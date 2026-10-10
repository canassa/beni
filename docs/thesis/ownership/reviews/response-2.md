# Response to the round-2 referee report on "Edit in Place or Not at All"

**Revision:** 10 October 2026. LaTeX sources in `docs/thesis/ownership/` on branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`). The PDF is
`references/ownership/ownership-thesis.pdf`, now **117 pages** (was 99). It compiles with no undefined
citation or reference and no overfull box, and the standalone `grep` returns nothing.

**Summary.** Of the 20 findings, **18 are fixed** and **2 are declined in whole or in part** (R2-F14, and
R2-F15's second suggestion). The verdict "one more round, not broken at the core" is accepted. The
revision also applies the author's four decisions of 2026-10-10 and reframes the thesis around a new
central question. Both changed the design more than the findings alone would have.

| Severity | Findings | Fixed | Declined |
|---|---|---|---|
| Soundness hole | R2-F1 – R2-F4 | 4 | 0 |
| Round-1 repair failed | R2-F5, R2-F6 | 2 | 0 |
| Theory | R2-F7 – R2-F9 | 3 | 0 (R2-F8's effect atoms are moot) |
| Language-change cost | R2-F10 – R2-F13 | 4 | 0 |
| False error | R2-F14, R2-F15 | 1 (R2-F15 in part) | 1 (R2-F14), and R2-F15's refinement |
| Citation | R2-F16 | 1 | 0 |
| Fidelity | R2-F17 | 1 | 0 |
| Standalone | R2-F18, R2-F19 | 2 | 0 |
| Minor | R2-F20 | 1 | 0 |

**Chapter numbers below are the revised thesis's.** Ch. 1 Introduction, Ch. 2 Background (new §2.10 *The
language the checker is designed for*), Ch. 3 Model, Ch. 4 Inference, **Ch. 5 Idiomatic Code Through the
Rules (new)**, Ch. 6 Soundness, Ch. 7 Hard cases, Ch. 8 Errors, Ch. 9 Compiler, Ch. 10 Costs, Ch. 11
Changes, Ch. 12 Evaluation, Ch. 13 Related work, Ch. 14 Conclusion. Appendices: A Programs, B Prior art,
C Method, **D The rules' history (new)**. Test programs are labelled T1–T34 (Table 6.1). The mapping from
the referee's labels is at the end.

---

## How the author's decisions were applied

### 1. Never a silent fallback

- Stated as rule 2 of the language under study (§2.10) and as Change 2 (Ch. 11): the compiler never copies,
  and never picks a slower algorithm, to make an edit safe. Every O(n) copy is `List.copy`.
- **The warning mode is removed.** It copied where the checker would reject, so it was a silent fallback
  in all but name. §10.8 *Escape hatches* says why there is none.
- **The decision criteria change** (§12.7). If the error rate is too high, the rule is not adopted yet: the
  persistent `List` stays, the frequent tags are addressed, and the experiment runs again. There is no
  shipped copying form.
- The building loop's exit no longer copies its tail (see decision 2).
- §9.5 separates growth from copying. Moving a consumed base into a larger array is growth, amortised as
  JavaScript's `push` is, and leaves no old version alive.

### 2. List construction consumes, like the writers

- The round-1 proposal "literals, spreads and `++` always build new arrays" is **removed**, and with it the
  quadratic-accumulator warning, the "Programs that copy" section and the `build … operand-unique-and-dead`
  dump line.
- **The rule** (§3.8 *Construction consumes its base*):
  - the base is the first spread, or the left side of `++` (which associates to the right);
  - the base is consumed and written in place: items before the spread are prepended into room in front,
    items after it are pushed;
  - the other operands and the elements are only read;
  - a literal with no spread allocates, and a pattern only reads.
- **Two aliases are not writes:** `[ …xs ]`, and re-consing a matched list.
- **The transfer table** (Table 3.2) gains the base row. The writers' rows explain how a construction lowers
  to `cons`/`push`/`append`. The backend table (Table 9.1) is rewritten.
- **One consequence is stated as a decision:** under the rule, `[] ++ ys` cannot return `ys` itself (§3.8).
  Keeping that promise would make the right operand of every `++` an alias of the result, and that
  contradicts "the other operands are only read". Ch. 11, Change 1 names it as withdrawn.
- **The building loop's summary** is now read from the source. `[ x, …appendTo rest ys ]` consumes `ys`,
  `res = {π₂}`, and the exit returns the tail itself when the builder is empty. The old F5 program becomes
  T12, rejected by **Dead** on `ys`.

### 3. `eq` and `compare` may only read

- Rule 3 of §2.10 and Change 3 (Ch. 11), now marked decided.
- §4.8 no longer carries the "if judged not worth it" fallback paragraph.
- R2-F13's observation that `Debug.log` inside `eq` stays legal is stated in §4.8 and Change 3.

### 4. `init` is a function, and top-level lists are shared

- Rule 4 of §2.10 and Change 4 (Ch. 11), now required, with its cost: a text search finds 253 test programs,
  examples and benchmarks that call a program constructor. The thesis also says the divergence from Elm's
  `Browser.sandbox` is forced by the rule.
- **Summaries can now say "shared", "escaped" and "unknown"** (R2-F1): there are new provenances `shared`,
  `esc_k` and `⊤` (§3.7).
- **The exact case from the decision is in the text.** `init ⊤ = { todos = seed }` with a top-level `seed`
  is rejected at the first in-place edit:
  - §3.10 *Top-level values are shared*, with the program written out;
  - §8.2, which gives the message with both fixes;
  - Table 6.1, T21.

### Not decided, so presented as open proposals with costs (§11.3)

- **O4:** publishing "can hold a list" in interfaces. The sound default, without it, is now that a type the
  module cannot see does not cross (§3.1). That costs width, not precision.
- **O3:** the policy for room in front of a list, the `List.cons` headroom details.
- **O2:** dropping the identity promises. It conflicts with the recorded identity decision; the thesis
  recommends keeping the promises and **keeps them throughout**.

---

## The reframing

- **The central question is the one in the brief.** It is stated in the abstract, in §1, and in its own
  chapter.
- **New Chapter 5, *Idiomatic Code Through the Rules*:**
  - §5.1 states the question and the target. It gives text-search counts, with the method in App. C: about
    112 prepend spreads, 30 append spreads, 88 `++ [ … ]`, 16 fold-callback prepends, 56 `update` arms that
    extend a model list (in 37 files), and 8 `List.push` calls in core.
  - §5.2 sets out seven idioms, each with real examples from `core/`, the test programs and the
    applications, the precision that accepts it, and the language or library choice that makes it
    provable: I1 accumulator, I2 fold, I3 recursive builder, I4 map/filter and pipelines, I5 TEA update,
    I6 container edits, I7 tuple accumulators.
  - §5.3: Table 5.1 maps parts of the analysis to idioms, followed by eight language and library choices
    ranked by reach.
  - §5.4: Table 5.2 lists every form still rejected, with kind, fix and the choice that would make it
    rarer.
  - §5.5 re-assesses TodoMVC and Conduit.
- **The main metric** is the *idiomatic error rate*. It is a new count in §12.4, and decision 2 of §12.7
  rests on it: under 1 in 50 idiomatic demand sites rejected, with at least 500 sites from at least 10
  applications, pooled and per median application. The report mode classifies every demand by idiom
  (§12.2).

### TodoMVC and Conduit, re-assessed honestly (§5.5, App. A.1)

**TodoMVC (five programs).**

- Each program has one demand, `model.todos ++ [ new ]`. The pending `{ model | draft = "" }` argument is
  not a use, because `changed` is `unused` at `π₁.todos`.
- **As written, none is accepted.**
  - `init` must become a function.
  - The three programs that persist do so with `save todos = Cmd.do λ⊤ → … (encode todos)`. That escapes the
    list at every entry, so the append is rejected on *every* platform.
  - The template runtime skips a `<For>` whose list is `===` the last one. Through the identity promise of
    `filter`, that list may be `model.todos` itself.
- **With fixes:** with `init` a function and one binding moved before the command, the programs are
  accepted on the direct platform. On their own platform they are accepted only if the template runtime
  adopts the new obligation P7.

**Conduit.**

- It has thirteen `++` on lists:
  - six consume fresh left operands;
  - seven are `model.errors ++ …`, appends in place onto rendered error lists.
- **Outcome:** accepted on the direct platform, by our reading. On the template runtime they are rejected
  unless it adopts P7.

**Common to both.** No acceptance is claimed beyond a hand trace. The gain is stated as small.

---

## Round-2 findings

### R2-F1. Summaries cannot say escaped, top-level or unknown — **Fixed**

- **New provenances** in `res` (§3.7):
  - `esc_k`: a new cell something unseen also keeps;
  - `shared`: a top-level value's cell;
  - `⊤`;
  - and `◇.q`, for R2-F2.
- **Abstract domain** (§3.4): `shared(v)` is a cell kind, and the walk keeps a set `Esc` of escaped cells.
- **Read-off rule** (§4.4):
  - a site made in this body becomes `fresh_k` only if it is not in `Esc`, and `esc_k` otherwise;
  - `shared` and `⊤` are never dropped.
- **Lattice** (§4.6): the order closes upward under `fresh_k ⊑ esc_k`, so the move is monotone.
- **Entry protocol:** P5 (§7.9) carries `esc`, `shared` and `⊤` into the model.
- **Lemma clause 3** is restated as what the read-off establishes.
- **The three programs** are T20, T21 and T22, each rejected by **Unescaped** or **Known**.
- The alternative of aliasing captures into `⟨Cmd⟩` was not taken.

### R2-F2. A closure that returns a cell from its environment looks fresh — **Fixed**

- A class's `res` can name `◇.q`, a cell the closure holds. At a call it is translated through
  `A(g)@◇.q`, as `π_i` is translated through the arguments (§3.6 *Results drawn from the environment*,
  §4.7).
- The read-off rule never names a cell `fresh` unless the body being summarised made it.
- `excl`'s "fresh" now means `fresh_k`, a cell made during the call, never `◇`, `π` or `shared` (§3.11).
- Programs (a)–(d) are T23–T26.
- For (c), a once local function that may call itself is rejected outright (§3.6 *Local functions*, §4.5).
  This is the one place where the rule meets de Vries et al.'s non-unique recursive binding.

### R2-F3. An escaped once closure is never re-checked — **Fixed**

- §3.6 *A once value never escapes*: a value that may be once may not reach an escaping position (an `E`
  parameter at `ε`, an escaped place, markup). The error message is "may be called more than once".
- Every asserted row with a function-typed parameter states `calls`, defaulting to `many` (§3.7, A2,
  §7.7).
- The *Once closures* lemma (§6.3) now covers calls by trusted code.
- The referee's program is T27.

### R2-F4. Crossing is undefined for `foreign type`s — **Fixed**

- §3.1 now says that a type the analysing module cannot see (an opaque type, a `foreign type`) does not
  cross unless its declaration says so. Its values carry `⟨T⟩` cells.
- The constructors of foreign-type values have asserted rows. A markup site escapes the captures of its
  handlers and messages (§7.7, Table 3.1, A6, A10).
- Change 5 now includes foreign types.
- The referee's program is T28.

### R2-F5. P7 contradicts the decided dispatch order — **Fixed (P7 dropped)**

- The old P7, its assumption A12 and Change 13 are **deleted**.
- §2.2 now states the dispatch order: a send dispatches at once, so a body's send runs `update` before the
  next body of the batch.
- §7.8 says nothing depends on when a body runs, and that a command's captures are escaped whether or not
  the body can suspend. The suspension bit is no longer read by ownership (§9.2).
- The referee's batch program is T29, rejected soundly without any promise.
- TodoMVC's acceptance no longer relies on draining. It needs the one-line `save` rewrite (§5.5).
- **Label note:** the label P7 is reused for a *different* obligation, identity skips only on unwritten
  lists. App. D says so.

### R2-F6. Where the entry check runs; Change 12 required — **Fixed**

- `init` is a function, called once per mount (decision 4, Change 4, now *decided* rather than a trade).
  §7.9 states that the protocol is per mount and needs nothing beyond the constructor's call.
- The two-mount program, with `init` a function, is T30: accepted and correct. A value `init` no longer
  type-checks.
- **Where the row sits** (§7.9):
  - on `browser-tea`, on the lower-level host interface the runtime calls; the TEA layer's beni code is
    analysed like any other, its `Js` uses through asserted rows;
  - on `browser-direct`, on the declarations the lowering recognises.
- **Guard cap.** Guards are decided at the constructor's call, so the cap of eight never fires on an
  instantiation (§4.6).

### R2-F7. `let`-bound functions are outside the model — **Fixed**

- §3.6 *Local functions* (with §4.2 and §4.5) treats a block's local functions as one group:
  - their closures are created at the block's entry;
  - captures are read at each call;
  - a function's self-reference holds the group's environments;
  - the group is solved by the same fixpoint;
  - a once local function that recurses is rejected.
- Liveness and the *Dead aliases* lemma account for references before the definition.
- The referee's program is T31.

### R2-F8. Argument-dependent facts are outside the grammar — **Fixed**

- The guard grammar gains argument-state atoms: `π_i excl`, `π_i stored exclusively`, `π_i ⊥ π_j`
  (§3.7). The height bound counts them (§4.6).
- **Effect atoms** are not added: they were needed only for the old P7, which is dropped.
- **Guards on `update`'s class** are resolved at the constructor's call (see R2-F6).
- **Dictionaries:**
  - `⟨Dict⟩` is split into `⟨Dict⟩.k` and `⟨Dict⟩.v` (§3.1, §7.4);
  - the exclusivity condition counts a key and its own value as two paths of one position (§3.11);
  - `Dict.update`'s asserted owned supply requires keys disjoint from values, which crossing keys satisfy
    trivially.
- The referee's program is T32.
- `Dict.update` is now described as it is written (see R2-F17).

### R2-F9. The proof sketch fails at five steps — **Fixed**

All five statements are restated in §6.3:

- *Flow facts* quantifies over provenances.
- *Summary soundness* clause 3 names `fresh_k`, `esc_k`, `◇`, `shared` and `⊤`, with an argument that the
  read-off rule establishes it.
- *Once closures* covers trusted code.
- *Entry* has no P7. It carries `esc`, `E`, `shared` and `⊤`, and relies on A3 and A4.
- *Dead aliases* covers local functions' environments and items of a construction.

Monotonicity is still asserted, not shown, and the text says so.

### R2-F10. Change 4 reverses the linear-prepend decision — **Fixed (by decision 2)**

- Construction consumes, so `[ x, …acc ]`, `[ …acc, x ]` and `acc ++ [ x ]` are amortised O(1) again, in
  place.
- The one part of the decision that construction-as-consumption cannot keep is **stated as a reversal**
  (§5.4, §10.2, Ch. 11 Change 1, App. D): a persistent stack whose old versions are read later now needs a
  copy per kept version.
- **The guarding test program, traced** (T33, §5.4):
  - its four accumulators are accepted in place;
  - its churn stack is rejected, because a kept version may share `s.top`'s array, and a prepend after a pop
    overwrites a slot the kept version shows;
  - with `List.copy` at the kept version (ten copies here), it is accepted.
- **Gate impact.** The test therefore needs a one-line source change once the rule is built. This is the
  one gate impact, and it is stated rather than hidden.
- The named-`cons`-only fast path and its spirit-of-the-syntax conflict are gone.

### R2-F11. Change 2 reverses the identity promise — **Fixed (promises kept)**

- The identity promises are **kept**. Functions with a promise have `res = {fresh, π₁}` (§3.8, §7.2), and A11
  is kept by those summaries.
- **Precision cost:** an edit of a filtered result demands the source dead. That holds in update arms and
  local pipelines, and the message offers `List.copy` otherwise.
- **Dropping the promises** is now open proposal **O2**. It names the renderer cost (a new array every
  render, so every row walked) and the conflict with the recorded decision, and recommends keeping them.
- **The one promise decision 2 does withdraw**, `[] ++ ys` returning `ys`, is named explicitly (§3.8,
  Change 1).
- **Measurement:** the per-render cost of the renderer obligation is part of §12.7 decision 3 and §12.9.

### R2-F12. Sending consumes, which rejects programs that never write — **Fixed**

- Change 9 (consuming send) is replaced by Change 7, *`send` writes what `update` writes*:
  - at the entry fixpoint, the class of the program's `Send` is bound to `update`'s use of its message
    parameter;
  - a send whose payload path an arm edits in place is a demand;
  - any other send only aliases.
- P6 is rewritten accordingly (§7.9).
- The referee's no-writer program is T34, accepted. Load-then-edit stays writable.

### R2-F13. The cost of the remaining changes — **Fixed**

- Ch. 11 is restructured into three groups:
  - **decided:** Changes 1–4;
  - **required:** Changes 5–8;
  - **open:** O1–O7.
- Each change gives its reason, its costs, the recorded decision it touches, and the principle check.
- The referee's points are absorbed:
  - Change 3's count is stated ("over a hundred" by text search; our count of `pub eq`/`pub compare`
    lines was 135, so the referee's 108 was not quoted);
  - Change 4's 253 constructor calls and the Elm divergence are stated;
  - Change 6 (the optimiser barrier) names the cost to the single-use fold and to the evaluation-order
    licence;
  - the old Change 13 is deleted;
  - crossing for foreign types is in Change 5, and publishing crossing is O4.

### R2-F14. P6's per-arm aliasing cannot be expressed — **Declined (coarseness accepted, with a tag)**

- We accept the coarseness. It is listed with a limit tag ("a message sent from the page may carry this
  list", Table 8.1) and counted by the evaluation.
- A summary split by the message's constructor is open proposal **O7**, to be built only if the tag is
  frequent (§12.7 decision 4).
- **Why not now:** messages that carry model lists are uncommon in idiomatic TEA, where messages carry
  identifiers. The text search found no construction on a model list outside update arms. A per-constructor
  summary costs interface content for every program. The message offers to send an identifier.

### R2-F15. "Escaped for the program's life" is too coarse — **Fixed in part; refinement declined**

- **Fixed:**
  - the evaluation counts this tag on its own ("command captures", §12.4);
  - §12.7 decision 4 ties value-taking command constructors to it.
- **Declined:** "held until the command's fiber ends" (§7.8). It needs a run-time fact the checker cannot
  have. We also do not rely on subscription taggers being replaced at every render, since several events
  can reach `update` before the next render.
- **The answer is a library choice instead:**
  - commands that capture the value they need, as Elm's `Http.jsonBody` does (O6, §7.8);
  - a message that offers exactly that rewrite (§8.2).
- This turns TodoMVC's rejection into a one-binding fix.

### R2-F16. Citations — **Fixed**

- Both "earliest" claims are removed: Guzmán and Hudak in Ch. 13, and the Aspinall *Let* rule in App. B,
  which is now "a typed form of the reads-before-writes rule".
- Guzmán and Hudak are softened to "a type system for single-threadedness in polymorphic code".
- The bib key `hudak1987semantic` is renamed `hudak1986semantic` to match its year.

### R2-F17. Fidelity — **Fixed**

- **`Dict.update`** is described as a lookup followed by an insert or a removal (§7.4, App. A.5). The text
  says the inferred rules would clear `excl` there, which is why the owned supply is asserted. The assertion's
  argument is written out: the insert reads neither the old value nor an aliasing key, given exclusive
  contents including keys.
- **TEA layering:** see R2-F6.
- **Trusted-surface counts** (§6.5) state their counting rule:
  - public *values*: List 49, String 45, Debug 5, Task 50, Ref 5, Deferred 5, Schema 42;
  - `foreign` declarations: List 7, Task 5, Schema 7;
  - `Js.pure` occurrences: List 17, String 21;
  - the unreproducible "54 uses of `Js`" figure is dropped.
- **`List.push` in core:** now **eight**: Dict 3, Result 3, Schedule 1, Random.Pcg 1.
- App. C states every counting rule.

### R2-F18. The thesis reads as a response to its reviewers — **Fixed**

- **"Earlier version" passages** are all removed from the body. A grep for "earlier version", "earlier
  edition" and "reviewer" returns nothing.
- **Revision history** lives in one new appendix, **App. D**, "The Rules' History and the Programs That
  Shaped Them". Table 6.1 uses the neutral labels T1–T34.
- **The conclusion** no longer directs a reviewer anywhere.
- **The modified language is stated up front:** new **§2.10** *The language the checker is designed for*
  lists the six rules added to beni. Ch. 11 is left for reasons and trades.
- **"Demand"** is redefined (§1.4, *Edit, demand, base*). It covers writers, constructions, once-closure
  creation and calls, and calls of functions whose summary writes, and it says user code makes demands
  whenever it builds a list from another.

### R2-F19. The pre-registered decision is determined by the platform; small denominator — **Fixed**

- **The platform is pre-registered** (§12.7). The decision rests on the external corpus under the
  template-runtime-with-P7 row, the design proposed for the platform those programs use. The other two
  rows (template runtime as it is, direct platform) are context.
- **The rows are declarations,** so the report mode can evaluate a program under a row whose runtime does
  not exist yet (§12.2).
- **Minimum and pooling:**
  - at least 500 idiomatic demand sites from at least 10 applications, enlarging the corpus by the same rule
    if short;
  - rates are pooled and must also hold for the median application.
- **The denominator is now large by construction:** every ported `x :: acc` is a demand.

### R2-F20. Minor — **Fixed**

- **Table 7.1** has a `subscriptions model, in settle` row (called once per render), and §2.2 introduces
  `settle`.
- **The stability rule** (§8.5) now says the core library is bound by it: a core summary may only become
  more permissive, except for a soundness fix.
- **The warning text** point is moot, because the copying warning is gone. The construction messages state
  which operand is reused (§8.2).
- **The F4 trace** row (now T11) cites the construction rule.

---

## Re-trace of every soundness program from both rounds

All are in Table 6.1. Round 1's first group:

| Was | Now | Program | Decided by |
|---|---|---|---|
| — | T1 | call arguments alias / callback capture | rejected: **Disjoint** |
| — | T2 | optimiser fold across a write | safe: A5 |
| — | T3 | top-level `empty` edited twice | rejected: `shared` |
| — | T4 | view-event payload kept by the model | rejected: P6 aliasing |
| — | T5 | once closure to two ≤1 positions | rejected: **Dead** |
| — | T6 | `Task.join` twice | rejected: **Known** |

Round 1, F1–F12:

| Was | Now | Program | Decided by |
|---|---|---|---|
| F1 | T7 | returned closure's captures | rejected: **Dead** on `(g, ◇)` |
| F2 | T8 | once lost by returning/capturing/storing | rejected: **Dead**, once edge |
| F3 | T9 | `eq` that writes | rejected at declaration |
| F4 | T10 | one cell at two fields | rejected: supply edge |
| F4 rel. | T11 | `xs ++ ys` then nested edit, `ys` read | rejected: supply edge (construction rule) |
| F5 | T12 | building loop returns its argument | **now rejected**: **Dead** on `ys` (was "safe: exit copies") |
| F6 | T13 | `view` spreading model lists | **now rejected** at `view` (base consumed); `List.concat` accepted |
| F7 | T14 | `Reset → init` | accepted and correct (`init ⊤` fresh) |
| F8 | T15 | `pick` through `foldl` | rejected: **Dead** |
| F9 | T16 | `init` aliasing edit in another module | re-checked via `res` |
| F10 | T17 | value held across the write | rejected: **Dead** |
| F11 | T18 | view's cached plain copy | safe: A1 |
| F12 | T19 | opaque `Stack` | rejected: opaque type does not cross |

Round 2:

| Was | Now | Program | Decided by |
|---|---|---|---|
| R2-F1 (a) | T20 | command captures a built list | rejected: `esc₁` at entry |
| R2-F1 (b) | T21 | `init` seeded from top-level `seed` | rejected: `shared` |
| R2-F1 (c) | T22 | `Task.join` wrapper | rejected: `⊤` |
| R2-F2 (a) | T23 | `get = λ⊤ → xs` | rejected: **Dead** via `◇` |
| R2-F2 (b) | T24 | `map` callback returns a capture | rejected: not `excl` |
| R2-F2 (c) | T25 | recursive local closure | rejected: once local function that recurses |
| R2-F2 (d) | T26 | returned captured once closure | rejected: **Dead** |
| R2-F3 | T27 | once `onKey` in model, put in markup | rejected: once value escapes |
| R2-F4 | T28 | handler capture in `Html` | rejected: markup row escapes |
| R2-F5 | T29 | batch whose first body sends | rejected: **Unescaped** |
| R2-F6 | T30 | program mounted twice | accepted and correct |
| R2-F7 | T31 | let function before its line | rejected: **Dead** |
| R2-F8 | T32 | list as dict key and value | rejected: supply edge |
| R2-F10 | T33 | churn stack keeping versions | rejected; accepted with `List.copy` |
| R2-F12 | T34 | send without a writer | accepted |

**Two old verdicts changed under decision 2,** both to *rejected*: F5 (T12) and F6 (T13). Both are correct
under the new rule. In each, the program consumes a list it or its caller still uses (F5), or edits a list
`view` only reads (F6).

## What remains open

- **The renderer obligation P7:** its per-render cost against the reference renderer. It decides whether
  TEA idioms are accepted on the current browser platform.
- **The idiomatic error rate** on real code.
- **The proof:** monotonicity and mechanisation.
- **The trusted surface:** enumerating its rows.
- **The headroom policy** (O3).
- **Command escapes:** whether value-taking commands (O6) remove most of them.
- **The coarse view-event payload rule** (O7).
