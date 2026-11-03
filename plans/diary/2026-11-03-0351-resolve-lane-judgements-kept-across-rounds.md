## 2026-11-03 03:51 CET — resolve lane: judgements kept across rounds

**What I did**

- Built §2.12's kept judgements (#1714, wall 3) in a new file, `src/own2/Kept.zig`. The line types moved there from `Resolve`.
- A demand's key is its fields plus its target leaves and operand values.
  - A judgement records the later uses' footprints it read: `(call, parameter)` with the callee's read and write tree node.
  - It also records its place in the round's holder events: a holder keyed, a hold done, a holder's aggregated holds done.
  - What no key names is compared once a round, whole: candidates' results, conditions, labels and flags; drafts' results and labels; the escapes.
- A kept judgement is taken again with its line, its events (it keys the live holders again, as it did) and its operand and pending writes.
- Under `-Downership-full-cross-check`, every demand is judged and compared with the kept one. A planted mutation panics.
- GroupRotate at n = 64: 406 404 → 287 898 records, growth 51 561 → 0. The test now requires growth 0.
- Ledger, summaries, oracle and cost table are unchanged. The cross-check binary runs every ledger root and core with no panic.
- `meetRun` is not on the values branch, so step 2 was skipped. None of the 10 remaining build_test failures is in Resolve. Their profiles are on #1714.

**What I learned**

- Resolver state carries over from one judgement to the next. Holders are keyed lazily, and the aggregated lists keep their link order: the done list is read "first that adds". So skipping a judgement can change a later one unless the keying happens at the same moment. Logging those events and asking for an equal prefix makes the replay exact.
- Leaves are interned and walk values are fixed, so a demand's key can be compared across rounds by ids. Values that an evaluation makes are not interned. They only make a key miss, which re-judges and is still exact.
- In inference rounds, results come from the live drafts, and conditions and labels from the candidates of the round before. The round print has to cover both.
- Groups is at its 1 900-line target. Each hook there had to be paid for by joining comments.
