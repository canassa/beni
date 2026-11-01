//! L5: κ reads of `Cond.Table` (`docs/design/ownership-v2.md` §2.9, §2.11
//! *κ across a call*, §3.4): the read machine (`kappaOf`) through views and
//! the crossing (`crossAt`, `eqOn`, `diffKeys`), the κ derived from a
//! node's cells, the apart aggregates and the path-multiset primitive,
//! `sep`, `apart`, `deep`, `lower`, the observable frontier and `kappaLeq`.
//! `Of(Table)` is this part's methods over the table `Cond.zig` declares;
//! `Cond.zig` binds them by name (§5).
//!
//! Obligations kept here: O13 (`apart`, `lower`) and O15's second half (a
//! union's κ is its sides' join, derived at the read and never stale), as
//! `Cond.zig`'s header states them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const stamped = @import("../stamped.zig");
const full_cross_check = @import("ownership_options").full_cross_check;
const CondId = Ids.CondId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const NodeId = Ids.NodeId;
const Charge = Ids.Charge;
const Error = Ids.ChargeError;
const Step = Shape.Step;
const CondAlgebra = @import("CondAlgebra.zig");
const yes = CondAlgebra.yes;
const shared = CondAlgebra.shared;
const lost = CondAlgebra.lost;
const Kappa = @import("Kappa.zig");
const Kappas = Kappa.Kappas;

/// S4's answer for two `taken` elements of one container from distinct
/// splits (§2.2, *Traversals*): apart under the container's κ when both are
/// `single` and of one entry prefix, else null (`lost`).
pub const Traversal = struct { ctx: *anyopaque, apart: *const fn (ctx: *anyopaque, container: CellId, a: CellId, b: CellId) ?CondId };

/// The tables `kappaOf` and its callers read; passed down, never stored.
pub const View = struct { shapes: *Shape.Table, cells: *Cell.Table, places: *Cell.Places };

/// One stored cell of a construction, with its pair's approximation.
pub const Item = struct { cell: CellId, approx: bool };

/// One arrival key of a certificate instantiated at a hypothesis node (§2.9
/// rule 4, #1485): the key, one of its images in the caller, whether that
/// image is approximate, and the key's group (`none_int`: in no group, so
/// its images add as before).
pub const HypKey = struct { key: CellId, image: CellId, approx: bool, group: u32 };

/// The environment a class's own knot is read under (`Cond.Table.hyp_knots`):
/// its cells are its keys.
pub const identity_env: u32 = Ids.none_int - 1;

/// The fold certificate's readers (§8 slice 4, *The fold certificate,
/// specified*, #1485), over the views calls answer (`Calls.Views`).
pub const Hyp = struct {
    ctx: *anyopaque,
    /// The environment of `v` when it is a hypothesis node: a view of a
    /// class of the group being solved, or of a settled certified class.
    envOf: *const fn (ctx: *anyopaque, shapes: *Shape.Table, v: NodeId) ?u32,
    /// The certificate's arrival keys `cells` (a class of the template) at
    /// environment `env`, each key's images by §2.9 rule 4, into `out`.
    keys: *const fn (ctx: *anyopaque, gpa: Allocator, charge: Charge, env: u32, cells: SetId, out: *std.ArrayList(HypKey)) Error!void,
    /// The `res` and snapshot of the class environment `env` names: its κ at a class
    /// `K` is the certificate's condition there (§8 slice 4, *What is
    /// proved*, #1485).
    class: *const fn (ctx: *anyopaque, env: u32) HypClass,
};

/// What `Hyp.class` answers: a class's `res` and its snapshot.
pub const HypClass = struct { res: NodeId, kappas: Kappas };

/// The part of `Cond.Table` this file holds, over the table `Cond.zig` declares.
pub fn Of(comptime Table: type) type {
    return struct {
        const fails = Table.fails;
        const matches = Table.matches;

        // ---- κ reads, and the crossing (§2.11 *κ across a call*) -------------------------

        /// A crossing carried down a walk (*Carried along the walk*): the
        /// re-rooted actual's region and the position `R_Q` the walk reads it at.
        /// `epoch`: the `base_epoch` its `eqOn` held at; once that moves, the pair
        /// carries nothing (*A read in flight*).
        pub const Pair = struct { region: SetId, r: Kappas, epoch: u32 };

        /// What a union, choice or positions DAG holds besides its κ, a function
        /// of the node alone (*`dagKappa`*): whether a recast is below it (a view
        /// of a recast included), whether a positions node is, and the cells the
        /// positions nodes below it repeat (`dups`, `dups_approx` those one of
        /// whose occurrences is approximate), as sets.
        pub const DagFacts = struct { approx: bool = false, positions: bool = false, dups: SetId = .none, dups_approx: SetId = .none };

        pub fn isDag(k: Shape.Kind) bool {
            return k == .@"union" or k == .choice or k == .positions;
        }

        /// A memo entry a crossed read made, written once the read is known not
        /// to have seen `base_epoch` move (*A read in flight*).
        pub const Pending = struct { which: enum(u8) { dag, inner, deep }, key: [3]u32, value: u32 };

        pub fn memoPut(t: *Table, gpa: Allocator, which: @FieldType(Pending, "which"), key: [3]u32, value: u32, crossed: bool) Error!void {
            if (t.no_memo) return;
            if (crossed) return t.pending.append(gpa, .{ .which = which, .key = key, .value = value });
            const m = switch (which) {
                .dag => &t.memo_dag,
                .inner => &t.memo_inner,
                .deep => &t.memo_deep,
            };
            (try m.getOrPut(gpa, key)).value_ptr.* = value;
            if (which != .deep) (try t.home_read.getOrPut(gpa, .{ @backingInt(which), key[1], key[2] })).value_ptr.* = key[0];
        }

        /// `memoGet`, or the entry a read of the same node and class stored at
        /// the last position it was read at, where that position reads alike
        /// on the node's region (`readsAlike`): the read is a function of what
        /// its one position stores on the region (§2.11 *Part 2*, *A read at
        /// another position*). The entry is then stored under `key` too. Only
        /// an entry made with no crossing is a home (`memoPut`).
        pub fn memoAt(t: *Table, gpa: Allocator, charge: Charge, v: View, which: @FieldType(Pending, "which"), key: [3]u32) Error!?u32 {
            if (t.memoGet(which, key)) |hit| return hit;
            if (t.no_memo) return null;
            const home = t.home_read.get(.{ @backingInt(which), key[1], key[2] }) orelse return null;
            if (home == key[0]) return null;
            const hit = t.memoGet(which, .{ home, key[1], key[2] }) orelse return null;
            if (!try t.readsAlike(gpa, charge, v, .from(key[0]), .from(home), try v.shapes.region(gpa, charge.account, .from(key[1])))) return null;
            try t.memoPut(gpa, which, key, hit, false);
            return hit;
        }

        /// Whether a read at position `c` of a node of `region` reads what one
        /// at `h` reads (*A read at another position*): one fold kind, and no
        /// key of the region that the two entry maps bind differently
        /// (`diffKeys`, memoised per pair of map nodes). A growth task (§4.1).
        pub fn readsAlike(t: *Table, gpa: Allocator, asking: Charge, v: View, c: Kappas, h: Kappas, region: SetId) Error!bool {
            if (c == h) return true;
            const task = try asking.account.enter(gpa, null);
            defer asking.account.leave(task);
            const charge: Charge = .growth(asking.account);
            const pc = t.position(c);
            const ph = t.position(h);
            if (pc.fold != ph.fold) return false;
            const d = try t.diffKeys(gpa, charge, v, pc.here, ph.here);
            if (d == .none) return true;
            return !try v.shapes.node_sets.intersectsMemo(gpa, charge, &v.shapes.memo_node_meet, d, region);
        }

        pub fn memoGet(t: *const Table, which: @FieldType(Pending, "which"), key: [3]u32) ?u32 {
            if (t.no_memo) return null;
            const v = switch (which) {
                .dag => t.memo_dag.get(key),
                .inner => t.memo_inner.get(key),
                .deep => t.memo_deep.get(key),
            } orelse return null;
            // A read with no crossing (a redo, the cross-check) takes no entry a
            // crossing made (*A read in flight*).
            if (t.no_cross) if (t.memo_crossed.get(.{ @backingInt(which), key[0], key[1], key[2] })) |c| if (c == v) return null;
            return v;
        }

        /// The pending entries from `from` on: kept, or dropped with the read.
        pub fn settle(t: *Table, gpa: Allocator, from: usize, kept: bool) Error!void {
            if (kept) for (t.pending.items[from..]) |p| {
                const m = switch (p.which) {
                    .dag => &t.memo_dag,
                    .inner => &t.memo_inner,
                    .deep => &t.memo_deep,
                };
                (try m.getOrPut(gpa, p.key)).value_ptr.* = p.value;
                (try t.memo_crossed.getOrPut(gpa, .{ @backingInt(p.which), p.key[0], p.key[1], p.key[2] })).value_ptr.* = p.value;
            };
            t.pending.shrinkRetainingCapacity(from);
        }

        /// The facts of a DAG node (`DagFacts`), memoised per node: post-order on
        /// an explicit stack over its union, choice and positions sides (a view
        /// side is read at its answer as one position, not walked), a node met
        /// again while open adding nothing and keeping no memo. A record per node
        /// and repeated cell.
        pub fn dagFacts(t: *Table, gpa: Allocator, charge: Charge, v: View, root: NodeId) Error!DagFacts {
            try charge.reserve(gpa, .memo, 1);
            if (t.dag_facts.get(root)) |i| return t.facts.items[i];
            const Frame = struct { node: NodeId, expanded: bool };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var local: stamped.Column(NodeId, DagFacts) = .{};
            defer local.deinit(gpa);
            var open: stamped.Column(NodeId, void) = .{};
            defer open.deinit(gpa);
            var cyclic = false;
            try stack.append(gpa, .{ .node = root, .expanded = false });
            while (stack.pop()) |f| {
                const n = f.node;
                if (local.contains(n)) continue;
                if (!isDag(v.shapes.kind(n))) {
                    // A recast, or a view of one, is approximate (§2.11).
                    const nk = v.shapes.kind(n);
                    const approx = nk == .recast or (nk == .view and v.shapes.kind(try v.shapes.force(gpa, charge.account, n)) == .recast);
                    try local.put(gpa, n, .{ .approx = approx });
                    continue;
                }
                if (t.dag_facts.get(n)) |i| {
                    try local.put(gpa, n, t.facts.items[i]);
                    continue;
                }
                const d = v.shapes.get(n);
                if (!f.expanded) {
                    if (open.contains(n)) {
                        cyclic = true;
                        continue;
                    }
                    try open.put(gpa, n, {});
                    try stack.appendSlice(gpa, &.{ .{ .node = n, .expanded = true }, .{ .node = .from(d.a), .expanded = false }, .{ .node = .from(d.b), .expanded = false } });
                    continue;
                }
                open.remove(n);
                const fa = local.get(.from(d.a)) orelse DagFacts{};
                const fb = local.get(.from(d.b)) orelse DagFacts{};
                var out: DagFacts = .{
                    .approx = fa.approx or fb.approx,
                    .positions = fa.positions or fb.positions or d.kind == .positions,
                    .dups = try v.cells.sets.unionWith(gpa, charge, fa.dups, fb.dups),
                    .dups_approx = try v.cells.sets.unionWith(gpa, charge, fa.dups_approx, fb.dups_approx),
                };
                if (d.kind == .positions) {
                    // The cells both sides hold, as sets: one approximate where the
                    // node is (a recast below) or either occurrence is.
                    const both = try v.cells.sets.intersection(gpa, charge, try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, .from(d.a)), try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, .from(d.b)));
                    out.dups = try v.cells.sets.unionWith(gpa, charge, out.dups, both);
                    out.dups_approx = try v.cells.sets.unionWith(gpa, charge, out.dups_approx, if (out.approx) both else try t.cellPart(gpa, charge, v.cells, v.places, .approx, both));
                }
                try local.put(gpa, n, out);
                if (!cyclic) {
                    try charge.reserve(gpa, .memo, 1);
                    try t.dag_facts.put(gpa, n, @intCast(t.facts.items.len));
                    try t.facts.append(gpa, out);
                }
            }
            return local.get(root).?;
        }

        /// A DAG node's read once its sides' join `inner` is known: at a summary
        /// position, a positions node below making it one, the leaf rule over its
        /// cells and the repeats its positions nodes found (*`dagKappa`*).
        pub fn dagRoot(t: *Table, gpa: Allocator, charge: Charge, v: View, root: NodeId, at_summary: bool, inner: CondId) Error!CondId {
            const facts = try t.dagFacts(gpa, charge, v, root);
            if (!at_summary and !facts.positions) return inner;
            return t.@"and"(gpa, charge, inner, try t.derivedCells(gpa, charge, v, try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, root), true, facts.dups, facts.dups_approx));
        }

        /// What is stored for view `n` along its chain (§2.11 *κ at a view*):
        /// the entries under the view and every view its chain passes through,
        /// joined as stored values, the answer's left to the reader. Memoised
        /// per `(ctx, view)`, each view on a chain once: a chain of L views costs
        /// L, never L². Null when no id on the chain stores anything.
        pub fn chainStored(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId) Error!?CondId {
            // Down the chain to its end or to a view already joined.
            var views: std.ArrayList(NodeId) = .empty;
            defer views.deinit(gpa);
            var joined: ?CondId = null;
            var id: ?NodeId = n;
            while (id) |x| : (id = v.shapes.chainNext(x)) {
                try charge.reserve(gpa, .memo, 1);
                // A walk with no memo (the cross-check) joins the whole chain.
                if (!t.no_memo) if (t.memo_chain.get(.{ ctx.int(), x.int() })) |hit| {
                    joined = if (hit == Ids.none_int) null else CondId.from(hit);
                    break;
                };
                // The join stored at the view's last position, where this one
                // reads alike on its region (*A read at another position*).
                if (!t.no_memo) if (t.home_chain.get(.{x.int()})) |h| if (h != ctx.int() and try t.readsAlike(gpa, charge, v, ctx, .from(h), try v.shapes.region(gpa, charge.account, x))) {
                    const hit = t.memo_chain.get(.{ h, x.int() }).?;
                    joined = if (hit == Ids.none_int) null else CondId.from(hit);
                    try charge.reserve(gpa, .memo, 1);
                    (try t.memo_chain.getOrPut(gpa, .{ ctx.int(), x.int() })).value_ptr.* = hit;
                    break;
                };
                try views.append(gpa, x);
            }
            // Back up it, each view's entry joined onto what lies joined it.
            var k = views.items.len;
            while (k > 0) {
                k -= 1;
                const x = views.items[k];
                if (t.kappaGet(ctx, x)) |s| joined = if (joined) |b| try t.join(gpa, charge, s, b) else s;
                if (t.no_memo) continue;
                try charge.reserve(gpa, .memo, 1);
                (try t.memo_chain.getOrPut(gpa, .{ ctx.int(), x.int() })).value_ptr.* = if (joined) |b| b.int() else Ids.none_int;
                (try t.home_chain.getOrPut(gpa, .{x.int()})).value_ptr.* = ctx.int();
            }
            return joined;
        }

        /// What is stored at `n` itself, a view's chain and answer joined in:
        /// what a reader of one position (a recast's inner, `innersOf`) takes.
        pub fn storedAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId) Error!?CondId {
            if (v.shapes.kind(n) != .view) return t.kappaGet(ctx, n);
            const answer = try v.shapes.force(gpa, charge.account, n);
            const chain = try t.chainStored(gpa, charge, v, ctx, n);
            const own = t.kappaGet(ctx, answer);
            if (chain) |c| return if (own) |o| try t.join(gpa, charge, c, o) else c;
            return own;
        }

        /// κ(n) in `ctx` by the header's rules; `at_summary` is whether `n`'s
        /// path crossed a `[*]` or `⟲` (`excl` there for an arrival `isFolded`).
        pub fn kappaOf(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
            return t.readAt(gpa, charge, v, ctx, n, at_summary, &.{});
        }

        /// `kappaOf` with the crossings a walk carries (`deep`'s frontier): the
        /// read at `ctx`, its value the same with or without them (*Argument 1*).
        /// A crossed read notes `base_epoch`; if it moved, the read is made again
        /// at `ctx`, exact, its memo entries dropped (*A read in flight*).
        pub fn readAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, pairs: []const Pair) Error!CondId {
            return t.resolved(gpa, charge, try t.readAtRaw(gpa, charge, v, ctx, n, at_summary, pairs));
        }

        pub fn readAtRaw(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, pairs: []const Pair) Error!CondId {
            // A node that walks nothing below it (no view, no DAG): read at once,
            // as the machine would, with no task of its own.
            if (v.shapes.kind(n) != .view and !isDag(v.shapes.kind(n))) {
                const k = try t.kappaReadOne(gpa, charge, v, ctx, n, at_summary, null);
                const fc = t.fold_cond.get(n) orelse return k;
                return t.@"and"(gpa, charge, k, fc);
            }
            // A union's, a positions node's or a view's read is a DAG walk (§4.1, #1098).
            const walk = try v.shapes.dagWalk(gpa, charge.account, n);
            defer if (walk) |k| charge.account.leave(k);
            const epoch = v.shapes.base_epoch;
            const from = t.pending.items.len;
            const r = try t.machine(gpa, charge, v, ctx, n, at_summary, pairs);
            // Every read outside a check is checked: memo hits walked whole.
            if (std.debug.runtime_safety and full_cross_check and !r.crossed and !t.no_memo) try t.crossCheckRead(gpa, charge, v, ctx, n, at_summary, r.k);
            if (!r.crossed) return r.k;
            t.crossed_reads += 1;
            if (v.shapes.base_epoch != epoch) {
                t.crossed_redos += 1;
                try t.settle(gpa, from, false);
                const saved = t.no_cross;
                t.no_cross = true;
                defer t.no_cross = saved;
                return (try t.machine(gpa, charge, v, ctx, n, at_summary, &.{})).k;
            }
            try t.settle(gpa, from, true);
            if (std.debug.runtime_safety and full_cross_check and !t.no_memo) try t.crossCheckRead(gpa, charge, v, ctx, n, at_summary, r.k);
            return r.k;
        }

        /// `-Downership-full-cross-check` (*Cross-check*): a crossed read made
        /// again at `C`, with no crossing and no memo, gives the same kind and
        /// atom set.
        pub fn crossCheckRead(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) Error!void {
            const saved = .{ t.no_cross, t.no_memo };
            t.no_cross = true;
            t.no_memo = true;
            defer {
                t.no_cross = saved[0];
                t.no_memo = saved[1];
            }
            const exact = (try t.machine(gpa, charge, v, ctx, n, at_summary, &.{})).k;
            try t.expectSame(gpa, charge, k, exact);
        }

        /// The crossing at re-root view `n` read at `ctx` (*The crossing*):
        /// `R`, the actual and its region, when `eqOn(ctx, R)` holds on the
        /// region; null where the read stays at `ctx`.
        pub fn crossAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId) Error!?struct { r: Kappas, region: SetId } {
            if (t.no_cross) return null;
            const r = (try v.shapes.rerootKappa(gpa, charge.account, n)) orelse return null;
            const answer = try v.shapes.force(gpa, charge.account, n);
            const actual = v.shapes.chainNext(n) orelse answer;
            const region = try v.shapes.region(gpa, charge.account, actual);
            if (!try t.eqOn(gpa, charge, v, ctx, r, region)) return null;
            return .{ .r = r, .region = region };
        }

        /// The position a node met at `ctx` with `pairs` carried is read at: a
        /// carried pair's `R_Q` when the node is wholly of its region, else `ctx`
        /// (*Carried along the walk*). `true` when it crossed.
        pub fn carried(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, pairs: []const Pair) Error!?Kappas {
            if (t.no_cross) return null;
            for (pairs) |p| if (p.epoch == v.shapes.base_epoch and try v.shapes.wholly(gpa, charge.account, n, p.region)) return p.r;
            return null;
        }

        const Read = struct { k: CondId, crossed: bool };

        /// The read machine: `kappaOf` and the DAG walk below it on one explicit
        /// stack (#1130: a chain of views below views is as long as the calls
        /// that made it, never native-stack depth). A `read` task is `kappaOf`
        /// at its position; an `inner` task a DAG node's join of its sides' reads
        /// with its own entry. At a re-root view the read may cross into the
        /// actual's own position (`crossAt`), and below a crossing a node wholly
        /// of the actual's region is read at the carried `R_Q`. Both tasks are
        /// memoised by `(position, node, class)`: positions and nodes are
        /// immutable, so a read is a function of its key, crossed or not. Within
        /// one run each task is made once; a task met again while it is open (a
        /// cycle) reads `yes`, and the run then keeps no memo entry.
        pub fn machine(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx0: Kappas, n0: NodeId, s0: bool, pairs: []const Pair) Error!Read {
            const Op = enum(u8) { read, inner };
            const Frame = struct {
                op: Op,
                ctx: Kappas,
                node: NodeId,
                summary: bool,
                /// Whether the carried pairs hold below this task.
                carry: bool,
                stage: u8 = 0,
                /// A read: the position and node its kind's rule reads (a view's
                /// answer, perhaps across) and what the chain stored.
                at: Kappas = .none,
                answer: NodeId = .none,
                extra: CondId = .none,
                /// Read at a position a crossing chose.
                crossed: bool = false,
                /// A read of a DAG: where its dropped entries start (`drop_entries`).
                check_from: u32 = 0,

                fn key(f: @This()) [4]u32 {
                    return .{ @backingInt(f.op), f.ctx.int(), f.node.int(), @intFromBool(f.summary) };
                }
            };
            const open_mark = std.math.maxInt(u32);
            var frames: std.ArrayList(Frame) = .empty;
            defer frames.deinit(gpa);
            var vals: std.ArrayList(Read) = .empty;
            defer vals.deinit(gpa);
            var state: Ids.FixedDict(4) = .{};
            defer state.deinit(gpa);
            var done: std.ArrayList(Read) = .empty;
            defer done.deinit(gpa);
            // Under `runtime_safety`: what each snapshot stores for a node a
            // rebuild dropped, met below the read in progress (`dropsOf`).
            var drop_entries: std.ArrayList(CondId) = .empty;
            defer drop_entries.deinit(gpa);
            var cyclic = false;
            try frames.append(gpa, .{ .op = .read, .ctx = ctx0, .node = n0, .summary = s0, .carry = pairs.len > 0 });
            while (frames.items.len > 0) {
                const fi = frames.items.len - 1;
                var f = frames.items[fi];
                if (f.stage == 0) {
                    try charge.reserve(gpa, .memo, 1);
                    const got = try state.getOrPut(gpa, f.key());
                    if (got.found_existing) {
                        _ = frames.pop();
                        if (got.value_ptr.* == open_mark) {
                            cyclic = true;
                            try vals.append(gpa, .{ .k = yes, .crossed = false });
                        } else try vals.append(gpa, done.items[got.value_ptr.*]);
                        continue;
                    }
                    got.value_ptr.* = open_mark;
                }
                var result: ?Read = null;
                switch (f.op) {
                    .read => if (f.stage == 0) {
                        f.at = f.ctx;
                        f.answer = f.node;
                        var extra: ?CondId = null;
                        if (v.shapes.kind(f.node) == .view) {
                            f.answer = try v.shapes.force(gpa, charge.account, f.node);
                            if (try t.crossAt(gpa, charge, v, f.ctx, f.node)) |x| {
                                // The view's own entry, the class's binding, at `C`;
                                // the chain past it and the answer at `R`.
                                f.at = x.r;
                                f.crossed = true;
                                extra = t.kappaGet(f.ctx, f.node);
                                if (v.shapes.chainNext(f.node)) |next| if (try t.chainStored(gpa, charge, v, x.r, next)) |c| {
                                    extra = if (extra) |e| try t.join(gpa, charge, e, c) else c;
                                };
                            } else extra = try t.chainStored(gpa, charge, v, f.ctx, f.node);
                        }
                        f.extra = extra orelse .none;
                        if (!isDag(v.shapes.kind(f.answer))) {
                            result = .{ .k = try t.kappaReadOne(gpa, charge, v, f.at, f.answer, f.summary, extra), .crossed = f.crossed };
                        } else {
                            if (try t.memoAt(gpa, charge, v, .dag, .{ f.at.int(), f.answer.int(), @intFromBool(f.summary) })) |hit| {
                                result = .{ .k = if (extra) |e| try t.join(gpa, charge, e, .from(hit)) else .from(hit), .crossed = f.crossed };
                            } else {
                                // The answer's DAG, its sides' join first. Below a
                                // crossing every node of it is of the region, read at
                                // `R`: the carried pairs are not needed there.
                                f.stage = 1;
                                f.check_from = @intCast(drop_entries.items.len);
                                frames.items[fi] = f;
                                try frames.append(gpa, .{ .op = .inner, .ctx = f.at, .node = f.answer, .summary = f.summary, .carry = f.carry and !f.crossed });
                                continue;
                            }
                        }
                    } else {
                        const inner = vals.pop().?;
                        const root = try t.dagRoot(gpa, charge, v, f.answer, f.summary, inner.k);
                        const crossed = f.crossed or inner.crossed;
                        if (!cyclic) try t.memoPut(gpa, .dag, .{ f.at.int(), f.answer.int(), @intFromBool(f.summary) }, root.int(), crossed);
                        result = .{ .k = if (f.extra != .none) try t.join(gpa, charge, f.extra, root) else root, .crossed = crossed };
                        if (std.debug.runtime_safety and !t.drop_check_off) {
                            for (drop_entries.items[f.check_from..]) |e| if (!try t.impliedBy(gpa, v, e, result.?.k))
                                std.debug.panic("ownership v2: a dropped positions node's entry {d} is not implied by the read {d} of its rebuild (§2.3 *Saturation at two*)", .{ e.int(), result.?.k.int() });
                            drop_entries.shrinkRetainingCapacity(f.check_from);
                        }
                    },
                    .inner => if (f.stage == 0) {
                        // The task's one record (above) covers its memo lookups.
                        if (try t.memoAt(gpa, charge, v, .inner, .{ f.ctx.int(), f.node.int(), @intFromBool(f.summary) })) |hit| {
                            result = .{ .k = .from(hit), .crossed = false };
                        } else {
                            f.stage = 1;
                            frames.items[fi] = f;
                            const d = v.shapes.get(f.node);
                            for ([_]NodeId{ .from(d.b), .from(d.a) }) |sd| {
                                var at = f.ctx;
                                var carry = f.carry;
                                if (f.carry) if (try t.carried(gpa, charge, v, sd, pairs)) |r| {
                                    at = r;
                                    carry = false;
                                };
                                try frames.append(gpa, .{ .op = if (isDag(v.shapes.kind(sd))) .inner else .read, .ctx = at, .node = sd, .summary = f.summary, .carry = carry, .crossed = at != f.ctx });
                            }
                            continue;
                        }
                    } else {
                        const a = vals.pop().?;
                        const b = vals.pop().?;
                        var k = try t.join(gpa, charge, a.k, b.k);
                        if (t.kappaGet(f.ctx, f.node)) |st| k = try t.join(gpa, charge, st, k);
                        if (std.debug.runtime_safety and !t.drop_check_off) {
                            var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
                            defer scratch.deinit(gpa);
                            var drops: std.ArrayList(NodeId) = .empty;
                            defer drops.deinit(gpa);
                            try v.shapes.dropsClosure(gpa, &scratch, f.node, &drops);
                            for (drops.items) |d| if (t.kappaGet(f.ctx, d)) |e| try drop_entries.append(gpa, e);
                        }
                        const crossed = a.crossed or b.crossed or f.crossed;
                        if (!cyclic) try t.memoPut(gpa, .inner, .{ f.ctx.int(), f.node.int(), @intFromBool(f.summary) }, k.int(), crossed);
                        result = .{ .k = k, .crossed = crossed };
                    },
                }
                var r = result.?;
                // A widened class image owes its path-multiset obligation wherever
                // it is read, a union's side included (§2.9, #1128). `fold_cond`
                // never keys a view: widen folds answers.
                if (f.op == .read) if (t.fold_cond.get(f.answer)) |fc| {
                    r.k = try t.@"and"(gpa, charge, r.k, fc);
                };
                _ = frames.pop();
                (try state.getOrPut(gpa, f.key())).value_ptr.* = @intCast(done.items.len);
                try done.append(gpa, r);
                try vals.append(gpa, r);
            }
            return vals.pop().?;
        }

        /// `kappaRead` of a node that is no view: a DAG node's read through the
        /// machine, any other kind's at once.
        pub fn kappaRead(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, extra: ?CondId) Error!CondId {
            if (!isDag(v.shapes.kind(n))) return t.resolved(gpa, charge, try t.kappaReadOne(gpa, charge, v, ctx, n, at_summary, extra));
            const k = try t.readAt(gpa, charge, v, ctx, n, at_summary, &.{});
            return t.resolved(gpa, charge, if (extra) |e| try t.join(gpa, charge, e, k) else k);
        }

        /// The read of a node of a kind that walks nothing below it (no view, no
        /// DAG): its stored entry, `extra` joined, and the derived read.
        pub fn kappaReadOne(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, extra: ?CondId) Error!CondId {
            const own = t.kappaGet(ctx, n);
            const stored: ?CondId = if (extra) |e| (if (own) |s| try t.join(gpa, charge, s, e) else e) else own;
            // THE RULE (header): stored ⊔ derived at the read's position.
            const derived: CondId = switch (v.shapes.kind(n)) {
                .leaf => try t.derivedCells(gpa, charge, v, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n)), at_summary, .none, .none),
                // A built node's κ is the walk's (O13): `lost` until set; in a
                // collapsed fold `lost` (§2.9). At a summary position its storage
                // arrivals that stand for many positions owe `excl` as a leaf's do
                // (§2.9, #1112), so a read never rests on where it was linked from.
                .node, .delta => {
                    if (t.isCollapsed(ctx)) return lost;
                    const s = stored orelse return lost;
                    if (!at_summary or s == shared) return s;
                    return t.@"and"(gpa, charge, s, try t.derivedCells(gpa, charge, v, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n)), true, .none, .none));
                },
                // A recast and its inner are one position: what is stored at
                // either counts (§2.9, §2.13.9).
                .recast => blk: {
                    var d: CondId = if (holdsBelow(v.places, v.shapes.place(n))) lost else yes;
                    // Every inner at this position, a union's recasts' inside an
                    // inner too (#1101).
                    var inners: std.ArrayList(NodeId) = .empty;
                    defer inners.deinit(gpa);
                    try innersOf(gpa, charge, v, n, &inners);
                    for (inners.items) |i| if (try t.storedAt(gpa, charge, v, ctx, i)) |s| {
                        d = try t.join(gpa, charge, s, d);
                    };
                    // At a summary position its cells owe what a leaf's do (#1115).
                    if (at_summary) d = try t.@"and"(gpa, charge, d, try t.derivedCells(gpa, charge, v, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n)), true, .none, .none));
                    break :blk d;
                },
                .@"union", .choice, .positions, .view => unreachable, // the machine's
            };
            return if (stored) |s| t.join(gpa, charge, s, derived) else derived;
        }

        // ---- the equality a crossing rests on (*The equality*) -----------------------------

        /// Whether any position at or below `ctx` is a fold, exact or collapsed
        /// (*No crossing at a fold*): memoised per position, post-order on an
        /// explicit stack.
        pub fn foldBelow(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas) Error!bool {
            if (ctx == .none) return false;
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_fold_below.get(.{ctx.int()})) |hit| return hit == 1;
            const Frame = struct { at: Kappas, expanded: bool };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, .{ .at = ctx, .expanded = false });
            while (stack.pop()) |f| {
                if (t.memo_fold_below.get(.{f.at.int()}) != null) continue;
                const p = t.position(f.at);
                if (p.fold != 0) {
                    (try t.memo_fold_below.getOrPut(gpa, .{f.at.int()})).value_ptr.* = 1;
                    continue;
                }
                if (!f.expanded) {
                    try charge.reserve(gpa, .inspection, 1);
                    try stack.append(gpa, .{ .at = f.at, .expanded = true });
                    var it = t.mapEntries(p.links);
                    while (it.next()) |e| if (t.memo_fold_below.get(.{e.value}) == null) try stack.append(gpa, .{ .at = .from(e.value), .expanded = false });
                    continue;
                }
                var any = false;
                var it = t.mapEntries(p.links);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    if (t.memo_fold_below.get(.{e.value}).? == 1) any = true;
                }
                try charge.reserve(gpa, .memo, 1);
                (try t.memo_fold_below.getOrPut(gpa, .{f.at.int()})).value_ptr.* = @intFromBool(any);
            }
            return t.memo_fold_below.get(.{ctx.int()}).? == 1;
        }

        /// `eqOn(C, R)` on `region` (*The equality*): at every pair of positions
        /// the walk can reach, neither is a fold, every key based on the region
        /// has in both no entry or entries of one kind and atom set, and `C`
        /// links a step exactly when `R` does. Memoised per `(C, R, region)`
        /// within one `base_epoch`; a pair of equal positions is equal at once,
        /// and the entry maps are compared per pair of map nodes (`mapsEqOn`).
        pub fn eqOn(t: *Table, gpa: Allocator, asking: Charge, v: View, c: Kappas, r: Kappas, region: SetId) Error!bool {
            // The crossing's comparison, a growth task (§4.1).
            const task = try asking.account.enter(gpa, null);
            defer asking.account.leave(task);
            const charge: Charge = .growth(asking.account);
            if (try t.foldBelow(gpa, charge, c) or try t.foldBelow(gpa, charge, r)) return false;
            if (c == r) return true;
            const key: [4]u32 = .{ c.int(), r.int(), region.int(), v.shapes.base_epoch };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_eq.get(key)) |hit| return hit == 1;
            const out = try t.eqOnWalk(gpa, charge, v, c, r, region);
            (try t.memo_eq.getOrPut(gpa, key)).value_ptr.* = @intFromBool(out);
            return out;
        }

        pub fn eqOnWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, c0: Kappas, r0: Kappas, region: SetId) Error!bool {
            var stack: std.ArrayList([2]Kappas) = .empty;
            defer stack.deinit(gpa);
            var seen: Ids.FixedDict(2) = .{};
            defer seen.deinit(gpa);
            try stack.append(gpa, .{ c0, r0 });
            while (stack.pop()) |pr| {
                const c, const r = pr;
                if (c == r) continue;
                try charge.reserve(gpa, .memo, 1);
                if ((try seen.getOrPut(gpa, .{ c.int(), r.int() })).found_existing) continue;
                if (t.memo_eq.get(.{ c.int(), r.int(), region.int(), v.shapes.base_epoch })) |hit| {
                    if (hit == 0) return false;
                    continue;
                }
                const pc = t.position(c);
                const pr_ = t.position(r);
                if (pc.fold != 0 or pr_.fold != 0) return false;
                if (!try t.mapsEqOn(gpa, charge, v, pc.here, pr_.here, region)) return false;
                if (!try t.linksEq(gpa, charge, pc.links, pr_.links, &stack)) return false;
            }
            return true;
        }

        /// Two entry maps equal on the keys based on `region` (*The comparison
        /// and its cost*): the keys the two bind differently (`diffKeys`, with no
        /// region in it, so a pair of subtrees an earlier call compared is met
        /// again whatever the region) must hold no tested key: not the empty
        /// value, which is tested for every region, and none whose `bases*`
        /// meets the region (`diffReach`, memoised per radix node).
        pub fn mapsEqOn(t: *Table, gpa: Allocator, charge: Charge, v: View, a: u32, b: u32, region: SetId) Error!bool {
            if (a == b) return true;
            const d = try t.diffKeys(gpa, charge, v, a, b);
            if (d == .none) return true;
            if (try t.nodesPart(gpa, charge, v, .empty, d) != .none) return false;
            return !try v.shapes.node_sets.intersectsMemo(gpa, charge, &v.shapes.memo_node_meet, try t.nodesPart(gpa, charge, v, .reach, d), region);
        }

        /// The keys two entry maps bind differently, as a node set: bound by one
        /// side only, or by both with another kind or atom set (`sameCond`).
        /// Memoised per unordered pair of map nodes, for good (maps and their
        /// entries never change); the recursion is the key width.
        pub fn diffKeys(t: *Table, gpa: Allocator, charge: Charge, v: View, a: u32, b: u32) Error!SetId {
            if (a == b) return .none;
            if (a == Ids.none_int) return t.mapKeys(gpa, charge, v, b);
            if (b == Ids.none_int) return t.mapKeys(gpa, charge, v, a);
            const key: [2]u32 = .{ @min(a, b), @max(a, b) };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_diff.get(key)) |hit| return .from(hit);
            const sets = &v.shapes.node_sets;
            const memo = &v.shapes.memo_node_union;
            const na = t.mapNode(a);
            const nb = t.mapNode(b);
            const out: SetId = blk: {
                if (na.mask == 0 and nb.mask == 0) {
                    if (na.prefix == nb.prefix) {
                        if (na.left == nb.left or try t.sameCond(gpa, charge, .from(na.left), .from(nb.left))) break :blk .none;
                        break :blk try sets.insert(gpa, charge, .none, na.prefix, 0);
                    }
                    break :blk try sets.unionMemo(gpa, charge, memo, try t.mapKeys(gpa, charge, v, a), try t.mapKeys(gpa, charge, v, b));
                }
                if (na.mask == 0 or nb.mask == 0) {
                    const leaf_a = na.mask == 0;
                    const leaf_id = if (leaf_a) a else b;
                    const leaf = if (leaf_a) na else nb;
                    const br = if (leaf_a) nb else na;
                    if (!matches(leaf.prefix, br.prefix, br.mask)) break :blk try sets.unionMemo(gpa, charge, memo, try t.mapKeys(gpa, charge, v, a), try t.mapKeys(gpa, charge, v, b));
                    const zero = leaf.prefix & br.mask == 0;
                    break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, leaf_id, if (zero) br.left else br.right), try t.mapKeys(gpa, charge, v, if (zero) br.right else br.left));
                }
                if (na.mask == nb.mask and na.prefix == nb.prefix) break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, na.left, nb.left), try t.diffKeys(gpa, charge, v, na.right, nb.right));
                if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
                    const zero = nb.prefix & na.mask == 0;
                    break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, if (zero) na.left else na.right, b), try t.mapKeys(gpa, charge, v, if (zero) na.right else na.left));
                }
                if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
                    const zero = na.prefix & nb.mask == 0;
                    break :blk try sets.unionMemo(gpa, charge, memo, try t.diffKeys(gpa, charge, v, a, if (zero) nb.left else nb.right), try t.mapKeys(gpa, charge, v, if (zero) nb.right else nb.left));
                }
                break :blk try sets.unionMemo(gpa, charge, memo, try t.mapKeys(gpa, charge, v, a), try t.mapKeys(gpa, charge, v, b));
            };
            (try t.memo_diff.getOrPut(gpa, key)).value_ptr.* = out.int();
            return out;
        }

        /// The keys of an entry map, as a node set: memoised per map node, for
        /// good, made from its two halves' sets; the recursion is the key width.
        pub fn mapKeys(t: *Table, gpa: Allocator, charge: Charge, v: View, m: u32) Error!SetId {
            if (m == Ids.none_int) return .none;
            const n = t.mapNode(m);
            if (n.mask == 0) return v.shapes.node_sets.insert(gpa, charge, .none, n.prefix, 0);
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_map_keys.get(.{m})) |hit| return .from(hit);
            const out = try v.shapes.node_sets.unionMemo(gpa, charge, &v.shapes.memo_node_union, try t.mapKeys(gpa, charge, v, n.left), try t.mapKeys(gpa, charge, v, n.right));
            (try t.memo_map_keys.getOrPut(gpa, .{m})).value_ptr.* = out.int();
            return out;
        }

        /// What a node set of keys tells the comparison (`mapsEqOn`): `empty`,
        /// the empty values among them (memoised for good); `reach`, their
        /// `bases*` with themselves (memoised within one `base_epoch`). Per radix
        /// node, a node's the union of its halves'; the recursion is the key width.
        const NodesPart = enum(u8) { empty, reach };

        pub fn nodesPart(t: *Table, gpa: Allocator, charge: Charge, v: View, which: NodesPart, s: SetId) Error!SetId {
            if (s == .none) return .none;
            const sets = &v.shapes.node_sets;
            const epoch: u32 = if (which == .reach) v.shapes.base_epoch else 0;
            const key: [3]u32 = .{ @backingInt(which), s.int(), epoch };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_nodes_part.get(key)) |hit| return .from(hit);
            const out: SetId = if (sets.branches(s)) |kids|
                try sets.unionMemo(gpa, charge, &v.shapes.memo_node_union, try t.nodesPart(gpa, charge, v, which, kids[0]), try t.nodesPart(gpa, charge, v, which, kids[1]))
            else blk: {
                var it = sets.iterate(s);
                const n: NodeId = .from(it.next().?.key);
                break :blk switch (which) {
                    .empty => if (v.shapes.kind(n) == .leaf and v.shapes.cells(n) == .none) s else .none,
                    .reach => try v.shapes.basesClosure(gpa, charge.account, n),
                };
            };
            (try t.memo_nodes_part.getOrPut(gpa, key)).value_ptr.* = out.int();
            return out;
        }

        /// One kind and one atom set (`flat`): what a block and a verdict see.
        pub fn sameCond(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!bool {
            if (a == b) return true;
            if (fails(a) or fails(b) or a == yes or b == yes) return false;
            return try t.flat(gpa, charge, a) == try t.flat(gpa, charge, b);
        }

        /// Two link maps with the same steps, each pair of differing children
        /// queued for `eqOn`: an extra link is no equality (*The equality*).
        pub fn linksEq(t: *Table, gpa: Allocator, charge: Charge, a: u32, b: u32, out: *std.ArrayList([2]Kappas)) Error!bool {
            if (a == b) return true;
            var ia = t.mapEntries(a);
            var ib = t.mapEntries(b);
            while (true) {
                try charge.reserve(gpa, .inspection, 1);
                const x = ia.next();
                const y = ib.next();
                if (x == null and y == null) return true;
                if (x == null or y == null) return false;
                if (x.?.key != y.?.key) return false;
                if (x.?.value != y.?.value) try out.append(gpa, .{ .from(x.?.value), .from(y.?.value) });
            }
        }

        /// κ from the cells at the read's position (header), `extra` arrivals
        /// counted besides them at a summary position; charged per read.
        pub fn derivedCells(t: *Table, gpa: Allocator, charge: Charge, v: View, cells: SetId, at_summary: bool, dups: SetId, dups_approx: SetId) Error!CondId {
            // At a plain path: `lost` for an approximate cell or `⊤`, the first one
            // found; a set read once costs its cells up to it.
            if (!at_summary) {
                var it = v.cells.sets.iterate(cells);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    if (e.value == 1 or v.cells.origin(.from(e.key)) == .top) return lost;
                }
                return yes;
            }
            // `summaryExcl(cells) ∧ apart(cells ⊎ dups)` (*The derivation*): the
            // set's aggregate, memoised per radix node, with the repeats added as
            // second occurrences. Every repeat is a cell of `cells`, one exact
            // where both its occurrences are, and then `cells` holds it exact: so
            // `all` is unchanged, and the repeats join `dups` as sets, approximate
            // where either occurrence is (`dups_approx`, or `cells` holds it so).
            var a = try t.setAgg(gpa, charge, v.cells, v.places, cells);
            if (dups != .none) {
                a.dups = try v.cells.sets.unionWith(gpa, charge, a.dups, dups);
                const old = try v.cells.sets.intersection(gpa, charge, dups, try t.cellPart(gpa, charge, v.cells, v.places, .approx, a.all));
                a.dups_approx = try v.cells.sets.unionWith(gpa, charge, a.dups_approx, try v.cells.sets.unionWith(gpa, charge, dups_approx, old));
            }
            const k = try t.@"and"(gpa, charge, try t.summaryExcl(gpa, charge, v.cells, v.places, cells), try t.aggCond(gpa, charge, v.cells, v.places, a));
            if (std.debug.runtime_safety and full_cross_check) try t.expectSame(gpa, charge, k, try t.derivedCellsFlat(gpa, charge, v, cells, dups, dups_approx));
            return k;
        }

        /// `derivedCells` the old way, a list sorted once (the cross-check's).
        pub fn derivedCellsFlat(t: *Table, gpa: Allocator, charge: Charge, v: View, cells: SetId, dups: SetId, dups_approx: SetId) Error!CondId {
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(gpa);
            var dt = v.cells.sets.iterate(dups);
            while (dt.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = v.cells.sets.member(dups_approx, e.key) });
            var it = v.cells.sets.iterate(cells);
            while (it.next()) |e| try items.append(gpa, .{ .cell = .from(e.key), .approx = e.value == 1 });
            const k = try t.summaryExclFlat(gpa, charge, v.cells, v.places, cells);
            return t.@"and"(gpa, charge, k, try t.apart(gpa, charge, v.cells, v.places, items.items, null));
        }

        /// The part of a cell set a property picks (*The derivation*): `approx`,
        /// the cells held approximately; `unfolded`, the cells a repeat of makes
        /// `shared` (not `⊤`, not standing for many positions). Memoised per radix
        /// node, a node's the union of its halves'. Post-order on an explicit stack.
        const Part = enum(u8) { approx, unfolded };

        pub fn cellPart(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, which: Part, cells: SetId) Error!SetId {
            if (cells == .none) return .none;
            if (cellt.sets.branches(cells) == null) {
                try charge.reserve(gpa, .inspection, 1);
                var it = cellt.sets.iterate(cells);
                const e = it.next().?;
                const kept = switch (which) {
                    .approx => e.value == 1,
                    .unfolded => cellt.origin(.from(e.key)) != .top and !isFolded(cellt, places, .from(e.key)),
                };
                return if (kept) cells else .none;
            }
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_cell_part.get(.{ @backingInt(which), cells.int() })) |hit| return .from(hit);
            var stack: std.ArrayList(SetId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, cells);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.memo_cell_part.get(.{ @backingInt(which), x.int() }) != null) {
                    _ = stack.pop();
                    continue;
                }
                const kids = cellt.sets.branches(x).?;
                var halves: [2]SetId = .{ .none, .none };
                var missing = false;
                for (kids, 0..) |kid, i| {
                    if (kid == .none) continue;
                    if (cellt.sets.branches(kid) == null) {
                        halves[i] = try t.cellPart(gpa, charge, cellt, places, which, kid);
                    } else if (t.memo_cell_part.get(.{ @backingInt(which), kid.int() })) |h| {
                        halves[i] = .from(h);
                    } else {
                        missing = true;
                        try stack.append(gpa, kid);
                    }
                }
                if (missing) continue;
                try charge.reserve(gpa, .memo, 1);
                const got = try cellt.sets.unionWith(gpa, charge, halves[0], halves[1]);
                (try t.memo_cell_part.getOrPut(gpa, .{ @backingInt(which), x.int() })).value_ptr.* = got.int();
                _ = stack.pop();
            }
            return .from(t.memo_cell_part.get(.{ @backingInt(which), cells.int() }).?);
        }

        /// The aggregate of a cell set (`Agg`), a use mark left out: memoised per
        /// radix node, a node's the disjoint join of its two halves' (`aggJoin`).
        /// Post-order on an explicit stack.
        pub fn setAgg(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, cells: SetId) Error!Agg {
            if (cells == .none) return .{};
            if (cellt.sets.branches(cells) == null) {
                var it = cellt.sets.iterate(cells);
                const e = it.next().?;
                if (cellt.origin(.from(e.key)) == .mark) return .{};
                return t.aggAdd(gpa, charge, cellt, places, .{}, .from(e.key), e.value == 1, false);
            }
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_set_agg.get(.{cells.int()})) |hit| return t.aggs.items[hit];
            var stack: std.ArrayList(SetId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, cells);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.memo_set_agg.get(.{x.int()}) != null) {
                    _ = stack.pop();
                    continue;
                }
                try charge.reserve(gpa, .memo, 1);
                const a: Agg = if (cellt.sets.branches(x)) |kids| blk: {
                    var halves: [2]Agg = .{ .{}, .{} };
                    var missing = false;
                    for (kids, 0..) |kid, i| {
                        if (kid == .none) continue;
                        if (t.memo_set_agg.get(.{kid.int()})) |h| halves[i] = t.aggs.items[h] else {
                            missing = true;
                            try stack.append(gpa, kid);
                        }
                    }
                    if (missing) continue;
                    break :blk try t.aggJoin(gpa, charge, cellt, places, halves[0], halves[1]);
                } else blk: {
                    var it = cellt.sets.iterate(x);
                    const e = it.next().?;
                    if (cellt.origin(.from(e.key)) == .mark) break :blk .{};
                    break :blk try t.aggAdd(gpa, charge, cellt, places, .{}, .from(e.key), e.value == 1, false);
                };
                const got = try t.agg(gpa, a);
                (try t.memo_set_agg.getOrPut(gpa, .{x.int()})).value_ptr.* = got;
                _ = stack.pop();
            }
            return t.aggs.items[t.memo_set_agg.get(.{cells.int()}).?];
        }

        /// Two aggregates of disjoint cell sets as one, a set's two halves (*The
        /// derivation*): the sets united as they are, the taken-element rule met
        /// across them, and the pairs over a base both bind added as `aggAdd`
        /// adds them, the smaller side's cells of that base one by one. No repeat
        /// arises: the keys are disjoint.
        pub fn aggJoin(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, x: Agg, y: Agg) Error!Agg {
            if (x.all == .none) return y;
            if (y.all == .none) return x;
            try charge.reserve(gpa, .inspection, 1);
            const sets = &cellt.sets;
            var a: Agg = .{
                .all = try sets.unionWith(gpa, charge, x.all, y.all),
                .all_len = x.all_len + y.all_len,
                .dups = try sets.unionWith(gpa, charge, x.dups, y.dups),
                .dups_approx = try sets.unionWith(gpa, charge, x.dups_approx, y.dups_approx),
                .lost_extra = x.lost_extra or y.lost_extra,
                .group = try sets.unionWith(gpa, charge, x.group, y.group),
                .group_len = x.group_len + y.group_len,
                .whole = try sets.unionWith(gpa, charge, x.whole, y.whole),
                .elems = try sets.unionWith(gpa, charge, x.elems, y.elems),
                .pairs = try t.@"and"(gpa, charge, x.pairs, y.pairs),
                .hit = x.hit or y.hit or try sets.intersects(gpa, charge, x.whole, y.elems) or try sets.intersects(gpa, charge, x.elems, y.whole),
            };
            // The bases: the larger side's map, the smaller's bases added to it.
            const big, const small = if (x.group_len >= y.group_len) .{ x, y } else .{ y, x };
            a.bases = big.bases;
            var bt = t.mapEntries(small.bases);
            while (bt.next()) |be| {
                try charge.reserve(gpa, .inspection, 1);
                var same: SetId = if (t.mapGet(a.bases, be.key)) |s| .from(s) else .none;
                if (same == .none) {
                    a.bases = try t.mapPut(gpa, charge, a.bases, be.key, be.value);
                    continue;
                }
                var ct = sets.iterate(.from(be.value));
                while (ct.next()) |ce| {
                    const c: CellId = .from(ce.key);
                    // A part below a cell the bucket holds meets every other cell
                    // as that cell does (`covered`).
                    if (try covered(gpa, charge, cellt, same, c)) continue;
                    const split = splitKey(cellt, c);
                    var run: ?CellId = null;
                    var run_len: u32 = 0;
                    var it = sets.iterate(same);
                    while (it.next()) |e| {
                        try charge.reserve(gpa, .inspection, 1);
                        const w: CellId = .from(e.key);
                        // One anchor's cells: a part is symbolic below it (§2.2).
                        if (sameAnchor(split, splitKey(cellt, w))) continue;
                        if (sameRun(split, splitKey(cellt, w))) {
                            run_len += 1;
                            run = w;
                            continue;
                        }
                        if (cellt.alias(places, c, w) == .no) continue;
                        a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, w, false, null));
                    }
                    if (run_len == 1) if (run) |w| if (cellt.alias(places, c, w) != .no) {
                        a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, w, false, null));
                    };
                    same = try sets.insert(gpa, charge, same, c.int(), 0);
                }
                a.bases = try t.mapPut(gpa, charge, a.bases, be.key, same.int());
            }
            return a;
        }

        /// Whether anything below `p` may hold an object.
        fn holdsBelow(places: *const Cell.Places, p: Ids.PlaceId) bool {
            for (places.steps(p).children) |c| if (!places.holds(c).isEmpty()) return true;
            return false;
        }

        // ---- sep, apart, deep, lower ------------------------------------------

        fn isConcrete(o: Cell.Origin) bool {
            return o == .site or o == .result or o == .esc;
        }

        /// Whether `c` stands for possibly several objects: its label is folded
        /// (`⋆`) or its path is at or below a summary position (`[*]`, `⟲`).
        fn isFolded(cellt: *const Cell.Table, places: *const Cell.Places, c: CellId) bool {
            const d = cellt.get(c);
            return switch (d.origin) {
                .site, .top, .mark => false,
                // No label (an asserted row's `taken` element): folded, which claims less.
                .result, .esc => d.a == Ids.none_int or cellt.labelOf(.from(d.a)).folded,
                .cb => d.a == Ids.none_int or cellt.labelOf(.from(d.a)).folded or places.isSummary(.from(d.b)),
                .param, .env, .shared, .msg => places.isSummary(.from(d.b)),
                // A part (§2.2 *Parts*): its anchor's, or several below a summary step.
                .part => isFolded(cellt, places, .from(d.a)) or places.isSummary(.from(d.c)),
                .elem, .others, .level, .below, .loan => d.b == Ids.none_int or cellt.labelOf(.from(d.b)).folded,
            };
        }

        /// `sep(a, b)` (§2.9) at this path: two distinct concrete cells `yes`;
        /// one unfolded cell twice `shared`, a folded one `lost`; `⊤`/approximate
        /// `lost`; arrivals `alias` tells apart the atom, that may be one `lost`;
        /// a split's two sides its κ; two `taken` elements the traversal rule.
        pub fn sep(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a: CellId, b: CellId, approx: bool, traversal: ?Traversal) Error!CondId {
            try charge.reserve(gpa, .inspection, 1);
            if (approx or cellt.origin(a) == .top or cellt.origin(b) == .top) return lost;
            if (a == b) return if (isFolded(cellt, places, a)) lost else shared;
            const memo = traversal == null;
            const key = [2]u32{ @min(a.int(), b.int()), @max(a.int(), b.int()) };
            if (memo) if (t.memo_sep.get(key)) |hit| return .from(hit);
            const out: CondId = switch (cellt.alias(places, a, b)) {
                .no => if (isConcrete(cellt.origin(a)) or isConcrete(cellt.origin(b))) yes else try t.sepAtom(gpa, charge, a, b),
                .yes => lost,
                .under => |s| blk: {
                    const k = cellt.splitOf(s).cond;
                    if (k == .none) break :blk lost;
                    if (k == yes or fails(k)) break :blk k;
                    // Two parts at one path below two positions of one list:
                    // `excl` of their one cell, which `k` implies (§2.9 *Two
                    // positions of one image*).
                    if (try partsCell(gpa, charge, cellt, places, a, b)) |x| break :blk try t.excl(gpa, charge, x);
                    break :blk k;
                },
                .under_kappa => |container| if (traversal) |tr| (tr.apart(tr.ctx, container, a, b) orelse lost) else lost,
            };
            if (memo) {
                try charge.reserve(gpa, .memo, 1);
                (try t.memo_sep.getOrPut(gpa, key)).value_ptr.* = out.int();
            }
            return out;
        }

        /// The κ of the first split on `c`'s refinement chain that `c` stands
        /// for many positions of (an `others` or `below` side) and whose list
        /// may repeat one of them (§2.9 *The repeating split*): its condition
        /// when that fails (`shared`, `lost`, or none recorded), else null.
        /// Those positions are not one-to-one with the canonical cell's, so no
        /// `excl` of that cell may stand for them. One position (`elem`,
        /// `level`) is one canonical position, whatever the list holds.
        pub fn repeatingSplit(cellt: *const Cell.Table, c: CellId) ?CondId {
            var at = c;
            while (cellt.origin(at).isRefinement()) : (at = cellt.parent(at)) {
                const o = cellt.origin(at);
                if (o != .others and o != .below) continue;
                const x = cellt.get(at);
                const sp = cellt.findSplit(x.parent, .from(x.b));
                if (sp == .none) continue;
                const k = cellt.splitOf(sp).cond;
                if (k == .none) return lost;
                if (fails(k)) return k;
            }
            return null;
        }

        /// Whether a list side's split keeps its positions apart: its κ neither
        /// fails nor is missing (*The repeating split*).
        fn sideHolds(cellt: *const Cell.Table, sd: CellId) bool {
            const x = cellt.get(sd);
            const sp = cellt.findSplit(x.parent, .from(x.b));
            if (sp == .none) return false;
            const k = cellt.splitOf(sp).cond;
            return k != .none and !fails(k);
        }

        /// `excl c` for a frame cell: the failed κ of a split on its chain whose
        /// list repeats a position (`repeatingSplit`), which no `excl` stands for.
        pub fn exclOf(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, c: CellId) Error!CondId {
            return repeatingSplit(cellt, c) orelse t.excl(gpa, charge, c);
        }

        /// The one canonical cell of two parts at one path `q` below two
        /// disjoint positions of one list (`Cell.listSides`), when `q` takes
        /// no summary step (`[*]`, `⟲`): then each of its positions is one
        /// position of the list's element cell, so the split's κ there, read
        /// at the summary position, implies its `excl`. Null otherwise.
        fn partsCell(gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a: CellId, b: CellId) Error!?CellId {
            if (cellt.origin(a) != .part or cellt.origin(b) != .part) return null;
            const sd = cellt.listSides(a, b) orelse return null;
            if (!sideHolds(cellt, sd[0]) or repeatingSplit(cellt, a) != null or repeatingSplit(cellt, b) != null) return null;
            try charge.reserve(gpa, .inspection, 1);
            const x = (try cellt.unrefined(gpa, charge.account, places, a)) orelse return null;
            if ((try cellt.unrefined(gpa, charge.account, places, b)) != x) return null;
            const e = (try cellt.unrefined(gpa, charge.account, places, sd[0])) orelse return null;
            if ((try cellt.unrefined(gpa, charge.account, places, sd[1])) != e) return null;
            const ex = cellt.get(e);
            const xx = cellt.get(x);
            if (ex.origin != xx.origin or ex.a != xx.a or ex.c != xx.c) return null;
            const ep: Ids.PathId = .from(ex.b);
            var q: Ids.PathId = .from(xx.b);
            if (q == ep) return null;
            while (places.pathDepth(q) > places.pathDepth(ep)) : (q = places.pathParent(q)) {
                try charge.reserve(gpa, .inspection, 1);
                const k = places.pathStep(q).kind;
                if (k == .elem or k == .level) return null;
            }
            return if (q == ep) x else null;
        }

        // ---- incremental apart reads (§2.9, #1121) ------------------------------------

        /// `apart` over a cell multiset as a persistent aggregate: a one-cell
        /// extension is one insertion into its predecessor, never a sort of the
        /// old cells again. `all` every distinct cell met (values joined as a
        /// set joins them); `dups` the cells met twice, `dups_approx` those one
        /// of whose occurrences was approximate; `lost_extra` a member's own
        /// approximation (an occurrence `all`'s join forgets); `group` the
        /// arrivals; `whole`/`elems` the parents §2.9's taken-element rule
        /// compares; `bases` base → the group's cells over it; `pairs` the
        /// same-base pairs' conditions; `hit` the taken-element rule met.
        pub const Agg = struct {
            all: SetId = .none,
            all_len: u32 = 0,
            dups: SetId = .none,
            dups_approx: SetId = .none,
            lost_extra: bool = false,
            group: SetId = .none,
            group_len: u32 = 0,
            whole: SetId = .none,
            elems: SetId = .none,
            bases: u32 = Ids.none_int,
            pairs: CondId = yes,
            hit: bool = false,
            /// `apartImage`'s images → the list sides that reached each (a set),
            /// or none once one arrival was no side (§2.9 *Two positions of one
            /// image*).
            sides: u32 = Ids.none_int,
        };

        pub fn agg(t: *Table, gpa: Allocator, a: Agg) Error!u32 {
            try t.aggs.append(gpa, a);
            return @intCast(t.aggs.items.len - 1);
        }

        /// `a` with one occurrence of `c` more. `multiset`: a cell met again is
        /// a repeat (two members holding it); otherwise the occurrences join as
        /// a set's do (`a` is one member's reach).
        pub fn aggAdd(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a0: Agg, c: CellId, approx: bool, multiset: bool) Error!Agg {
            var a = a0;
            try charge.reserve(gpa, .inspection, 1);
            const sets = &cellt.sets;
            if (sets.get(a.all, c.int())) |old| {
                if (multiset) {
                    a.dups = try sets.insert(gpa, charge, a.dups, c.int(), 0);
                    if (approx or old == 1) a.dups_approx = try sets.insert(gpa, charge, a.dups_approx, c.int(), 0);
                }
                a.all = try sets.insert(gpa, charge, a.all, c.int(), @intFromBool(approx));
                return a;
            }
            a.all = try sets.insert(gpa, charge, a.all, c.int(), @intFromBool(approx));
            a.all_len += 1;
            const o = cellt.origin(c);
            std.debug.assert(o != .mark);
            if (isConcrete(o) or o == .top) return a;
            const before = a.group;
            a.group = try sets.insert(gpa, charge, a.group, c.int(), 0);
            a.group_len += 1;
            try charge.reserve(gpa, .memo, 1);
            const prov = try t.group_prov.getOrPut(gpa, .{a.group.int()});
            if (!prov.found_existing) {
                prov.value_ptr.* = @intCast(t.group_steps.items.len);
                try t.group_steps.append(gpa, .{ before.int(), c.int() });
            }
            // The taken-element rule: a taken element stored beside its
            // container's `c[*]` (`apart`'s `whole`).
            const p = cellt.parent(c);
            const d = cellt.get(c);
            if (o.isSymbolic() and places.pathParent(.from(d.b)) != .none and places.pathStep(.from(d.b)).kind == .elem) {
                a.whole = try sets.insert(gpa, charge, a.whole, p.int(), 0);
                if (sets.member(a.elems, p.int())) a.hit = true;
            }
            if (o == .elem) {
                a.elems = try sets.insert(gpa, charge, a.elems, p.int(), 0);
                if (sets.member(a.whole, p.int())) a.hit = true;
            }
            // The pairs over one base `alias` does not tell apart (`sameBasePairs`):
            // one pair per split's run, every pair across runs.
            const b = cellt.base(c);
            const same: SetId = if (t.mapGet(a.bases, b.int())) |s| .from(s) else .none;
            if (try covered(gpa, charge, cellt, same, c)) return a;
            const split = splitKey(cellt, c);
            var run: ?CellId = null;
            var run_len: u32 = 0;
            var it = sets.iterate(same);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const y: CellId = .from(e.key);
                if (sameAnchor(split, splitKey(cellt, y))) continue;
                if (sameRun(split, splitKey(cellt, y))) {
                    run_len += 1;
                    run = y;
                    continue;
                }
                if (cellt.alias(places, c, y) == .no) continue;
                a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, y, false, null));
            }
            if (run_len == 1) if (run) |y| if (cellt.alias(places, c, y) != .no) {
                a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.sep(gpa, charge, cellt, places, c, y, false, null));
            };
            a.bases = try t.mapPut(gpa, charge, a.bases, b.int(), (try sets.insert(gpa, charge, same, c.int(), 0)).int());
            return a;
        }

        /// The split run a cell belongs to, and its anchor: an `elem`/`others`
        /// by its split, a part of one by its anchor's (§2.2 *Parts*: what is
        /// below two sides of one split is apart under it, whatever the paths).
        fn splitKey(cellt: *const Cell.Table, x: CellId) [3]u32 {
            const d = cellt.get(x);
            const anchor: CellId = if (d.origin == .part) .from(d.a) else x;
            const o = cellt.origin(anchor);
            if (o != .elem and o != .others) return .{ Ids.none_int, x.int(), Ids.none_int };
            const r = cellt.get(anchor);
            return .{ r.parent.int(), r.b, anchor.int() };
        }

        /// Two cells of one split run (`splitKey`) below two of its sides: one
        /// anchor's cells are not, its parts compare by `alias`.
        fn sameRun(a: [3]u32, b: [3]u32) bool {
            return a[0] != Ids.none_int and a[0] == b[0] and a[1] == b[1] and a[2] != b[2];
        }

        /// Two cells of one anchor (`splitKey`), one of them a part: compared as
        /// two symbolic cells of one origin are, by no same-base pair (§2.2
        /// *Parts*); `apart`'s atom over the group reads them.
        fn sameAnchor(a: [3]u32, b: [3]u32) bool {
            return a[0] != Ids.none_int and std.mem.eql(u32, &a, &b);
        }

        /// Whether `c` is a part (§2.2 *Parts*) whose anchor, or a shorter part
        /// of it, is in `same`. That pair is `lost` (`alias` says `yes`), and
        /// every other cell meets `c` as it meets that ancestor: a side of the
        /// anchor's split by the split's κ, a cell above or apart alike, a cell
        /// below the anchor `lost` or not at all. So `c` adds nothing more, and
        /// one base's cells stay one per position, not one per position and
        /// part. Only parts: a split's sides answer more than their container.
        fn covered(gpa: Allocator, charge: Charge, cellt: *const Cell.Table, same: SetId, c: CellId) Error!bool {
            var at = c;
            while (cellt.origin(at) == .part) {
                try charge.reserve(gpa, .inspection, 1);
                at = cellt.parent(at);
                if (cellt.sets.member(same, at.int())) return true;
            }
            return false;
        }

        /// Every cell of `from` added to `a` (`multiset` as `aggAdd`).
        pub fn aggAll(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a0: Agg, from: SetId, multiset: bool) Error!Agg {
            var a = a0;
            var it = cellt.sets.iterate(from);
            while (it.next()) |e| a = try t.aggAdd(gpa, charge, cellt, places, a, .from(e.key), e.value == 1, multiset);
            return a;
        }

        /// Two aggregates as one: the smaller's cells added to the larger's.
        pub fn aggMerge(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, x: Agg, y: Agg, multiset: bool) Error!Agg {
            const big, const small = if (x.all_len >= y.all_len) .{ x, y } else .{ y, x };
            // What the smaller side adds, its subtrees the larger shares
            // skipped whole (a DAG's two sides share most of their reach).
            var added: std.ArrayList(Cell.Radix.Iterator.Entry) = .empty;
            defer added.deinit(gpa);
            try cellt.sets.news(gpa, charge, big.all, small.all, &added);
            var a = big;
            for (added.items) |e| a = try t.aggAdd(gpa, charge, cellt, places, a, .from(e.key), e.value == 1, false);
            if (multiset) {
                // Both sides' cells are repeats, one approximate where either
                // occurrence is; a member's own approximation, which `all`'s join
                // forgets; the smaller side's own repeats.
                const both = try cellt.sets.intersection(gpa, charge, big.all, small.all);
                var it = cellt.sets.iterate(both);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    a.dups = try cellt.sets.insert(gpa, charge, a.dups, e.key, 0);
                    if (e.value == 1) a.dups_approx = try cellt.sets.insert(gpa, charge, a.dups_approx, e.key, 0);
                }
                a.lost_extra = a.lost_extra or small.lost_extra or try t.anyLost(gpa, charge, cellt, small.all) or try t.anyLost(gpa, charge, cellt, big.all);
                a.dups = try cellt.sets.unionWith(gpa, charge, a.dups, small.dups);
                a.dups_approx = try cellt.sets.unionWith(gpa, charge, a.dups_approx, small.dups_approx);
            }
            return a;
        }

        /// The aggregate of two cell sets as one multiset (an atom's two sides,
        /// `apart [A] [B]`): `aggMerge` of their set aggregates, made along the
        /// two radix tries and memoised per pair of set nodes. Disjoint halves
        /// join structurally (`aggJoin`); a node both sides share is all repeats;
        /// a leaf against a set is one `aggAdd`. So two sets that both grew pay
        /// their changed spines, never the smaller side's size. The recursion is
        /// the key width.
        pub fn aggMergeSets(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a: SetId, b: SetId) Error!Agg {
            var out = try t.aggMergeSetsAt(gpa, charge, cellt, places, a, b);
            // A member's own approximation, which `all`'s join forgets.
            out.lost_extra = out.lost_extra or try t.anyLost(gpa, charge, cellt, a) or try t.anyLost(gpa, charge, cellt, b);
            return out;
        }

        pub fn aggMergeSetsAt(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a: SetId, b: SetId) Error!Agg {
            if (a == .none) return t.setAgg(gpa, charge, cellt, places, b);
            if (b == .none) return t.setAgg(gpa, charge, cellt, places, a);
            const sets = &cellt.sets;
            if (a == b) {
                // Every cell twice: all repeats, approximate where either is.
                var x = try t.setAgg(gpa, charge, cellt, places, a);
                x.dups = try sets.unionWith(gpa, charge, x.dups, a);
                x.dups_approx = try sets.unionWith(gpa, charge, x.dups_approx, try t.cellPart(gpa, charge, cellt, places, .approx, a));
                return x;
            }
            const key: [2]u32 = .{ @min(a.int(), b.int()), @max(a.int(), b.int()) };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_agg_pair.get(key)) |hit| return t.aggs.items[hit];
            const na = sets.branches(a);
            const nb = sets.branches(b);
            const out: Agg = blk: {
                if (na == null or nb == null) {
                    // A leaf: its one cell added to the other side, a repeat when
                    // that side holds it.
                    const leaf = if (na == null) a else b;
                    const other = if (na == null) b else a;
                    var it = sets.iterate(leaf);
                    const e = it.next().?;
                    const base = try t.setAgg(gpa, charge, cellt, places, other);
                    if (cellt.origin(.from(e.key)) == .mark) break :blk base;
                    break :blk try t.aggAdd(gpa, charge, cellt, places, base, .from(e.key), e.value == 1, true);
                }
                const ra = sets.radixNode(a);
                const rb = sets.radixNode(b);
                if (ra.mask == rb.mask and ra.prefix == rb.prefix) break :blk try t.aggJoin(gpa, charge, cellt, places, try t.aggMergeSetsAt(gpa, charge, cellt, places, na.?[0], nb.?[0]), try t.aggMergeSetsAt(gpa, charge, cellt, places, na.?[1], nb.?[1]));
                if (ra.mask > rb.mask and sets.under(rb.prefix, ra.prefix, ra.mask)) {
                    const zero = sets.zeroAt(rb.prefix, ra.mask);
                    break :blk try t.aggJoin(gpa, charge, cellt, places, try t.aggMergeSetsAt(gpa, charge, cellt, places, if (zero) na.?[0] else na.?[1], b), try t.setAgg(gpa, charge, cellt, places, if (zero) na.?[1] else na.?[0]));
                }
                if (rb.mask > ra.mask and sets.under(ra.prefix, rb.prefix, rb.mask)) {
                    const zero = sets.zeroAt(ra.prefix, rb.mask);
                    break :blk try t.aggJoin(gpa, charge, cellt, places, try t.aggMergeSetsAt(gpa, charge, cellt, places, a, if (zero) nb.?[0] else nb.?[1]), try t.setAgg(gpa, charge, cellt, places, if (zero) nb.?[1] else nb.?[0]));
                }
                // Disjoint prefixes: no repeat.
                break :blk try t.aggJoin(gpa, charge, cellt, places, try t.setAgg(gpa, charge, cellt, places, a), try t.setAgg(gpa, charge, cellt, places, b));
            };
            const got = try t.agg(gpa, out);
            (try t.memo_agg_pair.getOrPut(gpa, key)).value_ptr.* = got;
            return out;
        }

        /// `aggMerge` of two multisets (an atom's sides): an empty side is the
        /// other, as it is.
        pub fn aggMergeMulti(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, x: Agg, y: Agg) Error!Agg {
            if (x.all == .none) return y;
            if (y.all == .none) return x;
            return t.aggMerge(gpa, charge, cellt, places, x, y, true);
        }

        /// §2.9's apart condition of an aggregate: `apart`'s over its cells.
        pub fn aggCond(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a: Agg) Error!CondId {
            // A cell met twice: `sep(c, c)` (§2.9), `shared` for one exact, not `⊤`
            // and standing for one position, `lost` otherwise. Decided over the
            // repeats' set: memoised per radix node, never cell by cell.
            var acc: CondId = yes;
            if (a.dups != .none) {
                if (!try cellt.sets.keysWithin(gpa, charge, try t.cellPart(gpa, charge, cellt, places, .unfolded, a.dups), a.dups_approx)) return shared;
                acc = lost;
            }
            if (a.lost_extra or try t.anyLost(gpa, charge, cellt, a.all)) acc = try t.@"and"(gpa, charge, acc, lost);
            if (a.group_len >= 2) {
                if (a.hit) return shared;
                acc = try t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, a.group));
                acc = try t.@"and"(gpa, charge, acc, a.pairs);
            }
            return acc;
        }

        /// Whether a cell set holds an approximate pair or `⊤`, memoised per
        /// node of the persistent set, so a new root reads its changed spine.
        pub fn anyLost(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, s: SetId) Error!bool {
            if (s == .none) return false;
            // One cell: read at once, never memoised.
            if (cellt.sets.branches(s) == null) {
                try charge.reserve(gpa, .inspection, 1);
                var it = cellt.sets.iterate(s);
                const e = it.next().?;
                return e.value == 1 or cellt.origin(.from(e.key)) == .top;
            }
            try charge.reserve(gpa, .memo, 1);
            if (t.lost_memo.get(.{s.int()})) |v| return v == 1;
            var stack: std.ArrayList(SetId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, s);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.lost_memo.get(.{x.int()}) != null) {
                    _ = stack.pop();
                    continue;
                }
                try charge.reserve(gpa, .inspection, 1);
                const v: bool = if (cellt.sets.branches(x)) |kids| blk: {
                    const l = t.lost_memo.get(.{kids[0].int()});
                    const r = t.lost_memo.get(.{kids[1].int()});
                    if (l == null or r == null) {
                        if (l == null) try stack.append(gpa, kids[0]);
                        if (r == null) try stack.append(gpa, kids[1]);
                        continue;
                    }
                    break :blk l.? == 1 or r.? == 1;
                } else blk: {
                    var it = cellt.sets.iterate(x);
                    const e = it.next().?;
                    break :blk e.value == 1 or cellt.origin(.from(e.key)) == .top;
                };
                (try t.lost_memo.getOrPut(gpa, .{x.int()})).value_ptr.* = @intFromBool(v);
                _ = stack.pop();
            }
            return t.lost_memo.get(.{s.int()}).? == 1;
        }

        /// The aggregate of `n`'s reach (every cell of its explicit structure,
        /// as a set), memoised per node: a node of finite rank merges its
        /// parts' aggregates, the larger extended by the smaller's cells and its
        /// own (so a tower's level adds its own cells, O(log) each); a node on
        /// or above a cycle, from its reach set.
        pub fn reachAgg(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!Agg {
            try charge.reserve(gpa, .memo, 1);
            if (t.reachMemo(v, n)) |hit| return t.aggs.items[hit];
            const walk = try v.shapes.dagWalk(gpa, charge.account, n);
            defer if (walk) |k| charge.account.leave(k);
            // Post-order over the parts on an explicit stack (a value is as
            // deep as the source). A part met again while it is open is on a
            // cycle: a node whose part has no aggregate yet takes its own from
            // its reach set (`Shape.reach` closes the cycle), so only a cycle,
            // never a recast or a deep DAG, reads a whole reach.
            const Frame = struct { node: NodeId, expanded: bool };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            const open = try t.marks.take(gpa);
            defer t.marks.give(open);
            var parts: std.ArrayList(NodeId) = .empty;
            defer parts.deinit(gpa);
            try stack.append(gpa, .{ .node = n, .expanded = false });
            while (stack.pop()) |f| {
                if (t.reachMemo(v, f.node) != null) continue;
                parts.clearRetainingCapacity();
                try partsOf(gpa, charge, v, f.node, &parts);
                if (!f.expanded) {
                    if (open.contains(f.node)) continue;
                    try open.put(gpa, f.node, {});
                    try stack.append(gpa, .{ .node = f.node, .expanded = true });
                    for (parts.items) |p| if (t.reachMemo(v, p) == null) try stack.append(gpa, .{ .node = p, .expanded = false });
                    continue;
                }
                open.remove(f.node);
                // The largest part's aggregate, the others' and the node's own
                // cells added to it.
                var best: ?Agg = null;
                const whole = for (parts.items) |p| {
                    try charge.reserve(gpa, .memo, 1);
                    const pi = t.reachMemo(v, p) orelse break true;
                    const pa = t.aggs.items[pi];
                    best = if (best) |b| try t.aggMerge(gpa, charge, v.cells, v.places, b, pa, false) else pa;
                } else false;
                const a = if (whole)
                    try t.aggAll(gpa, charge, v.cells, v.places, .{}, try v.shapes.reach(gpa, charge.account, &v.cells.sets, f.node), false)
                else
                    try t.aggAll(gpa, charge, v.cells, v.places, best orelse .{}, if (v.shapes.isLazy(f.node)) SetId.none else v.shapes.cells(f.node), false);
                const got = try t.agg(gpa, a);
                (try t.reach_agg.getOrPut(gpa, .{f.node.int()})).value_ptr.* = got;
                (try t.reach_epoch.getOrPut(gpa, .{f.node.int()})).value_ptr.* = v.shapes.ties;
            }
            return t.aggs.items[t.reachMemo(v, n).?];
        }

        /// `n`'s reach aggregate, if made since the last knot was tied.
        pub fn reachMemo(t: *const Table, v: View, n: NodeId) ?u32 {
            const at = t.reach_agg.get(.{n.int()}) orelse return null;
            return if (t.reach_epoch.get(.{n.int()}) == v.shapes.ties) at else null;
        }

        /// The parts of `n` whose cells its reach holds.
        fn partsOf(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
            const d = v.shapes.get(n);
            switch (d.kind) {
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try out.append(gpa, .from(d.a));
                    var it = v.shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| try out.append(gpa, e.node);
                },
                .recast => try out.append(gpa, .from(d.a)),
                .@"union", .choice, .positions => try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
                // A view holds what its answer holds (§2.11).
                .view => try out.append(gpa, try v.shapes.force(gpa, charge.account, n)),
            }
        }

        /// The apart condition of `group`'s cells' images (`image` maps one), a
        /// multiset: each group is extended from its predecessor's image
        /// (`group_prov`), `memo` holding the images built under this `image`.
        /// One arrival `c` at image `m` (§2.9 *Two positions of one image*):
        /// a repeat, as `aggAdd`'s multiset counts it, unless `m` is symbolic,
        /// off a fold, and every earlier arrival at it is another side of one
        /// list split (`Cell.listSide`, the sides kept per image in `a.sides`):
        /// then `c` is another position of `m` and owes `excl m`. Constant
        /// work per arrival.
        fn addArrival(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, a0: Agg, c: CellId, m: CellId) Error!Agg {
            try charge.reserve(gpa, .inspection, 1);
            const at_side = cellt.listSide(c);
            const sides_now = t.mapGet(a0.sides, m.int());
            const met = cellt.sets.get(a0.all, m.int()) != null;
            var positions = false;
            if (met and repeatingSplit(cellt, c) == null) if (at_side) |sd| if (sideHolds(cellt, sd)) if (sides_now) |raw| if (raw != Ids.none_int) {
                const set: SetId = .from(raw);
                var it = cellt.sets.iterate(set);
                const one: CellId = .from(it.next().?.key);
                const o = cellt.origin(m);
                positions = o.isSymbolic() and o != .top and !onFold(places, .from(cellt.get(m).b)) and
                    cellt.sameSplit(one, sd) and !cellt.sets.member(set, sd.int());
            };
            var a = try t.aggAdd(gpa, charge, cellt, places, a0, m, false, !positions);
            if (positions) {
                a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.excl(gpa, charge, m));
                a.sides = try t.mapPut(gpa, charge, a.sides, m.int(), (try cellt.sets.insert(gpa, charge, .from(sides_now.?), at_side.?.int(), 0)).int());
            } else if (!met) {
                a.sides = try t.mapPut(gpa, charge, a.sides, m.int(), if (at_side) |sd| (try cellt.sets.insert(gpa, charge, .none, sd.int(), 0)).int() else Ids.none_int);
            }
            return a;
        }

        fn onFold(places: *const Cell.Places, path: Ids.PathId) bool {
            var q = path;
            while (places.pathParent(q) != .none) : (q = places.pathParent(q)) if (places.pathStep(q).kind == .level) return true;
            return false;
        }

        pub fn apartImage(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, group: SetId, memo: *Ids.FixedDict(1), ctx: anytype, image: *const fn (@TypeOf(ctx), CellId) Error!CellId) Error!CondId {
            var chain: std.ArrayList([2]u32) = .empty;
            defer chain.deinit(gpa);
            var at = group;
            var start: Agg = .{};
            var base: SetId = .none;
            while (at != .none) {
                try charge.reserve(gpa, .memo, 1);
                if (memo.get(.{at.int()})) |hit| {
                    start = t.aggs.items[hit];
                    break;
                }
                // A set no aggregate built: its cells from nothing.
                const step = t.group_prov.get(.{at.int()}) orelse {
                    base = at;
                    break;
                };
                const s = t.group_steps.items[step];
                try chain.append(gpa, .{ at.int(), s[1] });
                at = .from(s[0]);
            }
            // New cells imaged in set order: `image` numbers by content (#1150).
            var fresh: std.ArrayList(u32) = .empty;
            defer fresh.deinit(gpa);
            var bt = cellt.sets.iterate(base);
            while (bt.next()) |e| try fresh.append(gpa, e.key);
            for (chain.items) |x| try fresh.append(gpa, x[1]);
            std.mem.sort(u32, fresh.items, {}, std.sort.asc(u32));
            for (fresh.items) |c| {
                try charge.reserve(gpa, .inspection, 1);
                _ = try image(ctx, .from(c));
            }
            if (base != .none) {
                var it = cellt.sets.iterate(base);
                while (it.next()) |e| start = try addArrival(t, gpa, charge, cellt, places, start, .from(e.key), try image(ctx, .from(e.key)));
                const got = try t.agg(gpa, start);
                (try memo.getOrPut(gpa, .{base.int()})).value_ptr.* = got;
            }
            var a = start;
            while (chain.pop()) |x| {
                a = try addArrival(t, gpa, charge, cellt, places, a, .from(x[1]), try image(ctx, .from(x[1])));
                const got = try t.agg(gpa, a);
                (try memo.getOrPut(gpa, .{x[0]})).value_ptr.* = got;
            }
            return t.aggCond(gpa, charge, cellt, places, a);
        }

        // ---- the path-multiset primitive (§2.9, #1128) --------------------------------

        /// Per destination class (a widened image node), the aggregate of the
        /// source occurrences μ maps into it: a persistent map image → `aggs`
        /// index, and how many classes it names (for merging small into large).
        /// `saturated`: a cyclic source, every class it reaches all repeated.
        pub const ClassAggs = struct { map: u32 = Ids.none_int, len: u32 = 0, saturated: bool = false };

        // ---- the path-multiset primitive for a client's walk (#1159) ---------------------

        /// One key holding each of `cells` once: a source node's own contents at
        /// its position (a cell's approximation is its set value).
        pub fn classesOf(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, key: u32, cells: SetId) Error!ClassAggs {
            if (cells == .none) return .{};
            const a = try t.aggAll(gpa, charge, cellt, places, .{}, cells, false);
            return .{ .map = try t.mapPut(gpa, charge, Ids.none_int, key, try t.agg(gpa, a)), .len = 1 };
        }

        /// Two contributions as one: coexisting (`together`, a multiset sum) or
        /// a choice's arms (the maximum, whole arm by whole arm).
        pub fn classesMerge(t: *Table, gpa: Allocator, charge: Charge, v: View, x: ClassAggs, y: ClassAggs, together: bool) Error!ClassAggs {
            if (x.len == 0) return y;
            if (y.len == 0) return x;
            return t.classMerge(gpa, charge, v, x, y, together);
        }

        /// Every occurrence repeated: a source on a cycle reaches each key below
        /// it at unboundedly many coexisting positions.
        pub fn classesRepeated(t: *Table, gpa: Allocator, charge: Charge, x: ClassAggs) Error!ClassAggs {
            var out: ClassAggs = .{ .saturated = true };
            var it = t.mapEntries(x.map);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                var a = t.aggs.items[e.value];
                a.dups = a.all;
                out.map = try t.mapPut(gpa, charge, out.map, e.key, try t.agg(gpa, a));
                out.len += 1;
            }
            return out;
        }

        /// The obligation of the occurrences at `key` (§2.9's three parts): a
        /// repeat `lost` (through a fold, never `shared`), distinct arrivals
        /// `apart`, and `summaryExcl` — `excl c` — for each symbolic arrival at
        /// a summary path, which stands for many objects whose own separation is
        /// its holder's (#1199); `yes` where no occurrence maps.
        pub fn classesRead(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, x: ClassAggs, key: u32) Error!CondId {
            try charge.reserve(gpa, .memo, 1);
            const a = t.mapGet(x.map, key) orelse return yes;
            var k = try t.foldCond(gpa, charge, cellt, places, t.aggs.items[a]);
            var it = cellt.sets.iterate(t.aggs.items[a].all);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                const o = cellt.origin(c);
                if (o.isSymbolic() and o != .top and places.isSummary(.from(cellt.get(c).b))) k = try t.@"and"(gpa, charge, k, try t.exclOf(gpa, charge, cellt, c));
            }
            return k;
        }

        /// The cells occurring at `key`, as a set (their approximation kept).
        pub fn classesCells(t: *const Table, x: ClassAggs, key: u32) SetId {
            const a = t.mapGet(x.map, key) orelse return .none;
            return t.aggs.items[a].all;
        }

        /// A client walk's result by `(node, key)`, kept across reads and calls:
        /// both are immutable, so an answer is never stale. Charged, hit or miss.
        pub fn classesMemo(t: *Table, gpa: Allocator, charge: Charge, n: NodeId, key: u32) Error!?ClassAggs {
            try charge.reserve(gpa, .memo, 1);
            const i = t.classes_memo.get(.{ n.int(), key }) orelse return null;
            return t.classes_done.items[i];
        }

        pub fn classesRemember(t: *Table, gpa: Allocator, charge: Charge, n: NodeId, key: u32, x: ClassAggs) Error!void {
            try charge.reserve(gpa, .memo, 1);
            try t.classes_done.ensureUnusedCapacity(gpa, 1);
            const got = try t.classes_memo.getOrPut(gpa, .{ n.int(), key });
            if (got.found_existing) return;
            got.value_ptr.* = @intCast(t.classes_done.items.len);
            t.classes_done.appendAssumeCapacity(x);
        }

        /// The fold obligations a read of `n` meets at its own position: its
        /// own, and through a union, choice or positions DAG its sides' (a class
        /// image rides there beside the class's other members).
        pub fn foldCondOf(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!CondId {
            if (t.fold_cond_n == 0) return yes;
            // Memoised per node: `fold_cond` only gains entries for fresh image
            // ids, which no existing DAG holds, so an answer never goes stale.
            try charge.reserve(gpa, .memo, 1);
            if (t.fold_of.get(n)) |hit| return hit;
            return t.foldCondWalk(gpa, charge, v, n);
        }

        /// `foldCondOf`'s walk: one Tarjan walk (`Shape.Table.cycleWalk`) over
        /// a union's, a choice's or a positions node's sides and a view's
        /// answer, so a cycle of them with no node on it (#1335) ends at its
        /// least fixed point: every member owes what every member owns and what
        /// enters the cycle (§2.11 *A cycle with no node on it*).
        pub fn foldCondWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId) Error!CondId {
            var w: FoldWalk = .{ .t = t, .gpa = gpa, .charge = charge, .v = v };
            try v.shapes.cycleWalk(gpa, n, &w);
            return t.fold_of.get(n).?;
        }

        /// `foldCondWalk`'s relation. A record whose parts are answered already
        /// is answered on entry, so a chain of unions costs each its own node
        /// once, a record that waited once more, as the post-order on a stack did.
        const FoldWalk = struct {
            t: *Table,
            gpa: Allocator,
            charge: Charge,
            v: View,

            /// The right side first; a view's answer.
            fn parts(w: *FoldWalk, x: NodeId) Error![2]NodeId {
                const shapes = w.v.shapes;
                return switch (shapes.kind(x)) {
                    .@"union", .choice, .positions => .{ .from(shapes.get(x).b), .from(shapes.get(x).a) },
                    .view => .{ try shapes.force(w.gpa, w.charge.account, x), .none },
                    else => .{ .none, .none },
                };
            }

            /// `x`'s own certificate and its parts' answers, the left side's
            /// first, or null while a part has none.
            fn answer(w: *FoldWalk, x: NodeId, two: [2]NodeId) Error!?CondId {
                const t = w.t;
                const acc: CondId = t.fold_cond.get(x) orelse yes;
                if (two[0] == .none) return acc;
                const r = t.fold_of.get(two[0]) orelse return null;
                if (two[1] == .none) return try t.@"and"(w.gpa, w.charge, acc, r);
                const l = t.fold_of.get(two[1]) orelse return null;
                return try t.@"and"(w.gpa, w.charge, acc, try t.@"and"(w.gpa, w.charge, l, r));
            }

            pub fn from(w: *FoldWalk, x: NodeId) Error![2]NodeId {
                try w.charge.reserve(w.gpa, .inspection, 1);
                const two = try w.parts(x);
                if (try w.answer(x, two)) |k| try w.t.fold_of.put(w.gpa, x, k);
                return two;
            }

            pub fn settled(w: *const FoldWalk, x: NodeId) bool {
                return w.t.fold_of.get(x) != null;
            }

            pub fn settle(w: *FoldWalk, members: []const NodeId) Error!void {
                const t = w.t;
                if (members.len == 1 and w.settled(members[0])) return;
                try w.charge.reserve(w.gpa, .inspection, @intCast(members.len));
                if (members.len == 1) {
                    const two = try w.parts(members[0]);
                    if (try w.answer(members[0], two)) |k| return t.fold_of.put(w.gpa, members[0], k);
                }
                // A cycle: what its members own, and what enters it.
                var acc: CondId = yes;
                for (members) |m| {
                    acc = try t.@"and"(w.gpa, w.charge, acc, t.fold_cond.get(m) orelse yes);
                    for (try w.parts(m)) |y| if (y != .none) if (t.fold_of.get(y)) |k| {
                        acc = try t.@"and"(w.gpa, w.charge, acc, k);
                    };
                }
                // A fixed point by construction: each member owes every
                // conjunct of every member.
                for (members) |m| try t.fold_of.put(w.gpa, m, acc);
            }
        };

        /// A folded class's obligation from its aggregate: a repeat is
        /// identified through the fold (`lost`, never `shared`: the levels it
        /// merged were never compared), distinct arrivals `apart`.
        pub fn foldCond(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *const Cell.Places, a: Agg) Error!CondId {
            var plain = a;
            plain.dups = .none;
            plain.dups_approx = .none;
            const k = try t.aggCond(gpa, charge, cellt, places, plain);
            return if (a.dups != .none) t.@"and"(gpa, charge, k, lost) else k;
        }

        /// The aggregates of `x`'s source occurrences by destination class: a
        /// post-order over the source on an explicit stack (a value is as deep
        /// as the source), each node's own cells at its image with its parts'
        /// aggregates, every node once (shared parts are re-read by reference,
        /// so two routes count twice where they coexist and once where they are
        /// a choice). A source on a cycle has no finite multiset by this walk:
        /// every class it reaches reads all its cells repeated (sound, `lost`).
        pub fn arrivalAggs(t: *Table, gpa: Allocator, charge: Charge, v: View, x: NodeId, fold: *const Shape.Table.Fold) Error!ClassAggs {
            var memo: stamped.Column(NodeId, ClassAggs) = .{};
            defer memo.deinit(gpa);
            var open: stamped.Column(NodeId, void) = .{};
            defer open.deinit(gpa);
            const Frame = struct { node: NodeId, expanded: bool };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var parts: std.ArrayList(NodeId) = .empty;
            defer parts.deinit(gpa);
            var cyclic = false;
            // The widen walked answers: a view root is read at its answer, but a
            // hypothesis node, which is read by its certificate (#1485).
            const root = if (t.hypEnv(v, x) != null) x else try v.shapes.force(gpa, charge.account, x);
            try stack.append(gpa, .{ .node = root, .expanded = false });
            while (stack.pop()) |f| {
                if (memo.get(f.node) != null) continue;
                if (t.hypEnv(v, f.node)) |e| {
                    // A hypothesis node: its certificate, never its cycle.
                    const got = try t.hypAggs(gpa, charge, v, fold, f.node, e) orelse {
                        cyclic = true;
                        break;
                    };
                    try memo.put(gpa, f.node, got);
                    continue;
                }
                parts.clearRetainingCapacity();
                try t.sourceParts(gpa, charge, v, fold, f.node, &parts);
                // An opened choice's arms: the maximum, arm by arm (§2.3).
                const arms = v.shapes.kind(f.node) == .choice and fold.opened.contains(f.node);
                if (!f.expanded) {
                    if (open.contains(f.node)) {
                        cyclic = true;
                        continue;
                    }
                    try open.put(gpa, f.node, {});
                    try stack.append(gpa, .{ .node = f.node, .expanded = true });
                    for (parts.items) |p| if (memo.get(p) == null) try stack.append(gpa, .{ .node = p, .expanded = false });
                    continue;
                }
                open.remove(f.node);
                if (cyclic) break;
                var acc: ClassAggs = .{};
                for (parts.items, 0..) |p, i| {
                    try charge.reserve(gpa, .memo, 1);
                    const pa = memo.get(p) orelse {
                        cyclic = true;
                        break;
                    };
                    acc = if (i == 0) pa else try t.classMerge(gpa, charge, v, acc, pa, !arms);
                }
                if (cyclic) break;
                if (fold.image.get(f.node)) |img| {
                    const own = try t.ownAgg(gpa, charge, v, fold, f.node);
                    if (own.all_len > 0) acc = try t.classMerge(gpa, charge, v, acc, .{ .map = try t.mapPut(gpa, charge, Ids.none_int, img.int(), try t.agg(gpa, own)), .len = 1 }, true);
                }
                try memo.put(gpa, f.node, acc);
            }
            if (!cyclic) return memo.get(root).?;
            // On a cycle: every source node's cells at its class, all repeated.
            var all: stamped.Column(NodeId, SetId) = .{};
            defer all.deinit(gpa);
            var images: std.ArrayList(NodeId) = .empty;
            defer images.deinit(gpa);
            var seen: stamped.Column(NodeId, void) = .{};
            defer seen.deinit(gpa);
            var walk: std.ArrayList(NodeId) = .empty;
            defer walk.deinit(gpa);
            try walk.append(gpa, try v.shapes.force(gpa, charge.account, x));
            while (walk.pop()) |n| {
                if (seen.contains(n)) continue;
                try seen.put(gpa, n, {});
                try charge.reserve(gpa, .inspection, 1);
                if (fold.image.get(n)) |img| {
                    const old = all.get(img) orelse blk: {
                        try images.append(gpa, img);
                        break :blk SetId.none;
                    };
                    try all.put(gpa, img, try v.cells.sets.unionWith(gpa, charge, old, if (v.shapes.isLazy(n)) SetId.none else v.shapes.cells(n)));
                }
                parts.clearRetainingCapacity();
                try t.sourceParts(gpa, charge, v, fold, n, &parts);
                for (parts.items) |*p| p.* = try v.shapes.force(gpa, charge.account, p.*);
                try walk.appendSlice(gpa, parts.items);
            }
            var out: ClassAggs = .{ .saturated = true };
            for (images.items) |img| {
                const cells = all.get(img).?;
                var a = try t.aggAll(gpa, charge, v.cells, v.places, .{}, cells, false);
                a.dups = cells;
                out.map = try t.mapPut(gpa, charge, out.map, img.int(), try t.agg(gpa, a));
                out.len += 1;
            }
            return out;
        }

        /// The environment of `n` when it is a hypothesis node (§8 slice 4,
        /// *The hypothesis node*, #1485), null for any other node.
        pub fn hypEnv(t: *const Table, v: View, n: NodeId) ?u32 {
            const h = t.hyp orelse return null;
            if (t.hyp_knots.contains(n)) return identity_env;
            const view = t.hyp_nodes.get(n) orelse n;
            if (v.shapes.kind(view) != .view) return null;
            return h.envOf(h.ctx, v.shapes, view);
        }

        /// A hypothesis node's contribution (§8 slice 4, *The hypothesis
        /// node*; §2.9 rule 4, #1485): the walk does not enter the view's
        /// cycle. Each class of its template (a node of the callee's widened
        /// `res`, a union's or choice's sides one class with it) gives its
        /// certificate's arrival keys, instantiated through the view's
        /// environment by rule 4, at the class of the caller's fold that the
        /// view's answer puts it in (the fold's steps, in lockstep). A group's
        /// keys enter once per image (the maximum), each pair of them merged
        /// onto one image owing `exclOf`; keys in no group, and the classes
        /// of the template, add. Null where the caller's fold has no class
        /// for a template class: the walk then saturates, as before.
        pub fn hypAggs(t: *Table, gpa: Allocator, charge: Charge, v: View, fold: *const Shape.Table.Fold, n: NodeId, e: u32) Error!?ClassAggs {
            const shapes = v.shapes;
            const view = t.hyp_nodes.get(n) orelse n;
            const template: NodeId = if (e == identity_env) n else .from(shapes.get(view).a);
            const img0 = fold.image.get(n) orelse fold.image.get(try shapes.force(gpa, charge.account, view)) orelse {
                return null;
            };
            var out: ClassAggs = .{};
            var seen: Ids.FixedDict(2) = .{};
            defer seen.deinit(gpa);
            const Entry = struct { tn: NodeId, img: NodeId, pos: ClassPos };
            var stack: std.ArrayList(Entry) = .empty;
            defer stack.deinit(gpa);
            var keys: std.ArrayList(HypKey) = .empty;
            defer keys.deinit(gpa);
            var merged: Ids.FixedDict(2) = .{};
            defer merged.deinit(gpa);
            var sides: std.ArrayList(NodeId) = .empty;
            defer sides.deinit(gpa);
            const pos0: ClassPos = if (e == identity_env) undefined else t.classPos(v, e);
            try stack.append(gpa, .{ .tn = template, .img = img0, .pos = pos0 });
            while (stack.pop()) |x| {
                try charge.reserve(gpa, .inspection, 1);
                if ((try seen.getOrPut(gpa, .{ x.tn.int(), x.img.int() })).found_existing) continue;
                const tn = x.tn;
                const img = x.img;
                var a = try t.certClassAgg(gpa, charge, v, e, tn, &keys, &merged);
                // The certificate's condition at the class, its κ (#1485).
                if (e != identity_env and !mutated("cert-keys-only-reader1")) a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.classCond(gpa, charge, v, x.pos, tn, e));
                if (a.all_len > 0 or a.pairs != yes) out = try t.classesMerge(gpa, charge, v, out, .{ .map = try t.mapPut(gpa, charge, Ids.none_int, img.int(), try t.agg(gpa, a)), .len = 1 }, true);
                // The class's children, each another class.
                sides.clearRetainingCapacity();
                try sides.append(gpa, tn);
                var i: usize = 0;
                while (i < sides.items.len) : (i += 1) {
                    const s = sides.items[i];
                    const d = shapes.get(s);
                    switch (d.kind) {
                        .@"union", .choice, .positions => try sides.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
                        .node, .delta => {
                            if (d.kind == .delta) try sides.append(gpa, .from(d.a));
                            var it = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                            while (it.next()) |c| {
                                const ci = fold.steps.get(.{ img.int(), c.step.word() }) orelse {
                                    return null;
                                };
                                try stack.append(gpa, .{ .tn = c.node, .img = .from(ci), .pos = if (e == identity_env) undefined else try t.classStep(gpa, charge, v, x.pos, c.step) });
                            }
                        },
                        .view => return null, // a class is stored forced
                        .leaf, .recast => {},
                    }
                }
            }
            return out;
        }

        /// One class `tn` of a certificate at environment `e` (`identity_env`:
        /// a class's own knot): its arrival keys instantiated by §2.9 rule 4
        /// as a multiset, a group's keys once per image (the maximum), a pair
        /// of them merged onto one image owing `exclOf` (#1485). `keys` and
        /// `merged` are scratch.
        pub fn certClassAgg(t: *Table, gpa: Allocator, charge: Charge, v: View, e: u32, tn: NodeId, keys: *std.ArrayList(HypKey), merged: *Ids.FixedDict(2)) Error!Agg {
            const h = t.hyp.?;
            const cells = v.cells;
            keys.clearRetainingCapacity();
            const own = try v.shapes.cellsOf(gpa, charge.account, &cells.sets, tn);
            if (e == identity_env) {
                // A class's own knot: each of its cells once, its repeats
                // its own fold condition's.
                var it = cells.sets.iterate(own);
                while (it.next()) |c| if (cells.origin(.from(c.key)) != .mark)
                    try keys.append(gpa, .{ .key = .from(c.key), .image = .from(c.key), .approx = c.value == 1, .group = Ids.none_int });
            } else try h.keys(h.ctx, gpa, charge, e, own, keys);
            merged.deinit(gpa);
            merged.* = .{};
            // In a read-off, an image is the class's cell (`ReadOff.image`).
            if (t.hyp_image) |hi| for (keys.items) |*k| {
                k.image = try hi.image(hi.ctx, k.image);
            };
            // (a′), before any maximum or `exclOf` (§2.9 rule 4, in every
            // build): a group whose keys overlap is dropped, and its keys add
            // as before. The test is `Cell.keysOverlap`'s trie over the
            // group's key set, memoised by that set.
            var group_keys: Ids.FixedDict(1) = .{};
            defer group_keys.deinit(gpa);
            for (keys.items) |k| if (k.group != Ids.none_int) {
                const got = try group_keys.getOrPut(gpa, .{k.group});
                if (!got.found_existing) got.value_ptr.* = SetId.none.int();
                got.value_ptr.* = (try cells.sets.insert(gpa, charge, .from(got.value_ptr.*), k.key.int(), 0)).int();
            };
            for (group_keys.values.items) |*s| s.* = @intFromBool(try cells.keysOverlap(gpa, charge, v.places, .from(s.*)));
            for (keys.items) |*k| if (k.group != Ids.none_int and group_keys.get(.{k.group}).? == 1) {
                k.group = Ids.none_int;
            };
            var a: Agg = .{};
            // `merged`: `(group, image)` met; `met`: `(group, image, key)`.
            // A group's keys are pairwise alias-apart now, so another key of
            // the group at an image is one more position of it, and owes
            // `exclOf`; the same key again adds nothing.
            var met: Ids.FixedDict(3) = .{};
            defer met.deinit(gpa);
            for (keys.items) |k| {
                try charge.reserve(gpa, .inspection, 1);
                if (k.group != Ids.none_int) {
                    if ((try met.getOrPut(gpa, .{ k.group, k.image.int(), k.key.int() })).found_existing) continue;
                    const got = try merged.getOrPut(gpa, .{ k.group, k.image.int() });
                    if (got.found_existing) {
                        a.pairs = try t.@"and"(gpa, charge, a.pairs, try t.exclOf(gpa, charge, cells, k.image));
                        continue;
                    }
                    got.value_ptr.* = 0;
                }
                a = try t.aggAdd(gpa, charge, cells, v.places, a, k.image, k.approx, true);
            }
            return a;
        }

        /// κ̂(V, K) (§2.11 item 3 (d), #1485): the certificate of class `k`
        /// read at environment `e`, its keys by §2.9 rule 4 (a repeat `lost`,
        /// distinct arrivals `apart`, a symbolic arrival at a summary path
        /// `excl`), with the certificate's own condition instantiated there:
        /// its fold's obligation at `k` and the class's κ there, read at
        /// `path` below the template's root (`k`'s class). The keys are a
        /// set, so a multiplicity of 2+ (one cell at two coexisting positions
        /// of `K`) is only in that κ (`lost`): a read of the keys alone takes
        /// it as once (#1485, *As built, part 2*).
        pub fn certRead(t: *Table, gpa: Allocator, charge: Charge, v: View, e: u32, k: NodeId, path: []const Step) Error!CondId {
            var keys: std.ArrayList(HypKey) = .empty;
            defer keys.deinit(gpa);
            var merged: Ids.FixedDict(2) = .{};
            defer merged.deinit(gpa);
            const a = try t.certClassAgg(gpa, charge, v, e, k, &keys, &merged);
            var c = try t.foldCond(gpa, charge, v.cells, v.places, a);
            var it = v.cells.sets.iterate(a.all);
            while (it.next()) |x| {
                try charge.reserve(gpa, .inspection, 1);
                const cell: CellId = .from(x.key);
                const o = v.cells.origin(cell);
                if (o.isSymbolic() and o != .top and v.places.isSummary(.from(v.cells.get(cell).b))) c = try t.@"and"(gpa, charge, c, try t.exclOf(gpa, charge, v.cells, cell));
            }
            if (t.fold_cond.get(k)) |fc| if (t.resolver) |r| {
                c = try t.@"and"(gpa, charge, c, try r.resolve(r.ctx, t, gpa, charge, fc.int(), e, false));
            };
            if (e != identity_env and !mutated("cert-keys-only")) {
                var p = t.classPos(v, e);
                for (path) |s| p = try t.classStep(gpa, charge, v, p, s);
                c = try t.@"and"(gpa, charge, c, try t.classCond(gpa, charge, v, p, k, e));
            }
            return c;
        }

        /// A position in a certificate's class, as a reader there reads its
        /// κ (§2.9 *Keyed where a reader looks*): the class's snapshot
        /// cursor, the projection of the class's `res` along the steps, the
        /// outermost join on the way projected, and whether a step crossed a
        /// summary. A `⟲` stays in its class (`Fold.classAt`).
        pub const ClassPos = struct { cur: Kappas, at: NodeId, dag: NodeId, summary: bool };

        /// The root of the class at environment `e`.
        pub fn classPos(t: *Table, v: View, e: u32) ClassPos {
            const h = t.hyp.?;
            const cls = h.class(h.ctx, e);
            const k = v.shapes.kind(cls.res);
            return .{ .cur = cls.kappas, .at = cls.res, .dag = if (isDag(k) and k != .positions) cls.res else .none, .summary = false };
        }

        pub fn classStep(t: *Table, gpa: Allocator, charge: Charge, v: View, p0: ClassPos, s: Step) Error!ClassPos {
            var p = p0;
            p.summary = p.summary or s.kind == .elem or s.kind == .level;
            if (s.kind == .level) return p;
            p.cur = t.kappaChild(p.cur, s);
            if (p.dag != .none) p.dag = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, p.dag, s)) orelse .none;
            if (p.at != .none) p.at = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, p.at, s)) orelse .none;
            if (p.dag == .none and p.at != .none and isDag(v.shapes.kind(p.at)) and v.shapes.kind(p.at) != .positions) p.dag = p.at;
            return p;
        }

        /// The certificate's condition at class `k` read at `p` (#1485): the
        /// class's κ there, at the class and at the join on the way, joined,
        /// instantiated at environment `e`, and in a read-off relabelled as
        /// its keys' images are (`hyp_image`). A key met at two coexisting
        /// positions of `K` is one key of the set and only this κ's `lost`.
        pub fn classCond(t: *Table, gpa: Allocator, charge: Charge, v: View, p: ClassPos, k: NodeId, e: u32) Error!CondId {
            const r = t.resolver orelse return yes;
            var kk = try t.kappaOf(gpa, charge, v, p.cur, k, p.summary);
            for ([_]NodeId{ p.at, p.dag }) |x| if (x != .none and x != k) {
                kk = try t.join(gpa, charge, kk, try t.kappaOf(gpa, charge, v, p.cur, x, p.summary));
            };
            if (fails(kk) or kk == yes) return kk;
            const got = try r.resolve(r.ctx, t, gpa, charge, kk.int(), e, false);
            if (t.hyp_image) |hi| if (hi.cond) |relabel| return relabel(hi.ctx, got);
            return got;
        }

        /// The parts of source node `n` the widen walked: its explicit
        /// children, an opened union's, choice's or positions node's sides. They
        /// coexist, except an opened choice's arms, which the caller takes by the
        /// maximum (§2.3: two source occurrences add, one execution has one arm).
        pub fn sourceParts(t: *Table, gpa: Allocator, charge: Charge, v: View, fold: *const Shape.Table.Fold, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
            const from = out.items.len;
            defer for (out.items[from..]) |*p| {
                // The widen forced each child as it descended: its source nodes
                // are answers, but a hypothesis node's (#1485).
                if (t.hypEnv(v, p.*) == null) p.* = v.shapes.forced(p.*);
            };
            const d = v.shapes.get(n);
            switch (d.kind) {
                .@"union", .choice, .positions => if (fold.opened.contains(n)) try out.appendSlice(gpa, &.{ .from(d.a), .from(d.b) }),
                .node => {
                    var it = v.shapes.overEntries(d.a);
                    while (it.next()) |e| try out.append(gpa, e.node);
                },
                .delta => {
                    var it = v.shapes.overEntries(d.b);
                    while (it.next()) |e| try out.append(gpa, e.node);
                    const base = try v.shapes.force(gpa, charge.account, .from(d.a));
                    if (v.shapes.kind(base) == .node) {
                        var bt = v.shapes.overEntries(v.shapes.get(base).a);
                        while (bt.next()) |e| if (v.shapes.overGet(d.b, e.step) == null) try out.append(gpa, e.node);
                    }
                },
                .leaf, .recast => {},
                .view => unreachable, // the widen walked answers, never views
            }
        }

        /// The cells source node `n` itself holds at its class, as a set: a
        /// leaf's, a node's, a delta's, a union's, choice's or positions node's kept
        /// whole (its sides' set; what it repeats inside is `dagKappa`'s), a
        /// recast's approximate. An opened one holds nothing of its own.
        pub fn ownAgg(t: *Table, gpa: Allocator, charge: Charge, v: View, fold: *const Shape.Table.Fold, n: NodeId) Error!Agg {
            const d = v.shapes.get(n);
            if ((d.kind == .@"union" or d.kind == .choice or d.kind == .positions) and fold.opened.contains(n)) return .{};
            const own = try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, n);
            if (d.kind != .recast) return t.aggAll(gpa, charge, v.cells, v.places, .{}, own, false);
            var a: Agg = .{};
            var it = v.cells.sets.iterate(own);
            while (it.next()) |e| a = try t.aggAdd(gpa, charge, v.cells, v.places, a, .from(e.key), true, false);
            return a;
        }

        /// Two arms of a choice: a cell in both is still one (the maximum), a
        /// repeat in either stays a repeat.
        pub fn aggChoice(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, x: Agg, y: Agg) Error!Agg {
            const big, const small = if (x.all_len >= y.all_len) .{ x, y } else .{ y, x };
            var a = try t.aggMerge(gpa, charge, cellt, places, big, small, false);
            a.dups = try cellt.sets.unionWith(gpa, charge, a.dups, small.dups);
            a.dups_approx = try cellt.sets.unionWith(gpa, charge, a.dups_approx, small.dups_approx);
            a.lost_extra = a.lost_extra or small.lost_extra;
            return a;
        }

        /// Two class maps as one, coexisting: each class the smaller names
        /// merged into the larger's as a multiset.
        pub fn classMerge(t: *Table, gpa: Allocator, charge: Charge, v: View, x: ClassAggs, y: ClassAggs, together: bool) Error!ClassAggs {
            const big, const small = if (x.len >= y.len) .{ x, y } else .{ y, x };
            var out = big;
            var it = t.mapEntries(small.map);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const b = t.aggs.items[e.value];
                const merged: Agg = if (t.mapGet(out.map, e.key)) |o| (if (together) try t.aggMerge(gpa, charge, v.cells, v.places, t.aggs.items[o], b, true) else try t.aggChoice(gpa, charge, v.cells, v.places, t.aggs.items[o], b)) else blk: {
                    out.len += 1;
                    break :blk b;
                };
                out.map = try t.mapPut(gpa, charge, out.map, e.key, try t.agg(gpa, merged));
            }
            return out;
        }

        /// §2.9's rule over the cells stored at one path, a multiset sorted once
        /// (an item a record): a duplicate decides at once, `⊤`/approximate is
        /// `lost`, the arrivals form ONE `apart` group, pairs over one base are
        /// decided one by one; concrete cells are apart by construction.
        /// `items` is scratch and is reordered.
        pub fn apart(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, items: []Item, traversal: ?Traversal) Error!CondId {
            try charge.reserve(gpa, .inspection, @intCast(items.len));
            std.mem.sort(Item, items, {}, struct {
                fn lessThan(_: void, x: Item, y: Item) bool {
                    return x.cell.int() < y.cell.int();
                }
            }.lessThan);
            var acc: CondId = yes;
            var arrivals: std.ArrayList(CellId) = .empty;
            defer arrivals.deinit(gpa);
            var i: usize = 0;
            while (i < items.len) {
                var j = i + 1;
                var any_approx = items[i].approx;
                while (j < items.len and items[j].cell == items[i].cell) : (j += 1) any_approx = any_approx or items[j].approx;
                const c = items[i].cell;
                if (j - i >= 2) {
                    acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, c, c, any_approx, traversal));
                    if (acc == shared) return shared;
                }
                const o = cellt.origin(c);
                if (any_approx or o == .top) acc = try t.@"and"(gpa, charge, acc, lost);
                std.debug.assert(o != .mark);
                if (!isConcrete(o) and o != .top) try arrivals.append(gpa, c);
                i = j;
            }
            if (arrivals.items.len >= 2) {
                var group: SetId = .none;
                for (arrivals.items) |c| group = try cellt.sets.insert(gpa, charge, group, c.int(), 0);
                // A taken element stored back beside its container's `c[*]` (not
                // `others`): one object at two positions (§2.9's `shared`, P5).
                var whole: SetId = .none;
                for (arrivals.items) |c| {
                    const o = cellt.origin(c);
                    if (!o.isSymbolic() or o == .top) continue;
                    if (places.pathParent(.from(cellt.get(c).b)) == .none or places.pathStep(.from(cellt.get(c).b)).kind != .elem) continue;
                    whole = try cellt.sets.insert(gpa, charge, whole, cellt.parent(c).int(), 0);
                }
                if (whole != .none) for (arrivals.items) |c| if (cellt.origin(c) == .elem) {
                    try charge.reserve(gpa, .inspection, 1);
                    if (cellt.sets.member(whole, cellt.parent(c).int())) return shared;
                };
                acc = try t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, group));
                // A part below another arrival meets every other one as the
                // arrival does (`covered`): left out.
                var kept: usize = 0;
                for (arrivals.items) |c| {
                    if (try covered(gpa, charge, cellt, group, c)) continue;
                    arrivals.items[kept] = c;
                    kept += 1;
                }
                arrivals.shrinkRetainingCapacity(kept);
                acc = try t.@"and"(gpa, charge, acc, try t.sameBasePairs(gpa, charge, cellt, places, arrivals.items, traversal));
            }
            return acc;
        }

        /// The pairs of `arrivals` over one base that `alias` does not tell apart.
        pub fn sameBasePairs(t: *Table, gpa: Allocator, charge: Charge, cellt: *Cell.Table, places: *Cell.Places, arrivals: []CellId, traversal: ?Traversal) Error!CondId {
            var acc: CondId = yes;
            // By base, then by split: one split's members answer `sep` alike
            // (`under` it), so its run is one pair; runs pair across (linear).
            // A part runs with its anchor's split (§2.2 *Parts*), and the cells
            // of one anchor in a run pair among themselves (`splitKey`).
            const Ctx = struct {
                cellt: *const Cell.Table,
                fn split(ctx: @This(), x: CellId) [3]u32 {
                    return splitKey(ctx.cellt, x);
                }
            };
            const ctx: Ctx = .{ .cellt = cellt };
            std.mem.sort(CellId, arrivals, ctx, struct {
                fn lessThan(c: Ctx, x: CellId, y: CellId) bool {
                    const bx = c.cellt.base(x).int();
                    const by = c.cellt.base(y).int();
                    if (bx != by) return bx < by;
                    const sx = c.split(x);
                    const sy = c.split(y);
                    if (sx[0] != sy[0]) return sx[0] < sy[0];
                    if (sx[1] != sy[1]) return sx[1] < sy[1];
                    if (sx[2] != sy[2]) return sx[2] < sy[2];
                    return x.int() < y.int();
                }
            }.lessThan);
            var k: usize = 0;
            while (k < arrivals.len) {
                var m = k + 1;
                while (m < arrivals.len and cellt.base(arrivals[m]) == cellt.base(arrivals[k])) m += 1;
                // The runs of one split in [k, m).
                var x = k;
                while (x < m) {
                    const sx = ctx.split(arrivals[x]);
                    var e = x + 1;
                    while (e < m and sx[0] != Ids.none_int and std.mem.eql(u32, ctx.split(arrivals[e])[0..2], sx[0..2])) e += 1;
                    // Two anchors' cells: one pair stands for the run.
                    if (e - x >= 2 and ctx.split(arrivals[e - 1])[2] != sx[2]) {
                        try charge.reserve(gpa, .inspection, @intCast(e - x));
                        if (cellt.alias(places, arrivals[x], arrivals[e - 1]) != .no) {
                            acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, arrivals[x], arrivals[e - 1], false, traversal));
                            if (acc == shared) return shared;
                        }
                    }
                    // Against every later run.
                    for (arrivals[x..e]) |a| for (arrivals[e..m]) |b| {
                        try charge.reserve(gpa, .inspection, 1);
                        if (cellt.alias(places, a, b) == .no) continue; // in the group
                        acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, cellt, places, a, b, false, traversal));
                        if (acc == shared) return shared;
                    };
                    x = e;
                }
                k = m;
            }
            return acc;
        }

        /// The deep condition of a node: κ of every node of its explicit
        /// structure and `excl c` for every arrival among their cells, each
        /// read at its own position of the snapshot (`ctx` is `n`'s) (*`deep`*).
        /// A walk over states `(position, node, class, explicit)`, post-order on
        /// an explicit stack: a state's answer is the `and` of its own part and
        /// its frontier's answers. An explicit state's answer is a function of
        /// its key, kept canonical in `memo_deep` and taken from there when met
        /// again, in this read or a later one. A state met again while it is open
        /// (a fold, a knot) adds nothing more, and the read then keeps no inner
        /// entry. Below a re-root view the walk carries the crossing's pairs
        /// (*Carried along the walk*): a node wholly of the actual's region is
        /// read at `R_Q`, where earlier reads met it.
        pub fn deep(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
            return t.resolved(gpa, charge, try t.deepRaw(gpa, charge, v, ctx, n, at_summary));
        }

        pub fn deepRaw(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!CondId {
            const epoch = v.shapes.base_epoch;
            const from = t.pending.items.len;
            const r = try t.deepWalk(gpa, charge, v, ctx, n, at_summary);
            if (!r.crossed and !(std.debug.runtime_safety and full_cross_check and !t.no_memo)) return r.k;
            if (!r.crossed) {
                try t.crossCheckDeep(gpa, charge, v, ctx, n, at_summary, r.k);
                return r.k;
            }
            if (v.shapes.base_epoch != epoch) {
                t.crossed_redos += 1;
                try t.settle(gpa, from, false);
                const saved = t.no_cross;
                t.no_cross = true;
                defer t.no_cross = saved;
                return (try t.deepWalk(gpa, charge, v, ctx, n, at_summary)).k;
            }
            try t.settle(gpa, from, true);
            if (std.debug.runtime_safety and full_cross_check and !t.no_memo) try t.crossCheckDeep(gpa, charge, v, ctx, n, at_summary, r.k);
            return r.k;
        }

        /// `-Downership-full-cross-check`: a `deep` read walked again whole, with
        /// no memo and no crossing, gives the same kind and atom set.
        pub fn crossCheckDeep(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool, k: CondId) Error!void {
            const saved = .{ t.no_cross, t.no_memo };
            t.no_cross = true;
            t.no_memo = true;
            defer {
                t.no_cross = saved[0];
                t.no_memo = saved[1];
            }
            try t.expectSame(gpa, charge, try t.resolved(gpa, charge, k), try t.resolved(gpa, charge, (try t.deepWalk(gpa, charge, v, ctx, n, at_summary)).k));
        }

        pub fn deepWalk(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, at_summary: bool) Error!Read {
            const Frame = struct {
                at: Kappas,
                node: NodeId,
                summary: bool,
                explicit: bool,
                /// The carried pairs: a range of `pairs`.
                pairs: [2]u32,
                expanded: bool = false,
                /// This state's part, and where its children's answers start.
                own: CondId = yes,
                kids: u32 = 0,
                crossed: bool = false,

                fn key(f: @This()) [4]u32 {
                    return .{ f.at.int(), f.node.int(), @intFromBool(f.summary), @intFromBool(f.explicit) };
                }
            };
            const open_mark = std.math.maxInt(u32);
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var vals: std.ArrayList(Read) = .empty;
            defer vals.deinit(gpa);
            var pairs: std.ArrayList(Pair) = .empty;
            defer pairs.deinit(gpa);
            var state: Ids.FixedDict(4) = .{};
            defer state.deinit(gpa);
            var done: std.ArrayList(Read) = .empty;
            defer done.deinit(gpa);
            var next: std.ArrayList(Next) = .empty;
            defer next.deinit(gpa);
            var cyclic = false;
            var stop = false;
            try stack.append(gpa, .{ .at = ctx, .node = n, .summary = at_summary, .explicit = true, .pairs = .{ 0, 0 } });
            while (stack.items.len > 0) {
                const fi = stack.items.len - 1;
                var f = stack.items[fi];
                if (!f.expanded) {
                    // Below a crossing, a node wholly of a carried region is read
                    // at that pair's `R_Q`, where earlier reads met it.
                    if (f.pairs[1] > 0 and !t.no_cross) {
                        for (pairs.items[f.pairs[0]..][0..f.pairs[1]]) |p| if (p.epoch == v.shapes.base_epoch and try v.shapes.wholly(gpa, charge.account, f.node, p.region)) {
                            f.at = p.r;
                            f.pairs = .{ 0, 0 };
                            f.crossed = true;
                            break;
                        };
                    }
                    try charge.reserve(gpa, .memo, 1);
                    const got = try state.getOrPut(gpa, f.key());
                    if (got.found_existing) {
                        _ = stack.pop();
                        if (got.value_ptr.* == open_mark) {
                            cyclic = true;
                            try vals.append(gpa, .{ .k = yes, .crossed = false });
                        } else try vals.append(gpa, done.items[got.value_ptr.*]);
                        continue;
                    }
                    // A traced read (a test's) walks every state: no answer from the memo.
                    if (f.explicit and t.trace == null) if (t.memoGet(.deep, .{ f.at.int(), f.node.int(), @as(u32, @intFromBool(f.summary)) })) |hit| {
                        got.value_ptr.* = @intCast(done.items.len);
                        const r: Read = .{ .k = .from(hit), .crossed = f.crossed };
                        try done.append(gpa, r);
                        _ = stack.pop();
                        try vals.append(gpa, r);
                        continue;
                    };
                    got.value_ptr.* = open_mark;
                    try charge.reserve(gpa, .inspection, 1);
                    try t.traced(gpa, f.node, f.summary);
                    const fpairs = pairs.items[f.pairs[0]..][0..f.pairs[1]];
                    if (!f.explicit) {
                        // A projection the structure does not name: what the arrivals
                        // above claim (`excl` is deep) covers its derivation; only
                        // what the snapshot stores there is more.
                        if (t.kappaGet(f.at, f.node)) |s| f.own = s;
                    } else {
                        const k = try t.readAt(gpa, charge, v, f.at, f.node, f.summary, fpairs);
                        f.own = try t.@"and"(gpa, charge, k, try t.shallow(gpa, charge, v.cells, v.places, (try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, f.node))));
                    }
                    f.expanded = true;
                    f.kids = @intCast(vals.items.len);
                    if (f.own == shared) {
                        stop = true;
                        stack.items[fi] = f;
                        continue;
                    }
                    // The pairs below: those carried, a step down, and the crossings
                    // at this node's re-root views.
                    const sub_from: u32 = @intCast(pairs.items.len);
                    if (!t.no_cross) try t.crossingsAt(gpa, charge, v, f.at, f.node, &pairs);
                    const own_pairs = pairs.items.len - sub_from;
                    next.clearRetainingCapacity();
                    try t.frontier(gpa, charge, v, f.node, f.summary, &.{f.at}, &next);
                    stack.items[fi] = f;
                    for (next.items) |e| {
                        const s = Step.fromWord(e.step);
                        const pf: u32 = @intCast(pairs.items.len);
                        for (0..f.pairs[1]) |i| {
                            const p = pairs.items[f.pairs[0] + i];
                            try pairs.append(gpa, .{ .region = p.region, .r = t.kappaChild(p.r, s), .epoch = p.epoch });
                        }
                        for (0..own_pairs) |i| {
                            const p = pairs.items[sub_from + i];
                            try pairs.append(gpa, .{ .region = p.region, .r = t.kappaChild(p.r, s), .epoch = p.epoch });
                        }
                        try stack.append(gpa, .{ .at = t.kappaChild(f.at, s), .node = e.node, .summary = e.summary, .explicit = e.explicit, .pairs = .{ pf, @intCast(pairs.items.len - pf) } });
                    }
                    continue;
                }
                // Its frontier's answers are in: this state's own.
                var k = f.own;
                var crossed = f.crossed;
                for (vals.items[f.kids..]) |r| {
                    k = try t.@"and"(gpa, charge, k, r.k);
                    crossed = crossed or r.crossed;
                }
                vals.shrinkRetainingCapacity(f.kids);
                if (f.pairs[1] > 0) crossed = true;
                k = try t.canonical(gpa, charge, k);
                _ = stack.pop();
                if (f.explicit and !cyclic and !stop) try t.memoPut(gpa, .deep, .{ f.at.int(), f.node.int(), @intFromBool(f.summary) }, k.int(), crossed);
                (try state.getOrPut(gpa, f.key())).value_ptr.* = @intCast(done.items.len);
                try done.append(gpa, .{ .k = k, .crossed = crossed });
                try vals.append(gpa, .{ .k = k, .crossed = crossed });
                if (stop) {
                    // `shared` absorbs: the root's answer is `shared`.
                    while (stack.items.len > 0) _ = stack.pop();
                    return .{ .k = shared, .crossed = crossed };
                }
            }
            const r = vals.pop().?;
            if (cyclic) try t.memoPut(gpa, .deep, .{ ctx.int(), n.int(), @intFromBool(at_summary) }, r.k.int(), r.crossed);
            return r;
        }

        /// The crossings at `n`'s re-root views read at `ctx` (*Carried along
        /// the walk*): the views a union, choice or positions DAG at `n`'s path
        /// has for sides (a view that is no re-root view read at its answer),
        /// each where `eqOn` holds, appended to `out` once per region.
        pub fn crossingsAt(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, n: NodeId, out: *std.ArrayList(Pair)) Error!void {
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(gpa);
            var seen: stamped.Column(NodeId, void) = .{};
            defer seen.deinit(gpa);
            try stack.append(gpa, n);
            while (stack.pop()) |x| {
                if (seen.contains(x)) continue;
                try seen.put(gpa, x, {});
                try charge.reserve(gpa, .inspection, 1);
                if (v.shapes.kind(x) == .view) {
                    if (try t.crossAt(gpa, charge, v, ctx, x)) |c| {
                        for (out.items) |p| {
                            if (p.region == c.region and p.r == c.r) break;
                        } else try out.append(gpa, .{ .region = c.region, .r = c.r, .epoch = v.shapes.base_epoch });
                        continue;
                    }
                    const answer = try v.shapes.force(gpa, charge.account, x);
                    if (isDag(v.shapes.kind(answer))) try stack.append(gpa, answer);
                    continue;
                }
                if (!isDag(v.shapes.kind(x))) continue;
                const d = v.shapes.get(x);
                try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
            }
        }

        /// What a cell set owes per cell (*The derivation*): `summary`, at a
        /// summary position, `excl c` per arrival standing for many positions
        /// (`summaryExclFlat`); `shallow`, `excl c` for every arrival, a deep
        /// condition's part (`shallowFlat`). A term depends only on the cell's
        /// origin, approximation and folding, all immutable, so the answer is
        /// memoised per radix node of the persistent set: a node's is its two
        /// halves' `and`, canonical (*Canonical partials*). A set one insertion
        /// larger reads its new spine. Post-order on an explicit stack.
        const PerCell = enum(u8) { summary, shallow };

        pub fn perCell(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, which: PerCell, cells: SetId) Error!CondId {
            if (cells == .none) return yes;
            // One cell: its term at once, never memoised.
            if (cellt.sets.branches(cells) == null) return switch (which) {
                .summary => t.summaryExclFlat(gpa, charge, cellt, places, cells),
                .shallow => t.shallowFlat(gpa, charge, cellt, places, cells),
            };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_per_cell.get(.{ @backingInt(which), cells.int() })) |hit| return .from(hit);
            var stack: std.ArrayList(SetId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, cells);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.memo_per_cell.get(.{ @backingInt(which), x.int() }) != null) {
                    _ = stack.pop();
                    continue;
                }
                const k: CondId = if (cellt.sets.branches(x)) |kids| blk: {
                    var halves: [2]CondId = undefined;
                    var missing = false;
                    for (kids, 0..) |kid, i| {
                        if (kid == .none) {
                            halves[i] = yes;
                        } else if (t.memo_per_cell.get(.{ @backingInt(which), kid.int() })) |h| {
                            halves[i] = .from(h);
                        } else {
                            missing = true;
                            try stack.append(gpa, kid);
                        }
                    }
                    if (missing) continue;
                    break :blk try t.canonical(gpa, charge, try t.@"and"(gpa, charge, halves[0], halves[1]));
                } else switch (which) {
                    .summary => try t.summaryExclFlat(gpa, charge, cellt, places, x),
                    .shallow => try t.shallowFlat(gpa, charge, cellt, places, x),
                };
                (try t.memo_per_cell.getOrPut(gpa, .{ @backingInt(which), x.int() })).value_ptr.* = k.int();
                _ = stack.pop();
            }
            return .from(t.memo_per_cell.get(.{ @backingInt(which), cells.int() }).?);
        }

        pub fn summaryExcl(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
            return t.perCell(gpa, charge, cellt, places, .summary, cells);
        }

        pub fn shallow(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
            return t.perCell(gpa, charge, cellt, places, .shallow, cells);
        }

        /// At a summary position: `excl c` per arrival standing for many positions.
        pub fn summaryExclFlat(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
            var acc: CondId = yes;
            var it = cellt.sets.iterate(cells);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                const o = cellt.origin(c);
                if (e.value == 1 or o == .top) return lost;
                if (isConcrete(o) or o == .mark or !isFolded(cellt, places, c)) continue;
                acc = try t.@"and"(gpa, charge, acc, try t.exclOf(gpa, charge, cellt, c));
            }
            return acc;
        }

        /// `excl c` for every arrival in a cell set (a DEEP condition's part).
        pub fn shallowFlat(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, places: *const Cell.Places, cells: SetId) Error!CondId {
            _ = places;
            var acc: CondId = yes;
            var it = cellt.sets.iterate(cells);
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                const o = cellt.origin(c);
                if (e.value == 1 or o == .top) return lost;
                if (isConcrete(o) or o == .mark) continue;
                acc = try t.@"and"(gpa, charge, acc, try t.exclOf(gpa, charge, cellt, c));
            }
            return acc;
        }

        /// The `apart` group atom at the top of a container's κ, and the rest.
        pub fn splitGroup(t: *Table, k: CondId) struct { atom: CondId, rest: CondId } {
            if (k == yes or fails(k)) return .{ .atom = .none, .rest = k };
            const d = t.get(k);
            if (d.kind == .atom) return if (d.atom == .apart) .{ .atom = k, .rest = yes } else .{ .atom = .none, .rest = k };
            const a: CondId = .from(d.a);
            const b: CondId = .from(d.b);
            if (t.kind(a) == .atom and t.get(a).atom == .apart) return .{ .atom = a, .rest = b };
            if (t.kind(b) == .atom and t.get(b).atom == .apart) return .{ .atom = b, .rest = a };
            return .{ .atom = .none, .rest = k };
        }

        /// §2.9's construction rule, incremental: a stored cell the base holds is
        /// `shared` (one set lookup); the arrivals group (the `apart` atom at the
        /// top of κ) grows by insertion, the base scanned only while it has no
        /// group; plus the stored value's κ as a position. W fresh stores O(W log W).
        pub fn lower(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx: Kappas, base_kappa0: CondId, base_cells: SetId, stored: NodeId, at_summary: bool, traversal: ?Traversal) Error!CondId {
            // `splitGroup` tests the base's condition's shape: resolved first.
            const base_kappa = try t.resolved(gpa, charge, base_kappa0);
            if (base_kappa == shared) return shared;
            const split = t.splitGroup(base_kappa);
            var acc = split.rest;
            var new_arrivals: std.ArrayList(CellId) = .empty;
            defer new_arrivals.deinit(gpa);
            var it = v.cells.sets.iterate((try v.shapes.cellsOf(gpa, charge.account, &v.cells.sets, stored)));
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (e.value == 1 or v.cells.origin(c) == .top) acc = try t.@"and"(gpa, charge, acc, lost);
                if (v.cells.sets.member(base_cells, c.int())) {
                    acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, v.cells, v.places, c, c, false, traversal));
                    if (acc == shared) return shared;
                } else if (!isConcrete(v.cells.origin(c)) and v.cells.origin(c) != .top) {
                    try new_arrivals.append(gpa, c);
                }
            }
            var group: SetId = if (split.atom != .none) .from(t.get(split.atom).a) else .none;
            if (new_arrivals.items.len > 0) {
                if (split.atom == .none) {
                    // No group yet: the base holds at most one arrival, found by
                    // one scan, charged per cell.
                    var bt = v.cells.sets.iterate(base_cells);
                    while (bt.next()) |e| {
                        try charge.reserve(gpa, .inspection, 1);
                        const o = v.cells.origin(.from(e.key));
                        if (!isConcrete(o) and o != .top and o != .mark) group = try v.cells.sets.insert(gpa, charge, group, e.key, 0);
                    }
                }
                // The new arrivals against the group's cells of the same base.
                var same: std.ArrayList(CellId) = .empty;
                defer same.deinit(gpa);
                for (new_arrivals.items) |c| {
                    var gt = v.cells.sets.iterate(group);
                    while (gt.next()) |e| {
                        try charge.reserve(gpa, .inspection, 1);
                        const g: CellId = .from(e.key);
                        if (v.cells.base(g) != v.cells.base(c)) continue;
                        if (v.cells.alias(v.places, g, c) == .no) continue;
                        acc = try t.@"and"(gpa, charge, acc, try t.sep(gpa, charge, v.cells, v.places, g, c, false, traversal));
                        if (acc == shared) return shared;
                    }
                    group = try v.cells.sets.insert(gpa, charge, group, c.int(), 0);
                }
                try same.appendSlice(gpa, new_arrivals.items);
                if (new_arrivals.items.len >= 2) acc = try t.@"and"(gpa, charge, acc, try t.sameBasePairs(gpa, charge, v.cells, v.places, same.items, traversal));
            }
            // The stored value's own condition at the written position (its κ
            // as a position, `excl` for its arrivals that stand for many): the
            // conditions of the paths below are set where the walker joins the
            // children (`propagate` together), never a deep condition here.
            acc = try t.@"and"(gpa, charge, acc, try t.kappaOf(gpa, charge, v, ctx, stored, at_summary));
            if (acc == shared) return shared;
            if (group != .none and try t.groupSize2(gpa, charge, v.cells, group)) return t.@"and"(gpa, charge, acc, try t.apartAtom(gpa, charge, group));
            if (split.atom != .none) return t.@"and"(gpa, charge, acc, split.atom);
            return acc;
        }

        /// Whether a set has at least two members: two steps of its iterator.
        pub fn groupSize2(t: *Table, gpa: Allocator, charge: Charge, cellt: *const Cell.Table, s: SetId) Error!bool {
            _ = t;
            try charge.reserve(gpa, .inspection, 1);
            var it = cellt.sets.iterate(s);
            return it.next() != null and it.next() != null;
        }

        // ---- joins -------------------------------------------------------------

        /// Record a position a reader reads (`trace`, for tests).
        pub fn traced(t: *Table, gpa: Allocator, n: NodeId, summary: bool) Error!void {
            if (t.trace) |l| try l.append(gpa, n.int() << 1 | @intFromBool(summary));
        }

        /// The positions a κ read reaches from `(n, summary)` (§2.9): a position
        /// is a path, so the transitions are steps, and the frontier is SPARSE:
        /// the steps `n`'s structure names (`explicitSteps`) and the steps the
        /// snapshots read there (`cursors`) link; every other projection's read
        /// is derived from structure the reader reads already, with nothing
        /// stored, so it is omitted and a type's width costs nothing. Below a
        /// fold (a widened recursive position, whose entries are keyed by node
        /// for every level) every step of the place is a transition. Other nodes
        /// at `n`'s path are read by `kappaOf` of `n`: a union's or positions
        /// node's sides by `dagKappa`, a recast's inner beside the recast (a
        /// recast changes the type, not the path, so the two are one position,
        /// and the inner's own steps are the position's too: `via` names the
        /// inner, found through the sides of a union or a positions node as
        /// well); a delta's base never (a built node's κ is the walk's, O13).
        /// `explicit`: the structure names something at that step. The one walk
        /// of `propagate`, `kappaLeq` and `deep`; Block writes the same.
        pub const Next = struct { node: NodeId, summary: bool, step: u32, explicit: bool = true, via: NodeId = .none };

        pub fn frontier(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, cursors: []const Kappas, out: *std.ArrayList(Next)) Error!void {
            var words: std.ArrayList(u64) = .empty;
            defer words.deinit(gpa);
            const fold = try t.cursorSteps(gpa, charge, cursors, &words);
            try t.frontierWith(gpa, charge, v, n, summary, .{ .words = words.items, .fold = fold }, out);
        }

        /// `frontier` against cursors read already: the frames reading one
        /// run read its cursors once (#1273).
        pub fn frontierWith(t: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, cs: CursorSteps, out: *std.ArrayList(Next)) Error!void {
            try t.steps(gpa, charge, v, n, summary, cs, .none, out);
            var inners: std.ArrayList(NodeId) = .empty;
            defer inners.deinit(gpa);
            try innersOf(gpa, charge, v, n, &inners);
            for (inners.items) |i| try t.steps(gpa, charge, v, i, summary, cs, i, out);
        }

        /// What a frontier reads of its cursors, the same for every node read
        /// against them: the steps their links name, distinct and sorted (a
        /// fold's links are the steps it saw, sparse below it too; a wide
        /// run's cursors name the same few steps, #1139), those a cursor has a
        /// position at, and whether one is a fold (a position at every step).
        pub const CursorSteps = struct {
            /// `step word << 1 | linked`, sorted.
            words: []const u64,
            fold: bool,
        };

        /// The cursors' steps appended to `out`, sorted; whether one is a fold.
        pub fn cursorSteps(t: *Table, gpa: Allocator, charge: Charge, cursors: []const Kappas, out: *std.ArrayList(u64)) Error!bool {
            const from = out.items.len;
            var fold = false;
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(gpa);
            for (cursors) |c| {
                if (c != .none and t.position(c).fold != 0) fold = true;
                var it = t.kappaLinks(c);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const got = try seen.getOrPut(gpa, .{e.step.word()});
                    if (!got.found_existing) {
                        got.value_ptr.* = @intCast(out.items.len);
                        try out.append(gpa, @as(u64, e.step.word()) << 1);
                    }
                    if (t.kappaChild(c, e.step) != .none) out.items[got.value_ptr.*] |= 1;
                }
            }
            try charge.reserve(gpa, .inspection, sortCost(out.items.len - from));
            std.mem.sort(u64, out.items[from..], {}, std.sort.asc(u64));
            return fold;
        }

        pub fn steps(_: *Table, gpa: Allocator, charge: Charge, v: View, n: NodeId, summary: bool, cs: CursorSteps, via: NodeId, out: *std.ArrayList(Next)) Error!void {
            var named: std.ArrayList(u32) = .empty;
            defer named.deinit(gpa);
            try explicitSteps(gpa, charge, v, n, &named);
            try charge.reserve(gpa, .inspection, sortCost(named.items.len));
            std.mem.sort(u32, named.items, {}, std.sort.asc(u32));
            // The named steps and the cursors' merged, each once, in order;
            // each is charged below as it is read.
            var a: usize = 0;
            var b: usize = 0;
            var last: ?u32 = null;
            while (a < named.items.len or b < cs.words.len) {
                const wb: ?u32 = if (b < cs.words.len) @intCast(cs.words[b] >> 1) else null;
                const take_named = a < named.items.len and (wb == null or named.items[a] <= wb.?);
                const w = if (take_named) named.items[a] else wb.?;
                const explicit_here = take_named;
                var linked = cs.fold;
                if (take_named) a += 1;
                if (wb != null and wb.? == w) {
                    linked = linked or cs.words[b] & 1 == 1;
                    b += 1;
                }
                if (last != null and last.? == w) continue;
                last = w;
                try charge.reserve(gpa, .inspection, 1);
                const s = Step.fromWord(w);
                const c = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, n, s)) orelse continue;
                // Through a recast's inner only what a snapshot stores is more:
                // an unstored inner adds nothing to the recast's derived read.
                const explicit = via == .none and explicit_here;
                const empty = try v.shapes.isNothing(gpa, charge.account, c);
                if (!linked and (!explicit or empty)) continue;
                try out.append(gpa, .{ .node = c, .summary = summary or below(s), .step = w, .explicit = explicit, .via = via });
            }
        }

        /// The steps `n`'s structure names: a node's overrides, a delta's and
        /// its base's, a union's or a positions node's sides'; a leaf or a
        /// recast names none (its projections are derived). Sorted and
        /// distinct, `Shape.namedSteps`' memo: a record per step read.
        fn explicitSteps(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(u32)) Error!void {
            const named = try v.shapes.namedSteps(gpa, charge.account, n);
            try charge.reserve(gpa, .inspection, @intCast(named.len));
            try out.appendSlice(gpa, named);
        }

        /// The inners of the recasts at `n`'s path: `n`'s own, those of its
        /// union's or positions node's sides, and, an inner being at the same
        /// path, those found inside an inner (a recast of a union of recasts,
        /// #1101), each once. A record per node.
        fn innersOf(gpa: Allocator, charge: Charge, v: View, n: NodeId, out: *std.ArrayList(NodeId)) Error!void {
            // A view is read at its answer; a recast's inner is listed as stored
            // (a view's κ is its chain's, `storedAt`) and walked at its answer:
            // `Shape.inners`, memoised per node, in node order.
            var it = v.shapes.node_sets.iterate(try v.shapes.inners(gpa, charge.account, n));
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                try out.append(gpa, .from(e.key));
            }
        }

        /// A member's counterpart for a transition: itself, or for one out of a
        /// recast's inner `via`, the join of the inners of its own recasts at
        /// that place (null: it has none, so nothing it stores is there).
        pub fn side(gpa: Allocator, charge: Charge, v: View, m: NodeId, via: NodeId) Error!?NodeId {
            if (via == .none) return m;
            var inners: std.ArrayList(NodeId) = .empty;
            defer inners.deinit(gpa);
            try innersOf(gpa, charge, v, m, &inners);
            // Every inner at that place, joined: a union's recasts' inners are
            // alternatives at one position, each read (#1114's review).
            var at: std.ArrayList(NodeId) = .empty;
            defer at.deinit(gpa);
            for (inners.items) |i| if (v.shapes.place(i) == v.shapes.place(via)) try at.append(gpa, i);
            if (at.items.len == 0) return null;
            if (at.items.len == 1) return at.items[0];
            return try v.shapes.join(gpa, charge.account, v.places, v.cells, at.items);
        }

        /// A sort of `n` items: n·⌈log₂(n + 1)⌉ comparisons, each a record.
        pub fn sortCost(n: usize) u32 {
            const lg: usize = std.math.log2_int_ceil(usize, n + 1);
            return @intCast(@min(n * lg, std.math.maxInt(u32)));
        }

        pub fn below(s: Step) bool {
            return s.kind == .elem or s.kind == .level;
        }

        /// Whether condition `e` adds nothing to `r` (§2.3 *Saturation at two*,
        /// *Exactness of a dropped entry*): `e ⊑ r` in the lattice once each
        /// `sep` and `apart` atom of `e` is read as its pairs, a pair being
        /// covered by a `sep` or an `apart` of `r` that holds both cells. A
        /// `runtime_safety` check's test: it walks the `and` trees itself and
        /// writes no memo, so it changes no later read or charge.
        pub fn impliedBy(t: *Table, gpa: Allocator, v: View, e: CondId, r: CondId) Error!bool {
            if (e == yes or e == r or r == shared) return true;
            if (e == shared) return false;
            if (r == lost) return true;
            if (e == lost or r == yes) return false;
            var es: std.ArrayList(CondId) = .empty;
            defer es.deinit(gpa);
            var rs: std.ArrayList(CondId) = .empty;
            defer rs.deinit(gpa);
            try t.atomsOf(gpa, e, &es);
            try t.atomsOf(gpa, r, &rs);
            var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
            defer scratch.deinit(gpa);
            const g: Charge = .growth(&scratch);
            const sets = &v.cells.sets;
            next: for (es.items) |a| {
                if (std.mem.indexOfScalar(CondId, rs.items, a) != null) continue;
                const d = t.get(a);
                if (d.atom != .sep and d.atom != .apart) return false;
                // One `apart` of `r` over a superset covers every pair at once.
                if (d.atom == .apart) for (rs.items) |b| {
                    const db = t.get(b);
                    if (db.atom == .apart and try sets.subset(gpa, g, .from(d.a), .from(db.a))) continue :next;
                };
                var cells: std.ArrayList(u32) = .empty;
                defer cells.deinit(gpa);
                if (d.atom == .sep) try cells.appendSlice(gpa, &.{ d.a, d.b }) else {
                    var it = sets.iterate(.from(d.a));
                    while (it.next()) |c| try cells.append(gpa, c.key);
                }
                for (cells.items, 0..) |x, i| for (cells.items[i + 1 ..]) |y| {
                    const pair = for (rs.items) |b| {
                        const db = t.get(b);
                        if (db.atom == .sep and db.a == @min(x, y) and db.b == @max(x, y)) break true;
                        if (db.atom == .apart and sets.member(.from(db.a), x) and sets.member(.from(db.a), y)) break true;
                    } else false;
                    if (!pair) return false;
                };
            }
            return true;
        }

        /// The atoms of `c`'s `and` tree, each once, read with no memo.
        pub fn atomsOf(t: *Table, gpa: Allocator, c: CondId, out: *std.ArrayList(CondId)) Error!void {
            var stack: std.ArrayList(CondId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, c);
            while (stack.pop()) |x| {
                if (x == yes) continue;
                const d = t.get(x);
                if (d.kind == .@"and") {
                    try stack.appendSlice(gpa, &.{ .from(d.a), .from(d.b) });
                } else if (std.mem.indexOfScalar(CondId, out.items, x) == null) try out.append(gpa, x);
            }
        }

        /// `κ_a(a) ⊑ κ_b(b)` at every position the two structures put at one
        /// path (§2.9's sparse frontier): a simulation over PAIRS, each once
        /// per pair of positions, `b` projected in lockstep along every step
        /// of `a`'s frontier, both snapshots' links included (#1063).
        pub fn kappaLeq(t: *Table, gpa: Allocator, charge: Charge, v: View, ctx_a: Kappas, a: NodeId, ctx_b: Kappas, b: NodeId, at_summary: bool) Error!bool {
            var seen: Ids.FixedDict(5) = .{};
            defer seen.deinit(gpa);
            const Frame = struct { a: NodeId, b: NodeId, summary: bool, ca: Kappas, cb: Kappas };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var next: std.ArrayList(Next) = .empty;
            defer next.deinit(gpa);
            try stack.append(gpa, .{ .a = a, .b = b, .summary = at_summary, .ca = ctx_a, .cb = ctx_b });
            while (stack.pop()) |f| {
                try charge.reserve(gpa, .inspection, 1);
                const got = try seen.getOrPut(gpa, .{ f.a.int(), f.b.int(), @intFromBool(f.summary), f.ca.int(), f.cb.int() });
                if (got.found_existing) continue;
                got.value_ptr.* = 1;
                try t.traced(gpa, f.a, f.summary);
                const ka = try t.kappaOf(gpa, charge, v, f.ca, f.a, f.summary);
                const kb = try t.kappaOf(gpa, charge, v, f.cb, f.b, f.summary);
                if (!try t.leq(gpa, charge, ka, kb)) return false;
                next.clearRetainingCapacity();
                try t.frontier(gpa, charge, v, f.a, f.summary, &.{ f.ca, f.cb }, &next);
                for (next.items) |e| {
                    const s = Step.fromWord(e.step);
                    const sb = (try side(gpa, charge, v, f.b, e.via)) orelse return false;
                    const nb = (try v.shapes.proj(gpa, charge.account, v.places, v.cells, sb, s)) orelse return false;
                    try stack.append(gpa, .{ .a = e.node, .b = nb, .summary = e.summary, .ca = t.kappaChild(f.ca, s), .cb = t.kappaChild(f.cb, s) });
                }
            }
            return true;
        }
    };
}

const v2_mutation = @import("ownership_options").v2_mutation;

/// A test-only mutation (`-Downership-v2-mutation`, which `gates` refuses).
fn mutated(comptime which: []const u8) bool {
    return std.mem.eql(u8, v2_mutation, which);
}
