## 2026-11-23 10:54 CET — `view` lets and statements on browser-inline

**What I did.** A program's `view` on `browser-inline` may now be `let`s and statements around
markup (`browser-inline.md` §8.2, amended 2026-11-23; interface 1.30). A `let` one binding
function reads is evaluated there; one that several contexts or an event read is a memo node, an
entry of its own in the `let`'s read set, before its readers, writing a slot. Statements run in one
entry, first, in the buckets of what they read; the write-set pass now records their reads. Any
other `let` must be pure and total. Six `browser/tea` pages copied to `browser/inline` (five with
tea's transcript, `ReentrantSend` with two listed differences), three new pages, three refusals,
one release golden. The inline sweep of the 357 tea/dom pages went from 104 to 110 by my script
(the #2614 diary's 108 is the same master counted another way).

**What I learned.** Turning `view_lets` on alone was unsound: the lowering never called
`programViewStatements`, so a `Debug.todo` statement was dropped without a word. The review
found a worse one: binding functions bound the `view`'s `let`s after entering a helper, by local
number, so a helper's parameter read the `let` (wrong pages, a `ReferenceError`). `let`s are now
bound level by level as each context is entered, tested only against values of the same
declaration. Root `if`/`case` bodies (8 pages) need branch regions, the next slice.
