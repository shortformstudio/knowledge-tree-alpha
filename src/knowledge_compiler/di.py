"""Dependency-injection container for porous modularity.

Every subsystem receives its dependencies through a single container
rather than reaching into global state.  This preserves the invariant that
components are independently testable and replaceable.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from .config import CompilerConfig

if TYPE_CHECKING:
    from .graph.store import GraphStore
    from .ingestion.crawler import Crawler
    from .ingestion.fetcher import Fetcher
    from .ingestion.parser import Parser
    from .semantic.compiler import SemanticCompiler
    from .social.profiler import SocialProfiler
    from .telemetry import EventBus


@dataclass(slots=True)
class Container:
    """Centralised wiring point.

    Modules are instantiated lazily via properties so that optional
    subsystems (telemetry) are created only when enabled.
    """

    config: CompilerConfig

    _graph: GraphStore | None = field(default=None, init=False)
    _fetcher: Fetcher | None = field(default=None, init=False)
    _parser: Parser | None = field(default=None, init=False)
    _crawler: Crawler | None = field(default=None, init=False)
    _semantic: SemanticCompiler | None = field(default=None, init=False)
    _social: SocialProfiler | None = field(default=None, init=False)
    _event_bus: EventBus | None = field(default=None, init=False)

    @property
    def event_bus(self) -> EventBus:
        if self._event_bus is None:
            from .telemetry import EventBus  # deferred import to avoid circularity

            self._event_bus = EventBus(enabled=self.config.telemetry_enabled)
        return self._event_bus

    @property
    def graph(self) -> GraphStore:
        if self._graph is None:
            from .graph.store import GraphStore

            self._graph = GraphStore(
                db_path=self.config.graph_db_path,
                event_bus=self.event_bus,
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
