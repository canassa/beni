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
| 1 | Stale "numbers only" hint in `Diagnostics.zig` | in flight | found by L1; `<` is no longer numbers-only |
| 2 | **Tail-call loop** (M3b, `backend.md` §8) — spec, then code | spec in flight | must precede effects; lets `foldl`/`foldr` leave `foreign`; closure-capture hazard is the exit-0 risk |
| 3 | `ambiguous_method_receiver` on by default + hard cap on inferred `where` count | todo | owed 4/5; manager decision: yes to both, cap 64; spec §10.9/§6.4 amendment first |
| 4 | `foreign` + `where` arity check (`boundary.md` §4) | todo | owed 2; how `Sibling.zig` reads exports decides the shape |
| 5 | Two printer defects: `Render.writeRecord` 64-link flatten drops `| r`; `Schemes.Writer.max_depth` writes `<error>` with exit 0 | todo | owed 3; each needs a fail-first fixture |
| 6 | Decision trees (M3b, `backend.md` §7) | todo | spec is four lines; needs the same expansion §8 got |
| 7 | Rest of M3b: interpolation, `?`, tuples, record update, `Int32` — audit what is actually missing | todo | start with a read-only audit against `backend.md` §4's table |
| 8 | **Reachability DCE** (M3c) | todo | the adoption's only blocker (report 19 §14.1); re-take M4 after |
| 9 | Drop the 4×500 split in `bench/runtime` once #2 lands; re-take M5 | todo | measurement follow-up |
| 10 | `transparent-effects-proposal.md` §10 item 1 is stale (`Func` is n-ary now) | todo | docs; found by L1 |

## Known-stale statements to fix in passing

- CLAUDE.md "Still to come are saturated calls in the backend" — the diary's
  n-ary entry says the backend's currying was deleted in that slice. Verify,
  then correct.
