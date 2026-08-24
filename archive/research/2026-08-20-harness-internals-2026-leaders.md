# Harness internals: 2026 coding-agent leaders

Date: 2026-08-20
Scope: Claude Code, Codex CLI, Gemini CLI, OpenCode, Aider, Goose, Crush, Pi, Copilot CLI, Amp — vs a tiny Unix-shell agent (vercel-labs/fx successor).
Method: primary docs, first-party engineering posts, official READMEs. Reverse-engineering paper used only where Anthropic does not publish internals, and labeled as such.

fx baseline (what a Unix-shell successor starts from): Zig harness, ~7.8 MiB native binary, Apache-2.0, model-agnostic, CLI closer to a shell than an “IDE in the terminal.” Tools: workspace read/search plus `write_file` / `edit_file` / `delete_file` / `rename_file` / `copy_file` / `create_folder` / `run_command` / `open_file` / `install_skill` / `vision`. Permission modes (`auto` default, `yolo` disables checks + command sandbox). Skills, MCP, subagents, ACP, WASM embed. Source: [vercel-labs/fx](https://github.com/vercel-labs/fx), [fx.sh/docs](https://fx.sh/docs).

---

## 1. Claude Code (Anthropic)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | Agentic while-loop: gather context → take action → verify. Model decides next tool; turn ends when the model stops calling tools. Surrounding subsystems (permissions, compaction, extensibility) dwarf the loop. | [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works); arXiv:2604.14228 (v2.1.88 source analysis) |
| Tool set | File ops (Read/Write/Edit), search (Glob/Grep), Bash, WebFetch/WebSearch, subagent spawn, AskUser. LSP via code-intelligence plugins. | [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works) |
| Permissions / sandbox | Permission modes + optional ML classifier in auto mode. `/sandbox`: bubblewrap (Linux/WSL2) or `@anthropic-ai/sandbox-runtime`; FS allow/deny + network domain allowlists; credential deny/mask (env + files, AWS re-sign). Unsandboxed retry via `dangerouslyDisableSandbox`. Managed settings can pin sandbox. | [Sandboxing](https://code.claude.com/docs/en/sandboxing) |
| Compaction / context | Auto-compact; `/compact` with focus; `/context` breakdown. Subagents run in a **separate window**; only a summary returns. CLAUDE.md + auto memory re-injected after compact; path-scoped rules are not. ArXiv: five-stage pipeline (budget reduction → snip → microcompact → context collapse → auto-compact). | [Context window](https://code.claude.com/docs/en/context-window); arXiv:2604.14228 |
| Provider lock-in | Claude-first. Terminal/VS Code also document third-party providers / LLM gateway. Native installer (curl/brew/winget), not npm-as-primary. | [Overview](https://code.claude.com/docs/en/overview) |
| MCP / skills / subagents | All first-class. Plus plugins, hooks (PreToolUse/PostToolUse/PermissionRequest/PreCompact…), Agent SDK. | [Overview](https://code.claude.com/docs/en/overview), [Hooks](https://code.claude.com/docs/en/hooks) |
| Headless / scriptability | `claude -p`, stdin pipe, Agent SDK, GitHub Actions / GitLab CI, `claude agents --json`, `claude ultrareview --json`. Unix-philosophy examples in overview. | [Overview](https://code.claude.com/docs/en/overview), [CLI reference](https://code.claude.com/docs/en/cli-reference) |
| Binary / runtime | Native binary (macOS/Linux/Windows). Internal: large TypeScript app (~512K LOC in the analyzed snapshot). Surfaces: CLI, VS Code, JetBrains, Desktop, Web, Slack, Chrome, mobile remote. | Overview; arXiv:2604.14228 |
| Beats a tiny Unix agent | OS sandbox + credential masking; classifier-backed auto-approve; subagent context isolation; hook pipeline; JSONL session store + checkpoints; worktrees; `-p` composability already Unix-shaped. |

Bloat to refuse: desktop/web/Slack/Chrome/mobile; agent-view supervisor daemon; 1M-token productization; ML permission classifier as a hard dep; encrypted vendor-only compaction.

---

## 2. Codex CLI (OpenAI)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | Responses API client. Turn = user input → inference → tool calls → observations until an **assistant message** (no tool calls). Prompt items: system/developer/user/assistant. Developer block describes sandbox **only for the built-in `shell` tool**; MCP tools are unsandboxed by Codex. Cache-stable prompt construction (append, don’t rewrite earlier items). | [Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/) (2026-01-23) |
| Tool set | `shell`, `update_plan`, apply-patch (platform tool), `web_search` (Responses API), user MCP tools. | Same; [Codex CLI](https://developers.openai.com/codex/cli) |
| Permissions / sandbox | Two layers: OS-enforced sandbox (typically workspace-only) + approval policy. Default `workspace-write`, **network off**. Auto preset: `--sandbox workspace-write --ask-for-approval on-request`. Optional `network_proxy` domain allowlist. Destructive MCP still needs approval. | [Agent approvals & security](https://developers.openai.com/codex/agent-approvals-security) |
| Compaction / context | Auto-compact via `/responses/compact` when `auto_compact_limit` exceeded. Returns items including `type=compaction` + opaque `encrypted_content` (latent state). AGENTS.md / `CODEX_HOME` instructions aggregated into the first prompt. | OpenAI loop post |
| Provider lock-in | ChatGPT plan or API key. Endpoint is configurable; any [OpenResponses](https://www.openresponses.org)-compatible server, including `--oss` / Ollama. Model-specific bundled `*_prompt.md`. | Loop post; [openai/codex](https://github.com/openai/codex) |
| MCP / skills / subagents | MCP client; skills + plugins; subagents; Codex can **be** an MCP server (`codex` / `codex-reply`). | Codex CLI docs |
| Headless / scriptability | Non-interactive / CI; `codex resume`; review-without-edit; cloud handoff. Apache-2.0 Rust core. | Codex CLI docs; GitHub |
| Binary / runtime | Rust (`codex-rs`), musl Linux binaries, also npm/Homebrew wrappers. ~107k GitHub stars. TUI + IDE + Cloud share the same harness. | [openai/codex](https://github.com/openai/codex) |
| Beats a tiny Unix agent | Seatbelt/bwrap-class sandbox **with network default-deny**; apply_patch; prompt-cache hygiene; server-side compact with latent state; plan tool; review mode that does not dirty the tree. |

Bloat to refuse: ChatGPT-account gravity; encrypted compact that only the Responses API can consume; cloud/IDE product surface; TUI chrome.

---

## 3. Gemini CLI (Google) — sunset path

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | `packages/core` (API, tools, history) + `packages/cli` (UI). Standard tool loop. | [Core](https://www.geminicli.com/docs/core) |
| Tool set | `run_shell_command` (bash/PowerShell; optional node-pty interactive), `read_file` / `write_file` / `replace` / `glob` / `grep_search` / `list_directory`, web, MCP. Hierarchical `GEMINI.md` via memory discovery. | [Shell tool](https://www.geminicli.com/docs/tools/shell); Core |
| Permissions / sandbox | Policy engine (TOML): `tools.core` allowlist, `tools.exclude` blocklist, `commandPrefix` / `commandRegex` sugar. **Allowlist of `tools.core` disables every unlisted builtin.** Not an OS sandbox. | Shell tool docs |
| Compaction / context | Automatic chat-history compression near the model token limit (claimed lossless). Model fallback: Pro → Flash on rate limit. | Core |
| Provider lock-in | Gemini-first. Apache-2.0. **Consumer Gemini CLI stops serving AI Pro/Ultra/free on 2026-06-18**, replaced by closed-source **Antigravity CLI**. Paid Gemini / Enterprise Agent Platform keys keep Gemini CLI. Living open fork: Qwen Code. | [Google blog](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli); [google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli) (~107k★) |
| MCP / skills / subagents | MCP; extensions marketplace; skills in extensions. | geminicli.com |
| Headless / scriptability | `-p` / non-TTY; `--output-format` JSON or JSONL (`init`/`message`/`tool_use`/`tool_result`/`error`/`result`); exit codes 0/1/42/53. | [Headless](https://www.geminicli.com/docs/cli/headless) |
| Binary / runtime | Node/TypeScript monorepo (`packages/`, `sea/` single-executable). | GitHub tree |
| Beats a tiny Unix agent | Policy-engine allowlists; hierarchical memory files; JSONL headless with turn-limit exit code; Pro→Flash fallback. |

Bloat / landmine: closed successor (Antigravity); interactive pty shell; extension marketplace; Node weight.

---

## 4. OpenCode (SST / Anomaly)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | TUI-default agent. Plan mode (read-only) vs Build. Tool loop with permission checks per action. | [Intro](https://opencode.ai/docs); [Permissions](https://opencode.ai/docs/permissions) (updated 2026-08-18) |
| Tool set | `bash`, `edit`/`write`/`apply_patch`, `read`, `grep`, `glob`, experimental `lsp`, `skill`, `todowrite`, `webfetch`, `websearch` (Exa / OpenCode provider), `question`, `task` (subagent). grep/glob = ripgrep, honors `.gitignore` + `.ignore`. | [Tools](https://opencode.ai/docs/tools) (updated 2026-08-20) |
| Permissions / sandbox | `allow` / `ask` / `deny` per tool; last-matching wildcard wins; `external_directory`; `doom_loop` guard; `.env` read denied by default. `--auto` auto-approves non-denied. Per-agent permission overlay. **Not OS sandbox** — policy only. | Permissions |
| Compaction / context | Autocompact (`OPENCODE_DISABLE_AUTOCOMPACT`). `AGENTS.md` via `/init`. Can ingest `.claude` skills/prompts (disable flags exist). | [CLI](https://opencode.ai/docs/cli) |
| Provider lock-in | models.dev; any provider via `opencode auth login`. Optional OpenCode Zen. MIT. | Intro; CLI |
| MCP / skills / subagents | MCP (stdio/HTTP, OAuth); plugins (`opencode plugin`); markdown agents (`mode: subagent`); skills; ACP server; GitHub agent. | CLI |
| Headless / scriptability | `opencode run` (JSON events); `serve` HTTP; `web`; `acp`; attach to running server to skip MCP cold-start. | CLI |
| Binary / runtime | Install script / npm / brew / native releases. TUI + desktop + IDE extension. Highest-star OSS CLI agent (~165k claimed mid-2026). | Intro; landscape blogs |
| Beats a tiny Unix agent | Permission DSL quality; apply_patch; LSP; HTTP/ACP/JSON automation; provider breadth; shareable transcripts. |

Bloat to refuse: Bubble Tea / OpenTUI IDE-in-terminal; desktop/web; plugin SDK + LSP downloader; Exa-tied websearch; Claude-compat shims.

---

## 5. Aider (Aider-AI)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | Pair-programming chat, not a general tool agent. User adds files → model emits an **edit format** (diff / udiff / whole) → aider applies → **git commit** → optional lint/test and fix. Architect/editor split optional. | [Usage](https://aider.chat/docs/usage.html); [GitHub](https://github.com/Aider-AI/aider) |
| Tool set | Not MCP-style tools as the primary surface. Repo map (tree-sitter, token-budgeted). Watch-mode (comment-to-edit). Images/URLs. Voice. Copy/paste to web chat. | README features |
| Permissions / sandbox | No OS sandbox. Safety = git commits + `/undo`. Docker docs exist for isolation. | README; docker/ in repo |
| Compaction / context | Repo-map is the context trick (whole-repo outline, not full files). Chat history + prompt caching. Weak model for commits. | [Repo map](https://aider.chat/docs/repomap.html) |
| Provider lock-in | LiteLLM; “almost any LLM” including local. Apache-2.0. | README |
| MCP / skills / subagents | None as first-class 2026 primitives. Conventions files instead of skills. | Docs TOC |
| Headless / scriptability | `aider --message` one-shot. Benchmark harness in-tree. | Usage; hermes aider skill notes |
| Binary / runtime | Python / PyPI (`aider-chat`). Heavier than a Zig/Go binary. | GitHub |
| Beats a tiny Unix agent | **Repo map** still the best cheap-context trick; git-native undo; lint/test closed loop; edit-format robustness across weak models. |

Bloat to refuse: voice, browser chat copypaste, watch-IDE, Python dep tree. Do steal repo-map + git checkpointing.

---

## 6. Goose (AAIF / Linux Foundation; formerly Block)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | General-purpose on-machine agent (not code-only). CLI + desktop + embed API. Extension tools via MCP. | [aaif-goose/goose](https://github.com/aaif-goose/goose); [goose-docs.ai](https://goose-docs.ai) |
| Tool set | Built-in developer extension (shell/edit/test) + Computer Controller + Memory + 70+ MCP extensions. | README |
| Permissions / sandbox | Extension/recipe scoped; not Codex-class OS sandbox in the public README. Recipes as packaged workflows. | README; docs site |
| Compaction / context | Session persistence; `.goosehints` / AGENTS.md in-tree. | Repo files |
| Provider lock-in | 15+ providers; can use **Claude Code / Codex as ACP providers**. Apache-2.0, AAIF governance. | README |
| MCP / skills / subagents | MCP-native (early adopter). Skills. ACP **server** (Zed/JetBrains/VS Code) and ACP **client**. Custom distros. | README |
| Headless / scriptability | CLI, HTTP API, recipes, `test_acp_client.py`. | Repo |
| Binary / runtime | **Rust + desktop UI + vendor/v8** — heavy. Native apps for macOS/Linux/Windows. ~53k★. | Repo tree |
| Beats a tiny Unix agent | MCP/ACP depth; provider neutrality + governance; recipes; “goose as component and orchestrator.” |

Bloat to refuse: Electron/desktop; v8 vendor; 70-extension kitchen sink; computer-controller. Steal ACP + recipe packaging.

---

## 7. Crush (Charmbracelet)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | TUI coding agent; multi-session per project; mid-session model switch with context preserved. | [charmbracelet/crush](https://github.com/charmbracelet/crush) README |
| Tool set | Coding tools + **LSP as extra context**; MCP (`http`/`stdio`/`sse`). | README Features |
| Permissions / sandbox | `crushrc` can auto-approve tools. Config is **Bash with Crush builtins** (works on Windows via embedded Bash). Not an OS sandbox. | README Configuration |
| Compaction / context | Session DB (SQLite); `tui.compact_mode`; Catwalk provider metadata auto-update. | README; Nix module example |
| Provider lock-in | Catwalk model DB; Hyper (Charm) optional; OpenAI- and Anthropic-compatible + Vertex/Bedrock/Azure/Ollama. FSL-1.1-MIT. | README |
| MCP / skills / subagents | MCP yes; `.agents/skills` in-tree; no first-class subagent product. | Repo tree |
| Headless / scriptability | Weaker than Claude/OpenCode: logs CLI, `crush update-providers`. TUI is the product. | README |
| Binary / runtime | **Go single binary** (Homebrew/npm/go install/deb/rpm). Charm stack. ~27.5k★. | README |
| Beats a tiny Unix agent | LSP-as-context; Go binary weight; crushrc-as-code; provider catalog that updates without a release. |

Bloat to refuse: glamorous TUI; Hyper subscription; telemetry (opt-out `DO_NOT_TRACK`); Catwalk auto-update on a network you don’t want.

---

## 8. Pi (earendil-works; Armin Ronacher / Mario Zechner)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | `pi-agent-core`: stream → validate tool → execute → append. **YOLO by default.** Minimal system prompt. | [pi.dev](https://pi.dev/); [Zechner 2025-11-30](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/) |
| Tool set | Minimal (read/edit/write/bash class). Everything else is an **extension**. | pi.dev “What we didn’t build” |
| Permissions / sandbox | None in core. Extensions: permission-gate, protected-paths, sandbox. Philosophy: run in a container. | pi.dev |
| Compaction / context | Auto-summarize near limit; **custom compaction via extensions**. AGENTS.md + SYSTEM.md. Tree-structured sessions (`/tree`). Skills = progressive disclosure without busting prompt cache. | pi.dev |
| Provider lock-in | 15+ providers; mid-session `/model`; `models.json`; unified Completions/Responses/Messages/Gemini APIs with **context handoff**. | pi.dev; Zechner post |
| MCP / skills / subagents | Skills + packages (npm/git). **No MCP, no subagents, no plan, no todos, no background bash in core** — all extension-or-tmux. | pi.dev |
| Headless / scriptability | Interactive / `pi -p` / `--mode json` / **RPC stdin JSON** / **SDK** (OpenClaw is the showcase). | pi.dev |
| Binary / runtime | TypeScript monorepo (`packages/`), npm `@earendil-works/pi-coding-agent`. ~91k★. TUI optional. | [earendil-works/pi](https://github.com/earendil-works/pi) |
| Beats a tiny Unix agent | Actual context engineering (inspectable prompt); tree history; RPC/SDK; provider handoff; “primitives not features.” Closest **philosophy** to fx. |

Bloat they already refuse — copy this list. Don’t copy Node as the core runtime if the successor is Zig.

---

## 9. GitHub Copilot CLI

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | Plan (`Shift+Tab`) vs Autopilot. Built-in specialist agents (Explore, Task, Code Review, Plan) can run in parallel. `&` prefix delegates to **cloud** coding agent. | [GA changelog 2026-02-25](https://github.blog/changelog/2026-02-25-github-copilot-cli-is-now-generally-available) |
| Tool set | File/shell plus **built-in GitHub MCP** (repos/issues/PRs). Custom MCP. Rubber-duck critic uses a **different model**. | Changelog; [docs hub](https://docs.github.com/en/copilot/how-tos/copilot-cli) |
| Permissions / sandbox | Approve-every-action vs autopilot. `preToolUse` / `postToolUse` hooks. Org policies. Client source-available; models closed. Independent sandbox writeup: process spawn + MCP/LSP children, not Codex-class OS sandbox as the default story. | Changelog; [Agent Safehouse](https://agent-safehouse.dev/docs/agent-investigations/copilot-cli) (2026-03-09) |
| Compaction / context | Auto-compact at **~95%** window. Repository memory + cross-session chronicle (NL query over past sessions). | Changelog |
| Provider lock-in | Copilot subscription. Models: Anthropic / OpenAI / Google (and others, e.g. Grok) **through GitHub**. | Changelog |
| MCP / skills / subagents | GitHub MCP built-in; plugins (`/plugin install owner/repo`); Agent Skills; `.agent.md` custom agents; hooks. | Changelog |
| Headless / scriptability | CI (`GITHUB_ASKPASS`); Codespaces image; remote control from github.com / mobile. | Changelog |
| Binary / runtime | npm + Homebrew/WinGet/script + standalone executables; auto-update on some channels. Alt-screen TUI experimental. | Changelog |
| Beats a tiny Unix agent | GitHub-native MCP; specialist parallel agents; hooks for policy; session chronicle; cloud handoff. |

Bloat to refuse: Copilot billing lock; alt-screen IDE TUI; rubber-duck as a product; remote-control cloud; plugin marketplace.

---

## 10. Amp (Amp Code; spun out of Sourcegraph)

| Axis | Finding | Source |
| --- | --- | --- |
| Loop | Thread = one task. Modes `low`/`medium`/`high`/`ultra` are **capability presets**, not fixed models. Main agent + Oracle routing. | [Owner’s Manual](https://ampcode.com/manual) |
| Tool set | Oracle (second-model review), Librarian (GitHub-scale search), Painter, Code Review, subagents, MCP (lazy-loaded via skills), browser/localhost screenshot loops. | Manual TOC; [Chronicle](https://ampcode.com/news) |
| Permissions / sandbox | Plugin permission examples; passkey “proof of human”; MCP registry allowlists (enterprise). **Orbs** = remote VMs for isolation. Local CLI is not the Codex sandbox story. | Manual; news (orbs, secrets of the orb) |
| Compaction / context | **Handoff instead of compact** (2025-10-23: “Handoff (No More Compaction)”). AGENTS.md hierarchy + glob-scoped mentioned files. Thread URLs as context. “Read bigger threads” for 271-round threads. | Manual; news |
| Provider lock-in | Opinionated router (GPT-5.x + Claude). BYOK + ChatGPT-sub link. “No backcompat.” npm `@ampcode/cli`. | Manual |
| MCP / skills / subagents | Skills, plugins (commands/tools/UI/custom agents), MCP, agent-to-agent messaging, schedules. | Manual; news 2026-07-17 |
| Headless / scriptability | `amp -x '…'`; streaming JSON; Python SDK; orbs/runners; Slack. | Manual CLI section |
| Binary / runtime | Node CLI (npm “not recommended”; brew/script preferred). TUI + web + orbs. Killed VS Code extension (2026-02, “The Coding Agent Is Dead”). | Manual; news |
| Beats a tiny Unix agent | Specialist subagents (oracle/librarian) without dumping their tokens into the main window; handoff as a compaction alternative; lazy MCP; thread-as-artifact. |

Bloat to refuse: orbs/Puck/voice/Slack/multiplayer; unconstrained-token billing culture; painter; killing features users still need; Node TUI.

---

## Cross-cut matrix

| | Loop | Tools | Sandbox | Compact | Lock-in | MCP/skills/sub | Headless | Weight |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Code | while-true | files+bash+web+LSP-plugin | **OS + classifier** | 5-layer + subagent windows | Claude-first | **all + hooks** | `-p`, SDK | native, huge product |
| Codex | Responses until assistant msg | shell+patch+plan | **OS, net off** | API compact + latent | Responses/ChatGPT | MCP+skills+sub | CI, MCP-server | **Rust binary** |
| Gemini CLI | core+cli | shell+files | policy engine | history compress | Gemini; **sunsetting** | MCP+ext | JSONL `-p` | Node |
| OpenCode | plan/build TUI | +lsp+patch | permission DSL | autocompact | any / Zen | MCP+agents+ACP | run/serve/ACP | TUI-heavy OSS |
| Aider | edit-format + git | repo map | git only | map budget | LiteLLM | no | `--message` | Python |
| Goose | general agent | MCP-first | recipes | sessions | any + ACP | **MCP/ACP** | API/recipes | Rust+desktop+v8 |
| Crush | TUI sessions | LSP+MCP | crushrc | SQLite sessions | Catwalk/Hyper | MCP+skills | weak | **Go binary** |
| Pi | minimal YOLO | tiny + ext | none/core | customizable | 15+ APIs | skills; MCP ext | `-p`/RPC/SDK | Node toolkit |
| Copilot CLI | plan/autopilot | GH MCP | hooks/org | 95% + memory | Copilot sub | all | CI + cloud | Node+exe |
| Amp | thread+modes | oracle/librarian | orbs | **handoff** | Amp router | all | `-x` JSON | Node TUI |
| **fx today** | Unix turns | files+cmd+vision | auto review + cmd sandbox | sessions (docs) | Gateway/Vercel | skills+MCP+sub+ACP | `fx ask`, WASM | **Zig 7.8 MiB** |

---

## Harness gaps vs leaders (what fx / a Unix successor is missing)

Steal these; they are why the field beats a naive `while tool: bash` loop.

1. **OS-enforced execution sandbox** with network default-deny (Codex workspace-write; Claude bubblewrap + domain allowlist + credential mask). fx `auto` review is policy, not kernel.
2. **Prompt-cache-stable context assembly** (Codex: append permission/env changes; never rewrite prefix).
3. **Layered compaction**: microcompact/snip before full summarize (Claude); optional **handoff** to a fresh thread instead of lossy summary (Amp); Pi-style **user-replaceable** summarizer. Avoid vendor `encrypted_content` unless you own the model API.
4. **Subagent = isolated context window** that returns a summary (Claude, Amp oracle/librarian, Copilot Explore). fx has subagents; leaders treat isolation as the point.
5. **apply_patch / structured edit** in addition to whole-file write (Codex, OpenCode). Survives weak models better than naive search-replace.
6. **Permission DSL**: last-match-wins globs, per-tool allow/ask/deny, `.env` deny-by-default, `external_directory` (OpenCode). Optional classifier (Claude) is extra, not required.
7. **Hooks** at PreToolUse (deny/mutate) and PostToolUse (format/lint) — Claude, Copilot, OpenCode. Cheaper than MCP for local policy.
8. **Skills as progressive disclosure** (description in prompt, body on demand) so MCP/tool schemas don’t eat the window (Claude, Pi, Amp lazy MCP).
9. **Headless JSONL + exit codes** (Gemini 0/1/42/53; OpenCode `run --format json`; Pi RPC; Claude `-p`). Unix agents must be scriptable without a TUI.
10. **Repo map or LSP as optional context**, not a default tax (Aider map; Crush/OpenCode LSP).
11. **Git checkpoints** independent of the model (Aider auto-commit; Codex “create checkpoints”; Claude file snapshots for rewind).
12. **Provider coverage without a single gateway**: OpenAI+Anthropic+Gemini+local, mid-session switch, context handoff (Pi, OpenCode, Crush, Goose). fx is “model-agnostic” but Vercel login / AI Gateway is still gravity.
13. **ACP** — fx already has it. Keep. Goose/OpenCode treat it as the editor bridge so you never build an IDE TUI.

### Nice-to-have, second wave

- Review-only mode that cannot dirty the tree (Codex).
- Plan vs build permission overlay (OpenCode, Copilot, Claude).
- Session **tree** / fork (Pi) rather than linear JSONL only.
- Doom-loop / turn-limit guards (OpenCode, Gemini exit 53).

---

## What leaders bloated that a minimal Unix-shell agent should refuse

Form factor

- Alt-screen “IDE in the terminal” (Copilot experimental, OpenCode/Crush/Amp TUI, Claude desktop). fx’s stated differentiator.
- Desktop apps, Slack, mobile remote control, voice (Claude, Goose, Amp, Copilot).
- Plugin marketplaces and extension stores (Gemini, Copilot, Claude plugins).
- Background supervisor daemons (Claude `claude daemon`).

Harness complexity that fights Unix

- Dumping **hundreds of MCP tool schemas** into the system prompt (everyone who eagerly MCP’d; Amp/Pi already retreated to lazy/skills/CLI).
- Built-in todos, plan mode, background bash as **core** (Pi’s anti-list; Amp killed TODOs). Prefer files (`TODO.md`, `PLAN.md`) and tmux.
- Vendor-encrypted compaction blobs (Codex `encrypted_content`) that lock you to one API.
- ML permission classifiers as a required service (Claude auto mode).
- Telemetry on by default (Crush; Codex OTel is at least opt-in).

Product lock-in

- Subscription-only models (Claude, Codex ChatGPT, Copilot, Amp router, Gemini→Antigravity).
- Closed successor replacing an open CLI (Gemini CLI → Antigravity, Jun 2026).
- “No backcompat / we delete features” as a platform (Amp) — fine for a lab, lethal for a Unix tool.

Runtime weight

- Node + TUI frameworks when the pitch is a 8 MiB Zig binary.
- Desktop + vendored V8 (Goose).
- Python (Aider) unless the embed story is notebooks.

---

## Design implication for an fx successor

Stay Unix-shell-minimal (Pi + fx form factor) while importing **Codex/Claude sandbox semantics**, **OpenCode permission DSL**, **Claude/Amp subagent isolation**, **Aider repo-map + git checkpoints**, **Pi provider handoff + RPC**, **Gemini/OpenCode JSONL headless**.

Do not import their TUIs, stores, daemons, or vendor compact blobs.

Closest existing “don’t bloat” statement in the field: Pi’s “What we didn’t build” ([pi.dev](https://pi.dev/)) plus fx’s 7.8 MiB / shell-not-IDE README ([vercel-labs/fx](https://github.com/vercel-labs/fx)).
