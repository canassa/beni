//! L11: the ownership block (`docs/design/ownership-v2.md` §3.6), minimal:
//! classes to words and back, with places written structurally. S2b builds
//! the class table and its records — a header (`OWN2`, the version), the
//! place table, the record table, the root classes — and nothing of S6's:
//! no lazy directory, no cache section, no traversal marks.
//!
//! **Every record once.** A label, a path, a cell, a split, a cell set, an
//! atom set, a condition, an atom, a shape node, a κ entry and a κ map, a
//! supply, a keep, a slot and a class are each one record of the table,
//! and every other record names it by its ordinal. A record's ordinal is
//! after its parts' (its parts are written first), but in a knot: the
//! nodes of a cycle (`widen`'s, `map`'s) are one `group` record whose
//! members are numbered together, so a child step may name any member and
//! every other part of a member names an earlier one — every cycle passes
//! through a step, as every cycle the constructors can make does.
//!
//! **No session id in the bytes.** A place is its kind, its head and its
//! children (a head, a field's rank — a use mark's too — through the
//! writer's `Names`), a shared value's declaration its qualified name and
//! ordinal. Instruction ids (a label's, a site's) are the module's own, and
//! a reader puts them in a namespace of its own (`Remap.inst`).
//!
//! **The order is the structure's.** Each record has a 64-bit key: a hash
//! of its own words, its places' canonical encodings and its parts' keys (a
//! set's, a union's and a group of members' sorted). A knot's keys are
//! partition refinement over the knot (Moore's: rounds until the partition
//! is stable), so two members are one key exactly when they are
//! bisimilar, and bisimilar members are one record. The table is then a
//! post-order walk from the classes, a record's parts in their written
//! order and a set's by key, so the ordinals, the place numbers and the
//! bytes follow from the structure alone, never from the order the tables
//! were built in. Two records with equal words are one record; equal keys
//! of different records (a 64-bit collision) are the one case the build
//! order can show, and in a knot a collision is refused, never merged.
//!
//! **κ maps.** A class's map and a supply's are each written as the stored
//! κ of every node its values reach (`kentry` records), not as the map's
//! own tree; entries for nodes a block merged are joined by the reader
//! (κ only grows, §2.12).
//!
//! **Reading.** `read` decodes into tables of its own first, against the
//! caller's allowance and the room left in its place table, and charges
//! that work to the caller once. A block that does not decode is no block
//! (null, R-5.7.4) and the caller's tables are untouched; one that exceeds
//! a limit is the caller's `OwnershipLimit`. Only then is it built in the
//! caller's tables, uncharged, where it cannot meet a limit; its places are
//! a namespace of their own (`Place.Table.ofBlock`), so it meets nothing of
//! the module's. A split that exists with another condition is
//! `error.BlockConflict`, never a silent change of meaning.
//!
//! **Cost.** Every record a class reaches is reserved on the writer's and
//! the reader's charge before it is read or made (§4.1); a sort of n
//! members is charged n·⌈log₂ n⌉; a knot of k nodes costs its rounds,
//! at most k, times its size, each round charged.
//!
//! Obligations kept here: none (a faithful encoding: what is read is what
//! was written).

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
pub const version: u32 = 3;

const none: u32 = Ids.none_int;

/// A record's kind, which is its tag in the table; `group` opens a knot.
const Kind = enum(u8) { label, path, cell, split, set, atoms, cond, atom, node, kentry, kmap, supply, keep, slot, class, group };

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

/// A stored κ: the node, its position class, the condition.
const KEntry = struct { node: NodeId, at_summary: bool, cond: CondId };

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
/// `knot` for a node's child step, which may name its own knot), or the
/// count of the unordered parts that follow.
const Tok = struct { tag: enum(u8) { word, place, ref, knot, group }, x: u32 };

const Rec = struct {
    kind: Kind,
    /// The table id, or the index of `extras` for a record of a class's
    /// own (a supply, a keep, a slot, a κ map or entry).
    id: u32,
    toks: u32 = 0,
    len: u32 = 0,
    key: u64 = 0,
    scc: u32 = none,
    /// The member a knot's bisimilar member is written as.
    rep: u32,
    ordinal: u32 = none,
};

const Extra = union(enum) {
    supply: Summary.Supply,
    keep: Summary.Keep,
    slot: Summary.Slot,
    kentry: KEntry,
    /// A run of `entries`.
    kmap: [2]u32,
};

/// A strongly connected component of the records: one record, or a knot.
const Scc = struct { first: u32, len: u32, all: u32, knot: bool, state: enum(u8) { new, open, done } = .new };

const Writer = struct {
    env: Env,
    sums: *Summary.Table,
    names: Names,
    recs: std.ArrayList(Rec) = .empty,
    /// `(kind, table id)` → record.
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    toks: std.ArrayList(Tok) = .empty,
    extras: std.ArrayList(Extra) = .empty,
    entries: std.ArrayList(u32) = .empty,
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
        w.toks.deinit(gpa);
        w.extras.deinit(gpa);
        w.entries.deinit(gpa);
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

    /// The child map of a node or a delta, in the order of the steps'
    /// words: `n, (step, child)×n`.
    fn overs(w: *Writer, root: u32) Error!void {
        const gpa = w.env.gpa;
        const Entry = struct { words: [3]u32, n: u8, node: NodeId };
        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(gpa);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        var it = w.env.shapes.overEntries(root);
        while (it.next()) |e| {
            words.clearRetainingCapacity();
            try w.stepWords(e.step, &words);
            var three: [3]u32 = @splat(0);
            @memcpy(three[0..words.items.len], words.items);
            try list.append(gpa, .{ .words = three, .n = @intCast(words.items.len), .node = e.node });
        }
        try chargeSort(w.env, list.items.len);
        std.mem.sort(Entry, list.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u32, &a.words, &b.words) == .lt;
            }
        }.less);
        try w.word(@intCast(list.items.len));
        for (list.items) |e| {
            try w.put(e.words[0..e.n]);
            try w.tok(.knot, try w.rec(.node, e.node.int()));
        }
    }

    /// The κ map `kappas` holds for what `roots` reach: one entry per
    /// stored κ of a reached node at its position class, or `none`.
    fn kmap(w: *Writer, kappas: Cond.Kappas, roots: []const NodeId) Error!u32 {
        if (kappas == .none) return none;
        const gpa = w.env.gpa;
        const shapes = w.env.shapes;
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(gpa);
        for (roots) |n| if (n != .none) try stack.append(gpa, .{ n.int(), 0 });
        const first: u32 = @intCast(w.entries.items.len);
        while (stack.pop()) |pair| {
            if ((try seen.getOrPut(gpa, .{(pair[0] << 1) | pair[1]})).found_existing) continue;
            try w.env.charge.reserve(gpa, .inspection, 1);
            const n: NodeId = .from(pair[0]);
            const at_summary = pair[1] == 1;
            if (w.env.conds.kappaGet(kappas, n, at_summary)) |k| try w.entries.append(gpa, try w.extra(.kentry, .{ .kentry = .{ .node = n, .at_summary = at_summary, .cond = k } }));
            const d = shapes.get(n);
            switch (d.kind) {
                .leaf => {},
                .node, .delta => {
                    if (d.kind == .delta) try stack.append(gpa, .{ d.a, pair[1] });
                    var it = shapes.overEntries(if (d.kind == .node) d.a else d.b);
                    while (it.next()) |e| try stack.append(gpa, .{ e.node.int(), @intFromBool(at_summary or e.step.kind == .elem or e.step.kind == .level) });
                },
                .recast => try stack.append(gpa, .{ d.a, pair[1] }),
                .@"union", .positions => try stack.appendSlice(gpa, &.{ .{ d.a, pair[1] }, .{ d.b, pair[1] } }),
            }
        }
        const len: u32 = @intCast(w.entries.items.len - first);
        if (len == 0) return none;
        return w.extra(.kmap, .{ .kmap = .{ first, len } });
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
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(gpa);
                var at: PathId = .from(id);
                while (places.pathParent(at) != .none) : (at = places.pathParent(at)) try steps.append(gpa, places.pathStep(at));
                try w.word(@intCast(steps.items.len));
                try w.tok(.place, places.pathPlace(at).int());
                var i = steps.items.len;
                while (i > 0) : (i -= 1) try w.step(steps.items[i - 1]);
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
                        try w.word(d.a);
                        // A written field's rank is a field rank like a step's.
                        try w.word(if (d.a == @backingInt(Cell.Mark.field)) w.names.place.field(w.names.place.ctx, d.b) else d.b);
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
            .node => {
                const d = w.env.shapes.get(.from(id));
                try w.word(@backingInt(d.kind));
                try w.tok(.place, d.place.int());
                switch (d.kind) {
                    .leaf => try w.ref(.set, d.cells.int()),
                    .node => {
                        try w.ref(.set, d.cells.int());
                        try w.overs(d.a);
                    },
                    .delta => {
                        try w.ref(.node, d.a);
                        try w.overs(d.b);
                    },
                    .recast => try w.ref(.node, d.a),
                    .@"union", .positions => try w.group(&.{ try w.rec(.node, d.a), try w.rec(.node, d.b) }),
                }
            },
            .kentry => {
                const e = w.extras.items[id].kentry;
                try w.ref(.node, e.node.int());
                try w.word(@intFromBool(e.at_summary));
                try w.ref(.cond, e.cond.int());
            },
            .kmap => {
                const run = w.extras.items[id].kmap;
                const list = try gpa.dupe(u32, w.entries.items[run[0]..][0..run[1]]);
                defer gpa.free(list);
                try w.group(list);
            },
            .supply => {
                const s = w.extras.items[id].supply;
                try w.put(&.{ s.k, @as(u32, @intFromBool(s.owned)) | (@as(u32, @intFromBool(s.taken)) << 1) });
                try w.ref(.label, s.label.int());
                // The handed value under its own snapshot.
                try w.tok(.ref, try w.kmap(s.kappa, &.{s.node}));
                try w.ref(.node, s.node.int());
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
        var roots: std.ArrayList(NodeId) = .empty;
        defer roots.deinit(gpa);
        try roots.append(gpa, k.res);
        try roots.appendSlice(gpa, w.sums.paramUses(c));
        try w.tok(.ref, try w.kmap(k.kappas, roots.items));
        try w.put(&.{ k.params.len, @as(u32, @intFromBool(k.writes)) | (@as(u32, @intFromBool(k.entry)) << 1) | (@as(u32, @intFromBool(k.refs_top)) << 2), @backingInt(k.origin) });
        try w.ref(.node, k.res.int());
        for (w.sums.paramUses(c)) |u| try w.ref(.node, u.int());
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

    fn keyOfPart(w: *const Writer, r: u32) u64 {
        return if (r == none) 0 else w.recs.items[r].key;
    }

    /// A record's key from its parts' current keys: its kind, its words, its
    /// places' encodings, its parts' keys, a group's sorted.
    fn keyOf(w: *Writer, r: u32, scratch: *std.ArrayList(u64)) Error!u64 {
        var h = std.hash.Wyhash.init(0x6f776e33);
        h.update(&.{@backingInt(w.recs.items[r].kind)});
        const ts = w.toksOf(r);
        var i: usize = 0;
        while (i < ts.len) : (i += 1) {
            const t = ts[i];
            const v: u64 = switch (t.tag) {
                .word => t.x,
                .place => try w.placeHash(.from(t.x)),
                .ref, .knot => w.keyOfPart(t.x),
                .group => {
                    scratch.clearRetainingCapacity();
                    for (ts[i + 1 ..][0..t.x]) |m| try scratch.append(w.env.gpa, w.keyOfPart(m.x));
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

    const Frame = struct { r: u32, cursor: u32 };

    /// Tarjan's components over the records, by an explicit stack, each
    /// keyed as it closes: its parts' components closed before it.
    fn keys(w: *Writer) Error!void {
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
        var scratch: std.ArrayList(u64) = .empty;
        defer scratch.deinit(gpa);
        for (0..n) |root| {
            if (index[root] != none) continue;
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
                    if ((t.tag != .ref and t.tag != .knot) or t.x == none) continue;
                    const c = t.x;
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
                    const p = call.items[call.items.len - 1].r;
                    low[p] = @min(low[p], low[r]);
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
                try w.sccs.append(gpa, .{ .first = first, .len = len, .all = len, .knot = len > 1 or w.selfPart(r) });
                try w.close(@intCast(w.sccs.items.len - 1), &scratch);
            }
        }
    }

    fn selfPart(w: *const Writer, r: u32) bool {
        for (w.toksOf(r)) |t| if ((t.tag == .ref or t.tag == .knot) and t.x == r) return true;
        return false;
    }

    fn distinct(w: *Writer, ms: []const u32) Error!usize {
        const ks = try w.env.gpa.alloc(u64, ms.len);
        defer w.env.gpa.free(ks);
        for (ms, ks) |m, *k| k.* = w.recs.items[m].key;
        try chargeSort(w.env, ks.len);
        std.mem.sort(u64, ks, {}, std.sort.asc(u64));
        var d: usize = 0;
        for (ks, 0..) |k, i| {
            if (i == 0 or k != ks[i - 1]) d += 1;
        }
        return d;
    }

    /// Key a closed component. A knot: rounds of refinement until its
    /// partition is stable, its bisimilar members merged, and its members
    /// ordered by key with every part but a child step after what it names.
    fn close(w: *Writer, s: u32, scratch: *std.ArrayList(u64)) Error!void {
        const gpa = w.env.gpa;
        const c = w.sccs.items[s];
        const ms = w.members.items[c.first..][0..c.len];
        if (!c.knot) {
            w.recs.items[ms[0]].key = try w.keyOf(ms[0], scratch);
            return;
        }
        // Only a shape node can be on a cycle; anything else is a table
        // the constructors cannot make.
        for (ms) |m| if (w.recs.items[m].kind != .node) return error.AccountingInvariant;
        const next = try gpa.alloc(u64, ms.len);
        defer gpa.free(next);
        var classes: usize = 1;
        while (true) {
            for (ms, next) |m, *k| k.* = std.hash.Wyhash.hash(w.recs.items[m].key, std.mem.asBytes(&try w.keyOf(m, scratch)));
            for (ms, next) |m, k| w.recs.items[m].key = k;
            const now = try w.distinct(ms);
            if (now == classes) break;
            classes = now;
        }
        // Bisimilar members are one: the first of each key.
        const Cmp = struct {
            w: *const Writer,
            fn less(ctx: @This(), a: u32, b: u32) bool {
                return ctx.w.recs.items[a].key < ctx.w.recs.items[b].key;
            }
        };
        std.mem.sort(u32, ms, Cmp{ .w = w }, Cmp.less);
        var reps: std.ArrayList(u32) = .empty;
        defer reps.deinit(gpa);
        for (ms, 0..) |m, i| {
            if (i > 0 and w.recs.items[m].key == w.recs.items[ms[i - 1]].key) {
                w.recs.items[m].rep = w.recs.items[ms[i - 1]].rep;
            } else try reps.append(gpa, m);
        }
        // Every part but a child step after what it names: a post-order
        // walk of those parts from each member in key order, so the order
        // is the structure's. A member met on its own walk is a cycle no
        // step closes, which no constructor makes.
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        // A member's walk: 0 open, 1 done.
        var state: Ids.FixedDict(1) = .{};
        defer state.deinit(gpa);
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(gpa);
        for (reps.items) |root| {
            const top = try state.getOrPut(gpa, .{root});
            if (top.found_existing) continue;
            top.value_ptr.* = 0;
            try stack.append(gpa, .{ root, 0 });
            while (stack.items.len > 0) {
                const f = &stack.items[stack.items.len - 1];
                const ts = w.toksOf(f[0]);
                if (f[1] == ts.len) {
                    (try state.getOrPut(gpa, .{f[0]})).value_ptr.* = 1;
                    try order.append(gpa, f[0]);
                    _ = stack.pop();
                    continue;
                }
                const t = ts[f[1]];
                f[1] += 1;
                try w.env.charge.reserve(gpa, .inspection, 1);
                if (t.tag != .ref or t.x == none or w.recs.items[t.x].scc != s) continue;
                const target = w.recs.items[t.x].rep;
                const got = try state.getOrPut(gpa, .{target});
                if (got.found_existing) {
                    if (got.value_ptr.* == 0) return error.AccountingInvariant;
                    continue;
                }
                got.value_ptr.* = 0;
                try stack.append(gpa, .{ target, 0 });
            }
        }
        const k = order.items.len;
        // The written members first, in order; the merged ones after them,
        // unwritten, for `emit` to check.
        var merged: std.ArrayList(u32) = .empty;
        defer merged.deinit(gpa);
        for (ms) |m| if (w.recs.items[m].rep != m) try merged.append(gpa, m);
        @memcpy(ms[0..k], order.items);
        @memcpy(ms[k..], merged.items);
        w.sccs.items[s].len = @intCast(k);
    }

    fn allMembers(w: *const Writer, s: u32) []const u32 {
        const c = w.sccs.items[s];
        return w.members.items[c.first..][0..c.all];
    }

    // ---- emitting -------------------------------------------------------------

    fn ordinalOf(w: *const Writer, r: u32) u32 {
        return if (r == none) none else w.recs.items[w.recs.items[r].rep].ordinal;
    }

    /// A record's parts in written order, a group's by key.
    fn parts(w: *Writer, r: u32, out: *std.ArrayList(u32)) Error!void {
        const gpa = w.env.gpa;
        const ts = w.toksOf(r);
        var i: usize = 0;
        while (i < ts.len) : (i += 1) {
            const t = ts[i];
            switch (t.tag) {
                .word, .place => {},
                .ref, .knot => if (t.x != none) try out.append(gpa, w.recs.items[t.x].rep),
                .group => {
                    const start = out.items.len;
                    for (ts[i + 1 ..][0..t.x]) |m| try out.append(gpa, w.recs.items[m.x].rep);
                    w.sortByKey(out.items[start..]);
                    i += t.x;
                },
            }
        }
    }

    fn sortByKey(w: *const Writer, rs: []u32) void {
        std.mem.sort(u32, rs, w, struct {
            fn less(ww: *const Writer, a: u32, b: u32) bool {
                const ka = ww.recs.items[a].key;
                const kb = ww.recs.items[b].key;
                return ka < kb or (ka == kb and ww.recs.items[a].ordinal < ww.recs.items[b].ordinal);
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
            try w.parts(m, kids);
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
                    for (ts[i + 1 ..][0..t.x]) |m| try g.append(gpa, w.recs.items[m.x].rep);
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
    /// with the words of one written before is that one.
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
        if (c.knot) {
            for (ms, 0..) |m, i| w.recs.items[m].ordinal = base + @as(u32, @intCast(i));
            try abs.appendSlice(gpa, &.{ @backingInt(Kind.group), c.len });
            try rel.appendSlice(gpa, &.{ @backingInt(Kind.group), c.len });
            const marks = try gpa.alloc(usize, ms.len + 1);
            defer gpa.free(marks);
            for (ms, 0..) |m, i| {
                marks[i] = rel.items.len;
                try w.spell(m, s, base, &abs, &rel);
            }
            marks[ms.len] = rel.items.len;
            // A merged member must be its representative's record: equal
            // keys of different records in one knot are refused.
            var other: std.ArrayList(u32) = .empty;
            defer other.deinit(gpa);
            var scratch: std.ArrayList(u32) = .empty;
            defer scratch.deinit(gpa);
            const all = w.allMembers(s);
            for (all) |x| {
                const rep = w.recs.items[x].rep;
                if (rep == x) continue;
                other.clearRetainingCapacity();
                scratch.clearRetainingCapacity();
                try w.spell(x, s, base, &scratch, &other);
                const i = w.recs.items[rep].ordinal - base;
                if (!std.mem.eql(u32, other.items, rel.items[marks[i]..marks[i + 1]])) return error.AccountingInvariant;
            }
        } else try w.spell(ms[0], s, base, &abs, &rel);
        try w.env.charge.reserve(gpa, .inspection, @intCast(abs.items.len));
        const key = std.mem.sliceAsBytes(rel.items);
        if (w.seen.get(key)) |found| {
            for (ms, 0..) |m, i| w.recs.items[m].ordinal = found + @as(u32, @intCast(i));
            return;
        }
        try w.seen.put(gpa, try w.seen_keys.allocator().dupe(u8, key), base);
        if (!c.knot) w.recs.items[ms[0]].ordinal = base;
        w.next += c.len;
        w.units += 1;
        try w.out.appendSlice(gpa, abs.items);
    }
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// The classes of a block, built in `env`'s tables and appended to `out`;
/// null when the words are not a block this version wrote. The block is
/// decoded first into tables of its own, against the caller's allowance
/// and the room in its place table, and that work is charged to the
/// caller once: a block that does not decode leaves `env`'s tables and
/// `out` as they were, and one past a limit is `error.OwnershipLimit`
/// before any of them is touched.
pub fn read(env: Env, sums: *Summary.Table, words: []const u32, remap: Remap, out: *std.ArrayList(ClassId)) ReadError!?void {
    const gpa = env.gpa;
    const owner = env.account();
    {
        var t: Scratch = .{};
        try t.init(gpa, env);
        defer t.deinit(gpa);
        var trial: std.ArrayList(ClassId) = .empty;
        defer trial.deinit(gpa);
        var r: Reader = .{ .env = t.env(gpa), .sums = &t.sums, .words = words, .remap = remap };
        defer r.deinit();
        const failed: ?Reader.Failure = if (r.all(&trial)) null else |err| err;
        if (failed) |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        try env.charge.reserve(gpa, .inspection, t.account.growth);
        if (failed) |e| {
            if (e != error.OwnershipLimit) return null;
            // The trial met the caller's limit: the caller's refusal.
            if (owner.failed == null) owner.failed = t.account.failed;
            return error.OwnershipLimit;
        }
    }
    // The commit: the work is paid for, and its limits were the trial's.
    var paid: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
    defer paid.deinit(gpa);
    const mark = out.items.len;
    var r: Reader = .{ .env = .{ .gpa = gpa, .charge = .growth(&paid), .places = env.places, .cells = env.cells, .shapes = env.shapes, .conds = env.conds }, .sums = sums, .words = words, .remap = remap };
    defer r.deinit();
    r.all(out) catch |err| {
        out.shrinkRetainingCapacity(mark);
        return switch (err) {
            // The trial decoded it: only the reader's own tables can make
            // it fail now.
            error.Malformed => error.BlockConflict,
            else => |e| e,
        };
    };
}

/// Tables of their own for a trial read, with the caller's allowance left
/// and the room left in its place table.
const Scratch = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    conds: Cond.Table = undefined,
    sums: Summary.Table = .{},
    account: Ids.Account = .{},

    fn init(t: *Scratch, gpa: Allocator, caller: Env) Error!void {
        const a = caller.account();
        t.account.allowance = if (caller.charge.lane == null) a.allowance -| a.growth else std.math.maxInt(u32);
        t.places.limits = caller.places.limits;
        t.places.limits.type_places -|= caller.places.count();
        t.conds = try Cond.Table.init(gpa, .growth(&t.account));
    }

    fn deinit(t: *Scratch, gpa: Allocator) void {
        t.places.deinit(gpa);
        t.cells.deinit(gpa);
        t.shapes.deinit(gpa);
        t.conds.deinit(gpa);
        t.sums.deinit(gpa);
        t.account.deinit(gpa);
    }

    fn env(t: *Scratch, gpa: Allocator) Env {
        return .{ .gpa = gpa, .charge = .growth(&t.account), .places = &t.places, .cells = &t.cells, .shapes = &t.shapes, .conds = &t.conds };
    }
};

const Reader = struct {
    env: Env,
    sums: *Summary.Table,
    words: []const u32,
    remap: Remap,
    at: usize = 0,
    /// The block's places, in local order, once each is in `env.places`.
    places: std.ArrayList(PlaceId) = .empty,
    /// Where each local place's record starts in `words`.
    place_at: std.ArrayList(u32) = .empty,
    /// Each record's value (a table id, or an index of the lists below) and
    /// kind, by ordinal.
    vals: std.ArrayList(u32) = .empty,
    kinds: std.ArrayList(Kind) = .empty,
    supplies: std.ArrayList(Summary.Supply) = .empty,
    keeps: std.ArrayList(Summary.Keep) = .empty,
    slots: std.ArrayList(Summary.Slot) = .empty,
    entries: std.ArrayList(KEntry) = .empty,
    /// The ordinals a part may name (below `low`), and a child step (below
    /// `high`: in a knot, any member).
    low: usize = 0,
    high: usize = 0,

    const Failure = ReadError || error{Malformed};

    fn deinit(r: *Reader) void {
        const gpa = r.env.gpa;
        r.places.deinit(gpa);
        r.place_at.deinit(gpa);
        r.vals.deinit(gpa);
        r.kinds.deinit(gpa);
        r.supplies.deinit(gpa);
        r.keeps.deinit(gpa);
        r.slots.deinit(gpa);
        r.entries.deinit(gpa);
    }

    fn get(r: *Reader) Failure!u32 {
        if (r.at >= r.words.len) return error.Malformed;
        r.at += 1;
        return r.words[r.at - 1];
    }

    fn flag(r: *Reader, max: u32) Failure!u32 {
        const x = try r.get();
        if (x > max) return error.Malformed;
        return x;
    }

    /// A count of what follows, each at least one word.
    fn count(r: *Reader) Failure!u32 {
        const n = try r.get();
        if (n > r.words.len - r.at) return error.Malformed;
        return n;
    }

    fn enumOf(comptime E: type, x: u32) Failure!E {
        if (x > std.math.maxInt(@typeInfo(E).@"enum".tag_type)) return error.Malformed;
        return std.enums.fromInt(E, x) orelse error.Malformed;
    }

    /// A part of `kind` below `limit`, or null for `none`.
    fn refBelow(r: *Reader, kind: Kind, limit: usize) Failure!?u32 {
        const o = try r.get();
        if (o == none) return null;
        if (o >= limit or r.kinds.items[o] != kind) return error.Malformed;
        return r.vals.items[o];
    }

    fn ref(r: *Reader, kind: Kind) Failure!?u32 {
        return r.refBelow(kind, r.low);
    }

    fn need(r: *Reader, kind: Kind) Failure!u32 {
        return (try r.ref(kind)) orelse error.Malformed;
    }

    fn opt(r: *Reader, comptime T: type, kind: Kind) Failure!T {
        return if (try r.ref(kind)) |v| .from(v) else .none;
    }

    /// A step's words, checked: a payload a step can hold, a field's rank
    /// the account takes.
    fn stepFrom(r: *Reader, kind: Place.StepKind, a: u32, b: u32) Failure!Step {
        return switch (kind) {
            .field => Step.field(r.env.account(), r.remap.place.field(r.remap.place.ctx, a)) catch error.Malformed,
            .ctor_arg => r.env.places.ctorStep(r.env.gpa, r.env.account(), a, b) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Malformed,
            },
            else => if (a > std.math.maxInt(@FieldType(Step, "payload"))) error.Malformed else .{ .kind = kind, .payload = @intCast(a) },
        };
    }

    fn stepOf(r: *Reader) Failure!Step {
        const kind = try enumOf(Place.StepKind, try r.get());
        const a = try r.get();
        const b = if (kind == .ctor_arg) try r.get() else 0;
        return r.stepFrom(kind, a, b);
    }

    fn placeOf(r: *Reader) Failure!PlaceId {
        const i = try r.get();
        if (i >= r.places.items.len) return error.Malformed;
        return r.places.items[i];
    }

    fn all(r: *Reader, out: *std.ArrayList(ClassId)) Failure!void {
        const gpa = r.env.gpa;
        if (try r.get() != magic or try r.get() != version) return error.Malformed;
        const n_places = try r.count();
        // Each place record, checked whole before any place is made: kind,
        // head, holds, n, then n × (step, child).
        var i: u32 = 0;
        while (i < n_places) : (i += 1) {
            try r.env.charge.reserve(gpa, .inspection, 1);
            try r.place_at.append(gpa, @intCast(r.at));
            if (r.at + 4 > r.words.len) return error.Malformed;
            _ = try enumOf(Place.Kind, r.words[r.at]);
            if (r.words[r.at + 2] > 0x7f) return error.Malformed;
            const n = r.words[r.at + 3];
            r.at += 4;
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                _ = try r.stepOf();
                if (try r.get() >= n_places) return error.Malformed;
            }
        }
        var failed: ?Failure = null;
        var source: Describe = .{ .r = r, .failed = &failed };
        // The block's places are a namespace of their own in the reader's
        // table (§3.6's re-interning onto a module's own graph is S6's).
        r.env.places.beginBlock();
        i = 0;
        while (i < n_places) : (i += 1) {
            try r.places.append(gpa, try r.env.places.ofBlock(gpa, r.env.account(), .{ .ctx = &source, .describe = Describe.describe }, i));
            if (failed) |e| return e;
        }
        const units = try r.count();
        i = 0;
        while (i < units) : (i += 1) try r.unit();
        const n_classes = try r.count();
        i = 0;
        while (i < n_classes) : (i += 1) {
            r.low = r.vals.items.len;
            try out.append(gpa, .from(try r.need(.class)));
        }
        if (r.at != r.words.len) return error.Malformed;
    }

    const Describe = struct {
        r: *Reader,
        failed: *?Failure,

        fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
            const d: *Describe = @ptrCast(@alignCast(ctx));
            const r = d.r;
            var at: usize = r.place_at.items[v];
            const k: Place.Kind = @fromBackingInt(@intCast(r.words[at]));
            const head = r.words[at + 1];
            const n = r.words[at + 3];
            at += 4;
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                const kind: Place.StepKind = @fromBackingInt(@intCast(r.words[at]));
                const a = r.words[at + 1];
                const b = if (kind == .ctor_arg) r.words[at + 2] else 0;
                at += if (kind == .ctor_arg) 3 else 2;
                const s = r.stepFrom(kind, a, b) catch |e| blk: {
                    d.failed.* = e;
                    break :blk Step.elem;
                };
                try out.append(r.env.gpa, .{ .step = s, .@"var" = r.words[at] });
                at += 1;
            }
            return .{ .kind = k, .head = if (k == .tuple or k == .record) head else r.remap.place.head(r.remap.place.ctx, head) };
        }
    };

    /// One record, or a knot: its members made first, every one a node no
    /// constructor interns, then each read and tied.
    fn unit(r: *Reader) Failure!void {
        const gpa = r.env.gpa;
        try r.env.charge.reserve(gpa, .inspection, 1);
        const kind = try enumOf(Kind, try r.get());
        if (kind != .group) {
            r.low = r.vals.items.len;
            r.high = r.low;
            const v = try r.record(kind);
            try r.vals.append(gpa, v);
            try r.kinds.append(gpa, kind);
            return;
        }
        const k = try r.count();
        if (k == 0) return error.Malformed;
        const base = r.vals.items.len;
        var i: u32 = 0;
        while (i < k) : (i += 1) {
            try r.vals.append(gpa, (try r.env.shapes.knot(gpa, r.env.account())).int());
            try r.kinds.append(gpa, .node);
        }
        i = 0;
        while (i < k) : (i += 1) {
            if (try r.get() != @backingInt(Kind.node)) return error.Malformed;
            r.low = base + i;
            r.high = base + k;
            _ = try r.node(.from(r.vals.items[base + i]));
        }
    }

    fn record(r: *Reader, kind: Kind) Failure!u32 {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const charge = r.env.charge;
        const cells = r.env.cells;
        const conds = r.env.conds;
        switch (kind) {
            .label => {
                const inst = try r.get();
                const folded = try r.flag(1);
                const callee = try r.opt(LabelId, .label);
                return (try cells.label(gpa, acct, r.remap.inst(r.remap.ctx, inst), callee, folded == 1)).int();
            },
            .path => {
                const depth = try r.count();
                var p = try r.env.places.rootPath(gpa, try r.placeOf());
                var i: u32 = 0;
                while (i < depth) : (i += 1) {
                    try charge.reserve(gpa, .inspection, 1);
                    p = (try r.env.places.extend(gpa, charge, p, try r.stepOf())) orelse return error.Malformed;
                }
                return p.int();
            },
            .cell => return (try r.cell()).int(),
            .split => {
                const container: CellId = .from(try r.need(.cell));
                const inst = try r.get();
                const l = try r.opt(LabelId, .label);
                const k: CondId = .from(try r.need(.cond));
                // A split made on first sight keeps its condition: one that
                // is there with another would change what the reader's
                // tables mean.
                const existing = cells.findSplit(container, l);
                if (existing != .none and cells.splitOf(existing).cond != k) return error.BlockConflict;
                return (try cells.split(gpa, acct, container, inst, l, k)).int();
            },
            .set => {
                var s: SetId = .none;
                for (0..2) |bit| {
                    const n = try r.count();
                    var i: u32 = 0;
                    while (i < n) : (i += 1) s = try cells.sets.insert(gpa, charge, s, try r.need(.cell), @intCast(bit));
                }
                return s.int();
            },
            .atoms => {
                const n = try r.count();
                var acc = Cond.yes;
                var i: u32 = 0;
                while (i < n) : (i += 1) acc = try conds.@"and"(gpa, charge, acc, .from(try r.need(.atom)));
                return acc.int();
            },
            .cond => return switch (try enumOf(Cond.Kind, try r.get())) {
                .yes => Cond.yes.int(),
                .shared => Cond.shared.int(),
                .lost => Cond.lost.int(),
                .@"and", .atom => try r.need(.atoms),
            },
            .atom => {
                const a = switch (try enumOf(Cond.AtomKind, try r.get())) {
                    .excl => try conds.excl(gpa, charge, .from(try r.need(.cell))),
                    .sep => blk: {
                        if (try r.get() != 2) return error.Malformed;
                        const x: CellId = .from(try r.need(.cell));
                        break :blk try conds.sepAtom(gpa, charge, x, .from(try r.need(.cell)));
                    },
                    .within => try conds.within(gpa, charge, .from(try r.need(.label))),
                    .apart => try conds.apartAtom(gpa, charge, try r.opt(SetId, .set)),
                    .keep => try conds.keep(gpa, charge, try r.get()),
                    .writes => try conds.writes(gpa, charge, try r.get()),
                };
                return a.int();
            },
            .node => return (try r.node(null)).int(),
            .kentry => {
                const n: NodeId = .from(try r.need(.node));
                const s = try r.flag(1);
                try r.entries.append(gpa, .{ .node = n, .at_summary = s == 1, .cond = .from(try r.need(.cond)) });
                return @intCast(r.entries.items.len - 1);
            },
            .kmap => {
                const n = try r.count();
                var ctx: Cond.Kappas = .none;
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    // Two entries of one node (nodes the block merged) join.
                    const e = r.entries.items[try r.need(.kentry)];
                    ctx = (try conds.kappaSet(gpa, charge, ctx, e.node, e.at_summary, e.cond)).ctx;
                }
                return ctx.int();
            },
            .supply => {
                const k = try r.get();
                const bits = try r.flag(3);
                const l = try r.opt(LabelId, .label);
                const kappa = try r.opt(Cond.Kappas, .kmap);
                const n = try r.opt(NodeId, .node);
                try r.supplies.append(gpa, .{ .j = 0, .k = k, .node = n, .label = l, .owned = bits & 1 == 1, .taken = bits & 2 == 2, .kappa = kappa });
                return @intCast(r.supplies.items.len - 1);
            },
            .keep => {
                const j = try r.get();
                const k = try r.get();
                const kept = try r.opt(PathId, .path);
                const written = try r.opt(PathId, .path);
                try r.keeps.append(gpa, .{ .j = j, .k = k, .kept_path = kept, .written_path = written, .writer = try r.get() });
                return @intCast(r.keeps.items.len - 1);
            },
            .slot => {
                const p = try r.get();
                try r.slots.append(gpa, .{ .param = p, .path = try r.opt(PathId, .path) });
                return @intCast(r.slots.items.len - 1);
            },
            .class => return (try r.class()).int(),
            .group => return error.Malformed,
        }
    }

    fn cell(r: *Reader) Failure!CellId {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const cells = r.env.cells;
        const o = try enumOf(Cell.Origin, try r.get());
        const kind = try enumOf(Cell.Kind, try r.get());
        switch (o) {
            .site => {
                const inst = r.remap.inst(r.remap.ctx, try r.get());
                return cells.site(gpa, acct, inst, try r.placeOf(), kind);
            },
            .result, .esc => {
                const l = try r.opt(LabelId, .label);
                const k = try r.get();
                return cells.result(gpa, acct, o, l, k, try r.placeOf(), kind);
            },
            .shared => {
                const name = try r.get();
                const ordinal = try r.get();
                const index = r.remap.decl(r.remap.ctx, name, ordinal) orelse return error.Malformed;
                const p: PathId = .from(try r.need(.path));
                return cells.symbolic(gpa, acct, r.env.places, o, index, p, try r.get());
            },
            .param, .env, .msg => {
                const index = try r.get();
                const p: PathId = .from(try r.need(.path));
                return cells.symbolic(gpa, acct, r.env.places, o, index, p, try r.get());
            },
            .cb => {
                const l = try r.opt(LabelId, .label);
                const p: PathId = .from(try r.need(.path));
                return cells.symbolic(gpa, acct, r.env.places, .cb, l.int(), p, try r.get());
            },
            .top => return cells.top(gpa, acct),
            .elem, .others, .level, .below, .loan => {
                const parent: CellId = .from(try r.need(.cell));
                const l = try r.opt(LabelId, .label);
                const step = try r.get();
                const at = try r.placeOf();
                // The split it was taken by is the container's at its label.
                if (try r.ref(.split)) |s| {
                    const split = cells.splitOf(.from(s));
                    if (split.container != parent or split.label != l) return error.Malformed;
                }
                return cells.refine(gpa, acct, o, parent, l, step, at, kind);
            },
            .mark => {
                const m = try enumOf(Cell.Mark, try r.get());
                const b = try r.get();
                return cells.mark(gpa, acct, m, if (m == .field) r.remap.place.field(r.remap.place.ctx, b) else b);
            },
        }
    }

    /// A child map: `n, (step, child)×n`, a child below `high`.
    fn overs(r: *Reader) Failure!u32 {
        const n = try r.count();
        var root: u32 = none;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const s = try r.stepOf();
            const child = (try r.refBelow(.node, r.high)) orelse return error.Malformed;
            root = try r.env.shapes.overPut(r.env.gpa, r.env.account(), root, s, .from(child));
        }
        return root;
    }

    /// A node, made by its constructor, or — a knot's member `raw` — tied
    /// as its constructor would have made it, its parts read before it.
    fn node(r: *Reader, raw: ?NodeId) Failure!NodeId {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const shapes = r.env.shapes;
        const sets = &r.env.cells.sets;
        const kind = try enumOf(Shape.Kind, try r.get());
        const at = try r.placeOf();
        switch (kind) {
            .leaf, .node => {
                const cells = try r.opt(SetId, .set);
                const children = if (kind == .node) try r.overs() else 0;
                const id = raw orelse return if (kind == .leaf) shapes.leaf(gpa, acct, at, cells) else shapes.node(gpa, acct, at, cells, children);
                shapes.tie(id, .{ .kind = kind, .place = at, .cells = cells, .a = children, .b = 0, .reach = .none });
                return id;
            },
            .delta => {
                const base: NodeId = .from(try r.need(.node));
                if (shapes.kind(base) == .delta) return error.Malformed;
                const over = try r.overs();
                const id = raw orelse return shapes.delta(gpa, acct, base, over);
                shapes.tie(id, .{ .kind = .delta, .place = shapes.place(base), .cells = shapes.cells(base), .a = base.int(), .b = over, .reach = .none });
                return id;
            },
            .recast => {
                const inner: NodeId = .from(try r.need(.node));
                const id = raw orelse return shapes.recast(gpa, acct, at, inner);
                if (shapes.kind(inner) == .recast) return error.Malformed;
                shapes.tie(id, .{ .kind = .recast, .place = at, .cells = shapes.cells(inner), .a = inner.int(), .b = 0, .reach = .none });
                return id;
            },
            .@"union", .positions => {
                if (try r.get() != 2) return error.Malformed;
                const a: NodeId = .from(try r.need(.node));
                const b: NodeId = .from(try r.need(.node));
                const id = raw orelse return if (kind == .@"union") shapes.@"union"(gpa, acct, sets, a, b) else shapes.collect(gpa, acct, sets, &.{ a, b });
                shapes.tie(id, .{ .kind = kind, .place = shapes.place(a), .cells = try sets.unionWith(gpa, r.env.charge, shapes.cells(a), shapes.cells(b)), .a = a.int(), .b = b.int(), .reach = .none });
                return id;
            },
        }
    }

    fn class(r: *Reader) Failure!ClassId {
        const gpa = r.env.gpa;
        const kappas = try r.opt(Cond.Kappas, .kmap);
        const n_params = try r.count();
        const flags = try r.flag(7);
        const origin = try enumOf(Summary.Origin, try r.get());
        const res = try r.opt(NodeId, .node);
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        var i: u32 = 0;
        while (i < n_params) : (i += 1) try params.append(gpa, try r.opt(NodeId, .node));
        const xreq: CondId = if (try r.ref(.atoms)) |v| .from(v) else Cond.yes;
        var funs: std.ArrayList(Summary.DraftFun) = .empty;
        defer funs.deinit(gpa);
        var supplies: std.ArrayList(Summary.Supply) = .empty;
        defer supplies.deinit(gpa);
        var keeps: std.ArrayList(Summary.Keep) = .empty;
        defer keeps.deinit(gpa);
        var runs: std.ArrayList([4]u32) = .empty;
        defer runs.deinit(gpa);
        const n_funs = try r.count();
        i = 0;
        while (i < n_funs) : (i += 1) {
            const j = try r.get();
            const calls = try enumOf(Summary.Calls, try r.get());
            const bits = try r.flag(3);
            const s_start: u32 = @intCast(supplies.items.len);
            const n_s = try r.count();
            var s: u32 = 0;
            while (s < n_s) : (s += 1) {
                var x = r.supplies.items[try r.need(.supply)];
                x.j = j;
                try supplies.append(gpa, x);
            }
            const k_start: u32 = @intCast(keeps.items.len);
            const n_k = try r.count();
            s = 0;
            while (s < n_k) : (s += 1) try keeps.append(gpa, r.keeps.items[try r.need(.keep)]);
            try funs.append(gpa, .{ .j = j, .calls = calls, .need = bits & 1 == 1, .seen = bits & 2 == 2 });
            try runs.append(gpa, .{ s_start, n_s, k_start, n_k });
        }
        for (funs.items, runs.items) |*f, run| {
            f.supplies = supplies.items[run[0]..][0..run[1]];
            f.keeps = keeps.items[run[2]..][0..run[3]];
        }
        var slots: std.ArrayList(Summary.Slot) = .empty;
        defer slots.deinit(gpa);
        var n = try r.count();
        i = 0;
        while (i < n) : (i += 1) try slots.append(gpa, r.slots.items[try r.need(.slot)]);
        var nested: std.ArrayList(ClassId) = .empty;
        defer nested.deinit(gpa);
        n = try r.count();
        i = 0;
        while (i < n) : (i += 1) try nested.append(gpa, .from(try r.need(.class)));
        var once: std.ArrayList(PathId) = .empty;
        defer once.deinit(gpa);
        n = try r.count();
        i = 0;
        while (i < n) : (i += 1) try once.append(gpa, .from(try r.need(.path)));
        const refs = try r.opt(SetId, .set);
        return r.sums.add(r.env, .{
            .params = params.items,
            .res = res,
            .kappas = kappas,
            .xreq = if (xreq == Cond.yes) .none else try r.env.conds.flat(gpa, r.env.charge, xreq),
            .funs = funs.items,
            .slots = slots.items,
            .classes = nested.items,
            .once = once.items,
            .refs = refs,
            .refs_top = flags & 4 == 4,
            .writes = flags & 1 == 1,
            .entry = flags & 2 == 2,
            .origin = origin,
        });
    }
};

const testing = std.testing;
const Rows = @import("Rows.zig");

/// 0 `List Int`, 1 `Int`, 2 `List (List Int)`, 3 `List Int → List Int`,
/// 4 `Ref (List Int)`, 5 `Maybe (List Int)`, 6 `{ a : List Int }`,
/// 7 `List { a : List Int }`, 8 `type Tree = Node Tree (List Int) Tree`.
const Graph = struct {
    table: *Place.Table,
    account: *Ids.Account,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *Graph = @ptrCast(@alignCast(ctx));
        const gpa = testing.allocator;
        switch (v) {
            0 => try out.append(gpa, .{ .step = Step.elem, .@"var" = 1 }),
            1 => return .{ .kind = .cross },
            2 => try out.append(gpa, .{ .step = Step.elem, .@"var" = 0 }),
            3 => return .{ .kind = .closure, .head = 300 },
            4 => {
                try out.append(gpa, .{ .step = Step.contents, .@"var" = 0 });
                return .{ .kind = .ref, .head = 400 };
            },
            5 => {
                try out.append(gpa, .{ .step = g.table.ctorStep(gpa, g.account, 1, 0) catch unreachable, .@"var" = 0 });
                return .{ .kind = .ctor, .head = 500 };
            },
            6 => {
                try out.append(gpa, .{ .step = Step.field(g.account, 10) catch unreachable, .@"var" = 0 });
                return .{ .kind = .record };
            },
            7 => try out.append(gpa, .{ .step = Step.elem, .@"var" = 6 }),
            8 => {
                for ([_]u32{ 8, 0, 8 }, 0..) |child, i| try out.append(gpa, .{ .step = g.table.ctorStep(gpa, g.account, 0, @intCast(i)) catch unreachable, .@"var" = child });
                return .{ .kind = .ctor, .head = 800 };
            },
            else => unreachable,
        }
        return .{ .kind = .list, .head = 200 };
    }
};

const Tables = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    conds: Cond.Table = undefined,
    sums: Summary.Table = .{},
    account: Ids.Account = .{},
    graph: Graph = undefined,

    fn init(t: *Tables) !void {
        t.graph = .{ .table = &t.places, .account = &t.account };
        t.conds = try Cond.Table.init(testing.allocator, .growth(&t.account));
    }

    fn deinit(t: *Tables) void {
        t.places.deinit(testing.allocator);
        t.cells.deinit(testing.allocator);
        t.shapes.deinit(testing.allocator);
        t.conds.deinit(testing.allocator);
        t.sums.deinit(testing.allocator);
        t.account.deinit(testing.allocator);
    }

    fn env(t: *Tables) Env {
        return .{ .gpa = testing.allocator, .charge = .growth(&t.account), .places = &t.places, .cells = &t.cells, .shapes = &t.shapes, .conds = &t.conds };
    }

    fn place(t: *Tables, v: u32) !PlaceId {
        return t.places.of(testing.allocator, &t.account, .{ .ctx = &t.graph, .describe = Graph.describe }, v);
    }

    fn text(t: *Tables, arena: Allocator, c: ClassId) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(arena);
        try t.sums.print(t.env(), arena, &buf.writer, c, "f", print_names);
        return buf.toOwnedSlice();
    }
};

const PrintNames = struct {
    fn field(_: *anyopaque, rank: u32) []const u8 {
        return if (rank == 10) "a" else "?";
    }
    fn ctor(_: *anyopaque, _: u32, _: u32) []const u8 {
        return "Just";
    }
    fn decl(_: *anyopaque, _: u32, _: u32) []const u8 {
        return "M.v";
    }
};
var names_ctx: u8 = 0;
const print_names: Summary.Names = .{ .ctx = &names_ctx, .field = PrintNames.field, .ctor = PrintNames.ctor, .decl = PrintNames.decl };

fn wordBits(words: []const Rows.Word) u32 {
    var acc: u32 = 0;
    for (words) |x| acc |= x.bit();
    return acc;
}

/// The rows v2's words give, in `t`; built in `order` so two tables can
/// build them in different orders.
fn rows(t: *Tables, reverse: bool) ![8]ClassId {
    const env = t.env();
    const list = try t.place(0);
    const int = try t.place(1);
    const lists = try t.place(2);
    const fun = try t.place(3);
    const ref = try t.place(4);
    const maybe = try t.place(5);
    const recs = try t.place(7);
    const sigs = [8]Rows.Signature{
        .{ .params = &.{ .{ .place = lists, .words = wordBits(&.{ .written, .returned }) }, .{ .place = list, .words = wordBits(&.{.stored}) } }, .result = lists },
        .{ .params = &.{ .{ .place = lists, .words = wordBits(&.{.borrowed}) }, .{ .place = int, .words = wordBits(&.{.borrowed}) } }, .result = list, .result_words = wordBits(&.{.taken}) },
        .{ .params = &.{ .{ .place = lists, .words = wordBits(&.{ .written, .returned }) }, .{ .place = int, .words = wordBits(&.{.borrowed}) }, .{ .place = fun, .words = wordBits(&.{ .once, .taken }), .fn_params = &.{list} } }, .result = lists },
        .{ .params = &.{ .{ .place = recs, .words = wordBits(&.{.written}) }, .{ .place = recs, .words = wordBits(&.{.borrowed}) } }, .result = recs, .result_words = wordBits(&.{.concatenated}) },
        .{ .params = &.{.{ .place = list, .words = wordBits(&.{.consumed}) }}, .result = ref, .result_words = wordBits(&.{.cellnew}) },
        .{ .params = &.{.{ .place = ref, .words = wordBits(&.{.cellread}) }}, .result = maybe, .result_words = wordBits(&.{.lentoptional}), .optional_payload = try t.places.ctorStep(testing.allocator, &t.account, 1, 0) },
        .{ .params = &.{ .{ .place = ref, .words = wordBits(&.{.cellwrite}) }, .{ .place = fun, .words = wordBits(&.{.cellmodify}), .fn_params = &.{list} } }, .result = list },
        .{ .params = &.{ .{ .place = list, .words = wordBits(&.{.many}) }, .{ .place = fun, .words = wordBits(&.{ .many, .owned }), .fn_params = &.{list} } }, .result = list, .result_words = wordBits(&.{ .fresh, .exclusive }) },
    };
    var out: [8]ClassId = undefined;
    for (0..8) |k| {
        const i = if (reverse) 7 - k else k;
        out[i] = try Rows.fromWords(env, &t.sums, sigs[i]);
    }
    return out;
}

test "a block round-trips: read into tables of its own, written again, the same words and the same classes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    try testing.expectEqual(magic, words.items[0]);

    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var read_back: std.ArrayList(ClassId) = .empty;
    defer read_back.deinit(testing.allocator);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &read_back) != null);
    try testing.expectEqual(classes.len, read_back.items.len);
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(testing.allocator);
    try write(b.env(), &b.sums, read_back.items, .identity, &again);
    try testing.expectEqualSlices(u32, words.items, again.items);
    for (classes, read_back.items) |x, y| try testing.expectEqualStrings(try a.text(arena, x), try b.text(arena, y));
    // That the same rows built in another order write the same bytes is
    // the next tests'.
}

test "a block that does not decode is no block: every truncation, a wrong magic, a wrong version, a bad tag" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
    // Each prefix in tables of its own: a refused read may leave records
    // behind in its tables, never a class in `out`.
    for (0..words.items.len) |n| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expect(try read(t.env(), &t.sums, words.items[0..n], .identity, &out) == null);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const copy = try testing.allocator.dupe(u32, words.items);
    defer testing.allocator.free(copy);
    for ([_]usize{ 0, 1, 3 + 0 }) |at| {
        @memcpy(copy, words.items);
        copy[at] +%= 7;
        try testing.expect(try read(b.env(), &b.sums, copy, .identity, &out) == null);
    }
    // A trailing word is not this block.
    var longer = try words.clone(testing.allocator);
    defer longer.deinit(testing.allocator);
    try longer.append(testing.allocator, 0);
    try testing.expect(try read(b.env(), &b.sums, longer.items, .identity, &out) == null);
}

/// `write`'s charge for the class `make(t, n)` builds, at n and 2n …: each
/// doubling may cost at most 2.5 times the last (n log n, not n²).
fn expectLinearithmic(sizes: []const u32, comptime make: fn (*Tables, u32) anyerror!ClassId) !void {
    var last: u64 = 0;
    for (sizes) |n| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        const c = try make(&t, n);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(testing.allocator);
        const before = t.account.growth;
        try write(t.env(), &t.sums, &.{c}, .identity, &words);
        const cost = t.account.growth - before;
        if (last > 0) {
            if (cost * 2 >= last * 5) {
                std.debug.print("n={d}: {d} records after {d}\n", .{ n, cost, last });
                return error.TestUnexpectedResult;
            }
        }
        last = cost;
    }
}

test "a block's cost is n log n: n stores, a list of n distinct elements, a union chain of depth n" {
    try expectLinearithmic(&.{ 25, 50, 100, 200 }, struct {
        fn make(t: *Tables, n: u32) anyerror!ClassId {
            const lists = try t.place(2);
            const list = try t.place(0);
            const params = try testing.allocator.alloc(Rows.Param, n + 1);
            defer testing.allocator.free(params);
            params[0] = .{ .place = lists, .words = wordBits(&.{ .written, .returned }) };
            for (params[1..]) |*p| p.* = .{ .place = list, .words = wordBits(&.{.stored}) };
            return Rows.fromWords(t.env(), &t.sums, .{ .params = params, .result = lists });
        }
    }.make);
    // A literal of n distinct lists: a balanced `positions` DAG at `[*]`.
    try expectLinearithmic(&.{ 64, 128, 256, 512, 1024 }, struct {
        fn make(t: *Tables, n: u32) anyerror!ClassId {
            const gpa = testing.allocator;
            const lists = try t.place(2);
            const list = try t.place(0);
            const members = try gpa.alloc(NodeId, n);
            defer gpa.free(members);
            for (members, 0..) |*m, i| {
                const s = try t.cells.site(gpa, &t.account, @intCast(i), list, .list);
                m.* = try t.shapes.leaf(gpa, &t.account, list, try t.cells.sets.insert(gpa, t.env().charge, .none, s.int(), 0));
            }
            const elems = try t.shapes.collect(gpa, &t.account, &t.cells.sets, members);
            const res = try t.shapes.node(gpa, &t.account, lists, .none, try t.shapes.overPut(gpa, &t.account, Ids.none_int, Step.elem, elems));
            return t.sums.add(t.env(), .{ .params = &.{}, .res = res });
        }
    }.make);
    // A left-deep chain of unions of depth n.
    try expectLinearithmic(&.{ 16, 32, 64, 128, 256 }, struct {
        fn make(t: *Tables, n: u32) anyerror!ClassId {
            const gpa = testing.allocator;
            const list = try t.place(0);
            var acc: NodeId = .none;
            for (0..n) |i| {
                const s = try t.cells.site(gpa, &t.account, @intCast(i), list, .list);
                const leaf = try t.shapes.leaf(gpa, &t.account, list, try t.cells.sets.insert(gpa, t.env().charge, .none, s.int(), 0));
                acc = if (acc == .none) leaf else try t.shapes.@"union"(gpa, &t.account, &t.cells.sets, acc, leaf);
            }
            return t.sums.add(t.env(), .{ .params = &.{}, .res = acc });
        }
    }.make);
}

test "a block round-trips labels, splits, κ snapshots, xreq, keeps, slots and nested classes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    const gpa = testing.allocator;
    const lists = try a.place(2);
    const list = try a.place(0);
    const fun = try a.place(3);
    const root = try a.places.rootPath(gpa, lists);
    const elem = (try a.places.extend(gpa, env.charge, root, Step.elem)).?;
    const inner = try a.cells.label(gpa, &a.account, 11, .none, true);
    const l = try a.cells.label(gpa, &a.account, 10, inner, false);
    const p1 = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, root, 0);
    const cb = try a.cells.symbolic(gpa, &a.account, &a.places, .cb, l.int(), elem, 1);
    _ = try a.cells.split(gpa, &a.account, p1, 12, l, try a.conds.excl(gpa, env.charge, p1));
    const taken = try a.cells.refine(gpa, &a.account, .elem, p1, l, 0, list, .list);
    const leafOf = struct {
        fn of(t: *Tables, at: PlaceId, cs: []const CellId) !NodeId {
            var s: SetId = .none;
            for (cs) |c| s = try t.cells.sets.insert(testing.allocator, t.env().charge, s, c.int(), 0);
            return t.shapes.leaf(testing.allocator, &t.account, at, s);
        }
    }.of;
    const res_elem = try leafOf(&a, list, &.{ cb, taken });
    const res = try a.shapes.node(gpa, &a.account, lists, .none, try a.shapes.overPut(gpa, &a.account, Ids.none_int, Step.elem, res_elem));
    const k = try a.conds.@"and"(gpa, env.charge, try a.conds.within(gpa, env.charge, inner), try a.conds.sepAtom(gpa, env.charge, cb, taken));
    const kappas = (try a.conds.kappaSet(gpa, env.charge, .none, res_elem, true, k)).ctx;
    const supply_node = try leafOf(&a, list, &.{taken});
    const supply_k = (try a.conds.kappaSet(gpa, env.charge, .none, supply_node, false, try a.conds.excl(gpa, env.charge, p1))).ctx;
    const use = try Summary.Table.markUse(env, .none, lists, &.{}, .{ .r = true, .a = true }, &.{});
    const nested = try a.sums.add(env, .{ .params = &.{.none}, .res = try leafOf(&a, list, &.{p1}) });
    const c = try a.sums.add(env, .{
        .params = &.{ use, .none },
        .res = res,
        .kappas = kappas,
        .xreq = try a.conds.flat(gpa, env.charge, try a.conds.keep(gpa, env.charge, 1)),
        .funs = &.{.{ .j = 1, .calls = .many, .need = true, .supplies = &.{.{ .j = 1, .k = 0, .node = supply_node, .label = l, .owned = true, .taken = true, .kappa = supply_k }}, .keeps = &.{.{ .j = 1, .k = 0, .kept_path = elem, .written_path = root, .writer = 3 }} }},
        .slots = &.{.{ .param = 1, .path = try a.places.rootPath(gpa, fun) }},
        .classes = &.{nested},
        .once = &.{root},
        .writes = true,
    });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try write(env, &a.sums, &.{c}, .identity, &words);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(gpa);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(gpa);
    try write(b.env(), &b.sums, back.items, .identity, &again);
    try testing.expectEqualSlices(u32, words.items, again.items);
    try testing.expectEqualStrings(try a.text(arena, c), try b.text(arena, back.items[0]));
    // The split came back with its κ: the reader's taken element has its
    // container's split, `excl π₁` at it.
    var rit = b.cells.sets.iterate(b.shapes.cells(b.sums.supply(b.sums.fun(back.items[0], 0), 0).node));
    const back_taken: CellId = .from(rit.next().?.key);
    const split = b.cells.findSplit(.from(b.cells.get(back_taken).a), .from(b.cells.get(back_taken).b));
    try testing.expect(split != .none);
    try testing.expectEqual(Cond.Kind.atom, b.conds.kind(b.cells.splitOf(split).cond));
    const bk = b.sums.get(back.items[0]);
    try testing.expect(bk.writes and !bk.entry);
    try testing.expectEqual(@as(u32, 1), b.sums.funCount(back.items[0]));
    try testing.expectEqual(@as(usize, 1), b.sums.nestedOf(back.items[0]).len);
}

test "a block built in another order writes the same bytes" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const forward = try rows(&a, false);
    const backward = try rows(&b, true);
    var wa: std.ArrayList(u32) = .empty;
    defer wa.deinit(testing.allocator);
    var wb: std.ArrayList(u32) = .empty;
    defer wb.deinit(testing.allocator);
    try write(a.env(), &a.sums, &forward, .identity, &wa);
    try write(b.env(), &b.sums, &backward, .identity, &wb);
    try testing.expectEqualSlices(u32, wa.items, wb.items);
}

test "a malformed block decodes as no block and never crashes: every truncation, and a mutation of every word" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    // Three rows (a store, a taken element, a cell's optional loan) reach
    // every record kind but labels'; the labels' test block has those.
    try write(a.env(), &a.sums, &.{ classes[0], classes[1], classes[5] }, .identity, &words);
    const copy = try testing.allocator.dupe(u32, words.items);
    defer testing.allocator.free(copy);
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
    // A payload a step cannot hold, which once panicked a cast.
    const bad_step = [_]u32{ magic, version, 1, @backingInt(Place.Kind.list), 200, 0, 1, @backingInt(Place.StepKind.elem), 0xFFFFFFFF, 0, 0 };
    {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expect(try read(t.env(), &t.sums, &bad_step, .identity, &out) == null);
    }
    for (0..words.items.len) |i| {
        for ([_]u32{if (i % 2 == 0) 0 else words.items[i] +% 1}) |v| {
            if (v == words.items[i]) continue;
            @memcpy(copy, words.items);
            copy[i] = v;
            var t: Tables = .{};
            try t.init();
            defer t.deinit();
            // A mutation may still be a block (another count, another
            // place); what it may not do is crash or half-decode.
            const before = out.items.len;
            if (try read(t.env(), &t.sums, copy, .identity, &out) == null) try testing.expectEqual(before, out.items.len);
            out.clearRetainingCapacity();
        }
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expect(try read(t.env(), &t.sums, words.items[0..i], .identity, &out) == null);
    }
}

test "a knot's member may name itself by a child step and by nothing else" {
    // magic, version, one place (a list, no children), one knot of one
    // member, no classes.
    const head = [_]u32{ magic, version, 1, @backingInt(Place.Kind.list), 200, 0, 0, 1, @backingInt(Kind.group), 1, @backingInt(Kind.node) };
    // A node whose `[*]` child is itself: a knot.
    const by_step = head ++ [_]u32{ @backingInt(Shape.Kind.node), 0, none, 1, @backingInt(Place.StepKind.elem), 0, 0, 0 };
    // A recast of itself: no constructor makes it.
    const by_inner = head ++ [_]u32{ @backingInt(Shape.Kind.recast), 0, 0, 0 };
    // A union with itself as a side.
    const by_side = head ++ [_]u32{ @backingInt(Shape.Kind.@"union"), 0, 2, 0, 0, 0 };
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
    for ([_][]const u32{ &by_step, &by_inner, &by_side }, [_]bool{ true, false, false }) |words, ok| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expectEqual(ok, try read(t.env(), &t.sums, words, .identity, &out) != null);
    }
}

test "a block read into tables that hold records already keeps its meaning, and a failed read changes nothing" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    // The reader holds the same rows built in the other order, so its cells,
    // labels and splits meet the block's: the classes read back write the
    // block again.
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    _ = try rows(&b, true);
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(testing.allocator);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(testing.allocator);
    try write(b.env(), &b.sums, back.items, .identity, &again);
    try testing.expectEqualSlices(u32, words.items, again.items);
    // A block that does not decode leaves every table of the reader as it was.
    const counts = [_]u32{ b.places.count(), b.cells.count(), b.shapes.count(), b.conds.count(), b.sums.count() };
    var broken = try words.clone(testing.allocator);
    defer broken.deinit(testing.allocator);
    broken.items[broken.items.len - 3] = 0xFFFF;
    try testing.expect(try read(b.env(), &b.sums, broken.items, .identity, &back) == null);
    try testing.expectEqualSlices(u32, &counts, &.{ b.places.count(), b.cells.count(), b.shapes.count(), b.conds.count(), b.sums.count() });
    // Reading the same block again builds it under places of its own: it
    // meets neither its first copy nor the reader's rows. (A split held with
    // another condition is then unreachable; `read` still refuses one as
    // `error.BlockConflict`, never a quiet change of meaning.)
    var twice: std.ArrayList(ClassId) = .empty;
    defer twice.deinit(testing.allocator);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &twice) != null);
}

test "a block names a written field and a shared declaration through Names, never by rank or index" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    const gpa = testing.allocator;
    const rec = try a.place(6);
    const list = try a.place(0);
    const use = try Summary.Table.markUse(env, .none, rec, &.{}, .{ .w = true }, &.{10});
    const shared = try a.cells.symbolic(gpa, &a.account, &a.places, .shared, 3, try a.places.rootPath(gpa, list), 0);
    const res = try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, shared.int(), 0));
    const c = try a.sums.add(env, .{ .params = &.{use}, .res = res });
    const Map = struct {
        fn field(_: *anyopaque, rank: u32) u32 {
            return rank + 100;
        }
        fn unfield(_: *anyopaque, n: u32) u32 {
            return n - 100;
        }
        fn decl(_: *anyopaque, index: u32) [2]u32 {
            return .{ index + 500, 7 };
        }
        fn undecl(_: *anyopaque, name: u32, ordinal: u32) ?u32 {
            return if (ordinal == 7 and name >= 500) name - 500 else null;
        }
        fn same(_: *anyopaque, x: u32) u32 {
            return x;
        }
    };
    var dummy: u8 = 0;
    const names: Names = .{ .place = .{ .ctx = &dummy, .head = Map.same, .field = Map.field }, .ctx = &dummy, .decl = Map.decl };
    const remap: Remap = .{ .place = .{ .ctx = &dummy, .head = Map.same, .field = Map.unfield }, .ctx = &dummy, .decl = Map.undecl, .inst = Map.same };
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try write(env, &a.sums, &.{c}, names, &words);
    // The field's rank 10 and the declaration's index 3 are not what the
    // block says.
    try testing.expect(std.mem.indexOfScalar(u32, words.items, 110) != null);
    try testing.expect(std.mem.indexOfScalar(u32, words.items, 503) != null);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(gpa);
    try testing.expect(try read(b.env(), &b.sums, words.items, remap, &back) != null);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try testing.expectEqualStrings(try a.text(arena_state.allocator(), c), try b.text(arena_state.allocator(), back.items[0]));
}

/// `go`'s widened tree (`Shape`'s "widen ties go's grafted levels back"): a
/// knot whose `#Node.0` and `#Node.2` children name it again.
fn widenedTree(t: *Tables) !NodeId {
    const gpa = testing.allocator;
    const tree = try t.place(8);
    const list = try t.place(0);
    const s0 = try t.places.ctorStep(gpa, &t.account, 0, 0);
    const s1 = try t.places.ctorStep(gpa, &t.account, 0, 1);
    const s2 = try t.places.ctorStep(gpa, &t.account, 0, 2);
    const param = try t.cells.symbolic(gpa, &t.account, &t.places, .param, 2, try t.places.rootPath(gpa, tree), 0);
    const t_param = try t.shapes.leaf(gpa, &t.account, tree, try t.cells.sets.insert(gpa, t.env().charge, .none, param.int(), 0));
    var level = t_param;
    for (1..3) |i| {
        const site = try t.cells.site(gpa, &t.account, @intCast(i), list, .list);
        var children = try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, level);
        children = try t.shapes.overPut(gpa, &t.account, children, s1, try t.shapes.leaf(gpa, &t.account, list, try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0)));
        children = try t.shapes.overPut(gpa, &t.account, children, s2, level);
        level = try t.shapes.node(gpa, &t.account, tree, .none, children);
    }
    return t.shapes.widen(gpa, &t.account, &t.places, &t.cells, level);
}

test "a recursive class's widened knot is written once and read back as a knot" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    // The allowance `@ownership_summary_size` allows: a knot is no reason to
    // stop, and no stack grows with it.
    a.account.allowance = std.math.maxInt(u32) - 1;
    const w = try widenedTree(&a);
    const k = try a.conds.excl(testing.allocator, a.env().charge, try a.cells.top(testing.allocator, &a.account));
    const c = try a.sums.add(a.env(), .{ .params = &.{w}, .res = w, .kappas = (try a.conds.kappaSet(testing.allocator, a.env().charge, .none, w, false, k)).ctx });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &.{c}, .identity, &words);
    try testing.expect(std.mem.indexOfScalar(u32, words.items, @backingInt(Kind.group)) != null);
    // Widened again, the same knot under other ids: the same words.
    const again_w = try widenedTree(&a);
    try testing.expect(again_w != w);
    const c2 = try a.sums.add(a.env(), .{ .params = &.{again_w}, .res = again_w, .kappas = (try a.conds.kappaSet(testing.allocator, a.env().charge, .none, again_w, false, k)).ctx });
    var words2: std.ArrayList(u32) = .empty;
    defer words2.deinit(testing.allocator);
    try write(a.env(), &a.sums, &.{c2}, .identity, &words2);
    try testing.expectEqualSlices(u32, words.items, words2.items);

    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(testing.allocator);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
    var round: std.ArrayList(u32) = .empty;
    defer round.deinit(testing.allocator);
    try write(b.env(), &b.sums, back.items, .identity, &round);
    try testing.expectEqualSlices(u32, words.items, round.items);
    // The knot is in the reader's table: a child at `#Node.0` leads back to
    // the root (through the union with the parameter's leaf, if any).
    const res = b.sums.get(back.items[0]).res;
    const s0 = try b.places.ctorStep(testing.allocator, &b.account, 0, 0);
    var at = res;
    if (b.shapes.kind(at) == .@"union") at = .from(b.shapes.nodes.items(.a)[at.int()]);
    const child = b.shapes.overGet(b.shapes.nodes.items(.a)[at.int()], s0).?;
    try testing.expect(child == res or b.shapes.nodes.items(.a)[child.int()] == at.int() or child == at);
    // Its stored κ came back with it.
    try testing.expect(b.conds.kappaGet(b.sums.get(back.items[0]).kappas, res, false) != null);
}

test "a block built in another order writes the same bytes: nested classes and supplies with maps of their own" {
    const Build = struct {
        fn of(t: *Tables, flip: bool) !ClassId {
            const gpa = testing.allocator;
            const env = t.env();
            const list = try t.place(0);
            const root = try t.places.rootPath(gpa, list);
            var p: [2]CellId = undefined;
            for (0..2) |k| {
                const i = if (flip) 1 - k else k;
                p[i] = try t.cells.symbolic(gpa, &t.account, &t.places, .param, @intCast(i), root, 0);
            }
            var nested: [2]ClassId = undefined;
            var supplies: [2]Summary.Supply = undefined;
            for (0..2) |k| {
                const i = if (flip) 1 - k else k;
                const leaf = try t.shapes.leaf(gpa, &t.account, list, try t.cells.sets.insert(gpa, env.charge, .none, p[i].int(), 0));
                const map = (try t.conds.kappaSet(gpa, env.charge, .none, leaf, false, try t.conds.excl(gpa, env.charge, p[i]))).ctx;
                nested[k] = try t.sums.add(env, .{ .params = &.{.none}, .res = leaf, .kappas = map });
                supplies[k] = .{ .j = 0, .k = @intCast(i), .node = leaf, .label = .none, .owned = true, .taken = false, .kappa = map };
            }
            return t.sums.add(env, .{ .params = &.{ .none, .none }, .res = .none, .classes = &nested, .funs = &.{.{ .j = 0, .calls = .once, .supplies = &supplies }} });
        }
    };
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const ca = try Build.of(&a, false);
    const cb = try Build.of(&b, true);
    var wa: std.ArrayList(u32) = .empty;
    defer wa.deinit(testing.allocator);
    var wb: std.ArrayList(u32) = .empty;
    defer wb.deinit(testing.allocator);
    try write(a.env(), &a.sums, &.{ca}, .identity, &wa);
    try write(b.env(), &b.sums, &.{cb}, .identity, &wb);
    try testing.expectEqualSlices(u32, wa.items, wb.items);
    // And both decode, every map with its κ.
    for ([_][]const u32{ wa.items, wb.items }) |words| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        var back: std.ArrayList(ClassId) = .empty;
        defer back.deinit(testing.allocator);
        try testing.expect(try read(t.env(), &t.sums, words, .identity, &back) != null);
        for (t.sums.nestedOf(back.items[0])) |x| try testing.expect(t.sums.get(x).kappas != .none);
        const f = t.sums.fun(back.items[0], 0);
        for (0..2) |i| try testing.expect(t.sums.supply(f, @intCast(i)).kappa != .none);
    }
}

test "a block's size is linear in a chain of taken elements of taken elements" {
    var last: usize = 0;
    for ([_]u32{ 64, 128, 256 }) |depth| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        const gpa = testing.allocator;
        const env = t.env();
        const list = try t.place(0);
        var c = try t.cells.symbolic(gpa, &t.account, &t.places, .param, 0, try t.places.rootPath(gpa, list), 0);
        for (0..depth) |i| {
            const l = try t.cells.label(gpa, &t.account, @intCast(i), .none, false);
            _ = try t.cells.split(gpa, &t.account, c, @intCast(i), l, try t.conds.excl(gpa, env.charge, c));
            c = try t.cells.refine(gpa, &t.account, .elem, c, l, 0, list, .list);
        }
        const res = try t.shapes.leaf(gpa, &t.account, list, try t.cells.sets.insert(gpa, env.charge, .none, c.int(), 0));
        const k = try t.sums.add(env, .{ .params = &.{.none}, .res = res });
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        try write(env, &t.sums, &.{k}, .identity, &words);
        if (last > 0) try testing.expect(words.items.len * 10 <= last * 21);
        last = words.items.len;
    }
}

test "a block's places are a namespace of their own: the module's type variables never meet them" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(testing.allocator);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
    // The module asks for its type variables after the read: each is a
    // place of its own walk, none of the block's.
    const block_places = b.places.count();
    for (0..8) |v| try testing.expect((try b.place(@intCast(v))).int() >= block_places);
}

test "a read is charged once, and a read past the allowance leaves the reader's tables as they were" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    var cost: u32 = 0;
    {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        var back: std.ArrayList(ClassId) = .empty;
        defer back.deinit(testing.allocator);
        const before = t.account.growth;
        try testing.expect(try read(t.env(), &t.sums, words.items, .identity, &back) != null);
        cost = t.account.growth - before;
    }
    for ([_]u32{ 0, 1 }) |short| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        t.account.allowance = t.account.growth + cost - short;
        const counts = [_]u32{ t.places.count(), t.cells.count(), t.shapes.count(), t.conds.count(), t.sums.count() };
        var back: std.ArrayList(ClassId) = .empty;
        defer back.deinit(testing.allocator);
        if (short == 0) {
            // The whole decode once is exactly what the read costs.
            try testing.expect(try read(t.env(), &t.sums, words.items, .identity, &back) != null);
        } else {
            try testing.expectError(error.OwnershipLimit, read(t.env(), &t.sums, words.items, .identity, &back));
            try testing.expectEqualSlices(u32, &counts, &.{ t.places.count(), t.cells.count(), t.shapes.count(), t.conds.count(), t.sums.count() });
            try testing.expectEqual(@as(usize, 0), back.items.len);
        }
    }
}
