//! L12: reading the ownership block (`docs/design/ownership-v2.md` §3.6)
//! that `Block` writes, and the block's tests.
//!
//! `read` decodes into tables of its own first, on the codec's lane: its
//! allowance is the codec's bound of the block's length, set before any word
//! is read, and its records are the caller's baseline, never growth (§4.1).
//! A block that does not decode — a part of the wrong kind, a node no
//! constructor makes (sides at two places, a child at a step its place has
//! not), a projected position `proj` does not make, a decode past the
//! codec's bound — is no block (null, R-5.7.4) and the caller's tables are
//! untouched; one past the room in the caller's place table is the
//! caller's `OwnershipLimit`. Only then is it built in the caller's
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
const Calls = @import("Calls.zig");
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
/// null when the words are not a block this version wrote. Decoded first
/// in tables of its own (the header): a block that does not decode leaves
/// `env`'s tables and `out` as they were.
pub fn read(env: Env, sums: *Summary.Table, words: []const u32, remap: Remap, out: *std.ArrayList(ClassId)) ReadError!?void {
    const gpa = env.gpa;
    const owner = env.account();
    if (owner.failed) |f| return f.err();
    {
        var t: Scratch = .{};
        try t.init(gpa, env, words.len);
        defer t.deinit(gpa);
        var trial: std.ArrayList(ClassId) = .empty;
        defer trial.deinit(gpa);
        var r: Reader = .{ .env = t.env(gpa), .sums = &t.sums, .words = words, .remap = remap };
        defer r.deinit();
        const failed: ?Reader.Failure = if (r.all(&trial)) null else |err| err;
        if (failed) |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        // The trial's records are the codec's: baseline, never growth.
        owner.baseline += t.account.growth;
        owner.baseline_by[@backingInt(Ids.Category.inspection)] += t.account.growth;
        if (failed) |e| {
            // Past the room in the caller's place table: the caller's
            // limit. Past the codec's bound of the block's length: no
            // block this writer wrote.
            if (e == error.OwnershipLimit and t.account.failed.? == .limit) {
                owner.failed = t.account.failed;
                return error.OwnershipLimit;
            }
            return null;
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

    /// The trial's allowance is the codec's bound of the block's length
    /// (§4.1), set before any word is read.
    fn init(t: *Scratch, gpa: Allocator, caller: Env, words: usize) Error!void {
        t.account.allowance = @intCast(@min(Block.codecBound(words), std.math.maxInt(u32) - 1));
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
    /// `cursor`: what the owner's snapshot is at the position (`0` none,
    /// `1` a position, `2` an exact fold, `3` a collapsed one, §3.6).
    const Pos = struct { node: NodeId, at_summary: bool, cursor: u32 = 0, kappa: CondId, place: PlaceId, first: u32, len: u32, absorbed: NodeId = .none };
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
                try r.env.charge.reserve(gpa, .inspection, 1);
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
        // The members made, then each tied: a record each, reserved first.
        try r.env.charge.reserve(gpa, .inspection, 2 * k);
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

    /// The snapshot of an owner whose values are the positions `roots`
    /// (§3.6), rebuilt by route: the values are at the root; the positions
    /// one snapshot position holds are a GROUP, closed under a position's
    /// sides, base and inner (one position, §2.9), and the group one step
    /// `s` below is its members' children at `s`, closed alike; below a fold
    /// every step is the group itself. Each group stores the κ each of its
    /// positions was written with. A group is a route's, never a merge of
    /// two routes, so a position the block shares between two routes (the
    /// refinement merges equal ones) is read at each with its κ there. A use
    /// shape is not a value and carries none.
    fn kmap(r: *Reader, roots: []const u32) Failure!Cond.Kappas {
        const gpa = r.env.gpa;
        var b: GroupBuild = .{ .r = r };
        defer b.deinit();
        var start: std.ArrayList(u32) = .empty;
        defer start.deinit(gpa);
        for (roots) |o| {
            const i = r.pos_of.items[o];
            // A value holds objects, never a use shape's marks.
            try r.checkValue(i);
            if (r.infos.items[i].cursor != 0) try start.append(gpa, i);
        }
        if (start.items.len == 0) return .none;
        const g = try b.group(start.items);
        return b.build(g);
    }

    fn checkValue(r: *Reader, i: u32) Failure!void {
        const p = r.infos.items[i];
        var it = r.env.cells.sets.iterate(try r.env.shapes.cellsOf(r.env.gpa, r.env.account(), &r.env.cells.sets, p.node));
        while (it.next()) |e| {
            try r.env.charge.reserve(r.env.gpa, .inspection, 1);
            if (r.env.cells.origin(.from(e.key)) == .mark) return error.Malformed;
        }
    }

    /// `kmap`'s groups: each an interned sorted run of positions.
    const GroupBuild = struct {
        r: *Reader,
        /// A run as a cons list `(position, rest)` → its id.
        cons: Ids.FixedDict(2) = .{},
        runs: std.ArrayList(std.ArrayList(u32)) = .empty,
        built: Ids.FixedDict(1) = .{},
        open: Ids.FixedDict(1) = .{},

        fn deinit(b: *GroupBuild) void {
            const gpa = b.r.env.gpa;
            b.cons.deinit(gpa);
            for (b.runs.items) |*l| l.deinit(gpa);
            b.runs.deinit(gpa);
            b.built.deinit(gpa);
            b.open.deinit(gpa);
        }

        /// The group of `seeds`: closed under the same-position parts, and
        /// under every child of a fold. Its id, interned by its sorted run.
        fn group(b: *GroupBuild, seeds: []const u32) Failure!u32 {
            const r = b.r;
            const gpa = r.env.gpa;
            var members: std.ArrayList(u32) = .empty;
            defer members.deinit(gpa);
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(gpa);
            var stack: std.ArrayList(u32) = .empty;
            defer stack.deinit(gpa);
            try stack.appendSlice(gpa, seeds);
            var fold = false;
            for (seeds) |s| fold = fold or r.infos.items[s].cursor >= 2;
            while (stack.pop()) |i| {
                try r.env.charge.reserve(gpa, .inspection, 1);
                if (r.infos.items[i].cursor == 0) continue;
                if ((try seen.getOrPut(gpa, .{i})).found_existing) continue;
                try members.append(gpa, i);
                const p = r.infos.items[i];
                const was_fold = fold;
                if (p.cursor >= 2) fold = true;
                for (r.edges.items[p.first..][0..p.len]) |e| {
                    if (e.stepped and !fold) continue;
                    try r.env.charge.reserve(gpa, .inspection, 1);
                    try stack.append(gpa, r.pos_of.items[e.to]);
                }
                // A fold found late takes the children of the members seen
                // before it, once: when the group first becomes a fold.
                if (fold and !was_fold) for (members.items[0 .. members.items.len - 1]) |m| {
                    const q = r.infos.items[m];
                    for (r.edges.items[q.first..][0..q.len]) |e| if (e.stepped) {
                        try r.env.charge.reserve(gpa, .inspection, 1);
                        try stack.append(gpa, r.pos_of.items[e.to]);
                    };
                };
            }
            try r.env.charge.reserve(gpa, .inspection, @intCast(@min(Block.sortCost(members.items.len), std.math.maxInt(u32))));
            std.mem.sort(u32, members.items, {}, std.sort.asc(u32));
            var id: u32 = none;
            var k = members.items.len;
            while (k > 0) {
                k -= 1;
                try r.env.charge.reserve(gpa, .memo, 1);
                const got = try b.cons.getOrPut(gpa, .{ members.items[k], id });
                if (!got.found_existing) {
                    got.value_ptr.* = @intCast(b.runs.items.len);
                    var run: std.ArrayList(u32) = .empty;
                    try run.appendSlice(gpa, members.items[k..]);
                    try b.runs.append(gpa, run);
                }
                id = got.value_ptr.*;
            }
            return id;
        }

        /// Group `g`'s snapshot position: its members' κ, a union its
        /// constructor absorbed into a side read as that side (its stored κ
        /// over its sides' joined into the side's, exact there; §2.12), and
        /// its links, each child group built first.
        fn build(b: *GroupBuild, root: u32) Failure!Cond.Kappas {
            const r = b.r;
            const gpa = r.env.gpa;
            const conds = r.env.conds;
            const ch = r.env.charge;
            // Post-order on an explicit stack (#1138: a snapshot is as deep as
            // the source): a group's own position first, its child groups
            // built, then linked in step order.
            const Frame = struct { g: u32, pos: Cond.Kappas = .none, kids_first: u32 = 0, kids_len: u32 = 0, expanded: bool = false };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            var links: std.ArrayList([2]u32) = .empty;
            defer links.deinit(gpa);
            try stack.append(gpa, .{ .g = root });
            while (stack.pop()) |f| {
                const g = f.g;
                // No member has a snapshot position: nothing is there.
                if (g == none) continue;
                if (f.expanded) {
                    var pos = f.pos;
                    for (links.items[f.kids_first..][0..f.kids_len]) |l| {
                        const child: Cond.Kappas = if (l[1] == none) .none else .from(b.built.get(.{l[1]}).?);
                        pos = try conds.kappaLink(gpa, ch, pos, Step.fromWord(l[0]), child);
                    }
                    (try b.built.getOrPut(gpa, .{g})).value_ptr.* = pos.int();
                    continue;
                }
                try ch.reserve(gpa, .memo, 1);
                if (b.built.get(.{g}) != null) continue;
                if ((try b.open.getOrPut(gpa, .{g})).found_existing) return error.Malformed;
                const members = b.runs.items[g].items;
                var fold: u32 = 0;
                for (members) |i| fold = @max(fold, r.infos.items[i].cursor);
                var pos: Cond.Kappas = if (fold >= 2) try conds.kappaEmptyFold(gpa, ch, if (fold == 3) Cond.Table.fold_collapsed else Cond.Table.fold_exact) else .none;
                for (members) |i| {
                    const p = r.infos.items[i];
                    if (p.absorbed == .none and p.kappa != .none) pos = (try conds.kappaSet(gpa, ch, pos, p.node, p.kappa)).ctx;
                }
                for (members) |i| {
                    const p = r.infos.items[i];
                    if (p.absorbed == .none) continue;
                    if (p.kappa != .none) pos = (try conds.kappaSet(gpa, ch, pos, p.absorbed, p.kappa)).ctx;
                    const k = try conds.kappaOf(gpa, ch, r.env.view(), pos, p.absorbed, p.at_summary);
                    pos = (try conds.kappaSet(gpa, ch, pos, p.node, k)).ctx;
                }
                // A fold's links are the steps its members take.
                if (fold >= 2) for (members) |i| {
                    const p = r.infos.items[i];
                    for (r.edges.items[p.first..][0..p.len]) |e| if (e.stepped) {
                        try ch.reserve(gpa, .inspection, 1);
                        pos = try conds.kappaFoldStep(gpa, ch, pos, e.step);
                    };
                };
                const kids_first: u32 = @intCast(links.items.len);
                if (fold < 2) {
                    // The children by step, in step order.
                    var kids: std.ArrayList([2]u32) = .empty;
                    defer kids.deinit(gpa);
                    for (b.runs.items[g].items) |i| {
                        const p = r.infos.items[i];
                        for (r.edges.items[p.first..][0..p.len]) |e| if (e.stepped) {
                            try ch.reserve(gpa, .inspection, 1);
                            try kids.append(gpa, .{ e.step.word(), r.pos_of.items[e.to] });
                        };
                    }
                    try ch.reserve(gpa, .inspection, @intCast(@min(Block.sortCost(kids.items.len), std.math.maxInt(u32))));
                    std.mem.sort([2]u32, kids.items, {}, struct {
                        fn less(_: void, x: [2]u32, y: [2]u32) bool {
                            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
                        }
                    }.less);
                    var seeds: std.ArrayList(u32) = .empty;
                    defer seeds.deinit(gpa);
                    var at: usize = 0;
                    while (at < kids.items.len) {
                        var end = at;
                        seeds.clearRetainingCapacity();
                        while (end < kids.items.len and kids.items[end][0] == kids.items[at][0]) : (end += 1) try seeds.append(gpa, kids.items[end][1]);
                        try links.append(gpa, .{ kids.items[at][0], try b.group(seeds.items) });
                        at = end;
                    }
                }
                const kids_len: u32 = @intCast(links.items.len - kids_first);
                try stack.append(gpa, .{ .g = g, .pos = pos, .kids_first = kids_first, .kids_len = kids_len, .expanded = true });
                var k = kids_len;
                while (k > 0) {
                    k -= 1;
                    try stack.append(gpa, .{ .g = links.items[kids_first + k][1] });
                }
            }
            if (root == none) return .none;
            return .from(b.built.get(.{root}).?);
        }
    };

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
                    // A block holds resolved conditions only.
                    .inst => return error.Malformed,
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
        const cursor = try r.flag(3);
        const at = try r.placeOf();
        const first: u32 = @intCast(r.edges.items.len);
        var absorbed: NodeId = .none;
        // In a knot a node's or a delta's child map may name a later member:
        // it is a node no constructor interns, its map tied when the knot is
        // read (`unit`). Every other kind is its constructor's, its parts
        // read before it.
        const id: NodeId = switch (kind) {
            .view => return error.Malformed, // a block holds no views: they are forced at publish (§2.11)
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
            .recast => blk: {
                const whole = try r.flag(1) == 1;
                const inner = try r.side();
                break :blk if (whole) try shapes.recastWhole(gpa, acct, sets, at, inner) else try shapes.recast(gpa, acct, at, inner);
            },
            .@"union", .choice, .positions => blk: {
                if (try r.get() != 2) return error.Malformed;
                const a = try r.side();
                const b = try r.side();
                // Two sides at the union's own place, as `join` makes them.
                if (shapes.place(a) != at or shapes.place(b) != at) return error.Malformed;
                if (kind == .positions) break :blk try shapes.collect(gpa, acct, sets, &.{ a, b });
                // A choice decodes to a choice, never a union (§3.6).
                if (kind == .choice) break :blk try shapes.choice(gpa, acct, sets, a, b);
                const made = try shapes.@"union"(gpa, acct, sets, a, b);
                if (made == a or made == b) {
                    absorbed = try shapes.knot(gpa, acct);
                    shapes.tie(absorbed, .{ .kind = .@"union", .place = at, .cells = try sets.unionWith(gpa, r.env.charge, try shapes.cellsOf(gpa, acct, sets, a), try shapes.cellsOf(gpa, acct, sets, b)), .a = a.int(), .b = b.int(), .reach = .none });
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
        try r.infos.append(gpa, .{ .node = id, .at_summary = at_summary, .cursor = cursor, .kappa = kappa, .place = at, .first = first, .len = @intCast(r.edges.items.len - first), .absorbed = absorbed });
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
/// 7 `List { a : List Int }`, 8 `type Tree = Node Tree (List Int) Tree`,
/// 9 `List Int × List Int`, 10 and 11 wide records (below).
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
            // 12: a pair of 9s (#1122's shared built node).
            12 => {
                for (0..2) |i| try out.append(gpa, .{ .step = Step.index(g.account, @intCast(i)) catch unreachable, .@"var" = 9 });
                return .{ .kind = .tuple };
            },
            // 10 and 11: records of 8 and of 512 `List (List Int)` fields (ranks
            // 100…), for a width the writer must not pay twice (#1073).
            10, 11 => {
                const w: u32 = if (v == 10) 8 else 512;
                for (0..w) |i| try out.append(gpa, .{ .step = Step.field(g.account, @intCast(100 + i)) catch unreachable, .@"var" = 2 });
                return .{ .kind = .record };
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
    /// The views a call answers (§2.11).
    views: Calls.Views = undefined,

    fn init(t: *Tables) !void {
        t.graph = .{ .table = &t.places, .account = &t.account };
        t.conds = try Cond.Table.init(testing.allocator, .growth(&t.account));
        t.views = .{ .places = &t.places, .cells = &t.cells, .shapes = &t.shapes, .conds = &t.conds, .sums = &t.sums };
        t.shapes.instantiation = t.views.instantiation();
        t.conds.resolver = t.views.resolver();
    }

    fn deinit(t: *Tables) void {
        t.views.deinit(testing.allocator);
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

/// Every truncation of the rows block whose length lies in the `part`-th of
/// `parts` equal slices of its length (so that no one test runs
/// long), read into one set of tables: each refused
/// read is no block, leaves no class in `out` and no record in the tables.
fn expectTruncationsRefused(part: u32, parts: u32) !void {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);

    // Parts of equal length: a short truncation costs about as much as a
    // long one (measured, #1209), so cut at len · k / parts.
    const cut = struct {
        fn at(len: usize, k: u32, of: u32) usize {
            return len * k / of;
        }
    }.at;
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    const counts = tableCounts(&t);
    for (cut(words.items.len, part, parts)..cut(words.items.len, part + 1, parts)) |n| {
        try testing.expect(try read(t.env(), &t.sums, words.items[0..n], .identity, &out) == null);
        try testing.expectEqual(@as(usize, 0), out.items.len);
        try testing.expectEqualSlices(u32, &counts, &tableCounts(&t));
    }
}

// Every truncation, in twenty parts of equal length (six of unequal work
// were near CI's 1 s budget, #1197, #1209).
test "a block that does not decode is no block: every truncation, part 1 of 20" {
    try expectTruncationsRefused(0, 20);
}

test "a block that does not decode is no block: every truncation, part 2 of 20" {
    try expectTruncationsRefused(1, 20);
}

test "a block that does not decode is no block: every truncation, part 3 of 20" {
    try expectTruncationsRefused(2, 20);
}

test "a block that does not decode is no block: every truncation, part 4 of 20" {
    try expectTruncationsRefused(3, 20);
}

test "a block that does not decode is no block: every truncation, part 5 of 20" {
    try expectTruncationsRefused(4, 20);
}

test "a block that does not decode is no block: every truncation, part 6 of 20" {
    try expectTruncationsRefused(5, 20);
}

test "a block that does not decode is no block: every truncation, part 7 of 20" {
    try expectTruncationsRefused(6, 20);
}

test "a block that does not decode is no block: every truncation, part 8 of 20" {
    try expectTruncationsRefused(7, 20);
}

test "a block that does not decode is no block: every truncation, part 9 of 20" {
    try expectTruncationsRefused(8, 20);
}

test "a block that does not decode is no block: every truncation, part 10 of 20" {
    try expectTruncationsRefused(9, 20);
}

test "a block that does not decode is no block: every truncation, part 11 of 20" {
    try expectTruncationsRefused(10, 20);
}

test "a block that does not decode is no block: every truncation, part 12 of 20" {
    try expectTruncationsRefused(11, 20);
}

test "a block that does not decode is no block: every truncation, part 13 of 20" {
    try expectTruncationsRefused(12, 20);
}

test "a block that does not decode is no block: every truncation, part 14 of 20" {
    try expectTruncationsRefused(13, 20);
}

test "a block that does not decode is no block: every truncation, part 15 of 20" {
    try expectTruncationsRefused(14, 20);
}

test "a block that does not decode is no block: every truncation, part 16 of 20" {
    try expectTruncationsRefused(15, 20);
}

test "a block that does not decode is no block: every truncation, part 17 of 20" {
    try expectTruncationsRefused(16, 20);
}

test "a block that does not decode is no block: every truncation, part 18 of 20" {
    try expectTruncationsRefused(17, 20);
}

test "a block that does not decode is no block: every truncation, part 19 of 20" {
    try expectTruncationsRefused(18, 20);
}

test "a block that does not decode is no block: every truncation, part 20 of 20" {
    try expectTruncationsRefused(19, 20);
}

test "a block that does not decode is no block: a wrong magic, a wrong version, a bad tag, a trailing word" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    var out: std.ArrayList(ClassId) = .empty;
    defer out.deinit(testing.allocator);
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
        const before = t.account.total();
        try write(t.env(), &t.sums, &.{c}, .identity, &words);
        const cost = t.account.total() - before;
        if (last > 0) {
            if (cost * 2 >= last * 5) {
                std.debug.print("n={d}: {d} records after {d}\n", .{ n, cost, last });
                return error.TestUnexpectedResult;
            }
        }
        last = cost;
    }
}

// A block's cost is n log n, one family a test (#1197).
test "a block's cost is n log n: n stores" {
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
}

test "a block's cost is n log n: a list of n distinct elements" {
    // A literal of n distinct lists: a balanced `positions` DAG at `[*]`.
    try expectLinearithmic(&.{ 64, 128, 256, 512 }, struct {
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
}

test "a block's cost is n log n: a union chain of depth n" {
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
    const kappas = try a.conds.kappaSetAt(gpa, env.charge, .none, &.{Step.elem}, res_elem, k);
    const supply_node = try leafOf(&a, list, &.{taken});
    const supply_k = (try a.conds.kappaSet(gpa, env.charge, .none, supply_node, try a.conds.excl(gpa, env.charge, p1))).ctx;
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

// A malformed block decodes as no block and never crashes: every truncation,
// and a mutation of every word. The sweep is split into twelfths of the words,
// each a test of its own under the 1 s budget (#1197, #1209); together they cover
// every word, as the one test did.
test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 1 of 12" {
    try malformedSweep(0, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 2 of 12" {
    try malformedSweep(1, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 3 of 12" {
    try malformedSweep(2, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 4 of 12" {
    try malformedSweep(3, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 5 of 12" {
    try malformedSweep(4, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 6 of 12" {
    try malformedSweep(5, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 7 of 12" {
    try malformedSweep(6, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 8 of 12" {
    try malformedSweep(7, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 9 of 12" {
    try malformedSweep(8, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 10 of 12" {
    try malformedSweep(9, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 11 of 12" {
    try malformedSweep(10, 12);
}

test "a malformed block decodes as no block and never crashes: every truncation and word mutation, part 12 of 12" {
    try malformedSweep(11, 12);
}

fn malformedSweep(part: usize, parts: usize) !void {
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
    if (part == 0) {
        const bad_step = [_]u32{ magic, version, 1, @backingInt(Place.Kind.list), 200, 0, 1, @backingInt(Place.StepKind.elem), 0xFFFFFFFF, 0, 0 };
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expect(try read(t.env(), &t.sums, &bad_step, .identity, &out) == null);
    }
    const len = words.items.len;
    for (len * part / parts..len * (part + 1) / parts) |i| {
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
    const by_step = head ++ [_]u32{ @backingInt(Shape.Kind.node), 0, 0, 0, none, 1, elem, 0, 1, 0, 0, 0 };
    // A recast of itself: no constructor makes it.
    const by_inner = head ++ [_]u32{ @backingInt(Shape.Kind.recast), 0, 0, 0, 0, 1, 0, 0, 0 };
    // A union with itself as a side.
    const by_side = head ++ [_]u32{ @backingInt(Shape.Kind.@"union"), 0, 0, 0, 2, 1, 1, none, 0, 0 };
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
    const c = try a.sums.add(a.env(), .{ .params = &.{w}, .res = w, .kappas = (try a.conds.kappaSet(testing.allocator, a.env().charge, .none, w, k)).ctx });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &.{c}, .identity, &words);
    try testing.expect(std.mem.indexOfScalar(u32, words.items, @backingInt(Kind.group)) != null);
    // Widened again, the same knot under other ids: the same words.
    const again_w = try widenedTree(&a);
    try testing.expect(again_w != w);
    const c2 = try a.sums.add(a.env(), .{ .params = &.{again_w}, .res = again_w, .kappas = (try a.conds.kappaSet(testing.allocator, a.env().charge, .none, again_w, k)).ctx });
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
    try testing.expect(b.conds.kappaGet(b.sums.get(back.items[0]).kappas, res) != null);
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
                const map = (try t.conds.kappaSet(gpa, env.charge, .none, leaf, try t.conds.excl(gpa, env.charge, p[i]))).ctx;
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

test "a read is the codec's baseline, never growth, and a read past the place room leaves the reader's tables as they were" {
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const classes = try rows(&a, false);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try write(a.env(), &a.sums, &classes, .identity, &words);
    {
        // No growth left at all: the read needs none.
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        t.account.allowance = t.account.growth;
        const before = t.account;
        var back: std.ArrayList(ClassId) = .empty;
        defer back.deinit(testing.allocator);
        try testing.expect(try read(t.env(), &t.sums, words.items, .identity, &back) != null);
        try testing.expectEqual(before.growth, t.account.growth);
        try testing.expect(t.account.baseline > before.baseline);
        try testing.expect(t.account.baseline - before.baseline <= Block.codecBound(words.items.len));
    }
    // One place short of the block's: the caller's limit, never no block.
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    t.places.limits.type_places = t.places.count() + words.items[2] - 1;
    const counts = tableCounts(&t);
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(testing.allocator);
    try testing.expectError(error.OwnershipLimit, read(t.env(), &t.sums, words.items, .identity, &back));
    try testing.expectEqualSlices(u32, &counts, &tableCounts(&t));
    try testing.expectEqual(@as(usize, 0), back.items.len);
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
    return t.conds.kappaOf(testing.allocator, t.env().charge, t.env().view(), t.conds.kappaAlong(kappas, steps), at, summary);
}

/// `km` with κ(n) joined with `k` `depth` steps `s` below the root.
fn below_n(t: *Tables, km: Cond.Kappas, s: Step, depth: usize, n: NodeId, k: CondId) !Cond.Kappas {
    const steps = try testing.allocator.alloc(Step, depth);
    defer testing.allocator.free(steps);
    @memset(steps, s);
    return t.conds.kappaSetAt(testing.allocator, t.env().charge, km, steps, n, k);
}

fn roundTrip(a: *Tables, b: *Tables, c: ClassId) !ClassId {
    return roundTripWith(a, b, c, true);
}

/// `roundTrip`; `same_text` false where the block shares what the original
/// repeats (equal knots merged), so the printer refers where it repeated.
fn roundTripWith(a: *Tables, b: *Tables, c: ClassId, same_text: bool) !ClassId {
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
    // And it reads what the original reads, its printed class (#1157's
    // review: re-encoding alone cannot see a weakened read).
    if (same_text) {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectEqualStrings(try a.text(arena_state.allocator(), c), try b.text(arena_state.allocator(), back.items[0]));
    }
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
        var m = (try a.conds.kappaSet(gpa, env.charge, .none, tops[i], Cond.yes)).ctx;
        m = try a.conds.kappaSetAt(gpa, env.charge, m, &.{Step.elem}, leaf, Cond.shared);
        maps[i] = m;
    }
    // The join stores `shared` on `proj(j, [*])`, a node no part of `j` names.
    const j = try Summary.Table.joinRes(env, tops[0], maps[0], tops[1], maps[1], .choice);
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
    var km = (try a.conds.kappaSet(gpa, a.env().charge, .none, root, Cond.yes)).ctx;
    km = try setAtNode(&a, km, root, inner1, Cond.yes);
    const c = try a.sums.add(a.env(), .{ .params = &.{.none}, .res = root, .kappas = km });
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTripWith(&a, &b, c, false));
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
        const before = a.account.total();
        try write(a.env(), &a.sums, &.{c}, .identity, &words);
        const cost = a.account.total() - before;
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
            [_]u32{ tag(.node), leaf, 0, 0, 0, none, 0, 0, tag(.node), leaf, 0, 0, second, none, 0, 0, tag(.node), @backingInt(Shape.Kind.@"union"), 0, 0, 0, 2, 1, 2, none, 0, tag(.class), 0, 0, 0, 3 } ++ no_class_rest ++ [_]u32{ 1, 4 };
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        try testing.expectEqual(second == 0, try read(t.env(), &t.sums, &words, .identity, &out) != null);
    }
    for ([_]u32{ 2, 1 }) |at| {
        // A `List` whose `[*]` child is a leaf at place `at` (its step's is 1).
        const words = [_]u32{ magic, version, 3, list, 200, 0, 1, @backingInt(Place.StepKind.elem), 0, 1, list, 201, 0, 0, ref, 400, 0, 0, 4 } ++ cond_yes ++
            [_]u32{ tag(.node), leaf, 1, 0, at, none, 0, 0, tag(.node), @backingInt(Shape.Kind.node), 0, 0, 0, none, 1, @backingInt(Place.StepKind.elem), 0, 1, 0, 0, tag(.class), 0, 0, 0, 2 } ++ no_class_rest ++ [_]u32{ 1, 3 };
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
    const km = (try a.conds.kappaSet(gpa, a.env().charge, .none, u, Cond.shared)).ctx;
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
    _ = &summary;
    var km = (try t.conds.kappaSet(gpa, env.charge, .none, res, Cond.yes)).ctx;
    km = try t.conds.kappaSetAt(gpa, env.charge, km, steps, at, Cond.shared);
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

test "#1311: a whole recast reads back whole, apart from the plain recast of the same inner" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const list = try a.place(0);
    const lists = try a.place(2);
    // `[ [ π1 ] ]` cast to `List Int`, as a class's `res`: whole, it holds
    // what the literal reaches (`π1`); plain, the literal's own site.
    const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, list), 0);
    const site = try a.cells.site(gpa, &a.account, 1, lists, .list);
    const kids = try a.shapes.overPut(gpa, &a.account, Ids.none_int, Step.elem, try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, a.env().charge, .none, p.int(), 0)));
    const inner = try a.shapes.node(gpa, &a.account, lists, try a.cells.sets.insert(gpa, a.env().charge, .none, site.int(), 0), kids);
    const whole = try a.shapes.recastWhole(gpa, &a.account, &a.cells.sets, list, inner);
    try testing.expect(whole != try a.shapes.recast(gpa, &a.account, list, inner));
    const c = try a.sums.add(a.env(), .{ .params = &.{.none}, .res = whole, .kappas = .none });
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    // The same words and the same printed class again (`roundTrip`).
    try testing.expect(b.shapes.isWhole(b.sums.get(try roundTrip(&a, &b, c)).res));
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
            km = try a.conds.kappaLink(gpa, env.charge, .none, s0, km);
            km = (try a.conds.kappaSet(gpa, env.charge, km, v, Cond.yes)).ctx;
        }
        const sups = try gpa.alloc(Summary.Supply, count);
        defer gpa.free(sups);
        for (sups, 0..) |*s, i| s.* = .{ .j = 0, .k = @intCast(i), .node = v, .label = .none, .owned = true, .taken = false, .kappa = km };
        const c = try a.sums.add(env, .{ .params = &.{.none}, .res = v, .kappas = km, .funs = &.{.{ .j = 0, .calls = .once, .supplies = sups }} });
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        // Under the default allowance.
        const before = a.account.total();
        try write(env, &a.sums, &.{c}, .identity, &words);
        const cost = a.account.total() - before;
        if (first == 0) first = cost else try testing.expect(cost * 10 <= first * 13);
    }
}

/// A class with `res` and one supply of `held`, both under one map with
/// `shared` stored at `stored`'s `[*]` position: κ at `[*]` of each value,
/// before and after a round trip, each under its own decoded map.
fn twoValues(t: *Tables, res: NodeId, held: NodeId, entry: NodeId, extra: []const NodeId) ![4]CondId {
    const gpa = testing.allocator;
    const env = t.env();
    var km = (try t.conds.kappaSet(gpa, env.charge, .none, res, Cond.yes)).ctx;
    for (extra) |n| km = (try t.conds.kappaSet(gpa, env.charge, km, n, Cond.yes)).ctx;
    km = try t.conds.kappaSetAt(gpa, env.charge, km, &.{Step.elem}, entry, Cond.shared);
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
        for (vals) |v| km = try a.conds.kappaSetAt(gpa, env.charge, km, &.{Step.elem}, (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, v, Step.elem)).?, Cond.shared);
        const sups = [_]Summary.Supply{.{ .j = 0, .k = 0, .node = vals[1], .label = .none, .owned = true, .taken = false, .kappa = km }};
        const c = try a.sums.add(env, .{ .params = &.{.none}, .res = vals[0], .kappas = km, .funs = &.{.{ .j = 0, .calls = .once, .supplies = &sups }} });
        try write(env, &a.sums, &.{c}, .identity, &out[flip]);
    }
    try testing.expectEqualSlices(u32, out[0].items, out[1].items);
}

/// A chain of `depth` distinct nested lists, `List (List (… Int))`: place
/// `v` holds place `v + 1` at `[*]`, numbered from 1 000 so they never meet
/// `Graph`'s.
const Deep = struct {
    const base = 1000;
    depth: u32,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const d: *Deep = @ptrCast(@alignCast(ctx));
        if (v == base + d.depth) return .{ .kind = .cross };
        try out.append(testing.allocator, .{ .step = Step.elem, .@"var" = v + 1 });
        return .{ .kind = .list, .head = 200 };
    }

    /// The places, outermost first.
    fn places(d: *Deep, t: *Tables) ![]PlaceId {
        const gpa = testing.allocator;
        t.places.limits.type_places = @max(t.places.limits.type_places, t.places.count() + d.depth + 64);
        const out = try gpa.alloc(PlaceId, d.depth + 1);
        out[0] = try t.places.of(gpa, &t.account, .{ .ctx = d, .describe = describe }, base);
        for (out[1..], 1..) |*p, i| p.* = t.places.child(out[i - 1], Step.elem).?;
        return out;
    }

    /// A value that names every place: a node at each with `[*]` the next,
    /// a marked leaf at the innermost.
    fn chain(d: *Deep, t: *Tables) !ClassId {
        const gpa = testing.allocator;
        const ps = try d.places(t);
        defer gpa.free(ps);
        const site = try t.cells.site(gpa, &t.account, 1, ps[d.depth - 1], .list);
        var v = try t.shapes.leaf(gpa, &t.account, ps[d.depth - 1], try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0));
        var i = d.depth - 1;
        while (i > 0) : (i -= 1) v = try t.shapes.node(gpa, &t.account, ps[i - 1], .none, try t.shapes.overPut(gpa, &t.account, Ids.none_int, Step.elem, v));
        return t.sums.add(t.env(), .{ .params = &.{}, .res = v });
    }
};

test "many distinct nested places cost n log n: a place's key never re-encodes what it reaches" {
    try expectLinearithmic(&.{ 250, 500, 1000 }, struct {
        fn make(t: *Tables, n: u32) anyerror!ClassId {
            var d: Deep = .{ .depth = n };
            return d.chain(t);
        }
    }.make);
}

/// Three classes besides `rows`: 48 nested places, a marked ring of 24,
/// and eight supplies sharing one map — built in `t` in either order, so
/// every id differs between the two.
fn mixed(t: *Tables, flip: bool) ![11]ClassId {
    const gpa = testing.allocator;
    var out: [11]ClassId = undefined;
    for (0..2) |k| {
        if ((k == 0) == flip) {
            out[0..8].* = try rows(t, flip);
            continue;
        }
        for (0..3) |j| {
            const which = if (flip) 2 - j else j;
            switch (which) {
                0 => {
                    var d: Deep = .{ .depth = 48 };
                    out[8] = try d.chain(t);
                },
                1 => {
                    const sets = try gpa.alloc(SetId, 24);
                    defer gpa.free(sets);
                    @memset(sets, .none);
                    sets[0] = (try siteSets(t, 1))[0];
                    const ns = try ring(t, sets);
                    defer gpa.free(ns);
                    out[9] = try t.sums.add(t.env(), .{ .params = &.{.none}, .res = ns[if (flip) 0 else 0] });
                },
                else => {
                    const env = t.env();
                    const tree = try t.place(8);
                    const s0 = try t.places.ctorStep(gpa, &t.account, 0, 0);
                    var v = try t.shapes.nothing(gpa, &t.account, tree);
                    var km: Cond.Kappas = .none;
                    for (0..12) |i| {
                        const site = try t.cells.site(gpa, &t.account, @intCast(i + 40), tree, .list);
                        v = try t.shapes.node(gpa, &t.account, tree, try t.cells.sets.insert(gpa, env.charge, .none, site.int(), 0), try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, v));
                        km = try t.conds.kappaLink(gpa, env.charge, .none, s0, km);
                        km = (try t.conds.kappaSet(gpa, env.charge, km, v, if (i % 3 == 0) Cond.shared else Cond.yes)).ctx;
                    }
                    var sups: [8]Summary.Supply = undefined;
                    for (&sups, 0..) |*s, i| s.* = .{ .j = 0, .k = @intCast(i), .node = v, .label = .none, .owned = true, .taken = false, .kappa = km };
                    out[10] = try t.sums.add(env, .{ .params = &.{.none}, .res = v, .kappas = km, .funs = &.{.{ .j = 0, .calls = .once, .supplies = &sups }} });
                },
            }
        }
    }
    return out;
}

fn writeMixed(flip: bool, out: *std.ArrayList(u32)) !void {
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    t.account.allowance = std.math.maxInt(u32) - 1;
    const classes = try mixed(&t, flip);
    try write(t.env(), &t.sums, &classes, .identity, out);
}

fn tableCounts(t: *Tables) [5]u32 {
    return .{ t.places.count(), t.cells.count(), t.shapes.count(), t.conds.count(), t.sums.count() };
}

/// Write `cs` with the codec's lane capped at `cap`, counting what the
/// writer allocates: the error, the growth and the baseline it took.
fn writeCapped(t: *Tables, cs: []const ClassId, cap: u64, out: *std.ArrayList(u32)) !struct { err: ?anyerror, growth: u32, baseline: u64, bytes: usize } {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var env = t.env();
    env.gpa = counting.allocator();
    t.account.failed = null;
    const g = t.account.growth;
    const b = t.account.baseline;
    const err: ?anyerror = if (Block.writeWith(env, &t.sums, cs, .identity, out, .{ .codec_cap = cap })) null else |e| e;
    if (err != null) try testing.expect(t.account.failed.? == .invariant);
    t.account.failed = null;
    return .{ .err = err, .growth = t.account.growth - g, .baseline = t.account.baseline - b, .bytes = counting.allocated_bytes };
}

test "the codec's lane stops the writer before the work: a cold place with a large reachable graph" {
    const gpa = testing.allocator;
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    // One leaf at the outermost of 20 000 nested places: its key reaches
    // them all.
    var d: Deep = .{ .depth = 20_000 };
    const ps = try d.places(&t);
    defer gpa.free(ps);
    const site = try t.cells.site(gpa, &t.account, 1, ps[0], .list);
    const leaf = try t.shapes.leaf(gpa, &t.account, ps[0], try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0));
    const c = try t.sums.add(t.env(), .{ .params = &.{}, .res = leaf });
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    var cap: u64 = 0;
    while (cap < 64) : (cap += 1) {
        const r = try writeCapped(&t, &.{c}, cap, &out);
        try testing.expectEqual(@as(?anyerror, error.AccountingInvariant), r.err);
        try testing.expectEqual(@as(usize, 0), out.items.len);
        try testing.expect(r.baseline <= cap);
        // What the writer allocated is bounded by what it reserved.
        if (@as(u64, r.bytes) > 1024 * (cap + 64)) {
            std.debug.print("cap {d}: {d} bytes allocated\n", .{ cap, r.bytes });
            return error.TestUnexpectedResult;
        }
    }
}

// The codec's lane stops the writer at every prefix: nothing written, no memo
// left behind. The first 200 caps one by one, and then the long prefixes in
// 48 steps in two halves, each part in one set of tables, one refusal after another (one
// test of both was over the 1 s budget, #1197).
test "the codec's lane stops the writer at every prefix: nothing written, no memo left behind, the first 200 caps" {
    try codecLane(0);
}

test "the codec's lane stops the writer at every prefix: nothing written, no memo left behind, the long prefixes" {
    try codecLane(1);
}

test "the codec's lane stops the writer at every prefix: nothing written, no memo left behind, the longest prefixes" {
    try codecLane(2);
}

/// Part 0: caps 0 to 200, one by one; parts 1 and 2: the halves of the 32
/// steps from 200 to the full price.
fn codecLane(part: u32) !void {
    const gpa = testing.allocator;
    var full: std.ArrayList(u32) = .empty;
    defer full.deinit(gpa);
    var paid: u64 = 0;
    var full_counts: [5]u32 = undefined;
    {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        t.account.allowance = std.math.maxInt(u32) - 1;
        const classes = try mixed(&t, false);
        const before = t.account.baseline;
        try write(t.env(), &t.sums, &classes, .identity, &full);
        paid = t.account.baseline - before;
        full_counts = tableCounts(&t);
    }
    // Every prefix refused in one set of tables, one after another.
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    t.account.allowance = std.math.maxInt(u32) - 1;
    const classes = try mixed(&t, false);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    var cap: u64 = 0;
    const step = paid / 32;
    const mid = @min(paid, 200 + 16 * step);
    if (part == 1) cap = @min(200, paid);
    if (part == 2) cap = mid;
    const end: u64 = switch (part) {
        0 => @min(200, paid),
        1 => mid,
        else => paid,
    };
    while (cap < end) : (cap += if (cap < 200) 1 else step) {
        const r = try writeCapped(&t, classes[0..], cap, &out);
        try testing.expectEqual(@as(?anyerror, error.AccountingInvariant), r.err);
        try testing.expectEqual(@as(usize, 0), out.items.len);
        try testing.expect(r.baseline <= cap);
        if (@as(u64, r.bytes) > 1024 * (cap + 64)) {
            std.debug.print("cap {d}: {d} bytes allocated\n", .{ cap, r.bytes });
            return error.TestUnexpectedResult;
        }
        // What the refused writes left in the tables, one full write makes.
        for (tableCounts(&t), full_counts) |x, y| try testing.expect(x <= y);
    }
    // And the next write, with room, is the one fresh tables make.
    try write(t.env(), &t.sums, &classes, .identity, &out);
    try testing.expectEqualSlices(u32, full.items, out.items);
}

test "a block built in another order writes the same bytes, and reads back to them: nested places, a marked ring, shared owners, the rows" {
    const gpa = testing.allocator;
    var out: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&out) |*o| o.deinit(gpa);
    for (0..2) |flip| try writeMixed(flip == 1, &out[flip]);
    try testing.expectEqualSlices(u32, out[0].items, out[1].items);
    // write ∘ read ∘ write is write.
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    b.account.allowance = std.math.maxInt(u32) - 1;
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(gpa);
    try testing.expect(try read(b.env(), &b.sums, out[0].items, .identity, &back) != null);
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(gpa);
    try write(b.env(), &b.sums, back.items, .identity, &again);
    try testing.expectEqualSlices(u32, out[0].items, again.items);
}

/// The knot `x0 → x2 → x1 → x0` (`x2` marked) and `s3 → x1`, all at
/// `Tree` by `#Node.0`; the classes' values `s3`, `x1` and `x0`, or, with
/// `copy`, a node `→ x2` outside the knot, bisimilar to `x0`, for the last.
fn knotAndCopy(t: *Tables, copy: bool) ![3]ClassId {
    const gpa = testing.allocator;
    const tree = try t.place(8);
    const s0 = try t.places.ctorStep(gpa, &t.account, 0, 0);
    const mark = (try siteSets(t, 1))[0];
    var x: [3]NodeId = undefined;
    for (&x) |*n| n.* = try t.shapes.knot(gpa, &t.account);
    const next = [3]usize{ 2, 0, 1 };
    for (x, 0..) |n, i| {
        const ch = try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, x[next[i]]);
        t.shapes.tie(n, .{ .kind = .node, .place = tree, .cells = if (i == 2) mark else .none, .a = ch, .b = 0, .reach = .none });
    }
    const s3 = try t.shapes.node(gpa, &t.account, tree, .none, try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, x[1]));
    const last = if (copy) try t.shapes.node(gpa, &t.account, tree, .none, try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, x[2])) else x[0];
    var out: [3]ClassId = undefined;
    for ([_]NodeId{ s3, x[1], last }, 0..) |v, i| out[i] = try t.sums.add(t.env(), .{ .params = &.{.none}, .res = v });
    return out;
}

test "bisimilar values are one block: a copy outside a knot writes the knot's bytes, and reads back to them" {
    const gpa = testing.allocator;
    var out: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&out) |*o| o.deinit(gpa);
    for (0..2) |copy| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        const cs = try knotAndCopy(&t, copy == 1);
        try write(t.env(), &t.sums, &cs, .identity, &out[copy]);
    }
    try testing.expectEqualSlices(u32, out[0].items, out[1].items);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    var back: std.ArrayList(ClassId) = .empty;
    defer back.deinit(gpa);
    try testing.expect(try read(b.env(), &b.sums, out[1].items, .identity, &back) != null);
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(gpa);
    try write(b.env(), &b.sums, back.items, .identity, &again);
    try testing.expectEqualSlices(u32, out[1].items, again.items);
}

/// A `Model` record of 50 records of 50 fields each, every field its own
/// place: 2 551 places. Numbered from 100 000.
const Wide = struct {
    const base = 100_000;
    account: *Ids.Account,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const w: *Wide = @ptrCast(@alignCast(ctx));
        const i = v - base;
        if (i > 50) return .{ .kind = .cross };
        for (0..50) |j| {
            const child: u32 = if (i == 0) base + 1 + @as(u32, @intCast(j)) else base + 51 + (i - 1) * 50 + @as(u32, @intCast(j));
            try out.append(testing.allocator, .{ .step = Step.field(w.account, @intCast(j)) catch unreachable, .@"var" = child });
        }
        return .{ .kind = .record };
    }
};

// Source-sized values write under the default allowance: one test per value
// (the four in one test were near the 1 s budget, #1197).
test "source-sized values write under the default allowance: a 4 000-deep type" {
    try sourceSized(0);
}

test "source-sized values write under the default allowance: a 1 040-node ring" {
    try sourceSized(1);
}

test "source-sized values write under the default allowance: a 2 551-place model" {
    try sourceSized(2);
}

test "source-sized values write under the default allowance: a 500-deep taken chain" {
    try sourceSized(3);
}

fn sourceSized(case: u32) !void {
    const gpa = testing.allocator;
    {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        const c: ClassId = switch (case) {
            0 => blk: {
                var d: Deep = .{ .depth = 4000 };
                const ps = try d.places(&t);
                defer gpa.free(ps);
                const site = try t.cells.site(gpa, &t.account, 1, ps[0], .list);
                const leaf = try t.shapes.leaf(gpa, &t.account, ps[0], try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0));
                break :blk try t.sums.add(t.env(), .{ .params = &.{}, .res = leaf });
            },
            1 => blk: {
                const sets = try gpa.alloc(SetId, 1040);
                defer gpa.free(sets);
                @memset(sets, .none);
                sets[0] = (try siteSets(&t, 1))[0];
                const ns = try ring(&t, sets);
                defer gpa.free(ns);
                break :blk try t.sums.add(t.env(), .{ .params = &.{.none}, .res = ns[0] });
            },
            2 => blk: {
                var wide: Wide = .{ .account = &t.account };
                const model = try t.places.of(gpa, &t.account, .{ .ctx = &wide, .describe = Wide.describe }, Wide.base);
                const site = try t.cells.site(gpa, &t.account, 1, model, .record);
                const leaf = try t.shapes.leaf(gpa, &t.account, model, try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0));
                break :blk try t.sums.add(t.env(), .{ .params = &.{}, .res = leaf });
            },
            else => blk: {
                const env = t.env();
                const list = try t.place(0);
                var cell = try t.cells.symbolic(gpa, &t.account, &t.places, .param, 0, try t.places.rootPath(gpa, list), 0);
                for (0..500) |i| {
                    const l = try t.cells.label(gpa, &t.account, @intCast(i), .none, false);
                    _ = try t.cells.split(gpa, &t.account, cell, @intCast(i), l, try t.conds.excl(gpa, env.charge, cell));
                    cell = try t.cells.refine(gpa, &t.account, .elem, cell, l, 0, list, .list);
                }
                const res = try t.shapes.leaf(gpa, &t.account, list, try t.cells.sets.insert(gpa, env.charge, .none, cell.int(), 0));
                break :blk try t.sums.add(env, .{ .params = &.{.none}, .res = res });
            },
        };
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        const before = t.account.growth;
        try write(t.env(), &t.sums, &.{c}, .identity, &words);
        // The write charges the allowance nothing for these values (measured:
        // growth 0); a 256th of it still catches a charge of one a few levels.
        try testing.expect(t.account.growth - before < Ids.Account.default_allowance / 256);
    }
}

/// A chain of 400 nodes at `Tree` and `k` supplies of it, each under its
/// own map: k interpretations of every node.
fn manyMaps(t: *Tables, k: u32) !ClassId {
    return manyMapsOver(t, k, 400);
}

/// `k` maps over a chain of `len` nodes (at most 400), each map's κ `shared` at
/// its own depth.
fn manyMapsOver(t: *Tables, k: u32, len: usize) !ClassId {
    const gpa = testing.allocator;
    const env = t.env();
    const tree = try t.place(8);
    const s0 = try t.places.ctorStep(gpa, &t.account, 0, 0);
    var v = try t.shapes.nothing(gpa, &t.account, tree);
    var chain_buf: [400]NodeId = undefined;
    const chain = chain_buf[0..len];
    for (chain, 0..) |*n, i| {
        const site = try t.cells.site(gpa, &t.account, @intCast(i + 1), tree, .list);
        v = try t.shapes.node(gpa, &t.account, tree, try t.cells.sets.insert(gpa, env.charge, .none, site.int(), 0), try t.shapes.overPut(gpa, &t.account, Ids.none_int, s0, v));
        n.* = v;
    }
    const sups = try gpa.alloc(Summary.Supply, k);
    defer gpa.free(sups);
    for (sups, 0..) |*s, i| {
        const km = try below_n(t, .none, s0, @intCast(len - 1 - (i % len)), chain[i % len], Cond.shared);
        s.* = .{ .j = 0, .k = @intCast(i), .node = v, .label = .none, .owned = true, .taken = false, .kappa = km };
    }
    return t.sums.add(env, .{ .params = &.{.none}, .res = v, .funs = &.{.{ .j = 0, .calls = .once, .supplies = sups }} });
}

test "a class whose interpretations grow past the allowance is refused loudly" {
    const gpa = testing.allocator;
    // §4.4's default.
    try testing.expectEqual(@as(u32, 65_536), Ids.Account.default_allowance);
    // Eight maps over 200 nodes: 1 400 interpretations past one per node,
    // against a declaration allowed 1 000.
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    t.account.allowance = std.math.maxInt(u32) - 1;
    const c = try manyMapsOver(&t, 8, 200);
    var small: Ids.Account = .{ .allowance = 1000 };
    defer small.deinit(gpa);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, Block.writeWith(t.env(), &t.sums, &.{c}, .identity, &out, .{ .charges = &.{.growth(&small)} }));
    try testing.expect(small.failed.? == .exhausted);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a class's interpretations are charged to its own declaration" {
    const gpa = testing.allocator;
    // Two declarations in one block: each class's growth on its own.
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    t.account.allowance = std.math.maxInt(u32) - 1;
    const heavy = try manyMapsOver(&t, 8, 200);
    const light = try t.sums.add(t.env(), .{ .params = &.{.none}, .res = try t.shapes.nothing(gpa, &t.account, try t.place(0)) });
    var accounts: [2]Ids.Account = .{ .{}, .{} };
    defer for (&accounts) |*a| a.deinit(gpa);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    const growth = t.account.growth;
    try Block.writeWith(t.env(), &t.sums, &.{ heavy, light }, .identity, &out, .{ .charges = &.{ .growth(&accounts[0]), .growth(&accounts[1]) } });
    try testing.expect(accounts[0].growth >= 7 * 200);
    try testing.expectEqual(@as(u32, 0), accounts[1].growth);
    try testing.expectEqual(growth, t.account.growth);
}

/// A record of `f` fields, each its own place — with `nested`, each field
/// a record of `f` fields itself. Numbered from 300 000.
const Fields = struct {
    const base = 300_000;
    account: *Ids.Account,
    f: u32,
    nested: bool,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const w: *Fields = @ptrCast(@alignCast(ctx));
        const i = v - base;
        if (i > (if (w.nested) w.f else 0)) return .{ .kind = .cross };
        for (0..w.f) |j| {
            const child: u32 = if (i == 0) base + 1 + @as(u32, @intCast(j)) else base + 1 + w.f + (i - 1) * w.f + @as(u32, @intCast(j));
            try out.append(testing.allocator, .{ .step = Step.field(w.account, @intCast(j)) catch unreachable, .@"var" = child });
        }
        return .{ .kind = .record };
    }

    fn place(w: *Fields, t: *Tables) !PlaceId {
        t.places.limits.type_places = @max(t.places.limits.type_places, t.places.count() + (w.f + 1) * (w.f + 1) + 8);
        return t.places.of(testing.allocator, &t.account, .{ .ctx = w, .describe = describe }, base);
    }
};

/// A node at record place `at` holding one field: a leaf with a site.
fn oneField(t: *Tables, at: PlaceId, site_id: u32) !NodeId {
    const gpa = testing.allocator;
    const s = try Step.field(&t.account, 0);
    const site = try t.cells.site(gpa, &t.account, site_id, at, .record);
    const leaf = try t.shapes.leaf(gpa, &t.account, t.places.child(at, s).?, try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0));
    return t.shapes.node(gpa, &t.account, at, .none, try t.shapes.overPut(gpa, &t.account, Ids.none_int, s, leaf));
}

// A type's width costs the writer nothing, under the default allowance, no
// growth: one test per shape (the four in one were near the 1 s budget, #1197).
test "a type's width costs the writer nothing: one node of a 4 000-field record" {
    try typeWidth(0);
}

test "a type's width costs the writer nothing: one node of a 30 000-field record" {
    try typeWidth(1);
}

test "a type's width costs the writer nothing: 340 nodes of a 100-field record" {
    try typeWidth(2);
}

test "a type's width costs the writer nothing: a 128 × 128 record" {
    try typeWidth(3);
}

fn typeWidth(case: u32) !void {
    const gpa = testing.allocator;
    {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        var fields: Fields = .{ .account = &t.account, .f = switch (case) {
            0 => 4000,
            1 => 30_000,
            2 => 100,
            else => 128,
        }, .nested = case == 3 };
        const model = try fields.place(&t);
        const c: ClassId = switch (case) {
            0, 1 => try t.sums.add(t.env(), .{ .params = &.{}, .res = try oneField(&t, model, 1) }),
            2 => blk: {
                var params: [340]NodeId = undefined;
                for (&params, 0..) |*p, i| p.* = try oneField(&t, model, @intCast(i + 1));
                break :blk try t.sums.add(t.env(), .{ .params = &params, .res = params[0] });
            },
            else => blk: {
                var over: u32 = Ids.none_int;
                for (0..128) |j| {
                    const s = try Step.field(&t.account, @intCast(j));
                    over = try t.shapes.overPut(gpa, &t.account, over, s, try oneField(&t, t.places.child(model, s).?, @intCast(j + 1)));
                }
                break :blk try t.sums.add(t.env(), .{ .params = &.{}, .res = try t.shapes.node(gpa, &t.account, model, .none, over) });
            },
        };
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        const before = t.account.growth;
        try write(t.env(), &t.sums, &.{c}, .identity, &out);
        try testing.expectEqual(before, t.account.growth);
    }
}

test "the codec's work is O(S log S) whatever the width: P declarations of one node at a P-field record" {
    const gpa = testing.allocator;
    var ratios: [3]f64 = undefined;
    for ([_]u32{ 128, 256, 512 }, 0..) |p, k| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        t.account.allowance = std.math.maxInt(u32) - 1;
        var fields: Fields = .{ .account = &t.account, .f = p, .nested = false };
        const model = try fields.place(&t);
        const cs = try gpa.alloc(ClassId, p);
        defer gpa.free(cs);
        const accounts = try gpa.alloc(Ids.Account, p);
        defer gpa.free(accounts);
        const charges = try gpa.alloc(Ids.Charge, p);
        defer gpa.free(charges);
        for (cs, accounts, charges, 0..) |*c, *a, *ch, i| {
            c.* = try t.sums.add(t.env(), .{ .params = &.{}, .res = try oneField(&t, model, @intCast(i + 1)) });
            a.* = .{};
            ch.* = .growth(a);
        }
        defer for (accounts) |*a| a.deinit(gpa);
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        const before = t.account.baseline;
        try Block.writeWith(t.env(), &t.sums, cs, .identity, &out, .{ .charges = charges });
        for (accounts) |a| try testing.expectEqual(@as(u32, 0), a.growth);
        // Against the block's words, which no measure of the writer's own
        // can inflate.
        const s: u64 = out.items.len;
        ratios[k] = @as(f64, @floatFromInt(t.account.baseline - before)) / @as(f64, @floatFromInt((s + 16) * std.math.log2_int_ceil(u64, s + 2)));
    }
    for (ratios[1..]) |r| try testing.expect(r <= ratios[0] * 1.25);
}

// A declaration's growth is its own: editing another that shares its
// records changes nothing of it. B is eight maps over a 200-node chain; A,
// the chain under one map or under eight more, first in the block. One test
// per edit, each against B alone (one test was over the 1 s budget, #1197).
test "a declaration's growth is its own: a declaration sharing its chain under one map changes nothing of it" {
    const alone = try sharedGrowth(0);
    try testing.expect(alone >= 7 * 100);
    try testing.expectEqual(alone, try sharedGrowth(1));
}

test "a declaration's growth is its own: a declaration sharing its maps and eight more changes nothing of it" {
    try testing.expectEqual(try sharedGrowth(0), try sharedGrowth(2));
}

/// B's growth when written alone (variant 0) or after A (1, 2).
fn sharedGrowth(variant: u32) !u32 {
    const gpa = testing.allocator;
    var t: Tables = .{};
    try t.init();
    defer t.deinit();
    t.account.allowance = std.math.maxInt(u32) - 1;
    const b = try manyMapsOver(&t, 8, 100);
    const a = if (variant == 2) try manyMapsOver(&t, 16, 100) else try t.sums.add(t.env(), .{ .params = &.{.none}, .res = t.sums.get(b).res });
    var accounts: [2]Ids.Account = .{ .{}, .{} };
    defer for (&accounts) |*x| x.deinit(gpa);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    if (variant == 0) {
        try Block.writeWith(t.env(), &t.sums, &.{b}, .identity, &out, .{ .charges = &.{.growth(&accounts[1])} });
    } else try Block.writeWith(t.env(), &t.sums, &.{ a, b }, .identity, &out, .{ .charges = &.{ .growth(&accounts[0]), .growth(&accounts[1]) } });
    return accounts[1].growth;
}

/// The atoms of a condition: how many, and how many are `excl` (a constant
/// is 100 + its id, no atoms).
fn atomCounts(t: *Tables, k: CondId) ![2]u32 {
    if (k == Cond.yes or k == Cond.shared or k == Cond.lost) return .{ k.int() + 100, 0 };
    var it = t.conds.atoms.iterate(try t.conds.flat(testing.allocator, t.env().charge, k));
    var n: u32 = 0;
    var excls: u32 = 0;
    while (it.next()) |e| {
        n += 1;
        if (t.conds.get(.from(e.key)).atom == .excl) excls += 1;
    }
    return .{ n, excls };
}

test "a round trip keeps deep's answer below a leaf: the block writes what is stored" {
    // `ownership-v2.md` §3.6: a position's κ is written as stored, the read
    // derives the rest from the structure the block rebuilds. `res` is the
    // leaf `{p}` at `List { a : List Int }`, `excl q` stored at `[*].a`; the
    // `[*]` on the way there is a projection `deep` reads stored-only, so a
    // block that wrote its derivation there would give `deep` more atoms.
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    const recs = try a.place(7);
    const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, recs), 0);
    const q = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 1, try a.places.rootPath(gpa, recs), 0);
    const res = try a.shapes.leaf(gpa, &a.account, recs, try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    const e1 = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, res, Step.elem)).?;
    const e2 = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, e1, try Step.field(&a.account, 10))).?;
    const km = try a.conds.kappaSetAt(gpa, env.charge, .none, &.{ Step.elem, try Step.field(&a.account, 10) }, e2, try a.conds.excl(gpa, env.charge, q));
    const c = try a.sums.add(env, .{ .params = &.{.none}, .res = res, .kappas = km });
    const d0 = try a.conds.deep(gpa, env.charge, env.view(), km, res, false);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    const d1 = try b.conds.deep(gpa, b.env().charge, b.env().view(), back.kappas, back.res, false);
    try testing.expectEqual(try atomCounts(&a, d0), try atomCounts(&b, d1));
}

test "#1129: a relabelled fold round-trips with the steps it saw: deep reaches below it after decode" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    const recs = try a.place(7);
    const fa = try Step.field(&a.account, 10);
    const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, recs), 0);
    const res = try a.shapes.leaf(gpa, &a.account, recs, try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    const e1 = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, res, Step.elem)).?;
    const e2 = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, e1, fa)).?;
    // `shared` below a collapsed fold, the snapshot then relabelled by the
    // identity, as a read-off relabels it.
    const folded = try a.conds.kappaFold(gpa, env.charge, try a.conds.kappaSetAt(gpa, env.charge, .none, &.{ Step.elem, fa }, e2, Cond.shared));
    const Identity = struct {
        fn node(_: *anyopaque, n: NodeId) Error!?NodeId {
            return n;
        }
        fn cond(_: *anyopaque, _: *Cond.Table, _: Allocator, _: Ids.Charge, k: CondId) Error!CondId {
            return k;
        }
    };
    var dummy: u8 = 0;
    const km = try a.conds.kappaRelabel(gpa, env.charge, folded, .{ .ctx = &dummy, .node = Identity.node, .cond = Identity.cond });
    try testing.expectEqual(Cond.shared, try a.conds.deep(gpa, env.charge, env.view(), km, res, false));
    const c = try a.sums.add(env, .{ .params = &.{.none}, .res = res, .kappas = km });
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    try testing.expect(b.conds.isFold(back.kappas));
    try testing.expectEqual(Cond.shared, try b.conds.deep(gpa, b.env().charge, b.env().view(), back.kappas, back.res, false));
}
test "#1073: a folded snapshot round-trips: its fold, and every read at and below it" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const env = a.env();
    const s0 = try a.places.ctorStep(gpa, &a.account, 0, 0);
    // The widened tree's snapshot, `shared` stored at `.0` before the
    // widen: `propagate` folds it where the shape cycles.
    const w = try widenedTree(&a);
    var unfolded = (try a.conds.kappaSet(gpa, env.charge, .none, w, Cond.yes)).ctx;
    unfolded = try a.conds.kappaSetAt(gpa, env.charge, unfolded, &.{s0}, try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, w, s0) orelse return error.NoChild, Cond.shared);
    const km = try a.conds.propagate(gpa, env.charge, env.view(), .none, w, &.{ w, w }, &.{ unfolded, .none }, .alternatives, false, null);
    const c = try a.sums.add(env, .{ .params = &.{.none}, .res = w, .kappas = km });
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    // Where the written snapshot folds, the read one does, at the same path
    // (each table's own words for the constructor's arguments).
    const Paths = struct {
        fn of(t: *Tables, i: usize) ![]const Step {
            const g = testing.allocator;
            const x0 = try t.places.ctorStep(g, &t.account, 0, 0);
            const x2 = try t.places.ctorStep(g, &t.account, 0, 2);
            const all = [_][]const Step{ &.{}, &.{x0}, &.{x2}, &.{ x0, x0 }, &.{ x0, x2 }, &.{ x2, x0, x0 } };
            return g.dupe(Step, all[i]);
        }
    };
    var any = false;
    for (0..6) |i| {
        const pa = try Paths.of(&a, i);
        defer gpa.free(pa);
        const pb = try Paths.of(&b, i);
        defer gpa.free(pb);
        const fa = a.conds.isFold(a.conds.kappaAlong(km, pa));
        any = any or fa;
        try testing.expectEqual(fa, b.conds.isFold(b.conds.kappaAlong(back.kappas, pb)));
        try testing.expectEqual(try kappaAt(&a, km, w, pa), try kappaAt(&b, back.kappas, back.res, pb));
    }
    // And a fold was there to round-trip.
    try testing.expect(any);
}

test "#1073: κ stored below one unbuilt field of a wide record costs the writer the same at any width" {
    const gpa = testing.allocator;
    var extra: [2]u64 = undefined;
    for ([_]u32{ 10, 11 }, 0..) |place, run| {
        var cost: [2]u64 = undefined;
        for (0..2) |stores| {
            var a: Tables = .{};
            try a.init();
            defer a.deinit();
            const env = a.env();
            const rec = try a.place(place);
            // A record parameter: a leaf, no field built.
            const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, rec), 0);
            const res = try a.shapes.leaf(gpa, &a.account, rec, try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
            const f0 = try Step.field(&a.account, 100);
            const at = (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, (try a.shapes.proj(gpa, &a.account, &a.places, &a.cells, res, f0)).?, Step.elem)).?;
            const km: Cond.Kappas = if (stores == 1) try a.conds.kappaSetAt(gpa, env.charge, .none, &.{ f0, Step.elem }, at, Cond.shared) else .none;
            const c = try a.sums.add(env, .{ .params = &.{.none}, .res = res, .kappas = km });
            var words: std.ArrayList(u32) = .empty;
            defer words.deinit(gpa);
            const before = a.account.total();
            try write(env, &a.sums, &.{c}, .identity, &words);
            cost[stores] = a.account.total() - before;
            if (stores == 1) {
                // And it is read back where it was stored.
                var b: Tables = .{};
                try b.init();
                defer b.deinit();
                const back = b.sums.get(try roundTrip(&a, &b, c));
                const g0 = try Step.field(&b.account, 100);
                try testing.expectEqual(Cond.shared, try kappaAt(&b, back.kappas, back.res, &.{ g0, Step.elem }));
            }
        }
        // What the stored entry adds to the block's work.
        extra[run] = cost[1] - cost[0];
    }
    // Eight fields or 512: the entry costs the same, up to the codec's
    // logarithmic sort terms; the place's width is paid once, by the place
    // table, either way.
    try testing.expect(extra[1] <= extra[0] + 16);
}

/// `ctx` (the snapshot of a value whose shape is `root`) with κ(target)
/// joined with `k` at every position of `root`'s explicit structure where
/// `target` stands; a route stops at a node it has passed.
fn setAtNode(t: *Tables, ctx: Cond.Kappas, root: NodeId, target: NodeId, k: CondId) !Cond.Kappas {
    var path: std.ArrayList(Step) = .empty;
    defer path.deinit(testing.allocator);
    var route: std.ArrayList(NodeId) = .empty;
    defer route.deinit(testing.allocator);
    var out = ctx;
    try setAtNodeFrom(t, &out, root, target, k, &path, &route);
    return out;
}

fn setAtNodeFrom(t: *Tables, out: *Cond.Kappas, n: NodeId, target: NodeId, k: CondId, path: *std.ArrayList(Step), route: *std.ArrayList(NodeId)) !void {
    const gpa = testing.allocator;
    for (route.items) |r| if (r == n) return;
    if (n == target) out.* = try t.conds.kappaSetAt(gpa, t.env().charge, out.*, path.items, n, k);
    try route.append(gpa, n);
    defer _ = route.pop();
    const d = t.shapes.get(n);
    switch (d.kind) {
        .view => unreachable, // a read block holds no views
        .leaf => {},
        .node, .delta => {
            if (d.kind == .delta) try setAtNodeFrom(t, out, .from(d.a), target, k, path, route);
            var it = t.shapes.overEntries(if (d.kind == .node) d.a else d.b);
            while (it.next()) |e| {
                try path.append(gpa, e.step);
                defer _ = path.pop();
                try setAtNodeFrom(t, out, e.node, target, k, path, route);
            }
        },
        .recast => try setAtNodeFrom(t, out, .from(d.a), target, k, path, route),
        .@"union", .choice, .positions => {
            try setAtNodeFrom(t, out, .from(d.a), target, k, path, route);
            try setAtNodeFrom(t, out, .from(d.b), target, k, path, route);
        },
    }
}

test "#1073 review: reading a fold's group is linear in its members" {
    const gpa = testing.allocator;
    var read_cost: [3]u64 = undefined;
    for ([_]u32{ 51, 101, 201 }, 0..) |members, run| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        a.account.allowance = std.math.maxInt(u32) - 1;
        const env = a.env();
        // A record node with `members − 1` built list fields, its snapshot an
        // exact fold at the root: every position is one fold group.
        const rec = try a.place(11);
        const lists = try a.place(2);
        var kids: u32 = Ids.none_int;
        for (0..members - 1) |i| {
            const site = try a.cells.site(gpa, &a.account, @intCast(i + 1), lists, .list);
            const kid = try a.shapes.node(gpa, &a.account, lists, try a.cells.sets.insert(gpa, env.charge, .none, site.int(), 0), Ids.none_int);
            kids = try a.shapes.overPut(gpa, &a.account, kids, try Step.field(&a.account, @intCast(100 + i)), kid);
        }
        const root = try a.shapes.node(gpa, &a.account, rec, try a.cells.sets.insert(gpa, env.charge, .none, (try a.cells.site(gpa, &a.account, 999, rec, .record)).int(), 0), kids);
        var km = try a.conds.kappaEmptyFold(gpa, env.charge, Cond.Table.fold_exact);
        km = (try a.conds.kappaSet(gpa, env.charge, km, root, Cond.yes)).ctx;
        const c = try a.sums.add(env, .{ .params = &.{.none}, .res = root, .kappas = km });
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        try write(env, &a.sums, &.{c}, .identity, &words);
        var b: Tables = .{};
        try b.init();
        defer b.deinit();
        b.account.allowance = std.math.maxInt(u32) - 1;
        var back: std.ArrayList(ClassId) = .empty;
        defer back.deinit(gpa);
        const before = b.account.total();
        try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
        read_cost[run] = b.account.total() - before;
        try testing.expect(b.conds.isFold(b.sums.get(back.items[0]).kappas));
    }
    // About twice the members, about twice the reader's work, never four.
    try testing.expect(read_cost[1] <= 3 * read_cost[0]);
    try testing.expect(read_cost[2] <= 3 * read_cost[1]);
}

test "#1138: a snapshot as deep as the source is written and read back on explicit stacks" {
    // The stack fits the walks' fixed frames at a shallow depth with a wide
    // margin. A run `deep_factor` times deeper must pass on that same stack:
    // a native frame per level (hundreds of bytes, times the depth) cannot.
    try onSmallStack(shallow_depth);
    try onSmallStack(shallow_depth * deep_factor);
}

const shallow_depth = 20;
const deep_factor = 10;
const small_stack = 128 << 10;

fn onSmallStack(depth: usize) !void {
    var result: anyerror!void = {};
    const th = try std.Thread.spawn(.{ .stack_size = small_stack }, struct {
        fn run(out: *anyerror!void, d: usize) void {
            out.* = deepBlock(d);
        }
    }.run, .{ &result, depth });
    th.join();
    try result;
}

fn deepBlock(depth: usize) !void {
    const gpa = testing.allocator;
    // The tables live on the heap: the 64 KiB stack is for the walks, so a
    // larger table record cannot overflow it (#1197) — only a native frame
    // per level would.
    const a = try gpa.create(Tables);
    defer gpa.destroy(a);
    a.* = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const c = try deepClass(a, depth);
    const b = try gpa.create(Tables);
    defer gpa.destroy(b);
    b.* = .{};
    try b.init();
    defer b.deinit();
    b.account.allowance = std.math.maxInt(u32) - 1;
    const back = b.sums.get(try roundTrip(a, b, c));
    // The bottom level reads what it read.
    const s0 = try b.places.ctorStep(gpa, &b.account, 0, 0);
    var at = back.res;
    var cur = back.kappas;
    for (0..depth - 1) |_| {
        at = (try b.shapes.proj(gpa, &b.account, &b.places, &b.cells, at, s0)).?;
        cur = b.conds.kappaChild(cur, s0);
    }
    try testing.expectEqual(Cond.yes, b.conds.kappaGet(cur, at).?);
}

/// A class whose `res` is `depth` levels down `#0`, each with its own list
/// at `#1` and `yes` stored at its node: a snapshot position per level.
fn deepClass(a: *Tables, depth: usize) !ClassId {
    const gpa = testing.allocator;
    const tree = try a.place(8);
    const list = try a.place(0);
    const s0 = try a.places.ctorStep(gpa, &a.account, 0, 0);
    const s1 = try a.places.ctorStep(gpa, &a.account, 0, 1);
    var level = try a.shapes.leaf(gpa, &a.account, tree, .none);
    var km: Cond.Kappas = .none;
    for (0..depth) |i| {
        const site = try a.cells.site(gpa, &a.account, @intCast(i + 1), list, .list);
        var children = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s0, level);
        children = try a.shapes.overPut(gpa, &a.account, children, s1, try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, a.env().charge, .none, site.int(), 0)));
        level = try a.shapes.node(gpa, &a.account, tree, .none, children);
        km = try a.conds.kappaLink(gpa, a.env().charge, .none, s0, km);
        km = (try a.conds.kappaSet(gpa, a.env().charge, km, level, Cond.yes)).ctx;
    }
    return a.sums.add(a.env(), .{ .params = &.{.none}, .res = level, .kappas = km });
}

test "#1141: the codec's work on a snapshot grows with its depth, never with its square" {
    const gpa = testing.allocator;
    var write_cost: [3]u64 = undefined;
    var read_cost: [3]u64 = undefined;
    // 64, 128 and 256 levels: the ratio, not the size, tells n from n²
    // (2 000 levels took the test over the 1 s budget, #1197; 500, CI's, #1209).
    for ([_]usize{ 64, 128, 256 }, 0..) |depth, run| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        a.account.allowance = std.math.maxInt(u32) - 1;
        const c = try deepClass(&a, depth);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        const wrote = a.account.baseline;
        try write(a.env(), &a.sums, &.{c}, .identity, &words);
        write_cost[run] = a.account.baseline - wrote;
        var b: Tables = .{};
        try b.init();
        defer b.deinit();
        b.account.allowance = std.math.maxInt(u32) - 1;
        var back: std.ArrayList(ClassId) = .empty;
        defer back.deinit(gpa);
        const before = b.account.total();
        try testing.expect(try read(b.env(), &b.sums, words.items, .identity, &back) != null);
        read_cost[run] = b.account.total() - before;
    }
    // Twice the levels, about twice the work (measured 2.05, n log n at most), never
    // 2.5 times: a quadratic of even half an n² is caught.
    for (1..3) |i| {
        try testing.expect(write_cost[i] * 2 <= 5 * write_cost[i - 1]);
        try testing.expect(read_cost[i] * 2 <= 5 * read_cost[i - 1]);
    }
}

/// A cyclic `res` of sites only, grafted (its sites map to themselves),
/// writes the block the original writes (#1143's review).
fn graftedSame(t: *Tables, res: NodeId) !void {
    const gpa = testing.allocator;
    const c0 = try t.sums.add(t.env(), .{ .params = &.{.none}, .res = res });
    var s: Calls.Scratch = .{};
    defer s.deinit(gpa);
    const arg = try t.shapes.leaf(gpa, &t.account, try t.place(8), .none);
    const applied = try Calls.apply(t.env(), &t.sums, c0, &.{.{ .node = arg, .kappa = .none }}, 0, &s);
    // The call answers a view (§2.11): a class holds it forced, as read-off
    // maps a result.
    const Same = struct {
        fn cells(_: void, s0: Ids.SetId) Shape.Error!Ids.SetId {
            return s0;
        }
    };
    const forced = try t.shapes.map(gpa, &t.account, applied.result.node, {}, Same.cells);
    try testing.expect(forced != res);
    const c1 = try t.sums.add(t.env(), .{ .params = &.{.none}, .res = forced });
    var wa: std.ArrayList(u32) = .empty;
    defer wa.deinit(gpa);
    var wb: std.ArrayList(u32) = .empty;
    defer wb.deinit(gpa);
    try write(t.env(), &t.sums, &.{c0}, .identity, &wa);
    try write(t.env(), &t.sums, &.{c1}, .identity, &wb);
    try testing.expectEqualSlices(u32, wa.items, wb.items);
}

fn knotSite(t: *Tables, i: u32) !NodeId {
    const gpa = testing.allocator;
    const tree = try t.place(8);
    const site = try t.cells.site(gpa, &t.account, i, tree, .record);
    return t.shapes.leaf(gpa, &t.account, tree, try t.cells.sets.insert(gpa, t.env().charge, .none, site.int(), 0));
}

fn knotSides(t: *Tables, k: NodeId, kind: Shape.Kind, a: NodeId, b: NodeId) !void {
    t.shapes.tie(k, .{ .kind = kind, .place = try t.place(8), .cells = try t.cells.sets.unionWith(testing.allocator, t.env().charge, t.shapes.cells(a), t.shapes.cells(b)), .a = a.int(), .b = b.int(), .reach = .none });
}

fn knotNode(t: *Tables, k: NodeId, child: NodeId, second: ?NodeId) !void {
    const gpa = testing.allocator;
    var m = try t.shapes.overPut(gpa, &t.account, Ids.none_int, try t.places.ctorStep(gpa, &t.account, 0, 0), child);
    if (second) |x| m = try t.shapes.overPut(gpa, &t.account, m, try t.places.ctorStep(gpa, &t.account, 0, 2), x);
    t.shapes.tie(k, .{ .kind = .node, .place = try t.place(8), .cells = .none, .a = m, .b = 0, .reach = .none });
}

test "#1143: a cyclic result grafted writes the block its original writes" {
    const gpa = testing.allocator;
    // A back edge on a union's side; two knots waiting on each other
    // through union sides; a positions side.
    for (0..3) |case| {
        var t: Tables = .{};
        try t.init();
        defer t.deinit();
        t.account.allowance = std.math.maxInt(u32) - 1;
        const a = try t.shapes.knot(gpa, &t.account);
        const b = try t.shapes.knot(gpa, &t.account);
        switch (case) {
            0 => {
                try knotSides(&t, b, .@"union", a, try knotSite(&t, 1));
                try knotNode(&t, a, b, a);
            },
            1 => {
                const na = try t.shapes.knot(gpa, &t.account);
                const nb = try t.shapes.knot(gpa, &t.account);
                try knotNode(&t, na, b, null);
                try knotNode(&t, nb, a, b);
                try knotSides(&t, a, .@"union", na, try knotSite(&t, 1));
                try knotSides(&t, b, .@"union", nb, a);
            },
            2 => {
                try knotSides(&t, b, .positions, a, try knotSite(&t, 1));
                try knotNode(&t, a, b, null);
            },
            else => unreachable,
        }
        try graftedSame(&t, a);
    }
}

test "#1122: a cell at two paths is published at both, through Summary and the block" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    // `( a, a )` over `List Int × List Int`: one leaf, two routes.
    const pair = try a.place(9);
    const list = try a.place(0);
    const p1 = try a.cells.symbolic(gpa, &a.account, &a.places, .param, 0, try a.places.rootPath(gpa, list), 0);
    const leaf = try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, p1.int(), 0));
    const s0 = try Step.index(&a.account, 0);
    const s1 = try Step.index(&a.account, 1);
    var kids = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s0, leaf);
    kids = try a.shapes.overPut(gpa, &a.account, kids, s1, leaf);
    const c = try a.sums.add(env, .{ .params = &.{.none}, .res = try a.shapes.node(gpa, &a.account, pair, .none, kids) });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try a.text(arena, c);
    try testing.expect(std.mem.indexOf(u8, before, ".0 π1") != null and std.mem.indexOf(u8, before, ".1 π1") != null);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    try testing.expectEqualStrings(before, try b.text(arena, try roundTrip(&a, &b, c)));
    // Both routes hold the cell, read back.
    for ([_]Step{ s0, s1 }) |s| {
        const at = (try b.shapes.proj(gpa, &b.account, &b.places, &b.cells, back.res, s)).?;
        try testing.expectEqual(@as(u32, 1), b.cells.sets.count(b.shapes.cells(at)));
    }
}

test "#1122 review: a built node at two paths is published at both, through Summary and the block" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    // `( p, p )`, `p = ( a, b )`: one built node, two routes, printed as a
    // reference to its first route and read back as one node at both.
    const outer = try a.place(12);
    const pair = try a.place(9);
    const list = try a.place(0);
    const s0 = try Step.index(&a.account, 0);
    const s1 = try Step.index(&a.account, 1);
    var leaves: [2]NodeId = undefined;
    for (&leaves, 0..) |*l, i| {
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, @intCast(i), try a.places.rootPath(gpa, list), 0);
        l.* = try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    }
    var inner = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s0, leaves[0]);
    inner = try a.shapes.overPut(gpa, &a.account, inner, s1, leaves[1]);
    const p = try a.shapes.node(gpa, &a.account, pair, .none, inner);
    var kids = try a.shapes.overPut(gpa, &a.account, Ids.none_int, s0, p);
    kids = try a.shapes.overPut(gpa, &a.account, kids, s1, p);
    const c = try a.sums.add(env, .{ .params = &.{ .none, .none }, .res = try a.shapes.node(gpa, &a.account, outer, .none, kids) });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try a.text(arena, c);
    try testing.expect(std.mem.indexOf(u8, before, ".0.0 π1, .0.1 π2, .1 = .0") != null);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    try testing.expectEqualStrings(before, try b.text(arena, try roundTrip(&a, &b, c)));
    // Both routes are one node holding both cells below.
    const at0 = (try b.shapes.proj(gpa, &b.account, &b.places, &b.cells, back.res, s0)).?;
    const at1 = (try b.shapes.proj(gpa, &b.account, &b.places, &b.cells, back.res, s1)).?;
    try testing.expectEqual(at0, at1);
    for ([_]Step{ s0, s1 }) |s| try testing.expectEqual(@as(u32, 1), b.cells.sets.count(b.shapes.cells((try b.shapes.proj(gpa, &b.account, &b.places, &b.cells, at0, s)).?)));
}

test "#1128: a choice decodes to a choice, never a union" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    const env = a.env();
    const list = try a.place(0);
    var arms: [2]NodeId = undefined;
    for (&arms, 0..) |*arm, i| {
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, @intCast(i), try a.places.rootPath(gpa, list), 0);
        arm.* = try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    }
    const c = try a.sums.add(env, .{ .params = &.{ .none, .none }, .res = try a.shapes.choice(gpa, &a.account, &a.cells.sets, arms[0], arms[1]) });
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    const back = b.sums.get(try roundTrip(&a, &b, c));
    try testing.expectEqual(Shape.Kind.choice, b.shapes.kind(back.res));
}

test "#1128: a folded class's path-multiset obligation crosses the block" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const env = a.env();
    // `T (T _ π2 _) π1 _` over place 8 (`C 8 0 8`): the lists `π1` at depth 0
    // and `π2` at depth 1 fold into one class, which owes `apart [π1] [π2]`.
    const tree = try a.place(8);
    const list = try a.place(0);
    const s = [_]Step{ try a.places.ctorStep(gpa, &a.account, 0, 0), try a.places.ctorStep(gpa, &a.account, 0, 1), try a.places.ctorStep(gpa, &a.account, 0, 2) };
    var lists: [2]NodeId = undefined;
    for (&lists, 0..) |*l, i| {
        const p = try a.cells.symbolic(gpa, &a.account, &a.places, .param, @intCast(i), try a.places.rootPath(gpa, list), 0);
        l.* = try a.shapes.leaf(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
    }
    const empty = try a.shapes.nothing(gpa, &a.account, tree);
    const node = struct {
        fn of(t: *Tables, ss: [3]Step, l: NodeId, e: NodeId, sub: NodeId) !NodeId {
            var m = try t.shapes.overPut(testing.allocator, &t.account, Ids.none_int, ss[0], sub);
            m = try t.shapes.overPut(testing.allocator, &t.account, m, ss[1], l);
            m = try t.shapes.overPut(testing.allocator, &t.account, m, ss[2], e);
            return t.shapes.node(testing.allocator, &t.account, try t.place(8), .none, m);
        }
    }.of;
    const inner = try node(&a, s, lists[1], empty, empty);
    const outer = try node(&a, s, lists[0], empty, inner);
    var k = (try a.conds.kappaSet(gpa, env.charge, .none, outer, Cond.yes)).ctx;
    k = try a.conds.kappaSetAt(gpa, env.charge, k, &.{s[0]}, inner, Cond.yes);
    const w = try a.conds.widenValue(gpa, env.charge, env.view(), outer, k);
    try testing.expect(w.node != outer);
    const c = try a.sums.add(env, .{ .params = &.{ .none, .none }, .res = w.node, .kappas = w.kappas });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try a.text(arena, c);

    try testing.expect(std.mem.indexOf(u8, before, "apart [π1] [π2]") != null);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    try testing.expectEqualStrings(before, try b.text(arena, try roundTrip(&a, &b, c)));
}

test "#1128: a #1125 repeat, one kids list at two depths, reads lost through the block" {
    const gpa = testing.allocator;
    var a: Tables = .{};
    try a.init();
    defer a.deinit();
    a.account.allowance = std.math.maxInt(u32) - 1;
    const env = a.env();
    // `k = [ … ]` at `.1` of the root and of its `.0` child (#1125's
    // minimal): no path holds `k` twice, the folded class does.
    const tree = try a.place(8);
    const list = try a.place(0);
    const s = [_]Step{ try a.places.ctorStep(gpa, &a.account, 0, 0), try a.places.ctorStep(gpa, &a.account, 0, 1), try a.places.ctorStep(gpa, &a.account, 0, 2) };
    const site = try a.cells.site(gpa, &a.account, 1, list, .list);
    const k = try a.shapes.node(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, site.int(), 0), Ids.none_int);
    const empty = try a.shapes.nothing(gpa, &a.account, tree);
    const node = struct {
        fn of(t: *Tables, ss: [3]Step, l: NodeId, e: NodeId, sub: NodeId) !NodeId {
            var m = try t.shapes.overPut(testing.allocator, &t.account, Ids.none_int, ss[0], sub);
            m = try t.shapes.overPut(testing.allocator, &t.account, m, ss[1], l);
            m = try t.shapes.overPut(testing.allocator, &t.account, m, ss[2], e);
            return t.shapes.node(testing.allocator, &t.account, try t.place(8), .none, m);
        }
    }.of;
    const inner = try node(&a, s, k, empty, empty);
    const outer = try node(&a, s, k, empty, inner);
    var kk = (try a.conds.kappaSet(gpa, env.charge, .none, outer, Cond.yes)).ctx;
    kk = try a.conds.kappaSetAt(gpa, env.charge, kk, &.{s[0]}, inner, Cond.yes);
    kk = try a.conds.kappaSetAt(gpa, env.charge, kk, &.{s[1]}, k, Cond.yes);
    kk = try a.conds.kappaSetAt(gpa, env.charge, kk, &.{ s[0], s[1] }, k, Cond.yes);
    const w = try a.conds.widenValue(gpa, env.charge, env.view(), outer, kk);
    const c = try a.sums.add(env, .{ .params = &.{}, .res = w.node, .kappas = w.kappas });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try a.text(arena, c);
    try testing.expect(std.mem.indexOf(u8, before, "{lost}") != null);
    var b: Tables = .{};
    try b.init();
    defer b.deinit();
    try testing.expectEqualStrings(before, try b.text(arena, try roundTrip(&a, &b, c)));
}

test "#1157 review: a widened class's lost stays lost through the block, a choice or union at the fold too" {
    const gpa = testing.allocator;
    for (0..3) |variant| {
        var a: Tables = .{};
        try a.init();
        defer a.deinit();
        a.account.allowance = std.math.maxInt(u32) - 1;
        const env = a.env();
        // `T (T _ k2 _) k _` over place 8, every built node `yes` where it
        // stands; variant 1 puts a choice at the fold, 2 a union.
        const tree = try a.place(8);
        const list = try a.place(0);
        const s = [_]Step{ try a.places.ctorStep(gpa, &a.account, 0, 0), try a.places.ctorStep(gpa, &a.account, 0, 1), try a.places.ctorStep(gpa, &a.account, 0, 2) };
        var ks: [2]NodeId = undefined;
        for (&ks, 0..) |*k, i| {
            const site = try a.cells.site(gpa, &a.account, @intCast(i + 1), list, .list);
            k.* = try a.shapes.node(gpa, &a.account, list, try a.cells.sets.insert(gpa, env.charge, .none, site.int(), 0), Ids.none_int);
        }
        const empty = try a.shapes.nothing(gpa, &a.account, tree);
        const node = struct {
            fn of(t: *Tables, ss: [3]Step, l: NodeId, e: NodeId, sub: NodeId) !NodeId {
                var m = try t.shapes.overPut(testing.allocator, &t.account, Ids.none_int, ss[0], sub);
                m = try t.shapes.overPut(testing.allocator, &t.account, m, ss[1], l);
                m = try t.shapes.overPut(testing.allocator, &t.account, m, ss[2], e);
                return t.shapes.node(testing.allocator, &t.account, try t.place(8), .none, m);
            }
        }.of;
        const inner = try node(&a, s, ks[1], empty, empty);
        const other = try node(&a, s, ks[0], empty, empty);
        const at0: NodeId = switch (variant) {
            0 => inner,
            1 => try a.shapes.choice(gpa, &a.account, &a.cells.sets, inner, other),
            else => try a.shapes.@"union"(gpa, &a.account, &a.cells.sets, inner, other),
        };
        const outer = try node(&a, s, ks[0], empty, at0);
        var kk = (try a.conds.kappaSet(gpa, env.charge, .none, outer, Cond.yes)).ctx;
        for ([_]NodeId{ inner, other }) |n| kk = try a.conds.kappaSetAt(gpa, env.charge, kk, &.{s[0]}, n, Cond.yes);
        kk = try a.conds.kappaSetAt(gpa, env.charge, kk, &.{s[1]}, ks[0], Cond.yes);
        for (ks) |k| kk = try a.conds.kappaSetAt(gpa, env.charge, kk, &.{ s[0], s[1] }, k, Cond.yes);
        const w = try a.conds.widenValue(gpa, env.charge, env.view(), outer, kk);
        const c = try a.sums.add(env, .{ .params = &.{}, .res = w.node, .kappas = w.kappas });
        var b: Tables = .{};
        try b.init();
        defer b.deinit();
        // `roundTrip` compares the printed class before and after.
        _ = try roundTrip(&a, &b, c);
    }
}
