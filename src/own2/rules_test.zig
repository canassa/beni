//! The layering gate of the ownership checker v2 (`docs/design/ownership-v2.md`
//! §5), enforced by reading the sources of `src/own2/`, as `src/rules_test.zig`
//! enforces the whole tree's rule 5 (which this directory is subject to as
//! well: nothing here is excused from it).
//!
//! 1. **Layering.** Every `@import("X.zig")` of an `own2/` file names a file
//!    on a strictly lower layer of §5's table; a same-layer or higher import,
//!    or a file §5 does not list, fails naming both files. Every import
//!    outside `own2/` must be on §5's base-layer list (`base_imports`): the
//!    type modules for `Place` alone, `src/own/` never, `../beni.zig` never.
//!    A file's tests (after `const testing = std.testing;`) may also import
//!    the front end to lower source in-process (`test_imports`). Later
//!    slices cannot introduce a cycle or a back door without editing these
//!    tables, which the design owns.
//! 2. **Sizes.** Each file's production lines — up to its in-source tests —
//!    are within §5's line target.
//! 3. **Fences.** Only `Cell` defines `alias`; `Transfer`, `Calls`,
//!    `Demands` and `Rows` compare no name to a string literal unless the
//!    line is allowlisted with a reason; `Facts.Cause` declares exactly
//!    R-6.3's causes in its order.
//! 4. **Records.** Every table is an `Ids.Columns(T)`, which puts its `T` under
//!    `Ids.assertRecord`, so no table's record can pass 16 words (§4.1), and
//!    reads it through plain column slices: no other `MultiArrayList`, and
//!    no `items(.f)` but on the BIR's instructions.
//! 5. **Obligations.** Every production file's header says which of §2.14's
//!    obligations it keeps (`Obligations kept here:`), or that it keeps
//!    none.
//! 6. **Mutations.** Every rule `Mutate.zig` names to break has a site.
//! 7. **Registered.** A file with tests is named in `src/beni.zig`'s `own2`:
//!    an import alone compiles no test of the file into `unit_test`.

const std = @import("std");
const testing = std.testing;

const Entry = struct { file: []const u8, layer: u8, max_lines: u32 };

/// §5's table. A new file is added here by the slice that adds it.
const layers = [_]Entry{
    // The slot domain (#1685) replaced the shape files: a file it added has
    // its production lines with headroom as its target, set with it; a file
    // master had keeps its target.
    // §5 says 600; the lane-charging forms, named limits and charge targets
    // the first review asked for live here and push it past that, so the
    // table is amended to 700 with the slice's design commit.
    // 760 since S3b slice 4a: which copy of the source lanes a walk takes.
    // 900 since #1646 and the counters: `Columns`, a table with its columns hoisted.
    // 1 000 since #1646: `IdColumn`, a memo keyed by one dense id.
    // 1 120 since #1646: `Index` and `Interned`, open addressing over entry indices.
    // #1685: an account's first reads of the module tables (§4.1, #1714);
    // the chunks, the task queue and their ids, which nothing used, cut.
    .{ .file = "Ids.zig", .layer = 0, .max_lines = 1120 },
    .{ .file = "Counters.zig", .layer = 0, .max_lines = 580 },
    // Its lines are its table: a line for each rule broken, and its comment.
    .{ .file = "Mutate.zig", .layer = 0, .max_lines = 480 },
    .{ .file = "RowSets.zig", .layer = 0, .max_lines = 60 },
    .{ .file = "WordRun.zig", .layer = 0, .max_lines = 30 },
    .{ .file = "StepWord.zig", .layer = 0, .max_lines = 90 },
    // §5 says 1 100 since #1345: the fold targets and levels of a read on a
    // cycle, memoised per path.
    // 1 200 since #1253: one position, one name (`levelPaths`, `expandLevels`).
    // 1 210 since #1566: `equals` skips the pairs an earlier walk proved.
    // 1 220 since #1646: `path_index` reads its keys from the paths.
    .{ .file = "Place.zig", .layer = 1, .max_lines = 1220 },
    .{ .file = "Runs.zig", .layer = 1, .max_lines = 90 },
    // A leaf's base keys as sets shared with its kids' (#1714).
    .{ .file = "KeySets.zig", .layer = 1, .max_lines = 160 },
    // The tags and routes of a leaf set (#1714), split from `Leaves`.
    .{ .file = "Routes.zig", .layer = 1, .max_lines = 680 },
    // Whether route sets hold together, split from `Routes` (#1714).
    .{ .file = "Coexist.zig", .layer = 2, .max_lines = 240 },
    .{ .file = "Facts.zig", .layer = 2, .max_lines = 350 },
    // Holds read by their tags (#1714).
    .{ .file = "TagTree.zig", .layer = 2, .max_lines = 250 },
    // What a place graph says below a path, split from `Subtree` (#1714).
    .{ .file = "PlaceBelow.zig", .layer = 2, .max_lines = 70 },
    .{ .file = "LevelCycle.zig", .layer = 2, .max_lines = 35 },
    // One step of a position, the step relation and the index protocol the pairs and the indices share (#1963).
    .{ .file = "Steps.zig", .layer = 2, .max_lines = 190 },
    // A place graph's encoding and equality, split from `Place` (#1714).
    .{ .file = "PlaceIdentity.zig", .layer = 2, .max_lines = 190 },
    .{ .file = "Slots.zig", .layer = 2, .max_lines = 440 },
    .{ .file = "Replay.zig", .layer = 2, .max_lines = 130 },
    // One set of the folds above a slot, checked under runtime safety (§2.1, *One below*, #2377).
    .{ .file = "UpCheck.zig", .layer = 2, .max_lines = 35 },
    .{ .file = "SlotWords.zig", .layer = 2, .max_lines = 110 },
    // A contract's result trees, hash-consed by node (#1714, §2.10).
    .{ .file = "Trees.zig", .layer = 2, .max_lines = 200 },
    // The readers and the union of result trees, below the contracts (#1714).
    // A read's result slots as a column, for `ReadOff` and `Relation` (#1714).
    .{ .file = "PastPayload.zig", .layer = 3, .max_lines = 90 },
    .{ .file = "LevelTargets.zig", .layer = 3, .max_lines = 50 },
    .{ .file = "PathsTo.zig", .layer = 3, .max_lines = 70 },
    .{ .file = "Origin.zig", .layer = 3, .max_lines = 20 },
    .{ .file = "Dests.zig", .layer = 3, .max_lines = 200 },
    // A relative slot's text, below the contracts: `Needs` errors name it too (§2.10).
    .{ .file = "RelText.zig", .layer = 3, .max_lines = 50 },
    // The identity tree's one normal form, below `Contract` (#1714).
    .{ .file = "Normal.zig", .layer = 3, .max_lines = 40 },
    .{ .file = "Forest.zig", .layer = 3, .max_lines = 380 },
    // The mark of a field read in an effect tree (§2.10, R-4.8.5).
    .{ .file = "FieldMark.zig", .layer = 3, .max_lines = 75 },
    // Conditions, split from `Contract` (#1714).
    .{ .file = "Conds.zig", .layer = 3, .max_lines = 200 },
    // The answers occurrence (§2.11.3).
    .{ .file = "AnsOcc.zig", .layer = 4, .max_lines = 35 },
    // A read effect names its field (§2.10, *a read's fields*).
    .{ .file = "Contract.zig", .layer = 4, .max_lines = 805 },
    // The anchors of a read below a caller slot (§2.1, *One below*, #2359).
    .{ .file = "BelowAnchors.zig", .layer = 4, .max_lines = 60 },
    // A whole subtree held as a symbol (#1706): its readers, above `Slots`.
    .{ .file = "Subtree.zig", .layer = 4, .max_lines = 350 },
    // What an open arrival says at the `⟲`s above it (#2195).
    .{ .file = "LevelWide.zig", .layer = 4, .max_lines = 80 },
    // A route to each first arrival, through `PathsTo` (#2192).
    .{ .file = "StepsTo.zig", .layer = 4, .max_lines = 45 },
    // How large `below(p)` is, split from `Subtree` (#1714).
    .{ .file = "BelowSize.zig", .layer = 4, .max_lines = 80 },
    .{ .file = "Prepass.zig", .layer = 4, .max_lines = 600 },
    // A selection in its one spelling of a subtree (#1714).
    .{ .file = "Canon.zig", .layer = 5, .max_lines = 120 },
    // Split from `Relation` (#2195): a read at a caller slot.
    .{ .file = "ArriveAt.zig", .layer = 5, .max_lines = 60 },
    // A set met against a run of slots in one pass, for `Descent` (#1714).
    .{ .file = "MeetRun.zig", .layer = 5, .max_lines = 70 },
    // The environment rows are read in, split from `Rows` (#1752).
    .{ .file = "RowEnv.zig", .layer = 5, .max_lines = 150 },
    // Which declarations a comparison's walk covers, split from `Groups`.
    .{ .file = "ComparisonWalks.zig", .layer = 5, .max_lines = 30 },
    // The arrivals a need meets in the code a caller hands, split from `Needs` (§2.11.3).
    .{ .file = "NeedArrivals.zig", .layer = 5, .max_lines = 75 },
    // A plain arrival at a type variable's slot is open, checked (§2.1, *One below*, #2377).
    .{ .file = "VarOpen.zig", .layer = 5, .max_lines = 30 },
    .{ .file = "Regions.zig", .layer = 5, .max_lines = 450 },
    .{ .file = "ContractText.zig", .layer = 5, .max_lines = 160 },
    // `within`, split from `Contract` (#1991).
    .{ .file = "Within.zig", .layer = 5, .max_lines = 140 },
    // A value's leaf set (#1714): made with the value, read by `Relation`.
    .{ .file = "Leaves.zig", .layer = 5, .max_lines = 600 },
    .{ .file = "ValueTypes.zig", .layer = 5, .max_lines = 170 },
    // Worded contracts by declaration and places, one footprint a callee (#1714).
    .{ .file = "Worded.zig", .layer = 5, .max_lines = 60 },
    // A label applied to an `alt` of known codes, one virtual call each (§2.11.3, #2322).
    .{ .file = "AltCodes.zig", .layer = 5, .max_lines = 115 },
    // Where a hoisted read is bound (§2.8, the hoist rows).
    .{ .file = "HoistPlace.zig", .layer = 6, .max_lines = 95 },
    .{ .file = "Rows.zig", .layer = 6, .max_lines = 320 },
    .{ .file = "Value.zig", .layer = 6, .max_lines = 480 },
    // A code's summary lines, its called contracts' after it (#2028).
    .{ .file = "SummaryText.zig", .layer = 6, .max_lines = 35 },
    // §5 says 750 since #1214: a path's uses grouped for a filter, and a
    // child's range found by its one step.
    // #1685: a holder's deepest use; the pair ancestry split to `Ancestry`.
    .{ .file = "Liveness.zig", .layer = 6, .max_lines = 750 },
    // Compatibility for one pair of points, split from `Liveness` (#1685).
    .{ .file = "Ancestry.zig", .layer = 6, .max_lines = 130 },
    .{ .file = "Pairs.zig", .layer = 6, .max_lines = 215 },
    // A reference read by steps, by every route of a `⟲`, split from `Relation` (#2192).
    .{ .file = "RefRead.zig", .layer = 6, .max_lines = 90 },
    // What a callee's open arrival says at a caller's folds above it (#2223).
    .{ .file = "CallFolds.zig", .layer = 6, .max_lines = 150 },
    // A deep need read at the folds above its slot, split from `Needs` (§2.1, *One below*).
    .{ .file = "NeedFolds.zig", .layer = 6, .max_lines = 35 },
    // A `fed` answer through the known codes a code's labels run (#2395).
    .{ .file = "FedThrough.zig", .layer = 6, .max_lines = 150 },
    // Whether a prepend may answer its base's array, split from `Relation` (§2.3.4, #2325).
    .{ .file = "Recons.zig", .layer = 6, .max_lines = 135 },
    // What a known code keeps of what a label hands it (§2.11.3, *a need on a supply*, #2393).
    .{ .file = "KeepsNot.zig", .layer = 6, .max_lines = 110 },
    // A call's mixed condition instantiated once, for `PlainReach` (§2.9.1, #2418).
    .{ .file = "CondOnce.zig", .layer = 6, .max_lines = 50 },
    .{ .file = "Relation.zig", .layer = 7, .max_lines = 1300 },
    .{ .file = "Taken.zig", .layer = 7, .max_lines = 75 },
    .{ .file = "AnswerKeep.zig", .layer = 7, .max_lines = 90 },
    // What a known code's run keeps of an argument a later run is handed, split from `SelfFed` (#2367).
    .{ .file = "RunKeeps.zig", .layer = 7, .max_lines = 75 },
    .{ .file = "HeldBy.zig", .layer = 7, .max_lines = 50 },
    // The distinct check's entries and rounds' state, split from `Distinct` (#1714).
    .{ .file = "Entries.zig", .layer = 7, .max_lines = 400 },
    // The atoms a result holds open already, for the read-off (#1716).
    .{ .file = "Held.zig", .layer = 7, .max_lines = 70 },
    .{ .file = "SupplyKey.zig", .layer = 7, .max_lines = 55 },
    // A call's subtree of atoms read as the callee's node (#1714).
    .{ .file = "AtomGraft.zig", .layer = 7, .max_lines = 70 },
    // The entries' inline order by jump pointers, for `Chains` (#1714).
    .{ .file = "Jumps.zig", .layer = 7, .max_lines = 60 },
    // One walk of a value along several paths by route sets, below
    // `Distinct` (#1714, §2.11.2); `⟲` one of its shared steps, split
    // from `Routed` (#1714, §2.3.5 *a key's leaf*).
    .{ .file = "RouteWalk.zig", .layer = 8, .max_lines = 450 },
    // A selection's apart and plain occurrences, split from `Distinct` (#1714).
    .{ .file = "ApartPlain.zig", .layer = 8, .max_lines = 130 },
    // A write onto a caller's parameter stops there, its targets read off
    // the callee's tree (#1714, §2.11.2).
    .{ .file = "Graft.zig", .layer = 8, .max_lines = 520 },
    .{ .file = "OneSet.zig", .layer = 8, .max_lines = 40 },
    // A callee's tree and condition taken as the caller's at a call whose
    // arguments are its parameters whole (#1225, #1714, §2.10).
    .{ .file = "CallGraft.zig", .layer = 8, .max_lines = 170 },
    // A holder DAG's items under united route sets, for the descent (#1714).
    .{ .file = "DagRoutes.zig", .layer = 8, .max_lines = 170 },
    // A value's leaves at their slots, split from `Relation` (#1714).
    .{ .file = "Parts.zig", .layer = 8, .max_lines = 70 },
    // What the distinct check reads of its rounds, split from `Distinct` (#1714).
    .{ .file = "Chains.zig", .layer = 8, .max_lines = 80 },
    // A chain of calls handing one object on, split from `Relation` (#1714).
    .{ .file = "Ends.zig", .layer = 8, .max_lines = 40 },
    // A call's leaf's atoms, for the distinct check (#1714).
    .{ .file = "AtomSets.zig", .layer = 8, .max_lines = 240 },
    // Split from `Relation` and `Eval` (#1685): the walk reads leaves of
    // values, the distinct check reads a call's instantiation.
    // A cell's `◆` as an evaluation reads it, from `Eval` (#1729).
    .{ .file = "Cells.zig", .layer = 8, .max_lines = 150 },
    .{ .file = "CellEdit.zig", .layer = 8, .max_lines = 65 },
    // A label's answer handed back to it, and its `fed` occurrence (#1713).
    .{ .file = "Fed.zig", .layer = 8, .max_lines = 140 },

    // The sources a frame's escapes reach, for the read-off's `host` (#1744).
    .{ .file = "Host.zig", .layer = 8, .max_lines = 120 },
    // A callee's `fed` occurrence at a call, split from `Fed` (#1721).
    .{ .file = "FedCall.zig", .layer = 8, .max_lines = 105 },
    // A known code's run handed its own answer, its separation by induction (#1713).
    .{ .file = "SelfFed.zig", .layer = 8, .max_lines = 100 },
    // A label's answers read, and their occurrence decided (§2.11.3).
    .{ .file = "Answers.zig", .layer = 8, .max_lines = 190 },
    // An answers occurrence decided at a caller.
    .{ .file = "AnswerCall.zig", .layer = 8, .max_lines = 120 },
    // What a check's plain slots may hold, split from `Distinct`.
    .{ .file = "PlainReach.zig", .layer = 8, .max_lines = 120 },
    // An entry of the distinct check expanded, split from `Distinct`.
    .{ .file = "EntryExpand.zig", .layer = 8, .max_lines = 30 },
    // The module's services a walk reads, split from `Walk` (#1758).
    .{ .file = "WalkContext.zig", .layer = 8, .max_lines = 75 },
    // The labels a virtual call's supply comes through, outward, split
    // from `Eval` (#1758, #1760, #1721).
    .{ .file = "LabelChain.zig", .layer = 8, .max_lines = 145 },
    // What a traversal's supply says, below the labels' chain's readers.
    .{ .file = "Each.zig", .layer = 8, .max_lines = 120 },
    // A closure's captures in what holds it, beside `Routed` (#1772).
    .{ .file = "Captures.zig", .layer = 8, .max_lines = 55 },
    // A function value in a result: its called code (#2028).
    .{ .file = "Called.zig", .layer = 8, .max_lines = 70 },
    // A function value that is one closure of the frame through callees' results (#2395).
    .{ .file = "FnSite.zig", .layer = 8, .max_lines = 110 },
    // A construction over its base, split from `Walk` (#2028).
    .{ .file = "Construction.zig", .layer = 8, .max_lines = 65 },
    // A record update over its base and the frame's field events, split from `Walk` (§2.6, §2.7).
    // The kind of a slot, for `CallReq` (a list's storage beside a record's object).
    .{ .file = "Update.zig", .layer = 8, .max_lines = 280 },
    // A closure's field captures, read off the text (§2.11.4, R-5.4.6).
    .{ .file = "FieldCapture.zig", .layer = 8, .max_lines = 70 },
    // A record's fields read, in a contract's reads (§2.8, R-4.8.5).
    .{ .file = "FieldReads.zig", .layer = 8, .max_lines = 95 },
    // A demand says whether it is a cell operation (#1727).
    .{ .file = "Walk.zig", .layer = 9, .max_lines = 1240 },
    // A function value run by unknown code: the function objects that escape (#1773, #1775, #1776).
    .{ .file = "FnRun.zig", .layer = 9, .max_lines = 250 },
    // What carries a need, for `NeedLeaves` (§2.11.3).
    .{ .file = "NeedCarry.zig", .layer = 9, .max_lines = 85 },
    .{ .file = "AnswerRead.zig", .layer = 9, .max_lines = 40 },
    // One entry of many objects; an answer apart from nothing (#1710,
    // #1711); what an answer may hold (§2.9.2 step 7).
    .{ .file = "Distinct.zig", .layer = 9, .max_lines = 750 },
    .{ .file = "ReqKinds.zig", .layer = 9, .max_lines = 105 },
    // What a pending argument holds for its consumer, in the record pass (§2.8, R-4.8.5).
    .{ .file = "PendingArg.zig", .layer = 9, .max_lines = 70 },
    .{ .file = "MovedReq.zig", .layer = 9, .max_lines = 75 },
    // A call's writes projected by the walk, and a set written out (#1714).
    .{ .file = "Routed.zig", .layer = 9, .max_lines = 90 },
    // A virtual call's record, from `Eval` (#2166).
    .{ .file = "Virtual.zig", .layer = 9, .max_lines = 70 },
    // What a callee holds across a run of a known code it is handed (#1955).
    .{ .file = "Across.zig", .layer = 9, .max_lines = 60 },
    // A known code's capture written through a label it applies, split from `Closures` (#2395).
    .{ .file = "CaptureRuns.zig", .layer = 9, .max_lines = 100 },
    // What a cell callback's write-back makes escape, from `Eval` (#1729, #1955).
    .{ .file = "Stored.zig", .layer = 9, .max_lines = 65 },
    // A cell callback's label, and what it answers: a loan of the cell or
    // `modify`'s owned `.0` (#1977).
    .{ .file = "Loans.zig", .layer = 9, .max_lines = 135 },
    // The subtree symbol's read-off beside the passed-on labels (§2.3.1).
    // A closure's cell operations on its captures, at its creation (#1727).
    .{ .file = "Eval.zig", .layer = 10, .max_lines = 640 },
    // Demands judged once for their twins (#1714).
    .{ .file = "Twins.zig", .layer = 10, .max_lines = 90 },
    // What resolution reads of the leaves: base keys, the escape index (#1714).
    .{ .file = "Holders.zig", .layer = 10, .max_lines = 700 },
    // The holder index and its sweep, split from `Holders` (#1714): holds
    // listed once a holder, buckets by next use, the aggregated holders.
    // A holder's later uses, split from `Resolve` for the best-hold descent (#1714).
    // The hold that is asked is the written record, or another object (#2443).
    .{ .file = "Later.zig", .layer = 10, .max_lines = 190 },
    .{ .file = "Sweep.zig", .layer = 10, .max_lines = 720 },
    // The paths at which a hold holds a target, split from `Descent` (#1714).
    .{ .file = "HoldAt.zig", .layer = 10, .max_lines = 140 },
    // The pending operands by clock and key, split from the walk's copies (#1714).
    .{ .file = "Stack.zig", .layer = 10, .max_lines = 380 },
    // A write of a fold's accumulator, by its slot (§2.11.3).
    .{ .file = "FedWrite.zig", .layer = 10, .max_lines = 100 },
    // A callee's `req` at a call, read for a record's write and for a list's (§2.11.2 item 4, #1018).
    .{ .file = "CallReq.zig", .layer = 10, .max_lines = 60 },
    .{ .file = "ByStructure.zig", .layer = 10, .max_lines = 70 },
    // Resolve grew by the passed-on labels' supply judgement (§2.11.3).
    // A supply part judged by its known objects too (#1712).
    // The read-off, split from `Eval` (#1714).
    // Where the read-off puts what it describes, split from `ReadOff` (#1714).
    .{ .file = "Put.zig", .layer = 11, .max_lines = 170 },
    // The read-off's columns, split from `ReadOff` (§2.10, #2359).
    .{ .file = "ReadCols.zig", .layer = 11, .max_lines = 55 },
    // The memo of subtrees described once per place, split from `Put` (#2195).
    .{ .file = "PutMemo.zig", .layer = 11, .max_lines = 40 },
    // The stack of subtrees the read-off describes once per place, split from `Put` (#2197).
    .{ .file = "Building.zig", .layer = 11, .max_lines = 40 },
    // The best-hold descent over a holder DAG, below Resolve (#1714).
    .{ .file = "Descent.zig", .layer = 11, .max_lines = 330 },
    .{ .file = "Deliver.zig", .layer = 11, .max_lines = 300 },
    // A callee's hand-back is an escape too (#1709).
    .{ .file = "ClosureAnswers.zig", .layer = 11, .max_lines = 110 },
    .{ .file = "Closures.zig", .layer = 11, .max_lines = 140 },
    // A store that may hold one object twice escapes the cell's contents (#1984).
    .{ .file = "Contents.zig", .layer = 11, .max_lines = 140 },
    // A group's judgements kept across its rounds (§2.12, #1714).
    .{ .file = "Kept.zig", .layer = 11, .max_lines = 420 },
    // What the labels outward of a virtual call add to its demands and to
    // a passed-on label's supplies, from `Eval` and `ReadOff` (#1758, #1721).
    // A record's write reads a taken row's occurrences a second time (`ReqKinds`).
    .{ .file = "Outward.zig", .layer = 11, .max_lines = 97 },
    // A label's need published and discharged (§2.11.3).
    .{ .file = "Needs.zig", .layer = 11, .max_lines = 260 },
    // Where a closure with a need goes, split from `Needs` (§2.11.3).
    .{ .file = "NeedLeaves.zig", .layer = 11, .max_lines = 90 },
    .{ .file = "EntryHeld.zig", .layer = 11, .max_lines = 70 },
    // What a closure's creation asks of its writes, split from `Eval` (#2028).
    // A once closure's record write names its fields (R-4.8.2).
    .{ .file = "Once.zig", .layer = 11, .max_lines = 63 },
    // What a called code says of what its creation made (#2028).
    .{ .file = "Made.zig", .layer = 11, .max_lines = 55 },
    .{ .file = "SupplyCond.zig", .layer = 11, .max_lines = 90 },
    // A traversal's supply, derived from the walk (§2.11.3).
    .{ .file = "Traversal.zig", .layer = 11, .max_lines = 230 },
    // A supplied part judged, split from `Resolve` (§2.11.3, #2013).
    .{ .file = "LaterFunctions.zig", .layer = 11, .max_lines = 40 },
    .{ .file = "Supplied.zig", .layer = 11, .max_lines = 165 },
    // A row of a supply at a caller that names more (§2.1, #2172).
    .{ .file = "SplitRow.zig", .layer = 11, .max_lines = 80 },
    // A label's answer in another label's supply (§2.11.3, #2013).
    .{ .file = "SupplyAnswers.zig", .layer = 11, .max_lines = 70 },
    .{ .file = "ClosureRuns.zig", .layer = 12, .max_lines = 85 },
    .{ .file = "ReadOff.zig", .layer = 12, .max_lines = 1160 },
    .{ .file = "Resolve.zig", .layer = 12, .max_lines = 685 },
    // The conditions of a contract, split from `ReadOff` (#2028).
    .{ .file = "CondsOff.zig", .layer = 12, .max_lines = 120 },
    // A frame's write of what it handed a label: a need on the supply (§2.11.3, #2393).
    .{ .file = "HandedWrites.zig", .layer = 12, .max_lines = 175 },
    // Nested codes' captures, split from `Groups` (#2028).
    .{ .file = "CodeCaps.zig", .layer = 12, .max_lines = 90 },
    // A parameter annotated with a type variable, split from `Groups` (#2028).
    .{ .file = "TypeVarParam.zig", .layer = 12, .max_lines = 95 },
    // A group's codes solved on their own and its local cycles, split from `Groups` (§2.12, #2035).
    .{ .file = "Peel.zig", .layer = 12, .max_lines = 110 },
    // A module's codes and one declaration's answer, split from `Groups` (#1758).
    .{ .file = "Codes.zig", .layer = 12, .max_lines = 60 },
    .{ .file = "BlockWords.zig", .layer = 12, .max_lines = 70 },
    .{ .file = "Callees.zig", .layer = 12, .max_lines = 290 },
    // Evidence terms as function values (#1708).
    // Which types share one place graph (§2.1, *A family*).
    .{ .file = "Family.zig", .layer = 12, .max_lines = 260 },
    // The flag of the record pass (§2.11.5, R-8.6); a line's hoist rows outlive a round (§2.8).
    .{ .file = "Groups.zig", .layer = 13, .max_lines = 1910 },
    // A refused loan's text, split from `Message` (#1991).
    .{ .file = "LoanNote.zig", .layer = 13, .max_lines = 35 },
    // How a block names what is local to a module, split from `Block` (#1991).
    .{ .file = "BlockNames.zig", .layer = 13, .max_lines = 30 },
    // A contract's called contracts in a block (#2028).
    .{ .file = "BlockCalled.zig", .layer = 13, .max_lines = 35 },
    .{ .file = "BlockStep.zig", .layer = 13, .max_lines = 60 },
    .{ .file = "Block.zig", .layer = 14, .max_lines = 380 },
    // A hoisted read's line of the report (§2.8, the hoist rows).
    .{ .file = "Message.zig", .layer = 14, .max_lines = 295 },
    .{ .file = "Report.zig", .layer = 14, .max_lines = 150 },
    // The channel's record half: the accepted record writes and the reads to bind (§2.8, the emitter reads the rows).
    .{ .file = "Hoists.zig", .layer = 14, .max_lines = 200 },
    // The facade runs the list pass and the record pass of each module (§2.11.5, R-8.6), and fills both halves of the channel.
    .{ .file = "Ownership.zig", .layer = 15, .max_lines = 415 },
    .{ .file = "Enforce.zig", .layer = 16, .max_lines = 510 },
};

/// §5's base layer, the only files outside `own2/` a production line may
/// import: `bir/Bir`, `check/{TypeStore,Types,Walk,Dispatch,SchemaPlan,
/// EffectPlan,Scc}`, `resolve/{Interface,Graph}`, `parse/Ast`, `InternPool`,
/// `stamped`, plus the build's option modules. `only` names the files
/// allowed to import it (the type modules: "only `Place` reads type
/// children").
const BaseImport = struct { path: []const u8, only: ?[]const []const u8 = null };
const base_imports = [_]BaseImport{
    .{ .path = "../bir/Bir.zig" },
    // The type modules: `Place` and the `Groups` source and signature
    // adapters read type children (§5); `Enforce` builds their inputs.
    .{ .path = "../check/TypeStore.zig", .only = &.{ "Place.zig", "Groups.zig" } },
    .{ .path = "../check/Types.zig", .only = &.{ "Place.zig", "Groups.zig", "Enforce.zig" } },
    .{ .path = "../check/Walk.zig", .only = &.{"Place.zig"} },
    // The hook's session, driver and diagnostics: `Enforce` alone (§3.7).
    .{ .path = "../Session.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Driver.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Check.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Diagnostics.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Dispatch.zig" },
    .{ .path = "../check/Edges.zig" },
    .{ .path = "../check/SchemaPlan.zig" },
    .{ .path = "../check/EffectPlan.zig" },
    .{ .path = "../check/Scc.zig" },
    .{ .path = "../resolve/Interface.zig" },
    .{ .path = "../resolve/Graph.zig" },
    .{ .path = "../parse/Ast.zig" },
    .{ .path = "../InternPool.zig" },
    .{ .path = "../stamped.zig" },
    .{ .path = "std" },
    .{ .path = "ownership_options" },
    .{ .path = "diagnostic" },
};

/// What a file's TESTS may import besides the above: the front end, to
/// lower a source text to BIR in-process.
const test_imports = [_][]const u8{ "../lex/Tokenizer.zig", "../parse/Parse.zig", "../bir/Lower.zig" };

/// The files that compare no name to a string literal.
/// `std.mem`'s compares, by the start of their names: a run of words compared with
/// another, or searched, whatever the spelling.
const mem_compares = [_][]const u8{ "eql", "startsWith", "endsWith", "order", "lessThan", "indexOf", "lastIndexOf", "find", "containsAtLeast", "containsAtMost", "count", "cut", "trim", "split", "tokenize", "replace" };
/// Files whose runs of words are no slot's: an event log, a block's words, interned
/// runs, a place's name set, route sets, a caller's capture ids, a type's places, a site's codes.
const no_slot_words = [_][]const u8{ "Block.zig", "Callees.zig", "CodeCaps.zig", "Counters.zig", "Enforce.zig", "Kept.zig", "Ownership.zig", "PlaceIdentity.zig", "RouteWalk.zig", "Routes.zig", "RowSets.zig", "Runs.zig", "Twins.zig", "WordRun.zig" };
/// A line of a file with slots that compares something else, by a needle on the line.
const not_slots = [_]struct { file: []const u8, needle: []const u8 }{
    // Parameter, code, value and leaf ids in small lists.
    .{ .file = "Answers.zig", .needle = "ids, c.code" },
    .{ .file = "Closures.zig", .needle = "cl.value" },
    .{ .file = "Distinct.zig", .needle = "js.items, j" },
    .{ .file = "MovedReq.zig", .needle = "js.items, Contract.occParam(o)" },
    .{ .file = "Routed.zig", .needle = "js.items, x.j" },
    .{ .file = "Contract.zig", .needle = "js.items, e.j" },
    .{ .file = "Walk.zig", .needle = "items.items, c" },
    // A record's kid ranks, and a row's names: these read one name, no slot.
    .{ .file = "Update.zig", .needle = "ranks.items, st.kidWord()" },
    // An update's written field ranks, no slot words.
    .{ .file = "FieldMark.zig", .needle = "fields, st.payload" },
    // The field ranks that a frame reads of a capture, no slot words.
    .{ .file = "FieldCapture.zig", .needle = "ranks.items, rank" },
    // A call's argument instructions, no slot words.
    .{ .file = "PendingArg.zig", .needle = "cl.arg_insts, inst" },
    .{ .file = "Place.zig", .needle = "t.rowNames(row)" },
    // Tarjan's stack of places.
    .{ .file = "Place.zig", .needle = "stack.items" },
    // The canonical order's keys, which rank and name, and tell no slot from another's row.
    .{ .file = "Slots.zig", .needle = "t.keyOf(a)" },
    // Whole selections and runs compared as stored: equal words, the same facts, a miss
    // only says "changed".
    .{ .file = "Conds.zig", .needle = "a.sel, b.sel" },
    .{ .file = "Contract.zig", .needle = "t.occsOf(a)" },
    .{ .file = "Contract.zig", .needle = "t.readsOf(x.reads)" },
    // A `[*]` among a slot's words: one step, which no row stands for.
    .{ .file = "Each.zig", .needle = "Place.Step.elem.word()" },
    .{ .file = "Traversal.zig", .needle = "relWords(a.slot), elem" },
    // Two arrivals by their slots' ids: one answer run's, one frame's.
    .{ .file = "Traversal.zig", .needle = "src.?, pass.?" },
    // The keys are read only with no row among them: `SlotWords.meetsKey` reads the others (§2.1).
    .{ .file = "PlainReach.zig", .needle = "sliceAsBytes(key" },
    // A call and its marked selection, compared as stored: an equal run is the same condition, and a
    // miss only instantiates it again (#2418).
    .{ .file = "CondOnce.zig", .needle = "sliceAsBytes(key)" },
};
/// Files that read a tree's kid by a step word; `Trees.rowKid` or the reason it is not
/// needed is in each (§2.1, *One rule per reader*). `Forest.at`'s nothing is no reading:
/// `AtomGraft` and `Relation` read the row by `Forest.atSlot` and `rowKid` beside it.
const kid_readers = [_][]const u8{ "AtomGraft.zig", "Deliver.zig", "Descent.zig", "Eval.zig", "FieldMark.zig", "Forest.zig", "Graft.zig", "Later.zig", "ReadOff.zig", "Relation.zig", "Trees.zig", "Within.zig" };

fn lineAround(text: []const u8, at: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return text[start..end];
}

/// Which exceptions excused something: a file of `no_slot_words`, a line of `not_slots`.
const Excused = struct {
    files: [no_slot_words.len]bool = @splat(false),
    lines: [not_slots.len]bool = @splat(false),
};

fn notSlots(name: []const u8, line: []const u8, used: *Excused) bool {
    for (not_slots, 0..) |x, i| if (std.mem.eql(u8, x.file, name) and std.mem.indexOf(u8, line, x.needle) != null) {
        used.lines[i] = true;
        return true;
    };
    return false;
}

/// `text` with each call chain on one line: `std\n.mem\n.eql` is `std.mem.eql`.
fn joinChains(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_at: usize = 0;
    var first = true;
    while (lines.next()) |line| : (first = false) {
        const t = std.mem.trimStart(u8, line, " ");
        if (!first and t.len > 1 and t[0] == '.' and std.ascii.isAlphabetic(t[1]) and !isComment(out.items[line_at..])) {
            try out.appendSlice(gpa, t);
            continue;
        }
        if (!first) try out.append(gpa, '\n');
        line_at = out.items.len;
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// Where the parenthesis opened at `open` closes, or the end of `text`.
fn closeOf(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    for (text[open..], open..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return text.len;
}

/// Whether a call's argument at the start of `text` is a fixed key, an array by address
/// and never a slice of a run (`&a[0..2].*`).
fn fixedKey(text: []const u8) bool {
    if (text.len < 2 or text[0] != '&') return false;
    const arg = text[0 .. std.mem.indexOfScalar(u8, text, ',') orelse text.len];
    return std.mem.indexOf(u8, arg, "..") == null and std.mem.indexOf(u8, arg, ".*") == null;
}

fn refuse(bad: *usize, quiet: bool, comptime fmt: []const u8, args: anytype) void {
    if (quiet) bad.* += 1 else fail(bad, fmt, args);
}

/// Refuses, by syntax, a compare of `std.mem` on anything but bytes, reached by name, by an
/// alias of `std.mem` or of a compare, or by `@field`; `std.meta.eql`; a run of words as bytes;
/// a deep hash; and a hash map keyed by a slice of words. A file of `no_slot_words` and a line of
/// `not_slots` say why they may. A loop written by hand, a type alias of the key and a
/// `std.mem` reached through a struct pass: this catches the likely spellings and proves nothing (§2.1).
fn wordCompares(gpa: std.mem.Allocator, name: []const u8, raw: []const u8, bad: *usize, quiet: bool, used: *Excused) !void {
    for (no_slot_words, 0..) |f, i| if (std.mem.eql(u8, f, name)) {
        var seen: usize = 0;
        try wordScan(gpa, name, raw, &seen, true, used);
        used.files[i] = used.files[i] or seen != 0;
        return;
    };
    return wordScan(gpa, name, raw, bad, quiet, used);
}

fn wordScan(gpa: std.mem.Allocator, name: []const u8, raw: []const u8, bad: *usize, quiet: bool, used: *Excused) !void {
    const text = try joinChains(gpa, raw);
    defer gpa.free(text);
    for ([_][]const u8{ "std.mem;", "std.mem\n", "\").mem;", "\").mem\n", "std.meta.eql", "@field(std", "@field(mem", ".Deep" }) |needle| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, needle)) |at| {
            from = at + needle.len;
            if (!isComment(lineAround(text, at)) and !notSlots(name, lineAround(text, at), used)) refuse(bad, quiet, "{s}: `{s}` hides a compare of words from this rule: slots go through `SlotWords` (§2.1)", .{ name, needle });
        }
    }
    for ([_][]const u8{ "sliceAsBytes(", "asBytes(" }) |needle| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, needle)) |at| {
            from = at + 1;
            const line = lineAround(text, at);
            if (!isComment(line) and !notSlots(name, line, used)) refuse(bad, quiet, "{s}: words as bytes: slots go through `SlotWords` (§2.1)", .{name});
        }
    }
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "HashMap")) |at| {
        from = at + 1;
        const line = lineAround(text, at);
        if (!isComment(line) and std.mem.indexOf(u8, line, "[]const u32") != null and !notSlots(name, line, used)) refuse(bad, quiet, "{s}: a map keyed by a run of words: slots go through `SlotWords` (§2.1)", .{name});
    }
    from = 0;
    while (std.mem.indexOfPos(u8, text, from, "mem.")) |at| {
        from = at + 4;
        if (at != 0 and (std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_')) continue;
        var e = from;
        while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_')) e += 1;
        const known = for (mem_compares) |c| {
            if (std.mem.startsWith(u8, text[from..e], c)) break true;
        } else false;
        const line = lineAround(text, at);
        if (!known or isComment(line)) continue;
        if (e >= text.len or text[e] != '(') {
            refuse(bad, quiet, "{s}: an alias of `mem.{s}`: slots go through `SlotWords` (§2.1)", .{ name, text[from..e] });
            continue;
        }
        const comma = std.mem.indexOfScalarPos(u8, text, e, ',') orelse continue;
        const args = text[e..closeOf(text, e)];
        const cast = std.mem.indexOf(u8, args, "@ptrCast") != null;
        if ((std.mem.eql(u8, text[e + 1 .. comma], "u8") and !cast) or fixedKey(std.mem.trimStart(u8, text[comma + 1 ..], " ")) or notSlots(name, line, used)) continue;
        refuse(bad, quiet, "{s}: `mem.{s}` on {s}: slots go through `SlotWords` (§2.1)", .{ name, text[from..e], text[e + 1 .. comma] });
    }
}

fn isListed(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

const no_name_compare = [_][]const u8{ "Eval.zig", "Relation.zig", "Resolve.zig", "Rows.zig" };

/// A `std.mem.eql(u8, …, "literal")` a fenced file is allowed, by file and
/// a text of its line, with why. An entry nothing matches fails too.
const Allowed = struct { file: []const u8, needle: []const u8, why: []const u8 };
const literal_allowlist = [_]Allowed{};

/// R-6.3's causes in print order. `Facts.Cause` must declare exactly these.
const causes = [_][]const u8{
    "unknown",   "escaped",  "top_level", "captured_edit", "disjoint", "held_operand", "later_use",
    "alias",     "captured", "element",   "call",          "supply",   "need",         "limit",
    "exclusive", "once",     "payload",   "read_only",     "level",    "comparison",   "loan",
};

const test_marker = "\nconst testing = std.testing;";

const Source = struct { name: []const u8, text: []const u8 };

fn layerOf(name: []const u8) ?Entry {
    for (layers) |e| if (std.mem.eql(u8, e.file, name)) return e;
    return null;
}

fn readSources(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Source)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, "src/own2", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 22));
        errdefer gpa.free(text);
        try out.append(gpa, .{ .name = try gpa.dupe(u8, entry.name), .text = text });
    }
    std.mem.sort(Source, out.items, {}, struct {
        fn lessThan(_: void, a: Source, b: Source) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// The production part of a file: everything before its tests.
fn production(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, test_marker)) |at| text[0..at] else text;
}

fn lineCount(text: []const u8) u32 {
    const prod = production(text);
    return @intCast(std.mem.count(u8, prod, "\n") + @intFromBool(prod.len > 0 and prod[prod.len - 1] != '\n'));
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//");
}

/// Every `@import("…")` target of `text`, in order.
fn imports(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "@import(\"")) |at| {
        const start = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse break;
        from = end;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
        if (isComment(text[line_start..at])) continue;
        try out.append(gpa, text[start..end]);
    }
}

/// Why `file` may not import `target` (from its production lines, or its
/// tests when `in_tests`), or null when it may.
fn importVerdict(file: []const u8, target: []const u8, in_tests: bool) ?[]const u8 {
    const me = layerOf(file) orelse return "not in §5's table";
    if (std.mem.indexOf(u8, target, "own/") != null) return "v1 (src/own/) is frozen and no v2 file reads it";
    if (std.mem.indexOfScalar(u8, target, '/') == null and std.mem.endsWith(u8, target, ".zig")) {
        if (std.mem.eql(u8, target, "Counters.zig") or std.mem.eql(u8, target, "Mutate.zig")) return null;
        const other = layerOf(target) orelse return "not in §5's table";
        if (other.layer >= me.layer) return "imports go to strictly lower layers (§5)";
        return null;
    }
    for (base_imports) |b| {
        if (!std.mem.eql(u8, b.path, target)) continue;
        if (b.only) |only| {
            for (only) |o| if (std.mem.eql(u8, o, file)) return null;
            return "only Place and the Groups adapters read type children; only Enforce reads the session (§5)";
        }
        return null;
    }
    if (in_tests) {
        for (test_imports) |t| if (std.mem.eql(u8, t, target)) return null;
    }
    return "not on §5's base layer (own2/rules_test.zig `base_imports`)";
}

/// The identifiers declared by an `enum` body, in order.
fn enumMembers(gpa: std.mem.Allocator, text: []const u8, decl: []const u8, out: *std.ArrayList([]const u8)) !bool {
    const start = std.mem.indexOf(u8, text, decl) orelse return false;
    const open = std.mem.indexOfScalarPos(u8, text, start, '{') orelse return false;
    const close = std.mem.indexOfPos(u8, text, open, "\n};") orelse return false;
    var lines = std.mem.splitScalar(u8, text[open + 1 .. close], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len == 0 or isComment(line) or std.mem.startsWith(u8, line, "pub ") or std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "const ")) continue;
        if (!std.mem.endsWith(u8, line, ",")) continue;
        const name = line[0 .. line.len - 1];
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        try out.append(gpa, name);
    }
    return true;
}

fn fail(bad: *usize, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("src/own2/" ++ fmt ++ "\n", args);
    bad.* += 1;
}

test "own2 layering: every import points strictly down §5's table or onto its base layer" {
    const gpa = testing.allocator;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |s| {
            gpa.free(s.name);
            gpa.free(s.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, testing.io, &sources);
    try testing.expect(sources.items.len >= 3);
    var bad: usize = 0;
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(gpa);
    for (sources.items) |s| {
        if (std.mem.eql(u8, s.name, "rules_test.zig")) continue;
        const me = layerOf(s.name) orelse {
            fail(&bad, "{s}: not in §5's table (own2/rules_test.zig `layers`): a new file is added there by its slice", .{s.name});
            continue;
        };
        if (lineCount(s.text) > me.max_lines) fail(&bad, "{s}: {d} lines, over §5's target of {d}", .{ s.name, lineCount(s.text), me.max_lines });
        const prod = production(s.text);
        targets.clearRetainingCapacity();
        try imports(gpa, prod, &targets);
        for (targets.items) |t| if (importVerdict(s.name, t, false)) |why| fail(&bad, "{s} imports {s}: {s}", .{ s.name, t, why });
        targets.clearRetainingCapacity();
        try imports(gpa, s.text[prod.len..], &targets);
        for (targets.items) |t| if (importVerdict(s.name, t, true)) |why| fail(&bad, "{s} (tests) imports {s}: {s}", .{ s.name, t, why });
        if (std.mem.indexOf(u8, prod, "Obligations kept here:") == null) fail(&bad, "{s}: the header names no §2.14 obligation (`Obligations kept here:` …, or `none`)", .{s.name});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "own2 fences: alias, name comparisons, Cause order, records asserted" {
    const gpa = testing.allocator;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |s| {
            gpa.free(s.name);
            gpa.free(s.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, testing.io, &sources);
    var bad: usize = 0;
    var used: [literal_allowlist.len]bool = @splat(false);
    var exceptions: Excused = .{};
    var members: std.ArrayList([]const u8) = .empty;
    defer members.deinit(gpa);
    for (sources.items) |s| {
        if (std.mem.eql(u8, s.name, "rules_test.zig")) continue;
        // Only `Cell` defines `alias`.
        if (!std.mem.eql(u8, s.name, "Distinct.zig") and std.mem.indexOf(u8, s.text, "fn overlap(") != null) {
            fail(&bad, "{s} defines `overlap`: only Distinct.overlap relates leaves (§2.9.2)", .{s.name});
        }
        // The normal form's words are build-local (§3.5: this module's
        // place ids, union sides in id order): only `Summary` makes them
        // and only `Block` may spell them for a hash or a file.
        if (!std.mem.eql(u8, s.name, "Summary.zig") and !std.mem.eql(u8, s.name, "Block.zig") and std.mem.indexOf(u8, production(s.text), "normalize(") != null) {
            fail(&bad, "{s} calls `normalize`: the normal-form words are build-local and only Block may hash or publish them (§3.5)", .{s.name});
        }
        // Name comparisons in the fenced files.
        for (no_name_compare) |f| {
            if (!std.mem.eql(u8, s.name, f)) continue;
            var lines = std.mem.splitScalar(u8, s.text, '\n');
            var n: u32 = 0;
            while (lines.next()) |line| {
                n += 1;
                if (isComment(line)) continue;
                const at = std.mem.indexOf(u8, line, "std.mem.eql(u8") orelse continue;
                if (std.mem.indexOfScalarPos(u8, line, at, '"') == null) continue;
                var allowed = false;
                for (literal_allowlist, 0..) |a, i| {
                    if (std.mem.eql(u8, a.file, s.name) and std.mem.indexOf(u8, line, a.needle) != null) {
                        allowed = true;
                        used[i] = true;
                    }
                }
                if (!allowed) fail(&bad, "{s}:{d}: a name compared to a string literal in a fenced file (§5)", .{ s.name, n });
            }
        }
        // A slot's words are compared in `WordRun`/`SlotWords` alone (§2.1).
        try wordCompares(gpa, s.name, production(s.text), &bad, false, &exceptions);
        // A tree's kid by a caller's word: each of these files is decided, and a new one
        // decides too, by `rowKid` or by saying why an exact kid will do (§2.1).
        for ([_][]const u8{ ".kidAt(", "Forest.at(" }) |needle| if (std.mem.indexOf(u8, production(s.text), needle) != null and !isListed(&kid_readers, s.name)) {
            fail(&bad, "{s} reads a tree's kid: take `Trees.rowKid` too, or add it to `kid_readers` (§2.1)", .{s.name});
        };
        // `Facts.Cause` is exactly R-6.3's list, in its order.
        if (std.mem.eql(u8, s.name, "Facts.zig")) {
            members.clearRetainingCapacity();
            if (!try enumMembers(gpa, s.text, "pub const Cause = enum", &members)) {
                fail(&bad, "Facts.zig: `pub const Cause = enum` not found or not a plain member list", .{});
            } else if (members.items.len != causes.len) {
                fail(&bad, "Facts.zig: `Cause` has {d} members, R-6.3 has {d}", .{ members.items.len, causes.len });
            } else for (members.items, causes) |m, c| if (!std.mem.eql(u8, m, c)) {
                fail(&bad, "Facts.zig: `Cause` has `{s}` where R-6.3's order has `{s}`", .{ m, c });
            };
        }
        // Every table is an `Ids.Columns`, which asserts its record (§4.1: at
        // most 16 words) and keeps its columns as plain slices in step with
        // every growth: `MultiArrayList`'s `items(.f)` and `get(i)` recompute
        // every column's address per call, a third of the checker's cycles
        // under Zig's own backend. Only `Ids.Columns` holds one.
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, s.text, from, "MultiArrayList(")) |at| {
            from = at + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, s.text[0..at], '\n')) |nl| nl + 1 else 0;
            if (isComment(s.text[line_start..at])) continue;
            if (std.mem.eql(u8, s.name, "Ids.zig") and std.mem.startsWith(u8, s.text[at..], "MultiArrayList(T)")) continue;
            fail(&bad, "{s}: a `MultiArrayList` table: make it an `Ids.Columns` and read it through `col`", .{s.name});
        }
        // Only the BIR's instructions, another module's list, are read
        // through `items`; and only `Ids.Columns` touches its own `list`,
        // which a write past `col` would leave out of step.
        var lines = std.mem.splitScalar(u8, production(s.text), '\n');
        var n: u32 = 0;
        while (lines.next()) |line| {
            n += 1;
            if (isComment(line)) continue;
            if (!std.mem.eql(u8, s.name, "Ids.zig") and std.mem.indexOf(u8, line, ".list.") != null) {
                fail(&bad, "{s}:{d}: an `Ids.Columns`' `list` reached from outside `Ids.zig`: use its methods and `col`", .{ s.name, n });
            }
            if (std.mem.indexOf(u8, line, ".items(.") == null) continue;
            if (std.mem.indexOf(u8, line, "bir.insts.items(.") != null) continue;
            fail(&bad, "{s}:{d}: a column read through `items`: read the table's `col`", .{ s.name, n });
        }
    }
    for (not_slots, exceptions.lines) |x, u| if (!u) fail(&bad, "{s}: the exception `{s}` excuses nothing: remove it", .{ x.file, x.needle });
    for (no_slot_words, exceptions.files) |f, u| if (!u) fail(&bad, "{s}: `no_slot_words` excuses nothing here: remove it", .{f});
    for (literal_allowlist, used) |a, u| {
        if (!u) fail(&bad, "rules_test.zig: the allowlist entry for {s} (`{s}`) matches nothing: remove it", .{ a.file, a.needle });
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "a file with tests is registered, or its tests never run" {
    const gpa = testing.allocator;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |x| {
            gpa.free(x.name);
            gpa.free(x.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, testing.io, &sources);
    const root = try std.Io.Dir.cwd().readFileAlloc(testing.io, "src/beni.zig", gpa, .limited(1 << 22));
    defer gpa.free(root);
    var bad: usize = 0;
    for (sources.items) |x| {
        if (!std.mem.startsWith(u8, x.text, "test \"") and std.mem.indexOf(u8, x.text, "\ntest \"") == null and std.mem.indexOf(u8, x.text, "\ntest {") == null) continue;
        const named = try std.fmt.allocPrint(gpa, "@import(\"own2/{s}\")", .{x.name});
        defer gpa.free(named);
        if (std.mem.indexOf(u8, root, named) == null) fail(&bad, "{s} has tests, and `src/beni.zig`'s `own2` does not name it: `unit_test` never compiles them", .{x.name});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "every mutation has a site" {
    const gpa = testing.allocator;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |x| {
            gpa.free(x.name);
            gpa.free(x.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, testing.io, &sources);
    // Each file read once: a site's name, and how many sites it has.
    var sites: std.StringHashMapUnmanaged(u32) = .empty;
    defer sites.deinit(gpa);
    const mark = ".on(.";
    for (sources.items) |x| {
        if (std.mem.eql(u8, x.name, "rules_test.zig") or std.mem.eql(u8, x.name, "Mutate.zig")) continue;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, x.text, at, mark)) |i| {
            at = i + mark.len;
            const end = std.mem.indexOfScalarPos(u8, x.text, at, ')') orelse break;
            const got = try sites.getOrPutValue(gpa, x.text[at..end], 0);
            got.value_ptr.* += 1;
        }
    }
    var bad: usize = 0;
    for (std.enums.values(@import("Mutate.zig").Name)) |m| {
        const name = @tagName(m);
        if (m == .none or std.mem.startsWith(u8, name, "word_")) continue;
        const n = sites.get(name) orelse 0;
        if (n == 0) fail(&bad, "mutation {s}: no site (`src/own2/Mutate.zig`)", .{name});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "the layering table has each file once and every layer below the next" {
    for (layers, 0..) |a, i| {
        for (layers[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.file, b.file));
        if (i > 0) try testing.expect(layers[i - 1].layer <= a.layer);
    }
    try testing.expectEqual(@as(usize, 177), layers.len);
    try testing.expectEqual(@as(usize, 21), causes.len);
}

test "the import verdict refuses back doors and accepts the base layer" {
    try testing.expect(importVerdict("Slots.zig", "../beni.zig", false) != null);
    try testing.expect(importVerdict("Slots.zig", "../beni.zig", true) != null);
    try testing.expect(importVerdict("Slots.zig", "../own/Ownership.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../check/TypeKeys.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../check/Module.zig", false) != null);
    try testing.expect(importVerdict("Slots.zig", "../check/TypeStore.zig", false) != null);
    try testing.expect(importVerdict("Place.zig", "../check/TypeStore.zig", false) == null);
    try testing.expect(importVerdict("Prepass.zig", "../check/Scc.zig", false) == null);
    try testing.expect(importVerdict("Prepass.zig", "../bir/Lower.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../bir/Lower.zig", true) == null);
    try testing.expect(importVerdict("Slots.zig", "Ids.zig", false) == null);
    try testing.expect(importVerdict("Ids.zig", "Slots.zig", false) != null);
    try testing.expect(importVerdict("Slots.zig", "Facts.zig", false) != null);
    try testing.expect(importVerdict("Shape.zig", "Nowhere.zig", false) != null);
}

test "a plain compare of words is refused in each spelling the rule knows" {
    const refused = [_][]const u8{
        "const mem = std.mem;\nfn f(a: []const u32) bool { return mem.startsWith(u32, a, a); }\n",
        "fn f(a: []const u32) ?usize { return std.mem.indexOfDiff(u32, a, a); }\n",
        "fn f(a: []const u32) std.math.Order { return std.mem.order(u32, a, a); }\n",
        "const same = std.mem.eql;\n",
        "const m = @import(\"std\").mem;\n",
        "fn f(a: []const u32) bool { return std.mem.endsWith(u32, a, a); }\n",
        "fn f(a: []const u32) bool { return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(a)); }\n",
        "fn f(a: []const u32) bool { return std.mem.eql(Step, a, a); }\n",
        "fn f(a: []const u32) bool { return std.meta.eql(a, a); }\n",
        "fn f(a: []const u32) bool { return std.mem.eql(u8, @ptrCast(a), @ptrCast(a)); }\n",
        "fn f(a: []const u32) bool { return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(a)); }\n",
        "fn f(a: []const u32) ?[]const u32 { return std.mem.cutPrefix(u32, a, a); }\n",
        "fn f(a: []const u32) ?[]const u32 { return std.mem.cutSuffix(u32, a, a); }\n",
        "fn f(a: []const u32) void { _ = std.mem.cut(u32, a, a); }\n",
        "const eq = @field(std.mem, \"eql\");\n",
        "fn f(a: []const u32) bool { return std.mem.eql(u32, &a[0..2].*, &a[0..2].*); }\n",
        "fn f(h: anytype, a: []const u32) void { std.hash.autoHashStrat(h, a, .Deep); }\n",
        "fn f(a: []const u32) bool { return std\n    .mem\n    .eql(u32, a, a); }\n",
        "const M = std.ArrayHashMap([]const u32, u32, Ctx, true);\n",
    };
    var used: Excused = .{};
    for (refused) |text| {
        var bad: usize = 0;
        try wordCompares(testing.allocator, "Probe.zig", text, &bad, true, &used);
        try testing.expect(bad != 0);
    }
    var ok: usize = 0;
    try wordCompares(testing.allocator, "Probe.zig", "fn f(x: [2]u32) bool { return std.mem.eql(u32, &x, &x) or std.mem.eql(u8, \"a\", \"b\"); }\nconst A = std.mem.Allocator;\n", &ok, true, &used);
    try testing.expectEqual(@as(usize, 0), ok);
}

test "the enum member reader is exact: extras, order and words inside words fail" {
    const gpa = testing.allocator;
    var members: std.ArrayList([]const u8) = .empty;
    defer members.deinit(gpa);
    const text =
        \\pub const Cause = enum(u8) {
        \\    unknown,
        \\    // a comment
        \\    escaped,
        \\    pub fn x() void {}
        \\    unknown_extra,
        \\};
        \\const other = 1;
    ;
    try testing.expect(try enumMembers(gpa, text, "pub const Cause = enum", &members));
    try testing.expectEqual(@as(usize, 3), members.items.len);
    try testing.expectEqualStrings("unknown_extra", members.items[2]);
}
