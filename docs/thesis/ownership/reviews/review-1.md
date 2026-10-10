# Referee report: "Edit in Place or Not at All"

**Reviewed:** the LaTeX sources in `docs/thesis/ownership/` on branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`). I used the 75-page PDF
only to check presentation.

**Checked against:**

- the design documents in the same worktree: `language.md`, `backend.md`, `write-sets.md`,
  `browser-direct.md`, `boundary.md`, `transparent-effects-proposal.md` and `schema.md`;
- `CLAUDE.md`;
- the core and platform sources: `core/List.beni`, `core/Debug.beni`,
  `platforms/browser-tea/Tea.beni`, `platforms/browser/Cmd.beni`;
- the applications the thesis cites: `tests/corpus/browser/tea/TodoMVC.beni`,
  `bench/todomvc/size.mjs` and `examples/conduit`;
- the cited sources in `references/ownership/`. Formulas and tables were checked on rendered pages.

**Stance:** adversarial, as asked.

**Labels:**

- A finding with a program or an exact citation is a claim.
- A finding marked *(guess)* has neither, and says so.
- "As written" means "by the rules as the thesis states them". Several holes close if an unstated
  rule is added, and each fix says which rule.

## Summary

| Severity | Count |
|---|---|
| Soundness hole | 12 (F1–F12) |
| False error, common | 5 (F13–F17) |
| False error, rare | 2 (F18–F19) |
| Theory error | 6 (F20–F25) |
| Fidelity | 5 (F26–F30) |
| Citation error | 3 (F31–F33) |
| Standalone / clarity | 5 (F34–F38) |
| Minor | 1 (F39) |

**Verdict.** The first-order core is a reasonable design:

- uniqueness at the site, decided by liveness;
- a directional, per-path cell flow;
- four side conditions;
- validated summaries.

I found no counterexample to it when every value involved is a list, a record, a tuple or a
constructor written in the body under analysis. What is broken is what the thesis claims as its main
contribution beyond the prior art: higher-order code with no annotations, and the hand-over of the
TEA model.

- Function values that are returned, stored or captured carry neither their captures nor their
  `once` flag. This gives three independent holes (F1, F2, F8).
- The well-known methods are assumed read-only when user code may consume (F3).
- The exclusive-contents flag does not exclude aliasing inside one element (F4).
- A core function the thesis reads as "fresh" returns its argument (F5).
- Code that the platform calls on a retained model, other than `update`, has no entry protocol (F6).

On the usability side, the claim that the two real applications are accepted is wrong for four
independent reasons (F13–F16).

I judge the design **sound in principle, with repairable holes**. The repairs are not small, though:

- function types need capture and affinity facts, which amount to modes on arrows;
- every entry point the platform calls needs a protocol;
- the trusted, asserted surface is several times larger than the "nine writers".

The usefulness case has to be re-made on a platform that does not exist yet for those
applications.

---

## Soundness holes

### F1. A returned or stored closure's captures are invisible to the caller

**Severity:** soundness hole.

**Hits:**

- §3.5 *Summaries* (`ch-model.tex`, the `use`/`res` grammar);
- §4.4 (`ch-inference.tex`, reading `shared` off the body);
- Lemmas 5.2 and 5.6 (*Flow facts*, *Dead aliases*).

**Program.**

```
mk : List Int → (⊤ → Int)
mk xs = λ⊤ → List.length xs

main =
    xs = [ 1, 2, 3 ]
    g = mk xs
    ys = List.push xs 4
    Debug.log "len" (g ⊤)      -- value semantics: 3; in place: 4
```

The same shape, with no lambda in sight, is a placeholder: `getter xs = List.get xs _`. Placeholders
desugar to closures (`language.md` §6.7; "the lambda evaluates nothing when it is built", line 831).

**Trace as written.**

1. In `mk`, `xs` is captured by a closure that is returned. By §4.4, `use(1, ε) = shared`.
2. `mk`'s result is function-typed, so it has no list-typed path, and `res` is empty. `res` ranges
   only over "list-typed result path[s]" (§3.5).
3. At the call `g = mk xs` the caller applies "the summary S_f" (Table 3.2). That gives
   A(g) = ∅, which by §3.4 means "provably no cell". `g` is not a lambda literal, so no `(λ, cap z)`
   holder exists.
4. Nothing on the caller side turns `shared` into "escaped". Lemma 5.5 clause 2 constrains only
   `borrowed`. Making every `shared` argument escaped would break every writer, since writers are
   `consumed` and `shared` (§4.4). So the caller cannot.
5. At `List.push xs 4` the only holder of the cell is `xs`, which is dead afterwards. **Known**,
   **Unescaped**, **Dead** and **Disjoint** all pass, and the program is accepted.
6. `g ⊤` reads the pushed array.

**Root cause.** `shared` conflates two things:

- "aliased by the result at a path `res` names";
- "kept by something the caller cannot see".

The path language has no step into a closure environment, and Lemma 5.2 quantifies only over cells
"reachable … through a path", so closure-held cells fall outside it. The proof of Lemma 5.6 says every
reference "is accounted for by a holder of the current frame, or of a caller's frame through the
chain of parameters". References held by closures that callees returned are not accounted for.

**Fix.**

- Split `shared` into `aliased` (explained by `res`) and `escapes` (the caller marks the cell
  escaped).
- Or give function-typed result and field paths a capture step (`cap`) in `res`, so that
  `mk : List a [captured by result] → (⊤ → Int)`.
- Restate Lemma 5.2 over closure environments.

### F2. `once` is a property of the binding, not of the function value, so it is lost by returning, capturing or storing

**Severity:** soundness hole.

**Hits:** §3.5 *Lambdas, captures and once*; §4.6 *Ownership classes*; §6.1.

**Program A: returned.**

```
mkPusher : List Int → (Int → List Int)
mkPusher acc = λx → List.push acc x

main =
    p = mkPusher [ 0 ]
    a = p 1
    b = p 2
    Debug.log "a" a          -- value: [0, 1]; in place: [0, 1, 2]
```

**Program B: captured by another closure.**

```
main =
    acc = [ 0 ]
    g = λx → List.push acc x          -- once
    h = λy → g y                      -- not once: g is not a list-typed capture
    Debug.log "rs" (List.map [ 1, 2 ] h)
    -- value: [[0,1],[0,2]]; in place: [[0,1,2],[0,1,2]] (one array, twice)
```

**Program C: stored.** `r = { k = λx → List.push acc x }`, followed by `r.k 1` and `r.k 2`. The same
works with `Just (λx → …)`.

**Trace as written.**

- `once` is "set exactly when some capture is consumed". `cap` is defined per (variable,
  *list-typed* path) (§3.5).
- The affine rule is stated on "its binding": "dead after one use on every path".
- An ownership class carries "the four `fun` facts, and `use`/`res` variables for its own parameters
  and result" (§4.6). It does not carry `once`.

So:

- **A:** `p`, the result of a call, is a function value with no `once` fact, and two calls are
  accepted. `mkPusher`'s `acc` is a parameter, so the creation-time check discharges it to the
  caller, which passes a fresh literal.
- **B:** calling the captured `g` is not a consumption of a list-typed capture, so `h` is not `once`
  and `map`'s `calls = many` edge does not fire.
- **C:** the lambda has no binding, so the affine rule has nothing to apply to.

**Fix.** Make affinity a fact of function *types*, as OxCaml's linearity axis is
(`lorenzen2024oxidizing` §3.3):

- a closure that captures a `once` value is `once`;
- a structure that holds a `once` function is affine;
- a function whose result may be `once` says so in its class.

This is mode inference on arrows. It is a real extension, not a patch, and it is exactly where the
thesis says (§12, "What we are confident of") that prior systems "gave up or required declarations".

### F3. "`eq` and `compare` are read-only by contract" is false, so `==` on lists, derived `eq` and `where`-generic code can run a consuming user `eq`

**Severity:** soundness hole.

**Hits:** §3.8 (says a user `eq` "is summarised like any function—one that consumes is a demand");
§4.7, §6.3 and §8.3 (say well-known `eq`/`compare` are borrowed "by contract" and that derived and
library equality are "read-only by construction"). The two statements contradict each other.

**Program.**

```
type Bag = Bag (List Int)

pub eq : Bag, Bag → Bool
eq (Bag a) (Bag b) =
    List.length (List.push a 0) == List.length b + 1

main =
    b = Bag [ 1 ]
    Debug.log "same" ([ b ] == [ b ])     -- value: True; in place: False
```

**Trace.**

- `Bag.eq` is accepted at its definition: the demand is on the parameter path `π₁.Bag#0`, which is
  discharged to its callers.
- `[ b ] == [ b ]` resolves to `List.eq`. The thesis calls it read-only "by construction", so no
  demand is seen.
- But `List.eq` calls the element type's evidence (`core/List.beni:172-181`), which is `Bag.eq` with
  both arguments the same cell. The push mutates that cell, so `List.length b` is 2, not 1.
- Afterwards `b` itself reads `Bag [1, 0]`.

**Other routes.**

- A record `{ bag : Bag }` with a derived `eq`.
- Any `where a.eq` function, such as `List.member`, instantiated at `Bag`.

**A version that is not contrived.** Under change 1, `eq (Bag a) (Bag b) = List.sort a == List.sort b`
is ordinary multiset equality, and it sorts both bags in place behind every caller's back.

**What the documents say.** They make well-known `eq`/`compare` `sync` (`boundary.md` §4), not
read-only.

**Fix.** Require every type's `eq` and `compare` to infer `borrowed` on every parameter path, and
reject a consuming one at its declaration. That restriction buys a guarantee, so it passes the
"guarantees, not restrictions" test of §9. Then derived and library equality really are read-only.

### F4. Exclusive contents does not exclude aliasing inside one element

**Severity:** soundness hole.

**Hits:** §3.10, Lemma 5.3, §6.4, Appendix A.4 (the "two-slots-one-record hazard" the thesis asks
reviewers to attack).

**Program.**

```
main =
    xs = [ 1 ]
    rows = [ { a = xs, b = xs } ]          -- one element, one cell at two of its paths
    rows2 = List.update rows 0 (λr → { r | a = List.push r.a 2 })
    Debug.log "b" (List.map rows2 (λr → r.b))   -- value: [[1]]; in place: [[1,2]]
```

**Trace.**

1. `excl` is "set by … a literal of distinct fresh cells". The literal stores one element, whose
   only cell is fresh, and `xs` is dead afterwards, so the flag is set.
2. `List.update` supplies the element owned, because `rows` is unique and exclusive.
3. Inside the lambda, `A(r)@.a = {π₁.a}` and `A(r)@.b = {π₁.b}`. These are different abstract
   cells, so **Dead** sees no other holder of `π₁.a`. The push is accepted.

**Why the caller's guarantee is missing.** For an ordinary call, `π₁.a ≠ π₁.b` is guaranteed by the
caller's **Disjoint** (`q' ≠ q`, §3.9). When the "caller" is `List.update`'s asserted supply, nothing
provides that guarantee. Lemma 5.3's statement, "stored at exactly one position … and has no holder
other than the container's path", is satisfied here: one position, several sub-paths. So the lemma
is true and does not imply what Lemma 5.6 needs.

**A related unspecified case.**

- None of the asserted rows in §3.7 says how `append`, `push`, `cons` or `insertAt` affect `excl`.
- `zs = xs ++ ys` puts `ys`'s elements into `zs` while `ys` lives.
- If `append` is read as preserving `xs`'s `excl`, the same hole opens:
  `List.update zs (List.length xs) (λr → List.push r 9)`, followed by a read of `ys`.

**Fix.**

- `excl` must mean deep, per-element disjointness: all list-typed sub-paths of every element hold
  pairwise distinct cells, recursively.
- The setting rule must check it, so that **Disjoint** applies within each stored element.
- Every asserted writer row must state its `excl` effect.

### F5. A building loop's exit returns its second argument; the thesis reads it as fresh

**Severity:** soundness hole.

**Hits:** §2.5 *Building loops*, §3.7 *A summary describes the emitted code*.

**Code.** `core/List.beni:486-497`: `close b v = … if n == 0 then v else …`. The comment says "or
`rest` itself when the destination is empty".

**Program.**

```
appendTo : List a, List a → List a
appendTo xs ys = case xs of
    [] → ys
    [ x, …rest ] → [ x, …appendTo rest ys ]

main =
    ys = [ 1, 2 ]
    zs = appendTo [] ys          -- the builder is empty, so zs is ys itself
    zs2 = List.push zs 3
    Debug.log "ys" ys            -- value: [1,2]; in place: [1,2,3]
```

**Trace.**

- §3.7 says: "the exit value is borrowed, the result fresh".
- So A(zs) is a fresh site, `ys` is not a holder of it, and the push is accepted.

**Fix.** Either make `close` always copy, which costs an allocation on every empty build, or read the
emitted function with `res = {fresh, π₂}`. Add `close` to change 2's list of identity promises. The
same audit should cover every alias the library returns (F27).

### F6. `view`, derived values and `subscriptions` receive a retained model with no entry protocol, and append and cons are demands

**Severity:** soundness hole, or a common false error, depending on an unstated choice.

**Hits:** §6.9, *Derived values are reads, never demands*.

**The claim.** §6.9 says that under the nine-writer demand set "this is automatic, since `filter`
and `map` are not demands".

**Why it is false.** `cons` and `append` are among the nine writers, and they are what list spreads
and `++` lower to (§2.9, §3.7).

**Program.** Direct platform.

```
view : Model → Html Msg
view model =
    shown = [ …model.pinned, …model.recent ]       -- append: consumes model.pinned
    <ul><For each={shown}>…</For></ul>
```

**Two readings, both bad.**

- **The platform's call of `view` is not checked**, which is what the thesis says for every entry
  except `update`; P5 covers only `init` and the arms.
  - Then `view`'s inferred summary `use(model, .pinned) = consumed` is discharged by nobody.
  - Every recomputation of the derived value, and every run of the development verification step
    (§2.7), appends `model.recent` onto `model.pinned` in place.
  - The list grows on each recomputation.
- **The platform declares `view`'s model `borrowed`.** Then every `++` or spread over a model list in
  any `view` is a compile error. That is common: class lists, error lists, header rows.

**Same gap elsewhere.**

- `subscriptions : Model → Sub Msg` is program code called on the retained model. Its taggers are
  stored by the runtime (`Tea.beni:451-459`: "keys that stayed keep their fiber and take their new
  taggers").
- Listener bodies (P3) are the same case.

*(guess)* I did not construct an observable tagger interleaving. Diffing happens once per render, in
the microtask after the update, so the window may be empty on browser-tea.

**Fix.** State an entry protocol for every function the platform calls (P1–P6 generalised): which
parameters are supplied owned or borrowed, and what the runtime retains. Then decide whether spreads
in `view` build fresh. If they do, that is the same "decided by position" split as change 1, and it
is needed even without change 1.

### F7. `init` is a top-level value: either TEA programs are rejected on their first edit, or `Reset → init` observes in-place writes

**Severity:** soundness hole, or a common false error; the rules do not say which.

**Hits:**

- Table 3.1 and §3.9 (a top-level value is "escaped: read by every later use, for the program's
  life");
- P5 (joins "`init`'s result" with no mention of that escape);
- Appendices A.1 and A.2.

**Fact.** In beni's TEA, `init` is a value (`Tea.beni:40-55`: `init : model × Cmd msg`), and the
applications declare it at top level (`TodoMVC.beni:111`: `init : Model × Cmd Msg`).

**Program.**

```
init : Model × Cmd Msg
init = ( { todos = [] }, Cmd.none )

update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Add t → ( { model | todos = List.push model.todos t }, Cmd.none )
        Reset → init
```

**Two readings.**

- **Table 3.1 applies.** Every cell of `init` is escaped, so the first `Add` fails **Unescaped**, in
  every TEA program whose lists start in `init`.
  - That is essentially all of them, including the table swap of A.2 and TodoMVC.
  - It is reported as a "limit".
- **P5 drops the top-level hold** to make A.1 and A.2 go through. Then `Add "x"` followed by `Reset`
  returns `todos = ["x"]` in place, where value semantics gives `[]`.

**Fix.**

- Treat `init` specially: the platform consumes it, and the program may not name it again.
- Or make every top-level list value a thunk that allocates on each read. That is a change to the
  language's memoisation and to `backend.md` §3.
- Either way, state it.

### F8. `supply` has no provenance, so a callback that returns its argument cannot be summarised soundly

**Severity:** soundness hole as written, or a common false error under the literal summary of `map`.

**Hits:** §3.5 (`supply` is "an owned or a borrowed cell") and §4.6 (`foldl : … → b [= π₂ ∪ g.res]`).

**Program.**

```
pick : List (List Int) → List Int
pick rows = List.foldl rows [] (λr acc → r)      -- returns the last element

main =
    rows = [ [ 1 ], [ 2 ] ]
    last = pick rows
    last2 = List.push last 9
    Debug.log "rows" rows      -- value: [[1],[2]]; in place: [[1],[2,9]]
```

**The problem.** The lambda's `res` names its own parameter `r`. To instantiate `g.res` at `foldl`'s
call, the caller must know which of `foldl`'s argument paths `foldl` passed as `g`'s first argument
(`π₁.[∗]`). `supply` records only owned or borrowed, never which path.

**Two readings.**

- **The implementation reads an unmapped `g.res` as fresh.** Then the program is accepted.
- **The implementation reads it as ⊤.** Then it is rejected, as a limit.

**What the thesis says about `map`.** §4.6 says `map`'s callback is "needed to return a fresh value".
Taken literally, that rejects `List.map model.rows (λr → r.tags)`. Extracting a list-valued field is
common in nested data.

**Fix.** Make `supply` a map from `g`'s parameter positions to `f`'s parameter paths, plus `fresh`,
so that `g.res` instantiates exactly as `res` does. Restate `map`'s `need` as conditional.

### F9. The entry fixpoint depends on bodies that are in no interface, so the cache can serve a stale entry state

**Severity:** soundness hole under incremental builds; a specification gap.

**Hits:** P5, §4.8 (says "the cache key does not change"), §8.7.

**The gap.**

- P5 needs `init`'s result paths and the aliasing between them (`{ a = xs, b = xs }`), and each arm's
  escapes.
- `init`'s interface entry is a top-level value's. By Table 3.1 that is "every cell escaped", which
  holds no path aliasing.
- The type, `Model`, does not change when `init`'s body changes.

**Scenario.**

1. Edit `Init.beni` from `init = { a = [ 1 ], b = [ 2 ] }` to `xs = [ 1 ]` and
   `init = { a = xs, b = xs }`.
2. No interface hash changes.
3. The module holding P5's result is not re-checked.
4. A cached acceptance of `List.push model.a 9` survives, and the page shows `model.b` as `[1, 9]`.

**Fix.** Either publish path-alias and escape summaries for top-level values and command-building
helpers in interfaces, which is new interface content with new churn, or run P5 uncached on every
build. Say which, and add the case to the determinism and incrementality tests.

### F10. Pending arguments and partly built structures are not in the holder table

**Severity:** soundness hole under the literal reading; a specification ambiguity.

**Hits:** Definition 3.1, Table 3.1, §3.3 ("reads before writes are never sharing"), §1.2.

**Programs.**

- `compare xs (List.push xs 1)`. Value semantics: `LT`. In place: `EQ`.
- `( xs, List.push xs 1 )`.
- `{ old = model.todos, new = List.push model.todos t }`.

In each one, `xs` appears textually *before* the demand. Its value is not read then; it is held, and
handed over after the write.

**Why it matters.**

- Table 3.1 lists variables, fields and elements "held by a place", captures, runtime places and
  JavaScript. It does not list an evaluated argument waiting for its call, or a tuple under
  construction.
- The thesis's own rhetoric ("strict left-to-right evaluation makes 'before' syntactic"; "a read that
  comes before the update is … never sharing") invites exactly the wrong implementation.
- The thesis's own TodoMVC argument (§9.5: "the record built just before it holds the old array …
  until a helper replaces that field") shows it *does* intend pending arguments to be holders.

**Fix.** Define the analysis on an A-normal form in which a variable occurrence is a use at the
instruction that consumes it. Add "an evaluated argument not yet passed" and "a structure under
construction" to Table 3.1. Restate "reads before writes" as "*dereferences* before writes".

### F11. A view caches a plain copy, and an in-place write through the base leaves it stale

**Severity:** soundness hole in the backend half; an obligation missing from A1 and Table 8.1.

**Fact.** `core/List.beni:520-533` and `597-606`:

- A view is `{ b, o, length, p, $plain }`.
- `$plain()` caches its copy in `p`, "made once".
- `length` is stored, not derived.

**Scenario.**

1. A platform reader calls `$plain()` on `rest`, for example to render it.
2. `List.set rest 0 9` writes `b[o]` in place and returns the same header (`res = π₁`).
3. The next `$plain()` returns the stale `p`.

Under value semantics, `set` returns a new list.

**Fix.** Table 8.1's row "write through a view" must reset `p`, and fix `length` for `push` and
`pop`. A1 should say that every cached derived form of a cell is invalidated by a licensed write.
`backend.md:588` also omits `p`.

### F12. Mode crossing for opaque types and runtime-opaque types is undefined *(guess)*

**Severity:** soundness hole (guess).

**Hits:** §3.1, A10.

**The gap.** `crosses(τ)` is computed "from the solved type", requiring "no `List` reachable through
… the payloads of its constructors". The thesis does not say how an importer computes this for an
opaque type whose constructors are hidden:

```
-- module Stack, exposing Stack opaquely
type Stack = Stack (List Int)
```

If an importer concludes that `Stack` crosses, then A(s) = ∅, which "means provably no cell". The
**Known** loop over `c ∈ ∅` is then vacuous, and a demand inside `Stack.push s 1` is accepted while
`s` is read later.

I did not confirm whether beni's interfaces carry representations of opaque types.

**Fix.** Publish a crossing bit per type in interfaces, computed in the declaring module.

---

## False errors

### F13. The rule cannot run on the platform the two applications use, so the "accepted" claims are wrong

**Severity:** false error, common: every TEA list edit.

**Hits:** §1.2 ("the rule as stated changes nothing in these two applications"), §9.5, A.1, A.2,
§11.

**Facts.**

- TodoMVC is built with `--platform=browser-tea` (`bench/todomvc/size.mjs:85`).
- Conduit's `beni.json` says `"platform": "browser-tea"`.
- Both use the template runtime, which keeps every rendered list. See `platforms/browser/Rt.beni:730`,
  `1419` and `1628`, confirmed by the fidelity check.

**Consequence.** The thesis itself says the template runtime "cannot host the rule" (§6.9). So every
demand on a rendered list in these applications is a sharing error on their own platform:

- TodoMVC's `model.todos ++ [ … ]`;
- Conduit's seven `model.errors ++ …`.

**What the counts actually show.** §9.5's counts are counts *on a hypothetical port to the direct
platform*, which neither application runs on. Any default-platform TEA program that edits a rendered
list would be rejected.

**Fix.**

- State plainly that adopting the rule requires the direct platform, or an equivalent hand-over in
  browser-tea, before any TEA program benefits.
- Make the evaluation run each application on the platform it actually uses, and report both
  numbers.

### F14. A command that captures the model's list escapes it for every later dispatch, and TodoMVC does exactly that

**Severity:** false error, common: the persistence and HTTP-body pattern. The diagnostic is also
mislabelled.

**Hits:** P5, §6.8, §7.2 (example 3), A.1.

**Fact.** `TodoMVC.beni:84-85, 223-224`:

```
save todos = Cmd.do λ⊤ → saved (Storage.set Local key (encode todos))
changed model todos = ( { model | todos = todos }, save todos )
```

The list is encoded *inside* the thunk. A.1's claim that "the build that persists to storage encodes
the list before the command is made" is false for the cited source.

**Consequence.** By P5 ("a cell that any arm captures in a command … is escaped at every entry"),
`.todos` is `shared` at entry. Every later `++`, and under change 1 every `map` or `filter`, on
`model.todos` is rejected.

**The mislabel.** §7.2 calls this "real sharing, across messages". But `Cmd.do` runs a command that
never waits "where its fiber would have started" (`Tea.beni:46-52`), which is before the next
message. The derivation depends on runtime scheduling the checker cannot see, so it must carry an
approximate tag. This undermines the exact/approximate split on which §11.6's decision rests.

**Fix.**

- Classify command captures as a limit.
- Or give the platform a way to declare thunks that finish before the next dispatch.
- Correct A.1.

### F15. The `use` lattice has no "unused", so threading a model through a helper that replaces one field is rejected, contradicting A.1 and §9.5

**Severity:** false error, common: the TEA helper idiom. Also an internal inconsistency.

**Hits:** §3.5 (`use ∈ {borrowed, shared, consumed}`, and "`borrowed` otherwise", §4.4), §3.8 (a call
whose summary is `borrowed` at a path is a read), §6.4, §9.5, A.1.

**Programs.** These are TodoMVC's own, at lines 146 and 150-154:

```
changed { model | draft = "", nextId = model.nextId + 1 }
        (model.todos ++ [ { id = model.nextId, title = title, completed = False } ])

changed model (List.map model.todos λt → …)     -- A.1, under change 1
```

**Trace.**

1. The first argument holds `.todos` and is passed to `changed` after the demand.
2. `changed model todos = ( { model | todos = todos }, … )` never reads `π₁.todos`. But the lattice
   has no value below `borrowed`, so `use(1, .todos) = borrowed`.
3. By §3.8 that is a read, so the holder is live and **Dead** fails.
4. A.1's argument, "whose summary reads no path that meets .todos", needs a summary value that does
   not exist.

**Fix.** Add `unused` as the bottom of `use`, and treat a parameter path in `unused` as not a use.
This is necessary for the field-sensitivity the thesis advertises in §3.8 and §6.4.

### F16. Spreads, `++` and cons consume their source, so a top-level constant list can never be spread

**Severity:** false error, common in Elm-style code.

**Hits:** §2.9, §3.7, §3.9 *Holders that live for the whole program*.

**Programs.**

```
baseClasses = [ "btn" ]
withActive = [ "active", …baseClasses ]        -- cons consumes a top-level list: rejected

allColumns = defaults ++ extra                 -- defaults top-level: rejected

a = base ++ [ 1 ]
b = base ++ [ 2 ]                              -- base live at the first append: rejected
```

**Scope.**

- Every `[ x, …xs ]` and `xs ++ ys` whose left or tail operand lives on is now a sharing error.
- A top-level list can never be the source of a spread.
- A function such as `withDefault opts = [ d, …opts ]` becomes `consumed` in `opts`, and that
  propagates to its callers.

These are among the most frequent list operations in Elm code. Conduit alone has nine concatenations
whose left operand is a local, and its `view`s are a further source (F6).

The thesis lists only "keeping an old version" and its relatives in §9.1. It does not list "spreading
a list you still use", which I expect to dominate the count.

**Estimate.** *(guess)* It is common enough that the evaluation should report it as its own category.

**Fix.** Consider making `cons` and `append` consume only when the operand is provably unique, and
build fresh otherwise. That is exactly the silent copy the thesis rejects, so it would have to be a
visible, position-decided rule. Or accept that the spread syntax needs a non-consuming spelling.

### F17. The core library is written over `Js`, so most of it marks its arguments escaped unless far more than nine rows are asserted

**Severity:** false error, common (every list ever mapped), unless the trusted surface grows. Also
fidelity and theory.

**Hits:** §3.7 ("Everything else in the list library is ordinary beni over `at` and an array
builder, and its summary is inferred … with no assertion"), Table 3.2 (a `Js` operation escapes its
arguments).

**Facts.**

- `map` is `mapHelp xs (base xs) (offset xs) … (builder …)` and ends in `kept same xs (done b n)`
  (`core/List.beni:1117-1129`).
- `base`, `offset`, `builder` and `done` are `Js.pure` functions (`core/List.beni:431-477`).
- `put`, `identical` and `kept` are `foreign` (`:470`, `:504`, `:511`).
- By Table 3.2 every list passed to `List.map` or `List.filter` (through `base xs`) becomes escaped
  forever.
- `Debug.log` is beni over `Js` too (`core/Debug.beni:29, 70-72`). It is not a `foreign` with an
  asserted "returns its second argument".

**Fix.** Enumerate the asserted rows the design actually needs: the internal primitives, `kept` and
`identical`, `Debug.log`, `Task`, `Ref`, `Cmd.perform`, `send`, `Dict.update`, and the platforms'
foreigns. Count them in the abstract, and put each under A8's pinned-test discipline. "Only the nine
writers carry the demand" is true of *demands*, but the trusted surface is several times larger.

### F18. Editing the head element of a list of lists while keeping the tail is rejected; Clean accepts it

**Severity:** false error, rare. It also refutes a claim (see F21).

**Hits:** Table 3.2 (`rest` is bound to "the same cells as x", including at `[∗]`), §3.3.

**Program.**

```
bumpHead : List (List Int) → List (List Int)
bumpHead rows = case rows of
    [] → []
    [ r, …rest ] → [ List.push r 0, …rest ]
```

**Trace.** `A(rest)@[∗] ∋ π₁.[∗]`, which is `r`'s cell, and `rest` is used after the push, so
**Dead** fails. Clean, with a unique spine and unique elements, types this program
(`barendsen1996uniqueness` §6, the three `Cons` attributions).

### F19. Storing any closure in a structure escapes its captures forever

**Severity:** false error, rare.

**Hits:** §4.3 (a closure escapes when "stored").

**Effect.** A record of handler functions that close over a list, such as a model holding
`renderRow : Row → Html Msg` built from a list of columns, makes that list uneditable for the
program's life.

*(guess)* This is rare in TEA models, but common in configuration records.

---

## Theory

### F20. Termination and optimality of the fixpoint are argued over a lattice that leaves out half the facts

**Severity:** theory error.

**Hits:** §4.5, §12 ("has a best solution").

**What the stated order covers.** It covers `use`, `res`, `calls` and `escapes`.

**What it does not cover.**

- `excl`, which is a *must* fact and so descends while the others ascend;
- `supply` and `need`;
- `once`;
- conditional summaries. §3.5 makes every `use`, `res` and side condition "an expression over the
  class variables". The iteration is over formulas, and their monotonicity and the height of their
  lattice are not argued.

**What the claim needs.** "The lattice is finite and every transfer is monotone" requires:

- a product order with `excl` and `supply = owned` reversed;
- a normal form for the formulas.

Without both, neither termination nor "least solution, which the optimistic start finds" follows.

**The parallel with Brandon et al.** They justify Knaster–Tarski for *their* equations, so the
parallel is suggestive, not a proof.

**Fix.** Give the full product lattice with orientations, a normal form for conditional summaries
(for example, disjunctions of conjunctions of class atoms, bounded by the number of class
variables), and the height bound that follows.

### F21. "Strictly more permissive than Clean" is false

**Severity:** theory error (an overclaim).

**Hits:** §1.3 *Contributions*, §3.3.

**Counterexample.** F18. Liveness at the site is more permissive than occurrence counting for
*references to the operand*. Deep uniqueness (Clean's unique spine with unique elements) accepts
element edits that the per-allocation-site cell abstraction cannot.

**Fix.** The two are incomparable. Say so.

### F22. The "performance guarantee" is false for prepend

**Severity:** theory error (a headline claim).

**Hits:** §9 ("every list write is O(1), or the O(n) a hand-written program also pays"), Table 8.1,
§9.2, change 8.

**Under the rule.** `cons` is `unshift`, which is O(n). So the canonical accumulator idioms are
quadratic:

- `List.foldl xs [] (λx acc → [ x, …acc ])`, which is reverse;
- prepending in a `foldr`, or in any non-tail recursion.

**Today.** `cons` is amortised O(1) through the claimable head (`core/List.beni:76-79`), and
`backend.md:3422-3427` keeps building loops mandatory "for the stack alone".

**So.** The rule makes beni's most common Elm idiom asymptotically *worse*. A hand-written program
does not unshift in a loop. The thesis lists this as a cost "to be measured", but it contradicts the
guarantee the rule exists to provide.

**Fix.** Either adopt change 8 (headroom) as part of the rule, or weaken the guarantee's wording.

### F23. The proof sketch has gaps beyond those it lists

**Severity:** theory error.

**Hits:** Chapter 5.

1. **Induction measure.** Lemma 5.5 is "by induction on the depth of the call tree". That is not
   well-founded for non-terminating executions: a non-tail recursion that never returns, or an
   unbounded sequence of TEA dispatches. Callback re-entry also interleaves frames. Use induction on
   execution-prefix length, with an invariant over the live stack.
2. **Lemma 5.2** quantifies over cells "reachable from the frame's locals through a path". Paths do
   not enter closures, so closure-held cells are outside the lemma (F1, F2). Lemma 5.6's proof
   inherits this, and also omits pending arguments (F10).
3. **Lemma 5.1's bisimulation ignores identity.** `S_v` and `S_u` differ in `===` between a demand's
   result and its operand. Privileged code observes `===`:
   - `Js.same` in `cons` (`core/List.beni:89`);
   - `identical` and `kept` in `map`;
   - the renderer.

   A4 covers only renderers. The proof needs a clause that every identity-dependent branch in core
   or a platform is covered by `res` including all of its outcomes, and that no identity result
   reaches a trace observation.
4. **`fresh` in Lemma 5.5(3)** means "no holder other than the result". Under F5 and F8, the inferred
   or asserted summaries violate it. The lemma is only as good as A8, and A8 now has to cover the
   surface F17 enumerates.

### F24. The complexity claim hides super-linear terms

**Severity:** theory error (minor).

**Hits:** §4.8, abstract.

**Terms the claim leaves out.**

- **Width.** For a recursive type, `w` (the tracked paths of a type) is up to `bᵏ` under the cut
  `k = 8`. That covers user trees, `Dict` itself and `type Tree = Node String (List Tree)`.
- **Inner loop.** The self tail call's inner fixpoint ("at most as many rounds as there are distinct
  cells") multiplies each round.
- **Height.** `h` includes a result-paths × parameter-paths term.
- **The check.** It is O(demands × holders) in the *largest declaration*, which in a TEA application
  is `update`, often most of a module. "Nothing is quadratic in the size of a module" is technically
  true and practically misleading.

**Fix.** State the bound with these terms. The proposed cap of 64 on `w` will fire on any recursive
type that contains lists.

### F25. `Dict`'s `.contents` path is not in the path language

**Severity:** theory error (inconsistency).

**Hits:** §3.1 (the steps are `.f`, `.i`, `C#i` and `[∗]`), §3.10 and §6.4 (`(x, q.contents)`).

**The inconsistency.** `Dict` is "a balanced tree of constructors written in beni", so its inferred
summaries would be over constructor paths. Those are cut at 8, so its values are ⊤, and every
dictionary-held list fails **Known**. The `.contents` abstraction exists only by assertion, and only
`Dict.update`'s supply is said to be asserted.

**Fix.** Either define an abstract-container step and assert every `Dict` and `Set` row, or admit
that dictionary-held lists are a limit.

---

## Fidelity to beni

### F26. A5's premise misdescribes the release optimiser

**Severity:** fidelity.

**Hits:** §2.6, A5, §8.6.

**What the thesis says.** Single-use inlining folds a pure binding "even when other pure bindings
stand between them", and "the language definition was amended to say so".

**What the documents say.**

- `backend.md:4310-4317`: the inlined initialiser must be an atom or a member chain, and every
  statement in between must be another such binding.
- `language.md:940-946`: the 2026-10-02 amendment licenses reordering *call-free* evaluations. It is
  used for a tail call's assignments, and "any call, pure or not — keeps its place".

**Consequence.** The worked example `n = List.length xs; ys = List.push xs 1; h ys n` →
`h(push(xs,1), xs.length)` is not something the optimiser does: the push is a call, so it blocks
the fold.

**The real hazard**, which A5 should name:

- `List.length` and `at` lower to the member reads `.length` and `[i]` (`core/List.beni:28-31,
  452-456`), so *after lowering* they look call-free;
- `backend.md:4296-4297` folds them because "nothing can change" a beni value;
- the tail-call reordering amendment (`language.md:844`) can do the same.

The thesis's sentence "all new arguments are evaluated before any parameter is rebound" is also
outdated.

### F27. More aliases come back from the library than the thesis lists

**Severity:** fidelity. Feeds F5 and F23.

**Hits:** §2.5 *Identity promises*, change 2.

**Missing from the thesis:**

- `cons` returns the base `b` itself when `o = 1` and `b[0] === x` (`core/List.beni:85-91`);
- `close` returns its second argument (F5);
- `drop` and `tail` return views (`core/List.beni:1749-1756`), not only a pattern's `rest`;
- `set` or `update` writing a `===` value, `swap xs i i`, `drop xs 0`, `pop []`, and `reverse` and
  the sorts below two elements (`backend.md:897-905`).

Each needs a `res` entry, or its promise dropped.

### F28. Smaller fidelity points

**Severity:** fidelity.

- **Specialisation.** Per-call-site specialisation does not exist; cloning was dropped
  (`backend.md:6728-6729`). §2.6 and §6.16 describe it. What exists is constant-argument
  propagation, and inlining of a private function called from one site (`backend.md:5402-5440`). The
  latter should be argued about, since it moves a body to its one call site.
- **Queue.** There is no `Queue` in core (`research/48`: "missing"). §2.2, Table 3.1 and §6.8 treat
  it as existing.
- **Subscriptions** are diffed once per render, not "after each update" (§2.2).
- **Churn ratio.** The figure "4.4–6.5 times as often as annotated ones" is misattributed. The ratios
  compare unannotated churn before and after the static-dispatch spike; annotated churn was 0, so no
  ratio against it exists (`research/19:33-40`).
- **Building loops** are mandatory today "for the stack alone" (`backend.md:3422-3427`), not for
  linearity. Under the rule, linearity becomes a reason again (F22).
- **Write sets and aliasing.** "Records no aliasing between two model paths" (§2.7, §8.4) is not
  stated in `write-sets.md`. Its domain tracks `Same(q)` moved to another path (`write-sets.md:541`).
  It has no fact for paths that already alias.
- **The direct platform's derived slots** can hold a list, which may be `model.todos` itself through
  `filter`'s identity promise (`browser-direct.md:458-481`). §2.7's "holds no … last-rendered list"
  is true of the instance arrays only.
- **Self tail calls.** The 2026-10-02 amendment lets a loop rebind a parameter early
  (`language.md:844`). §3.8 states the old rule.

### F29. The worked TEA examples rest on facts about TodoMVC that are not true

**Severity:** fidelity.

**Hits:** §9.5, A.1.

- **Platform.** browser-tea, not direct (F13).
- **`init`.** A top-level value (F7).
- **Encoding.** It happens inside the command (F14).
- **The helper.** `changed` needs `unused` (F15).

The TodoMVC claims in §1.2, §9.5 and §11.6 need to be withdrawn or re-derived.

### F30. The thesis describes the A4 hazard for list items inconsistently

**Severity:** fidelity / clarity.

**Hits:** Table 3.1 and P3.

- Table 3.1 classes the per-row instance item as "identity only".
- P3 says listener bodies "read the row's instance through the row's root node". That is a content
  read through the instance.
- When rows are themselves lists (`List (List Int)`), the "item" compared by `===` is the very array
  written in place. A4 says not to conclude "unchanged" from a list's identity, and per-row
  comparison is "on the row items".

*(guess)* It is probably safe, because the write set drives the row patch and identity only decides
moves. But the text contradicts itself, and the case needs a sentence.

---

## Citations

The citation checks were done against the authors' sources. Formulas and Table 2 of Emre et al. were
checked on rendered pages. Most quotes are verbatim. The following are not.

### F31. Misreadings that support an argument

**Severity:** citation error.

1. **Wrong Konečný paper.** The best-typing result that Aspinall, Hofmann and Konečný report in §6.2
   is Konečný **2003b**, "Typing with conditions and guarantees for functional in-place update"
   (TYPES 2002, LNCS 2646). It is not `konecny2003layered` (TLCA 2003). This affects §4.5 and §12,
   item 14.
2. **The Let condition in Aspinall et al., Fig. 8, is misread** (app-priorart). Only aspect 3 in the
   binding permits destruction in the body. Aspect 2 with a later destruction is marked ✗. The
   reads-before-writes analogy needs "aspect 3".
3. **Barendsen and Smetsers 1995, §6**, does not present `foldr` over a unique structure as a false
   error. Its derived `foldr` type leaves the list's attribute free. Only the `mark` example is a
   rejection.
4. **Marshall, Vollmer and Orchard** say the opposite of what app-priorart attributes to them: "there
   is no way to transform a non-unique value into a unique one". "A borrowed value *can* return to
   uniqueness" is the thesis's own liveness argument.
5. **de Vries et al. §7**: "every binding in a recursive group non-unique" is about letrec-bound
   *values*, not function parameters. The causal link to the arrow-subtyping restriction (app-priorart,
   §4.5) is not in either source.
6. **System Capybara.** It rejects the *parallel* use. It accepts `logSize(); v.push(4); logSize()`
   sequentially, which beni would reject, so the analogy in §4.6 inverts. The claim that capture
   systems "close the case only with declarations" (§6.1) is an overclaim: Capybara infers most
   permissions, including `ro`.
7. **Clarke et al.'s "cannot give a best solution"** is about design intent: the trivial owner is
   always a solution. It is not about the absence of least solutions. The rebuttal in §4.5 and
   Chapter 11 answers a different point. It should say that in beni the least solution *is* the
   intended one.

### F32. Overclaims and locator errors

**Severity:** citation error (minor).

- **Futhark's error index.** It offers a copy on *most* consumption errors, not "every one". §8.1.12
  offers no fix, and in §8.1.2 and §8.1.6 the copy is an alternative to an annotation.
- **Crichton et al. 2023.** "64–78 %" joins Table 1 (64 %, §2.4) with a §2.5 figure (78 %, which
  excludes the lifetime questions). Separately, §9.4's claim that "learners who can say why a program
  was rejected fix it less than half the time" adds a conditional that is not in the paper; 46 % is
  over all participants.
- **Emre et al.** The quote is §5's all-benchmarks statement, while "in tmux" is §1's. Table 2 is in
  §6. P2→P3 (7.87 % → 88.86 %) isolates subset-based analysis better than P1→P3.
- **Barendsen and Smetsers 1996.**
  - The Cons attributions are at the end of §6, not §7.
  - The marking rule precedes Def. 8.14 rather than being it.
  - "Show that the system has no principal uniqueness types" overstates "there is no 'Principal
    Uniqueness Type Theorem'". The paper declines to state such a theorem; it does not prove principal
    types absent.
- **Peters et al.** The list example is §4.1, not §4.2.
- **Aspinall et al.** "Read and not shared" and "read and shared with the result" are not verbatim.
  The abstract has "used read-only and not shared with the result".
- **Smetsers et al.** The term is "alternate arguments", not "alternates".
- **Wansbrough and Peyton Jones** solve poisoning by subsumption and argue against usage
  polymorphism. That is the opposite of the use made of them in Chapter 11 and app-priorart.
- **Deng et al.** A use effect covers writes too (`incr` writes), so "only reads" misdescribes it.
- **RFC 2094, problem case 3** is still unfixed in stable Rust (it needs Polonius). "Long rejected"
  implies it was fixed.
- **Polonius** is Matsakis's. Stjerna's thesis models it in Datalog.
- **OxCaml §6.4** speaks of a "complication", illustrated with locality. "The case every uniqueness
  system has found hardest … does not arise" (§1.1) overstates it. Only the *silent* capture goes
  away; explicit closures still need the lock rule, which is exactly where F2 lives.
- **Cann et al.** produced compiler statistics, not "the hand analysis" (§11.4).
- **Henriksen 2026** is forward-looking, not a "retrospective".

### F33. The rebuttal of Henriksen's 2026 warning is too quick

**Severity:** citation / fairness.

**Hits:** Chapter 11 and app-priorart (the warning "was about a type system reasoning about aliasing
— and this design is not a type system").

**Why it is too quick.** Henriksen's reasons apply equally to an inferred analysis:

- non-local errors;
- hard-to-explain rejections;
- interface churn.

Inferred summaries arguably make the non-locality *worse*, as §9.3 concedes.

**The thesis's own evidence.** The prototype study found that a sticky "shared" bit made the same
in-place decisions as a full count in every scenario (Chapter 11). That supports the run-time
alternative Henriksen recommends. The thesis should engage with it.

---

## Standalone quality and evaluation

### F34. The quantitative claims cite unpublished internal work with no method

**Severity:** standalone.

**Hits:** §1, §2.8, §3.8, A.2, §4.8.

**Uncited, with no method given:**

- the prototype study (0.14–0.47×, 0.44–0.48×, 1 514 → 706 bytes, 8.2×);
- the churn measurements;
- the direct platform's 0.127 ms against 0.113 ms swap;
- "a table application on the direct platform was found shipping…".

beni itself has no bibliography entry.

**What a referee cannot check:** the machine, the code transformed, the variance, or whether the
"static variant" implemented these rules (it did not have `excl`, classes or P5).

**Fix.** Add an appendix with the method and artefacts, or cite technical reports.

### F35. Project-process language and concepts used before definition

**Severity:** standalone / clarity.

**Process language:**

- "an adversarial reading of an earlier draft" (§1.3, §5.6);
- "a hidden flag" (§11.2);
- "the compiler's page tests", "by our count" (§6.9, §9.5);
- "change 5" used as a name before Chapter 10.

**Concepts used before they are defined:**

- **In Chapter 1:** hand over, the direct platform, derived values, the write-set analysis, and the
  same-shape rebuilds.
- **In Chapter 2:** A5 is referenced before Chapter 5.

**The "Terms" section** asserts "the checker is sound and incomplete, [so] every imprecision is a
false error, never a wrong answer" as a fact, before the argument that this review disputes.

### F36. Related work omits the closest static precedents

**Severity:** standalone (fairness and completeness). The catalogue lists each of these; the thesis
cites none of them.

- **Static in-place analyses for functional programs:**
  - Bloss, *Update analysis*, FPCA 1989;
  - Hudak's abstract reference counting;
  - Guzmán and Hudak's single-threaded λ-calculus;
  - Baker's *Unify and conquer*.
- **Observers.** Odersky's *Observers for linear types* is the type-system form of "reads before
  writes".
- **Escape analysis.** Park and Goldberg, *Escape analysis on lists*.
- **Sharing analysis.** Jones and Le Métayer's compile-time GC by sharing analysis.
- **Mazur's compile-time garbage collection for Mercury** (thesis, 2004). This is liveness-based
  structure reuse with modular interprocedural alias summaries in a pure language: the nearest prior
  art to Chapters 3 and 4, and it is in `references/ownership/pdf/`.
- **Languages.** Austral, Vale, Pony and Granule are in the catalogue and absent from the text. They
  are less central.

### F37. The evaluation plan cannot answer the question it poses

**Severity:** standalone (method).

**Hits:** Chapter 11.

1. **No soundness test at all.** The obvious experiment is missing. Build the in-place backend in a
   test mode, plus a *stale-read sanitiser*: the instrumented semantics of §5.2 as executable version
   stamps per array, trapping on a stale dereference. Run every accepted corpus program under both.
   The corpus's run hashes make this cheap. Every hole above would have been caught by it.
2. **Biased corpora.**
   - The core library and the test corpus were written by the compiler's authors.
   - The two applications avoid the nine writers.
   - None is "code people actually write" outside the project.
   - No external Elm corpus is ported, although beni has migration tooling.
3. **A hypothetical platform.** TEA programs are analysed "under the hand-over obligations", on a
   platform they do not run on (F13). The rejection rate measured is not the rate users would see.
4. **No thresholds.** "Decide on the numbers" has no pre-stated criterion, so no outcome can refute
   the proposal.
5. **Code written under the old semantics.** It measures rejection, not the cost of rewriting.
   Despite citing Crichton's learner studies, the plan measures nothing about people.

**Fix.**

- Add the differential and sanitiser runs as the first experiment.
- Add an external corpus.
- Pre-register thresholds.
- Report the rates per platform.

### F38. Presentation

**Severity:** standalone (presentation).

- **The `…` meta-ellipsis.** It collides with beni's spread operator: Table 3.2's
  `[ x₁, …, xₙ ]` reads as a spread, as does §3.9's `[ x, …defaults ]` against a meta-ellipsis.
  Use `⋯` or `x₁ … xₙ` without commas for the meta level.
- **The bracket summary notation in §3.7** has no grammar. For example,
  `[calls ≤1, supply owned if π₁ excl, need owned]` mixes facts and conditions. Give it a grammar,
  since the conditional facts are the hard part.
- **Bibliography.** `crichton2023grounded` should be PACMPL 7 (OOPSLA2), article 265. `rustc2026`
  lacks a `howpublished`.

---

## Minor

### F39. Small errors

- **`xs ++ xs`** fails **Disjoint**: the operand of the in-place push is also its source. It should
  appear in §9.1's list of rejected correct programs.
- **"Reads before writes are never sharing"** appears in the abstract and §1. It should be "a
  dereference that completes before the write is never sharing" (F10).
- **Table 3.2 and §3.8 disagree** on a `Js` operation: the first escapes its arguments forever, the
  second treats it as a read of every path.
- **`send` consumes its message** (P6, change 9). Under that rule, the beginner's
  `Cmd.perform (λsend → send (Saved model.todos))` already fails **Unescaped** at the `send`, because
  the capture is escaped. §9.1 and §7.2 attribute the error to a later edit instead.
- **Schema `write`/`print`** may hand a list's plain array to the host "as it is" (`schema.md`,
  §*Encoding*). If the output is a host value rather than a string, that is a `Js.from`-like escape
  the thesis does not list *(guess)*.
