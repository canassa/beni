//! Run hashes: the records that let the black-box suites skip running an
//! emitted program under Node when that exact JavaScript has already run
//! and done what the test expects. Two kinds of program use them.
//!
//! **Corpus `run/` fixtures.** A fixture's record is `<Fixture>.run-hash`
//! next to its `.expected` (or `_expected.run-hash` inside a project
//! fixture), one line per build that was verified:
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
//! A `browser/` fixture's record is the same file with one more field, the
//! DOM its page ran in (`dev v24.19.0 happy-dom-20.14.5 <sha-256 hex>`), and
//! its digest covers the page's other inputs too (`lineWith`, `browser.zig`).
//!
//! A line is written only by the walker's recording mode
//! (`BENI_RUN_HASHES=record`, `zig build test-run-hashes`), and only after
//! Node ran the program, it exited 0, and its stdout equalled the golden.
//! So a line that matches a fresh digest names a program, golden and Node
//! that were verified together, and any change to one of them (a new
//! emitter, a new `core/`, an edited golden, another Node) makes the digest
//! differ and the program run again.
//!
//! **Programs a black-box scenario runs** (`World.expectProgram`, *Program
//! runs* below). The expectation is written in the test's code rather than
//! in a golden, so it is fed to the digest itself: the exit code, stdout and
//! stderr the scenario expects, with the Node version, how Node is invoked
//! (the script's path; the environment is always empty and stdin closed)
//! and the output tree holding the script. Every verified run is one line
//! of the checked-in index `tests/blackbox/run-hashes.txt`:
//!
//!   <test name> #<n> <sha-256 hex>
//!
//! where `n` counts the programs the test has run so far, from 0. Lines are
//! sorted and each names one run, so two branches that verify different
//! tests merge cleanly. A process reads the index once. Recording, each
//! process writes what its runs verified into `BENI_RUN_HASH_REPORT`, and
//! `tests/run_hash_summary.zig` merges that into the index after the last
//! process: a run that ran and matched gets its line, a run that did not
//! loses any line it had, and a run that did not happen keeps its line —
//! unless the recording ran every test, when the index is rewritten from
//! the runs alone.
//!
//! **The Node version** is asked once per build: `build.zig` runs `node
//! --version` in one step and hands the answer to every test process as
//! `--node-version=` (`tests/test_runner.zig`). A process started any other
//! way asks Node itself, once.

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
    return lineWith(arena, w, out_dir, pass, golden_name, golden, null);
}

/// What a record line covers beyond a `run/` build's: the `browser/`
/// kind's page (`browser.zig`), whose verdict also depends on the DOM the
/// program ran in and the script that drove it.
pub const Page = struct {
    /// The DOM's name and version, written on the line after the Node
    /// version: `happy-dom-20.14.5`.
    dom: []const u8,
    /// Everything else the run read, each fed to the digest by name: the
    /// DOM's bytes, the driver's, the steps.
    inputs: []const Input,

    pub const Input = struct { name: []const u8, bytes: []const u8 };
};

/// `line` for a build whose run also depends on `page`, when there is one:
/// `<pass> <node version> <dom> <sha-256 hex>`. A `run/` build (`page`
/// null) gets exactly `line`'s digest and line.
pub fn lineWith(
    arena: Allocator,
    w: *World,
    out_dir: []const u8,
    pass: []const u8,
    golden_name: []const u8,
    golden: []const u8,
    page: ?Page,
) ![]const u8 {
    const node = try nodeVersion(w);
    var h = Sha256.init(.{});
    feed(&h, if (page == null) "beni run-hash 1" else "beni page-hash 1");
    feed(&h, pass);
    feed(&h, node);
    feed(&h, golden_name);
    feed(&h, golden);
    if (page) |p| {
        feed(&h, p.dom);
        for (p.inputs) |input| {
            feed(&h, input.name);
            feed(&h, input.bytes);
        }
    }
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
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (page) |p| return std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{ pass, node, p.dom, &hex });
    return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ pass, node, &hex });
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
/// the program's `process.version`: the build's answer when it gave one
/// (`--node-version=`), else asked once per process.
pub fn nodeVersion(w: *World) ![]const u8 {
    version_mutex.lockUncancelable(w.io);
    defer version_mutex.unlock(w.io);
    if (version) |v| return v;
    const root = @import("root");
    if (@hasDecl(root, "node_version")) {
        const given = std.mem.trim(u8, root.node_version, " \t\r\n");
        if (given.len != 0) {
            version = given;
            return given;
        }
    }
    const exe = w.node_exe orelse return error.NodeNotOnPath;
    var scratch: std.heap.ArenaAllocator = .init(w.gpa);
    defer scratch.deinit();
    const r = try world.spawnAndCapture(scratch.allocator(), w.gpa, w.io, &.{ exe, "--version" }, .inherit, world.default_timeout_ms);
    const text = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (r.exit_code != 0 or text.len == 0 or std.mem.indexOfAny(u8, text, " \n") != null) return error.NodeVersionUnreadable;
    version = try std.heap.page_allocator.dupe(u8, text);
    return version.?;
}

// ---------------------------------------------------------------------------
// Program runs
//
// A black-box scenario's program run (`World.expectProgram`): its digest is
// looked up in the index, and a listed one means Node already ran exactly
// this output tree, under exactly this Node, and it did exactly what the
// scenario expects now.
// ---------------------------------------------------------------------------

/// The index of verified program runs, relative to the repository root,
/// which is every test process's working directory.
pub const index_path = "tests/blackbox/run-hashes.txt";

/// `BENI_RUN_HASH_INDEX`, when set and not empty, reads another index: the
/// scenarios that test this mechanism give their child process one of its
/// own.
const index_env = "BENI_RUN_HASH_INDEX";

/// Run `node <script>` for `w` and compare what it did with `expected`,
/// unless the index lists this run's digest. Null when the program did what
/// `expected` says (or was verified before); else what it did. Recording
/// (`BENI_RUN_HASHES=record`), the program always runs, and the outcome is
/// reported for the index: the digest when it matched, a removal when not.
pub fn checkProgram(w: *World, script: []const u8, expected: world.Expected) !?world.Result {
    const arena = w.arena.allocator();
    const recording = recordingMode();
    const id = try nextRunId(arena);
    // Taken before Node runs, so nothing the program does can change it.
    const digest = try programDigest(arena, w, script, expected);
    if (!recording) {
        if (digest) |d| if (try indexLists(w.io, id, d)) {
            report(w.io, .skipped, null);
            return null;
        };
        report(w.io, .stale, null);
    }
    const got = try w.node(script);
    const ok = matches(got, expected);
    if (recording) {
        const verified = if (ok) digest else null;
        const entry = try std.fmt.allocPrint(arena, "{s} {s}", .{ id, verified orelse "-" });
        report(w.io, if (verified != null) .recorded else .refused, entry);
    }
    return if (ok) null else got;
}

/// Whether `got` is what `expected` says, every field of it.
fn matches(got: world.Result, expected: world.Expected) bool {
    if (got.term != .exited or got.exit_code != expected.exit_code) return false;
    if (!std.mem.eql(u8, got.stdout, expected.stdout)) return false;
    return switch (expected.stderr) {
        .exact => |text| std.mem.eql(u8, got.stderr, text),
        .contains => |text| std.mem.indexOf(u8, got.stderr, text) != null,
    };
}

/// The hex digest of one program run: the Node version, the script, the
/// expectation, and every file of the output tree that holds the script
/// (its directory) but `_manifest.txt`. Null when that tree is empty, which
/// only a build that wrote nothing leaves: such a run is never skipped nor
/// recorded, and Node reports the missing script.
fn programDigest(arena: Allocator, w: *World, script: []const u8, expected: world.Expected) !?[]const u8 {
    var h = Sha256.init(.{});
    feed(&h, "beni program-run 1");
    feed(&h, try nodeVersion(w));
    // How Node runs: `node <script>` in the project directory, with an
    // empty environment and stdin closed (`world.spawnAndCapture`); only the
    // script varies.
    feed(&h, script);
    feed(&h, &.{expected.exit_code});
    feed(&h, expected.stdout);
    feed(&h, @tagName(expected.stderr));
    feed(&h, switch (expected.stderr) {
        inline else => |text| text,
    });
    const tree = std.fs.path.dirname(script) orelse ".";
    const files = try w.listFiles(tree);
    var fed: usize = 0;
    for (files) |rel| {
        if (std.mem.eql(u8, rel, manifest)) continue;
        const full = try std.fs.path.join(arena, &.{ tree, rel });
        const bytes = try w.tmp.dir.readFileAlloc(w.io, full, w.gpa, .limited(world.max_stream_bytes));
        defer w.gpa.free(bytes);
        feed(&h, rel);
        feed(&h, bytes);
        fed += 1;
    }
    if (fed == 0) return null;
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    return try arena.dupe(u8, &hex);
}

fn recordingMode() bool {
    const value = std.testing.environ.getAlloc(std.heap.page_allocator, "BENI_RUN_HASHES") catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "record");
}

var id_mutex: Io.Mutex = .init;
var id_test: []const u8 = "";
var id_next: u32 = 0;

/// `<test name> #<n>`: the test running now (`tests/test_runner.zig` names
/// it, with its file), and how many programs it has run before this one.
fn nextRunId(arena: Allocator) ![]const u8 {
    id_mutex.lockUncancelable(std.testing.io);
    defer id_mutex.unlock(std.testing.io);
    const current = world.timing.current_test;
    if (current.ptr != id_test.ptr or current.len != id_test.len) {
        id_test = current;
        id_next = 0;
    }
    defer id_next += 1;
    return std.fmt.allocPrint(arena, "{s} #{d}", .{ current, id_next });
}

var index_mutex: Io.Mutex = .init;
var index_text: ?[]const u8 = null;

/// Whether the index holds the line `<id> <digest>`.
fn indexLists(io: Io, id: []const u8, digest: []const u8) !bool {
    index_mutex.lockUncancelable(io);
    defer index_mutex.unlock(io);
    if (index_text == null) {
        const gpa = std.heap.page_allocator;
        const custom = std.testing.environ.getAlloc(gpa, index_env) catch "";
        const path = if (custom.len == 0) index_path else custom;
        index_text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(world.max_stream_bytes)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }
    var it = std.mem.splitScalar(u8, index_text.?, '\n');
    while (it.next()) |l| {
        const space = std.mem.lastIndexOfScalar(u8, l, ' ') orelse continue;
        if (std.mem.eql(u8, l[space + 1 ..], digest) and std.mem.eql(u8, l[0..space], id)) return true;
    }
    return false;
}

/// What this process's program runs did, for `tests/run_hash_summary.zig`.
const Report = struct {
    skipped: u32 = 0,
    stale: u32 = 0,
    recorded: u32 = 0,
    refused: u32 = 0,
    /// Recording: one `<id> <digest>` (or `<id> -`) line per run.
    lines: std.ArrayList(u8) = .empty,
    /// `<dir>/program-<random hex>`, this process's two files without
    /// their extension; empty until the first report.
    base: []const u8 = "",
};
var report_mutex: Io.Mutex = .init;
var report_state: Report = .{};

const Event = enum { skipped, stale, recorded, refused };

/// Count one program run and, recording, keep its index line; then rewrite
/// this process's report files under `BENI_RUN_HASH_REPORT` (nothing when
/// it is unset). Rewritten whole each time, because nothing runs when a
/// test process ends, so the files must always be complete.
fn report(io: Io, event: Event, entry: ?[]const u8) void {
    report_mutex.lockUncancelable(io);
    defer report_mutex.unlock(io);
    const r = &report_state;
    switch (event) {
        inline else => |e| @field(r, @tagName(e)) += 1,
    }
    writeReport(io, r, entry) catch |err| {
        std.debug.print("BENI_RUN_HASH_REPORT: cannot write this process's program runs: {t}\n", .{err});
    };
}

fn writeReport(io: Io, r: *Report, entry: ?[]const u8) !void {
    const gpa = std.heap.page_allocator;
    if (entry) |l| {
        try r.lines.appendSlice(gpa, l);
        try r.lines.append(gpa, '\n');
    }
    if (r.base.len == 0) {
        const dir = std.testing.environ.getAlloc(gpa, "BENI_RUN_HASH_REPORT") catch return;
        if (dir.len == 0) return;
        try Io.Dir.cwd().createDirPath(io, dir);
        var random: [8]u8 = undefined;
        io.random(&random);
        r.base = try std.fmt.allocPrint(gpa, "{s}/program-{x}", .{ dir, &random });
    }
    var buffer: [256]u8 = undefined;
    const counts = try std.fmt.bufPrint(&buffer, "program_skipped {d}\nprogram_stale {d}\nprogram_recorded {d}\nprogram_refused {d}\n", .{ r.skipped, r.stale, r.recorded, r.refused });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}.txt", .{r.base}), .data = counts });
    if (r.lines.items.len != 0) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}.records", .{r.base}), .data = r.lines.items });
    }
}
