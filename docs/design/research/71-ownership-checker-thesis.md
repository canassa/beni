# 71 — An ownership checker for beni: a thesis from first principles

Status: research, 2026-10-10. Nothing here is normative. It answers the owner's question of
research 68 and 69 — *could editing a `List` while anything else still holds the old version
be a compile error, with ownership inferred and no annotations in user code, so that every
list is a plain JavaScript array written in place?* — by designing the checker that would do
it, from the properties beni already has, and then saying where it would break. The decision
whether to adopt it is the owner's; this document's job is to make the case for *how* it would
work strong enough that an adversarial reader can find the holes, and to list the holes it
already knows about.

It reads the design documents of the compiler (`language.md`, `checker-v2.md`, `backend.md`
§4 and §8, `write-sets.md`, `browser-direct.md`, `boundary.md`, `transparent-effects-proposal.md`),
research 42 (beni's own spike on in-place writes), research 68 and 69 (the survey and its second
pass), and the library `references/ownership/` catalogues: the core papers were read deeply, and
every rule quoted below was checked against the paper's page. Citations give paper, section and
page. Where this document reconstructs something a paper only asserts, it says so.

**How to read it.** §0 is the thesis on one page. §1 states the question precisely. §2 is the
model, §3 the inference, §4 the soundness argument, §5 the hard cases, §6 the error messages,
§7 the interaction with the rest of beni, §8 the honest cost under rule 7, §9 the experiment to
run before deciding, §10 the language changes the owner may want to make for it, §11 the
recommendation and the open questions. Appendix A reconciles the design with the prior art,
paper by paper. Appendix B works four programs through the rules.

Terms, defined once and used throughout (more are defined where they first appear):

- **Cell.** One JavaScript array that backs a `List` value. Two `List` values that are the same
  cell are `===`; editing a cell in place changes what every reference to it sees.
- **Holder.** Anything from which a cell can be reached and read later: a variable binding, a
  field of a record, an element of another list, a closure's captured variable, a fiber's saved
  locals, a `Cmd`'s thunk, the runtime's own state, a JavaScript sibling, a `Ref`.
- **Content holder / identity holder.** A content holder may read the cell's elements; an
  identity holder only ever asks `a === b` of it. Only content holders can observe an in-place
  edit; identity holders are a separate hazard (§2.2).
- **Dead.** A holder is dead at a point when no execution continuing from that point reads
  through it. A dead holder may exist; it just never looks.
- **Unique at a site.** A cell is unique at an update site when every holder of it is dead once
  the update's arguments have been evaluated — the operand's own binding included. This is the
  property the checker proves (§2.3). It is weaker than Clean's "exactly one reference exists",
  and it is what lets reads stand before writes.
- **Demand.** A function whose summary says it writes a parameter in place: `List.set`,
  `List.push` and their kin in `core/`. Nothing in user code is a demand; user code only
  inherits demands by calling them.
- **Summary.** What the checker infers per function and publishes in its interface: for each
  parameter, whether the function consumes it, shares it or only borrows it; for the result,
  which parameters it may alias; for each function-typed parameter, how often it is called and
  whether it escapes (§2.6).
- **False error.** A rejection of a program that would in fact have run correctly in place.
  Because the checker is sound and incomplete, every imprecision is a false error, never a
  wrong answer; §6 says how the message tells the two apart.
- **Value semantics / update semantics.** The meaning beni has today (every update builds a new
  list; the old one is untouched) and the meaning the checker licenses (an accepted update
  writes the cell). The soundness claim is that the two cannot be told apart (§4).

---

## 0. The thesis on one page

**The property.** An update is accepted when its operand's cell is *unique at the site*: every
other holder of that cell is dead at that point. A holder is dead when no later read goes
through it. A read that comes *before* the update is therefore never sharing, however many
there are; a read that comes *after*, through any path the checker can see, is. This is
Boyland's alias burying (2001 §3.2, p. 13: aliases may exist "simply … all be dead") and
Rust's non-lexical borrow (RFC 2094, "Liveness"), applied to a language with no references,
and it is exactly what a plain array needs: the write is invisible iff nobody reads the old
version afterwards.

**Why beni can infer it.** Three facts of the language do most of the work. (1) **Strict,
left-to-right evaluation in source order** (`language.md` §6, *Evaluation order*): the order a
read and a write happen in is the order they are written, so "before" is syntactic, as Futhark
chose (2022 post, ll. 80–105) and as Smetsers et al. formalised with "preliminaries" and
"alternate" argument classes (1994 §4, p. 9). (2) **Every call is saturated and there is no
currying** (`language.md` §6.7): the one thing every uniqueness type system found "far from
trivial" — a partial application silently holding a unique argument (Clean report §9.4.1 p. 97;
Barendsen & Smetsers 1996 §7 p. 18; de Vries 2007 §4.2; Lorenzen et al. 2024 §6.4 p. 22, who
say the complications "go away if we imagine a change to the language forbidding currying") —
does not exist. A closure is a written lambda, and a lambda's captures are visible. (3) **The
checker already infers two bits per function type and solves them as a directed graph after
each module, publishes them in the interface and hashes them** (`checker-v2.md` §26;
`transparent-effects-proposal.md` §14). Ownership rides in the same seats: a few more facts per
function-type site, the same `⊑` edges, the same interface block, the same firewall.

**The analysis.** Per function, in one forward pass over the body in evaluation order: for each
variable and record path, the set of cells it may hold (a directional, Andersen-style flow,
never unification: Emre et al. 2023 measured unification poisoning 85 % of tmux's pointers from
four unsafe ones, §5, p. 94:10, and Table 2, p. 94:14); then a backward liveness pass per
(variable, path); then, at
each demand, the check. Calls use the callee's summary. A recursive group starts from the most
optimistic summaries — everything borrowed, every result fresh — and weakens to a fixpoint, the
search Aspinall, Hofmann and Konečný prove finds the best typing for first-order programs (2008
§6.2, p. 36) and the direction Lean's borrow inference (Ullrich & de Moura 2019 §5.2, p. 6) and
Brandon et al. (2026 §4.4, p. 16: "a least fixed point … justified by Knaster–Tarski") take. The
cost is linear in the body per round, with a round count bounded by a two-step lattice per
parameter; it fits `fast-compiler.md` §2's budget the way the effect pass did (≤ +10 % of check).

**What it needs from the rest of beni.** `core/`'s update primitives declare their summaries
(they are `foreign`, which already declares a rung and `sync`; one more word). The runtime that
calls `update` must *hand the model over*: keep no content holder of any list in the old model
after the arm runs. Today's `browser` runtime keeps every rendered list (`backend.md` §15.11;
research 42 §6.1: "never in place"), so under this rule every edit of a rendered list in `update`
would be an error on that platform. `browser-direct` was designed so that identity compares and
in-place writes never meet (§7.4's two rules), and its handoff protocol is specified here (§5.9).
Values a program hands to a command, a fiber, a `Ref`, `Js` or a sibling are shared from then
on; the write-set interpreter already computes which model paths escape that way (§7.4
condition 2), and the checker reads it at the boundary.

**What it costs.** Every program that keeps an old version and then edits — an undo history, a
"before and after" comparison, a test that holds the input, a command that captured the list —
is rejected until it writes `List.copy`. Persistent sharing becomes an explicit O(n) copy; the
trie goes; prepending in a loop is O(n) again except where the building-loop rule applies.
Closures that consume a capture may be called at most once, so `List.map xs (λx → List.push acc
x)` is an error and `List.foldl` is the way. Interface churn: a body edit that changes a `pub`
function's summary re-checks its importers, as inferred `where` clauses already do (research 19
§4). And the owner's own programs show where the demand would land: TodoMVC and Conduit call
**none** of `set`, `push`, `update`, `swap`, `pop`, `insertAt` or `removeAt` — they write
`List.map`, `List.filter` and `++` — so under the rule as asked the only demands in them are the
`++` sites (`List.append`: one in TodoMVC's Enter arm, `model.todos ++ [ new ]`, and four in
Conduit on literal left operands), and nothing else changes unless the same-shape rebuilds
(`map`, `filter`, `indexedMap`) join the demand set (§10, change 1).

**The recommendation** (§11): build the checker as a *report-mode pass first*, exactly as the
write-set analysis was built (`write-sets.md` §8), run it over `core/`, the corpus, TodoMVC and
Conduit, classify every rejection as real sharing or a checker limit, and decide the error
against those numbers. The rule's soundness is good; its value depends on two things this
document cannot settle from a desk: the rejection rate on code people actually write, and
whether the owner wants `map` and `filter` in the demand set.

---

## 1. The question, restated precisely

### 1.1 What the owner asked

"Editing a `List` while anything else still holds the old version is a compile error." Unpacked:

- *Editing* is a call of one of `core/List`'s update primitives: today `set`, `update`, `push`,
  `pop`, `swap`, `insertAt`, `removeAt`, and the two the syntax lowers to, `cons` (`[ x, …xs ]`)
  and `append` (`[ …xs, …ys ]`, `++` on lists). §10 asks whether `map`, `filter`, `indexedMap`,
  `reverse`, `sort` and `take` should join them.
- *Anything else* is any holder of the cell, of any kind listed in §2.2 — the operand's own
  binding included, if it is read again after the edit.
- *Still holds* means the holder is live: some execution continuing from the edit reads
  through it.
- *The old version* is the cell: the very array, not an equal list.
- *A compile error*, not a copy and not a warning. The owner wants no silent fallback: an
  accepted program writes in place, always, in development and release alike.

So the rule is **uniqueness at the update site, decided by liveness**, with the one escape hatch
`List.copy` making intentional sharing explicit.

### 1.2 What "observe" means, and what it does not

An in-place write is observable when some computation reads the cell's elements after the write
through a reference it obtained before. Three readers of a cell exist in beni:

1. **Program code** — any expression that reads elements: `List.get`, a pattern, a fold, `==`
   (`List.eq` walks both lists), `Debug.toString`, a markup hole showing the list.
2. **The runtime** — today's `browser` keeps the rendered list to skip the walk when the next one
   is identical (`forPosition`'s `s.b`, `backend.md` §15.5); `browser-direct` keeps instance
   items and leaf slots (§5.3, §6.1).
3. **JavaScript** — a sibling or a `Js.from` that kept the array.

Each is a content holder. An **identity holder** is different: it keeps the reference only to
ask `===` later. In-place writes do not change identity, so an identity holder never sees a
different *object*; what it may do is conclude "unchanged" from "same object", which is wrong
after an in-place write. That hazard is the renderer's, not the program's: beni has no
reference equality a program can call (`language.md` §11.12), and `browser-direct` §7.4's first
rule says a group "never decides 'unchanged' by the identity of an object on an in-place-written
path". The soundness claim of §4 covers content holders; identity holders are an assumption on
the platforms (A4), discharged by that rule.

### 1.3 Two semantics that must coincide

The precise form of the guarantee is Cogent's, as O'Connor, Linares Arévalo and Rizkallah put
it: uniqueness works "by statically ruling out every program where the difference between the
immutable and the mutable interpretations can be observed" (2026, vimpl.tex:45). Aspinall,
Hofmann and Konečný prove exactly such a theorem for their first-order system: an in-place
evaluation and a "safe" functional evaluation agree on every well-typed term (2008 Thm 5.8,
p. 30, "in-place update evaluation is correct … and complete"). §4 states beni's version: for an
accepted program, the *value semantics* (every update copies) and the *update semantics* (every
accepted update writes the cell) produce the same observations — the same printed output, the
same DOM transcript, the same sequence of calls into JavaScript with the same marshalled
arguments.

### 1.4 What is not asked

- Records, tuples and constructors are not written in place by this checker. `browser-direct`
  §7.4 (S7) plans record paths; the machinery here extends to them (§7.7) but the thesis is
  about lists, as the owner asked.
- The checker does not decide *whether* an update is worth doing in place; every accepted update
  is in place. There is no cost model and no "copy if small".
- It does not replace the write-set analysis; it reads one fact from it (§5.9).

---

## 2. The model

### 2.1 Values, cells and paths

A beni value at run time is a JavaScript value. The ones that matter here are the arrays that
back lists. A **cell** `c` is one such array. A list value is a cell, or a *view* of one — a
header `{ b, o, length }` over a base array `b` (`backend.md` §4, *The representation*). A view
is a holder of its base; writing "through" a view writes the base (§5.11).

Every other value either contains lists or does not. A **path** is a chain of steps from a
value into it — a record field `.f`, a tuple index `.i`, a constructor argument `C#i`, a list
position `[*]` — exactly `write-sets.md` §2.1's path language, with the same cut at k steps (§2.2
there; k = 8). A path is **list-typed** when the checker's solved type at its end is `List a`.
Only list-typed paths are tracked.

**Mode crossing.** A value whose type contains no `List` anywhere — `Int`, `String`, a record of
them, `Order` — can hold no cell and is never tracked: it "crosses" the ownership axis in Peters
et al.'s sense, where a type crosses an axis "when all of its values have no interaction with
that axis" (2026 §2.3, p. 6) and a kind is computed per type constructor with the element's kind
passed through for `list` (`list.0 = ⊥, list.1 = ⊤`, §4.2, p. 18). The OxCaml documentation
states the corollary the checker relies on: "a type crosses uniqueness if it doesn't contain
memory location subject to overwriting". For beni the kind is computed from the solved type:
`crosses(τ)` holds when `τ` is a primitive, a record, tuple or nominal type all of whose
list-typed paths are empty — i.e. no `List` is reachable through its fields, through aliases,
through constructor payloads (`payload_params`, `checker-v2.md` §14.2). A **type variable** does
not cross: a value of type `a` may be a list, and is tracked as a whole (one path, `ε`). This is
what makes Mode Crossing's claim — adoption "would have been infeasible" without it (§1, p. 3)
— true here at no cost: most values in a beni program are scalars and records of scalars.

### 2.2 Holders, and the two kinds

A **holder** of a cell `c` at a program point is a pair `(place, path)` through which `c` can be
reached, where a place is one of:

| Place | Example | Kind |
|---|---|---|
| a local or parameter | `xs`, `model.rows` as `(model, .rows)` | content |
| a field of a record/tuple/constructor held by a place | `(m, .form.tags)` | content |
| an element of a list held by a place | `(rows, [*].tags)` | content |
| a captured variable of a closure value held by a place | `(f, cap xs)` | content, live while the closure is |
| the environment of a suspended fiber, a `Cmd`/`Sub` thunk, a `Ref`, a `Queue` | `Cmd.perform (λ… → … xs …)` | content, **escaped**: live until the analysis can prove otherwise, which it cannot |
| a JavaScript sibling or `Js.from`'s result | `Js.from xs` | content, escaped (pinned) |
| a **top-level value**, with or without a `where` clause | `empty = []` | content, escaped: it is read by every later use, for the program's life |
| a value the runtime **retains and hands out again** — a fiber's outcome (`Task.join`, every joiner gets the same value), `Task.bracket`'s resource (kept for the release), a `Queue`'s or `Deferred`'s contents | `Task.join fib` | content, `⊤` on every path of the result: the runtime is a holder the checker cannot see |
| the module-level `model` between dispatches, and a **view-event payload** read from it or from a row's item | `onClick={Keep model.rows}` | content: the listener body reads the model or the item when the event fires (`browser-direct` §4.2); P5–P6 in §5.9 |
| the runtime's instance item `it`, a rendered row | `insts[i].it` | identity, by `browser-direct` §6.1–§6.2 |
| a derived-value or hole slot | `g3` | leaf values only (`browser-direct` §5.3); a list-valued slot is content, recomputed by the write set before it is read (§5.9) |

The operand of an update is itself a holder; the check asks about all the others.

### 2.3 Unique at a site

Let `u` be an update site — a call of a demand with operand expression `e` — and let the write
happen after every argument of the call has been evaluated (`language.md` §6: "the callee, then
the arguments left to right", and the call runs last). Let `C(e)` be the cells `e` may evaluate
to.

> **Definition (unique at u).** Cell `c ∈ C(e)` is unique at `u` when every holder `h` of `c` —
> the operand's own binding included — is **dead at u**: no execution continuing from `u` reads
> through `h`. A read through `h` is a dereference of the cell's elements or length, directly or
> by passing `h`'s value to anything that may read it. The operand's occurrence itself is not a
> later read: it was evaluated before `u`, and the demand's result is the new owner of the cell.

> **The rule.** `u` is accepted iff every `c ∈ C(e)` is unique at `u`, `⊤ ∉ C(e)` (the checker
> knows which cells), and no `c` is **escaped** (held by something whose future reads it cannot
> see).

Three things follow. First, *reads before writes are never sharing*: `List.set xs i (List.get xs
j + 1)` reads `xs` while evaluating the third argument, before the call; at `u` the binding `xs`
is the operand and, if nothing reads `xs` after, it is accepted — Wadler's "only update
operations are sequentialised but lookups can occur in parallel" (1991 §3, p. 8), Rust's
two-phase borrow where "during the reservation phase before a mutable borrow is activated, it
acts exactly like a shared borrow" and the only new check is at activation (RFC 2025, "Proposed
change"). Second, a *later* read is sharing: `let ys = List.set xs 0 1 in List.get xs 0` is
rejected, and the message names line 1's binding, the `set`, and the `get` (§6). Third, *a dead
alias is harmless*: `let saved = xs in List.set xs 0 1` with `saved` never read is accepted —
Boyland's rule that aliases need only "all be dead, that is, assigned before being used again,
if ever" (2001 §3.2, p. 13).

This is not Clean's uniqueness. Clean's `*` is a structural property — one reference exists —
checked by counting occurrences (Barendsen & Smetsers 1996 Def. 8.14, p. 29: a variable is
marked `⊗` "if x either occurs more than once or x is a letrec-variable"), refined by the
compiler's observing-reference rule only for guards and strict lets (Clean report §9.4, p. 96).
Liveness-based uniqueness is strictly more permissive and needs no `let!`.

### 2.4 Abstract values: which cells a value may hold

For every expression the analysis computes an **abstract value** `A(e)`: a finite map from
list-typed paths under the value to sets of cells,

```
A(e) : Path ⇀ ℘(Cell)          Cell ::= site(ι)   a list made at instruction ι (a literal, a fresh result)
                                      | π_i.q     the cell at path q of parameter i, on entry
                                      | ⊤         a cell the analysis cannot name
```

`A(e)@q` is the set at path `q`. **`∅` means provably no cell** — a path of a crossing type, or
a fresh container known to be empty; it never means "unknown". **`⊤` is prefix-closed**: a value
whose path `q` is `⊤` has `⊤` at every path under `q`, so a decoder's `List (List Int)` whose
outer cell is fresh but whose inner cells the row does not describe has `[*] ↦ {⊤}`, and an
unsummarised call's result is `⊤` everywhere. A demand on a `⊤` path fails K1. This is
`write-sets.md` §3.1's domain with
identity (`Same(p)`) replaced by cell sets, and it is **directional**: a binding `let y = x` makes
`A(y) = A(x)`, a copy of the sets, never a merged class. The difference is the whole precision
argument: Emre et al. found that under a unification-based model "having only four necessarily
unsafe raw pointers is enough to poison 85 % of the total raw pointers", and that going to a
subset-based analysis moved the share of well-contained pointers from 6.7 % to 88.9 % on tmux
(2023 §5 p. 94:10, Table 2 p. 94:14). HM unification is the wrong solver for this fact, and the
effect bits already live beside the unifier rather than in it (`transparent-effects-proposal.md`
§14.2: "nothing is added to `TypeStore` or to `unify`"); ownership does the same.

### 2.5 The transfer rules

Written for the core forms, in evaluation order, with `Σ` the environment of locals. Each rule
says what the result may hold and what new holders exist. (`∪` on abstract values is pointwise
union of cell sets; `shift(A, s)` prefixes every path with step `s`; `proj(A, s)` keeps the
paths under `s`.)

| Expression | `A(e)` | Holders created / notes |
|---|---|---|
| variable `x` | `Σ(x)` | none new; a *use* for liveness (§2.7) |
| literal `[ x₁, …, xₙ ]` | `ε ↦ {site(ι)}` ∪ `shift(A(xᵢ), [*])` | a fresh cell; the elements' cells are reachable through `[*]` |
| record `{ f = x, … }`, tuple, constructor `C x̄` | `⋃ shift(A(x), .f)` etc. | the structure holds what its parts hold |
| record update `{ r \| f = y }` | `A(r)` with the `.f` paths replaced by `A(y)@…` | `language.md` §11.12: the other fields are the very values; so the old record and the new share every cell under every other field |
| field/tuple access `r.f` | `proj(A(r), .f)` | an alias of the field's cell, not a copy |
| `case x of p → e` | per arm, pattern variables bound to `proj(A(x), step)`; a list pattern's `rest` is bound to **the same cells as `x`** (a view of the base, §5.11) and `[ …init, last ]`'s `init` to a fresh cell (the as-built slice, `backend.md` §7) | arms are analysed separately; the result is the union; liveness is per path (§2.7) |
| `let x = e₁ in e₂` | `Σ[x ↦ A(e₁)]` | `x` is a holder of everything in `A(e₁)` |
| lambda `λ ȳ → e` | a function value with summary `S_λ` (§2.6) | the closure is a holder of each captured `z` at `(λ, cap z)` |
| call of a top-level `f x̄` with summary `S_f` | see §2.6 | the call is a use of every argument; a **demand** when some parameter is `consumed` |
| call through a value `g x̄` | by `g`'s class (§3.6) | as above |
| `foreign` / `Js.*` with no summary | `ε ↦ {⊤}` (prefix-closed) and every argument's cells **escaped** | §5.7 |
| a top-level value `v` | `Σ(v)`, every cell **escaped** | a holder for the program's life (§2.8) |

### 2.6 The summary: the annotation the compiler infers

For a function `f` with parameters `π₁ … πₙ` and result `ρ`:

```
S_f = ⟨ use : (i, q) ↦ borrowed | shared | consumed        for each list-typed parameter path πᵢ.q
      , res : q ↦ ℘({ πᵢ.q' } ∪ { fresh })                  for each list-typed result path ρ.q
      , fun : j ↦ ⟨ calls ∈ {0, ≤1, many}, escapes ∈ {no, yes}, supply, need ⟩
                                                              for each function-typed parameter πⱼ
      , reason : (i, q) ↦ a derivation tag (§6.4)            why each non-borrowed use was inferred ⟩
```

- **`borrowed`**: during the call `f` may read `πᵢ.q`'s cell; it does not write it, store it,
  return it, or capture it in anything that outlives the call. After the call the caller still
  owns the cell. This is Aspinall–Hofmann's aspect 3, "read and not shared" (2008 §1, p. 4), and
  FP²'s `^` parameter, which "cannot be used in a destructive match, passed as an owned
  parameter, or returned as a result" (2023 §1.3, p. 4).
- **`shared`**: `f` may make the cell reachable from its result (then `res` says where) or from
  something that outlives the call — a stored closure, a `Ref`, a fiber, JavaScript. Aspect 2,
  "read and shared with the result", plus escape.
- **`consumed`**: `f` may write the cell in place (directly, or by passing it to a consumed
  position). The caller must prove the cell unique at the call. A consumed parameter's cell may
  also appear in `res` (every `core/List` writer returns its operand) — ownership is transferred,
  not lost.
- **`res`** is the reachability-type idea of a dependent result: the function type records
  "which argument its result aliases" by naming the parameter in the result's qualifier
  (`f(x : T^◆) → T^{x}`, Wei et al. 2024 §2.2.3, ms.tex:1285). Here it is per path.
- **`fun`** records, for a function-typed parameter `g`, how many times `f` may call it (`0`,
  `≤1`, `many`: a call inside a loop, a recursion or a `List.map`-shaped callee is `many`),
  whether it escapes (is stored, returned or captured by something stored), what `f`
  **supplies** at each of `g`'s parameters (an owned cell, or a borrowed one) and what `f`
  **needs** of `g`'s result (whether it stores it, or treats it as fresh). The closure passed at
  a call is checked against this (§3.6). The `≤1`/`many` distinction is OxCaml's `once`/`many`:
  a closure that consumes a capture "can be invoked at most once" (Lorenzen et al. 2024 §2.2,
  p. 5; docs, *Uniqueness intro*), and Futhark's reason for refusing a free-variable consume:
  "we have no idea how often f will be applied" (2022 post, ll. 223–234).

A **lambda's summary** `S_λ` has the same shape over its own parameters, plus `cap : (z, q) ↦
borrowed | shared | consumed` for each captured variable **per path** — a lambda that reads only
`model.page` captures `(model, .page)` and holds nothing of `model.todos`, which is what keeps
the ordinary `( { model | todos = … }, Cmd.perform (λsend → Http.get (url model.page) …) )` from
sharing every list of the model — and `once ∈ {yes, no}`: `yes` iff some capture is consumed.
**A `once` closure is an affine value**: its binding is dead after one use on every path, a
second use (a second call, a second pass to any position, a store) is an error, and the K-rules
for its consumed captures are discharged at the lambda's *creation* against the closure's own
liveness — so `g = λx → List.push acc x; r1 = Result.andThen a g; r2 = Result.andThen b g` is
rejected at the second `g`, not accepted twice.

**Summaries may be conditional on a function parameter's class.** `foldl`'s accumulator is
`consumed` only when its callback consumes its own accumulator parameter (`use(acc) = consumed
iff g.need(2) = consumed`); a body whose K-check depends on whether a closure handed to a
parameter escapes (`f xs h = g = λ_ → List.length xs; _ = h g; List.push xs 1`) is accepted
**iff `h.fun(1).escapes = no`**, and that condition travels in `f`'s summary and is checked at
each caller when the class is bound (§3.6). The grammar above is read with every `use`, `res`
and K-condition allowed to be an expression over the function-typed parameters' class variables
— rank-1 constraints, the shape the effect summaries already have (`transparent-effects-proposal.md`
§14.4: "the other classes of the same scheme that reach it").

**The demand set is declared, not inferred.** `core/List`'s writers are beni bodies over `Js`
since 2026-10-02 (`backend.md` §4, *The runtime: `core/List.js`*, as amended): `set xs i v` is
`Js.pure λ⊤ → … Js.call (Js.from b) "slice" …`, and by §2.5's rule a `Js` argument is escaped and
a `Js` result is `⊤`, so inference would make every writer "escapes `xs`, result `⊤`". The
writers therefore carry an **asserted summary**, a promise the body's `Js` cannot show, exactly
as a `foreign` carries its rung and its `sync` marks and the owner's `Ref.update` carries `sync`
in a beni signature (`boundary.md` §4, amended 2026-10-02): **core and the platforms may assert a
summary; every other package may only narrow one** (§10 change 5). The rung is trusted the same
way; a false assertion is a correctness bug in privileged code, not a user error. The asserted
rows, in the bracket notation of this document:

```
pub set      : List a [consumed], Int, a → List a [= π₁]
pub update   : List a [consumed], Int, (a → a) [calls ≤1, supply owned if π₁ excl, need owned] → List a [= π₁]
pub push     : List a [consumed], a → List a [= π₁]
pub pop      : List a [consumed] → List a [= π₁]
pub swap     : List a [consumed], Int, Int → List a [= π₁]
pub insertAt : List a [consumed], Int, a → List a [= π₁]
pub removeAt : List a [consumed], Int → List a [= π₁]
pub cons     : a, List a [consumed] → List a [= π₂]
pub append   : List a [consumed], List a [borrowed] → List a [= π₁, fresh]   -- never π₂: §10 change 2
pub foreign pure length : List a [borrowed] → Int
pub copy     : List a [borrowed] → List a [fresh]                            -- new, §5.10
    at       : List a [borrowed], Int → a [= π₁[*]]                          -- core-private
```

(The bracket notation is this document's; §10 proposes the surface spelling.) Everything else in
`core/List` is beni and is inferred from its body: `map`, `filter`, `foldl` are loops over `at`
and a builder, so `map : List a [borrowed], (a → b) [calls many, supply borrowed, escapes no] →
List b [fresh]` comes out of the rules without an assertion. The whole user-facing demand is the
**nine writers** above (`update` is `set` with a callback), which is the Clean recipe — "the
demand lives only on the update primitives' types" (de Vries 2007 §6, p. 10: library functions
are given polymorphic result attributes so that "we will always be able to share arrays") —
with the demand on exactly the functions whose in-place form the owner wants.

**A summary must describe the emitted code, not only the source.** `backend.md` §8's tail-call-
modulo-cons rewrite compiles `appendTo xs ys = case xs of [] → ys; [ x, …rest ] → [ x, …appendTo
rest ys ]` to a builder loop whose exit **copies** `ys` (`List$close`), where the source's `cons`
steps would consume the result holding `ys`. The checker reads the function as the backend
emits it — a building function's exit value is `borrowed`, its result `fresh` — because the
rewrite is mandatory and part of the language's cost contract (`language.md` §6.8). The same
holds for scalar views: a loop slot the backend turns into an offset is a read of the base.

### 2.7 Liveness, per path

`live(h, p)` for a holder `h = (x, q)` at point `p`: there is a use of `x` at or after `p` on
some path that reads `q` or a prefix of it. Uses, in evaluation order, are:

- a read of `x.q'` with `q' ⊑ q` or `q ⊑ q'`;
- `x` passed to a call whose summary reads the parameter at `q` (`borrowed`, `shared` or
  `consumed` at a path that meets `q`); a parameter whose summary is `⊤`-shaped (no summary)
  reads everything;
- `x` returned, stored in a structure that is live, or captured by a closure that is live
  (a captured variable is live exactly while the closure value is live, and *forever* when the
  closure escapes);
- `x` used whole by anything the analysis does not see into (`Debug.toString`, a `Js`
  intrinsic) — a read of every path. `==` and `<` are method calls resolved by the dispatch table
  (`checker-v2.md` §13): a *derived* `eq`/`compare` and `List.eq`/`List.compare` are read-only
  by construction, but a type's **own** `pub eq` is ordinary beni and is summarised like any
  function — one that consumes is a demand.

A `case` makes liveness path-sensitive in the ordinary way: a holder live only in the arm not
taken is dead in the other (§5.6). A self tail call (`backend.md` §8) rebinds parameters: the
old values are dead after the jump unless an argument still to be evaluated reads them, which
the emitter's own ordering rule already guarantees (`backend.md` §8, *In place, when nothing
captures*).

Liveness is computed per (variable, k-path) so that `m.name` read after `List.push m.rows x`
is not a use of `m.rows`: field-sensitive deadness is what lets a record be threaded through
helpers that each touch one field. Rust lacks this across calls — Matsakis' "view types" problem
(research 68 §7.1) — and research 42's O8 ("capture the projection") measured its absence as a
copy of every row per `Append`.

### 2.8 The check, stated as a rule

At a call `f ā` whose summary has `use(i, q) = consumed`:

```
for each c ∈ A(aᵢ)@q:
    c ≠ ⊤, and A(aᵢ)@q is not ∅-by-ignorance                   (K1: the cell is known)
    c is not escaped                                           (K2: nothing unseen holds it)
    for each holder h of c:  ¬ live(h, after the call)         (K3: nothing reads it later)
    for each other argument path (aⱼ, q'), j ≠ i or q' ≠ q, and for each capture of each
    function-valued argument:  c ∉ A(aⱼ)@q'                     (K4: nothing reads it during)
```

K3 reads "after the call": every argument has been evaluated, so a read inside an argument is
before the write; and the operand's own binding is a holder like any other, so `let ys = List.set
xs 0 1 in List.get xs 0` fails K3 on `xs`. **K4 is the separation rule**: the write happens
*inside* the callee, before the callee's own later reads, and the callee reads its other
parameters and calls its callbacks while the write is already visible. `List.foldl xs xs (λx acc
→ List.insertAt acc 0 x)` — the same list as the walked input and the consumed accumulator — would
read the growing array through `xs` while writing it through `acc`; `g xs (λ_ → List.length xs)`
with `g xs k = k (List.push xs 1)` would read the pushed cell through the capture. K4 is Rust's
"one `&mut` or any number of `&`, never both, at one call" (NLL RFC, *Borrow checker phase 2*),
Futhark's "the argument passed for a consumed parameter does not alias any other argument"
(thesis Fig. 34, p. 87), and Aspinall–Hofmann–Konečný's comma-as-tensor ("they must be
implemented without sharing, unless the access is guaranteed to be read-only", 2008 §3, p. 13).
It is checked on abstract cells, so two arguments that *may* be one cell fail it.

When `aᵢ` is itself a parameter path `πⱼ.q'` of the enclosing function, the enclosing function's
`use(j, q')` becomes `consumed`, and K2–K4 are discharged at *its* callers in turn. A failure of
K1 or K2 is reported as a **limit**; a failure of K3 or K4 as **sharing**, with the holder named
(§6).

**Two holders that live for the whole program.** A top-level value (`empty = []`, a `where`-
constrained constant memoised per evidence, `language.md` §6) is a holder that is never dead: its
cells are **escaped** from the start, so `[ x, …defaults ]` onto a top-level list is a rejection
with the `List.copy` fix. And the page's `model` variable on `browser-direct` is a holder between
dispatches (§5.9). Neither is a local, which is why §2.2's table lists them.

### 2.9 Deep uniqueness: exclusive contents

A list's elements, a dictionary's values and a record's fields can hold cells, and two positions
of one container can hold the *same* cell: `[ r, r ]`, `List.repeat r 3`, `Dict.insert
(Dict.insert d k v) k' v`. An edit inside an element — `{ r | tags = List.push r.tags t }` on
the element at position 0 — would then be seen at position 1. The cell-set domain cannot tell
positions apart: every element of a `rows` built in a loop comes from one allocation site, so
`A(rows)@[*].tags` is one abstract cell for all of them, and K3 finds the holder `(rows,
[*].tags)` live (the other elements are read later) whenever the container outlives the edit.
That is the right answer when positions may share and a false error when they cannot, and it is
the case Clean handles with *deep* uniqueness — `*[*a]`, a unique list of unique elements, where
`head :: *[*a] -> *a` may hand an element out unique because the list's construction guaranteed
that no element was shared when it went in (Clean report §9.2, p. 93; Barendsen & Smetsers 1996
§7, p. 15, the three admissible `Cons` attributions). OxCaml states the same: "Uniqueness is
considered a deep property by default; that is, we expect components of a unique value also to
be unique" (Lorenzen et al. 2024 §2.1, p. 4).

The rule here: a container path — `(x, q[*])` for a list, `(x, q.contents)` for a `Dict` — is
**exclusive** when every cell stored under it was unique at the store and stored nowhere else,
and no read since has produced a holder of a contained cell that is still live. The flag `excl`
on an abstract container path is:

- **set** by a construction whose every stored cell is unique at the store: a literal of distinct
  fresh cells, or a `fresh` result whose elements are declared fresh (`map`'s result when the
  callback's result is fresh; a decoder's output, by its row);
- **kept** by a *destructive read*: a container function that consumes the container, hands one
  element to a callback and stores the callback's result back at that position, reading no
  other element in between (`List.update`'s body is `set xs i (func (at xs i))`, and `set`
  writes slot `i`). The element is unique inside the callback because, the container being
  consumed at the call (K3) and no argument or capture of the callback holding it (K4), the slot
  is the element's only other holder and nothing reads the slot before it is overwritten.
  `Dict.update`'s body (`insert d k (alter (get d k))`) is the same shape at a *key*, which the
  path domain cannot name (`contents[*]`): its callback's `supply = owned` is therefore an
  asserted row of core's, with the body-level reason written beside it, not an inferred one;
- **cleared** by a store of a cell that is not unique at the store (`[ r, r ]`'s second `r`,
  `List.repeat`, an element taken from another live container), and by a non-destructive read
  whose result is live while the container is (`Dict.get d k` with `d` used after; `List.get`; a
  pattern's `x` of `[ x, …rest ]` while `xs` lives).

With the flag, `List.update rows i (λr → { r | tags = List.push r.tags t })` is accepted when
`rows` is unique and exclusive, and rejected with the limit tag "the elements of `rows` may
share" when they came from somewhere the checker cannot see. Without the flag the whole class of
nested edits would be a limit. The flag travels in the summary beside `res` (a result path may be
`fresh, excl`) and in the interface, and its soundness is Lemma 1b (§4.3). Elements of a
crossing type (§2.1) need none of this.

---

## 3. The inference algorithm

### 3.1 Shape

Four passes per module, after type checking, in the slot `Effects.run` occupies today
(`checker-v2.md` §26: after P5, before P6, with every solved type available; the backend "sees
no types", §13.4, so nothing later could do this):

1. **Local flow** (§3.2): one forward walk of each declaration's body in evaluation order,
   computing `A(e)` for every list-typed expression. Calls use callees' summaries; a callee in
   the same strongly connected component uses the current round's summary.
2. **Liveness** (§3.3): one backward walk per declaration, computing `live(h, p)` for the
   holders the forward walk named.
3. **Check and summarise** (§3.4): the K-rules at every demand; the declaration's summary read
   off the walks.
4. **The group fixpoint** (§3.5): repeat 1–3 for a recursive group until no summary changes,
   then validate.

Function-typed values carry **ownership classes** (§3.6), solved with `⊑` edges in the same
pass. Imported summaries come from interfaces (§3.9). The pass runs on every build, like the
effect pass; it produces diagnostics, unlike the write-set pass.

### 3.2 Local flow: directional, flow-sensitive, in evaluation order

BIR is already a sequence of instructions in evaluation order with `let` binding and `case`
branching (`frontend.md` §3.6; `language.md` §6, *Evaluation order*). The walk keeps `Σ` and
applies §2.5's rules; a `case` forks `Σ` per arm and joins the results by union. There is no
loop inside a body except the self tail call, which the walk handles as a recursive call of the
same declaration (so the parameters' cells on re-entry are the union of the entry cells and the
jump's arguments — one fixpoint over the body, which converges in at most as many rounds as
there are distinct cells, in practice one or two).

Why directional and flow-sensitive both matter, in one example:

```
xs = [ 1, 2, 3 ]            -- A(xs) = {site₁}
ys = xs                     -- A(ys) = {site₁}: a copy of the set, not a class
zs = List.set ys 0 9        -- demand: site₁ unique?  holders: xs, ys. xs dead after? …
List.length zs              -- …yes: xs is never read again. Accepted.
```

A unification-based model would put `xs`, `ys`, `zs` in one class and then any later use of any
of them would taint all three; here `zs` is a new holder of the *same* cell (ownership
transferred), and `xs` is dead.

The cost of pass 1 is linear in the instructions times the width of the abstract values (the
number of list-typed k-paths under a type, bounded by the type; the cell sets are usually
singletons). Abstract values are hash-consed as `write-sets.md` §3.1 does, so a chain of `if`s
does not duplicate them.

### 3.3 Liveness

A standard backward pass over the same instruction sequence, with a bit per (variable, path)
and the uses of §2.7. Branches join by union (a holder live in either arm is live before the
`case`). Closures: a captured path is live **wherever the closure value is live** — at every
call, store, return or pass of the closure, which the walk sees as ordinary uses of the closure's
binding — and **from the creation onward, for ever**, when the closure escapes (passed to an
`escapes = yes` position, stored, returned). So `g = λ_ → List.length xs; ys = List.push xs 1;
{ m | f = g }` is rejected: `g` is read after the push and holds `xs`. The cost is linear.

### 3.4 The check, and reading off the summary

At each demand apply K1–K4. Then:

- `use(i, q) = consumed` if some demand's operand may hold `πᵢ.q` (K3 was discharged for every
  *local* holder; the caller discharges the rest);
- `use(i, q) = shared` if `πᵢ.q` ∈ `A(result)@q'` for some `q'`, or `πᵢ.q` was stored in an
  escaping place, or passed to a `shared` position of a callee, or captured by an escaping
  closure;
- `use(i, q) = borrowed` otherwise;
- `res(q') = { πᵢ.q | πᵢ.q ∈ A(result)@q' } ∪ { fresh | some site ∈ A(result)@q' }`;
- `fun(j)` from the calls of `πⱼ` the walk met: `calls` by counting on paths (any call inside a
  tail-call loop or passed to a `many` position is `many`), `escapes` from the holders, `supply`
  from the K-check at each call (owned iff the argument's cell was unique there), `need` from
  whether the result's cells reach `A(result)` or a store.

`consumed` and `shared` are not ordered; a parameter can be both (`consumed` and in `res`,
which is the normal writer shape). The three-valued `use` is the aspect lattice of Aspinall,
Hofmann and Konečný — "Variables may only be accessed once with aspect 1. Variables can be used
many times with aspect 2 … Finally, variables can be freely used with aspect 3" (2008 §1, p. 4)
— with "once" replaced by "unique at the site".

### 3.5 Recursion: the optimistic fixpoint, and why it is the best answer

A strongly connected component of the call graph (within one module; the module graph is a DAG,
so cross-module recursion cannot occur) is solved together. Every member starts at the most
optimistic summary: every parameter `borrowed`, every result `{fresh}`, every function-typed
parameter `calls ≤1, escapes no`. The body is analysed with those; the summaries that come out
are joined with the assumption (pointwise: `borrowed ⊏ shared`, `borrowed ⊏ consumed`, `fresh`
∪ parameters; `≤1 ⊏ many`, `no ⊏ yes`); repeat until nothing changes. The lattice is finite
(two independent bits per parameter path, a set per result path, two bits per function
parameter) and every transfer is monotone (more sharing in a callee's summary makes more holders
and more escapes in the caller, never fewer), so the iteration terminates in at most
`2·|paths| + |results| + 2·|fun params|` rounds and in practice one or two. **Then the group is
validated**: each body is checked once more against the final summaries, and every K-rule must
pass; a summary that reached a fixpoint is a consistent *typing* of the group, and §4.3's Lemma
3 argues its soundness by induction on the number of calls an execution makes.

This is the procedure the literature agrees on. Aspinall, Hofmann and Konečný: "for every
program typable in our system, there is a typing with best (i.e. largest) usage aspects. These
usage aspects can be automatically reconstructed using an iterative search for a fixed point,
starting with the most optimistic typing of all functions in the program" (2008 §6.2, p. 36 —
the algorithm itself is in Konečný 2003, not in the library). Lean: "we infer β(c) by starting
with the approximation β(c) = Bⁿ, then we compute S = collect_O(b), update β(c)_i := O if y_i ∈
S, and repeat the process until we reach a fix point" (Ullrich & de Moura 2019 §5.2, p. 6).
Brandon et al.: "each group of equations in Figure 8 defines a monotone function … Existence of
a least fixed point for each group of equations is justified by Knaster–Tarski, and termination
is justified by finiteness. In other words, our equations can be viewed as a Datalog program"
(2026 §4.4, p. 16). The write-set pass does the same for its summaries (`write-sets.md` §4.3,
Kleene iteration from ⊥). Clarke et al.'s complaint that ownership inference "cannot give a best
solution" (research 69 §1.1) does not apply: here the constraints are inclusions with a least
solution, and the optimistic start finds it.

Where Clean gave up — "we do not try any specific instances but consider the expression
untypable" (Barendsen & Smetsers 1996 §8, p. 33) and "the type of every binding in a recursive
binding group must be non-unique" (de Vries 2007 §7, p. 12) — this checker does not, because its
unknowns are facts about flows, not attributes on types that a rank restriction on arrows
prevents from being generalised.

### 3.6 Function values: ownership classes on function types

A function-typed parameter `g` of `f` has no body to analyse. Two ways exist: assume the worst
(every argument to `g` shared, `g`'s result `⊤`, `calls many`) — Huisinga's "higher-order
functions are always shared" (2023 §4.1, p. 47) and the Lean thesis's "considerable limitation"
— or make `f`'s summary *polymorphic* in `g`'s. beni already does the second for effect bits:
"a reference to a top-level declaration instantiates its summary … each class of the scheme
gets a fresh class at the use, which gets the scheme class's rung and `d ⊑ c` for every scheme
class `d` that `c` depends on" (`transparent-effects-proposal.md` §14.3 rule 3), which is "what
makes `List.map` serve a pure and a suspending callback with one definition". Ownership takes
the same seat:

- every function type in a scheme carries an **ownership class**: `fun(j)`'s four facts and,
  for its own parameters and result, `use`/`res` variables;
- `f`'s summary is expressed over its function-typed parameters' classes: `map`'s result is
  `fresh`; its callback is `calls many, escapes no, supply borrowed (the element), need fresh`;
  `foldl : List a [borrowed], b [consumed], (a, b [consumed] → b) [calls many, supply: borrowed,
  owned; need: owned] → b [= π₂ ∪ g.res]`;
- at a call `f … λ …` the lambda's actual summary is related to the instantiated class by
  **directional edges**, not unification: the lambda may consume a parameter only where `f`
  supplies an owned cell (`need_λ(k) = consumed ⟹ supply_f(k) = owned`); the lambda's `once`
  requires `calls ≤ 1`; the lambda's result aliases flow into `f`'s `need`; the lambda's
  `shared` captures flow into `f`'s result if `f` returns `g`'s result; `escapes = yes` escapes
  every capture. A violated edge is an error at the call, naming the lambda and the parameter.
  This is subtyping, "not just unification", exactly §4.4 of the effects proposal.

The classes ride on the solved types, so a function value that reaches `f` through a record
field or a parameter of a parameter is handled by the same instantiation (the class is where the
function type is). Rank-1 is enough: Lorenzen et al. note that "higher-order functions in Rust
that pass newly borrowed values to their callbacks must have higher-rank types … while in our
system such functions have rank-1 types that can be fully inferred" (2024 §8.3, p. 26), and
beni's arrows are n-ary and saturated, so there is no spine to propagate along.

What this does **not** do is infer, inside `f`, that a particular closure *only reads* a capture
and may therefore be called many times while the capture is later consumed. That fact is the
lambda's (`cap z = borrowed`), decided where the lambda is written, and it composes: `List.map
xs (λx → f x ys)` has `cap ys = borrowed`, `map`'s `calls = many` is fine for a closure that
consumes nothing, the closure does not escape, so `ys` is live only during the `map` call, and a
later `List.set ys …` is accepted. Deng et al. 2025 get the same by effects (`{u:c}` for a
reader, `{u:c; k:c}` for a consumer, Fig. 6, p. 11) and Capybara by capture modes (a read-only
capturing closure "never blocks a later write", ms.tex:647–671); both declare, this infers,
because the lambda is in front of the checker.

### 3.7 `where` clauses and generic code

A method call `x.m a` inside a function with a `where` clause calls evidence the caller
supplies. Two cases:

- the well-known `eq` and `compare` are `sync` and read-only by contract (`boundary.md` §4):
  summary `borrowed, borrowed → crosses`. No loss.
- a user method `a.update : a, Int → a`: its summary is a **class** on the constraint's method
  type, instantiated at each call site from the dispatch table's resolved term (`checker-v2.md`
  §13.1: `top`, `ext`, `derived`, `param`), exactly as its effect class is. Inside the generic
  body the class's variables are what the summary is written over; at the use they are bound.

So generic code loses nothing by itself. What it cannot do is write a type variable's value in
place: `f : a → a` has no demand to call. A generic container function — `Dict.update d k (λv →
List.push v x)` — is the container's business (§5.4), and its callback's `need` is a class the
caller's lambda is checked against.

Parametricity supplies the result aliasing for free: a function of type `a → a` can only return
its argument (or something a callback gave it), so `identity`'s summary is `res = {π₁}` without
analysis — Futhark's observation that "the only way this function can return an `a` is by
returning the `a` we give it" (2026 aliasing post, ll. 555–612) and the `id(x : T^◆) : T^{x}`
of Wei et al. The checker gets it from the body anyway (`identity x = x` analyses to that), and
from the type for a `foreign` over a type variable (`Debug.log`'s row in `write-sets.md` §3.7)
**only when no `foreign type` with a tracked parameter stands between the argument and the
result**: `Task.join : Fiber a → a` returns a value the runtime retains and hands to every
joiner, so its result is `⊤` (§2.2's runtime-retained row), not "fresh from nowhere".

### 3.8 Complexity, and the budget

Per declaration: pass 1 is O(|body| · w) where `w` is the number of tracked paths of the
widest type the body mentions (bounded by k and the type; for a model record with three list
fields `w = 3`); pass 2 is O(|body| · w); the check is O(demands · holders), which is quadratic
*within one declaration* when a cell has many alias bindings — `update` is the declaration that
has both, and §9 measures it. A recursive group of `n` declarations (top-level, or the `let`
functions of one body, which form their own component) runs ≤ `h` rounds where `h ≤ 2·P + R +
2·F` is the lattice height over the group's parameter paths, result paths and function
parameters, so the group costs O(h · Σ|body| · w). Interfaces add a few words per scheme site.
Nothing is quadratic in the module, and
nothing is whole-program: summaries are read from interfaces exactly as effect summaries are
(`checker-v2.md` §26, "imported summaries are applied at instantiation").

`fast-compiler.md` §2 asks for > 250k LOC/s per core for checking; the effect inference landed
inside the plan's "≤ +10 % of check" bound (§14.4 there), and this pass has the same shape with
a wider per-site record. The honest unknown is `w` on wide model records and the holder count at
a demand inside a large `update`; §9 measures both. A cap, if one is needed, goes on `w` (a type
with more than, say, 64 tracked paths is tracked as a whole) and yields `⊤` — a *limit* report,
never a wrong answer, the shape every cap in `write-sets.md` §6.1 has.

### 3.9 Summaries in the interface, and the firewall

The summary of every `pub` declaration is published in the interface record as a block beside
the effect block (`transparent-effects-proposal.md` §14.6): per scheme site (found by the same
root/path encoding), the `use` and `res` facts, and per function-type site its class's four
facts. The block is **hashed with the record** (`fast-compiler.md` §8.1), so a body edit that
changes a summary changes the hash and the importers are re-checked, which is the only correct
behaviour: Klabnik's "if it did [infer signatures], changing the body of the function would
change its signature" (research 69 §1.3 item 5) is a description of this design, and the cost is
churn, which research 19 §4 priced for inferred `where` suffixes at 4.4–6.5× the churn of
annotated code. §9 measures it for summaries; §10 offers an optional annotation that freezes
one.

The cache key does not change: the block is a function of the module's source and its imports'
interfaces, which the key already pins (`checker-v2.md` §28, same argument for the boundary
rows).

### 3.10 Determinism

Every order the pass uses is the checker's: SCC order tie-broken by source, instruction order
within a declaration, name text for fields and paths, store-variable index for classes
(`checker-v2.md` §17). Cells are named by instruction index and parameter position. No hash of a
pointer, no thread order. The `--jobs=1` versus `--jobs=8` determinism scenario gains the
ownership dump (§9.1) beside the dispatch and writes dumps.

### 3.11 What the pass is not

It is not an optimisation that decides per site whether to write in place: under the rule every
accepted demand is in place, so the backend needs no per-site bit (§7.5). It is not the
optimiser's analysis: its verdict is a function of the source and the rule set, and inlining,
specialisation or dead-binding elimination never change it — the optimiser is instead *told*
where the demands are and moves no read across one (A5, §7.6) — McCall's condition that the
guaranteed set be "real guarantees … even in debug builds" and never be "defined … by what `-O`
is able to eliminate in a particular release" (Swift forums 2025, #16).

---

## 4. Soundness

### 4.1 The claim

> **Theorem (the two semantics coincide).** Let `P` be a program every one of whose modules the
> checker accepts — every demand passes K1–K4 against the published summaries of its callees,
> every recursive group's summaries are validated — and let assumptions A1–A10 below hold of the
> runtime, `core/` and the platforms. Then for every sequence of host events, the **value
> semantics** `S_v` (each update allocates a fresh cell and copies) and the **update semantics**
> `S_u` (each accepted update writes its operand's cell) produce the same **trace**: the same
> sequence of observations, where an observation is a byte written to an output stream, a DOM
> write, a call into a `foreign` sibling or `Js` with its arguments marshalled by value, and the
> program's exit.

`S_v` is beni as it is today, and `S_u` is what the backend emits under the rule (§7.5). The
statement is Aspinall–Hofmann–Konečný's Theorem 5.8 (2008 p. 30) — in-place evaluation is
"correct … and complete" against the safe semantics — and Cogent's "immutable and mutable
semantics coincide", restated over traces because beni's observations are effects at the
JavaScript boundary rather than a final value. Linear Haskell proves the same shape for its
arrays: "the semantics with in-place mutation is observationally equivalent to the pure
semantics" (Bernardy et al. 2018 Thm 3.9, hlt.tex 1880–1887).

### 4.2 Instrumented semantics: versions and stale references

Add ghost state to `S_u`: every cell `c` carries a **version** `ver(c) ∈ ℕ`, incremented by each
in-place write; every reference to `c` held anywhere — in a local, a field, an element, a
closure environment, a fiber, a runtime slot, a JavaScript variable — carries the version at
which it was created or last re-obtained from a current reference (a field read of a current
record yields a current reference; a `let y = x` copies `x`'s stamp). A reference is **stale**
when its stamp is below `ver(c)`.

The correspondence to `S_v` is now a function on references: the reference `(c, k)` in `S_u`
corresponds to the cell `c_k` of `S_v`, the `k`th copy in the chain `c_0 → c_1 → …` that `S_v`'s
updates built. Contents agree by construction for current references: the write that bumped
`ver(c)` from `k` to `k+1` in `S_u` is the copy that made `c_{k+1}` from `c_k` in `S_v`, with the
same element written at the same index. Contents of a *stale* reference `(c, k)`, `k < ver(c)`,
disagree with `c_k`: that is the one place the two heaps differ.

> **Lemma 0 (no stale read).** If no step of `S_u` ever dereferences a stale reference, the two
> traces are equal.

Proof: a bisimulation on configurations whose relation is "the same expression, with every
reference mapped by `(c, k) ↦ c_k`"; every step preserves it, because every step reads only
current references (whose contents agree) and the only step that writes — an accepted update —
produces, on both sides, a reference whose contents agree (`c_{k+1}` and `(c, k+1)`). An
observation marshals by value from current references, so it agrees. ∎

So the theorem reduces to: *in an accepted program, no stale reference is ever dereferenced.*

### 4.3 The lemmas

**Lemma 1 (flow facts over-approximate the heap).** At every program point of a declaration, for
every cell `c` reachable from the frame's locals through a path, there is a holder `(x, q)` with
`c ∈ A(x)@q`, or `A(x)@q ∋ ⊤`, or `c` is marked escaped. Proof by induction over the transfer
rules of §2.5 (each rule's result set contains every cell the construct can produce from its
parts; a call's result is bounded by Lemma 3's `res`), with the k-cut yielding `⊤` and every
unsummarised construct yielding `⊤` and escape. This is the standard over-approximation lemma of
a flow analysis; it has the same shape as `write-sets.md` §5.2's "each rule over-approximates".

**Lemma 1b (exclusive contents).** If a container path carries `excl` at a point, then every
concrete cell reachable through it is stored at exactly one position of that container and has
no holder other than the container's path. Proof by induction over §2.9's rules: a set requires
each stored cell unique at the store (Lemma 4 for the store, read as a demand with no write); a
destructive read overwrites the one position before any other read, so the element handed out has
the callback as its only holder; every other store or read clears the flag. ∎

**Lemma 2 (liveness over-approximates future reads).** If `live(h, p)` is false, then no
execution continuing from `p` dereferences the cell held by `h` *through h*. Proof: the uses of
§2.7 cover every construct that can read a value or hand it to something that can — a direct
read, a call (by the callee's summary and Lemma 3), a return, a store, a capture (by the closure's
summary and the `calls`/`escapes` facts of the function it is passed to), and the catch-all for
anything unseen. Backward propagation over the instruction order is the evaluation order
(`language.md` §6), so "after `p`" is well defined.

**Lemma 3 (summary soundness).** For every call `f ā` evaluated in `S_u` with the arguments'
cells `C₁ … Cₙ`:
1. `f` writes a cell of `Cᵢ` only if `use(i, q) = consumed` for the path it sits at;
2. if `use(i, q) = borrowed`, after the call no cell of `Cᵢ@q` is reachable from the result,
   from any place that outlives the call, or from any closure still callable;
3. the result's cells at `q'` are within `res(q')` instantiated with the arguments (`fresh` is
   a cell no holder other than the result has);
4. `fun(j)`'s `calls` bounds the number of calls `f` makes to argument `j` in any execution,
   `escapes = no` means no reference to it outlives the call, and `supply`/`need` bound what
   `f` passes and keeps.

Proof: by induction on the depth of the call tree of the execution. For a non-recursive `f`, the
summary was read off its body under Lemmas 1–2 with its callees' summaries (smaller depth).
For a recursive group, the validated fixpoint is a consistent assignment: each body checks
against the final summaries, so the induction hypothesis for the recursive calls is exactly the
summary, and the body's own analysis gives the summary again. The optimistic start does not
weaken the argument — only the *validated* assignment is used; the search merely finds the best
one. For a `foreign`, the summary is declared and the sibling is trusted (A2). ∎

**Lemma 4 (the dead-alias lemma).** At an accepted demand `u` on operand cell `c`, every
reference to `c` other than the one the demand returns is dead: it is never dereferenced
afterwards, neither by the caller nor by the callee during the call.
Proof: by K1 the cell is known; by K2 it is not escaped, so (Lemma 1) every reference to it is
accounted for by a holder `(x, q)` of the current frame or of a caller's frame through the
parameter chain; by K3 each local holder is dead after the call (Lemma 2); by K4 no other
argument and no capture of a function-valued argument holds `c`, so nothing the callee reads
during the call — its other parameters, its callbacks' environments — reaches `c` (the callee's
own locals that hold `c` are its consumed parameter's aliases, checked by the callee's K-rules
with the parameter as the operand); each parameter-path holder was checked at the caller's call
site, where the same K-rules applied to the caller's holders (Lemma 3, clause 1, transfers the
obligation). Holders in closure environments are covered because a closure is itself a holder
whose liveness bounds its captures' (Lemma 2); a closure that may consume its capture is `once`,
an affine value used at most once and only where `calls ≤ 1`, and its consumed captures are
checked at its creation against its own liveness (§2.6). ∎

**Theorem.** By Lemma 4, after the write at `u` every reference to `c` other than the one the
demand returns is dead, hence never dereferenced; the returned reference is current. Induction
over the steps of the execution gives Lemma 0's hypothesis. ∎

### 4.4 What the proof sketch does not cover, and the reviewer should probe

- **Path-insensitive joins.** `A(e)` for a `case` is the union of the arms; a cell live only
  on the arm not taken is counted as a holder on the other. That is conservative (more
  rejections), never unsound.
- **The k-cut and `⊤`.** Both yield rejection (K1), never acceptance.
- **Concurrency.** Fibers interleave only at suspension points; a cell reachable from two fibers
  is escaped (captured by a spawned thunk, A6), so no demand on it is accepted. Within one fiber
  the sequential argument holds across a park, because the continuation holds exactly the locals
  liveness already counted.
- **Defects.** A defect stops the program (`browser-direct` §8.2); its `finally`-style release
  closures are stored and therefore escaped holders. What a crash screen prints must not include
  program values reachable from a half-run arm (A9).
- **An identity shortcut in `eq`** (`backend.md` §4's table once said `xs === ys` answers `True`
  at once; its *as built* note says `eq` and `compare` "do not answer at once for a list against
  itself"). Either way, such a test can only differ between the semantics when a stale reference
  meets a current one, which is a stale dereference and is excluded.
- **The entry state of `update`** is not covered by a caller's K-rules; §5.9's P5 is the
  whole-program fixpoint that stands in for the caller, and it is where a reviewer should look.

### 4.6 The adversarial review's findings, and where each was answered

A read-only review of the first draft (2026-10-10) found four programs the draft's rules
accepted whose in-place write was observable, and a fifth gap at `update`'s entry. Each is now
a rule; the ledger is kept here so that the reviewer's programs stay the fixtures:

| Found | The program | Answered by |
|---|---|---|
| aliasing between a call's own arguments, and between a consumed argument and a callback's capture | `List.foldl xs xs (λx acc → List.insertAt acc 0 x)`; `g xs (λ_ → List.length xs)` with `g xs k = k (List.push xs 1)` | **K4**, §2.8; Lemma 4 |
| the release optimiser folding a read across a write | `n = List.length xs; ys = List.push xs 1; h ys n` | **A5** rewritten: demands are a barrier to `Opt` |
| a top-level value as a holder | `empty = []; (addOne empty, addOne empty)` | §2.2, §2.5, §2.8: escaped for the program's life |
| a view-event payload that is a model cell or a row item | `onClick={Keep model.rows}` then `List.push rows 0` | **P6** rewritten, P3 narrowed, §5.9 |
| `init` or an earlier arm placing one cell at two model paths; `Cmd` captures not in the write-set pass | `init = xs = …; { a = xs, b = xs }`, then `List.push model.a 1` | **P5** rewritten: the checker's own entry fixpoint, §5.9 |
| a `once` closure passed twice to `calls ≤ 1` positions | `g = λx → List.push acc x; Result.andThen a g; Result.andThen b g` | `once` is affine, §2.6; Lemma 4 |
| `∅` read as "unknown"; `⊤` not prefix-closed; parametricity across `Fiber a` | `Task.join fib` twice, then `set` one | §2.4, §3.7, A6 |
| `core/List`'s writers are beni over `Js`, not `foreign`; `append` returns `ys` when `xs` is empty; derived values in `view` and `verifyAll` under change 1; `==` through a user `eq`; captures per variable; a building function's exit value; the two conflicting `filter` identity promises in `backend.md` | — | §2.6 (asserted summaries, `append`'s row, the emitted-code rule), §2.7, §10 changes 1–2, §8 |

What held: reads before writes, dead aliases, per-arm liveness, record-update field replacement,
the pessimistic default for undeclared `foreign`s, tail-call argument order, views as holders of
their base, the fiber escape argument, and Lemma 1b at the abstract level. The review is the
first evidence this document has that the rule set is *checkable*; the second must be the report
mode of §9.

### 4.5 Assumptions

| | Assumption | Where it is kept, or must be |
|---|---|---|
| A1 | **Only licensed writes.** `core/List.js` writes a cell only inside a declared-`consumed` primitive; no other JavaScript — emitted code, siblings, runtimes — writes a list it did not just make and still exclusively hold. The builder stays linear (`backend.md` §4, invariant 5) | `backend.md` §4 invariant 1, restated: with the trie gone the "claim" exceptions disappear |
| A2 | **`foreign` summaries are true of the sibling.** A `borrowed` parameter is not kept past the call; a `fresh` result is an array nothing else holds; a `consumed` parameter is written only in the declared way | `boundary.md` §4's "a sibling never keeps a list it was given" becomes "never keeps one unless its declaration says `shared`" (§5.7) |
| A3 | **The runtime hands the model over.** The platform's `update`/handler entry declares `model` consumed and keeps no content holder of any list of the old model after the arm; what it needs from the old model it reads before the arm into locals the checker sees, or scalars | `browser-direct` §4.1 step 0, §5.3, §6.1, §7.4; the protocol in §5.9 |
| A4 | **Identity holders never conclude "unchanged" from identity on a written list** | `browser-direct` §7.4 rule 1; §6.2's "a script is guarded by its tag's own condition, never by the list's identity" |
| A5 | **Evaluation order is as specified, and a demand is a barrier to the optimiser.** No call is moved across another or duplicated; every impure call is kept; **and no read of a cell — `xs.length`, `a[i]`, a scalar-view index, a single-use `let` folded into its use — is moved across a demand on that cell.** `backend.md` §9 item 1 today folds a single-use pure binding into its use when only other such bindings stand between (`n = List.length xs; ys = List.push xs 1; h ys n` would become `h(push(xs, 1), xs.length)`), on the strength of `language.md` §6's 2026-10-02 amendment that an evaluation making no call is unobservable against another — which is true only while every list is immutable. The demand summaries therefore become an input to `Opt`, exactly as the `impure` bit already is (item 1's `effect_keep`), and §6's amendment is narrowed to reads not crossing a demand | `language.md` §6; `backend.md` §9 item 1 — **a change to both, not a fact about them today** |
| A6 | **Escapes are total, in both directions.** Every way a value can outlive a frame — a `Cmd`/`Sub` thunk, `Task.spawn`, a `Ref`, a `Queue`, `Js.from`, a sibling parameter not declared borrowed, a stored closure — is a summary that marks the value escaped; and every value the runtime **retains and may hand out again** — a fiber's outcome at `Task.join`, `bracket`'s resource at its release, `Queue.take`'s and `Deferred.await`'s results — is `⊤` on every path | `core/Task`'s and the platforms' `foreign` declarations and asserted summaries |
| A7 | **Continuations are one-shot**; a cancelled fiber never resumes the rest of its body | `transparent-effects-proposal.md` §16.1 |
| A8 | **Core summary rows are true**, each pinned by a `run/` fixture, as the write-set rows are | `write-sets.md` §3.7's discipline |
| A9 | **A defect reads nothing of the program's heap** after it fires, except through escaped holders | `browser-direct` §8.2; to be checked for the development crash screen |
| A10 | **The checker's solved types are the backend's types**: a path is list-typed in the analysis iff the emitted value at that path is a cell | `checker-v2.md` §13; mode crossing is computed from the same types |

Each is a contract that already exists in some form, except A3 (new: §5.9) and the widening of
A2 and A6 (new words on `foreign` declarations, §5.7). A false assumption is a wrong answer, not
a false error — which is why they are listed here and not in §8.

---

## 5. The hard cases

Each case is stated, run through the rules, and marked **solved**, **solved with a cost**, or
**open**.

### 5.1 Closures that only read a captured list; closures called many times

```
total = List.foldl xs 0 (λx acc → acc + List.length ys)     -- reads ys, called n times
zs = List.set ys 0 7                                        -- then edits ys
```

The lambda's summary: `cap ys = borrowed` (it only reads), `once = no`. `foldl`'s class for its
callback: `calls many, escapes no`. The edge check passes (a non-`once` closure may be called
many times). The closure is a holder of `ys` while the closure value is live, which is during the
`foldl` call only (`escapes = no`), so at `List.set ys 0 7` the holder is dead. **Solved**, and
the reason it is solved is that beni's lambdas are in front of the checker: this is the case
research 69 §1.3 item 9 called "the open research question that matters most", open in every
type-based system because a capture counts as a use of the capture's *type* (Wansbrough's
⊢-Abs: "all free variables of an abstraction have at least the usage of the abstraction itself",
1999 §6.1 l. 294; Clean's `addInPlace` false error, research 69 §2.1), and closed in the effect-
and capture-based ones only with declarations (Deng et al. 2025 Fig. 6; Capybara ms.tex:647–671;
Affe's explicit shared borrow `&x`, Radanne et al. 2020 §3.3).

```
ys2 = List.map xs (λx → List.push acc x)                     -- consumes a capture, called n times
```

The lambda's summary: `cap acc = consumed`, `once = yes`. `map`'s class: `calls many`. The edge
`once ⟹ calls ≤ 1` fails: **rejected**, correctly — the first call writes `acc` and returns it,
the second writes the same array, so the result list's first element would change under the
second call. The message names the lambda, the capture and `map`'s call count, and offers the
fold (§6.2, example 4). This is OxCaml's lock rule, "a closure that consumes a captured value
uniquely must be `once`" (Lorenzen et al. 2024 §3.3, p. 10), and Futhark's refusal of a free-
variable consume (2022 post). A closure that consumes a capture and *is* called at most once —
`Task.scope (λscope → … List.push acc x …)`, `Result.andThen r (λx → List.push acc x)` — passes,
because those callees' classes say `calls ≤ 1`. **Solved**, with the cost that a `once` closure
passed to a `many` position is an error even when the program would only ever call it once for
reasons the checker cannot see (a `List.map` over a one-element list).

### 5.2 `▷` pipelines, `identity`, composition and polymorphic plumbing

`▷` is syntax: `xs ▷ List.filter p ▷ List.set 0 v` *is* `List.set (List.filter xs p) 0 v`
(`language.md` §6.7: "pipes rewrite before anything runs"), and a `_` placeholder or a `<-` bind
is a written lambda
(`language.md` §6.7), so there is no plumbing function to lose precision in. `identity x = x` is
inferred `res = {π₁}`; a user-written `apply f x = f x` is inferred `res = g.res` through its
class; a composition `λx → g (f x)` likewise. This is the case Futhark called "lossy" (2026
aliasing post, ll. 555–612) and proposed to fix by parametricity; here the body is analysed and
the class carries the result's provenance, so `id`, `apply` and `|>` keep exact aliasing with
no free theorem needed. **Solved.**

The residual cost is the identity promises of `backend.md` §4 (*Identity: what an operation
returns unchanged*): `filter` that keeps every element returns `xs` itself, `map` whose results
are all `===` returns `xs`, `slice` of everything returns `xs`. Under the rule those are
`res = {fresh, π₁}` — the result *may* be the input — so `List.set (List.filter xs p) 0 v`
demands `xs` unique too. In a pipeline `xs` is usually dead after, so it costs nothing; where
`xs` is used later it is a rejection whose message names the promise. §10 (change 2) asks the
owner whether the promises stay.

### 5.3 Generic code under `where` clauses

`where k.compare : k, k → Order` and `a.eq` are `sync`, read-only by contract: `borrowed`. A
user method's summary is a class on the constraint's method type, bound at each site from the
dispatch table's term (§3.7). Inside the generic body, a call `x.m a` is a call through a
function-typed value whose class is the constraint's; the body's own summary is expressed over
it. **Solved** for precision; the only limit is that a generic body cannot write a value of type
`a` in place (there is no demand of type `a → a`), which is the right answer.

### 5.4 Lists in containers

**A record.** `{ m | rows = List.push m.rows x }`: the operand is `(m, .rows)`; the holders of
that cell are `(m, .rows)` itself and whatever else holds `m` or its `rows`. The update's other
fields are the very values (`language.md` §11.12), so the new record and `m` share every *other*
cell — but not `rows`, which the push's result replaces. After the update `m` is dead unless
read later; a later `m.name` reads a path that does not meet `.rows`, so it is not a use of the
cell (§2.7's per-path liveness). **Solved**: a model threaded through helpers that each touch one
field is accepted, because `use` and `live` are per path, which is what the TEA shape needs
(§5.9) and what research 42's O8 found necessary.

**A tuple, a constructor.** The same, through `.i` and `C#i`.

**A list of lists.** `List.update rows i (λr → { r | tags = List.push r.tags t })`: the lambda's
parameter `r` is an element of `rows`. Two slots of `rows` may hold the same record (`[ r, r ]`),
in which case a push through slot `i` would be seen at the other slot; the cell-set domain
cannot tell slots apart (§2.9). So the derivation needs two things: `List.update` must be a
consuming writer that overwrites slot `i` with the callback's result — a destructive read, so
the slot's old holder is dead during the callback — and `rows` must be **unique and exclusive**.
Then `r` is unique inside the callback, `r.tags`'s only holder is `r`, and the push is in place:
accepted. With `rows` unique but not exclusive (its elements came from a `foreign` that declares
nothing, or from `List.repeat`), it is rejected as a **limit** — "the elements of `rows` may
share" — with the fix `List.copy r.tags`. With `map` in place of `update` under the rule as
asked, `map` is not a writer and `supply = borrowed`: the old `rows` holds every element until
`map` has built its result, so the push is **rejected** as real sharing; under §10's change 1
`map` becomes a destructive read per position and the exclusive case is accepted. This is Lean's
`groupBy`, Clean's propagation rule and the two-slots-one-record hazard in one example.
**Solved with a cost**: a nested edit needs exclusivity, which the program's own construction of
the container must establish, and which §9 counts.

**A `Dict`.** `Dict k v` is a tree of constructors (`static-dispatch-spike.md` §5.3), written in
beni. `Dict.get d k` is a non-destructive read: its result aliases a value inside `d`
(`res = {π₁ contents}`), and `d`'s values stop being exclusive while that result is live.
`Dict.insert d k v` stores `v` (`use(v) = shared`), rebuilds a path and shares the rest with `d`
(`res ∋ π₁`); it keeps `excl` only if `v` was unique at the store. `Dict.update d k f`, written as
a path-copying walk that takes the node's value, calls `f` and rebuilds the node with the
result, is a destructive read: its callback's argument is unique iff `d` is consumed at the call
and `d`'s values are exclusive. The Lean counter-example, `let group = RBMap.find? result x; …
RBMap.insert result x (Array.push group x)` (Huisinga 2023 §2.1, p. 7), is **rejected** as real
sharing with the holder named — `result` is live across the push, it is passed to `insert` after
— and the message offers `Dict.update`, which is accepted when the values are exclusive (B.4).
**Solved with the same cost.** Lean accepts the `find?` form at run time through its reference
count and silently copies; this checker rejects it with the fix on the message.

### 5.5 Recursion and folds

```
go xs acc = case xs of
    [] → acc
    [ x, …rest ] → go rest (List.push acc (f x))
```

`go`'s group is one declaration. Optimistic start: `acc borrowed, res {fresh}`. Round 1: the
tail call passes `List.push acc …` — a demand on `acc`'s cell; holders: `acc` (the operand), and
nothing else in the frame; after the jump `acc` is rebound, so dead. `use(acc) = consumed`;
`res = {π₂}` (the `[]` arm returns `acc`) ∪ the recursive call's `res`, which under the round's
assumption is `{fresh}`; round 2 with `res = {π₂, fresh}` gives the same; validate: passes.
`foldl` in `core/List` is this shape with its callback's class carrying the accumulator's
ownership (`supply owned, need owned`), so `List.foldl xs [] (λx acc → List.push acc x)` is
accepted and runs as research 42's R0 did (2–7× faster than the trie on builds, §6.4 there).
**Solved.** Mutual recursion is the same fixpoint over the group. A group that reaches the round
bound (it cannot: the lattice is finite) would be a `⊤` summary and a limit report.

### 5.6 Branches that keep the old value

```
case List.get xs i of
    Just v  → v
    Nothing → List.set xs i d ▷ List.get … 
```

`v` is an element, not the cell; the `set` writes a slot. Per-arm liveness: `xs` is live after
the `set` only on the `Nothing` arm where it is the operand. Accepted. The shape Rust's problem
case #3 could not accept for eight years (research 68 §7.1) does not arise because beni has no
references into a list: `get` returns the element, not a pointer to the slot.

```
ys = if c then List.set xs 0 1 else xs
```

Both arms: `A(ys) = {site(xs's cell)}` either way — in the then-arm as the demand's result, in
the else-arm as an alias. The demand in the then-arm asks whether `xs` is live after it on that
arm: it is not (the else-arm's read of `xs` is not on the then path). Accepted; `ys` owns the cell
in both arms. **Solved**: Futhark's union-of-both-branches rule (PLDI 2017 ALIAS-IF) is kept for
*cells* (the result may be either) but liveness is per path, so the false error of a value "used"
in the arm not taken does not happen.

What is still coarse: `xs = if c then a else b; List.set xs 0 1` demands both `a` and `b` unique,
so a later read of `a` on the path where `xs = b` is a false error. A known imprecision; §9
counts it.

### 5.7 `foreign` and platform boundaries

A `foreign` has no body. Its declaration carries the summary as it carries the rung and `sync`
(`boundary.md` §4). **The default is pessimistic**: a `foreign` parameter that says nothing is
`shared` (the sibling may keep it — `boundary.md` §4 promises only that a sibling "never writes a
list it was given, never keeps one it will later write", which allows keeping one to *read*, as
`Hosted`'s key storage does) and a result that says nothing is `⊤`. A sibling that only reads
its argument during the call says `borrowed`; one that returns "a fresh plain array that
nothing else holds" (the existing rule) says `fresh`; `Debug.log`'s result says `= π₂`. So a
platform author who writes nothing loses precision and never soundness, and the words are what
`boundary.md` §4's recipe gains. `Js.from x` marks `x` escaped forever (research 42's pin,
O7). A `Js.call` that passes a list is a `foreign` call with no summary: escaped. The checks of
`boundary.md` §4 are unchanged; the new promise is tested the way the rung is: by review and by
the `run/` fixtures that pin each row (A8). **Solved**, by contract; the residual risk is a
sibling that lies, which is a correctness bug in privileged code, the same class as a wrong
rung.

### 5.8 Fibers and commands capturing values

`Cmd.perform (λsend → send (Saved model.todos))` captures `model.todos` in a thunk that the
runtime stores and runs later (`boundary.md` §9.8.2). `Cmd.perform`'s summary: its argument
`escapes = yes` — so every capture of the lambda is escaped at the capture, and `model.todos`'s
cell is shared from then on, in this arm *and in every later dispatch that receives the same
cell in its model* (§5.9). `Task.spawn`, `Task.spawnIn`, `Task.par`'s thunks, `Ref.set`,
`Queue.offer`: the same. A thunk the callee calls synchronously and does not keep (`Task.scope`'s
body, `Task.bracket`'s acquire) is `calls ≤1, escapes no` and captures nothing permanently —
except `bracket`'s *release*, which is stored on the fiber's finaliser list and is `escapes =
yes`. These facts are declarations on `core/Task`'s `foreign`s and inferred for its beni
wrappers. **Solved** by escape; the cost is that a list handed to any command or fiber is shared
until the end of the program, because the analysis cannot see when the fiber reads it. The
message names the capture (§6.2, example 3).

### 5.9 The TEA `update` on `browser-direct`: the handoff protocol

Today's `browser` cannot host the rule: the runtime "keeps the rows it rendered (`s.b`)" and
"every patched hole keeps its last value" (research 42 §9), so every rendered list is a content
holder the program cannot see, and a `List.push model.rows x` in `update` is an error on every
message. Research 42 §6.1 measured it: with the runtime as written "R1 and R2 never write the
table in place". `browser-direct` removes the holds by design: no `view` at run time, no
`lastRendered`, slots hold leaf values (§5.3), instance arrays hold *items* and compare them by
identity (§6.1–§6.2), scripts are guarded by tags and never by list identity (§6.2), and "the old
model is dead after the arm" (§7.4). What remains is to state the contract the checker reads.

**The protocol (P1–P6), as obligations on the platform's lowering and runtime:**

- **P1 — handover.** The handler calls the arm with `model` **consumed**: after the arm, the
  runtime holds no content reference to any list reachable from the old model. The module-level
  `model` variable is reassigned by the arm (`model = …`, §4.1 step 1).
- **P2 — reads before the arm are the handler's.** Anything the handler needs from the old model
  (§4.1 step 0: index symbols, a derived value's old input) is read *before* the arm into
  locals; a list read this way is an ordinary holder of the handler, analysed by the same rules
  (so a script that reads the old list and compares it after the arm is a sharing error the
  lowering must not write — today's scripts read scalars and the *new* list, §6.2).
- **P3 — items are read only by the lowering's own code, and only as the lowering says.**
  `insts[i].it` is compared by `===` by the scripts (A4), and a row's groups read the *new*
  item. The one program-visible read through an instance is a **listener body**: `browser-direct`
  §4.2 reads a handler's arguments "at the event, not captured" — `onClick={Select model.id}`
  reads `model.id` when the click comes, and a row's handler reads "a row's instance through its
  root". A listener body is therefore program code the checker analyses: it reads the model and
  the item *before* the arm (it computes the payload), and what it hands the arm is P6's.
- **P4 — slots are leaves or recomputed.** A derived value's slot holding a list is recomputed
  by every key whose write set conflicts with its reads (§5.4) before any group reads it; the
  old slot value is never dereferenced after the arm. This is `write-sets.md` §1.3's soundness,
  which already covers in-place writes once "changed" is read as "possibly changed in content"
  rather than "not `===`" (§7.4 there; §7.4 here).
- **P5 — the entry state is a whole-program fixpoint of the checker's own.** `update` has no
  caller to discharge K2–K4 for it, so the checker computes the abstract value of `model` at
  entry itself: the join, over `init`'s result and every arm's result, of the cell sets at every
  model path, iterated to a fixpoint over the arms (one round per cell the arms can place, in
  practice two). Two things come out of it. **Aliasing between paths**: `init = xs = List.range
  1 3; { a = xs, b = xs }` puts one cell at `.a` and `.b`, so a `push` on `model.a` fails K4
  against `(model, .b)` — the write-set pass cannot see this (its `Rec(none, …)` places two
  `Lst` nodes with no alias fact) and the checker must. **Escapes across dispatches**: a cell any
  arm captures in a `Cmd`, a `Sub`, a stored closure, a `Debug`/`Js` call, a `Send`, or a
  message payload a view event reads (P6) is escaped at every entry, because the runtime may hand
  the same cell back in the next model. `browser-direct` §7.4's condition (2) names the same set,
  but its scan is S7's future work (§11 item 4 there) and `write-sets.md` §3.3 analyses no
  command ("the command is not analysed"); the checker owns this computation. The entry summary
  is then `use(model, p) = shared` for every escaped or aliased path, `consumed` otherwise.
- **P6 — payloads.** A message's payload list is unique at the arm **only if nothing else holds
  it when the arm runs**. Two senders exist. A program sender — a fiber calling `send (Got
  rows)` — gives it up: `Send msg` is asserted `consumed` for the message, so a sender that reads
  `rows` afterwards is rejected at the sender, and the arm may edit `rows` in place. A **view
  event** whose handler expression is a model path or a row item (`onClick={Keep model.rows}`,
  `onClick={Tag row.tags}`) hands the arm a cell the model still holds: such a payload path is
  **shared at the arm** (it is one of P5's escapes), and the message offers to copy it in the arm
  or to send an id instead of the list.

Under P1–P6 the derivation for the table app's `Swap` and `Update` and for the browser corpus's
`KeyedInPlace` (`List.update model.rows 1 …`, `List.push model.rows …`) is: `model` consumed at
entry; `model.rows` not escaped by any arm (nothing captures it); the arm's operand `model.rows`
has holders `(model, .rows)` and nothing else; `model` is dead after the arm (P1); accepted,
and the write is `a[i] = v` on the plain array — what `browser-direct` §7.4 calls
"container-owned" and planned for S7, derived here from the general rule rather than from a
model-specific one. **Solved**, conditional on P1–P6 being written into `browser-direct.md` and
kept by its lowering; P2 and P5 are the obligations that need sentences the document does not
have, and P5 is work: the entry fixpoint is the one whole-program computation in this design.

**Derived values and `verifyAll` are reads, never demands.** A `let` of `view` compiled into a
derived value (`browser-direct` §5.4) — TodoMVC's `<For each={List.filter model.todos (visible
model.filter _)}>` is one — is recomputed by handlers while the page's `model` is live for the
whole dispatch and beyond; and §8.3's development `verifyAll()` re-evaluates every derived value
after each dispatch "and must change nothing unless the compiler is wrong". So no expression a
derived value or `verifyAll` evaluates may be a demand: the rebuilds there are the fresh-building
forms. Under the rule as asked that is automatic (`filter` and `map` are not demands); under §10
change 1 it must be said, and it is the reason change 1 cannot be one function (§10).

### 5.10 `List.copy`

`copy : List a [borrowed] → List a [fresh]` — a shallow copy, `a.slice()` (or `$plain().slice()`
of a view). Shallow: the elements are the same values; records are immutable and need no
copying; a *nested* list inside an element is still shared, and editing it is still an error
whose message names the inner holder, with the fix `List.map xs List.copy` (or a copy at the
inner edit). The identity of a copy is new, so a `For` keyed by reference sees new rows — which
is the right answer for a list whose contents the program is about to change behind the
original's back. `copy` of a list already unique is legal and wasteful; the report mode counts
such calls so that the owner can see whether a `copy_of_unique` warning is wanted (rule 7:
a warning, never a refusal). **Solved.**

### 5.11 Views: a pattern's `rest`, `tail`, `drop`

`[ x, …rest ]` binds `rest` to a view `(b, o)` of `xs`'s base (`backend.md` §4). A view is a
holder of the base cell, and a write through a view is a write to the base: `List.set rest i v`
is `b[o + i] = v`. So the demand on `rest` asks that every holder of `b` — `xs` included — be
dead. In the common walk (`go rest …` with `xs` not read again) it is; where `xs` is read after,
it is a correct rejection: the elements *are* shared. A view is always a suffix of its base
(`backend.md` §4), so `push` on a view is `b.push(v)` and a new header, O(1); `pop` likewise. The
scalar-view rewrite (`backend.md` §8) removes most views from loops anyway. **Solved.**

### 5.12 `Ref`, `Queue` and other mutable cells

`Ref.get r` returns an alias of whatever is in the cell; `Ref.set r xs` stores `xs`; the analysis
cannot see who else called `Ref.get`. So a list stored in a `Ref` is **escaped**, every `Ref.get`
result is `⊤`-held, and `Ref.update r (λxs → List.push xs x)` is rejected with a limit message
(the checker cannot see the cell's other readers). **Open as a precision limit**: a linear-cell
discipline (the cell is the only holder and `update`'s callback consumes its argument) would
need a proof that no `Ref.get` result is live across the `update`, which is a whole-program
fact about an unbounded set of readers. The fix is `List.copy` in the callback, or a `Ref` of a
`Dict`-like persistent structure. Measured by §9.

### 5.13 Messages as values, `Html.map`, subscriptions

A message stored in the model, logged whole or mapped by `Html.map` with a non-constructor
function is a value (`browser-direct` §4.4); its payload lists are shared where the message is
shared. A handler payload passed as parameters (the common case) is P6. **Solved.**

### 5.14 An undo history, a diff, a snapshot

`{ model | history = [ model.todos, …model.history ], todos = List.push model.todos t }`: the
record update evaluates fields in written order (`language.md` §6), so `history` holds the old
cell when the `push` runs — a live holder; **rejected**, correctly, and the message says that the
undo entry would change with the push and offers `List.copy model.todos` in the history (O(n)
per edit, the price of a version). A persistent-vector library in beni (the trie, as a `Dict`-like
module with no in-place writes) would give O(log n) versions for programs that want them; it is
a library, not a representation of `List`. **Solved**, with the cost stated.

### 5.15 Debug, the crash screen, `Debug.toString`

`Debug.log tag x` reads `x` now and returns it (`write-sets.md` §3.7 row); `Debug.toString` reads
now. Neither is a holder after the call. The development crash screen must print only the
exception and the stack (A9); if it ever prints the model, it reads a half-updated record and
the two semantics differ *after* the program has stopped — a difference in a debugging aid, not
in the program, but one to state. **Solved**, with A9 recorded.

### 5.16 The release optimiser's single-use inlining and specialisation

Inlining substitutes a body at a call, which preserves evaluation order and the holders
(`language.md` §6); the verdict was computed on the unspecialised source and is not recomputed.
Whole-program specialisation (`backend.md` §9) may make a copy of a callee per site, which may
be *more* unique than the general summary; the rule ignores it, so the accepted set is the
source's, never the optimiser's (McCall). **Solved** by construction, with the cost that a
program the specialiser could have proved safe is still rejected.

---

## 6. Errors

### 6.1 What a message must do

Three places, a consequence, a fix, and a verdict on whether this is sharing or a limit. The
three places are Rust's three points — the borrow, the invalidating action, the later use — with
the blame on the action: "the error, conceptually, is to perform an invalidating action in
between two uses of the reference" (RFC 2094, *Leveraging intuition*). Futhark names the two
sites and offers `copy` on every entry of its error index (§8.1.1–§8.1.13), and its 2021 lesson
is that unnamed intermediate results must be given a description the user can read: "Consuming
result of applying "iota" (at 2:23-28)" (2021 post, l. 236). Hylo draws the arrow from the
consuming site to the later use and "will offer to insert these copies for you" (tour, l. 60).
Czaplicki's two rules apply unchanged: the code as written, above the message; a hint under
it, every time (2015). Wrenn and Krishnamurthi's frame — a message is a classifier of code into
"look here" and "do not look here", and its highlights should be exactly the places an edit
could go (2017 §2, §8.4) — fixes the highlight set: the kept place, the edit, the later use,
nothing else. Marceau's warning that highlights have "an over-focusing effect" and that
"expected … found" wording "suggests that the definition is fine and the use problematic" (2011
§7.2) is why the message blames none of the three alone.

Crichton's finding is the one that shapes the verdict line: learners "could usually predict why
the borrow checker would reject a program" (64–78 %) "but could only fix the program in 46 % of
cases … and could only create a counterexample in 31 %", and "only 3/15 participants" saw that a
rejected program was in fact safe (2023 §2.4). A sound-and-incomplete checker's errors "may
arise from either ownership-unsound behavior or limitations of the analyzer. Understanding this
distinction is essential for fixing ownership errors" (2020 abstract). So every message says
which it is, and how it knows.

### 6.2 Examples

**1. A later read (real sharing).**

```
-- EDIT OF A LIST STILL IN USE ------------------------------------ src/Main.beni

`List.push` changes a list in place, but this one is still needed afterwards.

12|     saved = model.todos
                ^^^^^^^^^^^ `saved` keeps the list here
15|     next = List.push model.todos todo
                ^^^^^^^^^^^^^^^^^^^^^^^^^^ the list is changed in place here
19|     List.length saved
                    ^^^^^ and `saved` is read here, after the change

If the change happened in place, `saved` would already contain `todo` when it
is read on line 19: `List.length saved` would be one more than before.

To keep `saved` as it was, copy it:

    saved = List.copy model.todos

Or, if `saved` only needs the list before the change, use it before line 15.

This is sharing the checker can see: the list is read on line 19 on every path
through this function.
```

**2. A closure that keeps the list (real sharing).**

```
`List.set` changes a list in place, but a function still holds it.

 8|     show = λi → String.fromInt (List.length rows)
                                                ^^^^ `show` holds `rows` here
11|     rows2 = List.set rows 0 r
                ^^^^^^^^^^^^^^^^^ the list is changed in place here
14|     { model | label = show 3 }
                          ^^^^ `show` is called here, after the change

`show` would see the changed list. If that is intended, call `show` with a
copy: `show = λi → String.fromInt (List.length (List.copy rows))` — or compute
what `show` needs before line 11.
```

**3. A command that captured the list (real sharing, across dispatches).**

```
`List.push` changes `model.todos` in place, but a command started by another
message may still be reading it.

-- in the arm for `Save`:
41|     Cmd.perform (λsend → send (Saved (encode model.todos)))
                                                 ^^^^^^^^^^^ the command keeps `model.todos`
-- in the arm for `Add`:
27|     { model | todos = List.push model.todos todo }
                          ^^^^^^^^^^^^^^^^^^^^^^^^^^ changed in place here

A command runs after `update` returns and may run after later messages, so the
list it keeps is the same one `Add` changes. To give the command its own copy:

41|     Cmd.perform (λsend → send (Saved (encode (List.copy model.todos))))

Or encode before the command is made:

40|     text = encode model.todos
41|     Cmd.perform (λsend → send (Saved text))
```

**4. A once-closure called many times (real sharing).**

```
This function changes `acc` in place, but `List.map` may call it once per element.

 7|     List.map xs (λx → List.push acc x)
                     ^^^^^^^^^^^^^^^^^^^^ changes `acc` in place
        ^^^^^^^^ `List.map` calls it for every element of `xs`

Each call would change the same list, so the result of the first call would
change under the second. To build a list by adding to `acc`, fold:

 7|     List.foldl xs acc (λx acc → List.push acc x)
```

**5. A checker limit.**

```
`List.set` changes `rows` in place, but the checker cannot tell whether anything
else still holds it.

14|     rows = Js.to raw
               ^^^^^^^^^ `rows` came from JavaScript here, which may keep it
17|     List.set rows i v
        ^^^^^^^^^^^^^^^^^ changed in place here

This is a limit of the checker, not proof of sharing: nothing in this module
reads the old `rows` after line 17, but the checker cannot see what JavaScript
does with the array it gave you. To be safe, copy it once where it arrives:

14|     rows = List.copy (Js.to raw)
```

### 6.3 The shape, fixed

```
<TITLE> ------------------------------------------------------------ <file>

<one sentence: what primitive, what list, why that is a problem here>

<the kept place, in source order, with a label beginning "… keeps"/"… holds">
<the edit, with the label "changed in place here">
<the later use, with the label "… read/called here, after the change">

<one or two sentences: what the program would see if the change happened in place>

<the fix, machine-applicable, as a replacement line, "To … , copy it: …">
<an alternative fix that avoids the copy, when there is one>

<the verdict line: "This is sharing the checker can see: …" or "This is a limit
 of the checker, not proof of sharing: …", naming the limit>
```

The suggestion is `MachineApplicable` in rustc's vocabulary: the compiler can insert `List.copy`
at the kept place by itself (rustc-dev-guide, *Suggestions*). "Did you mean" is not used; the
word "illegal" is not used.

### 6.4 Telling a checker limit from real sharing: the derivation tag

Every fact the checker derives carries a tag: **exact** when it comes from a read the source
shows (a variable occurrence, a field access, a call whose summary was inferred from a beni
body, a capture in a lambda written here), or **approximate** when it comes from one of the
checker's own limits:

| Limit | Tag text |
|---|---|
| a `foreign` or `Js` with a declared `shared` or no summary | "came from / was given to JavaScript, which may keep it" |
| a cell marked `⊤` by the k-cut or a width cap | "the value is nested deeper than the checker follows (8 steps)" |
| a path-insensitive join (§5.6's second shape) | "the list may be either `a` or `b` here; the checker treats it as both" |
| a `Ref`/`Queue` read | "was taken from a `Ref`, whose other readers the checker cannot see" |
| a method whose summary is pessimistic (an unannotated platform `foreign`) | "`M.f` declares nothing about what it keeps" |
| `calls many` for a closure the program calls once in fact | "`List.map` may call it more than once" |

A rejection whose derivation uses only exact tags is **real sharing**: there is a path through
the program text on which the old version is read after the edit. One that uses an approximate
tag is **possible sharing**, and the message names the limit. This is Crichton's distinction
made mechanical, and it is also what §9's experiment counts. A third thing the tags give for
free is Swift's "compiler bug" sentinel (DiagnosticsSIL.def, ll. 987–996): a rejection with no
derivation at all is an internal error, never a user error.

### 6.5 The stability rule

> A program the checker of release *n* accepts is accepted by every release *m > n*.

The accepted set is defined by the rules of §2–§3, not by what any optimiser removes (McCall:
"these guarantees would have to be real guarantees … even in debug builds"; Farvardin: checking
must happen "earlier in the optimization pipeline, just to guarantee stability across different
versions"). Precision improvements are additive — a finer path language, a container function
that gains an exact summary, a once-closure that gains a `calls ≤ 1` position — and each only
removes approximate tags. The one legitimate exception is a **soundness fix**: a rule found
unsound (Futhark's 2026 self-aliased abstract type is the model) may reject previously accepted
programs, and must do so with a diagnostic that says so and a `beni fmt --migrate-…` where a
mechanical rewrite exists. The rule set is versioned in the interface format (a summary block
version), so a cached interface from an older rule set is a miss, never a silent mix.

---

## 7. Interaction with the rest of beni

### 7.1 The checker: a pass after type checking

The ownership pass runs where `Effects.run` runs — after P5, with every type solved, before P6
and publication (`checker-v2.md` §26) — and for the same reason Futhark gave when it moved alias
checking out of its type checker in 2026: the old design "had always been hindered by having to
work with incomplete type information", and a separate pass over "a fully well-typed program …
simply had to figure out whether any of the in-place constraints were violated (essentially,
whether in-place updates are semantically observable)" (2026 rewrite post, ll. 110–117). Its
messages carry the solved types, and it never touches `unify` or the store. It needs one thing
the checker does not keep today: the solved type of every BIR instruction, or at least of every
list-typed one, to decide paths and crossing. The write-set pass already asks the checker for
"paths [that] are typed, which the checker's solved types make possible" (`write-sets.md` §2.1),
so the hook exists.

It also needs a per-instruction *cell site* id (the instruction index, as the write-set pass uses
the instruction for its index symbols) and, for messages, the source span of every holder, which
the instruction's `main_token` gives (`frontend.md` §3.6).

### 7.2 Effect bits

The two inferred bits and the ownership classes ride on the same function-type sites, are solved
in the same per-module phase and are published in the same kind of block. They interact in one
place: a function that **suspends** parks its locals in a continuation (`transparent-effects-
proposal.md` §16); the continuation is one-shot (A7), so a parked local is the same holder it
was, and liveness is unchanged. A `sync` demand says nothing about ownership. An `impure` call
is a call like any other for holders; the optimiser's duty to keep every impure call in place
(`language.md` §6) is what A5 relies on.

### 7.3 Static dispatch

A method call's callee is the dispatch table's term (`checker-v2.md` §13.1); its summary is the
callee's. A `param` term (evidence the enclosing function receives) is a class instantiated at
the caller, §3.7. Derived `eq`/`compare` are read-only (`borrowed`). The `where` suffix and the
summary block are both inferred facts in the interface, and both churn the same way; research 19
§4's instrument can measure the second as it measured the first.

### 7.4 Write sets

Two reads and one restatement:

- **The checker computes the entry state itself** (P5) and reads from the write-set pass only
  the program's shape: which declaration is `update`, which `init`, the key tree. The escape
  scan `browser-direct` §11 item 4 lists for S7 is this computation, done once here for both;
  the write-set interpreter does not analyse commands (`write-sets.md` §3.3, *Effects*) and
  records no aliasing between two model paths, so it cannot supply it.
- **The write-set consumer reads nothing new**, but its soundness statement must be read with
  one word changed. `write-sets.md` §1.3 defines "changed" as "not the same value: not `===`".
  Under in-place writes a `value` write at `ρ.rows[k]` leaves `M'@ρ.rows === M@ρ.rows`. The write
  set still *names* the path (the `Lst(p, kept, [k], …)` row is read off the arm's text, not off
  identity), so a consumer that calls the groups the write set names is still correct; what it
  may no longer do is conclude "unchanged" from `===` on a list path — which is exactly
  `browser-direct` §7.4's first rule and §6.2's tag guards. The restatement: *"changed" means
  "may differ in content from what was there before the dispatch"*, and `write-sets.md` §5.4's
  requirement 1 ("an in-place list write never touches a list a program still holds") becomes
  this checker's theorem rather than a requirement on the emitter.
- **The write-set interpreter is the right engine for the model paths, not for the general
  checker.** It is whole-program, per message key, and tracks identity; the ownership checker is
  per function, directional over cells, and publishes summaries. They meet at `update`'s entry
  (P5) and nowhere else.

### 7.5 The backend: in-place emission, and what replaces the trie

Under the rule every accepted demand is in place, so the backend needs no per-site decision: it
emits each writer's call as it does today, and `core/List`'s writers *are* the in-place
operations:

| primitive | today (`backend.md` §4) | under the rule |
|---|---|---|
| `set xs i v`, `update`, `swap` | copy ≤ 256, else trie path copy | `a[i] = v` on the base; O(1) |
| `push xs v` | copy < 32, else tail claim | `a.push(v)`; amortised O(1) |
| `pop xs` | copy ≤ 256, else header | `a.pop()`; O(1) |
| `insertAt`, `removeAt` | O(n) plain copy | `a.splice(i, …)`; O(n) memmove, what vanilla writes |
| `cons x xs` (`[ x, …xs ]`) | head claim / ≤ 31 copy / convert | `a.unshift(x)`; **O(n)** (§8) |
| `append xs ys` | push onto a trie or concatenate | `for (y of ys) a.push(y)`; O(\|ys\|) |
| `copy xs` | — | `a.slice()` |
| a write through a view `(b, o)` | — | the same on `b` at `o + i`; a new header for `push`/`pop` |

The **trie goes**: E1tp's claims, the radix offset, the head and tail buffers, `$plain()`'s cache
and the thresholds (`backend.md` §4, *E1t*, *E1tp*) exist to make writes to *shared* lists cheap,
and under the rule no shared list is ever written. What stays: the plain form, the view form
(for a pattern's `rest`, with the scalar-view loop rewrite still removing most of them), the
builder (`backend.md` §8), and the three-point protocol for readers (`length`, `Array.isArray`,
`$plain()`, the last now only for views). Research 42 §7.4 measured the sibling at 706 bytes
brotli without the trie against 1 514 with it, and research 40 measured the write half at ~450 B
in context; `browser-direct` §7.2 found the table app shipping the write half for a list it only
reads. All of that is removed. `List.beni`'s loops are unchanged.

What the backend must still keep: the identity promises it chooses to keep (§10, change 2), the
builder's linearity (invariant 5), and the fact that `Basics.append` on `appendable` stays a
sibling copy (`language.md` §6.8) — `++` on lists is `List.append`, a demand on its first
argument, which §10 (change 4) asks the owner to confirm.

### 7.6 The release optimiser

The verdict is a function of the source; `--release` emits the same in-place calls as the
development build, so "a release build behaves exactly as the development build does" holds with
no new exception — **provided the optimiser treats a demand as a barrier** (A5). Today's item 1
(`backend.md` §9) folds a single-use pure binding into its use across other such bindings,
because `language.md` §6's 2026-10-02 amendment lets evaluations that make no call commute; a
read of a cell and a demand on it do not commute, so the demand summaries become an input to
`Opt` as the `impure` bit is, and a read of a cell is never moved across a demand on it. With
that, the rest of the contract carries over: an unused binding whose right-hand side is a pure
call may be dropped (an unused `List.set` is then not performed, which no reader can tell), two
surviving calls are never reordered, inlining substitutes bodies and never duplicates an
argument's evaluation. Single-use inlining may inline a `once` closure's body into its one call.
The specialiser's copies inherit the general verdict (§5.16). `Minify` and `Rename` touch names,
not writes. `derived_bytes` and reachability are untouched: `copy` ships only when reached.

### 7.7 Records in place (`browser-direct` S7)

Not in this thesis's scope, but the same machinery applies: a record path is a "cell" whose
demand is the record-update-in-place the lowering would emit; its holders are the same places;
`language.md` §11.12's identity promise becomes the only difference (a written record keeps its
identity, which §7.4's rule 1 already forbids the renderer from relying on). The one hazard is
that records *are* compared by identity by the renderer everywhere (the per-hole reference
check, rule 8), so record paths need a stronger A4 than lists do; §7.4 (there) already states
the two rules.

### 7.8 Incremental builds

The summary block is in the interface and the hash; the firewall fires when it changes. Two
consequences, both to be measured (§9): churn (a body edit that turns a `borrowed` parameter
`consumed` re-checks every importer — necessary, since their K-checks change), and the warm
budget (`fast-compiler.md` §2: 15 ms for a body edit, 60 ms for a signature edit). A body edit
that changes a summary *is* a signature edit under this design, and `plans/queue.md` row 55
records that signature edits do not yet meet their budget for other reasons.

### 7.9 Determinism

§3.10. One addition for the dump: cells print as `site <decl>:<inst>` and `param <i>.<path>`,
both source-derived; summaries print in scheme-site order; holders in source order. The
`--jobs=1`/`--jobs=8` scenario byte-compares the ownership dump beside the others.

---

## 8. Rule 7: what the rule costs, plainly

Rule 7 says a restriction stays only when it buys a guarantee. This rule buys a **performance
guarantee** — every list write is O(1) or the O(n) vanilla pays, no hidden copy, no trie, no
reference count, a smaller runtime — at the price of rejecting programs that are **correct** under
value semantics. The owner has said he wants the error. Here is what it costs, without softening.

**Programs that are rejected.** Every one of these is a correct beni program today:

1. Keeping an old version: an undo history, a snapshot for a diff, a "previous" field in the
   model, a test that holds its input and compares it with the output.
2. A command, fiber, subscription or stored closure that captured a list which a later message
   edits (§5.8) — the beginner's `Cmd.perform (λsend → send (Saved model.todos))`.
3. A closure that edits a captured list and is passed to `map`, `filter`, `sortBy` or any
   `many` position (§5.1).
4. A list read out of a container that is still live — `Dict.get` then `push`, `List.get` of a
   list of lists then `push` on the element while the outer list lives (§5.4).
5. A list from JavaScript, a `Ref`, a `Queue` or any `foreign` without a summary (§5.7, §5.12):
   a *limit*, not sharing, and the message says so.
6. Anything the checker's joins or cut cannot follow (§5.6's second shape; a model nested more
   than k deep): limits.

The fix is one call, `List.copy`, in every case — Futhark's "an alias-related type error can
always be fixed by copying" (2022 post, ll. 127–131) — and the message writes it. What the fix
costs is a copy where the program meant to share, which for case 1 is the program's intended
semantics and for cases 5–6 is a copy the checker made the programmer pay for its own blindness.

**What it costs the representation.** The trie's reason to exist is gone and so is its
persistence: a program that wants versions pays O(n) per version, explicitly. `[ x, …xs ]` onto
a long unique list is `unshift`, O(n), so an Elm-style prepend accumulator is quadratic again
unless the building-loop rule (`browser-direct` §7.2, `backend.md` §8) catches it — it catches
the `go acc` shape and not `foldr`'s lambda. Research 46 §11 measured the E1tp cases it fixed at
11–2 500× the cons list under plain copies at 10 000 elements. §9 measures how much of the
corpus prepends outside the rule.

**What it costs the API.** A `pub` function's summary is part of its contract; editing a body
can break a caller in another module with an ownership error the caller's author did not write
(Klabnik, research 69 §1.3 item 5). The firewall makes it visible, not painless.

**What it costs learners.** The error fires first in `update`, where Crichton found Rust's
drop-off ("Chapter 4 [Ownership] is a significant drop-off point", 2024 §3.1), and learners who
can say why a program was rejected still fix it only 46 % of the time (2023 §2.4). The message
design of §6 is the mitigation; it is not a guarantee.

**What the owner's own programs say.** TodoMVC and Conduit contain no call of `set`, `push`,
`update`, `swap`, `pop`, `insertAt` or `removeAt`; their only demands under the rule as asked
the `++` sites on lists: TodoMVC's `model.todos ++ [ new ]`, where the record built just before
it holds the old cell at `.todos` until `changed` replaces that field — accepted — and Conduit's
twenty-one, of which eight have a model path on the left (`{ model | errors = model.errors ++
Api.errorMessages error }` in `ArticlePage` five times) and are accepted by the same argument,
the rest literal or fresh; `core/` has seven `push`es, every one an
accumulator in a fold or a loop
(`Result.combine`, `Result.partition`, `Dict.keys`/`values`/`toList`, `Schedule`); the browser
corpus has about fifty sites,
written to exercise the direct platform's scripts. So the rule as asked changes nothing in the
two real applications, and the in-place writes they would benefit from are `List.map model.todos
(λt → …)` and `List.filter` — which are not demands unless §10 change 1 makes them so. If it does,
TodoMVC's `Toggle` becomes `a[i] = f(a[i])` over a unique `todos` (P1–P6 hold; `changed` is
`{ model | todos = todos }`, a record update whose other fields do not meet `.todos`), and
`Destroy`'s `filter` compacts in place. Then the same rule also rejects `List.map` over a list the
program keeps — which TodoMVC's `view` **does** do: `<For each={List.filter model.todos (visible
model.filter _)}>` is a derived value the handlers recompute while the page holds `model`
(§5.9). So change 1 cannot be one `filter`: the rebuild in `update` writes in place, the same
spelling in a derived value must build fresh, and that is a static split by position or two
functions (FP²'s "two reverses"), stated in §10.

**Escape hatches that exist or could.** `List.copy` (always). A persistent-vector library in beni
for programs that want versions (not a representation of `List`). A **warning mode** —
`--ownership=warn` — that keeps the trie and copies where the checker would reject, printing the
same message as a warning: it is rule 7's "make it a warning" route, it is the form every
silent-fallback language ships (Lean's `dbgTraceIfShared`, Koka's `fip` warnings, Roc's proposed
"clippy-like check"), and it costs the owner the one thing he asked for, "no silent fallback" —
except that the fallback is not silent. This document recommends shipping the report mode first
(§9) and deciding error versus warning on its numbers; it does not recommend the warning as the
end state, because a warning that copies makes the cost model depend on whether the author read
the warning.

---

## 9. What to measure before deciding

The literature has no false-error rate for an inferred uniqueness checker in a functional
language (research 69 §3, "what is missing"); beni can produce one in a week. The experiment is
the report mode the write-set pass had (`write-sets.md` §8): build the analysis, run it as a
dump over real programs, classify every rejection, decide on numbers. Wrenn and Krishnamurthi's
frame: a checker's errors are a classifier, so measure its precision (2017 §2).

### 9.1 The dump

`beni dump --stage=owners` prints, per module:

```
summary <Decl>
  param <i>.<path> <borrowed|shared|consumed> [reason <tag>]
  result <path> {<param paths>|fresh}
  fun <j> calls <0|1|many> escapes <no|yes>
demand <Decl>:<inst> <primitive> operand <cells>
  unique                                              -- accepted
  shared <holder> kept-at <inst> used-at <inst> exact  -- real sharing
  shared <holder> … approx <limit-tag>                 -- possible sharing (a limit)
  unknown <limit-tag>                                  -- K1/K2 failure
copy <Decl>:<inst> of-unique                           -- a copy of a list that was already unique
prepend <Decl>:<inst> <in-building-loop|loose>
cap <which> fired at <Decl>
```

The dump is corpus-tested like the writes dump (`tests/corpus/owners/`, one golden per fixture),
deterministic (§7.9), and produced by `check`, not `build`: nothing reads it, no emitted byte
moves, no run hash changes — the write-set pass's exact arrangement (`write-sets.md` *as built*,
2026-10-09).

### 9.2 The demand set, as a flag

The dump takes a hidden `--owners-demand=writers|rebuilds` so that the same run reports both the
rule as asked (the eight writers) and the widened rule (§10 change 1: plus `map`, `indexedMap`,
`filter`, `filterMap`, `reverse`, `sort`, `sortBy`, `sortWith`, `take`, `slice`). Every count below
is reported for both.

### 9.3 The corpora and the counts

Run over `core/`, every `tests/corpus/` fixture (`run/`, `browser/`, `writes/`), `bench/todomvc`
(the four builds), `examples/conduit`, `bench/ui/apps/beni` (the table app and the sweeps), with
the `browser-direct` platform's P1–P6 assumed for TEA programs (the entry summary of `model` from
the write-set escape facts). Report, per corpus and in total:

| Count | Meaning |
|---|---|
| demands | update sites (per demand set) |
| accepted | unique at the site |
| rejected-exact | real sharing, by holder kind: local later read / closure / command or fiber / container / payload / view |
| rejected-approx | by limit tag: `foreign`/`Js` / `Ref` / k-cut / join / pessimistic summary / `calls many` / elements may share (§2.9) |
| exclusive containers | container paths that carry `excl` at a destructive read, against those that do not, and what cleared it |
| copies-of-unique | `List.copy` calls the checker would have allowed without |
| prepends-loose | `[ x, …xs ]` sites outside a building loop (the O(n) ones) |
| summaries changed per edit class | research 19 §4's four edit classes applied to `core/`: how many interfaces move |
| check time | `--self-profile`'s `owners` event beside `check`, cold, ReleaseFast, on the bench corpus and Conduit |
| widest `w` | the largest number of tracked paths in any declaration |

### 9.4 Hand classification

Every `rejected-exact` is read by a person and classified: **intended sharing** (the program
keeps the version on purpose: an undo, a snapshot), **accidental sharing** (the program would
have been wrong-but-fast had the write been in place: this is the bug class the rule exists to
catch), or **avoidable** (a reordering or a fold would make it unique). Every `rejected-approx`
is classified by whether a known extension (a `Ref` discipline, a wider k, a path-sensitive
join, a summary on a platform `foreign`) would accept it. The table is the one Sisal's report
made by hand (Cann, Feo, DeBoni 1990 Table I: 293 copy sites, 264 removed, 25 real sharing, 4
undecidable) and research 69 §1.1 reread.

### 9.5 Performance and size, after the fact

If the decision is yes, the second experiment is research 42's harness with the trie removed:
`bench/arrays` scenarios under plain arrays written in place (R2-plain's numbers without R2's
counts), `bench/size.mjs`'s page lines, `browser-direct`'s S2/S3 sweeps. The expected shape is
research 42 §6.4's builds (2–7× faster), §6.3's steady ticks (0.43–0.69×), §6.1's TEA rows
(hidden by the walk), and §6.5's history (gone: the program must copy). This is measured, not
assumed.

### 9.6 What a brief for the implementer must contain

The dump format above; the demand flag; the P1–P6 entry assumption as a per-program fact read
from the write-set pass; the derivation tags; a fixture per rule of §2.5 and §3.4 (red first);
the determinism scenario; the `--self-profile` event; and the hand-classification sheet with its
three columns. No emitted byte changes. The pass is specified in `docs/design/` before it is
built (rule 1); this document is research, not that specification.

---

## 10. Candidate language changes, for the owner

The owner has said the specification is open where the checker needs it. Each change below says
why, what precision it buys, what it costs developers, and how it weighs against rule 7
("guarantees, not restrictions"). None is required for soundness; each is a trade.

**Change 1 — widen the demand set to the same-shape rebuilds.** Make `map`, `indexedMap`,
`filter`, `filterMap`, `reverse`, `sort`, `sortBy`, `sortWith`, `take` and `slice` consuming
writers: `map` is `a[i] = f(a[i])`, `filter` compacts in place, `sort` is `a.sort(cmp)` (stable in
every current engine), `take n` is `a.length = n`.
*Reason:* the owner's programs edit lists this way, not with `set`/`push` (§8): without it the
rule changes nothing in TodoMVC or Conduit, and nested-list edits through `map` are rejected
(§5.4).
*Buys:* in-place `Toggle`, `Destroy`, `ClearCompleted`; unique elements inside `map`'s and
`update`'s callbacks where the contents are exclusive (§2.9), and the trie's last reason to
exist gone.
*Costs:* `List.map xs f` where `xs` is read later is now an error; today's identity promise
"`map` returns `xs` itself when every result is `===`" must go for `map` (it would be true by
construction — the array is `xs` — but the renderer's A4 obligation widens: a `For`'s `each`
over a mapped list keeps its identity after an edit, so the identity walk must compare items,
which `browser-direct` §6.2 already does).
*The wall:* the same `List.filter model.todos …` appears in `view`, where `browser-direct`
compiles it into a derived value recomputed while the page holds `model`, and in `verifyAll`'s
re-evaluation (§5.9); there it cannot be a demand. So change 1 is either **two functions**
(`List.map` fresh, `List.edit`/`List.keep` in place — FP²'s duplication, §1.4.1) or **one
spelling decided by position** (a demand in an `update` arm, a fresh build in a `view` or a
derived value), which is a static rule the owner can read but is not "one `map`". Neither is a
silent fallback; the second is the smaller surface.
*Rule 7:* it rejects more correct programs (every read-after-`map` in `update`) to buy a cost
guarantee on the most common list operations. Recommended **only together with the report
mode's numbers** for `rebuilds`, since it is where most false errors would come from, and only
in the by-position form.

**Change 2 — turn the identity promises into summaries, or drop the ones that alias.**
`backend.md` §4 promises `filter`, `map`, `slice`, `take`, `xs ++ []` return their input itself in
some cases. Under the rule a result that *may* be the input is `res ∋ π₁`, so the input must be
unique at any later write of the result.
*Reason:* otherwise `xs ▷ List.filter p ▷ List.push y` demands `xs` unique though `filter` usually
returns a fresh array.
*Buys:* fresh results everywhere, so pipelines never demand their source. The renderer's skip
on `===` for a `filter` that kept everything is lost (one O(n) compare instead of one pointer
test).
*Costs:* a measurable per-element compare in the renderer for lists whose `filter` keeps all; a
golden change in `run/ListIdentity`.
*Rule 7:* no restriction either way; a representation choice. Recommended: drop the promises for
`filter`, `map`, `slice`, `take`, **`[] ++ ys`** (today `append` returns `ys` itself when `xs`
is empty, so a consumed `append` would hand out `ys`'s cell as its result) and **`concat`'s
"the one non-empty list itself"** — they become always-fresh, or in-place under change 1 — and
keep them for out-of-range `set`/`swap`/`removeAt` (no-ops on the unique array). `backend.md`
§4 and §8 already disagree on `filter` ("returns `xs` itself when every element is kept" against
"a new list and still is, `run/ListIdentity`"); the specification must settle it before `res`
can be declared.

**Change 3 — `List.copy : List a → List a`.** New, shallow, `fresh`.
*Reason:* the explicit escape hatch; the machine-applicable fix.
*Costs:* none; a `copy_of_unique` **warning** (never an error) for a copy the checker can see is
not needed.
*Rule 7:* an escape hatch, which rule 7 asks for.

**Change 4 — `++` on lists consumes its left operand.** `xs ++ ys` lowers to `List.append` (O6),
which under the rule is `push` each of `ys` onto `xs`: `xs` consumed, `ys` borrowed.
*Reason:* consistency with `[ …xs, …ys ]`.
*Costs:* `xs ++ ys` with `xs` read later is an error; `Basics.append` over `appendable` stays a
copy. TodoMVC's `model.todos ++ [ new ]` becomes a push.
*Rule 7:* same shape as change 1, smaller. Recommended with change 1.

**Change 5 — ownership words on `foreign` declarations, and optionally on `pub` annotations.**
A `foreign` parameter may say `consumed`, `borrowed` (the default) or `shared`; a result `fresh`
(the default) or `= πᵢ`. A `pub` beni declaration *may* say the same in its annotation, and when
it does the inferred summary must be at most what is written (an annotation can only claim
*less* ownership than the body takes — `borrowed` where the body consumes is an error at the
declaration; `consumed` where the body borrows is accepted and freezes the interface at
`consumed`).
*Reason:* `foreign` has no body; platform contracts need the word (A2, A6); and `core/List`'s
writers are beni over `Js`, whose bodies cannot show what they promise (§2.6), so **core and the
platforms may assert a summary the body does not prove** — trusted, like the rung — while every
other package may only *narrow* an inferred one. For `pub` code it is Klabnik's and OxCaml's
answer to interface churn: an annotation makes the summary a declared contract, so a body edit
cannot change it (research 19 §4: annotated declarations measured zero interface changes). The
vocabulary must also reach a function type inside a platform record — `Tea.sandbox`'s
`{ update : sync (msg, model → model), … }` field is where P1's "`model` supplied owned" is
written, as `sync` already is.
*Buys:* stable interfaces for library authors who want them; the pessimistic default for
platform `foreign`s without words.
*Costs:* a vocabulary users may write but never must — the owner asked for no annotations in
user code, and this keeps that: inference is complete without them.
*Rule 7:* an opt-in, not a restriction. Recommended for `foreign` (required for soundness
anyway); optional for `pub`.

**Change 6 — closures that consume a capture are `once`, and a `many` position refuses them.**
Already a consequence of the rules (§5.1); listed because it is a language-visible restriction:
`List.map xs (λx → List.push acc x)` is an error whose fix is a fold.
*Buys:* soundness (two calls would write one array).
*Costs:* a shape some people write; the message gives the fold.
*Rule 7:* buys a correctness guarantee (no observable write), so it stays an error.

**Change 7 — a persistent vector as a library.** `core/Vector` (or `Persistent`), the E1tp trie
written in beni with no in-place writes, for programs that keep versions.
*Reason:* the trie's users (undo, time travel, shared tails) lose their O(log n) versions when
`List` stops being persistent.
*Costs:* a second sequence type in the library, which the owner removed from the *language*
("one sequence type", W35); as a library module it is `Dict`'s status, not `List`'s.
*Rule 7:* a capability filled inside the wall rather than a "work around it".

**Change 8 — a deque headroom for prepend, or none.** `[ x, …xs ]` on a unique plain array is
`unshift`, O(n). A unique view with headroom (`o > 0`) could take an O(1) prepend by writing
`b[o − 1]`; `cons` on a plain array could allocate headroom on its first conversion.
*Reason:* Elm-style prepend accumulators (research 46 §11's rows).
*Buys:* linear prepend loops without the building-loop rule.
*Costs:* a fourth list form or a growth policy in `core/List.js`; measured, not assumed.
*Rule 7:* a cost, not a guarantee; decide on §9.3's `prepends-loose` count.

**Change 9 — `Send msg` consumes its message.** A fiber that sends a value and reads it after is
an error at the sender (P6).
*Buys:* unique payloads at the arm.
*Costs:* `send (Got rows); use rows` becomes `send (Got (List.copy rows)); use rows`.
*Rule 7:* the alternative is every payload shared at every arm; this is the cheaper default.

**Change 10 — evaluation-order dependence, stated once more.** The rule depends on
`language.md` §6's order being the order the emitted code runs in; it already is, and A5 says
the optimiser keeps it. No change, but the dependence should be written into §6 ("in-place
writes are calls").

---

## 11. Recommendations and open questions

### 11.1 Recommendation

1. **Build the report mode** (§9) as a `check`-only pass with its dump and corpus fixtures, on
   the design of §2–§3, with the entry assumption P1–P6 for TEA programs read from the write-set
   pass. Nothing emitted changes. Budget: the effect pass's shape, a slice.
2. **Run it both ways** (`writers`, `rebuilds`) over `core/`, the corpus, TodoMVC, Conduit and the
   table app; classify by hand; report the table of §9.3 and the churn and timing rows.
3. **Decide the demand set first** (change 1). As asked, the rule touches nothing the owner's
   applications do; widened, it touches their every list edit. The number that decides is the
   rejection rate on `rebuilds`.
4. **Then decide error versus warning** on the exact/approximate split. The soundness argument
   holds for both; the choice is rule 7's.
5. **Write P1–P6 into `browser-direct.md`** before S7, whatever the decision: they are the
   obligations S7's in-place records need too.
6. If the error is adopted: specify the pass in `checker-v2.md` (an amendment, like §26), the
   `foreign` words in `boundary.md` §4, the demand summaries and `copy` in `language.md` §6.8,
   the representation change in `backend.md` §4, and the message catalogue in `language.md` §10
   — then build it red-first, with the stability rule versioned in the interface format.

### 11.2 What this document is confident of

- The property (§2.3) is the right one: liveness-based, so reads before writes are free, and
  dead aliases are harmless. Every production system that accepted real array code has some
  form of it (Sisal's ordering edges, Clean's observing references, Futhark's syntactic order,
  Rust's two-phase borrows), and beni's strict order gives it with no construct.
- The inference (§3) is directional, has a best solution, and is linear per round. The
  optimistic fixpoint with post-validation is the published recipe (AHK, Lean, Brandon).
- The soundness argument (§4) has the right shape and the right assumptions; its lemmas are
  standard. The reviewer should attack A3/A4 (the platform) and §4.4's list.
- Higher-order code is handled without annotation because lambdas are in front of the checker
  and function types already carry inferred classes (§3.6). This is the place every prior system
  gave up or declared; it is also where a reviewer should look hardest, at the `supply`/`need`
  edges.

### 11.3 Open questions

1. **The rejection rate on real code**, exact and approximate, for both demand sets. Nothing
   in the literature stands in for it (research 69 §5.1). §9 answers it.
2. **The demand set** (change 1): the owner's call.
3. **`Ref` and `Queue`** (§5.12): a sound discipline for in-place edits of a cell's contents
   needs a whole-program argument about readers; left as a limit with a `copy` fix.
4. **Path-sensitive cell sets** (§5.6): worth their cost only if §9's `join` tag is frequent.
5. **Interface churn** under inferred summaries: measured by §9.3; change 5's optional
   annotation is the remedy if it is high.
6. **The warm budget**: a body edit that changes a summary is a signature edit; `plans/queue.md`
   row 55's signature-edit miss applies.
7. **Prepend without the trie** (change 8): decided by `prepends-loose`.
8. **The crash screen** (A9): confirm it prints no program value, or make it so.
9. **Record paths** (§7.7): the same rules, a stronger A4; S7's business.
10. **Konečný's best-typing proof** (AHK 2008 §6.2 cites Konečný 2003, not in the library) and
    the Cogent JFP 2021 paper (the formal "two semantics coincide" theorem O'Connor 2026 only
    states): both should be added to `references/ownership/` before the specification is
    written, so that §3.5's and §4.1's shapes can be checked against the originals.
11. **Exclusive contents in practice** (§2.9): how often the lists and dictionaries real
    programs edit through their elements are built exclusively, and which construction clears the
    flag most. If decoded data (every `List` a schema parses) is not declared element-fresh,
    nested edits of loaded data are all limits; the row for a decoder's output decides it.
12. **The two-slots-one-record hazard** is the one place this design relies on a flag the
    program's construction must establish rather than on liveness alone; a reviewer should try to
    break Lemma 1b with containers built through `where`-constrained generic code and through
    `foreign` siblings.
13. **Path-insensitive `use`** (§4.6's review): `f xs flag = if flag then List.length xs else
    List.length (List.push xs 1)` is `consumed`, so `n = f xs True; List.length xs` is a false
    error. A conditional summary over a *value* (not a class) is beyond §2.6's grammar; §9 counts
    how often it bites.
14. **The entry fixpoint's cost** (P5): one whole-program pass over `init` and the arms per
    build, the only non-modular computation here; its time goes beside the write-set pass's under
    `--self-profile`.
15. **A once-closure the program calls once in fact** passed to a `many` position stays an error;
    whether a `List.map` over a literal of one element deserves a special case is a question for
    the report mode's `calls many` tag count.

---

## Appendix A. The prior art, and exactly what is taken from each

The reading order of `references/ownership/README.md` was followed; each entry says what the
design takes, what it declines, and why.

**Clean** (Barendsen & Smetsers 1993/1995/1996; Smetsers et al. 1994; de Vries et al. 2006/2007;
Clean 2.2 report ch. 9). *Taken:* the demand lives in library types ("newArray :: Int ──×──>
Array^u rather than Int ──×──> Array•", de Vries 2007 §6, p. 10), so user code carries nothing;
the propagation rule for containers — "if a unique object is stored in a data structure, the
data structure itself becomes unique as well" (report §9.2, p. 93) — appears here as the holder
relation through paths; evaluation-order-aware marking, Smetsers' preliminaries and alternates
(1994 §4 Def. 4.2–4.8, p. 9) and the report's "observing" references (§9.4, p. 96), is what §2.3's
liveness generalises. *Declined:* attributes on types solved by unification with a subtyping
restriction on arrows (1996 Def. 7.6, p. 19), which is why Clean has no principal uniqueness type
("there is no 'Principal Uniqueness Type Theorem'", p. 32) and must force recursive groups
non-unique (de Vries 2007 §7, p. 12); the rank-2 escape for `if isEmpty arr then shrink arr else
grow arr` (de Vries 2007 §6, p. 11–12), which an annotation-free checker cannot use and liveness
makes unnecessary. The `foldr` and `mark` false errors (Barendsen & Smetsers 1995 §6, pp. 12–14)
are accepted here: `foldr`'s callback is `borrowed`-captured, and `mark`'s `lookup` precedes its
`update`.

**Aspinall, Hofmann, Konečný 2002/2008.** *Taken:* the three aspects (§1, p. 4) as `use`; the
LET rule's per-variable condition that a common variable may be read with aspect 2 or 3 in the
binding and destroyed in the body ("the modification may happen before the reference", 2008
Fig. 8, p. 16) — the reads-before-writes rule in its earliest typed form; the best-typing claim
and its optimistic search (§6.2, p. 36); the separation theorem's clause C2 ("heap occupied by
arguments with aspect 2 or 3 is not modified", Thm 5.4, p. 23) as Lemma 3's clause 1–2; the
two-semantics soundness theorem (Thm 5.8, p. 30) as §4.1's shape. *Declined:* first-order,
monomorphic, affine with explicit `◇` resources; higher-order deferred to "the standard types and
effects technique" (p. 35–36), which §3.6 is.

**Wadler 1990/1991; Boyland 2001; Marshall, Vollmer & Orchard 2022.** *Taken:* `let!`'s
hyperstrict ordering as the reason strictness matters (1990 §4, p. 14); "only update operations
are sequentialised but lookups can occur in parallel" (1991 §3, p. 8) as the design goal; alias
burying's "all aliases must be dead" (2001 §3.2, p. 13) as the definition of unique-at-a-site;
uniqueness as a statement about the past (2022 §2.2, p. 353), which is why a borrowed value
*can* be returned to uniqueness after the borrow ends and why `List.copy` is the only way back
once shared. *Declined:* Boyland's annotations on fields and interfaces (inferred here);
Marshall's call-by-name calculus.

**Wand & Clinger 2001; Sisal 1990.** *Taken:* liveness-defined destructive update ("x can't be
bound to a live location after E1 and E2 have been evaluated", Def. 8, p. 326) and inclusion
constraints with a least solution ("data flow inequalities, which can be solved in polynomial
time", §1.1, p. 320); Sisal's Table I as the model for §9.4's hand classification (25 real
sharing, 4 undecidable, of 293). *Declined:* Wand & Clinger's first-order, scalar-array
restriction (§12, p. 344).

**Lean (Ullrich & de Moura 2019), Perceus, frame-limited reuse, FP², Brandon et al. 2026.**
*Taken:* the direction of inference ("starting with the approximation β(c) = Bⁿ … repeat … until
we reach a fix point", 2019 §5.2, p. 6; Brandon's Knaster–Tarski least fixpoint, §4.4, p. 16);
the one correctness rule every paper shares — a parameter that reaches a write must be owned
(2019 p. 6; Brandon §3.2, p. 7); Brandon's tail-call refinement ("treat variable occurrences in
the argument position of a tail-call as escaping", §6.3, p. 19) which beni's loop rebinding
handles directly; FP²'s diagnosis of static uniqueness typing — "code duplication, where a single
function can have multiple different implementations" (2023 §1.4.1) — answered here by summaries
that are facts about flows, not types, so one `reverse` serves both callers and the *caller* is
what is checked. *Declined:* run-time reference counts and the silent copy at a shared call
("The fip annotation in Koka only guarantees that no (de)allocation occurs if the parameters
are unique at runtime", Lorenzen, Leijen, Swierstra & Lindley, PLDI 2024 §3.1, p. 168:7);
borrowing as an RC-token discipline
that lets a borrowed value be returned with an `inc` (2019 Fig. 5); Lorenzen & Leijen's space
objection to inferred borrowing (2022 §4.2) does not apply, because there is no count to keep a
borrowed value alive past its last read. Brandon's "a handful of reference count operations"
fallback is this design's error.

**OxCaml (Lorenzen et al. 2024; Peters et al. 2026).** *Taken:* the lock rule for closures —
`once† := unique, many† := aliased`, a closure's captures are `u₁ ∨ a₂†` (2024 §3.3, p. 10) — as
§5.1's `once` rule; polarised inequality constraints solved by "essentially just transitive
closure" (App. B, p. 48) as the shape of §3.6's edges; mode crossing (2026 §2.3, p. 6; §4.2,
p. 18) as §2.1's `crosses(τ)`; the measured annotation counts (27 382 locality annotations in
interfaces; "the implementations can generally infer", 2024 §7, p. 24) as the warning about
interface churn; the currying remark (§6.4, p. 22) as evidence that beni's no-currying decision
removes the hard case. *Declined:* modes as types with no polymorphism ("85 functions duplicated",
§6.6, p. 23) — summaries here are per flow, not per mode; the per-module inference with written
interface modes (docs, *pitfalls*) — summaries here are inferred *and* published.

**Reachability types (Bao 2021; Wei 2024; Jia 2026; O'Connor 2026; Capybara; Deng 2025).**
*Taken:* a function type that names which argument its result reaches (`f(x : T^◆) → T^{x}`,
Wei 2024 §2.2.3) as `res`; the warning that polymorphism over tracked/untracked values is
unsound without a fresh marker (`fakeid`, ms.tex:1179–1216) — here `fresh` is a distinct cell
kind, never a type variable; "a consume kills its aliases" (Capybara ms.tex:2516) as the
dead-alias lemma's content; "a component of a shared structure cannot be consumed directly"
(Capybara §7) as §5.4's rule for containers; Deng's use/kill effects on closures (Fig. 6, p. 11)
as the `cap` facts, inferred rather than declared; O'Connor's statement of the guarantee. *Declined:*
qualifier annotations on arguments and explicit instantiation (Jia 2026 §4: inference is given
"annotations on function arguments and explicit instantiations"); the opaque joint qualifier for
lists (`μh.List[Ref^h]`), replaced by per-path cells.

**Rust: NLL, Polonius, two-phase borrows, Oxide, Pearce, Ho, Emre.** *Taken:* liveness as the
precision lever ("if a variable is live on entry to a point P, then all regions in its type must
include P", 2017 post) and the minimal-lifetime principle (RFC 2094); two-phase borrows as the
formal reads-before-writes ("acts exactly like a shared borrow" until activation, RFC 2025);
the three-point error with the blame on the action (RFC 2094, *Leveraging intuition*); Polonius
as "a bunch of transitive closures" over directional facts (Stjerna §3.3, p. 15); Pearce's and
Ho's joins at merges as the model for §5.6; Emre's measurement as the argument against
unification (§4, Table 2). *Declined:* lifetimes in signatures; references into structures (beni
has none, which is why problem case #3 does not arise).

**Futhark.** *Taken:* the consumption judgement `(O₂ ∪ C₂) ∩ C₁ = ∅` (PLDI 2017 Fig. 6, p. 7)
as the one-line statement of the rule; `if` as a union of alias sets (ALIAS-IF) for cells, with
per-path liveness added; the refusal of a free-variable consume inside a lambda (§3.3, p. 6) as
the `once` rule; the separate pass after type checking (2026 rewrite post); the error index's
shape — message, minimal program, reason, `copy` fix, and when the copy "subverts the purpose"
(§8.1.2); the 2021 lesson on naming intermediate results; the free-theorem idea for `id` and
`|>`. *Declined:* `*` on parameters and results, intra-procedural analysis with no summaries
("we are forced to be conservative", §3.2, p. 6), the 2026 verdict "don't do it" — which was
about a type system reasoning about aliasing, and §7.1's point is that this is not a type
system.

**Usage analysis (Turner 1995; Wansbrough & Peyton Jones 1999/2002); Affe (Radanne 2020);
escape analysis (Blanchet 1998/1999).** *Taken:* the poisoning problem as the reason summaries
must be polymorphic over function arguments ("one call to f 'poisons' all the others", 1999 §6.3);
polarity simplification of constraint sets (thesis §4.1.3, p. 95) as the way to keep summary
blocks small; the measured warning that generalising local binders loses precision; Affe's
`Abs` rule where a captured shared borrow leaves the closure unrestricted (§3.3) as the shape of
`cap = borrowed`; Blanchet's closure case split — applied versus escaped — as `escapes`.
*Declined:* usage on every type (demand-counting, which counts a read-only capture as a use);
Affe's lexical regions and explicit `&x`.

**Error design (Czaplicki 2015; Wrenn & Krishnamurthi 2017; Marceau 2011; rustc guide; Crichton
2020/2023/2024; Hylo; Swift).** Taken in full in §6; the one dissent recorded is Marceau's
"error messages should not propose solutions" for novices, against which Hylo, Futhark, Rust and
Swift all ship fixes; this document ships the fix and the verdict line.

**Research 42 and 68/69.** Research 42's R0 is this checker's backend half: "in place where last
use and per-function interface summaries prove a value unique" (§1), with S2's "consumed-unique
parameters … summaries go into the interface and flow forward" and S4's result summaries; its
findings that the TEA model needs a hands-over runtime (§6.1) and that a copy at an unprovable
call is "catastrophic in a loop" (§6.4) are why the rule is an error at the site and not a copy.
Research 69 §1.3's nine items are each answered: 1 (§2.6), 2 (§2.3), 3 (§2.4), 4 (§3.5),
5 (§3.9), 6 (§6.5), 7 (§2.1), 8 (§7.1), 9 (§5.1).

---

## Appendix B. Four programs through the rules

**B.1 TodoMVC `Toggle`, under change 1.**

```
Toggle id → changed model (List.map model.todos λt → if t.id == id then { t | completed = not t.completed } else t)
changed model todos = { model | todos = todos }
```

Entry: `model` consumed (P1), `model.todos` not escaped by any arm (P5: no command captures it;
`encode` in the routing build reads it before the command is made). `map` under change 1 is a
writer: demand on `(model, .todos)`'s cell; holders: `(model, .todos)` only; the lambda's captures:
`id`, a scalar (crosses); `calls many`, `once no` (it consumes nothing); after the `map`, `model`
is passed to `changed`, whose summary reads no path meeting `.todos` (its record update replaces
that field) — so the holder `(model, .todos)` is dead at the demand. Accepted: `a[i] = f(a[i])`.
Under the rule as asked, `map` is not a demand and nothing happens.

**B.2 The table app's `SwapRows`.**

```
SwapRows → { model | rows = List.swap model.rows 1 998 }
```

`swap` is a writer. Holders of `(model, .rows)`: itself; the instance array holds items (P3,
identity only); no arm captures `rows` (P5). Accepted: two assignments on the plain array; the
edit script's tag guard compares items (§6.2 there), never list identity (A4). This is the row
where S2's kill criterion fired on the trie (research 67: "the model's `List.swap` on a trie,
not the script"); in place it is two array writes.

**B.3 A histogram by `foldl` (research 42 §6.4).**

```
hist = List.foldl samples (List.repeat 0 1000) (λs acc → List.update acc (bucket s) (λn → n + 1))
```

`repeat` is `fresh`. `foldl`'s class for its callback: `supply (borrowed, owned), need owned,
calls many, escapes no`. The lambda: `List.update acc …` is a demand on its parameter `acc`
(`use = consumed`), its result `res = {π₂}`; `once = no` (it consumes a *parameter*, not a
capture). The edge `need(consumed) ⟹ supply(owned)` holds. Accepted; the accumulator is written
in place on every step, which research 42 measured at 0.14–0.47× the trie.

**B.4 Lean's `groupBy` in beni.**

```
groupBy xs key =
    List.foldl xs Dict.empty λx d →
        group = Maybe.withDefault (Dict.get d (key x)) []
        Dict.insert d (key x) (List.push group x)
```

`Dict.get d k`'s summary: `res = {π₁ contents}` — `group` holds a cell that `d` also holds
(through the tree). The demand `List.push group x`: holders of the cell: `group` (the operand)
and `(d, contents)`; `d` is live after (passed to `Dict.insert`). **Rejected, real sharing**, with
the message: "`d` still holds the list, and is read by `Dict.insert` on the next line … To add to
the group in place, update it where it is: `Dict.update d (key x) (λg → Just (List.push
(Maybe.withDefault g []) x))`" (`Dict.update : Dict k v, k, (Maybe v → Maybe v) → Dict k v`,
`core/Dict.beni`). With `Dict.update` — whose callback's `supply = owned` is an asserted row of
core's, since its body `insert d k (alter (get d k))` holds the old value at a key the path
domain cannot name (§2.9) — accepted, **provided `d`'s values are exclusive**: here they are,
from `Dict.empty` on, because every value stored is either `[ x ]` pushed onto a fresh `[]` or
the pushed result of a destructive read, and no `Dict.get` ever leaves a live alias. This is the
program whose silent quadratic cost motivated Huisinga's thesis (2023 §2.1); here it is a
message with the fix on it, and the fixed form is checked rather than counted at run time.
