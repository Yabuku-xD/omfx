# Tool union (fx / OMP / Claude / Codex) → omfx

Deduped names, then the **best** variant for a Unix-shell Zig core.

## Advertised (in the system prompt)

| Tool | Best of | Why |
| --- | --- | --- |
| read | all | workspace file |
| write | all | create/overwrite |
| edit | Pi/Claude unique-string (not OMP hashline, not yet Codex apply_patch) | smallest correct edit |
| bash | all (Codex `shell`) | Unix escape hatch |
| glob | Claude / fx / OMP | don't make the model remember `find` |
| grep | Claude / fx / OMP | don't make the model remember `rg` flags |
| web_fetch | Claude / fx | docs/URLs |
| ask_user | Claude / fx | fail closed without TTY |

## Implemented, not advertised

delete, rename (fx) — path-escaped; model can use bash. Available if an extension registers them.

## Packages (not core)

| Name | From | Why out of core |
| --- | --- | --- |
| lsp / debug | OMP | IDE |
| browser / computer / tts / image | OMP | product surface |
| mcp_* | fx / Claude / Codex | prompt dump |
| task / subagent | Claude / OMP | Pi example extension |
| todo / update_plan | Codex / OMP | Pi non-goal |
| eval | OMP | persistent interpreter |
| web_search | all | needs extra API keys; package |
| vision | fx / Claude | multimodal package |
| apply_patch | Codex | next edit-format upgrade |
| hashline | OMP | extra native |

## Compaction chosen for omfx

**Claude/Pi prefix summary + Codex cache-stable tail.** Compact after 8 turns, keep last 4 verbatim, one summary of the dropped prefix. No vendor `encrypted_content`.
