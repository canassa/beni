# Response to the round-5 referee report on "Edit in Place or Not at All"

**Revision:** 11 October 2026. LaTeX sources in `docs/thesis/ownership/`. The PDF is
`references/ownership/ownership-thesis.pdf`, now **151 pages** (was 144). It compiles with no error and no
undefined citation or reference.

**Summary.** The report's central finding is right and is fixed: the fresh-result rule of `map`, its family,
`initialize` and the schema parsers established deep exclusivity from freshness *across* callback calls,
and ignored sharing *inside* one call's result. The reviewer's program is now **T59**, rejected. The two
proof defects it names (clause 2 of summary soundness, and the missing configuration invariant) are
repaired and stated honestly, respectively. The monotonicity claim was false for one component; the
thesis now says so and drops the "least solution" claim where it fails. The oracle and A11 are reconciled.
One sub-claim of the report is half wrong (1.7, O2) and the response says which half. The design is not
changed around the report's chapter 2 and 3 proposals; the ones the task names are recorded as open
directions in §14.3.

**Numbering.** No section is renumbered. Program **T59** is new. O2 and O3 keep their numbers (O2 is now a
decision, O3 is withdrawn). Rule 8 of §2.10 is new. Appendix D gains a *Present form* paragraph; the old one
is renamed *Sixth form*.

## Author decisions taken during this round

Four decisions by the author were folded into this revision. They are not answers to the report, but
some of them touch its items.

- **Change 9 is decided.** Interfaces publish an opaque type's slots. It is rule 8 of §2.10, marked
  *Decided* in Chapter 11, and the chapter's introduction and §14.2's recommendation list it with the decided
  changes.
- **Prepending is not an idiom.** The canonical accumulator is `[ …acc, x ]`, a push at the end in amortised
  O(1). The representation reserves no room in front of a list (today's claimable head goes with the trie),
  so `[ x, …acc ]` copies the list. It is still an edit of its base and checked by the same rules. The
  compiler warns on a prepend onto a loop accumulator and suggests `[ …acc, x ]`; it is a warning, not an
  error, because the program is correct and only slower. Changed:
  - the abstract, §1 (*What an edit is*), §2.10 rule 1, §3.8 (the construction paragraph and the cost
    sentence), Table 9.1's `cons` row and the paragraph after it, §7.11 (views), §10 (the cost guarantee,
    *Versions cost a copy*, the representation), Change 1, Chapter 5's opening and I1, §5.4 (the
    linear-prepend decision is withdrawn), Conduit's one prepend (§5.5), and App. A.4, now *An accumulator by
    fold* with the Elm form discussed after it;
  - **O3** (room in front of a list) is **withdrawn**; its slot now says why and states the warning. The
    §12.10 benchmark item and the §14.3 open question about it are removed.
- **O2 is decided: the identity promises are kept.** O2 is now a decision with its cost, not an open
  proposal. It also carries the corrected statement of what dropping them would have bought (see 1.7). The
  relational entry stays the direction that could remove the cost. §7.2, §3.8, §2.10, §5.4's table, §12.8's
  extension list and §14.3 no longer treat it as open.
- **Pattern matching on `[ x, …rest ]`** is unaffected; only building by prepending changed.

---

## 1. Deep open questions

### 1.1. The fresh-result rule admits a concrete counterexample — **fixed**

Verified. "g.res fresh" asked for distinct fresh numbers at distinct tracked paths. The callback
`λ_ → cell = [ 0 ]; [ cell, cell ]` passes, because both positions are the one path `[*]`. `initialize`'s
row then made `rows` exclusive, the outer `update` supplied `pair` owned and exclusive, and the inner append
wrote the shared cell. The value run prints 3; the in-place run prints 4.

**What changed:**

- **§3.8.** "g.res fresh" now asks two things:
  - *across calls*: every maximal provenance is a `fresh_k` with distinct numbers at distinct paths;
  - *within one result*: the callback's `xres` holds at every container path of its result, which is §3.11's
    three conditions.

  The paragraph explains why the first does not imply the second, with the reviewer's callback.
- **The same condition** is now required by every row with that shape:
  - `map`, `indexedMap`, `filterMap` and `initialize` (the same row text, now meaning the stronger thing);
  - the `excl` *set* bullet of §3.11;
  - `Task.forEach`'s result (audit table);
  - the schema parsers: fresh if every mapping returns owned, **exclusive only if each is also exclusive at
    every container path** (§6.5's list and Table 6.1).

  "Returns owned" (§3.7) now says that it is about uniqueness only: `[ cell, cell ]` returns owned, so a row
  that promises an exclusive result must also ask for `xres`.
- **Searched for others.** The folds already use `g.xres` for the accumulator's exclusivity.
  `Dict.update` and `List.update` use "keeps shape", which already requires `xres`. `need fresh excl`
  already says exclusive. `Cmd.task` and `Http.expectStringResponse` claim owned, never exclusive.
- **The lattice (§4.6).** The antitone-test sentence now includes `xres` (a must fact that only falls), so
  the strengthened test is still antitone.
- **T59 (Table 6.2)** has the reviewer's program and its trace: rejected by the supply edge. Variants:
  `List.map`, a schema mapping returning `[ a, a ]`, and `[ [ 0 ], [ 0 ] ]`, which is accepted because the
  two literals are two cells.
- **The Exclusive-contents lemma (§6.3).** Its proof now covers the fresh-results case explicitly. The
  first half, with clause 3 of summary soundness, gives conditions 1 and 3 across positions. `xres_g` gives
  condition 2 within a position. It says that T59 is what the first half alone would accept. The lemma's
  statement was already true; its proof had the gap.
- **The audit (§6.5).** The `map` and `initialize` rows are now **fixed (fifth reading)**. A paragraph
  says that the audit had passed them. "Sound" in the table is defined: the row assumes nothing the rules do
  not establish *for this pattern*.
- **§12.1** counts the fifth reading's find. The generator is told to build heaps with duplicated inner
  cells under fresh outer containers. T59's original row is a **negative control**.
- **Abstract, §1, §6 and §14.1** say five readings. §14.1's "core is not yet shown to hold" names this hole.
  App. D has the history.

### 1.2. Proof gaps — **clause 2 fixed; the invariant stated as missing, not supplied**

- **Clause 2 of Lemma 6.7** now says that the call creates no *new* holder that outlives it, except the
  result at the paths `res` names. The caller's own surviving holders are not the call's to report. The
  reviewer's `n = List.length xs; List.length xs` is in the clause as the example.
- **A new paragraph after the proof of Lemma 6.7** says what the reviewer says:
  - clauses established at *return* are needed *during* calls;
  - "hold of every prefix" for a non-returning call restated the goal;
  - the prefix induction needs one invariant over the whole configuration: open frames with their entry
    permissions, closures and the contract for their future calls, suspended continuations, and runtime
    retention;
  - capture environments enter it as finite graphs with a reachability relation.

  It names a step-indexed logical relation, or simultaneous preservation, as the means. It says plainly
  that this invariant is not written, so the lemmas are a sketch.
- **§6.6** gains *The configuration invariant* as the first gap. §14.1 and §14.3's *The proof* item point
  to it.
- **Mechanisation** is not attempted. We agree with the reviewer that mechanising the present statements
  first would only expose the specification problems.

### 1.3. Two monotonicity claims — **fixed (claim weakened); the stability promise reworded**

Verified. `map` supplies owned exactly when its callback consumes, so a more pessimistic callback earns a
more optimistic supply bit under `owned ⊏ borrowed`.

- **§4.5** now says termination comes from the iteration *joining* each round into the previous state. That
  was already the procedure, so termination holds whether or not every transfer is monotone.
- **§4.6** names the supply bit as the one non-monotone component and explains why. A supply is a
  guarantee, which is ordered opposite to a requirement. The bit is not wrong, because it moves together
  with W on f's own `use`.
- **§4.6 also** states what the solver relies on, `x ⊔ F(x)` iteration stopping at `F(x) ⊑ x`, which is
  exactly validation, and what is lost: the claim of a *least*, most permissive solution where the bit is
  involved. The Clarke et al. paragraph (§4.5) and Chapter 13 make the same qualification.
- **Contracts.** A contract formulation with requirements and guarantees ordered oppositely is named as
  the fix and not written.
- **§8.5 (Stability)** is now called a **compatibility policy with a soundness exception**, not a theorem.
  It explains how the caps on atoms and width, and the non-monotone bit, can turn more precision into a
  rejection. It says a simulation argument would be needed. Until then, each release runs the previous
  release's accepted corpus and treats a new rejection as a release defect unless it is a soundness fix.
- **§6.6's Monotonicity gap** says the same.

### 1.4. The trusted surface is partly an artifact — **split as suggested; derivation recorded as open**

- **§6.5** gains *Three kinds of trust*:
  - **primitive contracts:** list primitives, `foreign`, A1, A3, A4, A7, A9–A12;
  - **derived library contracts:** folds, the `map` family, `initialize`, `Dict.update`, schema mappings.
    These are algorithms, asserted only because the analysis cannot tell calls apart or take an element
    out of a container;
  - **temporary assertions:** every derived row until it is derived. Each carries a derivation obligation,
    and a pinned program is evidence, not proof. T59 is cited as the cost of confusing the two.
- **The four-primitive decomposition** (traversal, focus, builder, close) is an open direction in §14.3.
  It is not a redesign.
- **The audit's use of "sound"** is now defined (1.1 above).
- **The Schema point** is answered by the stronger parser row, which requires owned *and* `xres` for an
  exclusive output.

### 1.5. Summaries are public API — **added**

- **§4.10** gains a paragraph:
  - the `prepare` example;
  - summaries are declared API under semantic versioning (cited);
  - compatibility is more than "consumes no more": a new alias, an escape, a call count, a weakened supply,
    or a changed exclusivity each breaks some caller;
  - comparison must be modulo slot and fresh-number renaming.
- **§14.3** records generated frozen public contracts and a compatibility report as an open direction.

### 1.6. Suspension: transfer and retention — **partly adopted (text), formal split declined for now**

- **§6.6's Concurrency item** now lists what the argument uses beyond one-shot continuations:
  finalisers keep exactly their declared captures, cancellation never reactivates an old continuation,
  re-entrant dispatch keeps the payload hand-over, and runtime-retained results stay ⊤ after their fiber
  ends.
- **The same item** names the precision loss: a read-only scoped child leaves a list escaped forever, and
  a sole owner cannot hand a result through `join`. It also names the four facts the rules merge: parked
  privately, transferred, lent for a scope, and retained for several readers.
- **§12.1's controls** now run several suspension interleavings.
- **Declined:** separating the four facts formally. It needs the configuration invariant of 1.2 first. The
  take-once task result (3.7) is the concrete open direction.

### 1.7. Histories, splices and O2 — **O2 corrected; the reviewer is half right**

- **The reviewer is wrong on one point.** Dropping the identity promises *does* remove sharing of the
  spine: without them `filter` never returns its input, so the result's spine is always fresh. The case
  "a filter that keeps everything returns its input" is exactly the promise O2 proposed to drop.
- **The reviewer is right on the other.** The *elements* are the source's at `[*]` either way. So O2's
  claim "an edit of the result never demands the source" was overstated for an edit *inside* an element.
- **O2 is now a decision** (the author kept the promises; see above). Its text states both halves: what
  dropping them would have bought (a fresh spine), what it would not (element sharing), and that a kept
  copy's `List.copy` is shallow.
- **Separating the three costs** (version preservation, lost separation after a move, slice overlap) is
  partly done already: §7.14 separates the two undo copies, and the splice is its own row in §5.4. The
  second undo copy is the motivating case of the new open direction *Separation along written paths*
  (§14.3), which is the reviewer's own proposal 3.6.
- **A versioned sequence** is O4.
- **Not changed:** the text never calls undo niche.

### 1.8. Report mode and user experience — **metrics added**

- **§12.5** gains three rows:
  - applications accepted, as written and after repair;
  - root causes, reported beside site counts;
  - repair effort: iterations, lines changed outside the reported function, and `List.copy` calls the
    repair introduced.
- **§12.4** freezes the raw port by a recorded commit before any repair, and reports the repaired port
  separately.
- **§12.6** redefines "accidental sharing". The program is correct under value semantics, and what the rule
  catches is an in-place compilation that would be wrong. The reviewer is right that the old wording
  blamed the program.
- **§12.7** adds development tasks (an undo, asynchronous work returning a list, an edit in nested data)
  and a prediction task.

### 1.9. Oracle vs A11 — **fixed**

- **§6.2 defines an exempt comparison narrowly.** It must be all of these:
  - in privileged code, at a site listed with the trusted surface;
  - made through a dedicated primitive;
  - comparing a reference handed to a callback owned with that callback's result;
  - with an outcome that only chooses between two related results, both in `res`.

  `map`'s test is the one such site. Every other stale identity comparison is a use.
- **The proofs follow it.** Lemma 6.2 and the reduction of the theorem exempt it. A11 restates the
  definition and says that a new exempt site must meet it and be listed.
- **Argument about both branches.** The relation paragraph now gives one, position by position, not just
  "res names both", as the reviewer asked.
- **Stamps live on stored reference edges (§6.2).** Reading a field of a current record yields the stored
  reference with its stored stamp. A stale child is never refreshed through a current parent.
- **§12.2** implements the same policy. Stamps sit on stored edges, an exempt comparison is recorded
  rather than trapped, and the sanitised run builds the branch not taken and compares contents. The text
  says the proof and the sanitiser share one executable observation policy.
- **§12.1** adds negative controls (T46's and T59's broken rows, and a removed retention fact), several
  schedules and call counts, and an independent value interpreter where practical.

## 2. Challenge the foundations

### 2.1. A declarative type-and-effect core — **acknowledged, not adopted in this revision**

We agree the choice is not either/or. Presenting the rules as a declarative judgment with the analysis as
its solver is the right shape for the configuration invariant of 1.2 and for the evidence checker of 3.8.
It is the step after this one, not a revision of this text.

**Not changed:** the claim the reviewer quotes ("flows avoid the principal-type problem") does not appear in
this form. §4.5's claim about least solutions is the one we weakened (1.3).

### 2.2. Share semantic infrastructure with write sets — **agreed; no change**

§9.4 already draws the boundary the reviewer endorses. Sharing typed paths and library contracts between
the two analyses is an implementation choice that the prototype will make. The cross-check the reviewer
asks for is Lemma 6.10, which derives the renderer's fact from the write-set analysis's own statement.

### 2.3. Lists only — **no change**

We agree it is a scope, not a semantic boundary. §9.7 and §14.3 (*Records in place*) already say that
record mutation would change today's crossing and acceptance. Parameterising the formal core by locations
and footprints belongs with the declarative core of 2.1.

### 2.4. Fewer exceptional contracts and better APIs — **partly adopted**

The derived-traversal direction (§14.3, 1.4) is this proposal's core. The API half is already there: O5
(commands take values) and messages carrying identifiers.

**Declined for now:** a three-way design comparison. It needs the prototype; it is an evaluation to run,
not text to write.

## 3. Novel directions

### 3.1. Model hand-over as a capability — **no change**

P1 is the obligation this would discharge. The reviewer notes that it does not cover P3–P7 or internal
separation, and we agree. It is a sound way to formalise the driver once the configuration invariant exists.

### 3.2. Messages as permission epochs — **no change**

This is an interesting reframing of the entry protocol. The reviewer's own counterexample (`{ a = xs, b = xs }`)
is why the entry already tracks numbered fresh cells rather than a region. We record it here only.

### 3.3. Witness-producing diagnostics — **no change**

§8.4's exact/approximate split is the static half. A replayed witness would be a strong addition, with the
reviewer's three honest outcomes. It needs an interpreter that the differential test (§12.1) will also
want, so it is a natural follow-on.

### 3.4. An explicit versioned sequence — **no change in the text**

O4 is the persistent-vector option. The reviewer's distinction between full persistence and semi-persistence,
and the point that nested values need their own discipline, should govern O4 when it is specified.

### 3.5. A plain-word vocabulary — **no change**

Chapter 8 already uses reads, keeps and builds. Extending the vocabulary to API documentation and
compatibility reports goes with the compatibility report of 1.5.

### 3.6. Separation along written paths — **recorded as an open direction** (§14.3)

The direction is recorded with the cards-and-labels example, the `model.todos ⊥ model.history[*]` use for
the second undo copy, and the citation of *Uniqueness is Separation*.

**Not done:** we did not redesign `excl` around it.

### 3.7. A task result taken once — **recorded as an open direction** (§14.3)

It is recorded with the reviewer's conditions: the producer must return owned contents and finalisers must
keep no conflicting holder. The Affe citation is kept.

### 3.8. Checkable ownership evidence — **recorded as an open direction** (§14.3)

It is recorded as proof-carrying code (Necula and Schneck, cited), starting with summaries and
exclusive-container derivations. It notes that this would give release stability a precise meaning (1.3).

## Top three recommendations

1. **Repair the core.** The nested-freshness hole is fixed (1.1). The summary-order problem is stated and
   its claim weakened (1.3). The privileged comparison is reconciled with "no stale use" (1.9). The
   formalisation is stated as missing (1.2), not done.
2. **Derivable traversals and compatibility.** Both are recorded as open directions (1.4, 1.5). Ownership
   compatibility is now stated to be part of package API.
3. **Programmer burden.** It is added to the evaluation (1.8).

## What was not fixed

- **The configuration invariant and a written proof.** Both are named as the main gap.
- **A monotone formulation of conditional summaries as contracts.** The thesis now claims a sound
  solution, not a least one, where it matters.
- **A simulation theorem for release stability.** The promise is now a policy.
- **The derivation of the traversal rows.** It is open.
