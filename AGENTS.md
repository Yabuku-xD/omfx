# AGENTS.md

Instructions for agents working in this repository.

## Layout

- `src/main.zig` is the composition root. Do not add leaf feature logic here.
- `src/core/` owns contracts (config, CLI parse, sessions, permissions, ids); `src/providers/` HTTP vendor adapters, never product state; `src/tools/` built-in tools; `src/cli/` the interactive surface.

## Zig

Follow `.agents/skills/zig-best-practices/SKILL.md` for `.zig` files.

- Tagged unions for exclusive states (`ChatOutcome`, `Parsed`, `Credential`, `slash.Name`, `tool.Name`, `live.Live`).
- Named error sets on public functions. Collapse `std.http` failures to `error.Transport`, not `anyerror`. Distinct ids live in `src/core/ids.zig`; env lookup is `env.Lookup`, never `anytype`.
- Pass allocators into every allocating function. `defer` next to acquire, `errdefer` on error paths. Tests use `std.testing.allocator`.
- `const log = std.log.scoped(.module)` per file. Log mkdir/persist/wait failures; do not swallow them.
- Exhaustive `switch` on `tool.Name` and `slash.Name`. Prefer `comptime T: type` over `anytype`. Format with `zig fmt` before committing.

## Style

- CLI flags are kebab-case.
- Do not use emojis in code or docs.

## Verify

Build with the binary at `./zig-out/bin/omfx` (`zig build` is ReleaseFast; `zig build test` stays Debug). Never use an installed `omfx` from PATH. After any change the user will run, also `zig build`: `zig build test` does not refresh that binary.

- `zig build test` — units, plus the `e2e ...` cases in `src/tools/dispatch.zig`
  that drive tools with the escaped JSON a model actually sends and assert the
  bytes on disk. Tool arguments arrive as JSON string values; `Args.str` decodes
  them once, so never read one with `sse.jsonString` directly.
- `scripts/e2e.sh` — the real binary, a real model, a scratch workspace, and an
  assertion that the workspace changed. Needs credentials and network. Run it
  before shipping anything that touches the loop, the tools, or the TUI.

A unit test proving a tool fired is not evidence the file is correct. Every bug
that shipped here was of that shape.

## Learned User Preferences

- Native Zig for product features.
- Keyboard-first TUI, no vim or modal keybindings. Activity phrases come from the model, not a table.
- Prefer TUI lists over extra slash commands. No stubs, placeholders, or competitor product names in source (docs are fine). Keep implementations minimal; style rewrites must not change behaviour or pixels.
- Treat AGENTS.md as the live rule file; never special-case its contents in source. Playbook lessons never collapse into it.
- Strip comments that restate the code. Persist last model, provider, mode and credentials; never reset to ask mode on launch.
- Mouse: press, release, and drag only. Never any-event tracking (`1003h`) -- it costs the terminal its drag-select. Bind hover-shaped features to a key or a click.
- Emphasis is colour, never weight. Table grids and diagram lines are content, not chrome: assistant foreground, not the dim border.
- Command answers are sentences, not `key=value`, via `chat.formatCommand` (muted, two-column gutter). Nothing writes raw text at column zero, menus included. A finished step confirms in the footer (`Session.note`, 3s) and leaves; only errors and menus stay in the scrollback.
- No default-model concept: last used model, provider and mode persist, which is not the same thing. `/model` aliases `/models`, not a second door.
- Reasoning level is `auto`, never "default": resolved per prompt, offered by every model that declares levels.

## Learned Workspace Facts

- Product is Oh My Fx (`omfx`); this checkout may still be named `ffx`. Zig 0.16.0+, no registered dependencies. MIT license.
- Homemade ANSI TUI (not libvaxis). Sticky-footer composer, transcript pinned above it.
- User data: `~/.omfx/auth.json` (0600), `~/.omfx/settings.json`; workspace playbook is `.omfx/playbook.jsonl`.
- Settings is `/settings` (no `/config`). `/login` lists model providers; `/web` lists search backends.
- Stored OAuth beats leftover `*_API_KEY` env vars. omfx is not a gateway and has no provider or API key of its own.
- AGENTS.md is parsed into a harness contract (`src/core/contract.zig`, 8 KiB cap), not dumped wholesale. Nested files apply.
- `/peers` starts a teammate (SSVP-lite). `/undo` is the last file op; `/rewind` and `/fork` cover history.
- `src/providers/registry.zig` fetches model catalogs into `~/.omfx/cache/`. Only Anthropic publishes reasoning levels; `models.zig` covers the rest. `authCap` clamps the window to the login route: a subscription and an API key differ for the same model.
- `src/core/autoeffort.zig` implements `auto` (Damani ICLR 2025, Snell ICLR 2025, arXiv:2604.14853): an archetype, not a difficulty. Easy and Hard both get the floor, the budget goes to the responsive middle. Two failed turns route *down*.
- Skills are discovered, not enumerated: `skills.home_roots` lists the known agent CLIs and `eachHomeRoot` walks `~/.<tool>/skills` one and two levels deep. Deduped by inode then name; dot-dirs skipped.
- Every skill is a slash command after the built-ins, with its `description:` as help. Several per prompt; system commands own the line. `/reload` rescans.
- Context accounting sums `input + output + cache_read + cache_write`; input alone reports an almost empty window on a cached turn. `/context` splits it: the total is the provider's, the parts omfx's.
- The system prompt must be byte-identical for the life of a session: providers cache by exact prefix, and Anthropic caching is opt-in (`cache_control`, 1h TTL on OAuth, 5m on an API key). Volatile orientation -- git status, repo map -- rides at the head of the user message, never in `assembleSystem`. `ChatFlags.cache_key` is per workspace so a resumed session reads the last one's cache. Caching is always on; there is no setting for it.
- Only headers a provider needs to answer are sent by default. Attribution (`http-referer`, `x-title`, `x-grok-conv-id`) is behind `telemetry`, off unless asked. Nothing else leaves the machine: `runlog` is local JSONL and holds no prompt or reply text.
- Command Code's /models publishes id, name and context_length only -- no modality -- so `models.zig` carries all 58 rows and is the sole source of the vision bit. `registry.Entry` has no vision field to merge.
- A workspace `.omfx/` appears only when written to: recall, playbook, board, `draft.txt`, `/fork`. The rest is in `~/.omfx`.
- Command Code is two rows on one key: `commandcode` (OpenAI shape) and `commandcode-anthropic` (Claude).
- `src/core/langs.zig` is the one language table (36 languages: extensions, comment and string syntax, a parse-only `check` argv). `lex.zig` scans with it; the repo map, the `read` outline, and `diag` read it. A new language is one row, never a second table.
- The repo map ranks files by how often their declared names appear elsewhere, not readdir order (RepoGraph, arXiv:2410.14684). It scans up to 4,096 files to pick the ~80 it emits, and names what it dropped.
- An edit that leaves a file unparseable is undone, not reported (`tools/gate.zig`; SWE-agent arXiv:2405.15793 measured +3.0pp). Only when the file parsed *before* it, or the model is stranded on a file it cannot repair.

## Traps This Repo Has Hit

- `readFileAlloc` with `.limited(n)` **errors** on a larger file; it does not truncate. Read with a real cap, scan a prefix. AGENTS.md is capped at `contract.file_max` (8000) and is dropped whole if it passes it.
- A borrowed transcript row (`setStatus`/`setQueued`/`setPinned`) must be unset in the same frame, or the next paint reads a dead stack frame.
- `zig fmt` rewrites `\u{...}` escapes to literal characters, so a replacement against the escape silently matches nothing.
- A placeholder that looks like speech becomes speech: `[tool <name>]` in the thread taught the model to say it. Omit the turn.
- Mouse reports are printable bytes; anything reading stdin consumes them whole (X10 payloads follow the final byte). `Transcript.append` is the one door into the pane and drops what is not valid UTF-8 -- three producers leaked there and fixing each did not hold.
- Measure table cells as drawn, not written: `**bold**` is eight characters and four cells.
- A scan that does not parse must abstain, not guess: a JS regex (`/[a-z]{2}/`) and a shell `case` label (`Darwin)`) read as stray brackets. `langs.balance = false` says so, and is allowed only where `check` answers. Wrong is worse than silent.
