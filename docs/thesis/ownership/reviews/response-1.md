# Response to the referee report on "Edit in Place or Not at All"

**Revision:** 10 October 2026, LaTeX sources in `docs/thesis/ownership/` on branch
`research/71-ownership-checker-thesis`. The PDF is `references/ownership/ownership-thesis.pdf`, now
99 pages (was 75).

**Summary.** All 39 findings are accepted, and every one leads to a change. The verdict "sound in
principle, with repairable holes" is right, and the holes were where the report said they were.

| Severity | Findings | Fixed | Declined |
|---|---|---|---|
| Soundness hole | F1–F12 | 12 | 0 |
| False error, common | F13–F17 | 5 | 0 (F17: the exact row count is deferred, see below) |
| False error, rare | F18–F19 | 2 | 0 |
| Theory error | F20–F25 | 6 | 0 |
| Fidelity | F26–F30 | 5 | 0 |
| Citation error | F31–F33 | 3 | 0 (two sub-points only partly accepted: F31.6 and F32 on Polonius) |
| Standalone / clarity | F34–F38 | 5 | 0 |
| Minor | F39 | 1 | 0 |

Three repairs take a different route from the report's suggestion:

- **F3:** a language rule, with the report's alternative kept as the fallback.
- **F7:** `init` becomes a function.
- **F16:** list syntax builds new arrays, rather than consuming only when the operand is unique.

Each is argued below.

**Section numbers.** Numbers below are the revised thesis's: Ch. 3 Model, Ch. 4 Inference, Ch. 5
Soundness, Ch. 6 Hard cases, Ch. 7 Errors, Ch. 8 Compiler, Ch. 9 Costs, Ch. 10 Changes, Ch. 11
Evaluation, Ch. 12 Related work, Ch. 13 Conclusion, App. A Programs, App. B Prior art, App. C Method.
Lemmas are cited by name, since the lemma numbers shifted. The
standalone check (the `grep` in the brief) returns nothing.

---

## The main design changes

1. **Closures carry their facts** (§3.6, new).
   - A new path step `◇` reaches a closure's environment. Every function-typed path is tracked, and
     summaries publish `res` at `◇`.
   - A closure that may consume a capture is *once*, and it is represented as a **cell**: its creation
     allocates a site, and every call of it is a demand on that site.
   - So once-ness and captures travel through returns, fields, constructors and captures, with no new
     rule and no annotation. This is mode inference on arrows, carried by the existing cell machinery.
2. **`use` is four independent bits** (R read, A aliased, E escaped, W written), with `unused` as
   bottom (§3.7).
   - Splitting A from E fixes the conflation behind F1.
   - The `unused` bottom fixes F15.
3. **`supply` carries provenance** (§3.7, §4.7). `res` uses numbered fresh cells.
4. **List syntax builds new arrays** (Change 4). Only the nine *named* writers write. A spread or `++`
   whose operand was unique and dead gets a warning.
5. **Deep exclusive contents** (§3.11). It is now defined by three conditions:
   - across positions;
   - within a position;
   - no outside holder.

   Every writer row states its effect on `excl`. A split pattern rule and `xreq` were added.
6. **An entry protocol for every platform-called function** (§6.9, Table 6.1, P1–P7).
   - It is an asserted row on the program constructor, evaluated at the call that starts the program,
     from summaries.
   - `init` becomes a function (Change 12).
   - A platform may drain sync commands (P7, A12).
7. **Evaluation-order normal form** (§3.3). A variable occurrence is a use at its consuming instruction.
8. **A stated finite lattice** (§4.6). Every fact is oriented, and conditional summaries are guarded
   joins with at most 8 atoms.
9. **The trusted surface stated honestly** (§5.5), and assumptions A1–A12, up from ten.
10. **A differential run with a stale-read sanitiser as the first experiment** (§11.1), with criteria
    fixed in advance (§11.7).

---

## Soundness holes

### F1. A returned or stored closure's captures are invisible to the caller

**Fixed.**

**What changed.**

- Paths gain the environment step `◇` (§3.1).
- The lambda rule puts every captured cell under `◇` (Table 3.2).
- `res` is published at `◇` for function-typed results (§3.7).
- `shared` is split into A (aliased, which `res` explains) and E (escaped, which the caller marks).
- The *Flow facts* lemma now quantifies over paths through `◇`, opaque steps and temporaries.

**Trace.**

- `mk xs = λ⊤ → List.length xs` has `res(◇) = {π₁}`.
- At `g = mk xs`, `A(g)@◇ = A(xs)`.
- At `List.push xs 4`, the holder `(g, ◇)` is live, because `g ⊤` is called afterwards. **Dead** fails.
- **Rejected.**

The placeholder form `List.get xs _` is a lambda and behaves the same way.

### F2. `once` is a property of the binding, not of the value

**Fixed**, along the lines the report suggests: affinity is now a fact of function values, close to
OxCaml's linearity axis.

**What changed.**

- A once closure is a *cell*, and its call is a demand (§3.6).
- A closure is once if it:
  - consumes a capture;
  - calls a captured once value; or
  - passes a captured once value to a consuming position.
- Creating a once closure is a demand on the captures it may write.
- The *Once closures* lemma is new.

**Traces.**

- **A.** `mkPusher`'s result names a fresh closure cell. `p 1` is a demand on that cell, and `p` is
  used again by `p 2`. **Dead** fails. **Rejected.**
- **B.** `h = λy → g y` calls a captured once value, so `h` is once. `List.map [1,2] h` has
  `calls = many`, so the once edge fails. **Rejected.**
- **C.** `r.k 1` is a demand on the cell at `(r, .k)`, and `r.k 2` uses that holder again. **Dead**
  fails. **Rejected.** The `Just (λx → …)` form is the same.

### F3. A user `eq` that writes, reached through `==`

**Fixed by a language rule.**

- **The rule** (§4.8, Change 11): a type's `eq` and `compare` must have `use ⊆ {R}` on every parameter
  path. One that writes, keeps or returns an argument's cell is an error at its declaration.
- **Why it passes the "guarantees, not restrictions" test.**
  - It buys "`==` and `<` never change a value", which list equality, dictionaries, sets and sorting
    then rest on unconditionally.
  - No capability is lost: `List.sort a == List.sort b` builds new lists and is accepted.
- **The fallback.** The report's other route was to summarise `eq` like any method, with every
  `where a.eq` function guarded on its evidence. It is sound and restricts nothing, and the thesis
  records it as the fallback (§4.8, Change 11).
- **The contradiction the report found is removed.** §3.9 now states the rule once, and §6.3 and §8.3
  refer to it.

**Trace.** `Bag.eq` infers W on `π₁.Bag#0`, which is an error at the declaration of `eq`. **Rejected.**

### F4. Exclusive contents does not exclude aliasing inside one element

**Fixed** as the report suggested (§3.11).

**What changed.**

- `excl` is now defined by three conditions: no sharing across positions, no sharing within a
  position, and no outside holder.
- Setting the flag requires **Disjoint** across *all* stored tracked paths, including within one
  element.
- Every writer row states its `excl` effect (§3.8):
  - `append` and `copy` clear it;
  - stores keep it only if the stored value is stored exclusively.
- **Disjoint** at ordinary calls now names "other paths of the same argument" explicitly. That is the
  guarantee an owned supply must reproduce.

**Traces.**

- `[ { a = xs, b = xs } ]` fails the within-position condition, so `excl` is not set, so `update`
  supplies the element *borrowed*. The lambda writes it, and the supply edge fails. **Rejected.**
- Related case: in `zs = xs ++ ys`, `++` stores `ys`'s elements while `ys` lives, so `excl` is not set,
  and the same edge fails. **Rejected.**

### F5. A building loop's exit returns its second argument

**Fixed** with the report's first option (§3.8, Change 2, Table 8.1).

- The exit now *copies* its tail when the destination is empty. That costs `O(|ys|)`, which the
  non-empty case already pays.
- Every alias the library returns has been audited (see F27).

**Trace.** `appendTo [] ys` now returns a fresh copy. The push writes the copy, and `ys` is untouched.
**Safe** (accepted and correct).

### F6. `view`, derived values and subscriptions receive a retained model with no entry protocol

**Fixed** (§6.9, Table 6.1).

**The entry protocol.** It states, for every entry, what is passed owned or read-only and what the
runtime keeps:

- `init`;
- `update`;
- `view`;
- derived values;
- listener bodies;
- `subscriptions`;
- command thunks.

What it says about the entries the report named:

- `view`, derived values and subscriptions receive the model read-only. A named writer applied to a
  model list in them is an error at the definition.
- Subscription results, with their taggers, are escaped.
- On the template runtime, `view`'s result is escaped.

**The spread question.** The report asked whether spreads in `view` build fresh. Under Change 4 they
always do, so the "decided by position" split is not needed.

**Trace.** `shown = [ …model.pinned, …model.recent ]` in `view` reads two lists and builds a third.
**Safe**: there is no demand. A `List.push model.pinned x` in `view` is **rejected**.

The *(guess)* about tagger interleaving is moot, because subscription results are escaped.

### F7. `init` is a top-level value

**Fixed** (§6.9, Change 12).

- The design keeps Table 3.1's reading, because it is the sound one: a value `init`'s cells are
  escaped.
- It rejects the alternative of ignoring the top-level hold, and says why: `Reset → init` would return
  arrays that earlier messages wrote.
- It proposes `init : ⊤ → Model × Cmd Msg`, as Elm's `init` is a function of its flags.

**Trace.**

- With `init` a value: the first `Add` fails **Unescaped**. **Rejected**, with a limit tag.
- With `init` a function: `Reset → init ⊤` gets fresh cells. **Accepted, and correct.**

We did not choose a thunk per top-level value: it would change the language's memoisation of every
constant.

### F8. `supply` has no provenance

**Fixed** as the report suggested (§3.7, §4.7).

- `supply(k)` is a set of provenances (`π_i.q` or `fresh`) plus an ownership bit.
- At a call, the lambda's `res` is translated through it.
- `map`'s row no longer "needs a fresh result". Its result elements are `g.res`, so
  `List.map model.rows (λr → r.tags)` is accepted, with the aliasing recorded.

**Trace.** `supply(1) = {π₁.[*]}` translates the lambda's `{π₁}`, so `pick`'s result aliases
`rows[*]`. The push on `last` meets the live `rows`, and **Dead** fails. **Rejected.**

### F9. The entry fixpoint depends on bodies that are in no interface

**Fixed** (§4.10, §6.9 P5).

- The entry is now an asserted row on the program constructor, evaluated at the call that starts the
  program, from *summaries* alone.
- Summaries carry exactly what the entry needs:
  - numbered fresh cells, so `res(.a) = res(.b) = {fresh₁}` expresses aliasing between result paths;
  - the E bit, for anything a command keeps.
- "Everything read about another module is in its interface" is now stated as an invariant.
- The incrementality test gains the report's scenario.

**Trace.** Editing `init` to place one list at two fields changes its published `res`, and so its
interface hash, and the starting module is re-checked. **Re-checked.** The program is then rejected
by **Disjoint** at the program's start.

### F10. Pending arguments and partly built structures are not holders

**Fixed** as the report suggested.

**What changed.**

- The analysis is defined on an evaluation-order normal form in the style of A-normal form (§3.3). A
  variable occurrence is a use at its consuming instruction.
- Table 3.1 gains the row "an argument evaluated and not yet passed; a structure partly evaluated".
- "Reads before writes" now reads "a dereference that completes before the write" in the abstract,
  §1.1 and §3.3.
- Definition 3.1 counts identity comparisons and calls as uses.

**Traces.** In `compare xs (List.push xs 1)`, `( xs, List.push xs 1 )` and
`{ old = model.todos, new = List.push model.todos t }`, the occurrence of `xs` (or `model.todos`) is a
use at the instruction that consumes it, after the push. **Dead** fails. **Rejected.**

### F11. A view caches a plain copy

**Fixed**, by a slightly different mechanism from the one suggested.

- A write through a view never mutates its header. It returns a new header with no cached copy and the
  correct length.
- The consumed old header is dead.
- A1 now says that every cached derived form lives in a header that a licensed write consumes and
  replaces (§5.4, §6.11, Table 8.1).
- A reader that took the cached copy earlier holds a separate array, a snapshot of the old version,
  which is what value semantics gives it.

**Safe.**

### F12. Mode crossing for opaque types *(guess)*

**Fixed**, although the report marked it a guess, because the design did leave it unspecified.

- The crossing bit is computed in the declaring module and published (§3.1, Change 14, A10).
- An opaque type that does not cross has its public functions' summaries expressed over an opaque path
  step `⟨T⟩`.

**Trace.** `Stack.push`'s summary writes `π₁.⟨Stack⟩`. The caller's later read of `s` fails **Dead**.
**Rejected.**

---

## False errors

### F13. The two applications run on the template runtime

**Fixed: the claims are corrected, not patched.**

- §9.6 now says plainly:
  - both applications run on the template runtime, which keeps every rendered list;
  - on that platform, any in-place edit of a rendered list is an error;
  - the earlier analysis was of a hypothetical port.
- The earlier claim is withdrawn in four explicit bullets.
- Under the revised rules, list syntax builds new arrays, so **neither application contains a demand**.
  Both are accepted on their own platform, and nothing in them is written in place.
- With in-place forms (Change 1), TodoMVC would be:
  - rejected on its own platform;
  - rejected on the direct platform as written;
  - accepted only on the direct platform, with `init` a function, P7 or encoding before the command,
    and the `unused` summary (App. A.1).
- The evaluation reports every count per platform (§11.3).

### F14. A command that captures the model's list escapes it for every later dispatch

**Fixed.**

- **The mislabel.** The command example's verdict is now *possible sharing* (§7.2), and a new
  approximate tag, "a command that may run after later messages", is added to Table 7.1.
- **Commands that cannot suspend.** A platform may promise to drain them before the next dispatch
  (P7, A12, Change 13). The suspension bit the checker already infers says which commands those are.
  Without the promise, the capture is escaped.
- **A.1 corrected.** TodoMVC encodes *inside* the thunk, and the appendix now says so.

### F15. The `use` lattice has no "unused"

**Fixed** as the report suggested.

- `unused = ∅` is the bottom of the four-bit `use` (§3.7).
- A parameter path that is `unused` is not a use for liveness (§3.9).
- `changed` is `unused` at `π₁.todos` (§6.4, App. A.1).

### F16. Spreads, `++` and cons consume their source

**Fixed by a different route** (§3.8, Change 4).

- List syntax (literals, spreads and `++` on lists) builds a new array and only reads its operands, as
  in JavaScript.
- Only the named writers, including `List.cons` and `List.append` called by name, write in place.

**Why not the report's "consume only when unique".** That is the silent, uniqueness-decided copy the
design refuses. A literal that allocates is visible in the source, and its cost is what hand-written
code pays.

**Cost.** Accumulators written with syntax now copy at each step. They become quadratic outside the
building-loop rewrite, as `acc ++ [x]` already is in Elm. The cost is stated in §9.2, and the checker
*warns* where the named writer would have been accepted.

**Effect on the report's programs.** `withActive = [ "active", …baseClasses ]`,
`allColumns = defaults ++ extra` and `a = base ++ [1]; b = base ++ [2]` are all accepted.

### F17. The core library is written over `Js`

**Fixed**, with one point deferred.

- §5.5 is new: the trusted surface counted module by module from the sources. It covers:
  - list: 51 public functions, 7 `foreign`, 54 uses of `Js`;
  - strings: 46 public functions;
  - debugging, including `Debug.log` as an asserted row;
  - tasks, `Ref` and `Deferred`;
  - schemas: 65 public functions, 7 `foreign`;
  - dictionaries and sets, which are inferred apart from one row;
  - the platforms' foreigns, entry protocol, commands, `send` and markup lowering;
  - the runtime contracts.
- The "nine writers" sentence is withdrawn explicitly.
- A8 covers the whole surface. Enumerating it is the report mode's first deliverable (§11.8).
- The abstract now names the trusted surface.
- Table 3.2 and §3.9 now agree on `Js`: a call reads and escapes every cell of its arguments and
  returns `⊤`.

**Partly declined:** the exact row count in the abstract. The rows are not enumerated yet, so the
thesis gives an estimate ("several dozen to a hundred and fifty") with its basis, rather than a number
it cannot back.

### F18. Editing the head element of a list of lists while keeping the tail

**Fixed** (§3.11).

- A pattern `[ x, …rest ]` on an exclusive container whose scrutinee is dead *splits* the container:
  `x`'s cells and `rest`'s `[*]` cells are disjoint, and `rest` stays exclusive.
- A function that relies on this records `xreq(i,q)`, which callers check.

**Result.**

- `bumpHead` is accepted, with `xreq(π₁) = yes`.
- A caller that passes `[ r, r ]` is rejected, and correctly so.

Clean types this program, and so does the checker now.

### F19. Storing any closure in a structure escapes its captures forever

**Fixed** as a consequence of F1.

- A stored closure holds its captures under `◇` at the field's path. They live exactly as long as the
  structure does, and are not escaped forever (§3.6, §6.1).
- Escape now happens only through E-positions or escaped places.

---

## Theory

### F20. The lattice leaves out half the facts

**Fixed** (§4.6, new).

- **The full product lattice**, with orientations:
  - `use`: four bits;
  - `res`: provenance sets with numbered fresh cells;
  - `xres`: a must-fact, ordered in reverse;
  - `xreq`;
  - `calls`;
  - `supply`: provenances, with `owned ⊑ borrowed`;
  - `need`;
  - once-ness.
- **A normal form for conditional summaries**: guarded joins over conjunctions of at most `a` atoms.
- **Height**: at most `2^a · h₀`.
- **A cap on atoms**, with a limit tag.
- Monotonicity is asserted as checked case by case, and **not written out**. The thesis lists this
  among what the sketch does not cover (§5.6), so termination and the least solution follow, while the
  case analysis stays honest debt.
- The Brandon et al. parallel is now labelled as theirs, for their equations.

### F21. "Strictly more permissive than Clean" is false

**Fixed.** Contributions (§1.2), §3.3, Ch. 12 and App. B now say *incomparable*. They name the element-edit
cases that the design accepts only with `excl`, and those it now accepts (F18).

### F22. The performance guarantee is false for prepend

**Fixed** by doing both things the report offered.

- The guarantee is restated precisely, per writer (Ch. 9 opening), and covers only edits spelled with
  a named writer. Syntax "costs what the same construction costs in JavaScript".
- Change 8 (headroom for the named `List.cons`) is **adopted**, so a named prepend is amortised O(1)
  through a view with headroom (Table 8.1).
- The quadratic cost of syntax accumulators is stated in §9.2.
- Building loops being mandatory "for the stack" today is corrected in §2.5.

### F23. The proof sketch has gaps beyond those it lists

**Fixed**, point by point.

1. **The induction.** It is now on the length of the execution prefix, with an invariant over the live
   configuration: frames, closures, pending arguments and runtime structures. Non-returning calls are
   covered by clauses 1 and 4 of the *Summary soundness* lemma.
2. **The *Flow facts* lemma** now covers paths through `◇`, opaque steps and normal-form temporaries.
   New lemmas cover once closures and the entry.
3. **Identity.**
   - "Use" includes identity comparison.
   - The *No stale use* lemma's bisimulation relates identity, and agrees for current references.
   - New assumption **A11** covers identity tests in privileged code: they are on current references,
     or cannot reach an observation, or both outcomes are in `res`.
   - Change 2 removes most such tests: the `kept`/`identical` promise and the claimed-head prepend.
4. **The lemma is only as good as A8.** This is stated, and A8 now covers the whole trusted surface of
   §5.5.

### F24. The complexity claim hides super-linear terms

**Fixed** (§4.9).

- **Width.** Recursive types are now *folded* (§3.1): a path that re-enters a type drops the steps
  since its first visit. So `w` is bounded by the size of the type's definition graph, not by `b^k`.
  This replaces the cut for recursive types.
- **The other terms**, stated explicitly:
  - the inner loop factor `c`;
  - the `res`×params and `2^a` terms in the height;
  - the check, which is `O(D·H)` and quadratic in the largest declaration (typically `update`).
- "Nothing is quadratic in a module" is withdrawn.
- The cap of 64 on `w` is expected to fire only on very wide records.

### F25. `Dict`'s `.contents` path is not in the path language

**Fixed.**

- `Dict` and `Set` are pure beni with no `Js`, so with folding their summaries are *inferred*.
  `.contents` is the folded path, which importers see as the opaque step `⟨Dict⟩` (§3.1, §6.4).
- Only `Dict.update`'s owned supply to its callback is asserted, because it is a destructive read at a
  key.

---

## Fidelity

### F26. A5's premise misdescribes the release optimiser

**Fixed** (§2.6, A5, §8.6).

- The optimiser is now described accurately:
  - folding is limited to atoms and member chains;
  - every statement in between must be another such binding;
  - "any call keeps its place";
  - a read of a beni value is folded past calls in the same statement.
- The real hazard is named: `List.length` and element reads are member reads after lowering.
- The example is corrected to `n = List.length xs; h (List.push xs 1) n`, which becomes
  `h(push(xs,1), xs.length)`. The old example, with a `ys =` binding in between, was wrong.
- The outdated tail-call sentence is replaced; see F28.

### F27. More aliases come back from the library than listed

**Fixed.**

- §2.5 lists every case the report gives:
  - `cons`'s claimed head;
  - `close`;
  - `drop` and `tail` returning views;
  - a `set` of a value that is already `===`;
  - `swap xs i i`;
  - `drop xs 0`;
  - `pop []`;
  - `reverse` and the sorts below two elements.
- §3.8 and Change 2 dispose of each one:
  - builders return fresh arrays;
  - views say `res = {π₁}`;
  - writer no-ops are covered by their rows;
  - the claimed head goes with the trie.

### F28. Smaller fidelity points

**Fixed, each one.**

- **Specialisation.** Per-call-site specialisation is removed from the description (§2.6, §6.16). What the optimiser
  actually does is described: constant-argument propagation, and inlining of a private function called
  from one site. That inlining is argued safe.
- **`Queue`.** Removed everywhere (§2.2, Table 3.1, §6.8, §6.12, Table 7.1). §2.2 says the core library
  has no queue.
- **Subscriptions.** Now described as evaluated once per render and diffed, with taggers retained
  (§2.2).
- **The churn figure.** The ratio is removed. The thesis now quotes the absolute figure, 50 of 90
  unannotated declarations against none annotated, and explains in App. C why no ratio against the
  annotated declarations exists.
- **Building loops.** Now described as mandatory "for the stack" (§2.5).
- **Write sets.** Now: "no fact for two model paths that already hold the same value at the arm's
  entry" (§2.7, §8.4).
- **Derived slots.** §2.7 now says that a derived slot may hold a list, possibly the model's own. P4
  covers it.
- **Self tail calls.** The amended rule is stated in §2.5 and §3.9: early rebinding happens only when
  no argument still to come reads the parameter.

### F29. The worked TEA examples rest on facts about TodoMVC that are not true

**Fixed.** App. A.1 is rewritten in three parts: as written, on the template runtime, and on the direct
platform. It uses the true facts:

- the platform is the template runtime (browser-tea);
- `init` is a value;
- the list is encoded inside the command;
- `changed` is `unused` at `.todos`.

The claims in §1.1, §9.6 and the conclusion are withdrawn or re-derived. A.2 now assumes `init` is a
function, and its unsourced timing is dropped (F34).

### F30. The A4 hazard for list items is described inconsistently

**Fixed.**

- Table 3.1 now says: the instance item is an identity holder for the runtime, and a listener body
  reads the *current* item, re-obtained after each dispatch.
- P3 now obliges the runtime to re-obtain items for every row whose path is in the write set.
- A4 now requires a row whose item is a list to be re-patched when its path is in the write set, even
  though its identity is unchanged.

The report's *(guess)* that this is safe is right, given these sentences.

---

## Citations

All locators and quotes below were checked against the local sources in `references/ownership/`, with
rendered pages where a figure or table was involved.

### F31. Misreadings that support an argument

**Fixed**, with two sub-points partly accepted.

1. **Wrong Konečný paper.**
   - The best-typing result is now cited to `konecny2003typing`: TYPES 2002, LNCS 2646, pp. 182–199,
     taken from Aspinall et al.'s bibliography.
   - `konecny2003layered` is removed from `refs.bib`, along with all three uses (§4.5, §13.3, App. B).
   - The thesis says we know the result only through Aspinall et al.'s report of it.
2. **The Let rule.** The text now says that only aspect 3 in the binding permits destruction in the
   body (Fig. 8, p. 16). It adds why this matters for beni: a read whose result aliases the list keeps
   a holder alive (App. B).
3. **`foldr`.** The claim is dropped. The `mark` rejection is kept, quoted: the array "is used twice in
   the right-hand side" (App. B).
4. **Marshall et al.** The thesis now quotes "there is no way to transform a non-unique value into a
   unique one" (§2.2). It notes that regaining uniqueness appears in their paper only as future work
   (§6), and presents liveness as *our* mechanism, not theirs.
5. **de Vries et al.** Now: "the type of every binding in a recursive binding group" is non-unique. It
   is a constraint on the bound names, not on parameters. The invented causal link to arrow subtyping
   is removed (§4.5, App. B).
6. **System Capybara. Partly accepted.**
   - The analogy is inverted, and is now stated correctly: Capybara accepts a write between two calls
     of a reading closure, which we reject; it rejects only the parallel use (§4.7).
   - On inference, the report is only half right: Capybara *does* infer `ro` ("mode inference",
     §6.1). It still requires the declared markers `Mutable`, `update` and `consume`.
   - The text says both (§4.7, §6.1).
7. **Clarke et al.** The point is now read as being about design intent: the trivial solution always
   satisfies the constraints. The rebuttal now says what the report asked: in beni the least solution
   *is* the intended one. It adds the closer comparison, Huang et al.'s Kleene iteration (survey §5.2)
   (§4.5, Ch. 12).

### F32. Overclaims and locator errors

**Fixed**, with one point partly accepted.

- **Futhark.** Now "most", with the §8.1 quotes.
- **Crichton et al.**
  - 64% is cited as the Table 1 average and 78% as the §2.5 figure, excluding lifetime-parameter
    programs.
  - 46% is now over all participants, with no condition attached (§7.1, §9.5).
  - A refinement of the report: Table 1 sits in §2.3, not §2.4.
- **Emre et al.** The quote is now the §5 all-benchmarks statement, with its "in the worst case". The
  directionality figure is now P2→P3 (7.9% → 88.9%), cited to §6, Table 2 (§3.4, §1.1).
- **Barendsen & Smetsers 1996.**
  - The Cons attributions are cited to §6.
  - The marking rule is cited as preceding Def. 8.14.
  - "No principal types" now reads "states no principal-type theorem", quoting "there is no 'Principal
    Uniqueness Type Theorem'".
- **Peters et al.** The locator is now §4.1.
- **Aspinall et al.** Aspect wording is now verbatim from the abstract.
- **Smetsers et al.** Now "groups of 'alternate arguments'".
- **Wansbrough & Peyton Jones.**
  - They are now credited with solving poisoning by subsumption and arguing against usage
    polymorphism.
  - Our polymorphism is justified by their own concession that only usage polymorphism expresses
    dependencies among arguments, as in `apply` (Ch. 12, App. B).
- **Deng et al.** The thesis now says that a use effect covers reads and writes. It corresponds to our
  "not consumed", not to read-only (§4.7).
- **RFC 2094.** Now "has long rejected and still rejects on stable", "deferred … to Polonius" (§6.6).
- **Polonius. Partly accepted.**
  - It is now attributed to Matsakis, with a new `matsakis2018alias` entry.
  - We keep Stjerna's thesis alongside it, not instead of it: that thesis extends Polonius and gives
    its first complete written description, so citing it for the description is legitimate.
- **OxCaml §6.4.**
  - The "hardest case" claim is removed.
  - The thesis now says only that the *silent* capture through partial application goes away.
  - It says explicit closures still need the lock rule, which our once closures implement (§1.1,
    Ch. 12, App. B).
- **Cann et al.** Now "compilation statistics", with the step the table leaves to prose made explicit
  (§11.5).
- **Henriksen 2026.** Now a "design note", not a "retrospective" (Ch. 12, §9.7).

### F33. The rebuttal of Henriksen's warning is too quick

**Fixed.**

- §9.7 ("The run-time alternative") is new. It quotes Henriksen's reasons and recommendation verbatim.
- It concedes that being "not a type system" does not answer him: he is himself pursuing inference
  outside the language of types.
- It engages with our own sticky-bit finding, which supports his alternative. It states the three
  things the rule buys over that alternative, and says that whether they are worth the rejections is
  for the evaluation to decide.
- Two other places change:
  - §9.4 now says that published summaries reproduce his interface-clutter objection, and that the
    non-locality is arguably worse.
  - App. B's "Declined" entry is rewritten accordingly.
- A note on the report: its three labels were paraphrases. The thesis quotes his actual wording.

---

## Standalone and evaluation

### F34. The quantitative claims cite unpublished work with no method

**Fixed.**

- Appendix C ("Method behind the numbers") is new. It covers:
  - the prototype study's variants and scenarios;
  - its setup: Node 24.19, five rounds, one pinned process per variant, the median of round medians;
  - the shared machine and its load, and the 1.25 threshold;
  - the Chrome spot check and the 484-check differential test;
  - its limits: the transformations were made by hand, the static variant lacked `excl`, ownership
    classes and the entry protocol, and only one machine was used;
  - the churn instrument and how the application counts were made.
- A `beni2026` bibliography entry points to the repository.
- The two claims we could not source are **removed**:
  - the direct platform's 0.127 ms / 0.113 ms swap;
  - "a table application … was found shipping".

### F35. Project-process language and concepts used before definition

**Fixed.**

- **Process language.**
  - "Adversarial reading" is gone.
  - "Hidden flag" is gone.
  - "The compiler's page tests" now reads "test programs that run in a page".
  - "By our count" now reads "by our reading of their sources", with the method in App. C.
  - Earlier versions are referred to as such, which is version history, not process.
- **Concepts before definition.** The Terms section (§1.4) now defines:
  - hand-over;
  - the direct platform;
  - derived values;
  - the write set;
  - same-shape rebuilds.
- **The soundness claim in Terms.** It now reads "is designed to be sound … if the argument of Ch. 5
  holds".
- **Change numbers.** These are cited with a section pointer at first use.

### F36. Related work omits the closest static precedents

**Fixed** (Ch. 12, App. B).

- **Mazur's thesis and the ICLP 2001 paper** are compared at length, with quotes checked on rendered
  pages:
  - reuse conditions published per procedure;
  - commutative sharing pairs;
  - a silent fallback to an unoptimised version;
  - no higher-order calls.
- **The earlier static precedents** are added, explicitly marked as known from secondary sources
  because there is no local copy:
  - Bloss;
  - Hudak;
  - Jones & Le Métayer;
  - Baker;
  - Guzmán & Hudak;
  - Odersky's observers (ESOP 1992), and his POPL 1991 paper, which the catalogue rates closer.
- **Park & Goldberg** is added under escape analysis.
- **Austral, Vale, Pony and Granule** get a "Languages" paragraph, quoting the local copies.

### F37. The evaluation plan cannot answer its question

**Fixed** (Ch. 11, rewritten). Each of the report's five points has a section:

1. **Soundness test (§11.1).** A differential run comes *first*:
   - an in-place backend in a test mode;
   - a stale-read sanitiser: per-array version counters, and references that trap on a stale use,
     including identity comparisons and second calls of once closures;
   - every accepted program run three times;
   - reuse of the existing run-hash machinery;
   - every program from the report's soundness holes added to the corpus.
2. **Biased corpora (§11.3).** Five corpora, the bias stated. An external corpus of open-source Elm
   applications is chosen by a rule fixed beforehand, ported without regard to the rule, and the
   porting effort is counted.
3. **Platform (§11.3).** Rates are reported per platform, and each application is analysed on its own
   platform as well as on a port.
4. **Thresholds (§11.7).** These are fixed in advance:
   - any sanitiser trap blocks adoption;
   - the error is adopted only if fewer than 10% of demand sites in the external corpus are rejected,
     fewer than half of the rejections are approximate, and most fixes take a few minutes;
   - otherwise the warning mode with the run-time fallback ships;
   - extensions are built only when their tag passes 5% of rejections.

   The thresholds are labelled as our judgement.
5. **People (§11.6).** A small study of fix success, the fix chosen and time taken.

### F38. Presentation

**Fixed.**

- **Meta-ellipsis.** It is now written `⋯` throughout:
  - the transfer table;
  - code sketches in the hard cases, background and evaluation;
  - the error-shape skeleton.

  Beni's own spread `…` appears only in beni code.
- **Bracket notation.** It now has a grammar (§3.7, "The bracket notation"), including guarded facts.
- **Bibliography.**
  - `crichton2023grounded` is now PACMPL 7 (OOPSLA2), article 265.
  - `rustc2026diagnostics` has a `howpublished`.

### F39. Small errors

**Fixed, all five.**

- **`xs ++ xs`.** It now builds and is accepted. Its named form `List.append xs xs` fails **Disjoint**
  and is listed among the rejected correct programs (§9.1, item 8).
- **Wording.** "Reads before writes" now reads "a dereference that completes before the write" (the
  abstract and §1.1).
- **`Js`.** Table 3.2 and §3.9 agree: a call reads and escapes every cell of its arguments.
- **`send`.** The beginner's `Cmd.perform (λsend → send (Saved model.todos))` is now attributed
  correctly: it fails at the `send`, because the model still holds the list (§9.1, item 3; Change 9
  weighs this against sharing sends).
- **Schema printers.** They are in the trusted surface. A printer that hands a list's array to the host
  as it is gets an escaping row (§5.5).

---

## What remains open

These are stated in the thesis (§5.6, §13.3).

- **Monotonicity** is not written out case by case, and nothing is mechanised.
- **The trusted surface** is estimated, not enumerated.
- **The template runtime.** Whether a refined row could host useful in-place edits there is not
  designed.
- **Mutable cells** remain a limit.
- **Sending.** Whether consuming sends reject more than they enable is an evaluation question.
- **Copying accumulators.** How often syntax accumulators copy is also an evaluation question.
- **Konečný's proof** is still known to us only through Aspinall et al.
- **Primary sources.** Seven F36 works are cited from secondary sources and marked as such.
