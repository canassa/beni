//! Command-line parsing (docs/design/frontend.md §1).
//!
//! Pure: bytes in, a `Command` or a usage message out, no I/O — so the whole
//! surface is covered by the hermetic suite, and `main.zig` is only the
//! dispatch. Every usage error is a one-line message; `main` prints it to
//! stderr and exits 2. The wording is part of the black-box contract.
//!
//! ```
//! beni build  [options] --platform=<name> <path>...
//! beni check  [options] <path>...
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
};

pub const Check = struct {
    common: Common = .{},
    paths: []const []const u8,
};

pub const Build = struct {
    common: Common = .{},
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

const NoSpecific = struct {
    consumed: bool = false,
    fn apply(_: *NoSpecific, _: []const u8, _: ?[]const u8) Allocator.Error!?Usage {
        return null;
    }
};

fn parseCheck(gpa: Allocator, args: []const [:0]const u8) Allocator.Error!Result {
    var s: Scanner(NoSpecific) = .{};
    errdefer s.positionals.deinit(gpa);
    if (try s.scan(gpa, args)) |u| {
        s.positionals.deinit(gpa);
        return .{ .usage = u };
    }
    if (s.positionals.items.len == 0) {
        s.positionals.deinit(gpa);
        return .{ .usage = .init("beni: check needs at least one path", .{}) };
    }
    return .{ .command = .{ .check = .{ .common = s.common, .paths = try s.positionals.toOwnedSlice(gpa) } } };
}

const BuildSpecific = struct {
    consumed: bool = false,
    platform: ?[]const u8 = null,
    out: ?[]const u8 = null,
    source_maps: bool = false,
    release: bool = false,
    library: bool = false,

    fn apply(self: *BuildSpecific, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
        if (std.mem.eql(u8, name, "--platform")) {
            const v = value orelse return needsValue(name, "<name>");
            if (v.len == 0) return needsValue(name, "<name>");
            self.platform = v;
            self.consumed = true;
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
        .platform = platform,
        .out = s.specific.out orelse default_out,
        .library = s.specific.library,
        .release = s.specific.release,
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

    fn apply(self: *DumpSpecific, name: []const u8, value: ?[]const u8) Allocator.Error!?Usage {
        if (std.mem.eql(u8, name, "--stage")) {
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
    // `--stage=interface` and `--stage=dispatch` also take a directory (a
    // whole project's interfaces or dispatch tables, checker.md §3 and
    // static-dispatch-spike.md §7.3); either way it is one path.
    if (s.positionals.items.len != 1) return .{ .usage = .init("beni: dump needs exactly one file", .{}) };
    return .{ .command = .{ .dump = .{
        .common = s.common,
        .stage = stage,
        .positions = s.specific.positions,
        .file = s.positionals.items[0],
    } } };
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
    // `--platform` belongs to build only.
    try expectUsage("beni: unknown option '--platform'; run 'beni help' for usage", &.{ "check", "--platform=node", "src" });
}

test "usage text mentions every subcommand" {
    for ([_][]const u8{ "build", "check", "fmt", "dump", "version", "help", "--diagnostics", "--self-profile", "--jobs", "--root", "--core", "--core-root", "--explain", "--pattern-budget", "--stage", "--positions", "interface", "--platform", "--out", "--source-maps", "--release", "--library" }) |word| {
        try testing.expect(std.mem.indexOf(u8, usage, word) != null);
    }
}
