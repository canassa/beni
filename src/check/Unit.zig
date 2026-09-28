//! One elaboration unit (checker-v2.md §12.2, §13.1): the
//! terms of one site (its callee and evidence roots) or of one derived row's
//! body, built as a DAG and written in topological order.
//!
//! A node is one term whose arguments are other nodes of the unit. A wanted
//! is ONE node per unit and context, whichever of its aliases reaches it, so
//! an answer the resolver shared (§9.5's memo) is one term here too, and
//! `==` on a doubling DAG of a type costs its distinct nodes.
//!
//! **The context** of a node is the kind of its nearest `derived` or
//! `ext_derived` ancestor (a row body's positions are inside their row), or
//! none. It is part of the key because it decides how an `undetermined`
//! answer is written (`Elaborate.undetermined`): the leaf takes its method from that ancestor in `Lower`, so the
//! leaf is written only where the ancestor's kind IS the wanted's method.
//!
//! `emit` writes the nodes reachable from the roots in REVERSE POST-ORDER —
//! owners before arguments, so every argument's index is greater than
//! every owner's even where a node is shared, and a unit with no sharing
//! reads in pre-order — by explicit stacks, so no walk stops at a fixed
//! depth.

const std = @import("std");
const lists = @import("../lists.zig");
const Allocator = std.mem.Allocator;
const Dispatch = @import("Dispatch.zig");
const Evidence = @import("Evidence.zig");

const Unit = @This();

pub const Error = Allocator.Error;
const TermIndex = Dispatch.TermIndex;

/// The kind of a node's nearest derived ancestor.
pub const Ctx = enum(u8) {
    none,
    eq,
    compare,

    pub fn of(kind: Dispatch.Derived.Kind) Ctx {
        return switch (kind) {
            .eq => .eq,
            .compare => .compare,
        };
    }
};

pub const Key = struct { wanted: Evidence.WantedId, ctx: Ctx };

pub const Node = struct { term: Dispatch.Term, args: Dispatch.Range = .empty };

pub const Pending = struct { node: u32, key: Key };

nodes: std.ArrayList(Node) = .empty,
/// Every node's arguments, as node indices.
node_args: std.ArrayList(u32) = .empty,
/// Each wanted's node. A site's unit is a handful of nodes, so the first
/// `inline_len` are searched in `inline_keys`; a larger unit reads `memo`,
/// dense over the module's wanteds and contexts (a wanted id is a dense id,
/// and hashing one cost most of elaborating a record of 65 537 fields). A
/// slot means something only while its stamp is `epoch`, so a unit clears
/// nothing: `begin` is one increment.
memo: std.ArrayList(u32) = .empty,
memo_stamp: std.ArrayList(u32) = .empty,
epoch: u32 = 0,
inline_keys: [inline_len]Key = undefined,
inline_nodes: [inline_len]u32 = undefined,
/// Keys held inline, or `inline_len + 1` once they moved into `memo`.
inlined: u32 = 0,

/// Wanted nodes whose term is not written yet.
pending: std.ArrayList(Pending) = .empty,
/// The unit's roots, in order: a site's callee, then its evidence roots, or
/// a row's body positions. A root may repeat a node.
roots: std.ArrayList(u32) = .empty,

const inline_len = 16;
const contexts = @typeInfo(Ctx).@"enum".fields.len;

pub fn deinit(u: *Unit, scratch: Allocator) void {
    u.nodes.deinit(scratch);
    u.node_args.deinit(scratch);
    u.memo.deinit(scratch);
    u.memo_stamp.deinit(scratch);
    u.pending.deinit(scratch);
    u.roots.deinit(scratch);
}

pub fn begin(u: *Unit) void {
    u.nodes.clearRetainingCapacity();
    u.node_args.clearRetainingCapacity();
    if (u.inlined > inline_len) {
        u.epoch +%= 1;
        if (u.epoch == 0) {
            @memset(u.memo_stamp.items, 0);
            u.epoch = 1;
        }
    }
    u.inlined = 0;
    u.pending.clearRetainingCapacity();
    u.roots.clearRetainingCapacity();
}

/// The node for `key`'s wanted (already followed through its aliases), made
/// and queued when it is new.
pub fn wanted(u: *Unit, scratch: Allocator, key: Key) Error!u32 {
    if (u.inlined <= inline_len) {
        for (u.inline_keys[0..u.inlined], u.inline_nodes[0..u.inlined]) |k, n| {
            if (k.wanted == key.wanted and k.ctx == key.ctx) return n;
        }
        if (u.inlined < inline_len) {
            const n = try u.newWanted(scratch, key);
            u.inline_keys[u.inlined] = key;
            u.inline_nodes[u.inlined] = n;
            u.inlined += 1;
            return n;
        }
        if (u.epoch == 0) u.epoch = 1;
        for (u.inline_keys, u.inline_nodes) |k, n| (try u.slot(scratch, k)).* = n;
        u.inlined = inline_len + 1;
    }
    const at = try u.slot(scratch, key);
    const stamp = &u.memo_stamp.items[slotIndex(key)];
    if (stamp.* == u.epoch) return at.*;
    const n = try u.newWanted(scratch, key);
    u.memo.items[slotIndex(key)] = n;
    stamp.* = u.epoch;
    return n;
}

fn slotIndex(key: Key) usize {
    return @as(usize, @intFromEnum(key.wanted)) * contexts + @intFromEnum(key.ctx);
}

/// `key`'s slot in `memo`, the columns grown to hold it (to twice what is
/// needed, so growth is amortised). Stamped live only by the caller.
fn slot(u: *Unit, scratch: Allocator, key: Key) Error!*u32 {
    const i = slotIndex(key);
    if (i >= u.memo.items.len) {
        const len = @max(i + 1, u.memo.items.len * 2, 64);
        try u.memo.appendNTimes(scratch, 0, len - u.memo.items.len);
        try u.memo_stamp.appendNTimes(scratch, 0, len - u.memo_stamp.items.len);
    }
    // Inline keys moved here are live at once.
    if (u.inlined <= inline_len) u.memo_stamp.items[i] = u.epoch;
    return &u.memo.items[i];
}

fn newWanted(u: *Unit, scratch: Allocator, key: Key) Error!u32 {
    const n: u32 = @intCast(u.nodes.items.len);
    try lists.add(&u.nodes, scratch, .{ .term = .undetermined });
    try lists.add(&u.pending, scratch, .{ .node = n, .key = key });
    return n;
}

pub fn leaf(u: *Unit, scratch: Allocator, t: Dispatch.Term) Error!u32 {
    const n: u32 = @intCast(u.nodes.items.len);
    try lists.add(&u.nodes, scratch, .{ .term = t });
    return n;
}

/// `nodes` as a run of `node_args`.
pub fn addArgs(u: *Unit, scratch: Allocator, nodes: []const u32) Error!Dispatch.Range {
    const start: u32 = @intCast(u.node_args.items.len);
    try u.node_args.appendSlice(scratch, nodes);
    return .{ .start = start, .len = @intCast(nodes.len) };
}

/// Write the nodes reachable from the roots onto `terms`/`args`, and append
/// each root's term to `out`. False on a cycle, which the resolver never
/// makes.
pub fn emit(
    u: *const Unit,
    gpa: Allocator,
    scratch: Allocator,
    terms: *std.ArrayList(Dispatch.Term),
    args: *std.ArrayList(TermIndex),
    out: *std.ArrayList(TermIndex),
) Error!bool {
    // A wanted's node holds `undetermined`, which is also a real answer,
    // until `Elaborate.fillUnit` answers it: nothing may be emitted while
    // one is still pending.
    if (std.debug.runtime_safety and u.pending.items.len != 0) {
        std.debug.panic("a dispatch unit was emitted with {d} wanted nodes unanswered (checker-v2.md §13.1)", .{u.pending.items.len});
    }
    const n = u.nodes.items.len;
    const colour = try scratch.alloc(u8, n);
    defer scratch.free(colour);
    @memset(colour, 0);
    var post: std.ArrayList(u32) = .empty;
    defer post.deinit(scratch);
    const Frame = struct { node: u32, cursor: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(scratch);
    // Roots and arguments are visited last first, so the reversed post-order
    // is the pre-order of a tree.
    var ri = u.roots.items.len;
    while (ri > 0) {
        ri -= 1;
        const r = u.roots.items[ri];
        if (colour[r] != 0) continue;
        colour[r] = 1;
        try lists.add(&stack, scratch, .{ .node = r, .cursor = u.nodes.items[r].args.len });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.cursor == 0) {
                colour[top.node] = 2;
                try lists.add(&post, scratch, top.node);
                _ = stack.pop();
                continue;
            }
            top.cursor -= 1;
            const a = u.nodes.items[top.node].args;
            const child = u.node_args.items[a.start + top.cursor];
            switch (colour[child]) {
                0 => {
                    colour[child] = 1;
                    try lists.add(&stack, scratch, .{ .node = child, .cursor = u.nodes.items[child].args.len });
                },
                1 => return false,
                else => {},
            }
        }
    }
    const index = try scratch.alloc(u32, n);
    defer scratch.free(index);
    const base: u32 = @intCast(terms.items.len);
    for (0..post.items.len) |k| index[post.items[post.items.len - 1 - k]] = base + @as(u32, @intCast(k));
    var k = post.items.len;
    while (k > 0) {
        k -= 1;
        const node = u.nodes.items[post.items[k]];
        var t = node.term;
        const start: u32 = @intCast(args.items.len);
        for (u.node_args.items[node.args.start..][0..node.args.len]) |child| {
            try lists.add(args, gpa, @enumFromInt(index[child]));
        }
        const range: Dispatch.Range = .{ .start = start, .len = node.args.len };
        switch (t) {
            .top => |*x| x.args = range,
            .ext => |*x| x.args = range,
            .derived => |*x| x.args = range,
            .ext_derived => |*x| x.args = range,
            else => {},
        }
        try lists.add(terms, gpa, t);
    }
    for (u.roots.items) |r| try out.append(scratch, @enumFromInt(index[r]));
    return true;
}
