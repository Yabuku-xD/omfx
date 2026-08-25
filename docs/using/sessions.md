# Sessions

Save, resume, rewind, fork, and compact conversation history.

## Where sessions live

Session files are under `~/.omfx/sessions/`. The live thread is `last.jsonl`. Workspace-local state (playbook, board, recall, memory, drafts) appears under `.omfx/` in the workspace only when written.

## Resume

```
/resume
/resume last
/resume <id>
```

Bare `/resume` opens the sessions panel. Outside the TUI: `omfx session resume last`.

## Clear and reset

- `/clear` (alias `/new`) — new thread; background jobs keep running
- `/reset` — new thread and stop background jobs

## Rewind and undo

- `/rewind` — pick a prior prompt; `/rewind <n>` steps back
- `/rewind <n> from` / `/rewind <n> upto` — compress one side instead of discarding
- `/undo` — undo the last tracked file operation; if `git_auto` recorded an omfx commit at HEAD, also resets that commit (SHA-gated)

## Fork and handoff

- `/fork` — copy the session to a new id; keep working here
- `/handoff [goal]` — new session from a **deterministic packet** (board paths, recall ids, open todos). No last-reply dump. Reviewable at `.omfx/handoff/<id>.md`; the new thread starts with a thin stub that points at the packet.

## Specs

`/spec` manages `.omfx/specs/<name>/{requirements,design,tasks}.md`. Only the active task pointer enters orientation — see [Specs](specs.md).

## Runs (checkpoint / sleep)

`/checkpoint`, `/sleep`, and `/wake` park and resume long work under `.omfx/runs/` without replaying the transcript — see [Runs](runs.md).

## Compact and recall

`/compact` runs local ARC compaction. Dropped tool bodies become cites under `.omfx/recall/` — inspectable files, not an LLM rewrite of your history. Compaction never encrypts and never stops the agent loop.

Memory (workspace and user) is reinjected every turn and survives compaction.

## Keep

`/settings keep_sessions=<n>` controls how many saved sessions stay on disk. `0` keeps all.
