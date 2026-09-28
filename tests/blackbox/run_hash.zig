//! Run hashes: the record that lets the corpus walker skip running a `run/`
//! program under Node when that exact JavaScript has already been run and
//! matched its golden.
//!
//! A fixture's record is `<Fixture>.run-hash` next to its `.expected` (or
//! `_expected.run-hash` inside a project fixture), one line per build that
//! was verified:
//!
//!   dev v24.19.0 <sha-256 hex>
//!   release v24.19.0 <sha-256 hex>
//!
//! The digest (`line`) covers everything the verdict depended on: the
//! build's name, the Node version (`process.version` of the `node` on
//! `PATH`), the name and bytes of the golden the output was compared with,
//! and every file of the emitted output tree — its path relative to `--out`
//! and its bytes, in sorted path order — except `_manifest.txt`, which lists
//! the other files' hashes and is never run. Every field is length-prefixed,
//! so no two different inputs feed the hash the same bytes.
//!
//! A line is written only by the walker's recording mode
//! (`BENI_RUN_HASHES=record`, `zig build test-run-hashes`), and only after
//! Node ran the program, it exited 0, and its stdout equalled the golden.
//! So a line that matches a fresh digest names a program, golden and Node
//! that were verified together, and any change to one of them (a new
//! emitter, a new `core/`, an edited golden, another Node) makes the digest
//! differ and the program run again.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The golden-adjacent extension of a fixture's record.
pub const ext = "run-hash";

/// The file of the output tree the digest leaves out: the build's own list
/// of what it wrote, with a hash per file, which Node never loads.
pub const manifest = "_manifest.txt";

/// The record line for the program `w` just built into `out_dir`, as build
/// `pass`, compared against `golden_name` holding `golden`. Owned by
/// `arena`.
pub fn line(
    arena: Allocator,
    w: *World,
    out_dir: []const u8,
    pass: []const u8,
    golden_name: []const u8,
    golden: []const u8,
) ![]const u8 {
    const node = try nodeVersion(w);
    var h = Sha256.init(.{});
    feed(&h, "beni run-hash 1");
    feed(&h, pass);
    feed(&h, node);
    feed(&h, golden_name);
    feed(&h, golden);
    const files = try w.listFiles(out_dir);
    var fed: usize = 0;
    for (files) |rel| {
        if (std.mem.eql(u8, rel, manifest)) continue;
        const full = try std.fs.path.join(arena, &.{ out_dir, rel });
        const bytes = try w.tmp.dir.readFileAlloc(w.io, full, w.gpa, .limited(world.max_stream_bytes));
        defer w.gpa.free(bytes);
        feed(&h, rel);
        feed(&h, bytes);
        fed += 1;
    }
    // A build that exited 0 always writes its entry file, so an empty tree
    // is a harness mistake (the wrong `out_dir`), never a digest to record.
    if (fed == 0) return error.EmptyOutputTree;
    const digest = h.finalResult();
    return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ pass, node, &std.fmt.bytesToHex(digest, .lower) });
}

fn feed(h: *Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
}

/// Whether `record` (a record file's text) holds `want` as a whole line.
pub fn listed(record: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, record, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, want)) return true;
    }
    return false;
}

/// A record file's text for the verified `lines` (null entries left out),
/// or null when none was verified and the file should not exist.
pub fn render(arena: Allocator, lines: []const ?[]const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |maybe| if (maybe) |l| {
        try out.appendSlice(arena, l);
        try out.append(arena, '\n');
    };
    return if (out.items.len == 0) null else out.items;
}

/// Replace the record at `path` (relative to the cwd) with `text`, or
/// delete it when `text` is null.
pub fn write(io: Io, path: []const u8, text: ?[]const u8) !void {
    if (text) |t| return Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = t });
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// The record at `path`, or empty when there is none.
pub fn read(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => err,
    };
}

var version_mutex: Io.Mutex = .init;
var version: ?[]const u8 = null;

/// `node --version` of the Node `w` runs programs with — the same text as
/// the program's `process.version` — asked once per process.
pub fn nodeVersion(w: *World) ![]const u8 {
    version_mutex.lockUncancelable(w.io);
    defer version_mutex.unlock(w.io);
    if (version) |v| return v;
    const exe = w.node_exe orelse return error.NodeNotOnPath;
    var scratch: std.heap.ArenaAllocator = .init(w.gpa);
    defer scratch.deinit();
    const r = try world.spawnAndCapture(scratch.allocator(), w.gpa, w.io, &.{ exe, "--version" }, .inherit, world.default_timeout_ms);
    const text = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (r.exit_code != 0 or text.len == 0 or std.mem.indexOfAny(u8, text, " \n") != null) return error.NodeVersionUnreadable;
    version = try std.heap.page_allocator.dupe(u8, text);
    return version.?;
}
