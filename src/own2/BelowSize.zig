//! L4: how large `below(p)` is, without writing it out
//! (`docs/design/ownership-v2.md` §2.3.1), split from `Subtree`: whether it
//! has more than a bound of slots, and whether a place no step can name
//! (a type variable's, an opaque one) is below a place.
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
const PlaceId = Ids.PlaceId;
const Error = Slots.Error;

/// A parameter's subtree that a contract's result returns at its own
/// path is said by structure, one open arrival, past this many slots
/// written out (§2.10, *Arrivals by structure*; #1715).
pub const written_max: usize = 256;

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

/// Whether a type variable's or an opaque place is at or below `p`: a
/// place no step below it can name.
pub fn wildBelow(gpa: Allocator, places: *const Place.Table, p: PlaceId) Allocator.Error!bool {
    if (p == .none) return false;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, places.count());
    defer seen.deinit(gpa);
    var stack: std.ArrayList(PlaceId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, p);
    while (stack.pop()) |x| {
        if (seen.isSet(x.int())) continue;
        seen.set(x.int());
        switch (places.kind(x)) {
            .@"var", .@"opaque" => return true,
            else => {},
        }
        try stack.appendSlice(gpa, places.steps(x).children);
    }
    return false;
}
