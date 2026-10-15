## 2026-10-15 12:10 CEST — Rebase the ownership review fixes onto current master

**What I did**

Claude's final pass on the capture and budget fixes found no remaining findings.
Answered its optional nit by explaining that the browser guard runs the whole-root
budget inventory validation once for every kind. Master advanced during review;
rebased #116 onto 2f397d7b6, preserving both the nullary-method amendment and the
initialization-transfer amendment in the ownership contract. Re-recorded all run
hashes with zorg on Linux, without hand-merging any; no further hash diff resulted.
Exact `zorg build gates -j8` passes on that rebased tree. Source and fixture
checksums match the Linux tree, including the final harness comment. TodoMVC and
Sternhalma's paired pages and fuzz remain green with the existing approved grants.
All three original tea goldens remain byte-identical. Updated research 95's entry
versus ordinary diagnostic wording and final validation base. No merge.

**What I learned**

A passing reviewed head can acquire a conflict while master advances. The second
rebase changed the emitter through master's release-map and nullary-method work,
so full hash recording and exact gates were necessary even though the ownership
fixes themselves were unchanged.
