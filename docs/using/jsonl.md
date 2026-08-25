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
| `error` | Transport / ask failure | error name |
| `diagram` | Mermaid save report | message |

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
