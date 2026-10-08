# 58 — Compiling the framework away: what is reducible to vanilla, what is not, and what beni should do

*2026-10-08. An adversarial design review for the owner, written from first principles against the
measurements in `bench/ui/results/2026-10-08-scaling.md` and research 56/57/55. Each claim is
marked: **[measured]** from those files, **[verified]** external fact with a source, **[recollection]**
an external fact I am confident of but did not re-verify this session, **[estimate]** my reasoning.
Terms are defined where first used. Nothing here was implemented.*

*Checked by the manager, 2026-10-08:*
- *Holes page: 9 999 of 10 000 holes read paths no `update` branch writes (`bench/ui/apps/scaling/holes.mjs`). Confirmed.*
- *P2 within 6% of vanilla: 0.052 against 0.045 traced and 0.090 against 0.085 untraced, from research 56 §2.2 and §2.4. Confirmed.*
- *Signals on Solid 2's runtime measured equal in speed and 12× the bytes: research 29 P4, 22 375 against 1 808 brotli. Confirmed.*
- *Not checked: V8's 1 020-property limit, given as the cause at width 1 024. It is the reviewer's recollection; §2.4's sweep of 512, 1 000 and 1 030 fields would settle it.*
- *Not checked: the Svelte 3 microtask and Svelte's reasons for runes, both marked as recollection.*

---

## 0. The verdict in six sentences

1. "Vanilla is the floor" is the right direction and the wrong unit. Measured as script
   milliseconds on a Chrome trace at ten holes, half of the "2× vanilla" gap is harness
   instrumentation and event dispatch, not framework work **[measured, §2]**; nobody feels 0.05 ms.
2. The honest unit is **asymptotic**: a message's cost must be proportional to the DOM writes it
   implies, never to view size, model width or depth, list length or the number of live inputs —
   every curve flat where vanilla's is flat — plus **bytes per static element → 0** and a fixed
   runtime measured in hundreds of bytes, not kilobytes.
3. Solid stops short of vanilla because its unit of change is a *runtime cell* (a signal) and its
   graph is built by observing reads at run time; JavaScript gives its compiler no read set and no
   write set, and no whole program. Beni has all three. Claim 1 is right in substance and
   wrong in one detail (§3).
4. **A hand-compiled TEA page already runs within 6% of vanilla** on the small page (P2: 0.052 vs
   0.045 traced, 0.090 vs 0.085 untraced **[measured]**). That is the existence proof that TEA,
   immutability and compare-based change detection cost ~0.005 ms. beni's remaining fixed gap
   (~0.035 ms) is its own dispatch plumbing, not its model (§2.3).
5. What is genuinely not vanilla in TEA: the *where* of a collection change, controlled-input
   reconciliation, and the allocation of a new model. All three are reducible: the first two
   fully (§5), the third to the top-level record (§6.7). None needs a language change.
6. The architecture to bet on is **message-indexed rendering**: compile `update × view` per `Msg`
   constructor into a handler that runs the update branch and then only the value groups whose
   read paths intersect that constructor's statically computed write set, with list operations
   in `update` (`List.update k`, `swap`, `push`, `remove`) compiled to the row operations vanilla's
   author writes. The group stays the unit of code, the compare stays the unit of safety, the
   message becomes the unit of dispatch. Claims 2–4 survive with corrections (§6); claim 5's spike
   is the right idea with the wrong measuring stick (§9).

---

## 1. What "the framework" is, cost by cost

A UI runtime does nine things per message. For each: what vanilla does, what the vanilla author
*knows* that lets them do it, and whether the cost is intrinsic to declarative UI, to TEA, to
immutability, to beni's guarantees, or an artefact of today's implementation.

| cost | vanilla | what the author knows | intrinsic to | beni today |
|---|---|---|---|---|
| **1. event delivery** | `addEventListener` on the node; the closure holds everything | which node, which handler | the browser's dispatch (shared by all, ~0.04 ms traced **[measured]**) | delegated listener: walk up, `${key}X` strings, `try/finally`, `send` — artefact |
| **2. state transition** | `tick++` in place | nothing escapes, nobody holds the old value | immutability (copy ∝ width of each record on the path) | spread per record on the path; invisible to 256 fields **[measured]**, a V8 cliff at 1 024 (§2.4) |
| **3. change detection** | none — *the handler is the change* | "clicking go changes tick; tick is shown in #tick" | declarative UI (something must map state to DOM) | B: compare each group's read paths to what it last saw — O(groups in the root) |
| **4. scheduling** | none | — | nothing (batching is a choice) | A: render at end of trusted dispatch — now ~free |
| **5. DOM creation** | `innerHTML` / `cloneNode` | the markup | the DOM | cloned templates — parity (create 1k 4.55 vs 4.67 **[measured]**) |
| **6. DOM update** | `node.data = x` | which node | the DOM | the same write — parity |
| **7. list reconciliation** | `trs[k]`, two `insertBefore` for a swap | *which row* | not intrinsic: it is lost when a function returns a new list | keyed walk O(n); trie copy; C unmerged |
| **8. memory** | `data[]`, `trs[]`; nothing per message | — | guards cost one slot per group; instances per row | per-hole last-value, per-row instance, message objects |
| **9. guarantees** | none: inputs never reconciled, errors crash | — | beni's "page is a function of the model" | controlled inputs: O(live rows) per render **[measured: 0.24 µs/row]** |
| **10. generality** | code only for the shapes this page uses | which shapes exist | a *runtime* that handles every shape | ~1.1 KB floor; forKeyed, Show, map, delegation are all generic code |

Three observations the table forces:

**(i) The author's knowledge is the whole difference, and in TEA every piece of it is derivable.**
"Which fields never change" is the complement of `update`'s write set over all constructors. "Which
node reads which field" is B's read set. "Which row" is the index argument of `List.update` in the
update branch. "Which shapes exist" is reachability. Vanilla is what a compiler emits when it knows
these four things. Solid's compiler knows only the last; Svelte 3's knew a syntactic version of the
first two; beni's knows the second and the fourth today.

**(ii) The benchmark pages encode that knowledge on the vanilla side only.** In the holes sweep
9 999 of 10 000 holes are *constants*: `model.name`, `model.count`, `model.cls` are never written
by any `update` branch (`holes.mjs` **[measured]**). Vanilla's author put them in the HTML string —
0 bytes, 0 time. beni emits 6.1 bytes and one compare per hole, and Solid 5.3 bytes and one effect,
for values the program can never change. The 61 905-byte page is not a limit of compiled
templates; it is a missing constancy analysis. The same holds for width (1 023 of 1 024 fields
constant) and for the rows page's Solid program, which "knows where" only because the author
created a signal per row. This is the first thing to fix and the cheapest.

**(iii) The fixed per-message cost is not the model.** P2 — hand-written TEA: one spread, eleven
compares, synchronous — is 0.052 traced against vanilla's 0.045 and 0.090 against 0.085 untraced
**[measured, research 56 §2.2/§2.4]**. Everything the owner might blame (a pure `update`, an
immutable record, comparing values instead of knowing them) costs 0.005–0.007 ms on that page.

## 2. The numbers, re-read

### 2.1 What the trace charges

**[measured]** An empty `queueMicrotask` added to vanilla costs 0.051 ms in this harness (0.045 →
0.096); untraced, beni − Solid 1 was 0.02 ms where traced it was 0.05. The harness is
js-framework-benchmark's method and therefore the public scoreboard's, so the floor was worth
removing (A did), but **"2× vanilla" at 10 holes is ~0.05 ms of which perhaps 0.02 is JavaScript a
user runs**. A 60 Hz frame is 16.7 ms. No per-message constant in these tables is perceptible;
only the slopes are. Every future batch must carry research 56 §2.4's untraced mode beside the
trace, or the owner will optimise instrumentation.

### 2.2 Where beni is actually behind vanilla, in order of size

**[measured]** Live rows 10 000: 2.42 ms (50× vanilla, linear). Rows 30 000 one edit: 0.442
(7×, linear). Width 1 024: 0.377 (9×, a cliff). Depth 128: 0.306 (7×, linear, 13.8 B/level).
Table `update every 10th` 1.45 vs 0.71 and `swap` 0.97 vs 0.39 (the two "where" operations).
Holes 10 000: 0.124 vs 0.045 (flat, but 61 905 bytes vs 195). Everything else is a constant
0.04–0.06 ms above vanilla and flat — i.e. the P2 constant plus beni's plumbing.

### 2.3 The plumbing constant

**[measured]** In research 56's batch, after A, beni was 0.085, Solid 1 0.088, P2 0.052,
vanilla 0.045 — one callback each. **[estimate]** beni and Solid 1 "match" because each carries
~0.035 ms of fixed work per message for *different* reasons: Solid's is its graph and `insert`'s
generality; beni's is the delegated walk, `fire`/`send`, the `${key}X`/`${key}F` strings, the
`try/finally`, the mount loop, `model !== lastRendered`, the after-render phase and whatever else
sits between the listener and the group compares. This is not TEA. It is the cheapest gap on the
table and research 56 §6.4 left it unmeasured ("`abl-nofinally` inside the noise"). Measure it
with a 10 000-iteration in-page loop, not a trace.

### 2.4 Two points that are not what they look like

- **Width 1 024** **[recollection + estimate]**: V8 keeps at most 1 020 fast properties on a
  hidden class (`kMaxNumberOfDescriptors`); an object with 1 024 named fields is a dictionary-mode
  object, and spreading one is a slow path. The flat curve to 256 says the copy itself is
  invisible; the 1 024 point is a cliff nobody will stand on. Do not design a chunked record for
  it (research 56 §6.4 refused it; right call). Confirm by sweeping 512, 1 000, 1 030.
- **Depth 128** **[estimate]**: a path copy of 128 small records should cost ~128 × 20 ns ≈ 3 µs,
  not 260 µs, and should not cost 13.8 bytes a level. Something in how nested record update is
  emitted or how B reads a 128-deep path is quadratic or allocating. Profile before theorising;
  it is likely an artefact, and in-place update (§6.7) would make it moot either way.

## 3. Why Solid, and the others, stop short — mechanically

### 3.1 Solid 1, time

A signal write in Solid 1 goes **[verified in `references/solid`, dom-expressions]**: `setTick`
→ `writeSignal` (compare, assign, walk `observers`, mark STALE, push onto the `Updates`/`Effects`
queues) → `runUpdates` → `completeUpdates` → `runTop` → `updateComputation` → `cleanNode` (unlink
the computation from every source's `observers` array) → re-run the effect → `insertExpression`
(a `typeof` dispatch over string/number/function/array/node) → `node.data = x`. Before it, the
delegated `eventHandler` walked from the target up the tree reading `node.$$click` and
`Object.defineProperty`'d `currentTarget` onto the event. Fifteen to twenty-five calls, several
array mutations and two queue allocations per message, against vanilla's one assignment. Untraced
that is ~0.025 ms **[measured]**.

Why Solid cannot remove it: the effect's dependencies are discovered by *running* it with a global
`Listener` set, because in JavaScript a read can hide behind any call, prop, context or proxy. So
the mapping "which effects does this write touch" is a run-time data structure that must be
maintained (subscribe, unsubscribe, mark, schedule). Claim 1 is correct on this. Two corrections:

- The gap is not only the graph. `insert` and `For` are **generic**: `insertExpression` handles
  every value kind at every hole; `For`'s `mapArray` diffs a whole new array by identity on
  `setRows(list)` — which is why swap at 30 000 costs 5.38 ms **[measured]**: the author had the
  two indices and the API made them hand over a new array. "Where" was lost at the API, not at the
  compiler.
- Solid *could* fold `const [name] = createSignal("beni")` whose setter is never used into a
  constant, in principle; it doesn't because its compiler is a per-file JSX transform, not whole
  program. The missing ingredient in the holes sweep is whole-program constancy, not purity.

### 3.2 Solid 1, bytes

**[measured]** 2 948 bytes at 10 holes, 5.3 per hole after. The floor is the reactive core
(signals, computations, owners, cleanup, batching, transition stubs) plus dom-expressions'
runtime (template, insert, delegation, spread, class/style helpers). It is the price of handling
every shape at run time with code written once; vanilla pays only for the shapes on the page.
beni's floor is already 1 131–1 372 bytes because reachability elimination keeps only the shapes
a build uses — that is the right mechanism, and it should go further (§7).

### 3.3 Svelte 3/4 — what actually failed

Claim 1 says Svelte "tried static analysis and abandoned it because it was unsound across function
calls". Half right. **[verified, research 56 §6.5's quotes from svelte.dev]** The *read* side —
which `$:` statement depends on which variable — was syntactic, broke through function boundaries,
was top-level only, and had ordering ties. The *write* side — `$$invalidate` injected at every
assignment in the component, a per-component 31-bit dirty mask, `p(ctx, dirty)` guarding each DOM
write — was essentially a write-set analysis, and its hole was **aliased mutation**: `obj.x = 1`
inside a helper in another file invalidates nothing. Beni has no mutation and no aliasing a program
can see, so that hole does not exist; and B's read side compares rather than trusts, so the other
hole becomes a re-evaluation instead of a stale screen (research 56 §6.5's verdict, which I
accept). Two more facts about Svelte 3 the claim omits **[recollection]**: it flushed in a
microtask (`schedule_update` → `Promise.resolve().then(flush)`) — the same floor A removed — and
its propagation was a top-down walk of every component whose mask was non-zero, coarser than
Solid's per-binding effect. Svelte moved to runes for refactorability and TypeScript, by its own
account, not because the bitmask was slow. The lesson for beni is narrow: *never decide "unchanged"
from analysis alone; decide "possibly changed" from analysis and "changed" from a compare.*

### 3.4 The others, one line each (which failure applies to beni in brackets)

**[recollection unless marked]**
- **Elm**: vdom, diff O(view) per render by design, `Html.lazy` manual; chose simplicity and
  guarantees over speed; roughly 1.6–2.2× vanilla on js-framework-benchmark. [beni's fallback
  path is the same shape — "compare everything" — at hole granularity; it must stay the fallback,
  never the common case.]
- **Imba**: memoised DOM, per-expression compare, no vdom — B before groups; but `imba.commit` after
  every handler re-walks the whole render tree checking memos: O(view) per event. [exactly
  beni-before-B; already past.]
- **Inferno / ivi / blockdom**: the fastest vdoms — monomorphic vnodes and flags, templates split
  static/dynamic; 1.05–1.2× vanilla on the table; the diff and per-row vnode allocation are the
  floor. Reached "near vanilla on benchmarks"; the vnode layer remains in real apps.
- **Million.js**: static/dynamic block split over React; "up to 70%" on micro-benchmarks, user
  impact disputed by its own maintainer **[verified, research 57]**; React's reconciler still
  surrounds it. [the risk that static-hole elimination wins the holes sweep and little else — §8.]
- **Vue Vapor**: template compiler to direct DOM over `@vue/reactivity`'s runtime effects — Solid's
  architecture without JSX; by construction it lands on Solid's floor.
- **Marko 6**: "targeted compilation" — proves per expression what *can* change from component
  inputs and emits per-binding code with no run-time dependency tracking; the closest shipped
  system to "compile the framework away"; still a runtime scheduler, and change detection at the
  component-input boundary is runtime. Performance claims self-reported **[research 57]**.
- **Svelte 5 / Preact Signals / Angular signals**: runtime graphs; Solid's floor.
- **Mint**: Elm-like language over a Preact-style vdom; never aimed at vanilla.
- **React Compiler**: decides what *not* to recompute; the fiber diff still runs **[verified,
  research 57]**.
- **Jane Street Incremental / Adapton / SAC**: runtime dependency graphs with a ~30 ns per-node
  floor **[verified, research 57]**; Solid's floor with better theory. **ILC** (static program
  derivatives) is the compile-time cousin and the formal name for what §6 proposes; it has no UI
  application on record.

**Distinguish:** Inferno/ivi/blockdom/Solid *reached ~1.1× vanilla on the table benchmark* by
making a runtime step cheap; none *removed* the step. Svelte 3 and Marko tried to remove it at
compile time; Svelte retreated for DX, Marko persists. Elm, Mint, Vue chose not to. Nobody has
had a pure, whole-program, closed-transition-set language to do it from — which is the one thing
claim 2 gets right.

## 4. The theoretical floor for a TEA program

Define: a **hole** is one dynamic position in a template (a text node, an attribute, a list
slot); a **read set** is the model paths a hole's expression reads (B has it, over-approximated
to "the whole local" when unsure); a **write set** is the model paths an `update` branch may
write; a **group** is the holes sharing a read set.

**Known at compile time** (whole program, pure, no aliasing):
- W1. Per `Msg` constructor, the write set as a set of *symbolic paths*: `tick`; `rows[k].label`
  with `k` a run-time value; `rows ← swap(i, j)`; `rows ← push(x)`; `child.*` through a nested
  update; `*` when the branch calls something the compiler cannot summarise (`foreign`, evidence
  through a `where` clause not specialised away, a recursion it will not summarise).
- W2. Per path, whether *any* constructor writes it. Never written → the hole is **mount-only**;
  if `init` gives it a literal → **baked into the template** (0 bytes beyond the HTML).
- W3. Per constructor, the groups whose read sets intersect its write set.
- W4. Whether a value of the model's type (or of the type at a written path) can be held anywhere
  but the single `model` — the condition for in-place update (§6.7).

**Known only at run time**, and what vanilla does about each:
- R1. Which branch inside the update branch ran, hence whether the written value differs
  (`if x then {m | a = 1} else m`). Vanilla branches on the same data. Cheapest step: one `!==`
  against the last-written value — ~1 ns, and it also lets the compiler skip reasoning about
  whether `tick + 1 ≠ tick`.
- R2. The index `k`. Vanilla has `trs[k]`. Cheapest step: the handler computes `k` (it must, to
  run `update`) and patches instance `k` — O(1) — provided the list's instances are indexable by
  position and this message did no reorder (W1 says).
- R3. A reorder: `swap i j` → two `insertBefore`; `sort` → O(n). Vanilla pays O(n) for a sort too.
- R4. User drift in controlled inputs: known from the `input` event the runtime itself handles.
  Cheapest step: a dirty set, O(touched).
- R5. Messages from fibers, timers and subscriptions: the same handlers.

So **the floor for a TEA program is vanilla + (allocation of the new model unless in place) +
(one compare per affected hole) + (an instance-array index per list write).** Everything else in
today's per-message cost — the view-size, list-length, width, depth and live-row slopes, the
generic keyed walk, the message object, the `case` in `update`, the compares of groups a
constructor cannot touch — is reducible with W1–W4. Vanilla itself keeps R1–R3: it branches on
data and indexes arrays. The line between the two sides is exactly where the vanilla author also
has to write an `if` or a `[k]`.

What is **irreducible relative to vanilla** and should be accepted: the model allocation where W4
fails (undo stacks, snapshots in `Cmd`s), ~20–50 ns per small record **[estimate]**; one compare
per affected hole; a few hundred bytes of runtime for mount, delegation inside rows, and keyed
reconciliation where W1 is `*` on a list; one retained slot per group for the compare.

## 5. The three costs claim 4 names — each reducible

**(a) "Collections lose the where."** Only when `update` hides it. `List.update rows k f` carries
`k` in plain sight: W1 = `rows[k] ← f(rows[k])`, with `f`'s own write set `label`; the handler
patches row `k`'s `label` group. `swap`, `push`, `remove k`, `set k`, `[ …xs, x ]`, `[]`,
`List.initialize` are likewise an **edit script the compiler reads off the update branch** — which
is what vanilla's author writes by hand (`rows.mjs`'s swap is two `insertBefore` and two array
writes; the compiled handler is the same six lines). The idiom that *does* lose it is
`List.map (λr → if r.id == id then {r | …} else r) rows`: W1 = `rows[*].label`, order and length
kept. For that: (1) `List.map` over a trie must **preserve node identity** when every leaf of a
node is `===` its old leaf — a compare per element, so a map that changes one row shares all but
one path; then (2) slice C's `$diff` finds the changed positions in O(changes · log₃₂ n). With
both, the Elm idiom costs what `List.update` costs. Without identity-preserving `map`, C does
nothing for the idiom. (Also note `List.filter (.id ≠ id)` is a length change: W1 = "some removed,
order kept" — a one-pass merge, O(n) compares at ~10 ns each, 0.3 ms at 30 000; vanilla's remove
is O(1) because the author has the row. To match it the compiler must see `filter` with a
predicate on a key it can resolve to one row — a pattern worth recognising, not a general
mechanism.)

**(b) "Immutability allocates."** True; invisible to 256 fields and a V8 cliff at 1 024 (§2.4).
With message-indexed rendering the renderer no longer needs the old model (it keeps leaf values
per group, as B already does), which removes research 55's named blocker; the remaining condition
is W4. Worth doing for the top-level `Model` record (almost always provably unique: it appears
only as `update`'s result and `view`'s argument) and deferring for inner types. The byte win is
real too: a nested path write is `m.a.b.c = v` (2 bytes a level) where a path copy is a spread
per level (~10). Order it after (a) and (c).

**(c) "Controlled inputs cost a visit per live row."** Not intrinsic to the guarantee — intrinsic to
implementing it by visiting. The only way an input's DOM value can differ from the model's is a
user edit the runtime itself saw (the `input` event that produced the message) or a browser action
(`autofill`, which fires `input`; a form `reset`, which does not). Keep a **dirty set**: the
delegated input listener marks the node before it sends; after the flush, reconcile dirty nodes
against the model and clear. Model-driven changes to the value go through the group compare as any
hole does. Cost O(touched + changed), which is vanilla's — vanilla pays zero because it never
promises anything. Handle `reset` by marking the form's inputs dirty. This is the single largest
measured loss (22× Solid, 50× vanilla at 10 000) and needs no analysis at all.

**(d) "Generic helpers make the write set everything."** Too pessimistic. The compiler is whole
program: a helper in another module has a summary like a helper in this one. What truly blocks a
summary is `foreign` (only core and platforms), a call through `where`-clause evidence the release
specialiser did not resolve, and a recursion the analysis declines to summarise. The honest limit
is "the write set is `*` for the receiver of an unsummarised call", and then the handler runs every
group — today's cost, not a regression. On real programs the question is *how often* W1 is
bounded; §9's feasibility spike answers it before anything is built.

## 6. Claims 2–4 and the alternatives

**Claim 2 (beni can go further because the facts are provable).** Correct, and incomplete in the
way that matters: *provable facts buy nothing until the emitted shape changes*. B proved read sets
and still compares every group of a root on every message because nothing tells it which groups
can have changed. The three facts beni lacks are W1 (write sets), W2 (constancy) and W4 (escape),
and the shape change is per-constructor dispatch. Without the shape change, W1 is an optimisation
of a compare that already costs 1 ns.

**Claim 3 (TEA is the best starting point because transitions are closed).** Agreed, with the
example corrected: `onClick={Inc}` becomes `m = {...m, count: m.count + 1}; if (m.count !== g0)
countText.data = g0 = m.count` — vanilla plus a spread and a compare — and only becomes `count++;
countText.data = count` under W4. And the thing TEA gives that no signal framework has is the
other half: **the handler knows its message**. Solid's handler knows a signal; the signal's
consumers are discovered at run time. A per-constructor handler is the closed-world dual of a
signal graph: the edges are computed once, by the compiler, from W1 ∩ read sets. This is also the
answer to "the view as an incremental function of messages": it is ILC restricted to record paths
and list positions, with "recompute and compare" as the derivative of everything else (sorts,
filters, arbitrary projections) — which is what Incremental and Solid's `createMemo` do at run
time and B already does statically (derived 100 000 is flat **[measured]**).

**Where TEA genuinely hinders**, honestly: (1) `update` returns a value, so any idiom that rebuilds
a collection rather than editing it needs identity preservation and a diff — a cost the signal
API avoids only by making the author pre-declare granularity (a signal per row); (2) the model is
one tree, so a message that writes a widely read path (`SetLocale`) runs most groups — vanilla's
author would write the same loop; (3) batching: beni's end-of-dispatch render wins bursts of
30–1 000 messages by 30% over Solid **[measured]** because it renders once; per-constructor handlers
that write the DOM directly give that up unless they stage group runs until the dispatch ends (keep
the staging: the handler marks groups and rows, the flush runs them once — that preserves the burst
win and costs one bit per group).

**Alternatives, judged by what each buys toward vanilla:**

| alternative | buys | costs | tried? | verdict |
|---|---|---|---|---|
| per-constructor specialised handlers + write sets | removes every slope but sort/filter; removes the message object and the `case`; makes static holes free | code per (constructor, group) pair; an analysis pass | Marko 6 at component granularity; Svelte 3's `$$invalidate` at variable granularity; never per message of a pure update | **build** |
| incremental computation as the architecture (Incremental/Adapton) | derived views incremental on *related* changes | a runtime graph: Solid's floor, 30 ns/node, bytes | Jane Street, in OCaml | a library at most (rule 7); not the architecture |
| signals/stores as a language feature | nothing toward vanilla; measured equal to Solid 2 at 12× the bytes (research 29 P4 **[measured]**) | immutability, closed transitions, the write set | everyone | reject |
| components with local state | ergonomics | nothing for speed; the same analysis per component | everyone | orthogonal; not now |
| lenses/optics in syntax | explicit paths | nothing the compiler cannot already read from record update syntax | Haskell/PureScript libraries | unnecessary |
| `update` returns a patch/diff type | the write set as a run-time value | allocation + interpretation per message; un-Elm; strictly dominated by computing the same patch at compile time | Immer's `produceWithPatches` | reject as surface; it is the *internal* IR of the handler |
| mutable store with uniqueness / FBIP | removes the copy and the path-copy bytes | needs W4; JS has no refcount, so proof only (research 55) | Koka, Lean, Roc, Clean, Futhark; never with a UI | type-directed, top-level `Model` first; slice 4 |
| view as an incremental function of messages (ILC) | the same as row 1, in theory's clothes | derivatives of sort/filter do not exist cheaply | academic, no UI | row 1 is the practical ILC |

## 7. Bundle size

**Why per-element code exists.** A compiled template must, per dynamic hole, (1) reach the node
(a `firstChild.nextSibling…` chain or an index into a one-time walk) and (2) write it. That is 4–6
bytes after brotli for beni and Solid alike **[measured: 6.1 vs 5.3]**, and it is the floor for a
*dynamic* hole: P2's `h[i]` indexing and dom-expressions' chains land in the same range. Vanilla
pays ~0 in the sweeps because its holes are **static**, and it pays the HTML string, which brotli
reduces to nothing when generated and repetitive. Real pages are heterogeneous, so everyone's bytes
per hole are higher there and the sweeps overstate every subject's compression.

**The size floor for compiled templates** is therefore: the HTML (shared with vanilla) + ~5 bytes
per *dynamic* hole + the runtime the page reaches. The lever is not a smaller per-hole encoding;
it is **classifying holes** so that most are not dynamic: W2 makes never-written holes mount-only
(a write at mount, no guard, no group) and literal-`init` holes part of the HTML. On the holes page
that is 61 905 → ~1 300 bytes **[estimate]**; on a real page, Solid's own argument applies — most
of a view is static — and the saving is the fraction of holes that read never-written paths
(labels from `init`, configuration, flags).

**Where 16 bytes per model field and 13.8 per level come from** **[estimate]**: the `init` literal
(vanilla pays it too, ~1.5 B/field), the hole (6), and for depth the spread per level in `update`
(~10) plus the path in the view. In-place update and W2 attack both.

**Do speed and size pull apart?** Per-constructor handlers can multiply code: |constructors| ×
|affected groups|. They need not: the group function is emitted **once** and a handler is a list of
group calls — ~2–4 bytes per (constructor, group) pair — and a constructor whose write set is `*`
calls the root's full patch, which exists anyway. Inline a group into a handler only when it has
one caller. Net, the handler *replaces* bytes: the message constructor, the `case` arm in `update`
and the generic root `p` all go. The rule for the compiler: **outline by default, inline on single
use, and measure the table app's bytes on every slice** — the `--release` build's 5 510 bytes
against vanilla's 1 415 is the number to move, with ~2 500–3 000 a realistic landing **[estimate]**:
a program whose every list message is a recognised edit (the table app's are: replace, update
every 10th, select, swap, remove, append, clear) does not reach the generic keyed reconciler at
all, and reachability drops it.

## 8. Which failure modes apply to beni

1. **O(view) fallback** (Elm, Imba): present today as the generic root patch; under
   message-indexed rendering it becomes the `*` case only. Keep it, measure how often real
   programs hit it (§9 S2).
2. **Stale screen from analysis** (Svelte 3): avoided by the standing rule — analysis says
   "possibly changed", a compare says "changed". Every handler must be differentially tested
   against a full render.
3. **Code growth from specialisation**: real; bounded by outlining; gated by the bytes line.
4. **Benchmark-shaped wins** (Million): constancy elimination wins the holes and width sweeps by
   100× and may win a real page by 20%. The table app, the TEA corpus pages and the static page are
   the honest yardsticks; the sweeps are instruments.
5. **A guarantee implemented by brute force** (live rows): the dirty set fixes this one; the
   general lesson is that a guarantee's cost must be charged to the event that endangers it.
6. **Measuring the harness**: the per-callback 0.05 ms nearly sent research 56 after the wrong
   target; untraced numbers beside traced ones from now on.

## 9. The verdict, and the direction

**Is "as close as possible to vanilla" the right goal?** As a direction, yes; as a per-message
millisecond target, no. Restate it as three measurable properties: (1) **flat curves** — on every
sweep where vanilla is flat beni is flat, and its constant is within 1.15× vanilla untraced
(P2 is 1.06× today); (2) **bytes**: marginal bytes per static element 0, per dynamic hole ≤ 6, the
table app ≤ 2× vanilla (≈ 2 800), the empty page ≤ 1 KB; (3) **the table**: within 1.2× vanilla on
all nine operations (today 1.0–1.15 on seven, 2.0–2.5 on the two "where" operations). Memory: one
slot per group and one instance per row, documented and not pursued further.

**Where beni can land** **[estimate]**: scalar messages 1.05–1.15× vanilla untraced once the
plumbing constant is found; list edits through `List.update`/`swap`/`push` equal to vanilla; the
`map`-idiom edit 1.2–1.5× (identity-preserving map + `$diff`); live rows flat at the scalar
constant; the table's `update every 10th` ~0.8–0.9 ms (1 000 compares plus 100 writes; vanilla
0.71) and `swap` ~0.45 (vanilla 0.39); width and depth flat to the V8 cliff. Bytes as above.

**What beni should NOT try**: signals or stores in the language; a runtime incremental graph as the
architecture; a patch type in `update`'s signature; chunked records for 1 024 fields; vanilla's
byte count on a page with lists (the generic reconciler is a few hundred bytes vanilla's author
writes by hand per page); and chasing traced constants below ~0.05 ms.

**The architecture: message-indexed rendering.** For each `Msg` constructor `C` with payload
`p₁…pₙ`, emit `C(p₁…pₙ)`: run the update branch; apply its list edit script to the affected
`For` instances; mark the groups in W3(C) (and the row groups the edit script names); the flush at
end of dispatch runs marked groups, which compare and write; reconcile the dirty inputs. A
constructor whose write set contains `*` marks everything. Holes on never-written paths are
mount-only; literal ones are template text. Development and release emit the same handlers (the
only observable is `Debug.log` order, already relaxed by `language.md` §11.11).

**Order of work**, each slice specified first, with fixtures that fail before it and the harness
traced *and* untraced after it:

0. **The plumbing constant** (days): an in-page loop profile of the dispatch path at 10 holes;
   find the 0.035 ms above P2. No design change; likely the biggest ratio win per hour.
1. **Dirty-set controlled inputs** (small; runtime only): kills the 22× line. Fixtures: typed and
   rejected, typed and accepted, autofill, form reset, a row removed while dirty.
2. **Constancy (W2)**: never-written paths mount-only, literal-`init` paths baked. Compiler pass +
   lowering; `emit/dom/` shapes change (smaller). This is where the holes and width bytes go.
3. **Write sets (W1) and per-constructor handlers (W3)**, with the group as the unit of code,
   outlined, and the `*` fallback = today's patch. Differential fixture: every corpus page, every
   step, specialised against `--no-specialise`.
4. **List edit scripts** from the update branch (`update k`, `set k`, `swap`, `push`, `remove k`,
   `[]`, `initialize`), then identity-preserving `List.map` + slice C for the `map` idiom.
5. **In-place update (W4)** for the top-level `Model` when its type is provably unique; later, inner
   types. Only after 3, because only then does the renderer hold no model.

**The spike (claim 5, amended).** Hand-writing the "ideal beni output" is right, with three
conditions: (i) it must be the output the *architecture above* would emit — groups outlined,
handlers per constructor, static holes elided, a dirty set, edit scripts — not the best JavaScript
a person can write for the page, or it measures the author again; (ii) it must be measured
untraced as well as traced, beside vanilla, P2, beni and Solid 1, on holes 10/10 000, rows
30 000 (edit and swap), live rows 10 000, depth 128, and the table app, with bytes; (iii) a
second, compiler-side feasibility spike must run first or in parallel: a read-only prototype of W1
and W2 over `tests/corpus/browser/tea/` and the table app, reporting per constructor whether its
write set is exact / indexed / structural / `*`, and per hole whether it is static. **Kill
criteria**: if the hand-written P3 is not within 1.15× vanilla untraced on the flat sweeps and
within 1.3× on the list sweeps, or the table app's P3 bytes exceed 2× vanilla, the architecture
does not pay and the right goal is "flat at Solid's constant", which B nearly gives; if fewer than
roughly two thirds of the corpus pages' constructors have a bounded write set, the win is a
benchmark win (Million's) and slices 3–4 should be cut to constancy and the dirty set.

**Risks**: analysis cost against the 250k LOC/s budget (W1/W2 are linear summaries; W4 is a
type-occurrence scan — all cheap, but a whole-program fixpoint over nested updates must be bounded
like the 64-constraint cap); correctness of edit scripts on tries (property tests against a
full keyed render, as C's plan already says); the burst win if handlers write the DOM directly
(keep staging); and the familiar one — an agent who, finding a page where W1 is `*`, "fixes" it by
restricting what `update` may call. Rule 7 forbids that: the `*` case is a cost, never an error.
