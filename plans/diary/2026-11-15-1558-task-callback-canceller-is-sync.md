## 2026-11-15 15:58 CET — Task.callback's canceller is sync

**What I did**
- Reproduced #1649 on master `e72a8bfd80`: a `Task.callback` canceller that calls `Task.yieldNow` checked with exit 0. PR #1615 had not added the mark, and `Task.callbackWith` no longer exists.
- Marked the returned canceller `sync` in `core/Task.beni`: `callback : sync (Resume a → sync (⊤ → ⊤)) → a` (transparent-effects-proposal.md §17.1 item 3, §15.2 item 1). The checker needed no change.
- Added `tests/corpus/check/bad/TaskCallbackCancellerSuspends`: `sync_boundary`, with the chain to `Task.yieldNow`.
- Blessed six worker `emit/` goldens (the worker fingerprint hashes core) and shifted the Task rows of `tests/corpus/ownership/core.v2.unchecked` by two lines.
- Opened #2519: `Listen.each` and `Hosted.hook` (`Sub.on`) have the same unmarked remover.

**What I learned**
- A `sync` mark on the result of a `sync` parameter already works: the demand travels and the error falls on the argument.
- `beni check --diagnostics=json` writes to stderr.
- `core.v2.unchecked` holds line ranges of core, and a filtered `-Dcorpus` run does not bless it (`staleKnown` skips filtered walks). A doc line added to `core/` moves it.
