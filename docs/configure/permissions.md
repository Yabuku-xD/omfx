# Permissions

Control when tools run.

## Modes

| Mode | Behavior |
| --- | --- |
| Normal (`ask`) | Sensitive tools prompt |
| Plan | Read-only; writes blocked until `/plan go` |
| Yolo | Tools run without asking for this session |

Shift-Tab cycles normal → plan → yolo. Yolo is never written to disk.

```
/permissions ask|auto|yolo
/yolo [on|off]
/plan
/plan go
```

## Allowlist (deterministic DSL)

No learned classifier. Rules are symbolic tool + argument checks. They live in settings and are enforced at runtime — never pasted into the system prompt.

```
/allowlist
/allowlist write allow
/allowlist bash:git * allow
/allowlist write.path=src/* allow
/allowlist bash:rm *#fallback=ask deny
/allowlist session bash deny
/allowlist remove write
```

| Pattern | Meaning |
| --- | --- |
| `tool` | Match the tool name |
| `tool:prefix*` | Match command/path prefix (`bash:git *`) |
| `tool.arg=value` | Named JSON arg (`write.path=src/*`) |
| `#fallback=ask\|deny` | On deny: prompt instead of hard-fail (`ask`) |

`/allowlist session …` adds ephemeral shrink-only rules (ask|deny). Expanding privilege requires a persistent `/allowlist … allow`.

## Sandbox

`/sandbox on|off` toggles the OS sandbox on bash (network denied when on). Prefer the settings panel for the same control.

- macOS: seatbelt
- Linux: landlock or bubblewrap when available

## Parse gate vs permissions

Permissions decide *whether* a tool may run. The parse gate decides *whether a write stands*: an edit that breaks a previously clean file is undone regardless of yolo. LSP type diagnostics (`lsp:`) never undo an edit.
