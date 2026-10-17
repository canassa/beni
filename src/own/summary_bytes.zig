//! A module's ownership summaries as bytes: the *summary block*
//! (`docs/design/ownership-checker.md` §28.4).
//!
//! A build on an in-place platform reads the summaries of every module it
//! did not walk — core and the platforms from the checked core, a project's
//! module from its cache entry — from this block, so the block names nothing
//! by a session's id:
//!
//! - a **module** by its package and dotted name, through the table at the
//!   block's head;
//! - a **declaration** by its index in its module's BIR, a **constructor** by
//!   its module and its index in that module's constructor table (the
//!   BIR's constructors, then its tagged schemas', `Ownership.schemaCtorIndex`) — both
//!   functions of the module's source, which the module's key covers;
//! - a **path** step by step, a field by its name;
//! - every other number (a parameter, a fresh number, a lambda's local) as
//!   the summary holds it: none is a session's id.
//!
//! ```
//! "BENIOWN\x00"      8       magic
//! version: u32               `version`
//! modules: u32, then per module: package u8, name (u32 length, bytes)
//! strings: u32, then per string: u32 length, bytes        field names
//! paths: u32, then per path: steps u8, then per step: kind u8 and
//!        field: string index u32 · tuple: index u32 · ctor: module u32,
//!        constructor u32, argument u32 · elem, env, any: nothing
//! decls: u32, then per declaration: index u32, flags u8 (1: a summary
//!        follows; 2: a value whose type may hold a list), the summary
//! ```
//!
//! A summary is its scalars, then each component's entries. Sets — `uses`,
//! `res`, `supply`, `funs`, `xreq` and a condition's atoms — are written in
//! a canonical order that compares paths and modules by their table index,
//! and both tables are sorted by content, so **the bytes are a function of
//! the summaries alone**, whatever ids the session that computed them
//! assigned. Lists whose order means something — the function slots and the
//! carried lambdas, which a provenance names by index, and a carried
//! lambda's bindings — keep theirs.
//!
//! Little-endian, read with bounds checks: a block that does not read is
//! `error.Bad`, which the pass treats as no block — the module is then
//! walked if it can be, and is otherwise a callee with no summary, never a
//! wrong one (§16.4's last paragraph).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ownership = @import("Ownership.zig");
const SourceStore = @import("../SourceStore.zig");

const Summary = Ownership.Summary;
const Prov = Ownership.Prov;
const XAtom = Ownership.XAtom;
const XSum = Ownership.XSum;
const ResEntry = Ownership.ResEntry;
const SupplyEntry = Ownership.SupplyEntry;
const UseEntry = Ownership.UseEntry;
const FunFacts = Ownership.FunFacts;
const Carried = Ownership.Carried;
const StepKind = Ownership.StepKind;

pub const magic = "BENIOWN\x00";

/// Bumped with the rule set (thesis §8.5): a block of another version is
/// absent, never misread. In this PR: 5 transferred private initializers,
/// 6 excluded evidence-driven values, 7 retained entry environments, and
/// 8 preserves unknown/root entry paths while excluding only known init fields.
/// 9 reads `need` through taken elements (§16.4 item 5, amended 2026-10-15).
/// 10 names a tagged schema's constructors after the BIR's own.
/// 11 gives a schema value its two analysis slots, `⟨decoded⟩` and
/// `⟨encoded⟩` (§30.10).
/// 12 drops the coarsened flag and carries a limit's measure (§16.7).
/// 13 names a carried lambda by where it is made, so a fixpoint over the
/// walk's cells settles, and a fixpoint that does not is the `fixpoint` limit
/// (§20.4, amended 2026-10-16).
/// 14 records whether a function parameter's `need` comes only from a send
/// (§23.5, amended 2026-10-17).
/// 15 writes a constructor step's field as a u32, so a field past 63 is
/// named exactly (issue #289; it was a byte, and a field past 63 refused).
pub const version: u32 = 15;

pub const Error = error{Bad} || Allocator.Error;

/// One declaration's row of a block, as `write` takes it.
pub const Row = struct {
    decl: u32,
    sum: ?*const Summary,
    /// A value with no parameters whose type may hold a list (§23.6).
    holds_list: bool = false,
};

/// What `read` gives: per declaration of the module, its summary, and
/// whether it is a value that may hold a list.
pub const Block = struct {
    sums: []?Summary,
    holds_list: []bool,
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

const Writer = struct {
    o: *Ownership,
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Path id → index in the sorted table.
    path_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Module index → index in the sorted table.
    module_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Field symbol → index in the sorted table.
    string_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    fn int(w: *Writer, v: u32) Allocator.Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.out.appendSlice(w.gpa, &b);
    }

    fn byte(w: *Writer, v: u8) Allocator.Error!void {
        try w.out.append(w.gpa, v);
    }

    fn text(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.int(@intCast(s.len));
        try w.out.appendSlice(w.gpa, s);
    }
};

/// The block of module `m`: `rows` in declaration order. The caller owns
/// the bytes.
pub fn write(o: *Ownership, gpa: Allocator, rows: []const Row) Allocator.Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w: Writer = .{ .o = o, .gpa = gpa };
    errdefer w.out.deinit(gpa);

    // Everything the summaries name, first: paths, and through them and the
    // provenances, modules and field names.
    var paths: std.ArrayList(u32) = .empty;
    var modules: std.ArrayList(u32) = .empty;
    var strings: std.ArrayList(u32) = .empty;
    var seen_path: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var seen_module: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var seen_string: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const Collect = struct {
        o: *Ownership,
        arena: Allocator,
        paths: *std.ArrayList(u32),
        modules: *std.ArrayList(u32),
        strings: *std.ArrayList(u32),
        seen_path: *std.AutoHashMapUnmanaged(u32, void),
        seen_module: *std.AutoHashMapUnmanaged(u32, void),
        seen_string: *std.AutoHashMapUnmanaged(u32, void),

        fn path(c: *@This(), p: u32) Allocator.Error!void {
            if ((try c.seen_path.getOrPut(c.arena, p)).found_existing) return;
            try c.paths.append(c.arena, p);
            var buf: [Ownership.k_limit + 1]Ownership.Step = undefined;
            for (c.o.steps(p, &buf)) |s| switch (s.kind) {
                .field => if (!(try c.seen_string.getOrPut(c.arena, s.arg)).found_existing) try c.strings.append(c.arena, s.arg),
                .ctor => try c.module(c.o.ctorKey(c.o.stepCtor(s.arg)).module),
                else => {},
            };
        }

        fn module(c: *@This(), m: u32) Allocator.Error!void {
            if ((try c.seen_module.getOrPut(c.arena, m)).found_existing) return;
            try c.modules.append(c.arena, m);
        }

        fn prov(c: *@This(), p: Prov) Allocator.Error!void {
            try c.path(p.path);
            if (p.kind == .shared) try c.module(p.a);
        }

        fn xsum(c: *@This(), x: XSum) Allocator.Error!void {
            for (x.atoms) |a| {
                try c.prov(a.a);
                try c.prov(a.b);
            }
        }

        fn res(c: *@This(), r: ResEntry) Allocator.Error!void {
            try c.path(r.path);
            try c.prov(r.prov);
            try c.xsum(r.xc);
            try c.xsum(r.sc);
        }

        fn summary(c: *@This(), s: *const Summary) Allocator.Error!void {
            for (s.uses) |u| try c.path(u.path);
            for (s.res) |r| try c.res(r);
            for (s.supply) |e| {
                try c.path(e.path);
                try c.prov(e.prov);
                try c.xsum(e.xc);
            }
            for (s.xreq) |a| {
                try c.prov(a.a);
                try c.prov(a.b);
            }
            for (s.slots) |sl| try c.path(sl[1]);
            for (s.klasses) |k| {
                try c.summary(k.sum);
                for (k.binds) |b| {
                    try c.path(b.path);
                    for (b.provs) |r| try c.res(r);
                }
            }
        }
    };
    var collect: Collect = .{
        .o = o,
        .arena = arena,
        .paths = &paths,
        .modules = &modules,
        .strings = &strings,
        .seen_path = &seen_path,
        .seen_module = &seen_module,
        .seen_string = &seen_string,
    };
    try collect.path(Ownership.eps);
    for (rows) |r| if (r.sum) |s| try collect.summary(s);

    // The tables, sorted by content.
    const SortModules = struct {
        o: *const Ownership,
        fn less(cx: @This(), x: u32, y: u32) bool {
            const px = cx.o.in.packages[x];
            const py = cx.o.in.packages[y];
            if (px != py) return @backingInt(px) < @backingInt(py);
            return std.mem.lessThan(u8, cx.o.in.module_names[x], cx.o.in.module_names[y]);
        }
    };
    std.mem.sort(u32, modules.items, SortModules{ .o = o }, SortModules.less);
    for (modules.items, 0..) |m, i| try w.module_index.put(arena, m, @intCast(i));
    const SortStrings = struct {
        o: *const Ownership,
        fn less(cx: @This(), x: u32, y: u32) bool {
            return std.mem.lessThan(u8, cx.o.in.interner.slice(@fromBackingInt(x)), cx.o.in.interner.slice(@fromBackingInt(y)));
        }
    };
    std.mem.sort(u32, strings.items, SortStrings{ .o = o }, SortStrings.less);
    for (strings.items, 0..) |s, i| try w.string_index.put(arena, s, @intCast(i));
    // A path's key is its steps' keys, so ε (no steps) sorts first.
    const keys = try arena.alloc([]const u8, paths.items.len);
    var key_of: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    for (paths.items, keys) |p, *k| {
        k.* = try pathKey(o, arena, &w, p);
        try key_of.put(arena, p, k.*);
    }
    const SortPaths = struct {
        key_of: *const std.AutoHashMapUnmanaged(u32, []const u8),
        fn less(cx: @This(), x: u32, y: u32) bool {
            return std.mem.lessThan(u8, cx.key_of.get(x).?, cx.key_of.get(y).?);
        }
    };
    std.mem.sort(u32, paths.items, SortPaths{ .key_of = &key_of }, SortPaths.less);
    for (paths.items, 0..) |p, i| try w.path_index.put(arena, p, @intCast(i));

    try w.out.appendSlice(gpa, magic);
    try w.int(version);
    try w.int(@intCast(modules.items.len));
    for (modules.items) |m| {
        try w.byte(@backingInt(o.in.packages[m]));
        try w.text(o.in.module_names[m]);
    }
    try w.int(@intCast(strings.items.len));
    for (strings.items) |s| try w.text(o.in.interner.slice(@fromBackingInt(s)));
    try w.int(@intCast(paths.items.len));
    for (paths.items) |p| try w.out.appendSlice(gpa, key_of.get(p).?);

    var count: u32 = 0;
    for (rows) |r| {
        if (r.sum != null or r.holds_list) count += 1;
    }
    try w.int(count);
    for (rows) |r| {
        if (r.sum == null and !r.holds_list) continue;
        try w.int(r.decl);
        try w.byte(@as(u8, if (r.sum != null) 1 else 0) | @as(u8, if (r.holds_list) 2 else 0));
        if (r.sum) |s| try writeSummary(&w, arena, s);
    }
    return w.out.toOwnedSlice(gpa);
}

/// A path's bytes in the table: its steps, each named by table indices.
fn pathKey(o: *Ownership, arena: Allocator, w: *Writer, p: u32) Allocator.Error![]const u8 {
    var buf: [Ownership.k_limit + 1]Ownership.Step = undefined;
    const s = o.steps(p, &buf);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, @intCast(s.len));
    for (s) |st| {
        try out.append(arena, @backingInt(st.kind));
        switch (st.kind) {
            .field => try appendInt(arena, &out, w.string_index.get(st.arg).?),
            .tuple => try appendInt(arena, &out, st.arg),
            .ctor => {
                const key = o.ctorKey(o.stepCtor(st.arg));
                try appendInt(arena, &out, w.module_index.get(key.module).?);
                try appendInt(arena, &out, key.index);
                try appendInt(arena, &out, o.stepField(st.arg));
            },
            .elem, .env, .any, .markup_render, .markup_event, .schema_decoded, .schema_encoded => {},
        }
    }
    return out.items;
}

fn appendInt(a: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

/// A provenance as five numbers in the block's vocabulary, for ordering.
const ProvKey = struct {
    kind: u8,
    a: u32,
    b: u32,
    path: u32,
    taken: bool,

    fn less(x: ProvKey, y: ProvKey) bool {
        if (x.kind != y.kind) return x.kind < y.kind;
        if (x.a != y.a) return x.a < y.a;
        if (x.b != y.b) return x.b < y.b;
        if (x.path != y.path) return x.path < y.path;
        return @intFromBool(x.taken) < @intFromBool(y.taken);
    }
};

fn provKey(w: *const Writer, p: Prov) ProvKey {
    return .{
        .kind = @backingInt(p.kind),
        .a = if (p.kind == .shared) w.module_index.get(p.a).? else p.a,
        .b = p.b,
        .path = w.path_index.get(p.path).?,
        .taken = p.taken,
    };
}

fn writeProv(w: *Writer, p: Prov) Allocator.Error!void {
    const k = provKey(w, p);
    try w.byte(k.kind);
    try w.int(k.a);
    try w.int(k.b);
    try w.int(k.path);
    try w.byte(@intFromBool(k.taken));
}

fn atomLess(w: *const Writer, x: XAtom, y: XAtom) bool {
    if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
    const xa = provKey(w, x.a);
    const ya = provKey(w, y.a);
    if (xa.less(ya) or ya.less(xa)) return xa.less(ya);
    return provKey(w, x.b).less(provKey(w, y.b));
}

fn writeAtoms(w: *Writer, arena: Allocator, atoms: []const XAtom) Allocator.Error!void {
    const sorted = try arena.dupe(XAtom, atoms);
    std.mem.sort(XAtom, sorted, w, atomLess);
    try w.int(@intCast(sorted.len));
    for (sorted) |a| {
        try w.byte(@backingInt(a.kind));
        try writeProv(w, a.a);
        try writeProv(w, a.b);
    }
}

fn writeXSum(w: *Writer, arena: Allocator, x: XSum) Allocator.Error!void {
    try w.byte(x.no);
    try writeAtoms(w, arena, x.atoms);
}

fn writeRes(w: *Writer, arena: Allocator, items: []const ResEntry, sort: bool) Allocator.Error!void {
    const list = try arena.dupe(ResEntry, items);
    if (sort) {
        const Cx = struct {
            w: *const Writer,
            fn less(cx: @This(), x: ResEntry, y: ResEntry) bool {
                const px = cx.w.path_index.get(x.path).?;
                const py = cx.w.path_index.get(y.path).?;
                if (px != py) return px < py;
                return provKey(cx.w, x.prov).less(provKey(cx.w, y.prov));
            }
        };
        std.mem.sort(ResEntry, list, Cx{ .w = w }, Cx.less);
    }
    try w.int(@intCast(list.len));
    for (list) |r| {
        try w.int(w.path_index.get(r.path).?);
        try writeProv(w, r.prov);
        try w.byte(@intFromBool(r.approx));
        try writeXSum(w, arena, r.xc);
        try writeXSum(w, arena, r.sc);
    }
}

fn writeSummary(w: *Writer, arena: Allocator, s: *const Summary) Allocator.Error!void {
    try w.int(s.params);
    try w.byte(@backingInt(s.limit));
    try w.int(s.limit_at);
    try w.byte(@as(u8, @intFromBool(s.asserted)) | @as(u8, @intFromBool(s.once)) << 2 | @as(u8, @intFromBool(s.words)) << 3);

    const uses = try arena.dupe(UseEntry, s.uses);
    const UseCx = struct {
        w: *const Writer,
        fn less(cx: @This(), x: UseEntry, y: UseEntry) bool {
            if (x.param != y.param) return x.param < y.param;
            return cx.w.path_index.get(x.path).? < cx.w.path_index.get(y.path).?;
        }
    };
    std.mem.sort(UseEntry, uses, UseCx{ .w = w }, UseCx.less);
    try w.int(@intCast(uses.len));
    for (uses) |u| {
        try w.int(u.param);
        try w.int(w.path_index.get(u.path).?);
        try w.byte(u.bits);
    }

    try writeRes(w, arena, s.res, true);

    const supply = try arena.dupe(SupplyEntry, s.supply);
    const SupCx = struct {
        w: *const Writer,
        fn less(cx: @This(), x: SupplyEntry, y: SupplyEntry) bool {
            if (x.fun != y.fun) return x.fun < y.fun;
            if (x.k != y.k) return x.k < y.k;
            const px = cx.w.path_index.get(x.path).?;
            const py = cx.w.path_index.get(y.path).?;
            if (px != py) return px < py;
            return provKey(cx.w, x.prov).less(provKey(cx.w, y.prov));
        }
    };
    std.mem.sort(SupplyEntry, supply, SupCx{ .w = w }, SupCx.less);
    try w.int(@intCast(supply.len));
    for (supply) |e| {
        try w.int(e.fun);
        try w.int(e.k);
        try w.int(w.path_index.get(e.path).?);
        try writeProv(w, e.prov);
        try w.byte(@as(u8, @intFromBool(e.owned)) | @as(u8, @intFromBool(e.approx)) << 1);
        try writeXSum(w, arena, e.xc);
    }

    const funs = try arena.dupe(FunFacts, s.funs);
    std.mem.sort(FunFacts, funs, {}, struct {
        fn less(_: void, x: FunFacts, y: FunFacts) bool {
            return x.param < y.param;
        }
    }.less);
    try w.int(@intCast(funs.len));
    for (funs) |f| {
        try w.int(f.param);
        try w.byte(@backingInt(f.calls));
        try w.byte(@as(u8, @intFromBool(f.need)) | @as(u8, @intFromBool(f.seen)) << 1 | @as(u8, @intFromBool(f.sends)) << 2);
        try w.int(f.send);
    }

    try writeAtoms(w, arena, s.xreq);

    try w.int(@intCast(s.slots.len));
    for (s.slots) |sl| {
        try w.int(sl[0]);
        try w.int(w.path_index.get(sl[1]).?);
    }

    try w.int(@intCast(s.klasses.len));
    for (s.klasses) |k| {
        try writeSummary(w, arena, k.sum);
        try w.int(@intCast(k.binds.len));
        for (k.binds) |b| {
            try w.int(b.local);
            try w.int(w.path_index.get(b.path).?);
            try writeRes(w, arena, b.provs, false);
        }
        try w.int(@intCast(k.cb_js.len));
        for (k.cb_js) |j| try w.int(j);
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const Reader = struct {
    o: *Ownership,
    arena: Allocator,
    bytes: []const u8,
    at: usize = 0,
    modules: []u32 = &.{},
    strings: []u32 = &.{},
    paths: []u32 = &.{},

    fn int(r: *Reader) Error!u32 {
        if (r.bytes.len - r.at < 4) return error.Bad;
        const v = std.mem.readInt(u32, r.bytes[r.at..][0..4], .little);
        r.at += 4;
        return v;
    }

    fn byte(r: *Reader) Error!u8 {
        if (r.at >= r.bytes.len) return error.Bad;
        r.at += 1;
        return r.bytes[r.at - 1];
    }

    fn text(r: *Reader) Error![]const u8 {
        const n = try r.int();
        if (r.bytes.len - r.at < n) return error.Bad;
        r.at += n;
        return r.bytes[r.at - n .. r.at];
    }

    /// A count of items each at least `min` bytes long: a count the rest of
    /// the block cannot hold is a bad block, not an allocation.
    fn count(r: *Reader, min: usize) Error!u32 {
        const n = try r.int();
        if (@as(u64, n) * min > r.bytes.len - r.at) return error.Bad;
        return n;
    }

    fn path(r: *Reader) Error!u32 {
        const i = try r.int();
        if (i >= r.paths.len) return error.Bad;
        return r.paths[i];
    }

    fn module(r: *Reader) Error!u32 {
        const i = try r.int();
        if (i >= r.modules.len) return error.Bad;
        return r.modules[i];
    }

    fn enumOf(r: *Reader, comptime E: type) Error!E {
        const v = try r.byte();
        return std.enums.fromInt(E, v) orelse error.Bad;
    }

    fn bool_(r: *Reader) Error!bool {
        return switch (try r.byte()) {
            0 => false,
            1 => true,
            else => error.Bad,
        };
    }
};

/// The block `bytes` of module `m`, its paths interned into `o`'s table and
/// its summaries in `o`'s normal form. `error.Bad` when the bytes are not a
/// block of this version, or name a module, declaration or constructor this
/// session does not have.
pub fn read(o: *Ownership, arena: Allocator, bytes: []const u8, m: u32) Error!Block {
    var r: Reader = .{ .o = o, .arena = arena, .bytes = bytes };
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.Bad;
    r.at = magic.len;
    if (try r.int() != version) return error.Bad;

    const n_modules = try r.count(5);
    r.modules = try arena.alloc(u32, n_modules);
    for (r.modules) |*slot| {
        const package = std.enums.fromInt(SourceStore.Package, try r.byte()) orelse return error.Bad;
        const name = try r.text();
        slot.* = o.moduleNamed(package, name) orelse return error.Bad;
    }
    const n_strings = try r.count(4);
    r.strings = try arena.alloc(u32, n_strings);
    for (r.strings) |*slot| {
        const name = try r.text();
        // A field the session never interned is a field no value of this
        // session has: the step is still a field, of no record it can meet.
        slot.* = if (o.in.interner.find(name)) |s| @backingInt(s) else Ownership.none;
    }
    const n_paths = try r.count(1);
    r.paths = try arena.alloc(u32, n_paths);
    for (r.paths) |*slot| {
        const n_steps = try r.byte();
        if (n_steps > Ownership.k_limit) return error.Bad;
        var at: u32 = Ownership.eps;
        for (0..n_steps) |_| {
            const kind = try r.enumOf(StepKind);
            const arg: u32 = switch (kind) {
                .field => blk: {
                    const i = try r.int();
                    if (i >= r.strings.len) return error.Bad;
                    break :blk r.strings[i];
                },
                .tuple => try r.int(),
                .ctor => blk: {
                    const cm = try r.module();
                    const ci = try r.int();
                    const k = try r.int();
                    const arity = (try o.ctorArity(cm, ci)) orelse return error.Bad;
                    if (k >= arity) return error.Bad;
                    break :blk try o.ctorStep(try o.ctorId(cm, ci), k);
                },
                .elem, .env, .any, .markup_render, .markup_event, .schema_decoded, .schema_encoded => 0,
            };
            at = try o.rawChild(at, kind, arg);
        }
        slot.* = at;
    }

    const decls = o.in.birs[m].decls.len;
    const block: Block = .{
        .sums = try arena.alloc(?Summary, decls),
        .holds_list = try arena.alloc(bool, decls),
    };
    @memset(block.sums, null);
    @memset(block.holds_list, false);
    const n_rows = try r.count(5);
    for (0..n_rows) |_| {
        const d = try r.int();
        if (d >= decls) return error.Bad;
        const flags = try r.byte();
        if (flags > 3) return error.Bad;
        block.holds_list[d] = flags & 2 != 0;
        if (flags & 1 != 0) block.sums[d] = try readSummary(&r, 0);
    }
    if (r.at != bytes.len) return error.Bad;
    return block;
}

fn readProv(r: *Reader) Error!Prov {
    const kind = try r.enumOf(Ownership.ProvKind);
    const a_raw = try r.int();
    const b = try r.int();
    const path = try r.path();
    const taken = try r.bool_();
    const a = if (kind == .shared) blk: {
        if (a_raw >= r.modules.len) return error.Bad;
        const sm = r.modules[a_raw];
        if (b >= r.o.in.birs[sm].decls.len) return error.Bad;
        break :blk sm;
    } else a_raw;
    return .{ .kind = kind, .a = a, .b = b, .path = path, .taken = taken };
}

fn readAtoms(r: *Reader) Error![]const XAtom {
    const n = try r.count(1 + 2 * 14);
    const atoms = try r.arena.alloc(XAtom, n);
    for (atoms) |*a| {
        const kind = try r.enumOf(@FieldType(XAtom, "kind"));
        const x = try readProv(r);
        const y = try readProv(r);
        a.* = if (kind == .sep) Ownership.sepAtom(x, y) else .{ .kind = kind, .a = x, .b = y };
    }
    return Ownership.sortAtoms(atoms);
}

fn readXSum(r: *Reader) Error!XSum {
    const no = try r.byte();
    if (no > 2) return error.Bad;
    return .{ .no = no, .atoms = try readAtoms(r) };
}

fn readRes(r: *Reader) Error![]const ResEntry {
    const n = try r.count(4 + 14 + 1 + 10);
    const out = try r.arena.alloc(ResEntry, n);
    for (out) |*e| {
        const path = try r.path();
        const prov = try readProv(r);
        const approx = try r.bool_();
        e.* = .{ .path = path, .prov = prov, .approx = approx, .xc = try readXSum(r), .sc = try readXSum(r) };
    }
    return out;
}

fn readSummary(r: *Reader, depth: u32) Error!Summary {
    // A carried lambda's class holds no carried lambda of its own deeper
    // than the walk can make; a block that nests further is not one.
    if (depth > 16) return error.Bad;
    const params = try r.int();
    const limit = try r.enumOf(Ownership.Limit);
    const limit_at = try r.int();
    const flags = try r.byte();
    // Bit 2 was a coarsened summary's, before §16.7 deleted coarsening.
    if (flags > 15 or flags & 2 != 0) return error.Bad;

    const uses = try r.arena.alloc(UseEntry, try r.count(9));
    for (uses) |*u| u.* = .{ .param = try r.int(), .path = try r.path(), .bits = try r.byte() };

    const res = try readRes(r);

    const supply = try r.arena.alloc(SupplyEntry, try r.count(12 + 14 + 1 + 5));
    for (supply) |*e| {
        const fun = try r.int();
        const k = try r.int();
        const path = try r.path();
        const prov = try readProv(r);
        const bits = try r.byte();
        if (bits > 3) return error.Bad;
        e.* = .{ .fun = fun, .k = k, .path = path, .prov = prov, .owned = bits & 1 != 0, .approx = bits & 2 != 0, .xc = try readXSum(r) };
    }

    const funs = try r.arena.alloc(FunFacts, try r.count(10));
    for (funs) |*f| {
        const param = try r.int();
        const calls = try r.enumOf(Ownership.Calls);
        const bits = try r.byte();
        if (bits > 7) return error.Bad;
        f.* = .{ .param = param, .calls = calls, .need = bits & 1 != 0, .seen = bits & 2 != 0, .sends = bits & 4 != 0, .send = try r.int() };
    }

    const xreq = try readAtoms(r);

    const slots = try r.arena.alloc([2]u32, try r.count(8));
    for (slots) |*sl| sl.* = .{ try r.int(), try r.path() };

    const klasses = try r.arena.alloc(Carried, try r.count(4));
    for (klasses) |*k| {
        const sum = try r.arena.create(Summary);
        sum.* = try readSummary(r, depth + 1);
        const binds = try r.arena.alloc(Carried.Bind, try r.count(12));
        for (binds) |*b| b.* = .{ .local = try r.int(), .path = try r.path(), .provs = try readRes(r) };
        const cb_js = try r.arena.alloc(u32, try r.count(4));
        for (cb_js) |*j| j.* = try r.int();
        k.* = .{ .sum = sum, .binds = binds, .cb_js = cb_js };
    }

    return r.o.normalizeRead(.{
        .params = params,
        .uses = uses,
        .res = res,
        .supply = supply,
        .funs = funs,
        .limit = limit,
        .limit_at = limit_at,
        .asserted = flags & 1 != 0,
        .once = flags & 4 != 0,
        .words = flags & 8 != 0,
        .xreq = xreq,
        .slots = slots,
        .klasses = klasses,
    });
}

test "a block naming a constructor field past the constructor's arity is refused" {
    const gpa = std.testing.allocator;
    const Bir = @import("../bir/Bir.zig");
    // One module, `M`, whose one constructor takes two fields.
    const extra = [_]u32{ 0, 0 };
    var symbols = [_]Bir.Symbol{};
    const ctors = [_]Bir.Ctor{.{ .name = .none, .name_token = 0, .decl = @fromBackingInt(@intCast(0)), .args_start = @fromBackingInt(@intCast(0)), .args_end = @fromBackingInt(@intCast(2)) }};
    const bir: Bir = .{
        .insts = (Bir.InstList{}).slice(),
        .extra = &extra,
        .string_bytes = "",
        .symbols = &symbols,
        .decls = &.{},
        .ctors = &ctors,
        .locals = &.{},
        .refs = &.{},
        .imports = &.{},
        .exposed = &.{},
        .interface = &.{},
        .diagnostics = &.{},
        .module_doc_start = 0,
        .module_doc_end = 0,
    };
    const birs = [_]*const Bir{&bir};
    const names = [_][]const u8{"M"};
    const packages = [_]SourceStore.Package{.app};
    var o = Ownership.init(.{
        .gpa = gpa,
        .graph = undefined,
        .birs = &birs,
        .provenance = &.{},
        .dispatch = &.{},
        .modules = &.{},
        .types = undefined,
        .interner = undefined,
        .module_names = &names,
        .packages = &packages,
        .spans = &.{},
        .positions = undefined,
    });
    defer o.deinit();
    try o.seedPaths();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // A block of no rows and one path, `#C.k`.
    const bytes = struct {
        fn of(a: Allocator, k: u32) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            const int = struct {
                fn f(al: Allocator, o2: *std.ArrayList(u8), v: u32) !void {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, v, .little);
                    try o2.appendSlice(al, &b);
                }
            }.f;
            try out.appendSlice(a, magic);
            try int(a, &out, version);
            try int(a, &out, 1);
            try out.append(a, @backingInt(SourceStore.Package.app));
            try int(a, &out, 1);
            try out.append(a, 'M');
            try int(a, &out, 0);
            try int(a, &out, 1);
            try out.append(a, 1);
            try out.append(a, @backingInt(Ownership.StepKind.ctor));
            try int(a, &out, 0);
            try int(a, &out, 0);
            try int(a, &out, k);
            try int(a, &out, 0);
            return out.items;
        }
    };
    _ = try read(&o, arena.allocator(), try bytes.of(arena.allocator(), 1), 0);
    try std.testing.expectError(error.Bad, read(&o, arena.allocator(), try bytes.of(arena.allocator(), 2), 0));
    try std.testing.expectError(error.Bad, read(&o, arena.allocator(), try bytes.of(arena.allocator(), 64), 0));
}
