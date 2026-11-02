//! L7: the one relation and the distinct check (`docs/design/ownership-v2.md`
//! §2.9): the selection of a parameter at a slot set, a call's separation
//! (its callee's `res_cond` on its arguments), the distinct check over the
//! objects a value reaches, and the relation of two leaves. It reads a
//! value's leaves and a call's instantiation through `Relation.Eval`, which
//! keeps every memo of one evaluation.
//!
//! Obligations kept here: the relation's half of O3 (two positions of one
//! root are apart only under the root's separation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Cond = Contract.Cond;
const Eval = Relation.Eval;
const Ov = Relation.Ov;
const Proj = Relation.Proj;
const Leaf = Value.Leaf;
const Step = Place.Step;
const none: u32 = Ids.none_int;

/// The selection of parameter `j` at the slots of `set` (paths under its root).
pub fn sel(e: *Eval, j: u32, set: Slots.SetId) Error!Cond {
    return selOf(e, j, set, false);
}

/// The selection of parameter `j` at `set`, its occurrences apart
/// only (§2.9.1) when `apart`.
pub fn selOf(e: *Eval, j: u32, set: Slots.SetId, only_apart: bool) Error!Cond {
    const items = e.f.slots.items(set);
    try e.charge(.cond, @intCast(1 + items.len));
    const out = try e.arena.alloc(u64, items.len);
    for (items, out) |s, *o| {
        const r = try e.f.slots.relOf(e.gpa(), e.account(), e.places(), .from(s));
        o.* = if (only_apart) Contract.occApart(j, r) else Contract.occ(j, r);
    }
    return Cond.of(e.account(), out);
}

/// Whether a leaf names a family: one of its slots is below a `[*]` or a
/// `⟲`, where many objects sit (§2.3.1); elsewhere a position's slot
/// holds one object.
fn isFamily(e: *Eval, l: Leaf) bool {
    for (e.f.slots.items(l.slots)) |s| if (e.f.places.isSummary(.from(s))) return true;
    return false;
}

/// `Sep` of a leaf's own objects (a family's): a parameter's selection,
/// a call's instantiated condition, an expansion's distinct check.
fn sepLeaf(e: *Eval, li: u32) Error!Cond {
    const l = e.f.leafAt(li);
    const r = e.f.roots.items[l.root];
    return switch (r.kind) {
        .param => sel(e, r.a, l.slots),
        .call => instCond(e, r.a),
        .supply, .cb => blk: {
            if (!e.expandable(l)) break :blk Cond.unprovable;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(e.gpa());
            try e.expand(li, &ls);
            var ps: std.ArrayList(Proj) = .empty;
            defer ps.deinit(e.gpa());
            for (ls.items, 0..) |x, k| try ps.append(e.gpa(), .{ .leaf = x, .route = @intCast(k + 1) });
            break :blk distinct(e, ps.items, false);
        },
    };
}

/// The callee's `res_cond` on call `call`'s arguments, once per call; a
/// cycle through it reads `no`.
pub fn instCond(e: *Eval, call: u32) Error!Cond {
    while (e.cond_state.items.len < e.f.calls.items.len) {
        try e.cond_state.append(e.gpa(), 0);
        try e.cond_of.append(e.gpa(), .{});
    }
    switch (e.cond_state.items[call]) {
        2 => return e.cond_of.items[call],
        1 => return Cond.unprovable,
        else => {},
    }
    e.cond_state.items[call] = 1;
    const c = e.contractOf(call) orelse {
        e.cond_state.items[call] = 2;
        e.cond_of.items[call] = Cond.unprovable;
        return Cond.unprovable;
    };
    const got = try instSel(e, try e.contracts.cond(e.arena, e.contracts.head(c).res_cond), call);
    e.cond_state.items[call] = 2;
    e.cond_of.items[call] = got;
    return got;
}

/// The callee's `res_cond` on call `call`'s arguments, for a check that
/// asks some of the call's slots only to be apart (§2.9.1): an
/// occurrence of the callee that arrives at no plain slot of the check
/// is asked apart, so that what an apart slot repeats inside it is not
/// asked once (`List.unzipHelp`'s builders, whose elements come from one
/// family of its parameter). `idx`: the call's entries of `ents`.
fn instCondMixed(e: *Eval, call: u32, ents: []const Ent, idx: []const u32) Error!Cond {
    const g = e.gpa();
    const c = e.contractOf(call) orelse return Cond.unprovable;
    const h = e.contracts.head(c);
    const full = try e.contracts.cond(e.arena, h.res_cond);
    if (full.no or full.sel.len == 0) return full;
    // The plain slots of the check, as words from the call's root.
    var plain: std.ArrayList([]const u32) = .empty;
    defer plain.deinit(g);
    for (idx) |i| {
        if (Contract.isApart(ents[i].occ)) continue;
        for (e.f.slots.items(e.f.leafAt(ents[i].leaf).slots)) |x| {
            try plain.append(g, e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), e.places(), .from(x))));
        }
    }
    const out = try e.arena.alloc(u64, full.sel.len);
    for (full.sel, 0..) |o, k| {
        out[k] = o;
        if (Contract.isApart(o)) continue;
        if (!try arrivesAtPlain(e, h.res, o, plain.items)) out[k] = o | Contract.apart_bit;
    }
    return instSel(e, try Cond.of(e.account(), out), call);
}

/// Whether occurrence `o` of a callee may arrive at one of the result
/// slots `plain` (words from the result's root) by `res`. A slot `res`
/// does not name may hold anything.
fn arrivesAtPlain(e: *Eval, res: Ids.Range, o: u64, plain: []const []const u32) Error!bool {
    const ow = e.f.slots.relWords(Contract.occRel(o));
    for (plain) |words| {
        var named = false;
        for (e.contracts.resOf(res)) |rs| {
            try e.charge(.cond, 1);
            const rw = e.f.slots.relWords(rs.slot);
            const exact = std.mem.eql(u32, rw, words);
            const opened = rs.open and rw.len < words.len and std.mem.eql(u32, rw, words[0..rw.len]);
            if (!exact and !opened) continue;
            named = true;
            const suffix = words[rw.len..];
            for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
                if (a.kind != .param or a.j != Contract.occParam(o)) continue;
                // The arrival's slot is its own steps, then what the
                // plain slot takes on below an open one; a deep arrival
                // reaches every slot below that.
                const aw = e.f.slots.relWords(a.slot);
                if (aw.len + suffix.len > ow.len) continue;
                if (!std.mem.eql(u32, aw, ow[0..aw.len])) continue;
                if (!std.mem.eql(u32, suffix, ow[aw.len..][0..suffix.len])) continue;
                if (a.deep or aw.len + suffix.len == ow.len) return true;
            }
        }
        if (!named) return true;
    }
    return false;
}

/// A callee's condition (a selection over its parameters) on call
/// `call`'s arguments (§2.9.3's routed rule): every object at a selected
/// occurrence, projected, distinct from every other.
pub fn instSel(e: *Eval, c: Cond, call: u32) Error!Cond {
    if (c.no) return Cond.unprovable;
    if (c.sel.len == 0) return Cond.yes;
    const cl = e.f.calls.items[call];
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(e.gpa());
    for (c.sel) |o| {
        const j = Contract.occParam(o);
        if (j >= cl.args.len) return Cond.unprovable;
        const arg = cl.args[j];
        var got: std.ArrayList(Proj) = .empty;
        defer got.deinit(e.gpa());
        // Routes are per parameter: two parameters handed one value are
        // that value twice (the experiment's third requirement).
        try e.project(arg, e.f.slots.relWords(Contract.occRel(o)), false, 0, try e.routeStep(0, 0x8000_0000 | j), &got);
        for (got.items) |p| try ps.append(e.gpa(), .{ .leaf = p.leaf, .route = p.route, .occ = o });
    }
    return distinct(e, ps.items, true);
}

/// `Sep(v)`: v's components each separated, all apart.
pub fn sepOf(e: *Eval, v: u32) Error!Cond {
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    try e.leavesOf(v, 0, &ls);
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(e.gpa());
    // Each component its own route: one value placed twice is two
    // entries (the experiment's fifth requirement).
    for (ls.items, 0..) |l, k| try ps.append(e.gpa(), .{ .leaf = l, .route = @intCast(k + 1) });
    return distinct(e, ps.items, false);
}

const Ent = struct { leaf: u32, route: u32, occ: u64, block: u32 };

/// §2.9.3: every object the entries name is distinct from every other's,
/// by the factored check (never a table of pairs).
pub fn distinct(e: *Eval, ps: []const Proj, routed: bool) Error!Cond {
    const g = e.gpa();
    var ents: std.ArrayList(Ent) = .empty;
    defer ents.deinit(g);
    for (ps) |p| try ents.append(g, .{ .leaf = p.leaf, .route = p.route, .occ = p.occ, .block = none });
    const acc: Cond = .{};
    // The conditions met, gathered and made one at the end: a merge per
    // entry or group would cost their product (§2.9.3's linear bound).
    var occs: Occs = .{};
    defer occs.deinit(g);
    // A family asks its own root's separation; ⊤ and shared objects are
    // never known to be once.
    for (ents.items) |en| {
        const l = e.f.leafAt(en.leaf);
        switch (l.kind) {
            .ref => if (!l.at_pos and isFamily(e, l) and !Contract.isApart(en.occ)) {
                if (e.f.roots.items[l.root].kind == .cb and !e.expandable(l)) return Cond.unprovable;
                if (try gather(e, &occs, try sepLeaf(e, en.leaf))) return Cond.unprovable;
            },
            .top, .shared => return Cond.unprovable,
            else => {},
        }
    }
    var next: std.ArrayList(Ent) = .empty;
    defer next.deinit(g);
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        try e.charge(.cond, @intCast(1 + ents.items.len));
        // Group by root; atoms by identity.
        var groups: Ids.FixedDict(1) = .{};
        defer groups.deinit(g);
        var members: std.ArrayList(std.ArrayList(u32)) = .empty;
        defer {
            for (members.items) |*m| m.deinit(g);
            members.deinit(g);
        }
        var group_root: std.ArrayList(u32) = .empty;
        defer group_root.deinit(g);
        var atoms: Ids.FixedDict(3) = .{};
        defer atoms.deinit(g);
        var atom_members: std.ArrayList(std.ArrayList(u32)) = .empty;
        defer {
            for (atom_members.items) |*m| m.deinit(g);
            atom_members.deinit(g);
        }
        var latest: u32 = none;
        for (ents.items, 0..) |en, i| {
            const l = e.f.leafAt(en.leaf);
            switch (l.kind) {
                .ref => {
                    const got = try groups.getOrPut(g, .{l.root});
                    if (!got.found_existing) {
                        got.value_ptr.* = @intCast(members.items.len);
                        try members.append(g, .empty);
                        try group_root.append(g, l.root);
                    }
                    try members.items[got.value_ptr.*].append(g, @intCast(i));
                    if (e.expandable(l) and (latest == none or l.root > latest)) latest = l.root;
                },
                .site, .fresh => {
                    const got = try atoms.getOrPut(g, .{ @backingInt(l.kind), l.atom, 0 });
                    if (!got.found_existing) {
                        got.value_ptr.* = @intCast(atom_members.items.len);
                        try atom_members.append(g, .empty);
                    }
                    for (atom_members.items[got.value_ptr.*].items) |fi| {
                        const o = ents.items[fi];
                        if (o.block != none and o.block == en.block) continue;
                        if (Contract.isApart(o.occ) and Contract.isApart(en.occ)) continue;
                        if ((try e.f.mergeTags(l.tags, e.f.leafAt(o.leaf).tags)) != null) return Cond.unprovable;
                    }
                    try atom_members.items[got.value_ptr.*].append(g, @intCast(i));
                },
                else => {},
            }
        }
        var params: u32 = 0;
        for (group_root.items) |root| if (e.f.roots.items[root].kind == .param) {
            params += 1;
        };
        // A supply or a label meeting itself is decided by expansion.
        var must: u32 = none;
        var unvouched = false;
        for (members.items, group_root.items) |idx, root| {
            if (try mayWithin(e, ents.items, idx.items, routed)) return Cond.unprovable;
            const r = e.f.roots.items[root];
            switch (r.kind) {
                .param => if (idx.items.len >= 2 or params >= 2) {
                    // One sort of the group's slots, never a union per entry.
                    // Each entry's slots; an entry of an apart occurrence
                    // asks to be apart only.
                    for (idx.items) |i| {
                        const ap = Contract.isApart(ents.items[i].occ);
                        const lslots = e.f.slots.items(e.f.leafAt(ents.items[i].leaf).slots);
                        try e.charge(.cond, @intCast(1 + lslots.len));
                        for (lslots) |x| {
                            const rl = try e.f.slots.relOf(g, e.account(), e.places(), .from(x));
                            try occs.add(g, if (ap) Contract.occApart(r.a, rl) else Contract.occ(r.a, rl));
                        }
                    }
                },
                .call => if (idx.items.len >= 2 and !allApart(ents.items, idx.items)) {
                    // A call that does not vouch for its parts is read
                    // through what they come from (§2.9.2 step 3),
                    // each part on its own.
                    const c = if (anyApart(ents.items, idx.items)) try instCondMixed(e, r.a, ents.items, idx.items) else try instCond(e, r.a);
                    if (c.no) {
                        if (must == none or root > must) {
                            must = root;
                            unvouched = true;
                        }
                    } else if (try gather(e, &occs, c)) return Cond.unprovable;
                },
                .supply, .cb => if (idx.items.len >= 2) {
                    if (!e.expandable(e.f.leafAt(ents.items[idx.items[0]].leaf))) return Cond.unprovable;
                    if (must == none or root > must) {
                        must = root;
                        unvouched = false;
                    }
                },
            }
        }
        if (must != none) latest = must else if (latest == none or groups.count() + atoms.count() < 2) break;
        if (rounds > 4096) return Cond.unprovable;
        // The latest expandable root meets another: its entries become
        // what they come from (one level), a block it vouched for.
        next.clearRetainingCapacity();
        // An expansion of a call is one block of alternatives: one entry
        // per leaf (pairs inside a block are never compared).
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(g);
        for (ents.items) |en| {
            const l = e.f.leafAt(en.leaf);
            if (l.kind != .ref or l.root != latest) {
                try next.append(g, en);
                continue;
            }
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(g);
            try e.expand(en.leaf, &list);
            for (list.items) |x| {
                const xl = e.f.leafAt(x);
                if (xl.kind == .top or xl.kind == .shared) return Cond.unprovable;
                try e.charge(.edge, 1);
                e.route_count += 1;
                const blk = if (e.f.roots.items[latest].kind == .call and !unvouched) latest else none;
                if (blk != none and (try seen.getOrPut(g, .{x})).found_existing) continue;
                try next.append(g, .{ .leaf = x, .route = 0x4000_0000 | e.route_count, .occ = if (Contract.isApart(en.occ)) en.occ else 0, .block = blk });
            }
        }
        std.mem.swap(std.ArrayList(Ent), &ents, &next);
        // Families of the expansion ask their own separation.
        for (ents.items) |en| {
            if (en.block == none) continue;
            const l = e.f.leafAt(en.leaf);
            if (l.kind == .ref and !l.at_pos and isFamily(e, l) and !e.expandable(l) and !Contract.isApart(en.occ)) {
                if (e.f.roots.items[l.root].kind == .cb) return Cond.unprovable;
                if (try gather(e, &occs, try sepLeaf(e, en.leaf))) return Cond.unprovable;
            }
        }
    }
    if (occs.run.items.len == 0) return acc;
    return Cond.conj(e.arena, e.account(), acc, try Cond.of(e.account(), try e.arena.dupe(u64, occs.run.items)));
}

fn anyApart(ents: []const Ent, idx: []const u32) bool {
    for (idx) |i| if (Contract.isApart(ents[i].occ)) return true;
    return false;
}

fn allApart(ents: []const Ent, idx: []const u32) bool {
    for (idx) |i| if (!Contract.isApart(ents[i].occ)) return false;
    return true;
}

/// The occurrences a check gathers, each once.
const Occs = struct {
    run: std.ArrayList(u64) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    fn deinit(o: *Occs, g: Allocator) void {
        o.run.deinit(g);
        o.seen.deinit(g);
    }
    fn add(o: *Occs, g: Allocator, x: u64) Allocator.Error!void {
        if ((try o.seen.getOrPut(g, x)).found_existing) return;
        try o.run.append(g, x);
    }
};

/// Add condition `c`'s occurrences to `occs`; whether it is `no`.
/// A condition gathered again (one interned run) is not read again.
fn gather(e: *Eval, occs: *Occs, c: Cond) Error!bool {
    if (c.no) return true;
    if (c.sel.len == 0) return false;
    try e.charge(.cond, 1);
    const key: u64 = @intFromPtr(c.sel.ptr) ^ (@as(u64, c.sel.len) << 48);
    if ((try occs.seen.getOrPut(e.gpa(), key | (1 << 63))).found_existing) return false;
    try e.charge(.cond, @intCast(c.sel.len));
    for (c.sel) |x| try occs.add(e.gpa(), x);
    return false;
}

/// Whether two entries of one root may name one object: at related
/// positions whose slots meet, found through each entry's ancestors (or
/// pairwise in a group with list steps or of at most eight).
fn mayWithin(e: *Eval, ents: []const Ent, idx: []const u32, routed: bool) Error!bool {
    if (idx.len < 2) return false;
    const g = e.gpa();
    var listy = idx.len <= 8;
    if (!listy) for (idx) |i| {
        var p = e.f.leafAt(ents[i].leaf).pos;
        while (p != none and e.f.pos.items[p].parent != none) : (p = e.f.pos.items[p].parent) {
            if (e.f.pos.items[p].kind != .plain) listy = true;
        }
    };
    if (listy) {
        for (idx, 0..) |i, k| for (idx[k + 1 ..]) |j| {
            if (try pairMay(e, ents[i], ents[j], routed)) return true;
        };
        return false;
    }
    var at: Ids.FixedDict(2) = .{};
    defer at.deinit(g);
    var lists: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (lists.items) |*l| l.deinit(g);
        lists.deinit(g);
    }
    for (idx) |i| {
        const l = e.f.leafAt(ents[i].leaf);
        for (e.f.slots.items(l.slots)) |s| {
            try e.charge(.inspection, 1);
            const got = try at.getOrPut(g, .{ l.pos, s });
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(lists.items.len);
                try lists.append(g, .empty);
            }
            try lists.items[got.value_ptr.*].append(g, i);
        }
    }
    for (idx) |i| {
        const l = e.f.leafAt(ents[i].leaf);
        var p = l.pos;
        while (p != none) : (p = e.f.pos.items[p].parent) {
            for (e.f.slots.items(l.slots)) |s| {
                try e.charge(.inspection, 1);
                const here = at.get(.{ p, s }) orelse continue;
                for (lists.items[here].items) |j| {
                    if (j == i) continue;
                    if (p == l.pos and j > i) continue;
                    if (try pairMay(e, ents[i], ents[j], routed)) return true;
                }
            }
        }
    }
    return false;
}

fn pairMay(e: *Eval, a: Ent, b: Ent, routed: bool) Error!bool {
    try e.charge(.cond, 1);
    if (a.block != none and a.block == b.block) return false;
    if (a.leaf == b.leaf and a.route == b.route and a.occ == b.occ) return false;
    // Apart occurrences need only be apart from the plain ones.
    if (Contract.isApart(a.occ) and Contract.isApart(b.occ)) return false;
    const la = e.f.leafAt(a.leaf);
    const lb = e.f.leafAt(b.leaf);
    if ((try e.f.mergeTags(la.tags, lb.tags)) == null) return false;
    // Two distinct occurrences of a callee at one value by one route are
    // two distinct positions of it (§2.9.3's routed rule).
    if (routed and a.route == b.route and a.occ != b.occ and la.pos == lb.pos) return false;
    if (la.at_pos and lb.at_pos and la.pos != lb.pos) return false;
    const r = try e.f.related(la.pos, lb.pos);
    return r.rel == .related and try e.f.slots.meet(e.account(), la.slots, lb.slots);
}

// ---- the one relation (§2.9.2) -------------------------------------------

/// The relation of holder leaf `x` (deep) and target leaf `t`;
/// `target`: `t` is a shallow write target.
pub fn overlap(e: *Eval, x: u32, t: u32, target: bool) Error!Ov {
    try e.charge(.cond, 1);
    const key: [3]u32 = .{ x, t, @intFromBool(target) };
    const got = try e.ov_memo.getOrPut(e.gpa(), key);
    if (got.found_existing) {
        return if (got.value_ptr.* == none) Ov.no else e.ovs.items[got.value_ptr.*];
    }
    got.value_ptr.* = none;
    const r = try overlapRaw(e, x, t, target);
    const at: u32 = @intCast(e.ovs.items.len);
    try e.ovs.append(e.gpa(), r);
    (try e.ov_memo.getOrPut(e.gpa(), key)).value_ptr.* = at;
    return r;
}

fn overlapRaw(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    if ((try e.f.mergeTags(x.tags, t.tags)) == null) return .no;
    // A cell's `◆` is behind its barrier (§2.13.7): a write replaces
    // what the cell holds and changes no object anyone holds.
    if (t.kind == .ref and t.at_pos) {
        const tp = e.f.pos.items[t.pos];
        if (tp.kind == .plain and Step.fromWord(tp.a).kind == .contents) return .no;
    }
    if (x.kind == .top or t.kind == .top) return .may;
    const xr = x.kind == .ref;
    const tr = t.kind == .ref;
    // An unknown label's answer may be anything its closure was handed.
    if (x.kind == .answer or t.kind == .answer) return .may;
    if ((xr and e.f.roots.items[x.root].kind == .cb) or (tr and e.f.roots.items[t.root].kind == .cb)) return .may;
    if (xr and tr and x.root == t.root) return positional(e, xi, ti, target);
    if (xr or tr) {
        const ex = xr and e.expandable(x);
        const et = tr and e.expandable(t);
        if (ex or et) {
            const expand_x = if (ex and et) x.root > t.root else ex;
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(e.gpa());
            try e.expand(if (expand_x) xi else ti, &list);
            var acc: Ov = .no;
            for (list.items) |l| {
                const o = if (expand_x) try overlap(e, l, ti, target) else try overlap(e, xi, l, target);
                acc = try Ov.join(e.arena, e.account(), acc, o);
                if (acc.kind == .may) return acc;
            }
            return acc;
        }
        if (xr and tr) {
            // Two parameters: apart under both selections; the holder's
            // objects need only be apart from the target's (§2.9.1).
            const c = try Cond.conj(e.arena, e.account(), try selOf(e, e.f.roots.items[x.root].a, x.slots, true), try sel(e, e.f.roots.items[t.root].a, t.slots));
            return .{ .kind = .under, .cond = c };
        }
        // A parameter's leaf and an atom.
        return .no;
    }
    // Two atoms.
    if (x.kind == t.kind and x.atom == t.atom and x.extra == t.extra) return .may;
    return .no;
}

fn positional(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    if (x.slots == Slots.empty or t.slots == Slots.empty) return .no;
    const r = try e.f.related(x.pos, t.pos);
    if (r.rel == .related) {
        // A write of a position's own storage never meets what lies
        // inside it: no value holds itself.
        if (target and t.at_pos and r.second_prefix and x.pos != t.pos) {
            if (!(try e.f.slots.meet(e.account(), x.slots, t.slots))) return apart(e, xi, ti, target);
            // The holder below the written position holds the slot only
            // where a level folds back onto it.
        }
        if (try e.f.slots.meet(e.account(), x.slots, t.slots)) return .may;
    }
    return apart(e, xi, ti, target);
}

/// Two leaves of one root at distinct places: apart under the root's
/// separation.
fn apart(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    const r0 = e.f.roots.items[x.root];
    switch (r0.kind) {
        .param => return .{ .kind = .under, .cond = try Cond.conj(e.arena, e.account(), try selOf(e, r0.a, x.slots, true), try sel(e, r0.a, t.slots)) },
        .call => {
            const sep = try instCond(e, r0.a);
            if (!sep.no) return .{ .kind = .under, .cond = sep };
        },
        .supply, .cb => {},
    }
    if (!e.expandable(x)) return .may;
    var lx: std.ArrayList(u32) = .empty;
    defer lx.deinit(e.gpa());
    var lt: std.ArrayList(u32) = .empty;
    defer lt.deinit(e.gpa());
    try e.expand(xi, &lx);
    try e.expand(ti, &lt);
    var acc: Ov = .no;
    for (lx.items) |a| for (lt.items) |b| {
        acc = try Ov.join(e.arena, e.account(), acc, try overlap(e, a, b, target));
        if (acc.kind == .may) return acc;
    };
    return acc;
}
