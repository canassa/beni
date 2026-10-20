//! The type-key artifact (checker-v2.md §36; `backend.md` §3, *Amended
//! 2026-10-20*, and §9, *Declared-type filtering of fact 3*): one key per
//! `Bir` local and per allocating instruction, the canonical form of its
//! solved type when that type is closed, `wild` when it is not; the closed
//! types the module adds to fact 3's wild set; and, for every module, which
//! quantifiers of each declaration cross into JavaScript. Made once per
//! module, while its store is alive and before P8 publishes the crossing
//! bits, and carried in the cache entry's `type_keys` section
//! (`cache/type_keys_bytes.zig`), so a module installed from the cache has
//! the keys a fresh check gives it.
//!
//! **What a key is.** A node of the module's `nodes`: a named type and its
//! argument keys, a record by its (label, key) pairs sorted by the label's
//! TEXT, a function's
//! parameters and result, a tuple's elements, `⊤`. An alias is its
//! expansion, so `type alias Point = { x : Int, y : Int }` and the record
//! written out are one node. Nodes are interned in this module: every child
//! precedes its owner and no node is written twice.
//!
//! **What is wild** (§36): a type that holds a `flex`, a `rigid` or an `err`
//! — a polymorphic or unsolved one; a record whose row is open; a `foreign
//! type` other than the four primitives and `List`, whose representation is
//! the host's (`Js.Value`, `Js.Ref`, the schema `Value`, a fiber, `Html`);
//! and a function type or application with a wild part.
//!
//! **The wild set's local half** (`wild`): every closed type a `Js.from` or a
//! `Js.to` of this module is instantiated at, every closed type it
//! instantiates a crossing quantifier at, and the parts of both; and the
//! subject type of every `?`. The merge closes the set through named types'
//! bodies and across modules.
//!
//! **Crossing quantifiers.** A quantifier of a declaration crosses when its
//! body instantiates `Js.from` at a type that mentions it, or instantiates a
//! crossing quantifier of a callee at one: of an import (the interface's
//! bit, `Instantiate.crossing`), of a declaration of this module or of a
//! `let` function (to a fixpoint over the module's own references). A type
//! variable met there that is not a quantifier this walk can name — a
//! rigid variable of an annotated `let`, say — makes every quantifier of
//! the enclosing declaration and of its `let` functions cross: more wild,
//! never less.
//!
//! **Determinism** (CLAUDE.md rule 5). Nodes are interned in a walk over the
//! locals, then the instructions, then the wild set's sources, each in index
//! order, and a record's fields are ordered by text, never by symbol id: the
//! artifact is a function of the module's input, and a module checked in
//! another session writes the same bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("Dispatch.zig");
const Instantiate = @import("Instantiate.zig");
const Schemes = @import("Schemes.zig");
const Solve = @import("Solve.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;

pub const Error = Allocator.Error;

/// A closed type's canonical form in its module's `nodes`, or `wild`.
pub const TypeKey = enum(u32) {
    wild = std.math.maxInt(u32),
    _,

    pub fn int(k: TypeKey) u32 {
        return @backingInt(k);
    }
};

/// One node of a canonical closed type.
pub const KeyNode = struct {
    kind: Kind,
    /// Children, a range of `args`: a named type's arguments; a record's
    /// field types, its fields sorted by text; a function's parameters then
    /// its result; a tuple's elements.
    args: Range = .{},
    /// `named`: the `TypeId`. `record`: where its fields' labels start in
    /// `labels`, one per child. Else 0.
    value: u32 = 0,

    pub const Kind = enum(u8) { named, record, function, tuple, unit };
};

pub const Range = struct { start: u32 = 0, len: u32 = 0 };

/// The keys of an allocating instruction: a record literal or update, a
/// constructor application, a tuple, a list literal or a lambda.
pub const InstKey = struct {
    inst: Bir.Inst.Index,
    /// The instruction's own type.
    key: TypeKey,
    /// A lambda's result type; `wild` for every other instruction.
    result: TypeKey = .wild,
};

/// One module's artifact, owned by `gpa`. Empty for a module whose keys are
/// all wild: core, a platform, a module checked silently or with an error.
pub const Artifact = struct {
    nodes: []const KeyNode = &.{},
    /// What every `KeyNode.args` ranges over; never `wild`.
    args: []const TypeKey = &.{},
    /// Every record node's field labels (`KeyNode.value`).
    labels: []const InternPool.Symbol = &.{},
    /// One per `Bir.locals` entry, or empty.
    locals: []const TypeKey = &.{},
    /// One per `Bir.decls` entry, or empty: a value declaration's scheme when
    /// it is closed (no quantifier), so a top-level function's return var
    /// has a filter; `wild` for every other declaration.
    decls: []const TypeKey = &.{},
    /// Ascending by instruction.
    insts: []const InstKey = &.{},
    /// What the module adds to fact 3's wild set, ascending, no key twice.
    wild: []const TypeKey = &.{},

    pub const empty: Artifact = .{};

    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        gpa.free(a.nodes);
        gpa.free(a.args);
        gpa.free(a.labels);
        gpa.free(a.locals);
        gpa.free(a.decls);
        gpa.free(a.insts);
        gpa.free(a.wild);
        a.* = .empty;
    }

    /// The key of declaration `decl`: `wild` when the module has none.
    pub fn declKey(a: *const Artifact, decl: u32) TypeKey {
        return if (decl < a.decls.len) a.decls[decl] else .wild;
    }

    /// The key of local `local`: `wild` when the module has none.
    pub fn localKey(a: *const Artifact, local: u32) TypeKey {
        return if (local < a.locals.len) a.locals[local] else .wild;
    }

    /// The keys of the allocating instruction `inst`, if it has a row.
    pub fn instKey(a: *const Artifact, inst: Bir.Inst.Index) ?InstKey {
        var lo: usize = 0;
        var hi: usize = a.insts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = a.insts[mid].inst;
            if (at == inst) return a.insts[mid];
            if (at.int() < inst.int()) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// A node's children.
    pub fn children(a: *const Artifact, key: TypeKey) []const TypeKey {
        const n = a.nodes[key.int()];
        return a.args[n.args.start..][0..n.args.len];
    }

    /// A record node's field labels, one per child.
    pub fn labelsOf(a: *const Artifact, key: TypeKey) []const InternPool.Symbol {
        const n = a.nodes[key.int()];
        if (n.kind != .record) return &.{};
        return a.labels[n.value..][0..n.args.len];
    }
};

pub const Input = struct {
    gpa: Allocator,
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    bir: *const Bir,
    local_type: []const Var.Optional,
    inst_type: []const Var.Optional,
    decl_scheme: []const Var.Optional,
    casts: []const Solve.Cast,
    /// Every crossing quantifier of an import this module instantiated.
    uses: []const Instantiate.CrossingUse,
    dispatch: *const Dispatch,
    /// Whether to make the keys: an app module (§36). The crossing bits are
    /// made for every module.
    keyed: bool,
};

pub const Output = struct {
    /// Owned by `gpa`.
    artifact: Artifact,
    /// Per declaration, its crossing quantifiers in scheme order, ascending;
    /// owned by `scratch`.
    crossing: []const []const u16,
};

pub fn build(in: Input) Error!Output {
    var b: Builder = .{
        .gpa = in.scratch, // the builder's lists die with the module's scratch
        .scratch = in.scratch,
        .store = in.store,
        .types = in.types,
        .interner = in.interner,
        .memo = try in.scratch.alloc(u32, in.store.count()),
        .named0 = try in.scratch.alloc(u32, in.types.count()),
        .alias0 = try in.scratch.alloc(u32, in.types.count()),
    };
    @memset(b.memo, unset);
    @memset(b.named0, unset);
    @memset(b.alias0, unset);
    defer b.deinit();

    var artifact: Artifact = .empty;
    errdefer artifact.deinit(in.gpa);
    if (in.keyed) {
        // Room for a module's usual types, so the table rarely grows.
        try b.map.ensureTotalCapacityContext(in.scratch, 64, .{ .b = &b });
        const locals = try in.gpa.alloc(TypeKey, in.bir.locals.len);
        artifact.locals = locals;
        for (locals, 0..) |*k, i| {
            k.* = if (i < in.local_type.len) if (in.local_type[i].unwrap()) |v| try b.keyOf(v) else .wild else .wild;
        }
        var insts: std.ArrayList(InstKey) = .empty;
        errdefer insts.deinit(in.scratch);
        const tags = in.bir.insts.items(.tag);
        for (tags, 0..) |tag, i| {
            if (!allocating[@backingInt(tag)] and !(tag == .call and isCtorCall(in.bir, i))) continue;
            const v = if (i < in.inst_type.len) in.inst_type[i].unwrap() else null;
            var row: InstKey = .{ .inst = @fromBackingInt(@intCast(i)), .key = .wild };
            if (v) |t| {
                row.key = try b.keyOf(t);
                if (tag == .lambda) if (Walk.function(in.store, t)) |f| {
                    row.result = try b.keyOf(f.result);
                };
            }
            try insts.append(in.scratch, row);
        }
        artifact.insts = try in.gpa.dupe(InstKey, insts.items);
        // Each value declaration's scheme: a quantifier is a `flex` at the
        // generalised rank, so a polymorphic scheme is wild.
        const decls = try in.gpa.alloc(TypeKey, in.bir.decls.len);
        artifact.decls = decls;
        for (decls, in.bir.decls, 0..) |*k, d, i| {
            k.* = .wild;
            if (!d.kind.isValue() or i >= in.decl_scheme.len) continue;
            if (in.decl_scheme[i].unwrap()) |v| k.* = try b.keyOf(v);
        }
    }

    var c: Crossing = .{ .in = in, .b = &b };
    defer c.deinit();
    try c.run();

    if (in.keyed) {
        // The subject of every `?`: its failure is returned unchanged at the
        // enclosing function's result type (`backend.md` §9).
        for (in.dispatch.tries) |t| {
            const subject = in.bir.instData(t.inst).lhs;
            if (subject >= in.inst_type.len) continue;
            const v = in.inst_type[subject].unwrap() orelse continue;
            const k = try b.keyOf(v);
            if (k != .wild) try c.wild.append(in.scratch, k);
        }
        std.mem.sort(TypeKey, c.wild.items, {}, struct {
            fn lessThan(_: void, x: TypeKey, y: TypeKey) bool {
                return x.int() < y.int();
            }
        }.lessThan);
        var kept: usize = 0;
        for (c.wild.items) |k| {
            if (kept != 0 and c.wild.items[kept - 1] == k) continue;
            c.wild.items[kept] = k;
            kept += 1;
        }
        artifact.wild = try in.gpa.dupe(TypeKey, c.wild.items[0..kept]);
        artifact.nodes = try in.gpa.dupe(KeyNode, b.nodes.items);
        artifact.args = try in.gpa.dupe(TypeKey, b.args.items);
        artifact.labels = try in.gpa.dupe(InternPool.Symbol, b.labels.items);
    }
    return .{ .artifact = artifact, .crossing = try c.published() };
}

/// The instructions that make a value with an identity of its own, by tag;
/// a constructor application is a `call` of a constructor.
const allocating = Bir.Inst.Tag.set(&.{ .record, .record_update, .tuple, .list, .lambda });

const ctor_tags = Bir.Inst.Tag.set(&.{ .ctor, .ext_ctor, .schema_ctor_top, .ext_schema_ctor });

fn isCtorCall(bir: *const Bir, i: usize) bool {
    const callee = bir.instData(@fromBackingInt(@intCast(i))).lhs;
    if (callee >= bir.insts.len) return false;
    return ctor_tags[@backingInt(bir.instTag(@fromBackingInt(@intCast(callee))))];
}

/// `memo`'s "not visited", and "on the stack": a type is acyclic through its
/// structure (`Unify`'s occurs check, checker-v2.md §8.2), so a variable met
/// while it is being keyed is a compiler bug, and wild is the safe answer.
const unset: u32 = std.math.maxInt(u32) - 1;
const pending: u32 = std.math.maxInt(u32) - 2;

const Builder = struct {
    gpa: Allocator,
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    /// Per store variable (a root), its key, `unset` or `pending`.
    memo: []u32,
    /// Per `TypeId`, the key of the type of no arguments, or `unset`.
    named0: []u32,
    /// Per `TypeId`, the key of an alias of no arguments, or `unset`.
    alias0: []u32,
    nodes: std.ArrayList(KeyNode) = .empty,
    args: std.ArrayList(TypeKey) = .empty,
    map: std.HashMapUnmanaged(Interned, void, NodeCtx, std.hash_map.default_max_load_percentage) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    /// One node's words while it is interned: kind, value, children.
    words: std.ArrayList(u32) = .empty,
    fields: std.ArrayList(TypeStore.Field) = .empty,
    keyed: std.ArrayList(Keyed) = .empty,
    names: std.ArrayList(InternPool.Symbol) = .empty,
    /// Every record node's field labels, in text order (`KeyNode.value`).
    labels: std.ArrayList(InternPool.Symbol) = .empty,
    /// One per node: its hash, which the table rehashes by.
    hashes: std.ArrayList(u64) = .empty,

    const Frame = struct { v: Var, expanded: bool };
    const Keyed = struct { name: InternPool.Symbol, key: TypeKey };
    const Interned = struct { id: u32 };

    const NodeCtx = struct {
        b: *const Builder,
        pub fn hash(c: NodeCtx, k: Interned) u64 {
            return c.b.hashes.items[k.id];
        }
        pub fn eql(_: NodeCtx, a: Interned, b: Interned) bool {
            return a.id == b.id;
        }
    };

    /// A node being looked up, with its hash.
    const Candidate = struct { h: u64, kind: KeyNode.Kind, value: u32, children: []const TypeKey, names: []const InternPool.Symbol = &.{} };

    const Adapter = struct {
        b: *const Builder,
        pub fn hash(_: Adapter, c: Candidate) u64 {
            return c.h;
        }
        pub fn eql(a: Adapter, c: Candidate, k: Interned) bool {
            if (a.b.hashes.items[k.id] != c.h) return false;
            const n = a.b.nodes.items[k.id];
            if (n.kind != c.kind or n.args.len != c.children.len) return false;
            if (c.kind == .record) {
                if (!std.mem.eql(InternPool.Symbol, a.b.labels.items[n.value..][0..n.args.len], c.names)) return false;
            } else if (n.value != c.value) return false;
            return std.mem.eql(TypeKey, a.b.args.items[n.args.start..][0..n.args.len], c.children);
        }
    };

    /// A multiply-rotate mix over the node's words: the nodes are a few words
    /// each, and a byte hash was most of the walk's cost.
    fn hashNode(kind: u32, value: u32, children: []const TypeKey) u64 {
        var h: u64 = mix(mix(0x7e9e, kind), value);
        for (children) |c| h = mix(h, c.int());
        return h ^ (h >> 29);
    }

    inline fn mix(h: u64, w: u32) u64 {
        return std.math.rotl(u64, (h ^ w) *% 0x9E3779B97F4A7C15, 23);
    }

    fn deinit(b: *Builder) void {
        b.nodes.deinit(b.gpa);
        b.args.deinit(b.gpa);
        b.map.deinit(b.gpa);
        b.stack.deinit(b.scratch);
        b.words.deinit(b.scratch);
        b.fields.deinit(b.scratch);
        b.keyed.deinit(b.scratch);
        b.names.deinit(b.scratch);
        b.labels.deinit(b.gpa);
        b.hashes.deinit(b.gpa);
    }

    /// The key of `v`'s type, interning every node it needs. Iterative: a
    /// type is as deep as the program makes it.
    fn keyOf(b: *Builder, v: Var) Error!TypeKey {
        const root = b.store.find(v);
        if (b.memo[root.int()] != unset and b.memo[root.int()] != pending) return @fromBackingInt(b.memo[root.int()]);
        if (try b.leaf(root)) |k| {
            b.memo[root.int()] = k.int();
            return k;
        }
        b.stack.clearRetainingCapacity();
        try b.stack.append(b.scratch, .{ .v = root, .expanded = false });
        while (b.stack.items.len != 0) {
            const top = &b.stack.items[b.stack.items.len - 1];
            const r = top.v;
            if (!top.expanded) {
                switch (b.memo[r.int()]) {
                    unset => {},
                    // Met again while it is being keyed: see `pending`.
                    pending => {
                        b.memo[r.int()] = TypeKey.wild.int();
                        _ = b.stack.pop();
                        continue;
                    },
                    else => {
                        _ = b.stack.pop();
                        continue;
                    },
                }
                top.expanded = true;
                b.memo[r.int()] = pending;
                // Children first; `top` may move as the stack grows.
                const before = b.stack.items.len;
                try b.pushChildren(r);
                if (b.stack.items.len == before) {
                    b.memo[r.int()] = (try b.finish(r)).int();
                    _ = b.stack.pop();
                }
                continue;
            }
            b.memo[r.int()] = (try b.finish(r)).int();
            _ = b.stack.pop();
        }
        return @fromBackingInt(b.memo[root.int()]);
    }

    fn pushChild(b: *Builder, v: Var) Error!void {
        const r = b.store.find(v);
        const m = b.memo[r.int()];
        if (m != unset and m != pending) return;
        if (try b.leaf(r)) |k| {
            b.memo[r.int()] = k.int();
            return;
        }
        try b.stack.append(b.scratch, .{ .v = r, .expanded = false });
    }

    /// The key of a type with no children to key first, made without a
    /// frame: most of what a walk meets is `Int` or a type variable.
    fn leaf(b: *Builder, r: Var) Error!?TypeKey {
        return switch (b.store.content(r)) {
            .flex, .rigid, .err => .wild,
            .structure => |s| switch (s) {
                .app => |a| if (a.args.len != 0) null else if (!b.keyedNominal(a.type)) .wild else try b.nullary(a.type),
                .unit => try b.intern(.unit, 0, &.{}),
                else => null,
            },
            // An alias of no arguments is one type wherever it is used:
            // its expansion is keyed once.
            .alias => |a| if (a.args.len == 0 and a.type.int() < b.alias0.len and b.alias0[a.type.int()] != unset) @as(TypeKey, @fromBackingInt(b.alias0[a.type.int()])) else null,
        };
    }

    /// The children `finish` reads, pushed unless already keyed. A wild node
    /// needs none.
    fn pushChildren(b: *Builder, r: Var) Error!void {
        const store = b.store;
        switch (store.content(r)) {
            .flex, .rigid, .err => {},
            .alias => |a| try b.pushChild(a.actual),
            .structure => |s| switch (s) {
                .unit, .empty_record => {},
                .func => |f| {
                    for (store.vars(f.params)) |p| try b.pushChild(p);
                    try b.pushChild(f.result);
                },
                .app => |a| if (b.keyedNominal(a.type)) for (store.vars(a.args)) |x| try b.pushChild(x),
                .tuple => |t| for (store.vars(t)) |x| try b.pushChild(x),
                .record => |rec| {
                    b.fields.clearRetainingCapacity();
                    if (!try b.closedRow(rec)) return;
                    // By text, so the nodes a walk makes are numbered by the
                    // input and never by a symbol's id (§36).
                    byText(TypeStore.Field, b.interner, b.fields.items);
                    for (b.fields.items) |f| try b.pushChild(f.value);
                },
            },
        }
    }

    /// Whether a named type is keyed by name, or is a host value (§36).
    fn keyedNominal(b: *const Builder, id: TypeStore.TypeId) bool {
        if (id == .none) return false;
        const e = b.types.entry(id);
        if (e.kind != .foreign) return true;
        const wk = b.types.well_known;
        return id == wk.int or id == wk.float or id == wk.char or id == wk.string or id == wk.list;
    }

    /// The fields of a record's whole row into `fields`, and whether the row
    /// is closed.
    fn closedRow(b: *Builder, rec: TypeStore.Structure.Record) Error!bool {
        const store = b.store;
        try b.fields.appendSlice(b.scratch, store.fields(rec.fields));
        var ext = rec.ext;
        var links: u32 = 0;
        while (true) {
            links += 1;
            if (links > store.count()) return false;
            const root = store.find(ext);
            switch (store.content(root)) {
                .alias => |a| ext = a.actual,
                .structure => |s| switch (s) {
                    .record => |r| {
                        try b.fields.appendSlice(b.scratch, store.fields(r.fields));
                        ext = r.ext;
                    },
                    .empty_record => return true,
                    else => return false,
                },
                else => return false,
            }
        }
    }

    fn childKey(b: *Builder, v: Var) TypeKey {
        const m = b.memo[b.store.find(v).int()];
        if (m == unset or m == pending) return .wild;
        return @fromBackingInt(m);
    }

    /// `r`'s key, its children keyed.
    fn finish(b: *Builder, r: Var) Error!TypeKey {
        const store = b.store;
        switch (store.content(r)) {
            .flex, .rigid, .err => return .wild,
            .alias => |a| {
                const k = b.childKey(a.actual);
                if (a.args.len == 0 and a.type.int() < b.alias0.len) b.alias0[a.type.int()] = k.int();
                return k;
            },
            .structure => |s| switch (s) {
                .unit => return b.intern(.unit, 0, &.{}),
                .empty_record => return b.intern(.record, 0, &.{}),
                .func => |f| {
                    b.words.clearRetainingCapacity();
                    for (store.vars(f.params)) |p| {
                        const k = b.childKey(p);
                        if (k == .wild) return .wild;
                        try b.words.append(b.scratch, k.int());
                    }
                    const res = b.childKey(f.result);
                    if (res == .wild) return .wild;
                    try b.words.append(b.scratch, res.int());
                    return b.internWords(.function, 0);
                },
                .app => |a| {
                    if (!b.keyedNominal(a.type)) return .wild;
                    // A type of no arguments, by far the most common node,
                    // is one table read.
                    if (a.args.len == 0) return b.nullary(a.type);
                    b.words.clearRetainingCapacity();
                    for (store.vars(a.args)) |x| {
                        const k = b.childKey(x);
                        if (k == .wild) return .wild;
                        try b.words.append(b.scratch, k.int());
                    }
                    return b.internWords(.named, a.type.int());
                },
                .tuple => |t| {
                    b.words.clearRetainingCapacity();
                    for (store.vars(t)) |x| {
                        const k = b.childKey(x);
                        if (k == .wild) return .wild;
                        try b.words.append(b.scratch, k.int());
                    }
                    return b.internWords(.tuple, 0);
                },
                .record => |rec| {
                    b.fields.clearRetainingCapacity();
                    if (!try b.closedRow(rec)) return .wild;
                    b.keyed.clearRetainingCapacity();
                    for (b.fields.items) |f| {
                        const k = b.childKey(f.value);
                        if (k == .wild) return .wild;
                        try b.keyed.append(b.scratch, .{ .name = f.name, .key = k });
                    }
                    // By text: a symbol's id is the session's (§36).
                    byText(Keyed, b.interner, b.keyed.items);
                    b.words.clearRetainingCapacity();
                    b.names.clearRetainingCapacity();
                    for (b.keyed.items) |f| {
                        try b.words.append(b.scratch, f.key.int());
                        try b.names.append(b.scratch, f.name);
                    }
                    return b.internLabelled(@ptrCast(b.words.items), b.names.items);
                },
            },
        }
    }

    /// The key of a named type of no arguments.
    fn nullary(b: *Builder, id: TypeStore.TypeId) Error!TypeKey {
        const slot = &b.named0[id.int()];
        if (slot.* == unset) slot.* = (try b.intern(.named, id.int(), &.{})).int();
        return @fromBackingInt(slot.*);
    }

    /// Intern `words` (the children) as a node of `kind` and `value`.
    fn internWords(b: *Builder, kind: KeyNode.Kind, value: u32) Error!TypeKey {
        // `intern` never writes `words`, so the children may stay there.
        return b.intern(kind, value, @ptrCast(b.words.items));
    }

    fn intern(b: *Builder, kind: KeyNode.Kind, value: u32, children: []const TypeKey) Error!TypeKey {
        return b.internCandidate(.{ .h = hashNode(@backingInt(kind), value, children), .kind = kind, .value = value, .children = children });
    }

    /// A record: its field keys and their labels, in the labels' text order.
    /// Its `value` is where its labels start in `labels`, which is not part
    /// of what the node is.
    fn internLabelled(b: *Builder, children: []const TypeKey, names: []const InternPool.Symbol) Error!TypeKey {
        var h = hashNode(@backingInt(KeyNode.Kind.record), 0, children);
        for (names) |n| h = mix(h, @backingInt(n));
        return b.internCandidate(.{ .h = h, .kind = .record, .value = @intCast(b.labels.items.len), .children = children, .names = names });
    }

    fn internCandidate(b: *Builder, candidate: Candidate) Error!TypeKey {
        const gop = try b.map.getOrPutContextAdapted(b.gpa, candidate, Adapter{ .b = b }, NodeCtx{ .b = b });
        if (gop.found_existing) return @fromBackingInt(gop.key_ptr.id);
        const id: u32 = @intCast(b.nodes.items.len);
        const start: u32 = @intCast(b.args.items.len);
        try b.args.appendSlice(b.gpa, candidate.children);
        try b.nodes.append(b.gpa, .{ .kind = candidate.kind, .args = .{ .start = start, .len = @intCast(candidate.children.len) }, .value = candidate.value });
        if (candidate.kind == .record) try b.labels.appendSlice(b.gpa, candidate.names);
        try b.hashes.append(b.gpa, candidate.h);
        gop.key_ptr.* = .{ .id = id };
        return @fromBackingInt(id);
    }
};

/// The crossing quantifiers of the module's declarations and `let`
/// functions, to a fixpoint, and the wild set's closed types (§36).
const Crossing = struct {
    in: Input,
    b: *Builder,
    /// One per declaration, then one per `Bir` local: made when first asked.
    owners: []Owner = &.{},
    wild: std.ArrayList(TypeKey) = .empty,
    changed: bool = false,
    todo: std.ArrayList(Var) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    zip_stack: std.ArrayList(Pair) = .empty,
    fields: std.ArrayList(TypeStore.Field) = .empty,
    other: std.ArrayList(TypeStore.Field) = .empty,
    refs: std.ArrayList(Ref) = .empty,

    const Owner = struct {
        made: bool = false,
        /// The quantifiers, in the scheme's order.
        order: []const Var = &.{},
        crossing: []bool = &.{},
        /// Every quantifier crosses.
        all: bool = false,
        /// Grows whenever a bit is set: what a reference compares.
        version: u32 = 0,

        fn any(o: *const Owner) bool {
            if (o.all) return true;
            for (o.crossing) |x| if (x) return true;
            return false;
        }

        fn crosses(o: *const Owner, q: usize) bool {
            return o.all or (q < o.crossing.len and o.crossing[q]);
        }
    };

    /// A scheme node and the instance node at the same place; `q` is the
    /// quantifier when the scheme node is one.
    const Pair = struct { s: Var, i: Var };

    fn deinit(c: *Crossing) void {
        const s = c.in.scratch;
        c.wild.deinit(s);
        c.todo.deinit(s);
        c.pairs.deinit(s);
        c.zip_stack.deinit(s);
        c.fields.deinit(s);
        c.other.deinit(s);
        c.refs.deinit(s);
    }

    fn run(c: *Crossing) Error!void {
        const in = c.in;
        const bir = in.bir;
        c.owners = try in.scratch.alloc(Owner, bir.decls.len + bir.locals.len);
        @memset(c.owners, .{});
        // The seeds: every `Js.from`, every imported crossing quantifier.
        for (in.casts) |cast| {
            const func = Walk.function(in.store, cast.copy) orelse continue;
            switch (cast.which) {
                .from => if (func.params.len == 1) try c.cross(func.params[0], cast.decl, true),
                // A `Js.to` adds its closed types to the wild set and crosses
                // no quantifier (`backend.md` §9's table).
                .to => try c.cross(func.result, cast.decl, false),
            }
        }
        for (in.uses) |u| try c.cross(u.v, u.decl orelse declOf(bir, u.inst) orelse continue, true);
        // The module's own references, until nothing new crosses: a
        // reference is looked at again only when its callee's bits grew.
        var any = false;
        for (c.owners) |*o| any = any or o.any();
        if (!any) return;
        try c.collectSites();
        const collected = try in.scratch.alloc(bool, bir.decls.len);
        @memset(collected, false);
        c.changed = true;
        while (c.changed) {
            c.changed = false;
            // A declaration's references are read once something it names
            // has crossing quantifiers: most of a module's never do.
            for (bir.decls, 0..) |d, di| {
                if (collected[di] or !d.kind.isValue() or !c.relevant(d)) continue;
                collected[di] = true;
                try c.collectDecl(d, @intCast(di));
            }
            for (c.refs.items) |*r| {
                const o = &c.owners[r.callee];
                if (o.version == r.seen) continue;
                r.seen = o.version;
                switch (r.kind) {
                    .instance => try c.instance(r.callee, r.scheme, r.inst, r.decl),
                    .method => try c.method(r.inst, r.decl),
                }
            }
        }
    }

    const Ref = struct {
        inst: Bir.Inst.Index,
        callee: usize,
        decl: u32,
        scheme: Var,
        kind: enum { instance, method },
        /// The callee's `version` when this was last looked at.
        seen: u32 = 0,
    };

    /// Whether declaration `d` names a declaration of this module, or has a
    /// `let` function, whose quantifiers cross.
    fn relevant(c: *const Crossing, d: Bir.Decl) bool {
        const bir = c.in.bir;
        for (bir.declRefs(d)) |r| {
            if (r.kind == .top_value and r.a < bir.decls.len and c.owners[r.a].any()) return true;
        }
        var l = d.locals_start;
        while (l < d.locals_end) : (l += 1) {
            if (c.owners[bir.decls.len + l].any()) return true;
        }
        return false;
    }

    /// Every reference in `d` to a declaration or a `let` function of this
    /// module with a scheme.
    fn collectDecl(c: *Crossing, d: Bir.Decl, di: u32) Error!void {
        const in = c.in;
        const bir = in.bir;
        const tags = bir.insts.items(.tag);
        {
            var at = d.inst_start.int();
            while (at < d.inst_end.int() and at < tags.len) : (at += 1) {
                const inst: Bir.Inst.Index = @fromBackingInt(@intCast(at));
                switch (tags[at]) {
                    .top => {
                        const callee = bir.instData(inst).lhs;
                        if (callee >= bir.decls.len) continue;
                        const scheme = in.decl_scheme[callee].unwrap() orelse continue;
                        try c.refs.append(in.scratch, .{ .inst = inst, .callee = callee, .decl = di, .scheme = scheme, .kind = .instance });
                    },
                    .local => {
                        const l = d.locals_start + bir.instData(inst).lhs;
                        if (l >= bir.locals.len or bir.locals[l].kind != .let) continue;
                        const t = in.local_type[l].unwrap() orelse continue;
                        try c.refs.append(in.scratch, .{ .inst = inst, .callee = bir.decls.len + l, .decl = di, .scheme = t, .kind = .instance });
                    },
                    else => {},
                }
            }
        }
    }

    /// Every method call that runs a declaration of this module.
    fn collectSites(c: *Crossing) Error!void {
        const in = c.in;
        const bir = in.bir;
        for (in.dispatch.sites) |site| {
            const callee = site.callee.unwrap() orelse continue;
            const decl = switch (in.dispatch.term(callee)) {
                .top => |t| t.decl.int(),
                else => continue,
            };
            if (decl >= bir.decls.len or bir.instTag(site.inst) != .method_call) continue;
            const owner = declOf(bir, site.inst) orelse continue;
            try c.refs.append(in.scratch, .{ .inst = site.inst, .callee = decl, .decl = owner, .scheme = undefined, .kind = .method });
        }
    }

    /// A method call that runs a declaration of this module whose quantifiers
    /// cross: its scheme is not at hand here, so every type the call reads or
    /// makes crosses.
    fn method(c: *Crossing, inst: Bir.Inst.Index, decl: u32) Error!void {
        const bir = c.in.bir;
        try c.crossInst(inst, decl);
        const data = bir.instData(inst);
        try c.crossInst(@fromBackingInt(@intCast(data.lhs)), decl);
        const call = bir.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
        for (bir.extraSlice(.{ .start = call.args_start, .end = call.args_end }, Bir.Inst.Index)) |arg| try c.crossInst(arg, decl);
    }

    fn crossInst(c: *Crossing, inst: Bir.Inst.Index, decl: u32) Error!void {
        if (inst.int() >= c.in.inst_type.len) return;
        const v = c.in.inst_type[inst.int()].unwrap() orelse return;
        try c.cross(v, decl, true);
    }

    /// The reference at `inst`, in declaration `decl`, instantiates owner
    /// `callee`'s scheme `scheme`: what each crossing quantifier became.
    fn instance(c: *Crossing, callee: usize, scheme: Var, inst: Bir.Inst.Index, decl: u32) Error!void {
        if (inst.int() >= c.in.inst_type.len) return;
        const at = c.in.inst_type[inst.int()].unwrap() orelse return;
        const owner = try c.ownerOf(callee);
        try c.zip(scheme, at);
        for (c.pairs.items) |p| {
            const q = indexOf(owner.order, c.in.store.find(p.s)) orelse continue;
            if (owner.crosses(q)) try c.cross(p.i, decl, true);
        }
    }

    /// The pairs of `scheme`'s quantifiers and the instance nodes at their
    /// places, into `pairs`. A row variable is paired with the whole record.
    fn zip(c: *Crossing, scheme: Var, at: Var) Error!void {
        const store = c.in.store;
        const s = c.in.scratch;
        c.pairs.clearRetainingCapacity();
        c.zip_stack.clearRetainingCapacity();
        const seen = store.nextMark();
        try c.zip_stack.append(s, .{ .s = scheme, .i = at });
        while (c.zip_stack.pop()) |p| {
            const sr = through(store, p.s);
            const ir = through(store, p.i);
            if (store.mark(sr) == seen) continue;
            store.setMark(sr, seen);
            switch (store.content(sr)) {
                .flex, .rigid => try c.pairs.append(s, .{ .s = sr, .i = ir }),
                .err, .alias => {},
                .structure => |ss| {
                    const is = switch (store.content(ir)) {
                        .structure => |x| x,
                        else => continue,
                    };
                    switch (ss) {
                        .unit, .empty_record => {},
                        .func => |f| if (is == .func and is.func.params.len == f.params.len) {
                            for (store.vars(f.params), store.vars(is.func.params)) |x, y| try c.zip_stack.append(s, .{ .s = x, .i = y });
                            try c.zip_stack.append(s, .{ .s = f.result, .i = is.func.result });
                        },
                        .app => |a| if (is == .app and is.app.type == a.type and is.app.args.len == a.args.len) {
                            for (store.vars(a.args), store.vars(is.app.args)) |x, y| try c.zip_stack.append(s, .{ .s = x, .i = y });
                        },
                        .tuple => |t| if (is == .tuple and is.tuple.len == t.len) {
                            for (store.vars(t), store.vars(is.tuple)) |x, y| try c.zip_stack.append(s, .{ .s = x, .i = y });
                        },
                        .record => |r| if (is == .record) {
                            c.fields.clearRetainingCapacity();
                            const end = try wholeRow(store, s, &c.fields, r);
                            c.other.clearRetainingCapacity();
                            _ = try wholeRow(store, s, &c.other, is.record);
                            for (c.fields.items) |f| {
                                for (c.other.items) |g| if (g.name == f.name) {
                                    try c.zip_stack.append(s, .{ .s = f.value, .i = g.value });
                                    break;
                                };
                            }
                            // A row variable stands for the fields the instance
                            // has beyond the scheme's: all of the record.
                            if (end) |e| try c.pairs.append(s, .{ .s = e, .i = ir });
                        },
                    }
                },
            }
        }
    }

    /// `v`'s type crosses into JavaScript in declaration `decl`: its closed
    /// parts join the wild set, and, when `quantifiers`, every quantifier it
    /// mentions crosses.
    fn cross(c: *Crossing, v: Var, decl: u32, quantifiers: bool) Error!void {
        const store = c.in.store;
        const s = c.in.scratch;
        // A fresh mark per walk: a type met twice in one walk is walked once.
        // `quantifier` may read a scheme's order with marks of its own, which
        // at worst walks a node of this type again.
        const seen = store.nextMark();
        c.todo.clearRetainingCapacity();
        try c.todo.append(s, v);
        while (c.todo.pop()) |next| {
            const r = store.find(next);
            if (store.mark(r) == seen) continue;
            store.setMark(r, seen);
            const content = store.content(r);
            switch (content) {
                .flex, .rigid => {
                    if (quantifiers) try c.quantifier(r, decl);
                    continue;
                },
                .err => continue,
                else => {},
            }
            if (c.in.keyed) {
                // The walk below may move `todo`'s marks: `keyOf` reads none.
                const k = try c.b.keyOf(r);
                if (k != .wild) try c.wild.append(s, k);
            }
            switch (content) {
                .flex, .rigid, .err => {},
                .alias => |a| try c.todo.append(s, a.actual),
                .structure => |st| switch (st) {
                    .unit, .empty_record => {},
                    .func => |f| {
                        try c.todo.appendSlice(s, store.vars(f.params));
                        try c.todo.append(s, f.result);
                    },
                    .app => |a| try c.todo.appendSlice(s, store.vars(a.args)),
                    .tuple => |t| try c.todo.appendSlice(s, store.vars(t)),
                    .record => |rec| {
                        // By text: the order `keyOf` meets them in numbers nodes.
                        c.fields.clearRetainingCapacity();
                        try c.fields.appendSlice(s, store.fields(rec.fields));
                        byText(TypeStore.Field, c.in.interner, c.fields.items);
                        var i = c.fields.items.len;
                        while (i > 0) {
                            i -= 1;
                            try c.todo.append(s, c.fields.items[i].value);
                        }
                        // A row's closed end is not a type a value has.
                        const ext = store.find(rec.ext);
                        const ends = switch (store.content(ext)) {
                            .structure => |e| e == .empty_record,
                            else => false,
                        };
                        if (!ends) try c.todo.append(s, ext);
                    },
                },
            }
        }
    }

    /// The type variable `r`, met in declaration `decl`, crosses: the
    /// quantifier it is of, or, when no owner names it, every quantifier of
    /// the declaration and of its `let` functions.
    fn quantifier(c: *Crossing, r: Var, decl: u32) Error!void {
        const in = c.in;
        const store = in.store;
        if (decl >= in.bir.decls.len) return;
        const rigid = store.content(r) == .rigid;
        // A variable no generalisation reached is one type, not a
        // quantifier: what reaches it is that type's (§36).
        if (!rigid and store.rank(r) != TypeStore.generalized) return;
        const d = in.bir.decls[decl];
        var found = false;
        // By identity: the declaration's own scheme, then its `let`s'.
        if (try c.mark(decl, r)) found = true;
        var l = d.locals_start;
        while (!found and l < d.locals_end) : (l += 1) {
            if (in.bir.locals[l].kind != .let) continue;
            if (try c.mark(in.bir.decls.len + l, r)) found = true;
        }
        // A rigid variable is an annotation's: by its name, in every owner
        // of the declaration that has a quantifier of that name.
        if (!found and rigid) if (store.flagsOf(r).name.unwrap()) |name| {
            if (try c.markNamed(decl, name)) found = true;
            l = d.locals_start;
            while (l < d.locals_end) : (l += 1) {
                if (in.bir.locals[l].kind != .let) continue;
                if (try c.markNamed(in.bir.decls.len + l, name)) found = true;
            }
        };
        if (found) return;
        try c.setAll(decl);
        l = d.locals_start;
        while (l < d.locals_end) : (l += 1) {
            if (in.bir.locals[l].kind == .let) try c.setAll(in.bir.decls.len + l);
        }
    }

    fn setAll(c: *Crossing, index: usize) Error!void {
        const o = try c.ownerOf(index);
        if (o.all) return;
        o.all = true;
        o.version += 1;
        c.changed = true;
    }

    fn mark(c: *Crossing, index: usize, r: Var) Error!bool {
        const o = try c.ownerOf(index);
        const q = indexOf(o.order, r) orelse return false;
        if (!o.crossing[q]) {
            o.crossing[q] = true;
            o.version += 1;
            c.changed = true;
        }
        return true;
    }

    fn markNamed(c: *Crossing, index: usize, name: InternPool.Symbol) Error!bool {
        const o = try c.ownerOf(index);
        var found = false;
        for (o.order, 0..) |v, q| {
            if (c.in.store.flagsOf(v).name.unwrap() != name) continue;
            found = true;
            if (!o.crossing[q]) {
                o.crossing[q] = true;
                o.version += 1;
                c.changed = true;
            }
        }
        return found;
    }

    /// Owner `index`'s quantifiers, read the first time it is asked about.
    fn ownerOf(c: *Crossing, index: usize) Error!*Owner {
        const o = &c.owners[index];
        if (o.made) return o;
        o.made = true;
        const in = c.in;
        const bir = in.bir;
        const t: ?Var = if (index < bir.decls.len)
            (if (bir.decls[index].kind.isValue()) in.decl_scheme[index].unwrap() else null)
        else blk: {
            const l = index - bir.decls.len;
            break :blk if (bir.locals[l].kind == .let) in.local_type[l].unwrap() else null;
        };
        const root = t orelse return o;
        var order: std.ArrayList(Var) = .empty;
        try Schemes.quantifierOrder(in.store, in.interner, root, &order, in.scratch);
        // A `let`'s type may hold variables of the enclosing declaration,
        // which it does not quantify.
        if (index >= bir.decls.len) {
            var kept: usize = 0;
            for (order.items) |v| {
                if (in.store.rank(v) != TypeStore.generalized) continue;
                order.items[kept] = v;
                kept += 1;
            }
            order.items.len = kept;
        }
        o.order = order.items;
        o.crossing = try in.scratch.alloc(bool, order.items.len);
        @memset(o.crossing, false);
        return o;
    }

    /// Per declaration, its crossing quantifiers, for P8.
    fn published(c: *Crossing) Error![]const []const u16 {
        const decls = c.in.bir.decls.len;
        const out = try c.in.scratch.alloc([]const u16, decls);
        for (out, 0..) |*slot, d| {
            slot.* = &.{};
            if (d >= c.owners.len or !c.owners[d].made) continue;
            const o = &c.owners[d];
            var list: std.ArrayList(u16) = .empty;
            for (0..o.order.len) |q| if (o.crosses(q)) try list.append(c.in.scratch, @intCast(q));
            slot.* = list.items;
        }
        return out;
    }
};

/// `v`'s root, through aliases to their expansion.
fn through(store: *TypeStore, v: Var) Var {
    var r = store.find(v);
    var links: u32 = 0;
    while (links <= store.count()) : (links += 1) switch (store.content(r)) {
        .alias => |a| r = store.find(a.actual),
        else => return r,
    };
    return r;
}

/// A record's whole row into `out`, and the variable it ends in, if any.
fn wholeRow(store: *TypeStore, gpa: Allocator, out: *std.ArrayList(TypeStore.Field), rec: TypeStore.Structure.Record) Error!?Var {
    try out.appendSlice(gpa, store.fields(rec.fields));
    var ext = rec.ext;
    var links: u32 = 0;
    while (links <= store.count()) : (links += 1) {
        const r = through(store, ext);
        switch (store.content(r)) {
            .structure => |s| switch (s) {
                .record => |next| {
                    try out.appendSlice(gpa, store.fields(next.fields));
                    ext = next.ext;
                },
                .empty_record => return null,
                else => return null,
            },
            .flex, .rigid => return r,
            else => return null,
        }
    }
    return null;
}

fn indexOf(order: []const Var, v: Var) ?usize {
    for (order, 0..) |x, i| if (x == v) return i;
    return null;
}

/// The declaration whose instruction range holds `inst`.
fn declOf(bir: *const Bir, inst: Bir.Inst.Index) ?u32 {
    for (bir.decls, 0..) |d, i| {
        if (inst.int() >= d.inst_start.int() and inst.int() < d.inst_end.int()) return @intCast(i);
    }
    return null;
}

/// Sort `items` (each with a `name`) by the names' text: an insertion sort,
/// for a record's few fields, with no allocation, reading the interner's
/// text ranks when it has them (`TypeStore.sortByText`'s order).
fn byText(comptime T: type, interner: *const InternPool.Global, items: []T) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        var j = i;
        while (j > 0 and textBefore(interner, x.name, items[j - 1].name)) : (j -= 1) items[j] = items[j - 1];
        items[j] = x;
    }
}

fn textBefore(interner: *const InternPool.Global, a: InternPool.Symbol, b: InternPool.Symbol) bool {
    if (interner.textRank(a)) |ra| if (interner.textRank(b)) |rb| return ra < rb;
    return std.mem.lessThan(u8, interner.slice(a), interner.slice(b));
}
