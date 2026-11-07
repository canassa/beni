//! L4: the routes between two places (`docs/design/ownership-v2.md` §2.1), split from `Relation`.
//!
//! Obligations kept here: O6 (`⟲` covers every level: every route is found).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const PathsTo = @import("PathsTo.zig");

/// The steps of a route from `from` to place `target` for each first arrival on its cycle,
/// by the slots and not the routes (`PathsTo`). Off it (a fold's instantiation): the shortest.
pub fn of(gpa: std.mem.Allocator, arena: std.mem.Allocator, account: *Ids.Account, pl: *Place.Table, from: Ids.PathId, target: Ids.PlaceId, out: *std.ArrayList([]const u32)) Ids.ChargeError!void {
    var nodes: std.ArrayList(PathsTo.Node) = .empty;
    defer nodes.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    if (pl.sameComponent(pl.pathPlace(from), target)) try PathsTo.of(gpa, account, pl, from, target, &nodes, &ends) else try shortest(gpa, account, pl, from, target, &nodes, &ends);
    if (ends.items.len > 1 and @import("Mutate.zig").on(.level_route_shortest)) ends.items.len = 1;
    for (ends.items) |n| {
        var ws: std.ArrayList(u32) = .empty;
        var k = n;
        while (k != 0) : (k = nodes.items[k].back) try ws.append(arena, nodes.items[k].word);
        std.mem.reverse(u32, ws.items);
        try out.append(arena, ws.items);
    }
}

fn shortest(gpa: std.mem.Allocator, account: *Ids.Account, pl: *Place.Table, from: Ids.PathId, target: Ids.PlaceId, nodes: *std.ArrayList(PathsTo.Node), out: *std.ArrayList(u32)) Ids.ChargeError!void {
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try nodes.append(gpa, .{ .p = from, .back = Ids.none_int, .word = 0 });
    var qi: u32 = 0;
    while (qi < nodes.items.len) : (qi += 1) {
        const it = nodes.items[qi];
        try account.reserve(.path, 1);
        if (qi != 0 and pl.pathPlace(it.p) == target) return out.append(gpa, qi);
        const st = pl.steps(pl.pathPlace(it.p));
        for (st.steps) |s| {
            if (s.kind == .level) continue;
            const nx = (try pl.extend(gpa, .growth(account), it.p, s)) orelse continue;
            if (nx == from or (try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
            try nodes.append(gpa, .{ .p = nx, .back = qi, .word = s.word() });
        }
    }
}
