## 2026-10-17 16:53 CEST — the emit cache spec: printed text, development first

**What I did**

Wrote the step-two spec for issue #94 (the emit cache), on the dashboard's answer to
`emit-cache-oc-q1` — *"Printed text, development first"*. The worktree was fast-forwarded to
`055609e06` and `zig build gates` was green on it before and (to be confirmed) after the docs.

- `backend.md` §9 gains `### The embedded modules' printed text, in the pack` (line 4756, before
  *The release optimiser*). It fixes the unit (a run of top-level statements with one selector:
  declaration, twin, derived row, primitive comparator, nullary constant, schema part, markup
  hoist), what a unit carries (bytes, marks, name identities, `Needed` entries in order, runtime
  flags, facts), the funnel that makes reuse honest (every program read goes through one
  accessor; a unit is reused only when the build answers alike, otherwise it falls back), the
  maker's canonical all-live run, the join (head rebuilt, units in canonical order restricted to
  the survivors, export and footer rebuilt, marks rebased, one `SourceMap.write`, no re-print),
  and what holds it (counters, the differential `--core-root` tests, emit goldens, run hashes,
  determinism; acceptance = `perf stat` median of five on three targets).
- `backend.md` §11.1 and §11.2 and `fast-compiler.md` §8 carry the amendments: the row kind
  `emit`, key `"BENIEMIT"` + module key + one `--schema-library` byte, the maker, coverage and
  the refusals, and — the point the task demanded — that a development build rebases a cached
  unit's marks while **a release build reads no row** (`--release` rewrites the text after
  lowering, so release caching is a later step with its own spec).
- Measured the baseline for the later slices: `run/Dictionaries` 153.8 M, `browser/tea/ApiItems`
  492.7 M, `bench/corpus` 400.0 M instructions (median of five, `perf stat -e instructions:u`,
  under the heavy lock), trees kept under `zig-out/scratch/oc/measure/out.baseline/` for
  `diff -r`. The earlier worker's drafts (151.5 / 489.2 / 390.7 M) match within a few percent.
- Slices named in the spec: (1) `Lower` lowers one unit at a time and a join assembles the
  module, byte-identical, no pack; (2) the funnel + maker writes rows; (3) a development build
  reads rows.

**What I learned**

- `perf` is not on `PATH` and not in the dev shell; a nix-store binary works
  (`/nix/store/wvrl2jv46nfig6kmmnsbs899k3cpznyb-perf-linux-7.2.9/bin/perf`, `perf_event_paranoid`
  is 2). Put the full path in scripts.
- Development printing is statement-local: `Print.print` walks the body one `p.statement` at a
  time, each top-level statement ends with its own newline, and a development module has **no**
  blank lines. That is what makes unit bytes spliceable at all.
- The map's `names` are the **base** texts in first-use order and identity is the whole
  `JsIr.Name` (module, base, tag): two declarations' locals `x$2` are two entries with the same
  text, and a `$`-prefixed base gets none. A cached unit must carry both the marks and the
  introductions, because `nameFunction` adds an entry before the mark that consumes it.
- `emissionOrder`'s edges (refs + `siteTops`) are a function of the module's check, and dead arms
  only change text — so any build's order is the canonical order filtered. That is the join's
  order rule, and it is why a core unit's facts are canonical in every build (`Reach.exempt` sets
  every ctor live for core) while a platform unit over a `case` arm can vary per program.
- The pack is `@embedFile`'d into the binary uncompressed, so emit rows are binary size; the live
  embedded text of a page build is 452 071 + 288 414 bytes on ApiItems, and the rows hold every
  declaration.
- The gates log's "failed command … docs_test" line is decoration when a passing step wrote to
  stderr; exit 0 is the verdict.
