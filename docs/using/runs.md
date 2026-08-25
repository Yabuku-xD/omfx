# Runs (checkpoint / sleep / wake)

Park a long-horizon coding run at **storage cost only**, then resume without dumping the transcript into the model.

## Why this shape

Checkpoints store **pointers** (paths, recall ids, pinned mode/plan) and a human-reviewable packet on disk. Wake injects a thin stub — not the prior attempt or tool bodies. Effects already live in the tree.

## Layout

```
.omfx/runs/<id>/
  checkpoint.md   # human-reviewable packet
  meta.json       # status, goal, pinned mode/plan
.omfx/runs/.active
```

## Commands

```
/checkpoint [note]   snapshot (status=ready)
/sleep [note]        snapshot + status=sleeping (zero compute)
/wake                list runs
/wake last           wake the active run
/wake <id>           wake a specific run
```

`/wake` returns a **thin stub** as the next user turn (`WAKE run=… packet=…`). It does **not** replay session JSONL into the model.

## What is never stored in the live prompt

- Prior assistant replies
- Tool result bodies (use `cite rN` / open the packet)
- Full board dumps beyond the capped packet on disk
