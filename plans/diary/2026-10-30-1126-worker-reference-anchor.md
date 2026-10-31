## 2026-10-30 11:26 CET — Worker reference anchor

**What I did**

Final verification found the new native-error reference in workers §6 used an
incorrect section slug. Corrected it to the research note's actual §9 heading
and validated every new round-3 relative path and heading anchor against the
target Markdown. No design contract changed. Final-head CI is awaited again
after this correction; cleanup and its result will be recorded on PR #1304.

**What I learned**

Checking that a Markdown target file exists does not validate its section anchor.
The final audit must derive the target heading slug as well.
