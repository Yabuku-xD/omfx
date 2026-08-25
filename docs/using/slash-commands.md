# Slash commands

Type `/` in the interactive session to search commands. Everything else is sent to the model as a prompt. Top-level CLI commands are in [CLI commands](cli.md).

## Session

| Command | Purpose |
| --- | --- |
| `/help` | List slash commands (panel when bare) |
| `/shortcuts` | Keyboard shortcuts |
| `/clear` | Fresh session; keep background jobs (`/new`) |
| `/reset` | Fresh session; stop background jobs |
| `/resume` | Pick or resume a saved session |
| `/continue` | Session picker, or retry the last prompt |
| `/rename [title]` | Rename the current session |
| `/compact` | Compact older turns now |
| `/rewind` | Go back to an earlier prompt, or compress |
| `/fork` | Copy this session to a new id |
| `/handoff [goal]` | New session from a thin packet (no transcript dump) |
| `/spec` | Spec-first: disk docs + phase overlay when active; `next` / `run` |
| `/checkpoint [note]` | Snapshot run pointers under `.omfx/runs/` |
| `/sleep [note]` | Checkpoint + park (zero compute until `/wake`) |
| `/wake [id\|list]` | Resume a run from a thin stub |
| `/quit` | Exit (`/exit`) |

## Account and model

| Command | Purpose |
| --- | --- |
| `/login` | Sign in (`/setup`); configured providers show `✓` |
| `/logout` | Remove a stored provider key |
| `/models` | Signed-in providers, then models; Esc goes back |
| `/fast` | Toggle effort=none |
| `/permissions` | `ask` \| `auto` \| `yolo` |
| `/allowlist` | Permission DSL; `session` rules shrink only |
| `/sandbox` | OS sandbox on bash |
| `/yolo` | Allow writes this session |
| `/effort` | Reasoning level; `auto` picks per prompt (ctrl-t cycles) |
| `/plan` | Enter read-only plan mode (`/plan` alone); `/plan go` implements; `/plan off` exits |

Model and provider picks settle in the footer for three seconds; menus and errors stay in the scrollback.

## Inspect and settings

| Command | Purpose |
| --- | --- |
| `/status` | Model, workspace, permissions, session |
| `/stats` | Session statistics |
| `/context` | Context window breakdown |
| `/usage` | Local usage (`/cost`) |
| `/settings` | Settings panel or `key=value` |
| `/appearance` | Composer presentation |
| `/statusline` | Footer fields |
| `/sound` | Launch and completion chimes |
| `/thinking` | Stream reasoning into the transcript |
| `/version` | Installed version |

## Tools and workspace

| Command | Purpose |
| --- | --- |
| `/web` | Search backends: keys, pick-to-order, test chain (19 backends) |
| `/browser` | Install Chrome relay extension |
| `/reload` | Reload settings, auth, skills, relay |
| `/background` | Background commands |
| `/mcp` | List / invoke / `add` (stdio or `--transport http`) |
| `/ide` | Open workspace in external IDE (`open` \| `list` \| pin) |
| `/plugin` | Plugin marketplaces (`list` \| `marketplace add` \| `install`) |
| `/init` | Scaffold `AGENTS.md` |
| `/workspace` | Extra directories |
| `/undo` | Undo last tracked file change |
| `/copy` | Copy latest assistant reply |
| `/diagram` | Save mermaid fences from the last reply |
| `/feedback` | Bug report path |
| `/trace` | Private diagnostic trace |
| `/peers` | Run a teammate |

Discovered skills appear as additional slash commands after `/reload`. Stack several skills and `@paths` in one prompt; see [Skills](../capabilities/skills.md).
