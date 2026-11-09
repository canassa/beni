//! L12: what a frame edits after it handed it to a label
//! (`docs/design/ownership-v2.md` §2.11.3, *a need on a supply*). The label's
//! code is the caller's, and it may keep what it is handed (a task, a fiber,
//! a stored closure): a write the frame makes later, of an object it handed
//! there, holds only if the code keeps nothing of it. The frame cannot judge
//! that, so it publishes a need on the label's supply, and the caller
//! discharges it where the code is known (`Needs`, `KeepsNot`).
//!
//! Obligations kept here: O14's need half (every write after a hand-over
//! that may meet the handed object publishes the need).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Regions = @import("Regions.zig");
const Value = @import("Value.zig");
const Place = @import("Place.zig");
const Eval = @import("Eval.zig");
const Needs = @import("Needs.zig");

const Error = Eval.Error;
const none: u32 = Ids.none_int;

/// An object handed to frame label `cb` as its argument `k` at `point`, by call `call` (`none`: a direct call).
const Handed = struct { cb: u32, k: u32, leaf: u32, point: u32, call: u32 };

/// The demands of evaluation `x` made since its last pass, each against every object the frame handed a label:
/// one that may meet such an object, at or after the hand-over in a compatible region (§2.5), and not the
/// handing call's own write (the callee orders its own, and publishes its need), publishes the need on that
/// label's argument, whole and deep. True when something new was published.
pub fn pass(st: *Needs.State, e: *Eval.Evaluation, x: u32, regions: *const Regions.Tree) Error!bool {
    if (@import("Mutate.zig").on(.handed_writes_off)) return false;
    while (st.handed.items.len <= x) try st.handed.append(e.gpa(), none);
    const first = st.handed.items[x] == none;
    const from = if (first) 0 else st.handed.items[x];
    st.handed.items[x] = @intCast(e.demands.items.len);
    if (!first and from == e.demands.items.len) return false;
    var hs: std.ArrayList(Handed) = .empty;
    try handedAll(e, &hs);
    if (hs.items.len == 0) return false;
    var new = false;
    if (first) new = try answered(e, hs.items);
    for (e.demands.items[from..]) |d| {
        // A cell operation replaces what a cell holds: a holder of the cell is meant to see it (§2.13.7).
        if (d.need or d.supplied or d.cell) continue;
        const ts = e.w.leavesOfRun(d.targets);
        for (hs.items) |h| {
            if (h.call != none and h.call == d.call) continue;
            if (d.point != h.point and !regions.afterCompatible(h.point, d.point)) continue;
            for (ts) |t| {
                const ov = try Distinct.overlap(&e.ev, h.leaf, t, false);
                // Apart under a condition on the parameters: the write's own conditions hold it (a caller's operand
                // rule keeps a written argument apart from the others, an element's write relies on its family's separation).
                if (ov.kind != .may and !(ov.kind == .under and ov.cond.no)) continue;
                new = try Needs.publish(&e.sink, h.cb, h.k + 1, Slots.root, true) or new;
                break;
            }
        }
    }
    return new;
}

/// What the frame handed its labels: a direct call's arguments, deep; a passed-on label's supplies, by
/// what arrives at them in the call (§2.11.3). A top-level value, `⊤` and a host object are never written.
fn handedAll(e: *Eval.Evaluation, out: *std.ArrayList(Handed)) Error!void {
    const f = e.fr();
    const a = e.ev.arena;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(e.gpa());
    for (f.cbs.items, 0..) |cb, ci| if (cb.inst != none) for (cb.args, 0..) |v, k| {
        ps.clearRetainingCapacity();
        try e.ev.project(v, &.{}, true, 0, 0, &ps);
        for (ps.items) |p| if (writable(f.leafAt(p.leaf).kind)) try out.append(a, .{ .cb = @intCast(ci), .k = @intCast(k), .leaf = p.leaf, .point = cb.point, .call = none });
    };
    for (e.passes.items) |p| {
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| for ((try Eval.entriesOf(e, su.res_root)).items.items) |rs| for (rs.arrivals) |ar| {
            ls.clearRetainingCapacity();
            if (ar.kind == .param and ar.j < call.args.len) {
                ps.clearRetainingCapacity();
                try e.ev.project(call.args[ar.j], f.slots.relWords(ar.slot), true, 0, 0, &ps);
                for (ps.items) |x| try ls.append(e.gpa(), x.leaf);
            } else if (ar.kind != .top and ar.kind != .host and ar.kind != .shared and ar.kind != .fresh) try e.ev.arrivalLeaves(p[1], call.contract, ar, &.{}, &ls);
            for (ls.items) |l| if (writable(f.leafAt(l).kind)) try out.append(a, .{ .cb = p[0], .k = su.k, .leaf = l, .point = call.point, .call = p[1] });
        };
    }
}

fn writable(k: anytype) bool {
    return k != .top and k != .host and k != .shared;
}

/// An object the frame made and handed a label, that its answer may hold: a caller may edit the answer
/// later, out of the frame's sight, so the need is published here (a caller reads such a supply as `fresh`
/// and skips it).
fn answered(e: *Eval.Evaluation, hs: []const Handed) Error!bool {
    if (e.w.result == none) return false;
    // An answer that holds only opaque values (a `Js.Value`) is never edited in place by a caller.
    const rp = e.w.code.result_place;
    const places = e.fr().places;
    if (rp == .none or places.holds(rp).join(Place.Kind.own(places.kind(rp))).bits() & ~Place.Holds.bits(.{ .@"opaque" = true }) == 0) return false;
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(e.gpa());
    try e.ev.project(e.w.result, &.{}, true, 0, 0, &ps);
    // Only what the frame made: a label's answer or a parameter's object the answer holds is the caller's to see.
    var n: usize = 0;
    for (ps.items) |p| if (try madeHere(e, p.leaf) and try editable(e, p.leaf)) {
        ps.items[n] = p;
        n += 1;
    };
    var new = false;
    for (hs) |h| {
        if (!try madeHere(e, h.leaf)) continue;
        for (ps.items[0..n]) |p| if ((try Distinct.overlap(&e.ev, h.leaf, p.leaf, false)).kind == .may) {
            new = try Needs.publish(&e.sink, h.cb, h.k + 1, Slots.root, true) or new;
            break;
        };
    }
    return new;
}

/// Whether leaf `x` may be an object the frame made (a construction, a callee's fresh object): a parameter's
/// and a label's answer reach a caller by their own arrivals.
fn madeHere(e: *Eval.Evaluation, x: u32) Error!bool {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(e.gpa());
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(e.gpa());
    // A callee's own object that it hands its label: the callee's answer holding it is the callee's to publish.
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(e.gpa());
    var made: std.ArrayList(u32) = .empty;
    defer made.deinit(e.gpa());
    try stack.append(e.gpa(), x);
    while (stack.pop()) |y| {
        if ((try seen.getOrPut(e.gpa(), .{y})).found_existing) continue;
        const l = e.fr().leafAt(y);
        if (l.kind == .ref and e.fr().roots.items[l.root].kind == .supply) try owners.append(e.gpa(), e.fr().supplies.items[e.fr().roots.items[l.root].a].call);
        if (e.ev.expandable(l)) try e.ev.expand(y, &stack) else if (l.kind == .site or l.kind == .recons) return true else if (l.kind == .fresh and !try hostWhole(e, l)) try made.append(e.gpa(), l.atom);
    }
    outer: for (made.items) |c| {
        for (owners.items) |o| if (o == c) continue :outer;
        return true;
    }
    return false;
}

/// Whether `x` is a callee's fresh object whose every slot may be a host object (`ε… host`, a `Js.Value`): no
/// write of it is accepted anywhere (§2.10, *host objects*), so no caller edits it.
fn hostWhole(e: *Eval.Evaluation, l: Value.Leaf) Error!bool {
    const c = e.ev.contractOf(l.atom) orelse return false;
    for ((try Eval.entriesOf(e, e.contracts.head(c).res_root)).items.items) |rs| if (rs.open and rs.len == 0) {
        for (rs.arrivals) |a| if (a.kind == .host) return true;
    };
    return false;
}

/// Whether leaf `x` may be an object edited in place: a construction of a record, a tuple, a constructor or a
/// closure never is (what it holds is a leaf of its own); a list, a dictionary, a cell or a callee's object may be.
fn editable(e: *Eval.Evaluation, x: u32) Error!bool {
    const l = e.fr().leafAt(x);
    if (l.kind != .site) return true;
    const k = e.fr().places.kind(try e.ctx.placeOfInst(e.ctx.ctx, l.atom));
    return k != .record and k != .tuple and k != .ctor and k != .closure;
}
