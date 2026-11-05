//! L8: a supply's family read from the argument it comes from
//! (`docs/design/ownership-v2.md` §2.9.3, *a family behind a supply*).
//! `expand` gives a value's objects each once (§2.11.2), so a literal that
//! holds one object twice reads as one entry; the distinct check needs both.
//!
//! Obligations kept here: the distinct check's half of O3 for a supply's
//! family: every position of the argument is an entry of its own.

const std = @import("std");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;

/// The entries of supply leaf `li`, each position of its argument at a
/// route of its own, into `ps`. An arrival that is no parameter's is
/// expanded as `Eval.expand` reads it.
pub fn entries(e: *Eval, li: u32, ps: *std.ArrayList(Proj)) Error!void {
    const g = e.gpa();
    const l = e.f.leafAt(li);
    const su = e.f.supplies.items[e.f.roots.items[l.root].a];
    const cl = e.f.calls.items[su.call];
    var route: u32 = 1;
    const c = e.contractOf(su.call) orelse return;
    for (e.f.slots.elems(l.slots)) |s| {
        if (Slots.isNot(s)) continue;
        const words = e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), e.places(), Slots.pathOf(s)));
        var hits: std.ArrayList(Contract.Hit) = .empty;
        defer hits.deinit(g);
        try e.hitsAt(e.resRoot(c, (su.label << 16) | su.k), words, &hits);
        for (hits.items) |hit| for (hit.arrivals) |a0| {
            const a = Subtree.readAt(e.places(), a0, Slots.pathOf(s), hit.open);
            route += 1;
            if (a.kind == .param and a.j < cl.args.len) {
                const at = try std.mem.concat(e.arena, u32, &.{ e.f.slots.relWords(a.slot), words[hit.depth..] });
                try e.project(cl.args[a.j], at, a.deep or Slots.isSub(s), 0, route, ps);
                continue;
            }
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(g);
            try e.arrivalLeaves(su.call, c, a, words[hit.depth..], &ls);
            for (ls.items, 0..) |x, k| try ps.append(g, .{ .leaf = x, .route = route + @as(u32, @intCast(k)) << 16 });
        };
    }
}
