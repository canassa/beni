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
const Dispatch = @import("Dispatch.zig");

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
    /// Static-dispatch accounting: `plans/static-dispatch-spike.md` §7 M1b
    /// for the rows they feed, `docs/design/static-dispatch-spike.md`
    /// §6.1-§6.3 for the mechanism. Declared before there is anything to
    /// count, the way
    /// the four above were, so the M1a baseline on this branch and the
    /// numbers after the checker lands are read off the SAME JSON line and
    /// the same `--self-profile` trace. Every one of them is zero until S3
    /// emits method constraints; a non-zero here on an unchanged checker
    /// would itself be the finding.
    ///
    ///   - `created` — method constraints attached to a type variable,
    ///     one per `x.m` whose receiver is not yet concrete.
    ///   - `merged` — constraint sets unioned by flex ⊓ flex (§6.2).
    ///   - `deferred` — obligations registered because the receiver was
    ///     still a variable when the constraint was raised.
    ///   - `discharged` — obligations resolved against a concrete type
    ///     (§6.3), which is where the method lookup is paid.
    ///   - `promoted` — constraints that survived generalisation and rode
    ///     out on an exported scheme, which is the `fast-compiler.md` §3.1
    ///     interface cost the spike exists to measure.
    constraints_created: u64 = 0,
    constraints_merged: u64 = 0,
    constraints_deferred: u64 = 0,
    constraints_discharged: u64 = 0,
    constraints_promoted: u64 = 0,

    /// Field-by-field sum. Reflective on purpose: a counter added above and
    /// forgotten here would silently report a per-module figure as if it
    /// were the whole project's.
    pub fn add(a: Counters, b: Counters) Counters {
        var out: Counters = .{};
        inline for (@typeInfo(Counters).@"struct".fields) |f| {
            @field(out, f.name) = @field(a, f.name) + @field(b, f.name);
        }
        return out;
    }
};

/// An ad-hoc constraint that cannot be answered until the type is concrete
/// (checker.md §6.4). Kept per rank and discharged when that rank is done.
pub const Obligation = struct {
    kind: Kind,
    v: Var,
    /// Where the requirement itself was WRITTEN: the `x.m` call, the
    /// operator, or — for a constraint that arrived by instantiating an
    /// imported scheme — the `where` clause inside the CALLEE.
    region: Bir.Inst.Index,
    /// The instruction in THIS module whose instantiation created this
    /// obligation (static-dispatch-spike.md §6.2, A.37). It is the
    /// PRIMARY span of every message that carries two: the call the author
    /// wrote, not the annotation it came from. Roc records the same thing
    /// and never reads it, which is report 18 §2.4's complaint.
    origin: Bir.Inst.Index = @enumFromInt(0),
    /// `tuple_index`: the index. `method`: the index into the store's
    /// `constraints` table of the constraint being discharged.
    index: u32 = 0,
    /// `tuple_index`: the variable the element must equal.
    result: Var.Optional = .none,

    pub const Kind = enum { equatable, interpolatable, tuple_index, method };
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
    /// Whether the type the last `makeCopy` produced can carry a method
    /// constraint ANYWHERE inside it (§7.2).
    ///
    /// `copyHelp` walks exactly the nodes `Schemes.quantifierOrder` then
    /// walks on the copy, so a walk that met no constrained variable proves
    /// `tagInstantiated` would number nothing and write nothing — and on
    /// code that uses no dispatch that is every instantiation. It is set
    /// CONSERVATIVELY wherever `copyHelp` shares a subtree instead of
    /// descending into it (a non-generalised root, the depth guard), so it
    /// can only be true too often, never false too often.
    copy_constrained: bool = false,
    /// Constraint indices `promote` has already emitted sites for. Two
    /// declarations of one mutually recursive group share their generalised
    /// variables, so without this each of them emits the same
    /// `(inst, evidence_index)` row — an argument passed twice.
    ///
    /// **That reading needs `evidence_next` to hold**: "the same row" is
    /// only "the same argument" while one instruction's slots each have
    /// their own index. `joinConstraint` and `appendSite` deduplicate on the
    /// same pair and inherit the same dependency.
    ///
    /// Keyed on the VARIABLE and not on the constraint: two headers of one
    /// group share their generalised variables wholesale, so one entry per
    /// quantifier settles every constraint on it — and a group has a
    /// handful of quantifiers where an unannotated chain of `n` links has
    /// n(n+1)/2 constraints. That accumulation IS what plan §7's M2
    /// measures, so the bookkeeping over it has to be free.
    promoted: std.ArrayList(Var) = .empty,
    /// Constraint indices that have been ANSWERED — a target emitted for
    /// their sites, or a message written about why there is none (A.57).
    ///
    /// One constraint can be answered twice over. The instantiation that
    /// created it registers an obligation; Rule U3 registers another when
    /// its variable later meets a structure; and Rule U2 answers it inside
    /// unification, before any obligation is drained, when the variable
    /// turns out to be the enclosing declaration's own rigid. Every one of
    /// those routes is needed — none of them fires in every case — so the
    /// SECOND answer is the one that must be a no-op, or a failing
    /// constraint reports its message twice and a succeeding one emits the
    /// same evidence argument twice (`EvidenceParameters`: `inner($m$0,
    /// $m$0, x, factor)`).
    ///
    /// Only a settled answer is recorded. Folding a constraint back onto a
    /// flex variable (§6.2) settles nothing, and a later obligation for it
    /// is what answers it.
    ///
    /// Keyed on the constraint's index in the store's table, which is
    /// stable for as long as the entry is — and a speculative probe can
    /// retract both the entry and the answer, so `resolved_journal` records
    /// the order they were added in and `tryShape` unwinds it.
    resolved_methods: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// `resolved_methods`' keys in insertion order, so a retracted probe
    /// takes back exactly what it decided and nothing else (A.35's
    /// journal-by-length, applied to one more table).
    resolved_journal: std.ArrayList(u32) = .empty,
    /// Constraint indices a REBUILT set superseded, each mapped to the
    /// index that took the constraint's place (A.75).
    ///
    /// A set is a range of an append-only table and is never edited (§6.1
    /// invariant 2), so every rebuild — Rule U1's union, an attach that
    /// joins two constraints of one name, an extend that could not append
    /// in place — COPIES its inputs to fresh indices and leaves the old
    /// ones behind. Obligations already registered still name those old
    /// indices and `resolved_methods` is keyed on the index, so without
    /// this map the input and its replacement are two live obligations
    /// over one site list: `put (put (Box "z") "a") "b"` wrote both of its
    /// call sites twice and `Lower.evidenceShapeOk` refused the call as
    /// `internal` (`dispatch/JoinedConstraintSites`).
    ///
    /// Everything keyed on a constraint index reads through
    /// `followConstraint`, so the replacement is the one that answers, and
    /// it answers exactly once (A.57). The chain only ever points FORWARD
    /// — a replacement is appended after its inputs — so following it
    /// terminates.
    superseded: Redirects = .{},
    /// Every method constraint a drain folded back onto a flex variable
    /// (§6.4), so `settleUndetermined` can revisit the ones generalisation
    /// then failed to quantify. Journalled by length like everything else a
    /// probe can retract (A.35).
    deferred: std.ArrayList(Deferred) = .empty,
    /// The next free `evidence_index` on an instruction (§7.2), keyed on the
    /// Bir instruction index.
    ///
    /// **One instruction's slots are numbered once, across every scheme it
    /// instantiates.** A `method_call` takes 0 for the callee and its
    /// evidence from 1; resolving one of those slots can instantiate the
    /// scheme that ANSWERS it — `[ [ [ Box "a" "b" ] ] ] == …` goes three
    /// deep through `List.eq … where a.eq` — and each of those nested
    /// instantiations used to restart at a hard-coded 1, so five slots of
    /// one instruction all read `evidence_index = 1`, and `joinConstraint`
    /// and `appendSite`, which both DEDUPLICATE on `(inst, evidence_index)`,
    /// would have dropped a different slot's site.
    ///
    /// **It is an ALLOCATION order and therefore breadth-first**, which is
    /// not the pre-order §8.2 reads the site list in: one instantiation
    /// numbers every slot of its own `where` clause before any of them is
    /// discharged, so a nested instantiation's slots land after the next
    /// top-level one's. `Dispatch.Site.parent` is what puts the list back in
    /// order, and this cursor stays what it is — the identity of a slot, not
    /// its position (A.68).
    evidence_next: std.AutoHashMapUnmanaged(u32, u16) = .empty,
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
    /// The declaring type's own parameters, as store variables, during the
    /// eager derivation pass of A.23. A position that resolves to one of
    /// them is `evidence i` — the derived function's own hidden parameter,
    /// not the enclosing declaration's (§9's parts contract). Empty every
    /// other moment.
    type_params: []const Var = &.{},

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

    /// How many method constraints an **unannotated** declaration's inferred
    /// scheme may promote (static-dispatch-spike.md §6.4, §10.11, A.83).
    /// Over it, `promote` reports `too_many_inferred_constraints` and the
    /// declaration promotes NOTHING — which is what bounds the inferred
    /// `where` suffix report 19 §3.1 found unbounded, and, because the next
    /// link then starts from zero, the n(n+1)/2 of report 19 §3 with it.
    ///
    /// An ANNOTATED declaration is never capped: its `where` clause is the
    /// whole set (Rule U2) and it is bounded by the text of the annotation.
    ///
    /// 64 because pre-dispatch `master` already refused the same chain at
    /// ≈64 links — `Render.writeRecord` flattens at most 64 extension links
    /// and the chain was an open record before it was a constraint set — so
    /// no program that checked before the 2026-09-18 adoption is newly
    /// refused (report 19 `results:152-167`).
    pub const max_inferred_constraints = 64;

    /// How many of the constraint names `too_many_inferred_constraints`
    /// prints. Bounding the message is half the point of the cap.
    const named_in_cap_message = 5;

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
        s.promoted.deinit(s.gpa);
        s.resolved_methods.deinit(s.gpa);
        s.resolved_journal.deinit(s.gpa);
        s.superseded.deinit(s.gpa);
        s.deferred.deinit(s.gpa);
        s.evidence_next.deinit(s.gpa);
    }

    /// The instruction's evidence cursor, created at 0 the first time it is
    /// asked for. The caller threads the value it gets through whatever
    /// numbers slots and hands it back to `commitEvidence`; the ENTRY is
    /// what is allocated here, so the write back cannot fail.
    fn evidenceCursor(s: *Solver, inst: Bir.Inst.Index) Error!u16 {
        const gop = try s.evidence_next.getOrPut(s.gpa, @intFromEnum(inst));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        return gop.value_ptr.*;
    }

    /// Give back a cursor `evidenceCursor` handed out. Infallible by
    /// construction: the entry exists, and nothing between the two calls
    /// adds another — a numbering walk instantiates schemes and appends
    /// obligations, it never discharges one.
    fn commitEvidence(s: *Solver, inst: Bir.Inst.Index, next: u16) void {
        const slot = s.evidence_next.getPtr(@intFromEnum(inst)) orelse return;
        slot.* = next;
    }

    /// One constraint held on a variable that is still flex: the variable
    /// and the constraint's index in the store's table.
    const Deferred = struct { v: Var, index: u32 };

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
            .method => try s.method(node),
        }
    }

    /// Record that constraint `at` has been answered (A.57).
    fn markResolved(s: *Solver, at: u32) Error!void {
        const gop = try s.resolved_methods.getOrPut(s.gpa, at);
        if (gop.found_existing) return;
        errdefer _ = s.resolved_methods.remove(at);
        try s.resolved_journal.append(s.gpa, at);
    }

    /// Unwind `resolved_methods` to the length `mark`, for a probe whose
    /// answers have been retracted along with the constraints they were
    /// about.
    fn forgetResolvedSince(s: *Solver, mark: usize) void {
        while (s.resolved_journal.items.len > mark) {
            const at = s.resolved_journal.pop().?;
            _ = s.resolved_methods.remove(at);
        }
    }

    /// The A.75 redirect table: a superseded constraint index mapped to the
    /// one that took its place, journalled so a `tryShape` probe can take
    /// back exactly what it decided (A.35).
    ///
    /// **The journal records the PREVIOUS value and not only the key.** A
    /// key can be re-pointed — a second rebuild supersedes a constraint
    /// the first one already moved — and when the first write happened
    /// before the probe's mark and the second inside it, removing the key
    /// would lose a redirect the probe never made while keeping the value
    /// would keep one it did. Restoring the pair is the only rollback that
    /// is exact either way.
    const Redirects = struct {
        map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        journal: std.ArrayList(Entry) = .empty,

        /// The key was not in the map at all before the write, so the
        /// rollback removes it.
        const absent: u32 = std.math.maxInt(u32);

        const Entry = struct { key: u32, previous: u32 };

        fn deinit(r: *Redirects, gpa: Allocator) void {
            r.map.deinit(gpa);
            r.journal.deinit(gpa);
        }

        /// What `forgetSince` takes the table back to.
        fn mark(r: *const Redirects) usize {
            return r.journal.items.len;
        }

        fn set(r: *Redirects, gpa: Allocator, old: u32, at: u32) Error!void {
            const gop = try r.map.getOrPut(gpa, old);
            const previous: u32 = if (gop.found_existing) gop.value_ptr.* else absent;
            r.journal.append(gpa, .{ .key = old, .previous = previous }) catch |e| {
                if (!gop.found_existing) _ = r.map.remove(old);
                return e;
            };
            gop.value_ptr.* = at;
        }

        fn forgetSince(r: *Redirects, to: usize) void {
            while (r.journal.items.len > to) {
                const entry = r.journal.pop().?;
                if (entry.previous == absent) {
                    _ = r.map.remove(entry.key);
                } else {
                    // The key was there before this mark, so the rollback
                    // is a write and not a removal. Infallible: the entry
                    // exists, so nothing is allocated.
                    r.map.putAssumeCapacity(entry.key, entry.previous);
                }
            }
        }

        fn follow(r: *const Redirects, at: u32) u32 {
            var current = at;
            // Forward-only by construction — a replacement is APPENDED
            // after its inputs — so this is a bound and not a cycle
            // guard.
            while (r.map.get(current)) |next| {
                if (next <= current) break;
                current = next;
            }
            return current;
        }
    };

    /// Record that `old` has been replaced by `at` (A.75): a rebuilt set
    /// copied it to a fresh index, and the obligations that name `old`
    /// belong to the copy.
    fn markSuperseded(s: *Solver, old: u32, at: u32) Error!void {
        if (old == at) return;
        try s.superseded.set(s.gpa, old, at);
    }

    /// Unwind `superseded` to the length `mark`, for a probe whose joins
    /// have been retracted along with the constraints they were about.
    fn forgetSupersededSince(s: *Solver, mark: usize) void {
        s.superseded.forgetSince(mark);
    }

    /// The constraint that answers for `at` today: `at` itself, or
    /// whatever a rebuild replaced it with (A.75).
    fn followConstraint(s: *const Solver, at: u32) u32 {
        return s.superseded.follow(at);
    }

    /// Where a constraint of a rebuilt set came from: the indices it takes
    /// over, and whether one of its inputs was minted by the caller and is
    /// not in the table at all — which makes it unanswered by
    /// construction.
    const Sources = struct {
        a: u32 = none,
        b: u32 = none,
        fresh: bool = false,

        const none: u32 = std.math.maxInt(u32);
    };

    /// Hand the constraint at `at` everything its inputs were: their
    /// obligations, by redirect, and their ANSWER, when every one of them
    /// had one already (A.57, A.75). A rebuild that supersedes an answered
    /// input and an unanswered one is answered for the second alone, and
    /// `joinConstraint` has already dropped the first's sites.
    fn adopt(s: *Solver, at: u32, from: Sources) Error!void {
        var answered = !from.fresh and from.a != Sources.none;
        for ([_]u32{ from.a, from.b }) |old| {
            if (old == Sources.none) continue;
            if (!s.resolved_methods.contains(old)) answered = false;
            try s.markSuperseded(old, at);
        }
        if (answered) try s.markResolved(at);
    }

    /// `name`'s POSITION in `set`. `TypeStore.findConstraint` hands back
    /// the constraint itself; a rebuild needs the index too, to hand the
    /// obligations on (`adopt`).
    fn findConstraintSlot(st: *const TypeStore, set: TypeStore.ConstraintSet.Optional, name: Symbol) ?u32 {
        const n = st.constraintCount(set);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (st.constraintAt(set, i).name == name) return i;
        }
        return null;
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
        try s.generalize(info.rank, true);
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
                // **Rule U1** (static-dispatch-spike.md §6.2): union the two
                // constraint sets onto the surviving root, beside the
                // `equatable` OR and the `Kind` meet. A name on both sides
                // unifies the two method types.
                //
                // The union is computed, the roots are MERGED, and only then
                // are the paired method types unified — in that order,
                // because unifying `a, Int -> a` with `b, Int -> b` unifies
                // `a` with `b`, which re-enters this arm. Merging first
                // makes the re-entry `ra == rb` and stops it dead; doing it
                // the other way round recursed to the depth guard and
                // emitted one dispatch site per level.
                const merged, const pairs = try s.unionConstraints(fa.constraints, fb.constraints);
                defer s.env.scratch.free(pairs);
                _ = st.merge(ra, rb, .{ .flex = .{
                    .name = if (fb.name != .none) fb.name else fa.name,
                    .kind = kind,
                    .equatable = fa.equatable or fb.equatable,
                    .constraints = merged,
                } });
                try s.unifyPending(pairs);
                return true;
            },
            .rigid => |fb| {
                // A rigid variable is a promise about ALL types, so it
                // cannot be narrowed: a flex `number` meeting a rigid `a`
                // means the code wants more than the annotation said.
                if (fa.kind != .any and fa.kind != fb.kind) return false;
                if (fa.equatable and !fb.equatable) return s.fail(.{ .not_equatable_rigid = rb });
                _ = st.merge(ra, rb, cb);
                try s.checkAgainstRigid(fa.constraints, st.find(rb), fb);
                return true;
            },
            .alias, .structure => {
                if (fa.kind != .any and !s.kindAccepts(fa.kind, rb)) {
                    return s.fail(.{ .kind_not_satisfied = .{ .kind = fa.kind } });
                }
                if (fa.equatable) try s.register(.{ .kind = .equatable, .v = rb, .region = s.region });
                try s.deferConstraints(fa.constraints, rb);
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
                // Rule U2 from the other side: the rigid's set is what its
                // `where` clause declared and is never extended (§6.2).
                _ = st.merge(ra, rb, .{ .rigid = fa });
                try s.checkAgainstRigid(fb.constraints, st.find(ra), fa);
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
                try s.deferConstraints(fb.constraints, ra);
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
                try s.deferConstraints(fb.constraints, ra);
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
            // A method call's arguments are a range inside its payload, and
            // the receiver is not one of them (static-dispatch-spike.md
            // §1.4). Without this arm every argument of a dot-call
            // underlined the whole call.
            .method_call => {
                const m = bir.extraData(@enumFromInt(bir.instData(region).rhs), Bir.MethodCall);
                return bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index);
            },
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
        const owner: Bir.Inst.OptionalIndex = @enumFromInt(node.b);
        const site = owner.unwrap() orelse node.region;
        // Both halves number the SAME slots, from the same base: an
        // imported scheme has its constraints numbered by
        // `Schemes.instantiate` as it copies them, and `tagInstantiated`
        // then walks the copy and re-derives the same indices (its
        // constraints are all below `mark`, so it writes nothing). Two
        // cursors off one base, and the cursor the instruction keeps is
        // whichever went further.
        const base = try s.evidenceCursor(site);
        var read_cursor = base;
        // A slot this instruction owns outright: nothing of its own
        // resolution asked for it, so it is a ROOT of the pre-order forest
        // `Dispatch.finish` walks (A.68).
        const scheme = (try s.schemeOf(node.region, .{ .inst = site, .next = &read_cursor, .parent = Dispatch.Site.no_parent })) orelse {
            s.commitEvidence(site, read_cursor);
            s.poison(target);
            return;
        };
        const mark: u32 = @intCast(s.store().constraints.items.len);
        const copy = try s.makeCopy(scheme);
        // A reference to a declaration of the CURRENT binding group is used
        // at its monomorphic type (`checker.md` §6.1), so `makeCopy` hands
        // back the scheme itself and there is nothing new to tag. The call
        // still has to forward the evidence, so its site is APPENDED to the
        // shared constraint instead — which is how `even`/`odd` with an
        // inferred `where` get the arguments their recursion needs.
        const shared = s.env.bir.instTag(node.region) == .top;
        var tag_cursor = base;
        // `copy_constrained` false means the walk `makeCopy` just did met
        // no method constraint, so the walk `tagInstantiated` would do over
        // the same nodes has nothing to number: it would leave `tag_cursor`
        // where it is and write no site. Skipping it is what keeps the
        // numbering off the back of code that dispatches on nothing — it is
        // one instantiation's second full traversal of its own type.
        if (s.copy_constrained) {
            try s.tagInstantiated(copy, site, &tag_cursor, mark, shared, Dispatch.Site.no_parent);
        }
        // Nothing numbered a slot, so the cursor goes back exactly as it
        // came out and the write is a lookup that stores what it read.
        const next = @max(read_cursor, tag_cursor);
        if (next != base) s.commitEvidence(site, next);
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
    fn schemeOf(s: *Solver, region: Bir.Inst.Index, site: ?Schemes.Site) Error!?Var {
        const bir = s.env.bir;
        const data = bir.instData(region);
        switch (bir.instTag(region)) {
            .local => return s.env.localVar(data.lhs),
            .top => {
                if (data.lhs >= s.env.decl_scheme.len) return null;
                return s.env.decl_scheme[data.lhs].unwrap();
            },
            .ctor => return try s.ctorType(data.lhs),
            .ext_value => return try s.importedValue(@enumFromInt(data.lhs), data.rhs, site),
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
        const v = try Schemes.instantiateCtor(iface, s.env.types.refIds(module), s.store(), index, type_id, s.rank, s.env.scratch) orelse return null;
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
    fn importedValue(s: *Solver, module: Graph.Index, index: u32, site: ?Schemes.Site) Error!?Var {
        if (module.int() >= s.env.interfaces.len) return null;
        const iface = &s.env.interfaces[module.int()];
        if (index >= iface.values.len) return null;
        const scheme_index = iface.values[index].scheme;
        if (scheme_index == .none) return null;
        const mark = s.store().count();
        const from: u32 = @intCast(s.store().constraints.items.len);
        const v = try Schemes.instantiate(iface, s.env.types.refIds(module), s.store(), @intFromEnum(scheme_index), s.rank, s.env.scratch, site);
        try s.adoptSince(mark);
        // **An imported scheme's constraints need obligations exactly as a
        // local one's do** (A.57). `Schemes.instantiate` writes their
        // dispatch sites and stops there; `tagInstantiated` then sees
        // indices BELOW its own mark — the constraints were created before
        // it was called — and registers nothing. So `Gen.before 1 2`, with
        // `before : a, a -> Bool where a.compare : …` in another module,
        // got no evidence site at all: the `number` flex never meets a
        // structure, Rule U3 never fires, and the emitted call was one
        // argument short of the function it called. Float, `String` and an
        // annotated parameter all did get theirs, which is how long it hid.
        if (site != null) try s.registerInstantiated(v, from);
        return v;
    }

    /// One obligation per constraint an instantiation created, in the
    /// canonical order of §7.2 so the drain is the same on every run
    /// (CLAUDE.md rule 5). `from` is the constraint table's length before
    /// the instantiation: anything below it belongs to something else.
    fn registerInstantiated(s: *Solver, copy: Var, from: u32) Error!void {
        const st = s.store();
        var order: std.ArrayList(Var) = .empty;
        defer order.deinit(s.env.scratch);
        try Schemes.quantifierOrder(st, s.env.interner, copy, &order, s.env.scratch);
        for (order.items) |root| {
            const set = st.flagsOf(root).constraints;
            const n = st.constraintCount(set);
            if (n == 0) continue;
            const base = st.constraint_sets.items[set.unwrap().?.int()].start;
            for (0..n) |j| {
                const at = base + @as(u32, @intCast(j));
                if (at < from) continue;
                try s.registerMethod(root, at);
            }
        }
    }

    /// Register the obligation that answers constraint `at` on `root`. Its
    /// `origin` is the instruction the instantiation tagged the constraint
    /// with — the call the author wrote (§6.2, A.37) — and `s.region` only
    /// when there is none.
    fn registerMethod(s: *Solver, root: Var, at: u32) Error!void {
        const st = s.store();
        const c = st.constraints.items[at];
        const sites = st.constraintSites(c);
        try s.register(.{
            .kind = .method,
            .v = root,
            .region = c.region,
            .origin = if (sites.len != 0) sites[0].inst else s.region,
            .index = at,
        });
        s.counters.constraints_deferred += 1;
    }

    /// Elm's `makeCopy`: copy a generalised type, memoising through the
    /// descriptor's `copy` field so internal sharing survives
    /// (`let x = (y, y)` copies `y` once, design §7 #4). The memo is
    /// cleared through `touched` rather than by walking the copy again.
    pub fn makeCopy(s: *Solver, v: Var) Error!Var {
        const start = s.touched.items.len;
        s.copy_constrained = false;
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
        if (s.depth > max_depth) {
            s.copy_constrained = true;
            return v;
        }

        const st = s.store();
        const root = st.find(v);
        if (st.copy(root).unwrap()) |existing| return existing;
        // Only a GENERALISED variable is copied. Everything else is shared
        // with the enclosing scope and must stay the same node — that is
        // what makes a lambda parameter monomorphic.
        if (st.rank(root) != TypeStore.generalized) {
            // NOT descended into, and `Schemes.orderWalk` does descend into
            // it, so nothing here can say whether something inside carries a
            // constraint: `copy_constrained` has to assume it does, unless
            // the store holds no constraint at all. Reading the root's own
            // content to answer exactly for a shared LEAF was measured and
            // is SLOWER — the branch costs more than the skips it buys.
            if (st.constraints.items.len != 0) s.copy_constrained = true;
            return root;
        }

        const content = st.content(root);
        switch (content) {
            .flex, .rigid => |flags| if (flags.constraints != .none) {
                s.copy_constrained = true;
            },
            else => {},
        }
        const copy = try s.fresh(content);
        st.setCopy(root, copy.toOptional());
        try s.touched.append(s.gpa, root);

        switch (content) {
            .err => {},
            // **§6.4**: a constraint's `fn_var` is copied through the SAME
            // memo as the rest of the scheme. Without it the copy shares
            // the scheme's method type, so discharging one use binds the
            // SCHEME — `twice : a, Int -> a where a.scale : …` came back
            // from its first call site as `Metre, Int -> Metre` and every
            // later caller was checked against that.
            .flex => |flags| {
                if (flags.constraints != .none) {
                    st.setContent(copy, .{ .flex = .{
                        .name = flags.name,
                        .kind = flags.kind,
                        .equatable = flags.equatable,
                        .constraints = try s.copyConstraints(flags.constraints),
                    } });
                }
            },
            // Instantiating an annotation's promise turns it into an
            // ordinary variable: inside the body `a` is rigid, at a call
            // site it is whatever the caller needs (Elm's `makeCopyHelp`).
            .rigid => |flags| st.setContent(copy, .{ .flex = .{
                .name = flags.name,
                .kind = flags.kind,
                .equatable = flags.equatable,
                .constraints = try s.copyConstraints(flags.constraints),
            } }),
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

    /// A fresh constraint set whose method types are copies, made through
    /// the enclosing `makeCopy`'s memo so two constraints that mention the
    /// same variable still share it after the copy (§6.4).
    ///
    /// The new constraints carry NO sites: the sites of an instantiated
    /// scheme are the instantiating instruction's, and `tagInstantiated`
    /// assigns them in the canonical order of §7.2 once the copy is whole.
    fn copyConstraints(s: *Solver, set: TypeStore.ConstraintSet.Optional) Error!TypeStore.ConstraintSet.Optional {
        const st = s.store();
        const n = st.constraintCount(set);
        if (n == 0) return .none;
        var built: std.ArrayList(TypeStore.MethodConstraint) = .empty;
        defer built.deinit(s.env.scratch);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = st.constraintAt(set, i);
            try built.append(s.env.scratch, .{
                .name = c.name,
                .fn_var = try s.copyHelp(c.fn_var),
                .region = c.region,
                .origin = c.origin,
                .sites = .empty,
            });
        }
        return (try st.addConstraints(built.items)).toOptional();
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
            const resolved_len = s.resolved_journal.items.len;
            const superseded_len = s.superseded.mark();
            const deferred_len = s.deferred.items.len;
            // The dispatch builder and the diagnostics are the other two
            // things a retracted probe must not leave behind (A.35, B3):
            // §6.2 registers obligations from INSIDE `unify`, so
            // `checkAgainstRigid` — which appends sites and raises
            // `missing_where_constraint` — is reachable from here. A site
            // the checker retracted is an argument the emitter would pass
            // anyway, and a message about a shape the compiler decided
            // against is worse than no message.
            const dispatch_len = s.env.dispatch.lengths();
            const report_mark = s.reporter.mark();
            const snapshot = s.store().beginSpeculation();
            const ok = try s.tryShapeOnce(id, scrutinee, info);
            if (ok) {
                s.store().commit(snapshot);
                // The shape the guess settled on is the one thing about a
                // `?` the backend cannot work out for itself: there is no
                // pattern at a `?` to read `Nothing` or `Err` off, and
                // `backend.md` §3 gives it no types. It crosses in the
                // dispatch table like every other decision of this phase
                // (§7.1), and only from the guess that COMMITTED — the
                // rollback above truncates what a retracted one wrote.
                try s.env.dispatch.addTry(.{
                    .inst = node.region,
                    .shape = if (id == wk.result) .result else .maybe,
                });
                return;
            }
            const exact = s.store().rollback(snapshot);
            (try s.pool(s.rank)).shrinkRetainingCapacity(pool_len);
            (try s.obligationsAt(s.rank)).shrinkRetainingCapacity(obligation_len);
            // A retracted probe's constraints are gone from the store's
            // table and their indices will be handed to other constraints,
            // so what this run decided about them has to go too (A.57).
            s.forgetResolvedSince(resolved_len);
            // A redirect outlives neither: it points at an index the
            // rollback has truncated away and will hand to some other
            // constraint (A.75).
            s.forgetSupersededSince(superseded_len);
            s.deferred.shrinkRetainingCapacity(deferred_len);
            s.env.dispatch.shrink(dispatch_len);
            s.reporter.rollbackTo(report_mark);
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
    pub fn generalize(s: *Solver, young_rank: u32, is_let: bool) Error!void {
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
                continue;
            }
            // **§6.4 rule (a)**: a `let` binding is never generalised over a
            // variable that carries a method constraint. It is held at the
            // enclosing rank instead, to be generalised — or promoted, or
            // reported — at the DECLARATION's boundary, so no constraint
            // ever straddles a boundary and every constraint that reaches
            // promotion sits on a variable the declaration itself
            // quantifies. That is what removes Roc's promoted-requirements
            // side table (A.30); the price is that a constrained `let`
            // helper is monomorphic, and `method_constraint_mismatch` is
            // what a second use at another type gets (§11).
            if (is_let and young_rank > TypeStore.outermost and st.flagsOf(v).constraints != .none) {
                // Remembered for the one message the boundary produces
                // (`Env.monomorphic`): by the time the second use fails,
                // the constraint is gone and only this says why.
                const flags = st.flagsOf(v);
                if (st.constraintCount(flags.constraints) != 0) {
                    try s.env.monomorphic.append(s.env.scratch, .{
                        .v = v,
                        .method = st.constraintAt(flags.constraints, 0).name,
                    });
                }
                st.setRank(v, young_rank - 1);
                try (try s.pool(young_rank - 1)).append(s.gpa, v);
                continue;
            }
            st.setRank(v, TypeStore.generalized);
            s.counters.generalisations += 1;
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
        var exhausted = true;
        while (rounds < 1 << 20) : (rounds += 1) {
            const o = blk: {
                const list = try s.obligationsAt(rank);
                if (i >= list.items.len) {
                    exhausted = false;
                    break;
                }
                break :blk list.items[i];
            };
            i += 1;
            s.counters.obligations += 1;
            switch (o.kind) {
                .equatable => try s.dischargeEquatable(o),
                .interpolatable => try s.dischargeInterpolatable(o),
                .tuple_index => try s.dischargeTupleIndex(o),
                .method => try s.dischargeMethod(o),
            }
        }
        // **A.27**: an exhausted budget used to fall out of the `while` and
        // clear the list, which left a module CHECKED with undischarged
        // obligations — the hole `checker.md` §5's "a guard that poisons
        // must report first" exists to close. A method obligation can
        // register more (§6.3.1 step 3), so the bound is reachable by input
        // and not only by a compiler bug.
        if (exhausted) {
            const list = try s.obligationsAt(rank);
            const region = if (list.items.len > i) list.items[i].origin else s.region;
            try s.reporter.nestingTooDeep(region, max_depth);
            for (list.items[i..]) |pending| s.poison(pending.v);
            // In a debug build this IS a compiler bug and a message would
            // hide it.
            if (std.debug.runtime_safety) @panic("obligation drain loop exhausted its budget");
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
                // `==` folds the two into one answer, as it always has:
                // §3.4's `equatable` marker is the whole story it tells and
                // `contains_function` is only reachable from the `compare`
                // gate (`walkComparable`).
                .opaque_type, .contains_function => try s.reporter.notEquatable(o.region, o.v, .opaque_type),
            },
        }
    }

    const EquatableResult = enum {
        ok,
        /// The receiver IS a function.
        function,
        /// A named type the gate refused, with no more to say.
        opaque_type,
        /// A named type the gate refused BECAUSE a function is reachable
        /// inside it — one level down or ten (A.58). §10.3 has a sentence
        /// of its own for this, and it is the one that helps.
        contains_function,
        unknown,
    };

    /// Walk a concrete type ONCE, with a mark as the cycle guard: no
    /// function anywhere, and every named type declared equatable
    /// (checker.md §6.4, Appendix B). The walk happens here, at discharge,
    /// and never inside unification — which is the whole point of §3.1.
    fn walkEquatable(s: *Solver, root_var: Var) EquatableResult {
        return walkDerivable(s, root_var, .eq);
    }

    /// The same walk asking whether `<` can be answered at every named type
    /// it reaches (A.54). `compare` has no `equatable` marker to lean on, so
    /// this is the only gate it has — and it has to be the same one the
    /// eager pass of A.23 excludes a type by, or a use would name a function
    /// nobody emitted.
    fn walkComparable(s: *Solver, root_var: Var) EquatableResult {
        return walkDerivable(s, root_var, .compare);
    }

    fn walkDerivable(s: *Solver, root_var: Var, kind: Dispatch.Derived.Kind) EquatableResult {
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
                        const ok = switch (kind) {
                            .eq => s.env.types.isEquatable(a.type),
                            .compare => s.env.types.isComparable(a.type),
                        };
                        // Which of the two gates said no is not a question
                        // the gate can answer — both fold several causes
                        // into one bit — so the ONE cause §10.3 has a
                        // better sentence for is kept beside them (A.58).
                        if (!ok) return if (s.env.types.hasFunction(a.type)) .contains_function else .opaque_type;
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

    // ---- Method constraints and dispatch (static-dispatch-spike.md §6) ---

    /// **Rule U0** (§6.2, A.34): the `method` node. A receiver whose root is
    /// already concrete has its method resolved HERE, inline, before the
    /// argument constraints that follow it in the same `and_` are solved.
    fn method(s: *Solver, node: Constrain.Node) Error!void {
        const info = s.tree.extraData(node.b, Constrain.Method);
        const receiver: Var = @enumFromInt(node.a);
        const st = s.store();
        // Site 0, the callee (§7.2) — and the first slot this instruction
        // hands out, so it opens the cursor every later one continues.
        const first_index = try s.evidenceCursor(node.region);
        s.commitEvidence(node.region, first_index +| 1);
        const sites = try st.addConstraintSites(&.{.{ .inst = node.region, .evidence_index = first_index }});
        const c: TypeStore.MethodConstraint = .{
            .name = info.name,
            .fn_var = info.fn_var,
            .region = node.region,
            .origin = if (info.kind == 1)
                .type_dispatch
            else if (info.origin != @intFromEnum(Bir.WellKnown.none))
                .well_known
            else
                .dot_call,
            .sites = sites,
        };
        const root, const content = st.resolved(receiver);
        switch (content) {
            .flex => {
                // The obligation names the index `c`'s sites ended up at,
                // which a join makes a different constraint from the one
                // that was just appended (A.75).
                const at = try s.attachConstraint(root, c, node.region, null);
                try s.register(.{
                    .kind = .method,
                    .v = root,
                    .region = node.region,
                    .origin = node.region,
                    .index = at,
                });
                s.counters.constraints_deferred += 1;
            },
            // Concrete — or rigid, which is what a `type_dispatch`'s
            // variable always is. Resolve now (Rule U0).
            else => try s.resolveMethod(c, root, content, node.region, true, info, null),
        }
    }

    /// Add one constraint to a flex root's set, by Rule U1: a name already
    /// present unifies the two method types and keeps both sites.
    ///
    /// **Appends when it can.** Rebuilding the whole set on every attach is
    /// quadratic, and a constraint chain is exactly the input that walks
    /// into it: at n = 800 it was 7.3x slower than the chain without
    /// dispatch and `constraints_promoted` read n(n+1)/2. A set is a
    /// half-open RANGE of an append-only list, so when the old range ends at
    /// the tail the new set is "that range, one longer" and costs one
    /// append; otherwise it costs one copy, which happens only when
    /// something else appended in between.
    ///
    /// `at` is `c`'s own index when the caller has one — an obligation
    /// being folded back (§6.3's `flex` row) — and null when `c` was
    /// minted for this call and is not in the table yet. Either way the
    /// answer is the index `c`'s sites live at afterwards, which is what
    /// the obligation for them must name (A.75).
    ///
    /// **Folding a constraint back onto the set it is already in is a
    /// no-op, and finding that out must not cost the set.** Every deferred
    /// constraint comes back through §6.3's `flex` row once per obligation,
    /// and by then `at` — followed through A.75's redirects — is the very
    /// slot the constraint occupies: the join below would copy the whole
    /// set to rebuild it byte for byte, and `adopt` would then redirect
    /// every index to itself. That is O(set) per obligation, which made the
    /// UNANNOTATED CHAIN cubic in its length rather than quadratic: link k
    /// defers k constraints over a set of k, so n = 400 spent 3.1 s and
    /// 3.3 GB where n = 100 spent 51 ms and 53 MB, and n = 1000 reached
    /// 29 GiB and was killed. The quadratic underneath is the feature
    /// (`constraints_promoted` is n(n+1)/2 on this input and always was);
    /// the third factor was bookkeeping (A.81).
    fn attachConstraint(
        s: *Solver,
        root: Var,
        c: TypeStore.MethodConstraint,
        region: Bir.Inst.Index,
        at: ?u32,
    ) Error!u32 {
        const st = s.store();
        const flags = st.flagsOf(root);
        const n = st.constraintCount(flags.constraints);
        const old_base: u32 = if (flags.constraints.unwrap()) |existing_set|
            st.constraint_sets.items[existing_set.int()].start
        else
            0;

        // Already this set's slot for that name: there is nothing to join,
        // nothing to copy and nothing to redirect. The name is compared as
        // well as the range, so a redirect that landed somewhere else falls
        // through to the rebuild instead of being trusted.
        if (at) |x| {
            if (x >= old_base and x - old_base < n and st.constraints.items[x].name == c.name) return x;
        }

        // The common case by far: a name this variable does not carry yet.
        if (st.findConstraint(flags.constraints, c.name) == null) {
            const set = try st.extendConstraints(flags.constraints, c);
            s.counters.constraints_created += 1;
            s.setConstraints(root, flags, set);
            const range = st.constraint_sets.items[set.unwrap().?.int()];
            // `extendConstraints` appends in place when the old range ends
            // at the tail, and COPIES the range otherwise — and a copy
            // leaves every input behind at an index obligations still name
            // (A.75).
            if (range.start != old_base) {
                var j: u32 = 0;
                while (j < n) : (j += 1) try s.adopt(range.start + j, .{ .a = old_base + j });
            }
            const index = range.start + range.len - 1;
            try s.adopt(index, if (at) |x| .{ .a = x } else .{ .fresh = true });
            return index;
        }

        var built: std.ArrayList(TypeStore.MethodConstraint) = .empty;
        defer built.deinit(s.env.scratch);
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(s.env.scratch);
        // One entry per position of `built`, in the same order: what each
        // constraint of the rebuilt set takes over (A.75).
        var sources: std.ArrayList(Sources) = .empty;
        defer sources.deinit(s.env.scratch);
        var joined_slot: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const existing = st.constraintAt(flags.constraints, i);
            const existing_at = old_base + i;
            if (existing.name != c.name) {
                try built.append(s.env.scratch, existing);
                try sources.append(s.env.scratch, .{ .a = existing_at });
                continue;
            }
            const first, const second, const first_at, const second_at = if (existing.region.int() <= c.region.int())
                .{ existing, c, @as(?u32, existing_at), at }
            else
                .{ c, existing, at, @as(?u32, existing_at) };
            joined_slot = i;
            try built.append(s.env.scratch, try s.joinConstraint(first, second, first_at, second_at));
            try sources.append(s.env.scratch, if (at) |x|
                .{ .a = existing_at, .b = x }
            else
                .{ .a = existing_at, .fresh = true });
            try pending.append(s.env.scratch, .{ .younger = second, .older = first });
        }
        const set = try st.addConstraints(built.items);
        s.counters.constraints_merged += 1;
        s.setConstraints(root, flags, set.toOptional());
        // Before anything re-enters: `unifyPending` can rebuild this very
        // set again, and the second rebuild has to find the first one's
        // redirects already in place.
        const base = st.constraint_sets.items[set.int()].start;
        for (sources.items, 0..) |from, slot| try s.adopt(base + @as(u32, @intCast(slot)), from);
        // After the set is in place, for the same reason Rule U1 merges
        // before it unifies: unifying two method types unifies the variables
        // they are about, and that re-enters here.
        const outer = s.region;
        defer s.region = outer;
        s.region = region;
        try s.unifyPending(pending.items);
        return base + joined_slot;
    }

    fn setConstraints(s: *Solver, root: Var, flags: TypeStore.Flags, set: TypeStore.ConstraintSet.Optional) void {
        const st = s.store();
        const with: TypeStore.Flags = .{
            .name = flags.name,
            .kind = flags.kind,
            .equatable = flags.equatable,
            .constraints = set,
        };
        st.setContent(root, switch (st.content(root)) {
            .rigid => .{ .rigid = with },
            else => .{ .flex = with },
        });
    }

    /// Drop the constraint named `name` from `root`'s set, because one of
    /// the two mechanisms `fast-compiler.md` §3.1 keeps already answers it
    /// (`builtinRigidTarget`). The set is rebuilt, never edited (§6.1
    /// invariant 2); leaving the constraint on would promote it, and
    /// `isEven n = n < 1` would publish
    /// `number -> Bool where number.compare : …` in its interface.
    ///
    /// Everything it KEEPS is copied to a fresh index, exactly as a join or
    /// a union copies, so every kept constraint's old index is superseded
    /// by its new one (A.75) — otherwise the obligations already
    /// registered over the old range stay live beside the ones over the
    /// new one and answer the same sites twice. The dropped constraint is
    /// not redirected: the caller has just answered it.
    fn detachConstraint(s: *Solver, root: Var, name: Symbol) Error!void {
        const st = s.store();
        const flags = st.flagsOf(root);
        const n = st.constraintCount(flags.constraints);
        if (n == 0) return;
        const old_base: u32 = if (flags.constraints.unwrap()) |existing|
            st.constraint_sets.items[existing.int()].start
        else
            0;
        var kept: std.ArrayList(TypeStore.MethodConstraint) = .empty;
        defer kept.deinit(s.env.scratch);
        // The old index of each kept constraint, in the order they are
        // rebuilt in, so the redirects can be written once the new range
        // exists.
        var kept_from: std.ArrayList(u32) = .empty;
        defer kept_from.deinit(s.env.scratch);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = st.constraintAt(flags.constraints, i);
            if (c.name == name) continue;
            try kept.append(s.env.scratch, c);
            try kept_from.append(s.env.scratch, old_base + i);
        }
        const set: TypeStore.ConstraintSet.Optional = if (kept.items.len == 0)
            .none
        else
            (try st.addConstraints(kept.items)).toOptional();
        s.setConstraints(root, flags, set);
        if (set.unwrap()) |built| {
            const base = st.constraint_sets.items[built.int()].start;
            for (kept_from.items, 0..) |from, slot| {
                try s.adopt(base + @as(u32, @intCast(slot)), .{ .a = from });
            }
        }
    }

    /// Two constraints of the same name on one variable: one constraint per
    /// `(variable, name)` (§6.1 invariant 3), so the two method types have
    /// to agree. The surviving constraint answers BOTH sites.
    ///
    /// The two indices are the inputs' own, or null for an input the
    /// caller minted and has not stored. An input that was ALREADY
    /// answered contributes its obligation, through `adopt`, and not its
    /// sites: a target was emitted for them, and emitting one again is the
    /// same argument passed twice (A.57, A.75).
    fn joinConstraint(
        s: *Solver,
        older: TypeStore.MethodConstraint,
        younger: TypeStore.MethodConstraint,
        older_at: ?u32,
        younger_at: ?u32,
    ) Error!TypeStore.MethodConstraint {
        const st = s.store();
        // Deduplicated: the same constraint is folded into its own set
        // again when its obligation is discharged against a still-flex
        // receiver (§6.3's `flex` row), and a site emitted twice is an
        // argument passed twice.
        const answered: []const TypeStore.ConstraintSite = &.{};
        const old_sites = if (s.isAnswered(older_at)) answered else st.constraintSites(older);
        const new_sites = if (s.isAnswered(younger_at)) answered else st.constraintSites(younger);
        var buffer = try s.env.scratch.alloc(TypeStore.ConstraintSite, old_sites.len + new_sites.len);
        defer s.env.scratch.free(buffer);
        var len: usize = 0;
        for ([_][]const TypeStore.ConstraintSite{ old_sites, new_sites }) |run| {
            outer: for (run) |site| {
                for (buffer[0..len]) |seen| {
                    if (seen.inst == site.inst and seen.evidence_index == site.evidence_index) continue :outer;
                }
                buffer[len] = site;
                len += 1;
            }
        }
        const joined = buffer[0..len];
        return .{
            .name = older.name,
            .fn_var = older.fn_var,
            .region = older.region,
            .origin = older.origin,
            .sites = try st.addConstraintSites(joined),
        };
    }

    /// Whether the constraint at `at` has been answered already. A null
    /// index is one the caller minted and has not stored, which no route
    /// can have answered yet.
    fn isAnswered(s: *const Solver, at: ?u32) bool {
        return if (at) |x| s.resolved_methods.contains(x) else false;
    }

    /// One method type pair the caller must unify once the roots are
    /// merged, and where to report if it does not fit.
    const Pending = struct { younger: TypeStore.MethodConstraint, older: TypeStore.MethodConstraint };

    /// **Rule U1**: union two sets onto one fresh range. Neither input is
    /// mutated (§6.1 invariant 2), and nothing is unified — the pairs that
    /// have to agree come back for the caller to unify AFTER the merge.
    fn unionConstraints(
        s: *Solver,
        a: TypeStore.ConstraintSet.Optional,
        b: TypeStore.ConstraintSet.Optional,
    ) Error!struct { TypeStore.ConstraintSet.Optional, []Pending } {
        const st = s.store();
        if (a == .none) return .{ b, &.{} };
        if (b == .none) return .{ a, &.{} };
        s.counters.constraints_merged += 1;
        var built: std.ArrayList(TypeStore.MethodConstraint) = .empty;
        defer built.deinit(s.env.scratch);
        var pending: std.ArrayList(Pending) = .empty;
        errdefer pending.deinit(s.env.scratch);
        // One entry per position of `built`: both sides are COPIED onto
        // the fresh range, so every index either side held is superseded
        // by one of them (A.75).
        var sources: std.ArrayList(Sources) = .empty;
        defer sources.deinit(s.env.scratch);
        const a_base = st.constraint_sets.items[a.unwrap().?.int()].start;
        const b_base = st.constraint_sets.items[b.unwrap().?.int()].start;
        const na = st.constraintCount(a);
        var i: u32 = 0;
        while (i < na) : (i += 1) {
            const left = st.constraintAt(a, i);
            const left_at = a_base + i;
            if (findConstraintSlot(st, b, left.name)) |slot| {
                const right = st.constraintAt(b, slot);
                const right_at = b_base + slot;
                const first, const second, const first_at, const second_at = if (left.region.int() <= right.region.int())
                    .{ left, right, left_at, right_at }
                else
                    .{ right, left, right_at, left_at };
                try pending.append(s.env.scratch, .{ .younger = second, .older = first });
                try built.append(s.env.scratch, try s.joinConstraint(first, second, first_at, second_at));
                try sources.append(s.env.scratch, .{ .a = left_at, .b = right_at });
            } else {
                try built.append(s.env.scratch, left);
                try sources.append(s.env.scratch, .{ .a = left_at });
            }
        }
        const nb = st.constraintCount(b);
        var j: u32 = 0;
        while (j < nb) : (j += 1) {
            const right = st.constraintAt(b, j);
            if (st.findConstraint(a, right.name) == null) {
                try built.append(s.env.scratch, right);
                try sources.append(s.env.scratch, .{ .a = b_base + j });
            }
        }
        const set = try st.addConstraints(built.items);
        const base = st.constraint_sets.items[set.int()].start;
        for (sources.items, 0..) |from, slot| try s.adopt(base + @as(u32, @intCast(slot)), from);
        return .{ set.toOptional(), try pending.toOwnedSlice(s.env.scratch) };
    }

    fn unifyPending(s: *Solver, pairs: []const Pending) Error!void {
        for (pairs) |pair| {
            if (try s.unifyQuiet(pair.older.fn_var, pair.younger.fn_var)) continue;
            try s.reporter.methodConstraintMismatch(
                pair.younger.region,
                pair.older.region,
                pair.younger.name,
                pair.younger.fn_var,
                pair.older.fn_var,
            );
            s.poison(pair.older.fn_var);
            s.poison(pair.younger.fn_var);
        }
    }

    /// **Rule U2**: every constraint on a flex meeting a rigid must be
    /// present by name on the rigid, which carries exactly what its `where`
    /// clause declared and is never extended.
    fn checkAgainstRigid(
        s: *Solver,
        set: TypeStore.ConstraintSet.Optional,
        rigid_root: Var,
        flags: TypeStore.Flags,
    ) Error!void {
        const st = s.store();
        const n = st.constraintCount(set);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = st.constraintAt(set, i);
            // Every arm below ANSWERS this constraint, rightly or wrongly,
            // and the obligation its instantiation registered must not
            // answer it a second time (A.57).
            try s.markResolved(st.constraint_sets.items[set.unwrap().?.int()].start + i);
            if (st.findConstraint(flags.constraints, c.name)) |rc| {
                if (!try s.unifyQuiet(rc.fn_var, c.fn_var)) {
                    try s.reporter.methodConstraintMismatch(c.region, rc.region, c.name, c.fn_var, rc.fn_var);
                    s.poison(c.fn_var);
                } else if (s.evidenceIndexOf(rigid_root, c.name)) |k| {
                    try s.emitSites(c, .{ .evidence = k });
                } else {
                    try s.reporter.internal(s.region, "a `where` constraint has no evidence parameter");
                    try s.emitSites(c, .err);
                }
                continue;
            }
            if (s.builtinRigidTarget(flags, c)) |target| {
                try s.emitSites(c, target);
                continue;
            }
            // At the FLEX's region — the call in the body that needs the
            // method — and never at the annotation (§6.2 Rule U2, §10.4).
            try s.reporter.missingWhereConstraint(s.region, c.origin == .where_clause, flags.name, c.name, c.fn_var);
        }
    }

    /// **Rule U3**: a flex carrying constraints meets a structure or an
    /// alias. Do NOT walk: register one obligation per constraint on the
    /// concrete variable, exactly as a flagged-`equatable` flex does.
    fn deferConstraints(s: *Solver, set: TypeStore.ConstraintSet.Optional, concrete: Var) Error!void {
        const st = s.store();
        const n = st.constraintCount(set);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const index = st.constraint_sets.items[set.unwrap().?.int()].start + i;
            // **§6.2, A.37**: `origin` is the instruction in THIS module
            // whose instantiation created the obligation — the call the
            // author wrote — and not wherever the unification that
            // discovered it happened to be. A constraint that arrived on an
            // instantiated scheme already knows it: its dispatch site is
            // that very instruction. `s.region` is the fallback for a
            // constraint raised here, where the two coincide.
            try s.registerMethod(concrete, index);
        }
    }

    fn dischargeMethod(s: *Solver, o: Obligation) Error!void {
        const st = s.store();
        // A rebuilt set moved the constraint this obligation was
        // registered for, and the copy is what answers now (A.75) —
        // followed BEFORE the answered test, or the copy of an answered
        // constraint answers its sites a second time.
        const at = s.followConstraint(o.index);
        if (at >= st.constraints.items.len) return;
        // **Answered once** (A.57): see `resolved_methods`. Emitting the
        // site twice is an argument passed twice and reporting the failure
        // twice is two copies of one message.
        if (s.resolved_methods.contains(at)) return;
        const c = st.constraints.items[at];
        const root, const content = st.resolved(o.v);
        switch (content) {
            .err => {},
            // Fold and stop: it will be promoted at generalisation or
            // discharged later against a concrete type. The
            // accumulate-until-nominal shape `dischargeEquatable` has.
            .flex => |flags| {
                // Unless the variable already answers it: a `number` is
                // `Int` or `Float` and an `equatable` variable has an `eq`
                // by §3.4, so folding either would promote a constraint the
                // two mechanisms `fast-compiler.md` §3.1 keeps already
                // discharge. `isEven n = n < 2` would otherwise infer
                // `number -> Bool where number.compare : …`.
                if (s.builtinRigidTarget(flags, c)) |target| {
                    try s.markResolved(at);
                    try s.emitSites(c, target);
                    try s.detachConstraint(root, c.name);
                    return;
                }
                const folded = try s.attachConstraint(root, c, o.origin, at);
                try s.deferred.append(s.gpa, .{ .v = root, .index = folded });
            },
            else => {
                try s.markResolved(at);
                const outer = s.region;
                defer s.region = outer;
                s.region = o.origin;
                try s.resolveMethod(c, root, content, o.origin, false, null, at);
            },
        }
    }

    /// The §6.3 discharge table: resolve `c` against a receiver that is no
    /// longer a variable, unify the method's type with the constraint's,
    /// and record the site's target.
    ///
    /// `immediate` distinguishes Rule U0's inline resolution from a
    /// deferred obligation, and it changes exactly one row: a RECORD
    /// receiver whose type was already known is a field call (§1.2), while
    /// a constraint that was deferred and only later met a record is
    /// `no_methods_on_shape` (§6.3, §11's deferred-receiver row).
    fn resolveMethod(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        root: Var,
        content: TypeStore.Content,
        origin: Bir.Inst.Index,
        immediate: bool,
        info: ?Constrain.Method,
        at: ?u32,
    ) Error!void {
        s.counters.constraints_discharged += 1;
        const st = s.store();
        switch (content) {
            .err => return,
            .flex => |flags| {
                if (s.builtinRigidTarget(flags, c)) |target| {
                    try s.emitSites(c, target);
                    try s.detachConstraint(root, c.name);
                    return;
                }
                _ = try s.attachConstraint(root, c, origin, at);
                return;
            },
            .rigid => |flags| {
                if (st.findConstraint(flags.constraints, c.name)) |rc| {
                    if (!try s.unifyQuiet(rc.fn_var, c.fn_var)) {
                        try s.reporter.methodConstraintMismatch(origin, rc.region, c.name, c.fn_var, rc.fn_var);
                        s.poison(c.fn_var);
                        return;
                    }
                    if (s.evidenceIndexOf(root, c.name)) |k| {
                        try s.emitSites(c, .{ .evidence = k });
                    } else {
                        try s.reporter.internal(origin, "a `where` constraint has no evidence parameter");
                        try s.emitSites(c, .err);
                    }
                    return;
                }
                if (s.builtinRigidTarget(flags, c)) |target| {
                    try s.unifyMethodType(c, root, &.{ root, root }, s.wellKnownResult(c), origin);
                    try s.emitSites(c, target);
                    return;
                }
                if (c.origin == .type_dispatch) {
                    const var_name = if (info) |i| @as(Symbol.Optional, @enumFromInt(i.var_name)) else flags.name;
                    try s.reporter.typeDispatchNeedsAnnotation(origin, var_name, c.name, c.fn_var);
                    s.poison(c.fn_var);
                    return;
                }
                try s.reporter.missingWhereConstraint(origin, c.origin == .where_clause, flags.name, c.name, c.fn_var);
                try s.emitSites(c, .err);
                return;
            },
            // `resolved` followed every alias already (§6.3's alias row: an
            // alias is transparent, so its methods are the expansion's).
            .alias => return,
            .structure => |flat| switch (flat) {
                .app => |a| return s.methodOnApp(c, root, a, origin),
                .record => |r| return s.methodOnRecord(c, root, r, origin, immediate),
                .empty_record => return s.methodOnRecord(c, root, .{ .fields = .empty, .ext = root }, origin, immediate),
                .tuple, .unit => {
                    if (!s.isWellKnown(c)) return s.noMethodsOnShape(c, root, origin);
                    if (!try s.derivable(c, root, origin)) return;
                    return s.finishDerived(c, root, origin);
                },
                .func => {
                    // `eq` on a function keeps `not_equatable`, which is the
                    // better message; `dischargeMethod` raises it itself
                    // because nothing instantiates `Basics.eq` for `==` any
                    // more (§6.3, §3.4).
                    if (c.name == InternPool.WellKnown.eq.symbol()) {
                        try s.reporter.notEquatable(origin, root, .function);
                    } else {
                        try s.reporter.noMethodsOnShape(origin, c.name, root, .function);
                    }
                    try s.emitSites(c, .err);
                    s.poison(c.fn_var);
                    return;
                },
            },
        }
    }

    /// The bridge between the two ad-hoc mechanisms `fast-compiler.md` §3.1
    /// keeps and the method constraints of this branch.
    ///
    /// A rigid `number` is `Int` or `Float` and nothing else, and the
    /// well-known table (§3.2) gives both of them the same answer; a rigid
    /// marked `equatable` is, by §3.4, exactly a type that has an `eq`.
    /// Both therefore DISCHARGE a well-known constraint without a `where`
    /// clause, which is what keeps `core/Basics.beni`'s `compare`, `max`,
    /// `min` and `clamp` and `core/List.beni`'s `member` checking while
    /// their signatures still say `number` and `equatable a` — the rewrite
    /// that gives them `where` clauses is §5, and it is slice S6.
    ///
    /// Recorded in the report as an addition to §6.3's rigid row: without
    /// it S3 cannot land without S6, and §3.4 already says the two
    /// mechanisms mean the same thing.
    fn builtinRigidTarget(s: *Solver, flags: TypeStore.Flags, c: TypeStore.MethodConstraint) ?Dispatch.Target {
        const is_eq = c.name == InternPool.WellKnown.eq.symbol();
        const is_compare = c.name == InternPool.WellKnown.compare.symbol();
        if (!is_eq and !is_compare) return null;
        if (flags.kind == .number) {
            return if (is_eq) .{ .primitive = .strict_eq } else .{ .primitive = .num_compare };
        }
        if (is_eq and flags.equatable) {
            // `Basics.eq` is the one structural walk (`core/Basics.js`),
            // which is what `==` on an `equatable a` means today.
            const module = s.env.graph.lookup(.core, InternPool.WellKnown.Basics.symbol()) orelse return null;
            if (module.int() >= s.env.interfaces.len) return null;
            const iface = &s.env.interfaces[module.int()];
            const value = iface.findValue(s.env.interner, c.name) orelse return null;
            return .{ .ext = .{ .module = module, .value = value } };
        }
        return null;
    }

    /// Whether this constraint may DERIVE (§3.3 step 2).
    ///
    /// The test is on the NAME plus the surface the constraint came from,
    /// and §1.3 rule 2 excludes exactly one of the four: a hand-written
    /// `x.eq y` is `unknown_method` and never a silent derivation. An
    /// operator (`well_known`), a `where` clause (`where_clause`) and a
    /// return-type dispatch (`type_dispatch`) are all declarative — the
    /// author asked for the method by the name the compiler owns — and all
    /// three derive (A.56).
    ///
    /// Testing `origin == .well_known` alone, as this did, meant that a
    /// constraint instantiated from a `where` clause never derived at a
    /// user type: `eqGen Red Green` under
    /// `eqGen : a, a -> Bool where a.eq : a, a -> Bool` was
    /// `unknown_method`, and §5's `Dict`/`Set`/`List.sort` rewrite — every
    /// one of which reaches its method through a `where` clause — could not
    /// have compiled at all.
    fn isWellKnown(s: *const Solver, c: TypeStore.MethodConstraint) bool {
        _ = s;
        if (c.origin == .dot_call) return false;
        return c.name == InternPool.WellKnown.eq.symbol() or
            c.name == InternPool.WellKnown.compare.symbol();
    }

    /// Whether the shape under `root` can be derived for, reporting if not.
    ///
    /// Derivation is structural and recursive (§3.3), so a function ANYWHERE
    /// inside the type stops it — which is the walk `equatable` already does
    /// (`checker.md` §6.4), reused here so `==` keeps exactly the messages it
    /// had and `compare` gets the one §6.3's `func` row gives it.
    fn derivable(s: *Solver, c: TypeStore.MethodConstraint, root: Var, origin: Bir.Inst.Index) Error!bool {
        const is_eq = c.name == InternPool.WellKnown.eq.symbol();
        // `compare` asks the SAME walk with the other gate (A.54), so a
        // record of a tuple of a `Wraps` is refused for the same reason a
        // bare `Wraps` is — and refused HERE, which is what keeps the use
        // and the eager pass saying the same thing.
        switch (if (is_eq) walkEquatable(s, root) else walkComparable(s, root)) {
            .ok => return true,
            // A type too wide for the walk's worklist. `dischargeEquatable`
            // ACCEPTS it — refusing a program for being large helps nobody
            // when the answer is one structural walk at runtime — but
            // derivation has to write a function per position, and a
            // function hiding in the part it could not reach would be a
            // wrong answer rather than a slow one.
            .unknown, .function => {
                if (is_eq) {
                    try s.reporter.notEquatable(origin, root, .function);
                } else {
                    try s.reporter.noMethodsOnShape(origin, c.name, root, .contains_function);
                }
            },
            // A named type that holds a function, one level down or ten
            // (A.58). `eq` keeps `not_equatable`, which §3.4 says is the
            // better message; `compare` gets §10.3's sentence about the
            // function, which is the one that says what to do about it.
            .contains_function => {
                if (is_eq) {
                    try s.reporter.notEquatable(origin, root, .opaque_type);
                } else {
                    try s.reporter.noMethodsOnShape(origin, c.name, root, .contains_function);
                }
            },
            // A named type the gate refused for any OTHER reason. For `eq`
            // that is the `equatable` answer it always was; for `compare`
            // it is A.54's, and its message names the causes that are left
            // — a payload with no ordering, a `foreign type` whose module
            // declares no `pub compare` — because the fixpoint does not
            // record which.
            .opaque_type => {
                if (!is_eq) {
                    try s.reporter.noMethodsOnShape(origin, c.name, root, .not_orderable);
                } else {
                    try s.reporter.notEquatable(origin, root, .opaque_type);
                }
            },
        }
        try s.emitSites(c, .err);
        s.poison(c.fn_var);
        return false;
    }

    fn noMethodsOnShape(s: *Solver, c: TypeStore.MethodConstraint, root: Var, origin: Bir.Inst.Index) Error!void {
        try s.reporter.noMethodsOnShape(origin, c.name, root, switch (s.store().resolvedContent(root)) {
            .structure => |flat| switch (flat) {
                .tuple => .tuple,
                .unit => .unit,
                .func => .function,
                .record, .empty_record => .record,
                else => .other,
            },
            else => .other,
        });
        try s.emitSites(c, .err);
        s.poison(c.fn_var);
    }

    /// A record receiver. Known at the call (Rule U0): a FIELD call, which
    /// is `language.md` §6.3 unchanged. Deferred and only now concrete: a
    /// well-known name derives over the closed shape, anything else is
    /// `no_methods_on_shape` (§6.3, A.28, A.36).
    fn methodOnRecord(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        root: Var,
        rec: TypeStore.Structure.Record,
        origin: Bir.Inst.Index,
        immediate: bool,
    ) Error!void {
        const st = s.store();
        if (s.isWellKnown(c)) {
            // Only a CLOSED record derives: a flex extension means more
            // fields may arrive and a rigid one means the annotation
            // promised every extension, so neither has a shape key.
            const ext_content = st.resolvedContent(rec.ext);
            const closed = switch (ext_content) {
                .structure => |flat| flat == .empty_record,
                else => false,
            };
            if (!closed) return s.noMethodsOnShape(c, root, origin);
            if (!try s.derivable(c, root, origin)) return;
            return s.finishDerived(c, root, origin);
        }
        if (!immediate) return s.noMethodsOnShape(c, root, origin);

        // The field call: `{ ext | m : args -> result }` on the receiver,
        // and the field's type takes the ARGUMENTS only — the receiver is
        // not one of them.
        const params = st.vars(switch (st.resolvedContent(c.fn_var)) {
            .structure => |flat| switch (flat) {
                .func => |f| f.params,
                else => return s.noMethodsOnShape(c, root, origin),
            },
            else => return s.noMethodsOnShape(c, root, origin),
        });
        const result = switch (st.resolvedContent(c.fn_var)) {
            .structure => |flat| flat.func.result,
            else => unreachable,
        };
        const rest = try s.env.scratch.dupe(Var, params[1..]);
        defer s.env.scratch.free(rest);
        // The FIELD first, against an open record, so a name the record does
        // not have is `unknown_field` and not an arity message about a type
        // nobody wrote (§1.2: "the ordinary record diagnostics").
        const callee = try s.fresh(.{ .flex = .{} });
        var pairs = [_]TypeStore.Field{.{ .name = c.name, .value = callee }};
        const range = try st.addFields(&pairs);
        const ext = try s.fresh(.{ .flex = .{} });
        const required = try s.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
        try s.unify(required, root, origin, .{ .tag = .field_access, .index = @intFromEnum(c.name) });
        try s.emitSites(c, .field);
        // Then §8.3's arity rule on what the field holds, which is the same
        // question a `call` asks and gets the same three messages.
        const given: u32 = @intCast(rest.len);
        switch (st.resolvedContent(callee)) {
            .err => return,
            .flex => |flags| {
                if (flags.kind == .any) {
                    const wanted = try s.func(rest, result);
                    try s.unify(callee, wanted, origin, .{ .tag = .general });
                    return;
                }
                try s.reporter.notAFunction(origin, s.reporter.calleeOf(origin), given, callee);
                s.poison(result);
                return;
            },
            .structure => |flat| switch (flat) {
                .func => |f| {
                    const arity: u32 = f.params.len;
                    if (arity != given) {
                        const declared = try s.copyVars(st.vars(f.params));
                        defer s.env.scratch.free(declared);
                        if (arity > given) {
                            try s.reporter.tooFewArgs(origin, s.reporter.calleeOf(origin), arity, given, declared[given..]);
                        } else {
                            try s.reporter.tooManyArgs(origin, s.reporter.calleeOf(origin), arity, given);
                        }
                        s.poison(result);
                        return;
                    }
                    const wanted = try s.func(rest, result);
                    try s.unify(callee, wanted, origin, .{ .tag = .general });
                    return;
                },
                else => {
                    try s.reporter.notAFunction(origin, s.reporter.calleeOf(origin), given, callee);
                    s.poison(result);
                    return;
                },
            },
            else => {
                try s.reporter.notAFunction(origin, s.reporter.calleeOf(origin), given, callee);
                s.poison(result);
                return;
            },
        }
    }

    fn fieldTextLessThan(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
        return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
    }

    /// §6.3.1: the well-known table, then the module rule, then derivation,
    /// then `unknown_method`.
    fn methodOnApp(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        root: Var,
        a: TypeStore.Structure.App,
        origin: Bir.Inst.Index,
    ) Error!void {
        // 1. The well-known table (§3.2), consulted BEFORE the module rule
        //    because `Int`, `Float`, `Bool`, `Order` and `Never` share
        //    `core/Basics.beni`, whose `compare : number, number -> Order`
        //    would be found for `Bool` and then fail to unify.
        if (s.wellKnownTarget(c, a)) |target| {
            try s.unifyMethodType(c, root, &.{ root, root }, s.wellKnownResult(c), origin);
            switch (target) {
                .derived_nominal => try s.emitSites(c, try s.nominalTarget(c, a, origin, 0)),
                .primitive => |p| try s.emitSites(c, .{ .primitive = p }),
            }
            return;
        }

        // 2. The module rule (§1.2), keyed on `(TypeId, name)`.
        const entry = s.env.types.entry(a.type);
        if (entry.module == s.env.module) {
            if (s.ownDeclNamed(c.name)) |decl| {
                const scheme = s.env.decl_scheme[decl].unwrap() orelse {
                    try s.emitSites(c, .err);
                    return;
                };
                // ONE instantiation per instruction this constraint
                // answers, and not one for `origin` alone: after A.75 a
                // join carries several instructions' sites on one
                // constraint, and the callee's own `where` clause needs a
                // slot — numbered by THAT instruction's cursor, parented
                // on THAT instruction's slot — on each of them (§7.2,
                // A.68).
                var origins: std.ArrayList(SiteOrigin) = .empty;
                defer origins.deinit(s.env.scratch);
                try s.siteOrigins(c, origin, &origins);
                for (origins.items) |site| {
                    const mark: u32 = @intCast(s.store().constraints.items.len);
                    const copy = try s.makeCopy(scheme);
                    // A `method_call`'s site 0 names the CALLEE, so its
                    // evidence slots start at 1 (§7.2) — which is where
                    // the cursor already stands. It is not always 1: this
                    // same arm answers a slot of an OUTER instantiation,
                    // and then it continues that instruction's numbering
                    // instead of colliding with it.
                    var cursor = try s.evidenceCursor(site.inst);
                    try s.tagInstantiated(copy, site.inst, &cursor, mark, false, site.parent);
                    s.commitEvidence(site.inst, cursor);
                    if (!try s.unifyQuiet(copy, c.fn_var)) {
                        try s.reporter.methodSignatureMismatch(origin, entry.module, entry.name, c.name, copy, c.fn_var);
                        try s.emitSites(c, .err);
                        s.poison(c.fn_var);
                        return;
                    }
                }
                try s.emitSites(c, .{ .top = .{ .decl = @enumFromInt(decl) } });
                return;
            }
        } else if (entry.module.int() >= s.env.interfaces.len) {
            // **§6.8 is not landed** (a concurrent slice owns
            // `resolve/Graph.zig`), so under `--jobs>1` a method lookup can
            // reach a module the DAG did not order before this one and whose
            // interface is therefore absent. That is a compiler bug in the
            // making, not a program error, so it says `internal` and never
            // panics — and it becomes unreachable the moment the implicit
            // `ext_type` edges of §6.8 land.
            try s.reporter.internal(origin, "a method's declaring module has no interface");
            try s.emitSites(c, .err);
            s.poison(c.fn_var);
            return;
        } else {
            const iface = &s.env.interfaces[entry.module.int()];
            if (iface.findValue(s.env.interner, c.name)) |value| {
                // The same continuation as the arm above: `List (List Int)`
                // resolves `List.eq`, whose `where a.eq` slot resolves
                // `List.eq` again, and each level takes the next free index
                // of the one instruction rather than 1 over and over.
                // Once per instruction, for the reason the arm above is:
                // `size (put (put seed [ 1, 2 ]) [ 3 ])` joins the two
                // calls' `k.compare` onto one constraint, and the inner
                // call needs its own `List.compare … where a.compare` slot
                // as much as the outer one does (A.75, A.68).
                var origins: std.ArrayList(SiteOrigin) = .empty;
                defer origins.deinit(s.env.scratch);
                try s.siteOrigins(c, origin, &origins);
                for (origins.items) |site| {
                    var cursor = try s.evidenceCursor(site.inst);
                    const copy = (try s.importedValue(entry.module, @intFromEnum(value), .{
                        .inst = site.inst,
                        .next = &cursor,
                        .parent = site.parent,
                    })) orelse {
                        s.commitEvidence(site.inst, cursor);
                        try s.emitSites(c, .err);
                        return;
                    };
                    s.commitEvidence(site.inst, cursor);
                    if (!try s.unifyQuiet(copy, c.fn_var)) {
                        try s.reporter.methodSignatureMismatch(origin, entry.module, entry.name, c.name, copy, c.fn_var);
                        try s.emitSites(c, .err);
                        s.poison(c.fn_var);
                        return;
                    }
                }
                try s.emitSites(c, .{ .ext = .{ .module = entry.module, .value = value } });
                return;
            }
            if (s.privateInOtherModule(entry.module, c.name)) {
                try s.reporter.privateMethod(origin, entry.module, c.name);
                try s.emitSites(c, .err);
                s.poison(c.fn_var);
                return;
            }
        }

        // 3. Derivation, for a well-known name on a shape that supports it
        //    (§3.3 step 2).
        if (s.isWellKnown(c) and !s.derivesForNominal(c, a.type) and entry.kind != .foreign) {
            // A declared type that cannot answer the method: the walk knows
            // WHY — a function somewhere inside, or a payload that cannot
            // answer it either — and says so. A `foreign type` falls
            // through to `unknown_method` instead, which is A.50's message
            // and the one that names the `pub compare` its module is
            // missing.
            _ = try s.derivable(c, root, origin);
            return;
        }
        if (s.isWellKnown(c) and s.derivesForNominal(c, a.type)) {
            if (!try s.derivable(c, root, origin)) return;
            try s.unifyMethodType(c, root, &.{ root, root }, s.wellKnownResult(c), origin);
            // **A.18**: an all-nullary type is a bare tag string, so `eq` at
            // a USE SITE is `===` and there is nothing to derive. `compare`
            // cannot be, because alphabetic tag order is not declaration
            // order (§9.4).
            if (c.name == InternPool.WellKnown.eq.symbol() and s.allNullary(a.type)) {
                try s.emitSites(c, .{ .primitive = .strict_eq });
                return;
            }
            try s.emitSites(c, try s.nominalTarget(c, a, origin, 0));
            return;
        }

        // 4. `unknown_method`, with a did-you-mean over the module's `pub`
        //    value names (§10.1).
        try s.reporter.unknownMethod(origin, c.origin == .where_clause, entry.module, entry.name, c.name);
        try s.emitSites(c, .err);
        s.poison(c.fn_var);
    }

    /// Whether every constructor of `id` takes no arguments, which is what
    /// makes its representation a bare tag string (`backend.md` §4).
    /// A type with NO constructors — a `foreign type` — is not one.
    fn allNullary(s: *const Solver, id: Types.TypeId) bool {
        const entry = s.env.types.entry(id);
        if (entry.module == s.env.module) {
            const bir = s.env.bir;
            if (entry.decl.int() >= bir.decls.len) return false;
            const d = bir.decls[entry.decl.int()];
            if (d.ctors_start == d.ctors_end) return false;
            for (bir.ctors[d.ctors_start..d.ctors_end]) |ctor| {
                if (ctor.args_start != ctor.args_end) return false;
            }
            return true;
        }
        if (entry.module.int() >= s.env.interfaces.len) return false;
        const iface = &s.env.interfaces[entry.module.int()];
        const index = iface.findType(s.env.interner, entry.name) orelse return false;
        const t = iface.types[@intFromEnum(index)];
        if (t.ctors_start == t.ctors_end) return false;
        for (iface.ctors[t.ctors_start..t.ctors_end]) |ctor| {
            if (ctor.arity != 0) return false;
        }
        return true;
    }

    const WellKnownTarget = union(enum) { primitive: Dispatch.Target.Primitive, derived_nominal };

    fn wellKnownTarget(s: *const Solver, c: TypeStore.MethodConstraint, a: TypeStore.Structure.App) ?WellKnownTarget {
        if (a.args.len != 0) return null;
        const wk = s.env.types.well_known;
        const is_eq = c.name == InternPool.WellKnown.eq.symbol();
        const is_compare = c.name == InternPool.WellKnown.compare.symbol();
        if (!is_eq and !is_compare) return null;
        const t = a.type;
        if (t == .none) return null;
        if (t == wk.int or t == wk.float or t == wk.bool) {
            return if (is_eq) .{ .primitive = .strict_eq } else .{ .primitive = .num_compare };
        }
        if (t == wk.char) return if (is_eq) .{ .primitive = .strict_eq } else .{ .primitive = .char_compare };
        if (t == wk.string) return if (is_eq) .{ .primitive = .strict_eq } else .{ .primitive = .string_compare };
        // `Order` is all-nullary, so `eq` is `===`; `compare` cannot be,
        // because alphabetic tag order is not `LT < EQ < GT` (§3.2).
        if (t == wk.order) return if (is_eq) .{ .primitive = .strict_eq } else .derived_nominal;
        if (t == wk.never) return .derived_nominal;
        return null;
    }

    fn wellKnownResult(s: *const Solver, c: TypeStore.MethodConstraint) Types.TypeId {
        return if (c.name == InternPool.WellKnown.eq.symbol())
            s.env.types.well_known.bool
        else
            s.env.types.well_known.order;
    }

    /// Unify the constraint's recorded type with `params -> T`.
    fn unifyMethodType(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        root: Var,
        params: []const Var,
        result_type: Types.TypeId,
        origin: Bir.Inst.Index,
    ) Error!void {
        _ = root;
        const result = try s.applied(result_type, &.{});
        const wanted = try s.func(params, result);
        try s.unify(wanted, c.fn_var, origin, .{ .tag = .general });
    }

    /// The declaration of THIS module named `name`, `pub` or not.
    ///
    /// A linear scan over the declaration table, and deliberately not
    /// `Interface.Provenance`: that maps only the `pub` entries, so a
    /// private method would be invisible and `private_method` could never
    /// be told apart from `unknown_method` inside the declaring module
    /// (§6.3.1 step 2).
    fn ownDeclNamed(s: *const Solver, name: Symbol) ?u32 {
        const bir = s.env.bir;
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue()) continue;
            if (bir.symbol(d.name) == name) return @intCast(i);
        }
        return null;
    }

    /// The `pub` declaration of THIS module named `name`.
    ///
    /// The difference from `ownDeclNamed` is the whole of §3.3 step 1's
    /// reach: a private value wins for this module's own uses, and for
    /// nobody else's, because `Interface.findValue` maps only the `pub`
    /// entries. So the EAGER pass (`deriveOne`) asks this one — a row it
    /// skips is a row every dependent still expects — while a use inside
    /// this module asks `ownDeclNamed` and takes the private value.
    fn ownPubDeclNamed(s: *const Solver, name: Symbol) ?u32 {
        const bir = s.env.bir;
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue()) continue;
            if (!d.is_pub) continue;
            if (bir.symbol(d.name) == name) return @intCast(i);
        }
        return null;
    }

    /// Whether `module` declares `name` WITHOUT `pub`, for §10.2.
    ///
    /// This reads another module's `Bir`, which the checker does not do on
    /// the happy path (`checker.md` §4.5) — it runs only after
    /// `Interface.findValue` has already failed, so the declaration is
    /// already wrong and the only question left is which message it gets.
    /// When the Bir is not in memory the answer is "no" and the message is
    /// `unknown_method`, which is the honest degradation.
    fn privateInOtherModule(s: *const Solver, module: Graph.Index, name: Symbol) bool {
        const file = s.env.graph.moduleFile(module);
        const bir = s.env.artifacts.bir(file);
        for (bir.decls) |d| {
            if (!d.kind.isValue()) continue;
            if (bir.symbol(d.name) == name) return true;
        }
        return false;
    }

    /// **The recursive resolver of §9's parts contract.** Never reports:
    /// the receiver's own arm has already run `derivable`, whose walk sees
    /// every position this one visits, so a mistake anywhere inside the
    /// type has a message before this is called.
    ///
    /// `.err` is what a position the checker cannot answer gets — a
    /// variable that is still flex, an open record, a function. The
    /// constraint is attached to a flex position so it still propagates and
    /// is still promoted.
    fn targetFor(s: *Solver, c: TypeStore.MethodConstraint, v: Var, origin: Bir.Inst.Index, depth: u32) Error!Dispatch.Target {
        // Derivation is structural and recursive (§3.3), so it needs a
        // guard of its own: a poisoned store can hand it a cycle that the
        // type reader's own `max_depth` never saw.
        if (depth > max_depth) return .err;
        const st = s.store();
        const root, const content = st.resolved(v);
        switch (content) {
            .err, .alias => return .err,
            .flex => {
                // A marker for one of the declaring type's own parameters,
                // during the eager pass of A.23: the derived function takes
                // one evidence parameter per type parameter, used or not
                // (§9.4, A.20).
                for (s.type_params, 0..) |marker, i| {
                    if (st.find(marker) == root) return .{ .evidence = @intCast(i) };
                }
                // The A.53 bridge first (A.59): a `number` position is
                // `Int` or `Float` and §3.2 gives both the same answer, so
                // a tuple of `( 1, "a" )` derives with `num_compare` at
                // position 0 and not with `err`. Without it every literal
                // position of a derived shape was a hole.
                const flags = st.flagsOf(root);
                if (s.builtinRigidTarget(flags, c)) |t| return t;
                const inner = try s.freshMethodConstraint(c, root);
                _ = try s.attachConstraint(root, inner, origin, null);
                return .err;
            },
            .rigid => |flags| {
                if (st.findConstraint(flags.constraints, c.name) != null) {
                    return .{ .evidence = s.evidenceIndexOf(root, c.name) orelse return .err };
                }
                if (s.builtinRigidTarget(flags, c)) |t| return t;
                return .err;
            },
            .structure => |flat| switch (flat) {
                .app => |a| return s.appTarget(c, a, origin, depth),
                .record => |r| {
                    const ext_content = st.resolvedContent(r.ext);
                    const closed = switch (ext_content) {
                        .structure => |f| f == .empty_record,
                        else => false,
                    };
                    if (!closed) return .err;
                    return s.recordTarget(c, r, origin, depth);
                },
                .empty_record => return s.recordTarget(c, .{ .fields = .empty, .ext = root }, origin, depth),
                .tuple => |t| {
                    const elements = try s.env.scratch.dupe(Var, st.vars(t));
                    defer s.env.scratch.free(elements);
                    const arity: u8 = @intCast(@min(elements.len, 255));
                    return s.derivedUse(c, .{ .tuple = arity }, elements, origin, depth);
                },
                .unit => return s.derivedUse(c, .unit, &.{}, origin, depth),
                .func => return .err,
            },
        }
    }

    /// The well-known method of a nominal type, as a target: the table of
    /// §3.2, then the module rule, then derivation (§6.3.1 without the
    /// diagnostics).
    fn appTarget(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        a: TypeStore.Structure.App,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Target {
        if (s.wellKnownTarget(c, a)) |wk| {
            return switch (wk) {
                .primitive => |p| .{ .primitive = p },
                .derived_nominal => s.nominalTarget(c, a, origin, depth),
            };
        }
        const entry = s.env.types.entry(a.type);
        if (entry.module == s.env.module) {
            if (s.ownDeclNamed(c.name)) |decl| {
                const scheme = s.env.decl_scheme[decl].unwrap();
                const parts = if (scheme) |v|
                    try s.ownValueParts(c, v, a, origin, depth)
                else
                    Dispatch.Range.empty;
                return .{ .top = .{ .decl = @enumFromInt(decl), .parts = parts } };
            }
        } else if (entry.module.int() < s.env.interfaces.len) {
            const iface = &s.env.interfaces[entry.module.int()];
            if (iface.findValue(s.env.interner, c.name)) |value| {
                const parts = try s.importedValueParts(c, entry.module, value, a, origin, depth);
                return .{ .ext = .{ .module = entry.module, .value = value, .parts = parts } };
            }
        }
        if (!s.derivesForNominal(c, a.type)) return .err;
        return s.nominalTarget(c, a, origin, depth);
    }

    /// **§7.1's amendment: a `top`/`ext` in a PART position carries its own
    /// evidence** (A.64), one target per constraint the named value's
    /// scheme puts on a type parameter.
    ///
    /// The mapping is the one `nominalTarget` already uses, and it is a
    /// mapping only because of what the value IS: a method of `T`, whose
    /// first parameter is `T a1 … an`. §7.2's canonical order walks the
    /// scheme body, so it meets `a1 … an` in the application's own order,
    /// and quantifier `i` is therefore argument `i`. What the scheme adds
    /// is WHICH parameters carry a constraint and how many each carries —
    /// `where a.eq` on a `Box a b` is one slot, answered by `a` alone.
    ///
    /// A scheme whose quantifier count does not match the type's arity has
    /// no such mapping — a `where` clause over a variable the receiver does
    /// not supply — so it gets NO parts and the backend refuses the call
    /// rather than passing evidence for the wrong parameter.
    fn constrainedParts(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        counts: []const u32,
        names: []const Symbol,
        a: TypeStore.Structure.App,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Range {
        if (names.len == 0) return .empty;
        const args = try s.env.scratch.dupe(Var, s.store().vars(a.args));
        defer s.env.scratch.free(args);
        if (counts.len != args.len) return .empty;
        const range = try s.env.dispatch.reserveParts(names.len);
        var slot: usize = 0;
        for (counts, 0..) |n, i| {
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                const inner = try s.renamedConstraint(c, names[slot], args[i]);
                s.env.dispatch.setPart(range, slot, try s.targetFor(inner, args[i], origin, depth + 1));
                slot += 1;
            }
        }
        return range;
    }

    /// The per-quantifier constraint counts and names of an IMPORTED
    /// value's scheme, read straight from the interface record: the same
    /// record `Lower.externalEvidence` counts, so caller and callee derive
    /// one order from one place (§7.2).
    fn importedValueParts(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        module: Graph.Index,
        value: Interface.ValueIndex,
        a: TypeStore.Structure.App,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Range {
        const iface = &s.env.interfaces[module.int()];
        if (@intFromEnum(value) >= iface.values.len) return .empty;
        const index = iface.values[@intFromEnum(value)].scheme;
        if (index == .none or @intFromEnum(index) >= iface.schemes.len) return .empty;
        const scheme = iface.scheme(index);
        const counts = try s.env.scratch.alloc(u32, scheme.quantified_count);
        defer s.env.scratch.free(counts);
        var names: std.ArrayList(Symbol) = .empty;
        defer names.deinit(s.env.scratch);
        for (counts, 0..) |*slot, i| {
            const q = iface.quantified(scheme, @intCast(i));
            slot.* = q.constraints_len;
            var j: u32 = 0;
            while (j < q.constraints_len) : (j += 1) {
                const qc = iface.quantifiedConstraint(q, j);
                if (@intFromEnum(qc.name) >= iface.symbols.len) return .empty;
                try names.append(s.env.scratch, iface.symbol(qc.name));
            }
        }
        return s.constrainedParts(c, counts, names.items, a, origin, depth);
    }

    /// The same, for a value of THIS module: the scheme is a live type
    /// variable, so the order comes from `Schemes.quantifierOrder` — the
    /// one walk §7.2 names, and the one `tagInstantiated` uses on a copy of
    /// the same scheme.
    fn ownValueParts(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        scheme: Var,
        a: TypeStore.Structure.App,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Range {
        const st = s.store();
        var order: std.ArrayList(Var) = .empty;
        defer order.deinit(s.env.scratch);
        try Schemes.quantifierOrder(st, s.env.interner, scheme, &order, s.env.scratch);
        const counts = try s.env.scratch.alloc(u32, order.items.len);
        defer s.env.scratch.free(counts);
        var names: std.ArrayList(Symbol) = .empty;
        defer names.deinit(s.env.scratch);
        for (order.items, counts) |root, *slot| {
            const set = st.flagsOf(root).constraints;
            const n = st.constraintCount(set);
            slot.* = @intCast(n);
            if (n == 0) continue;
            const sorted = try s.env.scratch.alloc(TypeStore.MethodConstraint, n);
            defer s.env.scratch.free(sorted);
            for (sorted, 0..) |*item, j| item.* = st.constraintAt(set, @intCast(j));
            std.mem.sort(TypeStore.MethodConstraint, sorted, s.env.interner, constraintNameLessThan);
            for (sorted) |item| try names.append(s.env.scratch, item.name);
        }
        return s.constrainedParts(c, counts, names.items, a, origin, depth);
    }

    fn constraintNameLessThan(
        interner: *const InternPool.Global,
        x: TypeStore.MethodConstraint,
        y: TypeStore.MethodConstraint,
    ) bool {
        return std.mem.lessThan(u8, interner.slice(x.name), interner.slice(y.name));
    }

    /// A use of a nominal type's derived method. The function itself is
    /// emitted by the DECLARING module (§8.5, A.23), so a type from another
    /// module is `ext_derived` and gets no row in this module's table
    /// (A.47); the evidence is one target per type parameter either way.
    fn nominalTarget(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        a: TypeStore.Structure.App,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Target {
        const kind = s.derivedKind(c);
        const entry = s.env.types.entry(a.type);
        // **A NULLARY `foreign type` never gets a derived row**, here or in
        // the eager pass (A.55): there is no body to write and nothing
        // underneath it, so a row would name a function S5 has nothing to
        // emit for. What answers `eq` on an `equatable` one is the
        // structural walk `core/Basics.js` already has, which is what the
        // `equatable`-rigid bridge uses and what the S4 shim emits for
        // every `==` (A.53).
        //
        // A PARAMETRIC one keeps its row (A.60). `List a` is `equatable`
        // when `a` is, and `a` may be a type with a user `pub eq`: the
        // structural walk would compare its payloads and ignore the method
        // the author wrote, so `[ Id 1 2 ] == [ Id 1 99 ]` answered `False`
        // where `Id`'s own `eq` says `True`. The row carries one part per
        // argument, which is the only place that method is named, and the
        // backend decides from the parts whether the structural walk will
        // do — the decision is its, and it refuses what it cannot honour
        // (A.51).
        if (entry.kind == .foreign and a.args.len == 0) {
            if (c.name == InternPool.WellKnown.eq.symbol()) {
                if (s.structuralEqTarget()) |t| return t;
            }
            return .err;
        }
        const args = try s.env.scratch.dupe(Var, s.store().vars(a.args));
        defer s.env.scratch.free(args);
        const range = try s.env.dispatch.reserveParts(args.len);
        for (args, 0..) |arg, i| {
            s.env.dispatch.setPart(range, i, try s.targetFor(c, arg, origin, depth + 1));
        }
        if (entry.module == s.env.module) {
            const index = try s.env.dispatch.derive(kind, .{ .nominal = a.type }, @intCast(args.len));
            return .{ .derived = .{ .index = index, .parts = range } };
        }
        return .{ .ext_derived = .{
            .module = entry.module,
            .type = a.type,
            .kind = kind,
            .parts = range,
        } };
    }

    /// `core/Basics.beni`'s `eq`, the one structural walk (§3.4, A.53).
    fn structuralEqTarget(s: *const Solver) ?Dispatch.Target {
        const module = s.env.graph.lookup(.core, InternPool.WellKnown.Basics.symbol()) orelse return null;
        if (module.int() >= s.env.interfaces.len) return null;
        const iface = &s.env.interfaces[module.int()];
        const value = iface.findValue(s.env.interner, InternPool.WellKnown.eq.symbol()) orelse return null;
        return .{ .ext = .{ .module = module, .value = value } };
    }

    fn recordTarget(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        rec: TypeStore.Structure.Record,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Target {
        const st = s.store();
        const fields = try s.env.scratch.dupe(TypeStore.Field, st.fields(rec.fields));
        defer s.env.scratch.free(fields);
        std.mem.sort(TypeStore.Field, fields, s.env.interner, fieldTextLessThan);
        const names = try s.env.scratch.alloc(Symbol, fields.len);
        defer s.env.scratch.free(names);
        const values = try s.env.scratch.alloc(Var, fields.len);
        defer s.env.scratch.free(values);
        for (fields, names, values) |f, *n, *v| {
            n.* = f.name;
            v.* = f.value;
        }
        const shape_range = try s.env.dispatch.addSymbols(names);
        return s.derivedUse(c, .{ .record = shape_range }, values, origin, depth);
    }

    /// A use of a STRUCTURAL derived function: the function is keyed on the
    /// shape alone and takes one evidence parameter per position, so what
    /// this use contributes is the arguments and nothing else (A.11, A.46).
    fn derivedUse(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        shape: Dispatch.Shape,
        positions: []const Var,
        origin: Bir.Inst.Index,
        depth: u32,
    ) Error!Dispatch.Target {
        const kind = s.derivedKind(c);
        const index = try s.env.dispatch.derive(kind, shape, @intCast(positions.len));
        const range = try s.env.dispatch.reserveParts(positions.len);
        for (positions, 0..) |v, i| {
            s.env.dispatch.setPart(range, i, try s.targetFor(c, v, origin, depth + 1));
        }
        return .{ .derived = .{ .index = index, .parts = range } };
    }

    fn derivedKind(_: *const Solver, c: TypeStore.MethodConstraint) Dispatch.Derived.Kind {
        return if (c.name == InternPool.WellKnown.eq.symbol()) .eq else .compare;
    }

    /// Whether `id`'s shape supports derivation at all (§3.3, "shape
    /// supports it"). A `foreign type` has no constructors to walk, so it
    /// derives only through §3.2's table — or, until §5.2 gives `List` its
    /// own `pub foreign eq` in S6, through the `equatable` marker, which
    /// §3.4 says means exactly "has an `eq`".
    fn derivesForNominal(s: *const Solver, c: TypeStore.MethodConstraint, id: Types.TypeId) bool {
        const entry = s.env.types.entry(id);
        if (c.name == InternPool.WellKnown.eq.symbol()) {
            // A `foreign type` has no constructors to walk, so `eq` reaches
            // it only through the `equatable` marker, which §3.4 says means
            // exactly "has an `eq`" — the bridge core leans on until §5.2
            // (A.50). Anything else is answered by the transitive walk in
            // `derivable`.
            if (entry.kind == .foreign) return s.env.types.isEquatable(id);
            return true;
        }
        // `compare` has no marker, so it has a gate of its own (A.54): a
        // type derives it only when every named type in its body can answer
        // `<` too. Without it, `type Wraps = Wraps Handle` over a plain
        // `foreign type Handle` derived a `compare` whose one part was
        // `err`, and `a < b` on it compiled.
        return s.env.types.isComparable(id);
    }

    /// A constraint of the same name and origin as `c`, at a fresh method
    /// type, for a position inside a derived function.
    fn freshMethodConstraint(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        v: Var,
    ) Error!TypeStore.MethodConstraint {
        return s.renamedConstraint(c, c.name, v);
    }

    /// The same, under a name the ENCLOSING value's `where` clause chose.
    /// `List.eq`'s clause happens to be `a.eq`, but nothing makes a
    /// method's own name and its constraint's name the same word, and a
    /// part resolved under the wrong one would name the wrong function.
    fn renamedConstraint(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        name: Symbol,
        v: Var,
    ) Error!TypeStore.MethodConstraint {
        const is_eq = name == InternPool.WellKnown.eq.symbol();
        const result_type = if (is_eq) s.env.types.well_known.bool else s.env.types.well_known.order;
        const result = try s.applied(result_type, &.{});
        return .{
            .name = name,
            .fn_var = try s.func(&.{ v, v }, result),
            .region = c.region,
            .origin = c.origin,
            .sites = .empty,
        };
    }

    /// The receiver's own derived target: `T, T -> Bool | Order`, and one
    /// site per instruction the constraint answers.
    fn finishDerived(s: *Solver, c: TypeStore.MethodConstraint, root: Var, origin: Bir.Inst.Index) Error!void {
        try s.unifyMethodType(c, root, &.{ root, root }, s.wellKnownResult(c), origin);
        try s.emitSites(c, try s.targetFor(c, root, origin, 0));
    }

    /// Record one dispatch site per instruction this constraint answers.
    fn emitSites(s: *Solver, c: TypeStore.MethodConstraint, target: Dispatch.Target) Error!void {
        const view = s.store().constraintSites(c);
        if (view.len == 0) return;
        const copied = try s.env.scratch.dupe(TypeStore.ConstraintSite, view);
        defer s.env.scratch.free(copied);
        for (copied) |site| {
            try s.env.dispatch.addSite(.{
                .inst = site.inst,
                .evidence_index = site.evidence_index,
                .parent = site.parent,
                .target = target,
            });
        }
    }

    /// An instruction whose evidence a resolution has to number, and the
    /// slot of it that `c` itself answers — the PARENT of every slot the
    /// resolution of `c` goes on to ask for (`Dispatch.Site.parent`,
    /// A.68).
    const SiteOrigin = struct { inst: Bir.Inst.Index, parent: u16 };

    /// Every instruction `c` answers a slot of, once each, in site order
    /// (A.75). A constraint carries one site per instruction until a join
    /// gives it several, and a resolution that instantiates the callee's
    /// own `where` clause has to do it once per instruction: the slots are
    /// numbered by a cursor the INSTRUCTION owns (§7.2, A.68), so one
    /// instantiation against one of them leaves the others a call short.
    ///
    /// Site order, which is the order the sites were appended in, so the
    /// numbering is a function of the input and not of the drain (§10 of
    /// `fast-compiler.md`).
    ///
    /// A constraint with NO sites still gets one entry — `fallback`, with
    /// `no_parent` — because the method type still has to be unified. That
    /// is what a `where` clause raised by the eager pass looks like: there
    /// is no call, so there is nothing for a child to hang under either.
    fn siteOrigins(
        s: *Solver,
        c: TypeStore.MethodConstraint,
        fallback: Bir.Inst.Index,
        out: *std.ArrayList(SiteOrigin),
    ) Error!void {
        for (s.store().constraintSites(c)) |site| {
            var seen = false;
            for (out.items) |already| {
                if (already.inst == site.inst) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            try out.append(s.env.scratch, .{ .inst = site.inst, .parent = site.evidence_index });
        }
        if (out.items.len == 0) {
            try out.append(s.env.scratch, .{ .inst = fallback, .parent = Dispatch.Site.no_parent });
        }
    }

    /// Which evidence parameter of the enclosing declaration answers
    /// `(rigid, name)` (§7.2). Built by `Check` from the annotation.
    ///
    /// **Null is a compiler bug, not a program error**, and every caller
    /// says so rather than passing evidence 0 — which is a silently wrong
    /// argument at a call the author cannot see.
    fn evidenceIndexOf(s: *const Solver, rigid_root: Var, name: Symbol) ?u16 {
        const st = s.store();
        for (s.env.rigid_evidence) |e| {
            if (e.method != name) continue;
            if (@constCast(st).find(e.v) == rigid_root) return e.index;
        }
        return null;
    }

    /// Tag the constraints a LOCAL instantiation created with the site they
    /// answer, in the canonical order of §7.2.
    ///
    /// The copy is structurally identical to the scheme, so the same walk
    /// gives the same order on both sides of a module boundary. The entries
    /// were appended by this very call, so writing their `sites` is not a
    /// mutation of anything already committed (§6.1 invariant 2).
    fn tagInstantiated(s: *Solver, copy: Var, origin: Bir.Inst.Index, next: *u16, from: u32, shared: bool, parent: u16) Error!void {
        const st = s.store();
        var order: std.ArrayList(Var) = .empty;
        defer order.deinit(s.env.scratch);
        try Schemes.quantifierOrder(st, s.env.interner, copy, &order, s.env.scratch);
        for (order.items) |root| {
            const set = st.flagsOf(root).constraints;
            const n = st.constraintCount(set);
            if (n == 0) continue;
            const sorted = try s.env.scratch.alloc(u32, n);
            defer s.env.scratch.free(sorted);
            const base = st.constraint_sets.items[set.unwrap().?.int()].start;
            for (sorted, 0..) |*x, j| x.* = base + @as(u32, @intCast(j));
            std.mem.sort(u32, sorted, s, constraintIndexLessThan);
            for (sorted) |at| {
                // Only what THIS copy created. `makeCopy` of a reference to
                // a non-generalised variable — a local, or a member of the
                // current binding group — hands back the variable itself,
                // and OVERWRITING that would replace the DECLARATION's own
                // `where`-clause constraint with the site of one use. A
                // same-group top reference still needs its forwarding site,
                // so there the site is appended rather than written.
                if (at < from) {
                    if (shared) try s.appendSite(at, .{ .inst = origin, .evidence_index = next.*, .parent = parent });
                    next.* +|= 1;
                    continue;
                }
                st.constraints.items[at].sites = try st.addConstraintSites(&.{.{ .inst = origin, .evidence_index = next.*, .parent = parent }});
                next.* +|= 1;
                // **Every constraint an instantiation creates gets an
                // obligation**, and not only the ones a later unification
                // happens to carry into `deferConstraints` (Rule U3, A.57).
                //
                // `gen 1 2` under `gen : a, a -> Bool where a.compare` is
                // the case that needs it: `1` is a `number` flex that never
                // meets a structure, so U3 never fires, the A.53 bridge in
                // `dischargeMethod`'s `.flex` arm never runs, and the call
                // got NO evidence site at all while `gen 1.5 2.5` and
                // `gen "a" "b"` got one each. When U3 does fire as well,
                // `resolved_methods` makes the second discharge a no-op.
                try s.registerMethod(root, at);
            }
        }
    }

    /// Add one more dispatch site to an existing constraint, unless it is
    /// already there. The site list is a range of an append-only table, so
    /// this is a fresh range and the old one is left alone (§6.1
    /// invariant 2).
    fn appendSite(s: *Solver, at: u32, site: TypeStore.ConstraintSite) Error!void {
        const st = s.store();
        const existing = st.constraintSites(st.constraints.items[at]);
        for (existing) |seen| {
            if (seen.inst == site.inst and seen.evidence_index == site.evidence_index) return;
        }
        const joined = try s.env.scratch.alloc(TypeStore.ConstraintSite, existing.len + 1);
        defer s.env.scratch.free(joined);
        @memcpy(joined[0..existing.len], existing);
        joined[existing.len] = site;
        st.constraints.items[at].sites = try st.addConstraintSites(joined);
    }

    fn constraintIndexLessThan(s: *const Solver, a: u32, b: u32) bool {
        const st = s.store();
        return std.mem.lessThan(
            u8,
            s.env.interner.slice(st.constraints.items[a].name),
            s.env.interner.slice(st.constraints.items[b].name),
        );
    }

    // ---- Eager nominal derivation (A.23, §6.3.1 step 4, §8.5) ----------

    /// Derive `eq` and `compare` for every nominal type this module
    /// declares, used or not.
    ///
    /// **It has to be eager, and it has to be here.** `Dispatch` is per
    /// module and is built at the end of that module's own check; the
    /// declaring module is checked and lowered BEFORE any user of the type
    /// (§6.8), so a use site cannot ask it for anything. Deriving on demand
    /// would either put the function in the consuming module — impossible
    /// for a `pub opaque type`, whose constructors it may not read — or
    /// make the declaring module's bytes depend on which other module asked
    /// first, which varies with `--jobs` and CLAUDE.md rule 5 forbids
    /// outright.
    ///
    /// Two exclusions (§6.3.1 step 4): a type whose module supplies a `pub`
    /// value of that name gets that instead, and a type ANY of whose
    /// constructor payloads contains a function type gets neither — a use
    /// is then `not_equatable` or `no_methods_on_shape` at the use.
    pub fn deriveDeclaredTypes(s: *Solver) Error!void {
        const bir = s.env.bir;
        for (bir.decls, 0..) |d, i| {
            if (d.kind != .type) continue;
            const id = s.env.types.ofDecl(s.env.module, @enumFromInt(i));
            if (id == .none) continue;
            try s.deriveOne(d, id);
        }
    }

    fn deriveOne(s: *Solver, d: Bir.Decl, id: Types.TypeId) Error!void {
        const bir = s.env.bir;
        const scratch = s.env.scratch;
        const params = bir.declTypeParams(d);

        // The type's own parameters as markers: a position that resolves to
        // one of them is `evidence i` of the DERIVED function (§9.4, A.20).
        const markers = try scratch.alloc(Var, params.len);
        defer scratch.free(markers);
        var b = s.env.builder(.flex, TypeStore.generalized);
        defer b.deinit();
        for (params, markers) |name, *v| {
            v.* = try s.store().fresh(.{ .flex = .{ .name = name.toOptional() } }, TypeStore.generalized);
            try b.bind(name, v.*);
        }

        // Every constructor argument, constructors in DECLARATION order and
        // arguments left to right — §9's parts contract exactly.
        var args: std.ArrayList(Var) = .empty;
        defer args.deinit(scratch);
        for (bir.ctors[d.ctors_start..d.ctors_end]) |ctor| {
            const written = bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index);
            for (written) |arg| try args.append(scratch, try b.read(arg));
        }
        if (b.too_deep) return; // already reported by `reportTooDeep`

        const outer = s.type_params;
        defer s.type_params = outer;
        s.type_params = markers;

        for ([_]InternPool.WellKnown{ .eq, .compare }) |well_known| {
            const name = well_known.symbol();
            const kind: Dispatch.Derived.Kind = if (well_known == .eq) .eq else .compare;
            // **§3.2's table FIRST, before §3.3's module rule**, which is
            // the order resolution itself uses. `core/Basics.beni` declares
            // `Bool`, `Order` and `Never` over a `pub foreign eq` and a
            // `pub compare` of its own, and consulting step 1 first let
            // those two suppress every row the table asks Basics for: the
            // module printed no `derived` line at all while every other
            // module's `< ` on an `Order` named `ext_derived Basics.Order
            // compare` (A.47). A primitive row is not a function and gets
            // no derived body; `Order`'s `compare` and both of `Never`'s
            // are derived and must be written here.
            const c: TypeStore.MethodConstraint = .{
                .name = name,
                .fn_var = try s.store().freshErr(TypeStore.generalized),
                .region = d.inst_start,
                .origin = .well_known,
                .sites = .empty,
            };
            const table = s.wellKnownTarget(c, .{ .type = id, .args = .empty });
            if (table) |answer| {
                // `Int`, `Float`, `Char`, `String`, `Bool` and `Order`'s
                // `eq` are all `primitive`: a use emits the JavaScript
                // operator, so there is no function for this module to
                // write (A.18).
                if (answer == .primitive) continue;
            } else {
                // Step 1 of §3.3: a user value of that name wins, and then
                // there is nothing to derive — but only a `pub` one, since
                // that is the only value another module can reach. A
                // PRIVATE `eq` is found by this module's own uses (the
                // `top` target of §3.3 step 1, which `targetFor` still
                // takes) and by nobody else's, so a dependent resolving the
                // same type derives instead and names `<T>$$eq` in this
                // module. Suppressing the row on a private declaration made
                // that name an import of an export that was never written:
                // exit 0, and `SyntaxError` at load.
                if (s.ownPubDeclNamed(name) != null) continue;
            }
            // **The exclusions of §6.3.1 step 4, and they have to be the
            // SAME test a use makes** (A.23, A.54): the two transitive
            // gates. `equatable` is false as soon as a function is
            // reachable — through another nominal type as well, which a
            // walk over this body's `app` ARGUMENTS alone would have missed
            // — and `comparable` is false for anything whose body reaches a
            // type that cannot answer `<`. A row written here that a use
            // refuses is a function nobody calls; a row a use names that is
            // not written here is a call to nothing.
            const gated = switch (kind) {
                .eq => s.env.types.isEquatable(id),
                .compare => s.env.types.isComparable(id),
            };
            if (!gated) continue;
            // The entry FIRST, then its parts: a recursive type's derived
            // function is a position of itself.
            const index = try s.env.dispatch.derive(kind, .{ .nominal = id }, @intCast(params.len));
            const range = try s.env.dispatch.reserveParts(args.items.len);
            for (args.items, 0..) |arg, j| {
                s.env.dispatch.setPart(range, j, try s.targetFor(c, arg, d.inst_start, 0));
            }
            s.env.dispatch.setDerivedParts(index, range);
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
        try s.generalize(s.rank, false);
        for (headers) |h| {
            if (!try occurs(&s.occurs_frames, s.gpa, s.store(), h.v)) continue;
            s.store().setContent(s.store().find(h.v), .err);
            try s.reporter.infiniteType(h.region, h.name);
        }
        for (headers) |h| try s.promote(h);
        try s.settleUndetermined();
    }

    /// **An evidence slot whose receiver type nothing ever determines**
    /// (§7.2, §8.2).
    ///
    /// `[] == []` is the whole of it. `List.eq` takes one hidden argument
    /// — the element's own `eq` (§5.2) — and §7.2 numbers a site for it at
    /// the `==`. The element type of two empty lists is a variable no use
    /// constrains, so the constraint is neither DISCHARGED, there being no
    /// type to discharge it against, nor PROMOTED, the declaration's own
    /// type not mentioning it. The site stayed empty and the emitted call
    /// was one argument short — which `Lower.evidenceShapeOk` catches as a
    /// table that does not add up, so it is a stopped build and not a
    /// miscompile, but it is a stopped build on a program that is fine.
    ///
    /// The answer is the A.53 bridge, and it is answerable *because* the
    /// type is undetermined: the function handed over can only be called on
    /// a value of that type, and no such value exists in any execution that
    /// gets here — the list is empty, the `Maybe` is `Nothing`. So
    /// `core/Basics.js`'s one structural walk answers `eq`, and §9.1's
    /// comparator answers `compare`. Both are total functions of the right
    /// arity and the right result type, which is all §8.2 asks of an
    /// evidence value.
    ///
    /// It runs after `promote` because "generalisation did not quantify it"
    /// is not known before `promote` has had its chance at it.
    fn settleUndetermined(s: *Solver) Error!void {
        const st = s.store();
        for (s.deferred.items) |d| {
            // A join after the fold moved it (A.75): the replacement is
            // what carries the sites, and what must be marked.
            const at = s.followConstraint(d.index);
            if (at >= st.constraints.items.len) continue;
            if (s.resolved_methods.contains(at)) continue;
            const c = st.constraints.items[at];
            // No site is no call: a constraint raised by the eager pass or
            // by a `where` clause answers nothing an instruction passes.
            const sites = st.constraintSites(c);
            if (sites.len == 0) continue;
            // Read before anything else appends to `constraint_sites`: the
            // view is a slice of a list that grows.
            const region = sites[0].inst;
            const root, const content = st.resolved(d.v);
            if (content != .flex) continue;
            // Promoted after all: `promote` gave it `evidence k`, and a
            // second target here would pass the argument twice. The RANK
            // cannot say this — `generalize` sets every young variable to
            // `generalized` whether or not the declaration's type mentions
            // it, and the one `[] == []` strands is generalised and
            // unquantifiable at once — so the answer is the list `promote`
            // keeps of what it actually claimed.
            if (std.mem.indexOfScalar(Var, s.promoted.items, root) != null) continue;
            const target = undeterminedTarget(s, c) orelse {
                // **A name that is not well known gets a MESSAGE, not a
                // function** (A.66's "not done for a name that is not well
                // known"). Returning null in silence left the slot empty
                // and the emitted call one argument short, which only
                // `Lower.evidenceShapeOk` stopped — an `internal` about a
                // compiler bug, on a program whose only fault is that
                // nothing pins the receiver's type down.
                try s.markResolved(at);
                try s.reporter.undeterminedMethodReceiver(region, c.name, content.flex.kind);
                try s.emitSites(c, .err);
                continue;
            };
            try s.markResolved(at);
            try s.emitSites(c, target);
        }
        s.deferred.clearRetainingCapacity();
    }

    /// What answers a well-known method on a receiver type nothing pins.
    /// A name that is not well known gets nothing: the value that raised it
    /// is a user's own `where` clause, and inventing a function for it
    /// would be inventing a meaning. The caller reports that null — see
    /// `Diagnostics.undeterminedMethodReceiver`; returning it in silence
    /// left the slot empty and the call one argument short.
    fn undeterminedTarget(s: *Solver, c: TypeStore.MethodConstraint) ?Dispatch.Target {
        if (c.name == InternPool.WellKnown.eq.symbol()) return s.structuralEqTarget();
        if (c.name == InternPool.WellKnown.compare.symbol()) return .{ .primitive = .num_compare };
        return null;
    }

    /// **Promotion** (§6.4): a constraint still sitting on a generalised
    /// variable of a declaration becomes part of the declaration's type.
    ///
    /// Constraints ride on `Flags`, so `generalize` already carried them;
    /// what happens here is the bookkeeping that hangs off that — the
    /// declaration's evidence list in the canonical order of §7.2, the sites
    /// of every promoted constraint, and the two diagnostics promotion can
    /// raise.
    ///
    /// An ANNOTATED declaration is skipped: its `where` clause is the whole
    /// set (Rule U2), `Check` built its evidence list from the annotation
    /// before the body was checked, and anything the body needed beyond it
    /// was already `missing_where_constraint`.
    fn promote(s: *Solver, h: Constrain.Header) Error!void {
        if (h.decl == Constrain.Header.no_decl) return;
        const bir = s.env.bir;
        if (h.decl >= bir.decls.len) return;
        const d = bir.decls[h.decl];
        if (d.annotation != .none) return;
        const st = s.store();

        var order: std.ArrayList(Var) = .empty;
        defer order.deinit(s.env.scratch);
        try Schemes.quantifierOrder(st, s.env.interner, h.v, &order, s.env.scratch);

        // The cap (§6.4, §10.11), counted BEFORE anything is emitted: an
        // unannotated declaration — `pub` or not, the quadratic does not
        // care — may promote at most `max_inferred_constraints`.
        var total: u32 = 0;
        for (order.items) |root| total += st.constraintCount(st.flagsOf(root).constraints);
        if (total > max_inferred_constraints) return s.capPromotion(h, d, order.items, total);

        var entries: std.ArrayList(Dispatch.Evidence) = .empty;
        defer entries.deinit(s.env.scratch);
        var index: u16 = 0;
        for (order.items, 0..) |root, q| {
            const flags = st.flagsOf(root);
            const n = st.constraintCount(flags.constraints);
            if (n == 0) continue;
            // A variable another header of this group already promoted:
            // its sites are recorded, and emitting them again would pass
            // the same argument twice. The evidence INDEX still advances —
            // this declaration's own list has a slot for each of them.
            const seen = std.mem.indexOfScalar(Var, s.promoted.items, root) != null;
            if (!seen) try s.promoted.append(s.gpa, root);
            const base = st.constraint_sets.items[flags.constraints.unwrap().?.int()].start;
            const sorted = try s.env.scratch.alloc(u32, n);
            defer s.env.scratch.free(sorted);
            for (sorted, 0..) |*x, j| x.* = base + @as(u32, @intCast(j));
            std.mem.sort(u32, sorted, s, constraintIndexLessThan);
            for (sorted) |at| {
                const c = st.constraints.items[at];
                try entries.append(s.env.scratch, .{
                    .quantified = @intCast(q),
                    .var_name = flags.name,
                    .method = c.name,
                });
                if (!seen) {
                    try s.emitSites(c, .{ .evidence = index });
                    s.counters.constraints_promoted += 1;
                }
                index += 1;
            }
        }
        if (entries.items.len == 0) return;
        const range = try s.env.dispatch.addEvidence(entries.items);
        try s.env.dispatch.setDeclEvidence(bir.decls.len, h.decl, range);

        if (!d.is_pub) return;
        // A `pub` value of ZERO parameters whose promoted scheme carries a
        // constraint would become a function of its evidence parameters
        // (§8.1), silently changing its type across the module boundary.
        if (d.params == 0) {
            try s.reporter.constrainedConstant(
                d.body.unwrap() orelse h.region,
                d.name_token,
                bir.symbol(d.name),
                entries.items[0].var_name,
                entries.items[0].method,
            );
            return;
        }
        // Informational (§10.9), on by default under `check` and `build`
        // since A.83, and only for a module of the ROOT package: a warning
        // about `Dict.foldl` is one nobody can act on, because `core/` is
        // embedded in the binary and a platform package is somebody else's
        // dependency. This is what plan §7's M3 churn measurement counts.
        if (s.env.informational and s.env.graph.module(s.env.module).package == .app) {
            try s.reporter.ambiguousMethodReceiver(
                d.body.unwrap() orelse h.region,
                d.name_token,
                bir.symbol(d.name),
                @intCast(entries.items.len),
                h.v,
            );
        }
    }

    /// **Over the cap** (§6.4, §10.11): report, then generalise the
    /// declaration with NO promoted constraints.
    ///
    /// Three things happen and they all matter. The constraints are dropped
    /// from every quantified variable, so the scheme `Schemes.Writer` puts
    /// in the interface has no `where` suffix. Each of those variables is
    /// entered in `promoted`, so `settleUndetermined` does not then ask
    /// about the same constraints a second time and answer them one message
    /// each. And the declaration gets no evidence list and no sites, so
    /// nothing downstream believes it takes hidden arguments.
    ///
    /// What is NOT touched is the root type: the declaration keeps the shape
    /// it inferred and simply keeps no requirements, which is what lets the
    /// next link of an unannotated chain start again from zero instead of
    /// inheriting a set that is already over the cap (report 19 §3).
    fn capPromotion(
        s: *Solver,
        h: Constrain.Header,
        d: Bir.Decl,
        order: []const Var,
        total: u32,
    ) Error!void {
        const st = s.store();
        // The first few names, in the canonical order of §7.2 — quantifier
        // order, then constraint order within each quantifier — so the
        // message does not depend on which worker checked the module.
        var names: std.ArrayList(Symbol) = .empty;
        defer names.deinit(s.env.scratch);
        for (order) |root| {
            const flags = st.flagsOf(root);
            const n = st.constraintCount(flags.constraints);
            if (n == 0) continue;
            if (names.items.len < named_in_cap_message) {
                const base = st.constraint_sets.items[flags.constraints.unwrap().?.int()].start;
                const sorted = try s.env.scratch.alloc(u32, n);
                defer s.env.scratch.free(sorted);
                for (sorted, 0..) |*x, j| x.* = base + @as(u32, @intCast(j));
                std.mem.sort(u32, sorted, s, constraintIndexLessThan);
                for (sorted) |at| {
                    if (names.items.len == named_in_cap_message) break;
                    try names.append(s.env.scratch, st.constraints.items[at].name);
                }
            }
            if (std.mem.indexOfScalar(Var, s.promoted.items, root) == null) {
                try s.promoted.append(s.gpa, root);
            }
            s.setConstraints(root, flags, .none);
        }
        try s.reporter.tooManyInferredConstraints(
            d.body.unwrap() orelse h.region,
            d.name_token,
            s.env.bir.symbol(d.name),
            total,
            max_inferred_constraints,
            names.items,
        );
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

// A.75, and the half of it a corpus fixture cannot reach: a `tryShape`
// probe rolls the redirect table back by LENGTH, and a key the probe
// re-pointed has to go back to the value it had before the probe — not be
// removed, which would strand the obligations the earlier rebuild moved.
test "the redirect journal restores an overwritten value, not just the key" {
    var r: Solver.Redirects = .{};
    defer r.deinit(testing.allocator);

    // Before the probe: 1 was superseded by 4, and 2 by 5.
    try r.set(testing.allocator, 1, 4);
    try r.set(testing.allocator, 2, 5);
    const mark = r.mark();

    // Inside it: 1 is re-pointed at 7 by a second rebuild, and 3 — a key
    // the probe minted — at 8.
    try r.set(testing.allocator, 1, 7);
    try r.set(testing.allocator, 3, 8);
    try testing.expectEqual(@as(u32, 7), r.follow(1));
    try testing.expectEqual(@as(u32, 8), r.follow(3));

    r.forgetSince(mark);
    try testing.expectEqual(@as(u32, 4), r.follow(1));
    try testing.expectEqual(@as(u32, 5), r.follow(2));
    // Minted inside the probe, so it goes with it: an index the rollback
    // has truncated away will be handed to some other constraint.
    try testing.expectEqual(@as(u32, 3), r.follow(3));

    // The chain is followed to its end, and only forwards.
    try r.set(testing.allocator, 4, 9);
    try testing.expectEqual(@as(u32, 9), r.follow(1));
}
