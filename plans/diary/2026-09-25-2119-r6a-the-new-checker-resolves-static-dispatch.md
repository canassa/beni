## 2026-09-25 — R6a: the new checker resolves static dispatch

**What I did**

- v2 now types dispatching programs under `check`: `Evidence.zig` (wanteds, givens, answers,
  the canonical requirement order, each wanted paired with one `Flags.constraints` entry by
  position), `Resolve.zig` (the step by receiver root: attach to a flex, the `number` bridge for
  flex and rigid, the given or a precise `missing_where_constraint` on a rigid, lookup on a
  structure), and one derivability verdict in `Instances.zig`. `build` of a dispatching module is
  still refused (R6b); an own untyped method used early is R7's; own derived contexts R8a's.
- Claimed CK-02, 03, 09 (the dispatch half), 20, 21, 48, 100 (new: v1 left a method's result
  untied when the receiver was learned later) and 101 (new: v1 overflows its stack on alternating
  `eq`/`compare` cycles); 47 claims. `where` blocks byte-identical to v1 on 471 interfaces.
  Bench 1.02× v1 on a dispatch corpus.
- Three review rounds, as expected for the part v1 got most wrong. Round 1 structural: `==`
  accepted on a function-holding type because three functions answered "can T derive eq" and
  disagreed; a recursive walk that overflowed; a memo that shared one instantiation of a
  polymorphic method; evidence order left for R6b. Two of v1's six root causes were creeping
  back. Fixed structurally: one iterative `(node, method)` verdict, no shared instantiations,
  canonical order at creation, every silent drop now `internal`. Round 2 found the lineage rule's
  premise false (a `where` can constrain another parameter), rejecting valid code as an infinite
  type; §9.5 corrected and the rule replaced by a real cycle test plus the reporting budget. The
  harness now kills a crashing child at Zig's crash banner so crash signatures do not race.
- All seven steps green.

**What I learned**

- On this slice the reviewers mattered more than the tests: the unsound `==` was found by reading
  code, not by the adversarial probes, and the false-cycle rule came from a false sentence in the
  spec. A design premise needs a counterexample hunt as much as code does.
- The six-root-cause table was a useful acceptance check: asking the implementer to fill it in
  made the regressions in #2 and #4 visible as regressions, not local bugs.
