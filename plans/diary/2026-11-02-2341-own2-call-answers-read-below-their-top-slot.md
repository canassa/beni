## 2026-11-02 23:41 CET — own2: call answers read below their top slot

**What I did**

- #1716 was a soundness hole. The read-off described an open item of a call's
  below-key (a fold's answer) at its top slot only, so `Dict.partition`'s
  contract said its values were `shared`. Under `--sanitize-lists`, an edit in
  place of a list the argument held trapped. Fix: widen the open item, and skip
  atoms that an open entry above already holds (`Held.zig`, L7). Fixture
  `run/SanitiserPartitionHolds`. Spec §2.10 *Read-off* and the §5 table.
- #1736 and #1735 stopped at a wall. Rows that work: `Fiber` as a cell,
  `spawn` `cellempty`, `join` `lent`. They give 0 TRAP on 49 probes and the
  join probes are accepted. A v2 row in `Task` brings 129 scheduler helpers
  under `check_test`'s pin guard. The patch is in scratch, and the options are
  on #1736.

**What I learned**

- Widening alone took `Schema.shapeOf` from 256k to 578k records. Almost all
  of that was `inspection` from a per-entry scan, plus restating fresh objects
  that an open entry already said. Charged as one draft lookup (as `arrive` is),
  and also applied on the subscription path, it is 260k.
- Core is checked when the binary is built. `dump core` prints the packed
  blocks, so debug prints show only in `zig build`'s core check. Use
  `dump --core core/X.beni` for live accounts and per-category numbers.
- Four ledger a2r positions (HttpAnswer, HttpSendBody, Words) came only from
  Schema passing its limit. Check limit lines before reading a2r rows.
