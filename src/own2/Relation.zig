//! L6: the one relation, the distinct check and a call's instantiation
//! (`docs/design/ownership-v2.md` §2.9, §2.11.2). An `Eval` is one
//! evaluation of a walk's frame under the contracts its calls read: the
//! instantiation of each call (built once per call and caller slot), each
//! call's separation, and the relation of each pair of leaves met, all
//! kept for the evaluation and dropped with it (§2.12: an evaluation per
//! candidate generation; the walk itself is never redone).
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
//! unknown callee is the pessimistic contract), the relation's half of O3
//! (two positions of one root are apart only under the root's separation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");

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
pub const SubKind = enum(u8) { forward, describe, effect, supply, escape };
pub const Sub = struct { kind: SubKind, a: u32 = 0, b: u32 = 0, c: u32 = 0, tags: u32 = 0 };

/// The group being solved (§2.12): its members' drafts, read while they
/// grow, and the queue of what is still to be delivered.
pub const Live = struct {
    ctx: *anyopaque,
    /// The draft result slots of code `code` when it is a member being
    /// solved now, else null.
    draftRes: *const fn (ctx: *anyopaque, code: u32) ?*std.ArrayList(Contract.Draft.DraftSlot),
    /// Key `key` of `ev` reads member `code`'s result at relative steps `rel`.
    watch: *const fn (ctx: *anyopaque, code: u32, rel: Slots.Rel, ev: *Eval, key: u32) Error!void,
    /// Key `key` of `ev` has leaves a subscriber has not seen.
    dirty: *const fn (ctx: *anyopaque, ev: *Eval, key: u32) Error!void,
    /// A subscriber of the read-off consumes a leaf.
    deliver: *const fn (ctx: *anyopaque, ev: *Eval, sub: Sub, leaf: u32) Error!void,
    /// Deliver everything queued, unless a delivery is under way.
    pump: *const fn (ctx: *anyopaque) Error!void,
    /// Member `code`'s draft label `i` as the label of the same identity
    /// in contract `c` (its candidate), or null when `c` has none yet.
    labelIn: *const fn (ctx: *anyopaque, code: u32, i: u32, c: Contract.Id) ?u32,
};

/// A live instantiation: one call's leaves at one caller slot, growing.
const Key = struct {
    call: u32,
    slot: PathId,
    which: u32,
    leaves: std.ArrayList(u32) = .empty,
    subs: std.ArrayList(SubAt) = .empty,
    dirty: bool = false,
};
const SubAt = struct { sub: Sub, cursor: u32 };

/// One projected object: its leaf and the literal route that reached it.
pub const Proj = struct { leaf: u32, route: u32 = 0, occ: u64 = 0 };

pub const Eval = struct {
    f: *Frame,
    contracts: *const Contract.Table,
    arena: Allocator,
    /// `(call, caller slot, which)` → a run of `inst_leaves`; `which` is
    /// `none` for the result, else the supply `label << 16 | k`.
    inst_memo: Ids.FixedDict(3) = .{},
    inst_runs: std.ArrayList([2]u32) = .empty,
    inst_leaves: std.ArrayList(u32) = .empty,
    /// Per call: 0 unset, 1 in progress, 2 done (`cond_of`).
    cond_state: std.ArrayList(u8) = .empty,
    cond_of: std.ArrayList(Cond) = .empty,
    /// `(leaf, leaf, target)` → `ovs` index; `none` while in progress.
    ov_memo: Ids.FixedDict(3) = .{},
    ovs: std.ArrayList(Ov) = .empty,
    /// Per `(call, callee label)`: the frame label it maps to (`cbs`), when
    /// the label passes on; set by `Eval.zig` before any relation is asked.
    label_map: Ids.FixedDict(2) = .{},
    /// Per `(call, callee label)`: the virtual call that applies a known code.
    known: Ids.FixedDict(2) = .{},
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
    scratch: std.ArrayList(u32) = .empty,
    /// Set while a group is solved (§2.12): a member's call reads its
    /// growing draft, and what reads a key subscribes to it.
    live: ?*Live = null,
    /// The consumer the next `instAt` subscribes (null: a one-off read).
    cur_sub: ?Sub = null,
    keys: std.ArrayList(Key) = .empty,
    /// `(key, leaf)`: the key has the leaf; `(key, sub…)`: subscribed.
    key_has: Ids.FixedDict(2) = .{},
    key_subs: Ids.FixedDict(6) = .{},
    inst_depth: u32 = 0,

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
        e.inst_stack.deinit(g);
        e.routes.deinit(g);
        e.expanding.deinit(g);
        e.scratch.deinit(g);
        for (e.keys.items) |*k| {
            k.leaves.deinit(g);
            k.subs.deinit(g);
        }
        e.keys.deinit(g);
        e.key_has.deinit(g);
        e.key_subs.deinit(g);
    }

    fn charge(e: *Eval, cat: Ids.Category, n: u32) Error!void {
        try e.f.account.reserve(cat, n);
    }

    fn places(e: *Eval) *Place.Table {
        return e.f.places;
    }

    fn gpa(e: *Eval) Allocator {
        return e.f.gpa;
    }

    fn account(e: *Eval) *Ids.Account {
        return e.f.account;
    }

    // ---- leaves of a value ---------------------------------------------------

    /// The deep leaves of value `v` (every object it reaches), appended.
    pub fn leavesOf(e: *Eval, v: u32, tags: u32, out: *std.ArrayList(u32)) Error!void {
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(e.gpa());
        try stack.append(e.gpa(), .{ v, tags });
        while (stack.pop()) |it| {
            try e.charge(.inspection, 1);
            const x = e.f.val(it[0]);
            switch (x.kind) {
                .scalar, .bot => {},
                .built => {
                    if (x.site != none) try out.append(e.gpa(), try e.f.leaf(.{ .kind = .site, .atom = x.site, .tags = it[1] }));
                    if (x.form == .list and x.head != 0) try e.storageOf(x.head - 1, it[1], out);
                    for (e.f.kidsOf(x)) |k| try stack.append(e.gpa(), .{ k, it[1] });
                },
                .ref => {
                    const set = try e.f.refSlots(x);
                    if (set == Slots.empty) continue;
                    try out.append(e.gpa(), try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set, .tags = it[1] }));
                },
                .alt => {
                    const ks = e.f.kidsOf(x);
                    var i: usize = 0;
                    while (i < ks.len) : (i += 2) {
                        const t = (try e.f.mergeTags(it[1], try e.f.internTags(&.{.{ x.head, ks[i] }}))) orelse continue;
                        try stack.append(e.gpa(), .{ ks[i + 1], t });
                    }
                },
                .top => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .top, .tags = it[1] })),
                .shared => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .shared, .atom = x.head, .extra = x.site, .tags = it[1] })),
            }
        }
    }

    /// The objects at value `v`'s own storage (a shallow write's target):
    /// a built list's or record's site, a reference's position itself.
    pub fn storageOf(e: *Eval, v: u32, tags: u32, out: *std.ArrayList(u32)) Error!void {
        const x = e.f.val(v);
        switch (x.kind) {
            .scalar, .bot => {},
            .built => {
                if (x.site != none) try out.append(e.gpa(), try e.f.leaf(.{ .kind = .site, .atom = x.site, .tags = tags }));
                // A list built over a base may be that base's storage; a
                // prepend only by a re-cons (§2.13.6, `prepended`).
                if (x.form == .list and x.head != 0 and (x.site == none or try e.mayRecons(x))) try e.storageOf(x.head - 1, tags, out);
            },
            .ref => {
                const set = if (x.family != Slots.empty) try e.objects(x.family) else try e.f.slots.canon(e.gpa(), e.account(), e.places(), e.f.pos.items[x.pos].slot);
                if (set == Slots.empty) return;
                try out.append(e.gpa(), try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set, .tags = tags, .at_pos = x.family == Slots.empty }));
            },
            .alt => {
                const ks = e.f.kidsOf(x);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) {
                    const t = (try e.f.mergeTags(tags, try e.f.internTags(&.{.{ x.head, ks[i] }}))) orelse continue;
                    try e.storageOf(ks[i + 1], t, out);
                }
            },
            .top => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .top, .tags = tags })),
            .shared => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .shared, .atom = x.head, .extra = x.site, .tags = tags })),
        }
    }

    /// Whether prepend `x` may answer its base's own array: a re-cons, when
    /// the item put in front is `Js.same` as the element stored just before
    /// the base's view. An object made after the base (a literal, a call's
    /// fresh objects) is none of the base's, so it cannot be (`PrependFresh`).
    fn mayRecons(e: *Eval, x: Value.Val) Error!bool {
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

    /// The object slots of a slot set (its canonical names).
    fn objects(e: *Eval, s: Slots.SetId) Error!Slots.SetId {
        return e.f.slots.setOf(e.gpa(), e.account(), e.places(), e.f.slots.items(s));
    }

    // ---- projection of an arrival onto a value -------------------------------

    fn routeStep(e: *Eval, route: u32, kid: u32) Error!u32 {
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
                .top => try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .top, .tags = it.tags }), .route = it.route }),
                .shared => try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .shared, .atom = x.head, .extra = x.site, .tags = it.tags }), .route = it.route }),
                .alt => {
                    const ks = e.f.kidsOf(x);
                    var i: usize = 0;
                    while (i < ks.len) : (i += 2) {
                        const t = (try e.f.mergeTags(it.tags, try e.f.internTags(&.{.{ x.head, ks[i] }}))) orelse continue;
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
                                // A call's result read on past its place:
                                // through what arrives there.
                                if (x.family == Slots.empty and try e.throughCall(x.root, .from(t), rest, deep, it.tags, it.route, out)) continue;
                                try inside.append(e.gpa(), t);
                            }
                        }
                    }
                    var set = try e.f.slots.setOf(e.gpa(), e.account(), e.places(), all.items);
                    if (deep) set = try e.f.slots.belowSet(e.gpa(), e.account(), e.places(), try e.f.slots.sorted(e.gpa(), e.account(), all.items));
                    for (inside.items) |t| set = try e.f.slots.unionOf(e.gpa(), e.account(), set, try e.f.slots.below(e.gpa(), e.account(), e.places(), .from(t)));
                    if (set == Slots.empty) continue;
                    try out.append(e.gpa(), .{ .leaf = try e.f.leaf(.{ .kind = .ref, .root = x.root, .pos = x.pos, .slots = set, .tags = it.tags }), .route = it.route });
                },
                .built => {
                    if (rest.len == 0) {
                        if (deep) {
                            var ls: std.ArrayList(u32) = .empty;
                            defer ls.deinit(e.gpa());
                            try e.leavesOf(it.v, it.tags, &ls);
                            for (ls.items) |l| try out.append(e.gpa(), .{ .leaf = l, .route = it.route });
                        } else {
                            var ls: std.ArrayList(u32) = .empty;
                            defer ls.deinit(e.gpa());
                            try e.storageOf(it.v, it.tags, &ls);
                            for (ls.items) |l| try out.append(e.gpa(), .{ .leaf = l, .route = it.route });
                        }
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
                        .level => try e.projectLevels(it.v, words[it.at + 1 ..], deep, it.tags, it.route, out),
                        else => {
                            // A step the literal cannot follow: every object of it.
                            var ls: std.ArrayList(u32) = .empty;
                            defer ls.deinit(e.gpa());
                            try e.leavesOf(it.v, it.tags, &ls);
                            for (ls.items) |l| try out.append(e.gpa(), .{ .leaf = l, .route = try e.routeStep(it.route, none) });
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
    fn throughCall(e: *Eval, root: u32, t: PathId, rest: []const u32, deep: bool, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!bool {
        const r = e.f.roots.items[root];
        if (r.kind != .call) return false;
        const call = e.f.calls.items[r.a];
        if (call.contract == none) return false;
        if (e.live) |lv| if (call.code != none and lv.draftRes(lv.ctx, call.code) != null) return false;
        const h = e.contracts.head(call.contract);
        const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), t));
        var arrs: std.ArrayList(struct { a: Contract.Arrival, n: usize }) = .empty;
        defer arrs.deinit(e.gpa());
        for (e.contracts.resOf(h.res)) |rs| {
            const rw = e.f.slots.relWords(rs.slot);
            const exact = std.mem.eql(u32, rw, words);
            const opened = rs.open and rw.len < words.len and std.mem.eql(u32, rw, words[0..rw.len]);
            if (!exact and !opened) continue;
            for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
                if (a.kind != .param or a.j >= call.args.len) return false;
                try arrs.append(e.gpa(), .{ .a = a, .n = rw.len });
            }
        }
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
    fn stepsTo(e: *Eval, from: PathId, target: PlaceId, out: *std.ArrayList(u32)) Error!void {
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

    /// `⟲` into a built value: the values one or more levels below, at the
    /// same place, through the parts that stay on its cycle; then `rest`
    /// from each (the experiment's fourth requirement). A part not built
    /// here gives its levels by its own slots, never its own storage.
    fn projectLevels(e: *Eval, v: u32, rest: []const u32, deep: bool, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
        const place = e.f.val(v).place;
        if (place == .none) {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(e.gpa());
            try e.leavesOf(v, tags, &ls);
            for (ls.items) |l| try out.append(e.gpa(), .{ .leaf = l, .route = route });
            return;
        }
        const pl = e.places();
        const Item = struct { v: u32, place: PlaceId, route: u32, below: bool };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(e.gpa());
        try stack.append(e.gpa(), .{ .v = v, .place = place, .route = route, .below = false });
        while (stack.pop()) |it| {
            try e.charge(.inspection, 1);
            const x = e.f.val(it.v);
            switch (x.kind) {
                .built => {
                    if (it.below and it.place == place) try e.project(it.v, rest, deep, tags, it.route, out);
                    for (e.f.kidsOf(x), 0..) |k, n| {
                        const kst: Step = switch (x.form) {
                            .list => Step.elem,
                            .record => try Step.field(e.account(), e.f.wordsOf(x.extra)[n]),
                            .tuple => try Step.index(e.account(), @intCast(n)),
                            .ctor => try pl.ctorStep(e.gpa(), e.account(), x.head, @intCast(n)),
                            .closure, .opaque_ => continue,
                        };
                        const kp = pl.child(it.place, kst) orelse continue;
                        if (kp != place and !pl.sameCycle(kp, place)) continue;
                        try stack.append(e.gpa(), .{ .v = k, .place = kp, .route = try e.routeStep(it.route, @intCast(n)), .below = true });
                    }
                },
                .scalar, .bot => {},
                .ref => if (it.below) {
                    if (it.place == place) try e.project(it.v, rest, deep, tags, it.route, out);
                    // A part on the cycle at another place (a `List T` below a
                    // `T`): its next level is the steps to the cycle's place.
                    var to: std.ArrayList(u32) = .empty;
                    defer to.deinit(e.gpa());
                    if (it.place != place and x.family == Slots.empty) try e.stepsTo(e.f.pos.items[x.pos].slot, place, &to);
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
                    try lv.append(e.gpa(), Step.level.word());
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

    fn contractOf(e: *Eval, call: u32) ?Contract.Id {
        const c = e.f.calls.items[call].contract;
        return if (c == none) null else c;
    }

    /// The leaves the callee of `call` says arrive at caller slot `slot`
    /// (a path under the call's result root), or, with `which` a supply
    /// `(label << 16) | k`, at the supply's slot. Built once per key.
    pub fn instAt(e: *Eval, call: u32, slot: PathId, which: u32) Error![]const u32 {
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
            const h = e.contracts.head(c);
            const res: Ids.Range = if (which == none) h.res else blk: {
                const l = e.contracts.labelsOf(h.labels)[which >> 16];
                for (e.contracts.suppliesOf(l.supplies)) |s| if (s.k == (which & 0xffff)) break :blk s.res;
                break :blk .{};
            };
            const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), slot));
            for (e.contracts.resOf(res)) |rs| {
                const rw = e.f.slots.relWords(rs.slot);
                const exact = std.mem.eql(u32, rw, words);
                const opened = rs.open and rw.len < words.len and std.mem.eql(u32, rw, words[0..rw.len]);
                if (!exact and !opened) continue;
                const suffix = words[rw.len..];
                for (e.contracts.arrivalsOf(rs.arrivals)) |a| try e.arrivalLeaves(call, c, a, suffix, &acc);
            }
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
            while (si < list.items.len) : (si += 1) {
                const rs = list.items[si];
                const rw = e.f.slots.relWords(rs.slot);
                const exact = std.mem.eql(u32, rw, words);
                const opened = rs.open and rw.len < words.len and std.mem.eql(u32, rw, words[0..rw.len]);
                if (!exact and !opened) continue;
                var ai: usize = 0;
                while (ai < list.items[si].arrivals.items.len) : (ai += 1) try e.feedDraft(ki, list.items[si].arrivals.items[ai], @intCast(rw.len));
            }
        } else if (e.contractOf(call)) |c| {
            const h = e.contracts.head(c);
            const res: Ids.Range = if (which == none) h.res else blk: {
                const l = e.contracts.labelsOf(h.labels)[which >> 16];
                for (e.contracts.suppliesOf(l.supplies)) |s| if (s.k == (which & 0xffff)) break :blk s.res;
                break :blk .{};
            };
            for (e.contracts.resOf(res)) |rs| {
                const rw = e.f.slots.relWords(rs.slot);
                const exact = std.mem.eql(u32, rw, words);
                const opened = rs.open and rw.len < words.len and std.mem.eql(u32, rw, words[0..rw.len]);
                if (!exact and !opened) continue;
                for (e.contracts.arrivalsOf(rs.arrivals)) |a| try e.feed(ki, a, @intCast(rw.len));
            }
        } else try e.addLeaf(ki, try e.f.leaf(.{ .kind = .top }));
        e.cur_sub = sub;
        e.inst_depth -= 1;
        // What the queue adds now is in the run returned; the consumer
        // subscribes after it, so it gets each leaf once.
        if (e.inst_depth == 0) try lv.pump(lv.ctx);
        if (sub) |s| _ = try e.subscribe(ki, s);
        return e.keys.items[ki].leaves.items;
    }

    /// Arrival `a` of key `ki`'s callee, at a slot whose steps are the
    /// first `at` of the key's: its leaves added to the key.
    pub fn feed(e: *Eval, ki: u32, a: Contract.Arrival, at: u32) Error!void {
        const k = e.keys.items[ki];
        const words = e.f.slots.relWords(try e.f.slots.relOf(e.gpa(), e.account(), e.places(), k.slot));
        const suffix = try e.gpa().dupe(u32, words[@min(at, words.len)..]);
        defer e.gpa().free(suffix);
        var acc: std.ArrayList(u32) = .empty;
        defer acc.deinit(e.gpa());
        const saved = e.cur_sub;
        e.cur_sub = .{ .kind = .forward, .a = ki };
        defer e.cur_sub = saved;
        try e.arrivalLeaves(k.call, none, a, suffix, &acc);
        for (acc.items) |x| try e.addLeaf(ki, x);
    }

    /// An arrival of a member's draft: its label, if any, renamed to the
    /// candidate's (the labels the evaluation applied); one the candidate
    /// does not have yet arrives in a later round.
    pub fn feedDraft(e: *Eval, ki: u32, a0: Contract.Arrival, at: u32) Error!void {
        var a = a0;
        if (a.kind == .cb) {
            const call = e.f.calls.items[e.keys.items[ki].call];
            if (call.contract == none) return;
            a.j = e.live.?.labelIn(e.live.?.ctx, call.code, a.j, call.contract) orelse return;
        }
        try e.feed(ki, a, at);
    }

    /// The words of key `ki`'s caller slot.
    pub fn keyRel(e: *Eval, ki: u32) Error!Slots.Rel {
        return e.f.slots.relOf(e.gpa(), e.account(), e.places(), e.keys.items[ki].slot);
    }

    fn addLeaf(e: *Eval, ki: u32, x: u32) Error!void {
        if ((try e.key_has.getOrPut(e.gpa(), .{ ki, x })).found_existing) return;
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
        const got = try e.key_subs.getOrPut(e.gpa(), .{ ki, @backingInt(s.kind), s.a, s.b, s.c, s.tags });
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
                const x = e.keys.items[ki].leaves.items[at.cursor];
                e.keys.items[ki].subs.items[si].cursor += 1;
                const saved = e.cur_sub;
                e.cur_sub = null;
                defer e.cur_sub = saved;
                switch (at.sub.kind) {
                    .forward => {
                        const y = (try e.f.withTags(x, at.sub.tags)) orelse continue;
                        try e.addLeaf(at.sub.a, y);
                    },
                    else => try e.live.?.deliver(e.live.?.ctx, e, at.sub, x),
                }
            }
        }
    }

    /// An arrival of call `call`'s contract `c`, as leaves of this frame.
    pub fn arrivalLeaves(e: *Eval, call: u32, c: Contract.Id, a: Contract.Arrival, suffix: []const u32, out: *std.ArrayList(u32)) Error!void {
        try e.charge(.edge, 1);
        const cl = e.f.calls.items[call];
        switch (a.kind) {
            .fresh => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .fresh, .atom = call })),
            .top => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .top })),
            .shared => try out.append(e.gpa(), try e.f.leaf(.{ .kind = .shared, .atom = a.j, .extra = a.slot })),
            .param => {
                if (a.j >= cl.args.len) return out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
                const arg = cl.args[a.j];
                var words: std.ArrayList(u32) = .empty;
                defer words.deinit(e.gpa());
                try words.appendSlice(e.gpa(), e.f.slots.relWords(a.slot));
                try words.appendSlice(e.gpa(), suffix);
                var ps: std.ArrayList(Proj) = .empty;
                defer ps.deinit(e.gpa());
                try e.project(arg, words.items, a.deep, 0, 0, &ps);
                for (ps.items) |p| try out.append(e.gpa(), p.leaf);
            },
            .cb => {
                var words: std.ArrayList(u32) = .empty;
                defer words.deinit(e.gpa());
                try words.appendSlice(e.gpa(), e.f.slots.relWords(a.slot));
                try words.appendSlice(e.gpa(), suffix);
                if (e.known.get(.{ call, a.j })) |vc| {
                    // The known code's answer at that slot: its virtual call's.
                    const r = e.f.roots.items[e.f.calls.items[vc].root];
                    var all: std.ArrayList(u32) = .empty;
                    defer all.deinit(e.gpa());
                    try Slots.replay(e.gpa(), e.account(), e.places(), r.path, words.items, &all);
                    if (all.items.len == 0) {
                        // A slot the answer's place cannot name: all of it.
                        var ls: std.ArrayList(u32) = .empty;
                        defer ls.deinit(e.gpa());
                        const whole = try e.f.leaf(.{ .kind = .ref, .root = e.f.calls.items[vc].root, .pos = r.pos, .slots = try e.f.slots.below(e.gpa(), e.account(), e.places(), r.path) });
                        try e.expand(whole, &ls);
                        try out.appendSlice(e.gpa(), ls.items);
                        return;
                    }
                    for (all.items) |s| try out.appendSlice(e.gpa(), try e.instAt(vc, .from(s), none));
                    return;
                }
                const fl = e.label_map.get(.{ call, a.j }) orelse return out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
                try out.append(e.gpa(), try e.f.leaf(.{ .kind = .answer, .atom = fl, .extra = try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), words.items) }));
            },
        }
        _ = c;
    }

    /// Whether a leaf's root is expanded into the leaves it comes from.
    fn expandable(e: *Eval, l: Leaf) bool {
        if (l.kind != .ref) return false;
        const r = e.f.roots.items[l.root];
        return switch (r.kind) {
            .param, .cb => false,
            .call, .supply => true,
        };
    }

    /// A call, supply or known label's leaf as the leaves it comes from,
    /// with its tags; a leaf met again while it is expanded adds nothing.
    pub fn expand(e: *Eval, li: u32, out: *std.ArrayList(u32)) Error!void {
        const l = e.f.leafAt(li);
        const r = e.f.roots.items[l.root];
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
            for (e.f.slots.items(l.slots)) |s| {
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
        for (e.f.slots.items(l.slots)) |s| {
            for (try e.instAt(call, .from(s), which)) |x| if (try e.f.withTags(x, l.tags)) |y| try out.append(e.gpa(), y);
        }
    }

    // ---- separation ---------------------------------------------------------

    /// The selection of parameter `j` at the slots of `set` (paths under its root).
    pub fn sel(e: *Eval, j: u32, set: Slots.SetId) Error!Cond {
        return e.selOf(j, set, false);
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
            .param => e.sel(r.a, l.slots),
            .call => e.instCond(r.a),
            .supply, .cb => blk: {
                if (!e.expandable(l)) break :blk Cond.unprovable;
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(e.gpa());
                try e.expand(li, &ls);
                var ps: std.ArrayList(Proj) = .empty;
                defer ps.deinit(e.gpa());
                for (ls.items, 0..) |x, k| try ps.append(e.gpa(), .{ .leaf = x, .route = @intCast(k + 1) });
                break :blk e.distinct(ps.items, false);
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
        const got = try e.instSel(try e.contracts.cond(e.arena, e.contracts.head(c).res_cond), call);
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
            if (!try e.arrivesAtPlain(h.res, o, plain.items)) out[k] = o | Contract.apart_bit;
        }
        return e.instSel(try Cond.of(e.account(), out), call);
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
        return e.distinct(ps.items, true);
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
        return e.distinct(ps.items, false);
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
                .ref => if (!l.at_pos and e.isFamily(l) and !Contract.isApart(en.occ)) {
                    if (e.f.roots.items[l.root].kind == .cb and !e.expandable(l)) return Cond.unprovable;
                    if (try e.gather(&occs, try e.sepLeaf(en.leaf))) return Cond.unprovable;
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
                if (try e.mayWithin(ents.items, idx.items, routed)) return Cond.unprovable;
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
                        const c = if (anyApart(ents.items, idx.items)) try e.instCondMixed(r.a, ents.items, idx.items) else try e.instCond(r.a);
                        if (c.no) {
                            if (must == none or root > must) {
                                must = root;
                                unvouched = true;
                            }
                        } else if (try e.gather(&occs, c)) return Cond.unprovable;
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
                if (l.kind == .ref and !l.at_pos and e.isFamily(l) and !e.expandable(l) and !Contract.isApart(en.occ)) {
                    if (e.f.roots.items[l.root].kind == .cb) return Cond.unprovable;
                    if (try e.gather(&occs, try e.sepLeaf(en.leaf))) return Cond.unprovable;
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
                if (try e.pairMay(ents[i], ents[j], routed)) return true;
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
                        if (try e.pairMay(ents[i], ents[j], routed)) return true;
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
        const r = try e.overlapRaw(x, t, target);
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
        if (xr and tr and x.root == t.root) return e.positional(xi, ti, target);
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
                    const o = if (expand_x) try e.overlap(l, ti, target) else try e.overlap(xi, l, target);
                    acc = try Ov.join(e.arena, e.account(), acc, o);
                    if (acc.kind == .may) return acc;
                }
                return acc;
            }
            if (xr and tr) {
                // Two parameters: apart under both selections; the holder's
                // objects need only be apart from the target's (§2.9.1).
                const c = try Cond.conj(e.arena, e.account(), try e.selOf(e.f.roots.items[x.root].a, x.slots, true), try e.sel(e.f.roots.items[t.root].a, t.slots));
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
                if (!(try e.f.slots.meet(e.account(), x.slots, t.slots))) return e.apart(xi, ti, target);
                // The holder below the written position holds the slot only
                // where a level folds back onto it.
            }
            if (try e.f.slots.meet(e.account(), x.slots, t.slots)) return .may;
        }
        return e.apart(xi, ti, target);
    }

    /// Two leaves of one root at distinct places: apart under the root's
    /// separation.
    fn apart(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
        const x = e.f.leafAt(xi);
        const t = e.f.leafAt(ti);
        const r0 = e.f.roots.items[x.root];
        switch (r0.kind) {
            .param => return .{ .kind = .under, .cond = try Cond.conj(e.arena, e.account(), try e.selOf(r0.a, x.slots, true), try e.sel(r0.a, t.slots)) },
            .call => {
                const sep = try e.instCond(r0.a);
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
            acc = try Ov.join(e.arena, e.account(), acc, try e.overlap(a, b, target));
            if (acc.kind == .may) return acc;
        };
        return acc;
    }
};
