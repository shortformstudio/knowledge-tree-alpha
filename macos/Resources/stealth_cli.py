#!/usr/bin/env python3
"""CLI entry point for stealth Threads scraping.

Usage: python -m knowledge_compiler.ingestion.stealth_cli @handle [--max-posts N] [--headless] [--proxy URL] [--user-data-dir PATH]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys

from .stealth_scraper import scrape_threads_stealth


def main() -> int:
    parser = argparse.ArgumentParser(description="Stealth Threads profile scraper")
    parser.add_argument("handle", help="Threads handle (with or without @)")
    parser.add_argument("--max-posts", type=int, default=50, help="Maximum posts to extract")
    parser.add_argument("--headless", action="store_true", default=True, help="Run headless")
    parser.add_argument("--no-headless", dest="headless", action="store_false", help="Show browser")
    parser.add_argument("--proxy", type=str, help="Proxy URL (e.g., http://user:pass@host:port)")
    parser.add_argument("--user-data-dir", type=str, help="Browser profile directory for persistence")
    parser.add_argument("--output", type=str, help="Output JSON file (default: stdout)")

    args = parser.parse_args()

    async def run() -> list[str]:
        return await scrape_threads_stealth(
            handle=args.handle,
            max_posts=args.max_posts,
            headless=args.headless,
            proxy=args.proxy,
            user_data_dir=args.user_data_dir,
        )

    try:
        posts = asyncio.run(run())
        result = {
            "handle": args.handle.lstrip("@"),
            "platform": "threads",
            "post_count": len(posts),
            "posts": posts,
        }
        output = json.dumps(result, ensure_ascii=False, indent=2)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(output)
        else:
            print(output)
        return 0
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())