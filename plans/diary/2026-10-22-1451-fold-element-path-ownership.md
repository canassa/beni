## 2026-10-22 14:51 CEST — Fold element path ownership

**What I did**

Fixed #720 through #737: a list-key table fold now keeps ownership of its fresh value-list arrays independently of shared comparison keys. Added the dated specification amendment first, then projection-aware construction conditions, callback-supply serialization and recursive guard folding. Rebased over the recursive function-result work (#731); the ownership cache format is now 23. Kept the exact reduction, String-key and explicit-call controls, cache roundtrip, runtime output, and negative alias/later-write/opaque-row fixtures. Existing ownership verdicts, counts and diagnostic goldens did not change. Full self-hosted gates passed on dagon.

The owner explicitly authorized increasing the affected budgets after normal gates reported overruns. Recorded specific grants with about 10% headroom and #732 to retire them. No caps, weakened assertions, Tea layout changes, local Zig, LLVM or separate measurements. The Tea-table implementation can resume from its preserved evidence archive.

**What I learned**

A separation guard over an opaque tuple must remain a projection rule: move the selected side and retain every array held by the other side. Treating it as one whole-element boolean either loses safe sibling ownership or misses duplicated value lists. These annotations describe a value, not another allocation or callable alternative. Their recursive growth must use the same variable boundary as the data paths, while a known sharing fact on a concrete array must retain its exactness.

The direct source review had no blocking findings. Its join-direction question is answered: a greater guard distance folds at an earlier boundary and retains both sources' possible aliases. I also fixed its overflow note by storing the full path-distance range in transient marks, with a regression test at the old byte boundary and `maxInt(u32)`.
