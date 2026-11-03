//! L2: what a place graph says below a path, read off the places and never
//! off the paths (`docs/design/ownership-v2.md` §2.3.1): how many object
//! slots lie at and below a place no cycle reaches, and whether a family
//! (`[*]`, `⟲`) does. Split from `Subtree`; read by `Distinct` and `Descent`.
//!
//! Obligations kept here: none of §2.14's directly (a count past its cap,
//! or a cycle, answers "many": never fewer slots than there are).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const Error = Ids.ChargeError;

/// The object slots at and below place `p`, at most `cap`;
/// `maxInt` when a place below it is on a cycle (its paths fold: not counted).
pub fn slotsBelow(gpa: Allocator, account: *Ids.Account, places: *const Place.Table, p: PlaceId, cap: u32, memo: *Ids.FixedDict(1)) Error!u32 {
    if (memo.get(.{p.int()})) |n| return n;
    try account.reserve(.path, 1);
    var n: u32 = @intFromBool(!Place.Kind.own(places.kind(p)).isEmpty());
    if (places.cyclic(p)) n = std.math.maxInt(u32) else for (places.steps(p).children) |c| {
        const m = try slotsBelow(gpa, account, places, c, cap, memo);
        if (m == std.math.maxInt(u32)) {
            n = m;
            break;
        }
        n = @min(n + m, cap);
    }
    try memo.put(gpa, .{p.int()}, n);
    return n;
}

/// Whether `below(p)` holds a slot below a `[*]` or a `⟲` (a family,
/// §2.3.1), read off the place graph, never off the paths: `p` is one, or a
/// place reachable from `p`'s is a list or a dictionary whose elements hold
/// an object, or lies on a cycle and holds one (every second return there
/// is a `⟲`, and `Up(p)`'s paths are `⟲`s).
/// The place graph's answer is a column of each place, set with its strongly
/// connected component (`Place.Place.family`, #1714): one record.
pub fn familyBelow(gpa: Allocator, account: *Ids.Account, places: *const Place.Table, p: PathId) Error!bool {
    _ = gpa;
    if (places.isSummary(p)) return true;
    try account.reserve(.inspection, 1);
    return places.places.col.below[places.pathPlace(p).int()].family;
}
