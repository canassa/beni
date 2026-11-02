//! The data-oriented measurement of the ownership checker v2: what its
//! containers are asked, and a census of the data they hold. A hidden build
//! option, `-Downership-v2-counters`, turns it on; `gates` refuses it.
//!
//! **Off, it is not there.** `enabled` is comptime false, every stats type is
//! `void`, every hook is an `inline` function that returns at once, and every
//! caller guards its argument work with `if (Counters.enabled)`. The compiled
//! checker and everything it prints are byte for byte the checker without this
//! file.
//!
//! **On**, the dump of a module (`beni dump --stage=ownership --ownership=v2`)
//! ends with `counters …` and `census …` lines, from `write`:
//!
//! - per table-resident dictionary and column, found by reflection over the
//!   module's tables (so the line names the field path): gets, hits, puts,
//!   new entries, and for a crit-bit dictionary the mean and longest descent;
//! - per width of dictionary, and for columns and pools, a total over every
//!   instance, local ones included: the difference to the sum of the table
//!   lines is the walks' own working sets;
//! - the cardinality of every persistent set (`SetId`) and κ map, as a
//!   histogram of the nodes made and of the requests made of them;
//! - per node attribute: how many distinct nodes (or ids) an attribute column
//!   was ever asked about, against how many exist;
//! - whether `Shape.Table.tie` changes a node's kind (`ShapeCensus`).
//!
//! `-Downership-v2-trace=<dir>` also writes every table dictionary's
//! operations (`<field path>.k<width>`, `u32` records of a tag, 0 for a get
//! and 1 for a put, and the key's words), which `bench/own2-dict/` replays.
//!
//! The counts are plain integers: run with `--jobs=1`. `MultiArrayList`
//! accessors are not counted here (std's type has no hook); their share is the
//! cost S1 removes, measured with `perf`.
//!
//! Obligations kept here: none.

const std = @import("std");
const options = @import("ownership_options");

pub const enabled: bool = options.counters;
const trace_dir: []const u8 = options.trace_dir;

pub fn Field(comptime T: type) type {
    return if (enabled) T else void;
}

/// The default value of a `Field`.
pub fn zero(comptime T: type) T {
    return if (T == void) {} else .{};
}

// ---------------------------------------------------------------------------
// Histograms
// ---------------------------------------------------------------------------

/// Counts by size: 0, 1, 2, 3-4, 5-8, 9-16, 17-32, 33-64, 65-128, 129-256,
/// 257-1024, more.
pub const Hist = struct {
    b: [bucket_count]u64 = @splat(0),
    n: u64 = 0,
    sum: u64 = 0,
    max: u32 = 0,

    pub const bucket_count = 12;
    const labels = [bucket_count][]const u8{ "0", "1", "2", "3-4", "5-8", "9-16", "17-32", "33-64", "65-128", "129-256", "257-1024", "1025+" };

    fn bucketOf(v: u32) usize {
        if (v <= 2) return v;
        if (v <= 4) return 3;
        if (v <= 8) return 4;
        if (v <= 16) return 5;
        if (v <= 32) return 6;
        if (v <= 64) return 7;
        if (v <= 128) return 8;
        if (v <= 256) return 9;
        if (v <= 1024) return 10;
        return 11;
    }

    pub fn add(h: *Hist, v: u32) void {
        h.b[bucketOf(v)] += 1;
        h.n += 1;
        h.sum += v;
        h.max = @max(h.max, v);
    }

    fn write(h: Hist, w: *std.Io.Writer, what: []const u8, label: []const u8, note: []const u8) std.Io.Writer.Error!void {
        try w.print("census {s} {s}{s}: n {d}, max {d}, mean {d:.2}, ", .{ what, label, note, h.n, h.max, if (h.n == 0) 0.0 else @as(f64, @floatFromInt(h.sum)) / @as(f64, @floatFromInt(h.n)) });
        for (h.b, labels) |c, l| if (c != 0) try w.print(" {s}:{d}", .{ l, c });
        try w.writeAll("\n");
    }
};

// ---------------------------------------------------------------------------
// Dictionaries, columns, pools
// ---------------------------------------------------------------------------

pub const Kind = enum { dict, column, pool };

pub const DictStats = struct {
    gets: u64 = 0,
    hits: u64 = 0,
    puts: u64 = 0,
    new: u64 = 0,
    /// Nodes visited by the crit-bit descents of gets and puts.
    probes: u64 = 0,
    max_probe: u32 = 0,
    last_probe: u32 = 0,
    /// `(tag, key words…)` per operation, when `-Downership-v2-trace` is set.
    trace: std.ArrayList(u32) = .empty,

    pub const counter_kind: Kind = .dict;
};
pub const Dict = Field(DictStats);

pub const ColStats = struct {
    reads: u64 = 0,
    hits: u64 = 0,
    writes: u64 = 0,
    /// Writes to a slot never written before: the distinct ids ever stored.
    fresh: u64 = 0,
    clears: u64 = 0,

    pub const counter_kind: Kind = .column;
};
pub const Col = Field(ColStats);

pub const PoolStats = struct {
    takes: u64 = 0,
    creates: u64 = 0,

    pub const counter_kind: Kind = .pool;
};
pub const PoolS = Field(PoolStats);

/// Every instance, local working sets included. FixedDict(k) for k in 1...5
/// at index k, wider at 0.
var dict_totals: [6]DictStats = @splat(.{});
var col_total: ColStats = .{};
var pool_total: PoolStats = .{};

/// Forget the totals: a module's report counts that module alone.
pub fn reset() void {
    if (!enabled) return;
    dict_totals = @splat(.{});
    col_total = .{};
    pool_total = .{};
}

/// A descent's length counter: nothing when off.
pub const Steps = struct {
    n: if (enabled) u32 else void = if (enabled) 0 else {},
    pub inline fn inc(s: *Steps) void {
        if (enabled) s.n += 1;
    }
};

inline fn mutable(p: anytype) @TypeOf(@constCast(p)) {
    return @constCast(p);
}

pub inline fn dictDescended(s: anytype, steps: Steps) void {
    if (!enabled) return;
    mutable(s).last_probe = steps.n;
}

pub inline fn dictGet(comptime k: usize, s: anytype, key: *const [k]u32, hit: bool) void {
    if (!enabled) return;
    const m = mutable(s);
    const t = &dict_totals[if (k < 6) k else 0];
    m.gets += 1;
    t.gets += 1;
    m.probes += m.last_probe;
    t.probes += m.last_probe;
    m.max_probe = @max(m.max_probe, m.last_probe);
    if (hit) {
        m.hits += 1;
        t.hits += 1;
    }
    if (trace_dir.len != 0) traceOp(m, 0, key);
}

pub inline fn dictPut(comptime k: usize, s: anytype, key: *const [k]u32, found: bool) void {
    if (!enabled) return;
    const m = mutable(s);
    const t = &dict_totals[if (k < 6) k else 0];
    m.puts += 1;
    t.puts += 1;
    m.probes += m.last_probe;
    t.probes += m.last_probe;
    m.max_probe = @max(m.max_probe, m.last_probe);
    if (!found) {
        m.new += 1;
        t.new += 1;
    }
    if (trace_dir.len != 0) traceOp(m, 1, key);
}

fn traceOp(m: *DictStats, tag: u32, key: []const u32) void {
    m.trace.append(std.heap.smp_allocator, tag) catch @panic("out of memory recording a trace");
    m.trace.appendSlice(std.heap.smp_allocator, key) catch @panic("out of memory recording a trace");
}

pub inline fn colRead(s: anytype, hit: bool) void {
    if (!enabled) return;
    const m = mutable(s);
    m.reads += 1;
    col_total.reads += 1;
    if (hit) {
        m.hits += 1;
        col_total.hits += 1;
    }
}

pub inline fn colWrite(s: anytype, fresh: bool) void {
    if (!enabled) return;
    const m = mutable(s);
    m.writes += 1;
    col_total.writes += 1;
    if (fresh) {
        m.fresh += 1;
        col_total.fresh += 1;
    }
}

pub inline fn colClear(s: anytype) void {
    if (!enabled) return;
    mutable(s).clears += 1;
    col_total.clears += 1;
}

pub inline fn poolTake(s: anytype, created: bool) void {
    if (!enabled) return;
    const m = mutable(s);
    m.takes += 1;
    pool_total.takes += 1;
    if (created) {
        m.creates += 1;
        pool_total.creates += 1;
    }
}

// ---------------------------------------------------------------------------
// Persistent sets and maps
// ---------------------------------------------------------------------------

/// A `Cell.Radix`'s, or a κ map store's: the cardinality of every node made
/// (children precede parents, so one sum each), and of what is asked of them.
pub const SetStats = struct {
    /// Per node id, the keys under it.
    cards: std.ArrayList(u32) = .empty,
    /// Requests to make a node: its cardinality, hits and misses together.
    make: Hist = .{},
    /// The operands of the operations, at every level of their recursion.
    get: Hist = .{},
    insert_in: Hist = .{},
    union_a: Hist = .{},
    union_b: Hist = .{},

    pub fn deinit(s: *SetStats, gpa: std.mem.Allocator) void {
        s.cards.deinit(gpa);
    }
};
pub const Sets = Field(SetStats);

pub inline fn setDeinit(s: anytype, gpa: std.mem.Allocator) void {
    if (enabled) s.deinit(gpa);
}

/// `none` is the empty set: cardinality 0.
fn cardOf(s: *const SetStats, id: u32) u32 {
    return if (id == std.math.maxInt(u32)) 0 else s.cards.items[id];
}

pub inline fn setRequest(s: anytype, comptime which: enum { make, get, insert_in, union_a, union_b }, id: u32) void {
    if (!enabled) return;
    @field(mutable(s), @tagName(which)).add(cardOf(s, id));
}

/// A node `leaf` (a leaf) or with children `l`, `r` was made.
pub inline fn setMade(s: anytype, gpa: std.mem.Allocator, is_leaf: bool, l: u32, r: u32) std.mem.Allocator.Error!void {
    if (!enabled) return;
    const card: u32 = if (is_leaf) 1 else cardOf(s, l) + cardOf(s, r);
    try mutable(s).cards.append(gpa, card);
}

/// A request to make a node answered by an existing one, or by the new one.
pub inline fn setMakeRequest(s: anytype, id: u32) void {
    if (!enabled) return;
    mutable(s).make.add(cardOf(s, id));
}

// ---------------------------------------------------------------------------
// Shape nodes: does `tie` change a kind?
// ---------------------------------------------------------------------------

pub const KindSite = enum { tie, raw_copy, widen_copy, widen_swap, widen_keep, map_adopt };

pub const ShapeCensus = struct {
    /// Per site, `[old kind][new kind]`.
    writes: [site_count][kinds][kinds]u32 = @splat(@splat(@splat(0))),
    /// Per site, the writes onto a knot not yet written (the placeholder
    /// `knot` leaves) and onto any other node.
    onto_knot: [site_count]u32 = @splat(0),
    onto_other: [site_count]u32 = @splat(0),
    /// Per origin of a placeholder (`Origin`): how many were made, and the
    /// reads of one's kind before its record was written.
    knots: [2]u32 = .{ 0, 0 },
    reads_before_write: [2]u64 = .{ 0, 0 },
    open: [2]std.DynamicBitSetUnmanaged = .{ .{}, .{} },

    const site_count = @typeInfo(KindSite).@"enum".field_names.len;
    const kinds = 8;

    pub fn deinit(c: *ShapeCensus, gpa: std.mem.Allocator) void {
        for (&c.open) |*o| o.deinit(gpa);
    }
};

/// A node whose record is written after its id is named: `Table.knot`'s, or
/// a `widen` class's.
pub const Origin = enum { knot, widen };
pub const Shapes = Field(ShapeCensus);

pub inline fn shapesDeinit(c: anytype, gpa: std.mem.Allocator) void {
    if (enabled) c.deinit(gpa);
}

pub inline fn knotMade(c: anytype, gpa: std.mem.Allocator, comptime origin: Origin, id: u32) std.mem.Allocator.Error!void {
    if (!enabled) return;
    const o = &c.open[@backingInt(origin)];
    if (o.bit_length <= id) try o.resize(gpa, @max(id + 1, 2 * o.bit_length), false);
    o.set(id);
    c.knots[@backingInt(origin)] += 1;
}

pub inline fn kindWrite(c: anytype, comptime site: KindSite, id: u32, old: anytype, new: anytype) void {
    if (!enabled) return;
    const si = @backingInt(site);
    c.writes[si][@backingInt(old)][@backingInt(new)] += 1;
    for (&c.open) |*o| if (id < o.bit_length and o.isSet(id)) {
        c.onto_knot[si] += 1;
        o.unset(id);
        return;
    };
    c.onto_other[si] += 1;
}

pub inline fn kindRead(c: anytype, id: u32) void {
    if (!enabled) return;
    for (&mutable(c).open, 0..) |*o, i| if (id < o.bit_length and o.isSet(id)) {
        mutable(c).reads_before_write[i] += 1;
    };
}

// ---------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------

const Error = std.Io.Writer.Error;

fn isOwn(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .@"struct" => |s| s.layout == .auto and std.mem.startsWith(u8, @typeName(F), "own2.") or std.mem.indexOf(u8, @typeName(F), ".Table") != null or std.mem.indexOf(u8, @typeName(F), "Radix") != null,
        else => false,
    };
}

/// The rows of the table whose ids `K` are, for the share of them an
/// attribute was asked about.
fn rowsOf(comptime K: type, mod: anytype) ?usize {
    const name = @typeName(K);
    if (comptime std.mem.endsWith(u8, name, "NodeId")) return mod.shapes.nodes.len;
    if (comptime std.mem.endsWith(u8, name, "CondId")) return mod.conds.conds.len;
    if (comptime std.mem.endsWith(u8, name, "PlaceId")) return mod.places.places.len;
    if (comptime std.mem.endsWith(u8, name, "CellId")) return mod.cells.cells.len;
    return null;
}

fn writeDict(w: *std.Io.Writer, path: []const u8, comptime k: usize, d: anytype) Error!void {
    const s = d.stats;
    const mean = if (s.gets + s.puts == 0) 0.0 else @as(f64, @floatFromInt(s.probes)) / @as(f64, @floatFromInt(s.gets + s.puts));
    try w.print("counters dict {s} k={d}: gets {d}, hits {d}, puts {d}, new {d}, entries {d}, descent mean {d:.1}, max {d}\n", .{ path, k, s.gets, s.hits, s.puts, s.new, d.count(), mean, s.max_probe });
    if (trace_dir.len != 0 and s.trace.items.len != 0) {
        var name: [160]u8 = undefined;
        const file = std.fmt.bufPrint(&name, "{s}/{s}.k{d}", .{ trace_dir, path, k }) catch return;
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = std.mem.sliceAsBytes(s.trace.items) }) catch |err| try w.print("counters trace {s}: not written: {t}\n", .{ file, err });
    }
}

fn writeLeaf(w: *std.Io.Writer, comptime path: []const u8, comptime F: type, v: *const F, mod: anytype) Error!void {
    switch (F.counter_kind) {
        .dict => try writeDict(w, path, @typeInfo(F.Key).array.len, v),
        .column => {
            const s = v.stats;
            try w.print("counters column {s}: reads {d}, hits {d}, writes {d}, distinct {d}, clears {d}, slots {d}", .{ path, s.reads, s.hits, s.writes, s.fresh, s.clears, v.slots.items.len });
            if (rowsOf(F.Key, mod)) |rows| try w.print(", of {d} {s} rows ({d:.1}%)", .{ rows, @typeName(F.Key), if (rows == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(s.fresh)) / @as(f64, @floatFromInt(rows)) });
            try w.writeAll("\n");
        },
        .pool => try w.print("counters pool {s}: takes {d}, created {d}\n", .{ path, v.stats.takes, v.stats.creates }),
    }
}

fn walk(w: *std.Io.Writer, comptime path: []const u8, comptime T: type, v: *const T, mod: anytype) Error!void {
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
        const sub = path ++ name;
        if (@typeInfo(F) == .@"struct") {
            if (@hasDecl(F, "counter_kind")) {
                try writeLeaf(w, sub, F, &@field(v.*, name), mod);
            } else if (@hasField(F, "stats") and @hasField(F, "category")) {
                // A `Radix`: its nodes' cardinalities.
                try writeSets(w, sub, "set", &@field(v.*, name).stats);
                try walk(w, sub ++ ".", F, &@field(v.*, name), mod);
            } else if (@hasDecl(F, "items") or @hasDecl(F, "slice") or !isOwn(F)) {
                if (@hasDecl(F, "slice")) try w.print("counters rows {s}: {d}\n", .{ sub, @field(v.*, name).len });
            } else try walk(w, sub ++ ".", F, &@field(v.*, name), mod);
        }
    }
}

fn writeSets(w: *std.Io.Writer, path: []const u8, what: []const u8, s: *const SetStats) Error!void {
    var made: Hist = .{};
    for (s.cards.items) |c| made.add(c);
    try made.write(w, what, path, " (nodes made)");
    try s.make.write(w, what, path, " (make requests)");
    try s.get.write(w, what, path, " (get operands)");
    try s.insert_in.write(w, what, path, " (insert operands)");
    try s.union_a.write(w, what, path, " (union left operands)");
    try s.union_b.write(w, what, path, " (union right operands)");
}

/// The module's counters and census, as lines.
pub fn write(w: *std.Io.Writer, mod: anytype) Error!void {
    if (!enabled) return;
    try w.writeAll("counters: ownership v2 data-oriented measurement (docs: src/own2/Counters.zig)\n");
    try walk(w, "places.", @TypeOf(mod.places), &mod.places, mod);
    try walk(w, "cells.", @TypeOf(mod.cells), &mod.cells, mod);
    try walk(w, "shapes.", @TypeOf(mod.shapes), &mod.shapes, mod);
    try walk(w, "conds.", @TypeOf(mod.conds), &mod.conds, mod);
    try walk(w, "sums.", @TypeOf(mod.sums), &mod.sums, mod);
    for (dict_totals, 0..) |t, k| {
        if (t.gets + t.puts == 0) continue;
        try w.print("counters total dict k={d}{s}: gets {d}, hits {d}, puts {d}, new {d}, descent mean {d:.1}\n", .{ k, if (k == 0) "+" else "", t.gets, t.hits, t.puts, t.new, @as(f64, @floatFromInt(t.probes)) / @as(f64, @floatFromInt(t.gets + t.puts)) });
    }
    try w.print("counters total column: reads {d}, hits {d}, writes {d}, distinct {d}, clears {d}\n", .{ col_total.reads, col_total.hits, col_total.writes, col_total.fresh, col_total.clears });
    try w.print("counters total pool: takes {d}, created {d}\n", .{ pool_total.takes, pool_total.creates });
    try writeShapes(w, mod);
    try writeKappa(w, mod);
}

fn writeShapes(w: *std.Io.Writer, mod: anytype) Error!void {
    const t = &mod.shapes;
    const NodeKind = @TypeOf(t.nodes.items(.kind)[0]);
    var by_kind: [8]u32 = @splat(0);
    var reach: u32 = 0;
    var lazy: u32 = 0;
    for (t.nodes.items(.kind), t.nodes.items(.reach), t.nodes.items(.cells)) |k, r, c| {
        by_kind[@backingInt(k)] += 1;
        if (r != .none) reach += 1;
        if (c == @TypeOf(t.*).lazy_cells) lazy += 1;
    }
    try w.print("census nodes: {d} total, reach memo set on {d}, lazy cells {d}, counted {d}, ties {d}, kinds", .{ t.nodes.len, reach, lazy, t.counted.count(), t.ties });
    inline for (@typeInfo(NodeKind).@"enum".field_names, 0..) |name, i| try w.print(" {s}:{d}", .{ name, by_kind[i] });
    try w.writeAll("\n");
    const c = &t.census;
    try w.print("census placeholders: knot() {d} made, {d} kind()/get() reads before the record was written; widen classes {d} made, {d} reads\n", .{ c.knots[0], c.reads_before_write[0], c.knots[1], c.reads_before_write[1] });
    inline for (@typeInfo(KindSite).@"enum".field_names, 0..) |site, si| {
        var total: u32 = 0;
        var changed: u32 = 0;
        for (c.writes[si], 0..) |row, o| for (row, 0..) |n, nw| {
            total += n;
            if (o != nw) changed += n;
        };
        if (total != 0) {
            try w.print("census kind-write {s}: {d} writes, {d} change the kind, {d} onto a fresh knot, {d} onto another node;", .{ site, total, changed, c.onto_knot[si], c.onto_other[si] });
            inline for (@typeInfo(NodeKind).@"enum".field_names, 0..) |on, o| inline for (@typeInfo(NodeKind).@"enum".field_names, 0..) |nn, nw| {
                if (c.writes[si][o][nw] != 0) try w.print(" {s}>{s}:{d}", .{ on, nn, c.writes[si][o][nw] });
            };
            try w.writeAll("\n");
        }
    }
    // The cell sets a node holds at its root.
    var held: Hist = .{};
    for (t.nodes.items(.cells)) |cs| {
        if (cs == @TypeOf(t.*).lazy_cells) continue;
        held.add(if (cs == .none) 0 else mod.cells.sets.stats.cards.items[cs.int()]);
    }
    try held.write(w, "set", "shapes.nodes.cells", " (a node's own cells, eager ones)");
}

fn writeKappa(w: *std.Io.Writer, mod: anytype) Error!void {
    const t = &mod.conds;
    const none = std.math.maxInt(u32);
    try writeSets(w, "conds.kmaps", "kmap", &t.kmap_stats);
    var here: Hist = .{};
    var links: Hist = .{};
    for (t.kpos.items(.here), t.kpos.items(.links)) |h, l| {
        here.add(if (h == none) 0 else t.kmap_stats.cards.items[h]);
        links.add(if (l == none) 0 else t.kmap_stats.cards.items[l]);
    }
    try here.write(w, "kmap", "conds.kpos.here", " (per position)");
    try links.write(w, "kmap", "conds.kpos.links", " (per position)");
    try w.print("census kpos: {d} positions, {d} kmap nodes\n", .{ t.kpos.len, t.kmaps.len });
}
