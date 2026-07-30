"""Dependency-injection container for porous modularity.

Every subsystem receives its dependencies through a single container
rather than reaching into global state.  This preserves the invariant that
components are independently testable and replaceable.
"""

from __future__ import annotations

import atexit
import contextlib
import logging
import signal
from dataclasses import dataclass, field
from types import FrameType
from typing import TYPE_CHECKING

from .config import CompilerConfig

if TYPE_CHECKING:
    from .graph.store import GraphStore
    from .ingestion.crawler import Crawler
    from .ingestion.fetcher import Fetcher
    from .ingestion.parser import Parser
    from .semantic.compiler import SemanticCompiler
    from .social.profiler import SocialProfiler
    from .telemetry import EventBus, EventUpcaster

_LIFECYCLE_LOGGER = logging.getLogger("knowledge_compiler.lifecycle")


@dataclass(slots=True)
class Container:
    """Centralised wiring point with graceful shutdown.

    Modules are instantiated lazily via properties so that optional
    subsystems (telemetry) are created only when enabled.  The
    ``shutdown()`` method is idempotent and safe to call from signal
    handlers or lifespan hooks.
    """

    config: CompilerConfig

    _graph: GraphStore | None = field(default=None, init=False)
    _fetcher: Fetcher | None = field(default=None, init=False)
    _parser: Parser | None = field(default=None, init=False)
    _crawler: Crawler | None = field(default=None, init=False)
    _semantic: SemanticCompiler | None = field(default=None, init=False)
    _social: SocialProfiler | None = field(default=None, init=False)
    _event_bus: EventBus | None = field(default=None, init=False)
    _upcaster: EventUpcaster | None = field(default=None, init=False)
    _shutdown_registered: bool = field(default=False, init=False)

    def __post_init__(self) -> None:
        self._register_shutdown_handler()

    # ------------------------------------------------------------------
    # Properties (lazy wiring)
    # ------------------------------------------------------------------

    @property
    def upcaster(self) -> EventUpcaster:
        if self._upcaster is None:
            from .telemetry import EventUpcaster

            self._upcaster = EventUpcaster()
        return self._upcaster

    @property
    def event_bus(self) -> EventBus:
        if self._event_bus is None:
            from .telemetry import EventBus

            self._event_bus = EventBus(
                enabled=self.config.telemetry_enabled,
                upcaster=self.upcaster,
            )
        return self._event_bus

    @property
    def graph(self) -> GraphStore:
        if self._graph is None:
            from .graph.store import GraphStore

            self._graph = GraphStore(
                db_path=self.config.graph_db_path,
                event_bus=self.event_bus,
                max_nodes=self.config.graph_max_nodes,
                node_ttl_seconds=self.config.graph_node_ttl_seconds,
            )
        return self._graph

    @property
    def fetcher(self) -> Fetcher:
        if self._fetcher is None:
            from .ingestion.fetcher import Fetcher

            self._fetcher = Fetcher(
                user_agent=self.config.user_agent,
                timeout=self.config.request_timeout,
                rate_limit_rps=self.config.rate_limit_rps,
                concurrency=self.config.concurrency_semaphore_value,
                event_bus=self.event_bus,
            )
        return self._fetcher

    @property
    def parser(self) -> Parser:
        if self._parser is None:
            from .ingestion.parser import Parser

            self._parser = Parser()
        return self._parser

    @property
    def crawler(self) -> Crawler:
        if self._crawler is None:
            from .ingestion.crawler import Crawler

            self._crawler = Crawler(
                fetcher=self.fetcher,
                parser=self.parser,
                max_depth=self.config.max_depth,
                graph=self.graph,
                max_content_chars=self.config.max_content_chars,
                event_bus=self.event_bus,
            )
        return self._crawler

    @property
    def semantic(self) -> SemanticCompiler:
        if self._semantic is None:
            from .semantic.compiler import SemanticCompiler

            self._semantic = SemanticCompiler(event_bus=self.event_bus)
        return self._semantic

    @property
    def social(self) -> SocialProfiler:
        if self._social is None:
            from .social.profiler import SocialProfiler

            self._social = SocialProfiler(
                fetcher=self.fetcher,
                parser=self.parser,
                graph=self.graph,
                max_posts=self.config.max_social_posts,
                event_bus=self.event_bus,
            )
        return self._social

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def _register_shutdown_handler(self) -> None:
        if self._shutdown_registered:
            return
        self._shutdown_registered = True
        atexit.register(self.shutdown)
        for sig in (signal.SIGINT, signal.SIGTERM):
            with contextlib.suppress(ValueError, OSError):
                signal.signal(sig, self._signal_handler)

    def _signal_handler(self, signum: int, frame: FrameType | None) -> None:
        _LIFECYCLE_LOGGER.info("Received signal %d, initiating graceful shutdown", signum)
        self.shutdown()
        signal.default_int_handler(signum, frame)

    def shutdown(self) -> None:
        """Idempotent graceful shutdown: close fetcher, flush graph, close bus.

        Safe to call multiple times — second calls are no-ops.
        """
        import asyncio

        if self._fetcher is not None:
            with contextlib.suppress(Exception):
                loop = asyncio.get_event_loop()
                if loop.is_running():
                    asyncio.ensure_future(self._fetcher.close())
                else:
                    loop.run_until_complete(self._fetcher.close())

        if self._graph is not None:
            with contextlib.suppress(Exception):
                self._graph.close()

        if self._event_bus is not None:
            with contextlib.suppress(Exception):
                self._event_bus.close()

    # ------------------------------------------------------------------
    # Async shutdown (for asyncio lifespan contexts)
    # ------------------------------------------------------------------

    async def ashutdown(self) -> None:
        """Async variant of shutdown — close fetcher's HTTP client properly."""
        if self._fetcher is not None:
            with contextlib.suppress(Exception):
                await self._fetcher.close()

        if self._graph is not None:
            with contextlib.suppress(Exception):
                self._graph.close()

        if self._event_bus is not None:
            with contextlib.suppress(Exception):
                self._event_bus.close()
