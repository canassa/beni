//! L3: the routes between two places (`docs/design/ownership-v2.md` §2.1), split from `Relation`.
//!
//! Obligations kept here: O6 (`⟲` covers every level: every route is found).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const none: u32 = Ids.none_int;

/// The steps of every route from path `from` to place `target` on its cycle, each
/// canonical path once and none past its first arrival, into `out`.
/// Off the cycle (a fold's instantiation): the shortest route.
pub fn of(gpa: std.mem.Allocator, arena: std.mem.Allocator, account: *Ids.Account, pl: *Place.Table, from: PathId, target: PlaceId, out: *std.ArrayList([]const u32)) Ids.ChargeError!void {
    const Item = struct { p: PathId, back: u32, word: u32 };
    var queue: std.ArrayList(Item) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try queue.append(gpa, .{ .p = from, .back = none, .word = 0 });
    _ = try seen.getOrPut(gpa, .{from.int()});
    const on = pl.sameComponent(pl.pathPlace(from), target);
    var qi: u32 = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const it = queue.items[qi];
        try account.reserve(.path, 1);
        if (qi != 0 and pl.pathPlace(it.p) == target) {
            var ws: std.ArrayList(u32) = .empty;
            var k = qi;
            while (k != 0) : (k = queue.items[k].back) try ws.append(arena, queue.items[k].word);
            std.mem.reverse(u32, ws.items);
            try out.append(arena, ws.items);
            if (on and !@import("Mutate.zig").on(.level_route_shortest)) continue else return;
        }
        const st = pl.steps(pl.pathPlace(it.p));
        for (st.steps, st.children) |s, c| {
            if (s.kind == .level or (on and !pl.sameComponent(c, target))) continue;
            const nx = (try pl.extend(gpa, .growth(account), it.p, s)) orelse continue;
            if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
            try queue.append(gpa, .{ .p = nx, .back = qi, .word = s.word() });
        }
    }
}
