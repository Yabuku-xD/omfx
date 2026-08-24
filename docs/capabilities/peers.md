# Peers

Start a teammate for a goal:

```
/peers <goal>
```

Peers share the same tool set in an isolated thread, communicate through the board (`FACT` / `FAIL` / `PATH`), and do not nest further peers by default. Depth is capped by settings (`max_peer_depth`).

When git is available, a peer may use a worktree under `.omfx/peers/`; otherwise it shares the workspace carefully through the board.
