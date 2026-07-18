"""Ingestion engine — async BFS crawler, HTML parser, rate-limited fetcher."""

from .crawler import Crawler
from .fetcher import Fetcher
from .parser import Parser

__all__ = ["Crawler", "Fetcher", "Parser"]
