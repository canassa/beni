# 72 — Bonsai: what Jane Street's incremental UI framework does that beni could use

*2026-10-11. A research report for the owner's question: is Jane Street's Bonsai (OCaml, compiled
to JavaScript by js_of_ocaml; the successor of `incr_dom`; built on the `Incremental` library)
doing anything novel, unusual or "crazy" that beni could use for speed, size or the programming
model? Research 57 covered Bonsai in one paragraph; this goes to the source. Read from shallow
clones taken today: `janestreet/bonsai` at `f316614`, `bonsai_web` at `989c18b`, `incremental` at
`98b5750`, `incr_map` at `21c6bc6`, `virtual_dom` at `4e9549c`, and Base's `map.ml` on `master`.
Claims are marked **[source]** (read in that code, file named), **[doc]** (Jane Street's own
documentation or posts), **[reported]** (a practitioner, linked), **[estimate]** (my reasoning).
Nothing was measured for this report: **no published measurement of Bonsai's speed or size
was found**; the one outside measurement of the family is js-framework-benchmark's entry for its
predecessor `incr_dom`, which is not idiomatic (§5). Jane Street's own speed claims come without
a method and are marked as such. Nothing here was implemented.*

---

## 0. The answer in seven points

1. **Bonsai is not a compiler, and its graph is not analysed ahead of time in beni's sense.** It
   builds a static dependency graph *when the program starts*, runs two small optimisation passes
   over it (constant folding, and lowering a stateless per-key body to one diff-driven map node),
   then hands it to `Incremental`, a run-time dependency graph that recomputes nodes in height
   order and stops at physical equality; the page is still a **virtual DOM diffed from the root
   every frame** (§1, §2). beni's write sets know, at compile time, what each message writes;
   Bonsai never knows that, only what each node reads.
2. **The one trick beni does not have and could use is `Map.symmetric_diff`**: diffing two
   persistent balanced trees by walking both and skipping every subtree the two share by identity,
   so the diff costs O(k log n) for k changed keys, not O(n) (§3.1). It answers `write-sets.md`'s
   open choice **O3** (a `Dict` has no positions; any write is a whole-value write) at run time,
   with no analysis: **adapt** it as the edit script for a list whose rows come from a `Dict`,
   where the dictionary itself is the key map. It does **not** carry over to `List`, and is
   incompatible with the ownership thesis's in-place arrays, which destroy the old value it needs.
3. **Bonsai's answer to local state is the most useful idea for the programming model** (§4): a
   component declares its own state where it is used, and the framework *derives* the one global,
   immutable model and the one action type from the program's static structure — the model is a
   tree shaped like the component graph, an action is a path into it. That keeps every guarantee
   TEA's single model buys and removes the boilerplate that, by the diary's own reading of
   practitioners, attaches to `Msg`. **Adapt** it as a compile-time desugaring, which beni can do
   and Bonsai has to do at start-up; write sets would see straight through it.
4. **Incremental folds over a collection** (`Incr_map.unordered_fold` with `add` and `remove`,
   §3.3) make "items left" in a 10 000-item list cost O(changes) per message. beni can get the
   same from the edit tags it already has, without a diff: **adapt**, low priority.
5. **The arrow-shaped API — no `bind` — is the part that cost Jane Street most** (arrows, then
   model-less components, then `Proc`, then `Cont`, from 2019 to 2023, §6.1) and buys them a
   static graph that beni already has by being a compiler over the whole program. Nothing to take, except the confirmation that the restriction is what
   makes the analysis possible: a `view` that may build new components from run-time data is
   what beni must keep inside `For`, `Show` and `case`.
6. **Reject the runtime**: Incremental's per-node graph (a heap by height, a cutoff per node,
   observers, a stabilisation per frame, plus re-stabilising before some actions), its
   per-frame virtual DOM diff, and Bonsai's state that outlives an inactive branch. Each is a
   cost beni's compiled design does not pay, and the Bonsai docs themselves warn against
   "over-incrementalizing" and against `assoc` on large maps (§5, §6).
7. **Worth a spike**: a `For` over a `Dict` (or `Dict.values`) rendered by symmetric diff with no
   reconciler and no key map, measured on the table app's operations against today's reconciler
   (§8). It is the only idea here that could move research 70's miss — the general reconciler,
   715 B — and it applies only to programs that keep rows in a dictionary.

---

## 1. What Bonsai is, layer by layer

| layer | what it is | where |
|---|---|---|
| `Incremental` | a self-adjusting computation library: nodes, variables, `map`/`bind`, observers, `stabilize ()` | `incremental/src/incremental_intf.ml` |
| `Incr_map` | ~60 functions on `Map.t Incr.t` (`mapi`, `filter_mapi`, `unordered_fold`, `rank`, `subrange`, `merge`, `collate`) whose work is proportional to the change in the input map | `incr_map/src/incr_map_intf.ml` |
| `bonsai` | a static computation graph of `Computation.t` (structure, state) over `Value.t` (wrapped `Incr.t`), compiled into one `Incr.t` at start-up | `bonsai/src/` |
| `bonsai_web` | the browser driver: a `requestAnimationFrame` loop that applies queued actions, stabilises, diffs and patches a virtual DOM | `bonsai_web/web/driver.ml`, `docs/how_to/bonsai_runtime.md` |
| `virtual_dom` | OCaml bindings over Matt-Esch's `virtual-dom` JavaScript library, plus widgets and hooks | `virtual_dom/lib/virtualdom.js`, `src/` |

**The run-time loop, per frame** [doc, `bonsai_runtime.md`]: flush the clock; apply every queued
action, **running a stabilisation before any action of a `state_machine1`** (a state machine
whose transition reads a derived input, which must be fresh); stabilise to get the new
`Vdom.Node.t`; run `before_display` effects and repeat until none are new; diff the new virtual
DOM against the previous one and patch; run lifecycle effects. One frame batches every action
queued since the last.

**Stabilisation** [source, `incremental_intf.ml` lines 110–140]: "`stabilize` traverses the DAG in
topological order starting at variables that changed … using a 'recompute heap' to visit the
nodes in non-decreasing order of 'height' … if the node's value changes, then add its parents to
the heap", and "by default, a node is considered to change if its new value is not `phys_equal`
to the previous value". Heights are bounded (128 by default in Incremental, 1 024 in Bonsai per
`best_practices_pitfalls.md`) because the heap is an array indexed by height. Only *necessary*
nodes — those with a path to an observer — are computed.

**What this is, in beni's terms.** Incremental is a run-time dependency graph that knows each
node's *reads* (its children) and finds what to recompute by pushing from the variables that
changed. A Bonsai app has exactly one variable that matters, the whole-app model
(`how_bonsai_works.md`: "a single variable tracking the state of our whole web UI"), so every
action marks that variable changed and propagation narrows by physical equality as it climbs:
a node reading `model.a.b` recomputes its projection, finds the same object and stops. This is
beni's `browser` platform's "compare each group's read paths to what it last saw" (research 58
§1, cost 3) done as a graph instead of a flat pass, and it is the *same* information: reads plus
identity. **It is not write sets.** No part of Bonsai knows what an action writes.

---

## 2. Static structure (question 1)

**What Bonsai does.** A Bonsai program is a function `local_ graph -> Vdom.Node.t Bonsai.t`. At
start-up it is *run once* to build a `Computation.t` — a tree of `Sub` (bind a computation's
result to a name and continue), `Leaf0`/`Leaf1` (state machines), `Assoc` (one copy of a
sub-computation per key of a map), `Switch` (`match%sub`), `Store`/`Fetch` (dynamic scope),
`Lifecycle`, `Path`, `Return` (a value) [source, `private_base/computation.ml`;
doc, `how_bonsai_works.md`]. "Before Bonsai boots up your web UI, it performs a compilation
pass" [doc]: the pass gathers a metadata tree (the shape of the model, of actions, of reset
functions), then a second pass threads `Incr.t` accessors down to every leaf. After that, "there
aren't any `Computation.t`s left to build! It's all just one big `Incr.t`!"

**The optimisations, all of them** [source]: `pre_process.ml` is one line,
`let pre_process = Constant_fold.constant_fold`. Constant folding (630 lines) evaluates
`Return`s of constants, collapses a `Switch` on a constant to its arm, and **unrolls an `Assoc`
over a constant map of at most 20 keys** (`assoc_max_input_size_to_fold = 20`; the comment: past
that "stack overflow on startup … It's cheaper to maintain one 1,000-input assoc around a
`Bonsai.state` than 1,000 separate `Bonsai.state`s"). `simplify.ml` recognises an `Assoc` whose
body is a pure function of key and data — no state, no lifecycle, no `match%sub` — and replaces
it with `Assoc_simple`, which is one `Incr_map.mapi` node (`private_gather/gather_assoc_simple.ml`)
instead of a sub-graph per key. That is the whole optimiser.

**Why the graph must be static** [doc, `thinking_in_bonsai.md`, *Why does `Bonsai.t` not have a
`bind`*]: a `bind` "would allow Bonsai nodes to conditionally create other Bonsai nodes,
effectively making the graph structure modifiable at runtime", which would prevent "optimizing
and condensing the Bonsai graph … which saves a lot of memory", and "dynamism is fairly slow in
Incremental". An earlier revision of the docs (`docs/advanced/why_no_bind.md`) adds a third reason: with
`bind`, state in a branch that is switched away from would be lost. Ty Overby (*Signals &
Threads*, 2021) gives the same account: the static invariant "lets us … do … constant folding or
collapsing multiple nodes into one … pick the one [algorithm] that is the most optimal for that
particular node", and the pass "happens exactly once".
Conditional and repeated structure is expressed by `match%sub` and `assoc`, which
*toggle* parts of a fixed graph rather than create them. `match%sub` builds **every** arm at
start-up; for large apps that cost forced an escape hatch, `match%sub [%lazy]`, which defers an
arm's construction until first use [doc, `ppx_bonsai/readme.md`: "traverses all of the branches
in the match when it constructs the graph. For graphs with giant `match%sub` branches, this can
be expensive"].

**What it buys** [doc + estimate]: memory (fewer nodes, the stated reason), instrumentation
(the graph can be printed, `to_dot.ml`, and watched, `enable_computation_watcher.ml`), automatic
composition of state (§4), and a test driver that runs the same graph without a browser (§6.5).
It does **not** buy a skipped diff: the virtual DOM is still diffed from the root each frame,
skipping only subtrees that are `===` (`virtual_dom/lib/vendor/vtree/diff.js` line 21,
`if (a === b)`), and Bonsai's own guide says the vdom's list diff "is naive: it just compares
elements at corresponding indices" (`best_practices_pitfalls.md`, *List performance in Vdom*).

**Against beni.** beni's static structure is the program text, known to the compiler with no
start-up pass; `browser-direct`'s write sets (`write-sets.md`) add the half Bonsai never has —
what each message *writes* — and turn it into per-message code with no graph, no heap and no
diff at run time (`browser-direct.md` §0). Bonsai's two optimisations have beni analogues
already: constant folding is §5.1's baking of values the program never changes into template
text; `Assoc_simple` is the observation that a row with no state needs no per-row machinery,
which `browser-direct.md` §6.1 takes further (a row is a cloned template and a few slots).
**Verdict: nothing to adopt; beni is past this point.** What Bonsai confirms is the premise: the
restriction that makes structure static (no `bind`; structure only through `match`, `assoc`) is
the same one beni keeps by allowing markup to vary only through `case`, `Show` and `For`.
Bonsai's `[%lazy]` is a warning for beni: everything that is built eagerly per branch at start-up
grows with the app. beni's `browser-direct` mounts an arm only when it is shown and keeps no
nodes for an arm that is not (`browser-direct.md` §5.5), which is the right side of that line.

---

## 3. Incremental collections (question 2)

### 3.1 `Map.symmetric_diff` and why it is fast

`Incr_map`'s whole design rests on one function in Base [source, `base/src/map.ml`,
`fold_symmetric_diff` and `Enum.drop_phys_equal_prefix`]. Given the previous and current value of
a persistent balanced binary tree, it walks both: if two subtrees are `phys_equal`, it skips them
whole; if two nodes have the same key, it recurses left, compares the data with a supplied
`data_equal` (by default physical equality), and recurses right; if the roots differ in shape
(a rebalance moved them) it falls back to an enumeration that still drops every physically equal
prefix, which "can be asymptotically faster than [cons] … because [cons] is always O(log(n)) …
while this function is O(log(n/m)) where [m] is the size of the part of the tree that is
skipped". Because an insert, remove or update path-copies only the O(log n) nodes from the root
to the key, **two versions of a map share every other subtree**, and the diff visits only the
copied paths: **O(k log n) for k changed keys** (the Base comments' claim; a rebalance near the
root can cost more: "if the overall root is rebalanced, we'll eat the whole cost,
unfortunately").

On that, `Incr_map` builds ~60 operations whose stated goal is "to do work on the output of the
computation proportional to the amount of work done on the input. i.e., k modifications to the
input map … will result in k modifications to the output map" [source, `incr_map_intf.ml`
line 537]: `mapi` and `filter_mapi` keep the previous output and apply the diff to it; `rank` is
O(log n + r) per change instead of O(n); `subrange` (virtualised tables) is O((k + m) log n);
`unordered_fold` (§3.3) applies `add`/`remove` per changed key. **No per-key nodes are needed**:
one `Incr_map.mapi` node over a 100 000-key map is one node, which is why Bonsai lowers a
stateless `assoc` to it (§2).

The same diff drives the DOM: `virtual_dom`'s `Vdom_node_with_map_children` is a widget whose
children are a `Map` from key to `Vdom.Node.t`; each frame it runs `Map.fold_symmetric_diff
~data_equal:phys_equal` between the previous and current child maps and turns `` `Left ``,
`` `Right `` and `` `Unequal `` into remove, insert and patch [source,
`virtual_dom/src/vdom_node_with_map_children.ml` lines 200–215]. **The DOM order is the map's key
order**: there is no move, because a permutation is not something a sorted map can express; to
show rows in another order the program re-keys the map (the partial-render table keys by sort key
then row key, through `Incr_map_collate`).

### 3.2 Against beni's lists

beni's row machinery (`browser-direct.md` §6) has three tools: the write-set **edit tag** of a
list path, which names the edit at compile time (`swap κ₁ κ₂`, `append`, `kept [κ]`); the
**identity walk** for `kept [*]` (one `!==` per row, O(n) compares, O(changed) writes); and the
**general reconciler** for `permute`, `replaced`, composed edits and derived lists (O(n) with a
key map). Symmetric diff sits between the second and third: exact like a tag, but found at run
time from the two values, so it needs no analysis and survives any composition of `Dict`
operations.

- **For `List`: reject.** beni's `List` is an array, or a 32-way trie after writes past the
  thresholds (`backend.md` §4). A plain array shares nothing between versions, so there is no
  subtree to skip, and the identity walk already is the array's symmetric diff (O(n) compares,
  which on 1 000 rows is of the order of microseconds [estimate]). A trie does share untouched subtrees after `set`, but
  `map`, `filter` and every builder make fresh nodes, and positions shift on insert, so a
  positional identity diff over trie nodes would serve only `List.set`/`update` — exactly the
  writes the tags already name. And the ownership thesis (`docs/thesis/ownership/`, research 71)
  makes a model list a plain array **edited in place**: then there is no old value to diff
  against at all. Bonsai's trick needs persistence; beni's direction for `List` is the opposite,
  and write sets are what replace the diff.
- **For `Dict`: adapt.** beni's `Dict` is Elm's left-leaning red-black tree, persistent and
  path-copying (`core/Dict.beni`), and the ownership thesis keeps it a tree of constructors
  (thesis, `ch-hard.tex`, *A dictionary*). `write-sets.md` §2.6 says a `Dict` has no positions
  (*open choice O3*): any write to one is a `value` write of the whole path, so a `For` over
  `Dict.values model.rows` goes to the reconciler today. A symmetric diff gives the exact edit at
  run time in O(k log n), with **no key map** (the dictionary *is* the key map, and its order is
  the DOM order) and **no reconciler**: remove for `Left`, make and `insertBefore` the next
  surviving row for `Right`, patch for `Unequal`. It is the right shape for the data apps Jane
  Street builds (thousands of rows keyed by id, ticking) and for a `Dict Id Todo`. **What it
  costs** [estimate]: an LLRB diff is a tree walk with a fallback for differing shapes — of the
  order of P3's reconciler (406 B) or less, against the 715 B general reconciler that research 70's size
  investigation found in the table app (the key map is counted apart, with the list scripts); it ships only for a program with a `For` over a dictionary. **What
  it does not do**: order by anything but the key (sorting needs re-keying, as in Bonsai), and
  identity of row values (`Unequal` is `!==`; a `Dict.map` that rebuilds every value defeats it,
  as it defeats every identity skip). Where it touches beni: `write-sets.md` O3, `browser-direct.md`
  §6.2 (a new script row: "a `For` over a `Dict` path: the symmetric diff") and §6.3 (one fewer
  reach of the reconciler), and `core/Dict` (a `foldDiff` written in beni, so not `foreign`).

**The physical-equality cutoff itself beni already has, and better.** Bonsai's default cutoff is
`phys_equal` on every node [doc, `cutoff.md`], the same as beni's reference check per hole; the
difference is that beni's `browser-direct` runs the check only for holes a message can reach,
and Bonsai's propagation reaches every node downstream of the single model variable until a
cutoff stops it. Bonsai's ppx also inserts cutoffs automatically for fields a pattern ignores
(`let%arr { a; _ } = r` depends on `a` only; `how_bonsai_works.md`, *arr*): that is beni's
per-hole read path, which the compiler computes for every hole without being asked.

### 3.3 Incremental folds

`Incr_map.unordered_fold` keeps an aggregate over a map by calling `add` for each new key,
`remove` for each removed one, and `remove` then `add` (or a supplied `update`) for each changed
one, driven by the symmetric diff [source, `incr_map_intf.ml` lines 620–660]. A sum, a count, a
min-heap, an index: anything with an inverse. Per message it costs O(k), not O(n).

beni's derived values (`browser-direct.md` §5.4) recompute a `let` that a message's writes reach,
whole: TodoMVC's "items left", `List.length (List.filter (not .done) model.todos)`, is O(n) on
every toggle. The write set already says *which* element changed (`kept [κ]`), so the compiler
could keep such a fold as a slot and update it by the edit — `count -= pred(old κ); count +=
pred(new κ)` — for folds it recognises (`length ∘ filter p`, `sum ∘ map f`), with no diff.
**Verdict: adapt, low priority.** It is a precision `browser-direct.md` §6.2 already allows for
filtered `For`s and does not promise; it matters only for long lists, and at 1 000 todos the
O(n) recount is not where research 70's TodoMVC time goes (the filter switch's reconcile is).

### 3.4 The filtered list, again

The TodoMVC shape — `For each={List.filter model.todos (visible model.filter _)}` — is where
Bonsai and beni meet most directly. `Incr_map.filter_mapi` keeps the previous filtered map and
applies the input's diff, so toggling one todo is O(log n) work and one DOM insert or remove; the
filter switch (the predicate changes) is O(n), as it must be. beni today sends the derived list
through the reconciler (research 70 §3: toggle 0.25 ms at 1 000 against vanilla's 0.095). The
write-set analogue needs no map: a `kept [κ]` write to `model.todos` under a filter whose
predicate reads no written path is, for the filtered view, a remove (`p old ∧ ¬p new`), an insert
(`¬p old ∧ p new`) or a patch at κ's place, and the place is the next visible row after κ in the
instance array. `browser-direct.md` §6.2 names this precision and leaves it unpromised; Bonsai is
evidence it is worth promising for filter, because their table and list components lean on
exactly `filter_mapi` and `subrange` [doc, `partial_render_table.md`].

---

## 4. Local state without breaking a pure model (question 3)

**How Bonsai does it.** `Bonsai.state 0 graph` declares a piece of state where it is used and
returns its current value and a setter. There is no global model the programmer writes. But
there **is** one global model: "The top-level `Computation.info` for our whole web UI now
contains a `'model Meta.Model.t` … We can use that to create a `'model Incr.Var.t`, which will
be a single variable tracking the state of our whole web UI! It's shaped roughly like the
`Computation.t` graph itself: every `Sub` is a tuple of the `'model` of its `from` and the
`'model` of its `into`; assocs are `Map.t`s of the inner's `'model` … And the 'actual'
representation of an action is a path in that tree" [doc, `how_bonsai_works.md`, *So where do
models + actions live?*]. The model is immutable; an action is applied by the leaf's pure
`apply_action` and the tree is rebuilt along the path. Default models compose automatically.

**How they got there** [doc, `blog/history.md`]: Bonsai began (2019) with the model and the action
as type parameters of a component, like TEA's nesting. The action parameter grew into a binary
tree of `Either.t` that the history quotes at sixty lines ("If you've ever wanted a binary tree
of types, Bonsai Beta would gladly provide"), so it was hidden first; then "some of the London T&C
team dared me to remove the model type parameter", and the result "simultaneously made normal
usage of the library much easier while making most unidiomatic patterns impossible". The cost
they accepted: components can no longer share a model; one that reads another's state takes it
as an input, and "none of the apps or libraries … actually relied on two components reading and
writing to the same model". The requirement they added: every model must be serialisable and
have an equality, which is what makes the whole state inspectable.

**The semantics worth copying, and the ones not to.**

- Per-key state is a map of models (`assoc`), keyed by the same key as the rows; `scope_model`
  keeps one copy per key and shows one ("you were editing User A, now you're editing User B")
  [doc, `state_per_key.md`].
- **State outlives an inactive branch**: "Bonsai keeps a node's state even while the node is
  inactive" [doc, `thinking_in_bonsai.md`], and an `assoc` keeps a removed key's model too —
  "persist that state even if the key is removed" — which Bonsai's changelog records as a
  memory leak fixed once ("Fixed memory leak in Bonsai.assoc with models not being removed").
  Resetting is opt-in (`with_model_resetter`, `scope_model`).
- **Stale values in effects** [doc, `effects_and_stale_values.md`]: an effect closes over values
  from the last stabilisation, so `set_state x` followed by reading a derived value reads the old
  one; the fix is `Bonsai.peek`, an effect that stabilises and reads. The pitfalls page lists it
  among "Common Bonsai Bugs".

**What it would mean for beni.** The diary (2026-09-20: two Ryan Carniato streams, and report 30 on
what Elm's users complained about) records the owner's open question as local state, and the finding that the pain
attaches to `Msg`, not to `Model`: "letting a subtree own a message type without every ancestor
naming it". Bonsai's design *is* that, done at run time: the source says "this component has an
`Int` and a `Bool` and these transitions", and the framework writes the nested model and the
nested action type that TEA's programmer writes by hand. beni can do the same **at compile
time**, which Bonsai cannot: a component's declared state becomes a field of a synthesised
record in the parent's model, its transitions become constructors of a synthesised message
type, and the result is an ordinary TEA program. Everything downstream is unchanged and keeps
working: the model stays one immutable value (time travel, `Debug` printing, the §8.3 property
that the page is a function of the model), and `write-sets.md` sees an ordinary record field and
an ordinary message key, so `browser-direct` compiles a local counter to the same two-line
handler it compiles a model counter to. Per-row state is a `Dict` keyed by the row key, which is
§3.2's case. **Verdict: adapt — as a design input, not a decision.** It is a language and
platform question for the owner (rule 1: specified before built), it touches `browser-decisions.md`
(the local-state question), `browser-direct.md` §9.2 (components), `write-sets.md` §4.4 (message
keys), and the `browser-tea` platform. Two of Bonsai's choices should be decided the other way
round in beni: state of a branch that is gone should be **dropped by default** (TEA's model
already does that when a variant is replaced; keeping it is the leak above), and effects must
read the model *after* the update, which TEA's `update` returning commands already guarantees —
the stale-value bug class does not exist in TEA and must not be introduced.

---

## 5. Cutoffs, heights, stabilisation and large UIs (question 4)

**Cutoffs.** Default `phys_equal`; custom by `Bonsai.cutoff ~equal` [doc, `cutoff.md`]. A cutoff
is per node, chosen by the programmer when identity is not enough (a derived value equal but
freshly allocated). beni's equivalent is the language's structural `==` (derived `eq`), never
needed at run time in compiled templates because `map`, `filter` and record update preserve
identity of untouched values (`backend.md` §4, *Identity*; `browser-decisions.md` W27). Nothing
to take.

**Heights.** A node's height exceeds its children's; the recompute heap is an array of buckets by
height; adding an edge may raise heights through an "adjust-heights heap" [source,
`incremental_intf.ml` lines 245–330]. This is Incremental's answer to glitch freedom in a graph
that changes shape at run time (through `bind`). beni has no run-time graph and a handler's
writes are emitted in source order of the sites (`browser-direct.md` §4.1); there is nothing for
heights to order. Reject.

**Stabilisation cost.** Incremental's own announcement puts firing a node "on the order of 30ns"
(research 57, checked there against the post). Bonsai's guide says "Incremental nodes aren't
*super* expensive, but they aren't free to create, fire, and track", advises against
"over-incrementalizing", and says `assoc` "is actually fairly expensive … This grows exponentially
for nested assocs" [doc, `best_practices_pitfalls.md`, *Bonsai Performance*]. The partial-render
table offers three cell modes and calls `Pure` "the most performant option by far", with a link to
a benchmark program whose results are not published in the repository [doc,
`partial_render_table.md`; source, `bonsai_web_components/partial_render_table/bench/bin/main.ml`].
Bonsai also has a **stabilisation tracker** that proves an action's input is already fresh and
skips the stabilisation the loop would otherwise run before it — "particularly helpful when
setting forms for highly nested types, which generally schedule lots of dynamic actions" [source,
`stabilization_tracker.mli`]. That such a pass was worth writing is itself a finding: stabilising
between actions was a real cost in their large forms.

**Large UIs.** Jane Street's answer to thousands of rows is not incrementality alone but
**virtualisation**: the partial-render table renders only the visible range, found with
`Incr_map.subrange` and `rank` in O(log n) per change ("once we get to thousands, the browser
starts to struggle", `partial_render_table.md`). beni has no virtualised list; when it needs one,
the incremental `rank`/`subrange` over a `Dict` is the prior art, and over an array the range is
an index slice that costs nothing to find.

**What Jane Street reports, and how much of it is measured.** Every number below is from a Jane
Street talk or post; none comes with a method, and none compares against another framework.

- *Seven Implementations of Incremental* (Yaron Minsky, 2016 talk transcript): the second
  implementation was "one and a half to four times worse" than the first; the eighth, with GADTs in
  place of closures, made "serious, relatively well tuned end user applications … three times
  faster"; and "these applications that you've made faster by adding Incremental are … now
  totally bounded by Incremental". **[reported, measured internally, no method]** The last line is
  the important one for beni: once the graph does its job, the graph is the cost.
- *Self Adjusting DOM and Diffable Data* (Minsky, 2016): applications "that display thousands of
  rows of data of which hundreds of cells are changing every second … respond to every update in
  just a handful of milliseconds", with the caveat "I doubt our performance is as good as … React
  and Mercury" on the virtual DOM side. **[assertion]**
- *Intro to Incr_dom* (Cristina Rosu, talk): a demo with 10 000 rows updating tens of times a
  second; at 30 000 rows the non-incremental version "took a few seconds to load … extremely
  choppy"; `Incr_map` made updates fast but "it doesn't help with the initial work", and the fix
  was partial rendering. **[live demo]**
- *Signals & Threads, "Building a UI Framework"* (Ty Overby, 2021): tables of "hundreds of
  thousands of rows", of which "we only actually show a very small subset to the DOM".
  **[assertion]**
- Hacker News, trishume (2017, a former Jane Street engineer): "a web based table that could do
  60fps scrolling on 100,000 items that were all dynamically updating using js_of_ocaml and …
  incr_dom", by creating "DOM elements for only things that you compute are visible".
  **[first-hand, not measured]**

The pattern across all five: Jane Street's large-UI speed comes from **virtualisation plus
incremental collection operations**, not from the DOM layer, which they concede is a naive
virtual DOM. beni's measured position (research 29, 70) is already ahead of a virtual DOM on every
table operation; what Bonsai adds for very large data is the virtualised range (above), which is
a list-component question, not an architecture question.

**The one outside measurement** is js-framework-benchmark's **non-keyed `incr_dom` v0.15.0**
entry (2019, written in Reason; there is no Bonsai entry). From the benchmark's committed
`webdriver-ts-results/src/results.ts` (Chrome 154, 2026-10-04), medians of total time in ms:
create 1 000 rows 140.6, replace 122.8, partial update 169.3, select 158.9, swap 169.9,
create 10 000 rows 740; bundle 946.8 kB raw and **243.2 kB compressed**; first paint 1 147 ms
(vanilla in the same file: 20.9 ms to create 1 000 rows and 2.4 kB compressed). **[measured by
the benchmark; medians recomputed from the file for this report]** It is **not** idiomatic
`incr_dom` — it keeps rows in an array, uses no `Incr_map` and rebuilds every row's view on each
change — so its times say nothing about Bonsai's design. Its size and first paint do say what a
js_of_ocaml program with Jane Street's standard library costs, and that is §7's subject.

---

## 6. The unusual parts (question 5)

### 6.1 Arrows, then `Proc`, then `Cont`

The history is a five-step retreat from the abstraction that made the static graph possible
[doc, `blog/history.md`, `blog/proc.md`, `upgrade/local-graph.md`]:

1. **2019, arrows.** `('input, 'model, 'result) Bonsai.t` with `>>>` and `both`: "Bonsai is
   somewhat unique among Jane Street libraries for embracing the Arrow … Unfortunately, the Arrow
   APIs can be a real struggle to work with": no names for intermediate results, tupling to pass
   several values, accidental duplicated work, and an `if_` whose branches had to take the same
   input.
2. **Model-less** (§4) and the **wormhole** (Leo White's proposal: a "read" end that lets any
   later computation use an earlier result), which became `sub`.
3. **2020–2022, `Proc`.** Two types, `'a Computation.t` (may hold state; each use is a separate
   instance) and `'a Value.t` (an applicative, a reference to a shared result), with `let%sub`
   to instantiate a computation and `let%arr` to map values — "largely inspired by the Arrow
   Calculus". The rule a programmer had to learn: `let%sub` once and alias the value, or get two
   instances with two states.
4. **Late 2023, `Cont`** (the `local_ graph` API). One type, `'a Bonsai.t`; state is created by
   passing `graph` (`Bonsai.state 0 graph`). Internally the same `Computation.t`, built in
   continuation-passing style: `graph` "is implemented as a ref holding a
   `Computation.t -> Computation.t` function", each `perform` wraps it in another `Sub`, "very
   similar to how Difference lists are typically implemented".
5. **The phase witness.** What stops a programmer from creating state inside a `let%arr` body at
   run time? OxCaml's `local_` mode: a `local_` argument may not escape into a closure, and every
   run-time body is a closure, so "if the compiler allows us to use `graph`, we are in the
   'compile' phase; if it doesn't, we are in the 'runtime' phase". And for `Bonsai.map`, "we
   cheat and make `graph` global".

**What beni takes from it.** Not the API: beni's components are functions and markup, and its
compiler sees the whole program, so the distinction Bonsai enforces with a type-system mode —
build-time code against run-time code — is the distinction between `view`'s structure and its
holes, which beni's JSX lowering already draws (`backend.md` §15). The lesson is about cost of
ownership: the static-graph property was bought with an API that took four years and three
redesigns to make usable, and Jane Street's own `Cont` design document concedes the final API
works by a global and a mode. A design that gets the same property from the compiler should not
re-import the restriction into the surface language.

### 6.2 `match%sub` and `assoc`: activity, not structure

A branch not taken is *inactive*: its nodes exist, are skipped by stabilisation, and fire
`on_activate`/`on_deactivate` when the scrutinee changes [doc, `thinking_in_bonsai.md`,
*lifecycle events*]. beni's `Show` and `case` mount and unmount; `browser-direct.md` §5.5 tears an
arm down on a switch and keeps no nodes for an arm not shown. Same semantics for the page, without the dormant graph.

### 6.3 Dynamic scope

`Bonsai.Dynamic_scope` (`Store`/`Fetch` nodes) gives a context value to everything below a point,
used for theming [doc, `theming.md`]. The partial-render table's own guide recommends passing a
style explicitly instead "because dynamically scoped theming is implicit, and can be difficult to
follow". Not needed by beni; noted because the people who built it advise against it.

### 6.4 Lowering a stateless per-key body

`Assoc` → `Assoc_simple` (§2) is the one optimisation in Bonsai that is about collections, and it
is the same insight as beni's rows: per-row machinery only where a row has state. Already beni's
design.

### 6.5 Testing: `Bonsai_web_test`

A test handle runs a component without a browser, prints its virtual DOM as HTML in an expect
test, and simulates `click_on`, `input_text` and injected actions; `show_diff` prints only what
changed since the last print [doc, `testing.md`]. The documented limits: events do not propagate,
hooks and widgets do not run, and it runs in Node, not a browser. beni's `tests/corpus/browser/`
already does more — a real DOM (happy-dom, and Chrome in `test-browser`), `.steps` scripts,
transcripts per step — so the only idea worth a line is **printing a diff per step instead of the
whole page**, which makes a long transcript readable. Low priority; the corpus README owns it.

### 6.6 Graph introspection

Every node carries a source position (`~here`), the graph can be dumped to Graphviz
(`to_dot.ml`), and a computation watcher logs which nodes fired (`enable_computation_watcher.ml`).
beni's equivalent is the `browser-direct` dump lines (`browser-direct.md` §11): which keys reach
the reconciler, what each message writes. Bonsai's suggests one addition beni could make
cheaply: in development, a per-message count of holes compared and written, which is the number
a programmer needs when a message is slow.

---

## 7. Costs and failures (question 6)

**Bundle size and first load.** Jane Street says so itself. Ty Overby, on *Signals & Threads*
(2021): "a lot of the things that would kill Bonsai on arrival at any other company like somewhat
enormous JavaScript bundle size and not being able to do server side rendering … [or] split a
application into many files … are simply not present" — their pages are long-lived tools on fast
internal networks. The only measured figure is js-framework-benchmark's `incr_dom` bundle: 243 kB
compressed, about 100× vanilla and about 30× Elm's 8.2 kB (§5). A Hacker News user (2022): "There
are drawbacks like filesize, but if you don't have to serve the webapp on the first pageload it
shouldn't be a problem." For beni, whose target is a 1.4 kB empty page and bytes per static
element tending to zero (`CLAUDE.md`, research 58), nothing in this runtime is affordable, and
nothing in this report proposes shipping it: every idea taken above is a compile-time
transformation or a single small function.

**Run-time overhead.** The cost of the graph is Jane Street's own recurring theme: "the overhead of
incremental is not inconsiderable" (*Introducing Incremental*, 2015, the 30 ns per node), the
eighth implementation's applications being "totally bounded by Incremental" (§5), "don't
over-incrementalize", `assoc` "fairly expensive" and exponential when nested
(`best_practices_pitfalls.md`). Start-up runs the graph build and optimiser every load ("happens
exactly once", Overby) — cheap per load but proportional to the app, which is why `match%sub
[%lazy]` exists.

**Learning curve and verbosity.** Overby: "about 50 people through a class … their frustrated
expressions still motivate me today"; the arrow API was "a real struggle" (`proc.md`); a component
used twice silently gets two states unless the programmer knows the `let%sub` rule; before `Cont`,
"`let%map`s were always considered harmful" (`local-graph.md`). Ian Henry (*Signals & Threads*,
2025): "You're definitely typing more characters when you're using Bonsai than when you're using
React." Hacker News (2026): "Considering how ridiculously verbose their library is compared to
React/Vue". Minsky in 2016, of the layer underneath: "programming with Incremental is a worse
experience than doing ordinary functional programming with immutable values".

**Lists in the virtual DOM.** Minsky (2016): "the virtual dom API uses lists, which can't be
updated incrementally in an efficient way"; Rosu, on rebuilding `Map.data` lists every frame:
"That's something we have noticed and have been sad about. We haven't really figured out a
solution." The later answer is `Vdom_node_with_map_children` (§3.1) — the diffable map carried
all the way into the DOM. That is the same gap beni's compiled lists close at compile time.

**An outsider's attempt to copy the approach.** Raph Levien (Druid, Xilem), Hacker News 2022:
incr_dom and Bonsai "were even greater inspirations for the Druid architecture … we were hoping
that a lot of the incremental/reactive patterns could be expressed using combinators over
immutable data structures. That didn't work out as well as hoped". The combinator surface is what
did not travel; it is what this report recommends beni not take.

**Effects and state semantics.** The stale-value bug and state kept for inactive branches and
removed keys (§4) are documented as "Common Bonsai Bugs" and as a fixed memory leak.

**Adoption.** Hacker News's 2026 thread on Bonsai (154 comments) is mostly about OCaml and
aesthetics; one commenter asks "Is Bonsai used much outside of Jane Street?" and the visible
outside users are research projects (Hazel, whose maintainer reports agents write it fine).
No outside production report of size or speed was found.

---

## 8. Verdicts

| idea | Bonsai source | beni today | verdict | touches |
|---|---|---|---|---|
| Static graph built at start-up, optimised (constant fold, stateless `assoc` → `mapi`) | `constant_fold.ml`, `simplify.ml` | compile-time structure, baking, write sets | **reject** — beni is past it | — |
| `phys_equal` cutoff per node; ppx cutoffs on ignored fields | `cutoff.md`, `how_bonsai_works.md` | reference check per hole, per-hole read paths | **already has** (better: only reachable holes) | — |
| Incremental's height-ordered recompute heap | `incremental_intf.ml` | per-message code in source order | **reject** — no run-time graph to order | — |
| `Map.symmetric_diff` for rows from a `Dict` | Base `map.ml`; `vdom_node_with_map_children.ml` | `Dict` writes are whole (`write-sets.md` O3) → reconciler | **adapt; spike** | `write-sets.md` O3, `browser-direct.md` §6.2–6.3, `core/Dict` |
| Symmetric diff for `List` | — | tags, identity walk; ownership makes arrays in place | **reject** — no sharing; in-place removes the old value | — |
| `unordered_fold`: aggregates in O(changes) | `incr_map_intf.ml` | derived `let` recomputed whole | **adapt, low priority**, from edit tags | `browser-direct.md` §5.4 |
| Filtered view maintained by diff (`filter_mapi`) | `incr_map.ml` | derived `each` → reconciler | **adapt** as a write-set precision | `browser-direct.md` §6.2 last paragraph |
| Model-less components: local state compiled into one global model, actions as paths | `blog/history.md`, `how_bonsai_works.md` | open owner question | **adapt** as a compile-time desugaring; drop state of a gone branch by default | `browser-decisions.md`, `browser-direct.md` §9.2, `write-sets.md` §4.4, `browser-tea` |
| Stabilisation tracker (skip a re-stabilise when the input is provably fresh) | `stabilization_tracker.mli` | TEA's `update` reads the model directly | **not needed** | — |
| Virtualisation by `rank`/`subrange` | `partial_render_table.md`, `incr_map_intf.ml` | none | **later**: prior art for a virtualised `For` | a future platform list |
| Arrow / `Proc` / `Cont` API, `local_` as phase witness | `blog/*`, `local-graph.md` | the compiler sees structure | **reject** for the surface; keep as the record of what a static graph costs when it is not a compiler | — |
| `Bonsai_web_test` diffs per step | `testing.md` | full transcripts in a real DOM | **minor**: print a diff per step | `tests/corpus/README.md` |
| Virtual DOM, rAF frame loop | `driver.ml`, `virtualdom.js` | compiled templates, writes in the handler | **reject** (research 29) | — |

**The spike, stated so it can be run.** Add `For each={Dict.values model.rows}` (or a `For` that
takes a `Dict` directly) to `browser-direct`, rendered by a symmetric diff of the old and new
`Dict` in place of §6.3's reconciler, with no key map. Measure, on the table app rewritten to keep
rows in a `Dict Int Row`, the operations whose writes compose (`run`, `replace`, `update10th`,
`remove`, `append`, `clear`) and bytes by leave-one-out, against today's reconciler on the `List`
version. The kill criterion is research 70's: if it does not take bytes out of the 715 B the
reconciler costs (and the key map's share), or loses time on any operation, it stops. `swap` is not this spike's
case — a sorted dictionary has no swap, which is a finding to report, not to work around.

---

## 9. Sources

Code (shallow clones, 2026-10-11):

- `janestreet/bonsai` @ `f316614`: `src/constant_fold.ml`, `src/simplify.ml(i)`,
  `src/pre_process.ml`, `src/stabilization_tracker.mli`, `src/private_base/computation.ml`,
  `src/private_gather/gather_assoc_simple.ml`, `ppx_bonsai/readme.md`, `changelog.md` —
  https://github.com/janestreet/bonsai
- `janestreet/bonsai_web` @ `989c18b`: `docs/advanced/how_bonsai_works.md`, `docs/blog/history.md`,
  `docs/blog/proc.md`, `docs/upgrade/local-graph.md`, `docs/thinking_in_bonsai.md`,
  `docs/how_to/{bonsai_runtime,cutoff,best_practices_pitfalls,partial_render_table,state_per_key,effects_and_stale_values,testing,benchmarking}.md`,
  `web/driver.ml` — https://github.com/janestreet/bonsai_web
- `janestreet/incremental` @ `98b5750`: `src/incremental_intf.ml` — https://github.com/janestreet/incremental
- `janestreet/incr_map` @ `21c6bc6`: `src/incr_map_intf.ml`, `src/incr_map.ml`,
  `collate/src/incr_map_collate.mli` — https://github.com/janestreet/incr_map
- `janestreet/virtual_dom` @ `4e9549c`: `src/vdom_node_with_map_children.ml`,
  `lib/vendor/vtree/diff.js` — https://github.com/janestreet/virtual_dom
- `janestreet/base`, `src/map.ml` (`fold_symmetric_diff`, `Enum.drop_phys_equal_prefix`) —
  https://github.com/janestreet/base/blob/master/src/map.ml
- `janestreet/bonsai_web_components`, `partial_render_table/bench/bin/main.ml` (a benchmark
  program; no results published) — https://github.com/janestreet/bonsai_web_components

Jane Street posts, talks and podcasts:

- Yaron Minsky, "Introducing Incremental", 2015-07-18 — https://blog.janestreet.com/introducing-incremental/
- Yaron Minsky, "Incrementality and the web", 2016-01-30 — https://blog.janestreet.com/incrementality-and-the-web/
- Yaron Minsky, "Self Adjusting DOM", 2016-02-06 — https://blog.janestreet.com/self-adjusting-dom/
- Yaron Minsky, "Self Adjusting DOM and Diffable Data", 2016-02-10 — https://blog.janestreet.com/self-adjusting-dom-and-diffable-data/
- Yaron Minsky, "Seven Implementations of Incremental" (talk, transcript) — https://www.janestreet.com/tech-talks/seven-implementations-of-incremental/
- Cristina Rosu, "Intro to Incr_dom" (talk, transcript) — https://www.janestreet.com/tech-talks/intro-to-incr-dom/
- Ty Overby on *Signals & Threads*, "Building a UI Framework", 2021-10-06 — https://signalsandthreads.com/building-a-ui-framework/
- Ian Henry on *Signals & Threads*, "Building Tools for Traders", 2025-05-28 — https://signalsandthreads.com/building-tools-for-traders/
- `docs/advanced/why_no_bind.md` in an earlier `bonsai` revision — https://github.com/janestreet/bonsai/blob/d5d79a93a9c407b986ac6b551795928eee8b0bc7/docs/advanced/why_no_bind.md

Measurement:

- js-framework-benchmark, `webdriver-ts-results/src/results.ts` (non-keyed `incr_dom-v0.15.0`,
  committed 2026-10-04) — https://github.com/krausest/js-framework-benchmark

Hacker News (via the `hackernews` skill):

- trishume, 2017 — https://news.ycombinator.com/item?id=14158420
- dna_polymerase, 2022 — https://news.ycombinator.com/item?id=33620768
- raphlinus, 2022 — https://news.ycombinator.com/item?id=31299266
- "Bonsai: Janestreet's UI Library", 2026 — https://news.ycombinator.com/item?id=49152842
- Onavo, 2026 — https://news.ycombinator.com/item?id=49157968
- mpweiher, 2026 — https://news.ycombinator.com/item?id=49147778
- disconcision, 2026 — https://news.ycombinator.com/item?id=49161054
- osener, 2026 — https://news.ycombinator.com/item?id=48990376

Not reached: Ty Overby's OCaml Workshop talk on Bonsai, the 2023 `Cont` talk, and Minsky's
Strange Loop 2018 "Data Driven UIs, Incrementally" (no transcript found); no outside blog post
measuring Bonsai was found.

In this repository: research 57 (§ on Jane Street), 58, 70; `browser-direct.md` §5–§6, §9;
`write-sets.md` §2.6 and O3; `backend.md` §4; `core/Dict.beni`; `docs/thesis/ownership/`;
`plans/diary/` (the entries of 2026-09-20, the local-state reading).
