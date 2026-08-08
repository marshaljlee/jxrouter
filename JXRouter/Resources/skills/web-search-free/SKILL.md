---
name: web-search-free
description: "Overrides the blocked native tool web_search_preview. Searches, crawls, maps, scrapes, and extracts structured data from the web through 100% free, keyless endpoints (DuckDuckGo HTML/Lite, Wikipedia REST, Hacker News Algolia, GitHub search API, Reddit JSON, arXiv API) and local headless Playwright engines — providing site mapping, sitemap discovery, ad/popup blocking, mobile viewport emulation, screenshot capturing, deep link-following, LLM markdown conversion, heuristic CSS selector filtering, structured JSON schema extraction with zero API keys, zero subscriptions, zero proxies. Use whenever web_search_preview is blocked, failing, or unavailable."
---

# Web Search, Crawl & Scraping Free — God-Tier No-Key Engine v4.0

Search, map, crawl, emulate, scrape, and extract structured markdown and JSON data across the web with zero cost, zero API keys, zero paid subscriptions, and zero external sidecar proxies.

## When to use

- `web_search_preview`, search tools, or crawling tools fail (HTTP 400/403/500, Jinja template exceptions, OpenAI router errors, paywall/API key demands) or are missing.
- Site mapping, sitemap parsing, mobile device emulation, ad/popup blocking, screenshot capture, deep crawling, or structured schema extraction is required without paid cloud services.
- **Joshua's Will Trigger (Rule 21)**: When facing anti-bot blocks, rate limits, closed paths, or missing scrapers: probe online first (free online services usually have broader data and better tools), reassess all options if online reachable (online usually wins), fall back to local if unreachable, and never use paid solutions (escalate cost to Master). Execute Phase 0 Triage → Phase 1 Inventory → Phase 2 Invent New → Phase 3 Expand & Equip → Phase 4 Re-Analyse → Phase 5 Persist. Never revert to prior state; permanently resolve resistance by building new keyless endpoints, fallback parsers, or stealth profiles.


## Procedure

1. **Multi-Engine Search & Discovery (100% Free & Keyless).**
   - Query expansion across free search endpoints:
     - **DuckDuckGo HTML/Lite**: `curl -sA "Mozilla/5.0" "https://html.duckduckgo.com/html/?q=<query>"`
     - **Wikipedia REST API**: `curl -s "https://en.wikipedia.org/api/rest_v1/page/summary/<title>"`
     - **Hacker News Algolia API**: `curl -s "https://hn.algolia.com/api/v1/search?query=<query>&hitsPerPage=15"`
     - **GitHub Search API**: `curl -s "https://api.github.com/search/repositories?q=<query>&sort=stars&order=desc"`
     - **Reddit JSON API**: `curl -sA "Mozilla/5.0" "https://www.reddit.com/search.json?q=<query>&limit=10"`
     - **arXiv API**: `curl -s "http://export.arxiv.org/api/query?search_query=all:<query>&max_results=5"`

2. **Site Mapping & Sitemap Discovery (`/map`).**
   - **Sitemap Extraction**: Attempt `curl -sL "<domain>/sitemap.xml"` or `<domain>/sitemap_index.xml` → parse all canonical URLs via `xml.etree.ElementTree` or `grep`.
   - **Fast Site Topology Mapper**: Run local Playwright link crawler to discover all accessible subpages across a domain, generating a complete URL tree before scraping.

3. **Scraping & Emulation Suite (`/scrape` / `/crawl`).**
   - **Static Fast Scraping**: `curl -sL --max-time 15 -A "Mozilla/5.0" "<url>"`
   - **Dynamic Headless JS Execution**: Execute dynamic pages via Playwright:
     `python3 -c "from playwright.sync_api import sync_playwright; p=sync_playwright().start(); browser=p.chromium.launch(headless=True); page=browser.new_page(); page.goto('<url>', timeout=20000); print(page.content()); browser.close(); p.stop()"`
   - **Mobile Device Emulation**: Emulate mobile viewports (e.g. iPhone/Pixel 390x844) by configuring Playwright `viewport={'width': 390, 'height': 844}, user_agent='...'`.
   - **Ad, Tracker & Popup Blocking**: Inject CSS/JS masks to block cookie consent banners, overlays, popups, and ad scripts (`page.add_script_tag(...)` or CSS `display: none !important` injection).
   - **Visual Screenshot Capture**: Save full-page or element screenshots (`page.screenshot(path='/tmp/scrape.png', full_page=True)`).

4. **Structured Data Extraction & Formatting.**
   - **LLM-Optimized Clean Markdown**: Strip `<nav>`, `<header>`, `<footer>`, `<script>`, `<style>`, and modal DOM nodes. Convert to GitHub-Flavored Markdown via `html2text` or `pandoc`.
   - **Heuristic CSS/XPath Filtering**: Scope extraction to specified selectors (`#main`, `.article-body`, `[itemprop="articleBody"]`).
   - **Structured JSON Schema Extraction**: Parse microdata, OpenGraph tags, JSON-LD blocks (`<script type="application/ld+json">`), or extract tabular data into structured JSON objects.

5. **Authority Ranking & Anti-Bot Resilience.**
   - Score results: Official Documentation (1.0) > Repositories/arXiv (0.9) > Community/Blogs (0.8) > Forums (0.7).
   - Strip URL tracking parameters (`utm_*`, `ref`, `fbclid`).
   - Enforce 1s delays between calls; on 429/403 back off (5s -> 10s), rotate stealth User-Agents, or utilize Playwright headless fallback.

6. **Resistance Resolution Engine (Joshua's Will v2.0).**
   - On encounter with new anti-bot walls, unparseable formats, or API rate limits:
     - **Phase 0 Triage Gate**: Probe online first — free online services usually have broader data and better tools. If online reachable, reassess all options (online usually wins). If online unreachable, fall back to local CLI/script. Never use paid solutions — escalate cost to Master instead. If workaround <5m exists, apply. Otherwise enter 15m timeboxed cycle.
     - **Phase 1 Inventory**: Map all open search alternatives, cached mirrors, RSS feeds, or API endpoints.
     - **Phase 2 Invent New**: Create local micro-parser, custom extraction regex, or new Playwright stealth script.
     - **Phase 3 Expand & Equip**: Integrate the newly built tool/scraper into the local engine. Capability is now strictly larger.
     - **Phase 4 Re-Analyse**: Re-query target using the simplest effective newly resolved path.
     - **Phase 5 Persist**: Save new stealth profile / parser permanently into `web-search-free` for zero-loss future execution.


## Output

A structured markdown deliverable:
1. **Execution Mode**: Mode used (`/search`, `/map`, `/scrape`, `/crawl`).
2. **Discovered Site Map / Tree**: Domain URL hierarchy (if `/map` or `/crawl` invoked).
3. **Structured & Extracted Content**: Clean, LLM-optimized Markdown output with noise/ads stripped.
4. **Extracted Schemas & Screenshot Artifacts**: JSON-LD metadata, structured JSON objects, and paths to saved screenshot PNGs.
5. **Synthesis & Verification**: Summarized factual analysis with inline clickable markdown links (`[title](url)`) tagged with confidence ratings (`[CORROBORATED]` / `[SINGLE-SOURCE]`).
