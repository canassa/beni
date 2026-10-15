## 2026-09-27 — R8c: performance and limits (and CK-122)

**What I did**

- CK-122: a `type alias` of a schema endpoint was read as a silent `err` by the shared alias
  reader, giving `internal` on `==`, a false refusal through a wrapper, and in both checkers
  `r + 1` on the alias checked. Fixed in `Types.Builder.aliasBody`; CK-126 (a private record
  schema reached through another module's `pub` alias) stays pending.
- Performance, each change measured: rank adjustment answering leaves at once and successors in
  the parent's frame, pool compaction, Unify's bounded pair scan and flex-flex fast path, P6 maps
  only with evidence. CK-93, 111, 112 and 114 fixed with `test-perf` scenarios (CK-111: 44 s →
  0.5 s). The CK-42 v2 twin resized so it measures.
- The two proof-keeping shortcuts (CK-93's stamps, CK-111's inherited proofs) were unsound: round
  1 found a cycle escaping the occurs check through an `err` overwrite; round 2 found two more
  holes, both through `err`, one accepting an infinite type with exit 0. Now one mechanism:
  acyclicity proofs in the shared `TypeStore`, voided on any write that could add an edge, with
  the broad `err` rule the reviewer verified (my choice over a narrower rule argued sufficient),
  and a Debug detector that re-walks from every trusted proof. 20 500 fuzzed programs: 0
  differences, 0 panics.
- Owner decision: CK-128 (derived `==` on deep data throws `RangeError`: a user linked list at
  ~8 900 cells) is fixed as Elm does, in R8d, with black-box tests.
- Bench: v2/v1 1.03× (plain) and ~1.055× (dispatch) in cycles; R8c's own 1.05× target missed by
  choice for the broad rule; R9's budget is 1.10×.

**What I learned**

- Performance shortcuts that keep a proof beyond its walk are where soundness breaks: three
  review rounds, three holes, each behind an argument for why a narrower condition sufficed. When
  a soundness argument has already failed twice, take the verified rule and pay the cost.
