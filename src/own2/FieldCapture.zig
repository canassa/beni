//! L8: a closure's field captures (`docs/design/ownership-v2.md` §2.11.4,
//! *A field capture*; R-5.4.6; `ownership-checker.md` §31.6). A frame, a
//! lambda's or a local function's, that names a captured local only as the
//! base of a field access reads those fields when the closure is made, and
//! holds their values, not the record. So the creation is a read of each
//! field, which a write before it hoists, and a write of the record after it
//! is no write of what the closure holds. The rule is read off the text,
//! because the lowering must find the same captures. The record pass only.
//!
//! Obligations kept here: O7's capture half (a closure that holds a record
//! whole is a holder of it; one that reads fields holds their values).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// Captured local `l` of the frame made at instruction `i`, whose value is `v`: where every reference to
/// `l` in the frame is the base of a field access, the closure's kid for it (a record of those fields'
/// values, with no object of its own) is appended to `kids`, each field is a read event of `l` at `i` and a
/// use of the field's value, and the answer is true. False: the frame uses `l` whole.
pub fn of(k: anytype, i: u32, l: u32, v: u32, kids: *std.ArrayList(u32)) Error!bool {
    if (@import("Mutate.zig").on(.field_capture_whole)) return false;
    const fr = k.f();
    var r = k.w.regions.get(k.w.regions.regionOf(k.data(i).rhs));
    while (r.kind != .frame) : (r = k.w.regions.get(r.parent)) if (r.kind == .body) return false;
    var ranks: std.ArrayList(u32) = .empty;
    defer ranks.deinit(k.gpa);
    // Each field's first access in the lambda: the read that a hoist row names (§2.8).
    var reads: std.ArrayList(u32) = .empty;
    defer reads.deinit(k.gpa);
    try k.charge(.inspection, r.end - r.start + 1);
    var x = r.start;
    while (x <= r.end) : (x += 1) {
        if (k.tag(x) != .local or k.data(x).lhs != l) continue;
        const c = k.consumer[k.rel(x)];
        if (c == none or k.tag(c) != .field_access or k.data(c).lhs != x) return false;
        const rank = k.ctx.fieldRank(k.ctx.ctx, @fromBackingInt(k.data(c).rhs));
        if (std.mem.indexOfScalar(u32, ranks.items, rank) == null) {
            try ranks.append(k.gpa, rank);
            try reads.append(k.gpa, c);
        }
    }
    if (ranks.items.len == 0) return false;
    var vals: std.ArrayList(u32) = .empty;
    defer vals.deinit(k.gpa);
    const root = try fr.places.rootPath(k.gpa, try k.placeOfLocal(l));
    for (ranks.items, reads.items) |rank, read| {
        const st = try Place.Step.field(fr.account, rank);
        try fr.charge(.use, 1);
        try vals.append(k.gpa, try k.project(v, .plain, st.word(), 0));
        try k.w.events.append(k.gpa, .{ .local = l, .path = root, .point = i, .value = v, .rank = st.payload, .read = read });
        // A field that a path names is used at that path; a field that no path names has its event only.
        if (try fr.places.extend(k.gpa, fr.gc(), root, st)) |at| {
            k.atom.* += 1;
            try k.w.uses.append(k.gpa, .{ .local = l, .path = at, .point = i, .kind = .whole, .region = k.w.regions.regionOf(i), .use_node = .none, .atom = k.atom.* });
        }
    }
    try kids.append(k.gpa, try k.recordOf(i, ranks.items, vals.items, 0, none));
    return true;
}
