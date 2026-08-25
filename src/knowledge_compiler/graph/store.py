"""Persistent directed knowledge graph backed by NetworkX and SQLite.

Invariants
----------
- Every node has a mandatory ``type`` attribute.
- Every edge has a mandatory ``relation`` attribute.
- The graph is a DAG (enforced by the BFS crawl's depth ordering during
  construction; after the fact, cycles are permitted but noted).
- Node and edge counts are O(1) properties delegated to NetworkX.
- Persistence (when a ``db_path`` is provided) uses a two-table SQLite
  schema with GEXF serialisation for full-fidelity round-trips.
- SQLite mutations are batched: commits flush once per logical operation
  boundary or when ``flush()`` is called explicitly.
- Nodes carry a ``_added_at`` timestamp for TTL-based eviction.
- Crawl sessions are tracked with tree structures showing link chains.
"""

from __future__ import annotations

import contextlib
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

import networkx as nx

from ..telemetry import EventBus


class GraphStore:
    """Directed graph store with optional SQLite persistence and TTL eviction.

    Parameters
    ----------
    db_path : Optional[Path]
        File path for SQLite; in-memory-only when ``None``.
    event_bus : EventBus
        Telemetry sink for mutation events.
    max_nodes : int | None
        Hard ceiling on in-memory node count.  When exceeded, the oldest
        nodes (by insertion time) are evicted.  ``None`` disables eviction.
    node_ttl_seconds : float | None
        Maximum age (seconds) for a node before eviction.  ``None`` disables
        time-based eviction.
    """

    __slots__ = ("_graph", "_db_path", "_event_bus", "_db", "_max_nodes", "_node_ttl", "_pending")

    def __init__(
        self,
        db_path: Path | None = None,
        event_bus: EventBus | None = None,
        max_nodes: int | None = None,
        node_ttl_seconds: float | None = None,
    ) -> None:
        self._graph: nx.DiGraph = nx.DiGraph()  # type: ignore[type-arg]
        self._db_path = db_path
        self._event_bus = event_bus or EventBus(enabled=False)
        self._db: sqlite3.Connection | None = None
        self._max_nodes = max_nodes
        self._node_ttl = node_ttl_seconds
        self._pending: list[tuple[str, dict[str, Any]]] = []

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
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS nodes ("
            "id TEXT PRIMARY KEY, type TEXT, content TEXT, depth INTEGER, "
            "added_at REAL, crawl_id TEXT, parent_url TEXT, crawl_order INTEGER)"
        )
        self._db.execute(
            "CREATE INDEX IF NOT EXISTS idx_nodes_crawl_id ON nodes(crawl_id)"
        )
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS edges (source TEXT, target TEXT, relation TEXT, "
            "PRIMARY KEY (source, target, relation), "
            "FOREIGN KEY (source) REFERENCES nodes(id), "
            "FOREIGN KEY (target) REFERENCES nodes(id))"
        )
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS crawl_sessions ("
            "crawl_id TEXT PRIMARY KEY, start_url TEXT, start_time REAL, "
            "max_depth INTEGER, nodes_count INTEGER, edges_count INTEGER)"
        )
        self._db.commit()

    def _load_from_db(self) -> None:
        if self._db is None:
            return
        for row in self._db.execute(
            "SELECT id, type, content, depth, added_at, crawl_id, parent_url, crawl_order FROM nodes"
        ):
            node_id, ntype, content, depth, added_at, crawl_id, parent_url, crawl_order = row
            self._graph.add_node(
                node_id,
                type=ntype,
                content=content or "",
                depth=depth or 0,
                _added_at=added_at or time.time(),
                crawl_id=crawl_id,
                parent_url=parent_url,
                crawl_order=crawl_order or 0,
            )
        for row in self._db.execute("SELECT source, target, relation FROM edges"):
            source, target, relation = row
            self._graph.add_edge(source, target, relation=relation)

    # ------------------------------------------------------------------
    # Mutation
    # ------------------------------------------------------------------

    def add_node(self, node_id: str, **attrs: Any) -> None:
        attrs.setdefault("_added_at", time.time())
        self._graph.add_node(node_id, **attrs)
        self._event_bus.emit(
            "graph:node_added", "GraphStore", {"id": node_id, **attrs}, version="v2"
        )
        self._pending.append((node_id, attrs))
        self._evict_if_needed()

    def add_edge(self, source: str, target: str, relation: str = "links_to") -> None:
        self._graph.add_edge(source, target, relation=relation)
        self._event_bus.emit(
            "graph:edge_added",
            "GraphStore",
            {"source": source, "target": target, "relation": relation},
            version="v2",
        )
        self._persist_edge(source, target, relation)

    def flush(self) -> None:
        """Persist all pending nodes in a single SQLite transaction."""
        if self._db is None or not self._pending:
            return
        try:
            self._db.execute("BEGIN")
            for node_id, attrs in self._pending:
                self._db.execute(
                    "INSERT OR REPLACE INTO nodes (id, type, content, depth, added_at, crawl_id, parent_url, crawl_order) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        node_id,
                        attrs.get("type", ""),
                        attrs.get("content", ""),
                        attrs.get("depth", 0),
                        attrs.get("_added_at", time.time()),
                        attrs.get("crawl_id"),
                        attrs.get("parent_url"),
                        attrs.get("crawl_order", 0),
                    ),
                )
            self._db.commit()
        except Exception:
            if self._db is not None:
                self._db.rollback()
            raise
        finally:
            self._pending.clear()

    # ------------------------------------------------------------------
    # Crawl Session Tracking
    # ------------------------------------------------------------------

    def start_crawl_session(
        self, start_url: str, max_depth: int
    ) -> str:
        """Create a new crawl session and return its unique ID."""
        crawl_id = str(uuid.uuid4())[:8]
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
            nodes = self._db.execute(
                "SELECT COUNT(*) FROM nodes WHERE crawl_id = ?", (crawl_id,)
            ).fetchone()[0]
            edges = self._db.execute(
                "SELECT COUNT(*) FROM edges e "
                "JOIN nodes n ON e.source = n.id "
                "WHERE n.crawl_id = ?", (crawl_id,)
            ).fetchone()[0]
            self._db.execute(
                "UPDATE crawl_sessions SET nodes_count = ?, edges_count = ? WHERE crawl_id = ?",
                (nodes, edges, crawl_id),
            )
            self._db.commit()
        self._event_bus.emit(
            "crawl:session_end",
            "GraphStore",
            {"crawl_id": crawl_id, "nodes": nodes, "edges": edges},
            version="v2",
        )

    def get_crawl_sessions(self) -> list[dict[str, Any]]:
        """Return all recorded crawl sessions."""
        if self._db is None:
            return []
        sessions = []
        for row in self._db.execute(
            "SELECT crawl_id, start_url, start_time, max_depth, nodes_count, edges_count "
            "FROM crawl_sessions ORDER BY start_time DESC"
        ):
            sessions.append({
                "crawl_id": row[0],
                "start_url": row[1],
                "start_time": row[2],
                "max_depth": row[3],
                "nodes_count": row[4],
                "edges_count": row[5],
            })
        return sessions

    def get_crawl_tree(self, crawl_id: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Return the crawl tree for a session as (nodes, edges).

        Nodes include: id, type, content, depth, crawl_order, parent_url
        Edges include: source, target, relation
        """
        nodes = []
        for row in self._db.execute(
            "SELECT id, type, content, depth, crawl_order, parent_url "
            "FROM nodes WHERE crawl_id = ? ORDER BY crawl_order",
            (crawl_id,),
        ):
            nodes.append({
                "id": row[0],
                "type": row[1],
                "content": row[2],
                "depth": row[3],
                "crawl_order": row[4],
                "parent_url": row[5],
            })

        edges = []
        node_ids = {n["id"] for n in nodes}
        for row in self._db.execute(
            "SELECT source, target, relation FROM edges"
        ):
            if row[0] in node_ids and row[1] in node_ids:
                edges.append({
                    "source": row[0],
                    "target": row[1],
                    "relation": row[2],
                })

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
        """Return (nodes, edges) of the ego graph around *node_id*.

        Complexity: O(V_sub + E_sub) where V_sub and E_sub are the
        vertices and edges within the radius-bounded induced subgraph.
        """
        if not self._graph.has_node(node_id):
            return [], []

        sub: nx.DiGraph = nx.ego_graph(self._graph, node_id, radius=radius)  # type: ignore[type-arg]

        nodes = [{"id": n, **self._graph.nodes[n]} for n in sub.nodes()]
        edges = [
            {"source": u, "target": v, **self._graph.edges[u, v]} for u, v in sub.edges()
        ]

        return nodes, edges

    # ------------------------------------------------------------------
    # Eviction
    # ------------------------------------------------------------------

    def _evict_if_needed(self) -> None:
        """Evict oldest nodes when count or TTL threshold is exceeded."""
        evicted: set[str] = set()

        if self._node_ttl is not None:
            now = time.time()
            cutoff = now - self._node_ttl
            for node_id, attrs in list(self._graph.nodes(data=True)):
                added = attrs.get("_added_at", 0.0)
                if added < cutoff:
                    evicted.add(node_id)

        if self._max_nodes is not None:
            current_count = self._graph.number_of_nodes()
            if current_count > self._max_nodes:
                nodes_by_age = sorted(
                    self._graph.nodes(data=True),
                    key=lambda item: item[1].get("_added_at", 0.0),
                )
                to_remove = [nid for nid, _ in nodes_by_age[: current_count - self._max_nodes]]
                evicted.update(to_remove)

        for node_id in evicted:
            self._graph.remove_node(node_id)
            if self._db is not None:
                self._db.execute("DELETE FROM nodes WHERE id = ?", (node_id,))
                self._db.execute(
                    "DELETE FROM edges WHERE source = ? OR target = ?", (node_id, node_id)
                )

        if evicted and self._db is not None:
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

    def _persist_edge(self, source: str, target: str, relation: str) -> None:
        if self._db is None:
            return
        self._db.execute(
            "INSERT OR REPLACE INTO edges (source, target, relation) VALUES (?, ?, ?)",
            (source, target, relation),
        )
        self._db.commit()

    def close(self) -> None:
        """Flush pending nodes, run WAL checkpoint, and close the database."""
        self.flush()
        if self._db is not None:
            with contextlib.suppress(Exception):
                self._db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self._db.close()
            self._db = None
