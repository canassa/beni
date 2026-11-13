# 121. The ownership kernel, blind reader C

*2026-11-13. A blind soundness test of the ownership checker v3 (`src/own3/`, `--ownership=v3`) at
commit `a2c60aa2b7`, by reader C. Its angle: each rule of `ownership-v3-kernel.md` read against the code
that implements it, and each rule's argument tested with a program. Another reader worked on the same
commit without contact. Nothing under `src/` is changed.*

## 1. Result

**Four faults.** v3 accepts each of the four programs below, and the in-place build traps under the
list sanitiser. Each fault has a minimal program and a safe twin in
`bench/ownership-sweeps/blind5c-faults/`. Three are in the entry rule and the markup rule (kernel §6.12,
§6.13). One is in the argument of §6.12 itself.

| Fault | Shape | Rule | Wrong | v1 | v2 |
|---|---|---|---|---|---|
| `entry-tuple-pair` | the model is a tuple, and `update` answers `( model, Cmd msg )` | §6.13 | code | refused | trap |
| `entry-unknown-view`, `entry-unknown-settle` | a function of the program's record has no known code (`if alt then viewB else viewA`) | §6.13 | code, and the rule's text is silent | refused | trap |
| `hole-closure` | a hole of markup makes a closure that reads a local list | §6.12 | code | trap | trap |
| `row-parameter` | a `For` row or a `Show` body puts its parameter in an event's message | §6.12 | the rule's argument | refused | trap |

"v1" is `--ownership=v1 --ownership-everywhere --sanitize-lists` and "v2" the same with `v2`, on the
same commit.

## 2. What I probed

I read `src/own3/Frame.zig` (the entry walk, markup, folds, method calls, flows), `Check.zig` (worded
rows, derived facts, the module), `Loc.zig` (layouts and the limit) and `Enforce.zig`, with the kernel
beside them. Then I wrote small programs where a negative fact looked assumed, and turned each corner
that broke into a section of a generator.

```sh
node bench/ownership-sweeps/blind5c.mjs <out>            # 226 programs
node bench/ownership-sweeps/run.mjs --beni=<ReleaseSafe beni> --checker=v3 --jobs=8 --tmp=<dir> <out>
node bench/ownership-sweeps/run.mjs --beni=<ReleaseSafe beni> --checker=v2 --jobs=8 --tmp=<dir> <out>
node bench/ownership-sweeps/run.mjs --beni=<ReleaseSafe beni> --checker=v3 --tmp=<dir> bench/ownership-sweeps/blind5c-faults
```

The sections of `blind5c.mjs`:

| Section | Programs | Corner |
|---|---:|---|
| `pair` | 30 | `browser-tea`'s `Tea.element`: 5 model shapes (4 tuples, 1 record as the control) × 3 makers of sharing (one list twice in `init`, a top-level list in `init`, one list twice in `update`) × live/dead |
| `nocode` | 66 | 11 ways to write a function of the record (directly, `if`, `case`, a call's answer, a field of a local record, `fst` of a pair, an identity call, `Maybe.withDefault`, a lambda, a local alias, a local `if`) × `view` (on `browser` and `browser-tea`) and `settle` (on `Browser.hosted`) × live/dead |
| `hole` | 32 | 8 ways a hole reads a local list (directly, an applied lambda, a local function, `Maybe.map` and `List.map` callbacks, an `if`, a top-level helper handed a lambda, a record of a lambda) × `browser`, `browser-tea` × live/dead |
| `row` | 20 | `For` over a field, keyed, over a literal; `Show` over a field and over a `Just` × `browser`, `browser-tea` × live/dead |
| `derived` | 56 | 8 shapes of generic types of other modules around `T`, whose `pub eq` and `pub compare` write their operand (`Box (Box T)`, `Pair 1 (Box T)`, a tuple, `Maybe`, a nominal `W T Int` inside `Box`, a record, a list, `Result`) × `==`, `<`, `List.sort`, `List.member` × live/dead |
| `fold` | 16 | `List.foldl` and a hand-written fold × a callback that answers one list at two places of a pair or a record, a new list at two places, or an element it keeps × live/dead |
| `limit` | 6 | `( x, x )` nested 11, 12 and 13 times over `List Int` (2¹¹, 2¹², 2¹³ locations) × live/dead |

I also tried, by hand: the program's record given as a top-level value or a local (refused, correctly);
`update` as one of two functions (refused); a handler in a `For` row that captures the model (refused);
a list written in place in a keyed and a positional `For` row of the `dom` runtime (accepted, correct);
the `alternatives` exception of §4.4 with `List.update` answering another element (refused); a derived
`eq` of `Box (Box T)` across three modules (refused).

## 3. Verdicts

v3, generator:

| Section | SAME dead | REFUSED dead | SAME live | REFUSED live | TRAP live |
|---|---:|---:|---:|---:|---:|
| `pair` | 15 | 0 | 0 | 3 | **12** |
| `nocode` | 33 | 0 | 0 | 15 | **18** |
| `hole` | 16 | 0 | 0 | 6 | **10** |
| `row` | 10 | 0 | 0 | 0 | **10** |
| `derived` | 12 | 16 | 0 | 28 | 0 |
| `fold` | 2 | 6 | 0 | 8 | 0 |
| `limit` | 2 | 1 | 0 | 3 | 0 |
| total | 90 | 23 | 0 | 63 | **50** |

No program was `DIFF`, `CRASH`, `LIMIT` or `PLAINFAIL`, and every compile ended. The fault folder: 5
`TRAP` (each `.live`), 5 `SAME` (each `.dead`).

v2 on the same 226 programs: 74 `TRAP`, 2 `SAME` live, 37 `REFUSED` live, 81 `SAME` dead, 32 `REFUSED`
dead. v2 traps on every live program of `pair`, `nocode`, `hole` and `row`.

## 4. The faults

### 4.1 `entry-tuple-pair`: a tuple model when `update` answers a pair

```text
init ⊤ =
    xs = [ 1, 2 ]
    ( ( xs, xs ), Cmd.none )

update Add ( a, b ) = ( ( List.push a 7, b ), Cmd.none )
```

The view shows `List.length b`. v3 accepts the push in place, so `b` grows too.

**Rule** (§6.13): a model location is `own` only where each source of it, in the answer of each
producer, is a cell the producer made at no other location, or an `own` location of its model
parameter.

**Code** (`Frame.zig:4885`–`4894`, `entryCall`): the walk decides whether a producer's answer is the
model itself or a pair whose first part is the model. It sets `direct = false` when an answer location
is below `.0`, and then sets `direct = true` again when a *model* location is below `.0`. A tuple model
always has its first part at `.0`, so the answer of `Tea.element`'s `init` and `update` is read as the
model itself. Then the model location `.0` is looked for at the answer's `.0`, which is the whole model
and has no entry. No source is found, no test fails, and every model location stays `own`. All of a
tuple model's lists are `own` whatever `init` and `update` answer: one list twice, a top-level list, or
`update`'s `( a, a )`. A record model (the control) is judged correctly.

**The code is wrong.** The rule is right.

### 4.2 `entry-unknown-view` and `entry-unknown-settle`: a function with no known code

```text
main =
    Browser.program
        { init = λ⊤ → { items = [ 1, 2 ], seen = 0 }
        , update = update
        , view = if alt then viewB else viewA
        }
```

`viewA` gives an outer `div` the message `Report model.items` and an inner button `Add`. A click on the
button runs `update` (which pushes onto `items`), then bubbles to the `div`, whose message the runtime
kept from the last render. With `view = viewA` v3 refuses (`view` lets `model.items` escape). With the
`if`, it accepts.

The settle twin: `settle = if alt then settleB else settleA`, where `settleA` puts `model.items` at a
second field once. v3 accepts the push, and the second field changes.

**Rule** (§6.13): the producers are `init`, `update` and `settle`; the other functions of the record
keep what they write, let escape, hand on or answer. The kernel's principle (§1) says a fact that no rule
derives is the pessimistic one.

**Code** (`Frame.zig:4803`): a field whose value has no known code (`codeOf` is null: a `join`, the
answer of a call, an `unknown`) goes to `flowTop` and is left out of `fields`. `flowTop` refuses such a
function only if it *writes* its parameter. So it is neither a producer nor one of "the other
functions": what it keeps or answers is not read. For `settle`, `Frame.zig:4872` then skips the
missing producer (`continue`). For `init` the code does the right thing: a missing `init` makes every
location not `own`.

Forms that reach this (from `nocode`): `if`, `case`, a call's answer (`pick viewA viewB`), `fst` of a
pair, `Maybe.withDefault`, a local bound to an `if`. Forms that do not: a direct name, a field of a local
record, an identity call, a lambda, a local alias.

**The code is wrong.** It reads "no contract" as "keeps nothing". The rule's text names no case for a
function with no contract; the principle of §1 covers it.

### 4.3 `hole-closure`: a closure made in a hole

```text
view model =
    xs = List.copy model
    m = <p id="m">{(λ⊤ → List.length xs) ⊤}</p>
    ys = List.push xs 5
    <main>{m}<p id="y">{List.length ys}</p></main>
```

The `dom` lowering evaluates the hole where it renders, after the push. v3 accepts the push in place. The
plain build shows 2; the in-place build reads `xs` after the push, and the sanitiser traps.

**Rule** (§6.12): a lowering may evaluate a hole's expression where it renders, so the markup holds the
value of every local and capture that a hole reads.

**Code**: the markup collects what a hole reads in `markup_reads`, and only `evalInner .local` appends to
it (`Frame.zig:1736`, `1752`). A lambda's captures are read by `closureOf` through `capSlot`
(`Frame.zig:2632`), which appends nothing. The lambda is the callee, not the hole's value, so the markup
holds neither the closure nor `xs`. The same hole through `Maybe.map`, `List.map`, an `if`, or a
top-level helper handed the lambda (`count (λ⊤ → List.length xs)`) traps too. The helper case has a
second gap: a hole whose value is text is not taken as a helper (`Frame.zig:2062`, "a hole of text is
written where it is"), but the `dom` lowering evaluates it where it renders.

**The code is wrong.** The rule says "every local and capture that a hole reads".

### 4.4 `row-parameter`: a row's parameter kept by an event

```text
<For each={model.rows} keyed={False}>
    {λl →
        <div class="outer" onClick={Report l}>
            <button class="add" onClick={Add}>add</button>
        </div>
    }
</For>
```

`update`'s `Add` writes `model.rows`'s first row in place. The click bubbles to the `div`, whose message
holds that row as it was. The same with `Show when={model.v}`, a `For` over `[ model.v ]`, and a keyed
`For`.

**Rule** (§6.12): every value at an item that no row names as an attribute escapes where the markup is
made; the runtime keeps an event's message after the render (`boundary.md` §9.4.8).

**Code**: the message is made in the row function's own frame, from its parameter `l`. There it
escapes, and the row function's contract says that its parameter escapes. But in the view's frame the
row function is a hole's value, a closure that answers markup, so it is only read
(`Frame.zig:1918`–`1921`), and `keptItems` skips `For` and `Show` (`Frame.zig:2017`). Nothing hands
the closure the items of `each` or the value of `when`, so the escape of its parameter is never applied
to them. `view`'s contract has no escape of `model.rows`, and the entry rule calls the rows `own`.

**The rule's argument is wrong.** It counts the escapes of the markup that a frame makes, and treats the
values of `For` and `Show` as values read during the render. But the runtime calls the row function with
those values, as a callee calls a callback; what the function does with its parameter is a fact of its
contract that the argument leaves out. A `Show` over a `Just` built in the hole is refused only because
a built hole value escapes.

## 5. v1 and v2

| Fault | v1 | v2 |
|---|---|---|
| `entry-tuple-pair` | refused (`LIST CHANGED WHILE STILL IN USE` at the entry) | trap |
| `entry-unknown-view` | refused (`LIST MAY BE SHARED` at the entry) | trap |
| `entry-unknown-settle` | refused (at the entry) | trap |
| `hole-closure` | trap | trap |
| `row-parameter` | refused (at the entry) | trap |

Each `.dead` twin is `SAME` under v1, v2 and v3.

## 6. Precision losses

- `derived`: with `List.sort` and `List.member`, every dead twin is refused (12 programs): the part's
  writing `eq` or `compare` is handed as evidence, and §6.11 refuses a function that writes where it is
  handed, whatever the operands. Every `List (Box T)` dead twin is refused too (4). `==` and `<` on the
  other shapes accept their dead twins.
- `fold`: the dead twins of `pairdup` and `recdup` read the accumulator after the push (`List.copy a`),
  so their refusal is right; the generator's twin is not safe. `newdup.dead` (one new list and a copy of
  it) is refused with `later-use` on both folds; I did not find why.
- `limit`: the type with 2¹³ locations is refused loudly, as §8 says; 2¹² is judged exactly.
- No dead twin of `pair`, `nocode`, `hole` or `row` is refused.

## 7. What I did not cover

- `browser-inline`: its `"lists": "in-place"` makes the plain build run v1 in place, so the oracle is not
  plain. The tuple fault refuses under v1 there, and I did not build a plain copy of the platform.
- Subscriptions and commands that keep a model list (`Time.every`, `Http`), and `Tea.application`'s
  extra functions.
- Records, cells and fibers, which v3 does not judge.
- `foreign` rows and `Js.*` (other readers' corners), and schema codecs.
- A fold whose callback answers the answer of a captured function (§6.8's third case).
- The run-entry walk of the `node` platform (`Io.run`) beyond what the generators of other reports
  reach.

A disclosure: by mistake I opened the first 200 lines of `blind4a.mjs` and the folder names of
`blind4a-faults/` before I wrote anything. Its corners (a derived method, a fold that lets its answer
escape, the entry with `page`) are named in the kernel's §6.8, §6.11 and §6.13 too. None of the four
faults above is in them.

*Sources: `ownership-v3-kernel.md` §1, §6.8, §6.11–§6.13, §8; `boundary.md` §9.4.8; `src/own3/Frame.zig`.*
