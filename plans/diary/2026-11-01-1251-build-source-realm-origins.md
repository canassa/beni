## 2026-11-01 12:51 CET — Build source realm origins

### What I did

Implemented RealmBuild/RealmValues and registered RealmBuildTest on exact combined7de. Source-owned scopes/value ports preserve actual local/imported provenance, deferred callable identity, static returns/captures and closed field selection. The compact32-bit field radix directory and iterative memo walk retain fixed-per-original-row bounds. Native seeds come downward from actual checked registry; function signatures/rungs never identify callable bodies. Blocked calls retain source/target witnesses and remain residual with no direct execution edge. No native lowering, public gate, ownership-v2 or source syntax changed. Part of #1295 and PR1304.

Thirteen actual checked-source semantic tests pass under the existing1000ms unit guard; the focused registered target is88/88 steps22/22 tests including9 infrastructure. A copied unit ELF independently reports15 passes:13 semantic+2 import roots,0 skips/failures/leaks/logged errors. Allocation-failure sweeps cover ordinary fields and native/blocked tables; results remain valid after the source Session is destroyed.

### What I learned

The first whole-core native unit finished its assertions but failed the actual CPU guard1088ms>1000. Root approved isolating the canonical generated native module in this pure hermetic builder test, retaining Source.source/addGenerated, full ordinary checking, Registry.install and every native assertion. The original source/ELF/log remain retained; this is no budget waiver. Equivalent actual full packaged CLI consumer/builder coverage remains mandatory, not covered by native-loader tests alone.

The consumer author found argument escape rows depended on source traversal order through a partially built coverage bit. An actual two-order Beni regression fails the original helper (expected1 escape, found0) and passes the correction: every original non-scalar argument retains an obligation absent formal-use/substitution proof, independently of target coverage. Formal Unit origins therefore remain conservative residual value obligations; no type-derived no-escape claim is guessed. Definite invocation and retention/escape are separate rows. The native whole-entry/EntryHost/launch and lowerability claims remain unavailable; consumer integration and parent review are still required.
