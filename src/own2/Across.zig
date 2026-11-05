//! L9: what a callee may hold across a run of a known code it is handed
//! (`docs/design/ownership-v2.md` §2.11.3, *a capture written across the
//! callee's run*; §2.13.7, #1955). A known code applied at a callee's
//! label runs inside the callee, while the callee holds what it was handed:
//! its other arguments (a closure's captures among them), the contents of
//! every cell they reach (a loan taken of them, `Ref.get r`, is a holder
//! behind the barrier the caller cannot see) and the answers of its other
//! labels. A capture the code writes is the caller's object, so each of
//! these is an operand of that write, at every label outward.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve` judges the
//! operands as it judges a call's other arguments).

const std = @import("std");
const Ids = @import("Ids.zig");
const Value = @import("Value.zig");
const LabelChain = @import("LabelChain.zig");

const Error = Value.Error;
const none: u32 = Ids.none_int;

/// Whether virtual call `q`'s argument `j` is a capture of its code, not a
/// supply: a closure's captures follow its own parameters.
pub fn capture(f: *const Value.Frame, q: u32, j: u32) bool {
    const call = f.calls.items[q];
    if (!call.virtual or call.callee_val == none) return false;
    return j + f.kidsOf(f.val(call.callee_val)).len >= call.args.len;
}

/// The operands of a capture write of virtual call `q`, appended to `out`:
/// at each label outward, the call's arguments but the one that hands the
/// code (the label's function slot is the root of it), and the answers of
/// the call's other labels applied to known codes.
pub fn operands(c: LabelChain.Chain, q: u32, out: *std.ArrayList(u32)) Error!void {
    const f = c.f;
    const gpa = f.gpa;
    var cur = q;
    while (f.calls.items[cur].virtual) {
        const o = LabelChain.virtualOuter(c, cur) orelse return;
        const oc = f.calls.items[o[0]];
        const lab = c.contracts.labelsOf(c.contracts.head(oc.contract).labels)[o[1]];
        const whole = f.slots.relWords(lab.slot).len == 0;
        for (oc.args, 0..) |a, k| if (k != lab.j or !whole) try out.append(gpa, a);
        const it = c.virt.keys.items;
        var i: usize = 0;
        while (i + 1 < it.len) : (i += 2) {
            if (it[i] != o[0] or it[i + 1] == o[1]) continue;
            try out.append(gpa, try f.refRoot(f.calls.items[c.virt.values.items[i / 2]].root));
        }
        cur = o[0];
    }
}
