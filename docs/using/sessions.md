# Sessions

Save, resume, rewind, fork, and compact conversation history.

## Where sessions live

Session files are under `~/.omfx/sessions/`. The live thread is `last.jsonl`. Workspace-local state (playbook, recall, drafts) appears under `.omfx/` in the workspace only when written.

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
- `/undo` — undo the last tracked file operation (not the same as rewind)

## Fork and handoff

- `/fork` — copy the session to a new id; keep working here
- `/handoff` — start a new session with a brief of the current goal

## Compact

`/compact` runs local ARC compaction. Dropped tool bodies become cites under `.omfx/recall/`. Compaction never encrypts and never stops the agent loop.

## Keep

`/settings keep_sessions=<n>` controls how many saved sessions stay on disk. `0` keeps all.
