//! L5: a plain arrival at a type variable's slot is open (`docs/design/ownership-v2.md` §2.1,
//! *One below*): no step below the slot names what it holds, so a reader of a slot below it,
//! at a caller's instance too, must meet it there, and `CallFolds` reads open arrivals only.
//! `Put.arrive` and the rows (`RowEnv`) mark such a slot open; under runtime safety each
//! function's result is checked when it is committed (`Groups`).
//!
//! Obligations kept here: none of §2.14's directly (it checks O6's premise under runtime safety).

const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");

/// Panics where a plain arrival of result `r` (of place `result`) is at a `var` slot.
pub fn check(r: *const Contract.Draft.Res, slots: *const Slots.Table, places: *const Place.Table, result: Ids.PlaceId) void {
    items: for (r.items.items) |it| {
        if (it.node != 0 or r.isOpen(it)) continue;
        var p = result;
        for (slots.relWords(it.slot)) |w| {
            const st = Place.Step.fromWord(w);
            if (st.isRow() or st.kind == .level) continue :items;
            p = places.child(p, st) orelse continue :items;
        }
        if (places.kind(p) == .@"var") @panic("a plain arrival at a type variable's slot");
    }
}
