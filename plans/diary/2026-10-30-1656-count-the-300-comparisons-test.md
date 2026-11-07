## 2026-10-30 16:56 CET — the 300-comparisons test counts records, not milliseconds

**What I did.** The build test for 300 derived comparisons of one module ended with `wall_ms < 1000` and failed in CI on an unrelated PR (#1332). It now runs the module at 75 and at 300 uses, sums the `total` of every `account f<k>:` line of `beni dump --stage=ownership --ownership=v2`, and checks that four times the uses cost at most four and a quarter times the records, with no `unchecked f` line. No clock is read.

**What I learned.** The `cmp_decl` scan is a plain loop that no account charges: with the memo removed in `src/own2/Groups.zig` (every lookup rescans the module), the new test still passes, and every `account f<k>` line is identical at 75 and 300. So records pin that per-use work stays constant, but they cannot catch the scan's return. The wall-clock test could not either, as its own comment said.
