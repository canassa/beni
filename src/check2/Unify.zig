//! Unification (checker-v2.md §7): v1's `unifyFlat`, `unifyRecord`,
//! `unifyAlias` and kind lattice with the dispatch arms removed.
//!
//! **`unify` merges and queues. It never resolves and never reports**
//! (§7.1). It returns `ok` or `mismatch(problem)` and the caller reports it
//! with its category, which is Elm's split. What it does besides merging:
//!
//!   - a merge that lowers a rigid's rank, or binds an outer flex to a
//!     younger structure, appends a `Capture` to the module's list (§7.1,
//!     *As built by R4b*), which is where §8.3 reports an escape;
//!   - a record merge leaves the surviving root **normalised** (§4.1): one
//!     node, the union of the fields sorted by symbol, and the chain's end.
//!
//! **Which failing field is reported is chosen by name text** (§7.2, I13,
//! CK-07): every shared field is unified, and among those that failed the
//! one whose name is smallest by text supplies the problem. With one
//! failure, the common case, nothing extra is done.
//!
//! **Depth** (§7.3): the recursion guard is v1's (`Parse.max_depth + 104`),
//! but past it `unify` fails with `too_deep`, which the caller reports as
//! `nesting_too_deep`. It never answers "ok" (CK-10 item 3).
//!
//! In R4b's subset no variable carries a method constraint or an
//! obligation (`Subset.zig`), so Rule U1's join and the ready queue are
//! R6a's to add here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Parse = @import("../parse/Parse.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Generalize = @import("Generalize.zig");
const Walk = @import("Walk.zig");

const Unify = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// Why a unification failed, when the reason is more specific than "these
/// two types differ" (v1's `Solve.Problem`, plus `too_deep`).
pub const Problem = union(enum) {
    kinds: struct { left: TypeStore.Kind, right: TypeStore.Kind },
    kind_not_satisfied: struct { kind: TypeStore.Kind },
    not_equatable_rigid: Var,
    missing_field: Fields,
    unknown_field: Fields,
    record_not_closed: struct { actual: Var, expected: Var },
    /// §7.3: the recursion guard stopped the walk.
    too_deep,
    /// A variable carrying a method constraint met `unify`, which R4b's
    /// subset excludes: `internal`.
    constrained,

    pub const Fields = struct { names: []Symbol, actual: Var, expected: Var };
};

pub const Result = union(enum) {
    ok,
    /// `null` when the two types simply differ.
    mismatch: ?Problem,
};

/// The recursion guard (§7.3): deep enough for anything the parser accepts.
pub const max_depth = Parse.max_depth + 104;

store: *TypeStore,
types: *const Types,
interner: *const InternPool.Global,
gpa: Allocator,
scratch: Allocator,
/// The open frames; the last is current. Fresh variables `unify` makes go
/// in its pool at its rank.
frames: *std.ArrayList(Generalize.Frame),
captures: *std.ArrayList(Generalize.Capture),
region: Bir.Inst.Index = @enumFromInt(0),
problem: ?Problem = null,
/// The pairs of non-variables being unified, outermost first: the
/// coinduction of §7.3.
active: std.ArrayList([2]Var) = .empty,
depth: u32 = 0,
unifications: u64 = 0,

pub fn unify(u: *Unify, a: Var, b: Var, region: Bir.Inst.Index) Error!Result {
    u.problem = null;
    u.region = region;
    u.depth = 0;
    if (try u.go(a, b)) return .ok;
    const problem = u.problem;
    u.problem = null;
    return .{ .mismatch = problem };
}

/// Record the first specific reason: the deepest call that knows is the
/// most specific, and a later sibling failure is its consequence.
fn fail(u: *Unify, problem: Problem) bool {
    if (u.problem == null) u.problem = problem;
    return false;
}

fn frame(u: *Unify) *Generalize.Frame {
    return &u.frames.items[u.frames.items.len - 1];
}

/// A fresh variable at the current frame's rank, in its pool.
fn fresh(u: *Unify, content: TypeStore.Content) Error!Var {
    const f = u.frame();
    const v = try u.store.fresh(content, f.rank);
    try f.pool.append(u.gpa, v);
    return v;
}

/// Bind the flex root `bound` to `other`'s content: the one place a flex
/// stops being a variable.
fn bind(u: *Unify, bound: Var, other: Var, content: TypeStore.Content) Error!void {
    const low = u.store.rank(bound);
    if (low < u.store.rank(other)) {
        try u.captures.append(u.gpa, .{ .v = other, .region = u.region });
    }
    _ = u.store.merge(bound, other, content);
}

fn go(u: *Unify, a: Var, b: Var) Error!bool {
    u.depth += 1;
    defer u.depth -= 1;
    if (u.depth > max_depth) return u.fail(.too_deep);

    const st = u.store;
    const ra = st.find(a);
    const rb = st.find(b);
    if (ra == rb) return true;
    u.unifications += 1;

    const ca = st.content(ra);
    const cb = st.content(rb);
    // Nothing in R4b's subset carries a method constraint (`Subset.zig`):
    // Rule U1's join and the ready queue are R6a's. Meeting one here is
    // the compiler's failure, said as `internal` — never a silent drop
    // (review S1, CK-02's class).
    if (carries(ca) or carries(cb)) return u.fail(.constrained);
    // **Coinduction** (§7.3, *As built by R4b's review*). Only two
    // non-variables recurse, and only they can meet again on a cycle: a pair
    // already being unified further up is assumed equal, so a cyclic graph —
    // or two isomorphic ones — terminates, and a finite type is unchanged
    // (in a finite graph no pair is its own descendant). Children are still
    // unified before the merge, so a message still prints two types.
    if (!isVariable(ca) and !isVariable(cb)) {
        for (u.active.items) |pair| {
            const x = st.find(pair[0]);
            const y = st.find(pair[1]);
            if ((x == ra and y == rb) or (x == rb and y == ra)) return true;
        }
        try u.active.append(u.gpa, .{ ra, rb });
        defer _ = u.active.pop();
        return switch (ca) {
            .alias => |aa| u.alias(ra, aa, rb, cb),
            .structure => |sa| u.structure(ra, sa, rb, cb),
            else => unreachable,
        };
    }
    return switch (ca) {
        .err => {
            _ = st.merge(ra, rb, .err);
            return true;
        },
        .flex => |fa| u.flex(ra, fa, rb, cb),
        .rigid => |fa| u.rigid(ra, fa, rb, cb),
        .alias => |aa| u.alias(ra, aa, rb, cb),
        .structure => |sa| u.structure(ra, sa, rb, cb),
    };
}

fn flex(u: *Unify, ra: Var, fa: TypeStore.Flags, rb: Var, cb: TypeStore.Content) Error!bool {
    const st = u.store;
    switch (cb) {
        .err => {
            _ = st.merge(ra, rb, .err);
            return true;
        },
        .flex => |fb| {
            const kind = TypeStore.Kind.meet(fa.kind, fb.kind) orelse
                return u.fail(.{ .kinds = .{ .left = fa.kind, .right = fb.kind } });
            _ = st.merge(ra, rb, .{
                .flex = .{
                    .name = if (fb.name != .none) fb.name else fa.name,
                    .kind = kind,
                    .equatable = fa.equatable or fb.equatable,
                    // Neither side carries one: `go` refused that.
                    .constraints = .none,
                },
            });
            return true;
        },
        .rigid => |fb| {
            // A rigid is a promise about ALL types: a `number` flex meeting a
            // rigid `a` wants more than the annotation said.
            if (fa.kind != .any and fa.kind != fb.kind) return false;
            if (fa.equatable and !fb.equatable) return u.fail(.{ .not_equatable_rigid = rb });
            try u.bind(ra, rb, cb);
            return true;
        },
        .alias, .structure => {
            if (fa.kind != .any and !u.kindAccepts(fa.kind, rb)) {
                return u.fail(.{ .kind_not_satisfied = .{ .kind = fa.kind } });
            }
            try u.bind(ra, rb, cb);
            return true;
        },
    }
}

/// v1's flat membership test for `number` and `appendable`.
fn kindAccepts(u: *Unify, kind: TypeStore.Kind, v: Var) bool {
    const wk = u.types.well_known;
    const app = switch (u.store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .app => |a| a,
            else => return false,
        },
        .err => return true,
        else => return false,
    };
    return switch (kind) {
        .any => true,
        .number => app.args.len == 0 and (app.type == wk.int or app.type == wk.float),
        .appendable => (app.args.len == 0 and app.type == wk.string) or
            (app.args.len == 1 and app.type == wk.list),
    };
}

fn rigid(u: *Unify, ra: Var, fa: TypeStore.Flags, rb: Var, cb: TypeStore.Content) Error!bool {
    const st = u.store;
    switch (cb) {
        .err => {
            _ = st.merge(ra, rb, .err);
            return true;
        },
        .flex => |fb| {
            if (fb.kind != .any and fb.kind != fa.kind) return false;
            if (fb.equatable and !fa.equatable) return u.fail(.{ .not_equatable_rigid = ra });
            try u.bind(rb, ra, .{ .rigid = fa });
            return true;
        },
        // Two rigids, or a rigid against a real type: the annotation
        // promised more than the code delivers.
        .rigid, .structure, .alias => return false,
    }
}

fn alias(u: *Unify, ra: Var, aa: TypeStore.Alias, rb: Var, cb: TypeStore.Content) Error!bool {
    const st = u.store;
    switch (cb) {
        .err => {
            _ = st.merge(ra, rb, .err);
            return true;
        },
        // The flex side absorbs the alias, name and all.
        .flex => |fb| {
            if (fb.kind != .any and !u.kindAccepts(fb.kind, ra)) {
                return u.fail(.{ .kind_not_satisfied = .{ .kind = fb.kind } });
            }
            try u.bind(rb, ra, .{ .alias = aa });
            return true;
        },
        .rigid => return u.go(aa.actual, rb),
        .alias => |ab| {
            if (aa.type != ab.type or aa.args.len != ab.args.len) return u.go(aa.actual, ab.actual);
            if (!try u.pairs(aa.args, ab.args)) return false;
            _ = st.merge(st.find(ra), st.find(rb), .{ .alias = ab });
            return true;
        },
        .structure => return u.go(aa.actual, rb),
    }
}

/// Unify two argument lists elementwise, re-slicing the range each time:
/// unifying appends to `extra` and would dangle a view taken once.
fn pairs(u: *Unify, left: TypeStore.Range, right: TypeStore.Range) Error!bool {
    const n = @min(left.len, right.len);
    for (0..n) |i| {
        if (!try u.go(u.store.vars(left)[i], u.store.vars(right)[i])) return false;
    }
    return true;
}

fn structure(u: *Unify, ra: Var, sa: TypeStore.Structure, rb: Var, cb: TypeStore.Content) Error!bool {
    const st = u.store;
    switch (cb) {
        .err => {
            _ = st.merge(ra, rb, .err);
            return true;
        },
        .flex => |fb| {
            if (fb.kind != .any and !u.kindAccepts(fb.kind, ra)) {
                return u.fail(.{ .kind_not_satisfied = .{ .kind = fb.kind } });
            }
            try u.bind(rb, ra, .{ .structure = sa });
            return true;
        },
        .rigid => return false,
        .alias => |ab| return u.go(ra, ab.actual),
        .structure => |sb| return u.flat(ra, sa, rb, sb),
    }
}

fn flat(u: *Unify, ra: Var, sa: TypeStore.Structure, rb: Var, sb: TypeStore.Structure) Error!bool {
    const st = u.store;
    switch (sa) {
        .unit => {
            if (sb != .unit) return false;
            _ = st.merge(ra, rb, .{ .structure = .unit });
            return true;
        },
        .empty_record => {
            if (sb != .empty_record) return false;
            _ = st.merge(ra, rb, .{ .structure = .empty_record });
            return true;
        },
        // Children FIRST, merge only on success (Elm's order): merging up
        // front would print the same type twice in the message.
        .func => |fa| {
            const fb = switch (sb) {
                .func => |f| f,
                else => return false,
            };
            if (fa.params.len != fb.params.len) return false;
            if (!try u.pairs(fa.params, fb.params)) return false;
            if (!try u.go(fa.result, fb.result)) return false;
            _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .func = fa } });
            return true;
        },
        .app => |aa| {
            const ab = switch (sb) {
                .app => |a| a,
                else => return false,
            };
            if (aa.type != ab.type or aa.args.len != ab.args.len) return false;
            if (!try u.pairs(aa.args, ab.args)) return false;
            _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .app = aa } });
            return true;
        },
        .tuple => |ta| {
            const tb = switch (sb) {
                .tuple => |t| t,
                else => return false,
            };
            if (ta.len != tb.len) return false;
            if (!try u.pairs(ta, tb)) return false;
            _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .tuple = ta } });
            return true;
        },
        .record => |rec_a| {
            const rec_b = switch (sb) {
                .record => |r| r,
                else => return false,
            };
            return u.record(ra, rec_a, rb, rec_b);
        },
    }
}

// ---------------------------------------------------------------------------
// Records: Elm's four-way field partition as one merge-join
// ---------------------------------------------------------------------------

const Gathered = struct {
    fields: std.ArrayList(TypeStore.Field),
    end: Walk.RowEnd,
    concatenated: bool,
};

fn gather(u: *Unify, rec: TypeStore.Structure.Record) Error!Gathered {
    var out: Gathered = .{ .fields = .empty, .end = undefined, .concatenated = false };
    out.end = try Walk.recordRow(u.store, rec, &out.fields, u.scratch, &out.concatenated);
    // A chain is two sorted runs concatenated; the merge-join needs one.
    if (out.concatenated) std.mem.sort(TypeStore.Field, out.fields.items, {}, symbolLessThan);
    return out;
}

fn symbolLessThan(_: void, a: TypeStore.Field, b: TypeStore.Field) bool {
    return @intFromEnum(a.name) < @intFromEnum(b.name);
}

fn endVar(end: Walk.RowEnd) Var {
    return switch (end) {
        .closed, .open => |v| v,
    };
}

/// One failed shared field, for the text-order choice of §7.2.
const Failure = struct { name: Symbol, problem: ?Problem };

fn record(u: *Unify, ra: Var, rec_a: TypeStore.Structure.Record, rb: Var, rec_b: TypeStore.Structure.Record) Error!bool {
    const st = u.store;
    var a = try u.gather(rec_a);
    defer a.fields.deinit(u.scratch);
    var b = try u.gather(rec_b);
    defer b.fields.deinit(u.scratch);
    const a_ext = endVar(a.end);
    const b_ext = endVar(b.end);
    const a_closed = a.end == .closed;
    const b_closed = b.end == .closed;

    var only_a: std.ArrayList(TypeStore.Field) = .empty;
    defer only_a.deinit(u.scratch);
    var only_b: std.ArrayList(TypeStore.Field) = .empty;
    defer only_b.deinit(u.scratch);
    var shared: std.ArrayList(Shared) = .empty;
    defer shared.deinit(u.scratch);

    var i: usize = 0;
    var j: usize = 0;
    while (i < a.fields.items.len and j < b.fields.items.len) {
        const fa = a.fields.items[i];
        const fb = b.fields.items[j];
        const na = @intFromEnum(fa.name);
        const nb = @intFromEnum(fb.name);
        if (na < nb) {
            try only_a.append(u.scratch, fa);
            i += 1;
        } else if (na > nb) {
            try only_b.append(u.scratch, fb);
            j += 1;
        } else {
            try shared.append(u.scratch, .{ .name = fa.name, .a = fa.value, .b = fb.value });
            i += 1;
            j += 1;
        }
    }
    try only_a.appendSlice(u.scratch, a.fields.items[i..]);
    try only_b.appendSlice(u.scratch, b.fields.items[j..]);

    // A field one side requires and the other cannot grow.
    if (only_a.items.len != 0 and !isOpenVar(st, b_ext)) {
        return u.fail(.{ .missing_field = .{ .names = try u.fieldNames(only_a.items), .actual = rb, .expected = ra } });
    }
    if (only_b.items.len != 0 and !isOpenVar(st, a_ext)) {
        return u.fail(.{ .unknown_field = .{ .names = try u.fieldNames(only_b.items), .actual = rb, .expected = ra } });
    }
    // Both can grow, but one promised to stay open: an annotation's
    // `{ r | … }` cannot become a specific record.
    if (isRigidVar(st, a_ext) != isRigidVar(st, b_ext) and (a_closed or b_closed)) {
        return u.fail(.{ .record_not_closed = .{ .actual = rb, .expected = ra } });
    }

    var ok = true;
    // Where the merged record's chain ends, for the normalised merge.
    var end: Var = a_ext;
    if (only_a.items.len == 0 and only_b.items.len == 0) {
        ok = try u.go(a_ext, b_ext) and ok;
    } else if (only_a.items.len == 0) {
        const sub = try u.freshRecord(only_b.items, b_ext);
        ok = try u.go(a_ext, sub) and ok;
        end = b_ext;
    } else if (only_b.items.len == 0) {
        const sub = try u.freshRecord(only_a.items, a_ext);
        ok = try u.go(sub, b_ext) and ok;
    } else {
        const ext = try u.fresh(.{ .flex = .{} });
        const sub_a = try u.freshRecord(only_a.items, ext);
        const sub_b = try u.freshRecord(only_b.items, ext);
        ok = try u.go(a_ext, sub_b) and ok;
        ok = try u.go(sub_a, b_ext) and ok;
        end = ext;
    }
    // A problem the extensions produced is v1's first and stays first.
    const kept = u.problem;
    var failures: std.ArrayList(Failure) = .empty;
    defer failures.deinit(u.scratch);
    // Past the depth guard no further field is tried: each would walk to the
    // guard again (review B1).
    const stopped = if (kept) |k| k == .too_deep else false;
    if (!stopped) for (shared.items) |pair| {
        u.problem = null;
        if (!try u.go(pair.a, pair.b)) {
            ok = false;
            if (u.problem) |p| if (p == .too_deep) return false;
            try failures.append(u.scratch, .{ .name = pair.name, .problem = u.problem });
        }
    };
    u.problem = kept;
    if (kept == null and failures.items.len != 0) {
        var best = failures.items[0];
        for (failures.items[1..]) |f| {
            if (std.mem.lessThan(u8, u.interner.slice(f.name), u.interner.slice(best.name))) best = f;
        }
        u.problem = best.problem;
    }
    if (!ok) return false;

    // Normalised on merge (§4.1): the survivor is ONE record, every field
    // and the chain's end. When `a` was already that — no chain, nothing
    // added — its own content is reused and nothing is allocated.
    const merged: TypeStore.Structure.Record = if (!a.concatenated and only_b.items.len == 0)
        rec_a
    else blk: {
        const all = try u.scratch.alloc(TypeStore.Field, a.fields.items.len + only_b.items.len);
        defer u.scratch.free(all);
        @memcpy(all[0..a.fields.items.len], a.fields.items);
        @memcpy(all[a.fields.items.len..], only_b.items);
        break :blk .{ .fields = try st.addFields(all), .ext = end };
    };
    _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .record = merged } });
    return true;
}

const Shared = struct { name: Symbol, a: Var, b: Var };

fn freshRecord(u: *Unify, fields: []const TypeStore.Field, ext: Var) Error!Var {
    const copied = try u.scratch.dupe(TypeStore.Field, fields);
    defer u.scratch.free(copied);
    const range = try u.store.addFields(copied);
    return u.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
}

fn fieldNames(u: *Unify, fields: []const TypeStore.Field) Error![]Symbol {
    const out = try u.scratch.alloc(Symbol, fields.len);
    for (fields, out) |f, *n| n.* = f.name;
    return out;
}

fn isRigidVar(st: *TypeStore, v: Var) bool {
    return st.content(st.find(v)) == .rigid;
}

fn isOpenVar(st: *TypeStore, v: Var) bool {
    return switch (st.content(st.find(v))) {
        .flex, .rigid, .err => true,
        else => false,
    };
}

/// Whether a variable's content carries a method constraint (`Walk`'s one
/// reading of them).
fn carries(c: TypeStore.Content) bool {
    return switch (c) {
        .flex, .rigid => |flags| !Walk.constraints(flags).isEmpty(),
        else => false,
    };
}

fn isVariable(c: TypeStore.Content) bool {
    return switch (c) {
        .flex, .rigid, .err => true,
        .alias, .structure => false,
    };
}

pub fn deinit(u: *Unify) void {
    u.active.deinit(u.gpa);
}
