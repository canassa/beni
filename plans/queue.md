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
