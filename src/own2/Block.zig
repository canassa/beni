//! L11: the ownership block (`docs/design/ownership-v2.md` §3.6), minimal:
//! classes to words and back, with places written structurally. S2b builds
//! the class table and its records, written here — a header (`OWN2`, the version), the
//! place table, the record table, the root classes — and nothing of S6's:
//! no lazy directory, no cache section, no traversal marks.
//!
//! **Positions, with the κ they read.** A class means κ as READ (§2.9: the
//! stored κ joined with the κ derived at the position), at every position
//! a read can reach: from its `res` (a supply's from its value; a use
//! shape is no value and carries none) along every step of the place by `proj`, as `kappaLeq` and
//! `propagate` walk, and through a union's sides as `dagKappa` reads them.
//! So the block's node records are POSITIONS — a node, its position class
//! (`at_summary`) and its owner's map — each with the κ read there (a
//! union's or a positions node's: what is stored there, as its sides are
//! read with it), its node's parts, and the positions `proj` makes that
//! its structure does not name. The reader
//! stores exactly that κ at exactly those positions, so every read of the
//! decoded class is the written one's.
//!
//! **Every record once.** A label, a path, a cell, a split, a cell set, an
//! atom set, a condition, an atom, a position, a supply, a keep, a slot and
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
//! **The order is the structure's.** A record that is not a position has a
//! 64-bit key: a hash of its own words, its places' encodings and its
//! parts' keys (a set's sorted). The positions are partitioned once, all of
//! the block's together (`refine`: Hopcroft's algorithm, counting a
//! union's two sides, O(E log n)), from their kind, place, cells, read κ
//! and steps; two positions are one block exactly when they are bisimilar
//! with equal κ everywhere, and one block is one record. Every choice of
//! the refinement depends on block numbers and splitting signatures only,
//! never on an id, so the final block numbers are canonical and are the
//! positions' keys. The table is then a post-order walk from the classes,
//! a set's parts in key order: ordinals, place numbers and bytes follow
//! from the structure alone. Two records with equal words are one record;
//! equal hashes of different local signatures (a 64-bit collision) are
//! refused, never merged.
//!
//! **Reading** is `BlockRead`'s, one layer up (§5): this file holds the
//! format both sides share.
//!
//! **Cost.** Every record is reserved on the writer's and the reader's
//! charge before it is read or made (§4.1); a sort of n members is charged
//! n·⌈log₂ n⌉, the refinement per edge it moves.
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
const stamped = @import("../stamped.zig");

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
pub const version: u32 = 4;

pub const none: u32 = Ids.none_int;

/// A record's kind, which is its tag in the table; `group` opens a knot.
/// A `node` record is a position.
pub const Kind = enum(u8) { label, path, cell, split, set, atoms, cond, atom, node, supply, keep, slot, class, group };

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

fn chargeSort(env: Env, n: usize) Error!void {
    if (n < 2) return;
    const log: u32 = std.math.log2_int_ceil(usize, n);
    try env.charge.reserve(env.gpa, .inspection, @intCast(@min(n * log, std.math.maxInt(u32))));
}

/// The position class of the child at `s` of a position of class `summary`.
pub fn below(summary: bool, s: Step) bool {
    return summary or s.kind == .elem or s.kind == .level;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Write `classes` as one block: header, place table, records, roots.
pub fn write(env: Env, sums: *Summary.Table, classes: []const ClassId, names: Names, out: *std.ArrayList(u32)) Error!void {
    const gpa = env.gpa;
    var w: Writer = .{ .env = env, .sums = sums, .names = names, .seen_keys = .init(gpa) };
    defer w.deinit();
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);
    for (classes) |c| try roots.append(gpa, try w.rec(.class, c.int()));
    while (w.pending.pop()) |r| try w.describe(r);
    try w.keys();
    for (roots.items) |r| try w.emitFrom(w.recs.items[r].scc);
    try w.check();
    // The places the records named, closed under their children, each
    // record `kind, head, holds, n, (step…, child)×n`.
    var places: std.ArrayList(u32) = .empty;
    defer places.deinit(gpa);
    var at: usize = 0;
    while (at < w.place_order.items.len) : (at += 1) {
        const p = w.place_order.items[at];
        try env.charge.reserve(gpa, .inspection, 1);
        const k = env.places.kind(p);
        const steps = env.places.steps(p);
        try places.appendSlice(gpa, &.{ @backingInt(k), if (k == .tuple or k == .record) env.places.head(p) else names.place.head(names.place.ctx, env.places.head(p)), env.places.holds(p).bits(), @intCast(steps.steps.len) });
        for (steps.steps, steps.children) |s, child| {
            try w.stepWords(s, &places);
            try places.append(gpa, try w.placeLocal(child));
        }
    }
    try out.appendSlice(gpa, &.{ magic, version, @intCast(w.place_order.items.len) });
    try out.appendSlice(gpa, places.items);
    try out.append(gpa, w.units);
    try out.appendSlice(gpa, w.out.items);
    try out.append(gpa, @intCast(roots.items.len));
    for (roots.items) |r| try out.append(gpa, w.ordinalOf(r));
}

/// One word of a record's description: a word as written, a place (its
/// local number in the block, its encoding in the key), a part (`ref`, or
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
    key: u64 = 0,
    scc: u32 = none,
    /// The record a position is written as: its block's first member.
    rep: u32,
    ordinal: u32 = none,
};

/// A node read at a position class under an owner's κ map.
const Position = struct { node: NodeId, at_summary: bool, owner: u32 };

const Extra = union(enum) {
    supply: Summary.Supply,
    keep: Summary.Keep,
    slot: Summary.Slot,
};

/// A strongly connected component of the written records: one record, or a
/// knot of positions.
const Scc = struct { first: u32, len: u32, knot: bool, state: enum(u8) { new, open, done } = .new };

const Writer = struct {
    env: Env,
    sums: *Summary.Table,
    names: Names,
    recs: std.ArrayList(Rec) = .empty,
    /// `(kind, table id)` → record.
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// `(node, position class, owner)` → position record.
    pos_index: Ids.FixedDict(3) = .{},
    positions: std.ArrayList(Position) = .empty,
    /// Each owner's κ map: a class's, a supply's; null for a class's use
    /// shapes, whose cells are marks and carry no κ.
    owners: std.ArrayList(?Cond.Kappas) = .empty,
    toks: std.ArrayList(Tok) = .empty,
    extras: std.ArrayList(Extra) = .empty,
    pending: std.ArrayList(u32) = .empty,
    sccs: std.ArrayList(Scc) = .empty,
    /// The members of each component, a knot's in its written order.
    members: std.ArrayList(u32) = .empty,
    place_hash: stamped.Column(PlaceId, u64) = .{},
    place_local: Ids.FixedDict(1) = .{},
    place_order: std.ArrayList(PlaceId) = .empty,
    /// The record table as written, and how many records and knots.
    out: std.ArrayList(u32) = .empty,
    units: u32 = 0,
    next: u32 = 0,
    /// A record's words (a knot's, its members' relative) → its ordinal.
    seen: std.StringHashMapUnmanaged(u32) = .empty,
    seen_keys: std.heap.ArenaAllocator,

    fn deinit(w: *Writer) void {
        const gpa = w.env.gpa;
        w.recs.deinit(gpa);
        w.index.deinit(gpa);
        w.pos_index.deinit(gpa);
        w.positions.deinit(gpa);
        w.owners.deinit(gpa);
        w.toks.deinit(gpa);
        w.extras.deinit(gpa);
        w.pending.deinit(gpa);
        w.sccs.deinit(gpa);
        w.members.deinit(gpa);
        w.place_hash.deinit(gpa);
        w.place_local.deinit(gpa);
        w.place_order.deinit(gpa);
        w.out.deinit(gpa);
        w.seen.deinit(gpa);
        w.seen_keys.deinit();
    }

    fn placeLocal(w: *Writer, p: PlaceId) Error!u32 {
        try w.env.charge.reserve(w.env.gpa, .inspection, 1);
        const got = try w.place_local.getOrPut(w.env.gpa, .{p.int()});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(w.place_order.items.len);
            try w.place_order.append(w.env.gpa, p);
        }
        return got.value_ptr.*;
    }

    /// A place's key: its canonical encoding from it, once per place,
    /// charged by the encoding's length.
    fn placeHash(w: *Writer, p: PlaceId) Error!u64 {
        if (w.place_hash.get(p)) |h| return h;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(w.env.gpa);
        try w.env.places.encode(w.env.gpa, p, w.names.place, &words);
        try w.env.charge.reserve(w.env.gpa, .inspection, @intCast(words.items.len + 1));
        const h = std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(words.items));
        try w.place_hash.put(w.env.gpa, p, h);
        return h;
    }

    // ---- describing ------------------------------------------------------------

    /// The record of table id `id` of `kind`, made and queued on first
    /// sight; `none` for no record.
    fn rec(w: *Writer, kind: Kind, id: u32) Error!u32 {
        if (id == none) return none;
        const got = try w.index.getOrPut(w.env.gpa, (@as(u64, @backingInt(kind)) << 32) | id);
        if (!got.found_existing) got.value_ptr.* = try w.fresh(kind, id);
        return got.value_ptr.*;
    }

    /// The position of `n` at class `at_summary` under owner `owner`.
    fn pos(w: *Writer, n: NodeId, at_summary: bool, who: u32) Error!u32 {
        if (n == .none) return none;
        const got = try w.pos_index.getOrPut(w.env.gpa, .{ n.int(), @intFromBool(at_summary), who });
        if (!got.found_existing) {
            try w.positions.append(w.env.gpa, .{ .node = n, .at_summary = at_summary, .owner = who });
            got.value_ptr.* = try w.fresh(.node, @intCast(w.positions.items.len - 1));
        }
        return got.value_ptr.*;
    }

    fn owner(w: *Writer, kappas: ?Cond.Kappas) Error!u32 {
        try w.owners.append(w.env.gpa, kappas);
        return @intCast(w.owners.items.len - 1);
    }

    fn fresh(w: *Writer, kind: Kind, id: u32) Error!u32 {
        try w.env.charge.reserve(w.env.gpa, .inspection, 1);
        const r: u32 = @intCast(w.recs.items.len);
        try w.recs.append(w.env.gpa, .{ .kind = kind, .id = id, .rep = r });
        try w.pending.append(w.env.gpa, r);
        return r;
    }

    fn extra(w: *Writer, kind: Kind, e: Extra) Error!u32 {
        try w.extras.append(w.env.gpa, e);
        return w.fresh(kind, @intCast(w.extras.items.len - 1));
    }

    fn tok(w: *Writer, comptime tag: @FieldType(Tok, "tag"), x: u32) Error!void {
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
        for (list) |o| {
            words.clearRetainingCapacity();
            try w.stepWords(o.step, &words);
            var three: [3]u32 = @splat(0);
            @memcpy(three[0..words.items.len], words.items);
            try sorted.append(gpa, .{ .words = three, .n = @intCast(words.items.len), .rec = o.rec });
        }
        try chargeSort(w.env, sorted.items.len);
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
    /// own class), the κ read there, and the positions `proj` makes at the
    /// place's steps that the node's parts do not name.
    fn position(w: *Writer, p: Position) Error!void {
        const gpa = w.env.gpa;
        const shapes = w.env.shapes;
        const conds = w.env.conds;
        const kappas = w.owners.items[p.owner];
        const d = shapes.get(p.node);
        try w.word(@backingInt(d.kind));
        try w.word(@intFromBool(p.at_summary));
        try w.tok(.place, d.place.int());
        var named: std.ArrayList(Over) = .empty;
        defer named.deinit(gpa);
        switch (d.kind) {
            .leaf => try w.ref(.set, d.cells.int()),
            .node, .delta => {
                if (d.kind == .node) try w.ref(.set, d.cells.int()) else try w.tok(.ref, try w.pos(.from(d.a), p.at_summary, p.owner));
                var it = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                while (it.next()) |e| try named.append(gpa, .{ .step = e.step, .rec = try w.pos(e.node, below(p.at_summary, e.step), p.owner) });
                try w.steps(named.items);
            },
            .recast => try w.tok(.ref, try w.pos(.from(d.a), p.at_summary, p.owner)),
            .@"union", .positions => try w.group(&.{ try w.pos(.from(d.a), p.at_summary, p.owner), try w.pos(.from(d.b), p.at_summary, p.owner) }),
        }
        // A union's and a positions node's κ is read from its sides with
        // what is stored there, so the stored is written; any other node's
        // is what is read there.
        if (kappas == null) {
            try w.tok(.ref, none);
        } else if (d.kind == .@"union" or d.kind == .positions) {
            try w.ref(.cond, if (conds.kappaGet(kappas.?, p.node, p.at_summary)) |k| k.int() else none);
        } else try w.ref(.cond, (try conds.kappaOf(gpa, w.env.charge, w.env.view(), kappas.?, p.node, p.at_summary)).int());
        // The positions a read reaches by `proj` beyond the node's parts.
        var made: std.ArrayList(Over) = .empty;
        defer made.deinit(gpa);
        if (d.kind != .leaf and d.kind != .recast) {
            for (w.env.places.steps(d.place).steps) |s| {
                const c = (try shapes.proj(gpa, w.env.account(), w.env.places, w.env.cells, p.node, s)) orelse continue;
                if (shapes.kind(c) == .leaf and shapes.cells(c) == .none) continue;
                if ((d.kind == .node or d.kind == .delta) and shapes.overGet(if (d.kind == .node) d.a else d.b, s) == c) continue;
                try made.append(gpa, .{ .step = s, .rec = try w.pos(c, below(p.at_summary, s), p.owner) });
            }
        }
        try w.steps(made.items);
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
                while (places.pathParent(at) != .none) : (at = places.pathParent(at)) try list.append(gpa, places.pathStep(at));
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
                if (k != Cond.yes and !Cond.Table.fails(k)) try w.ref(.atoms, (try w.env.conds.flat(gpa, w.env.charge, k)).int());
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
                try w.tok(.ref, try w.pos(s.node, false, try w.owner(s.kappa)));
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
            .class => try w.class(.from(id)),
            .group => unreachable,
        }
        const len: u32 = @intCast(w.toks.items.len - start);
        try w.env.charge.reserve(gpa, .inspection, len);
        w.recs.items[r].toks = start;
        w.recs.items[r].len = len;
    }

    fn class(w: *Writer, c: ClassId) Error!void {
        const gpa = w.env.gpa;
        const k = w.sums.get(c);
        const o = try w.owner(k.kappas);
        try w.put(&.{ k.params.len, @as(u32, @intFromBool(k.writes)) | (@as(u32, @intFromBool(k.entry)) << 1) | (@as(u32, @intFromBool(k.refs_top)) << 2), @backingInt(k.origin) });
        try w.tok(.ref, try w.pos(k.res, false, o));
        const uses = try w.owner(null);
        for (w.sums.paramUses(c)) |u| try w.tok(.ref, try w.pos(u, false, uses));
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

    // ---- keys ------------------------------------------------------------------

    fn toksOf(w: *const Writer, r: u32) []const Tok {
        const x = w.recs.items[r];
        return w.toks.items[x.toks..][0..x.len];
    }

    fn isPart(t: Tok) bool {
        return (t.tag == .ref or t.tag == .knot) and t.x != none;
    }

    /// A record's key from its parts' keys: its kind, its words, its places'
    /// encodings, its parts' keys, a group's sorted. A position's parts that
    /// are positions count only as their place in the record (`refine`
    /// follows them).
    fn keyOf(w: *Writer, r: u32, scratch: *std.ArrayList(u64)) Error!u64 {
        var h = std.hash.Wyhash.init(0x6f776e34);
        const local = w.recs.items[r].kind == .node;
        h.update(&.{@backingInt(w.recs.items[r].kind)});
        const ts = w.toksOf(r);
        var i: usize = 0;
        while (i < ts.len) : (i += 1) {
            const t = ts[i];
            const v: u64 = switch (t.tag) {
                .word => t.x,
                .place => try w.placeHash(.from(t.x)),
                .ref, .knot => if (t.x == none) 0 else if (local and w.recs.items[t.x].kind == .node) 1 else w.recs.items[t.x].key,
                .group => {
                    scratch.clearRetainingCapacity();
                    for (ts[i + 1 ..][0..t.x]) |m| try scratch.append(w.env.gpa, if (local) 1 else w.recs.items[m.x].key);
                    try chargeSort(w.env, scratch.items.len);
                    std.mem.sort(u64, scratch.items, {}, std.sort.asc(u64));
                    h.update(std.mem.asBytes(&@as(u64, t.x)));
                    for (scratch.items) |k| h.update(std.mem.asBytes(&k));
                    i += t.x;
                    continue;
                },
            };
            h.update(std.mem.asBytes(&v));
        }
        return h.final();
    }

    /// Every record's key, parts first, by an explicit stack: the records a
    /// position names (cells, conditions) first, then the positions by
    /// `refine`, then the owners (supplies, classes) that name positions.
    fn keys(w: *Writer) Error!void {
        const gpa = w.env.gpa;
        const n = w.recs.items.len;
        const done = try gpa.alloc(bool, n);
        defer gpa.free(done);
        @memset(done, false);
        var scratch: std.ArrayList(u64) = .empty;
        defer scratch.deinit(gpa);
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(gpa);
        for (0..2) |round| {
            for (0..n) |root| {
                const owners_round = w.recs.items[root].kind == .class or w.recs.items[root].kind == .supply;
                if (done[root] or w.recs.items[root].kind == .node or owners_round != (round == 1)) continue;
                try stack.append(gpa, .{ @intCast(root), 0 });
                while (stack.items.len > 0) {
                    const f = &stack.items[stack.items.len - 1];
                    const ts = w.toksOf(f[0]);
                    if (f[1] < ts.len) {
                        const t = ts[f[1]];
                        f[1] += 1;
                        if (isPart(t) and !done[t.x] and w.recs.items[t.x].kind != .node) try stack.append(gpa, .{ t.x, 0 });
                        continue;
                    }
                    const r = f[0];
                    _ = stack.pop();
                    if (done[r]) continue;
                    w.recs.items[r].key = try w.keyOf(r, &scratch);
                    done[r] = true;
                }
            }
            if (round == 0) try w.refine(&scratch);
        }
        try w.components();
    }

    /// Hopcroft's partition refinement over every position of the block
    /// (counting edges, as for lumping, so a union's two sides are one
    /// label), from the positions' own keys. Every decision depends on
    /// block numbers and signatures only, so the final numbers are canonical:
    /// they become the positions' keys, and each block's first member its
    /// record.
    fn refine(w: *Writer, scratch: *std.ArrayList(u64)) Error!void {
        const gpa = w.env.gpa;
        var states: std.ArrayList(u32) = .empty;
        defer states.deinit(gpa);
        for (w.recs.items, 0..) |x, r| if (x.kind == .node) try states.append(gpa, @intCast(r));
        const n = states.items.len;
        if (n == 0) return;
        const state_of = try gpa.alloc(u32, w.recs.items.len);
        defer gpa.free(state_of);
        for (states.items, 0..) |r, i| state_of[r] = @intCast(i);
        // Local keys, and the edges by target: (predecessor, label).
        const local = try gpa.alloc(u64, n);
        defer gpa.free(local);
        var edges: std.ArrayList([3]u32) = .empty;
        defer edges.deinit(gpa);
        for (states.items, 0..) |r, i| {
            local[i] = try w.keyOf(r, scratch);
            // A part's label is its place in the record; a group's parts
            // share the group's (a union's sides are counted, not ordered).
            const ts = w.toksOf(r);
            var k: usize = 0;
            while (k < ts.len) : (k += 1) {
                const t = ts[k];
                const run = if (t.tag == .group) ts[k + 1 ..][0..t.x] else ts[k..][0..1];
                for (run) |m| if (isPart(m) and w.recs.items[m.x].kind == .node) try edges.append(gpa, .{ state_of[m.x], @intCast(i), @intCast(k) });
                if (t.tag == .group) k += t.x;
            }
        }
        try chargeSort(w.env, edges.items.len);
        std.mem.sort([3]u32, edges.items, {}, struct {
            fn less(_: void, a: [3]u32, b: [3]u32) bool {
                return std.mem.order(u32, &a, &b) == .lt;
            }
        }.less);
        const pred_start = try gpa.alloc(u32, n + 1);
        defer gpa.free(pred_start);
        @memset(pred_start, 0);
        for (edges.items) |e| pred_start[e[0] + 1] += 1;
        for (1..n + 1) |i| pred_start[i] += pred_start[i - 1];
        // The partition: `elems` in block runs, the initial blocks in the
        // order of their local keys.
        var p: Partition = try .init(gpa, n);
        defer p.deinit(gpa);
        std.mem.sort(u32, p.elems, local, struct {
            fn less(ks: []const u64, a: u32, b: u32) bool {
                return ks[a] < ks[b];
            }
        }.less);
        for (p.elems, 0..) |e, i| {
            if (i == 0 or local[e] != local[p.elems[i - 1]]) try p.open(gpa, @intCast(i));
            p.block[e] = @intCast(p.first.items.len - 1);
            p.where[e] = @intCast(i);
        }
        try p.close(gpa, @intCast(n));
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(gpa);
        var queued: std.ArrayList(bool) = .empty;
        defer queued.deinit(gpa);
        for (0..p.first.items.len) |b| {
            try work.append(gpa, @intCast(b));
            try queued.append(gpa, true);
        }
        var hits: std.ArrayList([3]u64) = .empty;
        defer hits.deinit(gpa);
        var head: usize = 0;
        while (head < work.items.len) : (head += 1) {
            const s = work.items[head];
            queued.items[s] = false;
            // Every edge into the splitter: (predecessor, label) counted.
            hits.clearRetainingCapacity();
            for (p.elems[p.first.items[s]..p.end.items[s]]) |t| {
                for (edges.items[pred_start[t]..pred_start[t + 1]]) |e| try hits.append(gpa, .{ e[1], e[2], 0 });
            }
            try w.env.charge.reserve(gpa, .inspection, @intCast(hits.items.len + 1));
            if (hits.items.len == 0) continue;
            try chargeSort(w.env, hits.items.len);
            std.mem.sort([3]u64, hits.items, {}, struct {
                fn less(_: void, a: [3]u64, b: [3]u64) bool {
                    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
                }
            }.less);
            // Each predecessor's signature: its (label, count) run hashed.
            var touched: std.ArrayList([3]u64) = .empty;
            defer touched.deinit(gpa);
            var i: usize = 0;
            while (i < hits.items.len) {
                const x = hits.items[i][0];
                var h = std.hash.Wyhash.init(0x5371);
                while (i < hits.items.len and hits.items[i][0] == x) {
                    var j = i;
                    while (j < hits.items.len and hits.items[j][0] == x and hits.items[j][1] == hits.items[i][1]) j += 1;
                    h.update(std.mem.asBytes(&[2]u64{ hits.items[i][1], j - i }));
                    i = j;
                }
                try touched.append(gpa, .{ p.block[x], h.final(), x });
            }
            std.mem.sort([3]u64, touched.items, {}, struct {
                fn less(_: void, a: [3]u64, b: [3]u64) bool {
                    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
                }
            }.less);
            i = 0;
            while (i < touched.items.len) {
                var j = i;
                while (j < touched.items.len and touched.items[j][0] == touched.items[i][0]) j += 1;
                try p.split(gpa, touched.items[i..j], &work, &queued);
                i = j;
            }
        }
        // The canonical numbers, and each block's first member written.
        const firsts = try gpa.alloc(u32, p.first.items.len);
        defer gpa.free(firsts);
        @memset(firsts, none);
        for (states.items, 0..) |r, i| {
            const b = p.block[i];
            if (firsts[b] == none) firsts[b] = r;
            w.recs.items[r].key = b;
            w.recs.items[r].rep = firsts[b];
        }
    }

    // ---- components ---------------------------------------------------------------

    fn repOf(w: *const Writer, r: u32) u32 {
        return if (r == none) none else w.recs.items[r].rep;
    }

    const Frame = struct { r: u32, cursor: u32 };

    /// Tarjan's components over the written records (a merged position is
    /// its block's record), by an explicit stack.
    fn components(w: *Writer) Error!void {
        const gpa = w.env.gpa;
        const n = w.recs.items.len;
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
        // A merged position is in its record's component.
        for (w.recs.items) |*x| x.scc = w.recs.items[x.rep].scc;
    }

    fn selfPart(w: *const Writer, r: u32) bool {
        for (w.toksOf(r)) |t| if (isPart(t) and w.repOf(t.x) == r) return true;
        return false;
    }

    /// A knot's members in written order: by key, every part that is not a
    /// child step after what it names (a post-order walk of those parts from
    /// each member in key order). A member met on its own walk is a cycle no
    /// step closes, which no constructor makes.
    fn order(w: *Writer, s: u32) Error!void {
        const gpa = w.env.gpa;
        const c = w.sccs.items[s];
        const ms = w.members.items[c.first..][0..c.len];
        for (ms) |m| if (w.recs.items[m].kind != .node) return error.AccountingInvariant;
        w.sortByKey(ms);
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        // A member's walk: 0 open, 1 done.
        var state: Ids.FixedDict(1) = .{};
        defer state.deinit(gpa);
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(gpa);
        var out_parts: std.ArrayList(u32) = .empty;
        defer out_parts.deinit(gpa);
        for (ms) |root| {
            const top = try state.getOrPut(gpa, .{root});
            if (top.found_existing) continue;
            top.value_ptr.* = 0;
            try stack.append(gpa, .{ root, 0 });
            while (stack.items.len > 0) {
                const f = &stack.items[stack.items.len - 1];
                out_parts.clearRetainingCapacity();
                try w.parts(f[0], &out_parts, true);
                if (f[1] == out_parts.items.len) {
                    (try state.getOrPut(gpa, .{f[0]})).value_ptr.* = 1;
                    try out.append(gpa, f[0]);
                    _ = stack.pop();
                    continue;
                }
                const target = out_parts.items[f[1]];
                f[1] += 1;
                try w.env.charge.reserve(gpa, .inspection, 1);
                if (w.recs.items[target].scc != s) continue;
                const got = try state.getOrPut(gpa, .{target});
                if (got.found_existing) {
                    if (got.value_ptr.* == 0) return error.AccountingInvariant;
                    continue;
                }
                got.value_ptr.* = 0;
                try stack.append(gpa, .{ target, 0 });
            }
        }
        @memcpy(ms, out.items);
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
                    w.sortByKey(out.items[start..]);
                    i += t.x;
                },
            }
        }
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
            // A knot's own members are not its parts.
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
        try abs.append(gpa, @backingInt(w.recs.items[r].kind));
        try rel.append(gpa, @backingInt(w.recs.items[r].kind));
        const ts = w.toksOf(r);
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
                    try chargeSort(w.env, g.items.len);
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

    /// Write a closed component: one record, or a knot's group; a record
    /// with the words of one written before is that one. A position merged
    /// into its block's record must spell that record: equal local keys of
    /// different positions (a collision) are refused.
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
        for (ms, 0..) |m, i| w.recs.items[m].ordinal = base + @as(u32, @intCast(i));
        if (c.knot) try abs.appendSlice(gpa, &.{ @backingInt(Kind.group), c.len });
        if (c.knot) try rel.appendSlice(gpa, &.{ @backingInt(Kind.group), c.len });
        for (ms) |m| try w.spell(m, s, base, &abs, &rel);
        try w.env.charge.reserve(gpa, .inspection, @intCast(abs.items.len));
        const key = std.mem.sliceAsBytes(rel.items);
        if (w.seen.get(key)) |found| {
            for (ms, 0..) |m, i| w.recs.items[m].ordinal = found + @as(u32, @intCast(i));
            return;
        }
        try w.seen.put(gpa, try w.seen_keys.allocator().dupe(u8, key), base);
        w.next += c.len;
        w.units += 1;
        try w.out.appendSlice(gpa, abs.items);
    }

    /// Every merged position spells its record's words, checked once the
    /// table is written.
    fn check(w: *Writer) Error!void {
        const gpa = w.env.gpa;
        var a: std.ArrayList(u32) = .empty;
        defer a.deinit(gpa);
        var b: std.ArrayList(u32) = .empty;
        defer b.deinit(gpa);
        var scratch: std.ArrayList(u32) = .empty;
        defer scratch.deinit(gpa);
        for (w.recs.items, 0..) |x, r| {
            if (x.kind != .node or x.rep == r) continue;
            a.clearRetainingCapacity();
            b.clearRetainingCapacity();
            scratch.clearRetainingCapacity();
            try w.spell(@intCast(r), none, 0, &a, &scratch);
            scratch.clearRetainingCapacity();
            try w.spell(x.rep, none, 0, &b, &scratch);
            if (!std.mem.eql(u32, a.items, b.items)) return error.AccountingInvariant;
        }
    }
};

/// A refinable partition: `elems` in block runs `[first, end)`, each
/// element's block and index.
const Partition = struct {
    elems: []u32,
    block: []u32,
    where: []u32,
    first: std.ArrayList(u32) = .empty,
    end: std.ArrayList(u32) = .empty,

    fn init(gpa: Allocator, n: usize) Error!Partition {
        const p: Partition = .{ .elems = try gpa.alloc(u32, n), .block = try gpa.alloc(u32, n), .where = try gpa.alloc(u32, n) };
        for (p.elems, 0..) |*e, i| e.* = @intCast(i);
        return p;
    }

    fn deinit(p: *Partition, gpa: Allocator) void {
        gpa.free(p.elems);
        gpa.free(p.block);
        gpa.free(p.where);
        p.first.deinit(gpa);
        p.end.deinit(gpa);
    }

    fn open(p: *Partition, gpa: Allocator, at: u32) Error!void {
        if (p.first.items.len > 0) try p.end.append(gpa, at);
        try p.first.append(gpa, at);
    }

    fn close(p: *Partition, gpa: Allocator, at: u32) Error!void {
        try p.end.append(gpa, at);
    }

    fn swap(p: *Partition, i: u32, j: u32) void {
        const a = p.elems[i];
        const b = p.elems[j];
        p.elems[i] = b;
        p.elems[j] = a;
        p.where[b] = i;
        p.where[a] = j;
    }

    /// Split one block by its touched members, `(block, signature, element)`
    /// sorted by signature: the untouched members keep the block (else the
    /// first signature's do), each other signature a new block in signature
    /// order. Every part is queued if the block was, else all but the
    /// largest (the first of equal sizes in that order).
    fn split(p: *Partition, gpa: Allocator, touched: []const [3]u64, work: *std.ArrayList(u32), queued: *std.ArrayList(bool)) Error!void {
        const b: u32 = @intCast(touched[0][0]);
        const size = p.end.items[b] - p.first.items[b];
        if (touched.len == size) {
            var same = true;
            for (touched) |t| same = same and t[1] == touched[0][1];
            if (same) return;
        }
        // The touched members to the end of the run, in signature order.
        var tail = p.end.items[b];
        var k = touched.len;
        while (k > 0) {
            k -= 1;
            tail -= 1;
            p.swap(p.where[@intCast(touched[k][2])], tail);
        }
        const Part = struct { start: u32, end: u32 };
        var parts: std.ArrayList(Part) = .empty;
        defer parts.deinit(gpa);
        if (tail > p.first.items[b]) try parts.append(gpa, .{ .start = p.first.items[b], .end = tail });
        var at = tail;
        var i: usize = 0;
        while (i < touched.len) {
            var j = i;
            while (j < touched.len and touched[j][1] == touched[i][1]) j += 1;
            try parts.append(gpa, .{ .start = at, .end = at + @as(u32, @intCast(j - i)) });
            at += @intCast(j - i);
            i = j;
        }
        var largest: usize = 0;
        for (parts.items, 0..) |q, x| if (q.end - q.start > parts.items[largest].end - parts.items[largest].start) {
            largest = x;
        };
        const was = queued.items[b];
        for (parts.items, 0..) |q, x| {
            const id: u32 = if (x == 0) b else @intCast(p.first.items.len);
            if (x == 0) {
                p.end.items[b] = q.end;
            } else {
                try p.first.append(gpa, q.start);
                try p.end.append(gpa, q.end);
                try queued.append(gpa, false);
                for (p.elems[q.start..q.end]) |e| p.block[e] = id;
            }
            if ((was or x != largest) and !queued.items[id]) {
                queued.items[id] = true;
                try work.append(gpa, id);
            }
        }
    }
};
