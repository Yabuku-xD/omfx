# Agent re-plan loops + sticky todos

Date: 2026-08-25

## Verdict

Prompt nudges alone are **not** industry standard for stopping re-plan / explore thrash. Sticky task lists belong in **chrome near the composer**, not as scrollback rows.

## Re-plan / tool loops

Sources:

- [Typed Tool-Loop Failure Detector](https://www.agentpatternscatalog.org/patterns/typed-tool-loop-detector/) — prompt rules are advisory; detection must run at the dispatch boundary and return a forced tool result.
- [Circuit Breaker (agentic coding patterns)](https://aipatternbook.com/circuit-breaker) — breaker lives in the harness/tool layer; a confused agent cannot disable it.
- [loopbreaker](https://github.com/TomasJank/loopbreaker) — identical-call stall + near-identical jitter detectors (threshold ≈ 3).
- Harness writeups (TrueFoundry, Authon, Ralph): identical `(tool, args)` breakers are table stakes; soft “don’t loop” prose loses to the model’s re-decide habit.

What works:

1. Identical `(tool, args)` circuit breaker — omfx `doom_loop`.
2. Semantic / streak detection beyond identical args — explore-only rounds + “get oriented” preambles (`orient_streak` → inject on the tool-result channel).
3. Loud harness messages on the next observation the model must read — not system-prompt wallpaper alone.
4. Optional phase/artifact gates for “go through the whole repo” (heavier product change).

## Sticky task list

Claude Code docs ([interactive mode](https://code.claude.com/docs/en/interactive-mode)): `Ctrl+T` toggles the task checklist **in the status area** (up to five items). Fullscreen TUI keeps the input box fixed while output scrolls ([fullscreen](https://code.claude.com/docs/en/fullscreen)).

omfx bug: `Transcript.pinned` was counted in `rowCount()`, so todos scrolled away with chat. Fix: paint open todos as `Footer.tasks` overlay chrome above the composer, shrink the scroll region by that height (same band as jump-to-bottom).
