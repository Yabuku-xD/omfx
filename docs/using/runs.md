# Runs (checkpoint / sleep / wake)

Park a long-horizon coding run at **storage cost only**, then resume without dumping the transcript into the model.

## Research basis

| Paper / pattern | What we take |
| --- | --- |
| **AgentRewind** ([arXiv:2608.14380](https://arxiv.org/abs/2608.14380)) | Aligned checkpoints of *pointers* + env hints; wake injects thin rewind memory, not the prior attempt |
| **CWL / Beyond Compaction** ([arXiv:2606.11213](https://arxiv.org/abs/2606.11213)) | Tool effects already live in the tree — do not keep action bodies in the live window |
| **Durable execution** | `status=sleeping` parks the run locally until `/wake` |
| **Governance Decay** ([arXiv:2606.22528](https://arxiv.org/abs/2606.22528)) | **Constraint Pinning**: mode/plan stored in meta and re-stated on wake (not summarized away) |
| **ARC cites** ([arXiv:2607.25066](https://arxiv.org/abs/2607.25066)) | Recall ids, not bodies |

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
