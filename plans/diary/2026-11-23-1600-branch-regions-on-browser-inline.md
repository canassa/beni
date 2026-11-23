## 2026-11-23 16:00 CET — branch regions on browser-inline

**What I did.** `browser-inline` compiles a branch region (`browser-inline.md` §8.2, amended
2026-11-23; interface 1.31): a `view` whose body is an `if`, a `case` or a helper call, and a hole
whose branch reads what it binds. Each arm is a unit like a `For` row's (template, `make`, `set`);
one entry in the read set of the whole branch chooses the arm once per pass, evaluates its values,
then the runtime's `armShown` swaps the arm's node when the arm changed and runs `set`. A branch in
an arm is a region of the arm's unit. Lower gives two new facts: whether choosing an arm may have an
effect, and which arm never returns (`Debug.todo`). 15 `browser/tea` pages copied to
`browser/inline` (9 with tea's transcript, 6 with listed differences), five new pages, six
refusals, one release golden. The inline sweep of the 357 tea/dom pages went from 110 to 125 by
the same script on the same master.

**What I learned.** `memos` returned early for a `view` with no root, and it is where the
statements' entry is put: a `_ = Debug.log` before a root branch was dropped without a word. A
`let` that only an arm's markup reads is not seen through the branch's value: a region must read
its arms' values too, or the `let` is never bound (`ReferenceError`). Making such `let`s memo nodes
keeps a `Debug.log` in them to the passes that write what they read, which differs from tea's
every-render `view` as the statements' rule already does.
