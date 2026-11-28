# 141 — The order of a group's rounds, limit lines, and the release optimiser in the oracle

*Research report, 2026-11-15. Blind reader J ran every sweep of research reports 138 and 140 again,
and a new one that writes each program with its top-level declarations reversed. J found no fault of
soundness, and three other faults: the declarations' order changed v3's verdict, the limit lines pointed at
an unrelated declaration and the sweeps' runner did not count them as limits, and the release optimiser
was outside the in-place oracle. This report fixes the three.*

---

## 1. Result

- **The order of the declarations no longer changes a verdict.** J's `order` sweep (836 programs, each
  one of another sweep with its declarations reversed) had 36 programs whose verdict class differed from
  the program as written. It has none now. Each round of a recursive group walks its members callees
  first, in an order that the call graph and the names give (`Check.groupOrder`, kernel §6 rule 9).
- **A function value declared with no parameter starts its rounds from the bottom contract**, as a
  function does (`Check.bottom`). It started from no contract, so a member walked before it read it as
  unknown code, and contracts only grow. In `run/EvidenceFunctionRecursionAccepted`, `ping` and `pong`
  got an escape of their second parameter in one walk order and not in the other, and `countDown`, a
  lambda that calls itself, got it in every order. None of the three has it now. This is a precision gain,
  and no verdict of the corpus or the sweeps changed with it.
- **Each limit line points at what reached it**: a declaration's at its name, a group's at the name of the
  member first by name, a type past the layout limit at the type's name when the module declares it and
  at the declaration that met it otherwise (`Check.Limit`, `Check.overLimit`, kernel §8). They pointed at
  the module's first instruction, which was an unrelated declaration.
- **`run.mjs` counts each `OWNERSHIP CHECK TOO LARGE` line as LIMIT.** It looked for v2's
  `ownership_summary_size` only, so a v3 limit was `REFUSED unknown` with the position of the next line.
- **`--lists-in-place --release` builds** (still hidden and test-only), and `run.mjs --mode=both` adds a
  release leg: each program that passes the three other legs is built under `--release` plain and in
  place, each one scope-hoisted file, and the two runs are compared (`RIPTRAP`, `RIPDIFF`). No sweep has a
  release fault (§4).
- **One defect outside the checker**: a plain `--release` build of a list `case` with an unread `as`
  binding reads `undefined` (#2512). The release leg found it as `rip=PLAINRUNFAIL` in 4 programs of J's `lang`
  sweep and 4 of `order`.

## 2. The order of a group's rounds

`Check.checkModule` gave `solveGroup` the members of a group in the order of their declarations, and
each round walked them in that order. A contract that changes reaches a caller in the same round only
when the caller is walked after it. J's program is a ring of 40 functions, `s0` calling `s1` … `s39`
calling `s0`, each rotating a triple of lists: written with the callers first, a contract moved one member
a round, and the group did not settle in 64 rounds (a `limit` line, no contract, the write refused).
Written with the callees first, it settled in a few rounds. All 36 order changes of J's sweep are this one
cause.

The order is now made from what does not move when the declarations move: the names and the bodies.
`groupOrder` sorts the members by name, then walks the group's own calls depth first from each member in
that order, a body's calls in the order it writes them (`top` references and method calls that resolve to
a member), and puts each member after the members it calls. The result is a function of the program's
text without its declaration order, so the number of rounds, and whether the group settles, are the same
in every order. The limit is still 64 rounds and still refuses; whether a group settles is now a fact of
the program, not of its layout.

Measured on rings that rotate a triple of lists (`fwd` written callers first, `rev` callees first,
`shuf` a fixed shuffle; `both`, each member calls its two neighbours):

| ring | before: fwd / rev / shuf | after: fwd / rev / shuf |
|---|---|---|
| 40 | limit / settles / settles | settles / settles / settles |
| 64 | limit / settles / limit | settles / settles / settles |
| 200 | limit / settles / limit | settles / settles / settles |
| 200, both | settles / settles / limit | settles / settles / settles |

One group still does not settle in any order: J's `rounds/rot-70`, one function that rotates a 70-tuple
of lists, moves its answer's source one position a round and needs 70 rounds. That is the height of one
contract, not an order, and the bound of 64 is a constant; #2513 holds the choice.

The test: `ordering_test.zig`, *a ring of 64 functions settles in either order*, writes the ring in both
orders and builds each under `--ownership=v3 --ownership-everywhere --lists-in-place`. It fails on the
compiler before this report (the order written callers first is a limit). The ring is not in the corpus:
v1 and v2 stop at their own round limits on it, and the corpus compares them on every `run/` program.

## 3. Limit lines

`Check.Result.limits` holds each line's text and token. A declaration's line points at its name. A group
that did not settle names its member first by name, and says how many members the group has. A type past
the layout limit names the first type the table cut (a nominal type by its name, else `a record`, `a
tuple`, …) and the declaration that met it. The declarations' budgets, which build most layouts, are now
made in the order of the names, so that declaration does not depend on the declarations' order when the
budgets meet the type; when a walk meets it first, it is the walk's declaration. A line of the module as a
whole (the module's budget, met only by the derived rows) points at the file's first token.

The 4 096-location limit that J met with 20 nested types `T_i = T_i T_(i-1) T_(i-1)` and a derived `==`
is the documented limit and not a defect: with a list at the bottom, `T20` has 2²⁰ list locations, one
for each path of labels, and with an `Int` at the bottom it has no location and no limit. To accept it, the
table would need the principled layout §8 names: past a bound, the repeated halves of a type share one
summary location for each object place below them. That is research report 120 §2's open design; nothing
changed here.

## 4. The release optimiser in the oracle

`--release` runs the release optimiser (`backend.md` §9: the whole-program specialiser, dead bindings,
single-use inlining, short names) between the lowering and the printer, and writes an application as one
scope-hoisted file. An accepted in-place write is safe only while every read that the checker saw before
the write still runs before it. The in-place lowering's writes, and the reads of a list's length, are calls
into the in-place runtime, which the optimiser treats as calls that may have effects, so it keeps their
order.

The in-place runtime (`_core/_sanitize.mjs`) now joins the one file as any hand-written file does
(`Emit.planHoist`). Before, its import made the hoisting plan give up, so every in-place release build was
the multi-file layout: no one scope, and the specialiser and the pruning that a plain release build gets
did not run on it. The review of this report found that; the sweeps below ran with the one file.

The release leg tests it on every sweep. A program reaches it when the plain, sanitised and in-place legs
all pass; 4 448 programs did.

| sweep | programs | release-leg faults (`RIPTRAP`, `RIPDIFF`) | other `rip=` |
|---|---:|---:|---|
| J's 25 sweeps (`words` … `rand2`, `corpus`, `order`) | 10 713 | 0 | 8 `PLAINRUNFAIL` (#2512), 2 `PLAINFAIL` (nesting) |
| `evaluation-order.mjs` | 440 | 0 | — |
| `callbacks-keep.mjs` | 720 | 0 | — |
| `handed-back.mjs` | 2 592 | 0 (all refused) | — |

The two `PLAINFAIL`s are `perf/joins-*`: a release build of a function that nests 837 levels is refused
(`backend.md` §9), as it should be. The 8 `PLAINRUNFAIL`s are #2512: the plain release run throws, so the
leg has no oracle. (`handed-back.mjs` ran with the multi-file layout only.)

## 5. Before and after

Every verdict of J's sweeps, by program, before (J's run) and after: 73 changed, 36 in `order`, 36 in
`rounds` and 1 in `corpus`. In `rounds`, 18 dead twins went from the misread limit to `SAME`, 16 live twins to `REFUSED
later-use` (the write the program does make after a read), and `rot-70` (2) to `LIMIT`; `order` has the
same 36 reversed. The one in `corpus` is `corpus/run/EvidenceDagBuildDepth32`, a `REFUSED` that was a misread
layout limit and is `LIMIT`. Nothing else changed. The `dump --stage=ownership --ownership=v3` of every
`run/` and `ownership/` program of the corpus is the same before and after except the fresh names'
numbers (a site's number follows the walk), the limit lines' text, and the summaries of §1's three
functions.
