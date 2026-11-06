//! L2: a shape test for a non-regular fold (`docs/design/ownership-v2.md` §2.1, *A step
//! past a fold*, §2.11.3): past a fold no slot names a step and a contract can run
//! short. The head comes back at a second place, on a cycle: `T (List Int)`, then
//! `T var`. A stopgap: a fold with one place passes it (§2.11.3, *Sound*).
//!
//! Obligations kept here: none of §2.14's directly (`Needs` refuses).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PlaceId = Ids.PlaceId;

/// Whether the places reachable from `root` hold a constructor's head at two
/// places, one on a cycle. `Maybe (Maybe a)` has no cycle and does not.
pub fn crosses(gpa: std.mem.Allocator, pl: *const Place.Table, root: PlaceId) !bool {
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var heads: Ids.FixedDict(1) = .{};
    defer heads.deinit(gpa);
    var firsts: std.ArrayList(PlaceId) = .empty;
    defer firsts.deinit(gpa);
    var stack: std.ArrayList(PlaceId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root);
    while (stack.pop()) |p| {
        if (p == .none or (try seen.getOrPut(gpa, .{p.int()})).found_existing) continue;
        if (pl.kind(p) == .ctor) {
            const h = try heads.getOrPut(gpa, .{pl.head(p)});
            if (h.found_existing) {
                const q = firsts.items[h.value_ptr.*];
                if (pl.cyclic(p) or pl.cyclic(q)) return true;
            } else {
                h.value_ptr.* = @intCast(firsts.items.len);
                try firsts.append(gpa, p);
            }
        }
        try stack.appendSlice(gpa, pl.steps(p).children);
    }
    return false;
}
