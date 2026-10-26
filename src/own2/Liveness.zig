//! L5: the use index and its queries (`docs/design/ownership-v2.md` §2.7,
//! §3.4a). A use is `(local, path, point, kind, callee use node)`; the index
//! holds the uses of every frame of ONE owning declaration (its body, its
//! lambdas, its local functions: their locals are distinct), sorted by
//! `(local, path, point)`, keyed by PATH and never by place (two fields of
//! one record type share a place), each use entered once at its own path.
//! It is built once per declaration and phase (§4.1's two copies of the
//! source lanes): the account is the declaration's, and every lane below
//! is keyed by a source atom unique in it — a use's operand occurrence
//! (`Use.atom`), a canonical path node (`Ids.atom_path_bit`), a region id —
//! so two frames never meet in one lane.
//!
//! **Paths are ordered lexicographically by their steps from the root**
//! (`Place.stepLess`), so every descendant of a path is contiguous right
//! after it: a subtree is one index range found by two binary searches, and
//! no use is copied to an ancestor (§3.4a's "DFS interval").
//!
//! **The range index** is a merge-sort tree over the sorted uses: each
//! segment node holds its uses' `(point, use)` pairs sorted by point, so
//! "a use of this subtree with a point in `(lo, hi]`" is O(log² U)
//! fixed-word steps and returns the use. A query descends it explicitly,
//! one record per tree node and candidate visited, on the caller's `Charge`
//! — the demand's own lane (§4.1, *direct demand query*) or growth.
//!
//! **Compatibility** (§2.5) comes from `Regions.rangesAfterCharged`: the
//! points after `p` compatible with it are at most `depth` intervals, each
//! one range query, every region climbed and sibling arm read a record on
//! the query's charge before it is read, as is every step of the queried
//! path. `Ancestry` is the fixed-word form for one PAIR of points (what
//! `Demands` asks of a holder's use): binary lifting over the region tree,
//! LCA in O(log depth) with no allocation per query (§4.1's at-most-64-step
//! ancestry), its slots in the region atom's source-settlement lane.
//!
//! **Kinds** (§2.7): the index returns uses; a `call` use counts only when
//! the callee's use node is non-empty at the remainder of the queried path,
//! which the caller decides through `Filter` (it has the shape tables; a
//! `Summary.usedAt`). The filter sees candidates in point order and the
//! first it accepts is the answer, so the holder "used first" is found.
//!
//! Obligations kept here: O2's index half (a use is found at its own path
//! and at every prefix, in the right region, with its kind), O12 (a
//! `field` use is reported as such, so a hoist rests on this frame's own
//! read).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Regions = @import("Regions.zig");
const Shape = @import("Shape.zig");
const stamped = @import("../stamped.zig");

pub const Use = Facts.Use;
pub const UseId = Ids.UseId;
pub const PathId = Ids.PathId;
pub const RegionId = Ids.RegionId;
pub const Charge = Ids.Charge;
pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;

/// The caller's say on a candidate (§2.7): a `call` use counts when its node
/// is non-empty at the remainder of the queried path below the use's own
/// (the use carries its path; the caller knows the queried one).
pub const Filter = struct {
    ctx: *anyopaque,
    accept: *const fn (ctx: *anyopaque, use: Use, id: UseId) Error!bool,

    /// Every use counts.
    pub const all: Filter = .{ .ctx = undefined, .accept = yes };
    fn yes(_: *anyopaque, _: Use, _: UseId) Error!bool {
        return true;
    }
};

pub const Index = struct {
    uses: std.MultiArrayList(Use) = .empty,
    /// Per local: its run of `uses`.
    by_local: []Ids.Range = &.{},
    /// Per local: its last point of use, or `none`.
    last: []u32 = &.{},
    /// The merge-sort tree: `size` leaves (a power of two), node `i`'s
    /// pairs at `pairs[off[i]..off[i + 1]]`, sorted by point.
    size: u32 = 0,
    off: []u32 = &.{},
    pairs: []Pair = &.{},
    /// The steps of every path a use names, root first, for the order.
    steps: std.ArrayList(Place.Step) = .empty,
    runs: stamped.Column(PathId, Ids.Range) = .{},

    pub const Pair = struct { point: u32, use: u32 };

    pub fn deinit(x: *Index, gpa: Allocator) void {
        x.uses.deinit(gpa);
        gpa.free(x.by_local);
        gpa.free(x.last);
        gpa.free(x.off);
        gpa.free(x.pairs);
        x.steps.deinit(gpa);
        x.runs.deinit(gpa);
    }

    pub fn count(x: *const Index) u32 {
        return @intCast(x.uses.len);
    }

    pub fn get(x: *const Index, id: UseId) Use {
        return x.uses.get(id.int());
    }

    /// The last point `local` is used at, or `none` (§2.8's holder expiry).
    pub fn lastUse(x: *const Index, local: u32) u32 {
        return if (local < x.last.len) x.last[local] else none;
    }

    // ---- building --------------------------------------------------------------

    /// The index of a declaration's uses in `phase`. Each use is one record
    /// in its own `liveness_index` lane (atom: `Use.atom`, its source
    /// occurrence) plus one per tree level it enters (≤ 33); each node of a
    /// path read is one record in that NODE's lane (`atom_path_bit`), once
    /// per build, so a 600-step path is 600 lanes of one record and never a
    /// lane of 600; the sort is covered by the use's record. O(U log U ·
    /// depth).
    pub fn build(gpa: Allocator, account: *Ids.Account, phase: Ids.Phase, places: *const Place.Table, uses: []const Use) Error!Index {
        var x: Index = .{};
        errdefer x.deinit(gpa);
        const n: u32 = @intCast(uses.len);
        // The step runs of every distinct path, root first. A path's run is
        // built from the run of its nearest ancestor the index already has
        // (copied from this buffer, not re-read), plus the nodes below it,
        // each read and charged ONCE per build: `x.a.f0 … x.a.f599` reads
        // `x.a` once, whatever the number of paths below it.
        var missing: std.ArrayList(PathId) = .empty;
        defer missing.deinit(gpa);
        var seen_atoms: Ids.FixedDict(1) = .{};
        defer seen_atoms.deinit(gpa);
        for (uses) |u| {
            const charge: Charge = .in(account, .{ .atom = u.atom, .role = .liveness_index, .phase = phase });
            try charge.reserve(gpa, .use, 1);
            // `Use.atom` is a use occurrence, unique in the declaration: a
            // repeat is Transfer's defect, caught here under runtime safety.
            if (std.debug.runtime_safety) std.debug.assert(!(try seen_atoms.getOrPut(gpa, .{u.atom})).found_existing);
            if (x.runs.contains(u.path)) continue;
            missing.clearRetainingCapacity();
            var at = u.path;
            while (at != .none and !x.runs.contains(at)) : (at = places.pathParent(at)) try missing.append(gpa, at);
            const start: u32 = @intCast(x.steps.items.len);
            if (at != .none) {
                const r = x.runs.get(at).?;
                var i: u32 = 0;
                while (i < r.len) : (i += 1) try x.steps.append(gpa, x.steps.items[r.start + i]);
            }
            var i = missing.items.len;
            while (i > 0) {
                i -= 1;
                const node = missing.items[i];
                if (places.pathParent(node) != .none) {
                    const node_lane: Charge = .in(account, .{ .atom = Ids.atom_path_bit | node.int(), .role = .liveness_index, .phase = phase });
                    try node_lane.reserve(gpa, .path, 1);
                    try x.steps.append(gpa, places.pathStep(node));
                }
                try x.runs.put(gpa, node, .{ .start = start, .len = @intCast(x.steps.items.len - start) });
            }
        }
        // Sorted by (local, path, point).
        const order = try gpa.alloc(u32, n);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const Ctx = struct { x: *const Index, places: *const Place.Table, uses: []const Use };
        std.mem.sort(u32, order, Ctx{ .x = &x, .places = places, .uses = uses }, struct {
            fn lessThan(c: Ctx, a: u32, b: u32) bool {
                const ua = c.uses[a];
                const ub = c.uses[b];
                if (ua.local != ub.local) return ua.local < ub.local;
                const o = c.x.comparePaths(c.places, ua.path, ub.path);
                if (o != .eq) return o == .lt;
                if (ua.point != ub.point) return ua.point < ub.point;
                return @backingInt(ua.kind) < @backingInt(ub.kind);
            }
        }.lessThan);
        var max_local: u32 = 0;
        for (uses) |u| max_local = @max(max_local, u.local + 1);
        try x.uses.ensureTotalCapacity(gpa, n);
        for (order) |i| x.uses.appendAssumeCapacity(uses[i]);
        x.by_local = try gpa.alloc(Ids.Range, max_local);
        @memset(x.by_local, .empty);
        x.last = try gpa.alloc(u32, max_local);
        @memset(x.last, none);
        const locals = x.uses.items(.local);
        const points = x.uses.items(.point);
        var i: u32 = 0;
        while (i < n) {
            var j = i;
            while (j < n and locals[j] == locals[i]) : (j += 1) {
                x.last[locals[i]] = if (x.last[locals[i]] == none) points[j] else @max(x.last[locals[i]], points[j]);
            }
            x.by_local[locals[i]] = .{ .start = i, .len = j - i };
            i = j;
        }
        // The merge-sort tree, bottom up: leaves are single uses, a node
        // the merge of its children, O(U log U), one record per entry.
        var size: u32 = 1;
        while (size < n) size *= 2;
        x.size = size;
        x.off = try gpa.alloc(u32, 2 * size + 1);
        @memset(x.off, 0);
        // Node k (1-based heap) covers [lo, hi): count first.
        var k: u32 = 1;
        while (k < 2 * size) : (k += 1) x.off[k + 1] = x.off[k] + x.spanLen(k, n);
        x.pairs = try gpa.alloc(Pair, x.off[2 * size]);
        // Leaves.
        var leaf: u32 = 0;
        while (leaf < n) : (leaf += 1) {
            const node = size + leaf;
            x.pairs[x.off[node]] = .{ .point = points[leaf], .use = leaf };
        }
        // Inner nodes: merge.
        var level_size = size / 2;
        var lo_node = size / 2;
        while (lo_node >= 1) {
            var nd = lo_node;
            while (nd < lo_node + level_size) : (nd += 1) {
                const a = x.pairs[x.off[2 * nd]..x.off[2 * nd + 1]];
                const b = x.pairs[x.off[2 * nd + 1]..x.off[2 * nd + 2]];
                var out = x.pairs[x.off[nd]..x.off[nd + 1]];
                var ia: usize = 0;
                var ib: usize = 0;
                var o: usize = 0;
                while (o < out.len) : (o += 1) {
                    const take_a = ib == b.len or (ia < a.len and a[ia].point <= b[ib].point);
                    out[o] = if (take_a) a[ia] else b[ib];
                    if (take_a) ia += 1 else ib += 1;
                    const charge: Charge = .in(account, .{ .atom = x.uses.items(.atom)[out[o].use], .role = .liveness_index, .phase = phase });
                    try charge.reserve(gpa, .use, 1);
                }
            }
            lo_node /= 2;
            level_size /= 2;
            if (lo_node == 0) break;
        }
        return x;
    }

    /// How many uses heap node `k` covers.
    fn spanLen(x: *const Index, k: u32, n: u32) u32 {
        var lo = k;
        var hi = k + 1;
        var level: u32 = 1;
        while (lo < x.size) {
            lo *= 2;
            hi *= 2;
            level *= 2;
        }
        const a = lo - x.size;
        const b = @min(hi - x.size, n);
        return if (b > a) b - a else 0;
    }

    /// Lexicographic order of two paths by their steps from the root; a
    /// prefix comes first. Only paths the index holds.
    fn comparePaths(x: *const Index, places: *const Place.Table, a: PathId, b: PathId) std.math.Order {
        if (a == b) return .eq;
        const ra = x.runs.get(a) orelse unreachable;
        const rb = x.runs.get(b) orelse unreachable;
        const sa = x.steps.items[ra.start..][0..ra.len];
        const sb = x.steps.items[rb.start..][0..rb.len];
        const m = @min(sa.len, sb.len);
        for (sa[0..m], sb[0..m]) |p, q| {
            if (p.word() == q.word()) continue;
            return if (places.stepLess(p, q)) .lt else .gt;
        }
        return std.math.order(sa.len, sb.len);
    }

    /// `q` against a use's path: `lt`/`gt` by the lexicographic order,
    /// `eq` when equal, with `prefix` set when the use's path is below `q`.
    /// `q` need not be in the index: its steps are read from `places`.
    const Cmp = struct { order: std.math.Order, prefix: bool };

    fn compareQuery(x: *const Index, places: *const Place.Table, q_steps: []const Place.Step, use_path: PathId) Cmp {
        const r = x.runs.get(use_path) orelse unreachable;
        const s = x.steps.items[r.start..][0..r.len];
        const m = @min(s.len, q_steps.len);
        for (q_steps[0..m], s[0..m]) |p, u| {
            if (p.word() == u.word()) continue;
            return .{ .order = if (places.stepLess(p, u)) .lt else .gt, .prefix = false };
        }
        if (q_steps.len == s.len) return .{ .order = .eq, .prefix = true };
        // `q` shorter: the use is below `q`; `q` longer: the use is above.
        return if (q_steps.len < s.len) .{ .order = .lt, .prefix = true } else .{ .order = .gt, .prefix = false };
    }

    // ---- queries ---------------------------------------------------------------

    /// The steps of `q` from the root, in a caller's buffer; each node read
    /// is one record on `charge` before it is read.
    fn stepsOf(gpa: Allocator, charge: Charge, places: *const Place.Table, q: PathId, out: *std.ArrayList(Place.Step)) Error!void {
        out.clearRetainingCapacity();
        var at = q;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) {
            try charge.reserve(gpa, .path, 1);
            try out.append(gpa, places.pathStep(at));
        }
        std.mem.reverse(Place.Step, out.items);
    }

    /// The index range of local `h`'s uses whose path is `q` itself
    /// (`exact`) or `q` and everything below it (`subtree`): two binary
    /// searches over the local's run, O(log U · depth) fixed-word steps.
    fn range(x: *const Index, places: *const Place.Table, h: u32, q_steps: []const Place.Step, subtree: bool) Ids.Range {
        if (h >= x.by_local.len) return .empty;
        const run = x.by_local[h];
        const paths = x.uses.items(.path);
        // lo: the first use whose path is not below `q` in the order.
        var lo = run.start;
        var hi = run.start + run.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = x.compareQuery(places, q_steps, paths[mid]);
            if (c.order == .gt) lo = mid + 1 else hi = mid;
        }
        const first = lo;
        // hi: the first use past `q` (and its subtree when asked).
        lo = first;
        hi = run.start + run.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = x.compareQuery(places, q_steps, paths[mid]);
            const inside = c.order == .eq or (subtree and c.prefix);
            if (inside) lo = mid + 1 else hi = mid;
        }
        return .{ .start = first, .len = lo - first };
    }

    /// The first `(point, use)` of index range `r` at or past `(from_point,
    /// from_use)` in that order, by the merge-sort tree: O(log² U) steps,
    /// one record per tree node read. Pairs of a node are sorted by
    /// `(point, use)` (the merge is stable over use order).
    fn firstAtLeast(x: *const Index, gpa: Allocator, charge: Charge, r: Ids.Range, from_point: u32, from_use: u32) Error!?Pair {
        if (r.len == 0) return null;
        var best: ?Pair = null;
        var lo = r.start + x.size;
        var hi = r.start + r.len + x.size; // exclusive
        while (lo < hi) {
            if (lo & 1 == 1) {
                try charge.reserve(gpa, .inspection, 1);
                if (x.lowerBound(lo, from_point, from_use)) |p| if (best == null or pairLess(p, best.?)) {
                    best = p;
                };
                lo += 1;
            }
            if (hi & 1 == 1) {
                hi -= 1;
                try charge.reserve(gpa, .inspection, 1);
                if (x.lowerBound(hi, from_point, from_use)) |p| if (best == null or pairLess(p, best.?)) {
                    best = p;
                };
            }
            lo /= 2;
            hi /= 2;
        }
        return best;
    }

    fn pairLess(a: Pair, b: Pair) bool {
        return a.point < b.point or (a.point == b.point and a.use < b.use);
    }

    /// The first pair of node `k` at or past `(from_point, from_use)`.
    fn lowerBound(x: *const Index, k: u32, from_point: u32, from_use: u32) ?Pair {
        const ps = x.pairs[x.off[k]..x.off[k + 1]];
        const from: Pair = .{ .point = from_point, .use = from_use };
        var lo: usize = 0;
        var hi: usize = ps.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (pairLess(ps[mid], from)) lo = mid + 1 else hi = mid;
        }
        return if (lo < ps.len) ps[lo] else null;
    }

    /// The earliest use in index range `r` with a point in one of
    /// `intervals` (ascending, disjoint) the filter accepts; every candidate
    /// visited is one record.
    fn earliest(x: *const Index, gpa: Allocator, charge: Charge, r: Ids.Range, intervals: []const Regions.Tree.Range, filter: Filter) Error!?UseId {
        for (intervals) |iv| {
            var from: Pair = .{ .point = iv.start, .use = 0 };
            while (true) {
                const p = (try x.firstAtLeast(gpa, charge, r, from.point, from.use)) orelse break;
                if (p.point > iv.end) break;
                try charge.reserve(gpa, .inspection, 1);
                if (try filter.accept(filter.ctx, x.uses.get(p.use), .from(p.use))) return .from(p.use);
                if (p.use == std.math.maxInt(u32)) break;
                from = .{ .point = p.point, .use = p.use + 1 };
            }
        }
        return null;
    }
    /// §2.7's first query: a use of `h` at `q` or an ancestor of `q`, after
    /// `p` and compatible with it, the earliest the filter accepts (the
    /// filter sees each candidate's own path, so a `call` use is judged at
    /// the remainder of `q` below it). O(depth · log² U) steps plus the
    /// candidates visited, each a record on `charge`.
    pub fn useAfter(x: *const Index, gpa: Allocator, charge: Charge, places: *const Place.Table, regions: *const Regions.Tree, h: u32, q: PathId, p: u32, filter: Filter) Error!?UseId {
        var intervals: std.ArrayList(Regions.Tree.Range) = .empty;
        defer intervals.deinit(gpa);
        try regions.rangesAfterCharged(gpa, charge, p, &intervals);
        var steps: std.ArrayList(Place.Step) = .empty;
        defer steps.deinit(gpa);
        try stepsOf(gpa, charge, places, q, &steps);
        var best: ?UseId = null;
        var depth = steps.items.len + 1;
        while (depth > 0) : (depth -= 1) {
            try charge.reserve(gpa, .inspection, 1);
            const r = x.range(places, h, steps.items[0 .. depth - 1], false);
            if (try x.earliest(gpa, charge, r, intervals.items, filter)) |u| {
                if (best == null or x.uses.items(.point)[u.int()] < x.uses.items(.point)[best.?.int()]) best = u;
            }
        }
        return best;
    }

    /// §2.7's subtree queries: a use of `h` at `q` or below it, after `p`,
    /// compatible, the earliest the filter accepts. The caller passes `q.f`
    /// for a record demand's written field and `q` for a list demand.
    pub fn useUnder(x: *const Index, gpa: Allocator, charge: Charge, places: *const Place.Table, regions: *const Regions.Tree, h: u32, q: PathId, p: u32, filter: Filter) Error!?UseId {
        var intervals: std.ArrayList(Regions.Tree.Range) = .empty;
        defer intervals.deinit(gpa);
        try regions.rangesAfterCharged(gpa, charge, p, &intervals);
        var steps: std.ArrayList(Place.Step) = .empty;
        defer steps.deinit(gpa);
        try stepsOf(gpa, charge, places, q, &steps);
        try charge.reserve(gpa, .inspection, 1);
        const r = x.range(places, h, steps.items, true);
        return x.earliest(gpa, charge, r, intervals.items, filter);
    }
};

/// Binary lifting over a region tree: `compatible` for one pair of points
/// in O(log depth) fixed-word steps and no allocation (§4.1's ancestry
/// query). Built once per frame, `levels · regions` words.
pub const Ancestry = struct {
    up: []RegionId = &.{},
    depth: []u32 = &.{},
    levels: u32 = 0,

    pub fn deinit(a: *Ancestry, gpa: Allocator) void {
        gpa.free(a.up);
        gpa.free(a.depth);
    }

    /// `levels = ⌈log₂(max depth + 2)⌉` slots per region, each one record
    /// in the region's source-settlement lane (§4.1: "precompute 32
    /// binary-lifting ancestor slots per region … charging them to its
    /// source settlement lane"), keyed by the region id, unique in the
    /// declaration whose tree this is, and `phase`.
    pub fn build(gpa: Allocator, account: *Ids.Account, phase: Ids.Phase, regions: *const Regions.Tree) Error!Ancestry {
        const n = regions.count();
        var a: Ancestry = .{};
        errdefer a.deinit(gpa);
        a.depth = try gpa.alloc(u32, n);
        var max_depth: u32 = 0;
        for (0..n) |i| {
            a.depth[i] = regions.get(.from(@intCast(i))).depth;
            max_depth = @max(max_depth, a.depth[i]);
        }
        a.levels = std.math.log2_int_ceil(u32, max_depth + 2);
        a.up = try gpa.alloc(RegionId, n * a.levels);
        for (0..n) |i| {
            const charge: Charge = .in(account, .{ .atom = @intCast(i), .role = .transfer_settlement, .phase = phase });
            try charge.reserve(gpa, .region, a.levels);
            a.up[i * a.levels] = regions.get(.from(@intCast(i))).parent;
        }
        var k: u32 = 1;
        while (k < a.levels) : (k += 1) {
            for (0..n) |i| {
                const mid = a.up[i * a.levels + k - 1];
                a.up[i * a.levels + k] = if (mid == .none) .none else a.up[mid.int() * a.levels + k - 1];
            }
        }
        return a;
    }

    fn lift(a: *const Ancestry, r: RegionId, by: u32) RegionId {
        var at = r;
        var rest = by;
        var k: u32 = 0;
        while (rest > 0 and at != .none) : (k += 1) {
            if (rest & 1 == 1) at = a.up[at.int() * a.levels + k];
            rest >>= 1;
        }
        return at;
    }

    /// The children of the LCA on the way to `ra` and `rb` (`.none` when
    /// one is the ancestor of the other), §2.5's test: incompatible exactly
    /// when both are arms of one case and differ.
    pub fn compatible(a: *const Ancestry, regions: *const Regions.Tree, ra: RegionId, rb: RegionId) bool {
        var x = ra;
        var y = rb;
        if (a.depth[x.int()] > a.depth[y.int()]) {
            x = a.lift(x, a.depth[x.int()] - a.depth[y.int()] - 1);
            if (a.up[x.int() * a.levels] == y) return true;
            x = a.up[x.int() * a.levels];
        } else if (a.depth[y.int()] > a.depth[x.int()]) {
            y = a.lift(y, a.depth[y.int()] - a.depth[x.int()] - 1);
            if (a.up[y.int() * a.levels] == x) return true;
            y = a.up[y.int() * a.levels];
        }
        if (x == y) return true;
        // Same depth, distinct: lift both while their ancestors differ.
        var k = a.levels;
        while (k > 0) {
            k -= 1;
            const ux = a.up[x.int() * a.levels + k];
            const uy = a.up[y.int() * a.levels + k];
            if (ux != uy) {
                x = ux;
                y = uy;
            }
        }
        // `x` and `y` are the children below the LCA.
        const kx = regions.get(x).kind;
        const ky = regions.get(y).kind;
        if (!(kx == .arm or kx == .virtual_arm) or !(ky == .arm or ky == .virtual_arm)) return true;
        const rx = regions.get(x);
        const ry = regions.get(y);
        return !(rx.case_inst == ry.case_inst and rx.arm != ry.arm);
    }

    pub fn compatiblePoints(a: *const Ancestry, regions: *const Regions.Tree, p: u32, q: u32) bool {
        return a.compatible(regions, regions.regionOf(p), regions.regionOf(q));
    }
};

comptime {
    Ids.assertRecord(Use);
    Ids.assertRecord(Index.Pair);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Prepass = @import("Prepass.zig");

/// A test type graph: 0 a record `{ a : List Int, b : List Int }`, 1 `List
/// Int`, 2 `Int`.
const TestGraph = struct {
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            0 => {
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 10) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 11) catch unreachable), .@"var" = 1 });
                return .{ .kind = .record };
            },
            1 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 2 });
                return .{ .kind = .list, .head = 200 };
            },
            2 => return .{ .kind = .cross },
            // 100…699: a chain of 600 one-field tuples ending in a list, a
            // 600-step canonical path (every tuple its own place).
            100...699 => {
                try out.append(g.gpa, .{ .step = (Place.Step.index(g.account, 0) catch unreachable), .@"var" = v + 1 });
                return .{ .kind = .tuple, .head = 1 };
            },
            700 => {
                try out.append(g.gpa, .{ .step = Place.Step.elem, .@"var" = 2 });
                return .{ .kind = .list, .head = 200 };
            },
            // 900: `{ a : W }`, 901: `W`, a record of 600 list fields.
            900 => {
                try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 10) catch unreachable), .@"var" = 901 });
                return .{ .kind = .record };
            },
            901 => {
                var k: u32 = 0;
                while (k < 600) : (k += 1) try out.append(g.gpa, .{ .step = (Place.Step.field(g.account, 1000 + k) catch unreachable), .@"var" = 1 });
                return .{ .kind = .record };
            },
            else => unreachable,
        }
    }
};

/// A region tree with no arms: every pair of points compatible.
fn flatRegions(gpa: Allocator, n: u32) !Regions.Tree {
    var t: Regions.Tree = .{};
    try t.regions.append(gpa, .{ .kind = .body, .start = 0, .end = n - 1, .parent = .none, .depth = 0, .case_inst = none, .arm = 0, .guard = none });
    t.of = try gpa.alloc(RegionId, n);
    @memset(t.of, .from(0));
    return t;
}

const Fixture = struct {
    places: Place.Table = .{},
    account: Ids.Account = .{},
    graph: TestGraph = undefined,

    fn init(f: *Fixture) void {
        f.graph = .{ .account = &f.account, .gpa = testing.allocator };
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
    }

    fn path(f: *Fixture, root: u32, steps: []const Place.Step) !PathId {
        const p = try f.places.of(testing.allocator, &f.account, .{ .ctx = &f.graph, .describe = TestGraph.describe }, root);
        var at = try f.places.rootPath(testing.allocator, p);
        for (steps) |s| at = (try f.places.extend(testing.allocator, .growth(&f.account), at, s)).?;
        return at;
    }
};

fn use(local: u32, path: PathId, point: u32, kind: Facts.UseKind) Use {
    // The atom is the operand occurrence; in these frames one per point.
    return .{ .local = local, .path = path, .point = point, .kind = kind, .region = .from(0), .use_node = .none, .atom = 1000 + point };
}

test "lanes are keyed by the use's source atom and the phase: frames and phases never meet" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const r = try f.path(0, &.{});
    const ra = try f.path(0, &.{fa});
    // Frame A: 8 uses whose input order is the reverse of their sorted
    // order, so the sorted position differs from the input position.
    var a: std.ArrayList(Use) = .empty;
    defer a.deinit(gpa);
    var i: u32 = 8;
    while (i > 0) : (i -= 1) try a.append(gpa, use(1, if (i % 2 == 0) ra else r, i, .whole));
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var xa = try Index.build(gpa, &account, .inference, &f.places, a.items);
    defer xa.deinit(gpa);
    // Every use's records are in ITS lane: one plus the three inner tree
    // levels of 8 leaves; the path nodes in their own lanes, one each.
    for (a.items) |u| try testing.expectEqual(@as(u32, 4), account.laneUsed(.{ .atom = u.atom, .role = .liveness_index }));
    try testing.expectEqual(@as(u32, 1), account.laneUsed(.{ .atom = Ids.atom_path_bit | ra.int(), .role = .liveness_index }));
    // Frame B of the same declaration (other operands) and the validation
    // phase over frame A's uses again: no lane collides, no invariant.
    var b: std.ArrayList(Use) = .empty;
    defer b.deinit(gpa);
    i = 0;
    while (i < 8) : (i += 1) try b.append(gpa, use(2, r, 100 + i, .whole));
    var xb = try Index.build(gpa, &account, .inference, &f.places, b.items);
    defer xb.deinit(gpa);
    var xv = try Index.build(gpa, &account, .validation, &f.places, a.items);
    defer xv.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), account.laneUsed(.{ .atom = a.items[0].atom, .role = .liveness_index }));
    try testing.expectEqual(@as(u32, 4), account.laneUsed(.{ .atom = a.items[0].atom, .role = .liveness_index, .phase = .validation }));
    try testing.expectEqual(@as(u32, 0), account.growth);
    try testing.expect(account.failed == null);
    // The same frame built twice in one phase IS the implementation defect
    // the invariant exists for: it is reported as such, never as growth.
    var again: Ids.Account = .{};
    defer again.deinit(gpa);
    var k: u32 = 0;
    var hit = false;
    while (k < 200) : (k += 1) {
        var x = Index.build(gpa, &again, .inference, &f.places, a.items) catch |e| {
            try testing.expectEqual(error.AccountingInvariant, e);
            hit = true;
            break;
        };
        x.deinit(gpa);
    }
    try testing.expect(hit and again.failed.? == .invariant);
}

test "a 600-step path charges each of its nodes once in that node's lane" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    var steps: std.ArrayList(Place.Step) = .empty;
    defer steps.deinit(gpa);
    var k: u32 = 0;
    while (k < 600) : (k += 1) try steps.append(gpa, try Place.Step.index(&f.account, 0));
    // Building the 600-step path itself reads every ancestor per extension
    // (`Place.extend`): the fixture's account pays for the setup.
    f.account.allowance = 1 << 22;
    const deep = try f.path(100, steps.items);
    try testing.expectEqual(@as(u32, 600), f.places.pathDepth(deep));
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    const one = [_]Use{use(1, deep, 5, .whole)};
    var x = try Index.build(gpa, &account, .inference, &f.places, &one);
    defer x.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), account.laneUsed(.{ .atom = one[0].atom, .role = .liveness_index }));
    try testing.expectEqual(@as(u32, 1), account.laneUsed(.{ .atom = Ids.atom_path_bit | deep.int(), .role = .liveness_index }));
    try testing.expectEqual(@as(u64, 601), account.baseline);
    try testing.expectEqual(@as(u32, 0), account.growth);
}

test "the index answers §2.7's four queries by path: ancestors, a written field's subtree, a list's subtree, untouched fields" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const fb = try Place.Step.field(&f.account, 11);
    const r = try f.path(0, &.{});
    const ra = try f.path(0, &.{fa});
    const rb = try f.path(0, &.{fb});
    const ra_e = try f.path(0, &.{ fa, Place.Step.elem });
    const rb_e = try f.path(0, &.{ fb, Place.Step.elem });
    // Local 1 (`r`): read `r.b` at 3 (field), `r.a[*]` at 5 (field), handed
    // to a callee at 8 (call), whole at 12. Local 2: used at 4.
    const uses = [_]Use{
        use(1, rb, 3, .field),
        use(1, ra_e, 5, .field),
        use(1, r, 8, .call),
        use(1, r, 12, .whole),
        use(2, r, 4, .whole),
        use(1, rb_e, 2, .field),
    };
    var regions = try flatRegions(gpa, 20);
    defer regions.deinit(gpa);
    var x = try Index.build(gpa, &f.account, .inference, &f.places, &uses);
    defer x.deinit(gpa);
    try testing.expectEqual(@as(u32, 6), x.count());
    try testing.expectEqual(@as(u32, 12), x.lastUse(1));
    try testing.expectEqual(@as(u32, 4), x.lastUse(2));
    try testing.expectEqual(none, x.lastUse(7));
    const charge: Charge = .growth(&f.account);
    // Query 1: a demand on `r.a` at point 4: the ancestor-or-self uses
    // after 4 are `r` at 8 (call) and 12 (whole); the earliest is 8.
    const q1 = (try x.useAfter(gpa, charge, &f.places, &regions, 1, ra, 4, .all)).?;
    try testing.expectEqual(@as(u32, 8), x.get(q1).point);
    try testing.expectEqual(Facts.UseKind.call, x.get(q1).kind);
    const Reject = struct {
        fn accept(_: *anyopaque, u: Use, _: UseId) Error!bool {
            return u.kind != .call;
        }
    };
    var dummy: u8 = 0;
    const q1b = (try x.useAfter(gpa, charge, &f.places, &regions, 1, ra, 4, .{ .ctx = &dummy, .accept = Reject.accept })).?;
    try testing.expectEqual(@as(u32, 12), x.get(q1b).point);
    try testing.expectEqual(@as(?UseId, null), try x.useAfter(gpa, charge, &f.places, &regions, 1, ra, 12, .all));
    try testing.expectEqual(@as(?UseId, null), try x.useAfter(gpa, charge, &f.places, &regions, 3, ra, 0, .all));
    // Query 2: a record demand writing field `a` at 4: uses under `r.a`
    // after 4 — `r.a[*]` at 5, kind field: a hoist.
    const q2 = (try x.useUnder(gpa, charge, &f.places, &regions, 1, ra, 4, .all)).?;
    try testing.expectEqual(@as(u32, 5), x.get(q2).point);
    try testing.expectEqual(Facts.UseKind.field, x.get(q2).kind);
    // Query 4: the untouched field `b` after 4 has no use; before 4 it had.
    try testing.expectEqual(@as(?UseId, null), try x.useUnder(gpa, charge, &f.places, &regions, 1, rb, 4, .all));
    try testing.expectEqual(@as(u32, 2), x.get((try x.useUnder(gpa, charge, &f.places, &regions, 1, rb, 0, .all)).?).point);
    // Query 3: a list demand on `r` at 6: everything under `r` after 6.
    const q3 = (try x.useUnder(gpa, charge, &f.places, &regions, 1, r, 6, .all)).?;
    try testing.expectEqual(@as(u32, 8), x.get(q3).point);
    // A query charges its region climb and path walk before any work: with
    // nothing to spend it is refused at once, and a paid query's cost
    // covers the path's steps and the regions climbed.
    var broke: Ids.Account = .{ .allowance = 0 };
    defer broke.deinit(gpa);
    try testing.expectError(error.OwnershipLimit, x.useAfter(gpa, .growth(&broke), &f.places, &regions, 1, ra_e, 4, .all));
    const before = f.account.growth;
    _ = try x.useUnder(gpa, charge, &f.places, &regions, 1, ra_e, 4, .all);
    try testing.expect(f.account.growth - before >= 2 + 1);
}

test "queries cost O(log² U) tree reads and the index O(U log U): U = 256, 1024, 4096" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const r = try f.path(0, &.{});
    const ra = try f.path(0, &.{fa});
    var last_build: u64 = 0;
    var last_query: u64 = 0;
    for ([_]u32{ 256, 1024, 4096 }) |n| {
        var uses: std.ArrayList(Use) = .empty;
        defer uses.deinit(gpa);
        var i: u32 = 0;
        while (i < n) : (i += 1) try uses.append(gpa, use(1, if (i % 3 == 0) ra else r, (i *% 2654435761) % (4 * n), .whole));
        // Distinct atoms: the point may repeat.
        for (uses.items, 0..) |*u, k| u.atom = @intCast(k);
        var regions = try flatRegions(gpa, 4 * n);
        defer regions.deinit(gpa);
        var account: Ids.Account = .{};
        defer account.deinit(gpa);
        var x = try Index.build(gpa, &account, .inference, &f.places, uses.items);
        defer x.deinit(gpa);
        const build_cost = account.total();
        try testing.expectEqual(@as(u32, 0), account.growth);
        if (last_build > 0) try testing.expect(build_cost < last_build * 5);
        last_build = build_cost;
        const before = account.growth;
        _ = try x.useAfter(gpa, .growth(&account), &f.places, &regions, 1, ra, 2 * n, .all);
        const query_cost = account.growth - before;
        const lg: u64 = @as(u64, std.math.log2_int(u32, n)) + 1;
        try testing.expect(query_cost <= 8 * lg * lg);
        if (last_query > 0) try testing.expect(query_cost < last_query * 2);
        last_query = query_cost;
    }
}

test "ancestry: binary lifting agrees with the region tree's climb on a lowered module, in the region's lane" {
    const gpa = testing.allocator;
    const text =
        \\module Main exposing (g)
        \\
        \\g : Int, List Int → Int
        \\g n xs =
        \\    case n of
        \\        0 →
        \\            case xs of
        \\                [] → 1
        \\                [ x, …rest ] → x + List.length rest
        \\        _ →
        \\            let
        \\                k = n * 2
        \\            in
        \\            case k of
        \\                4 → k
        \\                _ → n
        \\
    ;
    var lowered = try Prepass.lowerSource(text);
    defer lowered.deinit();
    const bir = &lowered.bir;
    const d = bir.decls[lowered.declNamed("g")];
    var tree = try Regions.build(gpa, bir, d, null);
    defer tree.deinit(gpa);
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var anc = try Ancestry.build(gpa, &account, .inference, &tree);
    defer anc.deinit(gpa);
    try testing.expect(tree.count() >= 5);
    try testing.expectEqual(anc.levels, account.laneUsed(.{ .atom = 0, .role = .transfer_settlement }));
    try testing.expectEqual(@as(u32, 0), account.laneUsed(.{ .atom = 0, .role = .direct_demand_query }));
    var p = d.inst_start.int();
    while (p < d.inst_end.int()) : (p += 1) {
        var q = d.inst_start.int();
        while (q < d.inst_end.int()) : (q += 1) {
            try testing.expectEqual(tree.compatible(p, q), anc.compatiblePoints(&tree, p, q));
        }
    }
}

test "fault injection: a refused build or query leaves no index and no state behind" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const r = try f.path(0, &.{});
    const ra = try f.path(0, &.{fa});
    const uses = [_]Use{ use(1, ra, 3, .field), use(1, r, 8, .whole), use(2, r, 4, .whole) };
    var regions = try flatRegions(gpa, 20);
    defer regions.deinit(gpa);
    // A lane already at its ceiling: the build is the invariant, never growth,
    // and nothing of the index survives (`errdefer`).
    var full: Ids.Account = .{};
    defer full.deinit(gpa);
    try full.reserveLane(gpa, .{ .atom = uses[0].atom, .role = .liveness_index }, .use, 512);
    try testing.expectError(error.AccountingInvariant, Index.build(gpa, &full, .inference, &f.places, &uses));
    try testing.expectEqual(@as(u32, 0), full.growth);
    // A query with nothing to spend is refused before its first read, at any
    // allowance below its cost, and the index is unchanged by any of them.
    var x = try Index.build(gpa, &f.account, .inference, &f.places, &uses);
    defer x.deinit(gpa);
    var allowance: u32 = 0;
    while (allowance < 200) : (allowance += 1) {
        var broke: Ids.Account = .{ .allowance = allowance };
        defer broke.deinit(gpa);
        if (x.useAfter(gpa, .growth(&broke), &f.places, &regions, 1, ra, 2, .all)) |got| {
            try testing.expectEqual(@as(u32, 3), x.get(got.?).point);
            break;
        } else |err| try testing.expectEqual(error.OwnershipLimit, err);
        try testing.expectEqual(@as(u32, 3), x.count());
    }
    try testing.expect(allowance > 0 and allowance < 200);
}

test "a path node is read and charged once per build, whatever the number of paths below it" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const gpa = testing.allocator;
    const fa = try Place.Step.field(&f.account, 10);
    const xa = try f.path(900, &.{fa});
    // `x.a.f0 … x.a.f599`: 600 distinct use paths under `x.a`.
    var uses: std.ArrayList(Use) = .empty;
    defer uses.deinit(gpa);
    var k: u32 = 0;
    while (k < 600) : (k += 1) {
        const p = try f.path(900, &.{ fa, try Place.Step.field(&f.account, 1000 + k) });
        try uses.append(gpa, .{ .local = 1, .path = p, .point = 5, .kind = .field, .region = .from(0), .use_node = .none, .atom = 7000 + k });
    }
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var x = try Index.build(gpa, &account, .inference, &f.places, uses.items);
    defer x.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), account.laneUsed(.{ .atom = Ids.atom_path_bit | xa.int(), .role = .liveness_index }));
    try testing.expectEqual(@as(u32, 1), account.laneUsed(.{ .atom = Ids.atom_path_bit | uses.items[7].path.int(), .role = .liveness_index }));
    try testing.expectEqual(@as(u32, 0), account.growth);
    // 600 uses + 600 leaf nodes + `x.a` once + the tree levels (10 inner
    // levels of 1024 leaves, per use).
    try testing.expectEqual(@as(u64, 600 + 600 + 1 + 600 * 10), account.baseline);
    // One operand making many uses (a record update reading `r` at every
    // untouched field): each use its own atom, no lane past its ceiling.
    var many: std.ArrayList(Use) = .empty;
    defer many.deinit(gpa);
    k = 0;
    while (k < 80) : (k += 1) try many.append(gpa, .{ .local = 2, .path = uses.items[k].path, .point = 9, .kind = .field, .region = .from(0), .use_node = .none, .atom = (9 << 10) | k });
    var account2: Ids.Account = .{};
    defer account2.deinit(gpa);
    var y = try Index.build(gpa, &account2, .inference, &f.places, many.items);
    defer y.deinit(gpa);
    try testing.expect(account2.failed == null);
}
