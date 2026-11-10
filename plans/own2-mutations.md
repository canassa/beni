# The mutation table of the ownership checker v2

Written by `zig build test-own2-mutations` (`tests/own2-mutations.mjs`) from the mutants of
`src/own2/Mutate.zig`. Each line is one rule broken on purpose, built and run against the selection:
`run/Sanitiser*`, `ownership/`, the `own2` unit tests. A mutant the selection does not kill is a
candidate, and runs the corpus as the gates run it: unfiltered, with the parity net, the stale check and
core's parity (the column *the net*). `tests/corpus/run/ChildProcessRun.beni` and `ChildProcessCancelled.beni` are left out of it, the
fixtures of #2053, since a failed fixture stops its kind before the stale check.

**Result, 172 mutations:** 121 killed (11 of them *blanket*: more than half the selection failed), 10
crash, 3 v1 only, 6 stale, 32 survive. *Since #2276's pins:* `within_always` is killed by the `.v2-short` passes of
`ownership/ShortCandidates` and `BottomCycle` (`--only=within_always`, 31 s), so 122 killed and 31 survive;
`inst_memo_under_cut` is gone (#2299): no program reaches `instAt`'s cut (instrumented, 0 cuts over the corpus,
the pending fixtures and core), so the cut is a panic under safety and the mutant has no meaning; 171 mutations.
Measured on master `2f7bf74216`; the seven mutants of what `Pairs` changed on `fa2b611b38`; all 40
candidates, the net included, on `fe90ea2da0`; the nine mutants of a family (#2214) on that branch.
*Since #2344:* the three mutants of a fold handed its own answer (`SelfFed`, `Distinct.reqOn`) are killed
(`--only=self_fed_slot_off,self_fed_keeps_ok,self_fed_answer_free`, 222 s), so 174 mutations, 125 killed.
*Since #2354:* `below_join_one_name` is killed by `run/SanitiserFamilyJoinBelow` (`--only=below_join_one_name`, 96 s).
*Since #2325:* `recons_never` and `recons_front_any` (when a prepend may answer its base's array, `Recons.zig`) are killed by
`run/SanitiserPrependFrontHeld`, the first also by `ownership/Prepend` and `PrependFresh` (`--only=recons_never,recons_front_any`, 205 s).
*Since #2418:* `mixed_memo_off` (a call's mixed condition instantiated again at each asking, `CondOnce.zig`) is a cost-only
mutant: it is killed by `ownership/StateChain`, which reaches `ownership_summary_size` under it (`--only=mixed_memo_off`, 261 s).
*Since #1018 (S5a):* the eight mutants of the record pass (§2.11.5, *Two passes*) are killed, each by an `ownership/` fixture's
`.v2.ownership` golden, `record_pass_lists` also by `run/SanitiserRowKept` and `run/SanitiserRowKeptApart`
(`--only=update_fresh_site,update_no_events,update_reads_off,list_req_whole,record_refusal_lost,cell_record_edit`, 845 s;
`--only=record_pass_lists`, 354 s; `--only=record_pass_off`, 280 s). Each control is green.
`pending_arg_whole` (an argument that waits for its call holds its whole value, `PendingArg.zig`) is killed by
`ownership/RecordWriteOnlyCall` (`--only=pending_arg_whole`, 239 s, control green).
`field_reads_whole` (a callee's read of one field is said as a read of the record whole, `FieldReads.zig`) is killed by
`ownership/RecordCalleeFields` and `RecordDemands` (`--only=field_reads_whole`, 255 s, control green).
`field_capture_whole` (a closure that reads only fields of a captured record holds the record whole, `FieldCapture.zig`) is
killed by `ownership/RecordFieldCapture`, `RecordDemands` and one more (`--only=field_capture_whole`, 255 s, control green).
`write_fields_all` (a callee's write of a record names no field, `FieldReads.zig`) and `once_read_hoists` (a read of a
written field after a once closure is made is a hoist, `Later.zig`) are each killed by `ownership/RecordWriteFields` and
`RecordOnce` (`--only=write_fields_all,once_read_hoists`, 396 s, control green). A first run had both as survivors: the two
fixtures had a `.v2.ownership` and no `.v2` file, and a `.v2.ownership` is read only beside a `.v2`.
`record_req_whole` (a record's write at a call relies on the callee's whole `req`, `CallReq.zig`) is killed by
`ownership/RecordBesideLists` and `RecordFoldPush`; `list_req_whole`, whose code changed with it, is still killed by
`RecordFoldPush` (`--only=record_req_whole,list_req_whole`, 457 s, control green).
`record_supply_whole` (a record's write reads a taken row's container once, `Outward.zig`) and `record_deep_whole` (a deep
occurrence stays every object below its slot for a record's write, `ReqKinds.zig`) are each killed by
`ownership/RecordBesideListsSupplied`. The two mutants of the kind reading, whose code moved to `ReqKinds.zig`, are still
killed (`--only=record_supply_whole,record_deep_whole,record_req_whole,list_req_whole`, 446 s, control green).
`callee_write_whole` (a later callee's write below any field is a whole use of the old record, `Later.zig`) is killed by
`ownership/RecordCalleeWritesBelow`; `field_reads_whole`, the read half, is killed by that fixture too
(`--only=callee_write_whole,field_reads_whole`, 307 s, control green).
*Since #2443:* `sibling_holds_by_field` (an update reads every hold by the written record's fields, `Later.zig`) and
`field_read_by_point` (a read of a field no path names is a `whole` use that a filter tells by its point, `Update.zig`,
`Later.zig`) are each killed by `ownership/RecordSiblingHolds`. Four mutants of the code around them are still killed
(`--only=sibling_holds_by_field,field_read_by_point,update_no_events,once_read_hoists,callee_write_whole,field_reads_whole`,
645 s, control green).
`full_update_reads` (an update that keeps no field makes an event, `Update.zig`) is killed by
`ownership/RecordFullUpdateLater`; `field_read_by_point` is also killed by the new `ownership/RecordFieldAfterWrite`
(`--only=full_update_reads,field_read_by_point,sibling_holds_by_field`, 361 s, control green).

- *killed*: a fixture or a unit test failed. A cell is a count and the first in name order.
- *blanket*: killed, by so much that the fixture says little of the rule.
- *crash*: the checker panicked on core while the checked core was built, so a safety check of its own
  fired and no fixture ran. That is a pin by an assert, not by a program.
- *v1 only*: only parity with v1 failed, on the net.
- *stale*: only STALE lines failed: a difference `ownership-v2-known.txt` excuses is gone. **A real pin and a
  weak one:** it says a verdict moved, not that a program went wrong, and it goes when the known list goes.
- *SURVIVED*: the net exits 0, so nothing pins the rule. `tests/own2-mutations-survivors.txt` has each,
  with its class and issue.

**Classes of a survivor.** *dead*: no program reaches the rule. *redundant*: another rule answers every
program so far, which is a measurement and no proof. *equivalent*: the rule changes no answer anything
reads. *open*: no finding yet. The classes come from the review of #2190's probes, in
`~/.cache/beni-agents/review-2190/`, and from mine.


An `ownership/` kill is a golden verdict compared through the parity path, whatever the `-Dno-v2-parity`
switch says, since those goldens are v1's text. A `run/Sanitiser*` kill is a fixture's own: its
`.sanitize-lists-v2-refuses` list, its site list, or a run that trapped or printed another answer.
`run/SanitiserAnswerHandedOn` is the first killer of many mutants: much rests on it.

| Mutation | For | Breaks | Result | Class | run/Sanitiser | ownership/ | unit | the net |
|---|---|---|---|---|---|---|---|---|
| `unnamed_step_empty` | O1 O10 G4 | a step no place names reads as nothing, not as what it lies inside or `⊤` | killed | | 2: SanitiserCastTwin (SanitisedRefusalDiffers), … | 7: CastAcross [node] (OwnershipV2Differs), … | 0 | |
| `walker_project_scalar` | O1 O10 | `Walker.project` gives a scalar for a step a place cannot name | killed | | 4: SanitiserFoldFunction (SanitisedRefusalDiffers), … | 10: OneListTwoLevels (OwnershipV2Differs), … | 0 | |
| `walker_row_scalar` | O1 O10 | `Walker.project` gives a scalar for a row step of a tuple or constructor | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `recons_never` | O1 | a prepend never answers its base's array (`Recons.may`) | killed | | SanitiserPrependFrontHeld (ProgramFailed) | 2: Prepend (OwnershipV2Differs), … | 0 | |
| `recons_front_any` | O1 | a prepend whose front is a call never answers its base's array, whatever the call hands back | killed | | SanitiserPrependFrontHeld (SanitisedRefusalDiffers) | 0 | 0 | |
| `mixed_memo_off` | cost (§4.1) | a call's mixed condition is instantiated again at each asking, not once (#2418) | killed | | 0 | StateChain (OwnershipV2Limit) | 0 | |
| `update_fresh_site` | O7 | a record update's value is a new object, not its base's | killed | | 0 | 4: RecordDemands (OwnershipV2Differs), … | 0 | |
| `update_no_events` | O7 | an update asks no field event: no later update and no read of a written field is found | killed | | 0 | RecordDemands (OwnershipV2Differs) | 0 | |
| `update_reads_off` | O7 | a field read or an update of a parameter's record is no read of its object in the contract | killed | | 0 | RecordDemands (OwnershipV2Differs) | 0 | |
| `list_req_whole` | §2.11.2 item 4 | a list's write relies on the callee's whole `req`, a record's pairs with it | killed | | 0 | RecordFoldPush (OwnershipV2Differs) | 0 | |
| `record_pass_lists` | R-8.6 (§2.11.5, *Two passes*) | a refusal that only the record pass has stays a list line, so a list verdict reads the record pass | killed | | 3: SanitiserRowKept (SanitisedRefusalDiffers), … | 3: RecordContentsEntry [browser-tea+everywhere] (OwnershipV2Differs), … | 0 | |
| `record_pass_off` | §2.11.5, *Two passes* | the record pass never runs, so no update has a line and a block says that both passes agree | killed | | 0 | 10: HolderRestApart (OwnershipV2Differs), … | 0 | |
| `record_refusal_lost` | §2.11.5 | a refusal that only the record pass has, on a demand that is no record demand, is dropped | killed | | 0 | RecordPassOnly (OwnershipV2Differs) | 0 | |
| `cell_record_edit` | §2.11.5, §2.13.7 | a cell callback's update of the contents' own record is an edit in place, as a list's is | killed | | 0 | RecordCellEdit (OwnershipV2Differs) | 0 | |
| `pending_arg_whole` | §2.8, R-4.8.5 | an argument that waits for its call holds its whole value, whatever the callee reads | killed | | 0 | RecordWriteOnlyCall (OwnershipV2Differs) | 0 | |
| `field_reads_whole` | §2.8, R-4.8.5 | a callee's read of one field of a parameter's record is said as a read of the record whole | killed | | 0 | 2: RecordCalleeFields (OwnershipV2Differs), … | 0 | |
| `field_capture_whole` | §2.11.4, R-5.4.6 | a closure that reads only fields of a captured record holds the record whole | killed | | 0 | 3: RecordDemands (OwnershipV2Differs), … | 0 | |
| `write_fields_all` | §2.10, R-4.8.2 | a callee's write of a record names no field, so a caller reads it as every field | killed | | 0 | 2: RecordOnce (OwnershipV2Differs), … | 0 | |
| `once_read_hoists` | §2.8, R-4.8.2 | a read of a written field after a once closure is made is a hoist, as after an update | killed | | 0 | 2: RecordOnce (OwnershipV2Differs), … | 0 | |
| `record_req_whole` | §2.11.2 item 4 | a record's write at a call relies on the callee's whole `req`, also where only two lists' storage meets | killed | | 0 | 3: RecordBesideLists (OwnershipV2Differs), … | 0 | |
| `record_supply_whole` | §2.11.2 item 4 | a record's write reads the taken row's container occurrences once, as a list's write does | killed | | 0 | RecordBesideListsSupplied (OwnershipV2Differs) | 0 | |
| `record_deep_whole` | §2.11.2 item 4 | for a record's write a deep occurrence stays every object at and below its slot | killed | | 0 | RecordBesideListsSupplied (OwnershipV2Differs) | 0 | |
| `callee_write_whole` | §2.8, R-4.8.5 | a later callee's write below any field is a whole use of the old record, also below an untouched field | killed | | 0 | RecordCalleeWritesBelow (OwnershipV2Differs) | 0 | |
| `sibling_holds_by_field` | §2.8, #2443 | an update reads every hold of its judgement by the written record's fields, also a hold that is another object | killed | | 0 | RecordSiblingHolds (OwnershipV2Differs) | 0 | |
| `field_read_by_point` | §2.7, #2443 | a read of a field no path names is a `whole` use, and an update's filter tells it by its point | killed | | 0 | 2: RecordFieldAfterWrite (OwnershipV2Differs), … | 0 | |
| `full_update_reads` | §2.7, R-4.8.2 | an update that keeps no field makes an event, as an update that reads its record does | killed | | 0 | RecordFullUpdateLater (OwnershipV2Differs) | 0 | |
| `call_escape_off` | O1 O8 | a callee's escapes do not escape at the call | killed | | 11: SanitiserAnswerLeft (SanitisedRefusalDiffers), … | 9: BranchEscapes (OwnershipV2Differs), … | 0 | |
| `escape_shallow` | O8 | a callee's escape is read at the slot, not deep | killed | | 5: SanitiserAnswerLeft (SanitisedRefusalDiffers), … | 6: BranchEscapes (OwnershipV2Differs), … | 0 | |
| `pessimistic_no_escape` | O1 | the pessimistic contract escapes no argument | killed | | SanitiserEscapedResult (ProgramFailed) | page] (OwnershipV2Differs) | 0 | |
| `pessimistic_res_empty` | O1 O10 | the pessimistic contract's result holds nothing | killed | | 0 | 5: RecordCopy (OwnershipV2Differs), … | 0 | |
| `payload_read_off` | O10 F | both arms of `PastPayload` off: a read past a payload stays empty | killed |  | SanitiserFamilyRead (SanitisedRefusalDiffers) | 0 | 0 |  |
| `payload_prefix_off` | O10 | `PastPayload.prefix` off: a read past a payload finds no `var` | elsewhere |  | 0 | 0 | 0 | 2 own, 1 parity |
| `empty_past_arrival` | O10 | an empty read past a call's arrival or an arrival's suffix stays empty | killed |  | SanitiserFamilyRead (SanitisedRefusalDiffers) | 0 | 0 |  |
| `family_split_heads` | O3 Lemma T | a family's heads have a payload each, not one | elsewhere |  | 0 | 0 | 0 | 2 own |
| `family_permuted_own` | O3 Lemma T | an edge that permutes the parameters counts as own, so such a cycle is no family | killed |  | SanitiserFamily (SanitisedRefusalDiffers) | 0 | 0 |  |
| `payload_cross_child` | O1 Lemma T | a leaf of a context stays the payload's child, so its step crosses | killed |  | 21: SanitiserFamily (BuildFailed), … | 15: ApproximateAliasLevels (UnexpectedExitCode), … | 0 |  |
| `payload_no_steps` | O1 Lemma T | the payload has no steps | killed |  | 6: SanitiserFamilyBase (SanitisedRefusalDiffers), … | 7: ApproximateAliasLevels (OwnershipV2Differs), … | 0 |  |
| `payload_level_walked` | O3 | a payload's level on a literal is walked, not read whole | killed |  | 2: SanitiserFamilyCall (GoldenMismatch), … | PolyRecCps (OwnershipV2Differs) | 0 |  |
| `family_exit_off` | O1 O3 | a value that leaves a family for a concrete type arrives by its slot alone | killed |  | 2: SanitiserFamilyRead (SanitisedRefusalDiffers), … | 0 | 0 |  |
| `origin_leaves_off` | O10 | `Origin.leaves` off: a `⊤` lies inside nothing | killed | | 2: SanitiserFoldFunction (SanitisedRefusalDiffers), … | 0 | 0 | |
| `inst_no_contract_empty` | O10 | `instAt` with no contract reads nothing, not `⊤` | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `inst_live_no_contract_empty` | O10 | `instAt` in a group with no contract reads nothing | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `inst_below_no_contract_empty` | O10 | `instBelow` with no contract reads nothing | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `arrival_no_arg_empty` | O10 | an arrival of a parameter past the arguments reads nothing | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `arrival_no_label_empty` | O10 | an answer of no mapped label reads nothing | stale | | 0 | 0 | 0 | 4 STALE |
| `known_answer_empty` | O10 | a known code's answer at an unnamed slot reads nothing | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `lend_empty` | O10 | a loan of nothing is nothing, not `⊤` | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `targets_empty_accepted` | O10 G4 | a demand with no target is not refused `unknown` | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `walker_no_call_use` | O2 | a call's argument is no use of the local | killed | | 31: SanitiserCallbackAnswers (ProgramFailed), … | 136: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `live_holders_off` | O2 H1 | no live local is a witness | killed | | 40: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 199: AliasGroupCall (OwnershipV2Differs), … | 0 | |
| `aggregated_off` | O2 G6 | the aggregated holders are not read (a fast path's other half) | killed | | 2: SanitiserClosureSlotHolder (GoldenMismatch), … | 24: ApartPaths (OwnershipV2Differs), … | 0 | |
| `stack_judge_off` | O2 | `Stack.judge` off: no pending operand is a witness | killed | | 2: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 12: Binders (OwnershipV2Differs), … | 0 | |
| `stack_agg_off` | O2 G6 | `Stack.judge` skips the target's selection through other leaves | SURVIVED | open | 0 | 0 | 0 | 0 |
| `other_operands_off` | O2 | a write is not judged against the call's other operands | killed | | 3: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 13: EarlierRunSpread (OwnershipV2Differs), … | 0 | |
| `operands_judged_off` | O2 G6 | `Operands.judged` off: a call's aggregated operands are empty | killed | | 0 | 7: Disjoint (OwnershipV2Differs), … | 0 | |
| `regions_never_compatible` | O2 | no two points are in compatible regions | killed | | 2: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 12: Binders (OwnershipV2Differs), … | 4: own2.Regions.test.arms of one case are incompatible, everything else compatible; guards and ranges, … | |
| `later_footprint_none` | O2 | a call's use reads nothing of what its footprint says | blanket | | 43: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 241: AliasGroupCall (OwnershipV2Differs), … | 0 | |
| `descent_off` | O2 G6 | `Descent.descend` off: no hold is visited | killed | | 0 | 19: CallFieldStep (OwnershipV2Differs), … | 0 | |
| `hold_at_off` | O2 | `HoldAt.holdsAt` off: a holder holds nothing | blanket | | 43: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 247: AliasGroupCall (OwnershipV2Differs), … | 0 | |
| `sweep_add_off` | O2 | `Sweep.Live.add` off: no local is live | blanket | | 43: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 247: AliasGroupCall (OwnershipV2Differs), … | 0 | |
| `read_at_shallow` | O3 | `Subtree.readAt`: an open arrival is read at the slot only, a `var` not deep | killed | | SanitiserFoldedType (SanitisedRefusalDiffers) | 9: HostedEntryHostSettle [browser+everywhere] (OwnershipV2Differs), … | 0 | |
| `within_always` | O3 O5 | `Within.within` always true: a candidate is never validated | killed | | 0 | 2: BottomCycle (OwnershipV2ShortDiffers), … | 0 | |
| `route_walk_empty` | O3 | `RouteWalk.project` off: a routed read gives nothing | crash (panics) | | exit 1 |  |  | |
| `positional_always_apart` | O3 O6 | two positions of one root are apart under the root's separation, whatever they name | killed | | 22: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 174: AliasGroupCall (OwnershipV2Differs), … | 0 | |
| `apart_of_no` | O3 O13 | two leaves of one root are apart with no condition | killed | | 0 | 14: AnsweredHolder (OwnershipV2Differs), … | 0 | |
| `two_params_no` | O3 O13 | two parameters are apart with no condition | killed | | 5: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 4: BridgeResultPaths [browser-inline] (OwnershipV2Differs), … | 0 | |
| `overlap_no_expand` | O3 | a call's leaf is not read through what it comes from | killed | | 40: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 79: Binders (OwnershipV2Differs), … | 0 | |
| `answer_holds_no` | O3 H3 | an answer holds nothing of what its run was supplied | killed | | 3: SanitiserCapturedWriter (SanitisedRefusalDiffers), … | 2: CallbackKeeps [browser-inline] (OwnershipV2Differs), … | 0 | |
| `made_meets_off` | O3 | what a frame made may be what it was handed: `made` off | SURVIVED | open | 0 | 0 | 0 | 0 |
| `overlap_host_no` | O3 H6 | a host object meets no host object | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `loan_holds_nothing` | O3 | a loan holds nothing of what it lends | killed | | 2: SanitiserCellCaptureList (SanitisedRefusalDiffers), … | 0 | 0 | |
| `meet_in_never` | O3 O6 | `Subtree.meetIn` always false: two slot sets never meet | blanket | | 30: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 241: AliasGroupCall (OwnershipV2Differs), … | 0 | |
| `alt_first_arm` | O4 O15 | a `case`'s leaf sets keep its first arm | crash (panics) | | exit 1 |  |  | |
| `project_alt_first` | O4 O15 | a project through a choice reads its first arm | killed | | 0 | 4: CallReadsNothingAfter (OwnershipV2Differs), … | 0 | |
| `unite_left` | O4 | `Forest.unite` keeps the left tree | blanket | | 104: SanitiserAnswerFoldCycle (BuildFailed), … | 373: Accumulator (OwnershipV2Limit), … | 0 | |
| `contract_join_left` | O4 O15 | `Contract.join` keeps the left contract | blanket | | 96: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 368: Accumulator (OwnershipV2Limit), … | 0 | |
| `add_escape_drop` | O4 O8 | `Eval.addEscapeAt` records nothing | killed | | 15: SanitiserAnswerLeft (ProgramFailed), … | 9: BranchEscapes (OwnershipV2Differs), … | 0 | |
| `join_once_off` | O15 | a join loses `once` | killed | | 13: SanitiserCellCaptureList (SanitisedRefusalDiffers), … | 10: Binders (OwnershipV2Limit), … | 0 | |
| `join_calls_second` | O15 | a join's `many` is the second side's, not the maximum | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `conj_drop_right` | O15 | `Cond.conj` drops its right side | crash (panics) | | exit 1 |  |  | |
| `conj_forgets_no` | O15 | `no` becomes a selection: `conj` forgets a `no` | crash (panics) | | exit 1 |  |  | |
| `weaker_always` | O15 O5 | `weakerIn` always true | SURVIVED | open | 0 | 0 | 0 | 0 |
| `ov_join_left` | O15 | `Ov.join` keeps the left side | killed | | 0 | 0 | own2.Pairs.test.random systems of joins have one answer, their least fixed point, in any order | |
| `sets_meet_never` | O15 | `Coexist.setsMeet` always false: routed tags never coexist | killed | | 21: SanitiserAnswers (SanitisedRefusalDiffers), … | 70: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `contract_no_res` | O5 | a contract states no result | killed | | 39: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 134: Binders (OwnershipV2Differs), … | 0 | |
| `contract_no_reads` | O5 | a contract states no reads of a local's uses | killed | | 26: SanitiserCallbackAnswers (ProgramFailed), … | 38: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `contract_no_writes` | O5 | a contract states no writes | blanket | | 48: SanitiserAnswerHandedOn (ProgramFailed), … | 254: Accumulator (OwnershipV2Differs), … | 0 | |
| `contract_no_escapes` | O5 O8 | a contract states no escapes | killed | | 2: SanitiserClosureList (SanitisedRefusalDiffers), … | 0 | 0 | |
| `contract_no_stores` | O5 | a contract states no stores | killed | | SanitiserTakenElementCell (SanitisedRefusalDiffers) | 0 | 0 | |
| `contract_no_req` | O5 | a contract asks nothing of its callers | killed | | 8: SanitiserAnswers (SanitisedRefusalDiffers), … | 118: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `call_effects_off` | O5 | a callee's effects are not instantiated at a call | blanket | | 73: SanitiserAnswerHandedOn (SanitisedRefusalAccepted), … | 453: Accumulator (OwnershipV2Differs), … | 0 | |
| `graft_stop_off` | O5 G6 | `Graft.stop` off: every write is taken the slow way (a fast path's absence, so equivalent if it agrees) | v1 only | | 0 | 0 | 0 | 1 parity, 14 STALE |
| `step_elem_apart` | O6 | `[*]` meets no other list step | killed | | 2: SanitiserPatternStoredBack (ProgramFailed), … | 2: PushedPositions (OwnershipV2Differs), … | 2: own2.Steps.test.meetClasses lists exactly the classes of related steps (§2.3.2), … | |
| `step_front_back_apart` | O6 | a front and a back never meet | killed | | 0 | 0 | 3: own2.Steps.test.meetClasses lists exactly the classes of related steps (§2.3.2), … | |
| `step_slice_apart` | O6 | a slice is no range of its parent | killed | | 0 | 4: HeldElementWrites (OwnershipV2Differs), … | 2: own2.Steps.test.meetClasses lists exactly the classes of related steps (§2.3.2), … | |
| `related_prefix_apart` | O6 | a position and its prefix are apart | blanket | | 27: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 241: AliasGroupCall (OwnershipV2Differs), … | 2: own2.Value.test.every index of positions meets exactly what the pairwise relation relates (§2.3.2), … | |
| `level_replay_same` | O6 | a `⟲` replayed where it does not fold names no level below | killed | | 0 | 10: ChildBesideOwnCall (OwnershipV2Differs), … | 0 | |
| `level_route_shortest` | O6 | a reference's next levels are the first route alone | killed | | 3: SanitiserLevelRoutes | | |
| `level_slot_twice` | O6 | a slot two routes of a `⟲` reach is read twice | killed | | 2: SanitiserLevelRoutesFolded | | |
| `level_wide_off` | O6 | an open arrival is not said at the folds above it | killed | | 3: SanitiserLevelResult | | |
| `caller_folds_off` | O6 | an open arrival is not said at a caller's folds its callee's graph has not | killed | | 10: SanitiserLevelCaller | | |
| `below_folds_off` | O6 | a read below a call's slot misses the folds above it a walk below it reaches | killed | | 2: SanitiserLevelCallerBelow | | |
| `below_join_one_name` | O6 | a read below a call's slot named through a join reads the join's key alone, not each level path's | killed | | 1: SanitiserFamilyJoinBelow | | |
| `level_join_kept` | O6 | an arrival at a join is said at the join only, not at its level paths | killed | | 5: SanitiserLevelSlots | | |
| `unescaped_off` | O8 H1 H6 | `Resolve.judge` skips Unescaped | killed | | 9: SanitiserAnswerLeft (ProgramFailed), … | 9: BranchEscapes (OwnershipV2Differs), … | 0 | |
| `escape_unknown_off` | O8 | an escape of unknown keys reaches no target | v1 only | | 0 | 0 | 0 | 3 parity |
| `escape_params_off` | O8 | an escape of a parameter reaches no parameter's target | killed | | SanitiserHandedWriter (SanitisedRefusalDiffers) | 7: BranchEscapes (OwnershipV2Differs), … | 0 | |
| `unknown_accepted` | O8 H6 | a write of an unknown object is judged as a fresh one | killed | | 17: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 17: ApproximateAliasLevels (OwnershipV2Differs), … | 0 | |
| `shared_writable` | O8 | a write of `shared` is not refused `top_level` | killed | | 0 | 12: CallbackComponentGuard [browser-inline] (OwnershipV2Differs), … | 0 | |
| `escaped_writes_off` | O8 H6 | `Closures.escapedWrites` off: an escaped code writes nothing | killed | | 11: SanitiserCalledCodeIdentityWriter (SanitisedRefusalDiffers), … | 0 | 0 | |
| `closure_runs_off` | H6 | `ClosureRuns.runs` off: an escaped closure runs nothing | killed | | 2: SanitiserClosureList (SanitisedRefusalDiffers), … | 0 | 0 | |
| `closure_answers_off` | H6 | `ClosureAnswers.of` off: what an escaped code answers does not escape | killed | | 2: SanitiserClosureResult (SanitisedRefusalDiffers), … | 0 | 0 | |
| `answer_left_off` | H6 | `ClosureAnswers.labelled` off: `answer_left` is not read | killed | | SanitiserAnswerLeft (ProgramFailed) | 0 | 0 | |
| `stored_off` | O8 H6 | `Stored.leaves` off: what a cell stores does not escape | killed | | 4: SanitiserCellLoan (SanitisedRefusalDiffers), … | 0 | 0 | |
| `contents_check_off` | O8 | `Contents.check` off: a cell's handle is not checked | killed | | SanitiserTakenElementCell (SanitisedRefusalDiffers) | 0 | 0 | |
| `host_reach_off` | O8 | `Host.reaches` always false: no own object becomes a host object | killed | | SanitiserEscapedResult (SanitisedRefusalDiffers) | 0 | 0 | |
| `taken_side_off` | O9 | a taken element is not read as its container's | killed | | 13: SanitiserAnswers (SanitisedRefusalDiffers), … | 14: Callbacks (OwnershipV2Differs), … | 0 | |
| `taken_mark_off` | O9 | neither site marks `taken_write` | stale | | 0 | 0 | 0 | 15 STALE |
| `taken_occs_off` | O9 H3 | a `taken` write asks nothing of its element's slot | killed | | 6: SanitiserAnswers (SanitisedRefusalDiffers), … | 2: FoldKeepsInnerRefused [node+everywhere] (OwnershipV2Differs), … | 0 | |
| `reserve_off` | O11 | `Account.reserve` charges nothing: no limit is reached | killed | | 0 | WideModelArms [browser-tea] (GoldenMismatch) | 10: own2.Ids.test.a charge reserves in the lane it is given, and growth only when it is given none, … | |
| `hoists_of_refused` | O11 O12 | a refused or limited module publishes its writes | killed | | 0 | 0 | own2.Hoists.test.a refused or limited module publishes no write; an accepted one its writes, each once, by instruction | |
| `hoists_drop_write` | O12 | `Hoists.Builder.add` publishes no write | killed | | 47: SanitiserAnswerFoldCycle (SanitisedSitesMismatch), … | 0 | own2.Hoists.test.a refused or limited module publishes no write; an accepted one its writes, each once, by instruction | |
| `distinct_yes` | O13 | `Distinct.check` off: every value is distinct | crash (panics) | | exit 1 |  |  | |
| `sep_top_ok` | O13 | a `⊤`, `shared` or loan entry does not make `Sep` `no` | killed (panics) | | 0 | 2: NestedLambdaSend [browser-inline] (UnexpectedExitCode), … | 0 | |
| `sep_family_off` | O13 | a family asks no separation of its root | killed | | 4: SanitiserAnswers (SanitisedRefusalDiffers), … | 25: CombinePositions (OwnershipV2Differs), … | 0 | |
| `sep_answer_supply_off` | O13 H3 | a label's answer is not kept apart from what reaches its supply | SURVIVED | redundant | 0 | 0 | 0 | 0 |
| `atom_twice_off` | O13 | an atom met twice is no failure | killed | | 21: SanitiserAnswers (SanitisedRefusalDiffers), … | 69: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `within_group_off` | O13 | two entries of one root are not compared | killed | | 10: SanitiserAnswers (SanitisedRefusalDiffers), … | 88: AnsweredHolder (OwnershipV2Differs), … | 0 | |
| `made_meets_own_off` | O13 | a frame's own object and a made one are apart | killed | | SanitiserReturnedClosure (SanitisedRefusalDiffers) | 0 | 0 | |
| `answer_meets_off` | O13 H3 | `answerMeets` off: two answers of one run never meet | killed | | 2: SanitiserAnswers (SanitisedRefusalDiffers), … | ConditionalCallbackKeep [browser-inline] (OwnershipV2Differs) | 0 | |
| `res_conds_off` | O13 O5 | `Distinct.resConds` off: a result's condition is the default | crash (panics) | | exit 1 |  |  | |
| `inst_sel_yes` | O14 | `Distinct.instSelFeed` answers yes | crash (panics) | | exit 1 |  |  | |
| `inst_cond_yes` | O14 | `Distinct.instCond` answers yes | crash (panics) | | exit 1 |  |  | |
| `relies_off` | O14 H1 | `Outward.finishDemands` off: a write relies on nothing | killed | | 24: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 122: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `graft_sel_twice` | O14 | `CallGraft.sel` renames two parameters handed one value | killed | | 0 | 4: FoldCertificate (OwnershipV2Differs), … | 0 | |
| `moved_req_yes` | O14 | `MovedReq.of` answers yes | killed | | 8: SanitiserAnswers (SanitisedRefusalDiffers), … | 118: AnsweredAboveElements (OwnershipV2Differs), … | 0 | |
| `below_direct_off` | O14 H3 | a label's `below` at a direct call asks nothing | crash (panics) | | exit 1 |  |  | |
| `below_pass_off` | O14 H3 | a label's `below` at a pass asks nothing | crash (panics) | | exit 1 |  |  | |
| `below_outer_off` | O14 H3 | a label's `below` inside a known code asks nothing of the outer labels | SURVIVED | redundant | 0 | 0 | 0 | 0 |
| `repeated_off` | O14 H3 | `SupplyAnswers.repeated` off | killed | | SanitiserAnswerHandedOn (SanitisedRefusalDiffers) | 0 | 0 | |
| `runs_each_true` | O14 H3 | `Traversal.runsEach` always true | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `apart_sources_true` | O14 H3 | two sources of one traversal are always apart | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `one_family_true` | O14 H3 | any supply is one family | SURVIVED | redundant | 0 | 0 | 0 | 0 |
| `each_takes_true` | O14 H2 | `Each.takes` always true: a traversal takes every argument | killed | | 2: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 0 | 0 | |
| `each_kept_ignored` | O14 H3 | `each` is published over a kept supply | SURVIVED | open | 0 | 0 | 0 | 0 |
| `fed_covered_true` | O14 H3 | `Fed.covered` true whenever a feed covers | SURVIVED | redundant | 0 | 0 | 0 | 0 |
| `fed_relies_off` | O14 H3 | `FedWrite.relies` off | killed | | 3: SanitiserAnswerFoldCycle (BuildFailed), … | 6: BesideTupleHelper [node+everywhere] (OwnershipV2Differs), … | 0 | |
| `fed_call_no` | O14 H3 | `FedCall.at` answers `.no` | killed | | 15: SanitiserAnswerFoldCycle (BuildFailed), … | 14: Accumulator (OwnershipV2Differs), … | 0 | |
| `answer_call_no` | O14 H3 | `AnswerCall.at` answers false | killed | | 2: SanitiserAnswersApart (BuildFailed), … | 4: CallbackAnswerInList (OwnershipV2Differs), … | 0 | |
| `all_made_true` | O14 H3 | `Answers.allMade` true of any call with a contract | killed | | 2: SanitiserAnswers (SanitisedRefusalDiffers), … | 4: FoldCertificate (OwnershipV2Differs), … | 0 | |
| `self_fed_answer_free` | O14 H3 | `Distinct.reqOn` on a twin asks nothing of the answer itself | killed | | 1: SanitiserFoldAnswerFedRefused (SanitisedRefusalDiffers) | 0 | 0 | |
| `self_fed_keeps_ok` | O14 H3 | `RunKeeps.nothing` (`SelfFed.keepsNothing` before #2367) true of any known code | killed | | 1: SanitiserFoldAnswerFedKept (GoldenMismatch) | 1: FoldKeepsInnerRefused [node+everywhere] (OwnershipV2Differs) | 0 | |
| `self_fed_slot_off` | O14 H3 | `SelfFed.of` asks no arrival of the fed argument to stay at its own slot | killed | | 1: SanitiserFoldAnswerFedSlot (GoldenMismatch) | 0 | 0 | |
| `call_write_off` | H1 | `Eval.callWriteFrom` off: a callee's write makes no demand | blanket | | 73: SanitiserAnswerHandedOn (SanitisedRefusalAccepted), … | 451: Accumulator (OwnershipV2Differs), … | 0 | |
| `disjoint_off` | H1 | a callee's own reliance is not refused | killed | | 4: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 13: ChildBesideOwnCall (OwnershipV2Differs), … | 0 | |
| `exclusive_off` | H1 | what a write relied on, if it cannot hold, is not refused | SURVIVED | dead | 0 | 0 | 0 | 0 |
| `kept_write_off` | H2 | a known code's write of a kept supply is not refused | killed | | 6: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 9: ConditionalCallbackKeep [browser-inline] (OwnershipV2Differs), … | 0 | |
| `many_write_off` | H4 | a write of a capture at a code run more than once is not refused | killed | | 2: SanitiserNestedCallbackWrite (SanitisedRefusalAccepted), … | 3: ClosureCapture (OwnershipV2Differs), … | 0 | |
| `kept_outward_off` | H2 | `LabelChain.keptOutward` is not asked | killed | | 6: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 3: ConditionalCallbackKeep [browser-inline] (OwnershipV2Differs), … | 0 | |
| `supplied_judge_off` | H2 | `Supplied.judge` off: a part unknown whole keeps nothing of its known objects | killed | | 3: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 0 | 0 | |
| `may_be_held_off` | H2 | `Supplied.mayBeHeld` off | killed | | SanitiserAnswerHandedOn (SanitisedRefusalDiffers) | 0 | 0 | |
| `across_operands_off` | H2 | `Across.operands` off: a capture write has no operands | killed | | 3: SanitiserAnswerHandedOn (SanitisedRefusalDiffers), … | 0 | 0 | |
| `across_no_answers` | H2 | `Across.operands` leaves out the other labels' answers | SURVIVED | redundant | 0 | 0 | 0 | 0 |
| `answer_keep_no` | H2 | `AnswerKeep.kept` answers `.no` | killed | | SanitiserAnswerHandedOn (SanitisedRefusalDiffers) | 0 | 0 | |
| `once_off` | H4 | `Once.demands` off: a closure's creation asks nothing of what its code writes | killed | | 2: SanitiserCellCaptureList (SanitisedRefusalDiffers), … | 0 | 0 | |
| `outward_many_off` | H4 | `LabelChain.outwardMany` false | killed | | SanitiserAnswerHandedOn (SanitisedRefusalDiffers) | 0 | 0 | |
| `labels_add_up_off` | H4 | labels of one function slot do not add up | SURVIVED | redundant | 0 | 0 | 0 | 0 |
| `held_by_closure_off` | H4 | `Supplied.heldByClosure` false | killed | | SanitiserAnswerHandedOn (SanitisedRefusalDiffers) | 0 | 0 | |
| `deep_at_off` | H5 O13 | `Distinct.deepAt` off: no occurrence is made deep | killed | | 9: SanitiserAnswersApart (BuildFailed), … | 4: EditAnsweredList (OwnershipV2Differs), … | 0 | |
| `deep_at_closure_off` | H5 | a function slot is no deep occurrence | killed | | 2: SanitiserClosureSlotHolder (GoldenMismatch), … | 0 | 0 | |
| `later_functions_off` | H5 | `LaterFunctions.ask` off | killed | | SanitiserLaterFunction (ProgramFailed) | 0 | 0 | |
| `overlap_cycle_may` | O3 G5 G12 | `Pairs.Queries.enter` answers `may` to a pair in progress: refusals only | killed | | 3: SanitiserAnswerFoldCycle (BuildFailed), … | FoldStoresElements (OwnershipV2Differs) | 3: own2.Pairs.test.a cross edge to a closed member is no head, … | |
| `pairs_one_pass` | O3 G5 | `Pairs.Queries.leave` stops at one pass: a component's values are not its fixed point | killed | | 0 | 0 | 3: own2.Pairs.test.a cross edge to a closed member is no head, … | |
| `comparison_gate_off` | R-5.13.1 | a comparison's walk may write what arrived | killed | | 0 | 17: CmpComponentsImported (OwnershipV2Differs), … | 0 | |
| `comparison_row_no_reads` | O9 | a comparison's contract reads nothing | killed | | 0 | 2: ApartPaths (OwnershipV2Differs), … | 0 | |
| `entry_held_off` | G1 | `EntryHeld.demands` off | stale | | 0 | 0 | 0 | 15 STALE |
| `entry_mark_off` | G1 | an argument of an entry is not marked | stale | | 0 | 0 | 0 | 2 STALE |
| `word_aliased` | O9 | a row's word `aliased` is ignored | killed | | SanitiserTimeoutAnswer (ProgramFailed) | 9: HostedEntryHostSettle [browser+everywhere] (OwnershipV2Differs), … | 0 | |
| `word_builderdone` | O9 | a row's word `builderdone` is ignored | SURVIVED | open | 0 | 0 | 0 | 0 |
| `word_cellcomplete` | O9 | a row's word `cellcomplete` is ignored | stale | | 0 | 0 | 0 | 113 STALE |
| `word_cellempty` | O9 | a row's word `cellempty` is ignored | killed | | SanitiserLoanFreshEdit (BuildFailed) | 0 | 0 | |
| `word_cellmodify` | O9 | a row's word `cellmodify` is ignored | killed | | 3: SanitiserCellEdit (BuildFailed), … | LoanNames (OwnershipV2Differs) | 0 | |
| `word_cellnew` | O9 | a row's word `cellnew` is ignored | killed | | 19: SanitiserCellCapture (BuildFailed), … | 0 | 0 | |
| `word_cellstored` | O9 | a row's word `cellstored` is ignored | killed | | SanitiserTakenElementCell (SanitisedRefusalDiffers) | 0 | 0 | |
| `word_cellupdate` | O9 | a row's word `cellupdate` is ignored | killed | | 13: SanitiserCellCaptureList (SanitisedRefusalDiffers), … | 0 | 0 | |
| `word_cellwrite` | O9 | a row's word `cellwrite` is ignored | killed | | 0 | LoanNames (OwnershipV2Differs) | 0 | |
| `word_concatenated` | O9 | a row's word `concatenated` is ignored | killed | | 0 | 3: FoldAccumulators [browser-tea+everywhere] (OwnershipV2Differs), … | 0 | |
| `word_consumed` | O9 | a row's word `consumed` is ignored | killed | | 0 | RefMakeWrapped (OwnershipV2Differs) | 0 | |
| `word_copyof` | O9 | a row's word `copyof` is ignored | killed | | 8: SanitiserAnswersApart (BuildFailed), … | 20: Copy (OwnershipV2Differs), … | 0 | |
| `word_elementof` | O9 | a row's word `elementof` is ignored | killed | | 3: SanitiserFoldedType (SanitisedRefusalDiffers), … | 3: FoldKeepsInner [node+everywhere] (OwnershipV2Differs), … | 0 | |
| `word_entry` | O9 | a row's word `entry` is ignored | stale | | 0 | 0 | 0 | 15 STALE |
| `word_escaped` | O9 | a row's word `escaped` is ignored | killed | | 0 | JsWords (OwnershipV2Differs) | 0 | |
| `word_exclusive` | O9 | a row's word `exclusive` is ignored | killed | | 2: SanitiserAnswersApart (BuildFailed), … | 3: LoanNames (OwnershipV2Differs), … | 0 | |
| `word_fresh` | O9 | a row's word `fresh` is ignored | killed | | 16: SanitiserAnswers (SanitisedRefusalDiffers), … | 25: BranchEscapes (OwnershipV2Differs), … | 0 | |
| `word_lent` | O9 | a row's word `lent` is ignored | killed | | 2: SanitiserFiberJoins (SanitisedRefusalDiffers), … | 2: LoanNames (OwnershipV2Differs), … | 0 | |
| `word_lentoptional` | O9 | a row's word `lentoptional` is ignored | SURVIVED | open | 0 | 0 | 0 | 0 |
| `word_once` | O9 | a row's word `once` is ignored | v1 only | | 0 | 0 | 0 | 1 parity |
| `word_prepended` | O9 | a row's word `prepended` is ignored | SURVIVED | open | 0 | 0 | 0 | 0 |
| `word_returned` | O9 | a row's word `returned` is ignored | killed | | 29: SanitiserAnswerFoldCycle (BuildFailed), … | 95: Accumulator (OwnershipV2Differs), … | 0 | |
| `word_stored` | O9 | a row's word `stored` is ignored | killed | | 6: SanitiserAnswers (SanitisedRefusalDiffers), … | 25: CombinePositions (OwnershipV2Differs), … | 0 | |
| `word_taken` | O9 | a row's word `taken` is ignored | killed | | 25: SanitiserAnswers (SanitisedRefusalDiffers), … | 33: BesideLiteralHelper [node+everywhere] (OwnershipV2Differs), … | 0 | |
| `word_unknown` | O9 | a row's word `unknown` is ignored | SURVIVED | equivalent | 0 | 0 | 0 | 0 |
| `word_unused` | O9 | a row's word `unused` is ignored | SURVIVED | open | 0 | 0 | 0 | 0 |
| `word_written` | O9 | a row's word `written` is ignored | blanket | | 73: SanitiserAnswerHandedOn (SanitisedRefusalAccepted), … | 430: AliasGroupCall (OwnershipV2Differs), … | 0 | |
