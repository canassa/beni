//! L3: a read's result slots as a column (`docs/design/ownership-v2.md`
//! §2.10 *Read-off*, amended 2026-11-03 for #1714). A read is the read-off's
//! value below `from` described at result slot `q`, or a call root's
//! callee entries read at the root's path (`Relation.Eval.feedBelow`). Its
//! column has an entry per slot it has met, in the slots' order, each made
//! once from its nearest ancestor in the column: the ancestor's result
//! slots the remaining steps on (`Slots.replay`, one record a step).
//!
//! Obligations kept here: none of §2.14's directly. An entry is the
//! result slots its steps replayed from the read's root reach, by
//! `replay`'s own steps (a replay of a run is its steps one at a time).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");
const Slots = @import("Slots.zig");
const Replay = @import("Replay.zig");

const Error = Ids.ChargeError;
const PathId = Ids.PathId;

/// What an entry is made with.
pub const Env = struct { gpa: Allocator, account: *Ids.Account, places: *Place.Table, slots: *Slots.Table };

pub const Column = struct {
    /// The slots met (paths, or `Slots.Rel`s for a call root), sorted.
    domain: std.ArrayList(u32) = .empty,
    /// Per slot: whether its steps from the read's root are its own.
    textual: std.ArrayList(bool) = .empty,
    /// Per slot: its result slots, a run of `slots` (`[start, len]`).
    runs: std.ArrayList([2]u32) = .empty,
    slots: std.ArrayList(u32) = .empty,

    pub fn deinit(c: *Column, gpa: Allocator) void {
        c.domain.deinit(gpa);
        c.textual.deinit(gpa);
        c.runs.deinit(gpa);
        c.slots.deinit(gpa);
    }

    fn find(c: *const Column, x: u32) ?usize {
        return std.sort.binarySearch(u32, c.domain.items, x, order);
    }

    pub fn at(c: *const Column, x: u32) ?[]const u32 {
        const run = c.runs.items[c.find(x) orelse return null];
        return c.slots.items[run[0]..][0..run[1]];
    }

    /// Its slot `x`'s entry, the result slots `c.slots` has from `start` on.
    fn put(c: *Column, gpa: Allocator, x: u32, textual: bool, start: usize) Error!void {
        const pos = std.sort.lowerBound(u32, c.domain.items, x, order);
        try c.domain.insert(gpa, pos, x);
        try c.textual.insert(gpa, pos, textual);
        try c.runs.insert(gpa, pos, .{ @intCast(start), @intCast(c.slots.items.len - start) });
    }
};

/// The columns of a kind of read, each by its key.
pub fn Reads(comptime k: usize) type {
    return struct {
        of: Ids.FixedDict(k) = .{},
        cols: std.ArrayList(Column) = .empty,

        pub fn deinit(r: *@This(), gpa: Allocator) void {
            r.of.deinit(gpa);
            for (r.cols.items) |*c| c.deinit(gpa);
            r.cols.deinit(gpa);
        }

        /// The column of read `key`, empty the first time.
        pub fn col(r: *@This(), gpa: Allocator, key: [k]u32) Error!u32 {
            const got = try r.of.getOrPut(gpa, key);
            if (got.found_existing) return got.value_ptr.*;
            got.value_ptr.* = @intCast(r.cols.items.len);
            try r.cols.append(gpa, .{});
            return got.value_ptr.*;
        }
    };
}

fn order(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// The entry of `slot`, a path below `from` read at `q` (none when it has
/// one). A slot whose parent chain meets `from` is its nearest such
/// ancestor's entry (`q` for `from`) the remaining steps on; below `q =
/// from` it is the slot itself (§2.1, *one position, one name*), one
/// record. Any other slot is replayed from `q` (`replay`).
pub fn addPath(env: Env, c: *Column, from: PathId, q: PathId, slot: u32) Error!void {
    if (c.find(slot) != null) return;
    const start = c.slots.items.len;
    var steps: std.ArrayList(u32) = .empty;
    defer steps.deinit(env.gpa);
    var base: std.ArrayList(u32) = .empty;
    defer base.deinit(env.gpa);
    var p: PathId = .from(slot);
    // Below a `from` inside a level a route around the cycle meets a slot again (`routes`).
    const textual = if (from != q and env.places.paths.col.info[from.int()].levels) false else while (true) {
        if (p == from) {
            try base.append(env.gpa, q.int());
            break true;
        }
        if (p.int() != slot) if (c.find(p.int())) |i| {
            if (!c.textual.items[i]) break false;
            const run = c.runs.items[i];
            try base.appendSlice(env.gpa, c.slots.items[run[0]..][0..run[1]]);
            break true;
        };
        const up = env.places.pathParent(p);
        if (up == .none) break false;
        try steps.append(env.gpa, env.places.pathStep(p).word());
        p = up;
    };
    if (!textual) {
        try replay(env, from, .from(slot), q, &c.slots);
    } else if (from == q) {
        try env.account.reserve(.memo, 1);
        try c.slots.append(env.gpa, slot);
    } else {
        std.mem.reverse(u32, steps.items);
        try stepOn(env, &base, steps.items);
        try c.slots.appendSlice(env.gpa, base.items);
    }
    try c.put(env.gpa, slot, textual, start);
}

/// The entry of a callee's slot `rel` read at a call root's `path` (none
/// when it has one): its steps' longest prefix in the column, the rest of
/// them on; with none, all of them from `path`.
pub fn addRel(env: Env, c: *Column, path: PathId, rel: Slots.Rel) Error!void {
    if (c.find(rel) != null) return;
    const start = c.slots.items.len;
    const rw = env.slots.relWords(rel);
    var base: std.ArrayList(u32) = .empty;
    defer base.deinit(env.gpa);
    var n: usize = rw.len;
    while (n > 0) : (n -= 1) {
        if (n == rw.len) continue;
        const i = c.find(env.slots.rels.find(rw[0..n]) orelse continue) orelse continue;
        const run = c.runs.items[i];
        try base.appendSlice(env.gpa, c.slots.items[run[0]..][0..run[1]]);
        break;
    }
    if (n == 0) try base.append(env.gpa, path.int());
    try stepOn(env, &base, rw[n..]);
    try c.slots.appendSlice(env.gpa, base.items);
    try c.put(env.gpa, rel, true, start);
}

/// `base` the steps `words` on, as `Slots.replay` takes them: each step
/// from every slot reached so far, sorted and distinct.
fn stepOn(env: Env, base: *std.ArrayList(u32), words: []const u32) Error!void {
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(env.gpa);
    for (words) |w| {
        if (base.items.len == 0) return;
        next.clearRetainingCapacity();
        for (base.items) |x| try Replay.replay(env.gpa, env.account, env.places, .from(x), &.{w}, &next);
        std.mem.sort(u32, next.items, {}, std.sort.asc(u32));
        base.clearRetainingCapacity();
        for (next.items) |x| if (base.items.len == 0 or base.items[base.items.len - 1] != x) try base.append(env.gpa, x);
    }
}

/// `slot`'s result slots below `q`, its steps below `from` replayed
/// (`Slots.replay`; from `q` itself where `slot` is not below `from`),
/// appended to `out`.
pub fn replay(env: Env, from: PathId, slot: PathId, q: PathId, out: *std.ArrayList(u32)) Error!void {
    const start = out.items.len;
    // Below `q` itself, a slot named by `q`'s steps and its own is that
    // slot (§2.1, *one position, one name*): its steps replayed are its name.
    if (from == q) {
        const qw = env.slots.relWords(try env.slots.relOf(env.gpa, env.account, env.places, q));
        const sw = env.slots.relWords(try env.slots.relOf(env.gpa, env.account, env.places, slot));
        if (SlotWords.startsAt(sw, qw)) try out.append(env.gpa, slot.int());
    }
    if (out.items.len == start and !try routes(env, from, slot, q, out)) try out.append(env.gpa, q.int());
}

/// `slot` below `from` at `q` by every route to it (§2.1, *Every name*: a
/// slot in a fold above `from` is every level there), each result slot
/// once, appended to `out`; false where no route reaches it.
pub fn routes(env: Env, from: PathId, slot: PathId, q: PathId, out: *std.ArrayList(u32)) Error!bool {
    const start = out.items.len;
    const rels = try env.slots.relsBelow(env.gpa, env.account, env.places, from, slot, env.gpa);
    defer env.gpa.free(rels);
    for (rels) |rel| try Replay.replay(env.gpa, env.account, env.places, q, env.slots.relWords(rel), out);
    std.mem.sort(u32, out.items[start..], {}, std.sort.asc(u32));
    var n = start;
    for (out.items[start..]) |x| if (n == start or out.items[n - 1] != x) {
        out.items[n] = x;
        n += 1;
    };
    out.shrinkRetainingCapacity(n);
    return rels.len != 0;
}
