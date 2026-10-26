## 2026-10-26 14:14 CET — Make the ball machine controls visible

**What I did**

Implemented #1086 after comparing the actual `beni-logo/flow.html`, its CSS and
reset handler. Put At once and Per batch above the machine in a sticky panel,
with live values, the capacity hint and Reset the counts. Empty playground
consoles no longer reserve a third of the preview. The controls fit without
scrolling at desktop and phone sizes, in both colour schemes.

Reset matches the reference: it restarts the machine and its counters while
keeping both selected values. A keyed Cmd.Restart cancels and awaits the old
control/simulation scope before its replacement starts. Control.beni stays focused
on the four semaphore loops.

Chrome checks failed on the previous page and pass after the change, including
both sliders changing the live SVG, the capacity hint, and two resets that retain
the settings and resume the physics. Reviewed desktop and phone screenshots in
both schemes. Updated the existing browser fixture to reset twice; its transcript
records exactly one scheduled frame after each restart. Refreshed all three run
hashes with Zorg LLVM; zero runs failed. The sample is formatter-clean and the
updated project is open locally on port 8001.

**What I learned**

The original sliders already worked but followed the tall SVG, below the preview's
initial viewport. The flow page's reset clears the whole machine, not only its
counts, and keeps the knobs. That needs a command restart rather than replacing
only the mutable world while old fibers still hold queues and permits.

Kept these changes uncommitted with the prior refactor: the existing full-gate
blockers #90 and #1085 remain recorded; no unrelated goldens or tests were changed
to bypass them. All builds on this AArch64 Mac used Zorg.
