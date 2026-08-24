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
| `/handoff` | New session with a brief |
| `/quit` | Exit (`/exit`) |

## Account and model

| Command | Purpose |
| --- | --- |
| `/login` | Sign in (`/setup`) |
| `/logout` | Remove a stored provider key |
| `/models` | Models for the signed-in provider (`/model` is an alias) |
| `/fast` | Toggle effort=none |
| `/permissions` | `ask` \| `auto` \| `yolo` |
| `/allowlist` | Persistent permission rules |
| `/sandbox` | OS sandbox on bash |
| `/yolo` | Allow writes this session |
| `/effort` | Reasoning level; `auto` picks per prompt (ctrl-t cycles) |
| `/plan` | Read-only plan mode; `/plan go` implements |

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
| `/web` | Web search keys and fallback order |
| `/browser` | Install Chrome relay extension |
| `/reload` | Reload settings, auth, reads, relay |
| `/background` | Background commands |
| `/mcp` | MCP servers |
| `/init` | Scaffold `AGENTS.md` |
| `/workspace` | Extra directories |
| `/undo` | Undo last tracked file change |
| `/copy` | Copy latest assistant reply |
| `/diagram` | Save mermaid fences from the last reply |
| `/feedback` | Bug report path |
| `/trace` | Private diagnostic trace |
| `/peers` | Run a teammate |

Discovered skills appear as additional slash commands after `/reload`.
