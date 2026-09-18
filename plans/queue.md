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
| 26 | `check/Cycles.zig` and `js/Reach.zig` duplicate one edge walk with nothing mechanical keeping them in step | todo, low | hoist the three-leg walk into a shared module both import, once no agent is in `src/js/` |
| 27 | M3d: design pass **done** — `plans/m3d-plan.md`; **`lazy` is hard-blocked on effects; six owner decisions** | waiting on owner | the undisputed part (static multi-entry chunking, single-file `--release` bundle: −22 % brotli on `Dictionaries` from concatenation alone) is specified in `backend.md` §10 and can be built once `--release` lands |
| 28 | M4 design-readiness audit **done** — `plans/m4-plan.md`; **nine owner decisions** (disk cache before daemon; ordering `--release` → M4-0..3 → effects → M3d; …) | waiting on owner | slice zero does not exist: `beni check` cannot consume a serialized interface, there is no interface hash or comparison; `Session.run` is not re-entrant |
| 29 | **Interface bytes embed a whole-program `TypeId`** (`Interface.Term.app`/`alias`), so adding a type to ANY earlier module renumbers untouched modules' interfaces and would defeat §8.1's firewall | **done** `792bf76` | write `(module name, type name)` — or an interface-local type index — instead of the session id |
| 30 | M4 follow-ups from slice 29: the dispatch table embeds `Graph.Index`/`TypeId`; Reach edges embed `Graph.Index` and read other modules' tables; the interface `symbols` column is interner-local (write as text, re-intern on load); `Types.build`/`aliasBody` are whole-program Bir reads; `Schemes.Writer.attach` is not idempotent | waiting on owner (M4 plan D1–D9) | all are M4-0/M4-1 work per `plans/m4-plan.md`; none is observable today |
| 31 | **`beni check` cannot check a program that imports its platform** (`import Node` → `unknown_module`; `--platform` is a `build`-only flag) — so the editor/CI "just type-check it" path does not exist for any real program | **done** | find what `boundary.md`/`frontend.md` say; likely `check --platform=<name>` sharing `build`'s package resolution |
| 32 | `bench/size.mjs` total line mixes a netted `raw_bytes` with a gross `release_raw_bytes` (reads as release being LARGER); compare `gross_*` with `release_*` | **done** | found by the state-of-the-compiler pass |
| 33 | Emit is 1.74× C0 on 26 % more `JsIr` nodes for the same output bytes (statement-form lowering, trees); check tax is +24.5 % vs C0 (morning +20.3 %) — both far inside budget (12× and 5×), recorded so the trend is watched | watch | `plans/state-of-the-compiler.md` §3, §8 |
| 34 | M3c slice 2, field ambiguation: **specified and declined** — 0.07 % brotli across 109 trees, 0.71 % best case; the corpus has almost no records. Revisit when field names reach ~5 % of generated bytes | closed (measured) | `backend.md` §9 *Item 4*, `plans/release-notes.md` K–N. **Owner question flagged**: should `--release` refuse `Debug`, as Elm's `--optimize` does? |
| 35 | **M4 slice zero**: serialized interface (LE, `symbols` as text), SipHash128 interface hash, `--roundtrip-interfaces` acceptance matrix (cold ≡ round-tripped over the whole corpus at `--jobs=1/8`), churn by hash | spec **done**; code in flight (worktree) — manager decision: start it, it is identical under every answer to D1–D9 and purely additive (two hidden flags) | `checker.md` §7 *The serialized form*, `fast-compiler.md` §8, `plans/m4-slice-zero.md` |
| 36 | **`String.indexes`/`indices` answer in UTF-16 code units** (`core/String.js:76-85` is `indexOf`), while `length`/`slice` count code points — wrong answer at exit 0 on any astral character | in flight | found by the coverage audit; repro in scratchpad `audit/defects/IndexesAstral.beni` |
| 37 | Two `main`s are reported under the code `missing_main` / title "MISSING MAIN" (`src/js/Emit.zig:617`) | in flight (same slice) | needs its own code |
| 38 | Nine `core/` doc examples do not compile (six are `f -1` parsing as binary minus; `Tuple2`; bare `toString`); the platform's missing-runtime diagnostic points at the user's first line | in flight (same slice) | docs + span |
| 39 | `List.map2`–`map5` overflow the stack at ~5 700 / 4 900 / 4 200 / 3 700 elements (the only core functions linear in stack; everything else survived 4 000 000) | in flight (same slice) | `backend.md` §8 lists them as accepted; they are four `foldl`-shaped rewrites away from not being |
| 40 | Corpus walker cannot express: a `check/bad` kind that carries a platform (unlocks 6 boundary codes), a build-that-must-fail kind (`missing_main`, `main_not_program`) | todo | 10 of 107 diagnostic codes are blackbox-only for this reason; design call on layout |
