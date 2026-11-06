//! L11: a write of a supply a label is fed its own answers at
//! (`docs/design/ownership-v2.md` §2.11.3, *a fold's storage*): a fold's
//! accumulator. What the write relies on is asked of the slot it writes.
//!
//! Obligations kept here: O14's label half for a fold's accumulator: the
//! object a run writes is what it was handed or its own, each run.

const std = @import("std");
const Contract = @import("Contract.zig");
const LabelChain = @import("LabelChain.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const FedCall = @import("FedCall.zig");

const Each = @import("Each.zig");

const Error = Relation.Error;
const Cond = Contract.Cond;

/// What the code writes of argument `k`: an answer matters only where a
/// later run writes it.
const Written = struct {
    words: []const u32,
    deep: bool,
    pub fn reaches(w: Written, at_slot: []const u32) bool {
        return std.mem.startsWith(u32, w.words, at_slot) or (w.deep and std.mem.startsWith(u32, at_slot, w.words));
    }
};

/// What a write at `words` of supply `su` relies on (§2.11.2 item 4), each
/// condition instantiated at `call` by `instSel`.
pub fn relies(e: *Relation.Eval, c: LabelChain.Chain, lab: Contract.Label, su: Contract.Supply, call: u32, words: []const u32, deep: bool) Error![]const Cond {
    if (try asked(e, c, lab, su, call, words, deep)) |x| return c.arena.dupe(Cond, &.{x});
    const out = try c.arena.dupe(Cond, try Each.asked(c, c.arena, su, words, deep));
    for (out) |*x| x.* = try Distinct.instSel(e, x.*, call);
    return out;
}

/// What a write at `words` of supply `su` of label `lab` at `call` relies on,
/// when the condition feeds it its own answers; else null. The `fed`
/// occurrence is decided at the written slots only, and every parameter that
/// arrives at the supply is asked apart but the written slot, plain.
fn asked(e: *Relation.Eval, c: LabelChain.Chain, lab: Contract.Label, su: Contract.Supply, call: u32, words: []const u32, deep: bool) Error!?Cond {
    const f = c.f;
    const arena = c.arena;
    if (su.each) return null;
    const sep = try c.contracts.cond(arena, su.cond);
    const below = try c.contracts.cond(arena, su.below);
    if (sep.no) return null;
    var fed: ?u64 = null;
    for (sep.sel) |o| if (Contract.isFed(o) and Contract.fedParam(o) == lab.j and Contract.occRel(o) == lab.slot and Contract.fedArg(o) == su.k) {
        fed = o;
    };
    const self = fed orelse return null;
    const es = try LabelChain.entriesOf(c, su.res_root);
    var run: std.ArrayList(u64) = .empty;
    const written = words.len != 0 or deep;
    for ([_]Cond{ sep, if (written) below else Cond.yes }) |x| {
        if (x.no) return null;
        for (x.sel) |o| {
            if (o == self) continue;
            var y = o;
            if (!Contract.isFed(o)) for (es.items.items) |rs| for (rs.arrivals) |a| {
                if (a.kind == .param and a.j == Contract.occParam(o) and std.mem.startsWith(u32, f.slots.relWords(Contract.occRel(o)), f.slots.relWords(a.slot))) y |= Contract.apart_bit;
            };
            try run.append(arena, y);
        }
    }
    // The written object, plain: below a code's own type it is one object,
    // whatever a type variable's slot could hold in the callee.
    var named = false;
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param or !std.mem.startsWith(u32, words, es.wordsOf(rs))) continue;
        const at = try std.mem.concat(arena, u32, &.{ f.slots.relWords(a.slot), if (a.past) &.{} else words[rs.len..] });
        const o = Contract.occ(a.j, try f.slots.relOfWords(f.gpa, f.account, f.places, at));
        try run.append(arena, if (deep or a.past) Contract.occDeep(o) else o);
        named = true;
    };
    if (!named) return null;
    var res = try Distinct.instSel(e, try Cond.of(f.account, run.items), call);
    switch (try FedCall.at(e, call, self, Written{ .words = words, .deep = deep })) {
        .yes => {},
        .no => return Cond.unprovable,
        .occ => |x| {
            const one = try arena.alloc(u64, 1);
            one[0] = x;
            res = try Cond.conj(arena, f.account, res, try Cond.of(f.account, one));
        },
    }
    return res;
}
