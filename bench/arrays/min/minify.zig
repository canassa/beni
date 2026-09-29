//! beni's release compactor (`src/js/Minify.zig`, backend.md §9 *Hand-written JavaScript under
//! `--release`*) as a filter, so `measure.mjs` can run it on a sibling with any set of kept exports:
//!
//!     minify <file> [export…]      compacted and cut to those exports; no exports = compaction only
//!
//! Prints the result, or exits 2 when Minify declines the file (a build would copy it as written).
const std = @import("std");
const Minify = @import("beni").js.Minify;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.Usage;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(1 << 24));
    const keep: ?[]const []const u8 = if (args.len > 2) args[2..] else null;
    const out = try Minify.minify(arena, source, keep) orelse std.process.exit(2);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll(out);
    try w.interface.flush();
}
