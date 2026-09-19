# Work queue

The manager's running order, written 2026-09-18 when the owner went offline with
"continue the work on the language, don't stop; you are manager, planner and
validator; Opus agents implement". Edit freely — this is a plan, not a log; the
log is `diary.md`.

## How a slice runs

1. **Spec first** (CLAUDE.md rule 1): an Opus agent amends the normative
   document; the manager reviews it against the code.
2. **Implement**: a second Opus agent, from the spec, with fixtures that fail
   first. One building agent at a time in the main checkout; a docs-only agent
   may run beside it if the files do not overlap.
3. **Validate** (manager): read the diff, stash-prove the fail-first fixture,
   run the three gates plus a second `test-blackbox`, re-run any number claimed.
4. Commit per validated unit, push, diary at the end of the session.

Decisions the owner would normally take are taken by the manager while they are
offline, **recorded in the diary as manager decisions and kept reversible** —
one commit each, nothing force-pushed, no history rewritten.

## Queue

| # | Slice | State | Notes |
|---|---|---|---|
| 1 | Stale "numbers only" hint in `Diagnostics.zig` | **done** `cfe4665` | found by L1; `<` is no longer numbers-only |
| 2 | **Tail-call loop** (M3b, `backend.md` §8) — spec, then code | **done** `1cbf68e`, `bbfc869` | must precede effects; lets `foldl`/`foldr` leave `foreign`; closure-capture hazard is the exit-0 risk |
| 3 | `ambiguous_method_receiver` on by default + hard cap on inferred `where` count | **done** `9074538`, A.83 | owed 4/5; manager decision: yes to both, cap 64; spec §10.9/§6.4 amendment first |
| 4 | `foreign` + `where` arity check (`boundary.md` §4) | **done** `16b1c0d`, A.84 | owed 2; how `Sibling.zig` reads exports decides the shape |
| 5 | Two printer defects: `Render.writeRecord` 64-link flatten drops `| r`; `Schemes.Writer.max_depth` writes `<error>` with exit 0 | **done** | owed 3; each needs a fail-first fixture |
| 6 | Decision trees (M3b, `backend.md` §7) | **done** `ebacb5b` (spec), `cf7806f` (code) | worst path 17→2 on the enum-in-cons match; R1–R6 10–20 % faster, checksums identical |
| 7 | Rest of M3b — audit **done** (`plans/m3b-audit.md`): left are `?`, `Int32` (a language gap: owner decision), `--source-maps` honesty, sibling-import rewrite | todo | interpolation, tuples, record update already work |
| 8 | **Reachability DCE** (M3c) | **done** `dc311d0` (spec), `22f7f2f` (code) | hello-world 68 794 B / 19 files → 2 061 B / 5; spec's edge set was wrong three times and the compile-time self-check caught each |
| 9 | Drop the 4×500 split in `bench/runtime` once #2 lands; re-take M5 | todo | measurement follow-up |
| 10 | `transparent-effects-proposal.md` §10 item 1 is stale (`Func` is n-ary now) | todo | docs; found by L1 |
| 11 | `Render.Namer.allocate` is quadratic: ~23 ms per 64-clause warning in Debug (0.1 ms ReleaseFast) | **done** | found by slice 3; low priority |
| 12 | Effects: spec pass **done** `fe3cf8e` — `plans/effects-plan.md`; **eight owner decisions before any code** | waiting on owner | E1/E2 could go straight to master once decided |
| 13 | **M1 miscompile**: refutable pattern in a parameter | **done** `59e47f3` | type-directed (usefulness as a one-row match), `let` widened; my first decision (syntactic rule) broke 40 sites and was withdrawn |
| 14 | `check/Exhaustive.zig` reports nothing when `pattern_budget` runs out, so a non-exhaustive `case` can reach a default-free tree | **done** | exit-0 hole documented in `backend.md` §7; make budget exhaustion a diagnostic |
| 15 | Core callback order: `List.map` ran right-to-left | **done** | found by the effects plan |
| 16 | `?` codegen (`Lower.zig`), the last real M3b gap | **done** `b545b60` | after DCE lands (same file) |
| 17 | `Int32`: absent from the language, listed in `backend.md` §1/§4 | **owner decision** | add `core/Int32` + a `language.md` paragraph, or strike the rows |
| 18 | `language.md` has no evaluation-order section: "strict, left to right, in source order" lives only in the effects proposal §5; promote it, and say `let` bindings evaluate in written order (core's `Dict.mapTree`/`foldlTree` depend on it; M3c inlining must preserve it) | **done** | docs + a `run/` fixture pinning argument and `let` order |
| 19 | `List.sortBy` calls its key function more than once per element, in merge order | **done** — manager decision: key once per element (decorate-sort-undecorate); costs R3 +18 % where the key is a field read, saves O(n log n) key calls otherwise | harmless while pure; under effects a hazard — decorate-sort-undecorate, measure allocation |
| 20 | **Record literal evaluates fields in sorted-name order** (`Lower.zig` `recordNode` sorts, then lowers in sorted order) — observable via `Debug.log`, an effect-order bug later | **done** `2bf6f03` | fixture waiting in scratchpad `EvalOrderRecordFields.beni`; evaluate in written order into temporaries, sort only the emitted properties |
| 21 | **A `let` value naming a LATER `let` value compiles clean and crashes** with a JS TDZ `ReferenceError` | **done** | wants a `check/bad` diagnostic (the `bind_rhs_forward_reference` shape), or dependency-ordered emission; decide in spec (`language.md` §7 says all bindings are in scope) |
| 22 | Default `pattern_budget` of 200 000 refuses a flat ~440-literal or ~310-constructor `case` (cost is ~1.05·n² with no nesting) — an ordinary lookup table | **done** `992ab59` — flat columns decided by set membership (O(n)), default 5 M | nothing in the repo is within 19× of it today |
| 23 | **Top-level value cycles build with exit 0 and throw a TDZ `ReferenceError`** (`x = y + 1; y = x`, and transitively through a function) | **done** `a9b77c9` | `emissionOrder`'s comment "a cycle the checker allows only through functions" is false; the check must walk dispatch-table edges as well as `bir.refs`, so it belongs after the checker (Reach.zig's graph is the natural home); written up in `language.md` §6 |
| 24 | **M3c `--release`**: local dead-binding elimination, compact printing, short frequency-ranked names (`backend.md` §9 items 1–3), then field ambiguation and inlining | **done** `822eab5` (7 commits) — bench/corpus 126 436 → 55 593 raw, 21 840 → 15 017 brotli; widening the inliner breaks 4 run programs, so the narrow licence is a safety rule, not only a size one | §9's ranked list is a paragraph per pass; needs the same expansion §7–§9-DCE got; `--release` is refused today |
| 25 | Exhaustiveness: a TUPLE-keyed table (`case ( a, b ) of ( 1, 2 ) -> …`) is still 2n² and meets the 5 M default at ~1 580 rows | **done** | extend `Exhaustive.Flat` to unwrap a single-alternative constructor into flat columns (`checker.md` §6.6 says so) |
| 26 | `check/Cycles.zig` and `js/Reach.zig` duplicate one edge walk with nothing mechanical keeping them in step | **done** `2cb21eb` — `src/check/Edges.zig`; output-identical; `eliminate` +0.2 ms (the price of the buffer, stated in the docs) | hoist the three-leg walk into a shared module both import, once no agent is in `src/js/` |
| 27 | M3d: design pass **done** — `plans/m3d-plan.md`; **`lazy` is hard-blocked on effects; six owner decisions** | waiting on owner | the undisputed part (static multi-entry chunking, single-file `--release` bundle: −22 % brotli on `Dictionaries` from concatenation alone) is specified in `backend.md` §10 and can be built once `--release` lands |
| 28 | M4 design-readiness audit **done** — `plans/m4-plan.md`; **nine owner decisions** (disk cache before daemon; ordering `--release` → M4-0..3 → effects → M3d; …) | waiting on owner | slice zero does not exist: `beni check` cannot consume a serialized interface, there is no interface hash or comparison; `Session.run` is not re-entrant |
| 29 | **Interface bytes embed a whole-program `TypeId`** (`Interface.Term.app`/`alias`), so adding a type to ANY earlier module renumbers untouched modules' interfaces and would defeat §8.1's firewall | **done** `792bf76` | write `(module name, type name)` — or an interface-local type index — instead of the session id |
| 30 | M4 follow-ups from slice 29: the dispatch table embeds `Graph.Index`/`TypeId`; Reach edges embed `Graph.Index` and read other modules' tables; the interface `symbols` column is interner-local (write as text, re-intern on load); `Types.build`/`aliasBody` are whole-program Bir reads; `Schemes.Writer.attach` is not idempotent | waiting on owner (M4 plan D1–D9) | all are M4-0/M4-1 work per `plans/m4-plan.md`; none is observable today |
| 31 | **`beni check` cannot check a program that imports its platform** (`import Node` → `unknown_module`; `--platform` is a `build`-only flag) — so the editor/CI "just type-check it" path does not exist for any real program | **done** | find what `boundary.md`/`frontend.md` say; likely `check --platform=<name>` sharing `build`'s package resolution |
| 32 | `bench/size.mjs` total line mixes a netted `raw_bytes` with a gross `release_raw_bytes` (reads as release being LARGER); compare `gross_*` with `release_*` | **done** | found by the state-of-the-compiler pass |
| 33 | Emit is 1.74× C0 on 26 % more `JsIr` nodes for the same output bytes (statement-form lowering, trees); check tax is +24.5 % vs C0 (morning +20.3 %) — both far inside budget (12× and 5×), recorded so the trend is watched | investigated — `plans/check-tax.md`: the evening +24.5 % was noise (HEAD is +20.6 %, adoption was +16.7 %); 44 % of the tax is evidence numbering riding on every instantiation; one output-identical skip took it to +17.2 % | `plans/state-of-the-compiler.md` §3, §8 |
| 34 | M3c slice 2, field ambiguation: **specified and declined** — 0.07 % brotli across 109 trees, 0.71 % best case; the corpus has almost no records. Revisit when field names reach ~5 % of generated bytes | closed (measured) | `backend.md` §9 *Item 4*, `plans/release-notes.md` K–N. **Owner question flagged**: should `--release` refuse `Debug`, as Elm's `--optimize` does? |
| 35 | **M4 slice zero**: serialized interface (LE, `symbols` as text), SipHash128 interface hash, `--roundtrip-interfaces` acceptance matrix (cold ≡ round-tripped over the whole corpus at `--jobs=1/8`), churn by hash | **done** `506f596`..`f8357ba` — the matrix found no byte difference on 336 fixtures; churn by hash: an interface change never moved a second module; reading every record is 0.50 % of a cold check | `checker.md` §7 *The serialized form*, `fast-compiler.md` §8, `plans/m4-slice-zero.md` |
| 36 | **`String.indexes`/`indices` answer in UTF-16 code units** (`core/String.js:76-85` is `indexOf`), while `length`/`slice` count code points — wrong answer at exit 0 on any astral character | **done** `3edc718` (also `split s ""`; overlap rule now Elm's non-overlapping — a behaviour change, stated in the doc) | found by the coverage audit; repro in scratchpad `audit/defects/IndexesAstral.beni` |
| 37 | Two `main`s are reported under the code `missing_main` / title "MISSING MAIN" (`src/js/Emit.zig:617`) | **done** `06a2893` — `duplicate_main`, TWO MAINS | needs its own code |
| 38 | Nine `core/` doc examples do not compile (six are `f -1` parsing as binary minus; `Tuple2`; bare `toString`); the platform's missing-runtime diagnostic points at the user's first line | **done** `6eca714` | docs + span |
| 39 | `List.map2`–`map5` overflow the stack at ~5 700 / 4 900 / 4 200 / 3 700 elements (the only core functions linear in stack; everything else survived 4 000 000) | **done** `60bc529` | `backend.md` §8 lists them as accepted; they are four `foldl`-shaped rewrites away from not being |
| 40 | Corpus walker cannot express: a `check/bad` kind that carries a platform (unlocks 6 boundary codes), a build-that-must-fail kind (`missing_main`, `main_not_program`) | **done** `4fe1543` — `build/bad/`; 106 of 108 codes now have a corpus golden | 10 of 107 diagnostic codes are blackbox-only for this reason; design call on layout |
| 41 | `String.contains s ""` is `False` (it reads `indexes`, and an empty needle matches nothing); Elm and ordinary usage say `True` | **done** — `contains` guards on an empty needle; `startsWith`/`endsWith`/`replace`/`split`/`indexes` were already Elm's answer and are now pinned | `run/StringEmptyNeedle.beni`; every empty-needle rule is a doc example |
| 42 | A doc-example gate for `core/`: append each `--|     expr == value` example verbatim as a private declaration to a temp copy of its own module and `check --core-root` (exact in-module scope, no qualifier rewriting) — needs a skip list for prose lines and a stub preamble for ~20 examples naming undefined values | **done** — `tests/blackbox/docs_test.zig`, +0.33 s. 265 examples found, 221 compiled AND executed, 34 prose, 10 skipped with reasons. No stub preamble: the ~20 undefined names were a doc defect and 11 examples were rewritten self-contained | `checker.md` Appendix B, `frontend.md` §7. Caught all nine of 38's on `06a2893`'s `core/`, and found 43 |
| 43 | A `List` compared INSIDE `core/List.beni` as part of a larger value (`tail xs == Just [ 2, 3 ]`, `unzip … == ( [ … ], [ … ] )`) emits `() => List$eq(m0)` — a NULLARY closure where a binary method was promised — and the program crashes at run time, having exited 0 from the build | todo | `Lower.targetArity`'s `.top` branch reads `bir.decls[].params`, which `bir/Lower.newDecl` leaves at 0 for a `foreign` declaration; the `.ext` branch reads the interface scheme and is right, which is why `core/String.beni` compiles the same expression correctly. Blocks 4 of 42's skips. §3 says the backend reads targets and never types, so the arity probably belongs on the decl or in `Dispatch`, not in a type walk here |
| 43 | **A `foreign` with evidence, referenced from INSIDE its own module in value position, is eta-expanded at arity 0** — `Maybe (List a)` compared inside `core/List.beni` emits `() => List$eq(List$eq$prim)` and crashes after a clean build. `Lower.targetArity`'s `.top` branch reads `bir.decls[…].params`, which `bir/Lower.newDecl` leaves 0 for a `foreign` | **done** | found by the doc-example gate on its first run; four doc examples are skipped until it lands |
| 44 | Check-tax leads, not built: `evidence_next` hash map allocated per binding group (≈ 4.8 % of `check`; needs `commitEvidence` to be fallible — a spec sentence first); `tagInstantiated`'s remaining traversals (≈ 2.5 %, needs a "constrained below" bit in the store); `constrain` +2.3 ms unattributed; six gpa containers per `Solver` | todo | `plans/check-tax.md` §5; each must be proved output-identical the way `copy_constrained` was |
| 45 | Boundary diagnostics about a defect in a sibling `.js` anchor their caret on the module's FIRST `foreign` declaration (`foreign_export_mismatch`'s extra-export arm, `foreign_unbound_reference`, `not_implemented` for a sibling import); `missing_main` underlines the file's first token (an `import`); two messages overrun the 80-column wrap where a type name is spliced in after wrapping, and print `Basics.Int` where the user wrote `Int` | **done** | found by reading the nine new `build/bad` goldens |

## Owner decision, 2026-09-19: **M4 first**

`plans/m4-plan.md` D5: the order is M4 slices 1–3, then effects, then M3d. Proceeding on the plan's
own slice order (§6), which is cache-first, socket-last (D1's recommendation — assumed with "M4
first", to be confirmed; the daemon-phase decisions D6–D9 are not needed before M4-5).

| # | Slice | State | Notes |
|---|---|---|---|
| M4-1 | The content-hash cache key, the unhashed sidecar (`plans/m4-slice-zero.md` §4's disposition table), the "produced by a clean check" bit, a `stat` column on `SourceStore` | spec in flight | spec first; fixtures: a module cached while broken is never reused, a sibling `.js` edit invalidates only that emit unit, a compiler-build change discards the cache |
| M4-2 | Pre-resolve BIR, AST, tokens, comments, diagnostics on disk (mmap, validated on load) | todo | corrupt-cache fixture per artifact; budget: cold start with a warm cache < 120 ms |
| M4-3 | The firewall cutoff: unchanged interface hash ⇒ dependents not re-checked; needs the five re-entrancy fixes and the three "pure per module" corrections | todo | the incremental-determinism matrix; the three warm budgets 15 / 60 / 25 ms |

## Owner decision, 2026-09-19: **`lazy` is parked**

It leaves M3d and returns only when a browser platform and a real large application want it (effects
will be in by then and make it cheaper). Its surface syntax is decided then, not now. M3d becomes
static multi-entry chunking plus the single-file `--release` bundle; its acceptance reads "a two-ENTRY
program splits and both entries run". `plans/m3d-plan.md` decisions 1, 3, 4 and 6 are thereby settled
(1 and 6 postponed with `lazy`; 3 yes; 4 as recommended); 2 (static chunking ships) and 5
(`--release --library` emits one chunk) stand as recommended. **Docs to mark** once no agent is editing
them: `backend.md` §10's PENDING blocks and `fast-compiler.md` §9.5's *The `lazy` marker* — "deferred
by owner decision, 2026-09-19", design text kept.

| # | Slice | State | Notes |
|---|---|---|---|
| 46 | **`beni check .` (and `fmt --check .`, `build .`) reject every file with `invalid_module_path`** — the walk does not normalise `./`; absolute and `../proj` forms work | in flight (worktree) | found by the robustness audit; no test anywhere passes `.` |
| 47 | `beni fmt` resets a rewritten file's mode to 0644 (a 0600 file becomes world-readable; a 0444 file is rewritten anyway) and replaces a symlink with a regular file, leaving the target unformatted | in flight (same slice) | temp + `rename` write path; one fix serves both |
| 48 | `beni dump` exits 0 while printing an error diagnostic; `frontend.md` §1 and `beni help` say exit 1, `src/main.zig:6-15` says it is deliberate | in flight (same slice) — manager decision: the document wins, `dump` exits 1 when it printed an error | |
| 49 | `tests/corpus/README.md` says the `fmt/` kind checks "the same comments in the same order"; `corpus_test.zig`'s `format()` does not (the AST dump drops plain `--` comments) | in flight (same slice) | ~10 lines to make the claim true |
