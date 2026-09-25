//! Capabilities of types (checker-v2.md §9.3, §11). R5 builds its first
//! part: the **`equatable` marker walk** of §11.4 (CK-16, CK-17, CK-18),
//! the structural guarantee explicit `Basics.eq` and `Basics.neq` ask for.
//! Instance lookup, matching and derived contexts are R6a's and R8a's.
//!
//! The marker is never an `eq` method, and the resolver never reads it
//! (CK-19). The walk:
//!
//!   - takes `structural` successors (I2), with a growable stack and a
//!     visited mark (I4, CK-17): a width of 100 000 fields is walked to the
//!     end, and a cycle is walked once (the occurs check reports it);
//!   - at a nominal `T args` asks the session's gate for `T` itself — no
//!     function anywhere in its declaration, and a `foreign type` declared
//!     `equatable` (`Types.isEquatable`) — and then descends only into the
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
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Context = @import("Context.zig");
const Obligations = @import("Obligations.zig");
const Publish = @import("Publish.zig");
const Walk = @import("Walk.zig");

const Instances = @This();

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

const unknown: u32 = std.math.maxInt(u32);
const all: u32 = std.math.maxInt(u32) - 1;

pub fn deinit(in: *Instances) void {
    const gpa = in.cx.gpa;
    in.stack.deinit(gpa);
    in.met.deinit(gpa);
    in.fields.deinit(gpa);
    gpa.free(in.payload);
    in.words.deinit(gpa);
    in.scratch_words.deinit(gpa);
}

/// §11.4's walk over `v`, for an obligation raised at `region` whose
/// question is `origin`'s. On `yes`, every flex it met gets the flag and a
/// row of the same origin at the same region — only then, so a failure
/// leaves nothing behind that could report the same question again, and how
/// many flexes the walk reached before it failed (which depends on symbol
/// ids) changes nothing (I13, review B1).
pub fn equatable(in: *Instances, v: Var, region: Bir.Inst.Index, origin: Obligations.Id) Error!Answer {
    in.met.clearRetainingCapacity();
    const answer = try in.walk(v, .propagate);
    if (answer == .yes) {
        const store = in.cx.store;
        const gpa = in.cx.gpa;
        for (in.met.items) |root| {
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
fn walk(in: *Instances, v: Var, comptime mode: Mode) Error!Answer {
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
                    if (!cx.types.isEquatable(a.type)) return .opaque_type;
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
fn pushReversed(in: *Instances, root: Var) Error!void {
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
/// (§14.2). Every parameter when that cannot be known — a type with no
/// interface row (a private type reached through an alias), a record not yet
/// filled, a schema endpoint — which is the side that asks more, never less.
fn payloadParams(in: *Instances, id: Types.TypeId) Error!Bits {
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

fn fill(in: *Instances, id: Types.TypeId) Error!u32 {
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
    const iface = cx.iface(entry.module);
    for (0..iface.types.len) |ti| {
        if (cx.types.ofInterface(entry.module, @enumFromInt(ti)) != id) continue;
        const t = iface.types[ti];
        if (t.payload_params == Interface.no_terms) return all;
        const words = iface.range(t.payload_params);
        if (words.len != len) return all;
        try in.words.appendSlice(gpa, words);
        return start;
    }
    return all;
}
