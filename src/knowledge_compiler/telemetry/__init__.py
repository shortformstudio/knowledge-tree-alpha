"""Observable event bus for connective dynamics tracing.

Every subsystem emits structured events through this bus.  Consumers
(listeners) subscribe to event types and receive real-time notifications
of data flow between modules.  This makes the system's interactions
visible and inspectable.

Invariants
----------
- The bus is a non-blocking publish–subscribe dispatcher.
- Event emission is O(1) per listener (direct dispatch, no queue overhead).
- When ``enabled=False``, all methods are no-ops with zero allocation.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

Listener = Callable[["Event"], None]


@dataclass(slots=True, frozen=True)
class Event:
    """Immutable event envelope emitted across the bus."""

    type: str
    """Category tag (e.g. ``"crawl:node_visited"``, ``"graph:edge_added"``)."""

    source: str
    """Qualified module name that emitted the event."""

    payload: dict[str, Any] = field(default_factory=dict)
    """Arbitrary key-value data associated with the event."""

    timestamp: str = field(
        default_factory=lambda: datetime.now(UTC).isoformat(timespec="milliseconds")
    )


class EventBus:
    """Publish–subscribe dispatcher with optional observability.

    Parameters
    ----------
    enabled : bool
        When ``False``, the bus short-circuits all operations to avoid
        allocation and dispatch overhead in production deployments that
        do not require telemetry.
    """

    __slots__ = ("_enabled", "_listeners", "_history")

    MAX_HISTORY: int = 500

    def __init__(self, enabled: bool = True) -> None:
        self._enabled: bool = enabled
        self._listeners: dict[str, list[Listener]] = defaultdict(list)
        self._history: list[Event] = []

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def on(self, event_type: str, listener: Listener) -> None:
        """Subscribe *listener* to all events of *event_type*.

        Returns immediately; the listener runs synchronously during
        :meth:`emit`.
        """
        if self._enabled:
            self._listeners[event_type].append(listener)

    def off(self, event_type: str, listener: Listener) -> None:
        """Remove a previously registered *listener*."""
        if self._enabled and event_type in self._listeners:
            self._listeners[event_type].remove(listener)

    def emit(self, event_type: str, source: str, payload: dict[str, Any] | None = None) -> None:
        """Publish an event to all registered listeners of *event_type*.

        Complexity: O(L) where *L* is the number of listeners for that
        specific event type.  When disabled this is O(1) (early return).
        """
        if not self._enabled:
            return

        event = Event(type=event_type, source=source, payload=payload or {})

        self._history.append(event)
        if len(self._history) > self.MAX_HISTORY:
            self._history = self._history[-self.MAX_HISTORY :]

        import contextlib

        for listener in self._listeners.get(event_type, ()):
            with contextlib.suppress(Exception):
                listener(event)  # listener failures are non-fatal

    def snapshot(self, limit: int = 50) -> list[Event]:
        """Return the N most recent events from the internal ring buffer.

        Useful for dashboards and debugging panels.
        """
        return self._history[-limit:]

    def clear_history(self) -> None:
        """Reset the in-memory event log."""
        self._history.clear()


# ------------------------------------------------------------------
# Convenience factory for internal use
# ------------------------------------------------------------------

def create_event_bus(enabled: bool = True) -> EventBus:
    return EventBus(enabled=enabled)
