"""Graph query engine.

Provides structured accessors over the knowledge graph with type-aware
filtering and BFS traversal for subgraph exploration.

Complexity
----------
- ``ego_subgraph``: O(V_sub + E_sub) where the radius-bounded subgraph
  has V_sub vertices and E_sub edges.
- ``bfs_neighbors``: O(V_reachable + E_reachable) within the depth limit.
"""

from __future__ import annotations

from typing import Any

from .store import GraphStore


class QueryEngine:
    """Read-only query facade over a ``GraphStore``.

    Stateless by design — every method receives the graph it operates on.
    """

    __slots__ = ()

    @staticmethod
    def ego(graph: GraphStore, node_id: str, radius: int = 1) -> dict[str, Any]:
        """Return nodes and edges within *radius* hops of *node_id*.

        Returns
        -------
        dict
            ``{"nodes": [...], "edges": [...], "center": node_id, "radius": radius}``
            or ``{"error": "..."}`` if the node is absent.
        """
        nodes, edges = graph.ego_subgraph(node_id, radius)
        return {
            "nodes": nodes,
            "edges": edges,
            "center": node_id,
            "radius": radius,
            "total_nodes": len(nodes),
            "total_edges": len(edges),
        }

    @staticmethod
    def bfs_neighbors(
        graph: GraphStore,
        node_id: str,
        max_depth: int = 2,
        node_type: str | None = None,
    ) -> dict[str, Any]:
        """BFS traversal from *node_id* up to *max_depth*, with optional type filter.

        Returns
        -------
        dict with ``nodes``, ``edges``, ``depth_map`` mapping node → depth.
        """
        if not graph.has_node(node_id):
            return {"error": f"Node '{node_id}' not found in graph."}

        nx_graph = graph.graph
        visited: dict[str, int] = {node_id: 0}
        queue: list[str] = [node_id]
        result_nodes: list[dict[str, Any]] = []
        result_edges: list[dict[str, Any]] = []

        while queue:
            current = queue.pop(0)
            current_depth = visited[current]

            attrs = dict(nx_graph.nodes[current])
            if node_type is None or attrs.get("type") == node_type:
                result_nodes.append({"id": current, "depth": current_depth, **attrs})

            if current_depth >= max_depth:
                continue

            for neighbor in nx_graph.successors(current):
                edge_attrs = dict(nx_graph.edges[current, neighbor])
                result_edges.append(
                    {
                        "source": current,
                        "target": neighbor,
                        **edge_attrs,
                    }
                )
                if neighbor not in visited:
                    visited[neighbor] = current_depth + 1
                    queue.append(neighbor)

        return {
            "nodes": result_nodes,
            "edges": result_edges,
            "depth_map": visited,
            "total_nodes": len(result_nodes),
            "total_edges": len(result_edges),
        }

    @staticmethod
    def stats(graph: GraphStore) -> dict[str, int]:
        """Return aggregate graph statistics."""
        return {
            "total_nodes": graph.node_count,
            "total_edges": graph.edge_count,
        }
