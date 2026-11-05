//! L8: an entry of the distinct check expanded (`docs/design/ownership-v2.md`
//! §2.9.3, §2.3.5), split from `Distinct`.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");

/// An entry's expansion (§2.3.5, *a key's leaf*): each leaf without its
/// route set, the set its entry's routes (`rs`), where the entry has none;
/// else each leaf written out, under the entry's routes.
pub fn expand(e: *Relation.Eval, en: Entries.Ent, list: *std.ArrayList(u32), rs: *std.ArrayList(u32)) Relation.Error!void {
    const g = e.gpa();
    if (en.routes != 0) {
        try e.expand(en.leaf, list);
        for (list.items) |_| try rs.append(g, en.routes);
        return;
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
