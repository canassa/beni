//! The solver (docs/design/checker.md §6.2–§6.5): one walk over the
//! constraint tree, doing every unification, every generalisation and every
//! obligation.
//!
//! This is Elm's `Type/Solve.hs` on beni's store. The five techniques of
//! `fast-compiler.md` §7 all live here:
//!
//!   1. **Union-find, mutation in place.** `unify` merges descriptors; there
//!      is no substitution to apply anywhere.
//!   2. **Rémy levels.** `let_` bumps the rank, solves the header at the
//!      deeper one, and generalises by scanning only the POOL of variables
//!      allocated at that rank — never the environment (research/02 §2.2).
//!      `adjustRank` is Elm's, comment for comment: ranks never increase as
//!      you go deeper, so the outermost rank is representative of the whole
//!      structure, and two marks memoise the walk.
//!   3. **The occurs check is deferred.** It is not on the unification path
//!      at all: it runs once per generalised binding, after that region has
//!      stabilised, and reports `infinite_type` at the binding.
//!   4. **Sharing-preserving instantiation.** `makeCopy` memoises through
//!      the descriptor's `copy` field, so `let x = (y, y)` copies `y` once
//!      and not twice; the memo is cleared through a scratch list rather
//!      than a second walk.
//!   5. **SCC binding groups** are the generator's; the solver sees one
//!      `let` per group.
//!
//! **Errors never stop the build.** A failed unification records ONE
//! diagnostic and merges both roots into `err`; every later unification
//! touching them succeeds silently. That is Elm's cascade suppression and
//! the reason one mistake yields one message (research/02 §6).
//!
//! **The arity rule of §8.3 is in `call`.** A `call` node is not an ordinary
//! equality. Every call is saturated (`language.md` §6.7), so the question
//! is one comparison and not a peeling loop: the callee's type carries its
//! parameter count, and a call that does not supply exactly that many is
//! `too_few_args` (naming the function, its arity and the types of the
//! missing arguments), `too_many_args`, or — when the callee is not a
//! function at all — `not_a_function`. All three fire BEFORE the generic
//! `type_mismatch` and suppress it, and they are the one family with a
//! fixture suite of its own (`tests/corpus/check/args`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Parse = @import("../parse/Parse.zig");
const Interface = @import("../resolve/Interface.zig");
const Schemes = @import("Schemes.zig");
const Constrain = @import("Constrain.zig");
const Diagnostics = @import("Diagnostics.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

const Solve = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
const Constraint = Constrain.Constraint;
const Category = Constrain.Category;

/// What `--self-profile` reports, and what M4's incrementality tests will
/// assert did NOT move when only a body changed (checker.md §9).
pub const Counters = struct {
    unifications: u64 = 0,
    generalisations: u64 = 0,
    instantiations: u64 = 0,
    obligations: u64 = 0,
};

/// An ad-hoc constraint that cannot be answered until the type is concrete
/// (checker.md §6.4). Kept per rank and discharged when that rank is done.
pub const Obligation = struct {
    kind: Kind,
    v: Var,
    region: Bir.Inst.Index,
    /// `tuple_index`: the index. Unused otherwise.
    index: u32 = 0,
    /// `tuple_index`: the variable the element must equal.
    result: Var.Optional = .none,

    pub const Kind = enum { equatable, interpolatable, tuple_index };
};

pub const Error = Allocator.Error;

/// Why a unification failed, when the reason is more specific than "these
/// two types differ". Set by the deepest `unifyQuiet` that knows, read by
/// the `unify` that owns the region — which is how a message can say
/// `kind_mismatch` and point at the expression the author wrote, rather
/// than at whatever sub-term the recursion happened to be in.
pub const Problem = union(enum) {
    /// `number` met `appendable`: `number ⊓ appendable = ⊥` (§6.2).
    kinds: struct { left: TypeStore.Kind, right: TypeStore.Kind },
    /// A `number` or `appendable` variable met a type that is not in its
    /// set — `appendable` against `Int`, say. Only the KIND is carried: the
    /// two types are the ones the owning `unify` already has, and printing
    /// the sub-term the recursion stopped on instead would name something
    /// the author did not write.
    kind_not_satisfied: struct { kind: TypeStore.Kind },
    /// `==` was demanded of an annotation's type variable that is not
    /// declared `equatable` (checker.md Appendix B).
    not_equatable_rigid: Var,
    missing_field: Fields,
    unknown_field: Fields,
    record_not_closed: struct { actual: Var, expected: Var },

    pub const Fields = struct { names: []Symbol, actual: Var, expected: Var };
};

pub const Solver = struct {
    gpa: Allocator,
    env: *Constrain.Env,
    tree: *const Constrain.Tree,
    reporter: *Diagnostics.Reporter,
    /// `pools[rank]` is every variable allocated at `rank` that this region
    /// still owns. Cleared as each rank is generalised.
    pools: std.ArrayList(std.ArrayList(Var)) = .empty,
    obligations: std.ArrayList(std.ArrayList(Obligation)) = .empty,
    rank: u32 = 0,
    counters: Counters = .{},
    /// Variables whose `copy` memo one instantiation set, cleared after it.
    touched: std.ArrayList(Var) = .empty,
    depth: u32 = 0,
    /// Set by a sub-unification that knows more than "they differ"; read
    /// and cleared by the `unify` that owns the region.
    problem: ?Problem = null,
    /// Where the unification being performed came from. An `equatable`
    /// obligation can be registered from deep inside `unifyQuiet` — a flex
    /// variable marked equatable meeting a structure (§6.2) — and it has to
    /// point at the expression the author wrote, not at wherever the
    /// recursion happened to be.
    region: Bir.Inst.Index = @enumFromInt(0),
    /// The call whose arguments already produced a message. A call's
    /// arguments are constrained consecutively, so one slot is enough, and
    /// suppressing the rest is the same reasoning as the left-to-right
    /// hint: after one argument is wrong, every later parameter type was
    /// computed from a type the author did not mean.
    last_bad_call: Bir.Inst.OptionalIndex = .none,

    /// The occurs check's stack, reused across every generalised binding of
    /// the group; see `occurs`.
    occurs_frames: OccursFrames = .empty,

    /// Deep enough for anything the parser accepts, and shallow enough not
    /// to overflow a worker's 64 MiB stack (`Check.stack_size`).
    ///
    /// **Silence at this guard is correct, and only because of the `+`.**
    /// The parser bounds a whole declaration at `Parse.max_depth` levels
    /// (language.md §10, and `Parse.depth`'s comment explains why the
    /// charge is held for the declaration and not the subtree), and every
    /// walk guarded by this number spends at most one frame per level of
    /// that tree — so a file the front end accepted cannot reach it, and a
    /// file that could was reported as `nesting_too_deep` before the
    /// checker saw it. Derived from the parser's number rather than written
    /// as a constant, so the argument cannot rot when either moves.
    ///
    /// The guards that DO poison a type reachable from an accepted file are
    /// `Types.Builder.max_depth` and `Schemes.Writer.max_depth`, and both
    /// report.
    const max_depth = Parse.max_depth + 104;

    pub fn init(gpa: Allocator, env: *Constrain.Env, tree: *const Constrain.Tree, reporter: *Diagnostics.Reporter) Solver {
        return .{ .gpa = gpa, .env = env, .tree = tree, .reporter = reporter };
    }

    pub fn deinit(s: *Solver) void {
        s.occurs_frames.deinit(s.gpa);
        for (s.pools.items) |*p| p.deinit(s.gpa);
        s.pools.deinit(s.gpa);
        for (s.obligations.items) |*o| o.deinit(s.gpa);
        s.obligations.deinit(s.gpa);
        s.touched.deinit(s.gpa);
    }

    fn store(s: *const Solver) *TypeStore {
        return s.env.store;
    }

    fn pool(s: *Solver, rank: u32) Error!*std.ArrayList(Var) {
        while (s.pools.items.len <= rank) try s.pools.append(s.gpa, .empty);
        return &s.pools.items[rank];
    }

    fn obligationsAt(s: *Solver, rank: u32) Error!*std.ArrayList(Obligation) {
        while (s.obligations.items.len <= rank) try s.obligations.append(s.gpa, .empty);
        return &s.obligations.items[rank];
    }

    /// A fresh variable at the current rank, in the current pool.
    fn fresh(s: *Solver, content: TypeStore.Content) Error!Var {
        const v = try s.store().fresh(content, s.rank);
        try (try s.pool(s.rank)).append(s.gpa, v);
        return v;
    }

    /// Everything the store gained since `mark`, recorded in the pool of
    /// the current rank. Used where a helper builds types without going
    /// through `fresh` — the store's descriptor column is append-only, so
    /// "what is new" is a range and needs no bookkeeping of its own.
    fn adoptSince(s: *Solver, mark: u32) Error!void {
        const p = try s.pool(s.rank);
        var i = mark;
        while (i < s.store().count()) : (i += 1) {
            const v: Var = @enumFromInt(i);
            if (s.store().rank(v) == s.rank) try p.append(s.gpa, v);
        }
    }

    // ---- The walk --------------------------------------------------------

    pub fn solve(s: *Solver, c: Constraint) Error!void {
        if (c == .none) return;
        s.depth += 1;
        defer s.depth -= 1;
        // Unreachable from an accepted file — see `max_depth`. Silence is
        // the right answer here because the input that could get past the
        // parser's own bound has a diagnostic already.
        if (s.depth > max_depth) return;

        const node = s.tree.node(c);
        switch (node.tag) {
            .true_ => {},
            .and_ => for (s.tree.constraints(node.a, node.b)) |child| try s.solve(child),
            .equal => try s.unify(@enumFromInt(node.a), @enumFromInt(node.b), node.region, node.category),
            .let_ => try s.let_(node),
            .call => try s.call(node),
            .instantiate => try s.instantiate(node),
            .equatable => try s.register(.{ .kind = .equatable, .v = @enumFromInt(node.a), .region = node.region }),
            .interpolatable => try s.register(.{ .kind = .interpolatable, .v = @enumFromInt(node.a), .region = node.region }),
            .tuple_index => {
                const payload = s.tree.extraData(node.b, Constrain.TupleIndex);
                try s.register(.{
                    .kind = .tuple_index,
                    .v = @enumFromInt(node.a),
                    .region = node.region,
                    .index = payload.index,
                    .result = payload.result.toOptional(),
                });
            },
            .try_ => try s.tryShape(node),
        }
    }

    fn register(s: *Solver, o: Obligation) Error!void {
        try (try s.obligationsAt(s.rank)).append(s.gpa, o);
    }

    /// `CLet`: a new rank for the header, generalisation on the way out,
    /// then the body at the original rank.
    fn let_(s: *Solver, node: Constrain.Node) Error!void {
        const info = s.tree.extraData(node.a, Constrain.Let);
        const outer = s.rank;
        s.rank = info.rank;
        {
            const p = try s.pool(info.rank);
            p.clearRetainingCapacity();
            try p.appendSlice(s.gpa, s.tree.vars(info.vars_start, info.vars_len));
        }
        try s.solve(info.header_con);
        // Obligations first: `tuple_index` can still BIND, and binding
        // after generalisation would write into a scheme (checker.md §6.4).
        try s.dischargeObligations(info.rank);
        try s.generalize(info.rank);
        // The deferred occurs check, once per generalised binding — not
        // inside unification (design §7 #3).
        for (s.tree.headers(info.header_start, info.header_len)) |h| {
            if (try occurs(&s.occurs_frames, s.gpa, s.store(), h.v)) {
                s.store().setContent(s.store().find(h.v), .err);
                try s.reporter.infiniteType(h.region, h.name);
            }
        }
        s.rank = outer;
        try s.solve(info.body_con);
    }

    // ---- Unification -----------------------------------------------------

    pub fn unify(s: *Solver, expected: Var, actual: Var, region: Bir.Inst.Index, category: Category) Error!void {
        s.problem = null;
        const outer_region = s.region;
        defer s.region = outer_region;
        s.region = region;
        const ok = try s.unifyQuiet(expected, actual);
        if (ok) return;
        const owner = if (category.tag == .call_arg) category.owner else .none;
        if (owner != .none and owner == s.last_bad_call) {
            // A second bad argument to the SAME call: poison and stay quiet.
            s.poison(expected);
            s.poison(actual);
            return;
        }
        s.last_bad_call = owner;
        try s.reportFailure(region, category, expected, actual);
        s.poison(expected);
        s.poison(actual);
    }

    /// Record the first specific reason a unification failed. The FIRST
    /// wins: the deepest call that knows is the most specific, and a later
    /// sibling failure is a consequence of it.
    fn fail(s: *Solver, problem: Problem) bool {
        if (s.problem == null) s.problem = problem;
        return false;
    }

    fn reportFailure(s: *Solver, region: Bir.Inst.Index, category: Category, expected: Var, actual: Var) Error!void {
        const problem = s.problem orelse {
            return s.reporter.mismatch(region, category, expected, actual, s.rigidOf(expected, actual));
        };
        s.problem = null;
        switch (problem) {
            .kinds => |k| try s.reporter.kindMismatch(region, k.left, k.right),
            .kind_not_satisfied => |k| try s.reporter.kindNotSatisfied(region, category, k.kind, expected, actual),
            .not_equatable_rigid => |v| try s.reporter.notEquatable(region, v, .rigid_variable),
            .missing_field => |f| try s.reporter.missingField(region, f.names, f.actual, f.expected),
            .unknown_field => |f| try s.reporter.unknownField(region, f.names, f.actual, f.expected),
            .record_not_closed => |f| try s.reporter.recordNotClosed(region, f.actual, f.expected),
        }
    }

    /// Which side was an annotation's promise, for `rigid_mismatch`.
    fn rigidOf(s: *Solver, expected: Var, actual: Var) ?Diagnostics.Reporter.Rigid {
        const st = s.store();
        if (st.content(st.find(expected)) == .rigid) return .{ .v = expected, .against = actual };
        if (st.content(st.find(actual)) == .rigid) return .{ .v = actual, .against = expected };
        return null;
    }

    /// Poison a variable so nothing downstream reports again.
    fn poison(s: *Solver, v: Var) void {
        s.store().setContent(s.store().find(v), .err);
    }

    /// Unify without reporting; `false` means the caller owns the message.
    /// Sub-unifications report on their own, which is how a record field
    /// mismatch points at the field and not at the whole record.
    pub fn unifyQuiet(s: *Solver, a: Var, b: Var) Error!bool {
        s.depth += 1;
        defer s.depth -= 1;
        // See `max_depth`: unreachable from a file the parser accepted.
        // "True" rather than "false" so a guard that somehow trips cannot
        // invent a mismatch out of its own exhaustion.
        if (s.depth > max_depth) return true;

        const st = s.store();
        const ra = st.find(a);
        const rb = st.find(b);
        if (ra == rb) return true;
        s.counters.unifications += 1;

        const ca = st.content(ra);
        const cb = st.content(rb);
        return switch (ca) {
            .err => {
                _ = st.merge(ra, rb, .err);
                return true;
            },
            .flex => |fa| s.unifyFlex(ra, fa, rb, cb),
            .rigid => |fa| s.unifyRigid(ra, fa, rb, cb),
            .alias => |aa| s.unifyAlias(ra, aa, rb, cb),
            .structure => |sa| s.unifyStructure(ra, sa, rb, cb),
        };
    }

    fn unifyFlex(s: *Solver, ra: Var, fa: TypeStore.Flags, rb: Var, cb: TypeStore.Content) Error!bool {
        const st = s.store();
        switch (cb) {
            .err => {
                _ = st.merge(ra, rb, .err);
                return true;
            },
            .flex => |fb| {
                const kind = TypeStore.Kind.meet(fa.kind, fb.kind) orelse
                    return s.fail(.{ .kinds = .{ .left = fa.kind, .right = fb.kind } });
                _ = st.merge(ra, rb, .{ .flex = .{
                    .name = if (fb.name != .none) fb.name else fa.name,
                    .kind = kind,
                    .equatable = fa.equatable or fb.equatable,
                } });
                return true;
            },
            .rigid => |fb| {
                // A rigid variable is a promise about ALL types, so it
                // cannot be narrowed: a flex `number` meeting a rigid `a`
                // means the code wants more than the annotation said.
                if (fa.kind != .any and fa.kind != fb.kind) return false;
                if (fa.equatable and !fb.equatable) return s.fail(.{ .not_equatable_rigid = rb });
                _ = st.merge(ra, rb, cb);
                return true;
            },
            .alias, .structure => {
                if (fa.kind != .any and !s.kindAccepts(fa.kind, rb)) {
                    return s.fail(.{ .kind_not_satisfied = .{ .kind = fa.kind } });
                }
                if (fa.equatable) try s.register(.{ .kind = .equatable, .v = rb, .region = s.region });
                _ = st.merge(ra, rb, cb);
                return true;
            },
        }
    }

    /// Whether a `number` or `appendable` variable may become `v`. This is
    /// the flat membership test of `fast-compiler.md` §3.1: no recursion, no
    /// occurs check, which is exactly what dropping `comparable` bought.
    fn kindAccepts(s: *Solver, kind: TypeStore.Kind, v: Var) bool {
        const wk = s.env.types.well_known;
        const c = s.store().resolvedContent(v);
        const app = switch (c) {
            .structure => |st| switch (st) {
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

    fn unifyRigid(s: *Solver, ra: Var, fa: TypeStore.Flags, rb: Var, cb: TypeStore.Content) Error!bool {
        const st = s.store();
        switch (cb) {
            .err => {
                _ = st.merge(ra, rb, .err);
                return true;
            },
            .flex => |fb| {
                if (fb.kind != .any and fb.kind != fa.kind) return false;
                if (fb.equatable and !fa.equatable) return s.fail(.{ .not_equatable_rigid = ra });
                _ = st.merge(ra, rb, .{ .rigid = fa });
                return true;
            },
            // Two different rigids, or a rigid against a real type: the
            // annotation promised more than the code delivers.
            .rigid, .structure, .alias => return false,
        }
    }

    fn unifyAlias(s: *Solver, ra: Var, aa: TypeStore.Alias, rb: Var, cb: TypeStore.Content) Error!bool {
        const st = s.store();
        switch (cb) {
            .err => {
                _ = st.merge(ra, rb, .err);
                return true;
            },
            // The flex side absorbs the alias, name and all, so a later
            // diagnostic still says `Model` and not the record behind it.
            .flex => |fb| {
                if (fb.kind != .any and !s.kindAccepts(fb.kind, rb)) {
                    return s.fail(.{ .kind_not_satisfied = .{ .kind = fb.kind } });
                }
                if (fb.equatable) try s.register(.{ .kind = .equatable, .v = ra, .region = s.region });
                _ = st.merge(ra, rb, .{ .alias = aa });
                return true;
            },
            .rigid => return s.unifyQuiet(aa.actual, rb),
            .alias => |ab| {
                if (aa.type != ab.type or aa.args.len != ab.args.len) {
                    return s.unifyQuiet(aa.actual, ab.actual);
                }
                if (!try s.unifyPairs(aa.args, ab.args)) return false;
                _ = st.merge(st.find(ra), st.find(rb), .{ .alias = ab });
                return true;
            },
            .structure => return s.unifyQuiet(aa.actual, rb),
        }
    }

    /// `store.vars` hands back a view into `extra`, which grows while
    /// unifying; the copy is what keeps that view valid.
    fn copyVars(s: *Solver, items: []const Var) Error![]Var {
        return s.env.scratch.dupe(Var, items);
    }

    /// Unify two argument lists elementwise.
    ///
    /// Takes RANGES, not views. `store.vars` hands back a slice of `extra`,
    /// and unifying appends to `extra` — so a view taken once would dangle
    /// the moment the first element unified. Copying both lists out was the
    /// obvious fix and was two scratch allocations per `app`/`tuple`
    /// unification on the hot path, which §5's "no per-node allocation"
    /// rules out; re-slicing the range each iteration costs an add and
    /// cannot go stale.
    fn unifyPairs(s: *Solver, left: TypeStore.Range, right: TypeStore.Range) Error!bool {
        const n = @min(left.len, right.len);
        for (0..n) |i| {
            const x = s.store().vars(left)[i];
            const y = s.store().vars(right)[i];
            if (!try s.unifyQuiet(x, y)) return false;
        }
        return true;
    }

    fn unifyStructure(s: *Solver, ra: Var, sa: TypeStore.Structure, rb: Var, cb: TypeStore.Content) Error!bool {
        const st = s.store();
        switch (cb) {
            .err => {
                _ = st.merge(ra, rb, .err);
                return true;
            },
            .flex => |fb| {
                if (fb.kind != .any and !s.kindAccepts(fb.kind, ra)) {
                    return s.fail(.{ .kind_not_satisfied = .{ .kind = fb.kind } });
                }
                if (fb.equatable) try s.register(.{ .kind = .equatable, .v = ra, .region = s.region });
                _ = st.merge(ra, rb, .{ .structure = sa });
                return true;
            },
            .rigid => return false,
            .alias => |ab| return s.unifyQuiet(ra, ab.actual),
            .structure => |sb| return s.unifyFlat(ra, sa, rb, sb),
        }
    }

    fn unifyFlat(s: *Solver, ra: Var, sa: TypeStore.Structure, rb: Var, sb: TypeStore.Structure) Error!bool {
        const st = s.store();
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
            // Children FIRST, merge only on success — Elm's order, and it
            // is what makes a diagnostic readable: merging up front would
            // make the two roots one node, and the message would then print
            // the same type twice ("expected `Float -> Float`, got `Float ->
            // Float`"). The depth guard in `unifyQuiet` is what a cyclic
            // structure meets instead of an early merge.
            // **Arity is part of the head** (checker.md §6.2): a function
            // type carries its parameter count, so two of different arity
            // fail here exactly as `Maybe a` and `Result x a` do, and the
            // author is told where the mistake is written rather than two
            // arguments later.
            .func => |fa| {
                const fb = switch (sb) {
                    .func => |f| f,
                    else => return false,
                };
                if (fa.params.len != fb.params.len) return false;
                if (!try s.unifyPairs(fa.params, fb.params)) return false;
                if (!try s.unifyQuiet(fa.result, fb.result)) return false;
                _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .func = fa } });
                return true;
            },
            .app => |aa| {
                const ab = switch (sb) {
                    .app => |a| a,
                    else => return false,
                };
                if (aa.type != ab.type or aa.args.len != ab.args.len) return false;
                if (!try s.unifyPairs(aa.args, ab.args)) return false;
                _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .app = aa } });
                return true;
            },
            .tuple => |ta| {
                const tb = switch (sb) {
                    .tuple => |t| t,
                    else => return false,
                };
                if (ta.len != tb.len) return false;
                if (!try s.unifyPairs(ta, tb)) return false;
                _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .tuple = ta } });
                return true;
            },
            .record => |rec_a| {
                const rec_b = switch (sb) {
                    .record => |r| r,
                    else => return false,
                };
                return s.unifyRecord(ra, rec_a, rb, rec_b);
            },
        }
    }

    // ---- Records: Elm's four-way field partition -------------------------

    const Gathered = struct {
        fields: std.ArrayList(TypeStore.Field),
        /// Whatever the chain ended at: an `empty_record` structure for a
        /// closed record, a variable for an open one.
        ext: Var,
        closed: bool,
    };

    /// Flatten a record's extension chain into one field list, sorted by
    /// symbol id.
    ///
    /// The SORT is what makes `unifyRecord` a merge-join, which is what the
    /// `TypeStore` header promises: the store keeps each record's own
    /// fields sorted, but flattening `{ a | … }` where the extension is
    /// another record concatenates two sorted runs, and a concatenation of
    /// sorted runs is not sorted. Without it the partition below was a
    /// linear `findField` in both directions — O(n·m) per record
    /// unification, under a comment claiming one pass.
    ///
    /// Duplicate names cannot appear: `duplicate_field` refuses them in a
    /// literal and in a type, and a record variable is only ever extended
    /// with fields the other side did not have.
    fn gatherFields(s: *Solver, record: TypeStore.Structure.Record) Error!Gathered {
        var out: Gathered = .{ .fields = .empty, .ext = record.ext, .closed = false };
        try out.fields.appendSlice(s.env.scratch, s.store().fields(record.fields));
        // The store keeps ONE record's fields sorted, so a record that is
        // not extended by another is already in merge order and pays
        // nothing here. Only a flattened chain — two sorted runs
        // concatenated — needs the sort.
        var concatenated = false;
        var guard: u32 = 0;
        while (guard < 1024) : (guard += 1) {
            const root, const c = s.store().resolved(out.ext);
            switch (c) {
                .structure => |st| switch (st) {
                    .record => |r| {
                        try out.fields.appendSlice(s.env.scratch, s.store().fields(r.fields));
                        out.ext = r.ext;
                        concatenated = true;
                        continue;
                    },
                    .empty_record => {
                        out.ext = root;
                        out.closed = true;
                        break;
                    },
                    else => {
                        out.ext = root;
                        break;
                    },
                },
                else => {
                    out.ext = root;
                    break;
                },
            }
        }
        if (concatenated) std.mem.sort(TypeStore.Field, out.fields.items, {}, fieldLessThan);
        return out;
    }

    fn fieldLessThan(_: void, a: TypeStore.Field, b: TypeStore.Field) bool {
        return @intFromEnum(a.name) < @intFromEnum(b.name);
    }

    fn unifyRecord(s: *Solver, ra: Var, rec_a: TypeStore.Structure.Record, rb: Var, rec_b: TypeStore.Structure.Record) Error!bool {
        const st = s.store();
        var a = try s.gatherFields(rec_a);
        defer a.fields.deinit(s.env.scratch);
        var b = try s.gatherFields(rec_b);
        defer b.fields.deinit(s.env.scratch);

        var only_a: std.ArrayList(TypeStore.Field) = .empty;
        defer only_a.deinit(s.env.scratch);
        var only_b: std.ArrayList(TypeStore.Field) = .empty;
        defer only_b.deinit(s.env.scratch);
        var shared: std.ArrayList([2]Var) = .empty;
        defer shared.deinit(s.env.scratch);

        // Elm's four-way partition as ONE merge-join over two sorted runs
        // (`gatherFields` sorts), rather than a linear scan of each side
        // per field of the other.
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.fields.items.len and j < b.fields.items.len) {
            const fa = a.fields.items[i];
            const fb = b.fields.items[j];
            const na = @intFromEnum(fa.name);
            const nb = @intFromEnum(fb.name);
            if (na < nb) {
                try only_a.append(s.env.scratch, fa);
                i += 1;
            } else if (na > nb) {
                try only_b.append(s.env.scratch, fb);
                j += 1;
            } else {
                try shared.append(s.env.scratch, .{ fa.value, fb.value });
                i += 1;
                j += 1;
            }
        }
        try only_a.appendSlice(s.env.scratch, a.fields.items[i..]);
        try only_b.appendSlice(s.env.scratch, b.fields.items[j..]);

        // A field one side requires and the other cannot grow is the
        // interesting failure. Which code it is depends on WHICH side could
        // not grow: the expected type wanted a field the actual record does
        // not have (`missing_field`), or the actual record carried one the
        // expected type has no room for (`unknown_field`).
        if (only_a.items.len != 0 and !isOpenVar(st, b.ext)) {
            return s.fail(.{ .missing_field = .{
                .names = try s.fieldNames(only_a.items),
                .actual = rb,
                .expected = ra,
            } });
        }
        if (only_b.items.len != 0 and !isOpenVar(st, a.ext)) {
            return s.fail(.{ .unknown_field = .{
                .names = try s.fieldNames(only_b.items),
                .actual = rb,
                .expected = ra,
            } });
        }
        // Both sides can grow, but one of them promised to stay open: an
        // annotation's `{ r | … }` cannot become a specific record.
        if (isRigidVar(st, a.ext) != isRigidVar(st, b.ext) and (a.closed or b.closed)) {
            return s.fail(.{ .record_not_closed = .{ .actual = rb, .expected = ra } });
        }

        var ok = true;
        if (only_a.items.len == 0 and only_b.items.len == 0) {
            ok = try s.unifyQuiet(a.ext, b.ext) and ok;
        } else if (only_a.items.len == 0) {
            const sub = try s.freshRecord(only_b.items, b.ext);
            ok = try s.unifyQuiet(a.ext, sub) and ok;
        } else if (only_b.items.len == 0) {
            const sub = try s.freshRecord(only_a.items, a.ext);
            ok = try s.unifyQuiet(sub, b.ext) and ok;
        } else {
            const ext = try s.fresh(.{ .flex = .{} });
            const sub_a = try s.freshRecord(only_a.items, ext);
            const sub_b = try s.freshRecord(only_b.items, ext);
            ok = try s.unifyQuiet(a.ext, sub_b) and ok;
            ok = try s.unifyQuiet(sub_a, b.ext) and ok;
        }
        for (shared.items) |pair| ok = try s.unifyQuiet(pair[0], pair[1]) and ok;
        if (ok) _ = st.merge(st.find(ra), st.find(rb), .{ .structure = .{ .record = rec_a } });
        return ok;
    }

    fn freshRecord(s: *Solver, fields: []TypeStore.Field, ext: Var) Error!Var {
        const copied = try s.env.scratch.dupe(TypeStore.Field, fields);
        defer s.env.scratch.free(copied);
        const range = try s.store().addFields(copied);
        return s.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
    }

    fn fieldNames(s: *Solver, fields: []const TypeStore.Field) Error![]Symbol {
        const out = try s.env.scratch.alloc(Symbol, fields.len);
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

    // ---- Calls: checker.md §8.3 ------------------------------------------

    fn call(s: *Solver, node: Constrain.Node) Error!void {
        const info = s.tree.extraData(node.a, Constrain.Call);
        const args = try s.copyVars(s.tree.vars(info.args_start, info.args_len));
        defer s.env.scratch.free(args);
        const st = s.store();
        const given: u32 = @intCast(args.len);
        const arg_regions = s.argRegions(node.region);

        // A nullary constructor PATTERN arrives here as a call of no
        // arguments (`Constrain`'s `.ctor_pattern`): there is nothing to
        // apply, and the constructor's type is the pattern's type.
        //
        // The callee has to be nullary too. `Constrain` emits a `.call` for
        // EVERY constructor pattern, so `case p of Pair ->` with a 2-ary
        // `Pair` arrives here as well, and short-circuiting it would trade
        // §8.3's arity message for a raw `type_mismatch`. An `err` callee
        // and a flex one both have `paramCount == 0` and keep the shortcut.
        if (given == 0 and st.paramCount(info.callee) == 0) {
            try s.unify(info.result, info.callee, node.region, node.category);
            return;
        }

        // Every call is saturated (language.md §6.7), so §8.3 is one
        // question and not a peeling loop: is the callee a function, and
        // does it take exactly this many arguments? A callee that is still
        // a variable is the higher-order case — it becomes the n-ary
        // function this call needs, and its arity is fixed from here on.
        const callee_content = st.resolvedContent(info.callee);
        const callee_func = switch (callee_content) {
            .err => return,
            .structure => |flat| switch (flat) {
                .func => |f| f,
                else => null,
            },
            .flex => |flags| blk: {
                // A `number` or an `appendable` is never a function, so a
                // call of one is `not_a_function` and not an invitation to
                // grow arrows.
                if (flags.kind != .any) break :blk null;
                const wanted = try s.func(args, info.result);
                try s.unify(info.callee, wanted, node.region, node.category);
                return;
            },
            else => null,
        } orelse {
            if (info.flavor == .ctor_pattern) {
                try s.reporter.ctorPatternArity(node.region, s.reporter.calleeOf(node.region), 0, given);
            } else {
                try s.reporter.notAFunction(node.region, s.reporter.calleeOf(node.region), given, info.callee);
            }
            s.poison(info.result);
            for (args) |arg| s.poison(arg);
            return;
        };

        // Copied out of `extra`: unifying an argument appends to it and
        // would dangle a view (see `unifyPairs`).
        const params = try s.copyVars(st.vars(callee_func.params));
        defer s.env.scratch.free(params);
        const arity: u32 = @intCast(params.len);

        // The arity rule of §8.3 comes FIRST and suppresses the generic
        // mismatch. A call with the wrong number of arguments has its
        // arguments in the wrong positions, so checking them would report a
        // second, misleading message about a type the author never meant to
        // put there.
        if (arity != given) {
            if (info.flavor == .ctor_pattern) {
                try s.reporter.ctorPatternArity(node.region, s.reporter.calleeOf(node.region), arity, given);
            } else if (arity > given) {
                try s.reporter.tooFewArgs(node.region, s.reporter.calleeOf(node.region), arity, given, params[given..]);
            } else {
                try s.reporter.tooManyArgs(node.region, s.reporter.calleeOf(node.region), arity, given);
            }
            s.poison(info.result);
            for (args) |arg| s.poison(arg);
            return;
        }

        if (try s.unifyArgs(node, params, args, arg_regions, given)) {
            s.poison(info.result);
            return;
        }
        try s.unify(info.result, callee_func.result, node.region, node.category);
    }

    /// Unify the first `count` arguments against the callee's parameters,
    /// STOPPING at the first failure. One mistake yields one message: once
    /// an argument is wrong every later parameter was computed from a type
    /// the author did not mean, and reporting those too is the cascade
    /// research/02 §6 exists to prevent.
    fn unifyArgs(
        s: *Solver,
        node: Constrain.Node,
        params: []const Var,
        args: []const Var,
        arg_regions: []const Bir.Inst.Index,
        count: u32,
    ) Error!bool {
        // The flag is scoped to this loop, so anything the caller had
        // already reported has to survive it.
        const outer = s.reporter.didReport();
        defer if (outer) s.reporter.markReported();
        for (args[0..count], 0..) |arg, i| {
            s.reporter.clearReported();
            try s.unify(params[i], arg, argRegion(arg_regions, node.region, i), .{
                .tag = .call_arg,
                .index = @intCast(i + 1),
                .owner = node.region.toOptional(),
            });
            if (s.reporter.didReport()) return true;
        }
        return false;
    }

    /// The Bir instructions of a call's arguments, so an argument mismatch
    /// underlines the argument and not the whole call.
    fn argRegions(s: *Solver, region: Bir.Inst.Index) []const Bir.Inst.Index {
        const bir = s.env.bir;
        if (region.int() >= bir.insts.len) return &.{};
        return switch (bir.instTag(region)) {
            .call, .pat_ctor => bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(region).rhs)), Bir.Inst.Index),
            else => &.{},
        };
    }

    /// `p1, …, pn -> result`: one n-ary function type.
    fn func(s: *Solver, params: []const Var, result: Var) Error!Var {
        const range = try s.store().addVars(params);
        return s.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } });
    }

    // ---- Instantiation ---------------------------------------------------

    fn instantiate(s: *Solver, node: Constrain.Node) Error!void {
        const target: Var = @enumFromInt(node.a);
        const scheme = (try s.schemeOf(node.region)) orelse {
            s.poison(target);
            return;
        };
        const copy = try s.makeCopy(scheme);
        try s.unify(target, copy, node.region, node.category);
    }

    /// The scheme the reference at `region` names. After resolution every
    /// reference is a pair of dense indices, so this is array lookups and
    /// no name is compared (checker.md §4.5).
    ///
    /// Every arm reads this module's own Bir or a dependency's INTERFACE,
    /// and nothing reads a dependency's Bir — the firewall of
    /// `fast-compiler.md` §8.1, which M2 broke here: the `.ext_ctor` arm
    /// used to open the declaring module's Bir and scan its constructor
    /// table by NAME, under this very comment. `Interface.Ctor.arg_terms`
    /// is what makes the comment true.
    fn schemeOf(s: *Solver, region: Bir.Inst.Index) Error!?Var {
        const bir = s.env.bir;
        const data = bir.instData(region);
        switch (bir.instTag(region)) {
            .local => return s.env.localVar(data.lhs),
            .top => {
                if (data.lhs >= s.env.decl_scheme.len) return null;
                return s.env.decl_scheme[data.lhs].unwrap();
            },
            .ctor => return try s.ctorType(data.lhs),
            .ext_value => return try s.importedValue(@enumFromInt(data.lhs), data.rhs),
            .ext_ctor => return try s.importedCtor(@enumFromInt(data.lhs), data.rhs),
            else => return null,
        }
    }

    /// A constructor of THIS module: `arg1 -> … -> argN -> T p1 … pk`, built
    /// FRESH at the current rank. Building it fresh is the instantiation:
    /// nothing is shared with another use site, so there is nothing to
    /// copy. An imported constructor goes through `importedCtor` instead —
    /// this reads the module's own Bir, which only its own check may do.
    fn ctorType(s: *Solver, index: u32) Error!?Var {
        const module = s.env.module;
        const bir = s.env.bir;
        if (index >= bir.ctors.len) return null;
        const c = bir.ctors[index];
        const owner = bir.decl(c.decl);
        const id = s.env.types.ofDecl(module, c.decl);
        if (id == .none) return null;

        const mark = s.store().count();
        var b: Types.Builder = .init(
            s.store(),
            s.env.types,
            s.env.graph,
            s.env.artifacts,
            module,
            bir,
            .flex,
            s.rank,
            s.env.scratch,
            s.env.interner,
        );
        defer b.deinit();
        const params = bir.declTypeParams(owner);
        const param_vars = try s.env.scratch.alloc(Var, params.len);
        defer s.env.scratch.free(param_vars);
        for (params, param_vars) |p, *v| {
            v.* = try s.store().fresh(.{ .flex = .{ .name = p.toOptional() } }, s.rank);
            try b.bind(p, v.*);
        }
        const args = bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index);
        const arg_vars = try s.env.scratch.alloc(Var, args.len);
        defer s.env.scratch.free(arg_vars);
        for (args, arg_vars) |arg, *v| v.* = try b.read(arg);
        // The guard poisoned an argument, so the constructor's type is a
        // hole; a message has to go with it (`Env.too_deep`).
        if (b.too_deep) try s.env.noteTooDeep(s.region);
        const result = try b.apply(id, param_vars);
        // Everything the BUILDER made has to join the pool; `func` goes
        // through `fresh`, which pools as it goes, so it runs after —
        // adopting a range that already contained the function type's
        // variable would put it in twice.
        try s.adoptSince(mark);
        if (arg_vars.len == 0) return result;
        return try s.func(arg_vars, result);
    }

    /// A constructor of another module, instantiated from that module's
    /// interface (checker.md §7's `arg_terms`) — never from its `Bir`.
    ///
    /// This is the firewall of `fast-compiler.md` §8.1 for constructors: in
    /// M4 a dependency's Bir may not be in memory, only this record. It is
    /// also §4.5: `data.rhs` is the dense `CtorIndex` resolution already
    /// produced, so no name is compared. The version this replaced opened
    /// the dependency's Bir and scanned its constructor table by name.
    fn importedCtor(s: *Solver, module: Graph.Index, index: u32) Error!?Var {
        if (module.int() >= s.env.interfaces.len) return null;
        const iface = &s.env.interfaces[module.int()];
        if (index >= iface.ctors.len) return null;
        const type_id = s.env.types.ofInterface(module, iface.ctors[index].type);
        if (type_id == .none) return null;
        const mark = s.store().count();
        const v = try Schemes.instantiateCtor(iface, s.store(), index, type_id, s.rank, s.env.scratch) orelse return null;
        try s.adoptSince(mark);
        return v;
    }

    /// A value of another module, instantiated from that module's interface
    /// (checker.md §7): the flat term language, copied into this store with
    /// one fresh variable per quantifier.
    ///
    /// The `instantiations` counter is NOT bumped here. Every scheme this
    /// returns goes through `makeCopy`, which counts it — counting again
    /// would make one imported call read as two, and checker.md §9 has M4's
    /// incrementality tests asserting this counter did not move, so it has
    /// to mean exactly one thing.
    fn importedValue(s: *Solver, module: Graph.Index, index: u32) Error!?Var {
        if (module.int() >= s.env.interfaces.len) return null;
        const iface = &s.env.interfaces[module.int()];
        if (index >= iface.values.len) return null;
        const scheme_index = iface.values[index].scheme;
        if (scheme_index == .none) return null;
        const mark = s.store().count();
        const v = try Schemes.instantiate(iface, s.store(), @intFromEnum(scheme_index), s.rank, s.env.scratch);
        try s.adoptSince(mark);
        return v;
    }

    /// Elm's `makeCopy`: copy a generalised type, memoising through the
    /// descriptor's `copy` field so internal sharing survives
    /// (`let x = (y, y)` copies `y` once, design §7 #4). The memo is
    /// cleared through `touched` rather than by walking the copy again.
    pub fn makeCopy(s: *Solver, v: Var) Error!Var {
        const start = s.touched.items.len;
        const copy = try s.copyHelp(v);
        for (s.touched.items[start..]) |t| s.store().setCopy(t, .none);
        s.touched.shrinkRetainingCapacity(start);
        s.counters.instantiations += 1;
        return copy;
    }

    fn copyHelp(s: *Solver, v: Var) Error!Var {
        s.depth += 1;
        defer s.depth -= 1;
        // See `max_depth`: unreachable from a file the parser accepted.
        // Returning the original variable shares it with the copy, which is
        // wrong but monotone — it can only make a type LESS general, never
        // silently accept more.
        if (s.depth > max_depth) return v;

        const st = s.store();
        const root = st.find(v);
        if (st.copy(root).unwrap()) |existing| return existing;
        // Only a GENERALISED variable is copied. Everything else is shared
        // with the enclosing scope and must stay the same node — that is
        // what makes a lambda parameter monomorphic.
        if (st.rank(root) != TypeStore.generalized) return root;

        const content = st.content(root);
        const copy = try s.fresh(content);
        st.setCopy(root, copy.toOptional());
        try s.touched.append(s.gpa, root);

        switch (content) {
            .err, .flex => {},
            // Instantiating an annotation's promise turns it into an
            // ordinary variable: inside the body `a` is rigid, at a call
            // site it is whatever the caller needs (Elm's `makeCopyHelp`).
            .rigid => |flags| st.setContent(copy, .{ .flex = flags }),
            .structure => |flat| {
                const copied: TypeStore.Structure = switch (flat) {
                    .unit, .empty_record => flat,
                    .func => |f| .{ .func = .{ .params = try s.copyRange(st.vars(f.params)), .result = try s.copyHelp(f.result) } },
                    .app => |a| .{ .app = .{ .type = a.type, .args = try s.copyRange(st.vars(a.args)) } },
                    .tuple => |t| .{ .tuple = try s.copyRange(st.vars(t)) },
                    .record => |r| blk: {
                        // Copied, not viewed: `st.fields` is a view into
                        // `extra`, copying a child appends to `extra` and
                        // moves it, and `addFields` sorts its input in
                        // place. Both rule out working on the view.
                        const source = try s.env.scratch.dupe(TypeStore.Field, st.fields(r.fields));
                        defer s.env.scratch.free(source);
                        for (source) |*f| f.value = try s.copyHelp(f.value);
                        const range = try st.addFields(source);
                        break :blk .{ .record = .{ .fields = range, .ext = try s.copyHelp(r.ext) } };
                    },
                };
                st.setContent(copy, .{ .structure = copied });
            },
            .alias => |a| {
                const args = try s.copyRange(st.vars(a.args));
                const actual = try s.copyHelp(a.actual);
                st.setContent(copy, .{ .alias = .{ .type = a.type, .args = args, .actual = actual } });
            },
        }
        return copy;
    }

    /// Copy a range of variables. The dupe is unavoidable for the same
    /// reason as `copyHelp`'s record arm: `st.vars` is a view into `extra`
    /// and copying a child appends to it.
    fn copyRange(s: *Solver, vars: []const Var) Error!TypeStore.Range {
        const source = try s.env.scratch.dupe(Var, vars);
        defer s.env.scratch.free(source);
        for (source) |*v| v.* = try s.copyHelp(v.*);
        return s.store().addVars(source);
    }

    // ---- `?` (checker.md §6.5) -------------------------------------------

    /// Try `Result x a` and then `Maybe a`, each under a journal mark, and
    /// roll back the one that does not fit. The only speculation in M2b —
    /// and the reason the store carries an undo journal at all.
    fn tryShape(s: *Solver, node: Constrain.Node) Error!void {
        const info = s.tree.extraData(node.b, Constrain.Try);
        const scrutinee: Var = @enumFromInt(node.a);
        const wk = s.env.types.well_known;
        for ([_]Types.TypeId{ wk.result, wk.maybe }) |id| {
            if (id == .none) continue;
            // The journal restores the STORE; the pool and the obligation
            // list are the solver's own bookkeeping and have to be rolled
            // back with it, or the pool would hold variables the rollback
            // has already discarded.
            const pool_len = (try s.pool(s.rank)).items.len;
            const obligation_len = (try s.obligationsAt(s.rank)).items.len;
            const snapshot = s.store().beginSpeculation();
            const ok = try s.tryShapeOnce(id, scrutinee, info);
            if (ok) {
                s.store().commit(snapshot);
                return;
            }
            const exact = s.store().rollback(snapshot);
            (try s.pool(s.rank)).shrinkRetainingCapacity(pool_len);
            (try s.obligationsAt(s.rank)).shrinkRetainingCapacity(obligation_len);
            // An inexact rollback (the journal could not allocate) leaves
            // the store in a state no further guess can be trusted against,
            // so stop guessing rather than report a shape that was decided
            // by a memory failure.
            if (!exact) return;
        }
        try s.reporter.tryShape(node.region, scrutinee, info.enclosing);
        s.poison(scrutinee);
        s.poison(info.value);
    }

    fn tryShapeOnce(s: *Solver, id: Types.TypeId, scrutinee: Var, info: Constrain.Try) Error!bool {
        const arity = s.env.types.entry(id).arity;
        // `Result x a` shares its error type with the enclosing result;
        // `Maybe a` has none to share. That is the whole difference.
        const error_var = if (arity == 2) try s.fresh(.{ .flex = .{} }) else null;
        const scrutinee_value = try s.fresh(.{ .flex = .{} });
        const enclosing_value = try s.fresh(.{ .flex = .{} });
        const scrutinee_shape = if (error_var) |e|
            try s.applied(id, &.{ e, scrutinee_value })
        else
            try s.applied(id, &.{scrutinee_value});
        const enclosing_shape = if (error_var) |e|
            try s.applied(id, &.{ e, enclosing_value })
        else
            try s.applied(id, &.{enclosing_value});
        if (!try s.unifyQuiet(scrutinee_shape, scrutinee)) return false;
        if (!try s.unifyQuiet(enclosing_shape, info.enclosing)) return false;
        if (!try s.unifyQuiet(info.value, scrutinee_value)) return false;
        return true;
    }

    fn applied(s: *Solver, id: Types.TypeId, args: []const Var) Error!Var {
        const range = try s.store().addVars(args);
        return s.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } });
    }

    // ---- Generalisation --------------------------------------------------

    /// Elm's `generalize`: bucket the young pool by rank, fix the ranks
    /// bottom-up, move what escaped into its own pool, and quantify the
    /// rest. Never scans the environment (research/02 §2.2).
    pub fn generalize(s: *Solver, young_rank: u32) Error!void {
        const st = s.store();
        const young_mark = st.nextMark();
        const visit_mark = st.nextMark();

        const young = (try s.pool(young_rank)).items;
        // `table[rank]` holds the young pool's members currently at `rank`.
        var table: std.ArrayList(std.ArrayList(Var)) = .empty;
        defer {
            for (table.items) |*t| t.deinit(s.env.scratch);
            table.deinit(s.env.scratch);
        }
        while (table.items.len <= young_rank) try table.append(s.env.scratch, .empty);
        for (young) |v| {
            const root = st.find(v);
            st.setMark(root, young_mark);
            const r = @min(st.rank(root), young_rank);
            try table.items[r].append(s.env.scratch, root);
        }

        // Low ranks first, so the information is computed in one pass.
        for (table.items, 0..) |bucket, r| {
            for (bucket.items) |v| _ = adjustRank(st, young_mark, visit_mark, @intCast(r), v, 0);
        }

        // Everything BELOW the young rank escaped this `let` and goes back
        // into the pool of whatever rank `adjustRank` settled on — which is
        // why the bucket's own index is not needed here, only the
        // variable's new rank.
        for (table.items[0..young_rank]) |bucket| {
            for (bucket.items) |v| {
                if (st.find(v) != v) continue; // redundant: merged away
                try (try s.pool(st.rank(v))).append(s.gpa, v);
            }
        }
        for (table.items[young_rank].items) |v| {
            if (st.find(v) != v) continue;
            if (st.rank(v) < young_rank) {
                try (try s.pool(st.rank(v))).append(s.gpa, v);
            } else {
                st.setRank(v, TypeStore.generalized);
                s.counters.generalisations += 1;
            }
        }
        (try s.pool(young_rank)).clearRetainingCapacity();
    }

    // ---- Obligations (checker.md §6.4) -----------------------------------

    fn dischargeObligations(s: *Solver, rank: u32) Error!void {
        // Discharging can register more (an `equatable` flex variable that
        // meets a structure while a `tuple_index` binds), so the list is
        // drained by index and re-read every round rather than held across
        // a call that may grow it.
        var i: usize = 0;
        var rounds: usize = 0;
        while (rounds < 1 << 20) : (rounds += 1) {
            const o = blk: {
                const list = try s.obligationsAt(rank);
                if (i >= list.items.len) break;
                break :blk list.items[i];
            };
            i += 1;
            s.counters.obligations += 1;
            switch (o.kind) {
                .equatable => try s.dischargeEquatable(o),
                .interpolatable => try s.dischargeInterpolatable(o),
                .tuple_index => try s.dischargeTupleIndex(o),
            }
        }
        (try s.obligationsAt(rank)).clearRetainingCapacity();
    }

    fn dischargeEquatable(s: *Solver, o: Obligation) Error!void {
        const st = s.store();
        const root, const c = st.resolved(o.v);
        switch (c) {
            .err => {},
            // Still a variable: fold the flag in and let the caller's
            // instantiation carry it (checker.md §6.4).
            .flex => |flags| st.setContent(root, .{ .flex = .{ .name = flags.name, .kind = flags.kind, .equatable = true } }),
            .rigid => |flags| if (!flags.equatable) {
                try s.reporter.notEquatable(o.region, o.v, .rigid_variable);
            },
            else => switch (walkEquatable(s, o.v)) {
                // `unknown` is a type too wide for the walk's worklist. It
                // is accepted rather than refused: the alternative is
                // rejecting a program for being large, and there is no
                // message that would help.
                .ok, .unknown => {},
                .function => try s.reporter.notEquatable(o.region, o.v, .function),
                .opaque_type => try s.reporter.notEquatable(o.region, o.v, .opaque_type),
            },
        }
    }

    const EquatableResult = enum { ok, function, opaque_type, unknown };

    /// Walk a concrete type ONCE, with a mark as the cycle guard: no
    /// function anywhere, and every named type declared equatable
    /// (checker.md §6.4, Appendix B). The walk happens here, at discharge,
    /// and never inside unification — which is the whole point of §3.1.
    fn walkEquatable(s: *Solver, root_var: Var) EquatableResult {
        const st = s.store();
        const mark = st.nextMark();
        var stack: [256]Var = undefined;
        var len: usize = 1;
        stack[0] = root_var;
        var budget: usize = 1 << 16;
        while (len > 0) {
            if (budget == 0) return .unknown;
            budget -= 1;
            len -= 1;
            const v = stack[len];
            const root, const c = st.resolved(v);
            if (st.mark(root) == mark) continue;
            st.setMark(root, mark);
            // A full worklist means the walk cannot finish, and answering
            // `ok` there would let a function hide in a wide type. The
            // caller is told by the `.unknown` result instead.
            const push = struct {
                fn f(buf: *[256]Var, l: *usize, x: Var) bool {
                    if (l.* >= buf.len) return false;
                    buf[l.*] = x;
                    l.* += 1;
                    return true;
                }
            }.f;
            switch (c) {
                // `resolved` already followed every alias, so only these
                // five can appear; an alias here would mean a poisoned
                // chain, which is not worth a message.
                .err, .flex, .rigid, .alias => {},
                .structure => |flat| switch (flat) {
                    .unit, .empty_record => {},
                    .func => return .function,
                    .app => |a| {
                        if (!s.env.types.isEquatable(a.type)) return .opaque_type;
                        for (st.vars(a.args)) |arg| {
                            if (!push(&stack, &len, arg)) return .unknown;
                        }
                    },
                    .tuple => |t| for (st.vars(t)) |el| {
                        if (!push(&stack, &len, el)) return .unknown;
                    },
                    .record => |r| {
                        for (st.fields(r.fields)) |f| {
                            if (!push(&stack, &len, f.value)) return .unknown;
                        }
                        if (!push(&stack, &len, r.ext)) return .unknown;
                    },
                },
            }
        }
        return .ok;
    }

    fn dischargeInterpolatable(s: *Solver, o: Obligation) Error!void {
        const st = s.store();
        const c = st.resolvedContent(o.v);
        const wk = s.env.types.well_known;
        switch (c) {
            .err => {},
            // A `number` variable is `Int` or `Float`, and both are on the
            // list, so it needs no annotation to be decidable — the check is
            // "exactly String | Int | Float | Bool | Char" and a `number`
            // cannot be anything else. Any other variable is genuinely
            // undecidable and cannot be deferred to the caller, because the
            // emitted code has to know which conversion to make
            // (checker.md §6.4).
            .flex, .rigid => |flags| if (flags.kind != .number) try s.reporter.ambiguousInterpolation(o.region),
            .structure => |flat| switch (flat) {
                .app => |a| {
                    const ok = a.args.len == 0 and
                        (a.type == wk.string or a.type == wk.int or a.type == wk.float or a.type == wk.bool or a.type == wk.char);
                    if (!ok) try s.reporter.notInterpolatable(o.region, o.v);
                },
                else => try s.reporter.notInterpolatable(o.region, o.v),
            },
            // `resolved` followed every alias; reaching one means a
            // poisoned chain, which already has a message.
            .alias => {},
        }
    }

    fn dischargeTupleIndex(s: *Solver, o: Obligation) Error!void {
        const st = s.store();
        const c = st.resolvedContent(o.v);
        const result = o.result.unwrap() orelse return;
        switch (c) {
            .err => s.poison(result),
            .flex, .rigid => {
                try s.reporter.ambiguousTuple(o.region, o.index);
                s.poison(result);
            },
            .structure => |flat| switch (flat) {
                .tuple => |t| {
                    if (o.index >= t.len) {
                        try s.reporter.tupleIndexOutOfRange(o.region, o.index, t.len, o.v);
                        s.poison(result);
                        return;
                    }
                    const element = st.vars(t)[o.index];
                    try s.unify(result, element, o.region, .{ .tag = .general });
                },
                else => {
                    try s.reporter.notATuple(o.region, o.index, o.v);
                    s.poison(result);
                },
            },
            .alias => {},
        }
    }

    /// Seed the outermost pool with what the generator allocated. The
    /// top-level driver plays the part `let_` plays for a nested `let`.
    pub fn enterTopLevel(s: *Solver, vars: []const Var) Error!void {
        const p = try s.pool(s.rank);
        p.clearRetainingCapacity();
        try p.appendSlice(s.gpa, vars);
    }

    /// Close a top-level binding group: obligations, generalisation, then
    /// the deferred occurs check once per binding (design §7 #3).
    pub fn finishTopLevel(s: *Solver, headers: []const Constrain.Header) Error!void {
        try s.dischargeObligations(s.rank);
        try s.generalize(s.rank);
        for (headers) |h| {
            if (!try occurs(&s.occurs_frames, s.gpa, s.store(), h.v)) continue;
            s.store().setContent(s.store().find(h.v), .err);
            try s.reporter.infiniteType(h.region, h.name);
        }
    }
};

fn argRegion(regions: []const Bir.Inst.Index, fallback: Bir.Inst.Index, i: usize) Bir.Inst.Index {
    return if (i < regions.len) regions[i] else fallback;
}

/// Elm's `adjustRank`, comment for comment: ranks never increase as you move
/// deeper, so the outermost rank is representative of the entire structure.
/// Two marks memoise it — `young_mark` says "in this generalisation",
/// `visit_mark` says "already computed" — and the variable is marked BEFORE
/// its content is walked, because the structure may be cyclic.
fn adjustRank(st: *TypeStore, young_mark: u32, visit_mark: u32, group_rank: u32, v: Var, depth: u32) u32 {
    const root = st.find(v);
    const rank = st.rank(root);
    const mark = st.mark(root);
    // Unreachable from an accepted file (`Solver.max_depth`). Returning the
    // variable's own rank is the conservative answer: it can only keep a
    // variable OUT of a generalisation, never let one in that should have
    // stayed at an outer rank.
    if (depth > Solver.max_depth) return rank;
    if (mark == young_mark) {
        st.setMark(root, visit_mark);
        const max = adjustRankContent(st, young_mark, visit_mark, group_rank, st.content(root), depth);
        st.setRank(root, max);
        return max;
    }
    if (mark == visit_mark) return rank;
    const min_rank = @min(group_rank, rank);
    st.setMark(root, visit_mark);
    st.setRank(root, min_rank);
    return min_rank;
}

fn adjustRankContent(st: *TypeStore, young_mark: u32, visit_mark: u32, group_rank: u32, content: TypeStore.Content, depth: u32) u32 {
    switch (content) {
        .err, .flex, .rigid => return group_rank,
        .alias => |a| {
            var max = adjustRank(st, young_mark, visit_mark, group_rank, a.actual, depth + 1);
            for (st.vars(a.args)) |arg| max = @max(max, adjustRank(st, young_mark, visit_mark, group_rank, arg, depth + 1));
            return max;
        },
        .structure => |flat| switch (flat) {
            // A unit or an empty record never needs generalising.
            .unit, .empty_record => return TypeStore.outermost,
            .func => |f| {
                var max = adjustRank(st, young_mark, visit_mark, group_rank, f.result, depth + 1);
                for (st.vars(f.params)) |param| max = @max(max, adjustRank(st, young_mark, visit_mark, group_rank, param, depth + 1));
                return max;
            },
            .app => |a| {
                var max = TypeStore.outermost;
                for (st.vars(a.args)) |arg| max = @max(max, adjustRank(st, young_mark, visit_mark, group_rank, arg, depth + 1));
                return max;
            },
            .tuple => |t| {
                var max = TypeStore.outermost;
                for (st.vars(t)) |el| max = @max(max, adjustRank(st, young_mark, visit_mark, group_rank, el, depth + 1));
                return max;
            },
            .record => |r| {
                var max = adjustRank(st, young_mark, visit_mark, group_rank, r.ext, depth + 1);
                for (st.fields(r.fields)) |f| max = @max(max, adjustRank(st, young_mark, visit_mark, group_rank, f.value, depth + 1));
                return max;
            },
        },
    }
}

/// The deferred occurs check (design §7 #3): is `v` reachable from its own
/// structure? Run once per generalised binding, never inside unification.
/// Iterative, three-colour, so a 4096-deep type cannot overflow the stack.
///
/// **No depth guard, deliberately.** This is the only walk in the checker
/// that answers a yes/no question whose "no" is a *silently accepted
/// program*: a missed cycle is a missed `infinite_type` and a type the
/// backend would then try to emit. A fixed frame array meant answering "no
/// cycle" for a type merely too deep to finish, so the frames grow instead.
/// The stack is bounded anyway — every frame holds a distinct GREY node, so
/// it can never exceed the store's variable count.
///
/// `frames` is the caller's, cleared here and kept between calls: this runs
/// once per generalised binding — 122 000 times on the 100k-line corpus —
/// and a list allocated per call would put an allocation on a path that had
/// none.
pub fn occurs(frames: *OccursFrames, gpa: Allocator, st: *TypeStore, v: Var) Allocator.Error!bool {
    const grey = st.nextMark();
    const black = st.nextMark();
    frames.clearRetainingCapacity();
    try frames.append(gpa, .{ .v = st.find(v), .cursor = 0 });
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        const root = st.find(frame.v);
        if (frame.cursor == 0) {
            if (st.mark(root) == grey) return true;
            if (st.mark(root) == black) {
                _ = frames.pop();
                continue;
            }
            st.setMark(root, grey);
        }
        const child = nthChild(st, root, frame.cursor);
        frame.cursor += 1;
        if (child) |c| {
            try frames.append(gpa, .{ .v = c, .cursor = 0 });
            continue;
        }
        st.setMark(root, black);
        _ = frames.pop();
    }
    return false;
}

/// The occurs check's explicit stack. One per solver, reused.
pub const OccursFrames = std.ArrayList(OccursFrame);
pub const OccursFrame = struct { v: Var, cursor: u32 };

/// The `n`th child of a descriptor's content, or null past the end. One
/// place that knows the shape of every `Content`, so a new one is a compile
/// error here rather than a missed edge.
fn nthChild(st: *TypeStore, root: Var, n: u32) ?Var {
    switch (st.content(root)) {
        .err, .flex, .rigid => return null,
        .alias => |a| {
            if (n == 0) return a.actual;
            const args = st.vars(a.args);
            return if (n - 1 < args.len) args[n - 1] else null;
        },
        .structure => |flat| switch (flat) {
            .unit, .empty_record => return null,
            .func => |f| {
                const params = st.vars(f.params);
                if (n < params.len) return params[n];
                return if (n == params.len) f.result else null;
            },
            .app => |a| {
                const args = st.vars(a.args);
                return if (n < args.len) args[n] else null;
            },
            .tuple => |t| {
                const elements = st.vars(t);
                return if (n < elements.len) elements[n] else null;
            },
            .record => |r| {
                const fields = st.fields(r.fields);
                if (n < fields.len) return fields[n].value;
                return if (n == fields.len) r.ext else null;
            },
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "occurs finds a variable inside its own structure and nothing else" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var frames: OccursFrames = .empty;
    defer frames.deinit(testing.allocator);
    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    const pa = try store.addVars(&.{a});
    const pair = try store.fresh(.{ .structure = .{ .func = .{ .params = pa, .result = b } } }, 1);
    try testing.expect(!try occurs(&frames, testing.allocator, &store, pair));
    try testing.expect(!try occurs(&frames, testing.allocator, &store, a));

    // Tie `a` to a function that mentions `a`: `a = a -> b`.
    const pp = try store.addVars(&.{pair});
    _ = store.merge(a, try store.freshFlex(1), .{ .structure = .{ .func = .{ .params = pp, .result = b } } });
    try testing.expect(try occurs(&frames, testing.allocator, &store, a));
}

test "adjustRank pulls a structure's rank down to the outermost it reaches" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    // An inner variable at rank 3 whose structure mentions an outer one at
    // rank 1 may not be generalised by the inner `let`.
    const outer = try store.freshFlex(1);
    const inner = try store.freshFlex(3);
    const po = try store.addVars(&.{outer});
    const applied = try store.fresh(.{ .structure = .{ .func = .{ .params = po, .result = inner } } }, 3);
    const young = store.nextMark();
    const visit = store.nextMark();
    store.setMark(applied, young);
    store.setMark(inner, young);
    const rank = adjustRank(&store, young, visit, 3, applied, 0);
    try testing.expectEqual(@as(u32, 3), rank);
    try testing.expectEqual(@as(u32, 1), store.rank(outer));
    try testing.expectEqual(@as(u32, 3), store.rank(inner));
}
