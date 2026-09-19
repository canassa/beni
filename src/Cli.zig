//! Command-line parsing (docs/design/frontend.md §1).
//!
//! Pure: bytes in, a `Command` or a usage message out, no I/O — so the whole
//! surface is covered by the hermetic suite, and `main.zig` is only the
//! dispatch. Every usage error is a one-line message; `main` prints it to
//! stderr and exits 2. The wording is part of the black-box contract.
//!
//! ```
//! beni build  [options] --platform=<name> <path>...
//! beni check  [options] [--platform=<name>] <path>...
//! beni fmt    [options] [--check] [--stdout] <path>...
//! beni dump   [options] --stage=<tokens|ast|bir|interface|raw|types|graph> [--positions] <file>
//! beni version
//! beni help
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const usage =
    \\usage: beni <command> [options] [<path>...]
    \\
    \\commands:
    \\  build    compile to JavaScript for a platform
    \\  check    parse, lower and resolve every module against core; report diagnostics
    \\  fmt      format in place, or --check to verify, or --stdout to print
    \\  dump     print one file's IR as text (--stage=tokens|ast|bir|interface|raw|types|graph|dispatch)
    \\  version  print the version
    \\  help     print this text
    \\
    \\options (all commands):
    \\  --diagnostics=text|json   diagnostics on stderr as prose (default) or one JSON array
    \\  --self-profile=<path>     write a Chrome trace-event JSON file at exit
    \\  --jobs=<n>                worker threads (default: logical CPUs, capped at 4x that); output is identical for every n
    \\  --root=<dir>              the source root module names are derived from
    \\  --core                    treat the files as the core package (`foreign` declarations are legal)
    \\  --core-root=<dir>         read the core package from this directory instead of the embedded copy
    \\  --explain                 accepted; currently governs no diagnostic (all informational ones are on)
    \\  --pattern-budget=<n>      work one `case` may spend proving exhaustiveness before it is refused
    \\
    \\check and build options:
    \\  --cache-dir=<path>        keep checked modules between runs in this directory (no default)
    \\  --no-cache                ignore --cache-dir and any default
    \\
    \\check options:
    \\  --platform=<name>         also load this platform package, exactly as build does; optional,
    \\                            and with it the sibling checks of a build run too
    \\
    \\build options:
    \\  --platform=<name>         which platform supplies `main`'s type and the runtime (required)
    \\  --out=<dir>               output directory (default: out)
    \\  --library                 no `main` is required and no entry file is written; every exported name is a reachability root
    \\  --source-maps             emit .map files (not implemented until M5)
    \\  --release                 dead bindings out, short names, compact printing, joined consts
    \\
    \\fmt options:
    \\  --check                   exit 1 if any file would change; write nothing
    \\  --stdout                  print the formatted text instead of writing it
    \\
    \\dump options:
    \\  --stage=tokens|ast|bir|interface|raw|types|graph|dispatch
    \\                            which representation to print (required)
    \\  --positions               include source positions
    \\  --platform=<name>         as check's, for the stages that resolve imports (interface, raw,
    \\                            types, graph, dispatch); refused on the others
    \\
    \\exit codes: 0 no errors, 1 at least one error diagnostic, 2 usage or I/O failure
    \\
;

pub const DiagnosticsFormat = enum { text, json };
/// `raw` is `interface`'s record verbatim rather than its rendered form
/// (`dump/interface.zig`'s `writeRaw`): the pretty dump goes through the
/// type renderer, which re-sorts a record's fields by text, so it cannot
/// see a difference in the bytes `fast-compiler.md` §8.1 has M4 hashing.
/// It exists so a test can assert "the same at every `--jobs`" about the
/// record and not about a printer.
pub const Stage = enum { tokens, ast, bir, interface, raw, types, graph, dispatch };

/// Options every subcommand accepts.
pub const Common = struct {
    diagnostics: DiagnosticsFormat = .text,
    self_profile: ?[]const u8 = null,
    /// null means "logical CPUs", decided by `main`.
    jobs: ?u32 = null,
    root: ?[]const u8 = null,
    /// `--core`: the files are the core package, where `foreign` is legal.
    core: bool = false,
    /// `--core-root=<dir>`: read core from there instead of the embedded
    /// copy (checker.md §2).
    core_root: ?[]const u8 = null,
    /// `--pattern-budget=<n>`: the work one `case` may spend on the
    /// usefulness analysis (checker.md §6.6). null means the default.
    ///
    /// It is a flag and not only a test knob because exhausting it is now an
    /// ERROR (`pattern_budget_exhausted`), and a diagnostic that says "this
    /// was too big to decide" has to leave the author a way to say "decide it
    /// anyway". The message names this flag, so the flag has to exist.
    pattern_budget: ?u32 = null,
    /// `--explain`: emit the informational diagnostics that are otherwise
    /// suppressed (static-dispatch-spike.md §10 preamble, A.10).
    ///
    /// **It governs nothing today** (A.83). The one diagnostic it gated,
    /// `ambiguous_method_receiver`, has been emitted by default since
    /// 2026-09-18. The flag stays parsed and accepted so no invocation that
    /// passes it starts exiting `2`, and it is where the next informational
    /// diagnostic goes.
    explain: bool = false,
    /// `--roundtrip-interfaces` — **hidden**, and hidden on purpose
    /// (`fast-compiler.md` §8's *The interface hash, and slice zero*).
    ///
    /// Every module's record is written to bytes and read back IN PLACE the
    /// moment its check finishes, so every dependent, every dump, every
    /// dispatch table and every emitted file downstream is built from a
    /// record that has been through `resolve/iface_bytes.zig`. A run with it
    /// must be byte-identical to one without, which is the acceptance test
    /// of the whole slice.
    ///
    /// It is absent from `usage` and from `checker.md` §2's table because it
    /// is diagnostic surface, not product surface. A test-only entry point
    /// was the alternative and is refused: the suite is black-box, and an
    /// in-source hook would move the assertion off the thing that ships.
    roundtrip_interfaces: bool = false,
    /// `--roundtrip-dispatch` — hidden, and `--roundtrip-interfaces`' twin
    /// for the cache entry's sidecar (`fast-compiler.md` §8).
    ///
    /// On `Common` rather than on `check` and `build`, exactly as its twin
    /// is, because every command that resolves runs the checker and the
    /// acceptance matrix has to be able to pass it to `dump` as well.
    roundtrip_dispatch: bool = false,
    /// `--roundtrip-frontend` — hidden, and the third of that family
    /// (`fast-compiler.md` §8's *The front-end artifacts, and the file key*,
    /// `frontend.md` §1). The first that is not the checker's: every file's
    /// `Bir`, token spans, line-start table and front-end diagnostics are
    /// written to bytes and read back IN PLACE the moment its per-file phase
    /// ends and before anything downstream reads them.
    ///
    /// On `Common` like its two siblings, because `dump` has to be able to
    /// take it: `dump --stage=bir` is the lossless textual form of exactly
    /// these artifacts and is therefore the identity oracle the round trip is
    /// asserted against.
    roundtrip_frontend: bool = false,
    /// `--iface-hash` — hidden, for `--roundtrip-interfaces`' reasons.
    /// Makes `check` print one `<package>:<Module> <32 hex digits>` line per
    /// module, `core` and the platform included, sorted by that key.
    iface_hash: bool = false,
};

/// The persistent cache's flags (`frontend.md` §1, `fast-compiler.md` §8).
///
/// **They belong to `check` and `build` and to no other subcommand.** `fmt`
/// resolves nothing and `dump` prints a representation rather than a result,
/// so a cache flag on either would be accepted and do nothing — the mistake
/// `--source-maps` is refused to avoid. `fmt --cache-dir=x` is therefore the
/// ordinary `unknown option` and exit `2`, which falls out of the field
/// living here rather than on `Common`.
pub const Cache = struct {
    /// `--cache-dir=<path>`: keep checked modules between runs in this
    /// directory. **No default — in M4-1 the cache is opt-in**
    /// (`fast-compiler.md` §8); it becomes the default in M4-3, the slice
    /// whose cutoff makes it worth having.
    dir: ?[]const u8 = null,
    /// `--no-cache`: ignore `--cache-dir` and any default. It exists BEFORE
    /// there is a default so that a script written today keeps working the
    /// day the default arrives.
    off: bool = false,
    /// `--cache-build-id=<s>` — **hidden**, for `--roundtrip-interfaces`'
    /// reasons. Its bytes replace the compiler build id in the cache key
    /// (`src/build_id.zig`), which is how "a compiler change discards the
    /// whole cache" is written as a fixture rather than as a rebuild.
    build_id: ?[]const u8 = null,
    /// `--cache-keys` — hidden, and `check`'s alone. One
    /// `<package>:<Module> <32 hex digits>` line per module on stdout,
    /// sorted by that key, exactly as `--iface-hash` prints the record's.
    ///
    /// It is how an edit-scenario fixture asserts *which* modules a change
    /// reached, with no cache directory involved — which is why it lands
    /// before a byte is ever written to disk.
    keys: bool = false,
    /// `--frontend-keys` — hidden, `check`'s alone, and `--cache-keys`' twin
    /// (M4-2, `frontend.md` §1). One `<path> <32 hex digits>` line per FILE
    /// on stdout, sorted by path.
    ///
    /// The two are printed side by side in the edit-scenario table because
    /// the DIVERGENCE between them is the whole reason M4-2 exists: a body
    /// edit in a leaf moves one file key and three module keys, so the leaf
    /// re-lowers and its importers re-check without re-lowering. A key per
    /// file and not per module, because the front end is per file — a path
    /// that names no module still has one.
    frontend_keys: bool = false,
};

pub const Check = struct {
    common: Common = .{},
    cache: Cache = .{},
    /// `--platform`: the same value `build` takes, resolved the same way
    /// (frontend.md §1, boundary.md §5.3). **Optional here**, because a
    /// library and a platform-free module must stay checkable; null is "no
    /// platform", which is what `check` ran with until 2026-09-18 and what
    /// made it useless on every program that imports its platform for
    /// `Program`.
    platform: ?[]const u8 = null,
    paths: []const []const u8,
};

pub const Build = struct {
    common: Common = .{},
    cache: Cache = .{},
    /// `--platform`: an embedded platform's name, or a directory holding a
    /// package whose manifest says `"platform": true` (boundary.md §2).
    platform: []const u8,
    out: []const u8 = default_out,
    /// `--library` (backend.md §2): no `main` is required, no entry file is
    /// written, and §9's reachability roots are every name the root
    /// package's modules export.
    ///
    /// **It is not in `--source-maps`' company**: that one is refused
    /// because it is not implemented, and this one lands with §9 and does
    /// something the day it lands.
    library: bool = false,
    /// `--release` (backend.md §2, §9): local dead bindings out, short
    /// names, compact printing and joined `const` runs. It takes no value,
    /// composes with `--library`, `--out` and `--jobs`, and **implies
    /// nothing** — elimination is always on and there are no source maps to
    /// switch off.
    release: bool = false,
    /// `--allow-debug` — **hidden**, and hidden for exactly
    /// `--roundtrip-interfaces`' reason: it is diagnostic surface, not
    /// product surface.
    ///
    /// It turns off one thing and nothing else — `backend.md` §9's refusal
    /// of a `--release` build that still reaches `core/Debug` — and it does
    /// not change a byte of what either build emits. It exists because
    /// `Debug.log` is the corpus's only instrument for observing evaluation
    /// order, and the `--release` second pass over all 121 `run/` fixtures
    /// is what proved the wide inliner unsafe (`backend.md` §9 item 1). A
    /// refusal with no way past it would blind that pass, which is the one
    /// guard a minifier's failure mode has.
    ///
    /// Absent from `usage`, and from `backend.md` §2's table, for the same
    /// reason: a user has no business reaching for it, and the alternative —
    /// a test-only entry point — would move the assertion off the thing
    /// that ships.
    allow_debug: bool = false,
    /// No `source_maps` field: `parseBuild` refuses that flag outright, so
    /// nothing downstream can be handed a setting the backend does not
    /// honour.
    paths: []const []const u8,
};

pub const default_out = "out";

pub const Fmt = struct {
    common: Common = .{},
    check: bool = false,
    stdout: bool = false,
    paths: []const []const u8,
};

pub const Dump = struct {
    common: Common = .{},
    stage: Stage,
    positions: bool = false,
    /// `--platform`, for the stages that resolve imports. `parseDump`
    /// refuses it on the others rather than accepting a flag that does
    /// nothing, which is the rule `--source-maps` set (backend.md §2).
    platform: ?[]const u8 = null,
    file: []const u8,
};

pub const Command = union(enum) {
    build: Build,
    check: Check,
    fmt: Fmt,
    dump: Dump,
    version,
    help,
};

/// A usage error's one-line message, without the trailing newline. Carried
/// by value so `parse` needs no allocator for the failure path.
pub const Usage = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(u: *const Usage) []const u8 {
        return u.buf[0..u.len];
    }

    fn init(comptime fmt: []const u8, args: anytype) Usage {
        var u: Usage = .{};
        const written = std.fmt.bufPrint(&u.buf, fmt, args) catch &u.buf; // truncated is still a message
        u.len = written.len;
        return u;
    }
};

pub const Result = union(enum) {
    command: Command,
    usage: Usage,
};

/// Parse `args` (without the program name). Path lists are allocated from
/// `gpa`; option values are slices of `args`.
pub fn parse(gpa: Allocator, args: []const [:0]const u8) Allocator.Error!Result {
    if (args.len == 0) return .{ .usage = .init("beni: missing subcommand; run 'beni help' for usage", .{}) };
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "version")) {
        if (rest.len != 0) return .{ .usage = .init("beni: version takes no arguments", .{}) };
        return .{ .command = .version };
    }
    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        if (rest.len != 0) return .{ .usage = .init("beni: help takes no arguments", .{}) };
        return .{ .command = .help };
    }
    if (std.mem.eql(u8, sub, "build")) return parseBuild(gpa, rest);
    if (std.mem.eql(u8, sub, "check")) return parseCheck(gpa, rest);
    if (std.mem.eql(u8, sub, "fmt")) return parseFmt(gpa, rest);
    if (std.mem.eql(u8, sub, "dump")) return parseDump(gpa, rest);
    return .{ .usage = .init("beni: unknown subcommand '{s}'; run 'beni help' for usage", .{sub}) };
}

/// One pass over the arguments after the subcommand. Flags known to every
/// command are applied to `common`; command-specific flags are matched by
/// `Specific`; everything else is a positional (after `--`, everything is).
fn Scanner(comptime Specific: type) type {
    return struct {
        common: Common = .{},
        specific: Specific = .{},
        positionals: std.ArrayList([]const u8) = .empty,

        const Self = @This();

        fn scan(self: *Self, gpa: Allocator, args: []const [:0]const u8) Allocator.Error!?Usage {
            var only_positionals = false;
            for (args) |arg| {
                if (only_positionals or arg.len < 2 or arg[0] != '-') {
                    try self.positionals.append(gpa, arg);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--")) {
                    only_positionals = true;
                    continue;
                }
                const eq = std.mem.indexOfScalar(u8, arg, '=');
                const name = if (eq) |i| arg[0..i] else arg;
                const value: ?[]const u8 = if (eq) |i| arg[i + 1 ..] else null;
                if (try self.specific.apply(name, value)) |u| return u;
                if (self.specific.consumed) {
                    self.specific.consumed = false;
                    continue;
                }
                if (try applyCommon(&self.common, name, value)) |u| return u;
            }
            return null;
        }
    };
}

/// Returns a usage error, or null when `name` was handled or is not common.
fn applyCommon(common: *Common, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
    if (std.mem.eql(u8, name, "--diagnostics")) {
        const v = value orelse return needsValue(name, "text|json");
        common.diagnostics = std.meta.stringToEnum(DiagnosticsFormat, v) orelse
            return Usage.init("beni: invalid value '{s}' for --diagnostics (expected text or json)", .{v});
        return null;
    }
    if (std.mem.eql(u8, name, "--self-profile")) {
        const v = value orelse return needsValue(name, "<path>");
        if (v.len == 0) return needsValue(name, "<path>");
        common.self_profile = v;
        return null;
    }
    if (std.mem.eql(u8, name, "--jobs")) {
        const v = value orelse return needsValue(name, "<n>");
        const n = std.fmt.parseInt(u32, v, 10) catch 0;
        if (n == 0) return Usage.init("beni: invalid value '{s}' for --jobs (expected a positive integer)", .{v});
        common.jobs = n;
        return null;
    }
    if (std.mem.eql(u8, name, "--pattern-budget")) {
        const v = value orelse return needsValue(name, "<n>");
        const n = std.fmt.parseInt(u32, v, 10) catch 0;
        if (n == 0) return Usage.init("beni: invalid value '{s}' for --pattern-budget (expected a positive integer)", .{v});
        common.pattern_budget = n;
        return null;
    }
    if (std.mem.eql(u8, name, "--root")) {
        const v = value orelse return needsValue(name, "<dir>");
        if (v.len == 0) return needsValue(name, "<dir>");
        common.root = v;
        return null;
    }
    if (std.mem.eql(u8, name, "--core")) {
        if (value != null) return noValue(name);
        common.core = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--explain")) {
        if (value != null) return noValue(name);
        common.explain = true;
        return null;
    }
    // The two hidden flags of `fast-compiler.md` §8. Accepted like `--jobs`,
    // absent from `usage` — see `Common.roundtrip_interfaces`.
    if (std.mem.eql(u8, name, "--roundtrip-interfaces")) {
        if (value != null) return noValue(name);
        common.roundtrip_interfaces = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--roundtrip-dispatch")) {
        if (value != null) return noValue(name);
        common.roundtrip_dispatch = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--roundtrip-frontend")) {
        if (value != null) return noValue(name);
        common.roundtrip_frontend = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--iface-hash")) {
        if (value != null) return noValue(name);
        common.iface_hash = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--core-root")) {
        const v = value orelse return needsValue(name, "<dir>");
        if (v.len == 0) return needsValue(name, "<dir>");
        common.core_root = v;
        return null;
    }
    return Usage.init("beni: unknown option '{s}'; run 'beni help' for usage", .{name});
}

fn needsValue(name: []const u8, what: []const u8) Usage {
    return Usage.init("beni: option '{s}' needs a value: {s}={s}", .{ name, name, what });
}

fn noValue(name: []const u8) Usage {
    return Usage.init("beni: option '{s}' does not take a value", .{name});
}

/// `--platform=<name>`, which `build`, `check` and `dump` all take
/// (frontend.md §1). One spelling, one message, one value: the three
/// commands must not drift apart about what the flag is, because a `check`
/// that resolves a platform differently from the `build` behind it is worse
/// than no `check`.
fn applyPlatform(slot: *?[]const u8, consumed: *bool, value: ?[]const u8) ?Usage {
    const v = value orelse return needsValue("--platform", "<name>");
    if (v.len == 0) return needsValue("--platform", "<name>");
    slot.* = v;
    consumed.* = true;
    return null;
}

/// The cache flags of `Cache`, which `check` and `build` share and no other
/// subcommand accepts. One spelling and one message for both, for
/// `applyPlatform`'s reason: a `check` that keyed its cache differently from
/// the `build` behind it would serve one of them a stale answer.
fn applyCache(cache: *Cache, consumed: *bool, name: []const u8, value: ?[]const u8) ?Usage {
    if (std.mem.eql(u8, name, "--cache-dir")) {
        const v = value orelse return needsValue(name, "<path>");
        if (v.len == 0) return needsValue(name, "<path>");
        cache.dir = v;
        consumed.* = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--no-cache")) {
        if (value != null) return noValue(name);
        cache.off = true;
        consumed.* = true;
        return null;
    }
    if (std.mem.eql(u8, name, "--cache-build-id")) {
        const v = value orelse return needsValue(name, "<s>");
        if (v.len == 0) return needsValue(name, "<s>");
        cache.build_id = v;
        consumed.* = true;
    }
    return null;
}

const CheckSpecific = struct {
    consumed: bool = false,
    platform: ?[]const u8 = null,
    cache: Cache = .{},

    fn apply(self: *CheckSpecific, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
        if (std.mem.eql(u8, name, "--platform")) {
            if (applyPlatform(&self.platform, &self.consumed, value)) |u| return u;
            return null;
        }
        // `check`'s alone: a `build` that printed keys on stdout would put
        // them where `frontend.md` §1 gives the product, and a build's
        // product is the files it wrote.
        if (std.mem.eql(u8, name, "--cache-keys")) {
            if (value != null) return noValue(name);
            self.cache.keys = true;
            self.consumed = true;
            return null;
        }
        if (std.mem.eql(u8, name, "--frontend-keys")) {
            if (value != null) return noValue(name);
            self.cache.frontend_keys = true;
            self.consumed = true;
            return null;
        }
        if (applyCache(&self.cache, &self.consumed, name, value)) |u| return u;
        return null;
    }
};

fn parseCheck(gpa: Allocator, args: []const [:0]const u8) Allocator.Error!Result {
    var s: Scanner(CheckSpecific) = .{};
    errdefer s.positionals.deinit(gpa);
    if (try s.scan(gpa, args)) |u| {
        s.positionals.deinit(gpa);
        return .{ .usage = u };
    }
    if (s.positionals.items.len == 0) {
        s.positionals.deinit(gpa);
        return .{ .usage = .init("beni: check needs at least one path", .{}) };
    }
    // No "check needs --platform": a library, a single module and anything
    // that imports only core must stay checkable with no flag (frontend.md
    // §1). The cost of leaving it off is an `unknown_module` that names the
    // flag.
    return .{ .command = .{ .check = .{
        .common = s.common,
        .cache = s.specific.cache,
        .platform = s.specific.platform,
        .paths = try s.positionals.toOwnedSlice(gpa),
    } } };
}

const BuildSpecific = struct {
    consumed: bool = false,
    platform: ?[]const u8 = null,
    out: ?[]const u8 = null,
    source_maps: bool = false,
    release: bool = false,
    library: bool = false,
    allow_debug: bool = false,
    cache: Cache = .{},

    fn apply(self: *BuildSpecific, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
        if (applyCache(&self.cache, &self.consumed, name, value)) |u| return u;
        if (self.consumed) return null;
        if (std.mem.eql(u8, name, "--platform")) {
            if (applyPlatform(&self.platform, &self.consumed, value)) |u| return u;
        } else if (std.mem.eql(u8, name, "--out")) {
            const v = value orelse return needsValue(name, "<dir>");
            if (v.len == 0) return needsValue(name, "<dir>");
            self.out = v;
            self.consumed = true;
        } else if (std.mem.eql(u8, name, "--source-maps")) {
            if (value != null) return noValue(name);
            self.source_maps = true;
            self.consumed = true;
        } else if (std.mem.eql(u8, name, "--release")) {
            if (value != null) return noValue(name);
            self.release = true;
            self.consumed = true;
        } else if (std.mem.eql(u8, name, "--library")) {
            if (value != null) return noValue(name);
            self.library = true;
            self.consumed = true;
        } else if (std.mem.eql(u8, name, "--allow-debug")) {
            // The third hidden flag (see `Build.allow_debug`). Accepted like
            // `--library`, absent from `usage`.
            if (value != null) return noValue(name);
            self.allow_debug = true;
            self.consumed = true;
        }
        return null;
    }
};

fn parseBuild(gpa: Allocator, args: []const [:0]const u8) Allocator.Error!Result {
    var s: Scanner(BuildSpecific) = .{};
    errdefer s.positionals.deinit(gpa);
    if (try s.scan(gpa, args)) |u| {
        s.positionals.deinit(gpa);
        return .{ .usage = u };
    }
    defer s.positionals.deinit(gpa);
    // `--release` is no longer refused: M3c's first slice implements it
    // (backend.md §2, §9). `--source-maps` keeps its own refusal, and keeps
    // it in a `--release` build too, so the pair exits 2 on this line.
    //
    // Same rule, same milestone argument: source maps are M5 (backend.md
    // §11). A flag that is accepted and does nothing makes a user believe
    // they asked for something — they would go looking for a `.map` that a
    // successful, silent build never wrote.
    if (s.specific.source_maps) {
        return .{ .usage = .init("beni: --source-maps is not implemented until M5; this build would write no .map file", .{}) };
    }
    const platform = s.specific.platform orelse
        return .{ .usage = .init("beni: build needs --platform=<name>", .{}) };
    if (s.positionals.items.len == 0) {
        return .{ .usage = .init("beni: build needs at least one path", .{}) };
    }
    const paths = try s.positionals.toOwnedSlice(gpa);
    return .{ .command = .{ .build = .{
        .common = s.common,
        .cache = s.specific.cache,
        .platform = platform,
        .out = s.specific.out orelse default_out,
        .library = s.specific.library,
        .release = s.specific.release,
        .allow_debug = s.specific.allow_debug,
        .paths = paths,
    } } };
}

const FmtSpecific = struct {
    consumed: bool = false,
    check: bool = false,
    stdout: bool = false,

    fn apply(self: *FmtSpecific, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
        if (std.mem.eql(u8, name, "--check")) {
            if (value != null) return noValue(name);
            self.check = true;
            self.consumed = true;
        } else if (std.mem.eql(u8, name, "--stdout")) {
            if (value != null) return noValue(name);
            self.stdout = true;
            self.consumed = true;
        }
        return null;
    }
};

fn parseFmt(gpa: Allocator, args: []const [:0]const u8) Allocator.Error!Result {
    var s: Scanner(FmtSpecific) = .{};
    errdefer s.positionals.deinit(gpa);
    if (try s.scan(gpa, args)) |u| {
        s.positionals.deinit(gpa);
        return .{ .usage = u };
    }
    if (s.positionals.items.len == 0) {
        s.positionals.deinit(gpa);
        return .{ .usage = .init("beni: fmt needs at least one path", .{}) };
    }
    if (s.specific.check and s.specific.stdout) {
        s.positionals.deinit(gpa);
        return .{ .usage = .init("beni: fmt --check and --stdout are mutually exclusive", .{}) };
    }
    return .{ .command = .{ .fmt = .{
        .common = s.common,
        .check = s.specific.check,
        .stdout = s.specific.stdout,
        .paths = try s.positionals.toOwnedSlice(gpa),
    } } };
}

const DumpSpecific = struct {
    consumed: bool = false,
    stage: ?Stage = null,
    positions: bool = false,
    platform: ?[]const u8 = null,

    fn apply(self: *DumpSpecific, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
        if (std.mem.eql(u8, name, "--platform")) {
            if (applyPlatform(&self.platform, &self.consumed, value)) |u| return u;
        } else if (std.mem.eql(u8, name, "--stage")) {
            const v = value orelse return needsValue(name, "tokens|ast|bir|interface|raw|types|graph|dispatch");
            self.stage = std.meta.stringToEnum(Stage, v) orelse
                return Usage.init("beni: invalid value '{s}' for --stage (expected tokens, ast, bir, interface, raw, types, graph or dispatch)", .{v});
            self.consumed = true;
        } else if (std.mem.eql(u8, name, "--positions")) {
            if (value != null) return noValue(name);
            self.positions = true;
            self.consumed = true;
        }
        return null;
    }
};

fn parseDump(gpa: Allocator, args: []const [:0]const u8) Allocator.Error!Result {
    var s: Scanner(DumpSpecific) = .{};
    defer s.positionals.deinit(gpa);
    if (try s.scan(gpa, args)) |u| return .{ .usage = u };
    const stage = s.specific.stage orelse return .{ .usage = .init("beni: dump needs --stage=tokens|ast|bir|interface|raw|types|graph|dispatch", .{}) };
    // A platform is a package of MODULES, so it changes what an import
    // resolves to and nothing else. The stages below it are a function of
    // one file's own bytes, and accepting the flag there would be a flag
    // that does nothing — the mistake `--source-maps` is refused to avoid
    // (backend.md §2).
    if (s.specific.platform != null and !stageResolvesImports(stage)) {
        return .{ .usage = .init(
            "beni: --platform has no effect on --stage={t}; it applies to interface, raw, types, graph and dispatch",
            .{stage},
        ) };
    }
    // `--stage=interface` and `--stage=dispatch` also take a directory (a
    // whole project's interfaces or dispatch tables, checker.md §3 and
    // static-dispatch-spike.md §7.3); either way it is one path.
    if (s.positionals.items.len != 1) return .{ .usage = .init("beni: dump needs exactly one file", .{}) };
    return .{ .command = .{ .dump = .{
        .common = s.common,
        .stage = stage,
        .positions = s.specific.positions,
        .platform = s.specific.platform,
        .file = s.positionals.items[0],
    } } };
}

/// Whether a dump stage runs the phases that resolve imports (checker.md
/// §4). The same set `main.zig` loads the core package for, and for the same
/// reason: below it, nothing knows another module exists.
pub fn stageResolvesImports(stage: Stage) bool {
    return switch (stage) {
        .tokens, .ast, .bir => false,
        .interface, .raw, .types, .graph, .dispatch => true,
    };
}

/// Free what `parse` allocated for `command`.
pub fn deinitCommand(gpa: Allocator, command: Command) void {
    switch (command) {
        .build => |c| gpa.free(c.paths),
        .check => |c| gpa.free(c.paths),
        .fmt => |f| gpa.free(f.paths),
        .dump, .version, .help => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectCommand(expected: Command, args: []const [:0]const u8) !void {
    const result = try parse(testing.allocator, args);
    switch (result) {
        .command => |c| {
            defer deinitCommand(testing.allocator, c);
            try testing.expectEqualDeep(expected, c);
        },
        .usage => |u| {
            std.debug.print("unexpected usage error: {s}\n", .{u.message()});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectUsage(expected: []const u8, args: []const [:0]const u8) !void {
    const result = try parse(testing.allocator, args);
    switch (result) {
        .command => |c| {
            deinitCommand(testing.allocator, c);
            return error.TestUnexpectedResult;
        },
        .usage => |u| try testing.expectEqualStrings(expected, u.message()),
    }
}

test "version and help" {
    try expectCommand(.version, &.{"version"});
    try expectCommand(.help, &.{"help"});
    try expectCommand(.help, &.{"--help"});
    try expectUsage("beni: version takes no arguments", &.{ "version", "x" });
    try expectUsage("beni: help takes no arguments", &.{ "help", "check" });
}

test "missing and unknown subcommand" {
    try expectUsage("beni: missing subcommand; run 'beni help' for usage", &.{});
    try expectUsage("beni: unknown subcommand 'frobnicate'; run 'beni help' for usage", &.{"frobnicate"});
    try expectUsage("beni: unknown subcommand '--jobs=2'; run 'beni help' for usage", &.{ "--jobs=2", "check" });
}

test "check: paths and every common option" {
    try expectCommand(.{ .check = .{ .paths = &.{"src"} } }, &.{ "check", "src" });
    try expectCommand(.{ .check = .{
        .common = .{ .diagnostics = .json, .self_profile = "trace.json", .jobs = 4, .root = "src", .core = true, .core_root = "core" },
        .paths = &.{ "src", "tests/Main.beni" },
    } }, &.{ "check", "--diagnostics=json", "src", "--self-profile=trace.json", "--jobs=4", "--root=src", "--core", "--core-root=core", "tests/Main.beni" });
    // `--` ends options; a lone `-` is a path.
    try expectCommand(.{ .check = .{ .paths = &.{ "--jobs=9", "-" } } }, &.{ "check", "--", "--jobs=9", "-" });
}

test "check: usage errors" {
    try expectUsage("beni: check needs at least one path", &.{"check"});
    try expectUsage("beni: check needs at least one path", &.{ "check", "--jobs=2" });
    try expectUsage("beni: unknown option '--frob'; run 'beni help' for usage", &.{ "check", "--frob", "src" });
    try expectUsage("beni: unknown option '--frob'; run 'beni help' for usage", &.{ "check", "--frob=1", "src" });
    try expectUsage("beni: invalid value 'xml' for --diagnostics (expected text or json)", &.{ "check", "--diagnostics=xml", "src" });
    try expectUsage("beni: option '--diagnostics' needs a value: --diagnostics=text|json", &.{ "check", "--diagnostics", "src" });
    try expectUsage("beni: invalid value '0' for --jobs (expected a positive integer)", &.{ "check", "--jobs=0", "src" });
    try expectUsage("beni: invalid value 'many' for --jobs (expected a positive integer)", &.{ "check", "--jobs=many", "src" });
    try expectUsage("beni: option '--jobs' needs a value: --jobs=<n>", &.{ "check", "--jobs", "src" });
    try expectUsage("beni: option '--root' needs a value: --root=<dir>", &.{ "check", "--root=", "src" });
    try expectUsage("beni: option '--self-profile' needs a value: --self-profile=<path>", &.{ "check", "--self-profile", "src" });
    try expectUsage("beni: option '--core' does not take a value", &.{ "check", "--core=1", "src" });
    try expectUsage("beni: option '--core-root' needs a value: --core-root=<dir>", &.{ "check", "--core-root=", "src" });
    // `--check` belongs to fmt only.
    try expectUsage("beni: unknown option '--check'; run 'beni help' for usage", &.{ "check", "--check", "src" });
}

test "fmt: flags in any order" {
    try expectCommand(.{ .fmt = .{ .paths = &.{"src"} } }, &.{ "fmt", "src" });
    try expectCommand(.{ .fmt = .{ .check = true, .paths = &.{ "a.beni", "b.beni" } } }, &.{ "fmt", "a.beni", "--check", "b.beni" });
    try expectCommand(.{ .fmt = .{
        .common = .{ .diagnostics = .json, .jobs = 1, .core = true },
        .stdout = true,
        .paths = &.{"a.beni"},
    } }, &.{ "fmt", "--stdout", "--jobs=1", "--core", "--diagnostics=json", "a.beni" });
    try expectUsage("beni: fmt needs at least one path", &.{ "fmt", "--check" });
    try expectUsage("beni: fmt --check and --stdout are mutually exclusive", &.{ "fmt", "--check", "--stdout", "a.beni" });
    try expectUsage("beni: option '--check' does not take a value", &.{ "fmt", "--check=yes", "a.beni" });
    try expectUsage("beni: unknown option '--stage'; run 'beni help' for usage", &.{ "fmt", "--stage=ast", "a.beni" });
}

test "dump: stage, positions, exactly one file" {
    try expectCommand(.{ .dump = .{ .stage = .ast, .file = "Main.beni" } }, &.{ "dump", "--stage=ast", "Main.beni" });
    try expectCommand(.{ .dump = .{
        .common = .{ .root = "src", .core = true },
        .stage = .tokens,
        .positions = true,
        .file = "src/Main.beni",
    } }, &.{ "dump", "src/Main.beni", "--positions", "--core", "--root=src", "--stage=tokens" });
    try expectCommand(.{ .dump = .{ .stage = .bir, .file = "M.beni" } }, &.{ "dump", "--stage=bir", "M.beni" });
    try expectCommand(.{ .dump = .{ .stage = .interface, .file = "M.beni" } }, &.{ "dump", "--stage=interface", "M.beni" });
    try expectCommand(.{ .dump = .{ .stage = .types, .file = "M.beni" } }, &.{ "dump", "--stage=types", "M.beni" });
    try expectCommand(.{ .dump = .{ .stage = .graph, .file = "src" } }, &.{ "dump", "--stage=graph", "src" });
    try expectUsage("beni: dump needs --stage=tokens|ast|bir|interface|raw|types|graph|dispatch", &.{ "dump", "Main.beni" });
    try expectUsage("beni: option '--stage' needs a value: --stage=tokens|ast|bir|interface|raw|types|graph|dispatch", &.{ "dump", "--stage", "Main.beni" });
    try expectUsage("beni: invalid value 'cst' for --stage (expected tokens, ast, bir, interface, raw, types, graph or dispatch)", &.{ "dump", "--stage=cst", "Main.beni" });
    try expectUsage("beni: dump needs exactly one file", &.{ "dump", "--stage=ast" });
    try expectUsage("beni: dump needs exactly one file", &.{ "dump", "--stage=ast", "A.beni", "B.beni" });
    try expectUsage("beni: option '--positions' does not take a value", &.{ "dump", "--stage=ast", "--positions=1", "A.beni" });
}

test "build: the platform is required, --release is accepted and --source-maps is refused" {
    try expectCommand(.{ .build = .{ .platform = "node", .paths = &.{"src"} } }, &.{ "build", "--platform=node", "src" });
    try expectCommand(.{ .build = .{
        .common = .{ .root = "src", .jobs = 2 },
        .platform = "./platforms/node",
        .out = "dist",
        .paths = &.{ "src", "vendor" },
    } }, &.{ "build", "--platform=./platforms/node", "src", "--out=dist", "--root=src", "--jobs=2", "vendor" });
    try expectUsage("beni: build needs --platform=<name>", &.{ "build", "src" });
    try expectUsage("beni: build needs at least one path", &.{ "build", "--platform=node" });
    try expectUsage("beni: option '--platform' needs a value: --platform=<name>", &.{ "build", "--platform", "src" });
    try expectUsage("beni: option '--out' needs a value: --out=<dir>", &.{ "build", "--platform=node", "--out=", "src" });
    // `--release` is accepted and reaches the command, and it takes no
    // value (backend.md §2).
    try expectCommand(
        .{ .build = .{ .platform = "node", .release = true, .paths = &.{"src"} } },
        &.{ "build", "--platform=node", "--release", "src" },
    );
    try expectCommand(
        .{ .build = .{ .platform = "node", .release = true, .library = true, .out = "dist", .paths = &.{"src"} } },
        &.{ "build", "--platform=node", "--release", "--library", "--out=dist", "src" },
    );
    try expectUsage("beni: option '--release' does not take a value", &.{ "build", "--platform=node", "--release=yes", "src" });
    try expectUsage(
        "beni: --source-maps is not implemented until M5; this build would write no .map file",
        &.{ "build", "--platform=node", "--source-maps", "src" },
    );
    // Refused before the platform is missed: the flag is wrong whatever
    // else the line says. `--release --source-maps` exits 2 on the
    // source-map line, because that half is still unimplemented (§2).
    try expectUsage(
        "beni: --source-maps is not implemented until M5; this build would write no .map file",
        &.{ "build", "--source-maps", "src" },
    );
    try expectUsage(
        "beni: --source-maps is not implemented until M5; this build would write no .map file",
        &.{ "build", "--platform=node", "--release", "--source-maps", "src" },
    );
    try expectUsage("beni: option '--source-maps' does not take a value", &.{ "build", "--platform=node", "--source-maps=yes", "src" });
}

test "check and dump take --platform; fmt does not, and neither does a per-file stage" {
    // It was `build`'s alone until 2026-09-18, and that was an accident of
    // the flag arriving with the backend rather than a decision: `check` is
    // what an editor, a hook, CI, M4's daemon and M5's LSP run, and no real
    // program resolves without its platform (frontend.md §1, boundary.md
    // §5.3).
    try expectCommand(
        .{ .check = .{ .platform = "node", .paths = &.{"src"} } },
        &.{ "check", "--platform=node", "src" },
    );
    try expectCommand(
        .{ .check = .{ .common = .{ .jobs = 2 }, .platform = "./platforms/node", .paths = &.{ "src", "vendor" } } },
        &.{ "check", "--platform=./platforms/node", "--jobs=2", "src", "vendor" },
    );
    try expectUsage("beni: option '--platform' needs a value: --platform=<name>", &.{ "check", "--platform", "src" });
    try expectUsage("beni: option '--platform' needs a value: --platform=<name>", &.{ "check", "--platform=", "src" });
    // `dump` takes it for the stages that RESOLVE imports, and refuses it
    // for the ones that are a function of the file's own bytes rather than
    // accepting a flag that does nothing (backend.md §2's `--source-maps`
    // rule).
    for ([_][:0]const u8{ "--stage=interface", "--stage=raw", "--stage=types", "--stage=graph", "--stage=dispatch" }) |stage| {
        const result = try parse(testing.allocator, &.{ "dump", stage, "--platform=node", "M.beni" });
        switch (result) {
            .command => |c| {
                defer deinitCommand(testing.allocator, c);
                try testing.expectEqualStrings("node", c.dump.platform.?);
            },
            .usage => |u| {
                std.debug.print("unexpected usage error: {s}\n", .{u.message()});
                return error.TestUnexpectedResult;
            },
        }
    }
    try expectUsage(
        "beni: --platform has no effect on --stage=ast; it applies to interface, raw, types, graph and dispatch",
        &.{ "dump", "--stage=ast", "--platform=node", "M.beni" },
    );
    try expectUsage(
        "beni: --platform has no effect on --stage=tokens; it applies to interface, raw, types, graph and dispatch",
        &.{ "dump", "--platform=node", "--stage=tokens", "M.beni" },
    );
    try expectUsage(
        "beni: --platform has no effect on --stage=bir; it applies to interface, raw, types, graph and dispatch",
        &.{ "dump", "--stage=bir", "--platform=node", "M.beni" },
    );
    // `fmt` resolves nothing: formatting is per file.
    try expectUsage("beni: unknown option '--platform'; run 'beni help' for usage", &.{ "fmt", "--platform=node", "a.beni" });
}

// The two flags of `fast-compiler.md` §8, and the property that makes them
// "hidden": they parse everywhere `--jobs` does, and `beni help` does not
// list them. A flag the usage text advertises is product surface and would
// have to be supported forever; these two are diagnostic surface.
test "the hidden flags parse, take no value, and are absent from the usage text" {
    try expectCommand(
        .{ .check = .{ .common = .{ .roundtrip_interfaces = true }, .paths = &.{"src"} } },
        &.{ "check", "--roundtrip-interfaces", "src" },
    );
    try expectCommand(
        .{ .check = .{ .common = .{ .iface_hash = true }, .paths = &.{"src"} } },
        &.{ "check", "--iface-hash", "src" },
    );
    try expectCommand(
        .{ .check = .{
            .common = .{ .jobs = 8, .roundtrip_interfaces = true, .iface_hash = true },
            .paths = &.{"src"},
        } },
        &.{ "check", "--iface-hash", "--jobs=8", "--roundtrip-interfaces", "src" },
    );
    // Every command takes them, because every command that resolves runs the
    // checker: `build` and `dump` both have to be able to prove the same
    // thing `check` does.
    try expectCommand(
        .{ .build = .{ .common = .{ .roundtrip_interfaces = true }, .platform = "node", .paths = &.{"src"} } },
        &.{ "build", "--platform=node", "--roundtrip-interfaces", "src" },
    );
    try expectCommand(
        .{ .dump = .{ .common = .{ .roundtrip_interfaces = true }, .stage = .raw, .file = "M.beni" } },
        &.{ "dump", "--stage=raw", "--roundtrip-interfaces", "M.beni" },
    );
    try expectUsage(
        "beni: option '--roundtrip-interfaces' does not take a value",
        &.{ "check", "--roundtrip-interfaces=1", "src" },
    );
    try expectUsage("beni: option '--iface-hash' does not take a value", &.{ "check", "--iface-hash=yes", "src" });
    // Hidden: `beni help` prints `usage`, and `usage` says nothing of them.
    try testing.expect(std.mem.indexOf(u8, usage, "--roundtrip-interfaces") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "--iface-hash") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "iface") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "roundtrip") == null);

    // The third, appended 2026-09-19 with `backend.md` §9's refusal of
    // `Debug` under `--release` (queue slice 50). It is `build`'s alone —
    // nothing else emits — and it is hidden for the same reason: the corpus
    // harness needs it to keep running the `--release` second pass over the
    // 24 `run/` fixtures that use `Debug.log`, and a user does not.
    try expectCommand(
        .{ .build = .{ .platform = "node", .release = true, .allow_debug = true, .paths = &.{"src"} } },
        &.{ "build", "--platform=node", "--release", "--allow-debug", "src" },
    );
    try expectCommand(
        .{ .build = .{ .platform = "node", .allow_debug = true, .paths = &.{"src"} } },
        &.{ "build", "--platform=node", "--allow-debug", "src" },
    );
    try expectUsage("beni: option '--allow-debug' does not take a value", &.{ "build", "--platform=node", "--allow-debug=1", "src" });
    // It is not `check`'s, `fmt`'s or `dump`'s: those emit nothing, so there
    // is no refusal for it to lift.
    try expectUsage("beni: unknown option '--allow-debug'; run 'beni help' for usage", &.{ "check", "--allow-debug", "src" });
    try testing.expect(std.mem.indexOf(u8, usage, "--allow-debug") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "allow-debug") == null);

    // `--roundtrip-dispatch` is a fourth, and on `Common` for its twin's
    // reason: the acceptance matrix passes it to `dump` as well as to
    // `check` and `build`.
    try expectCommand(
        .{ .check = .{ .common = .{ .roundtrip_dispatch = true }, .paths = &.{"src"} } },
        &.{ "check", "--roundtrip-dispatch", "src" },
    );
    try expectCommand(
        .{ .dump = .{ .common = .{ .roundtrip_dispatch = true }, .stage = .dispatch, .file = "M.beni" } },
        &.{ "dump", "--stage=dispatch", "--roundtrip-dispatch", "M.beni" },
    );
    try expectCommand(
        .{ .build = .{
            .common = .{ .roundtrip_interfaces = true, .roundtrip_dispatch = true },
            .platform = "node",
            .paths = &.{"src"},
        } },
        &.{ "build", "--platform=node", "--roundtrip-interfaces", "--roundtrip-dispatch", "src" },
    );
    try expectUsage(
        "beni: option '--roundtrip-dispatch' does not take a value",
        &.{ "check", "--roundtrip-dispatch=1", "src" },
    );
    try testing.expect(std.mem.indexOf(u8, usage, "--roundtrip-dispatch") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "dispatch-") == null);

    // `--roundtrip-frontend` is the fifth, and the first that is not the
    // checker's (`plans/m4-2.md` M2-c). It is on `Common` because `dump` and
    // `fmt` are the identity oracles it is asserted against.
    try expectCommand(
        .{ .check = .{ .common = .{ .roundtrip_frontend = true }, .paths = &.{"src"} } },
        &.{ "check", "--roundtrip-frontend", "src" },
    );
    try expectCommand(
        .{ .dump = .{ .common = .{ .roundtrip_frontend = true }, .stage = .bir, .file = "M.beni" } },
        &.{ "dump", "--stage=bir", "--roundtrip-frontend", "M.beni" },
    );
    try expectCommand(
        .{ .fmt = .{ .common = .{ .roundtrip_frontend = true }, .stdout = true, .paths = &.{"M.beni"} } },
        &.{ "fmt", "--stdout", "--roundtrip-frontend", "M.beni" },
    );
    try expectUsage(
        "beni: option '--roundtrip-frontend' does not take a value",
        &.{ "check", "--roundtrip-frontend=1", "src" },
    );
    try testing.expect(std.mem.indexOf(u8, usage, "--roundtrip-frontend") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "frontend") == null);
}

test "--cache-build-id is check's and build's, hidden, and nobody else's" {
    // `fast-compiler.md` §8: its bytes replace the compiler build id in the
    // key, so a fixture can prove that a compiler change discards the whole
    // cache without building a second compiler.
    try expectCommand(
        .{ .check = .{ .cache = .{ .build_id = "pretend" }, .paths = &.{"src"} } },
        &.{ "check", "--cache-build-id=pretend", "src" },
    );
    try expectCommand(
        .{ .build = .{
            .cache = .{ .build_id = "pretend" },
            .platform = "node",
            .paths = &.{"src"},
        } },
        &.{ "build", "--platform=node", "--cache-build-id=pretend", "src" },
    );
    try expectUsage(
        "beni: option '--cache-build-id' needs a value: --cache-build-id=<s>",
        &.{ "check", "--cache-build-id", "src" },
    );
    try expectUsage(
        "beni: option '--cache-build-id' needs a value: --cache-build-id=<s>",
        &.{ "check", "--cache-build-id=", "src" },
    );
    // Not `fmt`'s and not `dump`'s: neither produces a cacheable result, and
    // a flag that is accepted and does nothing is the mistake `--source-maps`
    // is refused to avoid (`frontend.md` §1).
    try expectUsage(
        "beni: unknown option '--cache-build-id'; run 'beni help' for usage",
        &.{ "fmt", "--cache-build-id=x", "src" },
    );
    try expectUsage(
        "beni: unknown option '--cache-build-id'; run 'beni help' for usage",
        &.{ "dump", "--stage=raw", "--cache-build-id=x", "M.beni" },
    );
    // Hidden, like the two flags above it.
    try testing.expect(std.mem.indexOf(u8, usage, "--cache-build-id") == null);
}

test "usage text mentions every subcommand" {
    for ([_][]const u8{ "build", "check", "fmt", "dump", "version", "help", "--diagnostics", "--self-profile", "--jobs", "--root", "--core", "--core-root", "--explain", "--pattern-budget", "--stage", "--positions", "interface", "--platform", "--out", "--source-maps", "--release", "--library", "--cache-dir", "--no-cache" }) |word| {
        try testing.expect(std.mem.indexOf(u8, usage, word) != null);
    }
}
