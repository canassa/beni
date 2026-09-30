# Transparent effects — implementation plan

**Status:** plan, 2026-09-18. Written for the project owner to read *before* any
effects code exists, because several of the questions below are decisions and not findings, and they
are marked as such (§5). **All eight §5 decisions were taken by the owner on 2026-09-30**, each
recorded under its question. The first slice, inference in the checker, is specified in
[`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md) §14.

**What this is.** [`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md)
— **P2** throughout — is the design argument. This is the work-up against the repository as it
stands at `b41e860`: what the landed work discharged, what it newly complicated, where the two bits
would physically live, in what order the slices land, and what can go wrong at exit 0. Corrections
to P2 itself are in P2, each dated; this file does not repeat them.

**What changed under P2 since it was written.** Both of CLAUDE.md's blockers cleared: no-currying
landed (`TypeStore.Structure.Func` is `{ params: Range, result: Var }`,
`src/check/TypeStore.zig:249`), and the tail-call loop landed and took `List.foldl`/`foldr` out of
`foreign` with it (`bbfc869`, `backend.md` §8, `core/List.beni:68`, `:86`). In between, **static
dispatch** was adopted (2026-09-18, [`static-dispatch-spike.md`](../docs/design/static-dispatch-spike.md)
normative) and P2 does not mention it. Most of §2 below is that collision.

---

## 1. The state of the argument, on one page

**What P2 specifies and treats as decided.** Two inferred booleans per function — `suspends`, the
colouring bit, and `impure`, which only constrains the optimiser (§2). No effect syntax except one
keyword on a `foreign` declaration, `pure | impure | suspends` (§3.1). Higher-order functions are
bit-polymorphic by inference, so `List.map` serves a pure and an effectful callback with one
definition (§2). Deferral is a thunk `() -> a`; there is no `Task` (§2, §3.5). Lowering is **CPS
onto a fiber runtime this language owns**, shape L1, decided 2026-09-15 on `research/16` §2.4 —
56 ms to unwind a cancelled fiber against 301 ms under native `async` (§7.1) — with a `foreign
suspends` primitive returning either a value or a suspension, a value resuming inline on the same
stack in the same tick (§7.2). Typing is a two-point lattice `false ⊑ true` with flag variables,
riding beside unification as obligations rather than inside it (§4.1).

**What P2 leaves open.** `sync` is drafted and postponed (§3.2); bare `let` items (§3.3) and
parallel `and` (§3.4) are separable surface changes; §4.3's extraction hazard has a diagnostic and
no annotation; §7.6's double translation is an open question; §11 lists eleven questions.

**§10's prerequisite list, item by item, as of today.**

| # | P2's prerequisite | State |
|---|---|---|
| 0 | enumerate the platform's primitives and imposed signatures | **discharged** by `research/17-platform-primitives.md`, and the answer is *neither* of P2's two branches: the `foreign` keyword is enough (54 of 71 projected primitives are first-order), but `sync` needs an argument position and §8's `sync_boundary` is not droppable. **Newly complicated**: report 17's grep looked for a parenthesised arrow in a `foreign` signature; a `foreign … where` clause hides one where that grep cannot see it (§2.1) |
| 1 | `TypeStore.Func` is curried | **landed.** And the cost moved: `Func` is now 12 bytes and already the widest `Structure` payload, so report 17 §6.3's "free in size" is false (§3) |
| 2 | `checker.md` §6.3's "nothing else may be added to `Kind`" needs amending | **discharged without amendment.** Static dispatch added a per-variable constraint set beside `kind` and `equatable` on `TypeStore.Flags` (`src/check/TypeStore.zig:149-169`) and `Kind` is untouched. That set *is* the precedent for a flag variable, and its measured cost (20.3 % of check, report 19 §2.1) is the warning that comes with it |
| 3 | `boundary.md` §4 shape (b) must be rewritten | **still open**, and it now has two clauses to write rather than one: shape (b)'s `Task e a` is replaced by a `foreign` with bits, and check 4 (sibling arity, `16b1c0d`) has to gain a statement about what a sibling may do with an evidence parameter (§2.1) |
| 4 | `fast-compiler.md` §3.1's Decided-2026-09-13 bullet must be marked reversed | **still open.** §3.1 now carries a *different* reversal (static dispatch, 2026-09-18) in exactly the style this item wants; the effects bullet is untouched |
| 5 | the fiber runtime | **still open** and still the largest single deliverable. `research/16` §5 is its specification |
| 6 | the formatter | **partly landed** — the trailing-`<\|` lambda rule shipped in the no-currying slice A. Two keywords remain unwritten |

**What the two research reports settled.** `research/16-fibers-and-concurrency.md` is the lowering
decision (own the resume callback; prompt cancellation is free, and unavailable otherwise) and the
runtime's field-for-field specification: a 692 B fiber record, a `finalizers` list rather than
`try`/`finally`, a macrotask escape every ~64 resumptions. `research/17-platform-primitives.md`
settled §10 item 0 and found the ordering constraint this repository then obeyed — the trampoline
before effects, or P2's headline example threads scheduler objects through a JavaScript `for` loop.
Both reports predate static dispatch. Neither knows about evidence parameters.

---

## 2. New interactions P2 never considered

### 2.1 Evidence parameters

Since 2026-09-18 a constrained declaration carries hidden leading parameters, one per method
constraint, `$m$<k>`, and every constrained call site passes a function
(`static-dispatch-spike.md` §8.1, §8.2). Measured against the installed binary:

```js
const Main$countEq = ($m$0, $in$1, value$2, $in$3) => { … $m$0(x$4, value$2) … };
Main$countEq(Main$eq$prim, /* list */, 1, 0);
```

**Is a piece of evidence ever effectful?** Yes, as soon as effects exist, and nothing in the grammar
stops it today. A `where` constraint is `lower_ident '.' lower_ident ':' Type`
(`static-dispatch-spike.md` §2.1) with no restriction on the type, so `where a.fetch : a, Url ->
Response` is already writable and its evidence is an ordinary `pub` beni function. When that
function suspends, the evidence value is a suspendable closure. For evidence that is only ever
*called from beni* — `Dict.insert`'s `$m$0`, `List.sort`'s — that is fine and is exactly P2's bit
polymorphism doing its job: one `Dict.insert`, pure or suspending comparator, no signature change.

**Where it is not fine, and it is in `core/`.** `core/List.beni:100` and `:114`:

```elm
pub foreign eq : List a, List a -> Bool
    where a.eq : a, a -> Bool
```

and `core/List.js:37` is a **JavaScript loop that calls beni evidence**:

```js
export const eq = (m0, xs, ys) => {
  let a = xs, b = ys;
  while (a.$ === 1 && b.$ === 1) { if (!m0(a.a, b.a)) return false; a = a.b; b = b.b; }
  return a.$ === b.$;
};
```

That is report 17 §1's **kind (i)** — a host-called beni callback — and it is `foldl`'s miscompile in
the position static dispatch created. Under P2 §7.1 a suspending `m0` returns a *suspension object*;
`!suspension` is `false`; the loop walks to the end and answers `a.$ === b.$`. So for a type whose
`eq` suspends, `[ x ] == [ y ]` is **`true` for any x and y**, at exit 0, with no diagnostic. The
same hole is in `compare` (`core/List.js:56`): `o !== "EQ"` is true of a suspension object, so it is
returned as the `Order`.

Report 17 §3.4 closed this question by grepping `foreign` signatures for a parenthesised arrow;
after `bbfc869` that grep returns nothing, and `backend.md` §8 records "the count of higher-order
`foreign` values in the repository is zero". **The count is two.** The function type is in the
`where` clause, not the signature. `boundary.md` §4's check 4 counts the sibling's parameters and
cannot see what it does with them.

Three ways out, and the owner picks one (§5 decision 6): **(a)** constrain the evidence — a
`must_not_suspend` obligation where a well-known constraint is resolved, so a `Remote.eq` that
performs is a compile error at its own declaration and `core/List.js` is safe by typing;
**(b)** move `eq`/`compare` into beni over a new uncons primitive, which the adoption considered and
declined (`boundary.md` §4); **(c)** teach `core/List.js` the suspension protocol — kind (ii) —
which widens the `foreign` surface against CLAUDE.md rule 6.

**Can a `where`-named method suspend at all?** Under (a) the rule is narrow: only the **well-known**
`eq` and `compare` are constrained pure, because only they reach JavaScript (`core/List.js`) and
compiler-generated code (derivation, below). A user-written `where a.fetch : a, Url -> Response`
suspends freely — a capability record expressed one method at a time, which is P2 §9.3's own
recommended granularity mechanism arriving for free.

**Where the bits live on a method constraint's function type.** Nowhere new.
`TypeStore.MethodConstraint.fn_var` (`src/check/TypeStore.zig:177`) is a `Var` whose content is a
`structure.func`, so it carries whatever a `Func` carries. In the interface a constraint is a
`(SymbolIndex, TermIndex)` pair (`src/resolve/Interface.zig:164-167`) and the term is a `func` term,
so it costs whatever §3's encoding costs — nothing extra.

**What does change is unification.** `unify`'s flex case merges two constraint sets and unifies the
two `fn_var`s of a same-named pair, reporting `method_constraint_mismatch` on failure
(`checker.md` §6.2). If the bits are unified by equality inside `unifyFlat`
(`src/check/Solve.zig:881`), a variable used once with a pure callback and once with a suspending
one is a hard error exactly where P2 §4.4 wants `false ⊑ true`. **So the bits must never be compared
inside `unifyFlat`**; a `Func`/`Func` unification records a `flag_le` obligation in the per-rank list
and the fixpoint is taken post-solve, next to `dischargeEquatable` (`src/check/Solve.zig:1811`).
This is the same shape report 17 §6.3 prices for the constant `sync` bit, applied to the inferred
ones.

**Derived `eq` and `compare` are pure by construction — and their evidence is not.** A derived
function is compiler-emitted JavaScript over the representation
(`static-dispatch-spike.md` §9), so its own body performs nothing. But a parametric one takes
evidence: `Maybe$eq($m$0, x, y)`. If `$m$0` may suspend, the derived function is bit-polymorphic and
needs §7.6's second body — per type, per method, in every module that declares a type. Report 19
§5.1 measures derived functions at 3 159 bytes of a 68 791-byte floor and 197.6 bytes each; doubling
that is the price. Under decision (a) above the question disappears: derived functions stay
single-bodied and `==` and `<` never suspend.

**Eta-expanded evidence is a lambda the source never wrote.** `List$eq((l, r) => List$eq(Main$eq$prim,
l, r), xs, ys)` (`static-dispatch-spike.md` §8.2). P2 §4.2 rule 4 gives a lambda its own flags; this
one has no region of its own, so its flags are the wrapped target's and any diagnostic about them
must point at the *call site that created it*, not at a lambda. One line of spec, easy to get wrong.

**One thing dispatch makes better.** P2 §9.1's partial answer to silent colouring is "a `beni diff`
that computes the published interface, including both bits". Dispatch already put inferred method
constraints into the interface, and report 19 §4 measured the churn (an unannotated `pub`
declaration's interface moves 6.5× more often). An inferred `suspends` bit rides the same channel,
so `beni diff` is a stronger answer than it was — and the cost lands, again, on unannotated `pub`
declarations.

### 2.2 The tail-call loop and a suspendable body

What the loop emits today, read off the installed binary for `core/List.foldl`:

```js
const List$foldl = ($in$0, $in$1, func$3) => {
  List$foldl: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.$ === 0) { return acc$2; }
    else { const x$4 = xs$1.a; const rest$5 = xs$1.b;
           $in$0 = rest$5; $in$1 = func$3(x$4, acc$2); continue List$foldl; }
  }
};
```

The suspendable copy of the same function has to be, in P2 §7.3's own words, Koka's
`{ tailcall: while(1) { … } }` with the `_yielding()` test at each suspension point:

```js
const List$foldl$s = ($in$0, $in$1, func$3) => {
  List$foldl$s: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.$ === 0) { return acc$2; }
    const x$4 = xs$1.a, rest$5 = xs$1.b;
    const r = func$3(x$4, acc$2);
    if ($yielding(r)) return $suspend(r, (v) => List$foldl$s(rest$5, v, func$3));
    $in$0 = rest$5; $in$1 = r; continue List$foldl$s;
  }
};
```

Four findings, and three of them are good news.

1. **The loop's state *is* the parameter list, so the continuation is an ordinary call of the same
   function.** No state record, no hoisted locals, none of L2's machinery: `backend.md` §8 already
   guarantees every carried value has a parameter slot, which is exactly the live set a resume
   needs. This composes better than Koka's, which reconstructs parameters from a live-set analysis
   into a synthesised `_mlift_…` that P2 §7.4 names as the outcome to avoid.
2. **The per-iteration `const` prologue is what makes it correct**, and `backend.md` §8's rejected
   alternative — Elm's in-place reassignment — would have been a miscompile here too, for a second
   reason. A continuation must close over *this* iteration's `rest$5` and `x$4`; under in-place
   reassignment it would read whatever the loop reached before parking. §8 already argues this for
   `\x -> x + n` closures; effects make it argue itself twice.
3. **The continuation must never close over `$in$<i>`.** Those slots are assigned, so a closure over
   them is the same bug in a new place. The rule for the spec: a suspension point captures the
   prologue `const`s and the freshly computed next values, never a slot. `emit/` golden required.
4. **Evidence parameters are loop parameters** (`backend.md` §8, "Evidence parameters"), and
   polymorphic recursion means "evidence is loop-invariant" is not a rule. So a continuation has to
   forward `$m$k` too, and when `$m$0` is carried it must forward the carried value and not the
   original. The existing `TailCallEvidence` fixture is the template.

**What does not compose.** `backend.md` §8 leaves mutual recursion as a real stack frame (§14
question 5). A pair of mutually-recursive suspendable functions running the §7.2 *fast path* — every
primitive completing synchronously — grows the JavaScript stack exactly as it does today, because
nothing returns to the scheduler. P2 §7.3's "a tail call between suspendable functions passes the
caller's continuation along" is a second mechanism and it is not the loop; it has to be specified
separately or the fast path is a stack bomb where the slow path is not.

### 2.3 Decision trees inside a suspendable body

`backend.md` §7 is spec'd and being implemented now. Its shapes: a node with three or more labels is
a `switch`, each case body is a block ending in a terminator; a leaf reached from two or more paths
is written once and reached by `break $j$<d>$<b>` out of a labelled block; an expression-position
tree gets a `let $t$n` and a `$c$<d>` wrapper; bindings are member chains rebuilt at the leaf.

- **A labelled block is not a join point.** P2 §7.1 makes join points mandatory, citing Lean's
  exponential blow-up and Koka's 2^N. §7's `$j$<d>$<b>` blocks share a *leaf*; a CPS join point
  shares *the rest of the function after a suspension*, and it must be a named closure because a
  resume re-enters from outside and a `break` label does not survive a `return`. Two sharings, two
  mechanisms, and the spec must say so or the first implementation will try to reuse the labels.
- **In tail position there is nothing to join, which is most cases.** §8's `tailStmts`
  (`src/js/Lower.zig:1099`) lowers a tail-position `case` straight to statements whose arms `return`
  or `continue`. A suspension there returns a continuation and nothing follows it. The join point is
  needed exactly for a **non-tail** `case` whose arms suspend — today's `$c$<d>` wrapper — where
  `$t$1 = …; break $c$0;` has to become a call of one join closure taking the arm's value.
- **`break` and `continue` still work from inside a `switch`**, which `backend.md` §7 verified by
  hand on Node 24, so a suspension inside a `switch` case inside a shared block inside a loop is
  mechanically fine.
- **§7's "an occurrence is a member chain, not a name" is a dividend**: the live set at a suspension
  point is the scrutinee plus the loop parameters, not one `const` per tree edge — exactly what §7
  rejected Maranget's usual `const $p$k` presentation for. The continuation closure stays small.
- **"The scrutinee is evaluated exactly once" stops being an optimisation.** §7's `bindSubject`
  binds only when the tree reads the root more than once; a scrutinee that is itself a suspending
  call must be bound once whatever the read count is.

### 2.4 The headline example, now that the folds are beni

`core/List.beni:164`: `map xs func = foldr xs [] (\x acc -> func x :: acc)`; `:86`:
`foldr xs acc func = foldl (reverse xs) acc func`; `reverse` is `foldl xs [] cons`; `foldl` is the
loop of §2.2. Everything on the path is beni. So **`fetchAll ids = List.map ids (\id -> getUser id)`
lowers correctly in principle**: the callback's `suspends` bit propagates into `foldl`'s, `foldl` is
double-translated or emitted suspendable, and no JavaScript loop ever sees a suspension object.
Report 17 §0 finding 2 is discharged in fact.

**What still breaks is the order.** `foldr` is `reverse` then `foldl`, so `map`'s callback runs
**right to left over the source list**. Confirmed against the installed binary:

```elm
main = Node.printLines (List.map [ "a", "b", "c" ] (\x -> Debug.log x "visit"))
```

prints `visit: "c"`, `visit: "b"`, `visit: "a"`, then `a b c`. Today that is observable only through
`Debug.log`. Under direct-style effects it contradicts P2 §5's *"strict, left to right, in source
order"* in the document's own flagship line: `fetchAll` would fetch the last id first. The same
holds for every `List` function built on `foldr` — `filter` (`:181`), `concat` (`:329`), `filterMap`,
`partition`, `unzip` — and `String.foldr` through `List.foldr`.

This is a `core/` change, not a language one: `map` becomes `reverse (foldl xs [] (\x acc -> func x
:: acc))`, at one extra list of *n* cells, or `foldr` gets a right-to-left implementation that is not
`reverse`-then-`foldl`. It is cheap now and it is a silently wrong program later. `foldr`'s *own*
right-to-left order is correct and must not change.

**What else remains.** `List.map2`–`map5`, `List.sortWith`, `Dict.insertHelp`/`removeHelp`/`mapTree`
are non-tail self-recursive (`backend.md` §8's second list). Under CPS their frames become heap
closures, which is an improvement; on the §7.2 fast path they stay real frames and overflow where
they overflow today. Unchanged by effects, worth not being surprised by.

### 2.5 Check 4, `sync`, and report 17's four requirements against today's code

Report 17 §6.3 prices Branch B as one bool on `Structure.Func`, one `Term.Tag`, one obligation kind,
and (from the diary, 2026-09-16) a witness in the interface. Restated:

| Requirement | Today | Verdict |
|---|---|---|
| `sync: bool` on `Structure.Func` | `src/check/TypeStore.zig:249`, `Func = struct { params: Range, result: Var }`, 12 bytes | **no longer free.** Report 17 wrote this when `Func` was `{param, result}` at 8 bytes and `App`/`Record` were the 12-byte maxima. `Func` is now the joint maximum, so one added byte grows `Structure` 16 → 20, `Content` 20 → 24 and `Descriptor` 40 → 44. §3 has two zero-growth encodings |
| a `Term.Tag` value | `src/resolve/Interface.zig:177-201`; `Tag` is a `u8` column with 9 of 256 used, and `func` already spends both operand words | **free, still.** `func_sync` (and `func_impure`, `func_suspends`) are tag values and cost no word |
| an obligation kind | `src/check/Solve.zig:128`, `Kind = enum { equatable, interpolatable, tuple_index, method }`; registered from inside `unify` and drained by `dischargeObligations` (`:1767`) | **free.** A fifth value and one discharge arm beside `dischargeEquatable` (`:1811`) and `dischargeMethod` (`:2410`) |
| a witness in the interface for §8's chain | `checker.md` §7 keeps `Interface.Provenance` **out** of the record on purpose — it is meaningless once the Bir is gone and must never be hashed with what M4 caches | **the unsolved one.** P2 §8's `must_not_suspend` names call sites in other modules with spans; an interface carries types |

On the witness, two shapes and a recommendation:

- **One hop per module.** The chain stops at the boundary: *"`view` is `sync`, but it suspends.
  `view` calls `renderRow` (View.beni:12); `renderRow` suspends."* Needs nothing in the interface
  beyond the bit already there. **Recommended for v1.**
- **A full chain**, which needs a per-module side artifact of `(value → the one callee that made it
  suspend)` cached beside the interface and deliberately **excluded from the hash**, or a body edit
  in a leaf module re-checks its dependents and `fast-compiler.md` §8.1's firewall stops meaning
  anything. That is a real M4 design decision and should not be smuggled in with a diagnostic.

**Check 4's blind spot is the same hole.** It counts a sibling's parameter list lexically
(`boundary.md` §4, `16b1c0d`); it cannot see that `core/List.js` calls `m0` from a `while` loop. The
`sync` demand in an argument position is what closes it, and the closure is: a `foreign`'s
`where`-constraint types are `sync` by construction unless the platform writes otherwise.

---

## 3. Where the bits live, and what they weigh

**Measured**, by replicating the declarations of `src/check/TypeStore.zig:132-290` standalone under
Zig 0.16 (`@sizeOf`, x86-64):

| | `Flags` | `Func` | `Structure` | `Content` | `Descriptor` |
|---|---:|---:|---:|---:|---:|
| today | 12 | 12 | 16 | 20 | 40 |
| + two constant bits on `Func` (2 × `u8`) | 12 | 16 | 20 | 24 | **44** |
| + two flag **variables** on `Func` (2 × `u32`) | 12 | 20 | 24 | 28 | **48** |
| + two bits on `Flags` (flex/rigid) | **12** | — | — | — | 40 |

`Descriptor` is a `MultiArrayList` column set, so what actually grows is the `content` column: 20 →
24 (+20 %) or 20 → 28 (+40 %) per type variable, on every program whether or not it uses effects.
Two bits on `Flags` are **free** — that struct has padding — which is worth knowing but is the wrong
place: the bits belong to a function *type*, not to a variable.

**Two zero-growth encodings, either of which keeps `Descriptor` at 40 bytes:**

1. **Steal the top bits of `params.len`.** A `u32` length for a parameter list is absurd by four
   orders of magnitude; two bits in its high end cost one mask on every `paramCount`. Works for
   *constant* bits (`sync`, a `foreign`'s declared ladder); does not hold a variable.
2. **A two-word header in `extra` before the parameter range.** `Func.params` already points into
   `extra`; define `extra[params.start - 2 ..][0..2]` as the two flag vars. `Func` stays 12 bytes
   and nothing in `Content` moves; the cost is 8 bytes of `extra` per function type and one
   indirection on `unifyFlat`'s hot path. This is the encoding that holds flag **variables**.

**The interface.** `Interface.Term.func` spends `lhs` on an `extra` range and `rhs` on the result
(`src/resolve/Interface.zig:180-184`), so constant bits are three spare `Tag` values and cost zero
words; a flag *variable* needs one word, which the same two-word `extra` header supplies.
`Quantified` is already `words = 4` after dispatch (`:146`) and its flag word packs `kind | equatable
<< 8`, leaving bits 9–31 free — so if flag variables are ever quantified like type variables, they
fit without a fifth word. `Interface.Value` (`:204-212`) is `{ name, is_foreign, scheme }`; a
declaration-level `suspends` is readable off the scheme's body and needs no column.

**What to measure, and the bound to hold it to.** The instrument is the one dispatch used:
`zig build bench -- --generate=100000`, best of 5, ABBA-interleaved, `--jobs=1`, plus
`Solve.Counters` (`src/check/Solve.zig:63`) gaining `flags_created / joined / promoted` declared
before there is anything to count, as the dispatch counters were.

- `fast-compiler.md` §2's budget is **> 250k LOC/s** for checking. Today's check is 86.6 ms for
  100 159 lines (report 19 §2.1, B column) — about 1.16 M LOC/s — so the budget is not the binding
  constraint and quoting it would hide a regression.
- The binding constraint is the **regression**, and dispatch is the precedent: it cost **20.3 % of
  check on code that never uses the feature** and 48 % of emit. A second 20 % is most of the
  headroom. **Propose the acceptance bound up front: ≤ 10 % of `check` and 0 % of `emit` for a
  program with no suspending call, with every existing `emit/` golden byte-identical.**
- Output size has its own bound. Double translation (§7.6) emits two bodies per bit-polymorphic
  function, and `List.map`/`filter`/`foldl` are bit-polymorphic, so **without DCE the floor every
  program ships roughly doubles for `core/List`**. Report 19 §5.1 measured that floor at 68 791 raw
  bytes and blamed 3 159 of it on derivation nothing calls. Bound: the floor may not grow at all for
  a program with no suspending call — which means double translation lands **after** DCE, not
  before (§4, §5 decision 2).

---

## 4. Slices

Style and discipline follow [`static-dispatch-spike.md`](static-dispatch-spike.md)'s plan §8: spec
section written or confirmed first → implement → fixtures that fail before and pass after, proved by
stashing → three gates → read-only review → commit → diary entry. A slice that cannot be finished is
not half-landed.

| Slice | Spec first | Touches | Fail-first fixtures | Measurement |
|---|---|---|---|---|
| **E0 — promote the proposal** | P2 becomes normative in place, the way `static-dispatch-spike.md` did (file name historical, document normative); no section renumbered. Write the §5 decisions into it as decided, and fold §2 of this plan in as new sections at the end | docs only | — | review only |
| **E1 — the bits exist and are inferred** | P2 §3.1 (the `foreign` keyword), §4.1, §4.2. No lowering, no runtime, no error: the compiler infers `suspends`/`impure`, unifies them by obligation, generalises them, writes them to the interface and renders them | `Parse`, `Bir`, `TypeStore.Func`, `Solve` (`unifyFlat`, a `flag_le` obligation, `generalize`), `Schemes`, `Interface`, `Render`, `dump --stage=types\|interface\|raw`, formatter | `check/good/ForeignEffectLadder` + `.types` golden; `check/good/EffectsInferredAcrossModules` + `.iface`; `check/bad/ForeignEffectMissing`; a `--stage=raw` determinism module set | the §3 bound: check ≤ +10 %, emit ± 0, `Descriptor` size stated |
| **E2 — `sync`, and the boundary it closes** | P2 §3.2 rewritten for the type position (report 17 §6.3 Branch B), P2 §8's three codes, `boundary.md` §4 check 1 + check 4 clauses, §5.4's promise given a mechanism | `Solve` obligation kind + discharge, `Interface.Term.Tag`, grammar, `boundary.md`, the witness of §2.5 | `check/bad/SyncSuspends` (the chain); `check/bad/SyncBoundaryArgument`; `check/bad/SuspendingEqEvidence` — a suspending `eq` on a type used in a `List`, which is §2.1's miscompile turned into a diagnostic; `check/bad/MainSuspends` | diagnostic goldens beside Roc's, as report 19 §7 did |
| **E3 — L1 lowering, synchronous only** | P2 §7.1, §7.2, §7.3 extended with §2.2 and §2.3 of this plan. A `foreign suspends` whose JavaScript always returns a value: the fast path and nothing else. No fibers, no scheduler | `src/js/Lower.zig` (`tailStmts` `:1099`, `caseExpr` `:3573`, `functionOf` `:778`), `JsIr` | `run/SuspendFastPath`; `run/SuspendInLoop` (the §2.2 shape, 1 000 000 iterations); `run/SuspendInCase` (a suspension in a non-tail `case` arm — the join point); `emit/SuspendableLoop` golden | emit throughput; `js_bytes` for a program with no suspension unchanged |
| **E4 — the fiber runtime** | `research/16` §5.2, §5.3 as written; P2 §6.1–§6.5, §7.5 | a new platform-side runtime, `platforms/node/runtime.js`, the `Task`/`Fiber`/`Scope` beni modules | `run/SpawnJoin`, `run/ScopeChildren`, `run/BracketCancel` (finalisers run at cancel time, LIFO), `run/RaceLosersCancelled`, `run/QueueTakerCancelled` | `research/16` §6's missing experiment: a `requestAnimationFrame` latency histogram at budgets 16 / 64 / 512 / 2048, in Chrome and Firefox (P2 §11 Q3a) |
| **E5 — double translation** | P2 §7.6, decided on E4's numbers | `Dispatch`-shaped side table for which body a call site takes; `Lower` | `run/BitPolymorphicBothWays`; `emit/DoubleTranslation` | output size against the E3 floor; the R5/R6-shaped runtime programs of report 19 §6 |
| **E6 — surface sugar** | P2 §3.3 (bare `let` items), §3.4 (`and`) | parser, formatter, checker | `parse/good`, `fmt`, `check/bad/DiscardedValue`, `run/ParallelBindings` | none beyond the gates |

**Independence.** E1 is the only hard prerequisite for everything else. E2 depends on E1 and on
nothing else, and it is worth landing *even if effects are never finished*: it is what gives
`boundary.md` §5.4 a mechanism, what closes check 4's blind spot, and what makes §2.1's `List.eq`
hole a compile error. E6 is independent of E1–E5 entirely and P2 §3.3 says so ("separable"). E3
depends on E1; E4 depends on E3; E5 depends on E4 **and on DCE** (§3).

**Where to spike rather than go straight to master.** The dispatch precedent — branch, build it all,
measure, report, then decide — was worth it because the argument turned on unmeasured numbers.
Applying the same test:

- **E1 and E2 go straight to master.** Nothing about them is unmeasured in a way a branch would
  settle; the cost is a struct field and an obligation kind, both with known analogues, and the
  §3 bound is checkable on the first commit. E2 is independently useful.
- **E3 + E4 are the spike.** `research/16` §6 lists what its own figures do not cover — no figure
  was measured in a browser, `Queue` and `RateLimiter` were reasoned rather than read, the
  parent-chain cancellation check was never measured — and P2 §11 Q3(a)(b)(c) are three unmeasured
  constants in a runtime with no beni precedent. Branch `spike/effects-runtime`, deliver
  `research/2N-effects-runtime-results.md`, decide on it.
- **E5 is decided by E4's report**, not by a spike of its own; P2 §11 Q7 already frames it as
  "whether double translation is worth building at all".

**As built, the first slice (2026-09-30).** Built to P2 §14 and `checker-v2.md` §26, not to the table's
`Touches` column: the bits do **not** live on `TypeStore.Func` and `Solve` has no `flag_le`
obligation. A class is a union-find class of the store — a function type, or an application of a
nominal type whose body holds a function (§14.5) — so unification merges classes for free, and
generation, solving and instantiation only *record* edges (`callee ⊑ ambient`), seeds, joins,
zips, and which own-scheme variable each copy came from. `src/check/Effects.zig` runs after P5:
it joins, orders the declarations by those records into SCCs, and solves each component's
summary as a least fixpoint on the ladder `pure ⊏ impure ⊏ suspends`. A summary is a class list
(rung plus a 64-bit dependency mask) and a site list of paths into the scheme; it is the
interface's new effect block (interface format 9, frontend artifact 9, cache entry 7), and an
importer applies it at instantiation. An annotated declaration's two readings of its annotation
are paired by position instead of walked. `foreign` values carry a rung word (`foreign pure f`;
`foreign_effect_missing`, `unknown_foreign_effect`); `Debug.log`, `Debug.todo` and
`Html.targetValue`/`targetChecked` are `impure`. `dump --stage=types|interface` print `!impure`,
`!suspends`, `!e1` and `-- evaluates: impure`; diagnostics print no effects. No emitted byte moved:
no `emit/` golden and no run hash changed. Fixtures: `check/good/Effect*` (higher-order, evidence,
recursion, nominal, across modules), `check/good/core/EffectForeignRungs`,
`check/good/core/EffectSuspendsAcrossModules`, `parse/bad/core/{ForeignEffectMissing,UnknownForeignEffect}`,
a types-dump black-box test, and a cache test whose dependency flips a bit across the firewall.
**Measurement**: `beni check --jobs=1 --no-cache` over the 100 159-line generated corpus retires
772.3 M → 805.4 M instructions (+4.3 % of the process; about +7 % of the check phase, inside the
§3 bound of +10 %). Of the +33 M, recording is about +7 M and `Effects.run` the rest. `zig build
bench -- --generate=100000` on a loaded machine: check median 69.7 → 77.1 ms over ten ABBA-ordered
runs each, measured on an earlier build of the slice about 5 M instructions heavier (wall time, noisy; the instruction count is the figure to trust).

**As built, the second slice (2026-09-30).** Built to P2 §15 and `checker-v2.md` §27, not to the
table's `Touches` column: there is no `Solve` obligation and no `Term.Tag`. A demand is a mark on
a node of §14's graph; a summary class is `sync` when its declaration's graph carries it to one,
and every use of the summary demands its copy (class word bit 8, interface format 10, cache entry
8, frontend artifact 10). The platform writes `sync (A -> B)` in a `foreign` signature — the BIR
keeps the mark as the `type_fn`'s `main_token`, so no column — and `misplaced_sync` refuses one
that marks no function the platform receives. The language's own boundaries need nothing written:
a `foreign`'s evidence, a markup primitive's function parameters, a handler, row or key function,
`main`'s evaluation in the root package, and a type's `pub eq`/`compare`. `Sync.zig` reports
`sync_boundary` and `must_not_suspend` with the chain read backwards off the module's own graph,
one hop per module, and only on the error path. `Browser.program` and the `page` test platform
mark their callbacks; `Tea.sandbox` inherits them. No emitted byte and no run hash moved.
Fixtures: `check/bad/core/{SyncBoundaryArgument,SyncThroughParameter,SyncEvidence,SuspendingEqEvidence,MisplacedSync}`,
`check/good/core/SyncPermitted`, `build/bad/{MainSuspends,SyncPageBoundaries}`,
`parse/good/ForeignSync`, `fmt/ForeignSync`, and a cache test in which a dependency's flipped bit
makes the importer's error appear warm and go again. **Measurement**: `beni check --jobs=1
--no-cache` over the 100 159-line generated corpus, pinned, six runs each ABBA: 807.35 M → 812.75 M
instructions (+0.67 %); the harness's `check` line read 69.5 → 71.4 ms, one run each (wall time).

---

## 5. Decisions only the owner can take

1. **Does `sync` ship in the first cut?** *Options:* (a) yes, E2 lands immediately after E1;
   (b) no, as P2 §3.2 drafts it, and v1 has no boundary check at all.
   **Recommendation: (a).** Report 17 §6.1 item 4 already found `sync` unavoidable in an argument
   position, `boundary.md` §5.4 has promised the check in writing, §2.1 shows the hole is already
   inside `core/`, and P2 §3.2's own "what postponing costs" concedes the boundary question is the
   load-bearing one. (b)'s failure mode is a suspending `view` returning a suspension object to a
   VDOM patcher — `boundary.md` §4.1's "well-typed code crashes" reproduced by our own compiler.
   **Decided 2026-09-30 by the owner: (a).** `sync` ships in the first cut, right after inference;
   [`browser-decisions.md`](browser-decisions.md) W8 answers the same question the same way.

2. **Does effects wait for M3c/M3d, or interleave?** *Options:* (a) after DCE and chunking;
   (b) E1/E2 interleave now, E3+ after DCE.
   **Recommendation: (b).** E1 and E2 are checker work and touch nothing the backend is currently
   rewriting (§7's decision trees are in flight). E3's lowering collides with `Lower.zig` head-on and
   E5 is *blocked* on DCE — double translation without it roughly doubles the emitted `core/List`
   in every program (§3).
   **Decided 2026-09-30 by the owner: interleave, starting now.** Reachability elimination has
   landed (`backend.md` §9), so the slice that waited on it no longer has to.

3. **Fiber runtime scope for a first cut.** *Options:* (a) all fifteen primitives of P2 §6.5;
   (b) the eight `research/16` §5.6 calls free under both lowerings, plus `bracket`;
   (c) `spawn`/`join`/`scope`/`bracket` only.
   **Recommendation: (c) for the spike, (a) for the adoption.** Cancellation is the whole reason the
   lowering was chosen and `bracket`, `race` and `timeout` are one mechanism, so a spike omitting
   `bracket` measures the wrong thing; `race`, `timeout`, `parAll`, `Queue` and `RateLimiter` are
   library code over the same record and prove nothing new about the runtime.
   **Decided 2026-09-30 by the owner: (c) for the spike, (a) for the adoption.** The spike builds
   `spawn`/`join`/`scope`/`bracket`; the adoption ships all fifteen primitives.

4. **Two bits or one** (P2 §11 Q6). *Options:* (a) infer both, use both; (b) infer both, use only
   `suspends` in v1; (c) one bit.
   **Recommendation: (b).** `impure`'s only consumer is an optimiser that may duplicate, drop,
   reorder or memoise, and `backend.md` §9's optimiser does not exist yet. Inferring it costs
   nothing once the join machinery is there and keeps the interface bytes right from the first
   release, which is the expensive thing to add later. `Debug.log` is the only `impure` value in
   the repository today (`core/Debug.beni:19`), so v1's `impure` set has one member.
   **Decided 2026-09-30 by the owner: (b).** Both bits are inferred and published; v1 uses only
   `suspends`.

5. **What happens to `Program` and `Node.print`.** Measured: `main` is emitted as a module-level
   constant — `const Main$main = Node$print(…)` — evaluated at import time, outside any fiber, with
   no scheduler to park on. *Options:* (a) `main : Program` stays and its body is `sync`, checked by
   E2; (b) `main` becomes `() -> Program` and `runtime.js` calls the thunk; (c) `Program` gains a
   thunk field and `main`'s body may perform.
   **Recommendation: (a).** It is one obligation at one root, it costs no fixture churn across the
   ~70 `run/` fixtures that write `main : Program`, and it keeps `boundary.md` §7.2's "a `foreign`
   of effect type is pure to evaluate by construction" true. (b) is the right answer if a program's
   *top level* should be allowed to perform, and that is a language decision, not a platform one.
   **Decided 2026-09-30 by the owner: (a).** `main : Program` stays and its body is `sync`;
   [`browser-decisions.md`](browser-decisions.md) W9 is the same decision for the browser.
   **Extended 2026-09-30 by the manager, on the owner's delegation, and reversible:** every other
   top-level value is evaluated at module load exactly as `main` is, so it must not suspend either
   (P2 §15.2 item 7, `check/bad/core/TopLevelValueSuspends`). A value whose body is a lambda is a
   function and is never refused.

6. **May a well-known `eq`/`compare` suspend?** (§2.1) *Options:* (a) no — a `must_not_suspend`
   obligation on well-known evidence; (b) move `List.eq`/`compare` into beni over a new uncons
   primitive; (c) teach `core/List.js` the suspension protocol.
   **Recommendation: (a)**, with (b) held in reserve. It keeps derived functions single-bodied,
   keeps `==` and `<` non-suspending everywhere (which every reader will assume anyway), and is one
   rule rather than a new `foreign` capability. (c) widens the privileged surface against CLAUDE.md
   rule 6 for a feature nobody has asked for.
   **Decided 2026-09-30 by the owner: (a).** A well-known `eq` or `compare` must not suspend: a
   `must_not_suspend` obligation where one is resolved, built with `sync`.

7. **The chain diagnostic's reach** (§2.5). *Options:* (a) one hop per module, no new artifact;
   (b) a full cross-module chain from a side artifact excluded from the M4 hash.
   **Recommendation: (a) for v1.** (b) is an M4 cache-key design decision wearing a diagnostic's
   clothes, and `checker.md` §7 is explicit that provenance must never be hashed with the record.
   **Decided 2026-09-30 by the owner: (a).** One hop per module, and no side artifact.

8. **`List.map`'s effect order** (§2.4). *Options:* (a) fix `map`, `filter`, `concat`, `filterMap`,
   `partition` and `unzip` now, while it is unobservable; (b) fix them with E3; (c) weaken P2 §5 to
   promise source order only for `let` bindings and arguments, not for library traversals.
   **Recommendation: (a).** It is a `core/` change of a few lines and a handful of re-blessed
   goldens today, and a silently-wrong program later. (c) is defensible and should be rejected
   explicitly rather than by omission, because "in the order written" is what a reader of
   `List.map ids (\id -> getUser id)` will assume.
   **Decided 2026-09-30 by the owner: (a), deferred.** The traversals get source order, but whether
   `List` stays a cons list or becomes an array-backed sequence is itself pending
   ([`research/38`](../docs/design/research/38-immutable-array-representations.md)), so `core/List`
   is not touched now: this item lands with the sequence decision, and `run/MapEffectOrder` with it.

---

## 6. Risks: the exit-0 classes, and the fixture that catches each

Report 19 §11's finding, in its own words, was that *"the recurring failure mode was exit-0
wrongness — a program that compiled, ran and printed the wrong answer, which a fully green suite
coexisted with every time."* Everything below is that shape. Each row is a `tests/corpus/run/`
fixture unless it says otherwise, per CLAUDE.md rule 3 and `backend.md` §12.

| # | What goes wrong | Why nothing catches it | Fixture |
|---|---|---|---|
| 1 | A suspension object is threaded through a hand-written JavaScript loop. The diary's headline: `foldl` consing scheduler objects into a list. **Live again** as `core/List.js`'s `eq`/`compare` calling a suspending `m0` (§2.1) | `!suspension` is `false`, `suspension !== "EQ"` is `true`; both loops terminate and return a well-typed wrong answer | `run/ListEqSuspendingElement` — `[ x ] == [ y ]` for a type whose `eq` suspends must not be `true`. Under decision 6(a) it becomes `check/bad/SuspendingEqEvidence` and the `run/` fixture asserts the diagnostic instead |
| 2 | A suspension object reaches a host callback: a `view`, a DOM handler, a subscription tagger, or `main` itself | the patcher diffs it, or the pump dispatches it; the throw is inside the host's code, or there is none | `check/bad/MainSuspends` now; `run/` fixtures per callback when the browser platform exists |
| 3 | A continuation closes over a `$in$<i>` slot, or in-place loop reassignment is reintroduced. The resumed computation reads the loop's *last* values | the program runs and prints a plausible number | `run/SuspendInLoopClosure` — the `TailCallClosures` shape with a suspension point: cons a closure over the loop variable each iteration, park, resume, apply each. Prints `0 0 0` when wrong |
| 4 | Effects run in the wrong order. `List.map` is right-to-left today (§2.4), and nothing in the test suite can see it | every value is correct; only the *sequence* is wrong, and no golden records a sequence | `run/MapEffectOrder` — **writable today**, using `Debug.log` inside a `List.map`, and it fails before the `core/` fix. This one should land whatever is decided about effects |
| 5 | A cancelled fiber's finaliser does not run, or runs late. `research/16` §3.6 case (i): a primitive that never settles deletes the finaliser entirely, frame collected, nothing reported | the program exits 0 having leaked what it held | `run/BracketCancel` and `run/RaceLosersCancelled` — assert the *release* printed, in LIFO order, before the program exits |
| 6 | An `impure` call is duplicated, dropped or reordered by an optimiser or by DCE | the value is right; the side effect happened twice or never | `run/ImpureNotDuplicated` — a counter-shaped `foreign impure` called once behind a shared binding, asserted exactly once. Belongs with whichever of DCE or `--release` lands first |
| 7 | Double translation picks the direct body at a site whose flag is still a variable | works for every monomorphic test and fails on the polymorphic one | `run/BitPolymorphicBothWays` — one `List.map` called with a pure and a suspending callback in the same program, both answers asserted |
| 8 | The bit is lost crossing a module boundary, so a caller compiles the direct body against a suspending callee | single-module tests all pass | `check/good/SuspendsAcrossModules` with an `.iface` golden, plus the module set in the `--stage=raw` determinism comparison (CLAUDE.md rule 5) |
| 9 | Flag unification over-constrains: a bit-polymorphic function used pure in one place and effectful in another is rejected, or silently monomorphised (P2 §4.3's extraction hazard) | it is a false *rejection*, so it is loud — but the monomorphising variant is silent | `check/bad/FlagMonomorphised` for the diagnostic; `run/BitPolymorphicBothWays` for the silent half |

---

## 7. Could not determine without building it

- **Whether the two-word `extra` header (§3) is actually free in time.** It adds one indirection to
  `unifyFlat`'s `Func` case, which is on the hot path. The 20 % dispatch cost was *not* extra
  unification (report 19 §2.1), so a cost here would be a different and newer one.
- **What the `flag_le` obligation costs at the scale that broke dispatch.** Report 19 §3 found the
  constraint chain quadratic in the program's own constraint count. A flag join is a two-point
  lattice and should be linear, but nothing has generated the pathological program
  (`gen.zig --pathological=`) to find out.
- **Whether a bit-polymorphic `foldl` is fast enough for `core/`.** Report 17 §7 raised it and
  `backend.md` §8 only promises that *direct self-recursion* becomes a loop; the suspendable copy
  carries a `$yielding` test per element. Unmeasured.
- **Whether a kind (ii) `foreign` can receive a thunk emitted either way** — report 17 §7's own open
  item, and the foreign-boundary form of P2 §7.6.
- **Every scheduler constant.** `research/16` §6 names the missing experiment (the browser latency
  histogram) as the single most valuable thing absent from it, and every figure in that report is
  from Node.
- **What a `Cmd`/`Sub` bag is** — beni data or a host structure. `boundary.md` §5.4 leaves it to the
  browser package and report 17 §4.13 says the kind (i) count moves by several either way.
- **Short-circuiting.** `Basics.and`/`or` are `foreign` *because* they short-circuit
  (`core/Basics.beni:172`, `:179`), and P2 §5 says nothing about a suspension point in a right
  operand that may not be evaluated. Raised by report 17 §2.2, still unanalysed.
- **`Debug.todo`.** Neither `impure` nor `suspends` is totality, and `todo` throws. Report 17 §2.5
  raised it; nothing has decided what rung it sits on.
