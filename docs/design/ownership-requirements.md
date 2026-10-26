# The ownership checker — requirements

*Draft 2026-10-25, for the owner's review; not normative until accepted.* This is the WHAT of the checker: every
responsibility and acceptance criterion that a new checker (v2) must meet, with no design. It is extracted from the
sources below; where a requirement and its source disagree, the source wins unless §9 lists the disagreement.
v1 = `src/own/` at origin/master `573555476`. The owner's answers of 2026-10-25 are folded in as [O 2026-10-25].
v2 targets the end state: lists and records enforced on every platform (O4a and O4b done).

**Sources.** oc = `ownership-checker.md`, lang = `language.md`, be = `backend.md`, bd = `boundary.md`,
ws = `write-sets.md`, bi = `browser-inline.md`, dr = `plans/direct-rewrite.md`, fc = `fast-compiler.md`,
CL = `CLAUDE.md`, mem = owner memory (`ownership-no-silent-fallback`, `ownership-v1-frozen`,
`dict-keyed-collection`), #N = GitHub issue.

**Fixtures.** Paths are under `tests/corpus/` unless they start with `p/`. `o/` = `ownership/`, `bbi/` =
`build/bad/inline/`, `bbe/` = `build/bad/everywhere/`, `bb/` = `build/bad/`, `cbi/` = `check/bad/inline/`,
`cb/` = `check/bad/`, `p/` = `tests/pending/ownership/`. `o/X.f` = declaration `f` in `o/X.beni`; `o/X 24:18` = a
line of its golden. A `*` is a glob.

**Tags.** No tag = decided and met by v1. [S] = specified, not built. [G] = v1 is wrong or imprecise and the
requirement stands; every [G] is acceptance for v2 (R-8.2). [O date] = owner decision. [M date] = manager decision.

**Notation.** *Accept* = the write is accepted. *Refuse c* = refused with cause `c` (R-6.3); `(a)` marks an
approximate cause, `(p)` a position cause. Accept and refuse programs are the minimum: v2 may accept more only
where it proves the write safe (R-3.1).

---

## 0. Terms

- R-0.1 **Write**: an operation the language defines as editing a value in place (§2). Its **base** is the value
  it edits. Its **result** is the same object as the base.
- R-0.2 **Holder** of a base: anything other than the write's result that may reach the base after the write: a
  binding or alias, a path of a structure, a closure capture, an operand evaluated earlier and still pending,
  another operand of the same operation, a value the runtime retains (a command, subscription, view handler, fiber
  or queued body), JavaScript, a top-level value, a view of the base.
- R-0.3 **Verdict** of each write: *accepted*; *refused* with a cause (R-6.3); or *pending*, when the write cannot
  be decided where it is written (a writing function that goes where the checker cannot see its calls, "it is
  returned", "it is stored in a record", or a record base with no nameable origin [G #870]). Refused and pending
  are compile errors.
- R-0.4 **Value semantics**: the program's meaning if every write copied its base first. This is the meaning.

## 1. Scope

- R-1.1 The checker gives every write of §2 a verdict (R-0.3). Only accepted writes reach emitted code as in-place
  edits. (oc §28.5, §30.1)
- R-1.2 No fallback of any kind: no silent copy, no copying twin of a writer, no slower algorithm, no warning in
  place of the error, no opt-in strict mode, no run-time ownership test or reference count, no per-platform
  copying. [O 2026-10-10/10-15/10-17] (mem; be §4 *Every platform edits in place*; oc §30.1, §31.1)
- R-1.3 The checker runs in every `check`, `build` and `dump --stage=ownership`, on every platform and with no
  platform; no flag turns it off. Every refusal of a list, `Dict`, `Set` or record write is an error on every
  build, `browser` and `browser-tea` included (only their lowering keeps record spreads, R-1.12).
  [O 2026-10-25; S O4a #320, O4b #978] (oc §30.1, §30.7, lang §6.8)
- R-1.4 One source has one verdict on every platform. A platform changes only the entry protocol it declares with
  `entry` (§5.8) and the lowering (R-1.12); no row is chosen by package, constructor name or renderer.
  (oc §20.2 amended 2026-10-23, §30.1, §30.3)
- R-1.5 The pass runs on a module only when its type check had no error; ownership errors follow type errors.
  (oc §28.3)
- R-1.6 Inputs it may read: each module's typed IR in evaluation order; the solved type of every expression and
  local; dispatch resolution (which `++` is on lists, a method call's callee, `where` evidence); import provenance;
  type definitions, imported ones through interfaces; the ownership facts of imports (interface or checked core);
  ownership words and `entry`; the markup lowering's slot kinds (render or event). (oc §2, §16.10, §28 *markup
  slots*)
- R-1.7 Inputs it must not read: platform or constructor names, the `"lists"` key, any enforcement mode, session ids,
  completion order, where the project lives. (oc §30.1, §30.3; fc §10)
- R-1.8 Outputs: (1) diagnostics (§6); (2) the report (R-7.15); (3) interface facts, enough for an importer to get
  the in-module verdict (§5.7); (4) cache facts, enough that a hit reproduces verdicts, diagnostics and lowering
  channel without rechecking; (5) the lowering channel (R-1.12); (6) the facts of `core/` and the platforms,
  embedded in the checked core. (oc §16.10, §28.7, §31.10)
- R-1.9 Out of scope, though the checker depends on them: `prepend_in_loop` (the type checker); word placement
  errors (lowering, R-5.10.6); `invalid_dict_key` and `Dict`/`Set`'s missing `compare` (the type checker); the
  lowering's own refusals (browser-inline's error for a `List` row edited by id, naming `Dict.update`).
  (lang §6.8, §10; bi §5)
- R-1.10 `core/`, every platform and every test platform are checked like application code, with no exemption;
  none may have a refused or pending verdict when beni is built (that fails beni's build). A checker limit is never
  answered by adding a copy to `core/` or a platform. Every platform's modules are reported at beni's build [S].
  (oc §28.7, §30.5, §31.16)
- R-1.11 No runtime, sibling or platform code writes a list it was handed, or keeps one past a call unless its words
  say so; these are trusted obligations (R-5.10.7). (be §4 invariants 1 and 8; bd §4)
- R-1.12 **The lowering channel**, per module: a *clean* bit (checked, no limit reached, every write accepted); per accepted write, the write and for a record its written field set; per
  hoisted read, the holder, the reads to rewrite (field chains, record-pattern bindings, closures' field captures),
  the written-field prefix and the placement. (oc §31.10, §31.12 R5–R6; bi §8.4; ws *Amended 2026-10-23*)
  - Placement: before an instruction, or after an update's operands and before its stores; a callee's write
    hoists before the call; a write in one arm read after the join is placed before the nearest statement that
    dominates both; always after the holder's binding and before the first write the read's version does not see
    (two writes invalidating one read: the first placement); a closure's field captures are read at creation; only
    reads through holders bound before the write are hoisted. (oc §31.10, §31.14)
  - Properties: deterministic; source-derived positions only; no depth limit; versioned; outside the interface
    hash; no cache-key dependency. Report-only, unchecked or non-clean modules authorise no in-place store.
  - Lists are lowered in place on every platform [S O5, #321]; records in every clean module (core and platforms
    included) on every platform except `browser` and `browser-tea`, which keep spreads until retired
    [O 2026-10-25, #966; S O4b].

## 2. Writes that need a verdict

| # | Write | Base and what it edits | Source |
|---|---|---|---|
| R-2.1 | `List.set`, `update`, `swap`, `push`, `pop`, `insertAt`, `removeAt` (core's `List` only) | 1st argument; storage | oc §3.1; be §4 |
| R-2.2 | `List.append xs ys`, the named `Basics.append`, a `++` chain on lists. `a ++ b ++ c` and `a ++ (b ++ c)` are one write with base `a`; `(a ++ b) ++ c` is two. `++` on non-lists is no write. | leftmost operand | oc §3.2, §15.4 |
| R-2.3 | A list construction with anything after its first spread: `[ …acc, x ]`, `[ …a, …b ]`, `[ x, …xs, y ]`. A spread literal inside the last spread of another is its own write. | operand of the first spread | oc §3.2, §25.2; cbi/ListFormsShared, cbi/ListPrependShared |
| R-2.4 | `Dict`/`Set` `insert`, `remove`, `update`, `swap`, `insertAt`, `sortBy`; a no-op still writes. [S #961] | storage only | oc §32.1–§32.2; lang §6.8 |
| R-2.5 | A record update `{ r \| f = v }`. Base: a name, a top-level value, a call (`{ Record.copy r \| … }`, `{ defaults ⊤ \| … }`), a parenthesised expression, a markup spread. A nested update is two writes. | `r`'s object at the written fields | oc §31.3, §31.15; lang §6.3 |
| R-2.6 | A call whose callee writes a parameter path: a write on the argument at that path, transitively when the argument is the caller's parameter; a record parameter's written field set travels with it. | argument at that path | oc §16.4 item 3, §31.7 |
| R-2.7 | A writer handed as a value (`List.push`, `List.push _ 4`, a lambda writing its parameter): a write at every call the checker sees; *pending* where it leaves sight. | the parameter it writes | oc §30.4, §16.5 |
| R-2.8 | A closure whose body writes a capture: its creation is a write on the capture; each call uses the closure ("once"). A once local function's write is at each call. | the capture | oc §18.8, §31.4 item 4 |
| R-2.9 | A send (a send value, a subscription's tagged value, a tagger's result) gives up every list and record object its payload holds, deeply, closures expanded, send values excluded; a function that sends its parameter gives it up. Records: [G #976]. | the payload | oc §23.2, §31.6; bd §9.8.17(a) |
| R-2.10 | Program entry: each model or state path `update` (or hosted `settle`) writes. | the model | oc §20.6, §30.3 |
| R-2.11 | A `foreign` parameter worded `consumed`: a deep write. | the argument | oc §24.2 |
| R-2.12 | A private destructive read of core (`List.focus`, `traverseAt`, `Dict.focus`) whose callback writes what it is handed. | the element | oc §18.5, §20.8 |

Not writes (they read their operands):

- R-2.13 A prepend `[ x₁, …, xₖ, …xs ]` (one spread, last) and `List.cons`: they copy, though the result may share
  the base's array (R-4.4.2). [O 2026-10-11] (oc §25.2; lang §6.8)
- R-2.14 `[ …xs ]` is `xs`. A literal with no spread is fresh. A pattern only reads; rebuilding the shape just
  matched (`[ h, …t ]` after matching it, `[ …init, last ]` after matching it) is an alias of the scrutinee.
  (oc §3.2)
- R-2.15 `List.copy`, `Record.copy`; `Dict.copy`, `Set.copy` [S #961] (§4.10).
- R-2.16 The builders: `map`, `indexedMap`, `filter`, `filterMap`, `slice`, `take`, `reverse`, the sorts, `concat`,
  `concatMap`, `partition`, `unzip`, `map2`…`map5`; `Dict`/`Set` `map`, `filter`, `partition`, `union`,
  `intersect`, `diff`, `fromList` [S #961]. Interpolation, arithmetic, comparison. A schema run (§5.11).

## 3. The guarantee

- R-3.1 **Soundness.** For every accepted write, in every execution, nothing but the write's result observes the
  base after the write: no later read of its binding or an alias at an overlapping path; no later call or
  consumption of a closure that captured it; no pending operand or other operand of the same operation; no live
  structure, model, accumulator or message holding it; nothing the runtime keeps (command, subscription, view
  handler, queued body, concurrent fiber); no JavaScript (`foreign`, `Js`, `Ref`, `Js.ref`, a sibling); no
  top-level value; no view of the base; no receiver of a send after the payload was given up. (oc §0, §7.4, §8.1,
  §29; ws §5.4 item 1)
- R-3.2 **Equivalence.** The emitted program with every accepted write lowered in place prints what value
  semantics prints, hoisted field reads included; a closure keeps value semantics (`{ r | f = λ⊤ → r.f }` answers
  the old `f`). (oc §31.4 item 3, §31.10; be §4)
- R-3.3 **Position rules** refuse whatever the program observes: a write reaching a top-level value's list, record
  or collection; `view` or `subscriptions` writing the model they are handed. (lang §6.3, §6.8; oc §20.6, §31.8)
- R-3.4 **Unknown is never empty.** A value whose origin the checker cannot place may be anything a holder keeps.
  (oc §29 ¶3, §30.11)
- R-3.5 R-3.1 holds across modules, cached builds, the checked core, function values, recursion, polymorphism,
  casts through `Js.Value`, and every platform.
- R-3.6 The guarantee assumes only the trusted surface (R-5.10.7): asserted rows, words, `entry` obligations
  P1–P4 and P7, the runtimes' forwarding of sends, the schema engine's obligation, the pinned readers and forwarders of a
  `taken` result (read once per index in one direction, no competing read while materialised), and P-sync
  (no synchronous re-entry observing a Ref loan/write; suspension is checked separately).
  [O 2026-10-25] The pinning/gate discipline of R-5.10.7 covers these readers/forwarders and each platform's P-sync body. (oc §20.9, §23.9, §24.6, §30.10)
- R-3.7 No bound of the analysis ever produces an acceptance (R-7.3–R-7.5).

## 4. Precision: values, liveness and sharing

### 4.1 Liveness and evaluation order

- R-4.1.1 A use counts at its consuming point: an argument at its call, a field at its literal, a scrutinee at its
  `case`, a `let` value at its binding, a result at the end of its body, an update's base at the update. (oc §7.1)
- R-4.1.2 Field sensitivity: a use of `model.todos` is no use of `model.name`. Record fields, tuple indices,
  constructor arguments, list elements and closure environments are told apart at any depth. (oc §4.1 amended,
  §16.7(c); o/PathCut)
- R-4.1.3 A construction's items are evaluated before its base is written: accept `[ …xs, List.length xs ]`.
  (oc §3.3)
- R-4.1.4 A forwarded result (an arm, a block's tail, a function or callback body, an early return, `?`'s operand)
  is a use at that point; a write onto what the frame returns followed by a read of the old holder is refused.
  (oc §29; o/BridgeResultPaths, cbi/BridgeBlockResult, cbi/BridgeCaseResult)
- R-4.1.5 Accept: a read before the write; the write's own result written again; a dead alias. A later read of the
  base's own binding is `later-use`; of another holder, `alias` (R-4.3.1). (o/LaterRead, bbi/OwnershipLaterUse,
  cbi/InPlaceLaterUse, bbe/EverywhereLaterUse)
- R-4.1.6 A later read never resolves to the wrong binding, for every binder kind (`_`, `.field`, `(==)`,
  `x ← f a`, `if` without `else`, `e?`, pattern variables, spreads, lambda parameters): a binder placed between the
  write and a read of the original is refused, naming the original; distinct bindings are accepted. (oc §26.1;
  o/Binders, o/Question)

### 4.2 Branches

- R-4.2.1 Arms of one `case`/`if` do not keep each other's values live: accept a write in one arm while another
  keeps or returns the old value; a read after the `case` is after both. (oc §7.2, §29; o/BranchKeeps)
- R-4.2.2 An escape in one arm does not refuse a write in a sibling arm; one before the `case`, in an enclosing
  compatible arm, or in an already-joined `case` does. No exclusion is inferred across unrelated `case`s, calls
  or asynchronous bodies; a caller sees every arm joined. (oc §28 *escapes in alternative arms*; o/BranchEscapes,
  o/BranchSoonEscapes, bbi/OwnershipConcurrentFiber, bbi/OwnershipConcurrentSoon)
- R-4.2.3 `Maybe.withDefault (Maybe.map m f) d` and `Result.withDefault (Result.map m f) d` (both calls of the same
  core module), with `m`, `d` variable paths and `f` a lambda (including `g a _`) or a top-level value, are two
  exclusive arms: accept the pipeline, lambda and `case` forms. Refuse `later-use`: the old value read after, an
  eager handler call, an expression default, an edit while computing `m`, `andThen`. A record default is refused
  `held-operand` (o/MaybeDefault 63:54); mixing modules is refused (o/ResultDefault 84:68). (oc §25.4, §26.4)

### 4.3 Aliases, holders and operands

- R-4.3.1 One list reached by two names, written while the other is read later: refuse `alias`; fix `List.copy` at
  the second place, or read first. (o/StoredTwice, bbi/OwnershipAlias, bbi/OwnershipBorrowedAppend)
- R-4.3.2 One list as two operands of one write (`xs ++ xs`, `[ …xs, 4, …xs ]`, a renamed base, a view spread):
  refuse `disjoint`; a spread of another list is accepted. (o/SelfSpreads, o/Spreads, cbi/ListSpreadShared)
- R-4.3.3 An earlier-evaluated operand still holding the base: a pending construction, field or item, or an
  argument of a call whose callee's facts are known, gives `held-operand`; with no facts or an approximate value,
  `call (a)`. (oc §8.3, §16.4 item 2; o/Disjoint 20:24 and 24:33, bbi/OwnershipHeldOperand)
- R-4.3.4 Two paths of one argument that alias, at a call writing one of them: refuse `disjoint`. (oc §16.4 item 3;
  o/CallerSide)
- R-4.3.5 A pending argument holds the written list only at the paths its callee touches: accept
  `changed { model | draft = "" } (model.todos ++ [ new ])` when `changed` never reads `.todos`; a callee that never
  looks at a shared subtree is accepted, one that returns it refused. (oc §16.4 item 1; o/Changed, o/UnusedSubtree)
  The same per-path reading holds for a holder: a later read of a list's storage alone is no use of an element it
  holds, so `case rows of [ r, …_ ] → List.length [ …r, 0 ] + List.length rows` writes `r` in place and is accepted
  (`List.length` is `borrowed`: `R` at `ε`, not at `[*]`); v1 refused it `alias`. [M 2026-10-26, #1072]
  (o/Split `readAfter`)
- R-4.3.6 **Cause precedence.** Known, then Unescaped, then not captured, then Disjoint, then Dead; the first that
  fails names the cause (o/Toplevel 26:15 is `top-level` though a later read exists). Exact beats approximate;
  among failing holders, the one used first (ties: the earlier binding). (oc §8.1–§8.4)
- R-4.3.7 **Escape.** A value handed to a keeper (an `escaped` word, a wordless `foreign`, a callee that keeps it,
  JavaScript, a fiber, a command, the runtime) stays escaped for the rest of the body; a later write that reaches it
  is refused `escaped (a)`. An updated record's escape is its base's. (oc §4.3; o/BranchEscapes,
  o/FoldAccumulators, o/FoldKeepsInnerRefused, o/ForeignNoWords, o/core/JsWords, o/RecordCapture,
  o/RecordUpdateEscapes, o/InitializationTransfer, o/HostedEntryHost*)
- R-4.3.8 **Element.** A write whose base is an element and whose only live holders hold it as an element is
  refused `element (a)`. (oc §8.3; o/DeeperLevel, o/DictValueWritten, o/MarkerAcross, o/Toplevel 51:31,
  o/core/GrowingCast) `captured-edit` (a captured write the checker cannot place in a closure) is in no golden.

### 4.4 Prepend

- R-4.4.1 A prepend reads its items and base at the construction and never consumes the base: accept
  `ys = [ x, …xs ]` then a read of `xs`, a persistent stack, the suffix rebuilt after `[ a, b, …tail ]`.
  (oc §25.2; o/Prepend)
- R-4.4.2 A prepend's result may be the base itself (re-cons; on plain arrays the re-cons of a view stays after
  O5): editing that result while the base is read later is refused `call (a)`; with the base dead, accepted.
  (oc §25.2; be §4 *A prepend copies*; o/Prepend, o/Prepend 52:18)
- R-4.4.3 When the front item is a `List` value that is exactly a literal or a callee's fresh result, not escaped
  and not reachable from the base, the result is not the base: accept editing it while the base is read. Refuse
  `call (a)` when the front item is a parameter, a capture, a taken element, a top-level value, a callback result,
  stored in or taken from the base, held by the base (`baseHolds`), or a scalar. A fresh record or constructor value
  as the front item also counts as new (`[ Box n, …xs ]`). [O 2026-10-25] `List.cons` as a call is not narrowed.
  (oc §26.3, §26.8 item 2; o/PrependFresh)
- R-4.4.4 The emitted code of a prepend writes no array that existed before it. (oc §25.2; emit/PrependShapes)

### 4.5 Views and patterns

- R-4.5.1 A pattern's `rest`, `List.tail`, `List.drop` and `drop xs 0` alias their base: writing the base while a
  view is read later, or the view's source while the matched element is read, is refused; `restDead` is accepted.
  (be §4 invariant 3; o/ViewAliases; `tail`/`drop` have no fixture)
- R-4.5.2 Views are read-only; a write whose base is a view is checked like any write (the lowering copies the view).
  (oc §30.1; be §4 *A view is never written*)
- R-4.5.3 `[ x, …rest ]` binds `x` as taken and `rest` does not hold it; writing `x` needs the scrutinee's contents
  exclusive (§4.6) and the scrutinee dead. Walking `rest` by recursion is never an error while nothing writes the
  base. (oc §18.4; be §4; o/Split)

### 4.6 Containers: exclusive contents

- R-4.6.1 Editing an element of a container (`List.update`, `List.map`, `Dict.update`, a split) requires that no
  list or record object sits at two positions, or two paths of one position, of it; else `exclusive`, exact when the
  text shows it, decided after deadness so a live holder is named first. An outside holder read only before the edit
  does not refute it. A construction spreading a variable after its base (`[ …a, …b ]`, `b` a variable) loses the
  guarantee. (oc §18.2–§18.4, §31.4 item 6)
- R-4.6.2 Refuse `exclusive`: `[ cell, cell ]` or `List.repeat n r` edited through `update`, `map` or `initialize`
  (o/T59, o/RecordContents, o/RecordContentsBuilt 35:8); one list at two `Dict` keys or a key's value and inside
  another value (o/DictFocus); `insertAt` of one list twice (o/Permutations); `List.push l ( xs, 0 )` or
  `[ …acc, y ]` where another position holds the list, compared at that path even when the other operand's entry
  stands above it (o/Beside*Helper); `[ row, row ]` then a write of `row.1` (o/FoldElementPathAliases 31:46); one
  list in both tuple fields (o/DictTupleFocusSharing). (oc §28 #474 amended 2026-10-25)
- R-4.6.3 Accept: two separate literals; fresh distinct elements (o/ElementEdits); edits after `swap`, `pop` or
  `removeAt` of an exclusive list, or after `insertAt` of a fresh element (refuse `swapThenEdit [ row, row ]`); a
  fresh tuple's list at one fresh key. (o/T59, o/Permutations, o/DictTupleFocus, o/FoldElementPaths,
  o/FoldStringKeys)
- R-4.6.4 Per written path: in a table of pairs, keys shared at `acc[*].0` do not refute the outer array or
  separately owned value lists at `acc[*].1`; writing a key needs that key's ownership; a key aliasing a written
  value list refutes it; a key still held by the table refutes it (o/FoldElementPathAliases 25:13). A list key in a
  table fold is accepted. (oc §28 #720)
- R-4.6.5 Only places that may hold a record take part in record exclusivity: two records sharing a `List Int` share
  no record; type variables and opaque values (`Js.Value`, a program's type) may hold one. (oc §31.4 item 6;
  o/RecordContentsBuilt, o/RecordContentsCore, o/RecordContentsReturned)
- R-4.6.6 A callee's exclusivity requirement on its parameters is discharged at every caller, across modules too;
  a failure is reported on that call's line. (oc §18.3–§18.4)
- R-4.6.7 `want xs = List.update xs 0 λl → List.push l 9` on a list of distinct fresh lists built by `List.push`:
  accept. [G #977]
- R-4.6.8 `xs` and `List.copy xs` stored at two keys or positions are apart. [G #987]
- R-4.6.9 A pattern element stored back into its own list (`[ p, …_ ] → [ …l, p ]`, `List.push l p`, a tuple
  payload) refutes that container's exclusivity, for lists and records: refuse `exclusive`. [G #419, #970]
  (p/RecordSplitPushBack)
- R-4.6.10 A `List.update` callback answering a list another position holds, then that position edited: refuse
  `exclusive`, as `List.set` is. [G #971]

### 4.7 Recursive values

Implementation contract: `ownership-v2.md` §2.9's single path-multiset primitive carries coexisting
occurrences through every many-to-one path map, including a folded callee path over an unfolded actual.
Its Appendix B FoldedBCall red/green pair and JoinFoldChoice/K controls exercise these requirements;
§8 places the independent recursive-proof verifier spike before S3b. This pointer changes no verdict
requirement or section number.

- R-4.7.1 Accept writes to distinct lists at different levels of a recursive value: `ParamHole.hole`,
  `FoldLevels.pushRoot`, `RecordTree.deepest`, `PathCut.apart`, `LevelFresh.pushRoot`. Refuse: one list at two
  levels handed to a writer (`ParamHole.shared`, `disjoint`); a write while a deeper subtree holding the list is
  returned (o/MarkerAcross, o/DeeperLevel); one list at a place and below it (o/OneListTwoLevels); a call operand
  that holds the written list at another level (o/MarkerDisjoint); one list placed at both fields
  (o/PolyRecShared). (oc §16.7 #379; o/ParamHole, o/FoldLevels, o/LevelFresh, o/RecordTree, o/RepresentativePrefix,
  o/RecordBaseLevels)
- R-4.7.2 A write to one list of a part of a recursive value while another list of that part, at another level, is
  read later *may* be refused `level (a)` (`list_may_be_shared`), even when safe; v2 is not required to refuse it.
  Exact causes come first: the same level read twice stays `alias`, a re-read of the written list `later-use`.
  It is a compiler limit and may be lifted. (lang §6.8 *The one limit*; oc §16.7(e); dr §9; bbe/OwnershipLevel,
  o/LevelLimit 68:23 and 81:15, o/PolyRecLevels, o/MutualTypes)
- R-4.7.3 Only a type that reaches itself is recursive, and a type parameter is not a level: `Tree (Tree (List
  Int))`'s inner trees and `Maybe (Maybe a)` have distinct places, and a call and the same body inline get the same
  verdict. (oc §16.7 #341, (a); o/FoldTypeParameter, o/Nest)
- R-4.7.4 Mutually recursive types are exact: with `type A = A (List Int) B` and `type B = B (List Int) (Maybe A)`,
  `ab2` is accepted (a `List Int` field reaches no other type). [G #395] (o/MutualTypes, o/MutualCycles)
- R-4.7.5 A recursive update of every level (`incAll`) needs the tree exclusive below the part it writes; it is
  refused on a tree holding one list at two levels. (o/LevelRecursiveUpdates, o/LevelPlacesCall,
  o/LevelPlacesKinds)
- R-4.7.6 Storing an alias beside the original at another level is refused; discarding the subtree that holds the
  alias restores exclusivity. (oc §16.7 #456; o/ApproximateAliasLevels, o/ConstructorDiscardedAlias)
- R-4.7.7 `RNode { l, v, r }`: pushing the left child's `v` while returning the right child (`rt1`): accept.
  [G #396]
- R-4.7.8 A write to one list of a part does not need the whole part exclusive; a write to every level (`incAll`,
  `c1`/`c2`) does. [G #400]
- R-4.7.9 A push onto a list two constructors deep while the list is live (#509's `NestedLive`, `Ok (Ok v)`,
  `Just (Just xs)`): refuse `alias`, as one level is. [G #509]
- R-4.7.10 Recursive native schemas fold as recursive types do; `Type` and `Encoded` sides are separate.
  (oc §16.7 #820; o/SchemaLevels)

### 4.8 Records

- R-4.8.1 Every record type is tracked, even when its fields hold scalars; a scalar tuple, or a nominal type reaching
  no record, `List`, function or foreign type, holds nothing. A record literal and a record-alias constructor are
  fresh objects. (oc §31.2; o/RecordCells)
- R-4.8.2 Liveness is per field (oc §31.4 item 5, §31.14):
  - a later read of an untouched field: accept;
  - a later read of a written field through a holder bound before the write: accept, hoisted;
  - a later *whole* use of the old record (stored, returned, sent, compared at the root, bound to another name,
    captured whole, base of another update, passed to a callee that reads a written field or keeps it): refuse
    `later-use` or `alias`;
  - a holder bound after the write, a container holding it, or a call result that may be it, is read only whole;
    `x = r.a` binds the field value [O 2026-10-17];
  - a once closure writing a captured record: a read of a written field after the creation is a whole use (the
    write happens at the call); an untouched field stays accepted (oc §31.4 item 4).
  - An update reads the fields it keeps (o/RecordUpdateUse). An update replacing every field is a whole use of its
    own record only (820731f8f). A write whose fields cannot be named writes every field (o/RecordFieldSets).
  - (o/RecordDemands, o/RecordHoistChannel, o/RecordField, o/RecordOnce)
- R-4.8.3 New field values are evaluated before any store: `{ r | a = r.b, b = r.a }` swaps; a field value holding
  the base whole is refused. (oc §31.4 item 3, §31.10; run/RecordInPlaceExpressions)
- R-4.8.4 `{ model | form = { form | name = n } }` with `form = model.form`: accept; the lowering may drop the
  outer store. (oc §31.3, R7; o/RecordField, emit/release/inline/NestedFieldWrite)
- R-4.8.5 A callee that only writes a field set reads none: accept `changed model (List.map model.todos λt →
  { t | … })`; a callee that also reads a written field uses it whole; an unknown field set is a whole use.
  (oc §31.8 #405; o/RecordWriteOnlyCall)
- R-4.8.6 A record handed to a callee whose facts cannot name a field set refuses the update
  (`record_may_be_shared`), naming the cause: an unknown callee, wordless `foreign` or `Js` op (`call`/`unknown`,
  "cannot see which fields it reads"); a callee reading it at an unknown path (`call`, "may read any field"); an
  unfollowable function argument (`supply`); a callee past a limit (`limit`). (oc §31.4 item 5)
- R-4.8.7 `shift dx p = { p | x = p.x + dx }`: `shift 3 origin` followed only by reads of `origin.x` is accepted
  (hoisted before the call). `shift 3 origin` is refused when a later call hands `origin` whole to a callee that
  reads a written field (`(shift 3 origin).x` after it); fix `shift 3 (Record.copy origin)`. (oc §31.7, l.7153;
  run/Records pins the fixed form only; the refusal has no fixture)
- R-4.8.8 `[ { item | doc = l }, { item | doc = r }, …rest ]`: refuse `held-operand`, fix `{ Record.copy item | … }`.
  One record passed twice to one call: `disjoint`; one record at two result paths: `alias`. (oc §31.5;
  o/RecordDemands.twice 89:16 and 89:34, o/RecordSameCall, o/RecordAliasResult)
- R-4.8.9 After `List.map model.rows (λr → { r | … })`, reading the old `model.rows` is `later-use`; the map's result
  is fine. A constructor payload record is demanded at its payload path; constructors are rebuilt, not written.
  (oc §31.5)
- R-4.8.10 A constructor used as a function value holds its arguments: `b = apply Box r`, `{ r | x = 1 }`,
  `( b, … )`: refuse. (bbi/RecordConstructorValue, o/RecordConstructorPayload)
- R-4.8.11 Keep edge, record twin: a callee that hands a function a record (directly, through its record, tuple or
  list, `k.mk r`, `List.map fs λf → f r`) and then writes it is refused `supply (a)` at the function value supplied
  (`record_may_be_shared`). (oc §16.4, §31.5 revised #982; bbi/RecordCallbackKeeps)
  - Also when the record is wrapped in a fresh literal handed to the keeper (`b = f [ r ]`, `{ w = r }`) or written
    through a local bound to a field of the kept parent (`i = o.inner`). [G #1000, #1001: miscompiled today]
    (p/RecordKeptInLiteral, p/RecordInnerKept)
  - A record written *before* it is handed to a keeper and returned beside the keeper's answer: accept.
    [G #999] (p/RecordWriteBeforeKeep)
- R-4.8.12 A read of an old field through a wrapper (`w = Just p` or `t = ( p, 1 )`, then a pattern) is a field read,
  hoisted: accept #394's `caseAlias` and `tupleDestr`. [G #394]
- R-4.8.13 A callback that keeps one field of a record its callee hands it does not make the caller's record escape
  whole: a caller's update after `drive`/`perform` is accepted; no list verdict moves. [G #414]
  (o/core/RecordKeepJs, o/core/RecordFoldJs)
- R-4.8.14 Each record base gets a verdict with a cause, never "no provenance names where its base's object comes
  from" (#870's seven programs). [G #870]
- R-4.8.15 A record moved between variants of one model field (Conduit Editor `status`) is not a second holder:
  accept; a record genuinely held at two model fields stays `disjoint`. [G #410]
- R-4.8.16 Record `need`, `exclusive` and `supply` follow the list rules: a record taken from a function parameter's
  result and written needs it owned (o/RecordNeed); a record put back through `List.update` from a pattern or a list
  is `exclusive` (o/RecordContentsKeep); a callee's supply to a callback is the caller's argument (o/RecordSupply).
- R-4.8.17 Exchanging rows by index (`List.indexedMap` answering another index's row, `swapAt`, `List.drop` in
  KeyedEnds) over an exclusive list of records is accepted by a precise rule; a shape that puts one row at two
  positions stays `exclusive`. [O 2026-10-25, #869]

### 4.9 Top-level values and initialization

- R-4.9.1 A top-level value with no parameters is shared by the whole program: a write that reaches what its
  definition makes (list, record or collection, through `init`, a view message, a callback, a schema conversion or
  another module) is refused `top-level (p)`. (oc §5, §22.2, §31.8; o/Toplevel, bbi/OwnershipTopLevel*,
  bbi/OwnershipSetupSeed, bbi/RecordViewMessageConstant, bbi/RecordConversionAnswer, bbe/RecordTopLevel,
  o/RecordTopOrder, cbi/ListFormsShared)
- R-4.9.2 A top-level value holds only what its definition makes; a top-level function, constructor or scalar
  literal holds nothing. (oc §5, §16.3)
- R-4.9.3 Initialization transfer: a private, parameterless top-level value read exactly once in its module
  (deferred bodies counted), directly and not in a closure, by another parameterless, non-recursive initializer of
  the same application module, moves its fresh lists to that reader: accept `xs = [ 1, 2, 3 ]` with
  `main = … List.set xs 0 9 …`. (oc §28 *initialization transfer*; o/InitializationTransfer, o/InitializationWide)
  - Refuse `top-level`: a write in a function; a second read; a read in a lambda; a `pub`, foreign or schema source;
    a recursive initializer; an unknown result or a summary past a limit; explicit or inferred `where` evidence or
    return-type dispatch; a function-valued result. (o/Initialization*)
  - After a transfer the destination is still a top-level value: a function writing it is `top-level`.
- R-4.9.4 A top-level `List ⊤` (or a custom type around one) built by a fold, then pushed: refuse `top-level`; the
  fold keeps its result's provenance. (o/FoldUnitTopLevel 24:13, 47:13) A top-level `Set.fromList` written by
  `Set.remove`: refuse. [S #961; #952]

### 4.10 What the core library returns

- R-4.10.1 Writers (`set`, `update`, `swap`, `insertAt`, `removeAt`, `pop`, `push`) return their input, even when
  they write nothing; `append` returns its first argument, except that `xs ++ []` and `[] ++ ys` copy. The
  result's elements are the input's plus the stored value. (oc §27.2, §27.4, §16.8)
- R-4.10.2 Builders (R-2.16) always return a fresh list. Elements keep identity (`filter`, `slice`, sorts: the
  input's; `map`: the callback's results): editing a builder's spine while its source is read is accepted, editing
  inside an element still writes the source's element. [O 2026-10-13] (oc §27; o/Conservative, o/MapAcrossTypes,
  o/Differential)
- R-4.10.3 `List.copy`: fresh spine, the argument's elements, not a write: accept `[ …List.copy xs, x ]` with `xs`
  read later; editing an element of the copy while the original lives is `alias`. (oc §3.4; o/Copy, o/NullaryCopy)
- R-4.10.4 `Record.copy : { r | } → { r | }`: a new object with the same field values, not a write;
  `{ Record.copy r | f = v }` is accepted and `r` only read; `Record` is a prelude module used qualified;
  `{ r | }` unifies with every record type. It makes a new object for an open record type too [G #871]
  (run/FieldColouring). (oc §31.15; o/RecordCopy)
- R-4.10.5 A list literal, `[]` included, is a fresh array at every evaluation. (be §4 invariant 7)
- R-4.10.6 `cons`, `length`, `at`/`get` (aliasing an element), `sliceOf` (fresh, elements aliased) are reads.
  (oc §16.8, §22.5)
- R-4.10.7 Record exclusivity through core: `List.append` keeps "no record twice" when each input is exclusive and
  they are separate (refuse `rows ++ rows`); `copy`, `sliceOf`, `take`, `filter`, `reverse`, `sortWith` keep it;
  `sortBy` loses it (not required). A `sortWith` comparator writing an element is refused `supply`.
  (oc §31.4 item 6; o/RecordContentsRows, o/RecordSortWith)
- R-4.10.8 Core rows state record conditions on their own, so a row that loses a list condition keeps the record one
  where it holds: a callback writing records of `List.append`/`List.filter` results of exclusive inputs, and
  `{ i | path = [] }` over Schema's issue lists, are accepted; no list line moves. [G #420]
- R-4.10.9 `Dict`/`Set` are the ordered representation only; v1's tree rules are not required. [O 2026-10-25;
  S #961] (oc §32.1; lang §6.8):
  - Keys are `Int` or `String`. A `Dict` owns mutable storage even when its values are scalars.
  - A storage write demands only the storage; a callback writing a selected value adds its own write on it.
  - Reading the old collection (even its `size`) after a writer: refuse, fix `Dict.copy`/`Set.copy`.
  - `copy` separates storage only: a shared payload edited after a copy is still refused unless copied itself.
  - The read-then-replace program (#579) is refused while the original lives.
  - (o/DictLiveOld, bbi/DictLiveStorage, bbi/SetLiveStorage exist only on #961's branch; cbi/ListPersistenceShared)
- R-4.10.10 `Dict` rows [S #961] (oc §32.2; `keyAt` from bi §9.10, 2026-10-25):

  | Operation | What a verdict may rely on |
  |---|---|
  | `empty ⊤` | fresh at every call, including through a function value |
  | `singleton` | fresh storage; the value aliases its argument |
  | `get` | read; the `Just` payload aliases the stored value, borrowed |
  | `member`, `size`, `isEmpty`, `keyAt` | read of the storage; scalar result |
  | `insert`, `insertAt` | storage write; exclusive only when the arrival is separate from the retained values |
  | `remove` | storage write; may retain the removed value |
  | `swap` | storage write; conditions kept |
  | `sortBy` | storage write; callback once per entry in order, values borrowed (a write to one is refused) |
  | `focus` (private) | callback called exactly once; an absent key supplies nothing; the value is supplied owned only when the dictionary is exclusive, owned and dead outside; the loan cannot overlap another key, a capture or a live callback result; a shape-keeping write-back recovers exclusivity; a replacement is separate from the retained values; a read-only callback still writes the storage |
  | `copy`, `values`, `toList` | fresh; values aliased; value exclusivity kept; private pairs never escape |
  | `keys` | fresh exclusive list of scalars |
  | `eq` | read |

  - Fresh storage never implies exclusive values. `Dict.update` behaves as `focus`. `fold`, `filter` and `merge`
    callbacks are handed values borrowed; derived operations meet oc §32.3; `Set` behaves as `Dict`.
  - A function value of these operations gets the same verdicts as a direct call. A missing row is the
    conservative foreign call; an unrelated module's same-named function gets none of this.
- R-4.10.11 A storage permutation (`swap`, `sortBy`, `insertAt`, `List` storage writers) does not conflict with a
  value borrowed below it: accept a borrowed-value identity callback followed by a storage permutation; refuse
  `supply (a)` writing the kept value, keeping the storage, or sending the value. (oc §32 #670; o/WriteExtents;
  [S] for `Dict`/`Set`)
- R-4.10.12 `Dict.update` on two distinct fresh lists (`DictFocus.grow`): accept; repeated-value, payload and
  live-dictionary twins stay refused. [G, needs #961; #663] (p/DictFocusGrow)
- R-4.10.13 Tuple or record payloads aliased at two `Dict` keys, then a value edited: refuse `exclusive`; a fresh
  twin is accepted. [G, needs #961; #474] (p/DictHelperAlias, p/DictRecordAlias, p/DictTupleAlias)
- R-4.10.14 A write to a live old `Dict` on `node` by default: refuse. [S #961, O4a; #681]
- R-4.10.15 Platform `Tea` job and subscription tables are edited in place under ownership with no exemption.
  [S O4a/O5] (be §4; bd §9.8.3)

### 4.11 Casts through `Js.Value`

- R-4.11.1 A value cast to an opaque type and back is exact only when read at the identical full resolved type;
  any other read keeps all its contents approximate. Type identity is portable across modules and the cache.
  (oc §16.7 F2; o/core/FullCast, o/core/CastAcross, o/core/SchemaCastSlot)
- R-4.11.2 A cast between different closed types never cancels an alias: reading `(xs, xs)` as a list of lists does
  not make it exclusive (refuse). A child read through a cast is still a level of its recursive value.
  (oc §16.7 F2; o/core/FullCast 99:25, o/core/CastRegion, o/core/CastOccurrence, o/core/GrowingCast)

## 5. Higher-order, cross-module and platform

### 5.1 Calls

- R-5.1.1 A call of a function the checker can identify gets the verdicts its body justifies at that call, at least
  as precisely as v1, in the module and across modules alike (§5.7). (oc §16.2–§16.4, §18.3)
- R-5.1.2 A helper returning a list it made: fresh, accepted though its argument is read later (o/ReturnsFresh). A
  helper returning its argument, whose result is edited while the argument is read later: `alias` (o/ReturnsArg).
- R-5.1.3 A helper writing its parameter is accepted at a caller that does not read the argument later and refused at
  one that does; the obligation travels through wrappers. (o/CallerSide, o/CrossModule)
- R-5.1.4 A result that may be one of several values (`if c then [ 0 ] else xs`) is approximate; a refusal resting
  on it is `call (a)`. (oc §16.4 item 7; bbi/OwnershipLimit, o/Disjoint `forCall`)
- R-5.1.5 The written argument must be disjoint from the callee's captured environment and from every other
  argument, through function values and on the last invocation too. (oc §29 ¶4; cbi/BridgeCaptureOperand)
- R-5.1.6 `e?` on `Result`: the enclosing definition's result may hold the `Err` payload, so `pick (Err xs)` with
  `xs` written while the `Err` is read is `alias`; `?` on `Maybe`, or an error type holding no list, adds nothing;
  `?` returns from its own definition. (oc §26.2; o/Question)
- R-5.1.7 A resolved nullary method `x.m` (`current.trail.copy`) is a call. (oc §28 *nullary methods*; o/NullaryCopy)
- R-5.1.8 A call with no known facts holds what its result type can hold: a function read from a record, then its
  result pushed while the list is read, is `call (a)`; `pushOther`, whose result type cannot hold the list, is
  accepted. (oc §6.1, §16.4 item 6; o/UnitListHeld)

### 5.2 Callbacks: supply, need, keep

- R-5.2.1 *Supply.* A callback writing what its callee hands it borrowed: `supply`. An owned supply of the callee's
  own parameter becomes a write on the caller's argument. A borrowed supply whose callback answers *unknown* is
  `supply`. (oc §16.4 item 4, §30.11; o/Callbacks, o/RecordSupply)
- R-5.2.2 *Need.* A callback whose result the callee edits must return a list it owns: every result fresh, a
  parameter supplied owned and not escaped, or the guard callback, with no value at two result paths. A capture,
  top-level, escaped, unknown or borrowed value is refused `need`, exact when the text shows it, approximate when
  it fails only through *unknown*, an approximate step, another callback's result or an unplaceable function.
  (oc §16.4 item 5, §30.9 rule 11; o/NeedLabels, o/NeedUnknown, cbi/NeedMessage)
- R-5.2.3 `pushReturned xs identity` with `xs` read later: refused; a supplied parameter the callback returns is
  followed to the caller. (oc §16.4 CK-233; cbi/BridgeCallbackReturnsParameter, o/BridgeReturnedParameter)
- R-5.2.4 *Keep.* A callee hands a callback a list, keeps the result, then writes the list: an actual that may keep
  its parameter is `supply (a)`, one that drops it accepted. Also refused: a keeper of one field with a write of
  another; a callee writing a list it made after handing it on (`call (a)`). A callee returning the list beside the
  kept result makes them aliases at the caller. When the only possible writer is another function parameter or
  slot, a known non-writer discharges it. (oc §16.4 #281, #210; o/CallbackKeeps, o/ConditionalCallbackKeep,
  o/ScalarCallbackSlots, o/CallbackComponentGuard: the owned-result assumption holds per result component)
- R-5.2.5 A callback keeping a list stored inside its accumulator does not refuse writes to the accumulator; a kept
  list taken from the caller's `rows[*]` stays the caller's, so writing it after the traversal is refused.
  (oc §32 #749; o/FoldKeepsInner, o/FoldKeepsInnerRefused)
- R-5.2.6 A callback result whose type holds nothing tracked (`Int`, `String`, a specialised identity tagger) needs
  no owned-result proof. (oc §28 *markup slots*)
- R-5.2.7 An obligation on the result of the declaration's own function parameter or slot goes to its callers; a
  `need` on a lambda's parameter is decided where the lambda is handed on; with no such place (runtime entry, a
  callee with no facts, out of sight), `need (a)`. A function parameter called inside a lambda is the declaration's
  call (o/CapturedParam). (oc §18.9, §30.9 rules 6–7; o/SlotInLambda, o/LambdaParamNeed, o/LambdaPassNeed)
- R-5.2.8 A callee that only pushes onto the list its callback returns does not demand that list's items: accept
  when the items are shared with the caller; the message names the path. [G #188]
- R-5.2.9 `edit list f = List.map list λrow → if … then f row else row` keeps exclusivity for lists as it does for
  records (o/RecordContentsAnswered): accept `editL` over `List (List Int)`; a lambda answering a captured value
  twice stays refused. [G #868]

### 5.3 Folds and accumulators

- R-5.3.1 Accept the canonical accumulators: tail-recursive `go [ …acc, x ] rest`, `List.push acc x` and
  `[ …acc, x ]` in `foldl`/`foldr`, local recursive builders, `[ f x, …go rest ]`. (oc §16.4, §18.7; o/Accumulator,
  o/LocalGroups, o/Recursion; lang §6.8)
- R-5.3.2 For `List.foldl`/`foldr` and `Dict.foldl`/`foldr`, both directions, an accumulator the callback edits in
  place is accepted when the start value is owned (`[]`, a literal, a proven-fresh call, `Dict.empty` [S #961: a
  value on master]) and every callback arm returns the container it received or a fresh one, without escaping it,
  capturing it in a kept closure, storing it at a second position, or replacing it with something borrowed, shared
  or unknown. The start value proves only the containers it makes; a fresh outer dictionary proves nothing about
  its stored lists; an unknown callback, a callee past a limit or an unfinished analysis proves nothing.
  (oc §28 *fold invariants*; o/FoldAccumulators, browser/tea/DictFoldLeft, browser/tea/DictFoldRight,
  browser/tea/FoldRight, browser/tea/SubscriptionTapAppend)
  [O 2026-10-26] This storage-write guarantee does not promise exclusivity of a fold accumulator's
  elements. That condition stays `lost` unless the narrowed current-element/earlier-feedback rule is
  independently proved in S4 (ownership-v2.md C.9 gap 3, #1017).
- R-5.3.3 Refuse the twins: an accumulator that escapes, is captured, duplicated, starts shared, or has a closure
  capturing it stored beside it. (bbi/OwnershipFold*, cbi/BridgeFoldBorrow)
- R-5.3.4 An item a destructive fold lends from its container does not make an accumulator outliving it owned.
  (oc §29 ¶5)
- R-5.3.5 Record accumulators: a callback writing the accumulator its earlier call returned is accepted when the
  record is the caller's own and not kept at that path or above; `( r, List.push hist r )` refuses the next step's
  write. (oc §31.8; o/RecordFoldBelow, o/RecordFold)
- R-5.3.6 Callbacks of one callee that feed each other: accept `Dict.merge a b (Dict.empty ⊤) …` with a list
  accumulator shared by its three steps; a callback returning a top-level value stays refused. (oc §16.7 #968;
  o/MergeCallbackCycle)
- R-5.3.7 `n = List.length (List.foldr [] [] List.intersperse)` (an accumulator of an unnamed cyclic type) checks
  clean with no limit; a variant writing the accumulator keeps its verdict. [G #955, blocks O4a]

### 5.4 Closures

- R-5.4.1 A closure holds its captures while live (bound, stored, pending, kept by a call result): writing a capture
  while the closure is used later is `captured`. Capture is per path; captures count as read where the closure is
  consumed; a named closure sees bindings declared after it. (oc §7.3, §29 ¶2; o/ClosureCapture, o/Clo,
  o/ClosureLevels, o/DirectCapture, o/CapturedReread, bbi/OwnershipCaptured, cbi/BridgeCaptureResult,
  cbi/BridgeRecursiveCapture)
- R-5.4.2 A once closure: accept it created and called once, or handed to a callee that calls it at most once and
  sees it (`Maybe.map`); refuse `once` when called twice, handed to `List.map`, or calling itself; a read of the
  capture after creation is refused with the creation's cause (`later-use`, o/Once 24:18); out of sight it is
  *pending*; a callee with no facts refuses it; a command body that writes its capture and may run more than once is
  `once`. Its permitted transfer does not excuse an earlier unrelated write. (oc §18.8, §23.2; o/Once, o/RecordOnce)
- R-5.4.3 A once closure writing a list another holder still reads (#382's five shapes, e.g.
  `ys = xs; f = λ⊤ → ( List.push xs 1, List.length ys )`): refuse `alias`/`later-use`. [G #382]
- R-5.4.4 `( w 1, w 2 )` with `w = mkPusher xs`: refuse. [G #383]
- R-5.4.5 Accept `rev p = g2 (bump p _) p.x` and its list form: a read in a later argument of the call a once
  lambda is handed to is live only from that call. [G #416]
- R-5.4.6 A closure capturing a field path reads it at creation, so a later write of the record is accepted; one
  capturing the record whole holds the object. [O 2026-10-17] (oc §31.6; o/RecordCaptureField, o/RecordCapture)
- R-5.4.7 One list held by two sibling closure environments in one value is shared. (o/EnvPrefix, o/SiblingEnvs)
- R-5.4.8 A lambda in a callee's result is carried to the caller with the captures it passed: a captured list
  written before the lambda is called is `captured`, after it accepted. (oc §24.9; o/CarriedLambda, o/CarriedFold)
- R-5.4.9 #956's `flatten _ = λp → { p | y = 0 }`, called on a fresh literal: accept (the returned lambda's write is
  discharged at the call); called on a held point: refuse. [G #956]

### 5.5 Function values

- R-5.5.1 A function value's behaviour is known where its calls are seen (as the callee, or the actual of a callee
  parameter whose calls are seen); a lambda's write on its own parameter is accepted when every supply is owned or
  every call is local. (oc §16.5)
- R-5.5.2 Partial application `f a _` behaves as `f`: accept `apply List.push (List.copy xs)`; `apply List.push xs`
  with `xs` read later is `later-use`. (oc §30.4)
- R-5.5.3 A writing function leaving sight is *pending*, naming where it went ("it is stored in a record", "it is
  returned", "it is passed as evidence", "loses sight of what calls it"), records too (`{ handler = λr → { r | … } }`).
  (oc §30.4, §31.7; bbi/OwnershipPending, bbe/RecordMayBeShared, o/DeepCapture)
- R-5.5.4 A call of a function the checker cannot identify answers *unknown*; a write onto it is `unknown (a)`.
  Such calls: a function value of unknown origin (from a `Dict`, a list element, a call result); a method resolving
  to no declaration and no record field; type dispatch through a `where` method; an unreadable callee fact; a
  callback whose actual is unknown. A markup construction's result is made by the call. (oc §30.11;
  o/UnknownCallee, o/UnknownCalleeForms, cbi/UnknownCalleeShared, cbi/RecursiveUnknownFunction)
- R-5.5.5 A function value that may be one of several known functions is applied as each and joined: accept #278's
  three programs; `if flag then λ⊤ → shared else λ⊤ → []` pushed stays `top-level`. [G #278]
  (o/core/GrowingReturnedFunction)
- R-5.5.6 A top-level value naming a function (`list = Pcg.list`, `mkBox = Box`) is called as it: accept a fresh
  `mkBox` write; `named = λ⊤ → shared` then `named ⊤` pushed is `top-level`. (oc §30.9 rule 9, §30.11;
  o/UnknownCalleeForms)
  - A top-level alias of a *writer* is a call of the writer, not *pending* [O 2026-10-25; v1: o/AliasWriter 14:6].
  - Alias chains of any length [G: v1 stops at 8]; an alias of a function with a `where` clause: accept
    `bad ⊤ = List.push (keepAlias [ 1 ] 1) 2`, `keepAlias shared 1` stays refused [G #279].
- R-5.5.7 `r.load a`, the receiver's record type having field `load` and no method declaration, calls the field's
  value and reads only `r.load`. (oc §30.11; o/DotFieldCall)
- R-5.5.8 A constructor handed as a function returns its arguments at its fields (R-4.8.10). (oc §23.5)
- R-5.5.9 A lambda's call of its own function parameter carries that parameter's result; recursive members
  returning functions join compatible lambdas, so validators in a `List (Validator a)` are judged precisely.
  (oc §30.9 #223 amendments; browser/inline/ReturnedValidator, cbi/FunctionElementBorrowed,
  cbi/FunctionElementShared, cbi/RecursiveValidatorShared, cbi/RecursiveClassGrowth)
- R-5.5.10 A writing function passed as `where` evidence is *pending*, at any nesting depth. (o/EvidenceDeep)
- R-5.5.11 A type variable may hold a `List` or a record; what a custom type may hold is read from its constructors.
  Refuse at the caller supplying `Node xs`, not in the generic body. [O 2026-10-22] (oc §30.9 rule 4;
  o/NominalHolds, o/RecursiveHolds)
- R-5.5.12 `Push.onPush (λv → Pushed v)` with `Pushed : Value → Msg` gets the bare constructor's verdict, accept; a
  foreign `Value` reaches no beni list. [G #963]
- R-5.5.13 Behaviour carried in function types (#587) is not required in v2, but its design must leave room to add
  it without a rewrite. [O 2026-10-25]

### 5.6 Recursion and polymorphism

- R-5.6.1 Recursive and mutually recursive top-level groups and local-function groups are decided, never
  *pending*; a recursive function binds its callers as a non-recursive one does; declaration order never changes a
  verdict. (oc §16.6, §18.7, §29 ¶3; CL; o/RecursiveFunctions, o/RecursiveTupleGuards, o/LocalGroups,
  o/RecordRecursive, o/RecordTopOrder)
- R-5.6.2 Polymorphic recursion by any route (a callback into the group, a let-bound lambda, CPS, destructured
  parameters, a forwarded supply, a cast through `Js.Value`) terminates and keeps the base case precise: accept
  `pushArg` through `wrap 1 xs`. [O 2026-10-19] (oc §16.7; o/PolyRec*, o/LocalPolyRec, o/core/GrowingFunctionSlot)
- R-5.6.3 Recursion and every fixpoint terminate by construction, with no round cap (R-7.4): bbi/OwnershipRounds,
  bbi/OwnershipEntryRounds and o/InitializationLimit get ordinary verdicts (R-8.1). [O 2026-10-25]

### 5.7 Modules, interfaces and the cache

- R-5.7.1 An importer gets exactly the in-module verdict, opaque types included: it tells two slots of an opaque
  type apart without its definition. (oc §16.10; o/OpaqueSlots, o/CrossModule, o/ApartAcrossModules,
  o/WideCtorBlock, o/SchemaCtorBlock, o/SchemaMemberExt)
- R-5.7.2 A module's facts are a function of its source and its imports' interfaces only, published in its interface
  and hashed with it, naming no session id. (oc §16.10 *As built*)
- R-5.7.3 The firewall: an edit preserving a module's published facts rechecks only it; one changing them rechecks
  its importers. (oc §16.10; tests/blackbox/cache_test.zig)
- R-5.7.4 Every rule change versions the facts. An entry, block or lowering table of another version, or a bad table
  format, is a cache miss and the module is rechecked; only a single fact that does not decode inside a block that
  does counts as *unknown*. (oc §28.4 incl. #814, §31.10)
- R-5.7.5 A verdict does not depend on whether an import was checked in this run, cached, or from the checked core;
  cached, uncached and `--no-cache` agree. A clean report cached by another platform's build is reused; a cached
  refused report is rechecked before its diagnostics; a module with an ownership error is never cached clean.
  (oc §16.10 *As built 2026-10-23*, §28.3; every `*.cached` fixture)

### 5.8 Program entry

- R-5.8.1 A platform declares its entry protocol only with `entry` on a record parameter it writes out, fields among
  `init`, `update`, `view`, `subscriptions`, `onUrlRequest`, `onUrlChange`, `settle`; the protocol is chosen by the
  callback types; renaming a constructor changes no verdict; user packages cannot write `entry`. A shape other
  than `update` with 2–3 parameters, or hosted `settle` with 2, leaves the writes *pending*. `entry` does not replace
  the constructor's own inferred behaviour. (oc §30.3; bb/Entry*, o/EntryMalformedSettle)
- R-5.8.2 v1's rows; a new platform gets one through the word alone (o/EntryDeclared):

  | Platform | Constructors with entry rows |
  |---|---|
  | `browser-tea` | `Tea.sandbox`, `element`, `document`, `application` |
  | `browser-inline` | `Tea.sandbox`, `Tea.element` |
  | `browser` | `Browser.program`, `Browser.hosted` |
  | `tests/platforms/page` | `Page.sandbox` |
  | `tests/platforms/entry`, `entry-shape` | `Start.launch` |
  | `node`, `html`, `cloudflare`, toy, layered, oracle | none |

- R-5.8.3 `init` is a function (`init ⊤`; url and key for `application`; `Host msg` for hosted) called once per
  mount; what it allocates is fresh; a top-level value it returns, directly or through `λ⊤ → initialModel`,
  `init ⊤ = initialModel` or a named function, stays shared (`top-level` at the first edit); an `init` the checker
  cannot place gives an unknown initial model; a value `init` captures moves into the model only when no other
  entry callback (closures expanded) keeps it. [O 2026-10-12] (oc §22.2; o/EntryInit*, o/EntryDeclaredShared,
  bbi/OwnershipInitValue, bbi/OwnershipResetSeed, bbi/OwnershipInitCaptured*)
- R-5.8.4 `update` receives the model owned (`settle` the state): each model path it writes is accepted `entry` when
  the model is dead after the call, the path has not escaped, and it is disjoint from the message and other model
  paths. (oc §20.6, §30.3; o/EntryPush, o/HostedEntry, o/HostedEntryFresh, o/EntryRelay, o/WideModel,
  o/WideModelArms, o/SplitArmsJoin, o/RecordCallbackEntry)
- R-5.8.5 What every dispatch keeps is seen: `update`'s command half, `init`'s commands, `subscriptions`' result and
  what `view`/`subscriptions` let escape all escape; an arm keeping the old list beside the edited one is
  `disjoint`; a command capturing a model list refuses a later edit `escaped`. (oc §20.4; o/EntryKeepsOld,
  o/EntryCommand, bbe/OwnershipEscaped, bbi/OwnershipQueuedSnapshot)
- R-5.8.6 `view` and `subscriptions` read the model only: a write of it, or of a row's item, is `read-only (p)`. A
  `For` row callback's write is decided by the markup supply, `read-only`, not *pending* [G #402]
  (p/RecordForItem). (oc §20.6, §31.8; o/EntryView, bbi/OwnershipView, bbe/RecordViewChanges)
- R-5.8.7 The model's exclusivity is an invariant `init` establishes and every reachable `update` arm keeps: accept a
  recursive tree `update` grows with exclusive children, also with lambda commands; refuse duplicated children, a
  list kept elsewhere, a sharing arm, an unknown source, one record at two model paths. (oc §28 *exclusivity
  invariant*; o/EntryInvariantCommand*, bbi/OwnershipRecursiveChildren*, bbi/OwnershipUnknownTreeResult,
  bbi/RootsSharedRecord, o/RecordContentsEntry, o/RecordContentsTwice)
- R-5.8.8 Messages are owned: `update` writing its message's list, or storing an earlier payload, is `entry`; a
  message's element sharing is unknown, so editing an element of its list is `exclusive (a)` (no fixture).
  (oc §23.6; o/OwnedSend)
- R-5.8.9 A view event is not a send: what a view's messages may carry is borrowed, and an `update` write reaching
  it is `payload (a)`. A value only rendered (text, attributes, `For`/`Show` rows) is no payload; event attributes,
  children's events and mapped taggers' captures are. (oc §23.6, §28 *markup slots*, §31.6; o/EntryPayload,
  o/ViewEventPayload, o/EntryScalarHandler, o/HostedEntryView*, o/RecordPayload, o/Conduit, o/Conduit/AAIntent,
  bbi/RootsPayloadRecord, bbi/ConduitRetainedMarkup, bbe/Conduit*Errors, bbe/ConduitCarriedHandler,
  bbe/ConduitWrappedMarkup)
  - `update`'s arms are told apart, so Conduit's four model records (view events carry only `Cred` and strings) are
    accepted. [G #957]
- R-5.8.10 `onUrlRequest`/`onUrlChange` must return owned values (`need`, exact when shown); Conduit's fresh
  `ChangedUrl` address is accepted [G #412]. (oc §30.9 rule 10; o/EntryUrlTaggers)
- R-5.8.11 Hosted (a record with `settle`): `settle` runs before the first `view` and every render, is a second
  writer analysed like `update`, and the state invariant covers `init` and both transitions; `Host` is crossing and
  supplies no owned value; a callback storing state through a `Host` operation makes it escape. (oc §30.3 amended
  2026-10-22, §24.8; o/HostedEntry*)
- R-5.8.12 browser-inline's compiler-generated root closures are no holders of an old model (bi §8.4). Row readers
  and row handlers [S #298]: a handler capturing a scalar key holds nothing; one capturing the row value whole holds
  a borrowed payload, `payload`. (bi §9.5)
- R-5.8.13 The runtime obligations P1–P4 and P7 of each `entry` declaration are trusted: the runtime reads nothing of
  the old model after `update`, hands no old state to concurrent calls, recomputes `view` whole (P3), never decides
  "unchanged" from a list's or record's identity. (oc §20.9, §30.3)

### 5.9 Sends, commands and taggers

- R-5.9.1 A send giving up a list is refused at the send when the payload is unknown (`unknown (a)`), escaped or
  top-level, not disjoint, or any holder reads it after (the sender, a local, a pending operand, a lambda's capture),
  or the body sends `model.rows` while its arm keeps `model`. (oc §23.2; o/OwnedSend, o/NestedLambdaSend,
  o/SendInPayload, cbi/RefConstructShared)
- R-5.9.2 T34 (the sender reads the payload after sending, no arm writes it) is refused, finally. [O 2026-10-12,
  2026-10-25] (oc §23.1)
- R-5.9.3 A send gives up record objects too: #976's `send (Got origin)` with top-level `origin` is refused
  `top-level` at the send (`top_level_record_changed`); `send (Saved model.form)` from an arm keeping `model` is
  `later-use`. [G #976] (oc §31.6)
- R-5.9.4 A message type holding no list and no record makes no send line; a send value in a payload is no list.
  (oc §23.4, §30.9 rule 3; o/SendInPayload)
- R-5.9.5 A send handed to a function needs every supply that function makes owned (borrowed: `supply`); a send
  handed through a local-bound lambda, a local function or a structure is `supply (a)`; sends from nested lambdas
  are seen. (oc §23.4, §30.9 rule 2; o/NestedLambdaSend, o/SubOnShared)
- R-5.9.6 Taggers return owned values: `Cmd.task (λ⊤ → model.rows) Loaded` is `need` at the tagger, also when the
  callee does not see the tagger's calls; constant-message wrappers are accepted when messages hold no list.
  (oc §23.5, §28 *markup slots*; o/LambdaPassNeed, o/RandomGenerate, o/UnknownCalleeTagger, bbe/Conduit*Tagger,
  o/CapturedSubscription, cbi/CapturedSubscriptionShared)
- R-5.9.7 Commands that store, send or log take computed values (`Storage.save`, `Http.send`, `Cmd.log`,
  `Navigation.*` [M 2026-10-12]): saving the model's text then pushing is accepted; a `Cmd.do`, `Cmd.task` or
  listener body capturing a model list makes it escape at every later dispatch (`escaped`). [O 2026-10-12]
  (oc §22.3, §23.8; o/EntryValueCommand, o/NavigationCommands, o/T29)
- R-5.9.8 The `Http.Expect` decoder is followed to the tagger: an owned answer is accepted. `Http.send` with
  `stringBody` is accepted, with `jsonBody` `need (a)` (o/HttpSendBody 48:15). `Random.generate (Random.list g n)`
  is accepted when `g` makes what it returns; `Random.constant shared` refused. (oc §24.9, §30.9 rule 5;
  o/HttpAnswer, o/HttpAnswerEdited, o/HttpSendBody, o/RandomGenerate)
- R-5.9.9 Send positions come from the nominal `Send msg` operation's word:
  `Send.to : Send msg, consumed msg → ⊤`, written as `send.to message` or `Send.to send message`.
  No named `Hosted`, `Cmd` or `Sub` row supplies send positions; forwarding is inferred through their bodies.
  A top-level start handing its Send to `Listen.on` must be accepted. During implementation, v2 also
  accepts the existing callable alias through pinned protocol provenance (§2.13.5); S9's whole-corpus diff
  keeps that API unchanged. Only S10 migrates to nominal Send.to. No adapter/edit in frozen `src/own/`. [O 2026-10-25; G #440]
  (ownership-v2.md §2.13.5; replaces oc §23.3's named positions)

### 5.10 `foreign`, ownership words and the trusted surface

- R-5.10.1 A wordless `foreign` lets every argument escape (function arguments' captures too) and answers *unknown*
  unless its type is crossing, whatever its rung; a refusal through it names the rule. (oc §24.5, §18.6;
  o/ForeignNoWords)
- R-5.10.2 Words: parameter `unused`, `borrowed`, `aliased`, `returned`, `escaped`, `consumed`; function parameter
  `once`, `many`, `owned`, `escaped`, `returned`, `aliased`, `unused` (a `List` of functions takes a function's
  words per element); result `fresh`, `fresh exclusive`, `escaped`, `unknown`; `entry`; `crossing` before
  `foreign type` (after `equatable` it is the parse error `expected_token`, cb/core/CrossingAfterEquatable).
  (oc §24.2)
- R-5.10.3 Defaults are pessimistic: an unworded parameter is `escaped`; an unworded result `unknown`, unless a
  parameter is `returned` (then exactly the returned parameters). A worded declaration is read only from its words;
  its body is still checked for its own writes. (oc §24.2, §24.5)
- R-5.10.4 Words may stand in any annotated top-level signature of a core or platform package. User packages may
  not write them. [O 2026-10-25] Type/constructor ownership words may also stand at the explicit
  declaration positions specified in ownership-v2.md §2.13.5–§2.13.6, still only in core/platform packages.
  [O 2026-10-12, Change 5(b) refused] (oc §24.1, §24.4)
- R-5.10.5 Words do not change runtime types or emitted code. [O 2026-10-25] Ownership type/value metadata
  remains in typed interfaces and ownership blocks for checking; erase it only from runtime representation,
  not from the facts importers need. This clarifies the former “interfaces are the same” wording.
- R-5.10.6 `misplaced_ownership_word` (lowering's, at the word, which is dropped; one per signature outside a
  platform): a word outside a platform; nested inside a type, in a parenthesised signature, or on a signature that is
  not a function; a function word on a non-function, on an alias of a function, on a `List` alias or another holder
  of a function; a result word on a parameter or the reverse; `entry` not on a written-out record, with an unknown
  field, or with another word; impossible combinations (a word twice; `unused`/`borrowed` with another; `aliased`
  with `returned`; `once` with `many`; `owned` without `once`/`many`; two of `fresh`/`escaped`/`unknown`;
  `exclusive` without `fresh`; `consumed` on a function or a `List` of functions). (oc §24.4, §30.3;
  cb/OwnershipWordOutsidePlatform, cb/core/MisplacedOwnershipWord)
  [O 2026-10-25] The new sender/sequence/cell/failure and slot-protocol words use their separately validated
  type/constructor/parameter/result placements in ownership-v2.md §2.13.5–§2.13.6; these are explicit exceptions
  to the old signature-only placement list, never permission for arbitrary nested words.
  [O 2026-10-26] Result `elementof`, `copyof`, `prepended` and callback-parameter `stored` select exactly
  the result/retention paths specified in ownership-v2.md §2.13.6. Cellmodify's stored result is .1 only;
  an ordinary sequence store propagates loans, a store into ◆ requires no loans. Invalid kinds, destinations
  or companion words are errors; no approximate word substitutes for the declared row.
- R-5.10.7 The trusted surface is everything the guarantee assumes. Each worded or asserted declaration has a pinning
  fixture, a report change for each unsafe-direction flip, and a pinned hash of the source it was justified against
  (beni body, or sibling export, and the helper bodies on which the asserted contract relies); an unlisted declaration, missing fixture, flip with no
  effect or changed body fails the gates. The schema engine is trusted: each decoding worker builds what it hands
  `forward` from fresh values, and one reusing a list across runs declares it. (oc §24.6, §30.10;
  o/trusted-surface.txt, o/word-bodies.txt)
  [O 2026-10-25; O 2026-10-26] Include bodies that read a `taken` result and forwarders whose result is
  that taken value, transitively across modules/packages, not every caller of a fold. Their obligation is
  single-direction, once-per-index reading with no competing read while materialised. Pin each platform's
  P-sync body too. Pin identities include the package, and inlined primitives pin the codegen that actually
  executes them. The helper closure crosses module/package boundaries up to independently justified pinned
  contracts/foreign leaves; Task's scheduler and Deferred's Task helpers are no exemption (#1061, S8).
  A new unlisted reader/forwarder or changed body fails the gate; these are assumptions, not inferred proofs.
- R-5.10.8 Asserted, not inferred: the `List` array primitives, `traverseAt`, `List.focus`, `Dict.focus` (its callback
  `stored` row puts the answer back at the dictionary's value position: `Just`'s payload is stored, `Nothing` is a
  removal that stores nothing; worded in S8, #1021, #1053) and §4.10's
  `Dict` rows, the sequence/cell/failure metadata and Ref/Deferred/Builder slot-protocol rows
  (ownership-v2.md §2.13.6, pinned under R-5.10.7), `Send.to`'s consumed word [O 2026-10-25; R-5.9.9], the entry protocols, schema runs (§5.11).
  [O 2026-10-26] `List.sortWith`'s v1 row is asserted with its body pinned: fresh storage, original
  elements, list condition `lost`, record condition preserved, comparator many with borrowed supplies
  (ownership-v2.md Appendix C.9; #1014). Everything else in `core/` is inferred from its body. (oc §16.8, §24.5)
- R-5.10.9 The words must express at least v1's annotated surface (`Js.*`, `String.*`, `Schema.print*`, `Debug.*`,
  `Hosted.keyOf` (beni and inferred since 2026-10-26, #877), `Html.Event`, `Html.Pointer`, `Node.*`, `Ssr.render`, `Task.timeout`, `Task.raceOk`, `Int32`).
  (oc §24.8, §30.9; o/Words, o/WordsBrowser, o/JsPure, o/TaskWords, o/core/JsWords)
- R-5.10.10 Test platforms' foreigns that take lists carry words, like shipped platforms' (`refEq`, `Page.element`'s
  children). (oc §30.5)
- R-5.10.11 A sibling never writes a list it was handed; it returns a fresh array or a list it was given, unchanged,
  and words any list it keeps. (bd §4 *How a sibling sees a `List`*)
- R-5.10.12 In scope [O 2026-10-25]: `Task.callback`'s `Resume` gives up what it is handed (reading it after is
  `later-use`); `Ref`, `Deferred`, `Task` and the schema engine's public functions carry words justified by their
  bodies, so a call that only reads a list does not make it escape, and each is pinned per R-5.10.7. (oc §24.11)

### 5.11 Schemas

- R-5.11.1 A schema run (`parse`, `parseWith`, `decode*`, `read*`, `encode*`, `write*`) answers a fresh value holding
  only what the schema's direction keeps, per oc §30.10's table (conversions' captured or top-level values,
  `Schema.value`'s input, *unknown* for interpreting builders and unplaceable schemas); a runner handed on as a
  value has an unknown input part. (oc §30.10; o/SchemaAnswers, o/SchemaMemberHanded, o/SchemaMemberExt)
- R-5.11.2 A conversion placing one list at two positions (`λxs → Ok ( xs, xs )` and kin) makes every list of the
  answer unknown (`unknown (a)` on any write); one returning a captured list is refused
  (cbi/SchemaConversionShared); one returning a top-level record is `top-level` (bbi/RecordConversionAnswer).
  (o/SchemaConversionTwice)
- R-5.11.3 `Json.decode`, `Json.decodeValue` and a declaration's `parse` with no schema argument answer no record
  twice; so must a run of a schema built at run time (`Schema.read (Schema.list (RowJson.schema ⊤))`). [G #879]
  (p/RecordSchemaRun)
- R-5.11.4 Schema constructors (`Tree.Leaf { … }`) are constructors holding their payloads. (oc §30.11;
  o/SchemaCtorBlock) [G #201: they fold by their schema's family]
- R-5.11.5 The issues of an `Err` from `parseWith`, `encodeWith`, `printWith` are fresh: run/SchemaDepth's
  `Show.issue { i | path = [] }` is accepted. [G #413]
- R-5.11.6 A schema `default` is evaluated afresh on each decode, so a list it holds is the answer's own. [O 2026-10-25,
  #228]

### 5.12 Tasks, fibers, `Ref`, `Js.ref`

- R-5.12.1 A list held by a spawned fiber or queued body, then appended to in the same execution: refuse.
  (bbi/OwnershipConcurrentFiber, bbi/OwnershipConcurrentSoon)
- R-5.12.2 `Log.annotate`, `span`, `minimum`, `withSink` call `work` once: `update _ model = Log.annotate "k" "v"
  λ⊤ → ( { model | n = model.n + 1 }, Cmd.none )` is accepted. [G #996] Summaries through `Task.keepLogContext`
  are as precise as the bare body's (no verdict changes today) [G #774].
- R-5.12.3 **A `Ref` owns its contents.** [O 2026-10-25, #981; supersedes #219's borrowed callback] (R-8.2)
  - `Ref.get r` returns a *loan*, not an independent value. A loan is a holder: it may be read, passed to callees
    that only read it, and used to build new values (`List.filter`, `List.map`).
  - Ordinary `stored` carries loan tags/lifetimes into the built collection; it is not itself escape.
    A callee may return an incoming loan-bearing value to its still-live caller region. Stores into ◆,
    consumed demands and actual escapes still require deep no-loan checks. [O 2026-10-25]
  - A loan alive across a point where the fiber may suspend (as the effect checker infers it), or a loan that
    escapes (stored beyond its region/behind ◆, captured beyond its region, sent, given to JavaScript, returned out of its scope), is refused; the fix named is
    `List.copy (Ref.get r)`, `Dict.copy` or `Record.copy` only when that copies every borrowed storage
    path needing to leave the region. These are shallow: descendant loans remain. For List(List Int),
    `List.map (Ref.get r) List.copy` makes independent outer/inner storage; deeper structures need
    corresponding reconstruction. Diagnostics name remaining paths, never propose an insufficient automatic edit.
  - `Ref.update` and `Ref.modify` edit the contents in place when no loan of that cell is alive (across fibers this
    follows from the suspension rule; within one fiber it is ordinary liveness).
  - A `Ref` operation inside another `Ref` operation's callback, while that callback holds the moved-out contents,
    is refused at compile time for any `Ref` not proven to be another cell; never a run-time trap.
  - `Ref` and `Deferred` words (R-5.10.12) follow this model. (cbi/RefUpdateShared, cbi/RefConstructShared change
    accordingly)
- R-5.12.4 `Js.ref` contents are unknown, so a collection kept in a `Js.ref` is not edited in place; platform code
  uses a fold. [decided 2026-10-25, #969]
- R-5.12.5 `Js.maySuspend f` neither uses `f` nor loses sight of it. (oc §23.3)

### 5.13 Comparison and evidence

- R-5.13.1 A type's `eq` and `compare`, derived or written, may only read their arguments; a write in one (or in a
  function it calls) is the error `comparison_changes_value` at the write. [O 2026-10-10, 2026-10-25] (R-8.2)
- R-5.13.2 A call through type dispatch answers *unknown* (R-5.5.4); evidence also blocks initialization transfer
  (R-4.9.3). (oc §30.11; o/UnknownCalleeForms)

## 6. Diagnostics

- R-6.1 The codes, all errors, appended to lang §10's catalogue. `Dict`/`Set` storage refusals use the `list_*`
  codes. (oc §28.6, §31.9; lang §10)

  | Code | Title | Lines | Kind |
  |---|---|---|---|
  | `list_still_used` | LIST CHANGED WHILE STILL IN USE | exact list refusals | language rule |
  | `record_still_used` | RECORD CHANGED WHILE STILL IN USE | exact record refusals (bbe/RecordStillUsed) | language rule |
  | `top_level_list_changed` | TOP-LEVEL LIST CHANGED | `top-level`, lists and collections | language rule (position) |
  | `top_level_record_changed` | TOP-LEVEL RECORD CHANGED | `top-level`, records | language rule (position) |
  | `view_changes_model` | VIEW CHANGES THE MODEL | `read-only`, lists and records | platform rule (position) |
  | `list_may_be_shared` | LIST MAY BE SHARED | approximate list refusals, *pending* | compiler limit |
  | `record_may_be_shared` | RECORD MAY BE SHARED | approximate record refusals, *pending* | compiler limit |
  | `ownership_limit` | OWNERSHIP CHECK TOO LARGE | a declaration past a resource limit (R-7.4) | compiler limit |
  | `comparison_changes_value` | COMPARISON CHANGES A VALUE | a write in `eq` or `compare` (R-5.13.1) | language rule |

- R-6.2 Two kinds of refusal (dr §9; bi §5; oc §28.6): a *language rule* (exact sharing, a position rule) is
  permanent; its verdict line is "This is sharing the checker can see: …" or names the language's or platform's
  rule, and never says "not yet". A *compiler limit* (approximate, *pending*, `level`, `ownership_limit`) says "This
  is a limit of the checker, not proof of sharing: …" and names the limit; `ownership_limit` says the limit is the
  compiler's, not sharing in the code.
- R-6.3 The causes, in print order, with their kinds (e exact, a approximate, p position, e/a exact only when the
  text shows it): `unknown` a, `escaped` a, `top-level` p, `captured-edit` a, `disjoint` e/a, `held-operand` e,
  `later-use` e, `alias` e, `captured` e, `element` a, `call` a, `supply` e/a, `need` e/a, `limit` a, `exclusive`
  e/a, `once` e/a, `payload` a, `read-only` p, `level` a. Acceptance kinds: `fresh`, `call`, `param`,
  `callback-param`, `once`, `entry`; the counter `assumed` counts acceptances resting on a callee with no facts,
  allowed only for a markup construction. A label of exact resting on any approximation is a defect [G #996 claims
  visible sharing for a limit; #313, #714 blame the wrong place]. (oc §8.3, §16.11, §18.10, §20.7, §28.5, §30.11;
  src/own/Ownership.zig `Cause`)
- R-6.4 Reported modules: the application modules this run checked, including a cached refused report rechecked
  (R-5.7.5); core and platform verdicts are not reported again. (oc §28.3, §16.10)
- R-6.5 Span: the write, widened to balanced brackets for a construction or `++` chain: a writer's call, a call that
  writes an argument, a send; an entry line spans the program constructor's name; `ownership_limit` the
  declaration's name. (oc §28.6)
- R-6.6 Message shape, in order (oc §28.6; bbi/OwnershipAlias, bbi/OwnershipLimit, bbi/OwnershipGrouped):
  1. One sentence naming the operation, the base and the problem ("adds to the end of `acc` itself", "changes `xs`
     in place", "`update` changes `model.todos` in place", "Sending `x` gives the list up").
  2. Numbered source places in source order, line numbers right-aligned, carets and a label each (holder, write,
     later use); several places on one line share it, with extra caret lines (bbe/OwnershipLevel); an entry line
     adds the program constructor; `top-level` adds a "defined here" block last, with "`x` is defined in <path>:"
     for another file; a place in another file is prefixed by its path.
  3. Exact and position refusals only: what the program would see.
  4. The fix (R-6.7).
  5. The verdict line (R-6.2).

  The renderer adds no excerpt, except for `ownership_limit`. JSON carries the same text, and each code fix of
  R-6.7 as a machine-applicable edit (span and replacement text); a `--fix` is out of scope. [O 2026-10-25]
- R-6.7 The named fix (records use `Record.copy` where lists use `List.copy`) (oc §28.5–§28.6, §31.9; Message.zig):

  | Situation | Fix |
  |---|---|
  | base still used | the write's line with the base copied: `[ …List.copy acc, x ]`, `List.copy a ++ b`, `List.push (List.copy xs) 4`, `{ Record.copy r \| … }`, `(Record.copy r)` at a written argument; for `alias` also "or read `h` before line N" |
  | approximate (`unknown`, `call`, …) | "To be safe, change a copy:" and the copied line |
  | top-level list / record | make `x` a function that builds a fresh value (`x ⊤`), or `List.copy x` / `{ Record.copy x \| … }` |
  | top-level reached through `init` | build it inside `init ⊤ = …`; "wrapping `x` in `λ⊤ → x` still returns the same shared value" |
  | `read-only` | let `view` (or `subscriptions`) build a new value, or change a copy |
  | `need` | have the function return a list it owns: a new list or a `List.copy` |
  | *pending* | call it where it is written, or have it change a copy (a code line when it is a lambda) |
  | `payload` | build the messages from values that are not the model's; for records, find the model's own record by its key; or change a copy |
  | `level` | copy at the write, or where the list is put into the recursive value |
  | entry line | copy where the model gets it; for `escaped`, compute what the command needs before it is made, or hand it a copy |
  | anything else | copy before it is changed |
  | `Dict`/`Set` read after a write | `Dict.copy` / `Set.copy` |
  | `Dict` values shared | exact: `Dict.copy` is shallow, `List.copy` the value stored twice; approximate: a limit, `Dict.copy` does not help; never `Record.copy` [G #958: fixed only on #961's branch] (bbi/OwnershipSubscriptionTapAliases) |

- R-6.8 The `need` message is about the function value: names it as written, "a lambda" or "a function value";
  places "the function is handed on here" and "the function here may return a list it does not own"; never "changes
  a list it is handed", never `<function value>` for a lambda parameter. (oc §28.6 #272; cbi/NeedMessage)
- R-6.9 The `unknown` detail: "it came from a call of a function the checker cannot identify, which may return a list
  something else holds", or "…a function value that may be one of several functions". (oc §30.11)
- R-6.10 One diagnostic per root cause: refusals of one module with the same position, verdict, cause and detail
  are one diagnostic listing every base. (oc §28.5; bbi/OwnershipGrouped)
- R-6.11 `ownership_limit` names the declaration, limit, effective value and attempted growth count.
  [O 2026-10-25] Stop the affected owner immediately; no pessimistic limit class. Use canonical owner/task
  order within each dependency component; its first exhausted owner supplies the root diagnostic. Other
  members and dependents are blocked without secondary ownership verdicts/refusals/pending lines. Independent
  components finish and keep their completed exact/pending diagnostics. Sort root limits and independent
  diagnostics canonically, never choose a process-wide first failing worker. An affected module publishes no
  clean block/lowering channel; the build fails and emits no code. Print R-7.4's restructure/raise fixes, not an
  automatic copy. (oc §16.7, §28.6; cbi/OwnershipLimitPessimistic)
- R-6.12 Messages print model paths in source terms, not as the report does (`model#Article.0.errors`).
  [G, oc §28.11 item 5]

## 7. Non-functional

- R-7.1 **Budgets.** The pass is part of checking, so fc §2's budgets include it: > 250k LOC/s cold per core; an
  800 ms cold build of 100k lines; a warm one-body edit < 15 ms, a signature edit < 60 ms, a module added with no
  dependencies < 25 ms. oc §28.8's target: ≤ +10 % on `check` (Conduit, corpus pages), the 100k-line throughput
  unchanged, is the bar [G #975: Conduit +41 %, Bike Wars +11 %; accepted for O4]. A miss is reported, never
  answered by turning the pass off. (oc §28.8, §30.6)
- R-7.2 **Proved fragments and a bounded general analysis.** [O 2026-10-25] Preserve linear place-graph
  construction and the O(E+P) fresh-result template/selected-path fragment (P counts traversed path steps,
  not queries); include deterministic lookup costs where needed. State total costs over the whole module,
  including persistent unions, holder/index maintenance, κ/cell sets, recursive propagation and zero-growth
  inspections. Do not assert a general linear bound without proof. Work outside the proved fragments is
  bounded by the one summary-growth resource of R-7.4, charged before expansion. Source-proportional
  analysis and unchanged imported-table reads are exempt only through the proved nonfungible lanes in
  ownership-v2.md §4.1: B_f≤16,384 S_f, G_f≤R_f, N_f=B_f+G_f; total module time
  O(E+Σ N_f log(N_f+2)), storage O(E+Σ N_f). Length alone cannot spend G_f. Import credit cannot
  finance new invocation labels/contexts; renamed/repeated imports never renew a lane. The design must prove
  the total resource-parameter bound, not only count labels or output facts. Existing practical acceptance
  scenarios below still apply; their specified small instances must not hit the new default limit:

  | Scenario | Requirement | Reference |
  |---|---|---|
  | a 16-deep tuple holding `x` at 2¹⁶ places | no limit, checks within the hang guard | [G #856] p/DeepTupleDag |
  | a literal of n list parameters | not O(n⁴) | o/ListOfParams |
  | a TEA model of N parts and N arms | ×4 width costs ≤ ×4–5 | o/WideModelArms; N² arm copies and spine conditions open |
  | the entry's model fixpoint | linear for the proved nested-set/single-bit fragment; other propagation charged to R-7.4 [O 2026-10-25] | o/WideModel, o/EntryRelay, o/Conduit |
  | 12 mutually naming types | < 1 s | o/MutualCycles |
  | routed-app at N = 128 | `check` finishes at stated widths; linear only in the proved fragment, otherwise the explicit growth bound | [G #964] |
  | a 256-widget application | builds with no coarsening or size-only limit; extra inferred growth obeys the same accounted resource | dr §3; #220 |
  | interface reads per build | O(modules), each costing what it holds | [G #848] |
  | `Schema.read` | does not pay for all of `Schema`'s facts | oc §28.4 #814 |
  | wide values and conditions | listed fixtures get ordinary verdicts; written width/import reads never spend growth; inferred products obey R-7.4 | o/WideResult, o/WideFieldConditions, o/WideDeepCondition, o/HostValueOnePlace, o/ValueCellsGuards |
  | compile time | measure at N = 256 from the first slice; distinguish source lanes, inferred growth and time, never infer an asymptotic theorem from one size | dr §3 |

- R-7.3 **No silent coarsening.** [O 2026-10-25] No fact is cut, merged or made approximate to fit a
  resource: no width, path-depth, field-index or alias-hop precision cap. **Precise ordinary per-call-site
  callback labels stay distinct**, including forwarding wrappers. Only declared summary positions and genuine
  recursive summary dependencies fold; ordinary invocation contexts never fold merely because their code
  repeats. Keep captures' original identities on invocation, settle facts before judging a write, and never
  let a recursive proof cycle discharge its own obligation. Cycles encode backreferences, not unfolded copies.
  Exhaustion is the loud error in R-7.4, never an ownership verdict, copy or warning.
- R-7.4 **One summary-growth resource.** [O 2026-10-25] `ownership_summary_size` defaults to **65,536**
  constant-size **growth records** per owning declaration, not a cap on declaration size. Every workspace
  record belongs either to a proved, nonfungible source/import lane B_f or to G_f; the complete total N_f is
  still measured. The lanes and their constructive constant are specified in ownership-v2.md §4.1. Ordinary
  direct construction/scalar/control-flow/graft kernels of arbitrary length and unchanged imported tables
  stay in B_f. One final source validation, direct per-demand queries, singleton/direct call obligations,
  static transfer settlement and identity/delta entry work have separate bounded lanes (§4.1).
  **Qualification:** the no-length-cap proof covers fixed-topology/single-bit recursive functions and
  local groups, same-field identity-or-fresh record-update arms with direct holder proofs, and their wide-model
  main. It is not proved for arbitrary members of any of those three families: K changes×N transfers,
  D demands×H holders, N calls×M obligations and cross-field feedback products may exhaust growth even in
  safe applications. Only such work outside the stated source-linear kernels spends G_f; initial/final walks
  and another written direct query/call are not growth just because the body is longer. Ordinary labels never
  merge; multi-label/context expansion and general product work reserve G_f before their work.
  Nested classes, rounds, validation and serialization share the owner's account, with no refunds or renewed
  credit. Variable-width data stream in bounded chunks. Callee raises do not infect a caller merely reading
  the unchanged table; re-instantiation outside the direct-call lanes remains caller growth. Exhaustion obeys R-6.11 and authorises no write
  or clean output. No separate round, callback-depth or instruction-fuel cap exists.
  - Restructure suggestions: put repeated results in a list, make the wrapper chain recursive, or replace a
    closure tower with data and one fold. The optional raise attribute is
    `@ownership_summary_size(module, 131072)` in the leading module preamble, or
    `@ownership_summary_size(131072)` immediately before a top-level function/value annotation or unannotated
    definition. Function overrides may raise but not lower the inherited default; decimal literal only,
    maximum 2³²−2. Full placement/validation/format rules: ownership-v2.md §4.4. User packages may use it.
    It changes resources, never proof rules. Its implementation updates `language.md` and `skills/beni/`.
  - The measured **structural callback-label** maximum is 10 (`o/LimitOwnedAtoms.beni:45`); this is not yet
    a measurement of the complete new resource. Instrument B_f/G_f/S_f/N_f on corpus, core, platforms, examples
    and generator-deduplicated research apps from S3a (#1056); report G_f approaching one tenth of the default growth allowance to
    the owner, never silently raise it or weaken precision. A bounded-kernel lane overflow is a checked internal
    `ownership_accounting_invariant` defect, never automatic growth spill or a user resource refusal. The headroom gate uses measured G_f; baseline size is reported separately.
  - Huge named written-input/format limits remain as listed in ownership-v2.md §4.4, each loud and tested;
    the raise attribute changes only this summary allowance. No other analysis limit is introduced.
- R-7.5 v1's caps are therefore not allowed [G]: entries 262 144, path-entries 4 096, conditions 2²⁰, owned-atoms 8,
  rounds 32, fixpoint 32, callbacks 4, type walk depth 16, supply probed per cell up to 8, codec evidence nesting 8,
  alias chains of 8. (oc §16.7 cap table; fixtures in R-8.1)
- R-7.6 **Determinism.** Diagnostics, dumps, interfaces, cache entries and the lowering channel are byte-identical
  at `--jobs=1` and `--jobs=8`, twice each, wherever the project lives, `node` included; nothing
  printed is an internal id; ties go to source order; the summary-growth limit counts distinct retained growth records and semantic
  operation keys, with canonical source/import ranks and insertion schedules independent of declaration order or thread timing [O 2026-10-25]. [G #428: core's dump under load]
  (oc §9.1, §16.9, §28.9; fc §10; CL rule 5)
- R-7.7 Declaration order changes no verdict and no output except positions. (CL; ordering_test; o/RecordTopOrder)
- R-7.8 **Parallel.** Each module is checked by its worker on the module DAG, after its type check and before its
  interface is published; a waiting worker must not cost time (#845: a 19-line file went 0.4 s → 98 s under load)
  [G #845]. Splitting one module by function group is not required (#815: not viable). (oc §16.10 *As built*)
- R-7.9 The pass emits nothing itself; what is emitted in place follows R-1.12. (oc §28.9, §31.12 R6)
- R-7.10 **Data-oriented and layered.** fc §5's rules from day one; a module DAG a gate test enforces.
  [O 2026-10-25] (mem `ownership-v1-frozen`)
- R-7.11 Every enforcing `build/bad/` project rebuilt with `--release --allow-debug` is refused with identical
  diagnostics and writes nothing. (oc §28.10)
- R-7.12 **Robustness.** No input crashes the pass or overflows the stack; it ends in a report or `ownership_limit`
  (#954: `dump --stage=ownership tests/corpus/parse/good/Lambdas.beni` [G]). Writing the cache does not crash on
  schema-constructor patterns, local or imported. (oc §30.7 O0; o/SchemaCtorCached)
- R-7.13 Core's and the platforms' facts are computed when beni is built and read from the checked core; `dump` may
  recheck core from source, with the same report. (oc §16.9, §28.7)
- R-7.14 **Command line** (oc §2.4, §16.11, §24.6, §28.10, §30.7, §31.4, §31.12; corpus README):
  - `beni dump --stage=ownership <file|dir>`: every module at or under the path, in path order; embedded core and
    platform modules only when the path names their directory; none matched: exit 2; `--platform`, `--core`,
    `--core-root` accepted; it never enforces (exit 0 with refusals); a type error prints the diagnostics and no
    report.
  - Hidden: `--ownership-totals` (totals only; with another stage a usage error); `--ownership-flips=<spec>|…`
    (prints `flip <spec>: changes | no change | not applicable`); `--ownership-records-lost` (every record
    condition fails); `--sanitize-records` (development builds only, refused with `--release`);
    `--records-in-place` (records lowered in place, for the differential) [S O4b]. No `--ownership-everywhere` and
    no `"lists"` manifest key.
  - Harness: `.platform` cases, `.cached` reruns, `_expected.sources` projects (o/Conduit), the `.in-place` run
    token.
- R-7.15 **The report.** Required are the verdict lines and the count lines below; the goldens are the reference
  wherever this grammar is ambiguous. `hoist`, `summary` and `limit` lines are v2's own and not required.
  [O 2026-10-25] (src/dump/ownership.zig)

  ```text
  report  := (header body?)* "total" counts records? limits? cause*
  header  := "module " Name ("\n" | " (not checked)\n")              -- not checked: no body
  body    := write* other* "  demands" counts records?                   -- other: v2's own lines
  write   := "  " L ":" C " " op " " base ": " verdict note? approx? fix? hoisted? "\n"     -- sorted by L:C
  op      := "construction" | "++" | "List." name | "call " M "." f | "value" | "update" | "entry " M "." f
           | "update entry " M "." f | "send"
  base    := as written (local, field path, top-level, p#.a) | "<literal>" | "<call M.f>" | "<lambda>"
           | "<expression>" | "<construction>" | "<record>" | payload as written
  verdict := "accepted " kind | "pending" (": " detail)? | "rejected " cause ": " detail
  note    := " (" deciding fact ")"           approx := " (approx)"          -- rejected lines only
  fix     := " [copy]" | " [restructure]"     hoisted := " [hoisted " n "]" -- after fix; accepted, pending
  counts  := " " N ": accepted " A " (fresh a, call b, param c, callback-param d, once e, entry f; assumed g),"
             " pending " P ", rejected " R "\n"                               -- list writes only; N = A + P + R
  records := "records " N ": accepted a, pending p, rejected r (copy c, restructure s); hoisted h, eager reads e\n"
                                                    -- record writes only; omitted when none and no eager reads
  limits  := "limits " n "\n"                       -- once per run, only when n > 0
  cause   := "cause " cause " " n "\n"              -- once per run, list refusals with n > 0, in R-6.3's order
  ```

  `--ownership-totals` prints only the `total`, `records`, `limits` and `cause` lines.

## 8. Acceptance

- R-8.1 **The suite.** v2 is accepted when `zig build gates` is green with the whole of `tests/corpus/ownership/`,
  every `build/bad/` and `check/bad/` fixture whose golden carries a code of §6, and `run/` and `browser/` outputs
  unchanged. Ownership goldens are compared on their verdict and count lines (R-7.15); v2 regenerates the rest. On
  every platform, `check` fails with the ownership codes alone exactly when the report has a refused, *pending* or
  limit line, and passes otherwise. [O 2026-10-25] (corpus README; oc §28.10, §30.7) Against today's goldens:
  - **At O4a (list enforcement everywhere)**, these cases' `check` turns from pass to fail, with the codes their
    report lines map to (R-6.1, R-6.3); their dump goldens do not change. Default platform:
    ApartAcrossModules, ApproximateAliasLevels, Binders, BranchEscapes, BranchKeeps, BranchSoonEscapes, Callbacks,
    CallerSide, CapturedParam, CapturedReread, CarriedLambda, Changed, Clo, ClosureCapture, ClosureLevels, Copy,
    CrossModule, DeepCapture, DeeperLevel, DictFocus, DictValueWritten, Differential, DirectCapture, Disjoint,
    ElementEdits, FoldLevels, FoldTypeParameter, HostValueOnePlace, JsPure, LaterRead, LevelFresh, LevelLimit,
    LevelPlacesCall, LevelPlacesKinds, LevelRecursiveUpdates, LocalGroups, LocalPolyRec, MarkerAcross,
    MarkerDisjoint, MaybeDefault, MutualCycles, MutualTypes, NeedUnknown, Nest, NullaryCopy, Once, OneListTwoLevels,
    OpaqueSlots, ParamHole, PathCut, Permutations, PolyRec, PolyRecBranch, PolyRecCps, PolyRecLevels, PolyRecMutual,
    PolyRecShared, PolyRecTuples, PolyRecTwice, Prepend, PrependFresh, Question, RecordContentsBuilt,
    RecordContentsRows, RecordCopy, RecordField, RecordTopOrder, RecordUpdateEscapes, Recursion, ResultDefault,
    ReturnsArg, SchemaAnswers, Split, Spreads, StoredTwice, T59, Toplevel, UnusedSubtree, WideCtor, WideResult,
    core/JsWords. `browser-tea`: EntryCommand, EntryInit, EntryKeepsOld, EntryValueCommand, EntryView,
    LaterUseEnforced, NavigationCommands, OwnedSend, WordsBrowser. `browser`: EntryInitProgram. `page`:
    ForeignNoWords. `node`: Words, core/CastAcross, core/CastOccurrence, core/CastRegion, core/FullCast,
    core/GrowingCast, core/GrowingReturnedFunction, core/SchemaCastSlot.
  - **At O4a**, every `bbe/` project with only ownership codes (Conduit*Errors, Conduit*Tagger,
    ConduitCarriedHandler, ConduitWrappedMarkup, EverywhereLaterUse, OwnershipEscaped, OwnershipLevel) fails with
    its `_expected.diag` without the flag; `+everywhere` tokens become the plain platform; `build/bad/` gains a
    `node` project per ownership code. (oc §30.7 O4a)
  - **At O4b (record enforcement everywhere)**, `check` turns from pass to fail for the record-only cases (default
    platform): RecordAliasResult, RecordBaseLevels, RecordContents, RecordContentsAnswered, RecordContentsCore,
    RecordContentsKeep, RecordContentsReturned, RecordDemands, RecordFold, RecordFoldBelow, RecordNeed, RecordOnce,
    RecordRecursive, RecordSameCall, RecordSortWith, RecordSupply, RecordTree, RecordWriteOnlyCall,
    core/RecordKeepJs; and bbe/RecordMayBeShared, RecordStillUsed, RecordTopLevel, RecordViewChanges fail without
    the flag.
  - **At O4b**, `emit/` goldens of `node` programs with a record update in a clean module change from spreads to
    in-place stores (oc §31.10's form): candidates NullaryMethods, RecordUpdateIdentity,
    release/RecordUpdateIdentity, release/app/FieldsAndTags, release/app/ShapeRecordNames,
    release/app/SpecRecordLambdaUpdate, release/app/Unboxed; run hashes are re-recorded, outputs unchanged.
  - **With R-7.4**, these get ordinary verdicts and no `limit` line or `ownership_limit`: o/CallbackChain,
    o/InitializationLimit, o/LimitOwnedAtoms, o/LimitSpine, o/SplitCap (no probe cap), o/AliasWriter (no pending,
    9 hops), bbi/OwnershipRounds, bbi/OwnershipEntryRounds, cbi/OwnershipLimitPessimistic (its limit;
    its *pending* lines stay).
- R-8.2 **The known gaps are acceptance.** Every [G] item turns green, with the verdict this document gives, not
  v1's; a gap moves from `tests/pending/` to the corpus as it closes. [O 2026-10-25] (mem `ownership-v1-frozen`)
  - Pinned already: p/DeepTupleDag, p/DictFocusGrow, p/DictHelperAlias, p/DictRecordAlias, p/DictTupleAlias,
    p/RecordForItem, p/RecordSchemaRun, p/RecordSplitPushBack, p/RecordWriteBeforeKeep, p/RecordKeptInLiteral,
    p/RecordInnerKept.
  - Without a pinning fixture (a red fixture is to be written for each before design starts):

  | Req | Program | Required verdict |
  |---|---|---|
  | R-4.6.7 #977 | `want xs = List.update xs 0 λl → List.push l 9` on `List.push (List.push [] [1]) [2]`; twin with one list pushed twice | accept `callback-param`; twin `exclusive` |
  | R-4.6.8 #987 | `Dict.insert (Dict.insert (Dict.empty ⊤) 1 xs) 2 (List.copy xs)` then `Dict.update d 1 λm → Maybe.map m λp → List.push p 9` [needs #961]; list form `List.update [ xs, List.copy xs ] 0 λv → List.push v 9` | accept; twin storing `xs` twice `exclusive` |
  | R-4.6.10 #971 | `List.update (List.update [ [ 0 ], xs ] 0 λ_ → xs) 0 λv → List.push v 9`; helper `updH l xs = List.update l 0 λ_ → xs` | `exclusive`; control `λ_ → [ 2 ]` accepted |
  | R-4.6.9 #970 | `case l of [ p, …_ ] → [ …l, p ]` (and `List.push l p`, a tuple payload), then `List.update … 0 λv → List.push v 9` | `exclusive` |
  | R-4.7.4 #395 | `type A = A (List Int) B`, `type B = B (List Int) (Maybe A)`, #395's `ab2` | accept |
  | R-4.7.7 #396 | `RNode { l, v, r }`: push the left child's `v`, return the right child (`rt1`) | accept |
  | R-4.7.8 #400 | a function writing one list below a part and returning another part, called on a tree with one list at three levels (bridge `Case5230`); `c1`/`c2` | accept; `c1`/`c2` stay `exclusive` |
  | R-4.7.9 #509 | #509's `NestedLive` (`Ok (Ok xs)`, push `v`, read `xs`); nested-pattern and `Just (Just xs)` forms | `alias` (`list_still_used`) |
  | R-5.13.1 | `type T = T (List Int)` whose `pub eq (T a) (T b) = List.length (List.push a 0) == List.length b` | `comparison_changes_value` at the push |
  | R-6.6 | bbi/OwnershipAlias's JSON diagnostic | carries the fix edit: span of `model.todos`, replacement `List.copy model.todos` |
  | R-4.4.3 | `ys = [ Box n, …xs ]` then `List.push ys (Box 1)` while `xs` is read | accept |
  | R-4.8.17 #869 | ExchangeRows, writes/IndexGuard, KeyedEnds' `swapAt`/`List.drop` over exclusive rows; a twin putting one row twice | accept; twin `exclusive` |
  | R-5.11.6 #228 | a schema field with a list `default`, decoded twice, the first answer's default pushed while the second is read | accept |
  | R-5.5.6 | `writer = List.push`, `ys = writer xs 1` with `xs` read later; a nine-hop alias chain | no *pending*; `later-use` at the call, as for `List.push` |
  | R-5.10.12 | `Task.callback` whose `Resume` is handed a list read after; a read-only call of each worded `Ref`/`Deferred`/`Task`/schema function, then a push | `later-use`; accept |
  | R-5.12.3 | `examples/chat/server` with `Ref.update room.members λmembers → [ …members, x ]` (no `List.copy`) and `tellEach (List.filter (Ref.get room.members) …) event` | both accepted; the join edits in place |
  | R-5.12.3 | iterating `Ref.get room.members` directly while sending to each member | refused (loan alive across a suspension), fix `List.copy (Ref.get room.members)` |
  | R-5.12.3 | `Ref.get r` stored in a model | refused (the loan escapes) |
  | R-5.12.3 | `Ref.update r λxs → …` whose callback calls `Ref.get r` (or any `Ref` operation on a cell not proven distinct) before it returns | refused at compile time |
  | R-5.12.3 | check/good/RefUpdateImpure (callback touches no `Ref`) | stays accepted |
  | R-4.8.7 | `shift 3 origin`, then `(shift 3 origin).x` | first call refused `later-use` (`record_still_used`), fix `shift 3 (Record.copy origin)` |
  | R-4.8.12 #394 | #394's `caseAlias` and `tupleDestr` | accept, `[hoisted 1]` |
  | R-4.8.13 #414 | a caller updating a record after a callee whose callback keeps one list field of it | accept; no list line moves |
  | R-4.8.14 #870 | #870's seven programs (`writes/A1Fallthrough`, …) | each base accepted or refused with a cause, none *pending* |
  | R-4.8.15 #410 | a model field whose variants move one form record (`Editing slug errors form` → `Saving slug form`); twin holding it at two fields | accept `entry`; twin `disjoint` |
  | R-4.10.8 #420 | callback writing records of `List.append a b` / `List.filter` of exclusive inputs; `{ i \| path = [] }` over Schema issues | accept; no list line moves |
  | R-5.2.8 #188 | a callee pushing onto the list its callback returns, items shared with the caller | accept |
  | R-5.2.9 #868 | `editL` over `List (List Int)` through `List.map list λrow → if … then f row else row` | accept; captured-twice twin refused |
  | R-5.3.7 #955 | `n = List.length (List.foldr [] [] List.intersperse)`; a twin writing the accumulator | no limit, clean; twin keeps its verdict |
  | R-5.4.3 #382 | #382's five shapes | `later-use` or `alias` |
  | R-5.4.4 #383 | `( w 1, w 2 )`, `w = mkPusher xs` | refused `once` |
  | R-5.4.5 #416 | `rev p = g2 (bump p _) p.x`; `rev xs = g2 (push xs _) (List.length xs)` | accept both |
  | R-5.4.9 #956 | #956's `flatten` reduction; twin calling `f` on a held point | accept; twin refused |
  | R-5.5.5 #278 | #278's three programs; `if flag then λ⊤ → shared else λ⊤ → []`, pushed | accept; twin `top-level` |
  | R-5.5.6 #279 | `bad ⊤ = List.push (keepAlias [ 1 ] 1) 2`; `keepAlias shared 1` | accept; twin refused |
  | R-5.5.12 #963 | `Sub.batch [ Push.onPush (λv → Pushed v) ]`, `Pushed : Value → Msg` | accept |
  | R-5.8.9 #957 | o/Conduit's four model-record lines at `Main.beni:254` | accept `entry` |
  | R-5.8.10 #412 | o/Conduit's `msg#ChangedUrl.0` line | accept `entry` |
  | R-5.9.3 #976 | #976's program (`fire send = send (Got origin)`, top-level `origin`) | refused `top-level` at the send (`top_level_record_changed`) |
  | R-5.9.9 #440 | a top-level start handing its send to `Listen.on` (browser-inline) | accept |
  | R-5.11.5 #413 | run/SchemaDepth's `Show.issue { i \| path = [] }` | accept |
  | R-5.12.2 #996 | `update _ model = Log.annotate "k" "v" λ⊤ → ( { model \| n = model.n + 1 }, Cmd.none )`, browser-inline | accept |
  | R-4.10.4 #871 | `{ Record.copy r \| … }` on an open record type, `r` read whole after | accept |
  | R-6.3 #996 | the #996 refusal's message | "a limit of the checker", not "sharing the checker can see" |
  | R-7.12 #954 | `dump --stage=ownership tests/corpus/parse/good/Lambdas.beni` | terminates with a report |
  | R-7.6 #428 | core's dump at `--jobs=1` and `--jobs=8` under load | byte-identical |

  - Cost items ([G] #845, #848, #964, #975) are measured by `test-perf`/`bench`, not the gates.
- R-8.3 **Parity with v1.** No safe program v1 accepts may become refused (a stop condition, reported, never worked
  around); every v1 refusal the text proves unsafe stays; where v1 is wrong the requirement wins and the golden
  changes; any other golden change is justified line by line. No precision is built that only `browser` or
  `browser-tea` needs. [O 2026-10-25, #966] (oc §30.9, §32.4; dr §9)
- R-8.4 **The positive corpus is clean.** With list enforcement on everywhere, no refused or *pending* list line
  across oc §30.7 O1's roots (the positive corpus and platform variants, Debug fixtures, Workers corpus, examples,
  live bench applications, core, every platform surface); core and every platform have no refused or *pending*
  record line; every `run/` fixture gets the same verdict with enforcement everywhere as without.
  (oc §30.7 O1, §31.16; #961)
- R-8.5 **Value-semantics differential.** Every `run/` program built with records in place (plain, under the
  sanitiser, and `--release`) prints its spread-recorded golden (`zig build test-records-in-place`,
  `BENI_IN_PLACE=all`; under `--ownership-everywhere` until `--records-in-place` lands [O 2026-10-25, S O4b]); `run/RecordHoistValues`,
  `run/RecordInPlaceValues` and `run/RecordInPlaceExpressions` match; the `.in-place` fixtures pass. The list
  sanitiser traps any read through an old holder and runs the corpus clean [S O5]. (oc §31.12, §30.7 O5)
- R-8.6 **Lists independent of records.** Under `--ownership-records-lost` every list line is byte-identical
  (`zig build test-records-lost`). (oc §31.4 item 6)
- R-8.7 **Each rule has a test that notices it.** For every refusal rule a mutation disabling it fails some fixture
  (v1: `-Downership-record-mutation=…`, `zig build test-record-mutations`); every flip of a trusted word changes its
  pinning fixture (R-5.10.7). (oc §31.12, §24.6)
- R-8.8 **Internal consistency.** Wherever v2 computes one fact two ways (v1: `-Downership-full-cross-check`), a
  dedicated safety build with the explicit full-cross-check option checks they agree over the corpus.
  [O 2026-10-25] Expensive enumerating oracles are excluded from the ordinary gates binary; constant-work
  per-record invariants remain under runtime safety and inside the accounting bound. [G #427, #694, #892]
- R-8.9 **Lowering obligations.** Under runtime safety the lowering asserts that every in-place write it emits is an
  accepted write of a clean module; a read reached before its placement panics, never emits the old field access.
  (oc §31.10, §31.12 R6)
- R-8.10 **Red first.** Every defect fixed and every rule added gets a corpus fixture that fails before the change,
  preferably under `run/`. (CL rule 3)
- R-8.11 **Lean oracle** (`proofs/ownership/`): where Zig accepts what Lean rejects, that is a soundness defect.
  It is advisory: Lean results are not part of acceptance. [O 2026-10-25] (oc header, §26.7)

## 9. Open questions for the owner

1. Does stability (each release runs the previous release's accepted corpus, oc §28.11 item 2, not started) bind
   v2?

Follow-up outside this document (Q1, answered by O4b and #966): lang §6.3, §11.11–§11.12, be §4, be §15.5 and
bd §9.4.4 still say records are written in place "on every platform".
