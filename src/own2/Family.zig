//! L12: which declared types share one place graph (`docs/design/ownership-v2.md`
//! §2.1, *A family*). Read off the declarations alone, so the answer depends
//! on no use, on no order and on no module that imports them.
//!
//! A head's edges are the applications in its constructor templates, an alias
//! read through first and a function type's parts skipped, since a function is
//! a leaf of the graph. An edge is **own** when its arguments are the head's
//! parameters in order. A strongly connected set of heads with an edge inside it
//! that is not own is a family. Its heads' cycle reaches another instantiation
//! than the one it started at, so a generic function and its caller would read
//! different graphs. Every expansive cycle (Viroli; Kennedy and Pierce) is one,
//! and so are the finite ones: `T a b = S (T b a)`, `T a = C (T Int)`.
//!
//! Imports are acyclic, so a cycle stays inside one module and the walk stops
//! at a module's edge.
//!
//! Obligations kept here: none of §2.14's directly; the adapter's places are
//! what Lemma T's row for a family rests on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const stamped = @import("../stamped.zig");

const none = std.math.maxInt(u32);

const Edge = struct { to: u32, own: bool };

/// A head's walk state: Tarjan's number, and its component once closed.
const Mark = struct { number: u32, comp: u32 = none };

const Frame = struct { head: u32, cursor: u32, end: u32, number: u32, low: u32 };

pub const Table = struct {
    marks: stamped.Column(u32, Mark) = .{},
    met: u32 = 0,
    edges: std.ArrayList(Edge) = .empty,
    /// Per head met: its run of `edges`.
    runs: stamped.Column(u32, [2]u32) = .{},
    /// Head → family.
    family: stamped.Column(u32, u32) = .{},
    /// Per family, its heads in id order.
    heads: std.ArrayList([]u32) = .empty,
    comps: u32 = 0,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.marks.deinit(gpa);
        t.edges.deinit(gpa);
        t.runs.deinit(gpa);
        t.family.deinit(gpa);
        for (t.heads.items) |h| gpa.free(h);
        t.heads.deinit(gpa);
    }

    /// The family of `head`, an entry of `in.types`, or null.
    pub fn of(t: *Table, gpa: Allocator, in: anytype, head: u32) Allocator.Error!?u32 {
        if (!t.marks.contains(head) and walked(in, head)) try t.settle(gpa, in, head);
        return t.family.get(head);
    }

    pub fn members(t: *const Table, family: u32) []const u32 {
        return t.heads.items[family];
    }

    /// Whether `head` has templates the place graph reads.
    fn walked(in: anytype, head: u32) bool {
        const e = in.types.entries[head];
        if (e.kind != .adt or e.schema_endpoint) return false;
        const k = in.birs[e.module.int()].decl(e.decl).own_kind;
        return k != .sequence and k != .cell;
    }

    /// Tarjan's components from `root`, on an explicit stack.
    fn settle(t: *Table, gpa: Allocator, in: anytype, root: u32) Allocator.Error!void {
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var comp: std.ArrayList(u32) = .empty;
        defer comp.deinit(gpa);
        try t.enter(gpa, in, root, &stack, &comp);
        while (stack.items.len != 0) {
            const f = &stack.items[stack.items.len - 1];
            if (f.cursor != f.end) {
                const to = t.edges.items[f.cursor].to;
                f.cursor += 1;
                if (t.marks.get(to)) |m| {
                    if (m.comp == none) f.low = @min(f.low, m.number);
                } else try t.enter(gpa, in, to, &stack, &comp);
                continue;
            }
            const done = stack.pop().?;
            if (stack.items.len != 0) {
                const up = &stack.items[stack.items.len - 1];
                up.low = @min(up.low, done.low);
            }
            if (done.low == done.number) try t.close(gpa, done.head, &comp);
        }
    }

    fn enter(t: *Table, gpa: Allocator, in: anytype, head: u32, stack: *std.ArrayList(Frame), comp: *std.ArrayList(u32)) Allocator.Error!void {
        const n = t.met;
        t.met += 1;
        try t.marks.put(gpa, head, .{ .number = n });
        try comp.append(gpa, head);
        const start: u32 = @intCast(t.edges.items.len);
        const e = in.types.entries[head];
        const bir = in.birs[e.module.int()];
        const env = try gpa.alloc(u32, e.arity);
        defer gpa.free(env);
        for (env, 0..) |*p, i| p.* = @intCast(i);
        for (bir.declCtors(bir.decl(e.decl))) |c| {
            for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| {
                _ = try t.scan(gpa, in, e.module.int(), arg, env, e.module.int());
            }
        }
        const end: u32 = @intCast(t.edges.items.len);
        try t.runs.put(gpa, head, .{ start, end });
        try stack.append(gpa, .{ .head = head, .cursor = start, .end = end, .number = n, .low = n });
    }

    /// The parameter term `inst` of module `m` is exactly, under `env` (per
    /// parameter of the term's declaration, the walked head's parameter it
    /// stands for), or `none`. Every application in it is an edge.
    fn scan(t: *Table, gpa: Allocator, in: anytype, m: u32, inst: Bir.Inst.Index, env: []const u32, home: u32) Allocator.Error!u32 {
        const bir = in.birs[m];
        const Item = struct { inst: Bir.Inst.Index, expanded: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(gpa);
        var done: stamped.Column(u32, u32) = .{};
        defer done.deinit(gpa);
        var ops: std.ArrayList(Bir.Inst.Index) = .empty;
        defer ops.deinit(gpa);
        var args: std.ArrayList(u32) = .empty;
        defer args.deinit(gpa);
        try stack.append(gpa, .{ .inst = inst, .expanded = false });
        while (stack.pop()) |f| {
            const tag = bir.instTag(f.inst);
            const d = bir.instData(f.inst);
            if (!f.expanded) {
                // A function is a leaf of the graph: its parts are no edge.
                if (tag == .type_fn) {
                    try done.put(gpa, f.inst.int(), none);
                    continue;
                }
                try stack.append(gpa, .{ .inst = f.inst, .expanded = true });
                ops.clearRetainingCapacity();
                try bir.operands(gpa, f.inst, &ops);
                // A type application's head is no term of its own.
                for (ops.items[@intFromBool(tag == .type_app)..]) |o| try stack.append(gpa, .{ .inst = o, .expanded = false });
                continue;
            }
            var result: u32 = none;
            switch (tag) {
                .type_var => {
                    const p = Bir.TypeVarInfo.unpack(d.rhs).param;
                    if (p != Bir.TypeVarInfo.param_none and p < env.len) result = env[p];
                },
                .type_app => {
                    args.clearRetainingCapacity();
                    for (bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index)) |a| try args.append(gpa, done.get(a.int()).?);
                    const head: Bir.Inst.Index = @fromBackingInt(d.lhs);
                    result = try t.applied(gpa, in, in.types.headId(@fromBackingInt(m), bir.instTag(head), bir.instData(head)), args.items, home);
                },
                else => {
                    const g = in.types.headId(@fromBackingInt(m), tag, d);
                    if (g != .none) result = try t.applied(gpa, in, g, &.{}, home);
                },
            }
            try done.put(gpa, f.inst.int(), result);
        }
        return done.get(inst.int()).?;
    }

    fn applied(t: *Table, gpa: Allocator, in: anytype, g: anytype, args: []const u32, home: u32) Allocator.Error!u32 {
        if (g == .none or g.int() >= in.types.entries.len) return none;
        const e = in.types.entries[g.int()];
        if (e.kind == .alias and !e.schema_endpoint) {
            const bir = in.birs[e.module.int()];
            const body = bir.decl(e.decl).annotation.unwrap() orelse return none;
            return t.scan(gpa, in, e.module.int(), body, args, home);
        }
        if (e.module.int() != home or !walked(in, g.int())) return none;
        var own = args.len == e.arity;
        const permuted = @import("Mutate.zig").on(.family_permuted_own);
        for (args, 0..) |a, i| own = own and (a == i or (permuted and a != none));
        try t.edges.append(gpa, .{ .to = g.int(), .own = own });
        return none;
    }

    /// Close the component `comp` holds down to `head`: a family when an edge inside it is not own.
    fn close(t: *Table, gpa: Allocator, head: u32, comp: *std.ArrayList(u32)) Allocator.Error!void {
        const id = t.comps;
        t.comps += 1;
        var start = comp.items.len - 1;
        while (comp.items[start] != head) start -= 1;
        const ms = comp.items[start..];
        for (ms) |m| t.marks.getPtr(m).?.comp = id;
        var irregular = false;
        for (ms) |m| {
            const r = t.runs.get(m).?;
            for (t.edges.items[r[0]..r[1]]) |x| irregular = irregular or (!x.own and t.marks.get(x.to).?.comp == id);
        }
        if (irregular) {
            const family: u32 = @intCast(t.heads.items.len);
            const hs = try gpa.dupe(u32, ms);
            std.mem.sort(u32, hs, {}, std.sort.asc(u32));
            try t.heads.append(gpa, hs);
            for (hs) |m| try t.family.put(gpa, m, family);
        }
        comp.shrinkRetainingCapacity(start);
    }
};
