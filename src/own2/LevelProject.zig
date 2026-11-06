//! L7: `⟲` into a built value (`docs/design/ownership-v2.md` §2.1, §2.11.2):
//! the values one or more levels below it, read by `LevelCycle`'s readings.
//! Split from `Relation`, whose `Eval` it is passed: this file is below it.
//!
//! Obligations kept here: none of §2.14's directly (each output stands for
//! a level of the value).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const LevelCycle = @import("LevelCycle.zig");
const LevelRead = @import("LevelRead.zig");

const Error = Ids.ChargeError;

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const none: u32 = Ids.none_int;

/// The steps from a part at reading `r` to its next level: slot `from`'s.
pub fn toLevel(e: anytype, r: LevelCycle.Reading, from: PathId, out: *std.ArrayList(u32)) Error!void {
    if (r.c != .none) return LevelRead.wordsTo(e.places(), e.gpa(), e.f.gc(), r.c, r.origin, out);
    return stepsTo(e, from, r.origin, out);
}

/// The shortest steps from path `from` to a path at place `target`,
/// into `out` (nothing when there is none).
pub fn stepsTo(e: anytype, from: PathId, target: PlaceId, out: *std.ArrayList(u32)) Error!void {
    const pl = e.places();
    const Item = struct { p: PathId, back: u32, word: u32 };
    var queue: std.ArrayList(Item) = .empty;
    defer queue.deinit(e.gpa());
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(e.gpa());
    try queue.append(e.gpa(), .{ .p = from, .back = none, .word = 0 });
    _ = try seen.getOrPut(e.gpa(), .{from.int()});
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const it = queue.items[qi];
        try e.charge(.path, 1);
        if (qi != 0 and pl.pathPlace(it.p) == target) {
            var k: u32 = @intCast(qi);
            while (k != 0 and queue.items[k].back != none) : (k = queue.items[k].back) try out.append(e.gpa(), queue.items[k].word);
            std.mem.reverse(u32, out.items);
            return;
        }
        for (pl.steps(pl.pathPlace(it.p)).steps) |st| {
            if (st.kind == .level) continue;
            const nx = (try pl.extend(e.gpa(), e.f.gc(), it.p, st)) orelse continue;
            if ((try seen.getOrPut(e.gpa(), .{nx.int()})).found_existing) continue;
            try queue.append(e.gpa(), .{ .p = nx, .back = @intCast(qi), .word = st.word() });
        }
    }
}

/// `⟲` into a built value, at `place` (`LevelCycle`): the values one or more levels below, at the
/// same place, through the parts that stay on its cycle; then `rest`
/// from each (the experiment's fourth requirement). A part not built
/// here gives its levels by its own slots, never its own storage.
pub fn levels(e: anytype, v: u32, place: PlaceId, w: u32, rest: []const u32, deep: bool, tags: u32, route: u32, out: anytype) Error!void {
    if (place == .none) {
        try e.readAt(v, true, tags, route, out);
        return;
    }
    for (try LevelCycle.readings(e.places(), e.arena, w, place)) |r| try levelsBy(e, v, place, r, w, rest, deep, tags, route, out);
}

fn levelsBy(e: anytype, v: u32, place: PlaceId, r0: LevelCycle.Reading, w: u32, rest: []const u32, deep: bool, tags: u32, route: u32, out: anytype) Error!void {
    const pl = e.places();
    const Item = struct { v: u32, place: PlaceId, r: LevelCycle.Reading, route: u32, below: bool };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(e.gpa());
    try stack.append(e.gpa(), .{ .v = v, .place = place, .r = r0, .route = route, .below = false });
    var met: Ids.FixedDict(5) = .{};
    defer met.deinit(e.gpa());
    while (stack.pop()) |it| {
        if ((try met.getOrPut(e.gpa(), .{ it.v, it.place.int(), it.r.c.int(), @intFromBool(it.below), if (e.no_routes) 0 else it.route })).found_existing) continue;
        try e.charge(.inspection, 1);
        const x = e.f.val(it.v);
        switch (x.kind) {
            .built => {
                if (it.below and it.r.level(it.place)) try e.project(it.v, rest, deep, tags, it.route, out);
                for (e.f.kidsOf(x), 0..) |k, n| {
                    const kst: Step = switch (x.form) {
                        .list => Step.elem,
                        .record => try Step.field(e.account(), e.f.wordsOf(x.extra)[n]),
                        .tuple => try Step.index(e.account(), @intCast(n)),
                        .ctor => try pl.ctorStep(e.gpa(), e.account(), x.head, @intCast(n)),
                        .closure, .opaque_ => continue,
                    };
                    const kp = pl.child(it.place, kst) orelse continue;
                    const kr = it.r.kid(pl, kst, kp) orelse continue;
                    try stack.append(e.gpa(), .{ .v = k, .place = kp, .r = kr, .route = try e.routeStep(it.route, @intCast(n)), .below = true });
                }
            },
            .scalar, .bot => {},
            .ref => if (it.below) {
                if (it.r.level(it.place)) try e.project(it.v, rest, deep, tags, it.route, out);
                // A part on the cycle at another place (a `List T` below a
                // `T`): its next level is the steps to the cycle's place.
                var to: std.ArrayList(u32) = .empty;
                defer to.deinit(e.gpa());
                if (!it.r.level(it.place) and x.family == Slots.empty) try toLevel(e, it.r, e.f.pos.items[x.pos].slot, &to);
                // Its own levels below, by its slots (never its own storage).
                var lv: std.ArrayList(u32) = .empty;
                defer lv.deinit(e.gpa());
                if (to.items.len != 0) {
                    try lv.appendSlice(e.gpa(), to.items);
                    try lv.appendSlice(e.gpa(), rest);
                    try e.project(it.v, lv.items, deep, tags, it.route, out);
                    lv.clearRetainingCapacity();
                    try lv.appendSlice(e.gpa(), to.items);
                }
                try lv.append(e.gpa(), (Step{ .kind = .level, .payload = @intCast(w) }).word());
                try lv.appendSlice(e.gpa(), rest);
                try e.project(it.v, lv.items, deep, tags, it.route, out);
            },
            .alt => {
                const ks = e.f.kidsOf(x);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) try stack.append(e.gpa(), .{ .v = ks[i + 1], .place = it.place, .r = it.r, .route = it.route, .below = it.below });
            },
            else => if (it.below) try e.project(it.v, rest, deep, tags, it.route, out),
        }
    }
}
