# Knowledge Compiler

> **MCP server for web scraping, graph compilation, and knowledge visualization**

A local-first knowledge compiler that crawls websites, scrapes social profiles, translates content, builds crawl trees, and renders a photorealistic 3D "wisegraph" of your knowledge base.

---

## Features

### 🕸️ **Wisegraph** — Photorealistic 3D Knowledge Tree
A helical bark trunk rendered in Three.js with:
- Procedural GLSL bark shader (ridges, knots, moss, lichen)
- ACES filmic tone mapping, cyan glow on memory indents
- Golden-angle helical placement: drag to spin, spin to ascend
- Forest mode: distant species-tinted mini-trunks

### 🌲 **Crawl Tree Tracking**
Every scrape records an exact link chain:
- BFS queue tracks `(url, depth, parent_url, order)` for tree structure
- Each URL from Mission Control gets its own tree graph
- Expandable tree view in macOS UI with depth-colored nodes

### 🌐 **Multi-Backend Translation Pipeline**
Auto-detects language and translates to target language:
- **Detectors**: langdetect (pure Python), fastText (optional)
- **Translators**: LibreTranslate, Google (via deep-translator), MyMemory
- In-memory LRU cache, composite fallback chains
- Confidence thresholds prevent low-quality translations

### 🧹 **Content Cleaner**
Strips formatting, CSS, HTML junk from scraped pages:
- Decomposes script, style, nav, footer, iframe, form, etc.
- Strips all attributes, unwraps wrapper divs/spans
- Preserves paragraph boundaries, filters boilerplate

### 🕵️ **Stealth Threads Scraper (No Login)**
Playwright-based headless browser with anti-detection:
- webdriver override, chrome runtime mock, permissions/plugins/languages spoofing
- Canvas fingerprint noise, WebGL vendor spoofing
- Human-like: random viewport/UA, variable scroll delays, mouse movement
- Extracts 4-7 posts from initial HTML before login wall
- **Use your Chrome session**: `--user-data-dir` or CDP (port 9222)

### 📱 **Social Profiler**
Scrapes Twitter/X (via Nitter), GitHub, Reddit profiles into graph nodes

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      macOS App (SwiftUI)                    │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │
│  │ Mission     │ │ System Log  │ │ Profile     │          │
│  │ Control     │ │             │ │ Scraper     │          │
│  └─────────────┘ └─────────────┘ └─────────────┘          │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │
│  │ Crawl Trees │ │ Wisegraph   │ │ Node Reader │          │
│  │ (tree view) │ │ (three.js)  │ │             │          │
│  └─────────────┘ └─────────────┘ └─────────────┘          │
└─────────────────────────────────────────────────────────────┘
                          │
                    IPC / CLI
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                   Python MCP Server                         │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌─────────────┐ │
│  │ Crawler   │ │ Cleaner   │ │ LangDetect│ │ Translator  │ │
│  │ (BFS)     │ │ (BS4)     │ │ (multi)   │ │ (multi)     │ │
│  └───────────┘ └───────────┘ └───────────┘ └─────────────┘ │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐                │
│  │ GraphStore│ │ Stealth   │ │ Semantic  │                │
│  │ (NetworkX │ │ Scraper   │ │ Compiler  │                │
│  │  + SQLite)│ │(Playwright)             │                │
│  └───────────┘ └───────────┘ └───────────┘                │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites
- macOS 14+ (for native app)
- Python 3.11+
- Node.js (not required — Three.js bundled)

### Install Python Dependencies
```bash
pip install -r requirements.txt
playwright install chromium
```

### Build macOS App
```bash
cd macos
swift build
.build/debug/KnowledgeCompiler
```

### Run MCP Server (Python)
```bash
# From repo root
python -m knowledge_compiler.server
```

---

## Usage

### Mission Control (macOS App)
1. Enter a URL in the sidebar
2. Set crawl depth (1–5)
3. Click **Compile** — builds crawl tree, extracts content
4. Open **Crawl Trees** panel to see exact link chains
5. Open **Wisegraph** window for 3D helical trunk view

### Stealth Threads Scraper (CLI)
```bash
# Basic scrape (4-7 posts before login wall)
python -m knowledge_compiler.ingestion.stealth_cli @handle --max-posts 20

# Use your Chrome session (full history if authenticated)
# 1. Close Chrome completely
# 2. Copy profile: cp -r ~/Library/Application\ Support/Google/Chrome/Default /tmp/my-threads
# 3. Run with profile:
python -m knowledge_compiler.ingestion.stealth_cli @handle --max-posts 50 --user-data-dir /tmp/my-threads

# Or use CDP (Chrome must be running with --remote-debugging-port=9222)
python -m knowledge_compiler.ingestion.chrome_cdp_scraper @handle 20
```

### Configuration (Environment Variables)
```bash
# Translation
export KDC_TRANSLATE_ENABLED=true
export KDC_TARGET_LANGUAGE=en
export KDC_TRANSLATION_BACKENDS=libretranslate,google,mymemory
export KDC_LIBRETRANSLATE_URL=https://libretranslate.de
export KDC_LIBRETRANSLATE_API_KEY=your_key
export KDC_MYMEMORY_EMAIL=your@email.com

# Language Detection
export KDC_LANGUAGE_DETECTION_ENABLED=true
export KDC_LANGUAGE_DETECTION_BACKEND=langdetect  # or fasttext
export KDC_FASTTEXT_MODEL_PATH=/path/to/lid.176.bin

# Crawling
export KDC_MAX_DEPTH=3
export KDC_MAX_CONCURRENT_REQUESTS=8
export KDC_RATE_LIMIT_RPS=5.0
export KDC_MAX_CONTENT_CHARS=3000
```

---

## Project Structure

```
knowledge-tree-alpha/
├── macos/                          # Native macOS app (SwiftUI)
│   ├── Sources/KnowledgeCompiler/
│   │   ├── Engine/                 # Core engines
│   │   │   ├── GraphStore.swift    # Swift graph with crawl sessions
│   │   │   ├── ProfileScraper.swift # Stealth + WKWebView backends
│   │   │   └── ...
│   │   ├── UI/                     # SwiftUI views
│   │   │   ├── CrawlTreePanel.swift # Expandable tree view
│   │   │   ├── TrunkPanel.swift    # Three.js wisegraph host
│   │   │   ├── ContentView.swift   # Main canvas
│   │   │   └── ...
│   │   └── Resources/
│   │       ├── trunk.html          # Three.js photorealistic trunk
│   │       ├── three.min.js        # Bundled Three.js r152
│   │       └── stealth_cli.py      # Bundled for app
│   └── Package.swift
│
├── src/knowledge_compiler/         # Python MCP server
│   ├── config.py                   # Pydantic settings (KDC_* env vars)
│   ├── di.py                       # Dependency injection container
│   ├── graph/
│   │   ├── store.py                # NetworkX + SQLite GraphStore
│   │   └── query.py                # Query engine
│   ├── ingestion/
│   │   ├── cleaner.py              # ContentCleaner (BS4)
│   │   ├── crawler.py              # BFS crawler with crawl trees
│   │   ├── fetcher.py              # Rate-limited httpx fetcher
│   │   ├── langdetect.py           # LanguageDetector (multi-backend)
│   │   ├── parser.py               # Legacy parser
│   │   ├── stealth_scraper.py      # Playwright stealth browser
│   │   ├── stealth_cli.py          # CLI entry point
│   │   ├── chrome_cdp_scraper.py   # CDP connector for Chrome
│   │   └── translator.py           # Translator (multi-backend)
│   ├── semantic/
│   │   └── compiler.py             # Semantic compiler
│   ├── social/
│   │   └── profiler.py             # Social media profiler
│   ├── telemetry/
│   │   └── __init__.py             # Event bus
│   └── server.py                   # MCP server entry point
│
├── tests/                          # Pytest suite
└── requirements.txt
```

---

## Screenshots

### Wisegraph — Photorealistic Helical Trunk
![Wisegraph](docs/screenshots/wisegraph.png)
*Drag to spin, spin to ascend. Cyan-glowing memory indents carved into procedural bark.*

### Crawl Trees Panel
![Crawl Trees](docs/screenshots/crawl_trees.png)
*Each scrape URL gets its own tree. Expandable nodes show exact link chains with depth colors.*

### Mission Control
![Mission Control](docs/screenshots/mission_control.png)
*Enter URLs, set depth, run compiles. System log shows real-time telemetry.*

### Profile Scraper with Stealth Mode
![Profile Scraper](docs/screenshots/profile_scraper.png)
*Stealth toggle, max posts, user data dir for persistent Chrome session.*

---

## API (MCP)

The server exposes these tools via MCP:

| Tool | Description |
|------|-------------|
| `crawl` | BFS crawl with depth, returns crawl_id |
| `get_crawl_tree` | Returns (nodes, edges) for a crawl_id |
| `list_crawl_sessions` | All recorded crawl sessions |
| `scrape_profile` | Social profile scrape (Twitter, GitHub, Reddit, Threads) |
| `translate` | Translate text with auto-detect |
| `detect_language` | Detect language of text |
| `export_obsidian` | Export graph to Obsidian vault |
| `get_graph` | Current graph nodes/edges |

---

## Development

### Running Tests
```bash
PYTHONPATH=src python -m pytest tests/ -v
```

### Linting
```bash
ruff check src/
mypy src/
```

### Adding a Translation Backend
1. Implement `Translator` abstract class in `translator.py`
2. Add to `create_translator()` factory
3. Add backend name to `KDC_TRANSLATION_BACKENDS` default

### Adding a Language Detector
1. Implement `LanguageDetector` abstract class in `langdetect.py`
2. Add to `create_detector()` factory

---

## Limitations

- **Threads**: Only 4-7 posts visible without login (login wall in initial HTML)
- **Full Threads history**: Requires authenticated session (cookies via `user_data_dir` or CDP)
- **Python version**: Requires 3.11+ (union syntax, `dataclass(slots=True)`)
- **mcp package**: Not on PyPI — install in development environment

---

## License

MIT — see LICENSE file

---

## Credits

- **Three.js** — 3D rendering
- **Playwright** — Stealth browser automation
- **langdetect** — Language detection
- **deep-translator** — Google Translate wrapper
- **NetworkX** — Graph algorithms
- **httpx** — Async HTTP client
- **BeautifulSoup4** — HTML parsing
- **pydantic** — Configuration validation