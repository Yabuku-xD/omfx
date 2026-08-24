# Coding-agent CLI landscape (August 2026)

**Date:** 2026-08-20
**Purpose:** Evidence for a greenfield Unix-shell coding agent (`omfx`) that stays as small as [vercel-labs/fx](https://github.com/vercel-labs/fx) while beating the field on harness quality, provider coverage, and user-authored extensions.
**This is not an implementation plan.** The plan lives at `docs/plans/2026-08-20-001-feat-unix-coding-agent-plan.md`.

## Method

Primary sources first: official docs and GitHub READMEs. Secondary: curated lists and 2026 comparison articles. Star counts are a weak signal and are not used as a ranking.

- [bradAGI/awesome-cli-coding-agents](https://github.com/bradAGI/awesome-cli-coding-agents) (updated 2026-08-13, claims 110+ CLIs)
- [ishandutta2007/Awesome-CLI-Coding-Agents](https://github.com/ishandutta2007/Awesome-CLI-Coding-Agents)
- [fx.sh docs](https://fx.sh/docs) and [vercel-labs/fx](https://github.com/vercel-labs/fx) source (`AGENTS.md`, `src/builtins/tools.zig`, `src/core/gateway/model_catalog.zig`, `sdk/README.md`)
- [pi.dev docs](https://pi.dev/docs/latest) especially [Extensions](https://pi.dev/docs/latest/extensions), [Packages](https://pi.dev/docs/latest/packages), [Providers](https://pi.dev/docs/latest/providers), [Skills](https://pi.dev/docs/latest/skills), [SDK](https://pi.dev/docs/latest/sdk)
- [Armin Ronacher on Pi](https://lucumr.pocoo.org/2026/1/31/pi)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
- 2026 comparisons: [amux](https://amux.io/blog/best-terminal-ai-coding-agents-2026), [Tembo](https://www.tembo.io/blog/coding-cli-tools-comparison), [hidekazu-konishi](https://hidekazu-konishi.com/entry/cli_coding_agents_comparison.html), [DEV mid-2026 map](https://dev.to/soulentheo/coding-clis-in-mid-2026-the-engineers-map-and-what-changed-in-30-days-23p4)

Catalog entries C1-C12 are load-bearing (official docs read). C13-C50 are corroborated by at least one official README or a documented comparison matrix. C51+ include awesome-list entries whose READMEs were not all opened in this pass; treat language/license/provider cells marked `unknown` as unverified.

## How to read this

A **coding-agent CLI** reads/edits a repo and runs commands from a terminal. A **harness** is the loop around the model: tools, permissions, compaction, providers, extensions, sessions. "Beat the harness" does not mean "ship a heavier TUI." It means the loop is more reliable, more provider-open, more user-extensible, and still small.

---

## Executive findings

The field split in 2026 into three products that all claim "minimal" and mean different things:

1. **Lab-native TUI-IDEs** (Claude Code, Codex, Gemini CLI, OpenCode, Crush). Huge context, MCP, subagents, skills. They win daily-driver mindshare and lose on lock-in, binary/runtime weight, and prompt bloat.
2. **Gateway-shaped natives** (fx). Zig, ~8 MiB, ACP, WASM, skills, MCP, sandbox. Looks model-agnostic; auth and transport are Vercel AI Gateway. Source is not small: hundreds of Zig files, a real TUI render engine, and a 7k-line gateway client.
3. **Primitive cores** (Pi). Four tools (`read`, `write`, `edit`, `bash`), shortest system prompt, TypeScript extensions any user can drop in `~/.pi/agent/extensions/`, hot-reload, packages via `pi install`, agent-writes-its-own-tools. First-party providers number in the dozens. No baked permissions. Oh My Pi is the batteries-included fork of this idea and is already a TUI-IDE.

Nothing in the catalog is both (a) a small Unix-shell native, (b) first-class multi-provider without a single gateway, and (c) user-extensible the way Pi is, with (d) fx-grade permissions/sandbox and ACP/WASM embed.

That empty cell is `omfx`.

---

## Harness dimensions that actually matter

| Dimension | What "winning" looks like | Who is ahead | Who is behind |
| --- | --- | --- | --- |
| Core tool surface | Tiny advertised set; everything else is an extension | Pi (4 tools) | Claude Code / fx (15-25 named tools in prompt) |
| Provider coverage | Direct keys + OAuth + OpenAI-compat + local, mid-session switch | Pi, OpenCode, Aider | fx (Gateway only), Claude Code, Codex, Gemini |
| User extensions | Any user ships a file the agent can also write; hot reload | Pi (`ExtensionAPI`, `/reload`) | fx (skills+MCP only, no user TS/Zig plugin API) |
| Packages | `install` from npm/git, filterable | Pi packages | Most others: skills dirs or MCP servers |
| Permissions + sandbox | Allow/deny rules + OS sandbox, not yolo-or-nothing | fx, Codex | Pi (none in core; containerize yourself) |
| Embed | ACP + WASM/N-API + headless ask | fx | Pi (Node SDK + RPC; no WASM core) |
| Form factor | Unix shell, scriptable, not an IDE-in-the-terminal | Aider, fx `ask`, Goose | OpenCode, Crush, Claude Code, Oh My Pi |
| Session model | Tree/branch, not a linear log | Pi | Most CLIs |
| Compaction | Explicit, branch-aware, extension-hookable | Pi, Oh My Pi | Uneven |
| MCP | Lazy or out-of-core so catalogs do not blow the prompt | fx (`mcp_search_tools`), Pi (omit; use CLI) | Agents that dump every MCP tool into context |
| Skills | Agent Skills standard, progressive disclosure | Pi, fx, Claude Code | Aider |
| Binary/runtime | Single-digit MiB native, no Node to run the loop | fx, NullClaw | npm CLIs, Python CLIs |

---

## Deep dive: fx (the baseline we are beating)

Facts from [fx.sh](https://fx.sh/docs) and source, 2026-08-20:

- Zig 0.16, Apache-2.0, ~7.8 MiB, Unix-shell stated goal.
- Auth: `fx login` (Vercel OAuth) or `AI_GATEWAY_API_KEY`. Credential order is Vercel OIDC, env key, login session, setup key. Native addon "sends production credentials only to the canonical Vercel AI Gateway endpoint" (`sdk/README.md`).
- Model catalog is fetched from the Gateway (`src/core/gateway/model_catalog.zig`). Tests mention `anthropic/*`, `openai/*`, `xai/*`, `deepseek/*`, `zai/*`, `mistral/*` as Gateway ids, not first-party adapters.
- Built-in tools include `read_file`, `glob_files`, `grep_files`, `list_files`, `write_file`, `edit_file`, `delete_file`, `rename_file`, `copy_file`, `create_folder`, `file_info`, `semantic_search`, `open_file`, `web_fetch`, `web_search`, `terminal`, `memory`, `skill`, `install_skill`, `subagent`, `vision`, `ask_user_question`. Descriptions are long and policy-heavy.
- Permissions: `ask` / `auto` / `yolo`. Auto review is a *second* Gateway call to `openai/gpt-5.4`, billed extra, not user-selectable. macOS `os` sandbox; `none` elsewhere.
- Skills discovered from `.claude`, `.codex`, `.opencode`, `.agents`, `.claw` plus `~/.fx/skills/`. MCP only from trusted `~/.fx/mcp.json` (repo MCP files are never loaded — a real security win).
- Embed: `fx acp`, `createFxAgent()` / `createFxTerminal()` via WASM or N-API. WASM omits native processes, OS sandbox, native MCP, subagents, skills, web search.
- Source shape contradicts the marketing: `src/ui/render_engine/` is a full TUI, `src/gateway/client.zig` is thousands of lines, `src/core/input/` is an editor. Minimal binary, not minimal architecture.

**Gap vs fx:** first-class providers, user extensions, smaller core tool advertisement, no Vercel-shaped auth, keep ACP/WASM/permissions.

---

## Deep dive: Pi (the extension model we are stealing)

Facts from [pi.dev/docs/latest/extensions](https://pi.dev/docs/latest/extensions) and Ronacher (2026-01-31):

- Core tools: `read`, `write`, `edit`, `bash`. Shortest system prompt in the category.
- Philosophy: if it is missing, ask the agent to write an extension. Hot reload (`/reload`). Docs and examples ship so the agent can extend itself. Sessions are trees; side-quest a broken tool on a branch, rewind, summarize.
- Load paths: `~/.pi/agent/extensions/*.ts` (global), `.pi/extensions/*.ts` (project, after trust). Also `pi -e path.ts`, settings arrays, and packages.
- Factory: `export default function (pi: ExtensionAPI)`. Can `registerTool`, `registerCommand`, `registerShortcut`, `registerFlag`, `registerProvider`, subscribe to lifecycle events.
- Events include `project_trust`, `session_start`, `resources_discover`, `input`, `before_agent_start`, `tool_call` (can block), `before_provider_request`, `session_before_compact`, `session_shutdown`. That is a real harness ABI, not a skill dump.
- Packages: `pi install npm:@foo/bar@1.0.0` or `git:github.com/user/repo@v1`. Bundle extensions + skills + prompts + themes. Filterable. `pi update --extensions`.
- Skills: Agent Skills standard, progressive disclosure, `/skill:name`. Also reads `~/.agents/skills`.
- Providers: OAuth for ChatGPT/Claude/Copilot/xAI/OpenRouter/Radius; API keys for Anthropic, OpenAI, DeepSeek, Gemini, Bedrock, Mistral, Groq, Cerebras, Cloudflare, xAI, OpenRouter, Vercel AI Gateway, Fireworks, Together, Hugging Face, Kimi, MiniMax, Qwen, Xiaomi, ZAI, OpenCode Zen/Go, NVIDIA NIM, plus llama.cpp, Vertex, Azure, and custom OpenAI-compat via `models.json` or `registerProvider`.
- SDK: `createAgentSession()` in Node; RPC JSONL; print/JSON modes. OpenClaw is built on this.
- Deliberate omissions: no MCP in core, no permission popups, no plan mode, no subagents. Extensions can add all of them (`permission-gate.ts`, `plan-mode/`, `subagent/`, `gondolin/`).
- Security: extensions run with full user authority. Docs say containerize (Gondolin micro-VM, Docker, OpenShell).

**Gap vs Pi:** Pi is TypeScript/Node (or Bun binary), not a tiny Zig native; no OS sandbox in core; TUI is richer than a Unix shell; no WASM/ACP native core.

Oh My Pi (`can1357/oh-my-pi`, ~26k stars, TS+Rust) keeps the extension ABI and then bakes LSP, browser, Python, subagents, hash-anchored edits, async compaction. It is the cautionary tale: start from Pi, add "just a few" features, become a TUI-IDE. `omfx` must not become Oh My Pi.

---

## What is missing (the gap list)

### Harness gaps vs the field (what omfx must have)

G1. **User extensions as a first-class ABI**, not only skills/MCP. Drop-in TypeScript (and later Zig) modules; hot reload; the agent can write them. Pi is the source of truth ([docs](https://pi.dev/docs/latest/extensions)).

G2. **First-class providers**, not a single gateway. Direct Anthropic/OpenAI/Google/xAI/DeepSeek/Groq/Mistral/Bedrock/Azure/OpenRouter/Ollama/llama.cpp plus OpenAI-compat. Mid-session switch. Pi and OpenCode already do this; fx does not.

G3. **Tiny advertised tool set.** Four primitives in the system prompt. Grep/glob/web/browser/subagent arrive as extensions or lazy tools so the prompt stays short. Pi proves this; Terminus-style "just a shell" research supports it.

G4. **Permissions + sandbox without prompt bloat.** Steal fx's allow/deny/session grants and Codex-style OS isolation. Do not steal fx's extra billed auto-reviewer model. Pi's `tool_call` block hook is the extension-side version.

G5. **Embed without Node.** ACP + WASM/N-API like fx, so editors and JS hosts can host the same core. Pi's SDK is excellent but Node-shaped.

G6. **Unix-shell form factor.** Transcript + prompt, `ask` one-shot, JSON/RPC. Not Crush/OpenCode/Oh My Pi.

G7. **Packages.** `omfx install npm:…` / `git:…` bundling extensions+skills+prompts. Pi packages.

G8. **Tree sessions and compaction hooks.** Pi. Linear JSONL is not enough once extensions persist state.

### Gaps we refuse (so we stay small)

- IDE-in-the-terminal (OpenCode, Crush, Claude Code, Oh My Pi)
- Baking MCP tool catalogs into every prompt (lazy search like fx, or CLI-shaped like Pi+mcporter)
- Vercel-only auth
- Auto permission review that silently spends a second model
- Doom-in-the-TUI as a product goal
- Matching every Claude Code feature in v1

### What fx already has that we keep

- Native binary, no runtime to install
- ACP
- WASM/N-API embed split (`core` vs `term`)
- Trusted-profile MCP (never execute repo MCP on clone)
- Cross-harness skill discovery
- `doctor` / `status` / `ask` / `trace`
- Workspace-scoped permissions

---

## Scorecard (leaders only)

| Agent | Form | Providers | Extensibility | Permissions | Embed | Core tools | Keep/steal/refuse |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fx | unix-shell (stated) | Gateway only | skills+MCP | ask/auto/yolo + macOS sandbox | ACP+WASM | many | steal embed+perms; refuse gateway lock-in and source sprawl |
| Pi | unix-shell+TUI | 15+ first-party | TS extensions+packages | none in core | Node SDK+RPC | 4 | steal extension ABI, providers, packages, tree sessions |
| Oh My Pi | TUI-IDE | multi | Pi ABI + baked features | more than Pi | Node | many | steal hash-anchored edit as a package; refuse the bake-in |
| Claude Code | TUI-IDE | Anthropic | skills+hooks+MCP | strong | limited | many | steal loop quality, not the product |
| Codex CLI | TUI-IDE | OpenAI | MCP+skills | OS sandbox | limited | many | steal sandbox |
| OpenCode | TUI-IDE | 75+ | MCP+LSP+subagents | mixed | limited | many | steal provider breadth |
| Aider | unix-shell | 100+ models | weak | weak | none | edit+git | steal git discipline |
| Goose | unix-shell | multi+local | MCP extensions | mixed | limited | moderate | steal on-device MCP packaging |
| Crush | TUI | multi | MCP | mixed | none | moderate | refuse the TUI |
| Hermes | unix-shell+desktop | multi | skills+MCP | strong | desktop | many | study, do not copy desktop |

---

## Catalog

Stable C-IDs. Do not renumber.

### C1. fx
- **URL:** https://github.com/vercel-labs/fx
- **Language / license:** Zig / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** Vercel AI Gateway only
- **Extensibility:** skills+MCP+ACP
- **Note:** 7.8MiB native; model-agnostic claim is gateway-shaped

### C2. Pi
- **URL:** https://github.com/earendil-works/pi
- **Language / license:** TypeScript / MIT
- **Form factor:** unix-shell+TUI
- **Providers:** 15+ first-party + custom
- **Extensibility:** TS extensions+packages+skills
- **Note:** 4 tools; self-extensible; no baked MCP/permissions

### C3. Oh My Pi
- **URL:** https://github.com/can1357/oh-my-pi
- **Language / license:** TS+Rust / MIT
- **Form factor:** TUI-IDE
- **Providers:** multi-provider
- **Extensibility:** Pi-compatible extensions+plugins
- **Note:** Batteries-included Pi fork: LSP, browser, subagents, hash-anchored edits

### C4. Hermes Agent
- **URL:** https://github.com/NousResearch/hermes-agent
- **Language / license:** Python/TS / MIT
- **Form factor:** unix-shell+desktop
- **Providers:** multi-provider
- **Extensibility:** skills+MCP+plugins
- **Note:** Local-first Nous harness; de-facto Llama host

### C5. Claude Code
- **URL:** https://github.com/anthropics/claude-code
- **Language / license:** TypeScript / source-available
- **Form factor:** TUI-IDE
- **Providers:** Anthropic locked
- **Extensibility:** skills+MCP+hooks+subagents
- **Note:** Default serious-work CLI; deepest loop, provider lock-in

### C6. Codex CLI
- **URL:** https://github.com/openai/codex
- **Language / license:** Rust / Apache-2.0
- **Form factor:** TUI-IDE
- **Providers:** OpenAI (+oss)
- **Extensibility:** MCP server+client, skills
- **Note:** Best OS sandbox; network off by default

### C7. Gemini CLI
- **URL:** https://github.com/google-gemini/gemini-cli
- **Language / license:** TypeScript / Apache-2.0
- **Form factor:** TUI
- **Providers:** Google
- **Extensibility:** MCP+skills
- **Note:** Generous free tier; 1M context

### C8. GitHub Copilot CLI
- **URL:** https://github.com/github/copilot-cli
- **Language / license:** TypeScript / proprietary
- **Form factor:** unix-shell
- **Providers:** GitHub models
- **Extensibility:** GitHub MCP, custom agents
- **Note:** GA Feb 2026; repo/PR native

### C9. OpenCode
- **URL:** https://github.com/anomalyco/opencode
- **Language / license:** Go / MIT
- **Form factor:** TUI-IDE
- **Providers:** 75+ providers
- **Extensibility:** MCP+LSP+subagents+skills
- **Note:** Most-starred OSS harness; model flexibility winner

### C10. Aider
- **URL:** https://github.com/Aider-AI/aider
- **Language / license:** Python / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** 100+ models
- **Extensibility:** none/MCP undocumented
- **Note:** Git-native pair programmer; auto-commit; no subagents

### C11. Goose
- **URL:** https://github.com/block/goose
- **Language / license:** Rust / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** multi + local
- **Extensibility:** MCP extensions (70+)
- **Note:** Linux Foundation / AAIF; on-device; vendor-neutral

### C12. Crush
- **URL:** https://github.com/charmbracelet/crush
- **Language / license:** Go / MIT/Apache
- **Form factor:** TUI
- **Providers:** multi-provider
- **Extensibility:** MCP
- **Note:** Charmbracelet glamorous TUI; not unix-shell

### C13. Amazon Q / Kiro CLI
- **URL:** https://github.com/aws/amazon-q-developer-cli
- **Language / license:** Rust / MIT+Apache
- **Form factor:** unix-shell
- **Providers:** AWS/Bedrock
- **Extensibility:** MCP
- **Note:** AWS-team default

### C14. Cursor CLI
- **URL:** https://cursor.com/cli
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell/ACP
- **Providers:** mixed frontier
- **Extensibility:** ACP agent
- **Note:** Cursor's terminal/ACP surface

### C15. Amp
- **URL:** https://sourcegraph.com/amp
- **Language / license:** proprietary / proprietary
- **Form factor:** TUI
- **Providers:** Sourcegraph
- **Extensibility:** MCP
- **Note:** Ad-supported + pay; code review strength

### C16. Droid / Factory
- **URL:** https://github.com/Factory-AI/factory
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell
- **Providers:** Factory
- **Extensibility:** enterprise
- **Note:** Incident/product droids; enterprise pricing

### C17. Warp
- **URL:** https://github.com/warpdotdev/Warp
- **Language / license:** Rust / AGPL-3.0
- **Form factor:** terminal-IDE
- **Providers:** Warp AI
- **Extensibility:** built-in agent mode
- **Note:** AI lives in the terminal emulator, not a CLI

### C18. Grok Build CLI
- **URL:** https://github.com/xai-org/grok-build
- **Language / license:** unknown / proprietary/OSS mix
- **Form factor:** unix-shell
- **Providers:** xAI
- **Extensibility:** unknown
- **Note:** xAI first-party coding CLI

### C19. Groq Code CLI
- **URL:** https://github.com/build-with-groq/groq-code-cli
- **Language / license:** TypeScript / OSS
- **Form factor:** unix-shell
- **Providers:** Groq
- **Extensibility:** customizable
- **Note:** Lightweight Groq-hosted agent

### C20. Mistral Vibe
- **URL:** https://github.com/mistralai/mistral-vibe
- **Language / license:** unknown / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** Mistral
- **Extensibility:** unknown
- **Note:** Mistral first-party CLI

### C21. Qwen Code
- **URL:** https://github.com/QwenLM/qwen-code
- **Language / license:** TypeScript / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** Qwen/Dashscope
- **Extensibility:** MCP
- **Note:** Official Qwen coder CLI

### C22. Kilo Code CLI
- **URL:** https://github.com/Kilo-Org/kilocode
- **Language / license:** unknown / unknown
- **Form factor:** TUI
- **Providers:** 500+ models claimed
- **Extensibility:** orchestrator mode
- **Note:** Widest model picker claims

### C23. Roo Code CLI
- **URL:** https://github.com/RooCodeInc/Roo-Code
- **Language / license:** TypeScript / unknown
- **Form factor:** TUI-IDE
- **Providers:** multi
- **Extensibility:** skills+checkpoints+modes
- **Note:** Architect/code/debug/orchestrator

### C24. Cline CLI
- **URL:** https://github.com/cline/cline
- **Language / license:** TypeScript / Apache-2.0
- **Form factor:** TUI/IDE
- **Providers:** multi
- **Extensibility:** MCP+browser
- **Note:** VS Code origin; browser automation

### C25. Continue CLI
- **URL:** https://github.com/continuedev/continue
- **Language / license:** TypeScript / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** multi + local
- **Extensibility:** MCP
- **Note:** Privacy-focused open IDE agent CLI

### C26. Plandex
- **URL:** https://github.com/plandex-ai/plandex
- **Language / license:** Go / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** planning sandbox
- **Note:** Spec/plan-first; large context sandbox

### C27. gptme
- **URL:** https://github.com/gptme/gptme
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** persistent agents
- **Note:** Self-modifying git-backed memory

### C28. Open Interpreter
- **URL:** https://github.com/OpenInterpreter/open-interpreter
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** code exec
- **Note:** Computer-use via local code interpreter

### C29. OpenHands
- **URL:** https://github.com/All-Hands-AI/OpenHands
- **Language / license:** Python / MIT
- **Form factor:** hybrid
- **Providers:** multi
- **Extensibility:** docker sandbox
- **Note:** SWE-bench class cloud/local agent

### C30. SWE-agent
- **URL:** https://github.com/SWE-agent/SWE-agent
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** research harness
- **Note:** Issue-to-PR research agent

### C31. Mini-SWE-agent
- **URL:** https://github.com/SWE-agent/mini-swe-agent
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** minimal
- **Note:** Readable research reference

### C32. Agentless
- **URL:** https://github.com/OpenAutoCoder/Agentless
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** none
- **Note:** Localization-then-patch, not a loop

### C33. AutoCodeRover
- **URL:** https://github.com/AutoCodeRoverSG/auto-code-rover
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** code search
- **Note:** Autonomous issue patching

### C34. Mentat
- **URL:** https://github.com/AbanteAI/mentat
- **Language / license:** Python / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Terminal pair programmer

### C35. Letta Code
- **URL:** https://github.com/letta-ai/letta-code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Letta
- **Extensibility:** persistent memory
- **Note:** Memory-first CLI

### C36. Nanocoder
- **URL:** https://github.com/Nano-Collective/nanocoder
- **Language / license:** TypeScript / MIT
- **Form factor:** unix-shell
- **Providers:** local-first
- **Extensibility:** unknown
- **Note:** Cloud is opt-in

### C37. ForgeCode
- **URL:** https://github.com/antinomyhq/forge
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** pair-programming
- **Note:** Ranked pair-programming agent

### C38. Codebuff
- **URL:** https://github.com/CodebuffAI/codebuff
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** OSS coding agent

### C39. Devon
- **URL:** https://github.com/entropy-research/Devon
- **Language / license:** Python / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Open Devin-lineage

### C40. Smol Developer
- **URL:** https://github.com/smol-ai/developer
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** OpenAI-era
- **Extensibility:** none
- **Note:** Influential 2023 codegen; dated

### C41. Trae Agent
- **URL:** https://github.com/bytedance/trae-agent
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** ByteDance
- **Extensibility:** unknown
- **Note:** Trae terminal agent

### C42. Claude Engineer
- **URL:** https://github.com/Doriandarko/claude-engineer
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** Anthropic
- **Extensibility:** unknown
- **Note:** Early Claude coding loop

### C43. Kimi CLI
- **URL:** https://github.com/MoonshotAI/kimi-cli
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Moonshot
- **Extensibility:** unknown
- **Note:** Kimi first-party CLI

### C44. Kode CLI
- **URL:** https://github.com/shareAI-lab/Kode-cli
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** ShareAI terminal agent

### C45. Claw Code
- **URL:** https://github.com/ultraworkers/claw-code
- **Language / license:** Python/Rust / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** oh-my-codex
- **Note:** Clean-room Claude Code rewrite after 2026 leak

### C46. claw-code-agent
- **URL:** https://github.com/HarnessLab/claw-code-agent
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** zero deps
- **Note:** Python-only Claude Code rewrite

### C47. g3
- **URL:** https://github.com/dhanji/g3
- **Language / license:** Rust / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** skills
- **Note:** Rust coding agent + provider abstraction

### C48. NullClaw
- **URL:** https://github.com/nullclaw/nullclaw
- **Language / license:** Zig / MIT
- **Form factor:** unix-shell
- **Providers:** 23+ providers
- **Extensibility:** OpenClaw-compatible
- **Note:** 678KB binary; closest size peer to fx

### C49. IronClaw
- **URL:** https://github.com/nearai/ironclaw
- **Language / license:** Rust / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** WASM sandbox + caps
- **Note:** NEAR AI rewrite; capability permissions

### C50. PicoClaw
- **URL:** https://github.com/sipeed/picoclaw
- **Language / license:** Go / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** tiny RAM
- **Note:** $10 hardware target

### C51. OpenClaw
- **URL:** https://github.com/openclaw/openclaw
- **Language / license:** TypeScript / MIT
- **Form factor:** messaging agent
- **Providers:** via Pi SDK
- **Extensibility:** skills+channels
- **Note:** Personal assistant on Pi core

### C52. Junie CLI
- **URL:** https://junie.jetbrains.com
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell
- **Providers:** JetBrains
- **Extensibility:** IDE-native
- **Note:** JetBrains agent CLI

### C53. Auggie
- **URL:** https://github.com/augmentcode/auggie
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell
- **Providers:** Augment
- **Extensibility:** code review
- **Note:** Augment Code CLI

### C54. Tabnine CLI
- **URL:** https://docs.tabnine.com/main/getting-started/tabnine-cli
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell
- **Providers:** Tabnine
- **Extensibility:** unknown
- **Note:** Enterprise completion lineage

### C55. Devin
- **URL:** https://devin.ai
- **Language / license:** proprietary / proprietary
- **Form factor:** cloud-web
- **Providers:** Cognition
- **Extensibility:** sandbox VM
- **Note:** Async software engineer, not terminal-first

### C56. Command Code
- **URL:** https://github.com/CommandCodeAI/command-code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Terminal coding agent

### C57. Ante
- **URL:** https://github.com/AntigmaLabs/ante-preview
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** unknown
- **Extensibility:** unknown
- **Note:** Preview-stage agent

### C58. pool
- **URL:** https://github.com/poolsideai/pool
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell
- **Providers:** Poolside
- **Extensibility:** unknown
- **Note:** Poolside agent CLI

### C59. FetchCoder
- **URL:** https://github.com/fetchai/fetchcoder-releases
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Fetch.ai
- **Extensibility:** unknown
- **Note:** Fetch.ai coding CLI

### C60. Cortex Code CLI
- **URL:** https://www.snowflake.com/en/product/cortex-code/
- **Language / license:** proprietary / proprietary
- **Form factor:** unix-shell
- **Providers:** Snowflake
- **Extensibility:** unknown
- **Note:** Snowflake Cortex coding

### C61. Orca
- **URL:** https://github.com/stablyai/orca
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Stably
- **Extensibility:** unknown
- **Note:** Stably agent

### C62. Grok CLI (community)
- **URL:** https://github.com/superagent-ai/grok-cli
- **Language / license:** TypeScript / MIT
- **Form factor:** unix-shell
- **Providers:** xAI
- **Extensibility:** unknown
- **Note:** Community Grok CLI vs first-party Grok Build

### C63. open-codex
- **URL:** https://github.com/ymichael/open-codex
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenAI-compat
- **Extensibility:** unknown
- **Note:** Community Codex-shaped agent

### C64. Tau
- **URL:** https://github.com/huggingface/tau
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** HuggingFace
- **Extensibility:** unknown
- **Note:** HF coding agent

### C65. RA.Aid
- **URL:** https://github.com/ai-christianson/RA.Aid
- **Language / license:** Python / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** research+code
- **Note:** Research-augmented aider-like

### C66. VT Code
- **URL:** https://github.com/vinhnx/vtcode
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community coding CLI

### C67. Neovate Code
- **URL:** https://github.com/neovateai/neovate-code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Neovate agent

### C68. Dexto
- **URL:** https://github.com/truffle-ai/dexto
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Truffle AI CLI

### C69. agentty
- **URL:** https://github.com/1ay1/agentty
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C70. Coro Code
- **URL:** https://github.com/Blushyes/coro-code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C71. LettaBot
- **URL:** https://github.com/letta-ai/lettabot
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Letta
- **Extensibility:** memory
- **Note:** Letta bot CLI

### C72. zot
- **URL:** https://github.com/patriceckhart/zot
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C73. Mini-Kode
- **URL:** https://github.com/minmaxflow/mini-kode
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** educational
- **Note:** Readable reference implementation

### C74. nori-cli
- **URL:** https://github.com/tilework-tech/nori-cli
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Claude+Gemini+Codex
- **Extensibility:** Codex-based switcher
- **Note:** Multi-provider wrapper on Codex

### C75. cursor-agent (community)
- **URL:** https://github.com/civai-technologies/cursor-agent
- **Language / license:** Python / unknown
- **Form factor:** unix-shell
- **Providers:** Claude/OpenAI/Ollama
- **Extensibility:** unknown
- **Note:** Cursor-like community agent

### C76. VibePod
- **URL:** https://github.com/VibePod/vibepod-cli
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** VibePod CLI

### C77. Waveloom
- **URL:** https://github.com/Menfre01/waveloom
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C78. DvalinCode
- **URL:** https://github.com/arthurpanhku/dvalincode
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C79. Octomind
- **URL:** https://github.com/Muvon/octomind
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C80. openHarness
- **URL:** https://github.com/zhijiewong/openharness
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Open harness experiment

### C81. Codex Infinity
- **URL:** https://github.com/lee101/codex-infinity
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenAI-compat
- **Extensibility:** unknown
- **Note:** Codex-lineage loop

### C82. San
- **URL:** https://github.com/genai-io/san
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** genai-io CLI

### C83. Keen Code
- **URL:** https://github.com/mochow13/keen-code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C84. picocode
- **URL:** https://github.com/jondot/picocode
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Tiny coding CLI

### C85. QQCode
- **URL:** https://github.com/qnguyen3/qqcode
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C86. Smelt
- **URL:** https://github.com/leonardcser/smelt
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C87. Zap
- **URL:** https://github.com/zap-coding-agent/zap-coding-agent
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C88. Grinta
- **URL:** https://github.com/josephsenior/Grinta-Coding-Agent
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C89. Binharic
- **URL:** https://github.com/CogitatorTech/binharic-cli
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C90. Darce
- **URL:** https://github.com/AmerSarhan/darce-cli
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C91. Forge (Norvia)
- **URL:** https://github.com/NorviaLabs/forge
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Distinct from ForgeCode

### C92. CLAII
- **URL:** https://github.com/agencyswarm/CLAII
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Agency swarm CLI

### C93. nanobot
- **URL:** https://github.com/HKUDS/nanobot
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** HKU tiny agent

### C94. ZeroClaw
- **URL:** https://github.com/zeroclaw-labs/zeroclaw
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** OpenClaw-compatible

### C95. NanoClaw
- **URL:** https://github.com/gavrielc/nanoclaw
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** OpenClaw-compatible

### C96. Clawith
- **URL:** https://github.com/dataelement/Clawith
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** OpenClaw-compatible

### C97. claw0
- **URL:** https://github.com/shareAI-lab/claw0
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** OpenClaw-compatible

### C98. Moltis
- **URL:** https://github.com/moltis-org/moltis
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** OpenClaw-compatible

### C99. GitClaw
- **URL:** https://github.com/open-gitagent/gitclaw
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** Git-oriented OpenClaw

### C100. LionClaw
- **URL:** https://github.com/moshthepitt/lionclaw
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** OpenClaw
- **Extensibility:** unknown
- **Note:** OpenClaw-compatible

### C101. Codewhale
- **URL:** https://github.com/Hmbown/CodeWhale
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C102. Reasonix
- **URL:** https://github.com/esengine/DeepSeek-Reasonix
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** DeepSeek
- **Extensibility:** unknown
- **Note:** DeepSeek-oriented agent

### C103. Deep Agents Code
- **URL:** https://github.com/langchain-ai/deepagents
- **Language / license:** Python / MIT
- **Form factor:** unix-shell
- **Providers:** LangChain
- **Extensibility:** LangGraph
- **Note:** LangChain deep-agent CLI

### C104. Oh My OpenAgent
- **URL:** https://github.com/code-yeongyu/oh-my-openagent
- **Language / license:** unknown / unknown
- **Form factor:** TUI
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** OpenAgent distro

### C105. jcode
- **URL:** https://github.com/1jehuang/jcode
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C106. Prime Agent
- **URL:** https://github.com/PrimeIntellect-ai/prime-agent
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Prime Intellect
- **Extensibility:** unknown
- **Note:** Decentralized inference agent

### C107. MiMo Code
- **URL:** https://github.com/XiaomiMiMo/MiMo-Code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** Xiaomi MiMo
- **Extensibility:** unknown
- **Note:** Xiaomi first-party coder CLI

### C108. Claurst
- **URL:** https://github.com/Kuberwastaken/claurst
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C109. Free Code
- **URL:** https://github.com/paoloanzn/free-code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C110. OpenSquilla
- **URL:** https://github.com/opensquilla/opensquilla
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C111. Every Code
- **URL:** https://github.com/just-every/code
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** just-every coding CLI

### C112. CodeMachine-CLI
- **URL:** https://github.com/moazbuilds/CodeMachine-CLI
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** local
- **Extensibility:** multi-agent
- **Note:** Local multi-agent CLI

### C113. Codel
- **URL:** https://github.com/semanser/codel
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** unknown
- **Note:** Community CLI

### C114. graff
- **URL:** https://github.com/justrach/codegraff
- **Language / license:** Zig / unknown
- **Form factor:** unix-shell+desktop
- **Providers:** multi
- **Extensibility:** MCP+TS/Python SDKs
- **Note:** Zig harness peer; evolutionary loop

### C115. usecomputer
- **URL:** https://github.com/remorses/usecomputer
- **Language / license:** Zig+TS / unknown
- **Form factor:** unix-shell
- **Providers:** n/a (computer-use)
- **Extensibility:** CLI tools
- **Note:** Zig computer-use for agents, not a coding loop

### C116. Ecodex
- **URL:** https://dev.to/soulentheo/coding-clis-in-mid-2026-the-engineers-map-and-what-changed-in-30-days-23p4
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** open weights
- **Extensibility:** accountability
- **Note:** Open-weight CLI with audit claims

### C117. Antigravity CLI
- **URL:** https://github.com/google-gemini/gemini-cli
- **Language / license:** TypeScript / closed successor
- **Form factor:** TUI
- **Providers:** Google
- **Extensibility:** MCP
- **Note:** Google successor path for Gemini CLI

### C118. Claude Squad
- **URL:** https://github.com/smtg-ai/claude-squad
- **Language / license:** Go / MIT
- **Form factor:** orchestrator
- **Providers:** Claude Code
- **Extensibility:** tmux parallel
- **Note:** Multi-agent tmux runner, not a loop

### C119. amux
- **URL:** https://github.com/mixpeek/amux
- **Language / license:** unknown / OSS
- **Form factor:** orchestrator
- **Providers:** Claude/Codex/Gemini
- **Extensibility:** fleet+kanban
- **Note:** Agent multiplexer

### C120. gastown
- **URL:** https://github.com/steveyegge/gastown
- **Language / license:** unknown / unknown
- **Form factor:** orchestrator
- **Providers:** multi
- **Extensibility:** beads
- **Note:** Steve Yegge orchestration

### C121. Beads
- **URL:** https://github.com/steveyegge/beads
- **Language / license:** Go / MIT
- **Form factor:** infra
- **Providers:** n/a
- **Extensibility:** issue graph for agents
- **Note:** Local issue tracker agents use

### C122. claude-code-router
- **URL:** https://github.com/musistudio/claude-code-router
- **Language / license:** TypeScript / MIT
- **Form factor:** infra
- **Providers:** any via CC
- **Extensibility:** router
- **Note:** Lets Claude Code hit other providers

### C123. Docker Agent
- **URL:** https://github.com/docker/docker-agent
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** multi
- **Extensibility:** containers
- **Note:** Docker-native agent

### C124. NemoClaw
- **URL:** https://github.com/NVIDIA/NemoClaw
- **Language / license:** unknown / unknown
- **Form factor:** unix-shell
- **Providers:** NVIDIA
- **Extensibility:** unknown
- **Note:** NVIDIA OpenClaw-line

### C125. Codex Security
- **URL:** https://github.com/openai/codex-security
- **Language / license:** TS / Apache-2.0
- **Form factor:** unix-shell
- **Providers:** OpenAI
- **Extensibility:** multi-agent scans
- **Note:** Security-specialized Codex

### C126. deepsec
- **URL:** https://github.com/vercel-labs/deepsec
- **Language / license:** TypeScript / unknown
- **Form factor:** unix-shell
- **Providers:** via coding agents
- **Extensibility:** security harness
- **Note:** Vercel security harness on coding agents

### C127. Agent Executor (AX)
- **URL:** https://github.com/google/ax
- **Language / license:** unknown / unknown
- **Form factor:** infra
- **Providers:** Google
- **Extensibility:** unknown
- **Note:** Google agent executor

---

## Implications for omfx

1. Core is Zig. Loop, tools, permissions, sandbox, sessions, ACP, WASM live here. Binary stays single-digit MiB.
2. Extension host is TypeScript. Same idea as Pi: a documented `ExtensionAPI`, drop-in files, hot reload, packages. Zig does not need a plugin ABI in v1 if TS extensions can register tools/commands/hooks over a stable host protocol.
3. Providers are first-class in Zig (OpenAI-compat + Anthropic Messages + Google + local), not "whatever the Gateway has today."
4. Advertised tools in the system prompt: `read`, `write`, `edit`, `bash` (plus maybe `grep`/`glob` if measurements demand it). Everything else is an extension or a lazy built-in.
5. Permissions stay in core (unlike Pi). Extensions may add gates; they may not disable the sandbox.
6. Form factor is Unix-shell. No feature that requires a full TUI render engine ships in v1.
7. Oh My Pi is the failure mode to avoid: compatible extension ABI plus an ever-growing baked feature list.

---

## Sources

- https://github.com/vercel-labs/fx
- https://fx.sh/docs
- https://fx.sh/docs/configure-fx/permissions
- https://fx.sh/docs/getting-started/authentication
- https://fx.sh/docs/using-fx/acp
- https://fx.sh/docs/capabilities/skills
- https://fx.sh/docs/capabilities/mcp
- https://github.com/vercel-labs/fx/blob/main/AGENTS.md
- https://github.com/vercel-labs/fx/blob/main/sdk/README.md
- https://github.com/earendil-works/pi
- https://pi.dev/docs/latest
- https://pi.dev/docs/latest/extensions
- https://pi.dev/docs/latest/packages
- https://pi.dev/docs/latest/providers
- https://pi.dev/docs/latest/skills
- https://pi.dev/docs/latest/sdk
- https://lucumr.pocoo.org/2026/1/31/pi
- https://github.com/can1357/oh-my-pi
- https://github.com/bradAGI/awesome-cli-coding-agents
- https://github.com/ishandutta2007/Awesome-CLI-Coding-Agents
- https://amux.io/blog/best-terminal-ai-coding-agents-2026
- https://www.tembo.io/blog/coding-cli-tools-comparison
- https://hidekazu-konishi.com/entry/cli_coding_agents_comparison.html
- https://dev.to/soulentheo/coding-clis-in-mid-2026-the-engineers-map-and-what-changed-in-30-days-23p4
- https://terminaltrove.com/ai-coding-agents
- https://deepakness.com/blog/pi-agent-setup
