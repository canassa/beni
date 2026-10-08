# Write sets — what `update` may change, as a static analysis

*2026-10-08. The contract for the whole-program write summary that `plans/compile-away.md` R3
(values that never change) and R4 (per-message handlers) consume, and for the read-only pass and
the gate that come before either. The owner's decision of 2026-10-08: R4 is built **with nested-
message dispatch and same-variant analysis**, as a **sound static analysis and not a set of
syntactic patterns**, and it is **gated** — the analysis ships first as a read-only pass and must
show, by its own dump, that at least two thirds of Conduit's dispatchable message keys have a
bounded write set (research 62). Sources: research 58 §4 (W1–W4), §5 and §9; research 61 §2 (the
prototype classifier's informal rules, which this document replaces with a formal account) and
§5; research 62 (Conduit); `backend.md` §15.4 (how read sets work); `language.md` §11.11–§11.12.
Section numbers here are never renumbered (CLAUDE.md rule 2); every later change is an amendment
in place.*

**Rules this document keeps.** Analysis says "possibly changed"; a comparison says "changed"
(`compile-away.md` §2). An unknown write set is a cost, never an error (rule 7): nothing here
restricts what `update` may call or how it is written, and the analysis never produces a
diagnostic. A failing gate is a finding, not a reason to bend the design (rule 10).

---

## 0. The answer in eight sentences

1. For every message a program's `update` can receive, the analysis computes a **write set**: a
   finite set of **paths** into the model, each marked `node` (the object at that path is rebuilt,
   its untouched children keep their identity) or `value` (the value there, and everything below
   it, may be another JavaScript value). It over-approximates the paths at which `update msg m`
   is not the same JavaScript value as `m` (§1).
2. A path is a chain of steps — a record field, a tuple index, a constructor's tag and argument
   position, a list position — from the model's root, cut at **k = 8** steps (§2).
3. The analysis is an abstract interpretation of `update`'s body with the old model as a symbolic
   value. It tracks, for every expression, **what it is in terms of the old model**: the very
   value at a path, a record built from one with some fields replaced, a constructor applied to
   parts, a list made from an old list by a named edit, or a fresh value (§3). The write set is
   read off the result by comparing it with the symbolic model, path by path (§3.4).
4. A `case` refines what is known about the **tag** at the scrutinee's path in each arm, so a
   constructor applied to the parts the arm matched is a `node` write and not a `value` write:
   `Home (Home.update sub home)` under `( GotHomeMsg sub, Home home )` writes below `Home#0`, not
   the root (§3.3, *constructor*).
5. Functions are **summarised** once, as symbolic results over their parameters, and a call
   substitutes the arguments into the summary — a function-valued argument included, which is how
   `updateWith Home GotHomeMsg (Home.update sub home)` is seen through (§4). Recursion is a
   fixpoint with a bounded number of rounds (§4.3).
6. Messages are split along the constructor patterns `update` and the updates it calls actually
   match on, so the unit of dispatch is a **message key** — a path of constructor tags through the
   message, `GotEditorMsg · EnteredTitle` — and the write set is per key (§4.4).
7. Every bound is a cap that yields `value` at the root or a fresh value, never an error, and
   every join is over finite sets, so the analysis terminates; its work is bounded by a budget
   per key and per summary, and on the programs measured it is a few walks of `update` and
   `view` (§6). It is deterministic by construction (§7).
8. Before any code generation reads it, `beni dump --stage=writes` prints the whole result — per
   message key its write set and class, per view hole whether it is static, literal at `init`, or
   dynamic — and the gate is that dump run on Conduit (§8). R3 and R4 consume it as §9 says.

## 1. Purpose and contract

### 1.1 What is computed

A **program** here is a record literal with `init`, `update` and `view` fields handed to a
platform function whose result type is the platform's `Program` (`Tea.sandbox`, `Tea.element`,
`Tea.application`, `Browser.program`), where the record is written inline or is a top-level
value whose body is that literal, and where each of the three fields is a top-level function, a
lambda, or a top-level value (for `init`). Its **model type** is the type of `update`'s second
parameter, and its **message type** the type of the first. **Any other shape is
unrecognised** — a field computed by a call (`update = withLogging update`), a record a helper
builds, a program whose `main` the pass cannot trace to such a record — and an unrecognised
program has one key, `*`, with the write set `value ρ`, and every hole **dynamic** (*amended
2026-10-08, B3*). "No program found" is never "no writes": a consumer may use the result only
of a recognised program, and the dump prints `program <unrecognised>` for the rest (§8.1). For
each recognised program the analysis computes:

- **`writes(κ)`** for every **message key** κ (§4.4): the write set of `update m model` for every
  message `m` the key describes, over every model `model` of the model type. For a program whose
  `update` returns `model × Cmd msg`, the model is the pair's first component; the command is
  not analysed (§3.3, *effects*).
- **`writes(init)`**: nothing — `init` has no old model — but **`literal(p)`** for every path
  `p`: whether `init` gives the model at `p` a value the compiler can write as a literal (§3.5).
- **`anchor(local)`** for every local of `view` and of the functions `view` calls with markup:
  what that local is in terms of the model, so that a hole's read paths, which slice B computes
  relative to locals (`boundary.md` §9.4.6, version 1.5), can be expressed as model paths
  (§3.6).

### 1.2 What a consumer may rely on

**R3, "never written".** A model path `p` that no key's write set *conflicts with* (§2.5) holds
the same JavaScript value after every `update` as after `init`. A hole whose anchored read paths
are all such paths shows the same value for the page's life.

**R4, "may write P".** A handler for key κ that marks exactly the groups whose anchored read paths
conflict with `writes(κ)` misses no group that the general renderer would have found changed.
What the handler must still do at run time is §9: the comparison per group stays, because
"possibly changed" is all the analysis says.

### 1.3 The soundness statement

In plain words: *the write set names every place where the new model may not be the old one;
it may name places that did not change, and it never fails to name one that did.*

Precisely. Let `M` be the model before and `M'` the model `update` returned for a message that key
κ describes. Write `M@p` for the JavaScript value reached from `M` by following path `p` — a field
read per field step, an element read per tuple or constructor step, an element read per list
step — and say `M@p` is **undefined** when a step cannot be followed (the tag at a constructor
step is another constructor; a list index is out of range). Say `p` is **changed** in `(M, M')`
when `M'@p` and `M@p` are not the **same value**: not `===`, with the one exception `backend.md`
§4 (*Identity*) grants list views and trie headers, where `same(a, b)` is the test; a path that
is defined in one and undefined in the other is changed, and so is every path below a changed
path whose step cannot be followed. Then for every changed `p`:

> either some `value` write `w ∈ writes(κ)` is a prefix of `p` (`w ⊑ p`), or `p` itself is a
> `node` write in `writes(κ)`, or `p` is longer than k and its k-step prefix is a `value` write.

That is the whole claim, and §5 argues it rule by rule. Its shape is the shape of every claim a
consumer makes: a read of `r` conflicts with the write set exactly when some changed path could
be at or under `r`, or `r` itself could be rebuilt (§2.5).

**Why identity.** The renderer never compares by structure: a group runs when a path it reads is
not `===` to what it last saw (`backend.md` §15.4, *A root computes its own values*), and that
works only because an untouched value is the same object (`language.md` §11.12, *field identity
is load-bearing*). The analysis therefore speaks of identity too. A write set that said "the
value is equal" would be useless, and one that said "the value is different" would be false
(`tick + 1` may be `tick`); "may be another object" is exactly what a comparison can settle.

## 2. The abstract domain

### 2.1 Paths

A **path** is a finite sequence of **steps** from a **root**. The roots are:

- **ρ** — the program's model, as `update` received it (the "old model");
- **πᵢ** — the i-th parameter of the function being summarised (§4.1);
- **εⱼ** — the element a list operation's callback is applied to, in the j-th such position
  (§3.3, *core*); and **ιⱼ** the index of that element, which is not a path root but an index
  symbol (§2.3).

The steps:

| step | written | follows | exists when |
|---|---|---|---|
| field | `.f` | a record's field `f` | the type at the path is a record with field `f` |
| tuple | `.i` | the i-th component | a tuple of at least i+1 components |
| constructor | `C#i` | the i-th argument of constructor `C` | a custom type with constructor `C` of at least i+1 arguments; the step is **defined** only on a value whose tag is `C` |
| list, exact | `[κ]` | the element at index κ (§2.3) | a `List`; defined when κ is in range |
| list, any | `[*]` | some element, position unknown | a `List` |

A step is always one the **type** at the path allows: paths are typed, which the checker's
solved types make possible (`checker-v2.md` §13), and a path that no type allows is not a path.
A type alias is its expansion; an **opaque** type is its custom type, so `Feed.Model`'s paths go
through `Model#0` like any single-constructor type's (§2.6).

**Spelling.** `ρ.Home#0.feed.Loaded#0.Model#0.articles[*].author` is the author of some article
in the home page's loaded feed. The dump prints paths this way (§8.1).

**Two orders** (*amended 2026-10-08, A3–A5*). **Exact prefix**, `p ⊑ q`: `p` is a prefix of
`q` step by step, where two steps are equal only when they are the same field, the same tuple
index, the same constructor and position, or two list steps whose index symbols are **equal**
(§2.3); a `[*]` step equals no step, itself included. The exact order is what `diff` (§3.4) and
the invariant of §2.4 use. **May-prefix**, `p ⊑̃ q`: `|p| ≤ |q|` and each step of `p` **may
coincide** with the step of `q` at the same position — equal steps may coincide, `[*]` may
coincide with every list step, and two list steps `[κ₁]`, `[κ₂]` may coincide **unless both are
literals and differ**. The may-prefix order is what **conflict** (§2.5) uses, because two
positions the program spells differently (`[id]`, `[0]`, `[i + 1]`) can be the same slot at run
time, and the one disjointness this domain can state is literal against literal.

### 2.2 The k-limit

Paths are cut at **k = 8** steps, counted from the root. A path of more than k steps is **not
represented**: a write below the cut becomes a `value` write at the k-step prefix, and a read
below the cut is a read of its k-step prefix. Both directions are sound — a `value` write at a
prefix covers every path under it, and a read of a prefix conflicts with everything a deeper
read would — and both lose only precision below the cut (Jones & Muchnick 1979, §11).

**The cut never truncates a `Same`** (*amended 2026-10-08, B4*). Equality of paths (`q = p` in
§3.4, the exact prefix order) is decided on **uncut** paths; an abstract value `Same(q)` with
`|q| > k` is not `Same` of the k-prefix but **`Fresh({ q's k-prefix })`**, and a `Rec`, `Con`,
`Tup` or `Lst` that would sit deeper than k is `Fresh` likewise (§3.1). So two different paths at
depth nine never become one path at depth eight, `diff` never answers `∅` for a deep value, and
§1.3's third clause holds literally: the only thing at or below depth k that a deep write
produces is a `value` write at its k-prefix.

Why 8 and not slice B's 4. Slice B's read paths are at most four links *from a local*
(`boundary.md` §9.4.6), and a local of a nested page's view is itself several steps from ρ:
`article.author.image` inside `ArticlePage.view` anchors to
`ρ.Article#0.article.Loaded#0.author.image`, six steps, and the home feed's preview author is
eight (§2.1's example plus `.image`). Conduit's deepest anchored read is nine
(`…articles[*].author.image` under `Profile#1`), and the loss there is a read of `.author` where
`.image` was meant: one group compares one object more. A smaller k would cut Conduit's pages at
their status variants, which is exactly where same-variant analysis earns its keep. A larger k
costs nothing in principle — every path is syntactic — but k bounds the height of the lattice
(§2.4) and the depth of summary substitution (§4.2), and 8 covers what was measured. *Open
choice O1 (§12): k = 8, the owner to confirm.*

### 2.3 List positions and edit tags

An **index symbol** κ in `[κ]` is one of:

- a **handler-evaluable expression**: an expression of the `update` branch built from the
  message's payload, literals, top-level values and reads of the old model (`ρ.…`), and nothing
  bound by a lambda — one the R4 handler can evaluate before it patches, because it has the
  message and the old model. In the dump it is printed as its source text (`[id]`, `[i + 1]`);
- an **index parameter** ιⱼ of a callback (`List.indexedMap`, `List.update`'s position), which
  a guard may fix to an expression (§3.3, *guards*);
- **`?`**, unknown: the step then means `[*]`.

**When two index symbols are equal** (*amended 2026-10-08, A4–A5*): two literals with the same
value; two expressions that are the **same BIR instruction under the same substitution** (one
occurrence, not two spellings of one text — a pure expression evaluated once has one value; an
expression inside a summary is a term over the callee's roots, and two calls of that callee
instantiate it to two different terms unless their arguments are the same, §4.2, N5); two
index parameters that are the same ιⱼ under the same facts. Nothing else is equal, and `[*]` and `[?]` are equal to nothing,
themselves included: a `Same(q)` whose path holds `[*]` or `[?]` names *some* element's
identity and is never the identity of a placement path (§3.4). Equality is what `diff` asks;
conflict asks the weaker *may coincide* of §2.1.

A write at a list path carries an **edit tag** saying how the list's **shape** — its length and
the order of its elements — relates to the old list's, as `backend.md` §4 (*Identity*) and
`core/List` document it. The tags, and what each promises about the result `L'` of the old list
`L`:

| tag | promise |
|---|---|
| `kept` | `L'` has `L`'s length, and `L'[i]` is `L[i]` except at the positions the write names (`[κ]` or `[*]`) |
| `append` | `L'` is `L` followed by new elements |
| `prepend` | `L'` is new elements followed by `L` |
| `clear` | `L'` is empty |
| `removeSome` | `L'` is a subsequence of `L`: each element is an element of `L`, in `L`'s order (filter, take, drop, pop, slice, removeAt) |
| `insert κ` / `removeAt κ` / `swap κ₁ κ₂` / `set κ` | the named edit; every other element is `L`'s, at its index shifted as the edit shifts it |
| `permute` | `L'` has `L`'s elements, each exactly once, in another order (sort, reverse) |
| `replaced` | nothing: `L'` is another list |

`kept` is the tag of an element write (`[κ]` or `[*]`); every other tag is a write of the list
path itself. R5 reads the tags (§9.3); for R3 and R4 a tagged write is a write of the list path.

### 2.4 Write sets and the lattice

A **write** is a path with a **kind**, `node` or `value`, and, at a list path, an edit tag. A
**write set** `W` is a map from paths to kinds, `W(p) ∈ {none, node, value}`, with the
invariant that **every proper prefix of a written path is at least `node`**: `W(q) ≥ node`
for every `q ⊏ p` with `W(p) ≠ none`. The order is pointwise over `none < node < value`, join
is pointwise maximum, and edit tags join as: equal tags stay, `kept` under a different tag is the
other tag, two different tags are `replaced`. **The tag join removes no entry below the list
path** (*amended 2026-10-08, B7*): an element write `p[κ].f` is an entry of its own, kept
through every join, so a `kept` write joined with an `append` leaves `value p ⟨append⟩` *and*
`value p[κ].f` in the set, and R5 sees both. **Top** is `value` at ρ: "everything".

The lattice is finite for a fixed program: the paths of length ≤ k over a program's types are
finitely many (every step is a field name, an index symbol drawn from the finitely many
expressions of the program, a constructor or `*`), each has three kinds and a tag from a finite
set, so its **height** is bounded by `2 · |paths| + |tags|`. In practice a write set holds a few
paths: the ones the program's text spells.

What the two kinds mean, once more, since every consumer rests on them: a **`node`** write at `p`
says the object at `p` may be a new one whose untouched children are the old children — a record
update's spread, a constructor re-applied to matched parts; a **`value`** write at `p` says
nothing about what is below `p`.

### 2.5 Conflict

A read of model path `r` **conflicts** with a write set `W` when (*amended 2026-10-08, A3, A4,
B6*)

> some `value` write `w` has `w ⊑̃ r` or `r ⊑̃ w`, or some `node` write `w` has `w ⊑̃ r` and
> `|w| = |r|`,

with `⊑̃` the may-prefix order of §2.1. A `value` write above or below a read can change what
the read sees; a `node` write at a path the read's own path may coincide with can; a `node`
write at a *proper* may-prefix of the read cannot — that is the whole point of the kind. So
`SwapRows`' `value ρ.rows[1]` conflicts with a positional row's `ρ.rows[*].label` (`[1]` may
coincide with `[*]`), `Set id`'s `value ρ.xs[id]` conflicts with a hole reading `ρ.xs[0]` (`[id]`
may coincide with `[0]`), and `Toggle`'s `node ρ.todos[*]` does **not** conflict with a row's
`ρ.todos[*].title`: the record at some position was rebuilt, its `title` is the very value it
was, and the list's length and order are kept. The earlier clause "or `r` is below a `node`
write whose list step is `[*]`" is withdrawn: may-coincidence does its work, and it contradicted
§10.5. This is research 61 §2.3's rule ("one path is a prefix of the other") with `node` writes
and index aliasing added, and it is what §1.2's two promises are stated through. §5.2 proves it.

### 2.6 Unions and opaque wrappers

A model whose type is a custom type (Conduit's `Model = Redirect Session | NotFound Session |
Home Home.Model | …`) is not special: its paths start with a constructor step, `ρ.Home#0`, and
the facts a `case` establishes about the tag at ρ (§3.2) are what make a page's writes land under
its own variant. An **opaque** wrapper (`Feed.Model = Model Internals`) is a custom type of one
constructor, and a type of one constructor has its tag at every path of that type without any
`case` (§3.2, *the single-constructor rule*), so `Model { model | errors = [] }` writes
`node ρ`, `node ρ.Model#0`, `value ρ.Model#0.errors ⟨clear⟩` with no help. `--release`
represents a single-constructor, single-field type as its field (`backend.md` §9, *A type of one
constructor with one field is its field*): the paths are the same paths, and the `node` write at
the wrapper coincides with the one at its field; both are in the set, so the representation
does not matter to the claim.

A model whose type is a **type variable** or a function has no paths below ρ: every write is
at ρ. A **`Dict`** or **`Set`** has no positions in this domain (*open choice O3*): a write into
one is a `value` write of the dict's path, and a hole that reads a dict reads it whole.

## 3. Abstract values and the transfer rules

The write set is not computed directly. The analysis first computes, for every expression of
`update`, an **abstract value** saying what the expression's value is *in terms of the old
model* (and of the function's parameters, §4.1); the write set is then read off the result
(§3.4). This is the standard arrangement of an abstract interpretation (Cousot & Cousot 1977,
§11): a concrete value is a JavaScript value; an abstract value stands for a set of them; each
construct of the language has a rule that maps the abstract values of its parts to one for the
whole, and each rule over-approximates the construct's concrete meaning.

### 3.1 Abstract values

```
a ::= Same(p)                       the very value at path p (identity)
    | Lit(c)                        a literal: a number, string, character, nullary constructor
    | Rec(b?, { f ↦ a })            a record: fields f replaced, every other field as in b (b a path or none)
    | Con(C, [a₁ … aₙ])             constructor C applied to parts
    | Tup([a₁ … aₙ])                a tuple
    | Lst(b?, tag, κ?, a?)          a list made from the old list at b by the edit `tag`, with a
                                    written element at κ (or [*]) whose value is a
    | Fresh(D)                      a value the analysis cannot relate to the old model, computed
                                    from the model paths in D (D a finite set of paths, or ρ)
    | Fun(λ)                        a function value: a lambda or a top-level function with
                                    the abstract values it closes over (§4.2)
    | Alt(s, [ (Γ₁, a₁) … (Γₙ, aₙ) ])   one of several, each under the tag facts Γᵢ (§3.2),
                                    chosen by the scrutinee s (an abstract value, kept for
                                    anchoring, §3.6)
```

**Two kinds of `Alt`** (*amended 2026-10-08, C2; corrected the same day, N1*). A **keyed** `Alt`
is one a `case` makes on a scrutinee `Same(p)` with constructor patterns: **one alternative per
arm**, in arm order, each carrying its arm's **whole pattern** (two arms for one constructor —
`Loaded (Just x) → …; Loaded Nothing → …` — are two alternatives) and the facts §3.2 gives the
arm; its width is bounded by the number of arms, which the type bounds in practice, and it is
exempt from the width cap A below. **Selection** by a message key (§4.4) or by an argument at
instantiation (§4.2) **keeps every alternative that is not contradicted**: an alternative is
dropped only when its arm's pattern, **matched fully** against what is known of the scrutinee —
a `Con` and the `Con`s and `Lit`s inside it, a tag fact at the path — fails at a step whose
shape is known; a pattern that meets a part nothing decides (`Fresh`, a variable) is kept, and
so is every wildcard and variable arm. For `Loaded (Just _) → …; _ → …` applied to
`Con(Loaded, [Lit Nothing])`, the first alternative fails at `Nothing` against `Just` and is
dropped, the default is kept; applied to `Con(Loaded, [Fresh])`, both are kept and joined. This
is §3.2's `Con`-scrutinee rule, stated once more for selection: an arm is skipped only when its
own pattern cannot match. Every other `Alt` — an `if`, a `case` on a value that is not a path, a
join of summaries in a fixpoint — is **plain** and counts against A.

Elsewhere in this document an `Alt` is written without its scrutinee, `Alt([ (Γᵢ, aᵢ) ])`, when
only the alternatives matter; the scrutinee is always carried.

**Terms are shared.** Abstract values are hash-consed: structurally equal terms are one node,
so a chain of `let aₙ = if cₙ then aₙ₋₁ else aₙ₋₁'` is a DAG of 2n nodes and not a tree of 2ⁿ,
and `diff` is memoised on `(node, p, Γ)` with Γ interned as a sorted set (*amended 2026-10-08,
C1*). The **size cap S** (§6.1) counts DAG nodes and applies to **every** term the analysis
builds — a summary, a key's result, a lambda body's value at a call site — not only to
summaries; and the **depth** below counts an `Alt` as a level like any constructor.

Every abstract value has a **concretisation**, the set of JavaScript values it stands for given
an old model `M` (and, for πᵢ and εⱼ roots, the argument values). It is stated in §5.1; the
rules below are written against it. Three remarks the rules depend on:

- `Same(p)` is the strongest claim: *this is `M@p` itself*. It is what a variable bound to the
  model, a field read of it, or a pattern variable matched against it has.
- `Rec`, `Con`, `Tup` and `Lst` are claims about a *new* object with known parts; `Fresh(D)` is
  no claim beyond what it was computed from, which §3.6's anchoring uses and the write side does
  not.
- `Alt` keeps alternatives **symbolic** instead of joining them, so that a `case` whose arms are
  later placed into the model loses nothing: `feed = case model.feed of Loading →
  LoadingSlowly; other → other` is `Alt([ (tag(ρ.feed)=Loading, Lit LoadingSlowly),
  (tag(ρ.feed)≠Loading, Same(ρ.feed)) ])`, and it is only when it lands at `ρ.feed` that §3.4
  turns it into `value ρ.feed`. A **plain** `Alt` holds at most **A = 16** alternatives; a join
  that would make more is `Fresh` of the union of their dependencies (*open choice O2*). A keyed
  `Alt` is bounded by its type instead (above).

**Depth.** An abstract value nested more than k constructors, records, tuples or lists deep is
cut: the part below the cut becomes `Fresh`. Paths and values share one limit, and for the same
reason (§2.2).

### 3.2 Tag facts and refinement

A **tag fact** is `tag(p) = C` or `tag(p) ≠ {C₁ … Cₙ}` for a path `p` of a custom type. **Γ** is
a finite set of tag facts, the **context** an expression is analysed under; it starts empty at
`update`'s body and grows under a `case`. Γ is **path-sensitive on tags only**: it records no
fact about numbers, strings or list lengths, because the renderer's comparison needs none, and
tags are what make a same-variant rebuild recognisable.

**Refinement under a `case`.** For `case e of pat₁ → e₁; …`, with `e`'s abstract value `a`:

- If `a = Same(p)` and `patᵢ` is a constructor pattern `C x₁ … xₙ` (or a nested one), arm i is
  analysed under `Γ ∪ {tag(p) = C}`, each `xⱼ` bound to `Same(p.C#j)` and nested patterns
  refined the same way below `p.C#j`; a tuple pattern over `a = Tup(…)` or `Same(p)` binds its
  components to the parts or to `Same(p.j)`; a record pattern binds fields to `Same(p.f)`; a
  wildcard or variable binds the whole; a literal pattern refines nothing. A list pattern
  `[ x, …rest ]` binds `x` to `Same(p[0])` and `rest` to `Lst(p, removeSome)` — a view, which
  `backend.md` §4 makes `same` as the old tail but not `===` to any old path, so `Same` would
  be wrong.
- A later arm is analysed under the **negation** of the earlier arms' patterns — but only of an
  earlier arm whose pattern is a **single-path, irrefutable-below test** (*amended 2026-10-08,
  A1–A2*): a constructor pattern `C x₁ … xₙ` on a scrutinee `Same(p)` whose sub-patterns are
  all irrefutable (variables, wildcards, tuple or record patterns of those), or a tuple or
  record pattern with **exactly one** such constructor pattern among its components and the
  rest irrefutable. Such an arm fails to match for one reason only, the tag at `p` is not `C`,
  so the later arm gets `tag(p) ≠ {C}`, and `other → other` in the example above gets
  `tag(ρ.feed) ≠ {Loading}` and binds `other` to `Same(ρ.feed)`. An arm whose pattern tests
  **two or more paths** (`( GotHomeMsg sub, Home home )`) can fail because either tag differs — a
  disjunction this Γ cannot hold — and an arm with a **refutable sub-pattern** (`Loaded (Just
  x)`, `Loaded ( Editing "", _ )`) can fail with the outer tag in place; **neither contributes a
  negation fact**, and the arms after them are analysed as if they were absent. The positive
  facts of an arm's own pattern, nested ones included, are always sound: the arm ran, so they
  hold.
- If `a` is `Con(C, parts)`, an arm is **not analysed** only when its **own pattern, matched
  fully against the known shape** — `C` and the `Con`s and `Lit`s among `parts`, recursively —
  fails at a step whose shape is known (it cannot run); every other arm is analysed, with its
  variables bound to the parts it matches: a wildcard or variable arm, an arm for `C` whose
  refutable sub-pattern meets a `Fresh` part, and, in arm order, every later arm not
  contradicted (*amended 2026-10-08, N1*: `Loaded (Just _)` against `Con(Loaded, [Lit
  Nothing])` fails at `Nothing` and is skipped; the `_` arm after it runs).
  If `a` is `Alt`, each alternative is matched separately under its own Γ and the results are
  joined. Otherwise (`Fresh`, `Lit`) the scrutinee is unknown, the arms are analysed with no
  refinement, and variables bound by a constructor pattern over it are `Fresh(D)` with the
  scrutinee's dependencies. The one rule for skipping an arm, here and in §4.4, is that **its
  own pattern contradicts a fact that holds**; a negation fact never skips an arm, it only
  refines the value `other → other` binds.

**The single-constructor rule.** For a type with exactly one constructor `C`, `tag(p) = C` holds
at every path `p` of that type without a `case`. This is what makes an opaque wrapper
transparent (§2.6) and a tuple-like record type's constructor re-application a `node` write.

**Negation and the one-constructor-left rule.** When `tag(p) ≠ S` and the type at `p` has
exactly one constructor `C ∉ S`, then `tag(p) = C`. It is what makes `_ → status` after `Saving`
and `Creating` arms precise enough, and it costs a set difference.

### 3.3 The transfer rules

Each rule is `⟦e⟧(Γ, env) = a`: the abstract value of `e` under the context Γ and the environment
`env` mapping locals to abstract values. `update msg model` starts with `env = { model ↦ Same(ρ),
msg ↦ the key's message value (§4.4) }`. After each rule, one sentence says what it means.

**Variables.** `⟦x⟧ = env(x)`. A variable is what it was bound to; in particular `model` is
`Same(ρ)`, and `( model, Cmd.none )` therefore writes nothing — the **identity case**, which is
the base of everything else.

**Top-level values** (*amended 2026-10-08, B3*). A reference to a top-level value `v` (not a
function: `initialModel`, `emptyForm`, `adjectives`) is `⟦body of v⟧(∅, { })`, the body
analysed once per program with an empty environment and memoised: a closed term, so it holds no
`Same` and is a `Lit`, a structure of literals, or `Fresh(∅)`. Placed into the model it is a
`value` write; under `init` it is what `literal` (§3.5) reads. A top-level value of a function
type is `Fun` of its body's lambda.

**Literals.** `⟦c⟧ = Lit(c)`. A nullary constructor is a literal; so are numbers, strings and
characters. (Two evaluations of a string literal need not be `===` in JavaScript; a `Lit` placed
where an old `Lit` was is still a `value` write — §3.4 never claims identity for a literal.)

**Field access and tuple index.** `⟦e.f⟧ = proj(⟦e⟧, .f)` where
`proj(Same(p), .f) = Same(p.f)`, `proj(Rec(b, fs), .f) = fs[f]` if `f ∈ fs` else `Same(b.f)`
(or `Fresh` when `b` is none), `proj(Tup(as), .i) = aᵢ`, `proj(Con(C, as), C#i) = aᵢ`,
`proj(Alt(…), s)` projects each alternative, and `proj(a, s) = Fresh(deps(a))` otherwise. A
read of a path is that path; a read of a field a record update replaced is the replacement.

**Record update.** `⟦{ r | f₁ = e₁, … }⟧ = Rec(base(⟦r⟧), { fᵢ ↦ ⟦eᵢ⟧ } ∪ rest)` where, when
`⟦r⟧ = Same(p)`, `base = p` and `rest = ∅`; when `⟦r⟧ = Rec(b, fs)`, `base = b` and `rest = fs
minus the fᵢ`; otherwise `base = none` and every field not named is `Fresh(deps(⟦r⟧))`. The
rule rests on `language.md` §11.12: a field the update does not name is the very value `r`
held. This is the key lemma of §5.2, and the reason a record update at `p` is a `node` write at
`p` and `value` writes at `p.fᵢ`, not a `value` write at `p`.

**Record construction.** `⟦{ f₁ = e₁, … }⟧ = Rec(none, { fᵢ ↦ ⟦eᵢ⟧ })`. A new record; its
fields are what was written in them.

**Constructor application.** `⟦C e₁ … eₙ⟧ = Con(C, [⟦eᵢ⟧])`. The same-variant case is not a
rule of its own: `Home (Home.update sub home)` is `Con(Home, [a])` like any application, and it
is §3.4's comparison — under the arm's fact `tag(ρ) = Home` — that reads it as `node ρ` plus
`a`'s writes under `ρ.Home#0`. A constructor used as a function value (`updateWith Home …`,
`(Editor slug _)`) is `Fun` of the lambda it desugars to (`language.md` §8), and §4.2 applies it.

**Tuples.** `⟦( e₁, …, eₙ )⟧ = Tup([⟦eᵢ⟧])`. A `model × Cmd msg` result is a tuple whose first
component is the model.

**Lists.** `⟦[]⟧ = Lst(none, clear)`; `⟦[ e₁, …, eₙ ]⟧ = Lst(none, replaced)` with the elements
kept for `init`'s literal question only (§3.5); `[ x, …xs ]` and `[ …xs, x ]` are the
`List.cons`/`List.append` calls lowering made of them (`language.md` §8) and take the core rows
of §3.7.

**`case`.** `⟦case e of patᵢ → eᵢ⟧ = Alt([ (Γᵢ, ⟦eᵢ⟧(Γᵢ, envᵢ)) ])` with Γᵢ and envᵢ from §3.2.
An `if` is a `case` on `True`/`False` and refines nothing. The arms are kept apart, each with
the facts that make it reachable; nothing is joined until a value lands in the model.

**`let` and blocks.** `⟦x = e₁; e₂⟧ = ⟦e₂⟧(Γ, env[x ↦ ⟦e₁⟧])`; a destructuring `let`
(`( status, cmd ) = save cred model.status`) binds by the pattern rules of §3.2 without
refinement. A statement (`let_stmt`) binds nothing. A local function bound by a `let` is `Fun`.
Bindings are in written order; a block's value is its last expression's.

**Lambdas.** `⟦λx₁ … xₙ → e⟧ = Fun(λ)`, closing over `env`. It is not analysed until applied
(§4.2).

**Calls to user functions.** `⟦f e₁ … eₙ⟧ = inst(summary(f), [⟦eᵢ⟧], Γ)` — the callee's summary
instantiated with the arguments (§4.2). A call through a local that holds `Fun` is the same with
the lambda's body as the summary. A call through a local that is not `Fun` (a function from a
payload, from `Fresh`) is `Fresh(deps of the arguments)`.

**Calls to core and platform functions.** A function whose body is beni over nothing `foreign`
is summarised like a user function — `Maybe.map`, `Result.map`, `Maybe.withDefault` and most of
`core/` need no table row. A function whose body reaches a `foreign`, or whose precision the
body cannot give (`List.map` is a loop over `at`, `put` and `kept`, `foreign` all three), takes
its summary from the **core summary table**, §3.7. A call of anything in neither — a `foreign`
itself, a platform function with no row — is `Fresh(deps of the arguments)`.

**Static dispatch.** A method call `x.m a` or a `type_dispatch` is a call of the function the
dispatch table names at that site (`checker-v2.md` §13: a `top`, `ext`, `derived` or
`ext_derived` term), summarised as that function; a `derived` `eq`/`compare` returns a `Lit`
(a `Bool` or an `Order`). A call whose evidence is a **parameter** (`param` term: the enclosing
function has a `where` clause and the method is the caller's to supply) is summarised as
`App(evidence, args)` in the summary and resolved at instantiation like a function-valued
argument (§4.2); at the program's `update`, where no evidence is a parameter, every method is
resolved. `==` and `<` on the model are reads, not writes, and contribute only dependencies.

**Effects.** For a program whose `update` returns `model × Cmd msg`, the write set is read off
`proj(result, .0)`; the command is not analysed. A `Cmd` carries no model and runs after the
flush; a message it sends later is dispatched by its own key. An `impure` call in `update`
(`Debug.log`, a platform primitive) is analysed by its row or as `Fresh`; it does not change the
write set's meaning, because the claim is about the returned model only. `Debug.log x` returns
`x` itself and has a row saying so (§3.7); `Debug.todo` is `Fresh(∅)` (it does not return).

**`foreign`, a `Js` intrinsic, and anything unsummarisable** is `Fresh(D)`, with `D` the union
of its arguments' dependencies. Wherever a `Fresh` lands in the model it is a `value` write there (§3.4). This is
the one rule that can produce `value ρ`, and `compile-away.md` §2 says what that costs: today's
path.

**Guards on an index.** Inside a callback of `List.indexedMap` or `List.update` (§3.7) whose
index parameter is ιⱼ, an `if` or `case` whose condition is `ιⱼ == e` (or `e == ιⱼ`) with `e`
handler-evaluable (§2.3) analyses its `then` arm under the index fact `ιⱼ = e`, and its `else`
arm under `ιⱼ ≠ e`; a conjunction of such facts along nested `if`s accumulates. When the
callback's result is `Same(εⱼ)` under every alternative whose index facts do not fix ιⱼ, and
some other value only under alternatives that fix ιⱼ to `e₁ … eₘ`, the element write is at
`[e₁] … [eₘ]` instead of `[*]`. `Int.mod i 10 == 0` is not an index equality and yields `[*]`:
the domain has no residue classes, and `[*]` with the element's own sub-writes is what research
58 §4's R2 expects for "update every 10th" (one compare per row, 1 000 of them). Research 60
§5.4 asked for both; the swap is captured exactly and the residue is captured as "some
elements, shape kept", which is what it is.

### 3.4 Reading the write set off a value

`diff(a, p, Γ)` is the write set of placing the abstract value `a` at model path `p` — the set
of paths at or below `p` whose value may not be `M@…`:

| `a` | `diff(a, p, Γ)` | why |
|---|---|---|
| `Same(q)`, `q = p` exactly (§2.1's exact order on uncut paths, index symbols equal by §2.3) and `q` holds no `[*]` or `[?]` step | `∅` | the very value |
| `Same(q)`, otherwise | `{ value p }` | an old value, but another one, or *some* element's — it may happen to be `===` (`other → other` re-bound at the same path is `q = p`, not this row; `λ_ → t` with `t ↦ Same(ρ.todos[*])` mapped over `ρ.todos` is this row, *amended 2026-10-08, A5*) |
| `Lit(c)` | `{ value p }` | a literal is never promised identical |
| `Rec(b, fs)`, `b = p` | `{ node p } ∪ ⋃_f diff(fs[f], p.f, Γ)` | §11.12: unnamed fields keep identity |
| `Rec(none, fs)`, `fs` naming **every** field of the record type at `p` | `{ node p } ∪ ⋃_f diff(fs[f], p.f, Γ)` | a new object whose every field is known (*amended 2026-10-08, N7*): `{ a = model.a, b = 1 }` at ρ is `node ρ; value ρ.b` |
| `Rec(b, fs)`, `b ≠ p`, or `b` none with a field missing | `{ value p }` | a record built from another old one, or one the cut truncated |
| `Con(C, parts)`, `Γ ⊢ tag(p) = C` | `{ node p } ∪ ⋃ᵢ diff(partᵢ, p.C#i, Γ)` | the tag is known preserved, so the parts are at their paths |
| `Con(C, parts)`, otherwise | `{ value p }` | the tag may differ |
| `Tup(parts)` | `{ node p } ∪ ⋃ᵢ diff(partᵢ, p.i, Γ)` | a tuple's components are at their indices |
| `Lst(b, tag, κ, a')`, `b = p`, `tag = kept` | `{ node p ⟨kept⟩ } ∪ diff(a', εⱼ, Γ)[εⱼ := p[κ]]` | an element write at the written position; `κ` is `*` when unknown. **The element result is diffed against the callback's own root εⱼ as the placement root** (*amended 2026-10-08, N2*): `diff` is run with εⱼ in place of the path, so `Same(εⱼ)` is identity and `Rec(εⱼ, fs)` is a `node` write with its fields' writes, and every write path `εⱼ.s` that comes out is rewritten to `p[κ].s`. Sound because `kept` puts the result for element i at position i. It holds for the εⱼ root only: a `Same(ρ.todos[*])` in `a'` is still §3.4's second row (`Fill` stays `value p[*]`), and `Toggle` is `node p[*]; value p[*].completed` |
| `Lst(b, tag, …)`, `b = p`, other tag | `{ value p ⟨tag⟩ }` | the shape changed as the tag says |
| `Lst(b, …)`, `b ≠ p` or none | `{ value p ⟨replaced⟩ }` | another list |
| `Fresh(D)`, `Fun` | `{ value p }` | unknown |
| `Alt([ (Γᵢ, aᵢ) ])` | `⋃ᵢ diff(aᵢ, p, Γ ∪ Γᵢ)` | each alternative under its own facts |

plus, in every row, `node q` for every proper prefix `q ⊏ p` not already in the set (the
invariant of §2.4), and the k-cut: a write at a path longer than k is a `value` write at its
k-prefix. **`writes(κ) = diff(proj(⟦body⟧, .0), ρ, ∅)`** for a `model × Cmd msg` program,
`diff(⟦body⟧, ρ, ∅)` otherwise, where `⟦body⟧` is `update`'s body under the key's message (§4.4).

`Γ ⊢ tag(p) = C` holds when the fact is in Γ, when the single-constructor rule gives it, or when
negation leaves one constructor (§3.2). It does **not** hold for a `Same(q)` scrutinee with
`q ≠ p` — a tag known at one path says nothing about another.

The row for `Same(q), q ≠ p` is where "another old value" is written coarsely on purpose:
`Undo → prev` (research 61 §5) places `ρ.history[0]` at ρ, which is `value ρ`, as a person
would say.

### 3.5 `init`, and what is literal

`init` is analysed with no old model: `env = { }` plus its parameters (`Url`, `Navigation.Key`,
flags), each `Fresh`. Its result's model component is an abstract value `a₀` with no `Same` in
it. **`literal(p)`** holds when `proj(a₀, p)` — projected through `Rec`, `Con`, `Tup` and literal
`Lst` nodes — is `Lit(c)`, a `Con` or `Rec` or `Tup` whose parts are all literal, or an empty
list; it fails at `Fresh`, `Alt`, a non-empty list built by a call, and a `Fun`. R3 bakes a
hole's value into the template's HTML only when the hole is exactly such a path, nothing writes
it, and its literal is a string (§9.1, B5): `literal(p)` is a fact about the model, and baking
needs one about the hole too. Conduit's `init` is
`changeRouteTo (Route.fromUrl url) (Redirect …)`, an `Alt` over routes with `Fresh` pages, so
nothing of it is literal — and research 62 §4's literal-init holes read nothing of the model at
all, which is `literal` trivially (an empty read set).

### 3.6 Anchoring the view's reads

Slice B computes a hole's read paths relative to the **locals** of the function holding the
markup root, at most four links each (`boundary.md` §9.4.6, `Root.reads`). For R3 and R4 those
paths must be model paths. The same interpreter supplies the **anchor**: `view` (and every
function `view` calls that returns markup, inlined at its call as slice B already does for its
holes) is analysed with `env = { model ↦ Same(ρ) }`, pattern-bound locals refined by §3.2
(`case model of Home home →` binds `home ↦ Same(ρ.Home#0)`), and a local's read of the suffix
`s` anchors to

- `q.s` when the local is `Same(q)`;
- the anchors of `proj(a, s)` when it is `Rec`/`Con`/`Tup` — the written field's own anchors,
  or the base's path;
- **`D`**, every path in it, when it is `Fresh(D)`: a value computed from those paths may change
  when any of them does;
- for an `Alt(s, …)`, **the scrutinee's anchors, the path of every tag fact of every
  alternative, and every alternative's anchors** (*amended 2026-10-08, A6*): which alternative
  holds is decided by the scrutinee, so a value chosen by control flow over the model reads what
  the choice read. `label = if model.on then "On" else "Off"` anchors to `ρ.on`, and a `case
  model.status of Loading → "…"; _ → "…"` anchors to `ρ.status`, though every arm is a literal.
  `deps` follows the same rule: `deps(Alt(s, alts)) = deps(s) ∪ paths(Γᵢ) ∪ ⋃ deps(aᵢ)`.

A row variable of a `For` over a list at `q` anchors to `q[*]` (slice B binds it to the item;
`language.md` §11.9). A local anchored at ρ itself — `view model` used whole — reads everything,
which conflicts with every write set, as today. Anchored reads are cut at k like writes (§2.2).

**Dependencies `D`** are collected by every rule above: `deps(Same(p)) = {p}`, `deps(Lit) = ∅`,
`deps` of a structure is the union over its parts, `deps(Fresh(D)) = D`, `deps(Fun)` is the
closure's environment's, and a call's `Fresh` carries its arguments'. They are the read side's
version of "whole local" and are never used to decide a write.

### 3.7 The core summary table

A row gives a core function's result as an abstract value over its arguments' abstract values
`a₁ … aₙ`, with `p` short for "the path `aᵢ` is `Same` of" where a row needs the argument to be
an old value — when it is not, the result is `Fresh(deps)` unless the row says otherwise. Every
row cites the guarantee it rests on; `backend.md` §4 (*Identity: what an operation returns
unchanged*) is the source for lists. A callback argument `f` is applied by §4.2 with its element
parameter bound to `Same(εⱼ)` — **a root of its own**, which stands for the element at `p[*]`
but is **not** the path `p[*]` and unifies with nothing else (*amended 2026-10-08, A5*) — and,
where there is one, its index parameter to ιⱼ; "`f` is identity" means its result is exactly
`Same(εⱼ)`, the root, under every alternative. A callback that returns `Same(ρ.todos[*])` (an
element it was handed some other way) is not identity, and its `map` is `Lst(p, kept, *,
Same(ρ.todos[*]))`, which is `value p[*]` by §3.4's second row.

| function | result | rests on |
|---|---|---|
| `List.map xs f` | `Same(p)` when `f` is identity; else `Lst(p, kept, *, f's result)` | `map` returns `xs` itself when every result is `===` its element (`core/List`, `kept`) |
| `List.indexedMap xs f` | as `map`, with the index facts of §3.3: `Lst(p, kept, [e₁…eₘ], …)` when guards fix the written positions | the same |
| `List.filter xs f` | `Lst(p, removeSome)` | `filter` keeps every element's identity and order |
| `List.filterMap xs f` | `Fresh` — unless `f`'s result is `Con(Just, [Same(εⱼ)])` or `Lit Nothing` under every alternative, then `Lst(p, removeSome)` | elements kept are `===` |
| `List.update xs κ f` | `Same(p)` when `f` is identity; else `Lst(p, kept, [κ], f's result)` with `f`'s element `Same(p[κ])` | `update` out of range or writing the identical value returns `xs` |
| `List.set xs κ v` | `Lst(p, kept, [κ], ⟦v⟧)` | likewise |
| `List.swap xs κ₁ κ₂` | `Lst(p, swap κ₁ κ₂)` | `swap xs i i` and out of range return `xs` |
| `List.push xs v`, `List.append xs [ v… ]`, `[ …xs, v ]` | `Lst(p, append)` | the old elements keep identity and position |
| `List.cons v xs`, `[ v, …xs ]` | `Lst(p, prepend)` | likewise |
| `List.append xs ys` (`++` on lists, by the dispatch table) | `Lst(p, append)` when `xs` is `Same(p)`; `Lst(q, prepend)` when only `ys` is `Same(q)`; `Fresh` otherwise | `xs ++ []` is `xs` |
| `List.pop`, `take`, `drop`, `slice`, `tail` (as `Just`) | `Lst(p, removeSome)` | a view or a prefix shares elements |
| `List.insertAt xs κ v` / `removeAt xs κ` | `Lst(p, insert κ)` / `Lst(p, removeAt κ)` | out of range returns `xs` |
| `List.reverse`, `sort`, `sortBy`, `sortWith` | `Lst(p, permute)` | element identity always (invariant 6) |
| `List.get xs κ`, `head`, `last` | `Alt([ Con(Just, [Same(p[κ])]), Lit Nothing ])` (`[0]` for `head`, `[?]` for `last` — a `Same` that is never identity at a placement path, §2.3, and anchors to `p[*]`) | an element read is the element |
| `List.length`, `isEmpty`, `member`, `all`, `any`, `sum`, `product`, `maximum`, `minimum` | `Fresh(deps)` scalars or `Maybe`s | — |
| `List.foldl`, `foldr`, `concat`, `concatMap`, `initialize`, `range`, `repeat`, `singleton`, `intersperse`, `partition`, `unzip` | `Fresh(deps)` | no identity promised |
| `Dict.*`, `Set.*` | `Fresh(deps)` (§2.6, O3) | — |
| `Maybe.map`, `withDefault`, `andThen`; `Result.map`, `mapError`, `andThen`, `withDefault`, `toMaybe`; `Tuple.first`, `second` | **no row**: beni bodies, summarised by §4 | — |
| `Basics.*`, `Int.*`, `Float.*`, `String.*`, `Char.*` | `Fresh(deps)` — except `Basics.identity x = x` and `always`, by their bodies | — |
| `Debug.log tag x` | `Same` of what `x` is: `⟦x⟧` itself | the sibling returns its argument (requirement, §5.4) |
| `Debug.todo` | `Fresh(∅)` | never returns |
| `Html.map`, `Cmd.map`, `Cmd.*`, `Sub.*`, `Task.*`, platform primitives | `Fresh(deps)` | not model values; `Cmd` is not analysed |

**How a function gets a row.** A row is an entry in the compiler's table keyed by the function's
qualified name (*open choice O4*: a table in the compiler, `src/writes/Core.zig`, against an
annotation in `core/`), and every row has two things beside it: the sentence in `backend.md` §4
or `core/List` that promises the identity it relies on, and a `run/` fixture that pins that
promise in both builds (`backend.md` §15.8's kind). A core function with no row and a `foreign`
in its body is `Fresh`; nothing is ever wrong for want of a row, only coarse. A new core
function that should be precise gets a row, the sentence and the fixture in one change.

**Why the table is small.** The identity guarantees were written for the markup runtime, which
skips work on `===` (§15.4), long before this analysis; the rows restate them and add nothing.
A reader who finds a row the sibling does not honour has found a defect in the sibling, not in
the row.

## 4. Functions, recursion and nested dispatch

### 4.1 Summaries

The **summary** of a function `f x₁ … xₙ = e` is the abstract value `⟦e⟧(∅, { xᵢ ↦ Same(πᵢ) })`:
the body analysed once, with each parameter a symbolic root of its own, with no tag facts, and
with every call inside it to a function-valued parameter kept as an **application node**
`App(Same(πᵢ), [args])` (and likewise a call through `where`-clause evidence, §3.3). A summary
is a term over `π₁ … πₙ` — `Rec(π₂, { status ↦ Alt([ (tag(π₂.status)=Saving, Con(Saving,
[Same(π₂.status.Saving#0), App(Same(π₁), [Same(π₂.status.Saving#1)])])), … ]) })` is
`Editor.updateForm`'s — and it is computed once per function, whatever the number of calls.

**Roots are unique per function** (*amended 2026-10-08, B1*): `πᵢ` is short for `πᵢ^f`, the
i-th parameter of `f`, and no two functions share a root, so a summary that holds another
function's roots — a `Fun` closing over a callee's environment, a term a callee returned —
cannot be rewritten by its caller's instantiation except where the caller's own roots appear.

This is Sharir & Pnueli's functional approach (1981, §11): a procedure's effect is a function
from its input abstract value to its output, and a call applies the function. Here the function
is a **symbolic term** and application is **substitution**, which is cheaper than re-analysing
and exact for everything but `Alt` width and depth. It is not the incremental lambda calculus's
derivative (Cai et al. 2014), which would describe the result's *change* as a function of each
argument's change; §11 says why a value-level summary suffices when the model is immutable.

A summary is kept only for functions with a body: a `foreign` has none and is `Fresh` or a row
(§3.7). The summary of a `pub` function is a property of its module and could be published in
its interface; it is not, in this slice (§6.3).

### 4.2 Instantiation

`inst(S, [a₁ … aₙ], Γ)` replaces every `Same(πᵢ.s)` in the summary `S` by `proj(aᵢ, s)` — the
argument projected through the suffix `s`, which is `Same(q.s)` for an old value, a part for a
built one, `Fresh` for the rest — and every tag fact `tag(πᵢ.s) = C` in an `Alt` by
`tag(q.s) = C` when `aᵢ` is `Same(q)`, by the fact's truth when `proj(aᵢ, s)` is a `Con` or
`Lit` (an alternative whose fact is false is dropped), and by **no fact** otherwise, in which
case the alternative stays and the `Con` it builds is a `value` write where it lands (§3.4).
A **keyed** `Alt` on `πᵢ.s` (§3.1) whose argument projects to a `Con`, a `Lit` or a `Same(q)`
with a fact at `q.s` in Γ **keeps every alternative not contradicted** by matching each arm's
whole pattern against that shape (§3.1's selection, *amended 2026-10-08, N1*) — one alternative
when the shape decides every step of every pattern, several otherwise, joined as the `Alt` they
remain. **Index symbols in a summary are terms over the callee's roots** (*amended 2026-10-08,
N5*): `[πᵢ.k]`, `[πᵢ.k + 1]`, and substitution rewrites them like any other term, so that
`[k]` in `List.set xs k v`'s caller becomes the caller's own argument expression, and §2.3's
equality is decided on the **instantiated** terms — two symbols are equal when they are the
same instruction under the same substitution, never because two calls of one helper share its
text. Substitution **descends into
every sub-term, a `Fun`'s closed-over environment included** (*amended 2026-10-08, B1*), and it
touches only the callee's own roots (§4.1). **A base that is not a path** (*amended 2026-10-08,
B2*): a `Rec(πᵢ.s, fs)` whose argument projects to `Same(q)` becomes `Rec(q.s, fs)`; to
`Rec(b, gs)` becomes `Rec(b, gs ∪ fs)` with `fs` overriding (`Fresh` for the fields of neither
when `b` is none); to anything else becomes `Rec(none, fs ∪ { every other field of the type ↦
Fresh(deps(arg)) })`. A `Lst(πᵢ.s, tag, κ, a)` whose argument projects to `Same(q)` becomes
`Lst(q.s, tag, κ, a)`; to `Lst(b, kept, κ', a')` with `tag = kept` becomes `Lst(b, kept, …)`
holding both element writes; to anything else becomes `Lst(none, replaced)`. Then every
application node is reduced:

- `App(Fun(λ), args)` with `λ = λy₁ … yₘ → e` closing over `env`: `⟦e⟧(Γ, env[yⱼ ↦ argⱼ])`,
  the lambda's body analysed with the arguments. A constructor passed as a value (`Home`,
  `(Editor slug _)`) is the lambda lowering made of it, so this reduces to `Con(Home, [arg])`
  and `Con(Editor, [Same(ρ.Editor#0), arg])` — a **constructor re-applied through a
  higher-order helper is seen as the constructor**, which is how `updateWith` is seen through.
- `App(Fun(f), args)` with `f` a top-level function: `inst(summary(f), args, Γ)`.
- `App(a, args)` with any other `a`: `Fresh(deps(a) ∪ deps(args))`.

Instantiation nests: a summary's application nodes may instantiate summaries whose application
nodes instantiate further ones. The nesting is bounded by **D = 8** levels, after which an
application is `Fresh` (*open choice O2*). Conduit's deepest is three (`Main.update` →
`updateWith` → `Editor.update` → `updateForm` → the lambda).

**Lambdas and higher-order arguments** are therefore analysed **per call site**, with the
abstract values that reach them, and never summarised on their own: a lambda's meaning depends
on what it closes over, and the call site has it. A lambda that escapes into a data structure
(`Fun` stored in the model, or in a `Cmd`) is `Fresh` where it lands and `value` where it is
written.

### 4.3 Recursion: the fixpoint

Summaries are computed over the **call graph** of top-level functions (BIR `refs`, plus the
dispatch table's edges for method calls, `frontend.md` §3.6), in **reverse topological order of
its strongly connected components**, so a callee's summary exists before its caller's. Inside a
component with a cycle — a recursive function, or mutually recursive ones — the summaries are
computed by **Kleene iteration**: every function of the component starts at **⊥**, the empty
alternative (`Alt([])`, which joins as nothing and instantiates to nothing), each body is
analysed with the current summaries, and the round repeats until no summary changes. Each round
can only add alternatives, deepen terms, or turn a term into `Fresh`: the summaries ascend in a
lattice of finite height (§2.4 and §3.1's caps), so the iteration stops. It is **bounded** at
**I = 4 rounds** (*open choice O2; amended 2026-10-08, C5*): a round that changes no summary is
the one that detects stability, so I rounds allow I − 1 ascents — `bumpTimes` needs two ascents
and a third round to confirm, a mutually recursive pair one more — and a component not stable
after I has every summary replaced by `Fresh(deps of its parameters)`, which is above every
fixpoint and so sound (§5.3).

What this recovers and what it gives up. A loop that walks a list and rebuilds the model at the
end (`bumpTimes n model = if n == 0 then model else bumpTimes (n − 1) { model | count = model.count
+ 1 }`) is `Alt([ Same(π₂), Rec(π₂, { count ↦ Fresh }) ])` after one round and stable after
two: `value ρ.count`, which research 61 §5 hoped for. A loop that threads the model through
an accumulator parameter and returns the accumulator (`buildFrom`) is `Fresh` from the first
round and stays so, which is right: nothing relates its result to the old model by identity.

### 4.4 Message keys and nested dispatch

A **message key** κ is a path of constructor steps through the **message** value, from the
message's root μ: `GotEditorMsg#0 · EnteredTitle` names every message `GotEditorMsg (EnteredTitle
_)`. The **key tree** of a program is built by analysing `update` with `msg ↦ Same(μ)` and
**splitting** μ wherever the analysis meets a `case` whose scrutinee is `Same(μ.s)` for some
suffix `s` of constructor steps — directly (`case msg of`), through a tuple (`case ( msg, model )
of`), or inside a function the message was passed to (`Home.update sub home` with `sub ↦
Same(μ.GotHomeMsg#0)`, whose `case msg of` splits `μ.GotHomeMsg#0`). Each constructor pattern of
such a `case` is one child key, **and the constructors of the type at `μ.s` that no arm names
get one `default` child together** (*amended 2026-10-08, N3*), written `· _` in the dump, under
which every arm naming a constructor at `μ.s` is skipped by the own-pattern rule and the
wildcard and variable arms are analysed; a split whose arms name every constructor has no
default child. The analysis of a named arm continues with the matched variables bound to
`Same(μ.s.C#j)`, which is what lets a deeper `case` split further. So every constructor of the
message type, at every depth the tree reaches, is under exactly one leaf — a named one or a
default — which is what lets §9.2 treat an unknown tag as a defect. So the dispatch key
is **the path of constructors `update` and its callees actually match on**, nothing more — a
`Result` payload matched with `Ok`/`Err` splits (`CompletedFavorite · Ok`), a `String` payload
does not, and an inner message handed whole to something `Fresh` stops the split there.

Formally, `writes(κ)` is `diff` of `update`'s result analysed under the message facts
`tag(μ.s) = C` for every step of κ, with an arm skipped **only when its own pattern requires a
tag at some `μ.s` that the key's facts contradict** (§3.2's skipping rule, *amended 2026-10-08,
A1*). A fallthrough arm — `( _, _ ) → …` after `( GotHomeMsg sub, Home home ) → …` — is analysed
for every key, because the earlier arm's two-path pattern contributes no negation and the
fallthrough can run for `GotHomeMsg` when the model is another page; what it writes
(`{ model | warning = "stale message" }`: `value ρ.warning`) is in every key's set. A key is a **leaf** when no arm reachable under it splits μ
further; the dispatch table (§9.2) has one entry per leaf. The tree holds at most **L = 256**
leaves per program (*open choice O2*); past that, splitting stops and the remaining keys are
their parent's, with the parent's write set the join of what it covers — every named child it
would have had **and its default child** (N3), so that a parent leaf still covers every
constructor below it. Conduit's tree has 9
top-level keys, 65 page keys below seven of them, 4 feed keys below two of those, and a few
`Ok`/`Err` splits: about 100 leaves.

**When the inner message is not statically a constructor.** It never is, statically: a
sub-message always arrives inside a payload, and the key says which constructor it has at run
time. The handler reads the tags along the key to pick the leaf — one property read per step,
the decision tree of `backend.md` §7 — and dispatches to that leaf's handler. What the analysis
cannot do is split where `update` does not: a sub-message forwarded into a function it could
not summarise (`Fresh`) has one key for all its constructors, with the join of their writes,
which for a page-sized `update` is the page's whole variant. That is the bound research 62 §5
item 2 names, and it is paid only where a program hides its own dispatch.

**Messages from commands, subscriptions and the host** (`Cmd.map subCmd ⊤ GotHomeMsg`,
`onUrlChange = ChangedUrl`) arrive as ordinary messages and take their key by their tags at run
time; the analysis needs nothing from `Cmd.map` beyond ignoring it. A key no message ever
carries at run time (a constructor nothing sends) costs a table row and nothing else.

## 5. Soundness

### 5.1 The concretisation

Fix an old model `M`, and for a summary fix argument values `V₁ … Vₙ` for the roots `π₁ … πₙ`
and element values for `εⱼ`. Write `@` for the read of §1.3 extended to those roots. The
concretisation `γ(a)` is the set of JavaScript values `a` stands for:

- `γ(Same(p)) = { M@p }` (one value, the very object; the empty set when `M@p` is undefined);
- `γ(Lit(c))` = the values equal to `c` as a JavaScript primitive or nullary tag;
- `γ(Rec(b, fs))` = the records `r` with `r.f ∈ γ(fs[f])` for `f ∈ fs` and `r.f === M@b.f` for
  every other field (every record when `b` is none and the field is `Fresh`);
- `γ(Con(C, parts))` = the values with tag `C` whose i-th argument is in `γ(partᵢ)`;
- `γ(Tup(parts))` likewise by index;
- `γ(Lst(b, tag, κ, a'))` = the lists `L'` related to `L = M@b` as the tag of §2.3 promises,
  with `L'[κ] ∈ γ(a')` for a `kept` write (every list when `b` is none);
- `γ(Fresh(D)) = γ(Fun) =` every value;
- `γ(Alt([ (Γᵢ, aᵢ) ])) = ⋃ { γ(aᵢ) | Γᵢ holds of M }`, where `tag(p) = C` holds when `M@p` has
  tag `C`.

The order `a ⊑ a'` is `γ(a) ⊆ γ(a')`; `Fresh` is the top. **Monotonicity**: every rule of §3.3
and `diff` are monotone in their abstract arguments (each is defined structurally, and `Fresh`
absorbs), which the fixpoint argument of §5.3 needs.

### 5.2 Each rule over-approximates

**Claim.** If every free local `x` of `e` has its concrete value in `γ(env(x))`, and every fact
of Γ holds of `M`, then the concrete value of `e` is in `γ(⟦e⟧(Γ, env))`.

By induction on `e`. The cases that carry the argument:

- **Variable, literal, construction, tuple**: immediate from the definitions of `γ`.
- **Field access**: `proj` is `γ`-correct — a field of a value in `γ(Same(p))` is `M@p.f`;
  a field of a record in `γ(Rec(b, fs))` is in `γ(fs[f])` or is `M@b.f` by the record's
  definition; a part of a `Con` is in its part's set; anything else is in `γ(Fresh)`.
- **Record update** (the key lemma). `{ r | f = e }` evaluates, by `backend.md` §4, to a spread
  `{ ...r, f: v }`: a new object whose property `g ≠ f` is the very value `r.g` — not a copy —
  which is `language.md` §11.12's promise, kept by every pass of every build. With `r ∈
  γ(Same(p))`, the result has `g === M@p.g` for `g ≠ f` and `f ∈ γ(⟦e⟧)`, which is
  `γ(Rec(p, { f ↦ ⟦e⟧ }))`. With `r ∈ γ(Rec(b, fs))` the same, composed. Otherwise `Fresh`.
- **`case`.** Exactly one arm runs; call it `i`. The pattern matched, so the positive facts of
  §3.2 hold of `M` (a constructor pattern on `Same(p)` matched means `M@p` has that tag, nested
  ones included), and the variables it bound are the parts, which are in the `γ` of
  `Same(p.C#j)` (parts of `M@p`) or of the `Con`'s parts. **The negation lemma** (*amended
  2026-10-08, A1–A2*): a negation fact `tag(p) ≠ {C}` is added only for an earlier arm whose
  pattern is a single-path, irrefutable-below test on `Same(p)`; such a pattern matches **iff**
  `M@p` has tag `C` (every sub-pattern matches whatever it meets, and no other path is
  tested), so its failure to match is exactly `tag(p) ≠ C`. A two-path pattern fails when
  either tag differs and a refutable sub-pattern fails with the outer tag in place, which is why
  neither yields a fact; they yield none, and an arm analysed with fewer facts has a larger
  `γ`. By the induction hypothesis the arm's value is in `γ(aᵢ)`, and `Γᵢ` holds, so it is in
  `γ(Alt)`. An arm skipped by §3.2's rule cannot have run: its own pattern needs a tag the
  known tag of the scrutinee, or the key's fact at μ, contradicts, and that fact holds. **The
  selection lemma** (*amended 2026-10-08, N1*), for a keyed `Alt` selected by an argument or a
  key: the concrete scrutinee `v` is in `γ` of the known shape (a `Con` with its known parts, or
  a value with the key's tags), and the arm that ran matched `v`; a dropped alternative's pattern
  fails at a step whose shape is known, so it fails on every value in that `γ`, `v` included,
  so it is not the arm that ran. The arm that ran is therefore among the kept alternatives, and
  its value is in their join. Keeping alternatives the shape does not decide only enlarges the
  join.
- **The element rebasing** (*amended 2026-10-08, N2*), for `Lst(p, kept, κ, a')` from a `map`,
  `indexedMap` or `update`: by the row's guarantee the result `L'` has `L`'s length and
  `L'[i] = f(L[i])` for every written position i, with `f(L[i]) ∈ γ(a')` read with `εⱼ@ = L[i]`.
  Placing `L'` at `p` changes, below `p[i]`, exactly the paths changed between `L[i]` and
  `f(L[i])`, which `diff(a', εⱼ, Γ)` with `εⱼ@ = L[i]` covers by this same lemma, and the rewrite
  `εⱼ := p[i]` puts the cover at the position. The rebasing is of the root εⱼ only: a
  `Same(q)` with `q` a model path is unrelated to position i and keeps its own row.
- **`let`**: the bound value is in `γ(⟦e₁⟧)` by induction, so the environment stays correct.
- **Calls** (§4.2). Let `S = ⟦body⟧(∅, { xᵢ ↦ Same(πᵢ) })`. By the claim applied to the body with
  `πᵢ` bound to the actual argument `Vᵢ`, the result is in `γ(S)` read with `πᵢ@ = Vᵢ`. The
  **substitution lemma**: for an argument `aᵢ` with `Vᵢ ∈ γ(aᵢ)`, `γ(S)[πᵢ := Vᵢ] ⊆
  γ(inst(S, [aᵢ]))` — by induction on `S`, since `proj` is `γ`-correct, a fact `tag(πᵢ.s) = C`
  that holds of `Vᵢ` is a fact `tag(q.s) = C` that holds of `M` when `Vᵢ = M@q`, is decided by
  the shape when `proj(aᵢ, s)` is a `Con`, and is dropped (every alternative kept) otherwise,
  and an application node reduces to the callee's value by this same claim or to `Fresh`. The
  k- and D-cuts replace a sub-term by `Fresh`, which only enlarges `γ`.
- **Core rows.** Each row is a restatement of a documented guarantee of `core/List` or
  `backend.md` §4: `map` returns `xs` itself when every result is `===` its element, so a
  callback that is identity on every alternative gives `Same(p)`; otherwise the result has `xs`'s
  length and `L'[i] === L[i]` wherever `f` returned its element, which is `Lst(p, kept, *, …)`;
  `filter`'s result is a subsequence of `===` elements, which is `removeSome`; and so on down
  the table. A row's fixture (§3.7) is what makes the guarantee a tested one.
- **Static dispatch**: a method call is the call the dispatch table resolved it to; the backend
  emits exactly that call (`checker-v2.md` §13), so the summary of that function is the right
  one.
- **`Fresh`**: `γ(Fresh)` is everything.

**`diff` is correct.** *If `v ∈ γ(a)` and `Γ` holds of `M`, then every path `q` at or below `p`
that is changed between `M` and a model with `v` at `p` is covered by `diff(a, p, Γ)` in the
sense of §1.3.* By induction on `a`: `Same(p)` changes nothing; `Same(q ≠ p)`, `Lit`, `Fresh`,
`Fun` cover `p` and everything below with `value p`; `Rec(p, fs)` changes `p` itself (a new
object: `node p`) and, below it, only paths through named fields (unnamed ones are `===` by the
record lemma), each covered by induction at `p.f`; `Con(C, parts)` under `tag(p) = C` changes
`p` (`node`) and below it only through `C#i`, each covered at `p.C#i` — and here the fact is
what makes `p.C#i` *defined* in both models, so that a changed path below `p` is one through
`C#i` and not an undefined one; without the fact, `value p` covers everything; `Tup` likewise;
`Lst` by its tag's promise; `Alt` by the alternative that holds. The prefix closure adds `node`
at the ancestors, which a new object at `p` indeed rebuilds (a spread per level), and the k-cut
replaces a cover by a wider one. The first row needs `γ(Same(q))` to be the **singleton**
`{ M@p }`, which is why it asks for `q = p` on uncut paths with index symbols equal by §2.3 and
no `[*]`/`[?]` step: `γ(Same(p[*]))` is the set of all elements, and `γ(Same(p[κ]))` with κ
another instruction may be another element (*amended 2026-10-08, A5*).

**Conflict is correct** (*amended 2026-10-08, A3–A4*). *If a hole's anchored read `r` sees a
different value — some path `q` with `q = r`, `q ⊑ r` or `r ⊑ q` on concrete positions is
changed — then `r` conflicts with `W` by §2.5.* The changed `q` is covered: a `value` write `w ⊑
q` or `node q ∈ W`. On concrete positions, `w`, `q` and `r` are related by exact prefix with
every list step a concrete index; a syntactic step of `w` or `r` that stands for that index —
a literal, an expression, `[*]` — may coincide with any other step standing for the same index
unless the two are distinct literals, which cannot both stand for one index. So `w ⊑ q` and
(`q ⊑ r` or `r ⊑ q`) give `w ⊑̃ r` or `r ⊑̃ w`, and `node q` with `q = r` gives a `node` write
`w` with `w ⊑̃ r` and `|w| = |r|`. A `node` write at a proper prefix of `r` is excluded on
purpose: it says the object there is new, and nothing about `r`'s own slot, whose value is the
old one unless some deeper write covers it — and that deeper write is in `W` by the clause
above.

### 5.3 The fixpoint is sound

Kleene iteration from ⊥ over monotone transfer functions in a lattice of finite height reaches
the **least fixpoint** in finitely many rounds (Cousot & Cousot 1977, §11), and the least
fixpoint over-approximates every concrete execution: an execution that returns after `n`
unfoldings of the recursion is covered by the `n`-th iterate, which the fixpoint is above. The
cap at `I` rounds replaces the iterate by `Fresh`, the top, which is above the fixpoint; so the
capped result is sound too, and only coarse. Summaries of different components are computed in
callee-first order, so a callee's summary is final — a fixpoint or `Fresh` — before any caller
reads it, and the caller's correctness follows from the call case of §5.2.

### 5.4 What the analysis assumes about the runtime

Each of these is a requirement on the emitter, `core/` and the platforms, not on the analysis;
where it is already promised the promise is cited, and where it is not it is flagged.

1. **No mutation visible to beni code.** A value, once built, is never changed in place by
   anything a beni program can observe; `M@p` means the same object before and after `update`.
   `language.md` §6 (*What an optimiser may assume*: every expression is pure). The one in-place
   write the backend makes, `checker-v2.md` §30's literal a `Js` call writes, is in `core/`'s
   own siblings and never on a model value. **Requirement**: it stays so — an in-place list
   write (`core/List`'s loops write their own arrays, `backend.md` §4) never touches a list a
   program still holds.
2. **An untouched field keeps its identity.** `language.md` §11.12 and §6.3, for record update
   and every value not rebuilt; `backend.md` §4's identity list for lists; `--release`'s field
   renaming and integer tags (`backend.md` §9, item 4) change names, not identity. **Pinned** by
   `backend.md` §15.8's fixtures in both builds. The analysis adds no requirement here; it adds
   a *consumer* of the promise beside the renderer, and §12 asks that `backend.md` §9 name it.
3. **`foreign` may return a fresh or a shared value**, and the analysis assumes nothing: it is
   `Fresh` without a row (§3.3), and a row is a documented guarantee with a fixture. The
   `Debug.log` row — the sibling returns its argument itself — is **not written anywhere
   today** as a guarantee; this document makes it one (a `run/` fixture, §8.3).
4. **A list view is `same` as the tail it views** (`backend.md` §4, `language.md` §11.12's 2026-
   10-01 amendment), and the renderer compares with `same` wherever a list can appear
   (`backend.md` §15.5). The `[ x, …rest ]` pattern rule (§3.2) relies on it only to be
   *coarse* (`removeSome`, never `Same`), so nothing here depends on `same`'s exact cases.
5. **The emitter keeps the tag the analysis knows.** A `Con` re-applied in a `case` arm is
   emitted as a constructor of that tag (integer or string); a `case` on a tag is a comparison
   on that tag (`backend.md` §7). The analysis never assumes which representation.
6. **A message's tags are readable at run time** along the key's steps (§4.4), one property read
   per step, by the handler. `backend.md` §7's decision trees already do this.

Nothing is assumed about evaluation order, about `Debug` or about the result of a comparison,
because the claim is about identity only.

## 6. Termination and cost

### 6.1 Finite height, and the caps

Every lattice the analysis climbs is finite for a fixed program: write sets (§2.4), abstract
values cut at depth k with `Alt` width ≤ A (§3.1), and summaries, which are abstract values.
So every fixpoint terminates without a widening operator in the technical sense (Cousot &
Cousot 1977 §11, *widening*): the caps **are** the widening, applied unconditionally rather than
when a chain looks long, and each yields the top of its lattice — `Fresh`, hence `value` where
it lands — never a diagnostic. The caps, each an *open choice O2* with a recommended value:

| cap | bounds | at the cap |
|---|---|---|
| k = 8 | path and value depth, `Alt` levels included | `value` at the k-prefix; `Fresh` for a deeper term; reads cut likewise |
| A = 16 | alternatives in one **plain** `Alt` (a keyed `Alt` is bounded by its type, §3.1) | `Fresh(⋃ deps)` |
| D = 8 | nested instantiation depth | the application is `Fresh` |
| I = 4 | rounds of a recursive component | every summary of the component is `Fresh` |
| S = 4 096 | DAG nodes in **any** term: a summary, a key's result, a lambda's value at a call | the term is `Fresh` |
| W = 2²⁰ | **work**: node visits by `⟦·⟧`, `inst` and `diff` (memo hits included) for one summary or one key | the summary is `Fresh`; the key is `value ρ` |
| L = 256 | leaves of a program's key tree | splitting stops; keys share their parent's set |

*Amended 2026-10-08, C1–C2.* The width cap alone bounded nothing: a chain of `if`s nests `Alt`s
without widening any, and `diff` over nested `Alt`s under growing Γ can visit a shared DAG
exponentially often. **W caps the work itself**, counted per summary and per key, and S counts
every term; both are the real bound, and the others are the shapes that reach it first.

**What W counts, and what it does not** (*amended 2026-10-08, N6*). W counts **node visits**
of `⟦·⟧`, `inst` and `diff`, memo hits included. It does not count what a visit does beside
visiting: a join of two write sets costs their sizes (each at most S paths, since a set comes
from a term of at most S nodes, so a join is ≤ 2S per visit); interning a Γ costs its size
(≤ the depth of nested `case`s, ≤ k levels of facts); hash-consing a node costs one hash of its
children. So the pass's work is bounded by `(functions + L) · W · O(S)` elementary steps in the
worst case — bounded, **not** fast against `fast-compiler.md` §2's budgets, which is why the
caps are sized so that no program measured reaches them and why the dump marks the ones that
do. **The fixture that reaches W** (§8.3) cannot do so under the test budget with W = 2²⁰ and
CLAUDE.md rule 10 forbids raising the budget: it runs under a **hidden, test-only
`--writes-work=<n>`** that lowers W for that run, as the release corpus runs under
`--allow-debug`, and the golden shows the key marked `(cap W)` as `value ρ`. And
width was the wrong thing to cap for a `case` on a message: a page `update` with seventeen
constructors would have made every one of its keys `Fresh` — all its messages, not one — which
is why a `case` on a path is a keyed `Alt`, as wide as its type and no wider, and selected whole
by a key. (Conduit's `ArticlePage` has seventeen; under the first draft's rule its seventeen
keys would all have been `value ρ.Article#0`.) Like the cap of 64 inferred constraints
(`static-dispatch-spike.md` §10.11), each cap bounds a blow-up a program can reach by accident
and is lifted by writing the program another way, which nobody is asked to do: the cost of a cap
is a coarser handler for the summary or key it fired in — a `Fresh` summary coarsens every key
through it, which is the cost of the shape, not of one message — and `compile-away.md` §2's rule
stands. The dump marks a cap that fired (§8.1) so that a coarse result has a stated cause.

### 6.2 Cost on real programs

*Amended 2026-10-08, C3–C4.* **The bound**: the work of the pass is at most
`(functions + keys) · W` node visits plus one walk of `view` and the markup helpers it reaches,
because every summary and every key stops at W. **Within that bound**, a function's summary is
one walk of its body plus the instantiations it makes; an instantiation costs the callee's
summary size (≤ S) and, for a lambda argument, the lambda body's analysis at that site — so
higher-order fan-out is real: `twice f x = f (f x)` nested D levels is bᴰ lambda analyses, which
W, not D, is what stops. A key is **one walk of `update`'s body** under its facts, with the
arms its facts contradict skipped; code shared before the split — a `let` chain, helpers called
before `case msg of` — is walked **once per key**, so the sum over keys is up to `L` walks of
that shared part, not one. The claim "linear in the program" is therefore withdrawn: the pass is
**linear in the program on inputs that hit no cap** (every body walked once, each call site
instantiating a bounded summary, each key skipping all but its arms), and bounded by the caps
on every input. Conduit: 3 387 lines, about 100 keys, a handful of summaries wider than a
screen, no cap expected to fire; the estimate is a few milliseconds in ReleaseFast, which is
within the noise of its 150 ms check (research 62 §1.3), and the figure is reported, not
assumed. The pass is budgeted with the checker: the 250k LOC/s target
of `fast-compiler.md` §2 is for checking, the whole of `update`'s and `view`'s cost here is
another walk of their bodies, and the pass reports its own time under `--self-profile`
(`writes` beside `check` and `emit_module`), so a regression is a number. A program with no
program record costs one scan of the declarations and nothing else.

### 6.3 Incrementality

The pass is whole-program and runs on every build that emits for a markup platform; a summary of
a `pub` function depends only on its module and its callees' interfaces, so it is publishable in
the interface (`checker-v2.md` §14) and cacheable with it (M4). This slice does not publish it:
until `--self-profile` shows the pass costing more than a rebuild's budget allows
(`fast-compiler.md` §2, 15 ms warm), the simplest correct thing is to recompute. `core/`'s
summaries — the ones with rows are rows, the rest are computed from bodies — are computed once
per process, which is the same arrangement `core`'s check has (CLAUDE.md rule 10's finding).

## 7. Determinism

The result is a function of the program's text and nothing else (CLAUDE.md rule 5;
`fast-compiler.md` §10):

- **Paths** are interned in a table filled in module-index order (`fast-compiler.md` §10's file
  index), then declaration order, then instruction order within a declaration; a path's id
  decides every sort. Two programs with the same text in the same package layout get the same
  ids wherever the project lives.
- **Write sets** are kept sorted by path id; `Alt`s keep their alternatives in the order the
  arms are written; a join of two sets is a merge.
- **Call-graph components** are found by one deterministic SCC algorithm over the declaration
  order, and the callee-first order breaks ties by lowest module index then declaration index.
- **Keys** are discovered in the order `update`'s arms are written, and the key tree is printed
  in that order; a cap that stops splitting stops at the same leaf on every run.
- **Threads.** Summaries are computed per module on the checker's DAG schedule, callee modules
  first; within a module single-threaded; the program-level pass (keys, `update`, `view`) runs
  once, on one thread, after every module's summaries exist. No step reads a result another
  thread may still be writing, and no table is appended to concurrently.
- **The test**: the `--jobs=1` versus `--jobs=8` determinism scenario (`checker-v2.md` §17) gains
  the `writes` dump beside the dispatch dump, byte-compared, and `build_test.zig`'s
  *byte-identical wherever the project lives* covers the pass once R3 emits from it.

## 8. The read-only pass and the gate

### 8.1 `beni dump --stage=writes`

The pass ships first as a dump stage, `writes`, beside `types`, `interface` and `dispatch`: it
runs the check phases and the pass, and prints the result as text. The name is the thing it
prints; `write-sets` would read as two words and `effects` is taken. The format, one program
after another in module-index order, each line one fact, so that a golden diff names the fact
that moved:

```
program Main.main : Tea.application
  model Main.Model
  init
    literal <none>
  key ChangedUrl                                  *          value ρ
  key ClickedLink                                 exact      ∅
  key GotHomeMsg · ClickedTag                     exact      node ρ; node ρ.Home#0; value ρ.Home#0.feedTab; value ρ.Home#0.feedPage
  key GotHomeMsg · GotFeedMsg · CompletedFavorite · Ok
                                                  structural node ρ; node ρ.Home#0; node ρ.Home#0.feed; node ρ.Home#0.feed.Loaded#0; node ρ.Home#0.feed.Loaded#0.Model#0; node ρ.Home#0.feed.Loaded#0.Model#0.articles ⟨kept⟩; value ρ.Home#0.feed.Loaded#0.Model#0.articles[*]
  key GotEditorMsg · EnteredTitle                 exact      node ρ; node ρ.Editor#1; node ρ.Editor#1.status; value ρ.Editor#1.status.Saving#1.title; value ρ.Editor#1.status.Editing#2.title; value ρ.Editor#1.status.EditingNew#1.title; value ρ.Editor#1.status.Creating#0.title
  key GotProfileMsg · ClickedFollow               exact      ∅
  keys 101: bounded 100 (99%), exact 83, indexed 9, structural 8, * 1; capped 0
  hole Main.beni:52:17                            dynamic    reads ρ
  hole Home.beni:88:21                            static     reads ρ.Home#0.session.LoggedIn#1.username
  hole Page.beni:40:13                            literal    reads ∅
  holes 507: static 9, literal 264, static-key 2, dynamic 232
```

- **`key`**: the message key as constructor names joined by ` · ` (`#0` is left out when the
  constructor has one argument and printed otherwise, `Profile#1`), its **class**, and its write
  set — `node`/`value` writes sorted by path, a list write with its tag in `⟨⟩`, an index
  symbol in its source spelling or `?`. A key a cap coarsened carries ` (cap k)`, ` (cap A)`, …
  after its class.
- **Class**, research 61 §2.2's four, defined on the set: **`*`** when `value ρ` is in it;
  **structural** when some list write has tag `kept` with `[*]`, or `removeSome` or `permute`;
  **indexed** when some list write has any other tag or a `[κ]` with κ an expression; **exact**
  otherwise. (**Bounded** is every class but `*`.) The classes are a reading for people and for
  the gate; consumers read the set.
- **`keys`**: the count of leaf keys, and per class; `capped` is how many a cap coarsened, and
  a `cap W` or `cap S` that fired in a summary is printed once under a `summary <name> (cap …)`
  line after the keys, so a coarse key can be traced to the helper that caused it.
- **`program <unrecognised>`** (§1.1, B3): printed for a `main` of a `Program` type the pass
  could not trace to a record literal of the required shape, with one line `key * * value ρ`
  and every hole `dynamic`; a build for a markup platform with no `main` at all prints nothing.
- **`init`**: `literal` followed by the paths `literal(p)` holds at, or `<none>`.
- **`hole`**: the markup hole's position (module, line, column of its `{`), its class —
  **static** (no key's set conflicts with any anchored read, §2.5), **literal** (static, and
  every read path is `literal` under `init`, an empty read set included), **static-key** (a
  row hole of a keyed `For` reading only the key field, research 61 §2.3) or **dynamic** — and
  its anchored read paths. An event binding is not a hole and is not printed.
- **`holes`**: the counts, as research 61 and 62 report them.

The dump is a corpus golden: `tests/corpus/writes/<Name>.beni` with `<Name>.writes`, run by
`dump --stage=writes` like `dispatch/` (`tests/corpus/README.md`'s table gains the row), and a
project form for several modules (`writes/<Dir>/` with `_expected.writes`), which is what
Conduit's gate fixture is. A golden that moves is a finding, as `emit/`'s are.

### 8.2 The gate

The owner's condition, restated precisely so that the number is one the tool prints:

> On `examples/conduit/src` (`_expected.sources`, with Conduit's granted budget), **at least two
> thirds of the program's leaf keys are bounded**: `keys N: bounded B` with `3·B ≥ 2·N`.

**Dispatchable** means a leaf key of §4.4 — what the R4 handler table would have an entry for.
**Bounded** means the class is not `*`: no `value` write at ρ. This is research 62 §2's root-write
reading made the definition: a `value` write at the root reaches every group, so it is today's
path and counts as unbounded; a `node` write at ρ (every page message has one) reaches only the
holes that read the model whole, and counts as bounded. Research 62 counted by hand that the
analysis of §3–§4 makes 65 of 65 page keys bounded and all but `ChangedUrl` of Main's; this
document expects **about 100 of 101**, and the gate is cleared with room or the analysis has a
defect the dump shows.

*Re-checked 2026-10-08 under the amended rules (A1–A6, B1–B7, C1–C5).* **The expected figure
does not change.** A1: Conduit's fallthrough `( _, _ ) → ( model, Cmd.none )` is now analysed
for every key and writes nothing. A2: every refutable sub-pattern in Conduit's updates
(`Loaded ( Editing "", _ )`, `Loaded ( Sending text, list )`) is followed by an arm that returns
the scrutinee or the model itself, so the lost negations cost nothing; `CompletedPostComment ·
Err` is still `node ρ.…comments.Loaded#0` with `value` at the `CommentText` only, from the
arm's positive facts. A5: `replaceArticle` was never identity, so `Feed`'s map stays
`value …articles[*]`. C2 is the one correction that moves a number, the other way: under the
first draft's width cap `ArticlePage`'s seventeen constructors would have made its summary
`Fresh` and its seventeen keys `value ρ.Article#0` — bounded, so the ratio stood, but coarse —
and the keyed `Alt` keeps them exact. So: about 100 of 101 bounded, one `*` (`ChangedUrl`), and
the article page's keys as research 62's Appendix A lists them.

The gate is run by the tool, not by hand, as a corpus case: `tests/corpus/writes/Conduit/`
whose golden is the whole dump and whose harness check is the `keys` line's ratio — a second
assertion on the same output, so that a regression in precision fails the gates even when the
golden is re-blessed. Research 61's corpus (`tests/corpus/browser/tea/`, the table app under
`bench/ui/apps/beni/`, TodoMVC) is run the same way, and its results must be **no coarser** than
research 61's Appendix A on every constructor: a constructor the prototype classed exact that
this pass classes indexed is a defect in the pass, since the prototype's rules are a strict
subset of these.

**If the gate fails**, `compile-away.md` §4 V1 applies: R4 and R5 shrink to R2, R3 and R5's
append and clear, and the pass stays as what R3 needs. Nothing else in this document changes.

### 8.3 Fixtures the pass needs before any consumer

Every rule of §3.3 has a `writes/` fixture that reaches it and whose golden shows the write set
a person would state: the identity case; a record update at depth; a same-variant rebuild under
`case`, under the single-constructor rule and under the one-constructor-left rule; a
constructor whose tag is not known (`value`); `other → other`; a constructor passed as a value
and through a placeholder; a recursive helper that lands (`bumpTimes`) and one that does not
(`buildFrom`); every core row, with a `run/` twin pinning the identity it rests on (`List.map`
identity, `filter` keeping every element, `update` out of range, `Debug.log` returning its
argument — the last is new); an index guard and a residue guard; a key tree three deep; each
cap, at the smallest input that reaches it (one test per cap, `write-tests`' rule); `init`
literal and not. The determinism scenario of §7. None of these is a matrix.

*Added 2026-10-08, from the adversarial review's counterexamples (E). Each is a `writes/`
golden the read-only pass must pass before any consumer reads its result:*

1. **A1** — `( GotHomeMsg sub, Home home ) → …; ( _, _ ) → ( { model | warning = "stale" },
   Cmd.none )`. Golden: every `GotHomeMsg · X` key holds `value ρ.warning`.
2. **A2** — `case model.status of Loaded (Just x) → …; _ → { model | status = Failed e }`.
   Golden: `value ρ.status`, not `node ρ.status; … Failed#0`.
3. **A3/A4** — the table app's `SwapRows` and a `Set id v` key, with a positional `For` row hole
   reading `row.label` and a hole reading `List.head model.xs`. Golden: the row hole is
   `dynamic` under `SwapRows`, the `head` hole is `dynamic` under `Set`.
4. **A5** — `Fill → case List.last model.todos of Just t → { model | todos = List.map
   model.todos (λ_ → t) }`. Golden: `value ρ.todos[*]`.
5. **A6** — `view model = label = if model.on then "On" else "Off"; <button>{label}</button>`.
   Golden: `hole … dynamic reads ρ.on` (with a `Toggle` key writing `ρ.on`), and `static
   reads ρ.on` — never `literal` — when nothing writes it.
6. **B3** — `Tea.element { …, update = withLogging update }` and a program record a helper
   returns. Golden: `program <unrecognised>`, `key * * value ρ`, every hole `dynamic`.
7. **B2** — a helper `bump r = { r | n = r.n + 1 }` over a model `{ m, n }`, called on
   `{ model | m = 1 }` and on a `Fresh` value. Golden (*aligned 2026-10-08, N7, with §4.2 and
   §3.4's full-record row*): `node ρ; value ρ.m; value ρ.n` for both — the first composes the
   two updates, the second is a record of two `Fresh` fields placed at ρ.
12. **N1** — `f s m = case s of Loaded (Just _) → { m | a = 1 }; _ → { m | b = 2 }` called as
    `f (Loaded Nothing) model`. Golden: `node ρ; value ρ.b` — not `value ρ.a`.
13. **N3** — a message type of three constructors whose `update` names two and ends in `_ →
    { model | seen = True }`. Golden: three leaves, `A`, `B` and `_`, the last `value ρ.seen`;
    and under L, a parent whose set holds the default's write.
14. **N2** — TodoMVC's `Toggle` as §10.5 prints it. Golden: `node ρ.todos[*]; value
    ρ.todos[*].completed`, with the row's `title` hole `static` under that key alone; and `Fill`
    (item 4) still `value ρ.todos[*]`.
15. **N6** — the C1 chain under the hidden `--writes-work=4096`. Golden: the key `(cap W)` as
    `value ρ`; the same program without the flag is item 9's golden.
8. **B7** — a key that appends on one arm and writes `[*].f` on another. Golden: both
   `value ρ.xs ⟨append⟩` and `value ρ.xs[*].f` present.
9. **C1** — thirty `let aₙ = if cₙ then aₙ₋₁ else aₙ₋₁'` lines in a helper `update` calls,
   as a **`test-pending-perf` scenario** until the pass exists and a `test-perf` one after:
   the pass must finish within the budget and, hash-consed, within W; the golden is the key's
   set, which is `value` at the one field written, not `Fresh`.
10. **C2** — a page `update` of seventeen constructors behind `GotPageMsg`. Golden: seventeen
    exact keys, no `cap A`.
11. **C5** — a mutually recursive pair that lands (`stepA`/`stepB` each writing one field).
    Golden: `value` at the two fields, no `cap I`.

## 9. What the consumers may do, and what stays at run time

### 9.1 R3 — values that never change

A hole whose anchored reads (§3.6) conflict with no key's write set (§2.5) is **static**: R3
writes it at mount, with no group field, no test and no comparison. A static hole is **baked**
into the template's HTML, with no code at all, only when (*amended 2026-10-08, B5*) **its
expression is exactly a model path** (`tree.pathOf`, `boundary.md` §9.4.6: a local read
through field and tuple accesses and nothing more, anchored to `p`) **and `init` gives `p` a
plain string literal** — the one value the template can hold verbatim with no evaluator between
the source and the page — **and the hole stands alone in its text position**. *Plain* (*amended
2026-10-08, N4*): non-empty, with no character the HTML serialiser would escape or the parser
would alter — none of `&`, `<`, `>`, `"`, `'`, no control character or NUL, and no leading
newline — so that the bytes written are the bytes the page shows. *Alone*: the hole's neighbours
in its parent are elements or nothing, never a text run or another hole, and its parent is not
`pre` or `textarea`; a baked string makes exactly one text node where the hole's slot was, so
the template's walk is unchanged. A hole with an empty read set whose expression is a plain
string literal, standing alone, is baked likewise. Every other static hole — empty, escaped,
adjacent, in a `pre` — is mounted from its expression, which `backend.md` §15.3 already
specifies and which is correct for every string. Nothing else is: `String.fromInt (model.count + 1)`, a `Float`, a `Bool`, an
`if` over literals (A6's `label`) would need a compile-time evaluator bit-exact with the
runtime (`-0`, `NaN`, `Int` past 2⁵³, float printing), and this slice names none (*open choice
O8*: widen to integer literals once the backend's printer is specified as the evaluator). A
static hole that is not baked is written once at mount from its expression, which costs the
code and nothing per render. R3 must still: write every other hole as today; treat a
hole inside a `For` row by the row's own rules (`backend.md` §15.5 — a row's item is an input,
not a path, and `static-key` is the per-row-instance reading of research 61 §2.3); and keep
`backend.md` §15.4's restate of slots, since a static hole may hold markup that is live.

### 9.2 R4 — per-key handlers

For each leaf key κ, R4 emits a handler that runs `update`'s arm for κ and **marks** the groups
whose anchored read paths conflict with `writes(κ)`; the flush runs marked groups, which
compare and write as today. A key of class `*` marks every group: today's path, with the
dispatch cost of the key's tag reads added and nothing else. R4 must still, at run time:
**compare** — a marked group tests its paths by `===` before writing, because the analysis said
"possibly" (research 58 §3.3's lesson from Svelte; `compile-away.md` §2); dispatch on the
message's tags along the key; handle a message whose key has no entry (a cap-coarsened key is
its parent's; a tag the tree does not know is a defect, not a fallback, because the key tree
covers the message type — every constructor at every split is under a named child or the
split's default child, §4.4); and keep every guarantee `compile-away.md` §2 lists. What R4 may not
do: skip the comparison for a `node` write (an object was rebuilt; a group reading it whole must
run), or decide "unchanged" from anything but a comparison.

A `node` write at ρ with nothing else (`Feed.ClickedFavorite`: `Model model` rebuilt
unchanged) marks only the groups that read ρ whole, which in Conduit is Main's page `case`: one
comparison of the block's kind, then a patch of the same kind, which is §15.4's "patch when `t`
is the same kind".

### 9.3 R5 — list edits

R5 reads the edit tags (§2.3) and the index symbols: `append`, `prepend`, `clear`, `set κ`,
`update κ` with the element's own write set, `swap`, `removeSome` (a one-pass merge),
`permute`, `kept` with `[*]` and a sub-write (the identity-preserving `map` plus slice C's
diff, research 58 §5(a)). It must still verify the edit against the lists at run time where the
tag's promise is conditional (`update` out of range returns `xs`: the handler compares the list
first, as a group would), and fall back to the keyed pass on `replaced`.

### 9.4 M3 — in-place update

`writes(κ)` is also the set of paths an in-place update of the top-level model would write; W4
(whether the model is held anywhere else) is a separate analysis `compile-away.md` M3 specifies
later, and nothing here assumes it.

## 10. Worked examples

Each example states the source, the abstract value of the result, and the write set, in the
dump's spelling.

### 10.1 Conduit's `Main.update` — the page union

```
( GotHomeMsg subMsg, Home home ) → updateWith Home GotHomeMsg (Home.update subMsg home)
( _, _ )                         → ( model, Cmd.none )
```

Key `GotHomeMsg · ClickedTag`. The scrutinee is `Tup([Same(μ), Same(ρ)])`; the arm's patterns
give `tag(μ) = GotHomeMsg`, `subMsg ↦ Same(μ.GotHomeMsg#0)`, `tag(ρ) = Home`, `home ↦
Same(ρ.Home#0)`. `Home.update subMsg home` instantiates `Home.update`'s summary with `π₁ =
Same(μ.GotHomeMsg#0)`, which splits the key at `ClickedTag`, and `π₂ = Same(ρ.Home#0)`; the
`ClickedTag` arm is `Tup([Rec(ρ.Home#0, { feedTab ↦ Con(TagFeed, [Same(μ…ClickedTag#0)]),
feedPage ↦ Lit 1 }), Fresh])`. `updateWith`'s summary is `Tup([App(Same(π₁), [proj(π₃, .0)]),
Fresh])`; with `π₁ = Fun(Home)` the application reduces to `Con(Home, [Rec(ρ.Home#0, …)])`.
The last arm is `Tup([Same(ρ), …])`. Result: `Alt([ (tag(ρ)=Home, Con(Home, [Rec(…)])),
(tag(ρ)≠Home, Same(ρ)) ])`. `diff` at ρ: under `tag(ρ) = Home`, `node ρ`, then `Rec` at
`ρ.Home#0`: `node ρ.Home#0`, `value ρ.Home#0.feedTab`, `value ρ.Home#0.feedPage`; under the
other alternative, nothing.

```
key GotHomeMsg · ClickedTag    exact    node ρ; node ρ.Home#0; value ρ.Home#0.feedTab; value ρ.Home#0.feedPage
```

Research 62 §3.1 classed this `root`; it is now bounded, and the Settings page's holes, which
read under `ρ.Settings#0`, do not conflict with it (§2.5: a `node` write at a proper prefix).
`ChangedUrl → changeRouteTo …` is `Alt` over routes of `Con(NotFound, …)`, `Same(ρ)` and
`Con(Editor, [Lit Nothing, Fresh])`, … with no tag fact at ρ, so `value ρ`: the one `*` key,
which is genuinely a new page.

### 10.2 `Editor.update` — a same-variant rebuild

```
EnteredTitle title → updateForm (λform → { form | title = title }) model
```

Key `GotEditorMsg · EnteredTitle`, reached through `( GotEditorMsg subMsg, Editor slug editor )
→ updateWith (Editor slug _) GotEditorMsg (Editor.update subMsg editor)`: `editor ↦
Same(ρ.Editor#1)`, `slug ↦ Same(ρ.Editor#0)`, and the placeholder is `Fun(λx → Editor slug x)`.
`updateForm`'s summary (§4.1) instantiated with `π₁ = Fun(λform → …)`, `π₂ = Same(ρ.Editor#1)`:
each `Saving`/`Editing`/`EditingNew`/`Creating` alternative becomes, for instance,
`(tag(ρ.Editor#1.status) = Editing, Rec(ρ.Editor#1, { status ↦ Con(Editing,
[Same(….Editing#0), Same(….Editing#1), Rec(….Editing#2, { title ↦ Same(μ….EnteredTitle#0) })])
}))`, and the three loading alternatives are `Same(ρ.Editor#1)`. Through `Con(Editor,
[Same(ρ.Editor#0), …])` under `tag(ρ) = Editor`: `node ρ`, `node ρ.Editor#1`, `node
ρ.Editor#1.status`, and under each form-holding alternative `node` at the form and `value` at
its `title`:

```
key GotEditorMsg · EnteredTitle    exact    node ρ; node ρ.Editor#1; node ρ.Editor#1.status; node ρ.Editor#1.status.Saving#1; value ρ.Editor#1.status.Saving#1.title; node ρ.Editor#1.status.Editing#2; value ρ.Editor#1.status.Editing#2.title; node ρ.Editor#1.status.EditingNew#1; value ρ.Editor#1.status.EditingNew#1.title; node ρ.Editor#1.status.Creating#0; value ρ.Editor#1.status.Creating#0.title
```

A hole showing `form.body` under `Editing` reads `ρ.Editor#1.status.Editing#2.body`, which
conflicts with nothing here: typing in the title field no longer compares the body. Research 62
§5 listed this as "exact at `status`", the whole editor. `ClickedSave`, by contrast, builds
`Saving slug form` under `tag = Editing` — another tag — and is `value ρ.Editor#1.status`, which
is right: the page's shape changes.

### 10.3 `Feed` — the opaque wrapper

`update msg (Model model)` binds `model ↦ Same(π₂.Model#0)` by the single-constructor rule
with no `case` at all; `ClickedDismissErrors` returns `Con(Model, [Rec(π₂.Model#0, { errors ↦
Lst(none, clear) })])`, which at a path `q` (`ρ.Home#0.feed.Loaded#0`, under `GotHomeMsg ·
GotFeedMsg` and `Home.update`'s `Loaded feed` arm) is `node q`, `node q.Model#0`, `value
q.Model#0.errors ⟨clear⟩`. `CompletedFavorite · Ok` is `List.map model.articles (replaceArticle
article _)`: the callback's summary is `Alt([ (…, Same(π₁)), (…, Same(ε)) ])` — the `if` on
`new.slug == old.slug` refines no tag, so both alternatives stay; the callback is not identity,
and the row gives `Lst(q.Model#0.articles, kept, *, Alt([Same(μ…Ok#0), Same(ε)]))`: `node … 
articles ⟨kept⟩`, `value …articles[*]`. Research 62 §5 called this "the map-by-id idiom,
hidden"; it is now the structural write R5's second item needs. `ClickedFavorite` returns
`Con(Model, [Same(π₂.Model#0)])`: `node q`, `node q.Model#0`, and no `value` — "nothing", with
the wrapper rebuilt, which marks only a hole that reads the feed whole.

### 10.4 The table app — `indexedMap` with an index guard

```
SwapRows → { model | rows = swapRows model.rows }
swapRows rows = case ( at rows 1, at rows 998 ) of
    ( Just a, Just b ) → List.indexedMap rows λi row → if i == 1 then b else if i == 998 then a else row
    _ → rows
```

`at rows 1` is `List.get`'s row: `Alt([ Con(Just, [Same(π₁[1])]), Lit Nothing ])`; the tuple
pattern binds `a ↦ Same(π₁[1])`, `b ↦ Same(π₁[998])` in the first arm. The callback's result
under the index facts: `ι = 1 → Same(π₁[998])`; `ι = 998 → Same(π₁[1])`; otherwise `Same(ε)`.
Only alternatives that fix ι differ from the element, so the `indexedMap` row gives
`Lst(π₁, kept, [1, 998], …)`; the second arm is `Same(π₁)`. At `ρ.rows`:

```
key SwapRows    indexed    node ρ; node ρ.rows ⟨kept⟩; value ρ.rows[1]; value ρ.rows[998]
```

— the exact edit research 60 §5.4 asked for, which R5 turns into two row patches. For R4 the
two `value` writes conflict with a row's `ρ.rows[*].label` by may-coincidence (§2.5: `[1]` and
`[*]`), so a positional `For`'s rows are marked and rows 1 and 998 repaint; a keyed `For`'s
move with their items. `Update`'s guard is `Int.mod i 10 == 0`: no index fact, so `[*]` with
the element's write `{ label }`:

```
key Update    structural    node ρ; node ρ.rows ⟨kept⟩; node ρ.rows[*]; value ρ.rows[*].label
```

which is what it is — the rows' identity is kept and a tenth of their labels change; a row's
`label` hole compares, the `class` hole (reading `ρ.selected` and the row's id) does not run.
The domain does not capture residues, and this document recommends against adding them: the
compare per row is the floor research 58 §4 (R1) accepts, and a residue step would buy the one
benchmark operation and nothing in an application.

### 10.5 TodoMVC — `List.map` with an `if` on the id

```
Toggle id → changed model (List.map model.todos λt → if t.id == id then { t | completed = not t.completed } else t)
changed model todos = ( { model | todos = todos }, save todos )
```

The callback is `Alt([ Rec(ε, { completed ↦ Fresh }), Same(ε) ])` — the `if` is on a value,
not a tag, so no fact — not identity; the `map` row gives `Lst(ρ.todos, kept, *, …)`;
`changed`'s summary places it at `.todos`:

```
key Toggle    structural    node ρ; node ρ.todos ⟨kept⟩; node ρ.todos[*]; value ρ.todos[*].completed
```

The row's `title` hole does not run; its `completed` holes compare, one per row, until R5's
identity-preserving map and diff make it one per changed row. `Destroy id` is
`List.filter`'s row: `value ρ.todos ⟨removeSome⟩`, R5's third item. Both are what research 61
§4.2 counted by hand.

## 11. Prior art, and exactly what is taken from each

- **Abstract interpretation** — Cousot, P. & Cousot, R., *Abstract interpretation: a unified
  lattice model for static analysis of programs by construction or approximation of fixpoints*,
  POPL 1977. The frame of §3 and §5: a concrete semantics, an abstract domain with a
  concretisation, monotone transfer functions, and fixpoints by Kleene iteration whose
  termination comes from finite height or a widening. Taken whole; the caps of §6.1 are the
  widening, applied as the paper's §8 allows (any operator that bounds the chain is one).
- **Interprocedural summaries** — Sharir, M. & Pnueli, A., *Two approaches to interprocedural
  data flow analysis*, in Muchnick & Jones (eds.), *Program Flow Analysis*, 1981. The
  **functional approach**: a procedure's summary as a function from input abstract value to
  output, applied at each call; the alternative (call strings) is not used. §4.1–§4.2 are that
  approach with summaries as symbolic terms and application as substitution. **IFDS** — Reps,
  T., Horwitz, S. & Sagiv, M., *Precise interprocedural dataflow analysis via graph
  reachability*, POPL 1995 — is the same approach for distributive problems over finite sets;
  write sets with `node`/`value` kinds over interned paths are such a set, and §4.3's
  callee-first fixpoint is IFDS's exhaustive tabulation restricted to summaries. IFDS's
  call-site specific summary edges are what the per-call-site treatment of lambdas (§4.2)
  corresponds to.
- **k-limited access paths** — Jones, N. D. & Muchnick, S. S., *Flow analysis and optimization
  of LISP-like structures*, POPL 1979. The k-limit of §2.2 and its soundness argument (a
  truncated path stands for every extension) are theirs; the `node`/`value` distinction is not,
  and is what an immutable language with identity-preserving update adds.
- **Path sensitivity on variants** — the tag facts of §3.2 are the standard "refinement by
  pattern match" of typed functional languages, as in GHC's case-of-known-constructor and the
  occurrence typing of Tobin-Hochstadt & Felleisen (*Logical types for untyped languages*, ICFP
  2010), restricted to constructor tags on paths. Nothing beyond tags is tracked, by design.
- **The incremental lambda calculus** — Cai, Y., Giarrusso, P. G., Rendel, T. & Ostermann, K.,
  *A theory of changes for higher-order languages*, PLDI 2014. The write set is a *change
  description* in their sense — a value in a change structure over the model's type — and a
  function summary could be the function's *derivative*. This document does not take the
  derivative: because beni's values are immutable and update is identity-preserving, the
  *result as a term over the old model* carries the change for free (§3.4 reads it off), and a
  derivative would add the machinery for change composition the renderer never needs. What is
  taken is the discipline that the change of a composite is composed from the changes of its
  parts, and that `nil` changes (`Same`) must be first-class.
- **Svelte 3's `$$invalidate`** — the compiler injected an invalidation at every assignment to a
  component's variables and guarded each DOM write with a per-component dirty bitmask (research
  58 §3.3, from svelte.dev's own account). It was a write-set analysis, and it was **unsound in
  the presence of aliased mutation**: an assignment through an alias in another file
  (`obj.x = 1` in a helper) invalidated nothing, so the screen could be stale. The analysis here
  cannot have that hole: beni has no mutation (§5.4, item 1), so every change is a *construction*
  the analysis sees, and a call it cannot see through is `Fresh`, which marks rather than
  omits. The second difference is the one research 58 §3.3 draws: Svelte's mask *decided*
  "unchanged"; here the set decides "possibly changed" and a comparison decides the rest, so an
  analysis error can cost a comparison and never a wrong page.

## 12. Open choices for the owner

Each with a recommendation; none blocks the read-only pass, which can be built with the
recommended values and re-run under others.

- **O1 — k = 8**, counted from the program's model root, with reads anchored and cut the same
  way (§2.2). Recommended: 8. The alternative, slice B's 4, cuts Conduit's pages at their
  status variants and loses the same-variant precision this slice exists for.
- **O2 — the caps** A = 16 (plain `Alt`s only), D = 8, I = 4, S = 4 096 (every term),
  W = 2²⁰ (work per summary and per key), L = 256 (§6.1). Recommended as stated; each is a top,
  never an error, and the dump marks when one fires, so they can be moved on evidence. W is the
  one that bounds the pass; the others name the shapes that reach it. W counts node visits only
  (§6.1, N6): the bound it gives is `(functions + L) · W · O(S)` steps, which is a bound and
  not a speed, and the fixture that reaches it runs under a hidden test-only `--writes-work`,
  never a raised test budget.
- **O8 — what R3 may bake** (§9.1): only a hole that is exactly a model path whose `init` value
  is a string literal. Recommended as stated; widening to integer literals needs the backend's
  number printing named as the evaluator, and is a later amendment.
- **O3 — no positions in `Dict` or `Set`** (§2.6). Recommended: none now. Conduit and research
  61's corpus hold no dict in a model that a view reads by key; a `Dict` step (`{key}`) can be
  added later without renumbering anything.
- **O4 — where core's rows live** (§3.7): a table in the compiler, each row beside its cited
  guarantee and fixture, against an annotation in `core/`'s source. Recommended: the table.
  Rule 6 makes `core/` privileged, but a row is a claim *about* a sibling's JavaScript that the
  compiler relies on, and the compiler is where every such claim (the identity list, the
  `foreign` arity check) already lives.
- **O5 — keys by model variant as well as message.** `GotHomeMsg · X` writes nothing when the
  page is not `Home`; a handler keyed by `(message key, model tag)` could skip the marks. Not
  recommended now: the handler runs `update`'s arm and can test what ran (research 58 §4, R1),
  and the marks it would save are the ones a `node ρ` write makes, which are few.
- **O6 — the dump's name**, `writes` (§8.1). Recommended as is.
- **O7 — a requirement to name in `backend.md` §9**: that the analysis is a second consumer of
  `language.md` §11.12's identity promise, beside the renderer, so that a future pass that
  weighs breaking it sees both (§5.4, item 2). Recommended: one sentence there when R3 lands.

*Amendments go below this line, dated, without renumbering.*
