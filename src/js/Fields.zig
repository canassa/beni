//! `backend.md` §9, *Item 4, taken up*: under `--release`, a beni record's
//! fields are given short spellings and a type no JavaScript sees is given
//! integer constructor tags.
//!
//! Two halves, at two moments of a build:
//!
//!   - **The boundary**, closed once after elimination and before lowering
//!     (`close`): every field name and every named type JavaScript can see —
//!     what a live `foreign`'s annotation writes, what a live declaration's
//!     `Js.from`/`Js.to` was instantiated at (the checker's rows,
//!     checker-v2.md §28), and the bodies of every named type either reaches,
//!     transitively. A type variable is opaque (`boundary.md` §4, *What
//!     JavaScript may read of a beni value*). Its answer about TYPES is what
//!     `Lower` reads to write a tag; its answer about FIELDS is half of what
//!     pins a name.
//!   - **The spellings**, assigned after the optimiser on the calling thread
//!     (`assign`): one short spelling per field name that is neither pinned
//!     by the boundary nor written as a non-field property anywhere in the
//!     build, ranked by how often the build names it, ties by text. Scheme (i)
//!     of the section: no two names share a spelling, so no two fields on one
//!     object can.
//!
//! Everything here is keyed by TEXT or by input-derived indices and walked
//! in module order, so `--jobs` cannot move a byte (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Types = @import("../check/Types.zig");
const Reach = @import("Reach.zig");
const Rename = @import("Rename.zig");

const TypeId = Types.TypeId;

/// A field's short spelling, by the field's source text. A field with no
/// entry is printed as its text.
pub const Table = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The fields that keep their text. Read by the printer's self-check
    /// alone: every field it prints is in one of the two.
    kept: std.StringHashMapUnmanaged(void) = .empty,

    pub fn get(t: *const Table, text: []const u8) ?[]const u8 {
        return t.map.get(text);
    }

    /// Whether `text` is a field this build named when the table was made.
    pub fn knows(t: *const Table, text: []const u8) bool {
        return t.map.contains(text) or t.kept.contains(text);
    }
};

/// What JavaScript sees, for the whole build.
pub const Boundary = struct {
    /// The field texts it reads or writes by name.
    pinned: std.StringHashMapUnmanaged(void) = .empty,
    /// Per `TypeId`: whether a value of the type gets integer constructor
    /// tags. Empty when nothing does.
    integer_tags: std.DynamicBitSetUnmanaged = .{},

    /// Whether constructor tags of `id` are integers.
    pub fn integerTags(b: *const Boundary, id: TypeId) bool {
        return id != .none and id.int() < b.integer_tags.bit_length and b.integer_tags.isSet(id.int());
    }
};

pub const Input = struct {
    arena: Allocator,
    graph: *const Graph,
    /// One per module, by `Graph.Index`.
    birs: []const *const Bir,
    dispatch: []const *const Dispatch,
    live: *const Reach.Result,
    types: *const Types,
    interner: *const InternPool.Global,
    /// Per module, by `Graph.Index`, one bit per declaration: specialisation
    /// left none of its bodies in the output, nor a copy of one, so what it
    /// casts JavaScript no longer sees (`backend.md` §9, *Field names are
    /// decided after specialisation*). Empty before specialisation.
    gone: []const std.DynamicBitSetUnmanaged = &.{},

    fn alive(in: Input, m: Graph.Index, decl: usize) bool {
        if (m.int() >= in.gone.len) return true;
        const bits = in.gone[m.int()];
        return decl >= bits.bit_length or !bits.isSet(decl);
    }
};

/// Close the boundary (see the header). Null when nothing may be renamed
/// at all: a reflective order over a type whose `compare` takes no
/// evidence for its parameters (`orderedReflectively`).
pub fn close(in: Input) Allocator.Error!?Boundary {
    var b: Boundary = .{};
    const n = in.types.entries.len;
    var observed = try std.DynamicBitSetUnmanaged.initEmpty(in.arena, n);
    var walk: Walk = .{ .in = in, .boundary = &b, .observed = &observed };
    if (orderedReflectively(in)) {
        if (!try walk.comparedTypes()) return null;
    }
    // The seeds: what a live declaration says or was solved to say.
    for (in.birs, 0..) |bir, mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(mi))));
        for (bir.decls, 0..) |d, i| {
            if (!in.live.decl(m, i) or !in.alive(m, i)) continue;
            if (d.kind == .foreign_value) if (d.annotation.unwrap()) |annotation| try walk.typeAt(m, bir, annotation);
        }
        for (in.dispatch[mi].boundary) |row| {
            // Either body: a declaration that may suspend may be written
            // only as its suspendable twin, which casts what it casts.
            if (!in.live.decl(m, row.decl) and !in.live.twin(m, row.decl)) continue;
            if (!in.alive(m, row.decl)) continue;
            switch (row.kind) {
                .field => try walk.pin(in.interner.slice(@fromBackingInt(@intCast(row.value)))),
                .type => try walk.observe(@fromBackingInt(@intCast(row.value))),
            }
        }
    }
    // The bodies of what was reached, until nothing new is.
    while (walk.queue.pop()) |id| {
        const e = in.types.entries[id.int()];
        if (e.schema_endpoint or e.module.int() >= in.birs.len) continue;
        const bir = in.birs[e.module.int()];
        const d = bir.decl(e.decl);
        switch (e.kind) {
            .alias => if (d.annotation.unwrap()) |body| try walk.typeAt(e.module, bir, body),
            .adt => for (bir.declCtors(d)) |c| {
                for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| {
                    try walk.typeAt(e.module, bir, arg);
                }
            },
            .foreign => {},
        }
    }
    // Integer tags: a `type` nothing above reached, other than `Bool`, whose
    // values are `true`/`false`, and `Order`, whose tags every derived
    // `compare` and several siblings write.
    b.integer_tags = try std.DynamicBitSetUnmanaged.initEmpty(in.arena, n);
    for (in.types.entries, 0..) |e, i| {
        if (e.kind != .adt or e.schema_endpoint or observed.isSet(i)) continue;
        const id: TypeId = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        if (id == in.types.well_known.bool or id == in.types.well_known.order) continue;
        b.integer_tags.set(i);
    }
    return b;
}

/// Whether a live `foreign` takes a value of a type variable that carries
/// `compare`: its sibling holds a value of a type it cannot know and may
/// order it by what the value holds — field names and tags. `Hosted.key`
/// is the one today (`boundary.md` §4, §9.8.3): a key is any comparable
/// value, and the order of keys decides which subscription or command
/// starts first. `List.compare`, whose variable is under a `List`, hands
/// every element to the evidence and is not one.
fn orderedReflectively(in: Input) bool {
    for (in.birs, 0..) |bir, mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(mi))));
        for (bir.decls, 0..) |d, i| {
            if (d.kind != .foreign_value or !in.live.decl(m, i)) continue;
            const annotation = d.annotation.unwrap() orelse continue;
            if (bir.instTag(annotation) != .type_fn) continue;
            const params = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(annotation).lhs))), Bir.Inst.Index);
            var at: u32 = @backingInt(d.where_start);
            while (at < @backingInt(d.where_end)) : (at += Bir.extraLen(Bir.WhereConstraint)) {
                const w = bir.extraData(@fromBackingInt(@intCast(at)), Bir.WhereConstraint);
                if (!std.mem.eql(u8, in.interner.slice(bir.symbol(w.method)), "compare")) continue;
                for (params) |param| {
                    if (bir.instTag(param) != .type_var) continue;
                    if (bir.symbol(@fromBackingInt(@intCast(bir.instData(param).lhs))) == bir.symbol(w.variable)) return true;
                }
            }
        }
    }
    return false;
}

const Walk = struct {
    in: Input,
    boundary: *Boundary,
    observed: *std.DynamicBitSetUnmanaged,
    queue: std.ArrayList(TypeId) = .empty,
    stack: std.ArrayList(Bir.Inst.Index) = .empty,

    /// Every type the build orders, into the boundary: a key's type is any
    /// type with `compare`, so a build in which keys are ordered by what
    /// they hold keeps every comparable type's names and tags. A live
    /// derived `compare` names its type or its record's fields, and a live
    /// `pub compare` its parameter types. False when a `pub compare` of a
    /// type with parameters takes no evidence for them: what the
    /// parameters hold is then compared by nothing the build ships, and
    /// cannot be found — the caller keeps every name.
    fn comparedTypes(w: *Walk) Allocator.Error!bool {
        const in = w.in;
        for (in.birs, in.dispatch, 0..) |bir, table, mi| {
            const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(mi))));
            for (table.derived, 0..) |row, i| {
                if (row.kind != .compare or !in.live.derivedRow(m, i)) continue;
                switch (row.shape) {
                    .nominal => |id| try w.observe(id),
                    .record => |r| for (table.shapeNames(r)) |field| try w.pin(in.interner.slice(field)),
                    .tuple, .unit => {},
                }
            }
            for (bir.decls, 0..) |d, i| {
                if (!d.kind.isValue() or !d.is_pub or !in.live.decl(m, i)) continue;
                if (!std.mem.eql(u8, in.interner.slice(bir.symbol(d.name)), "compare")) continue;
                const annotation = d.annotation.unwrap() orelse continue;
                try w.typeAt(m, bir, annotation);
                if (d.where_start != d.where_end) continue;
                if (bir.instTag(annotation) != .type_fn) continue;
                const params = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(annotation).lhs))), Bir.Inst.Index);
                if (params.len == 0 or bir.instTag(params[0]) != .type_app) continue;
                return false;
            }
        }
        return true;
    }

    /// Copied: the session's pool may grow before the text is read again
    /// (whole-program specialisation interns names), moving its bytes.
    fn pin(w: *Walk, text: []const u8) Allocator.Error!void {
        const gop = try w.boundary.pinned.getOrPut(w.in.arena, text);
        if (!gop.found_existing) gop.key_ptr.* = try w.in.arena.dupe(u8, text);
    }

    fn observe(w: *Walk, id: TypeId) Allocator.Error!void {
        if (id == .none or id.int() >= w.observed.bit_length or w.observed.isSet(id.int())) return;
        w.observed.set(id.int());
        try w.queue.append(w.in.arena, id);
    }

    /// A written type of module `m`: every record field it names and every
    /// named type it reaches. A variable is opaque.
    fn typeAt(w: *Walk, m: Graph.Index, bir: *const Bir, root: Bir.Inst.Index) Allocator.Error!void {
        const arena = w.in.arena;
        w.stack.clearRetainingCapacity();
        try w.stack.append(arena, root);
        // A well-formed written type is a tree: the budget is a backstop
        // for a poisoned one, stated in the input's size.
        var budget: usize = bir.insts.len + 16;
        while (w.stack.pop()) |inst| {
            if (budget == 0) return;
            budget -= 1;
            if (inst.int() >= bir.insts.len) continue;
            const tag = bir.instTag(inst);
            const data = bir.instData(inst);
            switch (tag) {
                .type_top, .ext_type, .schema_type_top, .ext_schema_type => try w.observe(w.in.types.headId(m, tag, data)),
                .type_app => {
                    const head: Bir.Inst.Index = @fromBackingInt(@intCast(data.lhs));
                    try w.observe(w.in.types.headId(m, bir.instTag(head), bir.instData(head)));
                    try w.stack.appendSlice(arena, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index));
                },
                .type_fn => {
                    try w.stack.appendSlice(arena, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.lhs))), Bir.Inst.Index));
                    try w.stack.append(arena, @fromBackingInt(@intCast(data.rhs)));
                },
                .type_tuple => try w.stack.appendSlice(arena, bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)),
                .type_record => for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| {
                    try w.pin(w.in.interner.slice(bir.symbol(f.name)));
                    try w.stack.append(arena, f.value);
                },
                .type_record_ext => for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field)) |f| {
                    try w.pin(w.in.interner.slice(bir.symbol(f.name)));
                    try w.stack.append(arena, f.value);
                },
                else => {},
            }
        }
    }
};

/// One field text and how often the build names it.
pub const Count = struct { text: []const u8, uses: u32 };

/// The spellings (see the header). `counts` holds every field text the
/// build names, each once; `pinned` the boundary's; `plain` every property
/// text the build writes that is not a field's. A field in either set keeps
/// its text. No spelling holds a `$`, and none is the text of a field that
/// keeps it, because the two could be keys of one record. A spelling MAY be
/// a plain property's text: a record holds nothing but its fields, and
/// nothing that reads a plain property by name is handed a record whose
/// fields it does not name (`boundary.md` §4).
pub fn assign(
    arena: Allocator,
    counts: []Count,
    pinned: *const std.StringHashMapUnmanaged(void),
    plain: *const std.StringHashMapUnmanaged(void),
) Allocator.Error!Table {
    const Order = struct {
        fn lessThan(_: void, a: Count, b: Count) bool {
            if (a.uses != b.uses) return a.uses > b.uses;
            return std.mem.lessThan(u8, a.text, b.text);
        }
    };
    std.mem.sort(Count, counts, {}, Order.lessThan);
    var table: Table = .{};
    const kept = &table.kept;
    for (counts) |c| {
        if (pinned.contains(c.text) or plain.contains(c.text)) try kept.put(arena, c.text, {});
    }
    var ordinal: u32 = 0;
    for (counts) |c| {
        if (kept.contains(c.text)) continue;
        while (true) : (ordinal += 1) {
            var buf: [8]u8 = undefined;
            const spelled = Rename.spell(ordinal, &buf);
            if (std.mem.indexOfScalar(u8, spelled, '$') != null) continue;
            if (kept.contains(spelled)) continue;
            try table.map.put(arena, c.text, try arena.dupe(u8, spelled));
            ordinal += 1;
            break;
        }
    }
    return table;
}

test "assign ranks by use, keeps pinned and plain-named fields, and spells around what is kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var counts = [_]Count{
        .{ .text = "label", .uses = 3 },
        .{ .text = "id", .uses = 7 },
        .{ .text = "node", .uses = 9 },
        .{ .text = "rows", .uses = 3 },
        .{ .text = "b", .uses = 1 },
    };
    var pinned: std.StringHashMapUnmanaged(void) = .empty;
    try pinned.put(arena, "node", {});
    var plain: std.StringHashMapUnmanaged(void) = .empty;
    // A plain `a` keeps no field from being spelled `a`; a field named `b`
    // that is also a plain property keeps its text, so no field takes it.
    try plain.put(arena, "a", {});
    try plain.put(arena, "b", {});
    const t = try assign(arena, &counts, &pinned, &plain);
    try std.testing.expectEqual(@as(?[]const u8, null), t.get("node"));
    try std.testing.expectEqual(@as(?[]const u8, null), t.get("b"));
    try std.testing.expectEqualStrings("a", t.get("id").?);
    try std.testing.expectEqualStrings("c", t.get("label").?);
    try std.testing.expectEqualStrings("d", t.get("rows").?);
}
