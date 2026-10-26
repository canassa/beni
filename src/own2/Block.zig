//! L11: the ownership block (`docs/design/ownership-v2.md` §3.6), minimal:
//! classes to words and back, with places written structurally. S2b builds
//! the class table and its records — a header (`OWN2`, the version), the
//! place table, then each class by one canonical walk — and nothing of S6's:
//! no lazy directory, no cache section, no traversal marks. The block names
//! nothing by session id: a place is its kind, its head and its children
//! (a head and a field's rank through the writer's `Names`), a cell its
//! origin and canonical path, a node its first-visit ordinal (an already
//! numbered node is a backreference), and every set is written in the order
//! of its members' spellings, so the bytes do not depend on which table or
//! which order built a class. A reader builds the class again in tables of
//! its own (`read`), and writing it there gives the same bytes.
//!
//! Every record a class reaches is reserved on the writer's and the
//! reader's charge before it is read or made (§4.1), and a block that does
//! not decode is no block (R-5.7.4): `read` answers null, never an empty
//! class.
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

/// `"OWN2"`, little-endian.
pub const magic: u32 = 0x324e574f;
/// The minimal block's format. S6's directory and traversal marks bump it.
pub const version: u32 = 1;

const none: u32 = Ids.none_int;

const Tag = enum(u32) { class, node_new, node_ref, none_node, cell, set, cond, atom, fun, supply, keep, slot, path, label };

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Write `classes` as one block: header, place table, classes. `names`
/// writes a nominal head and a field's rank as the block's own numbers.
pub fn write(env: Env, sums: *Summary.Table, classes: []const ClassId, names: Place.Names, out: *std.ArrayList(u32)) Error!void {
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
        try w.put(if (k == .tuple or k == .record) env.places.head(p) else names.head(names.ctx, env.places.head(p)));
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

const Writer = struct {
    env: Env,
    sums: *Summary.Table,
    names: Place.Names,
    out: *std.ArrayList(u32) = undefined,
    ctx: Cond.Kappas = .none,
    /// A sort key's spelling: places structural and inline, no ordinal or
    /// local is handed out, so the key does not depend on what came first.
    key_mode: bool = false,
    /// `(node, map local)` → first-visit ordinal: one node under two maps
    /// is two records, each with its own κ.
    ordinal: Ids.FixedDict(2) = .{},
    /// A κ map's local number, in first-use order: what a node's ordinal is
    /// keyed by and what a class or a supply names its map by, so a reader
    /// shares a map exactly where the writer did.
    ctx_local: Ids.FixedDict(1) = .{},
    ctx_next: u32 = 0,
    next: u32 = 0,
    place_local: Ids.FixedDict(1) = .{},
    place_order: std.ArrayList(PlaceId) = .empty,

    fn deinit(w: *Writer) void {
        w.ordinal.deinit(w.env.gpa);
        w.ctx_local.deinit(w.env.gpa);
        w.place_local.deinit(w.env.gpa);
        w.place_order.deinit(w.env.gpa);
    }

    fn ctxLocal(w: *Writer, k: Cond.Kappas) Error!u32 {
        const got = try w.ctx_local.getOrPut(w.env.gpa, .{k.int()});
        if (!got.found_existing) {
            got.value_ptr.* = w.ctx_next;
            w.ctx_next += 1;
        }
        return got.value_ptr.*;
    }

    fn put(w: *Writer, x: u32) Error!void {
        try w.out.append(w.env.gpa, x);
    }

    fn tag(w: *Writer, t: Tag) Error!void {
        try w.put(@backingInt(t));
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

    fn place(w: *Writer, p: PlaceId) Error!void {
        if (!w.key_mode) return w.put(try w.placeLocal(p));
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(w.env.gpa);
        try w.env.places.encode(w.env.gpa, p, w.names, &words);
        try w.put(@intCast(words.items.len));
        try w.out.appendSlice(w.env.gpa, words.items);
    }

    fn step(w: *Writer, s: Step) Error!void {
        try w.put(@backingInt(s.kind));
        switch (s.kind) {
            .field => try w.put(w.names.field(w.names.ctx, s.payload)),
            .ctor_arg => {
                const pair = w.env.places.ctorArgOf(s);
                try w.put(pair[0]);
                try w.put(pair[1]);
            },
            else => try w.put(s.payload),
        }
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
        try w.place(places.pathPlace(at));
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
                try w.place(d.place);
            },
            .result, .esc => {
                try w.label(.from(d.a));
                try w.put(d.b);
                try w.place(d.place);
            },
            .param, .env, .msg, .shared => {
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
                try w.place(d.place);
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
                try w.put(d.b);
            },
        }
    }

    /// Spell `arg` with `spell` into a buffer of its own, as a sort key.
    fn key(w: *Writer, comptime spell: anytype, arg: anytype) Error![]u32 {
        const gpa = w.env.gpa;
        try w.env.charge.reserve(gpa, .inspection, 1);
        var buf: std.ArrayList(u32) = .empty;
        errdefer buf.deinit(gpa);
        var k: Writer = .{ .env = w.env, .sums = w.sums, .names = w.names, .out = &buf, .ctx = w.ctx, .key_mode = true };
        defer k.deinit();
        try spell(&k, arg);
        return buf.toOwnedSlice(gpa);
    }

    /// Members in the order of their keys, each then written for real.
    fn sorted(w: *Writer, comptime T: type, items: []const T, comptime spell: anytype) Error!void {
        const gpa = w.env.gpa;
        const Keyed = struct { key: []u32, item: T };
        var keyed: std.ArrayList(Keyed) = .empty;
        defer {
            for (keyed.items) |k| gpa.free(k.key);
            keyed.deinit(gpa);
        }
        for (items) |x| try keyed.append(gpa, .{ .key = try w.key(spell, x), .item = x });
        std.mem.sort(Keyed, keyed.items, {}, struct {
            fn lessThan(_: void, a: Keyed, b: Keyed) bool {
                return std.mem.order(u32, a.key, b.key) == .lt;
            }
        }.lessThan);
        try w.put(@intCast(items.len));
        for (keyed.items) |k| try spell(w, k.item);
    }

    const Member = struct { cell: CellId, bit: u32 };

    fn member(w: *Writer, m: Member) Error!void {
        try w.cell(m.cell);
        try w.put(m.bit);
    }

    fn cellSet(w: *Writer, s: SetId) Error!void {
        try w.tag(.set);
        var members: std.ArrayList(Member) = .empty;
        defer members.deinit(w.env.gpa);
        var it = w.env.cells.sets.iterate(s);
        while (it.next()) |e| try members.append(w.env.gpa, .{ .cell = .from(e.key), .bit = e.value });
        try w.sorted(Member, members.items, member);
    }

    fn cond(w: *Writer, k: CondId) Error!void {
        try w.tag(.cond);
        try w.put(@backingInt(w.env.conds.kind(k)));
        if (k == Cond.yes or Cond.Table.fails(k)) return;
        try w.atomSet(try w.env.conds.flat(w.env.gpa, w.env.charge, k));
    }

    fn atomSet(w: *Writer, s: SetId) Error!void {
        var atoms: std.ArrayList(CondId) = .empty;
        defer atoms.deinit(w.env.gpa);
        var it = w.env.conds.atoms.iterate(s);
        while (it.next()) |e| try atoms.append(w.env.gpa, .from(e.key));
        try w.sorted(CondId, atoms.items, atom);
    }

    fn atom(w: *Writer, id: CondId) Error!void {
        const a = w.env.conds.get(id);
        try w.tag(.atom);
        try w.put(@backingInt(a.atom));
        switch (a.atom) {
            .excl => try w.cell(.from(a.a)),
            .sep => try w.sorted(CellId, &.{ .from(a.a), .from(a.b) }, cell),
            .within => try w.label(.from(a.a)),
            .apart => try w.cellSet(.from(a.a)),
            .keep, .writes => try w.put(a.a),
        }
    }

    const Over = struct { step: Step, node: NodeId, at_summary: bool };

    fn over(w: *Writer, o: Over) Error!void {
        try w.step(o.step);
        try w.node(o.node, o.at_summary);
    }

    fn overStep(w: *Writer, o: Over) Error!void {
        try w.step(o.step);
    }

    fn overs(w: *Writer, root: u32, at_summary: bool) Error!void {
        const gpa = w.env.gpa;
        var entries: std.ArrayList(Over) = .empty;
        defer entries.deinit(gpa);
        var it = w.env.shapes.overEntries(root);
        while (it.next()) |e| try entries.append(gpa, .{ .step = e.step, .node = e.node, .at_summary = at_summary or e.step.kind == .elem or e.step.kind == .level });
        // By the step's spelling: a `C#i`'s intern index is this table's.
        const Keyed = struct { key: []u32, o: Over };
        var keyed: std.ArrayList(Keyed) = .empty;
        defer {
            for (keyed.items) |k| gpa.free(k.key);
            keyed.deinit(gpa);
        }
        for (entries.items) |o| try keyed.append(gpa, .{ .key = try w.key(overStep, o), .o = o });
        std.mem.sort(Keyed, keyed.items, {}, struct {
            fn lessThan(_: void, a: Keyed, b: Keyed) bool {
                return std.mem.order(u32, a.key, b.key) == .lt;
            }
        }.lessThan);
        try w.put(@intCast(keyed.items.len));
        for (keyed.items) |k| try w.over(k.o);
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
        try w.place(d.place);
        try w.cellSet(d.cells);
        try w.cond(try w.env.conds.kappaOf(gpa, w.env.charge, w.env.view(), w.ctx, id, at_summary));
        switch (d.kind) {
            .leaf => {},
            .node => try w.overs(d.a, at_summary),
            .delta => {
                try w.node(.from(d.a), at_summary);
                try w.overs(d.b, at_summary);
            },
            .recast => try w.node(.from(d.a), at_summary),
            .@"union", .positions => {
                // A union's sides in their table's order: write them by
                // their spellings (a positions node is a multiset).
                const sides = [_]NodeId{ .from(d.a), .from(d.b) };
                const ka = try w.key(nodeKey, sides[0]);
                defer gpa.free(ka);
                const kb = try w.key(nodeKey, sides[1]);
                defer gpa.free(kb);
                const swap = std.mem.order(u32, kb, ka) == .lt;
                try w.node(sides[if (swap) 1 else 0], at_summary);
                try w.node(sides[if (swap) 0 else 1], at_summary);
            },
        }
    }

    fn nodeKey(w: *Writer, id: NodeId) Error!void {
        try w.node(id, false);
    }

    const SupplyAt = struct { f: Summary.Fun, i: u32 };

    fn supply(w: *Writer, at: SupplyAt) Error!void {
        const s = w.sums.supply(at.f, at.i);
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

    fn keepOf(w: *Writer, at: SupplyAt) Error!void {
        const k = w.sums.keepOf(at.f, at.i);
        try w.tag(.keep);
        try w.put(k.j);
        try w.put(k.k);
        try w.path(k.kept_path);
        try w.path(k.written_path);
        try w.put(k.writer);
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
            var items: std.ArrayList(SupplyAt) = .empty;
            defer items.deinit(gpa);
            for (0..f.supplies.len) |s| try items.append(gpa, .{ .f = f, .i = @intCast(s) });
            try w.sorted(SupplyAt, items.items, supply);
            items.clearRetainingCapacity();
            for (0..f.keeps.len) |s| try items.append(gpa, .{ .f = f, .i = @intCast(s) });
            try w.sorted(SupplyAt, items.items, keepOf);
        }
        try w.put(k.slots.len);
        for (0..k.slots.len) |i| {
            const s = w.sums.slot(c, @intCast(i));
            try w.tag(.slot);
            try w.put(s.param);
            try w.path(s.path);
        }
        try w.put(k.classes.len);
        for (w.sums.nestedOf(c)) |x| try w.class(x);
        try w.sorted(PathId, w.sums.oncesOf(c), path);
        try w.cellSet(k.refs);
    }
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// The classes of a block, built in `env`'s tables and appended to `out`;
/// null when the words are not a block this version wrote (a decode
/// failure leaves `out` as it was).
pub fn read(env: Env, sums: *Summary.Table, words: []const u32, remap: Place.Remap, out: *std.ArrayList(ClassId)) Error!?void {
    const mark = out.items.len;
    var r: Reader = .{ .env = env, .sums = sums, .words = words, .remap = remap };
    defer r.deinit();
    r.all(out) catch |err| switch (err) {
        error.Malformed => {
            out.shrinkRetainingCapacity(mark);
            return null;
        },
        else => |e| return e,
    };
}

const Reader = struct {
    env: Env,
    sums: *Summary.Table,
    words: []const u32,
    remap: Place.Remap,
    at: usize = 0,
    ctx: Cond.Kappas = .none,
    /// The block's places, in local order, once each is in `env.places`.
    places: std.ArrayList(PlaceId) = .empty,
    /// Where each local place's record starts in `words`.
    place_at: std.ArrayList(u32) = .empty,
    nodes: std.ArrayList(NodeId) = .empty,
    /// The κ maps by the writer's local number, built as nodes arrive.
    maps: std.ArrayList(Cond.Kappas) = .empty,
    /// The local number `ctx` is being built as.
    ctx_index: u32 = none,
    /// A `describe` that could not make a step.
    failed: ?Error = null,

    const ReadError = Error || error{Malformed};

    fn deinit(r: *Reader) void {
        r.places.deinit(r.env.gpa);
        r.place_at.deinit(r.env.gpa);
        r.nodes.deinit(r.env.gpa);
        r.maps.deinit(r.env.gpa);
    }

    const Saved = struct { ctx: Cond.Kappas, index: u32 };

    /// Build into map `i`: the one built so far, or a new empty one.
    fn enter(r: *Reader, i: u32) ReadError!Saved {
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

    fn get(r: *Reader) ReadError!u32 {
        if (r.at >= r.words.len) return error.Malformed;
        r.at += 1;
        return r.words[r.at - 1];
    }

    fn expect(r: *Reader, t: Tag) ReadError!void {
        if (try r.get() != @backingInt(t)) return error.Malformed;
    }

    fn enumOf(comptime E: type, x: u32) ReadError!E {
        return std.enums.fromInt(E, x) orelse error.Malformed;
    }

    fn all(r: *Reader, out: *std.ArrayList(ClassId)) ReadError!void {
        const gpa = r.env.gpa;
        if (try r.get() != magic or try r.get() != version) return error.Malformed;
        const n_places = try r.get();
        // Each place record: kind, head, holds, n, then n × (step, child).
        var i: u32 = 0;
        while (i < n_places) : (i += 1) {
            try r.env.charge.reserve(gpa, .inspection, 1);
            try r.place_at.append(gpa, @intCast(r.at));
            if (r.at + 4 > r.words.len) return error.Malformed;
            const k = try enumOf(Place.Kind, r.words[r.at]);
            const n = r.words[r.at + 3];
            r.at += 4;
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                const kind = try enumOf(Place.StepKind, try r.get());
                _ = try r.get();
                if (kind == .ctor_arg) _ = try r.get();
                if (try r.get() >= n_places) return error.Malformed;
            }
            _ = k;
        }
        const source: Place.Source = .{ .ctx = r, .describe = describe };
        i = 0;
        while (i < n_places) : (i += 1) {
            // The block's place locals are a type-variable space of their own
            // in a table the reader owns for this block (§3.6's re-interning
            // onto a module's own graph is S6's).
            try r.places.append(gpa, try r.env.places.of(gpa, r.env.account(), source, i));
            if (r.failed) |e| return e;
        }
        const n_classes = try r.get();
        i = 0;
        while (i < n_classes) : (i += 1) try out.append(gpa, try r.class());
        if (r.at != r.words.len) return error.Malformed;
    }

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const r: *Reader = @ptrCast(@alignCast(ctx));
        var at: usize = r.place_at.items[v];
        const k: Place.Kind = @fromBackingInt(@intCast(r.words[at]));
        const head = r.words[at + 1];
        const n = r.words[at + 3];
        at += 4;
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            const kind: Place.StepKind = @fromBackingInt(@intCast(r.words[at]));
            const s: Step = switch (kind) {
                .field => Step.field(r.env.account(), r.remap.field(r.remap.ctx, r.words[at + 1])) catch |e| fail(r, e),
                .ctor_arg => blk: {
                    const s = r.env.places.ctorStep(r.env.gpa, r.env.account(), r.words[at + 1], r.words[at + 2]) catch |e| fail(r, e);
                    at += 1;
                    break :blk s;
                },
                else => .{ .kind = kind, .payload = @intCast(r.words[at + 1]) },
            };
            try out.append(r.env.gpa, .{ .step = s, .@"var" = r.words[at + 2] });
            at += 3;
        }
        return .{ .kind = k, .head = if (k == .tuple or k == .record) head else r.remap.head(r.remap.ctx, head) };
    }

    fn fail(r: *Reader, e: Error) Step {
        r.failed = e;
        return Step.elem;
    }

    fn placeOf(r: *Reader) ReadError!PlaceId {
        const i = try r.get();
        if (i >= r.places.items.len) return error.Malformed;
        return r.places.items[i];
    }

    fn stepOf(r: *Reader) ReadError!Step {
        const kind = try enumOf(Place.StepKind, try r.get());
        return switch (kind) {
            .field => try Step.field(r.env.account(), r.remap.field(r.remap.ctx, try r.get())),
            .ctor_arg => blk: {
                const c = try r.get();
                break :blk try r.env.places.ctorStep(r.env.gpa, r.env.account(), c, try r.get());
            },
            else => .{ .kind = kind, .payload = @intCast(try r.get()) },
        };
    }

    fn path(r: *Reader) ReadError!PathId {
        try r.expect(.path);
        const depth = try r.get();
        if (depth == none) return .none;
        var p = try r.env.places.rootPath(r.env.gpa, try r.placeOf());
        var i: u32 = 0;
        while (i < depth) : (i += 1) p = (try r.env.places.extend(r.env.gpa, r.env.charge, p, try r.stepOf())) orelse return error.Malformed;
        return p;
    }

    fn label(r: *Reader) ReadError!LabelId {
        try r.expect(.label);
        const inst = try r.get();
        if (inst == none) return .none;
        const folded = try r.get();
        if (folded > 1) return error.Malformed;
        const callee = try r.label();
        return r.env.cells.label(r.env.gpa, r.env.account(), inst, callee, folded == 1);
    }

    fn cell(r: *Reader) ReadError!CellId {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const cells = r.env.cells;
        try r.expect(.cell);
        const o = try enumOf(Cell.Origin, try r.get());
        const kind = try enumOf(Cell.Kind, try r.get());
        switch (o) {
            .site => {
                const inst = try r.get();
                return cells.site(gpa, acct, inst, try r.placeOf(), kind);
            },
            .result, .esc => {
                const l = try r.label();
                const k = try r.get();
                return cells.result(gpa, acct, o, l, k, try r.placeOf(), kind);
            },
            .param, .env, .msg, .shared => {
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
                if (try r.get() == 1) {
                    const inst = try r.get();
                    _ = try cells.split(gpa, acct, parent, inst, l, try r.cond());
                }
                return cells.refine(gpa, acct, o, parent, l, step, at, kind);
            },
            .mark => {
                const m = try enumOf(Cell.Mark, try r.get());
                return cells.mark(gpa, acct, m, try r.get());
            },
        }
    }

    fn cellSet(r: *Reader) ReadError!SetId {
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

    fn cond(r: *Reader) ReadError!CondId {
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
    fn atoms(r: *Reader) ReadError!CondId {
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
                    if (try r.get() != 2) return error.Malformed;
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

    fn overs(r: *Reader) ReadError!u32 {
        const n = try r.get();
        var root: u32 = none;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const s = try r.stepOf();
            root = try r.env.shapes.overPut(r.env.gpa, r.env.account(), root, s, try r.node());
        }
        return root;
    }

    fn node(r: *Reader) ReadError!NodeId {
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
                return r.nodes.items[o];
            },
            .node_new => {},
            else => return error.Malformed,
        }
        const kind = try enumOf(Shape.Kind, try r.get());
        const at_summary = try r.get();
        if (at_summary > 1) return error.Malformed;
        const at = try r.placeOf();
        const cells = try r.cellSet();
        const k = try r.cond();
        // The ordinal is handed out before the children are read, as the
        // writer numbered it.
        const slot = r.nodes.items.len;
        try r.nodes.append(gpa, .none);
        const id: NodeId = switch (kind) {
            .leaf => try shapes.leaf(gpa, acct, at, cells),
            .node => try shapes.node(gpa, acct, at, cells, try r.overs()),
            .delta => blk: {
                const base = try r.node();
                if (base == .none or shapes.kind(base) == .delta) return error.Malformed;
                break :blk try shapes.delta(gpa, acct, base, try r.overs());
            },
            .recast => try shapes.recast(gpa, acct, at, try r.node()),
            .@"union" => blk: {
                const a = try r.node();
                break :blk try shapes.@"union"(gpa, acct, &r.env.cells.sets, a, try r.node());
            },
            .positions => blk: {
                const a = try r.node();
                break :blk try shapes.collect(gpa, acct, &r.env.cells.sets, &.{ a, try r.node() });
            },
        };
        r.nodes.items[slot] = id;
        // Only a κ the map must store: where the derivation answers it, the
        // writer's map had no entry either, and maps the writer shared stay
        // shared.
        if (try r.env.conds.kappaOf(gpa, r.env.charge, r.env.view(), r.ctx, id, at_summary == 1) != k)
            r.ctx = (try r.env.conds.kappaSet(gpa, r.env.charge, r.ctx, id, at_summary == 1, k)).ctx;
        return id;
    }

    fn class(r: *Reader) ReadError!ClassId {
        const gpa = r.env.gpa;
        try r.env.charge.reserve(gpa, .inspection, 1);
        try r.expect(.class);
        const saved = try r.enter(try r.get());
        defer r.leave(saved);
        const n_params = try r.get();
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
                const n = try r.node();
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

test "a block's cost grows with the class: n stores, 25 to 200" {
    var last: u64 = 0;
    for ([_]u32{ 25, 50, 100, 200 }) |n| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        const lists = try t.place(2);
        const list = try t.place(0);
        const params = try testing.allocator.alloc(Rows.Param, n + 1);
        defer testing.allocator.free(params);
        params[0] = .{ .place = lists, .words = wordBits(&.{ .written, .returned }) };
        for (params[1..]) |*p| p.* = .{ .place = list, .words = wordBits(&.{.stored}) };

        const c = try Rows.fromWords(t.env(), &t.sums, .{ .params = params, .result = lists });
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(testing.allocator);
        const before = t.account.growth;
        try write(t.env(), &t.sums, &.{c}, .identity, &words);
        const cost = t.account.growth - before;
        // One record per cell, set member, atom and key: linear in the
        // stores, a sort's log aside.
        try testing.expect(cost <= 60 * @as(u64, n));
        if (last > 0) try testing.expect(cost * 2 < last * 5);
        last = cost;
    }
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
