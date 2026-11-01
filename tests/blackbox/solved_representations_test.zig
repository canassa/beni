//! Actual ordinary provenance through the installed source/cache boundary.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;
const header = "solved-representations schema=1 hostfree=false wire=false phase=P9-before-ownership\n";
fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/typed-entry-roots/basic", "_excluded.");
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
}
fn checked(w: *World, path: []const u8) !u64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, try w.read(path), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("traceEvents").?.array.items) |e| {
        if (!std.mem.eql(u8, e.object.get("name").?.string, "modules_checked")) continue;
        return @intCast(e.object.get("args").?.object.get("modules_checked").?.integer);
    }
    return error.MissingCheckedCounter;
}
fn run(w: *World, profile: []const u8, extra: []const []const u8) !world.Result {
    const a = w.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try argv.appendSlice(a, extra);
    try argv.append(a, try std.fmt.allocPrint(a, "--self-profile={s}", .{profile}));
    const result = try w.run(argv.items);
    try clean(result);
    return result;
}
fn metric(line: []const u8, key: []const u8) !u64 {
    const start = (std.mem.indexOf(u8, line, key) orelse return error.MissingMetric) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    return std.fmt.parseInt(u64, line[start..end], 10);
}
fn inventory(full_text: []const u8) ![]const u8 {
    const text = try @import("entry_roles.zig").before(full_text);
    _ = try @import("entry_solved.zig").before(text);
    const start = std.mem.indexOf(u8, text, header) orelse return error.MissingSolvedInventory;
    try testing.expect(std.mem.indexOfPos(u8, text, start + header.len, header) == null);
    try testing.expect(std.mem.endsWith(u8, text, "end-solved-representations\n"));
    var modules: usize = 0;
    var roots: u64 = 0;
    var expected_roots: u64 = 0;
    var nodes: u64 = 0;
    var expected_nodes: u64 = 0;
    var parent_edges: u64 = 0;
    var lines = std.mem.splitScalar(u8, text[start + header.len ..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, "end-solved-representations")) continue;
        if (std.mem.startsWith(u8, line, "solved-module ")) {
            try testing.expectEqual(expected_roots, roots);
            try testing.expectEqual(expected_nodes, nodes);
            roots = 0;
            nodes = 0;
            const d = try metric(line, "D=");
            const t = try metric(line, "T_store=");
            try testing.expect(d >= t);
            try testing.expectEqual(d - t, try metric(line, "parentEdges="));
            try testing.expect(try metric(line, "F_store=") <= try metric(line, "E_store="));
            expected_roots = try metric(line, "roots=");
            expected_nodes = try metric(line, "reachedNodes=");
            try testing.expect(expected_nodes <= t);
            parent_edges += d - t;
            modules += 1;
        } else if (std.mem.startsWith(u8, line, "  solved-root ")) {
            roots += 1;
        } else if (std.mem.startsWith(u8, line, "  solved-node ")) {
            nodes += 1;
        } else return error.UnknownSolvedRow;
    }
    try testing.expectEqual(expected_roots, roots);
    try testing.expectEqual(expected_nodes, nodes);
    try testing.expect(modules > 0 and parent_edges > 0);
    try testing.expect(std.mem.indexOf(u8, text[start..], " entry ") != null);
    try testing.expect(std.mem.indexOf(u8, text[start..], " nominal_template ") != null);
    try testing.expect(std.mem.indexOf(u8, text[start..], " alias_template ") != null);
    return text[start..];
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn cacheEntry(w: *World) ![]const u8 {
    const r = try w.run(&.{ "check", "--cache-keys", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(r);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "app:Main ")) {
        const hash = line[9..];
        try testing.expectEqual(@as(usize, 32), hash.len);
        return std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ hash[0..2], hash[2..] });
    };
    return error.MissingMainKey;
}
fn payloadAt(bytes: []const u8) !usize {
    const side = word(bytes, 40);
    const count = word(bytes, side + 12);
    try testing.expect(count > 0);
    const column = side + 16 + (count - 1) * 8;
    const at = side + word(bytes, column);
    try testing.expectEqualStrings("BENISLV\x00", bytes[at..][0..8]);
    return at;
}

test "solved representations retain real source binders and complete installed graph across warm jobs roundtrip relocation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const cold = try run(&w, "cold.json", &.{"--jobs=1"});
    _ = try inventory(cold.stdout);
    try testing.expect(try checked(&w, "cold.json") > 0);
    const warm = try run(&w, "warm.json", &.{"--jobs=8"});
    _ = try inventory(warm.stdout);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "warm.json"));
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    const parallel = try run(&w, "parallel.json", &.{ "--jobs=8", "--cache-dir=parallel" });
    _ = try inventory(parallel.stdout);
    try testing.expectEqualStrings(cold.stdout, parallel.stdout);
    const roundtrip = try run(&w, "roundtrip.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch", "--roundtrip-interfaces" });
    _ = try inventory(roundtrip.stdout);
    try testing.expectEqualStrings(cold.stdout, roundtrip.stdout);
    _ = try run(&w, "roundtrip-warm.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch" });
    try testing.expectEqual(@as(u64, 0), try checked(&w, "roundtrip-warm.json"));
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved);
    for (try w.listFiles("cache")) |name| {
        const path = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name});
        try moved.write(path, try w.read(path));
    }
    const relocated = try run(&moved, "relocated.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(cold.stdout, relocated.stdout);
    try testing.expectEqual(@as(u64, 0), try checked(&moved, "relocated.json"));
    try testing.expect(!w.exists("out") and !moved.exists("out"));
}

test "solved representation demand skips diagnostic payload on default and repairs malformed or missing requested cache evidence" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const initial = try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(initial);
    try testing.expectEqualStrings("", initial.stdout);
    const cold = try run(&w, "query-after-default.json", &.{});
    _ = try inventory(cold.stdout);
    try testing.expect(try checked(&w, "query-after-default.json") > 0);
    const warm = try run(&w, "warm.json", &.{});
    try testing.expectEqual(@as(u64, 0), try checked(&w, "warm.json"));
    const path = try cacheEntry(&w);
    const original = try w.read(path);
    const graph = try payloadAt(original);
    const corrupted = try w.arena.allocator().dupe(u8, original);
    // Correct outer BEC envelope; wrong private magic. Default must skip this
    // graph entirely, while a requested query repairs before exposing rows.
    corrupted[graph] ^= 1;
    try w.write(path, corrupted);
    const ordinary = try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "--self-profile=ordinary-after-query.json", "Main.beni" });
    try clean(ordinary);
    try testing.expectEqualStrings("", ordinary.stdout);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "ordinary-after-query.json"));
    const repaired = try run(&w, "repaired.json", &.{});
    try testing.expectEqualStrings(cold.stdout, repaired.stdout);
    try testing.expect(try checked(&w, "repaired.json") > 0);
    const after = try w.read(path);
    try testing.expectEqualStrings(original[word(original, 32)..][0..word(original, 36)], after[word(after, 32)..][0..word(after, 36)]);
    // Malformed source provenance, root/formal ranges and count metadata all
    // fail the actual common decoder/coverage path and recover warm source0.
    for ([_]usize{ 12, 16, 20, 24, 28, 32, 36, 40 }) |offset| {
        const bad = try w.arena.allocator().dupe(u8, original);
        put(bad, graph + offset, std.math.maxInt(u32));
        try w.write(path, bad);
        const result = try run(&w, "mutation.json", &.{});
        try testing.expectEqualStrings(warm.stdout, result.stdout);
        try testing.expect(try checked(&w, "mutation.json") > 0);
        _ = try run(&w, "mutation-warm.json", &.{});
        try testing.expectEqual(@as(u64, 0), try checked(&w, "mutation-warm.json"));
    }
    try testing.expect(!w.exists("out"));
}

test "solved representation cache rejects valid-index alias anchors formal scope collisions and owner substitutions" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const source = try std.fmt.allocPrint(w.arena.allocator(), "{s}\n\ntype alias Twin a =\n    message : a\n\ntwin : Worker.Program (Twin Int) ⊤\ntwin = Worker.empty ⊤\n", .{try w.read("Main.beni")});
    try w.write("Main.beni", source);
    const first = try run(&w, "scope-cold.json", &.{});
    _ = try inventory(first.stdout);
    const path = try cacheEntry(&w);
    const original = try w.read(path);
    const graph = try payloadAt(original);
    const roots_at = graph + 48 + word(original, graph + 16) * 32 + word(original, graph + 24) * 12;
    const formals_at = roots_at + word(original, graph + 32) * 32;
    var alias_a: ?usize = null;
    var alias_b: ?usize = null;
    var formal_pair: ?usize = null;
    var nominal: ?usize = null;
    for (0..word(original, graph + 32)) |i| {
        const root = roots_at + i * 32;
        const kind = word(original, root);
        if (kind == 2 and word(original, root + 24) == 1 and word(original, root + 28) == 0) {
            if (alias_a == null) alias_a = root else if (word(original, root + 8) != word(original, alias_a.? + 8)) alias_b = root;
        }
        if (word(original, root + 24) >= 2) formal_pair = root;
        if (kind == 1) nominal = root;
    }
    try testing.expect(alias_a != null and alias_b != null and formal_pair != null and nominal != null);
    for (0..4) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, original);
        switch (mutation) {
            0 => { // Both words name a real same-arity alias, but duplicate its
                // exact original TypeRef anchor and lose the other body scope.
                put(bad, alias_a.? + 8, word(original, alias_b.? + 8));
                put(bad, alias_a.? + 12, word(original, alias_b.? + 12));
            },
            1 => {
                const formal = formals_at + word(original, formal_pair.? + 20) * 4;
                put(bad, formal, word(original, formal + 4));
            },
            2 => put(bad, nominal.? + 4, word(original, nominal.? + 4) + 1),
            3 => put(bad, alias_a.? + 28, 1),
            else => unreachable,
        }
        try w.write(path, bad);
        const fixed = try run(&w, "scope-fixed.json", &.{});
        try testing.expectEqualStrings(first.stdout, fixed.stdout);
        try testing.expect(try checked(&w, "scope-fixed.json") > 0);
        _ = try run(&w, "scope-warm.json", &.{});
        try testing.expectEqual(@as(u64, 0), try checked(&w, "scope-warm.json"));
    }
}

test "solved representation dependency errors add no internal diagnostic and restore original owned evidence" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const main = try std.fmt.allocPrint(w.arena.allocator(), "import Library\n{s}\n\ntype Hidden = Hidden Library.Bad\n", .{try w.read("Main.beni")});
    try w.write("Main.beni", main);
    try w.write("Library.beni", "pub type alias Bad = Int\n");
    const first = try run(&w, "dependency-cold.json", &.{"Library.beni"});
    _ = try inventory(first.stdout);
    try w.write("Library.beni", "pub type alias Bad = Missing\n");
    for (0..2) |_| {
        const bad = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "Library.beni" });
        try testing.expectEqual(@as(u8, 1), bad.exit_code);
        try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
        try testing.expectEqual(@import("diagnostic").Code.unbound_type, bad.diagnostics[0].code);
        try testing.expectEqualStrings("Library.beni", bad.diagnostics[0].span.file);
        try testing.expectEqualStrings("", bad.stdout);
    }
    try w.write("Library.beni", "pub type alias Bad = Int\n");
    const repaired = try run(&w, "dependency-restored.json", &.{"Library.beni"});
    try testing.expectEqualStrings(first.stdout, repaired.stdout);
    _ = try run(&w, "dependency-warm.json", &.{"Library.beni"});
    try testing.expectEqual(@as(u64, 0), try checked(&w, "dependency-warm.json"));
    try testing.expect(!w.exists("out"));
}

fn moduleInventory(text: []const u8, module: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, text, module) orelse return error.MissingModuleInventory;
    const next = std.mem.indexOfPos(u8, text, start + module.len, "solved-module ") orelse std.mem.indexOfPos(u8, text, start, "end-solved-representations") orelse return error.MissingInventoryEnd;
    return text[start..next];
}
test "solved representation cached provenance relinks after an unrelated earlier nominal module changes dense type ids" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const before = try run(&w, "before-earlier.json", &.{});
    _ = try inventory(before.stdout);
    const main_path = try cacheEntry(&w);
    const main_bytes = try w.read(main_path);
    try w.write("AA.beni", "pub type Earlier a = Earlier a\n");
    const after = try run(&w, "after-earlier.json", &.{"AA.beni"});
    _ = try inventory(after.stdout);
    try testing.expectEqualStrings(try moduleInventory(before.stdout, "solved-module app:Main "), try moduleInventory(after.stdout, "solved-module app:Main "));
    // The existing Main cache artifact is preserved, not silently rebuilt
    // to hide dense-id leakage. Only AA is a fresh source module.
    try testing.expectEqual(@as(u64, 1), try checked(&w, "after-earlier.json"));
    try testing.expectEqualStrings(main_bytes, try w.read(main_path));
    _ = try run(&w, "after-earlier-warm.json", &.{"AA.beni"});
    try testing.expectEqual(@as(u64, 0), try checked(&w, "after-earlier-warm.json"));
}

const solved_reader_fixture =
    \\solved-representations schema=1 hostfree=false wire=false phase=P9-before-ownership
    \\solved-module app:Main D=5 T_store=3 E_store=2 F_store=0 parentEdges=2 roots=1 formals=1 reachedNodes=3 reachedEdges=2
    \\  solved-root 0 entry declaration=0 anchor=0 origin=entry node=0 owner=<entry> formals=0:1
    \\  solved-node 0 source=0 function rank=0 kind=any equatable=false edges=argument:0->1,result:0->2
    \\  solved-node 1 source=2 flex rank=1 kind=number equatable=true edges=
    \\  solved-node 2 source=4 unit rank=0 kind=any equatable=false edges=
    \\end-solved-representations
    \\
;
test "solved suffix generic reader accepts zero roots and source graphs without fixture templates" {
    const reader = @import("entry_solved.zig");
    try testing.expectEqualStrings("", try reader.before(solved_reader_fixture));
    const empty =
        \\solved-representations schema=1 hostfree=false wire=false phase=P9-before-ownership
        \\solved-module core:Unused D=7 T_store=4 E_store=2 F_store=1 parentEdges=3 roots=0 formals=0 reachedNodes=0 reachedEdges=0
        \\end-solved-representations
        \\
    ;
    try testing.expectEqualStrings("", try reader.before(empty));
    try testing.expectEqualStrings("", try reader.before(reader.header ++ reader.end));
    const alias =
        \\solved-representations schema=1 hostfree=false wire=false phase=P9-before-ownership
        \\solved-module app:Alias D=3 T_store=3 E_store=2 F_store=0 parentEdges=0 roots=1 formals=1 reachedNodes=3 reachedEdges=2
        \\  solved-root 0 alias_template declaration=0 anchor=0 origin=entry node=0 owner=app:Alias.Box formals=0:1
        \\  solved-node 0 source=0 alias rank=0 kind=any equatable=false edges=actual:0->2,argument:0->1 nominal=app:Alias.Box
        \\  solved-node 1 source=1 rigid rank=0 kind=dict_key equatable=true edges=
        \\  solved-node 2 source=2 unit rank=0 kind=any equatable=false edges=
        \\end-solved-representations
        \\
    ;
    try testing.expectEqualStrings("", try reader.before(alias));
}

test "solved suffix generic reader rejects malformed keys enums identities counts and proof flags" {
    const reader = @import("entry_solved.zig");
    const mutations = [_]struct { []const u8, []const u8 }{
        .{ "hostfree=false", "hostfree=true" },     .{ "wire=false", "wire=true" },
        .{ "D=5", "D=2" },                          .{ "E_store=2", "E_store=1" },
        .{ "F_store=0", "F_store=3" },              .{ "parentEdges=2", "parentEdges=1" },
        .{ "roots=1", "roots=2" },                  .{ "formals=1", "formals=2" },
        .{ "reachedNodes=3", "reachedNodes=2" },    .{ "reachedEdges=2", "reachedEdges=1" },
        .{ "T_store=3", "T_store=3 unknown=0" },    .{ "  solved-root 0 entry", "  solved-root 1 entry" },
        .{ "anchor=0", "anchor=4294967295" },       .{ "origin=entry", "origin=alien" },
        .{ "owner=<entry>", "owner=app:Main.Box" }, .{ "node=0", "node=3" },
        .{ "formals=0:1", "formals=1:1" },          .{ "formals=0:1", "formals=0:2" },
        .{ "kind=number", "kind=alien" },           .{ "source=4", "source=5" },
        .{ "solved-node 2", "solved-node 1" },      .{ "argument:0->1", "argument:1->1" },
        .{ "result:0->2", "result:0->3" },          .{ "kind=any equatable=false", "kind=any equatable=true" },
        .{ "  solved-node", "  alien-node" },       .{ "rank=0", "rank=0 unknown=0" },
    };
    for (mutations) |mutation| {
        const changed = try std.mem.replaceOwned(u8, testing.allocator, solved_reader_fixture, mutation[0], mutation[1]);
        defer testing.allocator.free(changed);
        if (reader.before(changed)) |_| return error.MalformedSolvedAccepted else |_| {}
    }
    const extra = try std.mem.concat(testing.allocator, u8, &.{ solved_reader_fixture, "unknown-row\n" });
    defer testing.allocator.free(extra);
    if (reader.before(extra)) |_| return error.TrailingSolvedAccepted else |_| {}
    const duplicate = try std.mem.concat(testing.allocator, u8, &.{ solved_reader_fixture, reader.header, reader.end });
    defer testing.allocator.free(duplicate);
    if (reader.before(duplicate)) |_| return error.DuplicateSolvedAccepted else |_| {}
    const truncated = solved_reader_fixture[0 .. solved_reader_fixture.len - reader.end.len];
    if (reader.before(truncated)) |_| return error.TruncatedSolvedAccepted else |_| {}
}

fn indexCounter(w: *World, path: []const u8, key: []const u8) !u64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, try w.read(path), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("traceEvents").?.array.items) |event| {
        if (!std.mem.eql(u8, event.object.get("name").?.string, key)) continue;
        return @intCast(event.object.get("args").?.object.get(key).?.integer);
    }
    return error.MissingCanonicalCounter;
}
test "canonical source index compares same-check inventory and grants no cache or default authority" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const initial = try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "--self-profile=default.json", "Main.beni" });
    try clean(initial);
    try testing.expectEqualStrings("", initial.stdout);
    for ([_][]const u8{ "canonical_fresh", "canonical_register", "canonical_export_nodes", "canonical_oracle_nodes" }) |key|
        try testing.expectEqual(@as(u64, 0), try indexCounter(&w, "default.json", key));
    const query = try run(&w, "index-source.json", &.{});
    _ = try inventory(query.stdout);
    try testing.expect(try indexCounter(&w, "index-source.json", "canonical_fresh") > 0);
    const nodes = try indexCounter(&w, "index-source.json", "canonical_export_nodes");
    const edges = try indexCounter(&w, "index-source.json", "canonical_export_edges");
    try testing.expect(nodes > 0 and edges > 0);
    try testing.expectEqual(nodes, try indexCounter(&w, "index-source.json", "canonical_oracle_nodes"));
    try testing.expectEqual(edges, try indexCounter(&w, "index-source.json", "canonical_oracle_edges"));
    try testing.expect(try indexCounter(&w, "index-source.json", "canonical_register") >= edges);
    const files = try w.listFiles("cache");
    const before = try w.arena.allocator().alloc([]const u8, files.len);
    for (files, before) |name, *bytes| bytes.* = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name}));
    const warm = try run(&w, "index-warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(query.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "index-warm.json"));
    const ordinary = try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "--self-profile=default-after-index.json", "Main.beni" });
    try clean(ordinary);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "default-after-index.json"));
    for ([_][]const u8{ "canonical_fresh", "canonical_export_nodes", "canonical_oracle_nodes" }) |key| {
        try testing.expectEqual(@as(u64, 0), try indexCounter(&w, "index-warm.json", key));
        try testing.expectEqual(@as(u64, 0), try indexCounter(&w, "default-after-index.json", key));
    }
    const after = try w.listFiles("cache");
    try testing.expectEqual(files.len, after.len);
    for (files, after, before) |name, after_name, bytes| {
        try testing.expectEqualStrings(name, after_name);
        try testing.expectEqualSlices(u8, bytes, try w.read(try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name})));
    }
}

test "canonical source index does not publish dependency-tainted or erroneous inventory and restores cache source zero" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const initial = try run(&w, "before-error.json", &.{});
    const original = try w.read("Main.beni");
    try w.write("Main.beni", try std.fmt.allocPrint(w.arena.allocator(), "{s}\n\nbad : Missing\nbad = ⊤\n", .{original}));
    const bad = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "--self-profile=bad.json", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), bad.exit_code);
    try testing.expectEqualStrings("", bad.stdout);
    try testing.expect(std.mem.indexOf(u8, bad.stderr, "UNKNOWN TYPE") != null);
    try testing.expect(std.mem.indexOf(u8, bad.stderr, "INTERNAL") == null);
    try testing.expect(try indexCounter(&w, "bad.json", "canonical_fresh") > 0);
    try testing.expectEqual(@as(u64, 0), try indexCounter(&w, "bad.json", "canonical_oracle_nodes"));
    try w.write("Main.beni", original);
    const restored = try run(&w, "restored-index.json", &.{});
    try testing.expectEqualStrings(initial.stdout, restored.stdout);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "restored-index.json"));
    try testing.expectEqual(@as(u64, 0), try indexCounter(&w, "restored-index.json", "canonical_fresh"));
}
