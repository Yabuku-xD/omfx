# How coding CLIs keep login credentials persistent

**Date:** 2026-08-21  
**Question:** After `omfx login`, how do peer CLIs keep OAuth/API-key sessions alive across process restarts and token expiry?  
**Local trigger:** `~/.omfx/auth.json` already holds `xai-oauth` (`type=oauth`, refresh present, `expires_at` set). Access token is expired. Chat still sends the dead JWT. `refreshXai` exists in `src/providers/oauth.zig` and is never called.

## What "persistent" actually means

Disk write is not persistence. Every serious coding CLI treats login as a **token lifecycle**:

1. Save access + refresh + expiry + token endpoint under a provider id, mode `0600`.
2. Remember that provider as the default (`last_provider` / config).
3. **Refresh the access token before it is used**, write the new pair back to the same file.
4. On `401` / `invalid_api_key`, refresh once more and retry.
5. If refresh is `invalid_grant`, stop looping and tell the user to `/login` again.

Without step 3, a SuperGrok device-code login "works" for about an hour, then every chat is `Incorrect API key`.

## What peers do

### Pi — `~/.pi/agent/auth.json`

Source: [pi.dev providers](https://pi.dev/docs/latest/providers)

- `/login` stores subscription OAuth (ChatGPT, Claude, Copilot, **xAI Grok/X**, OpenRouter, Radius) in `~/.pi/agent/auth.json`.
- File is created `0600`.
- Quote: **"Tokens are stored in `~/.pi/agent/auth.json` and auto-refresh when expired."**
- Quote: **"Auth file credentials take priority over environment variables."**
- OpenRouter mints a user-owned API key that does not expire; everything else is refreshable OAuth.
- `/logout` clears the stored object.

### Hermes — `~/.hermes/auth.json` (xAI SuperGrok / X Premium+)

Source: [xAI Grok OAuth guide](https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth)

- Device-code against `auth.x.ai` / `accounts.x.ai`. Same client family as Grok CLI.
- Saves tokens to `~/.hermes/auth.json`.
- Quote: **"Hermes refreshes the access token in the background — you stay signed in until you `hermes auth logout xai-oauth`."**
- Refresh **before each session** and **again on 401**.
- Terminal refresh (`invalid_grant`, HTTP 4xx): quarantine the refresh token so the next call does not hammer 401. Surface one "re-authentication required".
- OAuth preferred over leftover `XAI_API_KEY` when both exist.
- `HTTP 403` after a good login is an entitlement problem, not expiry — switch to `provider: xai` + API key.

### Claude Code

Sources: [opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth), [Claude authorization guide](https://www.remoteopenclaw.com/blog/claude-authorization-code-guide)

- macOS: Keychain service `claude-code`.
- Linux: `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`).
- In-memory cache (~30s TTL) plus refresh on the request interceptor so every Anthropic call sees a live token.

### Codex CLI

Sources: [Codex auth flows](https://codex.danielvaughan.com/2026/04/01/codex-cli-authentication-flows-credential-management/), [Codex MCP refresh issue](https://github.com/openai/codex/issues/17265), [refresh_token_reused](https://zooclaw.ai/help/en/2026-03-20/openai-codex-oauth-refresh-token-reused/)

- `~/.codex/auth.json` and/or OS keychain.
- Access tokens expire; refresh tokens **rotate**. Reusing a stale refresh token is `refresh_token_reused` — write the new refresh back immediately, never keep the previous one after a successful refresh.
- Persist the refreshed file between CI jobs or the next run is logged out.

### GitHub CLI / Copilot

Device-code GitHub tokens are long-lived (Copilot in this repo stores ~10 years). Persistence is "write once"; refresh is a no-op. Different from xAI JWTs.

## Pattern to copy (ranked)

| Must | Why |
|---|---|
| `auth.json` 0600 with `access_token`, `refresh_token`, `expires_at`, `token_endpoint` | Pi + Hermes + current omfx file shape |
| Refresh when `now >= expires_at` (expires_at already stored 5 minutes early) | Pi auto-refresh; Hermes before-session |
| Write the new access **and** refresh back atomically | Codex rotation; empty new refresh → keep old |
| Persist `last_provider` on login, not only after a chat | Hermes `config.yaml` `model.provider`; Pi stays on last login |
| Reload in-memory creds after `/login` in a live session | Process-start snapshot goes stale |
| Stored OAuth beats leftover `*_API_KEY` | Pi file > env; Hermes prefers OAuth |
| One 401 retry after force-refresh; then tell the user to login | Hermes; do not loop dead grants |

Nice later, not this change: macOS Keychain (Claude), file lock (xai-oauth-pkce), refresh-token quarantine.

## omfx gap (this checkout)

| Step | Status |
|---|---|
| Write `~/.omfx/auth.json` 0600 on login | Done (`login.saveToken`) |
| Store refresh + `expires_at` + `token_endpoint` | Done |
| `last_provider` after a chat / model pick | Done (`settings.setLastChat`) |
| Alias `xai` → `xai-oauth` so leftover `XAI_API_KEY` does not win | Done |
| Call `refreshXai` / Anthropic / ChatGPT / Google / Kimi | **Missing** |
| Persist refreshed tokens | **Missing** |
| Refresh before `ask` / TUI send | **Missing** |
| Set `last_provider` at login time | **Missing** |
| Reload `state.resolved` after TUI `/login` | **Missing** |

Local measurement (2026-08-21): `expires_at` was already in the past by ~3.7h while `refresh_token` was still on disk. xAI maps an expired JWT to `Incorrect API key`; `client.authErrorMessage` prints `omfx login xai-oauth`. That is expiry, not a missing file.

## Steal for omfx

Same file, same objects, add the lifecycle Pi and Hermes document: **ensure live token → persist → use**. No keychain in this pass.
