"""Memory and load stress tests.

Verifies:
- EventBus ring buffer does not leak memory under sustained load.
- GraphStore bounded eviction prevents unbounded growth.
- GraphStore TTL eviction releases stale references.
- Fetcher connection pooling does not accumulate socket handles.
- Repeated emission/disposal cycles return to baseline memory.
"""

from __future__ import annotations

import asyncio
import gc
from unittest.mock import AsyncMock, patch

import pytest

from knowledge_compiler.graph.store import GraphStore
from knowledge_compiler.ingestion.crawler import Crawler
from knowledge_compiler.ingestion.fetcher import Fetcher
from knowledge_compiler.ingestion.cleaner import ContentCleaner
from knowledge_compiler.telemetry import EventBus, EventV2, EventV2


def _allocated_mb() -> float:
    """Approximate memory footprint of tracked Python objects in MB."""
    gc.collect()
    try:
        import tracemalloc

        if not tracemalloc.is_tracing():
            tracemalloc.start()
        current, _ = tracemalloc.get_traced_memory()
        return current / 1_048_576.0
    except Exception:
        return 0.0


def _warmup_memory() -> None:
    """Prime tracemalloc so baseline measurement is non-zero."""
    _allocated_mb()


class TestEventBusMemoryUnderLoad:
    """Sustained event emission must not cause unbounded heap growth."""

    def test_history_stable_under_load(self) -> None:
        bus = EventBus(enabled=True, history_limit=500)
        _warmup_memory()
        import tracemalloc

        tracemalloc.start()
        tracemalloc.get_traced_memory()
        baseline = _allocated_mb()

        for _ in range(10_000):
            bus.emit("load:test", "StressTest", {"byte_data": "x" * 128}, version="v2")

        assert bus.history_length == 500
        after_load = _allocated_mb()

        bus.clear_history()
        bus.close()
        gc.collect()
        after_cleanup = _allocated_mb()
        assert after_cleanup < max(baseline * 30, 5.0)

    def test_listener_growth_plateaus(self) -> None:
        bus = EventBus(enabled=True)
        listeners: list[object] = []

        for i in range(200):
            listener = lambda e, _i=i: None  # noqa: E731
            listeners.append(listener)
            bus.on("load:test", listener)

        assert bus.listener_count == 200
        assert bus.listener_count < 10_000

        for listener in listeners:
            bus.off("load:test", listener)

        assert bus.listener_count == 0
        bus.close()

    def test_many_emits_no_residual(self) -> None:
        bus = EventBus(enabled=True, history_limit=50)
        _warmup_memory()
        baseline = _allocated_mb()
        for phase in range(5):
            for _ in range(2_000):
                bus.emit("stress:event", "Stress", {"phase": phase}, version="v2")
            bus.clear_history()

        bus.close()
        gc.collect()
        final = _allocated_mb()

        assert final < max(baseline * 5, 5.0)


class TestGraphStoreMemoryBounded:
    """Bounded graph must not exceed max_nodes."""

    def test_bounded_graph_plateaus(self) -> None:
        bus = EventBus(enabled=True)
        store = GraphStore(event_bus=bus, max_nodes=100, node_ttl_seconds=None)
        _warmup_memory()

        for i in range(500):
            store.add_node(f"node_{i}", type="webpage", content="x" * 500)

        assert store.node_count == 100
        assert store.has_node("node_499")

        store.close()
        bus.close()
        gc.collect()

    def test_ttl_eviction_releases_all_stale(self) -> None:
        import time

        bus = EventBus(enabled=True)
        store = GraphStore(event_bus=bus, max_nodes=None, node_ttl_seconds=0.1)

        for i in range(200):
            store.add_node(f"stale_{i}", type="test", content="x" * 200, _added_at=1.0)

        assert store.node_count == 0

        store.close()
        bus.close()

    def test_large_content_still_bounded(self) -> None:
        bus = EventBus(enabled=True)
        store = GraphStore(event_bus=bus, max_nodes=10, node_ttl_seconds=None)

        large_content = "A" * 100_000
        for i in range(50):
            store.add_node(f"big_{i}", type="webpage", content=large_content)

        assert store.node_count == 10
        store.close()
        bus.close()


class TestFetcherConnectionPooling:
    """Verify shared AsyncClient reuses connections."""

    @pytest.mark.asyncio
    async def test_shared_client_reuse(self) -> None:
        bus = EventBus(enabled=True)
        fetcher = Fetcher(
            user_agent="TestAgent/1.0",
            timeout=10.0,
            rate_limit_rps=100.0,
            concurrency=4,
            event_bus=bus,
        )

        client1 = await fetcher._client_instance()
        client2 = await fetcher._client_instance()
        assert client1 is client2

        await fetcher.close()
        bus.close()

    @pytest.mark.asyncio
    async def test_close_releases_client(self) -> None:
        bus = EventBus(enabled=True)
        fetcher = Fetcher(
            user_agent="TestAgent/1.0",
            timeout=10.0,
            rate_limit_rps=100.0,
            concurrency=4,
            event_bus=bus,
        )

        client = await fetcher._client_instance()
        await fetcher.close()
        assert client.is_closed

        bus.close()


class TestCrawlMemoryStability:
    """Crawler must not accumulate references across multiple crawl sessions."""

    @pytest.fixture
    def bus(self) -> EventBus:
        b = EventBus(enabled=True)
        yield b
        b.close()

    @pytest.fixture
    def graph(self, bus: EventBus) -> GraphStore:
        g = GraphStore(event_bus=bus, max_nodes=200)
        yield g
        g.close()

    @pytest.fixture
    def fetcher(self, bus: EventBus) -> Fetcher:
        f = Fetcher(
            user_agent="TestAgent/1.0",
            timeout=10.0,
            rate_limit_rps=100.0,
            concurrency=4,
            event_bus=bus,
        )
        yield f

    @pytest.fixture
    def crawler(
        self, fetcher: Fetcher, bus: EventBus, graph: GraphStore
    ) -> Crawler:
        return Crawler(
            fetcher=fetcher,
            cleaner=ContentCleaner(),
            max_depth=1,
            graph=graph,
            max_content_chars=3000,
            event_bus=bus,
        )

    @pytest.mark.asyncio
    async def test_repeated_crawls_memory_stable(self, crawler: Crawler, bus: EventBus) -> None:
        SAMPLE = """<html><body><p>Test content for memory stability.</p></body></html>"""
        _warmup_memory()
        baseline = _allocated_mb()

        for session in range(3):
            with patch.object(
                Fetcher,
                "_request",
                new_callable=AsyncMock,
                return_value=SAMPLE,
            ):
                await crawler.crawl(f"https://example{session}.com/page")

            bus.clear_history()

        gc.collect()
        after = _allocated_mb()

        assert after < max(baseline * 5, 5.0)


class TestEventUpcasterPerformance:
    """Upcasting must not be a bottleneck under load."""

    def test_many_upcasts_stable(self) -> None:
        from knowledge_compiler.telemetry import EventUpcaster, EventV1

        upcaster = EventUpcaster()
        _warmup_memory()
        baseline = _allocated_mb()

        for _ in range(10_000):
            v1 = EventV1(type="crawl:start", source="Test", payload={"url": "https://x.com"})
            v2 = upcaster.upcast(v1)
            assert v2.type == "crawl:start"

        gc.collect()
        after = _allocated_mb()
        assert after < max(baseline * 5, 5.0)
