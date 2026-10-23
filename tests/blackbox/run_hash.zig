//! Run hashes: the cache of verified program runs that lets the black-box
//! suites skip Node for an emitted program that has already run and done
//! what its test expects.
//!
//! **A run hash is a cache entry, not an assertion** (the owner,
//! 2026-10-23, #875). The goldens stay the assertion: `.expected`, `emit/`
//! and the expectations written in a scenario's code. A digest says that
//! one program, compared with one golden, under one Node (and, for a page,
//! in one DOM with one driver and one script), ran and matched.
//!
//! **The cache** is a directory of empty files outside git, one per
//! verified digest, `<dir>/<sha-256 hex>`. `BENI_RUN_HASH_DIR` names it:
//! `build.zig` hands every test process the value of its own environment,
//! else `${XDG_CACHE_HOME:-$HOME/.cache}/beni-run-hashes`, which the dev
//! shells export too (`flake.nix`). Set and empty, there is no cache, and
//! every program runs. All worktrees share one directory: that is safe,
//! because the digest covers every input of the verdict. On CI
//! `actions/cache` holds it, saved from master and from each pull request
//! in its own scope (`.github/workflows/ci.yml`). It only grows; delete it
//! to start cold.
//!
//! **Every ordinary test run records.** Before a program runs, its digest
//! is looked up (`verified`). A hit skips Node: the verdict was taken
//! before, on exactly these bytes. On a miss Node runs and the output is
//! compared with the golden, and only when the program exited as expected
//! and its output equalled the golden is the digest written (`record`),
//! atomically: a named temporary file in the directory (16 hex digits),
//! then a rename over the final name, so two processes that write the same
//! digest at once both succeed. A writer killed between the two leaves its
//! temporary file; it is never read as a digest (a digest has 64 digits)
//! and it counts toward CI's bound. The digest recorded is of the bytes
//! the compare used, never of a golden read before the run: a blessing run
//! can rewrite the golden between the two reads, and the cache must say
//! what the program showed. A run that fails writes nothing. Pending mode
//! never looks and never writes. A blessing run (`BENI_WRITE_EXPECTED=1`)
//! writes no digest for the build it blesses — a golden written from the
//! output is no verdict — but the other passes of the fixture, compared
//! with the golden it just wrote as always, are verified and recorded.
//! There is no recording mode. And the cache is a cache: when its
//! directory cannot be read or written, one warning is printed, every
//! program runs and nothing is recorded (`verified`, `record`). A record
//! file that comes back into the corpus (`<fixture>.run-hash`,
//! `.release-run-hash`, `.fuzz-run-hash`, or `tests/blackbox/run-hashes.txt`)
//! fails the walk by name, with its fix (`corpus_test.zig`, `isRecordFile`).
//!
//! **What a digest covers.** For a corpus `run/` build (`digest`): the
//! build's name (`dev`, `release`, …), the Node version (`process.version`
//! of the `node` on `PATH`), the name and bytes of the golden the output
//! is compared with, and every file of the emitted output tree — its path
//! relative to `--out` and its bytes, in sorted path order — except
//! `_manifest.txt`, which lists the other files' hashes and is never run.
//! Every field is length-prefixed, so no two different inputs feed the
//! hash the same bytes. A `browser/` page's digest (`digestWith`,
//! `browser.zig`) covers the DOM's name and version, its bytes, the
//! driver's and the steps as well; a Worker's (`workers.zig`) the driver,
//! the script and the Wrangler configuration; a served program's
//! (`serve.zig`) the driver, the preload and the requests. Any change to
//! one of them — a new emitter, a new `core/`, an edited golden, another
//! Node, an edited driver — makes the digest differ and the program run
//! again.
//!
//! **Programs a black-box scenario runs** (`World.expectProgram`, *Program
//! runs* below). The expectation is written in the test's code rather than
//! in a golden, so it is fed to the digest itself: the exit code, stdout
//! and stderr the scenario expects, with the Node version, how Node is
//! invoked (the script's path; the environment is always empty and stdin
//! closed) and the emitted output tree — the same things a `run/` digest
//! covers. That tree is the directory holding the script, which is where
//! a build writes its entry. A script in the project directory has no such
//! directory. The project also holds the sources and `.beni-cache`, and a
//! cache entry names the compiler that wrote it, so walking the project
//! would stale the digest on every compiler change even when the emitted
//! JavaScript is identical. The digest then covers the script's own bytes
//! and every emitted output tree, and nothing else in the project.
//!
//! **The counts.** Each process given `BENI_RUN_HASH_REPORT=<dir>` writes
//! there how many of its runs were skipped and how many ran for want of a
//! verified digest, and `tests/run_hash_summary.zig` prints them as one
//! line after the last process: information, never a failure.
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

/// The environment variable that names the cache directory. Unset or
/// empty: no cache.
pub const dir_env = "BENI_RUN_HASH_DIR";

/// The file of the output tree the digest leaves out: the build's own list
/// of what it wrote, with a hash per file, which Node never loads.
pub const manifest = "_manifest.txt";

/// The build cache's default directory (`src/cache/Dir.zig`'s
/// `default_path`). A project-root script's walk skips it: the entries are
/// not emitted output, so reading them would only be thrown away.
const cache_dir = ".beni-cache";

/// First line of a beni `_manifest.txt` (`backend.md` §2). A directory
/// holding one is an emitted output tree.
const manifest_header = "beni-manifest 1\n";

/// The length of a digest: a SHA-256 as lower-case hex, which is also the
/// name of its file in the cache.
pub const digest_len = Sha256.digest_length * 2;

/// The digest of the program `w` just built into `out_dir`, as build
/// `pass`, compared against `golden_name` holding `golden`. Owned by
/// `arena`.
pub fn digest(
    arena: Allocator,
    w: *World,
    out_dir: []const u8,
    pass: []const u8,
    golden_name: []const u8,
    golden: []const u8,
) ![]const u8 {
    return digestWith(arena, w, out_dir, pass, golden_name, golden, null);
}

/// What a digest covers beyond a `run/` build's: the `browser/` kind's
/// page (`browser.zig`), whose verdict also depends on the DOM the program
/// ran in and the script that drove it; a Worker's run (`workers.zig`); a
/// served program's requests (`serve.zig`).
pub const Page = struct {
    /// The host's name and version: `happy-dom-20.14.5`, the Chrome
    /// `test-browser` runs in, `workers`, `serve`.
    dom: []const u8,
    /// Everything else the run read, each fed to the digest by name: the
    /// DOM's bytes, the driver's, the steps.
    inputs: []const Input,

    pub const Input = struct { name: []const u8, bytes: []const u8 };
};

/// `digest` for a build whose run also depends on `page`, when there is
/// one. A `run/` build (`page` null) gets exactly `digest`'s digest.
pub fn digestWith(
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
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    return arena.dupe(u8, &hex);
}

fn feed(h: *Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
}

// ---------------------------------------------------------------------------
// The cache
// ---------------------------------------------------------------------------

var dir_mutex: Io.Mutex = .init;
var dir_read = false;
var dir_value: ?[]const u8 = null;

/// The cache directory, read once per process from `BENI_RUN_HASH_DIR`;
/// null when it is unset or empty, and then nothing is looked up or
/// written.
fn cacheDir(io: Io) ?[]const u8 {
    dir_mutex.lockUncancelable(io);
    defer dir_mutex.unlock(io);
    if (!dir_read) {
        dir_read = true;
        const value = std.testing.environ.getAlloc(std.heap.page_allocator, dir_env) catch "";
        if (value.len != 0) dir_value = value;
    }
    return dir_value;
}

/// The path of `digest_hex`'s file in the cache at `dir`.
fn entryPath(buffer: []u8, dir: []const u8, digest_hex: []const u8) ![]const u8 {
    // The digest is the file's name: anything else would name a file the
    // caller did not mean.
    if (digest_hex.len != digest_len) return error.MalformedDigest;
    for (digest_hex) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return error.MalformedDigest;
    return try std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir, digest_hex });
}

/// Whether the cache holds `digest_hex`: a run with this digest ran and
/// matched before. Always false without a cache, and false when the cache
/// cannot be read (one warning per process): a cache that fails is no
/// cache, never a verdict. A malformed digest is the harness's own bug,
/// not the cache's, and stays an error.
pub fn verified(io: Io, digest_hex: []const u8) error{MalformedDigest}!bool {
    const dir = cacheDir(io) orelse return false;
    return verifiedIn(io, dir, digest_hex) catch |err| switch (err) {
        error.MalformedDigest => return error.MalformedDigest,
        else => {
            warnOnce(dir, "read", err);
            return false;
        },
    };
}

/// `verified`, in the cache at `dir`.
pub fn verifiedIn(io: Io, dir: []const u8, digest_hex: []const u8) !bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try entryPath(&buffer, dir, digest_hex);
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Put `digest_hex` into the cache: the run it names ran and matched.
/// Atomic — a named temporary file in the directory, then a rename over
/// the final name — so two processes that record the same digest at once
/// both succeed, and a reader never sees a half-written entry (there is
/// nothing to half-write: the file is empty, its name is the record). The
/// directory is created when it does not exist. Nothing without a cache,
/// and a cache that cannot be written loses the entry with one warning per
/// process: the program passed, and the cache is not the verdict. A
/// malformed digest stays an error, as in `verified`.
pub fn record(io: Io, digest_hex: []const u8) error{MalformedDigest}!void {
    const dir = cacheDir(io) orelse return;
    recordIn(io, dir, digest_hex) catch |err| switch (err) {
        error.MalformedDigest => return error.MalformedDigest,
        else => warnOnce(dir, "written", err),
    };
}

var warned = false;

/// Say once per process that the cache at `dir` cannot be `what`.
fn warnOnce(dir: []const u8, what: []const u8, err: anyerror) void {
    if (@atomicRmw(bool, &warned, .Xchg, true, .monotonic)) return;
    std.debug.print("run-hash cache: {s} cannot be {s} ({t}); every program runs and nothing is recorded\n", .{ dir, what, err });
}

/// `record`, into the cache at `dir`.
pub fn recordIn(io: Io, dir: []const u8, digest_hex: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try entryPath(&buffer, dir, digest_hex);
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    try atomic.replace(io);
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
// looked up in the cache, and a verified one means Node already ran exactly
// this output tree, under exactly this Node, and it did exactly what the
// scenario expects now.
// ---------------------------------------------------------------------------

/// Run `node <script>` for `w` and compare what it did with `expected`,
/// unless the cache holds this run's digest. Null when the program did what
/// `expected` says (or was verified before); else what it did. A run that
/// matched is recorded.
pub fn checkProgram(w: *World, script: []const u8, expected: world.Expected) !?world.Result {
    const arena = w.arena.allocator();
    // Taken before Node runs, so nothing the program does can change it.
    const digest_hex = try programDigest(arena, w, script, expected);
    if (digest_hex) |d| if (try verified(w.io, d)) {
        report(w.io, .skipped);
        return null;
    };
    report(w.io, .stale);
    const got = try w.node(script);
    if (!matches(got, expected)) return got;
    if (digest_hex) |d| try record(w.io, d);
    return null;
}

/// A scenario's run whose digest the caller makes (`page_fuzz_test.zig`'s
/// fuzz runs, whose inputs are two output trees and the harness's files):
/// `digest_hex` must cover everything the verdict depends on, the
/// expectation included. Checked against the cache as `checkProgram`'s
/// runs are: null when the cache holds it, else `run(context)`, whose
/// result says whether the run did what was expected, and is recorded
/// when it did.
pub fn checkDigested(w: *World, digest_hex: []const u8, context: anytype, comptime run: fn (@TypeOf(context)) anyerror!bool) !?bool {
    if (try verified(w.io, digest_hex)) {
        report(w.io, .skipped);
        return null;
    }
    report(w.io, .stale);
    const ok = try run(context);
    if (ok) try record(w.io, digest_hex);
    return ok;
}

/// The hex SHA-256 of `parts`, each length-prefixed: a digest for
/// `checkDigested`.
pub fn digestOf(arena: Allocator, parts: []const []const u8) ![]const u8 {
    var h = Sha256.init(.{});
    feed(&h, "beni digested-run 1");
    for (parts) |p| feed(&h, p);
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    return arena.dupe(u8, &hex);
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

/// `checkProgram`'s digest of one run of `script`, for the test that shows
/// what a scenario's run hash covers. Null when the run has no output to
/// cover (`programDigest`).
pub fn programRunDigest(w: *World, script: []const u8, expected: world.Expected) !?[]const u8 {
    return programDigest(w.arena.allocator(), w, script, expected);
}

/// The hex digest of one program run: the Node version, the script's path,
/// the expectation, and every file of the emitted output tree but
/// `_manifest.txt`. The tree is the directory holding `script`. A script in
/// the project directory has none — that directory also holds the sources
/// and `.beni-cache` — so the digest covers the script's own bytes and
/// every directory whose `_manifest.txt` is a beni manifest instead. Null
/// when nothing was covered, which only a build that wrote nothing leaves:
/// such a run is never skipped nor recorded, and Node reports the missing
/// script.
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
    const fed = try feedProgramFiles(&h, arena, w, script);
    if (fed == 0) return null;
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    return try arena.dupe(u8, &hex);
}

/// Feed the files a program run's digest covers, and how many there were.
/// A script inside a directory covers that directory, which is the output
/// tree. A script in the project directory covers its own bytes and every
/// emitted output tree, not the project.
fn feedProgramFiles(h: *Sha256, arena: Allocator, w: *World, script: []const u8) !usize {
    if (std.fs.path.dirname(script)) |dir| {
        if (!std.mem.eql(u8, dir, ".")) return feedTree(h, arena, w, dir);
    }
    return feedProjectProgram(h, arena, w, script);
}

/// Every file of `dir` but `_manifest.txt`, each as its path relative to
/// `dir` and its bytes. This is the whole coverage of a script that lives
/// in the output tree, and it is what a `run/` digest hashes of that tree.
fn feedTree(h: *Sha256, arena: Allocator, w: *World, dir: []const u8) !usize {
    const files = try w.listFiles(dir);
    var fed: usize = 0;
    for (files) |rel| {
        if (std.mem.eql(u8, rel, manifest)) continue;
        const full = try std.fs.path.join(arena, &.{ dir, rel });
        try feedFile(h, w, full, rel);
        fed += 1;
    }
    return fed;
}

/// The script's own bytes, and every file of every emitted output tree in
/// the project, each as its path relative to the project. `.beni-cache` is
/// not walked: its entries are not output, and a walk would read the
/// compiler's cache on the way to ignoring it. A `--cache-dir` somewhere
/// else is walked. That is fine: the project is the scenario's temporary
/// directory, and a directory contributes files only when its
/// `_manifest.txt` is a beni manifest.
fn feedProjectProgram(h: *Sha256, arena: Allocator, w: *World, script: []const u8) !usize {
    const files = try projectFiles(arena, w);
    var roots: std.ArrayList([]const u8) = .empty;
    for (files) |rel| {
        const root = manifestRoot(rel) orelse continue;
        if (!try isBeniManifest(w, rel)) continue;
        // No scenario builds into the project directory (`--out=.`). The
        // only project-root script is `check.mjs`, and it builds into
        // `out/`. A manifest here would cover the project's top-level
        // files and miss nested output such as `_core/`.
        if (root.len == 0) return error.ProjectRootOutput;
        try roots.append(arena, root);
    }
    var chosen: std.ArrayList([]const u8) = .empty;
    for (files) |rel| {
        if (std.mem.eql(u8, rel, script) or inEmittedTree(rel, roots.items)) try chosen.append(arena, rel);
    }
    std.mem.sort([]const u8, chosen.items, {}, pathLessThan);
    var fed: usize = 0;
    for (chosen.items) |rel| {
        try feedFile(h, w, rel, rel);
        fed += 1;
    }
    return fed;
}

fn feedFile(h: *Sha256, w: *World, path: []const u8, name: []const u8) !void {
    const bytes = try w.tmp.dir.readFileAlloc(w.io, path, w.gpa, .limited(world.max_stream_bytes));
    defer w.gpa.free(bytes);
    feed(h, name);
    feed(h, bytes);
}

/// Every file under the project, sorted, except anything inside the build
/// cache. Paths are relative to the project.
fn projectFiles(arena: Allocator, w: *World) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try collectProject(arena, w, "", &out);
    std.mem.sort([]const u8, out.items, {}, pathLessThan);
    return out.items;
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectProject(arena: Allocator, w: *World, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    const full = if (prefix.len == 0) "." else prefix;
    // A directory that vanished between the listing and this open is not
    // there to hash. Anything else — permissions, a full file-descriptor
    // table — must fail the digest: skipping it would cover fewer files
    // and still report success.
    var dir = w.tmp.dir.openDir(w.io, full, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(w.io);
    var it = dir.iterate();
    while (try it.next(w.io)) |entry| {
        if (prefix.len == 0 and std.mem.eql(u8, entry.name, cache_dir)) continue;
        const rel = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try collectProject(arena, w, rel, out),
            .file => try out.append(arena, rel),
            // A symlink is not followed. The build writes regular files,
            // and following a link could leave the project.
            else => {},
        }
    }
}

/// The output directory a `_manifest.txt` at `rel` records, or null when
/// `rel` is not that file. Empty when the manifest is the project itself
/// (`--out=.`), which `feedProjectProgram` refuses.
fn manifestRoot(rel: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, rel, manifest)) return "";
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return null;
    if (!std.mem.eql(u8, rel[slash + 1 ..], manifest)) return null;
    return rel[0..slash];
}

fn isBeniManifest(w: *World, rel: []const u8) !bool {
    const bytes = w.tmp.dir.readFileAlloc(w.io, rel, w.gpa, .limited(world.max_stream_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer w.gpa.free(bytes);
    return std.mem.startsWith(u8, bytes, manifest_header);
}

/// Whether `rel` is a file of an emitted output tree: under one of `roots`,
/// and not the tree's own `_manifest.txt`. No root is empty: a manifest at
/// the project root is `error.ProjectRootOutput`.
fn inEmittedTree(rel: []const u8, roots: []const []const u8) bool {
    if (std.mem.eql(u8, std.fs.path.basename(rel), manifest)) return false;
    for (roots) |root| {
        if (rel.len > root.len and rel[root.len] == '/' and std.mem.startsWith(u8, rel, root)) return true;
    }
    return false;
}

/// What this process's program runs did, for `tests/run_hash_summary.zig`.
const Report = struct {
    /// Not run: the cache held the digest.
    skipped: u32 = 0,
    /// Run under Node, because it did not.
    stale: u32 = 0,
    /// `<dir>/program-<random hex>.txt`, this process's file; empty until
    /// the first report.
    path: []const u8 = "",
};
var report_mutex: Io.Mutex = .init;
var report_state: Report = .{};

const Event = enum { skipped, stale };

/// Count one program run, then rewrite this process's report file under
/// `BENI_RUN_HASH_REPORT` (nothing when it is unset). Rewritten whole each
/// time, because nothing runs when a test process ends, so the file must
/// always be complete.
fn report(io: Io, event: Event) void {
    report_mutex.lockUncancelable(io);
    defer report_mutex.unlock(io);
    const r = &report_state;
    switch (event) {
        inline else => |e| @field(r, @tagName(e)) += 1,
    }
    writeReport(io, r) catch |err| {
        std.debug.print("BENI_RUN_HASH_REPORT: cannot write this process's program runs: {t}\n", .{err});
    };
}

fn writeReport(io: Io, r: *Report) !void {
    const gpa = std.heap.page_allocator;
    if (r.path.len == 0) {
        const dir = std.testing.environ.getAlloc(gpa, "BENI_RUN_HASH_REPORT") catch return;
        if (dir.len == 0) return;
        try Io.Dir.cwd().createDirPath(io, dir);
        var random: [8]u8 = undefined;
        io.random(&random);
        r.path = try std.fmt.allocPrint(gpa, "{s}/program-{x}.txt", .{ dir, &random });
    }
    var buffer: [128]u8 = undefined;
    const counts = try std.fmt.bufPrint(&buffer, "program_skipped {d}\nprogram_stale {d}\n", .{ r.skipped, r.stale });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = r.path, .data = counts });
}
