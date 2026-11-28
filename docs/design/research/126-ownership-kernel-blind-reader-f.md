# 126 — The ownership kernel, blind reader F

*Research report, 2026-11-13. A blind soundness test of the v3 prototype (`src/own3/`,
`--ownership=v3`) at commit `6332798eeb` (branch `ownership-v2-design-review`, PR #2451), against
`ownership-v3-kernel.md` as revised that day. The reader did not read research reports 110 to 125,
the other blind generators or their fault folders, the v3 black-box tests, the corpus fixtures with a
`.sanitize-lists-v3` file, or the diary from 2026-11-12 on. Nothing under `src/` was changed. This
report is not normative.*

---

## 0. Summary

- **One fault: a compile that does not end.** A function whose local closures form a DAG — each
  closure captures several closures of the level below — makes v3 follow every path through the
  captures. The work grows by a constant factor per level: three closures per level triple it. At 16
  levels v3 takes 6.8 s, at 24 levels many hours. The plain build takes 15 ms, v1 17 ms, and v2
  stops at once with its loud size limit. Both the code and the rule's argument are wrong (§3).
- **No soundness fault** (no `TRAP`, no `DIFF`) in 4 160 generated programs and about 80 hand
  probes. Every `live` twin that v3 accepted printed the same as the plain build, because the
  written list was not the one read after it.
- **Precision.** The entry rule separated every live and dead twin of the TEA family (28 of 28 dead
  accepted, 24 of 24 holders refused). The losses that look like real code: a function that writes
  its parameter cannot be chosen with `if` or kept in a record field even when it is called at once;
  `Dict.update` with a callback that edits the value; a hand-written generic fold (§5).

## 1. What I probed

The generator is `bench/ownership-sweeps/blind7f.mjs`. Every program runs through `run.mjs`: a plain
build, and a build with `--ownership=v3 --ownership-everywhere --sanitize-lists`, both run and
compared. The beni was a ReleaseSafe build of `6332798eeb`.

```sh
zig build -Doptimize=ReleaseSafe -p <rs>
BLIND7F_CHAINS=500 node bench/ownership-sweeps/blind7f.mjs <out>/a chain
BLIND7F_CHAINS=1500 BLIND7F_FROM=501 node bench/ownership-sweeps/blind7f.mjs <out>/b chain
BLIND7F_CHAINS=0 node bench/ownership-sweeps/blind7f.mjs <out>/c
node bench/ownership-sweeps/run.mjs --beni=<rs>/bin/beni --checker=v3 --jobs=12 --tmp=<disk> <out>/a   # and b, c
```

The families:

| Family | Programs | What it does |
|---|---:|---|
| `chain` | 4 000 | Seeded, typed random chains. A list `inner` goes into a value of a random shape (a list of lists, a pair, a record, a `Maybe`, a `Tree a`), then through two to four helpers from a library of 39: generic (`a → a`, `a × b → b × a`, `a → a × a`, `a → List a`), over a row (`{ r \| items : a } → a`, a row that swaps two fields), over a tree (`Tree a → a`, `Tree a → List (Tree a)`), `apply`, a function run twice, folds, a `Ref` round trip, a `Dict` round trip, a function of a second module, `List.head`, `reverse`, `take`, `drop 0`, `filter`, `map`, `concat`, `Maybe.withDefault`, `map`, `andThen`. A `List Int` is dug out of the answer and written (`push`, `set`, `update`, `pop`); `live` then reads `inner` and the whole value. |
| `tree` | 20 | `Tree T` where `T` holds `List (Tree T)`: one node at a kid and inside the root's label, a label at two levels (`relabel`), a tree grafted under itself, a list that is a kid list and a label's list. The write is on a deep list; `live` sums the whole tree. |
| `dflt` | 80 | A function that hands a list to its function parameter, then writes it (directly, by a method call, by a later binding, by a callee, or answers it for the caller to write). It is run directly, from a `Ref`, from a record field, chosen by `if`, out of `Maybe.withDefault`, `List.head`, a `Dict`, or as a partial application. The parameter keeps the list in a `Ref` (`live`) or a copy (`dead`). |
| `entry` | 56 | The Elm Architecture on `browser-tea`: the model as a record, a record written through a row-typed helper, a triple, a triple written through a generic helper; holders: `update` copies one model list to another field, a command that sleeps then reads it, a command that puts it in a `Ref` that `view` shows, a message built in `view` that `update` stores, a subscription that reads it, `init` that puts one list at two places, none. Pages driven by clicks and `advance`. |
| `blowup` | 4 | The fault of §3 at 12 levels (fast), as a direct call and through a `Ref`. |

Hand probes, about 80, were written before the families; they are not in the generator. They tried:
markup kept in the model (`{ items, cache : Html Msg }`), a model whose rows hold one list twice, a
command that reads a model list after a sleep, `Random` generators that hold a list (`constant`,
`list`, `map`), `Schema.decode`, `encode`, `write` and `read` of a list and of one host value read
twice, the `alternatives` exception (`[ xs, g xs ]` with `g` the identity), cross-module field
labels with records whose field sets differ, `Task.bracket`, `onExit` and `spawn` with a list the
work writes, folds whose answer becomes an element (`List.foldl`, `foldr`, a hand-written fold),
callbacks of `core/` that write their element (`filter`, `partition`, `sortBy`, `filterMap`, `any`,
`map`, `indexedMap`, `update`, `concatMap`, `Dict.map`, `filter`, `update`, `foldl`), mutually
recursive local functions kept in a `Ref`, `Browser.program` and `browser-inline`'s `Tea.sandbox`.

## 2. The verdict table

| Family | Twin | SAME | REFUSED | LIMIT | TRAP | DIFF | CRASH |
|---|---|---:|---:|---:|---:|---:|---:|
| `chain` | live | 15 | 1 985 | 0 | 0 | 0 | 0 |
| `chain` | dead | 1 756 | 244 | 0 | 0 | 0 | 0 |
| `tree` | live | 0 | 10 | 0 | 0 | 0 | 0 |
| `tree` | dead | 8 | 2 | 0 | 0 | 0 | 0 |
| `dflt` | live | 0 | 40 | 0 | 0 | 0 | 0 |
| `dflt` | dead | 10 | 30 | 0 | 0 | 0 | 0 |
| `entry` | live | 4 | 24 | 0 | 0 | 0 | 0 |
| `entry` | dead | 28 | 0 | 0 | 0 | 0 | 0 |
| `blowup` (12 levels) | live | 0 | 2 | 0 | 0 | 0 | 0 |
| `blowup` (12 levels) | dead | 2 | 0 | 0 | 0 | 0 | 0 |
| `blind7f-faults/closure-dag` (24 levels) | live | 0 | 0 | 0 | 0 | 0 | 1 (timeout) |
| `blind7f-faults/closure-dag` (24 levels) | dead | 0 | 0 | 0 | 0 | 0 | 1 (timeout) |

No `PLAINFAIL` is left in the final runs. The 15 `chain` and 4 `entry` live programs that are `SAME`
are correct: the chain dug out a default value (`Nothing`'s list, an empty kid list), not `inner`,
and the `entry … none` case has no holder, so its live twin is its dead twin.

## 3. The fault: the walk over captured closures has no bound

**The program** (`blind7f-faults/closure-dag.dead/Main.beni`, hand-minimised; the live twin also
prints `xs` after the write):

```text
go n =
    a0 = λl → List.take l n
    b0 = λl → List.reverse l
    c0 = λl → List.drop l 1
    a1 = λl → a0 (b0 (c0 l))
    b1 = λl → b0 (c0 (a0 l))
    c1 = λl → c0 (a0 (b0 l))
    … 24 levels …
    xs = [ n, 2 ]
    ys = List.push xs 3
    show ys ++ show (a24 [ 4, 5 ])
```

**Measured** (one job, ReleaseSafe; three closures per level, `a<N>` called directly):

| Levels | v3 | plain |
|---:|---:|---:|
| 8 | 46 ms | 12 ms |
| 10 | 53 ms | |
| 12 | 116 ms | |
| 14 | 707 ms | |
| 16 | 6 279 ms (6 823 ms in a second run; the live twin 6 887 ms) | 14 ms |
| 24 | does not end within `run.mjs`'s 120 s; by the factor of 9 per two levels, about 11 hours | 15 ms |

With two closures per level the factor is 4 per two levels when the leaf writes its parameter (22
levels: 8.4 s; 24 levels: 33.6 s), and 3 per two levels when no closure writes (22 levels: 0.7 s).
The same growth shows when the last closure is kept in a `Ref` instead of called (`flowTop`), and
for a program that v3 accepts.

**The rule.** Kernel §8 says that each resource limit "falls to the pessimistic side, so it costs
precision and never soundness", and names "a `flow` deeper than 16 is the `top` use" as the bound of
`flow`. §6.2 and §6.8 send a known function's captured functions to the use the two contracts
compose to (`flowCaptures`), and `top` does the same (`defaultParams`, `flowCaptures` with `top`).

**The code.**

- `src/own3/Frame.zig:3773-3777` (`flow`): past depth 16 the function goes to a new `top` use whose
  `depth` is not set, so it is 0. `flowCode` with `top` (`Frame.zig:3816`) keeps that depth and calls
  `flowCaptures`, whose `innerUse` (`Frame.zig:3902`, `depth = up.depth + 1`) adds one. So the walk
  goes on for 16 more levels, then resets again: the depth limit bounds nothing.
- `src/own3/Frame.zig:3890-3899` (`flowCaptures`) flows each captured function to its inner use, and
  there is no memo of a function already judged at an equal use. A closure that two closures above
  it capture is walked once for each path to it. A DAG of `k` closures per level, each capturing the
  `k` below, has `k^N` paths at depth `N`.

**Which is wrong.** Both. The code resets the depth that the rule names as the bound. And the rule's
argument is short even with the depth kept: a depth of 16 still allows `3^16` (43 million) paths, so
"each limit is a resource limit" does not hold for `flow` as written. A bound needs a memo — a
function judged at a use that adds nothing new is not walked again — or a count of the flows of one
frame that falls to a loud `ownership_limit`, as v2 does.

**v1 and v2.** v1 refuses the live twin and accepts the dead one, each in 15 to 17 ms. v2 refuses
both at once, in about 150 ms, with `OWNERSHIP CHECK TOO LARGE` (its loud limit).

**How real it is.** The shape is synthetic. It needs a DAG of local closures, each capturing more
than one closure of the level below, about 20 levels deep: 60 local closures in one function. Hand-
written combinators (parsers, validators, decoders built in a `let`) come close to it. A compile
that does not end is a fault whatever the program.

## 4. Where I looked hardest, and what held

- **The call map (§4.1).** `Loc.cover` with a caller cycle that is wider than the signature's
  (`Tree T`, `T` holds `List (Tree T)`), through `labelOf`, `kidsOf`, `firstKid`, `relabel`; the
  fallback that maps a deep location to the one wide entry of the signature; rows in both
  directions (`itemsOf`, `rowSame`, `rowSwap`, a row-typed `update`). No program of the `tree` and
  `chain` families was accepted wrongly. One reading of the code that I could not turn into a
  program: `answerOwn` and `answerOfCode` narrow a wide entry to the callee's entry at the same
  label path (`exact`, `Frame.zig:4341-4347` and `4579-4587`; `4250-4256` in the draft walk too)
  and take `Loc.hits(cv, e)` as the test,
  which is true for `Loc.all`. Where the use's layout is concrete and the function's is generic over
  a wider cycle, the entry at the same path can name fewer cells than the use's entry. Every
  program I wrote to reach it was refused earlier, by the caller's atoms.
- **The default (§6.2, §6.8).** All 40 live programs of `dflt` were refused: a write directly after
  the hand-off, by a method call, by a later binding, by a callee, and an answer the caller writes.
  The default refuses the dead twins too wherever the function is not called directly (§5).
- **The entry (§6.13).** Records, a row-typed `update`, triples, a triple written by a generic
  helper, an `Html` in the model, a model whose rows hold one list twice. Every holder was refused
  and every dead twin accepted.
- **Markup (§6.12).** `Html` kept in the model is refused at the entry. `Browser.program` and
  `browser-inline` accept the plain counter.
- **Folds (§6.8).** A fold whose answer becomes the next accumulator and is an element of the folded
  list is refused when the list is read after it and accepted when it is not, for `List.foldl` and
  `foldr`.

## 5. Precision losses

Real-looking first.

1. **A writer chosen by `if`, or kept in a record field, is refused even when it is called at
   once.** `f = if n > 0 then work else work` then `f g xs`, and `r = { f = work }` then `r.f g xs`,
   are refused with "a function that writes its parameter goes where the checker does not follow
   it". In `call`, a callee that is a `join` of known functions goes to `top`
   (`Frame.zig:3000`), and a function in a record goes to `top` where the record is made. The
   same function called by name is accepted. A record of handlers and a strategy chosen with `if`
   are common.
2. **`Dict.update` with a callback that edits the value in place** (`λm → Maybe.map m λv → List.push
   v 0`) is refused (`supply`), and so are `Dict.map` and `Dict.filter` with such a callback.
   `core/Dict.beni` says that `focus` is there so that the edit can be in place.
3. **A hand-written generic fold** (`myFold : List a, b, (a, b → b) → b`) is refused (`supply`)
   where `List.foldl` with the same callback is accepted.
4. **A list read back out of a dead `Dict`** (`Dict.get (Dict.singleton 1 v) 1`) is never writable
   (`unknown`). All 244 refused dead `chain` programs pass the list through a `Ref` or a `Dict`; the
   `Ref` ones hold the list in a live cell and are right to refuse.
5. **A local function that writes what a captured lambda answers** (`g l = f (h l)` with
   `h = λl → List.take l n`, `f` writes its parameter) is refused at the call: "it is the answer of
   a function parameter". The captured lambda is known.
6. **A function that writes after it handed the list on is refused in every default holder**, even
   when the function parameter keeps a copy (30 dead `dflt` programs). This is the rule of §6.8 (the
   default keeps what it is handed), not a fault of the code.

## 6. What I did not cover

- `browser` with `Browser.hosted` and `settle`, `Tea.document`, `Tea.application`, `browser-inline`
  beyond the plain counter, and markup on `node` (SSR, `For`, `Show`, `Html.map`): only by hand, a
  few programs.
- Derived `eq`/`compare` (§6.11) and the 4 096-location limit (§8): read in the code, not probed.
- Recursion groups past a few rounds, and local function groups near their 16 rounds.
- Records, cells and fibers as written values: out of v3's scope.
- Identity skips in runtimes (#2504) and anything that the sanitiser cannot see, as the brief said.
- A second compile-time limit: I did not look for one in `resolve` (depth 12, which a `.answer` path
  can widen), `answerOfCode` or the entry's fixed-point loop over model locations.
