//! Wanteds, givens and the canonical order (checker-v2.md §4.2, §12.1).
//!
//! **A wanted is one method requirement at one use**: "whatever type ends up
//! as `receiver` has a method `method` of type `method_type` here". It is
//! created by a `method` node (a dot-call, an operator, a `type_dispatch`),
//! by instantiating a scheme with requirements (one per requirement: I5), or
//! by resolving another wanted (a sub-wanted: an instance's context, or a
//! derived shape's position). It is answered exactly once (I6), by the
//! resolver (`Resolve.zig`): a given, an instance, a primitive, a promotion
//! to a parameter or the proven-undetermined default.
//!
//! **Where a wanted rides** (§4.1, *Decided by R5*, and as R6a writes it
//! down). An OPEN wanted on a flex receiver is one entry of that flex's
//! `Flags.constraints` — the shared set `Schemes.Writer` publishes and
//! `Render` prints — so a flex's constraint set is exactly its open
//! wanteds. The pairing is by POSITION in the store's append-only
//! `constraints` table: `slots[p]` names the wanted (or, on a rigid, the
//! given) whose entry sits at position `p`. A position never changes
//! meaning, and every place v2 makes an entry — attaching, a merge's union,
//! an instantiation's copy, an imported scheme's read — writes its slot in
//! the same step. An entry v2 did not make (none today) reads `none`.
//!
//! **A given is a `where` clause's requirement on an annotation's rigid
//! variable** (§4.2): the rigid's own constraint set, read with the
//! annotation, and `k`, its index in the declaration's requirement list in
//! canonical order (§12.1). Rigid sets are never rebuilt, so a given's
//! position is its identity.
//!
//! No write here is journalled: v2 has no speculation (§7.5), so I14 holds
//! by absence — `Resolve` asserts that no snapshot is open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("Dispatch.zig");
const Schemes = @import("Schemes.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");

const Evidence = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

pub const WantedId = enum(u32) {
    _,

    pub fn int(id: WantedId) u32 {
        return @intFromEnum(id);
    }

    pub fn toOptional(id: WantedId) Optional {
        return @enumFromInt(@intFromEnum(id));
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?WantedId {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };
};

/// The surface a requirement came from, which decides two things: whether
/// it may derive (a hand-written `x.eq y` may not: static-dispatch-spike.md
/// §1.3 rule 2) and which sentence a failure gets.
pub const Kind = TypeStore.MethodConstraint.Origin;

pub const State = enum(u8) {
    /// Riding on a flex receiver (an entry of its constraint set).
    open,
    /// Its receiver was bound: on the `ready` queue, not decided yet.
    ready,
    answered,
    /// A requirement of its binder's scheme (§9.4).
    promoted,
    /// The proven-undetermined default (§9.4).
    defaulted,
    /// Rejected, with a message or in silence (against `err`).
    failed,
};

/// What a wanted is bound to: the evidence TERM before elaboration (§4.2).
/// P6 (R6b) turns these into `Dispatch.Term` trees; R6a records them.
pub const Answer = union(enum(u8)) {
    none,
    /// The `k`th evidence parameter of declaration `decl` (§4.3's
    /// `Binder.decl`; `let_def` binders are R14's, derived ones R8a's): a
    /// given, whose `k` is its annotation's own.
    param: struct { decl: u32, k: u32 },
    /// Promoted (§9.4): the requirement `(root, method)` of the group's
    /// schemes. Its index is the SITE's member's, computed by P6 from that
    /// member's own list (§12.3), never stored here.
    promoted: struct { root: Var, method: Symbol },
    /// A Rule-U1 join, or a repeated position of one derived shape: this
    /// wanted IS that one.
    alias: WantedId,
    top: struct { decl: u32, args: Range },
    ext: struct { module: Graph.Index, value: Interface.ValueIndex, args: Range },
    /// A derived function: a nominal type's (`type_id` set) or a structural
    /// shape's, with one sub-wanted per context entry or position.
    derived: struct { type_id: TypeStore.TypeId, args: Range },
    primitive: Dispatch.Primitive,
    /// §9.4's proven-undetermined default.
    undetermined,
    /// The callee of a dot-call on a record's function field.
    field,
    /// An in-flight member of the group being checked (§10.3): its
    /// arguments come from the member's final list (§12.3, R6b).
    group_call: u32,
};

/// A run of `args`.
pub const Range = struct { start: u32 = 0, len: u32 = 0 };

pub const Wanted = struct {
    method: Symbol,
    /// The carrier; it may become concrete.
    receiver: Var,
    /// The method's type AT THIS USE.
    method_type: Var,
    /// The instruction of this module that raised it: where it reports.
    origin: Bir.Inst.Index,
    kind: Kind,
    /// The declaration whose failure bit a message about it sets (§15.2).
    decl: u32,
    /// The wanted whose resolution created this one (the lineage of §9.5).
    parent: WantedId.Optional,
    /// Module-wide creation order, shared with obligations (§9.1).
    seq: u32,
    /// A dot-call's own wanted, and every wanted joined with it by Rule U1 one
    /// too (`joinField`): only then may a record met late answer it as a field
    /// call (static-dispatch-spike.md §11 *Deferred receiver*, amended
    /// 2026-09-26). A scheme's requirement joined in has no field accessor to
    /// be (R7's round-2 review, X1). Kept on the older wanted, the one an
    /// `alias` chain ends at.
    field_ok: bool = false,
    /// When `field_ok` was cleared by a join: the requirement joined in, where
    /// a refusal on a record is reported (the use that needs a method).
    blocked_at: Bir.Inst.OptionalIndex = .none,
    /// The `ready` queue of the frame current at creation (§9.1, round 4
    /// R4-1): where a unification readies it, whichever frame unified.
    frame: u32,
    state: State = .open,
    /// An instantiated requirement's quantifier name — the `a` of the
    /// callee's `where a.compare` — kept here because its receiver is
    /// bound to a type before a message about the clause is written
    /// (static-dispatch-spike.md §10.13, CK-55).
    receiver_name: Symbol.Optional = .none,

    pub const no_decl: u32 = std.math.maxInt(u32);
};

pub const Given = struct {
    rigid: Var,
    method: Symbol,
    method_type: Var,
    /// The annotated declaration whose `where` clause wrote it.
    decl: u32,
    /// Its index in `decl`'s requirement list, canonical order (§12.1).
    k: u32,
    /// Where the clause wrote it (its type), for a message about the clause.
    region: Bir.Inst.Index,
};

/// What sits at one position of the store's `constraints` table.
pub const Slot = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    const given_bit: u32 = 1 << 31;

    pub fn wanted(id: WantedId) Slot {
        return @enumFromInt(id.int());
    }

    pub fn given(index: u32) Slot {
        return @enumFromInt(index | given_bit);
    }

    pub fn asWanted(s: Slot) ?WantedId {
        if (s == .none or @intFromEnum(s) & given_bit != 0) return null;
        return @enumFromInt(@intFromEnum(s));
    }

    pub fn asGiven(s: Slot) ?u32 {
        if (s == .none or @intFromEnum(s) & given_bit == 0) return null;
        return @intFromEnum(s) & ~given_bit;
    }
};

/// One `ready` queue item: an obligation id, or a wanted id with this bit
/// set. Both share one `seq`, so a queue of both drains in creation order
/// (§9.1, round 4 S4-4).
pub const queued_wanted: u32 = 1 << 31;

pub const Callee = struct { inst: Bir.Inst.Index, wanted: WantedId };
pub const InstEvidence = struct { inst: Bir.Inst.Index, args: Range };
pub const Flag = struct { method: Symbol, derives: bool };

wanteds: std.ArrayList(Wanted) = .empty,
answers: std.ArrayList(Answer) = .empty,
args: std.ArrayList(WantedId) = .empty,
givens: std.ArrayList(Given) = .empty,
slots: std.ArrayList(Slot) = .empty,
/// Per `method_call`/`type_dispatch` instruction, the wanted naming the
/// function it runs (§4.2's `inst_callee`), in creation order.
callees: std.ArrayList(Callee) = .empty,

/// Per instruction that instantiated a scheme with requirements, its
/// wanteds in the scheme's canonical order (§4.2's `inst_evidence`, I5):
/// a range of `args`. P6 reads it as it stands.
inst_evidence: std.ArrayList(InstEvidence) = .empty,
/// Per annotated declaration with a `where` clause, its givens: a run of
/// `givens`.
given_ranges: std.AutoHashMapUnmanaged(u32, Range) = .empty,

/// §9.5's class flag (CK-37): per concrete receiver root, the methods a
/// rejection has already reported there. `Unify` moves a root's flags to
/// the survivor of every merge (OR-merged on union).
rejected: std.AutoHashMapUnmanaged(Var, std.ArrayList(Flag)) = .empty,

pub fn deinit(e: *Evidence, gpa: Allocator) void {
    e.wanteds.deinit(gpa);
    e.answers.deinit(gpa);
    e.args.deinit(gpa);
    e.givens.deinit(gpa);
    e.slots.deinit(gpa);
    e.callees.deinit(gpa);
    e.inst_evidence.deinit(gpa);
    e.given_ranges.deinit(gpa);
    var it = e.rejected.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    e.rejected.deinit(gpa);
}

/// Whether root `root` already rejected `flag` (§9.5).
pub fn isRejected(e: *const Evidence, root: Var, flag: Flag) bool {
    const list = e.rejected.get(root) orelse return false;
    for (list.items) |f| {
        if (f.method == flag.method and f.derives == flag.derives) return true;
    }
    return false;
}

pub fn setRejected(e: *Evidence, gpa: Allocator, root: Var, flag: Flag) Error!void {
    if (e.isRejected(root, flag)) return;
    const entry = try e.rejected.getOrPut(gpa, root);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(gpa, flag);
}

/// A merge made `kept` the root of `dropped`'s class: its flags move there.
pub fn mergeRejected(e: *Evidence, gpa: Allocator, dropped: Var, kept: Var) Error!void {
    if (dropped == kept or e.rejected.count() == 0) return;
    var moved = (e.rejected.fetchRemove(dropped) orelse return).value;
    defer moved.deinit(gpa);
    for (moved.items) |f| try e.setRejected(gpa, kept, f);
}

pub fn get(e: *const Evidence, id: WantedId) Wanted {
    return e.wanteds.items[id.int()];
}

pub fn ptr(e: *Evidence, id: WantedId) *Wanted {
    return &e.wanteds.items[id.int()];
}

pub fn answer(e: *const Evidence, id: WantedId) Answer {
    return e.answers.items[id.int()];
}

pub fn setAnswer(e: *Evidence, id: WantedId, a: Answer) void {
    e.answers.items[id.int()] = a;
}

/// Rule U1 made `younger` an `alias` of `older`: the joined class is a field
/// call only if both were a dot-call's own (`Wanted.field_ok`). The join set
/// does not depend on the order, so neither does the verdict.
pub fn joinField(e: *Evidence, older: WantedId, younger: WantedId) void {
    const y = e.get(younger);
    const o = e.ptr(older);
    if (o.field_ok and !y.field_ok) o.blocked_at = y.origin.toOptional();
    o.field_ok = o.field_ok and y.field_ok;
}

/// A merged frame's hand-down (§9.1 *Merges*): every wanted made since
/// `start` that routes to queue `from` routes to `to`.
pub fn repoint(e: *Evidence, start: u32, from: u32, to: u32) void {
    for (e.wanteds.items[start..]) |*w| {
        if (w.frame == from) w.frame = to;
    }
}

pub fn add(e: *Evidence, gpa: Allocator, w: Wanted) Error!WantedId {
    std.debug.assert(w.frame != std.math.maxInt(u32));
    const id: WantedId = @enumFromInt(@as(u32, @intCast(e.wanteds.items.len)));
    try e.wanteds.append(gpa, w);
    try e.answers.append(gpa, .none);
    return id;
}

/// A range of `args` holding `ids`.
pub fn addArgs(e: *Evidence, gpa: Allocator, ids: []const WantedId) Error!Range {
    const start: u32 = @intCast(e.args.items.len);
    try e.args.appendSlice(gpa, ids);
    return .{ .start = start, .len = @intCast(ids.len) };
}

/// The wanteds of an answer's or an instantiation's `args` range.
pub fn argsOf(e: *const Evidence, r: Range) []const WantedId {
    return e.args.items[r.start..][0..r.len];
}

pub fn slotAt(e: *const Evidence, at: u32) Slot {
    return if (at < e.slots.items.len) e.slots.items[at] else .none;
}

/// Pair at `at` of the store's `constraints` with `slot`.
pub fn setSlot(e: *Evidence, gpa: Allocator, at: u32, slot: Slot) Error!void {
    if (at >= e.slots.items.len) {
        const old = e.slots.items.len;
        try e.slots.resize(gpa, at + 1);
        @memset(e.slots.items[old..], .none);
    }
    e.slots.items[at] = slot;
}

/// The position of entry `i` of `set` in the store's `constraints` table.
pub fn position(store: *const TypeStore, set: TypeStore.ConstraintSet.Optional, i: u32) u32 {
    const s = set.unwrap().?;
    return store.constraint_sets.items[s.int()].start + i;
}

/// What rides on `set` under `name`: nothing, its wanted, or an entry paired
/// with none — which a live flex never has, and the caller says `internal`
/// (review S2).
pub const Named = union(enum) { absent, unpaired, wanted: WantedId };

pub fn named(e: *const Evidence, store: *const TypeStore, set: Walk.Constraints, name: Symbol) Named {
    const n = set.count(store);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (set.at(store, i).name != name) continue;
        const id = e.slotAt(position(store, set.set, i)).asWanted() orelse return .unpaired;
        return .{ .wanted = id };
    }
    return .absent;
}

/// What answers a wanted on a rigid: the given's method type and, when a
/// declaration registered it, that declaration and the given's index.
pub const GivenRef = struct { method_type: Var, decl: u32, k: u32 };

/// The given of a rigid's set named `name`, if any.
pub fn givenNamed(e: *const Evidence, store: *const TypeStore, set: Walk.Constraints, name: Symbol) ?GivenRef {
    const n = set.count(store);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const c = set.at(store, i);
        if (c.name != name) continue;
        if (e.slotAt(position(store, set.set, i)).asGiven()) |g| {
            const given = e.givens.items[g];
            return .{ .method_type = given.method_type, .decl = given.decl, .k = given.k };
        }
        // Every rigid reading registers its givens (`registerGivens`); a
        // set with none is the compiler's to explain, and `Resolve` says
        // `internal` when it answers from one.
        return .{ .method_type = c.fn_var, .decl = Wanted.no_decl, .k = 0 };
    }
    return null;
}

/// Register the givens of an annotated declaration's rigid reading `check`
/// (§4.2): every requirement its rigids carry, with its canonical index.
pub fn registerGivens(
    e: *Evidence,
    gpa: Allocator,
    store: *TypeStore,
    interner: *const InternPool.Global,
    scratch: Allocator,
    check: Var,
    decl: u32,
) Error!void {
    var list: std.ArrayList(Requirement) = .empty;
    defer list.deinit(scratch);
    try requirements(store, interner, check, scratch, &list);
    const first: u32 = @intCast(e.givens.items.len);
    for (list.items, 0..) |r, k| {
        const index: u32 = @intCast(e.givens.items.len);
        const c = store.constraints.items[r.position];
        try e.givens.append(gpa, .{
            .rigid = r.root,
            .method = r.method,
            .method_type = c.fn_var,
            .decl = decl,
            .k = @intCast(k),
            .region = c.region,
        });
        try e.setSlot(gpa, r.position, .given(index));
    }
    try e.given_ranges.put(gpa, decl, .{ .start = first, .len = @intCast(list.items.len) });
}

/// The givens declaration `decl`'s rigid reading registered.
pub fn givensOf(e: *const Evidence, decl: u32) []const Given {
    const r = e.given_ranges.get(decl) orelse return &.{};
    return e.givens.items[r.start..][0..r.len];
}

// ---------------------------------------------------------------------------
// The canonical order (§12.1)
// ---------------------------------------------------------------------------

/// One requirement of a scheme: the quantifier (a root), its index in
/// `Schemes.Writer`'s discovery order, its method, and the constraint's
/// position in the store's table.
pub const Requirement = struct { root: Var, quantified: u16, method: Symbol, position: u32, index: u32 };

/// `scheme`'s requirements in static-dispatch-spike.md §7.2's canonical
/// order: quantifiers in `Schemes.Writer` discovery order, then method name
/// text. THE one function for promotion, instantiation evidence and the
/// interface's `where` blocks (which the writer computes by the same rule,
/// `Schemes.quantifierOrder`): exporter and importer agree by construction.
pub fn requirements(
    store: *TypeStore,
    interner: *const InternPool.Global,
    scheme: Var,
    scratch: Allocator,
    out: *std.ArrayList(Requirement),
) Error!void {
    var order: std.ArrayList(Var) = .empty;
    defer order.deinit(scratch);
    try Schemes.quantifierOrder(store, interner, scheme, &order, scratch);
    for (order.items, 0..) |root, q| {
        const set = Walk.constraints(store.flagsOf(root));
        const n = set.count(store);
        if (n == 0) continue;
        const start = out.items.len;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try out.append(scratch, .{
                .root = root,
                .quantified = @intCast(q),
                .method = set.at(store, i).name,
                .position = position(store, set.set, i),
                .index = i,
            });
        }
        std.mem.sort(Requirement, out.items[start..], interner, methodTextLessThan);
    }
}

fn methodTextLessThan(interner: *const InternPool.Global, a: Requirement, b: Requirement) bool {
    return std.mem.lessThan(u8, interner.slice(a.method), interner.slice(b.method));
}
