//! P5 as R6b builds it (checker-v2.md §5, §12.4, *As built by R6b*): the
//! eager derived rows of every nominal type this module declares (A.23),
//! under v1's one-entry-per-parameter context until R8a's fixpoint (§11.2).
//!
//! **Why eager, and why here.** The declaring module is checked and lowered
//! before any user of its type, so a use elsewhere cannot ask it for a
//! function: every `eq` and `compare` a use could name is written now,
//! used or not, and `Reach` drops what nothing reaches (static-dispatch-
//! spike.md §8.5; v1's `deriveDeclaredTypes`).
//!
//! **Which rows** — v1's rule, verbatim, so the table is v1's: a type gets a
//! row for a method unless the module has a `pub` value of that name (§3.3
//! step 1: it wins), or the session's capability bit says the type cannot
//! answer it (the one settle v2 runs, `Types.settleDispatchCapabilities`,
//! R8a's to replace). The context is one entry per type parameter, for the
//! row's own method.
//!
//! **The body is resolved, not recomputed.** Each constructor argument, in
//! declaration order and left to right (§9's parts contract), becomes ONE
//! wanted of the row's method on the argument's type, read with the type's
//! parameters bound to fresh flex MARKERS, and the resolver answers it as it
//! answers any other wanted (`Resolve.step`). A position that needs the
//! parameter's own method rides OPEN on its marker, and P6 (`Elaborate`)
//! turns exactly that into `param derived i k`; anything else left on a
//! marker — a payload whose method asks for another method of the
//! parameter — is a context v1's rule cannot express, and the row is not
//! written (R8a's case; `Elaborate` refuses a use of it).
//!
//! The resolution runs with a QUIET report of its own: a body the resolver
//! refuses is a row not written, never a message about code the author did
//! not write. An `internal` is still said.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Evidence = @import("Evidence.zig");
const Report = @import("Report.zig");
const Resolve = @import("Resolve.zig");
const Generalize = @import("Generalize.zig");
const Solve = @import("Solve.zig");
const Decide = @import("Decide.zig");
const Elaborate = @import("Elaborate.zig");
const Unit = @import("Unit.zig");

const Eager = @This();

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// One eager row before elaboration.
pub const Row = struct {
    kind: Dispatch.Derived.Kind,
    type_id: Types.TypeId,
    /// Its markers, one per type parameter: a run of `markers`. The context
    /// is one entry per marker, for `kind`.
    markers: Evidence.Range = .{},
    /// One wanted per constructor argument position: a run of the
    /// evidence's `args`.
    body: Evidence.Range = .{},
    /// A parameter's type could not be read (its `nesting_too_deep` is
    /// P4's): no body, no row.
    unreadable: bool = false,
};

rows: std.ArrayList(Row) = .empty,
markers: std.ArrayList(Var) = .empty,

pub fn deinit(e: *Eager, gpa: Allocator) void {
    e.rows.deinit(gpa);
    e.markers.deinit(gpa);
}

pub fn markersOf(e: *const Eager, row: Row) []const Var {
    return e.markers.items[row.markers.start..][0..row.markers.len];
}

fn methodName(kind: Dispatch.Derived.Kind) Symbol {
    return switch (kind) {
        .eq => InternPool.WellKnown.eq.symbol(),
        .compare => InternPool.WellKnown.compare.symbol(),
    };
}

/// Whether the module has a `pub` value named `name` (v1's
/// `ownPubDeclNamed`: any such value suppresses the row of that method for
/// every ordinary type of the module).
fn ownPub(bir: *const Bir, name: Symbol) bool {
    for (bir.decls) |d| {
        if (d.kind.isValue() and d.is_pub and bir.symbol(d.name) == name) return true;
    }
    return false;
}

/// Decide the rows and resolve their bodies, in a frame of their own, after
/// P4 and before P6.
pub fn build(e: *Eager, s: *Solve) Error!void {
    const cx = s.cx;
    const bir = cx.bir;
    const gpa = cx.gpa;
    // Once per method, not per type (CK-42: a scan per type is quadratic).
    const suppressed = [_]bool{ ownPub(bir, methodName(.eq)), ownPub(bir, methodName(.compare)) };
    // Every row's entry first: a body may name any row of the module,
    // itself included.
    for (bir.decls, 0..) |d, i| {
        if (d.kind != .type) continue;
        const id = cx.types.ofDecl(cx.module, @enumFromInt(i));
        if (id == .none) continue;
        for ([_]Dispatch.Derived.Kind{ .eq, .compare }) |kind| {
            if (suppressed[@intFromEnum(kind)]) continue;
            const answers = switch (kind) {
                .eq => cx.types.answersEq(id),
                .compare => cx.types.answersCompare(id),
            };
            if (!answers) continue;
            try e.rows.append(gpa, .{ .kind = kind, .type_id = id });
        }
    }
    if (e.rows.items.len == 0) return;

    var items: std.ArrayList(Report.Item) = .empty;
    defer {
        for (items.items) |item| gpa.free(item.message);
        items.deinit(gpa);
    }
    var quiet: Report = undefined;
    try quiet.init(cx, &items, true, s.report.env.decl_scheme, s.report.local_type);
    defer quiet.deinit();
    const real = s.report;
    s.report = &quiet;
    defer s.report = real;

    try openFrame(s);
    for (e.rows.items) |*row| try e.body(s, row);
    try closeFrame(s);

    // The compiler's own failures are said; the rest was a probe.
    for (items.items) |item| {
        if (item.code != .internal) continue;
        var said = item;
        said.message = try gpa.dupe(u8, item.message);
        try real.emit(said);
    }
}

fn body(e: *Eager, s: *Solve, row: *Row) Error!void {
    const cx = s.cx;
    const bir = cx.bir;
    const gpa = cx.gpa;
    const entry = cx.types.entry(row.type_id);
    const d = bir.decls[entry.decl.int()];
    const params = bir.declTypeParams(d);
    const name = methodName(row.kind);

    row.markers = .{ .start = @intCast(e.markers.items.len), .len = @intCast(params.len) };
    var b = cx.builder(.flex, TypeStore.outermost);
    defer b.deinit();
    for (params) |p| {
        const v = try s.fresh(.{ .flex = .{ .name = p.toOptional() } });
        try e.markers.append(gpa, v);
        try b.bind(p, v);
    }
    const mark = cx.store.count();
    var ids: std.ArrayList(Evidence.WantedId) = .empty;
    defer ids.deinit(cx.scratch);
    var args: std.ArrayList(Var) = .empty;
    defer args.deinit(cx.scratch);
    for (bir.ctors[d.ctors_start..d.ctors_end]) |ctor| {
        for (bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index)) |arg| {
            try args.append(cx.scratch, try b.read(arg));
        }
    }
    try s.instantiate.adoptSince(mark);
    if (b.too_deep) {
        row.unreadable = true;
        return;
    }
    for (args.items) |arg| {
        const method_type = try Resolve.wellKnownType(s, name, arg);
        const id = try Resolve.create(s, name, arg, method_type, d.inst_start, .well_known, .none);
        try Resolve.step(s, id, false);
        try ids.append(cx.scratch, id);
    }
    row.body = try s.evidence.addArgs(gpa, ids.items);
}

// ---------------------------------------------------------------------------
// The rows' bodies, in P6 (`Elaborate`'s unit builder)
// ---------------------------------------------------------------------------

/// Every row, then its body. A row whose body cannot be elaborated — a
/// position the resolver refused, a context v1's rule cannot express — is
/// not written, and nor is any row whose body names one that is not
/// (v1's capability propagation, over the same answers): one pass that
/// records which rows each body names, one propagation over those edges,
/// then the bodies that are left. A compiler failure in either pass is
/// `internal`, never a dead row (review N3).
pub fn elaborate(e: *Elaborate) Error!void {
    const eager = e.in.eager;
    for (eager.rows.items, 0..) |r, i| {
        try e.addOwnRow(.{
            .kind = r.kind,
            .shape = .{ .nominal = r.type_id },
            .context = r.markers.len,
            .alive = !r.unreadable,
            .eager = @intCast(i),
        }, r.type_id);
    }
    const count: u32 = @intCast(e.rows.items.len);
    if (count == 0) return;

    e.collecting = true;
    for (0..count) |i| {
        if (!e.rows.items[i].alive) continue;
        const rows_len = e.rows.items.len;
        const symbols_len = e.symbols.items.len;
        if (!try bodyUnit(e, @intCast(i))) {
            e.rows.items[i].alive = false;
            if (e.why == .internal) try e.internal(rowRegion(e, @intCast(i)), e.what);
        }
        // What the probe made is made again by the pass that writes.
        e.rows.shrinkRetainingCapacity(rows_len);
        e.symbols.shrinkRetainingCapacity(symbols_len);
    }
    e.collecting = false;

    // A dead row kills every row whose body names it.
    std.mem.sort(Elaborate.Dep, e.deps.items, {}, depLessThan);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(e.scratch);
    for (0..count) |i| if (!e.rows.items[i].alive) try queue.append(e.scratch, @intCast(i));
    while (queue.pop()) |dead| {
        var at = std.sort.lowerBound(Elaborate.Dep, e.deps.items, dead, depOrder);
        while (at < e.deps.items.len and e.deps.items[at].to == dead) : (at += 1) {
            const from = e.deps.items[at].from;
            if (!e.rows.items[from].alive) continue;
            e.rows.items[from].alive = false;
            try queue.append(e.scratch, from);
        }
    }

    var roots: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer roots.deinit(e.scratch);
    for (0..count) |i| {
        if (!e.rows.items[i].alive) continue;
        roots.clearRetainingCapacity();
        const ok = try bodyUnit(e, @intCast(i)) and try e.emitUnit(&roots);
        if (!ok) {
            // Every row it names is alive, so this is the compiler's.
            e.rows.items[i].alive = false;
            try e.internal(rowRegion(e, @intCast(i)), "a derived row's body could not be elaborated a second time (checker-v2.md §12.4)");
            continue;
        }
        e.rows.items[i].body = try e.addArgs(roots.items);
    }
}

fn depLessThan(_: void, a: Elaborate.Dep, b: Elaborate.Dep) bool {
    if (a.to != b.to) return a.to < b.to;
    return a.from < b.from;
}

fn depOrder(key: u32, item: Elaborate.Dep) std.math.Order {
    return std.math.order(key, item.to);
}

/// Row `i`'s body positions as one unit; each position is inside the row,
/// so its context is the row's kind.
fn bodyUnit(e: *Elaborate, i: u32) Error!bool {
    const row = e.rows.items[i];
    const r = e.in.eager.rows.items[row.eager];
    e.beginUnit();
    for (e.in.evidence.argsOf(r.body)) |id| {
        const n = (try e.wantedNode(id, Unit.Ctx.of(row.kind))) orelse return false;
        try e.unit.roots.append(e.scratch, n);
    }
    return e.fillUnit(.{ .row = i });
}

fn rowRegion(e: *const Elaborate, i: u32) Bir.Inst.Index {
    const cx = e.in.cx;
    const entry = cx.types.entry(e.rows.items[i].shape.nominal);
    if (entry.decl.int() >= cx.bir.decls.len) return @enumFromInt(0);
    return cx.bir.decls[entry.decl.int()].inst_start;
}

/// An open wanted: in a P5 row, the row's own method on one of its markers
/// is that marker's context entry; anything else left on a marker is a
/// context v1's rule cannot express (R8a); an open wanted anywhere else is
/// `internal` (I6).
pub fn marker(e: *Elaborate, id: Evidence.WantedId, binder: Elaborate.Binder) ?Dispatch.Term {
    const w = e.in.evidence.get(id);
    const i = switch (binder) {
        .row => |i| i,
        else => return e.failTerm(.internal, "a wanted is still open at elaboration (checker-v2.md §12.2, I6)"),
    };
    const row = e.rows.items[i];
    const eager = e.in.eager;
    if (w.state != .open or w.method != methodName(row.kind)) return e.failTerm(.r8a, "");
    const st = e.in.cx.store;
    const receiver = st.find(w.receiver);
    for (eager.markersOf(eager.rows.items[row.eager]), 0..) |v, k| {
        if (st.find(v) == receiver) return .{ .param = .{ .binder = .{ .derived = i }, .k = @intCast(k) } };
    }
    return e.failTerm(.r8a, "");
}

// ---------------------------------------------------------------------------
// P5's frame
// ---------------------------------------------------------------------------

/// A top-level frame with no tree and no boundary: its wanteds are resolved
/// as they are made, and what rides open on a marker is P6's to read. It has
/// its own step budget and its own derived memo, so nothing P4 shared can
/// answer a row's position (review N4).
fn openFrame(s: *Solve) Error!void {
    s.resolver.steps = 0;
    s.resolver.derived.clearRetainingCapacity();
    try Generalize.pushFrame(s, TypeStore.outermost, .top);
}

/// Whatever the frame's resolutions readied is drained first.
fn closeFrame(s: *Solve) Error!void {
    try Decide.drain(s, s.frame().queue, true);
    Generalize.popFrame(s);
}
