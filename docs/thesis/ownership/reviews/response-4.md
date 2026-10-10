# Response to the round-4 referee report on "Edit in Place or Not at All"

**Revision:** 10 October 2026. LaTeX sources in `docs/thesis/ownership/` on branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`). The PDF is
`references/ownership/ownership-thesis.pdf`, now **144 pages** (was 130). It compiles with no error, no
undefined citation or reference and no overfull box, and the standalone `grep` returns nothing.

**Summary.** All 20 findings are **fixed**. Three sub-items are declined, each with a reason below: R4-F3's
specific mechanism (`xreq(⟨T⟩)` on the whole opaque value), replaced by a finer one because the coarse one
rejects Conduit; R4-F8's option of evaluating top-level values per use, which the settled rule "top-level
lists are shared" excludes; and R4-F9's whole-program set of send sites, replaced by a bit per message path
in the existing supply vocabulary. The verdict "one more round" is answered differently from the earlier
rounds: this is the last paper revision, and the thesis now says the next phase is a prototype checker under
a differential soundness test over generated programs (new §12.1).

| Severity | Findings | Fixed | Declined sub-items |
|---|---|---|---|
| Soundness hole | R4-F1 – R4-F5 | 5 | F3's mechanism (replaced) |
| False error, common | R4-F6 – R4-F8 | 3 | F8's per-use evaluation (settled rule) |
| Theory | R4-F9 – R4-F12 | 4 | F9's whole-program send sets (replaced) |
| Coherence | R4-F13 – R4-F15 | 3 | 0 |
| Fidelity | R4-F16, R4-F17 | 2 | 0 |
| Minor | R4-F18 – R4-F20 | 3 | 0 |

**Numbering.** Chapters keep their numbers. Inside them:

- §12.1 *The next phase* is new, so the old §12.1–§12.9 are now §12.2–§12.10.
- The trusted-surface audit is a new table in §6.5, and it took the number **Table 6.1**. The table of test
  programs the report calls "Table 6.1" is now **Table 6.2**.
- Programs T1–T45 keep their labels. **T46–T58** are new.
- Change 9 is new. The old proposal O4 is folded into it, so O5–O7 are now O4–O6.
- Lemma 6.10 (*Write sets name every change in place*) is new. The other lemmas of Chapter 6 keep their order.

---

## Soundness holes

### R4-F1. The folds' rows supplied the accumulator owned whatever the callback returned — fixed

**What changed:**

- **A new class atom, "h returns owned"** (§3.7, new paragraph *A callback's result is owned only when
  the rules show it*). It holds when, at every tracked path of h's result, every maximal provenance is
  some `fresh_k`, or a parameter path that the caller supplies owned and h does not escape. It also
  requires that no provenance appear at two paths. It adds to the guard grammar, the lattice's antitone
  tests (§4.6) and the read-off rule (§4.4): an inferred supply bit that holds a callback's earlier result
  is guarded by this atom.
- **The folds' row** (§4.7) is now `supply 2 owned π₂ ∪ g.res if g returns owned; borrowed otherwise`.
  The text explains why: π₂ is counted as owned because that is the guard being established, and π₁ is
  counted as owned only when the element is supplied owned.
- **I2's justification** (§5.2) and **App. A.3** were rewritten.
- **Lemma 6.7** (summary soundness), clause 4, now says what an owned supply promises. Its proof gives
  the induction over the callback's calls.
- **T46** pins both programs and the capture variant.

**Re-traced:**

- **Program 1** (`then defaults`). g.res = {π₂, shared}. Shared is not owned, so the supply is borrowed,
  the edge `W ∈ use_λ(2) ⇒ owned` fails, and the program is **rejected**.
  - With `then []` or `then List.copy defaults` it is accepted, correctly.
- **Program 2** (`then row`). g does not consume π₁, so the element is supplied borrowed, π₁ is not
  owned, and the program is **rejected**.
  - Variant `then [ …row, 0 ]`: g consumes π₁, so `foldl` consumes `rows` and requires it exclusive. The
    element is then supplied owned, and the result {π₁, π₂} is owned. This is accepted if `rows` is dead
    after the fold, and rejected by Dead at the call if `rows` is read. Both are correct.
- **Returning a capture** (`then ys`). g.res = {◇}, so the program is **rejected**. It is rejected even
  when `ys` is dead afterwards. That is conservative, and the message offers `List.copy ys`.
- **Returning `( acc, acc )`** into a tuple accumulator. One provenance sits at two paths, so the result
  is not owned, and the program is rejected if the next iteration writes either path. That is correct:
  the two paths are one array.
- **`foldr`, `String.foldl`/`foldr`** (via `List.foldl`) and **`Dict`/`Set` folds** (inferred) follow
  the same guard.
- **The idioms are unaffected.**
  - I1 and I2 return their accumulator or a list they built.
  - The histogram returns π₂.
  - `evens` returns π₂ on both arms.
  - T43's chain and T44's `Dict.update` (π₁ or fresh) return owned.

**The audit** of every other row is at the end of this response.

### R4-F2. Release unboxing defeated P7's element guard — fixed

**How representation enters the model:**

- **§3.1, new paragraph *The release representation*.**
  - A type of one constructor with one field is its field under `--release`, so a path through that
    constructor step and its field's path denote the same object.
  - The cell analysis is unaffected, because cells are arrays and closures, never constructors.
  - Every identity fact is read modulo the identification, in every build.
- **A10 is restated** (§6.4) as "the checker's types are the backend's types, up to one stated
  representation". It now also requires that any future representation choice which makes two paths one
  object be added before it ships.
- **§9.5** says the same of the backend.

**How it enters the renderer obligation:**

- **P7's IP is closed under the identification in every build** (§7.9, *P7 precisely*, third bullet).
  So `cols[*] ∈ IP` whenever `cols[*].Column#0` is, and development and release builds emit the same
  scripts.
- **The second half of the argument is corrected**: "a constructor erased to its field is rebuilt only
  when its field is".
- **Table 7.2** has a new row for this closure. Its cost is that (f) and (g) also apply in development
  builds to such pages.

**Re-traced:**

- **AddCard** (T47, and the fourth program of §7.9). The column's script is guarded by range only in both
  builds, and the card appears in both.
- **By-id `map` over columns.** (g) patches every row in both builds.
- **`Wrap { items }` wrapping a record.** `cols[*]` is identified with a *record* path, which is not in IP,
  because records are rebuilt. The guard stays, and it is correct: the release element is the new record.
- **Nested wrappers.** The identification is transitive.

We chose the identification over refusing to unbox types whose field path is in IP. The latter would make
an ownership fact change the backend's representation decision, and the representation would then differ
between builds for a reason that has nothing to do with representation.

### R4-F3. An opaque type merged its fields, so callers' `Disjoint` was lost — fixed by a finer mechanism (sub-item declined)

**How opaque types enter the model now:**

- **Slots** (§3.1).
  - The declaring module numbers the tracked paths inside the type's definition, after folding.
  - It publishes their number and which of them are containers, but not their names or types.
  - Importers see `⟨T⟩.1, …`, and `⟨Dict⟩.k`/`.v` is the existing two-slot case.
  - A type with no slot crosses, which subsumes the old proposal O4.
- **A `Disjoint` that a function leaves to its callers between two internal paths** is published between
  two slots, and an importer discharges it as it would for two fields (§3.10).
- **Where paths fold into one slot**, the obligation is that container's `xreq` (§3.10, §3.11).
- **Change 9** (new, required) states this, with its cost: interface content, and churn when a type's
  lists change. **A10** requires the slots to cover every tracked path.

**Why the reviewer's `xreq(⟨T⟩)` was not adopted.** It is sound, but it rejects Conduit. `Feed.update`'s
`CompletedFavorite` arm replaces articles by the message's payload, so two positions of `articles` may
hold one record, and `⟨Feed.Model⟩` as a whole is not exclusive. Under whole-value exclusivity the
`errors` append would therefore be rejected at the home page's entry. With slots, only `errors` against
the other slots is required. The trade-off is written in §7.4 (*An opaque record*) and in Change 9.

**Re-traced:**

- **`Pair`** (T48).
  - `pushA` writes slot `a` and leaves `Disjoint(a, b)` to callers.
  - `fromList`'s result names {π₁} at both slots.
  - The importer's check fails, so the program is **rejected**.
  - Variant `b = List.copy xs`: accepted.
  - Variant `getA` that returns `p.a`: its `res` names slot a, so an edit after it while the pair lives
    fails Dead.
- **Conduit's `Feed`** (T48, §5.5).
  - The home page receives each `Feed.Model` as a `CompletedFeedLoad` payload.
  - `Home.fetchFeed`'s body builds it with `Feed.init` (`errors = []`, decoded articles) and sends it at
    once, so the payload is supplied owned.
  - The two slots hold distinct cells at every entry, and the append is **accepted**.
- **T19** (`Stack`) was reworded to "writes `⟨Stack⟩.1`".

### R4-F4. Folding put two levels at one path — fixed as suggested, plus a split rule

**How recursive types enter the model** (§3.1, new paragraph *Folding, and what makes it sound*):

- **A folded path is a *representative*.** Its *unfoldings* are its positions, a fourth kind of
  container for `excl` (§3.11).
- **A demand at or under a representative records `xreq` on it**: no cell reachable at two unfoldings.
  This is exactly as an element demand records `xreq` on its list.
- **Constructions set and clear the flag as for lists.** A construction that stores one list at two
  levels fails `Disjoint` across the stored paths.
- **Liveness reads prefix order on folded paths, and that is the stated reading** (§3.9). A path is never
  taken to reach another round a fold's cycle. This is sound *because of* the `xreq`: what `t.kids` reaches
  at `.items` is another unfolding's cell.
- **A split for patterns** (§3.11). A constructor pattern that takes a sub-tree out of a representative
  position of an exclusive recursive value separates the sub-tree's cells from the enclosing level's, as
  `[ x, …rest ]` does for a list.
- **Lemma 6.4** (exclusive contents) covers unfoldings, and the gaps list says folding is sound only with
  the `xreq`.

**Re-traced:**

- **The reviewer's `addRoot`** (T49). The demand is at the representative `.items`, so `addRoot` requires
  `π₁` exclusive across levels. `t` stores `xs` at two levels and is not exclusive, so it is **rejected**
  at the call.
- **The fold-aware false error does not arise.** `addRoot` keeps `t.kids`, and prefix liveness does not
  count that as a use of the root's cell.
- **The tree-editing idiom `addItem id s (Node n)`** (§7.4, *A tree*; T49).
  - It is accepted on a tree of fresh lists.
  - The recursive call gets each kid through `map`'s owned supply, which is exclusive because `n` is (the
    new supply edge, R4-F1's audit).
  - Inside the call, the kid's `.items` and its descendants' are different *parameter* paths.
- **An edit two levels down written with patterns in one body**, where the scrutinee stays live, is not
  covered by the split. It stays a limit, with its own tag ("the checker does not tell the levels of
  `tree` apart") and the fix "write it as a recursive function" (Table 5.2).

### R4-F5. The send rule missed a payload edited without being stored — fixed, together with R4-F9

**The new mechanism** (Change 7 rewritten; P6, Lemma 6.9):

- **A `send` is a *supply* to `update`'s first parameter**, in the vocabulary summaries already have. A
  command body is a lambda whose parameter `send` is a function value, and its summary already records,
  for each call of it, the supplied provenance and an owned bit: unique, unescaped, disjoint across its
  paths at the send, and dead after it.
- **The command constructors' rows carry that bit into the command value**: one bit per tracked path of
  the message type, set when every payload sent there is owned.
  - `Cmd.perform` reads it off the body.
  - `Cmd.task` sets it when work and tagger return owned.
  - `Cmd.map` translates it through the tagger.
  - `Cmd.batch` takes the conjunction.
  - `Sub.*` do the same.
- **The edge at the constructor:** a message path that may be borrowed must reach no cell written in
  place. That means neither a path where `update` has W on its message parameter (F5's program), nor,
  round the fixpoint, a model path in IP (T38).

**Re-traced:**

- **F5's program** (T50). `update` has W on `π₁.Got#0`, and the send is borrowed because `rows` is read
  after, so it is **rejected**.
  - Variant where the sender does not read after: accepted.
  - `Cmd.task` with a decoder's fresh result: accepted.
- **T38** (stored, then extended, sender reads): rejected, now by the same edge.
- **T34** (no arm writes): accepted.
- **Two sends of one list, in two messages.** The first send's payload is live at the second send, so it
  is borrowed, and the program is rejected if anything it reaches is written.
- **A `Cmd.map` tagger that puts one payload at two message paths.** The provenance occurs twice, so the
  bit is clear, and the program is rejected if either path is written.

---

## False errors on idioms

### R4-F6. `Dict.empty` and `Dict.update` — fixed

- **Table 3.3's top-level row** now reads: "the abstract value of v's definition, with every cell it names
  renamed `shared(v)`; a path at which the definition holds no cell stays ∅".
  - `Dict.empty = Dict Leaf` holds no cell, so it is not shared.
  - A top-level `[]` is still one array, so it is still shared (T3 stands).
- **`Dict.update`'s row** (§7.4) is now `aliased; consumed+aliased and requires excl if g consumes 1`, with
  an owned supply only when g consumes and the dictionary is exclusive. It also gains `supply 1 excl if π₁
  excl` (the audit's edge).
- **T44 and App. A.5 were re-traced.**
  - Step 1 now says `Dict.empty` holds no cell, is not shared, and is exclusive.
  - Step 4 adds that the fold's callback returns owned.
- **T51 pins both of the reviewer's programs.** `init ⊤ = { tags = Dict.empty }` with
  `Dict.update … (λ_ → Just [ t ])` is accepted, and so is `( Dict.update d k f, Dict.size d )` with a
  reading `f`.

### R4-F7. An identity promise kept across the entry — fixed (named, counted, weighed)

The claim that the promises cost precision "only where the source is used again, which the idioms do not
do" was corrected where it appeared:

- §3.8 now names the kept copy as the one common form that pays.
- §5.2 I4 says the same.
- O2 was rewritten: it now recommends keeping the promises *narrowly*. It weighs the kept copy and the
  splices, and explains why a view-only promise cannot be expressed. The decision rests on the count of
  the kept-copy tag.
- Table 5.2 has a new row, "a filtered or mapped copy kept beside its source". It is tagged limit (real
  when the filter kept everything), and the fixes are `List.copy` at the store, a relational entry, or O2.
- §12.5 has a new count line, *kept copies*.
- Decision 4 now decides a relational entry on the entry-merge and kept-copy tags together.
- Open question 5 (relational entry) names it as the second customer after undo.

T52 pins the program.

### R4-F8. A top-level `initialModel` — fixed (named and counted); per-use evaluation declined

**Named and counted:**

- §3.10 now has a paragraph on it, with the fix the message writes (`initialModel ⊤`).
- §7.9 *init is a function* mentions it.
- Change 4's costs mention it.
- Table 5.2 has a row "a top-level model" (position), with a paragraph in §5.4 that says it is probably
  the commonest rejection in ported Elm code.
- §12.5 reports it on its own line.
- §12.8 says the port makes `init` a function and **leaves `initialModel` as written**, so criterion
  2(a) is neither met nor failed by the porting rule.
- T53 pins it, and open question 3 asks its frequency.

**Declined: evaluating a top-level value per use.** It would remove the rejection, but it reverses the
settled rule that top-level lists are shared. The thesis says so in §3.10 and does not propose it.

---

## Theory

### R4-F9. Send-site provenance had no place in summaries — fixed (whole-program alternative declined)

See R4-F5. The mechanism is the existing `fun(j).supply(k)` fact of the body's `send` parameter, carried
under the command type's opaque step as one bit per message path:

- **Bounded** by the message type's tracked paths, not by the number of sends (§4.9).
- **Published** with the summaries (§4.10).
- **A fact, not a guard.** "Owned at the send" is decided where the send is written, and "reaches a
  written cell" at the constructor. So nothing whole-program and no surviving guard is needed, which keeps
  §3.7 and §4.10 true.

**Declined:** publishing the set of (send site, provenance, dead-after) triples. It would grow interfaces
with the program and make the check whole-program over sites. Its one advantage, finer precision when one
send site keeps its payload and others do not, is listed as open question 11.

### R4-F10. A12 can be proved — **yes, proved (sketch), with A12 narrowed to the analysis's own soundness**

The new **Lemma 6.10** (*Write sets name every change in place*) states the following. In an accepted
program with no stale use before the current dispatch, if the in-place run's value at a model path r
differs in content, at any depth, from its value before the dispatch, then r conflicts with
`writes(κ)`.

**Proof (sketch):**

1. The bisimulation relation of Lemma 6.2 relates every current S_u reference to an S_v value with equal
   contents at every depth.
   - Lemma 6.2's correspondence is now stated as a relation.
   - Writes that leave contents unchanged (`xs ++ []`, `swap i i`, out-of-range `update`) raise no
     version.
   - `map` returning its input after in-place element edits is related to S_v's new array, outside the
     chain (the A11 case).
2. So S_v's model differs in content at r exactly when S_u's does.
3. In S_v nothing is mutated, so different content implies a different object (`!==`, or not `same` for
   views), and r is *changed* in the write-set analysis's own sense.
4. Its soundness statement, which is about the value semantics it was designed for, covers r.

**What changed in the thesis:**

- **A12 is now** "the write-set analysis meets its own soundness statement". That is its existing
  contract, argued rule by rule in its own design, and no restatement over contents is needed.
- **P7's argument** (§7.9, *Why write sets provide it*) uses the lemma for its first half.
- **§9.4** drops the "restatement". The run-time check of the lemma stays as a test.

The reviewer's caveat holds. The derivation needs no write-set rule that concludes `Same` from an S_u-only
fact, and none can, since the analysis is defined over S_v. So A12 remains an assumption only in the sense
that the write-set analysis's own soundness argument is itself a sketch. The gaps list says so.

### R4-F11. P7 mixed entry paths and current paths — fixed

- **IP is now a set of *entry cells*** named by entry paths (§7.9).
- **"May hold an IP_κ cell"** is decided by the ownership analysis of the new model, whose paths' cells are
  named in entry terms through `update`'s `res`.
- **A sentence on moved cells** was added: `{ model | a = [ …model.b, x ], b = [] }`. The cell is found at
  `a`, and the renderer's last value at `a` is another cell by `Disjoint` at entry.
- **(f) and (g) are rephrased** as "a list whose elements may hold an IP_κ cell", which covers derived
  lists reached through the reconciler (`Dict.values model.groups`, a filtered grid).

### R4-F12. The platform's own in-place records — fixed

- **IP includes the records** the direct platform assigns through on paths its own rule proves owned, if
  that slice is adopted (§7.9, second bullet).
- **The argument's second half** now says that every object a dispatch can change while keeping its
  identity is in IP.
- **§9.7 is rewritten.**
  - The platform's rule ("no group decides unchanged by the identity of an object on an
    in-place-written path") is the stronger A4 the old text asked for.
  - The two mechanisms are compatible only if adopted together.
  - Whether the ownership checker should decide record ownership is open.
- **A3, A4 and Change 8** say the same, and open question 7 lists it.

---

## Coherence

### R4-F13. The test mode ran the template runtime in place — fixed

**§12.2 (the differential run):**

- The in-place backend is linked into the direct platform and Node only.
- The text says why not into the template runtime: it is outside S_u by rule 7, and an in-place run there
  would differ from the value run on correct programs, TodoMVC's `hidden` among them.
- **A shadow mode** is added for the template runtime and other persistent targets. Each accepted demand
  marks its consumed array *superseded*, and any later program read of a superseded array traps. The
  runtime's identity holds are exempt. This detects exactly the stale uses without writing in place.

The theorem's description of S_u (§6.1) was scoped to match.

### R4-F14. Generic bodies write through `where` methods — fixed

**§4.8:**

- A generic body writes a value of type `a` only through a method.
- Its writes and the side conditions it leaves to callers are guarded on the method's class, and decided
  where the evidence is bound.
- The message points from the caller's argument to the generic body's line.

§7.3 is aligned, and T55 pins `bump x = x.push 1`.

### R4-F15. Stale claims about the examples — fixed

- **Conclusion.** The "three adversarial readings found no accepted program…" bullet is replaced by "The
  core is not yet shown to hold". It says the last reading found holes in parts called settled, that each
  was an interaction with a local repair, and that we do not claim the repaired rules sound.
- **App. D** has a new *Present form* paragraph. The old *Present form* becomes *Fifth form*.
- **Conduit's counts, verified against the sources:**
  - 14 list constructions with `++` and 16 operators.
  - 7 constructions have a left operand built in the same function: four literals (`Article` ×3, `Api`)
    and three locals (`Home`'s chain of two, `Settings`' chain of two, `Editor`).
  - 7 are `errors` appends: 5 in `ArticlePage`, 1 in `ProfilePage`, 1 in `Feed`. `Feed` is now called
    "an opaque component nested in the home page's model".
  - There is one spread.
  - A fourth fact, *The feed is opaque*, traces `Feed` through slots.
- **§10.7** says neither application needs (f)/(g), and both need P2's scalar locals and (a)'s rule where
  it applies.

---

## Fidelity

### R4-F16. P2 is not "already so" — fixed

**P2** (§7.9) now:

- quotes the direct platform's step 0 (`const old = model`, read after the arm);
- says that reading a scalar field of it is harmless, but an index computed from an old list (a position
  before a removal) is not;
- requires the binding to become scalar locals computed before the arm;
- says that whether any derived value's old input is a list we have not found in its specification, and
  that if one is, it must be a scalar or recomputed.

Table 7.2 has a row for P2 ("to be changed"). T58 pins a removal by identifier.

### R4-F17. The structure-hole rule was paraphrased — fixed

- **P7(a) now quotes the source exactly**: "written when its key writes it (a `value` write at or above its
  path) and compared by identity only where this document says identity holds".
- **It says what must change.** A structure that may hold an IP_κ cell is written whenever its group runs,
  whatever the tag, or is compiled as a `<For>`. This is marked **to be added**.
- **Table 3.1's group-slot row** now distinguishes scalar and structure holes.
- **Table 7.2** has a row for it, and T54 pins `{model.extras}` extended in place.
- §2.7's paraphrase was left as background and is now qualified by P7(a).

---

## Minor

- **R4-F18.** The limit message now uses `rows = Task.join loader`. Its text says a fiber's result is
  handed to every joiner, and the fix is `List.copy (Task.join loader)`.
- **R4-F19.** Chapter 10's opening scopes the cost guarantee to the direct platform and points to §10.6.
  "The fix is one call … in every case" is now "in most cases". The text names the two exceptions (a
  command, where the fix is to compute before it; a once closure, where the fix is a copy inside the
  callback or a fold) and the top-level model (make it a function).
- **R4-F20.** P7(f) now says why dropping the swap's "data moved" guard is safe. The handler never visits
  again an arm it mounted earlier in the same dispatch, and one key carries one tag per list (two swaps
  join to a replacement).

---

## The summary-row audit (task item 2)

**What was checked:** every asserted row with a function-typed parameter, or claiming a fresh or exclusive
result, for F1's pattern. That pattern is a row that treats a callback's result as owned, fresh or
exclusive, or a container's contents as disjoint, without the rules establishing it.

**Where it is in the thesis:** new paragraph *An audit for one pattern* and Table 6.1 in §6.5. Lemma 6.7's
proof cites it.

**Rows inferred from beni bodies** are covered by the read-off rule, which now guards a callback's result by
"returns owned".

| Row(s) | Risk | Verdict |
|---|---|---|
| `List.foldl`, `List.foldr` | next accumulator = previous result, owned | **fixed** (F1, T46) |
| `String.foldl`/`foldr` | via `List.foldl` | fixed with it |
| `Dict.foldl`/`foldr`, `Set.foldl`/`foldr` | same pattern | inferred; read-off rule guards it |
| `List.map`, `indexedMap`, `filterMap` | result excl from callback results; owned element | sound (`excl if g.res fresh`; owned needs consumed + excl) |
| `List.initialize` | result excl from callback results | **fixed**: asserted with `excl if g.res fresh` (inference cannot tell iterations' fresh cells apart; T37 relied on it) |
| `List.update`, `Dict.update`, single-pass rows | owned element to a callback that itself requires excl | **missing edge added**: `xreq_h(k) ⇒ supply k excl` (T57) |
| `List.update` | slot overwritten by "keeps shape" result | sound |
| `Dict.update` | consumed whatever the callback does | **fixed** (F6, T51) |
| `repeat`, `concat`, `concatMap`, `filter`, `take`, `drop`, `reverse`, `sort*`, `partition`, `unzip`, `map2`–`map5` | elements disjoint; result fresh | sound: `π₁`/`π₁[*]` named where possible, no `excl` claimed |
| writers, `copy`, `at`, builder primitives | stored value exclusive | sound: `excl` only if stored exclusively |
| `Task.repeat`, `Task.retry` | result fed back | sound: work takes `⊤`; results only read by the schedule (checked in `core/Task.beni`) |
| `Task.scope`, `uninterruptible`, `restore`, `withClock`, `onExit`, `timeout` | callback result owned | sound: ≤1 call, result `g.res` translated |
| `Task.par*`, `race*`, `forEach*` | child results owned | sound as `g.res`; fibers internal; `forEach` elements borrowed, result not excl unless `g.res` fresh |
| `Task.bracket` | resource owned in use step | sound only as `⊤` (retained for release, A6) |
| `spawn`, `join`, `wait`, `poll`, `Deferred.*` | retained value owned | sound: `⊤` |
| `Ref.update`, `Ref.modify` | contents owned | sound: `⊤`; new value escaped |
| `Schema.decode`/`parse`/`read` | output fresh and exclusive | **fixed**: only if `mapping`/`injection`/`conversion` functions return owned (T56) |
| `Schema.encode`/`print`/`write` | — | sound |
| `Cmd.task`, `Http.expectStringResponse` | payload a fresh temporary | **fixed**: owned only if work/tagger/callback return owned |
| `Cmd.perform`, `keyed`, `afterRender`, `map`, `batch`, `Sub.*`, `Html.map` | payloads owned | sound as revised (supply bits) |
| markup sites | handlers called once | sound: `many` |
| `Debug.*` | — | sound |
| program constructors' entry row | `update`'s result handed back owned | sound: the fixpoint tracks cells, so shared/escaped/unknown results are found; it is the same loop as the fold, already guarded |

**Result:** five rows or groups fixed (folds, `initialize`, `Dict.update`, schema parsers,
`Cmd.task`/`expectStringResponse`), and one missing edge added. The rest are sound.

---

## Idioms still rejected (after this revision)

- **Real sharing:**
  - a version kept and then extended;
  - the base read again in the same expression;
  - a list a command captured and a later message edits;
  - a once closure passed to a `many` position;
  - a lookup–edit–re-insert;
  - a fold callback that returns a list it does not own.
- **Position:**
  - a top-level list as a base;
  - a top-level `initialModel`;
  - a model list as a base in `view`.
- **Limits:**
  - splices and rotations by `take`/`drop`;
  - a filtered copy kept beside its source;
  - an undo history of a list (needs a second copy);
  - nested edits in containers not known exclusive (`List.repeat`, undeclared decoders, schemas whose
    mapping reuses a list, a tree with one list at two levels);
  - an edit two tree levels down via patterns in one body;
  - lists from `Ref`/JavaScript/`Task.join`;
  - a view event carrying a model list.

The ones most likely to matter in practice are `initialModel`, the kept filtered copy, and command
captures. All three are counted on their own lines.

## Next phase (task item 6)

§12.1 is new. It describes:

- **The prototype checker in report mode.**
- **The differential soundness test.** Both semantics are run, with the version-stamping sanitiser trapping
  any stale read.
- **Three sources of programs:** the test corpus, the applications, and **randomly generated programs**
  that cross folds × top-level values and captures, captures × spreads, containers × callbacks returning
  what they did not make, opaque and recursive types × demands, and every program built in development and
  release.
- **Shrinking and pinning** of every trap, with the rule repaired before anything proceeds.

It says plainly that four rounds of reading kept finding interaction holes (nine in the last two), and that
this is why testing comes next. It also says the decision criteria apply only after this phase finds no trap
over a budget fixed in advance.

Recommendations 1–2, the gaps list (*Interactions*), the abstract and §1.1 are aligned with it.
