## 2026-10-27 01:18 CET — Specify recursive ownership values

**What I did**

Reviewed ownership-v2.md against ownership-requirements.md, src/own2 at
2ffd5000f, the requested issues and complete PR review threads, and #1125
through its bfca7a3a7 repair. Rewrote the recursive-value account in place:
root-relative links, folded arrival multiplicity, exact/collapsed coverage,
incremental apart/excl/union/read-off work, call views and settled proof
obligations. Added 28 mechanism-pair acceptance rows, counted tower contracts,
a code/design reconciliation, and review-inclusive reference estimates
(234 days total, 211 on the dependency path). Preserved section headings and
the historical As built note.

Filed #1128 (cross-depth fold multiplicity), #1129 (relabelled fold steps),
and #1130 (source-depth native recursion). Read #1125's repair while finishing
and recorded its equal-cell duplicate check separately from full symbolic
arrival/substitution coverage. A temporary hermetic probe confirmed #1129:
identity relabelling loses deep's shared result. Restored the exact source
after the probe; no code or fixture is part of this docs change.

Validation on dagon only: zig build gates passed; git diff --check passed;
scripted checks confirmed unchanged section headings, byte-preserved historical
As built text, all 28 distinct mechanism pairs and the estimate sum. The probe
failed at the intended post-map equality and its log is attached to #1129.

**What I learned**

Being above every individual member's condition is insufficient after a fold
identifies coexisting depths. The new summary position must compare their
arrivals before deduplication, including concrete repeated allocations and
symbolic arrivals later made equal by a call. A small published graph also
says little about total work: whole-root caches still rebuild growing reads.
The shape architecture remains viable, conditional on those soundness and
incrementality obligations; neither extra copying nor a larger ordinary-program
allowance resolves them. Repeated review is a material part of slice scope,
but elapsed overlapping agent time is not measured implementer labour.
