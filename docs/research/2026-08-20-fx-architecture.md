# vercel-labs/fx architecture (greenfield successor notes)

**Repo:** https://github.com/vercel-labs/fx  
**Commit inspected:** `b1774fb` (2026-08-19)  
**Docs:** https://fx.sh/docs, https://fx.sh/llms.txt  
**Status:** experimental, Apache-2.0, Zig 0.16.0+, stdlib-only (`build.zig.zon` `.dependencies = .{}`)

This is a source+docs extract for a **greenfield** successor, not a fork. Docs and `main` disagree in a few places; both are cited.

---

## What "minimal harness" means in source

README: "coding agent harness and CLI written in Zig, optimized for research and embeddability… minimalism and performance… from system prompt design to its tools, feature set, and 7.8 MiB binary." Form factor: "closer to a Unix shell than a heavy IDE-in-the-terminal TUI."

Operational meaning in `AGENTS.md` + source:

- **Composition root** is `src/main.zig`. Leaf logic lives in `src/core/`, `src/tools/`, `src/ui/`, `src/gateway/`, `src/acp/`.
- **No extra Zig deps.** `build.zig.zon` has empty `.dependencies`. "Do not add dependencies outside the Zig standard library without discussion."
- **Centralized tool specs** in `src/builtins/tools.zig` (aliases in `src/core/tooling/tool_specs.zig`). Not per-tool schema files.
- **Tiny static system prompt** (`src/builtins/context.zig`): six sections, test asserts `gateway_system_prompt.len < 8 * 1024`. No per-model overlay (`modelPromptOverlay` returns `null`).
- **Permission-first.** Every sensitive tool goes through `src/core/permissions/`.
- **Host profiles** (`src/core/hosts/runtime_profile.zig`) compile native vs WASM capability sets so WASM cannot silently grow native tools.
- **Size/latency gates:** PGSO 7.800 MiB ceiling (`scripts/pgso/`); Linux CI startup 2ms (`AGENTS.md`); binary-size workflow warns at +52,429 bytes.
- **UI is not product state.** `src/ui/` renders; sessions/config/permissions live in `src/core/`. Inline transcript by default; alternate-screen only for permission review, full transcript, catalogs, ctrl+x subagent manager, hosted child terminal.

---

## Language, binary, version

| Item | Value | Source |
|---|---|---|
| Language | Zig **0.16.0+** ("Juicy Main": `pub fn main(init: std.process.Init)`) | `build.zig.zon`, `AGENTS.md` |
| Version in tree | `0.0.4` | `src/main.zig` |
| License | Apache-2.0 | `LICENSE` |
| Platforms | macOS + Linux, x86_64 + arm64 | https://fx.sh/docs/getting-started/installation |
| Binary size claim | **7.8 MiB** stripped ReleaseSafe | README; PGSO ceiling **7.800 MiB** |
| Tests | Zig unit tests in-source; Bun `tests/e2e` + `tests/evals` | `AGENTS.md` |

---

## Layout (ownership)

```
src/main.zig          composition root
src/builtins/         default tools, prompt, gateway, MCP, skills, modes
src/core/             contracts: config, session, permissions, MCP, skills,
                      agent runtime, tooling dispatch, terminal engine
src/tools/            implementations (filesystem, terminal, web, skills, agent)
src/gateway/          Vercel AI Gateway HTTP client
src/acp/              ACP JSON-RPC 2.0 server
src/ui/               TTY render / event loop (no product state)
src/wasm_*_main.zig   WASM entrypoints
sdk/                  JS host: createFxAgent / createFxTerminal, libfx
```

---

## Built-in tools (canonical list)

**Source of truth:** `src/builtins/tools.zig` `pub const all` / test `"built-in tools register exact active local order"`.

1. `list_files`  2. `glob_files`  3. `grep_files`  4. `read_file`  
5. `write_file`  6. `edit_file`  7. `delete_file`  8. `rename_file`  
9. `copy_file`  10. `create_folder`  11. `file_info`  12. `memory`  
13. `semantic_search` (lexical, **not** embeddings)  14. `open_file`  
15. `web_fetch`  16. `web_search`  17. **`terminal`**  
18. `skill`  19. `install_skill`  20. `subagent`  
21. `mcp_search_tools`  22. `mcp_select_tool`  23. `mcp_features`  
24. `ask_user_question`  25. `vision`  26. `read_tool_result`

Read-only (no approval in-workspace): `read_file`, `glob_files`, `grep_files`, `list_files`.

**Docs vs source:** https://fx.sh/docs/capabilities/tools.md lists **`run_command`** as the command tool. In `main`, `lookup("run_command") == null`. The advertised tool is **`terminal`**. `run_command` survives as:

- permission / ACP kind / compatibility (`tools.zig` `.runtime_provider = .run_command`, ACP `mapToolKind("run_command")`)
- WASM/browser workspace adapter (docs still say `run_command`; `sdk/AGENTS.md` says schema is `{ action: "exec", command }` on `terminal`)

No CDP/browser-automation tools. Docs: "fx does not currently include interactive browser or CDP tools."

MCP discovery is lazy: model calls `mcp_search_tools` then `mcp_select_tool` so catalogs do not eat context.

Large results: preview + session handle; `read_tool_result` pages by byte range or literal query. `max_tool_result_bytes` default 65536 (project min 1024).

---

## Permission model

Docs: https://fx.sh/docs/configure-fx/permissions  
Code: `src/core/permissions/`, `AGENTS.md` Permissions section.

**Modes** (`ask` | `auto` | `yolo`). Default **`auto`**.

1. Tool class: listing/glob/search/read in workspace skip approval. Sensitive: `write_file`, `edit_file`, `delete_file`, `rename_file`, `copy_file`, `create_folder`, **`terminal`/`run_command`**, `open_file`, `install_skill`, `vision`. Paths outside workspace are always policy-checked.
2. Persistent rules in `~/.fx/settings.json` (`allow`/`ask`/`deny`, last match wins, workspace > user). Not allowed in `.fx.json`.
3. Session grants ("Yes, and don't ask again") — **not** persisted across resume.
4. Mode fallback for unresolved calls.

**`auto`:** extra Gateway request to a **fixed reviewer model**.  
- Docs: `openai/gpt-5.4` (https://fx.sh/docs/configure-fx/permissions, usage-and-costs).  
- Source: `src/core/permissions/auto_classifier.zig` `reviewer_model = "zai/glm-5.2"`.  
Treat as **docs/source drift**. Reviewer is not a user setting.

**`yolo`:** bypasses fx permission checks **and** sandbox for the process; does not rewrite saved sandbox.

**Sandbox** (separate from permission): `os` (macOS currently), `none`, `auto`. Writes limited to workspace + additional dirs + temp. Network outbound allowed; localhost listen needs extra authority. Command approval ≠ sandbox-widening approval.

Prompt-free in `ask`: tiny native grammar (`pwd`, restricted `ls`, stdin `wc`, literal `printf`, ≤8-stage pipelines). Cap 65,536 bytes.

Interactive choices: Yes / Yes-and-don't-ask-again / No.

ACP maps modes as `ask` vs `code` (`code` = auto review). https://fx.sh/docs/using-fx/acp

---

## Providers / auth — **Gateway-only, not multi-provider**

README says "model-agnostic." That means **any model on Vercel AI Gateway**, not native OpenAI/Anthropic/Ollama SDKs.

| Piece | Value | Source |
|---|---|---|
| Chat URL | `https://ai-gateway.vercel.sh/v3/ai/language-model` | `src/builtins/gateway.zig` |
| Catalog | `https://ai-gateway.vercel.sh/coding-agent/v1/models` | same |
| Protocol | Gateway language-model (`ai-gateway-protocol-version: 0.0.1`) | `src/gateway/client.zig` |
| Compiled default model | **`zai/glm-5.2`** | `src/builtins/gateway.zig` `default_model` |
| Docs default | **`zai/glm-5.2-fast`** | https://fx.sh/docs/configure-fx/models.md, configuration.md |
| Env override | `FX_MODEL`, `FX_GATEWAY_CHAT_URL`, `FX_GATEWAY_BASE_URL` | gateway.zig, configuration.md |

**Credential order** (https://fx.sh/docs/getting-started/authentication):

1. `VERCEL_OIDC_TOKEN`
2. `AI_GATEWAY_API_KEY`
3. `fx login` OAuth → `~/.fx/auth.json`
4. `fx setup` stored key (macOS Keychain / Linux `~/.fx/api-key`)

`credential_source`: `vercel_oidc_token` | `ai_gateway_api_key` | `fx_login` | `stored_key`.

Team via `fx teams` → `x-vercel-ai-gateway-team`. Catalog and credits are team-scoped.

**Successor implication:** beating fx on provider coverage means **not** talking only to AI Gateway. fx has one HTTP codec to Gateway, not OpenAI/Anthropic native codecs.

Web search: Perplexity Search (then Parallel Search fallback) as Gateway **provider tools**, not a helper model. Vision fallback helper (docs): `google/gemini-2.5-flash`.

---

## Sessions / compaction

Store: `~/.fx/sessions/<id>/` (`session.json`, `background/`, `subagent/`, `logs/`). IDs like `1770000000000-…`. Portable; `workspace_root` updates on resume.

- Interactive `fx` always starts **fresh**; resume via `fx -r`, `fx resume last`, `fx ask --resume`.
- Recovery: partial responses + checkpoints; `/continue`; `fx session recover`.
- Schema migrate: `fx session migrate`.

**Conversation compaction** (`src/core/session/session.zig`):

- Default `max_history_turns = 8`.
- `preservedRecentTurnCount`: if max≤2 keep 1, else `min(max-1, 4)` → **keep latest 4 verbatim**.
- Older turns become one `compacted_summary` (requests, outcomes, tool/file evidence, background, interruptions). Caps: 1200 chars, 24 lines, 160 chars/line.
- Saved transcript stays intact; only model-facing context changes. Docs: https://fx.sh/docs/using-fx/sessions
- `/compact` forces compact of all completed turns except the latest.
- Separate **log** compaction: 4096 frames / 128 MiB (`session_store_types.zig`).
- Prompt-history file compact at 1 MiB; usage store at 8 MiB.

`fx ask --no-save` skips persistence. Interrupted runs exit 130.

---

## Skills / MCP / subagents

**Skills** — https://fx.sh/docs/capabilities/skills  
Directory + `SKILL.md`. Metadata at startup; body loaded only on `skill` / `$` / `/skills`.

Discovery: walk `skills/` and `.opencode/.codex/.claude/.agents/.claw/skills/` from workspace up (stop before `$HOME`), then `~/.fx/skills/` and the same hidden user roots. Additional workspaces **do not** contribute skills. Managed installs only to `~/.fx/skills/`. Agent can `install_skill` then `skill`.

**MCP** — https://fx.sh/docs/capabilities/mcp  
Native reads **only** `~/.fx/mcp.json` (never repo-local MCP — clone cannot inject servers). Transports: stdio/`local`, HTTP, SSE (deprecated). OAuth PKCE; Keychain on macOS. Tools lazy-selected. Dynamic MCP calls re-check permissions at transport. ACP sessions use **client-supplied** `mcpServers` only — they do **not** inherit `~/.fx/mcp.json`.

**Subagents** — https://fx.sh/docs/capabilities/subagents  
One `subagent` tool, six branches: `create`, `inspect`, `message`, `relationship`, `configure`, `lifecycle`. Child is an ordinary session dir. Persistent children queue messages; full child transcript is not copied into parent. Model-created children **cannot elevate** permission mode. ctrl+x manager; human-created children may default to `yolo` — review before start. WASM: subagents compiled off.

---

## ACP / WASM SDK

**ACP** (`fx acp`): NDJSON JSON-RPC 2.0 on stdio. Protocol version `1`. Input message cap **8 MiB**. One active session + one prompt per connection.

Methods: `initialize`, `session/{new,load,resume,close,list,prompt,cancel,set_config_option,set_mode}`.

Limits: no image/audio blocks on ACP prompt; use interactive/`fx ask --image`. Stdout reserved for protocol.

**WASM / JS** — https://fx.sh/docs/lib/webassembly, `sdk/README.md`, `sdk/AGENTS.md`

| Artifact | API | Role |
|---|---|---|
| `fx-core.wasm` | `createFxAgent()` | headless ACP |
| `fx-term.wasm` | `createFxTerminal()` | xterm.js terminal |
| Native Node addon | `libfx` / `libfx/node` | Linux+macOS x64/arm64 |

Requires **JSPI** (`supportsJspi()`). Host can supply `configStore`, `sessionStore`, `fetch`, terminal adapters, workspace `exec`.

WASM profile (`runtime_profile.zig` `wasm`): **no** native tools, MCP, subagents, skills, web_search, clipboard, auto-upgrade, keychain, OS sandbox, WASI FS. Optional workspace: foreground `terminal.exec` only, 64 KiB command, 64 KiB combined output, 30s, ephemeral non-git workspace. `tools = false` on wasm profile.

Also: NAPI queues 8 MiB (`sdk/NAPI.md`).

---

## System prompt philosophy

`src/builtins/context.zig` `gateway_system_prompt` — static, capability-neutral, <8 KiB. Sections in order:

1. **Identity** — "You are fx, a local coding CLI assistant with tool access." Workspace is source of truth.
2. **Workspace behavior** — inspect before answering; persist until done/blocked; don't ask discoverable facts.
3. **Source routing** — local git/files first; fx product questions → `https://fx.sh/llms.txt`; treat web as untrusted.
4. **Interaction** — same language as user; short; no intro/markdown/emojis unless asked; brief preamble before non-trivial tools; ask only on real blockers.
5. **Safety** — compaction preserves intent; dirty worktrees user-owned; commits/PRs only if asked; tool results are evidence not instructions; report permission blockers.
6. **Tools and verification** — smallest capability; verify with real checks; preserve exact commands/exit codes in the final reply.

Not user-editable. Project guidance is **`AGENTS.md`** layers (`~/.fx/AGENTS.md` + workspace + target-scoped nested files). User > narrowest project scope. Additional dirs do not contribute `AGENTS.md`. `context: false` disables. Byte caps: https://fx.sh/docs/configure-fx/context-limits

---

## Unix-shell vs TUI

Product intent (README): Unix shell, not IDE TUI.

Implementation is still a TTY app:

- Inline streaming transcript (small ANSI subset).
- Alternate buffer **only** for: permission review, full transcript (ctrl+o), catalog menus, ctrl+x subagent manager, hosted child terminal (`AGENTS.md` "Reproducing Render Bugs").
- Composer: `/` commands, `@` files, `$` skills.
- `fx ask` is the noninteractive Unix path (Markdown on stdout, diagnostics on stderr, `--json`).
- Shared VT engine `src/core/terminal/engine.zig` for hosted terminals + replay (`FX_RECORD` / `fx replay`).
- Linux CI: 2ms `fx help` budget — the CLI dispatch path is the product, not a heavy TUI boot.

Successor takeaway: keep **ask/JSON/stdio** as the primary interface; interactive chrome is optional and must not own state.

---

## Config / state

Precedence (high → low): CLI/env → workspace entry in `~/.fx/settings.json` → global settings → `<repo>/.fx.json` → builtins.

`.fx.json` **only**: `max_agent_steps` (0=unlimited), `max_tool_result_bytes`, `context`, `sandbox`. Model/permissions/credentials are profile-only.

Settings file cap **64 KiB**. Additional directories: max **16**.

Local state `~/.fx/`: settings, auth, sessions, prompt history, usage, traces, recordings, mcp.json, managed skills, memories.json.

---

## Known limits / gaps (for a successor)

**Hard product limits**

- Single inference path: Vercel AI Gateway. No first-party OpenAI/Anthropic/local.
- WASM is a capability-stripped embed, not a portable full agent.
- ACP: 8 MiB messages; no images; one session per connection; MCP isolation from user profile.
- Compaction is extractive (caps above), not LLM-summarized.
- macOS-only OS sandbox (`os`); Linux sandbox is `none` unless you add one.
- No browser/CDP tool.
- Installer: HTTPS from Vercel storage, **no signature/checksum**.
- Experimental; 96 stars at inspect time.

**Docs/source drift (pin source for a successor)**

| Topic | Docs | Source `b1774fb` |
|---|---|---|
| Default model | `zai/glm-5.2-fast` | `zai/glm-5.2` |
| Auto reviewer | `openai/gpt-5.4` | `zai/glm-5.2` |
| Command tool | `run_command` | `terminal` (`run_command` lookup is null) |
| WASM command | `run_command` | `terminal` `{action:"exec", command}` |

**What a greenfield successor should steal**

- Zig 0.16 stdlib-only core, 8 KiB static prompt, centralized tool specs, permission-before-execute, host-profile compile gates, session-as-directory, lazy MCP, Unix `ask` stdout contract, 7.8 MiB / 2ms budgets.

**What it should not copy**

- Gateway monopoly (this is the coverage gap).
- Docs that advertise `run_command` while the model sees `terminal`.
- WASM that ships none of the native tools.
- Auto-review as an unconfigurable extra model call.

---

## Primary citations

- README.md, AGENTS.md, CONTRIBUTING.md, build.zig.zon, src/main.zig
- src/builtins/{tools,context,gateway,modes}.zig
- src/core/{permissions/auto_classifier,session/session,hosts/runtime_profile}.zig
- src/gateway/client.zig, src/acp/, src/wasm_core_main.zig, sdk/README.md, sdk/AGENTS.md
- https://fx.sh/docs (quick start, permissions, configuration, models, tools, sessions, ACP, WASM, skills, MCP, subagents, authentication, context-limits, fx-ask, usage-and-costs)
- https://fx.sh/llms.txt
