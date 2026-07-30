"""Tests for GraphStore: persistence, batching, TTL eviction, bounded eviction."""

from __future__ import annotations

import time
from pathlib import Path

from knowledge_compiler.graph.store import GraphStore


class TestGraphStoreMutation:
    """Basic node/edge operations."""

    def test_add_node(self, graph_store: GraphStore) -> None:
        graph_store.add_node("node_a", type="test", content="hello")
        assert graph_store.has_node("node_a")
        assert graph_store.node_count == 1
        node = graph_store.get_node("node_a")
        assert node["type"] == "test"
        assert node["content"] == "hello"

    def test_add_node_assigns_timestamp(self, graph_store: GraphStore) -> None:
        graph_store.add_node("node_t", type="test", content="timed")
        node = graph_store.get_node("node_t")
        assert "_added_at" in node
        assert isinstance(node["_added_at"], float)
        assert node["_added_at"] > 0

    def test_add_edge(self, graph_store: GraphStore) -> None:
        graph_store.add_node("from", type="webpage", content="source")
        graph_store.add_node("to", type="webpage", content="target")
        graph_store.add_edge("from", "to", relation="links_to")
        assert graph_store.edge_count == 1

    def test_add_existing_node_updates(self, graph_store: GraphStore) -> None:
        graph_store.add_node("dup", type="test", content="first")
        graph_store.add_node("dup", type="test", content="second")
        node = graph_store.get_node("dup")
        assert node["content"] == "second"

    def test_ego_subgraph(self, graph_store: GraphStore) -> None:
        graph_store.add_node("center", type="webpage", content="c")
        graph_store.add_node("neighbor", type="webpage", content="n")
        graph_store.add_edge("center", "neighbor", relation="links_to")
        nodes, edges = graph_store.ego_subgraph("center", radius=1)
        assert len(nodes) == 2
        assert len(edges) == 1

    def test_ego_subgraph_missing_node(self, graph_store: GraphStore) -> None:
        nodes, edges = graph_store.ego_subgraph("nonexistent")
        assert nodes == []
        assert edges == []


class TestGraphStoreBatching:
    """Verify SQLite batching via flush()."""

    def test_flush_persists_nodes(self, persistent_graph: GraphStore) -> None:
        persistent_graph.add_node("batch_1", type="webpage", content="one")
        persistent_graph.add_node("batch_2", type="webpage", content="two")
        persistent_graph.flush()

        reloaded = GraphStore(
            db_path=persistent_graph._db_path,
            event_bus=persistent_graph._event_bus,
        )
        try:
            assert reloaded.has_node("batch_1")
            assert reloaded.has_node("batch_2")
            assert reloaded.get_node("batch_1") == reloaded.get_node("batch_1")
        finally:
            reloaded.close()

    def test_close_flushes_pending(self, persistent_graph: GraphStore) -> None:
        persistent_graph.add_node("auto_flush", type="webpage", content="flushed on close")
        persistent_graph.close()

        reloaded = GraphStore(
            db_path=persistent_graph._db_path,
            event_bus=persistent_graph._event_bus,
        )
        try:
            assert reloaded.has_node("auto_flush")
        finally:
            reloaded.close()


class TestGraphStoreBoundedEviction:
    """Verify max_nodes eviction."""

    def test_eviction_trims_oldest(self, bounded_graph: GraphStore) -> None:
        for i in range(10):
            bounded_graph.add_node(f"node_{i}", type="test", content=str(i))

        assert bounded_graph.node_count == 5
        assert not bounded_graph.has_node("node_0")
        assert not bounded_graph.has_node("node_1")
        assert bounded_graph.has_node("node_9")

    def test_eviction_staggered_timestamps(self, bounded_graph: GraphStore) -> None:
        bounded_graph.add_node("old_1", type="test", content="old", _added_at=100.0)
        bounded_graph.add_node("old_2", type="test", content="old", _added_at=200.0)
        bounded_graph.add_node("mid", type="test", content="mid", _added_at=300.0)
        bounded_graph.add_node("recent_1", type="test", content="new", _added_at=400.0)
        bounded_graph.add_node("recent_2", type="test", content="new", _added_at=500.0)
        bounded_graph.add_node("overflow", type="test", content="new", _added_at=600.0)

        assert bounded_graph.node_count == 5
        assert not bounded_graph.has_node("old_1")
        assert bounded_graph.has_node("overflow")


class TestGraphStoreTTLEviction:
    """Verify time-based node eviction."""

    def test_ttl_evicts_expired_nodes(self, event_bus: "EventBus") -> None:
        from knowledge_compiler.telemetry import EventBus as EB

        bus = EB(enabled=True)
        store = GraphStore(event_bus=bus, max_nodes=None, node_ttl_seconds=1.0)

        store.add_node("fresh", type="test", content="valid", _added_at=time.time())
        store.add_node("stale", type="test", content="expired", _added_at=time.time() - 100.0)

        assert store.has_node("fresh")
        assert not store.has_node("stale")
        store.close()
        bus.close()

    def test_ttl_with_bounded_eviction(self, event_bus: "EventBus") -> None:
        from knowledge_compiler.telemetry import EventBus as EB

        bus = EB(enabled=True)
        store = GraphStore(event_bus=bus, max_nodes=3, node_ttl_seconds=1.0)

        store.add_node("a", type="test", content="a", _added_at=time.time())
        store.add_node("b", type="test", content="b", _added_at=time.time() - 100.0)
        store.add_node("c", type="test", content="c", _added_at=time.time())
        store.add_node("d", type="test", content="d", _added_at=time.time())

        assert store.node_count <= 3
        assert not store.has_node("b")
        store.close()
        bus.close()

    def test_no_eviction_when_ttl_none(self, graph_store: GraphStore) -> None:
        graph_store.add_node("ancient", type="test", content="old", _added_at=1.0)
        assert graph_store.has_node("ancient")


class TestGraphStoreProperties:
    """O(1) property access."""

    def test_counts(self, graph_store: GraphStore) -> None:
        graph_store.add_node("a", type="t", content="a")
        graph_store.add_node("b", type="t", content="b")
        graph_store.add_edge("a", "b", relation="links_to")
        assert graph_store.node_count == 2
        assert graph_store.edge_count == 1

    def test_graph_accessor(self, graph_store: GraphStore) -> None:
        import networkx as nx

        g = graph_store.graph
        assert isinstance(g, nx.DiGraph)
