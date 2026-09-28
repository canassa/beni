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

/// `memo`'s hash: the wanted's index times an odd constant, the context in
/// the bits the product leaves alone. `std`'s `AutoContext` runs Wyhash
/// over the key, which was most of elaborating a record of 65 537 fields.
const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        return (@as(u64, @intFromEnum(k.wanted)) << 2 | @intFromEnum(k.ctx)) *% 0x9E37_79B9_7F4A_7C15;
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.wanted == b.wanted and a.ctx == b.ctx;
    }
};

pub const Node = struct { term: Dispatch.Term, args: Dispatch.Range = .empty };

pub const Pending = struct { node: u32, key: Key };

nodes: std.ArrayList(Node) = .empty,
/// Every node's arguments, as node indices.
node_args: std.ArrayList(u32) = .empty,
/// Each wanted's node. A site's unit is a handful of nodes, so the first
/// `inline_len` are searched in `inline_keys` and only a larger unit hashes
/// (hashing every unit cost a seventh of P6 on 6 000 tuple comparisons).
memo: std.HashMapUnmanaged(Key, u32, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
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

pub fn deinit(u: *Unit, scratch: Allocator) void {
    u.nodes.deinit(scratch);
    u.node_args.deinit(scratch);
    u.memo.deinit(scratch);
    u.pending.deinit(scratch);
    u.roots.deinit(scratch);
}

pub fn begin(u: *Unit) void {
    u.nodes.clearRetainingCapacity();
    u.node_args.clearRetainingCapacity();
    u.memo.clearRetainingCapacity();
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
        try u.memo.ensureTotalCapacity(scratch, inline_len * 2);
        for (u.inline_keys, u.inline_nodes) |k, n| u.memo.putAssumeCapacity(k, n);
        u.inlined = inline_len + 1;
    }
    const entry = try u.memo.getOrPut(scratch, key);
    if (entry.found_existing) return entry.value_ptr.*;
    entry.value_ptr.* = try u.newWanted(scratch, key);
    return entry.value_ptr.*;
}

fn newWanted(u: *Unit, scratch: Allocator, key: Key) Error!u32 {
    const n: u32 = @intCast(u.nodes.items.len);
    try u.nodes.append(scratch, .{ .term = .undetermined });
    try u.pending.append(scratch, .{ .node = n, .key = key });
    return n;
}

pub fn leaf(u: *Unit, scratch: Allocator, t: Dispatch.Term) Error!u32 {
    const n: u32 = @intCast(u.nodes.items.len);
    try u.nodes.append(scratch, .{ .term = t });
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
        try stack.append(scratch, .{ .node = r, .cursor = u.nodes.items[r].args.len });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.cursor == 0) {
                colour[top.node] = 2;
                try post.append(scratch, top.node);
                _ = stack.pop();
                continue;
            }
            top.cursor -= 1;
            const a = u.nodes.items[top.node].args;
            const child = u.node_args.items[a.start + top.cursor];
            switch (colour[child]) {
                0 => {
                    colour[child] = 1;
                    try stack.append(scratch, .{ .node = child, .cursor = u.nodes.items[child].args.len });
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
            try args.append(gpa, @enumFromInt(index[child]));
        }
        const range: Dispatch.Range = .{ .start = start, .len = node.args.len };
        switch (t) {
            .top => |*x| x.args = range,
            .ext => |*x| x.args = range,
            .derived => |*x| x.args = range,
            .ext_derived => |*x| x.args = range,
            else => {},
        }
        try terms.append(gpa, t);
    }
    for (u.roots.items) |r| try out.append(scratch, @enumFromInt(index[r]));
    return true;
}
