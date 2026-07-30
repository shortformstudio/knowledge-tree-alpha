"""End-to-end integration tests: event routing through full workflow."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from knowledge_compiler.graph.store import GraphStore
from knowledge_compiler.ingestion.crawler import Crawler
from knowledge_compiler.ingestion.fetcher import Fetcher
from knowledge_compiler.ingestion.parser import Parser
from knowledge_compiler.semantic.compiler import SemanticCompiler
from knowledge_compiler.social.profiler import SocialProfiler
from knowledge_compiler.telemetry import EventBus, EventV2

# Sample HTML that the mock fetcher will return
SAMPLE_PAGE = """<html><head><title>Test Page</title></head>
<body><p>Hello world. AI is part of technology. Technology defines progress.</p>
<a href="https://example.com/page2">Page 2</a>
<a href="https://example.com/page3">Page 3</a>
</body></html>"""

SAMPLE_PAGE_2 = """<html><head><title>Page 2</title></head>
<body><p>Second page. Knowledge has structure.</p></body></html>"""


class TestCrawlerIntegration:
    """Verify complete crawl pipeline: fetch → parse → graph store → events."""

    @pytest.fixture
    def bus(self) -> EventBus:
        b = EventBus(enabled=True)
        yield b
        b.close()

    @pytest.fixture
    def graph(self, bus: EventBus) -> GraphStore:
        g = GraphStore(event_bus=bus)
        yield g
        g.close()

    @pytest.fixture
    def fetcher(self, bus: EventBus) -> Fetcher:
        return Fetcher(
            user_agent="TestAgent/1.0",
            timeout=10.0,
            rate_limit_rps=100.0,
            concurrency=4,
            event_bus=bus,
        )

    @pytest.fixture
    def parser(self) -> Parser:
        return Parser()

    @pytest.fixture
    def crawler(self, fetcher: Fetcher, parser: Parser, graph: GraphStore, bus: EventBus) -> Crawler:
        return Crawler(
            fetcher=fetcher,
            parser=parser,
            max_depth=2,
            graph=graph,
            max_content_chars=5000,
            event_bus=bus,
        )

    def test_crawl_emits_all_lifecycle_events(
        self, crawler: Crawler, graph: GraphStore, bus: EventBus
    ) -> None:
        events: list[EventV2] = []

        bus.on("crawl:start", events.append)
        bus.on("crawl:node_visited", events.append)
        bus.on("crawl:complete", events.append)
        bus.on("graph:node_added", events.append)
        bus.on("graph:edge_added", events.append)

        with patch.object(
            Fetcher,
            "_request",
            new_callable=AsyncMock,
            side_effect=[SAMPLE_PAGE, SAMPLE_PAGE_2, SAMPLE_PAGE_2],
        ):
            nodes, edges = asyncio.run(crawler.crawl("https://example.com/"))

        assert nodes >= 1
        assert edges >= 0
        event_types = {e.type for e in events}
        assert "crawl:start" in event_types
        assert "crawl:node_visited" in event_types
        assert "crawl:complete" in event_types
        assert "graph:node_added" in event_types

        crawl_complete = [e for e in events if e.type == "crawl:complete"]
        assert len(crawl_complete) == 1
        assert crawl_complete[0].version == "v2"

    def test_crawl_all_events_versioned(self, crawler: Crawler, bus: EventBus) -> None:
        events: list[EventV2] = []

        handler = events.append
        for event_type in (
            "crawl:start",
            "crawl:node_visited",
            "crawl:skip",
            "crawl:complete",
            "graph:node_added",
            "graph:edge_added",
        ):
            bus.on(event_type, handler)

        with patch.object(
            Fetcher,
            "_request",
            new_callable=AsyncMock,
            return_value=SAMPLE_PAGE,
        ):
            asyncio.run(crawler.crawl("https://example.com/"))

        for event in events:
            assert event.version in ("v2", "v1", None)
            assert len(event.event_id) == 32
            assert event.sequence > 0
            assert isinstance(event.timestamp, str)


class TestSemanticCompilerIntegration:
    """Verify ER triplet extraction publishes versioned events."""

    def test_compile_emits_versioned_event(self) -> None:
        bus = EventBus(enabled=True)
        compiler = SemanticCompiler(event_bus=bus)

        events: list[EventV2] = []
        bus.on("semantic:triplets_extracted", events.append)

        text = "Machine learning is part of artificial intelligence. Python has a rich ecosystem."
        triplets = compiler.compile(text, source_url="https://example.com/article")

        assert len(triplets) >= 0
        assert len(events) == 1
        assert events[0].version == "v2"
        assert events[0].type == "semantic:triplets_extracted"
        assert events[0].payload["text_chars"] == len(text)
        bus.close()


class TestSocialProfilerIntegration:
    """Verify social profiling emits versioned events and populates graph."""

    def test_compile_emits_versioned_events(self) -> None:
        bus = EventBus(enabled=True)
        graph = GraphStore(event_bus=bus)
        parser = Parser()
        fetcher = Fetcher(
            user_agent="TestAgent/1.0",
            timeout=10.0,
            rate_limit_rps=100.0,
            concurrency=4,
            event_bus=bus,
        )
        profiler = SocialProfiler(
            fetcher=fetcher, parser=parser, graph=graph, max_posts=5, event_bus=bus
        )

        events: list[EventV2] = []
        bus.on("social:compile_start", events.append)
        bus.on("social:compile_complete", events.append)

        github_html = """
        <html><body>
        <div class="pinned-item-list-item-content">My cool project</div>
        <div class="pinned-item-list-item-content">Another repo</div>
        </body></html>
        """

        with patch.object(
            Fetcher,
            "_request",
            new_callable=AsyncMock,
            return_value=github_html,
        ):
            dossier = asyncio.run(profiler.compile(handle="testuser", platform="github"))

        assert dossier["post_count"] >= 0
        assert dossier["handle"] == "testuser"
        assert len(events) >= 2
        for e in events:
            assert e.version == "v2"
            assert len(e.event_id) == 32

        bus.close()
        graph.close()

    def test_unsupported_platform_returns_error(self) -> None:
        bus = EventBus(enabled=True)
        graph = GraphStore(event_bus=bus)
        parser = Parser()
        fetcher = Fetcher(
            user_agent="TestAgent/1.0",
            timeout=10.0,
            rate_limit_rps=100.0,
            concurrency=4,
            event_bus=bus,
        )
        profiler = SocialProfiler(
            fetcher=fetcher, parser=parser, graph=graph, max_posts=5, event_bus=bus
        )

        dossier = asyncio.run(profiler.compile(handle="user", platform="unsupported"))
        assert "error" in dossier
        assert dossier["error"] == "Unsupported platform: unsupported"

        bus.close()
        graph.close()


class TestQueryEngineIntegration:
    """Verify query engine works with populated graphs."""

    def test_ego_query_on_populated_graph(self, graph_store: GraphStore) -> None:
        from knowledge_compiler.graph.query import QueryEngine

        engine = QueryEngine()
        graph_store.add_node("center", type="webpage", content="center node")
        graph_store.add_node("neighbor_a", type="webpage", content="neighbor a")
        graph_store.add_node("neighbor_b", type="webpage", content="neighbor b")
        graph_store.add_edge("center", "neighbor_a", relation="links_to")
        graph_store.add_edge("center", "neighbor_b", relation="links_to")

        result = engine.ego(graph=graph_store, node_id="center", radius=1)
        assert result["center"] == "center"
        assert result["radius"] == 1
        assert result["total_nodes"] == 3
        assert result["total_edges"] == 2

    def test_bfs_neighbors(self, graph_store: GraphStore) -> None:
        from knowledge_compiler.graph.query import QueryEngine

        engine = QueryEngine()
        graph_store.add_node("root", type="webpage", content="root")
        graph_store.add_node("child", type="webpage", content="child")
        graph_store.add_edge("root", "child", relation="links_to")

        result = engine.bfs_neighbors(graph=graph_store, node_id="root", max_depth=1)
        assert result["total_nodes"] == 2
        assert result["total_edges"] == 1
        assert "root" in result["depth_map"]

    def test_bfs_with_type_filter(self, graph_store: GraphStore) -> None:
        from knowledge_compiler.graph.query import QueryEngine

        engine = QueryEngine()
        graph_store.add_node("root", type="webpage", content="root")
        graph_store.add_node("social", type="social_post", content="tweet")
        graph_store.add_edge("root", "social", relation="links_to")

        result = engine.bfs_neighbors(
            graph=graph_store, node_id="root", max_depth=2, node_type="social_post"
        )
        assert result["total_nodes"] == 1


class TestEventVersionRoutingE2E:
    """Verify that different event versions reach the correct handlers."""

    def test_v2_events_only_trigger_v2_handlers(self) -> None:
        bus = EventBus(enabled=True)
        v2_events: list[EventV2] = []
        v1_events: list[EventV2] = []
        all_events: list[EventV2] = []

        bus.on("data:updated:v2", v2_events.append)
        bus.on("data:updated:v1", v1_events.append)
        bus.on("data:updated", all_events.append)

        bus.emit("data:updated", "Source", {"value": 42}, version="v2")
        bus.emit("data:updated", "Source", {"value": 99}, version="v1")

        assert len(v2_events) == 1
        assert v2_events[0].payload == {"value": 42}
        assert len(v1_events) == 1
        assert v1_events[0].payload == {"value": 99}
        assert len(all_events) == 2

        bus.close()

    def test_upcasted_legacy_routes_to_v2_listeners(self) -> None:
        bus = EventBus(enabled=True)
        v2_received: list[EventV2] = []
        legacy_received: list[EventV2] = []

        bus.on("graph:edge_added:v1", legacy_received.append)
        bus.on("graph:edge_added", v2_received.append)
        bus.emit_legacy("graph:edge_added", "GraphStore", {"source": "a", "target": "b"})

        assert len(v2_received) == 1
        assert v2_received[0].version == "v1"
        assert len(legacy_received) == 1
        bus.close()
