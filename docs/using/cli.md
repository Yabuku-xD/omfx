# CLI commands

Top-level `omfx` commands and global flags. Interactive `/` commands are documented in [Slash commands](slash-commands.md).

Run `omfx` with no command to start an interactive session. `omfx --help` prints the live option list.

## Commands

| Command | Purpose |
| --- | --- |
| *(none)* | Interactive full-screen session |
| `ask <prompt>` | One-shot request (no alt screen) |
| `login [provider]` | List providers or sign in |
| `session [resume\|id]` | Session helpers (prefer `/resume` inside a session) |
| `browser-relay [install]` | Chrome relay listener / extension files |
| `doctor` | Runtime status |
| `update [--check\|--force]` | Check for and install the latest GitHub release |
| `version` | Print version |
| `help [command]` | Help |

Examples:

```sh
omfx ask "what does src/main.zig do?"
omfx ask --json --provider anthropic-api "summarize this repo"
omfx ask --prompt-file task.md
git diff | omfx ask --prompt-file - "review this diff"
omfx update --check
omfx doctor
```

## Global flags

Place flags before or after the command.

| Flag | Purpose |
| --- | --- |
| `--provider <id>` | Provider for this process |
| `--model <name>` | Model id |
| `--effort <level>` | Reasoning level when the model supports it |
| `--yolo` | Allow writes without a TTY prompt |
| `--auto` | Permission auto mode |
| `--prompt-permissions` | Force prompts |
| `--resume [last\|id]` | Continue a saved session |
| `--json` | JSONL events for `ask` ([schema](jsonl.md)) |
| `--prompt-file <path\|->` | `ask` reads the prompt from a file, or stdin for `-`; prompt words after it are appended |
| `--check` | With `update`: report only, do not install |
| `--force` | With `update`: reinstall even if current |
| `-h`, `--help` | Help |
| `-V`, `--version` | Version |

## Environment

| Variable | Purpose |
| --- | --- |
| `OMFX_BASE_URL` | Override provider base URL |
| `GITHUB_TOKEN` / `GH_TOKEN` | Optional auth for `omfx update` release metadata |
| `VISUAL` / `EDITOR` | External editor for ctrl-g |
| `HOME` | Locates `~/.omfx`. Unset, empty, or relative falls back to the account's home from the password database; omfx exits with `NO_HOME` if there is none |
| `PATH` | IDE and language-server discovery (`/ide`, one-shot LSP) |

Commands omfx runs (shell, verify, MCP servers, background jobs) see `AI_AGENT=omfx`.

## Exit status

| Code | Meaning |
| --- | --- |
| `0` | The model replied |
| `1` | `ask` ended on a provider failure (unreachable, or an error status after retries); the message is on stderr |
| `2` | Bad usage: unknown command or flag, missing prompt, unreadable `--prompt-file` |
| `78` | No provider configured, or no usable home directory |
