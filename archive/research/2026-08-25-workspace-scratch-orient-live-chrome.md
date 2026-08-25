# Workspace scratch, orient loops, live chrome (2026-08-25)

## Recall / draft / `.omfx` pollution

**Cause:** Large or secret-shaped tool results call `recall.put`, which mkdirs `.omfx/recall/` and writes `rN.txt`. That is independent of handoff/runs/sessions — those dirs are slash-gated. `draft.txt` is only created by external editor (`ctrl-g`) and was left behind after save.

**Industry:** Session/scratch belongs under the agent home profile (Claude: `~/.claude/projects/…`), not as silent project litter. Lazy create-on-use is fine; explore dumps should not force disk archives.

**Fix:** Cap list/glob/grep/bash/web explore results in memory (no recall files). Keep disk recall for file reads / secrets that need cite-back. Delete `draft.txt` after the external editor returns.

## Orient / NotAFile loop

**Cause:** Models `read` directories (`.` / `research`). Hard `error.NotAFile` is opaque; they retry (Kilo #4679, Claude EISDIR). Sandbox is bash-only — unrelated.

**Industry:** Soft recovery — hint + list (Kilo v7 lists dirs from read; Agent Patterns: actionable tool results, not bare Zig names). Harness circuit breakers stay as backstop.

**Fix:** `read` on a directory returns a soft “use list” message plus a one-level listing. Schema/postcard say list=folders, read=files. Keep `orient_streak` nudge.

## Empty finish after tools

**Cause:** Final `.text` can be empty after tools; REPL only appended final prose when `shown` was unchanged, so tool cards + late unstreamed prose vanished.

**Fix:** Notice when tools ran with empty prose; append final reply when it never streamed into `asst_hold`.

## Slash + context while generating

**Cause:** Watch owns stdin; slash matching and context clicks only ran on the idle loop. Header `context_used` was a frozen turn-start snapshot.

**Industry:** Claude keeps slash/input chrome live while generating (`/btw`, interactive mode); fullscreen keeps a fixed input box.

**Fix:** Mid-turn slash picker on steer typing; Tab/arrows; Enter defers `/cmd` to post-turn dispatch. Live token meter; click header context for a live peek overlay.
