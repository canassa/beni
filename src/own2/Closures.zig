//! L9: a closure handed to code the checker cannot see
//! (`docs/design/ownership-v2.md` §2.11.4).
//!
//! A closure whose code writes one of its own parameters relies on its
//! callers to hand it a list nothing else holds. A known caller says what
//! it hands (§2.11.3: a label's supplies, the `callsite` demands). Where the
//! closure escapes instead — to a callee with the pessimistic contract, to
//! JavaScript, into a cell — its caller is unknown and so are its supplies
//! (O1): each such write is a demand on `⊤`, refused `unknown`.
//!
//! Obligations kept here: O1 (an unknown caller's supplies are `⊤`).

const Ids = @import("Ids.zig");
const Eval = @import("Eval.zig");

const none: u32 = Ids.none_int;

/// After the deliveries, when the evaluation's escapes are all in: one
/// demand per escaped closure and parameter write of its code, at the
/// closure's first escape.
pub fn escapedWrites(e: *Eval.Evaluation) Eval.Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    for (e.w.closures.items) |cl| {
        const c = (e.ctx.contractOf(e.ctx.ctx, cl.code)) orelse continue;
        const h = e.contracts.head(c);
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const writes = e.contracts.effectsOf(h.writes);
        const own = for (writes) |wr| {
            if (wr.j < sig.own) break true;
        } else false;
        if (!own) continue;
        const at = for (e.escapes.items) |es| {
            const l = f.leafAt(es.leaf);
            if (l.kind == .site and l.atom == cl.inst) break es;
        } else continue;
        for (writes) |wr| {
            if (wr.j >= sig.own) continue;
            const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
            try e.w.leaf_runs.append(gpa, try f.leaf(.{ .kind = .top }));
            try e.demands.append(gpa, .{
                .point = at.point,
                .kind = .callsite,
                .token = Eval.tokenOf(e, if (at.call != none) f.calls.items[at.call].inst else cl.inst),
                .base_inst = cl.inst,
                .callee_inst = if (at.call != none) f.calls.items[at.call].head else none,
                .targets = .{ .start = t_start, .len = 1 },
                .deep = wr.deep,
                .callback = true,
            });
        }
    }
}
