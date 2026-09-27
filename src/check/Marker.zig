//! The **`equatable` marker walk** (checker-v2.md §11.4), split out of
//! `Instances.zig` by R6a's review (nit): R5 built it as the first part of
//! the capability file. The marker walk of §11.4 (CK-16, CK-17, CK-18),
//! the structural guarantee explicit `Basics.eq` and `Basics.neq` ask for.
//! The marker is never an `eq` method, and the resolver never reads it
//! (CK-19). The walk:
//!
//!   - takes `structural` successors (I2), with a growable stack and a
//!     visited mark (I4, CK-17): a width of 100 000 fields is walked to the
//!     end, and a cycle is walked once (the occurs check reports it);
//!   - at a nominal `T args` asks the gate for `T` itself — for a
//!     `foreign type` declared `equatable` (`Types.isEquatable`), for any
//!     other no function reachable from its payloads (`functionFree`, R8b's
//!     review round: through its module's schema endpoints and `via`
//!     targets, or its record's `no_function`) — and then descends only
//!     into the
//!     arguments whose parameter occurs in a constructor payload (D10,
//!     `payload_params`): computed from this module's own declaration, or
//!     read from interface v3 for another module's, so a phantom function
//!     argument is fine (CK-23, for the marker) and an opaque type's hidden
//!     payloads are never read;
//!   - **propagates** the flag to every flex it met — only once the answer is
//!     `yes` — and gives each a row of the SAME question (`origin`) at the
//!     same region, so what it later becomes is asked that question where it
//!     was raised, and one question says "no" once (R5's review, B1);
//!   - **requires** the flag of a rigid it meets, and without it answers
//!     `rigid` (CK-16's `same`: "the annotation says ANY type").
//!
//! It answers `yes` or why not. It has no "unknown" (I8). It writes
//! nothing on the way: a failure leaves no flag behind, so how many
//! flexes it reached before failing — which depends on symbol ids — changes
//! nothing (I13). Which failure is reported cannot depend on symbol ids
//! either: only on a failure does it walk again, with every record's fields
//! in name-text order, to choose the one it reports.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Context = @import("Context.zig");
const Obligations = @import("Obligations.zig");
const Publish = @import("Publish.zig");
const Contexts = @import("Contexts.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");

const Marker = @This();

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

/// Why a type cannot be compared with explicit `Basics.eq`.
pub const Answer = enum {
    yes,
    /// A function is reachable.
    function,
    /// A named type the gate refuses (a function inside it, or a `foreign
    /// type` not declared `equatable`).
    opaque_type,
    /// A rigid variable without the marker: the annotation promised any type.
    rigid,
};

cx: *const Context,
obligations: *Obligations,
stack: std.ArrayList(Var) = .empty,
/// The flexes a `yes` walk met without the flag: flagged after it.
met: std.ArrayList(Var) = .empty,
fields: std.ArrayList(TypeStore.Field) = .empty,
/// Per session type (`TypeId`), where its `payload_params` bits start in
/// `words`, `all` when every parameter counts, or `unknown` until asked.
/// A dense-id array, allocated the first time the walk meets a nominal type.
payload: []u32 = &.{},
words: std.ArrayList(u32) = .empty,
scratch_words: std.ArrayList(u32) = .empty,
/// The module's derived contexts, which memoise the gate (`functionFree`).
contexts: *Contexts,
/// The solver, whose groups a gate demands (`functionFree`).
solve: *Solve,
/// The gates this walk found unknown (a schema in flight), and at what.
unknown_gates: std.ArrayList(struct { type_id: Types.TypeId, v: Var }) = .empty,
/// The rank of the current frame when it is a fixpoint frame, else 0, set
/// by the caller: §11.2's frame assert (CK-117) covers the flags this walk
/// writes, as `Unify.assertContained` covers a merge.
fixpoint_rank: u32 = 0,

const unknown: u32 = std.math.maxInt(u32);
const all: u32 = std.math.maxInt(u32) - 1;

pub fn deinit(in: *Marker) void {
    const gpa = in.cx.gpa;
    in.stack.deinit(gpa);
    in.met.deinit(gpa);
    in.fields.deinit(gpa);
    gpa.free(in.payload);
    in.words.deinit(gpa);
    in.scratch_words.deinit(gpa);
    in.unknown_gates.deinit(gpa);
}

/// The gate for `T` itself (§11.4 *as amended by R8b's review rounds*,
/// CK-120): `functionFree`. Unknown while a schema its payloads go through
/// is in flight: then it passes for now, and the walk's question is asked
/// again of `T` in P5 (`unknown_gates`, handed to `Contexts.deferred_gates` when
/// the walk says yes).
fn gate(in: *Marker, id: Types.TypeId, root: Var) Error!bool {
    return (try functionFree(in.cx, in.contexts, in.solve, id)) orelse {
        try in.unknown_gates.append(in.cx.gpa, .{ .type_id = id, .v = root });
        return true;
    };
}

/// §11.4's gate for `T` itself, the one answer to "can a function be inside
/// a `T`, whatever its arguments": a `foreign type` is its declared
/// `equatable` bit; a type of this module has no function reachable from
/// its payloads — through its module's own types and schema endpoints
/// (their `via` targets as inferred so far), and the gate of every other
/// module's type; another module's type is its published `no_function`
/// (§14.2 *as amended by R8b*; from R9 every record a v2 build reads is
/// v2's, §22.1). Memoised per local type in
/// `Contexts` for the current generation (a group completing may infer a
/// `via` target), permanently in a module without schemas; a walk that
/// finds no function proves it of every type it met.
///
/// Before R8b's review round the gate of a plain type was the table-build
/// bit, which cannot see a `via` target: `==` on a type wrapping an
/// endpoint that holds a function was refused, and `Basics.eq` on it
/// accepted (CK-120).
pub fn functionFree(cx: *const Context, contexts: *Contexts, solve: ?*Solve, id: Types.TypeId) Error!?bool {
    if (id == .none or id.int() >= cx.types.entries.len) return true;
    const entry = cx.types.entry(id);
    if (entry.kind == .foreign) return cx.types.isEquatable(id);
    if (entry.kind != .adt) return true;
    if (entry.module != cx.module) return importedGate(cx, id);
    const own = contexts.local(id) orelse return true;
    if (contexts.gateKnown(own)) |ok| return ok;
    // Every schema with a `via` the walk can reach, demanded (as for a
    // derived context, `Contexts.complete`) — so an unchecked schema's
    // unfilled target never reads as "no function" — and none in flight;
    // else unknown, and nothing memoised (R8b's round-2 review, B1). After
    // P4 (`solve` null) every group is done and P5 completed the graph.
    if (solve) |s| {
        if (!try Contexts.complete(s, &.{own})) return null;
    }
    const store = cx.store;
    const gpa = cx.gpa;
    var met: std.ArrayList(u32) = .empty;
    defer met.deinit(gpa);
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(gpa);
    try met.append(gpa, own);
    contexts.gate_walk += 1;
    const walk_stamp = contexts.gate_walk;
    contexts.gate_seen[own] = walk_stamp;
    try pushPayloads(cx, contexts, own, &stack);
    const seen = store.nextMark();
    // A mark of its own, taken inside the marker walk's epoch: a node that
    // walk re-marks may be visited twice, which is harmless (review N8).
    const ok = while (stack.pop()) |next| {
        const root, const content = store.resolved(next);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        switch (content) {
            .structure => |flat| switch (flat) {
                .func => break false,
                .app => |a| {
                    const e = cx.types.entry(a.type);
                    if (contexts.local(a.type)) |t| {
                        if (e.kind == .adt and contexts.gate_seen[t] != walk_stamp) {
                            if (contexts.gateKnown(t)) |known| {
                                if (!known) break false;
                            } else {
                                contexts.gate_seen[t] = walk_stamp;
                                try met.append(gpa, t);
                                try pushPayloads(cx, contexts, t, &stack);
                            }
                        } else if (e.kind == .foreign and !cx.types.isEquatable(a.type)) break false;
                    } else if (!((try functionFree(cx, contexts, null, a.type)) orelse true)) break false;
                },
                else => {},
            },
            else => continue,
        }
        var n: u32 = 0;
        while (Walk.child(store, root, n, .structural)) |c| : (n += 1) try stack.append(gpa, c);
    } else true;
    // A walk that found no function explored every type it met in full.
    if (ok) {
        for (met.items) |t| contexts.setGate(t, true);
    } else contexts.setGate(own, false);
    return ok;
}

/// Another module's type's gate: its published `no_function`.
fn importedGate(cx: *const Context, id: Types.TypeId) bool {
    const entry = cx.types.entry(id);
    if (entry.module.int() >= cx.interfaces.len) return cx.types.isEquatable(id);
    const iface = cx.iface(entry.module);
    const facts = iface.typeFacts(cx.interner, entry.name) orelse return cx.types.isEquatable(id);
    return facts.no_function;
}

/// Local type `t`'s payloads onto `stack`: a tagged endpoint's from its
/// schema (`Schema.State`), a `type`'s constructor arguments read at
/// generalised rank with fresh parameters (as `Publish.payloadParams`).
fn pushPayloads(cx: *const Context, contexts: *Contexts, t: u32, stack: *std.ArrayList(Var)) Error!void {
    const id = contexts.typeId(t);
    const entry = cx.types.entry(id);
    if (entry.schema_endpoint) {
        const ep: Interface.SchemaCtor.Endpoint = if (cx.types.ofSchemaDecl(cx.module, entry.decl, .type) == id) .type else .encoded;
        return cx.schemas.payloads(entry.decl.int(), ep, stack, cx.gpa);
    }
    const bir = cx.bir;
    const d = bir.decls[entry.decl.int()];
    var b = cx.builder(.flex, TypeStore.generalized);
    defer b.deinit();
    for (bir.declTypeParams(d)) |p| try b.bind(p, try cx.store.fresh(.{ .flex = .{ .name = p.toOptional() } }, TypeStore.generalized));
    for (bir.declCtors(d)) |ctor| {
        for (bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index)) |arg| {
            try stack.append(cx.gpa, try b.read(arg));
        }
    }
}
/// §11.4's walk over `v`, for an obligation raised at `region` whose
/// question is `origin`'s. On `yes`, every flex it met gets the flag and a
/// row of the same origin at the same region — only then, so a failure
/// leaves nothing behind that could report the same question again, and how
/// many flexes the walk reached before it failed (which depends on symbol
/// ids) changes nothing (I13, review B1).
pub fn equatable(in: *Marker, v: Var, region: Bir.Inst.Index, origin: Obligations.Id) Error!Answer {
    in.met.clearRetainingCapacity();
    in.unknown_gates.clearRetainingCapacity();
    const answer = try in.walk(v, .propagate);
    if (answer == .yes) {
        // A gate unknown now is asked again in P5 (`Contexts.checkDeferred`).
        for (in.unknown_gates.items) |u| try in.contexts.deferred_gates.append(in.cx.scratch, .{ .type_id = u.type_id, .v = u.v, .region = region, .origin = origin, .decl = in.solve.report.current });
        const store = in.cx.store;
        const gpa = in.cx.gpa;
        for (in.met.items) |root| {
            if (std.debug.runtime_safety and in.fixpoint_rank != 0) {
                const rank = store.rank(root);
                if (rank != TypeStore.generalized and rank < in.fixpoint_rank)
                    std.debug.panic("a fixpoint frame's marker walk flagged a variable of an older frame (checker-v2.md §11.2, CK-117)", .{});
            }
            // The flags copied and one field changed, never rebuilt (CK-18).
            var flagged = store.content(root).flex;
            if (flagged.equatable) continue;
            flagged.equatable = true;
            const id = try in.obligations.create(gpa, .equatable, region, &.{root}, 0, origin);
            flagged.obls = try in.obligations.with(gpa, flagged.obls, id, true);
            store.setContent(root, .{ .flex = flagged });
        }
        return .yes;
    }
    // Which failure is said is chosen in name-text order (I13).
    return in.walk(v, .choose);
}

const Mode = enum { propagate, choose };

/// Read-only: the answer, and in `.propagate` mode the flexes met without
/// the flag, in `met`.
fn walk(in: *Marker, v: Var, comptime mode: Mode) Error!Answer {
    const cx = in.cx;
    const store = cx.store;
    const gpa = cx.gpa;
    const seen = store.nextMark();
    in.stack.clearRetainingCapacity();
    try in.stack.append(gpa, v);
    while (in.stack.pop()) |next| {
        const root, const content = store.resolved(next);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        switch (content) {
            // `resolved` followed every alias; one left means a poisoned
            // chain, which has a message already.
            .err, .alias => {},
            .flex => |flags| if (mode == .propagate and !flags.equatable) try in.met.append(gpa, root),
            .rigid => |flags| if (!flags.equatable) return .rigid,
            .structure => |flat| switch (flat) {
                .unit, .empty_record => {},
                .func => return .function,
                .tuple => try in.pushReversed(root),
                .record => |r| {
                    if (mode == .propagate) {
                        try in.pushReversed(root);
                        continue;
                    }
                    // Pushed in reverse text order, so the first by text is
                    // walked first; the extension last.
                    try in.stack.append(gpa, r.ext);
                    in.fields.clearRetainingCapacity();
                    try in.fields.appendSlice(gpa, Walk.recordFields(store, r));
                    std.mem.sort(TypeStore.Field, in.fields.items, cx.interner, fieldTextGreater);
                    for (in.fields.items) |f| try in.stack.append(gpa, f.value);
                },
                .app => |a| {
                    if (!try in.gate(a.type, root)) return .opaque_type;
                    // `payloadParams` may read an own declaration, taking
                    // marks of its own mid-walk: a node it re-marks can be
                    // visited twice, which is harmless (review N8).
                    const bits = try in.payloadParams(a.type);
                    var i: u32 = a.args.len;
                    // Pushed last to first, so the arguments are walked in order.
                    while (i > 0) {
                        i -= 1;
                        if (!has(bits, i)) continue;
                        try in.stack.append(gpa, Walk.child(store, root, i, .structural).?);
                    }
                },
            },
        }
    }
    return .yes;
}

/// Push every `structural` successor of `root`, last first, so they are
/// walked in order (review N4).
fn pushReversed(in: *Marker, root: Var) Error!void {
    const start = in.stack.items.len;
    var n: u32 = 0;
    while (Walk.child(in.cx.store, root, n, .structural)) |c| : (n += 1) try in.stack.append(in.cx.gpa, c);
    std.mem.reverse(Var, in.stack.items[start..]);
}

fn fieldTextGreater(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
    return std.mem.lessThan(u8, interner.slice(b.name), interner.slice(a.name));
}

/// The bits of `payload_params`, or null for "every parameter".
const Bits = ?[]const u32;

fn has(bits: Bits, i: usize) bool {
    const words = bits orelse return true;
    if (i / 32 >= words.len) return true;
    return words[i / 32] & (@as(u32, 1) << @intCast(i % 32)) != 0;
}

/// Which parameters of `id` occur in a constructor payload (D10): this
/// module's own declaration read now, another module's from its interface
/// (§14.2): its exported row, or the hidden row of a private type an importer
/// reaches (R8b). Every parameter when that cannot be known — a type with no
/// row, a record not yet filled, a schema
/// endpoint — which is the side that asks more, never less.
fn payloadParams(in: *Marker, id: Types.TypeId) Error!Bits {
    const cx = in.cx;
    const gpa = cx.gpa;
    if (id == .none or id.int() >= cx.types.entries.len) return null;
    if (in.payload.len == 0) {
        in.payload = try gpa.alloc(u32, cx.types.entries.len);
        @memset(in.payload, unknown);
    }
    const slot = &in.payload[id.int()];
    if (slot.* == unknown) slot.* = try in.fill(id);
    if (slot.* == all) return null;
    const entry = cx.types.entry(id);
    const len = (@as(usize, entry.arity) + 31) / 32;
    return in.words.items[slot.*..][0..len];
}

fn fill(in: *Marker, id: Types.TypeId) Error!u32 {
    const cx = in.cx;
    const gpa = cx.gpa;
    const entry = cx.types.entry(id);
    if (entry.arity == 0) return all;
    if (entry.schema_endpoint) return all;
    const len = (@as(usize, entry.arity) + 31) / 32;
    const start: u32 = @intCast(in.words.items.len);
    if (entry.module == cx.module) {
        try Publish.payloadParams(cx, entry.decl, entry.kind, entry.arity, &in.scratch_words);
        if (in.scratch_words.items.len != len) return all;
        try in.words.appendSlice(gpa, in.scratch_words.items);
        return start;
    }
    // Its exported row, or the hidden row of a private type an importer
    // reaches through a published scheme (§14.2 *as amended by R8a*; R8b).
    if (entry.module.int() >= cx.interfaces.len) return all;
    const iface = cx.iface(entry.module);
    const facts = iface.typeFacts(cx.interner, entry.name) orelse return all;
    if (facts.payload_params == Interface.no_terms) return all;
    const words = iface.range(facts.payload_params);
    if (words.len != len) return all;
    try in.words.appendSlice(gpa, words);
    return start;
}
