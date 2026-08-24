# Configuration

Settings files, scopes, and preferences.

## Files

| Layer | Location | Scope |
| --- | --- | --- |
| Auth | `~/.omfx/auth.json` | Credentials (0600) |
| Settings | `~/.omfx/settings.json` | Global preferences |
| Cache | `~/.omfx/cache/` | Provider model catalogs |
| Plugins | `~/.omfx/plugins/` | Installed marketplace plugins |
| User memory | `~/.omfx/memory.jsonl` | Facts reinjected every turn |
| Workspace | `.omfx/` | Playbook, board, recall, memory.md, drafts, forks — created when written |

There is no `/config`. Use `/settings`.

## Interactive settings

```
/settings
/settings key=value
```

The settings panel and the one-shot form share one setter.

| Key | Meaning |
| --- | --- |
| `sound` | Launch and completion chimes |
| `thinking` | Stream reasoning into the transcript |
| `telemetry` | Attribution headers to providers (off by default) |
| `statusline` | Footer fields |
| `composer` | Composer prefix |
| `editor` | Terminal editor for ctrl-g (`auto` → `$VISUAL` / `$EDITOR`) |
| `ide` | Graphical IDE for `/ide open` (`auto` → first on PATH) |
| `effort` | Starting reasoning level (`auto` picks per prompt) |
| `bash_timeout` | Seconds a bash command may run (`0` = default) |
| `keep_sessions` | Saved sessions to keep (`0` = all) |
| `max_peer_depth` | How deep `/peers` may nest |
| `sandbox` | `on` \| `off` for OS sandbox on bash |
| `review` | `llm` enables billed review after writes |
| `cdp_port` | Chrome relay port |
| `plugin_marketplaces` | Array of `owner/repo` marketplace ids |
| `mcp` | Array of MCP server objects |

## Last used

Last provider, model, and permission surface persist across launches. There is no separate “default model” concept — last used is what you get. Reasoning level `auto` is resolved per prompt.

## Project instructions

`AGENTS.md` at the workspace root (and nested files) is parsed into a harness contract (8 KiB cap). `/init` scaffolds one from the repo when missing. Volatile orientation (git status, repo map) rides on the user message so the system prefix stays byte-identical for provider prompt caching.

## Telemetry

Off by default. When on, omfx may send attribution headers some providers expect (`http-referer`, `x-title`, …). Nothing else leaves the machine for product analytics; `runlog` is local JSONL without prompt or reply text.
