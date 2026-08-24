# Gates: omfx planning + landscape research

Scope: Landscape comparison of 100+ coding-agent CLIs, plus a ce-plan for a minimal Zig+TypeScript Unix-like successor to vercel-labs/fx.

- [x] G1: Comparison doc lists 100+ distinct coding-agent CLIs/harnesses with sources
  CHECK: python3 -c "import re,pathlib; p=pathlib.Path('docs/research/2026-08-20-coding-agent-cli-landscape.md'); t=p.read_text(); ids=re.findall(r'^### C(\d+)\.', t, re.M); print(len(ids), min(int(x) for x in ids) if ids else 0, max(int(x) for x in ids) if ids else 0)"
  EXPECT: /1[0-9]{2,} /
  EVIDENCE: 127 1 127

- [x] G2: Comparison doc names harness gaps vs fx and vs the field
  CHECK: rg -n "What is missing|Harness gaps|Gap vs" docs/research/2026-08-20-coding-agent-cli-landscape.md | head
  EXPECT: /Gap/
  EVIDENCE: headings "What is missing", "Harness gaps", "Gap vs fx", "Gap vs Pi"

- [x] G3: Implementation plan exists at docs/plans/2026-08-20-001-feat-unix-coding-agent-plan.md
  CHECK: test -f docs/plans/2026-08-20-001-feat-unix-coding-agent-plan.md && echo PLAN_OK
  EXPECT: PLAN_OK
  EVIDENCE: PLAN_OK

- [x] G4: Plan pins Zig core + TypeScript embed surface and Unix-shell form factor
  CHECK: rg -n "Zig|TypeScript|Unix" docs/plans/2026-08-20-001-feat-unix-coding-agent-plan.md | head -20
  EXPECT: /Zig/
  EVIDENCE: title/summary and KTD1/KTD6 name Zig, TypeScript, Unix-shell

- [x] G5: Plan is greenfield (not a fork of vercel-labs/fx) and multi-provider
  CHECK: rg -n "greenfield|provider|not a fork" docs/plans/2026-08-20-001-feat-unix-coding-agent-plan.md | head
  EXPECT: /provider/
  EVIDENCE: R3 greenfield not a fork; R4-R5 providers; KTD3 first-class adapters
