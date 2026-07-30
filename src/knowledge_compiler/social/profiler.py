"""Social media profiler — scrapes public feeds to compile a dossier.

Supports Twitter/X (via Nitter), GitHub (via public API), and generic
RSS feed ingestion.  Extracted posts are stored as graph nodes linked
to the profile entity.

Invariants
----------
- Every post node carries ``type="social_post"`` and ``author=<handle>``.
- The profile node itself carries ``type="social_profile"``.
- Post count is bounded by ``max_posts`` to prevent runaway ingestion.
"""

from __future__ import annotations

from typing import Any

from bs4 import BeautifulSoup

from ..graph.store import GraphStore
from ..ingestion.fetcher import Fetcher
from ..ingestion.parser import Parser
from ..telemetry import EventBus

PLATFORM_SCRAPERS: dict[str, str] = {
    "twitter": "https://nitter.net/{handle}",
    "x": "https://nitter.net/{handle}",
    "github": "https://github.com/{handle}",
    "reddit": "https://old.reddit.com/user/{handle}/submitted",
}


class SocialProfiler:
    """Scrapes public social-media profiles and compiles structured dossiers.

    Parameters
    ----------
    fetcher : Fetcher
        Rate-limited HTTP fetcher.
    parser : Parser
        HTML parser (used for generic page extraction).
    graph : GraphStore
        Knowledge graph to populate with profile and post nodes.
    max_posts : int
        Hard ceiling on posts extracted per profile.
    event_bus : EventBus
        Telemetry sink.
    """

    __slots__ = ("_fetcher", "_parser", "_graph", "_max_posts", "_event_bus")

    def __init__(
        self,
        fetcher: Fetcher,
        parser: Parser,
        graph: GraphStore,
        max_posts: int,
        event_bus: EventBus,
    ) -> None:
        self._fetcher = fetcher
        self._parser = parser
        self._graph = graph
        self._max_posts = max_posts
        self._event_bus = event_bus

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def compile(
        self,
        handle: str,
        platform: str = "twitter",
    ) -> dict[str, Any]:
        """Scrape *handle* on *platform* and return a structured dossier.

        Parameters
        ----------
        handle : str
            Social-media handle (with or without leading ``@``).
        platform : str
            One of ``"twitter"``, ``"x"``, ``"github"``, ``"reddit"``.

        Returns
        -------
        dict with keys ``handle``, ``platform``, ``core_teachings``,
        ``extracted_themes``, and ``post_count``.
        """
        clean_handle = handle.lstrip("@")
        dossier: dict[str, Any] = {
            "handle": clean_handle,
            "platform": platform,
            "core_teachings": [],
            "extracted_themes": [],
            "post_count": 0,
        }

        self._event_bus.emit(
            "social:compile_start",
            "SocialProfiler",
            {"handle": clean_handle, "platform": platform},
            version="v2",
        )

        profile_node_id = f"profile_{platform}_{clean_handle}"
        self._graph.add_node(
            node_id=profile_node_id,
            type="social_profile",
            content=f"{clean_handle} on {platform}",
            author=clean_handle,
        )

        template = PLATFORM_SCRAPERS.get(platform.lower())
        if template is None:
            dossier["error"] = f"Unsupported platform: {platform}"
            return dossier

        url = template.format(handle=clean_handle)
        html = await self._fetcher.fetch(url)
        if html is None:
            dossier["error"] = f"Failed to fetch profile page: {url}"
            return dossier

        posts = await self._extract_posts(html, platform, clean_handle)

        for text in posts[: self._max_posts]:
            dossier["core_teachings"].append(text)
            post_id = f"post_{hash(text) & 0x7FFFFFFF:08x}"
            self._graph.add_node(
                node_id=post_id,
                type="social_post",
                content=text,
                author=clean_handle,
            )
            self._graph.add_edge(
                source=profile_node_id,
                target=post_id,
                relation="declared_idea",
            )

        self._graph.flush()

        dossier["post_count"] = len(dossier["core_teachings"])

        self._event_bus.emit(
            "social:compile_complete",
            "SocialProfiler",
            {"handle": clean_handle, "post_count": dossier["post_count"]},
            version="v2",
        )

        return dossier

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    async def _extract_posts(
        self, html: str, platform: str, handle: str
    ) -> list[str]:
        """Platform-specific post extraction.

        Returns a list of post text strings.
        """
        soup = BeautifulSoup(html, "html.parser")
        posts: list[str] = []

        if platform in ("twitter", "x"):
            for div in soup.find_all("div", class_="tweet-content"):
                text = div.get_text(strip=True)
                if text and len(text) > 5:
                    posts.append(text)
        elif platform == "github":
            for div in soup.find_all("div", class_="pinned-item-list-item-content"):
                text = div.get_text(strip=True)
                if text:
                    posts.append(text)
        elif platform == "reddit":
            for div in soup.find_all("div", class_="md"):
                text = div.get_text(strip=True)
                if text:
                    posts.append(text)

        return posts
