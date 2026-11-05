//! L11: what a called code's read-off says of what its creation made
//! (`docs/design/ownership-v2.md` §2.11.3, *a function value in a result*).
//! An object the creation made, and the answer of a label it called, came
//! once, when the value was made: at a call of the value they are what the
//! value holds, its `self` parameter deep. In any other code an object is
//! `fresh` and an answer its label's.
//!
//! Obligations kept here: none of §2.14's directly (the caller's arrival
//! says the value's whole holdings, by §2.11.4).

const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const Contract = @import("Contract.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;
const Sink = Eval.Sink;

/// The object `l` (a site's, a call's fresh) as an arrival: `fresh`, or in
/// a called code, for one the creation made, what the value holds (§2.11.3).
pub fn made(s: *Sink, l: Value.Leaf) Error!Contract.Arrival {
    const e = s.e;
    if (e.w.last.calls == 0 or (l.kind == .fresh and e.inLast(l.atom))) return .{ .kind = .fresh };
    return selfArrival(s);
}

fn selfArrival(s: *Sink) Contract.Arrival {
    return .{ .kind = .param, .j = s.e.w.code.arity() - 1, .slot = Slots.root, .deep = true };
}

/// The answer of frame label `cb` at slot `rel` as an arrival. In a called
/// code, a label its creation called was answered once: what the value holds.
pub fn answer(s: *Sink, cb: u32, rel: u32) Error!Contract.Arrival {
    const e = s.e;
    const last = e.w.last.calls == 0 or cb >= e.w.last.cbs and for (e.passes.items) |p| {
        if (p[0] == cb) break true;
    } else e.fr().cbs.items[cb].inst != Ids.none_int;
    return if (last) .{ .kind = .cb, .j = try s.labelIndex(cb), .slot = rel } else selfArrival(s);
}

/// In a called code, an escape of an object the creation made is one of
/// `self` (§2.11.3). Whether `l` is such an object.
pub fn selfEscape(s: *Sink, l: Value.Leaf) Error!bool {
    const e = s.e;
    if (e.w.last.calls == 0 or (l.kind != .site and l.kind != .fresh) or (l.kind == .fresh and e.inLast(l.atom))) return false;
    const eff: Contract.Effect = .{ .j = selfArrival(s).j, .slot = Slots.root, .deep = true };
    if (try Contract.Draft.addEffect(&s.d.escapes, s.arena, eff)) if (e.solver) |sv| try sv.effFact(sv.ctx, e.x, false, eff);
    return true;
}
