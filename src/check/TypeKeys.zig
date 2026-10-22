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
const Context = @import("Context.zig");
const Publish = @import("Publish.zig");
const Schema = @import("Schema.zig");
const Interface = @import("../resolve/Interface.zig");

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

/// All solved record rows, even when a field value has no closed key.
/// A row with an unknown extension conflicts with every field text.
pub const Record = struct { fields: Range, open: bool };

/// One module's artifact, owned by `gpa`. Empty for embedded core,
/// platforms and modules checked silently or with an error.
pub const Artifact = struct {
    records: []const Record = &.{},
    record_labels: []const InternPool.Symbol = &.{},

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
        gpa.free(a.records);
        gpa.free(a.record_labels);
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
    /// The module's check, for the payloads of its own types.
    cx: *const Context,
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    bir: *const Bir,
    local_type: []const Var.Optional,
    inst_type: []const Var.Optional,
    decl_scheme: []const Var.Optional,
    /// The type each declaration's body was checked against (an annotation's
    /// rigid reading, an unannotated one's own variable), or none: it
    /// shares its nodes with the locals', so it keys mostly from the memo.
    decl_display: []const Var.Optional,
    casts: []const Solve.Cast,
    /// Every crossing quantifier of an import this module instantiated.
    uses: []const Instantiate.CrossingUse,
    /// Every own scheme quantifier's copy, at each instantiation.
    copies: []const Instantiate.CopyPair,
    /// The module's schema declarations' endpoints and payloads, which
    /// compiled code builds and parses (`schema.md` §6).
    schemas: *const Schema.State,
    dispatch: *const Dispatch,
    /// Whether to make the keys: an app module (§36). The crossing bits are
    /// made for every module.
    keyed: bool,
};

pub const Output = struct {
    /// Owned by `gpa`.
    artifact: Artifact,
    /// Per store variable: whether it is a scheme quantifier that crosses,
    /// which P8 publishes as its `crosses` bit; owned by `scratch`.
    crossing: []const bool,
};

/// Record facts have no store-variable identity. Sort and deduplicate by
/// text before persisting them, just as closed keys order their labels.
const RecordOrder = struct {
    labels: []const InternPool.Symbol,
    interner: *const InternPool.Global,

    fn lessThan(o: RecordOrder, a: Record, b: Record) bool {
        const aa = o.labels[a.fields.start..][0..a.fields.len];
        const bb = o.labels[b.fields.start..][0..b.fields.len];
        for (0..@min(aa.len, bb.len)) |i| {
            // One symbol is one text: equal symbols are equal texts, and
            // two others are ordered by text, through its rank when the
            // interner has one.
            if (aa[i] == bb[i]) continue;
            return textBefore(o.interner, aa[i], bb[i]);
        }
        if (aa.len != bb.len) return aa.len < bb.len;
        return !a.open and b.open;
    }

    fn same(o: RecordOrder, a: Record, b: Record) bool {
        return a.open == b.open and std.mem.eql(InternPool.Symbol, o.labels[a.fields.start..][0..a.fields.len], o.labels[b.fields.start..][0..b.fields.len]);
    }
};

/// A row's identity while the store is scanned: its labels in symbol order
/// and its openness, read from the scan's `labels`.
const RowContext = struct {
    labels: []const InternPool.Symbol,

    pub fn hash(c: RowContext, r: Record) u64 {
        const row = c.labels[r.fields.start..][0..r.fields.len];
        return std.hash.Wyhash.hash(@intFromBool(r.open), std.mem.sliceAsBytes(row));
    }

    pub fn eql(c: RowContext, a: Record, b: Record) bool {
        return a.open == b.open and std.mem.eql(InternPool.Symbol, c.labels[a.fields.start..][0..a.fields.len], c.labels[b.fields.start..][0..b.fields.len]);
    }
};

fn symbolBefore(_: void, a: InternPool.Symbol, b: InternPool.Symbol) bool {
    return @backingInt(a) < @backingInt(b);
}

/// A row's labels in text order. Equal labels are one symbol, so the
/// order is total and an unstable sort writes it.
fn symbolsByText(interner: *const InternPool.Global, row: []InternPool.Symbol) void {
    std.mem.sortUnstable(InternPool.Symbol, row, interner, textBefore);
}

pub fn build(in: Input) Error!Output {
    var b: Builder = .{
        .gpa = in.scratch, // the builder's lists die with the module's scratch
        .scratch = in.scratch,
        .store = in.store,
        .types = in.types,
        .interner = in.interner,
        // Only a keyed module keys a type: core's and a platform's check
        // pays for its crossing quantifiers alone.
        .memo = if (in.keyed) try in.scratch.alloc(u32, in.store.count()) else &.{},
        .named0 = if (in.keyed) try in.scratch.alloc(u32, in.types.count()) else &.{},
        .alias0 = if (in.keyed) try in.scratch.alloc(u32, in.types.count()) else &.{},
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
        // Each value declaration's type: the one its body was checked
        // against, closed exactly when its scheme is (a quantifier is a rigid
        // variable there, a generalised `flex` in the scheme), and made of the
        // nodes the locals were keyed from.
        const decls = try in.gpa.alloc(TypeKey, in.bir.decls.len);
        artifact.decls = decls;
        for (decls, in.bir.decls, 0..) |*k, d, i| {
            k.* = .wild;
            if (!d.kind.isValue() or i >= in.decl_scheme.len) continue;
            const t = if (i < in.decl_display.len and in.decl_display[i] != .none) in.decl_display[i] else in.decl_scheme[i];
            if (t.unwrap()) |v| k.* = try b.keyOf(v);
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
        // Every schema's endpoints and its tagged variants' payloads, inline
        // records included: compiled code parses and prints them, outside
        // any Bir instruction, and the types live only in this store
        // (`schema.md` §6), so the artifact alone closes the wild set.
        var payloads: std.ArrayList(Var) = .empty;
        for (in.bir.decls, 0..) |d, i| {
            if (d.kind != .schema or d.schema_body == .none or i >= in.schemas.endpoints.len) continue;
            const pair = in.schemas.endpoints[i];
            try c.cross(pair.program, @intCast(i), false);
            try c.cross(pair.encoded, @intCast(i), false);
            for ([_]Interface.SchemaCtor.Endpoint{ .type, .encoded }) |ep| {
                payloads.clearRetainingCapacity();
                try in.schemas.payloads(@intCast(i), ep, &payloads, in.scratch);
                for (payloads.items) |p| try c.cross(p, @intCast(i), false);
            }
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
        // Scan roots, rather than only keyable expressions: schemas, ctor
        // payloads and records with polymorphic/host fields are in the store
        // too. A closed field set needs no key for its field values.
        //
        // A store holds many copies of one row (every instantiation of a
        // record type copies it), so the rows are made distinct first, by
        // their labels in symbol order and their openness, and only the
        // distinct ones are put in text order. A symbol is one text, so two
        // rows are one row in text order exactly when they are one here: the
        // artifact is the one a text sort of every copy, then a deduplication,
        // gives, and the distinct rows' text order is total, so an unstable
        // sort writes it (checker-v2.md §36, *As built 2026-10-22*).
        var records: std.ArrayList(Record) = .empty;
        var labels: std.ArrayList(InternPool.Symbol) = .empty;
        var fields: std.ArrayList(TypeStore.Field) = .empty;
        var distinct: std.HashMapUnmanaged(Record, void, RowContext, std.hash_map.default_max_load_percentage) = .empty;
        for (0..in.store.count()) |vi| {
            const v: Var = @fromBackingInt(@intCast(vi));
            if (in.store.find(v) != v) continue;
            const rec = switch (in.store.content(v)) {
                .structure => |s| switch (s) {
                    .record => |r| r,
                    else => continue,
                },
                else => continue,
            };
            fields.clearRetainingCapacity();
            const closed = try b.closedRow(rec, &fields);

            const start: u32 = @intCast(labels.items.len);
            for (fields.items) |field| try labels.append(in.scratch, field.name);
            const row = labels.items[start..];
            std.mem.sortUnstable(InternPool.Symbol, row, {}, symbolBefore);
            const r: Record = .{ .fields = .{ .start = start, .len = @intCast(row.len) }, .open = !closed };
            const slot = try distinct.getOrPutContext(in.scratch, r, .{ .labels = labels.items });
            if (slot.found_existing) {
                labels.shrinkRetainingCapacity(start);
                continue;
            }
            try records.append(in.scratch, r);
        }
        for (records.items) |r| symbolsByText(in.interner, labels.items[r.fields.start..][0..r.fields.len]);
        const order: RecordOrder = .{ .labels = labels.items, .interner = in.interner };
        std.mem.sortUnstable(Record, records.items, order, RecordOrder.lessThan);
        var canonical: std.ArrayList(Record) = .empty;
        var canonical_labels: std.ArrayList(InternPool.Symbol) = .empty;
        var previous: ?Record = null;
        for (records.items) |r| {
            if (previous) |p| if (order.same(p, r)) continue;
            previous = r;
            const start: u32 = @intCast(canonical_labels.items.len);
            try canonical_labels.appendSlice(in.scratch, labels.items[r.fields.start..][0..r.fields.len]);
            try canonical.append(in.scratch, .{ .fields = .{ .start = start, .len = r.fields.len }, .open = r.open });
        }
        artifact.records = try in.gpa.dupe(Record, canonical.items);
        artifact.record_labels = try in.gpa.dupe(InternPool.Symbol, canonical_labels.items);
        artifact.nodes = try in.gpa.dupe(KeyNode, b.nodes.items);

        artifact.args = try in.gpa.dupe(TypeKey, b.args.items);
        artifact.labels = try in.gpa.dupe(InternPool.Symbol, b.labels.items);
    }
    return .{ .artifact = artifact, .crossing = c.crossing };
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
    /// `direct`'s own lists: it runs while `pushChildren` walks the others.
    dfields: std.ArrayList(TypeStore.Field) = .empty,
    dwords: std.ArrayList(u32) = .empty,
    dnames: std.ArrayList(InternPool.Symbol) = .empty,
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
        b.dfields.deinit(b.scratch);
        b.dwords.deinit(b.scratch);
        b.dnames.deinit(b.scratch);
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
        if (try b.direct(root)) |k| {
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
        if (try b.direct(r)) |k| {
            b.memo[r.int()] = k.int();
            return;
        }
        try b.stack.append(b.scratch, .{ .v = r, .expanded = false });
    }

    /// `v`'s key when it is already known or a leaf, else null.
    fn known(b: *Builder, v: Var) Error!?TypeKey {
        const r = b.store.find(v);
        const m = b.memo[r.int()];
        if (m != unset and m != pending) return @fromBackingInt(m);
        const k = try b.leaf(r) orelse return null;
        b.memo[r.int()] = k.int();
        return k;
    }

    /// The key of a node whose children are all known or leaves, made without
    /// a frame: one level of a type, the common case. Null when a child needs
    /// a walk of its own.
    fn direct(b: *Builder, r: Var) Error!?TypeKey {
        const store = b.store;
        switch (store.content(r)) {
            .alias => |a| {
                const k = try b.known(a.actual) orelse return null;
                if (a.args.len == 0 and a.type.int() < b.alias0.len) b.alias0[a.type.int()] = k.int();
                return k;
            },
            .structure => |s| switch (s) {
                .func => |f| {
                    b.dwords.clearRetainingCapacity();
                    for (store.vars(f.params)) |p| {
                        const k = try b.known(p) orelse return null;
                        if (k == .wild) return .wild;
                        try b.dwords.append(b.scratch, k.int());
                    }
                    const res = try b.known(f.result) orelse return null;
                    if (res == .wild) return .wild;
                    try b.dwords.append(b.scratch, res.int());
                    return try b.intern(.function, 0, @ptrCast(b.dwords.items));
                },
                .app => |a| {
                    if (!b.keyedNominal(a.type)) return .wild;
                    b.dwords.clearRetainingCapacity();
                    for (store.vars(a.args)) |x| {
                        const k = try b.known(x) orelse return null;
                        if (k == .wild) return .wild;
                        try b.dwords.append(b.scratch, k.int());
                    }
                    return try b.intern(.named, a.type.int(), @ptrCast(b.dwords.items));
                },
                .tuple => |t| {
                    b.dwords.clearRetainingCapacity();
                    for (store.vars(t)) |x| {
                        const k = try b.known(x) orelse return null;
                        if (k == .wild) return .wild;
                        try b.dwords.append(b.scratch, k.int());
                    }
                    return try b.intern(.tuple, 0, @ptrCast(b.dwords.items));
                },
                .record => |rec| {
                    b.dfields.clearRetainingCapacity();
                    if (!try b.closedRow(rec, &b.dfields)) return .wild;
                    // By text, as `pushChildren` visits them (§36).
                    byText(TypeStore.Field, b.interner, b.dfields.items);
                    b.dwords.clearRetainingCapacity();
                    b.dnames.clearRetainingCapacity();
                    for (b.dfields.items) |f| {
                        const k = try b.known(f.value) orelse return null;
                        if (k == .wild) return .wild;
                        try b.dwords.append(b.scratch, k.int());
                        try b.dnames.append(b.scratch, f.name);
                    }
                    return try b.internLabelled(@ptrCast(b.dwords.items), b.dnames.items);
                },
                else => return null,
            },
            else => return null,
        }
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
                    if (!try b.closedRow(rec, &b.fields)) return;
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
    fn closedRow(b: *Builder, rec: TypeStore.Structure.Record, out: *std.ArrayList(TypeStore.Field)) Error!bool {
        const store = b.store;
        try out.appendSlice(b.scratch, store.fields(rec.fields));
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
                        try out.appendSlice(b.scratch, store.fields(r.fields));
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
                    if (!try b.closedRow(rec, &b.fields)) return .wild;
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
/// functions, and the wild set's closed types (§36). It reads only what the
/// check recorded on its way: the casts, every imported crossing quantifier's
/// instance, and every own scheme quantifier's copy at each instantiation
/// (`Instantiate.copies`). A quantifier that comes to cross wakes the copies
/// of it, so the fixpoint is a worklist over those records and never a second
/// walk of the module.
const Crossing = struct {
    in: Input,
    b: *Builder,
    wild: std.ArrayList(TypeKey) = .empty,
    todo: std.ArrayList(Var) = .empty,
    fields: std.ArrayList(TypeStore.Field) = .empty,
    /// Per store variable that existed when the walk began: whether it is a
    /// scheme quantifier that crosses.
    crossing: []bool = &.{},
    /// The quantifiers that came to cross in the current pass.
    queue: std.ArrayList(Var) = .empty,
    /// Per declaration, the generalised variables of its scheme and of its
    /// `let` functions' types, read once when an annotation's rigid variable
    /// has to be named.
    owned: []?[]const Var = &.{},
    /// Per `TypeId`, where its held parameters start in `held_words`.
    held_at: []u32 = &.{},
    held_words: std.ArrayList(u32) = .empty,

    fn deinit(c: *Crossing) void {
        const s = c.in.scratch;
        c.wild.deinit(s);
        c.todo.deinit(s);
        c.fields.deinit(s);
        c.queue.deinit(s);
        c.held_words.deinit(s);
    }

    fn run(c: *Crossing) Error!void {
        const in = c.in;
        const bir = in.bir;
        c.crossing = try in.scratch.alloc(bool, in.store.count());
        @memset(c.crossing, false);
        // The seeds: every `Js.from`, every imported crossing quantifier.
        for (in.casts) |cast| {
            const func = Walk.function(in.store, cast.copy) orelse continue;
            switch (cast.which) {
                .from => if (func.params.len == 1) try c.cross(func.params[0], cast.decl, true),
                // A `Js.to` adds its closed types to the wild set and crosses
                // no quantifier (`backend.md` §9's table).
                .to => if (in.keyed) try c.cross(func.result, cast.decl, false),
            }
        }
        for (in.uses) |u| try c.cross(u.v, u.decl orelse declOf(bir, u.inst) orelse continue, true);
        if (c.queue.items.len == 0) return;
        // Passes over the copies until none wakes: a copy is read once its
        // quantifier crosses, and a pass is a test per copy.
        const done = try in.scratch.alloc(bool, in.copies.len);
        @memset(done, false);
        while (true) {
            c.queue.clearRetainingCapacity();
            for (in.copies, done) |p, *d| {
                if (d.* or p.quantifier.int() >= c.crossing.len or !c.crossing[p.quantifier.int()]) continue;
                d.* = true;
                if (p.decl < bir.decls.len) try c.cross(p.copy, p.decl, true);
            }
            // A method call that runs a declaration of this module whose
            // quantifiers cross: its scheme is not at hand here, so every
            // type the call reads or makes crosses.
            for (in.dispatch.sites) |site| {
                const callee = site.callee.unwrap() orelse continue;
                const decl = switch (in.dispatch.term(callee)) {
                    .top => |t| t.decl.int(),
                    else => continue,
                };
                if (decl >= bir.decls.len or bir.instTag(site.inst) != .method_call) continue;
                if (!try c.declCrosses(decl)) continue;
                const owner = declOf(bir, site.inst) orelse continue;
                try c.crossInst(site.inst, owner);
                const data = bir.instData(site.inst);
                try c.crossInst(@fromBackingInt(@intCast(data.lhs)), owner);
                const call = bir.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
                for (bir.extraSlice(.{ .start = call.args_start, .end = call.args_end }, Bir.Inst.Index)) |arg| try c.crossInst(arg, owner);
            }
            if (c.queue.items.len == 0) return;
        }
    }

    fn declCrosses(c: *Crossing, decl: u32) Error!bool {
        for (try c.ownedBy(decl)) |v| {
            if (c.crossing[v.int()]) return true;
        }
        return false;
    }

    fn crossInst(c: *Crossing, inst: Bir.Inst.Index, decl: u32) Error!void {
        if (inst.int() >= c.in.inst_type.len) return;
        const v = c.in.inst_type[inst.int()].unwrap() orelse return;
        try c.cross(v, decl, true);
    }

    fn markVar(c: *Crossing, v: Var) Error!void {
        if (v.int() >= c.crossing.len or c.crossing[v.int()]) return;
        c.crossing[v.int()] = true;
        try c.queue.append(c.in.scratch, v);
    }

    /// `v`'s type crosses into JavaScript in declaration `decl`: its closed
    /// parts join the wild set, and, when `quantifiers`, every quantifier its
    /// representation holds crosses.
    fn cross(c: *Crossing, v: Var, decl: u32, quantifiers: bool) Error!void {
        const store = c.in.store;
        const s = c.in.scratch;
        const seen = store.nextMark();
        // `quantifier` walks a scheme with a list of its own, so `todo` is
        // this walk'"'"'s.
        const todo = &c.todo;
        todo.clearRetainingCapacity();
        try todo.append(s, v);
        while (todo.pop()) |next| {
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
                const k = try c.b.keyOf(r);
                if (k != .wild) try c.wild.append(s, k);
            }
            switch (content) {
                .flex, .rigid, .err => {},
                .alias => |a| try todo.append(s, a.actual),
                .structure => |st| switch (st) {
                    .unit, .empty_record => {},
                    .func => |f| {
                        try todo.appendSlice(s, store.vars(f.params));
                        try todo.append(s, f.result);
                    },
                    .app => |a| {
                        // Only the arguments its representation holds: a
                        // phantom parameter puts no value in JavaScript's hands
                        // (`backend.md` §9, amended 2026-10-20).
                        const args_held = try c.held(a.type);
                        for (store.vars(a.args), 0..) |x, i| {
                            if (has(args_held, i)) try todo.append(s, x);
                        }
                    },
                    .tuple => |t| try todo.appendSlice(s, store.vars(t)),
                    .record => |rec| {
                        // By text where it is keyed: the order `keyOf` meets
                        // them in numbers nodes.
                        c.fields.clearRetainingCapacity();
                        try c.fields.appendSlice(s, store.fields(rec.fields));
                        if (c.in.keyed) byText(TypeStore.Field, c.in.interner, c.fields.items);
                        var i = c.fields.items.len;
                        while (i > 0) {
                            i -= 1;
                            try todo.append(s, c.fields.items[i].value);
                        }
                        // A row's closed end is not a type a value has.
                        const ext = store.find(rec.ext);
                        const ends = switch (store.content(ext)) {
                            .structure => |e| e == .empty_record,
                            else => false,
                        };
                        if (!ends) try todo.append(s, ext);
                    },
                },
            }
        }
    }

    /// The type variable `r`, met in declaration `decl`, crosses. A
    /// generalised one is a quantifier of the declaration's scheme or of one
    /// of its `let` functions, and crosses itself. An annotation's rigid one
    /// stands for the scheme quantifier of its name, which crosses; when no
    /// owner has that name, every quantifier of the declaration does.
    fn quantifier(c: *Crossing, r: Var, decl: u32) Error!void {
        const store = c.in.store;
        if (decl >= c.in.bir.decls.len) return;
        if (store.content(r) != .rigid) {
            // A variable no generalisation reached is one type, not a
            // quantifier: what reaches it is that type's (§36).
            if (store.rank(r) == TypeStore.generalized) try c.markVar(r);
            return;
        }
        const owned = try c.ownedBy(decl);
        var found = false;
        if (store.flagsOf(r).name.unwrap()) |name| {
            for (owned) |v| {
                if (store.flagsOf(v).name.unwrap() != name) continue;
                found = true;
                try c.markVar(v);
            }
        }
        if (found) return;
        for (owned) |v| try c.markVar(v);
    }

    /// The generalised variables of declaration `decl`'s scheme and of its
    /// `let` functions' types, read once.
    fn ownedBy(c: *Crossing, decl: u32) Error![]const Var {
        const in = c.in;
        const bir = in.bir;
        if (c.owned.len == 0) {
            c.owned = try in.scratch.alloc(?[]const Var, bir.decls.len);
            @memset(c.owned, null);
        }
        if (c.owned[decl]) |o| return o;
        var out: std.ArrayList(Var) = .empty;
        const d = bir.decls[decl];
        if (d.kind.isValue()) if (in.decl_scheme[decl].unwrap()) |v| try c.generalised(v, &out);
        // An annotated `let`'"'"'s too: a rigid variable may be its annotation'"'"'s.
        // An unannotated one'"'"'s quantifiers are its own generalised variables,
        // which `quantifier` marks as they are met.
        var l = d.locals_start;
        while (l < d.locals_end) : (l += 1) {
            const local = bir.locals[l];
            if (local.kind != .let or bir.instTag(local.inst) != .let_def) continue;
            const def = bir.extraData(@fromBackingInt(@intCast(bir.instData(local.inst).lhs)), Bir.LetDef);
            if (def.annotation == .none) continue;
            if (in.local_type[l].unwrap()) |v| try c.generalised(v, &out);
        }
        c.owned[decl] = out.items;
        return out.items;
    }

    /// The generalised variables of `v`'s type, each once, in a walk's order.
    fn generalised(c: *Crossing, v: Var, out: *std.ArrayList(Var)) Error!void {
        const store = c.in.store;
        const s = c.in.scratch;
        const seen = store.nextMark();
        var todo: std.ArrayList(Var) = .empty;
        defer todo.deinit(s);
        try todo.append(s, v);
        while (todo.pop()) |next| {
            const r = store.find(next);
            if (store.mark(r) == seen) continue;
            store.setMark(r, seen);
            switch (store.content(r)) {
                .flex, .rigid => if (store.rank(r) == TypeStore.generalized and r.int() < c.crossing.len) try out.append(s, r),
                .err => {},
                .alias => |a| try todo.append(s, a.actual),
                .structure => |st| switch (st) {
                    .unit, .empty_record => {},
                    .func => |f| {
                        try todo.appendSlice(s, store.vars(f.params));
                        try todo.append(s, f.result);
                    },
                    .app => |a| try todo.appendSlice(s, store.vars(a.args)),
                    .tuple => |t| try todo.appendSlice(s, store.vars(t)),
                    .record => |rec| {
                        for (store.fields(rec.fields)) |f| try todo.append(s, f.value);
                        try todo.append(s, rec.ext);
                    },
                },
            }
        }
    }

    /// Which parameters of the named type `id` its representation holds
    /// (`backend.md` §9, amended 2026-10-20): an `adt`'s are those that occur
    /// in a constructor's payload (`Interface.Type.payload_params`, or
    /// `Publish.payloadParams` for this module's own); a `foreign type`
    /// holds nothing JavaScript can reach through it but `List`, an array of
    /// its elements, and `Js.Ref`, a cell of one; null means every
    /// parameter, the answer whenever the facts are not at hand.
    fn held(c: *Crossing, id: TypeStore.TypeId) Error!Bits {
        const in = c.in;
        if (id == .none or id.int() >= in.types.entries.len) return null;
        if (c.held_at.len == 0) {
            c.held_at = try in.scratch.alloc(u32, in.types.entries.len);
            @memset(c.held_at, unknown_held);
        }
        const slot = &c.held_at[id.int()];
        if (slot.* == unknown_held) slot.* = try c.fillHeld(id);
        if (slot.* == every_held) return null;
        const len = (@as(usize, in.types.entry(id).arity) + 31) / 32;
        return c.held_words.items[slot.*..][0..len];
    }

    fn fillHeld(c: *Crossing, id: TypeStore.TypeId) Error!u32 {
        const in = c.in;
        const entry = in.types.entry(id);
        if (entry.arity == 0 or entry.schema_endpoint) return every_held;
        const len = (@as(usize, entry.arity) + 31) / 32;
        const start: u32 = @intCast(c.held_words.items.len);
        if (entry.kind == .foreign) {
            const wk = in.types.well_known;
            const ref = entry.package == .core and std.mem.eql(u8, in.interner.slice(entry.module_name), "Js") and
                std.mem.eql(u8, in.interner.slice(entry.name), "Ref");
            if (id == wk.list or ref) return every_held;
            try c.held_words.appendNTimes(in.scratch, 0, len);
            return start;
        }
        if (entry.kind != .adt) return every_held;
        if (entry.module == in.cx.module) {
            var words: std.ArrayList(u32) = .empty;
            try Publish.payloadParams(in.cx, entry.decl, entry.kind, entry.arity, &words);
            defer words.deinit(in.cx.gpa);
            if (words.items.len != len) return every_held;
            try c.held_words.appendSlice(in.scratch, words.items);
            return start;
        }
        if (entry.module.int() >= in.cx.interfaces.len) return every_held;
        const iface = in.cx.iface(entry.module);
        const facts = iface.typeFacts(in.interner, entry.name) orelse return every_held;
        if (facts.payload_params == Interface.no_terms) return every_held;
        const words = iface.range(facts.payload_params);
        if (words.len != len) return every_held;
        try c.held_words.appendSlice(in.scratch, words);
        return start;
    }
};

/// The declaration whose instruction range holds `inst`.
fn declOf(bir: *const Bir, inst: Bir.Inst.Index) ?u32 {
    for (bir.decls, 0..) |d, i| {
        if (inst.int() >= d.inst_start.int() and inst.int() < d.inst_end.int()) return @intCast(i);
    }
    return null;
}

/// Stable text order, also for wide rows. Read text ranks when the interner
/// has them (`TypeStore.sortByText`'s order); do not use an insertion sort
/// here, since both closed keys and record facts may name thousands of fields.
fn byText(comptime T: type, interner: *const InternPool.Global, items: []T) void {
    std.mem.sort(T, items, interner, struct {
        fn lessThan(pool: *const InternPool.Global, left: T, right: T) bool {
            return textBefore(pool, left.name, right.name);
        }
    }.lessThan);
}

fn textBefore(interner: *const InternPool.Global, a: InternPool.Symbol, b: InternPool.Symbol) bool {
    if (interner.textRank(a)) |ra| if (interner.textRank(b)) |rb| return ra < rb;
    return std.mem.lessThan(u8, interner.slice(a), interner.slice(b));
}

/// A type's held parameters as bits (`Crossing.held`), or null for every one.
const Bits = ?[]const u32;
const unknown_held: u32 = std.math.maxInt(u32);
const every_held: u32 = std.math.maxInt(u32) - 1;

fn has(bits: Bits, i: usize) bool {
    const words = bits orelse return true;
    if (i / 32 >= words.len) return true;
    return words[i / 32] & (@as(u32, 1) << @intCast(i % 32)) != 0;
}
