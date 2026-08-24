# Web search

Configure search backends with `/web`.

Keys live in `~/.omfx/auth.json`. Fallback order lives in `~/.omfx/settings.json`.

Nineteen backends are available (API key, SearXNG endpoint, and free). Model-native search (Anthropic, xAI, ChatGPT, Gemini) is not listed here — those models already search when you chat with them. Prefer omfx `web_search` / `web_fetch` / `web_scrape` over any built-in vendor search.

Inside `/web`:

- Pick a provider to try it first (and paste a key if it needs one)
- Pick **Set search order**, then pick first, second, third… Empty line saves (replaces the previous list)
  - Pick the same provider again to remove it
  - Pick **Start over** to clear the picks and begin again
  - Pick **Use built-in order** if the custom list went wrong (drops it; the default chain runs)
- `off id` / `on id` — skip or include again
- `test zig 0.16` — run the chain now

The first working provider in the order wins; the rest are fallbacks.

Related tools: `web_fetch` (short raw sample for HTML), `web_scrape` (title + main text). Search returns numbered title/URL/snippet hits, deduped, with tracking params stripped. Prefer these omfx tools over any model-native search.
