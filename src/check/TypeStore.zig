//! The type store (docs/design/checker.md §5): descriptors, union-find,
//! Rémy levels and the undo journal — Elm's `Type.Variable` plus Roc's
//! `types/store.zig`, laid out under the design's data rules.
//!
//! **A type variable IS a graph node.** There is no substitution anywhere in
//! the checker; "apply the substitution" is `find`, and unification mutates
//! the graph in place (`fast-compiler.md` §7 #1, research/02 §2.1). Every
//! reference is a `Var = enum(u32)` index into ONE `MultiArrayList` of
//! descriptors, so a type is copied by copying an integer and compared by
//! comparing one.
//!
//! Two integers on a descriptor are easy to confuse and must not be:
//!
//!   - **`size`** is the union-find tree weight. `union` hangs the smaller
//!     tree under the larger; `find` compresses the path it walked. That is
//!     the only thing it is for.
//!   - **`rank`** is the Rémy/Kiselyov level — the depth of the enclosing
//!     `let` — and `generalized` (0) marks a variable that has been
//!     quantified. Generalisation scans the POOL of variables allocated at
//!     one rank and never the environment, which is what makes it
//!     asymptotically cheap (research/02 §2.2). Elm keeps the two apart the
//!     same way and reuses the word "rank" for the weight; this file does
//!     not.
//!
//! **Structures live in `extra`.** A descriptor is fixed size; the argument
//! list of an `app`, the elements of a `tuple` and the `(field, var)` pairs
//! of a `record` are ranges into one shared `[]u32` sidecar. A record's
//! fields are kept sorted by symbol id so unification can merge-join two
//! field sets in one pass; nothing observable is ordered by that, because
//! `Render` sorts by the field's TEXT (a `Symbol` id depends on `--jobs`,
//! see `InternPool`'s header).
//!
//! **Aliases are interned, never expanded** (checker.md §5, the Roc
//! behaviour §3.1 adopts): an `alias` descriptor carries the alias's
//! `TypeId`, its argument vars and the `actual` var of its one expansion.
//! Unification looks through to `actual`; error rendering prints the name.
//! Expanding at every use would turn a project's record aliases into the
//! doubling blowup instantiation's `copy` memo exists to prevent.
//!
//! **The undo journal** brackets a speculative unification. `mark` returns a
//! `Snapshot`; every later mutation of `parent`, `rank`, `content` or `size`
//! pushes the OLD descriptor, and `rollback` restores them in reverse and
//! truncates the vars and `extra` created since. M2b's only speculator is
//! `?` (checker.md §6.5, which tries `Result` and then `Maybe`), but the
//! journal is built now because retrofitting one is exactly the rework
//! `fast-compiler.md` §13 warns about. With no mark outstanding, journaling
//! is one `depth == 0` test and nothing is recorded.
//!
//! One store per module being checked, owned by the worker checking it and
//! backed by an `Arena` it owns, so the whole thing is released in one call
//! once the interface has been extracted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = @import("../Arena.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");

const TypeStore = @This();

pub const Symbol = InternPool.Symbol;

/// A union-find node. Only a ROOT's `content`, `rank` and `size` mean
/// anything; reach one with `find`.
pub const Var = enum(u32) {
    _,

    pub fn int(v: Var) u32 {
        return @intFromEnum(v);
    }

    pub fn toOptional(v: Var) Optional {
        const o: Optional = @enumFromInt(@intFromEnum(v));
        std.debug.assert(o != .none);
        return o;
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?Var {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };
};

/// A type or alias declaration, dense across the whole session
/// (checker.md §5: "type ids are dense ... so type identity is one integer
/// compare"). The table itself is `check/TypeTable.zig`; the store only
/// ever compares these.
pub const TypeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn int(t: TypeId) u32 {
        return @intFromEnum(t);
    }
};

/// The closed set of ad-hoc constraints of `fast-compiler.md` §3.1. Nothing
/// may be added here without revisiting that section: `comparable` is the
/// one that would force an O(term size) walk back onto the unification hot
/// path, and it is the reason this enum is three values and not four.
///
/// The lattice is `any ⊒ number`, `any ⊒ appendable`, and
/// `number ⊓ appendable = ⊥` (checker.md §6.2).
pub const Kind = enum(u8) {
    any,
    number,
    appendable,

    /// The greatest lower bound, or null when the two are incompatible
    /// (`kind_mismatch`).
    pub fn meet(a: Kind, b: Kind) ?Kind {
        if (a == b) return a;
        if (a == .any) return b;
        if (b == .any) return a;
        return null;
    }

    pub fn text(k: Kind) []const u8 {
        return switch (k) {
            .any => "a",
            .number => "number",
            .appendable => "appendable",
        };
    }
};

/// What a variable is once `find` has reached its root.
pub const Content = union(enum) {
    /// Unconstrained, or constrained only by `kind`/`equatable`.
    flex: Flags,
    /// Introduced by an annotation's type variable: unifies only with
    /// itself (`rigid_mismatch` otherwise), so an annotation really is a
    /// promise about ALL types and not about the one the body happens to
    /// use.
    rigid: Flags,
    structure: Structure,
    /// Interned, never expanded (see the header).
    alias: Alias,
    /// Poisoned. Unifies with anything, silently: "errors never stop the
    /// build" (`fast-compiler.md` §7), and this is what keeps one mistake
    /// to one message instead of forty.
    err,
};

pub const Flags = struct {
    /// The name the annotation spelled, for `rigid_mismatch`'s prose. Never
    /// used for identity — two rigid variables named `a` in two annotations
    /// are different variables.
    name: Symbol.Optional = .none,
    kind: Kind = .any,
    /// `==` may be used on this variable's type (checker.md §6.3). It rides
    /// next to `kind` rather than inside it because it is orthogonal: a
    /// `number` is also equatable.
    equatable: bool = false,
    /// The method constraints this variable carries
    /// (static-dispatch-spike.md §6.1): an index into `constraint_sets`, or
    /// `.none`. It rides here, beside `equatable`, because flex and rigid
    /// share this payload and a constraint is exactly as orthogonal to
    /// `kind` as `equatable` is — the same place Roc keeps
    /// `Flex.constraints`.
    ///
    /// `Descriptor` does not grow: `Flags` goes from 8 bytes to 12 and the
    /// largest `Content` payload is already `Alias` at 16.
    constraints: ConstraintSet.Optional = .none,
    /// The open obligations riding on this variable (checker-v2.md §4.1,
    /// §4.5): a set in the checker's own table (`check/Obligations.zig`),
    /// opaque here (§4.1, *Decided by R5*). A store no check builds — an
    /// interface dump's — leaves it `.none`.
    obls: ObligationSet = .none,
};

/// A set of the checker's obligations (`check/Obligations.zig`). The store
/// only carries it on a variable's `Flags`; what it names is the checker's.
pub const ObligationSet = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

comptime {
    // `obls` grew `Flags` from 12 to 16 bytes; `Content` did not grow,
    // because `Structure` and `Alias` are already 16 (checker-v2.md §4.1).
    std.debug.assert(@sizeOf(Flags) == 16);
    std.debug.assert(@sizeOf(Content) == 20);
}

/// One method constraint on a type variable (static-dispatch-spike.md
/// §6.1): "whatever type ends up here has a method `name` at `fn_var`".
pub const MethodConstraint = struct {
    /// The method's name.
    name: Symbol,
    /// The method's type AT THIS USE, e.g. `a, A, B -> R`.
    fn_var: Var,
    /// Where the constraint was written: the `x.m` call, the operator, or
    /// the `where` clause. NOT where the obligation that carries it was
    /// created — that is `Solve.Obligation.origin` (§6.2).
    region: Bir.Inst.Index,
    origin: Origin,

    pub const Origin = enum(u8) { dot_call, well_known, where_clause, type_dispatch };
};

/// A run of `constraints`, named by its index in `constraint_sets`.
///
/// Sets are APPEND-ONLY and never mutated: merging two appends a third and
/// leaves both originals, so the undo journal rolls speculation back by
/// truncating two lengths (§6.1 invariant 2).
pub const ConstraintSet = enum(u32) {
    _,

    pub fn int(c: ConstraintSet) u32 {
        return @intFromEnum(c);
    }

    pub fn toOptional(c: ConstraintSet) Optional {
        return @enumFromInt(@intFromEnum(c));
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?ConstraintSet {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };
};

pub const Structure = union(enum) {
    /// `()`.
    unit,
    /// The closed end of a record's extension chain — Elm's
    /// `EmptyRecord1`. A record literal's extension is this; an open
    /// record's is a flex var.
    empty_record,
    func: Func,
    app: App,
    /// Elements, in order.
    tuple: Range,
    record: Record,

    /// `p1, …, pn -> result` (language.md §6.7). The parameters are a
    /// RANGE and not one var: function types are n-ary and unify only at
    /// equal arity, so the count is part of the structure head and an
    /// arity difference is an ordinary structure mismatch.
    pub const Func = struct { params: Range, result: Var };
    pub const App = struct { type: TypeId, args: Range };
    pub const Record = struct {
        /// `(field Symbol, Var)` pairs, sorted by symbol id.
        fields: Range,
        ext: Var,
    };
};

pub const Alias = struct {
    type: TypeId,
    /// The alias's arguments, in declaration order.
    args: Range,
    /// The expansion, created once when the alias was instantiated.
    actual: Var,
};

/// A half-open run of `extra`, as `[start, start + len)`.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub const empty: Range = .{};
};

pub const Descriptor = struct {
    parent: Var,
    rank: u32,
    content: Content,
    mark: u32,
    copy: Var.Optional,
    /// Union-find tree weight; see the header.
    size: u32,
};

/// `rank == generalized` means the variable has been quantified and is a
/// scheme's bound variable (Elm's `noRank`).
pub const generalized: u32 = 0;
/// The rank of a top-level binding group (Elm's `outermostRank`).
pub const outermost: u32 = 1;

/// `mark == none` is "not visited by anything". Marks are handed out by
/// `nextMark` and are monotone, so a walk never has to clear them.
pub const no_mark: u32 = 0;

arena: Arena,
descriptors: std.MultiArrayList(Descriptor) = .empty,
extra: std.ArrayList(u32) = .empty,
/// Undo entries, newest last. Empty unless a `mark` is outstanding.
journal: std.ArrayList(Entry) = .empty,
/// Every method constraint ever created, in creation order
/// (static-dispatch-spike.md §6.1 invariant 1). A `ConstraintSet` is a run
/// of this list; nothing is ever removed out of order, so rollback is a
/// truncation.
constraints: std.ArrayList(MethodConstraint) = .empty,
/// One `Range` per set, indexed by `ConstraintSet`.
constraint_sets: std.ArrayList(Range) = .empty,
/// How many `mark`s are outstanding. Journaling is off at zero, which is
/// the whole of a normal solve.
depth: u32 = 0,
/// A journal entry could not be allocated, so the outstanding speculation
/// can no longer be undone exactly. `rollback` reports it; the only caller
/// (`?`, checker.md §6.5) treats an inexact rollback as "this shape did not
/// fit" and stops trying alternatives.
broken: bool = false,
next_mark: u32 = no_mark + 1,
/// Checker v2's acyclicity proofs (`checker-v2.md` §8.2 *as restated by R8c's
/// review rounds*): per variable, the epoch in which an occurs walk proved
/// it acyclic. They live here, beside the content they are about, because
/// every write that can add an edge to a proved graph or leave it an
/// unrecorded leaf — a proved leaf given successors, any write touching an
/// `err` with successors on either side — goes through `setContent` or
/// `merge`, which void them (`gains`, `touchesErr`). The
/// epoch wraps after 2³² voids and restarts at 1 with the table cleared;
/// what must not see a stale epoch keys on `proof_voids`. A store that
/// does not prove (`tracks_proofs`) pays one branch per content write.
acyclic: std.ArrayList(u32) = .empty,
acyclic_epoch: u32 = 1,
/// How many times the proofs were voided: never wraps, so a memo keyed on it
/// (`check/Resolve.zig`'s `derivable_open`) cannot match a stale epoch after
/// `acyclic_epoch` wraps and restarts.
proof_voids: u64 = 0,
/// Whether this store keeps the proofs at all: set by a module's check
/// (`check/Module.zig`); a store nothing checks in (an interface dump's,
/// a test's) does not prove, and pays one branch per content write.
tracks_proofs: bool = false,
/// How many times `rollback` ran: never decreases. The checker never
/// speculates (§7.5), so under it it stays 0; its memos keyed by a variable
/// id (`check/Derivable.zig`'s `GroundMemo` and `Shapes.last`) record it
/// and refuse to be read across a rollback, which could reuse an id for
/// another type (CK-131, R9b).
rollbacks: u32 = 0,
/// Debug only: the nodes `Walk.assertProved` has visited in this store, so
/// its re-walks of proved graphs stay within a budget linear in the store
/// (CK-133). Never read outside that assert.
proof_assert_work: u64 = 0,

const Entry = struct { v: Var, desc: Descriptor };

/// What `rollback` restores to.
pub const Snapshot = struct {
    journal_len: u32,
    vars: u32,
    extra: u32,
    /// The three append-only constraint tables, truncated by `rollback`
    /// exactly as `vars` and `extra` are (static-dispatch-spike.md §6.1
    /// invariant 2, A.35). The truncation is PER SNAPSHOT and not one saved
    /// length, because this journal nests (`depth`) where Roc's asserts it
    /// does not.
    ///
    /// The four `Dispatch` builders of §7.1 are journaled the same way, but
    /// by `Solve.tryShape` beside the pool and the obligation list, which is
    /// where the solver's own per-rank bookkeeping is already rolled back;
    /// the store does not own them and a pointer from here to the solver
    /// would be the only one in the file.
    constraints: u32,
    constraint_sets: u32,
};

pub fn init(backing: Allocator) TypeStore {
    return .{ .arena = .init(backing) };
}

pub fn deinit(store: *TypeStore) void {
    store.arena.deinit();
    store.* = undefined;
}

fn gpa(store: *TypeStore) Allocator {
    return store.arena.allocator();
}

/// Hint the expected variable count so the descriptor column is grown once
/// rather than a dozen times. An arena cannot free the old block, so every
/// avoided growth is memory saved as well as time.
pub fn reserve(store: *TypeStore, var_count: usize, extra_words: usize) Allocator.Error!void {
    try store.descriptors.ensureTotalCapacity(store.gpa(), var_count);
    try store.extra.ensureTotalCapacity(store.gpa(), extra_words);
}

pub fn count(store: *const TypeStore) u32 {
    return @intCast(store.descriptors.len);
}

// ---------------------------------------------------------------------------
// Allocation
// ---------------------------------------------------------------------------

/// A new root with `content` at `rank`. The caller is responsible for
/// putting it in the pool of that rank (`Solve` does).
pub fn fresh(store: *TypeStore, desc_content: Content, desc_rank: u32) Allocator.Error!Var {
    const v: Var = @enumFromInt(store.descriptors.len);
    try store.descriptors.append(store.gpa(), .{
        .parent = v,
        .rank = desc_rank,
        .content = desc_content,
        .mark = no_mark,
        .copy = .none,
        .size = 1,
    });
    return v;
}

/// An unconstrained variable at `rank`.
pub fn freshFlex(store: *TypeStore, at_rank: u32) Allocator.Error!Var {
    return store.fresh(.{ .flex = .{} }, at_rank);
}

/// A poisoned variable: the result of anything that already produced a
/// diagnostic.
pub fn freshErr(store: *TypeStore, at_rank: u32) Allocator.Error!Var {
    return store.fresh(.err, at_rank);
}

pub fn nextMark(store: *TypeStore) u32 {
    store.next_mark += 1;
    return store.next_mark;
}

// ---------------------------------------------------------------------------
// Union-find
// ---------------------------------------------------------------------------

/// The representative of `v`, compressing the path walked. The ONLY place
/// that walks parents; every other operation takes roots.
pub fn find(store: *TypeStore, v: Var) Var {
    const parents = store.descriptors.items(.parent);
    var root = v;
    while (parents[root.int()] != root) root = parents[root.int()];
    // Compress: point everything on the path straight at the root. Under a
    // mark this is journalled like any other write, so a rollback restores
    // the original chain — the shape is not observable either way.
    var walk = v;
    while (parents[walk.int()] != root) {
        const next = parents[walk.int()];
        store.setParent(walk, root);
        walk = next;
    }
    return root;
}

/// Merge the two trees, with `survivor` as the content, and return the
/// surviving root. Both arguments must be ROOTS; they may be the SAME root,
/// which happens whenever unifying two structures' children has already
/// merged them — a recursive type does it routinely — and which Elm handles
/// the same way (`Type/UnionFind.hs`'s `union` writes the descriptor and
/// stops when the two points are equal).
///
/// The survivor is the heavier tree (union by size) and keeps the SMALLER
/// of the two ranks: a variable reachable from an outer scope may not be
/// generalised by an inner one (Kiselyov: "update the level of each free
/// type variable to the smallest of the two").
pub fn merge(store: *TypeStore, a: Var, b: Var, survivor: Content) Var {
    if (a == b) {
        store.setContent(a, survivor);
        return a;
    }
    const sizes = store.descriptors.items(.size);
    const ranks = store.descriptors.items(.rank);
    const merged_rank = @min(ranks[a.int()], ranks[b.int()]);
    const keep, const drop = if (sizes[a.int()] >= sizes[b.int()]) .{ a, b } else .{ b, a };
    const total = sizes[a.int()] + sizes[b.int()];
    var carry = false;
    var epoch: u32 = 0;
    if (store.tracks_proofs) {
        const contents = store.descriptors.items(.content);
        store.touchesErr(contents[a.int()], contents[b.int()], survivor);
        const pa = store.proved(a);
        const pb = store.proved(b);
        if (pa or pb) {
            carry = true;
            epoch = store.acyclic_epoch;
            if (pa) store.gains(a, survivor);
            if (pb) store.gains(b, survivor);
        }
    }
    store.record(drop);
    store.record(keep);
    const parents = store.descriptors.items(.parent);
    parents[drop.int()] = keep;
    sizes[keep.int()] = total;
    ranks[keep.int()] = merged_rank;
    store.descriptors.items(.content)[keep.int()] = survivor;
    // A class keeps a proof either side had, unless the merge voided every
    // proof: a proved flat structure's children were unified with the other
    // side's before the merge, a proved leaf that stays a leaf gains no edge,
    // and a record's new rows reach it through a bind or an `err` (both void) (§8.2 *as restated by R8c's review rounds*).
    if (carry and store.acyclic_epoch == epoch) store.prove(keep);
    return keep;
}

// ---------------------------------------------------------------------------
// Descriptor access. Reads take any var and are NOT self-finding: passing a
// non-root is a bug in the caller, and making these find would hide it.
// ---------------------------------------------------------------------------

pub fn get(store: *const TypeStore, v: Var) Descriptor {
    return store.descriptors.get(v.int());
}

pub fn content(store: *const TypeStore, v: Var) Content {
    return store.descriptors.items(.content)[v.int()];
}

pub fn rank(store: *const TypeStore, v: Var) u32 {
    return store.descriptors.items(.rank)[v.int()];
}

pub fn mark(store: *const TypeStore, v: Var) u32 {
    return store.descriptors.items(.mark)[v.int()];
}

pub fn copy(store: *const TypeStore, v: Var) Var.Optional {
    return store.descriptors.items(.copy)[v.int()];
}

/// Whether `v` was proved acyclic in the current epoch.
pub fn proved(store: *const TypeStore, v: Var) bool {
    return v.int() < store.acyclic.items.len and store.acyclic.items[v.int()] == store.acyclic_epoch;
}

/// Record that `v` is acyclic, and that every node it reaches was walked.
/// Out of memory voids every proof instead: a proof is only ever a skipped
/// walk.
pub fn prove(store: *TypeStore, v: Var) void {
    if (!store.tracks_proofs) return;
    if (v.int() >= store.acyclic.items.len) {
        const want = @max(store.count(), v.int() + 1);
        store.acyclic.appendNTimes(store.gpa(), 0, want - store.acyclic.items.len) catch return store.voidProofs();
    }
    store.acyclic.items[v.int()] = store.acyclic_epoch;
}

/// Every proof is void.
pub fn voidProofs(store: *TypeStore) void {
    store.proof_voids += 1;
    store.acyclic_epoch +%= 1;
    if (store.acyclic_epoch == 0) {
        @memset(store.acyclic.items, 0);
        store.acyclic_epoch = 1;
    }
}

fn hasSuccessors(c: Content) bool {
    return switch (c) {
        .err, .flex, .rigid => false,
        .alias => true,
        .structure => |flat| switch (flat) {
            .unit, .empty_record => false,
            .app => |a| a.args.len != 0,
            .func, .tuple, .record => true,
        },
    };
}

/// The proved node `v`'s content is about to become `c` (the callers test
/// `proved` first: it is the cheap half). A proved leaf given successors adds
/// an edge to a proved graph, so every proof is void; so, conservatively, is a
/// proved structure overwritten with another kind. What a merge's survivor
/// holds besides that is the `err` rule's (`touchesErr`) and §8.2's argument
/// (`checker-v2.md` §8.2 *as restated by R8c's review rounds*).
/// The `err` rule (§8.2 *as restated by R8c's review rounds*): a write where
/// one side is `err` — before or after — and any side has successors voids
/// every proof. `err` is the one kind without successors that can absorb a
/// structure (a merge whose survivor is `err`, a poison: an unrecorded leaf
/// in a proved graph, or a record's extra fields absorbed into an `err` row
/// end and carried on unwalked) or be given one outside a proved leaf's bind
/// (`Unify.flat` writes the structure it read before the children were
/// unified). The broad form, not the narrowest one an argument allows: two
/// holes came from arguments that a narrower condition sufficed (the
/// manager, 2026-09-26). It costs a content read per merge, about 0.8 % of
/// instructions on the generated dispatch corpus.
fn touchesErr(store: *TypeStore, before_a: Content, before_b: Content, after: Content) void {
    if (before_a != .err and before_b != .err and after != .err) return;
    if (hasSuccessors(before_a) or hasSuccessors(before_b) or hasSuccessors(after)) store.voidProofs();
}

fn gains(store: *TypeStore, v: Var, c: Content) void {
    if (!hasSuccessors(c)) return;
    const before = store.descriptors.items(.content)[v.int()];
    if (!hasSuccessors(before) or std.meta.activeTag(before) != std.meta.activeTag(c)) store.voidProofs();
}

pub fn setContent(store: *TypeStore, v: Var, c: Content) void {
    store.record(v);
    if (store.tracks_proofs) {
        store.touchesErr(store.descriptors.items(.content)[v.int()], c, c);
        if (store.proved(v)) store.gains(v, c);
    }
    store.descriptors.items(.content)[v.int()] = c;
}

pub fn setRank(store: *TypeStore, v: Var, r: u32) void {
    store.record(v);
    store.descriptors.items(.rank)[v.int()] = r;
}

/// `mark` and `copy` are scratch columns of one walk each and are never
/// rolled back: a speculative unification that is undone leaves them
/// stale, and every consumer stamps a FRESH mark (`nextMark`) or clears
/// `copy` through its own touched-list before reading.
pub fn setMark(store: *TypeStore, v: Var, m: u32) void {
    store.descriptors.items(.mark)[v.int()] = m;
}

pub fn setCopy(store: *TypeStore, v: Var, c: Var.Optional) void {
    store.descriptors.items(.copy)[v.int()] = c;
}

fn setParent(store: *TypeStore, v: Var, parent: Var) void {
    store.record(v);
    store.descriptors.items(.parent)[v.int()] = parent;
}

/// The content of `v`'s root, following aliases to their expansion. What
/// unification and every structural walk want: an alias is a NAME for its
/// expansion and is transparent to everything except rendering.
/// The content behind `v` with every alias looked through, and the root the
/// walk ended on. Most callers want only the content — `resolvedContent` is
/// that, and exists so they do not have to name a root they then discard.
pub fn resolvedContent(store: *TypeStore, v: Var) Content {
    _, const c = store.resolved(v);
    return c;
}

pub fn resolved(store: *TypeStore, v: Var) struct { Var, Content } {
    var root = store.find(v);
    var guard: u32 = 0;
    while (true) {
        const c = store.content(root);
        switch (c) {
            // An alias chain is as deep as the source nests aliases, and
            // `recursive_alias` has already refused the cyclic ones; the
            // guard is belt and braces against a poisoned chain.
            .alias => |a| {
                guard += 1;
                if (guard > 1024) return .{ root, .err };
                root = store.find(a.actual);
            },
            else => return .{ root, c },
        }
    }
}

/// How many parameters `v`'s type takes, looking through aliases: the
/// ARITY of a function type, which is what §8.3's arity messages and the
/// arity hint both count. Zero when `v` is not a function.
///
/// Since function types are n-ary (language.md §6.7) this is one lookup and
/// not a walk down a chain of arrows: `a, b -> c -> d` takes two arguments
/// and returns a function of one, and counting three there would be exactly
/// the conflation currying forced.
///
/// Here rather than in either caller because it was written twice, verbatim,
/// in `Solve` and in `Diagnostics` — and the two have to agree: one decides
/// whether a call's arity is wrong, the other writes the sentence about it.
pub fn paramCount(store: *TypeStore, v: Var) u32 {
    return switch (store.resolvedContent(v)) {
        .structure => |flat| switch (flat) {
            .func => |func| func.params.len,
            else => 0,
        },
        else => 0,
    };
}

/// Whether `v` is `n` ≥ 2 nested 1-ary functions, `A -> B -> … -> R`: Elm's
/// curried annotation of a definition of `n` parameters (checker.md §8.7,
/// CK-56). `curriedParam` and `curriedResult` read its levels.
pub fn isCurried(store: *TypeStore, v: Var, n: u32) bool {
    if (n < 2) return false;
    var at = v;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const f = store.oneParam(at) orelse return false;
        at = f.result;
    }
    return true;
}

/// The parameter of level `i` of a curried chain (`isCurried`).
pub fn curriedParam(store: *TypeStore, v: Var, i: u32) Var {
    var at = v;
    var k: u32 = 0;
    while (k < i) : (k += 1) at = store.oneParam(at).?.result;
    return store.vars(store.oneParam(at).?.params)[0];
}

/// What `n` levels of a curried chain return (`isCurried`).
pub fn curriedResult(store: *TypeStore, v: Var, n: u32) Var {
    var at = v;
    var k: u32 = 0;
    while (k < n) : (k += 1) at = store.oneParam(at).?.result;
    return at;
}

fn oneParam(store: *TypeStore, v: Var) ?Structure.Func {
    return switch (store.resolvedContent(v)) {
        .structure => |flat| switch (flat) {
            .func => |func| if (func.params.len == 1) func else null,
            else => null,
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// `extra`
// ---------------------------------------------------------------------------

pub fn addVars(store: *TypeStore, items: []const Var) Allocator.Error!Range {
    const start: u32 = @intCast(store.extra.items.len);
    try store.extra.appendSlice(store.gpa(), @ptrCast(items));
    return .{ .start = start, .len = @intCast(items.len) };
}

pub fn vars(store: *const TypeStore, r: Range) []const Var {
    return @ptrCast(store.extra.items[r.start..][0..r.len]);
}

/// One `(field, var)` pair of a record.
pub const Field = struct { name: Symbol, value: Var };

/// Append `fields`, sorting them by symbol id so unification can merge-join
/// (see the header for why that order is never observable).
pub fn addFields(store: *TypeStore, items: []Field) Allocator.Error!Range {
    std.mem.sort(Field, items, {}, fieldLessThan);
    const start: u32 = @intCast(store.extra.items.len);
    try store.extra.ensureUnusedCapacity(store.gpa(), items.len * 2);
    for (items) |f| {
        store.extra.appendAssumeCapacity(@intFromEnum(f.name));
        store.extra.appendAssumeCapacity(@intFromEnum(f.value));
    }
    return .{ .start = start, .len = @intCast(items.len) };
}

fn fieldLessThan(_: void, a: Field, b: Field) bool {
    return @intFromEnum(a.name) < @intFromEnum(b.name);
}

pub fn fields(store: *const TypeStore, r: Range) []const Field {
    const words = store.extra.items[r.start..][0 .. r.len * 2];
    return @ptrCast(words);
}

comptime {
    // `addFields`/`fields` reinterpret the sidecar as pairs; two u32 per
    // field is the whole reason a record needs no side table.
    std.debug.assert(@sizeOf(Field) == 8);
    std.debug.assert(@sizeOf(Var) == 4);
}

// ---------------------------------------------------------------------------
// Method constraints (static-dispatch-spike.md §6.1)
// ---------------------------------------------------------------------------

/// A new set holding `items`, appended. Neither any existing set nor any
/// existing constraint is touched (invariant 2).
pub fn addConstraints(store: *TypeStore, items: []const MethodConstraint) Allocator.Error!ConstraintSet {
    const start: u32 = @intCast(store.constraints.items.len);
    try store.constraints.appendSlice(store.gpa(), items);
    const index: u32 = @intCast(store.constraint_sets.items.len);
    try store.constraint_sets.append(store.gpa(), .{ .start = start, .len = @intCast(items.len) });
    return @enumFromInt(index);
}

/// `set` with `c` appended, as a new set.
///
/// A set is a half-open RANGE of an append-only list, so when the old range
/// already ends at the tail this is one append and one range; otherwise it
/// is one copy. Neither the old set nor any existing constraint is touched
/// (invariant 2), and rollback is still a truncation of both lists.
pub fn extendConstraints(
    store: *TypeStore,
    set: ConstraintSet.Optional,
    c: MethodConstraint,
) Allocator.Error!ConstraintSet.Optional {
    const existing = set.unwrap() orelse {
        return (try store.addConstraints(&.{c})).toOptional();
    };
    const range = store.constraint_sets.items[existing.int()];
    if (range.start + range.len == store.constraints.items.len) {
        try store.constraints.append(store.gpa(), c);
        const index: u32 = @intCast(store.constraint_sets.items.len);
        try store.constraint_sets.append(store.gpa(), .{ .start = range.start, .len = range.len + 1 });
        return (@as(ConstraintSet, @enumFromInt(index))).toOptional();
    }
    // Capacity first: `appendSlice` from the list into itself would read a
    // slice the growth had already moved.
    try store.constraints.ensureUnusedCapacity(store.gpa(), range.len + 1);
    const start: u32 = @intCast(store.constraints.items.len);
    store.constraints.appendSliceAssumeCapacity(store.constraints.items[range.start..][0..range.len]);
    store.constraints.appendAssumeCapacity(c);
    const index: u32 = @intCast(store.constraint_sets.items.len);
    try store.constraint_sets.append(store.gpa(), .{ .start = start, .len = range.len + 1 });
    return (@as(ConstraintSet, @enumFromInt(index))).toOptional();
}

/// How many constraints `set` holds. Prefer this and `constraintAt` to
/// holding the slice: unifying a pair can grow `constraints` from under a
/// view, which is a use-after-realloc (§6.1 invariant 2).
pub fn constraintCount(store: *const TypeStore, set: ConstraintSet.Optional) u32 {
    const s = set.unwrap() orelse return 0;
    if (s.int() >= store.constraint_sets.items.len) return 0;
    return store.constraint_sets.items[s.int()].len;
}

/// The `i`th constraint of `set`, BY VALUE. Re-fetched per iteration on
/// purpose; see `constraintCount`.
pub fn constraintAt(store: *const TypeStore, set: ConstraintSet.Optional, i: u32) MethodConstraint {
    const s = set.unwrap().?;
    const range = store.constraint_sets.items[s.int()];
    return store.constraints.items[range.start + i];
}

/// The constraint named `name` in `set`, or null.
pub fn findConstraint(store: *const TypeStore, set: ConstraintSet.Optional, name: Symbol) ?MethodConstraint {
    const n = store.constraintCount(set);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const c = store.constraintAt(set, i);
        if (c.name == name) return c;
    }
    return null;
}

/// The flags of `v`'s root, or an empty set when it is not a variable.
pub fn flagsOf(store: *const TypeStore, v: Var) Flags {
    return switch (store.content(v)) {
        .flex, .rigid => |f| f,
        else => .{},
    };
}

// ---------------------------------------------------------------------------
// The undo journal
// ---------------------------------------------------------------------------

/// Push `v`'s current descriptor, if a mark is outstanding. Called by every
/// mutator; one predictable branch when nothing is speculating.
fn record(store: *TypeStore, v: Var) void {
    if (store.depth == 0 or store.broken) return;
    // A journal that could not record a write can no longer undo one, so
    // the region is marked BROKEN rather than closed: `rollback` then
    // restores what it can and says so, and the bracket stays balanced —
    // zeroing `depth` here would make the matching `rollback` decrement it
    // below zero.
    store.journal.append(store.gpa(), .{ .v = v, .desc = store.get(v) }) catch {
        store.broken = true;
    };
}

/// Open a speculative region. Every mutation until the matching `commit` or
/// `rollback` is undoable.
pub fn beginSpeculation(store: *TypeStore) Snapshot {
    store.depth += 1;
    return .{
        .journal_len = @intCast(store.journal.items.len),
        .vars = @intCast(store.descriptors.len),
        .extra = @intCast(store.extra.items.len),
        .constraints = @intCast(store.constraints.items.len),
        .constraint_sets = @intCast(store.constraint_sets.items.len),
    };
}

/// Keep everything the speculation did.
pub fn commit(store: *TypeStore, snapshot: Snapshot) void {
    std.debug.assert(store.depth > 0);
    store.depth -= 1;
    if (store.depth == 0) {
        store.journal.clearRetainingCapacity();
        store.broken = false;
    } else {
        store.journal.shrinkRetainingCapacity(snapshot.journal_len);
    }
}

/// Undo everything the speculation did: descriptors in reverse order, then
/// the variables and `extra` words it appended. Returns false when the
/// journal ran out of memory and the undo is therefore incomplete.
///
/// **An inexact undo keeps the variables it could not unwind.** Truncating
/// `descriptors` back to the snapshot is only safe when every write is
/// known to have been undone: a pre-existing descriptor whose `parent` was
/// re-pointed at a variable CREATED during the speculation, and whose old
/// value the journal could not record, would otherwise point past the end
/// of the column and the next `find` would index out of bounds. The store
/// outlives the speculation — the rest of the module's check keeps using it
/// — so leaking the speculation's variables is the cheap half of the
/// trade. The sole caller stops guessing once an undo comes back inexact.
pub fn rollback(store: *TypeStore, snapshot: Snapshot) bool {
    std.debug.assert(store.depth > 0);
    // A rolled-back write is not seen by the proofs, and a reused index could
    // read as proved: v2 never speculates (§7.5), and a rollback voids them.
    if (store.tracks_proofs) store.voidProofs();
    store.rollbacks +%= 1;
    store.depth -= 1;
    const exact = !store.broken;
    var i = store.journal.items.len;
    while (i > snapshot.journal_len) {
        i -= 1;
        const entry = store.journal.items[i];
        store.descriptors.set(entry.v.int(), entry.desc);
    }
    store.journal.shrinkRetainingCapacity(snapshot.journal_len);
    if (store.depth == 0) {
        store.journal.clearRetainingCapacity();
        store.broken = false;
    }
    if (exact) {
        store.descriptors.shrinkRetainingCapacity(snapshot.vars);
        store.extra.shrinkRetainingCapacity(snapshot.extra);
        store.constraints.shrinkRetainingCapacity(snapshot.constraints);
        store.constraint_sets.shrinkRetainingCapacity(snapshot.constraint_sets);
    }
    return exact;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "find compresses the path and union by size keeps the heavier root" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();

    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    const c = try store.freshFlex(1);
    // `a` and `b` merge into a tree of two; `c` is alone, so merging it in
    // must leave the two-node tree's root standing.
    const ab = store.merge(a, b, .{ .flex = .{} });
    try testing.expectEqual(a, ab);
    const abc = store.merge(store.find(c), ab, .{ .flex = .{} });
    try testing.expectEqual(a, abc);
    try testing.expectEqual(@as(u32, 3), store.get(a).size);

    // Every member finds the same root, and afterwards points at it
    // directly.
    for ([_]Var{ a, b, c }) |v| try testing.expectEqual(a, store.find(v));
    for ([_]Var{ a, b, c }) |v| try testing.expectEqual(a, store.get(v).parent);
}

test "merge keeps the smaller rank: an inner scope may not generalise an outer variable" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const outer = try store.freshFlex(1);
    const inner = try store.freshFlex(4);
    const root = store.merge(outer, inner, .{ .flex = .{} });
    try testing.expectEqual(@as(u32, 1), store.rank(root));
}

test "the kind lattice: any is the top, number and appendable do not meet" {
    try testing.expectEqual(@as(?Kind, .number), Kind.meet(.any, .number));
    try testing.expectEqual(@as(?Kind, .number), Kind.meet(.number, .any));
    try testing.expectEqual(@as(?Kind, .appendable), Kind.meet(.appendable, .appendable));
    try testing.expectEqual(@as(?Kind, .any), Kind.meet(.any, .any));
    try testing.expectEqual(@as(?Kind, null), Kind.meet(.number, .appendable));
    try testing.expectEqual(@as(?Kind, null), Kind.meet(.appendable, .number));
}

test "resolved looks through an alias chain to the expansion" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const int = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(7), .args = .empty } } }, 1);
    const inner = try store.fresh(.{ .alias = .{ .type = @enumFromInt(1), .args = .empty, .actual = int } }, 1);
    const outer = try store.fresh(.{ .alias = .{ .type = @enumFromInt(2), .args = .empty, .actual = inner } }, 1);
    // The alias is still what the descriptor says — it is never expanded
    // away — but `resolved` reaches the structure under it.
    try testing.expect(store.content(outer) == .alias);
    const root, const c = store.resolved(outer);
    try testing.expectEqual(int, root);
    try testing.expectEqual(@as(TypeId, @enumFromInt(7)), c.structure.app.type);
}

test "rollback restores descriptors and discards variables and extra made since the mark" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const a = try store.freshFlex(3);
    const b = try store.freshFlex(3);
    const before_vars = store.count();
    const before_extra = store.extra.items.len;

    const snapshot = store.beginSpeculation();
    const args = try store.addVars(&.{ a, b });
    const applied = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(3), .args = args } } }, 3);
    const params = try store.addVars(&.{applied});
    _ = store.merge(a, b, .{ .structure = .{ .func = .{ .params = params, .result = applied } } });
    store.setRank(a, 99);
    try testing.expect(store.content(store.find(b)) == .structure);

    try testing.expect(store.rollback(snapshot));
    try testing.expectEqual(before_vars, store.count());
    try testing.expectEqual(before_extra, store.extra.items.len);
    try testing.expectEqual(a, store.find(a));
    try testing.expectEqual(b, store.find(b));
    try testing.expectEqual(@as(u32, 3), store.rank(a));
    try testing.expect(store.content(a) == .flex);
    try testing.expect(store.content(b) == .flex);
    try testing.expectEqual(@as(u32, 1), store.get(a).size);
}

test "commit keeps what the speculation did" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    const snapshot = store.beginSpeculation();
    _ = store.merge(a, b, .err);
    store.commit(snapshot);
    try testing.expectEqual(store.find(a), store.find(b));
    try testing.expect(store.content(store.find(a)) == .err);
    try testing.expectEqual(@as(usize, 0), store.journal.items.len);
}

test "nested speculation rolls back only the inner region" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const a = try store.freshFlex(1);
    const outer = store.beginSpeculation();
    store.setRank(a, 5);
    const inner = store.beginSpeculation();
    store.setRank(a, 9);
    try testing.expect(store.rollback(inner));
    try testing.expectEqual(@as(u32, 5), store.rank(a));
    try testing.expect(store.rollback(outer));
    try testing.expectEqual(@as(u32, 1), store.rank(a));
}

test "nothing is journalled without an outstanding mark" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const a = try store.freshFlex(1);
    store.setRank(a, 2);
    store.setContent(a, .err);
    try testing.expectEqual(@as(usize, 0), store.journal.items.len);
}

test "record fields are stored sorted and read back as pairs" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const x = try store.freshFlex(1);
    const y = try store.freshFlex(1);
    var input = [_]Field{
        .{ .name = @enumFromInt(9), .value = x },
        .{ .name = @enumFromInt(4), .value = y },
    };
    const r = try store.addFields(&input);
    const read = store.fields(r);
    try testing.expectEqual(@as(usize, 2), read.len);
    try testing.expectEqual(@as(Symbol, @enumFromInt(4)), read[0].name);
    try testing.expectEqual(y, read[0].value);
    try testing.expectEqual(@as(Symbol, @enumFromInt(9)), read[1].name);
    try testing.expectEqual(x, read[1].value);
}

test "vars round trip through extra" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    const c = try store.freshFlex(1);
    const first = try store.addVars(&.{ a, b });
    const second = try store.addVars(&.{c});
    try testing.expectEqualSlices(Var, &.{ a, b }, store.vars(first));
    try testing.expectEqualSlices(Var, &.{c}, store.vars(second));
    try testing.expectEqualSlices(Var, &.{}, store.vars(.empty));
}

test "marks are monotone so a walk never has to clear them" {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    const a = try store.freshFlex(1);
    try testing.expectEqual(no_mark, store.mark(a));
    const first = store.nextMark();
    const second = store.nextMark();
    try testing.expect(first != second);
    try testing.expect(first != no_mark and second != no_mark);
    store.setMark(a, first);
    try testing.expectEqual(first, store.mark(a));
}
