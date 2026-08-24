# Web search

Configure search backends with `/web`.

Keys and enable/disable state live in `~/.omfx/auth.json`. Fallback order lives in `~/.omfx/settings.json`.

Examples inside `/web`:

- Numbered pick of backends
- `order exa,tavily,duckduckgo` — try in that order
- `off google` — skip one
- `test zig 0.16` — run the chain now

The first working provider in the order wins; the rest are fallbacks.
