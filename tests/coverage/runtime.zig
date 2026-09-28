//! The root of the compiler `zig build coverage` measures: beni's own
//! `main`, in a binary built with LLVM's SanitizerCoverage `trace-pc-guard`
//! instrumentation, plus the two callbacks that instrumentation calls.
//!
//! LLVM gives every instrumented basic block a 32-bit guard in the
//! `__sancov_guards` section and calls `__sanitizer_cov_trace_pc_guard`
//! with its address each time the block runs. The first call for a guard
//! sets it and writes a 1 into the hits file, a shared memory map of the
//! file `coverage_options.hits_path`: an 8-byte count of the processes that
//! mapped it, then one byte per guard, in section order. Every compiler
//! process of a run maps the same file, and a store of 1 is idempotent, so
//! no process needs a lock. A block is recorded the moment it first runs,
//! so a process that panics, is killed at a time limit or exits early keeps
//! everything it ran.
//!
//! `tests/coverage.zig` reads the file back and maps guards to lines.
//! The path is baked in at build time because the harness runs the
//! compiler with an empty environment.

const std = @import("std");
const linux = std.os.linux;
const options = @import("coverage_options");
const beni_main = @import("beni_main");

pub fn main(init: std.process.Init) u8 {
    return beni_main.main(init);
}

/// The byte of the hits file for the first guard, once the file is mapped.
var hits: ?[*]u8 = null;
/// The first guard of the section, which `hits` is indexed from.
var first_guard: [*]u32 = undefined;

/// The size of the hits file's header, the process count.
pub const header_len = 8;

/// Called by the module constructor LLVM adds, before `main` and once per
/// instrumented module; every call names the whole section.
export fn __sanitizer_cov_trace_pc_guard_init(start: [*]u32, stop: [*]u32) callconv(.c) void {
    @disableInstrumentation();
    if (hits != null) return;
    const count = (@intFromPtr(stop) - @intFromPtr(start)) / @sizeOf(u32);
    const len = header_len + count;

    const fd_rc = linux.open(options.hits_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd_rc) != .SUCCESS) fail("cannot open the hits file ");
    const fd: i32 = @intCast(fd_rc);
    // Every process sizes the file the same, so two doing it at once agree;
    // the bytes already written are kept.
    if (linux.errno(linux.ftruncate(fd, @intCast(len))) != .SUCCESS) fail("cannot size the hits file ");
    const map_rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(map_rc) != .SUCCESS) fail("cannot map the hits file ");
    _ = linux.close(fd);

    const base: [*]u8 = @ptrFromInt(map_rc);
    _ = @atomicRmw(u64, @as(*u64, @ptrCast(@alignCast(base))), .Add, 1, .monotonic);
    const map = base + header_len;
    // Blocks that ran before this point, the start-up code and this
    // function's own calls, set their guards but could not record them.
    for (start[0..count], 0..) |guard, i| {
        if (guard != 0) map[i] = 1;
    }
    first_guard = start;
    hits = map;
}

export fn __sanitizer_cov_trace_pc_guard(guard: *u32) callconv(.c) void {
    @disableInstrumentation();
    // The common case: a block that has run before in this process. The
    // check reads process-private memory, so the shared page is written
    // once per block and process, never contended by repeated stores.
    if (@atomicLoad(u32, guard, .monotonic) != 0) return;
    @atomicStore(u32, guard, 1, .monotonic);
    const map = hits orelse return;
    const index = (@intFromPtr(guard) - @intFromPtr(first_guard)) / @sizeOf(u32);
    @atomicStore(u8, &map[index], 1, .monotonic);
}

/// Report a hits file that cannot be used, and stop: a run that measured
/// nothing must not pass for one that measured.
fn fail(comptime message: []const u8) noreturn {
    @disableInstrumentation();
    const text = "coverage runtime: " ++ message;
    _ = linux.write(2, text, text.len);
    _ = linux.write(2, options.hits_path.ptr, options.hits_path.len);
    _ = linux.write(2, "\n", 1);
    linux.exit_group(127);
}
