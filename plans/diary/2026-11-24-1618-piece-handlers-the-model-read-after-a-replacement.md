## 2026-11-24 16:18 CET — Piece handlers: the model read after a replacement

**What I did.** A third pass on #2063 (pull request #2689). In every page so far the widget wrote
its record in place, so the root held the record itself. `make` also reads the model when the
root holds the model's object (the program replaces the widget's record) or the model's cell (the
program replaces its whole model). I built both by hand, compared them with `browser-tea`, and
kept them as pages: `browser/inline/PieceHandlerReplaced` and `PieceHandlerCell`. Each clicks a
handler that reads `model.cups`, then `Reset`, then the handler again: the message starts from
the new record. Both transcripts equal `browser-tea`'s, in development and release. I also took a
nit of the review: the comment in `Page.item` names `valuePureTotal`.

**What I learned.**
- **A new reader of the model in a piece has three ways to reach it** (`Program.RootArg`: held,
  through, cell). A page for the first says nothing about the other two, and a stale read there
  is a silent wrong answer. Write one page for each kind of holder.
- **The requested review pass reads fixtures too.** It checked the click order of
  `PieceHandlerRun` against `rootRuns` and found the order sound. Its one suggestion (a `send`
  root between two runs) has cover already: `RootRuns` splits a run at a root that takes a
  handler, and `runRow` answers null on the same line for both reasons.
