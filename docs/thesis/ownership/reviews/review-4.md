# Referee report, round 4: "Edit in Place or Not at All"

**Reviewed:** the LaTeX sources in `docs/thesis/ownership/` at commit `c809837f9`, branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`), and the 130-page PDF for
numbering. Section numbers below are the PDF's.

**Checked against:**

- rounds 1–3 and their responses;
- design documents: `browser-direct.md` §4.1, §5.3–§5.5, §6.1–§6.4, §7.2, §7.4; `write-sets.md` §1.3's
  tag-read amendment and the row-visit amendment; `backend.md` §4 (the `[]` row, *A type of one
  constructor with one field is its field*);
- sources: `core/List.beni` (`foldl`, `foldr`), `core/Dict.beni` (`empty`, `update`), `core/Task.beni`
  (`retry`, `repeat`, `race`, `par`), `core/Js.beni`, `core/Debug.beni`;
- programs: `tests/corpus/browser/tea/TodoMVC.beni`, `examples/conduit/src/*.beni` (all `++`, spreads,
  commands and the opaque `Feed.Model`);
- citations spot-checked against `references/ownership/pdf/`: Emre et al. 2023 (the 85 % quote; tmux's
  7.87 % → 88.86 % for P2 → P3 in Table 2), Crichton et al. 2023 (46 %, §2.4), Xu et al. 2026 (Capybara,
  "rejects only the interfering use", §2.2), Brandon et al. 2026 (§4.4, Knaster–Tarski, Datalog). All
  four are accurate.

**Stance:** adversarial. *(guess)* marks a claim that depends on a reading the thesis leaves open, or on
practice outside the repository.

## Summary

| Severity | Count | Findings |
|---|---|---|
| Soundness hole | 5 | R4-F1 – R4-F5 |
| Prior repair failed (counted above) | — | R4-F5 is R3-F3's repair failing in part |
| False error on an idiom, common | 3 | R4-F6 – R4-F8 |
| Theory | 4 | R4-F9 – R4-F12 |
| Coherence | 3 | R4-F13 – R4-F15 |
| Fidelity | 2 | R4-F16, R4-F17 |
| Citation | 0 | — |
| Minor | 3 | R4-F18 – R4-F20 |

20 findings.

**Round-3 repairs (16).**

- **11 hold:** R3-F4 (view escapes), R3-F5 (path-precise captures), R3-F6 (by-id `map`), R3-F8 (`map`'s
  type fact), R3-F9 (`++` chains), R3-F10 (undo, cost stated), R3-F11 (Hoare order), R3-F12 (metric),
  R3-F13 (renderer and views described), R3-F15 (messages), R3-F16 (once values, `xs ++ []`).
  - Variants tried on R3-F5: field reads through helpers (`getRows m = m.rows`), a pattern match on a
    captured variant, a capture passed whole to `identity`, a capture re-read after a record update. All
    decided correctly.
  - Variants on R3-F4/P3: a bubbling handler reading a derived slot; a handler built from a `let` in
    `view`. Both are evaluated at the event on the direct platform.
- **5 hold in part:**
  - R3-F1 and R3-F2 (P7 and the element guards): sound for the checker's types, but not for the
    release representation (R4-F2).
  - R3-F3 (the send rule): it misses a payload the receiving arm itself writes in place (R4-F5), and its
    mechanism is not in the summary vocabulary (R4-F9).
  - R3-F7 (exclusivity through folds and `Dict.update`): the flag is carried, but T44's first step
    contradicts the top-level rule (R4-F6). The fold row the repair extended also has an unsound supply
    (R4-F1).
  - R3-F14 (Conduit): the trace misses that `Feed.Model` is opaque (R4-F3, R4-F15).

**Verdict: one more round.**

- **Round 3 said the first-order and closure core held; it does not quite.**
  - R4-F1 is an accepted program that observes a write through the checker's own rules: the folds'
    asserted rows supply the accumulator owned when the callback returned something it does not own.
  - R4-F3 and R4-F4 are two places where the path abstraction merges paths that `Disjoint` must keep
    apart: opaque records, and folded recursive types.
- **The renderer obligation holds against the checker's types, but not against `--release`'s
  representation (R4-F2).**
- **Each hole has a local fix; none needs a design change.** I would not call the core broken. But four
  of the five holes are in parts the thesis calls settled: the trusted rows, the path domain and P7.
  Another adversarial pass over the repaired rules is warranted.

---

## Soundness holes

### R4-F1. The folds' asserted rows supply the accumulator *owned* even when the callback returned a list it does not own

**Severity:** soundness hole, in the trusted surface as the thesis states it.

**Where:**

- §4.7, `foldl`'s row: `supply 2 owned π₂ ∪ g.res`. `foldr` has "the same row".
- §5.2 I2's justification: "the accumulator is the fold's own parameter on the first call and the
  callback's previous result afterwards, neither held by anything else".
- App. A.3 ("provenance π₂ and the callback's own previous result").

**The fault.** On every call after the first, the accumulator is `g`'s previous result. The row makes it
*owned* whatever `g.res` is. But `g.res` may name things that are not owned:

- the callback's first parameter, which the row supplies *borrowed* unless `g` consumes it;
- a capture (`◇`);
- `shared`.

The only edge is "W ∈ use_λ(2) ⇒ supply_f(2) = owned", and the row satisfies it unconditionally.

**Program 1** corrupts a top-level constant:

```
defaults = [ 0 ]

keepPositives : List Int → List Int
keepPositives xs = List.foldl xs [] (λx acc → if x < 0 then defaults else [ …acc, x ])

main = a = keepPositives [ -1, 5 ]          -- S_v [0, 5]
       List.length defaults                 -- S_v 1;  S_u 2
```

The trace:

- The lambda's `use(2) ∋ W`, and its `res = {π₂, shared}`.
- It is not once, because it consumes a parameter, not a capture.
- The edge holds, because `foldl` "supplies owned".
- `[]` is fresh, so `foldl`'s π₂ passes.
- **Accepted.**
- On the second iteration `acc` is `defaults`, and the push writes the top-level array.

**Program 2** writes an element of a live list:

```
bad : List (List Int) → List Int × List (List Int)
bad rows =
    r = List.foldl rows [] (λrow acc → if List.isEmpty acc then row else [ …acc, 0 ])
    ( r, rows )                             -- rows = [[1],[2]]: S_v [[1],[2]];  S_u [[1,0],[2]]
```

The trace:

- `g` does not consume 1, so `rows` is `borrowed; [*] aliased` and nothing demands it.
- On the second iteration `acc` is `rows[0]`, supplied "owned", and the push writes it.
- **Accepted.**

The same goes for a callback that returns a capture (`… else ys`, with `ys` read after the fold). No
program in Table 6.1 has this shape. T15 (`pick`) tests the *result*'s aliasing, never the next
iteration's *supply*.

**Why inference would not do this.** `foldlFrom`'s body passes `func (at a i) acc` back as `acc`. An
inferred supply bit would be owned only when `g.res`'s maximal provenances are `fresh`, the callback's
own π₂, or a π₁ that was itself supplied owned. The asserted row drops that guard.

**Fix.**

- Make the bit guarded: `supply 2 owned π₂ ∪ g.res if g.res ⊆ {fresh, π₂, π₁ when supply 1 owned};
  borrowed otherwise`. The `xres` guard already has this shape.
- Fix I2's sentence and App. A.3.
- Add the two programs as T46.
- Re-check every asserted row that loops a callback's result back into a supply:
  - `foldr`, `Dict.foldl`/`foldr`, if they are ever asserted rather than inferred;
  - `Task.repeat`, `Task.retry` and `Schedule`, if their results feed the next call.

### R4-F2. Under `--release`, P7(f)/(g) keep the element guard for a list whose elements are unboxed wrappers of edited lists

**Severity:** soundness hole, in the renderer obligation, release builds only.

**Where:**

- §7.9 *P7 precisely*. IP is "model paths … at which `update`'s published summary has W".
- (f) and (g) drop the element guard only "for a list whose element path is in IP_κ".
- The argument's first half: "records, tuples and constructors are never written in place and are
  rebuilt by every arm that changes them".
- §9.7.

**The fact.** `backend.md` §4, *A type of one constructor with one field is its field*: under
`--release`, `Column (List Card)` *is* its list. The thesis knows this, since it is the type fact in
`map`'s row (§3.8), but P7 does not use it.

**Program** (a board of columns):

```
type Column = Column (List Card)

AddCard i c → { model | cols = List.update model.cols i (λ(Column cards) → Column [ …cards, c ]) }
```

The trace:

- **The checker:** `update` writes `cols` and `cols[*].Column#0`, so both are in IP. `cols[*]`, the
  constructor, is not; its callback keeps shape.
- **Development build:**
  - (f) keeps the guard `get(cols, i) !== insts[i].it` for `cols[*]`.
  - `Column` is a fresh object, so the guard passes and the row is patched.
- **`--release`:**
  - the element *is* the array, pushed in place, so `get(cols, i) === insts[i].it`;
  - the script skips the row, and the new card never appears.
- The identity walk of (g) has the same fault for a by-id `map` over such columns.

The two builds print different pages. That breaks both Theorem 6.1 and the promise that a release build
behaves as the development build does.

**Fix.**

- State A10 for representations: a path through an unboxed constructor step denotes the same run-time
  object as its field.
- Define IP and "may hold an IP_κ cell" modulo that identification, so that `cols[*] ≡ cols[*].Column#0`
  in release.
- Alternatively, do not unbox a type whose field path is in IP.
- Correct the first half of the argument: a constructor is not rebuilt when it is erased.

### R4-F3. An opaque type merges its fields into one path, so the `Disjoint` a callee needs between two of them cannot be discharged

**Severity:** soundness hole *(the reading depends on how a summary over internal paths is published;
T19 says it is published over ⟨T⟩)*.

**Where:**

- §3.1 (the opaque step ⟨T⟩ reaches "every cell inside it");
- §3.10 (a parameter path's `Disjoint` "against the caller's other paths of the same argument" is
  discharged at the callers);
- §3.11, where `excl` is defined only for list positions and folded recursive paths;
- T19.

**Program:**

```
-- module Pair
pub opaque type Pair = Pair { a : List Int, b : List Int }
pub fromList : List Int → Pair
fromList xs = Pair { a = xs, b = xs }
pub pushA : Pair, Int → Pair
pushA (Pair p) x = Pair { p | a = [ …p.a, x ] }
pub getB : Pair → List Int
getB (Pair p) = p.b

-- another module
List.length (Pair.getB (Pair.pushA (Pair.fromList [ 1 ]) 2))      -- S_v 1;  S_u 2
```

The trace:

- **Inside `Pair`:** `pushA` demands π₁.Pair#0.a. `Disjoint` between `.a` and `.b` is left to callers,
  which is correct there.
- **What the importer sees:**
  - `fromList`'s result is ⟨Pair⟩ ↦ {fresh₁};
  - `pushA`'s summary is W at π₁⟨Pair⟩;
  - there is no "other path of the same argument" to check, so the call is accepted.

The case is not exotic: elm-spa-example's `Feed.Model`, which Conduit copies, is an opaque record with
two lists, `errors` and `articles`, and `Feed.update` appends to `errors` in place. Within one module,
two fields of one record are kept apart by the caller's `Disjoint`. Across an opaque boundary nothing
keeps them apart.

**Fix.**

- When a summary is published over ⟨T⟩, an internal `Disjoint` obligation between two paths that fold
  into ⟨T⟩ becomes `xreq(⟨T⟩)`, condition 2 of `excl` ("within a position, distinct paths hold distinct
  cells").
- Every function returning `T` publishes `xres(⟨T⟩)`.
- Extend §3.11 to opaque steps. Re-trace Conduit's `Feed` through it: `Feed.init` builds `errors = []`
  and takes `articles` from the payload, so it is exclusive.
- Add the program to Table 6.1.

### R4-F4. Folding a recursive type puts two levels at one path, and neither `Disjoint` nor prefix liveness separates them

**Severity:** soundness hole under the literal reading; under the other reading, a false error on every
edit of a tree node *(guess about which reading is intended)*.

**Where:**

- §3.1 (folding: "the steps since the first visit are dropped … the exclusive-contents flag … recovers
  it for the same edits");
- §3.9 (a use reads `q′` with `q′ ⊑ q` or `q ⊑ q′`, *prefix order*);
- §3.10 (`Disjoint` over *other* paths).

**Program:**

```
type Tree = Node { items : List Int, kids : List Tree }

addRoot (Node t) = Node { t | items = [ …t.items, 1 ] }
firstKidItems (Node t) = case t.kids of
    [ Node k, …_ ] → k.items
    [] → []

xs = [ 0 ]   -- local
t = Node { items = xs, kids = [ Node { items = xs, kids = [] } ] }
firstKidItems (addRoot t)          -- S_v [0];  S_u [0, 1]
```

The trace:

- The inner node's `.kids[*].Node#0.items` folds to `.Node#0.items`. So `A(t)@.items = {site_xs}` and
  `A(t)@.kids = {site_kids}`.
- At the call, `Disjoint` compares `.items` with `.kids` only. It passes.
- Inside `addRoot`, `t.kids` is used after the demand. But `.kids` is not a prefix of `.items`, so the
  holder `(t, .items)` is dead.
- **Accepted.** The push is seen through the kid.
- **Under a fold-aware reading,** `.kids` reaches every path again, and every record update of a node
  that keeps its children fails `Dead`. That would reject outline and comment-tree editors.

The text says the flag "recovers" what folding loses. But no rule makes a demand on a fold
representative require `excl`, as `bumpHead`'s `xreq` does for `[*]`.

**Fix.**

- A demand on a path that is the representative of a fold records `xreq` across levels: no cell
  reachable at two unfoldings.
- Constructions of the recursive type set and clear the flag as for lists.
- State which reading of "meets" liveness uses.
- Add the program, and a tree-editing idiom, to Table 6.1.

### R4-F5. The send rule (Change 7) misses a payload the receiving arm writes in place without storing it — R3-F3's repair, in part

**Severity:** soundness hole as worded; prior repair failed in part.

**Where:**

- Change 7: "a demand on its payload at every path the payload may carry into a *model path* that some
  arm of `update` writes in place".
- P6, *Program senders*.

The Entry lemma promises more: "every message payload an arm writes in place is unique when the arm
runs". T34's wording also implies the second condition ("no arm edits `Got`'s payload in place, *and*
the paths …").

**Program:**

```
Got rows → ( { model | total = List.length [ …rows, 0 ] }, Cmd.none )

Cmd.perform λsend →
    rows = fetchRows ⊤
    send (Got rows)
    Task.sleep (Time.millis 10)
    Log.info (String.fromInt (List.length rows))     -- S_v n;  S_u n + 1
```

The trace:

- `update` has W on π₁.Got#0.
- The payload reaches only `total`, an `Int`, so it reaches no model path at all. By Change 7 the send
  only aliases.
- Neither P6's view-event clause nor `P5` discharges W on the message parameter.

**Fix.** A send is a demand on its payload at every path the payload may carry either into a path that
`update` writes in place in its *message* parameter, or into a model path written in place. State it so
in Change 7, P6 and the lemma, and add the program to Table 6.1.

---

## False errors on idioms

### R4-F6. `Dict.empty` is a top-level value, so the T44 trace contradicts the transfer rule; and `Dict.update` consumes its dictionary even when the callback only reads

**Severity:** false error, common *(on frequency: `Dict.empty` in `init` is ubiquitous; dictionaries of
lists or of records holding lists are less so)*. Also coherence.

**Where:**

- Table 3.3: a top-level value has "every tracked path ↦ {shared(v)}".
- App. A.5, step 1: "`foldl`'s accumulator is `Dict.empty`, a value with no cell: exclusive".
- T44.
- §7.4, `Dict.update`'s row: `Dict k v [consumed+aliased; …]`, unconditionally.

**The fact.** `core/Dict.beni`: `empty = Dict Leaf` is a top-level value. For `Dict k (List a)`, its path
⟨Dict⟩.v is tracked, so by Table 3.3 it is `shared`. Two consequences follow.

- **T44 and App. A.5 are rejected by `Unescaped` at the first `Dict.update`.** They are not accepted as
  claimed.
- **This program is rejected:**

  ```
  init ⊤ = { tags = Dict.empty }                       -- Dict String (List String)
  AddTag k t → { model | tags = Dict.update model.tags k (λ_ → Just [ t ]) }
  ```

  - The callback consumes nothing.
  - But `Dict.update` is `consumed` unconditionally, so it demands ⟨Dict⟩.v, which holds
    `shared(empty)`.
  - Even with the first point fixed, `( Dict.update d k f, Dict.size d )` with a read-only `f` fails
    `Dead`, and `model.tags⟨Dict⟩.v` enters IP for nothing.

**Fix.**

- A top-level value's abstract value is its definition's, with each *site* renamed `shared(v)`. An empty
  path stays ∅, which matches §3.4's "∅ means provably no cell".
- Make `Dict.update`'s row `consumed+aliased if g consumes 1; aliased otherwise`, as `foldl`'s `b`
  already is.
- Re-trace T44.

### R4-F7. An identity promise stored in another model field aliases its source forever

**Severity:** false error, common *(guess on frequency: a filtered or "visible" copy kept in the model is
discouraged by Elm's guide, but frequent in real Elm search and list UIs)*.

**Where:**

- §3.8 and §7.2: the promises cost precision "only where the source is used again, which the idioms do
  not do";
- O2's recommendation;
- Table 5.2.

**Program:**

```
Loaded xs  → { model | all = xs, visible = xs }
Search q   → { model | query = q, visible = List.filter model.all (matches q) }
Add x      → { model | all = [ …model.all, x ] }
```

The trace:

- `filter`'s `res = {fresh, π₁}` makes `update`'s `res(.visible) ∋ π₂.all`.
- The entry fixpoint therefore lets `all` and `visible` hold one cell at every entry, so `Add` fails
  `Disjoint` at every dispatch.
- The copy in `Loaded` does not help, because `Search`'s promise re-aliases the two paths.
- The only fix is `List.copy (List.filter …)` in every arm that stores a filtered list. That is an O(n)
  copy for a sharing that occurs only when the filter dropped nothing.

The source is not "read again" here. It is *kept at another model path*, which the entry protocol turns
into permanent aliasing. The same holds for `List.map` with an identity promise (`a = b`) and for `sort`.

**Fix.**

- Add the form to Table 5.2 with its own tag (*identity promise across the entry*).
- Count it in §12.4.
- Weigh it in O2.
- A relational entry (open question 16) would also remove it. Say so.

### R4-F8. A top-level `initialModel` is probably the commonest rejection in the external corpus, and the thesis does not name it

**Severity:** false error, common *(guess: on the frequency of `initialModel : Model` plus
`init _ = ( initialModel, Cmd.none )` in Elm applications)*.

**Where:** Change 4; §12.3's porting rule ("`init` becomes a function"); Table 5.2's *position* row.

**The fault.** Making `init` a function does not help when it returns a top-level record: every list in
`initialModel` is `shared`, and the program's first in-place edit of any of them is rejected (T21's
shape). The port described in §12.3 is "mechanical"; it adds `⊤` to `init` and leaves `initialModel`
alone. So a corpus of Elm applications will meet this at the first append in most programs that use the
pattern. The pooled rate in decision 2(a) includes position rejections, so this one pattern could decide
adoption.

**Fix.**

- Name the pattern in Table 5.2 and §5.4.
- Report it on its own line in §12.4.
- Say whether the port rewrites it, which would be a `beni fmt` migration that inlines a top-level model
  used only by `init`. The criterion must not be met or failed by the porting rule.
- If the owner wants it, an option worth stating: a top-level value of a type that holds a list is
  evaluated per use, as a zero-argument function would be. That is construction, not a copy of a live
  list, so Change 2 does not forbid it. It changes the cost model of constants.

---

## Theory

### R4-F9. Change 7's mechanism, "each send site's payload as a provenance of its own", has no place in the summary vocabulary, and its guards must survive to the program constructor

**Severity:** theory, and R3-F3's repair in part.

**Where:** Change 7, P6, the Entry lemma; §3.7's `Prov` grammar; §3.7 "no guard survives into the facts
of a caller that does not itself take the guarded value as a parameter"; §4.10 "nothing is
whole-program".

**The gap.**

- **The send site is out of reach.** A `send` sits in a command body, which may be in another module
  (`Feed`, `Api`, a platform's `Cmd.task`). It is stored in an opaque `Cmd`, re-tagged by `Cmd.map`,
  merged by `Cmd.batch`, and reaches `update`'s π₁ through the runtime. For the entry fixpoint to name
  "the payload of send site s" and check "dead after the send", the following must be published, per
  command-returning function:
  - which send sites its commands may run;
  - each payload's provenance;
  - whether the payload is dead after the send.

  `Prov` has no send-site element, and summaries have no field for "the commands this result may run".
- **The demand's guard cannot be resolved where the send is written.** The guard is "this payload
  reaches a path written in place". Only the module that calls the program constructor can decide it. So
  the guard must survive through every intermediate summary, contrary to §3.7.

**Fix.**

- Add to summaries a component under ⟨Cmd⟩: the set of (send site, payload provenance, dead-after-send
  bit), carried through `Cmd.map` and `Cmd.batch` rows.
- State the bound on its size.
- Admit that the entry check is whole-program over these sites, as `Cmd.task`'s fresh payload already
  is. Alternatively, restrict the demand to sends whose payload's liveness the sending module can
  decide locally: say "dead after the send" is published, and "reaches IP" is decided at the
  constructor.
- Add the item to §14.3.

### R4-F10. A12 is derivable rather than assumed

**Severity:** theory (a positive finding: one fewer assumption).

**Where:** A12; §7.9 *How write sets provide it*; §9.4; §14.3 item 2.

**The argument.**

- The write-set analysis is sound for the *value* semantics: a path whose value is not `===` after the
  arm is named.
- By Lemma 6.1's correspondence, applied by induction on dispatches, the following holds at the current
  dispatch. Every in-place write of S_u at a path corresponds to S_v building a new array at that path:
  the `c_k → c_{k+1}` of §6.2.
- So the write set, computed once for the program and valid for S_v, names every path S_u writes in
  place.
- S_v's identity promises are harmless:
  - where S_v returns its input (`xs ++ []`, `swap i i`, an out-of-range `update`), S_u writes no new
    content;
  - where S_u's `map` returns its input after in-place element edits, S_v built new elements and a new
    list, and the write set names them.

The restatement over contents is still a cleaner contract. But the thesis need not leave A12 as an open
question ("as we expect … but have not argued"). It can prove it from the write-set analysis's existing
statement, inside the main induction. *(guess: provided no write-set rule concludes `Same` from a fact
that holds only in S_u, and I found none.)*

**Fix.** Replace A12 with a lemma and its proof sketch. Keep the run-time check as a test.

### R4-F11. P7 mixes entry paths with current paths, and (f)/(g) are phrased for model paths only

**Severity:** theory.

**Where:** §7.9 *P7 precisely*.

**What is mixed.**

- **The two path sets.** IP is read from `update`'s *parameter* paths, `W ∈ use(π₂.p)`. "May hold an
  IP_κ cell" is read from `view`'s analysis of the *new* model.
  - An arm can move a cell between paths: `{ model | a = [ …model.b, x ], b = [] }`. Old `b`'s cell is
    written and is now at `a`, which is not in IP.
  - The argument still goes through: `Disjoint` at entry means the cached value at `a` is a different
    cell. But the text should say so.
- **The phrasing of (f)/(g).** They speak of "a list whose element path is in IP_κ". That has no meaning
  for a `<For>` over a *derived* list, such as `Dict.values model.groups` with `Dict.update` writing
  groups in place, or a filter of a grid. Both reach the rows through the reconciler.

**Fix.**

- Define IP_κ as a set of entry cells.
- Phrase (f) and (g) as "a list whose elements may hold an IP_κ cell".
- Add one sentence on moved cells.

### R4-F12. The direct platform's own in-place slice also writes *records* in place, which falsifies P7's first half

**Severity:** theory/coherence.

**Where:**

- §7.9's first half ("records … are never written in place");
- §9.7, which puts records-in-place out of scope and says they "need a stronger form of A4";
- `browser-direct.md` §7.4. The same slice S7 that this thesis's in-place lists would join assigns
  `m.a.b.c = v` on owned paths. It then says that "a written field's record may be the same object as
  before".

**The gap.** If both land together, as the platform's plan has them, a record holding no IP list may
keep its identity while its content changes. P7's soundness argument then rests on a premise the
platform's own design withdraws.

The platform's own rule ("a group never decides 'unchanged' by the identity of an object on an
in-place-written path") is the stronger A4 that §9.7 asks for. But the thesis neither cites it nor
includes record cells in IP.

**Fix.**

- Make IP include the record paths the platform writes in place under §7.4, or state that the two
  in-place mechanisms cannot be adopted together until P7 covers both.
- Add the item to §14.3.

---

## Coherence

### R4-F13. The evaluation's test mode runs the template runtime in place, which rule 7 and Theorem 6.1 exclude

**Severity:** coherence, but it would make the first decision criterion fire on correct programs.

**Where:**

- §12.1: the in-place backend is linked "into programs for every target, Node and the template runtime
  included".
- §6.1: on a persistent target S_u is S_v.
- A4: the template runtime "skips by identity everywhere".
- Decision 1: "If the differential run traps … or the two traces differ, the rule is not adopted".

**The fault.** Under the test mode, TodoMVC on the template runtime is R3-F1's program again. Its
`hidden={List.isEmpty model.todos}` grouped value is skipped by identity after the in-place append, so
the traces differ on an accepted program.

**Fix.** Run the test mode in place on Node and the direct platform only. On the template runtime, run S_v
plus the sanitiser's version counting (which needs no in-place writes), or not at all.

### R4-F14. "A generic body cannot write a value of type `a`" is contradicted by `where` methods

**Severity:** coherence.

**Where:** §4.8 ("there is no demand of type `a → a`") and §7.3 ("which is the right answer"). Both
sections also say that any non-well-known method is a class instantiated from the dispatch table.

**The fault.** `bump x = x.push 1` with `where a.push : a, Int → a` writes `x` when `a = List Int`. The
evidence is `List.push`.

**Fix.**

- Say that a generic body writes through a method only, under a class guard.
- Say that its side conditions are guarded, and checked where the evidence is bound.
- Say where the message points: to the generic body's line, from the caller's instantiation.

### R4-F15. Stale or inaccurate claims about the examples and earlier rounds

**Severity:** coherence.

- **Conclusion and App. A.** "Three adversarial readings found no accepted program that observes a write
  through the checker's own rules." R4-F1 is one, and R4-F3 and R4-F4 are two more under the stated
  rules.
- **§5.5 on Conduit's `++`.**
  - The thesis counts "thirteen `++` on lists … Six of the `++` have a left operand built in the same
    function". I count 14 list constructions (16 `++` operators):
    - `Article.beni` 176/179/182;
    - `Api.beni` 131;
    - `Home.beni` 228, a chain of two;
    - `Settings.beni` 200, a chain of two;
    - `Editor.beni` 223;
    - the seven `errors` appends.
  - "Seven are `model.errors ++ …` in the arms of three page modules". The three modules are
    `ArticlePage`, `ProfilePage` and `Feed`, and `Feed` is not a page: it is the opaque component of
    R4-F3, nested in `Home`'s model.
  - "Each page's `init` creates `[]`" holds for `Feed.init` too, but that path is under ⟨Feed.Model⟩.
- **§10.7.** "Neither needs anything of the direct platform's renderer beyond what it already does".
  That is right only if P2 is already so, which R4-F16 questions.

**Fix.** Correct the counts. Re-trace `Feed` through R4-F3's fix. Weaken the conclusion's claim.

---

## Fidelity

### R4-F16. P2 is not "already so": the direct platform reads `old` after the arm

**Severity:** fidelity.

**Where:** P2; Table 7.2, which omits P2; `browser-direct.md` §4.1 step 0. That step reads: "a handler
whose scripts need the model before the arm — an index symbol that reads it, a derived value's old
input — binds `const old = model` first". Step 3's scripts then read it, *after* the arm.

**The fault.** Reads of `old`'s scalars are harmless. But a derived value's old *list* input, read after
an in-place arm, is the new contents. P2 says this "must not" be generated. Table 7.2 lists neither P2
nor this change among the pieces "to be added".

**Fix.** Add a row for P2 to Table 7.2: step 0 must copy out scalars (or `List.length`) before the arm,
never hold an old list. Say whether any current key needs an old list.

### R4-F17. The structure-hole rule is paraphrased differently from `browser-direct.md` §5.3

**Severity:** fidelity *(guess on consequence)*.

**Where:** §2.7 says "a hole that shows a structure is written whenever its key writes it". Table 3.1's
group-slot row ("a leaf value: a scalar") and P7(a)'s "Already so" lean on that paraphrase.

**The source.** §5.3 says it is "written when its key writes it (**a `value` write at or above its
path**) and compared by identity only where this document says identity holds". So a structure slot may
hold a structure.

**The consequence.** Take a model field of type `List (Html Msg)` shown whole, `{model.extras}`, and
appended in place with `[ …model.extras, <li/> ]`. Its key's write is an `append`, not a `value`, and the
slot's identity is unchanged. Whether that hole runs is not what (a) asserts.

**Fix.**

- Quote §5.3 exactly.
- Say what a structure hole does for list tags under in-place writes: write on any conflicting write,
  or compile the hole as a `<For>`.
- Correct Table 3.1's group-slot row.

---

## Minor

### R4-F18. The "limit of the checker" message uses `Js.to` in application code

§8.2. `core/Js.beni`: "Only a platform package or core may import this module … `js_outside_platform`".
An application meets ⊤ through a platform function with no row, or through `Task.join`. Use one of those.

### R4-F19. Chapter 10's first paragraph states the cost guarantee without rule 7's scope

"This rule buys a guarantee about cost: an edit the program writes is performed in place … `set` … in
O(1)". This holds on the direct platform only. §10.6 says so, but the opening and §10.1's "the fix is
one call, `List.copy`, in every case" read as universal. The second claim is not true for commands and
once closures, where the fix is a reordering or a copy inside a callback. Scope both sentences.

### R4-F20. P7(f) drops the swap's "data moved" guard without citing what makes that safe

`browser-direct.md` §6.2 gives that guard an idempotence role: "rows an arm's mount built from the new
model … left alone". Dropping it is safe because §4.1(b) says an arm mounted earlier in the dispatch "is
not visited again". Cite that, or a reader will think (f) re-swaps freshly mounted rows.

---

## A12 and the open questions (§14.3)

- **A12 is stated honestly:**
  - as an assumption;
  - with the reason it is not in the write-set analysis's statement;
  - with a run-time net.

  But it is provable (R4-F10).
- **Missing from the open list:**
  - how a summary over an opaque step carries internal `Disjoint` (R4-F3);
  - whether a demand on a fold representative needs `excl`, and which reading of "meets" liveness uses
    (R4-F4);
  - the modular mechanism of send-site provenance (R4-F9);
  - unboxed wrappers in P7 (R4-F2);
  - the interaction with the platform's own record-in-place slice (R4-F12);
  - the frequency of `initialModel` (R4-F8);
  - identity promises held across the entry (R4-F7).
- **Item 16 (relational entry)** should name R4-F7 as a second customer.

## Idiom claims, re-checked against the code

- **TodoMVC** (`tests/corpus/browser/tea/TodoMVC.beni`): the thesis's account matches the file.
  - The one demand is the Enter arm's `model.todos ++ [ … ]`.
  - `Toggle` and `commit` use `map` with an identity promise, stored back at the same path, which is
    harmless.
  - `save` captures the list.
  - `init` is a value.
- **Conduit:** the commands read single fields, as claimed. The comment prepend's payload is a fresh
  temporary. Accepted, modulo R4-F3 (`Feed.Model`) and the counts in R4-F15.
- **The by-id `map` (I6), `map … ++ […]` in `view` (I4) and `++` chains (I1):** accepted by the rules as
  stated. These shapes are unaffected by R4-F1's fix, which only rejects folds that return a non-owned
  list as the next accumulator.
- **Idiomatic code the thesis does not cover that would be rejected:**
  - a stored filtered copy (R4-F7);
  - `initialModel` (R4-F8);
  - dictionaries of lists started from `Dict.empty` (R4-F6);
  - with R4-F4's fold-aware reading, edits of a tree node's own list while its children are kept.
