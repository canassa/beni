## 2026-10-13 04:50 CEST — Ownership checker slice 4: enforcement

**What I did.** Specified and built `ownership-checker.md` §28. A platform declares `"lists": "in-place"`
(`browser-direct` does); there `check` and `build` run the ownership pass after the module check and every
rejected or pending line is an error — four codes, one diagnostic per root cause, messages in thesis Chapter 8's
shape with their own excerpts and a `List.copy` line (`src/own/Message.zig`, `Enforce.zig`). Summaries cross module
boundaries as a *summary block* (`src/own/summary_bytes.zig`), a fifth cache-entry section, so the checked core
carries core's and the platforms' summaries; an enforcing run treats an entry without one as a miss and publishes
each non-pack module's interface hash folded with its key. Ten `build/bad/direct/Ownership*` fixtures, each also
built clean on `browser-tea` by the harness; the `ownership/` kind now checks that `check` fails exactly when the
dump rejects. Three `browser/direct/` pages failed for real reasons and take the copy their error asks for (a fourth, `KeyedEnds`, stopped failing when master dropped the identity promises). Research 89.

**What I learned.** The entry protocol, not the library, is what the pass costs on Conduit: shipping core's
summaries took the dump's 33 ms to the build's 28 ms, but `entryCall` alone is 22 % of the process, so the 10 %
target holds on the pages, TodoMVC and the table app and fails on Conduit (+112 %) and Bike Wars (+18 %) —
reported, not worked around. Sealing a whole module per cross-module request pushed a corpus case over the budget;
sealing per declaration costs nothing and still checks the codec on every summary the tests read. `ForForms` is real
sharing the checker can only call a limit, because the entry's fixpoint joins `update`'s arms. Two practical traps:
a shared `~/.cache/zig` lock stalled builds for minutes (a private `ZIG_GLOBAL_CACHE_DIR` fixed it), and a BIR
`let_def` carries whatever token lowering met last, so a binder's name has to be found from its `=`.
