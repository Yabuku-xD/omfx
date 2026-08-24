# Quick start

Install omfx, sign in, and run a first request.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

The installer places `omfx` in `~/.local/bin`. Later upgrades:

```sh
omfx update
```

See [Installation](getting-started/installation.md) if the binary is missing from your `PATH`.

Or build from this tree:

```sh
zig build
./zig-out/bin/omfx
```

Requires Zig 0.16.0+.

## Sign in

```sh
omfx
```

Type `/login`, pick a provider, and paste a key or finish OAuth. Credentials live in `~/.omfx/auth.json`. Details: [Authentication](getting-started/authentication.md).

## First prompts

```sh
omfx ask "what does src/main.zig do?"
omfx                              # interactive full-screen session
```

In an interactive session, type `/` for commands. See [Slash commands](using/slash-commands.md).

| Goal | Command |
| --- | --- |
| Open commands | Type `/` |
| Sign in | `/login` |
| Choose a model | `/models` |
| Permissions | `/permissions` or Shift-Tab |
| Context window | `/context` |
| Status | `/status` |
| Usage | `/usage` |

## What omfx does better

- **Parse gate** — a write that breaks a previously clean file is rewound before the model sees success.
- **Effort `auto`** — reasoning budget follows the prompt, not a fixed default.
- **ARC compact + recall** — dropped context is cited into `.omfx/recall/`, not rewritten by another model.
- **Memory + playbook** — `.omfx/memory.md`, user jsonl facts, and verified lessons in `.omfx/playbook.jsonl`.
- **Shared board** — `FACT` / `FAIL` / `PATH` notes in `.omfx/board.jsonl` for peers and coordination.
- **Ranked repo map** — orientation by symbol references, not directory walk order.
- **Credential-aware `/models`** — subscription and API windows capped correctly.
- **Stacked skills + `@files`** — several skills and file anchors in one prompt.
- **Web fallback chain** — twenty-three search backends; first that works wins.

## What omfx asks before it acts

In normal mode, sensitive tools prompt before they run. Plan mode is read-only. Yolo allows writes for the session only and is never persisted.

## Continue

- [CLI commands](using/cli.md)
- [Sessions](using/sessions.md)
- [Peers](capabilities/peers.md)
- [Configuration](configure/configuration.md)
- [Troubleshooting](using/troubleshooting.md)

[Browse all documentation](llms.txt)
