"""Shared test fixtures and helpers."""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import pytest

from knowledge_compiler.di import Container
from knowledge_compiler.graph.store import GraphStore
from knowledge_compiler.telemetry import EventBus, EventUpcaster, EventV1, EventV2


@pytest.fixture
def event_bus() -> EventBus:
    bus = EventBus(enabled=True)
    yield bus
    bus.close()


@pytest.fixture
def upcaster() -> EventUpcaster:
    return EventUpcaster()


@pytest.fixture
def graph_store(event_bus: EventBus) -> GraphStore:
    store = GraphStore(event_bus=event_bus, max_nodes=None, node_ttl_seconds=None)
    yield store
    store.close()


@pytest.fixture
def persistent_graph() -> Any:
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = Path(f.name)
    bus = EventBus(enabled=True)
    store = GraphStore(db_path=db_path, event_bus=bus)
    yield store
    store.close()
    bus.close()
    db_path.unlink(missing_ok=True)


@pytest.fixture
def bounded_graph(event_bus: EventBus) -> GraphStore:
    store = GraphStore(event_bus=event_bus, max_nodes=5, node_ttl_seconds=None)
    yield store
    store.close()


@pytest.fixture
def ttl_graph(event_bus: EventBus) -> GraphStore:
    store = GraphStore(event_bus=event_bus, max_nodes=None, node_ttl_seconds=3600)
    yield store
    store.close()
