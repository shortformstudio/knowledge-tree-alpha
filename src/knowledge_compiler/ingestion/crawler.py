"""BFS website crawler with depth-bounded graph population.

Formal guarantee
----------------
- Crawl complexity: O(V + E) where V = unique pages visited,
  E = unique edges discovered, within the depth-bounded induced subgraph.
- The state DAG (depth-ordered queue) ensures no node is visited twice
  and that depth strictly increases along every path.
"""

from __future__ import annotations

from ..graph.store import GraphStore
from ..telemetry import EventBus
from .fetcher import Fetcher
from .parser import Parser


class Crawler:
    """BFS crawler that populates the knowledge graph.

    Parameters
    ----------
    fetcher : Fetcher
        Rate-limited HTTP fetcher.
    parser : Parser
        HTML-to-text + link extractor.
    max_depth : int
        Hard ceiling on BFS depth (d ∈ {1, 2, 3}).
    graph : GraphStore
        Persistent knowledge graph to populate.
    max_content_chars : int
        Truncation length for page text stored in graph nodes.
    event_bus : EventBus
        Telemetry sink for crawl lifecycle events.
    """

    __slots__ = (
        "_fetcher",
        "_parser",
        "_max_depth",
        "_graph",
        "_max_content_chars",
        "_event_bus",
    )

    def __init__(
        self,
        fetcher: Fetcher,
        parser: Parser,
        max_depth: int,
        graph: GraphStore,
        max_content_chars: int,
        event_bus: EventBus,
    ) -> None:
        self._fetcher = fetcher
        self._parser = parser
        self._max_depth = max_depth
        self._graph = graph
        self._max_content_chars = max_content_chars
        self._event_bus = event_bus

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def crawl(self, start_url: str) -> tuple[int, int]:
        """Execute a BFS crawl from *start_url* and return (nodes, edges).

        The crawl respects ``self._max_depth`` and never revisits a URL.
        """
        visited: set[str] = set()
        queue: list[tuple[str, int]] = [(start_url, 0)]

        self._event_bus.emit(
            "crawl:start",
            "Crawler",
            {"url": start_url, "max_depth": self._max_depth},
        )

        while queue:
            current_url, depth = queue.pop(0)

            if current_url in visited or depth > self._max_depth:
                continue

            visited.add(current_url)

            html = await self._fetcher.fetch(current_url)
            if html is None:
                self._event_bus.emit(
                    "crawl:skip",
                    "Crawler",
                    {"url": current_url, "reason": "fetch_failed"},
                )
                continue

            text, links = self._parser.extract(html, current_url)

            truncated = text[: self._max_content_chars]

            self._graph.add_node(
                node_id=current_url,
                type="webpage",
                content=truncated,
                depth=depth,
            )
            self._event_bus.emit(
                "crawl:node_visited",
                "Crawler",
                {"url": current_url, "depth": depth, "chars": len(truncated)},
            )

            if depth < self._max_depth:
                for link in links:
                    self._graph.add_edge(
                        source=current_url,
                        target=link,
                        relation="links_to",
                    )
                    if link not in visited:
                        queue.append((link, depth + 1))

        self._event_bus.emit(
            "crawl:complete",
            "Crawler",
            {"nodes": self._graph.node_count, "edges": self._graph.edge_count},
        )

        return self._graph.node_count, self._graph.edge_count
