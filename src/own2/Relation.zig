//! L6: a value's leaves and a call's instantiation
//! (`docs/design/ownership-v2.md` §2.9, §2.11.2). An `Eval` is one
//! evaluation of a walk's frame under the contracts its calls read: the
//! instantiation of each call (built once per call and caller slot), each
//! call's separation, and the relation of each pair of leaves met, all
//! kept for the evaluation and dropped with it (§2.12: an evaluation per
//! candidate generation; the walk itself is never redone). The relation and
//! the distinct check that read them are `Distinct`'s.
//!
//! **Expansion.** A leaf of a call's root names the objects the callee's
//! contract says arrive at its slots: each arrival projected onto the
//! call's arguments (§2.11.2). A supply root's leaf is a callee's supply,
//! expanded the same way; a label's answer is its virtual call's result
//! when the label's code is known (§2.11.3). An unknown label's answer is
//! compared as `may` with everything: the caller's closure may answer
//! anything it was handed.
//!
//! Obligations kept here: O1 (unknown provenance is `⊤`, never empty: an
//! unknown callee is the pessimistic contract).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const LevelCycle = @import("LevelCycle.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const KeySets = @import("KeySets.zig");
const Value = @import("Value.zig");
const FoldRead = @import("FoldRead.zig");
pub const Dests = @import("Dests.zig");

pub const Error = Ids.ChargeError;
pub const Cond = Contract.Cond;
const Frame = Value.Frame;
const Leaf = Value.Leaf;
const Step = Place.Step;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const none: u32 = Ids.none_int;

/// The relation of two leaves (§2.9.2).
pub const Ov = struct {
    kind: enum(u8) { no, under, may } = .no,
    cond: Cond = .{},

    pub const no: Ov = .{};
    pub const may: Ov = .{ .kind = .may };

    pub fn join(arena: Allocator, account: *Ids.Account, a: Ov, b: Ov) Error!Ov {
        if (a.kind == .may or b.kind == .may) return may;
        if (a.kind == .no) return b;
        if (b.kind == .no) return a;
        const c = try Cond.conj(arena, account, a.cond, b.cond);
        return if (c.no) may else .{ .kind = .under, .cond = c };
    }
};

/// What consumes a growing instantiation (§2.12 *Deliveries*): a key's
/// leaves reach it once each, the ones it saw when it subscribed and every
/// one added after. `forward` adds them to another key (`a`); the other
/// kinds are the read-off's (`Eval.zig` delivers them).
pub const SubKind = enum(u8) { forward, forward_below, describe, describe_below, effect, supply, escape, escape_fn };
/// `d`: a `describe_below` consumer's prefix slot (its key's).
pub const Sub = struct { kind: SubKind, a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0, tags: u32 = 0 };

/// A module code's parameters' places, its own place and its result's (`Walk`; `CallGraft` via `Eval.code_sig`).
pub const Sig = struct { params: []const PlaceId, own: u32, result: PlaceId };
pub const CodeSig = struct { ctx: *anyopaque, of: *const fn (ctx: *anyopaque, code: u32) Error!Sig };

/// The group being solved (§2.12): its members' drafts, read while they
/// grow, and the queue of what is still to be delivered.
pub const Live = struct {
    ctx: *anyopaque,
    /// The draft result slots of code `code` when it is a member being solved now, else null.
    draftRes: *const fn (ctx: *anyopaque, code: u32) ?*Contract.Draft.Res,
    /// Key `key` of `ev` reads member `code`'s result at relative steps `rel`.
    watch: *const fn (ctx: *anyopaque, code: u32, rel: Slots.Rel, ev: *Eval, key: u32) Error!void,
    /// Key `key` of `ev` has leaves a subscriber has not seen.
    dirty: *const fn (ctx: *anyopaque, ev: *Eval, key: u32) Error!void,
    /// A subscriber of the read-off consumes a leaf; `at`, for a key below a
    /// prefix, the leaf's slot (`Key.at`).
    deliver: *const fn (ctx: *anyopaque, ev: *Eval, sub: Sub, leaf: u32, at: u32) Error!void,
    /// Key `key` of `ev` reads member `code`'s result at and below `rel`.
    watchBelow: *const fn (ctx: *anyopaque, code: u32, rel: Slots.Rel, ev: *Eval, key: u32) Error!void,
    /// Deliver everything queued, unless a delivery is under way.
    pump: *const fn (ctx: *anyopaque) Error!void,
    /// Member `code`'s draft label `i` as the label of the same identity
    /// in contract `c` (its candidate), or null when `c` has none yet.
    labelIn: *const fn (ctx: *anyopaque, code: u32, i: u32, c: Contract.Id) ?u32,
};

/// A live instantiation: one call's leaves at one caller slot, growing.
/// A key `below` a prefix (`instBelow`) holds every arrival at the slots at
/// and below `slot`, each leaf with its caller slot in `at` (the path's
/// index, `open_bit` set for an arrival that holds by structure at every
/// slot below its own, §2.10 *Read-off*).
const Key = struct {
    call: u32,
    slot: PathId,
    which: u32,
    below: bool = false,
    leaves: std.ArrayList(u32) = .empty,
    at: std.ArrayList(u32) = .empty,
    subs: std.ArrayList(SubAt) = .empty,
    dirty: bool = false,
};
const SubAt = struct { sub: Sub, cursor: u32 };
pub const open_bit: u32 = 1 << 31;
/// A subtree of more slots than this is read through one key below its
/// top; a smaller one through a key per slot, which costs less there.
/// Both read the same leaves.
pub const below_min = Slots.below_min;

/// One projected object: its leaf and the literal route that reached it.
pub const Part = struct { leaf: u32, at: Slots.Rel };

pub const Proj = struct { leaf: u32, route: u32 = 0, occ: u64 = 0, routes: u32 = 0 };

fn noRouted(_: *Eval, _: u32, _: []const u32, _: bool, _: u32, _: *std.ArrayList(u32)) Error!void {
    unreachable;
}

pub const Eval = struct {
    f: *Frame,
    contracts: *const Contract.Table,
    arena: Allocator,
    /// `(call, caller slot, which)` → a run of `inst_leaves`; `which` is
    /// `none` for the result, else the supply `label << 16 | k`.
    inst_memo: Ids.FixedDict(3) = .{},
    inst_runs: std.ArrayList([2]u32) = .empty,
    inst_leaves: std.ArrayList(u32) = .empty,
    /// Per call: 0 unset, 1 in progress, 2 done (`cond_of`); bit 4: `Distinct.instCondMixed` asks it.
    cond_state: std.ArrayList(u8) = .empty,
    cond_of: std.ArrayList(Cond) = .empty,
    /// A holder is judged against a label's answer (§2.11.3, *An answer handed on*).
    keeping: bool = false,
    read_mode: enum { ask, strict, hope, reading } = .ask,
    /// `(leaf, leaf, target)` → `ovs` index; `none` while in progress.
    ov_memo: Ids.FixedDict(3) = .{},
    ovs: std.ArrayList(Ov) = .empty,
    /// Per `(call, callee label)`: the frame label a label passes on to (`cbs`).
    label_map: Ids.FixedDict(2) = .{},
    /// Per `(call, callee label)`: the virtual call that applies a known code.
    known: Ids.FixedDict(2) = .{},
    /// Per `(call, label)`: a cell callback's answer the cell may keep is a loan of it (§2.13.7,
    /// `Loans.lends`): an index of `lent_cells`, the cell's argument and the slot of its `◆`.
    lent: Ids.FixedDict(2) = .{},
    lent_cells: std.ArrayList([2]u32) = .empty,
    /// `instAt`'s keys in progress, by depth; a key met again adds nothing
    /// (its own value), and a result computed under a cut deeper than its
    /// own key is not kept.
    inst_stack: std.ArrayList([3]u32) = .empty,
    min_cut: usize = std.math.maxInt(usize),
    routes: Ids.FixedDict(2) = .{},
    route_count: u32 = 0,
    /// Expansions in progress (a fold's answer feeds itself): a leaf met
    /// again while it is expanded adds nothing.
    expanding: Ids.FixedDict(1) = .{},
    /// `endOf`'s answers by `(leaf, grown)`; `grown` counts what keys gained.
    end_memo: Ids.FixedDict(2) = .{},
    /// A call's leaf's atoms (`AtomSets`) by `(leaf, grown)`, sets of `atom_sets`.
    atom_memo: Ids.FixedDict(2) = .{},
    atom_sets: KeySets.Table = .{},
    atom_count: std.ArrayList(u32) = .empty,
    grown: u32 = 0,
    scratch: std.ArrayList(u32) = .empty,
    /// Set while a group is solved (§2.12): a member's call reads its
    /// growing draft, and what reads a key subscribes to it.
    live: ?*Live = null,
    /// The consumer the next `instAt` subscribes (null: a one-off read).
    cur_sub: ?Sub = null,
    keys: std.ArrayList(Key) = .empty,
    /// `(key, leaf)`: the key has the leaf; `(key, sub…)`: subscribed.
    key_has: Ids.FixedDict(2) = .{},
    key_subs: Ids.FixedDict(7) = .{},
    /// `(call, prefix, which)` → a key below the prefix; `(key, leaf, at)`.
    below_memo: Ids.FixedDict(3) = .{},
    below_has: Ids.FixedDict(3) = .{},
    /// Per call root's path: the caller slots of its callee's entries.
    slot_cols: Dests.Reads(1) = .{},
    inst_depth: u32 = 0,
    /// A read-off pass (§2.3.4 *Reading*): 0 when none.
    pass: u32 = 0,
    /// A deep projection read part by part (`Distinct.instSel`): a literal
    /// below the slot gives each part's own objects at its own route.
    parts: bool = false,
    code_sig: ?CodeSig = null,
    /// A called code: 1 for a leaf its creation made, 2 for its own
    /// parameter's, 0 else; the two may be one object (§2.11.3).
    made: ?*const fn (e: *Eval, l: Value.Leaf) u2 = null,
    /// A projection whose routes nobody reads (`arrivalLeaves`): a level walk meets a value once a place,
    /// not once a place and literal route.
    no_routes: bool = false,
    tail_place: PlaceId = .none, // The next `project`'s start, a walk's place; it clears it.
    /// An arrival's leaves at a parameter's slot (its path, when known): `Routed.paramLeaves`, set by an evaluation that instantiates.
    routed: *const fn (e: *Eval, v: u32, words: []const u32, deep: bool, path: u32, out: *std.ArrayList(u32)) Error!void = noRouted,

    pub fn deinit(e: *Eval) void {
        const g = e.f.gpa;
        e.inst_memo.deinit(g);
        e.inst_runs.deinit(g);
        e.inst_leaves.deinit(g);
        e.cond_state.deinit(g);
        e.cond_of.deinit(g);
        e.ov_memo.deinit(g);
        e.ovs.deinit(g);
        e.label_map.deinit(g);
        e.known.deinit(g);
        e.lent.deinit(g);
        e.lent_cells.deinit(g);
        e.inst_stack.deinit(g);
        e.routes.deinit(g);
        e.expanding.deinit(g);
        e.end_memo.deinit(g);
        e.atom_memo.deinit(g);
        e.atom_sets.deinit(g);
        e.atom_count.deinit(g);
        e.scratch.deinit(g);
        for (e.keys.items) |*k| {
            k.leaves.deinit(g);
            k.subs.deinit(g);
            k.at.deinit(g);
        }
        e.keys.deinit(g);
        e.key_has.deinit(g);
        e.key_subs.deinit(g);
        e.below_memo.deinit(g);
        e.below_has.deinit(g);
        e.slot_cols.deinit(g);
    }

    pub fn charge(e: *Eval, cat: Ids.Category, n: u32) Error!void {
        try e.f.account.reserve(cat, n);
    }

    pub fn places(e: *Eval) *Place.Table {
        return e.f.places;
    }

    pub fn gpa(e: *Eval) Allocator {
        return e.f.gpa;
    }

    pub fn account(e: *Eval) *Ids.Account {
        return e.f.account;
    }

    // ---- leaves of a value ---------------------------------------------------

    /// The deep leaves of value `v` (every object it reaches), appended:
    /// its leaf set (§2.3.4), `tags` merged into each element, a `many`
    /// element twice. In a pass (`pass`, with no outer tags) a set node
    /// met before adds nothing.
    pub fn leavesOf(e: *Eval, v: u32, tags: u32, out: *std.ArrayList(u32)) Error!void {
        try e.readSet(e.f.deep.items[v], tags, if (tags == 0) e.pass else 0, out);
    }

    fn readSet(e: *Eval, s: u32, tags: u32, pass: u32, out: *std.ArrayList(u32)) Error!void {
        var it = e.f.sets.iterate(s, pass);
        while (try it.next(e.gpa(), e.account())) |el| {
            var routes = try e.f.sets.tags.routeIter(e.gpa(), el.routes, (try e.f.mergeTags(el.tags, tags)) orelse continue);
            defer routes.deinit(e.gpa());
            while (try routes.next(e.gpa(), e.account())) |t| {
                try e.charge(.inspection, 1);
                var l = e.f.leafAt(el.key);
                if (l.kind == .recons) {
                    // A prepend's own storage: its base's on a re-cons (§2.13.6).
                    const x = e.f.val(l.atom);
                    if (try e.mayRecons(x)) try e.readSet(e.f.shallow.items[x.head - 1], t, pass, out);
                    continue;
                }
                if (l.kind == .ref and l.extra != 0) l = (try e.f.resolveRef(l)) orelse continue;
                l.tags = t;
                const id = try e.f.leaf(l);
                try out.append(e.gpa(), id);
                if (el.many) try out.append(e.gpa(), id);
            }
        }
    }

    pub fn valueAt(e: *Eval, v0: u32, words: []const u32) Error!u32 {
        return e.f.valueAt(v0, words);
    }

    /// A value's leaves (`deep`) or its own storage, projected at `route`.
    /// A leaf two coexisting routes reach (`many`) is read twice; the second
    /// copy is at a route of its own, so the check never takes it for the
    /// first (§2.9.3: one object at two places is two entries).
    fn readAt(e: *Eval, v: u32, deep: bool, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(e.gpa());
        if (deep) try e.leavesOf(v, tags, &ls) else try e.storageOf(v, tags, &ls);
        for (ls.items, 0..) |l, k| try out.append(e.gpa(), .{ .leaf = l, .route = if (k != 0 and ls.items[k - 1] == l) try e.routeStep(route, many_route) else route });
    }

    /// The objects at value `v`'s own storage (a shallow write's target):
    /// a built list's or record's site, a reference's position itself.
    pub fn storageOf(e: *Eval, v: u32, tags: u32, out: *std.ArrayList(u32)) Error!void {
        try e.readSet(e.f.shallow.items[v], tags, 0, out);
    }

    /// Whether prepend `x` may answer its base's own array: a re-cons, when
    /// the item put in front is `Js.same` as the element stored just before
    /// the base's view. An object made after the base (a literal, a call's
    /// fresh objects) is none of the base's, so it cannot be (`PrependFresh`).
    fn mayRecons(e: *Eval, x: Value.Val) Error!bool {
        const saved = e.pass;
        e.pass = 0;
        defer e.pass = saved;
        const ks = e.f.kidsOf(x);
        if (ks.len < 2) return true;
        const birth = e.bornAt(x.head - 1);
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(e.gpa());
        try e.leavesOf(ks[ks.len - 2], 0, &ls);
        if (ls.items.len == 0) return true;
        var depth: u32 = 0;
        while (ls.items.len != 0) : (depth += 1) {
            if (depth > 4) return true;
            var next: std.ArrayList(u32) = .empty;
            defer next.deinit(e.gpa());
            for (ls.items) |li| {
                const l = e.f.leafAt(li);
                switch (l.kind) {
                    .site => if (birth == none or l.atom <= birth) return true,
                    .fresh => if (birth == none or e.f.calls.items[l.atom].point <= birth) return true,
                    .ref => {
                        if (!e.expandable(l) or e.f.roots.items[l.root].kind != .call) return true;
                        if (birth == none or e.f.calls.items[e.f.roots.items[l.root].a].point <= birth) return true;
                        try e.expand(li, &next);
                    },
                    else => return true,
                }
            }
            std.mem.swap(std.ArrayList(u32), &ls, &next);
        }
        return false;
    }

    /// The point value `v` was made at: a parameter's before every point,
    /// a call's at the call, a built one at its instruction; `none` unknown.
    fn bornAt(e: *Eval, v: u32) u32 {
        const x = e.f.val(v);
        return switch (x.kind) {
            .ref => switch (e.f.roots.items[x.root].kind) {
                .param => 0,
                .call => e.f.calls.items[e.f.roots.items[x.root].a].point,
                else => none,
            },
            .built => if (x.site != none) x.site else none,
            else => none,
        };
    }

    // ---- projection of an arrival onto a value -------------------------------

    /// The kid of `routeStep` that a `many` leaf's second copy takes.
    const many_route: u32 = none - 1;

    pub fn routeStep(e: *Eval, route: u32, kid: u32) Error!u32 {
        try e.charge(.path, 1);
        const g = try e.routes.getOrPut(e.gpa(), .{ route, kid });
        if (!g.found_existing) {
            e.route_count += 1;
            g.value_ptr.* = e.route_count;
        }
        return g.value_ptr.*;
    }

    /// The objects of value `v` at relative steps `words`: what an arrival
    /// at those steps names in this frame. `deep`: every object below too.
    pub fn project(e: *Eval, v: u32, words: []const u32, deep: bool, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
        const given = e.tail_place;
        e.tail_place = .none;
        const Item = struct { v: u32, at: u32, tags: u32, route: u32 };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(e.gpa());
        try stack.append(e.gpa(), .{ .v = v, .at = 0, .tags = tags, .route = route });
        while (stack.pop()) |it| {
            try e.charge(.inspection, 1);
            const x = e.f.val(it.v);
            const rest = words[it.at..];
            switch (x.kind) {
                .scalar, .bot => {},
                .top, .host => try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = if (x.kind == .host) .host else .top, .root = if (x.kind == .top) x.site else none, .tags = it.tags }), .route = it.route }),
                .shared => try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .shared, .atom = x.head, .extra = x.site, .tags = it.tags }), .route = it.route }),
                .alt => {
                    // Read deep whole: its leaf set, the leaves its arms give.
                    if (rest.len == 0 and deep and !e.parts) {
                        try e.readAt(it.v, true, it.tags, it.route, out);
                        continue;
                    }
                    const ks = e.f.kidsOf(x);
                    var i: usize = 0;
                    while (i < ks.len) : (i += 2) {
                        const t = (try e.f.mergeTags(it.tags, try e.f.internTags(&.{.{ x.head, try e.f.armOf(ks[i]) }}))) orelse continue;
                        try stack.append(e.gpa(), .{ .v = ks[i + 1], .at = it.at, .tags = t, .route = it.route });
                    }
                },
                .ref => {
                    var all: std.ArrayList(u32) = .empty;
                    defer all.deinit(e.gpa());
                    const tops: []const u32 = if (x.family != Slots.empty) e.f.slots.items(x.family) else &.{e.f.pos.items[x.pos].slot.int()};
                    // A step an opaque or a type variable's place cannot follow
                    // (a cast's inner, §2.13.9) is some object inside it: all
                    // of what it reaches, read approximately.
                    var inside: std.ArrayList(u32) = .empty;
                    defer inside.deinit(e.gpa());
                    for (tops) |t| {
                        const before = all.items.len;
                        try Slots.replay(e.gpa(), e.account(), e.places(), .from(t), rest, &all);
                        if (all.items.len == before and rest.len != 0) {
                            const k = e.places().kind(e.places().pathPlace(.from(t)));
                            if (k == .@"opaque" or k == .@"var") {
                                // A call's result read on past its place: through what arrives there.
                                if (x.family == Slots.empty and try e.throughCall(x.root, .from(t), rest, deep, it.tags, it.route, out)) continue;
                                try inside.append(e.gpa(), t);
                            } else if (try FoldRead.prefix(e, .from(t), rest, &inside) and e.f.roots.items[x.root].kind != .param) try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .top, .tags = it.tags }), .route = it.route });
                        }
                    }
                    var set = try e.f.slots.setOf(e.gpa(), e.account(), e.places(), all.items);
                    if (deep) set = try Subtree.belowSet(e.f.slots, e.gpa(), e.account(), e.places(), try e.f.slots.sorted(e.gpa(), e.account(), all.items));
                    for (inside.items) |t| set = try e.f.slots.unionOf(e.gpa(), e.account(), set, try Subtree.below(e.f.slots, e.gpa(), e.account(), e.places(), .from(t)));
                    if (set == Slots.empty) continue;
                    try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set, .tags = it.tags }), .route = it.route });
                },
                .built => {
                    if (rest.len == 0 and deep and e.parts) {
                        if (x.site != none) try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .site, .atom = x.site, .tags = it.tags }), .route = it.route });
                        if (x.form == .list and x.head != 0) {
                            try e.readAt(x.head - 1, false, it.tags, it.route, out);
                        }
                        for (e.f.kidsOf(x), 0..) |k, n| try stack.append(e.gpa(), .{ .v = k, .at = it.at, .tags = it.tags, .route = try e.routeStep(it.route, @intCast(n)) });
                        continue;
                    }
                    if (rest.len == 0) {
                        try e.readAt(it.v, deep, it.tags, it.route, out);
                        continue;
                    }
                    const st = Step.fromWord(rest[0]);
                    const ks = e.f.kidsOf(x);
                    switch (st.kind) {
                        .ctor_arg => if (x.form == .ctor) {
                            const ca = e.places().ctorArgOf(st);
                            if (ca[0] == x.head and ca[1] < ks.len) try stack.append(e.gpa(), .{ .v = ks[ca[1]], .at = it.at + 1, .tags = it.tags, .route = try e.routeStep(it.route, ca[1]) });
                        },
                        .index => if (x.form == .tuple and st.payload < ks.len) {
                            try stack.append(e.gpa(), .{ .v = ks[st.payload], .at = it.at + 1, .tags = it.tags, .route = try e.routeStep(it.route, st.payload) });
                        },
                        .elem => if (x.form == .list) {
                            for (ks, 0..) |k, n| try stack.append(e.gpa(), .{ .v = k, .at = it.at + 1, .tags = it.tags, .route = try e.routeStep(it.route, @intCast(n)) });
                        },
                        .field => if (x.form == .record) {
                            for (e.f.wordsOf(x.extra), 0..) |r, k| if (r == st.payload) try stack.append(e.gpa(), .{ .v = ks[k], .at = it.at + 1, .tags = it.tags, .route = try e.routeStep(it.route, @intCast(k)) });
                        },
                        .env => if (x.form == .closure) {
                            // A closure's environment: its captures, whole.
                            for (ks, 0..) |k, n| try stack.append(e.gpa(), .{ .v = k, .at = @intCast(words.len), .tags = it.tags, .route = try e.routeStep(it.route, @intCast(n)) });
                        },
                        .level => try e.projectLevels(it.v, LevelCycle.of(e.places(), if (given != .none) given else LevelCycle.rootOf(e.f, v), words[0..it.at], x.place), st.payload, words[it.at + 1 ..], deep, it.tags, it.route, out),
                        else => {
                            // A step the literal cannot follow: every object of it.
                            try e.readAt(it.v, true, it.tags, try e.routeStep(it.route, none), out);
                        },
                    }
                },
            }
        }
    }

    /// Project a call's result at slot `t` on by `rest`, steps `t`'s place
    /// cannot follow (an opaque value read back): through each arrival at
    /// `t`, the rest taken from the argument it names. Whether it could
    /// (a fixed contract with no arrival but parameters').
    pub fn throughCall(e: *Eval, root: u32, t: PathId, rest: []const u32, deep: bool, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!bool {
        const r = e.f.roots.items[root];
        if (r.kind != .call) return false;
        const call = e.f.calls.items[r.a];
        if (call.contract == none) return false;
        if (e.live) |lv| if (call.code != none and lv.draftRes(lv.ctx, call.code) != null) return false;
        const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), t));
        var arrs: std.ArrayList(struct { a: Contract.Arrival, n: usize }) = .empty;
        defer arrs.deinit(e.gpa());
        var hits: std.ArrayList(Contract.Hit) = .empty;
        defer hits.deinit(e.gpa());
        try e.hitsAt(e.contracts.head(call.contract).res_root, words, &hits);
        for (hits.items) |hit| for (hit.arrivals) |a| {
            if (a.kind != .param or a.j >= call.args.len) return false;
            try arrs.append(e.gpa(), .{ .a = a, .n = hit.depth });
        };
        if (arrs.items.len == 0) return false;
        for (arrs.items) |x| {
            var w: std.ArrayList(u32) = .empty;
            defer w.deinit(e.gpa());
            try w.appendSlice(e.gpa(), e.f.slots.relWords(x.a.slot));
            try w.appendSlice(e.gpa(), words[x.n..]);
            try w.appendSlice(e.gpa(), rest);
            try e.charge(.edge, 1);
            const before = out.items.len;
            try e.project(call.args[x.a.j], w.items, deep or x.a.deep, tags, route, out);
            // A whole value cast is read back by its own structure: the
            // rest from the argument's root too; and when neither reading
            // names anything, it is some object inside it (§2.13.9).
            if (x.a.deep) {
                try e.project(call.args[x.a.j], rest, deep, tags, route, out);
                if (out.items.len == before) try e.project(call.args[x.a.j], e.f.slots.relWords(x.a.slot), true, tags, route, out);
            }
        }
        return true;
    }

    /// The shortest steps from path `from` to a path at place `target`,
    /// into `out` (nothing when there is none).
    pub fn stepsTo(e: *Eval, from: PathId, target: PlaceId, out: *std.ArrayList(u32)) Error!void {
        const pl = e.places();
        const Item = struct { p: PathId, back: u32, word: u32 };
        var queue: std.ArrayList(Item) = .empty;
        defer queue.deinit(e.gpa());
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(e.gpa());
        try queue.append(e.gpa(), .{ .p = from, .back = none, .word = 0 });
        _ = try seen.getOrPut(e.gpa(), .{from.int()});
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const it = queue.items[qi];
            try e.charge(.path, 1);
            if (qi != 0 and pl.pathPlace(it.p) == target) {
                var k: u32 = @intCast(qi);
                while (k != 0 and queue.items[k].back != none) : (k = queue.items[k].back) try out.append(e.gpa(), queue.items[k].word);
                std.mem.reverse(u32, out.items);
                return;
            }
            for (pl.steps(pl.pathPlace(it.p)).steps) |st| {
                if (st.kind == .level) continue;
                const nx = (try pl.extend(e.gpa(), e.f.gc(), it.p, st)) orelse continue;
                if ((try seen.getOrPut(e.gpa(), .{nx.int()})).found_existing) continue;
                try queue.append(e.gpa(), .{ .p = nx, .back = @intCast(qi), .word = st.word() });
            }
        }
    }

    /// `⟲` into a built value, at `place` (`LevelCycle`): the values one or more levels below, at the
    /// same place, through the parts that stay on its cycle; then `rest`
    /// from each (the experiment's fourth requirement). A part not built
    /// here gives its levels by its own slots, never its own storage.
    fn projectLevels(e: *Eval, v: u32, place: PlaceId, w: u32, rest: []const u32, deep: bool, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
        if (place == .none) {
            try e.readAt(v, true, tags, route, out);
            return;
        }
        const pl = e.places();
        const Item = struct { v: u32, place: PlaceId, route: u32, below: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(e.gpa());
        try stack.append(e.gpa(), .{ .v = v, .place = place, .route = route, .below = false });
        var met: Ids.FixedDict(4) = .{};
        defer met.deinit(e.gpa());
        while (stack.pop()) |it| {
            if ((try met.getOrPut(e.gpa(), .{ it.v, it.place.int(), @intFromBool(it.below), if (e.no_routes) 0 else it.route })).found_existing) continue;
            try e.charge(.inspection, 1);
            const x = e.f.val(it.v);
            switch (x.kind) {
                .built => {
                    if (it.below and try LevelCycle.level(pl, e.gpa(), e.f.gc(), w, it.place, place)) try e.project(it.v, rest, deep, tags, it.route, out);
                    for (e.f.kidsOf(x), 0..) |k, n| {
                        const kst: Step = switch (x.form) {
                            .list => Step.elem,
                            .record => try Step.field(e.account(), e.f.wordsOf(x.extra)[n]),
                            .tuple => try Step.index(e.account(), @intCast(n)),
                            .ctor => try pl.ctorStep(e.gpa(), e.account(), x.head, @intCast(n)),
                            .closure, .opaque_ => continue,
                        };
                        const kp = pl.child(it.place, kst) orelse continue;
                        if (!try LevelCycle.way(pl, e.gpa(), e.f.gc(), w, kp, place)) continue;
                        try stack.append(e.gpa(), .{ .v = k, .place = kp, .route = try e.routeStep(it.route, @intCast(n)), .below = true });
                    }
                },
                .scalar, .bot => {},
                .ref => if (it.below) {
                    if (try LevelCycle.level(pl, e.gpa(), e.f.gc(), w, it.place, place)) try e.project(it.v, rest, deep, tags, it.route, out);
                    // A part on the cycle at another place (a `List T` below a
                    // `T`): its next level is the steps to the cycle's place.
                    var to: std.ArrayList(u32) = .empty;
                    defer to.deinit(e.gpa());
                    if (!try LevelCycle.level(pl, e.gpa(), e.f.gc(), w, it.place, place) and x.family == Slots.empty) try e.stepsTo(e.f.pos.items[x.pos].slot, place, &to);
                    // Its own levels below, by its slots (never its own storage).
                    var lv: std.ArrayList(u32) = .empty;
                    defer lv.deinit(e.gpa());
                    if (to.items.len != 0) {
                        try lv.appendSlice(e.gpa(), to.items);
                        try lv.appendSlice(e.gpa(), rest);
                        try e.project(it.v, lv.items, deep, tags, it.route, out);
                        lv.clearRetainingCapacity();
                        try lv.appendSlice(e.gpa(), to.items);
                    }
                    try lv.append(e.gpa(), (Step{ .kind = .level, .payload = @intCast(w) }).word());
                    try lv.appendSlice(e.gpa(), rest);
                    try e.project(it.v, lv.items, deep, tags, it.route, out);
                },
                .alt => {
                    const ks = e.f.kidsOf(x);
                    var i: usize = 0;
                    while (i < ks.len) : (i += 2) try stack.append(e.gpa(), .{ .v = ks[i + 1], .place = it.place, .route = it.route, .below = it.below });
                },
                else => if (it.below) try e.project(it.v, rest, deep, tags, it.route, out),
            }
        }
    }

    // ---- instantiation (§2.11.2) ---------------------------------------------

    /// The result tree of contract `c` (`which` none) or of its supply `(label << 16) | k`.
    pub fn resRoot(e: *Eval, c: Contract.Id, which: u32) Contract.Node {
        const h = e.contracts.head(c);
        if (which == none) return h.res_root;
        const l = e.contracts.labelsOf(h.labels)[which >> 16];
        for (e.contracts.suppliesOf(l.supplies)) |s| if (s.k == (which & 0xffff)) return s.res_root;
        return 0;
    }

    /// What arrives at slot `words` of tree `root` (`Trees.Table.atSlot`):
    /// a walk of the slot's steps, the instantiation's own lookup, which
    /// the key it fills pays for (§4.1); a test that reads a contract
    /// pays an inspection a node visited (`uniformAtoms`).
    pub fn hitsAt(e: *Eval, root: Contract.Node, words: []const u32, out: *std.ArrayList(Contract.Hit)) Error!void {
        _ = try Forest.atSlot(&e.contracts.trees, e.gpa(), root, words, out);
    }

    pub fn contractOf(e: *Eval, call: u32) ?Contract.Id {
        const c = e.f.calls.items[call].contract;
        return if (c == none) null else c;
    }

    /// The leaves the callee of `call` says arrive at caller slot `slot`
    /// (a path under the call's result root), or, with `which` a supply
    /// `(label << 16) | k`, at the supply's slot. Built once per key.
    pub fn instAt(e: *Eval, call: u32, slot: PathId, which: u32) Error![]const u32 {
        // What these fill is kept: never read under a pass (§2.3.4).
        const saved_pass = e.pass;
        e.pass = 0;
        defer e.pass = saved_pass;
        if (e.live) |lv| return e.instAtLive(lv, call, slot, which);
        try e.charge(.memo, 1);
        const key: [3]u32 = .{ call, slot.int(), which };
        if (e.inst_memo.get(key)) |r| {
            const run = e.inst_runs.items[r];
            return e.inst_leaves.items[run[0]..][0..run[1]];
        }
        for (e.inst_stack.items, 0..) |x, d| if (std.mem.eql(u32, &x, &key)) {
            e.min_cut = @min(e.min_cut, d);
            return &.{};
        };
        const depth = e.inst_stack.items.len;
        try e.inst_stack.append(e.gpa(), key);
        defer _ = e.inst_stack.pop();
        var acc: std.ArrayList(u32) = .empty;
        defer acc.deinit(e.gpa());
        if (e.contractOf(call)) |c| {
            const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), slot));
            var hits: std.ArrayList(Contract.Hit) = .empty;
            defer hits.deinit(e.gpa());
            try e.hitsAt(e.resRoot(c, which), words, &hits);
            for (hits.items) |hit| for (hit.arrivals) |a| try e.arrivalLeaves(call, c, Subtree.readAt(e.places(), a, slot, hit.open), words[hit.depth..], &acc);
        } else {
            // The pessimistic contract: whatever arrives is unknown.
            try acc.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
        }
        const start: u32 = @intCast(e.inst_leaves.items.len);
        try e.inst_leaves.appendSlice(e.gpa(), acc.items);
        const keep = e.min_cut >= depth;
        if (e.min_cut == depth) e.min_cut = std.math.maxInt(usize);
        if (keep) try e.inst_memo.put(e.gpa(), key, @intCast(e.inst_runs.items.len));
        try e.inst_runs.append(e.gpa(), .{ start, @intCast(acc.items.len) });
        return e.inst_leaves.items[start..][0..acc.items.len];
    }

    /// `instAt` while a group is solved (§2.12 *Deliveries*): the key is
    /// made once, filled from the callee's contract or, for a member, from
    /// its draft as it stands; it grows when the draft does, and the
    /// consumer reading it (`cur_sub`) gets every leaf, now or later.
    fn instAtLive(e: *Eval, lv: *Live, call: u32, slot: PathId, which: u32) Error![]const u32 {
        try e.charge(.memo, 1);
        const sub = e.cur_sub;
        const keyv: [3]u32 = .{ call, slot.int(), which };
        if (e.inst_memo.get(keyv)) |ki| {
            // A consumer already subscribed has had these leaves, and gets
            // the rest: it reads nothing twice (and a fold's answer that
            // feeds itself ends here).
            if (sub) |s| if (!try e.subscribe(ki, s)) return &.{};
            return e.keys.items[ki].leaves.items;
        }
        const ki: u32 = @intCast(e.keys.items.len);
        try e.keys.append(e.gpa(), .{ .call = call, .slot = slot, .which = which });
        try e.inst_memo.put(e.gpa(), keyv, ki);
        e.inst_depth += 1;
        e.cur_sub = .{ .kind = .forward, .a = ki };
        defer e.cur_sub = sub;
        const code = e.f.calls.items[call].code;
        const draft = if (which == none and code != none) lv.draftRes(lv.ctx, code) else null;
        const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), slot));
        if (draft) |list| {
            // A member: its draft now, and what it gains later (`feed`).
            try lv.watch(lv.ctx, code, try e.f.slots.relOf(e.gpa(), e.account(), e.places(), slot), e, ki);
            var si: usize = 0;
            while (si < list.items.items.len) : (si += 1) {
                const rs = list.items.items[si];
                const rw = e.f.slots.relWords(rs.slot);
                if (rw.len > words.len or !std.mem.eql(u32, rw, words[0..rw.len])) continue;
                if (rs.node == 0) {
                    if (rw.len == words.len or list.isOpen(rs)) try e.feedDraft(ki, rs.a, @intCast(rw.len), list.isOpen(rs));
                    continue;
                }
                // A subtree made whole: what it says at the slot's steps.
                var hits: std.ArrayList(Contract.Hit) = .empty;
                defer hits.deinit(e.gpa());
                try e.hitsAt(rs.node, words[rw.len..], &hits);
                var arrs: std.ArrayList(struct { a: Contract.Arrival, n: u32, open: bool }) = .empty;
                defer arrs.deinit(e.gpa());
                for (hits.items) |hit| for (hit.arrivals) |a| try arrs.append(e.gpa(), .{ .a = a, .n = @intCast(rw.len + hit.depth), .open = hit.open });
                for (arrs.items) |x| try e.feedDraft(ki, x.a, x.n, x.open);
            }
        } else if (e.contractOf(call)) |c| {
            var hits: std.ArrayList(Contract.Hit) = .empty;
            defer hits.deinit(e.gpa());
            try e.hitsAt(e.resRoot(c, which), words, &hits);
            for (hits.items) |hit| for (hit.arrivals) |a| try e.feed(ki, a, hit.depth, hit.open);
        } else try e.addLeaf(ki, try e.f.leaf(.{ .kind = .top }));
        e.cur_sub = sub;
        e.inst_depth -= 1;
        // What the queue adds now is in the run returned; the consumer
        // subscribes after it, so it gets each leaf once.
        if (e.inst_depth == 0) try lv.pump(lv.ctx);
        if (sub) |s| _ = try e.subscribe(ki, s);
        return e.keys.items[ki].leaves.items;
    }

    /// Every arrival of call `call`'s callee at the caller slots at and below
    /// `prefix` (a path under the call's result root), each with its slot:
    /// one key per prefix, never one per slot below it. A callee's entry at a
    /// slot below the prefix is read there; an open entry above it is read at
    /// the prefix, open (§2.10 *Read-off*). Items are `(leaf, at)` pairs of
    /// the key's `leaves` and `at`.
    pub fn instBelow(e: *Eval, call: u32, prefix: PathId, which: u32) Error!u32 {
        // What these fill is kept: never read under a pass (§2.3.4).
        const saved_pass = e.pass;
        e.pass = 0;
        defer e.pass = saved_pass;
        try e.charge(.memo, 1);
        const sub = e.cur_sub;
        const keyv: [3]u32 = .{ call, prefix.int(), which };
        if (e.below_memo.get(keyv)) |ki| {
            if (sub) |s| if (e.live != null) {
                _ = try e.subscribe(ki, s);
            };
            return ki;
        }
        const ki: u32 = @intCast(e.keys.items.len);
        try e.keys.append(e.gpa(), .{ .call = call, .slot = prefix, .which = which, .below = true });
        try e.below_memo.put(e.gpa(), keyv, ki);
        e.inst_depth += 1;
        const code = e.f.calls.items[call].code;
        const draft: ?*Contract.Draft.Res = if (e.live) |lv| (if (which == none and code != none) lv.draftRes(lv.ctx, code) else null) else null;
        const pw = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), prefix));
        if (draft) |list| {
            const lv = e.live.?;
            try lv.watchBelow(lv.ctx, code, try e.f.slots.relOf(e.gpa(), e.account(), e.places(), prefix), e, ki);
            var si: usize = 0;
            while (si < list.items.items.len) : (si += 1) {
                const rs = list.items.items[si];
                if (rs.node == 0) {
                    try e.feedBelowDraft(ki, rs.slot, list.isOpen(rs), rs.a);
                    continue;
                }
                try e.feedTree(ki, rs.node, e.f.slots.relWords(rs.slot), true);
            }
        } else if (e.contractOf(call)) |c| {
            // The entries at and below the prefix, then the open ones above
            // it: the prefix's steps walked from the root.
            const root = e.resRoot(c, which);
            try e.charge(.inspection, @intCast(1 + std.math.log2_int_ceil(usize, @as(usize, e.contracts.trees.count(root)) + 1)));
            if (Forest.at(&e.contracts.trees, root, pw)) |n| try e.feedTree(ki, n, pw, false);
            var n = root;
            for (0..pw.len) |d| {
                const opens = try e.gpa().dupe(Contract.Arrival, e.contracts.trees.open(n));
                defer e.gpa().free(opens);
                if (opens.len != 0) {
                    const rel = e.f.slots.rels.find(pw[0..d]) orelse try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), pw[0..d]);
                    for (opens) |a| try e.feedBelow(ki, rel, true, a);
                }
                n = e.contracts.trees.kidAt(n, pw[d]) orelse break;
            }
        } else try e.addBelow(ki, try e.f.leaf(.{ .kind = .top }), prefix.int() | open_bit);
        e.inst_depth -= 1;
        if (e.inst_depth == 0) if (e.live) |lv| try lv.pump(lv.ctx);
        if (sub) |s| if (e.live != null) {
            _ = try e.subscribe(ki, s);
        };
        return ki;
    }

    /// Every entry of tree `n`, its slots `prefix` and below, for below-key
    /// `ki` (`draft`: a member's, its labels renamed).
    fn feedTree(e: *Eval, ki: u32, n: Contract.Node, prefix: []const u32, draft: bool) Error!void {
        var es: Forest.Entries = .{};
        defer es.deinit(e.gpa());
        try es.of(&e.contracts.trees, e.gpa(), e.places(), n, prefix);
        var arrs: std.ArrayList(Contract.Arrival) = .empty;
        defer arrs.deinit(e.gpa());
        for (es.items.items) |x| {
            // A slot the callee named is interned already: read, not made.
            const rel = e.f.slots.rels.find(es.wordsOf(x)) orelse try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), es.wordsOf(x));
            arrs.clearRetainingCapacity();
            try arrs.appendSlice(e.gpa(), x.arrivals);
            for (arrs.items) |a| if (draft) try e.feedBelowDraft(ki, rel, x.open, a) else try e.feedBelow(ki, rel, x.open, a);
        }
    }

    /// An item of a key below a prefix as a plain leaf: an open one stands
    /// for its subtree, every slot below its own.
    pub fn widen(e: *Eval, x: u32, at: u32) Error!u32 {
        if (at & open_bit == 0) return x;
        const l = e.f.leafAt(x);
        if (l.kind != .ref) return x;
        var w = l;
        w.slots = try Subtree.belowSet(e.f.slots, e.gpa(), e.account(), e.places(), l.slots);
        w.at_pos = false;
        return e.f.leaf(w);
    }

    /// The callee's arrival `a` at its result slot `rel` (`open`: and below)
    /// for below-key `ki`: read at that slot when it is at or below the
    /// key's prefix, at the prefix, open, when the slot is open above it.
    pub fn feedBelow(e: *Eval, ki: u32, rel: Slots.Rel, open: bool, a: Contract.Arrival) Error!void {
        const k = e.keys.items[ki];
        const r = e.f.roots.items[e.rootOfKey(ki)];
        const pw = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), k.slot));
        const rw = e.f.slots.relWords(rel);
        if (rw.len >= pw.len and std.mem.eql(u32, pw, rw[0..pw.len])) {
            // The caller slots of the entry: the root's column.
            const col = &e.slot_cols.cols.items[try e.slot_cols.col(e.gpa(), .{r.path.int()})];
            try Dests.addRel(.{ .gpa = e.gpa(), .account = e.account(), .places = e.places(), .slots = e.f.slots }, col, r.path, rel);
            var paths: std.ArrayList(u32) = .empty;
            defer paths.deinit(e.gpa());
            try paths.appendSlice(e.gpa(), col.at(rel).?);
            if (paths.items.len == 0) try paths.append(e.gpa(), k.slot.int());
            for (paths.items) |at0| try e.feedAt(ki, .from(at0), @intCast(rw.len), open, a);
        } else if (open and rw.len < pw.len and std.mem.eql(u32, rw, pw[0..rw.len])) {
            try e.feedAt(ki, k.slot, @intCast(rw.len), true, a);
        }
    }

    /// Arrival `a` of an entry `n` steps from the call's root, read at the
    /// caller slot `base` at or below it; `open`: and at every caller slot
    /// below `base`. An atom is the same at every slot (one open item); a
    /// projection that gives only `⊤` or shared objects at `base` gives them
    /// below it too. Anything else open is its projection at `base`, read
    /// once, and at each slot below through that slot's own key (`instAt`),
    /// which every reader of the slot shares. A plain entry's atom is itself
    /// at `base`; any other plain arrival is read through `base`'s key.
    fn feedAt(e: *Eval, ki: u32, base: PathId, n: u32, open: bool, a: Contract.Arrival) Error!void {
        const k = e.keys.items[ki];
        const saved = e.cur_sub;
        defer e.cur_sub = saved;
        if (open) {
            var acc: std.ArrayList(u32) = .empty;
            defer acc.deinit(e.gpa());
            const bw = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), base));
            const suffix0 = try e.gpa().dupe(u32, bw[@min(n, bw.len)..]);
            defer e.gpa().free(suffix0);
            const at_base = base.int() | open_bit;
            e.cur_sub = .{ .kind = .forward_below, .a = ki, .b = at_base };
            try e.arrivalLeaves(k.call, none, a, suffix0, &acc);
            // What holds below `base`: an arrival by structure (§2.10) is
            // the argument's whole subtree there, not its slot's objects.
            var below: std.ArrayList(u32) = .empty;
            defer below.deinit(e.gpa());
            var da = a;
            da.deep = true;
            if (a.kind == .param and !a.deep) try e.arrivalLeaves(k.call, none, da, suffix0, &below) else try below.appendSlice(e.gpa(), acc.items);
            var atoms: std.ArrayList(u32) = .empty;
            defer atoms.deinit(e.gpa());
            var uniform = true;
            for (below.items) |x| if (!try e.uniformAtoms(x, &atoms)) {
                uniform = false;
                break;
            };
            if ((uniform and below.items.len != 0) or a.kind == .fresh or a.kind == .top or a.kind == .shared or a.kind == .host) {
                for (if (uniform) atoms.items else below.items) |x| try e.addBelow(ki, x, at_base);
                return;
            }
            // A call's or a supply's result at `base` is open there: its
            // subtree is read through that call's own key below it.
            var calls = true;
            for (below.items) |x| {
                const xl = e.f.leafAt(x);
                if (xl.kind != .ref or !e.expandable(xl)) calls = false;
            }
            if (calls and below.items.len != 0) {
                for (below.items) |x| try e.addBelow(ki, x, at_base);
                return;
            }
            // An argument's subtree by structure (§2.10 *Arrivals by
            // structure*): each slot below is the argument projected there,
            // deep where no step below it can be named, never a key of its own.
            // A deep arrival (a type variable's slot) is all of it at each.
            if (a.kind == .param and !a.deep) {
                // A parameter's whole subtree at the slot's own place is that
                // one open item: its slots below fold as the slot's, so the
                // read-off says it open again (one normal form, §2.11.2).
                var whole = below.items.len != 0;
                for (below.items) |x| {
                    const xl = e.f.leafAt(x);
                    if (xl.kind != .ref or e.f.roots.items[xl.root].kind != .param or xl.at_pos) {
                        whole = false;
                        break;
                    }
                    const ps = e.f.pos.items[xl.pos].slot;
                    if (e.places().pathPlace(ps) != e.places().pathPlace(base) or (Subtree.wholeOf(e.f.slots, xl.slots) != ps and xl.slots != try Subtree.below(e.f.slots, e.gpa(), e.account(), e.places(), ps))) whole = false;
                }
                if (whole) {
                    for (below.items) |x| try e.addBelow(ki, x, at_base);
                    return;
                }
                var at: std.ArrayList(u32) = .empty;
                defer at.deinit(e.gpa());
                for (e.f.slots.items(try Subtree.belowAll(e.f.slots, e.gpa(), e.account(), e.places(), base))) |sl| if (sl != base.int()) {
                    const sw = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), .from(sl)));
                    var sa = a;
                    const pk = e.places().kind(e.places().pathPlace(.from(sl)));
                    sa.deep = a.deep or pk == .@"var" or pk == .@"opaque";
                    at.clearRetainingCapacity();
                    try e.arrivalLeaves(k.call, none, sa, sw[@min(n, sw.len)..], &at);
                    for (at.items) |x| try e.addBelow(ki, x, sl);
                };
                for (acc.items) |x| try e.addBelow(ki, x, base.int());
                return;
            }
            // Each slot below through its own key: a whole subtree's slots
            // written out (`belowAll`, §2.3.1, charged).
            for (e.f.slots.items(try Subtree.belowAll(e.f.slots, e.gpa(), e.account(), e.places(), base))) |sl| {
                if (sl != base.int()) try e.slotItems(ki, .from(sl));
            }
            // At `base` itself, what the arrival gives there: read once.
            for (acc.items) |x| try e.addBelow(ki, x, base.int());
            return;
        } else if (a.kind == .fresh or a.kind == .top or a.kind == .shared or a.kind == .host) {
            // An atom at one slot: itself, never through the slot's key.
            var acc: std.ArrayList(u32) = .empty;
            defer acc.deinit(e.gpa());
            try e.arrivalLeaves(k.call, none, a, &.{}, &acc);
            for (acc.items) |x| try e.addBelow(ki, x, base.int());
            return;
        }
        try e.slotItems(ki, base);
    }

    /// The objects at every slot of leaf `x`'s subtree when they are the same
    /// atoms at each (`⊤`, a shared value, a call's fresh objects): a call's
    /// leaf whose callee says only that, open, above it and nothing below it
    /// (a pessimistic contract's `⊤`, a cast of one). Null otherwise.
    pub fn uniformAtoms(e: *Eval, x: u32, out: *std.ArrayList(u32)) Error!bool {
        const l = e.f.leafAt(x);
        switch (l.kind) {
            .top, .shared, .host => {
                try out.append(e.gpa(), x);
                return true;
            },
            .ref => {},
            else => return false,
        }
        const r = e.f.roots.items[l.root];
        if (r.kind != .call) return false;
        if (Subtree.symbolic(e.f.slots, l.slots)) return false;
        const sls = e.f.slots.items(l.slots);
        if (sls.len != 1) return false;
        const cl = e.f.calls.items[r.a];
        if (cl.contract == none) return false;
        if (e.live) |lv| if (cl.code != none and lv.draftRes(lv.ctx, cl.code) != null) return false;
        const xw = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), .from(sls[0])));
        const root = e.contracts.head(cl.contract).res_root;
        // Nothing may be said below the slot, nor plainly at it.
        if (Forest.at(&e.contracts.trees, root, xw)) |n| if (e.contracts.trees.kids(n).len != 0 or e.contracts.trees.here(n).len != 0) return false;
        var hits: std.ArrayList(Contract.Hit) = .empty;
        defer hits.deinit(e.gpa());
        try e.charge(.inspection, try Forest.atSlot(&e.contracts.trees, e.gpa(), root, xw, &hits));
        var any = false;
        for (hits.items) |hit| {
            if (!hit.open) continue;
            for (hit.arrivals) |a| switch (a.kind) {
                .top, .host => try out.append(e.gpa(), try e.f.leaf(.{ .kind = if (a.kind == .host) .host else .top, .tags = l.tags })),
                .shared => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .shared, .atom = a.j, .extra = a.slot, .tags = l.tags })),
                .fresh => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .fresh, .atom = r.a, .tags = l.tags })),
                .param, .cb, .lent => return false,
            };
            any = true;
        }
        return any;
    }

    /// The leaves at caller slot `sl` of key `ki`'s call, through the slot's
    /// own key, as items of `ki` at `sl`.
    fn slotItems(e: *Eval, ki: u32, sl: PathId) Error!void {
        const k = e.keys.items[ki];
        const saved = e.cur_sub;
        defer e.cur_sub = saved;
        e.cur_sub = .{ .kind = .forward_below, .a = ki, .b = sl.int() };
        const run = try e.gpa().dupe(u32, try e.instAt(k.call, sl, k.which));
        defer e.gpa().free(run);
        for (run) |x| try e.addBelow(ki, x, sl.int());
    }

    /// `feedBelow` of a member's draft arrival (its label renamed, as `feedDraft`).
    pub fn feedBelowDraft(e: *Eval, ki: u32, rel: Slots.Rel, open: bool, a0: Contract.Arrival) Error!void {
        var a = a0;
        if (a.kind == .cb) {
            const call = e.f.calls.items[e.keys.items[ki].call];
            if (call.contract == none) return;
            a.j = e.live.?.labelIn(e.live.?.ctx, call.code, a.j, call.contract) orelse return;
        }
        try e.feedBelow(ki, rel, open, a);
    }

    /// The root a key's call or supply results in.
    fn rootOfKey(e: *Eval, ki: u32) u32 {
        const k = e.keys.items[ki];
        if (k.which == none) return e.f.calls.items[k.call].root;
        for (e.f.supplies.items) |s| if (s.call == k.call and (s.label << 16 | s.k) == k.which) return s.root;
        unreachable;
    }

    fn addBelow(e: *Eval, ki: u32, x: u32, at: u32) Error!void {
        if ((try e.below_has.getOrPut(e.gpa(), .{ ki, x, at })).found_existing) return;
        e.grown +%= 1;
        try e.charge(.edge, 1);
        const k = &e.keys.items[ki];
        try k.leaves.append(e.gpa(), x);
        try k.at.append(e.gpa(), at);
        if (k.subs.items.len != 0 and !k.dirty) {
            k.dirty = true;
            if (e.live) |lv| try lv.dirty(lv.ctx, e, ki);
        }
    }

    /// Arrival `a` of key `ki`'s callee, at a slot whose steps are the
    /// first `at` of the key's: its leaves added to the key.
    pub fn feed(e: *Eval, ki: u32, a: Contract.Arrival, at: u32, open: bool) Error!void {
        const k = e.keys.items[ki];
        const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), k.slot));
        const suffix = try e.gpa().dupe(u32, words[@min(at, words.len)..]);
        defer e.gpa().free(suffix);
        var acc: std.ArrayList(u32) = .empty;
        defer acc.deinit(e.gpa());
        const saved = e.cur_sub;
        e.cur_sub = .{ .kind = .forward, .a = ki };
        defer e.cur_sub = saved;
        try e.arrivalLeaves(k.call, none, Subtree.readAt(e.places(), a, k.slot, open), suffix, &acc);
        for (acc.items) |x| try e.addLeaf(ki, x);
    }

    /// An arrival of a member's draft: its label, if any, renamed to the
    /// candidate's (the labels the evaluation applied); one the candidate
    /// does not have yet arrives in a later round.
    pub fn feedDraft(e: *Eval, ki: u32, a0: Contract.Arrival, at: u32, open: bool) Error!void {
        var a = a0;
        if (a.kind == .cb) {
            const call = e.f.calls.items[e.keys.items[ki].call];
            if (call.contract == none) return;
            a.j = e.live.?.labelIn(e.live.?.ctx, call.code, a.j, call.contract) orelse return;
        }
        try e.feed(ki, a, at, open);
    }

    fn addLeaf(e: *Eval, ki: u32, x: u32) Error!void {
        if ((try e.key_has.getOrPut(e.gpa(), .{ ki, x })).found_existing) return;
        e.grown +%= 1;
        try e.charge(.edge, 1);
        const k = &e.keys.items[ki];
        try k.leaves.append(e.gpa(), x);
        if (k.subs.items.len != 0 and !k.dirty) {
            k.dirty = true;
            try e.live.?.dirty(e.live.?.ctx, e, ki);
        }
    }

    /// Whether `s` is new to key `ki`.
    fn subscribe(e: *Eval, ki: u32, s: Sub) Error!bool {
        if (s.kind == .forward and s.a == ki) return false;
        const got = try e.key_subs.getOrPut(e.gpa(), .{ ki, @backingInt(s.kind), s.a, s.b, s.c, s.d, s.tags });
        if (got.found_existing) return false;
        try e.charge(.edge, 1);
        const k = &e.keys.items[ki];
        try k.subs.append(e.gpa(), .{ .sub = s, .cursor = @intCast(k.leaves.items.len) });
        return true;
    }

    /// Deliver key `ki`'s new leaves to each subscriber, once each.
    pub fn drainKey(e: *Eval, ki: u32) Error!void {
        e.keys.items[ki].dirty = false;
        var si: usize = 0;
        while (si < e.keys.items[ki].subs.items.len) : (si += 1) {
            while (true) {
                const at = e.keys.items[ki].subs.items[si];
                if (at.cursor >= e.keys.items[ki].leaves.items.len) break;
                const x0 = e.keys.items[ki].leaves.items[at.cursor];
                e.keys.items[ki].subs.items[si].cursor += 1;
                const saved = e.cur_sub;
                e.cur_sub = null;
                defer e.cur_sub = saved;
                const xat: u32 = if (e.keys.items[ki].below) e.keys.items[ki].at.items[at.cursor] else 0;
                const x = if (at.sub.kind == .describe_below) x0 else try e.widen(x0, xat);
                switch (at.sub.kind) {
                    .forward => {
                        const y = (try e.f.withTags(x, at.sub.tags)) orelse continue;
                        try e.addLeaf(at.sub.a, y);
                    },
                    .forward_below => {
                        const y = (try e.f.withTags(x, at.sub.tags)) orelse continue;
                        try e.addBelow(at.sub.a, y, at.sub.b);
                    },
                    else => try e.live.?.deliver(e.live.?.ctx, e, at.sub, x, xat),
                }
            }
        }
    }

    /// An arrival of call `call`'s contract `c`, as leaves of this frame.
    pub fn arrivalLeaves(e: *Eval, call: u32, _: Contract.Id, a: Contract.Arrival, suffix: []const u32, out: *std.ArrayList(u32)) Error!void {
        // What these fill is kept: never read under a pass (§2.3.4).
        const saved_pass = e.pass;
        e.pass = 0;
        defer e.pass = saved_pass;
        try e.charge(.edge, 1);
        const cl = e.f.calls.items[call];
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(e.gpa());
        if (a.kind == .param or a.kind == .cb or a.kind == .lent) try words.appendSlice(e.gpa(), e.f.slots.relWords(a.slot));
        try words.appendSlice(e.gpa(), suffix);
        const start = out.items.len;
        switch (a.kind) {
            .fresh => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .fresh, .atom = call })),
            .top, .host => try out.append(e.gpa(), try e.f.leaf(.{ .kind = if (a.kind == .host) .host else .top })),
            .shared => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .shared, .atom = a.j, .extra = a.slot })),
            .param, .lent => {
                if (a.j >= cl.args.len) return out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
                try e.routed(e, cl.args[a.j], words.items, a.deep, if (suffix.len == 0 and a.kind == .param) a.path else none, out);
                if (out.items.len == start and words.items.len != 0) try FoldRead.read(e, cl.args[a.j], words.items, out);
                if (a.kind == .lent) try e.lend(out, start, null, call);
            },
            .cb => {
                if (e.known.get(.{ call, a.j })) |vc| try e.knownAnswer(vc, a.deep, words.items, out) else {
                    const fl = e.label_map.get(.{ call, a.j }) orelse return out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
                    try out.append(e.gpa(), try e.f.leaf(.{ .kind = .answer, .atom = fl, .extra = try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), words.items) }));
                }
                if (e.lent.get(.{ call, a.j })) |i| if (e.lent_cells.items[i][0] < cl.args.len) try e.lend(out, start, .{ cl.args[e.lent_cells.items[i][0]], e.lent_cells.items[i][1] }, call);
            },
        }
    }

    /// The leaves `out[start..]` as loans of what a cell holds and, with
    /// `cell` (a value and the `◆` it holds at), a loan of all of it; `⊤` where
    /// there is nothing to lend (§2.13.7: a `Deferred` not yet completed).
    /// A loan's `extra` is the call that lent it.
    fn lend(e: *Eval, out: *std.ArrayList(u32), start: usize, cell: ?[2]u32, call: u32) Error!void {
        if (cell) |c| try e.routed(e, c[0], e.f.slots.relWords(c[1]), true, none, out);
        if (out.items.len == start) return out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
        for (out.items[start..]) |*x| switch (e.f.leafAt(x.*).kind) {
            .top, .host, .loan => {},
            else => x.* = try e.f.leaf(.{ .kind = .loan, .atom = x.*, .extra = call, .tags = e.f.leafAt(x.*).tags }),
        };
    }

    /// Known code `vc`'s answer at `words`: its virtual call's.
    fn knownAnswer(e: *Eval, vc: u32, deep: bool, words: []const u32, out: *std.ArrayList(u32)) Error!void {
        const r = e.f.roots.items[e.f.calls.items[vc].root];
        var all: std.ArrayList(u32) = .empty;
        defer all.deinit(e.gpa());
        try Slots.replay(e.gpa(), e.account(), e.places(), r.path, words, &all);
        if (all.items.len == 0) {
            // A slot the answer's place cannot name (a type
            // variable's, `a → a` answering at `.values`): the
            // code's contract read at those words, an open
            // entry above them projected down. Never the whole
            // answer, which is another object than its part.
            const start = out.items.len;
            if (e.contractOf(vc)) |vcc| {
                var hits: std.ArrayList(Contract.Hit) = .empty;
                defer hits.deinit(e.gpa());
                try e.hitsAt(e.contracts.head(vcc).res_root, words, &hits);
                for (hits.items) |hit| for (hit.arrivals) |va| try e.arrivalLeaves(vc, vcc, va, words[hit.depth..], out);
            }
            if (out.items.len == start) try out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
            return;
        }
        // The known code's call, read where its leaves are wanted (deep: its subtree).
        for (all.items) |s| try out.append(e.gpa(), try e.f.leaf(.{ .kind = .ref, .root = e.f.calls.items[vc].root, .pos = r.pos, .slots = if (deep) try Subtree.below(e.f.slots, e.gpa(), e.account(), e.places(), .from(s)) else try e.f.slots.internSorted(e.gpa(), e.account(), &.{s}) }));
    }

    /// Whether a leaf's root is expanded into the leaves it comes from.
    pub fn expandable(e: *Eval, l: Leaf) bool {
        if (l.kind != .ref) return false;
        const r = e.f.roots.items[l.root];
        return switch (r.kind) {
            .param, .cb => false,
            .call, .supply => true,
        };
    }

    /// Every arrival of call `call`'s callee at and below caller slot
    /// `prefix`, through one key below it, widened, with `tags`.
    fn wholeItems(e: *Eval, call: u32, which: u32, prefix: PathId, tags: u32, out: *std.ArrayList(u32)) Error!void {
        const ki = try e.instBelow(call, prefix, which);
        var i: usize = 0;
        while (i < e.keys.items[ki].leaves.items.len) : (i += 1) {
            const k = e.keys.items[ki];
            const x = try e.widen(k.leaves.items[i], k.at.items[i]);
            if (try e.f.withTags(x, tags)) |y| try out.append(e.gpa(), y);
        }
    }

    /// `expandRouted`, each leaf's route set written out (§2.3.5, *a key's leaf*): one leaf a route.
    pub fn expand(e: *Eval, li: u32, out: *std.ArrayList(u32)) Error!void {
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(e.gpa());
        try e.expandRouted(li, &ls);
        for (ls.items) |x| {
            var l = e.f.leafAt(x);
            if (l.routes == 0) try out.append(e.gpa(), x) else {
                var it = try e.f.sets.tags.routeIter(e.gpa(), l.routes, l.tags);
                defer it.deinit(e.gpa());
                l.routes = 0;
                while (try it.next(e.gpa(), e.account())) |t| {
                    l.tags = t;
                    try out.append(e.gpa(), try e.f.leaf(l));
                }
            }
        }
    }

    /// A call, supply or known label's leaf as the leaves it comes from,
    /// its tags merged in (never its route set), each with its own set (§2.3.5); one met again while expanded adds nothing.
    pub fn expandRouted(e: *Eval, li: u32, out: *std.ArrayList(u32)) Error!void {
        // What these fill is kept: never read under a pass (§2.3.4).
        const saved_pass = e.pass;
        e.pass = 0;
        defer e.pass = saved_pass;
        const l = e.f.leafAt(li);
        const r = e.f.roots.items[l.root];
        // A whole subtree is read through one key below its position, never
        // one per slot (§2.10 *Read-off*).
        // A symbol `↓p` (§2.3.1) is read the same way at `p`, whatever
        // else the set holds.
        if (r.kind == .call or r.kind == .supply) {
            const call: u32, const which: u32 = if (r.kind == .call) .{ r.a, none } else blk: {
                const su = e.f.supplies.items[r.a];
                break :blk .{ su.call, (su.label << 16) | su.k };
            };
            for (Subtree.subs(e.f.slots, l.slots)) |sb| try e.wholeItems(call, which, Slots.pathOf(sb), l.tags, out);
            if (Subtree.explicit(e.f.slots, l.slots).len == 0) return;
        }
        if (e.live != null) {
            // Keys meet cycles themselves: a key read again while it is
            // made gives what it has, and its consumer gets the rest.
            const call: u32, const which: u32 = switch (r.kind) {
                .call => .{ r.a, none },
                .supply => blk: {
                    const s = e.f.supplies.items[r.a];
                    break :blk .{ s.call, (s.label << 16) | s.k };
                },
                .cb, .param => unreachable,
            };
            for (Subtree.explicit(e.f.slots, l.slots)) |s| {
                // A copy: a consumer's work may grow the key under it.
                const run = try e.gpa().dupe(u32, try e.instAt(call, .from(s), which));
                defer e.gpa().free(run);
                for (run) |x| if (try e.f.withTags(x, l.tags)) |y| try out.append(e.gpa(), y);
            }
            return;
        }
        const got = try e.expanding.getOrPut(e.gpa(), .{li});
        if (got.found_existing and got.value_ptr.* == 1) return;
        got.value_ptr.* = 1;
        defer {
            if (e.expanding.get(.{li}) != null) (e.expanding.getOrPut(e.gpa(), .{li}) catch unreachable).value_ptr.* = 0;
        }
        const call: u32, const which: u32 = switch (r.kind) {
            .call => .{ r.a, none },
            .supply => blk: {
                const s = e.f.supplies.items[r.a];
                break :blk .{ s.call, (s.label << 16) | s.k };
            },
            .cb, .param => unreachable,
        };
        for (Subtree.explicit(e.f.slots, l.slots)) |s| {
            for (try e.instAt(call, .from(s), which)) |x| if (try e.f.withTags(x, l.tags)) |y| try out.append(e.gpa(), y);
        }
    }
};
