//! L8: what a traversal's supply says (`docs/design/ownership-v2.md`
//! §2.11.3, *a traversal's supply*), read by the labels' chain and the
//! read-off: the family it hands, what its callee takes, and what a write
//! of it asks. `Traversal` derives the mark.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const RowEnv = @import("RowEnv.zig");

const Allocator = std.mem.Allocator;
const Error = @import("Value.zig").Error;

/// The family arrival of callee supply `su`: its one parameter, its slot's
/// steps up to the last `[*]` of the shortest arrival. Null when anything
/// else arrives, when the parameter is no one's, or it is no family.
pub fn familyOf(c: anytype, su: Contract.Supply) Error!?struct { j: u32, words: []const u32 } {
    const es = try entriesOf(c, su.res_root);
    var got: ?struct { j: u32, words: []const u32 } = null;
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param) return null;
        const w = c.f.slots.relWords(a.slot);
        if (got) |g| {
            if (g.j != a.j) return null;
            if (w.len < g.words.len) got = .{ .j = a.j, .words = w };
        } else got = .{ .j = a.j, .words = w };
    };
    const g = got orelse return null;
    const i = std.mem.lastIndexOfScalar(u32, g.words, Place.Step.elem.word()) orelse return null;
    return .{ .j = g.j, .words = g.words[0 .. i + 1] };
}

/// The parameter contract `id`'s result is, slot for slot, unwritten; `base`
/// is one. Null for anything else.
pub fn answersWhole(c: anytype, id: Contract.Id) Error!?u32 {
    const h = c.contracts.head(id);
    if (h.res_root == 0 or h.flags.cross or h.flags.pessimistic) return null;
    var got: ?u32 = null;
    const es = try entriesOf(c, h.res_root);
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param or (got != null and got.? != a.j)) return null;
        if (!SlotWords.same(c.f.slots.relWords(a.slot), es.wordsOf(rs))) return null;
        got = a.j;
    };
    const j = got orelse return null;
    for (c.contracts.writesOf(h.writes)) |x| if (x[0] == j) return null;
    return j;
}

/// Whether a callee reads parameter `j` only through label `lab`'s runs: a
/// `walk` supply hands its whole family, and it reaches no result, store or
/// escape. A family at a part (`pr.0[*]`) leaves the other parts read.
pub fn takes(c: anytype, h: Contract.Head, lab: Contract.Label, j: u32) Error!bool {
    var hit = false;
    for (c.contracts.suppliesOf(lab.supplies)) |su| {
        if (!su.walk or su.res_root == 0) continue;
        const fam = (try familyOf(c, su)) orelse continue;
        if (fam.j == j and fam.words.len == 1) hit = true;
    }
    if (!hit) return false;
    for (c.contracts.effectsOf(h.escapes)) |x| if (x.j == j) return false;
    for (c.contracts.storesOf(h.stores)) |x| if (x.j == j) return false;
    for ((try entriesOf(c, h.res_root)).items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind == .param and a.j == j) return false;
    };
    return true;
}

/// Condition `c` of traversal supply `su`, its family's occurrences apart:
/// a write asks its own slot plain (`RowEnv.takenOccs`), so a part rows
/// share and the callback does not write is not asked once.
fn relaxed(c: anytype, arena: Allocator, su: Contract.Supply, cond: Contract.Cond) Error!Contract.Cond {
    if (cond.no) return cond;
    const fam = (try familyOf(c, su)) orelse return cond;
    const out = try arena.dupe(u64, cond.sel);
    for (out) |*o| {
        if (Contract.isFed(o.*) or Contract.occParam(o.*) != fam.j) continue;
        if (SlotWords.under(c.f.places, fam.words, c.f.slots.relWords(Contract.occRel(o.*))) != null) o.* |= Contract.apart_bit;
    }
    return Contract.Cond.of(c.f.account, out);
}

/// What a write at `words` of supply `su` relies on: its `sep` and, written
/// below the root, its `below`. Of a traversal's, one selection, the
/// family's occurrences apart and the written slot plain, so that it is
/// compared with what the function holds apart.
pub fn asked(c: anytype, arena: Allocator, su: Contract.Supply, words: []const u32, deep: bool) Error![]const Contract.Cond {
    const f = c.f;
    const written = words.len != 0 or deep;
    const sep = try c.contracts.cond(arena, su.cond);
    const below = try c.contracts.cond(arena, su.below);
    if (!su.each) return arena.dupe(Contract.Cond, if (written) &.{ below, sep } else &.{sep});
    var sel = try relaxed(c, arena, su, sep);
    if (written) sel = try Contract.Cond.conj(arena, f.account, sel, try relaxed(c, arena, su, below));
    // A write above every entry of a structural supply names no slot of it:
    // nothing is relaxed.
    const os = (try RowEnv.takenOccs(c.contracts, f.places, f.slots, f.account, f.gpa, arena, su, words, deep)) orelse return arena.dupe(Contract.Cond, &.{ below, sep });
    sel = try Contract.Cond.conj(arena, f.account, sel, try Contract.Cond.of(f.account, os));
    return arena.dupe(Contract.Cond, &.{sel});
}

fn entriesOf(c: anytype, root: Contract.Node) Error!*Forest.Entries {
    const es = try c.arena.create(Forest.Entries);
    es.* = .{};
    try es.of(&c.contracts.trees, c.arena, c.f.places, root, &.{});
    return es;
}
