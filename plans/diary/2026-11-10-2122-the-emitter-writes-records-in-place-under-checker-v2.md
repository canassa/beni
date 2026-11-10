## 2026-11-10 21:22 CET — the emitter writes records in place under checker v2

Part of #1018 (S5b, third part). Closes #2457.

**What I did**

- The lowering channel of checker v2 (`own2/Hoists.Table`) has a record half now: a clean bit, the accepted record writes, and the reads that the lowering binds (a hoisted read with its write, a field capture with none).
- `src/js/RecordRows.zig` converts those rows into the table that the emitter reads (`own/Hoists.Table`). The emitter is not changed, and v2 does not import `src/own/`. `Session.zig` installs the converted table under `--ownership=v2`.
- A module's records are written in place only where the module is an application's and both halves of the channel are clean. A refused record line, or a declaration past the record pass's limit, keeps the spread for the whole module.
- The test twin: `.in-place-v2` on a `run/` fixture gives three more builds under `--ownership=v2 --records-in-place` (sanitiser, stores, release). `zig build test-records-in-place-v2` does it for every `run/` program and inline page.
- Three new fixtures (`run/RecordOnceInPlace`, `run/RecordRefusedKeepsSpread`, `run/RecordLimitKeepsSpread`) and three mutants (`record_rows_unchecked`, `record_reads_lost`, `record_limit_clean`).
- The harness probe of the in-place sweeps reads only the errors of a build (#2457).

**What I learned**

- The order of two calls was the whole first defect. `Row.lines` hands the rows to the channel, and I called it after `channel.finish`. The table then had every write and no read. The stale-read sanitiser trapped at the first program, on the first field. A test that runs the emitted program finds this in one run. A report golden cannot find it, because the report's text was correct.
- The line for the limit is load-bearing, and no assertion stands behind it. An update that is accepted on a condition for its callers is correct only where each caller was checked. A caller past the limit has no verdict. Without the line, the callee's update is a store and the caller reads a stale field. The emitter's `assertAccepted` does not see it, because the caller has no update of its own. I wrote the mutant for it before I trusted the line.
- A mutant found a defect that no fixture had. `record_rows_unchecked` converts every module with a record line, also one with a refusal. Two `ownership/` fixtures then stopped the compiler in the table's own verification: a once closure's creation had a demand row, and the emitter's table accepts a demand only at an update or a call. In the corpus, each module with such a line also had a refusal, so the plain compiler never converted one, and the sweep was green. A module with such a line and no refusal stopped the plain compiler. `run/RecordOnceInPlace` is that module. A mutant that widens the input of a later stage is a cheap fuzzer for that stage.
- The sweep's one failure was no record fact. A program with a warning and a refusal was not read as refused, because the probe read each diagnostic code. The list sweep of v2 has had the same gap. A sweep that no gate runs can be wrong for a long time.
- The measurement by bytes is cheap and exact: build each program with and without `--records-in-place` and compare the JavaScript. v1 writes in place in 46 of 903 `run/` programs, v2 in 37, both in 31, and 30 of the 31 emit the same bytes. The one difference is a capture row for a field read through a `case` binding, which v2 does not make.
- `ownership/WideFieldConditions` hides an over-refusal behind its limit. With a `run` that returns an `Int`, the record pass ends and refuses the calls of `step` (`disjoint`, approximate), where v1 accepts and hoists the read. Solving the limit alone does not make that program accepted.
- My grep for a store (`name.field = `) missed the comma form `(v.x = 1, v)`, and I wrote in my notes that v2 refused a fixture that it accepts. I compare bytes now and do not count patterns.
