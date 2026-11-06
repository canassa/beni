//! L3: contracts (`docs/design/ownership-v2.md` §2.10, §3.5): what one
//! code (a declaration, a lambda, a local function, a constructor, a worded
//! row) does with its parameters, over slots. The module's contracts live
//! in one table of flat runs; a contract is a record of ranges, immutable
//! once committed. A join makes a new contract.
//!
//! Obligations kept here: none of §2.14's directly; `within` is §2.12's validation test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");
const Slots = @import("Slots.zig");
const Trees = @import("Trees.zig");
const Normal = @import("Normal.zig");
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
pub const fed_bit = Conds.fed_bit;
pub const occFed = Conds.occFed;
pub const isFed = Conds.isFed;
pub const fresh_arg = Conds.fresh_arg;
pub const fedParam = Conds.fedParam;
pub const fedArg = Conds.fedArg;
pub const weakest = Conds.weakest;
pub const sortOccs = Conds.sortOccs;

pub const ArrivalKind = Trees.ArrivalKind;
pub const Arrival = Trees.Arrival;

/// A read, write or escape (§2.10): parameter `j`'s slot, `deep` when it reaches every slot below.
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

/// A store a caller judges (§2.13.7, *The contents relation*): a value is
/// stored in the `◆` at parameter `j`'s `slot`, and what that cell holds
/// escapes at the call unless `cond` holds there.
pub const Store = struct { j: u32, slot: Rel, cond: StoredCond };

/// A callback label (§2.11.3): the function slot it calls, its origin
/// `(module, declaration, offset)`, how often, and its supplies.
pub const Label = struct {
    j: u32,
    slot: Rel,
    origin: [3]u32,
    calls: Calls = .none,
    /// The callee lets its answer go: a value that holds it escapes (§2.11.3).
    answer_left: bool = false,
    supplies: Range = .{},
};

pub const Calls = enum(u8) { none, once, many };

/// The high bit of a closure's `head`: a fixed contract, not a code.
pub const fixed_bit: u32 = 1 << 31;

/// What a call runs (`Context.callee`).
pub const Callee = union(enum) {
    /// The result and every argument cross: nothing to track.
    harmless,
    /// A constructor applied: `(ordinal, arity)`.
    ctor: [2]u32,
    /// A code of the module (`Groups`' numbering): its current contract.
    code: u32,
    /// A fixed contract: words, an import, a derived method, pessimistic.
    contract: Id,
    /// A function value: the head is evaluated.
    value,
    /// A record field of function type, `r.f x`: the receiver's field's value.
    field,
};

/// Marks a label origin's offset: a called code's last call (`Called`).
pub const last_origin: u32 = 1 << 29;

pub const Supply = struct {
    k: u32,
    /// `res` as a result tree (§2.10, *a contract is a tree of shared subtrees*): its root node.
    res_root: Node = 0,
    kept: Range,
    cond: StoredCond,
    /// What a write below the supply's root relies on: the callee's own
    /// claim about what it hands, derived from it (§2.11.3).
    below: StoredCond = .{},
    /// A traversal's (§2.11.3, *a traversal's supply*): each run is handed
    /// one element of one family, each position at most once, and the
    /// callee holds none of it after the run.
    each: bool = false,
    /// `each`, and the callee reads the family only to hand it over: every
    /// source is a `taken` row's, by the index obligation (§2.13.6).
    walk: bool = false,
};

pub const Flags = packed struct(u8) {
    returns: bool = false,
    cross: bool = false,
    once: bool = false,
    words: bool = false,
    pessimistic: bool = false,
    /// A `taken` result (§2.13.6, `traverseAt`): one element of parameter
    /// 1, read through the certified traversal, so a holder of that
    /// container holds the others for the rest of the frame (§2.11.3).
    taken: bool = false,
    /// A traversal's element, at some level, is written where it reaches a
    /// parameter (§2.11.3, *a taken supply*): no `entry` caller judges that.
    taken_write: bool = false,
    /// An argument's function values run as `entry` functions (`EntryHeld`).
    entry: bool = false,
};

pub const Head = struct {
    arity: u32,
    flags: Flags,
    /// `res` as a result tree: its root node.
    res_root: Node = 0,
    res_cond: StoredCond = .{},
    /// Where `res_cond` is `no`, the result's separation with its labels' answers read (§2.11.3, *a traversal's supply*).
    res_read: StoredCond = .{ .no = true },
    /// One tree a parameter (`Table.readsOf`).
    reads: Range = .{},
    /// One tree a parameter, as the reads (`Table.writesOf`, §2.11.2 *A
    /// write onto a caller's parameter stops at the parameter*): a plain
    /// mark writes its slot, an open one every slot at and below it.
    writes: Range = .{},
    req: StoredCond = .{},
    escapes: Range = .{},
    stores: Range = .{},
    labels: Range = .{},
};

/// A contract being built: plain lists, committed into the table at once.
pub const Draft = struct {
    arity: u32,
    flags: Flags = .{},
    res: Res = .{},
    res_cond: Cond = .{},
    res_read: Cond = .unprovable,
    reads: std.ArrayList(Effect) = .empty,
    writes: std.ArrayList(Effect) = .empty,
    req: Cond = .{},
    escapes: std.ArrayList(Effect) = .empty,
    stores: std.ArrayList(DraftStore) = .empty,
    labels: std.ArrayList(DraftLabel) = .empty,

    pub const DraftStore = struct { j: u32, slot: Rel, cond: Cond };

    /// A store into the cell at `(j, slot)`, which asks every condition stored there.
    pub fn addStore(d: *Draft, arena: Allocator, account: *Ids.Account, s: DraftStore) Error!void {
        for (d.stores.items) |*x| if (x.j == s.j and x.slot == s.slot) {
            x.cond = try Cond.conj(arena, account, x.cond, s.cond);
            return;
        };
        try d.stores.append(arena, s);
    }

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
        answer_left: bool = false,
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
        below: Cond = .{},
        each: bool = false,
        walk: bool = false,
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
    stores: std.ArrayList(Store) = .empty,
    /// The reads and the writes: `(j, tree)` a parameter.
    eroots: std.ArrayList([2]u32) = .empty,
    occs: std.ArrayList(u64) = .empty,
    labels: std.ArrayList(Label) = .empty,
    supplies: std.ArrayList(Supply) = .empty,
    /// `res` and supplies' `res` as result trees (§2.10), by node.
    trees: Trees.Table = .{},
    /// Per `(contract, function slot of its result)`: its called contract
    /// (§2.11.3), and per contract its run of `(slot, called contract)`.
    called: Ids.FixedDict(2) = .{},
    called_list: std.ArrayList([2]u32) = .empty,
    called_runs: Ids.FixedDict(1) = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.trees.deinit(gpa);
        t.called.deinit(gpa);
        t.called_list.deinit(gpa);
        t.called_runs.deinit(gpa);
        t.heads.deinit(gpa);
        t.effects.deinit(gpa);
        t.stores.deinit(gpa);
        t.eroots.deinit(gpa);
        t.occs.deinit(gpa);
        t.labels.deinit(gpa);
        t.supplies.deinit(gpa);
    }

    pub fn head(t: *const Table, c: Id) Head {
        return t.heads.items[c];
    }
    /// Code `c`'s result separation; `read`: with its labels' answers read.
    pub fn resCond(t: *const Table, arena: Allocator, c: Id, read: bool) Allocator.Error!Cond {
        const h = t.heads.items[c];
        return t.cond(arena, if (read and h.res_cond.no) h.res_read else h.res_cond);
    }
    pub fn calledOf(t: *const Table, c: Id, rel: Rel) ?Id {
        return t.called.get(.{ c, rel });
    }
    /// A contract's called contracts are put one after another.
    pub fn putCalled(t: *Table, gpa: Allocator, c: Id, rel: Rel, called: Id) Ids.IndexError!void {
        try t.called.put(gpa, .{ c, rel }, called);
        const got = try t.called_runs.getOrPut(gpa, .{c});
        if (!got.found_existing) got.value_ptr.* = @intCast(t.called_list.items.len << 8);
        got.value_ptr.* += 1;
        try t.called_list.append(gpa, .{ rel, called });
    }
    pub fn calledRun(t: *const Table, c: Id) []const [2]u32 {
        const x = t.called_runs.get(.{c}) orelse return &.{};
        return t.called_list.items[x >> 8 ..][0 .. x & 0xff];
    }
    /// The parameter whose whole subtree `c`'s result is, at its own path,
    /// when `c` writes nothing of it (§2.11.2, *the identity control*).
    pub fn identityOf(t: *const Table, c: Id) ?u32 {
        const h = t.heads.items[c];
        if (!h.flags.returns or h.flags.cross) return null;
        const j = t.trees.identity(h.res_root) orelse return null;
        for (t.writesOf(h.writes)) |x| if (x[0] == j) return null;
        return j;
    }
    /// Whether code `c` returns and its result holds no object (`Dict.empty`).
    pub fn holdsNothing(t: *const Table, c: Id) bool {
        const h = t.head(c);
        return h.flags.returns and !h.flags.pessimistic and h.res_root == 0;
    }
    pub fn storesOf(t: *const Table, r: Range) []const Store {
        return t.stores.items[r.start..][0..r.len];
    }
    pub fn effectsOf(t: *const Table, r: Range) []const Effect {
        return t.effects.items[r.start..][0..r.len];
    }
    pub fn readsOf(t: *const Table, r: Range) []const [2]u32 {
        return t.eroots.items[r.start..][0..r.len];
    }
    pub fn writesOf(t: *const Table, r: Range) []const [2]u32 {
        return t.eroots.items[r.start..][0..r.len];
    }

    /// Write trees `r` written out as effects, in the canonical order
    /// (§2.10): for the readers that take a write a slot at a time. `gpa`
    /// grows the slot table, `list` the list `out`.
    pub fn writesFlat(t: *const Table, gpa: Allocator, list: Allocator, account: *Ids.Account, slots: *Slots.Table, places: *const Place.Table, r: Range, out: *std.ArrayList(Effect)) Ids.ChargeError!void {
        for (t.writesOf(r)) |x| try t.effectFlat(gpa, list, account, slots, places, .{ .j = x[0], .slot = Slots.root, .node = x[1] }, out);
    }

    /// One draft write written out: a plain one is itself; one with a tree
    /// is each entry of the tree below its slot.
    pub fn effectFlat(t: *const Table, gpa: Allocator, list: Allocator, account: *Ids.Account, slots: *Slots.Table, places: *const Place.Table, x: Effect, out: *std.ArrayList(Effect)) Ids.ChargeError!void {
        if (x.node == 0) return out.append(list, x);
        var es: Forest.Entries = .{};
        defer es.deinit(gpa);
        try es.of(&t.trees, gpa, places, x.node, slots.relWords(x.slot));
        for (es.items.items) |y| try out.append(list, .{ .j = x.j, .slot = try slots.relOfWords(gpa, account, places, es.wordsOf(y)), .deep = y.open });
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
                if (!SlotWords.startsAt(xw, yw)) continue;
                if (xw.len == yw.len and isDeep(x) and (isApart(x) == isApart(y))) continue;
                continue :outer;
            }
            try t.occs.append(gpa, x);
        }
        const run = t.occs.items[start..];
        sortOccs(slots, run);
        return .{ .run = .{ .start = start, .len = @intCast(run.len) } };
    }

    /// A draft's stores, by cell in the canonical order (§2.10).
    fn putStores(t: *Table, gpa: Allocator, slots: *const Slots.Table, list: []Draft.DraftStore) Allocator.Error!Range {
        std.mem.sort(Draft.DraftStore, list, slots, struct {
            fn lt(sl: *const Slots.Table, a: Draft.DraftStore, b: Draft.DraftStore) bool {
                return if (a.j != b.j) a.j < b.j else sl.relOrder(a.slot, b.slot) == .lt;
            }
        }.lt);
        const start: u32 = @intCast(t.stores.items.len);
        for (list) |s| {
            const c = try t.putCond(gpa, slots, s.cond);
            try t.stores.append(gpa, .{ .j = s.j, .slot = s.slot, .cond = c });
        }
        return .{ .start = start, .len = @intCast(t.stores.items.len - start) };
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

    // ---- result trees (§2.10, *a contract is a tree of shared subtrees*) ---

    const Flat = struct { slot: Rel, open: bool, a: Arrival };

    /// The tree of a draft's result, its `cb` arrivals renumbered by
    /// `rank`: its arrivals as entries (sorted by their slots' canonical
    /// keys, a plain run before an open one), its subtrees and its base joined in.
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
        // One normal form (§2.11.2): what an open arrival above says by structure is not said again.
        var kept: usize = 0;
        for (flat.items[0..m]) |x| if (!Normal.saidAbove(slots, flat.items[0..m], x)) {
            flat.items[kept] = x;
            kept += 1;
        };
        var root = try t.treeOf(gpa, slots, flat.items[0..kept], 0);
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
            root = try Forest.unite(&t.trees, gpa, &memo, root, try Forest.graft(&t.trees, gpa, slots.relWords(e.slot), n), less);
        };
        if (r.base != 0) {
            memo.clearRetainingCapacity();
            const b = if (ident) r.base else try Forest.mapLabels(&t.trees, gpa, &memo, r.base, rank, less);
            memo.clearRetainingCapacity();
            root = try Forest.unite(&t.trees, gpa, &memo, b, root, less);
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
        h.res_read = try t.putCond(gpa, slots, if (d.res_cond.no) d.res_read else Cond.unprovable);
        h.reads = try t.putReads(gpa, slots, d.reads.items);
        h.writes = try t.putReads(gpa, slots, d.writes.items);
        h.req = try t.putCond(gpa, slots, d.req);
        h.escapes = try t.putEffects(gpa, slots, d.escapes.items);
        h.stores = try t.putStores(gpa, slots, d.stores.items);
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
                try made.append(gpa, .{ .k = s.k, .res_root = try t.putRes(gpa, slots, &s.res, rank), .kept = try t.putEffects(gpa, slots, s.kept.items), .cond = try t.putCond(gpa, slots, s.cond), .below = try t.putCond(gpa, slots, s.below), .each = s.each, .walk = s.walk });
            }
            try t.supplies.appendSlice(gpa, made.items);
            try t.labels.append(gpa, .{ .j = l.j, .slot = l.slot, .origin = l.origin, .calls = l.calls, .answer_left = l.answer_left, .supplies = .{ .start = sstart, .len = @intCast(made.items.len) } });
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
        d.res_read = try t.cond(arena, h.res_read);
        for (t.readsOf(h.reads)) |x| try d.reads.append(arena, .{ .j = x[0], .slot = Slots.root, .node = x[1] });
        for (t.writesOf(h.writes)) |x| try d.writes.append(arena, .{ .j = x[0], .slot = Slots.root, .node = x[1] });
        d.req = try t.cond(arena, h.req);
        try d.escapes.appendSlice(arena, t.effectsOf(h.escapes));
        for (t.storesOf(h.stores)) |s| try d.stores.append(arena, .{ .j = s.j, .slot = s.slot, .cond = try t.cond(arena, s.cond) });
        for (t.labelsOf(h.labels)) |l| {
            var dl: Draft.DraftLabel = .{ .j = l.j, .slot = l.slot, .origin = l.origin, .calls = l.calls, .answer_left = l.answer_left };
            for (t.suppliesOf(l.supplies)) |s| {
                var ds: Draft.DraftSupply = .{ .k = s.k, .cond = try t.cond(arena, s.cond), .below = try t.cond(arena, s.below), .each = s.each, .walk = s.walk };
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
        d.flags.taken_write = d.flags.taken_write or hb.flags.taken_write;
        d.flags.entry = d.flags.entry or hb.flags.entry;
        // A side that does not return says nothing of the result's condition.
        const bc = try t.cond(arena, hb.res_cond);
        const br = try t.resCond(arena, b, true);
        const dr = if (d.res_cond.no) d.res_read else d.res_cond;
        if (!a_returns) d.res_cond = bc else if (b_returns) d.res_cond = try weakest(arena, account, d.res_cond, bc);
        d.res_read = if (!a_returns) br else if (b_returns) try weakest(arena, account, dr, br) else dr;
        d.req = try Cond.conj(arena, account, d.req, try t.cond(arena, hb.req));
        // Labels of `b`, matched to `d`'s by (j, slot, origin): `b`'s index → `d`'s.
        const map = try arena.alloc(u32, hb.labels.len);
        for (t.labelsOf(hb.labels), 0..) |l, i| map[i] = try d.labelOf(arena, l.j, l.slot, l.origin);
        for (t.labelsOf(hb.labels), 0..) |l, i| {
            const at = map[i];
            const dl = &d.labels.items[at];
            dl.calls = @fromBackingInt(@intCast(@max(@backingInt(dl.calls), @backingInt(l.calls))));
            dl.answer_left = dl.answer_left or l.answer_left;
            for (t.suppliesOf(l.supplies)) |s| {
                const had = for (dl.supplies.items) |x| {
                    if (x.k == s.k) break true;
                } else false;
                const ds = try dl.supplyOf(arena, s.k);
                ds.each = s.each and (ds.each or !had);
                ds.walk = s.walk and (ds.walk or !had);
                try t.mergeRes(gpa, slots, &ds.res, s.res_root, map);
                for (t.effectsOf(s.kept)) |e| _ = try Draft.addEffect(&ds.kept, arena, e);
                ds.cond = try weakest(arena, account, ds.cond, try t.cond(arena, s.cond));
                ds.below = try weakest(arena, account, ds.below, try t.cond(arena, s.below));
            }
        }
        try t.mergeRes(gpa, slots, &d.res, hb.res_root, map);
        for (t.readsOf(hb.reads)) |x| _ = try Draft.addEffect(&d.reads, arena, .{ .j = x[0], .slot = Slots.root, .node = x[1] });
        for (t.writesOf(hb.writes)) |x| _ = try Draft.addEffect(&d.writes, arena, .{ .j = x[0], .slot = Slots.root, .node = x[1] });
        for (t.effectsOf(hb.escapes)) |e| _ = try Draft.addEffect(&d.escapes, arena, e);
        for (t.storesOf(hb.stores)) |s| try d.addStore(arena, account, .{ .j = s.j, .slot = s.slot, .cond = try t.cond(arena, s.cond) });
    }

    /// Tree `n` (its labels `map`ped) joined into a draft's base.
    fn mergeRes(t: *Table, gpa: Allocator, slots: *const Slots.Table, r: *Draft.Res, n: Node, map: []const u32) Error!void {
        var memo: Ids.FixedDict(2) = .{};
        defer memo.deinit(gpa);
        const m = try Forest.mapLabels(&t.trees, gpa, &memo, n, map, lessOf(slots));
        memo.clearRetainingCapacity();
        r.base = try Forest.unite(&t.trees, gpa, &memo, r.base, m, lessOf(slots));
    }

    /// Equality of two committed contracts: their words (both canonical).
    pub fn eql(t: *const Table, a: Id, b: Id) bool {
        if (a == b) return true;
        const x = t.heads.items[a];
        const y = t.heads.items[b];
        if (x.arity != y.arity or @as(u8, @bitCast(x.flags)) != @as(u8, @bitCast(y.flags))) return false;
        if (!t.condEql(x.res_cond, y.res_cond) or !t.condEql(x.res_read, y.res_read) or !t.condEql(x.req, y.req)) return false;
        if (x.res_root != y.res_root) return false;
        if (!std.mem.eql([2]u32, t.readsOf(x.reads), t.readsOf(y.reads)) or !std.mem.eql([2]u32, t.writesOf(x.writes), t.writesOf(y.writes)) or !t.effectsEql(x.escapes, y.escapes)) return false;
        if (x.stores.len != y.stores.len or x.labels.len != y.labels.len) return false;
        for (t.storesOf(x.stores), t.storesOf(y.stores)) |p, q| if (p.j != q.j or p.slot != q.slot or !t.condEql(p.cond, q.cond)) return false;
        for (t.labelsOf(x.labels), t.labelsOf(y.labels)) |p, q| {
            if (p.j != q.j or p.slot != q.slot or !std.mem.eql(u32, &p.origin, &q.origin) or p.calls != q.calls or p.answer_left != q.answer_left) return false;
            if (p.supplies.len != q.supplies.len) return false;
            for (t.suppliesOf(p.supplies), t.suppliesOf(q.supplies)) |s, u| {
                if (s.each != u.each or s.walk != u.walk or !t.condEql(s.below, u.below)) return false;
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

    /// Whether slot `p` is `q` continued by `suffix` (or below it, `deep`).
    pub fn continues(slots: *const Slots.Table, q: Rel, suffix: []const u32, p: Rel, deep: bool) bool {
        const qw = slots.relWords(q);
        const pw = slots.relWords(p);
        if (!SlotWords.startsAt(pw, qw)) return false;
        if (deep) return true;
        return SlotWords.same(pw[qw.len..], suffix);
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
    if (a.kind == .param or a.kind == .cb) return slots.relLess(a.slot, b.slot);
    return a.slot < b.slot;
}

fn effectLess(slots: *const Slots.Table, a: Effect, b: Effect) bool {
    if (a.j != b.j) return a.j < b.j;
    return slots.relLess(a.slot, b.slot);
}

const testing = std.testing;
