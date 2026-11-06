//! L8: the labels a virtual call's supply comes through, outward
//! (`docs/design/ownership-v2.md` §2.11.3). Where the call a known code
//! applies a label of is virtual too, its supply is that code's own
//! parameter's, so the outer labels' count, `taken` mark, conditions and
//! kept slots hold what it is supplied as well (#1721, #1758, #1760).
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Replay = @import("Replay.zig");
const Ids = @import("Ids.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const RowEnv = @import("RowEnv.zig");
const Value = @import("Value.zig");

const Allocator = std.mem.Allocator;
const Error = Value.Error;

/// What the chain reads of an evaluation: its frame, the walk's virtual
/// calls (`(call, label)` → the virtual call applying it) and the contracts.
pub const Chain = struct {
    f: *Value.Frame,
    virt: *const Ids.FixedDict(2),
    contracts: *Contract.Table,
    arena: Allocator,
};

/// The walk's call a virtual call applies a label of: `(call, label)`.
pub fn virtualOuter(c: Chain, q: u32) ?[2]u32 {
    const it = c.virt.keys.items;
    var i: usize = 0;
    while (i + 1 < it.len) : (i += 2) {
        if (c.virt.values.items[i / 2] == q) return .{ it[i], it[i + 1] };
    }
    return null;
}

/// The label of `(call, label)` pair `o`.
pub fn labelAt(c: Chain, o: [2]u32) Contract.Label {
    return c.contracts.labelsOf(c.contracts.head(c.f.calls.items[o[0]].contract).labels)[o[1]];
}

/// Whether call `q` is a known code's run by a label that calls it many
/// times (`calls` many), at any level outward (§2.11.3, #1721).
pub fn outwardMany(c: Chain, q: u32) bool {
    var cur = q;
    while (c.f.calls.items[cur].virtual) {
        const o = virtualOuter(c, cur) orelse return false;
        const lab = labelAt(c, o);
        if (lab.calls == .many) return true;
        // Labels of one function slot add up: `two h = ( h ⊤, h ⊤ )`.
        for (c.contracts.labelsOf(c.contracts.head(c.f.calls.items[o[0]].contract).labels), 0..) |x, li| {
            if (li != o[1] and x.j == lab.j and x.slot == lab.slot and x.calls != .none) return true;
        }
        cur = o[0];
    }
    return false;
}

/// Whether call `q` is a known code's run by a `taken` label (§2.13.6), at
/// any level outward: its supplies may be the taken element.
pub fn takenOutward(c: Chain, q: u32) bool {
    var cur = q;
    while (c.f.calls.items[cur].virtual) {
        const o = virtualOuter(c, cur) orelse return false;
        if (labelAt(c, o).origin[2] & RowEnv.taken_origin != 0) return true;
        cur = o[0];
    }
    return false;
}

/// A label a virtual call's supply comes through: the call `call` whose
/// callee's label `lab` it applies, the supply `k`, written at `words`.
pub const Level = struct { call: u32, lab: Contract.Label, k: u32, words: []const u32 };

/// The labels virtual call `q`'s argument `k`, written at `words`, is
/// supplied through, outward (§2.11.3, #1758). Where the call it applies a
/// label of is virtual too (a known code's label of a known code, `h = λv
/// → g v` called by a callee's label), that supply is in turn its own
/// parameter's: what an arrival of it at the supply says, so the outer
/// label's condition, kept slots and `taken` occurrences hold the write too.
/// The calls go down (a virtual call follows the call it applies), so the
/// chain ends; each level's (k, words) is listed once.
pub fn supplyLevels(c: Chain, q: u32, k: u32, words: []const u32, out: *std.ArrayList(Level)) Error!void {
    const f = c.f;
    const gpa = f.gpa;
    var cur = q;
    var ks: std.ArrayList(Level) = .empty;
    defer ks.deinit(gpa);
    try ks.append(gpa, .{ .call = q, .lab = undefined, .k = k, .words = words });
    while (f.calls.items[cur].virtual and ks.items.len != 0) {
        const o = virtualOuter(c, cur) orelse break;
        const oc = f.calls.items[o[0]];
        const lab = labelAt(c, o);
        var next: std.ArrayList(Level) = .empty;
        defer next.deinit(gpa);
        const own = if (oc.virtual and oc.callee_val != Ids.none_int) oc.args.len - f.kidsOf(f.val(oc.callee_val)).len else 0;
        for (ks.items) |kw| {
            try out.append(gpa, .{ .call = o[0], .lab = lab, .k = kw.k, .words = kw.words });
            if (!oc.virtual) continue;
            for (c.contracts.suppliesOf(lab.supplies)) |su| if (su.k == kw.k) {
                const es = try entriesOf(c, su.res_root);
                for (es.items.items) |rs| for (rs.arrivals) |a| {
                    if (a.kind != .param or a.j >= own) continue;
                    const at = es.wordsOf(rs);
                    const nw: []const u32 = if (Replay.under(f.places, at, kw.words)) |n| try std.mem.concat(c.arena, u32, &.{ f.slots.relWords(a.slot), kw.words[n..] }) else if (std.mem.startsWith(u32, at, kw.words)) f.slots.relWords(a.slot) else continue;
                    const seen = for (next.items) |n| {
                        if (n.k == a.j and std.mem.eql(u32, n.words, nw)) break true;
                    } else false;
                    if (!seen) try next.append(gpa, .{ .call = o[0], .lab = lab, .k = a.j, .words = nw });
                };
            };
        }
        ks.clearRetainingCapacity();
        try ks.appendSlice(gpa, next.items);
        cur = o[0];
    }
}

/// Whether a label virtual call `q`'s argument `k`, written at `words`, is
/// supplied through keeps a slot that holds the write (#1758).
pub fn keptOutward(c: Chain, q: u32, k: u32, words: []const u32) Error!bool {
    var lvs: std.ArrayList(Level) = .empty;
    defer lvs.deinit(c.f.gpa);
    try supplyLevels(c, q, k, words, &lvs);
    for (lvs.items) |lv| for (c.contracts.suppliesOf(lv.lab.supplies)) |su| if (su.k == lv.k) {
        for (c.contracts.effectsOf(su.kept)) |kp| if (overlaps(lv.words, c.f.slots.relWords(kp.slot))) return true;
    };
    return false;
}

/// Whether one of two slots' words is a prefix of the other's.
pub fn overlaps(a: []const u32, b: []const u32) bool {
    return std.mem.startsWith(u32, a, b) or std.mem.startsWith(u32, b, a);
}

/// Every entry of tree `root`, in the canonical order, in the chain's arena.
pub fn entriesOf(c: Chain, root: Contract.Node) Error!*Forest.Entries {
    const es = try c.arena.create(Forest.Entries);
    es.* = .{};
    try es.of(&c.contracts.trees, c.arena, c.f.places, root, &.{});
    return es;
}
