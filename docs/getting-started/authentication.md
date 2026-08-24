# Authentication

How omfx reaches models. omfx is not a gateway and has no API key of its own.

## Interactive login

```sh
omfx
```

Type `/login` (alias `/setup`). Pick a provider from the list:

- OAuth routes such as `xai-oauth`, `anthropic`, `openai-codex`, `github-copilot`, `kimi-code`
- API-key routes such as Groq, OpenRouter, Ollama, and others in the catalog

Stored credentials live in `~/.omfx/auth.json` (mode `0600`). A stored OAuth token beats a leftover `*_API_KEY` environment variable for the same provider.

## CLI login

```sh
omfx login                 # list providers
omfx login xai-oauth       # device code
omfx login groq            # paste a key
```

Prefer `/login` inside a session when you can; the CLI form is for scripts and first-time setup outside the TUI.

## Logout

```
/logout [provider|all]
```

## Base URL overrides

`OMFX_BASE_URL` can redirect the active provider's HTTP base for local gateways. Attribution headers (`http-referer`, `x-title`, …) stay off unless `/settings` turns `telemetry` on.
