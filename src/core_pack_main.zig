//! Makes the checked core (docs/design/fast-compiler.md §8, *The checked
//! core, embedded*):
//!
//! ```
//! core_pack <core dir> <build id, 32 hex digits> <out> [<name> <root> <dir>]...
//! ```
//!
//! Only `build.zig` runs this, once per compiler it builds, between building
//! this small program and building that compiler: it checks every module of
//! the core in `<core dir>` exactly as `beni check` would — the same option
//! string, every key computed with the build id of the compiler that will
//! carry the result — and then, for each platform that compiler carries,
//! every module of that platform's chain exactly as `beni check
//! --platform=<name>` would. It writes each core and platform file's
//! front-end artifact and each core and platform module's cache entry into
//! one blob (`cache/Pack.zig`), which that compiler embeds as `core_pack`.
//!
//! **The platforms are the target compiler's, not this program's.** Each
//! `<name> <root> <dir>` triple is one row of the table that compiler embeds
//! (`build.zig`'s `embedPlatforms`): `<dir>` holds exactly the files it
//! embeds, under the same relative paths, and `<root>` is the package root
//! it gives them. The triples become a table of the same shape here, so the
//! chain, the store's paths, the embedded siblings and therefore every key
//! are the ones that compiler computes — while this program is built once,
//! whatever platforms a compiler carries.
//!
//! **One run per chain.** A platform module's key carries what its chain
//! says about markup (`cache/Key.zig`), so one module can have a row per
//! chain it can be checked in; a row two chains share is one row. Each run
//! after the first reads the rows the earlier ones made, so core is checked
//! once and a platform's dependency once per distinct key.
//!
//! **It refuses to make an incomplete pack.** A core or platform module
//! that is not in it would be checked by every build, which is the cost the
//! pack exists to remove, and nothing else would say so; a core or a
//! platform with an error cannot be carried at all. Either fails the build
//! of beni, with the diagnostics.
//!
//! A program of its own, and not a hidden command of `beni`, because it is
//! on the path of every build of beni after an edit under `src/`: this root
//! reaches the front end and the checker and not the backend, the formatter
//! or the development loop, so it compiles in about half the time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const beni = @import("beni");
const Session = beni.Session;
const Pack = beni.cache.Pack;
const platform = beni.platform;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = init.minimal.args.toSlice(arena) catch return fail(stderr, "out of memory", .{});
    if (args.len < 4 or (args.len - 4) % 3 != 0) {
        return fail(stderr, "usage: core_pack <core dir> <build id> <out> [<name> <root> <dir>]...", .{});
    }
    const core_dir = args[1];
    var build_id: [16]u8 = undefined;
    const digits = args[2];
    if (digits.len != 32) return fail(stderr, "the build id is 32 hex digits, not '{s}'", .{digits});
    _ = std.fmt.hexToBytes(&build_id, digits) catch return fail(stderr, "the build id is 32 hex digits, not '{s}'", .{digits});

    const triples = args[4..];
    const table = arena.alloc(platform.Embedded, triples.len / 3) catch return fail(stderr, "out of memory", .{});
    for (table, 0..) |*row, i| {
        const t = triples[i * 3 ..][0..3];
        row.* = readPlatform(arena, io, t[0], t[1], t[2]) catch |err|
            return fail(stderr, "cannot read the platform '{s}' from '{s}': {t}", .{ t[0], t[2], err });
    }

    var writer: Pack.Writer = .{};
    defer writer.deinit(gpa);
    var made: []u8 = &.{};
    defer gpa.free(made);

    // Core alone, then each platform's chain over the rows made so far.
    for (0..table.len + 1) |run| {
        var chain_failure: ?platform.Failure = null;
        const chain: ?platform.Chain = if (run == 0) null else platform.resolveChainIn(arena, io, table[run - 1].name, table, &chain_failure) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "out of memory", .{}),
            error.Failed => {
                _ = platform.report(stderr, chain_failure.?);
                return fail(stderr, "the platform '{s}' has no chain", .{table[run - 1].name});
            },
        };
        const what = if (run == 0) "the core" else table[run - 1].name;
        const blob = check(gpa, io, stderr, core_dir, build_id, &writer, made, if (chain) |*c| c else null, what) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "out of memory", .{}),
            error.Reported => return 1,
        };
        gpa.free(made);
        made = blob;
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = made }) catch |err|
        return fail(stderr, "cannot write '{s}': {t}", .{ args[3], err });
    return 0;
}

/// One run: check `core_dir` and, with `chain`, every module of it, adding
/// the rows `made` does not already hold to `writer`. Returns the blob of
/// every row so far, having made sure it holds one for every core and
/// platform file and module of the run.
fn check(
    gpa: Allocator,
    io: Io,
    stderr: *Io.Writer,
    core_dir: []const u8,
    build_id: [16]u8,
    writer: *Pack.Writer,
    made: []const u8,
    chain: ?*const platform.Chain,
    what: []const u8,
) error{ OutOfMemory, Reported }![]u8 {
    const cpus: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 64));
    // `beni check`'s options, every one that is a term of a key
    // (`cache/Key.zig`'s option string), and `--platform`'s: a pack made with
    // any other would hold rows no build looks up.
    var session = try Session.init(gpa, io, .{
        .jobs = @max(cpus, 1),
        .size_by_work = true,
        .core_package = true,
        .core_root = core_dir,
        .informational = true,
        .platform = if (chain) |c| c.top().name else null,
        .chain = chain,
        .pack_out = writer,
        .pack_in = if (made.len == 0) null else made,
        .pack_build_id = build_id,
    });
    defer session.deinit();

    const summary = session.run(&.{}, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            _ = fail(stderr, "cannot read '{s}': {t}", .{ failure.path, failure.err });
            return error.Reported;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            _ = fail(stderr, "{t}", .{e});
            return error.Reported;
        },
    };
    if (summary.errors != 0) {
        _ = fail(stderr, "{s} does not check", .{what});
        return error.Reported;
    }

    // Every core and platform file and module of the run, or no pack.
    const blob = try writer.write(gpa);
    errdefer gpa.free(blob);
    const pack = Pack.Pack.init(blob);
    var files: u32 = 0;
    for (0..session.store.count()) |i| {
        if (session.store.package(@enumFromInt(i)) == .app) continue;
        files += 1;
        if (pack.find(.frontend, session.file_keys[i]) == null) {
            _ = fail(stderr, "checking {s}, '{s}' left no front-end artifact", .{ what, session.store.path(@enumFromInt(i)) });
            return error.Reported;
        }
    }
    if (files == 0) {
        _ = fail(stderr, "no core modules under '{s}'", .{core_dir});
        return error.Reported;
    }
    for (0..session.graph.count()) |i| {
        const m: @TypeOf(session.graph).Index = @enumFromInt(i);
        if (session.graph.modulePackage(m) == .app) continue;
        if (!session.keys.isCacheable(m) or pack.find(.entry, session.keys.of(m)) == null) {
            _ = fail(stderr, "checking {s}, the module '{s}' left no cache entry", .{ what, session.store.path(session.graph.moduleFile(m)) });
            return error.Reported;
        }
    }
    return blob;
}

/// The row of `build.zig`'s platform table for the platform `name`, whose
/// files `build.zig` staged under `dir`: its `beni.json`, its `.beni`
/// modules and its other files, each relative path as that table spells it.
fn readPlatform(arena: Allocator, io: Io, name: []const u8, root: []const u8, dir: []const u8) !platform.Embedded {
    var rels: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, dir, "", &rels);
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    var files: std.ArrayList(platform.EmbeddedFile) = .empty;
    var assets: std.ArrayList(platform.EmbeddedAsset) = .empty;
    var manifest: ?[]const u8 = null;
    var handle = try Io.Dir.cwd().openDir(io, dir, .{});
    defer handle.close(io);
    for (rels.items) |rel| {
        const bytes = try beni.fs_read.readFileSentinel(io, handle, rel, arena, .limited(1 << 26));
        if (std.mem.eql(u8, rel, "beni.json")) {
            manifest = bytes;
        } else if (std.mem.endsWith(u8, rel, ".beni")) {
            try files.append(arena, .{ .rel = rel, .source = bytes });
        } else {
            try assets.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel }), .bytes = bytes });
        }
    }
    return .{
        .name = name,
        .root = root,
        .manifest = manifest orelse return error.NoManifest,
        .files = files.items,
        .assets = assets.items,
    };
}

fn collect(arena: Allocator, io: Io, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    const full = if (prefix.len == 0) root else try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, prefix });
    var handle = try Io.Dir.cwd().openDir(io, full, .{ .iterate = true });
    defer handle.close(io);
    var it = handle.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try collect(arena, io, root, rel, out),
            .file, .sym_link => try out.append(arena, rel),
            else => {},
        }
    }
}

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print("core_pack: " ++ fmt ++ "\n", args) catch {};
    return 1;
}
