## 2026-09-30 06:25 CEST — markup against Solid 1 and 2, sizes, sequences, effects steps 1–3

**What I did**
- Markup performance: Solid 1 joined the benchmark. The renderer now matches a keyed list's
  ends before its key map, skips helpers whose arguments are unchanged, recognises selectors,
  empties a parent on replace, mounts rows through their patch and inserts rows directly.
  beni beats Solid 2 on all nine operations and Solid 1 on all but remove (a `List.filter`
  cost in `update`).
- Size: `--release` compacts and renames hand-written JavaScript, drops unused exports and
  writes one scope-hoisted file; nullary constructors are shared constants. The benchmark app
  went 12.1 → 5.1 KB brotli (Solid 1 4.4, Solid 2 22.1); an empty page 7.0 → 1.2 KB.
- Correctness: a single-constructor `case` now evaluates its scrutinee; recursion under `::`
  compiles to a loop (stack overflows at 100 000 gone); `--release` keeps unread bindings
  that may be impure, so both builds print the same.
- Sequences: reports 38 §15–§17, 40, 42 measured adaptive arrays, one type vs two, array-first
  code, brotli-minimal siblings and reference counting in JavaScript. The owner's
  List-or-one-type decision is still open.
- Effects: the owner took the eight decisions; the checker infers impure/suspends, the sync
  check refuses suspending code at synchronous boundaries, and the fiber runtime spike
  (spawn/join/scope/bracket) beats Effect v4 on every measure taken.

**What I learned**
- Research claims about where time goes were wrong twice (the model half of remove/swap);
  timing update and render separately in the page settled it both times.
- Array types measured on cons-shaped code look bad; the owner's point that the code should
  change, not the data structure, changed the study's outcome.
- Cherry-picking agent branches with run-hash conflicts is safe only for hash files: a
  blanket "take theirs" once dropped a test from build_test.zig, which I restored by hand.
