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

## Allowlist

`/allowlist` inspects or appends persistent rules in settings so repeated safe tools stop prompting.

## Sandbox

`/sandbox on|off` toggles the OS sandbox on bash (network denied when on). Prefer the settings panel for the same control.

- macOS: seatbelt
- Linux: landlock or bubblewrap when available

## Parse gate vs permissions

Permissions decide *whether* a tool may run. The parse gate decides *whether a write stands*: an edit that breaks a previously clean file is undone regardless of yolo. LSP type diagnostics (`lsp:`) never undo an edit.
