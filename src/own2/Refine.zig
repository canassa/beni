//! L10: Hopcroft's partition refinement with canonical block numbers, for
//! `Block`'s positions (`docs/design/ownership-v2.md` §3.6). Edges are
//! counted per label, as for lumping (Valmari and Franceschinis), so two
//! edges of one label — a union's two sides — are a count, not an order.
//! Every choice depends on block numbers and splitting signatures only,
//! never on an element's index: initial blocks in the order of their local
//! keys, touched blocks in number order, parts in signature order, the
//! untouched part keeping its block, the largest part (the first of equal
//! sizes) not queued. So the numbers are a function of the structure.
//! Each edge is moved O(log n) times and each splitter's edges are sorted
//! by comparison, so O(E log n · log E) in all, every edge and sort charged.
//!
//! Obligations kept here: none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");

pub const Error = Ids.ChargeError;

fn chargeSort(gpa: Allocator, charge: Ids.Charge, n: usize) Error!void {
    if (n < 2) return;
    const log: u32 = std.math.log2_int_ceil(usize, n);
    try charge.reserve(gpa, .inspection, @intCast(@min(n * log, std.math.maxInt(u32))));
}

/// The coarsest partition of `local.len` states, stable under `edges`
/// `(target, predecessor, label)` and refining the partition by `local`
/// keys: each state's block number, canonical. `edges` is sorted in place.
pub fn blocks(gpa: Allocator, charge: Ids.Charge, local: []const u64, edges: [][3]u32) Error![]u32 {
    const n = local.len;
    try chargeSort(gpa, charge, edges.len);
    std.mem.sort([3]u32, edges, {}, struct {
        fn less(_: void, a: [3]u32, b: [3]u32) bool {
            return std.mem.order(u32, &a, &b) == .lt;
        }
    }.less);
    const pred_start = try gpa.alloc(u32, n + 1);
    defer gpa.free(pred_start);
    @memset(pred_start, 0);
    for (edges) |e| pred_start[e[0] + 1] += 1;
    for (1..n + 1) |i| pred_start[i] += pred_start[i - 1];
    // The partition: `elems` in block runs, the initial blocks in the
    // order of their local keys.
    var p: Partition = try .init(gpa, n);
    defer p.deinit(gpa);
    std.mem.sort(u32, p.elems, local, struct {
        fn less(ks: []const u64, a: u32, b: u32) bool {
            return ks[a] < ks[b];
        }
    }.less);
    for (p.elems, 0..) |e, i| {
        if (i == 0 or local[e] != local[p.elems[i - 1]]) try p.open(gpa, @intCast(i));
        p.block[e] = @intCast(p.first.items.len - 1);
        p.where[e] = @intCast(i);
    }
    try p.close(gpa, @intCast(n));
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    var queued: std.ArrayList(bool) = .empty;
    defer queued.deinit(gpa);
    for (0..p.first.items.len) |b| {
        try work.append(gpa, @intCast(b));
        try queued.append(gpa, true);
    }
    var hits: std.ArrayList([3]u64) = .empty;
    defer hits.deinit(gpa);
    var head: usize = 0;
    while (head < work.items.len) : (head += 1) {
        const s = work.items[head];
        queued.items[s] = false;
        // Every edge into the splitter: (predecessor, label) counted.
        hits.clearRetainingCapacity();
        for (p.elems[p.first.items[s]..p.end.items[s]]) |t| {
            for (edges[pred_start[t]..pred_start[t + 1]]) |e| try hits.append(gpa, .{ e[1], e[2], 0 });
        }
        try charge.reserve(gpa, .inspection, @intCast(hits.items.len + 1));
        if (hits.items.len == 0) continue;
        try chargeSort(gpa, charge, hits.items.len);
        std.mem.sort([3]u64, hits.items, {}, struct {
            fn less(_: void, a: [3]u64, b: [3]u64) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.less);
        // Each predecessor's signature: its (label, count) run hashed.
        var touched: std.ArrayList([3]u64) = .empty;
        defer touched.deinit(gpa);
        var i: usize = 0;
        while (i < hits.items.len) {
            const x = hits.items[i][0];
            var h = std.hash.Wyhash.init(0x5371);
            while (i < hits.items.len and hits.items[i][0] == x) {
                var j = i;
                while (j < hits.items.len and hits.items[j][0] == x and hits.items[j][1] == hits.items[i][1]) j += 1;
                h.update(std.mem.asBytes(&[2]u64{ hits.items[i][1], j - i }));
                i = j;
            }
            try touched.append(gpa, .{ p.block[x], h.final(), x });
        }
        std.mem.sort([3]u64, touched.items, {}, struct {
            fn less(_: void, a: [3]u64, b: [3]u64) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.less);
        i = 0;
        while (i < touched.items.len) {
            var j = i;
            while (j < touched.items.len and touched.items[j][0] == touched.items[i][0]) j += 1;
            try p.split(gpa, touched.items[i..j], &work, &queued);
            i = j;
        }
    }
    const out = try gpa.alloc(u32, n);
    @memcpy(out, p.block);
    return out;
}

/// A refinable partition: `elems` in block runs `[first, end)`, each
/// element's block and index.
const Partition = struct {
    elems: []u32,
    block: []u32,
    where: []u32,
    first: std.ArrayList(u32) = .empty,
    end: std.ArrayList(u32) = .empty,

    fn init(gpa: Allocator, n: usize) Error!Partition {
        const p: Partition = .{ .elems = try gpa.alloc(u32, n), .block = try gpa.alloc(u32, n), .where = try gpa.alloc(u32, n) };
        for (p.elems, 0..) |*e, i| e.* = @intCast(i);
        return p;
    }

    fn deinit(p: *Partition, gpa: Allocator) void {
        gpa.free(p.elems);
        gpa.free(p.block);
        gpa.free(p.where);
        p.first.deinit(gpa);
        p.end.deinit(gpa);
    }

    fn open(p: *Partition, gpa: Allocator, at: u32) Error!void {
        if (p.first.items.len > 0) try p.end.append(gpa, at);
        try p.first.append(gpa, at);
    }

    fn close(p: *Partition, gpa: Allocator, at: u32) Error!void {
        try p.end.append(gpa, at);
    }

    fn swap(p: *Partition, i: u32, j: u32) void {
        const a = p.elems[i];
        const b = p.elems[j];
        p.elems[i] = b;
        p.elems[j] = a;
        p.where[b] = i;
        p.where[a] = j;
    }

    /// Split one block by its touched members, `(block, signature, element)`
    /// sorted by signature: the untouched members keep the block (else the
    /// first signature's do), each other signature a new block in signature
    /// order. Every part is queued if the block was, else all but the
    /// largest (the first of equal sizes in that order).
    fn split(p: *Partition, gpa: Allocator, touched: []const [3]u64, work: *std.ArrayList(u32), queued: *std.ArrayList(bool)) Error!void {
        const b: u32 = @intCast(touched[0][0]);
        const size = p.end.items[b] - p.first.items[b];
        if (touched.len == size) {
            var same = true;
            for (touched) |t| same = same and t[1] == touched[0][1];
            if (same) return;
        }
        // The touched members to the end of the run, in signature order.
        var tail = p.end.items[b];
        var k = touched.len;
        while (k > 0) {
            k -= 1;
            tail -= 1;
            p.swap(p.where[@intCast(touched[k][2])], tail);
        }
        const Part = struct { start: u32, end: u32 };
        var parts: std.ArrayList(Part) = .empty;
        defer parts.deinit(gpa);
        if (tail > p.first.items[b]) try parts.append(gpa, .{ .start = p.first.items[b], .end = tail });
        var at = tail;
        var i: usize = 0;
        while (i < touched.len) {
            var j = i;
            while (j < touched.len and touched[j][1] == touched[i][1]) j += 1;
            try parts.append(gpa, .{ .start = at, .end = at + @as(u32, @intCast(j - i)) });
            at += @intCast(j - i);
            i = j;
        }
        var largest: usize = 0;
        for (parts.items, 0..) |q, x| if (q.end - q.start > parts.items[largest].end - parts.items[largest].start) {
            largest = x;
        };
        const was = queued.items[b];
        for (parts.items, 0..) |q, x| {
            const id: u32 = if (x == 0) b else @intCast(p.first.items.len);
            if (x == 0) {
                p.end.items[b] = q.end;
            } else {
                try p.first.append(gpa, q.start);
                try p.end.append(gpa, q.end);
                try queued.append(gpa, false);
                for (p.elems[q.start..q.end]) |e| p.block[e] = id;
            }
            if ((was or x != largest) and !queued.items[id]) {
                queued.items[id] = true;
                try work.append(gpa, id);
            }
        }
    }
};
