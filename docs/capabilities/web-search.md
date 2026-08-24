# Web search

Run `/web` to configure search backends.

Keys live in `~/.omfx/auth.json`. Fallback order lives in `~/.omfx/settings.json`.

omfx ships nineteen backends: API key, SearXNG endpoint, and free. Free backends need no key and show as configured in the menu. Anthropic, xAI, ChatGPT, and Gemini search inside the model; they do not appear here. Use `web_search`, `web_fetch`, and `web_scrape` instead of vendor-native search.

Inside `/web`:

- Pick a provider to move it first (paste a key when prompted)
- Pick **Set search order**, then pick first, second, third. An empty line saves and replaces the old list.
  - Pick the same provider again to drop it from the list
  - Pick **Start over** to clear picks and begin again
  - Pick **Use built-in order** to drop a custom list and run the default chain
- `off id` / `on id` skip or restore a backend
- `test zig 0.16` runs the chain now

The first backend that works wins; the rest are fallbacks.

Related tools: `web_fetch` returns a short HTML sample; `web_scrape` returns title and main text. Search hits are numbered title, URL, and snippet, deduped, with tracking params stripped.
