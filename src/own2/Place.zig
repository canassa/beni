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
//! **Canonical paths** (§2.1) are a trie (`paths`): a step that re-enters a
//! place already on the path pops back to it and appends `⟲`, so a path
//! names a place at most once and is at most 2·|places| long.
//!
//! **Holds** is the least fixpoint of "what kinds of cell may sit at or
//! below this place"; a `ctor` or `tuple` holding nothing is reclassified
//! `cross` (§2.1's last row), which is what makes an `Int × Int` or a
//! `type T = A T | B` a leaf.
//!
//! **Structural identity.** `encode` writes a sub-graph as
//! `(kind, head, children)` records with ordinals for backreferences, so a
//! cycle is one record; `decode` reads one back into a table of its own;
//! `equals` is the charged graph-pair walk two tables are compared by
//! (§2.1, *Identity*). A field name is written as its symbol: the block
//! writer (L11) maps symbols through its string table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const stamped = @import("../stamped.zig");

pub const PlaceId = Ids.PlaceId;
pub const PathId = Ids.PathId;
pub const ClassId = Ids.ClassId;

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
    /// `.f`: the payload is the field's symbol.
    field,
    /// `.i`: a tuple index.
    index,
    /// `C#i`: the payload indexes `ctor_args`.
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

    pub fn field(symbol: u32) Step {
        return .{ .kind = .field, .payload = @intCast(symbol) };
    }
    pub fn index(i: u32) Step {
        return .{ .kind = .index, .payload = @intCast(i) };
    }
    pub fn slot(n: u32) Step {
        return .{ .kind = .slot, .payload = @intCast(n) };
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
/// children in canonical step order (fields by name text, indices,
/// constructor then argument) and returns its kind and head. Passed down,
/// never stored (§5).
pub const Source = struct {
    ctx: *anyopaque,
    describe: *const fn (ctx: *anyopaque, v: u32, out: *std.ArrayList(Child)) Allocator.Error!Description,
};

pub const Place = struct {
    kind: Kind,
    head: u32,
    steps: Ids.Range,
    holds: Holds,
    /// A declared class for a `closure` place (#587's slot); `.none` today.
    class: ClassId,
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
};

pub const Error = Allocator.Error || error{OwnershipLimit};

/// §4.4's input limits.
pub const max_places: u32 = 1 << 24;
pub const max_path_steps: u32 = 65_536;

pub const Table = struct {
    places: std.MultiArrayList(Place) = .empty,
    step_tab: std.MultiArrayList(StepEntry) = .empty,
    /// `C#i` steps, interned: `(constructor, argument)` → payload.
    ctor_args: Ids.FixedDict(2) = .{},
    /// The type walk's memo, type variable → place.
    by_var: stamped.Column(u32, PlaceId) = .{},
    paths: std.MultiArrayList(PathNode) = .empty,
    /// `(parent path, step)` → path; a root is `(none, place)`.
    path_index: Ids.FixedDict(2) = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.places.deinit(gpa);
        t.step_tab.deinit(gpa);
        t.ctor_args.deinit(gpa);
        t.by_var.deinit(gpa);
        t.paths.deinit(gpa);
        t.path_index.deinit(gpa);
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
            if (words[mid].word() < step.word()) lo = mid + 1 else hi = mid;
        }
        if (lo < words.len and words[lo].word() == step.word()) return t.step_tab.items(.child)[r.start + lo];
        return null;
    }

    /// The `C#i` step for constructor `c`'s argument `i`.
    pub fn ctorStep(t: *Table, gpa: Allocator, c: u32, i: u32) Allocator.Error!Step {
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
    pub fn of(t: *Table, gpa: Allocator, source: Source, root: u32) Error!PlaceId {
        if (t.by_var.get(root)) |p| return p;
        var scratch: std.ArrayList(Child) = .empty;
        defer scratch.deinit(gpa);
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        const first_new = t.count();
        const top = try t.open(gpa, source, root, &scratch, &stack);
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
            if (t.by_var.get(c.@"var")) |known| {
                t.step_tab.items(.child)[slot] = known;
                continue;
            }
            const made = try t.open(gpa, source, c.@"var", &scratch, &stack);
            t.step_tab.items(.child)[slot] = made;
        }
        try t.settleHolds(first_new);
        return top;
    }

    /// Allocate `v`'s place, memoise it BEFORE its children are visited
    /// (the knot), describe it and push a frame for its children.
    fn open(t: *Table, gpa: Allocator, source: Source, v: u32, scratch: *std.ArrayList(Child), stack: *std.ArrayList(Frame)) Error!PlaceId {
        if (t.count() >= max_places) return error.OwnershipLimit;
        const id: PlaceId = .from(t.count());
        try t.by_var.put(gpa, v, id);
        try t.places.append(gpa, .{ .kind = .cross, .head = 0, .steps = .empty, .holds = .{}, .class = .none });
        const first: u32 = @intCast(scratch.items.len);
        const d = try source.describe(source.ctx, v, scratch);
        const len: u32 = @intCast(scratch.items.len - first);
        const start: u32 = @intCast(t.step_tab.len);
        try t.step_tab.ensureUnusedCapacity(gpa, len);
        for (scratch.items[first..]) |c| t.step_tab.appendAssumeCapacity(.{ .step = c.step, .child = .none });
        // Children arrive in canonical order; the binary search in `child`
        // relies on the words being sorted, which they are when the
        // description's order agrees with the word order of `Step`.
        if (std.debug.runtime_safety) {
            var i: u32 = 1;
            while (i < len) : (i += 1) std.debug.assert(scratch.items[first + i - 1].step.word() < scratch.items[first + i].step.word());
        }
        t.places.set(id.int(), .{ .kind = d.kind, .head = d.head, .steps = .{ .start = start, .len = len }, .holds = d.kind.own(), .class = .none });
        try stack.append(gpa, .{ .place = id, .first = first, .len = len, .cursor = 0 });
        return id;
    }

    /// The least fixpoint of `holds` over the places from `first` on, then
    /// the `cross` reclassification. Each round visits every new place
    /// once; at most seven rounds change a bit, so O(7·E).
    fn settleHolds(t: *Table, first: u32) Error!void {
        const kinds = t.places.items(.kind);
        const hs = t.places.items(.holds);
        const ranges = t.places.items(.steps);
        const children = t.step_tab.items(.child);
        var changed = true;
        while (changed) {
            changed = false;
            var i: u32 = first;
            while (i < t.count()) : (i += 1) {
                var h = hs[i];
                const r = ranges[i];
                for (children[r.start..][0..r.len]) |c| h = h.join(hs[c.int()]);
                if (h.bits() != hs[i].bits()) {
                    hs[i] = h;
                    changed = true;
                }
            }
        }
        var i: u32 = first;
        while (i < t.count()) : (i += 1) {
            if ((kinds[i] == .ctor or kinds[i] == .tuple) and hs[i].isEmpty()) {
                kinds[i] = .cross;
                ranges[i].len = 0;
            }
        }
    }

    // ---- canonical paths ------------------------------------------------

    /// The `ε` path of `place`.
    pub fn rootPath(t: *Table, gpa: Allocator, place: PlaceId) Allocator.Error!PathId {
        const got = try t.path_index.getOrPut(gpa, .{ Ids.none_int, place.int() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(t.paths.len);
            try t.paths.append(gpa, .{ .parent = .none, .step = Step.level, .place = place, .depth = 0 });
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

    pub fn pathDepth(t: *const Table, p: PathId) u32 {
        return t.paths.items(.depth)[p.int()];
    }

    /// Whether `prefix` is `path` or an ancestor of it.
    pub fn isPrefix(t: *const Table, prefix: PathId, path: PathId) bool {
        var at = path;
        while (at != .none) : (at = t.pathParent(at)) if (at == prefix) return true;
        return false;
    }

    /// `path · step`, canonical (§2.1): null when the place has no such
    /// step; a step onto a place already on the path pops back to its node
    /// and appends `⟲` (once). O(path length) column reads, charged by the
    /// caller per step.
    pub fn extend(t: *Table, gpa: Allocator, path: PathId, step: Step) Error!?PathId {
        const here = t.pathPlace(path);
        const target = t.child(here, step) orelse return null;
        // Re-entry: is `target` on the path?
        var at = path;
        while (at != .none) : (at = t.pathParent(at)) {
            if (t.pathPlace(at) == target) {
                // Already `⟲` here (the root's placeholder step is not one).
                if (t.pathParent(at) != .none and t.pathStep(at).kind == .level) return at;
                return try t.node(gpa, at, Step.level, target);
            }
        }
        return try t.node(gpa, path, step, target);
    }

    fn node(t: *Table, gpa: Allocator, parent: PathId, step: Step, place: PlaceId) Error!PathId {
        const depth = t.pathDepth(parent) + 1;
        if (depth > max_path_steps) return error.OwnershipLimit;
        const got = try t.path_index.getOrPut(gpa, .{ parent.int(), step.word() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(t.paths.len);
            try t.paths.append(gpa, .{ .parent = parent, .step = step, .place = place, .depth = depth });
        }
        return .from(got.value_ptr.*);
    }

    /// Whether `path` is a summary position or below one: it holds a
    /// `[*]` or a `⟲` (§2.2's occurrence rule).
    pub fn isSummary(t: *const Table, path: PathId) bool {
        var at = path;
        while (at != .none) : (at = t.pathParent(at)) {
            const k = t.pathStep(at).kind;
            if (t.pathParent(at) != .none and (k == .elem or k == .level)) return true;
        }
        return false;
    }

    // ---- structural identity --------------------------------------------

    /// Write the sub-graph under `root` as records in pre-order ordinals:
    /// `[count] { kind, head, holds, n, (step, child ordinal)×n }`. A place
    /// is written once; a child seen before is its ordinal (a cycle too).
    pub fn encode(t: *const Table, gpa: Allocator, root: PlaceId, out: *std.ArrayList(u32)) Allocator.Error!void {
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
            try out.appendSlice(gpa, &.{ @backingInt(t.kind(p)), t.head(p), t.holds(p).bits(), r.len });
            for (t.step_tab.items(.step)[r.start..][0..r.len], t.step_tab.items(.child)[r.start..][0..r.len]) |s, c| {
                try out.appendSlice(gpa, &.{ s.word(), ordinal.get(c).? });
                // A `C#i` payload is this table's intern index: the pair follows.
                if (s.kind == .ctor_arg) try out.appendSlice(gpa, &t.ctorArgOf(s));
            }
        }
    }

    /// Read a graph `encode` wrote into a table of its own; the root is
    /// place 0. Null when the words are not a graph (R-5.7.4: an undecodable
    /// block is no block).
    pub fn decode(gpa: Allocator, words: []const u32) Allocator.Error!?Table {
        var t: Table = .{};
        decodeInto(&t, gpa, words) catch |err| switch (err) {
            error.OutOfMemory => {
                t.deinit(gpa);
                return error.OutOfMemory;
            },
            error.Malformed => {
                t.deinit(gpa);
                return null;
            },
        };
        return t;
    }

    fn decodeInto(t: *Table, gpa: Allocator, words: []const u32) (Allocator.Error || error{Malformed})!void {
        if (words.len == 0) return error.Malformed;
        const n = words[0];
        var at: usize = 1;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (at + 4 > words.len) return error.Malformed;
            const k = words[at];
            if (k > @backingInt(Kind.cross)) return error.Malformed;
            const h = words[at + 1];
            const hb = words[at + 2];
            const len = words[at + 3];
            at += 4;
            if (hb > 0x7f) return error.Malformed;
            const start: u32 = @intCast(t.step_tab.len);
            var j: u32 = 0;
            var last: u64 = 0;
            while (j < len) : (j += 1) {
                if (at + 2 > words.len) return error.Malformed;
                var s = Step.fromWord(words[at]);
                const c = words[at + 1];
                at += 2;
                if (c >= n) return error.Malformed;
                if (s.kind == .ctor_arg) {
                    if (at + 2 > words.len) return error.Malformed;
                    s = try t.ctorStep(gpa, words[at], words[at + 1]);
                    at += 2;
                }
                if (j > 0 and s.word() <= last) return error.Malformed;
                last = s.word();
                try t.step_tab.append(gpa, .{ .step = s, .child = .from(c) });
            }
            try t.places.append(gpa, .{ .kind = @fromBackingInt(@intCast(k)), .head = h, .steps = .{ .start = start, .len = len }, .holds = @bitCast(@as(u8, @intCast(hb))), .class = .none });
        }
        if (at != words.len) return error.Malformed;
    }

    /// Structural equality of `a` in `ta` and `b` in `tb`: a graph-pair
    /// walk, every pair visited once, O(pairs) — the charged comparison of
    /// §2.1's *Identity*. `pairs` counts the pairs for the caller's account.
    pub fn equals(ta: *const Table, a: PlaceId, tb: *const Table, b: PlaceId, gpa: Allocator, pairs: *u32) Allocator.Error!bool {
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        var stack: std.ArrayList([2]PlaceId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ a, b });
        while (stack.pop()) |pair| {
            const got = try seen.getOrPut(gpa, .{ pair[0].int(), pair[1].int() });
            if (got.found_existing) continue;
            got.value_ptr.* = 1;
            pairs.* += 1;
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
    std.debug.assert(@sizeOf(Place) == 20);
    std.debug.assert(@sizeOf(StepEntry) == 8);
    std.debug.assert(@sizeOf(PathNode) == 16);
}

// ---------------------------------------------------------------------------
// Tests: a type graph built by hand.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test type graph: node `v` is `nodes[v]`.
const TestGraph = struct {
    nodes: []const TestNode,
    table: *Table,
    gpa: Allocator,

    const TestNode = struct { kind: Kind, head: u32 = 0, children: []const TestChild = &.{} };
    const TestChild = struct { kind: StepKind, payload: u32 = 0, @"var": u32, arg: u32 = 0 };

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Child)) Allocator.Error!Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        const n = g.nodes[v];
        for (n.children) |c| {
            const step: Step = switch (c.kind) {
                .field => Step.field(c.payload),
                .index => Step.index(c.payload),
                .ctor_arg => try g.table.ctorStep(g.gpa, c.payload, c.arg),
                .elem => Step.elem,
                .contents => Step.contents,
                .env => Step.env,
                .slot => Step.slot(c.payload),
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
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    var g: TestGraph = .{ .nodes = &tree_nodes, .table = &t, .gpa = testing.allocator };
    const tree = try t.of(testing.allocator, g.source(), 0);
    try testing.expectEqual(@as(u32, 3), t.count());
    try testing.expectEqual(Kind.ctor, t.kind(tree));
    try testing.expect(t.holds(tree).list and !t.holds(tree).record);
    const s0 = try t.ctorStep(testing.allocator, 0, 0);
    const s1 = try t.ctorStep(testing.allocator, 0, 1);
    const s2 = try t.ctorStep(testing.allocator, 0, 2);
    // Both recursive children are the root itself.
    try testing.expectEqual(tree, t.child(tree, s0).?);
    try testing.expectEqual(tree, t.child(tree, s2).?);
    const list = t.child(tree, s1).?;
    try testing.expectEqual(Kind.list, t.kind(list));
    try testing.expectEqual(@as(?PlaceId, null), t.child(list, s0));
    // Paths: `#Node.1` is exact; `#Node.0` re-enters the root and is `⟲`.
    const root = try t.rootPath(testing.allocator, tree);
    const p1 = (try t.extend(testing.allocator, root, s1)).?;
    try testing.expectEqual(list, t.pathPlace(p1));
    try testing.expect(!t.isSummary(p1));
    const below = (try t.extend(testing.allocator, root, s0)).?;
    try testing.expectEqual(StepKind.level, t.pathStep(below).kind);
    try testing.expectEqual(tree, t.pathPlace(below));
    try testing.expectEqual(@as(u32, 1), t.pathDepth(below));
    // Further levels stay at the one ⟲; a list below is `⟲#Node.1`.
    try testing.expectEqual(below, (try t.extend(testing.allocator, below, s2)).?);
    try testing.expectEqual(below, (try t.extend(testing.allocator, root, s2)).?);
    const deep_list = (try t.extend(testing.allocator, below, s1)).?;
    try testing.expect(deep_list != p1);
    try testing.expect(t.isSummary(deep_list));
    try testing.expect(t.isPrefix(below, deep_list) and !t.isPrefix(p1, deep_list));
    // The list's elements: `[*]` is a summary position.
    const elems = (try t.extend(testing.allocator, p1, Step.elem)).?;
    try testing.expect(t.isSummary(elems));
    try testing.expectEqual(@as(usize, 5), t.paths.len);
    // The walk's memo answers a second ask with one read and no new place.
    try testing.expectEqual(tree, try t.of(testing.allocator, g.source(), 0));
    try testing.expectEqual(@as(u32, 3), t.count());
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
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    var g: TestGraph = .{ .nodes = &inst_nodes, .table = &t, .gpa = testing.allocator };
    const outer = try t.of(testing.allocator, g.source(), 0);
    const step = try t.ctorStep(testing.allocator, 1, 0);
    const inner = t.child(outer, step).?;
    try testing.expect(inner != outer);
    try testing.expectEqual(Kind.ctor, t.kind(inner));
    try testing.expectEqual(Kind.list, t.kind(t.child(inner, step).?));
    const tuple = try t.of(testing.allocator, g.source(), 4);
    try testing.expectEqual(Kind.cross, t.kind(tuple));
    try testing.expectEqual(@as(usize, 0), t.steps(tuple).steps.len);
    const self_only = try t.of(testing.allocator, g.source(), 5);
    try testing.expectEqual(Kind.cross, t.kind(self_only));
    try testing.expect(t.holds(self_only).isEmpty());
}

test "encode writes a cycle once and decode reads an equal graph" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    var g: TestGraph = .{ .nodes = &tree_nodes, .table = &t, .gpa = testing.allocator };
    const tree = try t.of(testing.allocator, g.source(), 0);
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try t.encode(testing.allocator, tree, &words);
    // 3 places: header, then 4 words each plus 2 per child (+2 per C#i).
    try testing.expectEqual(@as(u32, 3), words.items[0]);
    try testing.expectEqual(@as(usize, 1 + (4 + 3 * 4) + (4 + 2) + 4), words.items.len);
    var back = (try Table.decode(testing.allocator, words.items)).?;
    defer back.deinit(testing.allocator);
    var pairs: u32 = 0;
    try testing.expect(try Table.equals(&t, tree, &back, .from(0), testing.allocator, &pairs));
    try testing.expectEqual(@as(u32, 3), pairs);
    // A different graph at the same head is not equal.
    var t2: Table = .{};
    defer t2.deinit(testing.allocator);
    var g2: TestGraph = .{ .nodes = &inst_nodes, .table = &t2, .gpa = testing.allocator };
    const outer = try t2.of(testing.allocator, g2.source(), 0);
    try testing.expect(!try Table.equals(&t, tree, &t2, outer, testing.allocator, &pairs));
    // Truncated or malformed words are no graph.
    try testing.expect((try Table.decode(testing.allocator, words.items[0 .. words.items.len - 1])) == null);
    try testing.expect((try Table.decode(testing.allocator, &.{})) == null);
}
