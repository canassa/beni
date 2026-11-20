## 2026-11-20 21:55 CET — v3: List.length shallow, parts read apart, join answers

**What I did**

- Lane ref169, the fifth checker lane of v3's cells and fibers. First every sweep and the corpus
  under the four legs on the base (`12e5500d0e`): 56 sweeps, 111 020 programs, only the known
  `ListSanitiserTrieHolder`, `dom`/`tea` `ShowAndBranches` and `worded-bodies
  twice.unjudged-stored.live` trap. The `TIMEOUT plain` lines are programs whose plain run is
  exponential (`bounded-walk`'s DAGs, `TailModConsMerge`), the same on base and head.
- #2584: `List.length` is `borrowed shallow`. Two check tests pinned refusals of programs that are
  safe under that reading (`joinArg`, the generator's `twice`); they are accepted now, with live
  twins `joinArgLive` and `twiceLive` that read the elements. `run/LoanStoredLocal` is wholly
  accepted; `run/LoanStoredLocalLive`. Four `emit/` goldens change worker fingerprints only.
- #2588, a soundness fault on the base found while working on #2583: `SrcState.visit` keyed the
  answers in work by holder, location and entry, so the second arm of a join of lambdas read as the
  first one coming back and added no cell. Its answer held nothing of what the callee handed it
  (`run/AnswerOfJoinArmsLive` traps on the base; `SanitiserAltCodesRefused`'s `answersShared`,
  accepted on the base, is the same class). The key names the code and its captures.
- #2583: a read of a part of a root reads only the runs of the entries its path maps to
  (`entriesBelow`), not every entry of the root; a part with a location the layout does not name
  reads them all. Kernel §4.1. 13 writes of the 2 494 roots newly accepted, none newly refused;
  four `run/` fixtures wholly accepted; `run/CallAnswerPartsApart` and its live twin.
- #2582 and #2587 need rules beyond their text: recommendations in the issues, not built. Slice 5
  (`Deferred`/`Fiber` contents) not built: no real root needs it (the 10 refusals of the ledger
  and the 2 494 roots name no value taken out of a `Deferred` or a fiber).
- `cells.mjs` grew to 21 168 programs: a pair in the cell with one part read after a write of the
  other, a loan in a list read by `List.length` or through its element, and a write in the winning
  half of `Task.race`. `worded-bodies`' unproven row moved to a fold.
- Evidence: head sweeps 118 664 programs, four legs, the same four known traps and no other; 172
  programs refused → accepted, none accepted → refused; dumps of 2 494 roots, no accepted → refused
  but `answersShared`'s live write; ledger 309 of 319; mutant (a part reads no run) lets 64 live
  `cells.mjs` programs through, each TRAP; two adversarial reviewers, about 3 350 programs, no fault.

**What I learned**

- A pessimistic read can hide a hole elsewhere: reading every entry of a root covered for an empty
  run that the join's answer left. Make a read precise, then look at what the old reading was
  covering for, before trusting the precision.
- A dedupe key for "in work" must name everything that makes two visits different: two arms of a
  join share the holder and the location.
- Under a full sweep at 22 jobs, `check_test`'s blind-round tests pass their 10 s budgets only
  sometimes: run gates and timing with nothing else on the machine.
