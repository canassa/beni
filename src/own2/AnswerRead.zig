//! L9: whether known code only reads what it runs a parameter for
//! (`docs/design/ownership-v2.md` §2.11.3, *a function value goes where a value
//! goes*). What a closure answers such a run stays in that code (#2059).
//!
//! Obligations kept here: none of §2.14's directly.

const Contract = @import("Contract.zig");
const LabelChain = @import("LabelChain.zig");
const Value = @import("Value.zig");

const Error = Value.Error;

/// Whether contract `c` only reads what it runs parameter `j` for: nothing of
/// it, and no answer of it, leaves in a result (`res_ok`: bar that one), a supply,
/// an escape or a store.
pub fn of(c: LabelChain.Chain, k: Contract.Id, j: u32, res_ok: bool) Error!bool {
    const h = c.contracts.head(k);
    if (h.flags.pessimistic) return false;
    for (c.contracts.effectsOf(h.escapes)) |x| if (x.j == j) return false;
    for (c.contracts.storesOf(h.stores)) |x| if (x.j == j) return false;
    const labels = c.contracts.labelsOf(h.labels);
    for (labels) |l| if (l.j == j and l.answer_left) return false;
    if (!res_ok and try holdsParam(c, labels, h.res_root, j)) return false;
    for (labels) |l| for (c.contracts.suppliesOf(l.supplies)) |s| if (try holdsParam(c, labels, s.res_root, j)) return false;
    return true;
}

fn holdsParam(c: LabelChain.Chain, labels: []const Contract.Label, root: Contract.Node, j: u32) Error!bool {
    for ((try LabelChain.entriesOf(c, root)).items.items) |rs| for (rs.arrivals) |a| {
        if ((a.kind == .param or a.kind == .lent) and a.j == j or a.kind == .cb and labels[a.j].j == j) return true;
    };
    return false;
}
