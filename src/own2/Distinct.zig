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
const Subtree = @import("Subtree.zig");
const PlaceBelow = @import("PlaceBelow.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");
const Routed = @import("Routed.zig");
const Coexist = @import("Coexist.zig");

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
    const items = e.f.slots.elems(set);
    try e.charge(.cond, @intCast(1 + items.len));
    var out: std.ArrayList(u64) = .empty;
    for (items) |s| if (try occOf(e, j, s, only_apart)) |o| try out.append(e.arena, o);
    return Cond.of(e.account(), out.items);
}

/// The occurrence of parameter `j` at set element `s`: a symbol `↓p`
/// (§2.3.1) is the deep occurrence at `p`, and so is an explicit slot no
/// step below can name (`deepAt`); an exclusion asks nothing less (null:
/// the symbol's occurrence asks it).
fn occOf(e: *Eval, j: u32, s: u32, only_apart: bool) Error!?u64 {
    if (Slots.isNot(s)) return null;
    const p = Slots.pathOf(s);
    const r = try e.f.slots.relOf(e.gpa(), e.account(), e.places(), p);
    const o = if (Slots.isSub(s)) Contract.occDeep(Contract.occ(j, r)) else try deepAt(e, p, Contract.occ(j, r));
    return if (only_apart) o | Contract.apart_bit else o;
}

/// Occurrence `o` at slot path `s`, deep where no step below `s` can be
/// named (a type variable's or an opaque place, §2.9.1).
fn deepAt(e: *Eval, s: Slots.PathId, o: u64) Error!u64 {
    return switch (e.places().kind(e.places().pathPlace(s))) {
        .@"var", .@"opaque" => Contract.occDeep(o),
        else => o,
    };
}

/// Whether a leaf names a family: one of its slots is below a `[*]` or a
/// `⟲`, where many objects sit (§2.3.1); elsewhere a position's slot
/// holds one object.
fn isFamily(e: *Eval, l: Leaf) Error!bool {
    for (e.f.slots.elems(l.slots)) |s| {
        if (Slots.isNot(s)) continue;
        if (Slots.isSub(s)) {
            if (try PlaceBelow.familyBelow(e.gpa(), e.account(), e.places(), Slots.pathOf(s))) return true;
        } else if (e.f.places.isSummary(.from(s))) return true;
    }
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
    try condStates(e);
    switch (e.cond_state.items[call] & 3) {
        2 => return e.cond_of.items[call],
        1 => return Cond.unprovable,
        else => {},
    }
    e.cond_state.items[call] |= 1;
    const got = if (e.contractOf(call)) |c| try instSel(e, try e.contracts.cond(e.arena, e.contracts.head(c).res_cond), call) else Cond.unprovable;
    e.cond_state.items[call] ^= 3; // in progress → done, `mixed_on` kept
    e.cond_of.items[call] = got;
    return got;
}

/// `cond_state`'s bit while `instCondMixed` asks the call.
const mixed_on: u8 = 4;

fn condStates(e: *Eval) Error!void {
    while (e.cond_state.items.len < e.f.calls.items.len) {
        try e.cond_state.append(e.gpa(), 0);
        try e.cond_of.append(e.gpa(), .{});
    }
}

/// The callee's `res_cond` on call `call`'s arguments, for a check that
/// asks some of the call's slots only to be apart (§2.9.1): an
/// occurrence of the callee that arrives at no plain slot of the check
/// is asked apart, so that what an apart slot repeats inside it is not
/// asked once (`List.unzipHelp`'s builders, whose elements come from one
/// family of its parameter). `idx`: the call's entries of `ents`.
/// A cycle through it reads `no`, as `instCond`'s does (a fold's step fed
/// its own answer asks it inside its arguments; #1723).
fn instCondMixed(e: *Eval, call: u32, ents: []const Ent, idx: []const u32) Error!Cond {
    try condStates(e);
    if (e.cond_state.items[call] & mixed_on != 0) return Cond.unprovable;
    e.cond_state.items[call] |= mixed_on;
    defer e.cond_state.items[call] &= ~mixed_on;
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
        // A whole subtree is plain at every slot below its top: every
        // occurrence may arrive there.
        if (Subtree.symbolic(e.f.slots, e.f.leafAt(ents[i].leaf).slots)) return instSel(e, full, call);
        for (e.f.slots.items(e.f.leafAt(ents[i].leaf).slots)) |x| {
            try plain.append(g, e.f.slots.relWords(try e.f.slots.relOf(g, e.account(), e.places(), .from(x))));
        }
    }
    const out = try e.arena.alloc(u64, full.sel.len);
    for (full.sel, 0..) |o, k| {
        out[k] = o;
        if (Contract.isApart(o)) continue;
        if (!try arrivesAtPlain(e, h.res_root, o, plain.items)) out[k] = o | Contract.apart_bit;
    }
    return instSel(e, try Cond.of(e.account(), out), call);
}

/// Whether occurrence `o` of a callee may arrive at one of the result
/// slots `plain` (words from the result's root) by its result tree `res`.
/// A slot `res` does not name may hold anything.
fn arrivesAtPlain(e: *Eval, res: Contract.Node, o: u64, plain: []const []const u32) Error!bool {
    // A deep occurrence also reaches every slot below its own.
    const deep = Contract.isDeep(o);
    const ow = e.f.slots.relWords(Contract.occRel(o));
    var hits: std.ArrayList(Contract.Hit) = .empty;
    defer hits.deinit(e.gpa());
    for (plain) |words| {
        try e.charge(.cond, e.contracts.trees.count(res));
        hits.clearRetainingCapacity();
        try e.hitsAt(res, words, &hits);
        if (hits.items.len == 0) return true;
        for (hits.items) |hit| {
            const suffix = words[hit.depth..];
            for (hit.arrivals) |a| {
                if (a.kind != .param or a.j != Contract.occParam(o)) continue;
                // The arrival's slot is its own steps, then what the
                // plain slot takes on below an open one; a deep arrival
                // reaches every slot below that.
                const aw = try std.mem.concat(e.arena, u32, &.{ e.f.slots.relWords(a.slot), suffix });
                if (aw.len <= ow.len and std.mem.eql(u32, aw, ow[0..aw.len]) and (a.deep or aw.len == ow.len)) return true;
                if (deep and aw.len > ow.len and std.mem.eql(u32, ow, aw[0..ow.len])) return true;
            }
        }
    }
    return false;
}

/// A callee's condition (a selection over its parameters) on call
/// `call`'s arguments (§2.9.3's routed rule): every object at a selected
/// occurrence, projected, distinct from every other.
pub fn instSel(e: *Eval, c: Cond, call: u32) Error!Cond {
    if (c.no) return Cond.unprovable;
    if (c.sel.len == 0) return Cond.yes;
    const g = e.gpa();
    const cl = e.f.calls.items[call];
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(g);
    // A parameter asked deep apart and plain below: its objects part by part.
    var aps: std.ArrayList(Proj) = .empty;
    defer aps.deinit(g);
    var plains: std.ArrayList(Proj) = .empty;
    defer plains.deinit(g);
    defer e.parts = false;
    for (c.sel) |o| if (Contract.occParam(o) >= cl.args.len) return Cond.unprovable;
    // Each parameter's occurrences are projected by one walk of its
    // argument (§2.11.2 item 3): a step they share is read once, and a
    // value several arms reach once under their routes.
    const got = try e.arena.alloc(std.ArrayList(Proj), c.sel.len);
    for (got) |*x| x.* = .empty;
    defer for (got) |*x| x.deinit(g);
    const reqs = try e.arena.alloc(Routed.Req, c.sel.len);
    var js: std.ArrayList(u32) = .empty;
    defer js.deinit(g);
    for (c.sel, 0..) |o, i| {
        const j = Contract.occParam(o);
        if (std.mem.indexOfScalar(u32, js.items, j) != null) continue;
        try js.append(g, j);
        var n: usize = 0;
        for (c.sel[i..], i..) |x, k| if (Contract.occParam(x) == j) {
            reqs[n] = .{ .words = e.f.slots.relWords(Contract.occRel(x)), .deep = Contract.isDeep(x), .out = &got[k] };
            n += 1;
        };
        e.parts = mixed(c.sel, j);
        // Routes are per parameter: two parameters handed one value are
        // that value twice (the experiment's third requirement).
        try Routed.project(e, cl.args[j], reqs[0..n], try e.routeStep(0, 0x8000_0000 | j), 0);
    }
    for (c.sel, got) |o, *gp| {
        e.parts = mixed(c.sel, Contract.occParam(o));
        const to = if (!e.parts) &ps else if (Contract.isApart(o)) &aps else &plains;
        for (gp.items) |p| try to.append(g, .{ .leaf = p.leaf, .route = p.route, .occ = o, .routes = p.routes });
    }
    // An apart and a plain projection of one place by one route are taken
    // apart by their routes; two route sets there are written out.
    if (aps.items.len != 0 and try routesDiffer(e, aps.items, plains.items)) {
        try writeOut(e, &aps);
        try writeOut(e, &plains);
    }
    try ps.appendSlice(g, plains.items);
    try withoutPlain(e, aps.items, plains.items, &ps);
    return distinct(e, ps.items, true);
}

/// Whether two of the projections name one leaf's place by one route
/// under two route sets.
fn routesDiffer(e: *Eval, aps: []const Proj, plains: []const Proj) Error!bool {
    var at: Ids.FixedDict(4) = .{};
    defer at.deinit(e.gpa());
    for ([2][]const Proj{ aps, plains }) |ps| for (ps) |p| {
        try e.charge(.cond, 1);
        const l = e.f.leafAt(p.leaf);
        const got = try at.getOrPut(e.gpa(), .{ l.root, l.pos, l.tags, p.route });
        if (got.found_existing and got.value_ptr.* != p.routes) return true;
        got.value_ptr.* = p.routes;
    };
    return false;
}

/// Each projection of `ps` once per route of its set, its tags those of
/// the route (§2.11.2: what the walk by arms gives).
fn writeOut(e: *Eval, ps: *std.ArrayList(Proj)) Error!void {
    const g = e.gpa();
    const f = e.f;
    var out: std.ArrayList(Proj) = .empty;
    for (ps.items) |p| {
        if (p.routes == 0) {
            try out.append(g, p);
            continue;
        }
        var it = try f.sets.tags.routeIter(g, p.routes, f.leafAt(p.leaf).tags);
        defer it.deinit(g);
        while (try it.next(g, e.account())) |t| {
            try e.charge(.cond, 1);
            var l = f.leafAt(p.leaf);
            l.tags = t;
            try out.append(g, .{ .leaf = try f.leaf(l), .route = p.route, .occ = p.occ });
        }
    }
    ps.deinit(g);
    ps.* = out;
}

/// Whether occurrences `occs` ask parameter `j` deep apart somewhere and
/// plain somewhere.
fn mixed(occs: []const u64, j: u32) bool {
    var deep_apart = false;
    var plain = false;
    for (occs) |o| if (Contract.occParam(o) == j) {
        if (!Contract.isApart(o)) plain = true else if (Contract.isDeep(o)) deep_apart = true;
    };
    return deep_apart and plain;
}

/// §2.9.1: a deep apart occurrence asks apart only the objects the plain
/// occurrences of its condition do not ask plain. Both are read part by
/// part, so a route names one place in the argument: an object a plain
/// occurrence reaches at a route is taken once from the apart ones at that
/// route (as many times as the plain ones reach it, never by leaf alone:
/// one object at two places is two entries); a reference's slots lose the
/// plain ones' at its route (`Subtree.without`).
fn withoutPlain(e: *Eval, aps: []const Proj, plains: []const Proj, out: *std.ArrayList(Proj)) Error!void {
    if (aps.len == 0) return;
    const g = e.gpa();
    const f = e.f;
    var taken: Ids.FixedDict(3) = .{};
    defer taken.deinit(g);
    var refs: Ids.FixedDict(5) = .{};
    defer refs.deinit(g);
    var minus: std.ArrayList(std.ArrayList(Slots.SetId)) = .empty;
    defer {
        for (minus.items) |*m| m.deinit(g);
        minus.deinit(g);
    }
    for (plains) |p| {
        try e.charge(.cond, 1);
        const l = f.leafAt(p.leaf);
        if (l.kind == .ref) {
            const got = try refs.getOrPut(g, .{ l.root, l.pos, l.tags, p.route, p.routes });
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(minus.items.len);
                try minus.append(g, .empty);
            }
            try minus.items[got.value_ptr.*].append(g, l.slots);
            continue;
        }
        const got = try taken.getOrPut(g, .{ p.leaf, p.route, p.routes });
        got.value_ptr.* = if (got.found_existing) got.value_ptr.* + 1 else 1;
    }
    for (aps) |p| {
        try e.charge(.cond, 1);
        var l = f.leafAt(p.leaf);
        if (l.kind == .ref) {
            if (refs.get(.{ l.root, l.pos, l.tags, p.route, p.routes })) |mi| {
                l.slots = (try Subtree.without(f.slots, g, e.account(), e.places(), l.slots, minus.items[mi].items)) orelse continue;
                try out.append(g, .{ .leaf = try f.leaf(l), .route = p.route, .occ = p.occ, .routes = p.routes });
                continue;
            }
        } else if (taken.get(.{ p.leaf, p.route, p.routes })) |n| if (n != 0) {
            (try taken.getOrPut(g, .{ p.leaf, p.route, p.routes })).value_ptr.* = n - 1;
            continue;
        };
        try out.append(g, p);
    }
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

const Ent = Entries.Ent;
const Occs = Entries.Occs;

/// §2.9.3: every object the entries name is distinct from every other's,
/// by the factored check (never a table of pairs). The groups are kept
/// across rounds (`Entries.Rounds`): a round checks only the groups its
/// expansion changed, each for its new entries.
pub fn distinct(e: *Eval, ps: []const Proj, routed: bool) Error!Cond {
    const g = e.gpa();
    const f = e.f;
    var st: Entries.Rounds = .{};
    defer st.deinit(g);
    for (ps, 0..) |p, k| try st.add(g, .{ .leaf = p.leaf, .route = p.route, .occ = p.occ, .block = none, .routes = p.routes }, .{ none, @intCast(k), 0 });
    const acc: Cond = .{};
    // The conditions met, gathered and made one at the end: a merge per
    // entry or group would cost their product (§2.9.3's linear bound).
    var occs: Occs = .{};
    defer occs.deinit(g);
    // A family asks its own root's separation; ⊤ and shared objects are
    // never known to be once.
    for (st.ents.items) |en| {
        const l = f.leafAt(en.leaf);
        switch (l.kind) {
            .ref => if (!l.at_pos and try isFamily(e, l) and !Contract.isApart(en.occ)) {
                if (f.roots.items[l.root].kind == .cb and !e.expandable(l)) return Cond.unprovable;
                if (try gather(e, &occs, try sepLeaf(e, en.leaf))) return Cond.unprovable;
            },
            .top, .shared => return Cond.unprovable,
            else => {},
        }
        // A callback answer may be what the label was supplied (unknown code
        // may answer its argument): never apart from another entry that
        // reaches a supply (`pickSecond`: `( f b, b )`).
        if (l.kind == .ref and f.roots.items[l.root].kind == .cb and !e.expandable(l)) {
            var sl: std.ArrayList(u32) = .empty;
            defer sl.deinit(g);
            for (f.cbs.items[f.roots.items[l.root].a].args) |sv| try e.leavesOf(sv, 0, &sl);
            for (st.ents.items) |o| if (o.leaf != en.leaf) for (sl.items) |x| {
                if (o.routes != 0 and !try Entries.routesMeet(f, o, .{ .leaf = x, .route = 0, .occ = 0, .block = none })) continue;
                if ((try overlap(e, o.leaf, x, false)).kind != .no) return Cond.unprovable;
            };
        }
    }
    var taken: std.ArrayList(u32) = .empty;
    defer taken.deinit(g);
    var dirty: std.ArrayList(u32) = .empty;
    defer dirty.deinit(g);
    var fresh: usize = 0;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        const ents = st.ents.items;
        try e.charge(.cond, @intCast(1 + ents.len - fresh));
        if (try Entries.answerMeets(f, ents, st.alive.items, fresh)) return Cond.unprovable;
        // The new entries into their groups; a second parameter's group
        // makes every parameter group ask its occurrences.
        const params = st.params;
        for (fresh..ents.len) |i| try st.place(f, @intCast(i));
        fresh = ents.len;
        if (params < 2 and st.params >= 2) for (st.groups.items, 0..) |gr, gi| {
            if (gr.root != none and f.roots.items[gr.root].kind == .param) try st.mark(g, @intCast(gi));
        };
        std.mem.swap(std.ArrayList(u32), &dirty, &st.dirty);
        st.dirty.clearRetainingCapacity();
        for (dirty.items) |gi| st.groups.items[gi].dirty = false;
        for (dirty.items) |gi| {
            const gr = &st.groups.items[gi];
            const idx = gr.members.items;
            if (idx.len == 0) continue;
            if (gr.root == none) {
                if (try Entries.atomTwice(f, ents, idx)) return Cond.unprovable;
                continue;
            }
            if (try gr.within.add(f, ents, idx, routed)) return Cond.unprovable;
            const r = f.roots.items[gr.root];
            switch (r.kind) {
                // One entry that names several objects (a tuple a parameter
                // or a call answers whole) asks as two entries do (#1711).
                .param => if (idx.len >= 2 or st.params >= 2 or Entries.manyObjects(f, ents, idx)) {
                    // One sort of the group's slots, never a union per entry.
                    // Each entry's slots; an entry of an apart occurrence
                    // asks to be apart only. A member's are asked once.
                    for (idx[gr.occ_done..]) |i| {
                        const ap = Contract.isApart(ents[i].occ);
                        const lslots = f.slots.elems(f.leafAt(ents[i].leaf).slots);
                        try e.charge(.cond, @intCast(1 + lslots.len));
                        for (lslots) |x| if (try occOf(e, r.a, x, ap)) |o| try occs.add(g, o);
                    }
                    gr.occ_done = @intCast(idx.len);
                },
                .call => {
                    gr.must = 0;
                    if ((idx.len >= 2 or Entries.manyObjects(f, ents, idx)) and !Entries.allApart(ents, idx)) {
                        // A call that does not vouch for its parts is read
                        // through what they come from (§2.9.2 step 3),
                        // each part on its own.
                        const c = if (Entries.anyApart(ents, idx)) try instCondMixed(e, r.a, ents, idx) else try instCond(e, r.a);
                        if (c.no) {
                            // At a slot no step below can name, the arrivals
                            // are one set: `xs` twice inside a cast is one leaf
                            // there, so expansion cannot count it (#1710).
                            if (idx.len == 1 and Entries.wildEntry(f, ents[idx[0]])) return Cond.unprovable;
                            gr.must = 1;
                        } else if (try gather(e, &occs, c)) return Cond.unprovable;
                    }
                },
                .supply, .cb => {
                    gr.must = 0;
                    if (idx.len >= 2 or Entries.manyObjects(f, ents, idx)) {
                        if (!e.expandable(f.leafAt(ents[idx[0]].leaf))) return Cond.unprovable;
                        gr.must = 2;
                    }
                },
            }
            if (gr.must != 0) try Entries.Rounds.push(g, &st.musts, gr.root);
        }
        // A supply or a label meeting itself is decided by expansion.
        const must = st.top(&st.musts, struct {
            fn ok(gr: *const Entries.Group) bool {
                return gr.must != 0 and gr.members.items.len != 0;
            }
        }.ok);
        const latest = must orelse st.top(&st.expandable, struct {
            fn ok(gr: *const Entries.Group) bool {
                return gr.members.items.len != 0;
            }
        }.ok) orelse break;
        if (must == null and st.nonempty < 2) break;
        if (rounds > 4096) return Cond.unprovable;
        const unvouched = must != null and st.groups.items[st.of_root.items[latest]].must == 1;
        // The latest expandable root meets another: its entries become
        // what they come from (one level), a block it vouched for, in the
        // order the entries are read (a leaf met twice keeps its first).
        taken.clearRetainingCapacity();
        try st.take(g, latest, &taken);
        const blk = if (f.roots.items[latest].kind == .call and !unvouched) latest else none;
        if (blk != none and taken.items.len >= 2) try sortInline(e, &st, taken.items);
        // An expansion of a call is one block of alternatives: one entry
        // per leaf (pairs inside a block are never compared).
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(g);
        const start = st.ents.items.len;
        for (taken.items) |ti| {
            const en = st.ents.items[ti];
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(g);
            try e.expand(en.leaf, &list);
            for (list.items, 0..) |x, nth| {
                const xl = f.leafAt(x);
                if (xl.kind == .top or xl.kind == .shared) return Cond.unprovable;
                try e.charge(.edge, 1);
                e.route_count += 1;
                if (blk != none and (try seen.getOrPut(g, .{ x, en.routes })).found_existing) continue;
                try st.add(g, .{ .leaf = x, .route = 0x4000_0000 | e.route_count, .occ = if (Contract.isApart(en.occ)) en.occ else 0, .block = blk, .routes = en.routes }, .{ ti, @intCast(nth), st.par.items[ti][2] + 1 });
            }
        }
        // Families of the expansion ask their own separation.
        for (st.ents.items[start..]) |en| {
            if (en.block == none) continue;
            const l = f.leafAt(en.leaf);
            if (l.kind == .ref and !l.at_pos and try isFamily(e, l) and !e.expandable(l) and !Contract.isApart(en.occ)) {
                if (f.roots.items[l.root].kind == .cb) return Cond.unprovable;
                if (try gather(e, &occs, try sepLeaf(e, en.leaf))) return Cond.unprovable;
            }
        }
    }
    if (occs.run.items.len == 0) return acc;
    return Cond.conj(e.arena, e.account(), acc, try Cond.of(e.account(), try e.arena.dupe(u64, occs.run.items)));
}

/// `xs` in the inline order of the check's entries (an insertion sort by
/// `Entries.Rounds.before`, its comparisons charged).
fn sortInline(e: *Eval, st: *const Entries.Rounds, xs: []u32) Error!void {
    var i: usize = 1;
    while (i < xs.len) : (i += 1) {
        var k = i;
        while (k > 0 and try st.before(e.f, xs[k], xs[k - 1])) : (k -= 1) std.mem.swap(u32, &xs[k], &xs[k - 1]);
    }
}

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
    if (x.routes == 0 and t.routes == 0) {
        if (!try e.f.sets.tags.meet(e.f.account, x.tags, t.tags)) return .no;
    } else if (!try Coexist.setsMeet(&e.f.sets.tags, e.gpa(), e.account(), x.tags, x.routes, t.tags, t.routes)) return .no;
    // A cell's `◆` is behind its barrier (§2.13.7): a write replaces
    // what the cell holds and changes no object anyone holds.
    if (t.kind == .ref and t.at_pos) {
        const tp = e.f.pos.items[t.pos];
        if (tp.kind == .plain and Step.fromWord(tp.a).kind == .contents) return .no;
    }
    if (x.kind == .top or t.kind == .top) return .may;
    const xr = x.kind == .ref;
    const tr = t.kind == .ref;
    // An unknown label's answer may be anything its closure was handed:
    // written, anything; holding the target, what it was supplied or its
    // label's function slot holds.
    if (t.kind == .answer or (tr and e.f.roots.items[t.root].kind == .cb)) return .may;
    if (x.kind == .answer or (xr and e.f.roots.items[x.root].kind == .cb)) return answerHolds(e, x, ti, target);
    if (xr and tr and x.root == t.root) return positional(e, xi, ti, target);
    if (xr or tr) {
        // An object made after a call is none of the call's result (§2.9.2
        // step 4): no expansion, so a chain of calls is never walked again
        // per atom met at its end.
        if (madeAfter(e, x, t) or madeAfter(e, t, x)) return .no;
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

/// Whether atom `a` (a literal's or a call's fresh objects) was made
/// after the call whose result `l` is: then the result holds none of it.
fn madeAfter(e: *Eval, a: Leaf, l: Leaf) bool {
    if (l.kind != .ref or e.f.roots.items[l.root].kind != .call) return false;
    const at = switch (a.kind) {
        .site => a.atom,
        .fresh => e.f.calls.items[a.atom].point,
        else => return false,
    };
    return e.f.calls.items[e.f.roots.items[l.root].a].point < at;
}

/// What the answer `x` of a label's direct call may hold of `t` (§2.9.2
/// step 7): unknown code answers from what that call supplied it and
/// from what its function holds, the label's parameter slot. A label the
/// frame only passes on, or a target under that slot, answers anything.
fn answerHolds(e: *Eval, x: Leaf, ti: u32, target: bool) Error!Ov {
    const cb = e.f.cbs.items[if (x.kind == .answer) x.atom else e.f.roots.items[x.root].a];
    if (cb.inst == none) return .may;
    var sl: std.ArrayList(u32) = .empty;
    defer sl.deinit(e.gpa());
    for (cb.args) |sv| try e.leavesOf(sv, 0, &sl);
    var acc: Ov = .no;
    for (sl.items) |l| {
        acc = try Ov.join(e.arena, e.account(), acc, try overlap(e, l, ti, target));
        if (acc.kind == .may) return acc;
    }
    return Ov.join(e.arena, e.account(), acc, try heldBy(e, cb.j, cb.slot, ti));
}

/// What parameter `j`'s function at `slot` may hold of `t`: an object
/// made in this activation, nothing; another parameter's, what the two
/// selections keep apart.
fn heldBy(e: *Eval, j: u32, slot: Slots.Rel, ti: u32) Error!Ov {
    const t = e.f.leafAt(ti);
    if (t.kind == .site or t.kind == .fresh) return .no;
    if (t.kind != .ref) return .may;
    const r = e.f.roots.items[t.root];
    if (r.kind == .param and r.a != j) {
        var occ = [_]u64{Contract.occApart(j, slot)};
        const c = try Cond.conj(e.arena, e.account(), try Cond.of(e.account(), &occ), try sel(e, r.a, t.slots));
        return if (c.no) .may else .{ .kind = .under, .cond = c };
    }
    if (!e.expandable(t)) return .may;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(e.gpa());
    try e.expand(ti, &list);
    var acc: Ov = .no;
    for (list.items) |l| {
        acc = try Ov.join(e.arena, e.account(), acc, try heldBy(e, j, slot, l));
        if (acc.kind == .may) return acc;
    }
    return acc;
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
            if (!(try Subtree.meetIn(e.f.slots, e.gpa(), e.account(), e.places(), x.slots, t.slots))) return apart(e, xi, ti, target);
            // The holder below the written position holds the slot only
            // where a level folds back onto it.
        }
        if (try Subtree.meetIn(e.f.slots, e.gpa(), e.account(), e.places(), x.slots, t.slots)) return .may;
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
