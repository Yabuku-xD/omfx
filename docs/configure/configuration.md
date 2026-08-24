# Configuration

Settings files, scopes, and preferences.

## Files

| Layer | Location | Scope |
| --- | --- | --- |
| Auth | `~/.omfx/auth.json` | Credentials (0600) |
| Settings | `~/.omfx/settings.json` | Global preferences |
| Cache | `~/.omfx/cache/` | Provider model catalogs |
| Workspace | `.omfx/` | Playbook, recall, drafts, forks — created when written |

There is no `/config`. Use `/settings`.

## Interactive settings

```
/settings
/settings key=value
```

The settings panel and the one-shot form share one setter. Useful keys include sound, thinking, telemetry, statusline, editor, bash timeout, keep_sessions, max_peer_depth, and sandbox.

## Last used

Last provider, model, and permission surface persist across launches. There is no separate “default model” concept — last used is what you get. Reasoning level `auto` is resolved per prompt.

## Project instructions

`AGENTS.md` at the workspace root (and nested files) is parsed into a harness contract (8 KiB cap). `/init` scaffolds one from the repo when missing.

## Telemetry

Off by default. When on, omfx may send attribution headers some providers expect (`http-referer`, `x-title`, …). Nothing else leaves the machine for product analytics; `runlog` is local JSONL without prompt or reply text.
