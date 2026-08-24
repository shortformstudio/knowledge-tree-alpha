"""Content cleaning pipeline for scraped HTML.

Strips structural junk, normalizes whitespace, removes formatting artifacts,
and extracts semantic body text suitable for knowledge compilation.
"""

from __future__ import annotations

import re
from urllib.parse import urlparse

from bs4 import BeautifulSoup, Comment


STRIP_TAGS = {
    "script", "style", "nav", "footer", "header", "aside", "noscript",
    "iframe", "embed", "object", "applet", "form", "input", "button",
    "select", "textarea", "label", "fieldset", "legend", "datalist",
    "output", "option", "optgroup", "canvas", "svg", "map", "area",
    "audio", "video", "source", "track", "picture", "portal",
}

STRIP_ATTRS = {
    "class", "id", "style", "onclick", "onload", "onerror", "onmouseover",
    "onmouseout", "onkeydown", "onkeyup", "onfocus", "onblur", "onchange",
    "onsubmit", "onreset", "onselect", "data-*", "aria-*", "role",
    "tabindex", "accesskey", "contenteditable", "draggable", "hidden",
    "spellcheck", "translate", "dir", "lang", "xml:lang",
}

KEEP_TAGS = {
    "p", "h1", "h2", "h3", "h4", "h5", "h6", "article", "section",
    "main", "div", "span", "blockquote", "q", "cite", "pre", "code",
    "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody",
    "tr", "th", "td", "caption", "figcaption", "figure", "hr", "br",
    "strong", "em", "b", "i", "u", "mark", "small", "del", "ins",
    "sub", "sup", "a", "img", "time", "address", "abbr", "dfn",
}

WHITESPACE_RE = re.compile(r"\s+")
ZERO_WIDTH_RE = re.compile(r"[\u200b\u200c\u200d\u2060\ufeff]")
REPEATED_PUNCT_RE = re.compile(r"([.!?])\1{2,}")
BOILERPLATE_PATTERNS = [
    re.compile(r"cookie\s+(policy|notice|consent)", re.I),
    re.compile(r"privacy\s+policy", re.I),
    re.compile(r"terms\s+of\s+(service|use)", re.I),
    re.compile(r"all\s+rights\s+reserved", re.I),
    re.compile(r"copyright\s+\d{4}", re.I),
    re.compile(r"sign\s+(up|in)", re.I),
    re.compile(r"log\s+in", re.I),
    re.compile(r"subscribe", re.I),
    re.compile(r"newsletter", re.I),
    re.compile(r"follow\s+us", re.I),
    re.compile(r"share\s+this", re.I),
    re.compile(r"advertisement", re.I),
    re.compile(r"sponsored\s+content", re.I),
]


class ContentCleaner:
    """Stateless HTML content cleaner.

    Pipeline:
    1. Parse with BeautifulSoup
    2. Remove comments
    3. Decompose structural junk tags
    4. Strip attributes from remaining tags
    5. Unwrap non-semantic wrapper tags (div, span without semantic purpose)
    6. Extract text with preserved paragraph boundaries
    7. Normalize whitespace and filter boilerplate lines
    """

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
        """Clean HTML and return (plain_text, internal_links).

        Parameters
        ----------
        html : str
            Raw HTML document.
        base_url : str
            Base URL for resolving relative links.

        Returns
        -------
        text : str
            Cleaned, normalized body text.
        links : set[str]
            Absolute, same-domain, fragment-free URLs.
        """
        soup = BeautifulSoup(html, "html.parser")

        self._remove_comments(soup)
        self._decompose_junk(soup)
        self._strip_attributes(soup)
        self._unwrap_wrappers(soup)
        self._handle_media(soup, base_url)

        text, links = self._extract_text_and_links(soup, base_url)
        text = self._normalize_text(text)
        text = self._filter_boilerplate(text)

        return text, links

    def _remove_comments(self, soup: BeautifulSoup) -> None:
        for comment in soup.find_all(string=lambda text: isinstance(text, Comment)):
            comment.extract()

    def _decompose_junk(self, soup: BeautifulSoup) -> None:
        for tag_name in STRIP_TAGS:
            for tag in soup(tag_name):
                tag.decompose()

    def _strip_attributes(self, soup: BeautifulSoup) -> None:
        for tag in soup.find_all(True):
            attrs_to_remove = []
            for attr in tag.attrs:
                if attr in STRIP_ATTRS or any(attr.startswith(p.rstrip("*")) for p in STRIP_ATTRS if p.endswith("*")):
                    attrs_to_remove.append(attr)
            for attr in attrs_to_remove:
                del tag[attr]

            if tag.name == "a" and not self._keep_links:
                tag.unwrap()
            elif tag.name == "img" and not self._keep_images:
                tag.decompose()

    def _unwrap_wrappers(self, soup: BeautifulSoup) -> None:
        for tag in soup.find_all(["div", "span", "section", "article", "main"]):
            if tag.name in KEEP_TAGS and not tag.attrs:
                if not any(child.name in KEEP_TAGS for child in tag.children if hasattr(child, "name")):
                    continue
                tag.unwrap()

    def _handle_media(self, soup: BeautifulSoup, base_url: str) -> None:
        if self._keep_images:
            for img in soup.find_all("img"):
                src = img.get("src") or img.get("data-src")
                if src:
                    from urllib.parse import urljoin
                    img["src"] = urljoin(base_url, src)
                    img["alt"] = img.get("alt", "")

    def _extract_text_and_links(self, soup: BeautifulSoup, base_url: str) -> tuple[str, set[str]]:
        base_domain = urlparse(base_url).netloc
        links: set[str] = set()

        for a_tag in soup.find_all("a", href=True):
            href_val = a_tag["href"]
            href = href_val if isinstance(href_val, str) else href_val[0]
            from urllib.parse import urljoin
            full_url = urljoin(base_url, href)
            parsed = urlparse(full_url)
            if parsed.netloc == base_domain and full_url.startswith("http"):
                clean = full_url.split("#")[0]
                path = parsed.path.lower()
                if path and not any(path.endswith(ext) for ext in (".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".mp4")):
                    links.add(clean)

        text_parts = []
        for elem in soup.find_all(string=True):
            parent = elem.parent
            if parent and parent.name in KEEP_TAGS:
                text = elem.strip()
                if text:
                    text_parts.append(text)

        return "\n\n".join(text_parts), links

    def _normalize_text(self, text: str) -> str:
        text = ZERO_WIDTH_RE.sub("", text)
        text = WHITESPACE_RE.sub(" ", text)
        text = REPEATED_PUNCT_RE.sub(r"\1", text)
        lines = [line.strip() for line in text.split("\n") if line.strip()]
        return "\n".join(lines)

    def _filter_boilerplate(self, text: str) -> str:
        lines = text.split("\n")
        filtered = []
        for line in lines:
            if len(line) < self._min_text_length:
                continue
            if any(p.search(line) for p in BOILERPLATE_PATTERNS):
                continue
            filtered.append(line)
        return "\n".join(filtered)


def clean_html(html: str, base_url: str, **kwargs) -> tuple[str, set[str]]:
    """Convenience function for one-shot cleaning."""
    cleaner = ContentCleaner(**kwargs)
    return cleaner.clean(html, base_url)