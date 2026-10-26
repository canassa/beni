//! L12: reading the ownership block (`docs/design/ownership-v2.md` §3.6)
//! that `Block` writes, and the block's tests.
//!
//! `read` decodes into tables of its own first, against the caller's
//! allowance and the room left in its place table, and charges that work to
//! the caller once. A block that does not decode — a part of the wrong kind,
//! a node no constructor makes (sides at two places, a child at a step its
//! place has not), a projected position `proj` does not make — is no block
//! (null, R-5.7.4) and the caller's tables are untouched; one past a limit is
//! the caller's `OwnershipLimit`. Only then is it built in the caller's
//! tables, uncharged, where it cannot meet a limit, its places a namespace
//! of their own (`Place.Table.ofBlock`). A knot's nodes and deltas are nodes
//! no constructor interns, tied once the knot is read; everything else is
//! its constructor's. Each owner's κ map holds the κ each position it reaches
//! was written with; a split that exists with another condition is
//! `error.BlockConflict`.
//!
//! Obligations kept here: none (a faithful decoding: every κ read of what is
//! read is the κ read of what was written).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Block = @import("Block.zig");

const ClassId = Ids.ClassId;
const NodeId = Ids.NodeId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const CondId = Ids.CondId;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const LabelId = Ids.LabelId;
const Step = Place.Step;
const Env = Summary.Env;
const Error = Ids.ChargeError;
pub const ReadError = Block.ReadError;
pub const Remap = Block.Remap;
const Kind = Block.Kind;
const magic = Block.magic;
const version = Block.version;
const none = Block.none;
const write = Block.write;
const Names = Block.Names;
const below = Block.below;

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
    backs: std.ArrayList(Summary.Back) = .empty,
    /// The positions read: each one's node, class, κ and parts, and the
    /// position each ordinal is (`none` for another record).
    infos: std.ArrayList(Pos) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    pos_of: std.ArrayList(u32) = .empty,
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
        r.backs.deinit(gpa);
        r.infos.deinit(gpa);
        r.edges.deinit(gpa);
        r.pos_of.deinit(gpa);
    }

    /// `absorbed`: a union its constructor folded into a side, the union
    /// as written (a node no read reaches) to read its κ from.
    const Pos = struct { node: NodeId, at_summary: bool, kappa: CondId, place: PlaceId, first: u32, len: u32, absorbed: NodeId = .none };
    /// A part of a position that is a position: a child step's (`step`), a
    /// projected one's (`made`), or a side, a base, an inner.
    const Edge = struct { to: u32, step: Step = Step.elem, stepped: bool = false, made: bool = false };

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
        try r.verify();
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
            try r.pos_of.append(gpa, if (kind == .node) @intCast(r.infos.items.len - 1) else none);
            return;
        }
        const k = try r.count();
        if (k == 0) return error.Malformed;
        const base = r.vals.items.len;
        var i: u32 = 0;
        while (i < k) : (i += 1) {
            try r.vals.append(gpa, none);
            try r.kinds.append(gpa, .node);
            try r.pos_of.append(gpa, none);
        }
        i = 0;
        while (i < k) : (i += 1) {
            if (try r.get() != @backingInt(Kind.node)) return error.Malformed;
            r.low = base + i;
            r.high = base + k;
            r.vals.items[base + i] = (try r.node(true)).int();
            r.pos_of.items[base + i] = @intCast(r.infos.items.len - 1);
        }
        // Every member made: the child maps of its nodes and deltas.
        const shapes = r.env.shapes;
        for (r.pos_of.items[base..][0..k]) |pi| {
            const p = r.infos.items[pi];
            const nk = shapes.kind(p.node);
            if (nk != .node and nk != .delta) continue;
            var root: u32 = none;
            for (r.edges.items[p.first..][0..p.len]) |e| {
                if (e.stepped and !e.made) root = try shapes.overPut(gpa, r.env.account(), root, e.step, .from(r.vals.items[e.to]));
            }
            if (nk == .node) shapes.nodes.items(.a)[p.node.int()] = root else shapes.nodes.items(.b)[p.node.int()] = root;
        }
    }

    /// A position's ordinal below `low`, or null for `none`.
    fn posRef(r: *Reader) Failure!?u32 {
        const o = try r.get();
        if (o == none) return null;
        if (o >= r.low or r.kinds.items[o] != .node) return error.Malformed;
        return o;
    }

    /// The κ map of an owner whose values are the positions `roots`: the
    /// κ each reached position was written with, at it. A use shape is not
    /// a value and carries none.
    fn kmap(r: *Reader, roots: []const u32) Failure!Cond.Kappas {
        const gpa = r.env.gpa;
        var ctx: Cond.Kappas = .none;
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        var absorbed: std.ArrayList(u32) = .empty;
        defer absorbed.deinit(gpa);
        for (roots) |o| try stack.append(gpa, r.pos_of.items[o]);
        while (stack.pop()) |i| {
            if ((try seen.getOrPut(gpa, .{i})).found_existing) continue;
            try r.env.charge.reserve(gpa, .inspection, 1);
            const p = r.infos.items[i];
            // A value holds objects, never a use shape's marks.
            var it = r.env.cells.sets.iterate(r.env.shapes.cells(p.node));
            while (it.next()) |e| if (r.env.cells.origin(.from(e.key)) == .mark) return error.Malformed;
            if (p.absorbed != .none) {
                try absorbed.append(gpa, i);
            } else if (p.kappa != .none) ctx = (try r.env.conds.kappaSet(gpa, r.env.charge, ctx, p.node, p.at_summary, p.kappa)).ctx;
            for (r.edges.items[p.first..][0..p.len]) |e| try stack.append(gpa, r.pos_of.items[e.to]);
        }
        // A union its constructor absorbed into a side is read, at its
        // position, as that side: the κ the union as written reads (its
        // stored κ over its sides') is joined into the side's, parts first.
        // Exact there; the side's own reads can only grow (§2.12).
        std.mem.sort(u32, absorbed.items, {}, std.sort.asc(u32));
        for (absorbed.items) |i| {
            const p = r.infos.items[i];
            if (p.kappa != .none) ctx = (try r.env.conds.kappaSet(gpa, r.env.charge, ctx, p.absorbed, p.at_summary, p.kappa)).ctx;
            const k = try r.env.conds.kappaOf(gpa, r.env.charge, r.env.view(), ctx, p.absorbed, p.at_summary);
            ctx = (try r.env.conds.kappaSet(gpa, r.env.charge, ctx, p.node, p.at_summary, k)).ctx;
        }
        return ctx;
    }

    /// The checks a knot's members could not have while they were read: a
    /// child at the place its step reaches, then every projected position
    /// the node `proj` makes there.
    fn verify(r: *Reader) Failure!void {
        const places = r.env.places;
        for (0..2) |pass| {
            for (r.infos.items) |p| {
                for (r.edges.items[p.first..][0..p.len]) |e| {
                    try r.env.charge.reserve(r.env.gpa, .inspection, 1);
                    const child: NodeId = .from(r.vals.items[e.to]);
                    if (pass == 0 and e.stepped and !e.made) {
                        if (places.child(p.place, e.step) != r.env.shapes.place(child)) return error.Malformed;
                    } else if (pass == 1 and e.made) {
                        const made = (try r.env.shapes.proj(r.env.gpa, r.env.account(), places, r.env.cells, p.node, e.step)) orelse return error.Malformed;
                        if (made != child) return error.Malformed;
                    }
                }
            }
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
            .node => return (try r.node(false)).int(),
            .owner => {
                // One map for every value under it, as the writer closed it.
                const n = try r.count();
                const roots = try gpa.alloc(u32, n);
                defer gpa.free(roots);
                for (roots) |*x| x.* = (try r.posRef()) orelse return error.Malformed;
                return (try r.kmap(roots)).int();
            },
            .supply => {
                const k = try r.get();
                const bits = try r.flag(3);
                const l = try r.opt(LabelId, .label);
                const o = try r.posRef();
                const n: NodeId = if (o) |x| .from(r.vals.items[x]) else .none;
                const kappa: Cond.Kappas = if (try r.ref(.owner)) |v| .from(v) else .none;
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
            .back => {
                const dest_param = try r.get();
                const flags = try r.get();
                if (flags >> 8 > 1) return error.Malformed;
                const mode = try enumOf(Summary.BackMode, flags & 0xff);
                const selected = try r.opt(PathId, .path);
                try r.backs.append(gpa, .{ .dest_param = dest_param, .mode = mode, .removes = flags >> 8 == 1, .selected = selected, .dest = try r.opt(PathId, .path) });
                return @intCast(r.backs.items.len - 1);
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

    /// `n, (step, position)×n`, a position below `high`, each an edge; the
    /// child map of a node's steps when `made` is false.
    fn steps(r: *Reader, made: bool, build: bool) Failure!u32 {
        const n = try r.count();
        var root: u32 = none;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const s = try r.stepOf();
            const o = try r.get();
            if (o >= r.high or r.kinds.items[o] != .node) return error.Malformed;
            try r.edges.append(r.env.gpa, .{ .to = o, .step = s, .stepped = true, .made = made });
            if (build) root = try r.env.shapes.overPut(r.env.gpa, r.env.account(), root, s, .from(r.vals.items[o]));
        }
        return root;
    }

    /// A part that is a position below `low`, recorded as an edge.
    fn side(r: *Reader) Failure!NodeId {
        const o = (try r.posRef()) orelse return error.Malformed;
        try r.edges.append(r.env.gpa, .{ .to = o });
        return .from(r.vals.items[o]);
    }

    /// A position: its node made by its constructor, or — a knot's member
    /// `raw` — tied as its constructor would have made it, its parts read
    /// before it; then the κ read there and the positions `proj` makes.
    fn node(r: *Reader, in_knot: bool) Failure!NodeId {
        const gpa = r.env.gpa;
        const acct = r.env.account();
        const shapes = r.env.shapes;
        const sets = &r.env.cells.sets;
        const kind = try enumOf(Shape.Kind, try r.get());
        const at_summary = try r.flag(1) == 1;
        const at = try r.placeOf();
        const first: u32 = @intCast(r.edges.items.len);
        var absorbed: NodeId = .none;
        // In a knot a node's or a delta's child map may name a later member:
        // it is a node no constructor interns, its map tied when the knot is
        // read (`unit`). Every other kind is its constructor's, its parts
        // read before it.
        const id: NodeId = switch (kind) {
            .leaf => try shapes.leaf(gpa, acct, at, try r.opt(SetId, .set)),
            .node => blk: {
                const cells = try r.opt(SetId, .set);
                const children = try r.steps(false, !in_knot);
                if (!in_knot) break :blk try shapes.node(gpa, acct, at, cells, children);
                const id = try shapes.knot(gpa, acct);
                shapes.tie(id, .{ .kind = .node, .place = at, .cells = cells, .a = none, .b = 0, .reach = .none });
                break :blk id;
            },
            .delta => blk: {
                const base = try r.side();
                if (shapes.kind(base) == .delta or shapes.place(base) != at) return error.Malformed;
                const over = try r.steps(false, !in_knot);
                if (!in_knot) break :blk try shapes.delta(gpa, acct, base, over);
                const id = try shapes.knot(gpa, acct);
                shapes.tie(id, .{ .kind = .delta, .place = at, .cells = shapes.cells(base), .a = base.int(), .b = none, .reach = .none });
                break :blk id;
            },
            .recast => try shapes.recast(gpa, acct, at, try r.side()),
            .@"union", .positions => blk: {
                if (try r.get() != 2) return error.Malformed;
                const a = try r.side();
                const b = try r.side();
                // Two sides at the union's own place, as `join` makes them.
                if (shapes.place(a) != at or shapes.place(b) != at) return error.Malformed;
                if (kind == .positions) break :blk try shapes.collect(gpa, acct, sets, &.{ a, b });
                const made = try shapes.@"union"(gpa, acct, sets, a, b);
                if (made == a or made == b) {
                    absorbed = try shapes.knot(gpa, acct);
                    shapes.tie(absorbed, .{ .kind = .@"union", .place = at, .cells = try sets.unionWith(gpa, r.env.charge, shapes.cells(a), shapes.cells(b)), .a = a.int(), .b = b.int(), .reach = .none });
                }
                break :blk made;
            },
        };
        // A union keeps what is stored there. One its constructor absorbed
        // into a side reads that side joined with it: its stored κ joined
        // into the side's is that read exactly (the side holds its cells).
        // A use shape's positions (marks) carry none.
        const kappa = try r.opt(CondId, .cond);
        _ = try r.steps(true, false);
        try r.infos.append(gpa, .{ .node = id, .at_summary = at_summary, .kappa = kappa, .place = at, .first = first, .len = @intCast(r.edges.items.len - first), .absorbed = absorbed });
        return id;
    }

    fn class(r: *Reader) Failure!ClassId {
        const gpa = r.env.gpa;
        const n_params = try r.count();
        const flags = try r.flag(7);
        const origin = try enumOf(Summary.Origin, try r.get());
        const res_o = try r.posRef();
        const res: NodeId = if (res_o) |o| .from(r.vals.items[o]) else .none;
        const kappas: Cond.Kappas = if (try r.ref(.owner)) |v| .from(v) else .none;
        var params: std.ArrayList(NodeId) = .empty;
        defer params.deinit(gpa);
        var i: u32 = 0;
        while (i < n_params) : (i += 1) {
            const o = try r.posRef();
            try params.append(gpa, if (o) |x| .from(r.vals.items[x]) else .none);
        }
        const xreq: CondId = if (try r.ref(.atoms)) |v| .from(v) else Cond.yes;
        var funs: std.ArrayList(Summary.DraftFun) = .empty;
        defer funs.deinit(gpa);
        var supplies: std.ArrayList(Summary.Supply) = .empty;
        defer supplies.deinit(gpa);
        var keeps: std.ArrayList(Summary.Keep) = .empty;
        defer keeps.deinit(gpa);
        var backs: std.ArrayList(Summary.Back) = .empty;
        defer backs.deinit(gpa);
        var runs: std.ArrayList([6]u32) = .empty;
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
            const b_start: u32 = @intCast(backs.items.len);
            const n_b = try r.count();
            s = 0;
            while (s < n_b) : (s += 1) try backs.append(gpa, r.backs.items[try r.need(.back)]);
            try funs.append(gpa, .{ .j = j, .calls = calls, .need = bits & 1 == 1, .seen = bits & 2 == 2 });
            try runs.append(gpa, .{ s_start, n_s, k_start, n_k, b_start, n_b });
        }
        for (funs.items, runs.items) |*f, run| {
            f.supplies = supplies.items[run[0]..][0..run[1]];
            f.keeps = keeps.items[run[2]..][0..run[3]];
            f.backs = backs.items[run[4]..][0..run[5]];
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
            9 => {
                for (0..2) |i| try out.append(gpa, .{ .step = Step.index(g.account, @intCast(i)) catch unreachable, .@"var" = 0 });
                return .{ .kind = .tuple };
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
        .{ .params = &.{ .{ .place = lists, .words = wordBits(&.{ .written, .returned }) }, .{ .place = int, .words = wordBits(&.{.borrowed}) }, .{ .place = fun, .words = wordBits(&.{ .once, .taken, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = lists },
        .{ .params = &.{ .{ .place = recs, .words = wordBits(&.{.written}) }, .{ .place = recs, .words = wordBits(&.{.borrowed}) } }, .result = recs, .result_words = wordBits(&.{.concatenated}) },
        .{ .params = &.{.{ .place = list, .words = wordBits(&.{.consumed}) }}, .result = ref, .result_words = wordBits(&.{.cellnew}) },
        .{ .params = &.{.{ .place = ref, .words = wordBits(&.{.cellread}) }}, .result = maybe, .result_words = wordBits(&.{.lentoptional}), .optional_payload = try t.places.ctorStep(testing.allocator, &t.account, 1, 0) },
        .{ .params = &.{ .{ .place = ref, .words = wordBits(&.{.cellwrite}) }, .{ .place = fun, .words = wordBits(&.{ .cellmodify, .stored }), .fn_params = &.{list}, .fn_result = try t.place(9) } }, .result = list },
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
    // The write-backs travel with their funs (ownership-v2.md §2.13.6).
    try testing.expect(std.mem.indexOf(u8, try b.text(arena, read_back.items[2]), "stores answer at π1[*]") != null);
    try testing.expect(std.mem.indexOf(u8, try b.text(arena, read_back.items[6]), "stores answer.1 at π1◆") != null);
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
        t.account.allowance = std.math.maxInt(u32) - 1;
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
    // every record kind but labels'; the labels' test block has those. And
    // a widened knot, whose group a mutation can point anywhere.
    a.account.allowance = std.math.maxInt(u32) - 1;
    const w = try widenedTree(&a);
    const knot = try a.sums.add(a.env(), .{ .params = &.{.none}, .res = w });
    try write(a.env(), &a.sums, &.{ classes[0], classes[1], classes[5], knot }, .identity, &words);
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
    const tag = struct {
        fn k(x: Kind) u32 {
            return @backingInt(x);
        }
    }.k;
    const elem = @backingInt(Place.StepKind.elem);
    // One place, `List` of itself; `yes`; one knot of one member; no class.
    const head = [_]u32{ magic, version, 1, @backingInt(Place.Kind.list), 200, 0, 1, elem, 0, 0, 2, tag(.cond), @backingInt(Cond.Kind.yes), tag(.group), 1, tag(.node) };
    // A node whose `[*]` child is itself: a knot.
    const by_step = head ++ [_]u32{ @backingInt(Shape.Kind.node), 0, 0, none, 1, elem, 0, 1, 0, 0, 0 };
    // A recast of itself: no constructor makes it.
    const by_inner = head ++ [_]u32{ @backingInt(Shape.Kind.recast), 0, 0, 1, 0, 0, 0 };
    // A union with itself as a side.
    const by_side = head ++ [_]u32{ @backingInt(Shape.Kind.@"union"), 0, 0, 2, 1, 1, none, 0, 0 };
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

/// κ at the position `steps` reach from `n` in `t`, read by `proj` as a
/// reader of the class reads it.
fn kappaAt(t: *Tables, kappas: Cond.Kappas, n: NodeId, steps: []const Step) !CondId {
    var at = n;
    var summary = false;
    for (steps) |s| {
        at = (try t.shapes.proj(testing.allocator, &t.account, &t.places, &t.cells, at, s)).?;
        summary = below(summary, s);
    }
    return t.conds.kappaOf(testing.allocator, t.env().charge, t.env().view(), kappas, at, summary);
}

fn roundTrip(a: *Tables, b: *Tables, c: ClassId) !ClassId {
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &.{c}, .identity, &words);
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(testing.allocator);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
    // And the decoded class writes the same block.
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(testing.allocator);
    try write(b.env(), &b.sums, back.items, .identity, &again);
    try testing.expectEqualSlices(u32, words.items, again.items);
    return back.items[0];
}

test "a block keeps the κ a joined class stored at a position only `proj` reaches" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    const lists = try a.place(2);
    const list = try a.place(0);
    var tops: [2]NodeId = undefined;
    var maps: [2]Cond.Kappas = undefined;
    for (0..2) |i| {
        const site = try a.cells.site(gpa, &a.account, @intCast(i + 1), list, .list);
        const leaf = try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, site.int(), 0));
        tops[i] = try a.shapes.node(gpa, &a.account, lists, .none, try a.shapes.overPut(gpa, &a.account, Ids.none_int, Step.elem, leaf));
        var m = (try a.conds.kappaSet(gpa, env.charge, .none, tops[i], false, Cond.yes)).ctx;
        m = (try a.conds.kappaSet(gpa, env.charge, m, leaf, true, Cond.shared)).ctx;
        maps[i] = m;
    }
    // The join stores `shared` on `proj(j, [*])`, a node no part of `j` names.
    const j = try Summary.Table.joinRes(env, tops[0], maps[0], tops[1], maps[1]);
    const c = try a.sums.add(env, .{ .params = &.{.none}, .res = j.node, .kappas = j.kappas });
    try testing.expectEqual(Cond.shared, try kappaAt(&a, j.kappas, j.node, &.{Step.elem}));
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    try testing.expectEqual(Cond.shared, try kappaAt(&b, back.kappas, back.res, &.{Step.elem}));
    try testing.expectEqual(try kappaAt(&a, j.kappas, j.node, &.{}), try kappaAt(&b, back.kappas, back.res, &.{}));
}

test "a block merges two equal knots only where they read the same κ" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const w1 = try widenedTree(&a);
    const w2 = try widenedTree(&a);
    const tree = try a.place(8);
    const list = try a.place(0);
    var s: [3]Step = undefined;
    for (&s, 0..) |*x, i| x.* = try a.places.ctorStep(gpa, &a.account, 0, @intCast(i));
    var ch = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s[0], w1);
    ch = try a.shapes.overPut(gpa, &a.account, ch, s[1], try a.shapes.nothing(gpa, &a.account, list));
    ch = try a.shapes.overPut(gpa, &a.account, ch, s[2], w2);
    const root = try a.shapes.node(gpa, &a.account, tree, .none, ch);
    // `yes` stored on the first knot's node only: the second reads `lost`.
    const inner1: NodeId = if (a.shapes.kind(w1) == .@"union") .from(a.shapes.nodes.items(.a)[w1.int()]) else w1;
    var km = (try a.conds.kappaSet(gpa, a.env().charge, .none, root, false, Cond.yes)).ctx;
    km = (try a.conds.kappaSet(gpa, a.env().charge, km, inner1, false, Cond.yes)).ctx;
    const c = try a.sums.add(a.env(), .{ .params = &.{.none}, .res = root, .kappas = km });
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    // Every position a read reaches two steps down reads what it read.
    for ([_]Step{ s[0], s[2] }) |x| {
        for ([_][]const Step{ &.{x}, &.{ x, s[0] }, &.{ x, s[2] }, &.{ x, s[0], s[0] } }) |path| {
            try testing.expectEqual(try kappaAt(&a, km, root, path), try kappaAt(&b, back.kappas, back.res, path));
        }
    }
}

test "the same value written through `map` and through `widen` is the same block" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const w = try widenedTree(&a);
    const Id = struct {
        fn f(_: *Tables, s: SetId) Error!SetId {
            return s;
        }
    };
    const m = try a.shapes.map(gpa, &a.account, w, &a, Id.f);
    try testing.expect(m != w);
    var out: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&out) |*o| o.deinit(gpa);
    for ([_]NodeId{ w, m }, &out) |n, *o| try write(a.env(), &a.sums, &.{try a.sums.add(a.env(), .{ .params = &.{.none}, .res = n })}, .identity, o);
    try testing.expectEqualSlices(u32, out[0].items, out[1].items);
}

/// A ring of same-place nodes, each at `#Node.0` of the last.
fn ring(t: *Tables, cells: []const SetId) ![]NodeId {
    const gpa = testing.allocator;
    const tree = try t.place(8);
    const s0 = try t.places.ctorStep(gpa, &t.account, 0, 0);
    const ns = try gpa.alloc(NodeId, cells.len);
    for (ns) |*n| n.* = try t.shapes.knot(gpa, &t.account);
    for (ns, 0..) |n, i| {
        const ch = try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, ns[(i + 1) % ns.len]);
        t.shapes.tie(n, .{ .kind = .node, .place = tree, .cells = cells[i], .a = ch, .b = 0, .reach = .none });
    }
    return ns;
}

fn siteSets(t: *Tables, comptime n: usize) ![n]SetId {
    var cs: [n]SetId = undefined;
    const tree = try t.place(8);
    for (&cs, 0..) |*c, i| c.* = try t.cells.sets.insert(testing.allocator, t.env().charge, .none, (try t.cells.site(testing.allocator, &t.account, @intCast(i + 1), tree, .list)).int(), 0);
    return cs;
}

test "knots that are not bisimilar never share a key: their union, built in either order, is one block" {
    const gpa = testing.allocator;
    var out: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&out) |*o| o.deinit(gpa);
    for (0..2) |flip| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const cs = try siteSets(&a, 3);
        // Rings `c d` and `c d e`, which Moore keys per knot once confused.
        const first = try ring(&a, if (flip == 0) &.{ cs[0], cs[1] } else &.{ cs[0], cs[1], cs[2] });
        defer gpa.free(first);
        const second = try ring(&a, if (flip == 0) &.{ cs[0], cs[1], cs[2] } else &.{ cs[0], cs[1] });
        defer gpa.free(second);
        const u = try a.shapes.@"union"(gpa, &a.account, &a.cells.sets, first[0], second[0]);
        try write(a.env(), &a.sums, &.{try a.sums.add(a.env(), .{ .params = &.{.none}, .res = u })}, .identity, &out[flip]);
    }
    try testing.expectEqualSlices(u32, out[0].items, out[1].items);
    // Two deltas over those rings that name each other: written, no refusal.
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const cs = try siteSets(&a, 3);
    const x = try ring(&a, &.{ cs[0], cs[1] });
    defer gpa.free(x);
    const y = try ring(&a, &.{ cs[0], cs[1], cs[2] });
    defer gpa.free(y);
    const s2 = try a.places.ctorStep(gpa, &a.account, 0, 2);
    const m1 = try a.shapes.knot(gpa, &a.account);
    const m2 = try a.shapes.knot(gpa, &a.account);
    a.shapes.tie(m1, .{ .kind = .delta, .place = a.shapes.place(x[0]), .cells = a.shapes.cells(x[0]), .a = x[0].int(), .b = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s2, m2), .reach = .none });
    a.shapes.tie(m2, .{ .kind = .delta, .place = a.shapes.place(y[0]), .cells = a.shapes.cells(y[0]), .a = y[0].int(), .b = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s2, m1), .reach = .none });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try write(a.env(), &a.sums, &.{try a.sums.add(a.env(), .{ .params = &.{.none}, .res = m1 })}, .identity, &words);
}

test "a knot's member order is the structure's when a union has both sides in the knot" {
    const gpa = testing.allocator;
    for (0..12) |variant| {
        var out: [2]std.ArrayList(u32) = .{ .empty, .empty };
        defer for (&out) |*o| o.deinit(gpa);
        for (0..2) |flip| {
            var a: Tables = .{};
            try a.init();
            defer a.deinit();
            const tree = try a.place(8);
            const s0 = try a.places.ctorStep(gpa, &a.account, 0, 0);
            const cp = try a.cells.sets.insert(gpa, a.env().charge, .none, (try a.cells.site(gpa, &a.account, @intCast(10 + variant), tree, .list)).int(), 0);
            const cq = try a.cells.sets.insert(gpa, a.env().charge, .none, (try a.cells.site(gpa, &a.account, @intCast(100 + variant), tree, .list)).int(), 0);
            const u = try a.shapes.knot(gpa, &a.account);
            const one = try a.shapes.knot(gpa, &a.account);
            const two = try a.shapes.knot(gpa, &a.account);
            const p = if (flip == 0) one else two;
            const q = if (flip == 0) two else one;
            const ch = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s0, u);
            a.shapes.tie(p, .{ .kind = .node, .place = tree, .cells = cp, .a = ch, .b = 0, .reach = .none });
            a.shapes.tie(q, .{ .kind = .node, .place = tree, .cells = cq, .a = ch, .b = 0, .reach = .none });
            a.shapes.tie(u, .{ .kind = .@"union", .place = tree, .cells = try a.cells.sets.unionWith(gpa, a.env().charge, cp, cq), .a = one.int(), .b = two.int(), .reach = .none });
            try write(a.env(), &a.sums, &.{try a.sums.add(a.env(), .{ .params = &.{.none}, .res = u })}, .identity, &out[flip]);
        }
        try testing.expectEqualSlices(u32, out[0].items, out[1].items);
    }
}

test "a ring of k nodes costs k log k: k = 1 000 under the default allowance" {
    const gpa = testing.allocator;
    var last: u64 = 0;
    for ([_]u32{ 250, 500, 1000 }) |k| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const sets = try gpa.alloc(SetId, k);
        defer gpa.free(sets);
        @memset(sets, .none);
        // One node marked, so no two are bisimilar: k blocks.
        sets[0] = (try siteSets(&a, 1))[0];
        const ns = try ring(&a, sets);
        defer gpa.free(ns);
        const c = try a.sums.add(a.env(), .{ .params = &.{.none}, .res = ns[0] });
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        const before = a.account.growth;
        try write(a.env(), &a.sums, &.{c}, .identity, &words);
        const cost = a.account.growth - before;
        if (last > 0) try testing.expect(cost * 10 <= last * 25);
        last = cost;
    }
}

test "a node no constructor makes is no block: sides at two places, a child at another place than its step's" {
    const tag = struct {
        fn k(x: Kind) u32 {
            return @backingInt(x);
        }
    }.k;
    const list = @backingInt(Place.Kind.list);
    const ref = @backingInt(Place.Kind.ref);
    const leaf = @backingInt(Shape.Kind.leaf);
    const cond_yes = [_]u32{ tag(.cond), @backingInt(Cond.Kind.yes) };
    const no_class_rest = [_]u32{ none, none, 0, 0, 0, 0, none };
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
    for ([_]u32{ 1, 0 }) |second| {
        // A union of a leaf at `List` and a leaf at place `second`.
        const words = [_]u32{ magic, version, 2, list, 200, 0, 0, ref, 400, 0, 0, 5 } ++ cond_yes ++
            [_]u32{ tag(.node), leaf, 0, 0, none, 0, 0, tag(.node), leaf, 0, second, none, 0, 0, tag(.node), @backingInt(Shape.Kind.@"union"), 0, 0, 2, 1, 2, none, 0, tag(.class), 0, 0, 0, 3 } ++ no_class_rest ++ [_]u32{ 1, 4 };
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expectEqual(second == 0, try read(t.env(), &t.sums, &words, .identity, &out) != null);
    }
    for ([_]u32{ 2, 1 }) |at| {
        // A `List` whose `[*]` child is a leaf at place `at` (its step's is 1).
        const words = [_]u32{ magic, version, 3, list, 200, 0, 1, @backingInt(Place.StepKind.elem), 0, 1, list, 201, 0, 0, ref, 400, 0, 0, 4 } ++ cond_yes ++
            [_]u32{ tag(.node), leaf, 1, at, none, 0, 0, tag(.node), @backingInt(Shape.Kind.node), 0, 0, none, 1, @backingInt(Place.StepKind.elem), 0, 1, 0, 0, tag(.class), 0, 0, 0, 2 } ++ no_class_rest ++ [_]u32{ 1, 3 };
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expectEqual(at == 1, try read(t.env(), &t.sums, &words, .identity, &out) != null);
    }
}

test "a union of two equal knots, merged into one, still reads what the union read" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const w1 = try widenedTree(&a);
    const w2 = try widenedTree(&a);
    const u = try a.shapes.@"union"(gpa, &a.account, &a.cells.sets, w1, w2);
    try testing.expect(u != w1 and u != w2);
    // `shared` stored on the union itself: its sides read less.
    const km = (try a.conds.kappaSet(gpa, a.env().charge, .none, u, false, Cond.shared)).ctx;
    const c = try a.sums.add(a.env(), .{ .params = &.{.none}, .res = u, .kappas = km });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try write(a.env(), &a.sums, &.{c}, .identity, &words);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(gpa);
    try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
    const r = b.sums.get(back.items[0]);
    // The reader's union of one knot with itself is that knot; at the
    // union's position it reads what the union read, and below, no less.
    try testing.expectEqual(try kappaAt(&a, km, u, &.{}), try kappaAt(&b, r.kappas, r.res, &.{}));
    const s0 = try a.places.ctorStep(gpa, &a.account, 0, 0);
    const before = try kappaAt(&a, km, u, &.{s0});
    const after = try kappaAt(&b, r.kappas, r.res, &.{try b.places.ctorStep(gpa, &b.account, 0, 0)});
    try testing.expect(before == after or after == Cond.shared or after == Cond.lost);
}

/// A class whose `res` is `res`, with `shared` stored at the position
/// `steps` reach from it (and `yes` at `res`), written and read back: κ
/// there, before and after.
fn storedBelow(res: NodeId, t: *Tables, steps: []const Step) ![2]CondId {
    const gpa = testing.allocator;
    const env = t.env();
    var at = res;
    var summary = false;
    for (steps) |s| {
        at = (try t.shapes.proj(gpa, &t.account, &t.places, &t.cells, at, s)).?;
        summary = below(summary, s);
    }
    var km = (try t.conds.kappaSet(gpa, env.charge, .none, res, false, Cond.yes)).ctx;
    km = (try t.conds.kappaSet(gpa, env.charge, km, at, summary, Cond.shared)).ctx;
    const c = try t.sums.add(env, .{ .params = &.{.none}, .res = res, .kappas = km });
    const before = try kappaAt(t, km, res, steps);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(t, &b, c));
    // `[*]` and a field's rank are the same steps in the reader's table.
    return .{ before, try kappaAt(&b, back.kappas, back.res, steps) };
}

test "a block keeps a κ stored under a leaf and at an empty projection" {
    const gpa = testing.allocator;
    // A leaf `res`, κ stored at `[*]`.
    {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const lists = try a.place(2);
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, lists), 0);
        const res = try a.shapes.leaf(gpa, &a.account, lists, try a.cells.sets.insert(gpa, a.env().charge, .none, p.int(), 0));
        const k = try storedBelow(res, &a, &.{Step.elem});
        try testing.expectEqual(Cond.shared, k[0]);
        try testing.expectEqual(k[0], k[1]);
    }
    // A leaf `res` at `List { a : List Int }`, κ stored at `[*].a`.
    {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const recs = try a.place(7);
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, recs), 0);
        const res = try a.shapes.leaf(gpa, &a.account, recs, try a.cells.sets.insert(gpa, a.env().charge, .none, p.int(), 0));
        const k = try storedBelow(res, &a, &.{ Step.elem, try Step.field(&a.account, 10) });
        try testing.expectEqual(Cond.shared, k[0]);
        try testing.expectEqual(k[0], k[1]);
    }
    // A node `res` with no `[*]` child, κ stored at the empty leaf there.
    {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const lists = try a.place(2);
        const site = try a.cells.site(gpa, &a.account, 1, lists, .list);
        const res = try a.shapes.node(gpa, &a.account, lists, try a.cells.sets.insert(gpa, a.env().charge, .none, site.int(), 0), Ids.none_int);
        const k = try storedBelow(res, &a, &.{Step.elem});
        try testing.expectEqual(Cond.shared, k[0]);
        try testing.expectEqual(k[0], k[1]);
    }
}

test "supplies that hold one value under one map are one owner: the cost stays flat in their number" {
    const gpa = testing.allocator;
    var first: u64 = 0;
    for ([_]u32{ 1, 16, 64 }) |count| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const env = a.env();
        const tree = try a.place(8);
        const s0 = try a.places.ctorStep(gpa, &a.account, 0, 0);
        var v = try a.shapes.nothing(gpa, &a.account, tree);
        var km: Cond.Kappas = .none;
        for (0..200) |i| {
            const site = try a.cells.site(gpa, &a.account, @intCast(i + 1), tree, .list);
            v = try a.shapes.node(gpa, &a.account, tree, try a.cells.sets.insert(gpa, env.charge, .none, site.int(), 0), try a.shapes.overPut(gpa, &a.account, Ids.none_int, s0, v));
            km = (try a.conds.kappaSet(gpa, env.charge, km, v, false, Cond.yes)).ctx;
        }
        const sups = try gpa.alloc(Summary.Supply, count);
        defer gpa.free(sups);
        for (sups, 0..) |*s, i| s.* = .{ .j = 0, .k = @intCast(i), .node = v, .label = .none, .owned = true, .taken = false, .kappa = km };
        const c = try a.sums.add(env, .{ .params = &.{.none}, .res = v, .kappas = km, .funs = &.{.{ .j = 0, .calls = .once, .supplies = sups }} });
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        // Under the default allowance.
        const before = a.account.growth;
        try write(env, &a.sums, &.{c}, .identity, &words);
        const cost = a.account.growth - before;
        if (first == 0) first = cost else try testing.expect(cost * 10 <= first * 13);
    }
}

/// A class with `res` and one supply of `held`, both under one map with
/// `shared` stored at `stored`'s `[*]` position: κ at `[*]` of each value,
/// before and after a round trip, each under its own decoded map.
fn twoValues(t: *Tables, res: NodeId, held: NodeId, entry: NodeId, extra: []const NodeId) ![4]CondId {
    const gpa = testing.allocator;
    const env = t.env();
    var km = (try t.conds.kappaSet(gpa, env.charge, .none, res, false, Cond.yes)).ctx;
    for (extra) |n| km = (try t.conds.kappaSet(gpa, env.charge, km, n, false, Cond.yes)).ctx;
    km = (try t.conds.kappaSet(gpa, env.charge, km, entry, true, Cond.shared)).ctx;
    const sups = [_]Summary.Supply{.{ .j = 0, .k = 0, .node = held, .label = .none, .owned = true, .taken = false, .kappa = km }};
    const c = try t.sums.add(env, .{ .params = &.{.none}, .res = res, .kappas = km, .funs = &.{.{ .j = 0, .calls = .once, .supplies = &sups }} });
    const s0 = t.sums.supply(t.sums.fun(c, 0), 0);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = try roundTrip(t, &b, c);
    const s1 = b.sums.supply(b.sums.fun(back, 0), 0);
    const r = b.sums.get(back);
    return .{
        try kappaAt(t, km, res, &.{Step.elem}),           try kappaAt(&b, r.kappas, r.res, &.{Step.elem}),
        try kappaAt(t, s0.kappa, s0.node, &.{Step.elem}), try kappaAt(&b, s1.kappa, s1.node, &.{Step.elem}),
    };
}

test "two values under one map keep the map's κ wherever either reaches it" {
    const gpa = testing.allocator;
    // Two leaves whose `[*]` projections are one leaf.
    {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const lists = try a.place(2);
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, lists), 0);
        const ps = try a.cells.sets.insert(gpa, a.env().charge, .none, p.int(), 0);
        const site = try a.cells.site(gpa, &a.account, 1, lists, .list);
        const leaf_a = try a.shapes.leaf(gpa, &a.account, lists, ps);
        const leaf_b = try a.shapes.leaf(gpa, &a.account, lists, try a.cells.sets.insert(gpa, a.env().charge, ps, site.int(), 0));
        const e = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, leaf_a, Step.elem)).?;
        try testing.expectEqual(e, (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, leaf_b, Step.elem)).?);
        const k = try twoValues(&a, leaf_a, leaf_b, e, &.{});
        try testing.expectEqual(Cond.shared, k[0]);
        try testing.expectEqual(k[0], k[1]);
        try testing.expectEqual(k[2], k[3]);
    }
    // One leaf's `[*]` projection is a part of the other value.
    {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const lists = try a.place(2);
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, lists), 0);
        const site = try a.cells.site(gpa, &a.account, 1, lists, .list);
        const leaf_a = try a.shapes.leaf(gpa, &a.account, lists, try a.cells.sets.insert(gpa, a.env().charge, .none, p.int(), 0));
        const e = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, leaf_a, Step.elem)).?;
        const nb = try a.shapes.node(gpa, &a.account, lists, try a.cells.sets.insert(gpa, a.env().charge, .none, site.int(), 0), try a.shapes.overPut(gpa, &a.account, Ids.none_int, Step.elem, e));
        const k = try twoValues(&a, leaf_a, nb, e, &.{nb});
        try testing.expectEqual(Cond.shared, k[0]);
        try testing.expectEqual(k[0], k[1]);
        try testing.expectEqual(k[2], k[3]);
    }
}

test "a block built in another order writes the same bytes: two values of one owner" {
    const gpa = testing.allocator;
    var out: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&out) |*o| o.deinit(gpa);
    for (0..2) |flip| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        const env = a.env();
        const lists = try a.place(2);
        const root = try a.places.rootPath(gpa, lists);
        var ps: [2]SetId = undefined;
        for (0..2) |k| {
            const i = if (flip == 0) k else 1 - k;
            const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, @intCast(i), root, 0);
            ps[i] = try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0);
        }
        var vals: [2]NodeId = undefined;
        for (0..2) |k| {
            const i = if (flip == 0) k else 1 - k;
            vals[i] = try a.shapes.leaf(gpa, &a.account, lists, ps[i]);
        }
        var km: Cond.Kappas = .none;
        for (vals) |v| km = (try a.conds.kappaSet(gpa, env.charge, km, (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, v, Step.elem)).?, true, Cond.shared)).ctx;
        const sups = [_]Summary.Supply{.{ .j = 0, .k = 0, .node = vals[1], .label = .none, .owned = true, .taken = false, .kappa = km }};
        const c = try a.sums.add(env, .{ .params = &.{.none}, .res = vals[0], .kappas = km, .funs = &.{.{ .j = 0, .calls = .once, .supplies = &sups }} });
        try write(env, &a.sums, &.{c}, .identity, &out[flip]);
    }
    try testing.expectEqualSlices(u32, out[0].items, out[1].items);
}
