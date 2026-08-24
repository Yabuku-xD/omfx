# Oh My Fx (omfx) vs the 2026 coding-agent CLI field

**Date:** 2026-08-21
**Honesty:** the **binary as built today** (`./zig-out/bin/omfx`, 2.4 MiB). Not the four-tool postcard. Not a SWE-bench ranking.

Sources: this tree; Tembo 15-CLI guide; Pinggy mid-2026 ranked list; `docs/research/2026-08-20-harness-internals-2026-leaders.md`; `docs/research/2026-08-20-coding-agent-cli-landscape.md`.

Legend: **W** omfx is stronger on this axis · **T** different trade · **L** they win.

A **harness** is the loop around the model: tools, permissions, compact, providers, extensions, sessions. Engineering is how that loop is built (runtime, codecs, auth, composition). Star counts are omitted.

---

## Verdict

omfx is **not** the best harness overall.

Claude Code still wins productized compaction, hook pipeline, and sandbox+classifier. Codex still wins kernel sandbox (net off by default) and apply_patch. OpenCode still wins OSS TUI-IDE, last-match DSL polish, LSP, JSON `run`. Pi still wins shortest prompt, live `/reload`, session trees. Aider still wins git-native undo and tree-sitter repo maps. Amp still wins handoff-instead-of-compact. Goose still wins MCP-as-the-product.

omfx is the **intersection** that none of those occupy:

```
Zig loop, 2.4 MiB
  x 66 direct backends, 3 wire codecs, no omfx-as-gateway
  x OAuth-then-API-key (stored JWT beats leftover *_API_KEY)
  x OS sandbox on bash (seatbelt / bwrap, net deny)
  x last-match settings.json + ask/auto/yolo
  x user TypeScript extensions (host is not the loop)
  x inspectable compact (cite rN, never encrypt)
  x Unix + sticky footer (not an IDE in the terminal)
```

If a row is **L**, do not claim it.

---

## The field (every CLI that matters)

### Vendor subscriptions (they host the model)

| CLI | Runtime | Harness shape | Lock-in |
| --- | --- | --- | --- |
| Claude Code | huge TS + native wrapper | while-loop, hooks, 5-layer compact, OS sandbox + classifier | Claude-first |
| Codex CLI | Rust | Responses loop, apply_patch, OS sandbox net-off, encrypted compact | ChatGPT / Responses |
| Gemini CLI | Node | policy engine, JSONL headless | Gemini; consumer path ended 2026-06-18, replaced by **Antigravity** (closed) |
| Antigravity CLI | closed | parallel agents, built-in Chrome | Google |
| Copilot CLI | Node + exe | plan/autopilot, GitHub MCP, cloud `&` | Copilot seat |
| Amp | Node | thread + handoff (no compact), oracle/librarian | Amp router |
| Cursor CLI | Node | IDE-spawned agent | Cursor |
| Amazon Q CLI | native | AWS-specialized agents | AWS |
| Kiro | Amazon | spec-first (requirements before code) | AWS |
| Droid (Factory) | — | enterprise factory agent | Factory |
| Augment CLI | — | enterprise context | Augment |
| Warp 2.0 | Rust terminal | spawns Claude/Codex/Antigravity as sub-agents | Warp / AGPL client |

### Open-source BYOK (you bring keys)

| CLI | Runtime | Harness shape | Distinctive |
| --- | --- | --- | --- |
| OpenCode | Node + TUI | permission DSL, 75+ providers, LSP, ACP | most-starred OSS CLI |
| Pi | Node/Bun | 4 tools, TS extensions, tree sessions | shortest prompt, `/reload` |
| Oh My Pi | TS + Rust natives | Pi ABI + 31 tools + LSP + browser | cautionary bloat |
| fx | Zig | Gateway client, ~26 tools, ACP/WASM | 7.8 MiB, Vercel gravity |
| Crush | Go | Charm TUI, Catwalk catalog, LSP-as-context | mid-session model switch |
| Goose | Rust + desktop | MCP-native, recipes, ACP client+server | Linux Foundation |
| Aider | Python | edit-formats + git commit, repo map | not a tool-agent |
| Cline CLI | Node | 30+ providers, parallel agents | IDE then CLI |
| Continue `cn` | Node | same engine as IDE; CI checks | Continuous AI |
| OpenHands | Python | autonomous + browser + CI headless | former OpenDevin |
| Qwen Code | Node (Gemini-CLI fork) | Qwen3-Coder | living Gemini-CLI fork |
| Forge | Rust | forge / sage / muse split | 300+ BYOK models |
| Plandex | Go | cumulative-diff sandbox, huge index | maintenance-mode |
| Kilo Code | Node (OpenCode-based) | Roo successor | free model pack |
| Mistral Vibe | — | Devstral | Le Chat |
| Kimi CLI | — | K2.5 256k | also a backend for others |
| OpenClaw | Node (Pi SDK) | Chinese-model gateway | built on Pi |

### Not CLIs (exclude from harness ranking)

Cursor / Windsurf / Zed / Cline-in-VS-Code / Continue-in-IDE are editors. Ollama / llama.cpp / vLLM / LM Studio are inference. OpenRouter is a router. Warp is a terminal that *hosts* agents.

---

## omfx as built today (receipts)

Regenerate before quoting these anywhere:

```
ls -l zig-out/bin/omfx                              # binary
find src -name '*.zig' | xargs cat | wc -l          # lines
grep -c '\.id = ' src/providers/catalog.zig          # provider rows
```


| Piece | Now | Receipt |
| --- | --- | --- |
| Loop | Zig `chatOnce`: model → tools → observe until text. Plan mode blocks writes. Extra calls in the same round run sequentially. | `src/core/agent.zig` |
| Tools | **26** in `tool.Name`. Prompt still *names* four as core plus search/patch/web. | `src/core/tool.zig`, `src/core/prompt.zig` |
| Providers | **66** catalog rows, three codecs (compat / Anthropic / Responses). Direct keys. No omfx-as-gateway. | `src/providers/catalog.zig` `all` |
| Auth | OAuth env → stored OAuth → vendor API-key env → stored key. Stored JWT beats leftover `*_API_KEY`. | `src/providers/auth.zig` |
| Permissions | ask / auto / yolo + `settings.json` last-match. Hard deny is settings, not AGENTS.md. | `src/core/permissions.zig` `matchLast` |
| OS sandbox | `bash` via macOS `sandbox-exec` (net-deny) or Linux `bwrap --unshare-net`. Honest `none` if missing. | `src/tools/bash.zig` |
| Compact | ARC-lite: tool bodies → `cite rN`. Stitch after 8 turns, keep last 4. Template summary, **not** an LLM. **Never encrypt.** Snip/micro exist but are **not called** (cache-stable prefix). | `src/core/compact.zig`, `recall.zig` |
| Repo map | PEEK-lite: signature walk, 4000 chars / 80 files, no tree-sitter. | `src/core/repomap.zig` |
| Peers | `peer` tool, `max_peer_depth` default 1 cap 8, user-editable. Worktree `.omfx/peers`. `/fork` `/handoff`. | `settings.max_peer_depth`, `cmds.zig` |
| Stream | SSE tee; `output_text` is the answer; reasoning/`summary_text` is `.think`. TUI shows it only if `thinking=on`. | `sse.zig`, `tui.ThinkView` |
| Extensions | `extensions/host` `registerTool` / `registerCommand` / `registerProvider`. `/reload`. `omfx install`. | `extensions/host/index.mjs` |
| Form | Alt-screen + 3-row sticky footer. Temp TUI, not Crush/OpenCode chrome. | `src/cli/tui.zig` |
| MCP | One `mcp` tool. Catalogs do not dump into the system prompt. | `src/tools/mcp.zig` |
| Headless | `omfx ask`. `--json` emits typed events. Not Gemini-class JSONL. | `src/core/cli.zig` |
| Embed | `wasm_root.zig` is layout + compact + cli parse. No HTTP, no ACP server. | `src/wasm_root.zig` |
| Binary | **2.4 MiB** Zig 0.16, 27958 lines across core/providers/cli/tools/main. | `ls -l zig-out/bin/omfx`; `find src -name '*.zig' \| xargs cat \| wc -l` |

---

## Harness axes

| Axis | omfx | Claude | Codex | OpenCode | Pi | fx | Crush | Goose | Aider | Copilot | Amp | Gemini/Qwen |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Loop runtime | Zig **W** | TS huge **L** | Rust **T** | Node **L** | Node **L** | Zig **T** | Go **T** | Rust+V8 **L** | Python **L** | Node **L** | Node **L** | Node **L** |
| Binary | 2.4 MiB **W** | native wrapper **L** | musl Rust **T** | installer **L** | Node **L** | 7.8 MiB **T** | Go **T** | desktop **L** | PyPI **L** | Node+exe **L** | npm **L** | Node **L** |
| Advertised tools | 23 shipped, prompt says 4 **T** | 8+ plugins **L** | shell+patch+MCP **T** | 12+ **L** | **4 W them** | ~26 **L** | many **L** | MCP kitchen **L** | edit formats **T** | files+GH MCP **L** | oracle+… **L** | files+shell **T** |
| Provider coverage | 65 names, 3 codecs, no login-to-omfx **W vs fx** | Claude-first **L** | Responses **L** | 75+ **T** | dozens + OAuth **T** | Gateway only **L** | Catwalk **T** | 15+ + ACP **T** | LiteLLM **T** | Copilot models **L** | Amp router **L** | Gemini/Qwen **L** |
| Auth quality | OAuth then key, stored JWT beats leftover env **W vs fx** | OAuth Claude **T** | ChatGPT **L** | `auth login` **T** | Pi auth.json **T** | Vercel OAuth **L** | env/catwalk **T** | recipes **T** | env **T** | gh auth **L** | passkey **T** | Google login **T** |
| User extensions | TS host ABI **T** | hooks/plugins **T** | skills/plugins **T** | plugin SDK **T** | in-process `/reload` **W them** | skills+MCP only **L** | limited **L** | recipes **T** | conventions **L** | plugins **T** | plugins **T** | marketplace **T** |
| OS sandbox | seatbelt/bwrap on bash **T** | bwrap + classifier **W them** | seatbelt net-off **W them** | policy only **L** | none in core **L** | macOS + billed reviewer **T** | crushrc **L** | recipes **L** | git only **L** | hooks **T** | orbs **T** | policy **L** |
| Permission DSL | last-match settings.json + ask/auto/yolo **T** | modes + classifier **W them** | approval policy **T** | last-match DSL **T** | YOLO **L** | ask/auto/yolo **T** | auto-approve **L** | allowlist **T** | git undo **L** | autopilot **T** | plugin perms **T** | TOML allowlist **T** |
| Compact | local cite+stitch, never encrypt **T** | 5-layer **W them** | encrypted blob **L** | autocompact **T** | tree + hooks **W them** | N-turn **T** | SQLite **T** | sessions **T** | repo map **W them** | 95% window **T** | **handoff W them** | history compress **T** |
| Repo map | PEEK-lite signatures **T** | none as the trick **T** | none **T** | none **T** | none **T** | none **T** | LSP **T** | none **T** | tree-sitter **W them** | none **T** | code intel **T** | none **T** |
| Subagents | peer depth user-set, worktree **T** | isolated window **W them** | yes **T** | `task` **T** | extension **T** | in core **T** | no **L** | MCP **T** | no **L** | parallel specialists **W them** | oracle/librarian **W them** | ext **T** |
| Thinking UI | parse always, show iff `thinking=on` **T** | Ctrl+O + setting **T** | Ctrl+T + config **T** | `/thinking` **T** | thinking_delta **T** | — **T** | — **T** | — **T** | — **T** | — **T** | — **T** | hideThoughts **T** |
| Form factor | Unix + sticky footer **W vs TUI-IDEs** | TUI-IDE **L** | TUI+IDE **L** | TUI-IDE **L** | TUI **T** | claims Unix, real TUI engine **T** | Charm TUI **L** | desktop **L** | Unix **T** | alt-screen **L** | TUI+web **L** | TUI **T** |
| Headless | `ask` + `--json` **T** | `-p` SDK **W them** | CI + MCP-server **W them** | `run` JSON **W them** | `-p` RPC **W them** | `fx ask` WASM **T** | weak **L** | API **T** | `--message` **T** | CI **T** | `-x` JSON **T** | JSONL **W them** |
| MCP in prompt | one tool **W** | first-class dump **L** | first-class **L** | first-class **L** | omit **T** | lazy search **T** | yes **L** | MCP-first **L** | none **T** | GH MCP **L** | lazy via skills **T** | yes **L** |
| Embed | wasm stub **L** | Agent SDK **W them** | MCP-server **W them** | ACP **W them** | Node SDK **T** | WASM+ACP **W them** | — **L** | ACP **W them** | — **L** | — **T** | — **T** | — **T** |
| Lock-in | your keys **W** | Anthropic **L** | OpenAI **L** | open + Zen **T** | open **T** | Vercel **L** | Hyper optional **T** | open **T** | open **T** | GitHub **L** | Amp **L** | Google/Alibaba **T** |

---

## Engineering axes (how the loop is built)

| Axis | omfx | Typical field | Note |
| --- | --- | --- | --- |
| Composition | `src/main.zig` is a root. Leaf logic lives in `core/` `providers/` `tools/` `cli/`. | OpenCode/Claude: TUI and loop share a TS monorepo | AGENTS.md layout is enforced |
| Wire codecs | Three in-process: OpenAI-compat, Anthropic messages, Responses | OpenCode: Vercel AI SDK. fx: one Gateway client | No per-vendor modules in the binary |
| HTTP | Extra header bag forbids `content-type`/`authorization`/`host` (duplicate Content-Type was a 415) | most Node stacks: one header map | Zig std writes `headers.content_type` itself |
| Auth store | `~/.omfx/auth.json` 0600, Cursor JSON walker, exact keys (`xai` does not steal `xai-oauth`) | Pi similar; fx is Vercel session | Ladder is OAuth then key for **every** row |
| Stream parse | Tagged `Class` {answer, think, stop, other}; one `extract` pass | Pi/OpenClaw `thinking_delta`; Codex `show_raw_agent_reasoning` | Answer is never the reasoning body |
| TUI state | `ThinkView = hidden \| idle \| open` | two-bool flags elsewhere | Hidden cannot also be open |
| Settings | `Toggle.on\|off` for thinking; `max_peer_depth` u8 cap 8 | stringly "on"/"off" in several CLIs | Named budgets, compile-time floors |
| Prompt | Postcard + AGENTS.md + git + PEEK-lite + skill **names** | Claude 7–10k system; Pi <1k | We still ship 23 schemas. Prompt diet (layer 2) was refused |
| Compact | Template stitch, inspectable cites | Claude 5-layer LLM; Codex encrypted | Snip/micro **disabled** so the prefix stays cache-stable |
| Tests | `zig build test` on the same binary | mixed | Build with `./zig-out/bin/omfx` only |

---

## What omfx actually wins (not “more features”)

| vs | They still win | omfx is better because |
| --- | --- | --- |
| **Claude Code** | sandbox classifier, 5-layer compact, hooks product, surfaces | provider-open; no Anthropic gravity; no desktop/Slack/Chrome; MCP is one tool |
| **Codex** | kernel sandbox + net-off default, apply_patch maturity, cache-stable prompts | not ChatGPT-locked; compact is `cite rN`, not `encrypted_content` |
| **OpenCode** | TUI-IDE, LSP, 75+ via AI SDK, JSON `run` | Zig loop; two/three codecs in-process; extras are not a desktop |
| **Pi** | four-tool prompt, live `/reload`, session trees | native loop; bash is sandboxed; leftover `XAI_API_KEY` cannot steal SuperGrok |
| **Oh My Pi** | LSP, browser polish, 80k LoC natives | same idea (batteries) but Zig core + TS host, not a second IDE |
| **fx** | WASM embed, 7.8 MiB polish | **direct** Anthropic/OpenAI/xAI/Groq/Ollama/…; no `fx login`; OAuth in `~/.omfx/auth.json` |
| **Crush** | Charm TUI + Catwalk live catalog | not a Bubble Tea IDE; TS `registerProvider`; 65 backends without a network catalog fetch |
| **Goose** | MCP/ACP depth, recipes, LF governance | advertised surface is a coding loop, not 70 MCP extensions + desktop V8 |
| **Aider** | tree-sitter repo map, git commit/undo, edit-format robustness | tool-agent (not diff-paste); extensions; native binary. Our map is signatures only |
| **Cline / Continue / Kilo** | IDE heritage, CI agents, free model packs | one composition root; Unix default; not Node product sprawl |
| **OpenHands** | autonomous browser + CI headless | not a Python cloud agent |
| **Forge / Plandex** | agent split, 2M-token index | one loop; not maintenance-mode; not three personas |
| **Qwen Code** | living Gemini-CLI fork + Qwen3-Coder | not a sunset/replace cycle; not one-model |
| **Copilot / Amp / Cursor / Q / Warp / Droid / Augment / Kiro** | GitHub/AWS/IDE/orbs/factory | no vendor runtime; keys you already have; `omfx ask` is a pipe |
| **Gemini CLI / Antigravity** | JSONL headless, free Gemini quota (was) | not a closed successor |

---

## Where omfx is behind (do not market these)

| Gap | Who already has it | Notes |
| --- | --- | --- |
| Four-tool advertised set | Pi | We *say* four; we *ship* 24 schemas (compact added). Prompt bloat is real. Layer 2 was refused. |
| Classifier auto-approve | Claude | we will not take this as a hard dep |
| Encrypted/server compact | Codex | refuse; keep cite+stitch |
| LLM *narrative* summary | Claude 5-layer | we refuse the extra model call. ARC+SelfCompact is the paper path instead |
| Handoff-instead-of-compact | Amp | `/handoff` exists; not Amp-class |
| Tree-sitter repo map | Aider | PEEK-lite is signatures, 4k chars |
| Session *trees* | Pi | `/fork` copies; not a branchable tree |
| JSONL event stream | Gemini, OpenCode | `--json` is typed events, not a full turn protocol |
| WASM/ACP embed | fx, Goose, OpenCode | `wasm_root` has no HTTP |
| Live Catwalk-style model fetch | Crush, OpenCode | bundled `models.zig`; not live `/v1/models` |
| OS-thread parallel tools | Copilot specialists | extra calls, same round, sequential exec |
| apply_patch maturity | Codex, OpenCode | we have `patch`; not battle-tested |
| LSP-as-context | Crush, OpenCode, Oh My Pi | `symbols` is grep-shaped |
| In-process extension mutate | Pi | we **respawn** Node with scrubbed env (safer; not same-process live) |
| TUI chrome | OpenCode, Crush | temp alt-screen + footer. Layer 5 skipped |

### Paper-backed closes (2026-08-21)

| Axis | Paper | What shipped | Claim |
| --- | --- | --- | --- |
| Sandbox | Sandlock arXiv:2605.26298; Progent arXiv:2504.11703 | Linux Landlock+net unshare in the child (no bwrap binary when the kernel supports it); seatbelt secret-read deny; `.omfx/auth.json` / `.ssh` blocked in pathing | **On par** with OS-primitive sandboxes; **stricter** on secret reads. Not a microVM. |
| Compact | ARC arXiv:2607.25066; SelfCompact arXiv:2606.23525 | `compact` tool + rubric (model decides *when*); harness ARC cites (never LLM, never encrypt) | **Cheaper and more recoverable** than LLM-summary compact on tool traces. Not a 5-layer narrative summarizer. |
| Extensions | capability isolation (process boundary, not in-process JS) | `/reload` respawns Node; secret env names stripped | **Safer** than in-process plugins. DX is `/reload`, not Pi's same-process mutate. |

---

## How to read “better harness”

It is **not** better at sandbox than Codex, **not** better at compaction than Claude, **not** better at live extensions than Pi, **not** smaller-in-prompt than Pi, **not** a better TUI than OpenCode or Crush.

It **is** the only small native loop that is provider-direct, OAuth-then-key, OS-sandboxed, last-match-ruled, user-extensible in TypeScript, and inspectable when it drops context.

Close an **L** row or leave it as a package. Do not paper over it.

---

## Method notes

- “CLI” means: reads/edits a repo and runs commands from a terminal.
- omfx tool count: `src/core/tool.zig` `Name` (23). Provider count: `src/providers/catalog.zig` `all` (65).
- Auth ladder: `src/providers/auth.zig`. Sandbox: `src/tools/bash.zig`. Compact: `src/core/compact.zig`. Stream: `src/providers/sse.zig`.
- Parallelism claim is W&D-lite: multiple tool calls in one model step, executed one after another, no extra agents.
- Thinking visibility matches the field (parse always, show on a user toggle). Default off.
