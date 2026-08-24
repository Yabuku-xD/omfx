# Oh My Fx (omfx) vs the 2026 coding-agent CLI field

**Date:** 2026-08-20
**Honesty:** this is the **binary as built today**, not the original four-tool postcard. Sources: this tree, `docs/research/2026-08-20-harness-internals-2026-leaders.md`, `docs/research/2026-08-20-coding-agent-cli-landscape.md`, plus 2026 field maps (Tembo, Pinggy, DEV “30+ tools”).

`omfx` is a Zig 0.16 Unix-shell agent: 23 named tools, 65 catalog backends, OAuth-then-API-key, seatbelt/bwrap on `bash`, TypeScript extension host. It is **not** Pi (four tools, Node). It is **not** fx (Vercel Gateway only). It is **not** Claude Code / Codex (vendor TUI-IDE).

Legend: **W** omfx is stronger on this axis · **T** different trade · **L** they win.

---

## The field (every CLI that matters, grouped)

### Vendor subscriptions (they host the model)

| CLI | Runtime | Harness shape | Lock-in |
| --- | --- | --- | --- |
| Claude Code | huge TS + native wrapper | while-loop, hooks, 5-layer compact, OS sandbox + classifier | Claude-first |
| Codex CLI | Rust | Responses loop, apply_patch, OS sandbox net-off, encrypted compact | ChatGPT / Responses |
| Gemini CLI | Node | policy engine, JSONL headless | Gemini; consumer path → **Antigravity** (closed) |
| Antigravity CLI | closed | parallel agents, built-in Chrome | Google |
| Copilot CLI | Node + exe | plan/autopilot, GitHub MCP, cloud `&` | Copilot seat |
| Amp | Node | thread + handoff (no compact), oracle/librarian | Amp router |
| Cursor CLI | Node | IDE-spawned agent | Cursor |
| Amazon Q CLI | native | AWS-specialized agents | AWS |
| Kiro | Amazon | spec-first (requirements before code) | AWS |
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
| Cline CLI | Node | 30+ providers, parallel agents | IDE→CLI |
| Continue `cn` | Node | same engine as IDE; CI checks | Continuous AI |
| OpenHands | Python | autonomous + browser + CI headless | former OpenDevin |
| Qwen Code | Node (Gemini-CLI fork) | Qwen3-Coder | living Gemini-CLI fork |
| Forge | Rust | forge / sage / muse split | 300+ BYOK models |
| Plandex | Go | cumulative-diff sandbox, huge index | maintenance-mode |
| Kilo Code | Node (OpenCode-based) | Roo successor | free model pack |
| Mistral Vibe | — | Devstral | Le Chat |
| Kimi CLI | — | K2.5 256k | also a backend for others |
| OpenClaw | Node (Pi SDK) | Chinese-model gateway | built on Pi |

### Not CLIs (exclude from “harness” ranking)

Cursor / Windsurf / Zed / Cline-in-VS-Code / Continue-in-IDE are editors. Ollama / llama.cpp / vLLM / LM Studio are inference. OpenRouter is a router.

---

## omfx as built today

| Piece | Now |
| --- | --- |
| Loop | Zig `chatOnce`: model → tools → observe until text. Plan mode blocks writes. |
| Tools | **23** in `tool.Name` (read/write/edit/bash + glob/grep/list/copy/mkdir/delete/rename/file_info/open_file/semantic_search/web_fetch/web_search/ask_user/memory/browser/peer/board/mcp/patch). Prompt still *names* four as core. |
| Providers | **65** catalog rows, three wire codecs (OpenAI-compat, Anthropic messages, OpenAI responses). Direct keys. No omfx-as-gateway. |
| Auth | Same ladder every backend: OAuth env → stored OAuth → vendor API-key env → stored key. Device/PKCE `/login`. |
| Permissions | ask / auto / yolo. Hard deny is `settings.json`. AGENTS.md is behavior text, not the deny list. |
| OS sandbox | `bash` via macOS `sandbox-exec` (net-deny, write-restrict) or Linux `bwrap --unshare-net`. Honest `none` if missing. Toggle `/sandbox`. |
| Compact | ARC-lite: tool bodies >12k → `cite rN`. Stitch after 8 turns, keep last 4. **Never encrypt.** Observation trim (ANSI/CR, RLE, first5+last10). |
| Peers | `peer` tool, `max_peer_depth=1`, lazy git worktree `.omfx/peers`. Board posts. |
| Extensions | `extensions/host` parses `registerTool` / `registerCommand` / `registerProvider`. `/reload`. User `.mjs` via `omfx install`. |
| Form | Full-screen + 3-line sticky footer; `omfx ask` is a pipe. Temp TUI, not Crush/OpenCode chrome. |
| MCP | One `mcp` tool, not a dumped catalog in the system prompt. |
| Headless | `omfx ask`. No Gemini-class JSONL event stream yet. |

---

## Harness axes (engineering, not star count)

| Axis | omfx | Claude | Codex | OpenCode | Pi | fx | Crush | Goose | Aider | Copilot | Amp | Gemini/Qwen |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Loop runtime | Zig **W** | TS huge **L** | Rust **T** | Node **L** | Node **L** | Zig **T** | Go **T** | Rust+V8 **L** | Python **L** | Node **L** | Node **L** | Node **L** |
| Advertised tools | 23, prompt says 4 **T** | 8+ plugins **L** | shell+patch+MCP **T** | 12+ **L** | **4 W them** | ~26 **L** | many **L** | MCP kitchen **L** | edit formats **T** | files+GH MCP **L** | oracle+… **L** | files+shell **T** |
| Provider coverage | 65 names, 3 codecs, no login-to-omfx **W** | Claude-first **L** | Responses **L** | 75+ **T** | dozens + OAuth **T** | Gateway only **L** | Catwalk **T** | 15+ + ACP **T** | LiteLLM **T** | Copilot models **L** | Amp router **L** | Gemini/Qwen **L** |
| Auth quality | OAuth then key, stored JWT beats leftover `*_API_KEY` **W vs fx** | OAuth Claude **T** | ChatGPT **L** | `auth login` **T** | Pi auth.json **T** | Vercel OAuth **L** | env/catwalk **T** | recipes **T** | env **T** | gh auth **L** | passkey **T** | Google login **T** |
| User extensions | TS host ABI **T** | hooks/plugins **T** | skills/plugins **T** | plugin SDK **T** | in-process `/reload` **W them** | skills+MCP only **L** | limited **L** | recipes **T** | conventions **L** | plugins **T** | plugins **T** | marketplace **T** |
| OS sandbox | seatbelt/bwrap on bash **T** | bwrap + classifier **W them** | seatbelt net-off **W them** | policy only **L** | none in core **L** | macOS + billed reviewer **T** | crushrc **L** | recipes **L** | git only **L** | hooks **T** | orbs **T** | policy **L** |
| Permission DSL | ask/auto/yolo + settings.json **T** | modes + classifier **W them** | approval policy **T** | last-match DSL **W them** | YOLO **L** | ask/auto/yolo **T** | auto-approve **L** | allowlist **T** | git undo **L** | autopilot **T** | plugin perms **T** | TOML allowlist **T** |
| Compact | local cite+stitch, never encrypt **T** | 5-layer **W them** | encrypted blob **L** | autocompact **T** | tree + hooks **W them** | N-turn **T** | SQLite **T** | sessions **T** | repo map **W them** | 95% window **T** | **handoff W them** | history compress **T** |
| Subagents | peer depth 1, worktree **T** | isolated window **W them** | yes **T** | `task` **T** | extension **T** | in core **T** | no **L** | MCP **T** | no **L** | parallel specialists **W them** | oracle/librarian **W them** | ext **T** |
| Form factor | Unix + sticky footer **W vs TUI-IDEs** | TUI-IDE **L** | TUI+IDE **L** | TUI-IDE **L** | TUI **T** | claims Unix, real TUI engine **T** | Charm TUI **L** | desktop **L** | Unix **T** | alt-screen **L** | TUI+web **L** | TUI **T** |
| Headless | `ask` **T** | `-p` SDK **W them** | CI + MCP-server **W them** | `run` JSON **W them** | `-p` RPC **W them** | `fx ask` WASM **T** | weak **L** | API **T** | `--message` **T** | CI **T** | `-x` JSON **T** | JSONL **W them** |
| MCP in prompt | one tool **W** | first-class dump **L** | first-class **L** | first-class **L** | omit **T** | lazy search **T** | yes **L** | MCP-first **L** | none **T** | GH MCP **L** | lazy via skills **T** | yes **L** |
| Lock-in | your keys **W** | Anthropic **L** | OpenAI **L** | open + Zen **T** | open **T** | Vercel **L** | Hyper optional **T** | open **T** | open **T** | GitHub **L** | Amp **L** | Google/Alibaba **T** |

---

## What omfx actually wins (not “more features”)

| vs | They still win | omfx is better because |
| --- | --- | --- |
| **Claude Code** | sandbox classifier, 5-layer compact, hooks product, SWE-bench | provider-open; no Anthropic gravity; no desktop/Slack/Chrome; MCP is one tool |
| **Codex** | kernel sandbox + net-off default, apply_patch maturity, cache-stable prompts | not ChatGPT-locked; compact is inspectable (`cite rN`), not `encrypted_content` |
| **OpenCode** | permission DSL, LSP, 75+ via AI SDK, JSON `run` | Zig loop; two/three codecs in-process; extras are not a TUI-IDE |
| **Pi** | four-tool prompt, live `/reload`, session trees | native loop; bash is actually sandboxed; leftover `XAI_API_KEY` cannot steal SuperGrok |
| **Oh My Pi** | LSP, browser polish, 80k LoC natives | same idea (batteries) but still a small Zig core + TS host, not a second IDE |
| **fx** | WASM embed, 7.8 MiB polish | **direct** Anthropic/OpenAI/xAI/Groq/Ollama/…; no `fx login`; OAuth stored in `~/.omfx/auth.json` |
| **Crush** | Go binary + Catwalk live catalog | not a Charm TUI; TS `registerProvider`; 65 backends without a network catalog fetch |
| **Goose** | MCP/ACP depth, recipes, governance | advertised surface is still a coding loop, not 70 MCP extensions + desktop V8 |
| **Aider** | repo map, git-native undo, edit-format robustness | tool-agent (not diff-paste); extensions; native binary |
| **Copilot / Amp / Cursor / Q / Warp** | GitHub/AWS/IDE/orbs | no vendor runtime; keys you already have; `omfx ask` is a pipe |
| **Gemini CLI / Antigravity / Qwen Code** | JSONL headless, free Gemini quota | not a sunset/replace cycle; not Gemini-only |
| **Forge / Plandex / OpenHands / Cline / Continue / Kilo** | specialist splits, huge index, CI agents | one composition root (`src/main.zig`); Unix default; not Python/Node product sprawl |

---

## Where omfx is behind (do not market these)

| Gap | Who already has it | Notes |
| --- | --- | --- |
| Four-tool advertised set | Pi | We *say* four; we *ship* 23 schemas. Prompt bloat is real. |
| Last-match permission DSL | OpenCode | ask/auto/yolo is coarser |
| Classifier auto-approve | Claude | we will not take this as a hard dep |
| Encrypted/server compact | Codex | refuse; keep cite+stitch |
| Handoff-instead-of-compact | Amp | optional later |
| Repo map | Aider | cheap context win we do not have |
| Session trees / fork | Pi | linear sessions today |
| JSONL event stream | Gemini, OpenCode | `ask` prints text |
| WASM/ACP embed | fx, Goose, OpenCode | stub/host only |
| Live Catwalk-style model fetch | Crush, OpenCode | bundled `models.zig` for xAI; not live `/v1/models` |
| Parallel tool calls | Claude, Copilot | serial loop |
| apply_patch maturity | Codex, OpenCode | we have `patch`; not battle-tested |

---

## How to read “better harness”

It is **not** better at sandbox than Codex, **not** better at compaction than Claude, **not** better at live extensions than Pi, **not** smaller-in-prompt than Pi.

It **is** the intersection:

```
native loop              (fx, Codex, Crush, Forge)
  × first-class providers (OpenCode, Pi, Crush, Goose)
  × OAuth-then-key        (Pi; omfx now matches)
  × OS sandbox on bash    (Codex/Claude class, not Pi)
  × user TS extensions    (Pi ABI, not fx)
  × no vendor gateway     (not fx, not Claude, not Codex, not Copilot)
  × Unix + footer         (not OpenCode / Crush / OMP / Warp)
  × inspectable compact   (not Codex encrypted_content)
```

If a row is **L**, do not claim it. Close it or leave it as a package.

---

## Method notes

- Star counts omitted on purpose (OpenCode ~140–190k, Claude Code ~140k, Gemini CLI ~106k — popularity ≠ harness).
- “CLI” here means: reads/edits a repo and runs commands from a terminal. IDEs and inference runtimes are listed only so they are not silently compared.
- omfx tool count: `src/core/tool.zig` `Name` enum (23). Provider count: `src/providers/catalog.zig` `all` (65). Auth ladder: `src/providers/auth.zig` `resolveSource`. Sandbox: `src/tools/bash.zig` `SandboxKind`.
