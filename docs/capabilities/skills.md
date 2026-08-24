# Skills

Skills are discovered, not hard-coded into a fixed product list.

omfx walks known agent skill roots under your home directory (one and two levels deep), dedupes by inode then name, and exposes each skill as a slash command. The skill's `description:` front matter is the help text.

```
/reload
```

rescans. Built-in system commands still own the slash line when they match first.

## Stacking skills and files

Other CLIs converge on the same idea: name several skills in one prompt, keep the rest of the line as the task, and attach files with `@`.

| Shape | Example | Behaviour |
| --- | --- | --- |
| Leading stack (Claude Code) | `/deslop /tdd fix @src/main.zig` | Consecutive known skills at the start expand; everything after is the shared task, including `@paths` |
| Mid-prompt (omp-style) | `please /deslop this @note.txt` | Each `/skill` in prose expands in place; `@files` still inject |
| Codex | `$skill` + `@file` | Multiple skill mentions mean use them all; files are anchors |

omfx follows the Claude leading stack and the mid-prompt form. Expansion stops at the first token that is not a known skill. Cap is eight skills per prompt. Skill bodies stay on disk (`Read …/SKILL.md and follow it`) so context stays progressive, like Codex.

Workspace and home `skills/` directories participate. A sample skill ships at `skills/hello-omfx/` in this repository.
