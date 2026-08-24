# UX clone: steal vs skip (2026-08-21)

Clones: `/tmp/omfx-ux/{fx,opentui,clown-code,nullclaw,architect}`.
omfx constraint: Zig core, homemade ANSI TUI, no Ratatui / OpenTUI / libvaxis. Copy interaction, not their renderer.

## Steal

| From | What | Why it fits omfx |
|---|---|---|
| vercel-labs/fx | Full-width user turn as **one tinted surface** (`user_message_card.zig`: wrap + bg row, no nested `╭│╰` box). Stream tokens by rebuilding the transcript pane; footer stays pinned. Activity label while a turn runs (`activity_status.zig`: `• Thinking`). | Same bet: Zig core, homemade shadow-VT, Unix-shaped coding agent. |
| Grok Build TUI (session target) | Hint row `Enter:send`, full-width composer, **Generating** while waiting, `You` label above the user turn. | User asked for this chrome. |
| cztomsik/clown-code | Header / transcript / footer stack; busy line (`Processing... {d}s`) while `clown.busy()`. | Confirms a three-band layout plus an in-pane wait state. |

## Skip

| From | What | Why |
|---|---|---|
| anomalyco/opentui | Zig cell renderer + React/Solid UI (OpenCode). | Product lock: homemade ANSI, TypeScript only for user extensions. Screens in OpenCode are not Zig. |
| nullclaw/nullclaw | Multi-channel gateway, no Grok-like chat TUI. | Wrong surface. |
| forketyfork/architect | SDL3 + ghostty-vt GPU terminal wall. | Multi-agent grid, not a coding-agent transcript. |
| fx | Full shadow-VT engine, activity overlay bands, truecolor OSC 11 tinting. | We already paint SGR ourselves; nested Grok TUI strips truecolor. |

## omfx mapping (this pass)

1. User turn: dim `You` + full-width indexed `user_bg`/`user_fg` rows. No inner box.
2. While `chatOnce` runs: footer hint `Generating`, cursor hidden.
3. Assistant/tool/think chunks go through `writePane`, not a CUP dump at `regionBottom`.
