//! L4: how large `below(p)` is, without writing it out
//! (`docs/design/ownership-v2.md` §2.3.1), read by the hidden
//! `--ownership-below` dump: whether it has more than a bound of slots.
//!
//! Obligations kept here: none of §2.14's directly (a walk stopped past its
//! bound answers "more": never fewer slots than there are).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");

const Table = Slots.Table;
const PathId = Ids.PathId;
const Error = Slots.Error;

/// Whether `below(p)` written out has more than `n` slots: `belowAll`'s
/// walk, stopped at the first slot past `n` (never written out whole).
pub fn moreBelow(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId, n: usize) Error!bool {
    var queue: std.ArrayList(PathId) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var found: Ids.FixedDict(1) = .{};
    defer found.deinit(gpa);
    try queue.append(gpa, p);
    _ = try seen.getOrPut(gpa, .{p.int()});
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const at = queue.items[qi];
        try account.reserve(.path, 1);
        if (Slots.isObject(places, at)) for (t.items(try t.canon(gpa, account, places, at))) |c| {
            _ = try found.getOrPut(gpa, .{c});
            if (found.count() > n) return true;
        };
        for (places.steps(places.pathPlace(at)).steps) |st| {
            const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
            if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
            try queue.append(gpa, nx);
        }
    }
    return false;
}
