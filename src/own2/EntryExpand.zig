//! L8: an entry of the distinct check expanded (`docs/design/ownership-v2.md`
//! §2.9.3, §2.3.5), split from `Distinct`.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");

/// An entry's expansion (§2.3.5, *a key's leaf*): each leaf, its route set in `rs` (the entry's, written out,
/// when it has one). In a `block` a fresh-only call is its one atom, which its every leaf is (§7.6 item 6).
pub fn expand(e: *Relation.Eval, en: Entries.Ent, block: bool, list: *std.ArrayList(u32), rs: *std.ArrayList(u32)) Relation.Error!void {
    const g = e.gpa();
    if (block) if (try e.freshOnlyAtom(e.f.leafAt(en.leaf))) |x| {
        try list.append(g, x);
        return rs.append(g, en.routes);
    };
    if (en.routes != 0) {
        try e.expand(en.leaf, list);
        return rs.appendNTimes(g, en.routes, list.items.len);
    }
    try e.expandRouted(en.leaf, list);
    for (list.items) |*x| {
        var l = e.f.leafAt(x.*);
        try rs.append(g, l.routes);
        if (l.routes == 0) continue;
        l.routes = 0;
        x.* = try e.f.leaf(l);
    }
}
