# Compare

Honest field notes: what omfx ships vs common coding-agent CLIs, and what we refuse on purpose.

| Surface | omfx bet | Note |
| --- | --- | --- |
| Context | ARC cites + board gist + thin handoff/spec pointers | No transcript dump into the system prompt |
| Handoff | Deterministic packet under `.omfx/handoff/` | Reviewable on disk; `/compact` stays ARC; no summarizer loss into the next thread |
| Spec-first | `.omfx/specs/<name>/{requirements,design,tasks}.md` | Only `spec=… phase=… task=…` enters orientation; full docs stay on disk |
| Permissions | Symbolic tool+arg DSL + session shrink-only rules | No learned classifier, no policy prose in the prompt |
| Git undo | Opt-in `git_auto` / `git_dirty` + SHA-gated reset | Default off; SHAs never in the prompt |
| Headless | `omfx ask --json` JSONL events | Host-facing only; never appended into the model thread |
| Sleep / wake | `.omfx/runs/` checkpoint packets | Thin `/wake` stub, no transcript replay |
| Repo map | Personalized file-graph rank + symbol pack (4k) | No tree-sitter; no context bloat |
| Search | Hybrid `semantic_search` + ranked map | Embedding / code-DB intentionally refused |
| Windows | macOS/Linux first | Install + sandbox paths show the focus |

## One-liners

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
omfx ask --json "summarize this repo"
```

See [Permissions](configure/permissions.md), [Sessions](using/sessions.md), [Runs](using/runs.md), [JSONL](using/jsonl.md), and [Configuration](configure/configuration.md).
