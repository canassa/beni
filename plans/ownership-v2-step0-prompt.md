# Prompt: the step 0 prototype of report 110

*For an agent. The owner asked for it on 2026-11-10. It runs the experiment that report 110 §7 calls step 0.*

---

Build the step 0 prototype of `docs/design/research/110-ownership-v2-design-review.md`, and decide with
measurements whether it is the next path for beni's ownership checker.

Read the report first, all of it, and treat §6 and §7 as your brief. Then read `CLAUDE.md`,
`docs/design/ownership-requirements.md` and enough of `docs/design/ownership-v2.md` and `src/own2/` to reuse
the lower half: places, values, the walk, liveness, holders, words and reports. Treat the codebase as yours.
Make whatever choices make the experiment fair and fast. Where the sketch in §6 is wrong or incomplete, fix
it and say why.

**Build**, lists only, behind a hidden flag beside v1 and v2. Change neither of them.

- **Locations** (§6.2): one per place of a type, and one for all the levels of a cycle. Add one call map
  between the locations of a caller and those of a callee, with a test against concrete paths.
- **Permissions** (§6.3): `own` or `shared` for each location. The default is `shared`, and `shared`
  refuses.
- **Contracts** (§6.4): for first-order code, and for known lambdas at the worded loops of `core/`
  (`List.foldl`, `List.map`, and the folds that `Dict.keys`, `Dict.values` and `Dict.toList` use).
- **The write rule**: the target is `own`, it did not escape, and each other holder is dead (today's
  liveness).
- **Recursive groups**: a fixed point over the two-point lattice.

Leave out records, cells, fibers, the entry, functions that return functions, and the cache.

**Measure**, the new pass against v1 and v2, with a ReleaseFast compiler on one thread. Use the script of
report 110 (`bench/ownership-v2-review.mjs`) and extend it as you need.

1. **Precision.** How many of the 308 real list writes of the 32 real roots are accepted. List each refusal
   with its cause.
2. **Soundness.** No trap under `--sanitize-lists` on the `run/Sanitiser*` corpus and on random programs
   from a generator that you write for callbacks, folds and recursive types. Compare the output of the plain
   build with the in-place build, not only traps.
3. **Speed.** Lines per second of the pass on the 32 roots.
4. **Losses.** Every fixture that v2 accepts and the prototype refuses, grouped by cause, with whether the
   full target design (§6, later steps) would recover it.

**The gate** of report 110 §7: at least 300 of 308 real writes accepted, no trap, and more than 500 000 lines
per second. Report the result against it plainly. If it fails, say why, and say whether a change to the
design would pass it or whether §8 (keep v2) is the better path.

**Deliver** a new report, `docs/design/research/111-ownership-step0-prototype.md`. It opens with a verdict
of one paragraph: *go*, *no go* or *go with changes*. Then come the measurements with exact commands, the
losses by cause, and what the next step would be. Commit the prototype code on its own branch and open a pull
request that links #2451. Do not merge it. Follow the repository's rules in `CLAUDE.md`: run `zig build gates`
green before you push, never weaken a test, never raise a limit, and never bend the design to get green.
