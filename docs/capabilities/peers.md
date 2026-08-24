# Peers and board

Start a teammate for a goal:

```
/peers <goal>
```

Peers share the same tool set in an isolated thread, coordinate through a
shared board, and do not nest further peers beyond `max_peer_depth`.

## Board

Notes live in `.omfx/board.jsonl` as structured lines:

| Kind | Form | Meaning |
| --- | --- | --- |
| `FACT` | `FACT path=src/foo.zig …` | Verified claim tied to a file |
| `FAIL` | `FAIL …` | What did not work |
| `PATH` | `PATH path=… …` | Where to look next |

The `board` tool posts and reads notes. Each turn the agent sees a short gist;
peers sync when summaries diverge enough to matter.

When git is available, a peer may use a worktree under `.omfx/peers/`; otherwise
it shares the workspace and relies on the board for isolation.

## Playbook

Verified work feeds `.omfx/playbook.jsonl` — helpful and harmful lessons,
incremental items rather than a rewritten paragraph. Clean verifies can record
entries even in a solo session with no board notes. Repeated verified facts may
graduate into workspace skills under `.omfx/skills/`.

## Memory

Long-lived facts the model should see every turn:

| Store | Where | How |
| --- | --- | --- |
| Workspace | `.omfx/memory.md` | Edit by hand or let the agent write |
| User | `~/.omfx/memory.jsonl` | `memory` tool: save / list / clear |

Both survive compaction and are reinjected into the prompt. They are separate
from the board (coordination) and the playbook (verified lessons).

See [Tools](tools.md).
