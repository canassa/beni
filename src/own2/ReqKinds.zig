//! L9: a requirement as a write of one kind relies on it
//! (`docs/design/ownership-v2.md` §2.11.2 item 4, *A list's write beside a
//! record's*, *a record's write beside a list's*, *a deep occurrence, for a
//! record's write*). A requirement is one selection for every write that
//! relies on it. In the record pass (§2.11.5) a record's write asks no pair
//! of two lists' storage, and a list's write asks no pair of two records'
//! objects: the occurrences of the other kind are asked apart (§2.9.1). A
//! record's write reads a deep occurrence as the records at and below it.
//!
//! Obligations kept here: O14's kind half: each written object is still
//! asked apart from every occurrence that can be an object of its kind (a
//! slot whose kind no place says stays as it is).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Update = @import("Update.zig");

const Error = Relation.Error;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// The most places below a deep occurrence that a record's write names one by one; past it the occurrence stays deep.
const max_places = 64;

/// `c`, a selection on call `call`'s arguments, as a record's write relies on it (`record`), or a list's.
/// Each plain occurrence, not deep, at a slot of the other kind (a list's own storage; a record's own
/// object) is asked apart: it keeps its pairs with every plain occurrence, and its pairs with another
/// apart occurrence are not asked. The kind is the known code's parameter place's, or the argument's. For
/// a record's write a deep occurrence is the record objects at and below its slot (`records`). Null
/// where nothing changes.
pub fn of(ev: *Relation.Eval, call: Value.Call, c: Cond, record: bool) Error!?Cond {
    if (c.no or c.sel.len == 0) return null;
    const f = ev.f;
    const params: []const Place.PlaceId = if (ev.code_sig != null and call.code != none) (try ev.code_sig.?.of(ev.code_sig.?.ctx, call.code)).params else &.{};
    const other: Place.Kind = if (record) .list else .record;
    var sel: std.ArrayList(u64) = .empty;
    var n: usize = 0;
    for (c.sel) |o| {
        const j = Contract.occParam(o);
        const words = f.slots.relWords(Contract.occRel(o));
        const at: ?Place.PlaceId = if (Contract.isFed(o) or j >= call.args.len) null else Update.placeAt(f, call.args[j], words);
        const changed = if (Contract.isFed(o))
            false
        else if (Contract.isDeep(o))
            record and at != null and !@import("Mutate.zig").on(.record_deep_whole) and try records(ev, j, words, at.?, Contract.isApart(o), &sel)
        else if (Contract.isApart(o))
            false
        else blk: {
            const by_code: ?Place.PlaceId = if (j < params.len) Update.placeBelow(f, params[j], words) else null;
            const kinds: [2]?Place.Kind = .{ if (by_code) |p| f.places.kind(p) else null, if (at) |p| f.places.kind(p) else null };
            // A slot that either place says is a record's is a record's (a type variable's place at the callee).
            const kind: ?Place.Kind = if (kinds[0] == .record or kinds[1] == .record) .record else if (kinds[0] == .list or kinds[1] == .list) .list else null;
            if (kind == other) try sel.append(ev.arena, o | Contract.apart_bit);
            break :blk kind == other;
        };
        if (changed) n += 1 else try sel.append(ev.arena, o);
    }
    return if (n == 0) null else try Cond.of(f.account, sel.items);
}

/// The record objects at and below place `at`, which is `words` below argument `j`: an occurrence for each
/// record's slot into `out`, `apart` as the deep occurrence was, and true. False, with `out` as it was,
/// where they cannot be named one by one: a place on a cycle, a slot whose kind may hold a record that no
/// step names (a type variable, an opaque type, a closure, a cell, a dictionary), or more than `max_places`.
fn records(ev: *Relation.Eval, j: u32, words: []const u32, at: Place.PlaceId, apart: bool, out: *std.ArrayList(u64)) Error!bool {
    const start = out.items.len;
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(ev.gpa());
    try path.appendSlice(ev.gpa(), words);
    var left: u32 = max_places;
    if (try below(ev, j, at, apart, &path, out, &left)) return true;
    out.shrinkRetainingCapacity(start);
    return false;
}

fn below(ev: *Relation.Eval, j: u32, p: Place.PlaceId, apart: bool, path: *std.ArrayList(u32), out: *std.ArrayList(u64), left: *u32) Error!bool {
    const pl = ev.places();
    if (left.* == 0 or pl.cyclic(p)) return false;
    left.* -= 1;
    try ev.charge(.cond, 1);
    switch (pl.kind(p)) {
        .record => {
            const o = Contract.occ(j, try ev.f.slots.relOfWords(ev.gpa(), ev.account(), pl, path.items));
            try out.append(ev.arena, if (apart) o | Contract.apart_bit else o);
        },
        .list, .tuple, .ctor, .cross => {},
        .dict, .ref, .closure, .@"opaque", .@"var" => return false,
    }
    const st = pl.steps(p);
    for (st.steps, st.children) |s, child| {
        try path.append(ev.gpa(), s.word());
        defer _ = path.pop();
        if (!try below(ev, j, child, apart, path, out, left)) return false;
    }
    return true;
}
