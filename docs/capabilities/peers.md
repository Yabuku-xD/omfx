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

## Playbook and memory

Verified work also feeds `.omfx/playbook.jsonl` (helpful/harmful lessons).
Long-lived facts belong in `.omfx/memory.md` or the user `memory` store under
`~/.omfx/`. See [Tools](tools.md).
