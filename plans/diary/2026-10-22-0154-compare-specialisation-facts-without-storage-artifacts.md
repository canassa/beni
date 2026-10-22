## 2026-10-22 01:54 CEST — Compare specialisation facts without storage artifacts

**What I did**

Coordinated with #649 and claimed #657/#658. Worked only in the isolated
`fix-pts-order` dagon worktree from current origin/master; copied the original
ShapeRecordNames fixtures without changing the paused #653 worktree. No local
Zig command, LLVM flag, size measurement or speed measurement was used.

Reproduced #658 on master and on `d832ea899` (before #650) and `f647ca294`
(before sweep removal). Traced and recorded the causes in the issues before
fixing them. The comparison mistook reordered mapped site sets, empty sparse
property entries, and raw property values already subsumed by `any` for unequal
facts. No transfer or consumer changed. Added a dated backend §9 amendment,
a one-field schema/record-update run fixture, and comparison rejection tests.
With the source fix set aside the reduced fixture panics; restored it prints 3.

The entire corpus passed with the points-to check temporarily unbounded and
`-Dtest-budget=0`, including MapLambda and the three Conduit programs. Restored
the 1,500-node limit, recorded run hashes, and passed the unfiltered default
self-hosted `zig build gates`. Every existing recorded hash stayed identical.
Tracked a stale EnumCycleModule golden independently as #660: unchanged master
and patched compiler output trees are byte-identical, and only its old expected
text needed refreshing. Prepared one PR for the comparison fix and that refresh.

**What I learned**

A node-based site mapping is a bijection, not an order-preserving mapping. The
faulty top-valued positional comparison dates to `4a9177bf0` on October 19.
Sparse property storage is not the fact: absence means empty defaults, and a
per-key written bit under `any_written` adds nothing. A field read also includes
`any`; when that cell is top, escaped sites retained before a source escaped
add nothing to its effective value. The check must still reject every changed
live site, initialisation/read flag and value bit not subsumed by top. These
reports did not establish a non-monotone points-to transfer.
