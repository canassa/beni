## 2026-10-18 02:50 CEST — the slice-1 review round, answered

**What I did**

- The review of PR #332 found no correctness bugs and asked for four things; all four are in
  the tree:
  1. the `appendUnit` helper — the statement append and its unit record written once, three
     call sites (nullary constants, markup hoists, synthesised values);
  2. a runtime-safety cover check at the end of `lower()`: the units are contiguous, nonempty
     and exactly `[head_len, len − tail_len)`;
  3. the `lift_at` precondition check in `declarationPart`: when `livePiece(index)` said no,
     `liftPieces` must have appended nothing — the direction that would fold a surviving piece
     into the declaration's unit;
  4. the "sequential only" note on the shared `names_out` header (handed to a piece by value
     and copied back over arena buffers both share).
- One compile error on the way: `std.debug.assert(at == @intCast(…))` — `@intCast` has no
  inferred result type in a comparison; it is `@as(u32, @intCast(…))`.
- The review's optional contrast suggestion became a fixture, not a comment:
  `tests/corpus/emit/DceSurvivorOrderAllLive.{beni,js}` — the same three declarations, every
  one `pub`, so the `--library` build drops none and the golden is the FULL walk's order,
  `zed, dead, later`. The pair with `emit/app/DceSurvivorOrder` makes the §9 order amendment
  executable; `backend.md` names the pair in all three places.
- #328 got the review's second-shape ask as a comment: two more probes (dropped MIDDLE
  declaration, direct; dropped middle, survivor reached only through a nullary top value),
  with surviving / full / filtered orders, showing the mechanism is position-independent and
  survives a `top_value` ref chain; the evidence (`tops`) shape is named as the fixture slice
  3 owes to close the issue.
- `zig build gates` green on the fixed tree (log `zig-out/scratch/oc/review-gates.log`), and
  the new fixture was proven collected: corrupting its golden makes the filtered suite fail
  naming the fixture; restored byte-identically.

**What I learned**

- The `pub_on_definition` rule: with a type annotation, `pub` goes on the annotation line only
  — `pub dead : Int → Int` then `dead n = …`; `pub` on both lines is an error, and the
  fixture's first build caught me writing it both ways.
- A heavy job launched as `systemd-run --scope` under the tool call lives in the tool call's
  cgroup: a server restart SIGTERMs it mid-flight (two runs died that way), so launch the
  `flock → systemd-run` chain with `setsid` + `nohup` and poll its log; the log survives the
  restart with it.
- A `bash -c` payload written with `\n` escapes inside a zsh single-quoted string arrives as
  the literal `n…` ("nset: command not found"): put the payload in a script file.
