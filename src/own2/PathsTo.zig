//! L3: the canonical paths on which a walk from a path first reaches a place
//! (`docs/design/ownership-v2.md` §2.1, *A level read on a built value*). The
//! work follows the slots there are, never the routes to them. A walk below a
//! context, the path it started from or one a fold took it up to, tells two
//! routes apart only if the arrival depends on them. When the target has
//! returned on the context, every step onto it folds onto the same path
//! (`Place.extend`), and each place below is met once. Else each arrival is a
//! slot of its own, and each canonical path below is met once: a place alone
//! is no node there, since `#Bx.0` and `#Bx.1` hold one place and are two slots.
//!
//! Obligations kept here: O6 (`⟲` covers every level: every first arrival is found).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;

/// Whether a step onto `target` below `c` folds onto a path of `c`: `extend`'s
/// condition, read from `c`, on `target`'s cycle.
fn folds(pl: *const Place.Table, account: *Ids.Account, c: PathId, target: PlaceId) Ids.ChargeError!bool {
    var met = false;
    var at = c;
    while (at != .none) : (at = pl.pathParent(at)) {
        try account.reserve(.path, 1);
        const there = pl.pathPlace(at);
        if (there == target) {
            if (met or (pl.pathParent(at) != .none and pl.pathStep(at).kind == .level)) return true;
            met = true;
        } else if (!pl.sameComponent(there, target)) return false;
    }
    return false;
}

/// Every first arrival of a walk from `from` at `target`, on `target`'s cycle,
/// into `out`, each once. No walk goes on past an arrival, or off the cycle.
pub fn of(gpa: std.mem.Allocator, account: *Ids.Account, pl: *Place.Table, from: PathId, target: PlaceId, out: *std.ArrayList(u32)) Ids.ChargeError!void {
    var contexts: std.ArrayList(PathId) = .empty;
    defer contexts.deinit(gpa);
    var queue: std.ArrayList(PathId) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(2) = .{};
    defer seen.deinit(gpa);
    try contexts.append(gpa, from);
    var ci: usize = 0;
    while (ci < contexts.items.len) : (ci += 1) {
        const c = contexts.items[ci];
        const by_place = try folds(pl, account, c, target);
        queue.clearRetainingCapacity();
        try queue.append(gpa, c);
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const st = pl.steps(pl.pathPlace(queue.items[qi]));
            for (st.steps, st.children) |s, ch| {
                if (s.kind == .level or !pl.sameComponent(ch, target)) continue;
                const nx = (try pl.extend(gpa, .growth(account), queue.items[qi], s)) orelse continue;
                if (ch == target) {
                    if (!(try seen.getOrPut(gpa, .{ 0, nx.int() })).found_existing) try out.append(gpa, nx.int());
                } else if (!pl.isPrefix(c, nx)) {
                    if (!(try seen.getOrPut(gpa, .{ 1, nx.int() })).found_existing) try contexts.append(gpa, nx);
                } else if (!(try seen.getOrPut(gpa, .{ 2 + @as(u32, @intCast(ci)), if (by_place) ch.int() else nx.int() })).found_existing) {
                    try queue.append(gpa, nx);
                }
            }
        }
    }
}
