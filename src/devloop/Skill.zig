//! `beni skill` (docs/design/frontend.md §12.3): where the skill for coding
//! agents is installed, and putting it into a harness directory.
//!
//! The skill is a folder of Markdown files that `zig build install` puts
//! beside the binary, at `<prefix>/share/beni/skills/beni/`, and that is
//! never compiled into `beni` (§12.2). The command finds it from the
//! running executable's own path, with every symlink resolved, so a `beni`
//! reached through a profile's symlink still finds the folder next to the
//! real binary. It reads no environment variable and never looks in the
//! working directory.
//!
//! `beni skill` prints the folder's absolute path. `beni skill install
//! <dir>` copies the folder to `<dir>/beni` (or links it, `--link`), and
//! replaces nothing without `--force`. `<dir>` is named by the user: no two
//! harnesses agree on a home directory, and a cloud agent has none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");

/// The folder's path below the prefix, from the directory of the binary.
const below_bin = &[_][]const u8{ "..", "share", "beni", "skills", "beni" };

pub fn run(io: Io, stdout: *Io.Writer, stderr: *Io.Writer, skill: Cli.Skill) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const folder = locate(arena, io) catch |err| switch (err) {
        error.OutOfMemory => return oom(stderr),
        else => return fail(stderr, "beni: cannot find the running executable: {t}", .{err}),
    };
    const index = std.fs.path.join(arena, &.{ folder, "SKILL.md" }) catch return oom(stderr);
    Io.Dir.cwd().access(io, index, .{}) catch
        return fail(stderr, "beni: no skill at '{s}'; 'zig build install' puts it beside the binary", .{folder});

    switch (skill) {
        .locate => {
            stdout.print("{s}\n", .{folder}) catch return 2;
            return 0;
        },
        .install => |install| return installInto(arena, io, stdout, stderr, folder, install),
    }
}

/// `<exe dir>/../share/beni/skills/beni`, absolute and lexically resolved,
/// from the executable's real path.
fn locate(arena: Allocator, io: Io) ![]const u8 {
    const exe = try std.process.executablePathAlloc(io, arena);
    const bin = std.fs.path.dirname(exe) orelse return error.FileNotFound;
    var parts: [1 + below_bin.len][]const u8 = undefined;
    parts[0] = bin;
    for (below_bin, 1..) |segment, i| parts[i] = segment;
    return std.fs.path.resolveAlloc(arena, &parts);
}

fn installInto(arena: Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, folder: []const u8, install: Cli.SkillInstall) u8 {
    const cwd = Io.Dir.cwd();

    // `<dir>/beni` must not be the folder or lie inside it, or the copy
    // writes the tree into itself and a link points at its own path
    // (§12.3 step 2).
    const folder_real = cwd.realPathFileAlloc(io, folder, arena) catch |err|
        return fail(stderr, "beni: cannot read '{s}': {t}", .{ folder, err });
    const dir_real = resolveAsFarAsExists(arena, io, install.dir) catch |err|
        return fail(stderr, "beni: cannot read '{s}': {t}", .{ install.dir, err });
    const target_real = std.fs.path.join(arena, &.{ dir_real, "beni" }) catch return oom(stderr);
    if (std.mem.eql(u8, target_real, folder_real) or isUnder(target_real, folder_real)) {
        return fail(stderr, "beni: '{s}/beni' is the installed skill, or lies inside it", .{install.dir});
    }

    // `<dir>` and its missing parents, as `beni new` makes them.
    cwd.createDirPath(io, install.dir) catch |err|
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ install.dir, err });
    const target = std.fs.path.join(arena, &.{ install.dir, "beni" }) catch return oom(stderr);

    // `<dir>/beni` must not exist. With `--force` a beni skill is replaced —
    // a symlink, or a directory whose SKILL.md says `name: beni` — and
    // nothing else: `beni` is the name of many directories (§12.3 step 4).
    const occupied: ?Io.File.Kind = if (cwd.statFile(io, target, .{ .follow_symlinks = false })) |stat| stat.kind else |err| switch (err) {
        error.FileNotFound => null,
        else => return fail(stderr, "beni: cannot write '{s}': {t}", .{ target, err }),
    };
    if (occupied) |kind| {
        if (!install.force) return fail(stderr, "beni: '{s}' exists; pass --force to replace it", .{target});
        const replaceable = kind == .sym_link or (kind == .directory and isBeniSkill(arena, io, target));
        if (!replaceable) return fail(stderr, "beni: '{s}' is not a beni skill; remove it yourself", .{target});
    }

    if (install.link) {
        // A symlink is unlinked, never followed; a directory is deleted.
        if (occupied != null) cwd.deleteTree(io, target) catch |err|
            return fail(stderr, "beni: cannot write '{s}': {t}", .{ target, err });
        cwd.symLink(io, folder, target, .{ .is_directory = true }) catch |err|
            return fail(stderr, "beni: cannot write '{s}': {t}", .{ target, err });
        stdout.print("Linked the beni skill at {s}\n", .{target}) catch return 2;
        return 0;
    }

    // The copy goes to `<dir>/.beni-new`; when it is complete the old entry
    // is renamed to `<dir>/.beni-old`, the copy to `<dir>/beni`, and the old
    // one deleted: `<dir>/beni` is the old folder or the new one, never half
    // of either, and a failure between the renames leaves the old one whole
    // (§12.3 step 5). Leftovers of an interrupted run go first.
    const staging = std.fs.path.join(arena, &.{ install.dir, ".beni-new" }) catch return oom(stderr);
    const old = std.fs.path.join(arena, &.{ install.dir, ".beni-old" }) catch return oom(stderr);
    for ([_][]const u8{ staging, old }) |leftover| {
        cwd.deleteTree(io, leftover) catch |err|
            return fail(stderr, "beni: cannot write '{s}': {t}", .{ leftover, err });
    }
    copyTree(arena, io, folder, staging) catch |err| {
        cwd.deleteTree(io, staging) catch {};
        if (err == error.OutOfMemory) return oom(stderr);
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ staging, err });
    };
    if (occupied != null) cwd.rename(target, cwd, old, io) catch |err| {
        cwd.deleteTree(io, staging) catch {};
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ target, err });
    };
    cwd.rename(staging, cwd, target, io) catch |err| {
        if (occupied != null) {
            return fail(stderr, "beni: cannot write '{s}': {t}; the old skill is at '{s}'", .{ target, err, old });
        }
        cwd.deleteTree(io, staging) catch {};
        return fail(stderr, "beni: cannot write '{s}': {t}", .{ target, err });
    };
    if (occupied != null) cwd.deleteTree(io, old) catch |err|
        return fail(stderr, "beni: cannot remove '{s}': {t}", .{ old, err });
    stdout.print("Installed the beni skill at {s}\n", .{target}) catch return 2;
    return 0;
}

/// The real path of `dir`'s nearest existing ancestor, with the rest of
/// `dir` joined to it: what `dir` will resolve to once it exists.
fn resolveAsFarAsExists(arena: Allocator, io: Io, dir: []const u8) ![]const u8 {
    var existing: []const u8 = dir;
    var rest: []const u8 = "";
    while (true) {
        if (Io.Dir.cwd().realPathFileAlloc(io, if (existing.len == 0) "." else existing, arena)) |real| {
            return if (rest.len == 0) real else std.fs.path.join(arena, &.{ real, rest });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const base = std.fs.path.basename(existing);
        rest = if (rest.len == 0) base else try std.fs.path.join(arena, &.{ base, rest });
        existing = std.fs.path.dirname(existing) orelse "";
    }
}

fn isUnder(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// Whether `dir` holds a `SKILL.md` whose frontmatter says `name: beni`.
fn isBeniSkill(arena: Allocator, io: Io, dir: []const u8) bool {
    const index = std.fs.path.join(arena, &.{ dir, "SKILL.md" }) catch return false;
    const text = Io.Dir.cwd().readFileAlloc(io, index, arena, .limited(64 * 1024)) catch return false;
    if (!std.mem.startsWith(u8, text, "---\n")) return false;
    const close = std.mem.indexOfPos(u8, text, 4, "\n---") orelse return false;
    var lines = std.mem.splitScalar(u8, text[4..close], '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \r"), "name: beni")) return true;
    }
    return false;
}

/// Every directory and file under `from` (absolute), at the same relative
/// path under `to`, files as regular files.
fn copyTree(arena: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var src = try Io.Dir.openDirAbsolute(io, from, .{ .iterate = true });
    defer src.close(io);
    try cwd.createDirPath(io, to);
    var dest = try cwd.openDir(io, to, .{});
    defer dest.close(io);
    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest.createDirPath(io, entry.path),
        else => try src.copyFile(entry.path, dest, entry.path, io, .{}),
    };
}

fn oom(stderr: *Io.Writer) u8 {
    return fail(stderr, "beni: out of memory", .{});
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
