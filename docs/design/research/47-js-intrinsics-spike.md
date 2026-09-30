# The DOM runtime in beni, over privileged `Js` intrinsics: a spike

**Status:** research, 2026-10-01. Not normative. A spike the owner asked for: could the browser
platform's hand-written DOM runtime (`platforms/browser/runtime.js`) be written in beni itself, so
that the compiler's optimisations apply to it, using a privileged `Js` namespace of compiler
intrinsics — ClojureScript's `js/` interop, importable only by core and platform packages? §2 is the
draft specification, §3 what was built, §4 the port, §5 the measurements, **§6 what the compiler is
missing**, with an estimate each. **Read §0, then §6.**

**What this is not.** A change to the normative documents, or to `platforms/browser`: the port runs
in a copy of the platform (`tests/platforms/beni-runtime/`), and the runtime is compiled ahead of the
program and spliced into that copy's `runtime.js` (§4.2), not compiled with it. One Chrome batch of
five samples per cell (§5.3); the size rows are exact.

---

## 0. Findings

1. **The intrinsic layer works, costs nothing at run time, and is small.** Seventeen intrinsics in
   `core/Js.beni`, typed as `foreign` declarations so the checker types every use, written by the
   backend as the JavaScript they name — `Js.get o "f"` is `o.f`, `Js.set o "f" v` the statement
   `o.f = v`, `Js.same a b` is `a === b`, `Js.call o "m" [a, b]` is `o.m(a, b)` — with no call, no
   wrapper and no import (`emit/core/JsIntrinsics`). The gate is one test in the module graph
   (`js_outside_platform`). About 250 lines of Zig.
2. **The slot and mount half of the runtime ports cleanly**: 493 lines of beni (`Rt.beni`) for the
   125 lines of JavaScript (comments aside) that the empty page ships (`first`…`childHtml`,
   `template`, the render loop, `run`, `mount`), statement for statement, and the
   js-framework-benchmark app runs on it in Chrome with every post-condition holding.
3. **Speed: no difference measurable.** Script medians on create, replace, update, select, swap and
   remove are within noise of today's runtime on five of six operations, and every beni variant is
   below Solid 1 on all six (§5.3). The hot loops (`forKeyed`, `reconcile`) are still JavaScript;
   what moved runs once per render and once per mounted row.
4. **Size, today: +27 %.** The empty page is **980 → 1 245** brotli bytes with the port compiled by
   beni's release optimiser (1 447 when only the hand-written-JS compactor sees it), the benchmark
   app **5 117 → 5 508** (Solid 1: 4 356).
5. **Size, with the compiler this spike says is missing: −21 %.** Hand-applying to the compiled
   port what §6 lists — statement-shaped codegen for `()`-valued calls, plain loops, operators
   (−123 bytes); mutable locals and inlining of single-use top-level functions (−147 more) —
   brings the empty page to **975, level with the hand-written 980**. Whole-program
   specialisation, which only a beni-written runtime makes possible — the empty page never holds a
   list, never passes a template flag, never mounts a hosted program — takes it to **772**.
6. **Verdict: feasible, and not yet worth doing.** Moving the runtime to beni today costs a quarter
   of the empty page for no speed. The case for it is finding 5's last step, and that step needs
   compiler work (§6, items 1–8, roughly five to seven weeks) before it is anything but a cost.
   Build the items in §6's order; move the runtime when item 8 exists.

---

## 1. Method

- Compiler: this worktree at `97285ef5` plus the second commit's two intrinsics (`at`, `throw`).
  Node 24.19, brotli quality 11 over the whole release file (`_main.mjs`, one scope-hoisted file,
  `backend.md` §9), research 41's method.
- The **empty page** is `bench/size.mjs`'s: `view _ = <></>`, `Browser.program { init = {}, update
  = \_ m -> m, view = view }`, `--platform=browser --release` for today and
  `--platform=tests/platforms/beni-runtime --release` for the port.
- The **benchmark app** is `bench/ui/apps/beni/Main.beni` on `browser-tea`, and on
  `tests/platforms/beni-runtime-tea` (a copy of `browser-tea` layered on the port).
- Speed: `bench/ui/bench.mjs`, headless Chromium 153, Ryzen 9 5950X, `--taskset=4-11`, n = 5, the
  four subjects rotated per iteration, 2 min 7 s wall. Medians of script milliseconds, with the
  interquartile range (CLAUDE.md rule 8: no geometric means).

---

## 2. The draft specification

*A draft for `boundary.md` (a new §2 row and a §4 subsection) and `backend.md` §4, should the owner
take it.*

### 2.1 The module and its types

`core/Js.beni` declares one opaque type and seventeen values. Each value is a `foreign`, so the
checker types and rungs it as it does every `foreign`, and checks 1 to 4 apply to `core/Js.js`.
Being the `pub` values of the module that declares `Value`, they are also its methods, but a
dot-call (`o.get "f"`) goes through dispatch and is not written in place by this spike: it calls
the sibling. Only the qualified call is an intrinsic.

| intrinsic | type | rung | written as |
|---|---|---|---|
| `Value` | `foreign type` | — | any JavaScript value |
| `null`, `undefined` | `Value` | pure | `null`, `undefined` |
| `from` | `a -> Value` | pure | its argument: nothing |
| `to` | `Value -> a` | pure | its argument: nothing, and unchecked |
| `same` | `a, a -> Bool` | pure | `a === b` |
| `isNull`, `isUndefined`, `isNullish` | `Value -> Bool` | pure | `v === null`, `v === undefined`, `v == null` |
| `bitAnd` | `Int, Int -> Int` | pure | `a & b` |
| `global` | `String -> Value` | impure | `globalThis.name` |
| `get` | `Value, String -> Value` | impure | `o.name`, or `o[name]` |
| `set` | `Value, String, Value -> ()` | impure | the statement `o.name = v`; its value `null` |
| `at` | `Value, Int -> Value` | impure | `o[k]` |
| `call` | `Value, String, List Value -> Value` | impure | `o.name(a, b)` |
| `apply` | `Value, List Value -> Value` | impure | `f(a, b)` |
| `array` | `List Value -> Value` | impure | `[a, b]` |
| `throw` | `Value -> a` | impure | the statement `throw v`; its value `undefined` |

*The owner's list asked for a nullish test, a mutable local, a loop with an early exit and the two
constants.* The nullish tests and constants are there. **A mutable local is a property of an object
of one's own** (`Js.from { node = Js.null }`, then `Js.set`), and **a loop is a tail call**: beni's
tail-call loop (`backend.md` §8) already turns a self-call in tail position into `while (true)`, and
returning is the early exit. Both work; both cost bytes (§6 items 3, 5 and 6), and a first-class
`Js.Ref` or `let mut` is §6's answer, not this spike's.

`Js.Node` was not needed: every DOM value is a `Value`. A type alias (`type alias V = Js.Value`)
serves readability.

### 2.2 The gate

**`import Js` in a module of the root package is `js_outside_platform`**, unless the root package
may write `foreign` (`--core`, or a manifest with `"platform": true`) — exactly
`Session.fileMayDeclareForeign`'s rule, applied at the import (`resolve/Graph.zig`, the edge loop).
Core and platform packages import it freely. It is an error, and by CLAUDE.md rule 7 it has to be:
`Js.to` is an unchecked cast and `Js.get` reads a property nothing checks exists, so a program that
could import `Js` would lose "no runtime exception" and "no silent wrong answer" at once. It is the
`foreign` wall's guarantee and the same wall.

A module named `Js` in the root package is an ordinary module: the intrinsics are keyed on the core
package and the module name, never on a spelling a user can write.

### 2.3 What the emitter writes

- **A saturated call of an intrinsic** (`call` instruction whose callee is an `ext_value` of core's
  `Js`) is lowered in `Lower.callExpr` before anything else, by `jsIntrinsicCall`. The operands are
  lowered with `orderedExprs`, in written order, so an operand that hoists a statement pins the ones
  before it (`run/JsIntrinsics`'s last line: `String(o.v, (o.v = 2, null))` reads `1`).
- A property name written as a string literal that is an identifier is a `member` (`o.name`); any
  other name is an `index_get` (`o["x-y"]`, `o[k]`).
- `set` and `throw` are statements appended to the current statement list; the expression they leave
  is `null` or `undefined`, an atom.
- `call`, `apply` and `array` take their arguments **as a list literal**, whose elements are spread
  into the JavaScript call or array; anything else is refused (today an `internal` diagnostic; a
  code of its own if this is taken). No list is built at run time.
- `global` is a new `JsIr` literal, `global_this`, and not an `ident`, so no renaming pass can touch
  it — the first build of this spike wrote `globalThis` as a name and the release renamer shortened
  it to `b`.
- `null` and `undefined` written as values are the literals.
- **A declaration passed as a value** (`List.map Js.same xs`) is an ordinary reference to the
  `foreign`, and `core/Js.js` supplies it. That is the only way the sibling ships.
- **Reachability**: an intrinsic written in place is not an edge (`Reach.jsInPlace`), so a module
  that only calls intrinsics imports nothing from `Js` and the sibling is not copied
  (`emit/core/JsIntrinsics.js` has no `import` of it).

Two operators joined `JsIr.BinaryOp`: `bit_and` (`&`) and `loose_eq` (`==`, written only against
`null`).

### 2.4 Purity and effects

`get`, `set`, `at`, `call`, `apply`, `array`, `global` and `throw` are `impure`: a function that
calls one is inferred impure (`checker-v2.md` §26), and `--release` keeps any unread binding that
may be impure (`Opt`'s `keep` list), so `let _ = Js.set o "f" v` is never dropped. The tests,
conversions, constants and `bitAnd` are `pure` because they are total and do not throw — `pure`
licenses dropping an unread one, which is right for them. None of them suspends; a runtime that
needs to park a fiber still goes through `foreign suspends`.

### 2.5 Determinism, hoisting and renaming

Nothing new: an intrinsic is lowered where it stands, per module, from the `Bir` and the interfaces,
with no table and no counter. In the one scope-hoisted file, property names are `member` names,
which the printer passes as `fixed` and which are never renamed (`Rename`'s closed list); globals
are the `global_this` literal. The locals of a beni-written runtime are renamed like any other
beni code's, which is the point.

---

## 3. What was built

| file | what |
|---|---|
| `core/Js.beni`, `core/Js.js` | the module and its sibling |
| `src/js/JsIntrinsic.zig` | which intrinsic an instruction names (keyed on core + `Js`) |
| `src/js/Lower.zig` | `jsIntrinsicCall`, and `null`/`undefined` in `reference` |
| `src/js/Reach.zig` | `jsInPlace`: no edge for an intrinsic written in place |
| `src/js/JsIr.zig`, `Print.zig` | `bit_and`, `loose_eq`, `global_this` |
| `src/resolve/Graph.zig`, `src/Session.zig`, `src/diagnostic.zig`, `src/resolve/Diagnostics.zig` | the gate and `js_outside_platform` |
| `tests/corpus/check/bad/JsOutsidePlatform` | the import refused in a user package |
| `tests/corpus/run/JsIntrinsics/` | accepted in a test platform, and run, dev and release |
| `tests/corpus/emit/core/JsIntrinsics` | the golden: every intrinsic as plain JavaScript |

Adding a core module moved three existing tests by one module each (`TypeOwnerEdges`'s graph dump,
the cut-off counts in `cutoff_test`, and `docs_test`, which no longer imports `Js`).

---

## 4. The port

### 4.1 What moved

Everything the minified empty page ships from the runtime — `n`, `w`, `A`–`K`, `l`, `L`–`Q` in its
one file — which is `first`, `last`, `head`, `tail`, `put`, `drop`, `swap`, `template`, `slot`,
`parentOf`, `unit`, `patch`, `place`, `childHtml`, the render queue (`queued`, `scheduled`, `phase`,
`flush`), `run` and `mount`. The rest (`childMaybe` onwards: lists, `Show`, attributes, events, the
markup primitives) stays JavaScript, in `tests/platforms/beni-runtime-src/runtime.rest.js`, and calls
the ported functions by name.

### 4.2 How it is linked, and why that is a limitation

`tests/platforms/beni-runtime-src/Rt.beni` is a module of a package whose manifest says `"platform":
true`, so it may import `Js`. `splice.mjs` builds it with `--library`, takes beni's output, spells
`Rt$first` as `first` (the name the hand-written half and the `dom` lowering call), copies in the two
core functions it calls (`Basics.add`, `Basics.sub`), and writes
`tests/platforms/beni-runtime/runtime.js` = the compiled half + the hand-written half. With
`--release-src` it takes beni's **release** output instead, and maps its short names back — the best
available stand-in for compiling the runtime *with* the program, which is what §6 item 1 would give.

The markup runtime cannot be a beni module today: a lowering's calls import *exports of a JavaScript
file*, and a sibling may not import a file, so neither side can reach the other. That is §6 item 1.

### 4.3 Side by side

The hand-written JavaScript, the beni, and what beni writes for it (development build, then release
inside the one file):

```js
// platforms/browser/runtime.js
const patch = (i, b, cx) => {
  if (b === i.b) return i;
  if (b.t === i.t) {
    b.t.p(i, b.v);
    i.b = b;
    return i;
  }
  const n = unit(b, cx);
  swap(i, n);
  return n;
};
```

```elm
-- Rt.beni
pub patch : V, V, V -> V
patch i b cx =
    if Js.same b (Js.get i "b") then
        i

    else if Js.same (Js.get b "t") (Js.get i "t") then
        let
            _ =
                Js.call (Js.get b "t") "p" [ i, Js.get b "v" ]

            _ =
                Js.set i "b" b
        in
        i

    else
        let
            n =
                unit b cx

            _ =
                swap i n
        in
        n
```

```js
// beni, development
const Rt$patch = (i$1, b$2, cx$3) => {
  if (b$2 === i$1.b) {
    return i$1;
  } else {
    if (b$2.t === i$1.t) {
      const $t$7 = b$2.t.p(i$1, b$2.v);
      i$1.b = b$2;
      return i$1;
    } else {
      const n$4 = Rt$unit(b$2, cx$3);
      const $t$8 = Rt$swap(i$1, n$4);
      return n$4;
    }
  }
};
// beni, release, in the one file
const s=(A,b,c)=>{if(b===A.b){return A}else{if(b.t===A.t){const d=b.t.p(A,b.v);A.b=b;return A}else{const e=I(b,c),f=D(A,e);return e}}};
// the hand-written one, in the same file today
const I=(i,b,cx)=>{if(b===i.b)return i;if(b.t===i.t){b.t.p(i,b.v);i.b=b;return i}
const R=H(b,cx);E(i,R);return R};
```

The intrinsics are exact: every property access and call is the hand-written one. The difference is
all around them — `const d=` for a call whose result is discarded, `{return A}else{…}` for an early
return.

A loop:

```js
// hand-written
const put = (parent, i, before) => {
  const end = last(i);
  let n = first(i);
  for (;;) {
    const next = n.nextSibling;
    parent.insertBefore(n, before);
    if (n === end) return;
    n = next;
  }
};
```

```elm
pub put : V, V, V -> ()
put parent i before =
    putRun parent (first i) (last i) before


putRun : V, V, V, V -> ()
putRun parent n end before =
    let
        next =
            Js.get n "nextSibling"

        _ =
            Js.call parent "insertBefore" [ n, before ]
    in
    if Js.same n end then
        ()

    else
        putRun parent next end before
```

```js
// beni, development
const Rt$putRun = (parent$1, $in$1, end$3, before$4) => {
  Rt$putRun: while (true) {
    const n$2 = $in$1;
    const next$5 = n$2.nextSibling;
    const $t$1 = parent$1.insertBefore(n$2, before$4);
    if (n$2 === end$3) {
      return null;
    } else {
      $in$1 = next$5;
      continue Rt$putRun;
    }
  }
};
const Rt$put = (parent$1, i$2, before$3) => Rt$putRun(parent$1, Rt$first(i$2), Rt$last(i$2), before$3);
```

A closure's mutable state — the template cache — and the module's (`queued`, `scheduled`):

```js
// hand-written
export const template = (html, flags) => {
  let node = null;
  return () => {
    if (node === null) { /* parse into node */ }
    return flags & 1 ? globalThis.document.importNode(node, true) : node.cloneNode(true);
  };
};
```

```elm
pub template : String, Int -> (() -> V)
template html flags =
    let
        cell =
            Js.from { node = Js.null }
    in
    \() -> clone cell html flags
```

```js
// beni, development
const Rt$template = (html$1, flags$2) => {
  const cell$3 = { node: null };
  return ($p$6) => Rt$clone(cell$3, html$1, flags$2);
};
const Rt$clone = (cell$1, html$2, flags$3) => {
  const node$4 = cell$1.node === null ? Rt$parse(cell$1, html$2, flags$3) : cell$1.node;
  return (flags$3 & 1) !== 0 ? globalThis.document.importNode(node$4, true) : node$4.cloneNode(true);
};
```

And the mount, where the program's `send` closes over two `let`s the hand-written runtime assigns:

```js
// hand-written
const mount = (program, root) => {
  const s = slot(root, null, null);
  let model = program.init;
  let waiting = false;
  const render = () => { waiting = false; childHtml(s, program.view(model)); };
  root.$$root = (msg) => {
    if (!waiting) {
      waiting = true;
      queued.push(render);
      if (!scheduled) { scheduled = true; queueMicrotask(() => { if (scheduled) flush(); }); }
    }
    model = program.update(msg, model);
  };
  childHtml(s, program.view(model));
};
```

```js
// beni, development (from `mount`, `send`, `queue` and `microtask` in Rt.beni)
const Rt$mount = (program$1, root$2) => {
  const s$3 = Rt$slot(root$2, null, null);
  const state$4 = { model: program$1.init, waiting: false };
  const render$5 = ($p$17) => {
    state$4.waiting = false;
    return Rt$childHtml(s$3, program$1.view(state$4.model));
  };
  root$2.$$root = (msg$6) => Rt$send(program$1, state$4, render$5, msg$6);
  return Rt$childHtml(s$3, program$1.view(state$4.model));
};
const Rt$send = (program$1, state$2, render$3, msg$4) => {
  const $t$16 = state$2.waiting ? null : Rt$queue(state$2, render$3);
  state$2.model = program$1.update(msg$4, state$2.model);
  return null;
};
const Rt$queue = (state$1, render$2) => {
  state$1.waiting = true;
  const $t$14 = Rt$loop.queued.push(render$2);
  if (Rt$loop.scheduled) {
    return null;
  } else {
    Rt$loop.scheduled = true;
    return globalThis.queueMicrotask(($p$15) => Rt$microtask(null));
  }
};
```

---

## 5. Measurements

### 5.1 The empty page

| build | runtime part, raw / brotli | page, raw / brotli | vs today |
|---|--:|--:|--:|
| today, hand-written (`--platform=browser`) | 2 062 / 859 | 2 263 / **980** | |
| port, beni development output through the JS compactor (`splice.mjs`) | | 3 582 / **1 447** | +48 % |
| port, beni release output (`splice.mjs --release-src`) | 3 129 / 1 118 | 3 330 / **1 245** | +27 % |
| … and §6 items 2–4 hand-applied (`v1`) | 2 649 / 1 010 | 2 850 / **1 122** | +14 % |
| … and items 5–6: mutable locals, single-use functions inlined (`v2`) | 2 049 / 843 | 2 250 / **975** | −0.5 % |
| … and item 8: specialised to what this page uses (`v3`) | 1 526 / 651 | 1 727 / **772** | **−21 %** |

The runtime part is everything before the program's first `let`; the page rows append the same
program part to each (`tests/platforms/beni-runtime-src/estimates/`, §7). `v1`–`v3` are hand edits of the release port,
each a transformation §6 names and nothing else; they are estimates of what the compiler would
write, not its output. `v3` keeps every behaviour the empty page can reach (the refusals included)
and drops only code no value it builds can reach: the list half of `head`/`tail` and four slot
fields, `template`'s flag branches (it is called with `0`), the hosted mount and the after-render
phase.

### 5.2 The benchmark app

| build | raw | brotli |
|---|--:|--:|
| today (`browser-tea`) | 14 208 | **5 117** |
| port, development output through the JS compactor | 15 734 | 5 675 |
| port, release output | 15 663 | **5 508** |
| Solid 1.9.15 | 11 513 | 4 356 |

(The owner's 5 049 was measured on another tree; this is the same tree for every row.)

### 5.3 Speed

Script, median ms [IQR], n = 5. `beni-release` is today; `beni-rt` the port as development output;
`beni-rtr` as release output.

| subject | create 1k | replace 1k | update 10th ×16 | select | swap | remove |
|---|--:|--:|--:|--:|--:|--:|
| beni-release | 4.71 [4.67–4.79] | 10.6 [10.3–10.6] | 1.69 [1.68–1.74] | 1.26 [1.11–1.43] | 0.98 [0.82–1.50] | 0.52 [0.51–0.55] |
| beni-rt | 4.68 [4.68–4.70] | 10.6 [10.2–11.0] | 1.41 [1.41–1.41] | 1.27 [1.18–1.36] | 1.07 [1.03–1.44] | 0.52 [0.49–0.53] |
| beni-rtr | 4.75 [4.67–4.88] | 10.3 [10.2–10.5] | 1.48 [1.48–1.62] | 1.20 [0.97–1.23] | 1.04 [1.00–1.07] | 0.51 [0.51–0.53] |
| solid1 | 4.94 [4.94–4.97] | 12.4 [11.9–12.6] | 1.81 [1.71–2.02] | 1.43 [1.33–1.83] | 1.83 [1.67–2.02] | 0.77 [0.57–0.79] |

Orderings: on create, replace, select and remove the three beni rows are within each other's
ranges. On swap the port is 0.06–0.09 ms slower at the median with overlapping ranges. On update the
port is 0.2–0.3 ms *faster* with ranges that do not overlap; nothing in the port explains it (the
update path runs `patch` on 100 rows, which the port writes as the hand-written one does), so it is
recorded and not claimed. Every beni row is below Solid 1 on all six operations, as today.

---

## 6. What the compiler is missing

In the order to build them. Bytes are the empty page's, from §5.1; each estimate is for a slice with
its spec amendment, fixtures and gates.

1. **A runtime module the lowering can call** (enabler, 0 bytes by itself; ~1 week). A manifest key
   (`"markup": { "module": "Rt" }`) naming a beni module of the platform whose `pub` values stand
   in for runtime exports: `Lower.markupRuntime` refers to the declaration instead of importing from
   the file, and `Reach` roots, before lowering, the declarations of the exports the lowering
   declares (`boundary.md` §9.4.5's list) — coarse, then cut by the lowering's actual imports once
   lowering tells `Reach` which it used. The hand-written remainder must also reach the beni half,
   which needs the inverse: a runtime file that may name a beni module's exports (today it may import
   nothing). Without this the port is a two-stage build, as here, and items 7–8 cannot see the
   program.
2. **A discarded call is a statement** (part of −123; ~2 days). `let _ = f x` writes `const $t = f(x)`
   and `Opt` keeps it because it is impure; it should be `f(x);`. Likewise a `()`-valued function
   `return null`s: in a function whose result is `()` and whose callers all discard it, the value
   need not be written; and `let _ = if c then a else b` should be an `if` statement, not a `let`
   assigned in both arms. `throw` should end its block (today a dead `return undefined;` follows it).
3. **The tail-call loop without a label and without parameter copies** (part of −123; ~2 days).
   `L: while (true) { const n = $in; …; continue L; }` is `for (;;) { …; }` when the loop has no
   nested loop and the parameter is not captured by a closure; `if (c) { return x; } else { … }` is
   `if (c) return x; …`.
4. **Arithmetic and `not` as operators** (part of −123; ~2 days). `k + 1` on `Int` is
   `Basics$add(k, 1)` in both builds, `n - 1` is `Basics$sub`, `not b` a call of a beni function —
   `backend.md` §9's peephole for `Basics.add` is specified and not built. It matters beyond the
   runtime: every program pays it. A `Js.truthy` intrinsic (or `Bool` from `Int` by `!== 0` folded
   into a test) would also turn `(flags & 2) !== 0` into `flags & 2` in a condition.
5. **Mutable locals** (part of −147; ~1 week, and an owner decision). A closure's `let` and a
   module's `let` become object properties (`cell.node`, `loop.scheduled`, `state.model`): bytes,
   and an allocation per template and per mount. Two shapes: a privileged `Js.Ref a` with `new`,
   `get`, `set`, lowered to a `let` when the ref provably does not escape the declaration that makes
   it (a local escape analysis, since beni has no other aliasing), or a `let mut` for platform code.
   The first needs no syntax and is fenced like the rest of `Js`.
6. **Inlining a top-level function called once** (part of −147; ~1 week). `put` → `putRun`, `flush`
   → `each`, `run` → `runFrom` → `start` → `refuse`/`refusal`, `mount` → `send` → `queue` →
   `microtask`: every helper the port needed because a loop is a function and a sequence is a `let`
   is a top-level declaration called from one site. `Opt` inlines single-use *locals* only; this is
   the same rule over declarations, after `Reach`, in the release pipeline.
7. **A function of no parameters** (0 bytes; ~2 days and a spec line). `flush : () -> ()` compiles to
   `($p) =>`, which check 4 then refuses against the lowering's zero-argument call; `splice.mjs`
   deletes the parameter by hand. A runtime exported to JavaScript needs `() -> a` to mean "no
   parameters" at least at the `foreign`/runtime boundary.
8. **Whole-program specialisation** (−203; 2–3 weeks). Interprocedural constant propagation over the
   one hoisted file: a parameter every call site passes the same constant (`template`'s `flags` is
   `0` on the empty page), a record field no reachable code reads (a slot's `u`, `x`, `y`, `z`, `d`
   are read only by list code), a property no reachable code writes (`h` of a mount, so the hosted
   branch; `phase`, so the after-render call). This is the prize, the only item that makes a beni
   runtime *smaller* than the hand-written one, and it is possible only once the runtime is beni
   code the compiler sees with the program — hand-written JavaScript is copied whole (`backend.md`
   §9, *Sibling-level elimination is out of scope*). It is also what research 41 §9 found Rollup
   doing to today's runtime (81 bytes of `template`'s constant flags) and what a minifier's
   `compress` does.

Smaller things found on the way, not measured separately:

- `Js.call`'s list-literal rule reports `internal`; it wants a code of its own (and a fixture).
- A record literal's keys are sorted (`{ b, cx, d, i, m, p, u, … }` where the hand-written slot is
  `{ p, m, cx, … }`): harmless while beni makes every slot, a hidden-class split if JavaScript ever
  makes some.
- An interpolation cannot hold a string literal, so `"${Js.to (Js.get m "n")}"` needs a `let`.
- `Rt.beni` is 493 lines for 125 of JavaScript (comments aside); most of the difference is layout (every `let`
  binding four lines) and helper declarations items 5 and 6 would remove.

---

## 7. How to re-run

```sh
zig build                                              # zig-out/bin/beni
node tests/platforms/beni-runtime-src/splice.mjs      # the port as development output (committed)
node tests/platforms/beni-runtime-src/splice.mjs --release-src   # as release output
beni build --platform=tests/platforms/beni-runtime --release --out=… Main.beni        # the empty page
beni build --platform=tests/platforms/beni-runtime-tea --release --out=bench/ui/out/beni-rt-rel bench/ui/apps/beni/Main.beni
# bench/ui/out/extra-subjects.json:
#   [{"name":"beni-rt","kind":"beni","dir":"beni-rt-rel"},{"name":"beni-rtr","kind":"beni","dir":"beni-rtr-rel"}]
nix develop .#browser -c node bench/ui/bench.mjs --subjects=beni-release,beni-rt,beni-rtr,solid1 \
  --benchmarks=01_run1k,02_replace1k,03_update10th1k_x16,04_select1k,05_swap1k,06_remove-one-1k \
  --n=5 --taskset=4-11 --out=out/rt-cpu.json          # about 2 minutes
node bench/ui/report.mjs out/rt-cpu.json --column=script,total --vs=solid1
cd tests/platforms/beni-runtime-src/estimates     # §5.1's runtime-part rows
node br2.mjs page.mjs base-part.js relr-part.js v1-part.js v2-part.js v3-part.js
```

`tests/platforms/beni-runtime/runtime.js` is generated; edit `Rt.beni` or `runtime.rest.js` and
re-run `splice.mjs`. Nothing in the gates builds against it.
