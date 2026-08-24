# Oh My Fx

A coding agent that stays out of the way — until it shouldn't.

Native Zig core. Sticky-footer TUI. Your providers, your keys, nothing in the middle.

**9** providers · **26** built-in tools · **23** search backends · **~3 MB** binary · **Zig 0.16**

## Install

**macOS · Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

Re-run it to upgrade. The script verifies `SHA256SUMS` before it replaces the binary in `~/.local/bin`.

**From source** ([Zig 0.16.0+](https://ziglang.org/download/))

```sh
zig build
./zig-out/bin/omfx
```

Use `./zig-out/bin/omfx` while developing — never an older `omfx` on your `PATH`.

## Every turn, _harnessed_.

Edits that fail the parse gate are undone, not reported. Effort `auto` spends budget where the prompt is responsive, not on the easy or the hopeless. Compaction cites what it drops so the model can still find it.

| surface | what it does |
| --- | --- |
| sticky footer | Composer pinned; transcript scrolls above it — no modal editor, no vim mode |
| parse gate | A write that breaks a previously clean file is rewound before the model sees “success” |
| `auto` effort | Per-prompt reasoning level; floor on easy and hard, budget for the middle |
| ARC compact | Local cites at `.omfx/recall/` — never an LLM rewrite of your history |

## The agent surface, _complete enough to ship_.

### 01 · Your login, not ours

`/login` lists model providers. OAuth where the vendor has a route; paste a key everywhere else. Credentials live in `~/.omfx/auth.json` (0600). Stored OAuth beats a leftover env var. omfx is not a gateway and has no key of its own.

### 02 · Models that match the credential

`/models` is one command. It shows what the provider you are signed into actually lists — subscription caps and API windows included — then offers `auto` plus every reasoning level that model declares.

### 03 · Permissions you can feel

Normal asks. Plan is read-only until `/plan go`. Yolo runs tools without prompting for this session only and is never written to disk. Shift-Tab cycles the three.

### 04 · Web search with a fallback chain

`/web` configures twenty-three backends. Set an order, turn one off, `test` the chain. First working provider wins; the rest wait their turn.

### 05 · Skills, discovered

Walk the skill roots your other agent CLIs already use. Each `SKILL.md` becomes a slash command; its `description:` is the help. `/reload` rescans. No product-owned skill marketplace required.

### 06 · Peers on a board

`/peers <goal>` starts a teammate with the same tools, an isolated thread, and a shared board (`FACT` / `FAIL` / `PATH`). Depth is capped. No nested peer storms.

### 07 · Browser on tabs you already have

`/browser` installs a Chrome relay. Keep `omfx browser-relay` listening; the extension dials localhost. No headless browser farm — existing tabs.

### 08 · MCP without the ceremony

`/mcp` lists configured servers. Definitions stay under `~/.omfx`. Nothing ships a remote MCP gateway on your behalf.

### 09 · Project rules that stay cache-stable

`AGENTS.md` is parsed into a harness contract (8 KiB cap), not dumped wholesale. Volatile orientation — git status, repo map — rides on the user message so the system prefix can stay byte-identical for provider caching.

### 10 · Unapologetically native

One Zig binary. Homemade ANSI TUI — press, release, and drag only, so the terminal keeps drag-select. No Node host, no TypeScript extension runtime, no second language for product features.

## Use

```
omfx                         Interactive full-screen session
omfx ask <prompt>            One-shot request (no alt screen)
omfx doctor                  Runtime status
omfx version                 Print version
omfx help [command]          Help
```

Inside a session: `/login`, `/models`, `/help`. Flags: `--provider`, `--model`, `--effort`, `--yolo`, `--resume`, `-h`, `-V`.

## Docs

- [Quick start](docs/index.md)
- [Documentation index](docs/llms.txt)
- [Slash commands](docs/using/slash-commands.md)
- [Configuration](docs/configure/configuration.md)

## License

See the repository license when published.
