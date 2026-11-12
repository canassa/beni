# 113 — The ownership prototype: a blind test by another tester

*Research report, 2026-11-12. Asked for on pull request #2451. It is not normative. It tests the prototype of
[report 112](112-ownership-prototype-function-values.md), `src/own3/` behind the hidden flag `--ownership=v3`,
at head `3372bd2841`. The tester did not read the authors' generators or tests before the run.*

---

## 0. Verdict

**The claim does not hold. The prototype accepts a program whose in-place build reads a stale list.** The new
generator, 9 792 programs aimed at the border between function values and the first-order core, found no
fault in its one run: v3 has 0 `TRAP`, 0 `DIFF` and 0 `CRASH`, and it refuses each of the 4 896 `live`
programs. A search by hand after that run, from a reading of `src/own3/Frame.zig`, found one class of fault.
A local function `h` names a local function `g` that is bound after it. `g` reads a captured list. The
prototype then does not see that a later call of `h` reads that list, so it accepts an in-place write of the
list before that call. Four small programs trap under v3; `master`'s v2 refuses each of them. The fault is in
the place that report 112 §2.6 lists as one of the six ways to lose a function (`usedEarly`). The `flow` to
`top` there covers what `g` asks of its caller. It does not cover what `g` holds. On precision, v3 accepts
27 % of the safe twins of the sweep and v2 41 %.

---

## 1. What was done

1. I read `CLAUDE.md`, report 110 §6, report 112 §0–§2 and `src/own3/`. I did not read the other generators of
   `bench/ownership-sweeps/` (only `run.mjs` and the README), the step 0 scripts, `check_test.zig`, report 111
   §3–§4, report 112 §3–§6 or the diary.
2. I wrote `bench/ownership-sweeps/blind.mjs`. Each program puts one list `xs` at two places, edits one and
   reads the other (`live`), or reads nothing after the edit (`dead`, the safe twin).
3. I built a ReleaseSafe beni from a fresh worktree of the branch, and checked that each program builds and
   runs in a plain build. Then I ran the whole set one time with `--checker=v3` and one time with
   `--checker=v2`. I did not change the generator after the v3 run.
4. With no fault in the sweep, I searched by hand, aimed at what the code reading showed (§4).

## 2. The generator

`node bench/ownership-sweeps/blind.mjs <outdir>` writes 9 792 programs in three families.

| Family | Programs | What it does |
|---|---:|---|
| `pair` | 8 976 | route × mechanism × edit, with one pair of carriers for each combination, by rotation |
| `core` | 720 | a list of lists from `core/` or from a hand-written function, where two elements can be one list; then an edit of one element |
| `tree` | 96 | a recursive tree whose leaves can be one list, walked by a fold or a function value; then a leaf is edited |

In `pair`:

- **Carriers** (13): `List Int`, a record, a tuple, a `Maybe`, a custom constructor, a list of lists, two
  trees (`Leaf`/`Fork`, the list at the left or at the right, three levels down), `Maybe` of a tuple, a
  record in a record, a list of lists of lists, a thunk `⊤ → List Int`, and a generic `Hold a`.
- **Routes** (17): two arguments; one tuple (to a callee, and bound by a local pattern); a record; a
  constructor `Two a b`; a projection of the first argument; an `if` arm; a `case` arm; a capture and an
  argument (a lambda, and a returned function); `Hold` of a tuple; a list of two; a local alias; a tuple
  2, 7, 8 and 9 levels deep.
- **Mechanisms** (25): directly; two callbacks; two lambdas; a callee over type variables (two kinds); partial
  application `f a _` and `f _ a`; a record of functions; a list of functions; a tuple of functions; a
  `Maybe` of a function; a returned function; a composition; one callback run on both; `List.foldl`; a fold
  whose callback runs a function; a hand-written fold; one more call; a call through `k u v f = f u v`;
  `Maybe.map`; a local function; a recursion; a branch; a swap; `List.map`.
- **Edits** (11): in the caller (`List.set` of the first or second part, a read of the other or of `xs`;
  `List.push`); in a second callee; by a callback after the call; in a fold after the call; through
  `List.update` of a list of the two parts; through a record update; inside a wrapper callee; by a callback
  inside a wrapper callee.

## 3. The run

`node bench/ownership-sweeps/run.mjs --beni=<safe beni> --checker=v3|v2 --tag=v3|v2 --jobs=16 <outdir>`.
v3 took 3 min 23 s, v2 1 min 25 s.

| Verdict | v3 `live` | v3 `dead` | v2 `live` | v2 `dead` |
|---|---:|---:|---:|---:|
| `REFUSED` | 4 896 | 3 573 | 4 893 | 2 866 |
| `SAME` | 0 | 1 323 | 3 | 2 030 |
| `TRAP`, `DIFF`, `CRASH`, `PLAINFAIL` | 0 | 0 | 0 | 0 |

The three `live` programs that v2 accepts are `tree.built.*.flat.live`. They are a fault of the generator,
not of v2: in the shape `built` the list is at one leaf only, and the reader reads the new tree. So they
read nothing stale.

### 3.1 Precision on the safe twins

Of the 4 896 `dead` programs, v3 accepts 1 323 (27 %) and v2 2 030 (41 %). Both accept 1 097. v3 alone
accepts 226, v2 alone 933.

- The 226 that v3 alone accepts are all record updates (`recupd`). v2 refuses each record update of the
  sweep.
- Most of what v2 alone accepts is a function that goes through a default location. v3 accepts no `dead`
  program of these mechanisms: a composition, a returned function, a record, a list, a tuple or a `Maybe`
  of functions, a hand-written fold, `List.map`, and the route of a returned closure (2 of 264). Report 112
  §2.8 names this cost.
- With the edit in the caller, v3 accepts about half of the safe twins (213 to 226 of 408) and v2 nearly all
  (401 to 406).
- Neither accepts a `dead` twin of the edits that keep both parts in one value (a callback after the call, a
  fold after it, a list of the two parts, a wrapper callee), of the `core` family, or (v3) of the `tree`
  family. v2 accepts 9 of the 48 `tree` twins.
- The first codes of v3's refusals of the `dead` twins: `unknown` 2 044, `disjoint` 446, `supply` 432, `call`
  367, `later-use` 250, `escaped` 22, `element` 12.

## 4. The search by hand

The sweep tests the claims of `sourcesApart`, `argsApart` and `partsOf` from many sides, and each held. So I
read where a value of the frame can lose its cells. A value that is `v_shared` or `v_none` holds no atom.
That is safe for a write to it (no claim), but a read of it then reads nothing. The question was: where can
a value that holds a list cell become one of these?

`capture` (`Frame.zig:1297`) answers `v_shared` for a local that no frame has bound yet: "a later local
function: nothing is known of it". And `codeValue` (`Frame.zig:1732–1737`) takes the closure's captures
from `m.lv` at the point where the closure is made, before that later local is bound. The one rule for this
case is `usedEarly` (`Frame.zig:1644`): when the later local is bound, it flows to `top`.

That gives the fault.

### 4.1 The minimal program

```text
main : Program
main =
    xs = [ 1, 2, 3 ]
    h n = g n
    g n = ints xs
    ys = List.set xs 0 9
    Node.print "${ints ys} ${h 1}"
```

The plain build prints `9,2,3 1,2,3`. With `--ownership=v3 --ownership-everywhere --sanitize-lists`, v3
accepts the program, and the build throws: `a stale read of a list (read length), which List.set in Main …
changed in place`. v2 refuses the write: `later-use: xs is read again`. The same program with `g` bound
before `h` is refused by v3. The safe twin, with no call of `h` after the write, is accepted by both.

### 4.2 The programs

All are in `bench/ownership-sweeps/blind-faults/`, with a `LIST` for `run.mjs` (run it from the repository
root).

| Program | What it shows | v3 | v2 |
|---|---|---|---|
| `early-call.live` | the program of §4.1 | `TRAP` | refused, `later-use` |
| `early-mutual.live` | `h` and `g` call each other | `TRAP` | refused, `later-use` |
| `early-argument.live` | one list at two places of one call: `bumpThen xs h`, where `bumpThen` writes its list and then runs `h` | `TRAP` | refused, `disjoint` |
| `early-push.live` | `List.push`, and a read of the length through `g` | `TRAP` | refused, `later-use` |
| `early-call.dead` | the safe twin of `early-call.live` | accepted | accepted |

`early-argument.live` is the border of report 112 §2.7 from the other side: the argument `xs` and the
function `h` are two operands of one call that hold one list. The write is judged against the other operands
(`otherReaches`), and the cells of `h` do not include `xs`.

### 4.3 The cause

There is one cause. A local function that names a later local function holds no value for it.

1. In the frame of `h`, `g` is a capture that no frame has bound. `capture` answers `v_shared`, and `m.early`
   is set (`Frame.zig:1326`).
2. The closure `h` is made with the captures as the parent frame has them then. `g` is not bound, so the
   capture is no value with cells (`Frame.zig:1732–1737`).
3. When `g` is bound, `usedEarly` sends it to `flowTop`. The `top` use refuses a `g` that writes a parameter,
   and makes escape each captured value that `g` lets escape (`captureEscapes`). `g` only reads `xs`, so
   nothing is recorded. `flowCode` makes the function itself escape ("what the function captured is held
   from here on") only for a use that is not `top` (`Frame.zig:2682`). For a `top` use it counts on the
   value staying in a value of the frame, and here it does not.
4. A later call of `h`, or a call that is handed `h`, reads the closure `h`. `reach` follows the captures of
   `h` (`Frame.zig:686`), and they do not lead to `xs`. So neither `finishDemands` (`later-use`) nor
   `otherReaches` (`disjoint`) sees the read.

Report 112 §2.6 says that a function lost at one of these six places keeps the default contract, so "it can
lose precision. It cannot make a fact 'nothing happens'". That is true of what the function asks: the `top`
use refuses a function that writes. It is not true of what the function holds. In the other places on the
list, the function value stays in a value of the frame (an item of a record, an argument), so a later read of
that value still reaches the captures. At `usedEarly`, the holder (`h`) does not have the value. The default
says "the holder can run the function at any time", and the reads of each later run are the reads that are
lost.

A fix has to make a later run of `h` read what `g` holds. Two ways that keep the rule's shape: walk the
group of local functions that name each other as one group, as a recursive group of declarations is walked;
or, at `usedEarly`, count each cell that `g` captured as read by each later read of each closure that named
`g` early (the simplest sound form: those cells escape at `g`'s binding). This report does not choose.

## 5. What this test does not show

- The sweep has no fault. That is evidence about the shapes it has. It is not evidence that the border is
  closed. The fault of §4 was found by reading the code, as the fault of report 112 §6.5 was.
- The sweep's own family of the fault is small: none of its programs names a local function before it is
  bound. It was not written for that, and it was not changed after the run.
- The hand search covered the first-order order of evaluation (record, tuple, argument and `++` order: each
  sound), recursion and mutual recursion that swap or repeat arguments, callbacks that write a parameter while
  a capture or another operand holds the same list, and pairs of a parameter and the answer of a function
  that it was handed. Each was refused or sound. These were a few dozen programs, not a sweep.
- One generator fault: the three `tree.built.*.flat.live` programs are not live (§3).

## Appendix A. Commands

```sh
git worktree add <wt> origin/ownership-v2-design-review --detach
cd <wt> && nix develop -c zig build test-blackbox-check "-Dtest-filter=faults of round 2"
node bench/ownership-sweeps/blind.mjs <dir>/gen1
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --tag=v3 --jobs=16 --tmp=<disk> <dir>/gen1
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v2 --tag=v2 --jobs=16 --tmp=<disk> <dir>/gen1
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --jobs=4 --tmp=<disk> bench/ownership-sweeps/blind-faults
```
