//! Locating the platform package a run was told to use, and the platforms it
//! depends on (docs/design/boundary.md §5.3, §9.1; frontend.md §1).
//!
//! `--platform=<name>` is either the name of a platform embedded in the
//! binary — modules, siblings, runtime and manifest, the way `core/` is — or
//! a directory holding a package whose `beni.json` says `"platform": true`
//! (§2). A platform may depend on platforms of its own (`"platforms"`), each
//! named the same two ways, a directory relative to the package that names
//! it. `resolveChain` reads every manifest of that chain BEFORE the run reads
//! a source file, so a broken chain is one exit-2 line and nothing else; the
//! session then enumerates every package of the chain (`Session`'s
//! `enumeratePlatform`).
//!
//! It lives here rather than in `build/Command.zig` because `check` and the
//! import-resolving `dump` stages take the same flag and must resolve it the
//! same way, down to the bytes on stderr: a `check` that disagrees with the
//! `build` behind it about what a platform is would be worse than no `check`
//! at all. The answer comes from the manifests and not from a table in the
//! compiler, which is what makes a Bun or Deno platform a package rather than
//! a compiler change (§5.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Session = @import("Session.zig");
const SourceStore = @import("SourceStore.zig");
const Emit = @import("js/Emit.zig");
const Manifest = @import("js/Manifest.zig");
const core_package = @import("core_package");
const platform_packages = @import("platform_packages");

/// The most packages one chain may hold. A layer's view of the chain is a
/// bit set of this width (`Layer.sees`).
pub const max_layers = 64;

/// One platform package of the chain (`boundary.md` §9.1).
pub const Layer = struct {
    /// How messages name it: the manifest's `"name"`, else the spelling that
    /// reached it.
    name: []const u8,
    /// The package root as the `SourceStore` spells it, normalised.
    root: []const u8,
    manifest: Manifest,
    /// The platform's row in the binary's table, when it ships in it.
    embedded: ?*const platform_packages.Platform,
    /// The layers this one depends on directly, as indices into the chain.
    deps: []const u32,
    /// This layer and every layer it depends on, transitively, one bit per
    /// chain index: which layers' modules this layer's modules may import.
    sees: u64,
    /// Where its modules, siblings and runtime are written: `_platform/` for
    /// the top, `_platform/_<name>/` for a dependency (`backend.md` §2,
    /// rule 1: no module can reach a `_` segment).
    out_dir: []const u8,
};

/// Every package of the chain, read depth-first in list order from the
/// selected platform, which is index 0. A package reached twice is one.
pub const Chain = struct {
    layers: []const Layer,

    pub fn top(chain: *const Chain) *const Layer {
        return &chain.layers[0];
    }

    /// The first layer, in chain order, whose manifest gives `field` a value
    /// (§9.1's "first found, field by field"), with that value.
    pub fn first(chain: *const Chain, comptime field: []const u8) ?Found {
        for (chain.layers, 0..) |layer, i| {
            const value = @field(layer.manifest, field) orelse continue;
            return .{ .value = value, .layer = @intCast(i) };
        }
        return null;
    }

    /// As `first`, for one field of `"markup"` (§9.2).
    pub fn firstMarkup(chain: *const Chain, comptime field: []const u8) ?Found {
        for (chain.layers, 0..) |layer, i| {
            const value = @field(layer.manifest.markup, field) orelse continue;
            return .{ .value = value, .layer = @intCast(i) };
        }
        return null;
    }

    /// The layer whose root holds `path`, or null. The longest root wins,
    /// should one package sit inside another's directory.
    pub fn layerOfPath(chain: *const Chain, path: []const u8) ?u32 {
        var best: ?u32 = null;
        var best_len: usize = 0;
        for (chain.layers, 0..) |layer, i| {
            const r = layer.root;
            const under = std.mem.eql(u8, r, ".") or
                (path.len > r.len and std.mem.startsWith(u8, path, r) and path[r.len] == '/');
            if (!under) continue;
            if (best == null or r.len > best_len) {
                best = @intCast(i);
                best_len = r.len;
            }
        }
        return best;
    }
};

pub const Found = struct { value: []const u8, layer: u32 };

/// Why a chain could not be read. Every one is an exit-2 line (`report`).
pub const Failure = union(enum) {
    /// `--platform` named neither an embedded platform nor a directory.
    unknown: []const u8,
    /// A directory without a `beni.json`: the spelling that reached it.
    no_manifest: []const u8,
    /// A manifest that does not say `"platform": true`.
    not_a_platform: []const u8,
    /// A manifest that is not a JSON object of the expected shape: its root.
    malformed: []const u8,
    /// A `"platforms"` entry that names nothing.
    unknown_dependency: struct { from: []const u8, dep: []const u8 },
    /// The chain depends on itself: the layers of the cycle, in order.
    cycle: []const []const u8,
    too_many,
    /// The first `"markup".lowering` and the first `"markup".runtime` of the
    /// chain are declared by two different packages (§9.2).
    markup_split: struct { lowering: []const u8, runtime: []const u8 },
    /// A dependency whose output directory's name — its `"name"`, or its
    /// directory's when it has none (`named` false) — is not one plain
    /// directory name.
    bad_name: struct { from: []const u8, dep: []const u8, name: []const u8, named: bool },
    /// Two dependencies whose output directories are one, ASCII case folded.
    shared_dir: struct { first: []const u8, first_root: []const u8, second: []const u8, second_root: []const u8, dir: []const u8 },
};

/// Whether `name` is a directory name a dependency's output may take under
/// `_platform/_<name>/`: ASCII letters, digits, `-`, `_` and `.`, beginning
/// with a letter or a digit. So no separator, no `.` or `..`, no NUL, no
/// leading `_` or `.`, and nothing a file system treats specially.
pub fn validDirName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// Read the chain `requested` selects. Strings are owned by `arena`.
pub fn resolveChain(arena: Allocator, io: Io, requested: []const u8, failure: *?Failure) (Allocator.Error || error{Failed})!Chain {
    var r: Resolver = .{ .arena = arena, .io = io, .failure = failure };
    _ = try r.visit(requested, null);
    // `sees`, bottom-up: every dependency is visited, and its index fixed,
    // before its dependent's `visit` returns, so a pass from the last layer
    // to the first meets each dependency first.
    var i = r.layers.items.len;
    while (i > 0) {
        i -= 1;
        const layer = &r.layers.items[i];
        var sees: u64 = @as(u64, 1) << @intCast(i);
        for (layer.deps) |d| sees |= r.layers.items[d].sees;
        layer.sees = sees;
    }
    const chain: Chain = .{ .layers = r.layers.items };
    // A lowering and its runtime come from one package: the runtime is
    // written for the lowering (§9.2).
    if (chain.firstMarkup("lowering")) |lowering| if (chain.firstMarkup("runtime")) |runtime| {
        if (lowering.layer != runtime.layer) return r.fail(.{ .markup_split = .{
            .lowering = chain.layers[lowering.layer].name,
            .runtime = chain.layers[runtime.layer].name,
        } });
    };
    return chain;
}

const Resolver = struct {
    arena: Allocator,
    io: Io,
    failure: *?Failure,
    layers: std.ArrayList(Layer) = .empty,
    /// Per layer, the identity it was found under: `embedded:<name>` or its
    /// normalised directory.
    keys: std.ArrayList([]const u8) = .empty,
    /// Per layer, the directory its output goes to under `_platform/_…/`.
    dirs: std.ArrayList([]const u8) = .empty,
    /// The layers being visited, outermost first: a dependency that is one
    /// of them closes a cycle.
    path: std.ArrayList(u32) = .empty,

    fn fail(r: *Resolver, f: Failure) error{Failed} {
        r.failure.* = f;
        return error.Failed;
    }

    /// Visit the platform `spelling` names, as written by `from` (null for
    /// the command line), and return its chain index.
    fn visit(r: *Resolver, spelling: []const u8, from: ?u32) (Allocator.Error || error{Failed})!u32 {
        const arena = r.arena;
        var embedded: ?*const platform_packages.Platform = null;
        for (&platform_packages.platforms) |*p| {
            if (std.mem.eql(u8, p.name, spelling)) embedded = p;
        }
        // An embedded platform's dependencies are embedded platforms: it has
        // no directory for a relative path to be relative to.
        const from_embedded = if (from) |f| r.layers.items[f].embedded != null else false;
        var root: []const u8 = undefined;
        var key: []const u8 = undefined;
        if (embedded) |p| {
            root = p.root;
            key = try std.fmt.allocPrint(arena, "embedded:{s}", .{p.name});
        } else {
            if (from_embedded) return r.fail(.{ .unknown_dependency = .{ .from = r.layers.items[from.?].name, .dep = spelling } });
            if (from) |f| {
                // A dependency's path is relative to the package that names
                // it, and is joined and resolved lexically — `top/../base`
                // is `base` — because the compiler composed it, not the user.
                root = try std.fs.path.resolvePosix(arena, &.{ r.layers.items[f].root, spelling });
            } else {
                const buffer = try arena.alloc(u8, @max(spelling.len, 1));
                root = SourceStore.normalize(buffer, spelling);
            }
            // A directory is one package however it is spelled: its
            // identity is its real path when it has one.
            key = Io.Dir.cwd().realPathFileAlloc(r.io, root, arena) catch root;
        }
        for (r.keys.items, 0..) |k, i| {
            if (!std.mem.eql(u8, k, key)) continue;
            if (std.mem.indexOfScalar(u32, r.path.items, @intCast(i))) |at| {
                var names: std.ArrayList([]const u8) = .empty;
                for (r.path.items[at..]) |l| try names.append(arena, r.layers.items[l].name);
                return r.fail(.{ .cycle = names.items });
            }
            return @intCast(i);
        }
        if (r.layers.items.len == max_layers) return r.fail(.too_many);

        const manifest: Manifest = if (embedded) |p|
            Manifest.parse(arena, p.manifest) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => return r.fail(.{ .malformed = root }),
            }
        else blk: {
            const read = Manifest.read(arena, r.io, root) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => return r.fail(.{ .malformed = root }),
                error.ReadFailed => null,
            };
            if (read) |m| break :blk m;
            // No manifest: a directory that is not a package, or no
            // directory at all — the second is "unknown", as it always was.
            const is_dir = if (Io.Dir.cwd().statFile(r.io, root, .{})) |s| s.kind == .directory else |_| false;
            if (!is_dir) {
                if (from) |f| return r.fail(.{ .unknown_dependency = .{ .from = r.layers.items[f].name, .dep = spelling } });
                return r.fail(.{ .unknown = spelling });
            }
            return r.fail(.{ .no_manifest = spelling });
        };
        if (!manifest.platform) return r.fail(.{ .not_a_platform = spelling });

        const index: u32 = @intCast(r.layers.items.len);
        const name = manifest.name orelse spelling;
        // A dependency's output goes to `_platform/_<dir>/`: its manifest's
        // name, else the last segment of the directory that holds it. One
        // directory name, so the output stays under `--out`, and one per
        // chain, so two packages never write into one directory.
        const dir = manifest.name orelse std.fs.path.basenamePosix(root);
        if (index != 0) {
            if (!validDirName(dir)) return r.fail(.{ .bad_name = .{
                .from = r.layers.items[from.?].name,
                .dep = spelling,
                .name = dir,
                .named = manifest.name != null,
            } });
            for (r.layers.items[1..], r.dirs.items[1..]) |other, other_dir| {
                if (!std.ascii.eqlIgnoreCase(other_dir, dir)) continue;
                return r.fail(.{ .shared_dir = .{ .first = other.name, .first_root = other.root, .second = name, .second_root = root, .dir = other_dir } });
            }
        }
        try r.dirs.append(arena, dir);
        try r.layers.append(arena, .{
            .name = name,
            .root = root,
            .manifest = manifest,
            .embedded = embedded,
            .deps = &.{},
            .sees = 0,
            .out_dir = if (index == 0)
                Emit.platform_dir
            else
                try std.fmt.allocPrint(arena, "{s}_{s}/", .{ Emit.platform_dir, dir }),
        });
        try r.keys.append(arena, key);
        try r.path.append(arena, index);
        var deps: std.ArrayList(u32) = .empty;
        for (manifest.platforms) |dep| {
            const d = try r.visit(dep, index);
            if (std.mem.indexOfScalar(u32, deps.items, d) == null) try deps.append(arena, d);
        }
        _ = r.path.pop();
        r.layers.items[index].deps = deps.items;
        return index;
    }
};

/// The names `--platform` accepts without a directory, for the error
/// message. Built at comptime because the platform table is.
pub const embedded_names = blk: {
    var text: []const u8 = "";
    for (platform_packages.platforms, 0..) |platform, i| {
        text = text ++ (if (i == 0) "" else ", ") ++ platform.name;
    }
    break :blk text;
};

/// A chain that could not be read (`resolveChain`). Exit 2, one line, one
/// message per way of failing, because each asks for a different edit.
pub fn report(stderr: *Io.Writer, f: Failure) u8 {
    return switch (f) {
        .unknown => |requested| fail(
            stderr,
            "beni: unknown platform '{s}'; give the name of a platform that ships with the compiler ({s}) or a directory holding one",
            .{ requested, embedded_names },
        ),
        .no_manifest => |requested| fail(
            stderr,
            "beni: '{s}' has no {s}; a platform package declares itself one with \"platform\": true",
            .{ requested, Manifest.file_name },
        ),
        .not_a_platform => |requested| fail(
            stderr,
            "beni: '{s}' is not a platform package; its {s} must say \"platform\": true",
            .{ requested, Manifest.file_name },
        ),
        .malformed => |root| fail(
            stderr,
            "beni: cannot read '{s}/{s}': it is not a JSON object",
            .{ root, Manifest.file_name },
        ),
        .unknown_dependency => |d| fail(
            stderr,
            "beni: platform '{s}' depends on '{s}' (\"platforms\"), which is neither a platform that ships with the compiler ({s}) nor a directory holding one",
            .{ d.from, d.dep, embedded_names },
        ),
        .cycle => |names| {
            stderr.print("beni: these platforms depend on each other in a circle (\"platforms\"): ", .{}) catch {};
            for (names) |n| stderr.print("{s} → ", .{n}) catch {};
            return fail(stderr, "{s}; a platform may depend only on platforms that do not depend on it", .{names[0]});
        },
        .too_many => fail(stderr, "beni: the platform chain holds more than {d} packages", .{max_layers}),
        .bad_name => |b| if (b.named) fail(
            stderr,
            "beni: platform '{s}' depends on '{s}', whose \"name\" '{s}' cannot name its output directory _platform/_<name>/; a platform's name is ASCII letters, digits, '-', '_' and '.', and begins with a letter or a digit",
            .{ b.from, b.dep, b.name },
        ) else fail(
            stderr,
            "beni: platform '{s}' depends on '{s}', which has no \"name\", and its directory's name '{s}' cannot name its output directory _platform/_<name>/; give it a \"name\" of ASCII letters, digits, '-', '_' and '.', beginning with a letter or a digit",
            .{ b.from, b.dep, b.name },
        ),
        .shared_dir => |s| fail(
            stderr,
            "beni: platforms '{s}' ('{s}') and '{s}' ('{s}') of one chain would share the output directory _platform/_{s}/; give each a \"name\" of its own",
            .{ s.first, s.first_root, s.second, s.second_root, s.dir },
        ),
        .markup_split => |s| fail(
            stderr,
            "beni: the markup lowering is declared by '{s}' and the markup runtime by '{s}'; a \"markup\" \"lowering\" and its \"runtime\" must come from one package",
            .{ s.lowering, s.runtime },
        ),
    };
}

/// What a build or a check needs to know about the chain once the session
/// has enumerated it: the output shape its manifests declare, field by field
/// (§9.1), and every file the compiler carries that a build may copy out.
pub const Loaded = struct {
    platform: Emit.Platform,
    embedded: []const Emit.Asset,
};

pub const LoadError = error{
    /// A build of a program whose chain declares a `program` and no
    /// `runtime`, or the reverse.
    Incomplete,
} || Allocator.Error;

/// The output shape, inherited field by field down the chain (§9.1). A
/// `program` without a `runtime` or the reverse is `Incomplete` for a program
/// build; `check` and a library build need neither.
pub fn load(arena: Allocator, session: *Session, chain: *const Chain, needs_program: bool) LoadError!Loaded {
    const program = chain.first("program");
    const runtime = chain.first("runtime");
    if (needs_program and (program == null or runtime == null)) return error.Incomplete;
    const entry = chain.first("entry");
    const lowering = chain.firstMarkup("lowering");
    const markup_runtime = chain.firstMarkup("runtime");
    const dirs = try arena.alloc([]const u8, chain.layers.len);
    for (dirs, chain.layers) |*d, layer| d.* = layer.out_dir;
    return .{
        .platform = .{
            .program = if (program) |p| p.value else null,
            .runtime = if (runtime) |r| r.value else null,
            .runtime_root = if (runtime) |r| chain.layers[r.layer].root else chain.top().root,
            .runtime_dir = if (runtime) |r| chain.layers[r.layer].out_dir else Emit.platform_dir,
            // Optional: a chain that says nothing about the entry file gets
            // `backend.md` §2's reserved default. The NAME is checked in
            // `Emit`, because a bad one is a diagnostic against the manifest
            // at 1:1 rather than an exit-2 line.
            .entry = if (entry) |e| e.value else Emit.default_entry_file,
            .entry_root = if (entry) |e| chain.layers[e.layer].root else chain.top().root,
            .root = chain.top().root,
            .layer_dirs = dirs,
            .file_layers = session.file_layers,
            .name = chain.top().name,
            .lowering = if (lowering) |l| l.value else null,
            .lowering_root = if (lowering) |l| chain.layers[l.layer].root else chain.top().root,
            .markup_runtime = if (markup_runtime) |r| r.value else null,
            .markup_runtime_dir = if (markup_runtime) |r| chain.layers[r.layer].out_dir else Emit.platform_dir,
        },
        .embedded = try collectEmbedded(arena, session, chain),
    };
}

/// A `load` that failed. Exit 2, one line.
pub fn reportLoad(stderr: *Io.Writer, requested: []const u8, err: LoadError) u8 {
    return switch (err) {
        error.OutOfMemory => fail(stderr, "beni: out of memory", .{}),
        error.Incomplete => fail(
            stderr,
            "beni: '{s}' does not declare what `main` is; its {s} needs \"program\" and \"runtime\"",
            .{ requested, Manifest.file_name },
        ),
    };
}

/// A program build against a chain that declares no `program` (§9.1): the
/// platform is only depended on. Exit 2 before anything is read.
pub fn reportNoProgram(stderr: *Io.Writer, requested: []const u8) u8 {
    return fail(
        stderr,
        "beni: '{s}' declares no \"program\" and is only depended on: build a library for it with --library, or build the program for a platform that depends on it",
        .{requested},
    );
}

/// Every file the compiler carries that a run may have to read: core's
/// siblings, and the siblings and runtimes of every embedded platform of the
/// chain. A platform read from a directory contributes nothing here and is
/// read from disk instead.
///
/// `check` needs this as much as `build` does: boundary.md §4's checks 2, 3
/// and 4 read the sibling JavaScript of every module with a `foreign`, and
/// core's siblings are in the binary rather than on the user's disk.
fn collectEmbedded(arena: Allocator, session: *Session, chain: *const Chain) Allocator.Error![]const Emit.Asset {
    var out: std.ArrayList(Emit.Asset) = .empty;
    // A `--core-root` run reads core from disk, so the embedded copy must
    // not shadow it.
    if (session.options.core_root == null) {
        for (core_package.assets) |asset| {
            try out.append(arena, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    for (chain.layers) |layer| {
        const p = layer.embedded orelse continue;
        for (p.assets) |asset| {
            try out.append(arena, .{ .path = asset.path, .bytes = asset.bytes });
        }
    }
    return out.items;
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}

test "a dependency's output directory name is one plain directory name" {
    const testing = std.testing;
    for ([_][]const u8{ "lib", "lib-one", "a.b_c", "Html2" }) |n| try testing.expect(validDirName(n));
    for ([_][]const u8{ "", ".", "..", "x/../esc", "a\\b", "_lib", ".hidden", "x y", "a\x00b", "\u{e9}" }) |n| try testing.expect(!validDirName(n));
}
