//! L3: contracts (`docs/design/ownership-v2.md` §2.10, §3.5): what one
//! code (a declaration, a lambda, a local function, a constructor, a worded
//! row) does with its parameters, over slots. The module's contracts live
//! in one table of flat runs; a contract is a record of ranges, immutable
//! once committed. A join makes a new contract.
//!
//! Obligations kept here: none of §2.14's directly; `within` is §2.12's
//! validation test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Trees = @import("Trees.zig");
const Forest = @import("Forest.zig");

pub const Rel = Slots.Rel;
pub const Range = Ids.Range;
pub const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

pub const Id = u32;
pub const Node = Trees.Node;
pub const Hit = Trees.Hit;

const Conds = @import("Conds.zig");
pub const Cond = Conds.Cond;
pub const occ = Conds.occ;
pub const apart_bit = Conds.apart_bit;
pub const occApart = Conds.occApart;
pub const isApart = Conds.isApart;
pub const deep_bit = Conds.deep_bit;
pub const occDeep = Conds.occDeep;
pub const isDeep = Conds.isDeep;
pub const occParam = Conds.occParam;
pub const occRel = Conds.occRel;
pub const weakest = Conds.weakest;
pub const sortOccs = Conds.sortOccs;

pub const ArrivalKind = Trees.ArrivalKind;
pub const Arrival = Trees.Arrival;

/// A read, write or escape (§2.10): parameter `j`'s slot, `deep` when it
/// reaches every slot below.
pub const Effect = struct {
    j: u32,
    slot: Rel,
    deep: bool = false,
    /// A read: the reads of a tree below `slot` (§2.10, *Effects as trees*).
    node: Node = 0,
};

/// A stored condition: `no`, or a run of `occs`.
pub const StoredCond = struct {
    no: bool = false,
    run: Range = .{},
};

/// A callback label (§2.11.3): the function slot it calls, its origin
/// `(module, declaration, offset)`, how often, and its supplies.
pub const Label = struct {
    j: u32,
    slot: Rel,
    origin: [3]u32,
    calls: Calls = .none,
    supplies: Range = .{},
};

pub const Calls = enum(u8) { none, once, many };

pub const Supply = struct {
    k: u32,
    /// `res` as a result tree (§2.10, *a contract is a tree of shared
    /// subtrees*): its root node.
    res_root: Node = 0,
    kept: Range,
    cond: StoredCond,
};

pub const Flags = packed struct(u8) {
    returns: bool = false,
    cross: bool = false,
    once: bool = false,
    words: bool = false,
    pessimistic: bool = false,
    _pad: u3 = 0,
};

pub const Head = struct {
    arity: u32,
    flags: Flags,
    /// `res` as a result tree: its root node.
    res_root: Node = 0,
    res_cond: StoredCond = .{},
    /// One tree a parameter (`Table.readsOf`).
    reads: Range = .{},
    writes: Range = .{},
    req: StoredCond = .{},
    escapes: Range = .{},
    labels: Range = .{},
};

/// A contract being built: plain lists, committed into the table at once.
pub const Draft = struct {
    arity: u32,
    flags: Flags = .{},
    res: Res = .{},
    res_cond: Cond = .{},
    reads: std.ArrayList(Effect) = .empty,
    writes: std.ArrayList(Effect) = .empty,
    req: Cond = .{},
    escapes: std.ArrayList(Effect) = .empty,
    labels: std.ArrayList(DraftLabel) = .empty,

    /// A result (or supply) being built: arrivals at slots, plain or wide (at
    /// the slot and, by structure, below it, §2.10 *Read-off*), and subtrees
    /// made whole (`node`). A slot marked open (a type variable's) holds its
    /// plain arrivals open. `base`: a committed tree joined in (§2.10 *Lattice*).
    pub const Res = struct {
        items: std.ArrayList(Entry) = .empty,
        has: Ids.FixedDict(5) = .{},
        marked: Ids.FixedDict(1) = .{},
        base: Node = 0,

        pub fn isOpen(r: *const Res, e: Entry) bool {
            return e.wide or r.marked.get(.{e.slot}) != null;
        }
    };
    pub const Entry = struct { slot: Rel, wide: bool = false, a: Arrival = .{ .kind = .top }, node: Node = 0 };
    pub const DraftLabel = struct {
        j: u32,
        slot: Rel,
        origin: [3]u32,
        calls: Calls = .none,
        supplies: std.ArrayList(DraftSupply) = .empty,

        pub fn supplyOf(l: *DraftLabel, arena: Allocator, k: u32) Allocator.Error!*DraftSupply {
            for (l.supplies.items) |*s| if (s.k == k) return s;
            try l.supplies.append(arena, .{ .k = k });
            return &l.supplies.items[l.supplies.items.len - 1];
        }
    };
    pub const DraftSupply = struct {
        k: u32,
        res: Res = .{},
        kept: std.ArrayList(Effect) = .empty,
        cond: Cond = .{},
    };

    /// Every plain arrival at `slot` is open (a type variable's slot).
    pub fn markOpen(r: *Res, arena: Allocator, slot: Rel) Ids.IndexError!void {
        try r.marked.put(arena, .{slot}, 0);
    }

    fn put(r: *Res, arena: Allocator, e: Entry) Ids.IndexError!bool {
        const a = e.a;
        const kind: u32 = if (e.node != 0) 2 else @intFromBool(e.wide);
        const got = try r.has.getOrPut(arena, .{ e.slot, kind, if (e.node != 0) e.node else @as(u32, @backingInt(a.kind)) | @as(u32, @intFromBool(a.deep)) << 8, a.j, a.slot });
        if (got.found_existing) return false;
        try r.items.append(arena, e);
        return true;
    }

    /// An arrival at `slot` and, by structure, at every slot below it.
    pub fn addWide(r: *Res, arena: Allocator, slot: Rel, a: Arrival) Ids.IndexError!bool {
        return put(r, arena, .{ .slot = slot, .wide = true, .a = a });
    }

    pub fn addArrival(r: *Res, arena: Allocator, slot: Rel, a: Arrival) Ids.IndexError!bool {
        return put(r, arena, .{ .slot = slot, .a = a });
    }

    /// A subtree made whole, below `slot`.
    pub fn addNode(r: *Res, arena: Allocator, slot: Rel, n: Node) Ids.IndexError!bool {
        if (n == 0) return false;
        return put(r, arena, .{ .slot = slot, .node = n });
    }

    pub fn addEffect(list: *std.ArrayList(Effect), arena: Allocator, e: Effect) Allocator.Error!bool {
        for (list.items) |*x| if (x.j == e.j and x.slot == e.slot and x.node == e.node) {
            if (e.deep and !x.deep) {
                x.deep = true;
                return true;
            }
            return false;
        };
        try list.append(arena, e);
        return true;
    }

    /// The label `(j, slot, origin)`, made when missing.
    pub fn labelOf(d: *Draft, arena: Allocator, j: u32, slot: Rel, origin: [3]u32) Allocator.Error!u32 {
        for (d.labels.items, 0..) |l, i| if (l.j == j and l.slot == slot and std.mem.eql(u32, &l.origin, &origin)) return @intCast(i);
        try d.labels.append(arena, .{ .j = j, .slot = slot, .origin = origin });
        return @intCast(d.labels.items.len - 1);
    }
};

pub const Table = struct {
    heads: std.ArrayList(Head) = .empty,
    effects: std.ArrayList(Effect) = .empty,
    /// The reads: `(j, tree)` a parameter.
    eroots: std.ArrayList([2]u32) = .empty,
    occs: std.ArrayList(u64) = .empty,
    labels: std.ArrayList(Label) = .empty,
    supplies: std.ArrayList(Supply) = .empty,
    /// `res` and supplies' `res` as result trees (§2.10), by node.
    trees: Trees.Table = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.trees.deinit(gpa);
        t.heads.deinit(gpa);
        t.effects.deinit(gpa);
        t.eroots.deinit(gpa);
        t.occs.deinit(gpa);
        t.labels.deinit(gpa);
        t.supplies.deinit(gpa);
    }

    pub fn head(t: *const Table, c: Id) Head {
        return t.heads.items[c];
    }
    pub fn effectsOf(t: *const Table, r: Range) []const Effect {
        return t.effects.items[r.start..][0..r.len];
    }
    pub fn readsOf(t: *const Table, r: Range) []const [2]u32 {
        return t.eroots.items[r.start..][0..r.len];
    }
    pub fn labelsOf(t: *const Table, r: Range) []const Label {
        return t.labels.items[r.start..][0..r.len];
    }
    pub fn suppliesOf(t: *const Table, r: Range) []const Supply {
        return t.supplies.items[r.start..][0..r.len];
    }

    /// Every nonempty node the trees `roots` reach, once, in post-order
    /// (a node after its kids, each node's kids in the canonical order):
    /// how a block writes them (§3.6). An explicit stack, a frame's kids the
    /// top run of `ks` from its start: a tree is as deep as its type.
    pub fn postOrder(t: *const Table, gpa: Allocator, places: *const Place.Table, roots: []const Node, out: *std.ArrayList(Node)) Allocator.Error!void {
        var done: std.AutoHashMapUnmanaged(Node, void) = .empty;
        defer done.deinit(gpa);
        var stack: std.ArrayList([3]u32) = .empty;
        defer stack.deinit(gpa);
        var ks: std.ArrayList([2]u32) = .empty;
        defer ks.deinit(gpa);
        var sorted: std.ArrayList([2]u32) = .empty;
        defer sorted.deinit(gpa);
        for (roots) |root| {
            var push = root;
            while (true) {
                if (push != 0 and !(try done.getOrPut(gpa, push)).found_existing) {
                    try Forest.sortedKids(&t.trees, gpa, places, push, &sorted);
                    try stack.append(gpa, .{ push, @intCast(ks.items.len), 0 });
                    try ks.appendSlice(gpa, sorted.items);
                }
                const f = if (stack.items.len == 0) break else &stack.items[stack.items.len - 1];
                push = 0;
                if (f[2] < ks.items.len - f[1]) {
                    push = ks.items[f[1] + f[2]][1];
                    f[2] += 1;
                    continue;
                }
                try out.append(gpa, f[0]);
                ks.shrinkRetainingCapacity(f[1]);
                _ = stack.pop();
            }
        }
    }

    /// A stored condition as a walk-time one, its words in walk order
    /// (sorted by the raw occurrence word) in `arena`.
    pub fn cond(t: *const Table, arena: Allocator, c: StoredCond) Allocator.Error!Cond {
        if (c.no) return .unprovable;
        if (c.run.len == 0) return .yes;
        const out = try arena.dupe(u64, t.occs.items[c.run.start..][0..c.run.len]);
        std.mem.sort(u64, out, {}, std.sort.asc(u64));
        return .{ .sel = out };
    }

    /// The occurrences of a stored condition, in canonical order.
    pub fn occsOf(t: *const Table, c: StoredCond) []const u64 {
        return t.occs.items[c.run.start..][0..c.run.len];
    }

    /// The arrival `a` lists `cb` by label index; `labelAt` reads it.
    pub fn labelAt(t: *const Table, c: Id, i: u32) Label {
        return t.labels.items[t.heads.items[c].labels.start + i];
    }

    // ---- committing ----------------------------------------------------------

    fn putCond(t: *Table, gpa: Allocator, slots: *const Slots.Table, c: Cond) Allocator.Error!StoredCond {
        if (c.no) return .{ .no = true };
        const start: u32 = @intCast(t.occs.items.len);
        // An occurrence a deep one of its parameter asks already, at a slot
        // whose steps continue the deep one's, says nothing more (§2.9.1):
        // left out, so a join that adds it changes nothing.
        outer: for (c.sel) |x| {
            const xw = slots.relWords(occRel(x));
            for (c.sel) |y| {
                if (y == x or !isDeep(y) or occParam(y) != occParam(x) or (isApart(y) and !isApart(x))) continue;
                const yw = slots.relWords(occRel(y));
                if (xw.len < yw.len or !std.mem.eql(u32, yw, xw[0..yw.len])) continue;
                if (xw.len == yw.len and isDeep(x) and (isApart(x) == isApart(y))) continue;
                continue :outer;
            }
            try t.occs.append(gpa, x);
        }
        const run = t.occs.items[start..];
        sortOccs(slots, run);
        return .{ .run = .{ .start = start, .len = @intCast(run.len) } };
    }

    fn putEffects(t: *Table, gpa: Allocator, slots: *const Slots.Table, list: []Effect) Allocator.Error!Range {
        std.mem.sort(Effect, list, slots, effectLess);
        const start: u32 = @intCast(t.effects.items.len);
        // An effect below a deep one of the same parameter says nothing more.
        outer: for (list) |x| {
            for (t.effects.items[start..]) |y| {
                if (y.j == x.j and y.deep and y.slot != x.slot and continues(slots, y.slot, &.{}, x.slot, true)) continue :outer;
            }
            try t.effects.append(gpa, x);
        }
        return .{ .start = start, .len = @intCast(t.effects.items.len - start) };
    }

    /// A draft's reads as one tree a parameter (§2.10, *Effects as trees*):
    /// a deep read covers what is below it.
    fn putReads(t: *Table, gpa: Allocator, slots: *const Slots.Table, list: []const Effect) Ids.IndexError!Range {
        const start: u32 = @intCast(t.eroots.items.len);
        var memo: Ids.FixedDict(2) = .{};
        defer memo.deinit(gpa);
        var js: std.ArrayList(u32) = .empty;
        defer js.deinit(gpa);
        for (list) |e| if (std.mem.indexOfScalar(u32, js.items, e.j) == null) try js.append(gpa, e.j);
        std.mem.sort(u32, js.items, {}, std.sort.asc(u32));
        for (js.items) |j| {
            var r: Draft.Res = .{};
            defer {
                r.items.deinit(gpa);
                r.has.deinit(gpa);
                r.marked.deinit(gpa);
            }
            for (list) |e| {
                if (e.j != j) continue;
                _ = if (e.node != 0) try Draft.addNode(&r, gpa, e.slot, e.node) else if (e.deep) try Draft.addWide(&r, gpa, e.slot, Forest.mark) else try Draft.addArrival(&r, gpa, e.slot, Forest.mark);
            }
            const n = try Forest.foldDeep(&t.trees, gpa, &memo, try t.putRes(gpa, slots, &r, &.{}));
            if (n != 0) try t.eroots.append(gpa, .{ j, n });
        }
        return .{ .start = start, .len = @intCast(t.eroots.items.len - start) };
    }

    fn readsWithin(t: *const Table, arena: Allocator, a: Range, b: Range) Ids.IndexError!bool {
        var memo: Ids.FixedDict(2) = .{};
        for (t.readsOf(a)) |x| {
            const y = for (t.readsOf(b)) |y| {
                if (y[0] == x[0]) break y[1];
            } else 0;
            if (!try Forest.effectsWithin(&t.trees, arena, &memo, x[1], y)) return false;
        }
        return true;
    }

    // ---- result trees (§2.10, *a contract is a tree of shared subtrees*) ---

    const Flat = struct { slot: Rel, open: bool, a: Arrival };

    /// The tree of a draft's result, its `cb` arrivals renumbered by
    /// `rank`: its arrivals as entries (sorted by their slots' canonical
    /// keys, a plain run before an open one), its subtrees and its base
    /// joined in.
    pub fn putRes(t: *Table, gpa: Allocator, slots: *const Slots.Table, r: *const Draft.Res, rank: []const u32) Ids.IndexError!Node {
        var flat: std.ArrayList(Flat) = .empty;
        defer flat.deinit(gpa);
        for (r.items.items) |e| if (e.node == 0) {
            var a = e.a;
            if (a.kind == .cb) a.j = rank[a.j];
            try flat.append(gpa, .{ .slot = e.slot, .open = r.isOpen(e), .a = a });
        };
        std.mem.sort(Flat, flat.items, slots, struct {
            fn lt(s: *const Slots.Table, x: Flat, y: Flat) bool {
                const o = s.relOrder(x.slot, y.slot);
                if (o != .eq) return o == .lt;
                if (x.open != y.open) return !x.open;
                return arrivalLess(s, x.a, y.a);
            }
        }.lt);
        var m: usize = 0;
        for (flat.items) |x| {
            if (m != 0 and flat.items[m - 1].slot == x.slot and flat.items[m - 1].open == x.open and flat.items[m - 1].a.eql(x.a)) continue;
            flat.items[m] = x;
            m += 1;
        }
        var root = try t.treeOf(gpa, slots, flat.items[0..m], 0);
        var memo: Ids.FixedDict(2) = .{};
        defer memo.deinit(gpa);
        const less = lessOf(slots);
        const ident = for (rank, 0..) |x, i| {
            if (x != i) break false;
        } else true;
        for (r.items.items) |e| if (e.node != 0) {
            memo.clearRetainingCapacity();
            const n = if (ident) e.node else try Forest.mapLabels(&t.trees, gpa, &memo, e.node, rank, less);
            memo.clearRetainingCapacity();
            root = try Forest.unite(&t.trees, gpa, &memo, root, try Forest.graft(&t.trees, gpa, slots.relWords(e.slot), n), less, .plain);
        };
        if (r.base != 0) {
            memo.clearRetainingCapacity();
            const b = if (ident) r.base else try Forest.mapLabels(&t.trees, gpa, &memo, r.base, rank, less);
            memo.clearRetainingCapacity();
            root = try Forest.unite(&t.trees, gpa, &memo, b, root, less, .plain);
        }
        return root;
    }

    /// The node of the sorted entries `run` (each `depth` steps or more):
    /// those of exactly `depth` steps are its own, the others its kids',
    /// grouped by their step at `depth` (a key's prefix of steps is a
    /// prefix of its words, so a group is one run).
    fn treeOf(t: *Table, gpa: Allocator, slots: *const Slots.Table, run: []const Flat, depth: usize) Ids.IndexError!Node {
        var here: std.ArrayList(Arrival) = .empty;
        defer here.deinit(gpa);
        var open: std.ArrayList(Arrival) = .empty;
        defer open.deinit(gpa);
        var i: usize = 0;
        while (i < run.len and slots.relWords(run[i].slot).len == depth) : (i += 1) {
            try (if (run[i].open) &open else &here).append(gpa, run[i].a);
        }
        var kids: std.ArrayList([2]u32) = .empty;
        defer kids.deinit(gpa);
        while (i < run.len) {
            const st = slots.relWords(run[i].slot)[depth];
            var n = i + 1;
            while (n < run.len and slots.relWords(run[n].slot)[depth] == st) n += 1;
            try kids.append(gpa, .{ st, try t.treeOf(gpa, slots, run[i..n], depth + 1) });
            i = n;
        }
        return t.trees.node(gpa, here.items, open.items, kids.items);
    }

    /// Commit a draft: every list in its canonical order (§2.10).
    pub fn commit(t: *Table, gpa: Allocator, account: *Ids.Account, slots: *const Slots.Table, d: *Draft) Error!Id {
        try account.reserve(.class, 1);
        var h: Head = .{ .arity = d.arity, .flags = d.flags };
        // Labels: sorted by (j, slot, origin); `cb` arrivals renumbered.
        const order = try gpa.alloc(u32, d.labels.items.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, .{ slots, d.labels.items }, struct {
            fn lt(c: struct { *const Slots.Table, []Draft.DraftLabel }, x: u32, y: u32) bool {
                const a = c[1][x];
                const b = c[1][y];
                if (a.j != b.j) return a.j < b.j;
                const o = c[0].relOrder(a.slot, b.slot);
                if (o != .eq) return o == .lt;
                return std.mem.order(u32, &a.origin, &b.origin) == .lt;
            }
        }.lt);
        const rank = try gpa.alloc(u32, d.labels.items.len);
        defer gpa.free(rank);
        for (order, 0..) |o, r| rank[o] = @intCast(r);
        // The result and the supplies name the labels by their sorted order.
        h.res_root = try t.putRes(gpa, slots, &d.res, rank);
        h.res_cond = try t.putCond(gpa, slots, d.res_cond);
        h.reads = try t.putReads(gpa, slots, d.reads.items);
        h.writes = try t.putEffects(gpa, slots, d.writes.items);
        h.req = try t.putCond(gpa, slots, d.req);
        h.escapes = try t.putEffects(gpa, slots, d.escapes.items);
        const lstart: u32 = @intCast(t.labels.items.len);
        for (order) |o| {
            const l = &d.labels.items[o];
            std.mem.sort(Draft.DraftSupply, l.supplies.items, {}, struct {
                fn lt(_: void, a: Draft.DraftSupply, b: Draft.DraftSupply) bool {
                    return a.k < b.k;
                }
            }.lt);
            const sstart: u32 = @intCast(t.supplies.items.len);
            // The supplies' runs are made first; their records after.
            var made: std.ArrayList(Supply) = .empty;
            defer made.deinit(gpa);
            for (l.supplies.items) |*s| {
                try made.append(gpa, .{ .k = s.k, .res_root = try t.putRes(gpa, slots, &s.res, rank), .kept = try t.putEffects(gpa, slots, s.kept.items), .cond = try t.putCond(gpa, slots, s.cond) });
            }
            try t.supplies.appendSlice(gpa, made.items);
            try t.labels.append(gpa, .{ .j = l.j, .slot = l.slot, .origin = l.origin, .calls = l.calls, .supplies = .{ .start = sstart, .len = @intCast(made.items.len) } });
        }
        h.labels = .{ .start = lstart, .len = @intCast(d.labels.items.len) };
        try t.heads.append(gpa, h);
        return @intCast(t.heads.items.len - 1);
    }

    /// A draft holding `c`'s facts, in `arena`: what a join starts from.
    pub fn draftOf(t: *const Table, arena: Allocator, c: Id) Allocator.Error!Draft {
        const h = t.heads.items[c];
        var d: Draft = .{ .arity = h.arity, .flags = h.flags };
        d.res.base = h.res_root;
        d.res_cond = try t.cond(arena, h.res_cond);
        for (t.readsOf(h.reads)) |x| try d.reads.append(arena, .{ .j = x[0], .slot = Slots.root, .node = x[1] });
        try d.writes.appendSlice(arena, t.effectsOf(h.writes));
        d.req = try t.cond(arena, h.req);
        try d.escapes.appendSlice(arena, t.effectsOf(h.escapes));
        for (t.labelsOf(h.labels)) |l| {
            var dl: Draft.DraftLabel = .{ .j = l.j, .slot = l.slot, .origin = l.origin, .calls = l.calls };
            for (t.suppliesOf(l.supplies)) |s| {
                var ds: Draft.DraftSupply = .{ .k = s.k, .cond = try t.cond(arena, s.cond) };
                ds.res.base = s.res_root;
                try ds.kept.appendSlice(arena, t.effectsOf(s.kept));
                try dl.supplies.append(arena, ds);
            }
            try d.labels.append(arena, dl);
        }
        return d;
    }

    /// `a ⊔ b` (§2.10 *Lattice*): never drops a result slot.
    pub fn join(t: *Table, gpa: Allocator, arena: Allocator, account: *Ids.Account, slots: *const Slots.Table, a: Id, b: Id) Error!Id {
        if (a == b) return a;
        var d = try t.draftOf(arena, a);
        try t.mergeInto(gpa, arena, account, slots, &d, b);
        return t.commit(gpa, account, slots, &d);
    }

    /// Add `b`'s facts to draft `d`.
    fn mergeInto(t: *Table, gpa: Allocator, arena: Allocator, account: *Ids.Account, slots: *const Slots.Table, d: *Draft, b: Id) Error!void {
        const hb = t.heads.items[b];
        try account.reserve(.class, 1);
        const b_returns = hb.flags.returns;
        const a_returns = d.flags.returns;
        d.flags.returns = a_returns or b_returns;
        if (!a_returns) d.flags.cross = hb.flags.cross else if (b_returns) d.flags.cross = d.flags.cross and hb.flags.cross;
        d.flags.once = d.flags.once or hb.flags.once;
        // A side that does not return says nothing of the result's condition.
        const bc = try t.cond(arena, hb.res_cond);
        if (!a_returns) d.res_cond = bc else if (b_returns) d.res_cond = try weakest(arena, account, d.res_cond, bc);
        d.req = try Cond.conj(arena, account, d.req, try t.cond(arena, hb.req));
        // Labels of `b`, matched to `d`'s by (j, slot, origin): `b`'s index → `d`'s.
        const map = try arena.alloc(u32, hb.labels.len);
        for (t.labelsOf(hb.labels), 0..) |l, i| map[i] = try d.labelOf(arena, l.j, l.slot, l.origin);
        for (t.labelsOf(hb.labels), 0..) |l, i| {
            const at = map[i];
            const dl = &d.labels.items[at];
            dl.calls = @fromBackingInt(@intCast(@max(@backingInt(dl.calls), @backingInt(l.calls))));
            for (t.suppliesOf(l.supplies)) |s| {
                const ds = try dl.supplyOf(arena, s.k);
                try t.mergeRes(gpa, slots, &ds.res, s.res_root, map);
                for (t.effectsOf(s.kept)) |e| _ = try Draft.addEffect(&ds.kept, arena, e);
                ds.cond = try weakest(arena, account, ds.cond, try t.cond(arena, s.cond));
            }
        }
        try t.mergeRes(gpa, slots, &d.res, hb.res_root, map);
        for (t.readsOf(hb.reads)) |x| _ = try Draft.addEffect(&d.reads, arena, .{ .j = x[0], .slot = Slots.root, .node = x[1] });
        for (t.effectsOf(hb.writes)) |e| _ = try Draft.addEffect(&d.writes, arena, e);
        for (t.effectsOf(hb.escapes)) |e| _ = try Draft.addEffect(&d.escapes, arena, e);
    }

    /// Tree `n` (its labels `map`ped) joined into a draft's base.
    fn mergeRes(t: *Table, gpa: Allocator, slots: *const Slots.Table, r: *Draft.Res, n: Node, map: []const u32) Error!void {
        var memo: Ids.FixedDict(2) = .{};
        defer memo.deinit(gpa);
        const m = try Forest.mapLabels(&t.trees, gpa, &memo, n, map, lessOf(slots));
        memo.clearRetainingCapacity();
        r.base = try Forest.unite(&t.trees, gpa, &memo, r.base, m, lessOf(slots), .join);
    }

    /// Equality of two committed contracts: their words (both canonical).
    pub fn eql(t: *const Table, a: Id, b: Id) bool {
        if (a == b) return true;
        const x = t.heads.items[a];
        const y = t.heads.items[b];
        if (x.arity != y.arity or @as(u8, @bitCast(x.flags)) != @as(u8, @bitCast(y.flags))) return false;
        if (!t.condEql(x.res_cond, y.res_cond) or !t.condEql(x.req, y.req)) return false;
        if (x.res_root != y.res_root) return false;
        if (!std.mem.eql([2]u32, t.readsOf(x.reads), t.readsOf(y.reads)) or !t.effectsEql(x.writes, y.writes) or !t.effectsEql(x.escapes, y.escapes)) return false;
        if (x.labels.len != y.labels.len) return false;
        for (t.labelsOf(x.labels), t.labelsOf(y.labels)) |p, q| {
            if (p.j != q.j or p.slot != q.slot or !std.mem.eql(u32, &p.origin, &q.origin) or p.calls != q.calls) return false;
            if (p.supplies.len != q.supplies.len) return false;
            for (t.suppliesOf(p.supplies), t.suppliesOf(q.supplies)) |s, u| {
                if (s.k != u.k or s.res_root != u.res_root or !t.effectsEql(s.kept, u.kept) or !t.condEql(s.cond, u.cond)) return false;
            }
        }
        return true;
    }

    fn condEql(t: *const Table, a: StoredCond, b: StoredCond) bool {
        return a.no == b.no and std.mem.eql(u64, t.occsOf(a), t.occsOf(b));
    }

    fn effectsEql(t: *const Table, a: Range, b: Range) bool {
        if (a.len != b.len) return false;
        for (t.effectsOf(a), t.effectsOf(b)) |x, y| if (x.j != y.j or x.slot != y.slot or x.deep != y.deep) return false;
        return true;
    }

    /// `within(got, claim)` (§2.10): `got` says no more than `claim`.
    pub fn within(t: *const Table, arena: Allocator, slots: *const Slots.Table, got: Id, claim: Id) Ids.IndexError!bool {
        const g = t.heads.items[got];
        const c = t.heads.items[claim];
        if (g.flags.returns and !c.flags.returns) return false;
        if (g.flags.once and !c.flags.once) return false;
        if (g.flags.returns and !c.res_cond.no) {
            if (!(try t.cond(arena, g.res_cond)).weakerIn(slots, try t.cond(arena, c.res_cond))) return false;
        }
        if (!(try t.cond(arena, g.req)).weakerIn(slots, try t.cond(arena, c.req))) return false;
        if (!try t.readsWithin(arena, g.reads, c.reads) or !t.effectsWithin(slots, g.writes, c.writes) or !t.effectsWithin(slots, g.escapes, c.escapes)) return false;
        const ids: [2]Id = .{ got, claim };
        // Labels by identity; `cb` arrivals compared through them.
        for (t.labelsOf(g.labels)) |l| {
            const m = t.findLabel(c, l) orelse return false;
            if (@backingInt(l.calls) > @backingInt(m.calls)) return false;
            for (t.suppliesOf(l.supplies)) |s| {
                const u = for (t.suppliesOf(m.supplies)) |u| {
                    if (u.k == s.k) break u;
                } else return false;
                if (!try t.treeWithin(arena, slots, ids, s.res_root, u.res_root)) return false;
                if (!t.effectsWithin(slots, s.kept, u.kept)) return false;
                if (!u.cond.no and !(try t.cond(arena, s.cond)).weakerIn(slots, try t.cond(arena, u.cond))) return false;
            }
        }
        return t.treeWithin(arena, slots, ids, g.res_root, c.res_root);
    }

    fn findLabel(t: *const Table, h: Head, l: Label) ?Label {
        for (t.labelsOf(h.labels)) |m| if (m.j == l.j and m.slot == l.slot and std.mem.eql(u32, &m.origin, &l.origin)) return m;
        return null;
    }

    /// Every effect of `a` is one of `b`'s, or below a deep one of `b`'s.
    fn effectsWithin(t: *const Table, slots: *const Slots.Table, a: Range, b: Range) bool {
        for (t.effectsOf(a)) |x| {
            const found = for (t.effectsOf(b)) |y| {
                if (x.j != y.j) continue;
                if (x.slot == y.slot and (!x.deep or y.deep)) break true;
                if (y.deep and continues(slots, y.slot, &.{}, x.slot, true)) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }

    /// Every arrival of tree `a` is one of `b`'s at its slot: of `b`'s run
    /// of the same kind there, or of an open node of `b` above it,
    /// continued by the steps between (an atom is the same at every slot
    /// below). A node of `a` is checked once per node of `b` its slot
    /// reaches with the same open nodes above it.
    fn treeWithin(t: *const Table, arena: Allocator, slots: *const Slots.Table, ids: [2]Id, a: Node, b: Node) Allocator.Error!bool {
        var path: std.ArrayList(u32) = .empty;
        var above: std.ArrayList([2]u32) = .empty;
        return t.nodeWithin(arena, slots, ids, a, b, &path, &above);
    }

    fn nodeWithin(t: *const Table, arena: Allocator, slots: *const Slots.Table, ids: [2]Id, a: Node, b: Node, path: *std.ArrayList(u32), above: *std.ArrayList([2]u32)) Allocator.Error!bool {
        if (a == 0) return true;
        const tr = &t.trees;
        for ([_]bool{ false, true }) |open| for (if (open) tr.open(a) else tr.here(a)) |p| {
            const found = blk: {
                // `b`'s runs at this slot: its plain one only for a plain arrival.
                if (!open) for (tr.here(b)) |q| if (t.arrivalHas(slots, ids, q, p, &.{})) break :blk true;
                for (tr.open(b)) |q| if (t.arrivalHas(slots, ids, q, p, &.{})) break :blk true;
                for (above.items) |ab| for (tr.open(ab[0])) |q| if (t.arrivalHas(slots, ids, q, p, path.items[ab[1]..])) break :blk true;
                break :blk false;
            };
            if (!found) return false;
        };
        const pushed = tr.open(b).len != 0;
        if (pushed) try above.append(arena, .{ b, @intCast(path.items.len) });
        defer if (pushed) {
            _ = above.pop();
        };
        for (tr.kids(a)) |k| {
            try path.append(arena, k[0]);
            defer _ = path.pop();
            if (!try t.nodeWithin(arena, slots, ids, k[1], tr.kidAt(b, k[0]) orelse 0, path, above)) return false;
        }
        return true;
    }

    /// Whether claim's arrival `q` holds `got`'s `p` once continued by `suffix`.
    fn arrivalHas(t: *const Table, slots: *const Slots.Table, ids: [2]Id, q: Arrival, p: Arrival, suffix: []const u32) bool {
        if (p.kind != q.kind) return false;
        switch (p.kind) {
            .fresh, .top => return true,
            .shared => return p.j == q.j and p.slot == q.slot,
            .cb => {
                const lp = t.labelAt(ids[0], p.j);
                const lq = t.labelAt(ids[1], q.j);
                return lp.j == lq.j and lp.slot == lq.slot and std.mem.eql(u32, &lp.origin, &lq.origin) and continues(slots, q.slot, suffix, p.slot, false);
            },
            .param => return p.j == q.j and (!p.deep or q.deep) and continues(slots, q.slot, suffix, p.slot, q.deep),
        }
    }

    /// Whether slot `p` is `q` continued by `suffix` (or below it, `deep`).
    fn continues(slots: *const Slots.Table, q: Rel, suffix: []const u32, p: Rel, deep: bool) bool {
        const qw = slots.relWords(q);
        const pw = slots.relWords(p);
        if (pw.len < qw.len or !std.mem.eql(u32, qw, pw[0..qw.len])) return false;
        if (deep) return true;
        return std.mem.eql(u32, pw[qw.len..], suffix);
    }
};

/// The canonical order of arrivals as a tree's comparator.
pub fn lessOf(slots: *const Slots.Table) Forest.Less {
    return .{ .ctx = slots, .lt = struct {
        fn lt(ctx: *const anyopaque, a: Arrival, b: Arrival) bool {
            return arrivalLess(@ptrCast(@alignCast(ctx)), a, b);
        }
    }.lt };
}

fn arrivalLess(slots: *const Slots.Table, a: Arrival, b: Arrival) bool {
    if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
    if (a.j != b.j) return a.j < b.j;
    if (a.deep != b.deep) return !a.deep;
    if (a.kind == .param) return slots.relLess(a.slot, b.slot);
    return a.slot < b.slot;
}

fn effectLess(slots: *const Slots.Table, a: Effect, b: Effect) bool {
    if (a.j != b.j) return a.j < b.j;
    return slots.relLess(a.slot, b.slot);
}

const testing = std.testing;

test "a join keeps every result slot of both sides" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var slots: Slots.Table = .{};
    defer slots.deinit(gpa);
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    var t: Table = .{};
    defer t.deinit(gpa);
    const r1 = try slots.relOfWords(gpa, &account, &places, &.{1});
    const r2 = try slots.relOfWords(gpa, &account, &places, &.{2});
    var da: Draft = .{ .arity = 1, .flags = .{ .returns = true } };
    _ = try Draft.addArrival(&da.res, arena, r1, .{ .kind = .param, .j = 0, .slot = r1 });
    var db: Draft = .{ .arity = 1, .flags = .{ .returns = true } };
    _ = try Draft.addArrival(&db.res, arena, r2, .{ .kind = .fresh });
    const a = try t.commit(gpa, &account, &slots, &da);
    const b = try t.commit(gpa, &account, &slots, &db);
    const j = try t.join(gpa, arena, &account, &slots, a, b);
    try testing.expectEqual(@as(u32, 2), t.trees.count(t.head(j).res_root));
    try testing.expect(try t.within(arena, &slots, a, j) and try t.within(arena, &slots, b, j) and !try t.within(arena, &slots, j, a));
}
