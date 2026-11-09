## 2026-11-09 13:21 CET — move the wall-clock bounds out of the gates

**What I did**

- Built option 1 of #2272, the owner's decision. Three gates tests had a wall-clock bound below the
  120 s hang guard: `build_test.zig`'s `generated_wall_ms` (2 s on the whole `dump` process, seven
  tests and thirteen generated modules of `ownership-v2.md` §7 item 6), and two in `abuse_test.zig`
  (a 3 s kill on the RECURSIVE ALIAS check, a 20 s kill on the 2 000-constructor case). They now run
  under the default 120 s and check only structure and answers.
- The generated modules moved to `tests/blackbox/own2_generated.zig`, and the abuse sources to
  `abuse_support.zig`, so that `perf_test.zig` times the same programs: one `.alone` scenario
  bounds each module's `ownership2_module` event at 2 s, which is what §7 item 6 says (after type
  checking, no process start-up), and two `.concurrent` ones bound the abuse checks in CPU time.
- Amended §7 item 6 and S4's owed item (d) in `ownership-v2.md`. CLAUDE.md does not name the bound.

**What I learned**

- On ReleaseFast the slowest generated module walks in 42 ms (`union_composition = 256`), against the
  2 s bound. The gates' bound timed process start, the front end and the checker on ReleaseSafe; the
  spec's measure was always the event.
- `test-perf -Dtest-filter=…` with a broad filter showed that `an annotation over a doubling alias
  DAG is linear in its depth` fails on master: its generator writes `( A, A )`, now
  `tuple_type_removed`. #2379. `test-perf` is not a gate, so nothing caught it.
- The devloop `waitFor` deadline (20 s), Chrome's start deadline (30 s) and the pending mode's 20 s
  case timeout are deadlines for a live child or outside the gates, not performance claims; left.
