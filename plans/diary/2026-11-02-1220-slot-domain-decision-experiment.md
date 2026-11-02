## 2026-11-02 12:20 CET — the slot-domain decision experiment

**What I did.**
- I ran the experiment of Astra's second review (§6) on dagon: a first-order typed-BIR slot evaluator behind
  `--ownership-slots`. It is on the scratch branch `exp-slot-domain`, over `89e320851`, with self-hosted Debug
  builds only.
- Its value analysis is new: slots, positions, selections, contracts, demands and its own holder query. It keeps
  v2's `Place`, `Groups` adapters, `Prepass` groups, `Ids.Account` and the lowering channel.
- I instrumented `Shape`, `KappaRead` and `Propagate`. The slot path makes 0 calls into them; v2 on the same
  module makes 605 664.
- The verdict is **PASS within the first-order scope**:
  - generic `removeMin` checks in 20 214 records with growth 0, and core's `Dict.removeMin` in 20 213;
  - `rebuild` beside the surviving subtrees is accepted, and every negative control refuses;
  - copy, plain and sanitised runs print the same output, and the unsafe variant traps;
  - the import round-trip and the reversed declaration order give the same verdicts;
  - copies are exactly linear, and payload fields are linear;
  - against master, 280 demand positions show 0 accept→refuse and 17 documented-safe refuse→accept.
- I wrote ownership-v2.md §8 Q8's summary. The report is `experiments/slot-domain/report.md` on the branch, and a
  copy is in `~/.cache/beni-agents/slot-exp/report.md`.

**What I learned.**
- Pairwise apartness facts are the wrong shape, for two reasons:
  - They are quadratic in fields.
  - They do not survive substitution: two distinct callee families can fold into one caller family.

  One *selection* per condition fixes both. It is a set of (parameter, slot) occurrences whose objects occur
  once among them, and a conjunction is a union. A rule is then needed for substitution: two distinct callee
  occurrences that reach one caller value by one literal route are distinct positions of it. That rule must not
  confuse two parameters handed one value, so routes are per parameter.
- `extend` names a join of several level paths (`B (List B) (List B)`) differently from the level paths that a
  closure walk names. Every slot set must go through `expandLevels`, or two names for one position look apart.
- A `⟲` replayed at a path that is not a first return must expand to the levels below. `extend` makes a path no
  type has; that is how `h2`'s duplicate got through.
- A pairwise check over leaves brought the fields quadratic back. Grouping by root, and indexing conflicts by
  (position, slot) through ancestry, made it linear.
- Open: callbacks and folds (the review's next checkpoint); deliveries instead of a re-walk per round (`rotate`
  is O(N²)); callee read footprints; the full ledger.
