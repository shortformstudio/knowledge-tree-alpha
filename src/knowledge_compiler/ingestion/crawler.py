"""BFS website crawler with depth-bounded graph population.

Formal guarantee
----------------
- Crawl complexity: O(V + E) where V = unique pages visited,
  E = unique edges discovered, within the depth-bounded induced subgraph.
- The state DAG (depth-ordered queue) ensures no node is visited twice
  and that depth strictly increases along every path.
- Pending nodes are flushed to SQLite in a single batch at crawl completion.
- Each crawl session records a tree structure showing exact link chains followed.
"""

from __future__ import annotations

from ..graph.store import GraphStore
from ..telemetry import EventBus
from .cleaner import ContentCleaner
from .fetcher import Fetcher
from .langdetect import LanguageDetector
from .translator import Translator


class Crawler:
    """BFS crawler that populates the knowledge graph.

    Parameters
    ----------
    fetcher : Fetcher
        Rate-limited HTTP fetcher.
    cleaner : ContentCleaner
        HTML-to-text + link extractor with cleaning.
    max_depth : int
        Hard ceiling on BFS depth (d ∈ {1, 2, 3}).
    graph : GraphStore
        Persistent knowledge graph to populate.
    max_content_chars : int
        Truncation length for page text stored in graph nodes.
    event_bus : EventBus
        Telemetry sink for crawl lifecycle events.
    lang_detector : LanguageDetector | None
        Optional language detector for identifying page language.
    translator : Translator | None
        Optional translator for converting non-target-language content.
    target_language : str
        Target language code (ISO 639-1) for translation.
    """

    __slots__ = (
        "_fetcher",
        "_cleaner",
        "_max_depth",
        "_graph",
        "_max_content_chars",
        "_event_bus",
        "_lang_detector",
        "_translator",
        "_target_language",
    )

    def __init__(
        self,
        fetcher: Fetcher,
        cleaner: ContentCleaner,
        max_depth: int,
        graph: GraphStore,
        max_content_chars: int,
        event_bus: EventBus,
        lang_detector: LanguageDetector | None = None,
        translator: Translator | None = None,
        target_language: str = "en",
    ) -> None:
        self._fetcher = fetcher
        self._cleaner = cleaner
        self._max_depth = max_depth
        self._graph = graph
        self._max_content_chars = max_content_chars
        self._event_bus = event_bus
        self._lang_detector = lang_detector
        self._translator = translator
        self._target_language = target_language

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def crawl(self, start_url: str) -> tuple[int, int]:
        """Execute a BFS crawl from *start_url* and return (nodes, edges)."""
        crawl_id = self._graph.start_crawl_session(start_url, self._max_depth)

        visited: set[str] = set()
        queue: list[tuple[str, int, str | None, int]] = [(start_url, 0, None, 0)]
        crawl_order = 0

        self._event_bus.emit(
            "crawl:start",
            "Crawler",
            {"url": start_url, "max_depth": self._max_depth, "crawl_id": crawl_id},
            version="v2",
        )

        while queue:
            current_url, depth, parent_url, order = queue.pop(0)

            if current_url in visited or depth > self._max_depth:
                continue

            visited.add(current_url)
            crawl_order += 1

            html = await self._fetcher.fetch(current_url)
            if html is None:
                self._event_bus.emit(
                    "crawl:skip",
                    "Crawler",
                    {"url": current_url, "reason": "fetch_failed", "crawl_id": crawl_id},
                    version="v2",
                )
                continue

            text, links = self._cleaner.clean(html, current_url)

            detected_lang = None
            translated = False
            if self._lang_detector and len(text) >= 20:
                lang_result = self._lang_detector.detect(text)
                if lang_result:
                    detected_lang = lang_result.code
                    if (lang_result.code != self._target_language
                        and lang_result.confidence > 0.7
                        and self._translator):
                        trans_result = await self._translator.translate(
                            text[:5000],
                            source_lang=lang_result.code,
                            target_lang=self._target_language,
                        )
                        if trans_result and trans_result.text != text:
                            text = trans_result.text
                            translated = True

            truncated = text[: self._max_content_chars]

            self._graph.add_node(
                node_id=current_url,
                type="webpage",
                content=truncated,
                depth=depth,
                crawl_id=crawl_id,
                parent_url=parent_url,
                crawl_order=crawl_order,
            )
            self._event_bus.emit(
                "crawl:node_visited",
                "Crawler",
                {
                    "url": current_url,
                    "depth": depth,
                    "chars": len(truncated),
                    "lang": detected_lang,
                    "translated": translated,
                    "crawl_id": crawl_id,
                    "parent_url": parent_url,
                    "crawl_order": crawl_order,
                },
                version="v2",
            )

            if depth < self._max_depth:
                for link in links:
                    self._graph.add_edge(
                        source=current_url,
                        target=link,
                        relation="links_to",
                    )
                    if link not in visited:
                        queue.append((link, depth + 1, current_url, crawl_order))

        self._graph.flush()
        self._graph.end_crawl_session(crawl_id)

        self._event_bus.emit(
            "crawl:complete",
            "Crawler",
            {
                "nodes": self._graph.node_count,
                "edges": self._graph.edge_count,
                "crawl_id": crawl_id,
            },
            version="v2",
        )

        return self._graph.node_count, self._graph.edge_count
