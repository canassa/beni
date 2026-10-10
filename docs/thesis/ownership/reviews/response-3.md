# Response to the round-3 referee report on "Edit in Place or Not at All"

**Revision:** 10 October 2026. LaTeX sources in `docs/thesis/ownership/` on branch
`research/71-ownership-checker-thesis` (worktree `agent-af6abce79d461e41e`). The PDF is
`references/ownership/ownership-thesis.pdf`, now **130 pages** (was 117). It compiles with no error, no
undefined citation or reference and no overfull box, and the standalone `grep` returns nothing.

**Summary.** All 16 findings are **fixed**. Two sub-items are declined, with reasons: R3-F1's request
to price a per-render cost on the template runtime (moot under the author's new decision, which leaves
that runtime's skips alone) and R3-F10's relational entry (left open; the thesis states the cost
instead, which the finding offered as the alternative). The verdict "one more round" is accepted. The
revision also applies the author's decision of 2026-10-10, which changed the renderer half of the
design more than the findings alone would have.

| Severity | Findings | Fixed | Declined |
|---|---|---|---|
| Soundness hole | R3-F1 – R3-F4 | 4 | R3-F1 item 3 (moot) |
| False error, common | R3-F5 – R3-F8 | 4 | 0 |
| False error, rare | R3-F9, R3-F10 | 2 | R3-F10's relational entry (left open) |
| Theory | R3-F11, R3-F12 | 2 | 0 |
| Fidelity | R3-F13, R3-F14 | 2 | 0 |
| Minor | R3-F15, R3-F16 | 2 | 0 |

**Numbering.** Section numbers below are the revised PDF's. They match the old ones except in
Ch. 10, which gains §10.6 *What it costs on the other targets*, and Ch. 7, whose §7.9 grows a second
table (Table 7.2). Test programs T1–T34 keep their labels; T35–T45 are new (Table 6.1).

---

## How the author's decision was applied

**The decision:** in-place lists are a feature of the direct platform only. Its handlers decide what to
re-render from compile-time write sets, never from object identity, wherever a list may have been edited
in place. The template runtime keeps its identity skips and its persistent lists.

### Scope (§2.10, rule 7)

- It is stated as rule 7 of *the language the checker is designed for*, dated, and marked as reversing
  the previous form of this thesis. That form asked the template runtime to drop its `<For>` skip.
- **Reading we added, stated as ours:** the ownership rule is a rule of the *language*, checked on
  every build whatever the target, so that one source has one verdict and one meaning on both browser
  back ends. The two are compiled from one source and used as each other's test oracle.
  - On a target that keeps persistent lists, an accepted program means what it meant before. The rule
    changes only which programs are accepted.
  - The cost is now its own section, §10.6: rejections paid on targets that gain nothing, and two
    implementations of the list writers in core with one set of rows.
- **Where the decision reaches:**
  - Theorem 6.1: S_u is the direct platform's semantics, plus the test mode; elsewhere S_u = S_v.
  - A3 and A4 are direct-platform obligations.
  - The backend (§9.5): the trie goes on the direct platform only.
  - The evaluation (§12.1–§12.9): one entry row instead of three, external corpus built for the direct
    platform, error rate reported per target.

### The renderer obligation, as now specified (§7.9, *P7 precisely*; Table 7.2)

**IP**, the in-place paths:

- IP is the model paths, list positions included, at which `update`'s published summary has W.
- IP_κ is the subset that conflicts with the key's write set `writes(κ)`.
- A value *may hold an IP_κ cell* when its abstract value names the model's cell at such a path. The
  ownership analysis of `view`'s code decides this, so a user helper that returns its argument counts,
  not only a fixed list of promise functions.

**The obligation:**

> In the handler of κ, no `===` test, and no comparison of two views by base and offset, concludes
> "unchanged, skip" about a value that may hold an IP_κ cell; whatever reads such a value runs because
> the write set conflicts with its read paths.

It is enumerated over every piece of the direct platform's output:

| Piece | What it must do | Status |
|---|---|---|
| (a) groups | run by conflict; compare scalar leaves | already so |
| (b) derived values and `let`s | readers never skipped by the slot's identity | already so (forbids a future skip) |
| (c) helpers and components | no argument-identity skip | already so |
| (d) branches and `Show` | | already so |
| (e) row inputs, selectors | | already so |
| (f) indexed edits and swaps | for element paths in IP: range guard only, row groups run unconditionally | **to be added** |
| (g) `map`-idiom walk, merge, reconciler | for element paths in IP: patch every kept row; still match by key or item | **to be added** |
| (h) length guards | | already so |

**How write sets provide it:**

- Everything is decided at compile time, from three sources: IP from `update`'s summary, `writes(κ)`
  from the write-set analysis, and "may hold" from the ownership analysis of `view`.
- The soundness argument has two halves:
  - a value that holds no IP_κ cell changes identity whenever its content changes, because records and
    constructors are rebuilt and other lists are not written in place this dispatch;
  - a value that does is read only by code that runs because the write set conflicts.
- It needs one new fact, stated as **assumption A12**: the write set names every in-place write.
  - The write-set analysis's own soundness statement is about identity, so it does not give this.
  - Its rules do: every writer and construction is interpreted as a write of its path.
  - The write-set contract is to be restated over contents, and checked when both passes run.
  - The direct platform's verification mode and its differential fuzzing are the run-time safety nets.

**Shown on the three programs:**

- **TodoMVC (T35):**
  - The derived `left` and the groups of both `hidden`s and the count read `todos`, which the Enter
    key's write set names, so they run.
  - The `<For>` over the filtered list runs because it conflicts, and goes through the reconciler.
  - Todos hold no list, so nothing new is needed.
- **Row input (T36):** the class group reading `model.picked` runs on every row.
- **Grid (T37):** `grid[*]` is in IP, so the outer indexed script is guarded by range only and runs
  row `r`'s groups. The inner `set [c]` script keeps its identity guard, which `Shown !== Hidden`
  passes.

**Cost, stated honestly (Table 7.2 and text):**

- Nothing for lists of records: TodoMVC, Conduit, the table page.
- For lists of lists edited in place (grids, boards, spreadsheets):
  - bytes: unguarded scripts and all-rows patch variants, about 40–80 bytes each by the platform's own
    estimates (an estimate);
  - time: O(n·h) leaf comparisons where the identity walk did n pointer comparisons.
- P3's widening, which re-evaluates markup values when their handlers' reads conflict, costs more
  re-evaluation, to be measured.
- The direct platform's harness has no list-of-lists page. One must be added before adoption
  (decision 3 of §12.7, §12.9).

**Presented as the obligation a future slice must meet** (§7.9, *The obligation a future slice must
meet*):

- The direct platform's own design writes in place only for owned paths, and never for an element a row
  shows. That is why its element guards were sound.
- The slice that adopts these in-place lists must meet P1–P7, (f), (g) and P3's markup rule, pinned by
  page tests.
- Until it does, the direct platform keeps persistent lists too.

---

## Round-3 findings

### R3-F1. P7 covered only `<For>`'s skip; TodoMVC wrong under P7 — **Fixed**

- **The template runtime's skips** (grouped values, `let`s, helpers, components, `Show`, row inputs,
  `same()`) are now described in §2.7 and in Table 3.1's holders row as identity holds.
  - They are harmless there because that runtime writes nothing in place (rule 7).
- **P7 is restated** for the direct platform over every identity test (fix item 1), with "may hold"
  read from summaries rather than from a list of promise functions (fix item 2).
- **Your TodoMVC program and the row-input variant** are T35 and T36, decided correctly on the direct
  platform. §5.5 and App. A.1 are re-derived (fix item 5).
- **Change 8 is rewritten** (*in-place lists on the direct platform only, rendered by write sets*).
  - Its *Recorded decisions it touches* names the template runtime's grouped-value, row-skip and view
    promises (kept unchanged there).
  - It also names the direct platform's plan to keep row elements out of in-place updates (changed)
    (fix item 4).
- **Declined: item 3, pricing a per-render walk on the template runtime.** Under the decision that
  runtime keeps every skip, so there is nothing to price there. The corresponding direct-platform cost
  is priced (Table 7.2) and must be measured on a list-of-lists page.

### R3-F2. Direct platform's element-guarded scripts miss in-place element edits — **Fixed**

- P7(f) and (g) drop the element-identity guard, and the reconciler's "item changed" patch test, for
  element paths in IP. The identity guard stays elsewhere.
- Your grid is T37, traced in §7.9.
- "By design" is gone from A4 and Change 8. A4 now says which parts are designed and which (f, g) must
  be added.
- §7.9 states the requirement as the obligation on the direct platform's in-place slice.

### R3-F3. Change 7 inconsistent — **Fixed as you proposed**

- A `send` is a demand on its payload at every path the payload may carry into a model path some arm
  writes in place. The entry fixpoint follows each send site's payload as its own provenance through
  `update`'s results, round the loop (P6, Change 7, Lemma 6.7).
- Your send-then-read program is T38, rejected at the send by Dead.
- `Cmd.task`'s `send (tag (work ⊤))` is accepted, because the payload is a dead temporary.
- T34's wording now says the payload reaches no path written in place.
- Change 7 has a *What changed* paragraph naming the failed binding.

### R3-F4. `view`'s escapes not in P5 or the Entry lemma — **Fixed**

- **P5 now lists the escapes of every platform-called function**, `view` included, through its entry
  row. The Entry lemma's proof says why `view` contributes none on the direct platform.
- **P3 is strengthened.** No value an earlier evaluation of the view made is used after a dispatch that
  conflicts with it:
  - listener bodies evaluate their handler expression at the event;
  - markup *values* on the fallback path include their handlers' reads in their read paths and are
    re-evaluated before any later listener (an addition, stated as such).
- **Your bubbling program is T39**, accepted. On the direct platform the outer listener reads
  `model.log` at its event under both semantics. The template runtime writes nothing in place.
- **Row functions** do not exist at run time on the direct platform. Value-path markup is covered by
  P3.
- **The markup site's row changed** (§7.7). Handlers are held under the markup value's opaque step and
  called `many` times; they are no longer escaped at the site.
  - T27 is now rejected because a once value is passed to a `many` position.
  - T28 is now rejected by Dead.
  - Both still reject.

### R3-F5. Whole-variable capture — **Fixed**

- Captures are per path (Table 3.3 lambda row; §3.6 *Captures are per path*; §4.3; Lemma 6.2's
  statement and proof).
  - A closure holds under ◇ only the paths of a captured variable that its body *uses*, by the
    liveness uses.
  - Uses follow callee summaries across modules, so `Session.navKey model.session` uses `.session` only.
  - A whole use captures every path.
- The run-time closure still keeps the whole object, but the unread paths are dead holders forever. The
  proof says why that suffices.
- **Re-checked:**
  - Conduit's ArticlePage `CompletedDeleteArticle` and the editor, settings, login and register
    commands hold only the session or a key.
  - Main's `toSession model` is read through `toSession`'s summary.
  - ListenerOrder's `Navigation.pushUrl model.key` holds `.key` only.
  - `f = λ_ → model.name` no longer keeps `model.rows` live (§4.3 example).
  - T45 covers both the accepted and the whole-use case.

### R3-F6. By-id `map` edit rejected as "real" — **Fixed (first option)**

- `map`, `indexedMap`, `filterMap`, and the folds for their element, have an asserted **single-pass**
  row (§3.8). When the callback consumes its parameter, the function consumes the list and requires it
  exclusive, and supplies each element owned.
- **Soundness:** each element is read once and never again. The identity check after the callback is a
  stale-reference identity test, covered by A11, now spelled out.
- The previous "real sharing" verdict is withdrawn in §7.4.
- **Coverage:**
  - The card-tags edit and the grid pad are I6 examples, and T42.
  - The rows join the trusted surface (§6.5).

### R3-F7. I6 rejected: `excl` lost on record update; `Dict.update`, folds — **Fixed**

- **(a) "Keeps shape"** (§3.11): every result path holds fresh cells or the element's own cell at the
  same path, and nested containers stay exclusive. It is a class atom; `update`'s and `map`'s rows keep
  `excl` under it.
  - T40 is your record edit inside an `update`, accepted at every dispatch.
  - P5 now states that the entry carries `xres`.
- **(b) `Dict.update`'s row now asserts its supply and its `xres` together** (§7.4). `foldl`/`foldr`
  carry `supply 2 excl if π₂ excl and g.xres` (§4.7).
  - App. A.5 is re-traced step by step through the rows: first call, the callback keeps shape,
    `Dict.update` keeps the flag, later calls. It no longer argues from concrete cells.
  - That trace is T44.

### R3-F8. `map`'s unconditional identity promise; splices and rotations — **Fixed**

- **`map`'s `res` names π₁ only "if a and b may share a value"**, a new *type fact* atom (§3.7 grammar),
  decided on the run-time representation. A one-field, one-constructor type erased by the release
  optimiser keeps π₁.
  - `List.map model.items viewItem ++ [ addButton ]` in `view` is accepted (I4, §7.9).
- **Splices and rotations** are a Table 5.2 row marked *limit (identity promise)*. The message offers
  `List.insertAt`, `List.removeAt`, and a `List.copy` of the operand read.
  - Commentary in §5.4; new tag in Table 8.1 (with R3-F12); O2 mentions them.

### R3-F9. Right-associative `++`; prepending a list onto an accumulator — **Fixed**

- **A chain of `++` is one construction** with its leftmost operand as base (§3.8, rule 1 of §2.10,
  Table 3.3). `a ++ b ++ c` and `[ …a, …b, …c ]` now agree.
- **Change 1 names the decision it replaces:** the specification's right-to-left lowering of list
  literals (`List.append a (List.append b c)`).
- **`acc ++ r.cells ++ [ sep ]`** is an I1 example and T43, accepted.
- **`xs ++ acc` via `foldr`:**
  - It is a Table 5.2 row, with fixes `List.foldl xss [] (λxs acc → acc ++ xs)` (same result, in place)
    and `List.concat`.
  - Under the single-pass row it is now accepted when `xss` is exclusive and dead, and rejected by Dead
    when `xss` is read later. That is real sharing: its elements would change (T43).

### R3-F10. Undo of a list — **Fixed by stating the cost; relational entry declined (left open)**

- §7.14 traces your program: it is rejected by Disjoint at `Add`, because the entry merges `todos` with
  `history[*]`.
- The cost is a second `List.copy previous` in `Undo`.
- It is in Table 5.2 (*limit, merged at entry*) and is T41. A matching approximate tag is in Table 8.1.
- **Declined:** carrying the split across the entry needs a relational entry state. We left it as an
  open question (§14.3) and an extension gated on its tag's frequency (§12.7, decision 4), rather than
  design it now.

### R3-F11. Upward closure puts ⊤ in every set — **Fixed**

- §4.6 now defines the order on provenance sets as the Hoare (lower) order. Its quotient is the
  down-closed sets ordered by inclusion, stored by their maximal elements.
- The height is |Pv| = |P|+|V|+2|Q|+2, so the old figure was right for this order. `supply` is
  |Pv|+1.
- Every test reads maximal elements and is antitone. Known, "fresh" and Unescaped are spelled out.
  The read-off rule is shown monotone in this order.
- The text names the earlier mis-statement.

### R3-F12. Circular main metric; exact/approximate mislabels — **Fixed**

- **The idiomatic error rate** is now computed over *all* demand sites of the external corpus,
  idiomatic by definition. I1–I7 is only a breakdown, and the classifier only labels (§12.2–§12.4).
- **Decision 2 is restated** (§12.7):
  - (a) under 1/50 of all external demand sites, position-rule rejections included;
  - (b) no single idiom above 1/50;
  - (c) under half approximate, with the new tags.
- **Four approximate tags** are added to Table 8.1: identity promise, positions merged under [∗], merged
  at entry, record passed whole.
- **§8.4 redefines "exact"** as a step that names one run-time cell for one run-time cell. It names the
  earlier definition's error.
- **Rejections from the position rule's choice of base** (top-level base, model list in `view`) are a
  kind of their own in Table 5.2 (*position*), in the counts (§12.4) and in the dump (`[position]`).

### R3-F13. Out-of-date renderer, views, identity — **Fixed**

1. §2.7 and Table 3.1 are rewritten, describing every identity skip of the template runtime and the
   direct platform's write-set mechanism.
2. **Views are contiguous slices** (§2.5, §7.11, Table 9.1):
   - a pattern's `rest` is a suffix, `init` a prefix;
   - a push through a view writes `b[o+n]`, safe because Dead requires every holder of the base dead;
   - the re-cons alias rule covers `[ …init, last ]`;
   - if today's lowering copies `init`, the rule is unchanged.
3. "Cell", not "identity", in §3.8 and §9.5: a construction returns its base's cell, its header possibly
   new.

### R3-F14. Conduit misses its spread; verdict depends on R3-F3, R3-F5 — **Fixed**

§5.5 re-traces Conduit:

- the 13 `++` and the one spread `[ comment, …comments ]`;
- the commands hold single fields (R3-F5);
- the comments arrive by `Cmd.task`'s send of a dead temporary (R3-F3);
- rendering on the direct platform is length-guarded scripts and conflict-driven branches.

**Verdict:** accepted as written, by our hand trace. §10.7, §14 and the abstract are updated
accordingly.

### R3-F15. Two message fixes do not work — **Fixed**

- **The closure example** (§8.2):
  - it now uses `List.push`, so the difference is observable (the count is one more);
  - it offers the length bound before line 11, or a copy bound before line 11;
  - a note explains why a copy *inside* the closure does not work.
- **The `map` example:**
  - it offers `[ …List.copy acc, x ]` in the callback, which keeps the meaning;
  - the fold is offered only as a different program, with a non-shadowing parameter `soFar`;
  - the text records that every fix in the chapter was checked against the shadowing rule.

### R3-F16. Smaller points — **Fixed**

- **Once values** (§3.6, Lemma 6.4, Theorem 6.1):
  - the rule now covers every path of a value that may hold a once cell;
  - escape is allowed at a position whose asserted `calls` is ≤1, such as a spawned fiber's or a
    command's body;
  - the message's "more than once" is therefore true when it fires.
- **The withdrawn promise** (§3.8, Change 1, §10.2):
  - it is now stated as "an append whose left operand is empty at run time returns its right operand";
  - §3.8 adds that `xs ++ []` writes nothing but still consumes `xs`.
- **Calls through a function value** (Table 3.3): such a call is a demand only when the value may be
  once.
- **The prepend guard test:** confirmed; no change.

---

## Re-trace

**T1–T34** are decided as Table 6.1 says under the revised rules. Notes on the ones touched by this
revision:

- **Same verdict, new reason:**
  - T27: once value passed to a `many` handler position, instead of an escaping one.
  - T28: Dead, instead of Unescaped, after the markup row change.
- **Re-checked against path-precise capture, still escaped:** T20 and T29, whose bodies use the list
  whole.
- **Re-checked against the new single-pass rows, unchanged:** T8B (`map` still calls many) and T24
  (callback returns ◇).
- **T34** is accepted under the transitive send rule, with its wording sharpened.

**Soundness programs of earlier rounds:**

- Round 1's F-programs are T1–T19.
- Round 2's are T20–T34; R2-F1/F2/F3's one-line variants are re-checked by R3 and still hold.
- Round 3's programs:

| Program | Label | Verdict |
|---|---|---|
| TodoMVC count and `hidden` | T35 | accepted, correct |
| Row input | T36 | accepted, correct |
| Grid | T37 | accepted, correct |
| Send then read | T38 | rejected |
| Bubbling handler | T39 | accepted, correct |
| Record edit in `update` | T40 | accepted |
| Undo of a list | T41 | rejected; accepted with second copy |
| By-id `map` | T42 | accepted; rejected for `List.repeat` |
| `++` chains | T43 | accepted / rejected as stated |
| Fold grouping | T44 | accepted |
| Path-precise command | T45 | accepted; whole use rejected |

**Must-pass idioms (Ch. 5), re-checked against real code:**

- I1:
  - `combineHelp rest (List.push values value)` (core `Result`);
  - `prependAll` and `growPlus` (`run/ListPrependDeep`);
  - `acc ++ r.cells ++ [ sep ]`.
- I2: `Dict.keys` via `foldl`, the documented `Dict.foldr` prepend, `Task`'s `Just [ v, …rest ]`.
- I3: `mapRec` (`emit/TailModConsLoop`).
- I4:
  - pipelines;
  - `[ …List.filter xs p, y ]`;
  - `List.map model.items viewItem ++ […]` in `view` (newly accepted).
- I5:
  - `{ model | seen = [ …model.seen, k ] }` (`browser/direct/EventReadsModel`, a direct-platform test);
  - Conduit's seven `errors` appends and the comments prepend (newly accepted);
  - TodoMVC's Enter (after the two fixes);
  - the undo arm.
- I6:
  - `List.update model.rows 1 λrow → { row | label = … }` (`browser/direct/RowItemOnly`); records
    holding no list cross, and lists of lists keep shape;
  - `Dict.update` grouping in a fold (App. A.5);
  - by-id `map` edits of records with lists.
  - The corpus's by-id `map` edits (`RowMountOrder`, `Keyed`, TodoMVC's `Toggle`/`commit`) only rebuild
    records, so they make no demand.
- I7: `partitionHelp rest errors (List.push values value)`, and the tuple fold.

**Still rejected (Table 5.2):**

- kept versions;
- the base read again;
- command captures of a whole list;
- top-level or `view` bases (*position*);
- a list prepended onto an accumulator while still read;
- splices and rotations by `take` and `drop` (*limit*);
- once closures passed to `many`;
- lookup, edit, re-insert;
- non-exclusive containers;
- undo of a list (one extra copy);
- `Ref` and JavaScript lists;
- view-event payloads.

## Remaining open questions (§14.3)

- the error rate per idiom and per target;
- P7's cost for lists of lists, and A12's restatement of the write-set contract, rule by rule;
- the trusted surface;
- the proof (not mechanised);
- whole-program command escapes;
- `Ref`s;
- path-sensitive joins and value-conditional summaries;
- interface churn and the warm-rebuild budget;
- room in front;
- exclusive contents in practice;
- view-event payloads;
- the identity promises, now with splices as evidence;
- once closures called once in fact;
- a relational entry;
- the rule's cost on targets that do not use it;
- the crash screen;
- record paths;
- primary sources we could not check.
