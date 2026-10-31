//! Private nominal evidence through the installed checker/cache/inspector boundary.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;
fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/nominal-layouts/basic", "_excluded.");
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
}
const Stats = struct {
    modules_checked: u64 = 0,
    nominal_owners: u64 = 0,
    nominal_ctors: u64 = 0,
    nominal_args: u64 = 0,
    nominal_source_nodes: u64 = 0,
    nominal_alias_bodies: u64 = 0,
    nominal_cover_headers: u64 = 0,
    nominal_cover_ctors: u64 = 0,
    nominal_cover_refs: u64 = 0,
    nominal_cover_terms: u64 = 0,
};
fn stats(w: *World, path: []const u8) !Stats {
    const data = try std.json.parseFromSlice(std.json.Value, testing.allocator, try w.read(path), .{});
    defer data.deinit();
    var out: Stats = .{};
    var seen: [@typeInfo(Stats).@"struct".field_names.len]bool = @splat(false);
    for (data.value.object.get("traceEvents").?.array.items) |e| {
        if (!std.mem.eql(u8, e.object.get("ph").?.string, "C")) continue;
        const args = e.object.get("args") orelse continue;
        inline for (@typeInfo(Stats).@"struct".field_names, 0..) |name, i| if (args.object.get(name)) |value| {
            try testing.expect(!seen[i]);
            seen[i] = true;
            @field(out, name) = @intCast(value.integer);
        };
    }
    for (seen) |yes| try testing.expect(yes);
    return out;
}
fn run(w: *World, trace: []const u8, extra: []const []const u8) !world.Result {
    const a = w.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "Library.beni" });
    try argv.appendSlice(a, extra);
    try argv.append(a, try std.fmt.allocPrint(a, "--self-profile={s}", .{trace}));
    const r = try w.run(argv.items);
    try clean(r);
    return r;
}
fn nominal(text: []const u8) ![]const u8 {
    return text[std.mem.indexOf(u8, text, "nominal-module ") orelse return error.MissingNominalInspector ..];
}
fn canonical(w: *World, trace: []const u8, extra: []const []const u8) !Stats {
    const r = try run(w, trace, extra);
    try testing.expectEqualStrings(try w.read("_expected.nominals"), try nominal(r.stdout));
    return stats(w, trace);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn setWord(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn record(bytes: []const u8) []const u8 {
    return bytes[word(bytes, 32)..][0..word(bytes, 36)];
}
fn layoutBytes(bytes: []const u8) []const u8 {
    const side = word(bytes, 40);
    const column = side + 16 + (word(bytes, side + 12) - 1) * 8;
    return bytes[side + word(bytes, column) ..][0..word(bytes, column + 4)];
}
fn layoutRecord(bytes: []const u8) []const u8 {
    return bytes[32 + word(bytes, 12) * 24 + word(bytes, 16) * 20 + word(bytes, 20) * 4 ..];
}
fn quantifiedWord(bytes: []const u8, layout: usize, owner: usize, parameter: usize) usize {
    const record_at = layout + 32 + word(bytes, layout + 12) * 24 + word(bytes, layout + 16) * 20 + word(bytes, layout + 20) * 4;
    const scheme = word(bytes, layout + 32 + owner * 24 + 8);
    const schemes = record_at + word(bytes, record_at + 16 + 3 * 8);
    const extra = record_at + word(bytes, record_at + 16 + 7 * 8);
    return extra + 4 * (word(bytes, schemes + scheme * 20) + parameter * 4);
}
fn entry(w: *World, name: []const u8) ![]const u8 {
    const r = try w.run(&.{ "check", "--cache-keys", "--platform=platform", "--cache-dir=cache", "Main.beni", "Library.beni" });
    try clean(r);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    const prefix = try std.fmt.allocPrint(w.arena.allocator(), "app:{s} ", .{name});
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        const key = line[prefix.len..];
        try testing.expectEqual(@as(usize, 32), key.len);
        return std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ key[0..2], key[2..] });
    };
    return error.MissingModuleKey;
}

test "nominal layouts retain private scopes native schema and unused constructors through warm roundtrip and relocation" {
    // PREPARE: private function payload, truly phantom numeric formal, recursive
    // parameter-changing application, schema via conversion and opaque native.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    // EXECUTE / VERIFY OUTPUT: exact flat ordinary graph; never Wire=true.
    const cold = try canonical(&w, "cold.json", &.{"--jobs=1"});
    try testing.expect(cold.nominal_owners > 0 and cold.nominal_ctors > 0 and cold.nominal_args > 0 and cold.nominal_source_nodes > 0);
    const warm = try canonical(&w, "warm.json", &.{"--jobs=8"});
    try testing.expectEqual(@as(u64, 0), warm.modules_checked);
    try testing.expectEqual(@as(u64, 0), warm.nominal_owners);
    try testing.expectEqual(@as(u64, 0), warm.nominal_source_nodes);
    try testing.expect(warm.nominal_cover_headers > 0 and warm.nominal_cover_ctors > 0 and warm.nominal_cover_refs > 0 and warm.nominal_cover_terms > 0);
    _ = try canonical(&w, "roundtrip.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch", "--roundtrip-interfaces" });
    try testing.expectEqual(@as(u64, 0), (try canonical(&w, "roundtrip-warm.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch" })).modules_checked);
    // VERIFY SIDE EFFECTS: relocated cache owns terms after the original process.
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved);
    for (try w.listFiles("cache")) |path| {
        const full = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{path});
        try moved.write(full, try w.read(full));
    }
    try testing.expectEqual(@as(u64, 0), (try canonical(&moved, "relocated.json", &.{"--jobs=8"})).modules_checked);
    try testing.expect(!moved.exists("out"));
}

test "nominal layouts refresh retained payload display names through actual ordinary interface cutoff" {
    // PREPARE: a formal rename preserves the indexed type and ordinary read digest.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const before = try run(&w, "before.json", &.{});
    const lib_key = try entry(&w, "Library");
    const main_key = try entry(&w, "Main");
    const lib_bytes = try w.read(lib_key);
    const main_bytes = try w.read(main_key);
    const source = try w.read("Library.beni");
    const changed = try std.mem.replaceOwned(u8, w.arena.allocator(), source, "PrivatePayload a\n    = PrivatePayload (a → Int)", "PrivatePayload b\n    = PrivatePayload (b → Int)");
    try w.write("Library.beni", changed);
    // EXECUTE.
    const after = try run(&w, "after.json", &.{"--jobs=8"});
    // VERIFY OUTPUT / SIDE EFFECTS: declaring layout changes, public bytes don't.
    const new_lib_key = try entry(&w, "Library");
    try testing.expectEqualStrings(record(lib_bytes), record(try w.read(new_lib_key)));
    const old_layout = layoutBytes(lib_bytes);
    const new_layout = layoutBytes(try w.read(new_lib_key));
    const old_terms = layoutRecord(old_layout);
    const new_terms = layoutRecord(new_layout);
    try testing.expectEqualSlices(u8, old_layout[0 .. old_layout.len - old_terms.len], new_layout[0 .. new_layout.len - new_terms.len]);
    // Only retained display text changes; all semantic term/scope columns agree.
    const strings = word(old_terms, 16 + 17 * 8);
    const length = word(old_terms, 16 + 17 * 8 + 4);
    try testing.expectEqualSlices(u8, old_terms[0..strings], new_terms[0..strings]);
    try testing.expectEqualSlices(u8, old_terms[strings + length ..], new_terms[strings + length ..]);
    try testing.expect(!std.mem.eql(u8, old_terms[strings..][0..length], new_terms[strings..][0..length]));
    try testing.expectEqualStrings(main_key, try entry(&w, "Main"));
    try testing.expectEqualStrings(main_bytes, try w.read(main_key));
    try testing.expectEqual(@as(u64, 1), (try stats(&w, "after.json")).modules_checked);
    try testing.expect(!std.mem.eql(u8, try nominal(before.stdout), try nominal(after.stdout)));
    const warm = try run(&w, "after-warm.json", &.{});
    try testing.expectEqualStrings(after.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "after-warm.json")).modules_checked);
}

test "nominal layouts refuse missing malformed private owners constructors scopes and native disguise before cache install" {
    // PREPARE: hostile bytes are real standalone entry files from the checker.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    _ = try canonical(&w, "valid.json", &.{});
    const path = try entry(&w, "Main");
    const good = try w.read(path);
    const side = word(good, 40);
    try testing.expectEqual(@as(u32, 18), word(good, side + 8));
    const column = side + 16 + (word(good, side + 12) - 1) * 8;
    const layout = side + word(good, column);
    try testing.expectEqualStrings("BENINOM\x00", good[layout..][0..8]);
    const ctors = layout + 32 + word(good, layout + 12) * 24;
    const arguments = ctors + word(good, layout + 16) * 20;
    // EXECUTE / VERIFY: each corruption is a source repair, followed by warm0.
    for (0..10) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, good);
        switch (mutation) {
            0 => setWord(bad, layout + 8, 0),
            1 => setWord(bad, layout + 32, std.math.maxInt(u32)),
            2 => setWord(bad, layout + 32 + 4, std.math.maxInt(u32)),
            3 => setWord(bad, ctors + 4, std.math.maxInt(u32)),
            4 => setWord(bad, arguments, std.math.maxInt(u32)),
            5 => bad[layout + 32 + 22] = 0xff,
            6 => bad[layout + 32 + 20] ^= 1,
            7 => setWord(bad, column + 4, 0),
            8 => bad[layout + 32 + 22] = 1, // ADT cannot disguise itself as native
            9 => { // an any parameter cannot weaken the declared number bound
                const at = quantifiedWord(good, layout, 0, 0);
                setWord(bad, at, word(bad, at) & ~@as(u32, 0xff));
            },
            else => unreachable,
        }
        try w.write(path, bad);
        try testing.expectEqual(@as(u64, 1), (try canonical(&w, "repair.json", &.{})).modules_checked);
        try testing.expectEqualStrings(good, try w.read(path));
        try testing.expectEqual(@as(u64, 0), (try canonical(&w, "repaired.json", &.{})).modules_checked);
    }
}

test "nominal layouts reject private kind metadata contradicting a present ordinary public fact" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    _ = try canonical(&w, "valid-key.json", &.{});
    const path = try entry(&w, "Library");
    const good = try w.read(path);
    const side = word(good, 40);
    const column = side + 16 + (word(good, side + 12) - 1) * 8;
    const layout = side + word(good, column);
    try testing.expectEqual(@as(u32, 6), word(good, layout + 12));
    // PublicKey is the fifth declaring owner; its exact public fact says dict_key.
    const at = quantifiedWord(good, layout, 4, 0);
    try testing.expectEqual(@as(u32, 3), word(good, at) & 0xff);
    const bad = try w.arena.allocator().dupe(u8, good);
    setWord(bad, at, word(bad, at) & ~@as(u32, 0xff));
    try w.write(path, bad);
    try testing.expectEqual(@as(u64, 1), (try canonical(&w, "key-repair.json", &.{})).modules_checked);
    try testing.expectEqualStrings(good, try w.read(path));
    try testing.expectEqual(@as(u64, 0), (try canonical(&w, "key-warm.json", &.{})).modules_checked);
}

test "nominal layouts publish all unused local types and warm coverage visits local headers only across many modules" {
    for ([_]usize{ 8, 32 }) |count| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try prepare(&w);
        _ = try run(&w, "base-cold.json", &.{});
        _ = try run(&w, "base-warm.json", &.{});
        const base = try stats(&w, "base-warm.json");
        const a = w.arena.allocator();
        var files: std.ArrayList([]const u8) = .empty;
        for (0..count) |i| {
            const name = try std.fmt.allocPrint(a, "M{d}.beni", .{i});
            try w.write(name, "type Hidden a = Hidden a\n\ntype Spare number phantom = Spare number\n");
            try files.append(a, name);
        }
        // None of these modules has values, entry roots or constructor uses.
        _ = try run(&w, "many-cold.json", files.items);
        const cold = try stats(&w, "many-cold.json");
        try testing.expectEqual(@as(u64, count), cold.modules_checked);
        try testing.expectEqual(@as(u64, 2 * count), cold.nominal_owners);
        try testing.expectEqual(@as(u64, 2 * count), cold.nominal_ctors);
        try testing.expectEqual(@as(u64, 2 * count), cold.nominal_args);
        try testing.expectEqual(@as(u64, 2 * count), cold.nominal_source_nodes);
        _ = try run(&w, "many-warm.json", files.items);
        const warm = try stats(&w, "many-warm.json");
        try testing.expectEqual(@as(u64, 0), warm.modules_checked);
        try testing.expectEqual(@as(u64, 0), warm.nominal_source_nodes);
        try testing.expectEqual(base.nominal_cover_headers + 2 * count, warm.nominal_cover_headers);
        try testing.expectEqual(base.nominal_cover_ctors + 2 * count, warm.nominal_cover_ctors);
        try testing.expectEqual(base.nominal_cover_refs + 2 * count, warm.nominal_cover_refs);
    }
}

test "nominal layouts retain accepted written depth and shared canonical alias scopes with linear work" {
    var alias_counts: [2]u64 = undefined;
    var source_counts: [2]u64 = undefined;
    for ([_]usize{ 8, 16 }, 0..) |count, sample| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try prepare(&w);
        const a = w.arena.allocator();
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        try source.writer.writeAll(try w.read("Main.beni"));
        try source.writer.writeAll("\n\ntype alias A0 a = a\n");
        for (1..count + 1) |i| try source.writer.print("\ntype alias A{d} a = A{d} (A{d} a)\n", .{ i, i - 1, i - 1 });
        // Canonical alias a never inherits outer number's kind or phantom index.
        try source.writer.print("\ntype AliasUse number phantom = AliasUse (A{d} number)\n", .{count});
        try source.writer.writeAll("\ntype Deep = Deep (");
        for (0..1024) |_| try source.writer.writeAll("List (");
        try source.writer.writeAll("Int");
        for (0..1024) |_| try source.writer.writeByte(')');
        try source.writer.writeAll(")\n");
        try w.write("Main.beni", source.written());
        const cold = try run(&w, "deep-cold.json", &.{ "--roundtrip-dispatch", "--roundtrip-interfaces" });
        const counters = try stats(&w, "deep-cold.json");
        alias_counts[sample] = counters.nominal_alias_bodies;
        source_counts[sample] = counters.nominal_source_nodes;
        try testing.expect(std.mem.indexOf(u8, try nominal(cold.stdout), " Deep kind=adt ") != null);
        try testing.expect(std.mem.indexOf(u8, try nominal(cold.stdout), " AliasUse kind=adt arity=2 ") != null);
        const warm = try run(&w, "deep-warm.json", &.{"--jobs=8"});
        try testing.expectEqualStrings(cold.stdout, warm.stdout);
        try testing.expectEqual(@as(u64, 0), (try stats(&w, "deep-warm.json")).modules_checked);
    }
    try testing.expectEqual(alias_counts[0] + 8, alias_counts[1]);
    try testing.expectEqual(source_counts[0] + 3 * 8, source_counts[1]);
}

test "nominal layouts publish complete empty modules and restore valid cached evidence after source error" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("Empty.beni", "pub answer = 1\n");
    const first = try run(&w, "empty-cold.json", &.{"Empty.beni"});
    try testing.expect(std.mem.indexOf(u8, try nominal(first.stdout), "nominal-module app:Empty schema=1 owners=0 ctors=0") != null);
    _ = try run(&w, "empty-warm.json", &.{"Empty.beni"});
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "empty-warm.json")).modules_checked);
    const source = try w.read("Library.beni");
    try w.write("Library.beni", "pub seed = missing\n");
    const bad = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "Library.beni", "Empty.beni" });
    try testing.expectEqual(@as(u8, 1), bad.exit_code);
    try testing.expect(std.mem.indexOf(u8, bad.stdout, "nominal-module ") == null);
    try w.write("Library.beni", source);
    const restored = try run(&w, "restored.json", &.{"Empty.beni"});
    try testing.expectEqualStrings(first.stdout, restored.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "restored.json")).modules_checked);
}

test "nominal layouts refresh scalar representation with unchanged public bytes and baseline ordinary invalidation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const before = try run(&w, "scalar-before.json", &.{});
    const old_lib = try w.read(try entry(&w, "Library"));
    const source = try w.read("Library.beni");
    try w.write("Library.beni", try std.mem.replaceOwned(u8, w.arena.allocator(), source, "UnusedScalar Int", "UnusedScalar String"));
    const after = try run(&w, "scalar-after.json", &.{});
    const new_lib = try w.read(try entry(&w, "Library"));
    try testing.expectEqualSlices(u8, record(old_lib), record(new_lib));
    try testing.expect(!std.mem.eql(u8, layoutRecord(layoutBytes(old_lib)), layoutRecord(layoutBytes(new_lib))));
    try testing.expect(!std.mem.eql(u8, try nominal(before.stdout), try nominal(after.stdout)));
    // The exact dependency compiler also checks these two modules: no invented cutoff.
    try testing.expectEqual(@as(u64, 2), (try stats(&w, "scalar-after.json")).modules_checked);
    const warm = try run(&w, "scalar-warm.json", &.{});
    try testing.expectEqualStrings(after.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "scalar-warm.json")).modules_checked);
}

fn interfaceSymbol(bytes: []const u8, index: u32) []const u8 {
    const symbols = word(bytes, 16 + 16 * 8);
    const strings = word(bytes, 16 + 17 * 8);
    const at = strings + word(bytes, symbols + index * 4);
    return bytes[at + 4 ..][0..word(bytes, at)];
}
test "nominal layouts in an actual generated pack include unused private constructors with zero selected roots" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const maker = try testing.environ.getAlloc(a, "BENI_CORE_PACK_EXE");
    if (maker.len == 0) return error.MissingCorePackTool;
    try w.write("base/beni.json", "{\"platform\":true,\"name\":\"base\"}\n");
    try w.write("base/Base.beni", "pub type Program = Program\n\ntype Hidden a = Hidden (a → Int)\n\ntype Spare number phantom = Spare number\n");
    const project = try w.projectPath();
    const base = try std.fs.path.join(a, &.{ project, "base" });
    const core = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, "core", a);
    const made = try w.runWith(&.{ core, "11111111111111111111111111111111", "nominal.pack", "base", "_platform/base", base }, .{ .exe = maker, .raw_diagnostics = true });
    try clean(made);
    const pack = try w.read("nominal.pack");
    try testing.expectEqualStrings("BENIPACK", pack[0..8]);
    var found = false;
    for (0..word(pack, 12)) |i| {
        const at = 16 + i * 28;
        if (pack[at] != 0) continue;
        const bytes = pack[word(pack, at + 20)..][0..word(pack, at + 24)];
        const layout = layoutBytes(bytes);
        try testing.expectEqualStrings("BENINOM\x00", layout[0..8]);
        if (word(layout, 12) == 0) continue;
        const iface = layoutRecord(layout);
        const refs = word(iface, 16 + 8 * 8);
        const first_ref = word(layout, 32);
        const module = interfaceSymbol(iface, word(iface, refs + first_ref * 16));
        if (!std.mem.eql(u8, module, "Base")) continue;
        try testing.expect(!found);
        found = true;
        try testing.expectEqual(@as(u32, 3), word(layout, 12));
        try testing.expectEqual(@as(u32, 3), word(layout, 16));
        // Same normal sidecar also proves there were no selected entry schemes.
        const side = word(bytes, 40);
        const roots_column = side + 16 + (word(bytes, side + 12) - 2) * 8;
        const roots = side + word(bytes, roots_column);
        try testing.expectEqualStrings("BENIENT\x00", bytes[roots..][0..8]);
        try testing.expectEqual(@as(u32, 0), word(bytes, roots + 12));
        const ctors = 32 + 3 * 24;
        const hidden_name = word(layout, ctors + 20);
        try testing.expectEqualStrings("Hidden", interfaceSymbol(iface, hidden_name));
        const spare_scheme = word(layout, 32 + 2 * 24 + 8);
        const schemes = word(iface, 16 + 3 * 8);
        try testing.expectEqual(@as(u32, 2), word(iface, schemes + spare_scheme * 20 + 4));
    }
    try testing.expect(found);
    try testing.expect(!w.exists("out"));
}

test "nominal layouts retain final via-schema parameter kinds through private source publication and warm load" {
    // PREPARE: Box.k only becomes dict_key through Pass.Type k's final conversion.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.copyTree("tests/corpus/check/good/GenericSchemaDictKey", "_excluded.");
    // Restore the selected entry Main; the additional Models module is deliberately unused.
    try w.write("Main.beni", try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/nominal-layouts/basic/Main.beni", w.arena.allocator(), .unlimited));
    const cold = try run(&w, "via-cold.json", &.{"Models.beni"});
    const start = std.mem.indexOf(u8, cold.stdout, "nominal-module app:Models ") orelse return error.MissingModels;
    const end = std.mem.indexOfPos(u8, cold.stdout, start + 1, "nominal-module ") orelse cold.stdout.len;
    const model = cold.stdout[start..end];
    try testing.expect(std.mem.indexOf(u8, model, "ctors=1") != null);
    try testing.expect(std.mem.indexOf(u8, model, "scheme 0 body=5 quantified=1\n  q 0 kind=3 equatable=false name=- constraints=0\n") != null);
    try testing.expect((try stats(&w, "via-cold.json")).nominal_owners > 0);
    const warm = try run(&w, "via-warm.json", &.{"Models.beni"});
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "via-warm.json")).modules_checked);
    const roundtrip = try run(&w, "via-roundtrip.json", &.{ "Models.beni", "--cache-dir=roundtrip", "--roundtrip-dispatch", "--roundtrip-interfaces" });
    try testing.expectEqualStrings(cold.stdout, roundtrip.stdout);
    try testing.expect(!w.exists("out"));
}

test "nominal layouts discard dependency-tainted error terms without adding internal diagnostics and restore clean cache" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("Library.beni", "pub type alias Bad = Int\n");
    try w.write("Main.beni", "import Library\nimport Start\n\ntype Hidden = Hidden Library.Bad\n\nmain : Start.Program\nmain =\n    Start.make\n        { init = λ_ value → value\n        , start = λ_ value → value\n        , handle = λ_ _ value → value\n        , stream = λ_ _ _ value → value\n        }\n");
    const first = try run(&w, "dependency-clean.json", &.{});
    const original = try w.read(try entry(&w, "Main"));
    try w.write("Library.beni", "pub type alias Bad = Missing\n");
    for ([_][]const []const u8{
        &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "Library.beni" },
        &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "Library.beni" },
        &.{ "build", "--platform=platform", "--cache-dir=cache", "--out=out", "Main.beni", "Library.beni" },
    }) |args| {
        const bad = try w.run(args);
        try testing.expectEqual(@as(u8, 1), bad.exit_code);
        try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
        try testing.expectEqual(@import("diagnostic").Code.unbound_type, bad.diagnostics[0].code);
        try testing.expectEqualStrings("Library.beni", bad.diagnostics[0].span.file);
        try testing.expect(std.mem.indexOf(u8, bad.stdout, "nominal-module ") == null);
        try testing.expect(!w.exists("out"));
    }
    try w.write("Library.beni", "pub type alias Bad = Int\n");
    const restored = try run(&w, "dependency-restored.json", &.{ "--jobs=8", "--roundtrip-dispatch" });
    try testing.expectEqualStrings(first.stdout, restored.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "dependency-restored.json")).modules_checked);
    try testing.expectEqualSlices(u8, original, try w.read(try entry(&w, "Main")));
}
