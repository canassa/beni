# SolidJS 2 as built: where the speed comes from

**Commissioned by** the project owner's direction of 2026-09-20, recorded in
[`plans/queue.md`](../../../plans/queue.md)'s last section — ***"I want built in JSX in the
language. Also, clone and research SolidJS 2. I want a Beni UI to be fast, as fast as solid, the
runtime cannot be a limitation."*** Solid 2 is to UI performance what Effect v4 is to effects: the
gold standard beni is measured against. This is report **B-R4**.

**What this is.** A reading of Solid 2.0.0-rc.9's source — the reactive core (`packages/signals`),
the DOM runtime (`packages/web`), the JSX compiler (`references/dom-expressions`) — with the
question *where does the speed actually come from, and which half of it is available to an
architecture that is not signals*. Plus measurements of real Solid 2 programs in headless Chrome on
this machine, chosen to explain Solid's own internals rather than to rank frameworks.

**What this is not.** It is not the cross-framework benchmark — that is
[`research/29`](29-rendering-strategies-measured.md), which builds hand-written prototypes of what
a beni compiler could emit and races them. It is not the JSX language design — that is
[`research/28`](28-jsx-in-beni.md). Where this report needs a fact those own, it says so and
defers. It takes no decisions: §11 hands the owner numbered questions with a recommendation each.

**Read §0, then §11.** §0 is the one-page answer and the table the synthesis needs. §11 is the
owner's question list. §1–§10 are the evidence.

---


---

## 0. Findings

### 0.1 Where Solid's speed comes from, ranked

**1. It gets out of the way.** On a real DOM, the browser is the cost. Building 1 000 table rows
takes 21.9 ms in headless Chrome, of which Solid's own work is **3.35 ms and Chrome's layout is
18 ms** (§10.4). Updating 100 row labels costs Solid **0.12 ms** against 4.7 ms of relayout — 97 %
layout. And against a hand-written `cloneNode` loop building the identical 1 000 rows, **Solid
costs 13 % more, not 9× more** (§10.6). Most of what "Solid is fast" means is that Solid's share of
a frame is 2–15 % and it does not inflate it.

**2. The compiler, and this half is available to any architecture whose compiler sees markup.**
Markup becomes one HTML string cloned per instance; holes are reached by a `firstChild`/
`nextSibling` walk computed at compile time; static attributes are written once; events are
delegated through a single property write plus one `delegateEvents` call for the whole program;
only the holes that need previous-value diffing get an effect (§10.2, §6). None of this depends on
signals. **A TEA renderer with a compiler that sees JSX gets all of it.**

**3. Shape engineering — the constants, not the asymptotics.** One monomorphic object literal per
node kind, all optional state behind a single `_x` pointer gated by a bit in a word already loaded,
because past ~39 in-object fields V8's allocation cost "roughly quadruples" (§1.1). Twenty-three
`CONFIG_*` bits, each with a paragraph naming the regression it prevents — one of them a measured
"diamond −22 %". A store-leaf diet driven by a profile reading "store node machinery ~36 % + GC
~29 %" (§5.1). This is where the graph's per-node ~120 ns comes from, and it is a discipline, not
an architecture.

**4. Batching, and it is free.** Every write stages into `_pendingValue` and one microtask flushes
the lot; three writes to one signal in one task produce **one** memo recompute (§3.1, §3.4,
measured). There is no `batch()` function because everything is batched.

**5. The graph — O(changed) — and it is the smallest of the five, honestly measured.** A signal
write with N subscribers is linear at ~120–140 ns each, propagation costs ~140–160 ns per node
against ~16 ns to *run* a memo body (§10.6), and glitch-freedom holds exactly but costs 17–20 %
(§10.6). More important: **`<For>` does not deliver O(changed) on a one-row edit.** Changing one
label in a 10 000-row list costs 10 000 comparisons and a fresh 10 000-element array in *every*
keying mode (§7.7). Solid's genuinely O(1) answer to that operation is the **store**, which needs
mutable records with stable identity.

### 0.2 The honest compiler/graph split

| available to **any** compiler that sees markup | tied to **signals** as the programming model |
|---|---|
| `template()` + `cloneNode(true)` instead of `createElement` chains | O(changed) propagation from a write to the holes that read it |
| compile-time `firstChild`/`nextSibling` hole paths | automatic dependency discovery for holes the compiler cannot analyse |
| static/dynamic classification; static attributes written once | per-node laziness and equality cut-off |
| event delegation (one property write, one global listener) | glitch-freedom over an arbitrary user-built graph |
| grouping several attribute updates into one update | the store's per-leaf O(1) write |
| keyed list reconciliation reusing DOM subtrees | — |

Everything in the left column is the compiler half. The measurements say the left column is where
most of the speed lives, and the right column is worth 2–15 % of a frame at realistic sizes.

### 0.3 Solid piece by piece, and what beni should do about each

| Solid piece | size | why it is fast | beni |
|---|---|---|---|
| `template()` + `cloneNode` | `web/src/client.ts`, part of 7.4 KB min | one parse, then a native subtree clone per instance | **copy** |
| compile-time hole paths (`firstChild`/`nextSibling`) | compiler, no runtime | no selectors, no ids, no per-node map | **copy** |
| static/dynamic split (syntactic: a call or member access is dynamic) | compiler | static attributes never get a computation | **do better**: beni knows *types* and *purity*, so the rule is semantic, not syntactic |
| `isStatic(props, key)` — a runtime descriptor probe for "is this prop constant" | `store/utils.ts:262-273` | avoids a reactive node for a static prop | **not needed**: the compiler knows, and never erased the answer (§8.1) |
| props as getters, `merge`, `omit`, view proxies | `store/utils.ts`, ~1 200 lines | keeps props lazy in an eager language | **not needed**: saturated calls, typed arguments (§8.1) |
| event delegation | `client.ts` + `delegateEvents` | one listener per event type per document | **copy** |
| `insert()`'s runtime type dispatch (text / node / array / function) | `client.ts` | one code path for every hole shape | **do better**: a `String` hole is known to be a string (§6) |
| the intrusive `Link` graph + `link()` dependency diffing | `core/graph.ts`, 191 lines | O(1) membership via a pass generation; zero allocation in the stable case | **not needed** if the compiler knows the dependencies (§1.2) |
| the height-bucketed heap | `core/heap.ts`, 182 lines | topological order without a sort; glitch-freedom | **do better if ever needed**: heights can be computed statically, once (§9.5) |
| batching + microtask flush + `_pendingValue` staging | `core/scheduler.ts`, 1 789 lines | one flush per task, writes collapse | **not needed**: a `sync update` is already one atomic step (§3.7) |
| two effect phases (render / user) | `constants.ts:188-191` | DOM writes and measurement are different jobs | **copy** — it is W5's "one after-render phase" |
| owner tree, children-before-parent disposal | `core/owner.ts`, 419 lines | O(1) splice, no failure path | **copy**, and note it independently confirms beni's decided finaliser order (§2.2) |
| context as a flat object, copy-on-provide | `core/context.ts`, 70 lines | O(1) read | **copy the shape if beni ever wants UI context** — no fiber slot needed (§2.3) |
| `compute`/`effect` split on `createEffect` | `signals.ts:430-518` | keeps tracked reads out of imperative code | **do better**: the `impure` bit draws the line in the checker, so the API is one function |
| the store: proxies, CoW drafts, `reconcile`, projections | 6 426 lines | fine-grained nested mutable state; O(1) leaf write | **not needed** — and Solid's own uibench result says so (§7.8) |
| `NotReadyError` thrown on every pending read | `core/error.ts`, 92 lines | propagation through ordinary call stacks | **cannot, and should not**: beni's defects are fatal; a pending value is data |
| lanes, holds, optimistic overrides, verdicts | 3 898 lines | prevents "a frame no timeline contains" | **not needed under TEA** — one timeline, one commit point (§4.9). The caveat is partial reveal |
| the dev/observe tiers | 5 246 lines, 0 shipped bytes | catches what the language cannot | **do better**: six of its checks are compile errors in a typed pure language (§8.3) |
| `Repeat` (count-based, no diffing) | `map.ts:574-682` | O(overlap + entering + leaving), no keys | **copy the idea** where a list is a range |

### 0.4 The ten findings, in order of value

1. **The browser is the cost, not the framework.** Solid's share of building 1 000 rows is 3.35 ms
   of 21.9 ms; of updating 100 labels, 0.12 ms of 4.85 ms. An architecture 2× slower than Solid *in
   its own layer* is 2–15 % slower end to end (§10.4).

2. **A top-down reference-equality walk is in the same complexity class as `<For>`, with a smaller
   constant and no allocation.** One label changing in 10 000 rows: `<For keyed>` does 10 000
   comparisons, 10 000 gated `setSignal`s and one 10 000-element array allocation (measured 268 µs);
   the walk does ~10 004 comparisons and allocates nothing (measured 9.3 µs) (§7.7, §5.5).

3. **Solid's team already ran beni's experiment and published the result.** On uibench, 96 cases,
   the immutable-snapshot shape (`createSignal(snapshot)` + `<For keyed={r => r.id}>`, no store)
   beat the store-plus-`reconcile` shape on **96/96**, 1.20× vs 2.59× against Octane. Their ruling:
   *"`reconcile` is … not for ingesting immutable snapshots (the snapshot is the diff)"* (§7.8).

4. **Report 25's "signals need a fiber-local observer slot" objection does not survive.** Solid's
   observer is two module-level `let`s restored in a synchronous `finally`. If beni requires
   tracked computations to be `sync` — which A6 already decides and W8 already recommends — no
   fiber can interleave between install and restore, so a plain module variable is correct. No
   fourth slot against A7's three (§8.6).

5. **Tracking does not survive an `await` in Solid 2, confirmed three ways, and Solid says it
   cannot be fixed** — *"a post-`await` continuation is a bare promise job the runtime cannot
   hook"* (axiom A26). In the production build the failure is silent: measured, a program reported
   pending 400 ms after settling, with `isPending` reading `false` (§4.4).

6. **Solid 2's new complexity is async.** 3 898 lines of async, lanes, holds, verdicts, optimism
   and boundaries against a 1 446-line async-free reactive core — and ~14 KB minified of scheduler
   and async machinery sits in the floor of an app that does nothing (§4.8, §10.3). Touching one
   `Loading` boundary adds ~15 KB minified.

7. **Writes are transactional in 2.0 and the writer cannot see its own write.** `set(7); m()`
   returns the *old* value until the flush. Confirmed in Node and in Chrome. It buys automatic
   batching — three writes, one recompute — and it costs a staging slot per node plus a read-side
   visibility rule with its own axiom (§3.1, §3.4, §10.5).

8. **The cost is the node, not the work.** Creating a memo or an effect is 114–165 ns; running it
   the first time is 13–17 ns; a signal is 20–32 ns; propagating through a live chain is 140–160 ns
   per node. **Propagation, not computation, is where a Solid graph spends its time** (§10.6).

9. **Solid is adding language syntax to reach where beni would start.** Solid 2 ships `.tsrx`, an
   optional dialect with `@if`, `@for`, `@switch`, `@try/@pending/@catch`, 728 lines of desugaring,
   because control flow as *components* in an eager language forces rows to arrive as accessors and
   forbids destructuring (§8.5). beni's `if` and `case` already are control flow, typed and
   exhaustive.

10. **The dev tier catches what the language cannot, and it is deleted from production.** 5 246 of
    24 312 lines. Writing `createEffect(() => n(), v => seen.push(v))` — idiomatic JavaScript — puts
    a number where a cleanup function belongs; the first run succeeds and the **second halts the
    whole reactive system**, with the message `r is not a function` in mangled production code
    (§9.4, measured). Six of those checks are types in beni.

**Two more that did not make the ten but should not be lost.** Solid deleted a *faster* parallel
list-update mechanism because its visibility decisions were made outside the graph
(§7.9) — a design whose update path is only the compiled walk has no such failure mode. And Solid's
store carries a signature optimisation (notify by *listened* paths, not incoming keys) whose own
bench file records that it *"is invisible in JFB and UIBench"* because in a real UI every rendered
field is listened (§5.3).

### 0.5 The three strategies, stated precisely for reports 28 and 29

These are the candidates the synthesis has to choose between. Each is stated so that report 29 can
build it and time it, and so that the owner can be asked about it in plain words.

**(A) Signals as the programming model — Solid's.** The developer writes cells and derived cells.
`view` is not a function of a model; it is a tree built once whose holes are subscriptions. What
beni adds: the tracking primitive takes a `sync` function so §8.6's hazard cannot happen; `impure`
stops the optimiser breaking tracking (A5); cancellation of stale async work is structural rather
than a discard (§4). What beni loses: single source of truth, exhaustive messages, time travel,
state serialisation — §9.1's four "lost" rows.

**(B) TEA plus compiled templates plus per-hole reference-equality checks.** One model, one pure
`sync update`, one `view`. JSX compiles to §6's template-and-holes form. On each frame the runtime
walks the holes top-down and, per hole, compares the model sub-value it reads against the previous
frame's by reference; `===` means skip, and because records are immutable it means *deeply* skip.
No subscription graph, no proxies, no virtual DOM. The cost is **O(holes)** per frame, at a
measured ~1 ns per hole (§5.5), against Solid's **O(changed)**.

Everything strategy B needs is either already true or already measured: the compiler sees the
markup (the owner's JSX decision), record update is emitted as a spread so untouched fields stay
reference-equal (§5.6), the walk is ~1 ns per hole, and the crossover with a signal graph is around
10⁵–10⁶ holes per frame.

**(C) TEA on the outside, a compiler-derived dependency graph on the inside.** The programmer sees
exactly strategy B — one model, one `sync update`, `view` as a pure function. But the **compiler**
analyses `view` to learn which model fields each hole reads, and emits a dependency structure so
that an update touches only the holes whose inputs changed: O(changed) *without the programmer ever
seeing a signal*. It is Solid's asymptotics with Elm's guarantees.

**Is (C) feasible?** What it would need:

1. **A field-level diff of old and new model.** Cheap and already available: compare each field by
   reference; immutability gives deep equality. The diff is O(model fields), not O(holes).
2. **Static analysis of `view` through function calls, `case` and lists.** This is the hard part. A
   hole inside `viewRow row` reads `row.label`, but *which* row is a value only the list
   comprehension knows. The analysis has to be *path-based* (`model.rows[i].label`) rather than
   field-based, and it has to survive being split across functions — which needs whole-program
   analysis beni has and Elm's compiler largely does not use.
3. **Purity** — so the analysis is sound and `view` can be re-entered or skipped. beni has it.
4. **A fallback that is still correct.** Where the analysis cannot prove what a hole reads, it must
   degrade to strategy B's reference check for that hole rather than to a wrong answer. That makes
   (C) strictly an *optimisation of* (B), which is the property that makes it safe to ship
   incrementally: build B, measure, then add C's analysis where it pays.

That last point is the most important thing this report has to say about (C): **(B) and (C) are not
rivals. (C) is (B) with a compile-time narrowing of which holes to visit.** If report 29 finds (B)
already reaches Solid's numbers at realistic sizes — and §5.5's arithmetic says it should — then
(C) is an optimisation nobody has to build yet, and the owner's requirement ("as fast as Solid, the
runtime cannot be a limitation") is met by the simpler design that keeps every guarantee.

**Prior art for (C), as pointers.** None of these was read for this report; reports 28 and 29
should dig. Listed in order of how directly they bear on (C):

| system | what it does that is (C)-shaped | the question to ask it |
|---|---|---|
| **Svelte 3/4** | compile-time invalidation bitmasks: the compiler assigns each reactive variable a bit, an assignment becomes `$$invalidate(n, …)`, and each fragment guards its update with `if ($$dirty & mask)`. This is (C), shipped, at scale, for six years | **and then Svelte 5 replaced it with signals (runes).** *Why* is the single most valuable question either sibling report can answer. If the reasons are Svelte-specific (component-granular invalidation, a 31-bit-per-component limit, cross-component derived state) they do not transfer; if they are fundamental to compiler-derived graphs they kill (C) |
| **Marko 6 / Tags API** | compiler-derived reactivity from the template, no user-visible subscription | how it handles a hole whose source it cannot prove |
| **Million.js** | "block virtual DOM": compiles JSX to a block with an edit map, and diffs only the dynamic parts | the closest published thing to (B), and its published numbers are a sanity check on 29's |
| **Elm `lazy`** | reference-equality memoisation of a whole view subtree — (B) at subtree rather than hole granularity | `plans/browser-decisions.md` W4 and effects decision C9 already park it; R24 §6.8 records the price (a reference-identity guarantee in `language.md` §6) |
| **Imba** | memoised DOM: the tree is cached and a re-render walks it setting only changed properties | its claim is that the walk is cheap enough — the same bet as (B) |
| **React Compiler (Forget)** | automatic memoisation inserted by a compiler | it memoises rather than building a graph; the interesting part is how it proves a value is unchanged |
| **Qwik** | resumability and lazy loading; signals underneath | relevant to output size and first paint, not to the update path |

---

## Method

### Sources, pinned

| repo | branch | commit | version |
|---|---|---|---|
| `references/solid` | `next` | `be46a04de7235607e83658627e82b0b3d30003d9` | `2.0.0-rc.9` |
| `references/dom-expressions` | `next` | `e97e4290ec544bdade3c368ceae156baf54fab57` | — |

Both are shallow ("grafted") submodules, committed as pointers. Every claim in §1–§9 cites
`references/<repo>/<path>:<line>` against those two commits. Line numbers are of the **source**
files, not the built output.

**One structural fact first, because it re-frames the whole report.** `@solidjs/web` 2.0 has
**absorbed** `dom-expressions`: `references/solid/packages/web/package.json` lists no
`dom-expressions` dependency, and `references/solid/packages/web/src/client.ts` (2 847 lines) is
the DOM runtime Solid 2 actually ships. `references/dom-expressions` is the 1.x lineage and the
place where the JSX **compiler** still lives; the changeset
`references/solid/.changeset/align-with-dom-expressions.md` is Solid 2 keeping the two in step. So
§6 reads the compiler from `dom-expressions` and the runtime it targets from `packages/web`, and
says which is which at every line.

### Machine, engine, load

One machine, one engine, headless. Every measurement batch records `uptime` beside it; see §10.
Node 24, `google-chrome` 153 `--headless=new`, the CDP harness reused from
[`research/26`](26-browser-host-measured.md)'s scratchpad. Nothing here is a cross-engine claim and
nothing here is a claim about a real user's machine.

### Sizes

`wc -l` over the vendored source, and min+brotli over bundles built in the scratchpad. Source lines
include comments, and in this codebase that matters: `references/solid/packages/signals/src/core/constants.ts`
is 236 lines of which roughly 150 are essays on why a given bit exists. They are the most valuable
documentation in the repository and this report quotes them heavily.

### "Could not determine"

Used literally. Where a claim could not be established from source or measurement it is marked and
the reason given, rather than filled with a plausible number.

---

## 1. The reactive graph in `packages/signals`

### 1.1 What a node is, and the shape discipline

Three node kinds, three object literals, each written out **twice** — a production literal and an
"observe" literal with two extra slots — so V8 sees **one hidden class per kind**. Nothing is added
to a node after construction on any hot path.

A signal in production is a 13-field literal (`core/core.ts:1244-1265`): `_equals`, `_config`,
`_value`, `_subs`, `_subsTail`, `_time`, `_firewall`, `_nextChild`, `_prevChild`, `_pendingValue`,
`_transition`, `_notifiedAt`, `_x`. No `_fn`, no `_statusFlags` — every shared path reads them as
missing properties that mask to `0` (`core.ts:1259-1261`). A computed extends both `RawSignal` and
`Owner` and adds `_deps`, `_depsTail`, `_depGen`, `_flags`, `_statusFlags`, **`_height`**,
`_nextHeap`, `_prevHeap`, `_fn` (`core/types.ts:199-233`). An owner is the lifecycle half —
`_parent`, `_firstChild`, `_nextSibling`, `_prevSibling`, `_disposal`, `_context`, `_queue`
(`core/types.ts:175-197`).

**The cold extension is the shape trick that matters most.** Everything optional — optimistic
overrides, async in-flight handles, error payloads, deferred disposal, `isPending` companions —
lives one hop away on `_x: NodeExtension | null`:

```ts
// references/solid/packages/signals/src/core/types.ts:56-66 (abridged)
/**
 * Cold node extension (stage-3 §12): optional machinery that most nodes
 * never touch lives one hop away so the CORE node literal stays under V8's
 * in-object property boundary (~39 fields measured: past it, every literal
 * allocation spills to an out-of-object backing store and creation cost
 * roughly quadruples — the create0to1 cliff). … ONE shape shared by signals
 * and computeds so `_x` access stays monomorphic.
 */
```

and the gate on consulting `_x` is a **presence bit on the always-present `_config`**, never a
missing-property probe, *"because reading a missing property defeats V8's inline caches on the
hottest write/notify loops"* (`core/constants.ts:39-46`).

There are **23 `CONFIG_*` bits and 13 `REACTIVE_*` flags** (`constants.ts:1-181`), each with a
paragraph naming the work it removes. Two carry a measured regression: an unconditional `_x` deref
inside `markNode` cost **"diamond −22 %"** (`constants.ts:58-63`), and walking a store computed's
child chain unconditionally made every update **O(all leaves ever read)** (`constants.ts:51-57`).

**For beni.** This is beni's own data-oriented argument applied to JavaScript objects: one shape
per kind, hot fields in the literal, cold fields behind one pointer gated by a bit in a word
already loaded. A beni backend emitting reactive nodes would fix the shape at compile time rather
than discover it with a profiler, but the rule is the same rule — and §10.6 measures what it buys:
a signal costs 20–32 ns to create, a memo 114–159 ns.

### 1.2 Edges: intrusive doubly-linked `Link` objects, from alien-signals

Not Solid 1.x's parallel arrays. One `Link` per (dependency, subscriber) pair, threaded into two
intrusive lists at once — the dependency's subscriber list and the subscriber's dependency list —
with a pass-generation stamp (`core/types.ts:8-26`). The lineage is cited in the file:
`core/graph.ts:15` points at alien-signals v2.0.3 for `unlinkSubs`, `:123` for `link`. Unlinking is
O(1) with no index bookkeeping (`graph.ts:16-47`).

**The cost of a tracked read** is `link()` (`graph.ts:124-191`), and it has three early exits before
it allocates: same dep as the last one touched, one pointer compare (`:134-138`); re-running and
the dep list still matches in order — reuse the link, stamp it, advance the tail (`:141-151`); or
the dep's subscriber tail is already this subscriber at the current generation (`:158-169`). **A
computation that reads the same signals in the same order allocates nothing and frees nothing on a
re-run.** The generation stamp is what makes membership O(1):

```ts
// references/solid/packages/signals/src/core/graph.ts:152-157
  // A link stamped with the current pass generation was created or reused
  // in-order during this recompute, i.e. it already sits in the validated
  // [deps.._depsTail] prefix — the O(1) equivalent of scanning the dep list
  // (the old alien-signals `isValidLink` walk, O(n²) when a computation
  // re-reads earlier deps non-consecutively, e.g. store leaf reads).
```

Everything past `_depsTail` after a pass is stale and unlinked in one walk (`graph.ts:49-59`), so
dependency diffing is O(deps) with zero allocation in the stable case. Measured cost of a tracked
read: **~20 ns, of which ~7 ns is this bookkeeping** (§10.6).

**For beni.** A compiler that knows a hole's dependencies statically does not need `link()` at all:
the edge set of `\model -> model.user.name` is a constant. This is the clearest single place where
a typed, pure, whole-program compiler deletes a runtime mechanism rather than reimplementing it.

### 1.3 The algorithm: two colours plus a height-bucketed array

**The colours** are two bits (`constants.ts:2-3`): `REACTIVE_CHECK` ("a transitive source may have
changed") and `REACTIVE_DIRTY` ("a direct source did"). `markNode` pushes DIRTY at the origin and
CHECK transitively, stopping the instant it reaches a node already at or above that colour
(`heap.ts:127-133`).

**The heap is not a heap.** It is an array indexed by height, each slot an intrusive circular list,
plus `_min`/`_max` cursors (`heap.ts:33-38`). Insertion is O(1) (`heap.ts:46-62`). The drain walks
heights in increasing order, re-reading the bucket head after each recompute so nodes appended at
the current height are picked up:

```ts
// references/solid/packages/signals/src/core/heap.ts:150-161
export function runHeap(heap: Heap, recompute: (el: Computed<unknown>) => void): void {
  heap._marked = false;
  for (heap._min = 0; heap._min <= heap._max; heap._min++) {
    let el = heap._heap[heap._min];
    while (el !== undefined) {
      if (el._flags & REACTIVE_IN_HEAP) recompute(el);
      else adjustHeight(el, heap);
      el = heap._heap[heap._min];
    }
  }
  heap._max = 0;
}
```

**That ordering is the glitch-freedom.** A node at height *h* runs only after every lower height has
drained, so it never sees a mixture of old and new inputs. There is no topological sort at write
time and no visited set: **the height integer, maintained incrementally, *is* the topological
order.** §10.6 confirms it empirically — every node of a stacked-diamond graph recomputes exactly
once per write — and prices it at **17–20 % over a chain of the same node count**.

Heights are maintained in three places: at insertion a node is pushed below its owner
(`heap.ts:47-51`); during a read a subscriber that reads a taller dependency raises itself
(`core.ts:1969-1973`, whose comment admits *"parent check is shallow, might need to be
recursive"*); and after a recompute changes a height its subscribers enter a separate height-adjust
pass with its own flag (`heap.ts:163-181`, `constants.ts:6`).

**Push and pull are split, and that is where the laziness lives.** A write walks **only the direct
subscribers** and enqueues them (`scheduler.ts:1148-1179`); transitive marking happens lazily,
either when the heap is first walked (`heap.ts:117-125`) or when a *reader* pulls a node whose
height sits at or above the pending `_min` (`core.ts:1955-1968`). A write nobody reads costs
exactly **O(direct subscribers)**.

The cut-off is `===` by default (`core.ts:1418-1420`), applied before anything is touched
(`core.ts:2333-2337`); `equals: false` opts out (`types.ts:32`).

### 1.4 Memo laziness and `untrack`

`REACTIVE_LAZY` marks a computed that has never run; the first read runs it (`core.ts:1507-1511`).
A memo with no subscribers is reclaimed, but **deferred to the next flush** rather than inline,
because doing it inline *"made reads destructive: each read disposed the node, the next read
revived it with a full recompute … so consecutive reads could return different answers with no
write in between"* (`graph.ts:81-100`).

`untrack` is a save/restore around a **synchronous** call, with a fast path that skips even that
(`core.ts:1455-1473`). Hold that shape: §8.6 turns on it.

One measured surprise contradicts the laziness story: **Solid 2's flush eagerly recomputes
unobserved memos** — `runs/write` is exactly N even for N memos nobody reads (§10.6). A memo is not
a lazy thunk once it has been read; it is a scheduled node.

### 1.5 The hot paths

**Read.** `readNodeFast` is the inlinable body: eight cheap tests that bail to a slow path, then
the link and the value load (`core.ts:1855-1893`); one arm was moved out *"so this body stays
inlinable"* (`:1866-1867`). The full `read` is 217 lines (`core.ts:1895-2111`).

**Write.** `setSignal` is 104 lines and its comment states the budget in bytes — *"the arms
themselves are cold helpers so setSignal stays within every setter's inlining budget, ~300 B
bytecode"* (`core.ts:2346-2347`). It does not commit; see §3.

**Notify.** `insertSubs` (`scheduler.ts:1126-1181`) has an epoch skip, so **a loop writing one
signal N times in a tick pays the subscriber walk once**:

```ts
// references/solid/packages/signals/src/core/core.ts:2369-2375
  // Staged-rewrite fast path (§12d): a re-write to a node whose subscribers
  // were already walked — and where nothing has recomputed or linked since
  // (epoch) — re-stages the value and stops. The walk is idempotent …
  if (wasStaged && el._notifiedAt === notifyEpoch && currentOptimisticLane === null && !reaskArmed)
    return v;
```

Two further optimisations are recorded with the bug they fixed. Mounting N rows whose effects
subscribe to a ref signal each row writes was **O(N²)** until `insertIntoHeap` learned to mark a
node on the spot when entering an already-marked heap (`heap.ts:73-84`, #3350). And store mounts
materialise one signal per touched leaf, so the `CONFIG_SLOT_NODE` path replaces four per-node
allocations with one literal and one shared hook, against a profile reading *"store node machinery
~36 % + GC ~29 %"* (`constants.ts:118-125`, `core.ts:1281-1291`).

### 1.6 Size

| area | files | source lines |
|---|---|---|
| reactive graph core (`core`, `graph`, `heap`, `scheduler`, `owner`, `effect`, `constants`, `types`, `context`, `error`, `index`) | 11 | **6 204** |
| async / optimism / transitions / boundaries | 6 | **3 806** |
| stores | 9 | **6 426** |
| dev + observe tiers | 8 | **5 246** |
| `map`, `affects`, the `signals.ts` wrapper | 3 | **2 139** |
| **`packages/signals/src` total** | | **24 312** |

(Measured 2026-09-20 10:33 CEST, load average 0.68 0.17 0.05.)

Two things stand out. **The dev and observe tiers are 22 % of the source** and ship in no
production bundle — `packages/signals/package.json:29-40` resolves `.` to `dist/prod/index.js` by
default, and the build mangles private properties afterwards (`:53`). **And the async half is
3 806 lines against the graph's 6 204**: the machinery for "a value that has not arrived yet" is
nearly two-thirds the size of the reactive engine. §4 is where that goes; §10.3 is what it weighs.

### 1.7 For beni, in one paragraph

The reactive graph is not where the mystery is. It is a well-engineered intrusive-linked-list
dependency graph with two-colour invalidation and a height-bucketed drain, and every clever part of
it makes two operations cheap: *record that this computation read this cell*, and *find the minimal
set of computations to re-run in dependency order*. **A compiler that knows the dependencies
statically needs neither.** What the graph buys that a compiler cannot trivially replicate is the
O(changed) update — the drain visits only what was written to, whatever the size of the rest of the
program. Whether that matters at beni's scale is §5.5's and §7.7's arithmetic, and §10's
measurements, and it is what report 29 is built to settle.

---

## 2. Ownership and disposal

### 2.1 The owner tree

An ordinary doubly-linked sibling tree (`core/types.ts:175-190`). A new owner is spliced at the
**head** of the parent's child chain, O(1) (`core/owner.ts:375-384`); an individual disposal
splices itself out in O(1) using `_prevSibling` (`owner.ts:134-157`). `createRoot` is `createOwner`
plus `runWithOwner` (`owner.ts:413-419`). `onCleanup` is three lines over one field that holds
`null`, a function, or an array — **no allocation for the common case of zero or one cleanup**
(`owner.ts:282-288`).

### 2.2 Disposal order: children first, then the parent's own finalisers

```ts
// references/solid/packages/signals/src/core/owner.ts:100-166 (abridged)
  let child = … node._firstChild;
  while (child) {
    const nextChild = child._nextSibling;
    n._config &= ~CONFIG_AUTO_DISPOSE;
    deleteFromHeap(n, queueFor(n));
    clearDeps(n);
    disposeChildren(child, true);     // ← the child and its whole subtree first
    child = nextChild;
  }
  …
  runDisposal(node, zombie);          // ← then this node's own onCleanup list
  if (self && node._cleanup) { … effectCleanup(); }   // ← then the effect cleanup
```

**This is exactly beni's decided order.** `plans/effects-decisions.md` A1 item (7): *"Children are
interrupted first, then the parent's own finalisers run — deliberately the reverse of Effect v4,
which never argued its order."* Solid arrived at the same order independently and has shipped it
for years. That is evidence for a decision beni has already taken, and worth recording as such.

Three details for beni's `Scope`:

1. **Disposal is depth-first, synchronous, and has no failure path.** `runDisposal`
   (`owner.ts:168-183`) calls each disposable and does not catch — the same position as beni's
   *finalisers are infallible* (`-> ()`, A1 item 1).
2. **A re-run is not a disposal.** When a computed re-runs, its children are parked as *zombies*
   on `_x._pendingFirstChild` and disposed only when the new value commits (`core.ts:271-281`),
   because *"a parked node's children predate the hold, and tearing them down when the source lands
   ran cleanups before the transaction's atomic reveal"* (`core.ts:266-270`, #3404). beni has no
   equivalent today because it has no transactions; if it grows optimistic rendering it meets this
   problem exactly.
3. **Disposal strips the dormancy bit** so a later read freezes at the last value instead of
   resurrecting the node (`owner.ts:60-69`, #3024). One bit distinguishes *death* from *dormancy*;
   the teardown body is identical.

### 2.3 Context is a flat object, not an owner walk

`getContext` is a single property read on the owner's own `_context` (`core/context.ts:34-48`),
because `setContext` **copies** the whole record when it provides (`context.ts:66-69`) and children
inherit the parent's record by reference at creation (`owner.ts:340`). A context read is **O(1)**
and a provide is O(record size) — the opposite trade to an owner-chain walk, and the right one for
a UI.

**For beni.** A7 gives beni exactly three fixed per-fiber slots and explicitly declines a general
service locator. Solid's `_context` *is* the general locator, made cheap. If beni ever wants
React-style context for UI, this shape — copy-on-provide, inherit-by-reference, O(1) read — is the
implementation to copy, and **it needs no fiber slot at all**: it needs an owner tree, which a UI
scope tree already is.

---

## 3. Scheduling: what is synchronous and what is batched

### 3.1 2.0 batches by default, and a write does not commit

The biggest behavioural change from 1.x, and it reaches into every other section. `setSignal`
writes to **`_pendingValue`, not `_value`**, records the node on the current batch, notifies
subscribers into the height heap, and asks for a flush (`core.ts:2342-2377`). The flush is a
**microtask**:

```ts
// references/solid/packages/signals/src/core/scheduler.ts:403-411
export function schedule() {
  if (halted) { notifyHalted(); return; }
  if (scheduled) return;
  scheduled = true;
  if (!syncDepth && !globalQueue._running && !projectionWriteActive) queueMicrotask(flush);
}
```

The rule is *"A write becomes visible at flush — to every channel (A28)"*
(`references/solid/.changeset/a28-writes-visible-at-flush.md`). **There is no `batch()` function in
Solid 2's public API** (`packages/signals/src/index.ts:1-120`) because everything is batched; what
exists instead is `flush()`, which drains now, and `flush(fn)`, which runs `fn` with microtask
scheduling suppressed and drains when it returns (`scheduler.ts:1471-1503`).

### 3.2 What the flush does, in order

`GlobalQueue.flush` (`scheduler.ts:744-…`) has a fast drain — no dirty computeds, no queued
effects, no transactions: commit staged values and return (`:751-783`) — and a full spine whose
mainline arm is:

```ts
// references/solid/packages/signals/src/core/scheduler.ts:795-891 (abridged)
      sweepDormant();
      runHeap(dirtyQueue, GlobalQueue._update);   // 1. pure recomputes, by height
      …  commitPendingNodes();                    // 2. staged → committed
      clock++;
      this.run(EFFECT_RENDER);                    // 3. render effects
      this.run(EFFECT_USER);                      // 4. user effects
```

Two effect phases, `EFFECT_RENDER = 1` and `EFFECT_USER = 2` (`constants.ts:188-191`), each with
its own array per queue.

### 3.3 The split effect

Solid 2 changed `createEffect` to take **two** functions, and the docs are blunt: *"`compute(prev)`
runs reactively — **put all reactive reads here**… `effect(next, prev?)` runs imperatively
(untracked) after the queue flushes. **Put DOM writes / fetch / logging / subscriptions here.**…
Reactive reads inside `effect` will *not* re-trigger this effect — that's intentional"*
(`signals.ts:430-440`). The single-phase 1.x form survives only for migration, `@deprecated`, with
its hazards spelled out: *"may run multiple times for a single change or show tearing"*
(`signals.ts:561-573`).

That is the same line beni's `impure` bit draws — in the type system, for free, with one function
instead of two.

**Render effects run synchronously at creation** (`core/effect.ts:75-83`): the compute runs, and
for a render effect so does the effect half. That is why mounting a Solid tree builds real DOM
synchronously — every JSX hole is a `createRenderEffect` and creation runs it. Only *updates* go
through the microtask flush.

### 3.4 Exactly when does the DOM change relative to a write?

| moment | what has happened |
|---|---|
| `setCount(1)` returns | `_pendingValue` is set, direct subscribers are in the heap, a microtask is queued. **`count()` still reads the old value**; the DOM is untouched |
| first microtask checkpoint | `flush()`: memos recompute by height, values commit, **render effects write the DOM**, then user effects |
| the next rendering opportunity | the mutated DOM is styled, laid out, painted |

**Confirmed empirically**, `@solidjs/signals@2.0.0-rc.9` under Node 24, production condition
(`solid-r1/sched/s3.mjs`, `uptime` 10:39:45, load 1.45 0.93 0.41):

```
  memo ran, n=0
  user effect, d=0
--- three writes in one task ---
after set(1): n()=0 d()=0
after set(2): n()=0 d()=0
after set(3): n()=0 d()=0
  memo ran, n=3
  user effect, d=6
[microtask 1] n()=3 d()=6
```

Three things pinned. **A write is invisible to its own writer** until the flush. **Three writes
collapse into one recompute** — the memo body ran once, with `n=3`. And **the flush beats
user-queued microtasks**, because `schedule()` queued its microtask at the first write. (§10.5
reproduces all three in Chrome.)

### 3.5 Is a microtask flush a starvation risk? No, and the distinction is precise

[`research/26`](26-browser-host-measured.md) §0.1 finding 1 is emphatic: a fiber yielding through
`queueMicrotask` every 64 ops had input delay p50 **371 ms** against **84 ms** for the same fiber
that never yielded, because *"a microtask checkpoint never reaches input, timers or rendering"*.

That finding does not condemn Solid's design, and the difference matters because beni will face the
same choice. R26 measured a **loop**: work, `queueMicrotask`, work, `queueMicrotask`, … Each
microtask enqueues the next, the checkpoint never empties, and the task never ends — the page is
starved because control never returns to the event loop, not because microtasks are slow.

Solid's flush is a **single, bounded** microtask: `schedule()` refuses to queue a second until the
first has run (`scheduler.ts:408-410`), the queued `flush` does all pending work and returns, and
the checkpoint then drains normally.

The honest caveat is that "bounded" means bounded by *the application's graph*, not by a time
slice. A flush that recomputes 50 000 memos is a long task, and there is **no yield point inside
`runHeap`** — `heap.ts:150-161` is a plain nested loop with no budget check. Solid's answer is
transitions (§4), which move work off the visible path, not a preemptive scheduler.

### 3.6 One render per frame

Solid does **not** do one render per frame. It renders once per microtask flush — at most once per
task, but possibly several times per frame. `plans/browser-decisions.md` W5 recommends the opposite
default for beni: *one render per frame; a separate, explicit "render now" for text inputs; plus
one after-render phase*.

The two are compatible, and the reason is §3.4's table: Solid's DOM writes are *mutations*, which
the browser coalesces within a frame anyway — writing the same text node twice costs two
assignments and one paint. Frame batching saves the duplicated *JavaScript*, which for Solid is
small because the graph already skips unaffected work. For a TEA renderer that rebuilds a view
top-down, the duplicated work is the whole view pass. **So W5's recommendation is worth more to
strategies B and C than it would be to strategy A — an argument for it, not against.**

### 3.7 For beni

1. **Batch by default, flush on a microtask, and have no `batch()` function.** Solid 2 removed the
   need for one by making staging the only write path. beni's `sync update` gives it the same
   property more strongly: an `update` cannot suspend, so the whole message-handling step is one
   atomic batch with **no runtime bookkeeping at all**. beni gets for free what cost Solid
   `_pendingValue`, `queuePendingNode`, `commitPendingNodes` and an axiom with a read-side rule.
2. **Two effect phases, and name them.** Render effects (write the DOM) and user effects (measure,
   focus, fetch) are different jobs; W5's "one after-render phase" is the same idea.
3. **The compute/effect split is a type-system question, not an API question.** Solid needs two
   function arguments and a deprecation to keep tracked reads out of imperative code; beni's
   `impure` bit draws it in the checker.

---

## 4. Async in 2.0

### 4.1 There is no `createAsync` — the async primitive was deleted

Solid 2.0 did not rename `createResource`; it removed the idea. *Any* computation may return a
`Promise` or an `AsyncIterable` and the graph handles it. The 1.x → 2.0 map is a comment block
(`references/solid/packages/solid/src/index.ts:255-261`): `createResource, // all computations`;
`createSelector, // createProjection`; `Suspense, // Loading`; `startTransition` and
`useTransition` simply gone. The stated reasons
(`references/solid/documentation/solid-2.0/05-async-data.md:11-13`): *"Async shouldn't require a
parallel set of primitives (resources vs signals)"*; *"Async values can be represented without
pervasive `T | undefined` 'loading holes'"*; composability. Rejected alternatives at `:328-329`
include *"Keeping explicit transition wrappers: rejected because transitions are a scheduling
concern that should be inferred and managed by the runtime."*

The normative spec is in-tree and versioned: `packages/signals/docs/SPEC-ASYNC-SEMANTICS.md`, 669
lines, axioms A1–A34, with *"IDs are stable and never renumbered (source comments cite them)"*
(`:21`) and a generated cross-reference enforced by a test. **That is beni's rule 1 and rule 2,
written independently by another project for a codebase of comparable difficulty** — worth one line
as external validation, and one as a warning: Solid needed that discipline *because* it chose this
design.

### 4.2 A pending computation THROWS a sentinel

`NotReadyError` is thrown on every read of a pending source, and the cost admission is in the
constructor: *"Control-flow throw: it happens on every read of a pending source, so in production
skip V8's eager stack capture (proportional to stack depth — real cost under SSR) by zeroing the
V8-specific stackTraceLimit"* (`core/error.ts:25-38`). Two throw sites: registration, when a compute
returned a thenable that did not settle synchronously (`core/async.ts:836-843`), and a read of an
already-pending node (`core/core.ts:1977`, `:2028-2033`). The escape hatch is `loadingValue` —
"commit #0" — which suppresses the throw entirely and makes the window verdict-quiet
(`signals.ts:288-311`, axiom A27). The throw is load-bearing and must never be swallowed: *"A derive
must never swallow `NotReadyError` (#3073) … that propagation is load-bearing"*
(`documentation/solid-2.0/04-stores.md:120`).

### 4.3 Pending propagates as status, and costs no recomputes

Three status bits (`constants.ts:183-186`) plus a lazily-created **set of pending sources** per node
in the cold extension (`async.ts:47-56`). `notifyStatus` (`async.ts:928-1069`) walks transitive
dependents once, deduping on that set, and **stops at a display consumer** — a render effect or
boundary computed (`:993-1004`). Cost: **O(transitive dependents), once, with no recompute.**

**Measured** (`@solidjs/signals@2.0.0-rc.9`, Node 24, `uptime` 10:31–10:35, load 0.08–0.33): a
ten-deep chain of sync memos over one async memo. During the pending window every memo's run-count
delta was `[0,0,0,0,0,0,0,0,0,0]` while `isPending(tail)` read `true`; all ten recomputed only after
the landing. **The committed frame keeps rendering while the flight is out.**

Boundaries do not walk the graph. A boundary is a **queue in the owner chain**: a render effect that
catches a pending read calls `this._queue.notify(...)` (`core/effect.ts:104`, `:131`), which each
boundary consumes on its own status dimension and forwards the rest (`boundaries.ts:391-392`), so a
`Loading` inside an `Errored` composes with no special case.

`isPending`/`latest` are a separate **verdict layer** (`core/verdict.ts`, 800 lines): `isPending(fn)`
is a probe mode that runs `fn`, collects the sources read, and reads each one's lazily-created
companion signal so the answer is itself reactive. Axiom A19 defines it as *"the value you can
currently observe for `x` is not the final one"*; A24 adds question-scoping so a poll or refresh does
not grey the list.

**Measured**, the typeahead frames, `[isPending, read, latest]`: after first load
`[false, "<data1>", "<data1>"]`; mid-refetch `[true, "<data1>", "<data1>"]` then
`[true, "SUSPEND:NotReadyError", "<data1>"]`; after refetch `[false, "<data2>", "<data2>"]`. That is
the typeahead contract exactly — old list readable through `latest()`, `isPending` true for the
greying, the raw read suspending to the boundary.

### 4.4 Tracking does not survive an `await`. Definitively.

Report 25's reading of 1.x holds unchanged in 2.0, and Solid says why in its own spec.
`core.ts:421` is `const fnResult = el._fn(value);` — an `async` compute returns its promise there, at
the first `await` — and the restore is an ordinary `finally` (`core.ts:488-500`). There is no
save/restore across the suspension, and **there cannot be**:

> a post-`await` continuation is a bare promise job the runtime cannot hook — JavaScript has no
> ambient async context (TC39 AsyncContext, unshipped), and holding `activeTransition` open across
> the await window was rejected as strictly worse: unrelated ambient writes interleaving during
> `await fetch()` (a user click, a timer) would be captured into the action's transaction …
> — `packages/signals/docs/SPEC-ASYNC-SEMANTICS.md:73` (axiom A26)

Grepping the whole `packages/` tree for `AsyncContext` / `AsyncLocalStorage` / `async_hooks` finds
only the server request-scoping module, never the reactive core.

Solid's answer is to **detect the mistake and shout, in dev only** (`async.ts:431-447`): *"Read of an
unresolved async source after an `await`. Reads inside async computations only register as
dependencies before the first `await`."* The changeset states the consequence when the check is
absent: *"no edge exists, the sweep can never find the node, and it wedged forever — boundary hung
on its fallback, `isPending` reading false, no error anywhere"*
(`.changeset/dev-error-untracked-async-read.md:7-17`).

**Measured, three ways.** (1) In the production build, inside `createMemo(async () => …)`,
`getObserver()` is present before the `await` and `null` after it; a signal first read after the
`await` never becomes a dependency (run count stayed at 1). (2) In the development build the
diagnostic above is thrown. (3) **In the production build the same program wedges** — it reported
`pending:NotReadyError` 400 ms after everything had settled, with `isPending` reading `false`. The
comment's prediction is literally what happens.

The same platform hole bites `action()` at the transaction level, and the workaround is a syntax
rule: *"`yield` is the transaction-safe suspension point … a plain `await` does NOT … just put a
bare `yield` before any write or reader creation that follows it"* (`core/action.ts:64-77`), pinned
by a test named `"documented escape: a write between \`await\` and the next \`yield\` commits
ambiently"`.

**This is §8.6's evidence.** Solid cannot fix it because it does not own the continuation. beni does
— its CPS lowering means the continuation is a closure the runtime holds — so beni could do what
Leptos does. §8.6 argues it does not need to, because `sync` closes the hole instead.

### 4.5 Stale work is DISCARDED, not aborted

There is no `AbortController` in the async path. The generation counter is the **promise object's
identity**, stored in `_inFlight` (`async.ts:367`), and every callback opens with
`if (el._x?._inFlight !== result) return;` (`:428`, `:472`, `:706`, `:727`), plus a second gate on
dirtiness (`:474-476`). A recompute clears `_inFlight` first (`core.ts:249-256`), which makes the
old promise's later resolution a no-op. **AsyncIterables are genuinely cancelled**, because they
have a protocol — `it.return?.()` (`async.ts:656-669`), fired at the `_inFlight` release sites so a
superseded stream stops immediately (`:310-316`).

**Measured**: two flights, the stale one deliberately slower. `started: ["a","b"]`,
`settled: ["b","a"]` — **both promises ran to completion; nothing was aborted** — and
`committed: ["R(b)"]`. Every stale request still runs, still costs a round trip, still burns the
user's battery. Solid's *recommended* abort story is manual and lives outside the async model:
`createEffect(…, id => { const ctrl = new AbortController(); fetch(…, {signal: ctrl.signal});
return () => ctrl.abort(); })` (`signals.ts:486-488`) — i.e. outside the thing that was supposed to
subsume resources.

### 4.6 Transitions, lanes, holds — and what they are for

Transitions in 2.0 are ambient and inferred. Axiom A15: *"Transition entanglement is graph-driven:
writes whose async work is observed by a shared reader settle as one unit (no tearing …); writes on
fully disjoint graphs keep independent transitions"*. A **lane** is a per-optimistic-write
scheduling scope, implemented as a **union-find over the dependency graph**
(`core/lanes.ts:19-35`, `:94-97`, `:167-184`); lanes merge when their graphs overlap.

What the held/staged machinery buys is stated once, perfectly, in a constant's doc:

```ts
// references/solid/packages/signals/src/core/constants.ts:102-112 (abridged)
/** HELD truth (#3164): this node's staged `_pendingValue` is confirming
 * truth riding a transaction that retains optimism, revealed only at that
 * transaction's settle. … Until the reveal, ordinary readers … keep
 * committed: … without the mask a mid-hold recompute composes live optimism
 * with the confirming truth, a frame no timeline contains … */
```

**"A frame no timeline contains"** is what the entire lanes-plus-holds apparatus exists to prevent:
a render composed from two different moments. It follows that in a system with *one* timeline and
*one* commit point, the apparatus has nothing to do — §4.9.

### 4.7 Errors behave exactly like pending, one dimension over

An error is a **value on the node**: `_statusFlags |= STATUS_ERROR` and `_x._error = error`
(`async.ts:975-980`), propagated by the same walk with the same object identity (`:1067`), routed to
the nearest boundary on the `STATUS_ERROR` dimension (`boundaries.ts:571`). A tracked re-read on a
later clock tick retries by recomputing (`core.ts:2043-2051`). With no boundary anywhere, the system
halts permanently — §9.2. Axiom A6: `NotReadyError` is **not** a `StatusError`, so `<Errored>` must
never catch a pending.

### 4.8 Size: Solid 2.0's new complexity *is* async

`core/async.ts` 1 070, `core/verdict.ts` 800, `boundaries.ts` 743, `core/optimistic.ts` 717,
`core/lanes.ts` 252, `core/action.ts` 224, `core/error.ts` 92 — **3 898 lines** — against a
genuinely async-free reactive core (`graph`, `heap`, `owner`, `context`, `types`, `constants`,
`external`) of **1 446**. The async modules are 16 % of `packages/signals/src`, **28 %** of the
non-store non-observability core, and ~37 % once `scheduler.ts`'s and `core.ts`'s async-touching
lines are counted (566 of 1 789 and 589 of 2 532 mention
transition/pending/lane/async/optimistic/staged/override). **69 of the 168 test files** carry an
async word in their filename, and there are ~2 800 lines of spec and internals prose for this one
concern.

### 4.9 For beni

**What "a computation that suspends" would mean.** In beni an effectful call is just a call and the
runtime holds the continuation, so the current observer would be a fiber-record field rather than a
module global, restored at every resumption — Leptos's answer, available to beni for free from a
decision already taken. §8.6 argues beni should *not* take it, because requiring tracked
computations to be `sync` closes the hole with no new mechanism, and because Solid's own rejection
of the transaction-across-`await` analogue (A26) warns that holding an ambient scope across a gap
captures things you did not mean to capture.

**beni is already stronger than the gold standard here.** Solid has `sync: true` as a *memo option*
whose violation is undefined behaviour in production and a dev diagnostic otherwise
(`signals.ts:278-287`, `async.ts:345-360`). beni's `sync` is a checked property of the whole call
tree: a beni `view` or `update` declared `sync` cannot suspend, statically, with nothing written in
the tree below it.

**(a) Pending states in the UI.** Solid's typeahead answer decomposes into four independent channels
— the committed value, the verdict (`isPending`), the stale read (`latest`), and the boundary — and
all four are load-bearing *because state lives in a mutable graph several timelines write into*. In
a TEA-shaped beni with one `Model` and one `update`, "old list greyed" is
`{ results : List Item, refreshing : Bool }`: a field. And Solid concedes the point for the two
hardest cases — `loadingValue`'s doc tells you to use *"a `null` placeholder, a `skeleton: true`
field"* (`signals.ts:293-300`), and the actions document says process affordances are *"co-written
state … not verdicts"* (`documentation/solid-2.0/06-actions-optimistic.md:124`). **Solid built an
800-line verdict layer and then told users to put the two hardest states in the data anyway.**

**(b) Is beni's fiber cancellation better?** Yes, and Solid's source is the evidence: Solid cannot
abort a promise, stale flights run to completion (measured), and the only genuine cancellation in
the file is for `AsyncIterable` because `it.return()` exists. beni's cancellation runs finalisers at
cancel time, LIFO, and signals descendants before the parent unwinds. One honest caveat: Solid's
discard is *cheap and total* — one comparison, correct for every flight shape — while beni's
cancellation is a fiber record, a finaliser list and an interrupt protocol. beni is buying a
capability Solid cannot offer at all, which is rule 7's "fill the gap inside the wall", not a free
win.

**(c) Does TEA already have a cleaner answer than lanes + holds + overrides?** Yes, with one real
caveat. A TEA beni deletes the question the apparatus answers: there is one `Model`, it changes only
in `update`, and `view` is a pure function of it — so no `_pendingValue`, no `_overrideValue`, no
`CONFIG_HELD_TRUTH`, no stale-reader carve-out, because there is only one timeline and one commit
point. Optimistic UI is `{ todos = optimistic :: model.todos }` plus a command whose failure message
removes it, atomic by construction.

**The caveat is partial reveal.** A TEA `update` that folds one of five responses into the model
repaints everything derived from it; there is no "hold these four until the fifth lands". Solid's A15
entanglement *is* that feature. If beni wants streaming or partial hydration it will need some form
of it — and Solid's own notes record the mirror complaint, that 2.0 holds *too much* and there is no
way to say *"this subtree is an independent visual unit; let it fall behind"*
(`documentation/proposals/create-deferred.md:16-31`). **Whatever beni takes from Solid's speed, it
must not take Solid's visibility model without taking the 3 898 lines with it.**

---

## 5. Stores and projections, and the asymptotics question

Two stores ship in-tree. `store/store.ts` is now only types and brands; `store/utils.ts` is the
`merge`/`omit` prop views of §8.1. The **live** store is `store/next/`, which `store/index.ts:44-52`
routes `createStore`, `reconcile`, `snapshot`, `deep`, `createProjection` and `createOptimisticStore`
into unconditionally. Everything below is `next/`.

### 5.1 The proxy

One `ProxyHandler`, module-global, shared by every store node in the process
(`references/solid/packages/signals/src/store/next/store.ts:1965-2313`), with seven traps: `get`
(`:1966`), `has` (`:2143`), `ownKeys` (`:2172`), `getOwnPropertyDescriptor` (`:2179`), `set`
(`:2208`), `defineProperty` (`:2278`), `deleteProperty` (`:2299`). It does **not** wrap the user's
object; it wraps an internal *target* record which keeps the raw in a field
(`next/target.ts:59-61`). The target is built by a pre-shaped constructor, for the same V8 reason as
§1.1: *"V8 tips a bare `{}` into dictionary mode once ~19 named properties are assigned onto it …
every trap's field read became a hash lookup, a 15 % deep-dbmon tick regression"*, with the field
count capped at 20 and *"any future write-side state … must ride an extension object … never new
named fields here"* (`next/store.ts:110-130`, repeated as a **LOAD-BEARING SHAPE RULE** at
`next/target.ts:75-87`). The whole file is at war with V8's object model and its comments are the
battle log.

**A signal is materialised per touched leaf, lazily, on the first *tracked* read**; untracked reads
create nothing. The budget is normative in the repo's own internals document
(`references/solid/docs/INTERNALS-STORE-STATE.md:208-226`): *"Per adopted-but-unread object: zero
allocations… Creation is O(rendered), not O(data)"*; *"Per read-through object: one minimal target,
one proxy, one `storeLookup` entry"*; *"Per tracked binding: one bare core signal + one graph link.
This is the fine-grained floor, accepted; the shallow column (2.5 ms vs deep 10.3 ms, same engine)
shows ~75 % of today's deep cost is mechanism above that floor."*

The allocation diet is §1.5's `CONFIG_SLOT_NODE` story, and this is where its numbers come from:
store mounts materialise **~13 signals per row on dbmon**, so a 1 000-row table is 13 000 leaf
signals, and before the diet each cost five extra allocations — *"an options object, an equals
closure, an unobserved closure, a NodeExtension to hold it, and three post-construction expandos"*
(`core/core.ts:1282-1291`), against a profile reading *"store node machinery ~36 % + GC ~29 %"*
(`core/constants.ts:118-125`). The shared equals is one function for the process
(`next/store.ts:248-250`) and the shared unobserved hook is registered once (`:255-273`) — and that
hook is also the store's **GC**: a leaf losing its last subscriber is deleted from the target's node
map, so teardown is proportional to tracked surface, not data size.

**Writes** are refused outside a draft scope (`:2208-2212`). Inside one the trap mutates a
copy-on-write buffer, records the key in `target.wk`, and **touches no node** (`:2220-2243`);
notification happens at the outermost setter's exit and visits only the written keys (`notifyWrites`,
`:1191`, `:1256-1289`); the backing commit is deferred to the flush's `drainFolds` (`:979`). The
header states the invariant: *"Nodes carry no pending state — they are pure subscription points…
Laziness: a written target with no subscriptions folds as a pointer swap with zero node work"*
(`:14-17`). Copy-on-write has two shapes: a spread clone when the container grades as plain data
(*"at ~1/50th the cost"* of the descriptor walk, `:581-610`), and a **prototype overlay**
`Object.create(v)` for a plain owned container with more than 32 keys (`:652-657`, `:774-776`),
making a draft O(written) instead of O(container).

### 5.2 `reconcile`

`reconcile(value, key = "id")` does not merge-write; it **adopts**: *"Reconcile never merge-writes:
it adopts `next` as the authoritative pending backing at every proxied level (pointer swap folded at
flush commit), notification riding the fold's descriptor diff"* (`next/reconcile.ts:2-5`). The data
*is* the new object graph; only the **notifications** are diffed. Three structural optimisations
(`:7-19`): an **identity skip** — *"sound because input is immutable by convention (R2a)"*;
**reachability pruning** — *"descent happens only where a child TARGET exists (proxies exist only
where read) — never-subscribed subtrees are never walked"*; and **keyed matching** where key-matched
rows keep proxy identity and keyless items fall back positional.

Note the first bullet: **Solid's own reconciler is sound because the incoming data is immutable**,
and it says so. That is the property beni has by construction rather than by convention.

Keyed arrays take a positional-prefix fast path before any map is built — *"the `prevByKey` map is
built only for the misaligned remainder, and never at all on aligned ticks"* (`:161-166`) — and
objects take a **fused walk**, one `for…in` that descends then notifies inline, which *"replaces the
notifyFold re-walk that doubled dbmon's diff cost"* (`:307-312`). There is **no `merge` option** in
2.0. Complexity per proxied level: aligned keyed array **O(min(P,N)) + O(reachable) + O(subscribed)**
with no map allocated; misaligned **O(P+N)** with one map; object **O(N)**; an unreachable subtree
**O(1)**.

### 5.3 The optimisation that cannot be benchmarked

Solid 2's signature store optimisation is that `setStore(reconcile(…))` scales with *listened* paths
rather than the size of the incoming tree. Its own bench file says what that is worth:

```ts
// references/solid/packages/signals/tests/store/listened-paths.bench.ts:4-14 (abridged)
// … the Solid 2.0 `applyState` walks `Object.keys(nodes)` (keys with
// subscribers) instead of `Object.keys(next)` (every key in the new value) …
//
// This is the unique-to-Solid-2.0 store optimization. It is invisible
// in JFB and UIBench because both subscribe to every field per row,
// so every key is "listened" and the optimization can't show up.
```

Read that twice. It matters for report 29's framing: **the cleverest thing in Solid 2's store does
nothing on either standard benchmark**, because in a real rendered UI every rendered field *is*
listened.

### 5.4 `createProjection` and mutable-draft setters

A projection is **a computed whose body writes a store** (`next/projection.ts:2-8`, `:214-220`). A
memo returns one value, so every consumer re-runs when any part changes; a projection returns a
store, so consumers subscribe per leaf. The changesets prescribe it as the repair for wide fan-out,
with the diagnostic firing at *"at least 250 live subscribers"*. It is not cheap: per projection, a
family object with its own `WeakMap` — so an object read through both a source store and a
projection gets **two** targets and two proxies — one computed node, and every family node carrying
the computed as a **firewall** on a doubly-linked chain so release is O(1) (`core/core.ts:1302-1334`,
#3351). And **per recompute**: the derive runs inside a *second* proxy layer (`wrapDraft`,
`next/projection.ts:64-178`, six traps, re-wrapping every object result) over a deliberately fake
target, and commit is the full `reconcile` machinery (`:282`).

The **draft is the store proxy itself** — no copy of the object graph is made up front.
`storeSetterNext` (`next/store.ts:2326-2360`) sets a `writeScopes` set, runs the callback, and on the
outermost exit emits one `setSignal` per changed observed key. "Draft" is a *scope*, one `Set` per
setter call, and `inDraft(target)` is one `Set.has` (`:1564-1566`); writes outside a scope are
silently dropped. Commit is three-staged — trap → setter exit (notify) → flush (pointer swap plus a
CAS-guarded path copy into the parent slot, `:1088-1101`) — and the deferral is not an optimisation
but what lets a transition hold a write (`:1011-1029`).

### 5.5 The asymptotics, exactly: 10 000 rows, one label changes

**Solid, mutation path** — `setStore(s => { s.rows[4200].label = "x" })`: one `Set` allocation
(`:2329-2332`); two `get` traps, O(1) each with wrap-cache hits and zero allocations; one `set` trap
doing `ensurePB` → `{ ...row }`, **one small allocation**, `wk = {"label"}` (`:2235`); setter exit
loops over **1** key → **one `setSignal`** (`:1288`); flush does a pointer swap plus an O(1) path
copy. **K = 1** — one notification, three trap invocations, one allocation, and the 9 999 untouched
rows are never read, compared or walked. (One caveat: the *first* such write privatises the
10 000-element array — `privatizeCommitted`, `:920-936` — an O(N) descriptor clone, once.)

**Solid, reconcile path** — a fresh 10 000-row payload arrives: `O(P+N)` at the array level *plus*
`O(subscribed keys)` per descended row. A top-down walk, exactly strategy B's shape, with proxies on
top.

**Strategy B — a per-hole reference-equality check, measured.** Node 24 on this machine, two model
arrays of `{id, label, checked}` rows, the middle row replaced by `{...row, label:"CHANGED"}`, 2 000
repetitions, warmed (`uptime` 10:32:36, load 0.09 0.04 0.01):

| N holes | walk | per hole |
|---|---|---|
| 1 000 rows × 1 hole | 0.9 µs/frame | 0.93 ns |
| 10 000 rows × 1 hole | **9.3 µs/frame** | 0.93 ns |
| 100 000 rows × 1 hole | 98.8 µs/frame | 0.99 ns |
| 10 000 rows × 3 holes | 44.2 µs/frame | 1.47 ns |
| 100 000 rows × 3 holes | 458 µs/frame | 1.53 ns |

The ~1 ns premise holds and is flat in N. For scale, a bare `Proxy` `get` that does nothing but
`Reflect.get` costs **28.5 ns** against **1.03 ns** for a plain property read on the same machine
(`uptime` 10:32:58, load 0.22) — and Solid's trap does strictly more, so 28.5 ns is a floor.

**So: what does the graph buy beyond a per-hole reference check?** It buys **skipping the walk —
O(changed) instead of O(holes)**. For one label in 10 000 rows: Solid touches K = 1 node; strategy B
performs N = 10 000 comparisons, costing 9.3 µs, which is **0.06 % of a 16 ms frame**. At 100 000
rows with three holes each — 300 000 holes — it is 458 µs, **2.9 % of a frame**. The crossover at a
1 ms diff budget is about **1.07 million holes**; at a strict 0.1 ms budget, about **107 000**. That
is one to two orders of magnitude past any DOM that can be laid out in 16 ms.

The sharp form: **Solid's store pays 30–50× per *touched* leaf to avoid paying 1× per *untouched*
hole**, and that trade only pays above roughly 10⁵ holes per frame. Three qualifications, all cutting
Solid's way and none changing the conclusion: the walk is only cheap because reference equality on an
*immutable* record implies deeply unchanged — precisely why Solid needs a graph and beni would not;
Solid's O(1) is the mutation path only, since on a fresh payload both do a top-down walk; and the
graph buys **direct addressing** (the notification names the DOM node) — though that is a wash,
because strategy B's walk finds the hole and patches it in the same pass.

### 5.6 For beni: there is no equivalent of `reconcile`, and that is the point

`reconcile` exists to solve a problem beni does not have: *how to get new immutable data into an old
mutable identity graph without destroying the identities the subscriptions are attached to.* Every
line of `next/reconcile.ts` is identity preservation. In beni the model **is** the new data; the
programmer's `{ model | rows = … }` **is** the correspondence.

**And the structural-sharing premise strategy B rests on holds, verified against beni's own
emitter.** `Lower.zig` emits record update as a spread with the base first, because *"Spreading the
original FIRST and overriding after keeps the key order of the record being updated, which is what
keeps one hidden class per record type"* (`src/js/JsIr.zig:199-204`), and a real build of
`tests/corpus/run/Records.beni` produces
`const Records$shift = (dx$1, p$2) => ({ ...p$2, x: Basics$add(p$2.x, dx$1) });`. So `{ m | a = x }`
allocates one object and **copies every other field by reference** — `newM.b === m.b` for every
untouched `b`, and because records are immutable that implies `b` is *deeply* unchanged.
**Structural sharing is free at one level, which is exactly what strategy B needs per hole.**

Two caveats report 29 must carry. **Nesting:** `{ m | user = { m.user | name = n } }` allocates two
objects, so a per-hole check at the granularity of *the record the hole reads from* is correct and
cheap, while a check against the root model is useless because the root always changes.
**Lists are cons cells** (`backend.md` §4, with `:275-277` recording that M3c benchmarks a 32-way
persistent vector trie against them): updating row *i* rebuilds the spine for cells `0..i`, so those
*i* cells are fresh objects and **a walk must compare the element, never the spine cell**. At element
granularity one changed row is one miss; at spine granularity it is up to N. The 9.3 µs figure above
is measured at element granularity, and the pointer chase a cons walk adds is one more argument for
the vector trie already on the books.

**One measured hazard for beni's record update.** Because `{ r | f = x }` is a spread, its cost is
V8's object-clone path, and that path has a cliff. Median of 9 runs × 20 000 iterations, base built
as beni emits it — one object literal — Node 24 (`uptime` 10:33:42, load 0.67):

| record width | 4 | 8 | 16 | 17 | **18** | 20 | 24 | 32 | 64 |
|---|---|---|---|---|---|---|---|---|---|
| `{...r, f0:k}` ns | 18.2 | 19.4 | 33.4 | 29.9 | **222.6** | 246.1 | 306.3 | 425.3 | 986.3 |

`%HasFastProperties` is `true` on both sides, so this is **not** dictionary mode — it is V8's fast
object-clone inline cache bailing out above ~17 properties. (Measured, not read out of V8's source.)
A record built by repeated assignment rather than a literal is far worse past the cliff — 2.8 µs at
20 fields — so beni's "one literal, canonical key order, one hidden class per record type" rule is
doing real work and must be preserved. The consequence for a TEA model: **a wide flat `Model` of 30+
fields pays ~400 ns per `update` return instead of ~30 ns.** That is 0.0025 % of a frame and not a
crisis, but it is a reason to prefer nested sub-records over one wide model — question S6.

---

## 6. The compiler — what JSX becomes, and what beni could delete

### 6.1 Provenance

**`@solidjs/compiler` 2.0.0-rc.9 is a Rust/Oxc compiler**, N-API packaged — *"Solid 2.0's native
Oxc JSX compiler… The JavaScript fallback is `@solidjs/babel-plugin`"*
(`references/solid/packages/compiler/README.md:3`), pinning `oxc_parser`/`oxc_ast`/`oxc_codegen`
0.144 and `html5ever` 0.39 (`packages/compiler/Cargo.toml:26-37`), **12 142 lines across 72 files**.
Every output block below is verbatim from it; the 1.x contrasts are verbatim from
`babel-preset-solid@1.9.15`.

The two vendored repos are the same code at two points:
`references/solid/documentation/expression-origin.md:1-20` records the dom-expressions snapshot at
exactly the commit vendored here, *"drop the rxcore seam, flatten runtimes into package `src/`"*
(`packages/compiler/CHANGELOG.md:146`). So `references/solid/packages/web/src/client.ts` (2 847
lines) is the shipped runtime and `references/dom-expressions/packages/runtime/src/client.js`
(2 010) is the same code one step back.

### 6.2 What JSX compiles to

**A static tree.** `<div class="a"><span>hi</span></div>` becomes
`var _tmpl$ = /* @__PURE__ */ _$template(`​`<div class=a><span>hi`​`);` and `_tmpl$()`. The attribute
is unquoted and both closing tags omitted — the parser reconstructs them
(`packages/compiler/src/shared/utils.rs:302`, gated at `:313`). No reactivity, one clone.

**Dynamic holes.** Seven bindings across six elements of one template:

```js
var _tmpl$ = _$template(`<div><p></p><input><div></div><div style=font-size:12px></div><a title=static>link`);
	var _el$2 = _el$.firstChild;   var _el$3 = _el$2.nextSibling;  /* … */
	_$insert(_el$2, () => { return props.text; });
	_$claimElement(_el$8);
	_$effect(() => {
		return { e: props.value, t: props.id, a: _$readShallow(props.cls),
			i: props.color, s: "/x/" + props.id };
	}, ({ e, t, a, i, s }, _p$) => {
		_el$3.value = e ?? "";
		t !== _p$?.t && _$setAttribute(_el$3, "id", t);
		_$className(_el$4, a, _p$?.a);
		i !== _p$?.i && _$setStyleProperty(_el$6, "color", i);
		s !== _p$?.s && _$setAttribute(_el$8, "href", s);
	});
```

Four things to read off it. **`style={{color: props.color, "font-size":"12px"}}` is split at compile
time** — the static half is baked into the template string, the dynamic half becomes a *per-property*
write, not an object diff (`src/shared/attr_plan.rs`, `src/dom/set_attr.rs:53-75`). **Every dynamic
binding on the whole template root shares ONE effect**, with a compute half returning a keyed object
and a commit half destructuring it. **Each commit carries its own dirty guard `x !== _p$?.x`** — the
compiler emits it, not the runtime. And `class={{active: props.a, big: true}}` puts the static key
in the template and compiles the dynamic one to a single `classList.toggle`, where Solid 1.9.15
shipped the whole object to the runtime every update.

**Events.** The pessimistic path is `_$addEvent(el, "click", props.onClick, true)`, but when the
handler is a **resolvable function** the compiler skips the helper entirely — `_el$._$$click =
onClick`, one property write, zero runtime imports. The predicate is `is_resolvable_handler`
(`src/dom/events.rs:194-204`): an arrow, a function expression, or an identifier the binding table
says is a function. `props.onClick` is a member expression, so it is not resolvable and pays
`addEvent`'s runtime `Array.isArray` unwrap (`web/src/client.ts:751-786`). The delegated set is
**22 hard-coded event names** (`src/shared/constants.rs:11-37`).

**What delegation saves, measured.** A real 1 000-row list app bundled with the native compiler, run
in jsdom with the DOM APIs instrumented (`uptime` 10:34, load 0.44):

| initial render, 1 000 rows | count |
|---|---|
| `addEventListener` | **1** |
| `cloneNode` | 1 001 |
| `createElement` | **2** (the two `<template>` elements) |
| `createTextNode` / `setAttribute` | **0** / **0** |
| `insertBefore` | 1 000 |

**One listener for a thousand handlers.** `setAttribute: 0` because static classes live in the
template string; `createTextNode: 0` because `insertExpression`'s string branch writes
`parent.textContent` when it owns all children (`client.ts:2611`).

**Components.** Four decisions from one predicate (`src/shared/component.rs:251-267`): a literal
becomes a data property, a **member access becomes a getter**, an arrow becomes a data property (a
function is never dynamic), and `children` is always a getter so the subtree is not built unless the
callee reads it — `_$createComponent(Child, _$mergeProps({ a: 1, get b() { return props.b; },
c: () => props.c }, () => props.rest, { get children() { … } }))`.

**`<For>`** hoists the row template and passes the list as a getter. **`<Show>`** puts *both*
branches behind getters. **Spread** is where the compiler gives up: one `insert` plus one effect
enumerating every key of every source on every run (`client.ts:929-999`), with `assignProp` doing a
string-prefix dispatch per key per update (`:2410-2461`). **Spread is the most expensive thing in
compiled Solid output, and it exists only because the key set is unknown at compile time.**

### 6.3 `template()` + `cloneNode` — and the evidence is thinner than expected

Nine lines (`web/src/client.ts:395-403`): build the prototype node **lazily on first instantiation**
via `createElement("template"); t.innerHTML = html; return t.content.firstChild`, memoise it in the
closure, `cloneNode(true)` every later instance. Templates **dedupe on markup alone** across a module
(`src/dom/template.rs:289-300`).

**There is no benchmark in either repo comparing `template()`+`cloneNode` against a `createElement`
chain.** The justification is one sentence, twice — *"`cloneNode` (via `template()`) improves repeat
insert performance and precompilation reduces references to the minimal traversal path"*
(`packages/babel-plugin/README.md:72`). **Could not determine.**

What *is* measured is `cloneNode`'s absolute cost: **0.92 ms across 1 000 calls** in a `replace1k`
profile, beside `remove` 3.93 ms and `insertBefore` 0.75 ms
(`documentation/performance-experiments.md:4119-4122`), self-time that is *"browser-internal,
identical between Solid 1 and Solid 2"* (`:4113`), concluding *"that is ~5.5 ms of inherent DOM cost
— not optimizable in any framework using a per-row reconciler"* (`:4125`). Independently, §10.6
measured Solid at **13 % over a hand-written `cloneNode` loop**. The in-tree contrast is not a
benchmark but the **universal generator**, which has no parser downstream and must emit a
`createElement` chain — six helper calls where the DOM generator emits one `_tmpl$()`
(`packages/compiler/CHANGELOG.md:110`).

There is a recorded **cost** the other way. Because the parser restructures markup, `validate` became
a **hard compile error**: *"Once the validator fires the emitted positional walk is guaranteed not to
match the browser-built DOM (crashed or silently misplaced bindings; desynced hydration under SSR)"*
(`packages/compiler/CHANGELOG.md:126`) — which is why the compiler links `html5ever`. **Read that as:
the template strategy buys a browser-native bulk construction primitive, and you pay by depending on
the HTML parser's exact restructuring rules, which then needs its own HTML parser in the compiler to
police.**

### 6.4 Locating the holes

The walk is *declarations*, not calls. `child_walk_expression` (`src/dom/template.rs:443-467`) chains
off the **most recently declared walk variable** when one precedes this position, then the hydration
anchor, and only falls back to root-relative at the start of a parent; anchors are saved and restored
per parent (`src/dom/children.rs:31-47`). **A walk variable is emitted only for a node something
needs** — a nine-node fixture produced four declarations.

When a parent hosts more than one dynamic slot each needs its own truthy marker, because *"the marker
doubles as the runtime's `$$SLOT` ownership tag, and shared or null markers let one slot's cleanup
destroy a node that migrated to its neighbor"* (`src/dom/children.rs:64-69`, solidjs/solid#2830). The
cascade is `dynamic_slot_marker` (`children.rs:576-650`): hydratable → marker pair; boxed by text →
a dedicated placeholder, since *"the preceding and following template texts would otherwise merge
into a single node during HTML parsing"*; otherwise ride the next static sibling; otherwise `null`.

### 6.5 Static vs dynamic — purely syntactic

**One function, one authority** — *"Nothing outside this module may re-derive dynamic
classification"* (`src/shared/classify.rs:1-11`). `is_dynamic_deep` (`classify.rs:167-265`) sets
`dynamic = true` on: any **call expression** (`:184`), a tagged template (`:187`), **static member
access** (`:193`), computed member access (`:199`), a private field (`:205`), a spread (`:211`), the
`in` operator (`:214`), and with `check_tags` a JSX element or non-empty fragment (`:221`, `:227`).
It **skips function bodies entirely** (`:231-239`), and a top-level arrow short-circuits to `false`
(`:176-181`).

So a **bare identifier is static** and a member access is dynamic:

```js
_$insert(_el$4, d1);                              // identifier — passed by value
_$insert(_el$6, () => { return props.text; });    // member access — thunked
```

**There is no type information, no purity analysis and no dataflow.** `props.text` is dynamic not
because Solid knows `props` is a proxy but because a `.` appeared. Two escapes: a `/*@static*/`
marker comment (`classify.rs:39-47`, renamed from 1.x's `/*@once*/` and dropped from the public
model) and a namespace-import member, which cannot be reactive (`:134-157`).

`class` and `style` get a special case: anything not **confidently evaluable at compile time** becomes
dynamic even if syntactically static (`src/dom/attrs.rs:306-310`). A confident value is **inlined
into the template string** — which is why `title=static`, `class=big` and `style=font-size:12px` cost
nothing at runtime.

### 6.6 One effect per template root

`wrap_dynamics_statement` (`src/dom/dynamics.rs:59-227`) runs once per template root over a flat slot
list accumulated through the whole lowering, so **bindings on different elements in the same template
share one reactive node** (`src/dom/element.rs:332-336`). Per-slot codegen: `class`/`style`/stateful
props get a `_p$` and **no** dirty guard, because the helper diffs internally (`:146-161`);
`textContent` gets `!_p$ || v !== _p$.v`, because an initial `undefined` must still write
(`:163-186`); everything else gets `v !== _p$?.v` (`:188-193`).

The `_p$?.x` optional chaining is a 2.0 change that *"removes a per-render-effect setup allocation"*
(`dom-expressions/packages/babel-plugin-jsx/CHANGELOG.md:304`). And `value={props.value}` on an
`<input>` cost 1.9.15 a **second** effect where Solid 2 folds it into the one: seven bindings →
**1 reactive node in 2.x, 2 in 1.x**.

### 6.7 `insert()`'s fast paths — thirteen checks to write one string

`insert` (`web/src/client.ts:1273-1321`) is a universal receiver: the value may be a string, a
number, `null`, a DOM node, an array, an accessor returning any of those, or an accessor returning an
accessor. Its one genuinely important branch is **the static escape hatch** at `:1278` — if the
hole's value is not a function, `insert` runs once and **creates no effect at all**.

Counting the type and identity tests on the commonest update in any application, *a `String` hole
changing value*: `typeof accessor !== "function"` (1); `flatten`'s function test, unwrap loop,
null/bool/`""` test and `Array.isArray` (`signals/src/boundaries.ts:675-745`, 4+); `normalize`'s
`doNotUnwrap && typeof value` and `multi && !Array.isArray` (`client.ts:2682-2683`, 2);
`hydrationRt !== null` (2); `sharedConfig.hydrating` (1); `value === current` (1); `typeof value`
(1); `typeof current` (1). **Roughly 13 tests to perform `parent.firstChild.data = value`.**

### 6.8 Hydration, and what it costs

Under `hydratable: true` the template gains `<!$>…<!/>` comment pairs, `_tmpl$()` becomes
`_$getNextElement(_tmpl$)`, and each marker becomes a `_$getNextMarker(...)` pair whose runtime walk
counts `$`/`/` comments with nesting depth (`client.ts:2221-2240`).

Measured (esbuild minify + brotli q11, `@solidjs/web@2.0.0-rc.9`, `solid-js` external): a typical
page of 16 symbols is **5 059 brotli**; the same plus `hydrate` and `getNextElement` is **6 498**.
**Hydration costs 1 439 brotli bytes, +28 %, on top of the DOM runtime a CSR page needs.**

And a fourth cost the repo names but does not measure: `isHydrating(node)` is an **unconditional
early-return at every attribute write site** — `client.ts:530, 658, 687, 702, 798, 880, 2444, 2573` —
whose body walks `sharedConfig.claimRoots` (`:2354-2375`). **A CSR-only app pays that check on every
DOM write forever**, because the runtime is one module. The repo concedes the principle elsewhere:
server-owned output renders inside a `NoHydration` zone because *"`_hk` would be pure tax"*
(`documentation/server-components/server-components.md:281`).

### 6.9 Sizes and compiler throughput

`@solidjs/web@2.0.0-rc.9` with `solid-js` external, minify + brotli q11: `{template}` **598**;
`{template, insert}` **2 295**; `+ addEvent, delegateEvents` **3 008**; `{spread}` alone **4 922**;
`*` **13 943**.

With the reactive core bundled in, the jump that matters: **`{template}` alone is 255 brotli bytes;
`{template, insert}` is 10 350.** *`insert` is the door to the entire reactive core.* A page of static
templates ships a quarter of a kilobyte; **one dynamic text hole costs 10 KB.** That is the number
beni's view layer has to beat, and `src/js/Reach.zig`'s 2 147-byte floor says it can.

**Throughput**, 1 000 100 bytes / 40 607 lines of JSX, median of 7 after 3 warm-ups, single-threaded
(`uptime` 10:36, load 0.43): the native compiler **150.0 ms — 271 k LOC/s, 6.4 MB/s**; the 1.x Babel
plugin **63 181 ms**, ~1 k LOC/s. **421×** (the repo's own figure is 355× on an Apple M5,
`packages/compiler/README.md:196`). For beni's budgets: 271 k LOC/s for a JSX transform is the same
order as beni's own >250 k LOC/s per-core checking target — a native compiler doing this work is not
a bottleneck.

### 6.10 What changed vs 1.x, in brief

Babel → Rust/Oxc, with a fixture corpus as behaviour oracle and a 150-combination option-matrix
parity suite; the `effect(compute, commit)` split with `_p$?.x`;
`className`/`style`/`setStyleProperty`/`readShallow` replacing the 1.x `setAttribute(el,"class",v)`
path; **`classList` removed** and merged into `class`, *"to avoid two ways to do the same thing and
to simplify the compiler/runtime"* (`documentation/solid-2.0/07-dom.md:158`); `$$click` → `_$$click`
so a 1.x runtime on the same page cannot double-fire (`packages/compiler/CHANGELOG.md:8`);
native-element spread moved from `mergeProps` to an array of sources; **IIFE elision in statement
position**, *"saves one closure allocation + one function-call frame per render"*; `validate`
promoted to a hard error; and TSRX, a whole second surface syntax (§8.5).

### 6.11 What a beni compiler could delete, with the line each check lives on

beni knows four things this compiler does not: **the type of every hole**, **an `impure` bit per
function**, **that reference equality implies deep equality**, and **the whole program**.

**A. Hole typing deletes `insert()`'s dispatch.** For a `String` hole, delete:

| check | file:line |
|---|---|
| `typeof accessor !== "function"` ×2 | `web/src/client.ts:1278`, `:1280` |
| `typeof value !== "function"` and the nested inner effect | `client.ts:1296`, `:1297-1305` |
| `value === INNER_OWNED` | `client.ts:1313` |
| `marker !== undefined` / `multi` | `client.ts:1274`, `:1285`, `:2604` |
| `flatten`'s function test and unwrap loop | `signals/src/boundaries.ts:679-684` |
| `flatten`'s `null/true/false/""` skip | `boundaries.ts:685-690` |
| `flatten`'s `Array.isArray` + recursive `flattenArray` | `boundaries.ts:691-699`, `:704-745` |
| `normalize`'s `doNotUnwrap && typeof value`; `multi && !Array.isArray` | `client.ts:2682`, `:2683` |
| `insertExpression`'s `typeof value` four-way dispatch | `client.ts:2603`, `:2606`, `:2619`, `:2621`, `:2638` |
| `typeof current` | `client.ts:2607` |
| `ownsAllChildren`'s six branches | `client.ts:2742-2754` |
| the dev `UNRECOGNIZED_INSERT_VALUE` arm | `client.ts:2666-2677` |

For an **element hole**, `current.parentNode === parent` (`:2632`) and `current && parent.firstChild`
(`:2635`) exist because *user code may have moved the node* — in beni nothing outside the compiler
touches the DOM, so both go. For a **list hole**, `reconcileArrays` stays but the
primitive-materialisation loop (`:2645-2656`), `currentArray = current && Array.isArray(current)`
(`:2639`) and every `$$SLOT` ownership test (`web/src/reconcile.ts:17-38`, `client.ts:2636`, `:2795`)
go — **the `$$SLOT` tag exists only because two sibling holes can fight over a migrated node**
(`src/dom/children.rs:64-69`), and a whole-program compiler assigns every node exactly one owning
slot.

**B. Purity deletes the getters, the thunks and `untrack`.**

| construct | why it exists | beni |
|---|---|---|
| `get b() { return props.b; }` | the callee might read it lazily under tracking | pass the value when the callee is pure in that argument |
| the `c: () => …` vs `get c()` distinction | a syntactic `is_dynamic` guess | typed |
| `_$insert(el, () => props.text)` thunk | `insert` must subscribe | a pure function of non-reactive inputs needs **no thunk, no effect, one write at construction** |
| `untrack(() => Comp(props \|\| {}))` | a component body might subscribe its caller | `solid/src/client/component.ts:86` — deletable when effect flags are known |
| `readShallow`'s three-way probe | a class/style object might be a store proxy | `client.ts:859-871` — beni knows record from signal |

And the classification rule itself is a **syntactic proxy for a dataflow question**: `props.text` is
dynamic because a `.` appeared, `d1` is static because it is an identifier — *even if `d1` is
reassigned*. beni's answer is exact, so `/*@static*/` (`classify.rs:39-47`) and the namespace
carve-out (`:134-157`) both become unnecessary.

**C. Immutability deletes the diffing and the shadow state.** `className` (`client.ts:695-742`) and
`style` (`:791-856`) keep shadow state **on the DOM node** — `node._$classes`, `node._$styles` — and
diff against it every update, because *"value/prev are user-owned and may be the same object on
shared-effect reruns"* (`:722-724`). With reference-equality ⇒ deep-equality all of it goes:
`className`'s `typeof value === "number"` ×2 (`:697-698`), the `null`/`false` reset (`:703-709`), the
string fast path (`:711-715`), the `typeof prev === "string"` reset (`:719-722`),
`classListToObject` plus two diff loops plus the `key === "undefined"` guards (`:723-741`), the
`node._$classes = value` shadow write (`:741`); and on the style side `:802-808`, `:810-813`,
`:814-817`, the `{...prev}` seeding (`:820-825`), the removal loop (`:827-833`), the apply loop
(`:835-847`) and `classListToObject`/`flattenClassList` (`:2376-2400`).

beni's `class` is a `String` or a list of `(String, Bool)`, so a changed reference is a changed value:
emit `el.className = v` or a per-key `classList.toggle` with **no shadow state and no diff** — which
is exactly what Solid already does for the *statically split* case (`src/dom/set_attr.rs:77-95`),
just never for the dynamic one. Keep the generated `_p$?.x !== x` guards (`src/dom/dynamics.rs:188-193`)
— but beni can keep them for **every** binding including `class` and `style`, where Solid must fall
back to the helper's internal diff precisely because object identity does not imply object equality.

**D. Whole-program knowledge deletes the spread machinery entirely.** `spread` + `assign` +
`assignProp` + the `collect*`/`resolveSource`/`entry*` family (`client.ts:929-1091`, `:1330-1373`,
`:2410-2461`) is **~4 900 brotli bytes**, and it is all key-set uncertainty: `Array.isArray(props)`
(`:936`), `hasStaticKeys(props)` (`:948`), the `children` descriptor probe (`:955-961`), the
`resolvedTable`/`viewOf`/`OmitView`/`$PROXY` dispatch (`:989-997`), the per-key `style`/`class` test
(`:1007`), and `assignProp`'s `prop.indexOf(":")` (`:2421`), `prop.slice(0,2) === "on"` +
`toLowerCase` (`:2423-2424`), `DelegatedEvents.has` (`:2425`),
`ChildProperties.has`/`DOMWithState[nodeName]` (`:2440-2441`), `Namespaces[...]` (`:2456`), the
`value === prev && DOMWithState[...] !== 1` guard (`:2415`) and the tuple-listener retention
(`:2429`). In beni a spread is a record whose fields are known, so every one becomes a straight-line
write chosen at compile time. **beni should not ship a `spread` at all.**

**E. The rest.** `isHydrating(node)` at every write site (`client.ts:530, 658, 687, 702, 798, 880,
2444, 2573`) and its body (`:2354-2375`) — beni compiles whole programs and picks one build, so it
never ships both; `hydrationRt !== null` ×4 in `insert` (`:1277, 1294, 1299, 2573`);
`setAttribute`'s `value == null || value === false` and `value === true ? "" : value` (`:660-662`) —
a typed `Bool` attribute compiles to toggle/remove directly; its `selectMultiple` special case
(`:659, 670-675, 677`) and its `href`/`action` claim test (`:681`) — the compiler knows the tag;
`setProperty`'s `SELECT`/`INPUT`/`TEXTAREA` dispatch (`:537-545`); `addEvent`'s four handler-shape
tests (`:760, 767, 777, 783`) — Solid already skips the whole helper for a resolvable handler
(`src/dom/events.rs:194-204`) and **beni can always take that path**; `eventHandler`'s `_bnd` seam
probe (`:2506-2509`), three-way calling convention (`:2512-2516`) and shadow-DOM retarget
(`:2519-2523`); `tagHost`/`_$host` portal retargeting (`:2717-2740`, `:2557`, `:2537`);
`template()`'s lazy-init test per clone (`:399-400`); and `create()`'s document-shell regex (`:377`).

### 6.12 What beni must keep, and what it must build instead

**`reconcileArrays` stays** — keying and identity are semantic, not type-erased.

**The template + `cloneNode` strategy transfers directly, and beni is better placed to use it**,
because beni does not need the HTML-restructuring validator that forced Solid to link `html5ever`
into its compiler: beni's `Html` type can be constructed so that malformed nesting is a **type
error**, not a template-parse hazard. That is a guarantee in rule 7's sense, and it is free.

**The one-effect-per-template-root grouping** is the best idea in this compiler and beni should copy
it whole — then go further. Solid must put *all* slots in one compute object because any slot might
change; **beni can partition slots by which model fields they read and emit one update group per
partition**, which Solid cannot do without dataflow. **That is strategy C in miniature, at
template-root scope, and it is the most tractable place to try it.**

**`insert`'s non-function fast path** (`client.ts:1278-1284`) is the shape to generalise: in beni it
should be the *default*, and an effect the exception.

**And beni does not get the escape hatches** — `/*@static*/`, `on:`, `prop:`, `attr:`, `use:`, spread
all exist because Solid's compiler cannot see through JavaScript. Rule 7 asks of each *what guarantee
does removing it buy*: removing `spread` buys exhaustive attribute typing, which is a guarantee;
removing the attribute-versus-property choice buys nothing, so **beni should keep an explicit escape
for that** rather than guess from a hard-coded table like Solid's `src/shared/constants.rs`.

**The one-line summary.** Solid's JSX compiler spends its budget *guessing*: a syntactic `is_dynamic`
(`classify.rs:167-265`), prop getters because laziness is unknowable, `insert`'s 13-check dispatch
because hole types are unknowable, `className`/`style` shadow diffs because mutation is unknowable,
and `spread`'s 4.9 KB because key sets are unknowable. **Every one of those is a question beni's
front end has already answered before the backend runs.** The parts worth copying — the hoisted
template, the compile-time sibling walk, the one grouped effect per root, delegation through a
property write — are precisely the parts Solid reached by *removing* runtime decisions. **beni starts
where Solid's optimiser stops.**

---

## 7. Lists — `For`, `mapArray`, `reconcileArrays`, `Repeat`

Two layers, cleanly split. `@solidjs/signals` owns the **identity** diff (array of items → array of
mapped values, reusing owners); `dom-expressions` owns the **DOM** diff (array of nodes → array of
nodes). They never see each other's data.

### 7.1 The API 2.0 actually ships

There is no `Index`: `packages/solid/src/index.ts:269` lists it under `/* Not Implemented */` with
the comment `Index, // handled by For`, because *"Having both `For` and `Index` encourages
bikeshedding and accidental misuse"* (`documentation/solid-2.0/03-control-flow.md:11`); the removals
table reads `| Index | For keyed={false} |` (`:417`). So: two list components, `For` and `Repeat`
(`packages/solid/src/client/flow.ts:81-109`, `:126-144`), and three keying modes on one `keyed`
prop — absent or `true` (the **default**, identity by reference, raw item + index accessor); `false`
(item accessor + plain index, the old `Index`); or a key function. `compare()` degrades to `true`
when there is no key function (`packages/signals/src/map.ts:684-686`), which is what makes
`keyed={false}` walk the whole overlap unconditionally.

### 7.2 `mapArray`'s algorithm

Four parallel arrays: `_items` (a private copy of the last input), `_mappings`, `_nodes` (one owner
per row), plus optional `_rows`/`_indexes` per-row signals (`map.ts:700-713`). A prefix scan
(`:400-409`) and a suffix scan (`:411-420`) trim the window; the suffix scan is *counted, not
staged*, which shed *"~4 full-array passes even for a single-row removal"*.

**The single most important line for beni is the no-structural-change exit:**

```ts
// references/solid/packages/signals/src/map.ts:425-428
// no structural change (every position matched in place at equal
// length — the common post-reconcile shape): keep the same mapped
// array identity so downstream consumers don't re-run at all
if (start === newLen && this._len === newLen) {
  this._items = newItems.slice(0);
  return;
}
```

The computed then returns **the same array object**, its `_equals` is `===`, so **no subscriber is
notified at all**: no `flatten`, no `normalize`, no `reconcileArrays`, no DOM comparison. It is
reachable only when `_rows` is set — `keyed={fn}` or `keyed={false}` — because only then can the
prefix loop walk past a changed row object. **In default identity-keyed mode a single changed row
object always falls through to the general path.**

**A small-move fast path** landed 2026-09-02 (`map.ts:437-454`, `:150-302`): a ±32 probe, then a
two-pointer aligned-run scan with a 256-compare budget handling *at most 32 genuinely displaced
identities* and bailing otherwise. It is **not** an LIS. Measured payoff, from the changeset:
*"Rotate 140→6 µs, swap 94→4 µs, displace3 54→5 µs … ~0.5 kB brotli"*, and board-level
*"js-framework 1.27× → 1.10×"*. Two gating facts: it is off under `newLen > _len`, and off whenever
`_rows` or `_indexes` exist — so **writing `{(row, i) => …}` instead of `{(row) => …}` disables
it**, because a declared arity of 2 allocates an index signal per row (`map.ts:74`, `:96`, `:441`).

**The general path** (`:456-552`) is a backwards scan building a key→index map with a chained
duplicate list, then stage / create / commit. Work is **staged** because *"a map callback can throw
NotReadyError mid-pass (async read)"* (`:112-120`). A row is *moved* — owner and DOM subtree reused
— iff its key is found in the new window; *recreated* otherwise. No similarity heuristic, no
minimal-move computation: that is `reconcileArrays`' job. **Owners are reused on a move, never
recreated** (`:483`, `:291`), and disposal is deferred to the end of the pass because *"you cannot
destroy state before knowing the pass will land"* (`:117-120`).

### 7.3 `reconcileArrays` — the DOM patcher

158 lines, *"Slightly modified version of udomdiff"*
(`references/dom-expressions/packages/runtime/src/reconcile.js:1`). Branches in order: common
prefix, common suffix, append, remove, **symmetric end-swap**, map fallback.

The end-swap branch is not upstream, and the repo records both the rewrite and its price: stock
udomdiff did *two* `insertBefore` calls per iteration to two different anchors with `.nextSibling`
lookups in the hot loop, at `~10.2 µs/call` against `~3.3 µs/call` for a single walking anchor, and
`tree/[500]/[reverse]` went **2.50 ms → 1.10 ms** (`documentation/performance-experiments.md:5406-5453`);
collapsing it regresses `05_swap1k` by ~6.5 %. The map fallback (`reconcile.js:109-156`) uses a
run-length probe — `sequence > index - bStart`, *move the shorter side* — to choose between
inserting a block and replacing one node. **There is no LIS anywhere in Solid's list code.**

### 7.4 `Repeat` — the one genuinely O(changed) list

`repeat(count, map, { from, fallback })` (`map.ts:574-612`) keeps no `_items` and no keys; the
update is window arithmetic (`:645-675`) costing O(overlap + entering + leaving) with **no
comparisons and no key map**, and the index is a plain number, stable for the life of the slot. The
RFC positions it as the store companion: *"primarily intended for use with stores, where the data at
each index manages its own granular updates"* (`03-control-flow.md:58`). **`Repeat` buys O(changed)
by refusing to own identity.**

### 7.5 The cost model, measured

**(a) Signals layer**, the `@solidjs/signals@2.0.0-rc.9` dev bundle with one counter line inserted,
1 000-row list, fresh root per op, Node 24 (`uptime` 10:34:45, load 0.32). Counts are exact and
deterministic.

```
### DEFAULT KEYED, arity-1 row (the hot For shape)
op                    created  disposed  rowBodyRuns  sameMappedArray  smallMovePath
swap 1<->998                0         0            0            false              1
one label @500 (new obj)    1         1            1            false              0
partial: every 10th       100       100          100            false              0
remove row 500              0         1            0            false              0
append 1000              1000         0         1000            false              0
replace all              1000      1000         1000            false              0
clear                       0      1000            0            false              0

### DEFAULT KEYED, arity-2 row  {(row, i) => …}
swap 1<->998                0         0            0            false              0   ← fast path OFF

### keyed={r => r.id}
one label @500              0         0            1             TRUE              0
partial: every 10th         0         0          100             TRUE              0

### keyed={false}  (old Index)
swap 1<->998                0         0            2             TRUE              0   ← zero DOM moves
remove row 500              0         1          499            false              0   ← index shift
replace all                 0         0         1000             TRUE              0
```

**(b) DOM layer**, driving the real `reconcile.js` against a node stub, 1 000 nodes, final order
verified equal on every row:

```
op                     insertBefore  replaceChild  remove   total   outerIters  mapEntries
swap 1<->998 (jfb 05)             2             1       0       3         1001         997
remove row 500                    0             0       1       1          502           0
append 1000                    1000             0       0    1000         1002           0
replace all                    1000             0    1000    2000         1002        1000
reverse                         999             0       0     999            3           0
one row replaced @500             1             0       1       2          503           1
```

**Op by op.** *Create*: the `_len === 0` fast path, strictly O(N), no comparisons; DOM is
`appendNodes`, not `reconcileArrays`. *Replace all*: the small-move **probe** turns it away in ~65
compares without compiling the scan; the repo attributes the DOM side as *"~5.5 ms of inherent DOM
cost — not optimizable in any framework using a per-row reconciler"*
(`performance-experiments.md:4118-4126`). *Swap two rows*: **O(1) in DOM mutations (3) and graph
nodes (0), O(n) in comparisons and map construction** — 1 001 outer iterations and a 997-entry `Map`
to perform three mutations. *Remove one row*: the trims shrink the window below the 64 gate, so the
general path runs on a window of size 1 — 1 DOM `remove`, 502 outer iterations, no map; **but under
`keyed={false}` 499 row bodies re-run**, because every later index shifts. *Clear*: one
`this._owner.dispose(false)` tears down all N owners through the owner tree — Solid 2's one outright
win over Solid 1 (13.4 ms vs 15.0 ms), credited to *"the v2 owner-tree refactor"*.

**Select row is not a list operation at all.** jfb's Solid 2 entry holds selection in a store keyed
by row id, so a selection change dirties two keys → two render effects → two `className` writes, and
`mapArray` never runs: `04_select1k` script time **0.7 ms**, against Svelte 5's 2.6 ms. The repo
measured the alternative — a single `selected()` signal gives 2.2 ms and *"destroys select
scaling"* (`performance-experiments.md:888`). **Partial update (every 10th label)** is the same
story: the label lives in a store, the store's `$TRACK` node notifies only on *structural* change
(`store/next/store.ts:1533-1541`), and the deep-witness node is deliberately separate *"so
$TRACK/mapArray never rerun on leaf value changes"* (`store/next/target.ts:86-89`). 100 writes → 100
effects → 100 text writes, **zero list work**. With an immutable array instead it is O(N) on the
`mapArray` side in every mode.

The repo's own board (headless Chromium, 4× CPU throttle, script-time medians in ms,
`performance-experiments.md:5508-5530`): `01_run1k` 5.3 / 3.9 / 11.7 / 5.3 / 2.6;
`03_update10th1k_x16` 2.3 / 1.6 / 5.8 / 1.8 / 0.8; `04_select1k` 0.7 / 0.6 / 2.3 / 2.6 / 0.5;
`05_swap1k` 2.0 / 1.5 / 25.4 / 2.1 / 0.4; `07_create10k` 55.5 / 43.5 / 226.7 / 54.0 / 29.4;
`09_clear1k_x8` 13.4 / 15.0 / 21.7 / 13.9 / 11.4 — solid-next / solid-1.x / react-hooks / svelte-5 /
vanillajs.

### 7.6 Where it is O(n) anyway — honestly

Unconditional per list update, however few rows changed: the prefix+suffix scan (a midpoint change
costs n/2 + n/2 compares); `this._items = newItems.slice(0)`, a full input copy, at four sites
(`map.ts:383`, `:426`, `:538`, `:296`); the small-move commit `slice()`ing both live arrays
full-length *by design* (*"native memcpy keeps the fresh-identity contract downstream change
propagation relies on"*, `:138-140`); the general path's two `new Array(newLen)` plus
`newIndicesNext`; one `setSignal` per row per update under `keyed={false}`/`keyed={fn}`; and on the
DOM side `flatten` allocating a fresh array of every row node plus `normalize` walking it again
(`boundaries.ts:705-733`, `client.js:1872-1883`) *before the diff starts*. The only genuinely
sublinear path in downstream work is §7.2's no-structural-change exit — reached after an O(n) scan.

**Measured scaling** (Node 24, warmed, one label changes, new row object, new array; `uptime`
10:35:09, load 0.43; two independent runs):

| mode | N=1 000 | N=10 000 | N=100 000 |
|---|---|---|---|
| default keyed, arity-1 | 23.2 / 25.0 µs | 137.5 / 134.7 µs | 2 862 / 2 804 µs |
| `keyed={r => r.id}` | 21.5 / 21.0 µs | 273.3 / 267.6 µs | 3 189 / 3 062 µs |
| `keyed={false}` | 15.1 / 16.7 µs | 144.0 / 148.0 µs | 2 442 / 2 252 µs |

Linear to 10 k (~14 ns/row), superlinear past it. `keyed={fn}` costs ~2× default keyed at 10 k
despite doing strictly *less* structural work, because it pays 10 000 `setSignal` calls and carries
10 000 extra signal objects.

### 7.7 One label changes in a 10 000-row table — node by node

**Default `<For>` (identity keying), the worst case for immutable data.** Prefix 5 000 compares,
suffix 4 999, window = 1. The no-structural-change exit is not taken; the small-move gate is not
met; the general path allocates two 10 000-element arrays, disposes the old row's owner, creates a
fresh one and **re-runs the row callback — the whole `<tr>` template is cloned and every binding
re-created**. Commit copies ~10 000 elements twice plus a third full `slice`. `_mappings` is a new
array, so the memo notifies, `flatten` and `normalize` each walk 10 000 nodes, and `reconcileArrays`
does ~5 003 outer iterations to emit **1 `remove` + 1 `insertBefore`**. Measured: **135 µs**.

**`<For keyed={r => r.id}>` or `keyed={false}` — the shape beni should copy.** The prefix scan walks
all 10 000 positions issuing gated `setSignal`s, of which exactly one commits; the
no-structural-change exit fires; `_mappings` is returned unchanged so **nothing downstream runs at
all**; the one committed row signal wakes one render effect and writes one text node. Measured:
`created 0, disposed 0, bodyRuns 1, sameMappedArray true`, **268 µs** (`keyed={fn}`) / **144 µs**
(`keyed={false}`).

**A TEA top-down reference-equality walk**: 10 000 pointer compares, one mismatch, descend into that
row, compare its 3–4 holes, one text-node write, **zero allocations**.

| | compares | allocations | computations re-run | DOM mutations |
|---|---|---|---|---|
| Solid, default keyed | ~20 000 | 5 × 10 000-elem arrays | 1 row rebuilt from scratch | 2 (+ a full `<tr>` clone) |
| Solid, `keyed={fn}` / `keyed={false}` | 10 000 | 1 × 10 000-elem array | 1 | 1 text write |
| TEA + compiled templates + per-hole `===` | ~10 004 | 0 | n/a | 1 text write |

**The conclusion, and it is the most important paragraph in this report.** A top-down
reference-equality walk is **not asymptotically worse than Solid's `<For>` on a single-row edit. It
is the same O(n) class, with a smaller constant and no allocation.** Solid's `<For>` beats it on
*structural* edits — move, remove, reorder — where the keyed diff reuses the DOM subtree and its
state and the TEA walk would have to discover the move itself. Solid's genuinely O(1) answer to a
one-row edit is **not `<For>` at all; it is the store**, which requires mutable records with stable
identity — which beni does not have and §5.5 says it does not need.

### 7.8 Solid's team has already run beni's experiment, and published the result

On uibench, 96 cases, comparing the Solid 1 idiom (reconcile immutable snapshots into a store,
`<For>` by reference) against the immutable shape (`createSignal(snapshot)`,
`<For each={rows} keyed={r => r.id}>`, accessor rows, no store):

> "The Vapor/Octane shape in Solid — `createSignal(snapshot)`, `<For each={rows} keyed={r => r.id}>`,
> accessor rows, no store — is faster on **96/96 cases**"
> — `references/solid/documentation/performance-experiments.md:7374-7377`

| shape | vs Octane | vs Vapor |
|---|---|---|
| store + `reconcile` (Solid 1 idiom) | 2.59× | 2.52× |
| signal + keyed `<For>` | **1.20×** | **1.16×** |

and the ruling (`:7383-7387`):

> "`reconcile` is the tool for state edited in place through a setter (the writes *are* the diff),
> not for ingesting immutable snapshots (the snapshot *is* the diff)."

**That sentence is the one to quote at report 29.** For a language whose data model is immutable
snapshots, Solid's own measurements say: do not synthesise a mutable store from the snapshot; key
the list by a stable field, hand rows an accessor, and accept the O(n) pass.

### 7.9 And Solid deleted a faster list mechanism for being outside the graph

2.0 spent a long arc on a patch-mode list driver that bypassed `mapArray` + `reconcileArrays`
entirely for compiled store-array lists — a compile-time `rowProof` stamp, a `$ll` marker, a
`driveList` seam. It was removed. The post-mortem (`performance-experiments.md:7224-7244`) is that
*"the channel's visibility decisions were being made by hand at the driver, outside the graph, and
every round moved them"*, and the maintainer pulled it *"rather than ship behind opt-in ('putting it
behind opt-in doesn't matter')"*. Worth reading twice: **a parallel list-update mechanism that beat
the general path was deleted for being outside the reactive graph.** A beni design whose update path
is *only* the compiled walk — with no graph to be outside of — does not have this failure mode.

---

## 8. What exists only because of JavaScript and TypeScript

Solid is extraordinarily well engineered against a language that cannot help it. This section
separates the mechanisms that are *reactivity* from the mechanisms that are *JavaScript*, because
beni only has to inherit the first kind.

### 8.1 Props are getters, and the whole prop system is a workaround for eager evaluation

`<Foo bar={count()} />` evaluates `count()` at the call site. To keep a prop reactive the compiler
must not evaluate it — so it emits a **getter**, and every prop becomes an accessor property on an
object the component may not destructure. That one fact generates a family of mechanisms:
**`merge`/`omit`** (2.0's renames of `mergeProps`/`splitProps`,
`references/solid/packages/signals/src/store/utils.ts:965`, `:1104`) because you cannot spread or
destructure props without collapsing their getters; **view proxies** forwarding
`getOwnPropertyDescriptor` so laziness survives arbitrary layering (`utils.ts:279-293`); and
**`isStatic(props, key)`** — 2.0's newest addition, and the one this report cares about most:

```ts
// references/solid/packages/signals/src/store/utils.ts:262-273 (abridged)
export function isStatic(o: object, key: PropertyKey): boolean {
  if ($PROXY in o) { … return desc === undefined ? hasStaticKeys(o) : desc.get === undefined; }
  const desc = Reflect.getOwnPropertyDescriptor(o, key);
  return desc === undefined || (desc.get === undefined && desc.set === undefined);
}
```

with the doc explaining what it is for: *"A DATA descriptor means 'nothing reactive can hide behind
this value': the key is a data property of a plain-object leaf — **the compiler's own encoding of a
static attribute**. … That is what lets a consumer skip a reactive node for a static prop at the
bottom of a component chain"* (`utils.ts:283-290`).

**Read that again with beni in mind.** `isStatic` is a *run-time property-descriptor lookup* whose
purpose is to discover, during rendering, a fact a whole-program compiler knows at compile time:
*is this prop a constant?* Solid has to ask because JavaScript erased the answer. beni's compiler is
the thing that would have erased it, so beni simply does not: a prop whose argument is a literal or
a pure expression of nothing reactive gets no reactive node, decided in the checker, with no
descriptor lookup and no `$PROXY` brand. **This is the cleanest single example in the report of "do
better because typed and whole-program".**

**"Don't destructure props"** is enforced only by documentation. beni needs none of this: a beni
call is saturated and its arguments have types, so a reactive prop is either a value (pass it) or a
function of the model (pass the function, whose return type the compiler knows). No props object, no
getter, no proxy, no descriptor, no merge, no split, no destructuring rule.

### 8.2 The component-runs-once model, and `untrack`

`createComponent` wraps the component body in `untrack`
(`references/solid/packages/solid/src/client/component.ts:80-87`) so a signal read in a component
body does not subscribe the *parent* computation and re-run the whole subtree. The "components run
once" model Solid users are taught is that one line plus §8.1's getter discipline. In a language
where `view` is a pure function returning a value, this is not a model to teach — it is what
functions do.

### 8.3 Dev-mode machinery, and the three build tiers

**5 246 of 24 312 lines (22 %)** are the dev and observe tiers, and they ship in no production
bundle: `packages/signals/package.json:29-40` resolves `.` to `dist/prod/index.js` by default, and
the build mangles private properties afterwards (`:53`). A production Solid pays nothing for them.
What is in there is worth listing, because each item is a *compile-time* question in beni:

| Solid's dev check | where | beni |
|---|---|---|
| `REACTIVE_WRITE_IN_OWNED_SCOPE` — writing a signal inside a computation | `core/core.ts:141-143`, guard at `:2277-2295` | the `impure` bit; a compile error (§9.3) |
| `PRIMITIVE_IN_FORBIDDEN_SCOPE` — creating a primitive inside a tracked effect | `core/core.ts:139-140` | a scope rule the checker carries |
| `NO_OWNER_EFFECT` — an effect with no owner is never disposed | `core/effect.ts:84-101` | a `Scope` is a parameter, not an ambient |
| `ASYNC_STORE_SETTER` — a store setter callback returned a Promise | `core/core.ts:147-150` | `sync` refuses a suspending body |
| `FLUSH_IN_ACTION`, `FLUSH_IN_EFFECT_CALLBACK` | `core/scheduler.ts:1479-1523` | structural: beni has no re-entrant flush |
| strict-read warnings for untracked reads in a component body | `core/core.ts:1426-1431` | there is no ambient tracking to be outside of |

Every one is a run-time check, in a tier deleted from production, for a mistake a type system can
refuse. §9.4 is what happens when one of them is the only thing standing between you and a crash.

### 8.4 TypeScript-shaped API

`Merge`, `Omit`, `Truthy`, `NoInfer`, `Part`, `PathSetter`, `CustomPartial`, `StorePathRange`
(`packages/solid/src/index.ts:44-82`) exist to make untyped JavaScript patterns expressible; the
`.tsrx` frontend's rejection of "authored lazy destructuring"
(`packages/babel-plugin/src/tsrx/lazy.ts:38`) is the same thing a level up. beni's ordinary records
and its `case` cover the intent.

### 8.5 Solid is itself adding language syntax — the report's best argument for built-in JSX

Solid 2 ships an optional source dialect, **TSRX** (`.tsrx` files, or any file with
`syntax: "tsrx"`), parsed by `@tsrx/core` and desugared to JSX before the normal pipeline
(`packages/babel-plugin/src/tsrx/index.ts:1-13`). Its constructs are control flow *as syntax*:

```
// references/solid/packages/babel-plugin/src/tsrx/desugar.ts:14-25 (abridged)
 * - `@if` — `Show` for a single branch, `Switch`/`Match` for chains; `@else`
 * - `@for (const x of expr; index i; key k)` — `For`; `key` present emits …
 * - `@switch` — `Switch` with one `Match when={disc === test}` per `@case`
 * - `@try/@pending/@catch (e, reset)` — `<Errored fallback={(e, reset) => …
```

plus `@empty` and compile-time scoped styles; 728 lines of desugaring. The reason it exists is
visible in its own diagnostics: because `For` is a *component* and JavaScript is eager, `For` must
hand the row to the callback as an **accessor**, so the user writes `item().name` and may not
destructure (`desugar.ts:101-109`). **Eight years after JSX, Solid is adding syntax to paper over
the fact that its control flow is library components in an eager language.**

beni's built-in JSX starts on the other side of that: `if`, `case` and list comprehension are
already language constructs with exhaustiveness and types; a row is a value of a known type, not an
accessor; there is nothing to desugar and nothing to document. Report 28 owns the design — this is
the evidence that the owner's instinct is where Solid is heading anyway, from the far side.

### 8.6 What beni lacks that Solid relies on — and the fiber-slot objection

**(a) Mutation.** A signal is a mutable cell; `link()` mutates two lists on every new edge. beni's
answer is already settled and is not "make beni mutable": only platform packages may write `foreign`
(rule 6), so the cells and the graph live in the platform's JavaScript behind a beni-typed API,
exactly as `Ref` does. R25 §7.2 notes that a signal read is `impure` and not `suspends` — the same
class as `Ref.get` — and that **`Opt.zig`'s single-use inlining, the one transform that would
silently break dependency tracking, is already forbidden by the `impure` bit** (decision A5). beni's
optimiser is not an obstacle here; it is a help.

**(b) A global ambient observer.** This is where report 25 raised its one named blocker, and it is
worth settling.

R25 §7.3 argued: Solid installs the observer in a module-level variable and restores it in a
`finally`; if the tracked function is `async` the `finally` runs at the first `await` and every read
after that point is silently untracked; Leptos fixes it by re-installing inside `poll`; beni could
do better by restoring at every fiber resumption — *"the cost is that it needs a slot, and A7 bought
exactly three fixed slots and declined a general `Context`. A 'current observer' is a fourth"*
(R25 §7.3), and its §7.6 scorecard lists *"a fiber-local observer slot — without it, silently
wrong"*.

Solid 2 confirms the first half exactly. The observer is module-level `let`s —
`export let tracking = false;` and `export let context: Owner | null = null;`
(`core/core.ts:152`, `:168`) — and every install/restore pair is a synchronous `try`/`finally` around
a call (`untrack`, `:1462-1472`; `spectate`, `:1492-1500`; `runWithOwner`, `:2429-…`). There is no
fiber, no async-context, no `AsyncLocalStorage`. §4.4 shows it failing, three ways.

**But the objection dissolves, and here is the argument.** The hazard is *a tracked computation that
suspends*. It exists in Solid because JavaScript lets you pass an `async` function to `createMemo`
and nothing stops you. beni is not in that position: **A6 already decided that `sync` ships in the
first cut, and `sync` is a compiler-checked promise that a function contains no suspension point.**
If the platform's tracking primitive takes a `sync` function — which is exactly what W8 already
recommends for every callback crossing the boundary, *"the platform's registration primitives take a
`sync` function and nothing else can be passed"* — then:

1. A tracked computation cannot suspend, by the checker.
2. A fiber can only be descheduled at a suspension point (P2 §6; R25 §4.3's central result).
3. Therefore no other fiber can run between the install and the restore.
4. Therefore a **plain module-level variable in the platform's JavaScript is correct**, with no
   fiber-local slot, no per-resumption restoration, and no fourth slot against A7's three.

That is the same proof that makes `sync update` a concurrency proof (R25 §4.3), applied to a second
thing, and it costs nothing new: the check already has to exist.

What the slot would buy is the *feature* Leptos has and Solid does not — a tracked computation that
awaits and keeps tracking. That is a capability question, not a correctness question, and it goes to
the owner separately (S2). Note also that Solid's `createResource`-shaped split — *"a `sync` source
function whose reads are tracked, and a suspending fetcher whose reads are not"* — is not obviously
a workaround to be removed: it is also a clear statement of which reads are dependencies, and beni's
`sync` bit would make that split *visible in the type* rather than a convention.

**Verdict: report 25's "signals need a fiber-local slot" objection does not survive, provided
tracked computations are `sync`.** It should be re-issued as a much smaller question — *do we want
tracking to survive a suspension, as a feature?* — and it is no longer a blocker on option E.

**(c) Proxies.** §5's material. beni has immutable records and reference equality instead, and §5.5
says that is enough.

---

## 9. Guarantees: what the Solid model keeps, and what it loses

beni's yardstick is rule 7 — *"Beni's job is to make the error guarantees — like Elm does — but not
to enforce anything on the devs."* A rule stays if it protects a guarantee (no runtime exception,
no silent wrong answer, exhaustive matches, managed effects) and goes if it only encodes taste.
This section scores the signals model against the guarantees beni has, and then asks which of
Solid's footguns a typed pure language could convert into one.

### 9.1 The scorecard

| guarantee | signals | evidence |
|---|---|---|
| **Glitch-freedom** (no computation ever sees a mixture of old and new inputs) | **kept, structurally** | height-ordered drain, `heap.ts:150-161`; §1.3 |
| **Leak-freedom** (nothing outlives its scope) | **kept, structurally** — with one hole | owner tree + `disposeChildren`, `owner.ts:71-166`; the hole is an effect created with no owner, which is a **dev warning only** (`effect.ts:84-101`) |
| **Deterministic update order** | **kept** | heights are integers maintained incrementally; the drain is a deterministic walk |
| **No stale closure** (React's hook hazard) | **kept** | components run once (`component.ts:80-87`); there is no re-render to capture a stale value in |
| **Single source of truth** | **lost** | state is per-cell by construction |
| **Exhaustive messages** (a `case` over everything that can happen to a screen) | **lost** | there is no `Msg` type; per-cell `Result`s are still matched, the whole-program version is gone |
| **Time travel / state serialisation / a replayable log** | **lost** | R24 §10.3's finding is that Elm's debugger is a *consequence* of one model cell + a pure `update` + messages-as-data; signals keep none of the three |
| **No runtime exception** | **lost, and loudly** | §9.2 |

The two "lost" rows in the middle are the price of the programming model, not of the
implementation, and no amount of engineering recovers them. This is the reason the synthesis has
three strategies (§0.5) rather than one.

### 9.2 What happens when a computation throws

There are two failure channels and they behave differently.

**A compute-phase error** (thrown by a memo body, or arriving from an upstream async source)
becomes *status on the node*: `STATUS_ERROR` plus a payload in the cold extension
(`references/solid/packages/signals/src/core/core.ts:464-470`), and it propagates to subscribers
the way pending does. A `createEffect` given an `EffectBundle` with an `error` handler receives it;
without one, *"a compute-phase error is logged and the effect simply skips that run — a non-render
effect's reactivity failing does not crash the app"*
(`references/solid/packages/signals/src/signals.ts:450-452`).

**An effect-phase error** — your own imperative code throwing — is an application error. It is
offered to the nearest error boundary, and if there is none, the reactive system **halts
permanently**:

```ts
// references/solid/packages/signals/src/core/effect.ts:236-242
  } catch (error) {
    ext(node)._error = new StatusError(node, error);
    node._statusFlags |= STATUS_ERROR;
    if (!node._queue.notify(node, STATUS_ERROR, STATUS_ERROR)) {
      haltReactivity(error);
      throw error;
    }
  }
```

```ts
// references/solid/packages/signals/src/core/scheduler.ts:456-482 (abridged)
export function haltReactivity(cause?: unknown): void {
  if (halted) return;
  halted = true;
  let message = "[REACTIVITY_HALTED]";
  …
  // … a halt that only reaches console.error leaves a page that LOOKS alive
  // with nothing an app or its telemetry can act on (#3338 …)
  const report = cause !== undefined && globalThis.reportError;
  report || cause === undefined ? console.error(message) : console.error(message, cause);
  report && report(cause);
}
```

and every subsequent write logs once and is ignored (`scheduler.ts:485-493`). The rationale line is
the one beni should read twice: *"app state is undefined at that point, so scheduling stops
entirely rather than limping along with a half-applied update"* (`scheduler.ts:443-445`).

**This is almost exactly beni's decided defect rule.** `plans/effects-decisions.md` A1: *defects are
FATAL*; `plans/browser-decisions.md` W2 recommends *"stop the scheduler and tear down the mount
(finalisers run, listeners go, requests abort); a crash screen in development builds only."* Solid
does the first half (stop the scheduler, report through `reportError` so telemetry sees it) and
**not** the second (it does not tear the mount down — the page keeps its DOM and its listeners, and
looks alive). R26's finding that an uncaught throw in a browser kills nothing means the teardown is
work the platform must do; Solid's `#3338` comment is independent confirmation that leaving a
halted page standing is a real and reported problem.

Note also the shape of the boundary API: `createErrorBoundary(fn, fallback)` where the fallback
receives `(error, reset)` and `reset` re-runs every source that fed the boundary
(`references/solid/packages/signals/src/boundaries.ts:567-582`). It is a *recoverable* boundary,
which sits above beni's defect rule rather than replacing it: a beni error boundary would be for
`Result`-shaped failures, not for defects.

### 9.3 Solid's footguns, and which ones a typed pure language makes impossible

| footgun | what happens in Solid | in beni |
|---|---|---|
| **Reading a signal outside a tracking scope** | the read succeeds and returns the current value; the surrounding code simply never updates again. Silent. Dev builds can warn for component bodies via `strictRead` (`core.ts:1426-1431`), but only inside `untrack(fn, label)`. | **can be a compile error.** If a tracked read has a type that only a tracked context can consume, the checker refuses it everywhere else. This is a guarantee — *no silent wrong answer* — so rule 7 says keep it. |
| **Destructuring props** | collapses getters; the component stops updating. Silent. Documentation only. | **does not exist.** §8.1. |
| **An effect that writes a signal it reads** | a feedback loop, or a glitch | Solid 2 makes it an **error**, with an escape hatch — see below. beni's `impure` bit makes it a compile error. |
| **A stale async result overwriting a fresh one** | Solid discards rather than aborts (§4) | beni cancels the fiber structurally — R25 §0 finding 4 and its §9.2 |
| **An effect created with no owner** | never disposed — leaked. Dev warning only (`effect.ts:84-101`). | a `Scope` is an argument, not an ambient; there is no owner-less position to be in |

The third row is the interesting one, because **Solid 2 already implements the rule-7 pattern beni
argues for**:

```ts
// references/solid/packages/signals/src/core/core.ts:141-143
export const REACTIVE_WRITE_IN_OWNED_SCOPE_SIGNAL_MESSAGE =
  "[REACTIVE_WRITE_IN_OWNED_SCOPE] Writing to reactive state inside an owned scope (component, computation) is not allowed. " +
  "Move the write outside or set the `ownedWrite` option if this is intentional.";
```

guarded by `CONFIG_OWNED_WRITE` (`constants.ts:32`) and thrown at `core.ts:2277-2295`. A rule that
protects a real guarantee (a write from inside a computation makes the graph's order meaningless),
**an explicit escape hatch for the developer who means it**, and the escape hatch is one option
flag. That is precisely the shape CLAUDE.md rule 7 describes as "a limit done right", found
independently in another project. It is worth citing in beni's own documentation as prior art.

### 9.4 A footgun I hit by accident, in ten lines, in a production build

Writing §3.4's experiment I wrote this, which is idiomatic JavaScript:

```js
createEffect(() => n(), v => seen.push(v));   // push() returns a NUMBER
```

An effect callback's return value is taken as its **cleanup function**
(`references/solid/packages/signals/src/core/effect.ts:228-235`). `Array.prototype.push` returns a
number. The dev tier catches it by name:

```ts
// references/solid/packages/signals/src/core/effect.ts:229-233
    if (__DEV__ && nextCleanup !== undefined && typeof nextCleanup !== "function") {
      throw new Error(
        `${node._name || "effect"} callback returned an invalid cleanup value. …`
      );
    }
```

but `__DEV__` is compiled out of the production bundle — the shipped line reads
`if (false && e !== undefined && typeof e !== "function") ;`
(`node_modules/@solidjs/signals/dist/prod/core/effect.js:116`). So in production the number is
stored as `_cleanup` and **called on the next run**. Measured, both tiers,
`@solidjs/signals@2.0.0-rc.9`, Node 24 (`solid-r1/sched/s2.mjs`, `uptime` 10:39:36, load 1.44 0.91
0.40):

```
--- PROD (default condition) ---
run 1 ok, seen = [ 0 ]
[REACTIVITY_HALTED] TypeError: r is not a function
    at runEffect (…/dist/prod/core/effect.js:114:12)
--- DEV (development condition) ---
[REACTIVITY_HALTED] … Error: effect callback returned an invalid cleanup value.
    Return a cleanup function or undefined.
```

The first run succeeds; the **second** one halts the whole reactive system, and in production the
message is `r is not a function` in mangled code.

This is not a criticism of Solid — it is what the language forces. It is a clean illustration of the
report's thesis for §0's table: **the return type of an effect callback is a type, and beni has
types.** `() -> ()` versus `() -> (() -> ())` is decided in the checker, identically in every build,
and the bug cannot be written. Three of the six dev checks in §8.3's table are of exactly this
kind.

### 9.5 The one guarantee signals *add*

Elm and beni have no equivalent of glitch-freedom because they have nothing to be glitchy: one
model, one `update`, one `view`. But Solid's height ordering is a guarantee *about a graph*, and if
beni ever compiles a dependency graph out of `view` (strategy C, §0.5), it inherits the obligation.
A compiler-derived graph has an advantage here: heights can be computed **statically** from the
dependency structure, once, at compile time, instead of maintained incrementally with an admitted
"parent check is shallow, might need to be recursive" (`core.ts:1970`). That is a small but real
"do better because typed".

---

## 10. Measured

### 10.1 What is under test

`solid-js`, `@solidjs/web` and `@solidjs/signals` all at **2.0.0-rc.9** — the npm builds, matching
the pinned source version for version — compiled by **`@solidjs/compiler@2.0.0-rc.9`**, the native
Oxc/Rust compiler, called as an esbuild `onLoad` plugin. Bundler `esbuild@0.28.2`, ESM, es2022,
`conditions:["browser"]`, `--metafile`, confirmed resolving the **prod** entries. Browser
**Chrome 153.0.8010.47 `--headless=new`**, driven over CDP by the harness reused from
[`research/26`](26-browser-host-measured.md). Machine: AMD Ryzen 9 5950X, Linux 6.12.110, Node
24.19.0 — **one engine, one machine; nothing here generalises.** Pages are served
**cross-origin-isolated**, so `performance.now()` ticks at **5 µs** rather than 100 µs (verified in
page: min non-zero delta 4 999.995 ns); every micro figure amortises ≥2 000 iterations over that
tick. `uptime` load average is recorded per batch: idle 0.00–0.02, rising to 1.0–1.9 during the runs.

**A packaging note for anyone reproducing this.** `npm i @solidjs/compiler` installs **rc.2** as
`latest`, whose `linux-x64-gnu` tarball contains only `package.json` and `README.md` — **no `.node`
binary** — and the wasm fallback is unpublished. The default install is broken; pin `@2.0.0-rc.9`.

### 10.2 Compiled output — the counter, whole

13 lines of JSX became 807 bytes:

```js
var _tmpl$ = /* @__PURE__ */ _$template(`<div class=counter><button>increment</button><span>count: `);
function Counter() {
	const [count, setCount] = createSignal(0);
	var _el$ = _tmpl$();
	var _el$2 = _el$.firstChild;
	var _el$3 = _el$2.nextSibling;
	_el$2._$$click = () => setCount(count() + 1);
	_$insert(_el$3, count, null);
	return _el$;
}
render(() => _$createComponent(Counter, {}), document.getElementById("root"));
_$delegateEvents(["click"]);
```

The markup is one deliberately **unclosed** HTML string; `_$template` is a memoised `cloneNode`;
holes are reached by a compile-time sibling walk; **the reactive hole is passed as the accessor
itself**, so the *runtime* decides whether it needs a computation; events are one property write
plus one `delegateEvents` for the whole program. §6 has the detail.

The table's row body adds the one thing a text hole does not need — an effect, for `class`, which is
a property write needing previous-value diffing:
`_$effect(() => _$readShallow(selected() === row.id ? "danger" : ""), (_v$, _$p) => _$className(_el$3, _v$, _$p));`
**Per row: 1 template clone, 5 sibling hops, 2 inserts, 2 handler property writes, 1 effect.**
Reactive props on a component become getters — `get each() { return rows(); }` — which is the whole
"props are lazy" mechanism: one `get` per dynamic prop, no proxy.

The typeahead confirms §4.1 empirically: **`createAsync` does not exist** anywhere in `solid-js`'s or
`@solidjs/signals`'s `.d.ts` surface. The async source is a plain `createMemo(async () => …)`.

### 10.3 Bundle size

| program | raw | minified | **brotli** |
|---|---:|---:|---:|
| `sigonly` — signals only, no DOM | 75 329 | 27 017 | **9 743** |
| **`empty` — the floor**, `render(() => <div/>)` | 85 475 | 31 596 | **11 418** |
| `counter` | 96 906 | 36 051 | **12 872** |
| `table` (1 000-row keyed `<For>`) | 114 135 | 44 526 | **15 925** |
| `typeahead` (async + `Loading`) | 138 258 | 53 221 | **18 592** |

Split, from the metafile — minified bytes each package contributes **to the shipped bundle**, after
tree-shaking:

| program | `@solidjs/signals` | `@solidjs/web` | `solid-js` | app |
|---|---:|---:|---:|---:|
| `empty` | **23 792** | **7 373** | 135 | 91 |
| `counter` | 27 831 | 7 490 | 210 | 315 |
| `table` | 33 324 | 8 805 | 423 | 1 769 |
| `typeahead` | 44 110 | 7 490 | 562 | 854 |

**The reactive core dominates the DOM runtime 3:1 in every program.** In the empty app signals is
75 % of the bundle and app code is 91 bytes. The floor's top modules, minified:
`scheduler.js` 7 774, `@solidjs/web` 7 373, `core.js` 5 034, `async.js` 4 735, `owner.js` 1 624,
`heap.js` 1 124, `effect.js` 984, `lanes.js` 706, `boundaries.js` 691, `graph.js` 583.

**`scheduler.js` + `async.js` + `heap.js` + `lanes.js` — about 14 KB minified of scheduling and
async machinery — sit in the floor of an app that does nothing and has no async at all**, because
`render` reaches them and tree-shaking cannot remove them. *Solid 2's floor is the scheduler, not
the renderer.*

Marginal brotli, layer by layer: `sigonly` 9 743 (+9 743, the core alone) → `empty` 11 418 (+1 675,
the DOM runtime and `render`) → `counter` 12 872 (+1 454) → `table` 15 925 (+3 053, `<For>` plus the
app's own 1.7 KB) → `typeahead` 18 592 (+2 667). The last figure is almost all runtime, not app:
`verdict.js` 4 336, `optimistic.js` 3 534, `boundaries.js` 2 935 and `map.js` 4 153 minified bytes
appear only once `Loading`/`isPending` are used. **Touching one async boundary adds ~15 KB
minified.**

### 10.4 Per-operation timings, and the number that reframes everything

Method: `t0 = performance.now(); op(); flush(); document.body.offsetHeight; t1 = …`, 15 reps, first
5 discarded, median of 10; two processes × two passes, so four medians per op. Every median is
within ±11 % of the median-of-medians.

| op (1 000 rows unless stated) | median of medians |
|---|---:|
| create 1k / create 10k | **21.9 ms** / **229 ms** |
| replace 1k | **24.5 ms** |
| update every 10th label (100 rows) | **4.85 ms** |
| select a row | **0.20 ms** |
| swap rows 1 ↔ 998 | **1.7 ms** |
| remove one row | **1.5 ms** |
| append 1k | **25.9 ms** |
| clear 1k / clear 10k | **2.1 ms** / **29.7 ms** |

**Then the same ops with and without the forced layout read** (batch load 1.45, both passes shown):

| op | Solid + DOM mutation | + forced layout | layout's share |
|---|---:|---:|---:|
| create 1k | **3.35 / 3.35 ms** | 23.7 / 21.7 | **86 % / 85 %** |
| replace 1k | **6.32 / 6.43 ms** | 24.7 / 24.5 | 74 % |
| update every 10th | **0.14 / 0.11 ms** | 5.16 / 4.81 | **97 % / 98 %** |
| select a row | **0.27 / 0.19 ms** | 0.22 / 0.19 | ~0 % |
| swap rows | **0.155 ms** | 1.62 | 90 % |
| remove one row | **0.10 ms** | 1.53 | 93 % |
| clear 1k | **2.16 ms** | 2.18 | ~1 % |

**This is the most consequential measurement in the report.** Solid's own cost to build 1 000 rows
is **3.35 ms**; the other 18 ms is Chrome laying out a 1 000-row table. Updating 100 labels costs
Solid **0.12 ms** — 1.2 µs per changed row — against 4.7 ms of relayout. Selecting a row costs
0.19 ms and provokes no measurable layout, because two `class` attributes change and neither
reflows. `clear` is all JS disposal and no layout, because there is nothing left to lay out.

**On a real DOM the framework's share of an update is 2–15 % of the operation.** An architecture
2× slower than Solid *in its own layer* is 2–15 % slower end to end. That is the number the "as fast
as Solid" requirement has to be read against.

### 10.5 Writes are transactional — confirmed in the browser too

The first attempt at every microbenchmark measured zero, because `set()` alone does nothing
observable: `set(5); s()` → `0`; `flush(); s()` → `5`; `set(7); m()` → the *old* `50`;
`flush(); m()` → `70`. Not "the effect is deferred" — **the signal read itself returns the old
value.** Independent confirmation of §3.4's Node result, and every figure below is therefore the
cost of one *write-and-settle*.

### 10.6 Microbenchmarks that explain the internals

**A write with N subscribers is linear.** (`it` = 20 000 for N ≤ 100, 2 000 above; 50 warm-up writes
discarded; two passes `p1 / p2`; an in-graph recompute counter checks linearity structurally.)

| N | effects ns/write | ns/sub | unobserved memos ns/write | ns/sub | runs/write |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 106 / 631 | 1 106 / 631 | 1 033 / 590 | 1 033 / 590 | 1 |
| 100 | 12 896 / 14 876 | 129 / 149 | 10 523 / 12 003 | 105 / 120 | 100 |
| 1 000 | 125 735 / 142 572 | **126 / 143** | 103 205 / 113 845 | **103 / 114** | 1 000 |
| 10 000 | 1 209 133 / 1 386 138 | **121 / 139** | 954 232 / 1 077 350 | **95 / 108** | 10 000 |

Flat ns/sub from 100 to 10 000 — **~120–140 ns per effect subscriber, ~95–115 ns per memo
subscriber** — with no super-linearity, and a **fixed write-and-flush cost of ~600–1 100 ns**. And a
finding nobody expected: `runs/write` is exactly N **even for memos nobody observes**. **Solid 2's
flush eagerly recomputes unobserved memos**; reading all N afterwards costs only ~23 ns each, i.e.
they are already clean. A memo is not a lazy thunk once read; it is a scheduled node.

**A tracked read costs ~20 ns, of which ~7 ns is the dependency bookkeeping** — six independent runs
of 1 000 distinct signals summed 5 000 times gave **13.0–14.0 ns** untracked and **19.9–24.3 ns**
tracked. The ~13 ns baseline is not a property load; it is a closure call plus the observer check,
~55–65 cycles on a Zen 3.

**Creating a node costs far more than running it.** (The first attempt was GC-dominated and is
discarded; this retains every node so nothing is scalar-replaced, 8 rounds, minimum round, three
runs.) `createSignal` **20–32 ns**; `createMemo` construction **114–159 ns**, first read **16–17 ns**;
`createEffect` construction **145–165 ns**, first flush **13–15 ns**. **A memo or effect is 5–8× a
signal**, because it allocates a computation node, registers it with the owner and links it into the
scheduler. **The cost is the node, not the work** — which is what §1.1's shape engineering is about.

**Cost of one table row, split three ways** (15 reps, first 5 dropped, median; two passes):

| | graph only (1 000 signals) | full `<For>` + DOM | plain-DOM `cloneNode` baseline | framework overhead |
|---|---:|---:|---:|---:|
| pass 1 | 0.10 ms — **100 ns/row** | 21.62 ms | 19.19 ms | **2 430 ns/row** |
| pass 2 | 0.09 ms — **95 ns/row** | 21.55 ms | 19.03 ms | **2 510 ns/row** |

Per row: **~100 ns of reactive graph, ~2 400 ns of framework** (For bookkeeping, template clone,
sibling walk, owner, two inserts, one effect, two handler writes, insertion) **and ~19 000 ns of
Chrome table layout that any implementation pays.** Consistent with §10.4's 3.35 ms.

The first version of this measurement put the hand-written baseline in a `display:none` table and
got 2.5 ms, making Solid look 9× slower than hand-written DOM. That was wrong — hidden subtrees are
not laid out — and the error is recorded because the corrected number is a different conclusion
entirely: **Solid costs 13 % more than hand-written `cloneNode` for the same 1 000 rows.**

**Memory: ≈ 1 380 bytes of JS heap per row**, essentially constant from 1 k to 10 k (1 429 → 1 388;
CDP `HeapProfiler.collectGarbage` then `Runtime.getHeapUsage`, 300 ms settle, two passes each) —
covering the row object, its signal pair and node, the `<For>` mapping entry, the per-row owner, the
`class` effect node and handles to 8 DOM nodes. **Caveat: V8 JS heap only** — Blink's C++ DOM
allocation is not included, so the real footprint is higher and could not be determined here.

**Glitch-freedom holds exactly, and costs 17–20 %.** A chain of D memos against ⌊D/3⌋ stacked
diamonds at the same node count: **runs per node per write is `1` in every cell** — a naive push
propagator would run each join twice and show 1.33 — but the diamond costs 168.8/178.7 ns per node
against the chain's 144.1/141.8 at D=300, and 176.4/195.4 against 158.9/162.7 at D=30. Roughly
**25–35 ns per node**, the price of the ordering discipline, paid on the propagation path whether
the graph has a diamond in it or not. Note the absolute figure too: **~140–160 ns per node per write
to propagate**, against ~16 ns to *run* a memo body. **Propagation, not computation, is where a
Solid graph spends its time.**

### 10.7 The typeahead's stale request

Query `"a"` has a 300 ms source, `"ab"` a 10 ms source, fired 5 ms apart, so the stale request
settles 300 ms *after* the fresh one. Two passes, byte-identical:

```
     0 ms  initial                                   DOM="idle"
   5.3 ms  after type('a') then type('ab')           DOM="updating…"
  65.4 ms  the fast 'ab' has settled                 DOM="idle ab-hit-1 ab-hit-2 ab-hit-3"
 365.7 ms  the slow stale 'a' has settled            DOM="idle ab-hit-1 ab-hit-2 ab-hit-3"
          settle order                               " -> ab -> a"
```

The stale response resolves last and is discarded; the DOM never shows `a-hit-*`; `isPending` flips
to `"updating…"` during the flight and back without the `Loading` boundary re-showing its fallback.
Exactly the contract §4.3 measured in Node — **and exactly §4.5's point: the stale request ran to
completion.** First load does show the fallback: `[[0,""],[1,"Loading…"],[7,"idle"]]`.

### 10.8 Could not determine

**Per-bucket brotli** — esbuild's metafile gives byte counts per input, not ranges, so the bundle
cannot be sliced and compressed per package; §10.3's marginal ladder is the honest substitute and
the split columns are minified bytes only. **Non-JS memory per row** — see §10.6. **Rollup/Vite
numbers** — the build used esbuild plus the native compiler directly because the metafile split
required it; Rollup would tree-shake slightly differently and that was not quantified. **Anything
about Firefox, Safari or mobile.**

---

## 11. Questions for the owner

Same shape as the effects and browser sheets: the situation in plain words, an example, the options,
a recommendation. Ids are `S1…S7` so they do not collide with `W1…W24`. Nothing here is decided.

### S1. Which of the three ways of building a screen does beni use?

**The situation.** Solid is fast for two separable reasons. One is the **compiler**: it sees the
markup, so it clones a prepared template and writes directly into the places that change. The other
is the **graph**: every changing value knows which parts of the screen read it. The compiler half is
available to any design, including Elm's; the graph half comes with a programming model that has no
single model value, no list of everything that can happen to a screen, and no time-travel debugger.

**The example.** A 10 000-row table; you tick a checkbox on row 4 200. With the graph (A) the
runtime touches one place, under a microsecond. Without it (B) the runtime asks "is this row the
same object as last frame?" 10 000 times, finds the one that is not, and updates it — measured on
this machine at **9.3 µs, 0.06 % of a frame** (§5.5).

**The options.** **(A) Signals**, as Solid has them — fastest in principle, costs the four
guarantees in §9.1. **(B) One model, compiled templates, one reference comparison per hole** — keeps
every guarantee, costs a walk linear in the size of the screen at about one nanosecond per hole.
**(C) (B) plus the compiler working out which holes each field feeds**, so the walk skips what
cannot have changed — same guarantees as (B), same speed as (A), if the analysis works.

**Recommendation: (B) now, with (C) held open as a later optimisation of it, not as an
alternative.** §5.5's arithmetic says the walk does not become the bottleneck until about a million
holes per frame, one to two orders of magnitude past any page a browser can lay out in 16 ms; §10.4
says the framework's share of a real update is 2–15 % anyway; §7.7 says Solid's own `<For>` is in
the same O(n) class on this operation; and §7.8 says Solid's team measured the immutable-snapshot
shape beating their store on 96/96 uibench cases. **(C) is not a different design from (B); it is
(B) with the compiler narrowing which holes to visit**, and it can be added later without changing
a line of anybody's program. Report 29 is built to test this and should be believed over this
paragraph.

**Reversibility.** (B) → (C) is fully reversible, no user-visible change. (B) → (A) is not.

### S2. Should a beni computation keep tracking across a pause?

**The situation.** Report 25 flagged this as the one thing blocking signals: Solid installs "who is
listening" in a plain variable and puts it back when the function returns, so a function that pauses
halfway loses tracking silently. R25 proposed a fourth per-fiber slot.

**This report's finding: the problem goes away on its own** (§8.6). beni already plans to require
these functions be `sync` — the compiler has checked they contain no pause — so nothing can
interleave with them and a plain variable is correct. No fourth slot against A7's three.

What is left is smaller and optional: do we *want* Leptos's feature, a tracked computation that
waits for the network and keeps tracking afterwards?

**Options.** (a) No — tracked computations are `sync`, and fetching uses the `sync`-source /
suspending-fetcher split Solid already has. (b) Yes — one extra per-fiber slot, restored at every
resumption, which beni's scheduler can do once for every fiber.

**Recommendation: (a), revisit only if a real program asks.** It costs nothing and closes the
silent-wrong-answer hole by construction. And the split in (a) is not only a workaround: it states
in the *type* which reads are dependencies, which (b) throws away. Note Solid rejected the
transaction analogue deliberately (§4.4, axiom A26) — holding an ambient scope across a gap captures
things you did not mean to capture.

### S3. How much of a frame may "working out what changed" take?

S1 partly depends on a budget nobody has set. At ~1 ns per hole: a 0.1 ms budget allows ~107 000
holes on screen, a 1 ms budget ~1.07 million.

**Recommendation: publish 1 ms as the budget**, with report 29's measurements as the evidence that
it is met. A published number is what lets a later change be judged a regression. Fully reversible.

### S4. Should control flow inside markup be syntax, or components?

**The situation.** Solid writes conditionals and lists as *components* — `<Show when>`,
`<For each>`. Because JavaScript is eager, `For` must hand each row to the callback wrapped in a
function, so users write `item().name` and must not destructure. After eight years Solid has started
shipping an optional dialect, `.tsrx`, that adds `@if`, `@for`, `@switch` and `@try` as real syntax
and compiles them down to those components — 728 lines of desugaring (§8.5).

**Options.** (a) beni's `if`, `case` and list comprehension work inside markup directly, as language
constructs — typed, exhaustive, no accessors. (b) Copy Solid: control flow is library components.

**Recommendation: (a).** This is where the owner's instinct about built-in JSX pays off most
visibly: Solid is adding syntax from the far side to reach where beni would start. Report 28 owns
the design. Low reversibility — it is grammar.

### S5. Does beni want a recoverable error boundary, separate from the fatal-defect rule?

beni has decided a defect is fatal (A1) and that a defect in a page stops the scheduler and tears
down the mount (W2). Solid has *both*: a permanent halt when nothing catches, **and**
`createErrorBoundary(fn, fallback)` with a `reset` that re-runs everything feeding the boundary
(§9.2). The example: one dashboard panel fails to render — should the page die, or should the panel
show "something went wrong — retry"?

**Options.** (a) No boundary; a defect is fatal, and recoverable failures are `Result` values the
programmer already matches on. (b) A boundary for `Result`-shaped failures only, never catching a
defect. (c) A boundary that also catches defects — contradicts A1, out.

**Recommendation: (a) for now, revisit with a real application.** beni's exhaustive `case` already
puts the "something went wrong" branch where it happens, which is where Elm puts it. (b) costs
nothing to defer. High reversibility.

### S6. Does beni advise against wide model records?

beni emits `{ m | a = x }` as a JavaScript spread, and the cost jumps about sevenfold when a record
crosses roughly 17 fields — 30 ns to 223 ns (§5.6) — because V8's fast object-clone path gives up.
A real Elm `Model` commonly has 20–40 fields, so every `update` return would pay ~400 ns instead of
~30 ns.

**Options.** (a) Say nothing; 400 ns is 0.0025 % of a frame. (b) Document a preference for grouping
related fields into sub-records, with this measurement as the reason. (c) Have the emitter do
something cleverer (an explicit field-by-field copy is *worse*, measured).

**Recommendation: (b).** Free, true, and the kind of guidance a language gives without restricting
anybody — rule 7's shape exactly. Reopen (c) only if report 29 shows it mattering.

### S7. Are stores, proxies and `reconcile` out of scope?

6 426 of Solid's 24 312 source lines are the store: proxies for deeply nested mutable state plus
`reconcile` to fold fresh server data into it without destroying identities. **beni needs none of
it** (§5.6) — the model *is* the new data and the programmer's record update *is* the correspondence
`reconcile` has to reconstruct. Solid's own ruling agrees: *"`reconcile` is … not for ingesting
immutable snapshots (the snapshot is the diff)"* (§7.8).

**Recommendation: confirm in writing that stores, proxies and `reconcile` are out of scope**, and
record §5.5's and §7.8's evidence as the reason, so the question does not reopen every time someone
reads a Solid benchmark. A capability gap found later is filled inside the wall, like any other.
High reversibility — it is a decision not to build something.

---

## 12. Evidence index

### 12.1 Vendored sources

| repo | branch | commit | version |
|---|---|---|---|
| `references/solid` | `next` | `be46a04de7235607e83658627e82b0b3d30003d9` | `2.0.0-rc.9` |
| `references/dom-expressions` | `next` | `e97e4290ec544bdade3c368ceae156baf54fab57` | — |

`@solidjs/web` 2.0 has **absorbed** dom-expressions (`references/solid/documentation/expression-origin.md:1-20`
records the snapshot at exactly the vendored dom-expressions commit), so
`references/solid/packages/web/src/client.ts` is the shipped runtime and
`references/dom-expressions/packages/runtime/src/client.js` is the same code one step back.
`references/dom-expressions/packages/compiler` and `packages/babel-plugin-jsx` are where the
compiler lineage lives; Solid 2 ships `references/solid/packages/compiler`, a Rust/Oxc compiler.

### 12.2 The files this report reads, by section

| section | principal sources |
|---|---|
| §1 the graph | `signals/src/core/{core,graph,heap,scheduler,types,constants}.ts` |
| §2 owners | `signals/src/core/{owner,context}.ts` |
| §3 scheduling | `signals/src/core/{scheduler,effect}.ts`, `signals/src/signals.ts`, `.changeset/a28-writes-visible-at-flush.md` |
| §4 async | `signals/src/core/{async,error,lanes,optimistic,verdict,action}.ts`, `signals/src/boundaries.ts`, `signals/docs/SPEC-ASYNC-SEMANTICS.md`, `documentation/solid-2.0/05-async-data.md` |
| §5 stores | `signals/src/store/next/{store,reconcile,projection,target,optimistic}.ts`, `signals/src/store/utils.ts`, `docs/INTERNALS-STORE-STATE.md`, `tests/store/listened-paths.bench.ts` |
| §6 compiler | `packages/compiler/src/{shared/classify,shared/attr_plan,shared/component,dom/template,dom/children,dom/dynamics,dom/attrs,dom/events,dom/set_attr}.rs`, `packages/web/src/client.ts`, `packages/web/src/reconcile.ts`, both `CHANGELOG.md`s |
| §7 lists | `signals/src/map.ts`, `solid/src/client/flow.ts`, `dom-expressions/packages/runtime/src/reconcile.js`, `documentation/solid-2.0/03-control-flow.md`, `documentation/performance-experiments.md` |
| §8 JS/TS-only | `signals/src/store/utils.ts`, `solid/src/client/component.ts`, `packages/babel-plugin/src/tsrx/{index,desugar,lazy}.ts`, `signals/package.json` |
| §9 guarantees | `signals/src/core/{effect,scheduler,core}.ts`, `signals/src/boundaries.ts` |

### 12.3 Scripts and raw output

All in the scratchpad, none in the repository:
`solid-r1/sched/{s0,s2,s3}.mjs` (§3.4, §9.4 — scheduling and the production cleanup crash),
`solid-r1/compiler/` (§6 — the native-compiler fixtures, the jsdom instrumentation, the size and
throughput benches), `solid-r1/lists/{exp,exp2,exp3,exp4}.mjs` and `lists/rec/` (§7 — the
instrumented `mapArray` counters and the `reconcile.js` node stub), `solid-r1/async/{exp,exp2,exp3}.mjs`
(§4), `solid-r1/stores/` (§5 — the reference-equality walk, the proxy-trap floor, the record-update
width sweep), `solid-r1/meas/` (§10 — `build.mjs`, `split.mjs`, `ops.mjs`, `split2.mjs`,
`rowcost.mjs`, `runmicro.mjs`, `ta.mjs`, plus the CDP harness copied from `browser-r3/`).

### 12.4 Measurement conditions

One machine (AMD Ryzen 9 5950X, Linux 6.12.110), Node 24.19.0, Chrome 153.0.8010.47
`--headless=new`, pages served cross-origin-isolated so `performance.now()` ticks at 5 µs.
`uptime` load average is recorded beside every batch in §5.5, §7.5, §7.6, §10.1, §10.4 and §10.6;
idle baseline was 0.00–0.02, rising to 1.0–1.9 during the runs. Every batch was run at least twice
in separate processes and the report says where a figure reproduced and where it did not.

### 12.5 "Could not determine"

1. **No benchmark exists in either repo comparing `template()`+`cloneNode` against a `createElement`
   chain** (§6.3). The strategy's justification in-tree is one sentence, twice.
2. **Per-bucket brotli** for the bundle split — esbuild's metafile gives byte counts, not ranges
   (§10.8). The marginal ladder in §10.3 is the substitute.
3. **Non-JS memory per row** — `Runtime.getHeapUsage` excludes Blink's C++ DOM allocation, so the
   ~1 380 B/row figure is a lower bound (§10.6).
4. **Solid 1.x line counts** for a before/after size comparison — the checkout is a shallow graft of
   `next` only.
5. **No in-tree measurement** of hydration marker HTML bytes, of the browser's parse cost for the
   comment pairs, or of `getNextMarker`'s walk (§6.8).
6. **No throughput figure for the pending-status walk** — no in-tree benchmark isolates
   `notifyStatus`; §4.3 measures recompute *counts* (zero), not time.
7. **Solid's own store benches** (`commit-boundary`, `write-floor`, `listened-paths`,
   `reconcile-dbmon`, …) were not run: the pinned submodule is shallow with no `node_modules`. Their
   stated reference points are quoted from the files themselves and labelled as the repo's numbers.
8. **`Repeat`'s per-op cost** — read but not measured; no benchmark for it exists in either
   submodule (§7.4).
9. **Whether tracking across a suspension is *desirable*** in a fine-grained beni (§4.9, §8.6, S2).
   Solid rejected the transaction analogue for a stated reason; nobody has stated the read
   analogue's trade-offs, and a source read cannot settle it.
10. **Anything about Firefox, Safari or mobile.** One browser, one version, one machine.
11. **The prior art for strategy C** (§0.5's table) was **not read for this report** — the entries
    are pointers with the question to ask each, and reports 28 and 29 own the digging. The Svelte
    3/4 → Svelte 5 reversal is flagged as the single most valuable one to chase.
