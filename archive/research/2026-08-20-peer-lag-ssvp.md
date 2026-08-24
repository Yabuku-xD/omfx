# Peer lag/lead: the paper, not a homemade seq

**Date:** 2026-08-20
**Question:** peers can be 2–3 steps behind or ahead of each other. What is the published mechanism? Do not invent a step-counter.
**Status:** implemented — `src/core/ssvp.zig`, called from `agent.zig` (`ssvp.summary`, `ssvp.adopt`).
CDS is a **lexical** proxy (cosine over token bags), not the paper's embedding of a
3-sentence summary; see `docs/2026-08-21-bug-audit.md` O-2. Tau = 0.25 is the paper's
calibrated threshold.

---

## The paper

**Carson Rodrigues, *Hallucination as Context Drift: Synchronization Protocols for Multi-Agent LLM Systems*, arXiv:2606.21666, 19 Jun 2026.**

HTML: https://arxiv.org/html/2606.21666v1
PDF: https://arxiv.org/pdf/2606.21666

The failure is **temporal context drift**: agents operate with information from different timestamps; one agent’s “current” is another’s stale cache. Same for spatial (different world beliefs) and task (different histories of what was decided). Hallucination is the *symptom*. The cause is mismatched shared state.

The mechanism is **CDS + SSVP**, not “rebase every N turns.”

---

## Mechanism (from the paper)

### 1. Context Divergence Score (CDS)

Each agent `i` at time `t` holds a compressed context vector `c_i^t` = embedding of a 3-sentence summary of (spatial state || task history || goals).

```
CDS(i, j, t) = 1 - cosine(c_i^t, c_j^t)
```

System-level CDS is the mean over pairs. Calibrated threshold: **τ = 0.25** (false-positive 1.1% on their no-sync distribution; 0.22 → 5.6% FP; 0.28 → 0%).

CDS is **prescriptive, not diagnostic**. In no-sync, max CDS vs hallucination rate correlates at r = −0.03. Low CDS with full-broadcast coexists with the *highest* hallucination, because agents converged on the *wrong* shared city. CDS tells you *when* to sync, not whether you already hallucinated.

### 2. Shared State Verification Protocol (SSVP)

Algorithm 1, section 3.3:

1. Agents reason locally.
2. On interval `Δt` or a task-critical event, each agent emits a **ContextSummary** (≤3 sentences: spatial, history, goals) and broadcasts the summary only.
3. Compute pairwise CDS. If `CDS_sys > τ`:
   - pause joint reasoning
   - high-drift pairs exchange **full** context
   - **ContextMerge**: each agent is prompted to name contradictions and pick the more authoritative source given timestamps and information quality. **Do not silent-overwrite.**
   - re-embed, resume.
4. If CDS ≤ τ, keep going. Transient lag of 2–3 steps is allowed.

ContextSummary prompt: *“Summarize your current spatial context, task history, and active goals in 3 sentences or fewer.”*

ContextMerge prompt: *“Identify any beliefs you hold that directly contradict the incoming context. State which source is more likely authoritative given the timestamps and information quality involved.”*

### 3. The result that forbids homemade every-N-step rebase

Travel domain, n=30, Claude Haiku, 8 scenarios, 3 agents with injected mismatches (stale weather, wrong airport, truncated schedule):

| Condition | Hallucination rate | Task coherence | API calls |
| --- | --- | --- | --- |
| No-sync | 0.492 | 0.342 | 18 |
| **SSVP** | **0.463** | **0.350** | **53** |
| Full-broadcast every step | **0.658** (+34% vs no-sync) | 0.229 | 126 |

Full-broadcast **increases** hallucination (p=0.0022, d=1.18). Booking’s wrong city (Lisbon vs Barcelona) infects everyone. SSVP surfaces the conflict at step 2 in all 30 trials, agents adjudicate to Barcelona, 58% fewer API calls than full-broadcast.

Contamination **does not** replicate in software sprint planning (orthogonal mismatches). Taxonomy from §6.3: **high risk** when one fact cascades (destination → airport → weather → recs); **low risk** when agent contexts are orthogonal. SSVP is the conservative default for both.

SSVP vs no-sync HR drop is modest and **not significant** at n=30 (p=0.257, d=0.30). The load-bearing finding is: **indiscriminate sync is harmful; threshold-gated sync avoids the harm.**

---

## What “2–3 steps behind/ahead” is, in paper language

| Symptom in omfx | Paper name | What the paper does |
| --- | --- | --- |
| Peer missed the last 2–3 board notes | Temporal context drift (Rodrigues §1) | Let it drift until CDS > τ; then ContextMerge with timestamps |
| Peer already wrote 2–3 notes the others have not read | Same, plus dirty-read of tentative state (MemTX) | Tentative writes stay invisible until commit |
| Peer posts a FACT that another peer already superseded | Stale late write (MemTX §3.2) | Abort the late write; authority never overrides temporal precedence |
| Peer still believes a fact that later evidence quietly killed | Implicit conflict (STALE) | State resolution + write-time revision, not last-writer-wins |
| Navigator found the fix, planner was told something else | MAST FM-2.6 inter-agent misalignment | Dedicated sync protocol, not more chat |

A **seq counter with `drift_after=2`** is none of these. It is closer to full-broadcast on a timer: it forces a rebase even when CDS is low, and it can propagate a wrong FACT because it never asks “is this more authoritative?”

---

## Adjacent papers (do not implement these as the first cut)

**MemTX** — Li et al., *Transactional Belief Commit for Stateful Agent Memory*, arXiv:2607.23929, Jul 2026.
https://arxiv.org/html/2607.23929v2

This is the paper if the problem is **writes arriving out of order**, not just “beliefs drifted.”

- Each record has a **validity interval vs a logical clock**.
- Transactions open a **snapshot**. Staged writes are **invisible** to others at committed-read isolation.
- Commit check 3: *“A candidate whose rival committed after the snapshot is a stale late write and aborts before any authority comparison, so authority never overrides temporal precedence.”*
- Irreversible tools (write/edit/bash) gated until beliefs are committed.
- Retract → cascade-repair derived notes.
- Machine-checked on 5.5M protocol states. Zero downstream harm vs eight baselines.
- Open failure they document: an agent that **retries in a fresh transaction** after abort can make the late write no longer “late,” and adjudication falls back to authority. Transcription without declaring provenance also escapes.

Too heavy for omfx’s first cut. Keep as the write-protocol if SSVP-lite is not enough.

**STALE** — Chao et al., *Can LLM Agents Know When Their Memories Are No Longer Valid?*, arXiv:2605.06527, May 2026.
https://arxiv.org/abs/2605.06527

Implicit conflict: later observation invalidates earlier memory **without explicit negation**. Best model 55.2% overall. Retrieval of the update ≠ acting on it. CUPMem baseline: structured write-time consolidation + propagation-aware search.

**DeLM** — Mao & Mirhoseini, *Decentralized Multi-Agent Systems with Shared Context*, arXiv:2606.10662, Jun 2026.
https://arxiv.org/html/2606.10662v1

This is why omfx has a **board**, not P2P chat. Agents talk through admitted FACT/FAIL/PATH gists. Admission-time verify. Compact share, not raw traces. SWE-bench Verified: 77.4% pass@4, ~50% cost vs strongest baseline. Ablation: removing verification drops LongBench-v2 from 60.1% to 55.2%. DeLM does **not** solve lag/lead; it assumes admitted gists are already true. Pair with SSVP for *when* to pull the board, and MemTX for *whether* a late FACT may land.

**MAST** — Cemri et al., *Why Do Multi-Agent LLM Systems Fail?*, arXiv:2503.13657, NeurIPS 2025.
https://arxiv.org/abs/2503.13657

14 failure modes, 1600+ traces. Inter-agent misalignment is a distinct category from model error. Rodrigues cites this as incomplete without a sync protocol.

**Agent Drift** — Rath, arXiv:2601.04170, Jan 2026.
https://arxiv.org/html/2601.04170v1

Long-run semantic / coordination / behavioral drift. ASI composite, τ=0.75 over windows. Mitigations: episodic memory consolidation, drift-aware routing, adaptive behavioral anchoring. Simulation-heavy; complementary to Rodrigues (online pairwise CDS vs post-hoc 12-dim ASI). Architecture note: two-level (router + specialists) more stable than flat P2P or 3+ levels. Explicit memory beats conversation-only.

**Drift No More** — Dongre et al., arXiv:2510.07777.
https://arxiv.org/abs/2510.07777

Drift as turn-wise KL to a goal-consistent reference. Converges to a **bounded equilibrium**, not runaway decay. Reminder interventions reset toward lower divergence. Rodrigues: SSVP’s merge is that intervention.

**Meiklejohn**, *Multi-Agent Systems Have a Distributed Systems Problem*, 30 Mar 2026.
https://christophermeiklejohn.com/ai/agents/distributed/zabriskie/2026/03/30/multi-agent-systems-have-a-distributed-systems-problem.html

Stale reads, lost updates, no happened-before, every LLM is a potential Byzantine replica. Version vectors / CRDTs / crash-recovery. Not an experiment; the distributed-systems vocabulary Rodrigues and MemTX operationalize.

**Mieczkowski et al.**, *Language Model Teams as Distributed Systems*, arXiv:2603.12229, Mar 2026.
https://arxiv.org/abs/2603.12229

Position: evaluate LLM teams with distributed-systems primitives, not trial-and-error org charts.

---

## Mapping onto omfx as it stands (no code)

What exists:

- `peer` is a full-capability teammate, depth 1.
- `board` is DeLM-lite: FACT/FAIL/PATH into `{workspace}/.omfx/board.jsonl`, compact skips `Note ` lines.
- There is leftover homemade seq/drift counting in `board.zig` from a stopped attempt. That is **not** SSVP. Do not wire it.

What the papers say to do instead, if later asked to implement (smallest cut):

1. On peer start and after each board post, embed a 3-sentence ContextSummary (or reuse the FACT line itself as the summary).
2. CDS = 1 − cosine against the last summary the *other* agent used.
3. If CDS ≤ 0.25, do nothing. 2–3 steps of lag is the intended operating region.
4. If CDS > 0.25, inject a ContextMerge turn: contradictions + timestamps + which source is authoritative. Pause writes until merge returns.
5. Never full-broadcast the whole board into every peer prompt on every turn.

Do **not** start with MemTX snapshots unless SSVP-lite still loses FACT races on write.

---

## Caveats (from Rodrigues §6.2)

- 384-d MiniLM may miss subtle divergence.
- ContextMerge can pick the wrong side when both sources look equally authoritative (their injected mismatches were unambiguous; 0/30 adopted the error).
- n=3 agents. MAST: failures grow nonlinearly with count.
- Travel contamination is the scary case; software planning was already low-HR.
- SSVP vs no-sync is **not** a slam-dunk accuracy win. The win is **not poisoning the team**.

---

## Sources

1. Rodrigues, arXiv:2606.21666 — CDS, SSVP, ContextMerge, contamination +34%.
2. Li et al., arXiv:2607.23929 — MemTX stale late writes, logical clock, action gating.
3. Chao et al., arXiv:2605.06527 — STALE implicit conflict.
4. Mao & Mirhoseini, arXiv:2606.10662 — DeLM verified shared context.
5. Cemri et al., arXiv:2503.13657 — MAST.
6. Rath, arXiv:2601.04170 — Agent Drift / ASI.
7. Dongre et al., arXiv:2510.07777 — context equilibria.
8. Meiklejohn, 2026-03-30 — MAS as distributed systems.
9. Mieczkowski et al., arXiv:2603.12229 — LM teams as distributed systems.
