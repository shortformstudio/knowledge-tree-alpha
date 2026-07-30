"""Async HTTP fetcher with connection pooling and domain-aware rate limiting.

Guarantees
----------
- A single shared ``httpx.AsyncClient`` reuses TCP connections (HTTP/2
  multiplexing) across all requests during the fetcher's lifetime.
- Concurrent requests capped by an asyncio Semaphore (O(1) acquisition).
- Per-domain minimum inter-request interval via a lock-backed dictionary,
  bounding the request rate at the configured ``rate_limit_rps``.
- All timeouts are hardware-triggered (``httpx.Timeout``), preventing
  resource leaks from hung connections.
"""

from __future__ import annotations

import asyncio
import time
from urllib.parse import urlparse

import httpx

from ..telemetry import EventBus


class Fetcher:
    """Rate-limited asynchronous HTTP fetcher with connection pooling.

    Parameters
    ----------
    user_agent : str
        ``User-Agent`` header value.
    timeout : float
        Per-request timeout in seconds.
    rate_limit_rps : float
        Minimum interval (seconds) between requests to the same domain.
    concurrency : int
        Maximum simultaneous in-flight requests.
    event_bus : EventBus
        Telemetry sink for connection lifecycle events.
    """

    __slots__ = (
        "_user_agent",
        "_timeout",
        "_rate_interval",
        "_semaphore",
        "_last_request",
        "_lock",
        "_event_bus",
        "_client",
    )

    def __init__(
        self,
        user_agent: str,
        timeout: float,
        rate_limit_rps: float,
        concurrency: int,
        event_bus: EventBus,
    ) -> None:
        self._user_agent = user_agent
        self._timeout = timeout
        self._rate_interval = 1.0 / rate_limit_rps if rate_limit_rps > 0 else 0.0
        self._semaphore = asyncio.Semaphore(concurrency)
        self._last_request: dict[str, float] = {}
        self._lock = asyncio.Lock()
        self._event_bus = event_bus
        self._client: httpx.AsyncClient | None = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def fetch(self, url: str) -> str | None:
        """Fetch *url* and return its HTML body, or ``None`` on failure."""
        domain = urlparse(url).netloc
        await self._throttle(domain)

        async with self._semaphore:
            return await self._request(url)

    async def close(self) -> None:
        """Close the shared HTTP client, releasing pooled connections."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    async def _client_instance(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                headers={"User-Agent": self._user_agent},
                timeout=httpx.Timeout(self._timeout),
                follow_redirects=True,
                http2=True,
            )
        return self._client

    async def _throttle(self, domain: str) -> None:
        if self._rate_interval <= 0:
            return

        async with self._lock:
            now = time.monotonic()
            last = self._last_request.get(domain, 0.0)
            wait = self._rate_interval - (now - last)
            if wait > 0:
                await asyncio.sleep(wait)
                now = time.monotonic()
            self._last_request[domain] = now

    async def _request(self, url: str) -> str | None:
        self._event_bus.emit("fetch:start", "Fetcher", {"url": url}, version="v2")
        try:
            client = await self._client_instance()
            response = await client.get(url)
            if response.status_code == 200:
                self._event_bus.emit(
                    "fetch:success",
                    "Fetcher",
                    {"url": url, "bytes": len(response.content)},
                    version="v2",
                )
                return response.text
            self._event_bus.emit(
                "fetch:error",
                "Fetcher",
                {"url": url, "status": response.status_code},
                version="v2",
            )
            return None
        except httpx.TimeoutException:
            self._event_bus.emit("fetch:timeout", "Fetcher", {"url": url}, version="v2")
            return None
        except Exception as exc:
            self._event_bus.emit(
                "fetch:error",
                "Fetcher",
                {"url": url, "error": type(exc).__name__},
                version="v2",
            )
            return None
