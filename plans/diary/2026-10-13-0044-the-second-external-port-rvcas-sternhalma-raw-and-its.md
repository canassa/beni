## 2026-10-13 00:44 CEST — The second external port: rvcas/sternhalma, raw, and its ownership count

**What I did.** Ported Lucas's Sternhalma (Chinese Checkers, Elm 0.19.1, commit `ffb3f91b`, BSD-3-Clause)
to `examples/sternhalma` module by module, following Bike Wars' precedent: `PORTING.md` lists every kind of
change, the licence and attribution headers are kept, and the raw port is its own commit. Elm's `Array`
is `List` (`List.get`/`List.set`, the conversions dropped). The game is played by drag and drop, which beni
could not express: the html vocabulary had no drag events and there is no general `on`, so I declared
`onDragStart`, `onDragEnd`, `onDragOver` and `onDrop` (delegated) as `onMouseMove` was declared, amended
`boundary.md` §9.8.10, and gave the page driver a `drag` step (re-recording the browser run hashes, whose
digest holds the driver's bytes). The port's own `index.html` loads Tailwind's browser build, since beni has
no CSS pipeline. A play script (two players, steps, a rejected drop, a cancelled drag, a multi-jump, New
Game) passes in development and release. Research 88 counts the ownership dump: 12 demands, 4 rejected
(3 `top-level`, 1 `call`), identical on both platforms; three probe edits clear them all.

**What I learned.** The play script cannot be a corpus case: the case's floor is over the 4 300M budget
before any move (dev build 608M, release 1 219M, two loads of a 121-cell page under happy-dom, the
dev-against-release fuzz; a one-click script is 4 592M, the whole script 4 992M). I held it in
`examples/sternhalma/play/` and reported it rather than raise the budget. With prepends no longer demands
(slice 3f), the remaining rejections are the things a port keeps from Elm: a board written at the top level
(Change 4, two lines of it a real wrong answer under in-place editing) and `filter`'s identity promise on a
local fold. `browser-direct` refuses the port at `Tea.document` (S5) and markup held as a value (S4).
