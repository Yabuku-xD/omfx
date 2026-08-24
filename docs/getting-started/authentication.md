# Authentication

How omfx reaches models. omfx is not a gateway and has no API key of its own.

## Interactive login

```sh
omfx
```

Type `/login` (alias `/setup`). Pick a provider from the catalog list. Routes include:

- OAuth / device-code where the vendor has a route (for example Anthropic subscription, OpenAI Codex, xAI)
- API-key paste everywhere else

Stored credentials live in `~/.omfx/auth.json` (mode `0600`). A stored OAuth token beats a leftover `*_API_KEY` environment variable for the same provider.

## CLI login

```sh
omfx login                 # list providers
omfx login xai-oauth       # device code
omfx login anthropic-api   # paste a key
```

Prefer `/login` inside a session when you can; the CLI form is for scripts and first-time setup outside the TUI.

## Logout

```
/logout [provider|all]
```

## Models after login

`/models` shows what the signed-in provider actually lists. Subscription and API-key logins for the same model name may see different context ceilings. See [Models](../configure/models.md).

## Base URL overrides

`OMFX_BASE_URL` can redirect the active provider's HTTP base for local gateways. Attribution headers (`http-referer`, `x-title`, …) stay off unless `/settings` turns `telemetry` on.
