## 2026-10-31 12:34 CET — validate compact typed entry evidence

**What I did**

Integrated both entry handoffs on the corrected runtime baseline a2ab6b6e3.
Independently reviewed the source and corrected two acceptance blockers: nested
field reduction lost opaque control provenance, and missing typed roots could
print partial inspection before an unexplained exit. Both have permanent
before-fail/after-pass regressions. Source/cached matrices pass29 discovery cases,
14 typed-root cases and8 continuation regressions. Full unfiltered gates pass315
steps with2152 passed and17 existing skips; final gates follow this record.

Independently recalculated all measured Debug medians, checked actual output and
inspection bytes, verified warm source counts, all12 optimized checking rows and
four real CLI checks, and every one of64 full build output trees. All captures
succeed. Candidate optimized checking minimum is289971 LOC/s; full cold100k build
maximum is572.060843ms. No failed input, retry or discarded timing supports these
claims. Ordinary Debug CPU overhead ranges0.85–6.28%; extra cache/pack bytes and
absolute inspector costs are recorded in the implementation plan.

Raw JSON SHA256 values are
Debug `9c30e31a419b4bdc58b1ec8db5ca26b0d487a163630abfefa9eac182cac1cf18`,
checker `f7d812c0fcf8a39b8ff30a72a5e4c42f4a496688d2dd10894721fe30a39b3b2b`,
full build `b0a43614e6284cd76ac5f89b9d8c459350bb48fcc4ce3c4548dcd3a7eb0155ee`.
The reproducible evidence archive SHA256 is
`e94f5c9cd6ea604c813c4d7a71fc8f36df8e1b8b32a8c42135e65423f6fa16bd`.

**What I learned**

A source capture being closed is not C, Wire or ownership evidence. The retained
graph remains explicitly partial and declaration liveness conservative. Cache
coverage needs the real stable nominal identity before installation, and embedded
insufficiency must not hide a repaired directory entry. Owned projection views
must survive storage growth and caller path mutation. All required metadata is
ordinary checked evidence, not source reconstruction after stores expire.

Performance and artifact costs must be measured separately. Empty root headers
add real bytes even without selected declarations; selected metadata and inspection
add additional costs. Standard optimized checker/full-build budgets pass, while
ordinary development Debug commands are measurably slower. The runtime selector,
typed queue, nominal layouts and public worker execution remain independent,
unaccepted work with their own gates. No unfinished proof was relabeled complete.
