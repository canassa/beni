//! Representation keys (`backend.md` §3, *Amended 2026-10-20*, and §9,
//! *Declared-type filtering of fact 3*): the checker's type keys
//! (`check/TypeKeys.zig`), one artifact
//! per module, merged into ONE table for the build and mapped to what a
//! value of each type is at run time in a release build. `Lower` writes the
//! result into `JsIr.name_key` and `JsIr.node_keys`; nothing decides what to
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
//! `isWild` answers for the set. An arrow's key is what it returns, the one
//! thing it filters, and a function type is wild everywhere else.
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
const Interface = @import("../resolve/Interface.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
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
    /// One per graph module: `Check.plans`, the resolved schema plans, where
    /// a schema endpoint's type is written (`schema.md` A.6).
    plans: []const SchemaPlan = &.{},
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
/// Per graph module, per declaration: the key of what its function returns
/// (`declResult`), made here because a written annotation may intern a node
/// and the workers that read this table may not.
results: []const []const RepKey = &.{},
map: std.HashMapUnmanaged(Interned, void, Ctx, std.hash_map.default_max_load_percentage) = .empty,
queue: std.ArrayList(u32) = .empty,
/// The schema endpoints with parameters whose instantiations are records:
/// each node the table holds is matched against them (`instancesOf`).
param_endpoints: std.ArrayList(TypeId) = .empty,
/// Per graph module: its plan's `type_refs` as this session's ids, made
/// the first time a term of the plan is read.
plan_ids: []?[]const TypeId = &.{},
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
    r.plan_ids = try arena.alloc(?[]const TypeId, in.plans.len);
    @memset(r.plan_ids, null);
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

    // What each keyed module's top-level functions return: the result of
    // the declaration's key when the checker found it closed, else of the
    // annotation, whose parameters may be wild where its result is not
    // (`Js.Value` in, a model out).
    const results = try arena.alloc([]const RepKey, count);
    for (in.artifacts, results, 0..) |*a, *slot, mi| {
        if (a.decls.len == 0) {
            slot.* = &.{};
            continue;
        }
        const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(mi))));
        const bir = in.birs[mi];
        const out = try arena.alloc(RepKey, a.decls.len);
        for (out, a.decls, 0..) |*k, dk, di| {
            k.* = .wild;
            if (dk != .wild and dk.int() < terms[mi].len) {
                const t = terms[mi][dk.int()];
                if (t != wild_id and r.nodes.items[t].kind == .function) {
                    const kids = try r.childrenOf(t);
                    k.* = try r.column(kids[kids.len - 1]);
                    continue;
                }
            }
            if (di >= bir.decls.len) continue;
            const d = bir.decls[di];
            if (!d.kind.isValue()) continue;
            const annotation = d.annotation.unwrap() orelse continue;
            if (bir.instTag(annotation) != .type_fn) continue;
            const params = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(annotation).lhs))), Inst.Index);
            if (params.len != d.params) continue;
            switch (try r.fromBir(m, @fromBackingInt(@intCast(bir.instData(annotation).rhs)), &.{}, 0)) {
                .term => |t| k.* = try r.column(t),
                .wild, .unknown => {},
            }
        }
        slot.* = out;
    }
    r.results = results;

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
    // Every schema endpoint (`schema.md` §6): its values come from `Js.to`,
    // so its `Type` and its `Encoded` are wild, closed through their fields
    // like any wild type. A tagged one is a named type of no integer tags,
    // which the boundary's scan below takes; a record one is its record.
    for (in.types.entries, 0..) |e, i| {
        if (!e.schema_endpoint or e.kind != .alias) continue;
        const id: TypeId = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        if (e.arity != 0) {
            try r.param_endpoints.append(arena, id);
            continue;
        }
        switch (try r.named(id, &.{}, 0)) {
            .term => |t| try r.markWild(try r.repOf(t, 0)),
            .wild => {},
            .unknown => r.all_wild = true,
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
            for (r.param_endpoints.items) |id| try r.instancesOf(id, t);
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

/// What top-level function `decl` of module `m` returns: the key its own
/// arrow carries, which filters its return var.
pub fn declResult(r: *const RepKeys, m: Graph.Index, decl: u32) RepKey {
    if (m.int() >= r.results.len) return .wild;
    const out = r.results[m.int()];
    return if (decl < out.len) out[decl] else .wild;
}

/// Whether the checker found declaration `decl` of module `m` closed: its
/// type holds no variable and nothing wild (checker-v2.md §36), which is
/// when `Copy` may keep its body's keys.
pub fn declClosed(r: *const RepKeys, m: Graph.Index, decl: u32) bool {
    if (m.int() >= r.in.artifacts.len) return false;
    return r.in.artifacts[m.int()].declKey(decl) != .wild;
}

/// What the lambda `inst` of module `m` returns: its arrow's key.
pub fn lambdaResult(r: *const RepKeys, m: Graph.Index, inst: Inst.Index) RepKey {
    if (m.int() >= r.columns.len) return .wild;
    const row = r.in.artifacts[m.int()].instKey(inst) orelse return .wild;
    return r.columnOf(m, row.result);
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

/// The key a column holds for node `t`. A function type is wild: an arrow
/// is keyed by what it returns, the one thing its key filters, so a var of
/// function type holds arrows of any key.
fn column(r: *RepKeys, t: u32) Allocator.Error!RepKey {
    const rep = try r.repOf(t, 0);
    if (rep == wild_id or r.noSite(rep) or r.nodes.items[rep].kind == .function) return .wild;
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
            // A record schema endpoint's body is in its module's plan.
            if (e.schema_endpoint) return r.endpointTerm(id, args, depth + 1);
            if (e.module.int() >= r.in.birs.len) return .unknown;
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
    if (e.schema_endpoint) return r.closeTagged(id, kids);
    if (e.module.int() >= r.in.birs.len) {
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

// ---- Schema endpoints --------------------------------------------------------

/// The plan definition and term of endpoint `id`, if its module has a plan.
const EndpointAt = struct { plan: *const SchemaPlan, module: Graph.Index, def: SchemaPlan.Definition, term: Interface.TermIndex };

fn endpointAt(r: *const RepKeys, id: TypeId) ?EndpointAt {
    const e = r.in.types.entries[id.int()];
    if (e.module.int() >= r.in.plans.len) return null;
    const plan = &r.in.plans[e.module.int()];
    for (plan.definitions) |def| {
        if (def.decl != e.decl) continue;
        const program = r.in.types.ofSchemaDecl(e.module, e.decl, .type) == id;
        return .{ .plan = plan, .module = e.module, .def = def, .term = if (program) def.program_term else def.encoded_term };
    }
    return null;
}

/// A record endpoint applied to `args`: its plan term, canonical.
fn endpointTerm(r: *RepKeys, id: TypeId, args: []const u32, depth: u32) Allocator.Error!Conv {
    const at = r.endpointAt(id) orelse return .unknown;
    const env: Env = .{ .terms = &.{}, .nodes = args };
    const src = try r.planTerms(at.module);
    return r.fromTerm(&src, at.term, &env, depth);
}

/// What `var(i)` is where a plan term is read: a node (an endpoint's
/// argument), or, inside an alias's body, a term of the enclosing read.
const Env = struct {
    nodes: []const u32 = &.{},
    terms: []const Interface.TermIndex = &.{},
    parent: ?*const Env = null,
};

fn planIds(r: *RepKeys, module: Graph.Index) Allocator.Error![]const TypeId {
    if (r.plan_ids[module.int()]) |ids| return ids;
    const plan = &r.in.plans[module.int()];
    const ids = try r.in.arena.alloc(TypeId, plan.type_refs.len);
    for (plan.type_refs, ids) |ref, *slot| {
        slot.* = if (@backingInt(ref.module) < plan.symbols.len and @backingInt(ref.name) < plan.symbols.len)
            r.in.types.find(r.in.graph, ref.package, plan.symbols[@backingInt(ref.module)], plan.symbols[@backingInt(ref.name)])
        else
            .none;
    }
    r.plan_ids[module.int()] = ids;
    return ids;
}

/// Where interface terms are read: a module's plan, or its interface.
const Terms = struct {
    terms: std.MultiArrayList(Interface.Term).Slice,
    extra: []const u32,
    type_refs: []const Interface.TypeRef,
    symbols: []const Symbol,
    /// `type_refs` as this session's ids.
    ids: []const TypeId,

    fn range(src: *const Terms, start: u32) []const u32 {
        if (start >= src.extra.len) return &.{};
        const len = src.extra[start];
        const rest = src.extra[start + 1 ..];
        return if (len > rest.len) &.{} else rest[0..len];
    }
};

fn planTerms(r: *RepKeys, module: Graph.Index) Allocator.Error!Terms {
    std.debug.assert(module.int() < r.in.plans.len);
    const plan = &r.in.plans[module.int()];
    return .{ .terms = plan.terms, .extra = plan.type_extra, .type_refs = plan.type_refs, .symbols = plan.symbols, .ids = try r.planIds(module) };
}

fn ifaceTerms(r: *const RepKeys, module: Graph.Index) ?Terms {
    if (module.int() >= r.in.types.interfaces.len) return null;
    const iface = &r.in.types.interfaces[module.int()];
    return .{ .terms = iface.terms, .extra = iface.extra, .type_refs = iface.type_refs, .symbols = iface.symbols, .ids = r.in.types.refIds(module) };
}

/// A plan term, canonical as the checker keys it (checker-v2.md §36).
fn fromTerm(r: *RepKeys, src: *const Terms, index: Interface.TermIndex, env: *const Env, depth: u32) Allocator.Error!Conv {
    if (depth > max_depth or index == .none or index.int() >= src.terms.len) return .unknown;
    const t = src.terms.get(index.int());
    switch (t.tag) {
        .@"var" => {
            if (t.lhs < env.nodes.len) {
                const n = env.nodes[t.lhs];
                return if (n == wild_id) .wild else .{ .term = n };
            }
            if (t.lhs < env.terms.len) return r.fromTerm(src, env.terms[t.lhs], env.parent orelse return .unknown, depth + 1);
            return .unknown;
        },
        .unit => return .{ .term = try r.intern(.unit, 0, &.{}, &.{}) },
        .empty_record => return .{ .term = try r.intern(.record, 0, &.{}, &.{}) },
        .err => return .unknown,
        .func, .tuple => {
            const items = src.range(t.lhs);
            const extra: usize = if (t.tag == .func) 1 else 0;
            const kids = try r.in.arena.alloc(u32, items.len + extra);
            for (items, kids[0..items.len]) |item, *to| to.* = switch (try r.fromTerm(src, @fromBackingInt(@intCast(item)), env, depth + 1)) {
                .term => |x| x,
                else => |c| return c,
            };
            if (t.tag == .func) kids[items.len] = switch (try r.fromTerm(src, @fromBackingInt(@intCast(t.rhs)), env, depth + 1)) {
                .term => |x| x,
                else => |c| return c,
            };
            return .{ .term = try r.intern(if (t.tag == .func) .function else .tuple, 0, &.{}, kids) };
        },
        .app, .alias => {
            const ids = src.ids;
            const id: TypeId = if (t.lhs < ids.len) ids[t.lhs] else .none;
            const items = src.range(t.rhs);
            const args = try r.in.arena.alloc(u32, items.len);
            var wild = false;
            for (items, args) |item, *to| switch (try r.fromTerm(src, @fromBackingInt(@intCast(item)), env, depth + 1)) {
                .term => |x| to.* = x,
                .wild => {
                    wild = true;
                    to.* = wild_id;
                },
                .unknown => return .unknown,
            };
            // An alias is its row's body, read with its arguments: an
            // endpoint's own term is an alias naming the endpoint.
            if (t.tag == .alias and t.lhs < src.type_refs.len and src.type_refs[t.lhs].body != .none) {
                const inner: Env = .{ .nodes = args };
                return r.fromTerm(src, src.type_refs[t.lhs].body, &inner, depth + 1);
            }
            if (wild and !r.isAlias(id)) return .wild;
            return r.named(id, args, depth + 1);
        },
        .record => {
            const words = src.range(t.lhs);
            const Pair = struct { name: Symbol, term: u32 };
            var pairs: std.ArrayList(Pair) = .empty;
            var i: usize = 0;
            while (i + 1 < words.len) : (i += 2) {
                if (words[i] >= src.symbols.len) return .unknown;
                const v = switch (try r.fromTerm(src, @fromBackingInt(@intCast(words[i + 1])), env, depth + 1)) {
                    .term => |x| x,
                    else => |c| return c,
                };
                try pairs.append(r.in.arena, .{ .name = src.symbols[words[i]], .term = v });
            }
            // The row: closed, or a record the read binds.
            switch (try r.fromTerm(src, @fromBackingInt(@intCast(t.rhs)), env, depth + 1)) {
                .term => |row| {
                    if (r.nodes.items[row].kind != .record) return .unknown;
                    const kids = try r.childrenOf(row);
                    const names = try r.labelsOf(row);
                    for (names, kids) |name, kid| try pairs.append(r.in.arena, .{ .name = name, .term = kid });
                },
                else => |c| return c,
            }
            std.mem.sort(Pair, pairs.items, r.in.interner, struct {
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
        },
    }
}

/// Whether node `t` is an instance of the record endpoint with parameters
/// `id`; if so it is wild. Its instantiations are not listed anywhere, so
/// every node of the table is matched against the endpoint's plan term,
/// each parameter bound to the node it meets.
fn instancesOf(r: *RepKeys, id: TypeId, t: u32) Allocator.Error!void {
    if (r.nodes.items[t].kind != .record) return;
    const at = r.endpointAt(id) orelse {
        r.all_wild = true;
        return;
    };
    const binds = try r.in.arena.alloc(u32, r.in.types.entries[id.int()].arity);
    @memset(binds, unset);
    const env: Env = .{};
    const src = try r.planTerms(at.module);
    switch (try r.match(&src, at.term, &env, binds, t, 0)) {
        .yes => try r.markWild(try r.repOf(t, 0)),
        .no => {},
        .cannot => r.all_wild = true,
    }
}

const Match = enum { yes, no, cannot };

/// Whether plan term `index` (its parameters `binds`, bound as met) is node
/// `t`, both compared as representations.
fn match(r: *RepKeys, src: *const Terms, index: Interface.TermIndex, env: *const Env, binds: []u32, t: u32, depth: u32) Allocator.Error!Match {
    if (depth > max_depth or index == .none or index.int() >= src.terms.len) return .cannot;
    const term = src.terms.get(index.int());
    const n = r.nodes.items[t];
    switch (term.tag) {
        .@"var" => {
            if (env.parent) |outer| {
                if (term.lhs >= env.terms.len) return .cannot;
                return r.match(src, env.terms[term.lhs], outer, binds, t, depth + 1);
            }
            if (term.lhs >= binds.len) return .cannot;
            const rep = try r.repOf(t, 0);
            if (binds[term.lhs] == unset) {
                binds[term.lhs] = rep;
                return .yes;
            }
            return if (binds[term.lhs] == rep) .yes else .no;
        },
        .unit => return if (n.kind == .unit) .yes else .no,
        .err => return .cannot,
        .empty_record => return if (n.kind == .record and n.len == 0) .yes else .no,
        .func, .tuple => {
            const want: Kind = if (term.tag == .func) .function else .tuple;
            const items = src.range(term.lhs);
            const extra: usize = if (term.tag == .func) 1 else 0;
            if (n.kind != want or n.len != items.len + extra) return .no;
            const kids = try r.childrenOf(t);
            for (items, kids[0..items.len]) |item, kid| switch (try r.match(src, @fromBackingInt(@intCast(item)), env, binds, kid, depth + 1)) {
                .yes => {},
                else => |m| return m,
            };
            if (term.tag == .func) return r.match(src, @fromBackingInt(@intCast(term.rhs)), env, binds, kids[items.len], depth + 1);
            return .yes;
        },
        .app => {
            const ids = src.ids;
            const id: TypeId = if (term.lhs < ids.len) ids[term.lhs] else .none;
            if (id == .none) return .cannot;
            // A type that is its field, or a record endpoint, is not the
            // named node it would be written as.
            const kind = r.in.types.entries[id.int()].kind;
            if (r.unboxedField(id) != null or (kind != .adt and kind != .foreign)) return .cannot;
            const items = src.range(term.rhs);
            if (n.kind != .named or n.value != @backingInt(id) or n.len != items.len) return .no;
            const kids = try r.childrenOf(t);
            for (items, kids) |item, kid| switch (try r.match(src, @fromBackingInt(@intCast(item)), env, binds, kid, depth + 1)) {
                .yes => {},
                else => |m| return m,
            };
            return .yes;
        },
        .alias => {
            const ids = src.ids;
            if (term.lhs >= src.type_refs.len or term.lhs >= ids.len) return .cannot;
            const body = src.type_refs[term.lhs].body;
            if (body == .none) return .cannot;
            const items = src.range(term.rhs);
            const args = try r.in.arena.alloc(Interface.TermIndex, items.len);
            for (items, args) |item, *a| a.* = @fromBackingInt(@intCast(item));
            const inner: Env = .{ .terms = args, .parent = env };
            return r.match(src, body, &inner, binds, t, depth + 1);
        },
        .record => {
            if (n.kind != .record) return .no;
            // Only a closed row: the endpoint's own fields are the record.
            if (term.rhs >= src.terms.len) return .cannot;
            const row = src.terms.get(term.rhs);
            if (row.tag != .empty_record) return .cannot;
            const words = src.range(term.lhs);
            if (words.len / 2 != n.len) return .no;
            const names = try r.labelsOf(t);
            const kids = try r.childrenOf(t);
            var i: usize = 0;
            while (i + 1 < words.len) : (i += 2) {
                if (words[i] >= src.symbols.len) return .cannot;
                const label = src.symbols[words[i]];
                const at = std.mem.indexOfScalar(Symbol, names, label) orelse return .no;
                switch (try r.match(src, @fromBackingInt(@intCast(words[i + 1])), env, binds, kids[at], depth + 1)) {
                    .yes => {},
                    else => |m| return m,
                }
            }
            return .yes;
        },
    }
}

/// A tagged endpoint's payloads into the wild set. Its constructors are its
/// plan's variants: a payload that is a primitive makes no site, one that is
/// another schema is that schema's endpoint, wild in its turn, and one that
/// is a parameter is an argument, which `closeThrough` made wild already.
/// Any other payload is a type this file cannot write as the checker does,
/// and every key is wild.
fn closeTagged(r: *RepKeys, id: TypeId, args: []const u32) Allocator.Error!void {
    // A schema the interface lists has its constructors' schemes there:
    // each parameter of one is a payload, read exactly.
    switch (try r.closeTaggedSchemes(id, args)) {
        .yes => return,
        .no => {},
        .cannot => {
            r.all_wild = true;
            return;
        },
    }
    const at = r.endpointAt(id) orelse {
        r.all_wild = true;
        return;
    };
    const plan = at.plan;
    if (@backingInt(at.def.root) >= plan.nodes.len) {
        r.all_wild = true;
        return;
    }
    const root = plan.nodes.get(@backingInt(at.def.root));
    if (root.tag != .tagged) {
        r.all_wild = true;
        return;
    }
    for (planExtra(plan, root.rhs)) |vi| {
        if (vi >= plan.variants.len) {
            r.all_wild = true;
            return;
        }
        const payload = plan.variants[vi].payload.unwrap() orelse continue;
        if (@backingInt(payload) >= plan.nodes.len) {
            r.all_wild = true;
            return;
        }
        const node = plan.nodes.get(@backingInt(payload));
        switch (node.tag) {
            .primitive, .parameter => {},
            .reference => if (planExtra(plan, node.rhs).len != 0) {
                r.all_wild = true;
                return;
            },
            else => {
                r.all_wild = true;
                return;
            },
        }
    }
}

/// The index in `module`'s interface of the schema it declares at `decl`,
/// or null for a private one (`Types.schema_iface_by_decl`).
fn schemaIfaceOf(r: *const RepKeys, module: Graph.Index, decl: Bir.DeclIndex) ?u32 {
    const types = r.in.types;
    if (module.int() + 1 >= types.decl_offsets.len) return null;
    const base = types.decl_offsets[module.int()];
    const limit = types.decl_offsets[module.int() + 1];
    if (decl.int() >= limit - base) return null;
    const si = types.schema_iface_by_decl[base + decl.int()];
    return if (si == Types.no_schema) null else si;
}

/// A tagged endpoint's payloads from its constructors' interface schemes:
/// `.no` when the interface does not list the schema (a private one).
fn closeTaggedSchemes(r: *RepKeys, id: TypeId, args: []const u32) Allocator.Error!Match {
    const e = r.in.types.entries[id.int()];
    const at = r.schemaIfaceOf(e.module, e.decl) orelse return .no;
    const src = r.ifaceTerms(e.module) orelse return .no;
    const iface = &r.in.types.interfaces[e.module.int()];
    if (at >= iface.schemas.len) return .cannot;
    const schema = iface.schemas[at];
    const program = r.in.types.ofSchemaDecl(e.module, e.decl, .type) == id;
    const start = if (program) schema.program_ctors_start else schema.encoded_ctors_start;
    const end = if (program) schema.program_ctors_end else schema.encoded_ctors_end;
    if (start > end or end > iface.schema_ctors.len) return .cannot;
    for (iface.schema_ctors[start..end]) |ctor| {
        if (ctor.arity == 0) continue;
        const scheme = iface.scheme(ctor.scheme);
        if (scheme.body == .none) return .cannot;
        const f = iface.term(scheme.body);
        if (f.tag != .func) return .cannot;
        // The quantifiers, by where the result names them: the endpoint's
        // arguments.
        const binds = try r.in.arena.alloc(u32, scheme.quantified_count);
        @memset(binds, wild_id);
        const result = iface.term(@fromBackingInt(@intCast(f.rhs)));
        if (result.tag != .app and result.tag != .alias) return .cannot;
        const result_args = src.range(result.rhs);
        if (result_args.len != args.len) return .cannot;
        for (result_args, args) |word, arg| {
            const v = iface.term(@fromBackingInt(@intCast(word)));
            if (v.tag != .@"var" or v.lhs >= binds.len) return .cannot;
            binds[v.lhs] = arg;
        }
        const env: Env = .{ .nodes = binds };
        for (src.range(f.lhs)) |param| switch (try r.fromTerm(&src, @fromBackingInt(@intCast(param)), &env, 0)) {
            .term => |t| try r.markWild(try r.repOf(t, 0)),
            .wild => {},
            .unknown => return .cannot,
        };
    }
    return .yes;
}

fn planExtra(plan: *const SchemaPlan, start: u32) []const u32 {
    if (start >= plan.extra.len) return &.{};
    const len = plan.extra[start];
    const rest = plan.extra[start + 1 ..];
    return if (len > rest.len) &.{} else rest[0..len];
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
