//! L9: a closure the checker cannot follow to every call
//! (`docs/design/ownership-v2.md` §2.11.3, §2.11.4).
//!
//! A closure whose code writes one of its own parameters relies on its
//! callers to hand it a list nothing else holds. A known caller says what
//! it hands (§2.11.3: a label's supplies, the `callsite` demands). Where the
//! closure escapes instead — to a callee with the pessimistic contract, to
//! JavaScript, into a cell, back to its caller in a callee's answer — its
//! caller is unknown and so are its supplies
//! (O1): each such write is a demand on `⊤`, refused `unknown`.
//!
//! A closure whose code writes a capture is `once` (R-2.8): an escape of it,
//! or a callee that may call it more than once (a label whose `calls` is
//! many, or two labels of one function slot), refuses the write, `once`.
//!
//! Obligations kept here: O1 (an unknown caller's supplies are `⊤`).

const std = @import("std");
const Ids = @import("Ids.zig");
const Forest = @import("Forest.zig");
const Relation = @import("Relation.zig");
const Eval = @import("Eval.zig");

const none: u32 = Ids.none_int;

/// After the deliveries, when the evaluation's escapes are all in.
pub fn escapedWrites(e: *Eval.Evaluation) Eval.Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    // What the code returns: a closure in it is called by code that cannot
    // see it (a function value a callee returns is unknown, §2.11.3).
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    if (e.w.result != none) try e.ev.leavesOf(e.w.result, 0, &out);
    // What a callee hands back: a closure among a call's result arrivals is
    // a function value that callee returns, which the caller calls as
    // unknown code (§2.11.3), so its callers are unknown from there on.
    var back: std.ArrayList(Eval.Escape) = .empty;
    defer back.deinit(gpa);
    var back_done = false;
    for (e.w.closures.items) |cl| {
        const c = (e.ctx.contractOf(e.ctx.ctx, cl.code)) orelse continue;
        const h = e.contracts.head(c);
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const writes = e.contracts.effectsOf(h.writes);
        if (writes.len == 0) continue;
        if (!back_done) {
            back_done = true;
            try handedBack(e, &back);
        }
        // Its first escape, else (for a capture write) another closure that
        // captures it, which may call it any number of times (as v1 has it).
        const by: ?Eval.Escape = for (e.w.closures.items) |c2| {
            if (std.mem.indexOfScalar(u32, f.kidsOf(f.val(c2.value)), cl.value) != null) break .{ .leaf = none, .point = c2.point };
        } else null;
        const at = for (e.escapes.items) |es| {
            const l = f.leafAt(es.leaf);
            if (l.kind == .site and l.atom == cl.inst) break es;
        } else for (back.items) |es| {
            const l = f.leafAt(es.leaf);
            if (l.kind == .site and l.atom == cl.inst) break es;
        } else for (out.items) |l| {
            if (f.leafAt(l).kind == .site and f.leafAt(l).atom == cl.inst) break Eval.Escape{ .leaf = l, .point = cl.point };
        } else by orelse continue;
        const caps = f.kidsOf(f.val(cl.value));
        for (writes) |wr| {
            const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
            if (wr.j < sig.own) {
                if (at.leaf == none) continue;
                // A parameter: what an unknown caller hands it is unknown.
                try e.w.leaf_runs.append(gpa, try f.leaf(.{ .kind = .top }));
            } else {
                // A capture: the code may run again.
                if (wr.j - sig.own >= caps.len) continue;
                var ps: std.ArrayList(Relation.Proj) = .empty;
                defer ps.deinit(gpa);
                try e.ev.project(caps[wr.j - sig.own], f.slots.relWords(wr.slot), wr.deep, 0, 0, &ps);
                for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
                if (ps.items.len == 0) continue;
            }
            // Evidence escapes at its site, a call named by its callee.
            const callee = if (at.call != none) f.calls.items[at.call].head else if (e.w.bir.instTag(@fromBackingInt(cl.inst)) == .call) e.w.bir.instData(@fromBackingInt(cl.inst)).lhs else none;
            try e.demands.append(gpa, .{
                .point = at.point,
                .kind = if (callee == none) .once else .callsite,
                .token = Eval.tokenOf(e, if (at.call != none) f.calls.items[at.call].inst else cl.inst),
                .base_inst = cl.inst,
                .callee_inst = callee,
                .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
                .deep = wr.deep,
                .callback = true,
                .many = wr.j >= sig.own,
            });
        }
    }
    // A known code's capture write at a label that may call it again.
    for (e.demands.items) |*d| {
        if (d.call == none or d.call >= f.calls.items.len) continue;
        const call = f.calls.items[d.call];
        if (!call.virtual or call.callee_val == none or d.arg == none) continue;
        const own = call.args.len - f.kidsOf(f.val(call.callee_val)).len;
        if (d.arg < own) continue;
        const outer = Eval.virtualOuter(e, d.call) orelse continue;
        const labels = e.contracts.labelsOf(e.contracts.head(f.calls.items[outer[0]].contract).labels);
        const lab = labels[outer[1]];
        var same: u32 = 0;
        for (labels) |l| {
            if (l.j == lab.j and l.slot == lab.slot) same += 1;
        }
        if (lab.calls == .many or same > 1) d.many = true;
    }
}

/// The objects each call of the walk hands back to the frame through its
/// callee's result: its `res` arrivals of the arguments, projected, as
/// escapes at the call.
fn handedBack(e: *Eval.Evaluation, out: *std.ArrayList(Eval.Escape)) Eval.Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    for (f.calls.items, 0..) |call, q| {
        if (call.contract == none) continue;
        var es: Forest.Entries = .{};
        defer es.deinit(gpa);
        try es.of(&e.contracts.trees, gpa, f.places, e.contracts.head(call.contract).res_root, &.{});
        for (es.items.items) |x| for (x.arrivals) |a| {
            if (a.kind != .param) continue;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try e.ev.arrivalLeaves(@intCast(q), call.contract, a, &.{}, &ls);
            for (ls.items) |l| if (f.leafAt(l).kind == .site) try out.append(gpa, .{ .leaf = l, .point = call.point, .call = @intCast(q) });
        };
    }
}
