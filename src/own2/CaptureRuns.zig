//! L9: a known code's capture written through a label, and how often the
//! code runs (`docs/design/ownership-v2.md` §2.11.4, R-2.8; §2.11.3, *a
//! closure handed back*). A virtual call's write of one of its own
//! parameters is a write of what its label is handed; where that is, at some
//! label outward, a capture of an outer known code (a closure's capture, a
//! called code's `D` parameter: `λ⊤ → f y`, `mk y g = λ⊤ → g y`), it is a
//! capture write of that code, made at each of its runs. Split from
//! `Closures`, which marks such a write `many` where the code may run again.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve` refuses a
//! `many` write `once`).

const Ids = @import("Ids.zig");
const LabelChain = @import("LabelChain.zig");

const Error = @import("Value.zig").Error;
const none: u32 = Ids.none_int;

/// How many labels outward a write is followed; past that it is `many`.
const max_depth = 32;

/// Whether a write of virtual call `q`'s argument `k` writes a capture of a
/// known code that may run more than once: `q`'s own capture where `q`'s
/// label may call it again (its `calls` many, or two labels of one function
/// slot); or, through the arrivals of each label outward, a capture of an
/// outer known code that any label outward runs more than once.
pub fn many(c: LabelChain.Chain, q: u32, k: u32) Error!bool {
    const call = c.f.calls.items[q];
    if (!call.virtual or call.callee_val == none) return false;
    if (k >= ownOf(c, q)) {
        const outer = LabelChain.virtualOuter(c, q) orelse return false;
        const labels = c.contracts.labelsOf(c.contracts.head(c.f.calls.items[outer[0]].contract).labels);
        const lab = labels[outer[1]];
        var same: u32 = 0;
        for (labels) |l| {
            if (l.j == lab.j and l.slot == lab.slot) same += 1;
        }
        return lab.calls == .many or same > 1;
    }
    return outward(c, q, k, 0);
}

/// `q`'s own parameter `k`, read at the label that runs `q`: each parameter
/// of the outer call it arrives from, a capture there asking whether the
/// outer code runs more than once at any level outward.
fn outward(c: LabelChain.Chain, q: u32, k: u32, depth: u32) Error!bool {
    if (depth > max_depth) return true;
    const o = LabelChain.virtualOuter(c, q) orelse return false;
    const oc = c.f.calls.items[o[0]];
    if (!oc.virtual or oc.callee_val == none) return false;
    const own = ownOf(c, o[0]);
    for (c.contracts.suppliesOf(LabelChain.labelAt(c, o).supplies)) |su| if (su.k == k) for ((try LabelChain.entriesOf(c, su.res_root)).items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param) continue;
        if (if (a.j >= own) LabelChain.outwardMany(c, o[0]) else try outward(c, o[0], a.j, depth + 1)) return true;
    };
    return false;
}

/// The number of virtual call `q`'s own parameters: its arguments but the closure's captures.
fn ownOf(c: LabelChain.Chain, q: u32) usize {
    const call = c.f.calls.items[q];
    return call.args.len - c.f.kidsOf(c.f.val(call.callee_val)).len;
}
