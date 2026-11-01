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
    const start = std.mem.indexOf(u8, text, "nominal-module ") orelse return error.MissingNominalInspector;
    const end = std.mem.indexOfPos(u8, text, start, "type-cursor schema=") orelse text.len;
    return text[start..end];
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
    const column = side + 16 + (word(bytes, side + 12) - 4) * 8;
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
    try testing.expectEqual(@as(u32, 22), word(good, side + 8));
    const column = side + 16 + (word(good, side + 12) - 4) * 8;
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
    const column = side + 16 + (word(good, side + 12) - 4) * 8;
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
        const roots_column = side + 16 + (word(bytes, side + 12) - 5) * 8;
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

const source_header = "native-realm-source schema=1 proof=source-records realmProved=false entryComplete=false\n";
const execution_header = "native-realm-execution schema=1 proof=source-execution entryComplete=false nativeLowering=false\n";
fn executionMetric(line: []const u8, key: []const u8) !u64 {
    const at = (std.mem.indexOf(u8, line, key) orelse return error.MissingExecutionMetric) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, at, ' ') orelse line.len;
    return std.fmt.parseInt(u64, line[at..end], 10);
}
/// Preserve every old byte; accept only the two explicitly versioned new
/// sections with their known row grammar and complete declared row counts.
fn beforeSource(full_text: []const u8) ![]const u8 {
    const before_roles = try @import("entry_roles.zig").before(full_text);
    const text = try @import("entry_solved.zig").before(before_roles);
    const at = std.mem.indexOf(u8, text, source_header) orelse return error.MissingRealmSource;
    try testing.expect(at == 0 or text[at - 1] == '\n');
    try testing.expect(std.mem.indexOfPos(u8, text, at + source_header.len, "native-realm-source ") == null);
    const exec_at = std.mem.indexOfPos(u8, text, at + source_header.len, execution_header) orelse return error.MissingRealmExecution;
    try testing.expect(std.mem.indexOfPos(u8, text, exec_at + execution_header.len, "native-realm-execution ") == null);
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    var modules: usize = 0;
    var source_lines = std.mem.splitScalar(u8, text[at + source_header.len .. exec_at], '\n');
    while (source_lines.next()) |line_| {
        if (line_.len == 0) continue;
        const module = std.mem.startsWith(u8, line_, "  realm-module ");
        try testing.expect(module or std.mem.startsWith(u8, line_, "  realm-scope ") or std.mem.startsWith(u8, line_, "  realm-literal ") or std.mem.startsWith(u8, line_, "  realm-call ") or std.mem.startsWith(u8, line_, "  realm-reference "));
        modules += @intFromBool(module);
    }
    try testing.expect(modules > 0);
    const prefixes = [_][]const u8{ "  realm-selection ", "  realm-consumer ", "  realm-builder ", "  realm-kernel ", "  realm-exec ", "  realm-root ", "  realm-invocation ", "  realm-native ", "  realm-native-use ", "  realm-residual " };
    var counts: [prefixes.len]u64 = @splat(0);
    var expected_exec: u64 = 0;
    var expected_roots: u64 = 0;
    var expected_calls: u64 = 0;
    var expected_native: u64 = 0;
    var expected_residual: u64 = 0;
    var source_uses: u64 = 0;
    var lines = std.mem.splitScalar(u8, text[exec_at + execution_header.len ..], '\n');
    while (lines.next()) |line_| {
        if (line_.len == 0) continue;
        const kind = for (prefixes, 0..) |prefix, i| {
            if (std.mem.startsWith(u8, line_, prefix)) break i;
        } else return error.UnknownRealmExecutionRow;
        counts[kind] += 1;
        if (kind >= 4) {
            const rest = line_[prefixes[kind].len..];
            _ = try std.fmt.parseInt(u64, rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MissingExecutionIndex], 10);
            try testing.expect(std.mem.indexOf(u8, line_, " source=") != null);
        }
        switch (kind) {
            1 => {
                expected_roots = try executionMetric(line_, "roots=");
                expected_native = try executionMetric(line_, "nativeRows=");
                source_uses = try executionMetric(line_, "sourceUses=");
            },
            2 => {
                expected_calls = try executionMetric(line_, "calls=");
                expected_residual = try executionMetric(line_, "residuals=");
            },
            3 => expected_exec = try executionMetric(line_, "nodes="),
            else => {},
        }
    }
    for (counts[0..4]) |count_| try testing.expectEqual(@as(u64, 1), count_);
    try testing.expectEqual(expected_exec, counts[4]);
    try testing.expectEqual(expected_roots, counts[5]);
    try testing.expectEqual(expected_calls, counts[6]);
    try testing.expectEqual(expected_native, counts[7]);
    try testing.expect(counts[8] <= source_uses);
    try testing.expectEqual(expected_residual, counts[9]);
    return text[0..at];
}

fn cursorSection(text: []const u8) ![]const u8 {
    const prefix = try beforeSource(text);
    return prefix[std.mem.indexOf(u8, prefix, "type-cursor schema=") orelse return error.MissingCursorInspector ..];
}
test "cross artifact cursor keeps exact nominal prefix and complete owned graph across cache jobs roundtrip relocation" {
    // PREPARE: golden captured from the real checked basic source; its old A
    // prefix was independently compared with the accepted fef Debug compiler.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const expected = try w.read("_expected.cursor");
    for ([_][]const []const u8{ &.{"--jobs=1"}, &.{"--jobs=8"}, &.{ "--cache-dir=roundtrip", "--roundtrip-interfaces", "--roundtrip-dispatch" } }, 0..) |extra, pass| {
        const trace = try std.fmt.allocPrint(w.arena.allocator(), "cursor-{d}.json", .{pass});
        const r = try run(&w, trace, extra);
        try testing.expectEqualStrings(try w.read("_expected.nominals"), try nominal(r.stdout));
        try testing.expectEqualStrings(expected, try cursorSection(r.stdout));
        const count = (try stats(&w, trace)).modules_checked;
        if (pass == 1) try testing.expectEqual(@as(u64, 0), count) else try testing.expect(count > 0);
    }
    // VERIFY SIDE EFFECTS: relocated checked artifacts keep views, never stores.
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved);
    for (try w.listFiles("cache")) |name| {
        const path = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name});
        try moved.write(path, try w.read(path));
    }
    const relocated = try run(&moved, "relocated.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(expected, try cursorSection(relocated.stdout));
    try testing.expectEqual(@as(u64, 0), (try stats(&moved, "relocated.json")).modules_checked);
    try testing.expect(!w.exists("out"));
    try testing.expect(!moved.exists("out"));
}

const CursorState = struct { kind: []const u8, remaining: u32, payload: []const u8 };
fn cursorWord(line: []const u8, key: []const u8) ![]const u8 {
    const start = (std.mem.indexOf(u8, line, key) orelse return error.MissingCursorWord) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    return line[start..end];
}
fn cursorState(w: *World, text: []const u8, name: []const u8) !CursorState {
    const marker = try std.fmt.allocPrint(w.arena.allocator(), "typed-candidate {s} decl=", .{name});
    const candidate = text[(std.mem.indexOf(u8, text, marker) orelse return error.MissingCursorCandidate) + marker.len ..];
    const declaration = try std.fmt.parseInt(u32, candidate[0 .. std.mem.indexOfScalar(u8, candidate, ' ') orelse return error.MissingCursorCandidate], 10);
    const query = try std.fmt.allocPrint(w.arena.allocator(), " decl={d} role=0 ", .{declaration});
    var lines = std.mem.splitScalar(u8, try cursorSection(text), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  cursor-query ") or std.mem.indexOf(u8, line, query) == null) continue;
        const payload = try cursorWord(line, "payload=");
        return .{ .kind = try cursorWord(line, "kind="), .remaining = try std.fmt.parseInt(u32, try cursorWord(line, "remaining="), 10), .payload = payload[(std.mem.indexOfScalar(u8, payload, ':') orelse return error.MissingCursorPayload) + 1 ..] };
    }
    return error.MissingCursorQuery;
}
fn cursorFieldHeads(w: *World, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(w.arena.allocator());
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, try cursorSection(text), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  cursor-child ") or std.mem.indexOf(u8, line, " record_field ") == null) continue;
        try out.writer.print("{s} {s} {s}\n", .{ try cursorWord(line, "selector="), try cursorWord(line, "head="), try cursorWord(line, "nominal=") });
    }
    return out.toOwnedSlice();
}
test "cross artifact cursor substitutes private phantom aliases independently and retains unavailable schema native and recursive evidence" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.copyTree("tests/fixtures/nominal-layouts/cursor", "_excluded.");
    const expected = try w.read("_expected.cursor");
    const before = try run(&w, "cursor-rich-cold.json", &.{"--jobs=1"});
    try testing.expectEqualStrings(expected, try cursorSection(before.stdout));
    try testing.expectEqualStrings("value app core:Basics.Int\nvalue app core:String.String\n", try cursorFieldHeads(&w, before.stdout));
    const complete = "complete";
    try testing.expectEqualDeep(CursorState{ .kind = complete, .remaining = 0, .payload = "adt" }, try cursorState(&w, before.stdout, "payload"));
    try testing.expectEqualDeep(CursorState{ .kind = complete, .remaining = 0, .payload = "adt" }, try cursorState(&w, before.stdout, "textPayload"));
    try testing.expectEqualDeep(CursorState{ .kind = complete, .remaining = 0, .payload = "adt" }, try cursorState(&w, before.stdout, "recursivePayload"));
    try testing.expectEqualDeep(CursorState{ .kind = "obligation", .remaining = 1, .payload = "obligation" }, try cursorState(&w, before.stdout, "genericPayload"));
    try testing.expectEqualDeep(CursorState{ .kind = complete, .remaining = 0, .payload = "native_contract_unavailable" }, try cursorState(&w, before.stdout, "nativePayload"));
    try testing.expectEqualDeep(CursorState{ .kind = complete, .remaining = 0, .payload = "schema_type_contract_unavailable" }, try cursorState(&w, before.stdout, "schemaPayload"));
    try testing.expectEqualDeep(CursorState{ .kind = complete, .remaining = 0, .payload = "schema_encoded_contract_unavailable" }, try cursorState(&w, before.stdout, "encodedPayload"));
    const warm = try run(&w, "cursor-rich-warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(before.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "cursor-rich-warm.json")).modules_checked);
    const roundtrip = try run(&w, "cursor-rich-roundtrip.json", &.{ "--cache-dir=roundtrip", "--roundtrip-interfaces", "--roundtrip-dispatch" });
    try testing.expectEqualStrings(before.stdout, roundtrip.stdout);
    try testing.expect(!w.exists("out"));
}

test "cross artifact cursor preserves current schema leaf through aliases actual wrappers and primitive field projection" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const a = w.arena.allocator();
    const source = try std.fmt.allocPrint(a,
        \\{s}
        \\
        \\pub schema Plain =
        \\    field : Int
        \\type alias Endpoint = Plain.Type
        \\type alias Again = Endpoint
        \\type alias Identity a = a
        \\type alias Container a = {{ wrapped : a }}
        \\endpoint : Again
        \\endpoint = Debug.todo "checked schema endpoint"
        \\genericEndpoint : Identity Again
        \\genericEndpoint = endpoint
        \\wrapped : Container Again
        \\wrapped = {{ wrapped = endpoint }}
        \\convertedEndpoint : Wrapped.Type
        \\convertedEndpoint = Debug.todo "checked converted schema"
        \\convertedPayload = Worker.make {{ message = convertedEndpoint }} λvalue → value
        \\aliasPayload = Worker.make {{ message = endpoint }} λvalue → value
        \\genericSchemaPayload = Worker.make {{ message = genericEndpoint }} λvalue → value
        \\wrappedSchemaPayload = Worker.make {{ message = wrapped }} λvalue → value
        \\
    , .{try w.read("Main.beni")});
    try w.write("Main.beni", source);
    const original_manifest = try w.read("platform/beni.json");
    const paths = [_][]const u8{ "[\"message\"]", "[\"message\",\"wrapped\"]", "[\"message\",\"field\"]" };
    for (paths, 0..) |path, index| {
        const at = std.mem.indexOf(u8, original_manifest, paths[0]) orelse return error.MissingWirePath;
        const manifest = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ original_manifest[0..at], path, original_manifest[at + paths[0].len ..] });
        try w.write("platform/beni.json", manifest);
        const trace = try std.fmt.allocPrint(a, "schema-path-{d}.json", .{index});
        const r = try run(&w, trace, &.{"--jobs=1"});
        const endpoint: CursorState = if (index == 2) .{ .kind = "complete", .remaining = 0, .payload = "native_contract_unavailable" } else if (index == 1) .{ .kind = "shape_mismatch", .remaining = 1, .payload = "not_nominal" } else .{ .kind = "complete", .remaining = 0, .payload = "schema_type_contract_unavailable" };
        const converted: CursorState = if (index == 2) .{ .kind = "complete", .remaining = 0, .payload = "adt" } else endpoint;
        try testing.expectEqualDeep(converted, try cursorState(&w, r.stdout, "convertedPayload"));
        try testing.expectEqualDeep(endpoint, try cursorState(&w, r.stdout, "aliasPayload"));
        try testing.expectEqualDeep(endpoint, try cursorState(&w, r.stdout, "genericSchemaPayload"));
        const wrapped: CursorState = if (index == 1) .{ .kind = "complete", .remaining = 0, .payload = "schema_type_contract_unavailable" } else if (index == 2) .{ .kind = "shape_mismatch", .remaining = 1, .payload = "not_nominal" } else .{ .kind = "complete", .remaining = 0, .payload = "not_nominal" };
        try testing.expectEqualDeep(wrapped, try cursorState(&w, r.stdout, "wrappedSchemaPayload"));
        const warm_trace = try std.fmt.allocPrint(a, "schema-path-{d}-warm.json", .{index});
        const warm = try run(&w, warm_trace, &.{"--jobs=8"});
        try testing.expectEqualStrings(r.stdout, warm.stdout);
        try testing.expectEqual(@as(u64, 0), (try stats(&w, warm_trace)).modules_checked);
    }
    try testing.expect(!w.exists("out"));
}

test "cross artifact cursor retains distinct function argument and result origins without certifying callbacks" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const a = w.arena.allocator();
    try w.write("Library.beni", try std.fmt.allocPrint(a,
        \\{s}
        \\
        \\pub functionSeed : PrivatePayload String
        \\functionSeed = PrivatePayload λ_ → 1
        \\
    , .{try w.read("Library.beni")}));
    try w.write("Main.beni", try std.fmt.allocPrint(a,
        \\{s}
        \\
        \\functionPayload = Worker.make {{ message = Library.functionSeed }} λvalue → value
        \\
    , .{try w.read("Main.beni")}));
    const r = try run(&w, "function-cold.json", &.{});
    try testing.expectEqualDeep(CursorState{ .kind = "complete", .remaining = 0, .payload = "adt" }, try cursorState(&w, r.stdout, "functionPayload"));
    var heads: std.Io.Writer.Allocating = .init(a);
    defer heads.deinit();
    var origins: std.Io.Writer.Allocating = .init(a);
    defer origins.deinit();
    var lines = std.mem.splitScalar(u8, try cursorSection(r.stdout), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  cursor-child ")) {
            const kind = if (std.mem.indexOf(u8, line, " function_result ") != null) "function_result" else if (std.mem.indexOf(u8, line, " argument ") != null) "argument" else continue;
            try heads.writer.print("{s} {s}\n", .{ kind, try cursorWord(line, "nominal=") });
        } else if (std.mem.startsWith(u8, line, "  cursor-origin ")) {
            if (std.mem.indexOf(u8, line, " function_argument ") != null) try origins.writer.writeAll("function_argument\n");
            if (std.mem.indexOf(u8, line, " function_result ") != null) try origins.writer.writeAll("function_result\n");
        }
    }
    try testing.expectEqualStrings("argument core:String.String\nfunction_result core:Basics.Int\n", heads.written());
    try testing.expectEqualStrings("function_argument\nfunction_result\n", origins.written());
    const warm = try run(&w, "function-warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(r.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), (try stats(&w, "function-warm.json")).modules_checked);
    try testing.expect(!w.exists("out"));
}
