//! Deciding obligations (checker-v2.md §4.5, §8.1 steps 1, 3 and 7, §8.5,
//! §8.6, §11.4): the half of the solver that answers the questions an
//! obligation asks, kept apart from `Solve.zig` (§19.1).
//!
//! A `tuple_index`, `interpolatable` or `try` node calls `begin`: the row is
//! decided at once when what decides it is already known — a `try` when
//! EITHER side is (§8.6) — and is otherwise attached to its deciding
//! flex roots, its dependants lowered to its owner's rank (§4.5). `unify`
//! readies it when one of them is bound; `drain`
//! decides what is ready, after every constraint node (§9.1's eager
//! draining) and at the boundary's step 1. `defaults` is step 3, `close` step
//! 7.
//!
//! Every function takes the solver: this file is a part of it, with no state
//! of its own.

const std = @import("std");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Obligations = @import("Obligations.zig");
const Messages = @import("Messages.zig");
const Report = @import("Report.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");
const Evidence = @import("Evidence.zig");
const Resolve = @import("Resolve.zig");
const Recursion = @import("Recursion.zig");

const Var = TypeStore.Var;
const Error = Solve.Error;
const Id = Obligations.Id;
const Row = Obligations.Row;

/// A new obligation's first step: decided at once when what decides it is
/// known, and otherwise attached to its deciding flex variables.
pub fn begin(s: *Solve, id: Id) Error!void {
    const st = s.store();
    const row = s.obligations.row(id);
    for (row.vars[0..row.deciding()]) |v| {
        if (st.content(st.find(v)) != .flex) {
            s.obligations.rowPtr(id).state = .done;
            return decide(s, id, false);
        }
    }
    try attach(s, id);
}

/// Attach an open obligation to its deciding flex roots, lower its
/// dependants to its owner's rank (never the reverse, §4.5), and
/// put a `try` on the open list of the frame at its target's rank (§8.1
/// step 3).
fn attach(s: *Solve, id: Id) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const row = s.obligations.row(id);
    for (row.vars[0..row.deciding()], 0..) |v, slot| {
        const root = st.find(v);
        var flags = st.content(root).flex;
        // Copied and changed in one field.
        flags.obls = try s.obligations.with(gpa, flags.obls, id, slot == row.owner());
        st.setContent(root, .{ .flex = flags });
    }
    // The canonical pessimism of recursive groups (§10.7) first, so the
    // `?` list the row joins is its lowered
    // target's.
    if (s.recursive_frames != 0) try Recursion.row(s, id);
    const rank = try lowerDependants(s, row);
    if (row.kind == .@"try") {
        const at = if (rank == TypeStore.generalized) s.frames.items.len else rank;
        try s.frames.items[at - 1].tries.append(gpa, id.int());
    }
}

/// Lower `row`'s dependants to its owner's rank, and return that rank.
fn lowerDependants(s: *Solve, row: Row) Error!u32 {
    const st = s.store();
    const rank = st.rank(st.find(row.vars[row.owner()]));
    if (rank == TypeStore.generalized) return rank;
    for (row.dependants()) |slot| try Walk.lowerTo(st, &s.stacks, s.cx.gpa, row.vars[slot], rank);
    return rank;
}

/// Decide every readied item of queue `q` — a top-level-kind frame's (§9.1:
/// a frame drains only its own) — in `seq` order. Deciding can ready more;
/// they are decided in the next round of the same loop. Nothing here holds
/// a pointer into `s.queues` across a decision: a resolution may nest a
/// group (§10.2), which pushes a queue of its own.
///
/// An `equatable` row decides nothing another row reads — its walk only
/// flags variables, and a flag matters to nothing before quantification —
/// so the eager drain after a constraint node (`boundary == false`) sets it
/// aside, and the boundary's step 1 walks it over the type as it then
/// stands: the message shows `number -> number` where an early walk showed
/// `a -> b` (§11.4).
pub fn drain(s: *Solve, q: u32, boundary: bool) Error!void {
    const gpa = s.cx.gpa;
    // The current frame's queue, whose `ready` list `Solve` holds (and
    // swaps back in after any frame a decision pushes).
    std.debug.assert(q == s.ready_queue);
    var batch: std.ArrayList(u32) = .empty;
    defer batch.deinit(gpa);
    while (true) {
        const deferred = &s.queues.items[q].deferred;
        if (boundary and s.ready.items.len == 0) {
            try s.ready.appendSlice(gpa, deferred.items);
            deferred.clearRetainingCapacity();
        }
        if (s.ready.items.len == 0) break;
        batch.clearRetainingCapacity();
        try batch.appendSlice(gpa, s.ready.items);
        s.ready.clearRetainingCapacity();
        std.mem.sort(u32, batch.items, s, seqLessThan);
        for (batch.items) |raw| {
            // A wanted: the resolver's (§9.1, one `seq` for both kinds).
            if (raw & Evidence.queued_wanted != 0) {
                try Resolve.drained(s, @enumFromInt(raw & ~Evidence.queued_wanted));
                continue;
            }
            const id: Id = @enumFromInt(raw);
            const row = s.obligations.rowPtr(id);
            if (row.state != .ready) continue;
            if (!boundary and row.kind == .equatable) {
                try s.queues.items[q].deferred.append(gpa, raw);
                continue;
            }
            row.state = .done;
            try decide(s, id, false);
        }
    }
}

fn seqOf(s: *const Solve, raw: u32) u32 {
    if (raw & Evidence.queued_wanted != 0) return s.evidence.get(@enumFromInt(raw & ~Evidence.queued_wanted)).seq;
    return s.obligations.row(@enumFromInt(raw)).seq;
}

fn seqLessThan(s: *const Solve, a: u32, b: u32) bool {
    return seqOf(s, a) < seqOf(s, b);
}

/// Decide `id`, whose state the caller has made `done`. `default` is §8.1
/// step 3's: a `try` whose sides are both still variables is a `Result`.
fn decide(s: *Solve, id: Id, default: bool) Error!void {
    if (s.recursive_frames != 0) try Recursion.row(s, id);
    const row = s.obligations.row(id);
    switch (row.kind) {
        .tuple_index => try tupleIndex(s, id, row),
        .interpolatable => try interpolatable(s, id, row),
        .equatable => try equatable(s, id, row),
        .@"try" => try tryShape(s, id, row, default),
    }
}

/// Put `id` back on its variables: it was readied, but what decides it is
/// still a flex — a bind to an alias whose expansion is a variable, which
/// `resolved` looks through — so nothing is decided.
fn reopen(s: *Solve, id: Id) Error!void {
    s.obligations.rowPtr(id).state = .open;
    try attach(s, id);
}

fn tupleIndex(s: *Solve, id: Id, row: Row) Error!void {
    const st = s.store();
    const result = row.vars[1];
    const tuple, const content = st.resolved(row.vars[0]);
    switch (content) {
        .err, .alias => try s.poison(result),
        .flex => try reopen(s, id),
        .rigid => {
            try s.report.ambiguousTuple(row.region, row.index);
            try s.poison(result);
        },
        .structure => |flat| switch (flat) {
            .tuple => |t| {
                if (row.index >= t.len) {
                    try s.report.tupleIndexOutOfRange(row.region, row.index, t.len, row.vars[0]);
                    return s.poison(result);
                }
                const element = Walk.child(st, tuple, row.index, .structural).?;
                _ = try s.unify(result, element, row.region, .{ .tag = .general });
            },
            else => {
                try s.report.notATuple(row.region, row.index, row.vars[0]);
                try s.poison(result);
            },
        },
    }
}

fn interpolatable(s: *Solve, id: Id, row: Row) Error!void {
    const st = s.store();
    const wk = s.cx.types.well_known;
    switch (st.resolvedContent(row.vars[0])) {
        .err, .alias => {},
        .flex => try reopen(s, id),
        // A `number` rigid is `Int` or `Float`, both of which interpolate.
        // Any other is refused, but not here: held on the rigid until its
        // binder's boundary, whose step 7 reports it (`close`) — unless
        // step 6 finds the rigid escaped, reports THAT and poisons it, which
        // settles the row in silence (one mistake, one message).
        .rigid => |flags| if (flags.kind != .number) {
            const root = st.find(row.vars[0]);
            if (st.rank(root) == TypeStore.generalized) return s.report.ambiguousInterpolation(row.region);
            var held = flags;
            held.obls = try s.obligations.with(s.cx.gpa, flags.obls, id, true);
            s.obligations.rowPtr(id).state = .open;
            st.setContent(root, .{ .rigid = held });
        },
        .structure => |flat| switch (flat) {
            .app => |a| {
                const ok = a.args.len == 0 and
                    (a.type == wk.string or a.type == wk.int or a.type == wk.float or a.type == wk.bool or a.type == wk.char);
                if (!ok) try s.report.notInterpolatable(row.region, row.vars[0]);
            },
            else => try s.report.notInterpolatable(row.region, row.vars[0]),
        },
    }
}

/// The marker walk of §11.4 on a variable that became known. A question
/// already answered "no" at its origin says nothing more: one question, one
/// message, however many variables it was carried to.
fn equatable(s: *Solve, id: Id, row: Row) Error!void {
    if (s.obligations.row(row.origin).reported) return;
    const st = s.store();
    if (st.content(st.find(row.vars[0])) == .flex) return reopen(s, id);
    s.marker.fixpoint_rank = if (s.frame().kind == .fixpoint) s.frame().rank else 0;
    const reason: Report.EquatableReason = switch (try s.marker.equatable(row.vars[0], row.region, row.origin)) {
        .yes => return,
        .function => .function,
        .opaque_type => .opaque_type,
        .rigid => .rigid_variable,
    };
    s.obligations.rowPtr(row.origin).reported = true;
    try s.report.notEquatable(row.region, row.vars[0], reason);
}

const Head = enum { flex, err, result, maybe, other };

fn headOf(s: *Solve, v: Var) Head {
    const wk = s.cx.types.well_known;
    return switch (s.store().resolvedContent(v)) {
        .flex => .flex,
        .err, .alias => .err,
        .rigid => .other,
        .structure => |flat| switch (flat) {
            .app => |a| if (a.type != .none and a.type == wk.result) .result else if (a.type != .none and a.type == wk.maybe) .maybe else .other,
            else => .other,
        },
    };
}

/// §8.6: `e?` whose subject is `vars[0]`, whose target's result is
/// `vars[1]`, and whose value is `vars[2]`. The shape is the subject's when
/// it has one, else the target's, else — only as §8.1 step 3's default — a
/// `Result`. Then three unifications, not speculative, and a failure names
/// its leg (`checker.md` §8.6). A subject that is not a shape, or a
/// variable beside a target that is not one, is the `neither` leg: nothing
/// says the subject is a `Maybe` or a `Result`.
fn tryShape(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const subject = row.vars[0];
    const target = row.vars[1];
    const value = row.vars[2];
    const from_subject = headOf(s, subject);
    const from_target = headOf(s, target);
    if (from_subject == .err or from_target == .err) return s.poison(value);
    const shape: Dispatch.Try.Kind = switch (from_subject) {
        .result => .result,
        .maybe => .maybe,
        .other => return tryFailed(s, row, .neither),
        .err => unreachable,
        .flex => switch (from_target) {
            .result => .result,
            .maybe => .maybe,
            .other => return tryFailed(s, row, .neither),
            .err => unreachable,
            .flex => if (default) .result else return reopen(s, id),
        },
    };
    const wk = s.cx.types.well_known;
    const type_id = if (shape == .result) wk.result else wk.maybe;
    // No core to name the shape: the program has a message already.
    if (type_id == .none) return s.poison(value);
    const arity = s.cx.types.entry(type_id).arity;
    const error_var: ?Var = if (arity == 2) try s.fresh(.{ .flex = .{} }) else null;
    const subject_value = try s.fresh(.{ .flex = .{} });
    const target_value = try s.fresh(.{ .flex = .{} });
    const subject_shape = try applied(s, type_id, error_var, subject_value);
    const target_shape = try applied(s, type_id, error_var, target_value);
    if (try s.unifier.unify(subject_shape, subject, row.region) != .ok) return tryFailed(s, row, .neither);
    if (try s.unifier.unify(target_shape, target, row.region) != .ok) {
        return tryFailed(s, row, if (headOf(s, target) == headOfShape(shape)) .errors else .enclosing);
    }
    try s.tries.append(s.cx.gpa, .{ .inst = row.region, .shape = shape });
    _ = try s.unify(value, subject_value, row.region, .{ .tag = .general });
}

fn headOfShape(shape: Dispatch.Try.Kind) Head {
    return switch (shape) {
        .result => .result,
        .maybe => .maybe,
    };
}

fn applied(s: *Solve, id: TypeStore.TypeId, error_var: ?Var, value: Var) Error!Var {
    const range = if (error_var) |e| try s.store().addVars(&.{ e, value }) else try s.store().addVars(&.{value});
    return s.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } });
}

/// Report a `?` that cannot apply, naming the leg (`checker.md` §8.6), and
/// poison its subject and value, so nothing downstream repeats it.
fn tryFailed(s: *Solve, row: Row, leg: Messages.TryLeg) Error!void {
    try Messages.tryShape(s.report, row.region, leg, row.vars[0], row.vars[1]);
    try s.poison(row.vars[0]);
    try s.poison(row.vars[2]);
}

/// §8.1 step 3 at the current frame, of young rank `rank`: the open `try`
/// rows on its list (§4.5: a row joins the list of the frame at its target's
/// rank) whose target, after rank adjustment, still sits at `rank` are
/// decided as `Result`, oldest first. A row whose target escaped moves to
/// the list of the frame it escaped to, so a row is looked at once per frame
/// it passes through. True when a default was applied or anything
/// was readied: step 1 runs again.
pub fn defaults(s: *Solve, rank: u32) Error!bool {
    const gpa = s.cx.gpa;
    const f = &s.frames.items[rank - 1];
    var list = f.tries;
    f.tries = .empty;
    defer list.deinit(gpa);
    var applied_any = false;
    for (list.items, 0..) |raw, i| {
        const id: Id = @enumFromInt(raw);
        const row = s.obligations.row(id);
        if (row.state != .open) continue;
        const at = try lowerDependants(s, row);
        if (at < rank and at != TypeStore.generalized) {
            try s.frames.items[at - 1].tries.append(gpa, raw);
            continue;
        }
        s.obligations.rowPtr(id).state = .done;
        try decide(s, id, true);
        applied_any = true;
        // A default can ready a wanted whose resolution decides another
        // `?`: drained before the next default is applied.
        if (s.readied()) try drain(s, s.frame().queue, false);
        // The default's consequence demanded a group that merged this
        // frame into one below (§10.4, §10.8): a merged frame applies no
        // more defaults, and hands the rest down to its root.
        if (s.frames.items[rank - 1].merged) {
            try s.frames.items[rank - 1].tries.appendSlice(gpa, list.items[i + 1 ..]);
            return true;
        }
    }
    return applied_any or s.readied();
}

/// §8.1 step 7: the obligations still open on a variable step 5 quantified.
/// Nothing can decide them any more, so an undetermined `tuple_index` or
/// `interpolatable` is reported (they cannot be left to the caller: the
/// emitted code must know the element, and the conversion), and an
/// `equatable` one is the flag the variable already carries into its scheme.
/// The `tuple_index` rows go first, and poison their results: a `${…}` part
/// that is such a result was already reported, as the tuple's.
pub fn close(s: *Solve) Error!void {
    const st = s.store();
    inline for (.{ true, false }) |tuples| {
        for (s.carriers.items) |v| {
            const flags = switch (st.content(st.find(v))) {
                .flex, .rigid => |fl| fl,
                else => continue,
            };
            for (s.obligations.members(flags.obls)) |id| {
                const row = s.obligations.rowPtr(id);
                if (row.state != .open or (row.kind == .tuple_index) != tuples) continue;
                row.state = .done;
                switch (row.kind) {
                    .tuple_index => {
                        try s.report.ambiguousTuple(row.region, row.index);
                        try s.poison(row.vars[1]);
                    },
                    .interpolatable => if (flags.kind != .number) try s.report.ambiguousInterpolation(row.region),
                    .equatable => {},
                    .@"try" => try s.report.internal(row.region, "a `?` reached quantification undecided; §8.1 step 3 defaults every one at its target's boundary first (checker-v2.md §8.6)"),
                }
            }
        }
    }
}

/// `Solve.poison` on a flex that carries rows: nothing can decide them now,
/// so each is settled as a decision on `err` would settle it — done, and its
/// results poisoned — without going through the queue.
pub fn settle(s: *Solve, set: Obligations.Set) Error!void {
    for (s.obligations.members(set)) |id| {
        const row = s.obligations.rowPtr(id);
        if (row.state != .open) continue;
        row.state = .done;
        const r = row.*;
        switch (r.kind) {
            .tuple_index => try s.poison(r.vars[1]),
            .@"try" => try s.poison(r.vars[2]),
            .interpolatable, .equatable => {},
        }
    }
}
