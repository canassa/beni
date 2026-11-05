//! L7: what a function may hold of a leaf (`docs/design/ownership-v2.md`
//! §2.9.2 step 7), split from `Distinct` to be a worklist (#2070).
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");

/// What parameter `j`'s function at `slot` may hold of leaf `ti`: an object
/// made in this activation, nothing; another parameter's, what the two
/// selections keep apart (`sel`). One worklist, each leaf once: a call's
/// expansion can reach its own leaf again, and a cycle adds nothing (#2070).
pub fn of(comptime Ov: type, e: anytype, j: u32, slot: Slots.Rel, ti: u32, sel: anytype) !Ov {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(e.gpa());
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(e.gpa());
    try stack.append(e.gpa(), ti);
    var acc: Ov = .no;
    while (stack.pop()) |li| {
        if ((try seen.getOrPut(e.gpa(), .{li})).found_existing) continue;
        try e.charge(.cond, 1);
        const t = e.f.leafAt(li);
        if (t.kind == .site or t.kind == .fresh) continue;
        if (t.kind != .ref) return .may;
        const r = e.f.roots.items[t.root];
        if (r.kind == .param and r.a != j) {
            var occ = [_]u64{Contract.occApart(j, slot)};
            const c = try Contract.Cond.conj(e.arena, e.account(), try Contract.Cond.of(e.account(), &occ), try sel(e, r.a, t.slots));
            if (c.no) return .may;
            acc = try Ov.join(e.arena, e.account(), acc, .{ .kind = .under, .cond = c });
            continue;
        }
        if (!e.expandable(t)) return .may;
        try e.expand(li, &stack);
    }
    return acc;
}
