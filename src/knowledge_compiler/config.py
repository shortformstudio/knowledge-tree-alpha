"""Configuration model for the Knowledge Dataset Compiler MCP server.

All runtime settings flow through a single validated configuration object,
enforced by pydantic-settings with environment variable overrides.
"""

from __future__ import annotations

from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class CompilerConfig(BaseSettings):
    """Immutable configuration snapshot validated at server startup.

    Every field is overridable via environment variable (prefix ``KDC_``).
    """

    model_config = SettingsConfigDict(
        env_prefix="KDC_",
        env_file=".env",
        env_file_encoding="utf-8",
        frozen=True,
        extra="forbid",
    )

    user_agent: str = Field(
        default="KnowledgeCompiler/1.0 (MCP)",
        description="HTTP User-Agent header sent with every outbound request",
        min_length=1,
    )

    request_timeout: float = Field(
        default=15.0,
        ge=1.0,
        le=120.0,
        description="Timeout in seconds for each HTTP request",
    )

    max_depth: int = Field(
        default=3,
        ge=1,
        le=5,
        description="Hard ceiling on BFS crawl depth (d ∈ {1,2,3,4,5})",
    )

    max_concurrent_requests: int = Field(
        default=8,
        ge=1,
        le=32,
        description="Semaphore bound for concurrent outbound HTTP connections",
    )

    rate_limit_rps: float = Field(
        default=5.0,
        ge=0.5,
        description="Requests-per-second cap per domain for polite crawling",
    )

    graph_db_path: Path | None = Field(
        default=None,
        description="Filesystem path for SQLite-backed graph persistence; in-memory when unset",
    )

    max_content_chars: int = Field(
        default=3000,
        ge=500,
        le=100_000,
        description="Truncation length for page text stored in graph nodes",
    )

    max_social_posts: int = Field(
        default=20,
        ge=1,
        le=100,
        description="Maximum social posts extracted per profile compile",
    )

    telemetry_enabled: bool = Field(
        default=True,
        description="Enable the observable event bus for connective dynamics tracing",
    )

    @field_validator("graph_db_path")
    @classmethod
    def _resolve_path(cls, v: Path | None) -> Path | None:
        if v is not None:
            return v.expanduser().resolve()
        return v

    @property
    def concurrency_semaphore_value(self) -> int:
        """Expose the semaphore bound for DI wiring."""
        return self.max_concurrent_requests
