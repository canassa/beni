//! Summaries (transparent-effects-proposal.md §14.4): what `Effects.run`
//! reads off the solved graph for each declaration — its scheme's classes,
//! each one's rung, the other classes of the same scheme that reach it, the
//! demands it reaches (§15.3), and the fixed classes it reaches (§14.3 rule
//! 3, amended 2026-11-06) — and the walks that read them. Split from
//! `Effects.zig` at checker-v2.md §19.1's cap; `Effects` calls these and
//! nothing else does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Effects = @import("Effects.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Error = Effects.Error;
const Input = Effects.Input;
const none = Effects.none;

/// Read each member's summary off the graph: its scheme's classes, each
/// one's rung, and — 64 classes at a time, one bit each, pushed forward
/// along the edges — which of the declaration's other classes reach it.
/// True when a summary changed.
pub fn summarise(e: *Effects, in: Input, members: []const u32) Error!bool {
    const s = &e.solved;
    const scratch = in.scratch;
    var changed = false;
    const demands = s.sources.items.len != 0;
    for (members) |d| {
        const kind = in.bir.decls[d].kind;
        if (!kind.isValue() or kind == .foreign_value or kind == .vocab_markup) continue;
        const scheme = in.decl_scheme[d].unwrap() orelse continue;
        // The declaration's own root class publishes no demand (§15.3).
        const root: u32 = blk: {
            const r, _ = e.store.resolved(scheme);
            break :blk if (e.carries(r)) try e.nodeFor(r) else none;
        };
        const nodes = &s.scheme_nodes;
        nodes.clearRetainingCapacity();
        const rd = e.readings[d];
        if (rd.scheme_start != none and e.store.content(e.store.find(scheme)) != .err) {
            // An annotated scheme's variables are its reading's range: no
            // walk (see `readings`).
            for (rd.scheme_start..rd.scheme_end) |i| {
                const r = e.store.find(@fromBackingInt(@intCast(i)));
                if (!e.carries(r)) continue;
                const nd = try e.nodeFor(r);
                if (std.mem.indexOfScalar(u32, nodes.items, nd) == null) try nodes.append(e.gpa, nd);
            }
        } else try schemeNodes(e, scheme, nodes);
        // One class, the common case, depends on no other: no bits to push.
        if (nodes.items.len <= 1) {
            const old = s.classesOf(d);
            if (nodes.items.len == 0) {
                if (old.len == 0) continue;
                s.summaries[d] = .{};
                changed = true;
                continue;
            }
            const nd = nodes.items[0];
            const sync = demands and nd != root and s.level.items[nd] != .suspends and try reachesDemand(e, nd, scratch);
            const outs = try fixedReached(e, nd, scratch);
            defer scratch.free(outs);
            if (old.len == 1 and old[0].node == nd and old[0].rung == s.level.items[nd] and old[0].sync == sync and
                std.mem.eql(u32, s.outsOf(old[0]), outs)) continue;
            changed = true;
            s.summaries[d] = .{ .start = @intCast(s.classes.items.len), .len = 1 };
            const outs_start: u32 = @intCast(s.outs.items.len);
            try s.outs.appendSlice(e.gpa, outs);
            try s.classes.append(e.gpa, .{ .node = nd, .rung = s.level.items[nd], .outs_start = outs_start, .outs_len = @intCast(outs.len), .sync = sync });
            continue;
        }
        const reach = try scratch.alloc(bool, nodes.items.len);
        defer scratch.free(reach);
        @memset(reach, false);
        const deps = try dependencies(e, nodes.items, scratch, if (demands) reach else null);
        defer {
            for (deps) |list| scratch.free(list);
            scratch.free(deps);
        }
        for (nodes.items, reach) |nd, *r| r.* = r.* and nd != root and s.level.items[nd] != .suspends;
        // The fixed classes each class reaches (§14.3 rule 3, amended
        // 2026-11-06): none in a module with no fixed class.
        const outs = try scratch.alloc([]const u32, nodes.items.len);
        defer {
            for (outs) |list| scratch.free(list);
            scratch.free(outs);
        }
        for (nodes.items, outs) |nd, *o| o.* = try fixedReached(e, nd, scratch);
        // Compare with the summary in place, then replace it.
        const old = s.classesOf(d);
        var same = old.len == nodes.items.len;
        if (same) {
            for (old, nodes.items, deps, reach, outs) |c, nd, ds, sync, os| {
                if (c.node != nd or c.rung != s.level.items[nd] or c.sync != sync or !std.mem.eql(u32, s.depsOf(c), ds) or
                    !std.mem.eql(u32, s.outsOf(c), os)) same = false;
            }
        }
        if (same) continue;
        changed = true;
        const start: u32 = @intCast(s.classes.items.len);
        for (nodes.items, deps, reach, outs) |nd, ds, sync, os| {
            const deps_start: u32 = @intCast(s.deps.items.len);
            try s.deps.appendSlice(e.gpa, ds);
            const outs_start: u32 = @intCast(s.outs.items.len);
            try s.outs.appendSlice(e.gpa, os);
            try s.classes.append(e.gpa, .{
                .node = nd,
                .rung = s.level.items[nd],
                .deps_start = deps_start,
                .deps_len = @intCast(ds.len),
                .outs_start = outs_start,
                .outs_len = @intCast(os.len),
                .sync = sync,
            });
        }
        s.summaries[d] = .{ .start = start, .len = @intCast(nodes.items.len) };
    }
    return changed;
}

/// The fixed nodes `nd` reaches, not through another fixed node, ascending
/// and scratch-owned (§14.3 rule 3, amended 2026-11-06): what a use's copy
/// of `nd`'s class flows into. Empty for a fixed `nd`, whose copies are the
/// class itself, and in a module with no fixed class.
fn fixedReached(e: *Effects, nd: u32, scratch: Allocator) Error![]u32 {
    const s = &e.solved;
    if (!s.any_fixed or s.fixed.items[nd]) return scratch.alloc(u32, 0);
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(scratch);
    s.nextEpoch();
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    s.orMask(nd, 1);
    try work.append(scratch, nd);
    while (work.pop()) |x| {
        var at = s.head.items[x];
        while (at != none) : (at = s.next.items[at]) {
            const y = s.find(s.to.items[at]);
            if (s.maskOf(y) != 0) continue;
            s.orMask(y, 1);
            if (s.fixed.items[y]) {
                try out.append(scratch, y);
                continue;
            }
            try work.append(scratch, y);
        }
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return out.toOwnedSlice(scratch);
}

/// Whether node `nd` reaches a demand along the edges, itself included
/// (§15.3): one walk under a fresh epoch.
fn reachesDemand(e: *Effects, nd: u32, scratch: Allocator) Error!bool {
    const s = &e.solved;
    s.nextEpoch();
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    s.orMask(nd, 1);
    try work.append(scratch, nd);
    while (work.pop()) |x| {
        if (s.demanded.items[x]) return true;
        var at = s.head.items[x];
        while (at != none) : (at = s.next.items[at]) {
            const y = s.find(s.to.items[at]);
            if (s.maskOf(y) != 0) continue;
            s.orMask(y, 1);
            try work.append(scratch, y);
        }
    }
    return false;
}

/// For each of `nodes`, the indices of the others that reach it, ascending;
/// and, into `reach` when given, whether each reaches a demand (§15.3) —
/// the same pass, since a node's bits are the nodes that reach it.
fn dependencies(e: *Effects, nodes: []const u32, scratch: Allocator, reach: ?[]bool) Error![][]u32 {
    const s = &e.solved;
    const out = try scratch.alloc([]u32, nodes.len);
    for (out) |*o| o.* = &.{};
    // One class depends on no other: most functions have only their own.
    if (nodes.len < 2) return out;
    var lists = try scratch.alloc(std.ArrayList(u32), nodes.len);
    defer scratch.free(lists);
    for (lists) |*l| l.* = .empty;
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(scratch);
    // The demanded nodes a chunk's walk met.
    var met: std.ArrayList(u32) = .empty;
    defer met.deinit(scratch);
    var chunk: usize = 0;
    while (chunk < nodes.len) : (chunk += 64) {
        const end = @min(nodes.len, chunk + 64);
        // The bits live in a column over the nodes, valid under this pass's
        // epoch: no clearing, and no map keyed by a dense id.
        s.nextEpoch();
        met.clearRetainingCapacity();
        for (nodes[chunk..end], 0..) |nd, b| {
            s.orMask(nd, @as(u64, 1) << @intCast(b));
            try work.append(scratch, nd);
        }
        while (work.pop()) |x| {
            if (reach != null and s.demanded.items[x]) try met.append(scratch, x);
            const bits = s.maskOf(x);
            var at = s.head.items[x];
            while (at != none) : (at = s.next.items[at]) {
                const y = s.find(s.to.items[at]);
                if (s.maskOf(y) | bits == s.maskOf(y)) continue;
                s.orMask(y, bits);
                try work.append(scratch, y);
            }
        }
        for (nodes, 0..) |nd, i| {
            const bits = s.maskOf(nd);
            if (bits == 0) continue;
            for (chunk..end) |j| {
                if (j == i) continue;
                if (bits & (@as(u64, 1) << @intCast(j - chunk)) != 0) try lists[i].append(scratch, @intCast(j));
            }
        }
        if (reach) |out_reach| {
            // A demanded node's bits are the nodes of the chunk that reach
            // it; its bits are final once the walk is done.
            var reaching: u64 = 0;
            for (met.items) |x| reaching |= s.maskOf(x);
            for (chunk..end) |j| {
                if (reaching & (@as(u64, 1) << @intCast(j - chunk)) != 0) out_reach[j] = true;
            }
        }
    }
    for (lists, out) |*l, *o| o.* = try l.toOwnedSlice(scratch);
    return out;
}

/// The distinct nodes of `scheme`'s function types and function-holding
/// applications, its `where` types included, in a depth-first order.
/// The order is the walk's, deterministic and otherwise immaterial: a
/// summary's classes are numbered again by site when published, and named
/// by first print when dumped.
pub fn schemeNodes(e: *Effects, scheme: Var, out: *std.ArrayList(u32)) Error!void {
    const store = e.store;
    const stack = &e.solved.walk;
    stack.clearRetainingCapacity();
    const mark = store.nextMark();
    try stack.append(e.gpa, scheme);
    while (stack.pop()) |next| {
        const r = store.find(next);
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        switch (store.content(r)) {
            .flex, .rigid => |flags| {
                const set = Walk.constraints(flags);
                for (0..set.count(store)) |i| try stack.append(e.gpa, set.at(store, @intCast(i)).fn_var);
                continue;
            },
            else => {},
        }
        if (e.carries(r)) {
            const nd = try e.nodeFor(r);
            if (std.mem.indexOfScalar(u32, out.items, nd) == null) try out.append(e.gpa, nd);
        }
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1) try stack.append(e.gpa, c.v);
    }
}
