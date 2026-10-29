//! L11: what a demand's line and diagnostic say (`docs/design/ownership-v2.md`
//! §6, R-6.1–R-6.7, R-7.15): the operation, the base as written, the
//! verdict, its cause and the detail naming the holder and its later use —
//! v1's texts (`src/own/Ownership.zig`'s `resolveRaw`), so a golden compares
//! v1's verdict lines with v2's. Nothing printed is an id: names, field
//! names, constructor names and positions.
//!
//! Obligations kept here: none (text).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Demands = @import("Demands.zig");
const Walk = @import("Walk.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");

const none = Ids.none_int;

pub const Position = Facts.Position;

/// How names and positions print, the caller's (§5: passed down).
pub const Names = struct {
    ctx: *anyopaque,
    interner: *const InternPool.Global,
    module_names: []const []const u8,
    birs: []const *const Bir,
    /// The field name of a text rank.
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
    /// A nominal head's constructor `ordinal`, and the type's own name.
    ctor: *const fn (ctx: *anyopaque, head: u32, ordinal: u32) []const u8,
    type_name: *const fn (ctx: *anyopaque, head: u32) []const u8,
    /// A nominal head as a block names it, `package·module·type` (§3.6).
    type_qualified: *const fn (ctx: *anyopaque, head: u32) []const u8,
    position: *const fn (ctx: *anyopaque, module: u32, token: u32) Position,

    pub fn declName(n: Names, module: u32, decl: u32) []const u8 {
        const bir = n.birs[module];
        return n.interner.slice(bir.symbol(bir.decls[decl].name));
    }
};

pub const Frame = struct {
    names: Names,
    module: u32,
    decl: Bir.Decl,
    places: *const Place.Table,
    cells: *const Cell.Table,
    /// `shared` index → `(module, decl)`.
    shared: []const [2]u32,
    /// The `(module, decl)` a value reference names.
    ctx: *anyopaque,
    decl_of: *const fn (ctx: *anyopaque, inst: u32) ?[2]u32,
    /// The `(module, constructor index)` a constructor reference names.
    ctor_of: *const fn (ctx: *anyopaque, inst: u32) ?[2]u32,
};

fn birOf(f: Frame) *const Bir {
    return f.names.birs[f.module];
}

fn localName(f: Frame, local: u32) []const u8 {
    const b = birOf(f);
    const sym = b.locals[f.decl.locals_start + local].name;
    if (sym == .none) return "_";
    return f.names.interner.slice(b.symbol(sym));
}

fn tag(f: Frame, i: u32) Bir.Inst.Tag {
    return birOf(f).instTag(@fromBackingInt(i));
}

fn data(f: Frame, i: u32) Bir.Inst.Data {
    return birOf(f).instData(@fromBackingInt(i));
}

/// A value reference's `M.v`.
pub fn refName(f: Frame, a: Allocator, i: u32) Allocator.Error!?[]const u8 {
    const md = f.decl_of(f.ctx, i) orelse return null;
    return try std.fmt.allocPrint(a, "{s}.{s}", .{ f.names.module_names[md[0]], f.names.declName(md[0], md[1]) });
}

/// The base as written (R-7.15's `base`): a local and its field path, or
/// what made it.
fn baseText(f: Frame, a: Allocator, top: u32) Allocator.Error![]const u8 {
    // A chain of `.field` and `.0` reads: down to its base, then its
    // suffixes back up, as a loop (#1143: expressions nest as deep as the
    // source).
    var chain: std.ArrayList(u32) = .empty;
    defer chain.deinit(a);
    var at = top;
    while (tag(f, at) == .field_access or tag(f, at) == .tuple_index) : (at = data(f, at).lhs) try chain.append(a, at);
    var text = try baseOne(f, a, at);
    var k = chain.items.len;
    while (k > 0) {
        k -= 1;
        const i = chain.items[k];
        const d = data(f, i);
        text = if (tag(f, i) == .field_access)
            try std.fmt.allocPrint(a, "{s}.{s}", .{ text, f.names.interner.slice(birOf(f).symbol(@fromBackingInt(d.rhs))) })
        else
            try std.fmt.allocPrint(a, "{s}.{d}", .{ text, d.rhs });
    }
    return text;
}

/// The base as written, and below it the path a writer call writes.
fn writtenText(f: Frame, a: Allocator, d: Demands.Demand) Allocator.Error![]const u8 {
    const base = try baseText(f, a, d.base_inst);
    if (d.write_path == .none) return base;
    var buf: std.Io.Writer.Allocating = .init(a);
    buf.writer.writeAll(base) catch return error.OutOfMemory;
    pathText(f, a, &buf.writer, d.write_path) catch return error.OutOfMemory;
    return buf.written();
}
fn baseOne(f: Frame, a: Allocator, i: u32) Allocator.Error![]const u8 {
    const d = data(f, i);
    return switch (tag(f, i)) {
        .local => localName(f, d.lhs),
        .field_access, .tuple_index => unreachable,
        .list => "<literal>",
        .record => "<record>",
        .top, .ext_value => (try refName(f, a, i)) orelse "<expression>",
        .call => if (f.ctor_of(f.ctx, d.lhs)) |c| try std.fmt.allocPrint(a, "<{s} …>", .{f.names.interner.slice(f.names.birs[c[0]].symbol(f.names.birs[c[0]].ctors[c[1]].name))}) else if (try refName(f, a, d.lhs)) |n| try std.fmt.allocPrint(a, "<call {s}>", .{n}) else "<call>",
        .method_call => if (try refName(f, a, i)) |n| try std.fmt.allocPrint(a, "<call {s}>", .{n}) else "<call>",
        else => "<expression>",
    };
}

/// A path under a local's root, in source terms: `.field`, `.0`, `[*]`,
/// `#Ctor.i`, `⟨Type⟩` for the levels below a recursive value, `◆`.
fn pathText(f: Frame, a: Allocator, w: *std.Io.Writer, root: Ids.PathId) (Allocator.Error || std.Io.Writer.Error)!void {
    // The way up, then printed down: a path is as long as the source is
    // deep, so an explicit list, never a native frame per step (#1138).
    const places = f.places;
    var way: std.ArrayList(Ids.PathId) = .empty;
    defer way.deinit(a);
    var at = root;
    while (at != .none and places.pathParent(at) != .none) : (at = places.pathParent(at)) try way.append(a, at);
    var i = way.items.len;
    while (i > 0) {
        i -= 1;
        try stepText(f, w, way.items[i]);
    }
}

fn stepText(f: Frame, w: *std.Io.Writer, p: Ids.PathId) std.Io.Writer.Error!void {
    const places = f.places;
    const parent = places.pathParent(p);
    const s = places.pathStep(p);
    switch (s.kind) {
        .field => try w.print(".{s}", .{f.names.field(f.names.ctx, s.payload)}),
        .index => try w.print(".{d}", .{s.payload}),
        .elem => try w.writeAll("[*]"),
        .ctor_arg => {
            const pair = places.ctorArgOf(s);
            try w.print("#{s}.{d}", .{ f.names.ctor(f.names.ctx, places.head(places.pathPlace(parent)), pair[0]), pair[1] });
        },
        .level => try w.print("⟨{s}⟩", .{f.names.type_name(f.names.ctx, places.head(places.pathPlace(p)))}),
        .contents => try w.writeAll("◆"),
        .env => try w.writeAll("◇"),
        .slot => try w.print("⟨{d}⟩", .{s.payload}),
    }
}

/// The line of one resolved demand.
pub fn line(f: Frame, a: Allocator, l: Walk.Line, op_name: []const u8) Allocator.Error!Facts.Line {
    const d = l.demand;
    const o = l.outcome;
    const op: []const u8 = switch (d.kind) {
        .construction => "construction",
        .append => "++",
        else => op_name,
    };
    var detail: []const u8 = "";
    if (o.verdict == .refused) {
        var buf: std.Io.Writer.Allocating = .init(a);
        const w = &buf.writer;
        const up = if (l.use_token != none) f.names.position(f.names.ctx, f.module, l.use_token) else Position{ .line = 0, .col = 0 };
        (switch (o.cause) {
            .later_use, .alias, .element => blk: {
                const h = l.holder.?;
                w.writeAll(localName(f, h.who)) catch return error.OutOfMemory;
                // A hold at some level below the holder (a path ending in `⟲`)
                // names the holder: it holds every level (v1's text).
                var hp = o.holder_path;
                if (hp != .none and f.places.pathParent(hp) != .none and f.places.pathStep(hp).kind == .level) hp = f.places.pathParent(hp);
                if (o.cause != .later_use) pathText(f, a, w, hp) catch return error.OutOfMemory;
                break :blk if (o.cause == .later_use)
                    w.print(" is read again at {d}:{d}", .{ up.line, up.col })
                else
                    w.print(" holds it and is read at {d}:{d}", .{ up.line, up.col });
            },
            .held_operand => blk: {
                const pp = f.names.position(f.names.ctx, f.module, l.holder.?.token);
                break :blk w.print("the value at {d}:{d}, evaluated before it, holds it until its consumer runs", .{ pp.line, pp.col });
            },
            .disjoint => w.writeAll("another operand of the same operation reaches it"),
            // A demand relies only on its splits' κ (a callee's `xreq` is the frame's).
            .exclusive => w.writeAll("the elements of the list it was taken from may share one list"),
            .escaped => w.writeAll("it was given to JavaScript, or kept by a callee"),
            .unknown => w.writeAll("it came from a call of a function the checker cannot identify, which may return a list something else holds"),
            .top_level => blk: {
                const md = sharedOf(f, o.cell);
                break :blk if (md) |x| w.print("{s}.{s} is a top-level value", .{ f.names.module_names[x[0]], f.names.declName(x[0], x[1]) }) else w.writeAll("it is a top-level value");
            },
            else => {},
        }) catch return error.OutOfMemory;
        detail = buf.written();
    }
    return .{
        .position = f.names.position(f.names.ctx, f.module, d.token),
        .token = d.token,
        .op = op,
        .base = try writtenText(f, a, d),
        .refused = o.verdict == .refused,
        .accepted = o.accepted,
        .cause = o.cause,
        .approx = o.verdict == .refused and o.exactness == .approximate,
        .detail = detail,
    };
}

fn sharedOf(f: Frame, c: Ids.CellId) ?[2]u32 {
    if (c == .none) return null;
    const idx = f.cells.get(c).a;
    return if (idx < f.shared.len) f.shared[idx] else null;
}
