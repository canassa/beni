//! L5: a walk's values (`docs/design/ownership-v2.md` §2.3, §3.3): its
//! roots, the positions the source projects from them, its values, their
//! leaves and the choice tags the leaves carry. Every table is a list of
//! records indexed by `u32`; positions, leaves and tag sets are interned,
//! so two names bound to one projection share one position, and one object
//! named twice is one leaf.
//!
//! Obligations kept here: none of §2.14's directly (tables only); §2.3.2's
//! relation of two positions is `related`, by `Steps.stepRel`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Leaves = @import("Leaves.zig");

pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const SetId = Slots.SetId;
pub const Error = Ids.ChargeError;
pub const Step = Place.Step;
const Steps = @import("Steps.zig");
pub const PKind = Steps.PKind;
pub const Pos = Steps.Pos;
pub const Rel = Steps.Rel;
pub const StepRel = Steps.StepRel;
pub const StepClass = Steps.StepClass;
pub const none: u32 = Ids.none_int;

/// The sources of values (§2.3.2).
pub const RootKind = enum(u8) {
    /// `a`: the parameter's index (a capture is a parameter after its code's own).
    param,
    /// `a`: the call's index in `Frame.calls`.
    call,
    /// `a`: the label's index in `Frame.cbs`: its answer (§2.11.3).
    cb,
    /// `a`: the index in `Frame.supplies`: what a callee hands one of its labels, described by the callee's supply (§2.11.3).
    supply,
};

/// A call site (§2.11.2): its instruction and point, its arguments (a run
/// of `Frame.kids`, the values; a closure's captures after them), its
/// result root, and the contract read at it (set per evaluation; `none`:
/// the pessimistic one). `virtual`: a label's application to a known code,
/// made by an evaluation (§2.11.3), not by the walk.
pub const Call = struct {
    inst: u32,
    /// The callee's reference instruction (a method call's own), for texts.
    head: u32 = none,
    point: u32,
    args: []const u32,
    /// The arguments' instructions, `none` for a capture or a virtual one.
    arg_insts: []const u32,
    root: u32,
    contract: u32 = none,
    /// The code the call runs when it is one of the module's (`Groups`' numbering), else `none`.
    code: u32 = none,
    /// The callee's value when the call is of a function value.
    callee_val: u32 = none,
    virtual: bool = false,
    /// A virtual call: the label (`cbs`) it answers.
    answers: u32 = none,
};

/// A label of the frame (§2.11.3): the function slot `(j, slot)` of a
/// parameter, its origin, its answer's root (a direct call's; `none` for
/// a callee's label the frame passes on), and how it was met.
pub const Cb = struct {
    j: u32,
    slot: u32,
    origin: [3]u32,
    root: u32 = none,
    /// A direct callback call: its instruction, point and argument values.
    inst: u32 = none,
    point: u32 = none,
    args: []const u32 = &.{},
    /// Direct invocations of the label in this frame.
    calls: u8 = 0,
    /// The operand stack's clock at a direct call (the walk's entries).
    pending: u32 = Ids.none_int,
};

/// A supply root (§2.11.3): what call `call`'s callee hands its label
/// `label` (the index in the callee's contract) as argument `k`.
pub const Supply = struct { call: u32, label: u32, k: u32, root: u32 };

pub const Root = struct {
    kind: RootKind,
    a: u32,
    place: PlaceId,
    /// The root place's `ε` path: every position's slot is below it.
    path: PathId,
    pos: u32 = none,
};

pub const Kind = enum(u8) {
    scalar,
    bot,
    top,
    built,
    ref,
    alt,
    shared,
    /// A parameterless `foreign`'s value (§2.10, *host objects*).
    host,
};

/// What a `built` value is (§2.3.3).
pub const Form = enum(u8) {
    tuple,
    /// (`list`: `head` is 0, or one more than the value whose storage the
    /// list is: a construction over its base, §2.13.2.)
    /// `head`: the constructor's ordinal in its type.
    ctor,
    list,
    /// `extra`: the run of the fields' ranks in `words`, in the kids' order.
    record,
    /// `head`: the code (`Groups` numbers codes); kids are the captures.
    closure,
    /// A markup tree or another opaque object: its kids are what it holds.
    opaque_,
};

/// One value (§2.3.3). `built`: `form`, `head`, `site` (the instruction whose
/// object is its storage, or `none`), `extra`. `ref`: `root`, `pos` and
/// `family` (a slot set, or `Slots.empty` for the position's own subtree).
/// `alt`: `head` the choice; kids are `(arm, value)` pairs. `shared`:
/// `head` the module, `site` the declaration.
pub const Val = struct {
    kind: Kind,
    /// The value's place, `.none` when unknown: a `⟲` projection of a
    /// built value follows the parts that stay on the place's cycle.
    place: PlaceId = .none,
    form: Form = .tuple,
    head: u32 = 0,
    site: u32 = none,
    extra: []const u32 = &.{},
    root: u32 = none,
    pos: u32 = none,
    family: SetId = Slots.empty,
    kids: []const u32 = &.{},
};

pub const LeafKind = enum(u8) {
    /// The objects at `slots` in the subtree at `pos` of `root`.
    ref,
    /// The object built by instruction `atom`.
    site,
    /// The objects call `atom`'s callee allocated.
    fresh,
    /// A top-level value: `atom` the module, `extra` the declaration.
    shared,
    /// The answer of a label the frame cannot apply (§2.11.3): `atom` its `cbs` index, `extra` the answer's slot (a `Slots.Rel`).
    answer,
    top,
    /// A prepend's deferred storage, `atom` its value (§2.3.4; a leaf set's).
    recons,
    /// Objects JavaScript made, or beni objects that escaped (§2.10, *host objects*).
    host,
};

pub const Leaf = struct {
    kind: LeafKind,
    atom: u32 = 0,
    extra: u32 = 0,
    root: u32 = none,
    pos: u32 = none,
    slots: SetId = Slots.empty,
    /// A tag set (`Frame.tags`), 0 for none; a route set a projection
    /// reached it under, relative to `tags` (§2.11.2), 0 for none.
    tags: u32 = 0,
    routes: u32 = 0,
    /// A shallow target at its position's own slot only.
    at_pos: bool = false,
};

pub const Frame = struct {
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    places: *Place.Table,
    slots: *Slots.Table,

    roots: std.ArrayList(Root) = .empty,
    pos: std.ArrayList(Pos) = .empty,
    pos_index: Ids.FixedDict(4) = .{},
    vals: std.ArrayList(Val) = .empty,
    leaves: std.ArrayList(Leaf) = .empty,
    leaf_index: Ids.FixedDict(8) = .{},
    /// Leaf and tag sets; per value, its leaf set and its storage's (§2.3.4).
    sets: Leaves.Table = .{},
    deep: std.ArrayList(u32) = .empty,
    shallow: std.ArrayList(u32) = .empty,
    calls: std.ArrayList(Call) = .empty,
    cbs: std.ArrayList(Cb) = .empty,
    supplies: std.ArrayList(Supply) = .empty,

    pub fn deinit(f: *Frame) void {
        const gpa = f.gpa;
        f.roots.deinit(gpa);
        f.pos.deinit(gpa);
        f.pos_index.deinit(gpa);
        f.vals.deinit(gpa);
        f.leaves.deinit(gpa);
        f.leaf_index.deinit(gpa);
        f.sets.deinit(gpa);
        f.deep.deinit(gpa);
        f.shallow.deinit(gpa);
        f.calls.deinit(gpa);
        f.cbs.deinit(gpa);
        f.supplies.deinit(gpa);
    }

    pub fn charge(f: *Frame, cat: Ids.Category, n: u32) Error!void {
        try f.account.reserve(cat, n);
    }

    pub fn gc(f: *Frame) Ids.Charge {
        return .growth(f.account);
    }

    // ---- values -------------------------------------------------------------

    pub fn mk(f: *Frame, v: Val) Error!u32 {
        try f.charge(.shape, 1);
        const id: u32 = @intCast(f.vals.items.len);
        const sets = try f.setsOf(v, id);
        try f.vals.append(f.gpa, v);
        try f.deep.append(f.gpa, sets[0]);
        try f.shallow.append(f.gpa, sets[1]);
        return id;
    }

    /// A leaf set's `ref` element, its slots named when read: the family's
    /// or the position's `below` (deep), or their own storage. `resolveRef`
    /// gives the leaf, or null when it names no object slot.
    pub const deferred_deep: u32 = 1;
    pub const deferred_own: u32 = 2;
    pub fn resolveRef(f: *Frame, l0: Leaf) Error!?Leaf {
        var l = l0;
        const g = f.gpa;
        const slot = f.pos.items[l.pos].slot;
        l.slots = switch (l0.extra) {
            deferred_deep => if (l0.slots != Slots.empty) try Subtree.belowSet(f.slots, g, f.account, f.places, l0.slots) else try Subtree.below(f.slots, g, f.account, f.places, slot),
            else => if (l0.slots != Slots.empty) try f.slots.setOf(g, f.account, f.places, f.slots.items(l0.slots)) else try f.slots.canon(g, f.account, f.places, slot),
        };
        l.extra = 0;
        return if (l.slots == Slots.empty) null else l;
    }

    fn oneOf(f: *Frame, l: Leaf) Error!u32 {
        // Open: a call's, a supply's or a deferred leaf, read under the reader's tags.
        return f.sets.one(f.gpa, f.account, try f.leaf(l), 0, l.kind == .ref or l.kind == .recons, l.kind == .recons or (l.kind == .ref and f.roots.items[l.root].kind != .param));
    }

    /// Value `v`'s leaf sets, deep and its storage's, from its kids' (§2.3.4).
    fn setsOf(f: *Frame, v: Val, id: u32) Error![2]u32 {
        const s = &f.sets;
        const g = f.gpa;
        const a = f.account;
        switch (v.kind) {
            .scalar, .bot => return .{ Leaves.empty, Leaves.empty },
            .top, .shared, .host => {
                const x = try f.oneOf(if (v.kind == .shared) .{ .kind = .shared, .atom = v.head, .extra = v.site } else .{ .kind = if (v.kind == .top) .top else .host });
                return .{ x, x };
            },
            .ref => {
                // Its slots are named when it is read (`resolveRef`); a place
                // that holds no object has none (a crossing tuple of 2¹⁶ paths).
                const crossing = v.family == Slots.empty and !Slots.holdsAny(f.places, f.pos.items[v.pos].slot);
                const deep = if (crossing) Leaves.empty else try f.oneOf(.{ .kind = .ref, .root = v.root, .pos = v.pos, .slots = v.family, .extra = deferred_deep });
                const shallow = try f.oneOf(.{ .kind = .ref, .root = v.root, .pos = v.pos, .slots = v.family, .at_pos = v.family == Slots.empty, .extra = deferred_own });
                return .{ deep, shallow };
            },
            .built => {
                // Built over a base: its storage, read deep; a prepend's own
                // storage is the base's only on a re-cons (deferred).
                const own = if (v.site != none) try f.oneOf(.{ .kind = .site, .atom = v.site }) else Leaves.empty;
                const over = v.form == .list and v.head != 0;
                const base = if (over) f.shallow.items[v.head - 1] else Leaves.empty;
                const recons = if (over and v.site != none) try f.oneOf(.{ .kind = .recons, .atom = id }) else Leaves.empty;
                return s.built(g, a, own, base, recons, f.deep.items, v.kids);
            },
            .alt => return s.alt(g, a, f.deep.items, f.shallow.items, v.head, v.kids),
        }
    }

    pub fn val(f: *const Frame, id: u32) Val {
        return f.vals.items[id];
    }

    /// A value's kids: a run in the frame's arena, valid while others are made.
    pub fn kidsOf(f: *const Frame, v: Val) []const u32 {
        _ = f;
        return v.kids;
    }

    pub fn wordsOf(f: *const Frame, r: []const u32) []const u32 {
        _ = f;
        return r;
    }

    pub fn mkKids(f: *Frame, ks: []const u32) Error![]const u32 {
        try f.charge(.edge, @intCast(@max(1, ks.len)));
        return f.arena.dupe(u32, ks);
    }

    pub fn mkWords(f: *Frame, ws: []const u32) Error![]const u32 {
        return f.arena.dupe(u32, ws);
    }
    pub fn scalar(f: *Frame) Error!u32 {
        return f.mk(.{ .kind = .scalar });
    }
    pub fn top(f: *Frame) Error!u32 {
        return f.mk(.{ .kind = .top });
    }
    pub fn bot(f: *Frame) Error!u32 {
        return f.mk(.{ .kind = .bot });
    }

    /// A reference to the whole of root `r`.
    pub fn refRoot(f: *Frame, r: u32) Error!u32 {
        return f.mk(.{ .kind = .ref, .root = r, .pos = f.roots.items[r].pos, .place = f.roots.items[r].place });
    }

    // ---- roots and positions -------------------------------------------------

    pub fn addRoot(f: *Frame, kind: RootKind, a: u32, place: PlaceId) Error!u32 {
        const path = try f.places.rootPath(f.gpa, place);
        const id: u32 = @intCast(f.roots.items.len);
        try f.roots.append(f.gpa, .{ .kind = kind, .a = a, .place = place, .path = path });
        try f.charge(.path, 1);
        try f.pos.append(f.gpa, .{ .root = id, .parent = none, .kind = .plain, .a = 0, .b = 0, .slot = path });
        f.roots.items[id].pos = @intCast(f.pos.items.len - 1);
        return id;
    }

    /// The child of position `p` by a step, normalised so that a slice is
    /// only ever a last step (§2.3.2); null when the place has no such step.
    pub fn child(f: *Frame, p: u32, kind0: PKind, a0: u32, b0: u32) Error!?u32 {
        var parent = p;
        var kind = kind0;
        var a = a0;
        var b = b0;
        const ps = f.pos.items[p];
        if (ps.kind == .slice and ps.parent != none) switch (kind) {
            .front => {
                parent = ps.parent;
                a = ps.a + a;
            },
            .back => {
                parent = ps.parent;
                a = ps.b + a;
            },
            .slice => {
                parent = ps.parent;
                a = ps.a + a;
                b = ps.b + b;
            },
            .plain => {},
        };
        if (kind == .slice and a == 0 and b == 0) return parent;
        try f.charge(.path, 1);
        const key: [4]u32 = .{ parent, @backingInt(kind), a, b };
        if (f.pos_index.get(key)) |hit| return hit;
        const pp = f.pos.items[parent];
        const slot: PathId = switch (kind) {
            .plain => (try f.places.extend(f.gpa, f.gc(), pp.slot, Step.fromWord(a))) orelse return null,
            .front, .back => (try f.places.extend(f.gpa, f.gc(), pp.slot, Step.elem)) orelse return null,
            .slice => pp.slot,
        };
        const id: u32 = @intCast(f.pos.items.len);
        try f.pos.append(f.gpa, .{ .root = pp.root, .parent = parent, .kind = kind, .a = a, .b = b, .slot = slot });
        try f.pos_index.put(f.gpa, key, id);
        _ = &kind;
        return id;
    }

    /// The steps from the root to `p`, root first, into `out`.
    pub fn stepsTo(f: *Frame, p: u32, out: *std.ArrayList(u32)) Error!void {
        out.clearRetainingCapacity();
        var at = p;
        while (at != none and f.pos.items[at].parent != none) : (at = f.pos.items[at].parent) try out.append(f.gpa, at);
        std.mem.reverse(u32, out.items);
    }

    /// §2.3.2: whether two positions of one root may name one element.
    /// `second_prefix`: the second is a prefix of the first (or equal).
    pub fn related(f: *Frame, p1: u32, p2: u32) Error!StepRel {
        var a: std.ArrayList(u32) = .empty;
        defer a.deinit(f.gpa);
        var c: std.ArrayList(u32) = .empty;
        defer c.deinit(f.gpa);
        try f.stepsTo(p1, &a);
        try f.stepsTo(p2, &c);
        try f.charge(.inspection, @intCast(1 + @min(a.items.len, c.items.len)));
        const n = @min(a.items.len, c.items.len);
        for (0..n) |k| {
            if (a.items[k] == c.items[k]) continue;
            return Steps.stepRel(f.pos.items[a.items[k]], f.pos.items[c.items[k]]);
        }
        return .{ .rel = .related, .second_prefix = c.items.len <= a.items.len };
    }

    // ---- leaves and tags -----------------------------------------------------

    pub fn leaf(f: *Frame, l: Leaf) Error!u32 {
        try f.charge(.cell, 1);
        const key: [8]u32 = .{ @backingInt(l.kind) | (@as(u32, @intFromBool(l.at_pos)) << 8), l.atom, l.extra, l.root, l.pos, l.slots, l.tags, l.routes };
        if (f.leaf_index.get(key)) |hit| return hit;
        const id: u32 = @intCast(f.leaves.items.len);
        try f.leaves.append(f.gpa, l);
        try f.leaf_index.put(f.gpa, key, id);
        return id;
    }

    pub fn leafAt(f: *const Frame, id: u32) Leaf {
        return f.leaves.items[id];
    }

    /// The arm set of one arm (a tag's second word, §2.3.5).
    pub fn armOf(f: *Frame, arm: u32) Error!u32 {
        return f.sets.tags.armOf(f.gpa, f.account, arm);
    }

    pub fn internTags(f: *Frame, words: []const [2]u32) Error!u32 {
        return f.sets.tags.internTags(f.gpa, f.account, words);
    }

    /// The union of two tag sets, or null when they give one choice two
    /// arms (never together, §2.3.5).
    pub fn mergeTags(f: *Frame, x: u32, y: u32) Error!?u32 {
        return f.sets.tags.merge(f.gpa, f.account, x, y);
    }

    /// Leaf `l` with tags `t` added, or null when they conflict.
    pub fn withTags(f: *Frame, l: u32, t: u32) Error!?u32 {
        if (t == 0) return l;
        var x = f.leaves.items[l];
        x.tags = (try f.mergeTags(x.tags, t)) orelse return null;
        return try f.leaf(x);
    }
};

const testing = std.testing;

test "two front positions are distinct, a front and a back are related" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var places: Place.Table = .{};
    defer places.deinit(testing.allocator);
    var slots: Slots.Table = .{};
    defer slots.deinit(testing.allocator);
    var f: Frame = .{ .gpa = testing.allocator, .arena = arena_state.allocator(), .account = &account, .places = &places, .slots = &slots };
    defer f.deinit();
    // A hand-made position tree: the steps' slots are not read by `related`.
    try f.pos.append(testing.allocator, .{ .root = 0, .parent = none, .kind = .plain, .a = 0, .b = 0, .slot = .none });
    try f.pos.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = .front, .a = 0, .b = 0, .slot = .none });
    try f.pos.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = .front, .a = 1, .b = 0, .slot = .none });
    try f.pos.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = .back, .a = 0, .b = 0, .slot = .none });
    try f.pos.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = .slice, .a = 1, .b = 0, .slot = .none });
    try testing.expectEqual(Rel.distinct, (try f.related(1, 2)).rel);
    try testing.expectEqual(Rel.related, (try f.related(1, 3)).rel);
    try testing.expectEqual(Rel.distinct, (try f.related(1, 4)).rel);
    try testing.expectEqual(Rel.related, (try f.related(2, 4)).rel);
    try testing.expect((try f.related(1, 0)).second_prefix);
}

test "every index of positions meets exactly what the pairwise relation relates (§2.3.2)" {
    // A two-level position tree of every step class. Each position is filed
    // by the protocol every index shares (`Steps.fileUnder`/`askFor`): in
    // `Steps.PosLists`, `Sweep.Live`'s and `Stack.Index`'s storage, and in
    // a map keyed as `Entries.Within` keys it. A query at each position
    // meets every position `Frame.related` relates to it, and meets an
    // unrelated one only where a slice's indices tell them apart.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var places: Place.Table = .{};
    defer places.deinit(testing.allocator);
    var slots: Slots.Table = .{};
    defer slots.deinit(testing.allocator);
    var f: Frame = .{ .gpa = testing.allocator, .arena = arena_state.allocator(), .account = &account, .places = &places, .slots = &slots };
    defer f.deinit();
    const kinds = [_]struct { PKind, u32, u32 }{
        .{ .plain, Step.elem.word(), 0 },     .{ .plain, (Step{ .kind = .field, .payload = 0 }).word(), 0 },
        .{ .plain, Step.contents.word(), 0 }, .{ .front, 0, 0 },
        .{ .front, 1, 0 },                    .{ .back, 0, 0 },
        .{ .back, 1, 0 },                     .{ .slice, 1, 0 },
        .{ .slice, 0, 1 },                    .{ .slice, 1, 1 },
        .{ .slice, 2, 0 },
    };
    try f.pos.append(testing.allocator, .{ .root = 0, .parent = none, .kind = .plain, .a = 0, .b = 0, .slot = .none });
    for (kinds) |k| {
        const parent: u32 = @intCast(f.pos.items.len);
        try f.pos.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = k[0], .a = k[1], .b = k[2], .slot = .none });
        // A slice is only ever a last step.
        if (k[0] != .slice) for (kinds) |k2| try f.pos.append(testing.allocator, .{ .root = 0, .parent = parent, .kind = k2[0], .a = k2[1], .b = k2[2], .slot = .none });
    }
    const n: u32 = @intCast(f.pos.items.len);
    const pos = f.pos.items;
    var lists: Steps.PosLists = .{};
    defer lists.deinit(testing.allocator);
    // `Entries.Within`'s keys: `(position, list)` to the members filed there.
    const Keyed = struct {
        map: std.AutoHashMapUnmanaged([2]u32, std.ArrayList(u32)) = .empty,
        item: u32 = 0,
        out: ?*std.ArrayList(u32) = null,
        pub fn key(x: *@This(), at: u32, list: u32) Allocator.Error!void {
            if (x.out) |o| {
                if (x.map.get(.{ at, list })) |l| try o.appendSlice(testing.allocator, l.items);
                return;
            }
            const got = try x.map.getOrPut(testing.allocator, .{ at, list });
            if (!got.found_existing) got.value_ptr.* = .empty;
            try got.value_ptr.append(testing.allocator, x.item);
        }
    };
    var keyed: Keyed = .{};
    defer {
        var it = keyed.map.valueIterator();
        while (it.next()) |l| l.deinit(testing.allocator);
        keyed.map.deinit(testing.allocator);
    }
    var q: u32 = 0;
    while (q < n) : (q += 1) {
        try lists.file(testing.allocator, &account, pos, q, q);
        keyed.item = q;
        try Steps.fileUnder(pos, q, &keyed);
    }
    var met: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&met) |*m| m.deinit(testing.allocator);
    var p: u32 = 0;
    while (p < n) : (p += 1) {
        for (&met) |*m| m.clearRetainingCapacity();
        try lists.ask(testing.allocator, &account, pos, p, &met[0]);
        keyed.out = &met[1];
        try Steps.askFor(pos, p, &keyed);
        keyed.out = null;
        for (&met) |*m| {
            q = 0;
            while (q < n) : (q += 1) {
                const found = std.mem.indexOfScalar(u32, m.items, q) != null;
                if ((try f.related(p, q)).rel == .related) {
                    try testing.expect(found);
                } else if (found) {
                    // Met though apart: the two part at a slice and a list
                    // step its indices skip.
                    var x = p;
                    var y = q;
                    while (pos[x].parent != pos[y].parent) {
                        if (pos[x].parent != 0 and pos[x].parent != none) x = pos[x].parent else y = pos[y].parent;
                    }
                    try testing.expect(pos[x].kind == .slice or pos[y].kind == .slice);
                }
            }
        }
    }
}
