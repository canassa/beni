## 2026-10-03 00:38 CEST — How long building beni takes, and incremental compilation

**What I did**
- Measured Zig 0.16 building beni: Debug 9.0 s cold, 7.6 s after an edit, ~0.5 GiB; ReleaseFast
  (LLVM) 3 min 28 s either way, one thread, ~2.4 GiB. Tried `-fincremental`, with and without
  `--watch`. Findings and options for the owner in `plans/build-speed.md`. No code changed.

**What I learned**
- An edit costs almost a cold build, because any change under `src/` changes the build id, and
  then the core-pack maker is recompiled and re-run before beni is compiled again.
- `--watch -fincremental` rebuilds beni in ~0.13 s, but on 0.16 it crashes on the maker's Run step,
  and the configure-time build id goes stale under `--watch`. Incremental without `--watch` gives
  almost nothing, so it barely helps agents' one-shot gate runs.
