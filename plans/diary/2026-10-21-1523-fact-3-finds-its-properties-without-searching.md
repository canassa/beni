## 2026-10-21 15:23 CEST — Fact 3 finds its properties without searching

**What I did.** Issue #577, cause 5 of `plans/build-profile-2026-10-21.md`. I profiled the N = 64
dashboard and `nowd` with a throwaway frame-pointer build, then cut what it ranked, one change
at a time. The solver's walks over sorted lists (a fold, a spread, a mark, a link) look each id
up where the last one was. `copy` remembers the last edge of each end, and `hasEdge` walks the
shorter list. One-site batches past a var's last site are not searched for, the `u32` searches
have no order call, and `VSet` is split into a 64-byte hot record and two columns. Every output
and every `spec_pts_*` counter is the same. Against master, fact 3 fell 10% at N = 64 (78.5 → 70.3 ms) and 14% on
`nowd` (60.8 → 52.2 ms). The new `emit/release/inline/SpreadCopiesLookups` went from 4 869M
instructions, over the budget, to 4 091M. The table is in `backend.md` §9, after *Memory*'s
2026-10-21 notes.

**What I learned.**

- Count instructions (`perf stat -e instructions:u`) for each change. Times on dagon moved by
  more than the changes did, even at load 2. Instructions moved by under 0.1% between runs.
- A hand-written lower bound by `.id` was slower than `std.sort.lowerBound` in the walks. A
  forward scan of four places before the search was slower still. I measured both and dropped
  them. The `u32` one did pay, in `enqueue` and `joinNow`.
- The edge check's shorter-list rule cost instructions on its own and saved them once the
  last-edge caches were in. Measure a change again after the ones it depends on.
- `perf script` without `--no-inline` resolved every inlined frame with addr2line and took
  minutes per file. A background job under `ssh 'bash -s'` needs `</dev/null`. Without it,
  `perf record` read the heredoc and wrote empty files.
- #584 and #591 landed while this was in progress and took the 57-child case I first sized under
  the budget on their own. I sized it again on master, at 62 children.
- On the dashboard every representation key is wild, so dense per-type slots would not have
  applied there. The hints reach the same walks with no change of representation.
