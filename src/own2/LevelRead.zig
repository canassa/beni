//! L1: how a built value reads a `⟲` (`docs/design/ownership-v2.md` §2.1, *A level
//! past a fold*): on its own place's cycle, or step for step with a place of a
//! fold. Over `Place.Table`, passed in, as `LevelWalk`.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Ids = @import("Ids.zig");

const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;

/// One way to read a `⟲` at a place. `c` `.none`: on `origin`'s own cycle.
/// Else `origin` is a place of a fold's cycle, and `c` how far round it the reader is.
pub const Reading = struct {
    origin: PlaceId,
    c: PlaceId = .none,

    /// Whether a value at `p` is a level.
    pub fn level(r: Reading, p: PlaceId) bool {
        return if (r.c == .none) p == r.origin else r.c == r.origin;
    }

    /// The reading of kid `kp`, by step `st`; null when it is off the way.
    pub fn kid(r: Reading, t: anytype, st: anytype, kp: PlaceId) ?Reading {
        if (r.c == .none) return if (kp == r.origin or t.sameCycle(kp, r.origin)) r else null;
        const c = t.child(r.c, st) orelse return null;
        if (c != r.origin and !t.sameCycle(c, r.origin)) return null;
        if (!alike(t, c, kp)) return null;
        return .{ .origin = r.origin, .c = c };
    }
};

fn alike(t: anytype, a: PlaceId, b: PlaceId) bool {
    return t.kind(a) == t.kind(b) and t.head(a) == t.head(b);
}

/// The readings of a `⟲` that is `w` at `q`, into `out`: `q`'s own cycle, or
/// each place of a fold `q` may be an instantiation of.
pub fn readings(t: anytype, arena: std.mem.Allocator, w: u32, q: PlaceId) Error![]const Reading {
    var out: std.ArrayList(Reading) = .empty;
    if (w != 0 and !t.places.col.below[q.int()].fold) {
        for (t.fold_places.items) |c| if (alike(t, c, q)) try out.append(arena, .{ .origin = c, .c = c });
    }
    if (out.items.len == 0) try out.append(arena, .{ .origin = q });
    return out.items;
}

/// The steps round the cycle from `c` to `origin`, into `out`.
pub fn wordsTo(t: anytype, gpa: std.mem.Allocator, charge: Ids.Charge, c: PlaceId, origin: PlaceId, out: *std.ArrayList(u32)) Error!void {
    const Item = struct { p: PlaceId, back: u32, word: u32 };
    var queue: std.ArrayList(Item) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try queue.append(gpa, .{ .p = c, .back = Ids.none_int, .word = 0 });
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        try charge.reserve(gpa, .inspection, 1);
        const st = t.steps(queue.items[i].p);
        for (st.steps, st.children) |s, k| {
            if (k != origin and !t.sameCycle(k, origin)) continue;
            if ((try seen.getOrPut(gpa, .{k.int()})).found_existing) continue;
            try queue.append(gpa, .{ .p = k, .back = @intCast(i), .word = s.word() });
            if (k != origin) continue;
            var at: u32 = @intCast(queue.items.len - 1);
            while (queue.items[at].back != Ids.none_int) : (at = queue.items[at].back) try out.append(gpa, queue.items[at].word);
            std.mem.reverse(u32, out.items);
            return;
        }
    }
}
