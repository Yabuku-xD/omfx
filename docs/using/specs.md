# Specs

Three-file workflow: full docs on disk, a thin pointer plus a short phase postcard in the system prompt — never the document bodies.

## Layout

```
.omfx/specs/<name>/
  requirements.md
  design.md
  tasks.md
```

Active pointer: `.omfx/specs/.active` (`name` + `phase`).

## Commands

```
/spec                 list specs
/spec new <name>      create stubs; phase=requirements; starts a turn
/spec <name>          resume a spec; starts a turn
/spec next            requirements → design → tasks → execute; starts a turn
/spec run [name]      jump to execute; starts a turn
```

## What enters the model

Every turn while a spec is active:

1. Orientation pointer only, e.g. `spec=auth phase=design task=…`
2. Spec overlay (same tools as the base postcard; use `read`/`write`/`edit`/`patch` on phase files; keep bodies on disk)

`/plan` is separate: ad-hoc read-only frontier interview. `/spec` owns the gated three-file flow. If both are on, plan still blocks mutations until `/plan go`.
