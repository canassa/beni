//! L8: what a check's plain slots may hold of a callee (`docs/design/ownership-v2.md`
//! §2.9.1, *Apart occurrences*), split from `Distinct`: an occurrence of the
//! callee that arrives at no plain slot is asked apart.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Contract = @import("Contract.zig");
const SlotWords = @import("SlotWords.zig");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");
const Subtree = @import("Subtree.zig");

const Allocator = std.mem.Allocator;
const Eval = Relation.Eval;
const Cond = Contract.Cond;
const Error = Relation.Error;
const Ent = Entries.Ent;

/// `cond_state`'s bit while `instCondMixed` asks the call.
const mixed_on: u8 = 4;

/// The callee's `res_cond` on call `call`'s arguments, for a check that
/// asks some of the call's slots only to be apart (§2.9.1): an
/// occurrence of the callee that arrives at no plain slot of the check
/// is asked apart, so that what an apart slot repeats inside it is not
/// asked once (`List.unzipHelp`'s builders, whose elements come from one
/// family of its parameter). `idx`: the call's entries of `ents`.
/// A cycle through it reads `no`, as `instCond`'s does (a fold's step fed
/// its own answer asks it inside its arguments; #1723).
pub fn instCondMixed(e: *Eval, call: u32, ents: []const Ent, idx: []const u32, instSel: anytype, _: void) Error!Cond {
    if (e.cond_state.items[3 * call] & mixed_on != 0) return Cond.unprovable;
    e.cond_state.items[3 * call] |= mixed_on;
    defer e.cond_state.items[3 * call] &= ~mixed_on;
    const g = e.gpa();
    const c = e.contractOf(call) orelse return Cond.unprovable;
    const h = e.contracts.head(c);
    const full = try e.contracts.resCond(e.arena, c, e.read_mode == .reading);
    if (full.no or full.sel.len == 0) return full;
    if ((try @import("CallFolds.zig").of(e, call, @import("Ids.zig").none_int)).len != 0) return instSel(e, full, call); // read whole, through its keys
    // The plain slots of the check, as words from the call's root.
    var plain: std.ArrayList(u32) = .empty;
    defer plain.deinit(g);
    for (idx) |i| {
        if (Contract.isApart(ents[i].occ)) continue;
        // A whole subtree is plain at every slot below its top: every
        // occurrence may arrive there.
        if (Subtree.symbolic(e.f.slots, e.f.leafAt(ents[i].leaf).slots)) return instSel(e, full, call);
        try plain.appendSlice(g, e.f.slots.items(e.f.leafAt(ents[i].leaf).slots));
    }
    // What arrives at the plain slots, read once for every occurrence:
    // the callee's result tree is walked once per plain slot, not once
    // per (occurrence, slot).
    var reach: Reach = .empty;
    defer reach.deinit(g);
    var hits: std.ArrayList(Contract.Hit) = .empty;
    defer hits.deinit(g);
    var keys: std.ArrayList([]const u32) = .empty;
    for (plain.items) |x| {
        const words = e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), e.places(), .from(x)));
        try e.charge(.cond, e.contracts.trees.count(h.res_root));
        hits.clearRetainingCapacity();
        try e.hitsAt(h.res_root, words, &hits);
        // A slot the result tree does not name may hold anything.
        if (hits.items.len == 0) return instSel(e, full, call);
        for (hits.items) |hit| for (hit.arrivals) |a| {
            if (a.kind != .param) continue;
            // The arrival's slot is its own steps, then what the plain
            // slot takes on below an open one; at a family's payload, all of it (§2.1).
            const w = Subtree.wholeAt(e.places(), a, .from(x));
            const aw = try std.mem.concat(e.arena, u32, &.{ &.{a.j}, e.f.slots.relWords(a.slot), if (w != null) &.{} else words[hit.depth..] });
            try e.charge(.cond, @intCast(aw.len));
            try keys.append(e.arena, aw);
            try mark(&reach, g, aw, if ((w orelse a).deep) at_deep else at_slot);
            for (1..aw.len) |n| try mark(&reach, g, aw[0..n], below);
        };
    }
    const rows = for (keys.items) |w| {
        if (SlotWords.hasRow(w)) break true;
    } else false;
    const out = try e.arena.alloc(u64, full.sel.len);
    for (full.sel, 0..) |o, k| {
        out[k] = o;
        if (Contract.isApart(o)) continue;
        const row = rows or SlotWords.hasRow(e.f.slots.relWords(Contract.occRel(o)));
        if (row) try e.charge(.cond, @intCast(keys.items.len));
        const ws = e.f.slots.relWords(Contract.occRel(o));
        if (!(if (row) SlotWords.meetsKey(e.places(), keys.items, Contract.occParam(o), ws) else try arrives(e, &reach, o))) out[k] = o | Contract.apart_bit;
    }
    return instSel(e, try Cond.of(e.account(), out), call);
}

/// What arrives at a check's plain slots, by a callee's result tree: for
/// each word sequence `j · slot`, an arrival of parameter `j` there
/// (`at_slot`), a deep one (`at_deep`), or an arrival below it
/// (`below`).
pub const Reach = std.StringHashMapUnmanaged(u8);
pub const at_slot: u8 = 1;
pub const at_deep: u8 = 2;
pub const below: u8 = 4;

pub fn mark(r: *Reach, g: Allocator, key: []const u32, bit: u8) Error!void {
    const got = try r.getOrPut(g, std.mem.sliceAsBytes(key));
    got.value_ptr.* = if (got.found_existing) got.value_ptr.* | bit else bit;
}

/// Whether occurrence `o` of a callee may arrive at one of the check's
/// plain slots: an arrival at its own slot, a deep arrival above it, or,
/// for a deep occurrence (which reaches every slot below its own), an
/// arrival below it.
pub fn arrives(e: *Eval, reach: *const Reach, o: u64) Error!bool {
    const key = try std.mem.concat(e.arena, u32, &.{ &.{Contract.occParam(o)}, e.f.slots.relWords(Contract.occRel(o)) });
    try e.charge(.cond, @intCast(key.len));
    const at = reach.get(std.mem.sliceAsBytes(key)) orelse 0;
    if (at & (at_slot | at_deep) != 0) return true;
    if (Contract.isDeep(o) and at & below != 0) return true;
    for (1..key.len) |n| if ((reach.get(std.mem.sliceAsBytes(key[0..n])) orelse 0) & at_deep != 0) return true;
    return false;
}
