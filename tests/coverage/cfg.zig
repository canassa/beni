//! One function's control-flow graph, built from its machine code, and the
//! rules that decide which of its blocks ran from the few that recorded it.
//!
//! LLVM's `trace-pc-guard` instrumentation does not guard every block: it
//! leaves out a block whose running is implied by another's (it prunes by
//! dominance), and code generation later splits, merges and moves blocks.
//! So a guard that fired proves its own machine block ran, and the rest is
//! inferred, only by rules under which a block MUST have run:
//!
//!   - every dominator of a block that ran ran: control reaches a block
//!     only through its dominators;
//!   - every post-dominator of a block that ran ran: control leaves the
//!     function only through them.
//!
//! A block with a single successor is post-dominated by it and a block with
//! a single predecessor is dominated by it, so those two cases are part of
//! the rules. Each block the rules add is used again, until nothing
//! changes. The post-dominator rule assumes the call that ran the block
//! returned, which a call that panicked or exited the process did not.
//!
//! The graph must not miss an edge, which would make the rules claim too
//! much; an edge too many only makes them claim less. So an instruction the
//! decoder does not know, a branch into the middle of an instruction, or a
//! jump whose targets cannot be read (through a pointer in memory, or a
//! table with no entry in the function) marks the function unsound, and
//! nothing is inferred in it: only its guarded blocks count. A jump table
//! is read from its first word for as long as each entry is an
//! instruction of the function, which can only add edges. A jump through
//! a register that no table load fed is a tail call, and leaves the
//! function. A call of a function that cannot return (`returns`: a panic
//! handler) ends its block with no successor; the edge into the code
//! after it would be one that never runs, and one the rules trust.

const std = @import("std");
const Allocator = std.mem.Allocator;
const x86 = @import("x86.zig");

/// What `build` needs to know about the binary around a function.
pub const Image = struct {
    /// The address of `__sanitizer_cov_trace_pc_guard`.
    callback: u64,
    /// The first guard's address, and how many there are.
    guards: u64,
    guard_count: u64,
    /// The loaded sections a jump table may be read from.
    data: []const Segment,
    /// The entry addresses of the functions that cannot return (`returns`),
    /// ascending: a call of one ends its block with no successor.
    no_return: []const u64 = &.{},

    pub const Segment = struct { address: u64, bytes: []const u8 };

    fn neverReturns(image: Image, address: u64) bool {
        return std.sort.binarySearch(u64, image.no_return, address, struct {
            fn order(key: u64, item: u64) std.math.Order {
                return std.math.order(key, item);
            }
        }.order) != null;
    }

    /// The 8-byte little-endian word at `address`, or null outside `data`.
    fn word(image: Image, address: u64) ?u64 {
        for (image.data) |segment| {
            if (address >= segment.address and address - segment.address + 8 <= segment.bytes.len) {
                return std.mem.readInt(u64, segment.bytes[address - segment.address ..][0..8], .little);
            }
        }
        return null;
    }
};

/// One function's blocks and edges.
pub const Graph = struct {
    /// Each block's first address, ascending; a block ends where the next
    /// begins, and the last at `end`.
    starts: []u64,
    end: u64,
    /// Block `b`'s successors are `successors[successor_start[b]..successor_start[b + 1]]`.
    successor_start: []u32,
    successors: []u32,
    /// Whether control can leave the function from the block: a return, a
    /// tail call, a trap, or a branch out.
    exits: []bool,
    /// Every guarded call site: its block and its guard's index.
    sites: []Site,
    /// Whether the graph can be trusted to have every edge.
    sound: bool,
    /// Guarded call sites whose guard could not be found.
    unmatched_sites: u32,

    pub const Site = struct { block: u32, guard: u32 };

    pub fn blockCount(g: Graph) usize {
        return g.starts.len;
    }

    fn successorsOf(g: Graph, b: usize) []const u32 {
        return g.successors[g.successor_start[b]..g.successor_start[b + 1]];
    }
};

/// The most entries read from one jump table.
const max_table_entries = 4096;

/// One decoded instruction, as `build` keeps it.
const Decoded = struct {
    offset: u32,
    flow: x86.Flow,
    /// For a jump through a table, the table's address.
    table: ?u64 = null,
    /// Whether the jump reads its target from `table` itself, so a table
    /// with no entry in the function means the graph is missing edges; a
    /// jump through a register loaded from it is a tail call instead.
    table_required: bool = false,
    /// For a call to the coverage callback, the guard it passes, or
    /// `unmatched_guard` when it could not be found.
    guard: ?u32 = null,
};

const unmatched_guard = std.math.maxInt(u32);

/// The graph of the function whose machine code is `code`, at `address`.
pub fn build(arena: Allocator, image: Image, address: u64, code: []const u8) Allocator.Error!Graph {
    const end = address + code.len;
    var sound = true;
    var insts: std.ArrayList(Decoded) = .empty;

    // Decode every instruction, remembering the constant last put in `rdi`
    // and what each register was loaded with from a table.
    {
        var offset: usize = 0;
        var rdi: ?u64 = null;
        var table_loads: [16]?u64 = @splat(null);
        while (offset < code.len) {
            const at = address + offset;
            const inst = x86.decode(code[offset..]) catch {
                // The rest of the function is one block nothing is known about.
                sound = false;
                try insts.append(arena, .{ .offset = @intCast(offset), .flow = .trap });
                break;
            };
            var d: Decoded = .{ .offset = @intCast(offset), .flow = x86.flow(inst, at) };
            if (x86.rdiConstant(inst, at)) |value| rdi = value;
            if (x86.writesRegister(inst)) |r| table_loads[r] = null;
            if (x86.tableLoad(inst)) |load| table_loads[load.register] = load.table;
            if (x86.callTarget(inst, at)) |target| {
                if (target == image.callback) {
                    d.guard = unmatched_guard;
                    if (rdi) |value| {
                        if (value >= image.guards and value < image.guards + 4 * image.guard_count and (value - image.guards) % 4 == 0) {
                            d.guard = @intCast((value - image.guards) / 4);
                        }
                    }
                }
                // Nothing follows a call that cannot return, though the
                // next instruction, another block's, comes right after it.
                if (image.neverReturns(target)) d.flow = .trap;
                rdi = null;
            }
            if (d.flow == .jump_indirect) switch (x86.indirectJump(inst) orelse .other) {
                // Without a table load before it, a jump through a
                // register is a tail call through a function pointer.
                .register => |r| d.table = table_loads[r],
                .table => |table| {
                    d.table = table;
                    d.table_required = true;
                },
                // A tail call through the global offset table.
                .rip_slot => {},
                // A target read out of a structure could be anywhere.
                .other => sound = false,
            };
            if (d.flow != .next) {
                rdi = null;
                table_loads = @splat(null);
            }
            try insts.append(arena, d);
            offset += inst.len;
        }
    }

    // Leaders: the entry, every target inside the function, and whatever
    // follows a transfer of control.
    const leader = try arena.alloc(bool, insts.items.len);
    @memset(leader, false);
    leader[0] = true;
    var tables: std.AutoHashMapUnmanaged(usize, []const u32) = .empty;
    for (insts.items, 0..) |d, i| {
        if (d.flow != .next and i + 1 < insts.items.len) leader[i + 1] = true;
        switch (d.flow) {
            .branch, .jump => |target| if (target >= address and target < end) {
                if (indexAt(insts.items, target - address)) |t| leader[t] = true else sound = false;
            },
            .jump_indirect => if (d.table) |table| {
                var entries: std.ArrayList(u32) = .empty;
                var k: u64 = 0;
                while (k < max_table_entries) : (k += 1) {
                    const entry = image.word(table + 8 * k) orelse break;
                    if (entry < address or entry >= end) break;
                    const t = indexAt(insts.items, entry - address) orelse break;
                    leader[t] = true;
                    try entries.append(arena, @intCast(t));
                }
                if (entries.items.len != 0) {
                    try tables.put(arena, i, entries.items);
                } else if (d.table_required) {
                    sound = false;
                }
            },
            else => {},
        }
    }

    // Blocks.
    const block_of = try arena.alloc(u32, insts.items.len);
    var starts: std.ArrayList(u64) = .empty;
    for (insts.items, 0..) |d, i| {
        if (leader[i]) try starts.append(arena, address + d.offset);
        block_of[i] = @intCast(starts.items.len - 1);
    }
    const n = starts.items.len;

    // Edges, from each block's last instruction.
    const successor_start = try arena.alloc(u32, n + 1);
    var successors: std.ArrayList(u32) = .empty;
    const exits = try arena.alloc(bool, n);
    @memset(exits, false);
    var sites: std.ArrayList(Graph.Site) = .empty;
    var unmatched: u32 = 0;
    for (insts.items, 0..) |d, i| {
        if (d.guard) |guard| {
            if (guard == unmatched_guard) unmatched += 1 else try sites.append(arena, .{ .block = block_of[i], .guard = guard });
        }
        const last = i + 1 == insts.items.len or leader[i + 1];
        if (!last) continue;
        const b = block_of[i];
        successor_start[b] = @intCast(successors.items.len);
        const fallthrough: ?u32 = if (i + 1 < insts.items.len) block_of[i + 1] else null;
        switch (d.flow) {
            .next => if (fallthrough) |f| try successors.append(arena, f) else {
                exits[b] = true;
            },
            .branch => |target| {
                if (inside(target, address, end)) |t| {
                    try successors.append(arena, block_of[indexAt(insts.items, t) orelse continue]);
                } else exits[b] = true;
                if (fallthrough) |f| try successors.append(arena, f) else {
                    exits[b] = true;
                }
            },
            .jump => |target| if (inside(target, address, end)) |t| {
                try successors.append(arena, block_of[indexAt(insts.items, t) orelse continue]);
            } else {
                exits[b] = true;
            },
            .jump_indirect => if (tables.get(i)) |entries| {
                for (entries) |t| try successors.append(arena, block_of[t]);
            } else {
                // A tail call through a pointer.
                exits[b] = true;
            },
            .ret, .trap => exits[b] = true,
        }
    }
    successor_start[n] = @intCast(successors.items.len);

    return .{
        .starts = starts.items,
        .end = end,
        .successor_start = successor_start,
        .successors = successors.items,
        .exits = exits,
        .sites = sites.items,
        .sound = sound,
        .unmatched_sites = unmatched,
    };
}

/// Whether the function whose machine code is `code`, at `address`, may
/// return to its caller: whether any of its instructions returns, jumps or
/// branches out of it (a tail call), jumps through a register or memory,
/// or cannot be decoded. A function with none of those — a panic handler,
/// whose every path ends in a trap or another call that does not return —
/// cannot.
pub fn returns(address: u64, code: []const u8) bool {
    const end = address + code.len;
    var offset: usize = 0;
    while (offset < code.len) {
        const inst = x86.decode(code[offset..]) catch return true;
        switch (x86.flow(inst, address + offset)) {
            .ret, .jump_indirect => return true,
            .branch, .jump => |target| if (target < address or target >= end) return true,
            .next, .trap => {},
        }
        offset += inst.len;
    }
    return false;
}

/// `target - start` when `target` is inside `[start, end)`.
fn inside(target: u64, start: u64, end: u64) ?u64 {
    return if (target >= start and target < end) target - start else null;
}

/// The index of the instruction at `offset`, or null when no instruction
/// starts there.
fn indexAt(insts: []const Decoded, offset: u64) ?usize {
    var lo: usize = 0;
    var hi: usize = insts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (insts[mid].offset < offset) lo = mid + 1 else hi = mid;
    }
    return if (lo < insts.len and insts[lo].offset == offset) lo else null;
}

/// Mark in `ran` every block the rules say ran, given the blocks already
/// marked. Does nothing in an unsound graph.
pub fn infer(arena: Allocator, g: Graph, ran: []bool) Allocator.Error!void {
    if (!g.sound) return;
    const n = g.blockCount();
    std.debug.assert(ran.len == n);

    // A block from which no exit can be reached (an endless loop) would
    // leave its predecessors with post-dominators they do not have: it
    // counts as an exit.
    var closed = g;
    closed.exits = try arena.dupe(bool, g.exits);
    {
        const reaches = try arena.dupe(bool, g.exits);
        var changed = true;
        while (changed) {
            changed = false;
            // Backwards, because most edges point forwards.
            var b = n;
            while (b > 0) {
                b -= 1;
                if (reaches[b]) continue;
                for (g.successorsOf(b)) |s| {
                    if (reaches[s]) {
                        reaches[b] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }
        for (reaches, closed.exits) |r, *e| e.* = e.* or !r;
    }

    // The graph and its reverse in one numbering, with a virtual node `n`:
    // the root of the reverse graph, joined to every exit.
    const forward = try Adjacency.init(arena, n + 1, closed, false);
    const reverse = try Adjacency.init(arena, n + 1, closed, true);
    const idom = try dominators(arena, forward, reverse, 0);
    const ipdom = try dominators(arena, reverse, forward, @intCast(n));

    var work: std.ArrayList(u32) = .empty;
    for (ran, 0..) |r, b| if (r) try work.append(arena, @intCast(b));
    while (work.pop()) |b| {
        for ([_][]const u32{ idom, ipdom }) |tree| {
            var x = tree[b];
            while (x != none and x < n and !ran[x]) : (x = tree[x]) {
                ran[x] = true;
                try work.append(arena, x);
            }
        }
    }
}

const none = std.math.maxInt(u32);

/// A graph as lists of successors and of predecessors, over the function's
/// blocks and the virtual exit node.
const Adjacency = struct {
    start: []u32,
    to: []u32,

    fn of(a: Adjacency, v: u32) []const u32 {
        return a.to[a.start[v]..a.start[v + 1]];
    }

    /// The successor lists (or, `reversed`, the predecessor lists) of `g`
    /// with the virtual exit node `count - 1` after every exit.
    fn init(arena: Allocator, count: usize, g: Graph, reversed: bool) Allocator.Error!Adjacency {
        const exit: u32 = @intCast(count - 1);
        const degree = try arena.alloc(u32, count + 1);
        @memset(degree, 0);
        const n = count - 1;
        for (0..n) |b| {
            for (g.successorsOf(b)) |s| degree[if (reversed) s else b] += 1;
            if (g.exits[b]) degree[if (reversed) exit else b] += 1;
        }
        const start = try arena.alloc(u32, count + 1);
        var sum: u32 = 0;
        for (0..count) |v| {
            start[v] = sum;
            sum += degree[v];
        }
        start[count] = sum;
        const to = try arena.alloc(u32, sum);
        const fill = try arena.dupe(u32, start[0..count]);
        for (0..n) |b| {
            const bb: u32 = @intCast(b);
            for (g.successorsOf(b)) |s| {
                const from = if (reversed) s else bb;
                to[fill[from]] = if (reversed) bb else s;
                fill[from] += 1;
            }
            if (g.exits[b]) {
                const from = if (reversed) exit else bb;
                to[fill[from]] = if (reversed) bb else exit;
                fill[from] += 1;
            }
        }
        return .{ .start = start, .to = to };
    }
};

/// Each node's immediate dominator in the graph `succ` from `root`
/// (`pred` is its reverse), or `none` for the root and for a node the root
/// does not reach. Cooper, Harvey and Kennedy's iterative algorithm.
fn dominators(arena: Allocator, succ: Adjacency, pred: Adjacency, root: u32) Allocator.Error![]u32 {
    const count = succ.start.len - 1;
    // Reverse postorder, by an explicit depth-first search.
    const order_of = try arena.alloc(u32, count);
    @memset(order_of, none);
    var postorder: std.ArrayList(u32) = .empty;
    {
        const Frame = struct { node: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        const seen = try arena.alloc(bool, count);
        @memset(seen, false);
        seen[root] = true;
        try stack.append(arena, .{ .node = root, .next = 0 });
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const out = succ.of(top.node);
            if (top.next < out.len) {
                const s = out[top.next];
                top.next += 1;
                if (!seen[s]) {
                    seen[s] = true;
                    try stack.append(arena, .{ .node = s, .next = 0 });
                }
            } else {
                order_of[top.node] = @intCast(postorder.items.len);
                try postorder.append(arena, top.node);
                _ = stack.pop();
            }
        }
    }

    const idom = try arena.alloc(u32, count);
    @memset(idom, none);
    idom[root] = root;
    var changed = true;
    while (changed) {
        changed = false;
        var k = postorder.items.len;
        while (k > 0) {
            k -= 1;
            const v = postorder.items[k];
            if (v == root) continue;
            var new: u32 = none;
            for (pred.of(v)) |p| {
                if (idom[p] == none) continue;
                new = if (new == none) p else intersect(idom, order_of, p, new);
            }
            if (new != none and idom[v] != new) {
                idom[v] = new;
                changed = true;
            }
        }
    }
    idom[root] = none;
    return idom;
}

fn intersect(idom: []const u32, order_of: []const u32, a0: u32, b0: u32) u32 {
    var a = a0;
    var b = b0;
    while (a != b) {
        while (order_of[a] < order_of[b]) a = idom[a];
        while (order_of[b] < order_of[a]) b = idom[b];
    }
    return a;
}

// ---- Tests: small graphs, built by hand, and small functions, assembled
// by hand. ----

/// A graph from successor lists and exit flags, for the inference tests.
fn testGraph(arena: Allocator, succ: []const []const u32, exits: []const bool) !Graph {
    const n = succ.len;
    const starts = try arena.alloc(u64, n);
    for (starts, 0..) |*s, i| s.* = i;
    const successor_start = try arena.alloc(u32, n + 1);
    var all: std.ArrayList(u32) = .empty;
    for (succ, 0..) |list, b| {
        successor_start[b] = @intCast(all.items.len);
        try all.appendSlice(arena, list);
    }
    successor_start[n] = @intCast(all.items.len);
    return .{
        .starts = starts,
        .end = n,
        .successor_start = successor_start,
        .successors = all.items,
        .exits = try arena.dupe(bool, exits),
        .sites = &.{},
        .sound = true,
        .unmatched_sites = 0,
    };
}

fn expectInferred(succ: []const []const u32, exits: []const bool, ran: []const bool, expected: []const bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = try testGraph(arena, succ, exits);
    const marks = try arena.dupe(bool, ran);
    try infer(arena, g, marks);
    try std.testing.expectEqualSlices(bool, expected, marks);
}

test "an if without else: the body ran, so the test before it and the join after it ran" {
    // 0: test, branches to 1 (body) or 2 (join); 1 falls into 2; 2 returns.
    try expectInferred(
        &.{ &.{ 1, 2 }, &.{2}, &.{} },
        &.{ false, false, true },
        &.{ false, true, false },
        &.{ true, true, true },
    );
    // Only the join ran: the entry did, the body is unknown.
    try expectInferred(
        &.{ &.{ 1, 2 }, &.{2}, &.{} },
        &.{ false, false, true },
        &.{ false, false, true },
        &.{ true, false, true },
    );
}

test "an if with else: one arm running says nothing of the other" {
    // 0 branches to 1 or 2, both fall into 3.
    try expectInferred(
        &.{ &.{ 1, 2 }, &.{3}, &.{3}, &.{} },
        &.{ false, false, false, true },
        &.{ false, false, true, false },
        &.{ true, false, true, true },
    );
}

test "a block that can leave the function early does not imply the code after the exit" {
    // 0 branches to 1 (returns early) or 2 (returns); 0 ran.
    try expectInferred(
        &.{ &.{ 1, 2 }, &.{}, &.{} },
        &.{ false, true, true },
        &.{ true, false, false },
        &.{ true, false, false },
    );
    // 0 can return itself, or go on to 1.
    try expectInferred(
        &.{ &.{1}, &.{} },
        &.{ true, true },
        &.{ true, false },
        &.{ true, false },
    );
}

test "a loop: the body implies the header, not the other way round" {
    // 0 -> 1 (header); 1 -> 2 (body) or 3 (exit); 2 -> 1.
    try expectInferred(
        &.{ &.{1}, &.{ 2, 3 }, &.{1}, &.{} },
        &.{ false, false, false, true },
        &.{ false, false, true, false },
        &.{ true, true, true, true },
    );
    try expectInferred(
        &.{ &.{1}, &.{ 2, 3 }, &.{1}, &.{} },
        &.{ false, false, false, true },
        &.{ false, true, false, false },
        &.{ true, true, false, true },
    );
}

test "inferred blocks feed the rules again" {
    // 0 -> 1 | 4; 1 -> 2; 2 -> 3 | 4; 3 -> 4; 4 exits. Block 3 ran: its
    // dominators 2, 1 and 0 ran, and the post-dominator 4.
    try expectInferred(
        &.{ &.{ 1, 4 }, &.{2}, &.{ 3, 4 }, &.{4}, &.{} },
        &.{ false, false, false, false, true },
        &.{ false, false, false, true, false },
        &.{ true, true, true, true, true },
    );
}

test "a block that cannot reach an exit implies only its dominators" {
    // 0 -> 1 | 2; 1 loops forever; 2 returns.
    try expectInferred(
        &.{ &.{ 1, 2 }, &.{1}, &.{} },
        &.{ false, false, true },
        &.{ false, true, false },
        &.{ true, true, false },
    );
}

test "an unsound graph infers nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g = try testGraph(arena, &.{ &.{1}, &.{} }, &.{ false, true });
    g.sound = false;
    const marks = try arena.dupe(bool, &.{ false, true });
    try infer(arena, g, marks);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, marks);
}

/// An image with the callback at 0x9000, two guards at 0x5000 and a jump
/// table at 0x6000.
fn testImage(table: []const u8) Image {
    const S = struct {
        var segments: [1]Image.Segment = undefined;
    };
    S.segments[0] = .{ .address = 0x6000, .bytes = table };
    return .{ .callback = 0x9000, .guards = 0x5000, .guard_count = 2, .data = &S.segments };
}

test "a function's blocks, edges and guarded sites" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = 0x1000;
    // 1000: mov edi, 0x5000       ; guard 0
    // 1005: call 0x9000
    // 100a: test edi, edi
    // 100c: je 0x101a
    // 100e: mov edi, 0x5004       ; guard 1
    // 1013: call 0x9000
    // 1018: jmp 0x101a
    // 101a: ret
    const code = [_]u8{
        0xbf, 0x00, 0x50, 0x00, 0x00,
        0xe8, 0xf6, 0x7f, 0x00, 0x00,
        0x85, 0xff, 0x74, 0x0c, 0xbf,
        0x04, 0x50, 0x00, 0x00, 0xe8,
        0xe8, 0x7f, 0x00, 0x00, 0xeb,
        0x00, 0xc3,
    };
    const g = try build(arena, testImage(&.{}), base, &code);
    try std.testing.expect(g.sound);
    try std.testing.expectEqualSlices(u64, &.{ 0x1000, 0x100e, 0x101a }, g.starts);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, g.successorsOf(0));
    try std.testing.expectEqualSlices(u32, &.{2}, g.successorsOf(1));
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, g.exits);
    try std.testing.expectEqual(@as(usize, 2), g.sites.len);
    try std.testing.expectEqual(Graph.Site{ .block = 0, .guard = 0 }, g.sites[0]);
    try std.testing.expectEqual(Graph.Site{ .block = 1, .guard = 1 }, g.sites[1]);
    try std.testing.expectEqual(@as(u32, 0), g.unmatched_sites);
}

test "a switch through a jump table has an edge to every case" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1000: jmp [0x6000 + rax*8]
    // 1007: ret                   ; case 0
    // 1008: ud2                   ; case 1
    // 100a: ret                   ; never a case
    const code = [_]u8{ 0xff, 0x24, 0xc5, 0x00, 0x60, 0x00, 0x00, 0xc3, 0x0f, 0x0b, 0xc3 };
    var table: [24]u8 = undefined;
    std.mem.writeInt(u64, table[0..8], 0x1007, .little);
    std.mem.writeInt(u64, table[8..16], 0x1008, .little);
    // The next word is outside the function: the table ends before it.
    std.mem.writeInt(u64, table[16..24], 0x2000, .little);
    const g = try build(arena, testImage(&table), 0x1000, &code);
    try std.testing.expect(g.sound);
    try std.testing.expectEqualSlices(u64, &.{ 0x1000, 0x1007, 0x1008, 0x100a }, g.starts);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, g.successorsOf(0));
    try std.testing.expectEqualSlices(bool, &.{ false, true, true, true }, g.exits);
}

test "a jump through a table indexed by a scaled register, and one through a pointer" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table: [16]u8 = undefined;
    std.mem.writeInt(u64, table[0..8], 0x1006, .little);
    std.mem.writeInt(u64, table[8..16], 0x1007, .little);
    // 1000: jmp [rax + 0x6000]
    // 1006: ret
    // 1007: ret
    const scaled = try build(arena, testImage(&table), 0x1000, &.{ 0xff, 0xa0, 0x00, 0x60, 0x00, 0x00, 0xc3, 0xc3 });
    try std.testing.expect(scaled.sound);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, scaled.successorsOf(0));
    // 1000: jmp [rax + 0x18]; nothing says where it goes.
    const pointer = try build(arena, testImage(&table), 0x1000, &.{ 0xff, 0x60, 0x18, 0xc3 });
    try std.testing.expect(!pointer.sound);
    // 1000: jmp rax, with no table load before it: a tail call.
    const tail = try build(arena, testImage(&table), 0x1000, &.{ 0xff, 0xe0 });
    try std.testing.expect(tail.sound);
    try std.testing.expectEqualSlices(bool, &.{true}, tail.exits);
}

test "a jump into the middle of an instruction makes the function unsound" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1000: jmp 0x1003 (inside the next instruction)
    // 1002: mov eax, 0x90909090
    // 1007: ret
    const code = [_]u8{ 0xeb, 0x01, 0xb8, 0x90, 0x90, 0x90, 0x90, 0xc3 };
    const g = try build(arena, testImage(&.{}), 0x1000, &code);
    try std.testing.expect(!g.sound);
}

test "a jump or branch out of the function is an exit" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1000: jne 0x3000            ; out
    // 1006: jmp 0x4000            ; a tail call
    const code = [_]u8{ 0x0f, 0x85, 0xfa, 0x1f, 0x00, 0x00, 0xe9, 0xf5, 0x2f, 0x00, 0x00 };
    const g = try build(arena, testImage(&.{}), 0x1000, &code);
    try std.testing.expect(g.sound);
    try std.testing.expectEqualSlices(u64, &.{ 0x1000, 0x1006 }, g.starts);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, g.exits);
    try std.testing.expectEqualSlices(u32, &.{1}, g.successorsOf(0));
}

test {
    _ = x86;
}

test "a call of a function that cannot return ends its block" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A panic handler at 0x8000: it calls another and traps.
    try std.testing.expect(!returns(0x8000, &.{ 0xe8, 0x00, 0x10, 0x00, 0x00, 0x0f, 0x0b }));
    // Anything that returns, or leaves by a tail call, may return.
    try std.testing.expect(returns(0x8000, &.{ 0x31, 0xc0, 0xc3 }));
    try std.testing.expect(returns(0x8000, &.{ 0xe9, 0x00, 0x10, 0x00, 0x00 }));
    try std.testing.expect(returns(0x8000, &.{ 0xff, 0xe0 }));

    // 1000: je 0x1007
    // 1002: call 0x8000           ; the panic handler
    // 1007: ret
    var image = testImage(&.{});
    const code = [_]u8{ 0x74, 0x05, 0xe8, 0xf9, 0x6f, 0x00, 0x00, 0xc3 };
    const falls = try build(arena, image, 0x1000, &code);
    try std.testing.expectEqualSlices(u32, &.{2}, falls.successorsOf(1));
    image.no_return = &.{0x8000};
    const g = try build(arena, image, 0x1000, &code);
    try std.testing.expectEqualSlices(u64, &.{ 0x1000, 0x1002, 0x1007 }, g.starts);
    try std.testing.expectEqual(@as(usize, 0), g.successorsOf(1).len);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, g.exits);
}
