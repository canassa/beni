# 98 — Browser application ownership: audited causes and idiomatic repairs

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


*2026-10-15. The original campaign on `52a2c5d2f` plus PR #116's
initialization-transfer rule is retained as historical evidence in
[`98-browser-app-ownership.json`](98-browser-app-ownership.json). The independent
audit below corrects its causal and scheduling claims. The repaired apps are
measured on the rebased PR. The later captured-local soundness correction is
recorded separately in §5.*

## 0. Outcome

TodoMVC and Sternhalma build on `browser-direct` after ordinary source changes.
Their pending pages move into the paired direct corpus. Bike Wars' one copied
append clears all three ownership errors, then reaches the existing document
helper lowering gap (`not_implemented`); it stays pending with its view intact.
All three original **browser-tea transcripts remain byte-identical** in development
and release. Release replay uses the corpus's hidden `--allow-debug` for Bike
Wars' existing `Debug.log`; that is not a production-release claim.

| Original pattern | Audit finding | Repair / result |
|---|---|---|
| TodoMVC queues a save holding `model.todos` | correctly rejected; the corruption schedule requires synthetic sends in one task, and only cross-tab storage events differ | encode in `save` before constructing `Cmd.do` |
| TodoMVC's `init = λ⊤ → init` returns a top-level model | omitted by the original report; the decided top-level rule, not a checker limit | `init ⊤ = …` builds the model; the entry uses that function |
| Bike Wars' append at `Bike.beni:91` writes `current.trail` | the single root of all three ownership errors, including `handleInput` and `initBikes` | `List.copy current.trail ++ other.trail`; ownership clears, document-helper lowering stays pending |
| Sternhalma reuses `Board.init` for setup and later games | correctly rejected; the selection screen ignores occupants, while game two retains game one's pieces | `Board.init ⊤`, with `centralHexagon ⊤` generating the append's base inside the call |
| Sternhalma's original private `centralHexagon` initializer read | PR #116's one-shot private initialization rule accepts this separate class | keep the existing rule and its positive/negative fixtures; the repaired app now builds its board in a function |

The original report's seven diagnostic sites were not seven independent causes.
Its TodoMVC entry refusal hid another error, and Bike Wars' three messages
were consequences of one append. Each remaining refusal protects value
semantics or the decided top-level contract; none is made permissive here.

## 1. How ordinary code shares

**TodoMVC: queued save.** `changed model todos = ({ model | todos = todos },
save todos)` installs one list in the model and in the command's captures when
`encode todos` runs inside `Cmd.do`. The refusal remains correct: the program
can be driven by two synthetic sends in one JavaScript task, so the first save
can still hold the list when the second update appends to it.

**Native input cannot reach that schedule.** `Cmd.do` delegates to `perform`
(`platforms/browser/Cmd.beni`), whose nonsuspending body is `Now`. Both Tea
platforms' `queue` functions call `Task.soon`; `Task.schedule` queues the drain
with `queueMicrotask`. That work runs after each native listener before later
native input can update the model. The test driver's `click button 2` uses two
`dispatchEvent` calls on the same stack; it is a synthetic batching witness,
not a reproduction by ordinary typing or clicking. The driver's own native /
synthetic distinction is documented in `tests/browser/driver.mjs`.

The reduced `QueuedListSnapshot` page deliberately uses that synthetic schedule.
It sends lengths back and prints `12` with persistent lists; the previous
isolated emitted-code experiment that made only `List.push` mutate printed
`22`. That reduced page makes the stale read visible **inside the reduced page**.
TodoMVC does not send lengths back: it writes local storage. Even under synthetic
batching, its final local storage value and the sending page's rendered UI are
the same. Only the intermediate **cross-tab `storage` events** differ: another
document can observe the first snapshot or the already-grown second snapshot.
The sending document does not receive its own storage events. The old report
should not be read as claiming user-visible corruption from native TodoMVC input.

The repair computes `text = encode todos` in `save`, then builds a command that
captures only that string. This preserves ordinary app behavior and the intended
synthetic snapshot semantics. The checker still conservatively describes the
unrepaired command escape as approximate; this audit does not relabel that
analysis exact or add scheduling knowledge to it.

**TodoMVC: initialization.** The original `init : Model × Cmd Msg` is a top-level
value, including its `todos` list. `{ init = λ⊤ → init, … }` returns that shared
value; a lambda does not rebuild it. This is explicitly the decided behavior of
`ownership-checker.md` §22.2 (the owner's `init`-builds-its-model decision), not an
omitted checker feature. The entry's queued-save escape previously masked it.
A probe applying only the save repair to the original TodoMVC now reports
`top_level_list_changed`; its captured diagnostic is in the JSON evidence.
`build/bad/direct/OwnershipInitValue` pins the small refusal. The app becomes
`init : ⊤ → Model × Cmd Msg; init ⊤ = …`, and the entry uses `init` directly.

**Bike Wars.** `Bike.shoot` line 91 computes collision geometry using
`current.trail ++ other.trail`, which writes the append's base in place. The
returned bike retains `current.trail`. `Game.handleInput` then shoots the green
bike using the old red bike, giving the second diagnostic. Its summary carries
the same write to the entry's trails from `Game.initBikes`, giving the third.
**All three have that one root.** `initBikes` is not independently made unsafe
by a different writer, and this repair does not make it a function. Copying only
the retained base at line 91 clears all three demands. The two existing
`prepend_in_loop` warnings remain. The next error is Main's document-view helper,
the S6 helper-markup class. No markup wrapper or view rewrite bypasses it.

**Sternhalma.** `setupBoard` starts from `Board.init` for every game. Setup and
later moves edit its cells. The old report incorrectly used the selection view
as an observation of those edits: `viewBoard SelectPlayers` reads `Board.init`,
but `viewCell SelectPlayers` calls `viewEmptyCellStatic`, which uses geometry /
triangle color and **ignores `occupant`**. That screen does not reveal sharing.
Starting another game does: its setup reuses cells still occupied by game one's
pieces, including pieces moved out of the newly filled home triangles.

The repair makes `Board.init : ⊤ → Board` allocate the board during the call.
`centralHexagon : ⊤ → List Coord` also computes a fresh append base during that
call. Both setup and the selection drawing call `Board.init ⊤`; no seed board
is retained across games. The coordinate constants used only as append inputs
need no new ownership rule.

## 2. The existing initialization-transfer rule

PR #116's dated amendment in `ownership-checker.md` still specifies a private,
single-read initialization transfer. Only an application module's nonrecursive,
parameterless initializer at frame zero may consume a private value's fresh
allocations. All BIR value references in that module count, including deferred
bodies, and the count must be one. Public values, function/closure reads,
foreign/unknown arrivals, evidence/identity parameters and coarsened summaries
receive no permission.

Normal instantiation preserves allocation identities, aliases, escapes and
container/deep conditions. Arriving shared cells remain shared, and reading the
destination afterwards still uses the ordinary top-level rule. There is no
inserted copy or initializer re-evaluation. Reference counts saturate at two;
ownership summary blocks are version 6 (including the evidence-parameter restriction). §26.7 retains the Lean-model gap for
module initialization. The original positive/negative class fixtures remain:
repeated/deferred/public/function reads, evidence parameters, result aliases,
shared arrivals, escapes, chains and separate allocations.

Those are the checker changes already present in #116. The app-repair follow-up changed
no checker rule; the subsequent captured-local correction is recorded in §5. In particular it adds no permission for an `init` function
returning a top-level value.

## 3. Diagnostics and executable evidence

An entry demand on a changed top-level list, including one returned through
`init`, recommends building the value **inside the init function**:

```beni
init ⊤ = …
```

The message explains that `λ⊤ → initial` still returns the same shared value and
cites `ownership-checker.md` §22.2. Other top-level demands recommend making
the value a function or writing `List.copy <name>`, citing §4.2. It no longer suggests that merely moving the
read to startup makes the top-level lists fresh. Whole-list, nested-list and
entry cases have full diagnostic goldens, including the new `OwnershipInitValue`.
The existing still-used-base hint is retained verbatim; `OwnershipBorrowedAppend`
still prints `List.copy current.trail ++ other.trail` at the append site.

The JSON evidence separates the **historical baseline**, the **save-only init
probe**, and the **repaired builds**. Repaired TodoMVC and Sternhalma run on both
platforms in both modes. Bike Wars runs its original tea script in both modes;
its direct build reports `not_implemented` and is not executed. The original tea
goldens are never blessed or rewritten. Their SHA-256 hashes are recorded in the
evidence. Paired direct pages use the corpus's existing renderer-comment-free
comparison against one golden for both platforms; TodoMVC's direct golden is the
normalized tea transcript, while the separate original tea transcript is retained
byte-for-byte. No semantic output is removed or given a platform-specific golden.

The TodoMVC and Sternhalma pending records are removed on promotion. Bike Wars'
pending record names its lowering error and existing warnings. Its source stays
idiomatic, and its full document view remains unchanged.

## 4. Validation

The diagnostic corpus pins every changed message and the added top-level-init
refusal. All three original tea scripts match their existing byte-identical
goldens in development and release. The paired TodoMVC/Sternhalma cases compare
both platforms to one golden. Run hashes are regenerated with
`zorg build test-run-hashes` after the rebase and app edits; none is hand-merged.
Gate results and the exact pending signature are recorded with the final run.

*Linux budgets.* Fresh x86-64 Linux runs pass all functional comparisons but
count 5,711M instructions for TodoMVC's paired page, 9,031M for Sternhalma's
paired page and 11,387M for Sternhalma's separate value fuzz. On 2026-10-15 the
owner explicitly granted 6,300M / 10,000M / 12,600M respectively, about 10%
headroom. These case-specific files record the measurements and removal
condition. A `.fuzz-budget` is independent of a page's `.budget`; TodoMVC's
value fuzz keeps the default 4,300M. No checker rule or comparison was weakened.

Final reference-host validation: `zorg build test-run-hashes -j8` and exact
`zorg build gates -j8` both pass on x86-64 Linux. The checked source/fixture
checksums match this worktree. The macOS constituent checks and hash recording
have only the two known case-folding failures; exact gates refuse that host.
The focused Bike Wars pending replay matches `not_implemented` plus its two
existing prepend warnings. No checker refusal was weakened.

## 5. Captured-local entry correction (2026-10-15)

The independent review found a soundness hole in §22.2: `init = λ⊤ → m`
returned cells also retained by `view`. A local literal already reached this
hole on master; this PR's private initialization transfer also made `m = initial`
reach it. Neither is an allocation by the init body. The dated §22.2 amendment
now keeps every other entry field's environment live against runtime writes,
including instantiated bindings of helper-returned closures. Both reported
programs and a carried-view twin are rejected fixtures. A helper-returned entry
record updated at its use is also refused. The init-only capture
and body-allocation positives remain accepted. Block version 7 first added entry environments; version 8
also preserves root/wildcard entries when excluding the known init subtree,
invalidating both older proofs. This is a soundness fix, not a new acceptance rule.

Rebased onto master including #124 (`134d24ab9`). Both reported refusals fail
their tests when the capture fix is set aside. TodoMVC and Sternhalma's paired
pages also pass with initialization transfer temporarily disabled, on both
platforms in both modes. No shipped app depends on initialization transfer now.
The original tea goldens remain unchanged.

Diagnostics now scope the `init ⊤` advice and §22.2 citation to entry demands.
An ordinary top-level write recommends making the value a function or copying
the list (§4.2); a record's list field is the copy target. Inferred evidence at
two types, return-type dispatch with hidden identity, recursive consumers,
coarsened results and width-limit arrivals have ownership fixtures. Budget files
are checked against the complete case inventory before filters, including a
separate value-fuzz case; orphan page/fuzz/unknown-kind grants fail. Those three
harness tests fail when the inventory fix is set aside.

Final validation of the capture correction: full Linux `zorg build test-run-hashes`
and exact `zorg build gates` both pass. Source and fixture checksums match the
worktree. macOS constituent checks have 1,303 passed, 15 skipped and only the two
known case-folding failures. No budget grant was added or increased.

After master advanced, the branch was rebased again onto `2f397d7b6` (including
nullary methods and release source maps). Full Linux hash recording and exact
gates pass again; regenerated hash files need no further changes. The three
original tea goldens remain byte-identical.
