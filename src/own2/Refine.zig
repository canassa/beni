//! L10: canonical ranks and partition refinement for `Block`
//! (`docs/design/ownership-v2.md` §3.6), each step reserved before it is
//! done (§4.1, §4.4).
//!
//! **A record** is one task of O(1) words: a comparison, a dictionary
//! probe, a member's step, or a chunk of 16 words read or written.
//!
//! `rank` numbers variable-length keys exactly: an exact dictionary makes
//! equal words one rank (its hash only finds candidates), and the distinct
//! keys are ranked in (hash, length, words) order by a merge sort, a hash
//! tie ordered by the words — so the ranks are a function of the keys and
//! no collision merges two of them or orders a tie. O(words + d log d).
//!
//! `blocks` is Hopcroft's algorithm on an unlabelled graph whose edges are
//! counted, as for lumping (Valmari and Franceschinis): a label is the
//! caller's, a port state per labelled part, so a predecessor's signature
//! against a splitter is one word, its count. The touched predecessors are
//! grouped by block and by count through lists threaded through per-state
//! and per-count arrays, never a comparison sort of a splitter's edges.
//! Every choice depends on block numbers and counts only, never on an
//! element's index: the blocks that split are taken in number order (a sort
//! of at most one per new block), a block's untouched members keep its
//! number and its touched ones follow in count order (a sort of at most two
//! per new block), new numbers are given in that order, and every part is
//! queued if the block was, else all but the largest (the first of equal
//! sizes). So the numbers are a function of the structure. A state is in a
//! processed splitter O(log n) times and each of its edges is read then,
//! so with the two sorts the refinement is O((n + E) log n).
//!
//! **Reservations.** `Meter.pay` reserves before the work it stands for —
//! a splitter's member before its predecessors are read, each grouping
//! before it is made, each sort before it runs — and `spend` counts the
//! work done, which may never pass what was paid.
//!
//! Obligations kept here: none.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const Error = Ids.ChargeError;
const none: u32 = std.math.maxInt(u32);

/// A charge with a ledger: records reserved (`paid`) and records of work
/// done (`work`); work past what was reserved is a defect.
pub const Meter = struct {
    gpa: Allocator,
    charge: Ids.Charge,
    paid: u64 = 0,
    work: u64 = 0,

    /// Reserve `n` records before the work they stand for.
    pub fn pay(m: *Meter, n: u64) Error!void {
        if (n == 0) return;
        try m.charge.reserve(m.gpa, .inspection, std.math.cast(u32, n) orelse std.math.maxInt(u32));
        m.paid += n;
    }

    /// Count `n` records of the work reserved.
    pub fn spend(m: *Meter, n: u64) void {
        m.work += n;
        if (std.debug.runtime_safety and m.work > m.paid) @panic("own2: work done before it was reserved");
    }

    /// Reserve `n` and do it at once.
    pub fn take(m: *Meter, n: u64) Error!void {
        try m.pay(n);
        m.spend(n);
    }
};

/// What a sort of `n` fixed-word items is charged: n·⌈log₂ n⌉, nothing
/// for one.
pub fn sortCost(n: usize) u64 {
    return if (n < 2) 0 else @as(u64, n) * std.math.log2_int_ceil(usize, n);
}

pub const Ranks = struct { ranks: []u32, count: u32 };

/// What reading, writing or comparing `n` words is charged.
pub fn wordsCost(n: usize) u64 {
    return 1 + n / 16;
}

/// A key's hash: the order's first word, never its equality.
fn keyHash(words: []const u32) u64 {
    if (comptime std.mem.littleToNative(u32, 1) == 1) return std.hash.Wyhash.hash(0x6f776e32, std.mem.sliceAsBytes(words));
    var h = std.hash.Wyhash.init(0x6f776e32);
    for (words) |x| h.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, x)));
    return h.final();
}

const Keys = struct {
    words: []const u32,
    starts: []const u32,
    hashes: []const u64,
    tie: bool,

    fn of(k: Keys, i: u32) []const u32 {
        return k.words[k.starts[i]..k.starts[i + 1]];
    }

    pub fn eql(k: Keys, a: u32, b: u32) bool {
        return std.mem.eql(u32, k.of(a), k.of(b));
    }

    pub fn hash(k: Keys, i: u32) u64 {
        return if (k.tie) 0 else k.hashes[i];
    }

    /// (hash, length, words): a hash orders, its ties are the words'.
    fn order(k: Keys, m: *Meter, a: u32, b: u32) Error!std.math.Order {
        const ha = k.hash(a);
        const hb = k.hash(b);
        if (ha != hb) return std.math.order(ha, hb);
        const p = k.of(a);
        const q = k.of(b);
        if (p.len != q.len) return std.math.order(p.len, q.len);
        try m.take(wordsCost(p.len));
        return std.mem.order(u32, p, q);
    }
};

/// The keys `words[starts[i]..starts[i + 1]]`, ranked: equal words one rank
/// (an exact dictionary, whose hash only finds candidates), the ranks in
/// (hash, length, words) order by a merge sort, a comparison one record
/// and a hash tie's words more. `tie` makes every hash 0 (a test's).
pub fn rank(m: *Meter, words: []const u32, starts: []const u32, tie: bool) Error!Ranks {
    const gpa = m.gpa;
    const n = starts.len - 1;
    // Hashing, then interning (a candidate's words compared): each key
    // read twice.
    var cost: u64 = 1;
    for (0..n) |i| cost += 2 * wordsCost(starts[i + 1] - starts[i]);
    try m.pay(cost);
    const hashes = try gpa.alloc(u64, n);
    defer gpa.free(hashes);
    for (hashes, 0..) |*h, i| {
        m.spend(wordsCost(starts[i + 1] - starts[i]));
        h.* = keyHash(words[starts[i]..starts[i + 1]]);
    }
    const k: Keys = .{ .words = words, .starts = starts, .hashes = hashes, .tie = tie };
    // An index stands for its key's words: hashed and compared by them.
    var dict: std.HashMapUnmanaged(u32, u32, Keys, std.hash_map.default_max_load_percentage) = .empty;
    defer dict.deinit(gpa);
    const id = try gpa.alloc(u32, n);
    defer gpa.free(id);
    var reps: std.ArrayList(u32) = .empty;
    defer reps.deinit(gpa);
    for (0..n) |i| {
        m.spend(wordsCost(starts[i + 1] - starts[i]));
        const got = try dict.getOrPutContext(gpa, @intCast(i), k);
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(reps.items.len);
            try reps.append(gpa, @intCast(i));
        }
        id[i] = got.value_ptr.*;
    }
    // The distinct keys in order: a bottom-up merge sort.
    const d = reps.items.len;
    try m.pay(1 + sortCost(d) + d);
    var a = try gpa.dupe(u32, reps.items);
    defer gpa.free(a);
    var b = try gpa.alloc(u32, d);
    defer gpa.free(b);
    var width: usize = 1;
    while (width < d) : (width *= 2) {
        var lo: usize = 0;
        while (lo < d) : (lo += 2 * width) {
            const mid = @min(lo + width, d);
            const hi = @min(lo + 2 * width, d);
            var i = lo;
            var j = mid;
            var o = lo;
            while (o < hi) : (o += 1) {
                m.spend(1);
                const left = j == hi or (i < mid and try k.order(m, a[i], a[j]) != .gt);
                b[o] = if (left) a[i] else a[j];
                if (left) i += 1 else j += 1;
            }
        }
        std.mem.swap([]u32, &a, &b);
    }
    // `a` holds key indices; their distinct ids' ranks.
    const of_id = try gpa.alloc(u32, d);
    defer gpa.free(of_id);
    for (a, 0..) |x, r| {
        m.spend(1);
        of_id[id[x]] = @intCast(r);
    }
    try m.take(wordsCost(n));
    const ranks = try gpa.alloc(u32, n);
    for (ranks, id) |*r, x| r.* = of_id[x];
    return .{ .ranks = ranks, .count = @intCast(d) };
}

/// The coarsest partition of `initial.len` states that refines `initial`
/// (canonical block numbers below `count`) and is stable under `edges`
/// `(target, predecessor)`, counted: each state's block number, canonical.
pub fn blocks(m: *Meter, initial: []const u32, count: u32, edges: []const [2]u32) Error![]u32 {
    const gpa = m.gpa;
    const n = initial.len;
    try m.pay(1 + n + edges.len + count);
    m.spend(1 + n + edges.len + count);
    // The predecessors by target, and the largest count one can have.
    const pred_start = try gpa.alloc(u32, n + 1);
    defer gpa.free(pred_start);
    @memset(pred_start, 0);
    const out_deg = try gpa.alloc(u32, n);
    defer gpa.free(out_deg);
    @memset(out_deg, 0);
    for (edges) |e| {
        pred_start[e[0] + 1] += 1;
        out_deg[e[1]] += 1;
    }
    for (1..n + 1) |i| pred_start[i] += pred_start[i - 1];
    const preds = try gpa.alloc(u32, edges.len);
    defer gpa.free(preds);
    {
        const at = try gpa.dupe(u32, pred_start[0..n]);
        defer gpa.free(at);
        for (edges) |e| {
            preds[at[e[0]]] = e[1];
            at[e[0]] += 1;
        }
    }
    var max_deg: u32 = 0;
    for (out_deg) |d| max_deg = @max(max_deg, d);
    var p: Partition = try .init(gpa, n, max_deg);
    defer p.deinit(gpa);
    // The initial blocks, by a counting sort on their numbers.
    {
        const at = try gpa.alloc(u32, count + 1);
        defer gpa.free(at);
        @memset(at, 0);
        for (initial) |b| at[b + 1] += 1;
        for (1..count + 1) |i| at[i] += at[i - 1];
        for (0..count) |b| try p.blocks.append(gpa, .{ .first = at[b], .end = at[b + 1], .queued = true });
        for (initial, 0..) |b, i| {
            p.elems[at[b]] = @intCast(i);
            p.where[i] = at[b];
            p.block[i] = b;
            at[b] += 1;
        }
    }
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    for (0..count) |b| try work.append(gpa, @intCast(b));
    var touched: std.ArrayList(u32) = .empty;
    defer touched.deinit(gpa);
    var hit_blocks: std.ArrayList(u32) = .empty;
    defer hit_blocks.deinit(gpa);
    var splitting: std.ArrayList(u32) = .empty;
    defer splitting.deinit(gpa);
    var head: usize = 0;
    while (head < work.items.len) : (head += 1) {
        const s = work.items[head];
        p.blocks.items[s].queued = false;
        // Every edge into the splitter, counted per predecessor.
        touched.clearRetainingCapacity();
        const sb = p.blocks.items[s];
        for (p.elems[sb.first..sb.end]) |t| {
            const ps = preds[pred_start[t]..pred_start[t + 1]];
            try m.pay(1 + ps.len);
            m.spend(1);
            for (ps) |x| {
                m.spend(1);
                if (p.count[x] == 0) try touched.append(gpa, x);
                p.count[x] += 1;
            }
        }
        if (touched.items.len == 0) continue;
        // The touched members by block; the blocks they split, in number
        // order; then every count and list cleared.
        try m.pay(touched.items.len);
        hit_blocks.clearRetainingCapacity();
        for (touched.items) |x| {
            m.spend(1);
            const bi = &p.blocks.items[p.block[x]];
            if (bi.touched == 0) {
                try hit_blocks.append(gpa, p.block[x]);
                bi.c0 = p.count[x];
                bi.mixed = false;
                bi.head = none;
            } else if (p.count[x] != bi.c0) bi.mixed = true;
            p.next[x] = bi.head;
            bi.head = x;
            bi.touched += 1;
        }
        try m.pay(hit_blocks.items.len);
        splitting.clearRetainingCapacity();
        for (hit_blocks.items) |b| {
            m.spend(1);
            const bi = p.blocks.items[b];
            if (bi.mixed or bi.touched < bi.end - bi.first) try splitting.append(gpa, b);
        }
        try m.take(sortCost(splitting.items.len));
        std.mem.sort(u32, splitting.items, {}, std.sort.asc(u32));
        for (splitting.items) |b| try p.split(m, gpa, b, &work);
        for (touched.items) |x| {
            p.count[x] = 0;
        }
        for (hit_blocks.items) |b| {
            p.blocks.items[b].touched = 0;
        }
    }
    return gpa.dupe(u32, p.block);
}

/// A refinable partition: `elems` in block runs `[first, end)`, each
/// element's block and index; the per-splitter counts and lists.
const Partition = struct {
    elems: []u32,
    block: []u32,
    where: []u32,
    /// A state's edges into the current splitter, and its link in its
    /// block's list of touched members, then in its count's.
    count: []u32,
    next: []u32,
    /// The members of each count in the block being split, and the counts
    /// met there.
    count_head: []u32,
    count_size: []u32,
    counts: std.ArrayList(u32) = .empty,
    blocks: std.ArrayList(Block) = .empty,

    const Block = struct { first: u32, end: u32, queued: bool, head: u32 = none, touched: u32 = 0, c0: u32 = 0, mixed: bool = false };

    fn init(gpa: Allocator, n: usize, max_deg: u32) Error!Partition {
        const p: Partition = .{
            .elems = try gpa.alloc(u32, n),
            .block = try gpa.alloc(u32, n),
            .where = try gpa.alloc(u32, n),
            .count = try gpa.alloc(u32, n),
            .next = try gpa.alloc(u32, n),
            .count_head = try gpa.alloc(u32, @as(usize, max_deg) + 1),
            .count_size = try gpa.alloc(u32, @as(usize, max_deg) + 1),
        };
        @memset(p.count, 0);
        @memset(p.count_head, none);
        @memset(p.count_size, 0);
        return p;
    }

    fn deinit(p: *Partition, gpa: Allocator) void {
        inline for (.{ p.elems, p.block, p.where, p.count, p.next, p.count_head, p.count_size }) |a| gpa.free(a);
        p.counts.deinit(gpa);
        p.blocks.deinit(gpa);
    }

    fn swap(p: *Partition, i: u32, j: u32) void {
        const a = p.elems[i];
        const b = p.elems[j];
        p.elems[i] = b;
        p.elems[j] = a;
        p.where[b] = i;
        p.where[a] = j;
    }

    /// Split block `b` by its touched members' counts: the untouched keep
    /// `b` (else the smallest count's members do), each other count a new
    /// block in count order. Every part is queued if `b` was, else all but
    /// the largest (the first of equal sizes in that order).
    fn split(p: *Partition, m: *Meter, gpa: Allocator, b: u32, work: *std.ArrayList(u32)) Error!void {
        const info = p.blocks.items[b];
        // One task per member (grouped, placed and numbered: O(1) words)
        // and one per part.
        try m.pay(2 * @as(u64, info.touched) + 1);
        p.counts.clearRetainingCapacity();
        var x = info.head;
        while (x != none) {
            m.spend(1);
            const c = p.count[x];
            const nx = p.next[x];
            if (p.count_size[c] == 0) try p.counts.append(gpa, c);
            p.next[x] = p.count_head[c];
            p.count_head[c] = x;
            p.count_size[c] += 1;
            x = nx;
        }
        try m.take(sortCost(p.counts.items.len));
        std.mem.sort(u32, p.counts.items, {}, std.sort.asc(u32));
        // The touched members to the end of the run, in count order.
        var tail = info.end;
        var k = p.counts.items.len;
        while (k > 0) {
            k -= 1;
            x = p.count_head[p.counts.items[k]];
            while (x != none) : (x = p.next[x]) {
                tail -= 1;
                p.swap(p.where[x], tail);
            }
        }
        const untouched: u32 = @intFromBool(tail > info.first);
        const parts = untouched + @as(u32, @intCast(p.counts.items.len));
        var largest: u32 = 0;
        var largest_size: u32 = 0;
        var at = info.first;
        for (0..parts) |i| {
            const size = if (i < untouched) tail - info.first else p.count_size[p.counts.items[i - untouched]];
            if (size > largest_size) {
                largest = @intCast(i);
                largest_size = size;
            }
            at += size;
        }
        at = info.first;
        for (0..parts) |i| {
            m.spend(1);
            const size = if (i < untouched) tail - info.first else p.count_size[p.counts.items[i - untouched]];
            const id: u32 = if (i == 0) b else @intCast(p.blocks.items.len);
            if (i == 0) {
                p.blocks.items[b].end = at + size;
            } else {
                try p.blocks.append(gpa, .{ .first = at, .end = at + size, .queued = false });
                for (p.elems[at .. at + size]) |e| {
                    p.block[e] = id;
                }
            }
            if ((info.queued or i != largest) and !p.blocks.items[id].queued) {
                p.blocks.items[id].queued = true;
                try work.append(gpa, id);
            }
            at += size;
        }
        for (p.counts.items) |c| {
            p.count_head[c] = none;
            p.count_size[c] = 0;
        }
    }
};

/// The states `refine` partitions: each one's local words, then a port
/// state per labelled part, whose edges are counted.
pub const Graph = struct {
    words: std.ArrayList(u32) = .empty,
    starts: std.ArrayList(u32) = .empty,
    edges: std.ArrayList([2]u32) = .empty,
    /// Each port's label and its first target in `targets`.
    ports: std.ArrayList([3]u32) = .empty,
    targets: std.ArrayList(u32) = .empty,

    pub fn deinit(g: *Graph, gpa: Allocator) void {
        g.words.deinit(gpa);
        g.starts.deinit(gpa);
        g.edges.deinit(gpa);
        g.ports.deinit(gpa);
        g.targets.deinit(gpa);
    }

    pub fn open(g: *Graph, gpa: Allocator) Error!void {
        try g.starts.append(gpa, @intCast(g.words.items.len));
    }

    pub fn put(g: *Graph, gpa: Allocator, xs: []const u32) Error!void {
        try g.words.appendSlice(gpa, xs);
    }

    /// A port of `state` at `label` with an edge to each of `targets`.
    pub fn port(g: *Graph, gpa: Allocator, state: u32, label: u32, targets: []const u32) Error!void {
        try g.ports.append(gpa, .{ state, label, @intCast(g.targets.items.len) });
        try g.targets.appendSlice(gpa, targets);
    }

    /// The block of each of the `n` states (then of each port). A state
    /// with one labelled part needs no port: its words fix the label.
    pub fn refine(g: *Graph, m: *Meter, n: u32, tie: bool) Error![]u32 {
        const gpa = m.gpa;
        try m.take(1 + g.ports.items.len + wordsCost(g.targets.items.len));
        var next_port = n;
        var q: usize = 0;
        while (q < g.ports.items.len) {
            const state = g.ports.items[q][0];
            var e = q;
            while (e < g.ports.items.len and g.ports.items[e][0] == state) e += 1;
            for (g.ports.items[q..e], q..) |p, i| {
                const end = if (i + 1 < g.ports.items.len) g.ports.items[i + 1][2] else g.targets.items.len;
                const from = if (e - q == 1) state else next_port;
                if (e - q > 1) {
                    try g.starts.append(gpa, @intCast(g.words.items.len));
                    try g.words.appendSlice(gpa, &.{ 1, p[1] });
                    try g.edges.append(gpa, .{ next_port, state });
                    next_port += 1;
                }
                for (g.targets.items[p[2]..end]) |t| try g.edges.append(gpa, .{ t, from });
            }
            q = e;
        }
        try g.starts.append(gpa, @intCast(g.words.items.len));
        const ranks = try rank(m, g.words.items, g.starts.items, tie);
        defer gpa.free(ranks.ranks);
        return blocks(m, ranks.ranks, ranks.count, g.edges.items);
    }
};

const testing = std.testing;

/// `blocks` over `n` states with one initial block per `initial` entry,
/// under an account of `allowance`: the blocks, or the error, and the work.
fn run(initial: []const u32, count: u32, edges: []const [2]u32, allowance: u32) !struct { blocks: ?[]u32, growth: u32, work: u64 } {
    var account: Ids.Account = .{ .allowance = allowance };
    defer account.deinit(testing.allocator);
    var m: Meter = .{ .gpa = testing.allocator, .charge = .growth(&account) };
    const got = blocks(&m, initial, count, edges) catch |e| switch (e) {
        error.OwnershipLimit => null,
        else => return e,
    };
    return .{ .blocks = got, .growth = account.growth, .work = m.work };
}

/// A ring of `n` states, state 0 marked, each naming the next.
fn markedRing(n: u32) !struct { initial: []u32, edges: [][2]u32 } {
    const initial = try testing.allocator.alloc(u32, n);
    const edges = try testing.allocator.alloc([2]u32, n);
    for (initial, edges, 0..) |*b, *e, i| {
        b.* = @intFromBool(i != 0);
        e.* = .{ @intCast((i + 1) % n), @intCast(i) };
    }
    return .{ .initial = initial, .edges = edges };
}

test "blocks are the structure's: any numbering of the states gives the same blocks" {
    var prng: std.Random.DefaultPrng = .init(0x0b10c);
    const rnd = prng.random();
    const n = 400;
    var initial: [n]u32 = undefined;
    for (&initial) |*b| b.* = rnd.uintLessThan(u32, 3);
    var edges: [3 * n][2]u32 = undefined;
    for (&edges) |*e| e.* = .{ rnd.uintLessThan(u32, n), rnd.uintLessThan(u32, n) };
    const a = (try run(&initial, 3, &edges, std.math.maxInt(u32) - 1)).blocks.?;
    defer testing.allocator.free(a);
    // The same graph with its states renumbered and its edges reordered.
    var perm: [n]u32 = undefined;
    for (&perm, 0..) |*p, i| p.* = @intCast(i);
    rnd.shuffle(u32, &perm);
    var initial2: [n]u32 = undefined;
    for (initial, 0..) |b, i| initial2[perm[i]] = b;
    var edges2 = edges;
    for (&edges2) |*e| e.* = .{ perm[e[0]], perm[e[1]] };
    rnd.shuffle([2]u32, &edges2);
    const b = (try run(&initial2, 3, &edges2, std.math.maxInt(u32) - 1)).blocks.?;
    defer testing.allocator.free(b);
    for (0..n) |i| try testing.expectEqual(a[i], b[perm[i]]);
    // Coarsest: two states share a block exactly when their counted
    // successor blocks do.
    var distinct: usize = 0;
    for (a) |x| distinct = @max(distinct, x + 1);
    try testing.expect(distinct > 3 and distinct <= n);
}

test "blocks cost O((n + E) log n), counted: marked rings, and a path of equal states" {
    // A marked ring splits one state at a time; a path of equal states is
    // Moore's worst case, n rounds, and Hopcroft's n log n.
    for (0..2) |family| {
        var last: u64 = 0;
        var size: u32 = 1024;
        while (size <= 16384) : (size *= 2) {
            const g = try markedRing(size);
            defer testing.allocator.free(g.initial);
            defer testing.allocator.free(g.edges);
            var edges = g.edges;
            if (family == 1) {
                @memset(g.initial, 0);
                edges = edges[0 .. edges.len - 1];
            }
            const r = try run(g.initial, 2, edges, std.math.maxInt(u32) - 1);
            defer testing.allocator.free(r.blocks.?);
            // Every state ends alone.
            var seen = try testing.allocator.alloc(bool, size + 2);
            defer testing.allocator.free(seen);
            @memset(seen, false);
            for (r.blocks.?) |b| {
                try testing.expect(!seen[b]);
                seen[b] = true;
            }
            const bound = 8 * @as(u64, size + @as(u32, @intCast(edges.len))) * std.math.log2_int_ceil(u32, size);
            if (r.growth > bound) {
                std.debug.print("family {d}, n {d}: {d} records, bound {d}\n", .{ family, size, r.growth, bound });
                return error.TestUnexpectedResult;
            }
            if (last > 0) try testing.expect(r.growth * 10 <= last * 23);
            last = r.growth;
        }
    }
}

test "blocks stop at every prefix of the allowance before the work it would pay for" {
    const g = try markedRing(48);
    defer testing.allocator.free(g.initial);
    defer testing.allocator.free(g.edges);
    const full = try run(g.initial, 2, g.edges, std.math.maxInt(u32) - 1);
    defer testing.allocator.free(full.blocks.?);
    var a: u32 = 0;
    while (a < full.growth) : (a += 1) {
        // `spend` panics if any work ran past what was paid.
        const r = try run(g.initial, 2, g.edges, a);
        try testing.expect(r.blocks == null);
        try testing.expect(r.growth <= a);
        try testing.expect(r.work <= r.growth);
    }
    const r = try run(g.initial, 2, g.edges, full.growth);
    defer testing.allocator.free(r.blocks.?);
    try testing.expectEqualSlices(u32, full.blocks.?, r.blocks.?);
}

test "rank: equal words one rank, distinct words never, and a forced hash tie ordered by the words" {
    var account: Ids.Account = .{ .allowance = std.math.maxInt(u32) - 1 };
    defer account.deinit(testing.allocator);
    var m: Meter = .{ .gpa = testing.allocator, .charge = .growth(&account) };
    // Keys: [1 2], [3], [1 2], [], [1 3], [3].
    const words = [_]u32{ 1, 2, 3, 1, 2, 1, 3, 3 };
    const starts = [_]u32{ 0, 2, 3, 5, 5, 7, 8 };
    for ([_]bool{ false, true }) |tie| {
        const r = try rank(&m, &words, &starts, tie);
        defer testing.allocator.free(r.ranks);
        try testing.expectEqual(@as(u32, 4), r.count);
        try testing.expectEqual(r.ranks[0], r.ranks[2]);
        try testing.expectEqual(r.ranks[1], r.ranks[5]);
        var distinct: [4]bool = @splat(false);
        for ([_]usize{ 0, 1, 3, 4 }) |i| {
            try testing.expect(!distinct[r.ranks[i]]);
            distinct[r.ranks[i]] = true;
        }
        // Every hash 0: (length, words) alone.
        if (tie) try testing.expectEqualSlices(u32, &.{ 2, 1, 2, 0, 3, 1 }, r.ranks);
    }
}
