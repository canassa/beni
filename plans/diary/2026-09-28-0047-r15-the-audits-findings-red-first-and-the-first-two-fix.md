## 2026-09-28 00:47 CEST — R15: the audit's findings, red first, and the first two fix slices

**What I did**

- Collected the four R15 audits (core, dispatch, orchestration, adversarial) and had one agent
  turn every finding into CK-135…CK-168: 22 behavioural ones with a red fixture or scenario in
  `tests/pending/`, 12 structural ones catalogued without (`071cc0b`).
- Saved the broad perf study as `plans/perf-study-2026-09-27.md` (`1bec73c`).
- Landed R15-fix-B (`7fdf8a2`, `34c3cd6`): the printer brackets any arrow body or statement
  whose leftmost printed token is `{` (CK-138); shared evidence is judged once per term and the
  dispatch dump prints a shared term once as `#n` (CK-136, 48 s → 5 ms); one emit specifier
  table per importer depth (−10 % cycles, −54 % page faults, output byte-identical).
- Landed R15-fix-A (`763b7c8`): the plain-method memo is keyed by every input of its verdict,
  type included (CK-137, the unsound one); a `poisoned` wanted state for rejections against
  `err` (CK-141); arity mismatch and alias self-expansion build `err` (CK-139, CK-140);
  explicit-stack `orderWalk` (CK-135); derived-row templates publish through the one
  `Publisher` (CK-142).
- The generated cross-language benchmark finished a first full run (uncommitted, awaiting a
  fairness review and a quiet-machine rerun). A read-only reviewer is on both fix slices.

**What I learned**

- The one unsound finding was a memo key that omitted an input of the verdict it cached. When
  a memo is added, its key should be "everything the computation reads", reviewed as such.
- Parallel fix agents in worktrees plus a separately built baseline binary proved
  fixture-first without the shared stash stack, which is unsafe across worktrees.
- A usage limit killed three agents mid-slice; SendMessage resumed each from its transcript
  with nothing lost.
