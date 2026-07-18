"""HTML parser with link extraction.

Produces a (text, links) pair from raw HTML.  Strips structural
elements (nav, footer, script, style) before text extraction so the
stored content is primarily semantic body copy.

Complexity
----------
- ``BeautifulSoup`` parse: O(N) in HTML length.
- Link extraction: O(A) where *A* is the number of ``<a>`` tags.
- Overall: O(N + A) per document.
"""

from __future__ import annotations

from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup

STRIP_TAGS = {"script", "style", "nav", "footer", "header"}
NON_HTML_EXTS = (".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".mp4")


class Parser:
    """Stateless HTML-to-structured-data converter."""

    __slots__ = ()

    def extract(self, html: str, base_url: str) -> tuple[str, set[str]]:
        """Parse *html* and return (plain_text, internal_links).

        Parameters
        ----------
        html : str
            Raw HTML document.
        base_url : str
            URL used to resolve relative links and to determine the
            same-domain boundary for link filtering.

        Returns
        -------
        text : str
            Space-joined body text with structural tags removed.
        links : set[str]
            Absolute, same-domain, fragment-free URLs found in the document.
        """
        soup = BeautifulSoup(html, "html.parser")

        for tag in soup(STRIP_TAGS):
            tag.decompose()

        text = " ".join(soup.stripped_strings)

        base_domain = urlparse(base_url).netloc
        links: set[str] = set()

        for a_tag in soup.find_all("a", href=True):
            href_val = a_tag["href"]
            href = href_val if isinstance(href_val, str) else href_val[0]
            full_url = urljoin(base_url, href)
            parsed = urlparse(full_url)

            if parsed.netloc != base_domain:
                continue
            if not full_url.startswith("http"):
                continue

            clean = full_url.split("#")[0]
            path = parsed.path.lower()
            if path and any(path.endswith(ext) for ext in NON_HTML_EXTS):
                continue

            links.add(clean)

        return text, links
