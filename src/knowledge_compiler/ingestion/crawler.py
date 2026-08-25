"""BFS website crawler with depth-bounded graph population.

Formal guarantee
----------------
- Crawl complexity: O(V + E) where V = unique pages visited and E = unique
  edges discovered, within the depth-bounded induced subgraph.
- Frontier invariants: a URL enters the queue at most once (``queued`` set,
  O(1) membership) and is fetched at most once (``visited`` set).  Queue
  operations are O(1) via ``collections.deque`` — the legacy list-based
  ``pop(0)``, O(n) per call, degraded the traversal to O(V²).
- Each crawl session records an explicit tree: every node persists its
  ``crawl_id``, ``parent_url`` and monotonic ``crawl_order``.
"""

from __future__ import annotations

from collections import deque

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

    #: Minimum sample length for reliable language detection.
    _MIN_DETECT_CHARS: int = 20
    #: Confidence floor below which translation is refused.
    _MIN_TRANSLATE_CONFIDENCE: float = 0.7
    #: Upper bound on text handed to a translation backend per page.
    _TRANSLATE_SAMPLE_CHARS: int = 5000

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
        queued: set[str] = {start_url}
        # Elements: (url, depth, parent_url)
        frontier: deque[tuple[str, int, str | None]] = deque([(start_url, 0, None)])
        crawl_order = 0

        self._event_bus.emit(
            "crawl:start",
            "Crawler",
            {"url": start_url, "max_depth": self._max_depth, "crawl_id": crawl_id},
            version="v2",
        )

        while frontier:
            current_url, depth, parent_url = frontier.popleft()

            if depth > self._max_depth:
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

            detected_lang: str | None = None
            translated = False
            if self._lang_detector and len(text) >= self._MIN_DETECT_CHARS:
                lang_result = self._lang_detector.detect(text)
                if lang_result:
                    detected_lang = lang_result.code
                    needs_translation = (
                        lang_result.code != self._target_language
                        and lang_result.confidence > self._MIN_TRANSLATE_CONFIDENCE
                        and self._translator is not None
                    )
                    if needs_translation:
                        assert self._translator is not None
                        trans_result = await self._translator.translate(
                            text[: self._TRANSLATE_SAMPLE_CHARS],
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
                enqueue_depth = depth + 1
                for link in links:
                    self._graph.add_edge(source=current_url, target=link, relation="links_to")
                    if link not in visited and link not in queued:
                        queued.add(link)
                        frontier.append((link, enqueue_depth, current_url))

        self._graph.flush()
        self._graph.end_crawl_session(crawl_id)

        nodes, edges = self._graph.node_count, self._graph.edge_count
        self._event_bus.emit(
            "crawl:complete",
            "Crawler",
            {"nodes": nodes, "edges": edges, "crawl_id": crawl_id},
            version="v2",
        )
        return nodes, edges
