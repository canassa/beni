//! L11: the ownership block (`docs/design/ownership-v2.md` §3.6), minimal:
//! classes to words and back, with places written structurally. S2b builds
//! the class table and its records, written here — a header (`OWN2`, the version), the
//! place table, the record table, the root classes — and nothing of S6's:
//! no lazy directory, no cache section, no traversal marks.
//!
//! **Positions, with the κ they read.** A class means κ as READ (§2.9: the
//! stored κ joined with the κ derived at the position). So the block's node
//! records are POSITIONS — a node, its position class (`at_summary`) and
//! its owner's map (one owner per hash-consed map; a use shape is no value
//! and carries none) — each with the κ read there (a union's or a positions
//! node's: what is stored there, as its sides are read with it), its node's
//! parts, and the positions `proj` makes that its structure does not name.
//! An `owner` record names every value under one map, and the reader builds
//! that one map for all of them. The set is closed by construction
//! (`entries`): the owner's values, their
//! parts, and every stored entry a read can reach with the
//! projections that lead to it. The reader stores exactly that κ at exactly
//! those positions, so every read of the decoded class is the written one's.
//!
//! **Every record once.** A label, a path, a cell, a split, a cell set, an
//! atom set, a condition, an atom, a position, an owner, a supply, a keep, a slot and
//! a class are each one record, named by its ordinal everywhere else. A
//! record follows its parts, but in a knot: the positions of a cycle are
//! one `group` record whose members are numbered together, so a child step
//! (and a projected position) may name any member and every other part
//! names an earlier one — every cycle the constructors make passes through
//! a child step.
//!
//! **No session id in the bytes.** A place is its kind, its head and its
//! children (a head, a field's rank — a use mark's too — through the
//! writer's `Names`), a shared value's declaration its qualified name and
//! ordinal. Instruction ids (a label's, a site's) are the module's own, and
//! a reader puts them in a namespace of its own (`Remap.inst`).
//!
//! **The order is the structure's, and no hash reaches it** (`canon`).
//! Every key is exact and ordered by its words (`Refine.rank`, a merge
//! sort). The places the records name, closed under their children, are
//! refined once as one graph (`Refine.blocks`), so a place's rank is its
//! structure's and every key that names it shares it: no place is encoded
//! once per key. The records no position reaches are then ranked a height
//! at a time, each naming its parts by their keys; the positions — the only
//! records that make cycles — are refined from their own words, a port per
//! labelled part (a union's two sides a count, not an order); and the
//! owners, supplies and classes that name positions are ranked last, by
//! height. Refinement numbers its quotient, so two positions are one key
//! exactly when they are bisimilar with equal κ everywhere, and a copy of a
//! value outside its knot changes no number. Records of one key are written
//! as the first of them, and no two units spell the same words (`distinct`,
//! a sort). The table is then a post-order walk from the classes, a set's
//! parts in key order: ordinals, place numbers and bytes follow from the
//! quotient alone, and write ∘ read ∘ write is write.
//!
//! **Reading** is `BlockRead`'s, one layer up (§5): this file holds the
//! format both sides share.
//!
//! **Cost** (§4.1, §4.4). The codec's work — every lookup, token, scan,
//! sort and output word — is reserved before it is done on the codec's lane
//! (`Refine.Meter`): baseline records, bounded by `Refine.codecBound` of the
//! records and edges the writer reads, never the owner's growth allowance;
//! past the bound is `ownership_accounting_invariant`. Nothing reaches `out`
//! before all of it is paid; the κ reads and projections it makes run on
//! the lane too (`codecAccount`). Growth is only a class's own summary: the
//! positions it reaches past one per node (a node under a second κ map,
//! §3.6), counted as if the class were alone, on its declaration's charge
//! (`Options.charges`). With R records and E their tokens, V and A
//! the positions and their position parts, Q and T the places and their
//! steps: describing is O(R + E) plus the κ reads; ranking is
//! O((E + R) log R); the refinements are O((V + A) log V) and
//! O((Q + T) log Q); writing is O(E) plus each set's sort.
//!
//! Obligations kept here: none (a faithful encoding: every κ read of what
//! is read is the κ read of what was written).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Refine = @import("Refine.zig");

pub const ClassId = Ids.ClassId;
pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const CondId = Ids.CondId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const LabelId = Ids.LabelId;
pub const Step = Place.Step;
pub const Env = Summary.Env;
pub const Error = Ids.ChargeError;
pub const ReadError = Error || error{BlockConflict};

/// `"OWN2"`, little-endian.
pub const magic: u32 = 0x324e574f;
/// The minimal block's format. S6's directory and traversal marks bump it.
/// 7: a position's κ is what is stored there, never the read (#1069).
/// 8: a position records what its snapshot is there, so the trie is rebuilt (#1073).
/// 9: a fold is exact or collapsed, and keeps the steps it saw (#1113's review).
pub const version: u32 = 9;

pub const none: u32 = Ids.none_int;

/// A record's kind, which is its tag in the table; `group` opens a knot.
/// A `node` record is a position.
pub const Kind = enum(u8) { label, path, cell, split, set, atoms, cond, atom, node, owner, supply, keep, slot, class, group, back };

/// How the writer names what no session id may spell (§3.6).
pub const Names = struct {
    /// Heads and field ranks, the places' and a use mark's.
    place: Place.Names,
    ctx: *anyopaque,
    /// A `shared` cell's declaration: its qualified name (a string-table
    /// number) and its canonical ordinal.
    decl: *const fn (ctx: *anyopaque, index: u32) [2]u32,

    pub const identity: Names = .{ .place = .identity, .ctx = undefined, .decl = sameDecl };
    fn sameDecl(_: *anyopaque, index: u32) [2]u32 {
        return .{ index, 0 };
    }
};

/// The reader's inverse of `Names`, and its namespace for the block's
/// instruction ids.
pub const Remap = struct {
    place: Place.Remap,
    ctx: *anyopaque,
    /// A written declaration back to this session's index; null when the
    /// session has no such declaration (the block does not decode).
    decl: *const fn (ctx: *anyopaque, name: u32, ordinal: u32) ?u32,
    /// The block's instruction id in the reader's namespace for it, so a
    /// label or a site of another module never meets one of the reader's.
    inst: *const fn (ctx: *anyopaque, inst: u32) u32,

    pub const identity: Remap = .{ .place = .identity, .ctx = undefined, .decl = sameDecl, .inst = sameInst };
    fn sameDecl(_: *anyopaque, name: u32, ordinal: u32) ?u32 {
        return if (ordinal == 0) name else null;
    }
    fn sameInst(_: *anyopaque, inst: u32) u32 {
        return inst;
    }
};

pub const sortCost = Refine.sortCost;
pub const codecBound = Refine.codecBound;

/// What a scan of `n` tokens is charged: two words each, 16 to a record.
fn scan(n: usize) u64 {
    return Refine.wordsCost(2 * n);
}

/// The position class of the child at `s` of a position of class `summary`.
pub fn below(summary: bool, s: Step) bool {
    return summary or s.kind == .elem or s.kind == .level;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// How a block is written.
pub const Options = struct {
    /// Each class's owning declaration's charge, one per class: the growth
    /// its own positions add (`classGrowth`) is its declaration's. Null:
    /// `env.charge` for all.
    charges: ?[]const Ids.Charge = null,
    /// The codec lane's bound in place of `Refine.codecBound` (a test's).
    codec_cap: ?u64 = null,
};

/// Write `classes` as one block: header, place table, records, roots.
pub fn write(env: Env, sums: *Summary.Table, classes: []const ClassId, names: Names, out: *std.ArrayList(u32)) Error!void {
    return writeWith(env, sums, classes, names, out, .{});
}

/// `write`, the codec's records on its lane (§4.1): baseline in
/// `env.charge`'s account, bounded by the block's size, and only the
/// growth a class's own positions add on its declaration's charge.
pub fn writeWith(env: Env, sums: *Summary.Table, classes: []const ClassId, names: Names, out: *std.ArrayList(u32), options: Options) Error!void {
    const gpa = env.gpa;
    if (options.charges) |cs| std.debug.assert(cs.len == classes.len);
    var w: Writer = .{ .env = env, .sums = sums, .names = names, .charges = options.charges, .meter = .{ .gpa = gpa, .account = env.charge.account, .cap = options.codec_cap } };
    defer w.deinit();
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);
    // Every owner and its values before the positions they reach.
    var later: std.ArrayList(u32) = .empty;
    defer later.deinit(gpa);
    for (classes) |c| {
        try roots.append(gpa, try w.rec(.class, c.int()));
        while (w.pending.pop()) |r| if (w.recs.items[r].kind == .node or w.recs.items[r].kind == .owner) try later.append(gpa, r) else try w.describe(r);
    }
    for (0..w.owners.items.len) |o| try w.entries(@intCast(o));
    try w.pending.appendSlice(gpa, later.items);
    while (w.pending.pop()) |r| try w.describe(r);
    try w.classGrowth(roots.items);
    try w.canon();
    try w.components();
    for (roots.items) |r| try w.emitFrom(w.recs.items[r].scc);
    try w.check();
    try w.distinct();
    // The places the records named, closed under their children, one per
    // rank, each record `kind, head, holds, n, (step…, child)×n`.
    var places: std.ArrayList(u32) = .empty;
    defer places.deinit(gpa);
    var at: usize = 0;
    while (at < w.place_order.items.len) : (at += 1) {
        const p = w.place_order.items[at];
        const k = env.places.kind(p);
        const steps = env.places.steps(p);
        try w.meter.take(1 + steps.steps.len);
        try places.appendSlice(gpa, &.{ @backingInt(k), if (k == .tuple or k == .record) env.places.head(p) else names.place.head(names.place.ctx, env.places.head(p)), env.places.holds(p).bits(), @intCast(steps.steps.len) });
        for (steps.steps, steps.children) |s, child| {
            try w.stepWords(s, &places);
            try places.append(gpa, try w.placeLocal(child));
        }
    }
    // Nothing reaches `out` before all of it is paid for.
    try w.meter.take(Refine.wordsCost(5 + places.items.len + w.out.items.len + roots.items.len));
    try out.ensureUnusedCapacity(gpa, 5 + places.items.len + w.out.items.len + roots.items.len);
    out.appendSliceAssumeCapacity(&.{ magic, version, @intCast(w.place_order.items.len) });
    out.appendSliceAssumeCapacity(places.items);
    out.appendAssumeCapacity(w.units);
    out.appendSliceAssumeCapacity(w.out.items);
    out.appendAssumeCapacity(@intCast(roots.items.len));
    for (roots.items) |r| out.appendAssumeCapacity(w.ordinalOf(r));
}

/// One word of a record's description: a word as written, a place (its
/// local number in the block, its rank in the key), a part (`ref`, or
/// `knot` for a child step or a projected position, which may name its own
/// knot), or the count of the unordered parts that follow.
const Tok = struct { tag: enum(u8) { word, place, ref, knot, group }, x: u32 };

const Rec = struct {
    kind: Kind,
    /// The table id; for a position, a supply, a keep or a slot the index
    /// of `positions` or `extras`.
    id: u32,
    toks: u32 = 0,
    len: u32 = 0,
    /// The record's key from `canon`: canonical, and equal exactly when
    /// two records are the same structure.
    key: u32 = 0,
    scc: u32 = none,
    /// The record it is written as: its block's first member.
    rep: u32,
    ordinal: u32 = none,
};

/// A node read at a position class under an owner's κ map.
/// `cursor` is the node's position in the owner's snapshot (§3.6).
const Position = struct { node: NodeId, at_summary: bool, owner: u32, cursor: Cond.Kappas };

const Extra = union(enum) {
    supply: Summary.Supply,
    keep: Summary.Keep,
    slot: Summary.Slot,
    back: Summary.Back,
};

/// A strongly connected component of the written records: one record, or a
/// knot of positions.
const Scc = struct { first: u32, len: u32, knot: bool, state: enum(u8) { new, open, done } = .new };

const Writer = struct {
    env: Env,
    sums: *Summary.Table,
    names: Names,
    meter: Refine.Meter,
    /// Tokens reserved and not yet written.
    tok_credit: u8 = 0,
    recs: std.ArrayList(Rec) = .empty,
    /// `(kind, table id)` → record.
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// `(node, position class, owner, cursor)` → position record.
    pos_index: Ids.FixedDict(4) = .{},
    positions: std.ArrayList(Position) = .empty,
    /// Each owner's κ map (null: the use shapes, whose cells are marks and
    /// carry no κ), one owner per map, and the values it holds.
    owners: std.ArrayList(?Cond.Kappas) = .empty,
    owner_index: Ids.FixedDict(1) = .{},
    roots: std.ArrayList(std.ArrayList(NodeId)) = .empty,
    /// `(node, class, owner, cursor)` → the projections a stored κ beyond
    /// the structure needs written (`entries`).
    extra_index: Ids.FixedDict(4) = .{},
    extras_made: std.ArrayList(std.ArrayList(Step)) = .empty,
    toks: std.ArrayList(Tok) = .empty,
    extras: std.ArrayList(Extra) = .empty,
    pending: std.ArrayList(u32) = .empty,
    sccs: std.ArrayList(Scc) = .empty,
    /// The members of each component, a knot's in its written order.
    members: std.ArrayList(u32) = .empty,
    /// The places the records name, closed under their children (place →
    /// its index), and each one's rank (`canon`).
    place_state: Ids.FixedDict(1) = .{},
    place_list: std.ArrayList(PlaceId) = .empty,
    place_rank: std.ArrayList(u32) = .empty,
    /// A position record's state in `refinePositions`.
    state_of: std.ArrayList(u32) = .empty,
    /// A rank → its local number, and the place written for each number.
    place_local: Ids.FixedDict(1) = .{},
    place_order: std.ArrayList(PlaceId) = .empty,
    /// The record table as written, and how many records and knots.
    out: std.ArrayList(u32) = .empty,
    units: u32 = 0,
    next: u32 = 0,
    /// A record's words (a knot's, its members' relative) → its ordinal.
    /// Each unit's words as `emit` checks them (a knot's members relative),
    /// and where each starts: no two may be equal (`distinct`).
    rel_out: std.ArrayList(u32) = .empty,
    rel_starts: std.ArrayList(u32) = .empty,
    /// Each class's declaration's charge (`Options.charges`).
    charges: ?[]const Ids.Charge,
    /// The codec's κ reads and projections run on this (`codecAccount`).
    codec: Ids.Account = .{},

    fn deinit(w: *Writer) void {
        const gpa = w.env.gpa;
        w.recs.deinit(gpa);
        w.index.deinit(gpa);
        w.pos_index.deinit(gpa);
        w.positions.deinit(gpa);
        w.owners.deinit(gpa);
        w.owner_index.deinit(gpa);
        for (w.roots.items) |*l| l.deinit(gpa);
        w.roots.deinit(gpa);
        w.extra_index.deinit(gpa);
        for (w.extras_made.items) |*l| l.deinit(gpa);
        w.extras_made.deinit(gpa);
        w.toks.deinit(gpa);
        w.extras.deinit(gpa);
        w.pending.deinit(gpa);
        w.sccs.deinit(gpa);
        w.members.deinit(gpa);
        w.place_state.deinit(gpa);
        w.place_list.deinit(gpa);
        w.place_rank.deinit(gpa);
        w.state_of.deinit(gpa);
        w.place_local.deinit(gpa);
        w.place_order.deinit(gpa);
        w.out.deinit(gpa);
        w.rel_out.deinit(gpa);
        w.rel_starts.deinit(gpa);
        w.codec.deinit(gpa);
    }

    /// Reserve `n` records and do them at once.
    fn take(w: *Writer, n: u64) Error!void {
        return w.meter.take(n);
    }

    /// Place `p`'s local number: one per rank, in the order first named.
    fn placeLocal(w: *Writer, p: PlaceId) Error!u32 {
        try w.take(1);
        const r = w.place_rank.items[w.place_state.get(.{p.int()}).?];
        const got = try w.place_local.getOrPut(w.env.gpa, .{r});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(w.place_order.items.len);
            try w.place_order.append(w.env.gpa, p);
        }
        return got.value_ptr.*;
    }

    /// `p` among the places `canon` refines.
    fn placeState(w: *Writer, p: PlaceId) Error!void {
        try w.take(1);
        const got = try w.place_state.getOrPut(w.env.gpa, .{p.int()});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(w.place_list.items.len);
            w.meter.grow(1 + w.env.places.steps(p).steps.len);
            try w.place_list.append(w.env.gpa, p);
        }
    }

    // ---- describing ------------------------------------------------------------

    /// The record of table id `id` of `kind`, made and queued on first
    /// sight; `none` for no record. The lookup is reserved, hit or miss.
    fn rec(w: *Writer, kind: Kind, id: u32) Error!u32 {
        if (id == none) return none;
        try w.take(1);
        const got = try w.index.getOrPut(w.env.gpa, (@as(u64, @backingInt(kind)) << 32) | id);
        if (!got.found_existing) got.value_ptr.* = try w.fresh(kind, id);
        return got.value_ptr.*;
    }

    /// The position of `n` at class `at_summary` under owner `owner`, at
    /// `cursor` in its snapshot.
    fn pos(w: *Writer, n: NodeId, at_summary: bool, who: u32, cursor: Cond.Kappas) Error!u32 {
        if (n == .none) return none;
        try w.take(2);
        if (w.pos_index.get(.{ n.int(), @intFromBool(at_summary), who, cursor.int() })) |r| return r;
        try w.positions.append(w.env.gpa, .{ .node = n, .at_summary = at_summary, .owner = who, .cursor = cursor });
        const r = try w.fresh(.node, @intCast(w.positions.items.len - 1));
        (try w.pos_index.getOrPut(w.env.gpa, .{ n.int(), @intFromBool(at_summary), who, cursor.int() })).value_ptr.* = r;
        return r;
    }

    /// Owner `o`'s snapshot root (`.none` for the use shapes).
    fn rootOf(w: *Writer, o: u32) Cond.Kappas {
        return w.owners.items[o] orelse .none;
    }

    // ---- the codec's table reads -------------------------------------------------
    /// The codec broke its own bound or shape: `ownership_accounting_invariant`
    /// on the account, as `Meter.pay` records it.
    fn invariant(w: *Writer) Error {
        if (w.meter.account.failed == null) w.meter.account.failed = .{ .invariant = Refine.codec_lane };
        return error.AccountingInvariant;
    }

    /// The account the codec's κ reads and projections run on: its
    /// allowance the lane's room, so they stop before the lane's bound;
    /// what they take is the lane's (`settle`), never the owner's growth.
    fn codecAccount(w: *Writer) *Ids.Account {
        const room = w.meter.ceiling() -| w.meter.paid;
        w.codec.allowance = @intCast(@min(@as(u64, w.codec.growth) + room, std.math.maxInt(u32) - 1));
        return &w.codec;
    }

    fn settle(w: *Writer, before: u32) void {
        const d = w.codec.growth - before;
        w.meter.paid += d;
        w.meter.work += d;
        w.meter.account.baseline += d;
        w.meter.account.baseline_by[@backingInt(Ids.Category.inspection)] += d;
    }

    /// A failed codec read: past the lane, the codec's invariant; an input
    /// limit, the caller's.
    fn codecFailed(w: *Writer, before: u32, e: Error) Error {
        w.settle(before);
        const f = w.codec.failed orelse return e;
        if (w.meter.account.failed == null) w.meter.account.failed = switch (f) {
            .exhausted => .{ .invariant = Refine.codec_lane },
            else => f,
        };
        return w.meter.account.failed.?.err();
    }

    fn proj(w: *Writer, n: NodeId, s: Step) Error!?NodeId {
        const before = w.codec.growth;
        const c = w.env.shapes.proj(w.env.gpa, w.codecAccount(), w.env.places, w.env.cells, n, s) catch |e| return w.codecFailed(before, e);
        w.settle(before);
        return c;
    }

    fn flat(w: *Writer, k: CondId) Error!SetId {
        const before = w.codec.growth;
        const a = w.env.conds.flat(w.env.gpa, .growth(w.codecAccount()), k) catch |e| return w.codecFailed(before, e);
        w.settle(before);
        return a;
    }

    /// The owner of map `kappas` (null: the use shapes): maps are
    /// hash-consed, so values under one map are one owner's, described once.
    fn owner(w: *Writer, kappas: ?Cond.Kappas) Error!u32 {
        try w.take(1);
        const got = try w.owner_index.getOrPut(w.env.gpa, .{if (kappas) |k| k.int() else none - 1});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(w.owners.items.len);
            try w.owners.append(w.env.gpa, kappas);
            try w.roots.append(w.env.gpa, .empty);
        }
        return got.value_ptr.*;
    }

    /// A value of owner `o`: its position, recorded as a root of `o`'s walk.
    fn value(w: *Writer, n: NodeId, o: u32) Error!u32 {
        const x = try w.pos(n, false, o, w.rootOf(o));
        if (n != .none) try w.roots.items[o].append(w.env.gpa, n);
        return x;
    }

    /// A new record, its reservation its caller's.
    fn fresh(w: *Writer, kind: Kind, id: u32) Error!u32 {
        const r: u32 = @intCast(w.recs.items.len);
        w.meter.grow(1);
        try w.recs.append(w.env.gpa, .{ .kind = kind, .id = id, .rep = r });
        try w.pending.append(w.env.gpa, r);
        return r;
    }

    fn extra(w: *Writer, kind: Kind, e: Extra) Error!u32 {
        try w.take(1);
        try w.extras.append(w.env.gpa, e);
        return w.fresh(kind, @intCast(w.extras.items.len - 1));
    }

    /// A token, reserved a chunk of eight (16 words, §4.1) at a time.
    fn tok(w: *Writer, comptime tag: @FieldType(Tok, "tag"), x: u32) Error!void {
        if (w.tok_credit == 0) {
            try w.take(1);
            w.tok_credit = 8;
        }
        w.tok_credit -= 1;
        w.meter.grow(1);
        try w.toks.append(w.env.gpa, .{ .tag = tag, .x = x });
    }

    fn word(w: *Writer, x: u32) Error!void {
        try w.tok(.word, x);
    }

    fn put(w: *Writer, xs: []const u32) Error!void {
        for (xs) |x| try w.word(x);
    }

    fn ref(w: *Writer, kind: Kind, id: u32) Error!void {
        try w.tok(.ref, try w.rec(kind, id));
    }

    /// An unordered group of records.
    fn group(w: *Writer, rs: []const u32) Error!void {
        try w.tok(.group, @intCast(rs.len));
        for (rs) |r| try w.tok(.ref, r);
    }

    fn stepWords(w: *Writer, s: Step, out: *std.ArrayList(u32)) Error!void {
        switch (s.kind) {
            .field => try out.appendSlice(w.env.gpa, &.{ @backingInt(s.kind), w.names.place.field(w.names.place.ctx, s.payload) }),
            .ctor_arg => {
                const pair = w.env.places.ctorArgOf(s);
                try out.appendSlice(w.env.gpa, &.{ @backingInt(s.kind), pair[0], pair[1] });
            },
            else => try out.appendSlice(w.env.gpa, &.{ @backingInt(s.kind), s.payload }),
        }
    }

    fn step(w: *Writer, s: Step) Error!void {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(w.env.gpa);
        try w.stepWords(s, &words);
        try w.put(words.items);
    }

    /// `(step, position)` pairs in the order of the steps' words, written
    /// `n, (step, position)×n`.
    fn steps(w: *Writer, list: []const Over) Error!void {
        const gpa = w.env.gpa;
        const Entry = struct { words: [3]u32, n: u8, rec: u32 };
        var sorted: std.ArrayList(Entry) = .empty;
        defer sorted.deinit(gpa);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        try w.take(list.len);
        for (list) |o| {
            words.clearRetainingCapacity();
            try w.stepWords(o.step, &words);
            var three: [3]u32 = @splat(0);
            @memcpy(three[0..words.items.len], words.items);
            try sorted.append(gpa, .{ .words = three, .n = @intCast(words.items.len), .rec = o.rec });
        }
        try w.take(sortCost(sorted.items.len));
        std.mem.sort(Entry, sorted.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u32, &a.words, &b.words) == .lt;
            }
        }.less);
        try w.word(@intCast(sorted.items.len));
        for (sorted.items) |e| {
            try w.put(e.words[0..e.n]);
            try w.tok(.knot, e.rec);
        }
    }

    const Over = struct { step: Step, rec: u32 };

    /// A position: its node's kind, class, place and parts (a child at its
    /// own class and at its position one step below in the snapshot), what
    /// the snapshot is there (`0` none, `1` a position, `2` an exact fold,
    /// `3` a collapsed one), the κ
    /// stored there, and the positions `proj` makes at steps that the
    /// node's parts do not name and the snapshot links (or, below a fold,
    /// where a stored entry needs them, `entries`).
    fn position(w: *Writer, p: Position) Error!void {
        const gpa = w.env.gpa;
        const shapes = w.env.shapes;
        const conds = w.env.conds;
        const kappas = w.owners.items[p.owner];
        const cur = p.cursor;
        const d = shapes.get(p.node);
        try w.word(@backingInt(d.kind));
        try w.word(@intFromBool(p.at_summary));
        try w.word(if (cur == .none) 0 else if (conds.isCollapsed(cur)) 3 else if (conds.isFold(cur)) 2 else 1);
        try w.tok(.place, d.place.int());
        var named: std.ArrayList(Over) = .empty;
        defer named.deinit(gpa);
        switch (d.kind) {
            .leaf => try w.ref(.set, d.cells.int()),
            .node, .delta => {
                if (d.kind == .node) try w.ref(.set, d.cells.int()) else try w.tok(.ref, try w.pos(.from(d.a), p.at_summary, p.owner, cur));
                var it = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| try named.append(gpa, .{ .step = e.step, .rec = try w.pos(e.node, below(p.at_summary, e.step), p.owner, conds.kappaChild(cur, e.step)) });
                try w.steps(named.items);
            },
            .recast => try w.tok(.ref, try w.pos(.from(d.a), p.at_summary, p.owner, cur)),
            .@"union", .positions => try w.group(&.{ try w.pos(.from(d.a), p.at_summary, p.owner, cur), try w.pos(.from(d.b), p.at_summary, p.owner, cur) }),
        }
        // What is stored at the position, nothing else (§3.6): every reader
        // adds the derivation from the structure the reader rebuilds, and
        // one that reads only the stored (`deep` below a leaf) must find the
        // same after a round trip.
        if (kappas == null) {
            try w.tok(.ref, none);
        } else try w.ref(.cond, if (conds.kappaGet(cur, p.node)) |k| k.int() else none);
        // The projections that lead to a stored κ beyond the node's parts
        // (`entries`), each a position.
        var made: std.ArrayList(Over) = .empty;
        defer made.deinit(gpa);
        try w.take(1);
        if (w.extra_index.get(.{ p.node.int(), @intFromBool(p.at_summary), p.owner, cur.int() })) |beyond| {
            const list = w.extras_made.items[beyond].items;
            try w.take(list.len);
            for (list) |s| {
                const c = (try w.proj(p.node, s)) orelse return w.invariant();
                try made.append(gpa, .{ .step = s, .rec = try w.pos(c, below(p.at_summary, s), p.owner, conds.kappaChild(cur, s)) });
            }
        }
        try w.steps(made.items);
    }

    /// A node's successors `(node, class, step word, how, cursor)` at its
    /// position `cur` of the owner's snapshot: its parts (0) — the children
    /// it holds, at their positions one step below, a delta's base, a
    /// recast's inner, a union's or a positions node's sides, at its own —
    /// and, with `all`, the projections (2) at the steps the snapshot links
    /// there, or below a fold at every step of the place: `Cond.frontier`'s
    /// sparse transitions. What a block writes is the parts and the
    /// projections that lead to a stored κ (`entries`): any other
    /// projection reads κ derived from structure the reader rebuilds. Each
    /// is reserved before it is found.
    fn successors(w: *Writer, n: NodeId, summary: bool, cur: Cond.Kappas, all: bool, out: *std.ArrayList([5]u32)) Error!void {
        const gpa = w.env.gpa;
        const shapes = w.env.shapes;
        const conds = w.env.conds;
        const d = shapes.get(n);
        const sb: u32 = @intFromBool(summary);
        // Every edge found is one the codec reads.
        const start = out.items.len;
        defer w.meter.grow(out.items.len - start);
        switch (d.kind) {
            .leaf => {},
            .node, .delta => {
                try w.take(1);
                if (d.kind == .delta) try out.append(gpa, .{ d.a, sb, none, 0, cur.int() });
                var it = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| {
                    try w.take(1);
                    try out.append(gpa, .{ e.node.int(), @intFromBool(below(summary, e.step)), e.step.word(), 0, conds.kappaChild(cur, e.step).int() });
                }
            },
            .recast => try out.append(gpa, .{ d.a, sb, none, 0, cur.int() }),
            .@"union", .positions => try out.appendSlice(gpa, &.{ .{ d.a, sb, none, 0, cur.int() }, .{ d.b, sb, none, 0, cur.int() } }),
        }
        if (!all or cur == .none) return;
        // A fold's links are the steps it saw: sparse below it too.
        var cand: std.ArrayList(Step) = .empty;
        defer cand.deinit(gpa);
        var lt = conds.kappaLinks(cur);
        while (lt.next()) |e| try cand.append(gpa, e.step);
        for (cand.items) |s| {
            try w.take(1);
            w.meter.grow(1);
            const c = (try w.proj(n, s)) orelse continue;
            if ((d.kind == .node or d.kind == .delta) and shapes.overGet(if (d.kind == .node) d.a else d.b, s) == c) continue;
            try out.append(gpa, .{ c.int(), @intFromBool(below(summary, s)), s.word(), 2, conds.kappaChild(cur, s).int() });
        }
    }

    /// Close owner `o`'s positions under its snapshot: every stored entry a
    /// read can reach. A read — `kappaOf` at a position reached from a
    /// value (as `kappaLeq`, `propagate`, `join` and `map` read, `dagKappa`
    /// through a union's sides) — reaches only the positions
    /// `successors(all)` makes from the values. Where one holds a stored
    /// entry, the projections that lead to it are written (`extras_made`),
    /// so it is a position with the κ read there; where none, both sides
    /// derive κ from the structure the block rebuilds alone. So the written
    /// positions are closed: every read of the decoded class is the
    /// written one's. The snapshot's links give the route to an entry, so
    /// only below a fold does a projection need a search of the place.
    fn entries(w: *Writer, o: u32) Error!void {
        const gpa = w.env.gpa;
        const conds = w.env.conds;
        const kappas = w.owners.items[o] orelse return;
        if (kappas == .none) return;
        // The snapshot's entries, `(node, position)`.
        var stored: Ids.FixedDict(2) = .{};
        defer stored.deinit(gpa);
        {
            var walked: Ids.FixedDict(1) = .{};
            defer walked.deinit(gpa);
            var walk: std.ArrayList(Cond.Kappas) = .empty;
            defer walk.deinit(gpa);
            try walk.append(gpa, kappas);
            while (walk.pop()) |c| {
                try w.take(1);
                if ((try walked.getOrPut(gpa, .{c.int()})).found_existing) continue;
                var ht = conds.kappaHere(c);
                while (ht.next()) |e| {
                    try w.take(1);
                    (try stored.getOrPut(gpa, .{ e.node.int(), c.int() })).value_ptr.* = 0;
                }
                var lt = conds.kappaLinks(c);
                while (lt.next()) |e| {
                    try w.take(1);
                    try walk.append(gpa, e.child);
                }
            }
        }
        // The positions `position` writes anyway, from the values.
        const State = struct { node: u32, summary: bool, cur: u32, parent: u32, step: u32, chained: bool = false };
        var states: std.ArrayList(State) = .empty;
        defer states.deinit(gpa);
        var seen: Ids.FixedDict(3) = .{};
        defer seen.deinit(gpa);
        var next: std.ArrayList([5]u32) = .empty;
        defer next.deinit(gpa);
        var remaining = stored.count();
        for (0..2) |pass| {
            if (pass == 1) {
                if (remaining == 0) return;
                try w.take(states.items.len);
                for (states.items) |*x| {
                    x.parent = none - 1;
                    x.chained = false;
                }
            } else for (w.roots.items[o].items) |n| {
                try w.take(1);
                const got = try seen.getOrPut(gpa, .{ n.int(), 0, kappas.int() });
                if (got.found_existing) continue;
                got.value_ptr.* = @intCast(states.items.len);
                w.meter.grow(1);
                try states.append(gpa, .{ .node = n.int(), .summary = false, .cur = kappas.int(), .parent = none - 1, .step = none });
            }
            var at: usize = 0;
            while (at < states.items.len) : (at += 1) {
                const x = states.items[at];
                try w.take(1);
                if (pass == 0) {
                    if (stored.get(.{ x.node, x.cur })) |v| if (v == 0) {
                        (try stored.getOrPut(gpa, .{ x.node, x.cur })).value_ptr.* = 1;
                        remaining -= 1;
                    };
                }
                next.clearRetainingCapacity();
                try w.successors(.from(x.node), x.summary, .from(x.cur), pass == 1, &next);
                // Each successor's two lookups and its state.
                try w.take(next.items.len);
                for (next.items) |e| {
                    if (pass == 0 and e[3] == 2) continue;
                    const got = try seen.getOrPut(gpa, .{ e[0], e[1], e[4] });
                    if (got.found_existing) continue;
                    got.value_ptr.* = @intCast(states.items.len);
                    w.meter.grow(1);
                    try states.append(gpa, .{ .node = e[0], .summary = e[1] == 1, .cur = e[4], .parent = @intCast(at), .step = if (e[3] == 2) e[2] else none });
                    // An entry beyond the written positions: the chain of
                    // projections from a written one, each written.
                    const v = stored.get(.{ e[0], e[4] }) orelse continue;
                    if (v != 0) continue;
                    (try stored.getOrPut(gpa, .{ e[0], e[4] })).value_ptr.* = 1;
                    remaining -= 1;
                    var c = states.items.len - 1;
                    while (states.items[c].parent != none - 1 and !states.items[c].chained) {
                        states.items[c].chained = true;
                        try w.take(1);
                        const link = states.items[c];
                        const p = states.items[link.parent];
                        if (link.step != none) try w.extraMade(.from(p.node), p.summary, o, .from(p.cur), Step.fromWord(link.step));
                        c = link.parent;
                    }
                }
            }
        }
    }

    /// Each class's growth as if it were alone in the block: the positions
    /// it reaches past one per node (a node read under a second κ map, §3.6),
    /// on its own declaration's charge. Nothing another class reaches, or
    /// reaches first, changes it. The walks are the codec's.
    fn classGrowth(w: *Writer, roots: []const u32) Error!void {
        const gpa = w.env.gpa;
        const n = w.recs.items.len;
        try w.take(Refine.wordsCost(n));
        const stamp = try gpa.alloc(u32, n);
        defer gpa.free(stamp);
        @memset(stamp, 0);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        for (roots, 0..) |root, i| {
            const mark: u32 = @intCast(i + 1);
            var nodes: Ids.FixedDict(1) = .{};
            defer nodes.deinit(gpa);
            var positions: u32 = 0;
            stamp[root] = mark;
            try stack.append(gpa, root);
            while (stack.pop()) |r| {
                const ts = w.toksOf(r);
                try w.take(2 + scan(ts.len));
                w.meter.grow(1 + ts.len);
                if (w.recs.items[r].kind == .node and w.owners.items[w.positions.items[w.recs.items[r].id].owner] != null) {
                    positions += 1;
                    _ = try nodes.getOrPut(gpa, .{w.positions.items[w.recs.items[r].id].node.int()});
                }
                // An owner names every class's values: not this class's reach.
                if (w.recs.items[r].kind == .owner) continue;
                for (ts) |t| if (isPart(t) and stamp[t.x] != mark) {
                    stamp[t.x] = mark;
                    try stack.append(gpa, t.x);
                };
            }
            const charge = if (w.charges) |cs| cs[i] else w.env.charge;
            try charge.reserve(gpa, .context, positions - nodes.count());
        }
    }
    fn extraMade(w: *Writer, n: NodeId, summary: bool, o: u32, cur: Cond.Kappas, s: Step) Error!void {
        try w.take(1);
        const got = try w.extra_index.getOrPut(w.env.gpa, .{ n.int(), @intFromBool(summary), o, cur.int() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(w.extras_made.items.len);
            try w.extras_made.append(w.env.gpa, .empty);
        }
        try w.extras_made.items[got.value_ptr.*].append(w.env.gpa, s);
    }

    fn describe(w: *Writer, r: u32) Error!void {
        const gpa = w.env.gpa;
        const start: u32 = @intCast(w.toks.items.len);
        const kind = w.recs.items[r].kind;
        const id = w.recs.items[r].id;
        const cells = w.env.cells;
        switch (kind) {
            .label => {
                const d = cells.labelOf(.from(id));
                // A label's own supplies are the walk's (S4) and live, today,
                // in the classes' funs keyed by the label; its record holds
                // none yet.
                std.debug.assert(d.supplies.len == 0);
                try w.put(&.{ d.inst, @intFromBool(d.folded) });
                try w.ref(.label, d.callee_label.int());
            },
            .path => {
                const places = w.env.places;
                var list: std.ArrayList(Step) = .empty;
                defer list.deinit(gpa);
                var at: PathId = .from(id);
                while (places.pathParent(at) != .none) : (at = places.pathParent(at)) {
                    try w.take(1);
                    try list.append(gpa, places.pathStep(at));
                }
                try w.word(@intCast(list.items.len));
                try w.tok(.place, places.pathPlace(at).int());
                var i = list.items.len;
                while (i > 0) : (i -= 1) try w.step(list.items[i - 1]);
            },
            .cell => {
                const d = cells.get(.from(id));
                try w.put(&.{ @backingInt(d.origin), @backingInt(d.kind) });
                switch (d.origin) {
                    .site => {
                        try w.word(d.a);
                        try w.tok(.place, d.place.int());
                    },
                    .result, .esc => {
                        try w.ref(.label, d.a);
                        try w.word(d.b);
                        try w.tok(.place, d.place.int());
                    },
                    .shared => {
                        const name = w.names.decl(w.names.ctx, d.a);
                        try w.put(&.{ name[0], name[1] });
                        try w.ref(.path, d.b);
                        try w.word(d.c);
                    },
                    .param, .env, .msg => {
                        try w.word(d.a);
                        try w.ref(.path, d.b);
                        try w.word(d.c);
                    },
                    .cb => {
                        try w.ref(.label, d.a);
                        try w.ref(.path, d.b);
                        try w.word(d.c);
                    },
                    .top => {},
                    .elem, .others, .level, .below, .loan => {
                        try w.ref(.cell, d.a);
                        try w.ref(.label, d.b);
                        try w.word(d.c);
                        try w.tok(.place, d.place.int());
                        // The split the refinement was taken by, with the
                        // container's κ at it (§2.2), when there is one.
                        try w.ref(.split, cells.findSplit(.from(d.a), .from(d.b)).int());
                    },
                    .mark => {
                        // A written field's rank is a field rank like a step's.
                        try w.put(&.{ d.a, if (d.a == @backingInt(Cell.Mark.field)) w.names.place.field(w.names.place.ctx, d.b) else d.b });
                    },
                }
            },
            .split => {
                const s = cells.splitOf(.from(id));
                try w.ref(.cell, s.container.int());
                try w.word(s.inst);
                try w.ref(.label, s.label.int());
                try w.ref(.cond, s.cond.int());
            },
            .set => {
                var by_bit: [2]std.ArrayList(u32) = .{ .empty, .empty };
                defer for (&by_bit) |*l| l.deinit(gpa);
                var it = cells.sets.iterate(.from(id));
                while (it.next()) |e| try by_bit[e.value].append(gpa, try w.rec(.cell, e.key));
                try w.group(by_bit[0].items);
                try w.group(by_bit[1].items);
            },
            .atoms => {
                var list: std.ArrayList(u32) = .empty;
                defer list.deinit(gpa);
                var it = w.env.conds.atoms.iterate(.from(id));
                while (it.next()) |e| try list.append(gpa, try w.rec(.atom, e.key));
                try w.group(list.items);
            },
            .cond => {
                const k: CondId = .from(id);
                try w.word(@backingInt(w.env.conds.kind(k)));
                if (k != Cond.yes and !Cond.Table.fails(k)) try w.ref(.atoms, (try w.flat(k)).int());
            },
            .atom => {
                const a = w.env.conds.get(.from(id));
                try w.word(@backingInt(a.atom));
                switch (a.atom) {
                    .excl => try w.ref(.cell, a.a),
                    .sep => try w.group(&.{ try w.rec(.cell, a.a), try w.rec(.cell, a.b) }),
                    .within => try w.ref(.label, a.a),
                    .apart => try w.ref(.set, a.a),
                    .keep, .writes => try w.word(a.a),
                }
            },
            .node => try w.position(w.positions.items[id]),
            .supply => {
                const s = w.extras.items[id].supply;
                try w.put(&.{ s.k, @as(u32, @intFromBool(s.owned)) | (@as(u32, @intFromBool(s.taken)) << 1) });
                try w.ref(.label, s.label.int());
                // The handed value under its own snapshot.
                const o = try w.owner(s.kappa);
                try w.tok(.ref, try w.value(s.node, o));
                try w.ref(.owner, o);
            },
            .keep => {
                const k = w.extras.items[id].keep;
                try w.put(&.{ k.j, k.k });
                try w.ref(.path, k.kept_path.int());
                try w.ref(.path, k.written_path.int());
                try w.word(k.writer);
            },
            .slot => {
                const s = w.extras.items[id].slot;
                try w.word(s.param);
                try w.ref(.path, s.path.int());
            },
            .back => {
                const b = w.extras.items[id].back;
                try w.put(&.{ b.dest_param, @as(u32, @backingInt(b.mode)) | (@as(u32, @intFromBool(b.removes)) << 8) });
                try w.ref(.path, b.selected.int());
                try w.ref(.path, b.dest.int());
            },
            .owner => {
                // Every value under the map, from every class and supply of
                // the block, once: the reader builds the owner's one map
                // from them.
                var list: std.ArrayList(u32) = .empty;
                defer list.deinit(gpa);
                var once: Ids.FixedDict(1) = .{};
                defer once.deinit(gpa);
                for (w.roots.items[id].items) |n| {
                    const x = try w.pos(n, false, id, w.rootOf(id));
                    try w.take(1);
                    if ((try once.getOrPut(gpa, .{x})).found_existing) continue;
                    try list.append(gpa, x);
                }
                try w.group(list.items);
            },
            .class => try w.class(.from(id)),
            .group => unreachable,
        }
        const len: u32 = @intCast(w.toks.items.len - start);
        w.recs.items[r].toks = start;
        w.recs.items[r].len = len;
    }

    fn class(w: *Writer, c: ClassId) Error!void {
        const gpa = w.env.gpa;
        const k = w.sums.get(c);
        const o = try w.owner(k.kappas);
        try w.put(&.{ k.params.len, @as(u32, @intFromBool(k.writes)) | (@as(u32, @intFromBool(k.entry)) << 1) | (@as(u32, @intFromBool(k.refs_top)) << 2), @backingInt(k.origin) });
        try w.tok(.ref, try w.value(k.res, o));
        try w.ref(.owner, o);
        const uses = try w.owner(null);
        for (w.sums.paramUses(c)) |u| try w.tok(.ref, try w.pos(u, false, uses, .none));
        try w.ref(.atoms, k.xreq.int());
        try w.word(k.funs.len);
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(gpa);
        for (0..k.funs.len) |i| {
            const f = w.sums.fun(c, @intCast(i));
            try w.put(&.{ f.j, @backingInt(f.calls), @as(u32, @intFromBool(f.need)) | (@as(u32, @intFromBool(f.seen)) << 1) });
            list.clearRetainingCapacity();
            for (0..f.supplies.len) |s| try list.append(gpa, try w.extra(.supply, .{ .supply = w.sums.supply(f, @intCast(s)) }));
            try w.group(list.items);
            list.clearRetainingCapacity();
            for (0..f.keeps.len) |s| try list.append(gpa, try w.extra(.keep, .{ .keep = w.sums.keepOf(f, @intCast(s)) }));
            try w.group(list.items);
            list.clearRetainingCapacity();
            for (0..f.backs.len) |s| try list.append(gpa, try w.extra(.back, .{ .back = w.sums.backOf(f, @intCast(s)) }));
            try w.group(list.items);
        }
        list.clearRetainingCapacity();
        for (0..k.slots.len) |i| try list.append(gpa, try w.extra(.slot, .{ .slot = w.sums.slot(c, @intCast(i)) }));
        try w.group(list.items);
        list.clearRetainingCapacity();
        for (w.sums.nestedOf(c)) |x| try list.append(gpa, try w.rec(.class, x.int()));
        try w.group(list.items);
        list.clearRetainingCapacity();
        for (w.sums.oncesOf(c)) |p| try list.append(gpa, try w.rec(.path, p.int()));
        try w.group(list.items);
        try w.ref(.set, k.refs.int());
    }

    // ---- canonical keys ----------------------------------------------------------

    fn toksOf(w: *const Writer, r: u32) []const Tok {
        const x = w.recs.items[r];
        return w.toks.items[x.toks..][0..x.len];
    }

    fn isPart(t: Tok) bool {
        return (t.tag == .ref or t.tag == .knot) and t.x != none;
    }

    /// A record's tier: the records no position reaches (0), the positions
    /// (1), and those that name positions (2). Only positions make cycles.
    fn tier(kind: Kind) u2 {
        return switch (kind) {
            .node => 1,
            .owner, .supply, .class => 2,
            else => 0,
        };
    }

    /// Every record's key and every place's rank, exact and canonical, in
    /// a numbering of their own that grows in this order: the places, by a
    /// refinement of the graph they make (`refinePlaces`); the records of
    /// tier 0, then of tier 2, by height (`rankTier`); the positions between
    /// them, by a refinement of theirs (`refinePositions`). A record merged
    /// with another of its key is written as the first of them.
    fn canon(w: *Writer) Error!void {
        try w.refinePlaces();
        var next: u32 = 0;
        try w.rankTier(0, &next);
        try w.refinePositions(&next);
        try w.rankTier(2, &next);
    }

    /// The places the records name, closed under their children, refined
    /// from their kind, head, holds and step words, a port per step: two
    /// places are one rank exactly when they are one structure.
    fn refinePlaces(w: *Writer) Error!void {
        const gpa = w.env.gpa;
        const places = w.env.places;
        try w.take(scan(w.toks.items.len));
        for (w.toks.items) |t| if (t.tag == .place) try w.placeState(.from(t.x));
        var at: usize = 0;
        while (at < w.place_list.items.len) : (at += 1) {
            const children = places.steps(w.place_list.items[at]).children;
            try w.take(1 + children.len);
            for (children) |c| try w.placeState(c);
        }
        const np: u32 = @intCast(w.place_list.items.len);
        var g: Refine.Graph = .{};
        defer g.deinit(gpa);
        var step_words: std.ArrayList(u32) = .empty;
        defer step_words.deinit(gpa);
        for (w.place_list.items, 0..) |p, j| {
            const s = places.steps(p);
            try w.take(1 + s.steps.len);
            const kind = places.kind(p);
            try g.open(gpa);
            try g.put(gpa, &.{ 2, @backingInt(kind), if (kind == .tuple or kind == .record) places.head(p) else w.names.place.head(w.names.place.ctx, places.head(p)), places.holds(p).bits(), @intCast(s.steps.len) });
            for (s.steps, s.children, 0..) |st, c, i| {
                step_words.clearRetainingCapacity();
                try w.stepWords(st, &step_words);
                try g.put(gpa, step_words.items);
                try g.port(gpa, @intCast(j), @intCast(i), &.{w.place_state.get(.{c.int()}).?});
            }
        }
        const block = try g.refine(&w.meter, np);
        defer gpa.free(block);
        try w.take(1 + np);
        try w.place_rank.appendSlice(gpa, block[0..np]);
    }

    /// The local words of a token of a record being ranked: a word, a
    /// place's rank, a part's key (or, with `ports`, a port to a position
    /// part); a group's members' keys sorted.
    fn keyWords(w: *Writer, g: *Refine.Graph, state: u32, ts: []const Tok, ports: bool) Error!void {
        const gpa = w.env.gpa;
        var k: usize = 0;
        while (k < ts.len) : (k += 1) {
            const t = ts[k];
            switch (t.tag) {
                .word => try g.put(gpa, &.{ 0, t.x }),
                .place => {
                    try w.take(1);
                    try g.put(gpa, &.{ 1, w.place_rank.items[w.place_state.get(.{t.x}).?] });
                },
                .ref, .knot => if (t.x == none) {
                    try g.put(gpa, &.{if (t.tag == .ref) 2 else 3});
                } else if (ports and tier(w.recs.items[t.x].kind) == 1) {
                    try g.put(gpa, &.{if (t.tag == .ref) 5 else 7});
                    try g.port(gpa, state, @intCast(k), &.{w.state_of.items[t.x]});
                } else try g.put(gpa, &.{ 4, @intCast(w.recs.items[t.x].key) }),
                .group => {
                    // The members are a multiset: positions a port's count,
                    // the others their sorted keys.
                    const ms = ts[k + 1 ..][0..t.x];
                    k += t.x;
                    var keyed: std.ArrayList(u32) = .empty;
                    defer keyed.deinit(gpa);
                    var targets: std.ArrayList(u32) = .empty;
                    defer targets.deinit(gpa);
                    for (ms) |m| {
                        if (m.x == none) {
                            try keyed.append(gpa, none);
                        } else if (ports and tier(w.recs.items[m.x].kind) == 1) {
                            try targets.append(gpa, w.state_of.items[m.x]);
                        } else try keyed.append(gpa, @intCast(w.recs.items[m.x].key));
                    }
                    try w.take(sortCost(keyed.items.len));
                    std.mem.sort(u32, keyed.items, {}, std.sort.asc(u32));
                    try g.put(gpa, &.{ 6, t.x, @intCast(keyed.items.len) });
                    try g.put(gpa, keyed.items);
                    if (targets.items.len > 0) try g.port(gpa, state, @intCast(k - t.x), targets.items);
                },
            }
        }
    }

    /// The records of `tier` 0 or 2, which make no cycle: ranked a height
    /// at a time, a record's words naming its parts by their keys, so equal
    /// records are one key and the keys follow the structure.
    fn rankTier(w: *Writer, t: u2, next: *u32) Error!void {
        const gpa = w.env.gpa;
        const n = w.recs.items.len;
        try w.take(Refine.wordsCost(2 * n));
        var height = try gpa.alloc(u32, n);
        defer gpa.free(height);
        @memset(height, none);
        // Heights by an explicit stack, parts of the tier first.
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(gpa);
        var levels: u32 = 0;
        for (0..n) |root| {
            if (tier(w.recs.items[root].kind) != t or height[root] != none) continue;
            try w.take(1 + 2 * scan(w.toksOf(@intCast(root)).len));
            try stack.append(gpa, .{ @intCast(root), 0 });
            height[root] = none - 1;
            while (stack.items.len > 0) {
                const f = &stack.items[stack.items.len - 1];
                const ts = w.toksOf(f[0]);
                if (f[1] < ts.len) {
                    const x = ts[f[1]];
                    f[1] += 1;
                    if (x.tag == .word or x.tag == .place or x.tag == .group or x.x == none or tier(w.recs.items[x.x].kind) != t) continue;
                    if (height[x.x] == none - 1) return w.invariant();
                    if (height[x.x] == none) {
                        try w.take(1 + 2 * scan(w.toksOf(x.x).len));
                        height[x.x] = none - 1;
                        try stack.append(gpa, .{ x.x, 0 });
                    }
                    continue;
                }
                const r = f[0];
                _ = stack.pop();
                var h: u32 = 0;
                for (ts) |x| {
                    if (x.tag == .word or x.tag == .place or x.tag == .group or x.x == none or tier(w.recs.items[x.x].kind) != t) continue;
                    h = @max(h, height[x.x] + 1);
                }
                height[r] = h;
                levels = @max(levels, h + 1);
            }
        }
        // The records of each height, by a counting sort.
        const level_start = try gpa.alloc(u32, levels + 1);
        defer gpa.free(level_start);
        @memset(level_start, 0);
        var count: u32 = 0;
        for (0..n) |r| if (tier(w.recs.items[r].kind) == t) {
            level_start[height[r] + 1] += 1;
            count += 1;
        };
        for (1..levels + 1) |i| level_start[i] += level_start[i - 1];
        const by_level = try gpa.alloc(u32, count);
        defer gpa.free(by_level);
        {
            const at = try gpa.dupe(u32, level_start[0..levels]);
            defer gpa.free(at);
            for (0..n) |r| if (tier(w.recs.items[r].kind) == t) {
                by_level[at[height[r]]] = @intCast(r);
                at[height[r]] += 1;
            };
        }
        for (0..levels) |h| {
            const rs = by_level[level_start[h]..level_start[h + 1]];
            var g: Refine.Graph = .{};
            defer g.deinit(gpa);
            for (rs) |r| {
                const ts = w.toksOf(r);
                try w.take(Refine.wordsCost(4 * ts.len));
                try g.open(gpa);
                try g.put(gpa, &.{@backingInt(w.recs.items[r].kind)});
                try w.keyWords(&g, 0, ts, false);
            }
            try g.starts.append(gpa, @intCast(g.words.items.len));
            const ranks = try Refine.rank(&w.meter, g.words.items, g.starts.items);
            defer gpa.free(ranks.ranks);
            const firsts = try gpa.alloc(u32, ranks.count);
            defer gpa.free(firsts);
            @memset(firsts, none);
            try w.take(Refine.wordsCost(2 * rs.len));
            for (rs, ranks.ranks) |r, k| {
                if (firsts[k] == none or firsts[k] > r) firsts[k] = r;
            }
            for (rs, ranks.ranks) |r, k| {
                w.recs.items[r].key = next.* + k;
                w.recs.items[r].rep = firsts[k];
            }
            next.* += ranks.count;
        }
    }

    /// The positions, refined from their local words (tier-0 parts by
    /// key), a port per part that is a position: two positions are one key
    /// exactly when they are bisimilar with equal words everywhere.
    fn refinePositions(w: *Writer, next: *u32) Error!void {
        const gpa = w.env.gpa;
        try w.take(Refine.wordsCost(2 * w.recs.items.len));
        try w.state_of.resize(gpa, w.recs.items.len);
        var states: std.ArrayList(u32) = .empty;
        defer states.deinit(gpa);
        for (w.recs.items, 0..) |x, r| if (x.kind == .node) {
            w.state_of.items[r] = @intCast(states.items.len);
            try states.append(gpa, @intCast(r));
        };
        if (states.items.len == 0) return;
        var g: Refine.Graph = .{};
        defer g.deinit(gpa);
        for (states.items, 0..) |r, i| {
            const ts = w.toksOf(r);
            try w.take(Refine.wordsCost(4 * ts.len));
            try g.open(gpa);
            try w.keyWords(&g, @intCast(i), ts, true);
        }
        const block = try g.refine(&w.meter, @intCast(states.items.len));
        defer gpa.free(block);
        try w.take(Refine.wordsCost(4 * states.items.len));
        const firsts = try gpa.alloc(u32, block.len);
        defer gpa.free(firsts);
        @memset(firsts, none);
        for (states.items, 0..) |r, i| {
            const b = block[i];
            if (firsts[b] == none) firsts[b] = r;
            w.recs.items[r].key = next.* + b;
            w.recs.items[r].rep = firsts[b];
        }
        next.* += @intCast(block.len);
    }

    // ---- components ---------------------------------------------------------------

    fn repOf(w: *const Writer, r: u32) u32 {
        return if (r == none) none else w.recs.items[r].rep;
    }

    const Frame = struct { r: u32, cursor: u32 };

    /// Tarjan's components over the written records (a merged record is
    /// its block's), by an explicit stack.
    fn components(w: *Writer) Error!void {
        const gpa = w.env.gpa;
        const n = w.recs.items.len;
        try w.take(Refine.wordsCost(8 * n) + scan(w.toks.items.len));
        const index = try gpa.alloc(u32, n);
        defer gpa.free(index);
        const low = try gpa.alloc(u32, n);
        defer gpa.free(low);
        const on = try gpa.alloc(bool, n);
        defer gpa.free(on);
        @memset(index, none);
        @memset(on, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        var call: std.ArrayList(Frame) = .empty;
        defer call.deinit(gpa);
        var counter: u32 = 0;
        for (0..n) |root| {
            if (index[root] != none or w.recs.items[root].rep != root) continue;
            index[root] = counter;
            low[root] = counter;
            counter += 1;
            try stack.append(gpa, @intCast(root));
            on[root] = true;
            try call.append(gpa, .{ .r = @intCast(root), .cursor = 0 });
            while (call.items.len > 0) {
                const f = &call.items[call.items.len - 1];
                const ts = w.toksOf(f.r);
                if (f.cursor < ts.len) {
                    const t = ts[f.cursor];
                    f.cursor += 1;
                    if (!isPart(t)) continue;
                    const c = w.repOf(t.x);
                    if (index[c] == none) {
                        index[c] = counter;
                        low[c] = counter;
                        counter += 1;
                        try stack.append(gpa, c);
                        on[c] = true;
                        try call.append(gpa, .{ .r = c, .cursor = 0 });
                    } else if (on[c]) low[f.r] = @min(low[f.r], index[c]);
                    continue;
                }
                const r = f.r;
                _ = call.pop();
                if (call.items.len > 0) {
                    const parent = call.items[call.items.len - 1].r;
                    low[parent] = @min(low[parent], low[r]);
                }
                if (low[r] != index[r]) continue;
                const first: u32 = @intCast(w.members.items.len);
                while (true) {
                    const m = stack.pop().?;
                    on[m] = false;
                    try w.members.append(gpa, m);
                    w.recs.items[m].scc = @intCast(w.sccs.items.len);
                    if (m == r) break;
                }
                const len: u32 = @intCast(w.members.items.len - first);
                try w.sccs.append(gpa, .{ .first = first, .len = len, .knot = len > 1 or w.selfPart(r) });
                if (w.sccs.items[w.sccs.items.len - 1].knot) try w.order(@intCast(w.sccs.items.len - 1));
            }
        }
        // A merged record is in its block's component.
        for (w.recs.items) |*x| x.scc = w.recs.items[x.rep].scc;
    }

    fn selfPart(w: *const Writer, r: u32) bool {
        for (w.toksOf(r)) |t| if (isPart(t) and w.repOf(t.x) == r) return true;
        return false;
    }

    const OFrame = struct { r: u32, first: u32, len: u32, cursor: u32 };

    /// A knot's members in written order: by key, every part that is not a
    /// child step after what it names (a post-order walk of those parts from
    /// each member in key order). A member met on its own walk is a cycle no
    /// step closes, which no constructor makes.
    fn order(w: *Writer, s: u32) Error!void {
        const gpa = w.env.gpa;
        const c = w.sccs.items[s];
        const ms = w.members.items[c.first..][0..c.len];
        for (ms) |m| if (w.recs.items[m].kind != .node) return w.invariant();
        try w.sortDistinct(ms);
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        // A member's walk: 0 open, 1 done.
        var state: Ids.FixedDict(1) = .{};
        defer state.deinit(gpa);
        var stack: std.ArrayList(OFrame) = .empty;
        defer stack.deinit(gpa);
        var kids: std.ArrayList(u32) = .empty;
        defer kids.deinit(gpa);
        for (ms) |root| {
            try w.take(1);
            const top = try state.getOrPut(gpa, .{root});
            if (top.found_existing) continue;
            top.value_ptr.* = 0;
            try w.openParts(root, &kids, &stack);
            while (stack.items.len > 0) {
                const f = &stack.items[stack.items.len - 1];
                if (f.cursor == f.len) {
                    try w.take(1);
                    (try state.getOrPut(gpa, .{f.r})).value_ptr.* = 1;
                    try out.append(gpa, f.r);
                    kids.shrinkRetainingCapacity(f.first);
                    _ = stack.pop();
                    continue;
                }
                const target = kids.items[f.first + f.cursor];
                f.cursor += 1;
                if (w.recs.items[target].scc != s) continue;
                try w.take(1);
                const got = try state.getOrPut(gpa, .{target});
                if (got.found_existing) {
                    if (got.value_ptr.* == 0) return w.invariant();
                    continue;
                }
                got.value_ptr.* = 0;
                try w.openParts(target, &kids, &stack);
            }
        }
        @memcpy(ms, out.items);
    }

    /// `order`'s frame for `r`, its strict parts listed once.
    fn openParts(w: *Writer, r: u32, kids: *std.ArrayList(u32), stack: *std.ArrayList(OFrame)) Error!void {
        const first: u32 = @intCast(kids.items.len);
        try w.parts(r, kids, true);
        // Each part is looked at once, a chunk at a time.
        try w.take(Refine.wordsCost(kids.items.len - first));
        try stack.append(w.env.gpa, .{ .r = r, .first = first, .len = @intCast(kids.items.len - first), .cursor = 0 });
    }

    // ---- emitting -------------------------------------------------------------

    fn ordinalOf(w: *const Writer, r: u32) u32 {
        return if (r == none) none else w.recs.items[w.recs.items[r].rep].ordinal;
    }

    /// A record's parts (their records) in written order, a group's by key;
    /// with `strict`, only the parts a knot's member must follow (not a
    /// child step or a projected position).
    fn parts(w: *Writer, r: u32, out: *std.ArrayList(u32), strict: bool) Error!void {
        const gpa = w.env.gpa;
        const ts = w.toksOf(r);
        try w.take(scan(ts.len));
        var i: usize = 0;
        while (i < ts.len) : (i += 1) {
            const t = ts[i];
            switch (t.tag) {
                .word, .place => {},
                .knot => if (!strict and t.x != none) try out.append(gpa, w.repOf(t.x)),
                .ref => if (t.x != none) try out.append(gpa, w.repOf(t.x)),
                .group => {
                    const start = out.items.len;
                    for (ts[i + 1 ..][0..t.x]) |m| try out.append(gpa, w.repOf(m.x));
                    try w.take(sortCost(t.x));
                    w.sortByKey(out.items[start..]);
                    i += t.x;
                },
            }
        }
    }

    /// Records of distinct keys in key order: by comparison, or — when the
    /// keys lie close — by one pass over the range they span, whichever is
    /// charged less.
    fn sortDistinct(w: *Writer, rs: []u32) Error!void {
        if (rs.len < 2) return;
        try w.take(Refine.wordsCost(rs.len));
        var lo: u32 = std.math.maxInt(u32);
        var hi: u32 = 0;
        for (rs) |r| {
            lo = @min(lo, w.recs.items[r].key);
            hi = @max(hi, w.recs.items[r].key);
        }
        const range: usize = hi - lo + 1;
        const dense = 1 + rs.len + Refine.wordsCost(2 * range);
        if (dense >= sortCost(rs.len)) {
            try w.take(sortCost(rs.len));
            return w.sortByKey(rs);
        }
        try w.take(dense);
        const slot = try w.env.gpa.alloc(u32, range);
        defer w.env.gpa.free(slot);
        @memset(slot, none);
        for (rs) |r| slot[w.recs.items[r].key - lo] = r;
        var i: usize = 0;
        for (slot) |r| if (r != none) {
            rs[i] = r;
            i += 1;
        };
        if (i != rs.len) return w.invariant();
    }

    fn sortByKey(w: *const Writer, rs: []u32) void {
        std.mem.sort(u32, rs, w, struct {
            fn less(ww: *const Writer, a: u32, b: u32) bool {
                return ww.recs.items[a].key < ww.recs.items[b].key;
            }
        }.less);
    }

    const EFrame = struct { s: u32, first: u32, len: u32, cursor: u32 };

    /// Write component `s` and everything it reaches, parts first, by an
    /// explicit stack.
    fn emitFrom(w: *Writer, s0: u32) Error!void {
        const gpa = w.env.gpa;
        var kids: std.ArrayList(u32) = .empty;
        defer kids.deinit(gpa);
        var stack: std.ArrayList(EFrame) = .empty;
        defer stack.deinit(gpa);
        if (w.sccs.items[s0].state != .new) return;
        try w.open(s0, &kids, &stack);
        while (stack.items.len > 0) {
            const f = &stack.items[stack.items.len - 1];
            if (f.cursor < f.len) {
                const r = kids.items[f.first + f.cursor];
                f.cursor += 1;
                const s = w.recs.items[r].scc;
                if (w.sccs.items[s].state == .new) try w.open(s, &kids, &stack);
                continue;
            }
            const s = f.s;
            kids.shrinkRetainingCapacity(f.first);
            _ = stack.pop();
            try w.emit(s);
            w.sccs.items[s].state = .done;
        }
    }

    fn open(w: *Writer, s: u32, kids: *std.ArrayList(u32), stack: *std.ArrayList(EFrame)) Error!void {
        w.sccs.items[s].state = .open;
        const first: u32 = @intCast(kids.items.len);
        const c = w.sccs.items[s];
        for (w.members.items[c.first..][0..c.len]) |m| {
            const start = kids.items.len;
            try w.parts(m, kids, false);
            // A knot's own members are not its parts; each kept part is
            // visited once.
            try w.take(Refine.wordsCost(kids.items.len - start));
            var keep = start;
            for (kids.items[start..]) |x| {
                if (w.recs.items[x].scc == s) continue;
                kids.items[keep] = x;
                keep += 1;
            }
            kids.shrinkRetainingCapacity(keep);
        }
        try stack.append(w.env.gpa, .{ .s = s, .first = first, .len = @intCast(kids.items.len - first), .cursor = 0 });
    }

    const rel_bit: u32 = 1 << 31;

    /// Record `r`'s words: its kind, then its description with every part
    /// its ordinal (a member of knot `base`'s, its offset with `rel_bit` in
    /// `rel` and its ordinal in `abs`), a group's by key.
    fn spell(w: *Writer, r: u32, s: u32, base: u32, abs: *std.ArrayList(u32), rel: *std.ArrayList(u32)) Error!void {
        const gpa = w.env.gpa;
        const ts = w.toksOf(r);
        try w.take(Refine.wordsCost(6 * ts.len));
        try abs.append(gpa, @backingInt(w.recs.items[r].kind));
        try rel.append(gpa, @backingInt(w.recs.items[r].kind));
        var i: usize = 0;
        while (i < ts.len) : (i += 1) {
            const t = ts[i];
            switch (t.tag) {
                .word => {
                    try abs.append(gpa, t.x);
                    try rel.append(gpa, t.x);
                },
                .place => {
                    const p = try w.placeLocal(.from(t.x));
                    try abs.append(gpa, p);
                    try rel.append(gpa, p);
                },
                .ref, .knot => try w.part(t.x, s, base, abs, rel),
                .group => {
                    var g: std.ArrayList(u32) = .empty;
                    defer g.deinit(gpa);
                    for (ts[i + 1 ..][0..t.x]) |m| try g.append(gpa, w.repOf(m.x));
                    try w.take(sortCost(g.items.len));
                    w.sortByKey(g.items);
                    try abs.append(gpa, t.x);
                    try rel.append(gpa, t.x);
                    for (g.items) |m| try w.part(m, s, base, abs, rel);
                    i += t.x;
                },
            }
        }
    }

    fn part(w: *Writer, x: u32, s: u32, base: u32, abs: *std.ArrayList(u32), rel: *std.ArrayList(u32)) Error!void {
        const gpa = w.env.gpa;
        const o = w.ordinalOf(x);
        try abs.append(gpa, o);
        try rel.append(gpa, if (x != none and w.recs.items[x].scc == s) (o - base) | rel_bit else o);
    }

    /// Write a closed component: one record, or a knot's group. A record
    /// merged into its block's must spell that record's words (`check`),
    /// and no two units spell the same (`distinct`).
    fn emit(w: *Writer, s: u32) Error!void {
        const gpa = w.env.gpa;
        const c = w.sccs.items[s];
        var abs: std.ArrayList(u32) = .empty;
        defer abs.deinit(gpa);
        var rel: std.ArrayList(u32) = .empty;
        defer rel.deinit(gpa);
        const base = w.next;
        if (base + c.len >= rel_bit) return error.OwnershipLimit;
        const ms = w.members.items[c.first..][0..c.len];
        try w.take(Refine.wordsCost(ms.len));
        for (ms, 0..) |m, i| w.recs.items[m].ordinal = base + @as(u32, @intCast(i));
        if (c.knot) try abs.appendSlice(gpa, &.{ @backingInt(Kind.group), c.len });
        if (c.knot) try rel.appendSlice(gpa, &.{ @backingInt(Kind.group), c.len });
        for (ms) |m| try w.spell(m, s, base, &abs, &rel);
        // Kept for `distinct`, and written.
        try w.take(2 * Refine.wordsCost(abs.items.len));
        try w.rel_starts.append(gpa, @intCast(w.rel_out.items.len));
        try w.rel_out.appendSlice(gpa, rel.items);
        w.next += c.len;
        w.units += 1;
        try w.out.appendSlice(gpa, abs.items);
    }

    /// No two units spell the same words: the refinement merged every
    /// equal structure, so a repeat would be the codec's defect. Checked by
    /// sorting the units' words, never by a hash.
    fn distinct(w: *Writer) Error!void {
        try w.rel_starts.append(w.env.gpa, @intCast(w.rel_out.items.len));
        const r = try Refine.rank(&w.meter, w.rel_out.items, w.rel_starts.items);
        defer w.env.gpa.free(r.ranks);
        if (r.count != w.units) return w.invariant();
    }

    /// Every merged record spells its block's record's words, checked once
    /// the table is written: the refinement merged only equal structure.
    fn check(w: *Writer) Error!void {
        const gpa = w.env.gpa;
        var a: std.ArrayList(u32) = .empty;
        defer a.deinit(gpa);
        var b: std.ArrayList(u32) = .empty;
        defer b.deinit(gpa);
        var scratch: std.ArrayList(u32) = .empty;
        defer scratch.deinit(gpa);
        try w.take(Refine.wordsCost(w.recs.items.len));
        for (w.recs.items, 0..) |x, r| {
            if (x.rep == r) continue;
            a.clearRetainingCapacity();
            b.clearRetainingCapacity();
            scratch.clearRetainingCapacity();
            try w.spell(@intCast(r), none, 0, &a, &scratch);
            scratch.clearRetainingCapacity();
            try w.spell(x.rep, none, 0, &b, &scratch);
            try w.take(Refine.wordsCost(a.items.len));
            if (!std.mem.eql(u32, a.items, b.items)) return w.invariant();
        }
    }
};
