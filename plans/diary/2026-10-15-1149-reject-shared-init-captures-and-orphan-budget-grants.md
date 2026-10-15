## 2026-10-15 11:49 CEST — Reject shared init captures and orphan budget grants

**What I did**

Rebased #116 onto master `134d24ab9`, including merged #124, and migrated its
three diary entries verbatim into the new directory format. Specified the dated
§22.2 capture correction before fixing entry disjointness: non-init fields keep
ordinary and helper-carried environments alive against runtime writes. The two
reported programs (a local literal and a private top-level seed) now refuse,
along with a helper-returned-view twin. Init-only captures and body allocations
remain accepted. Ownership blocks advance to 7. Both reported tests fail with
the fix set aside and pass restored.

Scoped init allocation advice to entry diagnostics, retained ordinary function /
copy advice and the still-used append hint, and goldened both scopes plus a
record list-field copy. Added inferred-evidence/two-type, return-dispatch identity,
recursive, coarse and width-limit fixtures. Added complete budget-file inventory
validation before filters, with three black-box orphan regressions that fail
with validation set aside. Corrected Session's rendering comments, memo length
guards, the stale pending lines and Sternhalma's script/porting status.

TodoMVC and Sternhalma passed their paired direct/tea cases with initialization
transfer temporarily disabled: no shipped app depends on it. The final tree has
the complete checker restored. Full x86-64 Linux hash recording and exact gates
pass; the source/fixture checksums match. macOS constituents: 1,303 passed,
15 skipped, only the two known case-folding failures. All original tea goldens
remain byte-identical, and no budget grant was added or increased. Updated
research 95 and prepared the PR's review-fix description without merging.

**What I learned**

An init capture is an arrival, not an allocation by its body. Its cells remain
shared with any retained callback environment, including a closure carried back
from a helper. A diagnostic copy expression must name a list field rather than
its record, and cannot use this module's report-only qualification. Budget grants
need an inventory check of their own: a misspelling can otherwise evade every
case, and a tea page has no separate value-fuzz case to which a grant can apply.
