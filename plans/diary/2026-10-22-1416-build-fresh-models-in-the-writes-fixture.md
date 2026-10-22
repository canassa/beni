## 2026-10-22 14:16 CEST — Build fresh models in the writes fixture

**What I did**

Made the page fixture's feed and home initializers functions and called
them when starting the page. The hidden ownership-everywhere baseline
correctly refused its old initializer: it returned a top-level feed whose
errors list the update appends to. Each start now builds fresh lists.
The write-set golden stays unchanged, and the fixture checks under the flag.

**What I learned**

Wrapping a top-level model in a unit lambda does not make its lists fresh.
Fresh initialization must continue through each nested initializer. This
fixture still tests the same cross-module write paths, with no change to
record-update enforcement, a compiler check, core, or a platform. The fix
is part of #210; builds remain self-hosted on dagon without measurements.
