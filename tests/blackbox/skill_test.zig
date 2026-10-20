//! The skill for coding agents, `skills/beni/` (docs/design/frontend.md
//! §12): the gate that keeps the folder current, and `beni skill`.
//!
//! The folder must agree with the compiler of the same commit, because a
//! stale skill misleads every agent that reads it. So this file checks the
//! folder against the binary under test: every `beni` code block checks
//! (or is refused with the code it names), every command and flag of
//! `beni help` is in the CLI file, the generated API references are what
//! the generator writes today, `SKILL.md` has the shape the Agent Skills
//! standard asks for, and `zig build install` put the same bytes under
//! `share/beni/skills/beni/`. The command is run in a prefix the test
//! builds: a copy of the binary beside a copy of the folder, so the path
//! resolution, the missing-folder case, the copy, the link, the refusal
//! and `--force` are each one scenario.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;
const Io = std.Io;

/// Relative to the repository root, which the build step pins as cwd.
const skill_root = "skills/beni";
const installed_root = "zig-out/share/beni/skills/beni";
const cli_reference = "skills/beni/references/cli.md";

/// The packages `zig build skill-api` writes a file for (`tests/skill_api.zig`).
const packages = [_][]const u8{ "core", "node", "browser", "browser-tea", "browser-inline", "html" };

/// The flags `beni help` hides but a diagnostic tells the user to run
/// (`frontend.md` §12.4 item 2): each must be in the CLI reference and
/// must still be accepted by `beni fmt`.
const hidden_flags = [_][]const u8{
    "--migrate-cons",
    "--migrate-unicode",
    "--migrate-top",
    "--migrate-lambda",
    "--migrate-let",
    "--migrate-names",
    "--migrate-init",
};

/// One fenced block whose info string starts with `beni`.
const Block = struct {
    file: []const u8,
    line: usize,
    platform: ?[]const u8,
    refused: ?[]const u8,
    text: []const u8,
    /// The module the block was written as, relative to the world.
    module: []const u8 = "",
};

/// The `.md` files under `skill_root`, sorted, as repo-relative paths.
fn markdownFiles(arena: std.mem.Allocator, io: Io) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, skill_root, "", &out, ".md");
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every file under `root/prefix` whose name ends in `suffix` (empty: all),
/// as `prefix/name` paths relative to `root`.
fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8), suffix: []const u8) !void {
    const full = if (prefix.len == 0) root else try std.fs.path.join(arena, &.{ root, prefix });
    var dir = try Io.Dir.cwd().openDir(io, full, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try collect(arena, io, root, rel, out, suffix),
            .file => if (std.mem.endsWith(u8, entry.name, suffix)) try out.append(arena, rel),
            else => return error.UnexpectedEntryKind,
        }
    }
}

fn readRepoFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
}

/// The `beni` blocks of one Markdown file, in order. An info string that
/// starts with `elm`, or a `beni` token the gate does not know, is a
/// failure: the first would highlight `->` as correct, the second is a
/// block the gate would silently skip.
fn blocksOf(arena: std.mem.Allocator, file: []const u8, text: []const u8, out: *std.ArrayList(Block), problems: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var open: ?Block = null;
    var body: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (open) |*block| {
            if (std.mem.startsWith(u8, line, "```")) {
                block.text = try body.toOwnedSlice(arena);
                try out.append(arena, block.*);
                open = null;
            } else {
                try body.appendSlice(arena, line);
                try body.append(arena, '\n');
            }
            continue;
        }
        if (!std.mem.startsWith(u8, line, "```")) continue;
        const info = std.mem.trim(u8, line[3..], " \t");
        var tokens = std.mem.tokenizeScalar(u8, info, ' ');
        const first = tokens.next() orelse {
            // A fence with no info string: not beni, skipped to its close.
            try skipFence(&lines, &line_no);
            continue;
        };
        if (std.mem.eql(u8, first, "elm")) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: a block tagged `elm`; beni is not Elm, tag it `beni` and make it check, or `text`", .{ file, line_no }));
            try skipFence(&lines, &line_no);
            continue;
        }
        if (!std.mem.eql(u8, first, "beni")) {
            try skipFence(&lines, &line_no);
            continue;
        }
        var block: Block = .{ .file = file, .line = line_no, .platform = null, .refused = null, .text = "" };
        while (tokens.next()) |token| {
            if (std.mem.startsWith(u8, token, "platform=")) {
                block.platform = token["platform=".len..];
            } else if (std.mem.startsWith(u8, token, "refused=")) {
                block.refused = token["refused=".len..];
            } else {
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: unknown token `{s}` in a beni block's info string (platform=<name>, refused=<code>)", .{ file, line_no, token }));
            }
        }
        open = block;
        body = .empty;
    }
    if (open != null) try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: a code block is never closed", .{file}));
}

fn skipFence(lines: *std.mem.SplitIterator(u8, .scalar), line_no: *usize) !void {
    while (lines.next()) |raw| {
        line_no.* += 1;
        if (std.mem.startsWith(u8, raw, "```")) return;
    }
    return error.UnclosedFence;
}

fn printProblems(problems: []const []const u8) void {
    for (problems) |p| std.debug.print("{s}\n", .{p});
}

test "every beni code block of the skill checks and is formatted, or is refused with the code it names" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    var problems: std.ArrayList([]const u8) = .empty;
    var blocks: std.ArrayList(Block) = .empty;
    for (try markdownFiles(arena, w.io)) |rel| {
        const path = try std.fs.path.join(arena, &.{ skill_root, rel });
        try blocksOf(arena, path, try readRepoFile(arena, w.io, path), &blocks, &problems);
    }
    // A group is one info string: one `check` per group, not per block.
    const Group = struct { platform: ?[]const u8, refused: bool, dir: []const u8, members: std.ArrayList(usize) = .empty };
    var groups: std.ArrayList(Group) = .empty;
    for (blocks.items, 0..) |*block, i| {
        const is_refused = block.refused != null;
        var found: ?*Group = null;
        for (groups.items) |*g| {
            const same_platform = (g.platform == null and block.platform == null) or
                (g.platform != null and block.platform != null and std.mem.eql(u8, g.platform.?, block.platform.?));
            if (same_platform and g.refused == is_refused) found = g;
        }
        if (found == null) {
            try groups.append(arena, .{
                .platform = block.platform,
                .refused = is_refused,
                .dir = try std.fmt.allocPrint(arena, "g{d}", .{groups.items.len}),
            });
            found = &groups.items[groups.items.len - 1];
        }
        try found.?.members.append(arena, i);
        block.module = try std.fmt.allocPrint(arena, "{s}/B{d}.beni", .{ found.?.dir, i });
        try w.write(block.module, block.text);
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE, VERIFY OUTPUT                  │
    // └─────────────────────────────────────────┘
    for (groups.items) |g| {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "check", "--no-cache" });
        if (g.platform) |p| try args.append(arena, try std.fmt.allocPrint(arena, "--platform={s}", .{p}));
        try args.append(arena, g.dir);
        const r = try w.run(args.items);
        if (r.exit_code > 1) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "group {s} (platform {s}): check exited {d}: {s}", .{ g.dir, g.platform orelse "none", r.exit_code, r.stderr }));
            continue;
        }
        for (g.members.items) |i| {
            const block = blocks.items[i];
            var errors: usize = 0;
            var named: usize = 0;
            for (r.diagnostics) |d| {
                if (!std.mem.eql(u8, d.span.file, block.module)) continue;
                if (block.refused) |code| {
                    if (d.severity == .@"error") {
                        errors += 1;
                        if (std.mem.eql(u8, @tagName(d.code), code)) named += 1;
                    }
                } else {
                    const first_line = std.mem.sliceTo(d.message, '\n');
                    try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: {t} ({t}) at line {d} of the block: {s}", .{ block.file, block.line, d.code, d.severity, d.span.start.line, first_line }));
                }
            }
            if (block.refused) |code| {
                if (named == 0 or named != errors) {
                    try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: expected every error to be `{s}` and at least one; got {d} errors, {d} of them `{s}`", .{ block.file, block.line, code, errors, named, code }));
                }
            }
        }
        if (g.refused) {
            if (r.exit_code != 1) try problems.append(arena, try std.fmt.allocPrint(arena, "group {s}: a refused group must exit 1, not {d}", .{ g.dir, r.exit_code }));
            continue;
        }
        if (r.exit_code != 0) try problems.append(arena, try std.fmt.allocPrint(arena, "group {s}: an accepted group must exit 0, not {d}", .{ g.dir, r.exit_code }));
        // The formatter's layout, so an agent copies the canonical form.
        const f = try w.runWith(&.{ "fmt", "--check", g.dir }, .{ .raw_diagnostics = true });
        var paths = std.mem.tokenizeScalar(u8, f.stdout, '\n');
        while (paths.next()) |path| {
            for (g.members.items) |i| {
                const block = blocks.items[i];
                if (!std.mem.eql(u8, path, block.module)) continue;
                const shown = try w.runWith(&.{ "fmt", "--stdout", block.module }, .{ .raw_diagnostics = true });
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}: not in the formatter's layout; `beni fmt` writes:\n{s}", .{ block.file, block.line, shown.stdout }));
            }
        }
        if (f.exit_code > 1) try problems.append(arena, try std.fmt.allocPrint(arena, "group {s}: fmt --check exited {d}: {s}", .{ g.dir, f.exit_code, f.stderr }));
    }
    printProblems(problems.items);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
    // The parser saw the folder: a skill with fewer blocks than this lost some.
    try testing.expect(blocks.items.len >= 20);
}

test "every command and flag of beni help is in the CLI reference, and every flag there is in beni help" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const reference = try readRepoFile(arena, w.io, cli_reference);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const help = try w.runWith(&.{"help"}, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), help.exit_code);
    try testing.expectEqualStrings("", help.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    var problems: std.ArrayList([]const u8) = .empty;
    // The `commands:` block: one command per line until the blank line.
    var commands: usize = 0;
    var lines = std.mem.splitScalar(u8, help.stdout, '\n');
    var in_commands = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "commands:")) {
            in_commands = true;
            continue;
        }
        if (!in_commands) continue;
        if (line.len == 0) break;
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const name = tokens.next() orelse continue;
        commands += 1;
        const spelled = try std.fmt.allocPrint(arena, "`beni {s}", .{name});
        if (std.mem.indexOf(u8, reference, spelled) == null) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: the command `{s}` of beni help is not in it", .{ cli_reference, name }));
        }
    }
    try testing.expect(commands >= 9);
    // Every `--flag` of the help text is in the reference, and the reverse.
    const help_flags = try flagsIn(arena, help.stdout);
    const reference_flags = try flagsIn(arena, reference);
    try testing.expect(help_flags.len >= 25);
    for (help_flags) |flag| {
        if (!contains(reference_flags, flag)) try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: the flag `{s}` of beni help is not in it", .{ cli_reference, flag }));
    }
    for (reference_flags) |flag| {
        if (!contains(help_flags, flag) and !contains(&hidden_flags, flag)) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: the flag `{s}` is neither in beni help nor a hidden flag a diagnostic names", .{ cli_reference, flag }));
        }
    }
    // The hidden flags a diagnostic names: in the reference, and still accepted.
    try w.write("Canonical.beni", "x = 1\n");
    for (hidden_flags) |flag| {
        if (!contains(reference_flags, flag)) try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: the hidden flag `{s}`, which a diagnostic names, is not in it", .{ cli_reference, flag }));
        const r = try w.runWith(&.{ "fmt", flag, "Canonical.beni" }, .{ .raw_diagnostics = true });
        if (r.exit_code != 0) try problems.append(arena, try std.fmt.allocPrint(arena, "`beni fmt {s}` is no longer accepted (exit {d}): {s}", .{ flag, r.exit_code, r.stderr }));
    }
    printProblems(problems.items);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

/// Every `--name` token of `text`, deduplicated: `--` then a lower-case
/// letter, then letters, digits and hyphens, cut at `=`, a space or a
/// backtick.
fn flagsIn(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "--")) |at| {
        var end = at + 2;
        while (end < text.len and (std.ascii.isLower(text[end]) or std.ascii.isDigit(text[end]) or text[end] == '-')) end += 1;
        i = end;
        if (end == at + 2 or !std.ascii.isLower(text[at + 2])) continue;
        const flag = text[at..end];
        if (!contains(out.items, flag)) try out.append(arena, flag);
    }
    return out.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// Run the generator (`BENI_SKILL_API_EXE`) with the binary under test into
/// the world's `gen/`, and compare one package's file with the committed one.
fn expectPackageCurrent(package: []const u8) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const root = try Io.Dir.cwd().realPathFileAlloc(w.io, ".", arena);
    const out = try w.projectSubPath(arena, "gen");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The repository root is passed as `.`, as `zig build skill-api` passes
    // it: with an absolute root the dump reads the package as an app's
    // modules (issue #534), and the committed files were written with `.`.
    const argv = [_][]const u8{
        try testing.environ.getAlloc(arena, "BENI_SKILL_API_EXE"),
        try Io.Dir.cwd().realPathFileAlloc(w.io, world.exePath(arena), arena),
        ".",
        out,
        package,
    };
    var env = std.process.Environ.Map.init(arena);
    const r = try world.spawnAndCaptureIn(arena, w.io, &argv, .{ .path = root }, world.bulk_timeout_ms, &env);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) std.debug.print("--- stderr ---\n{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    const name = try std.fmt.allocPrint(arena, "api-{s}.md", .{package});
    const generated = try w.read(try std.fs.path.join(arena, &.{ "gen", name }));
    const committed = readRepoFile(arena, w.io, try std.fs.path.join(arena, &.{ skill_root, "references", name })) catch |err| {
        std.debug.print("skills/beni/references/{s}: cannot read ({t}); run `zig build skill-api`\n", .{ name, err });
        return error.StaleGeneratedFile;
    };
    if (!std.mem.eql(u8, generated, committed)) {
        std.debug.print("skills/beni/references/{s} is stale: run `zig build skill-api` and commit the result\n", .{name});
        return error.StaleGeneratedFile;
    }
    // The file holds beni's notation and none of the dump's (§12.1). `Never`
    // is checked as a whole word: `NeverKind` is a constructor and stays.
    for ([_][]const u8{ " !", "foreign ", "markup value", "(equatable)" }) |mark| {
        if (std.mem.indexOf(u8, generated, mark) != null) {
            std.debug.print("skills/beni/references/{s} holds `{s}`, which is the dump's notation, not beni's\n", .{ name, mark });
            return error.DumpNotationInReference;
        }
    }
    if (hasWord(generated, "Never")) {
        std.debug.print("skills/beni/references/{s} holds the word `Never`, which beni writes `⊥`\n", .{name});
        return error.DumpNotationInReference;
    }
}

/// Whether `word` occurs in `text` with no letter or digit on either side.
fn hasWord(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, word)) |at| {
        const before = at == 0 or !std.ascii.isAlphanumeric(text[at - 1]);
        const end = at + word.len;
        const after = end >= text.len or !std.ascii.isAlphanumeric(text[end]);
        if (before and after) return true;
        i = at + 1;
    }
    return false;
}

test "the generated API reference of core is what zig build skill-api writes today" {
    try expectPackageCurrent("core");
}

test "the generated API reference of node is what zig build skill-api writes today" {
    try expectPackageCurrent("node");
}

test "the generated API reference of browser is what zig build skill-api writes today" {
    try expectPackageCurrent("browser");
}

test "the generated API reference of browser-tea is what zig build skill-api writes today" {
    try expectPackageCurrent("browser-tea");
}

test "the generated API reference of browser-inline is what zig build skill-api writes today" {
    try expectPackageCurrent("browser-inline");
}

test "the generated API reference of html is what zig build skill-api writes today" {
    try expectPackageCurrent("html");
}

test "the generator's package list is every platform in the repository, and no generated file is an orphan" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    // Every directory under platforms/ is on the list.
    var dir = try Io.Dir.cwd().openDir(w.io, "platforms", .{ .iterate = true });
    defer dir.close(w.io);
    var it = dir.iterate();
    var platforms: usize = 0;
    while (try it.next(w.io)) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        platforms += 1;
        if (!contains(&packages, entry.name)) {
            std.debug.print("platforms/{s} is not a package tests/skill_api.zig generates a reference for\n", .{entry.name});
            return error.PlatformNotInList;
        }
    }
    try testing.expectEqual(packages.len - 1, platforms);
    // No generated file that the generator does not write.
    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, w.io, skill_root ++ "/references", "", &files, ".md");
    for (files.items) |file| {
        if (!std.mem.startsWith(u8, file, "api-")) continue;
        const package = file["api-".len .. file.len - ".md".len];
        if (!contains(&packages, package)) {
            std.debug.print("skills/beni/references/{s}: not a package the generator writes\n", .{file});
            return error.OrphanGeneratedFile;
        }
    }
}

test "SKILL.md has the standard's frontmatter, stays short, and names every reference file" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const text = try readRepoFile(arena, w.io, skill_root ++ "/SKILL.md");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    var problems: std.ArrayList([]const u8) = .empty;
    try testing.expect(std.mem.startsWith(u8, text, "---\n"));
    const close = std.mem.indexOfPos(u8, text, 4, "\n---\n") orelse return error.NoFrontmatter;
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, text[4..close], '\n');
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "name: ")) {
            name = field["name: ".len..];
        } else if (std.mem.startsWith(u8, field, "description: ")) {
            description = field["description: ".len..];
        } else {
            try problems.append(arena, try std.fmt.allocPrint(arena, "SKILL.md: a frontmatter line that is neither name nor description: {s}", .{field}));
        }
    }
    try testing.expectEqualStrings("beni", name orelse "");
    const d = description orelse "";
    try testing.expect(d.len >= 1 and d.len <= 1024);
    const line_count = std.mem.count(u8, text, "\n");
    try testing.expect(line_count < 500);
    // Codex injects at most 8 000 bytes of SKILL.md when a user names the skill.
    try testing.expect(text.len < 8000);
    // Every reference file is named, every named file exists, and a
    // hand-written topic stays short enough to read whole.
    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, w.io, skill_root ++ "/references", "", &files, "");
    for (files.items) |file| {
        const spelled = try std.fmt.allocPrint(arena, "`references/{s}`", .{file});
        if (std.mem.indexOf(u8, text, spelled) == null) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "SKILL.md does not name {s}; a harness loads only what SKILL.md names", .{spelled}));
        }
        if (std.mem.startsWith(u8, file, "api-")) continue;
        const body = try readRepoFile(arena, w.io, try std.fs.path.join(arena, &.{ skill_root, "references", file }));
        const topic_lines = std.mem.count(u8, body, "\n");
        if (topic_lines >= 300) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "references/{s} has {d} lines; a topic file stays under 300 (frontend.md §12.1)", .{ file, topic_lines }));
        }
    }
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "`references/")) |at| {
        const start = at + 1;
        const end = std.mem.indexOfScalarPos(u8, text, start, '`') orelse break;
        i = end;
        const path = try std.fs.path.join(arena, &.{ skill_root, text[start..end] });
        Io.Dir.cwd().access(w.io, path, .{}) catch {
            try problems.append(arena, try std.fmt.allocPrint(arena, "SKILL.md names {s}, which does not exist", .{text[start..end]}));
        };
    }
    printProblems(problems.items);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "zig build install puts the folder under share/beni/skills/beni, byte for byte" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    try expectSameTree(arena, w.io, skill_root, installed_root);
}

/// The two trees hold the same relative file paths with the same bytes.
fn expectSameTree(arena: std.mem.Allocator, io: Io, left: []const u8, right: []const u8) !void {
    var l: std.ArrayList([]const u8) = .empty;
    var r: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, left, "", &l, "");
    try collect(arena, io, right, "", &r, "");
    std.mem.sort([]const u8, l.items, {}, lessThan);
    std.mem.sort([]const u8, r.items, {}, lessThan);
    try testing.expectEqualDeep(l.items, r.items);
    try testing.expect(l.items.len >= 10);
    for (l.items) |rel| {
        const a = try readRepoFile(arena, io, try std.fs.path.join(arena, &.{ left, rel }));
        const b = try readRepoFile(arena, io, try std.fs.path.join(arena, &.{ right, rel }));
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("{s}/{s} differs from {s}/{s}\n", .{ left, rel, right, rel });
            return error.TreesDiffer;
        }
    }
}

/// A prefix in the world: a copy of the binary under test at `<prefix>/bin/beni`
/// and, when `with_skill`, a copy of the folder at
/// `<prefix>/share/beni/skills/beni/`. Returns the binary's absolute path.
fn makePrefix(w: *World, prefix: []const u8, with_skill: bool) ![]const u8 {
    const arena = w.arena.allocator();
    const bin = try std.fs.path.join(arena, &.{ prefix, "bin", "beni" });
    try w.createDir(try std.fs.path.join(arena, &.{ prefix, "bin" }));
    try Io.Dir.cwd().copyFile(world.exePath(arena), w.tmp.dir, bin, w.io, .{});
    try w.makeExecutable(bin);
    // The skip prefix "." skips nothing of the folder, which holds no dot file;
    // an empty prefix would skip everything.
    if (with_skill) try w.copyTreeInto(skill_root, try std.fs.path.join(arena, &.{ prefix, "share", "beni", "skills", "beni" }), ".");
    return w.projectSubPath(arena, bin);
}

/// Run `<exe> skill <args...>` in the world's directory.
fn skill(w: *World, exe: []const u8, args: []const []const u8) !world.Result {
    const arena = w.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "skill" });
    try argv.appendSlice(arena, args);
    var env = std.process.Environ.Map.init(arena);
    return world.spawnAndCaptureIn(arena, w.io, argv.items, .{ .dir = w.tmp.dir }, world.default_timeout_ms, &env);
}

test "beni skill prints the folder beside the real binary, through a symlink too, and says when there is none" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const exe = try makePrefix(&w, "prefix", true);
    const bare = try makePrefix(&w, "bare", false);
    try w.symlink(exe, "elsewhere/bin/beni");
    const linked = try w.projectSubPath(arena, "elsewhere/bin/beni");
    const folder = try w.projectSubPath(arena, "prefix/share/beni/skills/beni");
    const bare_folder = try w.projectSubPath(arena, "bare/share/beni/skills/beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const direct = try skill(&w, exe, &.{});
    const through_link = try skill(&w, linked, &.{});
    const missing = try skill(&w, bare, &.{});
    const missing_install = try skill(&w, bare, &.{ "install", "dest" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), direct.exit_code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{folder}), direct.stdout);
    try testing.expectEqualStrings("", direct.stderr);
    // The symlink is resolved: the folder next to the REAL binary.
    try testing.expectEqual(@as(u8, 0), through_link.exit_code);
    try testing.expectEqualStrings(direct.stdout, through_link.stdout);
    const no_skill = try std.fmt.allocPrint(arena, "beni: no skill at '{s}'; 'zig build install' puts it beside the binary\n", .{bare_folder});
    try testing.expectEqual(@as(u8, 2), missing.exit_code);
    try testing.expectEqualStrings("", missing.stdout);
    try testing.expectEqualStrings(no_skill, missing.stderr);
    try testing.expectEqual(@as(u8, 2), missing_install.exit_code);
    try testing.expectEqualStrings(no_skill, missing_install.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("dest"));
}

test "beni skill install copies the folder, refuses to replace it, replaces it with --force, and links with --link" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const exe = try makePrefix(&w, "prefix", true);
    const folder = try w.projectSubPath(arena, "prefix/share/beni/skills/beni");
    const source = try w.projectSubPath(arena, "prefix/share/beni/skills/beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE, VERIFY OUTPUT                  │
    // └─────────────────────────────────────────┘
    // A copy, under a directory that does not exist yet.
    const copied = try skill(&w, exe, &.{ "install", "agent/skills" });
    try testing.expectEqual(@as(u8, 0), copied.exit_code);
    try testing.expectEqualStrings("Installed the beni skill at agent/skills/beni\n", copied.stdout);
    try testing.expectEqualStrings("", copied.stderr);
    try expectSameTree(arena, w.io, skill_root, try w.projectSubPath(arena, "agent/skills/beni"));
    try testing.expectEqual(Io.File.Kind.directory, try w.kind("agent/skills/beni"));

    // Again, without --force: refused, and the stray file proves nothing moved.
    try w.write("agent/skills/beni/stray.txt", "mine\n");
    const refused = try skill(&w, exe, &.{ "install", "agent/skills" });
    try testing.expectEqual(@as(u8, 2), refused.exit_code);
    try testing.expectEqualStrings("", refused.stdout);
    try testing.expectEqualStrings("beni: 'agent/skills/beni' exists; pass --force to replace it\n", refused.stderr);
    try testing.expect(w.exists("agent/skills/beni/stray.txt"));

    // --force: the old directory goes, stray file included.
    const forced = try skill(&w, exe, &.{ "install", "--force", "agent/skills" });
    try testing.expectEqual(@as(u8, 0), forced.exit_code);
    try testing.expectEqualStrings("Installed the beni skill at agent/skills/beni\n", forced.stdout);
    try testing.expect(!w.exists("agent/skills/beni/stray.txt"));
    try expectSameTree(arena, w.io, skill_root, try w.projectSubPath(arena, "agent/skills/beni"));

    // --link: one symlink to the installed folder. A directory is in the way,
    // so --force again.
    const link_refused = try skill(&w, exe, &.{ "install", "--link", "agent/skills" });
    try testing.expectEqual(@as(u8, 2), link_refused.exit_code);
    const linked = try skill(&w, exe, &.{ "install", "--link", "--force", "agent/skills" });
    try testing.expectEqual(@as(u8, 0), linked.exit_code);
    try testing.expectEqualStrings("Linked the beni skill at agent/skills/beni\n", linked.stdout);
    try testing.expectEqual(Io.File.Kind.sym_link, try w.kind("agent/skills/beni"));
    try testing.expectEqualStrings(source, try w.readLink("agent/skills/beni"));

    // --force over the link unlinks it and never follows it: the folder it
    // pointed at keeps every file.
    const over_link = try skill(&w, exe, &.{ "install", "--force", "agent/skills" });
    try testing.expectEqual(@as(u8, 0), over_link.exit_code);
    try testing.expectEqual(Io.File.Kind.directory, try w.kind("agent/skills/beni"));
    try expectSameTree(arena, w.io, skill_root, folder);

    // Usage errors do nothing.
    const no_dir = try skill(&w, exe, &.{"install"});
    try testing.expectEqual(@as(u8, 2), no_dir.exit_code);
    try testing.expectEqualStrings("beni: skill install needs exactly one directory\n", no_dir.stderr);
    const common = try skill(&w, exe, &.{"--jobs=1"});
    try testing.expectEqual(@as(u8, 2), common.exit_code);
    try testing.expectEqualStrings("beni: unknown option '--jobs'; run 'beni help' for usage\n", common.stderr);
    const other = try skill(&w, exe, &.{ "remove", "agent/skills" });
    try testing.expectEqual(@as(u8, 2), other.exit_code);
    try testing.expectEqualStrings("beni: skill has one subcommand, install, not 'remove'\n", other.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("remove"));
    try testing.expect(!w.exists("agent/skills/beni/stray.txt"));
    try testing.expect(!w.exists("agent/skills/.beni-new"));
    try testing.expect(!w.exists("agent/skills/.beni-old"));
}

test "beni skill install --force replaces only a beni skill, and refuses a directory inside the installed folder" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const exe = try makePrefix(&w, "prefix", true);
    // `<dir>/beni` that is a user's own directory, a file, and a skill of another name.
    try w.write("src/beni/README.md", "my clone\n");
    try w.write("files/beni", "a file\n");
    try w.write("other/beni/SKILL.md", "---\nname: beni-tools\ndescription: another skill\n---\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const clone = try skill(&w, exe, &.{ "install", "--force", "src" });
    const file = try skill(&w, exe, &.{ "install", "--force", "files" });
    const other = try skill(&w, exe, &.{ "install", "--force", "other" });
    const inside = try skill(&w, exe, &.{ "install", "prefix/share/beni/skills/beni/references" });
    const folder = try skill(&w, exe, &.{ "install", "prefix/share/beni/skills/beni" });
    const itself = try skill(&w, exe, &.{ "install", "--link", "--force", "prefix/share/beni/skills" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), clone.exit_code);
    try testing.expectEqualStrings("beni: 'src/beni' is not a beni skill; remove it yourself\n", clone.stderr);
    try testing.expectEqual(@as(u8, 2), file.exit_code);
    try testing.expectEqualStrings("beni: 'files/beni' is not a beni skill; remove it yourself\n", file.stderr);
    try testing.expectEqual(@as(u8, 2), other.exit_code);
    try testing.expectEqualStrings("beni: 'other/beni' is not a beni skill; remove it yourself\n", other.stderr);
    try testing.expectEqual(@as(u8, 2), inside.exit_code);
    try testing.expectEqualStrings("beni: 'prefix/share/beni/skills/beni/references/beni' is the installed skill, or lies inside it\n", inside.stderr);
    try testing.expectEqual(@as(u8, 2), folder.exit_code);
    try testing.expectEqualStrings("beni: 'prefix/share/beni/skills/beni/beni' is the installed skill, or lies inside it\n", folder.stderr);
    try testing.expectEqual(@as(u8, 2), itself.exit_code);
    try testing.expectEqualStrings("beni: 'prefix/share/beni/skills/beni' is the installed skill, or lies inside it\n", itself.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("my clone\n", try w.read("src/beni/README.md"));
    try testing.expectEqualStrings("a file\n", try w.read("files/beni"));
    try testing.expect(w.exists("other/beni/SKILL.md"));
    try testing.expectEqual(Io.File.Kind.directory, try w.kind("prefix/share/beni/skills/beni"));
    try testing.expect(!w.exists("prefix/share/beni/skills/beni/references/beni"));
    try testing.expect(!w.exists("prefix/share/beni/skills/beni/beni"));
}
