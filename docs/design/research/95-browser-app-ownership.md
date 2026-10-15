# 95 — Unchanged browser applications: one checker limit, six sharing errors

*2026-10-15. Follow-up to research 87 §6, on `52a2c5d2f` plus the
initialization-transfer rule below. The applications are unchanged. Full build
diagnostics and all twelve build/script outcomes are in
[`95-browser-app-ownership.json`](95-browser-app-ownership.json).*

## 0. Outcome

None of the three full applications builds on `browser-direct`. One of the
seven reported errors is a checker limit and is fixed. The other six protect
observable value semantics; accepting them would require a copy or a change to
the programs, neither of which this work introduces. This is evidence against
an unconditional claim that idiomatic Elm-style code almost never needs an
ownership adjustment. It is not a successful three-application port.

| Original error | Verdict | Small class fixture | Result |
|---|---|---|---|
| TodoMVC, entry changes `model.todos` | real sharing | `browser/tea/QueuedListSnapshot`, `build/bad/direct/OwnershipQueuedSnapshot` | still rejected `list_may_be_shared` |
| Bike Wars, `Bike.shoot` line 91 concatenates `current.trail` | real sharing | `build/bad/direct/OwnershipBorrowedAppend`, first diagnostic | still rejected `list_still_used` |
| Bike Wars, `Game.handleInput` line 136 calls shoot before reading `red.trail` again | real sharing | same fixture, second diagnostic | still rejected `list_still_used` |
| Bike Wars, entry receives `Game.initBikes` | real sharing | `build/bad/direct/OwnershipResetSeed` | still rejected `top_level_list_changed` |
| Sternhalma, `Board.init` concatenates `centralHexagon` | checker limit | `ownership/InitializationTransfer`, `browser/direct/InitializationTransfer` | accepted |
| Sternhalma, entry changes `Board.init.cells` | real sharing | `build/bad/direct/OwnershipResetSeed` | still rejected `top_level_list_changed` |
| Sternhalma, setup's fold changes `Board.init.cells` | real sharing | `build/bad/direct/OwnershipSetupSeed` | still rejected `top_level_list_changed` |

## 1. How ordinary code shares

**TodoMVC.** `changed model todos = ({ model | todos = todos }, save todos)`
installs the same list in the model and in a command's captures. `save` computes
`encode todos` inside `Cmd.do`, when the queued command runs. A second message
can append before that queue runs. This is not a failure to prove deep
exclusivity of todo records: the ownership report's actual cause is `escaped`.
The `Perform` arm printed by the summary conservatively includes the queued
`Now` arm selected for a nonsuspending body; both retain the capture.

The reduced page sends two clicks in one task. Each update appends and queues a
command that sends back its list's length. The existing browser-tea runtime
prints `12`. In an isolated emitted output under `/tmp`, changing the small-list
`List.push` implementation from slicing its base to mutating that base prints
`22` under the same script. This experiment changes no repository runtime and
bypasses no compiler permission in a shipped build. It demonstrates precisely
the old-value observation the check prevents. In TodoMVC, queued storage writes
encode those retained snapshots; storage notifications to another document can
observe the difference even when the final stored value agrees.

The diagnostic usefully tells the developer to compute what the command needs
before making it. Here that means encoding the snapshot before constructing the
command. Its classification is conservative: it says "a limit of the checker,
not proof of sharing" and does not identify `save` or a second event. That text
is weaker evidence than this scheduling witness. No diagnostic is relabelled
exact without the checker itself proving the schedule and retained alias.

**Bike Wars.** `current.trail ++ other.trail` constructs collision geometry, but
in-place concatenation changes the current bike's trail itself. The record
returned just afterwards retains that trail. The caller then shoots the other
bike using the original red bike, so its geometry also observes the change.
The two errors are related boundaries of the same genuine alias, not two
independent checker limits. Their messages name the concatenation/call and the
later record read at lines 92 and 137. `initModel` also retains `initBikes`, and
Spacebar restarts from that same top-level model. Changing its trails would
change the next game's initial state. The third message identifies `Game.initBikes`
and explains that all its readers would observe the edit.

**Sternhalma.** `setupBoard` starts from `Board.init` on every game and edits its
cells through a fold. The selection view separately draws `Board.init`. An
in-place setup or move would change the initial board used for rendering and
future games. The setup and entry errors correctly identify the shared seed,
although the entry wording "when the program starts" is imprecise here: init
returns `SelectPlayers`; `Board.init` enters the model after `SetPlayers`.

The private `centralHexagon` list is different: its only reference is the strict
concatenation inside `Board.init`'s module initializer. It has no later reader,
no export and no repeated call. Keeping the resulting `Board.init` immutable
is sufficient; the intermediate binding need not remain independently shared.

## 2. The general rule

The dated amendment in `ownership-checker.md` specifies a private, single-read
initialization transfer before its implementation in `src/own/Ownership.zig`.
Only an application module's nonrecursive, parameterless initializer at frame
zero may consume a private value's fresh allocations. All BIR value references
in that module count, including references in deferred bodies; the count must
be one. Public values, function/closure reads, foreign/unknown values and
coarsened summaries receive no permission.

Normal summary instantiation preserves fresh allocation identities, result
aliases, escapes and both container/deep conditions. Arriving shared cells
remain shared. Reading the destination afterwards still uses the ordinary
top-level rule. The checker does not insert a copy or re-evaluate an initializer.
Reference counts saturate at two and are computed once per module. Ownership
summary blocks advance from version 4 to 6 (including the review guard below).

The rule is listed in §26.7 as not yet modelled in Lean: its language does not
have private module bindings or module initialization. The risk is accepting a
repeated/deferred read or losing an alias during transfer. Class fixtures pin
public, repeated, deferred and function reads, repeated result positions,
shared arrivals, escaped allocations, separate allocations and the destination's
continued shared status. With the implementation stashed, both the ownership
fixture and paired page fail; restoring it accepts the one-shot transfers and
keeps all unsafe twins rejected. Existing ownership goldens are unchanged.

## 3. Build and page evidence

Each unchanged source was built with `--platform=browser-direct --no-cache
--diagnostics=json`, in development and release mode. TodoMVC has one error,
Bike Wars three (plus two existing prepend warnings), and Sternhalma two. No
direct page is executed after its build fails.

Every existing application script was also replayed on browser-tea in both
modes against its one existing happy-dom golden. All six transcripts match.
Release replay uses the corpus's test-only `--allow-debug`, needed by Bike
Wars' existing `Debug.log`; this is not a production release-build claim.
The paired initialization-transfer page runs on both platforms against one
golden and through the existing page/value differential fuzzers.

TodoMVC and BikeWars retain their pending direct pages and pinned diagnostic
multisets. Sternhalma gains an external-source pending direct page using its
existing play script and golden, with two `top_level_list_changed` pinned in
`tests/pending/RED`. These are outstanding application builds, not claims that
the remaining rejections are checker bugs. Sternhalma's full corpus replay was
already excluded from the gates for its instruction budget (research 88 §1);
this work adds no budget grant and does not weaken that boundary.

## 4. Validation

`zorg build gates`: 1,297 passed, 15 skipped, two failures, both the known macOS
case-folding filesystem tests in `build_test.zig` (hard-linking `Zz.mjs` to
`ZZ.mjs`, and the case-only stale-path removal). There are no new failures.
The new paired page and snapshot page have freshly recorded run hashes.
The implementation-stashed run fails both initialization-transfer fixtures.
The Sternhalma pending case is red with exactly its pinned two errors.

The full pending run also exposes an unrelated stale signature for
`ValueCommands`: it currently reports `missing_field` (`tracker`), while its
existing RED line expects `list_may_be_shared`. That is a type-checking error
before ownership runs. This work does not rewrite that fixture or its signature.


## 5. Review follow-up

Claude requested suspension, nonstandard reference and shape coverage. Ordinary
top-level values are already sync (`transparent-effects-proposal.md` §15.2 item
7; `check/bad/core/TopLevelValueSuspends` pins `must_not_suspend`). The review
prompted a further necessary guard: annotated `where` constants may be
recomputed when evidence changes (`static-dispatch-spike.md` §8.1). Both ends
of a transfer must have no solved evidence or identity parameters. Explicit
constraints are checked through Dispatch, including annotation-only extra
constraints. With this guard stashed, the generic pop and evidence-source
regressions change to accepted. A repeated evidence-parameterized consumer
invalidates the one-shot proof; excluding an evidence-parameterized source is
a conservative boundary of this rule, rather than a claim of real sharing in
its particular empty-list twin. Block version 6 invalidates the earlier
version 5 proof.

Additional class cases accept a branch and a chain of initializers, reject a
local function's read, and reject second reads appearing in a schema conversion
or markup hole. Known private names in those expressions lower through
`bir/Lower.zig`'s `resolveValue` to `.top`; schema namespace instructions name
schema declarations, which are ineligible sources. Private values cannot be
public dispatch members. The ownership memo's comment now states that the
current walk is serial and parallel walkers would need synchronization.

`allTriangleCoords` is private with one initialization read too. Its fresh
allocations therefore transfer alongside `centralHexagon`; the right operand
of concatenation is only read. No second ownership error is claimed for it.
