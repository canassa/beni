## 2026-11-24 15:33 CET — Piece handlers through the dispatcher on browser-inline

**What I did.** #2063, worker `inline-piece-handler`. An event of another module's markup whose
handler value is not one constructor that takes the payload or nothing was a class-4 refusal on
`browser-inline` (`PieceEventArgs/`); the same program built on `browser-tea`. I reproduced it on
`186237c2b4` with the issue's `Nav` example, then amended `browser-inline.md` first (§5, §8.3,
§8.4, §8.7) and built it. The root makes the message: its listener is `on(E[n], send, type,
make)`, `make` written in the root's own module with `pg.enter`, `cx.rootValues` and `cx.value`,
which a root's bindings use already. The factory takes `send` after its handlers, only when the
root has such an event. The program hands its dispatcher: itself with no `Html.map` around the
call, else behind the maps' constructors (interface 1.41, `programPieceWrap`). Two narrower
refusals stay, each with a fixture: a handler value that reads a `let` of the root's function
(`PieceEventLet/`), and such an event in a helper's call whose argument is not proved pure and
total (`PieceEventHelperArg/`). Pages: `browser/inline/PieceHandler`, `PieceHandlerMoved`,
`PieceHandlerNoMap`, `PieceHandlerTwoMaps`, `PieceHandlerHelper`, `browser/prerender/PieceHandler`,
and the golden `emit/release/inline/PieceHandler`. Each transcript is `browser-tea`'s of the same
source, one but for two placeholders.

**What I learned.**
- **A second binary is a cheap proof.** I kept the compiler built from master beside the new one.
  It showed each new fixture red before the change, and it let me build all 408 existing
  `browser/inline/` fixtures with both compilers, development and release: every output tree is
  the same. The `emit/` goldens alone could not show that, since the pages have no byte golden.
- **A root's own handler and the dispatcher can both reach one key.** The plan moves a key into
  its root when no command of the program runs. Since #1176 a program can have a dispatcher with
  no command, so a key can have the root's handler and the program's named handler. Both are the
  same arm and the same pass on the slice the root holds. `PieceHandlerMoved` mixes their clicks.
- **Pieces have no memo node and keep no call arguments.** The program's own `view` makes a `let`
  that a handler value reads a memo node, and keeps the arguments its binding evaluated for a
  handler in a helper's call. A piece has neither, so I refused those two cases; to evaluate the
  `let` or the argument again at the event would run an effect once per event.
- **A sweep of `browser/tea` did not move.** 200 pages build before and after: no `browser/tea`
  page has such an event in another module's markup. The issue is a follow-up of #1176, not a
  result of the sweep.
- **A constructor is not proved pure and total** (`instSafeMode` accepts no `.ctor`). So
  `{button "inc" Inc}` keeps its arguments for the handler in the program's own markup, and in a
  piece it is refused by `argsOnce` (no binding enters the call). It is an older gap that hid
  behind this refusal: #2686.
- Debt left on purpose, each with an issue: a constructor applied to values in a piece goes
  through the dispatcher where it could call its key (#2687); the two narrower refusals (#2688).
- `date` on this machine is the only clock to trust: I wrote a time from memory in my report and
  it was 20 minutes wrong.
