## 2026-10-12 20:21 CEST — Bike Wars, the first external port, raw

**What I did.** Ported ohanhi/bike-wars (Elm 0.19.0, `ed263780`) to `examples/bike-wars` module by
module, with the used parts of linear-algebra, ohanhi/keyboard and elm/core's `Tuple`, licences
kept; `PORTING.md` lists every kind of change beni forced. Stopped once on the missing frame
subscription and SVG vocabulary (both since landed, PRs #70/#71). `browser/tea/BikeWars` plays a game
on virtual frames; the corpus harness now copies an outside program's subdirectories and builds it
with `--root=.`. The raw port is frozen at its own commit; research 82 counts its ownership demands:
82 lines, 31 rejected (38 %), identical on both browser platforms, seven root causes.

**What I learned.** Red's controls work: my first report said `keyParser` never parses `a`/`d`/`w`,
but `Keyboard.Arrows.arrowKey` reads WASD as `Character`s; only the case is kept. The original turns
a win into a draw while an explosion burns and the survivor rides on — faithful, and the test shows
it. The mechanical `x :: xs` → `[ x, …xs ]` makes `xs` a consumed base, which is where most of the
rejections start; a suffix rebuild `[ b, …tail ]` after `[ a, b, …tail ]` counts as a write of the
scrutinee (9 lines). beni's `String.fromFloat 20` is `"20.0"`, so every SVG coordinate prints so.
`/tmp` (8 GB tmpfs) filled with other sessions' scratch trees; a worktree under `.claude/worktrees/`
on disk was the way out.
