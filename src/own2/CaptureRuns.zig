//! L9: a known code's capture written through a label, and how often the code runs (`docs/design/ownership-v2.md`
//! §2.11.4, R-2.8; §2.11.3, *a closure handed back*). A virtual call's write of one of its own parameters is a write
//! of what its label is handed; where that is, at some label outward, a capture of an outer known code (a closure's
//! capture, a called code's `D` parameter: `λ⊤ → f y`, `mk y g = λ⊤ → g y`), it is a capture write of that code, made
//! at each of its runs; a closure a walked call runs and hands back runs again wherever the frame runs it after
//! (`handedAgain`). Split from `Closures`, which marks such a write `many`.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve` refuses a `many` write `once`).

const std = @import("std");
const Ids = @import("Ids.zig");
const LabelChain = @import("LabelChain.zig");
const Relation = @import("Relation.zig");
const FnSite = @import("FnSite.zig");

const Error = @import("Value.zig").Error;
const none: u32 = Ids.none_int;

/// How many labels outward a write is followed; past that it is `many`.
const max_depth = 32;

/// Whether the frame's closure `cv`, made at instruction `site`, runs under two calls of the walk (its own run is
/// one), one of which runs it and hands it back: their runs add up (§2.11.3, *a closure handed back*).
pub fn handedAgain(ev: *Relation.Eval, c: LabelChain.Chain, cv: u32, site: u32) Error!bool {
    var first: u32 = none;
    var two = false;
    for (0..2) |pass| for (c.f.calls.items, 0..) |call, q| if (call.callee_val == cv) {
        var r: u32 = @intCast(q);
        while (LabelChain.virtualOuter(c, r)) |o| r = o[0];
        const rc = c.f.calls.items[r];
        if (pass == 0) {
            if (first == none) first = r else if (first != r) two = true;
        } else if (two and !rc.virtual and rc.callee_val != cv and try FnSite.handsBack(ev, r, site)) return true;
    };
    return false;
}

/// Whether a write of call `q`'s argument `k`, `q` a run of a known code, writes a capture of a known code that may
/// run more than once: `q`'s own capture where `q`'s label may call it again (its `calls` many, or two labels of one
/// function slot) or `q` is made under a run of a closure in `again` (`handedAgain`); or, through the arrivals of
/// each label outward, a capture of an outer known code that runs more than once so.
pub fn many(c: LabelChain.Chain, q: u32, k: u32, again: []const u32) Error!bool {
    if (c.f.calls.items[q].callee_val == none) return false;
    if (k < ownOf(c, q)) return outward(c, q, k, 0, again);
    if (handed(c, q, again)) return true;
    const outer = LabelChain.virtualOuter(c, q) orelse return false;
    const labels = c.contracts.labelsOf(c.contracts.head(c.f.calls.items[outer[0]].contract).labels);
    const lab = labels[outer[1]];
    var same: u32 = 0;
    for (labels) |l| same += @intFromBool(l.j == lab.j and l.slot == lab.slot);
    return lab.calls == .many or same > 1;
}

/// Whether run `q`, or a run it is made under, is of a closure in `again`.
fn handed(c: LabelChain.Chain, q: u32, again: []const u32) bool {
    var cur = q;
    while (true) : (cur = (LabelChain.virtualOuter(c, cur) orelse return false)[0]) {
        for (again) |v| if (v == c.f.calls.items[cur].callee_val) return true;
    }
}

/// `q`'s own parameter `k`, read at the label that runs `q`: each parameter of the outer call it arrives from, a
/// capture there asking whether the outer code runs more than once at any level outward.
fn outward(c: LabelChain.Chain, q: u32, k: u32, depth: u32, again: []const u32) Error!bool {
    if (depth > max_depth) return true;
    const o = LabelChain.virtualOuter(c, q) orelse return false;
    if (c.f.calls.items[o[0]].callee_val == none) return false;
    const own = ownOf(c, o[0]);
    for (c.contracts.suppliesOf(LabelChain.labelAt(c, o).supplies)) |su| if (su.k == k) for ((try LabelChain.entriesOf(c, su.res_root)).items.items) |rs| for (rs.arrivals) |a| {
        if (try reaches(c, o[0], own, a, depth, again)) return true;
    };
    return false;
}

/// Whether arrival `a` at run `o` (of `own` own parameters), written, is a capture of a code run more than once: a
/// capture of `o`, a parameter of `o` followed outward, or another label's answer (`λ⊤ → f (g ⊤)`, `g = λ⊤ → l`)
/// read through the known code it applies. A fresh object is no capture; anything else is asked of `o`'s runs.
fn reaches(c: LabelChain.Chain, o: u32, own: usize, a: anytype, depth: u32, again: []const u32) Error!bool {
    if (depth > max_depth) return true;
    return switch (a.kind) {
        .param => if (a.j >= own) (LabelChain.outwardMany(c, o) or handed(c, o, again)) else try outward(c, o, a.j, depth + 1, again),
        .fresh => false,
        .cb => blk: {
            const r = c.alts.codes(c.known, o, a.j) orelse break :blk (LabelChain.outwardMany(c, o) or handed(c, o, again));
            for (r[0]..r[0] + r[1]) |vm| for ((try LabelChain.entriesOf(c, c.contracts.head(c.f.calls.items[vm].contract).res_root)).items.items) |rs| for (rs.arrivals) |b| {
                if (try reaches(c, @intCast(vm), ownOf(c, @intCast(vm)), b, depth + 1, again)) break :blk true;
            };
            break :blk false;
        },
        else => (LabelChain.outwardMany(c, o) or handed(c, o, again)),
    };
}

/// The number of call `q`'s own parameters: its arguments but the closure's captures.
fn ownOf(c: LabelChain.Chain, q: u32) usize {
    const call = c.f.calls.items[q];
    return call.args.len - c.f.kidsOf(c.f.val(call.callee_val)).len;
}
