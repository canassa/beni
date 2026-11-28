## 2026-11-16 16:40 CET — own3: an audit of every absence read as nothing

**What I did**

- Audited every site in `src/own3/` (and the `own2` code v3 calls) where a lookup that misses can become
  an empty answer: 498 sites, 449 proved empty, 49 assumed (research report 148, its table is the
  deliverable). Five forked readers took one part each and probed each assumed site with programs.
- Fixed six faults, each a program v3 accepted that read a list after an in-place write: casts through
  a type of no cell or of fewer places lost cells (`narrowed`), casts to a type with more places read
  nothing (`punned`, any location kind), a number read as a list through `Js.Value`, an operand location
  the call map cannot place (`otherReaches`'s `Loc.all`), and — found by the review — a value of no
  location read back through a type variable. A value whose type has no location now holds `outside`.
  Ten `run/` fixtures, each red on the base.
- Took the pessimistic answer at the latent sites (a part's location with no place in the whole, a
  markup hole that is a join, four worded-row corners), and added two safe-build checks:
  `Frame.checkPlaced` at every reader and `Contract.join`'s.
- New sweep `bench/ownership-sweeps/build-read.mjs` (1 050 programs).

**What I learned**

- The class is wider than reports 146 and 147 saw: "a value of a type with no location holds nothing"
  is a fact of the type that every cast breaks, in both directions. Seven sites the readers called
  proved rested on it; the sweep of the first fix and the review found them.
- A list write of no cell is not a safe place for the pessimistic answer: `FormValidation.andMap`
  writes `Invalid`'s list of a `Valid` construction. The fix belongs at the source of the absence.
- `checkPlaced`'s first version panicked on 95 roots, every one a reading below a type of no cell; the
  place graph's `holds` bits are the positive fact that tells those apart.
