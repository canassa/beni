//! L6: a reference read by steps, split from `Relation` (`Eval.project`'s
//! reference, `docs/design/ownership-v2.md` §2.3.3), and a `⟲` read through it
//! by every route to its next levels (§2.1, *A level read on a built value*).
//!
//! Obligations kept here: O6 (`⟲` covers every level, and each slot of them
//! is read once: a level of one route folds onto another's arrival).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Replay = @import("Replay.zig");
const Slots = @import("Slots.zig");
const SlotWords = @import("SlotWords.zig");
const Subtree = @import("Subtree.zig");
const PastPayload = @import("PastPayload.zig");

const Error = Ids.ChargeError;
const Step = Place.Step;
const none: u32 = Ids.none_int;

/// The objects of reference `x` at steps `rest`, one leaf (none when it holds no slot).
pub fn read(e: anytype, x: anytype, rest: []const u32, deep: bool, tags: u32, route: u32, out: anytype) Error!void {
    const set = try slotsAt(e, x, rest, deep, tags, route, out);
    if (set != Slots.empty) try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set, .tags = tags }), .route = route });
}

fn slotsAt(e: anytype, x: anytype, rest: []const u32, deep: bool, tags: u32, route: u32, out: anytype) Error!Slots.SetId {
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(e.gpa());
    const tops: []const u32 = if (x.family != Slots.empty) e.f.slots.items(x.family) else &.{e.f.pos.items[x.pos].slot.int()};
    // A step an opaque or a type variable's place cannot follow
    // (a cast's inner, §2.13.9) is some object inside it: all
    // of what it reaches, read approximately.
    var inside: std.ArrayList(u32) = .empty;
    defer inside.deinit(e.gpa());
    for (tops) |t| {
        const before = all.items.len;
        try Replay.replay(e.gpa(), e.account(), e.places(), .from(t), rest, &all);
        if (all.items.len == before and rest.len != 0 and !@import("Mutate.zig").on(.unnamed_step_empty)) {
            const k = e.places().kind(e.places().pathPlace(.from(t)));
            if (k == .@"opaque" or k == .@"var") {
                // A call's result read on past its place: through what arrives there.
                if (x.family == Slots.empty and try e.throughCall(x.root, .from(t), rest, deep, tags, route, out)) continue;
                try inside.append(e.gpa(), t);
            } else if (try PastPayload.prefix(e, .from(t), rest, &inside)) {
                if (e.f.roots.items[x.root].kind != .param) try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .top, .tags = tags }), .route = route });
            } else if (PastPayload.atPayload(e.places(), e.places().pathPlace(.from(t)), rest, 0)) try inside.append(e.gpa(), t);
        }
    }
    var set = try e.f.slots.setOf(e.gpa(), e.account(), e.places(), all.items);
    if (deep) set = try Subtree.belowSet(e.f.slots, e.gpa(), e.account(), e.places(), try e.f.slots.sorted(e.gpa(), e.account(), all.items));
    for (inside.items) |t| set = try e.f.slots.unionOf(e.gpa(), e.account(), set, try Subtree.below(e.f.slots, e.gpa(), e.account(), e.places(), .from(t)));
    return set;
}

/// `⟲` then `rest` at reference `x`, part of a value on a cycle: for each of `routes` (`Eval.levelRoutes`,
/// steps to the cycle's place) the level it arrives at and the levels below that. A level
/// of one route folds onto another's arrival, and two leaves of one slot would read
/// as two objects, so each slot is read once.
pub fn levels(e: anytype, x: anytype, routes: []const []const u32, rest: []const u32, deep0: bool, tags: u32, route: u32, out: anytype) Error!void {
    const g = e.gpa();
    const deep = deep0 or SlotWords.endsInRow(rest);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(g);
    var w: std.ArrayList(u32) = .empty;
    defer w.deinit(g);
    var run: std.ArrayList(u32) = .empty;
    defer run.deinit(g);
    for (routes) |to| for ([_]bool{ true, false }) |arrival| {
        if (arrival and to.len == 0) continue;
        w.clearRetainingCapacity();
        try w.appendSlice(g, to);
        if (!arrival) try w.append(g, Step.level.word());
        try w.appendSlice(g, rest);
        var set = try slotsAt(e, x, w.items, deep, tags, route, out);
        if (routes.len > 1 and !@import("Mutate.zig").on(.level_slot_twice)) {
            run.clearRetainingCapacity();
            for (e.f.slots.elems(set)) |s| {
                try e.charge(.inspection, 1);
                if (Slots.isSub(s) or Slots.isNot(s) or !(try seen.getOrPut(g, .{s})).found_existing) try run.append(g, s);
            }
            set = try e.f.slots.internSorted(g, e.account(), run.items);
        }
        if (set != Slots.empty) try out.append(g, .{ .leaf = try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set, .tags = tags }), .route = route });
    };
}
