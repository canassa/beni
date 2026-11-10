//! L8: a record update over its base (`docs/design/ownership-v2.md` §2.6
//! `record_update`, §2.7, §2.8 *Dead*, R-2.5, R-4.8.2), split from `Walk`:
//! the walker is `k`. The update writes its base's object at the written
//! fields; the fields it keeps are the base's. What a frame does with a
//! record's fields afterwards is a table of its own (`Event`), beside the
//! uses a list demand reads, so no list verdict reads it.
//!
//! Obligations kept here: O7 (the written object is the base's, and the kept
//! fields are its) and O2's record half (every later read or keep of a
//! written field through an old holder is found).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Relation = @import("Relation.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const FieldMark = @import("FieldMark.zig");
const Liveness = @import("Liveness.zig");

const Error = Ids.ChargeError;
const PathId = Ids.PathId;
const none: u32 = Ids.none_int;

/// What a frame does with a field of the record at `path` of `local`, at
/// `point` (§2.7): a field chain's step reads field `rank`, its own read,
/// which the lowering can move before a write (a hoist); or, `rank` none,
/// an update of that record writes `fields` and keeps every other field,
/// a read by the update itself, which nothing can move.
/// `value`: the record's value there.
pub const Event = struct { local: u32, path: PathId, point: u32, value: u32, rank: u32 = none, fields: []const u32 = &.{} };

/// Whether value `v` is a record's: a write of its own storage is a record write.
pub fn isRecord(f: anytype, v: u32) bool {
    return recordAt(f, v, &.{});
}

/// Whether the place `words` below value `v` is a record's.
pub fn recordAt(f: anytype, v: u32, words: []const u32) bool {
    const x = f.val(v);
    // A reference read by steps has no place of its own: its position's.
    const at = if (x.place != .none) x.place else if (x.kind == .ref and x.pos != none) f.places.pathPlace(f.pos.items[x.pos].slot) else return false;
    return recordBelow(f, at, words);
}

/// Whether the place `words` below place `at` is a record's. A word no child answers (a level) says no.
pub fn recordBelow(f: anytype, at: Place.PlaceId, words: []const u32) bool {
    var p = at;
    for (words) |wd| p = f.places.child(p, Place.Step.fromWord(wd)) orelse return false;
    return f.places.kind(p) == .record;
}

/// `recordBelow` at parameter `j` of a code whose parameters' places are `params`.
pub fn recordParam(f: anytype, params: []const Place.PlaceId, j: u32, words: []const u32) bool {
    return j < params.len and recordBelow(f, params[j], words);
}

/// Whether need `n` of a label that virtual call `vc` answers is of a record's own object: the
/// answer's (`n.j` 0), or argument `n.j - 1`'s.
pub fn ofNeed(f: anytype, vc: anytype, n: anytype) bool {
    const words = f.slots.relWords(n.slot);
    return f.records and !n.deep and if (n.j == 0) recordBelow(f, f.roots.items[vc.root].place, words) else n.j - 1 < vc.args.len and recordAt(f, vc.args[n.j - 1], words);
}

/// The arrivals of result tree `root`, every node's plain ones before every node's open ones: how
/// many are plain. No tree (`root` 0): the one arrival `one`, plain when `one_plain`.
pub fn arrivalsPlainFirst(t: anytype, gpa: std.mem.Allocator, places: anytype, root: u32, one: anytype, one_plain: bool, out: anytype) Ids.IndexError!usize {
    if (root == 0) {
        try out.append(gpa, one);
        return @intFromBool(one_plain);
    }
    var ns: std.ArrayList(u32) = .empty;
    defer ns.deinit(gpa);
    try Forest.nodes(t, gpa, places, root, &ns);
    for (ns.items) |n| try out.appendSlice(gpa, t.here(n));
    const plain = out.items.len;
    for (ns.items) |n| try out.appendSlice(gpa, t.open(n));
    return plain;
}

/// Whether arrival `a` is a parameter's record at its own slot, by the path the read-off knew.
pub fn ownRecord(f: anytype, a: anytype) bool {
    return !a.deep and a.path < Contract.Arrival.level_copy and f.places.kind(f.places.pathPlace(.from(a.path))) == .record;
}

/// A later-use witness that is an event, as a use id (`pointOf` reads either).
const event_bit: u32 = 0x8000_0000;

pub fn pointOf(w: anytype, u: Liveness.UseId) u32 {
    return if (u.int() & event_bit != 0) w.events.items[u.int() & ~event_bit].point else w.index.get(u).point;
}

/// A callee's write `x` of argument `arg` at `words`, at a call: the demand's token, and whether it
/// writes a record's own storage: by the value, by the argument's place (a top-level value names
/// none) or by the known code's parameter (a type variable's place at the caller). Its fields are
/// the ones that the callee's contract names (`fieldsAt`), where the demand is of `one` route.
pub fn atCall(e: anytype, d: anytype, call: anytype, x: anytype, arg: u32, words: []const u32, base: u32, one: bool) Error!void {
    const f = e.fr();
    d.token = e.w.bir.insts.items(.main_token)[call.inst];
    if (x.deep or d.cell or !f.records) return;
    d.record = isRecord(f, if (words.len == 0) arg else try e.ev.valueAt(arg, words)) or (base != call.inst and recordBelow(f, try e.ctx.placeOfInst(e.ctx.ctx, base), words)) or (call.code != none and recordParam(f, (try e.ctx.codeSig(e.ctx.ctx, call.code)).params, x.j, words));
    // A demand that covers more routes than its own (`Graft.Group.also`) names no field: each route has its fields.
    if (d.record and one and call.contract != none) d.fields = try fieldsAt(e, call.contract, call.code, x.j, words);
}

/// The fields that contract `c` of code `code` writes of the record at `words` of its parameter `j` (the
/// write tree's marks, `FieldMark.written`); none, every field, where the code is a member of the group
/// that is being solved, whose writes still grow.
pub fn fieldsAt(e: anytype, c: Contract.Id, code: u32, j: u32, words: []const u32) Error![]const u32 {
    const f = e.fr();
    if (code != none) if (e.ev.live) |lv| if (lv.draftRes(lv.ctx, code) != null) return &.{};
    try f.charge(.inspection, @intCast(words.len + 1));
    for (e.contracts.writesOf(e.contracts.head(c).writes)) |r| if (r[0] == j) return FieldMark.written(&e.contracts.trees, f.slots, f.arena, r[1], words);
    return &.{};
}

/// `{ base | fields }` at instruction `i` (R-2.5): an `update` demand on the
/// base's storage, and the base's object with the new values at `fields`.
pub fn of(k: anytype, i: u32, fields: anytype, base: u32) Error!u32 {
    const fr = k.f();
    var ranks: std.ArrayList(u32) = .empty;
    defer ranks.deinit(k.gpa);
    var ks: std.ArrayList(u32) = .empty;
    defer ks.deinit(k.gpa);
    // The new values, all evaluated before any store (R-4.8.3).
    const o_start: u32 = @intCast(k.w.value_runs.items.len);
    for (fields) |fl| {
        const v = try k.valueOf(fl.value.int());
        try ranks.append(k.gpa, k.ctx.fieldRank(k.ctx.ctx, fl.name));
        try ks.append(k.gpa, v);
        if (fr.records) try k.w.value_runs.append(k.gpa, v);
        try k.consume(fl.value.int(), i);
    }
    const written = try fr.arena.dupe(u32, ranks.items);
    std.mem.sort(u32, written, {}, std.sort.asc(u32));
    const bv = try k.valueOf(base);
    var ev: Relation.Eval = .{ .f = fr, .contracts = undefined, .arena = fr.arena };
    defer ev.deinit();
    const t_start: u32 = @intCast(k.w.leaf_runs.items.len);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(k.gpa);
    if (fr.records) try ev.storageOf(bv, 0, &ls);
    try k.w.leaf_runs.appendSlice(k.gpa, ls.items);
    // The fields it keeps are the base's: each a use of the base there, and
    // one event at the record for the fields no path names.
    const r = k.res[k.rel(base)];
    for (fr.places.steps(try k.placeOf(i)).steps) |st| {
        if (!st.inRow()) continue;
        if (std.mem.indexOfScalar(u32, ranks.items, st.kidWord()) != null) continue;
        try ranks.append(k.gpa, st.kidWord());
        try ks.append(k.gpa, try k.project(bv, .plain, st.word(), 0));
        if (r.local != none) if (try fr.places.extend(k.gpa, fr.gc(), r.path, st)) |p| {
            k.atom.* += 1;
            try k.w.uses.append(k.gpa, .{ .local = r.local, .path = p, .point = i, .kind = .field, .region = k.w.regions.regionOf(i), .use_node = .none, .atom = k.atom.* });
        };
    }
    if (fr.records and r.local != none and r.path != .none) try k.w.events.append(k.gpa, .{ .local = r.local, .path = r.path, .point = i, .value = bv, .fields = written });
    k.pop(base);
    // The list pass (R-8.6): a new record that holds the base's fields, and no demand.
    if (!fr.records) return k.recordOf(i, ranks.items, ks.items, 0, i);
    try k.w.demands.append(k.gpa, .{
        .point = i,
        .kind = .update,
        .token = k.token(i),
        .base_inst = base,
        .targets = .{ .start = t_start, .len = @intCast(ls.items.len) },
        .operands = .{ .start = o_start, .len = @intCast(k.w.value_runs.items.len - o_start) },
        .pending = try k.pendingRun(),
        .base_value = bv,
        .record = true,
        .fields = written,
    });
    const fresh = @import("Mutate.zig").on(.update_fresh_site);
    return k.recordOf(i, ranks.items, ks.items, if (fresh) 0 else bv + 1, if (fresh) i else none);
}

/// A record pattern on the value of instruction `i` (R-4.8.2, R-4.8.12): where the frame names a
/// record there, the pattern reads the fields it binds and nothing else. Each is a read event, which
/// an update asks, and a use of the field's value, which a list demand asks. False: no record is
/// named, and the caller uses the value whole.
pub fn bound(k: anytype, i: u32, locals: []const u32) Error!bool {
    const r = k.res[k.rel(i)];
    if (r.local == none or r.path == .none) return false;
    const fr = k.f();
    const rec = try k.valueOf(i);
    for (locals) |local| {
        const st = try Place.Step.field(fr.account, k.ctx.fieldRank(k.ctx.ctx, k.bir.locals[k.w.code.decl.locals_start + local].name));
        try fr.charge(.use, 1);
        try k.w.events.append(k.gpa, .{ .local = r.local, .path = r.path, .point = i, .value = rec, .rank = st.payload });
        // A field no path names: the record is used whole, as a field access of it is.
        const at = (try fr.places.extend(k.gpa, fr.gc(), r.path, st)) orelse r.path;
        k.atom.* += 1;
        try k.w.uses.append(k.gpa, .{ .local = r.local, .path = at, .point = i, .kind = .whole, .region = k.w.regions.regionOf(i), .use_node = .none, .atom = k.atom.* });
    }
    k.pop(i);
    return true;
}

/// The events in the order `after` reads them: by local, record path, field (an update after every read), point.
/// Called once, when the walk ends.
pub fn settle(w: anytype) void {
    std.mem.sort(Event, w.events.items, {}, struct {
        fn lt(_: void, a: Event, b: Event) bool {
            return std.mem.order(u32, &key(a), &key(b)) == .lt;
        }
    }.lt);
}

fn key(e: Event) [4]u32 {
    return .{ e.local, e.path.int(), e.rank, e.point };
}

/// The first event of `(h, q, rank)` after `point`: a binary search, charged.
fn firstAfter(w: anytype, h: u32, q: PathId, rank: u32, point: u32) Error!usize {
    try w.f.charge(.inspection, @as(u32, std.math.log2_int_ceil(usize, w.events.items.len + 1)) + 1);
    const want: [4]u32 = .{ h, q.int(), rank, point + 1 };
    var lo: usize = 0;
    var hi: usize = w.events.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u32, &key(w.events.items[mid]), &want) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// What holder `h`'s later events at the record path `q` are to an update
/// at `point` that writes `fields` (none named: every field): the first
/// later update of that record through `h`, a whole use of the old record
/// (R-4.8.2), as a witness; and in `hoists` one more for each of the
/// frame's own reads of a written field. Each event it visits is a record
/// on the account: the reads of the written fields and no other.
pub fn after(w: anytype, regions: anytype, h: u32, q: PathId, point: u32, fields: []const u32, hoists: ?*u32) Error!?Liveness.UseId {
    if (@import("Mutate.zig").on(.update_no_events)) return null;
    const es = w.events.items;
    var n = try firstAfter(w, h, q, none, point);
    var witness: ?u32 = while (n < es.len and es[n].local == h and es[n].path == q) : (n += 1) {
        try w.f.charge(.inspection, 1);
        if (regions.compatible(point, es[n].point)) break @intCast(n);
    } else null;
    // The reads: of each written field, or of every field when none is named.
    var k: usize = 0;
    while (k < @max(fields.len, 1)) : (k += 1) {
        n = if (fields.len == 0) try firstAfter(w, h, q, 0, 0) else try firstAfter(w, h, q, fields[k], point);
        while (n < es.len and es[n].local == h and es[n].path == q and es[n].rank != none and (fields.len == 0 or es[n].rank == fields[k])) : (n += 1) {
            try w.f.charge(.inspection, 1);
            if (es[n].point <= point or !regions.compatible(point, es[n].point)) continue;
            // No hoist (a once closure's write happens at its call, R-4.8.2): the read is a whole use, the earliest one.
            if (hoists) |hs| hs.* += 1 else if (witness == null or es[n].point < es[witness.?].point) {
                witness = @intCast(n);
            }
        }
    }
    return if (witness) |b| .from(event_bit | b) else null;
}
