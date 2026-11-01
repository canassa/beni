//! L2: stable images (`docs/design/ownership-v2.md` §2.3 *The two pieces
//! that (b) adds, prototyped (4e)*, #1372 F3). A knot that `Shape.map`
//! closes, and the graph that `widen` emits, are interned by their canonical
//! form. A graph that has the form of one made before is moved onto that
//! one, so node-keyed memos and κ entries hit across rounds.
//!
//! **The form.** The graph is its raw nodes (ones `make` did not intern)
//! reachable from its root, at or above the table size `lo` its maker began
//! at. It is minimised by partition refinement: a node's signature is its
//! kind, place and cells (none for a recast or a delta, as `make` keys
//! them), the caller's side word (`fold_cond`), and at each step of its
//! record the class of an internal reference or the id of an external one.
//! The key is the classes' signatures in a depth-first order from the root,
//! each internal reference written as its class number.
//!
//! **The move** σ sends each member to the node of its class in the graph
//! recorded under that key. Its precondition, asserted under
//! `runtime_safety` (`moveHolds`): each member's record with its internal
//! references mapped by σ is its target's record, the side words are equal,
//! neither has a node-keyed fact that is not a function of its record
//! (`sideFact`), and σ is injective on the members. A graph that is not
//! minimal, or that holds a side fact, is never moved. External references
//! are compared by id, so a graph that reaches a node can never have that
//! node's key: a route never meets a moved member and its target both.
//!
//! The functions take the shape table as `anytype` (`*Shape.Table`), so this
//! file sits below `Shape.zig`, which calls it.
//!
//! Obligations kept here: O3 for the moved value (σ keeps every record, so
//! every set reader reads the same), O11 (every record reserved before it is
//! made).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const NodeId = Ids.NodeId;
pub const Account = Ids.Account;
pub const Error = Ids.ChargeError;
const none = Ids.none_int;

/// A node → a word (σ: member → target), over `Ids.FixedDict(1)`.
pub const Redirect = struct {
    d: Ids.FixedDict(1) = .{},

    pub fn deinit(r: *Redirect, gpa: Allocator) void {
        r.d.deinit(gpa);
    }
    pub fn get(r: *const Redirect, k: u32) ?u32 {
        return r.d.get(.{k});
    }
    pub fn contains(r: *const Redirect, k: u32) bool {
        return r.d.get(.{k}) != null;
    }
    pub fn put(r: *Redirect, gpa: Allocator, k: u32, v: u32) Allocator.Error!void {
        (try r.d.getOrPut(gpa, .{k})).value_ptr.* = v;
    }
    pub fn count(r: *const Redirect) u32 {
        return r.d.count();
    }
    /// The `i`th key put, and its word.
    pub fn key(r: *const Redirect, i: u32) u32 {
        return r.d.keys.items[i];
    }
    pub fn value(r: *const Redirect, i: u32) u32 {
        return r.d.values.items[i];
    }
};

/// A word per node the caller keys by node outside the shape table
/// (`fold_cond`), `none` for none; and the nodes no move may target: a
/// widening's source nodes, which `propagate` reads in lockstep with the
/// image and links where the two are one node.
pub const Extra = struct {
    ctx: *anyopaque,
    word: *const fn (ctx: *anyopaque, n: NodeId) u32,
    avoid: ?*const fn (ctx: *anyopaque, n: NodeId) bool = null,
};

fn avoided(extra: ?Extra, x: u32) bool {
    const e = extra orelse return false;
    const f = e.avoid orelse return false;
    return f(e.ctx, .from(x));
}

/// The graphs met, by key, and `map`'s trail of the images it gave.
pub const Store = struct {
    /// Key bytes → the start of its representatives in `reps`, by class number.
    keys: std.StringHashMapUnmanaged(u32) = .empty,
    reps: std.ArrayList(u32) = .empty,
    /// `map`'s `(source, image)` puts, and the trail's length at each
    /// node it entered, so a knot moves the sources it gave an image.
    trail: std.ArrayList([2]u32) = .empty,
    trail_at: std.ArrayList(u32) = .empty,
    /// The cross-check's raw pass: nothing is moved.
    off: bool = false,

    pub fn deinit(s: *Store, gpa: Allocator) void {
        var it = s.keys.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.keys.deinit(gpa);
        s.reps.deinit(gpa);
        s.trail.deinit(gpa);
        s.trail_at.deinit(gpa);
    }

    pub fn clearTrail(s: *Store) void {
        s.trail.clearRetainingCapacity();
        s.trail_at.clearRetainingCapacity();
    }
};

/// A node's cells in its form: none where its parts determine them (a
/// recast, a delta, and a union's, choice's or positions node's, which a
/// reader may fill in later from a lazy record).
fn formCells(d: anytype) u32 {
    return switch (d.kind) {
        .recast, .delta, .@"union", .choice, .positions => none,
        else => d.cells.int(),
    };
}

fn keyedCells(d: anytype) u32 {
    return if (d.kind == .recast or d.kind == .delta) none else d.cells.int();
}

/// Whether `x` is a node `make` did not intern.
fn isRaw(t: anytype, x: u32) bool {
    const n = t.get(.from(x));
    const hit = t.intern.get(.{ @backingInt(n.kind), n.place.int(), keyedCells(n), n.a, n.b }) orelse return true;
    return hit != x;
}

/// A fact the table keys by `x` that its record does not determine: a
/// positions node's *counted* bit, its drops, an eager image other than
/// itself, a view it answers, or its birth.
/// A member must also have no projection origins and no bases, which a
/// move would drop. A target may have them: they accumulate on a shared
/// node as on any node `make` interned, from each use of it.
pub fn sideFact(t: anytype, x: u32, member: bool) bool {
    const n: NodeId = .from(x);
    if (x < t.counted.bit_length and t.counted.isSet(x)) return true;
    if (t.drop_head.get(.{x}) != null or t.answered.get(n) != null or t.born.get(n) != null) return true;
    if (t.memo_eager.get(n)) |e| if (e != n) return true;
    return member and (t.proj_origin.get(.{x}) != null or t.bases.get(.{x}) != null);
}

/// `x`'s references as `(step word or slot, node)` pairs, in record order.
fn refs(t: anytype, gpa: Allocator, x: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const d = t.get(.from(x));
    switch (d.kind) {
        .leaf, .view => {},
        .node => {
            var it = t.overEntries(d.a);
            while (it.next()) |e| try out.appendSlice(gpa, &.{ e.step.word(), e.node.int() });
        },
        .delta => {
            try out.appendSlice(gpa, &.{ none, d.a });
            var it = t.overEntries(d.b);
            while (it.next()) |e| try out.appendSlice(gpa, &.{ e.step.word(), e.node.int() });
        },
        .recast => try out.appendSlice(gpa, &.{ d.b, d.a }),
        .@"union", .choice, .positions => try out.appendSlice(gpa, &.{ 0, d.a, 1, d.b }),
    }
}

fn word(extra: ?Extra, x: u32) u32 {
    return if (extra) |e| e.word(e.ctx, .from(x)) else none;
}

/// A node's own part of a signature: kind, place, keyed cells, side word,
/// and a leaf's or view's other fields.
fn head(t: anytype, gpa: Allocator, x: u32, extra: ?Extra, out: *std.ArrayList(u32)) Allocator.Error!void {
    const d = t.get(.from(x));
    try out.appendSlice(gpa, &.{ @backingInt(d.kind), d.place.int(), formCells(d), word(extra, x) });
    if (d.kind == .leaf or d.kind == .view) try out.appendSlice(gpa, &.{ d.a, d.b });
}

/// The graph from `root` at or above `lo` (a member of `skip` excluded), by
/// its canonical form: σ onto the graph recorded under its key, or null
/// when the form is first met (it is recorded) or is not moved.
pub fn canon(t: anytype, gpa: Allocator, account: *Account, root: NodeId, lo: u32, extra: ?Extra, skip: ?*const Redirect) Error!?Redirect {
    const S = struct {
        fn in(tt: anytype, x: u32, l: u32, sk: ?*const Redirect) bool {
            if (x < l or x >= tt.count() or !isRaw(tt, x)) return false;
            return if (sk) |k| !k.contains(x) else true;
        }
    };
    if (t.stable.off or !S.in(t, root.int(), lo, skip)) return null;
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    var index: Redirect = .{};
    defer index.deinit(gpa);
    var rf: std.ArrayList(u32) = .empty;
    defer rf.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root.int());
    while (stack.pop()) |x| {
        if (index.contains(x)) continue;
        try account.reserve(.inspection, 1);
        if (sideFact(t, x, true)) return null;
        try index.put(gpa, x, @intCast(members.items.len));
        try members.append(gpa, x);
        try refs(t, gpa, x, &rf);
        var i: usize = 0;
        while (i < rf.items.len) : (i += 2) if (S.in(t, rf.items[i + 1], lo, skip) and !index.contains(rf.items[i + 1])) try stack.append(gpa, rf.items[i + 1]);
    }
    const n = members.items.len;
    const cls = try gpa.alloc(u32, n);
    defer gpa.free(cls);
    @memset(cls, 0);
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    var sig: std.ArrayList(u32) = .empty;
    defer sig.deinit(gpa);
    // Moore's refinement: each round splits by (class, own part, the
    // references' classes), until the count of classes stops moving.
    var classes: u32 = 0;
    while (true) {
        var m: std.StringHashMapUnmanaged(u32) = .empty;
        defer {
            var it = m.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            m.deinit(gpa);
        }
        try account.reserve(.inspection, @intCast(n));
        for (members.items, 0..) |x, i| {
            sig.clearRetainingCapacity();
            try sig.append(gpa, cls[i]);
            try head(t, gpa, x, extra, &sig);
            try refs(t, gpa, x, &rf);
            var j: usize = 0;
            while (j < rf.items.len) : (j += 2) {
                try sig.append(gpa, rf.items[j]);
                if (index.get(rf.items[j + 1])) |ri| try sig.appendSlice(gpa, &.{ 1, cls[ri] }) else try sig.appendSlice(gpa, &.{ 0, rf.items[j + 1] });
            }
            const got = try m.getOrPut(gpa, std.mem.sliceAsBytes(sig.items));
            if (!got.found_existing) {
                got.key_ptr.* = try gpa.dupe(u8, std.mem.sliceAsBytes(sig.items));
                got.value_ptr.* = m.count() - 1;
            }
            next[i] = got.value_ptr.*;
        }
        @memcpy(cls, next);
        if (m.count() == classes) break;
        classes = m.count();
    }
    // A graph with two members in one class is recorded under no key and
    // never moved: σ stays injective on the members.
    if (classes < n) return null;
    // The classes numbered depth-first from the root; the key in that order.
    const number = try gpa.alloc(u32, n);
    defer gpa.free(number);
    @memset(number, none);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try stack.append(gpa, 0);
    while (stack.pop()) |i| {
        if (number[i] != none) continue;
        number[i] = @intCast(order.items.len);
        try order.append(gpa, i);
        try refs(t, gpa, members.items[i], &rf);
        var j = rf.items.len;
        while (j >= 2) {
            j -= 2;
            if (index.get(rf.items[j + 1])) |ri| if (number[ri] == none) try stack.append(gpa, ri);
        }
    }
    var key: std.ArrayList(u32) = .empty;
    defer key.deinit(gpa);
    try account.reserve(.inspection, @intCast(n));
    for (order.items) |i| {
        try key.append(gpa, none - 1);
        try head(t, gpa, members.items[i], extra, &key);
        try refs(t, gpa, members.items[i], &rf);
        var j: usize = 0;
        while (j < rf.items.len) : (j += 2) {
            try key.append(gpa, rf.items[j]);
            if (index.get(rf.items[j + 1])) |ri| try key.appendSlice(gpa, &.{ 1, number[ri] }) else try key.appendSlice(gpa, &.{ 0, rf.items[j + 1] });
        }
    }
    const bytes = std.mem.sliceAsBytes(key.items);
    if (t.stable.keys.get(bytes)) |start| {
        // A target that gained a side fact since it was recorded is not
        // a target any more: the move would give the image that fact.
        for (t.stable.reps.items[start..][0..n]) |to| if (sideFact(t, to, false) or avoided(extra, to)) return null;
        var redir: Redirect = .{};
        errdefer redir.deinit(gpa);
        for (members.items, 0..) |x, i| try redir.put(gpa, x, t.stable.reps.items[start + number[i]]);
        if (std.debug.runtime_safety and !try moveHolds(t, gpa, members.items, &redir, extra)) std.debug.panic("ownership v2: a stable image's move does not keep its records (§2.3, 4e)", .{});
        return redir;
    }
    try account.reserve(.memo, @intCast(n));
    const start: u32 = @intCast(t.stable.reps.items.len);
    for (order.items) |i| try t.stable.reps.append(gpa, members.items[i]);
    try t.stable.keys.put(gpa, try gpa.dupe(u8, bytes), start);
    return null;
}

/// σ's precondition, and the shape half of the check that σ is a
/// bisimulation of the raw graph onto the moved one: each member and its
/// target have one kind, place and form cells, equal stored cells where
/// both are set, one side word (`fold_cond`), no side fact on either, and
/// references that pair under σ (an external one as it is); σ is
/// injective on `members`.
pub fn moveHolds(t: anytype, gpa: Allocator, members: []const u32, redir: *const Redirect, extra: ?Extra) Allocator.Error!bool {
    var seen: Redirect = .{};
    defer seen.deinit(gpa);
    var a: std.ArrayList(u32) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u32) = .empty;
    defer b.deinit(gpa);
    var ra: std.ArrayList(u32) = .empty;
    defer ra.deinit(gpa);
    var rb: std.ArrayList(u32) = .empty;
    defer rb.deinit(gpa);
    for (members) |x| {
        const to = redir.get(x) orelse return false;
        if (seen.contains(to)) return false;
        try seen.put(gpa, to, 1);
        if (sideFact(t, x, true) or sideFact(t, to, false) or word(extra, x) != word(extra, to)) return false;
        // The stored cells, as well as the form's: a lazy record fills them
        // in later from its sides, which the form already compares.
        const lazy = @TypeOf(t.*).lazy_cells;
        const cx = t.get(.from(x)).cells;
        const ct = t.get(.from(to)).cells;
        if (cx != lazy and ct != lazy and cx != ct) return false;
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        try head(t, gpa, x, extra, &a);
        try head(t, gpa, to, extra, &b);
        try refs(t, gpa, x, &ra);
        try refs(t, gpa, to, &rb);
        if (ra.items.len != rb.items.len or !std.mem.eql(u32, a.items, b.items)) return false;
        var j: usize = 0;
        while (j < ra.items.len) : (j += 2) {
            if (ra.items[j] != rb.items[j]) return false;
            const mapped = redir.get(ra.items[j + 1]) orelse ra.items[j + 1];
            if (mapped != rb.items[j + 1]) return false;
        }
    }
    return true;
}

/// `map`'s knot closed at `out` (entered at `entry`): moved onto an equal
/// knot made before, and every source the walk gave one of its images
/// takes that image's target (`memo_map`); two sources given one image
/// make `map_shared`.
pub fn mapKnot(t: anytype, gpa: Allocator, account: *Account, out: NodeId, entry: u32) Error!void {
    var redir = (try canon(t, gpa, account, out, out.int(), null, null)) orelse return;
    defer redir.deinit(gpa);
    const from = t.stable.trail_at.items[entry];
    for (t.stable.trail.items[from..]) |e| {
        const to = redir.get(e[1]) orelse continue;
        try account.reserve(.memo, 1);
        try t.memo_map.put(gpa, .from(e[0]), .from(to));

        if (t.map_src.contains(.from(e[0])) and (try t.map_images.getOrPut(gpa, .from(to))).found_existing) t.map_shared = true;
    }
}

/// `widen`'s emitted graph from `root` (nodes at or above `lo`), each
/// strongly connected component bottom up: its references to components
/// below moved to their targets, and a knot moved by `canon`. σ of every
/// member that moved.
pub fn widened(t: anytype, gpa: Allocator, account: *Account, root: NodeId, lo: u32, extra: ?Extra) Error!Redirect {
    var redir: Redirect = .{};
    errdefer redir.deinit(gpa);
    if (t.stable.off or root.int() < lo or root.int() >= t.count() or !isRaw(t, root.int())) return redir;
    var done: Redirect = .{};
    defer done.deinit(gpa);
    var rf: std.ArrayList(u32) = .empty;
    defer rf.deinit(gpa);
    const In = struct {
        fn f(tt: anytype, x: u32, l: u32) bool {
            return x >= l and x < tt.count() and isRaw(tt, x);
        }
    };
    // Tarjan on an explicit stack: (index, low) per node, each frame its
    // node and its next reference.
    var idx: Redirect = .{};
    defer idx.deinit(gpa);
    var low: Redirect = .{};
    defer low.deinit(gpa);
    var on: Redirect = .{};
    defer on.deinit(gpa);
    var st: std.ArrayList(u32) = .empty;
    defer st.deinit(gpa);
    const Frame = struct { v: u32, kids: u32, len: u32, at: u32, self: bool };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var kids: std.ArrayList(u32) = .empty;
    defer kids.deinit(gpa);
    var comp: std.ArrayList(u32) = .empty;
    defer comp.deinit(gpa);
    var counter: u32 = 0;
    const enter = struct {
        fn f(tt: anytype, g: Allocator, acc: *Account, v: u32, l: u32, ix: *Redirect, lw: *Redirect, o: *Redirect, s: *std.ArrayList(u32), fr: *std.ArrayList(Frame), ks: *std.ArrayList(u32), c: *u32, r: *std.ArrayList(u32)) Error!void {
            try acc.reserve(.inspection, 1);
            try ix.put(g, v, c.*);
            try lw.put(g, v, c.*);
            c.* += 1;
            try s.append(g, v);
            try o.put(g, v, 1);
            try refs(tt, g, v, r);
            const first: u32 = @intCast(ks.items.len);
            var self = false;
            var j: usize = 0;
            while (j < r.items.len) : (j += 2) if (In.f(tt, r.items[j + 1], l)) {
                if (r.items[j + 1] == v) self = true;
                try ks.append(g, r.items[j + 1]);
            };
            try fr.append(g, .{ .v = v, .kids = first, .len = @intCast(ks.items.len - first), .at = 0, .self = self });
        }
    }.f;
    try enter(t, gpa, account, root.int(), lo, &idx, &low, &on, &st, &frames, &kids, &counter, &rf);
    while (frames.items.len > 0) {
        const top = &frames.items[frames.items.len - 1];
        if (top.at < top.len) {
            const w = kids.items[top.kids + top.at];
            top.at += 1;
            if (!idx.contains(w)) {
                try enter(t, gpa, account, w, lo, &idx, &low, &on, &st, &frames, &kids, &counter, &rf);
            } else if (on.get(w) == 1) {
                try low.put(gpa, top.v, @min(low.get(top.v).?, idx.get(w).?));
            }
            continue;
        }
        const fin = frames.pop().?;
        const v_low = low.get(fin.v).?;
        if (frames.items.len > 0) {
            const up = frames.items[frames.items.len - 1].v;
            try low.put(gpa, up, @min(low.get(up).?, v_low));
        }
        if (idx.get(fin.v).? != v_low) continue;
        comp.clearRetainingCapacity();
        while (st.pop()) |x| {
            try on.put(gpa, x, 0);
            try comp.append(gpa, x);
            if (x == fin.v) break;
        }
        // A node on no cycle stays as `emit` made it: interned, it can be one
        // node with a part of another value that a later reader compares by
        // id (§2.3, 4e step 5, `PushedTwiceLevels`).
        if (comp.items.len == 1 and !fin.self) {
            try done.put(gpa, fin.v, 1);
            continue;
        }
        // Only the root's knot moves: a knot below has raw parents, and
        // moving it would mean rewriting them, which every node-keyed memo
        // (`proj`'s first) may have read already. Recorded all the same.
        if (try canon(t, gpa, account, .from(fin.v), lo, extra, &done)) |r0| {
            var r = r0;
            defer r.deinit(gpa);
            if (r.contains(root.int())) for (0..r.count()) |i| try redir.put(gpa, r.key(@intCast(i)), r.value(@intCast(i)));
        }
        for (comp.items) |x| try done.put(gpa, x, 1);
    }
    return redir;
}

/// Every node the records from `root` reach, into `out` (the check's
/// "inside the value").
pub fn reachable(t: anytype, gpa: Allocator, root: NodeId, out: *Redirect) Allocator.Error!void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var rf: std.ArrayList(u32) = .empty;
    defer rf.deinit(gpa);
    try stack.append(gpa, root.int());
    while (stack.pop()) |x| {
        if (out.contains(x)) continue;
        try out.put(gpa, x, 1);
        try refs(t, gpa, x, &rf);
        var j: usize = 0;
        while (j < rf.items.len) : (j += 2) try stack.append(gpa, rf.items[j + 1]);
    }
}
