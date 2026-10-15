## 2026-09-23 21:39 CEST — row 72 review: exact commit provenance, capabilities final for early groups

**What I did**

- A read-only review found three defects in the row 72 fix, each reproduced
  with the installed binary. Fixed all three, one fixture each, every one red
  on the previous-round binary and green now.
- HIGH, a regression: the `committed_method_from` watermark skipped every
  constraint at or above it, and a commit can merge two callers' FOLDED
  constraints (`x < x`, `y < y` in a `let`) into a fresh set before that set
  meets `Int` (`Trip.eq : Trip a a a, …` at `Trip x y Int`). Rule U3 skipped
  the callers' set and nothing answered it: INTERNAL ERROR "I cannot tell what
  this call dispatches to". Replaced the watermark with exact provenance:
  `committed_copy` is the range the copy's instantiation created, and `adopt`
  records a rebuild as copy-owned only when every source is. A join with a
  caller constraint keeps its obligation. Fixture
  `run/DerivedEqCommitKeepsCallerConstraints/` (tuple and record shapes).
- MEDIUM and LOW, one cause: groups checked early for an unannotated
  `pub eq`/`pub compare` read `Types.settleDispatchCapabilities`' syntactic
  first cut. It descends into a parameter with an arbitrary requirement
  (valid `W (Holder Keyed)` refused) and ignores a specialised receiver
  (`L (Holder String)` accepted, then an INTERNAL ERROR about too few derived
  parts). `Check.zig` now runs Solve's `settleOrdinaryCapabilities` before the
  early groups too, and again after they publish their schemes. Fixtures
  `run/DerivedEqInPriorityGroup/` and
  `check/bad/PriorityGroupSpecializedPayloadEq/`.
- Corrected queue row 73: after row 72 its reproducer, and the `R.eq` where
  `a.compare` variant, are refused as `not_equatable`. They used to crash or
  print a wrong `False`. What is left is a capability gap. Recorded row 75: an
  `==` on a module's own type, inside another early group, runs before that
  type's unannotated `pub eq` has a scheme. Its site is `err` with no
  diagnostic and it emits `undefined`. Pre-existing on 875f623 and not fixed.
- Extended static-dispatch §6.3.1 step 4 with both rules. Gates: 468/468 unit,
  288/288 black-box (33/33 steps), fmt-check green. Nothing committed.

**What I learned**

- "Skip what the commit created" has to be computed per constraint through
  every rebuild (`adopt` is the one choke point all rebuilds share). An index
  watermark conflates the copy's constraints with callers' constraints that a
  rebuild merely moved.
- A per-module fact that an early phase reads must already be final by then,
  or visibly undecided. A cheap first approximation that a later pass refines
  is wrong in both directions for whoever reads it in between.
- `p1_tuple` (`Pair.eq` where `a.compare` under a tuple shape) is now
  `not_implemented`, the §7.1 gap for an evidence-taking `ext` in a part
  position, where 875f623 said `not_equatable`. Both refuse the program, and
  the INTERNAL ERROR it also produced is gone.
