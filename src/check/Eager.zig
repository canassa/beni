//! P5 (checker-v2.md §5, §11.2, §12.4; *As built by R8a*): the eager derived
//! rows of every nominal type this module declares (A.23), and their bodies.
//!
//! **Why eager, and why here.** The declaring module is checked and lowered
//! before any user of its type, so a use elsewhere cannot ask it for a
//! function: every `eq` and `compare` a use could name is written now, used
//! or not, and `Reach` drops what nothing reaches (static-dispatch-
//! spike.md §8.5).
//!
//! **Which rows, and their contexts, are the derived contexts'** (`Contexts`,
//! D4): P4 is over, so every unit is settled from `done` inputs
//! (`Contexts.settleAll`), and a type gets a row for a method exactly when
//! its context is `present` — with that context as the row's evidence
//! parameters, one per entry, in `(param, method text)` order. Nothing here
//! decides a capability; publication (P8) reads the same answers.
//!
//! **The body is resolved, not recomputed.** Each constructor argument, in
//! declaration order and left to right (§9's parts contract), becomes ONE
//! wanted of the row's method on the argument's type, read with the type's
//! parameters bound to fresh flex MARKERS (`Contexts.readPayloads`, the
//! fixpoint's own read), and the resolver answers it as it answers any other
//! wanted. What rides open on marker `i` for method `m'` is the context entry
//! `(i, m')`, which P6 (`Elaborate`) turns into `param derived row k`.
//!
//! The resolution runs with the fixpoint's QUIET report: every position of a
//! `present` context resolves, so a refusal here is the compiler's, and P6
//! says `internal` for a body it cannot write. An `internal` is still said.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Contexts = @import("Contexts.zig");
const Decide = @import("Decide.zig");
const Elaborate = @import("Elaborate.zig");
const Evidence = @import("Evidence.zig");
const Generalize = @import("Generalize.zig");
const Solve = @import("Solve.zig");
const Unit = @import("Unit.zig");

const Eager = @This();

const Var = TypeStore.Var;
pub const Error = Allocator.Error;

/// One eager row before elaboration.
pub const Row = struct {
    kind: Dispatch.Derived.Kind,
    type_id: Types.TypeId,
    /// Its context: a run of `Contexts.entries`.
    entries: Contexts.Range,
    /// Its markers, one per type parameter: a run of `markers`.
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

/// Settle every context, decide the rows and resolve their bodies, in a
/// frame of their own, after P4 and before P6.
pub fn build(e: *Eager, s: *Solve) Error!void {
    const cx = s.cx;
    const bir = cx.bir;
    const gpa = cx.gpa;
    try Contexts.settleAll(s);
    try Contexts.checkDeferred(s);
    const c = &s.contexts;
    for (bir.decls, 0..) |d, i| {
        // A `type`, or a tagged schema's two nominal endpoints (§11.5, R8b).
        const ids: [2]Types.TypeId = switch (d.kind) {
            .type => .{ cx.types.ofDecl(cx.module, @enumFromInt(i)), .none },
            .schema => .{ cx.types.ofSchemaDecl(cx.module, @enumFromInt(i), .type), cx.types.ofSchemaDecl(cx.module, @enumFromInt(i), .encoded) },
            else => continue,
        };
        for (ids) |id| {
            const t = c.local(id) orelse continue;
            if (c.unit_of[t] == Contexts.none) continue;
            for ([_]Dispatch.Derived.Kind{ .eq, .compare }) |kind| {
                const answer = c.final(t, kind);
                if (answer.status != .present) continue;
                try e.rows.append(gpa, .{ .kind = kind, .type_id = id, .entries = answer.entries });
            }
        }
    }
    if (e.rows.items.len == 0) return;

    const real = s.report;
    s.report = try Contexts.quietReport(s);
    defer s.report = real;
    // A frame of its own, with its own step budget and derived memo, so
    // nothing P4 shared can answer a position P5 resolves here (review N4).
    // A KEPT body was resolved in P4, under P4's memo: that is sound only
    // because `Builder.read` gives every pass fresh variables, so no root
    // of a kept body is shared with anything the memo holds (R8a's review,
    // S4).
    s.resolver.steps = 0;
    s.resolver.derived.clearRetainingCapacity();
    try Generalize.pushFrame(s, @intCast(s.frames.items.len + 1), .fixpoint);
    for (e.rows.items) |*row| try e.body(s, row);
    try Decide.drain(s, s.frame().queue, true);
    Generalize.popFrame(s);
    try Contexts.sayInternals(s, real);
}

fn body(e: *Eager, s: *Solve, row: *Row) Error!void {
    const gpa = s.cx.gpa;
    const t = s.contexts.local(row.type_id).?;
    // A unit P5 settled kept its last passes: they are the bodies.
    const kept = s.contexts.bodies[t * 2 + @intFromEnum(row.kind)];
    if (kept.set) {
        row.markers = .{ .start = @intCast(e.markers.items.len), .len = @intCast(kept.markers.len) };
        try e.markers.appendSlice(gpa, kept.markers);
        row.body = try s.evidence.addArgs(gpa, kept.ids);
        return;
    }
    const p = (try Contexts.readPayloads(s, t)) orelse {
        row.unreadable = true;
        return;
    };
    row.markers = .{ .start = @intCast(e.markers.items.len), .len = @intCast(p.markers.len) };
    try e.markers.appendSlice(gpa, p.markers);
    const ids = try Contexts.resolvePayloads(s, p, row.kind);
    row.body = try s.evidence.addArgs(gpa, ids);
}

// ---------------------------------------------------------------------------
// The rows' bodies, in P6 (`Elaborate`'s unit builder)
// ---------------------------------------------------------------------------

/// Every row, then its body: a row whose body cannot be elaborated is the
/// compiler's failure (its context said every position answers), never a
/// row silently not written.
pub fn elaborate(e: *Elaborate) Error!void {
    const eager = e.in.eager;
    const contexts = e.in.contexts;
    for (eager.rows.items, 0..) |r, i| {
        const start: u32 = @intCast(e.row_entries.items.len);
        for (contexts.entriesOf(.{ .status = .present, .entries = r.entries })) |entry| {
            try e.row_entries.append(e.gpa, .{ .param = entry.param, .method = entry.method });
        }
        try e.addOwnRow(.{
            .kind = r.kind,
            .shape = .{ .nominal = r.type_id },
            .context = r.entries.len,
            .entries = .{ .start = start, .len = r.entries.len },
            .alive = !r.unreadable,
            .eager = @intCast(i),
        }, r.type_id);
    }
    const count: u32 = @intCast(e.rows.items.len);
    var roots: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer roots.deinit(e.scratch);
    for (0..count) |i| {
        if (!e.rows.items[i].alive) continue;
        roots.clearRetainingCapacity();
        const rows_len = e.rows.items.len;
        const symbols_len = e.symbols.items.len;
        try markerKeys(e, @intCast(i));
        const ok = try bodyUnit(e, @intCast(i)) and try e.emitUnit(&roots);
        if (!ok) {
            e.rows.shrinkRetainingCapacity(rows_len);
            e.symbols.shrinkRetainingCapacity(symbols_len);
            e.rows.items[i].alive = false;
            try e.internal(rowRegion(e, @intCast(i)), if (e.why == .internal) e.what else "a derived row's body could not be elaborated, though its context says every position answers (checker-v2.md §11.2, §12.4)");
            continue;
        }
        e.rows.items[i].body = try e.addArgs(roots.items);
    }
}

/// `marker`'s lookup for row `i`: an open wanted's receiver root and method
/// to its entry `k`, built once per row, so a row of n entries and n open
/// wanteds costs O(n) rather than O(n × (markers + entries)).
/// `Contexts.collect` keeps a context only over distinct markers, so a root
/// names one parameter; the first entry wins, as the scan this replaced did.
fn markerKeys(e: *Elaborate, i: u32) Error!void {
    const row = e.rows.items[i];
    const eager = e.in.eager;
    const st = e.in.cx.store;
    const markers = eager.markersOf(eager.rows.items[row.eager]);
    e.marker_keys.clearRetainingCapacity();
    e.marker_row = i;
    for (e.row_entries.items[row.entries.start..][0..row.entries.len], 0..) |entry, k| {
        if (entry.param >= markers.len) continue;
        const got = try e.marker_keys.getOrPut(e.scratch, .{ .root = st.find(markers[entry.param]), .method = entry.method });
        if (!got.found_existing) got.value_ptr.* = @intCast(k);
    }
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

/// An open wanted: in a P5 row, one riding on marker `i` for method `m'` is
/// the row's context entry `(i, m')`, its `param derived row k`; an open
/// wanted anywhere else is `internal` (I6).
pub fn marker(e: *Elaborate, id: Evidence.WantedId, binder: Elaborate.Binder) ?Dispatch.Term {
    const w = e.in.evidence.get(id);
    const i = switch (binder) {
        .row => |i| i,
        else => return e.failTerm(.internal, "a wanted is still open at elaboration (checker-v2.md §12.2, I6)"),
    };
    if (w.state == .open) {
        const root = e.in.cx.store.find(w.receiver);
        if (e.marker_row == i) {
            if (e.marker_keys.get(.{ .root = root, .method = w.method })) |k|
                return .{ .param = .{ .binder = .{ .derived = i }, .k = k } };
        }
    }
    return e.failTerm(.internal, "an open wanted of a derived row's body is not an entry of the row's context (checker-v2.md §11.2, §12.4)");
}
