//! Which type aliases are injective (checker-v2.md §7.1):
//! `Types.Entry.injective`, settled once per session
//! by `Types.build` and read by `Unify.throughAlias`; and, over the same
//! walk of the alias DAG, each alias's shape (`Types.Entry.shape`,
//! `AliasShape`, §7.4 as amended 2026-11-06), read by `Builder.apply`.
//! Split out of `Types.zig` by §19.1's 1 500-line rule.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const Graph = @import("../resolve/Graph.zig");
const Types = @import("Types.zig");
const AliasShape = @import("AliasShape.zig");

const Entry = Types.Entry;

/// Settle `Entry.injective` for every alias, once per session.
///
/// A parameter is KEPT when it occurs in the alias's body outside every
/// argument position that a nested alias drops: `type alias T a = Tagged a`
/// keeps nothing, because `Tagged` drops its one parameter. So a nested
/// alias is settled before the alias whose body names it — a depth-first
/// order over the alias DAG, iterative (a chain of aliases is as long as a
/// program makes it). A body is a tree, walked with an explicit stack. An
/// alias met while it is being settled is recursive, which resolution
/// refused (`recursive_alias`): its argument positions count as dropped,
/// the answer that is always sound.
pub fn settle(
    types: *Types,
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
) Allocator.Error!void {
    const n = types.entries.len;
    if (n == 0) return;
    // `kept[offsets[i] + j]`: alias `i` keeps its parameter `j`.
    const offsets = try gpa.alloc(u32, n + 1);
    defer gpa.free(offsets);
    var total: u32 = 0;
    for (types.entries, 0..) |e, i| {
        offsets[i] = total;
        if (isPlainAlias(e)) total += e.arity;
    }
    offsets[n] = total;
    const kept = try gpa.alloc(bool, total);
    defer gpa.free(kept);
    @memset(kept, false);
    const state = try gpa.alloc(State, n);
    defer gpa.free(state);
    @memset(state, .unvisited);

    const Item = struct { module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index, live: bool };
    var work: std.ArrayList(Item) = .empty;
    defer work.deinit(gpa);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(gpa);
    var shape_work: std.ArrayList(ShapeItem) = .empty;
    defer shape_work.deinit(gpa);

    for (types.entries, 0..) |first, fi| {
        if (!isPlainAlias(first) or state[fi] != .unvisited) continue;
        state[fi] = .settling;
        try pending.append(gpa, @intCast(fi));
        settle: while (pending.items.len != 0) {
            const i = pending.items[pending.items.len - 1];
            const e = types.entries[i];
            const bir = artifacts.bir(graph.moduleFile(e.module));
            const d = bir.decl(e.decl);
            const body = d.annotation.unwrap() orelse {
                state[i] = .settled;
                _ = pending.pop();
                continue;
            };
            // Pass 1: a nested alias not settled yet goes first.
            work.clearRetainingCapacity();
            try work.append(gpa, .{ .module = e.module, .bir = bir, .inst = body, .live = true });
            while (work.pop()) |item| {
                const b = item.bir;
                const data = b.instData(item.inst);
                const tag = b.instTag(item.inst);
                // An alias of no arguments too: pass 3 reads its shape.
                if (tag == .type_app or tag == .type_top or tag == .ext_type) {
                    const head: Bir.Inst.Index = if (tag == .type_app) @fromBackingInt(@intCast(data.lhs)) else item.inst;
                    const id = types.headId(item.module, b.instTag(head), b.instData(head));
                    if (id != .none and id.int() < n and isPlainAlias(types.entries[id.int()]) and state[id.int()] == .unvisited) {
                        state[id.int()] = .settling;
                        try pending.append(gpa, id.int());
                        continue :settle;
                    }
                }
                try pushTypeChildren(gpa, &work, item, true);
            }
            // Pass 2: which parameters survive.
            const params = bir.declTypeParams(d);
            const mine = kept[offsets[i]..offsets[i + 1]];
            work.clearRetainingCapacity();
            try work.append(gpa, .{ .module = e.module, .bir = bir, .inst = body, .live = true });
            while (work.pop()) |item| {
                const b = item.bir;
                const tag = b.instTag(item.inst);
                const data = b.instData(item.inst);
                switch (tag) {
                    .type_var => if (item.live) {
                        const var_name = b.symbol(@fromBackingInt(@intCast(data.lhs)));
                        const info = Bir.TypeVarInfo.unpack(data.rhs);
                        if (info.param != Bir.TypeVarInfo.param_none and info.param < mine.len and info.param < params.len and params[info.param] == var_name) {
                            mine[info.param] = true;
                        } else for (params, 0..) |p, j| {
                            if (p == var_name and j < mine.len) mine[j] = true;
                        }
                    },
                    .type_app => {
                        const head: Bir.Inst.Index = @fromBackingInt(@intCast(data.lhs));
                        const head_tag = b.instTag(head);
                        const id = types.headId(item.module, head_tag, b.instData(head));
                        const args = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index);
                        const nested = id != .none and id.int() < n and types.entries[id.int()].kind == .alias;
                        for (args, 0..) |arg, j| {
                            // An argument survives a nested alias only where
                            // that alias keeps its parameter; a schema
                            // endpoint's or a recursive alias's never does.
                            const through = if (!nested) head_tag != .schema_type_top and head_tag != .ext_schema_type else blk: {
                                const x = id.int();
                                if (!isPlainAlias(types.entries[x]) or state[x] != .settled) break :blk false;
                                break :blk j < offsets[x + 1] - offsets[x] and kept[offsets[x] + j];
                            };
                            try work.append(gpa, .{ .module = item.module, .bir = b, .inst = arg, .live = item.live and through });
                        }
                    },
                    else => try pushTypeChildren(gpa, &work, item, false),
                }
            }
            types.entries[i].injective = std.mem.allEqual(bool, mine, true);
            // Pass 3: the alias's shape (checker-v2.md §7.4, amended
            // 2026-11-06), over its nested aliases' settled shapes.
            types.entries[i].shape = try shapeOf(types, gpa, &shape_work, e.module, bir, body, params, state);
            state[i] = .settled;
            _ = pending.pop();
        }
    }
}

const State = enum(u8) { unvisited, settling, settled };
const ShapeItem = struct { module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index, c: AliasShape.Context };
const Child = struct { module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index, live: bool };

/// The shape of the alias whose body is `body` (`AliasShape`): its body
/// walked from the top in the `spine` context, each nested alias's
/// arguments in the contexts its settled shape gives. Unknown when the
/// body names anything whose shape is not known — a recursive alias, a
/// schema endpoint, a type that did not resolve or has the wrong number
/// of arguments — or a variable that is not a parameter: the read then
/// keys by every argument, as before.
fn shapeOf(
    types: *const Types,
    gpa: Allocator,
    work: *std.ArrayList(ShapeItem),
    module: Graph.Index,
    bir: *const Bir,
    body: Bir.Inst.Index,
    params: []const Bir.Symbol,
    state: []const State,
) Allocator.Error!AliasShape {
    if (params.len > AliasShape.max_params) return .{};
    var s: AliasShape = .{ .known = true };
    work.clearRetainingCapacity();
    try work.append(gpa, .{ .module = module, .bir = bir, .inst = body, .c = .spine });
    while (work.pop()) |item| {
        const b = item.bir;
        const tag = b.instTag(item.inst);
        const data = b.instData(item.inst);
        switch (tag) {
            .type_var => {
                const var_name = b.symbol(@fromBackingInt(@intCast(data.lhs)));
                const info = Bir.TypeVarInfo.unpack(data.rhs);
                const j = if (info.param != Bir.TypeVarInfo.param_none and info.param < params.len and params[info.param] == var_name)
                    info.param
                else
                    std.mem.indexOfScalar(Bir.Symbol, params, var_name) orelse return .{};
                if (!s.note(j, item.c)) return .{};
            },
            .type_unit => {},
            .type_fn, .type_tuple, .type_record, .type_record_ext => {
                // The same children `pushTypeChildren` walks, in the
                // context inside a structure.
                var children: std.ArrayList(Child) = .empty;
                defer children.deinit(gpa);
                try pushTypeChildren(gpa, &children, Child{ .module = item.module, .bir = b, .inst = item.inst, .live = true }, false);
                for (children.items) |child| try work.append(gpa, .{ .module = child.module, .bir = child.bir, .inst = child.inst, .c = item.c.inside() });
            },
            .type_top, .ext_type => {
                const id = types.headId(item.module, tag, data);
                if (id == .none or id.int() >= types.entries.len) return .{};
                // A type of parameters written with none is `err` in a
                // read (`wrong_type_arity`), which no shape describes.
                if (!shapeKnown(types, id.int(), state) or types.entries[id.int()].arity != 0) return .{};
            },
            .type_app => {
                const head: Bir.Inst.Index = @fromBackingInt(@intCast(data.lhs));
                const head_tag = b.instTag(head);
                if (head_tag != .type_top and head_tag != .ext_type) return .{};
                const id = types.headId(item.module, head_tag, b.instData(head));
                if (id == .none or id.int() >= types.entries.len) return .{};
                if (!shapeKnown(types, id.int(), state)) return .{};
                const nested = types.entries[id.int()];
                const args = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index);
                if (args.len != nested.arity) return .{};
                for (args, 0..) |arg, j| {
                    const c = if (nested.kind == .alias) item.c.argument(nested.shape, j) else item.c.inside();
                    try work.append(gpa, .{ .module = item.module, .bir = b, .inst = arg, .c = c });
                }
            },
            // A schema endpoint, or a type resolution refused.
            else => return .{},
        }
    }
    return s;
}

/// A named type whose expansion a shape may look through: a nominal type,
/// or a plain alias settled with a known shape.
fn shapeKnown(types: *const Types, i: u32, state: []const State) bool {
    const e = types.entries[i];
    if (e.kind != .alias) return !e.schema_endpoint;
    return isPlainAlias(e) and state[i] == .settled and e.shape.known;
}

/// An alias declaration `settleInjective` reads the body of.
fn isPlainAlias(e: Entry) bool {
    return e.kind == .alias and !e.schema_endpoint;
}

/// The written children of a type instruction, onto `work` with the
/// parent's liveness. `apps` says whether a `type_app`'s arguments are
/// pushed here too (pass 1) or by the caller (pass 2).
fn pushTypeChildren(gpa: Allocator, work: anytype, item: anytype, apps: bool) Allocator.Error!void {
    const b = item.bir;
    const data = b.instData(item.inst);
    const Item = @TypeOf(item);
    switch (b.instTag(item.inst)) {
        .type_fn => {
            for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Bir.Inst.Index)) |p| {
                try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = p, .live = item.live });
            }
            try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = @fromBackingInt(@intCast(data.rhs)), .live = item.live });
        },
        .type_tuple => for (b.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |el| {
            try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = el, .live = item.live });
        },
        .type_record => for (b.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| {
            try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = f.value, .live = item.live });
        },
        .type_record_ext => {
            try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = @fromBackingInt(@intCast(data.lhs)), .live = item.live });
            for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field)) |f| {
                try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = f.value, .live = item.live });
            }
        },
        .type_app => if (apps) {
            for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index)) |arg| {
                try work.append(gpa, Item{ .module = item.module, .bir = b, .inst = arg, .live = item.live });
            }
        },
        else => {},
    }
}
