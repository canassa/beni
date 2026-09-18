//! `beni check [--platform=<name>] <path>...` (docs/design/frontend.md §1,
//! checker.md §2): parse, lower, resolve and type-check every module, report
//! diagnostics, write nothing.
//!
//! **`--platform` is not `build`'s alone** (boundary.md §5.3). Until this
//! command took it, `check` could not be pointed at any program that imports
//! its platform for `Program` — which is every program — so the one command
//! an editor, a pre-commit hook, CI, M4's daemon and M5's LSP all run did not
//! exist for real code. The flag resolves exactly as `build`'s does, through
//! `platform.zig`, so the two commands cannot disagree about what a platform
//! is.
//!
//! It is **not required** the way `build` requires it: a library, a single
//! module, or anything importing only core must stay checkable with no flag.
//! What a platform adds is the package in the import search path and
//! boundary.md §4's four sibling checks; what it does NOT add is the
//! entry-point search, because a build is a pair of ONE entry point and ONE
//! platform while `check` is handed whatever paths it is handed.
//!
//! Exit codes are `frontend.md` §1's: 0 no errors, 1 at least one error
//! diagnostic, 2 a usage or I/O failure. stdout carries the product, and a
//! check has none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cli = @import("../Cli.zig");
const Session = @import("../Session.zig");
const Emit = @import("../js/Emit.zig");
const platform = @import("../platform.zig");

pub fn run(gpa: Allocator, io: Io, stderr: *Io.Writer, options_in: Session.Options, check: Cli.Check) u8 {
    var options = options_in;
    // A package may declare itself a platform (boundary.md §2), and then
    // `foreign` is legal in it. `check` has to honour that or a platform
    // package could not be checked at all.
    options.manifest_root = check.common.root orelse ".";
    // `check` resolves names across modules, and every module resolves
    // against core (checker.md §4): the package is part of the input.
    options.core_package = true;
    // `check` and `build` are the two subcommands that emit the
    // informational warnings of static-dispatch-spike.md §10 (A.83); a
    // `dump` or a `fmt` of the same file stays silent about them.
    options.informational = true;
    options.platform = check.platform;
    // With a platform there is a SECOND wave of diagnostics — §4's checks
    // run after `run` returns — and two renders on one stream are two JSON
    // arrays, which is not the format (§1.1). Without one there is no second
    // wave and `run` renders as it always has.
    options.defer_render = check.platform != null;

    var session = Session.init(gpa, io, options) catch return fail(stderr, "beni: out of memory", .{});
    defer session.deinit();

    const summary = session.run(check.paths, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            return fail(stderr, "beni: cannot read '{s}': {t}", .{ failure.path, failure.err });
        },
        else => |e| return fail(stderr, "beni: {t}", .{e}),
    };
    if (session.platform_error) return platform.reportUnknown(stderr, check.platform.?);
    if (summary.errors > 0) {
        _ = session.renderLate(&.{}, stderr) catch return 2;
        return 1;
    }
    const requested = check.platform orelse return 0;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The platform's own manifest is read even though nothing here uses its
    // `program` or `runtime`: `--platform=<dir>` naming something that is not
    // a platform package is the same exit-2 failure for `check` as for
    // `build`, and finding that out only at build time is the asymmetry this
    // flag exists to remove.
    const loaded = platform.load(arena, io, &session) catch |err|
        return platform.report(stderr, requested, &session, err);

    const items = Emit.checkContract(gpa, arena, &session, .{
        .out_dir = &.{}, // nothing is written; the field is `run`'s
        .platform = loaded.platform,
        .embedded = loaded.embedded,
    }) catch return fail(stderr, "beni: out of memory", .{});
    defer {
        for (items) |item| gpa.free(item.message);
        gpa.free(items);
    }

    // The one render of the stream: §4's diagnostics and the `warning`s
    // `run` held back, sorted together into one array. Called even when the
    // checks said nothing, because the held-back wave still has to reach the
    // author.
    const late = gpa.alloc(Session.LateItem, items.len) catch
        return fail(stderr, "beni: out of memory", .{});
    defer gpa.free(late);
    for (items, late) |item, *slot| {
        slot.* = .{ .code = item.code, .file = item.file, .token = item.token, .message = item.message };
    }
    const errors = session.renderLate(late, stderr) catch return 2;
    return if (errors > 0) 1 else 0;
}

fn fail(stderr: *Io.Writer, comptime format_string: []const u8, args: anytype) u8 {
    stderr.print(format_string ++ "\n", args) catch {};
    return 2;
}
