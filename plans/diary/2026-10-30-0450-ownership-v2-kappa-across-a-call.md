## 2026-10-30 04:50 CET — Ownership v2: κ across a call (S3b slice 2b)

**What I did**

- Built the three parts of `ownership-v2.md` §2.11 *κ across a call*. Calls answer views, and a read
  below a re-rooted actual crosses into the actual's own snapshot where `eqOn` holds on its region.
  Reads below a summary position are incremental (memos per inner node, per radix node and per
  map-node pair). The conditions a call instantiates are lazy `inst` atoms, resolved at the
  readers.
- Made `kappaOf`, `dagKappa` and the view chain one explicit-stack machine. A 400-call chain read
  at its end now fits a 64 KiB stack; native recursion is never one frame per call (#1130).
- Took two decisions with the manager, both written into the spec. First, `base_epoch` moves only
  when a relevant node (a κ key or in `bases*` of one) gains a base. Second, `wholly` is decided
  per construction, so a yes never turns into a no.
- Pinned six counted families (`CallChainShare`), the cross-check fixture
  `CrossProjectedActual`, and unit tests of the new memos. The 2a guard's chain of joins moved to
  `scenario/CK-1214`.
- Measured the `apply` + read-off + publish share at 10/100/1 000 calls: flat or a log factor in
  every family, with no `base_epoch` move and no redo.

**What I learned**

- The 2a pick-chain guard measures the whole continuation, and 98% of it is Demands' resolve
  walking holders' view chains (#1214). Parts 1–3 could not make it flat.
- The spec's cost arguments assume one side of a pair is small or the region stays put. Three
  cases broke that:
  - crossing into a small actual (a literal) left the other actual's keys one-sided in `C`;
  - `region(a)` is new at every call, so it cannot be in a pair memo's key;
  - two independent chains made both sides of `aggMerge` large.
  Each one needed a memo keyed without the region or along both tries.
- One interned node becomes a hub that gains a base every call: `nothing`, the empty leaf, which
  `proj` returns past every missing child. Treating it as always tested is sound and ends the
  bumps.
- A green corpus run means nothing if the build failed and the old binary ran. One switch over
  `AtomKind` in Walk.zig is not compiled by the unit tests.
- `measure.sh`-style probes must not restore source files from an old commit: that silently
  erased a field I had added.
