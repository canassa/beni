//! L13: which nominal heads a fold can reach, read off the templates alone
//! (`docs/design/ownership-v2.md` §2.1, *A level past a fold*). A head is
//! non-regular when it is on a cycle of heads, one of whose applications is
//! not the head's own parameters in order. The answer is a fact of the type
//! declarations, so it does not depend on which place was made first, and a
//! contract's `⟲` is the same word in any declaration order and any module.
//! Saying so of a regular head (`T b a` of a period two) costs nothing: the
//! walk that reads the word follows the steps of the place it was written at.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const stamped = @import("../stamped.zig");

const none: u32 = std.math.maxInt(u32);
const Edge = struct { to: u32, same: bool };
const Frame = struct { head: u32, first: u32, len: u32, cursor: u32 = 0, index: u32, low: u32 };

pub const Table = struct {
    verdict: stamped.Column(u32, bool) = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.verdict.deinit(gpa);
    }

    /// Whether `head` is non-regular. `in` is `Groups.Input`.
    pub fn nonRegular(t: *Table, gpa: Allocator, in: anytype, head: u32) Allocator.Error!bool {
        if (t.verdict.get(head)) |known| return known;
        try t.settle(gpa, in, head);
        return t.verdict.get(head).?;
    }

    /// Tarjan over the heads below `root` that have no verdict, on an explicit stack.
    fn settle(t: *Table, gpa: Allocator, in: anytype, root: u32) Allocator.Error!void {
        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(gpa);
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        var index: stamped.Column(u32, u32) = .{}; // head → index, `none` once its component is out
        defer index.deinit(gpa);
        var next: u32 = 0;
        try open(gpa, in, root, &edges, &frames, &stack, &index, &next);
        while (frames.items.len > 0) {
            const f = &frames.items[frames.items.len - 1];
            if (f.cursor < f.len) {
                const e = edges.items[f.first + f.cursor];
                f.cursor += 1;
                if (t.verdict.contains(e.to)) continue;
                if (index.get(e.to)) |i| {
                    if (i != none) f.low = @min(f.low, i);
                } else try open(gpa, in, e.to, &edges, &frames, &stack, &index, &next);
                continue;
            }
            const done = frames.pop().?;
            if (frames.items.len > 0) {
                const p = &frames.items[frames.items.len - 1];
                p.low = @min(p.low, done.low);
            }
            if (done.low != done.index) continue;
            const members = stack.items[std.mem.lastIndexOfScalar(u32, stack.items, done.head).?..];
            var folds = false;
            for (members) |m| {
                var mine: std.ArrayList(Edge) = .empty;
                defer mine.deinit(gpa);
                try edgesOf(gpa, in, m, &mine);
                for (mine.items) |e| folds = folds or (!e.same and std.mem.indexOfScalar(u32, members, e.to) != null);
            }
            for (members) |m| {
                try t.verdict.put(gpa, m, folds);
                try index.put(gpa, m, none);
            }
            stack.shrinkRetainingCapacity(stack.items.len - members.len);
        }
    }
};

fn open(gpa: Allocator, in: anytype, head: u32, edges: *std.ArrayList(Edge), frames: *std.ArrayList(Frame), stack: *std.ArrayList(u32), index: *stamped.Column(u32, u32), next: *u32) Allocator.Error!void {
    const first: u32 = @intCast(edges.items.len);
    try edgesOf(gpa, in, head, edges);
    try index.put(gpa, head, next.*);
    try stack.append(gpa, head);
    try frames.append(gpa, .{ .head = head, .first = first, .len = @intCast(edges.items.len - first), .index = next.*, .low = next.* });
    next.* += 1;
}

/// The heads `head`'s constructors apply, an alias read through.
fn edgesOf(gpa: Allocator, in: anytype, head: u32, out: *std.ArrayList(Edge)) Allocator.Error!void {
    if (head >= in.types.entries.len) return;
    const e = in.types.entries[head];
    if (e.kind != .adt or e.schema_endpoint) return;
    const bir = in.birs[e.module.int()];
    // An alias is read through once a head: a diamond of them is not 2ⁿ reads.
    var read: std.ArrayList(u32) = .empty;
    defer read.deinit(gpa);
    for (bir.declCtors(bir.decl(e.decl))) |c| {
        for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| try scan(gpa, in, e.module.int(), arg, e.arity, false, &read, out);
    }
}

/// The applications in term `root` of module `m`. `alias`: read through an
/// alias, whose parameters are not the head's, so no application is `same`.
fn scan(gpa: Allocator, in: anytype, m: u32, root: Bir.Inst.Index, arity: u32, alias: bool, read: *std.ArrayList(u32), out: *std.ArrayList(Edge)) Allocator.Error!void {
    const bir = in.birs[m];
    var stack: std.ArrayList(Bir.Inst.Index) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root);
    while (stack.pop()) |inst| {
        const d = bir.instData(inst);
        const tag = bir.instTag(inst);
        if (tag == .type_app) {
            const args = bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index);
            const h: Bir.Inst.Index = @fromBackingInt(d.lhs);
            try apply(gpa, in, in.types.headId(@fromBackingInt(m), bir.instTag(h), bir.instData(h)).int(), !alias and own(bir, args, arity), arity, read, out);
            try stack.appendSlice(gpa, args);
            continue;
        }
        const t = in.types.headId(@fromBackingInt(m), tag, d);
        if (t != .none) {
            try apply(gpa, in, t.int(), !alias and arity == 0, arity, read, out);
            continue;
        }
        try bir.operands(gpa, inst, &stack);
    }
}

fn apply(gpa: Allocator, in: anytype, head: u32, same: bool, arity: u32, read: *std.ArrayList(u32), out: *std.ArrayList(Edge)) Allocator.Error!void {
    if (head >= in.types.entries.len) return;
    const e = in.types.entries[head];
    if (e.kind != .alias or e.schema_endpoint) return out.append(gpa, .{ .to = head, .same = same });
    if (std.mem.indexOfScalar(u32, read.items, head) != null) return;
    try read.append(gpa, head);
    const bir = in.birs[e.module.int()];
    const body = bir.decl(e.decl).annotation.unwrap() orelse return;
    return scan(gpa, in, e.module.int(), body, arity, true, read, out);
}

/// Whether `args` are the parameters `0 … n-1`, `n` at most `arity`.
fn own(bir: *const Bir, args: []const Bir.Inst.Index, arity: u32) bool {
    if (args.len > arity) return false;
    for (args, 0..) |a, i| {
        if (bir.instTag(a) != .type_var or Bir.TypeVarInfo.unpack(bir.instData(a).rhs).param != i) return false;
    }
    return true;
}
