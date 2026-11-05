## 2026-11-05 04:04 CET — A function value goes where a value goes (#1773, #1775, #1776)

**What I did**

- Fixed three soundness holes of the v2 slot domain on `own2-holes-r3`, one commit each, on `own2-slot-pr`.
  In each, a call ran a function value that no label named, so the writes its code made relying on its
  callers, and its call count, were judged by nobody.
- The rule, in `ownership-v2.md` §2.11.3: a value that is one parameter function slot by every arrival is
  that slot. A call of it is a label. A callee label applied to it passes on as that slot's label. Any other
  function value that code the frame cannot see runs escapes there: its parameter function slots and the
  frame's closures, never its captures. That covers a call of it, a label applied to it, a known code's
  answer to a label, and a closure said into a label's supply.
- New file `FnRun.zig` (L9). The walk follows a call's result through the contracts settled at the walk,
  as the identity control does.
- Six `run/` fixtures. The three refused ones trap on the base.
- Oracle: 1 332 probes, 0 TRAP, 0 DIFF. The base traps on 31.
- Ledger vs the base: one accepted-to-refused, in a new fixture that traps on the base.
- The cost table is the same as the base.

**What I learned**

- An escape that a growing draft delivers later must be filtered like the first read. An `escape`
  subscription took every later leaf, so a list escaped and `FoldAccumulators` reached its summary-size
  limit. A separate `escape_fn` subscription keeps function objects only.
- Do not set a walk call's contract during the walk. The walk's own reads take `none` as "pessimistic"
  and have no contract table (`PrependFresh` crashed). Fill it only for the read that needs it.
- A closure handed to a label is cheapest to find where the read-off already says it into the supply
  (`hosted`). Two separate walks for it cost 96 records of `Dict.partition`'s growth.
- A diff3 conflict leaves a `|||||||` block even when the ancestor side is empty. Grep for it after
  resolving.
