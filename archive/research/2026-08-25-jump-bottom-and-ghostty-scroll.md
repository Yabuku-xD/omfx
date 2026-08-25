# Jump-to-bottom + smooth streaming (Ghostty)

Sources: MUI X chat scrolling docs; prompt-kit / use-stick-to-bottom; DECSET ?2026 (iTerm2/contour proposal, Ghostty/kitty/WezTerm/alacritty); Ghostty mouse-scroll-multiplier PRs; Ghostty discussion #2355 (smooth scroll).

## Chat UX (web / IDE)

Industry pattern (ChatGPT, Cursor, MUI X, prompt-kit):

1. **Stick-to-bottom** while the viewport is near the live tail (buffer of a few lines / ~50–100px). New tokens keep the view pinned.
2. **Break stick** when the user scrolls up past that buffer so they can read history without fighting the stream.
3. **Floating jump control** appears once unstuck; click re-pins (`scroll = 0`) and resumes stick during generation.
4. Hit target is the **button only**, not the full width of its row.

Smooth CSS `scrollTo({ behavior: "smooth" })` / spring scroll is a browser affordance. A cell TUI cannot pixel-animate alt-screen content the same way.

## What Ghostty (and peers) actually give a TUI

| Feature | Use for omfx |
| --- | --- |
| **DECSET ?2026** synchronized updates (`\x1b[?2026h` … `l`) | Already used (`tui.sync_begin` / `sync_end`). Atomic frame paint → less tear while streaming. Safe on terminals that ignore it. |
| **SGR mouse 1006** | Wheel + click hit-testing for the jump pill. |
| **mouse-scroll-multiplier** | Terminal-side; app still receives discrete wheel notches. omfx maps notches to a few transcript rows. |
| **DECSCLM / “smooth scroll”** | Hardware-era linefeed animation; not a useful path for alt-screen app-owned scrollbacks (Ghostty discussion #2355). |

## omfx design choice

- App-owned scroll offset (`scroll` from bottom): stick when `0`, show jump when `scroll >= threshold`.
- Jump pill: one centered row above the composer; click only on pill columns.
- Click during generate: set `scroll = 0` so the next paint follows the stream again.
- Do **not** fake sub-cell smooth scroll; rely on ?2026 + small wheel steps for feel.
