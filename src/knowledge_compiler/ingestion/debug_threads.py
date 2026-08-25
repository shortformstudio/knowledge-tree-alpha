#!/usr/bin/env python3
"""Debug Threads scraping - inspect what the browser sees."""

from __future__ import annotations

import asyncio
from playwright.async_api import async_playwright


async def debug_threads(handle: str):
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False, slow_mo=100)
        context = await browser.new_context(
            viewport={"width": 1920, "height": 1080},
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
        )
        page = await context.new_page()

        url = f"https://www.threads.net/@{handle}"
        print(f"Navigating to {url}")
        await page.goto(url, wait_until="networkidle")

        # Wait and check
        await page.wait_for_timeout(5000)

        # Get page title
        title = await page.title()
        print(f"Page title: {title}")

        # Get body text
        body_text = await page.evaluate("document.body.innerText")
        print(f"Body text (first 2000 chars):\n{body_text[:2000]}")

        # Check for specific elements
        print("\n--- Checking for content elements ---")
        for selector in [
            'div[role="article"]',
            'div[data-pressable-container="true"]',
            'article',
            'div.x1lliihq',
            'div[class*="x1yztbdb"]',
        ]:
            count = await page.evaluate(f'document.querySelectorAll("{selector}").length')
            print(f"  {selector}: {count} elements")

        # Check for login wall
        login_elements = await page.evaluate("""
            () => {
                const text = document.body.innerText.toLowerCase();
                return {
                    hasLogin: text.includes('log in') || text.includes('sign in'),
                    hasCookie: text.includes('cookie'),
                    hasMeta: text.includes('meta'),
                }
            }
        """)
        print(f"\nLogin check: {login_elements}")

        # Get HTML for inspection
        html = await page.content()
        with open(f"/tmp/threads_{handle}.html", "w") as f:
            f.write(html)
        print(f"\nSaved HTML to /tmp/threads_{handle}.html")

        await browser.close()


if __name__ == "__main__":
    import sys
    handle = sys.argv[1] if len(sys.argv) > 1 else "natgeo"
    asyncio.run(debug_threads(handle))