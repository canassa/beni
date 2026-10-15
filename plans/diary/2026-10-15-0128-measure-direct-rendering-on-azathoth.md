## 2026-10-15 01:28 CEST — measure direct rendering on azathoth

**What I did.** Measured the table and all UI sweeps with vanilla, both Solids,
browser-tea, browser-direct and P3 where available, rate 1, on azathoth's
dedicated physical cores. Kept 1,080 table samples and 10,188 sweep
observations. Fixed the harness trying nonexistent P3 pages and resumed all
remaining conditions jointly, preserving both epochs. Recorded whole and
part-by-part sizes, unchanged app builds, source/byte evidence and cold
sampling profiles. Wrote research 87 with the answer and failed targets
first. Linux's earlier gate passed; the final report branch is refreshed on
6e041631f for its publication gate. The PR will request Claude review and
remain unmerged. All builds used Zorg.

**What I learned.** Direct misses live, derived and depth speed targets at
1.50×, 1.317× and 2.123× vanilla. Depth's eight-step cap yields 121 groups
and 8,107 child reads; width copies its 1,024-field model for one hole. The
table remains 4,102 B brotli, non-core 3,403 B, and its update walk/indirect
writer is slower than P3 in the exact warm-up. The other small fixed paths
remain bounded, but their native share is not fully attributed. None of the
four unchanged full apps builds on measured master; reduced TodoMVC does.
Two Chrome value-fuzz failures follow full navigation on either platform,
then send into an error document with no hooks; they are oracle faults,
not evidence of a differential stale screen, and do not make Chrome green.
The full adversarial rendering campaign remains owed.
