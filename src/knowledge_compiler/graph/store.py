"""Persistent directed knowledge graph backed by NetworkX and SQLite.

Invariants
----------
- Every node has a mandatory ``type`` attribute; every edge a ``relation``.
- Mutations are batched: nodes and edges accumulate in bounded in-memory
  queues and are persisted with ``executemany`` — one transaction per batch
  (default 500 rows) instead of one fsync per edge.  ``flush()``, session
  end and ``close()`` drain the queues, so a completed crawl is fully
  durable; a hard crash mid-crawl forfeits at most one partial batch.
- Eviction uses a min-heap keyed on insertion time: O(log N) per push and
  amortised O(k log N) for k evictions, with zero cost while limits hold
  (the legacy implementation scanned every node on every insert).
- Crawl-tree reads resolve through indexed SQL (``EXISTS`` probes against
  the ``idx_nodes_crawl_id`` index) rather than loading the full edge table.
- Indexes are created with ``IF NOT EXISTS``, so databases written by the
  previous schema upgrade in place with no migration step.
"""

from __future__ import annotations

import contextlib
import heapq
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

import networkx as nx

from ..telemetry import EventBus


class GraphStore:
    """Directed graph store: batched SQLite persistence + heap eviction.

    Parameters
    ----------
    db_path : Path | None
        File path for SQLite; in-memory-only when ``None``.
    event_bus : EventBus
        Telemetry sink for mutation events.
    max_nodes : int | None
        Hard ceiling on in-memory node count; oldest evicted when exceeded.
    node_ttl_seconds : float | None
        Maximum node age in seconds before eviction.  ``None`` disables.
    """

    __slots__ = (
        "_graph",
        "_db_path",
        "_event_bus",
        "_db",
        "_max_nodes",
        "_node_ttl",
        "_pending_nodes",
        "_pending_edges",
        "_eviction_heap",
        "_batch_size",
    )

    _SCHEMA = (
        "CREATE TABLE IF NOT EXISTS nodes ("
        "id TEXT PRIMARY KEY, type TEXT, content TEXT, depth INTEGER, "
        "added_at REAL, crawl_id TEXT, parent_url TEXT, crawl_order INTEGER)",
        "CREATE INDEX IF NOT EXISTS idx_nodes_crawl_id ON nodes(crawl_id)",
        "CREATE INDEX IF NOT EXISTS idx_nodes_added_at ON nodes(added_at)",
        "CREATE INDEX IF NOT EXISTS idx_nodes_crawl_order ON nodes(crawl_id, crawl_order)",
        "CREATE TABLE IF NOT EXISTS edges ("
        "source TEXT, target TEXT, relation TEXT, "
        "PRIMARY KEY (source, target, relation))",
        "CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source)",
        "CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target)",
        "CREATE TABLE IF NOT EXISTS crawl_sessions ("
        "crawl_id TEXT PRIMARY KEY, start_url TEXT, start_time REAL, "
        "max_depth INTEGER, nodes_count INTEGER, edges_count INTEGER)",
    )

    def __init__(
        self,
        db_path: Path | None = None,
        event_bus: EventBus | None = None,
        max_nodes: int | None = None,
        node_ttl_seconds: float | None = None,
        batch_size: int = 500,
    ) -> None:
        self._graph: nx.DiGraph = nx.DiGraph()  # type: ignore[type-arg]
        self._db_path = db_path
        self._event_bus = event_bus or EventBus(enabled=False)
        self._db: sqlite3.Connection | None = None
        self._max_nodes = max_nodes
        self._node_ttl = node_ttl_seconds
        self._pending_nodes: list[tuple[Any, ...]] = []
        self._pending_edges: list[tuple[str, str, str]] = []
        self._eviction_heap: list[tuple[float, str]] = []
        self._batch_size = max(1, batch_size)

        if self._db_path is not None:
            self._init_db()
            self._load_from_db()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def _init_db(self) -> None:
        assert self._db_path is not None
        self._db = sqlite3.connect(str(self._db_path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=NORMAL")
        for statement in self._SCHEMA:
            self._db.execute(statement)
        self._db.commit()

    def _load_from_db(self) -> None:
        if self._db is None:
            return
        graph_add_node = self._graph.add_node
        heap: list[tuple[float, str]] = []
        for row in self._db.execute(
            "SELECT id, type, content, depth, added_at, crawl_id, parent_url, crawl_order FROM nodes"
        ):
            node_id, ntype, content, depth, added_at, crawl_id, parent_url, crawl_order = row
            ts = added_at if added_at is not None else time.time()
            graph_add_node(
                node_id,
                type=ntype,
                content=content or "",
                depth=depth or 0,
                _added_at=ts,
                crawl_id=crawl_id,
                parent_url=parent_url,
                crawl_order=crawl_order or 0,
            )
            heap.append((ts, node_id))
        heapq.heapify(heap)
        self._eviction_heap = heap

        for source, target, relation in self._db.execute(
            "SELECT source, target, relation FROM edges"
        ):
            self._graph.add_edge(source, target, relation=relation)

    # ------------------------------------------------------------------
    # Mutation (batched)
    # ------------------------------------------------------------------

    def add_node(self, node_id: str, **attrs: Any) -> None:
        attrs.setdefault("_added_at", time.time())
        self._graph.add_node(node_id, **attrs)
        self._pending_nodes.append(
            (
                node_id,
                attrs.get("type", ""),
                attrs.get("content", ""),
                attrs.get("depth", 0),
                attrs["_added_at"],
                attrs.get("crawl_id"),
                attrs.get("parent_url"),
                attrs.get("crawl_order", 0),
            )
        )
        heapq.heappush(self._eviction_heap, (attrs["_added_at"], node_id))
        self._event_bus.emit(
            "graph:node_added", "GraphStore", {"id": node_id, **attrs}, version="v2"
        )
        self._evict_if_needed()
        if len(self._pending_nodes) >= self._batch_size:
            self.flush()

    def add_edge(self, source: str, target: str, relation: str = "links_to") -> None:
        self._graph.add_edge(source, target, relation=relation)
        self._pending_edges.append((source, target, relation))
        self._event_bus.emit(
            "graph:edge_added",
            "GraphStore",
            {"source": source, "target": target, "relation": relation},
            version="v2",
        )
        if len(self._pending_edges) >= self._batch_size:
            self.flush()

    def flush(self) -> None:
        """Persist all queued nodes and edges in one transaction."""
        if self._db is None:
            self._pending_nodes.clear()
            self._pending_edges.clear()
            return
        try:
            if self._pending_nodes:
                self._db.executemany(
                    "INSERT OR REPLACE INTO nodes "
                    "(id, type, content, depth, added_at, crawl_id, parent_url, crawl_order) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    self._pending_nodes,
                )
                self._pending_nodes.clear()
            if self._pending_edges:
                self._db.executemany(
                    "INSERT OR IGNORE INTO edges (source, target, relation) VALUES (?, ?, ?)",
                    self._pending_edges,
                )
                self._pending_edges.clear()
            self._db.commit()
        except Exception:
            if self._db is not None:
                self._db.rollback()
            raise

    # ------------------------------------------------------------------
    # Crawl session tracking
    # ------------------------------------------------------------------

    def start_crawl_session(self, start_url: str, max_depth: int) -> str:
        """Create a new crawl session and return its unique ID."""
        crawl_id = uuid.uuid4().hex[:8]
        if self._db is not None:
            self._db.execute(
                "INSERT INTO crawl_sessions (crawl_id, start_url, start_time, max_depth, nodes_count, edges_count) "
                "VALUES (?, ?, ?, ?, 0, 0)",
                (crawl_id, start_url, time.time(), max_depth),
            )
            self._db.commit()
        self._event_bus.emit(
            "crawl:session_start",
            "GraphStore",
            {"crawl_id": crawl_id, "start_url": start_url, "max_depth": max_depth},
            version="v2",
        )
        return crawl_id

    def end_crawl_session(self, crawl_id: str) -> None:
        """Finalize a crawl session with final counts."""
        if self._db is not None:
            self._db.execute(
                "UPDATE crawl_sessions SET "
                "nodes_count = (SELECT COUNT(*) FROM nodes WHERE crawl_id = ?), "
                "edges_count = (SELECT COUNT(*) FROM edges e "
                "               JOIN nodes n ON e.source = n.id "
                "               WHERE n.crawl_id = ?) "
                "WHERE crawl_id = ?",
                (crawl_id, crawl_id, crawl_id),
            )
            self._db.commit()
            row = self._db.execute(
                "SELECT nodes_count, edges_count FROM crawl_sessions WHERE crawl_id = ?",
                (crawl_id,),
            ).fetchone()
            nodes, edges = row if row is not None else (0, 0)
        else:
            nodes, edges = self.node_count, self.edge_count
        self._event_bus.emit(
            "crawl:session_end",
            "GraphStore",
            {"crawl_id": crawl_id, "nodes": nodes, "edges": edges},
            version="v2",
        )

    def get_crawl_sessions(self) -> list[dict[str, Any]]:
        """Return all recorded crawl sessions, newest first."""
        if self._db is None:
            return []
        return [
            {
                "crawl_id": row[0],
                "start_url": row[1],
                "start_time": row[2],
                "max_depth": row[3],
                "nodes_count": row[4],
                "edges_count": row[5],
            }
            for row in self._db.execute(
                "SELECT crawl_id, start_url, start_time, max_depth, nodes_count, edges_count "
                "FROM crawl_sessions ORDER BY start_time DESC"
            )
        ]

    def get_crawl_tree(self, crawl_id: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Return ``(nodes, edges)`` for a session via indexed SQL probes."""
        if self._db is None:
            return [], []

        columns = "id, type, content, depth, crawl_order, parent_url"
        nodes = [
            {
                "id": row[0],
                "type": row[1],
                "content": row[2],
                "depth": row[3],
                "crawl_order": row[4],
                "parent_url": row[5],
            }
            for row in self._db.execute(
                f"SELECT {columns} FROM nodes WHERE crawl_id = ? ORDER BY crawl_order",
                (crawl_id,),
            )
        ]
        if not nodes:
            return [], []

        edges = [
            {"source": row[0], "target": row[1], "relation": row[2]}
            for row in self._db.execute(
                "SELECT e.source, e.target, e.relation FROM edges e "
                "WHERE EXISTS (SELECT 1 FROM nodes s WHERE s.id = e.source AND s.crawl_id = ?) "
                "AND EXISTS (SELECT 1 FROM nodes t WHERE t.id = e.target AND t.crawl_id = ?)",
                (crawl_id, crawl_id),
            )
        ]
        return nodes, edges

    # ------------------------------------------------------------------
    # Query
    # ------------------------------------------------------------------

    def has_node(self, node_id: str) -> bool:
        return self._graph.has_node(node_id)

    def get_node(self, node_id: str) -> dict[str, Any]:
        return dict(self._graph.nodes[node_id]) if self._graph.has_node(node_id) else {}

    def ego_subgraph(
        self, node_id: str, radius: int = 1
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Return (nodes, edges) of the radius-bounded ego subgraph."""
        if not self._graph.has_node(node_id):
            return [], []

        sub: nx.DiGraph = nx.ego_graph(self._graph, node_id, radius=radius)  # type: ignore[type-arg]
        nodes = [{"id": n, **self._graph.nodes[n]} for n in sub.nodes()]
        edges = [
            {"source": u, "target": v, **self._graph.edges[u, v]} for u, v in sub.edges()
        ]
        return nodes, edges

    # ------------------------------------------------------------------
    # Eviction — heap-driven, amortised O(log N); no-op while limits hold
    # ------------------------------------------------------------------

    def _evict_if_needed(self) -> None:
        evicted: set[str] = set()
        heap = self._eviction_heap

        if self._node_ttl is not None and heap:
            cutoff = time.time() - self._node_ttl
            while heap and heap[0][0] < cutoff:
                _, node_id = heapq.heappop(heap)
                if self._graph.has_node(node_id):
                    evicted.add(node_id)

        if self._max_nodes is not None:
            excess = self._graph.number_of_nodes() - self._max_nodes
            while excess > 0 and heap:
                _, node_id = heapq.heappop(heap)
                if self._graph.has_node(node_id):
                    evicted.add(node_id)
                    excess -= 1

        if not evicted:
            return

        for node_id in evicted:
            self._graph.remove_node(node_id)

        if self._db is not None:
            self._db.executemany(
                "DELETE FROM nodes WHERE id = ?", [(nid,) for nid in evicted]
            )
            self._db.executemany(
                "DELETE FROM edges WHERE source = ? OR target = ?",
                [(nid, nid) for nid in evicted],
            )
            self._db.commit()

    # ------------------------------------------------------------------
    # Properties (O(1))
    # ------------------------------------------------------------------

    @property
    def node_count(self) -> int:
        return self._graph.number_of_nodes()

    @property
    def edge_count(self) -> int:
        return self._graph.number_of_edges()

    @property
    def graph(self) -> nx.DiGraph:  # type: ignore[type-arg]
        """Expose the raw NetworkX graph for advanced consumers."""
        return self._graph

    # ------------------------------------------------------------------
    # Persistence helpers
    # ------------------------------------------------------------------

    def close(self) -> None:
        """Flush pending mutations, checkpoint WAL, close the database."""
        self.flush()
        if self._db is not None:
            with contextlib.suppress(Exception):
                self._db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self._db.close()
            self._db = None
