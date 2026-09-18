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
| 4 | `foreign` + `where` arity check (`boundary.md` §4) | todo | owed 2; how `Sibling.zig` reads exports decides the shape |
| 5 | Two printer defects: `Render.writeRecord` 64-link flatten drops `| r`; `Schemes.Writer.max_depth` writes `<error>` with exit 0 | **done** | owed 3; each needs a fail-first fixture |
| 6 | Decision trees (M3b, `backend.md` §7) | spec **done** `ebacb5b`; code in flight (worktree) | spec is four lines; needs the same expansion §8 got |
| 7 | Rest of M3b — audit **done** (`plans/m3b-audit.md`): left are `?`, `Int32` (a language gap: owner decision), `--source-maps` honesty, sibling-import rewrite | todo | interpolation, tuples, record update already work |
| 8 | **Reachability DCE** (M3c) | todo | the adoption's only blocker (report 19 §14.1); re-take M4 after |
| 9 | Drop the 4×500 split in `bench/runtime` once #2 lands; re-take M5 | todo | measurement follow-up |
| 10 | `transparent-effects-proposal.md` §10 item 1 is stale (`Func` is n-ary now) | todo | docs; found by L1 |
| 11 | `Render.Namer.allocate` is quadratic: ~23 ms per 64-clause warning in Debug (0.1 ms ReleaseFast) | todo | found by slice 3; low priority |
| 12 | Effects: spec pass over `transparent-effects-proposal.md` §10 now that both blockers landed | todo | after M3b; a design pass, owner should read it before code |
| 13 | **M1 miscompile**: refutable pattern in a function/lambda parameter is an unchecked destructure (exit 0, wrong answer) | in flight (worktree) | manager decision: parameters obey `let`'s irrefutability rule (Elm's rule) |
| 14 | `check/Exhaustive.zig` reports nothing when `pattern_budget` runs out, so a non-exhaustive `case` can reach a default-free tree | todo | exit-0 hole documented in `backend.md` §7; make budget exhaustion a diagnostic |
