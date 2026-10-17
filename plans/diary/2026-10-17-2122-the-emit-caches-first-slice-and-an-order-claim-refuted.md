## 2026-10-17 21:22 CEST — the emit cache's first slice, and an order claim refuted

**What I did**

Built slice 1 of the emit cache (issue #94, step two) on `emit-cache-join` — the per-unit
lowering and the join, with no pack — rebased onto master `3c3d5f84e` after the spec merged as
#309.

- **The re-review's one open note was wrong, and the fix is a finding.** It asked for a
  date-stamped amendment saying "a walk over every root, filtered to the survivors" is the order
  a build emits: `emissionOrder`'s outer loop starts at surviving roots, so (the argument went)
  the filtered full walk and the restricted walk agree. I probed it with two real builds and they
  disagree: a DROPPED declaration's subtree never visits its dependants, and a survivor it
  referenced is first reached where a surviving declaration reaches it — later than the filter
  would put it. Three declarations, `dead` (first) calling `zed`, `main` naming `later` then
  `zed`: the application build emits `later, zed, main`; the same three kept (`--library`) emit
  `zed, dead, later`, and filtering `dead` out keeps `zed` first — the wrong bytes. The claim
  traces to the DCE commit `1621c4717` (2026-09-18) and sat in three places (`backend.md` §9.1,
  the join's step 2, the `emissionOrder` comment).
- **The corrections ride with the slice**: dated amendments in `backend.md` §9.1 and the join's
  step 2 (naming `tests/corpus/emit/app/DceSurvivorOrder.{beni,js}` as the counterexample), the
  `Lower.zig` comment, the unit list's new lift bullet (`browser-inline.md` §7 landed after the
  spec) and the funnel's six survivor sets; the slice's As-built note carries the measurements.
  Issue **#328** is the slice-3 consequence: a row must carry each unit's outgoing edges and the
  join must replay the restricted walk — filtering one canonical sequence writes other bytes.
- **The slice as built**: `Lower` records `Result.head_len`/`Result.tail_len` and one `Unit` per
  run of top-level statements — per nullary constant, markup hoist, synthesised value, comparator
  constant, and per declaration with `Part.twin_at` and the new `Part.lift_at` apart (one
  statement each). `Print.Context`/`printRange` prints one range against the module's shared
  printer state; `Join.join` concatenates, rebases each piece's marks by where it landed, one
  `SourceMap.write` per module. `Emit`'s development path only; `--release` and walk-1 are
  untouched; nothing is stored.
- **New tests**: the `DceSurvivorOrder` emit fixture pins the surviving walk's order, and a
  blackbox test builds `[first, gone, second]` and `[first, second]` and asserts the two
  `Main.mjs` files are one file, byte for byte, `$p$1` included.
- **The evidence, under the shared lock**: a master worktree at `3c3d5f84e` with its own
  `.zig-cache`, master's safe binary (`test-blackbox -Dcorpus=Dictionaries`, rc 0), the branch's
  `zig build gates` green with no cached steps, then `diff -r` of the three development trees —
  `run/Dictionaries` 16 files, `browser/tea/ApiItems` 43, `bench/corpus` 59, source maps
  included — empty, and the run-hash line the same on both sides (one pre-existing scenario miss
  of 145; no `run/` or `browser/` program re-ran).
- **The cost**, `perf stat -e instructions:u`, median of five: `run/Dictionaries` 154 660 315 →
  155 188 282 (+0.34%), `browser/tea/ApiItems` 498 523 216 → 502 555 760 (+0.81%), `bench/corpus`
  as one `--library` build 402 398 323 → 407 392 615 (+1.24%). The saving is slice 3's.

**What I learned**

- **The wrong claim was almost right, which is why it lived.** The restricted walk does visit
  only survivors, and every edge it walks is a reachability edge — the difference is that a dead
  ROOT is skipped before its subtree can pull survivors early. "It can reach nothing else" is not
  "nothing else could have reached it first".
- **A spec note can be a defect report, and the answer is not wording.** The reviewer's closure
  argument would have let slice 3 store one canonical order; the counterexample changes the row
  (edges per unit, a replayed walk in the join). When a probe can settle a claim, build the probe
  first.
- **Byte-identity evidence is cheap when the pipeline is right**: two safe binaries, 30
  instrumented builds and three `diff -r` took about four minutes of lock time. The run-hash line
  is the quiet oracle — equal on both sides means no program's output moved.
- **A scratch job can lie green.** My evidence script's diff steps used `out.master/…` where the
  measure script had written `measure/out.master/…`: rc 2, zero bytes compared, and the
  notification still said the job exited 0. I read the log, reran the three leaf commands
  directly, and got the real (empty) diffs. Check the leaf, not the wrapper.
