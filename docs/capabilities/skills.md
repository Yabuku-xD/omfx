# Skills

Skills are discovered, not hard-coded into a fixed product list.

omfx walks known agent skill roots under your home directory (one and two levels deep), dedupes by inode then name, and exposes each skill as a slash command. The skill's `description:` front matter is the help text.

```
/reload
```

rescans. Built-in system commands still own the slash line when they match first.

## Where skills are found

Workspace and home trees participate, including roots used by other agent CLIs (for example `.claude/skills`, `.agents/skills`, `.codex/skills`, `.omfx/skills`). Dot-directories are skipped when walking. Verified playbook facts may also graduate into workspace skills under `.omfx/skills/`.

## Stacking skills and files

Other CLIs converge on the same idea: name several skills in one prompt, keep the rest of the line as the task, and attach files with `@`.

| Shape | Example | Behaviour |
| --- | --- | --- |
| Leading stack | `/deslop /tdd fix @src/main.zig` | Consecutive known skills at the start expand; everything after is the shared task, including `@paths` |
| Mid-prompt | `please /deslop this @note.txt` | Each `/skill` in prose expands in place; `@files` still inject |
| `$skill` + `@file` | `$deslop @note.txt` | Multiple skill mentions mean use them all; files are anchors |

omfx follows the leading stack and the mid-prompt form. Expansion stops at the first token that is not a known skill. Cap is eight skills per prompt. Skill bodies stay on disk (`Read …/SKILL.md and follow it`) so context stays progressive.

A sample skill ships at `skills/hello-omfx/` in this repository.

## Plugins

Curated catalogs use `/plugin marketplace add`. Day-to-day skills usually need no marketplace. See [Plugins](plugins.md).
