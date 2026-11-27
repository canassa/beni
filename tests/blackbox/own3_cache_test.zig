//! The module cache under `--ownership=v3`, black-box
//! (`docs/design/ownership-v3-kernel.md` §7.1; #2549).
//!
//! Before #2549 a run under `--ownership=v3` read and wrote no cache. Now a
//! module that the cache gives is not walked, and what its walk made is read
//! back from the entry's block. **One claim, in every scenario: a run with
//! the cache says what a run with `--no-cache` says**: the exit code, the
//! diagnostics and every byte of the emitted JavaScript. A stale verdict
//! here is an unsound write in place, so the scenarios are the edits that
//! change a verdict and no interface:
//!
//! - an import's body changes its contract and not its type, in both
//!   directions;
//! - a type error in another module hides a refusal, and is then corrected;
//! - one directory serves a run that does not enforce and one that does, the
//!   checker v1 and the checker v3, `--library` and a program;
//! - a block is damaged;
//! - a module that importers read is installed in a session with other
//!   symbols and other types than the one that stored it.
//!
//! The counters of `--self-profile` say whether the cache did anything: a
//! scenario that compared two cold runs would pass with no cache at all.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

// ---------------------------------------------------------------------------
// The project
// ---------------------------------------------------------------------------

const manifest =
    \\{ "name": "own3cache", "build": { "platform": "node", "paths": ["src"], "out": "out" } }
    \\
;

/// `grow` answers a new list: a write of its answer is no write of its argument.
const util_fresh =
    \\pub grow : List Int → List Int
    \\grow xs = List.copy xs
    \\
;

/// `grow` answers its argument: a write of its answer writes the argument.
/// The type is the same, and so is each other fact of the module's
/// interface: the two versions have one interface hash (`interfaceHash`),
/// so the cutoff key of an importer does not see the edit.
const util_same =
    \\pub grow : List Int → List Int
    \\grow xs = xs
    \\
;

/// Writes the answer of `Util.grow` and reads the argument after: accepted
/// where the answer is a new list, refused where it is the argument.
const main_source =
    \\import Node
    \\import Util
    \\
    \\
    \\main : Node.Program
    \\main =
    \\    xs = [ 1, 2, 3 ]
    \\    ys = List.push (Util.grow xs) 4
    \\    Node.print (String.fromInt (List.sum xs + List.sum ys))
    \\
;

fn writeProject(w: *World, util: []const u8) !void {
    try w.write("beni.json", manifest);
    try w.write("src/Util.beni", util);
    try w.write("src/Main.beni", main_source);
}

const enforced = [_][]const u8{ "build", "--ownership=v3", "--ownership-everywhere", "--lists-in-place" };

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

const Counters = struct { hits: u64 = 0, misses: u64 = 0, checked: u64 = 0, frontend_hits: u64 = 0, modules: u64 = 0 };

const Run = struct { result: world.Result, counters: Counters };

var trace_number: u32 = 0;

/// `beni <base> <extra> --self-profile=<trace>`, with the cache counters read back.
fn run(w: *World, arena: std.mem.Allocator, base: []const []const u8, extra: []const []const u8) !Run {
    trace_number += 1;
    const trace = try std.fmt.allocPrint(arena, "trace-{d}.json", .{trace_number});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, base);
    try argv.appendSlice(arena, extra);
    try argv.append(arena, try std.fmt.allocPrint(arena, "--self-profile={s}", .{trace}));
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
    const Event = struct {
        ph: []const u8,
        args: struct {
            cache_hits: ?u64 = null,
            cache_misses: ?u64 = null,
            modules_checked: ?u64 = null,
            frontend_hits: ?u64 = null,
            modules: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(trace), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var counters: Counters = .{};
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.cache_hits) |v| counters.hits = v;
        if (e.args.cache_misses) |v| counters.misses = v;
        if (e.args.modules_checked) |v| counters.checked = v;
        if (e.args.frontend_hits) |v| counters.frontend_hits = v;
        if (e.args.modules) |v| counters.modules = v;
    }
    return .{ .result = r, .counters = counters };
}

/// The interface hash of module `Util` under the enforced v3 run.
fn interfaceHash(w: *World, arena: std.mem.Allocator) ![]const u8 {
    const r = try w.runWith(&.{ "check", "--iface-hash", "--no-cache", "--ownership=v3", "--ownership-everywhere", "--platform=node", "src" }, .{ .raw_diagnostics = true });
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, "app:Util ")) return arena.dupe(u8, l);
    std.debug.print("--iface-hash printed no line for Util:\n{s}\n{s}\n", .{ r.stdout, r.stderr });
    return error.NoInterfaceHash;
}

/// Every file of output directory `dir`, as `path\0bytes` after one another:
/// two trees are the same when their texts are.
fn tree(w: *World, arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (try w.listFiles(dir)) |f| {
        try out.appendSlice(arena, f);
        try out.append(arena, 0);
        try out.appendSlice(arena, try w.read(try std.fs.path.join(arena, &.{ dir, f })));
        try out.append(arena, 0);
    }
    return out.items;
}

/// A run with the cache says what the run with no cache says.
fn expectSame(w: *World, arena: std.mem.Allocator, oracle: Run, oracle_out: []const u8, got: Run, got_out: []const u8) !void {
    try testing.expectEqual(oracle.result.exit_code, got.result.exit_code);
    try testing.expectEqualStrings(oracle.result.stdout, got.result.stdout);
    try testing.expectEqualStrings(oracle.result.stderr, got.result.stderr);
    try testing.expectEqualStrings(try tree(w, arena, oracle_out), try tree(w, arena, got_out));
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

test "a second build under --ownership=v3 installs every module and writes the same JavaScript" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w, util_fresh);

    const oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--out=out-oracle" });
    const cold = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-cold" });
    const warm = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-warm" });

    try testing.expectEqual(@as(u8, 0), oracle.result.exit_code);
    try expectSame(&w, arena, oracle, "out-oracle", cold, "out-cold");
    try expectSame(&w, arena, oracle, "out-oracle", warm, "out-warm");
    // The write is in place in all three: the lowering channel of an
    // installed module is the walked one's. A plain build copies.
    const plain = try run(&w, arena, &.{"build"}, &.{ "--no-cache", "--out=out-plain" });
    try testing.expectEqual(@as(u8, 0), plain.result.exit_code);
    try testing.expect(!std.mem.eql(u8, try w.read("out-plain/Main.mjs"), try w.read("out-warm/Main.mjs")));

    // Cold: nothing to install, and every module of the graph is checked,
    // core's too (the checked core has no block of v3). Warm: every module
    // is installed and none is checked or walked.
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);
    try testing.expectEqual(cold.counters.modules, cold.counters.checked);
    try testing.expect(cold.counters.modules > 2);
    try testing.expectEqual(warm.counters.modules, warm.counters.hits);
    try testing.expectEqual(@as(u64, 0), warm.counters.misses);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    try testing.expect(warm.counters.frontend_hits > 0);
}

test "an import whose body changes its contract and not its type: the importer is judged again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both directions: accepted then refused, and refused then accepted.
    for ([_][2][]const u8{ .{ util_fresh, util_same }, .{ util_same, util_fresh } }, 0..) |pair, round| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try writeProject(&w, pair[0]);
        const hash_before = try interfaceHash(&w, arena);
        const before = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-before" });
        const before_oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--out=out-before-oracle" });
        try expectSame(&w, arena, before_oracle, "out-before-oracle", before, "out-before");

        try w.write("src/Util.beni", pair[1]);
        // The edit moves no byte of the interface: only the transitive key
        // of `Main` sees it (kernel §7.1, rule 1).
        try testing.expectEqualStrings(hash_before, try interfaceHash(&w, arena));
        const oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--out=out-oracle" });
        const after = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-after" });
        try expectSame(&w, arena, oracle, "out-oracle", after, "out-after");
        // The verdict did change with the edit, or the scenario shows nothing.
        try testing.expect(before_oracle.result.exit_code != oracle.result.exit_code);
        const refused: Run = if (round == 0) oracle else before_oracle;
        try testing.expectEqual(@as(u8, 1), refused.result.exit_code);
        try testing.expect(std.mem.indexOf(u8, refused.result.stderr, "is refused") != null);
        // `Util` and `Main` are checked again; core is installed.
        try testing.expectEqual(@as(u64, 2), after.counters.checked);
        try testing.expect(after.counters.hits > 0);

        // And back: the first build's answer again.
        try w.write("src/Util.beni", pair[0]);
        const back = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-back" });
        try expectSame(&w, arena, before_oracle, "out-before-oracle", back, "out-back");
    }
}

test "a refusal that a type error in another module hid is shown when the error is corrected" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w, util_same);
    // `Other` is imported by no module, and has a type error. The check
    // drops each ownership diagnostic while a type error stands
    // (`Check.run`), so `Main` looks clean in this build.
    try w.write("src/Other.beni",
        \\pub n : Int
        \\n = "one"
        \\
    );
    const broken = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-broken" });
    try testing.expectEqual(@as(u8, 1), broken.result.exit_code);
    try testing.expect(std.mem.indexOf(u8, broken.result.stderr, "is refused") == null);

    try w.write("src/Other.beni",
        \\pub n : Int
        \\n = 1
        \\
    );
    const oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--out=out-oracle" });
    const fixed = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-fixed" });
    try testing.expectEqual(@as(u8, 1), oracle.result.exit_code);
    try testing.expect(std.mem.indexOf(u8, oracle.result.stderr, "is refused") != null);
    try expectSame(&w, arena, oracle, "out-oracle", fixed, "out-fixed");
    // And every later build: the module with the refusal is never stored.
    const again = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-again" });
    try expectSame(&w, arena, oracle, "out-oracle", again, "out-again");
}

test "one cache directory: a run that does not enforce, then one that does" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w, util_same);
    // `node` does not edit lists in place: without `--ownership-everywhere`
    // the refusal is no error, and every module is stored.
    const report_only = [_][]const u8{ "build", "--ownership=v3" };
    const loose = try run(&w, arena, &report_only, &.{ "--cache-dir=cache", "--out=out-loose" });
    try testing.expectEqual(@as(u8, 0), loose.result.exit_code);
    const loose_warm = try run(&w, arena, &report_only, &.{ "--cache-dir=cache", "--out=out-loose-warm" });
    try testing.expectEqual(loose_warm.counters.modules, loose_warm.counters.hits);
    try expectSame(&w, arena, loose, "out-loose", loose_warm, "out-loose-warm");

    const strict = [_][]const u8{ "build", "--ownership=v3", "--ownership-everywhere" };
    const oracle = try run(&w, arena, &strict, &.{ "--no-cache", "--out=out-oracle" });
    const got = try run(&w, arena, &strict, &.{ "--cache-dir=cache", "--out=out-strict" });
    try testing.expectEqual(@as(u8, 1), oracle.result.exit_code);
    try expectSame(&w, arena, oracle, "out-oracle", got, "out-strict");
}

test "one cache directory: the checker v1, then v3, then v1 again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w, util_fresh);
    const v1 = [_][]const u8{"build"};
    const v3 = [_][]const u8{ "build", "--ownership=v3" };

    const v1_oracle = try run(&w, arena, &v1, &.{ "--no-cache", "--out=out-v1-oracle" });
    const v3_oracle = try run(&w, arena, &v3, &.{ "--no-cache", "--out=out-v3-oracle" });
    const v1_cold = try run(&w, arena, &v1, &.{ "--cache-dir=cache", "--out=out-v1-cold" });
    const v3_cold = try run(&w, arena, &v3, &.{ "--cache-dir=cache", "--out=out-v3-cold" });
    const v1_warm = try run(&w, arena, &v1, &.{ "--cache-dir=cache", "--out=out-v1-warm" });
    const v3_warm = try run(&w, arena, &v3, &.{ "--cache-dir=cache", "--out=out-v3-warm" });

    try expectSame(&w, arena, v1_oracle, "out-v1-oracle", v1_cold, "out-v1-cold");
    try expectSame(&w, arena, v1_oracle, "out-v1-oracle", v1_warm, "out-v1-warm");
    try expectSame(&w, arena, v3_oracle, "out-v3-oracle", v3_cold, "out-v3-cold");
    try expectSame(&w, arena, v3_oracle, "out-v3-oracle", v3_warm, "out-v3-warm");
    // No entry of one checker is read by the other: v3's first run with the
    // directory installs no module, though v1 stored two.
    try testing.expectEqual(@as(u64, 0), v3_cold.counters.hits);
    try testing.expectEqual(@as(u64, 2), v1_warm.counters.hits);
    try testing.expectEqual(v3_warm.counters.modules, v3_warm.counters.hits);
}

test "one cache directory: --library and a program" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("beni.json", manifest);
    // Under `--library` host JavaScript calls `push` with a list that it may
    // still hold (kernel §6.14); in a program each caller is checked.
    try w.write("src/Lib.beni",
        \\pub push : List Int → List Int
        \\push xs = List.push xs 1
        \\
    );
    const program = [_][]const u8{ "check", "--platform=node", "--ownership=v3", "--ownership-everywhere" };
    const library = [_][]const u8{ "build", "--library", "--ownership=v3", "--ownership-everywhere" };
    const program_oracle = try run(&w, arena, &program, &.{ "--no-cache", "src" });
    const library_oracle = try run(&w, arena, &library, &.{ "--no-cache", "--out=out-oracle" });
    for (0..2) |i| {
        const p = try run(&w, arena, &program, &.{ "--cache-dir=cache", "src" });
        try testing.expectEqual(program_oracle.result.exit_code, p.result.exit_code);
        try testing.expectEqualStrings(program_oracle.result.stderr, p.result.stderr);
        const out = try std.fmt.allocPrint(arena, "out-{d}", .{i});
        const l = try run(&w, arena, &library, &.{ "--cache-dir=cache", try std.fmt.allocPrint(arena, "--out={s}", .{out}) });
        try expectSame(&w, arena, library_oracle, "out-oracle", l, out);
    }
}

test "a damaged block is a miss: the module is checked and walked again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w, util_fresh);
    const oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--out=out-oracle" });
    const cold = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-cold" });
    try expectSame(&w, arena, oracle, "out-oracle", cold, "out-cold");

    // Each entry's block starts with its magic. Three kinds of damage, each
    // in every entry: the version, a byte of the body, and the last bytes cut
    // off (the entry's table still names them, so the entry itself is bad).
    const block_magic = "OWN3BLK\x00";
    var damaged: usize = 0;
    for ([_]u8{ 0, 1, 2 }) |kind| {
        for (try w.listFiles("cache")) |f| {
            if (!std.mem.endsWith(u8, f, ".bec")) continue;
            const path = try std.fs.path.join(arena, &.{ "cache", f });
            const bytes = try w.read(path);
            const at = std.mem.indexOf(u8, bytes, block_magic) orelse continue;
            const copy = try arena.dupe(u8, bytes);
            switch (kind) {
                0 => copy[at + block_magic.len] ^= 0xff,
                1 => copy[at + block_magic.len + 9] ^= 0xff,
                else => {},
            }
            try w.write(path, if (kind == 2) copy[0 .. copy.len - 3] else copy);
            damaged += 1;
        }
        const out = try std.fmt.allocPrint(arena, "out-damaged-{d}", .{kind});
        const got = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", try std.fmt.allocPrint(arena, "--out={s}", .{out}) });
        try expectSame(&w, arena, oracle, "out-oracle", got, out);
        try testing.expectEqual(@as(u64, 0), got.counters.hits);
        try testing.expectEqual(got.counters.modules, got.counters.checked);
        // The run stored good entries in place of the damaged ones.
        const repaired = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-repaired" });
        try testing.expectEqual(repaired.counters.modules, repaired.counters.hits);
    }
    try testing.expect(damaged >= 3 * 3);
}

test "a warm build under --ownership=v3 is the same at --jobs=1 and --jobs=8" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w, util_fresh);
    const oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--jobs=1", "--out=out-oracle" });
    const cold = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--jobs=8", "--out=out-cold" });
    try expectSame(&w, arena, oracle, "out-oracle", cold, "out-cold");
    for ([_][]const u8{ "--jobs=1", "--jobs=8" }) |jobs| {
        const out = try std.fmt.allocPrint(arena, "out{s}", .{jobs});
        const warm = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", jobs, try std.fmt.allocPrint(arena, "--out={s}", .{out}) });
        try expectSame(&w, arena, oracle, "out-oracle", warm, out);
        try testing.expectEqual(warm.counters.modules, warm.counters.hits);
    }
}

// ---------------------------------------------------------------------------
// Another session's ids
// ---------------------------------------------------------------------------

const shapes_source =
    \\pub type alias Box =
    \\    { items : List Int
    \\    , label : String
    \\    , spare : List Int
    \\    }
    \\
    \\
    \\pub type Pair
    \\    = Pair (List Int) (List Int)
    \\
;

/// Contracts over a record's fields and a constructor's arguments:
/// `itemsOf` answers the list at `items`, `leftOf` and `rightOf` the first
/// and the second list of a pair.
const lookup_source =
    \\import Shapes exposing (Box, Pair)
    \\
    \\
    \\pub itemsOf : Box → List Int
    \\itemsOf box = box.items
    \\
    \\
    \\pub leftOf : Pair → List Int
    \\leftOf pair =
    \\    case pair of
    \\        Pair left _ →
    \\            left
    \\
    \\
    \\pub rightOf : Pair → List Int
    \\rightOf pair =
    \\    case pair of
    \\        Pair _ right →
    \\            right
    \\
;

/// A write of what `Lookup` answers (`written`), then a read (`read`) of
/// the value that it was taken from.
fn userSource(arena: std.mem.Allocator, written: []const u8, read: []const u8, comment: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{s}import Lookup
        \\import Node
        \\import Shapes exposing (Box, Pair)
        \\
        \\
        \\main : Node.Program
        \\main =
        \\    box = {{ items = [ 1, 2 ], label = "b", spare = [ 3 ] }}
        \\    pair = Pair [ 4 ] [ 5 ]
        \\    written = List.push ({s}) 6
        \\    Node.print (String.fromInt (List.sum written + List.sum ({s})))
        \\
    , .{ comment, written, read });
}

/// A module that no other imports, with fields and types whose names sort
/// before, between and after those of `Shapes`: with it in the build, each
/// field of `Shapes` has another text rank and each type another `TypeId`.
const decoy_source =
    \\pub type alias Aardvark =
    \\    { aaa : List Int
    \\    , itemz : List Int
    \\    , j : Int
    \\    , labek : String
    \\    , spara : List Int
    \\    , zzz : Int
    \\    }
    \\
    \\
    \\pub type Ant
    \\    = Ant (List Int)
    \\    | Bee Ant Ant
    \\
    \\
    \\pub type Zebra
    \\    = Zebra (List Int)
    \\
;

test "a block read in a session with other text ranks and type ids gives the importer the same verdicts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A write is accepted where the contract of `Lookup` names the one
    // location that the answer holds, and the later read is of another: a
    // label with the rank of another field, or the id of another type, names
    // no location of the argument, the answer then holds every cell of it,
    // and the write is refused. A write with a later read of the same
    // location is refused in every session.
    const cases = [_]struct { written: []const u8, read: []const u8, exit: u8 }{
        .{ .written = "Lookup.itemsOf box", .read = "box.spare", .exit = 0 },
        .{ .written = "Lookup.itemsOf box", .read = "box.items", .exit = 1 },
        .{ .written = "Lookup.leftOf pair", .read = "Lookup.rightOf pair", .exit = 0 },
        .{ .written = "Lookup.leftOf pair", .read = "Lookup.leftOf pair", .exit = 1 },
    };
    for (cases) |case| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try w.write("beni.json", manifest);
        try w.write("src/Shapes.beni", shapes_source);
        try w.write("src/Lookup.beni", lookup_source);
        try w.write("src/Main.beni", try userSource(arena, case.written, case.read, ""));
        // Stores `Shapes` and `Lookup` (and `Main` where it is accepted).
        const first = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-first" });
        try testing.expectEqual(case.exit, first.result.exit_code);

        // Another session: the decoy's symbols and types, and `Main` changed
        // by a comment, so it is walked against the blocks of `Shapes` and
        // `Lookup` that the first session stored.
        try w.write("src/Aardvark.beni", decoy_source);
        try w.write("src/Main.beni", try userSource(arena, case.written, case.read, "-- walked again\n"));
        const oracle = try run(&w, arena, &enforced, &.{ "--no-cache", "--out=out-oracle" });
        const got = try run(&w, arena, &enforced, &.{ "--cache-dir=cache", "--out=out-got" });
        try testing.expectEqual(case.exit, oracle.result.exit_code);
        try expectSame(&w, arena, oracle, "out-oracle", got, "out-got");
        // `Main` and the decoy are checked; `Shapes`, `Lookup` and core are installed.
        try testing.expectEqual(@as(u64, 2), got.counters.checked);
    }
}
