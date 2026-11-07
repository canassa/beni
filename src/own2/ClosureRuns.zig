//! L12: what a closure run by unknown code runs in turn
//! (`docs/design/ownership-v2.md` §2.11.3, *a function value goes where a
//! value goes*): a function it captures and calls, hands on or lets escape
//! is run by unknown code too, and it escapes (#2041).
//!
//! Obligations kept here: O1's half for a closure's captured functions.

const std = @import("std");
const Ids = @import("Ids.zig");
const Eval = @import("Eval.zig");
const FnRun = @import("FnRun.zig");
const Answers = @import("ClosureAnswers.zig");
const AnswerRead = @import("AnswerRead.zig");
const Loans = @import("Loans.zig");

/// One closure of the frame, escaped at `point` (`none`: where it stands).
fn runs(e: *Eval.Evaluation, atom: u32, point: u32, call: u32, read: bool) Eval.Error!void {
    if (@import("Mutate.zig").on(.closure_runs_off)) return;
    const f = e.fr();
    for (e.w.closures.items) |cl| {
        if (cl.inst != atom) continue;
        const c = e.ctx.contractOf(e.ctx.ctx, cl.code) orelse continue;
        const h = e.contracts.head(c);
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const caps = f.kidsOf(f.val(cl.value));
        const at = if (point == Ids.none_int) cl.point else point;
        for (e.contracts.labelsOf(h.labels)) |lab| {
            if (lab.j < sig.own or lab.j - sig.own >= caps.len) continue;
            // Run by code that only reads its answer, what the closure runs answers into that read.
            const kept = read and try Loans.supply(f, e.contracts, lab) == null and try AnswerRead.of(e.chain(), c, lab.j, true);
            try Eval.escapeFns(e, caps[lab.j - sig.own], f.slots.relWords(lab.slot), if (kept) .run_read else .run, at, call);
        }
        try Answers.supplied(e, c, sig.own, caps, at);
        for (e.contracts.effectsOf(h.escapes)) |x| {
            if (x.j < sig.own or x.j - sig.own >= caps.len) continue;
            try Eval.escapeFns(e, caps[x.j - sig.own], f.slots.relWords(x.slot), if (x.deep) .run_deep else .run, at, call);
            try Answers.gone(e, caps[x.j - sig.own], x.slot, x.deep, at);
        }
    }
}

/// Whether closure `cl`'s escape matters: it writes, or names a capture.
fn hasRuns(e: *Eval.Evaluation, cl: anytype) Eval.Error!bool {
    const c = e.ctx.contractOf(e.ctx.ctx, cl.code) orelse return false;
    const h = e.contracts.head(c);
    const own = (try e.ctx.codeSig(e.ctx.ctx, cl.code)).own;
    if (h.writes.len != 0) return true;
    for (e.contracts.labelsOf(h.labels)) |lab| if (lab.j >= own) return true;
    for (e.contracts.effectsOf(h.escapes)) |x| if (x.j >= own) return true;
    return Answers.namesCapture(e, c, own);
}

/// Each escaped closure run, by index: a captured closure is added as it is met.
pub fn labels(e: *Eval.Evaluation) Eval.Error!void {
    const f = e.fr();
    try Answers.labelled(e);
    // Reading an escape costs an expansion: only where a closure's escape matters.
    const wide = for (e.w.closures.items) |cl| {
        if (try hasRuns(e, cl)) break true;
    } else false;
    var i: usize = 0;
    var k: usize = 0;
    var sites: std.ArrayList(u32) = .empty;
    defer sites.deinit(e.gpa());
    while (true) {
        while (wide and k < e.escapes.items.len) : (k += 1) {
            const es = e.escapes.items[k];
            sites.clearRetainingCapacity();
            try FnRun.sitesOf(&e.ev, e.ctx, e.w.closures.items, es.leaf, &sites);
            for (sites.items) |l| if (f.leafAt(l).kind == .site) try e.fn_escapes.append(e.gpa(), .{ .leaf = l, .point = es.point, .call = es.call });
        }
        if (i == e.fn_escapes.items.len) return;
        const es = e.fn_escapes.items[i];
        const atom = f.leafAt(es.leaf).atom;
        var ran, var left = .{ false, es.read };
        for (e.fn_escapes.items[0..i]) |o| if (f.leafAt(o.leaf).atom == atom) {
            ran = true;
            left = left or !o.read;
        };
        if (!ran or !left) try runs(e, atom, es.point, es.call, es.read);
        if (!left) try Answers.of(e, atom, es.point);
        i += 1;
    }
}
