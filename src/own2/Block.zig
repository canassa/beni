//! L11: contracts as words (`docs/design/ownership-v2.md` §3.6, format
//! v-next): what a module publishes for its importers. Every module-local
//! id is written canonically: a relative slot as its steps, a field by its
//! name (a string of the block's table), a constructor argument by
//! `(ordinal, argument)`, a top-level value and a label's origin by their
//! qualified names. The reader re-interns each step in its own tables and
//! encodes what it decoded again: the words must be the block's, or the
//! block is unknown (its codes are pessimistic at every importer).
//!
//! Obligations kept here: O10 (a block's contract means at the importer
//! what it meant at the writer: validated by re-encoding).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");

pub const magic: u32 = 0x324e574f;
pub const version: u32 = 20;
pub const Error = Ids.ChargeError || error{BadBlock};
const Step = Place.Step;

/// How the writer names a field rank, a top-level value and an origin, as
/// string indices of the block's table.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) u32,
    /// `(module, declaration)` as a qualified name.
    decl: *const fn (ctx: *anyopaque, md: [2]u32) u32,
};

/// The reader's inverse: a field name string to this module's rank, a
/// qualified name string to `(module, declaration)`.
pub const Remap = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, string: u32) ?u32,
    decl: *const fn (ctx: *anyopaque, string: u32) ?[2]u32,
};

/// A writer's node to its index in the node table (from 1).
const Index = std.AutoHashMapUnmanaged(Contract.Node, u32);

const Writer = struct {
    t: *const Contract.Table,
    slots: *const Slots.Table,
    places: *const Place.Table,
    names: Names,
    out: *std.ArrayList(u32),
    gpa: Allocator,

    fn word(w: *Writer, x: u32) Allocator.Error!void {
        try w.out.append(w.gpa, x);
    }

    fn rel(w: *Writer, r: Slots.Rel) Allocator.Error!void {
        try w.word(@intCast(w.slots.relWords(r).len));
        for (w.slots.relWords(r)) |wd| try w.step(wd);
    }

    /// One step as `(kind, a, b)`.
    fn step(w: *Writer, wd: u32) Allocator.Error!void {
        const s = Step.fromWord(wd);
        switch (s.kind) {
            .field => try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), w.names.field(w.names.ctx, s.payload), 0 }),
            .ctor_arg => {
                const ca = w.places.ctorArgOf(s);
                try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), ca[0], ca[1] });
            },
            else => try w.out.appendSlice(w.gpa, &.{ @backingInt(s.kind), s.payload, 0 }),
        }
    }

    fn cond(w: *Writer, c: Contract.StoredCond) Allocator.Error!void {
        try w.word(@intFromBool(c.no));
        const run = w.t.occsOf(c);
        try w.word(@intCast(run.len));
        for (run) |o| {
            try w.word(Contract.occParam(o) | (if (Contract.isApart(o)) @as(u32, 1 << 31) else 0) | (if (Contract.isDeep(o)) @as(u32, 1 << 30) else 0) | (if (Contract.isFed(o)) @as(u32, 1 << 29) else 0));
            try w.rel(Contract.occRel(o));
        }
    }

    fn effects(w: *Writer, r: Ids.Range) Allocator.Error!void {
        try w.word(r.len);
        for (w.t.effectsOf(r)) |e| {
            try w.word(e.j);
            try w.rel(e.slot);
            try w.word(@intFromBool(e.deep));
        }
    }

    /// The node table of a contract's trees (§3.6, version 18): every node
    /// its result, reads, writes and supplies' results reach, once, in
    /// post-order with each node's kids in the canonical order; `index`
    /// maps a node to its place in the table (from 1; 0 is the empty node).
    fn table(w: *Writer, roots: []const Contract.Node, index: *Index) Allocator.Error!void {
        var order: std.ArrayList(Contract.Node) = .empty;
        defer order.deinit(w.gpa);
        try w.t.postOrder(w.gpa, w.places, roots, &order);
        var ks: std.ArrayList([2]u32) = .empty;
        defer ks.deinit(w.gpa);
        try w.word(@intCast(order.items.len));
        for (order.items, 1..) |n, at| {
            try w.arrivals(w.t.trees.here(n));
            try w.arrivals(w.t.trees.open(n));
            try Forest.sortedKids(&w.t.trees, w.gpa, w.places, n, &ks);
            try w.word(@intCast(ks.items.len));
            for (ks.items) |k| {
                try w.step(k[0]);
                try w.word(nodeIndex(index, k[1]));
            }
            try index.put(w.gpa, n, @intCast(at));
        }
    }

    fn arrivals(w: *Writer, run: []const Contract.Arrival) Allocator.Error!void {
        try w.word(@intCast(run.len));
        for (run) |a| {
            try w.word(@backingInt(a.kind) | (@as(u32, @intFromBool(a.deep)) << 8));
            switch (a.kind) {
                .param, .cb, .lent => {
                    try w.word(a.j);
                    try w.rel(a.slot);
                },
                .shared => try w.word(w.names.decl(w.names.ctx, .{ a.j, a.slot })),
                .fresh, .top, .host => {},
            }
        }
    }

    fn nodeIndex(index: *const Index, n: Contract.Node) u32 {
        return if (n == 0) 0 else index.get(n).?;
    }

    fn contract(w: *Writer, c: Contract.Id) Allocator.Error!void {
        const h = w.t.head(c);
        try w.word(h.arity);
        try w.word(@as(u8, @bitCast(h.flags)));
        var roots: std.ArrayList(Contract.Node) = .empty;
        defer roots.deinit(w.gpa);
        try roots.append(w.gpa, h.res_root);
        for ([_]Ids.Range{ h.reads, h.writes }) |rr| for (w.t.readsOf(rr)) |x| try roots.append(w.gpa, x[1]);
        for (w.t.labelsOf(h.labels)) |l| for (w.t.suppliesOf(l.supplies)) |s| try roots.append(w.gpa, s.res_root);
        var index: Index = .empty;
        defer index.deinit(w.gpa);
        try w.table(roots.items, &index);
        try w.word(nodeIndex(&index, h.res_root));
        try w.cond(h.res_cond);
        for ([_]Ids.Range{ h.reads, h.writes }) |rr| {
            try w.word(rr.len);
            for (w.t.readsOf(rr)) |x| {
                try w.word(x[0]);
                try w.word(nodeIndex(&index, x[1]));
            }
        }
        try w.cond(h.req);
        try w.effects(h.escapes);
        try w.word(h.labels.len);
        for (w.t.labelsOf(h.labels)) |l| {
            try w.word(l.j);
            try w.rel(l.slot);
            try w.word(w.names.decl(w.names.ctx, .{ l.origin[0], l.origin[1] }));
            try w.word(l.origin[2]);
            try w.word(@backingInt(l.calls));
            try w.word(l.supplies.len);
            for (w.t.suppliesOf(l.supplies)) |s| {
                try w.word(s.k);
                try w.word(nodeIndex(&index, s.res_root));
                try w.effects(s.kept);
                try w.cond(s.cond);
            }
        }
    }
};

/// The words of `contracts` (in order), after the header.
pub fn write(gpa: Allocator, t: *const Contract.Table, slots: *const Slots.Table, places: *const Place.Table, contracts: []const Contract.Id, names: Names, out: *std.ArrayList(u32)) Allocator.Error!void {
    var w: Writer = .{ .t = t, .slots = slots, .places = places, .names = names, .out = out, .gpa = gpa };
    try w.word(magic);
    try w.word(version);
    try w.word(@intCast(contracts.len));
    for (contracts) |c| {
        const at = out.items.len;
        try w.word(0);
        try w.contract(c);
        out.items[at] = @intCast(out.items.len - at - 1);
    }
}

const Reader = struct {
    words: []const u32,
    at: usize = 0,
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    places: *Place.Table,
    slots: *Slots.Table,
    remap: Remap,
    /// Per string the block's table names: its index, for re-encoding.
    field_string: Ids.FixedDict(1) = .{},
    decl_string: Ids.FixedDict(2) = .{},

    fn next(r: *Reader) Error!u32 {
        if (r.at >= r.words.len) return error.BadBlock;
        r.at += 1;
        return r.words[r.at - 1];
    }

    fn rel(r: *Reader) Error!Slots.Rel {
        const out = try r.arena.alloc(u32, try r.count());
        for (out) |*o| o.* = try r.step();
        return r.slots.relOfWords(r.gpa, r.account, r.places, out);
    }

    /// One step `(kind, a, b)` as this module's step word.
    fn step(r: *Reader) Error!u32 {
        const kind = try r.next();
        const a = try r.next();
        const b = try r.next();
        if (kind > @backingInt(Place.StepKind.level)) return error.BadBlock;
        const k: Place.StepKind = @fromBackingInt(@intCast(kind));
        const s: Step = switch (k) {
            .field => blk: {
                const rank = r.remap.field(r.remap.ctx, a) orelse return error.BadBlock;
                (try r.field_string.getOrPut(r.gpa, .{rank})).value_ptr.* = a;
                break :blk try Step.field(r.account, rank);
            },
            .ctor_arg => try r.places.ctorStep(r.gpa, r.account, a, b),
            else => .{ .kind = k, .payload = @intCast(a & 0x0fff_ffff) },
        };
        return s.word();
    }

    fn decl(r: *Reader) Error![2]u32 {
        const s = try r.next();
        const md = r.remap.decl(r.remap.ctx, s) orelse return error.BadBlock;
        (try r.decl_string.getOrPut(r.gpa, md)).value_ptr.* = s;
        return md;
    }

    fn cond(r: *Reader) Error!Contract.Cond {
        const no = try r.next() != 0;
        const run = try r.arena.alloc(u64, try r.count());
        for (run) |*o| {
            const j = try r.next();
            o.* = Contract.occ(j & 0x1fff_ffff, try r.rel()) | (if (j >> 31 != 0) Contract.apart_bit else 0) | (if ((j >> 30) & 1 != 0) Contract.deep_bit else 0) | (if ((j >> 29) & 1 != 0) Contract.fed_bit else 0);
        }
        if (no) return .unprovable;
        return Contract.Cond.of(r.account, run);
    }

    fn effects(r: *Reader, out: *std.ArrayList(Contract.Effect)) Error!void {
        for (0..try r.count()) |_| {
            const j = try r.next();
            const s = try r.rel();
            const deep = try r.next() != 0;
            try out.append(r.arena, .{ .j = j, .slot = s, .deep = deep });
        }
    }

    /// A contract's node table (§3.6, version 18), each node re-interned in
    /// `t`'s trees (equal subtrees are one node here too): `out[i]` is the
    /// block's node `i` (0 the empty node). A kid names an earlier node.
    fn table(r: *Reader, t: *Contract.Table, out: *std.ArrayList(Contract.Node)) Error!void {
        try out.append(r.arena, 0);
        for (0..try r.count()) |_| {
            const plain = try r.arrivals();
            const open = try r.arrivals();
            const kids = try r.arena.alloc([2]u32, try r.count());
            for (kids) |*k| k.* = .{ try r.step(), try node(out.items, try r.next()) };
            try out.append(r.arena, try t.trees.node(r.gpa, plain, open, kids));
        }
    }

    /// A count, no more than the block's words.
    fn count(r: *Reader) Error!u32 {
        const n = try r.next();
        return if (n > r.words.len) error.BadBlock else n;
    }

    fn arrivals(r: *Reader) Error![]Contract.Arrival {
        const out = try r.arena.alloc(Contract.Arrival, try r.count());
        for (out) |*a| {
            const kw = try r.next();
            if ((kw & 0xff) > @backingInt(Contract.ArrivalKind.lent) or kw >> 9 != 0) return error.BadBlock;
            a.* = .{ .kind = @fromBackingInt(@intCast(kw & 0xff)), .deep = kw >> 8 != 0 };
            switch (a.kind) {
                .param, .cb, .lent => {
                    a.j = try r.next();
                    a.slot = try r.rel();
                },
                .shared => {
                    const md = try r.decl();
                    a.j = md[0];
                    a.slot = md[1];
                },
                .fresh, .top, .host => {},
            }
        }
        return out;
    }

    fn node(nodes: []const Contract.Node, i: u32) Error!Contract.Node {
        return if (i < nodes.len) nodes[i] else error.BadBlock;
    }

    fn contract(r: *Reader, t: *Contract.Table) Error!Contract.Id {
        var d: Contract.Draft = .{ .arity = try r.next() };
        d.flags = @bitCast(@as(u8, @truncate(try r.next())));
        var nodes: std.ArrayList(Contract.Node) = .empty;
        try r.table(t, &nodes);
        d.res.base = try node(nodes.items, try r.next());
        d.res_cond = try r.cond();
        for ([_]*std.ArrayList(Contract.Effect){ &d.reads, &d.writes }) |list| for (0..try r.count()) |_| {
            const j = try r.next();
            try list.append(r.arena, .{ .j = j, .slot = Slots.root, .node = try node(nodes.items, try r.next()) });
        };
        d.req = try r.cond();
        try r.effects(&d.escapes);
        for (0..try r.count()) |_| {
            const j = try r.next();
            const slot = try r.rel();
            const md = try r.decl();
            const off = try r.next();
            const calls = try r.next();
            if (calls > 2) return error.BadBlock;
            const li = try d.labelOf(r.arena, j, slot, .{ md[0], md[1], off });
            d.labels.items[li].calls = @fromBackingInt(@intCast(calls));
            for (0..try r.count()) |_| {
                const k = try r.next();
                const s = try d.labels.items[li].supplyOf(r.arena, k);
                s.res.base = try node(nodes.items, try r.next());
                try r.effects(&s.kept);
                s.cond = try r.cond();
            }
        }
        return t.commit(r.gpa, r.account, r.slots, &d);
    }

    fn fieldString(ctx: *anyopaque, rank: u32) u32 {
        const r: *Reader = @ptrCast(@alignCast(ctx));
        return r.field_string.get(.{rank}) orelse Ids.none_int;
    }
    fn declString(ctx: *anyopaque, md: [2]u32) u32 {
        const r: *Reader = @ptrCast(@alignCast(ctx));
        return r.decl_string.get(md) orelse Ids.none_int;
    }
};

/// Decode a block's contracts into `t`, each validated by re-encoding; the
/// contracts in the block's order.
pub fn read(gpa: Allocator, words: []const u32, t: *Contract.Table, slots: *Slots.Table, places: *Place.Table, account: *Ids.Account, remap: Remap, out: *std.ArrayList(Contract.Id)) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Reader = .{ .words = words, .gpa = gpa, .arena = arena_state.allocator(), .account = account, .places = places, .slots = slots, .remap = remap };
    defer r.field_string.deinit(gpa);
    defer r.decl_string.deinit(gpa);
    if (try r.next() != magic or try r.next() != version) return error.BadBlock;
    const n = try r.next();
    if (n > words.len) return error.BadBlock;
    try account.reserve(.class, @intCast(@max(1, words.len / 16)));
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(gpa);
    for (0..n) |_| {
        const len = try r.next();
        const start = r.at;
        if (start + len > words.len) return error.BadBlock;
        const c = try r.contract(t);
        if (r.at != start + len) return error.BadBlock;
        // The round trip: encoded again in this module's terms, the same words.
        again.clearRetainingCapacity();
        var w: Writer = .{ .t = t, .slots = slots, .places = places, .names = .{ .ctx = &r, .field = Reader.fieldString, .decl = Reader.declString }, .out = &again, .gpa = gpa };
        try w.contract(c);
        if (!std.mem.eql(u32, again.items, words[start..][0..len])) return error.BadBlock;
        try out.append(gpa, c);
    }
}
