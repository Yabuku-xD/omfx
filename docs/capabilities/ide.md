# IDE

Open the workspace in a graphical editor you already have installed. omfx does not embed an IDE in the terminal.

## Commands

```
/ide
/ide open
/ide list
/ide cursor
```

| Form | Behaviour |
| --- | --- |
| `/ide` or `/ide open` | Launch the configured IDE on the current workspace |
| `/ide list` | Show IDE binaries found on `PATH` |
| `/ide <name>` | Pin that IDE in settings (e.g. `code`, `cursor`, `zed`) |

## Settings

In `/settings`, the **IDE** row lists what is on this machine. `auto` picks the first found. Persist with:

```
/settings ide=cursor
```

This is separate from **Editor** (`editor` / ctrl-g), which opens the draft in a terminal editor (`nvim`, `vim`, …).

## Detection

omfx looks for common CLI shims on `PATH`: `code`, `cursor`, `zed`, `windsurf`, `subl`, `idea`, `webstorm`, `fleet`, and related binaries. Install the editor's shell command if the binary is missing.

## Scope

`/ide` only launches the external app on the workspace — intentionally lightweight, no ACP bridge inside the TUI.
