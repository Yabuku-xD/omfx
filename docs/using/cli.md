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
| `version` | Print version |
| `help [command]` | Help |

Examples:

```sh
omfx ask "what does src/main.zig do?"
omfx ask --json --provider groq "summarize this repo"
omfx doctor
```

## Global flags

Place flags before the command.

| Flag | Purpose |
| --- | --- |
| `--provider <id>` | Provider for this process |
| `--model <name>` | Model id |
| `--effort <level>` | Reasoning level when the model supports it |
| `--yolo` | Allow writes without a TTY prompt |
| `--auto` | Permission auto mode |
| `--prompt-permissions` | Force prompts |
| `--resume [last\|id]` | Continue a saved session |
| `--json` | Structured output where supported (`ask`) |
| `-h`, `--help` | Help |
| `-V`, `--version` | Version |

## Environment

| Variable | Purpose |
| --- | --- |
| `OMFX_BASE_URL` | Override provider base URL |
| `VISUAL` / `EDITOR` | External editor for ctrl-g |
| `HOME` | Locates `~/.omfx` |
