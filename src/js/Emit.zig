//! `beni build`'s back half (docs/design/backend.md §2, §5;
//! boundary.md §4, §5): the platform contract's build-time checks, then one
//! `.mjs` per source module plus the sibling JavaScript the modules bind to
//! and the platform's entry file.
//!
//! **Development output is one ESM file per source module, mirroring the
//! source tree** (§2). Nothing is eliminated and every name is readable,
//! because this is the mode the §2 warm-rebuild budget of 15 ms is measured
//! against: one edit rewrites one small file. Release output is chunks and
//! is M3c/M3d's.
//!
//! Layout under `--out`:
//!
//! ```
//! out/Main.mjs                       the app's modules, mirroring their names
//! out/core/List.mjs                  core, and its hand-written half beside it
//! out/core/List.foreign.mjs
//! out/platform/Node.mjs              the platform, its sibling, and its runtime
//! out/platform/Node.foreign.mjs
//! out/platform/runtime.foreign.mjs
//! out/main.mjs                       the entry file: imports `main`, hands it to `run`
//! ```
//!
//! Packages get a directory each because a module's identity is
//! `(package, name)` (checker.md §4.1) and an app may perfectly well have
//! its own `List`.
//!
//! **Every emitted file is `.mjs`, the hand-written ones included** (§2:
//! "so nothing depends on a `package.json` the user owns"). A sibling that
//! landed as `.js` would be an ES module with no module type declared, and
//! Node reparses it and warns on every start — which is exactly the
//! dependency on a user-owned `package.json` the rule exists to avoid. The
//! source keeps its `.js` name, because that is what a hand-written
//! JavaScript file is called and `language.md` §5.4 fixes the sibling's NAME
//! and not its extension; only the copy is renamed.
//!
//! The copy cannot simply keep its stem — `out/core/List.mjs` is already the
//! generated module — so it gains `.foreign.mjs`, which reads as what it is
//! and can never collide: a generated module's file name is its module name
//! with `.` turned into `/`, and every segment of a module name is an upper
//! identifier, so no generated file has two dots in its base name.
//!
//! **The three checks of boundary.md §4 run before a byte is written**, and
//! all three are things Elm does not do. Check 1 (the two-shape type rule)
//! is here because it reads the `Bir` annotation; checks 2 and 3 are
//! `js/Sibling.zig`'s, because they read JavaScript.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const Lower = @import("Lower.zig");
const Print = @import("Print.zig");
const Sibling = @import("Sibling.zig");

const Emit = @This();

/// A diagnostic this phase produces, before rendering: a file, a token and
/// the message. Same shape as `Graph.Item` and for the same reason — the
/// session turns a token into a span and nothing else here needs positions.
pub const Item = struct {
    code: diagnostic.Code,
    file: SourceStore.Index,
    token: u32,
    /// Owned by the caller's allocator.
    message: []const u8,
};

/// What a platform package tells the emitter (boundary.md §5.2).
pub const Platform = struct {
    /// Module-qualified name of the opaque `Program` type `main` must have.
    program: []const u8,
    /// The runtime file, relative to the platform package root, whose `run`
    /// export is handed `main`'s value.
    runtime: []const u8,
    /// The platform package's root, as paths in the `SourceStore` spell it.
    root: []const u8,
};

/// A file the build must copy out verbatim: a sibling `.js`, or a
/// platform's runtime. Embedded copies come from the binary; anything else
/// is read from disk.
pub const Asset = struct {
    /// Path as the `SourceStore` spells it (`core/Basics.js`).
    path: []const u8,
    bytes: []const u8,
};

pub const Options = struct {
    out_dir: []const u8,
    platform: Platform,
    /// Files embedded in the compiler binary, by store path.
    embedded: []const Asset,
    /// `--source-maps`. Accepted and ignored in M3a: positions are in the
    /// IR from the start (§9.6) but the VLQ encoder is M3's later half.
    source_maps: bool = false,
};

pub const Result = struct {
    /// Owned; messages are gpa-owned.
    diagnostics: []const Item,
    /// Files written, for the profile counter and the summary line.
    files_written: u32,
    bytes_written: u64,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        for (r.diagnostics) |d| gpa.free(d.message);
        gpa.free(r.diagnostics);
        r.* = undefined;
    }
};

pub const Error = error{
    /// A file could not be written. `io_failure` says which.
    OutputPath,
} || Allocator.Error;

/// Check the platform contract and emit. `scratch` is an arena the caller
/// resets afterwards; nothing here frees individually.
pub fn run(
    gpa: Allocator,
    scratch: Allocator,
    session: *Session,
    options: Options,
    io_failure: *?Session.IoFailure,
) Error!Result {
    var e: Emitter = .{
        .gpa = gpa,
        .scratch = scratch,
        .session = session,
        .options = options,
        .io_failure = io_failure,
    };
    errdefer for (e.diagnostics.items) |d| gpa.free(d.message);

    try e.checkForeignShapes();
    try e.checkSiblings();
    const entry = try e.findEntry();
    if (e.diagnostics.items.len != 0 or entry == null) return e.nothingWritten(gpa);

    // Everything is produced into `pending` first and written afterwards.
    // A diagnostic can still appear here — `?` is not compiled yet
    // (backend.md §1) and says so — and a build that wrote half its modules
    // before finding out would leave an `out/` that looks fresh and is not.
    // Nothing is emitted until the whole project is known to emit.
    try e.emitModules(entry.?);
    try e.copyAssets();
    try e.emitEntry(entry.?);
    if (e.diagnostics.items.len != 0) return e.nothingWritten(gpa);

    try e.flush();
    return .{
        .diagnostics = try e.diagnostics.toOwnedSlice(gpa),
        .files_written = e.files_written,
        .bytes_written = e.bytes_written,
    };
}

const Emitter = struct {
    gpa: Allocator,
    scratch: Allocator,
    session: *Session,
    options: Options,
    io_failure: *?Session.IoFailure,
    diagnostics: std.ArrayList(Item) = .empty,
    /// What the build produced, path and bytes, before any of it reaches
    /// the disk. Scratch-owned.
    pending: std.ArrayList(Output) = .empty,
    files_written: u32 = 0,
    bytes_written: u64 = 0,

    const Output = struct { path: []const u8, bytes: []const u8 };

    fn nothingWritten(e: *Emitter, gpa: Allocator) Allocator.Error!Result {
        return .{
            .diagnostics = try e.diagnostics.toOwnedSlice(gpa),
            .files_written = 0,
            .bytes_written = 0,
        };
    }

    /// A `foreign` value's name and the token that declared it, so a
    /// mismatch points at the declaration and not at the module.
    const Declared = struct { name: []const u8, token: u32 };

    fn graph(e: *Emitter) *const Graph {
        return &e.session.graph;
    }

    fn bir(e: *Emitter, m: Graph.Index) *const Bir {
        return e.session.artifacts.bir(e.graph().moduleFile(m));
    }

    fn report(e: *Emitter, code: diagnostic.Code, file: SourceStore.Index, token: u32, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(e.gpa, fmt, args);
        errdefer e.gpa.free(message);
        try e.diagnostics.append(e.gpa, .{ .code = code, .file = file, .token = token, .message = message });
    }

    // ---- boundary.md §4, check 1: the two-shape type rule -----------------

    /// Either (a) a function over admitted types, or (b) an effect value.
    ///
    /// M3a has no effect types yet (`Task`, `Cmd` and `Sub` arrive with B3
    /// and B4), so shape (b) is approximated by its structural property: a
    /// CONCRETE type, with no type variable anywhere in it. That admits
    /// `foreign pi : Float` and `foreign type Program`'s values, and
    /// refuses `foreign xs : List a` and `foreign anything : a`, which are
    /// the shapes that would let a `foreign` invent a value of a type the
    /// caller chose.
    ///
    /// **This is weaker than §4 as written, and §4 as written is wrong.**
    /// §4 says "all 65 of core's current foreign values are shape (a)";
    /// `Basics.e` and `Basics.pi` are not functions and never were, so the
    /// rule as stated rejects core. The rule the compiler can actually
    /// enforce is about the TYPE, and the dangerous case §4 names —
    /// `foreign now : Float` — is indistinguishable from `pi` by type
    /// alone. What the check buys is real but narrower than advertised: no
    /// `foreign` may be polymorphic in a way that lets it fabricate a value.
    fn checkForeignShapes(e: *Emitter) !void {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            const b = e.bir(m);
            for (b.decls) |d| {
                if (d.kind != .foreign_value) continue;
                const annotation = d.annotation.unwrap() orelse continue;
                if (b.instTag(annotation) == .type_fn) continue;
                const offender = firstTypeVar(b, annotation) orelse continue;
                _ = offender;
                try e.report(
                    .foreign_bad_shape,
                    file,
                    d.name_token,
                    \\This `foreign` value is neither a function nor a concrete value.
                    \\
                    \\A `foreign` declaration binds to JavaScript, and the type is all the compiler
                    \\can check about it (`docs/design/boundary.md` §4). It must be a function, or a
                    \\value of a type with no variables in it. A polymorphic value like this one
                    \\claims to produce whatever the caller asks for, which nothing in JavaScript
                    \\can honour.
                ,
                    .{},
                );
            }
        }
    }

    // ---- boundary.md §4, checks 2 and 3 -----------------------------------

    fn checkSiblings(e: *Emitter) !void {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            const b = e.bir(m);

            var declared: std.ArrayList(Declared) = .empty;
            for (b.decls) |d| {
                if (d.kind != .foreign_value) continue;
                try declared.append(e.scratch, .{
                    .name = e.session.interner.slice(b.symbol(d.name)),
                    .token = d.name_token,
                });
            }
            if (declared.items.len == 0) continue;
            const first_token = declared.items[0].token;

            const source_path = e.session.store.path(file);
            const sibling_path = try e.siblingPath(source_path);
            const bytes = e.readAsset(sibling_path) orelse {
                try e.report(
                    .foreign_sibling_missing,
                    file,
                    first_token,
                    \\I cannot find `{s}`.
                    \\
                    \\A module with `foreign` declarations binds them to a sibling JavaScript file
                    \\of the same name, one export per foreign value
                    \\(`docs/design/boundary.md` §4). Write that file next to `{s}`.
                ,
                    .{ sibling_path, source_path },
                );
                continue;
            };

            const found = try Sibling.scan(e.scratch, bytes);
            try e.compareExports(file, first_token, sibling_path, declared.items, found.exports);
            for (found.relative_imports) |specifier| {
                try e.report(
                    .not_implemented,
                    file,
                    first_token,
                    \\`{s}` imports {s}, and I cannot relocate that yet.
                    \\
                    \\A sibling file is RENAMED as it is copied into the output — `{s}` becomes
                    \\`<Module>{s}`, so that every emitted file is an ES module by extension
                    \\(`docs/design/backend.md` §2). A specifier that names a file would then point
                    \\at a name that no longer exists, and the build would succeed while the program
                    \\failed to load. Rewriting them is M3b's; for now, import a package
                    \\(`node:process`, a dependency) or inline the helper.
                ,
                    .{ sibling_path, specifier, std.fs.path.basename(sibling_path), foreign_extension },
                );
            }
            for (found.unbound) |reference| {
                try e.report(
                    .foreign_unbound_reference,
                    file,
                    first_token,
                    \\`{s}` uses `{s}`, which it never imports.
                    \\
                    \\A sibling file's references have to be covered by its own `import`
                    \\statements (`docs/design/boundary.md` §4, check 3). That is what keeps dead
                    \\code elimination declaration-granular: the compiler reads the imports to
                    \\learn the file's dependencies, and a name that comes from nowhere is an edge
                    \\it cannot see. Write `import {s} from "node:{s}";` — or whatever module
                    \\really provides it — at the top of the file.
                ,
                    .{ sibling_path, reference, reference, reference },
                );
            }
        }
    }

    fn compareExports(
        e: *Emitter,
        file: SourceStore.Index,
        token: u32,
        sibling_path: []const u8,
        declared: []const Declared,
        exported: []const []const u8,
    ) !void {
        for (declared) |entry| {
            const name = entry.name;
            if (contains(exported, name)) continue;
            try e.report(
                .foreign_export_mismatch,
                file,
                entry.token,
                \\`{s}` does not export `{s}`.
                \\
                \\A sibling JavaScript file exports exactly the `foreign` values its module
                \\declares — no more, no fewer (`docs/design/boundary.md` §4, check 2). Add
                \\`export const {s} = …;` to it, or delete the `foreign` declaration.
            ,
                .{ sibling_path, name, name },
            );
        }
        for (exported) |name| {
            if (containsDeclared(declared, name)) continue;
            try e.report(
                .foreign_export_mismatch,
                file,
                token,
                \\`{s}` exports `{s}`, which is not a `foreign` value of this module.
                \\
                \\A sibling JavaScript file exports exactly the `foreign` values its module
                \\declares — no more, no fewer (`docs/design/boundary.md` §4, check 2). One
                \\export per foreign value is one node in the dependency graph per foreign value,
                \\which is what keeps elimination declaration-granular; an extra export is a node
                \\nothing can reach. Declare `foreign {s} : …`, or stop exporting it.
            ,
                .{ sibling_path, name, name },
            );
        }
    }

    // ---- boundary.md §5: `main`, resolved per platform --------------------

    /// The module that declares `main`, and the declaration's index.
    ///
    /// The entry point is found rather than named on the command line: a
    /// build is a pair of entry point and platform (§5.3), and in a project
    /// with one `main` the entry point is not information the user should
    /// have to repeat. A project with two would be two builds, which is
    /// exactly §5.3's full-stack case, and M3a says so rather than guessing.
    fn findEntry(e: *Emitter) !?Entry {
        var found: ?Entry = null;
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            const file = e.graph().moduleFile(m);
            if (e.session.store.package(file) != .app) continue;
            const b = e.bir(m);
            for (b.decls, 0..) |d, index| {
                if (d.kind != .value) continue;
                if (b.symbol(d.name) != InternPool.WellKnown.main.symbol()) continue;
                if (found) |previous| {
                    try e.report(
                        .missing_main,
                        file,
                        d.name_token,
                        \\This project has more than one `main`.
                        \\
                        \\`{s}` and `{s}` both declare one, and a build is a pair of ONE entry
                        \\point and ONE platform (`docs/design/boundary.md` §5.3). Build them
                        \\separately.
                    ,
                        .{
                            e.session.store.moduleName(e.graph().moduleFile(previous.module)),
                            e.session.store.moduleName(file),
                        },
                    );
                    return null;
                }
                found = .{ .module = m, .decl = @enumFromInt(@as(u32, @intCast(index))) };
            }
        }
        const entry = found orelse {
            const file: SourceStore.Index = @enumFromInt(0);
            try e.report(
                .missing_main,
                file,
                0,
                \\I cannot find `main`.
                \\
                \\A program's entry point is a declaration called `main` whose type is the
                \\`Program` the platform owns — here `{s}` (`docs/design/boundary.md` §5). Add
                \\one to a module of this project.
            ,
                .{e.options.platform.program},
            );
            return null;
        };
        try e.checkMainType(entry);
        return entry;
    }

    const Entry = struct { module: Graph.Index, decl: Bir.DeclIndex };

    /// `main`'s type is a platform fact (§5), so it is checked against the
    /// platform's declared `Program` rather than against a hardcoded name.
    ///
    /// The check reads the ANNOTATION and requires there to be one. That is
    /// a real rule and worth stating: `main` is where the program meets the
    /// platform, and an inferred type there would let a build succeed with
    /// `main` bound to something the runtime cannot run. With the annotation
    /// present the checker has already proved the body matches it, so
    /// comparing the annotation is a complete check and costs no inference.
    fn checkMainType(e: *Emitter, entry: Entry) !void {
        const file = e.graph().moduleFile(entry.module);
        const b = e.bir(entry.module);
        const d = b.decl(entry.decl);
        const annotation = d.annotation.unwrap() orelse return e.report(
            .main_not_program,
            file,
            d.name_token,
            \\`main` needs a type annotation.
            \\
            \\It is where your program meets the platform, and the platform decides what type
            \\it has (`docs/design/boundary.md` §5). Write:
            \\
            \\    main : {s}
            \\
            \\above the definition.
        ,
            .{shortName(e.options.platform.program)},
        );
        const actual = e.typeName(b, annotation) orelse "";
        if (std.mem.eql(u8, actual, e.options.platform.program)) return;
        try e.report(
            .main_not_program,
            file,
            d.name_token,
            \\`main` must be a `{s}`.
            \\
            \\This one is annotated `{s}`. The platform owns the type of the entry point and
            \\hands out the only values of it (`docs/design/boundary.md` §5); a `Program` is
            \\what you get back from one of its functions.
        ,
            .{ e.options.platform.program, if (actual.len == 0) "something else" else actual },
        );
    }

    /// `Module.Type` for a resolved type reference, or null for anything
    /// else (a function, a record, an application).
    fn typeName(e: *Emitter, b: *const Bir, inst: Bir.Inst.Index) ?[]const u8 {
        const d = b.instData(inst);
        switch (b.instTag(inst)) {
            .ext_type => {
                const m: Graph.Index = @enumFromInt(d.lhs);
                if (m.int() >= e.session.resolution.interfaces.len) return null;
                const iface = &e.session.resolution.interfaces[m.int()];
                if (d.rhs >= iface.types.len) return null;
                const module = e.session.interner.slice(e.graph().moduleName(m));
                const name = e.session.interner.slice(iface.symbols[@intFromEnum(iface.types[d.rhs].name)]);
                return std.fmt.allocPrint(e.scratch, "{s}.{s}", .{ module, name }) catch null;
            },
            .type_top => {
                if (d.lhs >= b.decls.len) return null;
                return std.fmt.allocPrint(e.scratch, "{s}.{s}", .{
                    e.session.store.moduleName(e.graph().moduleFile(e.currentModuleOf(b))),
                    e.session.interner.slice(b.symbol(b.decls[d.lhs].name)),
                }) catch null;
            },
            else => return null,
        }
    }

    fn currentModuleOf(e: *Emitter, b: *const Bir) Graph.Index {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(i);
            if (e.bir(m) == b) return m;
        }
        return @enumFromInt(0);
    }

    // ---- Emission ---------------------------------------------------------

    fn emitModules(e: *Emitter, entry: Entry) !void {
        const count = e.graph().count();
        // The output path of every module, so a specifier is a string join
        // and not a second walk.
        const paths = try e.scratch.alloc([]const u8, count);
        for (paths, 0..) |*slot, i| slot.* = try e.outputPath(@enumFromInt(@as(u32, @intCast(i))));

        for (0..count) |i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            const file = e.graph().moduleFile(m);
            const specifiers = try e.scratch.alloc([]const u8, count);
            for (specifiers, paths) |*slot, to| slot.* = try relativeSpecifier(e.scratch, paths[i], to);

            const source_path = e.session.store.path(file);
            const sibling = try e.siblingSpecifier(source_path);
            const tokens = e.session.artifacts.tokens(file);

            var lowered = try Lower.lower(e.gpa, e.scratch, &e.session.interner, .{
                .bir = e.bir(m),
                .token_starts = tokens.items(.start),
                .module = m,
                .graph = e.graph(),
                .interfaces = e.session.resolution.interfaces,
                .specifiers = specifiers,
                .sibling = sibling,
                .entry_decl = if (m == entry.module) entry.decl.int() else null,
            });
            defer lowered.ir.deinit(e.gpa);
            defer e.gpa.free(lowered.diagnostics);
            for (lowered.diagnostics) |d| {
                const token = if (d.region.int() < e.bir(m).insts.len)
                    e.bir(m).insts.items(.main_token)[d.region.int()]
                else
                    0;
                try e.diagnostics.append(e.gpa, .{ .code = d.code, .file = file, .token = token, .message = d.message });
            }
            if (lowered.diagnostics.len != 0) continue;

            const text = try Print.print(e.gpa, &lowered.ir, .fromGlobal(&e.session.interner));
            defer e.gpa.free(text);
            try e.produce(paths[i], text);
        }
    }

    /// Sibling `.js` files and the platform runtime, copied verbatim next to
    /// the modules that import them.
    fn copyAssets(e: *Emitter) !void {
        for (0..e.graph().count()) |i| {
            const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            const b = e.bir(m);
            var has_foreign = false;
            for (b.decls) |d| {
                if (d.kind == .foreign_value) has_foreign = true;
            }
            if (!has_foreign) continue;
            const source_path = e.session.store.path(e.graph().moduleFile(m));
            const sibling_source = try e.siblingPath(source_path);
            const bytes = e.readAsset(sibling_source) orelse continue;
            const out = try e.siblingOutputPath(m);
            try e.produce(out, bytes);
        }
        // The platform's runtime (§5.2). It is not a sibling of any module,
        // so nothing above would have copied it.
        const runtime_source = try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{
            e.options.platform.root,
            e.options.platform.runtime,
        });
        const bytes = e.readAsset(runtime_source) orelse {
            try e.report(
                .foreign_sibling_missing,
                @enumFromInt(0),
                0,
                \\I cannot find the platform's runtime file `{s}`.
                \\
                \\A platform declares its output shape in its manifest (`"runtime"`), and that
                \\file is what the entry point hands `main` to
                \\(`docs/design/boundary.md` §5.2).
            ,
                .{runtime_source},
            );
            return;
        };
        try e.produce(try e.runtimeOutputPath(), bytes);
    }

    /// The entry file. A platform declares how `main` is invoked (§5.2) and
    /// this is the smallest honest form of that: import the runtime's `run`,
    /// import `main`, apply one to the other.
    fn emitEntry(e: *Emitter, entry: Entry) !void {
        const module_path = try e.outputPath(entry.module);
        const runtime_path = try e.runtimeOutputPath();
        const module_name = e.session.store.moduleName(e.graph().moduleFile(entry.module));
        var qualified: std.ArrayList(u8) = .empty;
        for (module_name) |c| try qualified.append(e.scratch, if (c == '.') '$' else c);
        try qualified.appendSlice(e.scratch, "$main");

        const text = try std.fmt.allocPrint(e.scratch,
            \\// Generated by `beni build` (docs/design/boundary.md §5.2): the entry file
            \\// the platform's output shape asks for.
            \\import {{ run }} from "./{s}";
            \\import {{ {s} }} from "./{s}";
            \\
            \\run({s});
            \\
        , .{ runtime_path, qualified.items, module_path, qualified.items });
        try e.produce("main.mjs", text);
    }

    // ---- Paths and files --------------------------------------------------

    /// `<package prefix>/<module name with dots as directories>.mjs`.
    fn outputPath(e: *Emitter, m: Graph.Index) ![]const u8 {
        const file = e.graph().moduleFile(m);
        const prefix: []const u8 = switch (e.session.store.package(file)) {
            .app => "",
            .core => "core/",
            .platform => "platform/",
        };
        const name = e.session.store.moduleName(file);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(e.scratch, prefix);
        for (name) |c| try out.append(e.scratch, if (c == '.') '/' else c);
        try out.appendSlice(e.scratch, ".mjs");
        return out.items;
    }

    /// Where a module's sibling JavaScript is WRITTEN: beside the module,
    /// under `.foreign.mjs`. See the header for why it is not `.js`.
    fn siblingOutputPath(e: *Emitter, m: Graph.Index) ![]const u8 {
        const mjs = try e.outputPath(m);
        return std.fmt.allocPrint(e.scratch, "{s}{s}", .{ mjs[0 .. mjs.len - ".mjs".len], foreign_extension });
    }

    /// Where a module's sibling JavaScript is READ from: next to the source,
    /// under its own name. `core/Basics.beni` becomes `core/Basics.js`.
    fn siblingPath(e: *Emitter, source_path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(e.scratch, "{s}.js", .{stripExtension(source_path, SourceStore.extension)});
    }

    /// What the emitted module writes in its `import`: the sibling sits in
    /// the same output directory, so it is `./Name.foreign.mjs`.
    fn siblingSpecifier(e: *Emitter, source_path: []const u8) ![]const u8 {
        const base = std.fs.path.basename(source_path);
        return std.fmt.allocPrint(e.scratch, "./{s}{s}", .{ stripExtension(base, SourceStore.extension), foreign_extension });
    }

    /// Where the platform's runtime is written. It is not a sibling of any
    /// module, but it is hand-written JavaScript all the same, so it takes
    /// the same extension — and that is also what keeps a platform whose
    /// runtime is called `Node.js` from overwriting the module `Node`.
    fn runtimeOutputPath(e: *Emitter) ![]const u8 {
        const base = std.fs.path.basename(e.options.platform.runtime);
        return std.fmt.allocPrint(e.scratch, "platform/{s}{s}", .{ stripExtension(base, ".js"), foreign_extension });
    }

    /// The bytes of an asset: the embedded copy when the compiler carries
    /// one, else the file on disk.
    fn readAsset(e: *Emitter, path: []const u8) ?[]const u8 {
        for (e.options.embedded) |asset| {
            if (std.mem.eql(u8, asset.path, path)) return asset.bytes;
        }
        return Io.Dir.cwd().readFileAlloc(e.session.io, path, e.scratch, .limited(max_asset_bytes)) catch null;
    }

    /// Record one output file. `bytes` is copied into the scratch arena
    /// because the printer's buffer is freed as soon as the module is done.
    fn produce(e: *Emitter, relative_path: []const u8, bytes: []const u8) Allocator.Error!void {
        try e.pending.append(e.scratch, .{
            .path = try e.scratch.dupe(u8, relative_path),
            .bytes = try e.scratch.dupe(u8, bytes),
        });
    }

    /// Write everything, in the order it was produced. The first failure
    /// stops the build; a half-written `out/` is the price of a disk that
    /// filled up, not of a diagnostic.
    fn flush(e: *Emitter) Error!void {
        for (e.pending.items) |output| {
            const path = std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ e.options.out_dir, output.path }) catch
                return error.OutOfMemory;
            if (std.fs.path.dirname(path)) |dir| {
                Io.Dir.cwd().createDirPath(e.session.io, dir) catch |err| {
                    e.io_failure.* = .{ .path = dir, .err = err };
                    return error.OutputPath;
                };
            }
            Io.Dir.cwd().writeFile(e.session.io, .{ .sub_path = path, .data = output.bytes }) catch |err| {
                e.io_failure.* = .{ .path = path, .err = err };
                return error.OutputPath;
            };
            e.files_written += 1;
            e.bytes_written += output.bytes.len;
        }
    }
};

/// What a hand-written JavaScript file is called once the build has copied
/// it into the output tree. `backend.md` §2 requires every emitted file to be
/// `.mjs`; the `.foreign` part keeps the copy from colliding with the
/// generated module of the same name and says which half of the module it is.
pub const foreign_extension = ".foreign.mjs";

/// `name` without `extension`, or `name` when it does not end in one.
fn stripExtension(name: []const u8, extension: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, extension))
        name[0 .. name.len - extension.len]
    else
        name;
}

/// Largest sibling or runtime file read. Privileged JavaScript is small by
/// construction — one export per foreign value — and a file past this is a
/// mistake worth failing on rather than allocating for.
pub const max_asset_bytes = 8 * 1024 * 1024;

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn containsDeclared(haystack: []const Emitter.Declared, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item.name, needle)) return true;
    }
    return false;
}

fn shortName(qualified: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse return qualified;
    return qualified[dot + 1 ..];
}

/// The first type variable reachable from `inst`, or null when the type is
/// concrete. Iterative: a type is a tree the parser bounds, but the bound is
/// 4096 levels (language.md §10) and recursion here would be bounded by the
/// C stack instead of by the input.
fn firstTypeVar(b: *const Bir, root: Bir.Inst.Index) ?Bir.Inst.Index {
    var stack: [64]Bir.Inst.Index = undefined;
    var depth: usize = 1;
    stack[0] = root;
    var budget: u32 = 4096;
    while (depth != 0) {
        budget -= 1;
        if (budget == 0) return null;
        depth -= 1;
        const inst = stack[depth];
        if (inst.int() >= b.insts.len) continue;
        const d = b.instData(inst);
        switch (b.instTag(inst)) {
            .type_var => return inst,
            .type_fn => {
                const params = b.extraSlice(b.subRange(@enumFromInt(d.lhs)), Bir.Inst.Index);
                if (depth + params.len + 1 > stack.len) return null;
                for (params) |param| {
                    stack[depth] = param;
                    depth += 1;
                }
                stack[depth] = @enumFromInt(d.rhs);
                depth += 1;
            },
            .type_app => {
                for (b.extraSlice(b.subRange(@enumFromInt(d.rhs)), Bir.Inst.Index)) |child| {
                    if (depth >= stack.len) return null;
                    stack[depth] = child;
                    depth += 1;
                }
            },
            .type_tuple => {
                for (b.extraSlice(Bir.inlineRange(d), Bir.Inst.Index)) |child| {
                    if (depth >= stack.len) return null;
                    stack[depth] = child;
                    depth += 1;
                }
            },
            .type_record => {
                for (b.extraSlice(Bir.inlineRange(d), Bir.Field)) |f| {
                    if (depth >= stack.len) return null;
                    stack[depth] = f.value;
                    depth += 1;
                }
            },
            .type_record_ext => return @enumFromInt(d.lhs),
            else => {},
        }
    }
    return null;
}

/// The ESM specifier for `to` as written inside `from`. Both are paths under
/// the output root, so the answer is `../` once per directory `from` sits
/// in, then `to`. It always starts with `./` or `../`, because a bare
/// specifier is a package name in ESM and not a relative path.
fn relativeSpecifier(arena: Allocator, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
    const depth = std.mem.count(u8, from, "/");
    var out: std.ArrayList(u8) = .empty;
    if (depth == 0) {
        try out.appendSlice(arena, "./");
    } else {
        for (0..depth) |_| try out.appendSlice(arena, "../");
    }
    try out.appendSlice(arena, to);
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an ESM specifier is relative to the importing file's directory" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("./core/List.mjs", try relativeSpecifier(arena, "Main.mjs", "core/List.mjs"));
    try testing.expectEqualStrings("../core/List.mjs", try relativeSpecifier(arena, "Dict/Int.mjs", "core/List.mjs"));
    try testing.expectEqualStrings("../../Main.mjs", try relativeSpecifier(arena, "a/b/C.mjs", "Main.mjs"));
    try testing.expectEqualStrings("./Main.mjs", try relativeSpecifier(arena, "Other.mjs", "Main.mjs"));
}

test "a qualified platform type shortens to its own name for the hint" {
    try testing.expectEqualStrings("Program", shortName("Node.Program"));
    try testing.expectEqualStrings("Program", shortName("Program"));
}
