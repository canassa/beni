//! Build graph for beni (docs/design/frontend.md §2).
//!
//! Steps, all of which must stay green at the end of every milestone:
//!   zig build                 install `beni`
//!   zig build test            hermetic unit tests (no processes, no files)
//!   zig build test-blackbox   spawns the INSTALLED binary; never folded into `test`
//!   zig build bench           ReleaseFast throughput harness over bench/corpus
//!   zig build fmt-check       `zig fmt --check` over every Zig source tree
const std = @import("std");

/// Where the core package's sources live, relative to the build root. The
/// same string is the prefix of every embedded file's path, so a diagnostic
/// in core names `core/Basics.beni` whether it came from the embedded copy
/// or from the checkout (see `SourceStore`'s header).
const core_dir = "core";

/// Where the platform packages that ship with the compiler live
/// (`docs/design/boundary.md` §5.3: "two platforms ship with the compiler").
/// Each subdirectory is one package: its `beni.json`, its `.beni` modules and
/// the JavaScript they bind to, all embedded so `beni build --platform=node`
/// needs nothing on disk.
const platforms_dir = "platforms";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `diagnostic` is a NAMED module because two roots need the same schema:
    // the compiler renders it and the black-box suite parses it back. A field
    // added or renamed in production then fails the tests at compile time
    // instead of silently (frontend.md §1.1). It imports only `std`.
    const diagnostic_mod = b.addModule("diagnostic", .{
        .root_source_file = b.path("src/diagnostic.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The library root. `src/main.zig` is a thin shell over it, so every
    // piece of behaviour (including argument parsing) is reachable from the
    // hermetic test root without spawning anything.
    const beni_mod = b.addModule("beni", .{
        .root_source_file = b.path("src/beni.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "diagnostic", .module = diagnostic_mod }},
    });
    // The core package (checker.md §3): every `core/**/*.beni` embedded, the
    // list generated from the directory at configure time so adding a core
    // module is dropping in a file. It is part of the compiler, not of a
    // test, so it hangs off the library module every root imports.
    beni_mod.addImport("core_package", embedCore(b, core_dir));
    // The platform packages (boundary.md §8, B2), embedded the same way.
    beni_mod.addImport("platform_packages", embedPlatforms(b, platforms_dir));
    // The compiler build id (`fast-compiler.md` §8): the cache key's term for
    // "which compiler produced this entry". Computed here rather than by
    // hashing the installed binary at run time, which is correct and costs
    // ~2 ms of a 15 ms warm budget.
    beni_mod.addImport("build_options", buildIdOptions(b, target, optimize));

    const exe = b.addExecutable(.{
        .name = "beni",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "beni", .module = beni_mod },
                .{ .name = "diagnostic", .module = diagnostic_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run beni");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- Hermetic suite. ----
    // `src/beni.zig` references every internal module from its test block;
    // `diagnostic` is its own module and therefore its own test artifact.
    // The generator is tested here too (same output for the same seed) so the
    // bench corpus can be trusted to be stable.
    // Fixture corpora reach the hermetic suite as embedded bytes (frontend.md
    // §2, tests/fixtures): a generated manifest module per directory, so a
    // test walks `@import("corpus_parse_good").fixtures` without touching
    // the filesystem. Only test blocks import them, so the binary does not
    // carry the bytes.
    beni_mod.addImport("corpus_parse_good", embedCorpus(b, "tests/corpus/parse/good"));
    beni_mod.addImport("corpus_bir", embedCorpus(b, "tests/corpus/bir"));

    const beni_tests = b.addTest(.{ .root_module = beni_mod });
    const diagnostic_tests = b.addTest(.{ .root_module = diagnostic_mod });
    const gen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the hermetic unit tests");
    test_step.dependOn(&b.addRunArtifact(beni_tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostic_tests).step);
    test_step.dependOn(&b.addRunArtifact(gen_tests).step);

    // ---- Black-box suite. ----
    // Spawns `./zig-out/bin/beni`, so it depends on the install step and runs
    // with cwd = repo root (the harness resolves the binary and the corpus
    // relative to it). The blackbox modules import only `diagnostic`: reaching
    // for an internal is a compile error, not a code-review finding.
    const blackbox_step = b.step("test-blackbox", "Run the black-box tests (spawns the installed binary)");
    for ([_][]const u8{
        "tests/blackbox/blackbox_test.zig",
        "tests/blackbox/corpus_test.zig",
        "tests/blackbox/abuse_test.zig",
        "tests/blackbox/build_test.zig",
        "tests/blackbox/check_test.zig",
        "tests/blackbox/docs_test.zig",
        "tests/blackbox/iface_test.zig",
        "tests/blackbox/matrix_test.zig",
    }) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "diagnostic", .module = diagnostic_mod }},
            }),
        });
        const run = b.addRunArtifact(t);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(b.path("."));
        blackbox_step.dependOn(&run.step);
    }

    // ---- Bench. ----
    // Always ReleaseFast, whatever `-Doptimize` says: a Debug throughput number
    // is not a number. It gets its own module instances because a module's
    // optimize mode is fixed at creation.
    const bench_diagnostic = b.createModule(.{
        .root_source_file = b.path("src/diagnostic.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_beni = b.createModule(.{
        .root_source_file = b.path("src/beni.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "diagnostic", .module = bench_diagnostic }},
    });
    bench_beni.addImport("core_package", embedCore(b, core_dir));
    bench_beni.addImport("platform_packages", embedPlatforms(b, platforms_dir));
    // Its own options, because the id covers the optimize mode and the bench
    // module is always ReleaseFast whatever `-Doptimize` says.
    bench_beni.addImport("build_options", buildIdOptions(b, target, .ReleaseFast));
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "beni", .module = bench_beni }},
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.setCwd(b.path("."));
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Measure per-phase throughput over bench/corpus (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // ---- Formatting. ----
    const fmt_step = b.step("fmt-check", "Check formatting with `zig fmt --check`");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ "src", "build.zig", "tests", "bench" },
        .check = true,
    }).step);
}

/// The `build_options` module, carrying the 16-byte compiler build id of
/// `docs/design/fast-compiler.md` §8 — the cache key's term for "which
/// compiler produced this entry" (`src/build_id.zig` has what it is for).
fn buildIdOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([16]u8, "build_id", compilerBuildId(b, target, optimize));
    return options.createModule();
}

/// Bumped whenever the recipe below changes, so that two compilers which
/// hash the same inputs differently cannot collide on an id.
const build_id_recipe: []const u8 = "BENIBUILDID\x00v1";

/// `SipHash128(1, 3)` — the compiler's one hash function
/// (`src/resolve/iface_bytes.zig`) — over the recipe tag, the Zig version
/// string, the optimize mode, the target triple and every file under `src/`:
/// path then bytes, in sorted path order, each preceded by its length so that
/// two different splits of the same concatenation cannot agree.
///
/// Configure time, not run time: the whole tree is ~2 MB and hashing it costs
/// under a millisecond, and `build.zig` re-runs on every `zig build` — so the
/// id is fresh whenever the sources are, which is also exactly when the
/// compiler is relinked anyway.
///
/// `beni.version` is not a separate term; see `src/build_id.zig`'s header.
fn compilerBuildId(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [16]u8 {
    var hasher = std.hash.SipHash128(1, 3).init(&@as([16]u8, @splat(0)));
    feed(&hasher, build_id_recipe);
    feed(&hasher, @import("builtin").zig_version_string);
    feed(&hasher, @tagName(optimize));
    feed(&hasher, target.result.zigTriple(b.allocator) catch @panic("OOM"));

    var paths: std.ArrayList([]const u8) = .empty;
    collectAll(b, "src", "", &paths);
    sortPaths(&paths);
    if (paths.items.len == 0) std.debug.panic("the compiler source tree at src/ is empty", .{});

    const io = b.graph.io;
    for (paths.items) |rel| {
        feed(&hasher, rel);
        const full = b.pathJoin(&.{ "src", rel });
        const bytes = b.build_root.handle.readFileAlloc(io, full, b.allocator, .unlimited) catch |err| {
            std.debug.panic("cannot read compiler source {s}: {t}", .{ full, err });
        };
        feed(&hasher, bytes);
        b.allocator.free(bytes);
    }

    var out: [16]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// One length-prefixed field of the digest.
fn feed(hasher: *std.hash.SipHash128(1, 3), slice: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, slice.len, .little);
    hasher.update(&len);
    hasher.update(slice);
}

/// Every file under `<root>/<prefix>`, recursively, as paths relative to
/// `root`. Unlike `collectFiles` it does not sort files into two buckets:
/// every file under `src/` is compiler source, whatever its extension.
fn collectAll(b: *std.Build, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) void {
    const io = b.graph.io;
    const full = if (prefix.len == 0) b.dupe(root) else b.pathJoin(&.{ root, prefix });
    var handle = b.build_root.handle.openDir(io, full, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open compiler source directory {s}: {t}", .{ full, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ full, err })) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => collectAll(b, root, rel, out),
            .file => out.append(b.allocator, rel) catch @panic("OOM"),
            else => {},
        }
    }
}

/// A module whose root exports `fixtures`, one `{ name, source }` per
/// `.beni` file directly under `dir` (sorted by name), each embedded. The
/// files are copied next to a generated manifest so `@embedFile` resolves
/// them inside that module's root; the directory is enumerated at
/// configure time, so adding a fixture is dropping in a file.
fn embedCorpus(b: *std.Build, dir: []const u8) *std.Build.Module {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    var handle = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open corpus directory {s}: {t}", .{ dir, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read corpus directory {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator, "pub const Fixture = struct { name: []const u8, source: [:0]const u8 };\npub const fixtures = [_]Fixture{\n") catch @panic("OOM");
    for (names.items) |name| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, name })), name);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ name, name })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const root = wf.add("manifest.zig", manifest.items);
    return b.createModule(.{ .root_source_file = root });
}

/// The core package as a module exporting `dir`, `files` and `assets`: one
/// `{ rel, source }` per `.beni` under `core/` (recursively, sorted by path)
/// and one `{ path, bytes }` per other file — the sibling JavaScript of
/// `boundary.md` §4, which `beni build` copies next to the module that
/// imports it. Same mechanism as `embedCorpus` — the files are copied next to
/// a generated manifest so `@embedFile` resolves inside the generated module
/// — but the paths keep their subdirectories, because a `core/Dict/Int.beni`
/// would be the module `Dict.Int` and the path IS the name. Nothing under
/// `core/` is nested today; the mechanism outlives the modules that used it.
fn embedCore(b: *std.Build, dir: []const u8) *std.Build.Module {
    var paths: std.ArrayList([]const u8) = .empty;
    var assets: std.ArrayList([]const u8) = .empty;
    collectFiles(b, dir, "", &paths, &assets);
    sortPaths(&paths);
    sortPaths(&assets);
    if (paths.items.len == 0) std.debug.panic("the core package at {s} is empty", .{dir});

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\//! Generated by build.zig: the core package, embedded (checker.md §3,
        \\//! boundary.md §4).
        \\
        \\pub const File = struct {
        \\    /// Relative to `dir`, with `/` separators: `Dict/Int.beni`
        \\    /// would be one, were any core module nested.
        \\    rel: []const u8,
        \\    source: [:0]const u8,
        \\};
        \\
        \\/// A file `beni build` copies out verbatim, keyed by the path the
        \\/// `SourceStore` spells it with (`core/Basics.js`).
        \\pub const Asset = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
    ) catch @panic("OOM");
    manifest.appendSlice(b.allocator, b.fmt("pub const dir = \"{s}\";\npub const files = [_]File{{\n", .{dir})) catch @panic("OOM");
    for (paths.items) |rel| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, rel })), rel);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ rel, rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\npub const assets = [_]Asset{\n") catch @panic("OOM");
    for (assets.items) |rel| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, rel })), rel);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ dir, rel, rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("core_package.zig", manifest.items) });
}

/// Every platform package under `dir`, embedded: its manifest bytes, its
/// `.beni` modules and its JavaScript. `--platform=<name>` matches the
/// subdirectory name, so adding a platform to the box is dropping in a
/// directory (boundary.md §5.1: supporting a runtime is a package, not a
/// compiler change).
fn embedPlatforms(b: *std.Build, dir: []const u8) *std.Build.Module {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    var handle = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open platforms directory {s}: {t}", .{ dir, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    sortPaths(&names);

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\//! Generated by build.zig: the platform packages that ship with the
        \\//! compiler (boundary.md §5.3, §8).
        \\
        \\pub const File = struct { rel: []const u8, source: [:0]const u8 };
        \\pub const Asset = struct { path: []const u8, bytes: []const u8 };
        \\pub const Platform = struct {
        \\    /// What `--platform=<name>` matches.
        \\    name: []const u8,
        \\    /// The package root as the `SourceStore` spells it.
        \\    root: []const u8,
        \\    /// The bytes of its `beni.json`.
        \\    manifest: []const u8,
        \\    files: []const File,
        \\    assets: []const Asset,
        \\};
        \\
    ) catch @panic("OOM");
    var bodies: std.ArrayList(u8) = .empty;
    var table: std.ArrayList(u8) = .empty;
    table.appendSlice(b.allocator, "pub const platforms = [_]Platform{\n") catch @panic("OOM");
    for (names.items) |name| {
        const root = b.fmt("{s}/{s}", .{ dir, name });
        var files: std.ArrayList([]const u8) = .empty;
        var assets: std.ArrayList([]const u8) = .empty;
        collectFiles(b, root, "", &files, &assets);
        sortPaths(&files);
        sortPaths(&assets);
        if (files.items.len == 0) std.debug.panic("the platform package at {s} has no modules", .{root});

        const manifest_rel = b.fmt("{s}/beni.json", .{name});
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ root, "beni.json" })), manifest_rel);
        bodies.appendSlice(b.allocator, b.fmt("const files_{s} = [_]File{{\n", .{name})) catch @panic("OOM");
        for (files.items) |rel| {
            const key = b.fmt("{s}/{s}", .{ name, rel });
            _ = wf.addCopyFile(b.path(b.pathJoin(&.{ root, rel })), key);
            bodies.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ rel, key })) catch @panic("OOM");
        }
        bodies.appendSlice(b.allocator, b.fmt("}};\nconst assets_{s} = [_]Asset{{\n", .{name})) catch @panic("OOM");
        for (assets.items) |rel| {
            if (std.mem.eql(u8, rel, "beni.json")) continue;
            const key = b.fmt("{s}/{s}", .{ name, rel });
            _ = wf.addCopyFile(b.path(b.pathJoin(&.{ root, rel })), key);
            bodies.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ root, rel, key })) catch @panic("OOM");
        }
        bodies.appendSlice(b.allocator, "};\n") catch @panic("OOM");
        table.appendSlice(b.allocator, b.fmt(
            "    .{{ .name = \"{s}\", .root = \"{s}\", .manifest = @embedFile(\"{s}\"), .files = &files_{s}, .assets = &assets_{s} }},\n",
            .{ name, root, manifest_rel, name, name },
        )) catch @panic("OOM");
    }
    table.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    manifest.appendSlice(b.allocator, bodies.items) catch @panic("OOM");
    manifest.appendSlice(b.allocator, table.items) catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("platform_packages.zig", manifest.items) });
}

fn sortPaths(list: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
}

/// Append every file under `<root>/<prefix>` to `sources` (the `.beni`
/// modules) or `assets` (everything else), as paths relative to `root`,
/// descending into subdirectories.
fn collectFiles(
    b: *std.Build,
    root: []const u8,
    prefix: []const u8,
    sources: *std.ArrayList([]const u8),
    assets: *std.ArrayList([]const u8),
) void {
    const io = b.graph.io;
    const full = if (prefix.len == 0) b.dupe(root) else b.pathJoin(&.{ root, prefix });
    var handle = b.build_root.handle.openDir(io, full, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open package directory {s}: {t}", .{ full, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read package directory {s}: {t}", .{ full, err })) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => collectFiles(b, root, rel, sources, assets),
            .file => if (std.mem.endsWith(u8, entry.name, ".beni"))
                sources.append(b.allocator, rel) catch @panic("OOM")
            else
                assets.append(b.allocator, rel) catch @panic("OOM"),
            else => {},
        }
    }
}
