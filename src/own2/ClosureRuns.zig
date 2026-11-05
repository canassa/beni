//! L11: what a closure run by unknown code runs in turn
//! (`docs/design/ownership-v2.md` §2.11.3, *a function value goes where a
//! value goes*). A closure that escapes is called by code nobody sees, so
//! a function it captures and calls, hands on or lets escape is run by
//! unknown code too, and it escapes. Before this a closure reaching a
//! callee in a list of two met no rule, and what its label wrote was judged
//! by nobody (#2041).
//!
//! Obligations kept here: O1's half for a closure's captured functions.

const std = @import("std");
const Ids = @import("Ids.zig");
const Eval = @import("Eval.zig");
const FnRun = @import("FnRun.zig");
const Relation = @import("Relation.zig");

/// One closure of the frame, escaped at `point` (`none`: where it stands).
fn runs(e: *Eval.Evaluation, atom: u32, point: u32, call: u32) Eval.Error!void {
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
            try Eval.escapeFns(e, caps[lab.j - sig.own], f.slots.relWords(lab.slot), .run, at, call);
        }
        for (e.contracts.effectsOf(h.escapes)) |x| {
            if (x.j < sig.own or x.j - sig.own >= caps.len) continue;
            try Eval.escapeFns(e, caps[x.j - sig.own], f.slots.relWords(x.slot), if (x.deep) .run_deep else .run, at, call);
            // What the code lets escape has escaped, data too, once the code runs unseen.
            var ps: std.ArrayList(Relation.Proj) = .empty;
            defer ps.deinit(e.gpa());
            try e.ev.project(caps[x.j - sig.own], f.slots.relWords(x.slot), x.deep, 0, 0, &ps);
            for (ps.items) |p| try Eval.addEscape(e, p.leaf, at);
        }
    }
}

/// Whether closure `cl`'s contract writes, or names a capture in a label or
/// an escape: whether its escape matters.
fn hasRuns(e: *Eval.Evaluation, cl: anytype) Eval.Error!bool {
    const c = e.ctx.contractOf(e.ctx.ctx, cl.code) orelse return false;
    const h = e.contracts.head(c);
    const own = (try e.ctx.codeSig(e.ctx.ctx, cl.code)).own;
    if (h.writes.len != 0) return true;
    for (e.contracts.labelsOf(h.labels)) |lab| if (lab.j >= own) return true;
    for (e.contracts.effectsOf(h.escapes)) |x| if (x.j >= own) return true;
    return false;
}

/// Each escaped closure's captured functions, escaped in turn. By index:
/// a captured closure is added as it is met. A closure stored by a callee
/// or spawned is an escape of the value that holds it, written out here.
pub fn labels(e: *Eval.Evaluation) Eval.Error!void {
    const f = e.fr();
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
        for (e.fn_escapes.items[0..i]) |o| {
            if (f.leafAt(o.leaf).atom == atom) break;
        } else try runs(e, atom, es.point, es.call);
        i += 1;
    }
}
