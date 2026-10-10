# Referee report, round 3: "Edit in Place or Not at All"

**Reviewed:** the LaTeX sources in `docs/thesis/ownership/` at commit `0c2a082db`, branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`), and the 117-page PDF for
numbering. Section numbers below are the PDF's.

**Checked against:**

- rounds 1 and 2: `ownership-thesis-review.md`, `ownership-thesis-response.md`,
  `ownership-thesis-review-2.md`, `ownership-thesis-response-2.md`;
- design documents: `language.md` §6.8 (list syntax, its lowering, costs), §11.9 (row skip and row
  inputs), §11.11 (what a render may skip, including the 2026-10-04 grouped-value rule), §11.12 (identity,
  and the view promise); `backend.md` §4, §15.4–§15.8; `boundary.md` §9.8.4; `browser-direct.md` §6.2,
  §7.4; `write-sets.md` §2;
- sources: `core/List.beni`, `core/Dict.beni`, `core/Result.beni`, `core/Task.beni`,
  `platforms/browser/Rt.beni`, `platforms/browser/Cmd.beni`;
- programs: `tests/corpus/browser/tea/TodoMVC.beni`, `tests/corpus/browser/tea/ListenerOrder.beni`,
  `tests/corpus/browser/dom/KeyedEnds.beni`, `tests/corpus/browser/dom/KeyedMoves.beni`,
  `tests/corpus/run/ListPrependDeep.beni`, `tests/corpus/run/Int32Keys.beni`,
  `tests/corpus/run/PhantomAliasUnifiesByExpansion.beni`, `bench/arrays/ops/elm/Ops.beni`,
  `bench/corpus/NotesApp.beni`, `examples/conduit/src/*.beni`;
- citations spot-checked against `references/ownership/`: Barendsen & Smetsers 1996 §8 (the letrec
  quote, Def. 8.14), de Vries et al. 2007 §6 (the `newArray` quote), Peters et al. 2026 (both crossing
  quotes), Wei et al. 2024 (the `id` typing). All four are accurate.

**Stance:** adversarial. *(guess)* marks a claim that depends on a reading the thesis leaves open, or on
practice outside the repository; the finding says which.

## Summary

| Severity | Count | Findings |
|---|---|---|
| Soundness hole | 4 | R3-F1 – R3-F4 |
| Prior repair failed | 1 | R3-F3 (also counted above: R2-F12's repair) |
| False error on an idiom, common | 4 | R3-F5 – R3-F8 |
| False error on an idiom, rare | 2 | R3-F9, R3-F10 |
| Theory | 2 | R3-F11, R3-F12 |
| Fidelity | 2 | R3-F13, R3-F14 |
| Minor | 2 | R3-F15, R3-F16 |

R3-F3 is both a soundness hole and a failed repair; it is counted once, as a soundness hole, in the totals
below (16 findings).

**Prior repairs.**

- **All 34 programs of Table 6.1** are decided as the table says. I re-traced T1–T34 through the current
  rules, construction rule included.
- **Round 2's 19 repair items** (R2-F1 to R2-F13, R2-F15 to R2-F20):
  - **12 hold:** F2, F3, F4, F5, F6, F7, F10, F15, F16, F17, F18, F20.
  - **6 hold in part:**
    - F1: the entry protocol leaves out the escapes `view` makes (R3-F4).
    - F8: `Dict.update` keeps no `excl` (R3-F7).
    - F9: the lattice is mis-stated (R3-F11).
    - F11: an unconditional `π₁` in `res` causes false errors (R3-F8).
    - F13: Change 8 says it touches no recorded decision (R3-F1).
    - F19: the main metric's idiom set is circular (R3-F12).
  - **1 fails:** F12's replacement, Change 7 (R3-F3).

**One-line variants of R2-F1, R2-F2 and R2-F3.**

- **R2-F2 (closure-held results) holds** under every variant I tried:
  - a closure returning a field of a capture;
  - a closure returning a captured closure's result;
  - a closure called through a list of closures, a placeholder, or `apply`;
  - `excl` through `map`, `repeat`, `initialize` and `Dict.fromList`.
- **R2-F3 (once closures and the runtime) holds**, apart from the wording "at ε" (R3-F16).
- **R2-F1 (escapes in summaries) holds as vocabulary.** Its variants break where the entry protocol
  consults escapes and sends:
  - the escapes `view` makes are not consulted (R3-F4);
  - a send whose payload is stored and edited later (R3-F3).

**Verdict: one more round.** The first-order and closure core still holds: I found no accepted program
that observes a write through the checker's own rules. All four soundness holes sit at the platform
boundary, in what the renderer and the entry protocol are said to guarantee:

- R3-F1: the renderer obligation P7 is too narrow for the template runtime as specified;
- R3-F2: the direct platform does not meet A4 for in-place element edits;
- R3-F3: the send rule is inconsistent;
- R3-F4: P5 omits the escapes `view` makes.

Separately, three "must pass" claims fail as written:

- I6, the record edit and the dictionary grouping (R3-F7);
- the TodoMVC assessment (R3-F1);
- the Conduit assessment (R3-F5).

The thesis's own standard is that "a single false error in a common idiom would be met by every user"
(§10.2). Against it:

- capture of whole variables (R3-F5) is common;
- the by-id `map` edit (R3-F6) is common;
- so is the identity promise of `map` (R3-F8).

---

## Soundness holes

### R3-F1. P7 covers only `<For>`'s list skip, but the template runtime and `language.md` skip far more by identity; TodoMVC is wrong under P7 as stated

**Severity:** soundness hole. P7 is the obligation that A4 and the *Entry* lemma rest on. It also falsifies
§5.5's TodoMVC verdict and a recorded-decision claim in Change 8.

**Where:**

- §7.9, P7: "compiles every markup site that may show such a list without the skip: its rows are
  walked, each compared by its own item";
- Table 3.1, the holders row, which names only "the template runtime's last list of a `<For>`, and its
  row items";
- §2.7, which describes the runtime as skipping only a `<For>` and a row;
- A4 ("*Not kept* by the template runtime as it stands, which skips a `<For>`…");
- Change 8: "Recorded decisions it touches: None";
- §5.5 and App. A.1, which say TodoMVC is "accepted with P7".

**The fact.** The template runtime decides "unchanged" by identity in at least five more places, all
normative or as built:

1. **Root values and `let`s are grouped.** `language.md` §11.11 (amended 2026-10-04, as built in
   `backend.md` §15.4) says: "A value of a markup root is evaluated … in a later render only when one of
   the paths it reads is not `===` to what it was". It adds: "a `let` read only by markup … `shown = top
   model.items` … is computed again only when `model.items` is another list."
2. **Helper calls and components** are skipped when their arguments are `===` (§11.11, *skipped calls*;
   `backend.md` §15.4 "A skipped group restates its slots").
3. **Row inputs.** A row is skipped when its item and every input are `===`, and its inputs are
   enclosing-scope fields such as `model.selected` (`language.md` §11.9; `Rt.beni` `sameInputs`, used
   by `forKeyed` and `forPosition`).
4. **`Show` bodies** are skipped when key, value and inputs are `===` (`backend.md` §15.5).
5. **`same(a, b)`.** It counts two views "over the same backing array at the same offset" as equal
   (`backend.md` §15 *Identity*; `language.md` §11.12's view promise; and `write-sets.md` §2's
   exception). A push through a view makes a new header with the same base and offset and a greater
   length (§7.11), and `same` calls it unchanged.

**Program.** This is TodoMVC exactly as it stands in `tests/corpus/browser/tea/TodoMVC.beni`, with
`init` made a function and `save` encoding first: the fixes §5.5 says suffice.

```
view model =
    left = List.length (List.filter model.todos λt → not t.completed)
    <section class="todoapp">
        …
        <section class="main" hidden={List.isEmpty model.todos}> … </section>
        <footer class="footer" hidden={List.isEmpty model.todos}>
            <strong>{String.fromInt left}</strong> …
            <button hidden={left == List.length model.todos} …>
```

1. Start empty and type a todo. The Enter arm appends in place: `model.todos ++ [ new ]`.
2. The `<For>`'s skip is compiled away by P7.
3. But `left`, both `hidden={List.isEmpty model.todos}` and `hidden={left == …}` read only the path
   `model.todos`, which is `===` to its old value. By §11.11 none of them is evaluated again.
4. So the `main` section stays hidden and the count stays at 0.

Value semantics shows the new todo. The traces differ in a DOM write, which Theorem 6.1 counts as an
observation.

**A row-input variant:**

```
<For each={model.rows}>{λr → <tr class={if List.member r.id model.picked then "on" else ""}>…}</For>
Pick id → { model | picked = [ id, …model.picked ] }
```

- Every row's input `model.picked` is `===` to last render's (a prepend returns a new header but the
  same cell; with a push through a view, `same` holds).
- Every item is unchanged, so every row is skipped and no highlight appears.
- P7 as worded walks the rows of `model.rows` only if `model.rows` is written, and it is not.

**Fix:**

1. **Restate P7 over every identity test the renderer makes.** No `===` or `same` test, on any
   hole, group, `let`, helper argument, component prop, `Show` key or input, row input, item or list,
   may conclude "unchanged" for a value whose cells may include an in-place-written path.
2. **Use summaries, not a list of promise functions.** A value "may include" such a path when `view`'s
   summary says so. Use `view`'s `res` and `use` provenance, not only "a function with an identity
   promise". A user helper that returns `model.todos` on one branch counts too.
3. **Price it honestly.** Every group that reads an edited path then runs on every render. In TodoMVC
   that is the filter, the count, both `hidden`s and the `<For>`, run on every keystroke in the draft
   field. Or give the runtime a write version per path. Measure it with research 29's static-heavy page
   as well as the table benchmark.
4. **Name the conflicts in Change 8.** It touches `language.md` §11.11 (the owner's decision of
   2026-10-04), §11.9's row skip and §11.12's view promise.
5. **Re-derive §5.5 and App. A.1.**

### R3-F2. The direct platform does not meet A4 for the element edits I6 makes in place: its indexed scripts are guarded by the element's identity

**Severity:** soundness hole. It contradicts "The direct platform already satisfies the obligation by
design" (Change 8), A4's "Kept by", and §7.9.

**Where:**

- A4;
- Change 8;
- §7.9, *The two platforms*;
- `browser-direct.md` §6.2.

**The fact.** `browser-direct.md` §6.2 guards these scripts by the element's identity:

- the script for `kept [κ]` with sub-writes, from `List.update xs k f`, is guarded by
  `get(xs, κ) !== insts[κ].it` ("the element changed, not the list");
- `swap` is guarded the same way.

`browser-direct.md` §7.4 explains why its own in-place design is safe: "an item's path is never owned by
(2)'s last clause". Its S7 never writes an element in place. The thesis does:

- I6 and §3.11's destructive read write an element's list in place;
- the element then keeps its identity whenever the element *is* a list.

**Program.** This is a grid, on the direct platform:

```
init ⊤ = { grid = List.initialize 9 (λ_ → List.repeat Hidden 9) }    -- fresh, distinct rows: excl
Reveal r c → { model | grid = List.update model.grid r (λrow → List.set row c Shown) }
view model = <table><For each={model.grid}>{λrow → <tr><For each={row}>…</For></tr>}</For></table>
```

- The checker accepts it:
  - `model.grid` is unique and exclusive at entry;
  - `update` supplies the row owned;
  - `List.set` writes it in place, and the callback returns "the element itself", so `excl` survives.
- The write set tags `model.grid` `kept [r]` with a sub-write.
- `get(grid, r) === insts[r].it`, because the same array was written in place. So the script and its
  row groups are skipped, and the cell is never drawn.

Kanban columns and spreadsheets have the same shape.

**Fix:**

- For a `kept [κ]` or `swap` script whose element path is written in place, run the row groups the
  sub-writes conflict with unconditionally, and keep the identity guard only for element paths no arm
  writes in place.
- State the requirement in P7 and in `browser-direct.md`.
- Drop "by design" from Change 8 and A4.

### R3-F3. Change 7 (send) is inconsistent: as stated, the flow it claims to accept is either rejected or accepted unsoundly

**Severity:** soundness hole *(guess: which reading an implementation takes)*. This is R2-F12's repair
failing on a one-line variant of T34.

**Where:**

- §7.9, P6: "the class of the program's `Send` is bound to `update`'s own use of its message
  parameter … A list decoded in a fiber, sent, stored in the model and later extended in place is
  accepted, since the sender gives it up";
- Change 7.

**The gap.** In the flow the thesis accepts, the arm that receives the payload only stores it:
`Loaded rows → { model | rows = rows }`. So `update`'s use of the message path is `A`, not `W`. The `W`
arises one dispatch later, on `π₂.rows`. By the stated binding the send is therefore *not* a demand: it
"only aliases". Two outcomes are possible.

- **Reading (a): the entry treats the payload as owned.** Then this is accepted, and is wrong:

  ```
  init ⊤ = ( { rows = [] }
           , Cmd.perform λsend →
               rows = fetchRows ⊤                 -- decoded: fresh
               send (Loaded rows)                 -- update runs now (boundary.md §9.8.4, rule 1)
               _ = Http.get { url = "/ping", expect = Http.expectString }   -- parks; user clicks Add
               Log.info (String.fromInt (List.length rows))   -- value: n, in place: n + 1
           )
  update msg model = case msg of
      Loaded rows → ( { model | rows = rows }, Cmd.none )
      Add r → ( { model | rows = [ …model.rows, r ] }, Cmd.none )
  ```

- **Reading (b): the entry treats an aliased payload as held by the sender.** Then `Add` is rejected,
  and so is the flow P6 says is accepted. That includes Conduit's comments (R3-F14) and every
  `Cmd.task` result a later arm extends.

**Fix:**

- Bind the send to the *transitive* use: a payload path is consumed at the send when `update`'s `res`
  may carry it into a model path that any arm writes in place.
- The program above is then rejected at the send, correctly, because `rows` is read after it. A
  `Cmd.task` body (`send (tag (work ⊤))`) is accepted.
- Add the program to Table 6.1.

### R3-F4. The escapes `view` makes are in Table 7.1 but not in P5 or the *Entry* lemma; a handler that reads a model list is then a stale holder

**Severity:** soundness hole as stated (P5, Lemma 6.7). The table says otherwise, so the text contradicts
itself.

**Where:**

- P5: "a cell that `update`'s summary marks E …";
- Lemma *Entry*'s proof: "every escape that `init`, any arm, any command body or any subscription
  creates";
- Table 7.1, which says `view`'s handlers and messages are escaped.

**Program.** This runs on the template runtime. A send dispatches at once (`boundary.md` §9.8.4), and the
render is a microtask later:

```
view model =
    <div onClick={λ_ → Report (List.length model.log)}>
        <button onClick={Log "x"}>log</button>
    </div>
update msg model = case msg of
    Log s → { model | log = [ …model.log, s ] }
    Report n → { model | shown = n }
```

1. One click fires the button's handler: `Log` appends in place.
2. The event then bubbles, in the same task, to the `div`'s handler from the previous render. It reads
   the old `model.log`.
3. Value semantics reports n; in place it reports n + 1.

**What happens if the escape is carried instead.** With whole-variable capture (R3-F5), carrying `view`'s
escapes into the entry escapes *every* list of the model whenever a markup closure mentions any model
field. *(guess)* That includes TodoMVC's `<For>` row lambda, which reads `model.editing`, if row
functions count as handlers. The thesis does not say whether a row function is escaped. It is called only
during a render, by the render that made it, so it need not be.

**Fix:**

- Add `view`'s escapes (handlers, messages, `Html.map` functions) to P5 and to the lemma.
- Say that row functions are held only until the next render, so they are not escaped.
- Pair this with R3-F5's per-path capture.
- Add the bubbling program to Table 6.1.

---

## False errors on idioms

### R3-F5. Capture is whole-variable: a command body or handler that reads one field escapes every list of the model, which rejects Conduit and a test program

**Severity:** false error, common. It falsifies §5.5's Conduit verdict.

**Where:**

- Table 3.3, the lambda row ("$\diamond.z_j.q \mapsto A(z_j)@q$" for every path $q$ of the captured
  variable);
- §4.3 ("a captured path is live wherever the closure value is live");
- §7.8.

**Programs, as written in the repository:**

- **`examples/conduit/src/ArticlePage.beni:181`.**
  - The arm is `CompletedDeleteArticle (Ok ⊤) → ( model, Cmd.do λ⊤ → Route.replaceUrl
    (Session.navKey model.session) Route.Home )`.
  - The body reads `model.session`, but captures `model`. So `π₂.errors` and `π₂.comments` gain `E`, and
    the arm returns the same cells.
  - At every later entry they are escaped, and all five `model.errors ++ …` appends in that module are
    rejected on every platform. §5.5 says they are accepted on the direct platform. So is the comment
    prepend of R3-F14.
- **`tests/corpus/browser/tea/ListenerOrder.beni:62`.**
  - The arm is `Cmd.afterRender λsend → _ = Navigation.pushUrl model.key "#/early"; …`.
  - It escapes `model.lines`, so `note`'s `model.lines ++ [ line ]` is rejected.
- **How common.** A text search finds command lambdas that read a `model.` field in about 7 of the 48
  test, example and benchmark files that make commands.
- **The same within one body.** `f = λ_ → model.name` followed by `{ model | rows = [ …model.rows, x ],
  label = f ⊤ }` is rejected, because `f` keeps `model.rows` live.

None of these is sharing: no execution reads the list through the closure.

**Fix:**

- Capture per path read. The closure's `◇` holds `z.q` only for the paths its body reads; a whole-value
  use (passing `model` on) captures every path.
- `language.md` §11.9 already computes exactly this ("the fields it reads … `model.selected`, not
  `model`") for row inputs.
- Re-derive Conduit.

### R3-F6. The by-id `map` edit of a nested list is rejected and labelled real sharing, though no execution observes the write; it is missing from Table 5.2

**Severity:** false error, common *(guess, from Elm practice: Elm's `List` has no `update`, so editing
an element by id with `map` is the canonical idiom; the beni corpus has few nested lists)*.

**Where:**

- §7.4: "With `map` in place of `update`, `map` supplies a borrowed element … the construction is rejected
  as real sharing";
- Table 5.2, where it is absent;
- §10.1.

**Program:**

```
AddTag id t →
    { model | cards = List.map model.cards λc →
        if c.id == id then { c | tags = [ …c.tags, t ] } else c }
```

Also `List.map grid (λrow → [ …row, Empty ])`, which pads a grid.

- **It is rejected:**
  - the callback consumes its parameter's `.tags`;
  - `map`'s row supplies `borrowed`, so the edge of §4.7 fails.
- **It is not real sharing:**
  - `map` reads element *i* once, calls the callback, stores the result, and never reads element *i*
    again;
  - the old `model.cards` is dead after the arm;
  - so the write is unobservable when the input is unique, exclusive and dead.
- This is exactly the destructive-read argument §3.11 makes for `List.update`.

**Fix:**

- Give `map` (and `indexedMap`, `filterMap`) a conditional owned supply: `supply 1 owned π₁[*] if π₁
  excl and π₁ consumed`. The caller then discharges the consumption as for a writer. The identity
  promise still holds, since an unchanged element is returned as itself.
- Otherwise, list the form in Table 5.2 as a *limit*, not as real sharing, and give its frequency weight
  in §12.7.

### R3-F7. Idiom I6 is rejected as written: `excl` does not survive a callback that returns a record update of the element, and `Dict.update` keeps no `excl`

**Severity:** false error on a "must pass" idiom, common. It contradicts §5.2, §14 ("every idiom we
enumerated … is accepted by the rules as written") and App. A.5.

**(a) The record edit, I6's second example.** `List.update rows i (λr → { r | tags = [ …r.tags, t ] })`.

- `update`'s row keeps the flag only with `excl if π₁ excl and g.res fresh`, and §3.11 says "the flag
  survives if the callback's result is fresh or the element itself".
- The callback's result is a new record whose `.tags` is the element's own consumed cell, `π₁.tags`
  through the supply: neither fresh nor the element itself. So the flag is cleared.
- In a TEA `update`, the entry fixpoint then finds `model.rows` not exclusive. The arm's own `xreq`
  fails, so it is rejected at the first dispatch, statically.
- If P5 does not carry `xres` at all, which the thesis never states, every arm needing `xreq` on a model
  path is rejected for the same reason.

**(b) The dictionary grouping, I6's first example and App. A.5's fixed `groupBy`.**

- §7.4 says that by the inferred rules `Dict.update`'s lookup clears `excl` while `d` is live, and only
  the *owned supply* is asserted (§6.5: "only `Dict.update`'s owned supply to its callback is
  asserted"). Its inferred `xres` is therefore "not exclusive".
- `foldl`'s row (§4.7) carries no exclusivity for the accumulator it supplies.
- So from the fold's second iteration the callback receives a dictionary not known exclusive, the
  asserted owned supply's precondition fails, and `[ …Maybe.withDefault g [], x ]` consumes a borrowed
  value.
- A.5's argument ("each a distinct cell with no other holder") is true of concrete cells. But the folded
  abstract cell $\langle\mathit{Dict}\rangle.v$ cannot express it, which is exactly why the flag exists.

**Fix:**

- Keep the flag when every tracked path *q* of the callback's result holds a `fresh_k` or the element's
  own cell at the same *q*.
- Assert `Dict.update`'s `xres` together with its supply.
- Give the fold rows an `excl` guard on the accumulator they supply (`supply 2 … excl if π₂ excl and g
  xres`).
- State that P5 carries `xres`.
- Re-trace I6 and A.5 through the rows.

### R3-F8. `map`'s identity promise is unconditional in its `res`, so Elm's commonest view construction is rejected as "real"; take/drop splices and rotations fail `Disjoint`

**Severity:**

- false error, common *(guess for the external Elm corpus, where views build children with `++`; beni's
  own corpus mostly uses `<For>`)*;
- splices: rare to common.

**Where:**

- §3.8, the `map` row: `→ List b [= fresh, π₁; …]`;
- §7.2;
- Table 5.2, "a model list as a base in `view`", marked *real*.

**Programs:**

1. **A `view` construction.** `ul [] (List.map viewItem model.items ++ [ addButton ])`. Its base is
   `map`'s result, `{fresh, π₁}`. It is rejected at `view`'s definition as a write of `model.items`. But
   `map` can return its input only if every callback result is `===` its element, which is impossible when
   `g`'s `res` never names its parameter: here the type changes from `Item` to `Html`. The `map` row
   already has the atom it needs (`[*] aliased if g aliases 1`) on the parameter side, but not on the
   result.
2. **Splices and rotations.** All fail `Disjoint` or `Dead`, because `take` is `{fresh, π₁}` and `drop`
   is a view, `{π₁}`:
   - `List.take rows k ++ [ r, …List.drop rows k ]` (`tests/corpus/browser/dom/KeyedEnds.beni:60`);
   - `List.take xs i ++ List.drop xs (i + 1)` (`bench/arrays/ops/elm/Ops.beni:36`, and lines 12 and 32);
   - `List.drop xs k ++ List.take xs k` (rotate);
   - `[ …xs, …List.reverse xs ]` (mirror).

   These are Elm's idioms for insert, remove and rotate, since Elm's `List` has none of them. Only in
   corner cases (`k ≥ length`) are they sharing. None is in Table 5.2.

**Fix:**

- Write `res = fresh, π₁ if g may return its parameter` for `map`, `indexedMap` and `filterMap`. Write
  `filter`'s, `take`'s and `reverse`'s as they are.
- Add the splice forms to Table 5.2. Their message should offer `List.insertAt`, `List.removeAt` and a
  rotation's `List.copy`, not only the generic copy.
- Classify both under a new approximate tag (R3-F12).

### R3-F9. The position rule cannot prepend a list onto an accumulator, and right-associative `++` makes the middle operand a base: Elm's own `concat` and `acc ++ part ++ sep` are rejected

**Severity:** false error, rare to common *(guess)*. It is also a stated-conflict omission.

**Where:**

- §3.8 ("`a ++ b ++ c` consumes `b` for the inner `++` and `a` for the outer one");
- §9.5 ("lowers each construction to the writers on its base **as the language already specifies**");
- Change 1 ("It agrees with the decision that `++` on lists calls the list library's append").

**The conflicts:**

- **The lowering differs from the specification's.** `language.md` §6.8 specifies the lowering
  *from the right*: "`[ x, …a, y ]` is `List.cons x (List.append a [ y ])`". So `[ …a, …b, …c ]` is
  `append a (append b c)`, which under the writer rows consumes `b`. The thesis's rule (first spread is
  the base, later spreads only read) is a different lowering, and the text presents it as the existing
  one.
- **Two forms the language equates now behave differently.** The same table says `[ …a, …b ]` *is*
  `a ++ b`, yet:
  - `a ++ b ++ c` consumes `a` and `b`;
  - `[ …a, …b, …c ]` consumes only `a`.

**Programs:**

- `List.foldl rows [] (λr acc → acc ++ r.cells ++ [ sep ])`. The inner `r.cells ++ [ sep ]` consumes a
  borrowed element's field and is rejected; `[ …acc, …r.cells, sep ]` is accepted.
- `List.foldr xss [] (λxs acc → xs ++ acc)`, the definition of `concat` in `elm-core/src/List.elm:387`
  (`foldr append [] lists`). The base is the borrowed element, so it is rejected. No positional form puts
  `acc` as the base of a list prepend, so "prepend a list onto an accumulator" has no in-place spelling at
  all. `List.copy xs ++ acc` is O(|acc|) per step, which is quadratic.

**Fix:**

- State the lowering change as part of Change 1, and name `language.md` §6.8's lowering paragraph as the
  decision it touches.
- Consider flattening a `++` chain into one construction with the leftmost operand as base, so the two
  forms agree.
- Add `xs ++ acc` and the chained form to Table 5.2 with their fixes, `List.concat` and the literal form.

### R3-F10. An undo history *of a list* makes the current list uneditable: the entry fixpoint is non-relational, so §7.14's "solved with the copy" is incomplete

**Severity:** false error, rare *(the repository's undo application, `bench/corpus/NotesApp.beni`, keeps a
`Dict`, which is unaffected)*.

**Where:**

- §7.14;
- I5's undo example;
- P5.

**Program.** This is the fix the message offers, plus the `Undo` arm I5 lists:

```
Add t → { model | history = [ List.copy model.todos, …model.history ], todos = [ …model.todos, t ] }
Undo → case model.history of
    [ previous, …rest ] → { model | todos = previous, history = rest }
    [] → model
```

1. `Undo`'s summary has `res(.todos) = {π₂.history[*]}`.
2. `Add`'s has `res(.history[*]) ∋ fresh_c`.
3. The entry fixpoint therefore puts `fresh_c` in both `model.todos` and `model.history[*]`.
4. `Add`'s write of `π₂.todos` fails `Disjoint` against `π₂.history[*]`, so it is rejected.

At run time the two are disjoint after the pop: `rest` excludes slot 0. The split of §3.11 is local to
the arm and does not survive the fixpoint.

**Fix:**

- Either carry the split across the entry: a path filled by a destructive split of a dead container's
  head is disjoint from that container's `[*]`.
- Or state the cost: a second `List.copy` in `Undo`.

---

## Theory

### R3-F11. The order on `res` is mis-stated: closing each set upwards under `p ⊏ ⊤` puts `⊤` in every non-empty set

**Severity:** theory. It falls under R2-F9's repair.

**Where:** §4.6, the table row for $\mathit{res}(q')$ ("ordered by inclusion after closing upwards under
$\mathit{fresh}_k \sqsubset \mathit{esc}_k$ and $p \sqsubset \top$").

**The problem.**

- Taken literally, the upward closure of `{π₁}` is `{π₁, ⊤}`, so every result fails `Known`.
- What the text needs is the Hoare preorder ($S \sqsubseteq T$ iff every element of $S$ is below some
  element of $T$), quotiented, or inclusion on down-closed sets.
- The stated height, $|P|+|V|+2|Q|+2$, is the height of plain inclusion, so it must be recomputed for
  the intended order.
- The same applies to `supply`'s provenance sets.

**Fix:** define the order on down-closed sets (or the Hoare quotient), restate the height, and recheck the
monotonicity claim of the read-off rule against it.

### R3-F12. The main metric is circular, and the exact/approximate split mislabels non-sharing as real

**Severity:** theory (evaluation design). R2-F19's repair holds only in part.

**Where:**

- §12.2 (the idiom classifier "following §5.2");
- §12.4 (the idiomatic error rate);
- §12.7, criteria 2(a) and 2(c);
- §8.4 ("A rejection whose derivation uses only exact tags is real sharing: there is a path through the
  program text on which the old version is read after the edit").

**The problems:**

1. **The idiom set is the thesis's own list I1–I7**, built from forms that pass. Several are known to be
   rejected:
   - constructions in `view` (R3-F8);
   - splices (R3-F8);
   - `xs ++ acc` (R3-F9);
   - by-id `map` edits (R3-F6);
   - top-level bases such as `samples ++ samples` (`run/Int32Keys.beni:68`) and `k ++ both ++ […]`
     (`run/PhantomAliasUnifiesByExpansion.beni:57`).

   All of these fall into "other", which is bounded only by the 1-in-10 criterion 2(b). Criterion 2(a),
   at 1 in 50, can pass while the commonest Elm constructions fail.
2. **Exact derivations that read no old version.** All of these are tagged exact, yet in none is the old
   version read after the edit:
   - `Disjoint` failures caused by an identity promise's "may" (R3-F8);
   - by merged list positions $[\ast]$ (R3-F6);
   - by the non-relational entry (R3-F10);
   - by whole-variable capture (R3-F5).

   They therefore inflate "real sharing" and flatter criterion 2(c) ("fewer than half approximate").
   Calling a top-level base or a `view` base "real" is also definitional: the rule's own choice of base
   creates the write.

**Fix:**

- Make every demand in the external corpus an idiomatic site; Elm code written without the rule is
  idiomatic by the thesis's own definition. Report I1–I7 as a breakdown.
- Add approximate tags: "may be its source (identity promise)", "positions merged", "merged at entry"
  and "captured with the whole record".
- Report "rejected because of the position rule's choice of base" separately from sharing.

---

## Fidelity

### R3-F13. The thesis's descriptions of the renderer, views and identity are out of date or self-contradictory

**Severity:** fidelity.

1. **§2.7 and Table 3.1 describe the template runtime as skipping only a `<For>` and a row by item.** The
   grouped-value, `let`, helper, component, `Show`, row-input and `same()` skips of R3-F1 are normative
   (§11.9, §11.11, §11.12) and as built (`Rt.beni`).
2. **"A view is always a suffix of its base" (§2.5, §7.11)** contradicts both:
   - `language.md` §6.8, where `[ …init, last ]` binds `init` to "a view of the ones before it";
   - Table 3.3's own treatment of `init` as a view.

   If `init` is a prefix view, "a push on a view is a push on the base" writes the wrong slot. *(guess:
   today's lowering may copy `init`.)* Either way the text needs one consistent story, and the re-cons
   alias rule should say whether it covers `[ …init, last ]`.
3. **Identity of headers versus cells.** §9.5 says "A construction returns its base's identity", while
   Table 9.1 says a prepend, and any write through a view, "return[s] a new header". The language's
   identity is the header's `===`, so the result is the base's *cell* but not always its identity. The
   instrumented semantics of §6.2 relates cells, so this affects only the prose and P7's wording (R3-F1).

**Fix:**

- Update §2.7 and Table 3.1 from `language.md` §11.9 and §11.11.
- Settle prefix views.
- Write "cell" where §9.5 says "identity".

### R3-F14. Conduit's assessment misses its one spread construction, and its verdict depends on R3-F3 and R3-F5

**Severity:** fidelity.

**Where:** §5.5 ("It has thirteen `++` on lists"; "all seven appends are accepted").

**The fact.**

- `examples/conduit/src/ArticlePage.beni:140` holds
  `Loaded ( Editing "", [ comment, …comments ] )`, a prepend onto a model list.
- That list came from a `Cmd.task` result (`CompletedLoadComments (Ok comments)`) and is rendered in the
  page.
- Whether it is accepted turns on R3-F3's send rule.
- The seven `errors` appends are rejected on every platform in that module, by R3-F5.

**Fix:** re-trace Conduit with the spread, the send rule and per-path capture, and update §5.5, §10.6
and the abstract.

---

## Minor

### R3-F15. Two error-message fixes do not work as written

**Severity:** minor.

**Where:** §8.2.

- **The closure example** offers `show = λi → String.fromInt (List.length (List.copy rows))`.
  - The copy runs when `show` is called, on line 14, after the write. So it does not restore the old
    version, and the closure still captures `rows`, so the checker still rejects.
  - The real fix binds the copy, or the length, before line 11.
  - The example's `List.set` also does not change the length `show` reads, so "show would see the changed
    list" claims an observable difference that does not exist.
- **The `map` example's fix**, `List.foldl xs acc (λx acc → [ …acc, x ])`, has two problems:
  - it shadows `acc`, which is an error in beni (`language.md` §7);
  - it computes a different value from the `map` it replaces.

**Fix:** correct both, and check every fix in §8.2 against the compiler's shadowing rule.

### R3-F16. Smaller points

**Severity:** minor.

- **"A once value never escapes" is worded at $\varepsilon$ (§3.6).**
  - A record holding a once closure at `.f`, passed to a parameter with `E` at `.f`, is not covered by
    the words. The entry check of T27 covers it in practice, but the rule should say "at any path where
    the value may hold a once cell".
  - The same rule rejects `Task.spawn (λ⊤ → … [ …acc, x ] …)`, whose body runs once. Its message says the
    body "may be called more than once", which is false. Allow escape at a position whose asserted `calls`
    is ${\le}1$, or reword the message.
- **The withdrawn promise is broader than `[] ++ ys` (§3.8, Change 1).** It is the general rule that
  `xs ++ ys` with `xs` empty *at run time* returns `ys` (`core/List.beni`, `append`). Also, `xs ++ []`
  "writes nothing" but is still a demand that consumes `xs`; say so.
- **Calls through a function-typed parameter.** In Table 3.3, "if $A(g)@\varepsilon$ holds a cell, the
  call is also a demand on it" reads as true of every function-typed parameter, whose `A` at
  $\varepsilon$ is $\pi_i$. That would make `List.map fs (λf → f x)` a write. State that the demand is
  guarded by the class atom "may be once".
- **The prepend guard test (§5.4) traces as claimed** (`run/ListPrependDeep.beni`):
  - its `kept = List.push s.kept top` holds `top` as an element while the next iteration prepends onto
    `s.top`, so it is rejected;
  - with `List.copy top` it is accepted, with ten copies.

  Stating the one-line source change in Change 1's "recorded decisions it touches" is correct.

---

## Re-trace of the earlier programs

- **T1–T19 (round 1) and T20–T34 (round 2)** are decided as Table 6.1 says under the current rules,
  construction rule included.
- **Two verdicts changed, both correctly.** T12 is now rejected by **Dead** on `ys`, because the building
  loop consumes its tail. T13 is rejected at `view`.
- **Programs to add to Table 6.1**, which the stated rules decide wrongly or do not decide:
  - R3-F1's TodoMVC `hidden` and row-input programs;
  - R3-F2's grid;
  - R3-F3's send-then-read;
  - R3-F4's bubbling handler;
  - R3-F7(a) in an `update`;
  - R3-F10's undo of a list.
