//! L1: places, the type-shaped nodes abstract values live at
//! (`docs/design/ownership-v2.md` §2.1, §3.1).
//!
//! A place is a node of the *place graph* of a type: one per store variable
//! reachable from a root, children by step, built by one memoised walk with
//! knot-tying — a variable reached again while on the walk's stack is the
//! place being built, so a recursive type folds onto itself and a different
//! instantiation is another place (R-4.7.3).
//!
//! **The one reader of type children.** This file is the only one in
//! `own2/` that looks at a type's structure (§5's fence), and it does so
//! through `Source`: an interface the caller passes down that describes one
//! type node as `(kind, head, children)`. The adapter from the checker's
//! `TypeStore`/`Types` is the caller's — note that `Walk.structural` yields
//! an `app`'s type ARGUMENTS and not a constructor's payloads, so the
//! adapter, not this file, instantiates `C#i`'s children — and a test
//! builds a graph by hand. Nothing here names a type, a module or a field by
//! spelling.
//!
//! **Steps are ordered by text, never by a session id** (§3.1, §3.8). A
//! field step carries the field name's RANK in the adapter's table of the
//! module's field names sorted by text, built once in input time; a
//! constructor step carries `(constructor ordinal, argument)`; a tuple step
//! its index. The canonical order of a place's children is the order of
//! these words, and `encode`/`decode` map every name and head through the
//! caller's `Names`/`Remap`, so a block holds no interned address.
//!
//! **Canonical paths** (§2.1) are a trie (`paths`): a step that re-enters a
//! place already on the path pops back to it and appends `⟲`, so a path
//! names a place at most once and is at most 2·|places| long. `extend` is
//! memoised per `(path, step)`; a first extension reads the ancestors and
//! charges one record per ancestor read (§3.1: "charged … per step").
//!
//! **Holds** is the least fixpoint of "what kinds of cell may sit at or
//! below this place", by a worklist over reverse edges, O(7·E); a `ctor`
//! or `tuple` holding nothing is reclassified `cross` (§2.1's last row),
//! which is what makes an `Int × Int` or a `type T = A T | B` a leaf.
//!
//! **Limits** (§4.4) are checked before the work they bound and named:
//! `type_places`, `record_fields`, `tuple_arity`, `constructor_args`,
//! `path_steps`, and the step payload's 28 bits. Each sets the account's
//! failure.
//!
//! **Structural identity.** `encode` writes a sub-graph as
//! `(kind, head, children)` records with ordinals for backreferences, so a
//! cycle is one record; `decode` reads one back into a table of its own;
//! `equals` is the graph-pair walk two tables are compared by (§2.1,
//! *Identity*), one record reserved per pair before it is read.
//!
//! Obligations kept here: none of §2.14's rules is about a place; the
//! canonical-path fold (`⟲`) is what O6's "`⟲` covers every level" rests on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const stamped = @import("../stamped.zig");

pub const PlaceId = Ids.PlaceId;
pub const PathId = Ids.PathId;
pub const ClassId = Ids.ClassId;
pub const Account = Ids.Account;
pub const Charge = Ids.Charge;

pub const Kind = enum(u8) {
    record,
    tuple,
    ctor,
    list,
    dict,
    ref,
    closure,
    @"opaque",
    @"var",
    cross,

    /// The kind of cell a value at a place of this kind IS, as a `Holds`
    /// bit; nothing for a tuple, a constructor or a crossing leaf.
    pub fn own(k: Kind) Holds {
        return switch (k) {
            .record => .{ .record = true },
            .list => .{ .list = true },
            .dict => .{ .dict = true },
            .ref => .{ .ref = true },
            .closure => .{ .closure = true },
            .@"opaque" => .{ .@"opaque" = true },
            .@"var" => .{ .any = true },
            .tuple, .ctor, .cross => .{},
        };
    }

    /// The input limit on this kind's children (§4.4), or null.
    fn childLimit(k: Kind) ?Ids.Limit {
        return switch (k) {
            .record => .record_fields,
            .tuple => .tuple_arity,
            .ctor => .constructor_args,
            else => null,
        };
    }
};

/// What may hold a cell at or below a place (§3.1's `holds` bits).
pub const Holds = packed struct(u8) {
    list: bool = false,
    dict: bool = false,
    record: bool = false,
    ref: bool = false,
    closure: bool = false,
    @"opaque": bool = false,
    any: bool = false,
    _pad: u1 = 0,

    pub fn bits(h: Holds) u8 {
        return @bitCast(h);
    }
    pub fn join(a: Holds, b: Holds) Holds {
        return @bitCast(a.bits() | b.bits());
    }
    pub fn isEmpty(h: Holds) bool {
        return h.bits() == 0;
    }
};

pub const StepKind = enum(u4) {
    /// `.f`: the payload is the field name's text rank.
    field,
    /// `.i`: a tuple index.
    index,
    /// `C#i`: the payload indexes the table's interned `(constructor,
    /// argument)` pairs; canonical order among them is by the pair.
    ctor_arg,
    /// `[*]`.
    elem,
    /// `◆`.
    contents,
    /// `◇`.
    env,
    /// `⟨n⟩`: an opaque type's published slot.
    slot,
    /// `⟲`: one or more levels below a recursive place. Payload 0.
    level,
};

/// A step, one word: `kind` in the top four bits (§3.1).
pub const Step = packed struct(u32) {
    payload: u28,
    kind: StepKind,

    pub const level: Step = .{ .kind = .level, .payload = 0 };
    pub const elem: Step = .{ .kind = .elem, .payload = 0 };
    pub const contents: Step = .{ .kind = .contents, .payload = 0 };
    pub const env: Step = .{ .kind = .env, .payload = 0 };

    /// A payload past 28 bits is the named format limit `step_payload`,
    /// never a truncation.
    fn checked(account: *Account, kind: StepKind, payload: u32) Ids.AccountError!Step {
        try account.limit(.step_payload, @as(u64, payload) + 1);
        return .{ .kind = kind, .payload = @intCast(payload) };
    }

    pub fn field(account: *Account, rank: u32) Ids.AccountError!Step {
        return checked(account, .field, rank);
    }
    pub fn index(account: *Account, i: u32) Ids.AccountError!Step {
        return checked(account, .index, i);
    }
    pub fn slot(account: *Account, n: u32) Ids.AccountError!Step {
        return checked(account, .slot, n);
    }
    pub fn word(s: Step) u32 {
        return @bitCast(s);
    }
    pub fn fromWord(w: u32) Step {
        return @bitCast(w);
    }
    pub fn eql(a: Step, b: Step) bool {
        return a.word() == b.word();
    }
};

/// One child of a type node, as a `Source` describes it.
pub const Child = struct { step: Step, @"var": u32 };

pub const Description = struct {
    kind: Kind,
    /// The `TypeId` of a nominal or foreign type, a tuple's arity, 0 for
    /// a record (its field steps are its identity) and for a leaf.
    head: u32 = 0,
};

/// The type graph, as the caller sees it: `describe(v)` appends `v`'s
/// children (in any order; the table sorts them) and returns its kind and
/// head. Passed down, never stored (§5).
pub const Source = struct {
    ctx: *anyopaque,
    describe: *const fn (ctx: *anyopaque, v: u32, out: *std.ArrayList(Child)) Allocator.Error!Description,
};

/// How `encode` writes a head and a field rank: through the block writer's
/// string table, so no session id is written (§3.6).
pub const Names = struct {
    ctx: *anyopaque,
    head: *const fn (ctx: *anyopaque, head: u32) u32,
    field: *const fn (ctx: *anyopaque, rank: u32) u32,

    pub const identity: Names = .{ .ctx = undefined, .head = same, .field = same };
    fn same(_: *anyopaque, x: u32) u32 {
        return x;
    }
};

/// The reader's inverse of `Names`: a written head to this session's, a
/// written field name to this table's rank.
pub const Remap = Names;

pub const Place = struct {
    kind: Kind,
    head: u32,
    steps: Ids.Range,
    holds: Holds,
    /// A declared class for a `closure` place (#587's slot); `.none` today.
    class: ClassId,
    /// The strongly connected component of the place graph this place is
    /// in (`settleCycles`): what `sameCycle` reads for §2.2's `⟲` matching.
    scc: u32,
};

pub const StepEntry = struct { step: Step, child: PlaceId };

/// A canonical path node (§2.1): its parent, the step that reached it and
/// the place it ends at. The root of a place is its `ε` path.
pub const PathNode = struct {
    parent: PathId,
    step: Step,
    place: PlaceId,
    /// Steps from the root.
    depth: u32,
    /// At or below a summary position: a `[*]` or a `⟲` on the way.
    summary: bool,
    /// The nearest node at or above this one whose step stays on a cycle (a
    /// `⟲`, or a step between two places of one cyclic SCC): the prefixes
    /// §2.8's cycle anchors key, so a reader visits them alone, never every
    /// step of a long path (#1236). Set when the node is made: SCCs are
    /// settled before any path reaches their places.
    anchor_up: PathId = .none,
};

pub const Error = Ids.ChargeError;

/// §4.4's input limits as this table enforces them; a test lowers them.
pub const Limits = struct {
    type_places: u64 = Ids.Limit.type_places.value(),
    path_steps: u64 = Ids.Limit.path_steps.value(),
    children: u64 = Ids.Limit.record_fields.value(),
};

pub const Table = struct {
    places: std.MultiArrayList(Place) = .empty,
    step_tab: std.MultiArrayList(StepEntry) = .empty,
    /// The type walk's memo, type variable → place.
    by_var: stamped.Column(u32, PlaceId) = .{},
    /// `ofBlock`'s memo, a block's place number → place: a namespace of
    /// its own, so a block's places never meet a type variable of the
    /// module's (`Block.read`), cleared by `beginBlock`.
    block_var: stamped.Column(u32, PlaceId) = .{},
    paths: std.MultiArrayList(PathNode) = .empty,
    /// `(parent path, step)` → path; a root is `(none, place)`.
    path_index: Ids.FixedDict(2) = .{},
    /// `extend`'s memo: `(path, step)` → the canonical result, `none` for
    /// no such step.
    extend_memo: Ids.FixedDict(2) = .{},
    /// `C#i` steps: `(constructor, argument)` pairs interned, the payload
    /// their index, so a module has 2²⁸ of them (`ctor_steps`); the
    /// canonical order among them is by the pair (`stepLess`).
    ctor_args: Ids.FixedDict(2) = .{},
    /// `hits` and `up`'s memos, path → a run of `fold_runs` into
    /// `fold_paths` (§2.7, *A read that leaves its path on a cycle*).
    hit_memo: Ids.FixedDict(1) = .{},
    up_memo: Ids.FixedDict(1) = .{},
    level_memo: Ids.FixedDict(1) = .{},
    fold_runs: std.ArrayList([2]u32) = .empty,
    fold_paths: std.ArrayList(PathId) = .empty,
    limits: Limits = .{},
    /// Instrumentation: places visited by the holds fixpoint.
    holds_visits: u32 = 0,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.places.deinit(gpa);
        t.step_tab.deinit(gpa);
        t.by_var.deinit(gpa);
        t.block_var.deinit(gpa);
        t.paths.deinit(gpa);
        t.path_index.deinit(gpa);
        t.extend_memo.deinit(gpa);
        t.ctor_args.deinit(gpa);
        t.hit_memo.deinit(gpa);
        t.up_memo.deinit(gpa);
        t.level_memo.deinit(gpa);
        t.fold_runs.deinit(gpa);
        t.fold_paths.deinit(gpa);
    }

    /// Start a block's place namespace: `ofBlock`'s numbers from here on
    /// are the next block's, and meet no earlier block's.
    pub fn beginBlock(t: *Table) void {
        t.block_var.clear();
    }

    pub fn count(t: *const Table) u32 {
        return @intCast(t.places.len);
    }

    pub fn kind(t: *const Table, p: PlaceId) Kind {
        return t.places.items(.kind)[p.int()];
    }

    pub fn head(t: *const Table, p: PlaceId) u32 {
        return t.places.items(.head)[p.int()];
    }

    pub fn holds(t: *const Table, p: PlaceId) Holds {
        return t.places.items(.holds)[p.int()];
    }

    /// The steps out of `p` and the places they reach, in canonical order.
    pub const Steps = struct { steps: []const Step, children: []const PlaceId };

    pub fn steps(t: *const Table, p: PlaceId) Steps {
        const r = t.places.items(.steps)[p.int()];
        return .{ .steps = t.step_tab.items(.step)[r.start..][0..r.len], .children = t.step_tab.items(.child)[r.start..][0..r.len] };
    }

    fn stepRange(t: *const Table, p: PlaceId) Ids.Range {
        return t.places.items(.steps)[p.int()];
    }

    /// The place `step` reaches from `p`, or null when `p` has no such
    /// step. A `level` step stays at `p`. Binary search over the sorted
    /// step run: O(log F).
    pub fn child(t: *const Table, p: PlaceId, step: Step) ?PlaceId {
        if (step.kind == .level) return p;
        const r = t.stepRange(p);
        const words = t.step_tab.items(.step)[r.start..][0..r.len];
        var lo: usize = 0;
        var hi: usize = words.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (t.stepLess(words[mid], step)) lo = mid + 1 else hi = mid;
        }
        if (lo < words.len and words[lo].word() == step.word()) return t.step_tab.items(.child)[r.start + lo];
        return null;
    }

    /// The canonical order of steps (§3.1): by kind, then a field by its
    /// text rank, an index or slot by its number, a `C#i` by its
    /// `(constructor, argument)` pair — not by its interned index.
    pub fn stepLess(t: *const Table, a: Step, b: Step) bool {
        if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
        if (a.kind != .ctor_arg) return a.payload < b.payload;
        const pa = t.ctorArgOf(a);
        const pb = t.ctorArgOf(b);
        return if (pa[0] != pb[0]) pa[0] < pb[0] else pa[1] < pb[1];
    }

    /// The `C#i` step for constructor `c`'s argument `i`: its word orders
    /// by `(c, i)`, so a place's constructor steps are in declaration order
    /// whatever order the pairs were first seen in.
    pub fn ctorStep(t: *Table, gpa: Allocator, account: *Account, c: u32, i: u32) Error!Step {
        try account.limit(.constructor_args, @as(u64, i) + 1);
        try account.limit(.ctor_steps, @as(u64, t.ctor_args.count()) + 1);
        const got = try t.ctor_args.getOrPut(gpa, .{ c, i });
        if (!got.found_existing) got.value_ptr.* = got.index;
        return .{ .kind = .ctor_arg, .payload = @intCast(got.value_ptr.*) };
    }

    /// The `(constructor, argument)` a `ctor_arg` step stands for.
    pub fn ctorArgOf(t: *const Table, step: Step) [2]u32 {
        std.debug.assert(step.kind == .ctor_arg);
        return t.ctor_args.keys.items[@as(usize, step.payload) * 2 ..][0..2].*;
    }

    // ---- building -------------------------------------------------------

    const Frame = struct {
        place: PlaceId,
        /// The frame's children in `scratch`.
        first: u32,
        len: u32,
        cursor: u32,
    };

    /// The place of type variable `root`, building every place reachable
    /// from it that the table does not have yet (R-4.7.3). O(E) in the
    /// edges first seen; a variable seen before costs one column read.
    pub fn of(t: *Table, gpa: Allocator, account: *Account, source: Source, root: u32) Error!PlaceId {
        return t.ofIn(&t.by_var, gpa, account, source, root);
    }

    /// `of` in the current block's namespace (`beginBlock`): `root` is a
    /// block's place number, never a type variable of the module's.
    pub fn ofBlock(t: *Table, gpa: Allocator, account: *Account, source: Source, root: u32) Error!PlaceId {
        return t.ofIn(&t.block_var, gpa, account, source, root);
    }

    fn ofIn(t: *Table, memo: *stamped.Column(u32, PlaceId), gpa: Allocator, account: *Account, source: Source, root: u32) Error!PlaceId {
        if (memo.get(root)) |p| return p;
        var scratch: std.ArrayList(Child) = .empty;
        defer scratch.deinit(gpa);
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        // Everything this walk adds is undone if any step of it is refused,
        // so a refusal leaves no half-built place for another owner to read
        // (§4.4: the owner that hit the limit stops; nobody gets a wrong
        // answer).
        var added: std.ArrayList(u32) = .empty;
        defer added.deinit(gpa);
        const first_new = t.count();
        const first_step: usize = t.step_tab.len;
        errdefer t.rollback(memo, first_new, first_step, added.items);
        const top = try t.open(memo, gpa, account, source, root, &scratch, &stack, &added);
        while (stack.items.len > 0) {
            const f = &stack.items[stack.items.len - 1];
            if (f.cursor == f.len) {
                scratch.shrinkRetainingCapacity(f.first);
                _ = stack.pop();
                continue;
            }
            const c = scratch.items[f.first + f.cursor];
            const slot = t.stepRange(f.place).start + f.cursor;
            f.cursor += 1;
            if (memo.get(c.@"var")) |known| {
                t.step_tab.items(.child)[slot] = known;
                continue;
            }
            const made = try t.open(memo, gpa, account, source, c.@"var", &scratch, &stack, &added);
            t.step_tab.items(.child)[slot] = made;
        }
        try t.settleHolds(gpa, first_new);
        try t.settleCycles(gpa, first_new);
        return top;
    }

    /// Undo a refused walk: its places, their steps and their memo entries.
    fn rollback(t: *Table, memo: *stamped.Column(u32, PlaceId), first_new: u32, first_step: usize, vars: []const u32) void {
        for (vars) |v| memo.remove(v);
        t.places.shrinkRetainingCapacity(first_new);
        t.step_tab.shrinkRetainingCapacity(first_step);
    }

    /// Describe `v` and check every limit FIRST; only then allocate its
    /// place and memoise it — before its children are visited (the knot) —
    /// and push a frame for them.
    fn open(t: *Table, memo: *stamped.Column(u32, PlaceId), gpa: Allocator, account: *Account, source: Source, v: u32, scratch: *std.ArrayList(Child), stack: *std.ArrayList(Frame), added: *std.ArrayList(u32)) Error!PlaceId {
        try account.limitOver(.type_places, @as(u64, t.count()) + 1, t.limits.type_places);
        const first: u32 = @intCast(scratch.items.len);
        const d = try source.describe(source.ctx, v, scratch);
        const len: u32 = @intCast(scratch.items.len - first);
        if (d.kind.childLimit()) |l| try account.limitOver(l, len, t.limits.children);
        const id: PlaceId = .from(t.count());
        try added.append(gpa, v);
        try memo.put(gpa, v, id);
        const start: u32 = @intCast(t.step_tab.len);
        // The canonical step order is the word order of `Step`: fields by
        // text rank, indices, `C#i` by (constructor, argument). A source
        // may describe children in any order.
        std.mem.sort(Child, scratch.items[first..], t, struct {
            fn lessThan(tt: *Table, a: Child, b: Child) bool {
                return tt.stepLess(a.step, b.step);
            }
        }.lessThan);
        try t.step_tab.ensureUnusedCapacity(gpa, len);
        for (scratch.items[first..]) |c| t.step_tab.appendAssumeCapacity(.{ .step = c.step, .child = .none });
        try t.places.append(gpa, .{ .kind = d.kind, .head = d.head, .steps = .{ .start = start, .len = len }, .holds = d.kind.own(), .class = .none, .scc = 0 });
        try stack.append(gpa, .{ .place = id, .first = first, .len = len, .cursor = 0 });
        return id;
    }

    /// The least fixpoint of `holds` over the places from `first` on: a
    /// worklist over reverse edges, every place popped once at the start
    /// and once more per bit a child gains, so O(7·E) whatever the depth.
    /// Then the `cross` reclassification.
    fn settleHolds(t: *Table, gpa: Allocator, first: u32) Error!void {
        const n = t.count() - first;
        if (n == 0) return;
        const kinds = t.places.items(.kind);
        const hs = t.places.items(.holds);
        const ranges = t.places.items(.steps);
        const children = t.step_tab.items(.child);
        // Reverse edges among the new places, as a CSR: child → parents.
        const starts = try gpa.alloc(u32, n + 1);
        defer gpa.free(starts);
        @memset(starts, 0);
        var i: u32 = first;
        while (i < t.count()) : (i += 1) {
            const r = ranges[i];
            for (children[r.start..][0..r.len]) |c| if (c.int() >= first) {
                starts[c.int() - first + 1] += 1;
            };
        }
        for (1..n + 1) |k| starts[k] += starts[k - 1];
        const parents = try gpa.alloc(u32, starts[n]);
        defer gpa.free(parents);
        const cursor = try gpa.alloc(u32, n);
        defer gpa.free(cursor);
        @memcpy(cursor, starts[0..n]);
        i = first;
        while (i < t.count()) : (i += 1) {
            const r = ranges[i];
            for (children[r.start..][0..r.len]) |c| if (c.int() >= first) {
                parents[cursor[c.int() - first]] = i;
                cursor[c.int() - first] += 1;
            };
        }
        // The worklist: every place once, then a parent per changed child.
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(gpa);
        const queued = try gpa.alloc(bool, n);
        defer gpa.free(queued);
        @memset(queued, true);
        i = first;
        while (i < t.count()) : (i += 1) try work.append(gpa, i);
        while (work.pop()) |p| {
            queued[p - first] = false;
            t.holds_visits += 1;
            var h = hs[p];
            const r = ranges[p];
            for (children[r.start..][0..r.len]) |c| h = h.join(hs[c.int()]);
            if (h.bits() == hs[p].bits()) continue;
            hs[p] = h;
            for (parents[starts[p - first]..starts[p - first + 1]]) |q| if (!queued[q - first]) {
                queued[q - first] = true;
                try work.append(gpa, q);
            };
        }
        i = first;
        while (i < t.count()) : (i += 1) {
            if ((kinds[i] == .ctor or kinds[i] == .tuple) and hs[i].isEmpty()) {
                kinds[i] = .cross;
                // A leaf names no type: the head would otherwise carry a
                // session id into a block.
                t.places.items(.head)[i] = 0;
                ranges[i].len = 0;
            }
        }
    }

    /// The strongly connected components of the places from `first` on:
    /// an iterative Tarjan over the child edges, O(E), numbering each
    /// component after the table's count so ids never collide across
    /// builds. Edges into older places are followed for membership but
    /// those places keep their own component.
    fn settleCycles(t: *Table, gpa: Allocator, first: u32) Error!void {
        const n = t.count() - first;
        if (n == 0) return;
        const ranges = t.places.items(.steps);
        const children = t.step_tab.items(.child);
        const sccs = t.places.items(.scc);
        const none = Ids.none_int;
        const index = try gpa.alloc(u32, n);
        defer gpa.free(index);
        @memset(index, none);
        const low = try gpa.alloc(u32, n);
        defer gpa.free(low);
        const on_stack = try gpa.alloc(bool, n);
        defer gpa.free(on_stack);
        @memset(on_stack, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        const Visit = struct { place: u32, cursor: u32 };
        var frames: std.ArrayList(Visit) = .empty;
        defer frames.deinit(gpa);
        var next: u32 = 0;
        var component: u32 = t.count(); // ids past every place id
        var root: u32 = first;
        while (root < t.count()) : (root += 1) {
            if (index[root - first] != none) continue;
            index[root - first] = next;
            low[root - first] = next;
            next += 1;
            on_stack[root - first] = true;
            try stack.append(gpa, root);
            try frames.append(gpa, .{ .place = root, .cursor = 0 });
            while (frames.items.len > 0) {
                const f = &frames.items[frames.items.len - 1];
                const r = ranges[f.place];
                if (f.cursor < r.len) {
                    const c = children[r.start + f.cursor].int();
                    f.cursor += 1;
                    if (c < first) continue;
                    if (index[c - first] == none) {
                        index[c - first] = next;
                        low[c - first] = next;
                        next += 1;
                        on_stack[c - first] = true;
                        try stack.append(gpa, c);
                        try frames.append(gpa, .{ .place = c, .cursor = 0 });
                    } else if (on_stack[c - first]) {
                        low[f.place - first] = @min(low[f.place - first], index[c - first]);
                    }
                    continue;
                }
                const p = f.place;
                _ = frames.pop();
                if (frames.items.len > 0) {
                    const parent = frames.items[frames.items.len - 1].place;
                    low[parent - first] = @min(low[parent - first], low[p - first]);
                }
                if (low[p - first] != index[p - first]) continue;
                while (true) {
                    const m = stack.pop().?;
                    on_stack[m - first] = false;
                    sccs[m] = component;
                    if (m == p) break;
                }
                component += 1;
            }
        }
    }

    /// Whether a step from `p` to `q` is on a cycle of `p`: `q` can reach
    /// `p` again (§2.2's `⟲` matching). O(1): a column compare, plus a
    /// child scan for the self-loop.
    pub fn sameCycle(t: *const Table, p: PlaceId, q: PlaceId) bool {
        if (p != q) return t.places.items(.scc)[p.int()] == t.places.items(.scc)[q.int()];
        const s = t.steps(p);
        for (s.children) |c| if (c == p) return true;
        return false;
    }

    // ---- canonical paths ------------------------------------------------

    /// The `ε` path of `place`.
    pub fn rootPath(t: *Table, gpa: Allocator, place: PlaceId) Allocator.Error!PathId {
        const got = try t.path_index.getOrPut(gpa, .{ Ids.none_int, place.int() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(t.paths.len);
            try t.paths.append(gpa, .{ .parent = .none, .step = Step.level, .place = place, .depth = 0, .summary = false });
        }
        return .from(got.value_ptr.*);
    }

    pub fn pathPlace(t: *const Table, p: PathId) PlaceId {
        return t.paths.items(.place)[p.int()];
    }

    pub fn pathParent(t: *const Table, p: PathId) PathId {
        return t.paths.items(.parent)[p.int()];
    }

    pub fn pathStep(t: *const Table, p: PathId) Step {
        return t.paths.items(.step)[p.int()];
    }

    /// `p` itself or its nearest ancestor that is a cycle anchor's prefix
    /// (`PathNode.anchor_up`), `.none` when there is none.
    pub fn anchorUp(t: *const Table, p: PathId) PathId {
        if (p == .none) return .none;
        return t.paths.items(.anchor_up)[p.int()];
    }

    pub fn pathDepth(t: *const Table, p: PathId) u32 {
        return t.paths.items(.depth)[p.int()];
    }

    /// Whether `prefix` is `path` or an ancestor of it. O(depth) column
    /// reads, the caller's charged walk (§2.2: `alias` costs O(path length)).
    pub fn isPrefix(t: *const Table, prefix: PathId, path: PathId) bool {
        if (t.pathDepth(prefix) > t.pathDepth(path)) return false;
        var at = path;
        while (t.pathDepth(at) > t.pathDepth(prefix)) at = t.pathParent(at);
        return at == prefix;
    }

    /// `path · step`, canonical (§2.1): null when the place has no such
    /// step; a step onto a place already on the path pops back to its node
    /// and appends `⟲` (once). Memoised per `(path, step)`; a miss reads the
    /// ancestors and charges one record per ancestor read.
    pub fn extend(t: *Table, gpa: Allocator, charge: Charge, path: PathId, step: Step) Error!?PathId {
        // One record per request, a memo hit included (§4.1: a cache hit is
        // reached only through a charged edge, and charged).
        try charge.reserve(gpa, .path, 1);
        if (t.extend_memo.get(.{ path.int(), step.word() })) |hit| return if (hit == Ids.none_int) null else PathId.from(hit);
        const here = t.pathPlace(path);
        const target = t.child(here, step) orelse {
            (try t.extend_memo.getOrPut(gpa, .{ path.int(), step.word() })).value_ptr.* = Ids.none_int;
            return null;
        };
        // Re-entry: is `target` on the path? Only if it shares a cycle with
        // `here` (a place above on the path that `here` steps back to closes
        // one), and then among the path's last places on that cycle: they are
        // a suffix of it, so the walk stops at the first one off the cycle.
        // As long as the cycle, never the path (#1236).
        var out: ?PathId = null;
        if (t.sameCycle(here, target)) {
            var at = path;
            while (at != .none) : (at = t.pathParent(at)) {
                try charge.reserve(gpa, .path, 1);
                const there = t.pathPlace(at);
                if (there == target) {
                    // Already `⟲` here (the root's placeholder step is not one).
                    out = if (t.pathParent(at) != .none and t.pathStep(at).kind == .level) at else try t.node(gpa, charge.account, at, Step.level, target);
                    break;
                }
                if (!t.sameCycle(there, target)) break;
            }
        }
        const result = out orelse try t.node(gpa, charge.account, path, step, target);
        (try t.extend_memo.getOrPut(gpa, .{ path.int(), step.word() })).value_ptr.* = result.int();
        return result;
    }

    fn node(t: *Table, gpa: Allocator, account: *Account, parent: PathId, step: Step, place: PlaceId) Error!PathId {
        const depth = t.pathDepth(parent) + 1;
        try account.limitOver(.path_steps, depth, t.limits.path_steps);
        const got = try t.path_index.getOrPut(gpa, .{ parent.int(), step.word() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(t.paths.len);
            const summary = t.paths.items(.summary)[parent.int()] or step.kind == .elem or step.kind == .level;
            const anchor = step.kind == .level or t.sameCycle(t.pathPlace(parent), place);
            const up: PathId = if (anchor) .from(@intCast(t.paths.len)) else t.paths.items(.anchor_up)[parent.int()];
            try t.paths.append(gpa, .{ .parent = parent, .step = step, .place = place, .depth = depth, .summary = summary, .anchor_up = up });
        }
        return .from(got.value_ptr.*);
    }

    /// Whether `p` is on a cycle of the place graph: a step back to itself,
    /// or a strongly connected component of two places or more.
    pub fn cyclic(t: *const Table, p: PlaceId) bool {
        for (t.steps(p).children) |c| if (t.sameCycle(p, c)) return true;
        return false;
    }

    /// `Up(p)` (§2.7, *A read that leaves its path on a cycle*): the paths
    /// that `extend` reaches from `p`, step by step along the cycle of
    /// `p`'s place, and that are not below `p`: the `⟲` paths above `p`
    /// that `p`'s levels fold into, closed over the levels below each. A
    /// deep read at `p` reads every path below each of them. Memoised per
    /// path; a run of `fold_paths`, read by `foldPath`.
    pub fn foldsUp(t: *Table, gpa: Allocator, charge: Charge, p: PathId) Error!Ids.Range {
        try charge.reserve(gpa, .memo, 1);
        if (t.up_memo.get(.{p.int()})) |i| return rangeOf(t.fold_runs.items[i]);
        var acc: std.ArrayList(PathId) = .empty;
        defer acc.deinit(gpa);
        if (t.cyclic(t.pathPlace(p))) {
            // The targets of `p`'s own levels, then those of each target's
            // levels: a target is a `⟲` of a prefix, so each round climbs.
            try t.mergeHits(gpa, charge, p, p, &acc);
            var i: usize = 0;
            while (i < acc.items.len) : (i += 1) try t.mergeHits(gpa, charge, acc.items[i], p, &acc);
        }
        return t.memoRun(gpa, &t.up_memo, p, acc.items);
    }

    /// The paths at the place of `p` one or more steps around its cycles,
    /// each as `extend` makes it (`Walk.Graft.levels`' answer): where a
    /// callee's `⟲` step at `p` lands in this graph. A walk of the
    /// canonical paths of the place's strongly connected component, each
    /// once; memoised per path; empty when the place is on no cycle.
    pub fn levelsOf(t: *Table, gpa: Allocator, charge: Charge, p: PathId) Error!Ids.Range {
        try charge.reserve(gpa, .memo, 1);
        if (t.level_memo.get(.{p.int()})) |i| return rangeOf(t.fold_runs.items[i]);
        const target = t.pathPlace(p);
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        var queue: std.ArrayList(PathId) = .empty;
        defer queue.deinit(gpa);
        var acc: std.ArrayList(PathId) = .empty;
        defer acc.deinit(gpa);
        try queue.append(gpa, p);
        _ = try seen.getOrPut(gpa, .{p.int()});
        while (queue.pop()) |x| {
            const n = t.steps(t.pathPlace(x)).steps.len;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const st = t.steps(t.pathPlace(x));
                try charge.reserve(gpa, .inspection, 1);
                if (st.children[j] != target and !t.sameCycle(target, st.children[j])) continue;
                const np = (try t.extend(gpa, charge, x, st.steps[j])) orelse continue;
                if (t.pathPlace(np) == target and std.mem.indexOfScalar(PathId, acc.items, np) == null) try acc.append(gpa, np);
                if (!(try seen.getOrPut(gpa, .{np.int()})).found_existing) try queue.append(gpa, np);
            }
        }
        return t.memoRun(gpa, &t.level_memo, p, acc.items);
    }

    fn memoRun(t: *Table, gpa: Allocator, memo: *Ids.FixedDict(1), p: PathId, items: []const PathId) Allocator.Error!Ids.Range {
        const run: [2]u32 = .{ @intCast(t.fold_paths.items.len), @intCast(items.len) };
        try t.fold_paths.appendSlice(gpa, items);
        (try memo.getOrPut(gpa, .{p.int()})).value_ptr.* = @intCast(t.fold_runs.items.len);
        try t.fold_runs.append(gpa, run);
        return rangeOf(run);
    }

    pub fn foldPath(t: *const Table, i: u32) PathId {
        return t.fold_paths.items[i];
    }

    fn rangeOf(r: [2]u32) Ids.Range {
        return .{ .start = r[0], .len = r[1] };
    }

    /// Add `hits(x)` to `acc`, each once, but those below `p`.
    fn mergeHits(t: *Table, gpa: Allocator, charge: Charge, x: PathId, p: PathId, acc: *std.ArrayList(PathId)) Error!void {
        const r = try t.hits(gpa, charge, x);
        var k: u32 = 0;
        while (k < r[1]) : (k += 1) {
            try charge.reserve(gpa, .inspection, 1);
            const e = t.fold_paths.items[r[0] + k];
            if (e == p or t.pathParent(e) == p) continue;
            for (acc.items) |a| {
                if (a == e) break;
            } else try acc.append(gpa, e);
        }
    }

    /// `hits(x)`: the paths that a step of `x`'s plain subtree on its cycle
    /// folds into, outside `x`'s subtree. A fold lands at the deepest place
    /// of the path it re-enters (`extend`), so a target is `a⟲` for a
    /// prefix `a`, or `a` when that is a `⟲` already; below `x` exactly
    /// when `a` is `x`. Made from the plain children's, so each canonical
    /// path of a cycle is visited once, on an explicit stack (#1138).
    fn hits(t: *Table, gpa: Allocator, charge: Charge, x0: PathId) Error![2]u32 {
        try charge.reserve(gpa, .memo, 1);
        if (t.hit_memo.get(.{x0.int()})) |i| return t.fold_runs.items[i];
        const Fr = struct { path: PathId, expanded: bool };
        var stack: std.ArrayList(Fr) = .empty;
        defer stack.deinit(gpa);
        var acc: std.ArrayList(PathId) = .empty;
        defer acc.deinit(gpa);
        try stack.append(gpa, .{ .path = x0, .expanded = false });
        while (stack.pop()) |f| {
            const x = f.path;
            if (t.hit_memo.get(.{x.int()}) != null) continue;
            const here = t.pathPlace(x);
            if (!f.expanded) try stack.append(gpa, .{ .path = x, .expanded = true });
            acc.clearRetainingCapacity();
            const n = t.steps(here).steps.len;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                // By index: `extend` makes paths, never steps, but reads anew.
                const st = t.steps(here);
                const s = st.steps[j];
                try charge.reserve(gpa, .inspection, 1);
                if (!t.sameCycle(here, st.children[j])) continue;
                const y = (try t.extend(gpa, charge, x, s)) orelse continue;
                const plain = t.pathParent(y) == x and t.pathStep(y).word() == s.word();
                if (!f.expanded) {
                    if (plain and t.hit_memo.get(.{y.int()}) == null) try stack.append(gpa, .{ .path = y, .expanded = false });
                    continue;
                }
                if (plain) {
                    const r = t.fold_runs.items[t.hit_memo.get(.{y.int()}).?];
                    var k: u32 = 0;
                    while (k < r[1]) : (k += 1) {
                        try charge.reserve(gpa, .inspection, 1);
                        try addOutside(&acc, gpa, x, t.fold_paths.items[r[0] + k], t);
                    }
                } else try addOutside(&acc, gpa, x, y, t);
            }
            if (!f.expanded) continue;
            _ = try t.memoRun(gpa, &t.hit_memo, x, acc.items);
        }
        return t.fold_runs.items[t.hit_memo.get(.{x0.int()}).?];
    }

    fn addOutside(acc: *std.ArrayList(PathId), gpa: Allocator, x: PathId, e: PathId, t: *const Table) Allocator.Error!void {
        if (e == x or t.pathParent(e) == x) return;
        for (acc.items) |a| if (a == e) return;
        try acc.append(gpa, e);
    }

    /// Whether `path` is a summary position or below one: it holds a
    /// `[*]` or a `⟲` (§2.2's occurrence rule). O(1): a column.
    pub fn isSummary(t: *const Table, path: PathId) bool {
        return t.paths.items(.summary)[path.int()];
    }

    // ---- structural identity --------------------------------------------

    /// Write the sub-graph under `root` as records in pre-order ordinals:
    /// `[count] { kind, head, holds, n, (step, child ordinal)×n }`, with a
    /// field step's name and a nominal head written through `names` (the
    /// block's string table), so no session id reaches the bytes. A place
    /// is written once; a child seen before is its ordinal (a cycle too).
    pub fn encode(t: *const Table, gpa: Allocator, root: PlaceId, names: Names, out: *std.ArrayList(u32)) Allocator.Error!void {
        var ordinal: stamped.Column(PlaceId, u32) = .{};
        defer ordinal.deinit(gpa);
        var order: std.ArrayList(PlaceId) = .empty;
        defer order.deinit(gpa);
        var stack: std.ArrayList(PlaceId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, root);
        while (stack.pop()) |p| {
            if (ordinal.contains(p)) continue;
            try ordinal.put(gpa, p, @intCast(order.items.len));
            try order.append(gpa, p);
            const r = t.stepRange(p);
            // Pushed in reverse so the first child gets the next ordinal.
            var i = r.len;
            while (i > 0) : (i -= 1) try stack.append(gpa, t.step_tab.items(.child)[r.start + i - 1]);
        }
        try out.append(gpa, @intCast(order.items.len));
        for (order.items) |p| {
            const r = t.stepRange(p);
            const k = t.kind(p);
            const h = if (k == .tuple or k == .record) t.head(p) else names.head(names.ctx, t.head(p));
            try out.appendSlice(gpa, &.{ @backingInt(k), h, t.holds(p).bits(), r.len });
            for (t.step_tab.items(.step)[r.start..][0..r.len], t.step_tab.items(.child)[r.start..][0..r.len]) |s, c| {
                // A field's rank and a `C#i`'s intern index are this table's: the
                // word carries the kind alone and the name or pair follows, so
                // two tables write one type identically.
                const w = if (s.kind == .field or s.kind == .ctor_arg) (Step{ .kind = s.kind, .payload = 0 }).word() else s.word();
                try out.appendSlice(gpa, &.{ w, ordinal.get(c).? });
                // A field's name follows its step, through the string table.
                if (s.kind == .field) try out.append(gpa, names.field(names.ctx, s.payload));
                // A `C#i` payload is this table's intern index: the pair follows.
                if (s.kind == .ctor_arg) try out.appendSlice(gpa, &t.ctorArgOf(s));
            }
        }
    }

    /// Read a graph `encode` wrote into a table of its own, mapping heads
    /// and field names back through `remap`; the root is place 0. Null when
    /// the words are not a graph (R-5.7.4: an undecodable block is no
    /// block), including a child order that is not canonical after the
    /// remap.
    pub fn decode(gpa: Allocator, account: *Account, words: []const u32, remap: Remap) Error!?Table {
        var t: Table = .{};
        decodeInto(&t, gpa, account, words, remap) catch |err| switch (err) {
            error.Malformed => {
                t.deinit(gpa);
                return null;
            },
            else => |e| {
                t.deinit(gpa);
                return e;
            },
        };
        return t;
    }

    fn decodeInto(t: *Table, gpa: Allocator, account: *Account, words: []const u32, remap: Remap) (Error || error{Malformed})!void {
        if (words.len == 0) return error.Malformed;
        const n = words[0];
        var at: usize = 1;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (at + 4 > words.len) return error.Malformed;
            const k = words[at];
            if (k > @backingInt(Kind.cross)) return error.Malformed;
            const kd: Kind = @fromBackingInt(@intCast(k));
            const h = if (kd == .tuple or kd == .record) words[at + 1] else remap.head(remap.ctx, words[at + 1]);
            const hb = words[at + 2];
            const len = words[at + 3];
            at += 4;
            if (hb > 0x7f) return error.Malformed;
            try account.limitOver(.type_places, @as(u64, t.count()) + 1, t.limits.type_places);
            if (kd.childLimit()) |l| try account.limitOver(l, len, t.limits.children);
            const start: u32 = @intCast(t.step_tab.len);
            var j: u32 = 0;
            var last: u64 = 0;
            while (j < len) : (j += 1) {
                if (at + 2 > words.len) return error.Malformed;
                var s = Step.fromWord(words[at]);
                const c = words[at + 1];
                at += 2;
                if (c >= n) return error.Malformed;
                if (s.kind == .field) {
                    if (at + 1 > words.len) return error.Malformed;
                    s = try Step.field(account, remap.field(remap.ctx, words[at]));
                    at += 1;
                }
                if (s.kind == .ctor_arg) {
                    if (at + 2 > words.len) return error.Malformed;
                    s = try t.ctorStep(gpa, account, words[at], words[at + 1]);
                    at += 2;
                }
                if (j > 0 and !t.stepLess(Step.fromWord(@intCast(last)), s)) return error.Malformed;
                last = s.word();
                try t.step_tab.append(gpa, .{ .step = s, .child = .from(c) });
            }
            try t.places.append(gpa, .{ .kind = kd, .head = h, .steps = .{ .start = start, .len = len }, .holds = @bitCast(@as(u8, @intCast(hb))), .class = .none, .scc = 0 });
        }
        if (at != words.len) return error.Malformed;
    }

    /// Structural equality of `a` in `ta` and `b` in `tb`: a graph-pair
    /// walk, every pair visited once, O(pairs) — the charged comparison of
    /// §2.1's *Identity*: one record reserved per pair before it is read.
    pub fn equals(ta: *const Table, a: PlaceId, tb: *const Table, b: PlaceId, gpa: Allocator, charge: Charge) Error!bool {
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList([2]PlaceId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ a, b });
        while (stack.pop()) |pair| {
            try charge.reserve(gpa, .inspection, 1);
            const got = try seen.getOrPut(gpa, .{ pair[0].int(), pair[1].int() });
            if (got.found_existing) continue;
            got.value_ptr.* = 1;
            const x = pair[0];
            const y = pair[1];
            if (ta.kind(x) != tb.kind(y) or ta.head(x) != tb.head(y)) return false;
            const rx = ta.stepRange(x);
            const ry = tb.stepRange(y);
            if (rx.len != ry.len) return false;
            var i: u32 = 0;
            while (i < rx.len) : (i += 1) {
                const sx = ta.step_tab.items(.step)[rx.start + i];
                const sy = tb.step_tab.items(.step)[ry.start + i];
                if (sx.kind != sy.kind) return false;
                if (sx.kind == .ctor_arg) {
                    if (!std.mem.eql(u32, &ta.ctorArgOf(sx), &tb.ctorArgOf(sy))) return false;
                } else if (!sx.eql(sy)) return false;
                try stack.append(gpa, .{ ta.step_tab.items(.child)[rx.start + i], tb.step_tab.items(.child)[ry.start + i] });
            }
        }
        return true;
    }
};

comptime {
    Ids.assertRecord(Place);
    Ids.assertRecord(StepEntry);
    Ids.assertRecord(PathNode);
    std.debug.assert(@sizeOf(Place) == 24);
    std.debug.assert(@sizeOf(StepEntry) == 8);
    std.debug.assert(@sizeOf(PathNode) == 24);
}

// ---------------------------------------------------------------------------
// Tests: a type graph built by hand.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test type graph: node `v` is `nodes[v]`.
const TestGraph = struct {
    nodes: []const TestNode,
    table: *Table,
    account: *Account,
    gpa: Allocator,

    const TestNode = struct { kind: Kind, head: u32 = 0, children: []const TestChild = &.{} };
    const TestChild = struct { kind: StepKind, payload: u32 = 0, @"var": u32, arg: u32 = 0 };

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Child)) Allocator.Error!Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        const n = g.nodes[v];
        for (n.children) |c| {
            const step: Step = switch (c.kind) {
                .field => Step.field(g.account, c.payload) catch unreachable,
                .index => Step.index(g.account, c.payload) catch unreachable,
                .ctor_arg => g.table.ctorStep(g.gpa, g.account, c.payload, c.arg) catch unreachable,
                .elem => Step.elem,
                .contents => Step.contents,
                .env => Step.env,
                .slot => Step.slot(g.account, c.payload) catch unreachable,
                .level => unreachable,
            };
            try out.append(g.gpa, .{ .step = step, .@"var" = c.@"var" });
        }
        return .{ .kind = n.kind, .head = n.head };
    }

    fn source(g: *TestGraph) Source {
        return .{ .ctx = g, .describe = describe };
    }
};

const Fixture = struct {
    table: Table = .{},
    account: Account = .{},
    graph: TestGraph = undefined,

    fn init(f: *Fixture, nodes: []const TestGraph.TestNode) void {
        f.graph = .{ .nodes = nodes, .table = &f.table, .account = &f.account, .gpa = testing.allocator };
    }

    fn deinit(f: *Fixture) void {
        f.table.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
    }

    fn of(f: *Fixture, v: u32) !PlaceId {
        return f.table.of(testing.allocator, &f.account, f.graph.source(), v);
    }

    fn ctor(f: *Fixture, c: u32, i: u32) !Step {
        return f.table.ctorStep(testing.allocator, &f.account, c, i);
    }

    fn extend(f: *Fixture, path: PathId, step: Step) !?PathId {
        return f.table.extend(testing.allocator, .growth(&f.account), path, step);
    }
};

// `type Tree = Node Tree (List Int) Tree`: 0 Tree, 1 List Int, 2 Int.
const tree_nodes = [_]TestGraph.TestNode{
    .{ .kind = .ctor, .head = 100, .children = &.{
        .{ .kind = .ctor_arg, .payload = 0, .arg = 0, .@"var" = 0 },
        .{ .kind = .ctor_arg, .payload = 0, .arg = 1, .@"var" = 1 },
        .{ .kind = .ctor_arg, .payload = 0, .arg = 2, .@"var" = 0 },
    } },
    .{ .kind = .list, .head = 200, .children = &.{.{ .kind = .elem, .@"var" = 2 }} },
    .{ .kind = .cross },
};

test "a recursive type is one place and its canonical paths fold with ⟲" {
    var f: Fixture = .{};
    f.init(&tree_nodes);
    defer f.deinit();
    const t = &f.table;
    const tree = try f.of(0);
    try testing.expectEqual(@as(u32, 3), t.count());
    try testing.expectEqual(Kind.ctor, t.kind(tree));
    try testing.expect(t.holds(tree).list and !t.holds(tree).record);
    const s0 = try f.ctor(0, 0);
    const s1 = try f.ctor(0, 1);
    const s2 = try f.ctor(0, 2);
    // Both recursive children are the root itself.
    try testing.expectEqual(tree, t.child(tree, s0).?);
    try testing.expectEqual(tree, t.child(tree, s2).?);
    const list = t.child(tree, s1).?;
    try testing.expectEqual(Kind.list, t.kind(list));
    try testing.expectEqual(@as(?PlaceId, null), t.child(list, s0));
    // Paths: `#Node.1` is exact; `#Node.0` re-enters the root and is `⟲`.
    const root = try t.rootPath(testing.allocator, tree);
    const p1 = (try f.extend(root, s1)).?;
    try testing.expectEqual(list, t.pathPlace(p1));
    try testing.expect(!t.isSummary(p1));
    const below = (try f.extend(root, s0)).?;
    try testing.expectEqual(StepKind.level, t.pathStep(below).kind);
    try testing.expectEqual(tree, t.pathPlace(below));
    try testing.expectEqual(@as(u32, 1), t.pathDepth(below));
    // Further levels stay at the one ⟲; a list below is `⟲#Node.1`.
    try testing.expectEqual(below, (try f.extend(below, s2)).?);
    try testing.expectEqual(below, (try f.extend(root, s2)).?);
    const deep_list = (try f.extend(below, s1)).?;
    try testing.expect(deep_list != p1);
    try testing.expect(t.isSummary(deep_list));
    try testing.expect(t.isPrefix(below, deep_list) and !t.isPrefix(p1, deep_list));
    // The list's elements: `[*]` is a summary position.
    const elems = (try f.extend(p1, Step.elem)).?;
    try testing.expect(t.isSummary(elems));
    try testing.expectEqual(@as(usize, 5), t.paths.len);
    // The walk's memo answers a second ask with one read and no new place.
    try testing.expectEqual(tree, try f.of(0));
    try testing.expectEqual(@as(u32, 3), t.count());
    // A second extension of a known pair is a memo hit, charged one record
    // per request and no more (no ancestor walk, no new node).
    const before = f.account.growth;
    try testing.expectEqual(deep_list, (try f.extend(below, s1)).?);
    try testing.expectEqual(below, (try f.extend(root, s0)).?);
    try testing.expectEqual(before + 2, f.account.growth);
}

// `Maybe (Maybe (List Int))` and `Int × Int`: 0 outer Maybe, 1 inner Maybe,
// 2 List Int, 3 Int, 4 the tuple, 5 `type T = A T | B`.
const inst_nodes = [_]TestGraph.TestNode{
    .{ .kind = .ctor, .head = 300, .children = &.{.{ .kind = .ctor_arg, .payload = 1, .arg = 0, .@"var" = 1 }} },
    .{ .kind = .ctor, .head = 300, .children = &.{.{ .kind = .ctor_arg, .payload = 1, .arg = 0, .@"var" = 2 }} },
    .{ .kind = .list, .head = 200, .children = &.{.{ .kind = .elem, .@"var" = 3 }} },
    .{ .kind = .cross },
    .{ .kind = .tuple, .head = 2, .children = &.{ .{ .kind = .index, .payload = 0, .@"var" = 3 }, .{ .kind = .index, .payload = 1, .@"var" = 3 } } },
    .{ .kind = .ctor, .head = 400, .children = &.{.{ .kind = .ctor_arg, .payload = 2, .arg = 0, .@"var" = 5 }} },
};

test "a different instantiation is another place, and a type holding nothing crosses" {
    var f: Fixture = .{};
    f.init(&inst_nodes);
    defer f.deinit();
    const t = &f.table;
    const outer = try f.of(0);
    const step = try f.ctor(1, 0);
    const inner = t.child(outer, step).?;
    try testing.expect(inner != outer);
    try testing.expectEqual(Kind.ctor, t.kind(inner));
    try testing.expectEqual(Kind.list, t.kind(t.child(inner, step).?));
    const tuple = try f.of(4);
    try testing.expectEqual(Kind.cross, t.kind(tuple));
    try testing.expectEqual(@as(usize, 0), t.steps(tuple).steps.len);
    const self_only = try f.of(5);
    try testing.expectEqual(Kind.cross, t.kind(self_only));
    try testing.expect(t.holds(self_only).isEmpty());
}

/// A tuple chain of depth `d` ending in a list: `0 = (1, Int)`, `1 = (2,
/// Int)`, …, `d − 1 = (list, Int)`.
fn chainNodes(gpa: Allocator, d: u32) ![]TestGraph.TestNode {
    const nodes = try gpa.alloc(TestGraph.TestNode, d + 2);
    const int_node = d;
    const list_node = d + 1;
    for (0..d) |i| {
        const kids = try gpa.alloc(TestGraph.TestChild, 2);
        kids[0] = .{ .kind = .index, .payload = 0, .@"var" = if (i + 1 < d) @intCast(i + 1) else list_node };
        kids[1] = .{ .kind = .index, .payload = 1, .@"var" = int_node };
        nodes[i] = .{ .kind = .tuple, .head = 2, .children = kids };
    }
    nodes[int_node] = .{ .kind = .cross };
    const elem = try gpa.alloc(TestGraph.TestChild, 1);
    elem[0] = .{ .kind = .elem, .@"var" = int_node };
    nodes[list_node] = .{ .kind = .list, .head = 200, .children = elem };
    return nodes;
}

fn freeChain(gpa: Allocator, nodes: []TestGraph.TestNode) void {
    for (nodes) |n| if (n.children.len > 0) gpa.free(n.children);
    gpa.free(nodes);
}

test "holds settles a deep chain in O(E), not O(depth · E)" {
    const gpa = testing.allocator;
    const depth: u32 = 4000;
    const nodes = try chainNodes(gpa, depth);
    defer freeChain(gpa, nodes);
    var f: Fixture = .{};
    f.init(nodes);
    defer f.deinit();
    const top = try f.of(0);
    try testing.expect(f.table.holds(top).list);
    try testing.expectEqual(Kind.tuple, f.table.kind(top));
    // Every place once, plus one more visit per bit a child gained: the
    // list bit climbs the chain once. Nowhere near depth² = 16 million.
    try testing.expect(f.table.holds_visits <= 2 * (depth + 2) + 2);
    // A deep canonical path is bounded by `path_steps`, named.
    f.table.limits.path_steps = 100;
    var at = try f.table.rootPath(gpa, top);
    const s0 = try Step.index(&f.account, 0);
    var i: u32 = 0;
    var hit_limit = false;
    while (i < 200) : (i += 1) {
        at = (f.table.extend(gpa, .growth(&f.account), at, s0) catch |err| {
            try testing.expectEqual(error.OwnershipLimit, err);
            hit_limit = true;
            break;
        }) orelse break;
    }
    try testing.expect(hit_limit);
    try testing.expectEqual(Ids.Limit.path_steps, f.account.failed.?.limit);
}

test "input limits are named and stop the walk before it allocates" {
    var f: Fixture = .{};
    f.init(&inst_nodes);
    defer f.deinit();
    f.table.limits.type_places = 2;
    try testing.expectError(error.OwnershipLimit, f.of(0));
    try testing.expectEqual(Ids.Limit.type_places, f.account.failed.?.limit);
    try testing.expect(f.table.count() <= 2);
    var g: Fixture = .{};
    g.init(&inst_nodes);
    defer g.deinit();
    g.table.limits.children = 1;
    try testing.expectError(error.OwnershipLimit, g.of(4));
    try testing.expectEqual(Ids.Limit.tuple_arity, g.account.failed.?.limit);
    // A step payload past 28 bits is the format limit, not a truncation.
    var a: Account = .{};
    defer a.deinit(testing.allocator);
    _ = try Step.field(&a, (1 << 28) - 1);
    try testing.expectError(error.OwnershipLimit, Step.field(&a, 1 << 28));
    try testing.expectEqual(Ids.Limit.step_payload, a.failed.?.limit);
}

test "constructor steps order by (constructor, argument), whatever order they were first seen in" {
    var f: Fixture = .{};
    f.init(&tree_nodes);
    defer f.deinit();
    // Seen "out of order" first: the words still sort by the pair.
    const late = try f.ctor(0, 2);
    const early = try f.ctor(0, 0);
    try testing.expect(f.table.stepLess(early, late) and !f.table.stepLess(late, early));
    try testing.expectEqual([2]u32{ 0, 2 }, f.table.ctorArgOf(late));
    const tree = try f.of(0);
    const s = f.table.steps(tree);
    try testing.expectEqual(@as(usize, 3), s.steps.len);
    try testing.expect(f.table.stepLess(s.steps[0], s.steps[1]) and f.table.stepLess(s.steps[1], s.steps[2]));
}

/// A remap for the encode/decode test: heads and field names shifted by a
/// constant on the way out and back, as a string table would renumber them.
const Shift = struct {
    fn out(_: *anyopaque, x: u32) u32 {
        return x + 1000;
    }
    fn back(_: *anyopaque, x: u32) u32 {
        return x - 1000;
    }
    const names: Names = .{ .ctx = undefined, .head = out, .field = out };
    const remap: Remap = .{ .ctx = undefined, .head = back, .field = back };
};

// A record `{ a : List Int, b : Tree }` by field ranks 10 and 11: 0 record,
// 1 list, 2 Int, 3 Tree.
const record_nodes = [_]TestGraph.TestNode{
    .{ .kind = .record, .children = &.{ .{ .kind = .field, .payload = 10, .@"var" = 1 }, .{ .kind = .field, .payload = 11, .@"var" = 3 } } },
    .{ .kind = .list, .head = 200, .children = &.{.{ .kind = .elem, .@"var" = 2 }} },
    .{ .kind = .cross },
    .{ .kind = .ctor, .head = 100, .children = &.{
        .{ .kind = .ctor_arg, .payload = 0, .arg = 0, .@"var" = 3 },
        .{ .kind = .ctor_arg, .payload = 0, .arg = 1, .@"var" = 1 },
        .{ .kind = .ctor_arg, .payload = 0, .arg = 2, .@"var" = 3 },
    } },
};

test "encode writes a cycle once through the names table, and decode reads an equal graph" {
    var f: Fixture = .{};
    f.init(&record_nodes);
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.of(0);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try f.table.encode(gpa, rec, Shift.names, &words);
    // 4 places; a field step carries its name; heads are shifted.
    try testing.expectEqual(@as(u32, 4), words.items[0]);
    try testing.expectEqual(@as(usize, 1 + (4 + 2 * 3) + (4 + 2) + 4 + (4 + 3 * 4)), words.items.len);
    try testing.expectEqual(@as(u32, 1010), words.items[1 + 4 + 2]);
    // The nominal head of `Tree` went through the table; the record's did not.
    try testing.expectEqual(@as(u32, 0), words.items[2]);
    var decoded = (try Table.decode(gpa, &f.account, words.items, Shift.remap)).?;
    defer decoded.deinit(gpa);
    try testing.expectEqual(@as(u32, 100), decoded.head(.from(3)));
    try testing.expect(try Table.equals(&f.table, rec, &decoded, .from(0), gpa, .growth(&f.account)));
    // A different graph at the same place count is not equal, and the
    // comparison was charged per pair.
    var g: Fixture = .{};
    g.init(&inst_nodes);
    defer g.deinit();
    const outer = try g.of(0);
    const before = f.account.growth;
    try testing.expect(!try Table.equals(&f.table, rec, &g.table, outer, gpa, .growth(&f.account)));
    try testing.expect(f.account.growth > before);
    // Truncated or malformed words are no graph; neither is one whose
    // children come out of order after the remap.
    try testing.expect((try Table.decode(gpa, &f.account, words.items[0 .. words.items.len - 1], Shift.remap)) == null);
    try testing.expect((try Table.decode(gpa, &f.account, &.{}, Shift.remap)) == null);
    const Swap = struct {
        fn back(_: *anyopaque, x: u32) u32 {
            return if (x == 1010) 11 else if (x == 1011) 10 else x - 1000;
        }
        const remap: Remap = .{ .ctx = undefined, .head = Shift.back, .field = back };
    };
    try testing.expect((try Table.decode(gpa, &f.account, words.items, Swap.remap)) == null);
}

/// One place of every kind, each nominal one with a distinctive head:
/// 0 record { a : 1, b : 2 }, 1 list, 2 dict, 3 ref, 4 closure, 5 opaque,
/// 6 var, 7 tuple (var, Int), 8 `type T = A T | B` (crosses), 9 Int.
const every_kind = [_]TestGraph.TestNode{
    .{ .kind = .record, .children = &.{ .{ .kind = .field, .payload = 10, .@"var" = 1 }, .{ .kind = .field, .payload = 11, .@"var" = 2 } } },
    .{ .kind = .list, .head = 777, .children = &.{.{ .kind = .elem, .@"var" = 3 }} },
    .{ .kind = .dict, .head = 778, .children = &.{.{ .kind = .elem, .@"var" = 4 }} },
    .{ .kind = .ref, .head = 779, .children = &.{.{ .kind = .contents, .@"var" = 5 }} },
    .{ .kind = .closure, .head = 780, .children = &.{.{ .kind = .env, .@"var" = 6 }} },
    .{ .kind = .@"opaque", .head = 781, .children = &.{.{ .kind = .slot, .payload = 0, .@"var" = 7 }} },
    .{ .kind = .@"var" },
    .{ .kind = .tuple, .head = 2, .children = &.{ .{ .kind = .index, .payload = 0, .@"var" = 6 }, .{ .kind = .index, .payload = 1, .@"var" = 8 } } },
    .{ .kind = .ctor, .head = 782, .children = &.{ .{ .kind = .ctor_arg, .payload = 0, .arg = 0, .@"var" = 8 }, .{ .kind = .ctor_arg, .payload = 1, .arg = 0, .@"var" = 9 } } },
    .{ .kind = .cross },
};

test "no session id reaches the bytes for any place kind, a reclassified leaf included" {
    var f: Fixture = .{};
    f.init(&every_kind);
    defer f.deinit();
    const gpa = testing.allocator;
    const rec = try f.of(0);
    // `type T = A T | B` holds nothing: a leaf, and no longer a `T`.
    const t = try f.of(8);
    try testing.expectEqual(Kind.cross, f.table.kind(t));
    try testing.expectEqual(@as(u32, 0), f.table.head(t));
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try f.table.encode(gpa, rec, Shift.names, &words);
    for (words.items) |w| {
        for ([_]u32{ 777, 778, 779, 780, 781, 782 }) |head| try testing.expect(w != head);
    }
    var decoded = (try Table.decode(gpa, &f.account, words.items, Shift.remap)).?;
    defer decoded.deinit(gpa);
    try testing.expect(try Table.equals(&f.table, rec, &decoded, .from(0), gpa, .growth(&f.account)));
    // Every head came back as it was, the leaf's as 0.
    var i: u32 = 0;
    var seen_heads: u32 = 0;
    while (i < decoded.count()) : (i += 1) {
        const h = decoded.head(.from(i));
        if (h >= 777 and h <= 782) seen_heads += 1;
    }
    try testing.expectEqual(@as(u32, 5), seen_heads);
}

test "a refused walk leaves no placeholder: the next owner gets the real place" {
    var f: Fixture = .{};
    f.init(&record_nodes);
    defer f.deinit();
    // Owner A is refused by the child limit after `describe`; owner B, with
    // the limit restored, must see the record and its lists, not a leaf.
    f.table.limits.children = 1;
    try testing.expectError(error.OwnershipLimit, f.of(0));
    try testing.expectEqual(@as(u32, 0), f.table.count());
    try testing.expectEqual(@as(usize, 0), f.table.step_tab.len);
    f.table.limits.children = Ids.Limit.record_fields.value();
    var b: Account = .{};
    defer b.deinit(testing.allocator);
    // The source checks step payloads against the owner's account too.
    f.graph.account = &b;
    const rec = try f.table.of(testing.allocator, &b, f.graph.source(), 0);
    try testing.expectEqual(Kind.record, f.table.kind(rec));
    try testing.expectEqual(@as(usize, 2), f.table.steps(rec).steps.len);
    try testing.expect(f.table.holds(rec).list);
    // An exhausted owner deep in a walk (the tree below the record) undoes
    // everything it added, and B rebuilds it whole.
    var g: Fixture = .{};
    g.init(&record_nodes);
    defer g.deinit();
    g.account.allowance = 0;
    try testing.expectError(error.OwnershipLimit, g.account.reserve(.cell, 1));
    try testing.expectError(error.OwnershipLimit, g.of(0));
    try testing.expectEqual(@as(u32, 0), g.table.count());
    g.graph.account = &b;
    const rec2 = try g.table.of(testing.allocator, &b, g.graph.source(), 0);
    try testing.expectEqual(@as(u32, 4), g.table.count());
    try testing.expectEqual(Kind.ctor, g.table.kind(g.table.child(rec2, try Step.field(&b, 11)).?));
}

test "two tables that intern one type in different orders write identical bytes" {
    const gpa = testing.allocator;
    var f: Fixture = .{};
    f.init(&record_nodes);
    defer f.deinit();
    var g: Fixture = .{};
    g.init(&record_nodes);
    defer g.deinit();
    // `g` interns the Tree's constructor steps in another order first.
    _ = try g.ctor(0, 2);
    _ = try g.ctor(0, 1);
    _ = try g.ctor(0, 0);
    const rf = try f.of(0);
    const rg = try g.of(0);
    var wf: std.ArrayList(u32) = .empty;
    defer wf.deinit(gpa);
    var wg: std.ArrayList(u32) = .empty;
    defer wg.deinit(gpa);
    try f.table.encode(gpa, rf, Names.identity, &wf);
    try g.table.encode(gpa, rg, Names.identity, &wg);
    try testing.expectEqualSlices(u32, wf.items, wg.items);
    // And both decode to a graph equal to either.
    var decoded = (try Table.decode(gpa, &f.account, wg.items, Names.identity)).?;
    defer decoded.deinit(gpa);
    try testing.expect(try Table.equals(&f.table, rf, &decoded, .from(0), gpa, .growth(&f.account)));
    try testing.expect(try Table.equals(&g.table, rg, &decoded, .from(0), gpa, .growth(&g.account)));
}
