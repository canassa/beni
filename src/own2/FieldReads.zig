//! L8: a record's fields read, in a contract's `reads`
//! (`docs/design/ownership-v2.md` §2.8, *Dead, by field*; §2.10, *Effects
//! as trees*; R-4.8.2, R-4.8.5). A read of one field of a parameter's record
//! is a mark of that field at the record's slot (`FieldMark.of`), so a
//! caller that updated the record before asks the callee's reads by field
//! (`FieldMark.reads`). The record pass only makes the events.
//!
//! Obligations kept here: O7's read half (a callee's read of a written
//! field is found; a read of an untouched field is none).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");

const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// The record objects the frame's events read: the storage of each record a field is read of or an update
/// keeps fields of. The read-off says a parameter's among them as a read of its slot, so a caller that writes
/// the record first sees the callee's read (R-4.8.2). A field read says its field (`FieldMark.of`), so
/// that a callee that reads only an untouched field is no whole use (R-4.8.5); an update reads its record whole.
pub fn events(w: anytype, s: anytype, effects: anytype) Error!void {
    if (@import("Mutate.zig").on(.update_reads_off)) return;
    const f = &w.f;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(f.gpa);
    for (w.events.items) |x| {
        ls.clearRetainingCapacity();
        try s.e.ev.storageOf(x.value, 0, &ls);
        const field: Slots.Rel = if (x.rank == none or @import("Mutate.zig").on(.field_reads_whole)) 0 else try f.slots.relOfWords(f.gpa, f.account, f.places, &.{(try Place.Step.field(f.account, x.rank)).word()});
        for (ls.items) |li| {
            const l = f.leafAt(li);
            // A parameter's record: a plain read of its own slot. An open record's storage is held as a whole
            // subtree (§2.3.1), which `effects` reads deep, and a field read reads nothing below the record.
            if (l.kind != .ref or f.roots.items[l.root].kind != .param) {
                try effects(s, li, false, .reads);
            } else for (f.slots.elems(l.slots)) |sl| {
                if (!Slots.isNot(sl)) _ = try Contract.Draft.addEffect(&s.d.reads, s.arena, .{ .j = f.roots.items[l.root].a, .slot = try f.slots.relOf(f.gpa, f.account, f.places, Slots.pathOf(sl)), .field = field });
            }
        }
    }
}

/// A callee's plain read `marks` at a slot, read at leaf `li` of the frame: where every mark is a field's and
/// the leaf is a parameter's, the same fields of that parameter's slot, and true. Else false: the caller
/// reads the leaf whole.
pub fn through(s: anytype, li: u32, marks: []const Contract.Arrival) Error!bool {
    const f = s.e.fr();
    const l = f.leafAt(li);
    if (marks.len == 0 or l.kind != .ref or f.roots.items[l.root].kind != .param) return false;
    for (marks) |a| if (a.kind != .param) return false;
    for (f.slots.elems(l.slots)) |sl| {
        if (Slots.isNot(sl) or Slots.isSub(sl)) return false;
    }
    for (f.slots.elems(l.slots)) |sl| for (marks) |a| {
        _ = try Contract.Draft.addEffect(&s.d.reads, s.arena, .{ .j = f.roots.items[l.root].a, .slot = try f.slots.relOf(f.gpa, f.account, f.places, Slots.pathOf(sl)), .field = a.slot });
    };
    return true;
}
