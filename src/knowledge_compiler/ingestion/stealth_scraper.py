"""Playwright-based stealth scraper for Threads and other platforms.

Uses Playwright with stealth plugin to mimic human browser behavior,
bypassing login walls and anti-bot detection where possible.
"""

from __future__ import annotations

import asyncio
import random
import re
from pathlib import Path
from typing import Optional

from playwright.async_api import async_playwright, Browser, BrowserContext, Page


class StealthScraper:
    """Human-like browser scraper using Playwright with stealth evasion."""

    # Realistic viewport sizes
    VIEWPORTS = [
        {"width": 1920, "height": 1080},
        {"width": 1440, "height": 900},
        {"width": 1536, "height": 864},
        {"width": 1366, "height": 768},
    ]

    # Real user agents (rotate)
    USER_AGENTS = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    ]

    def __init__(
        self,
        headless: bool = True,
        slow_mo: int = 50,
        proxy: Optional[str] = None,
        user_data_dir: Optional[str] = None,
    ) -> None:
        self._headless = headless
        self._slow_mo = slow_mo
        self._proxy = proxy
        self._user_data_dir = user_data_dir
        self._browser: Optional[Browser] = None
        self._context: Optional[BrowserContext] = None
        self._playwright = None

    async def __aenter__(self) -> "StealthScraper":
        await self.launch()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self.close()

    async def launch(self) -> None:
        """Launch browser with stealth configuration."""
        self._playwright = await async_playwright().start()

        launch_args = [
            "--disable-blink-features=AutomationControlled",
            "--disable-features=IsolateOrigins,site-per-process",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions-except",
            "--disable-plugins-discovery",
        ]

        self._browser = await self._playwright.chromium.launch(
            headless=self._headless,
            slow_mo=self._slow_mo,
            proxy={"server": self._proxy} if self._proxy else None,
            args=launch_args,
        )

        # Create context with realistic fingerprint
        viewport = random.choice(self.VIEWPORTS)
        user_agent = random.choice(self.USER_AGENTS)

        context_options = {
            "viewport": viewport,
            "user_agent": user_agent,
            "locale": "en-US",
            "timezone_id": "America/Los_Angeles",
            "color_scheme": "dark",
            "reduced_motion": "no-preference",
            "forced_colors": "none",
            "device_scale_factor": 2,
            "is_mobile": False,
            "has_touch": False,
            "java_script_enabled": True,
            "bypass_csp": True,
            "ignore_https_errors": True,
        }

        if self._user_data_dir:
            context_options["user_data_dir"] = self._user_data_dir

        self._context = await self._browser.new_context(**context_options)

        # Inject stealth scripts
        await self._inject_stealth_scripts()

    async def _inject_stealth_scripts(self) -> None:
        """Inject anti-detection scripts into all pages."""
        if not self._context:
            return

        stealth_script = """
        // Override navigator.webdriver
        Object.defineProperty(navigator, 'webdriver', {
            get: () => undefined,
        });

        // Override chrome runtime
        window.chrome = {
            runtime: {},
            loadTimes: function() {},
            csi: function() {},
            app: {}
        };

        // Override permissions
        const originalQuery = window.navigator.permissions.query;
        window.navigator.permissions.query = (parameters) => (
            parameters.name === 'notifications' ?
                Promise.resolve({ state: Notification.permission }) :
                originalQuery(parameters)
        );

        // Plugins length
        Object.defineProperty(navigator, 'plugins', {
            get: () => [1, 2, 3, 4, 5],
        });

        // Languages
        Object.defineProperty(navigator, 'languages', {
            get: () => ['en-US', 'en'],
        });

        // Platform
        Object.defineProperty(navigator, 'platform', {
            get: () => 'MacIntel',
        });

        // Hardware concurrency
        Object.defineProperty(navigator, 'hardwareConcurrency', {
            get: () => 8,
        });

        // Device memory
        Object.defineProperty(navigator, 'deviceMemory', {
            get: () => 8,
        });

        // WebGL vendor
        const getParameter = WebGLRenderingContext.prototype.getParameter;
        WebGLRenderingContext.prototype.getParameter = function(parameter) {
            if (parameter === 37445) return 'Intel Inc.';
            if (parameter === 37446) return 'Intel Iris OpenGL Engine';
            return getParameter.call(this, parameter);
        };

        // Canvas fingerprint noise
        const originalToDataURL = HTMLCanvasElement.prototype.toDataURL;
        HTMLCanvasElement.prototype.toDataURL = function(type) {
            const context = this.getContext('2d');
            if (context) {
                const noise = Math.random() * 0.0001;
                context.fillStyle = `rgba(${Math.random()*255},${Math.random()*255},${Math.random()*255},${noise})`;
                context.fillRect(0, 0, 1, 1);
            }
            return originalToDataURL.call(this, type);
        };
        """

        await self._context.add_init_script(stealth_script)

    async def new_page(self) -> Page:
        """Create a new page with human-like behavior."""
        if not self._context:
            raise RuntimeError("Browser not launched. Call launch() first.")

        page = await self._context.new_page()

        # Set realistic headers
        await page.set_extra_http_headers({
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
            "DNT": "1",
            "Connection": "keep-alive",
            "Upgrade-Insecure-Requests": "1",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-User": "?1",
            "Cache-Control": "max-age=0",
        })

        return page

    async def human_like_goto(
        self,
        page: Page,
        url: str,
        wait_until: str = "networkidle",
        timeout: int = 60000,
    ) -> None:
        """Navigate with human-like timing."""
        # Random pre-navigation delay
        await asyncio.sleep(random.uniform(0.5, 1.5))

        await page.goto(url, wait_until=wait_until, timeout=timeout)

        # Random post-load delay
        await asyncio.sleep(random.uniform(1.0, 2.5))

    async def human_like_scroll(
        self,
        page: Page,
        scrolls: int = 10,
        min_wait: float = 1.5,
        max_wait: float = 3.0,
    ) -> None:
        """Scroll with human-like behavior."""
        for i in range(scrolls):
            # Random scroll amount
            scroll_amount = random.randint(300, 800)
            await page.evaluate(f"window.scrollBy(0, {scroll_amount})")

            # Random pause with occasional longer pauses
            wait_time = random.uniform(min_wait, max_wait)
            if random.random() < 0.1:  # 10% chance of longer pause
                wait_time *= random.uniform(2, 4)
            await asyncio.sleep(wait_time)

            # Occasionally move mouse
            if random.random() < 0.3:
                await page.mouse.move(
                    random.randint(100, 1000),
                    random.randint(100, 700),
                    steps=random.randint(5, 15)
                )

    async def scrape_threads_profile(
        self,
        handle: str,
        max_posts: int = 50,
        headless: bool = True,
    ) -> list[str]:
        """Scrape Threads profile without login using stealth browser.

        Attempts to access public profile content. May be limited
        by Threads' anti-bot measures.
        """
        if not self._context:
            await self.launch()

        page = await self.new_page()
        url = f"https://www.threads.net/@{handle.lstrip('@')}"

        try:
            await self.human_like_goto(page, url)

            # Wait for content to load
            await page.wait_for_load_state("domcontentloaded")

            # Check if we hit a login wall
            login_wall = await page.query_selector(
                'div[role="dialog"], form[action*="login"], text="Log in", text="Sign in"'
            )
            if login_wall:
                # Try to dismiss or wait for public content
                await page.wait_for_timeout(3000)

            # Scroll to load more posts
            await self.human_like_scroll(page, scrolls=max_posts // 5 + 3)

            # Extract posts using multiple selector strategies
            posts = await self._extract_threads_posts(page, max_posts)

            return posts

        finally:
            await page.close()

    async def _extract_threads_posts(self, page: Page, max_posts: int) -> list[str]:
        """Extract Threads posts with multiple fallback selectors."""
        selectors = [
            'div[role="article"]',
            'div[data-pressable-container="true"]',
            'div.x1lliihq',
            'article',
            'div[class*="x1yztbdb"]',
            'div[class*="x1qjc9v5"]',
        ]

        for selector in selectors:
            try:
                posts = await page.evaluate(f"""
                    () => {{
                        const elements = document.querySelectorAll('{selector}');
                        const results = [];
                        elements.forEach(el => {{
                            const text = (el.innerText || el.textContent || '').trim();
                            if (text.length > 10) {{
                                results.push(text);
                            }}
                        }});
                        return results.slice(0, {max_posts});
                    }}
                """)
                if posts and len(posts) > 0:
                    # Clean up posts
                    cleaned = []
                    seen = set()
                    for post in posts:
                        post = re.sub(r'\s+', ' ', post).strip()
                        key = post[:120]
                        if key not in seen:
                            seen.add(key)
                            cleaned.append(post)
                    return cleaned[:max_posts]
            except Exception:
                continue

        return []

    async def close(self) -> None:
        """Close browser and cleanup."""
        if self._context:
            await self._context.close()
        if self._browser:
            await self._browser.close()
        if self._playwright:
            await self._playwright.stop()


async def scrape_threads_stealth(
    handle: str,
    max_posts: int = 50,
    headless: bool = True,
    proxy: Optional[str] = None,
    user_data_dir: Optional[str] = None,
) -> list[str]:
    """Convenience function for one-shot Threads scraping."""
    async with StealthScraper(
        headless=headless,
        proxy=proxy,
        user_data_dir=user_data_dir,
    ) as scraper:
        return await scraper.scrape_threads_profile(handle, max_posts)


if __name__ == "__main__":
    import sys
    handle = sys.argv[1] if len(sys.argv) > 1 else "zuck"
    posts = asyncio.run(scrape_threads_stealth(handle, max_posts=20))
    for i, post in enumerate(posts, 1):
        print(f"--- Post {i} ---")
        print(post[:200])
        print()