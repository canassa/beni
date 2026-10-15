## 2026-09-23 21:01 CEST — row 72 finished: no second obligation for a committed custom method

**What I did**

- Picked up the half-landed row 72 fix (derived wrapper equality honours a
  payload type's public `eq`/`compare`). The one regression left was
  `TwoSlotsNested` (dispatch dump and run build): two extra evidence arguments
  and an INTERNAL ERROR "The hidden arguments of this call do not add up".
- Root cause: after the speculative applicability probe accepts a custom method
  inside a derived target, `commit{Local,Imported}MethodApplication` repeats the
  unification on the real store so a specialised receiver (`Holder Int`) narrows
  the caller. That commit registered the copy's constraints as obligations a
  second time (first via `registerInstantiated`, then through Rule U3's
  `deferConstraints`), and `siteOrigins` invented free child slots for the
  site-less copy — evidence the part tree from `ownValueParts`/
  `importedValueParts` already supplies.
- The previous agent's unbuilt fix returned early from `deferConstraints` for the
  whole commit. That also dropped the CALLER's constraints whenever a caller flex
  met the copy's structure. Narrowed it: `Solver.committed_method_from` holds the
  constraint table length before the copy, and only indices at or above it are
  skipped. Probed with a caller flex carrying `left.label ()` beside a
  `Holder Key`-specialised `==`, in both orders, plus `left.bogus ()`: interface
  `Key, Key -> ( String, Bool )`, correct JS, and `unknown_method` still reported.
- Documented the rule in static-dispatch §6.3.1 step 4 and marked queue row 72
  done. Rows 73/74 left unfixed as recorded.
- Gates: 468/468 unit, 288/288 black-box (33/33 steps), fmt-check green. Red
  proof: reversed `git diff -- src`, rebuilt; `DerivedEqThroughCustom` (16
  diagnostics) and `DerivedEqLocalCustom` (2) red, both inference fixtures fail
  with `not_equatable` at the definition's `==`; the negative fixtures and
  `DerivedEqWithArbitraryConstraint` are controls that pass either way.
  Reapplied; the src diff hash matches byte for byte.

**What I learned**

- A speculative check followed by a committing re-unification must not
  re-register what the check already accounted for, but the filter has to be by
  PROVENANCE (constraint index minted by the copy), not by phase: caller
  constraints can meet the copy's structure in the same unification.
- A caller flex's own method constraint already has a live obligation from its
  call site, so the probe above could not tell the broad suppression from the
  narrow one; the narrowing is justified by the invariant, not by a red test.
