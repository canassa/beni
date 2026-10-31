//! L10: the transfer frame's accessors, value helpers and uses
//! (`docs/design/ownership-v2.md` §2.6, §2.7): the instruction and value
//! reads, the lanes, the values of nothing and `⊤`, the κ setters, and the
//! uses at a consumer, the parameter reads, the pending operands and the
//! bindings. `Of(Frame)` is this part's methods over the frame
//! `Transfer.zig` declares; `Transfer.zig` binds them by name (§5). Every
//! other part of the frame calls this one.
//!
//! Obligations kept here: O2 (uses at consumers, at the path read, with
//! their kind) and O1's unknown (`topValue`, `opaqueOf`: an unknown is
//! `⊤`), as `Transfer.zig`'s header states them.

const std = @import("std");
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cond = @import("Cond.zig");
const Demands = @import("Demands.zig");
const Calls = @import("Calls.zig");
const Bir = @import("../bir/Bir.zig");
const NodeId = Ids.NodeId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const CondId = Ids.CondId;
const Value = Demands.Value;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;
const Inst = Bir.Inst;

/// One instruction's value, and the local and path it reads when it is a
/// read of one (a field chain included): what its consumer records a use of.
pub const Val = struct {
    value: Value = .{},
    local: u32 = none,
    path: PathId = .none,
};

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        pub fn rel(f: *const Frame, i: u32) u32 {
            return i - f.decl.inst_start.int();
        }

        pub fn account(f: *Frame) *Ids.Account {
            return f.env.account();
        }

        pub fn tag(f: *const Frame, i: u32) Inst.Tag {
            return f.bir.instTag(@fromBackingInt(i));
        }

        pub fn data(f: *const Frame, i: u32) Inst.Data {
            return f.bir.instData(@fromBackingInt(i));
        }

        pub fn token(f: *const Frame, i: u32) u32 {
            return f.bir.insts.items(.main_token)[i];
        }

        pub fn val(f: *const Frame, i: u32) Val {
            return f.vals[f.rel(i)];
        }

        /// Enter instruction `i`'s settlement kernel (§4.1), to `leave` after.
        pub fn lane(f: *Frame, i: u32) Error!Ids.Account.Kernel {
            return f.account().enter(f.gpa, .{ .atom = i, .role = .transfer_settlement });
        }

        /// An item's work that is as large as its value (its fit, its κ merge
        /// and reads, its projection, its cells): a growth task chosen before
        /// it, never the item's lane, whose ceiling a large value would pass
        /// (§4.1, #1139's review). Read-off continuations charge it by its
        /// producers (#1098).
        pub fn sized(f: *Frame) Error!Ids.Account.Kernel {
            return f.account().enter(f.gpa, null);
        }

        pub fn markUnbuilt(f: *Frame, i: u32) void {
            if (f.unbuilt == none) f.unbuilt = i;
        }

        pub fn args(f: *const Frame, c: u32) []const Inst.Index {
            return f.bir.extraSlice(f.bir.subRange(@fromBackingInt(f.data(c).rhs)), Inst.Index);
        }

        pub fn placeOf(f: *Frame, i: u32) Error!PlaceId {
            return f.ctx.placeOfInst(f.ctx.ctx, i);
        }

        pub fn set1(f: *Frame, c: CellId) Error!SetId {
            return f.env.cells.sets.insert(f.gpa, f.env.charge, .none, c.int(), 0);
        }

        pub fn nothing(f: *Frame, at: PlaceId) Error!Value {
            return .{ .node = try f.env.shapes.nothing(f.gpa, f.account(), at) };
        }

        pub fn topValue(f: *Frame, at: PlaceId) Error!Value {
            const top = try f.env.cells.top(f.gpa, f.account());
            return .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, try f.set1(top)) };
        }

        /// A value built at a place the checker gave no structure (a type
        /// variable: `Js.array`'s literal): one leaf of `⊤` and everything its
        /// parts reach, so what flowed into it is in its reach and held at its
        /// own path (#1102, #1136). Each part's union is that part's work, on
        /// its own lane when it has one (§4.1), and a part's reach is memoised,
        /// so a level adds its own cells and never rebuilds the one below.
        pub fn opaqueOf(f: *Frame, at: PlaceId, parts: []const Value, insts: ?[]const u32) Error!Value {
            const sets = &f.env.cells.sets;
            var cells = try f.set1(try f.env.cells.top(f.gpa, f.account()));
            for (parts, 0..) |p, i| {
                if (p.node == .none) continue;
                const kernel = if (insts) |is| try f.lane(is[i]) else null;
                defer if (kernel) |k| f.account().leave(k);
                cells = try sets.unionWith(f.gpa, f.env.charge, cells, try f.env.shapes.reach(f.gpa, f.account(), sets, p.node));
            }
            return .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, cells) };
        }

        /// `k` with κ(n) joined with `c` at the position `k` is.
        pub fn kappaSet(f: *Frame, k: Cond.Kappas, n: NodeId, c: CondId) Error!Cond.Kappas {
            return (try f.env.conds.kappaSet(f.gpa, f.env.charge, k, n, c)).ctx;
        }

        /// `k` with κ(n) joined with `c` at its `[*]`.
        pub fn kappaSetElem(f: *Frame, k: Cond.Kappas, n: NodeId, c: CondId) Error!Cond.Kappas {
            return f.env.conds.kappaSetAt(f.gpa, f.env.charge, k, &.{Step.elem}, n, c);
        }

        // ---- uses ----------------------------------------------------------------

        /// Operand `o` consumed by `by`: a use of the local it reads, if any,
        /// and, where the consumer reads it (a call's argument, a case's
        /// scrutinee; a store or a binding only moves it), the parameter parts
        /// its value holds (`readsOf`).
        pub fn consume(f: *Frame, o: u32, by: u32, kind: Facts.UseKind, use_node: NodeId) Error!void {
            const v = f.val(o);
            if (kind == .call or f.tag(by) == .case) try f.readsOf(v.value, use_node, v.local != none and f.env.places.pathDepth(v.path) == 0);
            if (v.local == none) return;
            const point = f.point_of[f.rel(o)];
            const k: Facts.UseKind = if (kind == .whole and f.env.places.pathDepth(v.path) > 0) .field else kind;
            try f.uses.append(f.gpa, .{
                .local = v.local,
                .path = v.path,
                .point = point,
                .kind = k,
                .region = f.regions.regionOf(point),
                .use_node = use_node,
                .atom = @intCast(f.uses.items.len),
            });
            try f.use_tokens.append(f.gpa, f.token(by));
        }

        /// The parameter parts a consumed value holds, read where the consumer
        /// reads them (§2.6: an operand is used at its consumer; §2.10's
        /// read-off: `R` from uses), for the read-off: each parameter cell at
        /// the value's root is read there (`.none`), and under a call (`use`,
        /// the callee's use of the argument) every parameter cell of the value
        /// is read at the paths of `use` below it. The value is the operand's:
        /// a temporary's, a construction or a call's result, which has no
        /// local to be a use of (#1330: `rbc { b = g.x }` with `rbc r =
        /// List.length r.b.c` reads `π1.x.c`, as `t = { b = g.x }; rbc t`
        /// does), or a local's at its use's path. A local read whole (`bare`)
        /// is the read-off's own at its root. The pair (use node, value node)
        /// is walked as a DAG, each pair once, down to the value's leaves,
        /// whose parameter cells take the use below them whole; a leaf of
        /// marks reads every parameter cell the value reaches. A walk of the
        /// value, growth chosen before it (§4.1).
        pub fn readsOf(f: *Frame, value: Value, use: NodeId, bare: bool) Error!void {
            if (value.node == .none or (bare and use == .none)) return;
            const gpa = f.gpa;
            const shapes = f.env.shapes;
            const cells = f.env.cells;
            const root = try shapes.force(gpa, f.account(), value.node);
            const deeper = use != .none and shapes.kind(root) != .leaf;
            if (bare and !deeper) return;
            const task = try f.account().enter(gpa, null);
            defer f.account().leave(task);
            if (!bare) try f.paramReads(try shapes.cellsOf(gpa, f.account(), &cells.sets, root), .none, use);
            if (!deeper) return;
            var stack: std.ArrayList([2]NodeId) = .empty;
            defer stack.deinit(gpa);
            var seen: Ids.FixedDict(2) = .{};
            defer seen.deinit(gpa);
            var frontier: std.ArrayList(NodeId) = .empty;
            defer frontier.deinit(gpa);
            try stack.append(gpa, .{ use, root });
            while (stack.pop()) |it| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                if ((try seen.getOrPut(gpa, .{ it[0].int(), it[1].int() })).found_existing) continue;
                const n = try shapes.force(gpa, f.account(), it[1]);
                if (it[0] != use or n != root) try f.paramReads(try shapes.cellsOf(gpa, f.account(), &cells.sets, n), it[0], .none);
                if (shapes.kind(n) == .leaf) continue;
                const d = shapes.get(it[0]);
                if (d.kind != .node) {
                    try f.paramReads(try shapes.reach(gpa, f.account(), &cells.sets, n), it[0], .none);
                    continue;
                }
                var kt = shapes.overEntries(d.a);
                while (kt.next()) |k| if (k.step.kind == .level) {
                    frontier.clearRetainingCapacity();
                    try f.reentries(n, &frontier);
                    for (frontier.items) |x| try stack.append(gpa, .{ k.node, x });
                } else if (try shapes.proj(gpa, f.account(), f.env.places, cells, n, k.step)) |x| try stack.append(gpa, .{ k.node, x });
            }
        }

        /// Each parameter cell of `s`, read with use `a`, and with `b` too.
        pub fn paramReads(f: *Frame, s: SetId, a: NodeId, b: NodeId) Error!void {
            const cells = f.env.cells;
            var it = cells.sets.iterate(s);
            while (it.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                if (cells.origin(cells.base(.from(e.key))) != .param) continue;
                try f.param_reads.append(f.gpa, .{ .cell = .from(e.key), .use_node = a });
                if (b != .none) try f.param_reads.append(f.gpa, .{ .cell = .from(e.key), .use_node = b });
            }
        }

        /// A computed operand evaluated before its consumer: pending between.
        pub fn pending(f: *Frame, i: u32) Error!void {
            const v = f.val(i);
            if (v.local != none or v.value.node == .none) return;
            const end = f.point_of[f.rel(i)];
            if (end <= i) return;
            try f.holders.append(f.gpa, .{ .kind = .pending, .who = i, .value = v.value, .start = i, .end = end, .root = .none, .token = f.token(i) });
        }

        pub fn bindLocal(f: *Frame, local: u32, v: Value, point: u32) Error!void {
            f.locals[local] = v;
            f.bound[local] = true;
            const at = try f.ctx.placeOfLocal(f.ctx.ctx, local);
            f.binding[local] = @intCast(f.holders.items.len);
            try f.holders.append(f.gpa, .{ .kind = .binding, .who = local, .value = v, .start = point, .end = point, .root = try f.env.places.rootPath(f.gpa, at), .token = f.token(point) });
        }

        /// The positions one `⟲` step stands for below `x` (`Calls.reentries`).
        pub fn reentries(f: *Frame, x: NodeId, out: *std.ArrayList(NodeId)) Error!void {
            return Calls.reentries(f.env, x, out);
        }
    };
}
