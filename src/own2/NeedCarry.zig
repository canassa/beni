//! L9: what carries a need (`docs/design/ownership-v2.md` §2.11.3, *A value
//! that carries a need*). A closure of the frame whose code has a label with a
//! need is where a need starts; a value carries it when it reaches such a
//! closure by any route: the closure itself, a structure that holds it, a
//! closure or a partial application that captures it, a call's answer it
//! arrives in, or a cell that lends it, transitively. `NeedLeaves.escaped` and
//! `NeedLeaves.stored` ask this one question of what they find.
//!
//! Obligations kept here: O14's need half (a value that carries a need is
//! seen wherever it stands, never by its shape alone).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Origin = @import("Origin.zig");
const Relation = @import("Relation.zig");
const WalkContext = @import("WalkContext.zig");

const Error = Relation.Error;

/// The contract of a closure's head: a fixed contract's own, else its code's, if it has one yet.
pub fn contractOf(cx: WalkContext.Context, head: u32) ?Contract.Id {
    return if (head & Contract.fixed_bit != 0) head & ~Contract.fixed_bit else cx.contractOf(cx.ctx, head);
}

/// Whether the code or fixed contract `head` has a label with a need.
pub fn wants(contracts: *const Contract.Table, cx: WalkContext.Context, head: u32) bool {
    const c = contractOf(cx, head) orelse return false;
    for (contracts.labelsOf(contracts.head(c).labels)) |l| if (l.need.len != 0) return true;
    return false;
}

/// Whether one of the frame's `closures` has a need: else nothing in the frame carries one.
pub fn any(contracts: *const Contract.Table, cx: WalkContext.Context, closures: anytype) bool {
    for (closures) |c| if (wants(contracts, cx, c.code)) return true;
    return false;
}

/// The frame's closures with a need that leaves `ls` reach, as indices into
/// `closures`, each once, appended to `out`. A closure's own leaf reaches what
/// it captures (its kids: captures, a partial application's arguments); a call's
/// or a supply's leaf what arrives in it; a loan what the cell holds; a `⊤` its origin.
pub fn reached(ev: *Relation.Eval, cx: WalkContext.Context, closures: anytype, ls: []const u32, out: *std.ArrayList(u32)) Error!void {
    const gpa = ev.gpa();
    const f = ev.f;
    // Every element of a set, whatever pass a reader is in (§2.3.4).
    const saved = ev.pass;
    ev.pass = 0;
    defer ev.pass = saved;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, ls);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    while (stack.pop()) |li| {
        if ((try seen.getOrPut(gpa, .{li})).found_existing) continue;
        try ev.charge(.inspection, 1);
        const l = f.leafAt(li);
        if (ev.expandable(l)) {
            try ev.expand(li, &stack);
            continue;
        }
        switch (l.kind) {
            .site => for (closures, 0..) |c, i| if (c.inst == l.atom) {
                if (wants(ev.contracts, cx, c.code) and !listed(out.items, @intCast(i))) try out.append(gpa, @intCast(i));
                try ev.leavesOf(c.value, 0, &stack);
            },
            .loan => try stack.append(gpa, l.atom),
            .top => if (l.root != Ids.none_int) try Origin.leaves(ev, l, &stack),
            else => {},
        }
    }
}

/// Whether closure index `i` is in `out` already (a handful: the frame's closures with a need).
fn listed(out: []const u32, i: u32) bool {
    for (out) |o| if (o == i) return true;
    return false;
}
