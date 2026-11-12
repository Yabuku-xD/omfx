# JSONL (headless)

`omfx ask --json` emits one JSON object per line on stdout for CI and Agent SDK hosts. Events never enter the model context.

## Events

| `type` | When | `text` |
| --- | --- | --- |
| `session` | Start of the ask | `provider=… model=…` |
| `text` | Assistant stream chunk | chunk |
| `think` | Reasoning stream chunk | chunk |
| `tool_start` / `tool_end` | Tool lifecycle | `name detail` |
| `tool` | Legacy alias | `name run\|done detail` |
| `permission` | Non-interactive deny | `deny name detail` |
| `result` | Final assistant reply | full reply |
| `error` | Provider failure (non-2xx after retries, unreachable host) or ask failure | message; replaces `result` |
| `diagram` | Mermaid save report | message |

## Exit status

`0` when the model replied. `1` when the turn ended on a provider failure; plain `omfx ask` then prints `omfx: <message>` on stderr. `2` for usage errors, `78` when no provider is configured.

Overload and gateway statuses (408, 429, 500, 502, 503, 504, 529) and connection failures before the first streamed byte retry up to three times with 1 s, 2 s, 4 s backoff. Esc cancels a backoff.

Envelope:

```json
{"type":"text","text":"…"}
```

Quotes, backslashes, and newlines in `text` are escaped.

## Example

```sh
omfx ask --json --provider anthropic-api "summarize this repo"
```

Interactive prompts are unavailable under `--json`; permission asks become `permission` + deny unless `--prompt-permissions` is set with a TTY.

See [CLI](cli.md).
