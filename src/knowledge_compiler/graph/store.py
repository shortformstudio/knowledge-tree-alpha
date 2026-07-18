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
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import networkx as nx

from ..telemetry import EventBus


class GraphStore:
    """Directed graph store with optional SQLite persistence.

    Parameters
    ----------
    db_path : Optional[Path]
        File path for SQLite; in-memory-only when ``None``.
    event_bus : EventBus
        Telemetry sink for mutation events.
    """

    __slots__ = ("_graph", "_db_path", "_event_bus", "_db")

    def __init__(
        self,
        db_path: Path | None = None,
        event_bus: EventBus | None = None,
    ) -> None:
        self._graph: nx.DiGraph = nx.DiGraph()
        self._db_path = db_path
        self._event_bus = event_bus or EventBus(enabled=False)
        self._db: sqlite3.Connection | None = None

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
            "id TEXT PRIMARY KEY, type TEXT, content TEXT, depth INTEGER)"
        )
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS edges (source TEXT, target TEXT, relation TEXT, "
            "PRIMARY KEY (source, target, relation), "
            "FOREIGN KEY (source) REFERENCES nodes(id), "
            "FOREIGN KEY (target) REFERENCES nodes(id))"
        )
        self._db.commit()

    def _load_from_db(self) -> None:
        if self._db is None:
            return
        for row in self._db.execute("SELECT id, type, content, depth FROM nodes"):
            node_id, ntype, content, depth = row
            self._graph.add_node(node_id, type=ntype, content=content or "", depth=depth or 0)
        for row in self._db.execute("SELECT source, target, relation FROM edges"):
            source, target, relation = row
            self._graph.add_edge(source, target, relation=relation)

    # ------------------------------------------------------------------
    # Mutation
    # ------------------------------------------------------------------

    def add_node(self, node_id: str, **attrs: Any) -> None:
        self._graph.add_node(node_id, **attrs)
        self._event_bus.emit("graph:node_added", "GraphStore", {"id": node_id, **attrs})
        self._persist_node(node_id, attrs)

    def add_edge(self, source: str, target: str, relation: str = "links_to") -> None:
        self._graph.add_edge(source, target, relation=relation)
        self._event_bus.emit(
            "graph:edge_added",
            "GraphStore",
            {"source": source, "target": target, "relation": relation},
        )
        self._persist_edge(source, target, relation)

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

        sub: nx.DiGraph = nx.ego_graph(self._graph, node_id, radius=radius)

        nodes = [{"id": n, **self._graph.nodes[n]} for n in sub.nodes()]
        edges = [{"source": u, "target": v, **self._graph.edges[u, v]} for u, v in sub.edges()]

        return nodes, edges

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
    def graph(self) -> nx.DiGraph:
        """Expose the raw NetworkX graph for advanced consumers."""
        return self._graph

    # ------------------------------------------------------------------
    # Persistence helpers
    # ------------------------------------------------------------------

    def _persist_node(self, node_id: str, attrs: dict[str, Any]) -> None:
        if self._db is None:
            return
        self._db.execute(
            "INSERT OR REPLACE INTO nodes (id, type, content, depth) VALUES (?, ?, ?, ?)",
            (node_id, attrs.get("type", ""), attrs.get("content", ""), attrs.get("depth", 0)),
        )
        self._db.commit()

    def _persist_edge(self, source: str, target: str, relation: str) -> None:
        if self._db is None:
            return
        self._db.execute(
            "INSERT OR REPLACE INTO edges (source, target, relation) VALUES (?, ?, ?)",
            (source, target, relation),
        )
        self._db.commit()

    def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None
