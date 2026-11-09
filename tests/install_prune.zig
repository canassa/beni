//! The step before `zig build install` copies a source folder into the
//! prefix (docs/design/frontend.md §12.2): it deletes every entry of the
//! installed folder that the source folder does not have.
//!
//!   beni-install-prune <source-dir> <installed-dir>
//!
//! `addInstallDirectory` adds and replaces files, but it never deletes an
//! installed file that the source no longer has. A file that another
//! branch installed then stays in the prefix, and the installed folder is
//! no longer exactly the source (issue #1987). This tool deletes such an
//! entry: a file or a directory that the source does not have, or has with
//! a different kind. An entry that the source has as a file or a directory
//! stays, so the install step after it copies only what changed.
//!
//! It deletes nothing outside `<installed-dir>`, and nothing when that
//! folder does not exist yet.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: beni-install-prune <source-dir> <installed-dir>\n", .{});
        return 2;
    }
    var source = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer source.close(io);
    var installed = Io.Dir.cwd().openDir(io, args[2], .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    defer installed.close(io);

    // Collect first and delete after: the walker must not see a directory
    // change under it. A stale directory is not entered, so its children
    // are not listed; `deleteTree` takes them with it.
    var stale: std.ArrayList([]const u8) = .empty;
    var walker = try installed.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // A file system may not report the kind in the directory entry.
        const kind = if (entry.kind != .unknown) entry.kind else (try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false })).kind;
        if (try sourceHas(io, source, entry.path, kind)) {
            if (kind == .directory) try walker.enter(io, .{ .dir = entry.dir, .basename = entry.basename, .path = entry.path, .kind = kind });
        } else {
            try stale.append(arena, try arena.dupe(u8, entry.path));
        }
    }
    for (stale.items) |sub_path| try installed.deleteTree(io, sub_path);
    return 0;
}

/// Whether the source holds `sub_path` with the same kind. The install step
/// copies only files and directories, so any other kind is stale.
fn sourceHas(io: Io, source: Io.Dir, sub_path: []const u8, kind: Io.File.Kind) !bool {
    if (kind != .file and kind != .directory) return false;
    const st = source.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return st.kind == kind;
}
