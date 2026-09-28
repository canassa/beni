//! Every walk over the type graph (checker-v2.md §4.1).
//!
//! **Two successor functions, and every walk names one**:
//!
//! | Content     | `structural`                                  | `owned`                                   |
//! |-------------|-----------------------------------------------|-------------------------------------------|
//! | `structure` | every parameter, result, argument, element, field value and the extension | the same |
//! | `alias`     | the expansion (`actual`) and the arguments    | the same                                  |
//! | `flex`      | nothing                                       | the method type of every constraint riding on it, then every variable of every open obligation riding on it (§4.5) |
//! | `rigid`     | nothing                                       | the same as `flex` (its givens)           |
//! | `err`       | nothing                                       | nothing                                   |
//!
//! Which walk uses which (§4.1's table): occurs, `recordRow` and the capture
//! search are `structural` — a method type mentions its own receiver, so
//! following it would make every constrained variable a false cycle — and
//! rank adjustment, `lowerTo` and the error scan are `owned`, because what a
//! variable's requirements mention lives and dies with it. An
//! obligation's variables are `owned` successors of the variables it rides
//! on (§4.5), read by `owned`, the one function that sees the obligation
//! table.
//!
//! **No walk has a fixed-size stack, and none answers when it gives up**
//! Every stack here is a growable `std.ArrayList` the caller owns and
//! reuses, every walk that can meet a cycle carries an epoch colour
//! (`TypeStore.nextMark`, never a memset), and nothing here stops at a depth.
//! A 100 000-deep type is walked to the bottom.
//!
//! Only `child`, `owned` and `eachOwned` (`owned` in one decode) read a
//! descriptor's children; the walks below and in `Generalize.zig` enumerate
//! successors through them.

const std = @import("std");
const lists = @import("../lists.zig");
const Allocator = std.mem.Allocator;
const TypeStore = @import("TypeStore.zig");
const InternPool = @import("../InternPool.zig");
const Obligations = @import("Obligations.zig");

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

/// Which successor function a walk uses.
pub const Successors = enum {
    structural,
    owned,
    /// What a constructor payload can hold a value of (§11.4, §14.2's
    /// `payload_params`): `structural`, except that an alias contributes its
    /// expansion only — an argument the expansion drops holds no value.
    payload,
};

/// The `n`th successor of `root` (a union-find root), or null past the end.
/// One place that knows every `Content`'s shape, so a new one is a compile
/// error here and not a missed edge.
///
/// `owned` successors come from `owned`, which also reads the module's
/// obligation table (§4.5); asking this function for them is a compile error.
pub inline fn child(store: *const TypeStore, root: Var, n: u32, comptime successors: Successors) ?Var {
    if (successors == .owned) @compileError("owned successors come from Walk.owned, which also reads the obligations riding on a variable (checker-v2.md §4.5)");
    return shape(store, root, n, successors);
}
/// The `n`th `owned` successor of `root` (§4.1's table, §4.5): for a
/// variable, the method type of every constraint riding on it and then the
/// dependants of every open obligation it owns (`obligations` null reads
/// none); for anything else, its `structural` successors. The one WALK
/// successor function that yields obligation variables; `child(…, .owned)`
/// does not compile.
/// none); for anything else, its `structural` successors.
pub fn owned(store: *TypeStore, obligations: ?*const Obligations, root: Var, n: u32) ?Var {
    switch (store.content(root)) {
        .flex, .rigid => |flags| {
            const set = constraints(flags);
            const count = set.count(store);
            if (n < count) return set.at(store, n).fn_var;
            const o = obligations orelse return null;
            return o.successor(store, flags.obls, root, n - count);
        },
        else => return shape(store, root, n, .owned),
    }
}

/// Every `owned` successor of `root`, whose content is `content`, handed to
/// `visitor.add` in `owned`'s order: the node decoded once, not once per
/// successor as a cursor over `owned` does (rank adjustment's walk).
pub inline fn eachOwned(store: *TypeStore, obligations: ?*const Obligations, root: Var, content: TypeStore.Content, visitor: anytype) Error!void {
    switch (content) {
        .err => {},
        .flex, .rigid => {
            var n: u32 = 0;
            while (owned(store, obligations, root, n)) |c| : (n += 1) try visitor.add(c);
        },
        .alias => |a| {
            try visitor.add(a.actual);
            for (store.vars(a.args)) |c| try visitor.add(c);
        },
        .structure => |flat| switch (flat) {
            .unit, .empty_record => {},
            .func => |f| {
                for (store.vars(f.params)) |c| try visitor.add(c);
                try visitor.add(f.result);
            },
            .app => |a| for (store.vars(a.args)) |c| try visitor.add(c),
            .tuple => |t| for (store.vars(t)) |c| try visitor.add(c),
            .record => |r| {
                for (store.fields(r.fields)) |f| try visitor.add(f.value);
                try visitor.add(r.ext);
            },
        },
    }
}

inline fn shape(store: *const TypeStore, root: Var, n: u32, comptime successors: Successors) ?Var {
    switch (store.content(root)) {
        .err, .flex, .rigid => return null,
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

/// What `encodeGround` found besides the encoding.
pub const Ground = struct {
    /// `heads.kept` said yes to every nominal head.
    kept: bool,
};

/// A GROUND type's structure as words (`Derivable.Shapes`): `first`,
/// then `root` in preorder, each node a tag and its arity — an application
/// its type, a record its field names — with aliases read through to their
/// expansion. Null for a variable, an `err` or a function anywhere, or past
/// `cap` words (a graph with a cycle among them). `heads.kept(app)` says
/// whether a nominal head may be kept by structure. `words` and `stack` are
/// the caller's, reused.
pub fn encodeGround(
    store: *TypeStore,
    gpa: Allocator,
    words: *std.ArrayList(u32),
    stack: *std.ArrayList(Var),
    root: Var,
    first: u32,
    cap: usize,
    heads: anytype,
) Error!?Ground {
    const Tag = enum(u32) { unit, empty_record, tuple, app, record };
    words.clearRetainingCapacity();
    stack.clearRetainingCapacity();
    var found: Ground = .{ .kept = true };
    try lists.add(words, gpa, first);
    try lists.add(stack, gpa, root);
    while (stack.pop()) |v| {
        if (words.items.len > cap) return null;
        const flat = switch (store.resolvedContent(v)) {
            .structure => |flat| flat,
            .flex, .rigid, .err, .alias => return null,
        };
        switch (flat) {
            .unit => try lists.add(words, gpa, @intFromEnum(Tag.unit)),
            .empty_record => try lists.add(words, gpa, @intFromEnum(Tag.empty_record)),
            .func => return null,
            .tuple => |t| {
                const elements = store.vars(t);
                try words.appendSlice(gpa, &.{ @intFromEnum(Tag.tuple), @intCast(elements.len) });
                var i = elements.len;
                while (i > 0) : (i -= 1) try lists.add(stack, gpa, elements[i - 1]);
            },
            .app => |a| {
                if (a.type == .none) return null;
                if (!heads.kept(a)) found.kept = false;
                const args = store.vars(a.args);
                try words.appendSlice(gpa, &.{ @intFromEnum(Tag.app), a.type.int(), @intCast(args.len) });
                var i = args.len;
                while (i > 0) : (i -= 1) try lists.add(stack, gpa, args[i - 1]);
            },
            .record => |rec| {
                const fields = store.fields(rec.fields);
                try words.appendSlice(gpa, &.{ @intFromEnum(Tag.record), @intCast(fields.len) });
                for (fields) |f| try lists.add(words, gpa, @intFromEnum(f.name));
                try lists.add(stack, gpa, rec.ext);
                var i = fields.len;
                while (i > 0) : (i -= 1) try lists.add(stack, gpa, fields[i - 1].value);
            },
        }
    }
    if (words.items.len > cap) return null;
    return found;
}

// ---------------------------------------------------------------------------
// The one reading of a variable's method constraints (§4.1)
// ---------------------------------------------------------------------------

/// A variable's method constraints, as `Flags.constraints` holds them.
/// Every read of them goes through here, so the representation changes in
/// ONE place.
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
// Children read outside a walk (§4.1)
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

/// A tuple's elements or an application's arguments, `v` resolved through
/// aliases, or none: the positions a derived shape is answered over (§9.3
/// step 5). A view into the store's `extra`, valid until the store grows.
pub fn positions(store: *TypeStore, v: Var) []const Var {
    return switch (store.resolvedContent(v)) {
        .structure => |flat| switch (flat) {
            .tuple => |t| store.vars(t),
            .app => |a| store.vars(a.args),
            else => &.{},
        },
        else => &.{},
    };
}

/// A record node's own fields, in symbol order: the one accessor for a walk
/// that must see field NAMES (the marker walk's text-order pass).
pub fn recordFields(store: *const TypeStore, record: TypeStore.Structure.Record) []const TypeStore.Field {
    return store.fields(record.fields);
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
    /// Rank adjustment's pending successors; a frame's start at `base`.
    rank_kids: std.ArrayList(Var) = .empty,
    /// The module's obligation table, which every `owned` walk reads (§4.5);
    /// null where there is none (a unit test). It rides here, beside the
    /// scratch stacks, because every `owned` walk already takes `Stacks`:
    /// this struct is the module's walk context, not only its stacks (N10).
    obligations: ?*const Obligations = null,
    /// `firstCycle`'s frames and their successors in text order.
    ordered: std.ArrayList(OrderedFrame) = .empty,
    kids: std.ArrayList(Var) = .empty,
    fields: std.ArrayList(TypeStore.Field) = .empty,
    /// Debug: `assertProved`'s colours, one per store variable, the last
    /// two values it handed out, and its frames, reused across its calls:
    /// fresh ones per call would make the Debug check of a 1 100-link
    /// alias chain spend seconds allocating (`run/AliasChainThroughLet`).
    assert_marks: std.ArrayList(u32) = .empty,
    assert_epoch: u32 = 0,
    assert_frames: std.ArrayList(Frame) = .empty,
    pub fn deinit(s: *Stacks, gpa: Allocator) void {
        s.assert_marks.deinit(gpa);
        s.assert_frames.deinit(gpa);
        s.frames.deinit(gpa);
        s.vars.deinit(gpa);
        s.ranks.deinit(gpa);
        s.rank_kids.deinit(gpa);
        s.ordered.deinit(gpa);
        s.kids.deinit(gpa);
        s.fields.deinit(gpa);
    }
};

/// One frame of the iterative rank walk: a node, where its pending successors
/// start on `Stacks.rank_kids`, and the running maximum of its successors' ranks when it folds them.
pub const RankFrame = struct { v: Var, base: u32, max: u32, maxes: bool };

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
    /// Whether this run records what it proves (`TypeStore.acyclic`): every
    /// node it blackens and every leaf it meets, so a later
    /// walk — a later boundary's, or a nested position's cycle test — stops
    /// at any of them (`checker-v2.md` §8.2).
    /// `binders_end`'s runs could prove too (every node a run blackens is
    /// acyclic); they do not, which keeps their cost what it was.
    proves: bool = false,
    /// Whether a proving run records every node it blackens, or only its
    /// roots and the leaves it meets (enough for soundness: a proved root's
    /// leaves are proved). §9.5's cycle test records every node, so the
    /// positions of the receiver it proved are proved; a boundary's
    /// run only its roots, which is all a later boundary meets.
    interior: bool = false,
    /// Whether this run stops at a proved node. False only for the Debug
    /// check of a proof (`Resolve.step`).
    trusts: bool = true,
    /// The deepest path a run walks before it stops and says `too_deep`
    /// for a boundary's run over its binders (`Solve.closeFrame`),
    /// whose binder is then `nesting_too_deep` (checker-v2.md
    /// §7.3). Unbounded for every other run.
    limit: u32 = std.math.maxInt(u32),
    /// Set when a path went past `limit`: the run stopped there, and said
    /// nothing about cycles.
    too_deep: bool = false,

    pub fn begin(store: *TypeStore) Occurs {
        return .{ .grey = store.nextMark(), .black = store.nextMark() };
    }

    pub fn restart(o: *Occurs, store: *TypeStore) void {
        const proves = o.proves;
        const trusts = o.trusts;
        const interior = o.interior;
        const limit = o.limit;
        o.* = begin(store);
        o.proves = proves;
        o.trusts = trusts;
        o.interior = interior;
        o.limit = limit;
    }

    /// The node on a cycle reachable from `v` — the one the walk met again
    /// while it was still on the path — or null when there is none.
    pub fn check(o: *Occurs, store: *TypeStore, stacks: *Stacks, gpa: Allocator, v: Var) Error!?Var {
        const start = store.find(v);
        if (isLeaf(store, start) or store.mark(start) == o.black) return null;
        if (o.trusts and store.proved(start)) {
            try assertProved(store, stacks, gpa, start);
            return null;
        }
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
                if (mark == o.black) continue;
                if (o.trusts and store.proved(r)) {
                    try assertProved(store, stacks, gpa, r);
                    continue;
                }
                if (isLeaf(store, r)) {
                    // A leaf of the graph being proved: giving it successors
                    // voids the proof (`TypeStore.gains`).
                    if (o.proves) store.prove(r);
                    continue;
                }
                if (frames.items.len >= o.limit) {
                    o.too_deep = true;
                    return null;
                }
                store.setMark(r, o.grey);
                try frames.append(gpa, .{ .v = r, .cursor = 0 });
                continue;
            }
            store.setMark(root, o.black);
            if (o.proves and (o.interior or frames.items.len == 1)) store.prove(root);
            _ = frames.pop();
        }
        return null;
    }
};

/// Debug: a proved node reaches no cycle (`checker-v2.md` §8.2), checked by
/// a walk of its own that trusts no proof
/// and touches no mark, over at most `assert_cap` nodes, wherever a walk
/// stops at a proof. A hole in the invariant panics in the tests instead of
/// hiding a cycle.
///
/// **Bounded per store**: every stop at a proof re-walks up
/// to `assert_cap` nodes, and a 4 095-level record literal stops at one per
/// level and position, so an unbounded Debug check would take hundreds of
/// times ReleaseFast's time. The walks share a budget of `assert_budget_per_var` visits per store
/// variable (plus a floor): every program the corpus holds is checked in
/// full but the two whose size is their point (an alias chain 1 100
/// links long, a requirement 512 deep), and a pathological one is checked
/// until the budget runs out. A floor of a million visits let a
/// comparison of lists nested 1 024 deep spend most of a second on this
/// check alone, several times the check it guards.
fn assertProved(store: *TypeStore, stacks: *Stacks, gpa: Allocator, v: Var) Error!void {
    if (!std.debug.runtime_safety) return;
    if (store.proof_assert_work > assert_budget_floor + @as(u64, store.count()) * assert_budget_per_var) return;
    // The colours are marks of this walk's own, in a column beside the
    // store's (it touches none of the store's marks), two fresh values per
    // walk: a hash map of them was two thirds of the walk's cost.
    const marks = &stacks.assert_marks;
    if (marks.items.len < store.count()) try marks.appendNTimes(gpa, 0, store.count() - marks.items.len);
    if (stacks.assert_epoch > std.math.maxInt(u32) - 2) {
        @memset(marks.items, 0);
        stacks.assert_epoch = 0;
    }
    const grey = stacks.assert_epoch + 1;
    const black = stacks.assert_epoch + 2;
    stacks.assert_epoch = black;
    const frames = &stacks.assert_frames;
    frames.clearRetainingCapacity();
    try frames.append(gpa, .{ .v = v, .cursor = 0 });
    marks.items[v.int()] = grey;
    var visited: u32 = 1;
    defer store.proof_assert_work += visited;
    while (frames.items.len > 0) {
        if (visited > assert_cap) return;
        const top = &frames.items[frames.items.len - 1];
        const next = child(store, top.v, top.cursor, .structural);
        top.cursor += 1;
        if (next) |c| {
            const r = store.find(c);
            const colour = marks.items[r.int()];
            if (colour == grey) std.debug.panic("a proved node reaches a cycle (checker-v2.md §8.2)", .{});
            if (colour == black) continue;
            if (isLeaf(store, r)) continue;
            marks.items[r.int()] = grey;
            visited += 1;
            try frames.append(gpa, .{ .v = r, .cursor = 0 });
            continue;
        }
        marks.items[top.v.int()] = black;
        _ = frames.pop();
    }
}

const assert_cap = 1024;
const assert_budget_per_var = 16;
const assert_budget_floor = 1 << 16;

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
// The error path's cycle, chosen by text (§7.2)
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
/// `structural` successors. The capture search of §8.3 (§7.1): error path
/// only.
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

/// `reaches`, also through the method type of every requirement on a
/// variable met: the closure `Schemes.quantifierOrder` lists a scheme's
/// quantifiers from, so "is `target` one of `from`'s quantifiers" has one
/// answer whichever of the two asks. Error path only.
pub fn reachesThroughRequirements(store: *TypeStore, stacks: *Stacks, gpa: Allocator, from: Var, target: Var) Error!bool {
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
        // `owned` with no obligation table: the structural successors, and
        // a variable's requirements' method types.
        var n: u32 = 0;
        while (owned(store, null, root, n)) |c| : (n += 1) try stack.append(gpa, c);
    }
    return false;
}

/// The variable roots (`flex`, `rigid`) reachable from `from` by
/// `structural` successors, each once, appended to `out` (allocated with
/// `scratch`).
pub fn variables(store: *TypeStore, stacks: *Stacks, gpa: Allocator, scratch: Allocator, from: Var, out: *std.ArrayList(Var)) Error!void {
    const seen = store.nextMark();
    const stack = &stacks.vars;
    stack.clearRetainingCapacity();
    try stack.append(gpa, from);
    while (stack.pop()) |v| {
        const root = store.find(v);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        switch (store.content(root)) {
            .flex, .rigid => try out.append(scratch, root),
            else => {},
        }
        var n: u32 = 0;
        while (child(store, root, n, .structural)) |c| : (n += 1) try stack.append(gpa, c);
    }
}

// ---------------------------------------------------------------------------
// The error scan of publication (§14.1): `owned`, kept three-valued
// ---------------------------------------------------------------------------

/// `hasError`, three-valued and budgeted by the store's own size
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
        while (owned(store, stacks.obligations, root, n)) |c| : (n += 1) try stack.append(gpa, c);
    }
    return .clean;
}

// ---------------------------------------------------------------------------
// Rank lowering (§7.1): `owned`, downward only
// ---------------------------------------------------------------------------

/// Lower every variable reachable from `v` by `owned` successors to at most
/// `rank`, stopping at nodes already at or below it (OCaml's `update_level`
/// on binding). Called when an obligation is attached and when a merge moves
/// one, so all the variables of one obligation share one rank (§4.5).
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
        while (owned(store, stacks.obligations, root, n)) |c| : (n += 1) try stack.append(gpa, c);
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
/// Cycle-safe by colour rather than by a bound: a chain that comes back
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
    try testing.expectEqual(@as(?Var, method), owned(&store, null, y, 0));
    try testing.expectEqual(@as(?Var, null), child(&store, y, 0, .structural));
}

const small_stack = @import("../small_stack.zig");

/// Twice the depth at which the smallest recursive walk there is — one
/// frame per level, reading one child and nothing else — overflows
/// `small_stack.size` on the Debug test binary: it finished 4 000 levels
/// and overflowed at 10 000. A walk that recursed per level cannot get
/// through a type this deep on that stack.
pub const deep_type = 20_000;

test "a type deeper than a recursive walk survives goes through occurs, the error scan and lowerTo" {
    // The walks keep their own stack (`Stacks`), so they run on
    // `small_stack`'s few pages at any depth.
    try small_stack.run(walkDeepType, .{});
}

fn walkDeepType() !void {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Stacks = .{};
    defer stacks.deinit(testing.allocator);
    var v = try store.fresh(.err, 5);
    const bottom = v;
    for (0..deep_type) |_| {
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

test "a variable met only in a requirement's method type is reached through requirements alone" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Stacks = .{};
    defer stacks.deinit(testing.allocator);
    // `a` carries `a.m : a, b -> b`; `b` appears nowhere else.
    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    const params = try store.addVars(&.{ a, b });
    const method_type = try store.fresh(.{ .structure = .{ .func = .{ .params = params, .result = b } } }, 1);
    const set = try store.addConstraints(&.{.{ .name = @enumFromInt(3), .fn_var = method_type, .region = @enumFromInt(0), .origin = .where_clause }});
    store.setContent(a, .{ .flex = .{ .constraints = set.toOptional() } });
    const args = try store.addVars(&.{a});
    const scheme = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(0), .args = args } } }, 1);
    try testing.expect(!try reaches(&store, &stacks, testing.allocator, scheme, b));
    try testing.expect(try reachesThroughRequirements(&store, &stacks, testing.allocator, scheme, b));
    try testing.expect(try reachesThroughRequirements(&store, &stacks, testing.allocator, scheme, a));
}

/// Whether `a` and `b` are the same type up to fresh copies: the same
/// variable roots at the leaves (a frozen template's parameters are shared,
/// not copied) and the same heads, children in `structural` order. For
/// `Contexts`' Debug assert that a pass whose entry set did not change did
/// not change its template either: O(size), no marks,
/// so it may run beside any walk. A cycle is not followed past `limit`
/// pairs, and answers true: a template has none, and the assert must not
/// be the thing that loops.
pub fn sameShape(store: *TypeStore, gpa: Allocator, a: Var, b: Var, limit: u32) Error!bool {
    var pairs: std.ArrayList([2]Var) = .empty;
    defer pairs.deinit(gpa);
    try pairs.append(gpa, .{ a, b });
    var budget = limit;
    while (pairs.pop()) |p| {
        if (budget == 0) return true;
        budget -= 1;
        const x = store.find(p[0]);
        const y = store.find(p[1]);
        if (x == y) continue;
        if (!sameHead(store, x, y)) return false;
        var n: u32 = 0;
        while (true) : (n += 1) {
            const cx = child(store, x, n, .structural);
            const cy = child(store, y, n, .structural);
            if (cx == null and cy == null) break;
            if (cx == null or cy == null) return false;
            try pairs.append(gpa, .{ cx.?, cy.? });
        }
    }
    return true;
}

fn sameHead(store: *TypeStore, x: Var, y: Var) bool {
    const cx = store.content(x);
    const cy = store.content(y);
    if (std.meta.activeTag(cx) != std.meta.activeTag(cy)) return false;
    return switch (cx) {
        // Distinct variable roots: two different leaves.
        .flex, .rigid => false,
        .err => true,
        .alias => |l| l.type == cy.alias.type,
        .structure => |l| {
            const r = cy.structure;
            if (std.meta.activeTag(l) != std.meta.activeTag(r)) return false;
            return switch (l) {
                .unit, .empty_record, .func, .tuple => true,
                .app => |la| la.type == r.app.type,
                .record => |lr| {
                    const f = recordFields(store, lr);
                    const g = recordFields(store, r.record);
                    if (f.len != g.len) return false;
                    for (f, g) |p, q| if (p.name != q.name) return false;
                    return true;
                },
            };
        },
    };
}
