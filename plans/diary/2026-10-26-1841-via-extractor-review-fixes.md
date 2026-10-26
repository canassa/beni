## 2026-10-26 18:41 CET — via extractor: the review's fixes

**What I did.** The review of #925 (the `via` extractor written in beni, #883) asked for six
things. F1, high: an extractor that may suspend was accepted, beni or `foreign suspends`. A
lowering calls it while the event is dispatched, outside any fiber, so it is now held `sync`:
a demand of kind `extractor` on its scheme (`check/Effects.zig`, `check/Vocab.zig`), checked
once the effects are inferred, `sync_boundary` at the event whose `via` names it
(`check/Sync.zig`). Spec first: `checker-v2.md` §25.8 and `boundary.md` §9.3, dated
2026-10-26. Fixture `check/bad/core/ViaSuspends`: a beni extractor over `Js.suspending` and a
`foreign suspends` one, both refused; red before. F2: `check/bad/core/ViaNamesPrimitive` pins
the declaration-kind filter (`via` naming a `pub markup` is `unbound_variable`). F3: issue
#1096 for the older side effect (a vocabulary fault reaches the program as a type mismatch on
the wildcard attribute). F5: the unannotated-value message prints the declared payload type.
F6: the Chrome run of `browser/dom/BeniVia` did not run: its queued job was stopped for
memory pressure, and only the owner restarts a stopped job. Gates green through `heavy-run`
on base `fe7af05f1`.

**What I learned.**
- A demand kind is cheap to add: `Effects.DemandKind` names it, `Sync.regionOf` places it
  (the region is the event's declaration), and the message is one arm. A kind not in the
  roots list is `sync_boundary`, not `must_not_suspend`, which is the right code for a
  callback a host calls.
- The `check/bad/core` goldens hold line numbers; a header comment that quotes them must be
  checked against the regenerated golden, not written from the plan.
- A heavy job that reaches `GATES GREEN` and is then stopped while a second job waits in the
  queue loses only the second job. Read the log before assuming the whole chain is gone.
