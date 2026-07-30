"""Tests for the versioned EventBus, upcaster, and event lifecycle."""

from __future__ import annotations

import uuid

from knowledge_compiler.telemetry import (
    EventBus,
    EventUpcaster,
    EventV1,
    EventV2,
    create_event_bus,
)


class TestEventV2Schema:
    """Verify EventV2 carries versioning and idempotency fields."""

    def test_event_v2_defaults(self) -> None:
        event = EventV2(
            type="test:event",
            version="v2",
            source="TestModule",
            payload={"key": "val"},
        )
        assert event.type == "test:event"
        assert event.version == "v2"
        assert event.source == "TestModule"
        assert event.payload == {"key": "val"}
        assert len(event.event_id) == 32
        uuid.UUID(hex=event.event_id)
        assert event.sequence == 0
        assert event.timestamp.endswith("Z") or "+" in event.timestamp

    def test_event_v2_custom_id(self) -> None:
        custom_id = uuid.uuid4().hex
        event = EventV2(
            type="test:event",
            version="v2",
            source="Test",
            event_id=custom_id,
        )
        assert event.event_id == custom_id

    def test_event_v2_immutable(self) -> None:
        event = EventV2(type="test:event", version="v2", source="Test")
        with __import__("pytest").raises(Exception):
            event.payload = {"bad"}  # type: ignore[misc]


class TestEventUpcaster:
    """Verify EventV1 → EventV2 translation."""

    def test_upcast_preserves_fields(self, upcaster: EventUpcaster) -> None:
        v1 = EventV1(type="crawl:start", source="Crawler", payload={"url": "https://x.com"})
        v2 = upcaster.upcast(v1)
        assert v2.type == "crawl:start"
        assert v2.source == "Crawler"
        assert v2.payload == {"url": "https://x.com"}
        assert v2.timestamp == v1.timestamp

    def test_upcast_assigns_known_versions(self, upcaster: EventUpcaster) -> None:
        v1 = EventV1(type="graph:node_added", source="GraphStore", payload={})
        v2 = upcaster.upcast(v1)
        assert v2.version == "v1"

    def test_upcast_unknown_event_defaults_to_v1(self, upcaster: EventUpcaster) -> None:
        v1 = EventV1(type="unknown:event_type", source="?", payload={})
        v2 = upcaster.upcast(v1)
        assert v2.version == "v1"


class TestEventBusSubscription:
    """Verify versioned and legacy subscription mechanics."""

    def test_on_receives_events(self, event_bus: EventBus) -> None:
        received: list[EventV2] = []

        def handler(e: EventV2) -> None:
            received.append(e)

        event_bus.on("test:event", handler)
        event_bus.emit("test:event", "TestSrc", {"a": 1}, version="v2")
        assert len(received) == 1
        assert received[0].payload == {"a": 1}

    def test_versioned_subscription_routes_strictly(self, event_bus: EventBus) -> None:
        v2_received: list[EventV2] = []
        v3_received: list[EventV2] = []
        any_received: list[EventV2] = []

        event_bus.on("test:event:v2", v2_received.append)
        event_bus.on("test:event:v3", v3_received.append)
        event_bus.on("test:event", any_received.append)

        event_bus.emit("test:event", "Src", {}, version="v2")

        assert len(v2_received) == 1
        assert len(v3_received) == 0
        assert len(any_received) == 1

    def test_unversioned_subscription_receives_all_versions(self, event_bus: EventBus) -> None:
        received: list[EventV2] = []

        event_bus.on("test:event", received.append)
        event_bus.emit("test:event", "Src", {}, version="v2")
        event_bus.emit("test:event", "Src", {}, version="v3")
        assert len(received) == 2

    def test_off_removes_listener(self, event_bus: EventBus) -> None:
        received: list[EventV2] = []

        event_bus.on("test:event", received.append)
        event_bus.emit("test:event", "Src", {}, version="v2")
        assert len(received) == 1

        event_bus.off("test:event", received.append)
        event_bus.emit("test:event", "Src", {}, version="v2")
        assert len(received) == 1

    def test_off_nonexistent_listener_no_error(self, event_bus: EventBus) -> None:
        def dummy(_e: EventV2) -> None:
            pass

        event_bus.off("nonexistent", dummy)
        event_bus.off("test:event", dummy)

    def test_listener_count(self, event_bus: EventBus) -> None:
        assert event_bus.listener_count == 0
        event_bus.on("test:event", lambda e: None)
        assert event_bus.listener_count == 1
        event_bus.on("test:event:v2", lambda e: None)
        assert event_bus.listener_count == 2


class TestEventBusLegacyCompat:
    """Verify emit_legacy → upcast → dispatch pathway."""

    def test_emit_legacy_upcasts_and_dispatches(self) -> None:
        bus = EventBus(enabled=True)
        v2_received: list[EventV2] = []
        legacy_received: list[EventV1] = []

        bus.on("crawl:start", v2_received.append)
        bus.on_legacy("crawl:start", legacy_received.append)
        bus.emit_legacy("crawl:start", "Crawler", {"url": "https://x.com"})

        assert len(v2_received) == 1
        assert len(legacy_received) == 1
        assert v2_received[0].version == "v1"
        assert legacy_received[0].type == "crawl:start"
        bus.close()


class TestEventBusLifecycle:
    """Verify close() clears state."""

    def test_close_clears_listeners(self, event_bus: EventBus) -> None:
        event_bus.on("test:event", lambda e: None)
        assert event_bus.listener_count == 1
        event_bus.close()
        assert event_bus.listener_count == 0

    def test_close_clears_history(self) -> None:
        bus = EventBus(enabled=True)
        bus.emit("test:event", "Src", {}, version="v2")
        assert bus.history_length == 1
        bus.close()
        assert bus.history_length == 0


class TestEventBusIdempotency:
    """Verify sequence numbers and event_id uniqueness."""

    def test_monotonic_sequence(self, event_bus: EventBus) -> None:
        events: list[EventV2] = []

        event_bus.on("test:event", events.append)
        for i in range(5):
            event_bus.emit("test:event", "Src", {"seq": i}, version="v2")

        sequences = [e.sequence for e in events]
        assert sequences == [1, 2, 3, 4, 5]

    def test_unique_event_ids(self, event_bus: EventBus) -> None:
        events: list[EventV2] = []

        event_bus.on("test:event", events.append)
        for _ in range(10):
            event_bus.emit("test:event", "Src", {}, version="v2")

        ids = {e.event_id for e in events}
        assert len(ids) == 10


class TestEventBusHistory:
    """Verify ring buffer behavior."""

    def test_history_truncates(self) -> None:
        bus = EventBus(enabled=True, history_limit=10)
        for i in range(20):
            bus.emit("test:event", "Src", {"i": i}, version="v2")
        assert bus.history_length == 10
        snap = bus.snapshot()
        assert len(snap) == 10
        bus.close()

    def test_snapshot_respects_limit(self, event_bus: EventBus) -> None:
        for i in range(5):
            event_bus.emit("test:event", "Src", {"i": i}, version="v2")
        assert len(event_bus.snapshot(limit=3)) == 3
        assert len(event_bus.snapshot(limit=100)) == 5


class TestEventBusDisabled:
    """Verify no-op mode."""

    def test_disabled_bus_no_allocations(self) -> None:
        bus = EventBus(enabled=False)
        bus.on("test:event", lambda e: None)
        bus.emit("test:event", "Src", {}, version="v2")
        assert bus.listener_count == 0
        assert bus.history_length == 0
        bus.close()


class TestListenerErrorIsolation:
    """Verify that a failing listener does not prevent other listeners."""

    def test_failing_listener_isolated(self, event_bus: EventBus) -> None:
        healthy_received: list[EventV2] = []

        def bad_handler(_e: EventV2) -> None:
            raise RuntimeError("intentional failure")

        def good_handler(e: EventV2) -> None:
            healthy_received.append(e)

        event_bus.on("test:event", bad_handler)
        event_bus.on("test:event", good_handler)
        event_bus.emit("test:event", "Src", {}, version="v2")

        assert len(healthy_received) == 1


class TestCreateEventBus:
    def test_factory_defaults(self) -> None:
        bus = create_event_bus()
        assert bus.listener_count == 0
        bus.close()

    def test_factory_disabled(self) -> None:
        bus = create_event_bus(enabled=False)
        assert bus.listener_count == 0
        bus.close()
