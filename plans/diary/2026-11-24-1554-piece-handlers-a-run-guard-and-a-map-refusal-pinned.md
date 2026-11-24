## 2026-11-24 15:54 CET — Piece handlers: a run guard and a map refusal pinned

**What I did.** A second pass on #2063 (pull request #2689), after a review of my own work found
two lines of new code that no fixture held. (1) `runRow` leaves a root that takes `send` out of a
run of roots mounted through one table. The page `browser/inline/PieceHandlerRun` has such a root
beside a run of two. I built a second compiler without the guard: the root joined the run, got no
`send`, and its click threw `TypeError: f$1 is not a function`. (2) The program site refuses such
an event under an `Html.map` whose function is not a constructor of one field
(`build/bad/inline/PieceEventMapArgs/`, a row in `browser-inline.md` §8.7). (3) A comment in
`Page.item` said a piece's listener never enters a helper's call at the event, which `pieceMake`
now does; I rewrote it. I ran the seven new pages in headless Chrome (`zig build test-browser
-Dcorpus=PieceHandler`): the step passes, and it fails when I make one golden wrong.

**What I learned.**
- **Every new branch needs a fixture that fails without it.** The first set of pages had one
  widget each, so `rootRuns` returned before the guard and a wrong guard could not show. A
  compiler with one line removed, installed with `zig build -p zig-out/mutant`, is a quick proof
  and leaves the main binary alone.
- **A root with only such events has no handler of its own**, so `programPieceKey` never checks
  the maps for it. The limit at `programPieceWrap` is then the first check of the maps, and it
  needs its own fixture.
- **On a pull request, CI runs only `browser/managed` in Chrome.** The full Chrome corpus runs on
  the push to master, so a new `browser/inline/` page needs a local Chrome run before the merge.
- A CI job can fail before it starts (HTTP 429 on the download of `actions/checkout`). Read the
  job log before you look for a fault in the change.
