# Pi and Oh My Pi extension systems (for a Unix-shell omfx successor)

Research for a greenfield Zig+TypeScript coding agent that stays Unix-shell-minimal like [vercel-labs/fx](https://github.com/vercel-labs/fx) while copying Pi’s “any user (or the agent itself) can add extensions that power the agent further.”

**Date:** 2026-08-20  
**Primary sources:** [pi.dev](https://pi.dev), [pi.dev/docs/latest](https://pi.dev/docs/latest), [earendil-works/pi](https://github.com/earendil-works/pi), [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi), [Armin Ronacher, 2026-01-31](https://lucumr.pocoo.org/2026/1/31/pi), [Mario Zechner, 2025-11-30](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/), [Mario Zechner, 2025-11-02](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/).  
**Repo note:** Pi currently lives at `earendil-works/pi` (npm `@earendil-works/pi-coding-agent`). Older posts still cite `badlogic/pi-mono` / `mariozechner/pi-mono`. Oh My Pi still names itself a fork of that lineage.

---

## 1. Core tools

### Pi (default: four)

By default the model gets **`read`, `write`, `edit`, `bash`**. ([coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md); [pi.dev](https://pi.dev); [Ronacher](https://lucumr.pocoo.org/2026/1/31/pi))

Optional **built-in** tools that are *not* in the default set: `grep`, `find`, `ls`. Allowlisted via `--tools` / `-t`; excluded via `--exclude-tools`. `--no-builtin-tools` keeps extension tools. ([coding-agent README, Tool Options](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md))

Example from docs: `pi --tools read,grep,find,ls -p "Review the code"` — read-only mode without write/edit/bash.

`bash` is the Unix escape hatch: `ls`/`rg`/`find` are documented as bash jobs unless those optional tools are enabled. System prompt even says “Use bash for file operations like ls, rg, find” when grep/find/ls are absent. ([system-prompt.ts](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/system-prompt.ts))

User-typed `!command` / `!!command` run bash independently of the LLM tool (output sent / not sent to the model). Extensions can intercept via `user_bash`. ([extensions](https://pi.dev/docs/latest/extensions))

**No permission popups by default.** YOLO + container/sandbox/extension gates. ([Philosophy](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md#philosophy); [pi.dev “What we didn’t build”](https://pi.dev))

### Oh My Pi (31 tools in one namespace)

OMP’s README: “31 tools live in the same namespace as `read` and `bash`.” Pin with `--tools`. Rare tools hide behind `xd://`. ([oh-my-pi README](https://github.com/can1357/oh-my-pi))

| Group | Tools |
|---|---|
| Files & search | `read`, `write`, `edit` (hashline), `ast_edit`, `ast_grep`, `grep`, `glob` |
| Runtime | `bash` (in-process brush + coreutils), `eval` (persistent Python + Bun JS, can re-enter tools) |
| Code intelligence | `lsp`, `debug` (DAP), `security_scan` (gated) |
| Coordination | `task` (subagents), `hub`, `todo`, `ask` |
| Desktop & web | `browser`, `computer`, `web_search`, `github` (gated), `generate_image`, `inspect_image`, `tts` |
| Memory & skills | `checkpoint`, `rewind`, `retain`, `recall`, `reflect`, `memory_edit`, `learn`, `manage_skill` |

`read` is overloaded: files, dirs, archives, SQLite, PDFs, notebooks, URLs, `ssh://`, plus internal schemes (`pr://`, `issue://`, `agent://`, `skill://`, `conflict://`, `xd://`). That is the opposite of Pi’s “bash + four tools.”

---

## 2. System prompt philosophy

Pi’s whole product is **context engineering by omission**.

- Shortest harness prompt Mario/Armin know of. ([Ronacher](https://lucumr.pocoo.org/2026/1/31/pi); [Zechner 2025-11-30](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/))
- Default text in [`system-prompt.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/system-prompt.ts) is roughly:
  - “You are an expert coding assistant operating inside pi…”
  - **Available tools:** one-line snippets only for tools that supplied `toolSnippets`
  - “you may have access to other custom tools”
  - Guidelines: bash-for-file-ops (conditional), “Be concise”, “Show file paths clearly”, plus extension `promptGuidelines`
  - **Self-extension pointer:** absolute paths to bundled README, docs, and `examples/` — “read only when the user asks about pi itself, its SDK, extensions…”
  - AGENTS.md / SYSTEM.md / skills XML appended
  - cwd
- Skills use **progressive disclosure**: names+descriptions in the prompt; full `SKILL.md` loaded via `read` on demand. ([skills](https://pi.dev/docs/latest/skills))
- Custom tools opt into the prompt via `promptSnippet` / `promptGuidelines`; guidelines must name the tool (`Use my_tool when…`, not “this tool”). ([extensions](https://pi.dev/docs/latest/extensions))
- `SYSTEM.md` can replace or append; `--system-prompt` / `--append-system-prompt`; extensions rewrite via `before_agent_start.systemPrompt` or `before_provider_request` payload. ([pi.dev context engineering](https://pi.dev); [extensions](https://pi.dev/docs/latest/extensions))

**OMP** does the inverse: per-model prompt tuning, magic keywords (`ultrathink`, `orchestrate`, `workflowz`), `/vibe`, advisor notes, time-traveling stream rules, role models (`smol`/`slow`/`plan`/…). That is a product, not a prompt you can hold in your head.

**Steal:** tiny default prompt + “docs live on disk, agent reads them when extending itself.”  
**Refuse:** baking 31-tool manuals and magic keywords into every turn.

---

## 3. Extension load paths

### Pi

Trusted auto-discovery ([extensions](https://pi.dev/docs/latest/extensions)):

| Location | Scope |
|---|---|
| `~/.pi/agent/extensions/*.ts` | global |
| `~/.pi/agent/extensions/*/index.ts` | global dir |
| `.pi/extensions/*.ts` | project, **after trust** |
| `.pi/extensions/*/index.ts` | project dir |

Plus:

- `settings.json` `extensions: []` (file or dir)
- `settings.json` `packages: []` (`npm:@foo/bar@1.0.0`, `git:github.com/user/repo@v1`)
- CLI `pi -e ./path.ts` / `pi -e npm:@foo/bar` (temp; not `/reload`able)
- Loaded with **jiti** (TS without compile)
- `/reload` hot-reloads auto-discovered locations
- **Security:** full user permissions; “only install from sources you trust.” Project `.pi` waits on `project_trust`.

Config dir override: `PI_CODING_AGENT_DIR` (default `~/.pi/agent`).

### Oh My Pi

Native auto-discovery is **`.omp`, not `.pi`** ([extension-loading.md](https://github.com/can1357/oh-my-pi/blob/main/docs/extension-loading.md)):

- Project: `<cwd>/.omp/extensions`
- User: `~/.omp/agent/extensions` (or `~/.omp/profiles/<name>/agent/extensions`)
- Settings: `config.yml` / `settings.json` `extensions:`
- CLI `--extension` / `-e`; `--hook` treated as an extension path
- Installed plugins via `omp.extensions` / legacy `pi.extensions` in `package.json`
- JS/TS **hook factories** also load through the same pipeline
- Bun import + `?mtime` cache-buster; rewrites `@mariozechner/*` / `@earendil-works/*` onto host copies
- **`.pi/extensions` is not a native root** (legacy only in package manifests)
- `--no-extensions` still honors explicit `-e`
- Failures are per-path; not sandboxed

Load order: native auto-discover → hook factories → plugin entries → explicit paths. First absolute path wins.

---

## 4. Hook / event names

Pi merged old `hooks/` + `customTools/` into one extension system ([issue #454](https://github.com/earendil-works/pi/issues/454)). Events are in-process `pi.on(...)`. Official lifecycle ([pi.dev/docs/latest/extensions](https://pi.dev/docs/latest/extensions)):

**Startup / trust / resources**

- `project_trust` — global/CLI extensions only; return `{ trusted: "yes"|"no"|"undecided", remember? }`
- `session_start` — `reason: startup|reload|new|resume|fork`
- `resources_discover` — add skill/prompt/theme paths (`startup|reload`)

**Session**

- `session_info_changed`
- `session_before_switch` (cancelable)
- `session_before_fork` (cancelable)
- `session_before_compact` / `session_compact` / `session_compact_failed`
- `session_before_tree` / `session_tree`
- `session_shutdown`

**Prompt / agent / turn**

- `input` — transform / handle / continue (before skill+template expansion)
- `before_agent_start` — inject message, rewrite system prompt
- `agent_start` / `agent_end` / `agent_settled`
- `turn_start` / `turn_end`
- `message_start` / `message_update` / `message_end`
- `context` — prune/rewrite messages for this LLM call
- `before_provider_headers`
- `before_provider_request`
- `after_provider_response`

**Tools / bash / model**

- `tool_execution_start` / `tool_execution_update` / `tool_execution_end`
- `tool_call` — mutate `event.input`; `{ block, reason, terminate }`
- `tool_result` — middleware chain on content/details/isError
- `user_bash` — wrap/replace `!` / `!!`
- `model_select` / `thinking_level_select`

That is **~34 named events**, not 25. The “25+ in-process hooks” claim is the same surface.

**ExtensionAPI (Pi) — registration + actions** ([extensions.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)):  
`on`, `registerTool`, `registerCommand`, `registerShortcut`, `registerFlag`, `registerProvider`, `registerMessageRenderer`, `registerEntryRenderer`, `registerMarkdownTransformer`, `sendMessage`, `sendUserMessage`, `appendEntry`, `setSessionName`/`getSessionName`, `setLabel`, `setActiveTools`/`getAllTools`, `setModel`, `setThinkingLevel`, `events` (inter-extension bus), plus UI (`notify`/`confirm`/`select`/`custom`/`setStatus`/`setWidget`/`setFooter`/`setHeader`/`setEditorComponent`).

**OMP extras** ([docs/extensions.md](https://github.com/can1357/oh-my-pi/blob/main/docs/extensions.md)):

- Still has **legacy Hooks** (`src/extensibility/hooks/`) and **custom-tools** adapters
- Extra events: `session_stop` (can continue, cap 8; not for subagents), `session_switch`/`session_branch`, `session.compacting`, `tool_approval_requested`/`tool_approval_resolved`, `auto_compaction_*`, `auto_retry_*`, `ttsr_triggered`, `todo_reminder`, `goal_updated`, `credential_disabled`, `mcp_notification`, `user_python`
- `resources_discover` exists in types but **no AgentSession callsite** (dead)
- `ctx.invokeTool` to delegate to the shadowed built-in
- Managed `ctx.setInterval`/`setTimeout` (raw timers can kill the process)

For omfx: **do not clone 34 events on day one.** A minimal successor needs maybe: `session_start`, `input`, `before_agent_start`, `tool_call`, `tool_result`, `session_shutdown`, plus `registerTool`/`registerCommand`. Grow the rest when users hit walls.

---

## 5. How users add extensions

**Drop a `.ts` file.** That is the whole UX.

1. Write `~/.pi/agent/extensions/my-extension.ts` exporting `default function (pi: ExtensionAPI) { ... }`
2. Or project `.pi/extensions/` after trust
3. Or `pi -e ./path.ts` for a one-shot
4. Or `pi install npm:@foo/bar` / `git:github.com/user/repo` / local path (`-l` for project)
5. Enable/disable with `pi config`
6. `/reload` after edits

Same idea in OMP under `~/.omp/agent/extensions/` and `.omp/extensions/`, plus YAML `extensions:` and plugin packages.

**Trust model (steal this):** global + CLI extensions load first; they decide `project_trust` before any project-local TS runs. Untrusted `.pi` must not execute.

---

## 6. How the agent writes its own extensions

This is Pi’s actual moat. Documented as first-class:

- Docs open with “**pi can create extensions. Ask it to build one.**” ([extensions](https://pi.dev/docs/latest/extensions); same line for skills, templates, packages)
- System prompt ships **absolute paths** to README, docs, and `examples/extensions/` (50+ working samples: plan-mode, permission-gate, subagent, ssh, sandbox, custom providers, Doom…)
- Agent uses `write`/`edit` into `~/.pi/agent/extensions/` or `.pi/extensions/`
- `/reload` picks up the file **without restarting**; sessions are trees so you can branch, fix a tool, rewind ([Ronacher](https://lucumr.pocoo.org/2026/1/31/pi))
- Custom session entries (`appendEntry`) persist extension state across reloads
- Examples are the API. The agent copies `permission-gate.ts` / `dynamic-tools.ts` rather than inventing from a 100k-token spec.

Ronacher: you don’t download MCP — you point Pi at an existing extension and say “build it like that, with these changes.” Skills he uses were “hand-crafted by my clanker.”

**omfx implication:** ship a **tiny, stable Extension API**, a **docs tree the agent is told to read**, and **hot reload**. Without those three, “self-extensible” is marketing.

---

## 7. Packages vs skills vs MCP vs extensions vs templates

| Layer | What it is | In context? | Can run code? | Pi | OMP |
|---|---|---|---|---|---|
| **Built-in tools** | `read/write/edit/bash` (+ optional grep/find/ls) | always (schemas) | yes | 4 default | 31 |
| **Extensions** | TS modules: tools, events, commands, TUI, providers | only if they `registerTool` | **yes, in-process, unsandboxed** | `~/.pi/agent/extensions` | `~/.omp/agent/extensions` |
| **Skills** | Agent Skills spec: `SKILL.md` + scripts | **descriptions only**; body via `read` | scripts invoked by the model through bash/read | `~/.pi/agent/skills`, `.agents/skills`, packages | same idea + `manage_skill`/`learn` |
| **Prompt templates** | Markdown → `/name` expansion | only when invoked | no | `~/.pi/agent/prompts/*.md` | present |
| **Pi/OMP packages** | npm/git bundle of extensions+skills+prompts+themes | whatever they contain | yes if they include extensions | `pi install`, `pi` key in package.json | `omp.extensions` + MCP decls |
| **MCP** | JSON-RPC tool servers | **all tools at session start** (cache-hostile) | separate process | **intentionally absent** | **first-class**, imports Claude/Cursor/Codex/VS Code/… |
| **Themes** | TUI chrome | n/a | no | yes | yes |

### Skills (Pi)

Implements [agentskills.io](https://agentskills.io/specification), lenient. Locations: `~/.pi/agent/skills/`, `~/.agents/skills/`, `.pi/skills/`, ancestor `.agents/skills/`, packages, settings, `--skill`. `/skill:name` force-loads. `disable-model-invocation: true` hides from prompt. ([skills](https://pi.dev/docs/latest/skills))

Philosophy: **README + CLI > MCP**. A skill is “here is a script and when to run it.” Zechner’s browser-tools README is ~225 tokens vs Playwright MCP ~13.7k. ([no MCP post](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/))

### Packages (Pi)

`pi install npm:@scope/pkg@1.2.3` | `git:host/user/repo@v1` | local path. Manifest:

```json
{ "keywords": ["pi-package"], "pi": { "extensions": ["./extensions"], "skills": ["./skills"], "prompts": ["./prompts"], "themes": ["./themes"] } }
```

Convention dirs if no manifest. Full system access. Gallery at [pi.dev/packages](https://pi.dev/packages). ([packages](https://pi.dev/docs/latest/packages))

### MCP

**Pi:** “No MCP. Build CLI tools with READMEs, or an extension that adds MCP.” OpenClaw uses [mcporter](https://github.com/steipete/mcporter) outside the harness. Reasons: tool schemas blow the cache; you cannot hot-reload MCP tools without trashing prefix cache; MCP results are not composable except through context. ([pi.dev](https://pi.dev); [Ronacher](https://lucumr.pocoo.org/2026/1/31/pi); [Zechner](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/))

**OMP:** native `.omp/mcp.json`, user `~/.omp/agent/mcp.json`, stdio/http/sse, OAuth, `/mcp add|list|test|reauth`, and **imports MCP from Claude, Codex, Gemini, OpenCode, Cursor, Windsurf, VS Code**. ([mcp-config.md](https://github.com/can1357/oh-my-pi/blob/main/docs/mcp-config.md))

---

## 8. Provider layer

### Pi (`@earendil-works/pi-ai`)

Designed as **four wire APIs**, not N SDKs ([Zechner](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)):

1. OpenAI Completions  
2. OpenAI Responses  
3. Anthropic Messages  
4. Google Generative AI  

Catalog from OpenRouter + models.dev, refreshable (`pi update --models`). Auth: API keys + `/login` OAuth (Claude Pro/Max, ChatGPT, Copilot, llama.cpp, …). Mid-session `/model` / `Ctrl+P`. Sessions are **provider-portable** (thinking traces converted on handoff). ([pi.dev](https://pi.dev); [providers](https://pi.dev/docs/latest/providers))

**Two extension points:**

- `~/.pi/agent/models.json` — any host speaking a supported API  
- `pi.registerProvider()` — custom streaming, OAuth, proxies ([custom-provider](https://pi.dev/docs/latest/custom-provider))

Hooks `before_provider_headers` / `before_provider_request` / `after_provider_response` for gateways and debugging.

Compat knobs are huge (`thinkingFormat`, `maxTokensField`, cache markers, …). That complexity lives in **pi-ai**, not in the coding-agent loop.

### Oh My Pi

60+ providers, role routing (`default`/`smol`/`slow`/`plan`/`commit`/`vision`/`advisor`/…), fallback chains, path-scoped models, round-robin keys, `models.yml`. Extra APIs: `openai-codex-responses`, `azure-openai-responses`, `bedrock-converse-stream`, `google-gemini-cli`, `google-vertex`. This is the “batteries” fork of the same idea, not a different architecture.

**omfx alignment with existing `PROVIDER_LANDSCAPE.md`:** Zig core should speak 2–3 codecs; JSON describes backends; TypeScript `registerProvider` covers OAuth/weirdness. Do not port OMP’s 60-provider catalog into Zig.

---

## 9. What Oh My Pi added vs Pi

OMP is **not** “Pi + a default package.” HN and the README: a **fork with foundational core features**. ([README](https://github.com/can1357/oh-my-pi); ~80k LoC Rust natives)

Added in the core (not as optional extensions):

1. **Hashline edits** (`@oh-my-pi/hashline`) — content-hash anchors; claimed huge edit-success lift  
2. **In-process Unix** — brush bash, 58 builtins, grep/glob/walker; no fork on hot path; Windows without WSL  
3. **LSP + DAP** as tools  
4. **Persistent `eval`** (Python + JS calling back into tools)  
5. **First-class subagents** (`task`, Agent Hub) — Pi ships this as an *example extension*  
6. **Advisor model** watching every turn  
7. **Time-traveling stream rules** (regex abort + inject + retry)  
8. **`/collab` live session** (sealed frames, QR)  
9. **`web_search` + 23 backends**, `browser`, `computer`  
10. **Memory backends** (local / Hindsight / Mnemopi)  
11. **ACP** (Zed)  
12. **MCP + inherit other tools’ configs** (8 formats)  
13. **Internal URL schemes** (`pr://`, `conflict://`, `xd://`, …)  
14. **Plan/vibe/review/commit** product surfaces  
15. Profiles (`--profile`), YAML config, magic keywords  

Kept from Pi: TypeScript extensions, skills, packages, session trees, multi-provider, TUI.

Pi’s explicit non-goals that OMP **re-baked into core**: MCP, sub-agents, permission popups, plan mode, todos, background bash. ([Pi philosophy](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md#philosophy))

---

## 10. What a minimal Unix-shell successor should steal vs refuse

### Steal (this is the Pi lesson)

1. **Four tools + bash is the product.** Extra FS tools (`grep`/`glob`) can exist but default off, or just tell the model to use `rg`/`find` via bash (fx-like).
2. **Shortest system prompt.** Guidelines that fit on a postcard. Point at on-disk docs instead of inlining them.
3. **One extension primitive:** a TypeScript (or JS) module with `export default (api) => {}`. Drop in `~/.omfx/extensions/*.ts` and `.omfx/extensions/`. No separate “hooks vs tools” loaders (Pi already merged those).
4. **Hot reload + examples the agent can copy.** Self-extension is a **docs + reload** feature, not a plugin marketplace.
5. **Progressive-disclosure skills** (Agent Skills / SKILL.md). Descriptions in prompt; body via `read`. Prefer “README + CLI script” over new LLM tools.
6. **Project trust before executing project TS.**
7. **Session-file custom entries** so extensions persist state without a second DB.
8. **Provider as data + 2–3 codecs**, `registerProvider` for the rest. Mid-session model switch.
9. **`tool_call` can block/mutate; `tool_result` can rewrite.** That is enough for permission gates, `uv` instead of `pip`, path protection — without a permission framework.
10. **Packages as tarballs of files** (`extensions/`, `skills/`, `prompts/`) installable from git/npm. Optional, after drop-a-file works.
11. **Tree sessions / rewind** if cheap; they make “agent builds a broken tool, branches, fixes, rewinds” actually usable.

### Refuse (this is the OMP lesson, and Pi’s “what we didn’t build”)

1. **Do not bake MCP into the core.** Optional extension or `mcporter`-style CLI. MCP fights prompt cache and hot reload.
2. **Do not ship 31 tools.** LSP, DAP, browser, computer-use, TTS, image gen, advisor, collab, memory engines are **packages or skills**, or they become the product (OMP).
3. **Do not in-process a bash clone + 58 coreutils in Zig on day one.** Unix-shell-minimal means *use the user’s shell*. In-process grep is a perf optimization, not an identity.
4. **Do not clone 34 lifecycle events.** Start with ~6; add when an extension cannot be written.
5. **Do not import every other agent’s config** (Cursor MDC, Copilot, Windsurf, …). That’s OMP’s compatibility tax.
6. **Do not add plan mode, todos, subagents, permission TUI, background jobs as builtins.** Pi proved they are extension-shaped. If omfx users need them, they write them (or install a package).
7. **Do not grow the system prompt to explain the extension system.** The agent reads `docs/extensions.md`.
8. **Do not run extension factories with network/process side effects at import.** Pi: defer to `session_start`; OMP: raw `setInterval` can kill the process.

### Minimal omfx shape (copy-paste spec)

```
Zig core:   agent loop, 2–3 LLM codecs, bash+fs tools, JSONL session, trust
TS embed:   load ~/.omfx/extensions/*.ts + .omfx/extensions/*.ts
API:        on(session_start|input|before_agent_start|tool_call|tool_result|session_shutdown)
            registerTool, registerCommand, registerProvider
Skills:     ~/.omfx/skills/**/SKILL.md  (descriptions in prompt)
Reload:     /reload after the agent writes a file
Docs:       examples/ the agent is instructed to read
MCP:        not in core
OMP-scale:  never in core
```

Pi’s one-sentence philosophy, worth tattooing on the binary: **primitives, not features** — “Adapt Pi to your workflows, not the other way around.” ([pi.dev](https://pi.dev))

OMP’s one-sentence warning: batteries-included forks re-accumulate the spaceship Pi was written to escape.

---

## Source index

| Claim | Source |
|---|---|
| 4 default tools; skip sub-agents/plan/MCP/todos/bg-bash | https://pi.dev , coding-agent README Philosophy |
| Extension paths, events, API | https://pi.dev/docs/latest/extensions |
| Skills locations + progressive disclosure | https://pi.dev/docs/latest/skills |
| Packages install/manifest | https://pi.dev/docs/latest/packages |
| Prompt templates | https://pi.dev/docs/latest/prompt-templates |
| Custom providers | https://pi.dev/docs/latest/custom-provider |
| Default system prompt source | packages/coding-agent/src/core/system-prompt.ts |
| Hooks+tools unified | https://github.com/earendil-works/pi/issues/454 |
| Self-extensible / no MCP / session trees | https://lucumr.pocoo.org/2026/1/31/pi |
| Four APIs, YOLO, no MCP rationale | https://mariozechner.at/posts/2025-11-30-pi-coding-agent/ |
| CLI/README > MCP token cost | https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/ |
| OMP 31 tools, hashline, LSP, MCP inherit | https://github.com/can1357/oh-my-pi |
| OMP extension load paths | docs/extension-loading.md |
| OMP extra events / legacy hooks | docs/extensions.md |
| OMP MCP discovery | docs/mcp-config.md |
