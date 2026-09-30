# Roc-style in-place writes in JavaScript: counts, a shared bit, or proofs

**Commissioned by** the owner's question: **can beni do Roc-style in-place updates in JavaScript
by maintaining its own reference information in the code it emits?** Roc writes a `List` in place
when its reference count is 1. JavaScript has no reference counts, but beni generates every line
of code that touches a beni value, as Koka (Perceus, Reinking et al. 2021) and Lean 4 ("Counting
Immutable Beans", Ullrich & de Moura 2019) insert `dup`/`drop` at compile time. A scope addition
asked for **R0**, a purely static variant with no run-time information at all.

**What this is.** Both papers read, and what their analyses insert summarised (§2). Four ways to
write in place, prototyped by transforming beni's own compiled output **by hand, exactly as a
compiler pass would**, each transformation named by the rule that licenses it (§3, §4):

* **R0**, static: in place where last use and per-function interface summaries prove a value
  unique; a copy where a caller cannot prove what a callee consumes;
* **R1**, full counts: an `rc` count on arrays and on records that hold them, Perceus's `dup`/`drop`
  with Lean's borrowed parameters;
* **R2**, a sticky shared bit: R1 with every `drop` deleted;
* **R2-plain**: R2 with no trie at all, every array a plain JS array, copied whole when shared.

They were run on research 38 §15's six array scenarios and on §16's list shapes, against the
adaptive array of §15 (T = 256) and plain copy-on-write, with a differential test, escape tests and
negative controls (§5.1), and the costs that do not show in a scenario measured on their own (§7).
Node 24.19, five rounds; headless Chrome 153 as a three-round spot check (§6.8). Scripts in
`bench/arrays/rc/`.

**What this is not.** A change to `src/`, or a design ready to build: §9 prices the pass.

**Read §0, then §6 and §10.**

---

## 0. Findings

### 0.1 The answer

**Yes, it can be done, and it is sound; it pays in one kind of code, and the TEA model is not that
kind.** A count (R1) or a sticky shared bit (R2) on beni arrays, maintained by compiler-inserted
`dup`s, lets a write to an array nobody else holds land in place. With a garbage collector a
missing `drop` costs only a missed in-place write, so the drops can go entirely: **R2 made the same
in-place decision as R1 in every scenario, cheaper**. A value handed to JavaScript is pinned and
never written again; the escape tests prove it.

Where it pays is **an array written repeatedly while unique**: building in a fold is **2–7× faster**
than §15's adaptive array, a large board's steady ticks up to 2×. Where it does not: **the TEA
model, because the DOM runtime keeps every array it rendered** — a kept array is shared, so R1 and
R2 write it exactly as adaptive does and pay their counting on top (up to 1.3× in Node, ≈1.0× in
Chrome). A runtime that hands the model over lets the writes land in place, and the render walk
hides them. A **history** (shared by design) gets nothing and pays 2–3× per edit, because generic
code moving counted arrays through lists stores to every one of them.

**The static variant R0 reached every win R2 did, with no run-time state, no read overhead and +2 %
code**, given R4's fold inlining and summaries over record field paths. Its "copy
first" at an unprovable call is harmless at a message boundary and catastrophic in a loop (cow's
cliff through a closure); calling a persistent twin instead makes a miss cost exactly today's write.
**R2-plain** (no trie, copy when shared) is the fastest in-place variant and the wrong
representation: it brings back cow's cliff for anything that keeps versions (11× per history edit,
44× the memory).

### 0.2 Per scenario (Node, median of 5 rounds; ratio to adaptive)

| scenario | adaptive | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|
| TEA table, update one row, 10 000 rows, runtime retains (today) | 55.0 µs | 0.86× | 1.15× | 1.33× | 0.95× |
| TEA table, update one row, 10 000 rows, runtime hands over | 58.5 µs | 0.84× | 0.99× | 1.12× | 0.86× |
| TEA table, swap, 10 000 rows, hands over | 43.6 µs | 0.95× | 1.21× | 1.22× | 1.02× |
| decoded, `count` by `foldl`, 10 000 (read only) | 47.8 µs | 0.92× | 1.38× | 1.39× | 0.84× |
| decoded, 1 000 binary searches, 100 000 (read only) | 348 µs | 1.01× | 1.07× | 1.10× | 1.18× |
| grid, 100-cell tick, 1 000 000 cells, steady | 45.9 µs | 0.44× | 0.85× | 0.81× | 0.43× |
| grid, 100-cell tick, 1 000 000 cells, first (board kept) | 2.80 ms | 1.52× | 1.09× | 1.00× | 1.76× |
| build: histogram of 100 000 samples, 1 000 buckets | 8.71 ms | 0.14× | 0.28× | 0.24× | 0.26× |
| build: collect 100 000 by `push` | 10.8 ms | 0.47× | 0.45× | 0.45× | 0.56× |
| build: coin-change table, 100 000 | 13.1 ms | 0.41× | 0.57× | 0.47× | 0.45× |
| undo history, one edit (10 000, 100 versions kept) | 1.06 µs | 1.13× | 3.2× | 2.1× | 11× |
| undo history, retained memory, 101 versions | 178 KB | 178 KB | 186 KB | 190 KB | 7 905 KB |
| write to an array JavaScript was handed, 100 000 | 122 µs | 3.3× | 0.93× | 1.04× | 3.9× |
| lists (one array type): accumulator in a record field, 100 000 | cons 3.07 ms | 0.62× | — | 2.8× | — |

cow for scale: the history edit 9.1×, the grid tick 10 107×, the histogram 7.6×. Chrome (three
rounds) agrees on every ordering that clears 1.25×, and shows less of R1's and R2's overhead.

### 0.3 Overheads and size

* **Reads**: one `$dupA` per element in a generic `core` loop — free on numbers, **1.3–1.9 ns** on a
  record (a property miss) — visible only on the tightest loop (1.38× on a one-comparison `foldl`
  in Node, none in Chrome). Argument passing: **0.1 ns** (R2) or **0.7 ns** (R1) for an owned array
  a callee does not keep. Record construction: **+1 ns** for a unique counted record, +2.6–3.2 ns
  for a shared one. Where the count lives: a named property on the array is free on reads and costs
  4 ns at creation; `Object.freeze` as the bit is 10× slower on reads. **One trap**: V8's
  `Array.prototype.concat` falls off its fast path on an array with a named property (7–15×).
* **Emitted code**, brotli, on 2 439 bytes of array-heavy modules: **R2 +156 (+6 %)**, **R1 +307
  (+13 %)**, R0 +59; the sibling with its runtime helpers grows 1 514 → 1 891 bytes (R1, R2), and
  shrinks to 706 for R2-plain, which has no trie.
* **Memory**: one property per counted array or record, invisible in every retained figure.

### 0.4 What to do

Keep §15's adaptive array, with no counts. If in-place writes are wanted, take them **statically**:
R0 with persistent twins (§10) keeps every fold-building win, costs nothing on reads and needs no
`foreign` or markup contract to be correct. Do not build R1. R2 is worth revisiting only together with a markup
runtime that hands the model over and versions its `For` slots. The list verdict of research 38
§16 stands (§8). §9 prices the pass: types in the backend, liveness, borrow or consumed-unique
signatures in the interface hash, an ownership declaration on every `foreign`, and a runtime
protocol for the markup runtime.

---

## 1. The candidates

| | where the information lives | a write lands in place when | a shared write | what the compiler emits |
|---|---|---|---|---|
| **adaptive** (baseline) | nowhere | never | copy up to T = 256, a trie above | nothing new |
| **cow** (baseline) | nowhere | never | a whole copy | nothing new |
| **R0** | the compiler, only | a proof says the value is fresh or consumed-unique, and dead after | adaptive's | `setU`/`pushU` where proven; a copy at a call that cannot prove what the callee consumes |
| **R1** | an `rc` count on every array and every record holding one | `rc === 1` | adaptive's, and the result is unique | `dup` (`rc++`) at a second holder, `drop` (`rc--`) at a death, drop specialisation at a record's last use |
| **R2** | an `rc` bit, 1 then 2 forever | `rc === 1` | adaptive's, and the result is unique | R1's `dup`s as `rc = 2`; **no drops at all** |
| **R2-plain** | as R2 | `rc === 1` | **a whole copy** (there is no trie) | R2's, and every read is a bare `a[i]` |

Under R1 and R2 a unique trie is written in place too, transient-style: its root carries an
ownership token and a node stamped with it is written directly, an unstamped one copied once and
stamped (`rc/ports/rc-adaptive.js`). A persistent write through a shared root must retire the
root's token first (§5.1 has the test that shows why). A first version flattened a unique trie back
to a plain array instead; it paid two O(n) passes on a board's first ticks (22 ms against 3.5 ms
at a million cells) and was dropped.

---

## 2. What the papers insert

### 2.1 Counting Immutable Beans (Lean 4)

Lean compiles a pure first-order IR (`λpure`, A-normal form, every closure lambda-lifted) to
`λRC`, which adds `inc x`, `dec x`, `let y = reset x` and `let z = reuse y in ctor_i w`. Three
passes, in order (§5 of the paper):

1. **Reset/reuse insertion** (`δreuse`, Fig. 3). For each `case x of …` arm with a constructor of
   arity n, find the first point where x is dead and a later `ctor_i` of the same arity; put
   `let w = reset x` there and replace the constructor by `reuse w in ctor_i`. At run time `reset`
   on a unique x decrements x's children and hands back its cell; on a shared x it decrements x and
   returns ⊥, and `reuse` allocates. `reset` and `reuse` are kept apart deliberately: between them
   the recursive call (`map f s`) must see `s` with a count of 1.
2. **Borrow inference** (`collectO`, Fig. 4). Every parameter starts Borrowed; a parameter becomes
   Owned if it (or a projection of it) is `reset`, is passed to an Owned parameter, is applied as or
   to a closure, or is partially applied; iterate to a fixpoint per strongly connected component.
   A refinement keeps tail calls: a parameter passed at a tail call in an owned slot is Owned,
   otherwise the caller's `dec` after the call would break the loop. Partial applications of a
   function with borrowed parameters go through an all-owned wrapper.
3. **inc/dec insertion** (`C`, Fig. 5). An owned variable used in an owned position is `inc`'d
   unless this is its last use (then ownership moves); a variable used only in borrowed positions is
   not touched; an owned variable that is dead at the start of a branch, or after its last borrowed
   use, is `dec`'d there. A projection from an owned value is `inc`'d; from a borrowed one it is
   itself borrowed.

On top of that the runtime writes an **array in place when its count is 1** (`Array.write`,
§7.1: "a well known optimization … we mention it here because it is relevant"), and marks values
**persistent** (static data, never counted) and **multi-threaded** (`markMT` walks a value once,
when it first crosses to another task, and after that its counts are atomic). The measured
benefit: reuse matters on `const_fold`, `rbmap` and `unionfind` (1.4–3.2× without it), borrowing
on `binarytrees` and `deriv` (1.14–1.16×), single-threaded counts everywhere (1.13–2.43×).

### 2.2 Perceus (Koka)

Perceus inserts `dup` and `drop` into a core language with explicit control flow (every exception
and effect is compiled to explicit returns first, §2.7.1) so that **a reference is dropped as soon
as it is dead** — "garbage free", proved against a linear resource calculus (§3, Theorems 3–4). On
top of that, four passes over the inserted code:

* **Drop specialisation** (§2.3): `drop(x)` right after matching x against a constructor is inlined
  as `if is-unique(x) then drop children; free(x) else decref(x)`, the `dup`s of the children are
  pushed into both branches, and `dup(c); drop(c)` pairs fuse. For a unique `xs`, `map`'s fast
  path then does no count operations at all (Fig. 1d).
* **Reuse analysis** (§2.4): Lean's reset/reuse, as `drop-reuse` producing a reuse token for a
  same-sized constructor in the branch, itself specialised (Fig. 1f–g).
* **Reuse specialisation** (§2.5): when the reused cell keeps most of its fields, write only the
  changed ones (`ru->left := y`).
* **FBIP** (§2.6): a programming discipline, not a pass — write the algorithm so every match is
  paired with a same-sized construction, and a unique input is rebuilt in place (the Morris
  traversal as a pure function).

The paper's Perceus has no borrowed parameters ("we would like to integrate selective borrowing",
§6); Koka has since added borrowed-parameter annotations. Thread sharing uses Lean's flag,
encoded as a negative count so that one `rc <= 1` test covers "unique", "shared across threads"
and "sticky": counts past 2^30 are never adjusted again (§2.7.2).

### 2.3 What survives when a garbage collector exists

Everything in both papers serves one of three ends: **freeing memory** (drops, garbage freedom),
**reusing memory** (reset/reuse, reuse specialisation, FBIP), and **writing in place** (the array
primitive). In a JavaScript target:

* **Freeing** buys nothing: the collector frees, and a count that reaches zero has nothing to do.
* **Reusing a constructor cell** buys almost nothing. V8 allocates a small object with a bump
  pointer and a dead young object costs nothing to collect, which is what Lean's and Koka's reuse
  replaces with a write (a `malloc`/`free` pair in C). It also *harms* beni: reusing a record cell
  is an in-place write to a record, and beni's renderer compares record references by identity
  (`i.x !== item`, research 38 §7, rule 8 — *field identity is load-bearing*). Constructors are left
  alone here.
* **Writing an array in place** is the whole prize, because the alternative is an O(n) copy or an
  O(log n) path copy — the only place where §15's baselines pay more than a small allocation.

And one thing changes sign. In C a missing `drop` is a leak and a missing `dup` a use-after-free;
**in JavaScript a missing `drop` is only a missed in-place write, and only a missing `dup` is a
wrong answer**. Counts may overestimate freely. That is what R2 exploits: keep every `dup` (as a
sticky "shared" mark) and delete every `drop`. It also relaxes Perceus's hardest precondition:
drops need explicit control flow, so that a cancelled fiber runs them; dups do not — a fiber that
never resumes leaves counts too high, never too low.

What carries over, then: **borrow inference** (fewer dups), **dup placement at the last use**
(Lean's `O+`), **drop specialisation for the one case that matters** — taking an array field out of
a record at the record's last use (rule O4 below), **persistent values** (module constants,
pinned), and **`markMT`'s shape**: a one-way mark when a value crosses a boundary, which becomes the
pin at the JavaScript boundary (O7).

---

## 3. The rules (R1, R2)

Each is written so that a pass over `Bir` or `JsIr` could apply it with the declaration, its module
and the interfaces of its imports; none needs the whole program.

* **O1 Borrow signatures.** Every parameter whose type can contain a counted value is Owned or
  Borrowed, by Lean's `collectO` fixpoint per strongly connected component, with the tail-call
  refinement. Exported signatures go into the module interface and flow forward, as types do.
  Closure parameters are always Owned. A `foreign` declares its signature (the array sibling:
  `set`/`push`/`pop`/`append`'s array Owned, every other parameter Borrowed).
* **O2 Dup at a second holder.** A variable used in an Owned position — an Owned parameter, a
  constructor or record field, a return, a closure capture — is `dup`'d unless this is its last
  use. A Borrowed variable in an Owned position is always `dup`'d.
* **O3 Drop at a death** (R1 only). An Owned variable dead at the start of a branch, or after its
  last Borrowed use, is `drop`'d; for a counted record type the drop is that type's generated
  function, which releases its array fields when the count reaches 0.
* **O4 Take at a record's last use.** `{ r | f = e(r.f) }` (and any projection of an Owned record
  at its last use) emits `u = r.rc === 1; f' = u ? r.f : dup(r.f)`, plus `if (!u) drop(r)` under R1:
  the field moves out of a unique record and is dup'd out of a shared one. This is Perceus's drop
  specialisation, applied only to fields of counted type.
* **O5 Counted kinds, type-directed.** Arrays are counted; so are records, tuples and constructors
  whose type holds an Array field. The compiler knows which at every monomorphic site and emits
  nothing for a value of a type that holds no Array. At a site whose type is a **type variable**
  (every generic `core` function) it emits `$dupA`/`$dropA`, which test for the field. Uncounted
  containers — cons cells, `Maybe`, a generic tuple — keep the token they were given forever, and
  **anything read out of any container is `dup`'d**, so a value stored in one is never seen as
  unique again. That makes element counts inside arrays unnecessary: copying an array needs no
  `dup` per element. (A Lean-style `Array.modify` that swaps an element out to update it in place
  would need exact element counts; it is left out.)
* **O6 Constants are pinned** at initialisation (Lean's persistent values): `Array.empty` is
  shared forever, so the first `push` onto it copies.
* **O7 The JavaScript boundary pins.** A value JavaScript may keep — a `foreign` argument that is
  not declared Borrowed, `toJs`, a value the DOM runtime keeps in a slot, a closure JavaScript
  holds — gets `rc = 2^29` (R1, out of reach of the drops) or `rc = 2` (R2). A value JavaScript
  hands in is fresh (the decoder's array, which it built and forgets) or pinned.
* **O8 Capture the projection.** A lambda that uses a counted variable only through scalar fields
  captures the fields (`const nextId$ = model.nextId`), not the variable. Without it, `Append`'s
  `initialize` lambda holds the model and every `Append` copies the rows.

R2 is R1 with O3 deleted: `rc/rc.mjs build` makes the R2 source by deleting every line of the R1
source marked `// R1`, and checks that no drop survives.

### 3.1 What it looks like

Research 38 §15's swap, `{ model | rows = Array.set (Array.set model.rows i b) j a }`, after O4 (R1;
R2 is the same without the marked line):

```js
const u$ = model$2.rc === 1;
const rows$ = u$ ? model$2.rows : $dup(model$2.rows);
if (!u$) Table$Model$drop(model$2); // R1
return { ...model$2, rc: 1, rows: Array$set(Array$set(rows$, i$7, b$10), j$8, a$9) };
```

The inner `set` writes in place if the rows are unique; its result is unique either way, so the
outer `set` always does. In `core`, the generic element read (O5):

```js
$in$3 = func$5($dupA(Array$unsafeGet(arr$1, i$2)), acc$4);   // Array.foldlHelp
```

---

## 4. The rules (R0)

R0 has no run-time information, so every in-place write is a proof.

* **S1 Local.** A write whose array operand is fresh in this function (the result of a write,
  `initialize`, `map`, `filter`, `fromList`, `repeat`, a `push` onto a constant) and dead after the
  write is in place.
* **S2 Consumed-unique parameters.** A parameter, or a field path of one (`model.rows`,
  `g.cells`), is consumed-unique if it flows only into in-place writes or consumed-unique
  parameters and is dead after. Summaries go into the interface and flow forward; a strongly
  connected component iterates. `Array.update`'s `arr` is one.
* **S3 The caller copies.** A call that passes a consumed-unique parameter anything it cannot prove
  fresh-and-dead, or consumed-unique in its own summary, copies it first (O(n), a fresh plain array).
* **S4 Result summaries.** A function whose result's field path is fresh or a consumed-unique input
  says so, so uniqueness survives a call: `update`'s rows are unique when its argument's were, and a
  runtime that hands the model to `update` keeps it unique by induction.
* **Closures get no requirement.** A lambda passed to a higher-order function is called by generic
  code that cannot copy for it. Its parameters are not consumed-unique, so a write on them is
  persistent, unless the call is inlined first: **R4** of research 38 §16.3 (`List.foldl` with a
  literal lambda becomes the loop, whose accumulator is a loop variable, and the loop's entry is a
  call site that copies an unproven initial value, S3).

`Build.histogramNoInline` shows what happens if S3 is applied to a lambda instead: the lambda calls
the consumed-unique `Array.update` with a parameter it cannot prove, so it copies per sample — §15's
cow cliff, 71 ms for 1 000 buckets against adaptive's 8.7 ms. A real R0 would never do that; it
would call the persistent write, which is what "closures get no requirement" means.

---

## 5. Method

A bare §15 or §16 in this report is research 38's.

**The code is beni's.** §15's seven scenario modules and its experimental `core/Array` are compiled
by this repository's `beni` (`node scenarios.mjs build`, development build). `rc/rc.mjs build` lays
the hand transformations over the compiled tree: `rc/src/r1/` (six scenario modules plus core's
`Array.mjs` and `List.mjs`), `rc/src/r0/` (four modules plus core's `Array.mjs`); `Interop` needed
nothing under R1, and `Decoded`, `Life` and `History` nothing under R0. R2 is generated from R1
(lines marked `// R1` deleted), R2-plain from R2 (every `unsafeGet`/`length` call turned into
`a[i]`/`a.length`, as §15.3's proven-plain build did). The siblings are
`rc/ports/{rc-adaptive,rc-plain,r0}.js`, the runtime helpers `rc/rt.js`.

**The protocol at the JavaScript boundary is explicit** (`rc/harness.js`). A value the harness keeps
and passes again is pinned under R1/R2 (O7) and copied before a consuming call under R0 (S3).
Steady-state cells hand their value over (the harness drops its reference), which is what a runtime
that gives the model to `update` does. The TEA table runs under two protocols:

* **runtime retains**: the DOM runtime keeps the rendered rows until the next render, as
  `forPosition`'s `s.b` does today — R1/R2 pin them at every render, R0 copies them before every
  `update`;
* **hands over**: the runtime keeps nothing `update` may write (the walk keeps rows' items, which
  are records and never written in place).

The baselines behave identically under both.

**Timing** is §15's loop, one pinned `node --expose-gc` process per variant, **five rounds**
(two cores in parallel, 2 and 3), each cell the median of the round medians. The machine was shared:
load average 4–17 on 32 threads, from other sessions' benchmarks and builds. Within-round
spread is §15's; **nothing below rests on a ratio under 1.25×** unless it says so. cow's 100 000-element
builds are not rerun (§15.7 has them: 21–39 s).

### 5.1 Correctness

`node rc/rc.mjs test` runs §15's differential test extended to both protocols: 484 checks per
variant, every intermediate array digested, inputs checked unchanged, and three new kinds of check:

* **escape**: an array is handed to JavaScript (`toJs`), then written in beni; JavaScript's copy
  must not move (the owner's example; the answer is the pin);
* **retention**: under "runtime retains", the rows the runtime kept are digested before and after
  every `update`;
* **kept twice**: a board is kept and ticked twice from the same value; both results must agree.

All six variants agree. `rc/unit.js` checks the in-place trie paths directly (share, persistent
write, writes through both roots, a count back at 1 under R1). Each check was shown to fail on a
broken build: deleting one `$dup` in R2's `History.edit` (the history corrupts), an unpinned `toJs`
(the escape check), R0's harness skipping one copy (kept-twice), a trie write that does not retire
its token (unit, R1 only — the old root, unique again, wrote into the new one), and in the list
half an identity `retain` (the retention check). The last two first **passed** with weaker
tests; both tests were strengthened until the broken build failed.

The mechanism was checked too, apart from the comparison: under R0, R1, R2 and R2-plain a
handed-over `UpdateLabel` returns the same rows object, a steady tick the same cells, a fresh
`reprice` the same array; under the baselines none do.

---

## 6. The array scenarios

Node, median of five round medians, and the ratio to adaptive. Every row is §15's scenario of the
same name; `results/rc.jsonl` has every cell (`node rc/rc.mjs tables`). Cells that allocate a
whole new array per message (`update every 10th`, `remove one`, `append 1000`) are GC-bound: their
within-round spread reaches 3× the median, and no ordering is claimed for them.

### 6.1 The TEA table, and what the runtime's retention does

| message (+ render) | n | adaptive | cow | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|--:|--:|
| update one, first | 10 000 | 54.0 µs | 0.90× | 0.84× | 1.23× | 1.32× | 0.90× |
| update one, steady, runtime retains | 10 000 | 55.0 µs | 0.92× | 0.86× | 1.15× | 1.33× | 0.95× |
| update one, steady, hands over | 10 000 | 58.5 µs | 0.78× | 0.84× | 0.99× | 1.12× | 0.86× |
| swap, steady, runtime retains | 10 000 | 44.3 µs | 1.06× | 1.03× | 1.18× | 1.18× | 1.08× |
| swap, steady, hands over | 10 000 | 43.6 µs | 1.08× | 0.95× | 1.21× | 1.22× | 1.02× |
| remove one + add one, steady, hands over | 10 000 | 339 µs | 0.67× | 0.67× | 1.25× | 0.88× | 0.80× |
| select (render only), hands over | 10 000 | 38.7 µs | 1.04× | 1.12× | 1.32× | 1.21× | 1.11× |
| update one, steady, hands over | 1 000 | 5.55 µs | 0.89× | 0.87× | 1.12× | 1.11× | 0.80× |
| swap, steady, hands over | 1 000 | 4.64 µs | 1.05× | 0.89× | 1.20× | 1.11× | 0.93× |
| select, hands over | 1 000 | 4.02 µs | 0.99× | 1.05× | 1.24× | 1.18× | 1.05× |

**With the runtime as it is written today, R1 and R2 never write the table in place.** The runtime
keeps the rows it rendered (`s.b`), so O7 pins them at every render, and the next message's write
finds them shared: it converts or copies exactly as adaptive does, and pays the counting on top
(1.15–1.33× at 10 000 rows in Node). The one exception proves the rule: in `remove one + add one`
the `AddOne` writes the array `Remove` has just built, which no render has seen, and R2 pushes onto
it in place (0.86–0.88×; R1 does too, and its `$dupA`/`$dropA` pair per element in `filter`'s
lambda eats the gain, 1.18–1.23×). R0 has to copy the rows before every `update` instead (S3) —
an O(n) copy per message, even for `Select` — and that is **not** slower than adaptive here (0.86×
retained), for §15.4's reason: the render walk visits every row anyway, and a copied plain array
walks faster than a trie.

**With a runtime that hands the model over, the writes do land in place** — the differential test's
mechanism line shows the same rows object before and after an `UpdateLabel` under R0, R1, R2 and
R2-plain — **and it buys nothing visible.** One in-place element write saves one trie path copy,
about a microsecond, next to a 40–60 µs walk. R1 and R2 stay 1.0–1.3× adaptive (R2 0.84–0.88×
on `remove one + add one`, as above), because every
message pays the record take (O4), the counted-record construction and core's generic `$dupA`s in
`get`, `indexedMap` and `filter`; R0 and R2-plain are 0.8–0.9×, and that gain is their plain
representation under the walk, the same one §15 measured for cow.

Chrome shrinks the overhead: R1 and R2 are 0.63–1.08× adaptive on every table message at 10 000
rows except `remove one, first` (1.37–1.47×) (§6.8).

### 6.2 Decoded data, never written

| op | n | adaptive | cow | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|--:|--:|
| count by category (`foldl`) | 10 000 | 47.8 µs | 0.37× | 0.92× | 1.38× | 1.39× | 0.84× |
| total price (`foldl`) | 10 000 | 148 µs | 0.83× | 0.87× | 1.04× | 0.90× | 1.05× |
| `filter` one category | 10 000 | 200 µs | 0.76× | 0.75× | 0.82× | 0.71× | 0.71× |
| 1 000 binary searches by `get` | 10 000 | 235 µs | 0.92× | 1.09× | 1.08× | 1.11× | 1.26× |
| count by category (`foldl`) | 100 000 | 1.09 ms | 0.89× | 1.03× | 1.20× | 1.00× | 1.23× |
| total price (`foldl`) | 100 000 | 1.22 ms | 0.94× | 1.00× | 1.22× | 1.10× | 1.27× |
| 1 000 binary searches | 100 000 | 348 µs | 0.91× | 1.01× | 1.07× | 1.10× | 1.18× |
| a page of 50 by `get` | 100 000 | 442 ns | 0.90× | 1.05× | 1.20× | 1.16× | 1.12× |

Nothing here writes, so every difference is overhead or process history. **The overhead is visible
only on the tightest generic loop**: `count` is a `foldl` whose lambda is one comparison, and
`Array.foldlHelp`'s `$dupA` on every element costs R1 and R2 1.38–1.39× at 10 000 elements and
1.0–1.2× at 100 000. Elsewhere the variants are within the noise of each other and of §15's
mixed-process effect (a read site is faster in a process that has seen fewer tries, which is why
cow and R0 lead). R2-plain's bare `a[i]` did not show a gain in these processes; §15.11 measured it
in isolation (2.2× on `count`). In Chrome R1 and R2 run `count` at 0.63–0.74× adaptive: the
overhead is not visible there at all.

### 6.3 A grid game

| op | cells | adaptive | cow | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|--:|--:|
| tick k = 1, first | 10 000 | 12.3 µs | 0.62× | 0.65× | 1.10× | 0.97× | 0.60× |
| tick k = 1, steady | 10 000 | 362 ns | 21× | 0.56× | 0.97× | 1.10× | 0.69× |
| tick k = 100, steady | 10 000 | 38.0 µs | 20× | 0.50× | 0.91× | 0.90× | 0.60× |
| tick k = 100, first | 1 000 000 | 2.80 ms | 166× | 1.52× | 1.09× | 1.00× | 1.76× |
| tick k = 1, steady | 1 000 000 | 428 ns | 9 712× | 0.48× | 0.93× | 0.87× | 0.54× |
| tick k = 100, steady | 1 000 000 | 45.9 µs | 10 107× | 0.44× | 0.85× | 0.81× | 0.43× |
| life step (reads only) | 1 000 000 | 238 ms | 0.98× | 1.03× | 1.11× | 0.98× | 1.03× |

**This is where writing in place pays, and representation decides how much.** The steady ticks
start from the kept board, so R1 and R2's first write finds it shared and converts it to a trie, as
adaptive does; after that their writes are in place along the trie path (transient-style) and
save the path copies: 0.81–0.93× at a million cells, and nothing at 10 000 (0.90–1.10×). R0 copies
the board once at the call (S3) and R2-plain copies it at the first shared write; both then write a
plain array in place: **0.43–0.69×, up to twice as fast as adaptive**, and the reads are plain too.
The price is on the first tick at a million cells, where a whole copy (4.1–5.0 ms) costs more than
adaptive's conversion (2.8 ms). A board that is created
fresh and handed over, rather than kept, never converts: under R1 and R2 it stays plain and gets
R2-plain's numbers.

### 6.4 Building in a fold

| op | n | adaptive | cow | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|--:|--:|
| collect by `push` | 1 000 | 95.6 µs | 5.3× | 0.14× | 0.20× | 0.16× | 0.18× |
| histogram of 100 000 samples | 1 000 | 8.71 ms | 7.6× | 0.14× | 0.28× | 0.24× | 0.26× |
| coin-change table | 1 000 | 128 µs | 3.5× | 0.31× | 0.39× | 0.30× | 0.27× |
| collect by `push` | 100 000 | 10.8 ms | (21 s, §15.7) | 0.47× | 0.45× | 0.45× | 0.56× |
| histogram of 100 000 samples | 100 000 | 26.7 ms | (39 s) | 0.19× | 0.26× | 0.27× | 0.31× |
| coin-change table | 100 000 | 13.1 ms | (21 s) | 0.41× | 0.57× | 0.47× | 0.45× |
| histogram, R0 copying at the lambda (S3 misapplied) | 1 000 | 8.71 ms | 7.6× | **8.2×** | — | — | — |

**The largest win in the report: 2–7× faster than adaptive**, for every in-place variant, because
every write is to an accumulator nobody else holds. R1 and R2 get it at run time through
`List.foldl`'s owned accumulator; R0 gets it statically only after inlining `List.foldl` with its
literal lambda (R4), and part of R0's lead is that inlining, not the write. Without the inlining,
and with S3 applied to the lambda as the owner's formulation literally reads, R0 copies per sample
and lands on cow's cliff (71 ms); an R0 that calls the persistent write instead lands on adaptive
(8.7 ms), which is why §4 gives closures no requirement.

### 6.5 Undo history, shared by design

| | adaptive | cow | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|--:|
| one edit, steady | 1.06 µs | 9.1× | 1.13× | **3.2×** | **2.1×** | **11×** |
| 100 undos + a `foldl` | 79.2 µs | 0.17× | 0.86× | 2.2× | 1.07× | 0.28× |
| retained: 101 versions of 10 000 | 178 KB | 7 901 KB | 178 KB | 186 KB | 190 KB | **7 905 KB** |

Every version is kept, so nothing is ever unique and **no variant writes in place** — correctly: the
retention check proves the kept versions never move. What is left is cost. **R1 and R2 are 2–3×
slower per edit** (3.4–5.8× in Chrome): `edit` dups the current array twice, and `List.take 100`
moves a hundred counted arrays through cons cells (`takeHelp`, then `reverse`), each read-out a
`$dupA` that finds a counted root and writes to it — two hundred stores to a hundred objects per
edit, O5's rule for uncounted containers doing exactly what it says. **R2-plain has no persistent
representation left**: every edit copies 10 000 elements (11×, cow's 9×), and the history holds
7.9 MB where the trie holds 178 KB — §15.8's result for cow, reintroduced.

### 6.6 Handing arrays to JavaScript

| op | n | adaptive | cow | R0 | R1 | R2 | R2-plain |
|---|--:|--:|--:|--:|--:|--:|--:|
| `toJs`, mapped (never written) | 100 000 | 6.7 ns | 0.91× | 0.95× | 1.28× | 1.24× | 1.03× |
| `toJs`, edited | 100 000 | 517 µs | 0.00× | 0.00× | 1.03× | 1.06× | 0.00× |
| `Math.max`, edited | 100 000 | 862 µs | 0.30× | 0.33× | 0.95× | 0.96× | 0.35× |
| a write after `toJs` handed the array out | 10 000 | 12.8 µs | 0.52× | 0.54× | 0.84× | 0.93× | 0.62× |
| a write after `toJs` handed the array out | 100 000 | 122 µs | 3.5× | 3.3× | 0.93× | 1.04× | 3.9× |

**The escape guarantee holds in every variant** (§5.1's escape check): `toJs` pins the array under
R1, R2 and R2-plain, and the next write copies. The pin itself is one store (1.2–1.3× a 6 ns call).
What the write then costs is the representation's: adaptive, R1 and R2 convert to a trie (~120 µs
at 100 000), R0 and R2-plain copy (~400–480 µs, 3.3–3.9×) — but the result is plain, so the next
`toJs` is free and the `Math.max` over it 3× faster.

### 6.7 Memory

The count costs nothing measurable per array: one property. A 10 000-row model retains 706–708 KB
under every variant; 101 history versions 178 KB (adaptive, R0), 186–190 KB (R1, R2: the roots'
counts and the transient tokens). A million-cell board after 100 ticks is 7.8 MB under R0 (its
one copy is an exact `slice`), 9.6 MB adaptive (a trie), and 10.2 MB under R1, R2 and R2-plain,
which keep the fresh board plain and write it in place: a board built by `push` keeps V8's growth
slack when it is never copied. The large differences are the ones above: R2-plain's and cow's
7.9 MB history.

### 6.8 Chrome

Three rounds of the same bundles in headless Chrome 153 (`rc/chrome.mjs`, `results/rc-chrome.jsonl`)
agree with every ordering above that clears 1.25×: builds 0.10–0.40× adaptive for every in-place
variant, steady ticks 0.16–0.49× for R0 and R2-plain and 0.53–0.67× for R1 and R2, history edits
3.4× (R2), 5.8× (R1) and 8.3× (R2-plain). Chrome is kinder to the counting: R1 and R2 are 0.89–1.08×
adaptive on the table's steady messages at 10 000 rows, and their generic-loop overhead on `count`
does not show.

---

## 7. What the counting costs where nothing is written

### 7.1 Per operation

`rc/probe-overhead.mjs`, Node, three runs, ns per operation, each loop against itself without the
operation:

| pattern | plain | R1 | R2 |
|---|--:|--:|--:|
| `foldl` over Ints, `$dupA` per element | 0.89 | 0.89 | 0.91 |
| `foldl` over records, `$dupA` per element | 6.2 | 7.6 (+1.4) | 8.1 (+1.9) |
| the same, plus the lambda's `$dropA` (R1) | 6.2 | 8.5 (+2.3) | — |
| `Array.get` of a record (a `Maybe`), `$dupA` | 4.2 | 5.5 (+1.3) | 5.5 |
| record update of a counted model, unique | 15.7 | 16.7 (+1.0) | 17.8 (+2) |
| the same, model shared (take + dup + drop) | 15.7 | 18.9 (+3.2) | 18.3 (+2.6) |
| call with an owned array the callee does not keep (dup + drop) | 0.51 | 1.23 (+0.7) | 0.64 (+0.1) |
| build + walk a cons cell with a count (every constructor counted) | 7.3 | 7.5 | 9.1 |

A `$dupA` on a number is free (the `typeof` test folds away); on a record it is a property miss,
1.3–1.9 ns. That is the whole read overhead of §6.2: one per element in a generic loop. R2's dup
is cheaper than R1's where it replaces an increment–decrement pair, and R2 has no drops.

### 7.2 Where the count can live

`rc/probe-storage.mjs`: a named property on the array costs nothing on reads (1.97 against
1.93 ms for two million) and 4 ns on creating a small array (13.7 against 9.6 ms per million). A
wrapper object costs the indirection on every read. **`Object.freeze` as the shared bit is out**:
reads of a frozen array were 10× slower (20.3 ms) and `Object.isFrozen` per write 24×.

### 7.3 One trap in V8

`rc/probe-builtins.mjs`: **`Array.prototype.concat` leaves its fast path when the receiver has a
named property**: 52 µs against 7.7 µs to append 1 000 to 10 000 elements (ints 57 against 3.8).
`slice` and element-wise loops are unaffected. The first full run used cow's concat-based copies and
put R1, R2 and R2-plain at 2× adaptive on `append`; the ports now copy with `slice`. A runtime that
keeps a count on the array must keep every builtin it calls on such arrays under this kind of watch.

### 7.4 Size

`node rc/rc.mjs size`: the seven scenario modules and core's `Array` and `List` as emitted, bundled
with the siblings external, `esbuild --minify`, brotli 11; and the sibling with `rc/rt.js`.

| | emitted beni, min | brotli | Δ | sibling + runtime, brotli |
|---|--:|--:|--:|--:|
| adaptive | 7 388 | 2 439 | — | 1 514 |
| R0 | 7 562 | 2 498 | **+59 (+2 %)** | 1 655 |
| R1 | 8 368 | 2 746 | **+307 (+13 %)** | 1 903 |
| R2 | 7 964 | 2 595 | **+156 (+6 %)** | 1 891 |
| R2-plain | 7 984 | 2 601 | +162 (+7 %) | **706** |

In the R1 source: 13 static dups, 9 dynamic, 18 drops (three of them per-type drop functions),
14 counted constructions and 9 uniqueness tests, over nine modules. R2 keeps the dups and tests.
R0's growth is mostly the inlined fold loops (R4), not the uniqueness. R2-plain's emitted code is
R2's minus every read call, and its sibling has no trie: 706 bytes, less than half of adaptive's.
These modules are array-heavy; the growth follows the number of functions that touch a counted
type and the number of generic `core` read sites.

---

## 8. The list half: does a run-time bit rescue one sequence type?

Research 38 §16 rejected one array-backed sequence type (B) because `x :: xs` copies unless a
static rule (C) proves the tail unique, and three ordinary shapes defeat the rules: an accumulator
in a record field, accumulators in a tuple, and retained lists that share tails. The question here
is whether reference information closes that gap. Two variants on §16's compiled modules
(`rc/lists.mjs`, `rc/lists/`):

* **R2 on B** (`rc/lists/rt-r2.js`): the sticky bit on sequences and on records and tuples that
  hold one (O4, O5). `x :: t` onto a unique view of a unique backing writes the free slot before it,
  in place; a full backing is regrown with as much room in front as it holds, so prepending is
  amortised O(1). `$tl` shares the backing (the tail is a second reader), `$hd` shares what it reads.
* **R0 on C**: scalar replacement of the fold's state — after R4, a record or tuple built fresh on
  every iteration and read only by the next one becomes one loop variable per field, and C's local
  builder applies to each list field (`rc/lists/decls.js`).

Three rounds, median, ratio to A (cons cells, today). The differential test (64 checks, with a
retention check that failed when `retain` was broken, §5.1) passes for all five.

| code | n | A | B | C | R0 | R2 |
|---|--:|--:|--:|--:|--:|--:|
| `x :: acc` in a `foldl`, then `reverse` | 10 000 | 201 µs | 185× | 0.19× | 0.19× | 1.6× |
| | 100 000 | 7.70 ms | 3 687× | 0.24× | 0.24× | 0.59× |
| accumulator in a **record field** | 10 000 | 242 µs | 158× | 121× | **0.18×** | **1.95×** |
| | 100 000 | 3.07 ms | 42 s | 31 s | **0.62×** | **2.8×** |
| accumulators in a **tuple** | 10 000 | 179 µs | 109× | 101× | **0.34×** | **0.89×** |
| | 100 000 | 2.07 ms | 14 s | 14 s | **1.08×** | **1.34×** |
| retained paths **sharing tails** | 10 000 | 165 µs | 3 094× | 2 620× | 2 861× | 2 853× |
| walk by `x :: rest` (`sum`) | 100 000 | 167 µs | 7.0× | 0.67× | 0.66× | **5.7×** |
| `List.map` | 100 000 | 2.27 ms | 1.08× | 0.99× | 0.90× | 1.40× |
| TEA `Add` + `Remove`, hands over | 100 000 | 2.70 ms | 1.09× | 1.30× | 1.03× | 1.41× |
| TEA `Add` + `Remove`, runtime retains | 100 000 | 2.62 ms | 1.13× | 1.11× | 1.08× | 1.28× |

* **R2 turns the record and tuple accumulators from quadratic to linear**: 42 s to 8.5 ms at
  100 000 for the record field. It is still 1.3–2.8× the cons list, because every step pays the
  record take and the headroom regrowth.
* **R0 does the same statically, and faster** (0.18–1.08× A): the fold's state is scalar-replaced,
  which is a local rule of the kind §16.3 already had.
* **Retained shared tails stay quadratic for every array representation**, R2 included: the parent
  path is read out of the list of paths, so it is shared, and `i :: parent` copies it. No reference
  information makes a value unique that is, in fact, shared.
* **R2 makes walks slower, not faster**: `x :: rest` over B allocates a view per step already
  (§16.4, 5–7× A) and R2 adds the shared-mark store; C's scalar view is what fixes walks.

So reference information closes two of §16's three holes, and a local static rule closes the same
two. It does not close the third, and it does not change §16's verdict: **keep `List` as cons
cells and `Array` beside it.**

---

## 9. What the pass would cost to build

**The analyses.** R1 and R2 need, in the backend, per function: the types of every binding (to
decide O5 — does this type hold an Array, or is it a type variable), liveness (last use, per
branch, and across the loop-carried variables of backend.md §8's tail-call loop), borrow signatures
(`collectO`, a fixpoint per strongly connected component, the same shape as the checker's
generalisation), and the insertion itself, including O4's take and one generated drop function per
counted record type (R1). R0 needs the same liveness plus freshness and consumed-uniqueness
summaries over field paths (S2, S4), and inlining of `List.foldl`/`foldr` with a literal lambda
(R4) to reach anything in a fold. None of it needs the whole program; all of it needs types in a
phase that today works on `Bir` shapes.

**Interfaces and incrementality.** Borrow signatures (R1, R2) and consumed-unique summaries (R0)
are part of a function's calling convention: a body edit that turns a Borrowed parameter Owned
changes the code every caller emits. They must go into the interface and its hash, like types, so
the M4 interface firewall sees them. R0's summaries are the more fragile of the two: they are
facts about *what a function does with its argument*, not only its type, so an edit that adds one
read of `model.rows` after the write flips `update` from consumed-unique to not: `update` silently
stops writing in place, its callers stop copying, and a program's speed changes with no diagnostic.

**Determinism** (rule 5) is not at risk: every inserted operation is a function of the input, and
the summaries are computed per module in dependency order, as interfaces already are.

**Effects and fibers.** Perceus needs explicit control flow because a skipped drop leaks in C. In
JavaScript a skipped drop only loses an in-place write, so a cancelled fiber (transparent-effects
§6.2), which never runs the rest of its body, leaves counts high and is sound. Dups are what must be
complete: a value passed to two fibers of an `and` group gets one per fiber, by O2, as for any
second holder. Continuations are one-shot (transparent-effects §5), so a suspension duplicates
nothing; a multi-shot continuation would have to dup every captured counted value at capture.

**Closures.** A JavaScript closure is not counted, so a capture is a holder that is never
released (O2): the captured value is shared for the rest of its life under R1 as under R2. Borrowed
captures for closures that provably do not escape (passed to a Borrowed parameter that only calls
them) would recover it; that is an escape analysis, not in the prototype. O8 covers the common case.

**`foreign`.** Every `foreign` parameter needs a declared ownership, and the sibling must honour
it: a sibling that keeps an argument it declared Borrowed, or returns a value it did not make
fresh, produces **a silent wrong answer**, and no check can see inside JavaScript. That is a new
clause in boundary.md §4 and a new burden on every platform package (trusted, but a mistake is
now a correctness bug, not a leak). The safe default is to pin every argument of an undeclared
`foreign`, which costs a store per call and loses uniqueness for anything that crosses.

**The markup runtime.** The runtime keeps what it rendered: `forPosition` and `forKeyed` keep the
list in `s.b` and skip the walk when the next one is identical (`platforms/browser/runtime.js`),
and every patched hole keeps its last value. Under O7 each of those is a pin, so **every array a
view renders is shared from its first render on**, and the next message's write copies it — §6.1
measures that as the "runtime retains" rows. To write a rendered array in place, the runtime has to
change protocol: give the model to `update` without keeping a reference to anything `update` may
write, and replace the `items === s.b` identity skip for a counted array by a version stamp the
write bumps (or no skip at all). Field identity (rule 8) is untouched for records, because records
are never written in place here — only arrays are.

**Size.** §7.4: +156 bytes brotli (R2) and +307 (R1) on 2 439 bytes of array-heavy modules, plus
~380 bytes of runtime; R0 +59. The growth follows the number of functions that touch a counted type
and the number of generic `core` read sites.

---

## 10. Verdict

**Can beni write in place in JavaScript by keeping its own reference information? Yes — it works,
it is sound with a garbage collector underneath, and the escape guarantee holds.** Whether it pays
depends on who else holds the array, and in the programs measured here the answer is usually
"someone":

| scenario | best in-place variant against adaptive | R1 | R2 | why |
|---|---|--:|--:|---|
| building in a fold | R0 0.14–0.47× | 0.20–0.57× | 0.16–0.47× | the accumulator is unique: **the one big win** |
| grid, steady ticks | R0 / R2-plain 0.43–0.69× | 0.85–0.97× | 0.81–1.10× | unique, but R1/R2 inherit the trie a kept board converted to |
| TEA table, runtime as written | R0 0.70–1.30× | 1.15–1.34× | 0.86–1.33× | the runtime keeps every rendered array: **never in place** across a render |
| TEA table, runtime hands over | R0 / R2-plain 0.67–1.12× | 0.99–1.32× | 0.84–1.22× | in place, but one element write hides behind a 40 µs walk |
| decoded, read only | — | 1.0–1.4× | 1.0–1.4× | a `$dupA` per element in generic loops (Node; none in Chrome) |
| undo history | — | **3.2×** | **2.1×** | shared by design; generic code pays a store per counted element it moves |
| an array written after JavaScript got it | — | 0.93× | 1.04× | pinned; R0 and R2-plain copy (3.3–3.9×) |
| lists: record/tuple accumulators on one array type | R0 0.18–1.08× A | — | 0.89–2.8× A | R2 closes two of §16's holes; a local static rule closes the same two |

1. **R1 never beats R2 in JavaScript.** They made the same in-place decision in every scenario,
   because the drops that distinguish them only ever lower a count that a garbage-collected
   program has no other use for. R1 costs more (history 3.2× against 2.1×, +307 against +156 bytes)
   and needs drops on every control path, which fibers and cancellation make hard. Of Perceus and
   Lean, what transfers is **borrow inference, dup placement, the record-field take, pinned
   constants and a one-way mark at a boundary**; drops, reuse and FBIP do not.
2. **R2 pays only where a unique array is written repeatedly** — building in a fold (2–6× faster)
   and steady writes to a large board — and costs 1.1–1.3× on the TEA messages in Node, 2–3.4× on a
   history, and up to 1.4× on the tightest generic read loop. **The TEA model gets nothing unless
   the markup runtime changes protocol**: the runtime keeps what it rendered, and a kept value is
   shared. With a hands-over runtime the writes do land in place, and the render walk hides them.
3. **R0 captures every win R2 showed, with no run-time state, no read overhead and +2 % code** —
   but only with the machinery around it: R4's inlining of `List.foldl`/`foldr` (without it the
   fold wins vanish), field-path summaries for records (`model.rows`, `g.cells`), result summaries
   so uniqueness survives a call, and the same runtime protocol for the TEA model. Its weak points
   are the owner's "copy first": a copy at a caller that cannot prove what the callee consumes is
   harmless at a message boundary (0.86× here, hidden by the walk) and catastrophic in a loop
   (histogram without inlining: cow's cliff, 8×). **Calling a persistent twin instead of copying**
   makes every miss cost exactly adaptive's write, never more, and is the form worth building. A
   wrong proof is a wrong answer, as §15.2 already found for plainness; the differential test
   caught a missing copy here too.
4. **R2-plain is the fastest in-place variant and the wrong representation.** Bare `a[i]` reads, no
   trie, a 706-byte sibling — and every write to a shared array is a whole copy, which brings back
   §15's cow cliff for any program that keeps old versions: 11× per history edit and 44× the memory
   (7.9 MB for 101 versions of 10 000). Uniqueness is not something a programmer can see in the
   source, so this is §16's argument again: a performance contract that depends on an analysis the
   programmer cannot see.
5. **Lists do not change.** R2 makes the single array type linear on record and tuple
   accumulators, but retained shared tails stay quadratic under every array representation, and
   walks get slower. Keep cons cells.

**Recommendation.** Keep §15's adaptive array as `core/Array`, with no counts in it. If beni wants
in-place writes, take them statically: **R0 with persistent twins** — S1 (a fresh value dead after
its write), R4 (inline `foldl`/`foldr` with a literal lambda), S2/S4 summaries over record field
paths in the interface, and at every call that cannot prove uniqueness, the persistent write rather
than a copy. That keeps every result of §6.4, costs nothing on reads, needs no `foreign` or markup
contract to be correct (a hands-over runtime would only unlock the TEA writes, which the walk
hides), and never makes a miss worse than today. Do not build R1. Revisit R2 only together with a
markup runtime that hands the model over and versions its `For` slots, and only if profiles show
writes in generic higher-order code that R4 cannot inline.

---

## 11. Reproducing

From `bench/arrays/`, after `zig build` at the root and `npm ci`:

```sh
node scenarios.mjs build && node rc/rc.mjs build && node rc/rc.mjs test && node rc/rc.mjs size
for r in 1 2 3 4 5; do RESULTS=results/rc.jsonl node rc/rc.mjs bench 2; done   # ~2.5 min a round
node rc/rc.mjs tables
CHROME=<chromium> node rc/chrome.mjs 3                   # after a bench on core 2; three times
node rc/rc.mjs tables results/rc-chrome.jsonl
node lists.mjs build && node rc/lists.mjs build && node rc/lists.mjs test
for r in 1 2 3; do node rc/lists.mjs bench 4; done       # ~6 min a round; B's 100 000 cells are 42 s a call
node rc/lists.mjs tables
node rc/probe-overhead.mjs r1; node rc/probe-overhead.mjs r2    # §7.1, raw runs in results/rc-overhead.jsonl
node rc/probe-storage.mjs; node rc/probe-builtins.mjs           # §7.2, §7.3
```

The files: the hand transformations in `rc/src/r0/` and `rc/src/r1/` (R2 and R2-plain are derived
from R1 by `rc/rc.mjs build`), the siblings in `rc/ports/`, the run-time helpers in `rc/rt.js`, the
harness with the ownership protocol in `rc/harness.js`, the trie unit checks in `rc/unit.js`; the
list half in `rc/lists.mjs`, `rc/lists-harness.js` and `rc/lists/`; raw cells in
`results/rc.jsonl`, `results/rc-chrome.jsonl`, `results/rc-lists.jsonl` and
`results/rc-overhead.jsonl`.
