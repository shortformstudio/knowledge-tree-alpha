"""Single-pass HTML content cleaner.

One iterative DOM traversal replaces the previous five recursive passes
(comments → junk → attributes → unwrap → extract).  Junk subtrees are
decomposed on encounter, so every ``NavigableString`` reached by the walk
is by construction free of stripped ancestry — the per-node parent
membership test from the legacy implementation becomes redundant.

Link extraction now happens *before* anchor unwrapping.  (The legacy
implementation unwrapped ``<a>`` in an earlier pass and then searched for
``<a href>`` afterwards, yielding an empty link set whenever
``keep_links=False`` — crawler discovery silently degraded to depth-0.)

Complexity: O(n) in document nodes, single allocation-heavy join at exit.
"""

from __future__ import annotations

import re
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup, Comment, NavigableString, Tag

STRIP_TAGS = frozenset({
    "script", "style", "nav", "footer", "header", "aside", "noscript",
    "iframe", "embed", "object", "applet", "form", "input", "button",
    "select", "textarea", "label", "fieldset", "legend", "datalist",
    "output", "option", "optgroup", "canvas", "svg", "map", "area",
    "audio", "video", "source", "track", "picture", "portal",
})

STRIP_ATTR_EXACT = frozenset({
    "class", "id", "style", "role", "tabindex", "accesskey",
    "contenteditable", "draggable", "hidden", "spellcheck",
    "translate", "dir", "lang", "xml:lang",
})
_STRIP_ATTR_PREFIXES = ("data-", "aria-", "on")

WRAPPER_TAGS = frozenset({"div", "span", "section", "article", "main"})

NON_HTML_EXTS = frozenset({".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".mp4"})

ZERO_WIDTH_RE = re.compile(r"[\u200b\u200c\u200d\u2060\ufeff]")
WHITESPACE_RE = re.compile(r"\s+")
REPEATED_PUNCT_RE = re.compile(r"([.!?])\1{2,}")

# Thirteen legacy patterns fused into one alternation — O(L) instead of O(P·L).
BOILERPLATE_RE = re.compile(
    r"(?i)(cookie\s+(?:policy|notice|consent)"
    r"|privacy\s+policy"
    r"|terms\s+of\s+(?:service|use)"
    r"|all\s+rights\s+reserved"
    r"|copyright\s+\d{4}"
    r"|sign\s+(?:up|in)"
    r"|log\s+in"
    r"|subscribe"
    r"|newsletter"
    r"|follow\s+us"
    r"|share\s+this"
    r"|advertisement"
    r"|sponsored\s+content)"
)


class ContentCleaner:
    """Stateless HTML content cleaner with a single traversal contract."""

    __slots__ = ("_keep_links", "_keep_images", "_min_text_length")

    def __init__(
        self,
        keep_links: bool = False,
        keep_images: bool = False,
        min_text_length: int = 50,
    ) -> None:
        self._keep_links = keep_links
        self._keep_images = keep_images
        self._min_text_length = min_text_length

    def clean(self, html: str, base_url: str) -> tuple[str, set[str]]:
        """Parse *html* once; return ``(plain_text, internal_links)``."""
        base_domain = urlparse(base_url).netloc
        soup = BeautifulSoup(html, "html.parser")

        text_parts: list[str] = []
        links: set[str] = set()

        # Iterative DFS; children are materialised before any mutation so a
        # decompose() mid-walk can never invalidate our iteration state.
        stack: list[object] = [soup]
        while stack:
            node = stack.pop()

            if isinstance(node, NavigableString):
                if not isinstance(node, Comment):
                    text = str(node).strip()
                    if text:
                        text_parts.append(text)
                continue

            if not isinstance(node, Tag):
                continue

            name = node.name

            if name in STRIP_TAGS:
                node.decompose()
                continue

            if name == "a":
                href = node.get("href")
                if isinstance(href, str) and href:
                    full_url = urljoin(base_url, href)
                    parsed = urlparse(full_url)
                    path = parsed.path.lower()
                    if (
                        parsed.netloc == base_domain
                        and full_url.startswith("http")
                        and not any(path.endswith(ext) for ext in NON_HTML_EXTS)
                    ):
                        links.add(full_url.split("#", 1)[0])
                if not self._keep_links:
                    # snapshot before unwrap(): splicing empties the node
                    kids = list(node.children)
                    node.unwrap()
                    stack.extend(reversed(kids))
                    continue

            elif name == "img":
                if not self._keep_images:
                    node.decompose()
                    continue
                src = node.get("src") or node.get("data-src")
                if isinstance(src, str) and src:
                    node["src"] = urljoin(base_url, src)

            attrs = node.attrs
            if attrs:
                for attr in [
                    a for a in attrs
                    if a in STRIP_ATTR_EXACT
                    or a.startswith(_STRIP_ATTR_PREFIXES)
                ]:
                    del attrs[attr]
                if name in WRAPPER_TAGS and not attrs:
                    kids = list(node.children)
                    node.unwrap()
                    stack.extend(reversed(kids))
                    continue

            stack.extend(reversed(list(node.children)))

        return self._finalize("\n\n".join(text_parts)), links

    def _finalize(self, text: str) -> str:
        text = ZERO_WIDTH_RE.sub("", text)
        text = WHITESPACE_RE.sub(" ", text)
        text = REPEATED_PUNCT_RE.sub(r"\1", text)
        min_len = self._min_text_length
        return "\n".join(
            line for line in (s.strip() for s in text.split("\n"))
            if len(line) >= min_len and not BOILERPLATE_RE.search(line)
        )


def clean_html(html: str, base_url: str, **kwargs: object) -> tuple[str, set[str]]:
    """Convenience one-shot wrapper around :class:`ContentCleaner`."""
    return ContentCleaner(**kwargs).clean(html, base_url)  # type: ignore[arg-type]
