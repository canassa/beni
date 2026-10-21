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
//! largest chunk so the next file starts warm; `reset(.keep_all)` keeps every
//! chunk, so that work repeated on one arena — the release optimiser's
//! points-to runs (backend.md §9, *The combined solver — Memory*) — reuses
//! memory the kernel has already mapped and never frees or maps it again.
//!
//! A chunk of `huge_page` bytes or more is, on Linux, placed and sized in
//! whole huge pages and advised to be backed by them (`MADV_HUGEPAGE`,
//! #606): one fault then maps 2 MiB instead of 4 KiB, and the release
//! optimiser's runs touch tens of megabytes. Only where the chunk lives
//! changes — never what is allocated, in what order, or how much fits — so
//! nothing a build writes can tell; on every other target it is a no-op.

const std = @import("std");
const builtin = @import("builtin");
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
/// The size the first chunk is planned at, again after a reset that gave
/// every chunk back: `min_chunk_size`, or a column's reservation
/// (`initColumn`).
first_chunk_size: usize = min_chunk_size,
/// A column's arena (`initColumn`): its chunks are touched only as far as
/// the one list in it has grown, so the first huge page of each is not
/// advised, and a short list costs the small pages it fills.
sparse: bool = false,
/// The chunks a `.keep_all` reset kept, linked by `prev`, in the order the
/// work before it opened them: each is opened again, the first that fits
/// a request, before the backing allocator is asked for a new one, so work
/// done again touches the pages it touched before.
spare: ?*Chunk = null,

/// Chunks are never smaller than this. 256 KiB holds every token and node
/// of a typical module, so most files never open a second chunk.
pub const min_chunk_size = 256 * 1024;

/// Allocations are placed at least this aligned; larger alignments are
/// honoured by forwarding the bump pointer.
const chunk_align: Alignment = .fromByteUnits(16);

/// The huge page a large chunk is placed and sized in (x86-64's and
/// AArch64's PMD size with 4 KiB pages). The kernel backs only an aligned
/// 2 MiB range with one, so such a chunk asks the backing allocator for
/// that alignment.
pub const huge_page = 2 * 1024 * 1024;

/// Whether large chunks are placed for huge pages and advised to use them:
/// only Linux has transparent huge pages behind `madvise`. Elsewhere — macOS,
/// Windows, the playground's `wasm32-wasi` — a chunk is what it was.
const huge_pages = builtin.os.tag == .linux;

/// The alignment a chunk of `size` bytes was opened with, and so is
/// freed with: a function of its size alone.
fn alignmentOf(size: usize) Alignment {
    return if (huge_pages and size >= huge_page) .fromByteUnits(huge_page) else chunk_align;
}

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
    /// Keep every chunk and free none: the next allocations fill them
    /// again, in the order they were opened, and the backing allocator is
    /// asked only for what they cannot hold. Memory the work touched once
    /// stays mapped, so doing the same work again faults no page;
    /// `retain_capacity` gives the others back, and a chunk the backing
    /// allocator hands out again is a fresh mapping whose every page
    /// faults anew.
    keep_all,
};

pub fn init(backing: Allocator) Arena {
    return .{ .backing = backing };
}

/// Where memory a process has mapped costs nothing until it is touched, so
/// a reservation is address space and not memory: 64-bit Linux and macOS.
/// Not Windows, whose page allocator commits what it maps, nor 32-bit
/// targets, the playground's `wasm32-wasi` among them, where address space
/// is memory or is short.
const lazy_commit = @sizeOf(usize) == 8 and (builtin.os.tag == .linux or builtin.os.tag.isDarwin());

/// How much address space a column's arena reserves for its one list.
pub const column_reservation = 256 * 1024 * 1024;

/// An arena for ONE growing list — a column — and nothing else (#606).
/// The list is always the arena's last allocation, so it grows in place
/// (`resize`) for as long as its chunk lasts, and its first chunk is a
/// reservation of `column_reservation` bytes where that costs only address
/// space (`lazy_commit`): a list that grows by doubling then never copies
/// itself, and leaves no old copy behind for the pages it faulted in. A
/// list longer than that, or a reservation the backing allocator refuses,
/// goes on in ordinary chunks; elsewhere it is an ordinary arena. Either
/// way only where the list lives changes.
pub fn initColumn(backing: Allocator) Arena {
    const first = if (lazy_commit) column_reservation else min_chunk_size;
    return .{ .backing = backing, .next_chunk_size = first, .first_chunk_size = first, .sparse = true };
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
    if (mode == .keep_all) {
        // Newest first, each in front: the oldest leads, and the spares
        // this work did not open follow.
        var it = arena.current;
        while (it) |chunk| {
            it = chunk.prev;
            chunk.prev = arena.spare;
            arena.spare = chunk;
        }
        arena.current = null;
        arena.end_index = 0;
        return;
    }
    // The spare chunks are chunks like the others here.
    while (arena.spare) |chunk| {
        arena.spare = chunk.prev;
        chunk.prev = arena.current;
        arena.current = chunk;
    }
    var keep: ?*Chunk = null;
    var it = arena.current;
    while (it) |chunk| {
        it = chunk.prev;
        const keep_this = mode == .retain_capacity and (keep == null or chunk.size > keep.?.size);
        if (keep_this) {
            if (keep) |previous_keep| arena.backing.rawFree(previous_keep.bytes(), alignmentOf(previous_keep.size), @returnAddress());
            keep = chunk;
        } else {
            arena.backing.rawFree(chunk.bytes(), alignmentOf(chunk.size), @returnAddress());
        }
    }
    if (keep) |chunk| {
        chunk.prev = null;
        arena.current = chunk;
        arena.end_index = Chunk.header_size;
    } else {
        arena.current = null;
        arena.end_index = 0;
        arena.next_chunk_size = arena.first_chunk_size;
    }
}

/// Bytes currently mapped across all chunks (headers included). For tests
/// and the profiler; not part of the allocation fast path.
pub fn capacity(arena: *const Arena) usize {
    var total: usize = 0;
    for ([_]?*Chunk{ arena.current, arena.spare }) |first| {
        var it = first;
        while (it) |chunk| : (it = chunk.prev) total += chunk.size;
    }
    return total;
}

fn openChunk(arena: *Arena, needed: usize, ret_addr: usize) ?*Chunk {
    // The first spare chunk the request fits: memory work before this
    // touched, already mapped.
    var link = &arena.spare;
    while (link.*) |chunk| {
        if (chunk.size >= Chunk.header_size + needed) {
            link.* = chunk.prev;
            chunk.prev = arena.current;
            arena.current = chunk;
            arena.end_index = Chunk.header_size;
            return chunk;
        }
        link = &chunk.prev;
    }
    // Enough for the request after the header, or the planned size,
    // whichever is larger; every chunk opened raises the plan.
    const fits = Chunk.header_size + needed;
    var size = chunkSize(@max(arena.next_chunk_size, fits));
    const raw = arena.backing.rawAlloc(size, alignmentOf(size), ret_addr) orelse raw: {
        // A plan past the request — a column's reservation — that the
        // backing allocator refuses is not a failure while the request
        // itself can be had.
        const least = chunkSize(@max(min_chunk_size, fits));
        if (least >= size) return null;
        size = least;
        break :raw arena.backing.rawAlloc(size, alignmentOf(size), ret_addr) orelse return null;
    };
    if (alignmentOf(size) != chunk_align) {
        const skip: usize = if (arena.sparse) huge_page else 0;
        if (size > skip) adviseHuge(@alignCast(raw[skip..size]));
    }
    const chunk: *Chunk = @ptrCast(@alignCast(raw));
    chunk.* = .{ .prev = arena.current, .size = size };
    arena.current = chunk;
    arena.end_index = Chunk.header_size;
    arena.next_chunk_size = size *| 2;
    return chunk;
}

/// The size a chunk planned at `planned` bytes is opened at: a huge chunk
/// is whole huge pages, since the tail of a partial one could never be
/// backed by one.
fn chunkSize(planned: usize) usize {
    return if (huge_pages and planned >= huge_page) std.mem.alignForward(usize, planned, huge_page) else planned;
}

/// Ask the kernel to back `bytes` with huge pages. Advice only: a kernel
/// without transparent huge pages, or with them off, refuses or ignores
/// it, and the chunk is ordinary memory, as it was before #606.
fn adviseHuge(bytes: []align(huge_page) u8) void {
    if (!huge_pages) return;
    std.posix.madvise(bytes.ptr, bytes.len, std.posix.MADV.HUGEPAGE) catch {};
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

// #574: the release optimiser runs its points-to fixpoint six times on one
// arena. `retain_capacity` gave back every chunk but the largest, and the
// next run's chunks were fresh mappings whose every page faulted again.
// `keep_all` frees nothing and opens the chunks again in the order the work
// before opened them, so the same work again — here, a small allocation,
// one past the first chunk, and a list grown past both — lands where it did,
// on the same pages, and asks the backing allocator for nothing.
test "reset(.keep_all) frees nothing, and the same work again lands where it did" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: Arena = .init(counting.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    var opened: usize = 0;
    var mapped: usize = 0;
    var where: [3]usize = undefined;
    for (0..4) |round| {
        const small = try a.alloc(u8, 100);
        const big = try a.alloc(u8, min_chunk_size * 2);
        var list: std.ArrayList(u32) = .empty;
        for (0..min_chunk_size) |i| try list.append(a, @intCast(i));
        for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
        const here = [3]usize{ @intFromPtr(small.ptr), @intFromPtr(big.ptr), @intFromPtr(list.items.ptr) };
        if (round == 0) {
            opened = counting.allocations;
            mapped = arena.capacity();
            where = here;
            try testing.expect(opened > 1);
        } else {
            try testing.expectEqual(opened, counting.allocations);
            try testing.expectEqual(mapped, arena.capacity());
            try testing.expectEqualSlices(usize, &where, &here);
        }
        arena.reset(.keep_all);
        try testing.expectEqual(@as(usize, 0), counting.deallocations);
        try testing.expectEqual(mapped, arena.capacity());
    }
    // `retain_capacity` after `keep_all` keeps the largest of them all.
    arena.reset(.retain_capacity);
    try testing.expectEqual(@as(usize, 1), countChunks(&arena));
    try testing.expectEqual(counting.deallocations + 1, opened);
}

// #606: a chunk of a huge page or more is placed and sized so that the
// kernel can back all of it with huge pages — on Linux; elsewhere it is
// opened exactly as before. Either way it holds what it held, and it is
// given back with the alignment it was taken with (the testing allocator
// fails the test otherwise).
test "a huge chunk is whole huge pages on Linux, and an ordinary chunk elsewhere" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const small = try a.alloc(u8, 100);
    try testing.expect(arena.current.?.size < huge_page);
    const big = try a.alloc(u8, huge_page + 1);
    @memset(big, 0xEF);
    @memset(small, 0x12);
    const chunk = arena.current.?;
    try testing.expect(chunk.size >= Chunk.header_size + huge_page + 1);
    if (huge_pages) {
        try testing.expectEqual(@as(usize, 0), @intFromPtr(chunk) % huge_page);
        try testing.expectEqual(@as(usize, 0), chunk.size % huge_page);
        try testing.expectEqual(@as(usize, 2 * huge_page), chunk.size);
    } else {
        try testing.expectEqual(Chunk.header_size + huge_page + 1, chunk.size);
    }
    for (big) |b| try testing.expectEqual(@as(u8, 0xEF), b);
    for (small) |b| try testing.expectEqual(@as(u8, 0x12), b);
    // Kept by `retain_capacity` as the largest, and given back by `free_all`.
    arena.reset(.retain_capacity);
    try testing.expectEqual(chunk, arena.current.?);
    arena.reset(.free_all);
    try testing.expectEqual(@as(usize, 0), arena.capacity());
}

// #606: a list alone in a column's arena is its last allocation, so it
// grows in place; where a reservation costs only address space, its first
// chunk is one, and a list that doubles to megabytes is never copied — the
// one chunk is the only thing asked of the backing allocator, every run
// after a `keep_all` reset lands on it again, and nothing is freed.
test "a list alone in a column's arena grows in place and is never copied" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: Arena = .initColumn(counting.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    var first: ?[*]u64 = null;
    for (0..3) |_| {
        var list: std.ArrayList(u64) = .empty;
        var moves: usize = 0;
        var at: ?[*]u64 = null;
        for (0..(4 * huge_page) / @sizeOf(u64)) |i| {
            try list.append(a, i);
            if (at != list.items.ptr) moves += 1;
            at = list.items.ptr;
        }
        for (list.items, 0..) |v, i| try testing.expectEqual(@as(u64, i), v);
        if (lazy_commit) {
            try testing.expectEqual(@as(usize, 1), moves);
            try testing.expectEqual(@as(usize, 1), counting.allocations);
            try testing.expectEqual(column_reservation, arena.capacity());
        }
        if (first) |f| try testing.expectEqual(f, list.items.ptr) else first = list.items.ptr;
        arena.reset(.keep_all);
        try testing.expectEqual(@as(usize, 0), counting.deallocations);
    }
}

// A column's reservation is a plan, not a need: a backing allocator that
// refuses it still hands out what the request needs, and the list goes on
// in ordinary chunks.
test "a column whose reservation is refused opens what its list needs" {
    const Capped = struct {
        child: Allocator,
        refused: usize = 0,
        fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            if (len > 8 * min_chunk_size) {
                c.refused += 1;
                return null;
            }
            return c.child.rawAlloc(len, alignment, ret_addr);
        }
        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return c.child.rawResize(memory, alignment, new_len, ret_addr);
        }
        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return c.child.rawRemap(memory, alignment, new_len, ret_addr);
        }
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.child.rawFree(memory, alignment, ret_addr);
        }
        fn allocator(c: *@This()) Allocator {
            return .{ .ptr = c, .vtable = &.{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn } };
        }
    };
    var capped: Capped = .{ .child = testing.allocator };
    var arena: Arena = .initColumn(capped.allocator());
    defer arena.deinit();
    var list: std.ArrayList(u32) = .empty;
    for (0..min_chunk_size) |i| try list.append(arena.allocator(), @intCast(i));
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    try testing.expectEqual(@as(usize, if (lazy_commit) 1 else 0), capped.refused);
    // Too large for the backing allocator even at its least: out of memory.
    try testing.expectError(error.OutOfMemory, arena.allocator().alloc(u8, 16 * min_chunk_size));
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
