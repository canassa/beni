# 143 — Precision of v3 on real programs: the refusals, and three fixes

*Research report, 2026-11-15. The ownership checker v3 (`--ownership=v3`, `src/own3/`,
`ownership-v3-kernel.md`) refuses some safe writes in real programs. This report lists every v3 refusal
in the real programs (the real-writes ledger, the apps of the corpus and the benches, `tests/corpus/run/`
and `core/`), checks each one with the in-place oracle, groups them by cause, and fixes the three causes
that a change of the checker alone can fix soundly. Each fix has a corpus fixture that is refused before
and accepted after, a live twin that stays refused, and a paragraph of the kernel.*

---

## 1. Result

- **Three causes fixed**, with no trusted row added:
  1. **Each location of an escaping answer is its own query** (`escapeAnswer`, kernel §8). One set of
     answers in work, of 24 places, served every location of the answer of a function whose answer
     escapes. With a wide message type the set filled, and the rest of the answer was read as lost:
     every argument of the call escaped. It is why the model of Conduit's `updateWith` escaped, not
     `Hosted.mapJob` (issue #2508, item 3).
  2. **A send asks nothing of the sender** (kernel §6 rule 13). The message is never `update`'s own,
     so no write rests on the sender giving it up; what it sends escapes at the runtime's default. A
     refused send line stopped every write of its module and was a compile error.
  3. **The fresh answers of a callback over aliased arguments are apart** (kernel §4.4). Where the
     arguments hold one cell at two places, a summary entry fed by an answer was `twice`, also when the
     answer holds no cell that the holder handed on.
- **Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1
  judges, v3 accepted 287 and refused 20; it now accepts **289** and refuses **18**. Read line by line
  (the script now matches a v3 line by its text where one position has several, §5), it accepted 292
  and refused 15, and accepts **296** and refuses **11**. Of all v3 lines of the 32 real roots, 303 of 339
  were accepted and **317** are. No line went from accepted to refused.
- **Conduit**: 24 of its 40 v3 lines were accepted, and **38** are. Its modules `Home` and `ProfilePage`
  publish their writes. The two lines left come from a message (§4).
- **No fault from these changes** in any sweep or in the corpus under the four legs (§7), and none in the new generator,
  `answers-sends.mjs`, of 54 programs aimed at the three fixes, whose 15 newly accepted programs are all
  `dead` twins.
- **On the branch's head** (rebased onto reports 142 and 144, which judge records too): the ledger goes from 286 to
  294 accepted, and Conduit's `Main`, which passed its budget there, is judged to the end: 231 of its 278
  lines accepted, 147 of 160 before (§5). No line of the ownership roots went from accepted to refused.
  By the script's match by position, the real writes were 287 before records were judged, are 274 at the
  head and 280 with these fixes; of the 13 records cost, the four of Conduit come back, and §5 lists the
  other nine with their causes (#2532).
- **The scan of an answer's map** reads the other map once for each location asked (`AnswersAt`, kernel
  §8): asking each location of an answer on its own made that scan the square of the layout's lookups.
- **Speed**: within ±2 % on the corpus and on report 138's shapes; +10 to +15 % on the worst shape
  found for §3.1, which reaches the same budget as before (§6).
- **One fault found on the branch, not from these changes**: at report 142's head, `ShowAndBranches`
  (`browser/dom/`, `browser/tea/`) traps and differs in place: a `Show` keyed by identity misses an
  in-place record update (#2530).

## 2. The inventory

Each refusal was checked by hand and with the in-place leg forced: a build of the program in which every
write v3 refused is done in place anyway (a compiler with the channel's refusal dropped, not committed).
A program whose output did not change is a candidate safe write; a program whose output changed has at
least one write that must stay refused.

### 2.1 The real-writes ledger and the apps

The 32 real roots of the ledger had 36 refused v3 lines. `core/` had none, and none of `NotesApp`, the
static site pages (`browser/prerender/`, all accepted) and the other examples.

| Cause | Lines | Where | Safe | This report |
|---|---:|---|---|---|
| a send whose message holds cells the sender does not own | 12 | `conduit` `Home` 135:9, `ProfilePage` 164:9 | yes | fixed (§3.2) |
| the answer of `updateWith`'s message function read as lost (24 answers in work) | 2 | `conduit` `Main` 257:5, `Article.0.errors`, `Profile.1.errors` | yes | fixed (§3.1) |
| a model location whose source is the message | 3 | `conduit` `Main` 257:5 (`Home…feed…errors`, `Profile…feed…errors`), `todo/page` 454:5 | yes in these programs | left: #2508 item 2 |
| a function in a list called (validators) | 6 | `bench/corpus` `FormValidation` 128:9, 212:11 to 216:11 | yes | left: #2501 item 1 |
| `Dict.update`'s function edits the value | 1 | `FormValidation` 276:17 | yes | left: #2501 item 5 |
| `Tea`'s table (`Hosted.compare` as evidence, its folds) | 12 | `platforms/browser-tea` | — | out of scope (`browser-tea`), #2508 item 1 |

The 3 pages of `tests/corpus/browser/inline/` that v3 refuses are the same causes: `FunctionElements` and
`ReturnedValidator` (a function in a list), and `TotalCallBranchOwnership` (the arms of an `if` in a hole
of markup, read in the order the lowering evaluates them).

### 2.2 The corpus

Of the 1 655 programs of `corpus.mjs`, v3 refused 345 before. Forced in place, 236 of them print another
output: each holds a write that must stay refused. The other 109 are candidates, by cause:

| Cause (the first refusal of each program) | Programs | This report |
|---|---:|---|
| a send (`tea/`: `DebouncedSearch`, `HttpCancel`, `HttpProgress`, `RespondSettlesEachChunk`) | 4 | fixed (§3.2) |
| a callback's answers over an argument with one list twice (`SanitiserAnswersApart`, one of its three writes) | 1 | fixed in part (§3.3) |
| a `Ref.update` or `Ref.modify` function edits the cell's contents, which are `outside` (kernel §3.1; `tea/BallMachine` among them) | 13 | left: #2521 |
| the answer of a function parameter written: v2's *needs* (`Sanitiser*NeedApart`, `NeedAcrossModules`, `LevelCallerNeedApart`, `LabelKeepsApart`, `AnswerWholeApart`, `AltCodes`) | 12 | left |
| a value no rule follows: a function in a list or answered by a call, a family or a row the call map cannot name (`inline/FunctionElements`, `inline/ReturnedValidator`, `ClosureTower`, `Sanitiser*ClosureApart`, `EtaChainApart`, `EtaWideTupleApart`, `Family*Apart`, `Row{Chain,OwnWord}Apart`) | 11 | left: #2501 item 1 for the functions |
| a read after the write through a row, a deep level or a family (`SanitiserRow*`, `LevelResult*`, `FamilyApart`, `LabelRoundsCopied`, `inline/TotalCallBranchOwnership`) | 11 | left |
| a function that writes its parameter goes where no contract follows it, at a type variable or a row (`SanitiserRow*CallerApart`, `OpenTupleLevelApart`, `HandedWriterApart`, `SuppliedFunctionApart`, `FunctionResultApart`, `NonRegularMatchRelease`) | 10 | left |
| a fold's or a traversal's answer, or a value handed back (`FoldKeepsAnswerApart`, `HandedBackApart`, `TraversalApart`, `ForwardedLabelApart`, `CallbackAnswerPending`, `AnswerHandedOnApart`, `LevelCallerSupplyApart`, `FoldStoredApart`, `RefinementFeedbackRefused`) | 9 | left |
| a model location that the `dom` lowering's root holds (`tea/`: `DefectReleasesHost`, `LatestTagger`, `LetMarkupHandler`, `ListenerOrder`, `NavigatePush`, `PointerInput`, `WebSocketDirect`, `WebSocketLifetime`) | 8 | out of scope (the `dom` lowering) |
| the message of `update` (`tea/Conduit*Errors`, four, and `OwnedCommandSend`) | 5 | left: #2508 item 2 |
| `Dict.update`'s function edits the value (`tea/`: `DictFoldLeft`, `DictFoldRight`, `FoldRight`, `SubscriptionTapAppend`, `SubscriptionTapFold`) | 5 | left: #2501 item 5 |
| two parts of one list pattern (`SplitSingletonRest`, `SanitiserWideDistinctApart`, `PatternStoredBackApart`, `SplitLocalLoop`, `PassedTupleRowApart`) | 5 | left: #2522 |
| a closure that writes what it captured, run once (`JoinedClosureExclusive*`, three, `OnceExclusiveArms`, `ClosureSlotHolderApart`) | 5 | left |
| an escape that v1's tests write on purpose (`EtaReduceHostValue`, `ListSanitiserHiddenHolder*`, two, `SanitiserAnswerLeft`) | 4 | left |
| a write of a top-level list or of `Dict.empty` (`LetHelperJoinedMethod`, `PhantomAliasUnifiesByExpansion`, `SanitiserEmptyValue`, `tea/InitializationTransfer`) | 4 | not safe in general: a top-level value is every reader's |
| two runs of one callback, one name (`CallbackPairFresh`, `WideCallbackFresh`) | 2 | left |
| **total** | **109** | |

## 3. The fixes

### 3.1 Each location of an escaping answer is its own query

**Cause.** Where a holder lets the answer of a function escape (`Fn.ans_escapes`: a cell's
`update`, `Cmd.map`'s function lost in `Hosted.mapJob`), `escapeAnswer` asks what the answer can hold,
location by location, and lets it escape. It kept one `SrcState` for all the locations, and its set of
answers in work (`seen`, 24 places) is the set of one query. `updateWith`'s message function answers a
`Main.Msg`, of 138 locations in Conduit: after 24 the set was full, and each later location was the lost
answer, `outside` and every argument of the call, the page model among them. So the page's `errors`
escaped where `updateWith` was called, and no location of the model was `own`.

**Rule.** Each location is a query of its own. A set of answers in work stops an answer that comes back
to itself; two locations of one answer are not that. The answers are the ones a query of each location
alone gives, which is what a narrow answer always got. Kernel §8 (the limits) says so.

**Why it is sound.** The union of the queries is the union of what each location can hold, and no
query ends earlier than before. A shared set could also skip a result entry for a second location with
another suffix, so the new queries can only find more cells.

**Fixture.** `browser/tea/SubPageWideMessage`: `updateWith` over a page message of 32 constructors;
`++` extends the page's errors in place. Refused before (`entry … model#Article.0.errors`), accepted
after. Twin: `SubPageWideMessageLive`, whose message function captures the errors: refused.

### 3.2 A send asks nothing of the sender

**Cause.** A call of the runtime's `send` made a demand on each cell of the message, v1's rule: the
sender gives the message up, so `update` may own it. Kernel rule 13 says the message is never `update`'s
own, so the demand guards no write. But its refusal was a line like a write's: a send of a top-level
list, of a list read after the send, or of what a schema worker parsed made the module publish no write
and was a compile error. Conduit's `Home` sends `CompletedFeedLoad (Result.map (Article.list …) …)`,
whose articles come from the API.

**Rule.** The send's test now says only whether the function is handed the message `free`; its line is
accepted, on the entry rule where the cells are not the sender's own (`finishDemands`). A walk that gave
up still accepts nothing.

**Why it is sound.** No rule reads a send line's verdict but the line itself; `free` keeps its test. What
the sender hands `send` escapes where the function goes to the runtime's default (`defaultParams`), and a
function that writes a cell after it sent it is refused there (`Fn.rewrites`): the blind-6 fault
`top-rewrite-send.live` is now refused by that rule instead of by the send line.

**Fixture.** `browser/tea/SendHeldList`: a command's body sends a top-level list, and `update` pushes a
list of the model in place. Refused before (`send <constructor …>: unknown`), accepted after. Twin:
`SendHeldListLive`, whose body pushes the list after it sent it: refused.

### 3.3 The fresh answers of a callback over aliased arguments

**Cause.** A callee's contract is written for arguments that hold each cell once. Where they do not, the
caller cannot take its claims (`argsApart`), and `apply` made `twice` every summary entry fed by two
sources or by an answer. `List.map [ a, a ] λ_ → [ 9 ]` answers a new list on each run, yet its elements
were `twice`, and a write of each was refused.

**Rule.** An answer makes the entry `twice` only where it can hold a cell the holder handed on
(`SrcState.handed`: a cell reached through a parameter's supply, a lost answer, or the frame's own
function's answer).

**Why it is sound.** The duplicate is a cell of the arguments. An answer reaches one only through what
the holder hands the function (a supply), through a lost answer (every argument in sight), or through the
frame's own function. Every other source of an answer is a cell its run made, which no other run holds; a
captured cell, which makes the entry `twice` already; or a cell outside the frame, which no write accepts.
The test of two sources (`sources > 1`) and of a parameter's own duplicates (`dup`) are unchanged.

**Fixture.** `run/FreshAnswersOfAliased`. Twin: `run/FreshAnswersOfAliasedLive` (the callback answers the
list it is handed): refused.

## 4. What is left

- **The message** (3 real writes, 5 corpus pages). A list that `update` keeps from a message is never its
  own. Winning it back needs facts of the platform: that a command's message reaches `update` once, and
  what `Cmd.map`'s and `Html.map`'s functions are handed. These are the owner's deferred decision #2508.
- **A function in a list or answered by a call** (6 real writes, 2 pages). A contract on a function at a
  location of data. Owner's decision #2501 item 1.
- **`Dict.update`** (1 real write, 5 pages). Needs a row on `focus`, which changes v2's verdicts, so a
  column of words only v3 reads. Owner's decision #2501 item 5.
- **A cell's contents** (11 corpus programs). A scope change of the kernel (§0): #2521.
- **Two parts of one list pattern** (5 corpus programs): #2522.
- The other synthetic shapes of §2.2 are v1's and v2's tests of their own designs (needs, labels,
  families, rows); no real program is refused for them.

## 5. The real-program precision table

| Measure | Before (`23ab068c89`) | After |
|---|---:|---|
| ledger, v1's 308 writes, by position (the script of report 138) | 287 accepted, 20 refused, 1 no line | 289, 18, 1 |
| ledger, matched by text where one position has several | 292, 15, 1 | 296, 11, 1 |
| all v3 lines of the 32 real roots | 303 of 339 | 317 of 339 |
| Conduit's v3 lines | 24 of 40 | 38 of 40 |
| a line accepted before, refused after | — | none |

The script change (`bench/ownership-v2-review.mjs`): the entry makes one line for each model location at
one position, and the script read every v1 line there as refused when any v3 line there was. It now
takes the v3 line with the same text when there is one.

**On the branch's head.** Reports 142 and 144 landed while this work ran: v3 now judges record updates
too. The fixes were rebased onto `d2964ad9eb`. The real writes at the three points:

| Measure | `23ab068c89` (before records) | `d2964ad9eb` (head) | head + this report |
|---|---:|---:|---:|
| ledger, v1's 308 writes, matched by position | 287 accepted, 20 refused, 1 no line | 274, 23, 11 | 280, 25, 3 |
| ledger, matched by text | 292, 15, 1 | 286, 11, 11 | 294, 11, 3 |
| all v3 lines of the 32 real roots | 303 of 339 | 1 286 of 1 359 | 1 370 of 1 477 |
| Conduit's v3 lines | 24 of 40 | 147 of 160, `Main` past its budget | 231 of 278, `Main` judged |
| a line accepted before, refused after (all ownership roots) | — | — | none |

The 13 writes lost between `23ab068c89` and the head, by cause (#2532):

| Writes | Cause | With this report |
|---|---|---|
| Conduit `Main` 231:41, 234:60 (two), 237:47 | no line: `Main` passes its budget in `changeRouteTo` (6.8 million units) once records are judged; the lost answers of §3.1 hold every argument in sight, and the model is a record of many lists | won back |
| `platforms/browser` `Gpu.Make` 889:15, 1094:7 | no line: `checkedIn` and `writeTexture` pass their budgets with records judged (a platform module authorises no write anyway) | lost |
| `bench/todomvc` `NoEditing`, `NoRouting`, `NoStorage`, `Sandbox` (`entry … model.todos`) | the list line is accepted, but a record line at its position is refused: `model.todos[*].completed=`, an element record of the model's list, is not `update`'s own; the refusal stops the module's writes | lost |
| `examples/sternhalma` `Main` 101:5, 114:13; `core` `Markdown` 1271:22 (`call List.foldl …`) | the list line is accepted, but the fold's function is refused at its position: it can answer one cell at two places. `{ Record.copy cell \| occupant = … }` shares `cell`'s field records, and `List.set` puts the copy over `cell`; the checker cannot see that the old element left the list, so `cells[*].coord=` is `twice`. Safe in Sternhalma, but winning it back needs a fact that `List.set` drops the element it replaces, for record slots: a design question of the record checker | lost |

With records judged, `Main` is walked to the end, its 118 more lines are judged one by one, and 47 of
the 278 are refused, among them the two of §4 and record writes of the model that reports 142 and 144
leave (`entry … model#Login.0.form=` and the like).

## 6. Speed

ReleaseFast, LLVM, `--jobs=1`, base `23ab068c89` against the fixes before the rebase (§7), on one machine, each program
run in turn with both compilers and the least time kept. The machine was shared and loaded; the sweeps
of §7 were paused for the measures.

**The corpus** (`bench/ownership-v2-review.mjs --checkers=v3`, v3's own time from `--self-profile`):

| Roots | Base | After | Change |
|---|---:|---:|---:|
| the 32 real roots (3 runs, two passes) | 747.4 and 744.0 ms | 732.6 and 731.4 ms | −2 % |
| all 2 322 ownership roots (1 run, two passes, in both orders) | 32 337.5 and 32 033.1 ms | 32 210.1 and 32 126.4 ms | 0 % |

**Shapes** (`check --no-cache`, 5 to 9 runs each; the first four are report 138 §5's, the others aim at
§3.1, whose answers are now asked location by location):

| Shape | Base | After | Change | Verdict, both |
|---|---:|---:|---:|---|
| 30 `f p = p` over nested pairs of 4 096 lists | 33.5 ms | 34.3 ms | +2 % | accepted |
| 30 functions, each a list of 45 calls of a function over nested pairs of 2 048 lists | 334.0 ms | 331.9 ms | −1 % | a declaration's budget |
| a record of 9 000 fields | 15.3 ms | 15.4 ms | +1 % | accepted |
| 30 `Ref.update cell keep` of nested pairs of 4 096 lists | 14.5 ms | 14.3 ms | −1 % | accepted |
| 30 calls of a holder that hands a function nested pairs of 4 096 lists in a `Ref.update` | 24.5 ms | 27.3 to 28.2 ms | +11 to +15 % | a declaration's budget |
| 30 calls of the same holder with a constructor | 191.2 ms | 192.9 ms | +1 % | the module's budget |

The fifth shape is the worst found. Each location of an escaping answer of 4 096 locations is now a
query, and each query scans the answer's map: about the square of the layout, counted (`scanUnits`), so
the declaration reaches its budget at the same place as before. The first version of §3.1 took 68.7 ms
there (+162 %): `answersAt` looked up both maps of the pair for each entry of the scan. The scan now reads
the map the other way once for the location asked (`AnswersAt`, kernel §8), with the same answers: the
v3 dumps of all 2 322 ownership roots are the same with and without it.

**On the branch's head** (report 142's `ef3098f82e` against the rebased commits, the same method):

| Measure | `ef3098f82e` | Rebased | Change |
|---|---:|---:|---:|
| the 32 real roots (3 runs, two passes, least) | 1 233.0 ms | 1 230.7 ms | 0 % |
| all 2 323 ownership roots (1 run, two passes, least) | 45 612.9 ms | 46 325.0 ms | +1.6 % |
| Conduit (5 runs, two passes) | 129.9 to 131.0 ms, `Main` past its budget | 130.4 to 130.6 ms, `Main` judged | 0 % |
| the six shapes above | — | — | −1 % to +2 %, and +10 % for the holder of the fifth row |

## 7. Soundness evidence

**Every sweep, every fault folder and the corpus, under the four legs** (`run.mjs --mode=both`: plain, v3
with `--sanitize-lists` and its identity trap, v3 with `--lists-in-place`, and release plain against
release in place), on the compiler of the three fixes before the rebase (§7, end), and the fault folders
and the last two reruns on the same with the scan of §6, whose v3 dumps of every ownership root are the
same:

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `corpus` | 1655 | 1248 | 341 | 1 | 1 | 64 (60 BOTHFAIL ip=BOTHFAIL, 1 TIMEOUT ip=SAME, 3 PLAINFAIL) |
| `as` | 54 | 19 | 35 | 0 | 0 | 0 |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | 0 |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | 0 |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | 0 |
| `blind2` | 1202 | 502 | 700 | 0 | 0 | 0 |
| `blind3` | 417 | 160 | 257 | 0 | 0 | 0 |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | 0 |
| `blind4b` | 6596 | 1229 | 5365 | 2 | 0 | 0 |
| `blind5c` | 226 | 81 | 143 | 2 | 0 | 0 |
| `blind5d` | 1234 | 456 | 778 | 0 | 0 | 0 |
| `blind6e` | 238 | 93 | 138 | 0 | 0 | 7 (7 PLAINFAIL) |
| `blind7f` | 960 | 404 | 556 | 0 | 0 | 0 |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | 0 |
| `blind9h` | 3213 | 852 | 2361 | 0 | 0 | 0 |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 (114 PLAINFAIL) |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 (18 TIMEOUT) |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | 0 |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | 0 |
| `folds-callbacks` | 30300 | 5392 | 24908 | 0 | 0 | 0 |
| `function-values` | 1960 | 304 | 1656 | 0 | 0 | 0 |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | 0 |
| `recursive-levels` | 16131 | 4139 | 11990 | 0 | 0 | 2 (1 TIMEOUT, 1 SAME ip=SAME rip=TIMEOUT-plain) |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | 0 |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | 0 |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | 0 |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | 0 |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | 0 |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | 0 |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | 0 |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | 0 |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | 0 |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 (2 TIMEOUT) |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | 0 |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | 0 |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 (4 TIMEOUT) |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | 0 |
| `fx` | 4 | 2 | 2 | 0 | 0 | 0 |
| `fx2` | 2 | 1 | 1 | 0 | 0 | 0 |
| **total** | **84431** | **18636** | **65568** | **15** | **1** | **211** |

The one fault counted is the corpus's `run/ListSanitiserTrieHolder`, whose platform's words lie on
purpose: it is the sanitiser's own test, and its golden is the trap (report 140 §4); in place it prints
the same. *Other* is what the runner cannot judge, as in reports 140 and 141: programs that do not build
plain (`PLAINFAIL`: the generators' pages that the platforms do not compile, and three corpus fixtures on
test platforms), programs that fail in both builds on purpose (`BOTHFAIL`), and plain runs past the
runner's 20 s on a loaded machine (`TIMEOUT plain`: the DAGs of `bounded-walk`, `blind7f-faults` and
`bounded-walk-faults`, whose v3 verdicts are the base's, checked one by one; the two of
`recursive-levels` were run again: `REFUSED` and `SAME`). `TailModConsMerge` passed the 20 s under the
sanitiser, in place `SAME`, as in report 140.

Against report 140's table (an earlier base), the sweeps accept 38 more programs (`aliased-arguments`
+33, `blind6e` +3, `answers-beside` +2), all `dead` twins; the corpus accepts 4 more (§2.2); no count of
`SAME` fell.

**The generator of the new shapes**, `bench/ownership-sweeps/answers-sends.mjs` (54 programs, §1): every
`live` twin refused, 19 `dead` twins accepted and the same on all four legs, of which 15 the base refused.

**The review** wrote 704 programs more (§8).

**Rebased** onto `d2964ad9eb` (reports 142 and 144, records written in place), the combination was
checked again: the v3 dumps of all 2 331 ownership roots, head against rebased, lose no accepted line
and win 460 (Conduit's six copies 74 each, the rest the pages and programs of §2.2 and §3). Under the
four legs on the rebased compiler: the corpus as it now is (1 671 programs: 1 194 `SAME`, 457 `REFUSED`,
1 `LIMIT`, 3 `TRAP`), `answers-sends.mjs` (19 `SAME`, 35 `REFUSED`), report 142's `records.mjs`
(1 876: 353 `SAME`, 1 523 `REFUSED`), the three sweeps whose verdicts these fixes moved
(`aliased-arguments` 1 216 `SAME`, 3 944 `REFUSED`; `answers-beside` 79, 161; `blind6e` 91, 140, 7
`PLAINFAIL`) and the review's 704 programs (the same verdicts as before the rebase, one `SAME` of
`Ref.update` now refused by a record write): no fault from these changes. Of the three traps, one is
`ListSanitiserTrieHolder` (above); the other two are `browser/dom/ShowAndBranches` and
`browser/tea/ShowAndBranches`, which trap and differ in place on the head's own compiler too, and were
`SAME` before records were written in place: a `Show` keyed by identity misses an in-place record update
(#2530, out of this report's scope: the `dom` lowering). The other sweeps were not run again on the
combination; before the rebase no verdict of theirs moved (their `SAME` counts are report 140's).

## 8. The review

One fresh reader had the diff of `src/own3/` and of the kernel, not this report, and was asked for a
program that the new rules accept and that is unsafe in place. It wrote 704 programs in eleven families
and ran each through `run.mjs --mode=both` on the compiler of the three fixes. **It found no fault**: every
program was `SAME` or `REFUSED`.

| Family | Programs | SAME | REFUSED | Did not build |
|---|---:|---:|---:|---:|
| a send, then a write of what it sent: `send` reached through a captured closure, a record, a tuple, `List.map`, `Maybe.map`, a fold, recursive helpers with and without `Time.sleep`, a partial application, an `if`, an alias chain; the list in a record, a tuple, a `Maybe`, a list of lists; written by `set`, a helper, a callback, a spawned fiber; `update` sending lists of the model eight ways | 79 | 0 | 79 | 0 |
| a function of the program that takes a `Browser.Send` and keeps or writes the message | 9 | 0 | 9 | 0 |
| the body reached through wrappers (a record field, a `Maybe`, a `Dict`, a `Ref`, `Cmd.map`, `afterRender`, a relay, a function that runs the body twice, a factory, a fiber) | 22 | 1 | 21 | 0 |
| a write before the send, the order of the arguments | 13 | 0 | 13 | 0 |
| `Cmd.map` over a wide message, `Ref.update` and `Ref.modify` of a wide record, the answer holding the frame's list at a late or an early location, through a helper, a partial application, an `if`, a field, a `case`, a captured function, the frame's own function | 45 | 1 | 44 | 0 |
| callbacks over one list at two places (`List.map`, over pairs, `indexedMap`, `filterMap`, a hand-written map, a fold, …) answering 23 kinds of value (`[]`, a literal, `copy`, a top-level list, `take`, `drop`, `x ++ []`, `filter`, `reverse`, `sort`, `map id`, a spread, `concat`, `head`, a list in a `Ref`, `Dict.values`, `slice`, an `if` that picks), then a write and a read of the original | 464 | 182 | 262 | 20 |
| further callees (evidence, a callee that caches `g`'s answer, `map2`, `foldr`, `concatMap`, `Dict.map`, `Maybe.map`, `sortBy`) | 27 | 5 | 21 | 1 |
| `answers-sends.mjs` | 54 | 19 | 35 | 0 |

Of the 182 `SAME` callbacks over aliased arguments, 156 are newly accepted, and every callback that
answers the list it is handed, or a captured list, is still refused.

It noted one point, which is answered here. A send line is now accepted whatever refused it, but a limit,
so a body that writes a list after it sent it is refused only where the function meets the runtime's
default (`Fn.rewrites`, kernel §6 rule 2), and a change that weakened that rule would no longer be caught
by the send. That is the design: by rule 13 the send line guarded no write, and every route the reader
tried, and `blind6e-faults/top-rewrite-send.live`, is refused by `rewrites`.

## 9. Reproduce

```sh
node bench/ownership-sweeps/answers-sends.mjs <dir>/as
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/as
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
```

The forced in-place compiler of §2 drops the refusal in `src/own3/Enforce.zig` (`channel.add(…, false, …)`
and no diagnostic); it is not in the commits.
