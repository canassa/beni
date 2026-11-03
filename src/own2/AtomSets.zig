//! L8: the atoms a call's result names, kept with its leaf for the distinct
//! check (`docs/design/ownership-v2.md` §2.9.3, *A call's atoms*, #1714).
//!
//! A leaf of a call's result whose expansion ends, through calls only, at
//! atoms (a literal's or a call's fresh objects) names exactly those atoms.
//! Its set is the union of its expansion's sets, a hash-consed Patricia set
//! (`KeySets`) shared with theirs: `y_k = List.push y_(k-1) [ k ]` makes a
//! path a level, not a copy of the k atoms below. A leaf that reaches a
//! parameter, a label, a supply, `⊤` or a cycle has no set (`impure`). The
//! distinct check then asks "is this atom in that result" as a membership
//! lookup, where it read the result's leaves to their atoms a round a call.
//! Each set is made once a leaf while no key grows (`Eval.grown`), as
//! `Ends.endOf`'s answers are; it is the leaf's own description, never an
//! answer of the check. Every leaf read is one `edge` record, every set
//! node and union `KeySets`' own records, every key listed and every
//! membership step one `inspection`, each reserved before the work.
//!
//! Obligations kept here: the distinct check's half of O3 for a root read
//! whole: its objects are its atoms, so it is apart from every entry whose
//! atoms it does not hold, and its own objects are apart by its callee's
//! vouching or by its entries' being apart only (§2.9.1).

const std = @import("std");
const Ids = @import("Ids.zig");
const KeySets = @import("KeySets.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");
const Contract = @import("Contract.zig");
const Slots = @import("Slots.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const none: u32 = Ids.none_int;

/// The leaf names something other than atoms: it has no set.
pub const impure: u32 = none - 1;
/// The leaf's set is being made: met again, it is a cycle (`impure`).
const making: u32 = none - 2;

fn key(l: Value.Leaf) KeySets.Key {
    return .{ @backingInt(l.kind), l.atom, 0 };
}

/// Whether a leaf has a slot of a type variable's or an opaque place, or a
/// subtree held whole (`Entries.wildEntry`).
fn wild(e: *Eval, l: Value.Leaf) bool {
    for (e.f.slots.elems(l.slots)) |x| {
        if (Slots.isNot(x)) continue;
        if (Slots.isSub(x)) return true;
        switch (e.places().kind(e.places().pathPlace(Slots.pathOf(x)))) {
            .@"var", .@"opaque" => return true,
            else => {},
        }
    }
    return false;
}

/// The atoms leaf `x0` names, or `impure`. A walk with its own stack, never
/// a recursion: a chain of n calls is n leaves deep.
pub fn of(e: *Eval, x0: u32) Error!u32 {
    if (e.atom_memo.get(.{ x0, e.grown })) |s| return if (s == making) impure else s;
    const g = e.gpa();
    const Frame = struct { leaf: u32, kids: u32, next: u32, end: u32, set: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(g);
    var kids: std.ArrayList(u32) = .empty;
    defer kids.deinit(g);
    try stack.append(g, .{ .leaf = x0, .kids = none, .next = 0, .end = 0, .set = KeySets.empty });
    var got: u32 = impure;
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.kids == none) {
            try e.charge(.edge, 1);
            const l = e.f.leafAt(top.leaf);
            const own: ?u32 = switch (l.kind) {
                .site, .fresh => try e.atom_sets.one(g, e.account(), key(l)),
                // A slot no step below names may hold one object several
                // times (§2.9.3, #1710): its leaf is no set of atoms.
                .ref => if (e.f.roots.items[l.root].kind == .call and !wild(e, l)) null else impure,
                else => impure,
            };
            if (own) |s| {
                got = s;
                try e.atom_memo.put(g, .{ top.leaf, e.grown }, s);
                stack.items.len -= 1;
                continue;
            }
            try e.atom_memo.put(g, .{ top.leaf, e.grown }, making);
            const start: u32 = @intCast(kids.items.len);
            try e.expandRouted(top.leaf, &kids);
            const t = &stack.items[stack.items.len - 1];
            t.kids = start;
            t.next = start;
            t.end = @intCast(kids.items.len);
            continue;
        }
        // The kids made so far, their sets into the parent's.
        var done = true;
        while (top.next < top.end) {
            const k = kids.items[top.next];
            const m = e.atom_memo.get(.{ k, e.grown });
            if (m == null) {
                done = false;
                break;
            }
            top.next += 1;
            if (m.? == making or m.? == impure) {
                top.set = impure;
                top.next = top.end;
                break;
            }
            top.set = try e.atom_sets.unite(g, e.account(), top.set, m.?);
        }
        if (!done) {
            const k = kids.items[top.next];
            try stack.append(g, .{ .leaf = k, .kids = none, .next = 0, .end = 0, .set = KeySets.empty });
            continue;
        }
        got = top.set;
        try e.atom_memo.put(g, .{ top.leaf, e.grown }, got);
        kids.items.len = top.kids;
        stack.items.len -= 1;
    }
    return got;
}

/// How many atoms set `s` holds: a node's count, made once a node (the
/// nodes are hash-consed, never changed), a recursion the key width deep.
fn size(e: *Eval, s: u32) Error!u32 {
    if (s == KeySets.empty) return 0;
    const t = &e.atom_sets;
    while (e.atom_count.items.len < t.nodes.items.len) try e.atom_count.append(e.gpa(), none);
    if (e.atom_count.items[s] != none) return e.atom_count.items[s];
    try e.charge(.inspection, 1);
    const n = t.nodes.items[s];
    const got = if (n.mask == 0) 1 else try size(e, n.left) + try size(e, n.right);
    e.atom_count.items[s] = got;
    return got;
}

/// Whether entry `en` names objects of a family its check has not vouched
/// for: one plain member of an expansion at a slot below a `[*]` or a `⟲`.
fn unvouchedFamily(e: *Eval, st: *const Entries.Rounds, i: usize, members: usize) Error!bool {
    const en = st.ents.items[i];
    if (members != 1 or st.par.items[i][0] == none or Contract.isApart(en.occ)) return false;
    const l = e.f.leafAt(en.leaf);
    if (l.at_pos) return false;
    for (e.f.slots.elems(l.slots)) |x| {
        if (Slots.isNot(x)) continue;
        if (Slots.isSub(x)) return true;
        if (e.f.places.isSummary(.from(x))) return true;
    }
    return false;
}

/// Whether the check in `st` is decided with no more rounds (§2.9.3, *A
/// call's atoms*), asked once a check, at its first round after an
/// expansion that would expand a root no group asks to: every live entry is
/// an atom, a parameter's object or a call's leaf whose objects end at
/// atoms; every call's group
/// has vouched for its own objects (its callee's `res_cond`, asked by the
/// group's check and not `no`, or its members all apart occurrences, or one
/// member of one object); and no atom is named twice, the atoms counted
/// against their union. A parameter's object is never an atom of this
/// frame. Then every expansion would make atoms that meet nothing and ask
/// nothing, and the check ends.
pub fn settled(e: *Eval, st: *Entries.Rounds) Error!bool {
    // Asked after the first expansion: a check one round ends asks nothing.
    const n = st.par.items.len;
    if (st.settle_asked or n == 0 or st.par.items[n - 1][0] == none) return false;
    st.settle_asked = true;
    const f = e.f;
    const ents = st.ents.items;
    for (ents, st.alive.items) |en, alive| {
        if (!alive) continue;
        try e.charge(.inspection, 1);
        const l = f.leafAt(en.leaf);
        switch (l.kind) {
            .site, .fresh => {},
            .ref => if (f.roots.items[l.root].kind != .call and f.roots.items[l.root].kind != .param) return false,
            else => return false,
        }
    }
    // Each call's set, the largest kept whole: every other atom is looked
    // up in it and among the others, so a chain's set is never listed.
    const g = e.gpa();
    var sets: std.ArrayList(u32) = .empty;
    defer sets.deinit(g);
    var seen: Ids.FixedDict(3) = .{};
    defer seen.deinit(g);
    var big: usize = none;
    for (ents, st.alive.items, 0..) |en, alive, i| {
        if (!alive) continue;
        const l = f.leafAt(en.leaf);
        if (l.kind != .ref) {
            try e.charge(.inspection, 1);
            if ((try seen.getOrPut(g, key(l))).found_existing) return false;
            continue;
        }
        if (f.roots.items[l.root].kind == .param) continue;
        if (try unvouchedFamily(e, st, i, st.groups.items[st.of_root.items[l.root]].members.items.len)) return false;
        const x = try of(e, en.leaf);
        if (x == impure) return false;
        if (big == none or try size(e, x) > try size(e, sets.items[big])) big = sets.items.len;
        try sets.append(g, x);
    }
    for (sets.items, 0..) |x, k| {
        if (k == big) continue;
        for (try e.atom_sets.keys(g, e.account(), x)) |ak| {
            try e.charge(.inspection, 1);
            if ((try seen.getOrPut(g, ak)).found_existing) return false;
        }
    }
    if (big == none) return true;
    for (0..seen.count()) |k| if (try has(e, sets.items[big], seen.keyAt(@intCast(k)))) return false;
    return true;
}

/// Whether set `s` holds atom key `k`: one step a level of the tree.
fn has(e: *Eval, s: u32, k: KeySets.Key) Error!bool {
    const id = e.atom_sets.ids.get(k) orelse return false;
    var n = s;
    while (n != KeySets.empty) {
        try e.charge(.inspection, 1);
        const x = e.atom_sets.nodes.items[n];
        if (x.mask == 0) return x.prefix == id;
        if (id & ~((x.mask << 1) -% 1) != x.prefix) return false;
        n = if (id & x.mask == 0) x.left else x.right;
    }
    return false;
}
