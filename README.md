# Oh My Fx

A coding agent CLI that refuses to ship broken edits, spends reasoning where it
helps, and keeps your history inspectable.

**9** providers · **26** built-in tools · **23** search backends · **~3 MB** binary · **Zig 0.16**

## Install

**macOS · Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

Upgrade later with:

```sh
omfx update
omfx update --check    # report only
```

The installer verifies `SHA256SUMS` before it replaces `~/.local/bin/omfx`. Pin a
release with `OMFX_VERSION=<tag>`.

**From source** ([Zig 0.16.0+](https://ziglang.org/download/))

```sh
zig build
./zig-out/bin/omfx
```

Use `./zig-out/bin/omfx` while developing — never an older `omfx` on your `PATH`.

## Why omfx

### Parse gate

An edit that leaves a previously clean file unparseable is undone before the
model sees success. The agent is not rewarded for breaking the tree.

### Effort `auto`

Reasoning level is chosen per prompt. Easy and hard both get the floor; the
budget goes to the responsive middle. Two failed turns route effort down.

### ARC compaction

When the context window fills, omfx cites what it drops into `.omfx/recall/` —
local, inspectable files — instead of rewriting your history through another
LLM call.

### Credential-aware models

`/models` shows what the provider you signed into actually lists. Subscription
windows and API keys for the same model are capped correctly. `auto` plus every
declared reasoning level appear when the model offers them.

### Permissions you can feel

Ask prompts before sensitive tools. Plan is read-only until `/plan go`. Yolo
runs without prompts for this session only and is never written to disk.
Shift-Tab cycles the three.

### Web search with a fallback chain

`/web` configures twenty-three backends. Set an order, disable one, `test` the
chain. First working provider wins.

### Skills, discovered

Walk the skill roots your other agent CLIs already use. Each `SKILL.md` becomes
a slash command; its `description:` is the help. `/reload` rescans. No
product-owned marketplace required.

### Peers on a board

`/peers <goal>` starts a teammate with the same tools, an isolated thread, and
a shared board (`FACT` / `FAIL` / `PATH`). Depth is capped — no nested peer
storms.

### Browser on tabs you already have

`/browser` installs a Chrome relay. Keep `omfx browser-relay` listening; the
extension dials localhost. Existing tabs, not a headless farm.

### MCP without a gateway

`/mcp` lists servers you configured under `~/.omfx`. omfx does not run a remote
MCP gateway on your behalf.

### Cache-stable project rules

`AGENTS.md` is parsed into a harness contract (8 KiB cap), not dumped wholesale.
Volatile orientation — git status, repo map — rides on the user message so the
system prefix stays byte-identical for provider prompt caching.

### Your keys, your providers

`/login` lists model providers. OAuth where the vendor has a route; paste a key
everywhere else. Credentials live in `~/.omfx/auth.json` (0600). Stored OAuth
beats a leftover env var. omfx is not a gateway and has no key of its own.

## Use

```
omfx                         Interactive full-screen session
omfx ask <prompt>            One-shot request (no alt screen)
omfx update [--check|--force]  Install the latest GitHub release
omfx doctor                  Runtime status
omfx version                 Print version
omfx help [command]          Help
```

Inside a session: `/login`, `/models`, `/help`. Flags: `--provider`, `--model`,
`--effort`, `--yolo`, `--resume`, `-h`, `-V`.

## Docs

- [Quick start](docs/index.md)
- [Documentation index](docs/llms.txt)
- [Slash commands](docs/using/slash-commands.md)
- [Configuration](docs/configure/configuration.md)

## License

See the repository license when published.
