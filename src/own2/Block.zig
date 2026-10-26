//! L11: the ownership block (`docs/design/ownership-v2.md` §3.6), minimal:
//! classes to words and back, with places written structurally. S2b builds
//! the class table and its records — a header (`OWN2`, the version), the
//! place table, then each class by one canonical walk — and nothing of S6's:
//! no lazy directory, no cache section, no traversal marks.
//!
//! **No session id in the bytes.** A place is its kind, its head and its
//! children (a head, a field's rank — a use mark's too — through the
//! writer's `Names`), a shared value's declaration its qualified name and
//! ordinal, a cell its origin and canonical path, a node its first-visit
//! ordinal per κ map (an already numbered node is a backreference).
//! Instruction ids (a label's, a site's) are the module's own, and a reader
//! puts them in a namespace of its own (`Remap.inst`).
//!
//! **Canonical order in O(n log n).** Every set, a union's two sides, a
//! node's children, a fun's supplies and keeps, a class's slots, nested
//! classes and once paths are written in the order of their members'
//! structural hashes, each computed once per record (a node's per κ map) and
//! memoised: no subtree is spelled twice to sort it. Two members with equal
//! hashes keep their table order; equal hashes of different records (a
//! 64-bit collision) are the one case that order shows.
//!
//! **Reading.** `read` decodes into tables of its own first; a block that
//! does not decode is no block (null, R-5.7.4) and the caller's tables are
//! untouched. Only a block that decoded is then built in the caller's tables,
//! and there a split that exists with another condition is a conflict
//! (`error.BlockConflict`), never a silent change of meaning.
//!
//! Every record a class reaches is reserved on the writer's and the
//! reader's charge before it is read or made (§4.1); a sort of n members is
//! charged n·⌈log₂ n⌉.
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
pub const version: u32 = 2;

const none: u32 = Ids.none_int;

const Tag = enum(u32) { class, node_new, node_ref, none_node, cell, set, cond, atom, fun, supply, keep, slot, path, label };

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

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Write `classes` as one block: header, place table, classes.
pub fn write(env: Env, sums: *Summary.Table, classes: []const ClassId, names: Names, out: *std.ArrayList(u32)) Error!void {
    const gpa = env.gpa;
    var w: Writer = .{ .env = env, .sums = sums, .names = names };
    defer w.deinit();
    var body: std.ArrayList(u32) = .empty;
    defer body.deinit(gpa);
    w.out = &body;
    try w.put(@intCast(classes.len));
    for (classes) |c| try w.class(c);
    // The places the classes named, closed under their children, each
    // record `kind, head, holds, n, (step…, child)×n`.
    var at: usize = 0;
    var places: std.ArrayList(u32) = .empty;
    defer places.deinit(gpa);
    w.out = &places;
    while (at < w.place_order.items.len) : (at += 1) {
        const p = w.place_order.items[at];
        try env.charge.reserve(gpa, .inspection, 1);
        const k = env.places.kind(p);
        const steps = env.places.steps(p);
        try w.put(@backingInt(k));
        try w.put(if (k == .tuple or k == .record) env.places.head(p) else names.place.head(names.place.ctx, env.places.head(p)));
        try w.put(env.places.holds(p).bits());
        try w.put(@intCast(steps.steps.len));
        for (steps.steps, steps.children) |s, child| {
            try w.step(s);
            try w.put(try w.placeLocal(child));
        }
    }
    try out.appendSlice(gpa, &.{ magic, version, @intCast(w.place_order.items.len) });
    try out.appendSlice(gpa, places.items);
    try out.appendSlice(gpa, body.items);
}

/// What a hash memo is keyed by.
const HashKind = enum(u8) { place, path, label, cell, set, atom, cond, node, kappa, class };

const Writer = struct {
    env: Env,
    sums: *Summary.Table,
    names: Names,
    out: *std.ArrayList(u32) = undefined,
    ctx: Cond.Kappas = .none,
    /// `(node, map local)` → first-visit ordinal: one node under two maps
    /// is two records, each with its own κ.
    ordinal: Ids.FixedDict(2) = .{},
    next: u32 = 0,
    /// A κ map's local number, in first-use order: what a node's ordinal is
    /// keyed by and what a class or a supply names its map by, so a reader
    /// shares a map exactly where the writer did.
    ctx_local: Ids.FixedDict(1) = .{},
    ctx_next: u32 = 0,
    place_local: Ids.FixedDict(1) = .{},
    place_order: std.ArrayList(PlaceId) = .empty,
    /// The structural hashes, once per record (a node's and its κ's per
    /// map): `(kind, id, map)` → hash.
    hashes: std.AutoHashMapUnmanaged([3]u32, u64) = .empty,

    fn deinit(w: *Writer) void {
        const gpa = w.env.gpa;
        w.ordinal.deinit(gpa);
        w.ctx_local.deinit(gpa);
        w.place_local.deinit(gpa);
        w.place_order.deinit(gpa);
        w.hashes.deinit(gpa);
    }

    fn put(w: *Writer, x: u32) Error!void {
        try w.out.append(w.env.gpa, x);
    }

    fn tag(w: *Writer, t: Tag) Error!void {
        try w.put(@backingInt(t));
    }

    fn ctxLocal(w: *Writer, k: Cond.Kappas) Error!u32 {
        const got = try w.ctx_local.getOrPut(w.env.gpa, .{k.int()});
        if (!got.found_existing) {
            got.value_ptr.* = w.ctx_next;
            w.ctx_next += 1;
        }
        return got.value_ptr.*;
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

    // ---- structural hashes -------------------------------------------------

    fn memo(w: *Writer, kind: HashKind, id: u32, map: u32) Error!?u64 {
        if (w.hashes.get(.{ @backingInt(kind), id, map })) |h| return h;
        try w.env.charge.reserve(w.env.gpa, .inspection, 1);
        return null;
    }

    fn remember(w: *Writer, kind: HashKind, id: u32, map: u32, h: u64) Error!u64 {
        try w.hashes.put(w.env.gpa, .{ @backingInt(kind), id, map }, h);
        return h;
    }

    fn mix(words: []const u64) u64 {
        return std.hash.Wyhash.hash(0x6f776e32, std.mem.sliceAsBytes(words));
    }

    /// A place's hash: its canonical encoding from it, once per place,
    /// charged by the encoding's length.
    fn placeHash(w: *Writer, p: PlaceId) Error!u64 {
        if (try w.memo(.place, p.int(), 0)) |h| return h;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(w.env.gpa);
        try w.env.places.encode(w.env.gpa, p, w.names.place, &words);
        try w.env.charge.reserve(w.env.gpa, .inspection, @intCast(words.items.len));
        return w.remember(.place, p.int(), 0, std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(words.items)));
    }

    fn stepWords(w: *Writer, s: Step) [3]u64 {
        return switch (s.kind) {
            .field => .{ @backingInt(s.kind), w.names.place.field(w.names.place.ctx, s.payload), 0 },
            .ctor_arg => blk: {
                const pair = w.env.places.ctorArgOf(s);
                break :blk .{ @backingInt(s.kind), pair[0], pair[1] };
            },
            else => .{ @backingInt(s.kind), s.payload, 0 },
        };
    }

    fn pathHash(w: *Writer, p: PathId) Error!u64 {
        if (p == .none) return 0;
        if (try w.memo(.path, p.int(), 0)) |h| return h;
        const places = w.env.places;
        const parent = places.pathParent(p);
        const h = if (parent == .none)
            mix(&.{ 1, try w.placeHash(places.pathPlace(p)) })
        else blk: {
            const s = w.stepWords(places.pathStep(p));
            break :blk mix(&.{ 2, try w.pathHash(parent), s[0], s[1], s[2] });
        };
        return w.remember(.path, p.int(), 0, h);
    }

    fn labelHash(w: *Writer, l: LabelId) Error!u64 {
        if (l == .none) return 0;
        if (try w.memo(.label, l.int(), 0)) |h| return h;
        const d = w.env.cells.labelOf(l);
        return w.remember(.label, l.int(), 0, mix(&.{ 3, d.inst, @intFromBool(d.folded), try w.labelHash(d.callee_label) }));
    }

    fn cellHash(w: *Writer, c: CellId) Error!u64 {
        if (try w.memo(.cell, c.int(), 0)) |h| return h;
        const cells = w.env.cells;
        const d = cells.get(c);
        const o: u64 = @backingInt(d.origin);
        const k: u64 = @backingInt(d.kind);
        const h = switch (d.origin) {
            .site => mix(&.{ 4, o, k, d.a, try w.placeHash(d.place) }),
            .result, .esc => mix(&.{ 4, o, k, try w.labelHash(.from(d.a)), d.b, try w.placeHash(d.place) }),
            .shared => blk: {
                const name = w.names.decl(w.names.ctx, d.a);
                break :blk mix(&.{ 4, o, k, name[0], name[1], try w.pathHash(.from(d.b)), d.c });
            },
            .param, .env, .msg => mix(&.{ 4, o, k, d.a, try w.pathHash(.from(d.b)), d.c }),
            .cb => mix(&.{ 4, o, k, try w.labelHash(.from(d.a)), try w.pathHash(.from(d.b)), d.c }),
            .top => mix(&.{ 4, o }),
            .elem, .others, .level, .below, .loan => blk: {
                const s = cells.findSplit(.from(d.a), .from(d.b));
                const split: u64 = if (s == .none) 0 else try w.condHash(cells.splitOf(s).cond);
                break :blk mix(&.{ 4, o, k, try w.cellHash(.from(d.a)), try w.labelHash(.from(d.b)), d.c, try w.placeHash(d.place), split });
            },
            .mark => mix(&.{ 4, o, d.a, if (d.a == @backingInt(Cell.Mark.field)) w.names.place.field(w.names.place.ctx, d.b) else d.b }),
        };
        return w.remember(.cell, c.int(), 0, h);
    }

    /// An unordered set's hash: its members' hashes, sorted, mixed.
    fn sortedMix(w: *Writer, seed: u64, hs: []u64) Error!u64 {
        try chargeSort(w.env, hs.len);
        std.mem.sort(u64, hs, {}, std.sort.asc(u64));
        var acc = seed;
        for (hs) |h| acc = mix(&.{ acc, h });
        return acc;
    }

    fn setHash(w: *Writer, s: SetId) Error!u64 {
        if (try w.memo(.set, s.int(), 0)) |h| return h;
        var hs: std.ArrayList(u64) = .empty;
        defer hs.deinit(w.env.gpa);
        var it = w.env.cells.sets.iterate(s);
        while (it.next()) |e| try hs.append(w.env.gpa, mix(&.{ try w.cellHash(.from(e.key)), e.value }));
        return w.remember(.set, s.int(), 0, try w.sortedMix(5, hs.items));
    }

    fn atomHash(w: *Writer, id: CondId) Error!u64 {
        if (try w.memo(.atom, id.int(), 0)) |h| return h;
        const a = w.env.conds.get(id);
        const kind: u64 = @backingInt(a.atom);
        const h = switch (a.atom) {
            .excl => mix(&.{ 6, kind, try w.cellHash(.from(a.a)) }),
            .sep => blk: {
                var two = [2]u64{ try w.cellHash(.from(a.a)), try w.cellHash(.from(a.b)) };
                break :blk try w.sortedMix(mix(&.{ 6, kind }), &two);
            },
            .within => mix(&.{ 6, kind, try w.labelHash(.from(a.a)) }),
            .apart => mix(&.{ 6, kind, try w.setHash(.from(a.a)) }),
            .keep, .writes => mix(&.{ 6, kind, a.a }),
        };
        return w.remember(.atom, id.int(), 0, h);
    }

    fn atomSetHash(w: *Writer, s: SetId) Error!u64 {
        var hs: std.ArrayList(u64) = .empty;
        defer hs.deinit(w.env.gpa);
        var it = w.env.conds.atoms.iterate(s);
        while (it.next()) |e| try hs.append(w.env.gpa, try w.atomHash(.from(e.key)));
        return w.sortedMix(7, hs.items);
    }

    fn condHash(w: *Writer, k: CondId) Error!u64 {
        if (try w.memo(.cond, k.int(), 0)) |h| return h;
        const kind = w.env.conds.kind(k);
        const h = if (k == Cond.yes or Cond.Table.fails(k)) mix(&.{ 8, @backingInt(kind) }) else mix(&.{ 8, @backingInt(kind), try w.atomSetHash(try w.env.conds.flat(w.env.gpa, w.env.charge, k)) });
        return w.remember(.cond, k.int(), 0, h);
    }

    /// The κ the current map stores for a node, if any: the one fact of a
    /// node's κ a reader cannot derive again from its structure.
    fn stored(w: *Writer, id: NodeId, at_summary: bool) ?CondId {
        return w.env.conds.kappaGet(w.ctx, id, at_summary);
    }

    const Over = struct { step: Step, node: NodeId, at_summary: bool, key: u64 };

    /// A node's children map, sorted by their steps' spelling.
    fn overList(w: *Writer, root: u32, at_summary: bool, out: *std.ArrayList(Over)) Error!void {
        var it = w.env.shapes.overEntries(root);
        while (it.next()) |e| {
            const s = w.stepWords(e.step);
            try out.append(w.env.gpa, .{ .step = e.step, .node = e.node, .at_summary = at_summary or e.step.kind == .elem or e.step.kind == .level, .key = mix(&.{ s[0], s[1], s[2] }) });
        }
        try chargeSort(w.env, out.items.len);
        std.mem.sort(Over, out.items, {}, struct {
            fn less(_: void, a: Over, b: Over) bool {
                return a.key < b.key;
            }
        }.less);
    }

    fn nodeHash(w: *Writer, id: NodeId, at_summary: bool) Error!u64 {
        if (id == .none) return 0;
        const map = try w.ctxLocal(w.ctx);
        const key = (id.int() << 1) | @intFromBool(at_summary);
        if (try w.memo(.node, key, map)) |h| return h;
        const d = w.env.shapes.get(id);
        const own_cells: u64 = if (d.kind == .leaf or d.kind == .node) try w.setHash(d.cells) else 0;
        const stored_k: u64 = if (w.stored(id, at_summary)) |k| try w.condHash(k) else 0;
        var acc = mix(&.{ 9, @backingInt(d.kind), @intFromBool(at_summary), try w.placeHash(d.place), own_cells, stored_k });
        switch (d.kind) {
            .leaf => {},
            .node, .delta => {
                if (d.kind == .delta) acc = mix(&.{ acc, try w.nodeHash(.from(d.a), at_summary) });
                var overs: std.ArrayList(Over) = .empty;
                defer overs.deinit(w.env.gpa);
                try w.overList(if (d.kind == .node) d.a else d.b, at_summary, &overs);
                for (overs.items) |o| acc = mix(&.{ acc, o.key, try w.nodeHash(o.node, o.at_summary) });
            },
            .recast => acc = mix(&.{ acc, try w.nodeHash(.from(d.a), at_summary) }),
            .@"union", .positions => {
                var two = [2]u64{ try w.nodeHash(.from(d.a), at_summary), try w.nodeHash(.from(d.b), at_summary) };
                acc = try w.sortedMix(acc, &two);
            },
        }
        return w.remember(.node, key, map, acc);
    }

    // ---- the records ---------------------------------------------------------

    fn step(w: *Writer, s: Step) Error!void {
        const words = w.stepWords(s);
        try w.put(@intCast(words[0]));
        try w.put(@intCast(words[1]));
        if (s.kind == .ctor_arg) try w.put(@intCast(words[2]));
    }

    fn path(w: *Writer, p: PathId) Error!void {
        try w.tag(.path);
        if (p == .none) return w.put(none);
        const places = w.env.places;
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(w.env.gpa);
        var at = p;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) try steps.append(w.env.gpa, places.pathStep(at));
        try w.put(@intCast(steps.items.len));
        try w.put(try w.placeLocal(places.pathPlace(at)));
        var i = steps.items.len;
        while (i > 0) : (i -= 1) try w.step(steps.items[i - 1]);
    }

    fn label(w: *Writer, l: LabelId) Error!void {
        try w.tag(.label);
        if (l == .none) return w.put(none);
        try w.env.charge.reserve(w.env.gpa, .inspection, 1);
        const d = w.env.cells.labelOf(l);
        try w.put(d.inst);
        try w.put(@intFromBool(d.folded));
        try w.label(d.callee_label);
        // A label's own supplies are the walk's (S4) and live, today, in the
        // classes' funs keyed by the label; its record holds none yet.
        std.debug.assert(d.supplies.len == 0);
    }

    fn cell(w: *Writer, c: CellId) Error!void {
        try w.env.charge.reserve(w.env.gpa, .inspection, 1);
        const cells = w.env.cells;
        const d = cells.get(c);
        try w.tag(.cell);
        try w.put(@backingInt(d.origin));
        try w.put(@backingInt(d.kind));
        switch (d.origin) {
            .site => {
                try w.put(d.a);
                try w.put(try w.placeLocal(d.place));
            },
            .result, .esc => {
                try w.label(.from(d.a));
                try w.put(d.b);
                try w.put(try w.placeLocal(d.place));
            },
            .shared => {
                const name = w.names.decl(w.names.ctx, d.a);
                try w.put(name[0]);
                try w.put(name[1]);
                try w.path(.from(d.b));
                try w.put(d.c);
            },
            .param, .env, .msg => {
                try w.put(d.a);
                try w.path(.from(d.b));
                try w.put(d.c);
            },
            .cb => {
                try w.label(.from(d.a));
                try w.path(.from(d.b));
                try w.put(d.c);
            },
            .top => {},
            .elem, .others, .level, .below, .loan => {
                try w.cell(.from(d.a));
                try w.label(.from(d.b));
                try w.put(d.c);
                try w.put(try w.placeLocal(d.place));
                // The split the refinement was taken by, with the
                // container's κ at it (§2.2), when there is one.
                const s = cells.findSplit(.from(d.a), .from(d.b));
                if (s == .none) {
                    try w.put(0);
                } else {
                    const split = cells.splitOf(s);
                    try w.put(1);
                    try w.put(split.inst);
                    try w.cond(split.cond);
                }
            },
            .mark => {
                try w.put(d.a);
                // A written field's rank is a field rank like a step's.
                try w.put(if (d.a == @backingInt(Cell.Mark.field)) w.names.place.field(w.names.place.ctx, d.b) else d.b);
            },
        }
    }

    const Keyed = struct { key: u64, id: u32, bit: u32 = 0 };

    fn sortKeyed(w: *Writer, items: []Keyed) Error!void {
        try chargeSort(w.env, items.len);
        std.mem.sort(Keyed, items, {}, struct {
            fn less(_: void, a: Keyed, b: Keyed) bool {
                return a.key < b.key;
            }
        }.less);
    }

    fn cellSet(w: *Writer, s: SetId) Error!void {
        try w.tag(.set);
        var members: std.ArrayList(Keyed) = .empty;
        defer members.deinit(w.env.gpa);
        var it = w.env.cells.sets.iterate(s);
        while (it.next()) |e| try members.append(w.env.gpa, .{ .key = mix(&.{ try w.cellHash(.from(e.key)), e.value }), .id = e.key, .bit = e.value });
        try w.sortKeyed(members.items);
        try w.put(@intCast(members.items.len));
        for (members.items) |m| {
            try w.cell(.from(m.id));
            try w.put(m.bit);
        }
    }

    fn cond(w: *Writer, k: CondId) Error!void {
        try w.tag(.cond);
        try w.put(@backingInt(w.env.conds.kind(k)));
        if (k == Cond.yes or Cond.Table.fails(k)) return;
        try w.atomSet(try w.env.conds.flat(w.env.gpa, w.env.charge, k));
    }

    fn atomSet(w: *Writer, s: SetId) Error!void {
        var atoms: std.ArrayList(Keyed) = .empty;
        defer atoms.deinit(w.env.gpa);
        var it = w.env.conds.atoms.iterate(s);
        while (it.next()) |e| try atoms.append(w.env.gpa, .{ .key = try w.atomHash(.from(e.key)), .id = e.key });
        try w.sortKeyed(atoms.items);
        try w.put(@intCast(atoms.items.len));
        for (atoms.items) |a| try w.atom(.from(a.id));
    }

    fn atom(w: *Writer, id: CondId) Error!void {
        const a = w.env.conds.get(id);
        try w.tag(.atom);
        try w.put(@backingInt(a.atom));
        switch (a.atom) {
            .excl => try w.cell(.from(a.a)),
            .sep => {
                const x: CellId = .from(a.a);
                const y: CellId = .from(a.b);
                const swap = try w.cellHash(y) < try w.cellHash(x);
                try w.cell(if (swap) y else x);
                try w.cell(if (swap) x else y);
            },
            .within => try w.label(.from(a.a)),
            .apart => try w.cellSet(.from(a.a)),
            .keep, .writes => try w.put(a.a),
        }
    }

    fn node(w: *Writer, id: NodeId, at_summary: bool) Error!void {
        const gpa = w.env.gpa;
        try w.env.charge.reserve(gpa, .inspection, 1);
        if (id == .none) return w.tag(.none_node);
        const got = try w.ordinal.getOrPut(gpa, .{ id.int(), try w.ctxLocal(w.ctx) });
        if (got.found_existing) {
            try w.tag(.node_ref);
            return w.put(got.value_ptr.*);
        }
        got.value_ptr.* = w.next;
        w.next += 1;
        const d = w.env.shapes.get(id);
        try w.tag(.node_new);
        try w.put(@backingInt(d.kind));
        try w.put(@intFromBool(at_summary));
        try w.put(try w.placeLocal(d.place));
        // A leaf's and a built node's cells; every other kind's are its
        // parts', which the reader's constructors join again.
        if (d.kind == .leaf or d.kind == .node) try w.cellSet(d.cells);
        if (w.stored(id, at_summary)) |k| {
            try w.put(1);
            try w.cond(k);
        } else try w.put(0);
        switch (d.kind) {
            .leaf => {},
            .node, .delta => {
                if (d.kind == .delta) try w.node(.from(d.a), at_summary);
                var overs: std.ArrayList(Over) = .empty;
                defer overs.deinit(gpa);
                try w.overList(if (d.kind == .node) d.a else d.b, at_summary, &overs);
                try w.put(@intCast(overs.items.len));
                for (overs.items) |o| {
                    try w.step(o.step);
                    try w.node(o.node, o.at_summary);
                }
            },
            .recast => try w.node(.from(d.a), at_summary),
            .@"union", .positions => {
                const a: NodeId = .from(d.a);
                const b: NodeId = .from(d.b);
                const swap = try w.nodeHash(b, at_summary) < try w.nodeHash(a, at_summary);
                try w.node(if (swap) b else a, at_summary);
                try w.node(if (swap) a else b, at_summary);
            },
        }
    }

    fn supplyHash(w: *Writer, s: Summary.Supply) Error!u64 {
        const saved = w.ctx;
        w.ctx = s.kappa;
        defer w.ctx = saved;
        return mix(&.{ 10, s.k, @intFromBool(s.owned), @intFromBool(s.taken), try w.labelHash(s.label), try w.nodeHash(s.node, false) });
    }

    fn supply(w: *Writer, s: Summary.Supply) Error!void {
        try w.tag(.supply);
        try w.put(s.k);
        try w.put(@as(u32, @intFromBool(s.owned)) | (@as(u32, @intFromBool(s.taken)) << 1));
        try w.label(s.label);
        // The handed value under its own snapshot.
        try w.put(try w.ctxLocal(s.kappa));
        const saved = w.ctx;
        w.ctx = s.kappa;
        defer w.ctx = saved;
        try w.node(s.node, false);
    }

    fn keepHash(w: *Writer, k: Summary.Keep) Error!u64 {
        return mix(&.{ 11, k.j, k.k, try w.pathHash(k.kept_path), try w.pathHash(k.written_path), k.writer });
    }

    fn keep(w: *Writer, k: Summary.Keep) Error!void {
        try w.tag(.keep);
        try w.put(k.j);
        try w.put(k.k);
        try w.path(k.kept_path);
        try w.path(k.written_path);
        try w.put(k.writer);
    }

    /// A class's hash, to order nested classes: everything `class` writes.
    fn classHash(w: *Writer, c: ClassId) Error!u64 {
        if (try w.memo(.class, c.int(), 0)) |h| return h;
        const k = w.sums.get(c);
        const saved = w.ctx;
        w.ctx = k.kappas;
        defer w.ctx = saved;
        var acc = mix(&.{ 12, k.params.len, @as(u64, @intFromBool(k.writes)) | (@as(u64, @intFromBool(k.entry)) << 1) | (@as(u64, @intFromBool(k.refs_top)) << 2), @backingInt(k.origin), try w.nodeHash(k.res, false) });
        for (w.sums.paramUses(c)) |u| acc = mix(&.{ acc, try w.nodeHash(u, false) });
        acc = mix(&.{ acc, try w.atomSetHash(k.xreq) });
        for (0..k.funs.len) |i| {
            const f = w.sums.fun(c, @intCast(i));
            var hs: std.ArrayList(u64) = .empty;
            defer hs.deinit(w.env.gpa);
            for (0..f.supplies.len) |s| try hs.append(w.env.gpa, try w.supplyHash(w.sums.supply(f, @intCast(s))));
            for (0..f.keeps.len) |s| try hs.append(w.env.gpa, try w.keepHash(w.sums.keepOf(f, @intCast(s))));
            acc = try w.sortedMix(mix(&.{ acc, f.j, @backingInt(f.calls), @as(u64, @intFromBool(f.need)) | (@as(u64, @intFromBool(f.seen)) << 1) }), hs.items);
        }
        var rest: std.ArrayList(u64) = .empty;
        defer rest.deinit(w.env.gpa);
        for (0..k.slots.len) |i| {
            const s = w.sums.slot(c, @intCast(i));
            try rest.append(w.env.gpa, mix(&.{ 13, s.param, try w.pathHash(s.path) }));
        }
        for (w.sums.nestedOf(c)) |x| try rest.append(w.env.gpa, try w.classHash(x));
        for (w.sums.oncesOf(c)) |p| try rest.append(w.env.gpa, mix(&.{ 14, try w.pathHash(p) }));
        acc = try w.sortedMix(acc, rest.items);
        return w.remember(.class, c.int(), 0, mix(&.{ acc, try w.setHash(k.refs) }));
    }

    fn class(w: *Writer, c: ClassId) Error!void {
        const gpa = w.env.gpa;
        try w.env.charge.reserve(gpa, .inspection, 1);
        const k = w.sums.get(c);
        const saved = w.ctx;
        w.ctx = k.kappas;
        defer w.ctx = saved;
        try w.tag(.class);
        try w.put(try w.ctxLocal(k.kappas));
        try w.put(k.params.len);
        try w.put(@as(u32, @intFromBool(k.writes)) | (@as(u32, @intFromBool(k.entry)) << 1) | (@as(u32, @intFromBool(k.refs_top)) << 2));
        try w.put(@backingInt(k.origin));
        try w.node(k.res, false);
        for (w.sums.paramUses(c)) |u| try w.node(u, false);
        try w.atomSet(k.xreq);
        try w.put(k.funs.len);
        for (0..k.funs.len) |i| {
            const f = w.sums.fun(c, @intCast(i));
            try w.tag(.fun);
            try w.put(f.j);
            try w.put(@backingInt(f.calls));
            try w.put(@as(u32, @intFromBool(f.need)) | (@as(u32, @intFromBool(f.seen)) << 1));
            var items: std.ArrayList(Keyed) = .empty;
            defer items.deinit(gpa);
            for (0..f.supplies.len) |s| try items.append(gpa, .{ .key = try w.supplyHash(w.sums.supply(f, @intCast(s))), .id = @intCast(s) });
            try w.sortKeyed(items.items);
            try w.put(@intCast(items.items.len));
            for (items.items) |it| try w.supply(w.sums.supply(f, it.id));
            items.clearRetainingCapacity();
            for (0..f.keeps.len) |s| try items.append(gpa, .{ .key = try w.keepHash(w.sums.keepOf(f, @intCast(s))), .id = @intCast(s) });
            try w.sortKeyed(items.items);
            try w.put(@intCast(items.items.len));
            for (items.items) |it| try w.keep(w.sums.keepOf(f, it.id));
        }
        var items: std.ArrayList(Keyed) = .empty;
        defer items.deinit(gpa);
        for (0..k.slots.len) |i| {
            const s = w.sums.slot(c, @intCast(i));
            try items.append(gpa, .{ .key = mix(&.{ 13, s.param, try w.pathHash(s.path) }), .id = @intCast(i) });
        }
        try w.sortKeyed(items.items);
        try w.put(@intCast(items.items.len));
        for (items.items) |it| {
            const s = w.sums.slot(c, it.id);
            try w.tag(.slot);
            try w.put(s.param);
            try w.path(s.path);
        }
        items.clearRetainingCapacity();
        const nested = w.sums.nestedOf(c);
        for (nested, 0..) |x, i| try items.append(gpa, .{ .key = try w.classHash(x), .id = @intCast(i) });
        try w.sortKeyed(items.items);
        try w.put(@intCast(items.items.len));
        for (items.items) |it| try w.class(nested[it.id]);
        items.clearRetainingCapacity();
        const once = w.sums.oncesOf(c);
        for (once, 0..) |p, i| try items.append(gpa, .{ .key = mix(&.{ 14, try w.pathHash(p) }), .id = @intCast(i) });
        try w.sortKeyed(items.items);
        try w.put(@intCast(items.items.len));
        for (items.items) |it| try w.path(once[it.id]);
        try w.cellSet(k.refs);
    }
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// The classes of a block, built in `env`'s tables and appended to `out`;
/// null when the words are not a block this version wrote. The block is
/// decoded first into tables of its own: a block that does not decode
/// leaves `env`'s tables and `out` as they were.
pub fn read(env: Env, sums: *Summary.Table, words: []const u32, remap: Remap, out: *std.ArrayList(ClassId)) ReadError!?void {
    const gpa = env.gpa;
    // The trial: fresh tables, charged to the caller like the real read.
    {
        var t: Scratch = .{};
        try t.init(gpa);
        defer t.deinit(gpa);
        var trial: std.ArrayList(ClassId) = .empty;
        defer trial.deinit(gpa);
        var r: Reader = .{ .env = t.env(gpa), .sums = &t.sums, .words = words, .remap = remap };
        defer r.deinit();
        const ok = if (r.all(&trial)) true else |err| switch (err) {
            error.Malformed, error.BlockConflict => false,
            error.OwnershipLimit, error.AccountingInvariant => false,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const spent = t.account.growth;
        try env.charge.reserve(gpa, .inspection, @intCast(@min(spent, std.math.maxInt(u32))));
        if (!ok) return null;
    }
    const mark = out.items.len;
    var r: Reader = .{ .env = env, .sums = sums, .words = words, .remap = remap };
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

/// Tables of their own for a trial read.
const Scratch = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    conds: Cond.Table = undefined,
    sums: Summary.Table = .{},
    account: Ids.Account = .{},

    fn init(t: *Scratch, gpa: Allocator) Error!void {
        // The trial is the caller's work, charged to the caller once it is
        // done; its own account only counts it.
        t.account.allowance = std.math.maxInt(u32);
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
    ctx: Cond.Kappas = .none,
    /// The block's places, in local order, once each is in `env.places`.
    places: std.ArrayList(PlaceId) = .empty,
    /// Where each local place's record starts in `words`.
    place_at: std.ArrayList(u32) = .empty,
    /// The nodes by ordinal; `.none` while one is still being read.
    nodes: std.ArrayList(NodeId) = .empty,
    /// The κ maps by the writer's local number, built as nodes arrive.
    maps: std.ArrayList(Cond.Kappas) = .empty,
    /// The local number `ctx` is being built as.
    ctx_index: u32 = none,
    /// The first type-variable number the block's places take.
    place_base: u32 = 0,

    const Failure = ReadError || error{Malformed};

    fn deinit(r: *Reader) void {
        r.places.deinit(r.env.gpa);
        r.place_at.deinit(r.env.gpa);
        r.nodes.deinit(r.env.gpa);
        r.maps.deinit(r.env.gpa);
    }

    const Saved = struct { ctx: Cond.Kappas, index: u32 };

    /// Build into map `i`: the one built so far, or a new empty one.
    fn enter(r: *Reader, i: u32) Failure!Saved {
        if (i > r.maps.items.len) return error.Malformed;
        if (i == r.maps.items.len) try r.maps.append(r.env.gpa, .none);
        const saved: Saved = .{ .ctx = r.ctx, .index = r.ctx_index };
        r.ctx = r.maps.items[i];
        r.ctx_index = i;
        return saved;
    }

    fn leave(r: *Reader, saved: Saved) void {
        if (r.ctx_index != none) r.maps.items[r.ctx_index] = r.ctx;
        r.ctx = saved.ctx;
        r.ctx_index = saved.index;
    }

    fn get(r: *Reader) Failure!u32 {
        if (r.at >= r.words.len) return error.Malformed;
        r.at += 1;
        return r.words[r.at - 1];
    }

    fn expect(r: *Reader, t: Tag) Failure!void {
        if (try r.get() != @backingInt(t)) return error.Malformed;
    }

    fn enumOf(comptime E: type, x: u32) Failure!E {
        if (x > std.math.maxInt(@typeInfo(E).@"enum".tag_type)) return error.Malformed;
        return std.enums.fromInt(E, x) orelse error.Malformed;
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

    fn all(r: *Reader, out: *std.ArrayList(ClassId)) Failure!void {
        const gpa = r.env.gpa;
        if (try r.get() != magic or try r.get() != version) return error.Malformed;
        const n_places = try r.get();
        // The block's places take type-variable numbers no place of the
        // reader's table has: they meet nothing of the module's or of
        // another block's (§3.6's structural re-interning is S6's).
        r.place_base = r.env.places.freshVar();
        if (n_places > std.math.maxInt(u32) - r.place_base) return error.Malformed;
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
                const kind = try enumOf(Place.StepKind, try r.get());
                const a = try r.get();
                const b = if (kind == .ctor_arg) try r.get() else 0;
                _ = try r.stepFrom(kind, a, b);
                if (try r.get() >= n_places) return error.Malformed;
            }
        }
        var failed: ?Failure = null;
        var source: Describe = .{ .r = r, .failed = &failed };
        i = 0;
        while (i < n_places) : (i += 1) {
            // The block's place locals are a type-variable space of their own
            // in the reader's table (§3.6's re-interning onto a module's own
            // graph is S6's).
            try r.places.append(gpa, try r.env.places.of(gpa, r.env.account(), .{ .ctx = &source, .describe = Describe.describe }, r.place_base + i));
            if (failed) |e| return e;
        }
        const n_classes = try r.get();
        i = 0;
        while (i < n_classes) : (i += 1) try out.append(gpa, try r.class());
        if (r.at != r.words.len) return error.Malformed;
    }

    const Describe = struct {
        r: *Reader,
        failed: *?Failure,

        fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
            const d: *Describe = @ptrCast(@alignCast(ctx));
            const r = d.r;
            var at: usize = r.place_at.items[v - r.place_base];
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
                try out.append(r.env.gpa, .{ .step = s, .@"var" = r.place_base + r.words[at] });
                at += 1;
            }
            return .{ .kind = k, .head = if (k == .tuple or k == .record) head else r.remap.place.head(r.remap.place.ctx, head) };
        }
    };

    fn placeOf(r: *Reader) Failure!PlaceId {
        const i = try r.get();
        if (i >= r.places.items.len) return error.Malformed;
        return r.places.items[i];
    }

    fn stepOf(r: *Reader) Failure!Step {
        const kind = try enumOf(Place.StepKind, try r.get());
        const a = try r.get();
        const b = if (kind == .ctor_arg) try r.get() else 0;
        return r.stepFrom(kind, a, b);
    }

    fn path(r: *Reader) Failure!PathId {
        try r.expect(.path);
        const depth = try r.get();
        if (depth == none) return .none;
        var p = try r.env.places.rootPath(r.env.gpa, try r.placeOf());
        var i: u32 = 0;
        while (i < depth) : (i += 1) {
            try r.env.charge.reserve(r.env.gpa, .inspection, 1);
            p = (try r.env.places.extend(r.env.gpa, r.env.charge, p, try r.stepOf())) orelse return error.Malformed;
        }
        return p;
    }

    fn label(r: *Reader) Failure!LabelId {
        try r.expect(.label);
        const inst = try r.get();
        if (inst == none) return .none;
        const folded = try r.get();
        if (folded > 1) return error.Malformed;
        const callee = try r.label();
        return r.env.cells.label(r.env.gpa, r.env.account(), r.remap.inst(r.remap.ctx, inst), callee, folded == 1);
    }

    fn cell(r: *Reader) Failure!CellId {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const cells = r.env.cells;
        try r.expect(.cell);
        const o = try enumOf(Cell.Origin, try r.get());
        const kind = try enumOf(Cell.Kind, try r.get());
        switch (o) {
            .site => {
                const inst = r.remap.inst(r.remap.ctx, try r.get());
                return cells.site(gpa, acct, inst, try r.placeOf(), kind);
            },
            .result, .esc => {
                const l = try r.label();
                const k = try r.get();
                return cells.result(gpa, acct, o, l, k, try r.placeOf(), kind);
            },
            .shared => {
                const name = try r.get();
                const ordinal = try r.get();
                const index = r.remap.decl(r.remap.ctx, name, ordinal) orelse return error.Malformed;
                const p = try r.path();
                if (p == .none) return error.Malformed;
                return cells.symbolic(gpa, acct, r.env.places, o, index, p, try r.get());
            },
            .param, .env, .msg => {
                const index = try r.get();
                const p = try r.path();
                if (p == .none) return error.Malformed;
                return cells.symbolic(gpa, acct, r.env.places, o, index, p, try r.get());
            },
            .cb => {
                const l = try r.label();
                const p = try r.path();
                if (p == .none) return error.Malformed;
                return cells.symbolic(gpa, acct, r.env.places, .cb, l.int(), p, try r.get());
            },
            .top => return cells.top(gpa, acct),
            .elem, .others, .level, .below, .loan => {
                const parent = try r.cell();
                const l = try r.label();
                const step = try r.get();
                const at = try r.placeOf();
                const has_split = try r.get();
                if (has_split > 1) return error.Malformed;
                if (has_split == 1) {
                    const inst = try r.get();
                    const k = try r.cond();
                    // A split made on first sight keeps its condition: one
                    // that is there with another would change what the
                    // reader's tables mean.
                    const existing = cells.findSplit(parent, l);
                    if (existing != .none and cells.splitOf(existing).cond != k) return error.BlockConflict;
                    _ = try cells.split(gpa, acct, parent, inst, l, k);
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

    fn cellSet(r: *Reader) Failure!SetId {
        try r.expect(.set);
        const n = try r.get();
        var s: SetId = .none;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = try r.cell();
            const bit = try r.get();
            if (bit > 1) return error.Malformed;
            s = try r.env.cells.sets.insert(r.env.gpa, r.env.charge, s, c.int(), @intCast(bit));
        }
        return s;
    }

    fn cond(r: *Reader) Failure!CondId {
        try r.expect(.cond);
        const kind = try enumOf(Cond.Kind, try r.get());
        switch (kind) {
            .yes => return Cond.yes,
            .shared => return Cond.shared,
            .lost => return Cond.lost,
            .@"and", .atom => return r.atoms(),
        }
    }

    /// An atom set, conjoined.
    fn atoms(r: *Reader) Failure!CondId {
        const gpa = r.env.gpa;
        const t = r.env.conds;
        const charge = r.env.charge;
        const n = try r.get();
        var acc = Cond.yes;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try r.expect(.atom);
            const k = try enumOf(Cond.AtomKind, try r.get());
            const a = switch (k) {
                .excl => try t.excl(gpa, charge, try r.cell()),
                .sep => blk: {
                    const x = try r.cell();
                    break :blk try t.sepAtom(gpa, charge, x, try r.cell());
                },
                .within => try t.within(gpa, charge, try r.label()),
                .apart => try t.apartAtom(gpa, charge, try r.cellSet()),
                .keep => try t.keep(gpa, charge, try r.get()),
                .writes => try t.writes(gpa, charge, try r.get()),
            };
            acc = try t.@"and"(gpa, charge, acc, a);
        }
        return acc;
    }

    fn overs(r: *Reader) Failure!u32 {
        const n = try r.get();
        var root: u32 = none;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const s = try r.stepOf();
            root = try r.env.shapes.overPut(r.env.gpa, r.env.account(), root, s, try r.child());
        }
        return root;
    }

    /// A node that must be there: a child, a side, an inner.
    fn child(r: *Reader) Failure!NodeId {
        const n = try r.node();
        if (n == .none) return error.Malformed;
        return n;
    }

    fn node(r: *Reader) Failure!NodeId {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const shapes = r.env.shapes;
        try r.env.charge.reserve(gpa, .inspection, 1);
        const t = try enumOf(Tag, try r.get());
        switch (t) {
            .none_node => return .none,
            .node_ref => {
                const o = try r.get();
                if (o >= r.nodes.items.len) return error.Malformed;
                // A node that is still being read cannot be its own part.
                if (r.nodes.items[o] == .none) return error.Malformed;
                return r.nodes.items[o];
            },
            .node_new => {},
            else => return error.Malformed,
        }
        const kind = try enumOf(Shape.Kind, try r.get());
        const at_summary = try r.get();
        if (at_summary > 1) return error.Malformed;
        const at = try r.placeOf();
        const cells: SetId = if (kind == .leaf or kind == .node) try r.cellSet() else .none;
        const has_k = try r.get();
        if (has_k > 1) return error.Malformed;
        const k: ?CondId = if (has_k == 1) try r.cond() else null;
        // The ordinal is handed out before the children are read, as the
        // writer numbered it.
        const slot = r.nodes.items.len;
        try r.nodes.append(gpa, .none);
        const id: NodeId = switch (kind) {
            .leaf => try shapes.leaf(gpa, acct, at, cells),
            .node => try shapes.node(gpa, acct, at, cells, try r.overs()),
            .delta => blk: {
                const base = try r.child();
                if (shapes.kind(base) == .delta) return error.Malformed;
                break :blk try shapes.delta(gpa, acct, base, try r.overs());
            },
            .recast => try shapes.recast(gpa, acct, at, try r.child()),
            .@"union" => blk: {
                const a = try r.child();
                break :blk try shapes.@"union"(gpa, acct, &r.env.cells.sets, a, try r.child());
            },
            .positions => blk: {
                const a = try r.child();
                break :blk try shapes.collect(gpa, acct, &r.env.cells.sets, &.{ a, try r.child() });
            },
        };
        r.nodes.items[slot] = id;
        // The κ the writer's map stored, stored again; the rest derives.
        if (k) |cond_k| r.ctx = (try r.env.conds.kappaSet(gpa, r.env.charge, r.ctx, id, at_summary == 1, cond_k)).ctx;
        return id;
    }

    fn class(r: *Reader) Failure!ClassId {
        const gpa = r.env.gpa;
        try r.env.charge.reserve(gpa, .inspection, 1);
        try r.expect(.class);
        const saved = try r.enter(try r.get());
        defer r.leave(saved);
        const n_params = try r.get();
        if (n_params > r.words.len) return error.Malformed;
        const flags = try r.get();
        if (flags > 7) return error.Malformed;
        const origin = try enumOf(Summary.Origin, try r.get());
        const res = try r.node();
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        var i: u32 = 0;
        while (i < n_params) : (i += 1) try params.append(gpa, try r.node());
        const xreq_cond = try r.atoms();
        var funs: std.ArrayList(Summary.DraftFun) = .empty;
        defer funs.deinit(gpa);
        var supplies: std.ArrayList(Summary.Supply) = .empty;
        defer supplies.deinit(gpa);
        var keeps: std.ArrayList(Summary.Keep) = .empty;
        defer keeps.deinit(gpa);
        var runs: std.ArrayList([4]u32) = .empty;
        defer runs.deinit(gpa);
        const n_funs = try r.get();
        i = 0;
        while (i < n_funs) : (i += 1) {
            try r.expect(.fun);
            const j = try r.get();
            const calls = try enumOf(Summary.Calls, try r.get());
            const bits = try r.get();
            if (bits > 3) return error.Malformed;
            const s_start: u32 = @intCast(supplies.items.len);
            const n_s = try r.get();
            var s: u32 = 0;
            while (s < n_s) : (s += 1) {
                try r.expect(.supply);
                const k = try r.get();
                const sb = try r.get();
                if (sb > 3) return error.Malformed;
                const l = try r.label();
                // The handed value under its own snapshot.
                const outer = try r.enter(try r.get());
                const n = r.node() catch |e| {
                    r.leave(outer);
                    return e;
                };
                const kappa = r.ctx;
                r.leave(outer);
                try supplies.append(gpa, .{ .j = j, .k = k, .node = n, .label = l, .owned = sb & 1 == 1, .taken = sb & 2 == 2, .kappa = kappa });
            }
            const k_start: u32 = @intCast(keeps.items.len);
            const n_k = try r.get();
            s = 0;
            while (s < n_k) : (s += 1) {
                try r.expect(.keep);
                const kj = try r.get();
                const kk = try r.get();
                const kept = try r.path();
                const written = try r.path();
                try keeps.append(gpa, .{ .j = kj, .k = kk, .kept_path = kept, .written_path = written, .writer = try r.get() });
            }
            try funs.append(gpa, .{ .j = j, .calls = calls, .need = bits & 1 == 1, .seen = bits & 2 == 2 });
            try runs.append(gpa, .{ s_start, n_s, k_start, n_k });
        }
        for (funs.items, runs.items) |*f, run| {
            f.supplies = supplies.items[run[0]..][0..run[1]];
            f.keeps = keeps.items[run[2]..][0..run[3]];
        }
        var slots: std.ArrayList(Summary.Slot) = .empty;
        defer slots.deinit(gpa);
        const n_slots = try r.get();
        i = 0;
        while (i < n_slots) : (i += 1) {
            try r.expect(.slot);
            const p = try r.get();
            try slots.append(gpa, .{ .param = p, .path = try r.path() });
        }
        var nested: std.ArrayList(ClassId) = .empty;
        defer nested.deinit(gpa);
        const n_nested = try r.get();
        i = 0;
        while (i < n_nested) : (i += 1) try nested.append(gpa, try r.class());
        var once: std.ArrayList(PathId) = .empty;
        defer once.deinit(gpa);
        const n_once = try r.get();
        i = 0;
        while (i < n_once) : (i += 1) try once.append(gpa, try r.path());
        const refs = try r.cellSet();
        return r.sums.add(r.env, .{
            .params = params.items,
            .res = res,
            .kappas = r.ctx,
            .xreq = if (xreq_cond == Cond.yes) .none else try r.env.conds.flat(gpa, r.env.charge, xreq_cond),
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
/// 7 `List { a : List Int }`.
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
    // Not asserted: that a table which built the same rows in another
    // order writes the same bytes. `Cell.internCell` keys a `result`,
    // `site` or refinement cell without its place, so the cell keeps the
    // place of the first row that made it, and the block writes that place
    // (S6 decides whether the key takes the place or the record drops it).
    // Within one module the order is the schedule's (§3.8), so the bytes
    // are still a function of the module.
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

test "a node that refers to itself while it is read is no block" {
    // magic, version, one place (a leaf list), one class whose res is a
    // node whose child is a reference to itself.
    const words = [_]u32{
        magic,                        version,                        1,
        @backingInt(Place.Kind.list), 200,                            0,
        0,                            1,                              0,
        0,                            0,                              0,
        @backingInt(Tag.node_new),    @backingInt(Shape.Kind.recast), 0,
        0,                            0,                              @backingInt(Tag.node_ref),
        0,
    };
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(try read(t.env(), &t.sums, &words, .identity, &out) == null);
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
