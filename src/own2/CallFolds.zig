//! L6: what a callee's open arrival says at the caller's folds above it, which
//! the callee's own place graph does not have (`docs/design/ownership-v2.md`
//! §2.1, *A level read on a built value*, #2223). `hg : G a → Maybe (G a)` says
//! `π1#1.0#0.0*` open at `#0.0#1.0#0.0`, a type variable's slot: below it the
//! callee has no step, so `LevelWide` says it at no fold. At a caller of
//! `G R`, `type R = RL (List Int) | RW (G R)`, a walk below that slot returns
//! to `G R` and folds above it, onto `#Just.0#GP.0⟲`, whose words do not
//! start with the entry's: `Forest.atSlot` met no kid there, and the read said
//! fresh. So the caller says it at each such fold, read whole there: its
//! level below the fold is not known (§2.1, *An arrival's level*).
//!
//! Obligations kept here: O6 (`⟲` covers every level of a result, at a
//! caller's instance too).

const std = @import("std");
const Ids = @import("Ids.zig");
const Replay = @import("Replay.zig");
const SlotWords = @import("SlotWords.zig");
const Trees = @import("Trees.zig");
const Forest = @import("Forest.zig");
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
    const g = e.gpa();
    const pl = e.places();
    const rp = e.f.roots.items[if (which == none) e.f.calls.items[call].root else e.f.supplies.items[which].root].path;
    var out: std.ArrayList(Said) = .empty;
    if (root != 0 and !@import("Mutate.zig").on(.caller_folds_off) and try reachesMiddle(e, pl.pathPlace(rp))) {
        var es: Forest.Entries = .{};
        defer es.deinit(g);
        try e.charge(.inspection, e.contracts.trees.count(root));
        try es.of(&e.contracts.trees, g, pl, root, &.{});
        var qs: std.ArrayList(u32) = .empty;
        defer qs.deinit(g);
        var ts: std.ArrayList(Ids.PathId) = .empty; // the arena's
        for (es.items.items) |x| if (x.open) {
            qs.clearRetainingCapacity();
            try Replay.replay(g, e.account(), pl, rp, es.wordsOf(x), &qs);
            for (qs.items) |q| {
                if (!LevelTargets.hasMiddle(pl, pl.pathPlace(.from(q)))) continue;
                ts.clearRetainingCapacity();
                try LevelTargets.of(e.f, g, e.arena, .from(q), &ts);
                for (ts.items) |t| if (!LevelTargets.coveredBy(pl, ts.items, t)) {
                    const tw = try e.arena.dupe(u32, e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), pl, t)));
                    for (x.arrivals) |a| if (!try saidAt(e, root, tw, a)) {
                        var w = a;
                        w.deep = true;
                        try out.append(e.arena, .{ .words = tw, .a = w });
                    };
                };
            }
        };
    }
    try m.index.put(g, .{ call, which }, @intCast(m.lists.items.len));
    try m.lists.append(g, out.items);
    return out.items;
}

/// Whether the callee says `a` at fold words `tw` itself (`LevelWide`, its own graph's fold):
/// at `tw` or above it, as it is or as the parameter read at that slot's own words.
fn saidAt(e: anytype, root: Trees.Node, tw: []const u32, a: Arrival) Error!bool {
    var hs: std.ArrayList(Trees.Hit) = .empty;
    defer hs.deinit(e.gpa());
    try e.hitsAt(root, tw, &hs);
    for (hs.items) |h| if (h.open) for (h.arrivals) |b| {
        if (b.eql(a)) return true;
        if (b.kind == a.kind and b.j == a.j and b.kind != .fresh and b.slot == try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), tw[0..h.depth])) return true;
    };
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
