## 2026-10-22 20:16 CEST — the check's fixed cost per module is small; TypeKeys sorted every row copy

**What I did.** Took #464's check share apart. Built a ReleaseFast compiler whose
`--self-profile` events count user instructions (`perf_event_open`, one counter per
thread, a local patch never committed) and fitted each module's check events on
the generated 100k corpus (`zig build bench -- --generate=100000`, names migrated so
it checks clean), N=64 and `nowd`. Profiled with a frame-pointer ReleaseFast build
(`perf record --call-graph=fp`) and attributed samples to `Module.check`'s direct
callees. Fixed the one structural cost the profile showed outside the solver:
`TypeKeys.build` made its record facts by text-sorting every copy of every row in
the store, with stable block sorts, before deduplicating (#783). Now the rows are
made distinct by symbols first and only the distinct ones are put in text order.
Also fixed `bench/bench.zig`, which no longer compiled (#784).

**What I learned.**
- The fit "126 µs fixed plus 0.35 µs per line" does not hold. Against lines the
  intercept is large (52% of check's instructions), but against content it is not:
  regressed on each module's own lexing instructions, the check's intercept is
  81k instructions a module, 9%, and `constrain` and `solve` have none. Lines are
  a poor measure of a module's content (lexing itself shows a 39% "fixed" share
  against lines). With the driver's `dep_digest` (26k) and `cache_load` (4k), the
  per-module cost is about 111k instructions, 12% of the 100k corpus's check. Most
  of it follows a module's exported surface: `publish` 34k, `dep_digest` 26k,
  eager `derived` rows 13k.
- On the 100k corpus the check is the solver: `Groups.check` is 64% of
  `Module.check` (`Solve.unify` 35% of `solve`, `Instantiate.reference` 18%,
  `adjustRanks` most of `settle`). Imported-scheme instantiation is about 5%,
  per reference, not per module.
- On N=64 the check is one module: `Main.beni` is 42.9M of the 96M, and 21M of it
  sat outside every profile event, mostly `TypeKeys.build`.
- Per-module tables sized by the whole program remain (`TypeKeys`' `named0` and
  `alias0`, `Crossing.held_at`, `Marker.payload`): quadratic in principle, under
  0.5% of the check today.
- Record facts are checked byte for byte with a print patch on both compilers:
  596 rows on N=64 and `nowd`, 2 255 on the 100k corpus, identical.
