# 88 — The second external port: rvcas/sternhalma, raw, under the ownership checker

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


*2026-10-13. This note reports what `beni dump --stage=ownership` says about the second application of
thesis §12.4's external corpus, after research 82's Bike Wars: an Elm program written by someone else,
ported to beni and frozen before any repair. The application is Lucas's (rvcas) Sternhalma
(<https://github.com/rvcas/sternhalma>, commit `ffb3f91b`, Elm 0.19.1, BSD-3-Clause), Chinese Checkers for
two, three, four or six players: 1 201 lines of Elm in 4 modules, no ports, no package beyond `elm/*`. Its
board is an `Array` of cells with a `Dict` from coordinates to indices, and a move is checked by a
breadth-first search over hop chains with a `Set`. The port is `examples/sternhalma` (`PORTING.md` lists
every change beni forced); it is 1 050 lines of beni after `beni fmt`. The frozen raw port is the commit
that adds `examples/sternhalma/PORTING.md` (`3a7c465e1` on its branch), and every count below is taken on
it. The checker is master's at `9a5276a06`, which includes slice 3f (research 85: a prepend copies, `map`
across records, the default read). Re-run on master at `228681b94`, after slice 3g (research 86), both dumps
and every probe step of §4 are byte-for-byte the same. Every figure is **[measured]** with the commands in §6. The probes of §4
are hypothetical edits made in a scratch copy, and none of them is applied.*

---

## 0. The answer

1. **12 demand lines: 8 accepted, 0 pending, 4 rejected.** The two dumps, `browser-tea` and
   `browser-direct`, are byte-identical. The idiomatic error rate of this application is **4/12 = 33 %**,
   against the thesis's criterion of under 2 %. **The application is not accepted.**
2. **By kind.**
   - 0 exact.
   - 1 approximate: `call` 1.
   - 3 position: `top-level` 3.
3. **Three root causes explain all four** (§3):

   | Root cause | Lines | Kind |
   |---|---|---|
   | S1, the game is set up by editing the top-level `Board.init` | 2 | position; correct in substance |
   | S2, `centralHexagon ++ allTriangleCoords` appends onto a top-level list | 1 | position |
   | S3, a fold that writes the board while it walks `List.filter`'s result of the board's cells | 1 | approximate: O2's identity promise |

4. **Classification.**
   - **Correct rejections:** 2, S1's. `Board.init` is read again — `viewBoard` draws it while the players
     are chosen, and every `SetPlayers` sets a new game up from it — so editing it in place would start the
     next game from the last one's pieces.
   - **Limits of the checker:** 1, S3. `List.filter` returns its input only when every cell passes, which
     the triangle test never allows, and even then each write lands behind the fold's read.
   - **Cleared by a change already decided:** S1 and S2 are both Change 4's rule that a top-level list is
     shared, and both clear with its port fix: `Board.init ⊤` and `centralHexagon ⊤`.
5. **What a repair would need.** §4 makes three edits in a scratch copy: two make `Board.init` and
   `centralHexagon` functions of `⊤`, and one copies the triangle's cells before the fold
   (`List.copy`). Together they clear all 4. On `browser-tea` the entry then says `platform` (§20.2: the
   template runtime keeps the model it hands `update`), as the direct row predicts; on `browser-direct` the
   program is accepted.
6. **The headline differs from Bike Wars'.** Slice 3f removed this port's prepends as demands before it was
   written, so no rejection here is a translation of `::`. What is left is the two things a port does not
   change by itself: Elm values written at the top level (Change 4, 3 of 4 lines), and the identity promise
   read without the predicate (O2, 1 line). Two of the four are correct, one is a position the decided change
   assigns, and one is a limit.

## 1. The port, and what was measured

`examples/sternhalma/PORTING.md` is the full account. In short:

- Each module is the Elm module with the same declarations, names, model, messages and logic.
- **`Array` is `List`.** beni has no `Array`; `List` is the one sequence type, array-backed, with Elm's
  `Array` operations on it (`language.md` §6.8). `Array.get i a` is `List.get a i`, `Array.set i v a` is
  `List.set a i v`, with Elm's out-of-range behaviour, and `Array.fromList`/`Array.toList` disappear.
- **The drag events.** The game is played by drag and drop, which Elm writes with `Events.on "dragstart"`
  and `preventDefaultOn "dragover"` over `Json.Decode.succeed`. beni has neither a general `on` nor a decoder
  library, and its html vocabulary had no drag events. This change declares `onDragStart`, `onDragEnd`,
  `onDragOver` and `onDrop` in `platforms/html/Html.beni` (`boundary.md` §9.8.10, amended 2026-10-13), and
  the page driver gains a `drag` step. The author's four helpers keep their names and return the handlers;
  `preventDefaultOn`'s `True` is a call of `Html.preventDefault`.
- The changes beni forced are listed by kind:
  - saturated calls and `_`, with one two-argument partial application written as a lambda
    (`two_placeholders`);
  - subject-first core with pipe-first `▷`, and nested calls where the author's subject is last;
  - `[ x, …xs ]` for `::`;
  - Unicode notation, `×` tuple types, `⊤` for `()`;
  - parenthesised negative arguments (`coord 1 (-5)`);
  - `modBy` as `Int.mod`;
  - markup, where one button's two `class` attributes, which Elm's virtual DOM joins with a space, are one;
  - `Tea.document`.
- **The page shell.** The original is styled by Tailwind through Vite. beni has no CSS pipeline, so the
  port's own `index.html` (`beni.json`'s `"html"`) loads Tailwind's browser build of the same version.
- The port builds and plays on **`browser-tea`**. `browser-direct` refuses it twice over: `Tea.document`
  (its slice S5), and markup held as a value (its slice S4), first reported at `viewPlayerSelect` (a
  top-level value) and `viewPlayerButton` (handed to `List.map`). The checker evaluates any program under
  the direct row (`ownership-checker.md` §20.2), so both rows are reported.

**The play.** `examples/sternhalma/play/sternhalma.steps` drives the page driver: two players; a piece of
the player whose turn it is not, which starts no drag; red's step, with the two cells it may reach ringed; a
drop out of reach, which moves nothing; a drag let go off the board; purple's step; and red's multi-jump,
(4,−5) over (3,−5) and then over (2,−4) to (2,−3), which no single hop reaches, with the four cells it may
reach ringed; then New Game. The development and `--release` transcripts are identical.

**It is not a corpus case, because no case of this program fits the test budget.** A `browser/tea/` case
builds the program twice and runs both builds in one Node process under happy-dom, then fuzzes one against
the other. Measured on the ReleaseSafe beni the gates run, in retired user-space instructions:

| Part | Million instructions |
|---|---|
| development build | 608 |
| release build | 1 219 |
| Node and happy-dom with an empty page (another fixture's) | 546 |
| one page: the load of the 121-cell board | +264 |
| one page: the whole script | +626 |
| the case, whole script (harness) | 4 992 |
| the case, a script of one click (harness) | 4 592 |

The budget is 4 300. Bike Wars' case was 3 786 (research 82 §1). This one's floor — two builds, two loads
and the dev-against-release fuzz — is above the budget before any move is played, so shrinking the script
cannot bring it under, and splitting it pays the floor twice. Rule 10 holds: the budget is not raised here.
The case moves into `tests/corpus/browser/tea/Sternhalma/` when the owner grants it a `.budget`, as
Conduit's cases have, or when the case's cost falls. Until then the play is checked by hand, with the
command in the script's header.

## 2. Every rejection

Lines are `module line:col`, in the frozen commit's formatting. *Kind* is the dump's (`ownership-checker.md`
§8.3). *Verdict* is this report's hand classification.

| # | Line | Cause | Kind | Root | Verdict |
|---|---|---|---|---|---|
| 1 | Board 41:32 `++ Board.centralHexagon` | top-level | position | S2 | the position rule: `allCoords = centralHexagon ++ allTriangleCoords` makes the top-level `centralHexagon` the append's base (Change 1). Nothing reads it again (only `init` names it, once), so the write is harmless in substance; Change 4's port fix clears it |
| 2 | Main 101:5 call `List.foldl board.cells` | top-level | position | S1 | **correct**: `setupBoard` folds `placePlayerPieces` over `board = Board.init`, a top-level value, and `Board.setOccupant`'s `List.set` writes its cells. `viewBoard` draws `Board.init` again on the player choice, and the next `SetPlayers` sets up from it |
| 3 | Main 114:13 call `List.foldl board.cells` | call | approx | S3 | limit: `triangleCells = board.cells ▷ List.filter …` may be `board.cells` itself under O2's identity promise, and the fold's callback writes the accumulator's cells |
| 4 | Main 17:5 `entry Main.update model#Playing.0.board.cells` | top-level | position | S1 | correct, as 2: `update`'s `Drop` arm writes the board's cells, which `setupBoard` may hand over as `Board.init`'s |

**Totals.**

| Cause | Lines | Root causes |
|---|---|---|
| `top-level` | 3 | 2 S1, 1 S2 |
| `call` | 1 | S3 |

**The accepted lines**, for the denominator: `Board.setOccupant`'s `List.set board.cells` (param);
`placePlayerPieces` and `Board.setOccupant` as `List.foldl` callbacks (callback-param, 2); `update`'s two
`Board.setOccupant` calls (param, 2); `reachableByHops`' call of `bfsHops` with a literal frontier (fresh),
`bfsHops`' `rest ++ hopTargets` and its recursive call (param, 2).

**Thesis counts.**

- Top-level models (§12.5's own line): 0. `init` returns `SelectPlayers`, which holds no list. The model is
  seeded from a top-level list instead, the case Change 4's costs name ("a program that seeds its model from a
  top-level list is rejected at its first in-place edit"); its lines count as position.
- Kept copies: 0. Once-closure rejections: 0.
- Prepend warnings: 0. `groupByRow`'s `[ [ first, …sameRow ], …groupByRow remaining ]` prepends onto a
  recursive call's result, not onto an accumulator.

## 3. The root causes

**S1: the game is set up by editing `Board.init` (2 lines; correct, position).** `Board.init` is a top-level
`Board`: 121 cells built once. `Main.setupBoard` starts from it and folds `placePlayerPieces` over the
players, each placing ten pieces with `Board.setOccupant`, whose `List.set` writes the board's cells. Under
value semantics each fold step makes a new board and `Board.init` never changes. An in-place compile would
put the pieces into `Board.init`'s own array. Two readers would then see them: the next game, since `Reset`
returns to `SelectPlayers` and the next `SetPlayers` sets up from `Board.init` again (a three-player game
after a two-player one would start with the two-player pieces still on the board); and `viewBoard`, which
draws `Board.init` while the players are chosen (it draws every cell empty there, so this reader would show
nothing wrong). The entry line is the same fact seen from `update`: its `Drop` arm writes the board's cells,
which may be `Board.init`'s. This is exactly the rule Change 4 decided — a top-level list is shared and never
edited in place — and its port fix, `Board.init : ⊤ → Board` with `Board.init ⊤` at the two call sites,
clears both lines (§4, step 1).

**S2: `centralHexagon ++ allTriangleCoords` (1 line; position).** Elm's `++` copies. beni's makes its left
operand the base (Change 1), and the left operand here is `centralHexagon`, a top-level list. Only
`Board.init` reads it, once, so no reader would see the push; the position rule rejects it all the same,
because a top-level value is shared by definition. `centralHexagon ⊤` clears it (§4, step 2), as would a fresh
base, `[ …[], …centralHexagon, …allTriangleCoords ]`.

**S3: the fold over the triangle's cells (1 line; a checker limit).** `placePlayerPieces` filters the board's
cells to those of the home triangle and folds `Board.setOccupant` over them with the board as accumulator:

    triangleCells = board.cells ▷ List.filter (λc → Board.triangleOf c.coord == Just triangle)
    List.foldl triangleCells board λcell b → Board.setOccupant cell.index (Just playerId) b

O2 (decided) keeps `filter`'s promise to return its input when it keeps every element, so `triangleCells`
may be `board.cells`, and the callback writes the accumulator's cells while the fold walks them: `call`,
approximate. Two facts the checker cannot see make it harmless. The promise never fires: the predicate keeps
the 10 cells of one triangle out of 121. And if it did, each write is `List.set` at `cell.index`, the position
of the element the fold has just read, so it lands behind the walk. The repair is one `List.copy` of the
triangle's ten cells (§4, step 3), the cost O2's decision records for a filtered list used beside its source.

## 4. The probe chain (not applied)

These edits were made in a scratch copy, one at a time and cumulatively. Each step is dumped under both
platforms. They are evidence for §3, not a repair; the repaired port will be counted separately.

| Step | Edit | Rejected after, `browser-direct` | `browser-tea` |
|---|---|---|---|
| 0 | the frozen raw port | 4 | 4 |
| 1 | S1: `Board.init : ⊤ → Board`; `Board.init ⊤` in `setupBoard` and `viewBoard` | 2 | 3 (the entry now says `platform`) |
| 2 | S2: `centralHexagon : ⊤ → List Coord`; `centralHexagon ⊤ ++ allTriangleCoords` | 1 | 2 |
| 3 | S3: `List.foldl (List.copy triangleCells) board …` | **0** | 1 (`platform`) |

The direct row accepts the repaired program, with the entry `accepted entry`. The template row keeps one
`platform` line, which §20.2 says it must: `browser-tea`'s runtime keeps the model it hands `update` and skips
a render by identity, so an in-place edit of the model's board is never safe there. The repair effort the
thesis counts (§12.5) is three edits, two of them a `⊤` each and one `List.copy` of ten elements, all inside
`Board` and `Main.placePlayerPieces`; it belongs to the repaired port.

## 5. What this says for the evaluation

- **The rate.** Two applications now: Bike Wars 4 of 15 rejected after slice 3g (research 86), Sternhalma 4
  of 12. Pooled, 8 of 27 (30 %). The decision needs at least 500 sites from at least ten applications
  (§12.8), so this is a second point, not a verdict. The denominator is small because slice 3f made prepends
  no demand and the program's other list operations are reads.
- **Top-level values are the commonest cause here.** Elm programs write constants at the top level as a
  matter of course; `Board.init` is the board every game starts from. Change 4's rule rejects every in-place
  edit that can reach one, and its port fix is mechanical (`⊤` on the definition and at each use). Two of the
  three lines are a real wrong answer under an in-place compile, so the rule is earning its keep, but the
  thesis's "top-level models" line does not count them: the model is *seeded* from a top-level value, not
  returned by `init` as one. §12.5's counts may want a line for "seeded from a top-level list", since a port
  meets it as often as the `initialModel` shape.
- **O2's identity promise costs a `List.copy` on a local fold.** S3 is the shape O2's text names (a filtered
  list used beside its source), here local rather than kept in the model. Reading the promise with the
  predicate is not possible in general; a promise that names the accumulator's write position (the write is
  behind the walk) would be a narrower, checkable extension. One line.
- **A capability gap, filled inside the wall.** The port could not be written without the drag events. They
  were added to the vocabulary the way `onMouseMove` was, and `boundary.md` §9.8.10 records it. Elm's general
  `on` stays open.
- **A test-cost wall.** No corpus case of this 1 050-line program fits the 4 300 million instruction budget:
  the floor of two builds, two loads of a 121-cell page and the page fuzz is already over it (§1). This is a
  finding, not something the port could change.

## 6. Commands

```sh
git checkout 3a7c465e1                       # the frozen raw port (its branch's commit)
zig build                                    # beni at master 9a5276a06 plus this branch's vocabulary
cd examples/sternhalma
../../zig-out/bin/beni dump --stage=ownership --platform=browser-tea src
../../zig-out/bin/beni dump --stage=ownership --platform=browser-direct src
../../zig-out/bin/beni build --platform=browser-direct src   # refused: Tea.document (S5), markup as a value (S4)
../../zig-out/bin/beni build --out=out src                   # browser-tea
node ../../tests/browser/driver.mjs --dom=../../tests/browser/happy-dom.mjs \
    out/_main.mjs play/sternhalma.steps | diff - play/sternhalma.expected
```

The two dumps are byte-identical. The instruction counts of §1 were taken with a `perf_event_open`
counter of retired user-space instructions inherited by every child, the unit the gates' budget uses, around
`zig-out/safe/bin/beni build` (with and without `--release`) and around the driver; the harness's own figure
is the failure line of a corpus case under `BENI_WRITE_EXPECTED=1 zig build test-blackbox
-Dcorpus=tea/Sternhalma` with the play script copied into `tests/corpus/browser/tea/Sternhalma/`.
