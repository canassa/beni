//! L3: the shortest steps between two places (`docs/design/ownership-v2.md`
//! §2.1, *A step past a fold*), split from `Relation`.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const none: u32 = Ids.none_int;

/// The shortest steps from path `from` to a path at place `target`,
/// into `out` (nothing when there is none).
pub fn of(gpa: Allocator, account: *Ids.Account, pl: *Place.Table, from: PathId, target: PlaceId, out: *std.ArrayList(u32)) Ids.ChargeError!void {
    const Item = struct { p: PathId, back: u32, word: u32 };
    var queue: std.ArrayList(Item) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try queue.append(gpa, .{ .p = from, .back = none, .word = 0 });
    _ = try seen.getOrPut(gpa, .{from.int()});
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const it = queue.items[qi];
        try account.reserve(.path, 1);
        if (qi != 0 and pl.pathPlace(it.p) == target) {
            var k: u32 = @intCast(qi);
            while (k != 0 and queue.items[k].back != none) : (k = queue.items[k].back) try out.append(gpa, queue.items[k].word);
            std.mem.reverse(u32, out.items);
            return;
        }
        for (pl.steps(pl.pathPlace(it.p)).steps) |st| {
            if (st.kind == .level) continue;
            const nx = (try pl.extend(gpa, .growth(account), it.p, st)) orelse continue;
            if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
            try queue.append(gpa, .{ .p = nx, .back = @intCast(qi), .word = st.word() });
        }
    }
}
