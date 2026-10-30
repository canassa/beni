//! Select core sibling assets consistently for validation, emission and
//! persistent keys. Disk core overrides win; generated siblings are supplied
//! only when that override has no physical implementation of the asset.
const std = @import("std");
const core_package = @import("core_package");
const SourceStore = @import("SourceStore.zig");

pub fn append(
    comptime Asset: type,
    allocator: std.mem.Allocator,
    paths: std.mem.Allocator,
    io: std.Io,
    core_root: ?[]const u8,
    out: *std.ArrayList(Asset),
) std.mem.Allocator.Error!void {
    for (core_package.assets) |asset| {
        const root = core_root orelse {
            try out.append(allocator, .{ .path = asset.path, .bytes = asset.bytes });
            continue;
        };
        if (!asset.generated) continue;
        const relative = asset.path[core_package.dir.len + 1 ..];
        const joined = try std.fs.path.join(paths, &.{ root, relative });
        const normalized = try paths.alloc(u8, joined.len);
        const path = SourceStore.normalize(normalized, joined);
        if (std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |_| {
            // Do not mask an override, including an invalid physical asset.
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => continue,
        }
        try out.append(allocator, .{ .path = path, .bytes = asset.bytes });
    }
}
