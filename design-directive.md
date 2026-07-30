# Design Directive: Event Architecture & Memory Management

## 1. Executive Summary

A comprehensive audit and remediation of the Knowledge Compiler codebase identified two systemic deficiency classes: **absence of event versioning and routing** (every event type was a flat string with no schema version, no idempotency, and silently discarded listener failures), and **multiple memory-retention and allocation pathologies** (per-request HTTP client teardown, per-mutation SQLite commits, unbounded NetworkX graph growth, and no lifecycle teardown for the event bus).

58 tests now pass (up from 0). The test suite spans:
- EventBus version routing with strict `event_type:vN` segmentation and auto-upcast at the `emit_legacy` boundary
- GraphStore with max-node and TTL eviction, batched SQLite persistence
- Fetcher with shared connection pooling across requests
- End-to-end crawl → graph → query workflow
- Memory stress tests asserting plateau behavior under sustained load

The system is now clean under `mypy --strict` and `ruff` with zero warnings.

---

## 2. Root Cause Analysis (RCA)

### 2.1 Event Versioning Failures

| Issue | Location | Impact |
|-------|----------|--------|
| No version field on `Event` dataclass | `telemetry/__init__.py:26` (ex-`Event`) | Zero version awareness; consumers received unknown payload shapes silently |
| Listener exceptions silently suppressed | `telemetry/__init__.py:99-101` (ex-`_dispatch`) | Malformed payloads or typing errors vanished with no dead-letter queue or log |
| No event ID or sequence numbering | Absent entirely | Duplicate processing on retry; out-of-order race conditions undetectable |
| Flat event type routing (`"graph:edge_added"`) | `telemetry/__init__.py:68-75` (ex-`on`) | Consumers subscribed to unversioned type received all versions indiscriminately |
| No upcaster layer | Absent entirely | Legacy emitters could not interoperate with updated consumers |

### 2.2 Memory Bloat & Leaks

| Issue | Location | Impact |
|-------|----------|--------|
| Per-request `httpx.AsyncClient` creation | `ingestion/fetcher.py:103-108` (ex-`_request`) | SSL context per request; HTTP/2 multiplexing wasted; no connection reuse |
| SQLite commit on every `add_node` call | `graph/store.py:153-157` (ex-`_persist_node`) | N pages → N WAL flushes; O(N) I/O instead of O(1) batch |
| Unbounded NetworkX DiGraph | `graph/store.py:43` (ex-`__init__`) | Nodes and edges accumulated across all sessions with no eviction or TTL |
| EventBus has no `close()` | `telemetry/__init__.py:44-120` (ex-`EventBus`) | Listener closures held indefinitely; no teardown contract |
| Ring buffer slice copy | `telemetry/__init__.py:95` (ex-`_append_history`) | New `list[-N:]` slice on every eviction threshold hit |
| Container lacks signal/atexit handler | `di.py` | Crashes left SQLite WAL journals unreclaimed |

---

## 3. Engineering Remediation & Code Changes

### 3.1 Event System Overhaul (`telemetry/__init__.py`)

**Before (excerpt):**
```python
@dataclass(slots=True, frozen=True)
class Event:
    type: str
    source: str
    payload: dict[str, Any] = field(default_factory=dict)
    timestamp: str = field(default_factory=lambda: datetime.now(UTC).isoformat(...))

class EventBus:
    def on(self, event_type: str, listener: Listener) -> None: ...
    def emit(self, event_type: str, source: str, payload=None) -> None:
        event = Event(type=event_type, source=source, payload=payload or {})
        self._history.append(event)
        for listener in self._listeners.get(event_type, ()):
            with contextlib.suppress(Exception):  # SILENT FAILURE
                listener(event)
```

**After (new invariants):**
```python
@dataclass(slots=True, frozen=True)
class EventV2:
    type: str
    version: str          # NEW: schema version tag
    source: str
    payload: dict[str, Any] = field(default_factory=dict)
    event_id: str = field(default_factory=lambda: uuid.uuid4().hex)  # NEW: idempotency
    sequence: int = 0     # NEW: monotonic ordering
    timestamp: str = ...

class EventUpcaster:
    CURRENT_VERSION: str = "v2"
    VERSION_MAP: dict[str, str] = {"crawl:start": "v1", "graph:node_added": "v1", ...}
    def upcast(self, event: EventV1) -> EventV2: ...

class EventBus:
    def on(self, event_type: str, listener: Listener) -> None:
        # "graph:edge_added" → all versions
        # "graph:edge_added:v2" → only v2

    def emit(self, event_type, source, payload=None, *, version="v2") -> None:
        event = EventV2(type=..., version=version, ..., sequence=self._sequence)
        self._dispatch(event)  # routes to versioned + unversioned subscribers

    def emit_legacy(self, event_type, source, payload=None) -> None:
        legacy = EventV1(...)
        # dispatch to legacy listeners directly
        upcasted = self._upcaster.upcast(legacy)
        self._dispatch(upcasted)

    def _dispatch(self, event: EventV2) -> None:
        versioned_type = f"{event.type}:{event.version}"
        for listener in self._listeners.get(versioned_type, ()):
            with _suppress_and_log(f"listener for '{versioned_type}'"):  # LOGS failures
                listener(event)
        for listener in self._listeners.get(event.type, ()):
            with _suppress_and_log(...):
                listener(event)
```

Key improvements:
- **Version routing**: `on("data:updated:v2", h)` receives only v2 events; `on("data:updated", h)` receives all versions
- **Upcaster boundary**: `emit_legacy` translates EventV1 → EventV2 before dispatching to v2 listeners
- **Idempotency**: `event_id` (UUID4 hex) + `sequence` (monotonic) on every event
- **Error visibility**: `_suppress_and_log` (a proper `@contextmanager`) logs stack traces instead of discarding them
- **Lifecycle**: `EventBus.close()` clears all listeners and history

### 3.2 Fetcher — Connection Pooling (`ingestion/fetcher.py`)

**Before:**
```python
async def _request(self, url: str) -> str | None:
    async with httpx.AsyncClient(...) as client:  # NEW CLIENT PER REQUEST
        response = await client.get(url)
```

**After:**
```python
async def _client_instance(self) -> httpx.AsyncClient:
    if self._client is None or self._client.is_closed:
        self._client = httpx.AsyncClient(..., http2=True)
    return self._client

async def _request(self, url: str) -> str | None:
    client = await self._client_instance()  # REUSED ACROSS REQUESTS
    response = await client.get(url)

async def close(self) -> None:
    if self._client is not None:
        await self._client.aclose()
        self._client = None
```

### 3.3 GraphStore — Batching + Eviction (`graph/store.py`)

**Batched SQLite persistence (instead of commit-per-mutation):**
```python
class GraphStore:
    _pending: list[tuple[str, dict[str, Any]]]  # NEW

    def add_node(self, node_id, **attrs) -> None:
        self._graph.add_node(node_id, **attrs)
        self._pending.append((node_id, attrs))  # DEFER
        self._evict_if_needed()

    def flush(self) -> None:
        """Persist all pending nodes in a single SQLite transaction."""
        with self._db:
            for node_id, attrs in self._pending:
                self._db.execute("INSERT OR REPLACE INTO nodes (...) VALUES (...)", ...)
        self._pending.clear()

    def close(self) -> None:
        self.flush()  # drain pending before closing
        self._db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self._db.close()
```

**Bounded growth with TTL eviction:**
```python
class GraphStore:
    def __init__(self, ..., max_nodes: int | None = None, node_ttl_seconds: float | None = None):
        ...

    def _evict_if_needed(self) -> None:
        if self._node_ttl is not None:
            cutoff = time.time() - self._node_ttl
            for node_id, attrs in list(self._graph.nodes(data=True)):
                if attrs.get("_added_at", 0.0) < cutoff:
                    evicted.add(node_id)

        if self._max_nodes is not None and self._graph.number_of_nodes() > self._max_nodes:
            nodes_by_age = sorted(self._graph.nodes(data=True), key=lambda x: x[1].get("_added_at", 0.0))
            evicted.update(nid for nid, _ in nodes_by_age[:overflow])
```

### 3.4 Container Lifecycle (`di.py`)

The Container now registers `atexit` and signal handlers for SIGINT/SIGTERM, providing an `ashutdown()` method for asyncio lifespan hooks. On shutdown, it closes the Fetcher (HTTP client), flushes and closes the GraphStore, and closes the EventBus — satisfying the full resource hierarchy in the correct order.

### 3.5 Configuration (`config.py`)

New fields:
```python
graph_max_nodes: int | None      # Hard ceiling on in-memory nodes
graph_node_ttl_seconds: float | None  # Maximum node age before eviction
memory_payload_streaming_threshold_bytes: int  # 1 MB default
```

---

## 4. End-to-End Verification & Benchmark Results

### 4.1 Test Suite Summary

```
58 passed in 2.04s
```

| Category | Tests | Coverage |
|----------|-------|----------|
| Telemetry (EventV2 schema, upcasting, subscription, idempotency, error isolation) | 18 | Event routing, version dispatch, legacy compat, listener isolation, disabled no-op |
| GraphStore (mutation, batching, bounded eviction, TTL eviction, properties) | 15 | SQLite persistence round-trips, max-node plateau, TTL eviction, multi-factor eviction |
| Integration (crawl pipeline, semantic compiler, social profiler, query engine) | 10 | Full crawl→graph→event flow, multi-version routing E2E, unsupported platform error paths |
| Memory (event bus under load, graph bounded growth, connection pooling, crawl stability) | 15 | 10K-emit plateau, bounded node count under 500-insert stress, shared client reuse, repeated crawl sessions |

### 4.2 Memory Stress Test Results

All memory tests assert plateau behavior:

| Test | Mechanism | Assertion |
|------|-----------|-----------|
| `test_history_stable_under_load` | 10,000 emits → ring buffer caps at 500 | Post-cleanup allocation below threshold |
| `test_bounded_graph_plateaus` | 500 node inserts with max_nodes=100 | Node count precisely 100; oldest 400 evicted |
| `test_ttl_eviction_releases_all_stale` | 200 nodes with TTL=0.1s, all with _added_at=1.0 | All 200 evicted; node_count == 0 |
| `test_large_content_still_bounded` | 50 inserts, each 100KB, max_nodes=10 | Node count stays 10; large buffer memory reclaimed by GC |
| `test_shared_client_reuse` | Two calls to `_client_instance()` | Same object identity; no new SSL contexts |
| `test_repeated_crawls_memory_stable` | 3 sequential crawl sessions, history cleared between | Final allocation within threshold of baseline |

### 4.3 Pre-Refactor vs. Post-Refactor Comparison

| Metric | Pre-Refactor | Post-Refactor |
|--------|-------------|---------------|
| Event version awareness | None (flat `type` strings) | `version` field + versioned routing (`type:vN`) |
| Event idempotency | None | `event_id` (UUID4) + `sequence` |
| Listener error visibility | Silent (`suppress(Exception)`) | Logged with traceback (`_suppress_and_log`) |
| HTTP connection reuse | New `AsyncClient` per request | Shared client with HTTP/2 multiplexing |
| SQLite efficiency | 1 commit per graph mutation | Batched single-transaction flush |
| Graph memory bound | Unbounded (`nx.DiGraph` grows forever) | `max_nodes` + `node_ttl_seconds` eviction |
| EventBus teardown | None | `close()` clears listeners + history |
| Process shutdown | No signal/atexit handling | `atexit` + SIGINT/SIGTERM → full resource drain |
| Test coverage | 0 tests | 58 tests (telemetry, graph, integration, memory) |

---

## 5. Future Architectural Invariants & Mandatory Rules

### 5.1 Event Schema Evolution

1. **New event versions require a version bump and an upcaster entry.** When adding a breaking change to an event payload, increment the version tag (e.g., `v2` → `v3`) and add a corresponding entry in `EventUpcaster.VERSION_MAP` and a `_upcast_v2_to_v3` transformation method.

2. **Versioned subscription is the default.** All new consumers *must* subscribe with a version tag: `bus.on("graph:edge_added:v3", handler)`. The unversioned wildcard `bus.on("graph:edge_added", handler)` is reserved for cross-cutting listeners (monitoring, logging) that explicitly tolerate any schema.

3. **Every event payload dict must be flat.** Nested dicts or lists of dicts in event payloads are prohibited — they prevent consumers from safely accessing fields across versions. Use top-level keys with scalar or list-of-scalar values only.

4. **Deprecation schedule.** When a version $V_{N-1}$ is superseded by $V_N$, legacy emitters have 2 release cycles to migrate. After the deprecation window, the upcaster entry for $V_{N-1}$ is removed, and `emit_legacy` for that type raises a deprecation warning.

### 5.2 Memory Budgeting

1. **Streaming threshold.** Any operation loading more than `memory_payload_streaming_threshold_bytes` (default 1 MB) of data into a single Python object must use buffered streaming or pagination. The GraphStore's `ego_subgraph` and `bfs_neighbors` are exempted for bounded-radius queries but must document the worst-case payload size.

2. **Cache bounds mandatory.** Every in-memory cache or collection must have an explicit upper bound (`max_nodes`, TTL, or LRU capacity). Unbounded caches will not pass review.

3. **Lifecycle teardown contract.** Every component that allocates external resources (HTTP clients, DB connections, file handles) *must* expose an `async close()` or `close()` method and be registered in the Container's `ashutdown()` / `shutdown()` sequence. The teardown order is: Fetcher → GraphStore → EventBus (dependency-first).

4. **Connection pooling.** No component may create a `httpx.AsyncClient` (or any TCP connection) per request. Use the shared `Fetcher._client_instance()` pattern.

5. **SQLite batching.** Individual graph mutations must not trigger SQLite commits. Nodes are batched via `_pending` and flushed at crawl completion, `SocialProfiler` completion, or `GraphStore.close()`. Edge persistence (currently per-edge) should be migrated to the same batch model in a follow-up.

### 5.3 Testing

1. **Every new event type and version requires a version-routing test** following the pattern in `tests/test_integration.py::TestEventVersionRoutingE2E`.

2. **Every new bounded cache requires a plateau test** following the pattern in `tests/test_memory.py::TestGraphStoreMemoryBounded`.

3. **Regression baseline.** All 58 tests must pass on every commit. Add `pytest` to the CI pipeline.
