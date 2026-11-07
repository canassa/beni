//! L8: whether an entry of the distinct check is one set of arrivals
//! (`docs/design/ownership-v2.md` §2.9.2, §2.1, *The row of a record*), split from
//! `Entries`.
//!
//! Obligations kept here: the half of O3 that a slot no expansion can count is
//! never read as apart.

const Slots = @import("Slots.zig");
const Entries = @import("Entries.zig");
const Value = @import("Value.zig");

/// Whether an entry's arrivals are one set, so expansion cannot count them (#1710): a
/// slot of a type variable's or an opaque place, or a subtree held whole. A record's row
/// is not: a caller reads it at its own steps (§2.1), so what a cast put at two fields of
/// a row is two entries there, and a row's arrival is counted where it is read.
pub fn of(f: *Value.Frame, en: Entries.Ent) bool {
    for (f.slots.elems(f.leafAt(en.leaf).slots)) |x| {
        if (Slots.isNot(x)) continue;
        const p = Slots.pathOf(x);
        if (f.places.pathParent(p) != .none and f.places.pathStep(p).isRow()) continue;
        if (Slots.isSub(x)) return true;
        switch (f.places.kind(f.places.pathPlace(p))) {
            .@"var", .@"opaque" => return true,
            else => {},
        }
    }
    return false;
}
