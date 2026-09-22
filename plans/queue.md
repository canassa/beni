# Work queue

> **PARKED 2026-09-19 by the owner.** No new agents after the one in flight (M4-3) finishes;
> implementation is on hold. Resume from [`plans/resume.md`](resume.md).

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
| 17 | `Int32`: absent from the language, listed in `backend.md` §1/§4 | **done** — built (owner decision 2026-09-19) | add `core/Int32` + a `language.md` paragraph, or strike the rows |
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
| M4-1 | The content-hash cache key, the unhashed sidecar (`plans/m4-slice-zero.md` §4's disposition table), the "produced by a clean check" bit, a `stat` column on `SourceStore` | **done** — nine commits; warm `check` 63 ms vs 131 cold (`--jobs=1`, 100k lines), warm ≠ cold never observed; cold-path writes cost 33 ms and stay serial until M4-2 | spec first; fixtures: a module cached while broken is never reused, a sibling `.js` edit invalidates only that emit unit, a compiler-build change discards the cache |
| M4-2 | Pre-resolve BIR, AST, tokens, comments, diagnostics on disk (mmap, validated on load) | **done** — warm `check` 62 → 39.5 ms, warm `build` 122 → 100.5 ms: the `< 120 ms` warm-start budget is met for the first time; `decode` (10 ms) is what is left, and it is M4-4's | corrupt-cache fixture per artifact; budget: cold start with a warm cache < 120 ms |
| M4-3 | The firewall cutoff: unchanged interface hash ⇒ dependents not re-checked; needs the five re-entrancy fixes and the three "pure per module" corrections | **done** `92cfca8`..`ed8385f` — a comment in a leaf re-checks 1 module of 634 (117 → 45 ms); **the cache is ON BY DEFAULT** (`.beni-cache/`, `--no-cache` to opt out); NOT met: a `pub` signature edit still re-checks 624 of 634 (127–134 ms vs the 41–47 predicted) because an importer's digest folds its imports' interface hashes transitively; warm floor regressed 41 → 44 ms (`dep_digest` re-serializes a record even on a hit) | the incremental-determinism matrix; the three warm budgets 15 / 60 / 25 ms |

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
| 46 | **`beni check .` (and `fmt --check .`, `build .`) reject every file with `invalid_module_path`** — the walk does not normalise `./`; absolute and `../proj` forms work | **done** | found by the robustness audit; no test anywhere passes `.` |
| 47 | `beni fmt` resets a rewritten file's mode to 0644 (a 0600 file becomes world-readable; a 0444 file is rewritten anyway) and replaces a symlink with a regular file, leaving the target unformatted | **done** | temp + `rename` write path; one fix serves both |
| 48 | `beni dump` exits 0 while printing an error diagnostic; `frontend.md` §1 and `beni help` say exit 1, `src/main.zig:6-15` says it is deliberate | **done** — `dump` exits 1 over an error (manager decision: the document wins) | |
| 49 | `tests/corpus/README.md` says the `fmt/` kind checks "the same comments in the same order"; `corpus_test.zig`'s `format()` does not (the AST dump drops plain `--` comments) | **done** | ~10 lines to make the claim true |

## Owner decision, 2026-09-19: **`--release` refuses `Debug`**

As Elm's `--optimize` does. A release build that REACHES `Debug.log`/`toString`/`todo` after
reachability elimination is an error naming the use sites. Consequences to handle in the slice:
the `run/` corpus's evaluation-order and callback-order fixtures observe order THROUGH `Debug.log`,
and their second pass under `--release` is what proved the wide inliner unsafe — so the harness
needs a hidden, test-only `--allow-debug` and must keep running them; `ReleaseDeadDebug`'s
`.release-expected` (the one place the two builds legitimately differed) goes away; `backend.md`
§9's "renaming is off when `Debug` survives" rule becomes unnecessary.

| # | Slice | State | Notes |
|---|---|---|---|
| 50 | `--release` refuses a build that reaches `Debug` | **done** | new code, fixtures, hidden `--allow-debug` for the corpus's second pass |

## Owner's stance, 2026-09-19 (the test for every restriction)

"Beni's job is to make the error guarantees — like Elm does — but not to enforce anything on the
devs. If devs need to reach for Int32 then let them." `Int32` was an EXAMPLE of this, not a feature
request in itself. So: a rule stays only if it protects a guarantee (no runtime exception, no silent
wrong answer, exhaustiveness, managed effects); a capability gap is filled inside the wall (core or a
platform), because only they may write `foreign`; where no guarantee is at stake, warn — do not
refuse. `--release` refusing `Debug` was confirmed by the owner AFTER stating this, on the ground that
`Debug.toString` reflects the representation the release optimiser must be free to change.

## Owner decision, 2026-09-19: **effects gets a full spike, and Effect-TS v4 is the gold standard**

"We need a full-blown spike and investigation… I want to achieve Effect-TS levels of quality and API
coverage." `references/effect` is vendored (Effect-TS/effect `main`, `4.0.0-rc.116`, shallow). Effect
has to deal with generators and TypeScript and beni does not — learn from it regardless. Agents
investigate, document and plan the spike; the spike itself follows M4 slices 1–3 (owner: M4 first).

| # | Slice | State | Notes |
|---|---|---|---|
| E-R1 | Research: Effect v4's runtime — fibers, scheduler, interruption, scopes/finalizers, the `Exit`/`Cause` model | **done** — report 21 | read-only, docs out: `docs/design/research/21-…` |
| E-R2 | Research: Effect v4's API surface — what "API coverage" means: the module map, what is essential vs TypeScript-induced, what maps onto beni's two-bit design | **done** — report 22 | `docs/design/research/22-…` |
| E-R3 | Research: errors, services/layers, resources, concurrency combinators, streams, schedule/retry — semantics beni must match or deliberately decline | **done** — report 23 | `docs/design/research/23-…` |
| E-P | The spike plan: fold E-R1..3 and `plans/effects-plan.md` into `plans/effects-spike.md` (slices, measurements, acceptance), for the owner | **done** — `plans/effects-spike.md`, `plans/effects-decisions.md` (16 / 11 / 9 decisions by tier; five-question shortlist) | |
| 51 | **A shipped beni program cannot log**: `Debug` is the only way to write a diagnostic line and `--release` refuses it (owner decision). Rule 7: fill the gap inside the wall — a platform logging function (`Node.log`/`Log.info…`), not `Debug` | todo — needs a small design (what it returns while there are no effects: a `Program` step? or wait for the `impure` bit) | found by report 22 §0 finding 5 |

## Owner decisions on effects, 2026-09-19 (sheet: `plans/effects-decisions.md`)

| Sheet item | Decision |
|---|---|
| **A6** — does `sync` ship in the first cut? | **(a) yes**, right after the two bits — it is the one guarantee-bearing item: without it there is no boundary check at all |
| **A1** — the runtime's failure value; what is a defect? | **Defects are FATAL, and it is `core/`'s and the platforms' responsibility that they never happen.** A throwing `foreign` is a bug inside the wall, not a condition beni code handles: no `Cause`, no defect in any type, no catching at a fiber boundary (JS fibers share a heap — a throw mid-operation leaves platform state nobody can vouch for). The process dies loudly — which `foreign`, the beni-level stack, the JS stack, non-zero exit — and the supervisor restarts it. **A stack overflow in user code is the same: a crash**, reported well. Finalisers are infallible (`-> ()`), so the two-failures-at-once case does not exist. The outcome type is **`Exit a = Done a \| Cancelled`**; expected failures stay inside `a` as `Result`. Supersedes r21 §11.6a and r22 D2 |

| 52 | **A fifth boundary check**: refuse a bare `throw` statement in a sibling `.js` (`Debug.todo` excepted) — a tripwire, not a proof: a host API that throws internally is invisible to a token scan | todo | follows from A1: keeping defects from happening is the wall's job |
| 53 | **Hostile-input suite as a standing requirement for every platform package** (the coverage audit's method: every `foreign` on empty / huge / astral / NaN / malformed inputs, must return, never throw), and a sweep of `core/*.js` and `platforms/node/*.js` for host calls that can throw unwrapped (`JSON.parse`, `new URL`, `fs.*`, `BigInt`, `decodeURIComponent`, `String.prototype.normalize`, `RegExp`) | todo | follows from A1 |
| 54 | **The crash reporter**: when a `foreign` throws or the stack overflows, the process dies with a beni-shaped report — which `foreign` (or which beni function overflowed), the beni call stack, then the JS stack — and a non-zero exit; today it is a raw Node trace | todo | follows from A1; dev builds first; needs names to survive `--release` renaming or a note saying to reproduce in dev |
| **A1, closed** — the seven remaining items, all as recommended (2026-09-19) | (1) **finalisers are infallible**: release functions return `()`; a finaliser that throws is a defect, so fatal. (2) **`Exit a = Done a \| Cancelled`** — no `Cause`, no defect variant. (3) **Interruption is invisible to the interrupted code**: never a value there, never caught; only finalisers run; `Cancelled` exists only for another fiber, through `await`. (4) **Both `await : Fiber a -> Exit a` and `join : Fiber a -> a`** — a cancelled child cancels the joiner. (5) **The interrupter waits for cleanup by default** (`interrupt`, `timeout`, `race`, the end of an `and` group), with an explicit fire-and-forget variant. (6) **Uninterruptible**: `bracket`'s acquire and release, all finalisers, and an explicit `Task.uninterruptible (\() -> …)` with `restore`. (7) **Children are interrupted first, then the parent's own finalisers run** — deliberately the reverse of Effect v4, which never argued its order (r23). Also settled: **A3**, `bracket`'s release receives the outcome (`Done a \| Cancelled`), and **A2** (`join` and `await` are two operations), **A10** (combinators return after their losers' cleanup), **A11** (children before parent finalisers) |
| **A5** — is `impure` used in v1, or only inferred? | **(a) used from the slice that infers it**: the `--release` optimiser consults the bit before dropping, inlining, merging or reordering a call, so there is never a window in which two `Ref.get`s can be merged. `language.md` §6 *Evaluation order* gains the exemption it already anticipates. Supersedes plan decision 4 |
| **A8** — what is `main` under effects; what does a dying program print and exit with? | **As recommended**: `main : Program` stays and its body must not suspend (enforced by A6's `sync` check); asynchronous work is spawned inside it, so the ~70 `run/` fixtures are untouched. **The process stays alive while any fiber is parked** (reference-counted keep-alive, as Effect v4 built after v3 exited with work undone). Exit codes **0** success / **1** failure / **130** interrupted by Ctrl-C; a defect crashes loudly per A1; **nothing ever fails silently with exit 0** (Effect's `runFork` wart is not copied). Needs a corpus kind that can assert a non-zero exit and stderr |
| **A7** — services | **Decided 2026-09-19, as recommended**: records of functions and `where` clauses now (both exist today; every T0/T1 signature is written this way); with the runtime, **three fixed per-fiber slots — clock, scheduler, log context** — inherited by children and swappable for a scope, not a general service locator; and the concession in writing that beni will not have Effect's proof that everything was provided at the entry point. **All five shortlist questions are now answered and folded into `plans/effects-spike.md` §0.1 and `plans/effects-decisions.md`** |
| 55 | **M4-3's two honest misses** (`plans/m4-3.md` §16): (1) a `pub` signature edit re-checks almost the whole project — the `iface_hash` term in the digest chain is load-bearing (`Solve.methodOnApp`, `Exhaustive.ctorUnion`, `Solve.allNullary` read records of modules never imported), and §16 records two candidate narrowings; (2) the warm floor went 41 → 44 ms because the digest pass re-serializes a whole record to hash it on a hit, where the entry's section could be hashed verbatim (~1 ms recoverable) | todo (parked) | §2's < 60 ms row for a signature edit is NOT met by a one-shot process today |

## Owner decision, 2026-09-19: **the browser platform comes before Node — beni is primarily a browser language**

What this re-weights (nothing here is started; implementation is parked):

| Area | What changes |
|---|---|
| **Platform order** | `boundary.md` §8 has B3 ports → B4 the browser platform → B5; a real Node platform (HTTP, file system) was my "critical path" step 3 and the browser step 4. **Swap them**: the browser platform and its UI architecture come first; Node stays what it is — the harness's platform |
| **Effects spike** | The plan lands the kernel in `platforms/node` (S5) and puts the Elm-Architecture question (P2 §6.6) out of scope. Both need revisiting: the kernel must be platform-neutral with the BROWSER as its first real host, and "what replaces The Elm Architecture under transparent effects" moves from a non-objective to a central question. A8's exit codes 0/1/130 and process keep-alive are Node notions — the browser half of "what is `main`" (mounting, a page that never exits, unhandled fiber death → console + an error boundary?) is undecided |
| **Runtime measurements** | Every number in reports 21 and 23 is Node-only, and report 21 says so: v4 yields through `setImmediate`, which browsers lack (`MessageChannel` / `scheduler.postTask` / `setTimeout` clamped to 4 ms after five nested levels); the yield-budget knee of 512 "is not transferable". The spike's E-M10 already asks for the browser half — it becomes the primary half |
| **Output size and loading** | Matters far more in a browser. The single-file `--release` bundle (−22 % brotli from concatenation alone), static chunking, and later `lazy` (parked "until a browser platform" — that condition is now the plan, so it un-parks WITH the browser platform, after effects) move up. Sibling `.js` is never minified and is 44–76 % of small programs' bytes: a browser-first language has to decide what to do about that |
| **Source maps** (M5) | Debugging emitted JS in browser devtools without them is poor; `--source-maps` is refused today. Moves up |
| **Testing** | The whole corpus runs under Node. A browser platform needs a headless-browser harness (or a DOM-less core it can be tested against under Node) — a harness design question before B4 |
| **What is unaffected** | The compiler, checker, cache, optimiser and `core/` are platform-neutral; rule 6's wall and the four boundary checks apply to a browser platform exactly as to Node |

## Owner decision, 2026-09-20: **un-park for RESEARCH only — a design pass on "what is a beni browser program?"**

Implementation stays parked; this pass changes no code. Same shape as the Effect investigation:
read what exists, measure in a real browser, end with a decision sheet for the owner.
`references/elm-browser` and `references/elm-virtual-dom` are vendored (shallow) beside `elm-core`.

| # | Report | State |
|---|---|---|
| B-R1 | **24 — Elm's browser runtime as built**: `Platform`/`Scheduler`/effect managers (`elm-core`), `Browser.*` programs, the virtual DOM (diff, patch, keyed, lazy, event delegation), animation-frame batching, ports, navigation — what each piece exists FOR, and which exist only because Elm has `Cmd`/`Sub`/`Task` | **done** `0ebdce5` — 12 of 25 pieces exist because of the browser; the scheduler never yields (372 ms, zero frames); 75.9 % of a counter is kernel JS |
| B-R2 | **25 — the design space for UI under transparent effects**: what a browser program looks like when an effectful call is just a call — TEA kept, TEA with effects in `update`, components with local state, signals/fine-grained reactivity, fibers per component; how Effect users build UI (`packages/atom`), Lustre, Leptos/Dioxus, Solid, React's concurrent model, Compose; rule 7 applied | **done** `d5c04c0` — C first (pure `sync` update, effects are fibers with a `send`); `sync` on update is a concurrency proof; ten owner decisions |
| B-R3 | **26 — the browser as a host for beni's fiber runtime, measured**: the event loop, the scheduling primitives (no `setImmediate`; `MessageChannel`, `scheduler.postTask`, `setTimeout` clamping, `requestAnimationFrame`, microtasks), the yield budget re-measured in Chrome, input latency under a busy fiber, what `sync` must cover (`view`, event handlers, rAF), loading/size budgets, and how a browser platform is TESTED (headless Chrome is on this machine) | **done** `3302367` — `MessageChannel` on a ~1 ms slice; a microtask yield is worse than none; one bundle loads 3.0× faster; harness 10 ms/fixture. Manager re-ran e3b and e8: reproduce |
| B-P | Synthesis: `plans/browser-decisions.md` (the owner's sheet) and `plans/browser-platform.md` (the design + slice plan, and what it changes in `plans/effects-spike.md`) | **done** — `plans/browser-decisions.md` (W1–W24, nine in tier 1, each with a recommendation) and `plans/browser-platform.md` (kernel, slices B0–B9, output track O1–O3, whole-project sequence). **Awaiting the owner on W1–W9.** Recommended first un-parked slice: O1, the single-file `--release` bundle |

## Owner direction, 2026-09-20: built-in JSX, and a UI as fast as Solid

The owner, after reading the browser design pass: **"I want built in JSX in the language. Also, clone
and research SolidJS 2. I want a Beni UI to be fast, as fast as solid, the runtime cannot be a
limitation."**

Three things, and they re-open part of `plans/browser-decisions.md`:

1. **JSX is a language feature**, not a library convention — so it is a `language.md` change (grammar,
   lexer, formatter, typing of elements / attributes / children / components) and the COMPILER sees
   markup. That is the opening Solid exploits: a compiler that sees the template can split static
   structure from dynamic holes and emit direct DOM updates, with no virtual DOM to diff.
2. **Solid 2 is the performance gold standard for UI**, as Effect v4 is for effects. Vendored:
   `references/solid` (`next`, 2.0.0-rc.9, with `packages/signals` — the new reactive core — in-tree)
   and `references/dom-expressions` (`next`, the JSX compiler and DOM runtime Solid is built on).
3. **"The runtime cannot be a limitation"** is a requirement on the ARCHITECTURE, not a tuning target.
   Report 25 ranked signals fourth and assumed a virtual DOM throughout (its own §13 lists "whether
   beni has a virtual DOM at all" as undetermined); W1's rider "`view` returns a data tree the platform
   renders" and W4/W10 rest on that assumption. **W1, W4, W5, W6 and W10 are therefore NOT to be put to
   the owner as they stand**; they are re-issued after the research below. What does not move: `sync`
   handlers, the scheduler (W3), the defect rule (W2), key namespacing (W7), callbacks (W8), `main`
   (W9), and report 25's finding that an `update` which may suspend is wrong.

The open question the research must answer with measurements: **can beni keep TEA's guarantees (one
model, atomic `sync` `update`, exhaustive messages, time travel) AND render as fast as Solid** — by
having the compiler turn JSX into templates whose holes are updated directly from the model — or does
Solid-class speed require signals as the programming model? Research only; implementation stays parked.

| # | Item | State |
|---|---|---|
| B-R4 | **27 — Solid 2 as built**: `packages/signals` (the reactive graph, ownership, scheduling/batching, async and boundaries), `dom-expressions` (what JSX compiles to: template cloning, hole walking, delegated events, `For`/keyed reconciliation), where the speed comes from piece by piece, what is there only because of JavaScript/TypeScript | **done** `62c7108` — the browser is the cost, then the compiler (available to TEA), last the graph; signals need no fiber slot after all |
| B-R5 | **28 — JSX in beni**: the language design — grammar in an indentation-sensitive language where `<` is an operator, typing, components and props with no currying and static dispatch, children, the formatter, what the compiler emits; prior art read from source (Mint, ReScript, Reason, Fable/Feliz, Leptos `view!`, Dioxus `rsx!`, Svelte, Marko, Imba) | **done** `2271159` — an element is an atom at operand start; quoted text; a tag is a name; typed holes; ~1 300–1 900 lines of Zig; J1–J5 |
| B-R6 | **29 — how fast, measured**: js-framework-benchmark in headless Chrome on this machine — vanilla, Solid 1.9, Solid 2 rc, Elm, Svelte 5, ivi/Inferno, Leptos — plus HAND-WRITTEN prototypes of what a beni compiler could emit: (a) virtual DOM, (b) TEA + compiled templates with per-hole change checks on an immutable model, (c) signals. Does (b) reach Solid? | **done** `740dd40` — TEA + compiled templates beats Solid 2 on script on 9/9 ops; a vdom is slowest; ranking re-run by the manager and reproduces, the 0.989 parity figure does not |
| B-P2 | Synthesis: re-issue W1/W4/W5/W6/W10, extend `plans/browser-decisions.md` with the JSX questions, revise `plans/browser-platform.md` | **done** — see the note below row 56 |

### A compiler defect found during the pass (2026-09-20) — recorded, NOT fixed (implementation is parked)

| # | Item | State |
|---|---|---|
| 56 | **A `()` pattern under a constructor is invisible to exhaustiveness.** `case (m : Maybe ()) of Just () -> …; Nothing -> …` and `case (r : Result String ()) of Ok () -> …; Err _ -> …` both report `MISSING PATTERNS · Just ()` / `Ok ()` and `beni check` exits 1 on a VALID program. A bare `case u of () -> …` is fine, and a nested tuple (`Just ( a, b )`) is fine, so it is `pat_unit` under a constructor; the AST is right, so the fault is in `src/check/Exhaustive.zig`. Reproduced by the manager with the installed binary. It rejects a valid program rather than accepting a wrong one, so no guarantee is broken — but `Result e ()` is the shape of every "did it succeed" effect (`setFavourite : HitId, Bool -> Result HttpError ()` in the worked browser program), so it must be fixed before any effects or browser work. Workaround: match `Ok _`. Owes a fail-first `tests/corpus/check/` fixture and a `run/` fixture | **done** `b160152` (the owner un-parked this one fix, red test first): `.pat_unit` hard-coded `alt = 0` where every other arm uses the union's `alts_start`; one arm in `Exhaustive.zig`; `run/UnitSubPattern`, `check/bad/RedundantPatternUnitArg`, `check/bad/MissingPatternsUnitArg` |

B-P2 is **done**: `plans/browser-decisions.md` revision 2 (W1–W45; W1, W4, W5, W10 withdrawn in place and
re-issued; seventeen in tier 1) and `plans/browser-platform.md` revision 2 (JSX worked program, the
template renderer, language / rendering / core tracks, experiment X1). **Awaiting the owner.**

## Owner direction, 2026-09-21: schemas as powerful as Effect's

On report 31 (derived codecs), the owner: **"We need something as powerful as Effect schemas. That's
the gold standard."** So report 31's question 1 is answered — the bar is Effect v4's `Schema`
(`references/effect/packages/effect/src/Schema*.ts`, `JsonSchema.ts`), not "lift the port generator":
one description of how data maps to a type, from which come the reader, the writer (which therefore
cannot disagree), validation rules, error reports with paths, defaults, renamed and optional fields,
tagged unions, recursion, and further interpreters (JSON Schema, test-data generators, equality).
The owner also asked why it would need new syntax. The manager's answer: it probably does not —
Effect's is a library of ordinary values, and beni can have the compiler supply the default schema
for a type the way it already supplies `eq`/`compare`, with differences expressed by ordinary
functions over that value. Report 31's "C needs its own surface syntax" was an assumption. Not yet
researched: Effect's Schema read as built (report 31 read only its exported surface), and a beni
design that matches it. Research only when the owner says; implementation stays parked.

### Schemas (2026-09-21) and a second compiler defect found on the way

Report 32 (`docs/design/research/32-schemas-at-effect-parity.md`) is the design for the owner's
direction above: a `core/Schema` library of inspectable schema values plus a `schema` declaration
that is pure sugar over it. 162 capabilities from Effect's `SCHEMA.md`: same 40, spelled differently
67, not needed 39 (JavaScript-only distinctions), cannot 14 (ten of them one thing — computing a type
from a type: pick / omit / partial), needs language help 2 (effectful reads). Twelve owner decisions
K1–K12. **Awaiting the owner.**

| # | Item | State |
|---|---|---|
| 57 | **A well-typed program that builds with exit 0 and THROWS at run time.** An annotated top-level value with no parameters and a `where` clause (`pub blank : List a where a.eq : a, a -> Bool` / `blank = []`) is emitted as a function of its evidence, and a monomorphic value defined from it (`blankInts : List Int = blank`) is emitted as a thunk `() => Blank$blank(Blank$eq$prim)` — but consumers read `Blank$blankInts` as a plain value: `List$length(Blank$blankInts)` → `TypeError: Cannot read properties of undefined (reading '$')`. Reproduced by the manager (two modules, `build --platform=node`, `node out/main.mjs`, exit 1). Spec gap: spike §8.1 says the checker refuses a constrained constant first, §10.10 scopes `constrained_constant` to INFERRED schemes, so the ANNOTATED case falls between them. This breaks the no-runtime-exception guarantee, so it outranks everything parked. Owes a fail-first `run/` or `check/bad/` fixture; the fix is either to refuse the annotated case too or to make the emitter and its consumers agree | **done** `aba6c04` (2026-09-22, on darwin): reproduced exactly — build exit 0, `TypeError` at load. **Two spec statements were wrong, not one**: spike §8.1 asserted the checker refuses a zero-parameter constrained declaration "so the backend never meets one", while §10.10 scopes `constrained_constant` to INFERRED schemes, so an annotated one walks past both. **Accepted rather than refused**, under CLAUDE.md rule 7: both fixes close the same exit-0 hole, so a refusal buys no guarantee and costs `Dict.empty`, which is the shape of the value anyone wants. A.25's reason — a function-typed value in flight must be a closure of known arity — is about FUNCTION-typed values, and a constant is not one, so the closure was never an arity fix but a type error the emitter wrote itself. One branch in `Lower.etaExpand`: at arity 0 the expansion is the CALL. §8.1, §8.2/A.25 and §10.10 corrected, A.85 appended; `tests/corpus/run/ConstrainedConstant` is the fixture, and with the branch reversed it is the ONLY test that fails. No `emit/` golden moved — every eta-expansion that already existed had arity above zero |

### Schema specification commission, 2026-09-22

**Normative contract:** [`schema.md`](../docs/design/schema.md), a new document;
report 32 remains research. The owner has now selected the fork: inspectable
description plus specialised top-level parse/print, success and failure paths
compiled, independent DCE, and one engine-owned context contract with differential
fixtures against the library path. This supersedes “fork remains open” in the
historical investigation entries below, not their measurement caveats.
Owner review accepted Q1/Q2/Q4/Q5/Q8/Q10; see schema.md A.2. `via` uses an
input schema plus fallible conversion with optional target checks, default none.
V1 defers Dict/tuples/BigInt; errors use ordinary Result with nonempty List Issue;
options use Effect defaults and bounded native recursion; the namespace has
schema/parse/print (+ parseWith/printWith), with typed operations in core/Schema;
recursion is explicitly nominal, Presence and Nullable separate. Raw-host
validation lowers to JsIr; the library uses the same host representation through
privileged primitives. Neither constructs an intermediate Value ADT.

Remaining owner decisions (recommendations and costs at the start of schema.md):

- Q3: defaults — recommend no v1 declaration defaults; explicit transformations remain.
- Q6: descriptions/tooling — retain endpoint and check metadata now; JSON Schema
  output and generators later. The representation clause is settled: read/write
  construction fails when Type contains an opaque target without a structural
  description; typed typeOnly retains optional checks, identity if none.
- Q7: patterns — recommend `Message.Encoded.Count`, including module qualification.
- Q9: differential gate — every schema fixture through both paths inside
  test-blackbox, with independent expected answers.
- Q11: stored-function ABI — preserve directional effects, settle H4 with P2
  before freezing the opaque representation.

**Q12 scheduling, clarified by the owner:** S1 and row 67 may run in parallel;
both must land before S2. S2–S4 follow their remaining decisions; S5 follows P2/H4.
The recorded M4-first slices 1–3 have landed; remaining M4 work follows this
schema sequence as dependencies permit. The specification revision contained
no code; S1 was then commissioned and completed as recorded below.
The native-recursion ceiling is an implementation proof obligation (row 69),
not an assumed portable 4,096-frame guarantee.

| # | Slice | State | Acceptance |
|---|---|---|---|
| Schema-S1 | Frontend, schema.md §2/§8 | **done**, 2026-09-22; row 67 fixed independently | Parser/AST, formatter, unresolved BIR and artifact v2; explicit pre-resolution refusal; 14 corpus fixtures + 3 black-box scenarios, red baseline verified; 464/464 hermetic, 283/283 black-box, fmt-check green |
| Schema-layout | Declaration record bodies, language.md §3–§4/§9 and schema.md §2/A.5 | **specified**, 2026-09-22; after S1, before S2 | Option A: brace-equivalent AST/BIR, aligned field and variant blocks, always-layout declaration formatting; red fixtures, recovery, fixed points and the three gates |
| Schema-S2 | Checker, §3–§4/§8 | after S1, row 67 fix and Q7 | Red interface/resolution/type fixtures; serialized/cache-hit endpoint and namespace identity; remove the temporary whole-input schema exclusion from resolver fuzz |
| Schema-S3 | Library and description, §5 | after S2, Q3/Q6, concrete API and row 69 proof | Red run fixtures for both endpoints, context, flip/projections, presence, recursion closure and host failures; H4 not claimed |
| Schema-S4 | Specialisation, §6/§10 | after S3, Q9 and row 69 proof | Red run/emit/DCE differential fixtures, all gates; add beni benchmark row and qualified measurements |
| Schema-S5 | Effects, §7 | after P2 and Q11 | All seven EFFECTS.md cases, both paths, directional interface bits and cancellation |

### Owner decisions on schemas, 2026-09-21 (report 32 to be revised around them)

- **New syntax**: the owner leans to a `schema` declaration, at feature parity with Effect's Schema
  including custom transformations.
- **The schema is the defined thing, not a type.** "We are defining a schema User, not a type User."
  `schema User = { … }` defines a schema; its two types hang off it and are reached through it, as
  in Effect. This REPLACES report 32's K4 ("the declaration declares the type too") and K9 ("no wire
  type"): both types exist from the first cut.
- **Names: `User.Type` and `User.Encoded`** (Effect's names). **No shorthand**: bare `User` in a type
  annotation is not the program type; a developer who wants a short name writes
  `type alias Person = User.Type` themselves.
- Nothing appears under an invented name (no `UserWire`), and no source is generated: the declaration
  is the only text, as `type` is for `eq`/`compare`.
- Follows from it (manager): a conversion carries both sides — `Conversion encoded a` — so the compiler
  can read a field's `Encoded` type off a `via`; validated types need a declaration form too
  (`schema Email = String via …`) or their `Encoded` side is unknown; a tag's literal text cannot be
  a beni type, so a tagged union's `Encoded` is a custom type and the text lives in the reader/writer.

### Owner decisions on schemas, 2026-09-22 — readiness review

These decisions supersede the conflicting recommendations in report 32 revision 2.
They settle direction; the revised representation and normative specification are still owed.

**Prototype, 2026-09-22:** the owner commissioned Sol implementation agents with
the manager planning and validating. The isolated ordinary-Beni prototype is
complete under `bench/schema-prototype/`: originally 50 exact assertions,
expanded to 54 at close-out in Node/Chrome, development/release and deterministic
jobs 1/8 output, plus two whole-diagnostic negative fixtures. It is a dated
research artifact, not a supported feature or `zig build` gate; `results.json`
is committed as captured. Evidence commit: **9a8f903**; report/plan/queue/
diary: **this close-out commit**, titled `📝 close out the schema prototype review`
(resolve with `git log -1 --format=%h -- plans/schema-prototype.md`; a commit
cannot embed its own hash). [Report 33](../docs/design/research/33-schema-prototype.md)
§4's added fifth bullet records the guarantee-shaped finding: custom endpoints
can bypass caller options, paths and depth with exit 0. Closed construction or
an interpreter owning context—not only field-schema composition—is needed before
fixing the representation. The gap is pinned, NOT fixed. Next: a specification
pass for that representation, H4, and namespaces/elaboration; none starts in this
close-out. No production compiler/core changes or schema syntax have landed.
The close-out reran all three project gates successfully; Beni fixture formatting
and staged whitespace checks also passed.

**Delegation, owner 2026-09-22:** "This is the kind of decision that you can take.
The guideline is to follow Effect standard." Use the pinned Effect implementation
as the default for routine schema semantics; resolve those autonomously. Bring the
owner material departures or unresolved language tradeoffs, not a question for
each library behavior. Existing explicit owner decisions take precedence.

**Compiled-library investigation, 2026-09-22:** the owner commissioned an
independent comparison with Zod before specifying whether `schema` declarations
compile or elaborate to an interpreted library. [Report 34](../docs/design/research/34-compiled-schemas-in-javascript.md)
and `bench/schema-libraries/` record source-built JavaScript subjects, shared
strict JSON payloads, fault paths, both directions, JSON and hand-written
references, startup, browser bundles and CSP behavior. This does not commission
the representation slice or change report 33's context guarantee finding.
Latest Typia 15 requires its native `ttsc` transformer: the owner approved
**latest Typia + supported `ttsc`** on 2026-09-22, superseding the original
`ts-patch` requirement rather than silently pinning an older version. The fork
remains open; a specialized static path and a dynamic interpreter can share
one inspectable representation and one context contract.

**Compiled-library result, 2026-09-22:** the final qualified capture is
`bench/schema-libraries/results.json` (SHA-256
`d33501cdab1f5253b29a6f947cc312c6655eefacc908d153b0351438bc673f1c`),
with nine fresh processes, 4,500 supported timed process-cells and 157,500
retained samples. It has no single-library verdict: per-operation ratios to Zod
cross in several rows, failure machinery is often a different path, and 91
pairwise orderings flip even between the three selected groups. Ahead-of-time
Ajv standalone and Typia show that small shipped specialized validators can be
competitive on this contract; dynamic composition, context ownership and
Effect-class semantics remain separate requirements. The source pointers are
committed at `c5ba612`; all eight implementations were built from those source
trees with no published implementation substituted. The complete predecessor
capture is retained compressed only as diagnostic evidence because an audit
found four generic flat-entry builders overstated browser size/cold import; the
whole matrix was recaptured after specializing those entries, rather than
splicing results. No production compiler, core, platform or build file changed,
and no schema implementation is commissioned by this close-out. Benchmark and
capture evidence is commit `6954730`.

**Numeric baseline, selected under that guidance:** `Schema.int` validates safe
integers on both decoding and encoding, matching Effect's `isInt` implementation
(`Schema.ts:7548`, `Number.isSafeInteger`). Exact large integers need an explicit
representation/conversion; Effect provides BigInt and BigIntFromString, while the
Beni counterpart still needs design inside the foreign boundary. Do not describe
lossless parsing of unquoted JSON numbers as Effect's default: its JSON getter
uses `JSON.parse` (`SchemaGetter.ts:1225`). Preserving original number text is a
separate investigation, not an owner-approved requirement from the preceding
recommendation. General floating-point values and finite/JSON-representable values
must remain distinct, as Effect's Number and Finite are.

- **Encoding may fail**, returning an ordinary `Result`, including custom transformations.
  This reverses K5's total-writing requirement. Neither direction throws; flipping must
  preserve failures in either direction.
- **Generic schemas take explicit schema arguments.** A container is given the schema
  for its contents, so two wire formats for the same program type remain selectable.
  `Page.schema (UserV1.schema ())` and `Page.schema (UserV2.schema ())` illustrate the
  agreed composition model; exact factory signatures remain to be specified.
- **Multiple schemas per module, with ordinary imports and qualified access** — K13(b).
  A module `Models` may declare `pub schema User` and `pub schema Order`.
  `import Models` permits `Models.User.Type` / `Models.User.parse`; explicitly
  `import Models exposing (User)` permits `User.Type` / `User.parse`. Exposing the
  schema brings only `User` into scope, not bare `Type`, `parse`, or other members.
  This does not commission a general-purpose namespace feature. The owner accepted
  the recommendation after clarifying that this is explicit exposure, not a wildcard.
- **Optionality and nullability are separate and composable, following Effect.**
  Required/non-nullable is the default; optional permits a missing key; nullable
  permits an explicit null; combining them preserves missing, null and a present
  value as distinct states through decoding and encoding. Collapsing missing and
  null requires an explicit transformation. This supersedes report 32 §4.4's
  `optional` rule that merges both into `Nothing`. Exact Beni syntax and the types
  representing presence remain to be specified; this decision does not introduce
  JavaScript `undefined` or general null values into Beni.
- **A tagged schema's `Encoded` is a custom union, not a flattened record** — K15(c).
  Each variant retains its own encoded payload type, so variants may share a wire
  key with different types. The accepted naming is `Message.Encoded.Text` /
  `Message.Encoded.Count` for encoded constructors and `Message.Text` /
  `Message.Count` for constructors of `Message.Type`. Both support ordinary
  construction and pattern matching. The codec maps those constructors to the
  declared discriminator and tags; JSON remains, for example,
  `{ "kind": "count", "value": 42 }`. A transformed field may be a `String`
  in the encoded payload and an `Int` in the program payload. These are agreed
  design forms, not implemented syntax; representation, resolution and lowering
  still need their specification pass.
- **Effectful schema transformations are supported in the intended design** — K10.
  Separating parsing and fetching is a developer choice, not a language restriction.
  Synchronous schemas may ship first, but before fixing the representation, investigate
  how inferred effects propagate through stored reader/writer functions and composition.
  The design must accommodate suspension and cancellation without requiring a second,
  incompatible schema API. This supersedes report 32 §5.7's recommendation to refuse
  effectful transformations; it does not establish that H4 is already solved or
  authorize implementation of the effects runtime.
- **Both `Type` and `Encoded` use the declared Beni field names.** `as` maps that
  field to its external key during reading/writing; it does not rename the field
  in `Encoded`. For `{ userId : Int as "user-id" }`, the encoded Beni record is
  `{ userId = 42 }` and the JSON is `{ "user-id": 42 }`. This applies consistently
  to all renamed keys, including keys that are valid Beni identifiers. Field types
  may still differ between the two sides because of transformations or presence.
  This supersedes report 32's wire-named encoded record fields and supports arbitrary
  external keys without adding quoted record fields to the language. `Encoded` is
  a typed Beni representation of wire data, not its exact JSON object spelling.

### Found on macOS, 2026-09-21 — output paths that differ only by case

| # | Item | State |
|---|---|---|
| 58 | **The output tree relies on case to keep names apart, and macOS (APFS) and Windows (NTFS) fold case.** `src/js/Emit.zig:1371` hardcodes the entry file as `main.mjs`; a module `Main.beni` emits `Main.mjs` beside it; on a case-insensitive file system they are one file, the entry shim is written second and wins, and `out/Main.mjs` imports itself — **build exit 0, then `SyntaxError` at run time** (31 of 277 `test-blackbox` cases fail on darwin, all downstream of this one). Verified on Linux by reading: the name is hardcoded, `platforms/node/beni.json` has no key for it, and the harness has the mirror hazard (`build_test.zig:1684` proves `--library` writes no entry with `!exists("out/main.mjs")`, which a legitimate `Main.mjs` falsifies there). **The same hazard, not yet hit**: `core/` and `platform/` are reserved output directories (`Emit.zig:1399-1400`), so a user module `Core.List` or `Platform.Node` lands in the same directory on those systems, and two user modules differing only by case (`Json.Decode` / `JSON.Decode`) collide too. Moving the entry name into the platform manifest (`boundary.md` §5.2 "declares … rather than hardcoding") is right but NOT sufficient — a declared name can still collide. The guarantee-shaped fix is two rules: (1) every reserved output name is one NO module path can equal under case folding (module segments start with a capital letter, so a leading `_` or a dotted suffix is unreachable — e.g. `_main.mjs`, `_core/`, `_platform/`, or the entry declared by the platform subject to that rule); (2) a build-time diagnostic when two output paths are equal under case folding. Touches the `emit/` goldens, `backend.md` §2/§10 (the single-file bundle names `out/main.mjs`) and `boundary.md` §5.2 — a spec decision first (rule 1). Also unexplained on darwin: `abuse_test` "5 000 empty modules" hit the 60 s timeout once (possibly a cold cache — re-run before chasing) | **done** `8fff2cd` (the spec) and the commit after it (2026-09-21, on darwin): spec first, then red tests, then the fix. `backend.md` §2 gained *The output tree does not depend on the file system's case sensitivity* — the guarantee (**a build's output is the same set of files on every file system**) and the two rules; `boundary.md` §5 and §5.2 gained the `"entry"` manifest key and its constraint; `language.md` §10 gained `output_path_collision` and `invalid_entry_file` (and its positional row labels, which had drifted, were corrected). Reserved names are now `_main.mjs`, `_core/`, `_platform/`. The `emit/` and `emit/release/` goldens moved by **import paths only** — every changed line is `./core/` → `./_core/` or `./platform/` → `./_platform/`, proved by rewriting the new side back and diffing to empty. Cost: bench/corpus 128 369 → 128 415 raw (+46, one byte per import specifier), 22 476 → 22 472 brotli (−4); release 57 486 → 57 532 raw, 15 647 → 15 720 brotli; the floor 2 147 → 2 149 raw in 5 files, release brotli 789 unchanged. The 31 darwin failures are gone; `zig build test` and `fmt-check` green, `test-blackbox` 279/280 with the one failure being row 59 below |

### Found while fixing row 58 (2026-09-21) — recorded, NOT fixed

| # | Item | State |
|---|---|---|
| 59 | **`abuse_test`'s "5 000 empty modules" is flaky on Apple Silicon at `--jobs=1`, against the harness's 60 s `CompilerTimeout`.** Measured on darwin with a warm cache, five runs of `check --jobs=1 src` over 5 000 empty modules: **12.05 s, 26.11 s, 59.16 s, 61.16 s (the failure), 24.29 s**. The default-jobs run beside it is **6.00, 6.00, 6.08 s** — three runs inside 80 ms. The work is identical and deterministic, so the variance is not the compiler: USER cpu time for the same run varies **6.77 s to 16.22 s**, which is the signature of a single-threaded process being scheduled onto an efficiency core rather than a performance core. The timeout was **not** raised — the owner's instruction was to measure before touching it, and the honest reading is that a wall-clock deadline cannot separate "hung" from "on an E-core" on this hardware. Options, none taken: pin the bound to cpu time rather than wall clock; raise it; or drop `--jobs=1` from this particular abuse case and keep the determinism claim in the determinism test, which already runs the corpus at `--jobs=1` and `--jobs=8`. Unrelated to row 58: `check` writes no output, so neither new check runs on this path, and it failed the same way before that work started. Frequency measured: **`test-blackbox` was green on 3 of 4 consecutive full runs** of the finished branch, red on the fourth, always this one case. **Done** `9171e08` (2026-09-22): the bound is now per-run — `world.default_timeout_ms` 60 s everywhere, `world.bulk_timeout_ms` 300 s (five times the worst measurement) for this one case. **A cpu-time bound was the first choice and was withdrawn**: reading a LIVE child's cpu time needs per-pid rusage (`proc_pid_rusage` on macOS, `/proc/<pid>/stat` on Linux), neither is in std, and `getrusage(RUSAGE_CHILDREN)` counts only children already reaped — so it says nothing about the run being bounded. Two non-portable syscalls in a test harness was the worse trade. The numbers and that reasoning live in the harness doc comment |
| 60 | **The `--release` size figures quoted in `CLAUDE.md` are stale by about 1.9 kB.** It says `bench/corpus` fell *126 436 → 55 593* raw and *21 840 → 15 017* brotli. Measured today on darwin with the binary at `9ce4f65` (row 58 reversed out), the same corpus is **128 369 → 57 486** raw and **22 476 → 15 647** brotli. The −31% claim still holds and nothing about the release optimiser is in question; the absolute numbers were recorded at an earlier commit and core has grown since. Row 58 moved them by a further +46 raw, which is how the gap was noticed. Not corrected in place, because the right fix is one re-measurement of every figure in that paragraph against one binary rather than patching the two that happened to be checked | todo |

### Schema prototype close-out, 2026-09-22 — recorded, NOT fixed

| # | Item | State |
|---|---|---|
| 61 | **Nested recursive descriptions omit child definitions.** The close-out's dedupe probe nests recursive `WireNode` as `inner` inside recursive `NestedNode` (whose `children` recurse to `NestedNode`). `Schema.describe` returns only the outer `NestedNode` definition on both sides, leaving `ReferenceShape "WireNode"` unresolved. No duplication occurs in this case: `recursiveEndpoint` replaces the description with a singleton, while the undeduplicated `List.append` belongs to `object2Endpoint`. The full observed result is pinned by `nested recursive description omits child definitions (limitation)`. This is a different defect from custom endpoints dropping context. No fix: definition collection/reference closure belongs to the next representation specification, not this dated artifact. | recorded; future representation slice |

### Found during the compiled-schema investigation, 2026-09-22 — recorded, NOT fixed

| # | Item | State |
|---|---|---|
| 62 | **Typia 15's default strict-object diagnostic shortcut can lose the surplus key's path.** With every optional property present plus an extra key, the generated key-count check reports the containing object, not the key. The research fixture requests native per-key diagnostics with a never-valued template index signature; that extra traversal remains timed. No upstream or Beni production fix. Also, this latest release replaced the requested `ts-patch` route with native `ttsc`; the artifact is not evidence for Typia 12/ts-patch. | recorded in report 34 and its generated proof |
| 63 | **The existing Effect rc.116 source already has an opt-in compiled-schema registry.** `internal/schema/compilerRegistry.ts` defaults to interpreted entries but can install compiled fast paths and diagnostic/effect fallback through the same public parser APIs; `unstable/schema/SchemaCompiler.ts` documents that contract. Report 34 measures only the requested default baseline. Measuring the optional compiler is a separate follow-up, not silently added to the matrix or used as an unmeasured performance claim. | investigate only if commissioned; no production change |
| 64 | **JSON-shaped parity does not establish arbitrary JavaScript encode parity.** Ajv and TypeBox accept an explicitly present optional `undefined` where the artifact's absent-or-string rule rejects it. Separate untimed probes preserve those outcomes; measured inputs are JSON-shaped. Beni does not inherit JavaScript undefined from this comparison, and no hand-written repair was added to those rows. | recorded; boundary-spec consideration |
| 65 | **Typia 15 emits an accepting `undefined` branch for a `never`-valued template index signature.** The generated predicate is `null !== value && undefined === value`; a surplus key matching `__beni_schema_never__*` whose value is undefined passes and is then stripped by the research adapter's mapping. The index signature introduced to obtain exact native fault paths therefore preserves the timed JSON-shaped domain, not arbitrary JavaScript closed-object semantics. Report 34 records the generated evidence and a separate executable counterexample; no upstream patch or Beni implementation. | recorded, NOT fixed |

### Found during the schema specification, 2026-09-22 — recorded, NOT fixed

| # | Item | State |
|---|---|---|
| 66 | **The requested effects-plan §H4 anchor does not exist.** `plans/effects-plan.md` has no H4 heading or schema obligation. H4 is report 32's name; `bench/schema-prototype/EFFECTS.md` supplies the actual seven acceptance cases. `schema.md` §7 links those and leaves the nominal stored-function/interface ABI unresolved. The effects plan needs an explicit obligation before P2 can be treated as discharging it. | planning follow-up; no effects decision taken |
| 67 | **Numeric literals do not unify through primitive type aliases.** Owner confirmation, 2026-09-22: `type alias T = Int` / `val : T` / `val = 1` reports `kind_mismatch` locally and through imports; Float aliases fail too. Record aliases pass. The original imported `Models.User.Type = Int` probe used `beni 0.1.0-m1 aa57fab71568ff4271a7090db1db11d6`, `check --no-cache --diagnostics=json`, exit 1. This is a confirmed checker defect in well-typed programs, broader than the original imported-only observation. Schema primitive aliases depend on it. | **done**, 2026-09-22; `unifyAlias` now checks the constrained kind against the alias root rather than the flex variable. Fail-first `check/good/NumericAliasLiterals` covers local/imported Int and Float, alias chains, both unification orientations, record controls and preserved interface names. The same operand defect also rejected appendable String aliases; that case is included. No kind rules changed |
| 68 | **Synchronous closed schema builders and the future opaque effects ABI still need executable proof.** Report 33 proves two endpoints in transparent aliases, not closed heterogeneous builders preserving context plus directional effect information. `schema.md` §5 specifies semantic vocabulary, not an existential ADT or a cast; the accepted Q1/Q10 semantics still need a concrete builder API before S3, and Q11/S5 require the seven effects cases before freezing the ABI. V1 uses explicit nominal recursion. Q6 still owns JSON Schema/generator metadata. The opaque-target rule is settled in schema.md §5/A.4: read/write construction fails when Type contains an opaque target without a structural description; typed projections keep optional checks. | S3/S5 design and implementation acceptance; not decided by fiat |
| 69 | **A portable native-recursion ceiling needs generated-code evidence.** Bounded native recursion is decided; default 512 and ceiling 4,096 are numeric candidates. Queue row 39 already records a different core function overflowing around 3,700 calls, so 4,096 is not automatically safe. S3/S4 must account for interpreter/worker helper frames, conversion nesting, JSON output and pre-existing caller stack in supported browsers and Node, establishing the ceiling and boundary behavior required by G1/G3. No measurement run or fallback architecture chosen in this revision. | S3/S4 acceptance before shipping; does not block S1 |
