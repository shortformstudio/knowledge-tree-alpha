"""Observable event bus with strict version routing and upcasting.

Every subsystem emits structured events through this bus. Consumers subscribe
to versioned event types and receive notifications with guaranteed schema
compatibility. An upcaster at the ingestion boundary translates legacy events
into the current system schema before processing.

Invariants
----------
- Every event carries a unique ``id`` (UUID4), a ``version`` tag, and a
  monotonic ``sequence`` counter.
- The bus routes by versioned type (e.g. ``"graph:edge_added:v2"``) so
  consumers only receive schema-compatible payloads.
- Legacy format listeners registered without a version suffix receive
  upcasted events automatically at the dispatch boundary.
- Listener failures are captured and surfaced via an error log handler
  instead of being silently discarded.
- When ``enabled=False``, all methods are no-ops with zero allocation.
"""

from __future__ import annotations

import contextlib
import logging
import uuid
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

_LISTENER_ERROR_LOGGER = logging.getLogger("knowledge_compiler.telemetry")

Listener = Callable[["EventV2"], None]
LegacyListener = Callable[["EventV1"], None]


# ------------------------------------------------------------------
# Versioned event schemas
# ------------------------------------------------------------------


@dataclass(slots=True, frozen=True)
class EventV1:
    """Legacy event envelope (pre-versioning era).

    Retained for backward compatibility.  All legacy subscribers receive
    events in this shape through the automatic upcasting layer.
    """

    type: str
    source: str
    payload: dict[str, Any] = field(default_factory=dict)
    timestamp: str = field(
        default_factory=lambda: datetime.now(UTC).isoformat(timespec="milliseconds")
    )


@dataclass(slots=True, frozen=True)
class EventV2:
    """Current event envelope with versioning and idempotency guards.

    Fields
    ------
    type : str
        Unversioned category (e.g. ``"crawl:node_visited"``).
    version : str
        Schema version tag (e.g. ``"v2"``).
    source : str
        Qualified module name that emitted the event.
    payload : dict[str, Any]
        Structured event data.
    event_id : str
        Unique UUID4 identifier for deduplication and tracing.
    sequence : int
        Monotonic sequence counter assigned by the bus at emit time.
    timestamp : str
        ISO-8601 UTC timestamp with millisecond precision.
    """

    type: str
    version: str
    source: str
    payload: dict[str, Any] = field(default_factory=dict)
    event_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    sequence: int = 0
    timestamp: str = field(
        default_factory=lambda: datetime.now(UTC).isoformat(timespec="milliseconds")
    )


# ------------------------------------------------------------------
# Upcaster — legacy EventV1 → EventV2 translation
# ------------------------------------------------------------------


class EventUpcaster:
    """Translates legacy EventV1 payloads into the current EventV2 schema.

    Installation
    ------------
    >>> upcaster = EventUpcaster()
    >>> bus = EventBus(upcaster=upcaster)
    >>> bus.emit_legacy(event_v1)  # automatically upcasted before dispatch

    Extend this class with version-specific field mappers when schema
    evolution introduces breaking changes.
    """

    VERSION_MAP: dict[str, str] = {
        "fetch:start": "v1",
        "fetch:success": "v1",
        "fetch:timeout": "v1",
        "fetch:error": "v1",
        "crawl:start": "v1",
        "crawl:node_visited": "v1",
        "crawl:skip": "v1",
        "crawl:complete": "v1",
        "graph:node_added": "v1",
        "graph:edge_added": "v1",
        "semantic:triplets_extracted": "v1",
        "social:compile_start": "v1",
        "social:compile_complete": "v1",
    }

    CURRENT_VERSION: str = "v2"

    def upcast(self, event: EventV1) -> EventV2:
        """Translate a legacy event to the current schema.

        Override in subclasses to apply field-level transformations
        when the schema evolves.
        """
        version = self.VERSION_MAP.get(event.type, "v1")
        return EventV2(
            type=event.type,
            version=version,
            source=event.source,
            payload=event.payload,
            timestamp=event.timestamp,
        )


# ------------------------------------------------------------------
# EventBus — versioned publish–subscribe dispatcher
# ------------------------------------------------------------------


class EventBus:
    """Versioned publish–subscribe dispatcher with observability and upcasting.

    Parameters
    ----------
    enabled : bool
        When ``False``, the bus short-circuits to avoid overhead.
    upcaster : EventUpcaster | None
        Translator for legacy EventV1 → EventV2.  When ``None``, legacy
        events are dispatched as v1 directly to legacy listeners only.
    history_limit : int
        Maximum events retained in the in-memory ring buffer.
    """

    __slots__ = (
        "_enabled",
        "_listeners",
        "_legacy_listeners",
        "_history",
        "_sequence",
        "_upcaster",
        "_history_limit",
    )

    DEFAULT_HISTORY_LIMIT: int = 500

    def __init__(
        self,
        enabled: bool = True,
        upcaster: EventUpcaster | None = None,
        history_limit: int = DEFAULT_HISTORY_LIMIT,
    ) -> None:
        self._enabled: bool = enabled
        self._listeners: dict[str, list[Listener]] = defaultdict(list)
        self._legacy_listeners: dict[str, list[LegacyListener]] = defaultdict(list)
        self._history: list[EventV2] = []
        self._sequence: int = 0
        self._upcaster = upcaster or EventUpcaster()
        self._history_limit = history_limit

    # ------------------------------------------------------------------
    # Public subscription API
    # ------------------------------------------------------------------

    def on(self, event_type: str, listener: Listener) -> None:
        """Subscribe to all events of *event_type* (any version).

        The listener receives EventV2 instances.  Events emitted via
        the legacy path are automatically upcasted before dispatch.

        To subscribe to a specific version, include the version tag:
        ``bus.on("graph:edge_added:v2", handler)``.
        """
        if self._enabled:
            self._listeners[event_type].append(listener)

    def on_legacy(self, event_type: str, listener: LegacyListener) -> None:
        """Subscribe to *event_type* in legacy EventV1 format.

        These listeners receive the original EventV1 without upcasting.
        """
        if self._enabled:
            self._legacy_listeners[event_type].append(listener)

    def off(self, event_type: str, listener: Listener | LegacyListener) -> None:
        """Remove a previously registered listener."""
        import contextlib as _cl

        if not self._enabled:
            return
        if event_type in self._listeners:
            with _cl.suppress(ValueError):
                self._listeners[event_type].remove(listener)  # type: ignore[arg-type]
        if event_type in self._legacy_listeners:
            with _cl.suppress(ValueError):
                self._legacy_listeners[event_type].remove(listener)  # type: ignore[arg-type]

    # ------------------------------------------------------------------
    # Emission API
    # ------------------------------------------------------------------

    def emit(
        self,
        event_type: str,
        source: str,
        payload: dict[str, Any] | None = None,
        *,
        version: str = "v2",
    ) -> None:
        """Publish a versioned event to all matching listeners.

        Complexity: O(L) where L is the listener count for the matching
        event type + its versioned form.  When disabled, O(1).
        """
        if not self._enabled:
            return

        self._sequence += 1
        event = EventV2(
            type=event_type,
            version=version,
            source=source,
            payload=payload or {},
            sequence=self._sequence,
        )

        self._append_history(event)
        self._dispatch(event)

    def emit_legacy(
        self, event_type: str, source: str, payload: dict[str, Any] | None = None
    ) -> None:
        """Emit an event in legacy format, automatically upcasting for v2 listeners."""
        if not self._enabled:
            return

        legacy = EventV1(type=event_type, source=source, payload=payload or {})

        for legacy_listener in self._legacy_listeners.get(event_type, ()):
            with _suppress_and_log(f"legacy listener for '{event_type}'"):
                legacy_listener(legacy)

        upcasted = self._upcaster.upcast(legacy)
        upcasted = EventV2(
            type=upcasted.type,
            version=upcasted.version,
            source=upcasted.source,
            payload=upcasted.payload,
            event_id=upcasted.event_id,
            sequence=self._sequence + 1,
            timestamp=upcasted.timestamp,
        )
        self._sequence += 1

        self._append_history(upcasted)
        self._dispatch(upcasted)

    # ------------------------------------------------------------------
    # History / observability
    # ------------------------------------------------------------------

    def snapshot(self, limit: int = 50) -> list[EventV2]:
        """Return the N most recent events from the ring buffer."""
        return self._history[-limit:]

    def clear_history(self) -> None:
        self._history.clear()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def close(self) -> None:
        """Teardown the bus: clears listeners, history, and resets sequence.

        Call this before the owning process exits to release references
        held by subscriber closures.
        """
        self._listeners.clear()
        self._legacy_listeners.clear()
        self._history.clear()
        self._sequence = 0

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _append_history(self, event: EventV2) -> None:
        self._history.append(event)
        if len(self._history) > self._history_limit:
            overflow = len(self._history) - self._history_limit
            del self._history[:overflow]

    def _dispatch(self, event: EventV2) -> None:
        versioned_type = f"{event.type}:{event.version}"

        for listener in self._listeners.get(versioned_type, ()):
            with _suppress_and_log(f"listener for '{versioned_type}'"):
                listener(event)

        for listener in self._listeners.get(event.type, ()):
            with _suppress_and_log(f"listener for '{event.type}'"):
                listener(event)

    @property
    def listener_count(self) -> int:
        """Total registered listeners (both v2 and legacy)."""
        v2_total = sum(len(v) for v in self._listeners.values())
        legacy_total = sum(len(v) for v in self._legacy_listeners.values())
        return v2_total + legacy_total

    @property
    def history_length(self) -> int:
        """Current number of events in the history buffer."""
        return len(self._history)

    @property
    def sequence(self) -> int:
        """Last assigned sequence number."""
        return self._sequence


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------


@contextlib.contextmanager
def _suppress_and_log(context_label: str) -> Any:
    """Context manager that logs and suppresses listener exceptions."""
    try:
        yield
    except Exception:
        _LISTENER_ERROR_LOGGER.exception("EventBus listener failure in %s", context_label)


def create_event_bus(
    enabled: bool = True,
    upcaster: EventUpcaster | None = None,
) -> EventBus:
    return EventBus(enabled=enabled, upcaster=upcaster)
