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

    graph_max_nodes: int | None = Field(
        default=None,
        ge=1,
        description=(
            "Hard ceiling on in-memory graph nodes; "
            "oldest evicted when exceeded. None = unbounded."
        ),
    )

    graph_node_ttl_seconds: float | None = Field(
        default=None,
        ge=10.0,
        description="Maximum node age in seconds before eviction. None = no time-based eviction.",
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

    memory_payload_streaming_threshold_bytes: int = Field(
        default=1_048_576,
        ge=1024,
        description="Payload size threshold (bytes) above which streaming/pagination is mandatory",
    )

    # ─── Translation & Language ──────────────────────────────────────

    translate_enabled: bool = Field(
        default=True,
        description="Enable automatic translation of non-target-language pages",
    )

    target_language: str = Field(
        default="en",
        min_length=2,
        max_length=5,
        description="Target language code for translation (ISO 639-1)",
    )

    translation_backends: str = Field(
        default="libretranslate,google,mymemory",
        description="Comma-separated list of translation backends in priority order",
    )

    libretranslate_url: str = Field(
        default="https://libretranslate.de",
        description="Base URL for LibreTranslate instance",
    )

    libretranslate_api_key: str | None = Field(
        default=None,
        description="API key for LibreTranslate (if required)",
    )

    mymemory_email: str | None = Field(
        default=None,
        description="Email for MyMemory API (increases rate limits)",
    )

    translation_timeout: float = Field(
        default=30.0,
        ge=5.0,
        le=120.0,
        description="Timeout in seconds for translation requests",
    )

    translation_cache_enabled: bool = Field(
        default=True,
        description="Enable in-memory translation cache",
    )

    language_detection_enabled: bool = Field(
        default=True,
        description="Enable automatic language detection",
    )

    language_detection_backend: str = Field(
        default="langdetect",
        description="Language detection backend: langdetect or fasttext",
    )

    fasttext_model_path: str | None = Field(
        default=None,
        description="Path to fastText language identification model (.bin)",
    )

    min_text_for_detection: int = Field(
        default=50,
        ge=10,
        description="Minimum text length for reliable language detection",
    )

    @field_validator("graph_db_path")
    @classmethod
    def _resolve_path(cls, v: Path | None) -> Path | None:
        if v is not None:
            return v.expanduser().resolve()
        return v

    @field_validator("translation_backends")
    @classmethod
    def _parse_backends(cls, v: str) -> str:
        return ",".join(b.strip() for b in v.split(",") if b.strip())

    @property
    def concurrency_semaphore_value(self) -> int:
        """Expose the semaphore bound for DI wiring."""
        return self.max_concurrent_requests

    @property
    def translation_backend_list(self) -> list[str]:
        return [b.strip() for b in self.translation_backends.split(",") if b.strip()]
