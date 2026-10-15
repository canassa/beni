## 2026-10-15 00:18 CEST — Answer the document-helper review

**What I did**

Pushed the Conduit implementation and measurements to draft PR #98, asked
Claude for review, and addressed its six points. Clarified that the previous
record-with-body-case lowering remains intact, while whole-document cases
were formerly refused. Recorded the body-before-title slot lifetime and its
single-branch assertion. Added a black-box document helper whose transitive
Time.sleep call is refused with sync_boundary; synchronous helper effects
remain covered by the paired runtime fixtures. Named the precise selective
visit protocol broken by the built helper-value path. Explained that fallback
instruction provenance scales grants without measuring instructions, and
added reproduction pointers beside the raw JSON archive.

**What I learned**

The reviewer found no new code defect and agreed the measured criterion-7
stop blocks acceptance. It was useful to distinguish a case returning a
whole document from a case inside its body: the latter keeps its compiled
arm sites. The suspension boundary is a checker guarantee, not a lowering
workaround. Editor/Tour Chrome value fuzz and Linux verification remain
explicit limitations; the draft remains unmerged and the second full V3
campaign remains owed.

Review validation re-recorded hashes with no changes: 546/548 passed, only
the two known macOS case-folding failures. The first gate also hit an
unrelated time-report smoke-test CPU fallback overrun (1,012 ms / 999 ms).
The unchanged test, which includes nine Node startup probes, passed alone
at 863 ms (852 ms in the report tool and its children). No limit or coverage
was changed; a final unfiltered gate checks that remaining failure.
The final gate finished with 1,297 passed, 15 skipped and only the two known
case-folding failures; the unchanged time-report test passed in the gate too.
