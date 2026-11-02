//! L4: κ storage of `Cond.Table` (`docs/design/ownership-v2.md` §2.9,
//! §3.4): the hash-consed radix maps and the trie of positions a snapshot
//! is (`kappaGet`, `kappaSet`, `kappaAt`, `kappaLink`, `kappaMerge`, the
//! folds and the relabelling). `Of(Table)` is this part's methods over the
//! table `Cond.zig` declares; `Cond.zig` binds them by name (§5).
//!
//! Obligations kept here: none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Counters = @import("Counters.zig");
const Shape = @import("Shape.zig");
const CondId = Ids.CondId;
const NodeId = Ids.NodeId;
const Charge = Ids.Charge;
const Error = Ids.ChargeError;
const Step = Shape.Step;
const CondAlgebra = @import("CondAlgebra.zig");
const yes = CondAlgebra.yes;
const lost = CondAlgebra.lost;

/// A holder's κ snapshot: the root of a persistent map, `.none` when empty.
pub const Kappas = Ids.KappaId;

/// A κ map node: a leaf (`mask == 0`: `prefix` the key, `left` the
/// condition) or a branch; hash-consed, so equal maps are one root.
pub const MapNode = struct { prefix: u32, mask: u32, left: u32, right: u32 };

/// The part of `Cond.Table` this file holds, over the table `Cond.zig` declares.
pub fn Of(comptime Table: type) type {
    return struct {
        const fails = Table.fails;

        // ---- the κ snapshots ----------------------------------------------------
        //
        // A snapshot (§2.9, §3.4) is a trie of POSITIONS: a position stores
        // conditions by node (`here`, a radix map NodeId → CondId) and links
        // one step below (`links`, a radix map step word → Kappas). Paths are
        // the steps a read takes from the root of the snapshot that stores
        // them; a construction links its children's snapshots, never re-keyed.
        // A FOLD (`widen`'s, §2.9) is a position whose links lead back to
        // itself, its conditions keyed by node alone for every level below.

        pub fn mapNode(t: *const Table, id: u32) MapNode {
            return t.kmaps.get(id);
        }

        /// One map node, interned; reserved before the dictionary is touched.
        pub fn makeMap(t: *Table, gpa: Allocator, charge: Charge, n: MapNode) Error!u32 {
            try charge.reserve(gpa, .cond, 1);
            const got = try t.kmap_intern.getOrPut(gpa, .{ n.prefix, n.mask, n.left, n.right });
            if (got.found_existing) {
                Counters.setMakeRequest(&t.kmap_stats, got.value_ptr.*);
                return got.value_ptr.*;
            }
            got.value_ptr.* = @intCast(t.kmaps.len());
            try t.kmaps.append(gpa, n);
            try Counters.setMade(&t.kmap_stats, gpa, n.mask == 0, n.left, n.right);
            Counters.setMakeRequest(&t.kmap_stats, got.value_ptr.*);
            return got.value_ptr.*;
        }

        pub inline fn matches(key: u32, prefix: u32, mask: u32) bool {
            return (key & ~((mask << 1) -% 1)) == prefix;
        }

        pub fn mapJoin(t: *Table, gpa: Allocator, charge: Charge, p0: u32, t0: u32, p1: u32, t1: u32) Error!u32 {
            const mask = @as(u32, 1) << @intCast(31 - @clz(p0 ^ p1));
            const prefix = p0 & ~((mask << 1) -% 1);
            return if (p0 & mask == 0)
                t.makeMap(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t0, .right = t1 })
            else
                t.makeMap(gpa, charge, .{ .prefix = prefix, .mask = mask, .left = t1, .right = t0 });
        }

        /// The value at `key`, or null. O(min(32, depth)) reads.
        pub fn mapGet(t: *const Table, root: u32, key: u32) ?u32 {
            Counters.setRequest(&t.kmap_stats, .get, root);
            var at = root;
            while (at != Ids.none_int) {
                const m = t.mapNode(at);
                if (m.mask == 0) return if (m.prefix == key) m.left else null;
                if (!matches(key, m.prefix, m.mask)) return null;
                at = if (key & m.mask == 0) m.left else m.right;
            }
            return null;
        }

        /// `root` with `key ↦ v` (replacing), path-copied: ≤ 33 records.
        pub fn mapPut(t: *Table, gpa: Allocator, charge: Charge, root: u32, key: u32, v: u32) Error!u32 {
            Counters.setRequest(&t.kmap_stats, .insert_in, root);
            if (root == Ids.none_int) return t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
            const m = t.mapNode(root);
            if (m.mask == 0) {
                if (m.prefix == key) return if (m.left == v) root else t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
                const leaf = try t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
                return t.mapJoin(gpa, charge, key, leaf, m.prefix, root);
            }
            if (!matches(key, m.prefix, m.mask)) {
                const leaf = try t.makeMap(gpa, charge, .{ .prefix = key, .mask = 0, .left = v, .right = Ids.none_int });
                return t.mapJoin(gpa, charge, key, leaf, m.prefix, root);
            }
            if (key & m.mask == 0) {
                const l = try t.mapPut(gpa, charge, m.left, key, v);
                return if (l == m.left) root else t.makeMap(gpa, charge, .{ .prefix = m.prefix, .mask = m.mask, .left = l, .right = m.right });
            }
            const r = try t.mapPut(gpa, charge, m.right, key, v);
            return if (r == m.right) root else t.makeMap(gpa, charge, .{ .prefix = m.prefix, .mask = m.mask, .left = m.left, .right = r });
        }

        /// How two values bound to one key combine in a union: conditions by
        /// the lattice join, links by merging the two positions below.
        const Combine = enum { cond, link };

        pub fn combine(t: *Table, gpa: Allocator, charge: Charge, how: Combine, x: u32, y: u32) Error!u32 {
            if (x == y) return x;
            return switch (how) {
                .cond => (try t.join(gpa, charge, .from(x), .from(y))).int(),
                .link => (try t.kappaMerge(gpa, charge, .from(x), .from(y))).int(),
            };
        }

        /// The union of two maps, a key both bind combined (`how`). Persistent:
        /// `a` when `b` adds nothing. Every node pair inspected is a record; the
        /// recursion is the key width, 33 frames.
        pub fn mapUnion(t: *Table, gpa: Allocator, charge: Charge, how: Combine, a: u32, b: u32) Error!u32 {
            Counters.setRequest(&t.kmap_stats, .union_a, a);
            Counters.setRequest(&t.kmap_stats, .union_b, b);
            if (a == Ids.none_int) return b;
            if (b == Ids.none_int or a == b) return a;
            // Memoised per pair of map nodes and `Combine` (*Argument 2*): the union
            // of two maps that both grew meets, below their changed spines, the
            // pairs an earlier union met.
            const key: [3]u32 = .{ @backingInt(how), a, b };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_map_union.get(key)) |hit| return hit;
            const out = try t.mapUnionUncached(gpa, charge, how, a, b);
            (try t.memo_map_union.getOrPut(gpa, key)).value_ptr.* = out;
            return out;
        }

        pub fn mapUnionUncached(t: *Table, gpa: Allocator, charge: Charge, how: Combine, a: u32, b: u32) Error!u32 {
            try charge.reserve(gpa, .inspection, 1);
            const na = t.mapNode(a);
            const nb = t.mapNode(b);
            if (nb.mask == 0) {
                const old = t.mapGet(a, nb.prefix);
                const v = if (old) |o| try t.combine(gpa, charge, how, o, nb.left) else nb.left;
                if (old != null and old.? == v) return a;
                return t.mapPut(gpa, charge, a, nb.prefix, v);
            }
            if (na.mask == 0) {
                const old = t.mapGet(b, na.prefix);
                const v = if (old) |o| try t.combine(gpa, charge, how, na.left, o) else na.left;
                if (old != null and old.? == v) return b;
                return t.mapPut(gpa, charge, b, na.prefix, v);
            }
            if (na.mask == nb.mask and na.prefix == nb.prefix) {
                const l = try t.mapUnion(gpa, charge, how, na.left, nb.left);
                const r = try t.mapUnion(gpa, charge, how, na.right, nb.right);
                if (l == na.left and r == na.right) return a;
                if (l == nb.left and r == nb.right) return b;
                return t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = r });
            }
            if (na.mask > nb.mask and matches(nb.prefix, na.prefix, na.mask)) {
                if (nb.prefix & na.mask == 0) {
                    const l = try t.mapUnion(gpa, charge, how, na.left, b);
                    return if (l == na.left) a else t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = l, .right = na.right });
                }
                const r = try t.mapUnion(gpa, charge, how, na.right, b);
                return if (r == na.right) a else t.makeMap(gpa, charge, .{ .prefix = na.prefix, .mask = na.mask, .left = na.left, .right = r });
            }
            if (nb.mask > na.mask and matches(na.prefix, nb.prefix, nb.mask)) {
                if (na.prefix & nb.mask == 0) {
                    const l = try t.mapUnion(gpa, charge, how, a, nb.left);
                    return if (l == nb.left) b else t.makeMap(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = l, .right = nb.right });
                }
                const r = try t.mapUnion(gpa, charge, how, a, nb.right);
                return if (r == nb.right) b else t.makeMap(gpa, charge, .{ .prefix = nb.prefix, .mask = nb.mask, .left = nb.left, .right = r });
            }
            return t.mapJoin(gpa, charge, na.prefix, a, nb.prefix, b);
        }

        /// The `(key, value)` entries of a map in key order: a leaf walk on a
        /// stack of at most 34 entries. Iterating a whole map is the caller's
        /// charged task (§4.1).
        pub const MapIterator = struct {
            t: *const Table,
            stack: [34]u32 = undefined,
            depth: usize = 0,

            pub const Entry = struct { key: u32, value: u32 };

            pub fn next(it: *MapIterator) ?Entry {
                while (it.depth > 0) {
                    it.depth -= 1;
                    const m = it.t.mapNode(it.stack[it.depth]);
                    if (m.mask == 0) return .{ .key = m.prefix, .value = m.left };
                    it.stack[it.depth] = m.right;
                    it.stack[it.depth + 1] = m.left;
                    it.depth += 2;
                }
                return null;
            }
        };

        pub fn mapEntries(t: *const Table, root: u32) MapIterator {
            var it: MapIterator = .{ .t = t };
            if (root != Ids.none_int) {
                it.stack[0] = root;
                it.depth = 1;
            }
            return it;
        }

        /// One position of a snapshot, hash-consed: equal snapshots are one root.
        pub const Position = struct { here: u32, links: u32, fold: u32 };

        pub fn position(t: *const Table, ctx: Kappas) Position {
            if (ctx == .none) return .{ .here = Ids.none_int, .links = Ids.none_int, .fold = 0 };
            return t.kpos.get(ctx.int());
        }

        /// A position, interned (`.none` when it stores and links nothing and is
        /// no fold); reserved before the dictionary is touched.
        pub fn makePos(t: *Table, gpa: Allocator, charge: Charge, p: Position) Error!Kappas {
            if (p.here == Ids.none_int and p.links == Ids.none_int and p.fold == 0) return .none;
            try charge.reserve(gpa, .cond, 1);
            const got = try t.kpos_intern.getOrPut(gpa, .{ p.here, p.links, p.fold });
            if (got.found_existing) return .from(got.value_ptr.*);
            got.value_ptr.* = @intCast(t.kpos.len());
            try t.kpos.append(gpa, p);
            return .from(got.value_ptr.*);
        }

        /// κ stored for `n` at the position `ctx`, or null.
        pub fn kappaGet(t: *const Table, ctx: Kappas, n: NodeId) ?CondId {
            if (ctx == .none) return null;
            return if (t.mapGet(t.position(ctx).here, n.int())) |v| CondId.from(v) else null;
        }

        /// The position one step `s` below `ctx`: its link, `.none` without one;
        /// a fold is its own position at every step below (§2.9).
        pub fn kappaChild(t: *const Table, ctx: Kappas, s: Step) Kappas {
            if (ctx == .none) return .none;
            const p = t.position(ctx);
            if (p.fold != 0) return ctx;
            return if (t.mapGet(p.links, s.word())) |v| Kappas.from(v) else .none;
        }

        /// The position along `along` from `ctx`.
        pub fn kappaAlong(t: *const Table, ctx: Kappas, along: []const Step) Kappas {
            var at = ctx;
            for (along) |s| {
                if (at == .none) return .none;
                at = t.kappaChild(at, s);
            }
            return at;
        }

        pub fn isFold(t: *const Table, ctx: Kappas) bool {
            return ctx != .none and t.position(ctx).fold != 0;
        }

        /// A fold made by collapsing a snapshot (`kappaFold`), not by
        /// `propagate`'s walk: a built node or a delta absent at one of the
        /// positions it covered read `lost` there, and the collapse cannot tell
        /// which, so it reads `lost` (§2.9).
        pub fn isCollapsed(t: *const Table, ctx: Kappas) bool {
            return ctx != .none and t.position(ctx).fold == fold_collapsed;
        }

        /// `Position.fold`: an exact fold (`propagate` stores every built node
        /// it walks) or a collapsed one.
        pub const fold_exact: u32 = 1;
        pub const fold_collapsed: u32 = 2;

        pub const Set = struct { ctx: Kappas, changed: bool };

        /// `ctx` with κ(n) at this position joined with `k` (monotone, §2.12):
        /// the new root and whether κ(n) changed; the same root when not.
        /// `n` became a κ key: relevant to the crossing's `base_epoch` (*Bases*).
        pub fn keyed(t: *Table, gpa: Allocator, charge: Charge, n: NodeId) Error!void {
            if (t.shapes_hook) |s| try s.markRelevant(gpa, charge.account, n);
        }

        pub fn kappaSet(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, n: NodeId, k: CondId) Error!Set {
            const old = t.kappaGet(ctx, n);
            const new = if (old) |o| try t.join(gpa, charge, o, k) else k;
            if (old) |o| if (o == new) return .{ .ctx = ctx, .changed = false };
            const p = t.position(ctx);
            try t.keyed(gpa, charge, n);
            return .{ .ctx = try t.makePos(gpa, charge, .{ .here = try t.mapPut(gpa, charge, p.here, n.int(), new.int()), .links = p.links, .fold = p.fold }), .changed = true };
        }

        /// What `kappaAt` does at the position its path reaches.
        pub const PathOp = union(enum) { set: struct { node: NodeId, k: CondId }, merge: Kappas, fold };

        /// `root` with `op` done at the position along `along`, path-copied: a
        /// record per step; a fold on the way is the rest of the path itself.
        pub fn kappaAt(t: *Table, gpa: Allocator, charge: Charge, root: Kappas, along: []const Step, op: PathOp) Error!Kappas {
            // Down the path on an explicit stack (#1130: a path's length is the
            // source's depth, never native-stack depth), to its end or a fold.
            var way: std.ArrayList(Kappas) = .empty;
            defer way.deinit(gpa);
            var at = root;
            var i: usize = 0;
            while (i < along.len and !t.isFold(at)) : (i += 1) {
                try charge.reserve(gpa, .inspection, 1);
                try way.append(gpa, at);
                at = t.kappaChild(at, along[i]);
            }
            var out = switch (op) {
                .set => |s| (try t.kappaSet(gpa, charge, at, s.node, s.k)).ctx,
                .merge => |sub| try t.kappaMerge(gpa, charge, at, sub),
                .fold => if (t.isFold(at)) at else try t.kappaFold(gpa, charge, at),
            };
            // Back up, each position with its link replaced.
            while (way.pop()) |up| {
                i -= 1;
                out = try t.withLink(gpa, charge, up, along[i], out);
            }
            return out;
        }

        /// `kappaAt` setting κ(n) to `k` joined.
        pub fn kappaSetAt(t: *Table, gpa: Allocator, charge: Charge, root: Kappas, along: []const Step, n: NodeId, k: CondId) Error!Kappas {
            return t.kappaAt(gpa, charge, root, along, .{ .set = .{ .node = n, .k = k } });
        }

        /// `ctx` with its link at `s` replaced by `child`.
        pub fn withLink(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, s: Step, child: Kappas) Error!Kappas {
            const p = t.position(ctx);
            std.debug.assert(p.fold == 0);
            if (t.kappaChild(ctx, s) == child) return ctx;
            const links = if (child == .none) p.links else try t.mapPut(gpa, charge, p.links, s.word(), child.int());
            return t.makePos(gpa, charge, .{ .here = p.here, .links = links, .fold = 0 });
        }

        /// `ctx` with `child` linked one step `s` below (§2.9: a construction
        /// links each child's snapshot under its step, never re-keyed); a link
        /// there already is merged with it. One record when the step is new.
        pub fn kappaLink(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, s: Step, child: Kappas) Error!Kappas {
            if (child == .none) return ctx;
            if (t.isFold(ctx)) return t.kappaMerge(gpa, charge, ctx, child);
            const old = t.kappaChild(ctx, s);
            return t.withLink(gpa, charge, ctx, s, if (old == .none) child else try t.kappaMerge(gpa, charge, old, child));
        }

        /// Two snapshots combined (§2.9: a construction combines its children's
        /// snapshots and joins them where they bind one key): at each position
        /// the union of what both store, a node both bind joined, the links
        /// merged below. A fold takes the other side folded into it; two exact
        /// folds stay exact (each stores every built node of its own), anything
        /// collapsed into one is collapsed. `a` when `b` adds nothing.
        /// Memoised per unordered pair (§2.9): positions are immutable and
        /// interned by content, so a pair always merges to one position.
        pub fn kappaMerge(t: *Table, gpa: Allocator, charge: Charge, a: Kappas, b: Kappas) Error!Kappas {
            if (a == .none) return b;
            if (b == .none or a == b) return a;
            const mkey: [2]u32 = .{ @min(a.int(), b.int()), @max(a.int(), b.int()) };
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_merge.get(mkey)) |hit| return .from(hit);
            // The pairs below that both sides link merge first, on an explicit
            // stack (#1130: a snapshot's depth is the source's, never native-
            // stack depth); each pair is memoised once complete, so a position's
            // links then find their children merged.
            const Frame = struct { a: Kappas, b: Kappas, expanded: bool };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, .{ .a = a, .b = b, .expanded = false });
            while (stack.pop()) |f| {
                const key: [2]u32 = .{ @min(f.a.int(), f.b.int()), @max(f.a.int(), f.b.int()) };
                if (!f.expanded) {
                    try charge.reserve(gpa, .memo, 1);
                    if (t.memo_merge.get(key) != null) continue;
                    try stack.append(gpa, .{ .a = f.a, .b = f.b, .expanded = true });
                    const pa = t.position(f.a);
                    const pb = t.position(f.b);
                    if (pa.fold != 0 or pb.fold != 0) continue;
                    var lt = t.mapEntries(pa.links);
                    while (lt.next()) |e| {
                        try charge.reserve(gpa, .inspection, 1);
                        const y: Kappas = .from(t.mapGet(pb.links, e.key) orelse continue);
                        const x: Kappas = .from(e.value);
                        if (x != y) try stack.append(gpa, .{ .a = x, .b = y, .expanded = false });
                    }
                    continue;
                }
                if (t.memo_merge.get(key) != null) continue;
                const out = try t.kappaMergeUncached(gpa, charge, f.a, f.b);
                try charge.reserve(gpa, .memo, 1);
                (try t.memo_merge.getOrPut(gpa, key)).value_ptr.* = out.int();
            }
            return .from(t.memo_merge.get(mkey).?);
        }

        pub fn kappaMergeUncached(t: *Table, gpa: Allocator, charge: Charge, a: Kappas, b: Kappas) Error!Kappas {
            try charge.reserve(gpa, .inspection, 1);
            const pa = t.position(a);
            const pb = t.position(b);
            if (pa.fold != 0 or pb.fold != 0) {
                const fa = t.position(try t.kappaFold(gpa, charge, a));
                const fb = t.position(try t.kappaFold(gpa, charge, b));
                const here = try t.mapUnion(gpa, charge, .cond, fa.here, fb.here);
                const steps_union = try t.mapUnion(gpa, charge, .cond, fa.links, fb.links);
                return t.makePos(gpa, charge, .{ .here = here, .links = steps_union, .fold = @max(fa.fold, fb.fold) });
            }
            const here = try t.mapUnion(gpa, charge, .cond, pa.here, pb.here);
            const links = try t.mapUnion(gpa, charge, .link, pa.links, pb.links);
            if (here == pa.here and links == pa.links) return a;
            if (here == pb.here and links == pb.links) return b;
            return t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = 0 });
        }

        /// `ctx` collapsed into one COLLAPSED fold (§2.9): by node, the join of
        /// everything stored at it and below it; its links, which lead back to
        /// itself, the steps it saw (so a reader below it stays sparse). A
        /// record per position, step and entry folded in, each shared position
        /// once. An exact fold stays as it is.
        pub fn kappaFold(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas) Error!Kappas {
            if (ctx != .none and t.isFold(ctx)) return ctx;
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(gpa);
            var stack: std.ArrayList(Kappas) = .empty;
            defer stack.deinit(gpa);
            var here: u32 = Ids.none_int;
            var steps_seen: u32 = Ids.none_int;
            if (ctx != .none) try stack.append(gpa, ctx);
            while (stack.pop()) |at| {
                try charge.reserve(gpa, .memo, 1);
                const got = try seen.getOrPut(gpa, .{at.int()});
                if (got.found_existing) continue;
                got.value_ptr.* = 1;
                const p = t.position(at);
                here = try t.mapUnion(gpa, charge, .cond, here, p.here);
                var it = t.mapEntries(p.links);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    steps_seen = try t.mapPut(gpa, charge, steps_seen, e.key, 0);
                    if (p.fold == 0) try stack.append(gpa, .from(e.value));
                }
            }
            return t.makePos(gpa, charge, .{ .here = here, .links = steps_seen, .fold = fold_collapsed });
        }

        /// An empty fold of `kind` (`fold_exact` or `fold_collapsed`).
        pub fn kappaEmptyFold(t: *Table, gpa: Allocator, charge: Charge, fold_kind: u32) Error!Kappas {
            return t.makePos(gpa, charge, .{ .here = Ids.none_int, .links = Ids.none_int, .fold = fold_kind });
        }

        /// The fold `ctx` with step `s` among the steps it saw.
        pub fn kappaFoldStep(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, s: Step) Error!Kappas {
            const p = t.position(ctx);
            std.debug.assert(p.fold != 0);
            return t.makePos(gpa, charge, .{ .here = p.here, .links = try t.mapPut(gpa, charge, p.links, s.word(), 0), .fold = p.fold });
        }

        /// The `(node, condition)` entries stored at the position `ctx`.
        pub const HereIterator = struct {
            it: MapIterator,

            pub const Entry = struct { node: NodeId, cond: CondId };

            pub fn next(h: *HereIterator) ?Entry {
                const e = h.it.next() orelse return null;
                return .{ .node = .from(e.key), .cond = .from(e.value) };
            }
        };

        pub fn kappaHere(t: *const Table, ctx: Kappas) HereIterator {
            return .{ .it = t.mapEntries(t.position(ctx).here) };
        }

        /// The `(step, position)` links of `ctx`; a fold's are the steps it
        /// saw, each leading back to it.
        pub const LinkIterator = struct {
            it: MapIterator,
            fold: Kappas,

            pub const Entry = struct { step: Step, child: Kappas };

            pub fn next(l: *LinkIterator) ?Entry {
                const e = l.it.next() orelse return null;
                return .{ .step = Step.fromWord(e.key), .child = if (l.fold != .none) l.fold else .from(e.value) };
            }
        };

        pub fn kappaLinks(t: *const Table, ctx: Kappas) LinkIterator {
            const p = t.position(ctx);
            return .{ .it = t.mapEntries(p.links), .fold = if (p.fold != 0) ctx else .none };
        }

        /// How `kappaRelabel` maps an entry: its node (null: dropped) and its
        /// condition.
        pub const Relabel = struct {
            ctx: *anyopaque,
            node: *const fn (ctx: *anyopaque, n: NodeId) Error!?NodeId,
            cond: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId,
            /// Where several source nodes at one position become one image
            /// (`Shape.map` interns, #1372): the source an entry's key stands for
            /// at source position `pos` (null for a key that stands for no source
            /// there: none, or a stale entry of a node a branch join left elsewhere),
            /// and how many distinct sources at `pos` map to image `m`. A built
            /// source with no entry reads `lost` (§2.9), so the image's entry there
            /// is `lost` unless every one of those sources has one. Null: one source
            /// per image.
            source: ?*const fn (ctx: *anyopaque, pos: Kappas, n: NodeId) ?NodeId = null,
            present: ?*const fn (ctx: *anyopaque, pos: Kappas, m: NodeId) u32 = null,
            /// The projection correspondence (§2.9 *Keyed where a reader looks*):
            /// for a DAG node a projection made, the node a reader of the image
            /// meets there, the projection of its origin's image; null for none.
            /// The entry is keyed there too.
            projected: ?*const fn (ctx: *anyopaque, n: NodeId) Error!?NodeId = null,
        };

        /// Whether a snapshot stores an unresolved condition (an `inst` atom in an
        /// entry): a check that a published κ is resolved (§2.11), uncharged, for
        /// `runtime_safety` builds.
        pub fn kappaHoldsInst(t: *const Table, gpa: Allocator, ctx: Kappas) Allocator.Error!bool {
            if (ctx == .none) return false;
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(gpa);
            var stack: std.ArrayList(Kappas) = .empty;
            defer stack.deinit(gpa);
            var conds: std.ArrayList(CondId) = .empty;
            defer conds.deinit(gpa);
            try stack.append(gpa, ctx);
            while (stack.pop()) |at| {
                if (at == .none or (try seen.getOrPut(gpa, .{at.int()})).found_existing) continue;
                const p = t.position(at);
                var it = t.mapEntries(p.here);
                while (it.next()) |e| try conds.append(gpa, .from(e.value));
                while (conds.pop()) |k| {
                    if (k == yes or fails(k)) continue;
                    const c = t.get(k);
                    if (c.kind == .@"and") {
                        try conds.appendSlice(gpa, &.{ .from(c.a), .from(c.b) });
                    } else if (c.atom == .inst) return true;
                }
                if (p.fold != 0) continue;
                var lt = t.mapEntries(p.links);
                while (lt.next()) |e| try stack.append(gpa, .from(e.value));
            }
            return false;
        }

        /// Whether a snapshot stores an entry under a view or a node whose DAG
        /// holds one: a check of the invariant that a class is stored forced
        /// (§2.11), uncharged, for `runtime_safety` builds. A position found
        /// view-free is remembered while no knot is tied, as `holdsView`
        /// remembers nodes, so a class added checks only the positions it adds.
        pub fn kappaHoldsView(t: *Table, gpa: Allocator, shapes: *Shape.Table, ctx: Kappas) Allocator.Error!bool {
            if (ctx == .none) return false;
            if (t.kview_free_epoch != shapes.ties) {
                t.kview_free.deinit(gpa);
                t.kview_free = .{};
                t.kview_free_epoch = shapes.ties;
            }
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(gpa);
            var visited: std.ArrayList(Kappas) = .empty;
            defer visited.deinit(gpa);
            var stack: std.ArrayList(Kappas) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, ctx);
            while (stack.pop()) |at| {
                if (at == .none or t.kview_free.get(.{at.int()}) != null) continue;
                if ((try seen.getOrPut(gpa, .{at.int()})).found_existing) continue;
                try visited.append(gpa, at);
                const p = t.position(at);
                var it = t.mapEntries(p.here);
                while (it.next()) |e| if (try shapes.holdsView(gpa, .from(e.key))) return true;
                if (p.fold != 0) continue;
                var lt = t.mapEntries(p.links);
                while (lt.next()) |e| try stack.append(gpa, .from(e.value));
            }
            for (visited.items) |at| (try t.kview_free.getOrPut(gpa, .{at.int()})).value_ptr.* = 1;
            return false;
        }

        /// `ctx` with every stored entry's node and condition mapped, the
        /// positions' paths and folds unchanged (§2.9: `Shape.map` relabels
        /// each binding's node, its paths relative to the value's root). A
        /// record per position and entry, each shared position once.
        pub fn kappaRelabel(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, r: Relabel) Error!Kappas {
            if (ctx == .none) return .none;
            var memo: Ids.FixedDict(1) = .{};
            defer memo.deinit(gpa);
            var maps: Ids.FixedDict(1) = .{};
            defer maps.deinit(gpa);
            // Post-order on an explicit stack (#1130): a snapshot's depth is the
            // source's, never native-stack depth. A position's children are
            // relabelled before it; a shared one once (the memo).
            const Frame = struct { at: Kappas, expanded: bool };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, .{ .at = ctx, .expanded = false });
            while (stack.pop()) |f| {
                if (!f.expanded) {
                    try charge.reserve(gpa, .memo, 1);
                    if (memo.get(.{f.at.int()}) != null) continue;
                    try stack.append(gpa, .{ .at = f.at, .expanded = true });
                    const p = t.position(f.at);
                    if (p.fold == 0) {
                        var lt = t.mapEntries(p.links);
                        while (lt.next()) |e| try stack.append(gpa, .{ .at = .from(e.value), .expanded = false });
                    }
                    continue;
                }
                if (memo.get(.{f.at.int()}) != null) continue;
                try t.relabelOne(gpa, charge, f.at, r, &memo, &maps);
            }
            return .from(memo.get(.{ctx.int()}).?);
        }

        /// An entry map with each key's node and condition mapped: the union of
        /// its two halves' images, memoised per map node (`maps`), so a submap
        /// that many positions share is mapped once (§2.9: read-off maps κ
        /// submaps once under one correspondence). Two keys with one image
        /// join their conditions. The recursion is the key width.
        pub fn relabelMap(t: *Table, gpa: Allocator, charge: Charge, m: u32, r: Relabel, maps: *Ids.FixedDict(1)) Error!u32 {
            if (m == Ids.none_int) return Ids.none_int;
            try charge.reserve(gpa, .memo, 1);
            if (maps.get(.{m})) |hit| return hit;
            const n = t.mapNode(m);
            const out: u32 = if (n.mask == 0) blk: {
                try charge.reserve(gpa, .inspection, 1);
                const img = try r.node(r.ctx, .from(n.prefix));
                // The node a reader meets for a DAG made as a projection (§2.9
                // *Keyed where a reader looks*): the projection of its origin's image.
                const via: ?NodeId = if (r.projected) |f| try f(r.ctx, .from(n.prefix)) else null;
                if (img == null and via == null) break :blk Ids.none_int;
                const k = try r.cond(r.ctx, t, gpa, charge, .from(n.left));
                var one: u32 = Ids.none_int;
                if (img) |x| {
                    try t.keyed(gpa, charge, x);
                    one = try t.mapPut(gpa, charge, one, x.int(), k.int());
                }
                if (via) |x| if (img == null or x != img.?) {
                    try t.keyed(gpa, charge, x);
                    const old = t.mapGet(one, x.int());
                    one = try t.mapPut(gpa, charge, one, x.int(), if (old) |o| (try t.join(gpa, charge, .from(o), k)).int() else k.int());
                };
                break :blk one;
            } else try t.mapUnion(gpa, charge, .cond, try t.relabelMap(gpa, charge, n.left, r, maps), try t.relabelMap(gpa, charge, n.right, r, maps));
            (try maps.getOrPut(gpa, .{m})).value_ptr.* = out;
            return out;
        }

        /// One position relabelled, its children's images in `memo` already.
        pub fn relabelOne(t: *Table, gpa: Allocator, charge: Charge, ctx: Kappas, r: Relabel, memo: *Ids.FixedDict(1), maps: *Ids.FixedDict(1)) Error!void {
            const p = t.position(ctx);
            var here: u32 = Ids.none_int;
            // `(image, source)` of each entry whose image stands for several
            // sources here.
            var met: std.ArrayList([2]NodeId) = .empty;
            defer met.deinit(gpa);
            here = try t.relabelMap(gpa, charge, p.here, r, maps);
            if (r.present) |many| {
                var it = t.mapEntries(p.here);
                while (it.next()) |e| {
                    try charge.reserve(gpa, .inspection, 1);
                    const m = (try r.node(r.ctx, .from(e.key))) orelse continue;
                    if (many(r.ctx, ctx, m) >= 2) {
                        if (r.source.?(r.ctx, ctx, .from(e.key))) |s| try met.append(gpa, .{ m, s });
                    }
                }
            }
            // An image of several sources at this position is `lost` where one
            // of them has no entry: that source alone reads `lost` (§2.9), and
            // the image stands for each (#1372's review).
            if (met.items.len > 0) {
                std.mem.sort([2]NodeId, met.items, {}, struct {
                    fn lt(_: void, a: [2]NodeId, b: [2]NodeId) bool {
                        return if (a[0] != b[0]) a[0].int() < b[0].int() else a[1].int() < b[1].int();
                    }
                }.lt);
                try charge.reserve(gpa, .inspection, @intCast(met.items.len));
                var i: usize = 0;
                while (i < met.items.len) {
                    const m = met.items[i][0];
                    var distinct: u32 = 0;
                    var j = i;
                    while (j < met.items.len and met.items[j][0] == m) : (j += 1) {
                        if (j == i or met.items[j][1] != met.items[j - 1][1]) distinct += 1;
                    }
                    if (distinct < r.present.?(r.ctx, ctx, m)) here = try t.mapPut(gpa, charge, here, m.int(), lost.int());
                    i = j;
                }
            }
            // A fold's links are the steps it saw, its sparse frontier (§2.9),
            // each leading back to itself: kept as they are, never followed (#1129).
            var links: u32 = if (p.fold != 0) p.links else Ids.none_int;
            if (p.fold == 0) {
                var lt = t.mapEntries(p.links);
                while (lt.next()) |e| {
                    const child: Kappas = .from(memo.get(.{e.value}).?);
                    if (child != .none) links = try t.mapPut(gpa, charge, links, e.key, child.int());
                }
            }
            const out = try t.makePos(gpa, charge, .{ .here = here, .links = links, .fold = p.fold });
            (try memo.getOrPut(gpa, .{ctx.int()})).value_ptr.* = out.int();
        }
    };
}
