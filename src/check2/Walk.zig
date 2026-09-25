//! Every walk over the type graph (checker-v2.md §4.1, I2, I4).
//!
//! **Two successor functions, and every walk names one** (I2):
//!
//! | Content     | `structural`                                  | `owned`                                   |
//! |-------------|-----------------------------------------------|-------------------------------------------|
//! | `structure` | every parameter, result, argument, element, field value and the extension | the same |
//! | `alias`     | the expansion (`actual`) and the arguments    | the same                                  |
//! | `flex`      | nothing                                       | the method type of every constraint riding on it |
//! | `rigid`     | nothing                                       | the same as `flex` (its givens)           |
//! | `err`       | nothing                                       | nothing                                   |
//!
//! Which walk uses which (§4.1's table): occurs, `recordRow` and the capture
//! search are `structural` — a method type mentions its own receiver, so
//! following it would make every constrained variable a false cycle — and
//! rank adjustment, `lowerTo` and the error scan are `owned`, because what a
//! variable's requirements mention lives and dies with it. In R4b's subset
//! nothing carries a constraint, so the two differ only in principle; the
//! column exists so R5/R6a change a set, not every walk.
//!
//! **No walk has a fixed-size stack, and none answers when it gives up**
//! (I4). Every stack here is a growable `std.ArrayList` the caller owns and
//! reuses, every walk that can meet a cycle carries an epoch colour
//! (`TypeStore.nextMark`, never a memset), and nothing here stops at a depth.
//! A 100 000-deep type is walked to the bottom.
//!
//! Only `child` reads a descriptor's children; the walks below and in
//! `Generalize.zig` enumerate successors through it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TypeStore = @import("../check/TypeStore.zig");
const InternPool = @import("../InternPool.zig");

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

/// Which successor function a walk uses (I2).
pub const Successors = enum {
    structural,
    owned,
    /// What a constructor payload can hold a value of (D10, §14.2's
    /// `payload_params`): `structural`, except that an alias contributes its
    /// expansion only — an argument the expansion drops holds no value.
    payload,
};

/// The `n`th successor of `root` (a union-find root), or null past the end.
/// One place that knows every `Content`'s shape, so a new one is a compile
/// error here and not a missed edge.
pub fn child(store: *const TypeStore, root: Var, n: u32, comptime successors: Successors) ?Var {
    switch (store.content(root)) {
        .err => return null,
        .flex, .rigid => |flags| {
            if (successors != .owned) return null;
            const set = constraints(flags);
            return if (n < set.count(store)) set.at(store, n).fn_var else null;
        },
        .alias => |a| {
            if (n == 0) return a.actual;
            if (successors == .payload) return null;
            const args = store.vars(a.args);
            return if (n - 1 < args.len) args[n - 1] else null;
        },
        .structure => |flat| switch (flat) {
            .unit, .empty_record => return null,
            .func => |f| {
                const params = store.vars(f.params);
                if (n < params.len) return params[n];
                return if (n == params.len) f.result else null;
            },
            .app => |a| {
                const args = store.vars(a.args);
                return if (n < args.len) args[n] else null;
            },
            .tuple => |t| {
                const elements = store.vars(t);
                return if (n < elements.len) elements[n] else null;
            },
            .record => |r| {
                const fields = store.fields(r.fields);
                if (n < fields.len) return fields[n].value;
                return if (n == fields.len) r.ext else null;
            },
        },
    }
}

// ---------------------------------------------------------------------------
// The one reading of a variable's method constraints (§4.1, S3)
// ---------------------------------------------------------------------------

/// A variable's method constraints, as v1's `Flags.constraints` holds them.
/// Every v2 read of them goes through here, so R5/R6a change the
/// representation in ONE place (`checker-rewrite.md` R5: where `wants` and
/// `obls` live is decided before any obligation code is written).
pub const Constraints = struct {
    set: TypeStore.ConstraintSet.Optional,

    pub fn count(c: Constraints, store: *const TypeStore) u32 {
        return store.constraintCount(c.set);
    }

    pub fn at(c: Constraints, store: *const TypeStore, i: u32) TypeStore.MethodConstraint {
        return store.constraintAt(c.set, i);
    }

    pub fn isEmpty(c: Constraints) bool {
        return c.set == .none;
    }
};

pub fn constraints(flags: TypeStore.Flags) Constraints {
    return .{ .set = flags.constraints };
}

// ---------------------------------------------------------------------------
// Children read outside a walk (I2 as restated by R4b's review, S6)
// ---------------------------------------------------------------------------

/// A function type's parameters and result, `v` resolved through aliases,
/// or null when it is not a function. The parameters are a view into the
/// store's `extra`, valid until the store grows.
pub const Function = struct { params: []const Var, result: Var };

pub fn function(store: *TypeStore, v: Var) ?Function {
    return switch (store.resolvedContent(v)) {
        .structure => |flat| switch (flat) {
            .func => |f| .{ .params = store.vars(f.params), .result = f.result },
            else => null,
        },
        else => null,
    };
}

/// One DFS frame: a node and which of its successors is next.
pub const Frame = struct { v: Var, cursor: u32 };

/// The reusable stacks of one module's walks. Owned by the solver, cleared
/// per walk and never shrunk, so a walk allocates only when a type is
/// deeper than every one before it.
pub const Stacks = struct {
    frames: std.ArrayList(Frame) = .empty,
    vars: std.ArrayList(Var) = .empty,
    /// Rank adjustment's frames (`Generalize.adjustRanks`).
    ranks: std.ArrayList(RankFrame) = .empty,
    /// `firstCycle`'s frames and their successors in text order.
    ordered: std.ArrayList(OrderedFrame) = .empty,
    kids: std.ArrayList(Var) = .empty,
    fields: std.ArrayList(TypeStore.Field) = .empty,

    pub fn deinit(s: *Stacks, gpa: Allocator) void {
        s.frames.deinit(gpa);
        s.vars.deinit(gpa);
        s.ranks.deinit(gpa);
        s.ordered.deinit(gpa);
        s.kids.deinit(gpa);
        s.fields.deinit(gpa);
    }
};

/// One frame of the iterative rank walk: a node, its next successor, and
/// the running maximum of its successors' ranks when it folds them.
pub const RankFrame = struct { v: Var, cursor: u32, max: u32, maxes: bool };

// ---------------------------------------------------------------------------
// Occurs (§8.2): three colours over `structural` successors
// ---------------------------------------------------------------------------

/// A run of occurs checks that share one pair of epochs, so a node already
/// proved acyclic (black) is not walked again by the next root of the same
/// run — one boundary's binders are one run (§8.2, §18).
///
/// After a cycle is found the caller poisons it and calls `restart`: the
/// abandoned walk left grey marks behind, and a grey mark read by the next
/// root would be a false cycle.
pub const Occurs = struct {
    grey: u32,
    black: u32,

    pub fn begin(store: *TypeStore) Occurs {
        return .{ .grey = store.nextMark(), .black = store.nextMark() };
    }

    pub fn restart(o: *Occurs, store: *TypeStore) void {
        o.* = begin(store);
    }

    /// The node on a cycle reachable from `v` — the one the walk met again
    /// while it was still on the path — or null when there is none.
    pub fn check(o: *Occurs, store: *TypeStore, stacks: *Stacks, gpa: Allocator, v: Var) Error!?Var {
        const start = store.find(v);
        if (isLeaf(store, start) or store.mark(start) == o.black) return null;
        const frames = &stacks.frames;
        frames.clearRetainingCapacity();
        try frames.append(gpa, .{ .v = start, .cursor = 0 });
        store.setMark(start, o.grey);
        while (frames.items.len > 0) {
            const top = &frames.items[frames.items.len - 1];
            const root = top.v;
            const next = child(store, root, top.cursor, .structural);
            top.cursor += 1;
            if (next) |c| {
                const r = store.find(c);
                const mark = store.mark(r);
                if (mark == o.grey) return r;
                // A node with no successor cannot be on a cycle, and a black
                // one was walked to the bottom already: neither is pushed.
                if (mark == o.black or isLeaf(store, r)) continue;
                store.setMark(r, o.grey);
                try frames.append(gpa, .{ .v = r, .cursor = 0 });
                continue;
            }
            store.setMark(root, o.black);
            _ = frames.pop();
        }
        return null;
    }
};

/// A node with no `structural` successor: no cycle passes through it.
fn isLeaf(store: *const TypeStore, root: Var) bool {
    return !hasSuccessors(store.content(root));
}

/// Whether a node of this content has a `structural` successor.
fn hasSuccessors(content: TypeStore.Content) bool {
    return switch (content) {
        .err, .flex, .rigid => false,
        .alias => true,
        .structure => |flat| switch (flat) {
            .unit, .empty_record => false,
            .app => |a| a.args.len != 0,
            .func, .tuple, .record => true,
        },
    };
}

/// The variable a record's field range gives `name`, by binary search (a
/// range is sorted by symbol): the generator's lookup into a record it just
/// built.
pub fn fieldIn(store: *const TypeStore, range: TypeStore.Range, name: InternPool.Symbol) ?Var {
    const fields = store.fields(range);
    var lo: usize = 0;
    var hi: usize = fields.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = @intFromEnum(fields[mid].name);
        const want = @intFromEnum(name);
        if (at < want) lo = mid + 1 else if (at > want) hi = mid else return fields[mid].value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The error path's cycle, chosen by text (I13; review S5)
// ---------------------------------------------------------------------------

pub const OrderedFrame = struct { v: Var, kids_start: u32, kids_len: u32, cursor: u32 };

/// The cycle `Occurs.check` would find from `v`, but found with a record's
/// fields visited in NAME-TEXT order, so which of two cycles is reported,
/// and drawn, does not depend on symbol ids (which depend on which worker
/// interned what). The error path only: it sorts every record it meets.
pub fn firstCycle(store: *TypeStore, stacks: *Stacks, gpa: Allocator, interner: *const InternPool.Global, v: Var) Error!?Var {
    const grey = store.nextMark();
    const black = store.nextMark();
    const frames = &stacks.ordered;
    const kids = &stacks.kids;
    frames.clearRetainingCapacity();
    kids.clearRetainingCapacity();
    const start = store.find(v);
    if (isLeaf(store, start)) return null;
    store.setMark(start, grey);
    try pushOrdered(store, stacks, gpa, interner, start);
    while (frames.items.len > 0) {
        const top = &frames.items[frames.items.len - 1];
        if (top.cursor < top.kids_len) {
            const r = store.find(kids.items[top.kids_start + top.cursor]);
            top.cursor += 1;
            const mark = store.mark(r);
            if (mark == grey) return r;
            if (mark == black or isLeaf(store, r)) continue;
            store.setMark(r, grey);
            try pushOrdered(store, stacks, gpa, interner, r);
            continue;
        }
        const done = frames.pop().?;
        store.setMark(done.v, black);
        kids.shrinkRetainingCapacity(done.kids_start);
    }
    return null;
}

fn pushOrdered(store: *TypeStore, stacks: *Stacks, gpa: Allocator, interner: *const InternPool.Global, root: Var) Error!void {
    const kids = &stacks.kids;
    const start: u32 = @intCast(kids.items.len);
    switch (store.content(root)) {
        .structure => |flat| switch (flat) {
            .record => |r| {
                const fields = &stacks.fields;
                fields.clearRetainingCapacity();
                try fields.appendSlice(gpa, store.fields(r.fields));
                std.mem.sort(TypeStore.Field, fields.items, interner, fieldTextLessThan);
                for (fields.items) |f| try kids.append(gpa, f.value);
                try kids.append(gpa, r.ext);
            },
            else => {
                var n: u32 = 0;
                while (child(store, root, n, .structural)) |c| : (n += 1) try kids.append(gpa, c);
            },
        },
        else => {
            var n: u32 = 0;
            while (child(store, root, n, .structural)) |c| : (n += 1) try kids.append(gpa, c);
        },
    }
    try stacks.ordered.append(gpa, .{ .v = root, .kids_start = start, .kids_len = @intCast(kids.items.len - start), .cursor = 0 });
}

fn fieldTextLessThan(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
    return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
}

/// Whether `target`'s root is `from`'s root or reachable from it by
/// `structural` successors. The capture search of §8.3 (§7.1, *As built by
/// R4b*): error path only.
pub fn reaches(store: *TypeStore, stacks: *Stacks, gpa: Allocator, from: Var, target: Var) Error!bool {
    const want = store.find(target);
    const seen = store.nextMark();
    const stack = &stacks.vars;
    stack.clearRetainingCapacity();
    try stack.append(gpa, from);
    while (stack.pop()) |v| {
        const root = store.find(v);
        if (root == want) return true;
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        var n: u32 = 0;
        while (child(store, root, n, .structural)) |c| : (n += 1) try stack.append(gpa, c);
    }
    return false;
}

// ---------------------------------------------------------------------------
// The error scan of publication (§14.1): `owned`, kept three-valued
// ---------------------------------------------------------------------------

/// v1's `hasError`, three-valued and budgeted by the store's own size
/// (checker.md §7): `unknown` cannot arise from a well-formed store, and the
/// caller treats it as `poisoned` AND reports, never as clean.
pub const ErrorScan = enum { clean, poisoned, unknown };

pub fn hasError(store: *TypeStore, stacks: *Stacks, gpa: Allocator, root_var: Var) Error!ErrorScan {
    const seen = store.nextMark();
    const stack = &stacks.vars;
    stack.clearRetainingCapacity();
    try stack.append(gpa, root_var);
    var budget: usize = @as(usize, store.count()) + 16;
    while (stack.pop()) |v| {
        const root = store.find(v);
        if (store.mark(root) == seen) continue;
        if (budget == 0) return .unknown;
        budget -= 1;
        store.setMark(root, seen);
        if (store.content(root) == .err) return .poisoned;
        var n: u32 = 0;
        while (child(store, root, n, .owned)) |c| : (n += 1) try stack.append(gpa, c);
    }
    return .clean;
}

// ---------------------------------------------------------------------------
// I15's lowering (§7.1): `owned`, downward only
// ---------------------------------------------------------------------------

/// Lower every variable reachable from `v` by `owned` successors to at most
/// `rank`, stopping at nodes already at or below it (OCaml's `update_level`
/// on binding). R4b attaches nothing, so nothing calls this yet; R5/R6a's
/// attach and merge paths do (§4.5, §7.1).
pub fn lowerTo(store: *TypeStore, stacks: *Stacks, gpa: Allocator, v: Var, rank: u32) Error!void {
    const seen = store.nextMark();
    const stack = &stacks.vars;
    stack.clearRetainingCapacity();
    try stack.append(gpa, v);
    while (stack.pop()) |next| {
        const root = store.find(next);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        if (store.rank(root) <= rank) continue;
        store.setRank(root, rank);
        var n: u32 = 0;
        while (child(store, root, n, .owned)) |c| : (n += 1) try stack.append(gpa, c);
    }
}

// ---------------------------------------------------------------------------
// Records (§4.1): the one closedness test
// ---------------------------------------------------------------------------

/// Where a record's extension chain ends.
pub const RowEnd = union(enum) {
    /// `{}`: the record is closed.
    closed: Var,
    /// A variable (flex, rigid or `err`), or a non-record structure.
    open: Var,
};

/// Follow `record`'s extension chain to its end, appending every field met
/// to `out`, and say where it ends. `concatenated` is set when a second
/// record joined the first, so the fields are no longer one sorted run.
///
/// Cycle-safe by colour rather than by a bound (I4): a chain that comes back
/// to a record already on it ends there, as an `open` end at that node, and
/// the occurs check reports the cycle at its boundary.
pub fn recordRow(
    store: *TypeStore,
    record: TypeStore.Structure.Record,
    out: *std.ArrayList(TypeStore.Field),
    gpa: Allocator,
    concatenated: *bool,
) Error!RowEnd {
    try out.appendSlice(gpa, store.fields(record.fields));
    const seen = store.nextMark();
    var ext = record.ext;
    while (true) {
        const root, const c = store.resolved(ext);
        switch (c) {
            .structure => |s| switch (s) {
                .record => |r| {
                    if (store.mark(root) == seen) return .{ .open = root };
                    store.setMark(root, seen);
                    try out.appendSlice(gpa, store.fields(r.fields));
                    concatenated.* = true;
                    ext = r.ext;
                },
                .empty_record => return .{ .closed = root },
                else => return .{ .open = root },
            },
            else => return .{ .open = root },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "occurs finds a cycle through a record and none through a constraint's method type" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Stacks = .{};
    defer stacks.deinit(testing.allocator);

    // x = { e | f : x }
    const x = try store.freshFlex(1);
    const e = try store.freshFlex(1);
    var fields = [_]TypeStore.Field{.{ .name = @enumFromInt(3), .value = x }};
    const range = try store.addFields(&fields);
    const record = try store.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = e } } }, 1);
    _ = store.merge(x, record, store.content(record));
    var o: Occurs = .begin(&store);
    try testing.expect((try o.check(&store, &stacks, testing.allocator, x)) != null);

    // y carries a constraint whose method type mentions y: not a cycle for
    // `structural`, and `owned` does see it.
    const y = try store.freshFlex(1);
    const params = try store.addVars(&.{ y, y });
    const method = try store.fresh(.{ .structure = .{ .func = .{ .params = params, .result = y } } }, 1);
    const set = try store.addConstraints(&.{.{ .name = @enumFromInt(1), .fn_var = method, .region = @enumFromInt(0), .origin = .dot_call }});
    store.setContent(y, .{ .flex = .{ .constraints = set.toOptional() } });
    o.restart(&store);
    try testing.expectEqual(@as(?Var, null), try o.check(&store, &stacks, testing.allocator, y));
    try testing.expectEqual(@as(?Var, method), child(&store, y, 0, .owned));
    try testing.expectEqual(@as(?Var, null), child(&store, y, 0, .structural));
}

test "a 100 000-deep type goes through occurs, the error scan and lowerTo" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Stacks = .{};
    defer stacks.deinit(testing.allocator);
    var v = try store.fresh(.err, 5);
    const bottom = v;
    for (0..100_000) |_| {
        const args = try store.addVars(&.{v});
        v = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(0), .args = args } } }, 5);
    }
    var o: Occurs = .begin(&store);
    try testing.expectEqual(@as(?Var, null), try o.check(&store, &stacks, testing.allocator, v));
    try testing.expectEqual(ErrorScan.poisoned, try hasError(&store, &stacks, testing.allocator, v));
    try lowerTo(&store, &stacks, testing.allocator, v, 2);
    try testing.expectEqual(@as(u32, 2), store.rank(bottom));
    try testing.expect(try reaches(&store, &stacks, testing.allocator, v, bottom));
}
