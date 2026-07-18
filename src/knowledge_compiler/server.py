"""Knowledge Dataset Compiler MCP Server.

Exposes three core tools via FastMCP:
- ``kdc_scrape_website_to_graph`` — BFS crawl → knowledge graph
- ``kdc_compile_social_dossier`` — profile scraping → dossier
- ``kdc_query_knowledge_graph`` — ego-graph query with depth radius

All tools are wired through a dependency-injection container for
porous modularity and independent testability.
"""

from __future__ import annotations

import json
from contextlib import asynccontextmanager
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .config import CompilerConfig
from .di import Container
from .graph.query import QueryEngine

# ---------------------------------------------------------------------------
# Pydantic input models
# ---------------------------------------------------------------------------


class ScrapeInput(BaseModel):
    """Input model for ``kdc_scrape_website_to_graph``."""

    model_config = ConfigDict(str_strip_whitespace=True, validate_assignment=True, extra="forbid")

    start_url: str = Field(
        ...,
        description="Root URL to begin the BFS crawl (e.g., 'https://example.com/docs')",
        min_length=1,
    )
    max_depth: int = Field(
        default=2,
        ge=1,
        le=3,
        description="BFS crawl depth: 1 = root only, 2 = root + direct links, 3 = two hops out",
    )

    @field_validator("start_url")
    @classmethod
    def _validate_url(cls, v: str) -> str:
        v = v.strip()
        if not v.startswith("http://") and not v.startswith("https://"):
            raise ValueError("start_url must begin with http:// or https://")
        return v


class SocialInput(BaseModel):
    """Input model for ``kdc_compile_social_dossier``."""

    model_config = ConfigDict(str_strip_whitespace=True, validate_assignment=True, extra="forbid")

    handle: str = Field(
        ...,
        description="Social media handle (with or without leading '@')",
        min_length=1,
        max_length=64,
    )
    platform: str = Field(
        default="twitter",
        description="Platform identifier: 'twitter', 'x', 'github', or 'reddit'",
        min_length=1,
        max_length=32,
    )

    @field_validator("handle")
    @classmethod
    def _clean_handle(cls, v: str) -> str:
        return v.strip().lstrip("@")


class QueryInput(BaseModel):
    """Input model for ``kdc_query_knowledge_graph``."""

    model_config = ConfigDict(str_strip_whitespace=True, validate_assignment=True, extra="forbid")

    entity_or_url: str = Field(
        ...,
        description="Node ID or URL to center the query on",
        min_length=1,
    )
    depth_radius: int = Field(
        default=1,
        ge=1,
        le=5,
        description="Number of hops to expand in the ego graph",
    )


# ---------------------------------------------------------------------------
# Lifespan: build the DI container once at server start
# ---------------------------------------------------------------------------

_container: Container | None = None
_query_engine = QueryEngine()


def _get_container() -> Container:
    global _container
    if _container is None:
        raise RuntimeError("Container not initialised — did the lifespan hook run?")
    return _container


@asynccontextmanager
async def _lifespan(server: FastMCP) -> Any:  # noqa: ARG001
    global _container
    config = CompilerConfig()
    _container = Container(config=config)
    yield {"config": config, "container": _container}
    if _container is not None:
        _container.graph.close()


# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------

mcp = FastMCP(
    "knowledge_compiler_mcp",
    lifespan=_lifespan,
)

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool(
    name="kdc_scrape_website_to_graph",
    annotations=ToolAnnotations(
        title="Scrape Website to Knowledge Graph",
        readOnlyHint=False,
        destructiveHint=False,
        idempotentHint=False,
        openWorldHint=True,
    ),
)
async def kdc_scrape_website_to_graph(params: ScrapeInput) -> str:
    """Crawl a website with BFS up to max_depth and populate the knowledge graph.

    Each page becomes a graph node carrying its text content; each hyperlink
    becomes a directed edge with relation ``links_to``.  The crawl respects
    the configured depth ceiling (1–3) and rate-limits per domain.

    Args:
        params (ScrapeInput):
            - start_url (str): Root URL (must start with http:// or https://)
            - max_depth (int): Crawl depth 1–3 (default 2)

    Returns:
        str: Summary string with total nodes and edges added.
    """
    c = _get_container()
    try:
        nodes, edges = await c.crawler.crawl(
            start_url=params.start_url,
        )
        return json.dumps(
            {
                "status": "success",
                "start_url": params.start_url,
                "max_depth": params.max_depth,
                "total_nodes": nodes,
                "total_edges": edges,
            },
            indent=2,
        )
    except Exception as exc:
        return f"Error during crawl: {type(exc).__name__}: {exc}"


@mcp.tool(
    name="kdc_compile_social_dossier",
    annotations=ToolAnnotations(
        title="Compile Social Profile Dossier",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=True,
    ),
)
async def kdc_compile_social_dossier(params: SocialInput) -> str:
    """Scrape a public social media profile and compile a dossier of posts.

    Extracted posts are stored as graph nodes linked to a profile entity.
    Supported platforms: twitter, x (Nitter), github, reddit.

    Args:
        params (SocialInput):
            - handle (str): Social handle (with or without '@')
            - platform (str): One of 'twitter', 'x', 'github', 'reddit' (default 'twitter')

    Returns:
        str: JSON dossier with handle, platform, core_teachings list, and post_count.
    """
    c = _get_container()
    try:
        dossier = await c.social.compile(
            handle=params.handle,
            platform=params.platform,
        )
        return json.dumps(dossier, indent=2, default=str)
    except Exception as exc:
        return f"Error compiling dossier: {type(exc).__name__}: {exc}"


@mcp.tool(
    name="kdc_query_knowledge_graph",
    annotations=ToolAnnotations(
        title="Query Knowledge Graph",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
async def kdc_query_knowledge_graph(params: QueryInput) -> str:
    """Query the compiled knowledge graph centered on an entity or URL.

    Returns the ego subgraph (nodes and edges) within depth_radius hops.
    Use this to explore connections, citations, and thematic relationships.

    Args:
        params (QueryInput):
            - entity_or_url (str): Node ID or URL to query
            - depth_radius (int): Ego-graph radius in hops (1–5, default 1)

    Returns:
        str: JSON with nodes, edges, center, radius, and counts.
    """
    c = _get_container()
    result: dict[str, Any] = _query_engine.ego(
        graph=c.graph,
        node_id=params.entity_or_url,
        radius=params.depth_radius,
    )
    if "error" in result:
        return f"Error: {result['error']}"
    return json.dumps(result, indent=2, default=str)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run()
