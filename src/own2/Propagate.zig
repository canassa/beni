//! L5: `propagate`, the κ of a joined node from its members
//! (`docs/design/ownership-v2.md` §2.9 *Fold first*, §3.4, §4.1): methods of
//! `Cond.Table`, bound there by name (§5).
//!
//! **The rule.** One call makes three passes over its *state graph* Σ. A
//! state is `(joined node, class bits, interned run of members and their
//! positions)`; its children are what one frame of a depth-first walk
//! would push (`frontierWith`, the runs one step below). Pass 1 reads each
//! state once and records the edges, stopping at a clean-memo hit. Pass 2
//! takes Tarjan's components of Σ and of its node graph, and a *cycle bit*
//! per state: does it reach a state of its own node? The bits of a
//! node-graph component K are its nodes', propagated bottom up along the
//! edges inside K. Pass 3 builds positions by their *set* of states: a set
//! holding a cyclic state is an exact fold whose content is its closure in
//! Σ; any other set is open, with the sets one step down as its children.
//! Each set is interned, charged and built once per call. A hit that
//! cannot be used (it shares a set, or lies in a fold's closure) is
//! expanded then, by resuming pass 1 from it and running pass 2 over what
//! that read, before pass 3 reads any of it.
//!
//! **The reference.** `reference` is §2.9's specification: frames
//! `(state, position, folded, route)`, each met once, folding where a route
//! names the child's node. It is exponential in its routes, and it is what
//! `-Downership-full-cross-check` compares the rule with, in both frontier
//! orders, beside the rule without its memo.
//!
//! Obligations kept here: O15 (κ(join) is below every member's: an
//! alternatives state joins its members' κ, a together state conjoins them
//! with `apart` over their cells).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Shape = @import("Shape.zig");
const CondAlgebra = @import("CondAlgebra.zig");
const Kappa = @import("Kappa.zig");
const options = @import("ownership_options");

const NodeId = Ids.NodeId;
const CondId = Ids.CondId;
const Charge = Ids.Charge;
const Error = Ids.ChargeError;
const Kappas = Kappa.Kappas;
const Step = Shape.Step;
const yes = CondAlgebra.yes;
const lost = CondAlgebra.lost;
const none = Ids.none_int;

/// How `propagate` reads a joined node's members: a branch (the lattice
/// join, O15) or a summary position holding every member (`apart` across
/// their cells at every path, and every member's κ).
pub const Mode = enum(u8) { alternatives, together };

/// What one call by the rule read and built: `--ownership-propagate`'s line,
/// and the counted tests'.
pub const Stats = struct { states: u32 = 0, edges: u32 = 0, open: u32 = 0, folds: u32 = 0, resumed: u32 = 0 };

/// The reference walk's frames past which a call is not compared, and a
/// line names it (§2.9 *The `runtime_safety` check*).
pub const reference_cap: u32 = 1 << 22;

/// A test-only mutation of the rule (`-Downership-v2-mutation`, which
/// `gates` refuses): each breaks one part that a counted test pins.
fn mutated(comptime which: []const u8) bool {
    return comptime std.mem.eql(u8, options.v2_mutation, which);
}

pub fn Of(comptime Table: type, comptime View: type, comptime Traversal: type, comptime Item: type) type {
    return struct {
        const Agg = Table.Agg;
        const Next = Table.Next;

        /// What one call propagates.
        const Input = struct {
            v: View,
            out: Kappas,
            joined: NodeId,
            members: []const NodeId,
            ctxs: []const Kappas,
            mode: Mode,
            at_summary: bool,
            member_summary: bool,
            traversal: ?Traversal,
        };

        /// `out` merged with a snapshot that sets κ at every position of
        /// `joined` (a `Shape.join` of `members`, widened or not) from the
        /// members read at the same path, projected in lockstep, each at its
        /// own position of its own snapshot: `alternatives` is the lattice
        /// join (O15), `together` `apart` across the members' cells and every
        /// member's κ. The positions are §2.9's sparse frontier; where
        /// `joined` cycles (a knot `widen` tied) the position becomes a fold
        /// (§2.9 *Fold first*).
        pub fn propagate(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, traversal: ?Traversal) Error!Kappas {
            return propagateFrom(t, gpa, charge, v, out, joined, members, member_ctxs, mode, at_summary, at_summary, traversal);
        }

        /// `propagate`, the members read at their own class (a literal's `vᵢ`, §2.9).
        pub fn propagateFrom(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, member_summary: bool, traversal: ?Traversal) Error!Kappas {
            std.debug.assert(members.len == member_ctxs.len);
            const in: Input = .{ .v = v, .out = out, .joined = joined, .members = members, .ctxs = member_ctxs, .mode = mode, .at_summary = at_summary, .member_summary = member_summary, .traversal = traversal };
            const call = t.prop_calls;
            const r = try rule(t, gpa, charge, &in, !t.no_memo, t.reverse_front, t.propagate_dump and !t.no_memo);
            const cross = std.debug.runtime_safety and options.full_cross_check;
            if (t.no_memo or !(cross or t.order_check)) return r;
            // Walked again with no memo, on an account of its own so that the
            // check moves no limit (§2.9 *The `runtime_safety` check*): the
            // rule in both frontier orders and, under the full cross-check,
            // the reference in both. Each interns in the module's tables, so
            // it may move later records.
            var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
            defer scratch.deinit(gpa);
            t.no_memo = true;
            defer t.no_memo = false;
            for ([_]bool{ false, true }) |rev| {
                if (!cross and !rev) continue;
                if (r != try rule(t, gpa, .growth(&scratch), &in, false, rev, false))
                    std.debug.panic("ownership v2: propagate call {d}'s rule differs without its memo (reversed: {})", .{ call, rev });
                if (!cross) continue;
                if (try reference(t, gpa, .growth(&scratch), &in, rev)) |ref| {
                    if (ref != r) std.debug.panic("ownership v2: propagate call {d}'s rule differs from the reference (reversed: {})", .{ call, rev });
                } else std.debug.print("ownership v2: propagate call {d}: the reference passes {d} frames, not compared\n", .{ call, reference_cap });
            }
            return r;
        }

        /// The reference (§2.9), for tests: null past `reference_cap` frames.
        pub fn propagateReference(t: *Table, gpa: Allocator, charge: Charge, v: View, out: Kappas, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas, mode: Mode, at_summary: bool, reverse: bool) Error!?Kappas {
            const in: Input = .{ .v = v, .out = out, .joined = joined, .members = members, .ctxs = member_ctxs, .mode = mode, .at_summary = at_summary, .member_summary = at_summary, .traversal = null };
            return reference(t, gpa, charge, &in, reverse);
        }

        /// The rule alone, with no memo and no check: `widenValue`'s
        /// bisimulation check reads two images with it.
        pub fn propagatePlain(t: *Table, gpa: Allocator, charge: Charge, v: View, joined: NodeId, members: []const NodeId, member_ctxs: []const Kappas) Error!Kappas {
            const in: Input = .{ .v = v, .out = .none, .joined = joined, .members = members, .ctxs = member_ctxs, .mode = .alternatives, .at_summary = false, .member_summary = false, .traversal = null };
            return rule(t, gpa, charge, &in, false, false, false);
        }

        // ---- pass 1: the state graph ---------------------------------------

        const State = struct {
            node: NodeId,
            summary: bool,
            msummary: bool,
            run: u32,
            first: u32,
            len: u32,
            /// A clean-memo hit not expanded: its position is `hit_at`.
            hit: bool = false,
            hit_at: Kappas = .none,
            /// A finite rank of at least 1, with no traversal: a clean state.
            clean: bool = false,
            /// A link: the member's own snapshot is the position's.
            linked: bool = false,
            link: Kappas = .none,
            has_kept: bool = false,
            kept: Kappas = .none,
            out: u32 = none,
            edge_first: u32 = 0,
            edge_len: u32 = 0,
            // Pass 2.
            classified: bool = false,
            cyclic: bool = false,
            bits_comp: u32 = none,
            bits_off: u32 = 0,
            bits_len: u32 = 0,
            /// The next state of the same node, for a reopened component.
            node_next: u32 = none,
            in_node_list: bool = false,
            /// Tarjan's scratch: 0 outside the run, 1 unvisited, 2 on the
            /// path, 3 done, 4 in the component being closed.
            tj: u8 = 0,
            tj_index: u32 = none,
            tj_low: u32 = 0,
            /// Pass 3's closure mark, by fold.
            mark: u32 = 0,
        };

        const Edge = struct { to: u32, step: u32 };

        /// What a state reads of its run alone, once per run (#1273): its
        /// one member (the link test's), κ from the members, the cursors'
        /// steps, and the frontier of the first node read against them.
        const Slice = struct { m0: NodeId, c0: Kappas, one: bool, k: [4]u32, words: u32, words_len: u32, fold: bool, front: [3]u32 = .{ none, 0, 0 } };

        const Below = struct { first: u32, len: u32, run: u32 };

        const NodeInfo = struct { node: NodeId, comp: u32 = none, kidx: u32 = 0, head: u32 = none, tj_index: u32 = none, tj_low: u32 = 0 };

        const Comp = struct { size: u32, nontrivial: bool };

        const Sigma = struct {
            t: *Table,
            gpa: Allocator,
            charge: Charge,
            in: *const Input,
            memo: bool,
            reverse: bool,
            /// A lone member's entries are kept outside a fold (§2.9 *Keyed
            /// where a reader looks*): alternatives over one member.
            kept_call: bool,
            states: std.ArrayList(State) = .empty,
            index: Ids.FixedDict(3) = .{},
            edges: std.ArrayList(Edge) = .empty,
            runs: std.ArrayList(NodeId) = .empty,
            run_ctxs: std.ArrayList(Kappas) = .empty,
            slices: std.ArrayList(Slice) = .empty,
            slice_at: Ids.FixedDict(1) = .{},
            words: std.ArrayList(u64) = .empty,
            below_at: Ids.FixedDict(4) = .{},
            belows: std.ArrayList(Below) = .empty,
            front_at: Ids.FixedDict(3) = .{},
            fronts: std.ArrayList(Next) = .empty,
            items: std.ArrayList(Item) = .empty,
            next: std.ArrayList(Next) = .empty,
            stack: std.ArrayList(u32) = .empty,
            /// The states read since pass 2 last ran.
            batch: std.ArrayList(u32) = .empty,
            node_at: Ids.FixedDict(1) = .{},
            nodes: std.ArrayList(NodeInfo) = .empty,
            node_edge_at: Ids.FixedDict(2) = .{},
            node_edges: std.ArrayList([2]u32) = .empty,
            comps: std.ArrayList(Comp) = .empty,
            bitwords: std.ArrayList(u64) = .empty,
            resumed: u32 = 0,

            fn deinit(s: *Sigma) void {
                const gpa = s.gpa;
                inline for (.{ "states", "edges", "runs", "run_ctxs", "slices", "words", "belows", "fronts", "items", "next", "stack", "batch", "nodes", "node_edges", "comps", "bitwords" }) |f| @field(s, f).deinit(gpa);
                inline for (.{ "index", "slice_at", "below_at", "front_at", "node_at", "node_edge_at" }) |f| @field(s, f).deinit(gpa);
            }

            /// The run `runs[first..][0..len]` interned as a cons list of
            /// `(member, position)` pairs (`prop_runs`, across calls).
            fn intern(s: *Sigma, first: u32, len: u32) Error!u32 {
                var run: u32 = none;
                var r = len;
                while (r > 0) {
                    r -= 1;
                    try s.charge.reserve(s.gpa, .memo, 1);
                    const got = try s.t.prop_runs.getOrPut(s.gpa, .{ s.runs.items[first + r].int(), s.run_ctxs.items[first + r].int(), run });
                    if (!got.found_existing) got.value_ptr.* = got.index;
                    run = got.value_ptr.*;
                }
                return run;
            }

            /// The state `(node, class bits, run)`, made and queued to be read
            /// when new.
            fn stateOf(s: *Sigma, node: NodeId, summary: bool, msummary: bool, b: Below) Error!u32 {
                try s.charge.reserve(s.gpa, .memo, 1);
                const got = try s.index.getOrPut(s.gpa, .{ node.int(), @as(u32, @intFromBool(summary)) | @as(u32, @intFromBool(msummary)) << 1, b.run });
                if (got.found_existing) return got.value_ptr.*;
                const id: u32 = @intCast(s.states.items.len);
                got.value_ptr.* = id;
                try s.states.append(s.gpa, .{ .node = node, .summary = summary, .msummary = msummary, .run = b.run, .first = b.first, .len = b.len });
                try s.stack.append(s.gpa, id);
                try s.batch.append(s.gpa, id);
                return id;
            }

            fn sliceOf(s: *Sigma, st: State) Error!u32 {
                const sg = try s.slice_at.getOrPut(s.gpa, .{st.run});
                if (sg.found_existing) return sg.value_ptr.*;
                sg.value_ptr.* = @intCast(s.slices.items.len);
                var m0: NodeId = .none;
                var c0: Kappas = .none;
                var one = true;
                for (0..st.len) |i| {
                    const m = s.runs.items[st.first + i];
                    const c = s.run_ctxs.items[st.first + i];
                    if (c == .none and try s.in.v.shapes.isNothing(s.gpa, s.charge.account, m)) continue;
                    if (m0 == .none) {
                        m0 = m;
                        c0 = c;
                    } else one = one and s.in.mode == .alternatives and m == m0 and c == c0;
                }
                try s.slices.append(s.gpa, .{ .m0 = m0, .c0 = c0, .one = one, .k = @splat(none), .words = 0, .words_len = none, .fold = false });
                return sg.value_ptr.*;
            }

            /// Pass 1 from the states queued: each read once, a hit read
            /// only to its head.
            fn drain(s: *Sigma) Error!void {
                while (s.stack.pop()) |id| try s.readHead(id);
            }

            /// What every state reads first: the link test, its kept
            /// entries and the clean memo. A link or a hit stops here.
            fn readHead(s: *Sigma, id: u32) Error!void {
                const t = s.t;
                const gpa = s.gpa;
                const charge = s.charge;
                const in = s.in;
                const v = in.v;
                try charge.reserve(gpa, .memo, 1);
                const st = s.states.items[id];
                const si = try s.sliceOf(st);
                try t.traced(gpa, st.node, st.summary);
                // One alternative, or alternatives all one member at its own
                // node: the position IS that member's, a link (§2.9, #1112) —
                // nothing below is read. An alternative that is nothing (an
                // empty leaf with nothing stored) adds nothing to a join, so it
                // does not count. Together, an empty member is no object
                // either, but two equal members are two positions, never one.
                // An atom is read, never linked: it is a widen's own image
                // (§2.3 *The atom rule*), and its snapshot linked under a fold
                // would collapse the fold.
                if (st.len > 0) {
                    const m0 = s.slices.items[si].m0;
                    const c0 = s.slices.items[si].c0;
                    const one = s.slices.items[si].one and m0 != .none and !v.shapes.isAtom(st.node) and (st.node == m0 or try joinOfOne(gpa, charge, v, st.node, m0, if (in.mode == .alternatives) .@"union" else .positions));
                    if (one) {
                        try charge.reserve(gpa, .inspection, 1);
                        var out: u32 = none;
                        // A literal's one element at its `[*]` itself: the objects it
                        // holds at any path below are compared there (§2.9), over
                        // those construction does not make apart (`arrivals`).
                        if (in.mode == .together and st.node == in.joined) {
                            var k1 = try t.kappaOf(gpa, charge, v, c0, m0, st.msummary);
                            k1 = try t.@"and"(gpa, charge, k1, try t.summaryExcl(gpa, charge, v.cells, v.places, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, m0))));
                            if (in.traversal == null) {
                                // Its reach's aggregate, extended from its parts' (#1121).
                                k1 = try t.@"and"(gpa, charge, k1, try t.aggCond(gpa, charge, v.cells, v.places, try t.reachAgg(gpa, charge, v, m0)));
                            } else {
                                s.items.clearRetainingCapacity();
                                var it = v.cells.sets.iterate(try v.shapes.arrivals(gpa, charge.account, v.cells, &v.cells.sets, m0));
                                while (it.next()) |e| {
                                    try charge.reserve(gpa, .inspection, 1);
                                    try s.items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
                                }
                                k1 = try t.@"and"(gpa, charge, k1, try t.apart(gpa, charge, v.cells, v.places, s.items.items, in.traversal));
                            }
                            try charge.reserve(gpa, .inspection, 1);
                            out = k1.int();
                        }
                        const p = &s.states.items[id];
                        p.linked = true;
                        p.link = c0;
                        p.out = out;
                        return;
                    }
                }
                if (in.mode == .alternatives and st.len == 1 and s.kept_call) {
                    try charge.reserve(gpa, .inspection, 1);
                    s.states.items[id].has_kept = true;
                    s.states.items[id].kept = s.run_ctxs.items[st.first];
                }
                // A clean state met before, in this call or another: its
                // position is the snapshot its walk made (§2.9, *The join
                // memo*). Pass 1 stops there; pass 3 links it where it is alone
                // at an open position, and expands it otherwise.
                if (in.traversal == null and try memoRank(gpa, charge, v, st.node)) {
                    s.states.items[id].clean = true;
                    if (s.memo) {
                        try charge.reserve(gpa, .memo, 1);
                        if (!mutated("propagate-full-read")) {
                            if (t.memo_prop.get(s.memoKey(st))) |hit| {
                                s.states.items[id].hit = true;
                                s.states.items[id].hit_at = .from(hit);
                                return;
                            }
                        }
                    }
                }
                try s.readBody(id);
            }

            /// A clean state's key: its node, class, the mode, whether it is
            /// the call's root (a literal's root reads everything its members
            /// hold), whether a lone member's entries are kept, and its run.
            fn memoKey(s: *const Sigma, st: State) [3]u32 {
                const bits = @as(u32, @intFromBool(st.summary)) | @as(u32, @intFromBool(st.msummary)) << 1 | @as(u32, @backingInt(s.in.mode)) << 2 | @as(u32, @intFromBool(st.node == s.in.joined)) << 3 | @as(u32, @intFromBool(s.kept_call)) << 4;
                return .{ st.node.int(), bits, st.run };
            }

            /// The rest of a state: κ, its entry and its children.
            fn readBody(s: *Sigma, id: u32) Error!void {
                const t = s.t;
                const gpa = s.gpa;
                const charge = s.charge;
                const in = s.in;
                const v = in.v;
                const st = s.states.items[id];
                const si = try s.sliceOf(st);
                const k_slot = @as(usize, @intFromBool(st.node == in.joined)) * 2 + @intFromBool(st.msummary);
                var k: CondId = yes;
                if (s.slices.items[si].k[k_slot] != none) k = .from(s.slices.items[si].k[k_slot]) else {
                    s.items.clearRetainingCapacity();
                    // At the joined node, the members' reaches as one multiset of
                    // aggregates, each extended from its parts' (#1121).
                    const by_agg = in.mode == .together and st.node == in.joined and in.traversal == null;
                    var together: Agg = .{};
                    for (0..st.len) |i| {
                        const m = s.runs.items[st.first + i];
                        const c = s.run_ctxs.items[st.first + i];
                        const km = try t.kappaOf(gpa, charge, v, c, m, st.msummary);
                        k = if (in.mode == .alternatives) try t.join(gpa, charge, k, km) else try t.@"and"(gpa, charge, k, km);
                        if (in.mode == .together) {
                            k = try t.@"and"(gpa, charge, k, try t.summaryExcl(gpa, charge, v.cells, v.places, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, m))));
                            // At the position itself every object a member holds
                            // anywhere below counts (I-κ: one object at two
                            // positions, at whatever paths, is shared — the
                            // `[ (a, b), (b, a) ]` twin); below it, the path's own.
                            if (by_agg) {
                                together = try t.aggMerge(gpa, charge, v.cells, v.places, together, try t.reachAgg(gpa, charge, v, m), true);
                                continue;
                            }
                            const set = if (st.node == in.joined) try v.shapes.reach(gpa, charge.account, &v.cells.sets, m) else (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, m));
                            var it = v.cells.sets.iterate(set);
                            while (it.next()) |e| {
                                try charge.reserve(gpa, .inspection, 1);
                                try s.items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
                            }
                        }
                    }
                    if (by_agg) {
                        k = try t.@"and"(gpa, charge, k, try t.aggCond(gpa, charge, v.cells, v.places, together));
                    } else if (in.mode == .together) k = try t.@"and"(gpa, charge, k, try t.apart(gpa, charge, v.cells, v.places, s.items.items, in.traversal));
                    if (in.mode == .alternatives and st.len == 0) k = lost;
                    s.slices.items[si].k[k_slot] = k.int();
                }
                // A folded class's obligation, stored so the block carries it: the
                // class image's own, or its sides' where it rides in a union
                // (§2.3, #1120).
                k = try t.@"and"(gpa, charge, k, try t.foldCondOf(gpa, charge, v, st.node));
                // A leaf's read is the stored ⊔ the derivation, so a κ no
                // stronger than the derivation stores nothing (against the read
                // without its fold obligation, so the snapshot stores the
                // obligation itself, #1128).
                const plain = try v.shapes.force(gpa, charge.account, st.node);
                const redundant = v.shapes.kind(plain) == .leaf and try t.leq(gpa, charge, k, try t.kappaRead(gpa, charge, v, .none, plain, st.summary, null));
                if (!redundant) {
                    try charge.reserve(gpa, .inspection, 1);
                    s.states.items[id].out = k.int();
                }
                // Children: the joined node's frontier, the members projected
                // along each step of it, each the state one step below.
                if (s.slices.items[si].words_len == none) {
                    const at: u32 = @intCast(s.words.items.len);
                    const fold = try t.cursorSteps(gpa, charge, s.run_ctxs.items[st.first..][0..st.len], &s.words);
                    s.slices.items[si].words = at;
                    s.slices.items[si].words_len = @intCast(s.words.items.len - at);
                    s.slices.items[si].fold = fold;
                }
                const sl = s.slices.items[si];
                // The slice's first frontier is kept on it; another of its
                // frontiers is in `front_at`.
                const fkey: [2]u32 = .{ st.node.int(), @intFromBool(st.summary) };
                var at: ?u32 = if (sl.front[0] == fkey[0] and sl.front[1] == fkey[1]) sl.front[2] else null;
                if (at == null and sl.front[0] != none) {
                    try charge.reserve(gpa, .memo, 1);
                    const fg = try s.front_at.getOrPut(gpa, .{ fkey[0], fkey[1], si });
                    if (fg.found_existing) at = fg.value_ptr.* else fg.value_ptr.* = @intCast(s.fronts.items.len);
                }
                if (at == null) {
                    s.next.clearRetainingCapacity();
                    try t.frontierWith(gpa, charge, v, st.node, st.summary, .{ .words = s.words.items[sl.words..][0..sl.words_len], .fold = sl.fold }, &s.next);
                    at = @intCast(s.fronts.items.len);
                    if (sl.front[0] == none) s.slices.items[si].front = .{ fkey[0], fkey[1], at.? };
                    try s.fronts.appendSlice(gpa, s.next.items);
                    try s.fronts.append(gpa, .{ .node = .none, .summary = false, .step = none });
                }
                var end = at.?;
                while (s.fronts.items[end].node != .none) end += 1;
                const n_front = end - at.?;
                const edge_first: u32 = @intCast(s.edges.items.len);
                for (0..n_front) |fi| {
                    const e = s.fronts.items[at.? + (if (s.reverse) n_front - 1 - fi else fi)];
                    const step = Step.fromWord(e.step);
                    // The run one step below, made once per (run, step, inner
                    // place, class). A member's `side` for a transition out of a
                    // recast's inner reads the inner's place, never the inner.
                    try charge.reserve(gpa, .memo, 1);
                    const place: u32 = if (e.via == .none) none else v.shapes.place(e.via).int();
                    const bg = try s.below_at.getOrPut(gpa, .{ st.run, e.step, place, @intFromBool(e.summary) });
                    if (!bg.found_existing) {
                        bg.value_ptr.* = @intCast(s.belows.items.len);
                        const first: u32 = @intCast(s.runs.items.len);
                        for (0..st.len) |i| {
                            try charge.reserve(gpa, .inspection, 1);
                            const m = s.runs.items[st.first + i];
                            const c = s.run_ctxs.items[st.first + i];
                            const sm = (try Table.side(gpa, charge, v, m, e.via)) orelse continue;
                            const pm = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, sm, step)) orelse continue;
                            try s.runs.append(gpa, pm);
                            try s.run_ctxs.append(gpa, t.kappaChild(c, step));
                        }
                        const len: u32 = @intCast(s.runs.items.len - first);
                        try s.belows.append(gpa, .{ .first = first, .len = len, .run = try s.intern(first, len) });
                    }
                    const b = s.belows.items[bg.value_ptr.*];
                    const child = try s.stateOf(e.node, e.summary, s.states.items[id].msummary or Table.below(step), b);
                    try charge.reserve(gpa, .inspection, 1);
                    try s.edges.append(gpa, .{ .to = child, .step = e.step });
                }
                s.states.items[id].edge_first = edge_first;
                s.states.items[id].edge_len = @intCast(s.edges.items.len - edge_first);
            }

            fn edgesOf(s: *const Sigma, id: u32) []const Edge {
                const st = s.states.items[id];
                return s.edges.items[st.edge_first..][0..st.edge_len];
            }

            /// Resume pass 1 at the hits `ids`, then pass 2 over what that
            /// read: one resumed pass (§2.9 *Resumed passes read only new
            /// states*).
            fn expand(s: *Sigma, ids: []const u32) Error!void {
                var any = false;
                for (ids) |id| {
                    if (!s.states.items[id].hit) continue;
                    any = true;
                    s.states.items[id].hit = false;
                    // Its head was classified a sink: it is classified again
                    // with its edges.
                    s.states.items[id].classified = false;
                    try s.batch.append(s.gpa, id);
                    try s.readBody(id);
                    try s.drain();
                }
                if (!any) return;
                s.resumed += 1;
                if (!mutated("propagate-no-resumed-pass2")) try s.classify();
            }

            // ---- pass 2: the cycle bit -------------------------------------

            fn nodeIndex(s: *Sigma, n: NodeId) Error!u32 {
                const got = try s.node_at.getOrPut(s.gpa, .{n.int()});
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(s.nodes.items.len);
                    try s.nodes.append(s.gpa, .{ .node = n });
                }
                return got.value_ptr.*;
            }

            /// Pass 2 over the states read since it last ran (§2.9 *The cycle
            /// bit*): an earlier state is a sink whose component, cycle bit
            /// and bit set are kept, except where the new edges merge
            /// node-graph components that hold earlier states, whose bits are
            /// propagated again first (*A merge reopens kept sets*).
            fn classify(s: *Sigma) Error!void {
                const gpa = s.gpa;
                const charge = s.charge;
                if (s.batch.items.len == 0) return;
                // The node graph: one vertex per joined node, an edge per edge.
                for (s.batch.items) |id| {
                    const a = try s.nodeIndex(s.states.items[id].node);
                    if (!s.states.items[id].in_node_list) {
                        s.states.items[id].in_node_list = true;
                        s.states.items[id].node_next = s.nodes.items[a].head;
                        s.nodes.items[a].head = id;
                    }
                    for (s.edgesOf(id)) |e| {
                        try charge.reserve(gpa, .memo, 1);
                        const b = try s.nodeIndex(s.states.items[e.to].node);
                        const got = try s.node_edge_at.getOrPut(gpa, .{ a, b });
                        if (!got.found_existing) try s.node_edges.append(gpa, .{ a, b });
                    }
                }
                // Its components, taken once on the final graph of this pass.
                const n = s.nodes.items.len;
                try charge.reserve(gpa, .inspection, @intCast(n + s.node_edges.items.len));
                const head = try gpa.alloc(u32, n + 1);
                defer gpa.free(head);
                @memset(head, 0);
                for (s.node_edges.items) |e| head[e[0] + 1] += 1;
                for (1..n + 1) |i| head[i] += head[i - 1];
                const adj = try gpa.alloc(u32, s.node_edges.items.len);
                defer gpa.free(adj);
                const fill = try gpa.alloc(u32, n);
                defer gpa.free(fill);
                @memcpy(fill, head[0..n]);
                for (s.node_edges.items) |e| {
                    adj[fill[e[0]]] = e[1];
                    fill[e[0]] += 1;
                }
                const comp_of = try gpa.alloc(u32, n);
                defer gpa.free(comp_of);
                var members: std.ArrayList(u32) = .empty;
                defer members.deinit(gpa);
                var comp_first: std.ArrayList(u32) = .empty;
                defer comp_first.deinit(gpa);
                try tarjanNodes(gpa, head, adj, comp_of, &members, &comp_first);
                // Match each component with the one its nodes had: unchanged,
                // it keeps its id and bit indices; changed, it is numbered
                // again and its earlier states are reopened.
                var reopen: std.ArrayList(u32) = .empty;
                defer reopen.deinit(gpa);
                const n_comps = comp_first.items.len;
                const new_id = try gpa.alloc(u32, n_comps);
                defer gpa.free(new_id);
                for (0..n_comps) |ci| {
                    const lo = comp_first.items[ci];
                    const hi = if (ci + 1 < n_comps) comp_first.items[ci + 1] else @as(u32, @intCast(members.items.len));
                    const ms = members.items[lo..hi];
                    var nontrivial = ms.len > 1;
                    if (!nontrivial) for (adj[head[ms[0]]..head[ms[0] + 1]]) |b| {
                        if (b == ms[0]) nontrivial = true;
                    };
                    const prev = s.nodes.items[ms[0]].comp;
                    var same = prev != none and s.comps.items[prev].size == ms.len and s.comps.items[prev].nontrivial == nontrivial;
                    if (same) for (ms) |x| {
                        if (s.nodes.items[x].comp != prev) same = false;
                    };
                    if (same) {
                        new_id[ci] = prev;
                        continue;
                    }
                    const id: u32 = @intCast(s.comps.items.len);
                    try s.comps.append(gpa, .{ .size = @intCast(ms.len), .nontrivial = nontrivial });
                    new_id[ci] = id;
                    var earlier = false;
                    for (ms, 0..) |x, kidx| {
                        if (s.nodes.items[x].comp != none) earlier = true;
                        s.nodes.items[x].comp = id;
                        s.nodes.items[x].kidx = @intCast(kidx);
                    }
                    if (earlier and nontrivial and !mutated("propagate-no-merge-reopen")) try reopen.append(gpa, @intCast(ci));
                }
                // Reopen: the earlier states of each changed component,
                // bottom up along Σ's edges inside it.
                var olds: std.ArrayList(u32) = .empty;
                defer olds.deinit(gpa);
                for (reopen.items) |ci| {
                    const lo = comp_first.items[ci];
                    const hi = if (ci + 1 < n_comps) comp_first.items[ci + 1] else @as(u32, @intCast(members.items.len));
                    olds.clearRetainingCapacity();
                    for (members.items[lo..hi]) |x| {
                        var at = s.nodes.items[x].head;
                        while (at != none) : (at = s.states.items[at].node_next) {
                            if (s.states.items[at].classified) try olds.append(gpa, at);
                        }
                    }
                    try s.bitsOver(olds.items, true);
                }
                // The new states, with the earlier ones as sinks.
                try s.bitsOver(s.batch.items, false);
                s.batch.clearRetainingCapacity();
            }

            /// Tarjan over the states `ids` (their edges to states outside
            /// them read as sinks already classified), and each component's
            /// cycle bits, in the order Tarjan emits them: bottom up. For a
            /// reopened component the cycle bits must come out as before.
            fn bitsOver(s: *Sigma, ids: []const u32, reopened: bool) Error!void {
                const gpa = s.gpa;
                const charge = s.charge;
                // Membership of `ids` for this run.
                for (ids) |id| s.states.items[id].tj = 1;
                defer {
                    for (ids) |id| s.states.items[id].tj = 0;
                }
                const Frame = struct { id: u32, edge: u32 };
                var stack: std.ArrayList(Frame) = .empty;
                defer stack.deinit(gpa);
                var path: std.ArrayList(u32) = .empty;
                defer path.deinit(gpa);
                var scc: std.ArrayList(u32) = .empty;
                defer scc.deinit(gpa);
                var counter: u32 = 0;
                for (ids) |root| {
                    if (s.states.items[root].tj != 1) continue;
                    try stack.append(gpa, .{ .id = root, .edge = 0 });
                    s.states.items[root].tj_index = counter;
                    s.states.items[root].tj_low = counter;
                    counter += 1;
                    s.states.items[root].tj = 2;
                    try path.append(gpa, root);
                    while (stack.items.len > 0) {
                        const top = &stack.items[stack.items.len - 1];
                        const es = s.edgesOf(top.id);
                        if (top.edge < es.len) {
                            const to = es[top.edge].to;
                            top.edge += 1;
                            try charge.reserve(gpa, .inspection, 1);
                            const m = s.states.items[to].tj;
                            if (m == 1) {
                                s.states.items[to].tj_index = counter;
                                s.states.items[to].tj_low = counter;
                                counter += 1;
                                s.states.items[to].tj = 2;
                                try path.append(gpa, to);
                                try stack.append(gpa, .{ .id = to, .edge = 0 });
                            } else if (m == 2) {
                                const low = &s.states.items[top.id].tj_low;
                                low.* = @min(low.*, s.states.items[to].tj_index);
                            }
                            continue;
                        }
                        const id = top.id;
                        _ = stack.pop();
                        if (stack.items.len > 0) {
                            const parent = stack.items[stack.items.len - 1].id;
                            const low = &s.states.items[parent].tj_low;
                            low.* = @min(low.*, s.states.items[id].tj_low);
                        }
                        if (s.states.items[id].tj_low != s.states.items[id].tj_index) continue;
                        scc.clearRetainingCapacity();
                        while (path.pop()) |x| {
                            s.states.items[x].tj = 4;
                            try scc.append(gpa, x);
                            if (x == id) break;
                        }
                        try s.component(scc.items, reopened);
                        for (scc.items) |x| s.states.items[x].tj = 3;
                    }
                }
            }

            /// One component of Σ: its bit set, shared by its states, and each
            /// state's cycle bit.
            fn component(s: *Sigma, scc: []const u32, reopened: bool) Error!void {
                const gpa = s.gpa;
                const charge = s.charge;
                const x0 = scc[0];
                const node0 = s.node_at.get(.{s.states.items[x0].node.int()}).?;
                const kid = s.nodes.items[node0].comp;
                const k = s.comps.items[kid];
                var nontrivial = scc.len > 1;
                if (!nontrivial) for (s.edgesOf(x0)) |e| {
                    if (e.to == x0) nontrivial = true;
                };
                const words: u32 = if (k.nontrivial) (k.size + 63) / 64 else 0;
                const off: u32 = @intCast(s.bitwords.items.len);
                if (words > 0) {
                    try charge.reserve(gpa, .inspection, words);
                    try s.bitwords.appendNTimes(gpa, 0, words);
                    for (scc) |x| for (s.edgesOf(x)) |e| {
                        const to = s.states.items[e.to];
                        const tn = s.node_at.get(.{to.node.int()}).?;
                        if (s.nodes.items[tn].comp != kid) continue;
                        try charge.reserve(gpa, .inspection, words);
                        const kidx = s.nodes.items[tn].kidx;
                        s.bitwords.items[off + kidx / 64] |= @as(u64, 1) << @intCast(kidx % 64);
                        // A state of this component carries the set being made.
                        if (to.tj == 4 or to.bits_len == 0) continue;
                        if (std.debug.runtime_safety and to.bits_comp != kid)
                            std.debug.panic("ownership v2: propagate reads a bit set of another component (§2.9 *A merge reopens kept sets*)", .{});
                        for (0..words) |w| s.bitwords.items[off + w] |= s.bitwords.items[to.bits_off + w];
                    };
                }
                for (scc) |x| {
                    const st = &s.states.items[x];
                    const kidx = s.nodes.items[s.node_at.get(.{st.node.int()}).?].kidx;
                    const cyclic = nontrivial or (words > 0 and s.bitwords.items[off + kidx / 64] >> @intCast(kidx % 64) & 1 == 1);
                    if (std.debug.runtime_safety and reopened and st.cyclic != cyclic)
                        std.debug.panic("ownership v2: a reopened component changed a state's cycle bit (§2.9 *A merge reopens kept sets*)", .{});
                    st.cyclic = cyclic;
                    st.classified = true;
                    st.bits_comp = kid;
                    st.bits_off = off;
                    st.bits_len = words;
                }
            }
        };

        /// Tarjan's components of a graph in CSR form (`head`, `adj`), on an
        /// explicit stack: `members` the vertices by component, in the order
        /// emitted, `comp_first` where each begins.
        fn tarjanNodes(gpa: Allocator, head: []const u32, adj: []const u32, comp_of: []u32, members: *std.ArrayList(u32), comp_first: *std.ArrayList(u32)) Allocator.Error!void {
            const n = comp_of.len;
            const index = try gpa.alloc(u32, n);
            defer gpa.free(index);
            const low = try gpa.alloc(u32, n);
            defer gpa.free(low);
            const on = try gpa.alloc(bool, n);
            defer gpa.free(on);
            @memset(index, none);
            @memset(on, false);
            @memset(comp_of, none);
            const Frame = struct { v: u32, e: u32 };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var path: std.ArrayList(u32) = .empty;
            defer path.deinit(gpa);
            var counter: u32 = 0;
            for (0..n) |root| {
                if (index[root] != none) continue;
                index[root] = counter;
                low[root] = counter;
                counter += 1;
                on[root] = true;
                try path.append(gpa, @intCast(root));
                try stack.append(gpa, .{ .v = @intCast(root), .e = head[root] });
                while (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    if (top.e < head[top.v + 1]) {
                        const w = adj[top.e];
                        top.e += 1;
                        if (index[w] == none) {
                            index[w] = counter;
                            low[w] = counter;
                            counter += 1;
                            on[w] = true;
                            try path.append(gpa, w);
                            try stack.append(gpa, .{ .v = w, .e = head[w] });
                        } else if (on[w]) low[top.v] = @min(low[top.v], index[w]);
                        continue;
                    }
                    const x = top.v;
                    _ = stack.pop();
                    if (stack.items.len > 0) {
                        const p = stack.items[stack.items.len - 1].v;
                        low[p] = @min(low[p], low[x]);
                    }
                    if (low[x] != index[x]) continue;
                    try comp_first.append(gpa, @intCast(members.items.len));
                    while (path.pop()) |y| {
                        on[y] = false;
                        comp_of[y] = @intCast(comp_first.items.len - 1);
                        try members.append(gpa, y);
                        if (y == x) break;
                    }
                }
            }
        }

        // ---- pass 3: positions by their set of states ------------------------

        const SetInfo = struct { first: u32 = none, len: u32 = 0, status: enum(u8) { new, open, done } = .new, pos: Kappas = .none, kids_first: u32 = 0, kids_len: u32 = 0 };
        const Kid = struct { step: u32, set: u32 };

        const Sets = struct {
            cons: Ids.FixedDict(2) = .{},
            info: std.ArrayList(SetInfo) = .empty,
            members: std.ArrayList(u32) = .empty,
            kids: std.ArrayList(Kid) = .empty,
            open: u32 = 0,
            folds: u32 = 0,

            fn deinit(x: *Sets, gpa: Allocator) void {
                x.cons.deinit(gpa);
                x.info.deinit(gpa);
                x.members.deinit(gpa);
                x.kids.deinit(gpa);
            }

            /// `ids`, sorted and distinct, interned as a cons list: a record
            /// per state (§2.9 *Cost*, *It ends loudly*).
            fn intern(x: *Sets, gpa: Allocator, charge: Charge, ids: []const u32) Error!u32 {
                std.debug.assert(ids.len > 0);
                var id: u32 = none;
                var r = ids.len;
                while (r > 0) {
                    r -= 1;
                    try charge.reserve(gpa, .memo, 1);
                    const got = try x.cons.getOrPut(gpa, .{ ids[r], id });
                    if (!got.found_existing) {
                        got.value_ptr.* = got.index;
                        try x.info.append(gpa, .{});
                    }
                    id = got.value_ptr.*;
                }
                if (x.info.items[id].first == none) {
                    x.info.items[id].first = @intCast(x.members.items.len);
                    x.info.items[id].len = @intCast(ids.len);
                    try x.members.appendSlice(gpa, ids);
                }
                return id;
            }

            fn of(x: *const Sets, id: u32) []const u32 {
                const i = x.info.items[id];
                return x.members.items[i.first..][0..i.len];
            }
        };

        /// One call by the rule (§2.9 *Fold first*, *The rule*).
        fn rule(t: *Table, gpa: Allocator, charge: Charge, in: *const Input, memo: bool, reverse: bool, dump: bool) Error!Kappas {
            if (mutated("propagate-no-fold-first")) {
                if (try reference(t, gpa, charge, in, reverse)) |r| return r;
            }
            const call = t.prop_calls;
            t.prop_calls += 1;
            var s: Sigma = .{ .t = t, .gpa = gpa, .charge = charge, .in = in, .memo = memo, .reverse = reverse, .kept_call = in.mode == .alternatives and in.members.len == 1 };
            defer s.deinit();
            // Pass 1, and pass 2 over it.
            try s.runs.appendSlice(gpa, in.members);
            try s.run_ctxs.appendSlice(gpa, in.ctxs);
            const root_run = try s.intern(0, @intCast(in.members.len));
            const root = try s.stateOf(in.joined, in.at_summary, in.member_summary, .{ .first = 0, .len = @intCast(in.members.len), .run = root_run });
            try s.drain();
            try s.classify();
            // Pass 3, post-order on an explicit stack.
            var sets: Sets = .{};
            defer sets.deinit(gpa);
            const root_set = try sets.intern(gpa, charge, &.{root});
            var pairs: std.ArrayList([2]u32) = .empty;
            defer pairs.deinit(gpa);
            var ids: std.ArrayList(u32) = .empty;
            defer ids.deinit(gpa);
            var hits: std.ArrayList(u32) = .empty;
            defer hits.deinit(gpa);
            // The clean singletons built here, written to the clean memo once
            // the call has finished.
            const Candidate = struct { key: [3]u32, set: u32 };
            var candidates: std.ArrayList(Candidate) = .empty;
            defer candidates.deinit(gpa);
            var gen: u32 = 0;
            const Work = struct { set: u32, build: bool };
            var work: std.ArrayList(Work) = .empty;
            defer work.deinit(gpa);
            try work.append(gpa, .{ .set = root_set, .build = false });
            while (work.pop()) |w| {
                const info = sets.info.items[w.set];
                if (info.status == .done) continue;
                if (!w.build) {
                    // A clean singleton with a hit links the hit.
                    const ms = sets.of(w.set);
                    if (ms.len == 1 and s.states.items[ms[0]].hit) {
                        sets.info.items[w.set].pos = try openPos(&s, ms, &.{}, &sets);
                        sets.info.items[w.set].status = .done;
                        sets.open += 1;
                        continue;
                    }
                    // A hit that shares a set is expanded (pass 1 resumed).
                    hits.clearRetainingCapacity();
                    for (ms) |x| if (s.states.items[x].hit) try hits.append(gpa, x);
                    if (hits.items.len > 0) try s.expand(hits.items);
                    var fold = false;
                    for (sets.of(w.set)) |x| fold = fold or s.states.items[x].cyclic;
                    if (fold) {
                        gen += 1;
                        sets.info.items[w.set].pos = try foldPos(&s, sets.of(w.set), gen);
                        sets.info.items[w.set].status = .done;
                        sets.folds += 1;
                        continue;
                    }
                    // The sets one step down, one per step.
                    pairs.clearRetainingCapacity();
                    for (sets.of(w.set)) |x| for (s.edgesOf(x)) |e| try pairs.append(gpa, .{ e.step, e.to });
                    try charge.reserve(gpa, .inspection, Table.sortCost(pairs.items.len));
                    std.mem.sort([2]u32, pairs.items, {}, lessPair);
                    const kids_first: u32 = @intCast(sets.kids.items.len);
                    var i: usize = 0;
                    while (i < pairs.items.len) {
                        const step = pairs.items[i][0];
                        ids.clearRetainingCapacity();
                        while (i < pairs.items.len and pairs.items[i][0] == step) : (i += 1) {
                            if (ids.items.len == 0 or ids.items[ids.items.len - 1] != pairs.items[i][1]) try ids.append(gpa, pairs.items[i][1]);
                        }
                        try charge.reserve(gpa, .inspection, 1);
                        try sets.kids.append(gpa, .{ .step = step, .set = try sets.intern(gpa, charge, ids.items) });
                    }
                    sets.info.items[w.set].kids_first = kids_first;
                    sets.info.items[w.set].kids_len = @intCast(sets.kids.items.len - kids_first);
                    sets.info.items[w.set].status = .open;
                    try work.append(gpa, .{ .set = w.set, .build = true });
                    for (sets.kids.items[kids_first..]) |kid| switch (sets.info.items[kid.set].status) {
                        .new => try work.append(gpa, .{ .set = kid.set, .build = false }),
                        // Below an open set no set is open: its own descendant
                        // would hold a cyclic state, so it is a fold.
                        .open => std.debug.panic("ownership v2: propagate call {d}: an open set is its own descendant (§2.9 *Fold first*)", .{call}),
                        .done => {},
                    };
                    continue;
                }
                const kids = sets.kids.items[info.kids_first..][0..info.kids_len];
                const ms = sets.of(w.set);
                sets.info.items[w.set].pos = try openPos(&s, ms, kids, &sets);
                sets.info.items[w.set].status = .done;
                sets.open += 1;
                if (memo and ms.len == 1) {
                    const st = s.states.items[ms[0]];
                    if (st.clean and !st.linked) try candidates.append(gpa, .{ .key = s.memoKey(st), .set = w.set });
                }
            }
            // The call has finished: each clean state built alone at an open
            // position is that position's snapshot wherever it is met again.
            for (candidates.items) |c| {
                try charge.reserve(gpa, .memo, 1);
                (try t.memo_prop.getOrPut(gpa, c.key)).value_ptr.* = sets.info.items[c.set].pos.int();
            }
            if (memo) t.prop_stats = .{ .states = @intCast(s.states.items.len), .edges = @intCast(s.edges.items.len), .open = sets.open, .folds = sets.folds, .resumed = s.resumed };
            if (dump) std.debug.print("propagate {d}: {d} states, {d} edges, {d} open sets, {d} fold sets, {d} resumed\n", .{ call, s.states.items.len, s.edges.items.len, sets.open, sets.folds, s.resumed });
            return t.kappaMerge(gpa, charge, in.out, sets.info.items[root_set].pos);
        }

        fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }

        /// An open set's position: its states' kept entries and then their
        /// entries, joined per node; a link per step to the set one step
        /// down; its states' linked snapshots and a hit merged in.
        fn openPos(s: *Sigma, ms: []const u32, kids: []const Kid, sets: *const Sets) Error!Kappas {
            const t = s.t;
            const gpa = s.gpa;
            const charge = s.charge;
            var here: u32 = none;
            for (ms) |x| {
                const st = s.states.items[x];
                if (!st.has_kept or st.kept == .none) continue;
                try charge.reserve(gpa, .inspection, 1);
                here = try t.mapUnion(gpa, charge, .cond, here, t.position(st.kept).here);
            }
            for (ms) |x| {
                const st = s.states.items[x];
                if (st.out == none) continue;
                try charge.reserve(gpa, .inspection, 1);
                const old = t.mapGet(here, st.node.int());
                const val = if (old) |o| try t.join(gpa, charge, .from(o), .from(st.out)) else CondId.from(st.out);
                try t.keyed(gpa, charge, st.node);
                here = try t.mapPut(gpa, charge, here, st.node.int(), val.int());
            }
            var links: u32 = none;
            for (kids) |kid| {
                const p = sets.info.items[kid.set].pos;
                if (p != .none) links = try t.mapPut(gpa, charge, links, kid.step, p.int());
            }
            var pos = try t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = 0 });
            for (ms) |x| {
                const st = s.states.items[x];
                if (st.linked) pos = try t.kappaMerge(gpa, charge, pos, st.link);
                if (st.hit) pos = try t.kappaMerge(gpa, charge, pos, st.hit_at);
            }
            return pos;
        }

        /// A fold's position (§2.9 *Fold first*, rule 3): the entries of every
        /// state of the set's closure in Σ joined per node, the steps of every
        /// edge of it, and every linked snapshot in it merged. A hit in it is
        /// expanded first.
        fn foldPos(s: *Sigma, ms: []const u32, gen: u32) Error!Kappas {
            const t = s.t;
            const gpa = s.gpa;
            const charge = s.charge;
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(gpa);
            for (ms) |x| if (s.states.items[x].mark != gen) {
                s.states.items[x].mark = gen;
                try queue.append(gpa, x);
            };
            var here: u32 = none;
            var links: u32 = none;
            var merged: std.ArrayList(Kappas) = .empty;
            defer merged.deinit(gpa);
            var resumed = false;
            var i: usize = 0;
            while (i < queue.items.len) : (i += 1) {
                const x = queue.items[i];
                if (s.states.items[x].hit) {
                    // Pass 1 resumed here; pass 2 runs once the closure is read.
                    s.states.items[x].hit = false;
                    s.states.items[x].classified = false;
                    try s.batch.append(gpa, x);
                    try s.readBody(x);
                    try s.drain();
                    resumed = true;
                }
                try charge.reserve(gpa, .inspection, 1);
                const st = s.states.items[x];
                if (st.linked) try merged.append(gpa, st.link);
                if (st.out != none) {
                    const old = t.mapGet(here, st.node.int());
                    const val = if (old) |o| try t.join(gpa, charge, .from(o), .from(st.out)) else CondId.from(st.out);
                    try t.keyed(gpa, charge, st.node);
                    here = try t.mapPut(gpa, charge, here, st.node.int(), val.int());
                }
                for (s.edgesOf(x)) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    links = try t.mapPut(gpa, charge, links, e.step, 0);
                    if (s.states.items[e.to].mark == gen) continue;
                    s.states.items[e.to].mark = gen;
                    try queue.append(gpa, e.to);
                }
            }
            if (resumed) {
                s.resumed += 1;
                if (!mutated("propagate-no-resumed-pass2")) try s.classify();
            }
            var pos = try t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = Table.fold_exact });
            for (merged.items) |m| pos = try t.kappaMerge(gpa, charge, pos, m);
            return pos;
        }

        // ---- the reference ---------------------------------------------------

        /// §2.9's reference semantics: frames `(state, position, folded,
        /// route)`, each met once. Null past `reference_cap` frames.
        fn reference(t: *Table, gpa: Allocator, charge: Charge, in: *const Input, reverse: bool) Error!?Kappas {
            var s: Sigma = .{ .t = t, .gpa = gpa, .charge = charge, .in = in, .memo = false, .reverse = reverse, .kept_call = in.mode == .alternatives and in.members.len == 1 };
            defer s.deinit();
            try s.runs.appendSlice(gpa, in.members);
            try s.run_ctxs.appendSlice(gpa, in.ctxs);
            const root_run = try s.intern(0, @intCast(in.members.len));
            const root = try s.stateOf(in.joined, in.at_summary, in.member_summary, .{ .first = 0, .len = @intCast(in.members.len), .run = root_run });
            try s.drain();
            const PathRec = struct { parent: u32, step: u32 };
            var paths: std.ArrayList(PathRec) = .empty;
            defer paths.deinit(gpa);
            var path_index: Ids.FixedDict(2) = .{};
            defer path_index.deinit(gpa);
            try paths.append(gpa, .{ .parent = none, .step = none });
            var fold_at: std.ArrayList(bool) = .empty;
            defer fold_at.deinit(gpa);
            try fold_at.append(gpa, false);
            var fold_steps: std.ArrayList([2]u32) = .empty;
            defer fold_steps.deinit(gpa);
            const Write = struct { path: u32, node: NodeId, k: CondId };
            var outs: std.ArrayList(Write) = .empty;
            defer outs.deinit(gpa);
            const Linked = struct { path: u32, at: Kappas };
            var kept: std.ArrayList(Linked) = .empty;
            defer kept.deinit(gpa);
            var linked: std.ArrayList(Linked) = .empty;
            defer linked.deinit(gpa);
            const Frame = struct { state: u32, path: u32, folded: bool, route: u32 };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var visited: Ids.FixedDict(4) = .{};
            defer visited.deinit(gpa);
            try stack.append(gpa, .{ .state = root, .path = 0, .folded = false, .route = try t.mapPut(gpa, charge, none, in.joined.int(), 0) });
            var frames: u32 = 0;
            while (stack.pop()) |f| {
                try charge.reserve(gpa, .memo, 1);
                const got = try visited.getOrPut(gpa, .{ f.state, f.path, @intFromBool(f.folded), f.route });
                if (got.found_existing) continue;
                got.value_ptr.* = 1;
                frames += 1;
                if (frames > reference_cap) return null;
                const st = s.states.items[f.state];
                if (st.out != none) try outs.append(gpa, .{ .path = f.path, .node = st.node, .k = .from(st.out) });
                if (st.linked) {
                    try linked.append(gpa, .{ .path = f.path, .at = st.link });
                    continue;
                }
                if (st.has_kept and !f.folded) try kept.append(gpa, .{ .path = f.path, .at = st.kept });
                const es = s.edgesOf(f.state);
                for (0..es.len) |ei| {
                    const e = es[if (reverse) es.len - 1 - ei else ei];
                    const c = s.states.items[e.to].node;
                    var next: Frame = .{ .state = e.to, .path = f.path, .folded = true, .route = f.route };
                    const back = t.mapGet(f.route, c.int());
                    if (!f.folded) {
                        if (back) |q| {
                            next.path = q;
                            fold_at.items[q] = true;
                        } else {
                            try charge.reserve(gpa, .memo, 1);
                            const pg = try path_index.getOrPut(gpa, .{ f.path, e.step });
                            if (!pg.found_existing) {
                                pg.value_ptr.* = @intCast(paths.items.len);
                                try paths.append(gpa, .{ .parent = f.path, .step = e.step });
                                try fold_at.append(gpa, false);
                            }
                            next.path = pg.value_ptr.*;
                            next.folded = false;
                            next.route = try t.mapPut(gpa, charge, f.route, c.int(), next.path);
                        }
                    } else if (back) |q| {
                        // A folded frame looks its child up as an unfolded one does,
                        // and moves to a fold above it.
                        var up = paths.items[f.path].parent;
                        while (up != none and up != q) up = paths.items[up].parent;
                        if (up == q) {
                            next.path = q;
                            fold_at.items[q] = true;
                        }
                    }
                    if (next.folded) {
                        try charge.reserve(gpa, .inspection, 1);
                        try fold_steps.append(gpa, .{ next.path, e.step });
                    }
                    try stack.append(gpa, next);
                }
            }
            // The output, as the walk before the rule built it: each position
            // below a fold is the highest fold on its way.
            const n = paths.items.len;
            const owner = try gpa.alloc(u32, n);
            defer gpa.free(owner);
            for (paths.items, 0..) |p, i| {
                owner[i] = @intCast(i);
                if (p.parent == none) continue;
                const up = owner[p.parent];
                if (up != p.parent) owner[i] = up else if (fold_at.items[p.parent]) owner[i] = p.parent;
            }
            const here = try gpa.alloc(u32, n);
            defer gpa.free(here);
            @memset(here, none);
            const fold_links = try gpa.alloc(u32, n);
            defer gpa.free(fold_links);
            @memset(fold_links, none);
            for (fold_steps.items) |x| {
                const at = owner[x[0]];
                fold_links[at] = try t.mapPut(gpa, charge, fold_links[at], x[1], 0);
            }
            for (paths.items, 0..) |p, pi| if (p.parent != none and owner[pi] != pi) {
                fold_links[owner[pi]] = try t.mapPut(gpa, charge, fold_links[owner[pi]], p.step, 0);
            };
            for (kept.items) |x| {
                if (owner[x.path] != x.path or fold_at.items[x.path] or x.at == .none) continue;
                here[x.path] = try t.mapUnion(gpa, charge, .cond, here[x.path], t.position(x.at).here);
            }
            for (outs.items) |w| {
                const at = owner[w.path];
                const old = t.mapGet(here[at], w.node.int());
                const val = if (old) |o| try t.join(gpa, charge, .from(o), w.k) else w.k;
                try t.keyed(gpa, charge, w.node);
                here[at] = try t.mapPut(gpa, charge, here[at], w.node.int(), val.int());
            }
            const link_head = try gpa.alloc(u32, n);
            defer gpa.free(link_head);
            @memset(link_head, none);
            const link_next = try gpa.alloc(u32, linked.items.len);
            defer gpa.free(link_next);
            for (linked.items, 0..) |l, li| {
                link_next[li] = link_head[owner[l.path]];
                link_head[owner[l.path]] = @intCast(li);
            }
            const pos = try gpa.alloc(Kappas, n);
            defer gpa.free(pos);
            @memset(pos, .none);
            const links = try gpa.alloc(u32, n);
            defer gpa.free(links);
            @memset(links, none);
            var i = n;
            while (i > 0) {
                i -= 1;
                if (owner[i] != i) continue;
                pos[i] = try t.makePos(gpa, charge, .{ .here = here[i], .links = if (fold_at.items[i]) fold_links[i] else links[i], .fold = if (fold_at.items[i]) Table.fold_exact else 0 });
                var li = link_head[i];
                while (li != none) : (li = link_next[li]) pos[i] = try t.kappaMerge(gpa, charge, pos[i], linked.items[li].at);
                const p = paths.items[i];
                if (p.parent != none and pos[i] != .none) links[p.parent] = try t.mapPut(gpa, charge, links[p.parent], p.step, pos[i].int());
            }
            return try t.kappaMerge(gpa, charge, in.out, pos[0]);
        }

        /// Whether `n` may key the join memo: a finite rank of at least 1, so
        /// no walk below it meets it, or anything above it, again.
        fn memoRank(gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!bool {
            const r = try v.shapes.rank(gpa, charge.account, n);
            return r >= 1 and r != Shape.Table.rank_unbounded;
        }

        /// Whether `joined` is `m` with nothing but empty leaves: a `via` DAG
        /// (`union` for alternatives, `positions` for elements) whose every
        /// other side is an empty leaf. As elements `m` must stand once: twice
        /// is two positions. A record per node.
        fn joinOfOne(gpa: Allocator, charge: Charge, v: View, joined: NodeId, m: NodeId, via: Shape.Kind) Error!bool {
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, joined);
            var found: u32 = 0;
            while (stack.pop()) |x| {
                try charge.reserve(gpa, .inspection, 1);
                if (x == m) {
                    found += 1;
                    continue;
                }
                if (try v.shapes.isNothing(gpa, charge.account, x)) continue;
                const xk = v.shapes.kind(x);
                // Alternatives are joined as a `choice` or a `union` (§2.3).
                if (xk != via and !(via == .@"union" and xk == .choice)) return false;
                const d = v.shapes.get(x);
                try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
            }
            return found == 1 or (found > 1 and via == .@"union");
        }
    };
}
