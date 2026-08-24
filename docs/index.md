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
| Open IDE | `/ide open` |
| Status | `/status` |
| Usage | `/usage` |

## What omfx does better

- **Parse gate**: omfx rewinds a write that breaks a file that parsed clean before the model sees success.
- **One-shot LSP**: after a clean parse, omfx runs diagnostics from a language server on PATH. Nothing is bundled; no daemon.
- **Effort `auto`**: reasoning budget follows the prompt, not a fixed default.
- **ARC compact + recall**: dropped context lands in inspectable recall files, not a rewrite pass from another model.
- **Hybrid semantic search**: repo rank, symbols, and tokens fused; no embeddings required.
- **Memory + playbook**: workspace and user facts, plus verified lessons that can graduate into skills.
- **Shared board**: structured notes for facts, failures, and paths for peers and coordination.
- **Ranked repo map**: orientation by symbol references, not directory walk order.
- **Credential-aware `/models`**: signed-in providers first, then that provider's models.
- **Stacked skills + `@files`**: several skills and file anchors in one prompt.
- **Web fallback chain**: nineteen search backends; pick an order in `/web`, first match wins.
- **External IDE**: `/ide open` launches code, cursor, zed, and friends on the workspace.

## What omfx asks before it acts

In normal mode, sensitive tools prompt before they run. Plan mode is read-only. Yolo allows writes for the session only and is never persisted.

## Continue

- [CLI commands](using/cli.md)
- [Sessions](using/sessions.md)
- [Peers](capabilities/peers.md)
- [Tools](capabilities/tools.md)
- [Configuration](configure/configuration.md)
- [Troubleshooting](using/troubleshooting.md)

[Browse all documentation](llms.txt)
