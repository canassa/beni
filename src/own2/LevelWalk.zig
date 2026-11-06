//! L1: where a `⟲` goes past a non-regular type's fold
//! (`docs/design/ownership-v2.md` §2.1, *A level past a fold*). A `⟲` written on
//! a fold's cycle means every way round that cycle back to the place it was
//! written at, and a value of another instantiation reads it step for step
//! with that place: the walk is a pair, the fold's place and the reader's. So
//! a kid a type variable stands for is no step, since the fold's place has a
//! `var` there and a `var` is on no cycle, and the walk ends where the two
//! places are one, since `⟲` there names the rest. Over `Place.Table`, passed
//! in: `Slots` reads this file.
//!
//! Obligations kept here: none of §2.14's directly (a `⟲` stands for at
//! least the levels its value has).

const std = @import("std");
const Ids = @import("Ids.zig");

const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;
const PathId = Ids.PathId;

fn alike(t: anytype, a: PlaceId, b: PlaceId) bool {
    return t.kind(a) == t.kind(b) and t.head(a) == t.head(b);
}

/// `at`'s levels past `at`'s own cycle, for a `⟲` written on a fold's cycle, into
/// `out`. `Place.levelsOf` and `extend` have the levels where `at` is on it.
pub fn walk(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, at: PathId, out: *std.ArrayList(u32)) Error!void {
    const q = t.pathPlace(at);
    if (t.places.col.below[q.int()].fold or !t.places.col.below[q.int()].leads) return;
    const a = charge.account;
    if (a.walkedRun(.past_fold, at.int())) |run| return out.appendSlice(gpa, run);
    const first = out.items.len;
    for (t.fold_places.items) |c| if (alike(t, c, q)) try from(t, gpa, charge, at, c, out);
    try a.keepRun(gpa, .past_fold, at.int(), out.items[first..]);
}

fn from(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, at: PathId, origin: PlaceId, out: *std.ArrayList(u32)) Error!void {
    const Item = struct { c: PlaceId, x: PathId };
    var seen: Ids.FixedDict(2) = .{};
    defer seen.deinit(gpa);
    var queue: std.ArrayList(Item) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, .{ .c = origin, .x = at });
    _ = try seen.getOrPut(gpa, .{ origin.int(), at.int() });
    while (queue.pop()) |it| {
        const n = t.steps(it.c).steps.len;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const st = t.steps(it.c);
            const c = st.children[j];
            if (c != origin and !t.sameCycle(c, origin)) continue;
            try charge.reserve(gpa, .inspection, 1);
            const here = t.pathPlace(it.x);
            const stays = c == it.c and t.child(here, st.steps[j]) == here;
            // The reader's own self-loop: every way round it is its one `⟲`.
            const np = (try t.extend(gpa, charge, it.x, if (stays) .level else st.steps[j])) orelse continue;
            const p = t.pathPlace(np);
            if (!alike(t, c, p)) continue;
            if (c == origin) {
                try out.append(gpa, np.int());
                if (p == c) {
                    try out.append(gpa, (try t.extend(gpa, charge, np, .level)).?.int());
                    continue;
                }
            }
            if (!(try seen.getOrPut(gpa, .{ c.int(), np.int() })).found_existing) try queue.append(gpa, .{ .c = c, .x = np });
        }
    }
}
