# Research report 133: a tenth blind test of the v3 kernel (reader I), at the boundary

*2026-11-14. Commit under test: `fc22a06d73` (branch `ownership-v2-design-review`). Reader I, the only
reader of this round. The angle: markup, platforms and codecs. Nothing under `src/` was changed.*

## 1. Verdict

Two faults.

1. **A `let` that the `dom` lowering keeps across renders is written in place.** v3 accepts the write. The
   next render reads the written array. 18 programs trap, on `browser` and `browser-tea`. v1 and v2 accept
   the same programs.
2. **A chain of writes makes v3's walk slow past its module budget.** 400 writes, each of the list that the
   one before answered, take 17.8 s in v3's own phase (LLVM ReleaseSafe) and more than 120 s on the
   self-hosted ReleaseSafe build. 2 000 of them take more than 120 s on LLVM too. The budget is passed
   after about 85 writes; the time after that is not bounded.

No other probe found a fault. Every `live` program of the other families is refused or prints the same.

## 2. What I probed

The generator is `bench/ownership-sweeps/blind10i.mjs`. It writes 474 programs in seven families. I ran
it with `run.mjs` on a self-hosted ReleaseSafe beni (`zig-out/safe/bin/beni`) and ran three of its sets
again on an LLVM ReleaseSafe beni.

```sh
node bench/ownership-sweeps/blind10i.mjs <out>/all
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --jobs=16 --tmp=<disk> <out>/all
```

| Family | Programs | What it does |
|---|---:|---|
| `dom.*` | 156 | `Browser.program` on `browser`. `update` writes `model.items` in place (`push`, `set`, `update`). The view shows it through 26 holders: text holes, helpers of one module and of a second module, records built in the render, `For` in four modes, rows of rows, a keyed `Show`, class and style lists, a `let`, `Html.map`, a component with a prop or children, a controlled input, a branch, a `case`. `live` keeps the old list in the model and shows it |
| `inline.*` | 156 | the same pages on `browser-inline`, against a copy of the platform with no `"lists"` key (below) |
| `tea.*` | 36 | `Tea.element` on `browser-tea`. A command (`perform`, a lambda, `keyed` under the four policies, a list as the key, `task`, `afterRender`, `batch`, `map`, `do`) or a subscription (`Sub.listen` body or key, `Time.every`, `onResize`, `Sub.map`, `Sub.batch`) holds a list of the model; `update` then writes it; the holder reads it after a sleep or an event |
| `memo.*` | 72 | a `let` of a view, of a helper's root or of a component's root, written in place in the view, on `browser` and `browser-tea` |
| `ssr.*` | 28 | markup on `node` over a list, rendered after or before the list is written: 14 holders, among them a closure, a pair, a list of markup and two renders of one markup |
| `codec.*` | 18 | `Json.encodeValue` then `decodeValue` (derived codecs), `Schema.decode`, `encode`, `write` then `read`, a declared schema, `Schema.converted`: the decoded list is written and the source is read, or not |
| `slow.*` | 8 | chains of 50 to 400 writes, and controls with the lists apart |

**The `browser-inline` oracle.** That platform's manifest says `"lists": "in-place"`, so its plain build
already edits in place (v1). The generator copies `platforms/browser-inline` and `platforms/html` below its
output directory and removes the `"lists"` key from the copy. The plain build of the copy copies; the
build with `--ownership-everywhere` edits in place. I checked the copy on a page that v1 refuses: its plain
build shows the copying answer. `browser-inline` refuses `For`, class and style lists, `let`s in a view and some
other forms, so 114 of its programs do not build (`PLAINFAIL`).

**By hand**, outside the generator: two mounts of one program with `Browser.programs` and `mountAt`;
`Browser.hosted` whose `settle` writes the model; `--release` builds whose optimiser
could move a read past a write; whether a list literal in a function is shared between calls; a view
with 2 000 holes, a model of 1 000 lists, markup 800 levels deep, 20 nested `For`s, 200 nested
`Html.map`s and 500 handlers, each timed with `--self-profile`. None of these was a fault.

**LLVM.** I built `-Doptimize=ReleaseSafe` (LLVM) once and ran the `dom`, `ssr` and `memo` sets again
with it (`--tag=llvm`): 280 programs. Each verdict is the self-hosted build's.

## 3. Verdicts

| Family | SAME | REFUSED | TRAP | DIFF | CRASH | PLAINFAIL |
|---|---:|---:|---:|---:|---:|---:|
| `dom` | 72 dead | 78 live, 6 dead | 0 | 0 | 0 | 0 |
| `inline` | 21 dead | 21 live | 0 | 0 | 0 | 114 |
| `tea` | 18 dead | 18 live | 0 | 0 | 0 | 0 |
| `memo` | 20 dead, 2 live | 4 live, 24 kept, 4 dead | **18 live** | 0 | 0 | 0 |
| `ssr` | 12 dead | 14 live, 2 dead | 0 | 0 | 0 | 0 |
| `codec` | 0 | 9 live, 9 dead | 0 | 0 | 0 | 0 |
| `slow` | 5 | 2 | 0 | 0 | **1** (the 120 s timeout) | 0 |

The two `memo` programs that print the same are the `List.update` shape: the in-place build gives the
plain answer there. `run.mjs` counts a build that its timeout kills as `CRASH -1`; that is `slow.chain400`.

## 4. Fault 1: a `let` the `dom` lowering keeps is written in place

**The program** (`bench/ownership-sweeps/blind10i-faults/view-let-kept.live`):

```text
view model =
    xs = [ 1, 2 ]
    ys = List.push xs model.k
    <main>
        <button id="add" onClick={Add}>add</button>
        <p>{show ys}</p>
    </main>
```

`update` only adds 1 to `model.k`. The plain build shows `1,2,0`, then `1,2,1`, then `1,2,2`. With
`--ownership=v3 --ownership-everywhere --sanitize-lists`, v3 accepts the push. The first render is right.
The click after it traps: *a stale read of a list (read slice), which `List.push` … changed in place*.
Without the sanitiser the page would show `1,2,0,1`.

**Why.** `xs` and `ys` are `let`s that only the markup root reads. `backend.md` §15.4, *The `let` rule*,
and `language.md` §11.11 say that the root evaluates such a `let` at its first render, keeps the value in
the instance (`i.d0`), and evaluates it again only when a path that it reads changed. `xs` reads no path, so
the root makes `[ 1, 2 ]` once. `ys` reads `model.k`, so it runs on each render and pushes onto the one kept
array. The emitted code:

```js
if ($i$1.d0 === undefined) { const $t$4 = [1, 2]; $i$1.d0 = $t$4; }
const $let$5 = $i$1.d0;
if ($input$3.k !== $i$1.l1_0) { $i$1.l1_0 = $input$3.k; const $t$6 = List$push($let$5, $input$3.k); $i$1.d1 = $t$6; }
```

v3 walks `view` as a function whose `let`s are made on each call. In that walk `xs` is a fresh list, and
nothing reads it after the push, so the write passes the four tests of §5.

The same happens when the kept `let` reads only scalar paths (`xs = List.repeat 2 model.j`: it is kept while
`j` does not change; `view-let-scalar.live`, on `browser-tea`), when it is a record or a tuple that holds the
list, a list of lists, a chain of two writes, `List.set`, and when the root is a helper's
(`card k = …`) or a component's (`Comp.counter`). A write in a hole (`{show (List.push xs model.k)}`) is
refused, because the markup holds what a hole reads.

| | |
|---|---|
| Kernel section | §5.3 (the clock follows the order of the emitted JavaScript) and §6.14, last row: "a lowering that rewrites the program … the checker trusts each lowering to keep the program's calls and their order". The row names the `browser-inline` hook, the suspendable twin and the helper re-made at render. It does not name the root's kept `let`s |
| Code | `platforms/browser/zig/dom.zig:884-911`: each `let` of `Root.lets` is kept as `d<k>`; at `:892` a `let` that reads no path is evaluated once; at `:896` a scalar path keeps it while the path is `===`. `src/own3/Frame.zig:2179` (`.markup`) sees only what the holes read; `xs` is read by the binding of `ys`, outside the markup, so nothing in `src/own3/` knows that the value outlives the call |
| What is wrong | The rule. A kept `let` is a holder that outlives the frame: a value that one call of `view` made is read by a later call. §6.14 says the checker trusts lowerings to keep the program's calls, and this lowering does not make the call. Either the checker counts such a `let` as held by the root (an escape, or `outside`, so that no write of it is accepted), or the lowering does not keep a `let` whose value a later `let` of the root writes. `language.md` §11.11's amendment of 2026-10-15 ("a list that is `===` the last one may have been written in place") covers the paths that a value reads, not the kept value itself |
| Twins | `view-let-kept.kept` reads `xs` after the push in the same render: v3 refuses it. `view-let-kept.dead` makes `xs` with `List.copy model.items`: a list path, which the root treats as changed on every render, so `xs` is new each render; v3 accepts it, and it prints the same |
| v1, v2 | Both accept `view-let-kept.live` and `view-let-scalar.live` with `--ownership-everywhere`, and both trap. Both refuse `.kept`. No shipped platform edits in place with the `dom` lowering, so no shipped program is wrong today |

## 5. Fault 2: a chain of writes is slow after the budget

**The program** (`blind10i-faults/chain-of-writes.slow`): one function, `x0 = [ k ]`, then
`x1 = List.push x0 k` … `x400 = List.push x399 k`, then `x400`.

| Writes | v3's own phase (LLVM ReleaseSafe) | Verdicts |
|---:|---:|---|
| 80 | 77 ms (the whole check) | all 80 accepted |
| 90 | 81 ms | 73 accepted, 17 refused (`limit`) |
| 100 | 70 ms | refused from the 40th on (`limit`) |
| 200 | 1.1 s | the same |
| 400 | 17.8 s | the same |
| 500, in a view | 40.1 s | the same |
| 2 000, in a view | more than 120 s | killed |

The control (`chain-of-writes.control`, 400 pushes on lists apart) takes 12 ms. v1 and v2 check the chain
in 15 and 17 ms and accept it. The self-hosted ReleaseSafe build does not finish 400 in 120 s.

Each doubling past the budget costs 16 times more: the time grows with the fourth power of the length.
Two stack samples (gdb on the self-hosted ReleaseSafe build, at 9 s and 10 s) are each deep in
`markAtomIn`, which calls itself; the full one is
`walkBody → binding → eval → call → apply → applyAt → demand → markAtom → markAtomIn`. `markAtomIn`
follows the run of each `version` entry, and the new name of each push holds the one before.

| | |
|---|---|
| Kernel section | §8: "a module passes its budget by at most one such piece of work", "past either budget every walk returns at once", and "every other loop of a declaration's walks … is counted by the elements it visits" |
| Code | `src/own3/Frame.zig:1519-1543` (`markAtom`, `markAtomIn`): a recursive walk over the runs of `version` and `taken` entries, with no `charge`. It is called from `demand` (`:1753`) for each written atom, and at `:1495` and `:3140`. `tick` and `charge` (`:453`, `:469`) stop counted work only; `Check.walkDecl` (`src/own3/Check.zig:1279-1280`) still walks the whole body and runs `finish` after the budget is passed |
| What is wrong | The code: a loop that no memo bounds and that is not counted, so the bound of §8 does not hold for it |
| v1, v2 | Fast, and both accept the chain |

**Precision.** A straight chain of about 85 pushes in one function passes the module budget (17 104 896
units for 1 040 tokens), so the counted work of a chain also grows faster than its length.

## 6. Precision, briefly

- A component's props and children escape (§6.12), so a component handed a list of the model makes every
  write of that list refused (`dom.comp.*`, `dom.children.*`, `ssr.comp.*`, `ssr.children.*`). A
  component that shows a list of the model is common in real pages.
- Every write of a list that a codec decoded is refused: `Json.decodeValue`, `Schema.decode`, `read` and a
  compiled schema answer code with no contract (§3.2), so their answer is `outside` (all 9 `codec.*.dead`).

## 7. What I did not cover

- A real browser: every page ran under happy-dom. `test-browser` (Chrome) was not run.
- `Tea.document`, `Tea.application` and `Browser.Navigation`, `Http` at run time (the `respond` steps), WebSocket, storage
  and workers. `Browser.Worker` is a walked platform function, not an entry, so it was left out.
- The keyed `For` and `Show` that compare a kept list by `===` (deferred, #2504).
- `--release` beyond a few hand probes: the sanitiser refuses `--release`, so a release fault would show
  only as a `DIFF`.
- The time of the `dom` lowering itself: 20 nested `For`s take 40 s to emit, in the plain build as well
  (v3's phase: 0 ms). It is not v3's.
