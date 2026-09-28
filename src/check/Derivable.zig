//! THE derivability verdict (checker-v2.md §9.5,
//! §11.1): "can this receiver derive `eq` or `compare`, and
//! if not, why", asked once per derived answer and reported at the use for
//! the receiver the author compared.
//!
//! **It reads the one answer** (whether `T` answers `m` has one answer per
//! module): a nominal type's head is what
//! its derived context says (`Contexts` for this module's types, the
//! published row for another's, §14.2), or what its method's requirements
//! say when the module rule answers it (a custom method is a boundary: its
//! requirements, not its payloads, say what the arguments must answer).
//! Nothing here settles, caches a capability, or has a second opinion — a
//! tagged schema endpoint's head included (§11.5), whose context is
//! computed over its schema's payloads like any `type`'s.
//!
//! One iterative walk over `(node, method)` pairs, coloured per pair (a pair
//! met grey again is a cycle, whichever method the contexts alternate
//! through), no native recursion, and linear on a DAG. A head that
//! needs a fixpoint run or a nested group check first stops the walk
//! (`pending`, `query`); `derivable` does it and walks again.

const std = @import("std");
const InternPool = @import("../InternPool.zig");
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Dispatch = @import("Dispatch.zig");
const Contexts = @import("Contexts.zig");
const Evidence = @import("Evidence.zig");
const Messages = @import("Messages.zig");
const Resolve = @import("Resolve.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Solve.Error;
const WantedId = Evidence.WantedId;
const Kind = Dispatch.Derived.Kind;

pub const PairKey = struct { root: Var, kind: Kind };

/// The pairs proved derivable over a ground subgraph
/// (`Resolve.State.derivable`): one byte per variable, bit `kind`, grown
/// with the store. A dense id indexes a column, never a hash map.
///
/// Keyed by a variable id, so sound only while no id is reused for another
/// type: the checker never rolls the store back (§7.5). A rollback while the memo
/// holds anything (`TypeStore.rollbacks` moved since its first write) is a
/// panic in a safe build, and empties it otherwise (§9.3).
pub const GroundMemo = struct {
    bits: std.ArrayList(u8) = .empty,
    /// `TypeStore.rollbacks` at the first write, or null while empty.
    generation: ?u32 = null,

    pub fn contains(m: *GroundMemo, store: *const TypeStore, key: PairKey) bool {
        m.guard(store);
        const i = key.root.int();
        return i < m.bits.items.len and m.bits.items[i] & bit(key.kind) != 0;
    }

    fn guard(m: *GroundMemo, store: *const TypeStore) void {
        const g = m.generation orelse return;
        if (g == store.rollbacks) return;
        if (std.debug.runtime_safety) std.debug.panic("the type store rolled back under a memo keyed by variable ids (checker-v2.md §9.3)", .{});
        m.bits.clearRetainingCapacity();
        m.generation = null;
    }

    pub fn put(m: *GroundMemo, gpa: std.mem.Allocator, store: *const TypeStore, key: PairKey) Error!void {
        m.guard(store);
        if (m.generation == null) m.generation = store.rollbacks;
        const i = key.root.int();
        if (i >= m.bits.items.len) {
            const len = @max(store.count(), i + 1);
            try m.bits.appendNTimes(gpa, 0, len - m.bits.items.len);
        }
        m.bits.items[i] |= bit(key.kind);
    }

    fn bit(kind: Kind) u8 {
        return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(kind)));
    }
};

/// The ground shapes this module proved derivable
/// (`Resolve.State.shapes`), keyed by their STRUCTURE, not by a variable: a
/// module that compares `( Int, List Int )` in 6 000 declarations walks it
/// once. Only a shape whose every nominal head is §3.2's or another
/// module's is kept — the verdict then reads nothing but the structure, the
/// table and interfaces that cannot change during the module's check — and
/// only up to `shape_cap` words, which also stops at a cyclic graph.
pub const Shapes = struct {
    /// Owned keys: `std.mem.sliceAsBytes` of an encoding.
    map: std.StringHashMapUnmanaged(void) = .empty,
    /// The encoding being built: the kind, then the receiver in preorder,
    /// each node a tag and its arity (so no two shapes share an encoding).
    words: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(Var) = .empty,
    /// The last encoding's receiver and kind, what it found, and
    /// `TypeStore.rollbacks` then: `words` holds its encoding while `last`
    /// names it (`derivable` reads it before and after the walk). Keyed by a
    /// variable id: a rollback since is a panic in a safe build and a miss
    /// otherwise (`GroundMemo`).
    last: ?struct { root: Var, kind: Kind, ground: ?Ground, generation: u32 } = null,

    pub fn deinit(sh: *Shapes, gpa: std.mem.Allocator) void {
        var it = sh.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        sh.map.deinit(gpa);
        sh.words.deinit(gpa);
        sh.stack.deinit(gpa);
    }
};

const shape_cap = 64;

/// A ground receiver of at most `shape_cap` words.
pub const Ground = struct {
    /// Its encoding, valid until the next `groundShape`.
    key: []const u8,
    /// Every nominal head is §3.2's or another module's: `Shapes` may keep it.
    kept: bool,
};

/// `root`'s encoding for `Shapes` under `kind`, or null when it has a
/// variable, a function, or more than `shape_cap` words (a cyclic graph
/// among them).
pub fn groundShape(s: *Solve, root: Var, kind: Kind) Error!?Ground {
    const sh = &s.resolver.shapes;
    const generation = s.store().rollbacks;
    if (sh.last) |l| if (l.root == root and l.kind == kind) {
        if (l.generation == generation) return l.ground;
        if (std.debug.runtime_safety) std.debug.panic("the type store rolled back under a memo keyed by variable ids (checker-v2.md §9.3)", .{});
    };
    const ground = try encode(s, root, kind);
    sh.last = .{ .root = root, .kind = kind, .ground = ground, .generation = generation };
    return ground;
}

fn encode(s: *Solve, root: Var, kind: Kind) Error!?Ground {
    const sh = &s.resolver.shapes;
    const Heads = struct {
        s: *Solve,
        pub fn kept(h: @This(), a: TypeStore.Structure.App) bool {
            return isWellKnownType(h.s, a) or h.s.cx.types.entry(a.type).module != h.s.cx.module;
        }
    };
    const found = (try Walk.encodeGround(s.store(), s.cx.gpa, &sh.words, &sh.stack, root, @intFromEnum(kind), shape_cap, Heads{ .s = s })) orelse return null;
    return .{ .key = std.mem.sliceAsBytes(sh.words.items), .kept = found.kept };
}

fn keep(s: *Solve, key: []const u8) Error!void {
    const map = &s.resolver.shapes.map;
    const got = try map.getOrPut(s.cx.gpa, key);
    if (got.found_existing) return;
    got.key_ptr.* = s.cx.gpa.dupe(u8, key) catch |err| {
        map.removeByPtr(got.key_ptr);
        return err;
    };
}

/// Why a receiver cannot derive a well-known method, or that it can.
pub const Verdict = union(enum) {
    ok,
    function,
    contains_function,
    opaque_type,
    cycle: Var,
    /// An own unannotated method of this name whose group is `unchecked`:
    /// the caller demands it (§10.2) and asks again.
    pending: u32,
    /// An own type whose context needs a fixpoint run: the caller runs it
    /// (`Contexts.ensure`) and asks again.
    query: struct { type_id: Types.TypeId, kind: Kind },
    /// §11.2's parametric in-flight case: `method_needs_annotation`.
    needs_annotation: struct { type_id: Types.TypeId, decl: u32 },
    /// A context whose computation ran out of the step budget:
    /// `nesting_too_deep` at the use.
    budget,
    /// A context that reaches another module's private method (§11.2,
    /// §11.3): `private_method` at the use, naming the type whose module
    /// declares it.
    private_method: struct { type_id: Types.TypeId, method: Symbol },
    /// A context whose pass met a payload's method of the wrong type
    /// (static-dispatch-spike.md §10.13): said at the use, naming
    /// the type whose method it is.
    requirement: struct { type_id: Types.TypeId, method: Symbol, site: ?Messages.PayloadSite = null },
    /// An own type whose context met a payload's `err` (`Contexts.Status.
    /// poisoned`): no answer, and no message — the `err` has one.
    poisoned,
};

/// `derivability` for wanted `id` on `root`, reported at the use when it is
/// not `ok`.
pub fn derivable(s: *Solve, id: WantedId, root: Var) Error!bool {
    const w = s.evidence.get(id);
    const kind = Contexts.kindOf(w.method);
    // A ground shape proved derivable before (`Shapes`).
    if (try groundShape(s, root, kind)) |g| {
        if (g.kept and s.resolver.shapes.map.contains(g.key)) return true;
    }
    var forced: std.ArrayList(Forced) = .empty;
    defer forced.deinit(s.cx.scratch);
    // The common case, `T … == T …` on an own type whose context nothing
    // asked for yet: computed before the walk, so the walk runs once.
    if (try headNeedsRun(s, root, kind)) |u| try Contexts.ensure(s, u);
    var verdict = try derivability(s, root, kind, forced.items);
    while (true) {
        switch (verdict) {
            // An own type whose method of this name has no scheme yet: its
            // group is demanded now (§10.2) — at most once per method name.
            .pending => |decl| {
                const got = try s.groups.demand(s, decl, w.origin, s.cx.bir.symbol(s.cx.bir.decls[decl].name));
                if (got == .refused) {
                    try Resolve.reject(s, id, true);
                    return false;
                }
            },
            // Its context is computed now; a result that could not be
            // memoised is read as it stands for the rest of this walk.
            .query => |q| {
                const t = s.contexts.local(q.type_id).?;
                try Contexts.ensure(s, s.contexts.unit_of[t]);
                try forced.append(s.cx.scratch, .{ .type_id = q.type_id, .kind = q.kind });
            },
            else => break,
        }
        verdict = try derivability(s, root, kind, forced.items);
    }
    switch (verdict) {
        .ok => {
            if (try groundShape(s, root, kind)) |g| {
                if (g.kept) try keep(s, g.key);
            }
            return true;
        },
        .pending, .query => unreachable,
        .poisoned => {
            try Resolve.poisoned(s, id);
            return false;
        },
        .cycle => |node| {
            try s.reportCycle(w.origin, .none, root, node);
            try Resolve.reject(s, id, false);
            return false;
        },
        else => try report(s, w.origin, root, w.method, verdict),
    }
    try Resolve.reject(s, id, true);
    return false;
}

/// A refusal `verdict` of `method` on `root`, said at `origin` (with
/// §11.3's and §11.2's own texts). Shared with the deferred checks of a closed
/// endpoint compared while its schema was in flight (`checkDeferred`).
/// The payload `site` names (`Contexts.Answer.payload`), read afresh over
/// its type's parameters for a message: its constructor and its type, or
/// null when it cannot be read.
fn payloadAt(s: *Solve, site: ?Messages.PayloadSite) Error!?Messages.Payload {
    const at = site orelse return null;
    const t = s.contexts.local(at.owner) orelse return null;
    const entry = s.cx.types.entry(at.owner);
    if (entry.schema_endpoint) return null;
    const p = (try Contexts.readPayloads(s, t)) orelse return null;
    if (at.payload >= p.args.len) return null;
    const bir = s.cx.bir;
    var k: u32 = 0;
    for (bir.declCtors(bir.decls[entry.decl.int()])) |ctor| {
        const n: u32 = @intCast(bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index).len);
        if (at.payload < k + n) return .{ .owner = entry.name, .ctor = bir.symbol(ctor.name), .v = p.args[at.payload] };
        k += n;
    }
    return null;
}

pub fn report(s: *Solve, origin: Bir.Inst.Index, root: Var, method: Symbol, verdict: Verdict) Error!void {
    const is_eq = method == InternPool.WellKnown.eq.symbol();
    const w = .{ .origin = origin, .method = method };
    switch (verdict) {
        // A poisoned verdict has its message where the `err` was made.
        .ok, .pending, .query, .cycle, .poisoned => {},
        .private_method => |p| {
            s.contexts.notePrivate(s, p.type_id, p.method);
            try Messages.privateMethod(s.report, w.origin, root, p.type_id, p.method);
        },
        .budget => try Messages.resolutionBudget(s.report, w.origin, Resolve.step_budget),
        .requirement => |q| {
            s.contexts.noteRequirement(s, q.type_id, q.method);
            try Messages.requirementFailed(s.report, w.origin, root, method, q.type_id, q.method, null, try payloadAt(s, q.site));
        },
        .needs_annotation => |n| {
            s.contexts.noteCulprit(s, n.decl);
            try Messages.derivedNeedsAnnotation(s.report, origin, root, method, s.cx.bir.decls[n.decl].kind == .schema, s.cx.bir.symbol(s.cx.bir.decls[n.decl].name), Contexts.schemaConversion(s.cx, n.decl));
        },
        .function => {
            s.contexts.noteFunction(s);
            if (is_eq) {
                try s.report.notEquatable(w.origin, root, .function);
            } else {
                try s.report.noMethodsOnShape(w.origin, w.method, root, .contains_function);
            }
        },
        .contains_function => {
            s.contexts.noteFunction(s);
            if (is_eq) {
                try s.report.notEquatable(w.origin, root, .opaque_type);
            } else {
                try s.report.noMethodsOnShape(w.origin, w.method, root, .contains_function);
            }
        },
        .opaque_type => if (is_eq) {
            try s.report.notEquatable(w.origin, root, .opaque_type);
        } else {
            try s.report.noMethodsOnShape(w.origin, w.method, root, .not_orderable);
        },
    }
}

/// The unit of `root`'s head when `root` is an own derived type whose
/// context the walk would stop to compute (`.query`).
fn headNeedsRun(s: *Solve, root: Var, kind: Kind) Error!?u32 {
    const a = switch (s.store().resolvedContent(root)) {
        .structure => |flat| switch (flat) {
            .app => |a| a,
            else => return null,
        },
        else => return null,
    };
    const c = &s.contexts;
    const t = c.local(a.type) orelse return null;
    if (c.unit_of[t] == Contexts.none or c.notDerived(a.type, kind)) return null;
    if (Contexts.tableRow(s.cx.types, a.type, kind) == null and s.ownValue(Contexts.methodName(kind)) != null) return null;
    if (try c.peek(s, a.type, kind) != null) return null;
    return c.unit_of[t];
}

/// A type whose context a run just computed but could not memoise: read
/// from `Contexts.answers` as it stands.
const Forced = struct { type_id: Types.TypeId, kind: Kind };

const Colour = enum { grey, black, black_open };

const Frame = struct {
    key: PairKey,
    /// A structure's next `structural` successor, or a nominal head's next
    /// step (a run of `steps`).
    cursor: u32 = 0,
    nominal: bool = false,
    steps: Range = .{},
    /// No variable below it, so far: a black ground node's verdict cannot
    /// change, and is kept (`Resolve.State.derivable`).
    ground: bool = true,
    /// The verdict a failure below it is reported as (a failed
    /// `eq` requirement is `contains_function`, a failed `compare` one
    /// `opaque_type`).
    map: ?Verdict,
};

const Range = struct { start: u32 = 0, len: u32 = 0 };

/// One argument a nominal head asks something of.
const Step = struct { v: Var, kind: Kind, map: ?Verdict };

/// The walk's scratch: the nominal heads' steps.
const Walker = struct {
    steps: std.ArrayList(Step) = .empty,
    /// It read an approximation or a generational result: no ground verdict
    /// it proves is kept past this walk.
    volatile_read: bool = false,
};

/// The walk's colour per pair. The first `inline_len` pairs are kept inline
/// and searched linearly, so the common walk — one use's tuple, record or
/// list, a handful of nodes — never hashes; past them, a hash map (hashing
/// every walk would cost about a twentieth of the check of 6 000 tuple
/// comparisons, `checker-v2.md` §18).
const Colours = struct {
    const inline_len = 16;

    keys: [inline_len]PairKey = undefined,
    values: [inline_len]Colour = undefined,
    /// Inline pairs, or `inline_len + 1` once they moved into `map`.
    len: u32 = 0,
    map: std.AutoHashMapUnmanaged(PairKey, Colour) = .empty,

    fn get(c: *const Colours, key: PairKey) ?Colour {
        if (c.len > inline_len) return c.map.get(key);
        for (c.keys[0..c.len], c.values[0..c.len]) |k, v| {
            if (k.root == key.root and k.kind == key.kind) return v;
        }
        return null;
    }

    fn put(c: *Colours, a: std.mem.Allocator, key: PairKey, colour: Colour) Error!void {
        if (c.len <= inline_len) {
            for (c.keys[0..c.len], c.values[0..c.len]) |k, *v| {
                if (k.root == key.root and k.kind == key.kind) {
                    v.* = colour;
                    return;
                }
            }
            if (c.len < inline_len) {
                c.keys[c.len] = key;
                c.values[c.len] = colour;
                c.len += 1;
                return;
            }
            try c.map.ensureTotalCapacity(a, inline_len * 2);
            for (c.keys, c.values) |k, v| c.map.putAssumeCapacity(k, v);
            c.len = inline_len + 1;
        }
        try c.map.put(a, key, colour);
    }

    fn deinit(c: *Colours, a: std.mem.Allocator) void {
        c.map.deinit(a);
    }
};

/// Whether frame `f` has no successor: a nominal head that asks nothing of
/// its arguments (`Int`, a type whose context is empty), or a structure
/// with no `structural` child (`()`, `{}`). Such a node cannot be on a
/// cycle and holds no variable, so the walk neither colours nor memoises
/// it: it is ground, and asking again is one `open`.
fn isLeaf(s: *Solve, f: Frame) bool {
    const st = s.store();
    switch (st.content(f.key.root)) {
        .alias => return false,
        else => {},
    }
    if (f.nominal) return f.steps.len == 0;
    return Walk.child(st, f.key.root, 0, .structural) == null;
}

/// THE answer to "can `start` derive `kind`?", which every derivation
/// reads. `forced` are the heads `derivable` computed for this walk.
pub fn derivability(s: *Solve, start: Var, kind: Kind, forced: []const Forced) Error!Verdict {
    const st = s.store();
    const gpa = s.cx.gpa;
    const scratch = s.cx.scratch;
    const first: PairKey = .{ .root = st.find(start), .kind = kind };
    if (s.resolver.derivable.contains(st, first)) return .ok;
    // The open memo holds while no leaf a walk met has been given
    // successors since (`TypeStore.proof_voids`), and only for a walk with
    // nothing forced.
    const r = &s.resolver;
    if (r.derivable_open_voids != st.proof_voids) {
        r.derivable_open.clearRetainingCapacity();
        r.derivable_open_voids = st.proof_voids;
    }
    const open_memo = forced.len == 0;
    if (open_memo and r.derivable_open.contains(first)) return .ok;
    var colours: Colours = .{};
    defer colours.deinit(scratch);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(scratch);
    var walker: Walker = .{};
    defer walker.steps.deinit(scratch);
    switch (try open(s, &walker, first, null, forced)) {
        .frame => |f| try frames.append(scratch, f),
        .refusal => |refusal| return refusal,
    }
    try colours.put(scratch, first, .grey);
    while (frames.items.len > 0) {
        const top = &frames.items[frames.items.len - 1];
        const next = nextStep(s, &walker, top) orelse {
            const done = frames.pop().?;
            try colours.put(scratch, done.key, if (done.ground) .black else .black_open);
            if (!walker.volatile_read) {
                if (done.ground) {
                    try s.resolver.derivable.put(gpa, st, done.key);
                } else if (open_memo) {
                    try r.derivable_open.put(gpa, done.key, {});
                }
            }
            if (frames.items.len > 0 and !done.ground) frames.items[frames.items.len - 1].ground = false;
            continue;
        };
        const key: PairKey = .{ .root = st.find(next.v), .kind = next.kind };
        const map = top.map orelse next.map;
        if (colours.get(key)) |c| switch (c) {
            .grey => return .{ .cycle = key.root },
            .black => continue,
            .black_open => {
                top.ground = false;
                continue;
            },
        };
        if (s.resolver.derivable.contains(st, key)) continue;
        if (open_memo and r.derivable_open.contains(key)) {
            top.ground = false;
            continue;
        }
        switch (st.content(key.root)) {
            // A variable holds nothing yet: not a verdict, but not ground.
            .flex, .rigid, .err => {
                top.ground = false;
                // Recorded, so the open memo is voided if it is ever given
                // successors (`TypeStore.gains`).
                if (open_memo) st.prove(key.root);
                continue;
            },
            else => {},
        }
        switch (try open(s, &walker, key, map, forced)) {
            .frame => |f| {
                if (isLeaf(s, f)) continue;
                try colours.put(scratch, key, .grey);
                try frames.append(scratch, f);
            },
            .refusal => |refusal| return switch (refusal) {
                .pending, .query, .needs_annotation, .private_method, .requirement, .budget, .poisoned => refusal,
                else => map orelse refusal,
            },
        }
    }
    return .ok;
}

/// A node's frame, or its own verdict: a function; a nominal head that
/// cannot answer, or that must be computed or demanded first.
fn open(s: *Solve, w: *Walker, key: PairKey, map: ?Verdict, forced: []const Forced) Error!Opened {
    const st = s.store();
    const frame: Frame = .{ .key = key, .map = map };
    switch (st.content(key.root)) {
        .structure => |flat| switch (flat) {
            .func => return .{ .refusal = .function },
            .app => |a| {
                var nominal = frame;
                nominal.nominal = true;
                nominal.steps.start = @intCast(w.steps.items.len);
                if (try head(s, w, key, a, forced)) |refusal| return .{ .refusal = refusal };
                nominal.steps.len = @intCast(w.steps.items.len - nominal.steps.start);
                return .{ .frame = nominal };
            },
            else => {},
        },
        else => {},
    }
    return .{ .frame = frame };
}

const Opened = union(enum) { frame: Frame, refusal: Verdict };

/// A type with a row of §3.2's table (`Contexts.tableRow`; both kinds have one).
fn isWellKnownType(s: *const Solve, a: TypeStore.Structure.App) bool {
    return a.args.len == 0 and Contexts.tableRow(s.cx.types, a.type, .eq) != null;
}

/// A nominal head `T args` (§11.2): its steps, or why it cannot answer.
fn head(s: *Solve, w: *Walker, key: PairKey, a: TypeStore.Structure.App, forced: []const Forced) Error!?Verdict {
    const cx = s.cx;
    const st = s.store();
    const scratch = cx.scratch;
    if (isWellKnownType(s, a)) return null;
    const name = Contexts.methodName(key.kind);
    const entry = cx.types.entry(a.type);
    const args = try scratch.dupe(Var, Walk.positions(st, key.root));
    defer scratch.free(args);
    // The module rule: a method is a boundary.
    if (entry.module == cx.module) {
        if (s.ownValue(name)) |d| {
            const decl = cx.bir.decls[d];
            if (decl.annotation == .none) switch (s.groups.statusOf(d)) {
                .unchecked => return .{ .pending = d },
                // In flight: its requirements are not known yet, and the
                // resolver's in-flight link decides the use (§10.3).
                .checking => return null,
                .done => {},
            };
            if (decl.is_pub) {
                if (s.decl_scheme[d].unwrap()) |scheme| try ownBoundary(s, w, scheme, a.type, args, key.kind);
            } else {
                for (args) |v| try w.steps.append(scratch, .{ .v = v, .kind = key.kind, .map = null });
            }
            return null;
        }
    } else if (entry.module.int() < cx.interfaces.len) {
        const iface = cx.iface(entry.module);
        if (iface.findValue(cx.interner, name)) |value| {
            try importedBoundary(s, w, iface, entry.module, value, a.type, args, key.kind);
            return null;
        }
    }
    if (entry.kind == .foreign) {
        if (!foreignDerives(entry, key.kind)) return .opaque_type;
        for (args) |v| try w.steps.append(scratch, .{ .v = v, .kind = key.kind, .map = null });
        return null;
    }
    // Derivation: the context.
    if (entry.module == cx.module) {
        const answer = (try forcedAnswer(s, a.type, key.kind, forced)) orelse
            (try s.contexts.peek(s, a.type, key.kind)) orelse
            return .{ .query = .{ .type_id = a.type, .kind = key.kind } };
        if (s.contexts.runs.items.len != 0 or !s.contexts.settled(a.type)) w.volatile_read = true;
        switch (answer.status) {
            .present => for (s.contexts.entriesOf(answer)) |e| try contextStep(w, scratch, args, e.param, e.method, key.kind),
            .absent_function => return .contains_function,
            .absent_other, .foreign => return .opaque_type,
            .absent_budget => return .budget,
            .poisoned => return .poisoned,
            .absent_private => return .{ .private_method = .{ .type_id = @enumFromInt(answer.culprit), .method = answer.method } },
            .absent_requirement => return .{ .requirement = .{ .type_id = @enumFromInt(answer.culprit), .method = answer.method, .site = if (answer.payload != Contexts.none) .{ .owner = a.type, .payload = answer.payload } else null } },
            .own_method => {},
            .needs_annotation => return .{ .needs_annotation = .{ .type_id = a.type, .decl = answer.culprit } },
        }
        return null;
    }
    if (entry.module.int() >= cx.interfaces.len) return null;
    const iface = cx.iface(entry.module);
    // A record has a row for every type it can reach (§22.1): with none,
    // resolution says `internal` (`Instances.derivedNominal`).
    const facts = iface.typeFacts(cx.interner, entry.name) orelse return null;
    const row = facts.derived(if (key.kind == .eq) .eq else .compare);
    switch (row.status) {
        .present => {
            var k: usize = 0;
            while (iface.contextEntry(row.context, k)) |e| : (k += 1) {
                try contextStep(w, scratch, args, e.param, iface.symbol(e.method), key.kind);
            }
        },
        .function => return .contains_function,
        .unanswerable, .foreign => return .opaque_type,
        // §11.3, §14.2: the row names the type whose
        // module's private method its context reaches — its own, under the
        // module rule, or one a payload holds.
        .private_method => {
            const p = iface.privateCulprit(row.context) orelse return .opaque_type;
            const refs = cx.types.refIds(entry.module);
            const culprit = if (@intFromEnum(p.type_ref) < refs.len) refs[@intFromEnum(p.type_ref)] else return .opaque_type;
            return .{ .private_method = .{ .type_id = culprit, .method = iface.symbol(p.method) } };
        },
        // The row names the type whose method failed (§14.2).
        .requirement => {
            const p = iface.privateCulprit(row.context) orelse return .opaque_type;
            const refs = cx.types.refIds(entry.module);
            const culprit = if (@intFromEnum(p.type_ref) < refs.len) refs[@intFromEnum(p.type_ref)] else return .opaque_type;
            return .{ .requirement = .{ .type_id = culprit, .method = iface.symbol(p.method) } };
        },
        .unchecked, .primitive, .own_method, .alias => {},
    }
    return null;
}

fn forcedAnswer(s: *Solve, type_id: Types.TypeId, kind: Kind, forced: []const Forced) Error!?Contexts.Answer {
    for (forced) |f| {
        if (f.type_id != type_id or f.kind != kind) continue;
        const t = s.contexts.local(type_id) orelse return null;
        return s.contexts.final(t, kind);
    }
    return null;
}

/// A context entry `(param, method)` asked of a head being derived for
/// `kind`: the argument, for the same method; for the other well-known one,
/// mapped as a boundary's requirement is; for any other method, the
/// derived method itself (a requirement it cannot check).
fn contextStep(w: *Walker, scratch: std.mem.Allocator, args: []const Var, param: u16, method: Symbol, kind: Kind) Error!void {
    if (param >= args.len) return;
    const step: Step = if (!Resolve.isWellKnownName(method) or Contexts.kindOf(method) == kind)
        .{ .v = args[param], .kind = kind, .map = null }
    else if (method == InternPool.WellKnown.eq.symbol())
        .{ .v = args[param], .kind = .eq, .map = .contains_function }
    else
        .{ .v = args[param], .kind = .compare, .map = .opaque_type };
    try w.steps.append(scratch, step);
}

/// A requirement of a boundary method on its receiver's parameter `i`:
/// `eq` (or the `equatable` marker), `compare`, or another method, which the
/// derived method stands for.
fn boundaryStep(w: *Walker, scratch: std.mem.Allocator, arg: Var, method: ?Symbol, kind: Kind) Error!void {
    const m = method orelse return w.steps.append(scratch, .{ .v = arg, .kind = .eq, .map = .contains_function });
    if (m == InternPool.WellKnown.eq.symbol()) return w.steps.append(scratch, .{ .v = arg, .kind = .eq, .map = .contains_function });
    if (m == InternPool.WellKnown.compare.symbol()) return w.steps.append(scratch, .{ .v = arg, .kind = .compare, .map = .opaque_type });
    return w.steps.append(scratch, .{ .v = arg, .kind = kind, .map = null });
}

/// This module's `pub` method `scheme` as a boundary for `T args`: when its
/// receiver is `T` over its own quantifiers, each quantifier's requirements
/// ask its argument; a method over another type's receiver asks nothing (the
/// resolver reports the module-rule clash); a polymorphic one (`a, a ->
/// Bool`) asks nothing either.
fn ownBoundary(s: *Solve, w: *Walker, scheme: Var, type_id: Types.TypeId, args: []const Var, kind: Kind) Error!void {
    const st = s.store();
    const scratch = s.cx.scratch;
    const f = Walk.function(st, scheme) orelse return;
    if (f.params.len != 2) return;
    const receiver = Walk.positions(st, f.params[0]);
    switch (st.resolvedContent(f.params[0])) {
        .structure => |flat| switch (flat) {
            .app => |app| if (app.type != type_id or receiver.len != args.len) return,
            else => return,
        },
        else => {
            // A receiver that is not `T` itself is no boundary for `T`: its
            // arguments are asked as a derived head's would be.
            return;
        },
    }
    const params = try scratch.dupe(Var, receiver);
    defer scratch.free(params);
    for (params, args) |p, arg| {
        const flags = st.flagsOf(st.find(p));
        if (flags.equatable) try boundaryStep(w, scratch, arg, null, kind);
        const set = Walk.constraints(flags);
        const n = set.count(st);
        var j: u32 = 0;
        while (j < n) : (j += 1) try boundaryStep(w, scratch, arg, set.at(st, j).name, kind);
    }
}

/// Another module's `pub` method, read from its interface scheme the same
/// way (`ownBoundary`): the first parameter's term `T (var q₀) …`, and each
/// quantifier's constraint block.
fn importedBoundary(s: *Solve, w: *Walker, iface: *const Interface, module: @import("../resolve/Graph.zig").Index, value: Interface.ValueIndex, type_id: Types.TypeId, args: []const Var, kind: Kind) Error!void {
    const scratch = s.cx.scratch;
    const index = iface.values[@intFromEnum(value)].scheme;
    if (index == .none or @intFromEnum(index) >= iface.schemes.len) return;
    const scheme = iface.scheme(index);
    const body = iface.term(scheme.body);
    if (body.tag != .func) return;
    const params = iface.range(body.lhs);
    if (params.len != 2) return;
    const first = iface.term(@enumFromInt(params[0]));
    if (first.tag != .app) return;
    const refs = s.cx.types.refIds(module);
    if (first.lhs >= refs.len or refs[first.lhs] != type_id) return;
    const arg_terms = iface.range(first.rhs);
    if (arg_terms.len != args.len) return;
    for (arg_terms, args) |t, arg| {
        const term = iface.term(@enumFromInt(t));
        if (term.tag != .@"var" or term.lhs >= scheme.quantified_count) continue;
        const q = iface.quantified(scheme, term.lhs);
        if (q.equatable) try boundaryStep(w, scratch, arg, null, kind);
        var j: u32 = 0;
        while (j < q.constraints_len) : (j += 1) {
            try boundaryStep(w, scratch, arg, iface.symbol(iface.quantifiedConstraint(q, j).name), kind);
        }
    }
}

/// The next pair to visit below `frame`, or null when it has none left: an
/// alias's expansion; a nominal head's steps; every other node's
/// `structural` successors, for the same kind.
fn nextStep(s: *Solve, w: *const Walker, frame: *Frame) ?Step {
    const st = s.store();
    const root = frame.key.root;
    switch (st.content(root)) {
        .alias => {
            if (frame.cursor != 0) return null;
            frame.cursor = 1;
            return .{ .v = Walk.child(st, root, 0, .payload).?, .kind = frame.key.kind, .map = null };
        },
        else => {},
    }
    if (frame.nominal) {
        if (frame.cursor >= frame.steps.len) return null;
        const step = w.steps.items[frame.steps.start + frame.cursor];
        frame.cursor += 1;
        return step;
    }
    const c = Walk.child(st, root, frame.cursor, .structural) orelse return null;
    frame.cursor += 1;
    return .{ .v = c, .kind = frame.key.kind, .map = null };
}

/// Whether a `foreign type` answers derived `kind` (A.55): it has no body to
/// derive over, so only an `equatable` one answers `eq`, structurally. The
/// one statement of the rule: at a use's head
/// `Instances` routes a refusal to `unknown_method`, which names the `pub
/// compare` its module is missing (A.50); at a position the verdict is
/// `opaque_type`.
pub fn foreignDerives(entry: Types.Entry, kind: Kind) bool {
    return kind == .eq and entry.equatable;
}

/// P9's property byte for a schema endpoint `v` (schema.md A.6: bit 0
/// equatable, bit 1 comparable, bit 2 has-function), read off THE verdict —
/// the derived contexts P5 settled — for a nominal endpoint and a record
/// one's expansion alike (checker-v2.md §11.5).
pub fn propertyBits(s: *Solve, v: Var) Error!u8 {
    var bits: u8 = 0;
    for ([_]Kind{ .eq, .compare }, 0..) |kind, i| {
        switch (try settledVerdict(s, v, kind)) {
            .ok => bits |= @as(u8, 1) << @intCast(i),
            .function, .contains_function => bits |= 4,
            else => {},
        }
    }
    return bits;
}

/// `derivability`, with every context it stops for computed first. After P5
/// every unit is settled, so this is one walk.
pub fn settledVerdict(s: *Solve, v: Var, kind: Kind) Error!Verdict {
    var forced: std.ArrayList(Forced) = .empty;
    defer forced.deinit(s.cx.scratch);
    while (true) {
        const verdict = try derivability(s, v, kind, forced.items);
        switch (verdict) {
            .query => |q| {
                const t = s.contexts.local(q.type_id).?;
                try Contexts.ensure(s, s.contexts.unit_of[t]);
                try forced.append(s.cx.scratch, .{ .type_id = q.type_id, .kind = q.kind });
            },
            else => return verdict,
        }
    }
}
