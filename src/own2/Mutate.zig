//! L0: the rules of the checker, broken one at a time on purpose
//! (`docs/design/ownership-v2.md` §2.14, §7 item 7). `-Downership-v2-mutation=<name>`
//! picks one member of `Name`; `zig build test-own2-mutations` builds a compiler with
//! each and says which fixtures fail. A site is one line in the rule it breaks, and a
//! rule with two sites has both:
//! `if (@import("Mutate.zig").on(.fold_read_off)) return;`. `on` is decided at compile
//! time, so without the option a site compiles to nothing, and `gates` refuses the option.
//!
//! A member's comment says what it breaks, after the obligations (§2.14.6), the rows of
//! §2.14.5 and the gaps (§2.14.7) it stands for. `word_<w>` ignores signature word `w`
//! (R-8.7, R-5.10.7): it has one site, `RowEnv.Env.has`.
//!
//! Obligations kept here: none of §2.14's directly; this file is how they are measured.

const std = @import("std");

pub const Name = enum {
    none,
    /// O1 O10 G4: a step no place names reads as nothing, not as what it lies inside or `⊤`.
    unnamed_step_empty,
    /// O1 O10: `Walker.project` gives a scalar for a step a place cannot name.
    walker_project_scalar,
    /// O1 O10: `Walker.project` gives a scalar for a row step of a tuple or constructor.
    walker_row_scalar,
    /// O1 O8: a callee's escapes do not escape at the call.
    call_escape_off,
    /// O8: a callee's escape is read at the slot, not deep.
    escape_shallow,
    /// O1: the pessimistic contract escapes no argument.
    pessimistic_no_escape,
    /// O1 O10: the pessimistic contract's result holds nothing.
    pessimistic_res_empty,
    /// O10 G2: `FoldRead.read` off: an empty arrival past a fold stays empty.
    fold_read_off,
    /// O10 G2: `FoldRead.prefix` off: a project past a fold finds no `var`.
    fold_prefix_off,
    /// O10: `Origin.leaves` off: a `⊤` lies inside nothing.
    origin_leaves_off,
    /// O10: `instAt` with no contract reads nothing, not `⊤`.
    inst_no_contract_empty,
    /// O10: `instAt` in a group with no contract reads nothing.
    inst_live_no_contract_empty,
    /// O10: `instBelow` with no contract reads nothing.
    inst_below_no_contract_empty,
    /// O10: an arrival of a parameter past the arguments reads nothing.
    arrival_no_arg_empty,
    /// O10: an answer of no mapped label reads nothing.
    arrival_no_label_empty,
    /// O10: a known code's answer at an unnamed slot reads nothing.
    known_answer_empty,
    /// O10: a loan of nothing is nothing, not `⊤`.
    lend_empty,
    /// O10 G4: a demand with no target is not refused `unknown`.
    targets_empty_accepted,
    /// O2: a call's argument is no use of the local.
    walker_no_call_use,
    /// O2 H1: no live local is a witness.
    live_holders_off,
    /// O2 G6: the aggregated holders are not read (a fast path's other half).
    aggregated_off,
    /// O2: `Stack.judge` off: no pending operand is a witness.
    stack_judge_off,
    /// O2 G6: `Stack.judge` skips the target's selection through other leaves.
    stack_agg_off,
    /// O2: a write is not judged against the call's other operands.
    other_operands_off,
    /// O2 G6: `Operands.judged` off: a call's aggregated operands are empty.
    operands_judged_off,
    /// O2: no two points are in compatible regions.
    regions_never_compatible,
    /// O2: a call's use reads nothing of what its footprint says.
    later_footprint_none,
    /// O2 G6: `Descent.descend` off: no hold is visited.
    descent_off,
    /// O2: `HoldAt.holdsAt` off: a holder holds nothing.
    hold_at_off,
    /// O2: `Sweep.Live.add` off: no local is live.
    sweep_add_off,
    /// O3: `Subtree.readAt`: an open arrival is read at the slot only, a `var` not deep.
    read_at_shallow,
    /// O3 O5: `Within.within` always true: a candidate is never validated.
    within_always,
    /// O3: `RouteWalk.project` off: a routed read gives nothing.
    route_walk_empty,
    /// O3 O6: two positions of one root are apart under the root's separation, whatever they name.
    positional_always_apart,
    /// O3 O13: two leaves of one root are apart with no condition.
    apart_of_no,
    /// O3 O13: two parameters are apart with no condition.
    two_params_no,
    /// O3: a call's leaf is not read through what it comes from.
    overlap_no_expand,
    /// O3 H3: an answer holds nothing of what its run was supplied.
    answer_holds_no,
    /// O3: what a frame made may be what it was handed: `made` off.
    made_meets_off,
    /// O3 H6: a host object meets no host object.
    overlap_host_no,
    /// O3: a loan holds nothing of what it lends.
    loan_holds_nothing,
    /// O3 O6: `Subtree.meetIn` always false: two slot sets never meet.
    meet_in_never,
    /// O4 O15: a `case`'s leaf sets keep its first arm.
    alt_first_arm,
    /// O4 O15: a project through a choice reads its first arm.
    project_alt_first,
    /// O4: `Forest.unite` keeps the left tree.
    unite_left,
    /// O4 O15: `Contract.join` keeps the left contract.
    contract_join_left,
    /// O4 O8: `Eval.addEscapeAt` records nothing.
    add_escape_drop,
    /// O15: a join loses `once`.
    join_once_off,
    /// O15: a join's `many` is the second side's, not the maximum.
    join_calls_second,
    /// O15: `Cond.conj` drops its right side.
    conj_drop_right,
    /// O15: `no` becomes a selection: `conj` forgets a `no`.
    conj_forgets_no,
    /// O15 O5: `weakerIn` always true.
    weaker_always,
    /// O15: `Ov.join` keeps the left side.
    ov_join_left,
    /// O15: `Coexist.setsMeet` always false: routed tags never coexist.
    sets_meet_never,
    /// O5: a contract states no result.
    contract_no_res,
    /// O5: a contract states no reads of a local's uses.
    contract_no_reads,
    /// O5: a contract states no writes.
    contract_no_writes,
    /// O5 O8: a contract states no escapes.
    contract_no_escapes,
    /// O5: a contract states no stores.
    contract_no_stores,
    /// O5: a contract asks nothing of its callers.
    contract_no_req,
    /// O5: a callee's effects are not instantiated at a call.
    call_effects_off,
    /// O5 G6: `Graft.stop` off: every write is taken the slow way (a fast path's absence, so equivalent if it agrees).
    graft_stop_off,
    /// O6: `[*]` meets no other list step.
    step_elem_apart,
    /// O6: a front and a back never meet.
    step_front_back_apart,
    /// O6: a slice is no range of its parent.
    step_slice_apart,
    /// O6: a position and its prefix are apart.
    related_prefix_apart,
    /// O6: a `⟲` replayed where it does not fold names no level below.
    level_replay_same,
    /// O6: a reference's next levels are the first route alone.
    level_route_shortest,
    /// O6: a slot two routes of a `⟲` reach is read twice.
    level_slot_twice,
    /// O8 H1 H6: `Resolve.judge` skips Unescaped.
    unescaped_off,
    /// O8: an escape of unknown keys reaches no target.
    escape_unknown_off,
    /// O8: an escape of a parameter reaches no parameter's target.
    escape_params_off,
    /// O8 H6: a write of an unknown object is judged as a fresh one.
    unknown_accepted,
    /// O8: a write of `shared` is not refused `top_level`.
    shared_writable,
    /// O8 H6: `Closures.escapedWrites` off: an escaped code writes nothing.
    escaped_writes_off,
    /// H6: `ClosureRuns.runs` off: an escaped closure runs nothing.
    closure_runs_off,
    /// H6: `ClosureAnswers.of` off: what an escaped code answers does not escape.
    closure_answers_off,
    /// H6: `ClosureAnswers.labelled` off: `answer_left` is not read.
    answer_left_off,
    /// O8 H6: `Stored.leaves` off: what a cell stores does not escape.
    stored_off,
    /// O8: `Contents.check` off: a cell's handle is not checked.
    contents_check_off,
    /// O8: `Host.reaches` always false: no own object becomes a host object.
    host_reach_off,
    /// O9: a taken element is not read as its container's.
    taken_side_off,
    /// O9: neither site marks `taken_write`.
    taken_mark_off,
    /// O9 H3: a `taken` write asks nothing of its element's slot.
    taken_occs_off,
    /// O11: `Account.reserve` charges nothing: no limit is reached.
    reserve_off,
    /// O11 O12: a refused or limited module publishes its writes.
    hoists_of_refused,
    /// O12: `Hoists.Builder.add` publishes no write.
    hoists_drop_write,
    /// O13: `Distinct.check` off: every value is distinct.
    distinct_yes,
    /// O13: a `⊤`, `shared` or loan entry does not make `Sep` `no`.
    sep_top_ok,
    /// O13: a family asks no separation of its root.
    sep_family_off,
    /// O13 H3: a label's answer is not kept apart from what reaches its supply.
    sep_answer_supply_off,
    /// O13: an atom met twice is no failure.
    atom_twice_off,
    /// O13: two entries of one root are not compared.
    within_group_off,
    /// O13: a frame's own object and a made one are apart.
    made_meets_own_off,
    /// O13 H3: `answerMeets` off: two answers of one run never meet.
    answer_meets_off,
    /// O13 O5: `Distinct.resConds` off: a result's condition is the default.
    res_conds_off,
    /// O14: `Distinct.instSelFeed` answers yes.
    inst_sel_yes,
    /// O14: `Distinct.instCond` answers yes.
    inst_cond_yes,
    /// O14 H1: `Outward.finishDemands` off: a write relies on nothing.
    relies_off,
    /// O14: `CallGraft.sel` renames two parameters handed one value.
    graft_sel_twice,
    /// O14: `MovedReq.of` answers yes.
    moved_req_yes,
    /// O14 H3: a label's `below` at a direct call asks nothing.
    below_direct_off,
    /// O14 H3: a label's `below` at a pass asks nothing.
    below_pass_off,
    /// O14 H3: a label's `below` inside a known code asks nothing of the outer labels.
    below_outer_off,
    /// O14 H3: `SupplyAnswers.repeated` off.
    repeated_off,
    /// O3: `AnswerKeep.repeats` counts a label only an earlier evaluation passed on.
    repeats_stale_labels,
    /// O1 O8: a known code read as unknown does not escape.
    unknown_code_no_escape,
    /// O14 H3: `Traversal.runsEach` always true.
    runs_each_true,
    /// O14 H3: two sources of one traversal are always apart.
    apart_sources_true,
    /// O14 H3: any supply is one family.
    one_family_true,
    /// O14 H2: `Each.takes` always true: a traversal takes every argument.
    each_takes_true,
    /// O14 H3: `each` is published over a kept supply.
    each_kept_ignored,
    /// O14 H3: `Fed.covered` true whenever a feed covers.
    fed_covered_true,
    /// O14 H3: `FedWrite.relies` off.
    fed_relies_off,
    /// O14 H3: `FedCall.at` answers `.no`.
    fed_call_no,
    /// O14 H3: `AnswerCall.at` answers false.
    answer_call_no,
    /// O14 H3: `Answers.allMade` true of any call with a contract.
    all_made_true,
    /// H1: `Eval.callWriteFrom` off: a callee's write makes no demand.
    call_write_off,
    /// H1: a callee's own reliance is not refused.
    disjoint_off,
    /// H1: what a write relied on, if it cannot hold, is not refused.
    exclusive_off,
    /// H2: a known code's write of a kept supply is not refused.
    kept_write_off,
    /// H4: a write of a capture at a code run more than once is not refused.
    many_write_off,
    /// H2: `LabelChain.keptOutward` is not asked.
    kept_outward_off,
    /// H2: `Supplied.judge` off: a part unknown whole keeps nothing of its known objects.
    supplied_judge_off,
    /// H2: `Supplied.mayBeHeld` off.
    may_be_held_off,
    /// H2: `Across.operands` off: a capture write has no operands.
    across_operands_off,
    /// H2: `Across.operands` leaves out the other labels' answers.
    across_no_answers,
    /// H2: `AnswerKeep.kept` answers `.no`.
    answer_keep_no,
    /// H4: `Once.demands` off: a closure's creation asks nothing of what its code writes.
    once_off,
    /// H4: `LabelChain.outwardMany` false.
    outward_many_off,
    /// H4: labels of one function slot do not add up.
    labels_add_up_off,
    /// H4: `Supplied.heldByClosure` false.
    held_by_closure_off,
    /// H5 O13: `Distinct.deepAt` off: no occurrence is made deep.
    deep_at_off,
    /// H5: a function slot is no deep occurrence.
    deep_at_closure_off,
    /// H5: `LaterFunctions.ask` off.
    later_functions_off,
    /// O3 G5: `instAt` memoises what it read under a cycle's cut.
    inst_memo_under_cut,
    /// O3 G5 G12: `Pairs.Queries.enter` answers `may` to a pair in progress: refusals only.
    overlap_cycle_may,
    /// O3 G5: `Pairs.Queries.leave` stops at one pass: a component's values are not its fixed point.
    pairs_one_pass,
    /// R-5.13.1: a comparison's walk may write what arrived.
    comparison_gate_off,
    /// O9: a comparison's contract reads nothing.
    comparison_row_no_reads,
    /// G1: `EntryHeld.demands` off.
    entry_held_off,
    /// G1: an argument of an entry is not marked.
    entry_mark_off,
    /// O9: a row's word `aliased` is ignored.
    word_aliased,
    /// O9: a row's word `builderdone` is ignored.
    word_builderdone,
    /// O9: a row's word `cellcomplete` is ignored.
    word_cellcomplete,
    /// O9: a row's word `cellempty` is ignored.
    word_cellempty,
    /// O9: a row's word `cellmodify` is ignored.
    word_cellmodify,
    /// O9: a row's word `cellnew` is ignored.
    word_cellnew,
    /// O9: a row's word `cellstored` is ignored.
    word_cellstored,
    /// O9: a row's word `cellupdate` is ignored.
    word_cellupdate,
    /// O9: a row's word `cellwrite` is ignored.
    word_cellwrite,
    /// O9: a row's word `concatenated` is ignored.
    word_concatenated,
    /// O9: a row's word `consumed` is ignored.
    word_consumed,
    /// O9: a row's word `copyof` is ignored.
    word_copyof,
    /// O9: a row's word `elementof` is ignored.
    word_elementof,
    /// O9: a row's word `entry` is ignored.
    word_entry,
    /// O9: a row's word `escaped` is ignored.
    word_escaped,
    /// O9: a row's word `exclusive` is ignored.
    word_exclusive,
    /// O9: a row's word `fresh` is ignored.
    word_fresh,
    /// O9: a row's word `lent` is ignored.
    word_lent,
    /// O9: a row's word `lentoptional` is ignored.
    word_lentoptional,
    /// O9: a row's word `once` is ignored.
    word_once,
    /// O9: a row's word `prepended` is ignored.
    word_prepended,
    /// O9: a row's word `returned` is ignored.
    word_returned,
    /// O9: a row's word `stored` is ignored.
    word_stored,
    /// O9: a row's word `taken` is ignored.
    word_taken,
    /// O9: a row's word `unknown` is ignored.
    word_unknown,
    /// O9: a row's word `unused` is ignored.
    word_unused,
    /// O9: a row's word `written` is ignored.
    word_written,
};

/// The mutation of this build: `none` unless a build asks for one.
pub const active: Name = std.meta.stringToEnum(Name, @import("ownership_options").v2_mutation) orelse
    @compileError("-Downership-v2-mutation names no member of `Mutate.Name`");

/// Whether this build breaks rule `m`.
pub inline fn on(comptime m: Name) bool {
    return comptime active == m;
}

/// The signature word this build ignores, or empty.
const word: []const u8 = if (std.mem.startsWith(u8, @tagName(active), "word_")) @tagName(active)["word_".len..] else "";

/// Whether this build reads signature word `w`.
pub inline fn keeps(w: anytype) bool {
    if (comptime word.len == 0) return true;
    return !std.mem.eql(u8, @tagName(w), word);
}
