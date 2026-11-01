## 2026-11-01 16:27 CET — integrate upstream worker foundations

**What I did**

Merged upstream master 1251f98a8 into the workers branch after validating and
pushing the selected-realm consumer checkpoint 6bb3f0f7e. The only merge conflict
was the emitted-program hash index. Re-recorded the complete index by executing
its programs with the merged compiler; the unfiltered test-run-hashes step
passed. Kept both earlier validated source trees and their independent evidence.
The full unfiltered gates validate this merged source before it is committed.

**What I learned**

GitHub reports the pre-merge PR as conflicting, which prevents the normal PR
checks from starting. The merge requires no worker design change or ownership
implementation by this workstream. Earlier optimized budget measurements belong
to their exact recorded source tree; they do not certify the newly merged tree.
