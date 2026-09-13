//! Single-thread chunked bump allocator (docs/design/frontend.md §3.4,
//! fast-compiler.md §5 rule 3).
//!
//! Every per-file phase allocates from one of these, and each is owned by
//! exactly one worker for its whole lifetime, so there is no atomic anywhere
//! in it — that is the point of not using `std.heap.ArenaAllocator`, whose
//! per-allocation state updates are atomic RMWs (Roc's `SingleThreadArena`
//! finding, research/05). It implements the `std.mem.Allocator` vtable so
//! `std.ArrayList` and `std.MultiArrayList` can be pointed at it unchanged.
//!
//! Layout: a singly linked list of chunks, newest first, each carrying its
//! header at the front of its own bytes. `alloc` bumps in the current chunk
//! and opens a new one (double the previous size, or the request if larger)
//! when full. `resize`/`remap` grow in place only for the most recent
//! allocation; `free` rolls the bump pointer back only for the most recent
//! allocation and is otherwise a no-op. `reset(.retain_capacity)` keeps the
//! largest chunk so the next file starts warm.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Arena = @This();

/// Where chunks come from. `std.heap.page_allocator` in production; tests
/// pass `std.testing.allocator` so a leaked chunk fails the test.
backing: Allocator,
/// Most recently opened chunk; null until the first allocation.
current: ?*Chunk = null,
/// Bump offset within `current`, measured from the chunk's first byte
/// (so it is never smaller than `Chunk.header_size`).
end_index: usize = 0,
/// Size of the next chunk to open, doubled every time one is opened.
next_chunk_size: usize = min_chunk_size,

/// Chunks are never smaller than this. 256 KiB holds every token and node
/// of a typical module, so most files never open a second chunk.
pub const min_chunk_size = 256 * 1024;

/// Allocations are placed at least this aligned; larger alignments are
/// honoured by forwarding the bump pointer.
const chunk_align: Alignment = .fromByteUnits(16);

const Chunk = struct {
    prev: ?*Chunk,
    /// Total bytes including this header.
    size: usize,

    const header_size = std.mem.alignForward(usize, @sizeOf(Chunk), chunk_align.toByteUnits());

    fn bytes(chunk: *Chunk) []align(chunk_align.toByteUnits()) u8 {
        const base: [*]align(chunk_align.toByteUnits()) u8 = @ptrCast(@alignCast(chunk));
        return base[0..chunk.size];
    }
};

pub const ResetMode = enum {
    /// Release every chunk; the next allocation starts from scratch.
    free_all,
    /// Keep the largest chunk, release the rest. The design's default between
    /// files (frontend.md §3.4).
    retain_capacity,
};

pub fn init(backing: Allocator) Arena {
    return .{ .backing = backing };
}

/// Release every chunk. The arena must not be used afterwards.
pub fn deinit(arena: *Arena) void {
    arena.reset(.free_all);
    arena.* = undefined;
}

/// The `std.mem.Allocator` view. The returned allocator is only valid on the
/// owning thread and only while `arena` is not moved.
pub fn allocator(arena: *Arena) Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// Forget every allocation. With `.retain_capacity`, the largest chunk stays
/// mapped and becomes the current one; every other chunk is returned to the
/// backing allocator.
pub fn reset(arena: *Arena, mode: ResetMode) void {
    var keep: ?*Chunk = null;
    var it = arena.current;
    while (it) |chunk| {
        it = chunk.prev;
        const keep_this = mode == .retain_capacity and (keep == null or chunk.size > keep.?.size);
        if (keep_this) {
            if (keep) |previous_keep| arena.backing.rawFree(previous_keep.bytes(), chunk_align, @returnAddress());
            keep = chunk;
        } else {
            arena.backing.rawFree(chunk.bytes(), chunk_align, @returnAddress());
        }
    }
    if (keep) |chunk| {
        chunk.prev = null;
        arena.current = chunk;
        arena.end_index = Chunk.header_size;
    } else {
        arena.current = null;
        arena.end_index = 0;
        arena.next_chunk_size = min_chunk_size;
    }
}

/// Bytes currently mapped across all chunks (headers included). For tests
/// and the profiler; not part of the allocation fast path.
pub fn capacity(arena: *const Arena) usize {
    var total: usize = 0;
    var it = arena.current;
    while (it) |chunk| : (it = chunk.prev) total += chunk.size;
    return total;
}

fn openChunk(arena: *Arena, needed: usize, ret_addr: usize) ?*Chunk {
    // Enough for the request after the header, or the planned size,
    // whichever is larger; every chunk opened raises the plan.
    const size = @max(arena.next_chunk_size, Chunk.header_size + needed);
    const raw = arena.backing.rawAlloc(size, chunk_align, ret_addr) orelse return null;
    const chunk: *Chunk = @ptrCast(@alignCast(raw));
    chunk.* = .{ .prev = arena.current, .size = size };
    arena.current = chunk;
    arena.end_index = Chunk.header_size;
    arena.next_chunk_size = size *| 2;
    return chunk;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    if (arena.current) |chunk| {
        if (arena.bumpIn(chunk, len, alignment)) |ptr| return ptr;
    }
    // A request that needs alignment above the chunk's own must reserve
    // slack for the forward, since a fresh chunk's first byte is only
    // `chunk_align` aligned.
    const slack = if (alignment.toByteUnits() > chunk_align.toByteUnits()) alignment.toByteUnits() else 0;
    const chunk = arena.openChunk(len + slack, ret_addr) orelse return null;
    return arena.bumpIn(chunk, len, alignment) orelse unreachable; // sized to fit above
}

/// Try to carve `len` bytes at `alignment` out of `chunk`'s free tail.
fn bumpIn(arena: *Arena, chunk: *Chunk, len: usize, alignment: Alignment) ?[*]u8 {
    const base = @intFromPtr(chunk);
    const start = alignment.forward(base + arena.end_index);
    const end = start + len;
    if (end > base + chunk.size) return null;
    arena.end_index = end - base;
    return @ptrFromInt(start);
}

/// True when `memory` is the most recent allocation, i.e. it ends exactly at
/// the bump pointer of the current chunk.
fn isLast(arena: *const Arena, memory: []u8) bool {
    const chunk = arena.current orelse return false;
    return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(chunk) + arena.end_index;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = alignment;
    _ = ret_addr;
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    if (new_len <= memory.len) return true; // shrinking in place is always fine
    if (!arena.isLast(memory)) return false;
    const chunk = arena.current.?;
    const new_end = @intFromPtr(memory.ptr) + new_len;
    if (new_end > @intFromPtr(chunk) + chunk.size) return false;
    arena.end_index = new_end - @intFromPtr(chunk);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    // Only the most recent allocation can be given back; anything else is
    // reclaimed by `reset`.
    if (arena.isLast(memory)) arena.end_index -= memory.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "allocations honour alignment across types" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try a.alloc(u8, 3);
    const words = try a.alloc(u64, 4);
    const wide = try a.alignedAlloc(u8, .fromByteUnits(64), 10);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(words.ptr) % @alignOf(u64));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(wide.ptr) % 64);
    try testing.expect(@intFromPtr(words.ptr) >= @intFromPtr(bytes.ptr) + bytes.len);
    try testing.expect(@intFromPtr(wide.ptr) >= @intFromPtr(words.ptr) + 4 * @sizeOf(u64));
    try testing.expectEqual(@as(usize, 1), countChunks(&arena));
}

test "growth opens a new chunk and keeps earlier allocations intact" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try a.alloc(u8, 100);
    @memset(first, 0xAB);
    // Larger than the first chunk: forces a second, bigger chunk.
    const big = try a.alloc(u8, min_chunk_size * 2);
    @memset(big, 0xCD);
    try testing.expectEqual(@as(usize, 2), countChunks(&arena));
    try testing.expect(arena.current.?.size >= min_chunk_size * 2 + Chunk.header_size);
    for (first) |b| try testing.expectEqual(@as(u8, 0xAB), b);
    for (big) |b| try testing.expectEqual(@as(u8, 0xCD), b);

    // The chunk after that doubles again.
    _ = try a.alloc(u8, min_chunk_size * 3);
    try testing.expectEqual(@as(usize, 3), countChunks(&arena));
    try testing.expect(arena.current.?.size >= min_chunk_size * 4);
}

test "resize grows the last allocation in place and refuses others" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var list = try a.alloc(u8, 16);
    const before = list.ptr;
    try testing.expect(a.resize(list, 1024));
    list = list.ptr[0..1024];
    try testing.expectEqual(before, list.ptr);

    // No longer the last allocation: growing must fail, shrinking still works.
    const other = try a.alloc(u8, 8);
    try testing.expect(!a.resize(list, 2048));
    try testing.expect(a.resize(list, 8));
    try testing.expectEqual(@as(?[]u8, null), a.remap(list, 2048));

    // Freeing the last allocation rolls the bump pointer back so the next
    // allocation reuses the bytes.
    a.free(other);
    const again = try a.alloc(u8, 8);
    try testing.expectEqual(other.ptr, again.ptr);

    // Beyond the chunk: fails without moving.
    try testing.expect(!a.resize(again, min_chunk_size * 4));
}

test "ArrayList grows through the arena" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(u32) = .empty;
    for (0..100_000) |i| try list.append(arena.allocator(), @intCast(i));
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
}

test "reset(.retain_capacity) keeps exactly the largest chunk" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 10);
    _ = try a.alloc(u8, min_chunk_size * 2 - 1024); // second chunk, the largest
    _ = try a.alloc(u8, 10); // fits in the second chunk's slack
    try testing.expectEqual(@as(usize, 2), countChunks(&arena));
    const largest = arena.current.?;

    arena.reset(.retain_capacity);
    try testing.expectEqual(@as(usize, 1), countChunks(&arena));
    try testing.expectEqual(largest, arena.current.?);
    try testing.expectEqual(Chunk.header_size, arena.end_index);
    try testing.expectEqual(largest.size, arena.capacity());

    // Reuse: the next allocation lands at the start of the retained chunk.
    const p = try a.alloc(u8, 1);
    try testing.expectEqual(@intFromPtr(largest) + Chunk.header_size, @intFromPtr(p.ptr));

    arena.reset(.free_all);
    try testing.expectEqual(@as(usize, 0), countChunks(&arena));
    try testing.expectEqual(@as(usize, 0), arena.capacity());
}

test "reset on an empty arena is a no-op" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    arena.reset(.retain_capacity);
    arena.reset(.free_all);
    try testing.expectEqual(@as(?*Chunk, null), arena.current);
}

test "no chunk leaks when the backing allocator fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(backing: Allocator) !void {
            var arena: Arena = .init(backing);
            defer arena.deinit();
            const a = arena.allocator();
            _ = try a.alloc(u8, 10);
            _ = try a.alloc(u8, min_chunk_size * 2);
            arena.reset(.retain_capacity);
            _ = try a.alloc(u64, min_chunk_size);
        }
    }.run, .{});
}

fn countChunks(arena: *const Arena) usize {
    var n: usize = 0;
    var it = arena.current;
    while (it) |chunk| : (it = chunk.prev) n += 1;
    return n;
}
