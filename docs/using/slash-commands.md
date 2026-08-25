# Slash commands

Type `/` in the interactive session to search commands. Everything else is sent to the model as a prompt. Top-level CLI commands are in [CLI commands](cli.md).

## Session

| Command | Purpose |
| --- | --- |
| `/help` | List slash commands (panel when bare) |
| `/shortcuts` | Keyboard shortcuts |
| `/clear` | Start a fresh chat; keep background work (`/new`) |
| `/reset` | Start a fresh chat and stop background work |
| `/resume` | Open a saved chat |
| `/continue` | Pick a chat to continue, or retry the last turn |
| `/rename [title]` | Rename this chat |
| `/compact` | Shorten older parts of this chat |
| `/rewind` | Go back to an earlier message, or trim from one |
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
| `/plan` | Plan first (no changes); `/plan go` carries it out; `/plan off` exits |

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
| `/background` | See work running in the background |
| `/mcp` | List / invoke / `add` (stdio or `--transport http`) |
| `/ide` | Open workspace in external IDE (`open` \| `list` \| pin) |
| `/plugin` | Plugin marketplaces (`list` \| `marketplace add` \| `install`) |
| `/init` | Scaffold `AGENTS.md` |
| `/workspace` | Extra folders |
| `/undo` | Undo last tracked file change |
| `/copy` | Copy latest assistant reply |
| `/diagram` | Save mermaid fences from the last reply |
| `/feedback` | Bug report path |
| `/trace` | Private diagnostic trace |
| `/peers` | Ask a teammate to work on a goal |
| `/files` | Pick a file to mention in what you type |

Discovered skills appear as additional slash commands after `/reload`. Stack several skills and `@paths` in one prompt; see [Skills](../capabilities/skills.md).
