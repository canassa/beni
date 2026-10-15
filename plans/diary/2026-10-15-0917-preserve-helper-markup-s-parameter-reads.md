## 2026-10-15 09:17 CEST — Preserve helper markup's parameter reads

**What I did**

Specified parameterised helper templates and independent visit verification in
browser-direct.md/write-sets.md before implementing them. The general lowering
retains parameter/capture reads through imported/nested helpers, different call
sites, choices, keyed/positional and mapped rows, component children and root
local derivations. Added explicit value/list fallbacks and the consumer-plan
artifact; no Conduit-specific compiler/runtime path. Added paired/fuzz Template
fixtures and four deliberate-corruption probes for the corpus-wide invariant.
Fixed the red-first findings from those attempts: lost choice/path reads,
overlapping row entries, mapped row scopes, identical-block fallback bypass,
component child paths, and volatile host arguments. Preserved collection path
identity while retaining deferred control reads.

Re-recorded run hashes with zorg; standard and LLVM gates pass 1,301 tests,
skip 15 and hit only the two known macOS case-folding failures, untouched.
New composition cases pass paired behavior/value fuzz in happy-dom and Chrome;
a final List Html case pins its declared structural fallback and is included
in the final gates/Chrome runs. No new budget is used: the owner approved a
5,300M Tour fuzz grant, but the hash-recorded gate fits the existing limit.

Rebuilt Conduit with the exact research-94 compiler and the new one, recorded
actual versus independent predicted group entries on all 62 dispatches, and
ran a balanced 15-page Chrome before/after/tea timing batch. Research 95 and
the dated raw artifacts retain all results and limitations. Research 94 and
all earlier diary entries remain intact. The PR stays draft and must not merge.

**What I learned**

Criterion 7 no longer fires: every dispatch matches its predicted visits,
including zero for all five empty-write Internal handlers, and patchAll is
exactly the nine ChangedUrl dispatches. Conduit's repaired choice read facts
are 782 pairs/114 groups, with message writes unchanged. That precision is
not a performance win by itself: direct grows 32,411 → 37,908 B brotli and
its feed/favorite/editor medians worsen to 0.400/0.360/0.380 ms versus old
direct 0.380/0.330/0.365 and tea 0.305/0.270/0.340 in the same batch. Context
capture, input preparation and selection lookup/construction remain outside
the selected groups; their counts are recorded, not tuned away. The empty
floor stays 327 B. Earlier S0 tripwires and the second full V3 campaign remain
open. List Html has precise known helper-hole masks but still general value
reconciliation and uncached value-root selection; the report states that cost.
