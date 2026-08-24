# Harness that improves from use

**Date:** 2026-08-20
**Question:** papers on CLIs that get better the more people use them. What can omfx do without leaving the empty cell (small Zig core, TS extensions, postcard prompt).
**Status:** implemented — `src/core/playbook.zig`, called from `agent.zig`
(`noteHarmful`, `noteVerified`, `catalog`) and `repl.zig`. Admission on a clean verify
requires board notes, so a solo session records nothing; see
`docs/2026-08-21-bug-audit.md` O-4.

---

## The split every paper makes

The **model** is frozen. The **harness** is prompts, skills, memory, tools, and control flow. Self-improvement in a CLI is almost never weight updates. It is writing durable artifacts from execution traces, then loading them next time.

Two capabilities are not the same (Lin et al., arXiv:2605.30621):

| Capability | What it is | Who is good at it |
| --- | --- | --- |
| Harness-updating | Produce useful persistent updates from traces | Flat across model size. Qwen3.5-9B ≈ Opus 4.6 |
| Harness-benefit | Actually follow those updates at task time | Mid-tier models gain most; weak fail to invoke; strong already know |

omfx implication: a cheap model can write the playbook. Spend the user’s model on the task. Train/prompt the task agent to *read* skills, not to author them.

---

## Papers that matter

### 1. ACE — evolving playbook, not a rewritten prompt

Zhang et al., *Agentic Context Engineering*, arXiv:2510.04618, ICLR 2026.
https://arxiv.org/abs/2510.04618

Loop: **Generator** (do the task) → **Reflector** (what worked / failed from execution feedback, no labels required) → **Curator** (incremental delta into a structured playbook).

Two failure modes of “just summarize the session into AGENTS.md”:

- **Brevity bias:** summaries drop the domain tricks.
- **Context collapse:** each rewrite erodes the last rewrite.

ACE keeps a growing item list, not one paragraph. Offline = system prompt / playbook. Online = agent memory. +10.6% on agents, +8.6% on finance. AppWorld: matches a production agent with a smaller model.

### 2. Self-Harness — diagnose, tiny patch, regression-test

Zhang et al., *Self-Harness: Harnesses That Improve Themselves*, arXiv:2606.09498.
https://arxiv.org/abs/2606.09498

Loop: **Weakness Mining** from traces → **Harness Proposal** (diverse but *minimal* edits) → **Proposal Validation** (accept only after regression). MiniMax M2.5 held-out 40.5% → 61.9%. Every model–benchmark pair improved both held-in and held-out.

Edits that survived were bottleneck-specific: artifact handling, patch verification, app-state retrieval. Not “smarter prompt.”

### 3. CODESKILL — trajectories become skills, bank stays small

Li et al., arXiv:2605.25430.
https://arxiv.org/abs/2605.25430

Coding traces → multi-granularity procedural skills → evolve on new/failed experience → add / merge / drop so the bank does not grow forever. +9.69 pass vs no-skill, +4.01 vs best memory baseline. EnvBench, SWE-Bench Verified, Terminal-Bench 2.

omfx already has the skill *format* (names in prompt, SKILL.md on demand). It does not *write* skills from traces.

### 4. SkillHone — keep the decision history

Li & Hu, arXiv:2606.08671.
https://arxiv.org/html/2606.08671v2

Don’t keep only the last SKILL.md. Keep diagnoses, rejected alternatives, evidence, outcomes. Later agents should not rediscover why a revision was thrown out.

### 5. MUSE-Autoskill — catalog routing + per-skill memory

arXiv:2605.27366.

Eager surface = name + description only (~5–10k tokens for 100 skills). Body loads after `read_skill`. Sibling `.memory.md` holds run-local lessons and is **not** shipped with the skill.

omfx `promptBlock` already lists names. It does not have per-skill memory or auto-construction.

### 6. SICA — agent edits its own code

Robeyns et al., *A Self-Improving Coding Agent*, arXiv:2504.15228.
https://arxiv.org/abs/2504.15228

The agent rewrites its own Python harness. +17–53% on a SWE-Bench Verified slice. That is a research loop, not a product default: it can bloat, break, or self-jailbreak.

### 7. HELIX / RHI / HASE — model–harness co-evolution

HELIX arXiv:2608.13951, RHI arXiv:2607.15524, HASE arXiv:2607.03935.

Harness traces become SFT/preference data for the *next* model, then the harness is rebuilt. Out of scope for a local CLI that does not train weights.

### 8. Continual Harness — online, no episode reset

Karten et al., arXiv:2605.09998.

Human-in-the-loop harness refinement first (Gemini Plays Pokémon), then the agent edits prompt / sub-agents / skills / memory *during* one long run. Prompt-optimizers need resets; this does not. For omfx: don’t wait for a “session end job.” Allow mid-session playbook appends from verify/FAIL.

---

## What omfx has today

| Surface | Now | Gap vs papers |
| --- | --- | --- |
| Prompt | Postcard, stable | ACE says do not rewrite it each session |
| AGENTS.md | Loaded as instructions | Human-authored; no curator |
| Skills | Names in prompt, SKILL.md if the model reads | No extraction from traces; no merge/drop |
| Memory | User prefs only (`save/list/clear`) | Not procedural; not from execution |
| Sessions | `last.jsonl` user + assistant text | No tool trace, no outcome label |
| Board | FACT/FAIL/PATH + SSVP | Per-task, not a durable playbook |
| Compact | 5 local layers | Summaries of *this* thread, not cross-session |
| Verify | diag after write | Unused as a skill-admission signal |

---

## What to do (ranked for omfx)

### Do now (one small loop, no Zig self-edit)

1. **Keep traces that can be judged.** Persist tool name, args hash, exit/verify, and whether the user continued or aborted. Sessions already exist; they currently drop tools.

2. **ACE playbook, not AGENTS.md rewrite.** File: `{workspace}/.omfx/playbook.jsonl` (or user-global `~/.omfx/playbook.jsonl`). Each line is an item: `helpful` / `harmful`, count, quote, source session. Curator **appends or bumps counts**. Never collapse to one summary. Inject a short catalog of the top-N items into the system prompt (names), unfold on `board read`-style pull.

3. **Admit skills from verified traces.** If a session ends with `verify` green and a repeated FAIL/FACT pattern, write a SKILL.md under `.omfx/skills/` (workspace) with name + description only in the postcard. Body on demand. Merge duplicates. Cap the bank (CodeSkill). Do not train RL.

4. **User signals as labels.** Permission deny, empty-line abort, “wrong”, undo, `/peers` retry = Reflector evidence. ACE works without ground truth if execution feedback exists; user pushback is the strongest feedback a CLI has.

5. **Cheap curator, user model for the task.** 2605.30621: don’t spend the session model on writing the playbook. Optional background pass after persist.

### Later

- SkillHone sidecar: `.omfx/skill-log.jsonl` of rejected skill drafts.
- Self-Harness *on skills and playbook only*: propose a one-line playbook edit, replay last failing session offline, keep if verify still green.
- Per-skill `.memory.md` (MUSE), not shipped.

### Do not

- Let omfx rewrite `src/*.zig` of itself (SICA). Extensions and playbook are the evolvable surface. Core stays a composition root.
- Full-rewrite AGENTS.md or the postcard after every session (ACE collapse).
- Weight SFT / HELIX. Not a CLI feature.
- Dump raw traces into the next prompt (contamination, cost, Rodrigues full-broadcast).

---

## Minimal loop (if implemented)

```
session ends
  -> if verify failed or user aborted: Reflector writes a harmful item
  -> if verify passed and pattern seen ≥2 times: Curator adds/merges a skill
  -> next chatOnce: postcard unchanged; playbook catalog (names) + skill names
  -> model reads SKILL.md / playbook item only when needed
```

Same shape as DeLM admission + ACE deltas + existing skill progressive disclosure.

---

## Sources

1. Zhang et al., arXiv:2510.04618 — ACE playbooks, brevity bias, context collapse.
2. Zhang et al., arXiv:2606.09498 — Self-Harness mine / propose / validate.
3. Li et al., arXiv:2605.25430 — CODESKILL trajectory → skill bank.
4. Li & Hu, arXiv:2606.08671 — SkillHone decision history.
5. MUSE-Autoskill, arXiv:2605.27366 — catalog routing, per-skill memory.
6. Lin et al., arXiv:2605.30621 — updating ≠ benefit; cheap evolver.
7. Robeyns et al., arXiv:2504.15228 — SICA self-edit (don’t do this in core).
8. Fan & Huang, arXiv:2608.13951 — HELIX model–harness co-evolution.
9. Karten et al., arXiv:2605.09998 — Continual Harness, online, no reset.
10. Lee et al., arXiv:2607.15524 — Recursive Harness Self-Improvement.
