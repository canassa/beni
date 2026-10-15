## 2026-10-09 00:45 CEST — The direct browser platform: the design and the rewritten plan

**What I did**
- Wrote `docs/design/browser-direct.md`, the first-principles design of a second browser platform,
  `browser-direct` (the brief's `browser-next`, renamed because "direct" names the design), to be
  built beside `browser`/`browser-tea` and measured against it, P3, vanilla and Solid 1. Each piece
  is organised around "what does the vanilla author write, is the fact known at compile time, what
  does the step cost" (§2, the cost table §3). The shape: one HTML string per mount with
  never-written literals baked; module-level node handles and slots for a unique markup site; one
  handler per message key (`write-sets.md` §4.4) that inlines the key's `update` arm, takes the
  payload as parameters, and writes directly the groups, rows and branches its write set reaches,
  each write guarded by a leaf compare; direct listeners outside lists and one delegated listener
  per list parent; edit scripts per edit tag and one keyed reconciler shipped only for a list some
  key replaces or permutes; `Html.map` over a constructor composed at compile time; a dispatcher
  only when a message is a value; the edited set, the defect guard and the teardown reused; the
  model immutable, with a building-loop rule to keep accumulator lists plain and in-place update
  (S7) specified with an ownership condition and two rules that keep identity compares apart from
  in-place writes. §12 is the harness (same source on both platforms; shared vs copied code), §13
  the targets and kill criteria per page class with the ways it could fail like P3, Svelte 3, Imba
  or Million, §14 the slices S0–S8, §15 six owner questions, §16 the limits in plain words.
- Rewrote `plans/compile-away.md` around it: §1's criteria kept with a column for the design's
  expected landing, §2's rules amended (no render on the direct platform; every byte of runtime
  justifies itself), every R/M/B/V item marked survives/merges/dropped (R1 dropped after the
  owner's withdrawal; R3–R6, M1, M3, M4 merge into slices; R2, M2, B1, V2, V3 survive; V1 done),
  §5 the new order, §6 the 2026-10-08 decisions added, §7 the slice table.
- Gates green (docs only).

**What I learned**
- The brief's list was a good adversary: writing "what does vanilla do here" for every piece
  removed P3's staging (vanilla writes in the handler; the burst win was 13 % at K = 1 000 and a
  microtask at K = 1), P3's instance objects for unique sites, P3's per-row message objects, and
  P3's reconciler-for-everything. What stayed is what vanilla also pays: a compare where the
  analysis says "possibly", delegation inside rows, a keyed match for a list rebuilt from data.
- A `For` over a filtered expression is the common TodoMVC shape, and it reaches the reconciler
  however exact the model list's edits are; the write set tags a list *path*, not a derived
  value. I had first written that TodoMVC ships no reconciler; reading its `view` corrected it.
- In-place update's real blocker was never the renderer holding the old model — on a handler
  platform nothing holds it — but aliasing: `Same(q)` placed at `p` makes p and q one object.
  The write-set interpreter already sees every placement, so "owned" is a property it can
  compute, and the two rules (slots hold leaves; row items are never owned) keep it sound.
- Today's markup lowering interface is per root and has no notion of a program; the direct
  lowering needs the program (keys, arms, write sets), which is an additive interface version,
  not a second interface.
