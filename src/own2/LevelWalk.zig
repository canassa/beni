//! L1: where a `⟲` goes past a non-regular type's fold
//! (`docs/design/ownership-v2.md` §2.1, *A level past a fold*). The fold joins
//! every instantiation below the first into one place, so `T (List Int)`'s own
//! place is off the cycle a contract's `⟲` was written on, and its levels are
//! at another place. Over `Place.Table`, passed in: `Slots` reads this file.
//!
//! Obligations kept here: none of §2.14's directly (a `⟲` stands for at
//! least the levels its value has).

const std = @import("std");
const Ids = @import("Ids.zig");

const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;
const PathId = Ids.PathId;

/// Whether `p` is or leads to the fold of `at`'s head: a place of its kind and head on a cycle with a fold.
fn reaches(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, p: PlaceId, at: PlaceId) Error!bool {
    if (!t.places.col.below[p.int()].leads) return false;
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var stack: std.ArrayList(PlaceId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, p);
    while (stack.pop()) |x| {
        try charge.reserve(gpa, .inspection, 1);
        if (t.places.col.below[x.int()].fold and t.kind(x) == t.kind(at) and t.head(x) == t.head(at)) return true;
        for (t.steps(x).children) |c| {
            if (!t.places.col.below[c.int()].leads) continue;
            if (!(try seen.getOrPut(gpa, .{c.int()})).found_existing) try stack.append(gpa, c);
        }
    }
    return false;
}

/// Whether `p` is a level of `at` to a `⟲` that is `w`: that place, or, for a
/// fold's `⟲`, another instantiation of its head on the way to the head's fold.
pub fn level(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, w: u32, p: PlaceId, at: PlaceId) Error!bool {
    if (p == at) return true;
    if (w == 0 or t.kind(p) != t.kind(at) or t.head(p) != t.head(at)) return false;
    return reaches(t, gpa, charge, p, at);
}

/// Whether a walk of `at`'s levels for a `⟲` that is `w` goes on into `p`: on
/// `at`'s cycle, or, for a fold's `⟲`, on the way to its fold.
pub fn way(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, w: u32, p: PlaceId, at: PlaceId) Error!bool {
    return p == at or t.sameCycle(p, at) or (w != 0 and try reaches(t, gpa, charge, p, at));
}

/// `at`'s levels at another place than its own, into `out`, from `at` and from
/// its own levels' join: a walk off `at`'s cycle by `way`'s steps. A level on the
/// fold's cycle ends the walk: `⟲` there names the rest, so the paths are as many
/// as the routes to the fold. `Place.levelsOf` has the levels at `at`'s own place.
pub fn walk(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, at: PathId, out: *std.ArrayList(u32)) Error!void {
    const q = t.pathPlace(at);
    if (!t.places.col.below[q.int()].leads) return;
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var queue: std.ArrayList(PathId) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, at);
    _ = try seen.getOrPut(gpa, .{at.int()});
    if (t.cyclic(q)) {
        const own = (try t.extend(gpa, charge, at, .level)).?;
        if (!(try seen.getOrPut(gpa, .{own.int()})).found_existing) try queue.append(gpa, own);
    }
    while (queue.pop()) |x| {
        const n = t.steps(t.pathPlace(x)).steps.len;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const st = t.steps(t.pathPlace(x));
            try charge.reserve(gpa, .inspection, 1);
            const c = st.children[j];
            if (c == q or !try way(t, gpa, charge, 1, c, q)) continue;
            const np = (try t.extend(gpa, charge, x, st.steps[j])) orelse continue;
            if (try level(t, gpa, charge, 1, c, q)) {
                try out.append(gpa, np.int());
                if (t.places.col.below[c.int()].fold) {
                    try out.append(gpa, (try t.extend(gpa, charge, np, .level)).?.int());
                    continue;
                }
            }
            if (!(try seen.getOrPut(gpa, .{np.int()})).found_existing) try queue.append(gpa, np);
        }
    }
}
