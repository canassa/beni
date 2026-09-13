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

/// The core package as a module exporting `dir` and `files`, one
/// `{ path, source }` per `.beni` under `core/` (recursively, sorted by
/// path), each `@embedFile`d. Same mechanism as `embedCorpus` — the files
/// are copied next to a generated manifest so `@embedFile` resolves inside
/// the generated module — but the paths keep their subdirectories, because
/// `core/Dict/Int.beni` is the module `Dict.Int` and the path IS the name.
fn embedCore(b: *std.Build, dir: []const u8) *std.Build.Module {
    var paths: std.ArrayList([]const u8) = .empty;
    collectBeniFiles(b, dir, "", &paths);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    if (paths.items.len == 0) std.debug.panic("the core package at {s} is empty", .{dir});

    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\//! Generated by build.zig: the core package, embedded (checker.md §3).
        \\
        \\pub const File = struct {
        \\    /// Relative to `dir`, with `/` separators: `Dict/Int.beni`.
        \\    rel: []const u8,
        \\    source: [:0]const u8,
        \\};
        \\
    ) catch @panic("OOM");
    manifest.appendSlice(b.allocator, b.fmt("pub const dir = \"{s}\";\npub const files = [_]File{{\n", .{dir})) catch @panic("OOM");
    for (paths.items) |rel| {
        _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, rel })), rel);
        manifest.appendSlice(b.allocator, b.fmt("    .{{ .rel = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ rel, rel })) catch @panic("OOM");
    }
    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("core_package.zig", manifest.items) });
}

/// Append every `.beni` under `<root>/<prefix>` to `out`, as paths relative
/// to `root`, descending into subdirectories.
fn collectBeniFiles(b: *std.Build, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) void {
    const io = b.graph.io;
    const full = if (prefix.len == 0) b.dupe(root) else b.pathJoin(&.{ root, prefix });
    var handle = b.build_root.handle.openDir(io, full, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open core directory {s}: {t}", .{ full, err });
    };
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read core directory {s}: {t}", .{ full, err })) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => collectBeniFiles(b, root, rel, out),
            .file => if (std.mem.endsWith(u8, entry.name, ".beni")) out.append(b.allocator, rel) catch @panic("OOM"),
            else => {},
        }
    }
}
