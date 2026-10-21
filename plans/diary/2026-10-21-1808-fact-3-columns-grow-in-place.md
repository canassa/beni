## 2026-10-21 18:08 CEST — fact 3's columns grow in place, scratch stays mapped

**What I did.** Issue #606 (cause 2 of `plans/build-profile-2026-10-21b.md`, committed here).
`src/Arena.zig` gained column arenas (`initColumn`: a 256 MiB lazily committed first chunk on
64-bit Linux and macOS, so one list alone grows in place; a refused reservation falls back to
what the request needs) and, on Linux only, huge-page placement and `MADV_HUGEPAGE` for chunks of
2 MiB or more. `Spec.RunArena` gives fact 3's eight hot lists a column each. Check's, the
frontend's, the emit workers' and ownership's per-item scratch is emptied with `keep_all`
(ownership's walk arenas moved off `std.heap.ArenaAllocator`). Outputs byte-identical, run hashes
unchanged, gates and `test-playground` green. N = 64 at `--jobs=1`: faults 29.0k → 11.3k, sys 55 →
32 ms, wall 201 → 169 ms, peak RSS 104 → 96 MB (`backend.md` §9 *Memory*, the 2026-10-21 *As built*).

**What I learned.**
- A stack trace dumped at every non-last free of 64 KiB or more in the run arena found the
  garbage's owners in one debug run: eight lists, 44 MB over four runs. Cheaper than guessing
  presizes, and presizing would have needed per-program ratios (`field_outs` is 0.4 to 4.3 per node).
- THP under `defrag=madvise` is a bet on the host: on fragmented dagon, one run under load doubled
  sys time. The portable half (columns, `keep_all`) lowers RSS everywhere; huge pages take most of
  the faults on a quiet host.
- `std.posix.MADV` is `void` on wasm32-wasi: a comptime-false early return keeps the call out of
  analysis there. The gates' wasm build caught it, not the native unit tests.
