//! Locating the platform package a run was told to use (docs/design/
//! boundary.md §5.3, frontend.md §1).
//!
//! `--platform=<name>` is either the name of a platform embedded in the
//! binary — modules, siblings, runtime and manifest, the way `core/` is — or
//! a directory holding a package whose `beni.json` says `"platform": true`
//! (§2). `Session.enumeratePlatform` does the enumeration; what is left is
//! reading what the package says about ITSELF, collecting the files the
//! compiler carries, and the one-line exit-2 messages for a `--platform` that
//! named nothing.
//!
//! It lives here rather than in `build/Command.zig` because `check` and the
//! import-resolving `dump` stages take the same flag and must resolve it the
//! same way, down to the bytes on stderr: a `check` that disagrees with the
//! `build` behind it about what a platform is would be worse than no `check`
//! at all. The answer comes from the manifest and not from a table in the
//! compiler, which is what makes a Bun or Deno platform a package rather than
//! a compiler change (§5.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Session = @import("Session.zig");
const Emit = @import("js/Emit.zig");
const Manifest = @import("js/Manifest.zig");
const core_package = @import("core_package");
const platform_packages = @import("platform_packages");

pub const Error = error{
    NoManifest,
    NotAPlatform,
    Incomplete,
    Malformed,
} || Allocator.Error;

/// Everything a command needs about the platform once the session has
/// enumerated it: what it says about its own output shape, and every file
/// the compiler carries that a build may have to copy out.
pub const Loaded = struct {
    platform: Emit.Platform,
    embedded: []const Emit.Asset,
};

pub fn load(arena: Allocator, io: Io, session: *Session) Error!Loaded {
    return .{
        .platform = try resolve(arena, io, session),
        .embedded = try collectEmbedded(arena, session),
    };
}

/// What the platform package says about itself (boundary.md §5.2). The
/// embedded platforms carry their manifest bytes in the binary; a directory
/// is read from disk.
fn resolve(arena: Allocator, io: Io, session: *Session) Error!Emit.Platform {
    if (session.platform_manifest.len == 0) {
        const read = Manifest.read(arena, io, session.platform_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => return error.Malformed,
            error.ReadFailed => return error.NoManifest,
        } orelse return error.NoManifest;
        return finish(read, session.platform_root);
    }
    const manifest = Manifest.parse(arena, session.platform_manifest) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return error.Malformed,
    };
    return finish(manifest, session.platform_root);
}

fn finish(manifest: Manifest, root: []const u8) Error!Emit.Platform {
    if (!manifest.platform) return error.NotAPlatform;
    return .{
        .program = manifest.program orelse return error.Incomplete,
        .runtime = manifest.runtime orelse return error.Incomplete,
        // Optional, unlike the other two: a platform that says nothing
        // about the entry file gets `backend.md` §2's reserved default. The
        // NAME is checked in `Emit` and not here, because a bad one is a
        // diagnostic against the manifest at 1:1 rather than one of §5.3's
        // exit-2 lines — the same call `foreign_sibling_missing` makes
        // about a `"runtime"` that is not there.
        .entry = manifest.entry orelse Emit.default_entry_file,
        .root = root,
    };
}

/// Every file the compiler carries that a run may have to read: core's
/// siblings, and the chosen platform's siblings and runtime. A platform read
/// from a directory contributes nothing here and is read from disk instead.
///
/// `check` needs this as much as `build` does: boundary.md §4's checks 2, 3
/// and 4 read the sibling JavaScript of every module with a `foreign`, and
/// core's siblings are in the binary rather than on the user's disk.
fn collectEmbedded(arena: Allocator, session: *Session) Allocator.Error![]const Emit.Asset {
    var out: std.ArrayList(Emit.Asset) = .empty;
    // A `--core-root` run reads core from disk, so the embedded copy must
    // not shadow it.
    if (session.options.core_root == null) {
        for (core_package.assets) |asset| {
            try out.append(arena, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    for (platform_packages.platforms) |platform| {
        if (!std.mem.eql(u8, platform.root, session.platform_root)) continue;
        for (platform.assets) |asset| {
            try out.append(arena, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    return out.items;
}

/// The names `--platform` accepts without a directory, for the error
/// message. Built at comptime because the platform table is.
pub const embedded_names = blk: {
    var text: []const u8 = "";
    for (platform_packages.platforms, 0..) |platform, i| {
        text = text ++ (if (i == 0) "" else ", ") ++ platform.name;
    }
    break :blk text;
};

/// `--platform` named something that is neither an embedded platform nor a
/// readable directory (`Session.platform_error`). Exit 2, one line.
pub fn reportUnknown(stderr: *Io.Writer, requested: []const u8) u8 {
    return fail(
        stderr,
        "beni: unknown platform '{s}'; give the name of a platform that ships with the compiler ({s}) or a directory holding one",
        .{ requested, embedded_names },
    );
}

/// The directory was there and is not a platform package. One message per
/// way of failing, because "not a platform" and "does not say what `main`
/// is" ask for different edits.
pub fn report(stderr: *Io.Writer, requested: []const u8, session: *const Session, err: Error) u8 {
    return switch (err) {
        error.OutOfMemory => fail(stderr, "beni: out of memory", .{}),
        error.NoManifest => fail(
            stderr,
            "beni: '{s}' has no {s}; a platform package declares itself one with \"platform\": true",
            .{ requested, Manifest.file_name },
        ),
        error.NotAPlatform => fail(
            stderr,
            "beni: '{s}' is not a platform package; its {s} must say \"platform\": true",
            .{ requested, Manifest.file_name },
        ),
        error.Incomplete => fail(
            stderr,
            "beni: '{s}' does not declare what `main` is; its {s} needs \"program\" and \"runtime\"",
            .{ requested, Manifest.file_name },
        ),
        error.Malformed => fail(
            stderr,
            "beni: cannot read '{s}/{s}': it is not a JSON object",
            .{ session.platform_root, Manifest.file_name },
        ),
    };
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
