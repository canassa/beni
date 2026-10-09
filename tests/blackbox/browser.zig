//! The `browser/` corpus kind's harness: where its driver, its DOM and its
//! test platform are, and the headless Chrome `zig build test-browser`
//! runs the same fixtures in (tests/corpus/README.md, `browser/`).
//!
//! A fixture is built like a `run/` one, for the `page` test platform
//! (`tests/platforms/page`) unless it carries a `platform/` of its own, and
//! then `tests/browser/driver.mjs` loads the build into a page, runs the
//! fixture's `.steps` against it and prints what the page showed after each
//! step; that transcript is the golden. The gates run the page in Node under
//! happy-dom, vendored as one file (`tests/browser/vendor.sh`), so they need
//! neither a browser nor the network; `test-browser` runs it in Chrome.
//!
//! **Why happy-dom, and not linkedom, jsdom or Chrome, in the gates.**
//! Measured on a Ryzen 9 5950X with Node 24.19, a fixture-sized page
//! (mount, three clicks, serialise) in a fresh process, CPU per page: bare
//! Node 30 ms; linkedom 0.18 bundled into one file 56 (151 from
//! `node_modules`); happy-dom 20.14 bundled 115 (336 from `node_modules`);
//! jsdom 30.1, from `node_modules`, 705. One headless Chrome 153 with a
//! fresh target per page: 32 ms of wall time a page one at a time, 20 at 8
//! in flight, 36 ms of CPU, after 0.7 s of CPU to start. Across the harness
//! itself, 24 fixtures (48 builds and pages) on 8 workers took 1.2 s of wall
//! time and 8.9 s of CPU under happy-dom, 2.3 s and 11.1 s in Chromium
//! 153. Chrome is not in the flake's default shell
//! (Chromium is 454 MiB, and Linux only), a skip without it would leave the
//! gates unproven on most machines, and a browser shared by every case has
//! no place in a per-case instruction budget. Against Chrome, on eight
//! probes — `<!>` in a template, a `<table>` without `<tbody>`,
//! `<p><div>`, `<template>`'s content, an input's `value` against its
//! attribute, a checkbox's activation, focus, and an exception in a
//! listener — happy-dom differed on one (the empty `<p></p>` the parser
//! makes after a misnested `</p>`) and linkedom on seven, including
//! dropping everything after a `<!>`, the marker the `dom` lowering's
//! templates are made of. So the gates pay about 60 ms of CPU more per
//! page than linkedom would cost for a DOM that behaves like the browser,
//! and the run hashes below keep them from paying it for a page already
//! verified. A case's two pages, its development and release builds', run
//! in one Node process (`driveAll`): Node starting and compiling happy-dom
//! is about 500 million instructions of a page's 550 to 600 on a TodoMVC-
//! sized program, and the second page does not pay it again.
//!
//! **Run hashes.** A browser build's record line is
//! `<pass> <node version> <dom> <sha-256>` (`run_hash.lineWith`): the
//! digest covers what a `run/` one does — the output tree, the golden, the
//! Node version — plus the DOM's name and checksum, the driver's bytes and
//! the steps, so a change to any of them runs the page again.

const std = @import("std");
const world = @import("world.zig");
const run_hash = @import("run_hash.zig");
const World = world.World;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The driver, relative to the repository root.
pub const driver_path = "tests/browser/driver.mjs";

/// The page fuzzer (browser-direct.md §8.3), relative to the repository
/// root: two builds of one program, random sequences, the pages compared
/// after every step (`fuzz`).
pub const fuzz_path = "tests/browser/fuzz.mjs";

/// The vendored DOM, its name and version, and the SHA-256 of its bytes,
/// which `tests/browser/vendor.sh` prints when it writes the file.
pub const dom_path = "tests/browser/happy-dom.mjs";
pub const dom_id = "happy-dom-20.14.5";
pub const dom_sha256 = "7e09361e2353bc4bb2766b7b39754466aa37b40157c31c94cf4422bbb7aa616d";

/// The platform a fixture without a `platform/` directory is built for.
pub const platform_path = "tests/platforms/page";

/// Where a fixture's project holds its copy of `platform_path`'s files.
///
/// **Copied, never named by its path in the repository.** A development
/// build's source maps name each `.beni` file by its path from the map
/// (`backend.md` §11.1), and the project lives under `/dev/shm` or
/// `.zig-cache/tmp`, so a platform named at its place in the checkout put
/// the checkout's absolute path into `_platform/Page.mjs.map` — and into
/// the run hash, which then differed between the main checkout and every
/// worktree. In the project, the map says `../platform/Page.beni`
/// wherever the repository is.
pub const platform_dir = "platform";

/// The harness's files, resolved once per process from the working
/// directory, which is the repository root in every run the build makes.
pub const Harness = struct {
    /// Absolute paths, for a driver that runs in a test's project
    /// directory.
    driver: []const u8,
    dom: []const u8,
    /// `platform_path`'s files, each named by its path inside it, for a
    /// fixture to copy into `platform_dir`.
    platform: []const run_hash.Page.Input,
    driver_bytes: []const u8,
    fuzz_bytes: []const u8,
};

var harness_mutex: Io.Mutex = .init;
var harness_value: ?Harness = null;

/// The harness, after checking that the vendored DOM is the file its
/// checksum names: an edited or truncated DOM would otherwise be a silent
/// change to what every browser fixture ran in.
pub fn harness(io: Io) !Harness {
    harness_mutex.lockUncancelable(io);
    defer harness_mutex.unlock(io);
    if (harness_value) |h| return h;
    const gpa = std.heap.page_allocator;
    const dom_bytes = try Io.Dir.cwd().readFileAlloc(io, dom_path, gpa, .limited(world.max_stream_bytes));
    defer gpa.free(dom_bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(dom_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, dom_sha256)) {
        std.debug.print(
            "{s} has SHA-256 {s}, not the {s} of {s}: it is generated by tests/browser/vendor.sh and never edited by hand\n",
            .{ dom_path, &hex, dom_sha256, dom_id },
        );
        return error.DomChecksumMismatch;
    }
    harness_value = .{
        .driver = try Io.Dir.cwd().realPathFileAlloc(io, driver_path, gpa),
        .dom = try Io.Dir.cwd().realPathFileAlloc(io, dom_path, gpa),
        .platform = try readPlatform(io, gpa),
        .driver_bytes = try Io.Dir.cwd().readFileAlloc(io, driver_path, gpa, .limited(world.max_stream_bytes)),
        .fuzz_bytes = try Io.Dir.cwd().readFileAlloc(io, fuzz_path, gpa, .limited(world.max_stream_bytes)),
    };
    return harness_value.?;
}

/// Every file under `platform_path`, with its path inside it.
fn readPlatform(io: Io, gpa: Allocator) ![]const run_hash.Page.Input {
    var dir = try Io.Dir.cwd().openDir(io, platform_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var files: std.ArrayList(run_hash.Page.Input) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try files.append(gpa, .{
            .name = try gpa.dupe(u8, entry.path),
            .bytes = try dir.readFileAlloc(io, entry.path, gpa, .limited(world.max_stream_bytes)),
        });
    }
    return files.toOwnedSlice(gpa);
}

/// Write the `page` platform into `w`'s project as `platform_dir`.
pub fn writePlatform(arena: Allocator, w: *World, h: Harness) !void {
    for (h.platform) |file| try w.write(try std.fs.path.join(arena, &.{ platform_dir, file.name }), file.bytes);
}

/// What a browser build's record line covers besides the output tree and
/// the golden (`run_hash.lineWith`).
pub fn page(arena: Allocator, h: Harness, steps: []const u8) !run_hash.Page {
    return .{ .dom = dom_id, .inputs = try arena.dupe(run_hash.Page.Input, &.{
        .{ .name = "dom sha-256", .bytes = dom_sha256 },
        .{ .name = "driver", .bytes = h.driver_bytes },
        .{ .name = "steps", .bytes = steps },
    }) };
}

/// `node <driver> --dom=<dom> <entry> [<steps>]` in `w`'s project, or with
/// `--chrome=<endpoint>` for a page in the Chrome at that endpoint.
pub fn drive(
    w: *World,
    h: Harness,
    chrome: ?[]const u8,
    entry: []const u8,
    steps: ?[]const u8,
    timeout_ms: i64,
) !world.Result {
    const arena = w.arena.allocator();
    const node = w.node_exe orelse return error.NodeNotOnPath;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ node, h.driver });
    try argv.append(arena, if (chrome) |endpoint|
        try std.fmt.allocPrint(arena, "--chrome={s}", .{endpoint})
    else
        try std.fmt.allocPrint(arena, "--dom={s}", .{h.dom}));
    try argv.append(arena, entry);
    if (steps) |s| try argv.append(arena, s);
    return world.spawnAndCapture(arena, w.gpa, w.io, argv.items, .{ .dir = w.tmp.dir }, timeout_ms);
}

/// What `driveAll` gives: the driver's own run, and per page what a run of
/// that page alone would have given — null for a page the run stopped
/// before (a timeout, a crash of the driver), which `run` explains.
pub const Pages = struct {
    run: world.Result,
    pages: []?world.Result,
};

/// One page `driveAll` runs: the entry file, and whether the page asks the
/// build's test hook to run every listener subscription in a fiber (the
/// driver's `--fiber-page`; `boundary.md` §9.8.5) — or, `fuzz` set, a run
/// of the page fuzzer whose spec is the file at `path` (the driver's
/// `--fuzz`; `writeFuzzSpec`).
pub const Entry = struct { path: []const u8, fiber: bool = false, fuzz: bool = false };

/// The test hook's name in a development build of `browser-tea`
/// (`Hosted.fibered`): a build that does not contain it has no listener
/// subscription for `--fiber-page` to change.
pub const fiber_hook = "__beniFiberSubscriptions";

/// Every page of `entries`, one after another in ONE Node process, each in
/// a fresh page (the driver's `--page`): Node starts and compiles the DOM
/// once for all of them, and each page's exit code, stdout and stderr are
/// what `drive` of it alone would give. Each page may take `timeout_ms`.
pub fn driveAll(
    w: *World,
    h: Harness,
    chrome: ?[]const u8,
    entries: []const Entry,
    steps: ?[]const u8,
    timeout_ms: i64,
) !Pages {
    const arena = w.arena.allocator();
    const node = w.node_exe orelse return error.NodeNotOnPath;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ node, h.driver });
    try argv.append(arena, if (chrome) |endpoint|
        try std.fmt.allocPrint(arena, "--chrome={s}", .{endpoint})
    else
        try std.fmt.allocPrint(arena, "--dom={s}", .{h.dom}));
    if (steps) |s| try argv.append(arena, try std.fmt.allocPrint(arena, "--steps={s}", .{s}));
    const reports = try arena.alloc([]const u8, entries.len);
    for (entries, reports, 0..) |entry, *report, i| {
        report.* = try std.fmt.allocPrint(arena, "_page{d}.json", .{i});
        w.tmp.dir.deleteFile(w.io, report.*) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try argv.append(arena, try std.fmt.allocPrint(arena, "--{s}={s}@{s}", .{
            if (entry.fuzz) "fuzz" else if (entry.fiber) "fiber-page" else "page", entry.path, report.*,
        }));
    }
    const run = try world.spawnAndCapture(arena, w.gpa, w.io, argv.items, .{ .dir = w.tmp.dir }, timeout_ms * @as(i64, @intCast(entries.len)));
    const pages = try arena.alloc(?world.Result, entries.len);
    for (reports, pages) |report, *slot| {
        slot.* = null;
        const bytes = w.tmp.dir.readFileAlloc(w.io, report, arena, .limited(world.max_stream_bytes)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const Report = struct { code: u8, stdout: []const u8, stderr: []const u8 };
        // A report cut short: the run stopped while writing it.
        const r = std.json.parseFromSliceLeaky(Report, arena, bytes, .{}) catch continue;
        slot.* = .{
            .exit_code = r.code,
            .term = .{ .exited = r.code },
            .stdout = r.stdout,
            .stderr = r.stderr,
            .diagnostics = &.{},
        };
    }
    return .{ .run = run, .pages = pages };
}

/// One run of the page fuzzer (`tests/browser/fuzz.mjs`,
/// browser-direct.md §8.3): two builds of a program, output directories of
/// `w`'s project, replayed against each other on random sequences.
pub const Fuzz = struct {
    a: []const u8,
    b: []const u8,
    /// How the report names each build.
    label_a: []const u8,
    label_b: []const u8,
    /// The `beni dump --stage=writes --msg-types` output, a file of the
    /// project, when both builds take messages as values: development
    /// builds of `browser-tea`, or `--fuzz` builds.
    types: ?[]const u8 = null,
    /// The fixture's `.steps`, a file of the project: the answers it gives
    /// its requests, which the fuzzer gives too.
    script: ?[]const u8 = null,
    /// Patterns of the log lines the two builds may differ on, and nothing
    /// else (`fuzz.mjs`'s `ignore`).
    ignore: []const []const u8 = &.{},
    /// Whether the two builds' crash screens are the same, so a body is
    /// compared after both threw.
    crash: enum { same, own } = .own,
    /// Play the first seed twice on build `a` and fail when the two
    /// disagree: set wherever the verdict may be recorded, so a page that
    /// does not replay itself never passes into a record. Not part of the
    /// record's digest: it changes no verdict of a page that replays.
    replay: bool = false,
    /// A line the report begins with: why this pair's fuzz is what it is
    /// (a `browser/direct/` pair whose value fuzz runs in the sweep only).
    note: ?[]const u8 = null,
    /// The seeds, `1,2,…`, and the steps of each sequence.
    seeds: []const u8 = gate_seeds,
    steps: u32 = gate_steps,
};

/// What the gates run: one fixed seed of thirty steps, so a run's verdict
/// is a function of its inputs and its record can stand for it. One seed
/// and not two of fifteen: a page and its module graph cost more than
/// fifteen steps, and `browser/tea/ApiAndRoutes`, whose two builds take
/// 3.4 of its 4.3 billion instructions, has room for two pages only.
/// `zig build fuzz` runs fifty seeds (`BENI_FUZZ_SEEDS`, `BENI_FUZZ_STEPS`).
pub const gate_seeds = "1";
pub const gate_steps = 30;

/// The spec `fuzz.mjs` reads, for `f`: JSON, every path relative to the
/// project.
pub fn fuzzSpec(arena: Allocator, f: Fuzz) ![]const u8 {
    for (f.seeds) |ch| if (!std.ascii.isDigit(ch) and ch != ',') return error.BadFuzzSeeds;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"a\":{f},\"b\":{f},\"labelA\":{f},\"labelB\":{f},\"types\":", .{
        std.json.fmt(try std.fmt.allocPrint(arena, "{s}/_main.mjs", .{f.a}), .{}),
        std.json.fmt(try std.fmt.allocPrint(arena, "{s}/_main.mjs", .{f.b}), .{}),
        std.json.fmt(f.label_a, .{}),
        std.json.fmt(f.label_b, .{}),
    });
    if (f.types) |t| try w.print("{f},\"values\":true", .{std.json.fmt(t, .{})}) else try w.writeAll("null,\"values\":false");
    try w.writeAll(",\"script\":");
    if (f.script) |s| try w.print("{f}", .{std.json.fmt(s, .{})}) else try w.writeAll("null");
    try w.print(",\"ignore\":{f},\"crash\":\"{t}\",\"replay\":{}", .{ std.json.fmt(f.ignore, .{}), f.crash, f.replay });
    try w.writeAll(",\"note\":");
    if (f.note) |n| try w.print("{f}", .{std.json.fmt(n, .{})}) else try w.writeAll("null");
    try w.print(",\"seeds\":[{s}],\"steps\":{d},\"shrink\":true}}\n", .{ f.seeds, f.steps });
    return out.written();
}

/// Write `f`'s spec into `w`'s project as `name`, for a `driveAll` entry
/// (`.{ .path = name, .fuzz = true }`).
pub fn writeFuzzSpec(arena: Allocator, w: *World, f: Fuzz, name: []const u8) !void {
    try w.write(name, try fuzzSpec(arena, f));
}

/// `f` alone, in a Node process of its own: what its report says.
pub fn fuzz(w: *World, h: Harness, chrome: ?[]const u8, f: Fuzz, timeout_ms: i64) !world.Result {
    const arena = w.arena.allocator();
    try writeFuzzSpec(arena, w, f, "_fuzz.json");
    const r = try driveAll(w, h, chrome, &.{.{ .path = "_fuzz.json", .fuzz = true }}, null, timeout_ms);
    if (r.pages[0]) |report| return report;
    std.debug.print("the page fuzzer's driver stopped before its report\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ r.run.stdout, r.run.stderr });
    return error.FuzzReportMissing;
}

/// The record line of a fuzz run that agreed (`run_hash.lineWith`, pass
/// `fuzz`): it covers build `a`'s output tree as a page's line covers its
/// build, and as inputs the DOM, the driver, the fuzzer, build `b`'s tree,
/// the message types, the script and the spec.
pub fn fuzzLine(arena: Allocator, w: *World, h: Harness, f: Fuzz) ![]const u8 {
    const b_line = try run_hash.lineWith(arena, w, f.b, "tree", "", "", null);
    const types: []const u8 = if (f.types) |t| try w.read(t) else "";
    const script: []const u8 = if (f.script) |s| try w.read(s) else "";
    var digested = f;
    digested.replay = false;
    return run_hash.lineWith(arena, w, f.a, "fuzz", "spec", try fuzzSpec(arena, digested), .{ .dom = dom_id, .inputs = try arena.dupe(run_hash.Page.Input, &.{
        .{ .name = "dom sha-256", .bytes = dom_sha256 },
        .{ .name = "driver", .bytes = h.driver_bytes },
        .{ .name = "fuzz", .bytes = h.fuzz_bytes },
        .{ .name = "b", .bytes = b_line[std.mem.lastIndexOfScalar(u8, b_line, ' ').? + 1 ..] },
        .{ .name = "types", .bytes = types },
        .{ .name = "script", .bytes = script },
    }) });
}

/// The Chrome `test-browser` runs pages in: `BENI_CHROME` when it is set
/// and not empty, else the first of `chromium`, `google-chrome-stable` and
/// `google-chrome` on `PATH` (`nix develop .#browser` puts Chromium there).
pub fn findChrome(arena: Allocator, io: Io) ?[]const u8 {
    const given = std.testing.environ.getAlloc(arena, "BENI_CHROME") catch "";
    if (given.len != 0) return given;
    const path = std.testing.environ.getAlloc(arena, "PATH") catch return null;
    for ([_][]const u8{ "chromium", "google-chrome-stable", "google-chrome" }) |name| {
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return null;
            Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            return candidate;
        }
    }
    return null;
}

/// One headless Chrome for a whole `test-browser` walk; every page is a
/// fresh target in it (research 26 §9: one browser per run is fifteen
/// times cheaper than one per fixture). Its profile is a directory of its
/// own, and it listens on a port it picks, on the loopback interface only.
pub const Chrome = struct {
    child: std.process.Child,
    profile: World,
    /// `ws://127.0.0.1:<port>/devtools/browser/<id>`.
    endpoint: []const u8,

    /// How long Chrome may take to start listening.
    const start_timeout_ms = 30_000;

    pub fn launch(gpa: Allocator, io: Io, exe: []const u8) !Chrome {
        var profile = try World.init(gpa, io);
        errdefer profile.deinit();
        const arena = profile.arena.allocator();
        const dir = try profile.projectPath();
        const log = try profile.tmp.dir.createFile(io, "chrome.log", .{});
        defer log.close(io);
        var child = std.process.spawn(io, .{
            .argv = &.{
                exe,
                "--headless=new",
                "--remote-debugging-port=0",
                try std.fmt.allocPrint(arena, "--user-data-dir={s}/profile", .{dir}),
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-gpu",
                // A page loads the program's modules from the file system.
                "--allow-file-access-from-files",
                "--disable-extensions",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-sync",
                "--mute-audio",
                // A target nobody looks at still runs its timers at speed.
                "--disable-background-timer-throttling",
                "--disable-renderer-backgrounding",
                "--disable-backgrounding-occluded-windows",
                "about:blank",
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = log },
        }) catch |err| {
            std.debug.print("cannot start Chrome at {s}: {t}\n", .{ exe, err });
            return err;
        };
        errdefer child.kill(io);
        const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(start_timeout_ms));
        while (true) {
            // Chrome writes the port and the browser target's path here once
            // it listens.
            if (profile.read("profile/DevToolsActivePort")) |text| {
                var lines = std.mem.splitScalar(u8, text, '\n');
                const port = lines.next() orelse "";
                const target = lines.next() orelse "";
                if (port.len != 0 and std.mem.startsWith(u8, target, "/devtools/browser/")) {
                    return .{
                        .child = child,
                        .profile = profile,
                        .endpoint = try std.fmt.allocPrint(arena, "ws://127.0.0.1:{s}{s}", .{ port, target }),
                    };
                }
            } else |_| {}
            if (Io.Timestamp.now(io, .awake).durationTo(deadline).toMilliseconds() <= 0) {
                std.debug.print("{s} did not start listening within {d} ms; its log:\n{s}\n", .{
                    exe, start_timeout_ms, profile.read("chrome.log") catch "",
                });
                return error.ChromeDidNotStart;
            }
            try io.sleep(.fromMilliseconds(20), .awake);
        }
    }

    /// Stop Chrome and remove its profile.
    pub fn deinit(chrome: *Chrome, io: Io) void {
        chrome.child.kill(io);
        chrome.profile.deinit();
    }
};
