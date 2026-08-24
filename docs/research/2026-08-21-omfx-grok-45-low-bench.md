# Oh My Fx (omfx) harness bench: grok-4.5, effort=low

**Date:** 2026-08-21
**Binary:** `./zig-out/bin/omfx` 7,283,136 bytes (6.95 MiB), version 0.0.1
**Live model:** `--provider xai-oauth --model grok-4.5 --effort low --json`
**Host:** macOS, Debug build

Re-run:

```
zig build test
python3 docs/research/bench-grok-45-low.py
python3 docs/research/bench-tools-live.py
```

Raw JSON: `docs/research/.bench-grok-45-low.json`, `.bench-tools-live.json`, `.bench-tools-followup2.json`.

---

## What to read first

1. Local CLI and slash dispatch work. Cold process is ~10 ms warm, ~170 ms first exec.
2. Compact stitch is cheap: **1.0 ms** for 143 KiB of turns. Session `/compact` is local JSONL, not an LLM.
3. Pass 1 (no tools on the wire): grok-4.5 Responses body omitted `tools`. Zero tool events.
4. Pass 2 (this update): Responses tools are flat `{type,name,parameters}` and **are sent**. After unescaping call arguments, **write, edit, bash sandbox, compact, memory, board, mcp, browser, web_fetch, peer** all fired. glob still panics `BADF` on `dir.iterate` in Debug.
5. `omfx ask` still leaks the reply allocation (DebugAllocator).

---

## Cold start

| Probe | wall | first byte | notes |
|---|---:|---:|---|
| first `omfx version` this session | 168.6 ms | | page-cache miss |
| warm `omfx version` | 10.4 ms | 7.8 ms | |
| `omfx --version` | 10.3 ms | 7.7 ms | |
| `omfx help` | 10.7 ms | 8.1 ms | 1298 bytes |
| `omfx doctor` | 10.0 ms | 7.5 ms | catalog dump |
| `omfx login` (list only) | 9.9 ms | 7.4 ms | no network |
| `omfx session` | 9.9 ms | 7.5 ms | |
| missing `omfx ask` | 7.8 ms | | exit 1, usage |
| unknown command / flag | 7.3-7.8 ms | | exit 1 |
| `omfx` with stdin not a tty |  | | `omfx: not a tty; use omfx ask` exit 1 |
| grok-4.5 ping TTFB | 1136 ms | **917 ms** | ~900 ms is the vendor |

Process overhead after warm is ~8-11 ms. Live TTFB is the API.

`omfx doctor` on this machine: `permission_mode=ask`, `sandbox=macos`, `provider=xai-oauth`, default model **grok-4.6** (overridden per ask).

---

## CLI subcommands

8 commands in `cli.commands`. All exercised.

| Command | Result |
|---|---|
| `help` / `-h` / `help <cmd>` | ok, per-command usage |
| `version` / `-V` | `omfx 0.0.1` |
| `doctor` | ok |
| `login` (no arg) | provider list, no hang |
| `session` / `session list` | prints `last` |
| `session last` | 793-byte jsonl dump |
| `install` no path | exit 1 usage |
| `install /tmp/.../dummy.mjs` | copied into `~/.omfx/extensions` (dummy removed after) |
| `browser-relay install` | wrote `~/.omfx/browser-relay/extension` |
| `browser-relay` listen | **not run** (blocks) |
| `ask` no prompt | exit 1 |
| unknown command/flag | exit 1, names the token |

`--resume` parses on `ask` and is **ignored** there. Resume only paints the TUI transcript (`main.zig` interactive path). `omfx ask` also does not persist `last.jsonl`.

---

## Slash commands (no TUI)

43 builtins dispatched through `cmds.dispatch` against a temp `$HOME` (26.5 ms total, 9107 bytes of output). `/clear` and `/reset` skipped: `freshSession` deinits `reads` and `State.deinit` would double-free in the test (same pattern as a TUI `/clear` then process teardown).

Covered: `/help`, `/help compact`, `/version`, `/status`, `/stats`, `/usage`, `/settings`, `/models`, `/model`, `/effort`, `/effort low`, `/fast`, `/permissions`, `/allowlist`, `/sandbox`, `/yolo`, `/thinking`, `/sound`, `/statusline`, `/appearance`, `/mcp`, `/skills`, `/workspace`, `/background`, `/feedback`, `/trace`, `/diagram` (no reply), `/copy`, `/undo`, `/continue`, `/peers` (usage), `/plan`, `/rewind list`, `/rename`, `/session`, `/compact` (12 jsonl lines -> keep_last), `/fork`, `/handoff`, `/login` menu, `/web` menu, `/browser` install into temp home.

Not driven live: `/peers <goal>` (would HTTP), `/plan go`, `/logout`, `/init` (writes `AGENTS.md` in cwd), TUI alt-screen, menus that wait for a key.

---

## Context taken

Measured in-process (`zig build test` BENCH lines). No vendor usage object is parsed; xAI `response.created` had `"usage":null`.

| Piece | Bytes | Receipt |
|---|---:|---|
| Postcard `prompt.text` | 1423 | `BENCH postcard_bytes` |
| Plan postcard | 178 | |
| Advertised tools | 24 names | `tool.Name` |
| OpenAI-compat `tools` JSON | 5527 | includes `peer` |
| tools JSON without peer | 5206 | |
| grok-4.5 Responses body (pass 1, no tools) | 156 | omitted `tools` |
| grok-4.5 Responses body (pass 2, dummy sys + tools) | **5380** | flat tools, `reasoning_effort` |
| Responses tools JSON | 5215 | not nested under `function` |
| Same prompt as OpenAI-compat body | 5729 | nested `function.name` |
| `assembleSystem` empty workspace | 1513 | postcard + empty extras |
| `assembleSystem` + plan | 1691 | |
| This repo `AGENTS.md` | 2129 | capped at 8000 |
| `git status -sb` here | 2439 | truncated at **1500** |
| Repomap cap | 4000 | 63 `.zig` files |
| grok-4.5 window | 500_000 tokens | `models.zig` |
| Layer-1 tool result cap | 12_000 | `compact.result_budget` |
| Char compact tripwire | 48_000 | `compact.char_budget` |
| Turn compact tripwire | 8 turns, keep 4 | `compact_after` / `keep_last` |

**Pass 1 wire:** instructions + input only. xAI echoed `"tools":[]`.

**Pass 2 wire:** same plus `"tools":[{type:function,name,description,parameters},...]`. Body 5380 B. xAI function-calling docs (flat schema, not chat-completions nested).

`--effort low` is serialized as `"reasoning_effort":"low"`. The early `response.created` snapshot still showed `"reasoning":{"effort":null}`.

Token estimate (chars/4, not billed): empty-ws system ~380 tokens; this repo system ~2-4k tokens after git/repomap caps; tools would add ~1.4k tokens **if they were sent**.

---

## Compact / compression overhead

Local CPU only. `snipThread` / `microThread` exist and are **never called** from `chatOnce`. Live loop compact is `stitch` after each tool result. `omfx ask` never grew a thread, so live stitch did not run.

| Case | ns | ms |
|---|---:|---:|
| stitch 8 small turns (keep) | 50_875 | 0.051 |
| stitch 12 small turns (applied) | 252_250 | 0.252 |
| stitch 12 turns, 143_004 chars | 989_708 | **0.990** |
| `capResult` 13_000 -> 12_000+notice | 143_667 | 0.144 |
| 43 slash cmds including `/compact` | 26_513_500 | 26.5 |

Tripwire in test: fat stitch < 50 ms. Headroom is ~50x.

`/compact` on session jsonl is `Store.compactNow`: keep last 4 lines, one summary line, no HTTP. Distinct from HTTP-thread `stitch` (keep original user + tail).

---

## Live grok-4.5 `--effort low`

Workspace `/tmp/omfx-bench-ws` (`hello.txt`, `note.md`). `--yolo` on tool prompts.

| Name | wall s | TTFB s | tool events | What happened |
|---|---:|---:|---:|---|
| ping | 1.136 | 0.917 | 0 | streamed `pong`, result `pong` |
| list | 1.805 | 1.010 | 0 | prose about listing; **did not call `list`** |
| read | 1.360 | 0.809 | 0 | prose about reading; **did not call `read`** |
| bash | 1.170 | 1.001 | 0 | no `output_text`; result = raw SSE `response.created` dump |
| mermaid | 1.286 | 0.889 | 0 | streamed a mermaid fence; **result event was only ````\n`** |
| compact tool | 1.223 | 1.049 | 0 | same SSE dump; compact tool never ran |

All six Debug runs printed `ensureNl` leak at `agent.zig` (returned slice not freed in `omfx ask`).

Thinking JSONL: 0 chars. `/thinking` defaults off, and `Live.think` drops think when `ThinkView` is `.hidden`.

---

## The two groups that were untested (pass 2)

Pass 1 listed these as unproven because tools never left the client. Pass 2 sent Responses tools, skipped empty `function_call` stubs, and unescaped `arguments` so `jsonString(..., "path")` works.

Workspace `/tmp/omfx-bench-tools3` unless noted. `--yolo`. grok-4.5 `--effort low`.

### Group 1 — files + sandbox + diagram

| Item | Fired | Wall s | Proof |
|---|---|---:|---|
| write | yes | 3.34 | `created.txt` = `created-by-omfx`; JSONL `write run created.txt` |
| edit | yes | 7.95 | `note.md` became `gamma beta`; undo ` .omfx/undo/1` |
| grep | yes | (pass 2 files group, then glob crash) | JSONL `grep run` / `grep done` twice |
| glob | **crash** | 1.87 | Debug panic `posixSeekTo` `BADF` on `dir.iterate` |
| patch | not isolated | | files group died on glob before patch |
| bash sandbox | yes | 4.93 | result `sandbox: seatbelt net-deny` for `curl -sI https://example.com` |
| diagram save | fence yes, file no | 4.05 | JSON `result` is the mermaid fence; `.omfx/diagrams/` empty (`extract` saw no fence) |

### Group 2 — harness tools

| Item | Fired | Wall s | Proof |
|---|---|---:|---|
| memory | yes | 4.83 (batch) | `memory run/done` |
| board | yes | | `board run/done` twice. File is `.omfx/board.jsonl` not `board.md` |
| mcp | yes | | `mcp run/done`; no servers configured |
| browser | yes | | `browser run/done`; relay not listening |
| web_fetch | yes | | `web_fetch run/done` |
| web_search | retry only | | batch result text mentioned it; no `web_search run` JSONL |
| compact tool | yes | 3.31 | **skipped: under turn/char budget** (honest; 1-turn ask) |
| peer | yes | **23.24** | 100 tool events: peer + nested list/read/bash/board |
| recall cites | no | 4.46 then crash | `read` of `fat.txt` then glob `BADF`; no `.omfx/recall/` |

TUI-only still: alt screen, footer, `/thinking` visibility, permission prompts.

---

## Engineering findings

Must (pass 1, now closed or moved):

1. **Responses tools.** Closed: `ToolShape.responses` is flat `name`+`parameters`. Body 5380 B. xAI docs: `/v1/responses` + `tools: [{type:function,name,...}]`.
2. **Empty `function_call` stubs.** Streaming emits `arguments:""` then a second item with the JSON. `collectCalls` now skips empty args. Without this, write was `MissingPath` in a doom loop.
3. **Escaped arguments.** `arguments` is a JSON string; `jsonString` does not unescape. `sse.unescapeAlloc` on the dupe. Write/edit started working after this.
4. **Streamed text vs `result`.** HostWriter now concatenates deltas into `answer`. Mermaid `result` is the full fence (was ````\n` in pass 1).
5. **`omfx ask` leaks `reply`.** Still true.

Open:

6. **glob `BADF`.** `search.glob` / `dir.iterate` + Debug `posixSeekTo`. Reproduced on `glob pattern=*.txt` alone. grep can finish; glob panics.
7. **diagram extract vs streamed fence.** Reply contains the mermaid fence; `save` returned `.none`.
8. `ask --resume` unused. Ask does not persist sessions.
9. L3 snip/micro still dead in the loop.
10. No spend meter.

---

## Numbers to quote

- Warm CLI: **10 ms**
- First exec: **169 ms**
- grok-4.5 low ping: **1.14 s** wall, **0.92 s** TTFB
- Compact 143 KiB stitch: **1.0 ms**
- write (live): **3.3 s**; edit: **8.0 s**; sandbox curl: **4.9 s**; compact skip: **3.3 s**; peer: **23.2 s**
- Postcard: **1423 B**; chat tools JSON **5527 B**; Responses tools **5215 B**; Responses body **5380 B**
- Binary: **6.95 MiB**
