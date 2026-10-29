//! The prototype hosts of research 108: `qhost-qjs` (Bellard's QuickJS) and
//! `qhost-ng` (QuickJS-ng), built from C with Zig's toolchain only. The
//! engines' sources are not in the repository: `run.sh fetch` downloads
//! them, checks their SHA-256, and passes their directories here.
//!
//!     zig build -Doptimize=ReleaseFast -Dqjs=<dir> -Dng=<dir>
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip the binaries") orelse false;
    // Zig compiles C with a trapping -fsanitize=undefined in Debug and
    // ReleaseSafe. -Dubsan=true keeps it (less the function-type check,
    // which needs a runtime Zig does not link); the default turns it off.
    const ubsan = b.option(bool, "ubsan", "Keep Zig's C sanitizer") orelse false;
    const san: []const u8 = if (ubsan) "-fno-sanitize=function" else "-fno-sanitize=undefined";
    const qjs_dir = b.option([]const u8, "qjs", "Bellard's QuickJS source directory") orelse @panic("-Dqjs=<dir> is required");
    const ng_dir = b.option([]const u8, "ng", "QuickJS-ng source directory") orelse @panic("-Dng=<dir> is required");

    const Engine = struct { name: []const u8, dir: []const u8, files: []const []const u8, ng: bool };
    const engines = [_]Engine{
        .{ .name = "qhost-qjs", .dir = qjs_dir, .files = &.{ "quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c", "cutils.c" }, .ng = false },
        .{ .name = "qhost-ng", .dir = ng_dir, .files = &.{ "quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c" }, .ng = true },
    };
    for (engines) |e| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .strip = strip });
        const dir: std.Build.LazyPath = .{ .cwd_relative = e.dir };
        mod.addCMacro("_GNU_SOURCE", "1");
        mod.addCMacro("CONFIG_VERSION", if (e.ng) "\"ng\"" else "\"bellard\"");
        if (e.ng) mod.addCMacro("QJS_NG", "1");
        mod.addIncludePath(dir);
        mod.addIncludePath(b.path("src"));
        mod.addCSourceFiles(.{ .root = dir, .files = e.files, .flags = &.{ "-std=gnu11", san, "-funsigned-char", "-Wno-everything" } });
        mod.addCSourceFiles(.{ .root = b.path("src"), .files = &.{"host.c"}, .flags = &.{ "-std=gnu23", san } });
        b.installArtifact(b.addExecutable(.{ .name = e.name, .root_module = mod }));
    }
}
