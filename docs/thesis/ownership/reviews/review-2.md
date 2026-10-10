# Referee report, round 2: "Edit in Place or Not at All" (revised)

**Reviewed:** the LaTeX sources in `docs/thesis/ownership/` at commit `7e37a0472` on branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`), and the 99-page PDF for
presentation. The PDF has no unresolved references.

**Checked against:**

- round 1: `ownership-thesis-review.md` (F1–F39) and the author's `ownership-thesis-response.md`;
- the design documents in the worktree: `language.md` (§6.8 list costs, §11.12 identity, the
  evaluation-order table), `backend.md` (§4 *Identity*, §15.6, the template runtime's skip rule),
  `boundary.md` (§9.8.4 dispatch order, §9.8.11), `browser-direct.md`;
- the sources: `core/List.beni`, `core/Dict.beni`, `core/Debug.beni`, `core/Task.beni`,
  `platforms/browser/Browser.beni`, `platforms/browser/Cmd.beni`, `platforms/browser/Listen.beni`,
  `platforms/browser-tea/Tea.beni`, `platforms/browser-direct/Tea.beni`, `platforms/html/Html.beni`,
  `platforms/browser/Hosted.beni`;
- the corpus: `tests/corpus/` (counts below are `grep` counts, read by hand where quoted), in
  particular `run/ListPrependDeep`, `browser/tea/SyncCommandOrder`, `browser/tea/ReentrantSend`,
  `browser/direct/KeyedInPlace` and the 15 direct-platform programs that call a named writer;
- cited sources in `references/ownership/` (Mazur, Clebsch et al., Clarke et al., Xu et al., de Vries
  et al., the Austral and Vale texts), read as text or rendered.

**Stance:** adversarial. A program marked *(guess)* depends on a choice the thesis leaves open, and
the finding says which. "As written" means by the rules as the revised thesis states them.

## Summary

| Severity | Count | Findings |
|---|---|---|
| Soundness hole | 4 | R2-F1 – R2-F4 |
| Round-1 repair failed | 2 | R2-F5, R2-F6 |
| Theory | 3 | R2-F7 – R2-F9 |
| Language-change cost | 4 | R2-F10 – R2-F13 |
| False error | 2 | R2-F14 (rare), R2-F15 (common, guess) |
| Citation | 1 | R2-F16 |
| Fidelity | 1 | R2-F17 |
| Standalone | 2 | R2-F18, R2-F19 |
| Minor | 1 | R2-F20 |

**Round-1 repairs.** Traced through the revised rules, **all twelve soundness programs F1–F12 are now
rejected or made safe**, exactly as the response says. But five of the repairs are narrower than the
holes they were meant to close. A one-line variant of each reopens the same class of bug: F1, F2, F4
(through R2-F2), and F7, F9 (through R2-F1). F12's repair does not reach `foreign` types (R2-F4). The
repair of F14 rests on a platform promise, P7, that contradicts beni's decided dispatch order (R2-F5).
The table at the end of this summary gives the per-program trace.

**Verdict.** The first-order core still holds; I found no counterexample in it. Higher-order code
has improved a great deal. Environments under `◇` and once closures as cells are the right idea, and
they work wherever the closure's *creation* or its *holding* is the issue. They fail where a value
leaves a call:

- **What a summary's `res` can name.** It can name a parameter path or a numbered fresh cell, and
  nothing else (§3.7, §4.6). It cannot say "a cell the closure holds" (R2-F2), "a cell that escaped
  inside the callee", "a top-level value's cell" or "⊤" (R2-F1). The read-off rule of §4.4 maps every
  site in the result to `fresh_k`, including sites of the enclosing scope and sites that escaped.
- **A once closure that escapes.** Once it escapes it is never checked again (R2-F3).
- **The proof.** Several lemmas inherit these gaps (R2-F9).

The repairs are local: extend the `res` vocabulary, add one rule for escaped once cells, and default
`foreign` types to not crossing. So the design is not broken at the core.

But the cost side changed. The revision made the rule sound partly by shrinking its reach:

- after Change 4, only nine named writers are demands, and the two applications call none of them;
- Changes 2 and 4 reverse two decisions the language design records as the owner's: W27 and
  `language.md` §11.12 on identity, and W35 on prepending (R2-F10, R2-F11). The thesis does not say
  that it reverses them.

**One more round is needed.**

### Round-1 soundness programs, traced through the revised rules

| Program | Now | Holds? |
|---|---|---|
| F1 `mk xs = λ⊤ → List.length xs` | `res(◇) = {π₁}`; `(g, ◇)` live at the push → **Dead** fails | yes, for this program; a closure that *returns* `xs` reopens it (R2-F2) |
| F2 A/B/C | A: closure cell, `p` reused → **Dead**; B: `h` calls captured once `g` → once, `map` calls many; C: `(r, .k)` reused | yes; a closure that *returns* a captured once closure reopens it (R2-F2 (d)) |
| F3 `Bag.eq` that pushes | W on `π₁.Bag#0` → error at the declaration | yes |
| F4 `[ { a = xs, b = xs } ]` | within-position condition fails → no `excl` → borrowed supply → edge fails | yes; `List.map [ 1, 2 ] (λ_ → xs)` sets `excl` wrongly (R2-F2 (b)) |
| F4 related, `xs ++ ys` | `++` stores `ys`'s elements while `ys` lives → no `excl` | yes |
| F5 `appendTo [] ys` | the exit copies | yes |
| F6 spreads in `view` | spreads build; `view` reads | yes |
| F7 `Reset → init` | `init ⊤` returns fresh cells | only when `init` builds its lists; an `init` that returns a top-level list reopens it (R2-F1 (b)) |
| F8 `pick` through `foldl` | supply provenance translates `{π₁}` | yes |
| F9 a stale entry | aliasing is in `init`'s published `res` | for aliasing only; escapes and top-level cells are not representable in `res` (R2-F1) |
| F10 pending arguments | evaluation-order normal form | yes |
| F11 the view's `$plain` | a write returns a new header | yes |
| F12 an opaque `Stack` | crossing published, `⟨Stack⟩` | yes for `opaque type`; `foreign type` crossing is undefined (R2-F4) |

**Spot-check of the other round-1 findings.**

- **Fixed in the text:** F13, F15, F16, F17 (as an estimate), F18, F19, F21, F23, F24, F26–F28, F30,
  F31–F34, F36–F39. I re-checked F31.6, F31.7 and F32 on Capybara and Clarke against the sources;
  they are now accurate.
- **Only partly fixed:**
  - **F20.** The lattice still omits the argument-dependent `excl` conditions (R2-F8).
  - **F22.** The quadratic cost moved from `cons` to the list syntax (R2-F10).
  - **F25.** `Dict.update` is misdescribed (R2-F17).
  - **F35.** Revision-history language returned in a new form (R2-F18).

---

## Soundness holes

### R2-F1. A summary cannot say that a result cell escaped, is a top-level value's, or is ⊤, so escapes made inside a callee vanish at its callers and at the entry protocol

**Severity:** soundness hole. This is also the reason the repairs of F7 and F9 are incomplete.

**Where.**

- §3.7: `res : q ↦ ℘({π_i.q'} ∪ {fresh_k})`, and the bracket grammar's `prov`.
- §4.4: `res(q') = {π_i.q | …} ∪ {fresh_k | site(ι_k) ∈ A(result)@q'}`. Sites become `fresh_k`, and
  `⊤` is dropped.
- §4.6: `res` is a subset of `P ∪ {fresh_1, …}`.
- Lemma *Summary soundness* clause 3: "a fresh cell has no holder other than the result".
- §6.9, P5: "a cell that `update`'s summary marks E … is escaped at every later entry".

**The gap.** The E bit exists only on *parameter* paths. When a function makes a cell and lets
something keep it, the cell is escaped in that function's frame, and nothing records it:

- the something can be a command (`Cmd.perform`'s row puts E on the lambda's `◇`), a spawned fiber,
  a `Ref`, or `Js.from`;
- the function then returns the cell, and its summary names it `fresh_k`.

A top-level value read in the body, and a `⊤` from `Task.join`, have no provenance at all.

**Program (a): P5 is defeated.** This is an idiomatic TEA program on the direct platform, with
`init` a function.

```
type Msg
    = Rename String String
    | Add String
    | Saved Int

update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Rename old new →
            todos = List.map model.todos λt → if t == old then new else t
            ( { model | todos = todos }
            , Cmd.perform λsend →
                _ = Http.get { url = "/save", expect = Http.expectString }   -- waits
                send (Saved (List.length todos))
            )

        Add t →
            ( { model | todos = List.push model.todos t }, Cmd.none )

        Saved n →
            ( { model | saved = n }, Cmd.none )
```

Click Rename, then Add while the request is in flight. Value semantics sends `Saved 3`; in place it
sends `Saved 4`.

1. In the `Rename` arm, `todos` is a site `s`. `Cmd.perform`'s row escapes it in `update`'s frame.
2. `update`'s summary has `use(π₂.todos) = {R}`, which is what `map` does to it, and
   `res(.1.todos) ∋ fresh_1`. Nothing in the summary says `fresh_1` escaped.
3. P5's fixpoint gives `model.todos` cells `{fresh from init, π₂.todos, fresh_1}`, none of them
   escaped.
4. The `List.push` in `Add` passes **Known**, **Unescaped**, **Dead** and **Disjoint**. It is
   accepted.

This is exactly §7.2's "command that captured the list" error, which the thesis says is rejected. It
is rejected only when the captured list is a parameter path, and the idiomatic code builds a new
list first, as TodoMVC's `changed model (List.map …)` / `save todos` does.

**Program (b): F7's repair is defeated.** The `KeyedInPlace` corpus program seeds its model from a
top-level constant in the same way.

```
seed : List String
seed = [ "milk" ]

init : ⊤ → Model × Cmd Msg
init ⊤ = ( { todos = seed }, Cmd.none )

update msg model =
    case msg of
        Add t → ( { model | todos = List.push model.todos t }, Cmd.none )
        Reset → init ⊤
```

`init`'s `res(.1.todos)` cannot say "a top-level value". It is either:

- `fresh` (the top-level site renumbered): accepted;
- or ∅, which means "provably no cell" (`⊤` dropped): **Known** loops over nothing, and the program
  is accepted.

After `Add "eggs"`, `Reset` shows `["milk", "eggs"]`. Value semantics shows `["milk"]`, and the
constant `seed` itself has changed.

**Program (c): a wrapper of `Task.join`.** The thesis's own Table 5.1 row ("`Task.join fib` twice …
rejected") is defeated by a one-line wrapper:

```
result : Fiber (List Int) → List Int
result f = Task.join f

a = result fib
b = result fib
a2 = List.push a 9
List.length b          -- value: 2; in place: 3
```

`Task.join`'s asserted result is `⊤`, and §4.4 drops it, so `result`'s `res = ∅`.

**Fix.**

1. Add two provenances to `res`, to the bracket grammar and to the lattice of §4.6:
   - `esc`: the cell is kept by something the caller cannot see. The caller marks it escaped.
   - `⊤`: the cell is unknown. This one is prefix-closed.
2. In §4.4, map a site that escaped in the frame to `esc`, a top-level cell to `esc`, and `⊤` to `⊤`.
   A site becomes `fresh_k` only if it was made in this body and never escaped.
3. Alternatively, have command constructors *alias* their captures into the `⟨Cmd⟩` part of the
   result (A, not E). The entry protocol, which already escapes what the runtime keeps of commands,
   then sees `.1.todos` and `.2` share `fresh_1`.
4. Add programs (a)–(c) to Table 5.1.
5. Restate clause 3 of the summary lemma as a property the read-off rule actually establishes.

### R2-F2. Calling a closure that returns a cell from its environment gives a result the analysis believes fresh

**Severity:** soundness hole. This is also the reason the repairs of F1, F2 and F4 are incomplete.

**Where.**

- Table 3.2, "call `g a₁ ⋯ aₙ` through a value: by `g`'s ownership class".
- §4.7, which says a class carries "the `use`, `res` and `xres` facts of the function type's own
  parameters and result".
- §4.4's read-off rule.
- §3.11, which sets `excl` on `map`'s result "when its callback's result is fresh at every tracked
  path".

**The gap.** F1's repair publishes `res` at `◇` for a function whose *result is a closure*. It gives
no way to say that a closure's *call result* is something the closure holds:

- A class's `res` can name only the function type's own parameters or `fresh_k`.
- §4.4 turns a site of the enclosing body, captured and returned, into `fresh_k`.

**Programs.**

(a) The direct form:

```
main =
    xs = [ 1, 2 ]
    get = λ⊤ → xs
    ys = List.push (get ⊤) 3
    Debug.log "again" (get ⊤)          -- value: [1,2]; in place: [1,2,3]
```

`A(get ⊤)` is a fresh cell. So `(get, ◇)` is never compared with the operand, and the push is
accepted.

(b) Through `excl`, which is F4 again by another route:

```
main =
    xs = [ 1, 2 ]
    rows = List.map [ 1, 2 ] (λ_ → xs)              -- [ xs, xs ]
    rows2 = List.update rows 0 (λr → List.push r 9)
    Debug.log "second" (List.get rows2 1)          -- value: Just [1,2]; in place: Just [1,2,9]
```

1. The lambda's result is "fresh", so `map`'s result is exclusive.
2. `update` therefore supplies `r` owned, and the push is accepted.
3. Both positions are the same array.

(c) Recursion through a closure. This is a `let` function, which beni allows to recurse:

```
main =
    acc = [ 0 ]
    upTo n = if n == 0 then acc else List.push (upTo (n - 1)) n
    a = upTo 2
    b = upTo 1
    Debug.log "a" a                    -- value: [0,1,2]; in place: [0,1,2,1]
```

1. Whether `upTo` is once depends on whether the demand's operand, the recursive call's result, may
   hold the captured `acc`.
2. Its `res` cannot say so, so `upTo` is not once.
3. The two calls are accepted.

(d) Returning a once closure, which is F2 again by another route:

```
main =
    acc = [ 0 ]
    push1 = λx → List.push acc x      -- once: a cell
    give = λ⊤ → push1                 -- not once: it only returns a capture
    f = give ⊤
    a = f 1
    g = give ⊤
    b = g 2
    Debug.log "a" a                   -- value: [0,1]; in place: [0,1,2]
```

1. `f` and `g` are each "a fresh once closure".
2. Each is called once, so both demands pass.
3. They are the same closure.

**Fix.**

1. Give a class's `res` a provenance `◇` (or `◇.q`) meaning "a cell this closure holds". At a call,
   translate it through `A(g)@◇`, exactly as `π_i` is translated through the arguments.
2. In §4.4, a site that is not made in the body being summarised is never `fresh_k`.
3. Make §3.11's `excl` condition "fresh" mean "made during this call", which excludes `◇` and
   enclosing-scope cells.
4. Add (a)–(d) to Table 5.1.

### R2-F3. A once closure that escapes is never checked again, though the runtime may call it many times

**Severity:** soundness hole as written. It is also a gap in the proof of the *Once closures* lemma.

**Where.**

- §3.6 and §3.10: calls of a once closure are demands, checked where the call is written.
- A6 and Table 6.1, which speak only of *escapes*.
- The *Once closures* lemma: "the first call finds every other holder of the closure dead, so no
  second call happens".

**The gap.**

- Escape is not a demand. A once closure passed to an E position marks its cell escaped, and no rule
  fires.
- The rule that fails **Unescaped** applies at a demand, and the demand, the call, then happens in
  JavaScript, where nothing checks it.
- The lemma's argument covers only calls in checked beni code.

**Program.** The template runtime, which is the platform both applications use; `init` is a function:

```
type Msg
    = Typed (List String)

type alias Model =
    onKey : String → Msg
    last : List String

init : ⊤ → Model
init ⊤ =
    seen = []
    { onKey = λs → Typed (List.push seen s), last = [] }   -- once: consumes `seen`

update : Msg, Model → Model
update msg model =
    case msg of
        Typed xs → { model | last = xs }

view : Model → Html Msg
view model =
    <div>
        <input onInput={model.onKey} />
        <p>{String.join "," model.last}</p>
    </div>
```

Type `a` then `b`. Value semantics shows `b`; in place it shows `a,b`.

1. Creation is checked: `seen` is reachable only through the closure.
2. `view` passes `model.onKey` to markup. That is E on `π₁.onKey`, which Table 6.1 allows `view`.
3. No beni code ever calls the closure, so there is no demand.
4. The runtime calls the same closure at every keystroke, and each call pushes onto the array the
   previous call wrote.

The same gap applies to any `Tea.*` record field that is a once closure (a once `update`, say,
returned by a helper that captured a local list), unless the constructor's row states
`calls many`. Table 6.1 states no call counts.

**What does catch it today.** Callbacks that the platform calls from beni code are covered:
`Browser.Events.eachKeyDown` runs `f` in `Listen.pump`'s beni loop, so a once handler gets
`calls = many` by inference. The gap is the callbacks reached through `Js`: markup handlers, and
whatever a sibling keeps.

**Fix.**

- Either make E on the `ε` path of a possibly-once value an error ("this function may be called more
  than once by the runtime"), or treat it as a pass to a `many` position.
- And require every asserted row with a function-typed parameter to state `calls`, defaulting to
  `many`.
- Extend the lemma to cover calls made by trusted code.

### R2-F4. Crossing is undefined for `foreign type`s; read as written, `Html Msg` crosses and its handlers' captures disappear

**Severity:** soundness hole (a specification gap). The program depends on how the markup lowering's
rows are written *(guess)*.

**Where.**

- §3.1: crosses(τ) for "a record, tuple or nominal type all of whose tracked paths are empty",
  computed "with the type's parameters' contributions, as Peters et al. publish crossing coefficients".
- A10: "computed in its declaring module from its full definition".

**The fact.**

- These are `foreign type`s with no definition: `Html msg` (`platforms/html/Html.beni:23`), and in
  `Hosted.beni`, `Job msg`, `Outlet msg`, `Later msg` and `Relay msg`, and in `core/Task.beni`,
  `Fiber a`.
- `Cmd msg` is `Cmd (List (Item msg))`, whose `Item` holds a `Job msg`, the command's body closure.

**The gap.** By the stated rule, a parameterless or parameter-crossing foreign type has no tracked
path, so `Html Msg` crosses when `Msg` does, and a command's thunk is invisible through its type:

- Commands are rescued by `Cmd.perform`'s row, which escapes captures at construction.
- Markup is rescued only if the markup lowering's rows also escape at construction. Table 6.1
  instead escapes "the rendered view" when `view` *returns*, which needs `Html` to carry the cells.

**Program** *(guess as to the row)*:

```
view : Model → Html Msg
view model =
    xs = [ "a" ]
    field = <input onInput={λs → Typed (String.join "," xs)} />   -- the handler holds xs
    ys = List.push xs "b"
    <div>{field}<p>{String.join "," ys}</p></div>
```

If `Html Msg` crosses, `A(field) = ∅` and the push is accepted. Typing then sends `Typed "a,b"`;
value semantics sends `Typed "a"`.

**Fix.**

- A `foreign type` never crosses unless its declaration says so.
- Its values carry `⟨T⟩`, and every constructor of such a value (markup sites, `Hosted.job`) has an
  asserted row.
- Add this to Change 14 and to the trusted surface.

---

## Round-1 repairs that failed

### R2-F5. P7 (sync commands drained before the next message) contradicts beni's decided dispatch order, so F14's repair is not available on either platform

**Severity:** round-1 repair failed (F14, F29). It is also a language-change cost (Change 13).

**Where.** P7, A12, Change 13, §6.8, and App. A.1, where TodoMVC is "accepted … with \Obl{P7}".

**The contract.** `boundary.md` §9.8.4 (W53), item 1: "A message is dispatched when `send` is
called: `update` runs at once". §9.8.11 (b) runs bodies that cannot suspend "with no fiber, queued
where its fiber would have started". The fixture `browser/tea/SyncCommandOrder` pins the result:
"every message a body sends applied at once, between two bodies".

**Program.**

```
Clear →
    kept = List.filter model.todos λt → not t.done
    ( { model | todos = kept }
    , Cmd.batch
        [ Cmd.perform λsend → send (Toggle 0)                     -- never waits
        , Cmd.do λ⊤ → saved (Storage.set Local key (encode kept))  -- never waits
        ]
    )

Toggle i →
    ( { model | todos = List.update model.todos i λt → { t | done = not t.done } }, Cmd.none )
```

1. The first body's `send` runs `update (Toggle 0)` at once, between the two bodies.
2. That arm writes `kept` in place.
3. The second body then stores the toggled list.

Value semantics stores `kept` as it was at `Clear`.

**Why P7 does not save this.** A platform claiming P7 would let the checker treat the second
body's capture as "held until the next dispatch", and accept `Toggle`. But no platform can claim P7
without reversing W53: the next message arrives *during* the drain. Even P7's own wording is per
command, and here the second command has not yet run when the next message reaches `update`.

**Consequences.**

- Change 13's cost, "a scheduling constraint … to be measured", understates it: the change reverses a
  decided ordering contract and a pinned fixture.
- App. A.1's "accepted on the direct platform" survives only through its alternative, encoding before
  the command is made.

**Fix.**

- State P7 over a batch: no message any body of a batch sends reaches `update` before every
  non-suspending body of the batch has finished.
- Say that this reverses W53 item 1, and leave that decision to the owner.
- Or drop P7 and keep the pessimistic row.

### R2-F6. Where the entry check runs is ill-defined: a Program value can be mounted several times, and Change 12 is required, not a trade

**Severity:** round-1 repair failed in part (F6, F7, F9). It is a soundness hole under one of the two
readings the text allows.

**Where.** §4.10 and §6.9 ("evaluated at the one call that starts the program", an "asserted row on
the platform's program constructor (`Tea.element` and its kin)"), Change 12 ("A program that keeps
`init` as a value loses nothing in correctness"), and App. A.2.

**Facts.**

1. `Browser.program p = Js.to (Js.array [ Js.from { a = p, n = Js.null } ])`
   (`platforms/browser/Browser.beni`). A Program is a first-class value. `Browser.programs` and
   `mountAt` mount it several times.
2. `browser-tea`'s `Tea.element` is beni over `Browser.hosted`: `init = λhost → start host app.init`.
   Each mount therefore starts from the *same* `app.init` value.
3. On `browser-direct` the constructors are `foreign` that the lowering recognises; the record "is
   never evaluated as a value".
4. 253 corpus and example files call a program constructor. Nearly all write `init` as a value, and
   every one of the 15 direct-platform programs that call a named writer writes it as an inline
   literal (e.g. `main = Tea.sandbox { init = { rows = [ 10, 20, 30 ], log = "" }, … }`).

**Program.** This runs on the template runtime, where the thesis says model lists that are never
rendered *can* be edited in place:

```
type Msg
    = Click

type alias Model =
    log : List String
    n : Int

counter : Browser.Program
counter =
    Tea.sandbox
        { init = { log = [], n = 0 }
        , update = λ_ model →
            log = List.push model.log "click"
            { log = log, n = List.length log }
        , view = λmodel → <button onClick={Click}>{String.fromInt model.n}</button>
        }

main : Browser.Program
main = Browser.programs [ counter, Browser.mountAt counter "second" ]
```

Click the first mount twice, then the second once. The second mount shows 1 under value semantics
and 3 in place.

**Two readings, both bad.**

- **The row treats the inline `init` as fresh and owned at "the call that starts the program"**, the
  `Tea.sandbox` call. Then this program is accepted.
- **Everything reachable from a top-level value is escaped** (Table 3.1). Then the program is
  rejected, but so is every edit in all 15 direct-platform writer programs and in App. A.2 unless
  `init` is a function. "Loses nothing in correctness" is then true only because the program can no
  longer edit in place, and Change 12 is required.

**Further facts.**

- The asserted row sits on `Tea.element`, which is a beni function whose body inference can see. The
  thesis does not say which wins.
- `Tea.document` and `Tea.application` wrap the user's functions in further lambdas. The row's guards
  are per model path, so the cap of eight guard atoms (§4.6) may fire *(guess)*.

**Fix.**

- Define the entry check per *mount*, at `main`.
- Make Change 12 required and list it with the required changes.
- Say that a value `init` is escaped.
- Put the asserted row on the function the runtime actually calls (`Browser.hosted` / `Browser.program`
  on `browser-tea`; the lowering's recognised constructors on `browser-direct`). Let inference run
  through `Tea`'s beni layer, including its use of `Js`, or state why not.

---

## Theory

### R2-F7. `let`-bound functions (hoisted, mutually recursive, capturing) are outside the model

**Severity:** theory, a specification gap. The program below is a hole under one natural reading
*(guess)*.

**Where.**

- §4.2: "The only loop inside a body is a self tail call".
- §4.5: strongly connected components "of the call graph"; "a recursive function's own name is a
  reference to a declaration that captures nothing".
- Table 3.2's lambda row: the closure is created where it is written.

**Fact.** `language.md` §7 and the initialisation rows say:

- a `let` function is emitted as a hoisted `function` declaration;
- it may be named above its own line;
- mutual recursion among `let` functions is unrestricted.

**Program.**

```
main =
    acc = [ 0 ]
    a = addTo 1                    -- legal: a let function may be named above its line
    b = addTo 2
    addTo x = List.push acc x      -- once
    Debug.log "a" a                -- value: [0,1]; in place: [0,1,2]
```

**The gap.**

- A forward walk in evaluation order meets the two calls before the lambda's creation instruction.
- Neither the creation-time demand nor the closure's cell exists yet.
- The thesis does not say where a hoisted closure is created. Nor does it say how a group of
  mutually recursive local functions that capture lists is solved, or what a local function's own
  name holds. R2-F2 (c) is the recursive case.

**Fix.** Treat a block's `let` functions as one group:

- create all their closures at block entry, with their captures read at call time;
- solve the group by the same fixpoint;
- give each function's self-reference the group's cells under `◇`.

### R2-F8. Argument-dependent facts are outside the stated summary grammar and lattice

**Severity:** theory. The `Dict` program below is a *(guess)*.

**Where.** §3.7's bracket grammar (`guard ::= atom`, where an atom is "one fact of one function-typed
parameter's class"), and §4.6's lattice (`xres ∈ {yes, no}`).

**The facts that do not fit.**

- **Conditions on argument state.** The writers' rows use them: "`excl if π₁ excl and π₃ stored
  exclusively`". An *inferred* container summary needs the same: `Dict.insert` keeps `excl` only if
  its value is stored exclusively, and so would any user tree. Neither the guard grammar nor the
  lattice expresses this, so inference cannot produce it, and App. A.4's claim that `d`'s values are
  exclusive "from `Dict.empty` on" has no derivation.
- **Effect bits.** P7's rows are conditional on whether a thunk may suspend, which is not an
  ownership atom.
- **Guards on `update`'s class.** The entry row's guards are per model path. Their number grows with
  the number of written list paths in the model, against a cap of eight.

**Keys and values under `⟨Dict⟩`.** Importers see keys and values under one step, `⟨Dict⟩`
(§6.4). The "within a position" condition of §3.11, that distinct tracked paths hold distinct cells,
is then vacuous for a key and its own value.

```
main =
    k = [ 1 ]
    d = Dict.insert Dict.empty k k            -- one list as key and value
    d2 = Dict.update d [ 1 ] λm → Maybe.map m λv → List.push v 9
    Debug.log "size" (Dict.size d2)           -- value: 1; in place: 2
```

If `d` is judged exclusive, `Dict.update`'s asserted owned supply lets the callback push onto the
stored *key*. `insert` then compares `[1]` with `[1,9]`, goes left, and adds a second node.

**A related description error.** `Dict.update` is `case alter (get dict targetKey) of Just v →
insert dict targetKey v …` (`core/Dict.beni:391-399`). It is not "a path-copying walk that takes the
node's value". Its owned-supply assertion must argue that `insert` and `remove` never read the old
value *or a key that aliases it*.

**Fix.**

- Add argument-state atoms (`π_i excl`, `π_i stored exclusively`, `π_i ⊥ π_j`) and effect atoms to the
  guard grammar.
- Restate the height bound with them.
- Give `⟨Dict⟩` two steps, keys and values. Put keys in the exclusivity condition, or state that
  `Dict.update` requires keys that cross.

### R2-F9. The proof sketch no longer goes through at four named steps

**Severity:** theory.

1. **Flow facts.** "A call's result is bounded by the callee's `res` … translated through `supply`".
   This is false while `res` cannot name `◇`, `esc` or `⊤` (R2-F1, R2-F2).
2. **Summary soundness, clause 3.** "A fresh cell has no holder other than the result". This is false
   of the read-off rule of §4.4, which names escaped and enclosing-scope sites `fresh_k`.
3. **Once closures.** The lemma covers only calls in checked code (R2-F3).
4. **Entry.** "Every escape that `init`, any arm, any command … can create appears in it". This is
   false for cells that `update` creates (R2-F1), and P7 is not a property any current platform can
   have (R2-F5).
5. **Dead aliases.** References to `let`-function closures are not accounted for before their
   textual creation (R2-F7).

**What survives.**

- Termination and the least fixpoint survive the fixes. Each adds finitely many elements (`◇.q`,
  `esc`, `⊤`) to finite sets, and each new transfer is a union.
- The optimality argument ("the least solution is the intended one") is unaffected.
- Monotonicity is still asserted, not shown. I found no non-monotone rule: the split rule, `excl` and
  the ownership bit all move pessimistically as liveness grows.

**Fix.** Repair the five statements together with R2-F1–F3 and F7. The *Flow facts* lemma should
quantify over provenances, not over "parameter paths or fresh".

---

## Language-change cost

### R2-F10. Change 4 (list syntax always builds) reverses the owner's W35 decision and turns the corpus's prepend accumulators quadratic; one guard fixture would exceed the test budget

**Severity:** language-change cost, in conflict with an existing decision.

**The decision.** `language.md` §6.8, amended 2026-10-01 by the owner (W35, E1tp): "`[ x, ...xs ]` is
cheap … so Elm's `x :: acc` then `List.reverse`, `foldr` building a list, a persistent stack and a TEA
list that gains rows at the top are all linear, and **no way of building a list by prepending is
quadratic**." O6 makes `++` on lists call `List.append`, which is amortised O(1) for `[ …acc, x ]` and
`acc ++ [ x ]`.

**What Change 4 does.**

- Every `[ x, …acc ]`, `[ …acc, x ]` and `acc ++ [ x ]` copies (Table 8.1: "O(|result|)").
- Its "Costs" paragraph says this is "as `acc ++ [ x ]` already does in Elm", which leaves out that
  Elm's canonical prepend, `x :: acc`, is O(1).

**Counts** (grep, approximate):

- 106 prepend-spread expressions in core, platforms, the corpus and examples, of which about 34 are
  accumulators in a fold lambda or a tail-recursive loop;
- 14 `[ …acc, x ]`;
- 88 `++ [ … ]`;
- the core library's own documented idioms:
  `Dict.foldr d [] (λkey _ names → [ key, …names ])` (`core/Dict.beni:507`) and its `Set`
  counterpart.

**The fixture.** `tests/corpus/run/ListPrependDeep.beni` exists to guard W35, and its header says:
"The guard was proved by a scratch core whose `cons` always copies and whose `append` never pushes:
this program then exceeds the test budget." Change 4 makes the gates red. Under the project's rule 10
that is a finding, not a test to weaken.

**What the thesis offers instead.**

- The warning fires only where the named writer would be accepted.
- Change 8 restores O(1) only for `List.cons` spelled by name. The decided list syntax (`::` was
  removed in favour of it on 2026-10-01) thus becomes the slow spelling, and `List.cons` the fast one,
  although `core/List.beni:73` documents `cons` as "what `[ x, …xs ]` desugars to".

**Fix.**

- State the reversal of W35 and O6 explicitly, for the owner to decide.
- Or keep syntax linear: where the checker proves the operand unique and dead, which is exactly when
  it would warn, lower the spread to the in-place writer.
  - This adds no silent *copy*; it removes one.
  - It is the one place where an analysis-decided lowering costs nothing in predictability, because
    the warning already exposes the fact.
- Report the cost of `run/ListPrependDeep` under Change 4.

### R2-F11. Change 2 (drop the identity promises) reverses W27 and `language.md` §11.12, on which the template runtime's skip rests

**Severity:** language-change cost, in conflict with an existing decision.

**The decision.** `language.md` §11.12 (W27, decided 2026-09-29, amended 2026-10-01): "the operations
`backend.md` §4 lists return their input itself when their result would equal it". `backend.md` §4
*Identity* lists:

- `filter` keeping everything;
- `map` when every result is `===`;
- `slice`/`take` of everything;
- `xs ++ []` and `[] ++ ys`;
- `concat` with one non-empty list;
- `reverse` and the sorts below two elements.

`run/ListIdentity` pins them. The template runtime skips a `For` "when `items === s.b`"
(`backend.md` §15).

**What Change 2 does.** It makes every one of these return a fresh array. With Change 4, a no-op
spread does too.

**What it costs.** A `view` that renders `List.filter model.todos visible`, as TodoMVC's does, now
hands the runtime a new array on *every* render. Every unrelated message then reconciles the whole
row list, keyed matching included, instead of one pointer test. The thesis lists this as "one O(n)
comparison of items". That understates it, and it does not name the decision being reversed, which
is the one rule 8 of the project calls load-bearing for Solid-level speed.

**Fix.**

- Name W27 and §11.12 as reversed, for the owner to decide.
- Or keep the promises and pay the precision: `res = {fresh, π₁}` matters only when the result
  reaches a writer, and the warning can point such sites at `List.copy`.
- Measure the per-render cost on the template runtime with the existing harness.

### R2-F12. Change 9 (sending consumes) makes programs that never write in place fail

**Severity:** language-change cost; a false error, rare.

**Where.** P6, Change 9, §9.1 item 3.

**The problem.** Under Change 9, `send (Got rows)` followed by any use of `rows` is an error at the
sender, and so is `Cmd.perform (λsend → send (Saved model.todos))`. This holds whether or not any
named writer exists anywhere in the program. It contradicts:

- the thesis's own scope (§1: "the rule is about the writers");
- the claim that the two applications are accepted because they "contain no demand at all". That is
  true only because neither sends a list it keeps; by `grep`, the corpus has few such sends.

The rejection buys no guarantee in a program without writers, so it fails the "guarantees, not
restrictions" test the thesis applies (Ch. 9).

**Fix.** Make `send` *alias* its payload with the sender's holders rather than consume it. The
entry check knows from `update`'s summary which payload paths an arm writes, and can reject only
there, at the arm.

### R2-F13. The cost of the remaining changes

**Severity:** language-change cost.

| Change | Cost found | Conflicts |
|---|---|---|
| 5, ownership words on `foreign` | trusted vocabulary on every sibling; inference stays complete | none |
| 8, headroom for the named `cons` | views become common; fast prepend needs the function, not the syntax (R2-F10) | the spirit of the 2026-10-01 bracket-syntax decision |
| 10, demands as optimiser barriers | the single-use fold may no longer place `xs.length` past a call; a small size cost, unmeasured | none, but it is a change to `language.md`'s evaluation-order licence |
| 11, `eq`/`compare` only read | 108 `pub eq`/`pub compare` declarations in core, platforms, the corpus and examples; those I read only read; Debug-logging inside `eq` stays legal (R+A on a Bool result is not A) | none; cheap, and it holds |
| 12, `init` a function | 253 corpus and example programs call a constructor, almost all with a value `init`, plus both applications and every `Tea`/`Browser` constructor except `Tea.application` (already a function); `Tea.sandbox` diverges from Elm's `Browser.sandbox` | the project's "mirror Elm's API unless beni forces it" practice: here the rule forces it, which should be said; and it is required, not a trade (R2-F6) |
| 13, drain sync commands | reverses W53 (R2-F5) | `boundary.md` §9.8.4 |
| 14, crossing published | interface content; must also cover `foreign type`s (R2-F4) | none |

---

## False errors

### R2-F14. P6's per-arm aliasing cannot be expressed by an entry check that reads only summaries

**Severity:** false error, rare.

**The problem.** P6 says a view-event payload built from a model path "is aliased with the model at
the arm". The entry check, however, runs once, at the program's start, against `update`'s whole
summary, which is not conditional on the message's constructor: a summary conditional on a value is
"outside the summary grammar" (§13.3). With one handler `onClick={Keep model.rows}` anywhere in
`view`:

- `msg`'s `Keep#0` may hold `model.rows`'s cell;
- **Disjoint** fails for `W ∈ use(π₂.rows)`;
- every arm's in-place edit of `model.rows` is rejected, including `Add t → List.push model.rows t`,
  which never sees `Keep`.

**Fix.** Make the entry check per arm, using the write-set analysis's per-message split, which
already exists. Or accept the coarseness and list it among the limit tags.

### R2-F15. "Escaped for the program's life" is per model field and forever, even where the old holder provably cannot run after the write

**Severity:** false error. Common *(guess)* once R2-F1 is fixed.

**What becomes uneditable.** Once escapes of built lists are tracked (R2-F1), every model field
becomes uneditable in place for the program's life when any of these happens:

- any arm hands a list built from it to a waiting command (the usual "save" shape);
- any subscription tagger mentions it;
- it started as a top-level constant, as in `KeyedInPlace`'s `init = { rows = rows, … }`.

**Why that is too coarse.** Taggers are replaced at every render (`Tea.beni:451-459`), so an old
tagger never runs after the next write. A waiting command whose request has completed holds
nothing. The approximate tag "a command that may run after later messages" covers the first case
only.

**Estimate** *(guess)*. CRUD applications that persist through Http would lose in-place editing of
every persisted list. That is the population for which in-place edits would matter.

**Fix.**

- Give the evaluation a separate count of this tag.
- Consider a "held until the command's fiber ends" fact for keyed commands with `Restart`.

---

## Citations

### R2-F16. New citations: mostly accurate; one internal contradiction and a few unverifiable characterisations

**Severity:** citation.

**Verified against the local sources:**

- **Mazur 2004:** "a pre-condition that must be met by the caller", "backbone of the first list is not
  live in the calling environment", "higher-order calls are not handled at all", and "a plain
  non-optimised version that is always safe to use" are verbatim. The page locators were not checked.
- **Clebsch et al.:** "8 reference capability annotations and 3 uses of recover in 249 LOC"
  (Pony/HPCC).
- **Austral:** the use-once rule, verbatim.
- **Vale:** "insert a run-time check", verbatim.
- **Clarke et al. §5.2:** Huang et al.'s "Kleene iteration of a monotonic transfer function" with a
  "programmer-supplied metric", verbatim.
- **Capybara:** "rejects only the interfering use" and "mode inference" (§6.1).
- **de Vries et al. 2008:** the `isEmpty`/`shrink`/`grow` rank-2 example in §6, and "the type of every
  binding in a recursive binding group must be non-unique" in §7.

**The seven secondary-source works.** The `refs.bib` entries for Bloss (FPCA '89), Hudak (LFP '86),
Jones and Le Métayer (FPCA '89), Baker (LFP '90), Guzmán and Hudak (LICS '90) and Odersky (POPL '91,
ESOP '92) have plausible venues and DOIs. I could not open any of them; they are not in
`references/ownership/`. Three issues:

1. **A contradiction about "earliest".** Ch. 12 calls Guzmán and Hudak "the earliest typed precedent
   we know of for ordering reads before writes". App. B calls Aspinall et al.'s **Let** rule "the
   reads-before-writes rule in its earliest typed form". Wadler's `let!` (1990), cited in the same
   paragraph as Guzmán and Hudak, is at least as early. Keep one claim, or none.
2. **Guzmán and Hudak "infers single-threadedness for polymorphic code".** Whether the LICS paper gives
   *inference*, as opposed to a type system, is the kind of detail a secondary source gets wrong
   *(guess)*. Soften it to "a type system for single-threadedness".
3. **The `hudak1987semantic` entry** has `year = 1986` and an LFP '86 venue. The key is cosmetic, but
   the text's year follows the bib.

---

## Fidelity

### R2-F17. Smaller fidelity points

**Severity:** fidelity.

- **`Dict.update`** is described as a "path-copying walk that takes the node's value, calls `f` and
  rebuilds the node". It is `get` followed by `insert`/`remove` (R2-F8). By the thesis's own rule, the
  `get` clears `excl` while `dict` is live, which is why the owned supply must be asserted. Say so.
- **The TEA platform's layering** (R2-F6):
  - `Tea.element` is beni over `Browser.hosted`, which goes through `Js.from`;
  - `browser-direct`'s constructors are `foreign` that the lowering recognises.
  - "An asserted row on the program constructor" fits neither as written.
- **The trusted-surface counts.** "51 public functions" in `List` is the count of *all* `pub`
  declarations, types included (49 are values). The same holds for `Task` (56) and `Schema` (65).
  "54 uses of the `Js` interface" is not reproducible: there are 17 `Js.pure` and 263 `Js.` tokens
  outside comments. State the counting rule.
- **"Seven calls of `List.push`" in core:** I count eight outside comments. This is trivial, but it is
  quoted as evidence.

---

## Standalone quality

### R2-F18. The thesis now reads as a response to its reviewers

**Severity:** standalone.

**The revision log in the body.**

- 22 passages say "an earlier version of these rules / this design / this analysis" (abstract, §3.6,
  §3.7, §3.8, §3.11, §4.7, §4.8, §4.10, §5, Ch. 6, §9.6, Ch. 10, Ch. 11, App. A).
- Table 5.1 labels twelve programs "F1"–"F12", which are the referee's numbering.
- The conclusion says "that is where we would direct a reviewer next".

This is version history written into the argument; F35 asked for it to be removed. A thesis states
the design it defends.

**The structure.** The model chapter depends on six "required" changes (2, 4, 5, 10, 11, 14) that are
introduced only in Ch. 10, after the cost chapter. The language under study is therefore beni plus
six changes, and with R2-F6, seven. The title, abstract and §1.4 should say so.

**A term.** §1.4 defines "Demand" with "Nothing in user code is a demand". But a call of a once
closure, and its creation, are demands in user code (§3.10, §4.4).

**Fix.**

- Move every "earlier version" passage, and Table 5.1's history, into one appendix, "The rules'
  history and the programs that shaped them", with neutral labels.
- State the modified language L′ in Ch. 2 or Ch. 3, and leave Ch. 10 for the trades.
- Fix the definition of "Demand".

### R2-F19. The pre-registered decision is all but determined by the platform choice, and its denominator may be tiny

**Severity:** standalone (method).

**Where.** §11.3 and §11.7.

**The problem.**

- **The platform.** Criterion 2 is measured "over the external corpus on the platform its programs
  use". Ported Elm applications would use `browser-tea`. There, by §6.9, every in-place edit of a
  rendered list is rejected, with an approximate tag. Criteria (a), fewer than 10 % rejected, and (b),
  fewer than half approximate, then fail almost by construction, so the outcome, the warning mode, is
  known before the run.
- **The denominator.** Under Change 4, ported Elm code calls the named writers only where it used
  `Array.set` and similar functions. The denominator of "demand sites" may be a handful per
  application, and no minimum is set.

**Fix.**

- Pre-register the platform on which the decision is made, which is presumably the direct platform.
- Set a minimum number of demand sites, or pool across applications with the pooling rule stated.
- Report the template-runtime rate as context, not as the criterion.

---

## Minor

### R2-F20. Small points

- **Table 6.1** omits `Browser.hosted`'s `settle`, which the runtime calls once per render on the
  model (`Tea.element`'s `settle` calls `app.subscriptions state.model`).
- **The stability rule (§7.5)** constrains the core library as well. `core/` ships in the binary, so
  any core edit that makes a summary more pessimistic rejects previously accepted programs. The rule
  should say that a core function's published summary may only become more permissive.
- **§9.2** says the warning fires "in exactly that case", where the named writer would be accepted.
  The warning text should name `List.cons`/`List.push`/`List.append` according to the spread's
  position. `[ …acc, x ]` is `push`, not `append`.
- **The F4 trace in Table 5.1** says `++` "stores `ys`'s elements while `ys` lives". Under Change 4 it
  is the literal rule of Table 3.2 that does it, and the row should cite that rule.
