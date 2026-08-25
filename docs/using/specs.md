# Specs

Three-file workflow without dumping requirements into every turn.

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
/spec new <name>      create stubs; phase=requirements
/spec <name>          resume a spec
/spec next            requirements → design → tasks → execute
/spec run [name]      jump to execute
```

## Context rule

Orientation injects only:

```
spec=<name> phase=<phase> task=<first open checkbox>
```

Read the markdown files when needed. `/plan` stays for ad-hoc read-only research; `/spec` owns the three-file gates.
