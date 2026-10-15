## 2026-09-25 — R4b: the new checker's foundation

**What I did**

- The first slice of the new checker, `src/check2/`, written from the ground up to
  `checker-v2.md`: a type store read only through `Walk` (two named successor sets), `Unify` that
  merges and never resolves or reports, frames with iterative rank adjustment and quantification,
  the annotation generality check, occurs at binders, one publication routine, one emit path with
  failure bits set by errors only. About 4 400 lines in 16 files, none over 525.
- v2 checks every root module that needs no dispatch and no obligation, now including modules
  that declare a `type` (my decision after review: their derived rows publish as `unchecked`,
  and only a `--library` build is refused, naming R8a); anything else reports `not_implemented`
  naming its slice. `test-v2`: 331 fixtures green under v2, all 313 of the subset, byte-identical
  JavaScript to v1 on the 51 green `run/`/`emit/app` programs. 20 pending fixtures claimed,
  among them CK-01, CK-04, CK-07, CK-13, CK-57 and two v1 defects R4b found: CK-90 (a `let`
  pattern binding outside its group's edges, accepted ill-typed) and CK-91 (v1's solver guard
  silently dropped constraints past ~4 200 `let` bindings).
- Two reviews. The structural one found a six-line program that hung v2 (unification recursing
  through cycles, exponentially through records); the adversarial one found the same root
  reporting infinite types as "nested 4 200 levels deep" and rejecting a valid program. `Unify`
  is now coinductive (a pair met again on the stack is assumed equal), so cyclic graphs
  terminate and unify; §7.3 records why not link-first. Also: silent defaults became `internal`,
  v2's last imports of v1's `Constrain`/`Solve` moved to shared files with a test refusing new
  ones, I2 restated and grep-tested, cycle reports in field-name order.
- CK-92, found by the adversarial review and shared with v1: a two-line program made the
  mismatch printer write 300 MB. Fixed in the shared `Render` with a per-message node budget.
  New: CK-93 (growing `let` chains quadratic) → R6a; CK-94 (`number` prints as `a`) → R13; CK-95
  (BIR lowering quadratic in a `let`'s size) → R12.
- Bench: v2 0.94× v1 on a generated 131 000-line dispatch-free corpus. Gates and all four other
  steps green.

**What I learned**

- The adversarial reviewer found no unsoundness in the new core, the first time a review of this
  checker has come back without one. The design reviews paid off; the bugs left were at the edges
  of the design (cycles the fallback lets live), not inside it.
- Two reviewers with different briefs (structure vs adversarial) found the same root cause from
  two sides, which made the fix obvious. Worth keeping for the big slices.
