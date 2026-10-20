//! Representation keys (`backend.md` §3, *Amended 2026-10-20*, and §9,
//! *Declared-type filtering of fact 3*): the checker's type keys
//! (`check/TypeKeys.zig`), one artifact
//! per module, merged into ONE table for the build and mapped to what a
//! value of each type is at run time in a release build. `Lower` writes the
//! result into `JsIr.name_key` and `JsIr.node_key`; nothing decides what to
//! emit by it, and fact 3's declared-type filter is its one reader.
//!
//! **The table.** A node is a canonical closed type, as the checker's are
//! (a named type applied to its arguments' keys, a record by its fields
//! ordered by text, a function's parameters then its result, a tuple's
//! elements, `⊤`), but interned once for the whole build, so one type is one
//! id in every module. Ids are assigned here, on the calling thread, in
//! module order and, within a module, in its artifact's order, and every
//! later node in the order the walk below meets it: never by a worker
//! (CLAUDE.md rule 5). A module installed from the cache has the artifact a
//! fresh check gives it (checker-v2.md §36), so the table is the same warm
//! or cold.
//!
//! **The representation.** `rep` maps a type to what its value is: a type
//! of one constructor with one field, under `--release` with integer tags,
//! IS its field (`CtorRep.unboxed`, *A type of one constructor with one field
//! is its field*), so `Wrap R` is `R`'s key, its arguments substituted into
//! the field's written type; every other node is itself with its children's
//! representations. `Bool`, the primitives, `⊤` and a type all of whose
//! constructors are nullary make no site, and a column holds `wild` for
//! them: they need no key.
//!
//! **The wild set**, assembled here in module order: what each module's
//! artifact adds (`Js.from` and `Js.to` types, closed types a crossing
//! quantifier is instantiated at, `?` subjects); every closed type a live
//! `foreign` names; every named type the release boundary keeps
//! (`Fields.close`, unboxing's boundary set — a type without integer tags);
//! and, to a fixpoint, every part of a wild key and every field type of a
//! wild named type's constructors under its arguments. A key in the set is
//! wild wherever it occurs; the columns hold the key itself, and
//! `isWild` answers for the set.
//!
//! **What this file cannot key is wild, and what it cannot follow is
//! everything.** A written type this file cannot canonicalise as the checker
//! does — a schema endpoint's body, which is a plan and not a written type —
//! is wild where it is a field of an unboxed type, and where the wild set
//! would have to close through it, every key is (`all_wild`): a key equal to
//! no checker key would make a var's filter differ from a site of the same
//! type, which is a miscompile and not a missed precision.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("../check/Types.zig");
const TypeKeys = @import("../check/TypeKeys.zig");
const Fields = @import("Fields.zig");
const Reach = @import("Reach.zig");
const JsIr = @import("JsIr.zig");

const RepKeys = @This();

pub const RepKey = JsIr.RepKey;
pub const Kind = TypeKeys.KeyNode.Kind;
const TypeId = Types.TypeId;
const Symbol = InternPool.Symbol;
const Inst = Bir.Inst;

/// One canonical closed type of the build.
pub const Node = struct {
    kind: Kind,
    /// Children, a range of `args`.
    start: u32,
    len: u32,
    /// `named`: the `TypeId`. `record`: where its labels start in `labels`.
    value: u32,
};

pub const Input = struct {
    arena: Allocator,
    graph: *const Graph,
    /// One per graph module.
    birs: []const *const Bir,
    /// One per graph module: `Check.type_keys`.
    artifacts: []const TypeKeys.Artifact,
    types: *const Types,
    interner: *const InternPool.Global,
    /// The release boundary (`Fields.close`): which types have integer
    /// tags and so may be unboxed. Null: none has, and every named type of
    /// constructors is in the boundary.
    boundary: ?*const Fields.Boundary,
    live: *const Reach.Result,
};

in: Input,
nodes: std.ArrayList(Node) = .empty,
args: std.ArrayList(u32) = .empty,
labels: std.ArrayList(Symbol) = .empty,
hashes: std.ArrayList(u64) = .empty,
/// Per node: its representation (`rep`), `unset` or `pending`.
reps: std.ArrayList(u32) = .empty,
/// Per node: in the wild set.
wild: std.ArrayList(bool) = .empty,
/// Every key is wild: the wild set had to close through a type this file
/// cannot canonicalise (see the header).
all_wild: bool = false,
/// Per graph module, per type key of its artifact: what a column holds.
columns: []const []const RepKey = &.{},
map: std.HashMapUnmanaged(Interned, void, Ctx, std.hash_map.default_max_load_percentage) = .empty,
queue: std.ArrayList(u32) = .empty,
/// One node's children while it is interned.
scratch_children: std.ArrayList(u32) = .empty,

const unset: u32 = std.math.maxInt(u32) - 1;
const pending: u32 = std.math.maxInt(u32) - 2;
const wild_id: u32 = RepKey.wild.int();

/// How deep a written type is followed before it is given up on.
const max_depth = 256;

const Interned = struct { id: u32 };

const Ctx = struct {
    r: *const RepKeys,
    pub fn hash(c: Ctx, k: Interned) u64 {
        return c.r.hashes.items[k.id];
    }
    pub fn eql(_: Ctx, a: Interned, b: Interned) bool {
        return a.id == b.id;
    }
};

const Candidate = struct { h: u64, kind: Kind, value: u32, children: []const u32, names: []const Symbol };

const Adapter = struct {
    r: *const RepKeys,
    pub fn hash(_: Adapter, c: Candidate) u64 {
        return c.h;
    }
    pub fn eql(a: Adapter, c: Candidate, k: Interned) bool {
        if (a.r.hashes.items[k.id] != c.h) return false;
        const n = a.r.nodes.items[k.id];
        if (n.kind != c.kind or n.len != c.children.len) return false;
        if (c.kind == .record) {
            if (!std.mem.eql(Symbol, a.r.labels.items[n.value..][0..n.len], c.names)) return false;
        } else if (n.value != c.value) return false;
        return std.mem.eql(u32, a.r.args.items[n.start..][0..n.len], c.children);
    }
};

inline fn mix(h: u64, w: u32) u64 {
    return std.math.rotl(u64, (h ^ w) *% 0x9E3779B97F4A7C15, 23);
}

/// What converting a written type gives: its node; `wild`, a type the
/// checker keys wild too (a host type, a poisoned one); or `unknown`, a type
/// this file cannot canonicalise although the checker may key it.
const Conv = union(enum) { term: u32, wild, unknown };

/// Merge every module's artifact into one table and close the wild set.
pub fn build(in: Input) Allocator.Error!RepKeys {
    var r: RepKeys = .{ .in = in };
    const arena = in.arena;
    const count = in.artifacts.len;

    // The artifacts' nodes, as the build's, in module order. A child
    // precedes its owner in an artifact.
    const terms = try arena.alloc([]const u32, count);
    for (in.artifacts, terms) |*a, *slot| {
        const of = try arena.alloc(u32, a.nodes.len);
        for (a.nodes, 0..) |n, k| {
            const kids = try arena.alloc(u32, n.args.len);
            var ok = true;
            for (a.args[n.args.start..][0..n.args.len], kids) |child, *to| {
                if (child == .wild or child.int() >= k) {
                    ok = false;
                    break;
                }
                to.* = of[child.int()];
                if (to.* == wild_id) ok = false;
            }
            of[k] = if (!ok) wild_id else switch (n.kind) {
                .record => try r.intern(.record, 0, a.labels[n.value..][0..n.args.len], kids),
                else => try r.intern(n.kind, n.value, &.{}, kids),
            };
        }
        slot.* = of;
    }

    // What each column holds: the representation, or wild for a type that
    // makes no site.
    const columns = try arena.alloc([]const RepKey, count);
    for (terms, columns) |of, *slot| {
        const col = try arena.alloc(RepKey, of.len);
        for (of, col) |t, *k| k.* = try r.column(t);
        slot.* = col;
    }
    r.columns = columns;

    // The wild set: each module's own half, in module order.
    for (in.artifacts, terms) |*a, of| {
        for (a.wild) |k| {
            if (k == .wild or k.int() >= of.len) continue;
            try r.markWild(try r.repOf(of[k.int()], 0));
        }
    }
    // Every closed type a live `foreign` names.
    for (in.birs, 0..) |bir, mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(mi))));
        for (bir.decls, 0..) |d, i| {
            if (d.kind != .foreign_value or !in.live.decl(m, i)) continue;
            const annotation = d.annotation.unwrap() orelse continue;
            try r.foreignTypes(m, annotation);
        }
    }
    // The boundary's named types and the closure, until neither adds a node.
    var scanned: usize = 0;
    var cursor: usize = 0;
    while (!r.all_wild) {
        if (cursor < r.queue.items.len) {
            const w = r.queue.items[cursor];
            cursor += 1;
            try r.closeThrough(w);
            continue;
        }
        if (scanned < r.nodes.items.len) {
            const t: u32 = @intCast(scanned);
            scanned += 1;
            if (r.inBoundary(t)) try r.markWild(t);
            continue;
        }
        break;
    }
    return r;
}

// ---- Queries ----------------------------------------------------------------

/// The key a column holds for local `local` (an index of `Bir.locals`) of
/// module `m`.
pub fn localKey(r: *const RepKeys, m: Graph.Index, local: usize) RepKey {
    if (m.int() >= r.columns.len) return .wild;
    const a = &r.in.artifacts[m.int()];
    if (local >= a.locals.len) return .wild;
    return r.columnOf(m, a.locals[local]);
}

/// The key a column holds for the value allocating instruction `inst` of
/// module `m` makes, or wild when it has no row.
pub fn instKey(r: *const RepKeys, m: Graph.Index, inst: Inst.Index) RepKey {
    if (m.int() >= r.columns.len) return .wild;
    const row = r.in.artifacts[m.int()].instKey(inst) orelse return .wild;
    return r.columnOf(m, row.key);
}

fn columnOf(r: *const RepKeys, m: Graph.Index, k: TypeKeys.TypeKey) RepKey {
    if (k == .wild) return .wild;
    const col = r.columns[m.int()];
    return if (k.int() < col.len) col[k.int()] else .wild;
}

/// Whether `k` is in the wild set: a var it filters holds everything, and
/// a site of it passes every filter.
pub fn isWild(r: *const RepKeys, k: RepKey) bool {
    if (k == .wild or r.all_wild) return true;
    return k.int() >= r.wild.items.len or r.wild.items[k.int()];
}

/// The result key of a function key: what its arrow's return var is
/// filtered by.
pub fn result(r: *const RepKeys, k: RepKey) RepKey {
    if (k == .wild or k.int() >= r.nodes.items.len) return .wild;
    const n = r.nodes.items[k.int()];
    if (n.kind != .function or n.len == 0) return .wild;
    return @fromBackingInt(r.args.items[n.start + n.len - 1]);
}

// ---- Interning --------------------------------------------------------------

fn intern(r: *RepKeys, kind: Kind, value: u32, names: []const Symbol, children: []const u32) Allocator.Error!u32 {
    const arena = r.in.arena;
    var h: u64 = mix(mix(0x5e9e, @backingInt(kind)), if (kind == .record) 0 else value);
    for (names) |s| h = mix(h, @backingInt(s));
    for (children) |c| h = mix(h, c);
    h ^= h >> 29;
    const gop = try r.map.getOrPutContextAdapted(arena, Candidate{ .h = h, .kind = kind, .value = value, .children = children, .names = names }, Adapter{ .r = r }, Ctx{ .r = r });
    if (gop.found_existing) return gop.key_ptr.id;
    const id: u32 = @intCast(r.nodes.items.len);
    const start: u32 = @intCast(r.args.items.len);
    try r.args.appendSlice(arena, children);
    var v = value;
    if (kind == .record) {
        v = @intCast(r.labels.items.len);
        try r.labels.appendSlice(arena, names);
    }
    try r.nodes.append(arena, .{ .kind = kind, .start = start, .len = @intCast(children.len), .value = v });
    try r.hashes.append(arena, h);
    try r.reps.append(arena, unset);
    try r.wild.append(arena, false);
    gop.key_ptr.* = .{ .id = id };
    return id;
}

/// A node's children, copied: interning may move `args`.
fn childrenOf(r: *RepKeys, t: u32) Allocator.Error![]u32 {
    const n = r.nodes.items[t];
    return r.in.arena.dupe(u32, r.args.items[n.start..][0..n.len]);
}

fn labelsOf(r: *RepKeys, t: u32) Allocator.Error![]Symbol {
    const n = r.nodes.items[t];
    if (n.kind != .record) return &.{};
    return r.in.arena.dupe(Symbol, r.labels.items[n.value..][0..n.len]);
}

// ---- The representation ------------------------------------------------------

/// What a value of node `t` is at run time: the node itself, its children
/// each their own representation, but for a type that is its one field.
fn repOf(r: *RepKeys, t: u32, depth: u32) Allocator.Error!u32 {
    if (t == wild_id) return wild_id;
    switch (r.reps.items[t]) {
        unset => {},
        // A type that is its own field, through however many unboxed types:
        // no value has it, and wild is the safe answer.
        pending => return wild_id,
        else => |done| return done,
    }
    if (depth > max_depth) return wild_id;
    r.reps.items[t] = pending;
    const n = r.nodes.items[t];
    const out: u32 = blk: {
        if (n.kind == .unit) break :blk t;
        if (n.kind == .named) if (r.unboxedField(@fromBackingInt(@intCast(n.value)))) |field| {
            const args = try r.childrenOf(t);
            switch (try r.fromBir(field.module, field.inst, args, depth + 1)) {
                .term => |f| break :blk try r.repOf(f, depth + 1),
                .wild, .unknown => break :blk wild_id,
            }
        };
        const kids = try r.childrenOf(t);
        var same = true;
        for (kids) |*c| {
            const k = try r.repOf(c.*, depth + 1);
            if (k == wild_id) break :blk wild_id;
            if (k != c.*) same = false;
            c.* = k;
        }
        if (same) break :blk t;
        const rep = try r.intern(n.kind, n.value, try r.labelsOf(t), kids);
        // A representation is its own.
        if (r.reps.items[rep] == unset) r.reps.items[rep] = rep;
        break :blk rep;
    };
    r.reps.items[t] = out;
    return out;
}

/// The key a column holds for node `t`.
fn column(r: *RepKeys, t: u32) Allocator.Error!RepKey {
    const rep = try r.repOf(t, 0);
    if (rep == wild_id or r.noSite(rep)) return .wild;
    return @fromBackingInt(rep);
}

const Field = struct { module: Graph.Index, inst: Inst.Index };

/// The field's written type of `id`'s one constructor, when a value of
/// `id` is that field (`Lower.ctorRepLocal`'s `.unboxed`: integer tags, one
/// constructor, one field).
fn unboxedField(r: *const RepKeys, id: TypeId) ?Field {
    const b = r.in.boundary orelse return null;
    if (!b.integerTags(id)) return null;
    const e = r.in.types.entries[id.int()];
    if (e.kind != .adt or e.schema_endpoint or e.module.int() >= r.in.birs.len) return null;
    const bir = r.in.birs[e.module.int()];
    const ctors = bir.declCtors(bir.decl(e.decl));
    if (ctors.len != 1) return null;
    const args = bir.extraSlice(.{ .start = ctors[0].args_start, .end = ctors[0].args_end }, Inst.Index);
    if (args.len != 1) return null;
    return .{ .module = e.module, .inst = args[0] };
}

/// Whether a value of node `t` is never an object, an array or a function:
/// `⊤`, `Bool`, a primitive, a type all of whose constructors are nullary.
fn noSite(r: *const RepKeys, t: u32) bool {
    const n = r.nodes.items[t];
    switch (n.kind) {
        .unit => return true,
        .named => {},
        else => return false,
    }
    const id: TypeId = @fromBackingInt(@intCast(n.value));
    const wk = r.in.types.well_known;
    if (id == wk.int or id == wk.float or id == wk.char or id == wk.string or id == wk.bool) return true;
    const e = r.in.types.entries[id.int()];
    if (e.kind != .adt or e.schema_endpoint or e.module.int() >= r.in.birs.len) return false;
    const bir = r.in.birs[e.module.int()];
    for (bir.declCtors(bir.decl(e.decl))) |c| {
        if (@backingInt(c.args_end) != @backingInt(c.args_start)) return false;
    }
    return true;
}

// ---- Written types ----------------------------------------------------------

/// The node of the written type `inst` of module `m`, its type parameters
/// `subst`: canonical as the checker's (checker-v2.md §36) — an alias
/// expanded, a record's fields by text, a host type wild.
fn fromBir(r: *RepKeys, m: Graph.Index, inst: Inst.Index, subst: []const u32, depth: u32) Allocator.Error!Conv {
    if (depth > max_depth) return .unknown;
    if (m.int() >= r.in.birs.len) return .unknown;
    const bir = r.in.birs[m.int()];
    if (inst.int() >= bir.insts.len) return .unknown;
    const tag = bir.instTag(inst);
    const d = bir.instData(inst);
    switch (tag) {
        .type_var => {
            const info = Bir.TypeVarInfo.unpack(d.rhs);
            if (info.param == Bir.TypeVarInfo.param_none or info.param >= subst.len) return .wild;
            const t = subst[info.param];
            return if (t == wild_id) .wild else .{ .term = t };
        },
        .type_top, .ext_type, .schema_type_top, .ext_schema_type => return r.named(r.in.types.headId(m, tag, d), &.{}, depth),
        .type_app => {
            const head: Inst.Index = @fromBackingInt(@intCast(d.lhs));
            const items = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index);
            const args = try r.in.arena.alloc(u32, items.len);
            var wild = false;
            for (items, args) |item, *to| switch (try r.fromBir(m, item, subst, depth + 1)) {
                .term => |t| to.* = t,
                .wild => {
                    wild = true;
                    to.* = wild_id;
                },
                .unknown => return .unknown,
            };
            const id = r.in.types.headId(m, bir.instTag(head), bir.instData(head));
            // An alias expands whatever its arguments are: a wild argument
            // may be one the body never reads.
            if (wild and !r.isAlias(id)) return .wild;
            return r.named(id, args, depth);
        },
        .type_fn => {
            const params = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.lhs))), Inst.Index);
            const kids = try r.in.arena.alloc(u32, params.len + 1);
            for (params, kids[0..params.len]) |p, *to| to.* = switch (try r.fromBir(m, p, subst, depth + 1)) {
                .term => |t| t,
                else => |c| return c,
            };
            kids[params.len] = switch (try r.fromBir(m, @fromBackingInt(@intCast(d.rhs)), subst, depth + 1)) {
                .term => |t| t,
                else => |c| return c,
            };
            return .{ .term = try r.intern(.function, 0, &.{}, kids) };
        },
        .type_unit => return .{ .term = try r.intern(.unit, 0, &.{}, &.{}) },
        .type_tuple => {
            const items = bir.extraSlice(Bir.inlineRange(d), Inst.Index);
            const kids = try r.in.arena.alloc(u32, items.len);
            for (items, kids) |item, *to| to.* = switch (try r.fromBir(m, item, subst, depth + 1)) {
                .term => |t| t,
                else => |c| return c,
            };
            return .{ .term = try r.intern(.tuple, 0, &.{}, kids) };
        },
        .type_record => return r.record(m, bir, bir.extraSlice(Bir.inlineRange(d), Bir.Field), null, subst, depth),
        .type_record_ext => {
            // `{ r | x : Int }` under a closed record `r`: the whole row.
            const base: Inst.Index = @fromBackingInt(@intCast(d.lhs));
            const row = switch (try r.fromBir(m, base, subst, depth + 1)) {
                .term => |t| t,
                else => |c| return c,
            };
            if (r.nodes.items[row].kind != .record) return .unknown;
            return r.record(m, bir, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Bir.Field), row, subst, depth);
        },
        else => return .unknown,
    }
}

fn isAlias(r: *const RepKeys, id: TypeId) bool {
    if (id == .none or id.int() >= r.in.types.entries.len) return false;
    return r.in.types.entries[id.int()].kind == .alias;
}

/// `id` applied to `args`, as the checker keys it.
fn named(r: *RepKeys, id: TypeId, args: []const u32, depth: u32) Allocator.Error!Conv {
    if (id == .none or id.int() >= r.in.types.entries.len) return .unknown;
    const e = r.in.types.entries[id.int()];
    if (args.len != e.arity) return .unknown;
    switch (e.kind) {
        .alias => {
            // A schema endpoint's body is a plan, not a written type.
            if (e.schema_endpoint or e.module.int() >= r.in.birs.len) return .unknown;
            const bir = r.in.birs[e.module.int()];
            const body = bir.decl(e.decl).annotation.unwrap() orelse return .unknown;
            return r.fromBir(e.module, body, args, depth + 1);
        },
        .foreign => {
            const wk = r.in.types.well_known;
            if (id != wk.int and id != wk.float and id != wk.char and id != wk.string and id != wk.list) return .wild;
        },
        .adt => {},
    }
    for (args) |a| if (a == wild_id) return .wild;
    return .{ .term = try r.intern(.named, @backingInt(id), &.{}, args) };
}

/// A record of `fields`, and of `row`'s when it extends one, its fields
/// ordered by text.
fn record(r: *RepKeys, m: Graph.Index, bir: *const Bir, fields: []const Bir.Field, row: ?u32, subst: []const u32, depth: u32) Allocator.Error!Conv {
    const Pair = struct { name: Symbol, term: u32 };
    var pairs: std.ArrayList(Pair) = .empty;
    if (row) |base| {
        const kids = try r.childrenOf(base);
        const names = try r.labelsOf(base);
        for (names, kids) |name, kid| try pairs.append(r.in.arena, .{ .name = name, .term = kid });
    }
    for (fields) |f| {
        const t = switch (try r.fromBir(m, f.value, subst, depth + 1)) {
            .term => |t| t,
            else => |c| return c,
        };
        try pairs.append(r.in.arena, .{ .name = bir.symbol(f.name), .term = t });
    }
    const interner = r.in.interner;
    std.mem.sort(Pair, pairs.items, interner, struct {
        fn lessThan(pool: *const InternPool.Global, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, pool.slice(a.name), pool.slice(b.name));
        }
    }.lessThan);
    const names = try r.in.arena.alloc(Symbol, pairs.items.len);
    const kids = try r.in.arena.alloc(u32, pairs.items.len);
    for (pairs.items, names, kids) |p, *n, *k| {
        n.* = p.name;
        k.* = p.term;
    }
    return .{ .term = try r.intern(.record, 0, names, kids) };
}

// ---- The wild set -----------------------------------------------------------

fn markWild(r: *RepKeys, t: u32) Allocator.Error!void {
    if (t == wild_id or r.wild.items[t]) return;
    r.wild.items[t] = true;
    try r.queue.append(r.in.arena, t);
}

/// A named type the release boundary keeps: one without integer tags, so a
/// value of it is one JavaScript may make or read (`Fields.close`).
fn inBoundary(r: *RepKeys, t: u32) bool {
    const n = r.nodes.items[t];
    if (n.kind != .named) return false;
    const id: TypeId = @fromBackingInt(@intCast(n.value));
    const e = r.in.types.entries[id.int()];
    if (e.kind != .adt or r.noSite(t)) return false;
    const b = r.in.boundary orelse return true;
    return !b.integerTags(id);
}

/// What a wild key makes wild: its parts, and a named type's constructors'
/// fields under its arguments, each as its representation.
fn closeThrough(r: *RepKeys, w: u32) Allocator.Error!void {
    const kids = try r.childrenOf(w);
    for (kids) |k| try r.markWild(try r.repOf(k, 0));
    const n = r.nodes.items[w];
    if (n.kind != .named) return;
    const id: TypeId = @fromBackingInt(@intCast(n.value));
    const e = r.in.types.entries[id.int()];
    if (e.kind != .adt) return;
    if (e.schema_endpoint or e.module.int() >= r.in.birs.len) {
        r.all_wild = true;
        return;
    }
    const bir = r.in.birs[e.module.int()];
    for (bir.declCtors(bir.decl(e.decl))) |c| {
        for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Inst.Index)) |arg| {
            switch (try r.fromBir(e.module, arg, kids, 0)) {
                .term => |t| try r.markWild(try r.repOf(t, 0)),
                // A field whose type holds a host type is wild already;
                // its closed parts are not, and are followed one by one.
                .wild => try r.closedParts(e.module, arg, kids),
                .unknown => {
                    r.all_wild = true;
                    return;
                },
            }
        }
    }
}

/// Every closed part of a written type into the wild set.
fn closedParts(r: *RepKeys, m: Graph.Index, root: Inst.Index, subst: []const u32) Allocator.Error!void {
    const bir = r.in.birs[m.int()];
    var stack: std.ArrayList(Inst.Index) = .empty;
    try stack.append(r.in.arena, root);
    var budget: usize = bir.insts.len + 16;
    while (stack.pop()) |inst| {
        if (budget == 0) {
            r.all_wild = true;
            return;
        }
        budget -= 1;
        switch (try r.fromBir(m, inst, subst, 0)) {
            .term => |t| {
                try r.markWild(try r.repOf(t, 0));
                continue;
            },
            .unknown => {
                r.all_wild = true;
                return;
            },
            .wild => {},
        }
        const d = bir.instData(inst);
        switch (bir.instTag(inst)) {
            .type_app => try stack.appendSlice(r.in.arena, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index)),
            .type_fn => {
                try stack.appendSlice(r.in.arena, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.lhs))), Inst.Index));
                try stack.append(r.in.arena, @fromBackingInt(@intCast(d.rhs)));
            },
            .type_tuple => try stack.appendSlice(r.in.arena, bir.extraSlice(Bir.inlineRange(d), Inst.Index)),
            .type_record => for (bir.extraSlice(Bir.inlineRange(d), Bir.Field)) |f| try stack.append(r.in.arena, f.value),
            .type_record_ext => for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Bir.Field)) |f| try stack.append(r.in.arena, f.value),
            else => {},
        }
    }
}

/// A live `foreign`'s annotation: every closed type it names (unboxing's
/// boundary set, `backend.md` §9).
fn foreignTypes(r: *RepKeys, m: Graph.Index, annotation: Inst.Index) Allocator.Error!void {
    try r.closedParts(m, annotation, &.{});
}

// ---- The dump ---------------------------------------------------------------

/// The table and the wild set as text (`build --rep-keys`): a named type by
/// its module's name and its own, a field by its text, no symbol id.
pub fn writeTable(r: *const RepKeys, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (r.all_wild) try w.writeAll("every key wild\n");
    const interner = r.in.interner;
    for (r.nodes.items, 0..) |n, i| {
        try w.print("key #{d} ", .{i});
        const kids = r.args.items[n.start..][0..n.len];
        switch (n.kind) {
            .named => {
                if (r.in.types.named(@fromBackingInt(@intCast(n.value)))) |nm| {
                    try w.print("{s}.{s}", .{ interner.slice(nm.module), interner.slice(nm.name) });
                } else try w.writeAll("<unknown>");
                for (kids) |k| try w.print(" #{d}", .{k});
            },
            .record => {
                if (kids.len == 0) {
                    try w.writeAll("{}");
                } else {
                    try w.writeAll("{ ");
                    for (kids, r.labels.items[n.value..][0..kids.len], 0..) |k, label, j| {
                        if (j != 0) try w.writeAll(", ");
                        try w.print("{s} : #{d}", .{ interner.slice(label), k });
                    }
                    try w.writeAll(" }");
                }
            },
            .function => {
                for (kids[0 .. kids.len - 1], 0..) |k, j| {
                    if (j != 0) try w.writeAll(", ");
                    try w.print("#{d}", .{k});
                }
                if (kids.len != 1) try w.writeByte(' ');
                try w.print("→ #{d}", .{kids[kids.len - 1]});
            },
            .tuple => for (kids, 0..) |k, j| {
                if (j != 0) try w.writeAll(" × ");
                try w.print("#{d}", .{k});
            },
            .unit => try w.writeAll("⊤"),
        }
        if (r.reps.items[i] != unset and r.reps.items[i] != i) {
            if (r.reps.items[i] == wild_id or r.reps.items[i] == pending) try w.writeAll(" is wild") else try w.print(" is #{d}", .{r.reps.items[i]});
        }
        if (r.wild.items[i]) try w.writeAll(" wild");
        try w.writeByte('\n');
    }
}

const testing = std.testing;

test "the wild set's queue never revisits a node" {
    // `markWild` is the only way into the queue and sets the bit first.
    var r: RepKeys = .{ .in = undefined };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    r.in.arena = arena_state.allocator();
    try r.wild.appendSlice(r.in.arena, &.{ false, false });
    try r.markWild(1);
    try r.markWild(1);
    try r.markWild(wild_id);
    try testing.expectEqualSlices(u32, &.{1}, r.queue.items);
}
