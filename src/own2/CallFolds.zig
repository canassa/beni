//! L6: what a callee's open arrival says at a caller's folds that the callee's own place graph
//! has not (`docs/design/ownership-v2.md` §2.1, *A fold the caller's instance adds*, #2223): a
//! type variable's slot has no step below it in the callee, but at a caller's instance a walk
//! below it can return to a place above it and fold there, out of the entry's words. The caller
//! says the arrival at each such fold, whole (§2.1, *An arrival's level*).
//!
//! Obligations kept here: O6 (`⟲` covers every level of a result, at a caller's instance too).

const std = @import("std");
const Ids = @import("Ids.zig");
const Replay = @import("Replay.zig");
const SlotWords = @import("SlotWords.zig");
const Trees = @import("Trees.zig");
const Place = @import("Place.zig");
const LevelTargets = @import("LevelTargets.zig");

const Error = Ids.ChargeError;
const Arrival = Trees.Arrival;
const none: u32 = Ids.none_int;

/// An arrival said at a caller's fold: every caller slot at or below `words` reads all of it.
pub const Said = struct { words: []const u32, a: Arrival };

/// Per `(call, which)`: the call's folds (`Said`s in the evaluation's arena, so a slice stays put).
pub const Memo = struct {
    index: Ids.FixedDict(2) = .{},
    lists: std.ArrayList([]const Said) = .empty,
    /// Per place: 2 when a place with a middle is reachable from it, 1 when none is.
    reach: Ids.FixedDict(1) = .{},

    pub fn deinit(m: *Memo, g: std.mem.Allocator) void {
        m.index.deinit(g);
        m.lists.deinit(g);
        m.reach.deinit(g);
    }
};

/// Whether a place on a cycle with a middle is reachable from place `p`: else no walk below a
/// slot at `p` folds above it, and no tree there says anything at a fold.
fn reachesMiddle(e: anytype, p: Ids.PlaceId) Error!bool {
    const m = &e.call_folds;
    if (m.reach.get(.{p.int()})) |v| return v == 2;
    const pl = e.places();
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(e.gpa());
    var stack: std.ArrayList(Ids.PlaceId) = .empty;
    defer stack.deinit(e.gpa());
    try stack.append(e.gpa(), p);
    const found = while (stack.pop()) |x| {
        if ((try seen.getOrPut(e.gpa(), .{x.int()})).found_existing) continue;
        try e.charge(.path, 1);
        if (LevelTargets.hasMiddle(pl, x)) break true;
        try stack.appendSlice(e.gpa(), pl.steps(x).children);
    } else false;
    try m.reach.put(e.gpa(), .{p.int()}, if (found) 2 else 1);
    return found;
}

/// The folds of call `call`'s tree `which` (`none`: its result; else a supply), made once.
pub fn of(e: anytype, call: u32, which: u32) Error![]const Said {
    const m = &e.call_folds;
    if (m.index.get(.{ call, which })) |i| return m.lists.items[i];
    const c = e.contractOf(call) orelse return &.{};
    const root = e.resRoot(c, which);
    const rp = e.f.roots.items[if (which == none) e.f.calls.items[call].root else e.f.supplies.items[which].root].path;
    var out: std.ArrayList(Said) = .empty;
    var w: Walk = .{ .root = root, .rp = rp, .out = &out };
    defer w.words.deinit(e.gpa());
    if (root != 0 and !@import("Mutate.zig").on(.caller_folds_off)) try walk(e, &w, root, e.places().pathPlace(rp), true);
    try m.index.put(e.gpa(), .{ call, which }, @intCast(m.lists.items.len));
    try m.lists.append(e.gpa(), out.items);
    return out.items;
}

const Walk = struct { root: Trees.Node, rp: Ids.PathId, words: std.ArrayList(u32) = .empty, out: *std.ArrayList(Said) };

/// Node `n` at caller place `at` and below it, charged a node a visit; no fold is below a place
/// that reaches no middle. `prune`: `at` is the node's own (a row's step keeps its parent's).
fn walk(e: anytype, w: *Walk, n: Trees.Node, at: Ids.PlaceId, prune: bool) Error!void {
    try e.charge(.inspection, 1);
    const pl = e.places();
    const t = &e.contracts.trees;
    if (prune and !try reachesMiddle(e, at)) return;
    if (t.open(n).len != 0 and (!prune or LevelTargets.hasMiddle(pl, at))) try sayOpen(e, w, t.open(n));
    for (t.kids(n)) |k| {
        try w.words.append(e.gpa(), k[0]);
        defer _ = w.words.pop();
        const step = Place.Step.fromWord(k[0]);
        const c = if (step.isRow()) null else pl.child(at, step);
        try walk(e, w, k[1], c orelse at, prune and c != null);
    }
}

/// Open arrivals `as` of the node at `w.words`, at each fold above it a walk below it reaches.
fn sayOpen(e: anytype, w: *Walk, as: []const Arrival) Error!void {
    const g = e.gpa();
    const pl = e.places();
    var qs: std.ArrayList(u32) = .empty;
    defer qs.deinit(g);
    try Replay.replay(g, e.account(), pl, w.rp, w.words.items, &qs);
    var ts: std.ArrayList(Ids.PathId) = .empty; // the arena's
    for (qs.items) |q| if (LevelTargets.hasMiddle(pl, pl.pathPlace(.from(q)))) {
        ts.clearRetainingCapacity();
        try LevelTargets.of(e.f, g, e.arena, .from(q), &ts);
        // A fold below the slot is read through the entry's node, by the words, when the
        // caller names the slot by the entry's words; else the slot itself is a fold to say.
        const own = SlotWords.same(e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), pl, .from(q))), w.words.items);
        if (!own) try ts.append(e.arena, .from(q));
        for (ts.items) |t| if (!LevelTargets.coveredBy(pl, ts.items, t) and !(own and pl.isPrefix(.from(q), t))) {
            const tw = try e.arena.dupe(u32, e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), pl, t)));
            for (as) |a| if (!try saidAt(e, w.root, tw, a)) {
                var x = a;
                x.deep = true;
                try w.out.append(e.arena, .{ .words = tw, .a = x });
            };
        };
    };
}

/// Whether the callee says `a` at fold words `tw` itself (`LevelWide`, its own graph's fold):
/// at `tw` or above it, as it is or as the parameter read at that slot's own words.
fn saidAt(e: anytype, root: Trees.Node, tw: []const u32, a: Arrival) Error!bool {
    var hs: std.ArrayList(Trees.Hit) = .empty;
    defer hs.deinit(e.gpa());
    try e.hitsAt(root, tw, &hs);
    for (hs.items) |h| if (h.open) for (h.arrivals) |b| if (b.eql(a) or (b.kind == a.kind and b.j == a.j and b.kind != .fresh and
        b.slot == try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), tw[0..h.depth]))) return true;
    return false;
}

/// What call `call`'s tree `which` (contract `c`) says at caller slot `words`: its walk
/// (`hitsAt`), then each fold at or above the slot, all of it, at no suffix.
pub fn hits(e: anytype, call: u32, c: u32, which: u32, words: []const u32, out: *std.ArrayList(Trees.Hit)) Error!void {
    try e.hitsAt(e.resRoot(c, which), words, out);
    for (try of(e, call, which)) |*s| if (SlotWords.startsAt(words, s.words))
        try out.append(e.gpa(), .{ .depth = @intCast(words.len), .open = false, .arrivals = @as(*const [1]Arrival, &s.a) });
}

/// The folds at and below prefix `pw` for below-key `ki`, each read whole at the slots it covers.
pub fn below(e: anytype, ki: u32, call: u32, which: u32, pw: []const u32) Error!void {
    for (try of(e, call, which)) |s| {
        if (SlotWords.startsAt(pw, s.words)) {
            try e.feedBelow(ki, try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), pw), true, s.a, false);
        } else if (SlotWords.startsAt(s.words, pw)) try e.feedBelow(ki, try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), s.words), true, s.a, true);
    }
}
