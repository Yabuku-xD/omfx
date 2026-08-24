# 2026 model-provider landscape for a model-agnostic coding CLI

Research for a Zig+TypeScript coding agent that must beat [vercel-labs/fx](https://github.com/vercel-labs/fx) on provider coverage without bloating the Zig core.

**Date:** 2026-08-20  
**Sources:** first-party docs and CLI source/docs (fx, OpenCode, Goose, Crush, Aider, LiteLLM, Vercel AI Gateway, OpenRouter). Secondary roundups used only for orientation.

---

## 1. The actual 2026 wire-protocol map

Almost every backend a coding CLI cares about speaks **one of three HTTP shapes**:

| Protocol | Endpoint | Who needs a native codec |
|---|---|---|
| **OpenAI Chat Completions** | `POST {base}/chat/completions` + SSE | ~90% of hosts (Groq, Fireworks, Together, DeepSeek, DashScope, Mistral, Cerebras, SambaNova, NIM, Ollama, vLLM, llama.cpp, LM Studio, MLX servers, OpenRouter, LiteLLM, Vercel Gateway, …) |
| **OpenAI Responses** | `POST {base}/responses` | OpenAI flagship agentic path; xAI Grok 4.6; Vercel Gateway; some Cloudflare models |
| **Anthropic Messages** | `POST {base}/messages` + `anthropic-version` | First-party Claude; Claude Code gateways; Vercel Gateway Anthropic-compat; some OpenRouter Claude routes |

Google is the only remaining first-party that still has a widely used **native** API (`generativelanguage.googleapis.com/v1beta`, plus the 2026 Interactions API). In practice CLIs treat Gemini as either:

- native generateContent (Goose, OpenCode via `@ai-sdk/google`), or
- OpenAI-compat at `https://generativelanguage.googleapis.com/v1beta/openai/` (good enough for tools+streaming).

**Do not implement 20 SDKs in Zig.** Implement 2 codecs (OpenAI chat SSE + Anthropic messages SSE), optionally a thin Responses adapter, and describe every backend as JSON.

---

## 2. First-party / lab APIs (the named list)

Auth is Bearer unless noted.

| Provider | Default base | Protocol | Auth | Notes for a coding agent |
|---|---|---|---|---|
| **OpenAI** | `https://api.openai.com/v1` | chat + **responses** | `OPENAI_API_KEY`; org/project headers | Tool calling, reasoning, Responses is the agentic path. ChatGPT Plus/Pro is **OAuth**, not the API key. |
| **Anthropic** | `https://api.anthropic.com` | messages | `x-api-key` + `anthropic-version`; `ANTHROPIC_API_KEY` | Prompt caching (`cache_control`) matters. Claude Pro/Max is OAuth; Anthropic forbids third-party CLIs using the subscription (OpenCode docs, 2026). |
| **Google** | `https://generativelanguage.googleapis.com/v1beta` | native or openai-compat | `GEMINI_API_KEY` / `GOOGLE_API_KEY` | Vertex is ADC + project/location, not a key. Gemini 3 thinking levels. |
| **xAI / Grok** | `https://api.x.ai/v1` | openai + responses | `XAI_API_KEY` | Docs push `/v1/responses` for Grok 4.6. SuperGrok OAuth exists (Goose). |
| **Amazon Bedrock** | regional `bedrock-runtime.{region}.amazonaws.com` | Converse **or** Anthropic-compat | SigV4 (`AWS_*`) **or** `AWS_BEARER_TOKEN_BEDROCK` | The expensive special case. Do **not** SigV4 in Zig core; plugin or sidecar. |
| **Azure OpenAI / Foundry** | `https://{resource}.openai.azure.com` | openai + `api-version` | key, Entra bearer, or credential chain | Deployment name ≠ model id. Foundry adds Anthropic/Meta/etc. MaaS endpoints. |
| **Groq** | `https://api.groq.com/openai/v1` | openai | `GROQ_API_KEY` | Fast; incomplete OpenAI surface (`n>1` etc.). |
| **Fireworks** | `https://api.fireworks.ai/inference/v1` | openai | `FIREWORKS_API_KEY` | Declarative in Goose. |
| **Together** | `https://api.together.xyz/v1` | openai | `TOGETHER_API_KEY` | Same. |
| **DeepSeek** | `https://api.deepseek.com` | openai | `DEEPSEEK_API_KEY` | `reasoning_content` on R1-class models. |
| **Qwen / DashScope** | `https://dashscope.aliyuncs.com/compatible-mode/v1` (intl variants exist) | openai | `DASHSCOPE_API_KEY` | Crush: `ALIBABA_SINGAPORE_API_KEY` / `ALIBABA_US_API_KEY`. Goose: declarative Alibaba provider. |
| **Mistral** | `https://api.mistral.ai/v1` | openai | `MISTRAL_API_KEY` | Codestral is the same shape. |
| **Cohere** | `https://api.cohere.com/v2` | **native chat** (not OpenAI) | `COHERE_API_KEY` / `CO_API_KEY` | Skip native unless needed; route via OpenRouter/LiteLLM. Aider talks to it via LiteLLM. |
| **Hugging Face** | `https://router.huggingface.co/v1` (Inference Providers, 2026) | openai | `HF_TOKEN` | TGI archived Mar 2026; HF is now a router. |
| **NVIDIA NIM** | `https://integrate.api.nvidia.com/v1` | openai | `NVIDIA_API_KEY` | Also self-hosted NIM = openai on your URL. |
| **Cloudflare Workers AI** | `https://api.cloudflare.com/client/v4/accounts/{id}/ai/v1` | openai (+ responses for some) | CF API token + account id | Separate: **Cloudflare AI Gateway** (unified billing across vendors). |
| **Cerebras** | `https://api.cerebras.ai/v1` | openai | `CEREBRAS_API_KEY` | Drops some OpenAI params (400 if sent). |
| **SambaNova** | `https://api.sambanova.ai/v1` | openai | `SAMBANOVA_API_KEY` | |
| **Hyperbolic** | `https://api.hyperbolic.xyz/v1` | openai | `HYPERBOLIC_API_KEY` | LiteLLM: add via JSON, no code. |
| **Novita** | `https://api.novita.ai/v3/openai` | openai **and** anthropic-compat | `NOVITA_API_KEY` | |
| **SiliconFlow** | `https://api.siliconflow.cn/v1` | openai | `SILICONFLOW_API_KEY` | CN-heavy catalog. |
| **GitHub Models** | — | — | — | **Retired 2026-07-30.** Use **GitHub Copilot** device-flow instead (`https://api.githubcopilot.com`). |

---

## 3. OpenAI-compatible gateways / aggregators

These are how a tiny CLI gets 75+ backends without writing them.

| Gateway | Base | Auth | Why it exists |
|---|---|---|---|
| **OpenRouter** | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | Biggest public catalog; fallbacks; optional `HTTP-Referer` / `X-OpenRouter-Title`. |
| **LiteLLM** (lib + proxy) | user (`:4000`) | `LITELLM_API_KEY` | Aider’s entire provider surface. Hundreds of native adapters **outside** your binary. Point at the proxy as openai. |
| **Vercel AI Gateway** | `https://ai-gateway.vercel.sh/v1` | `AI_GATEWAY_API_KEY`, `VERCEL_OIDC_TOKEN`, or Vercel OAuth | openai + anthropic + responses. Zero markup, BYOK, failover. **This is fx’s only path.** |
| **Cloudflare AI Gateway** | account/gateway URL | CF token / unified billing | Fronts OpenAI, Anthropic, Workers AI. |
| **Databricks / Snowflake Cortex / SAP / Scaleway / OVH / Venice / Routstr / Tetrate** | various | vendor keys | Enterprise/regional openai fronts. Goose has first-class entries. |

**Implication:** shipping OpenRouter + LiteLLM-proxy + “any openai base URL” already covers more vendors than a 20-SDK core.

---

## 4. Local / self-hosted runtimes

All of these (in 2026) expose **OpenAI chat** on localhost. Do not special-case their inference engines.

| Runtime | Typical URL | Auth | Extra |
|---|---|---|---|
| **Ollama** | `http://127.0.0.1:11434/v1` | none / `OLLAMA_API_KEY` for cloud | Also `https://ollama.com` cloud. `GET /v1/models`. |
| **LM Studio** | `http://127.0.0.1:1234/v1` | none | Goose default. |
| **llama.cpp** (`llama-server`) | `http://127.0.0.1:8080/v1` | optional | OpenCode has a first-class entry. |
| **vLLM** | `http://host:8000/v1` | optional | Production OSS serving (TGI archived). |
| **MLX** (`mlx_lm.server` / Goose local) | localhost openai | none | Apple Silicon; Goose added MLX to local inference (2026). |
| **NVIDIA NIM** (self-host) | user URL `/v1` | optional | Same codec as cloud NIM. |
| **Docker Model Runner / Ramalama / Atomic Chat** | openai on 12434 / ollama-compat / `:1337` | none | Goose treats as openai/ollama engines. |

Capability gotcha: tool-calling quality varies wildly. Catalog should flag `tools: true` only for models known to work (Qwen-Coder, DeepSeek-Coder, etc.).

---

## 5. How the top CLIs plug providers

### vercel-labs/fx (Zig) — the thing to beat

- **One backend:** Vercel AI Gateway.
- Auth order ([fx docs](https://fx.sh/docs/getting-started/authentication)): `VERCEL_OIDC_TOKEN` → `AI_GATEWAY_API_KEY` → `fx login` OAuth (`~/.fx/auth.json`) → keychain/`fx setup`.
- Model picker is Gateway catalog (`/models`). Local inference is “whatever Gateway or a local model the account exposes”, not first-class Groq/Anthropic/Ollama adapters.
- **Gap:** model-agnostic *marketing*, provider-locked *implementation*. Beating fx = first-class openai+anthropic codecs + JSON provider catalog + local base URLs, not another Gateway.

### OpenCode (anomalyco/opencode, TS)

- **AI SDK + [Models.dev](https://models.dev)** → 75+ providers.
- Credentials in `~/.local/share/opencode/auth.json` via `/connect`.
- Config: `provider.<id>.options.baseURL`, npm package (`@ai-sdk/openai-compatible` vs `@ai-sdk/openai` for `/v1/responses` vs `@ai-sdk/anthropic` / `@ai-sdk/google` / `@ai-sdk/cerebras`).
- Custom provider = JSON + openai-compat package. Bedrock/Azure/Vertex are the only fat auth paths.
- Optional **OpenCode Zen/Go** (their hosted, tested coding models).
- Anthropic Pro/Max OAuth is documented but Anthropic ToS-hostile; Copilot / ChatGPT / GitLab Duo subscriptions are first-class.

### Goose (aaif-goose/goose, Rust)

- `Provider` trait + **registry** of built-ins + **declarative JSON** (`engine: OpenAI | Anthropic | Ollama`).
- This is the closest design to copy.
- Built-ins: OpenAI, Anthropic, Gemini, Vertex, Bedrock, Azure/Foundry, Databricks, Groq, Mistral, xAI, OpenRouter, LiteLLM, Ollama, LM Studio, Copilot (device flow), ChatGPT OAuth, plus a flood of declarative openai hosts (Fireworks, Together, DashScope, Novita, Cerebras, Perplexity, …).
- Extra: CLI-passthrough (`cursor-agent`) and **ACP providers** (Claude Code / Codex as the model).
- Auth: env → config.yaml → OS keychain; OAuth with proactive refresh.

### Crush (charmbracelet/crush, Go)

- **Two types only:** `openai` and `anthropic` (plus Bedrock detect).
- Catalog is **Catwalk** (remote JSON, auto-update; disable for airgap). User JSON can add any openai/anthropic base_url.
- Env table: Hyper, Anthropic, OpenAI, Vercel Gateway, Gemini, Z.ai, MiniMax, Synthetic, HF, Cerebras, OpenRouter, io.net, Alibaba SG/US, Groq, Avian, OpenCode Zen, Azure, Moonshot, DeepSeek via custom JSON.
- **This is the minimum-bloat pattern.**

### Aider (Python)

- **LiteLLM as the provider layer.** `--model openai/foo` + `OPENAI_API_BASE` for anything openai-compat.
- First-class docs for OpenAI, Anthropic, Gemini, Groq, LM Studio, xAI, Azure, Cohere, DeepSeek, Ollama, OpenRouter, Copilot, Vertex, Bedrock.
- Tradeoff: Python+LiteLLM is huge. Do not vendor LiteLLM into Zig; optionally *call* a LiteLLM proxy.

### Claude Code (Anthropic, proprietary)

- Speaks **Anthropic Messages only**.
- Enterprise/gateway: `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` / `apiKeyHelper`.
- Not multi-provider. Third parties (OpenRouter, Claude Code Router, 302.AI) pretend to be Anthropic. Weak with non-Claude models.
- Do not emulate this as your architecture; *accept* Anthropic-shaped gateways as one protocol.

---

## 6. Recommended provider abstraction (Zig core stays small)

### Zig implements (only)

```
Protocol = openai_chat | openai_responses | anthropic_messages

ProviderSpec (loaded from JSON, not compiled in):
  id, name
  base_url
  protocol
  auth: { kind: bearer | header | query,
          env, header_name, extra_headers[] }
  path?                  // if not /chat/completions or /messages
  api_version?           // Azure query
  extra_headers[]        // anthropic-version, OpenRouter referer
  models[] { id, context, output, tools, reasoning, vision, cache }
  quirks: { drop_params[], remap_system_to_user, tool_call_style }

ChatRequest  { model, messages[], tools[], stream, max_tokens,
               temperature?, reasoning_effort?, cache_hint? }
StreamEvent  { text_delta | thinking_delta | tool_call_delta |
               usage | stop(reason) | error }
```

HTTP/SSE + JSON encode/decode + retry/429 `Retry-After` live in Zig.  
**No per-vendor modules in the binary.**

### TypeScript (or a JSON catalog file) owns

- Provider presets (the table in §2–4) — Crush Catwalk / Models.dev style, fetchable, embeddable for airgap.
- Model metadata (context, pricing, tool support) from Models.dev.
- Auth UX: `login` OAuth device flows (Copilot, ChatGPT, Claude, Vercel, xAI SuperGrok).
- Cloud IAM plugins: Bedrock SigV4, Vertex ADC, Azure credential chain — **out-of-process or TS**, never in the 6–8 MB Zig core.

### Auth story

Priority (match fx/Goose, but generic):

1. Process env (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `AI_GATEWAY_API_KEY`, …).
2. OS keychain / `~/.omfx/auth.json` (mode 0600), written by `omfx login` / `omfx auth`.
3. Provider-specific OAuth tokens with refresh (TS helper).
4. Explicit `base_url` + `api_key` in project config (**never** commit secrets; allow `${ENV}`).

Standard env names (copy LiteLLM/Crush, don’t invent):

`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `GROQ_API_KEY`, `FIREWORKS_API_KEY`, `TOGETHER_API_KEY`, `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`, `MISTRAL_API_KEY`, `COHERE_API_KEY`, `OPENROUTER_API_KEY`, `AI_GATEWAY_API_KEY` / `VERCEL_API_KEY`, `HF_TOKEN`, `NVIDIA_API_KEY`, `CEREBRAS_API_KEY`, `SAMBANOVA_API_KEY`, `HYPERBOLIC_API_KEY`, `NOVITA_API_KEY`, `SILICONFLOW_API_KEY`, `OLLAMA_HOST`, `AWS_BEARER_TOKEN_BEDROCK`, `AZURE_OPENAI_API_KEY`.

### Coverage vs code size

| Layer | Backends covered | Zig LOC |
|---|---|---|
| openai_chat + bearer | Groq, Fireworks, Together, DeepSeek, DashScope, Mistral, Cerebras, SambaNova, Hyperbolic, Novita, SiliconFlow, NIM, HF router, OpenRouter, LiteLLM, Vercel Gateway, Ollama, LM Studio, llama.cpp, vLLM, MLX, Cloudflare Workers AI, GitHub Copilot (once you have a token) | 1 codec |
| anthropic_messages + x-api-key | Anthropic, Vercel Gateway Claude, Anthropic-shaped proxies | 1 codec |
| openai_responses (optional) | OpenAI/xAI agentic | thin adapter on same HTTP client |
| JSON catalog + env | all of the above named as first-class in `/models` | 0 |
| TS plugins | Bedrock SigV4, Vertex ADC, Azure Entra, Copilot device flow | 0 in Zig |
| skip native | Cohere v2, Gemini native (use openai-compat) | 0 |

That is **20+ backends** with **two codecs**. Adding a vendor is a JSON stanza (`base_url`, `env`, `protocol`), not a Zig file.

### What not to do

- Do not vendor LiteLLM or Vercel AI SDK into Zig (OpenCode’s approach is fine for TS, fatal for a 6 MB binary).
- Do not implement Bedrock Converse or Vertex generateContent in core.
- Do not treat GitHub Models as alive (retired 2026-07-30).
- Do not rely on “OpenAI-compatible” as identical: strip unsupported params per `quirks.drop_params` (Cerebras `frequency_penalty`, Groq `n`, Gemma system messages).
- Do not send Anthropic `cache_control` to openai hosts; do not send OpenAI `reasoning_effort` to Claude without mapping.

### Suggested config (user-facing)

```jsonc
{
  "provider": {
    "openrouter": { "protocol": "openai_chat", "base_url": "https://openrouter.ai/api/v1", "auth": { "env": "OPENROUTER_API_KEY" } },
    "anthropic":  { "protocol": "anthropic_messages", "base_url": "https://api.anthropic.com", "auth": { "kind": "header", "header_name": "x-api-key", "env": "ANTHROPIC_API_KEY" }, "extra_headers": { "anthropic-version": "2023-06-01" } },
    "ollama":     { "protocol": "openai_chat", "base_url": "http://127.0.0.1:11434/v1", "auth": { "kind": "none" }, "dynamic_models": true }
  },
  "model": "openrouter/anthropic/claude-sonnet-4"
}
```

`dynamic_models: true` → `GET {base}/models` (Goose/Crush already do this).

---

## 7. fx comparison (why this wins)

| | fx | recommended omfx |
|---|---|---|
| Zig core | Gateway HTTP client | 2 protocol codecs + SSE |
| Providers | Vercel AI Gateway only | JSON catalog: 20+ named + any openai/anthropic URL |
| Auth | Vercel OAuth / Gateway key / OIDC | env + keychain + optional TS OAuth |
| Local | via Gateway or undocumented | Ollama/LM Studio/llama.cpp/vLLM as openai presets |
| Model catalog | Gateway | Models.dev + Catwalk-style refresh, embeddable |
| Binary bloat | tiny | still tiny (codecs, not SDKs) |

---

## Sources

- fx: https://github.com/vercel-labs/fx , https://fx.sh/docs/getting-started/authentication
- OpenCode providers: https://opencode.ai/docs/providers (updated 2026-08-19)
- Models.dev: https://models.dev
- Goose providers: https://block.github.io/goose/docs/getting-started/providers and `crates/goose/src/providers/`
- Crush: https://github.com/charmbracelet/crush (Catwalk catalog, openai|anthropic types)
- Aider: https://aider.chat/docs/llms.html , https://aider.chat/docs/llms/other.html (LiteLLM)
- LiteLLM providers: https://docs.litellm.ai/docs/providers
- Vercel AI Gateway: https://vercel.com/docs/ai-gateway
- OpenRouter: https://openrouter.ai/docs
- xAI: https://docs.x.ai/docs (`https://api.x.ai/v1`)
- Cloudflare Workers AI openai-compat: https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility
- GitHub Models retirement: https://docs.github.com/en/github-models/use-github-models (retired 2026-07-30)
- Claude Code gateways: https://code.claude.com/docs/en/llm-gateway (`ANTHROPIC_BASE_URL`)
