# Oh My Fx

A coding agent CLI built to keep edits honest, memory inspectable, and context
under control.

**9** providers · **27** built-in tools · **19** search backends · **~3 MB** binary · **Zig 0.16** · **MIT**

## Install

**macOS · Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

Upgrade later:

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

**Parse gate** — broken edits are undone before the model sees success. Thirty-six
languages, one check table; verify after writes and feed the playbook on clean runs.
When a language server is already on PATH, one-shot LSP diagnostics append after a
clean parse — no daemon, nothing bundled.

**Effort auto** — reasoning budget follows the prompt, not a fixed default. Easy and
hard get the floor; the responsive middle gets the spend. Two failures route down.

**ARC compact and recall** — when the window fills, older turns compact locally.
Dropped bodies stay as inspectable cites, not an LLM rewrite of your history. Compact
one side or rewind from a point.

**Memory and playbook** — workspace and user facts reinjected every turn, surviving
compaction. Helpful and harmful lessons from verified work accumulate incrementally;
verified facts can graduate into skills.

**Shared board** — structured notes for facts, failures, and paths. Peers and solo
sessions coordinate through a gist each turn; divergence detection keeps summaries
aligned without spamming the thread.

**Peers** — teammates with the same tools, an isolated thread, and the shared board.
Manual `/peers` always works; optional auto peers are task-gated when `peer=on`.
Name a model in plain words like `sonnet 5 from anthropic` to pin it. Depth capped;
nested peers denied. Optional git worktrees for isolation.

**Ranked repo map** — personalized file-graph rank + symbol packing (4k cap); no tree-sitter, no dump.
Volatile status and the map refresh on the user message, not the cached system prefix.

**Credential-aware models** — the list matches what your login actually offers.
Subscription and API windows capped correctly. Auto effort plus every reasoning
level the model declares. Vision when supported.

**Permissions** — ask before sensitive tools; plan is read-only until you go; yolo
is session-only and never persisted. Deterministic allowlist DSL (named args,
`#fallback=ask`), session shrink-only rules, sandbox, Shift-Tab cycling. No
learned classifier and no policy dump into the prompt.

**Handoff and specs** — `/handoff [goal]` writes a reviewable packet (paths,
board, recall ids) without dumping the last reply. `/spec` keeps
requirements→design→tasks on disk and injects only the active task pointer.

**Git auto-commit** — opt-in `/settings git_auto=on` (dirty snapshot + per-edit
commits with omfx trailer). `/undo` is SHA-gated against the last omfx commit.

**Headless JSONL** — `omfx ask --json` streams session/tool/permission/result
events for CI hosts; events never enter the model thread.

**Web fallback chain** — nineteen search backends in your order; test the chain;
first working provider wins. Set order by picking, not by typing ids.

**Skills** — discovered from your other agent CLIs, stackable in one prompt or
mid-sentence, with file anchors inline. Reload rescans.

**External IDE** — `/ide open` launches code, cursor, zed, and friends on the
workspace. Separate from ctrl-g's terminal editor.

**Plugins** — marketplaces via `/plugin marketplace add` (`.claude-plugin` / `.omfx-plugin`).

**Browser relay** — your open Chrome tabs via a local listener, not a headless farm.

**MCP** — your configured servers only; no remote gateway. Many servers allowed.

**Hybrid search** — `semantic_search` fuses repo rank, symbols, and tokens. No
embeddings required.

**Sessions** — save, resume, rewind, fork, handoff, undo. Background shell runs
survive clear.

**Cache-stable rules** — project rules parsed into a contract, not dumped wholesale.
System prefix stays stable; orientation changes every turn. Provider caching always on.

**Context audit** — provider totals versus local parts: system, tools, transcript,
cache read and write.

**Your keys** — OAuth or API keys stored locally; stored login beats leftover env
vars. Hooks deny risky calls and redact secrets in output. Telemetry off unless asked.
Run logs stay local with no prompt text uploaded.

## Vs the field

Thin harness, thick honesty: parse gate, ARC cites, deterministic handoff packets,
named-arg permissions, and opt-in git auto-commit — without dumping transcripts
or policy into the model context. Field notes: [docs/compare.md](docs/compare.md).

## Use

```
omfx                         Interactive full-screen session
omfx ask <prompt>            One-shot request (no alt screen)
omfx ask --json <prompt>     JSONL events for CI / hosts
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
- [Compare](docs/compare.md)
- [Slash commands](docs/using/slash-commands.md)
- [Sessions](docs/using/sessions.md)
- [Runs](docs/using/runs.md)
- [Specs](docs/using/specs.md)
- [JSONL](docs/using/jsonl.md)
- [Tools](docs/capabilities/tools.md)
- [Peers and board](docs/capabilities/peers.md)
- [IDE](docs/capabilities/ide.md)
- [Plugins](docs/capabilities/plugins.md)
- [Configuration](docs/configure/configuration.md)

## License

[MIT](LICENSE)
