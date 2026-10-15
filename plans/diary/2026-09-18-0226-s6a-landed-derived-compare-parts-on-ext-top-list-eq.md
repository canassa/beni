## 2026-09-18 02:26 CEST — S6a landed: derived `compare`, parts on `ext`/`top`, `List.eq`

**What I did**

- **S6a** (`fe3bdfa`). Derived `compare` bodies for every shape, `$$order`
  tables in declaration order emitted ahead of all functions, code-point
  comparators callable from inside a body. §7.1 amended: `top`/`ext` targets
  carry a parts range, filled when nested in a shape and empty at a call site,
  which is what lets `core/List.beni` own `pub foreign eq … where a.eq` and
  retires the A.51 bridge for lists. `Basics` now emits `Order`'s and
  `Never`'s rows. The reviewer found no blocking defect; two must-fix items
  were a latent `Bool`-into-`Order` fallback in value position and evidence
  slots of one instruction all numbered `1`, masked by a stable sort. A.64–A.68.
- Two checker mechanisms were added along the way and are worth knowing:
  `settleUndetermined` (A.66) gives an evidence slot nothing ever pinned —
  `[] == []` — the number/equatable bridge after promotion, keyed on the
  promoted list rather than rank; and a per-instruction evidence cursor
  (A.68) threaded through instantiation.
- Split S6 at a cleaner seam than the plan's row: S6a is the emitter side and
  landed green on its own; S6b is the core rewrite plus the C1 corpus and
  measurements, one commit. The brief for both is in `/tmp/s6-brief.md` and
  will be folded into `plans/` when S6b lands.
- **In flight before S6b:** the cursor exposed a pre-existing drain-order
  defect — a call with two constrained slots that each nest gets breadth-first
  site numbering, so `pair [[1]] [[2]]` under `where a.eq, b.eq` emits a
  four-deep evidence tree for `a` and none for `b`, exit 0. Being fixed at the
  drain, with a `run/` fixture that executes the repro.

**What I learned**

- **A stable sort can hide a broken key for a whole milestone.** The
  `(inst, evidence_index)` key had duplicates since S3; output was right only
  because `std.sort.block` is stable and insertion happened to be pre-order.
  The dump showing `1 1 1 1` was the tell, and nobody had a fixture with a
  nested constrained element until `List` got its own `eq`.
- **The value position and the body position must refuse the same things.**
  Twice now (S5's `partValue`, S6a's `derivedValue`) the body-side wall was
  right and the value-side fell through to `Basics.eq`. Any new wall goes in
  both, and the review checklist asks for it by name.
- **Pins are not proofs.** `ConstrainedMutualRecursion` and `ErrParts` both
  pass on the base commit; the headers now say so. A fixture that cannot fail
  first is still worth having, but it must not be cited as evidence.
