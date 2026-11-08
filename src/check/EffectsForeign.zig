//! A `foreign`'s summary (transparent-effects-proposal.md §14.3 rule 6,
//! §15.2): split from `Effects.zig` to keep that file under §19.1's 1 500
//! lines (checker-v2.md), as `EffectsBlock.zig` was.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Effects = @import("Effects.zig");
const Erasure = @import("Erasure.zig");
const Walk = @import("Walk.zig");

const Var = Effects.Var;
const Rung = Effects.Rung;
const Error = Effects.Error;
const none = Effects.none;

/// §14.3 rule 6: a `foreign`'s own arrow has its rung, and so does every
/// function type in a positive position of its signature; its `where` types
/// flow into its own arrow; everything else is independent.
pub fn summary(e: *Effects, decl: u32, scheme: Var, rung: Rung, markup: bool, scratch: Allocator) Error!void {
    const s = &e.solved;
    const store = e.store;
    const own_var, _ = store.resolved(scheme);
    const is_function = switch (store.content(own_var)) {
        .structure => |st| st == .func,
        else => false,
    };
    var nodes: std.ArrayList(u32) = .empty;
    defer nodes.deinit(scratch);
    var positive: std.ArrayList(bool) = .empty;
    defer positive.deinit(scratch);
    var evidence: std.ArrayList(bool) = .empty;
    defer evidence.deinit(scratch);
    var sync: std.ArrayList(bool) = .empty;
    defer sync.deinit(scratch);
    // The function types P2 found marked `sync` in this declaration (§15.2 item 1).
    var marked: std.ArrayList(u32) = .empty;
    defer marked.deinit(scratch);
    for (e.foreign_syncs.items) |f| if (f.decl == decl) try marked.append(scratch, try e.nodeFor(f.v));
    var realm_calls: std.ArrayList(@import("Realms.zig").ForeignCall) = .empty;
    defer realm_calls.deinit(scratch);
    const Item = struct { v: Var, positive: bool, evidence: bool, where_root: bool = false, realm_caller: u32 = none };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, .{ .v = scheme, .positive = true, .evidence = false });
    const mark = store.nextMark();
    while (stack.pop()) |item| {
        const r = store.find(item.v);
        const unknown = @import("Realms.zig").unknown(store, r);
        if (unknown and store.mark(r) == mark and !item.positive and !item.evidence and item.realm_caller != none)
            try realm_calls.append(scratch, .{ .caller = item.realm_caller, .callback = try e.nodeFor(r) });
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        switch (store.content(r)) {
            .flex, .rigid => |flags| {
                const set = Walk.constraints(flags);
                for (0..set.count(store)) |i| try stack.append(scratch, .{ .v = set.at(store, @intCast(i)).fn_var, .positive = false, .evidence = true, .where_root = true });
            },
            else => {},
        }
        var realm_caller = item.realm_caller;
        if (e.realmCarrier(r)) {
            const nd = try e.nodeFor(r);
            if (item.positive and switch (store.content(r)) {
                .structure => |st| st == .func,
                else => false,
            }) {
                realm_caller = nd;
            } else if (!item.positive and !item.evidence and realm_caller != none) {
                try realm_calls.append(scratch, .{ .caller = realm_caller, .callback = nd });
            }
            if (std.mem.indexOfScalar(u32, nodes.items, nd) == null) {
                try nodes.append(scratch, nd);
                try positive.append(scratch, item.positive and !unknown);
                try evidence.append(scratch, item.evidence);
                // `sync` (§15.2): a function type the platform marked; the
                // evidence the sibling calls from JavaScript (item 2); a
                // markup primitive's function parameter, which the page
                // calls (item 3).
                const is_func = switch (store.content(r)) {
                    .structure => |st| st == .func,
                    else => false,
                };
                try sync.append(scratch, std.mem.indexOfScalar(u32, marked.items, nd) != null or item.where_root or (markup and is_func and !item.positive and !item.evidence));
            }
        }
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1) {
            // A parameter flips the position; everything else keeps it.
            const flips = c.kind == .param;
            try stack.append(scratch, .{ .v = c.v, .positive = if (flips) !item.positive else item.positive, .evidence = item.evidence, .realm_caller = realm_caller });
        }
    }
    const own = if (is_function) try e.nodeFor(own_var) else none;
    const erased = try Erasure.foreignBits(e, scheme, scratch);
    defer scratch.free(erased);
    const start: u32 = @intCast(s.classes.items.len);
    for (nodes.items, positive.items, evidence.items, sync.items) |nd, pos, _, is_sync| {
        const deps_start: u32 = @intCast(s.deps.items.len);
        if (nd == own) {
            for (nodes.items, evidence.items, 0..) |other, ev, j| {
                if (other == own) continue;
                if (ev) {
                    try s.deps.append(e.gpa, @intCast(j));
                }
            }
        }
        try @import("Realms.zig").foreignDependencies(e, nodes.items, realm_calls.items, nd);
        const class_rung: Rung = if (pos and !isEvidence(nodes.items, evidence.items, nd)) rung else .pure;
        try s.classes.append(e.gpa, .{
            .node = nd,
            .rung = class_rung,
            .realms = e.realmOf(nd),
            .deps_start = deps_start,
            .deps_len = @intCast(s.deps.items.len - deps_start),
            .sync = is_sync and nd != own,
            .erased = Erasure.bitsOf(erased, nd),
        });
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(scratch);
        try e.raise(nd, class_rung, &work, scratch);
        try e.propagate(&work, scratch);
    }
    s.summaries[decl] = .{ .start = start, .len = @intCast(nodes.items.len) };
}

fn isEvidence(nodes: []const u32, evidence: []const bool, nd: u32) bool {
    for (nodes, evidence) |x, ev| if (x == nd) return ev;
    return false;
}
