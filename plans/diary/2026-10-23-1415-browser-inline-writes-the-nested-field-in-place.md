## 2026-10-23 14:15 CEST — browser-inline writes the nested field in place

**What I did.** Slice R7 of #315. After R6, an accepted nested write
`{ model | cup = { cup | tea = 4 } }` lowered as `let a=e,b=a.a;b.b=4;a.a=b;e=a`
in a release `browser-inline` handler: two stores that change nothing. The
outer update stored back the object its field already held, and the handler
stored the model back into itself. `Lower.sameFieldObject` drops the first:
the value is an update whose base is `m.c` (directly or through a `let`) and
`m` is the outer base. For the second, `directArmFields` answers the `model`
handle itself when the arm's value names the model's object. The handler in
`platforms/browser-inline/zig/inline.zig` compares the handles and writes no
`model = next` (`Interface.zig`'s doc comment says so, with no version
change). The release handler is now `e.a.b=4;i()`. New fixtures:
`emit/release/inline/NestedFieldWrite` and its page
`browser/inline/NestedFieldWrite`. `OldValueAfterWrite`'s comments describe the
hoist (`let b=e.a;e.a=e.a+1;e.b=b`). The emit golden is red with the fix
stashed. `./rr check` passes on unique-components and big-component (sizes 1,
16, 64 and 256, seeds 1–3).

**What I learned.** Once no arm reassigns the model, §9's optimiser folds more
than the handler. It also folds every binding's `let a=e.b` into its use,
because the model is now a name nothing reassigns. Most of the
`emit/release/inline/` goldens got smaller this way. The sanitiser needs both
skips off: there the inner update answers a copy, and both stores are real.
