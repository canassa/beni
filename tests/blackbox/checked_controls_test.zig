//! Actual source -> generated ordinary body -> checked-control consumer.
//! No success golden is synthesized from a failing prototype.
const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/checked-controls/source", "_excluded.");
}
fn run(w: *World, extra: []const []const u8) !world.Result {
    var args: std.ArrayList([]const u8) = .empty;
    const a = w.arena.allocator();
    try args.appendSlice(a, &.{ "check", "--core", "--checked-controls", "--cache-dir=cache", "Main.beni" });
    try args.appendSlice(a, extra);
    return w.run(args.items);
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
}
fn contains(text: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, text, needle) != null);
}
fn linesWith(text: []const u8, prefix: []const u8) usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        count += 1;
    };
    return count;
}
fn positive(r: world.Result) !void {
    try clean(r);
    try contains(r.stdout, "checked-controls schema=1 supported=4 ");
    for ([_][]const u8{ "sourceRegionMapped=true", "generatedBodyTypechecked=true", "producerModelChecked=true", "actualTaskProducerProved=false", "runtimeRepresentationProved=false", "taskMigrated=false", "C=false", "launch=false", "batches=1" }) |field| try contains(r.stdout, field);
    try testing.expectEqual(@as(usize, 4), linesWith(r.stdout, "  body "));
    try testing.expectEqual(@as(usize, 10), linesWith(r.stdout, "    capture "));
    try testing.expectEqual(@as(usize, 4), linesWith(r.stdout, "  job-class "));
    try testing.expectEqual(@as(usize, 4), linesWith(r.stdout, "    dependency "));
    var jobs = std.mem.splitScalar(u8, r.stdout, '\n');
    while (jobs.next()) |line| {
        if (std.mem.startsWith(u8, line, "  job-class ")) try contains(line, "sync=true rawDeps=1 unresolvedDeps=0");
        if (std.mem.startsWith(u8, line, "    dependency ")) {
            try contains(line, "BODY.param=0 ");
            try contains(line, "factory.param=2 ");
            try contains(line, "checkedSync=true");
        }
    }
    try testing.expect(linesWith(r.stdout, "    checked-inst ") >= 14);
    try contains(r.stdout, "module GeneratedControls");
    try contains(r.stdout, "generated-ordinary-source\n");
    for (0..4) |i| {
        var name: [32]u8 = undefined;
        try contains(r.stdout, try std.fmt.bufPrint(&name, "pub rest{d} :", .{i}));
        try contains(r.stdout, try std.fmt.bufPrint(&name, "source=Main decl={d} ", .{i}));
    }
    // The two n-ary source remainders use opposite parameter order. Retained
    // parameter provenance must include both orders, not just same-typed roots.
    var parameters: std.Io.Writer.Allocating = .init(testing.allocator);
    defer parameters.deinit();
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  body ")) try parameters.writer.writeByte('|');
        if (!std.mem.startsWith(u8, line, "    capture ")) continue;
        const start = (std.mem.indexOf(u8, line, "parameter=") orelse return error.MissingCaptureParameter) + "parameter=".len;
        const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
        try parameters.writer.print("{s},", .{line[start..end]});
    }
    try testing.expectEqualStrings("|0,1,|0,1,2,|0,1,|0,2,1,", parameters.written());
}
fn rejected(r: world.Result) !void {
    try testing.expect(r.exit_code != 0);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expect(r.diagnostics.len > 0);
}
fn hasCode(r: world.Result, code: diagnostic.Code) bool {
    for (r.diagnostics) |d| if (d.code == code) return true;
    return false;
}

test "checked controls check real generic scalar and nary bodies with ordered captures" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try positive(try run(&w, &.{"--jobs=1"}));
    try testing.expect(!w.exists("out"));
}

test "checked controls preserve output across warm jobs roundtrip and relocated cache" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const cold = try run(&w, &.{"--jobs=1"});
    try positive(cold);
    for ([_][]const []const u8{ &.{"--jobs=8"}, &.{ "--cache-dir=roundtrip", "--roundtrip-interfaces", "--roundtrip-dispatch", "--jobs=1" }, &.{ "--cache-dir=roundtrip", "--jobs=8" } }) |extra| {
        const r = try run(&w, extra);
        try positive(r);
        try testing.expectEqualStrings(cold.stdout, r.stdout);
    }
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved);
    for (try w.listFiles("cache")) |name| {
        const path = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name});
        try moved.write(path, try w.read(path));
    }
    const relocated = try run(&moved, &.{"--jobs=8"});
    try positive(relocated);
    try testing.expectEqualStrings(cold.stdout, relocated.stdout);
    try testing.expect(!moved.exists("out"));
}

test "checked controls wrong output slot fails ordinary generated body typing" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const r = try run(&w, &.{"--checked-controls-tamper=wrong-slot"});
    try rejected(r);
    try testing.expect(hasCode(r, .type_mismatch));
    try contains(r.stderr, "Generated ordinary body");
    try contains(r.stderr, "mapped from this source suspension");
}

test "checked controls reject same typed operand scaffold and source inventory tampering" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    for ([_][]const u8{ "same-type-operand", "scaffold-return-slot", "drop-region", "duplicate-region" }) |kind| {
        const option = try std.fmt.allocPrint(w.arena.allocator(), "--checked-controls-tamper={s}", .{kind});
        const r = try run(&w, &.{option});
        try rejected(r);
        try contains(r.stderr, "InvalidControlProvenance");
    }
}

test "checked controls core privilege cannot survive an app role cache transition" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try positive(try run(&w, &.{}));
    const app = try w.run(&.{ "check", "--checked-controls", "--cache-dir=cache", "Main.beni" });
    try rejected(app);
    try testing.expect(hasCode(app, .misplaced_sync));
    try positive(try run(&w, &.{"--jobs=8"}));
}

test "checked controls discard source errors and restore valid cached body evidence" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const source = try w.read("Main.beni");
    const before = try run(&w, &.{});
    try positive(before);
    try w.write("Main.beni", "broken : Int\nbroken = \"wrong\"\n");
    const bad = try run(&w, &.{});
    try rejected(bad);
    try testing.expect(hasCode(bad, .type_mismatch));
    try w.write("Main.beni", source);
    const restored = try run(&w, &.{});
    try positive(restored);
    try testing.expectEqualStrings(before.stdout, restored.stdout);
}

test "checked controls ordinary packed core path reports actual incomplete ownership v2 evidence" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    // Actual CLI/default core pack, not the hermetic helper's empty core pack.
    const r = try run(&w, &.{ "--ownership=v2", "--ownership-everywhere", "--jobs=1" });
    try positive(r);
    try contains(r.stdout, "sourceOwnershipEnforced=true generatedOwnershipEnforced=true ownershipV2=true owningStorageProved=false");
    try contains(r.stdout, "ownership-v2-report source owningStorageProved=false\nmodule Main\n");
    try contains(r.stdout, "ownership-v2-report generated owningStorageProved=false\nmodule ControlBridge\n");
    try contains(r.stdout, "unchecked generic:");
    try contains(r.stdout, "unchecked job0:");
    try contains(r.stdout, "summary job0: not built: call (pessimistic)");
    const warm = try run(&w, &.{ "--ownership=v2", "--ownership-everywhere", "--jobs=8" });
    try positive(warm);
    try contains(warm.stdout, "ownership-v2-report source owningStorageProved=false");
    try contains(warm.stdout, "ownership-v2-report generated owningStorageProved=false");
    try contains(warm.stdout, "unchecked job0:");
}

test "checked controls truncated source cache is repaired without format offset assumptions" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const before = try run(&w, &.{});
    try positive(before);
    const keys = try w.run(&.{ "check", "--core", "--cache-dir=cache", "--cache-keys", "Main.beni" });
    try clean(keys);
    var lines = std.mem.splitScalar(u8, keys.stdout, '\n');
    var mutated = false;
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, ":Main ") orelse continue;
        const key = line[at + ":Main ".len ..];
        try testing.expectEqual(@as(usize, 32), key.len);
        const path = try std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ key[0..2], key[2..] });
        const bytes = try w.read(path);
        try testing.expect(bytes.len > 8);
        try w.write(path, bytes[0..8]);
        mutated = true;
    }
    try testing.expect(mutated);
    const repaired = try run(&w, &.{});
    try positive(repaired);
    try testing.expectEqualStrings(before.stdout, repaired.stdout);
}

test "checked controls empty source has no invented positive body receipt" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "pub value = 1\n");
    const r = try run(&w, &.{});
    try clean(r);
    try contains(r.stdout, "supported=0 unsupported=0 sourceRegionMapped=false generatedBodyTypechecked=false");
    try testing.expectEqual(@as(usize, 0), linesWith(r.stdout, "  body "));
}

fn mainCachePath(w: *World) ![]const u8 {
    const keys = try w.run(&.{ "check", "--core", "--cache-dir=cache", "--cache-keys", "Main.beni" });
    try clean(keys);
    var lines = std.mem.splitScalar(u8, keys.stdout, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, ":Main ") orelse continue;
        const key = line[at + ":Main ".len ..];
        try testing.expectEqual(@as(usize, 32), key.len);
        return std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ key[0..2], key[2..] });
    }
    return error.MissingMainCacheKey;
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn putWord(bytes: []u8, at: usize, value: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(value), .little);
}
const PlanLocation = struct { section_row: usize, column_row: usize, plan: usize, len: usize };
// Resolve directories by magic, never by a hardcoded column ordinal.
fn planLocation(bytes: []const u8) !PlanLocation {
    try testing.expectEqualStrings("BENICAC\x00", bytes[0..8]);
    for (0..word(bytes, 12)) |i| {
        const section = 32 + i * 8;
        const dispatch: usize = word(bytes, section);
        const len: usize = word(bytes, section + 4);
        if (len < 16 or !std.mem.eql(u8, bytes[dispatch..][0..8], "BENIDSP\x00")) continue;
        for (0..word(bytes, dispatch + 12)) |j| {
            const column = dispatch + 16 + j * 8;
            const plan = dispatch + word(bytes, column);
            const plan_len: usize = word(bytes, column + 4);
            if (plan_len < 32 or !std.mem.eql(u8, bytes[plan..][0..8], "BENICTL\x00")) continue;
            try testing.expectEqual(@as(u32, 2), word(bytes, plan + 8));
            try testing.expectEqual(dispatch + len, plan + plan_len);
            return .{ .section_row = section, .column_row = column, .plan = plan, .len = plan_len };
        }
    }
    return error.MissingControlPlan;
}

test "checked controls repair well formed cached root and absent region substitutions" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const before = try run(&w, &.{});
    try positive(before);
    const path = try mainCachePath(&w);
    const original = try w.read(path);
    const warm = try run(&w, &.{"--self-profile=warm.json"});
    try positive(warm);
    const warm_checked = try modulesChecked(&w, "warm.json");
    const p = try planLocation(original);
    const sites: usize = word(original, p.plan + 12);
    const regions: usize = word(original, p.plan + 16);
    try testing.expect(sites > 0 and regions > 0);
    const region = p.plan + 32 + sites * 8;
    const capture = region + regions * 52;
    try testing.expect(word(original, p.plan + 20) > 0);
    for (0..3) |kind| {
        var changed = try w.arena.allocator().dupe(u8, original);
        switch (kind) {
            0 => {
                // Existing term in the same ordinary scope, wrong source role.
                try testing.expect(word(original, region + 16) != word(original, region + 20));
                putWord(changed, region + 20, word(original, region + 16));
            },
            1 => {
                // Valid parameter ordinal, wrong captured definition.
                try testing.expectEqual(@as(u32, 0), word(original, capture + 8));
                putWord(changed, capture + 8, 1);
            },
            2 => {
                // Well-shaped unsupported plan, with no orphaned regions. Fix
                // the containing directories as well, preserving the cache key.
                const keep = 32 + sites * 8;
                const removed = p.len - keep;
                const shortened = try w.arena.allocator().alloc(u8, original.len - removed);
                @memcpy(shortened[0 .. p.plan + keep], original[0 .. p.plan + keep]);
                @memcpy(shortened[p.plan + keep ..], original[p.plan + p.len ..]);
                changed = shortened;
                for (0..sites) |i| putWord(changed, p.plan + 32 + i * 8 + 4, std.math.maxInt(u32));
                for ([_]usize{ 16, 20, 24 }) |offset| putWord(changed, p.plan + offset, 0);
                // Later private columns (including absent RealmSource) retain
                // valid offsets after shrinking this non-final column.
                const dispatch = word(original, p.section_row);
                for (0..word(original, dispatch + 12)) |ci| {
                    const column = dispatch + 16 + ci * 8;
                    const offset = word(original, column);
                    if (dispatch + offset >= p.plan + p.len) putWord(changed, column, offset - removed);
                }
                putWord(changed, p.column_row + 4, keep);
                putWord(changed, p.section_row + 4, word(original, p.section_row + 4) - removed);
                for (0..word(original, 12)) |i| {
                    const row = 32 + i * 8;
                    const offset = word(original, row);
                    if (offset >= p.plan + p.len) putWord(changed, row, offset - removed);
                }
            },
            else => unreachable,
        }
        try w.write(path, changed);
        const repaired = try run(&w, &.{ "--jobs=8", "--self-profile=repair.json" });
        try testing.expect(try modulesChecked(&w, "repair.json") > warm_checked);
        try positive(repaired);
        try testing.expectEqualStrings(before.stdout, repaired.stdout);
        // Output equality alone could hide use of stale source authority.
        try testing.expectEqualSlices(u8, original, try w.read(path));
    }
}

test "ordinary core cached sync source remains forbidden to application checker" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try clean(try w.run(&.{ "check", "--core", "--cache-dir=cache", "Main.beni" }));
    const app = try w.run(&.{ "check", "--cache-dir=cache", "Main.beni" });
    try rejected(app);
    try testing.expectEqual(@as(usize, 4), app.diagnostics.len);
    try testing.expectEqualStrings(try w.read("app-expected.json"), app.stderr);
}

test "standalone ownership everywhere reports visible source reuse" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/fixtures/checked-controls/ownership", "_excluded.");
    const r = try w.run(&.{ "check", "--ownership-everywhere", "OwnershipFailure.beni" });
    try rejected(r);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualStrings(try w.read("expected.json"), r.stderr);
}

fn modulesChecked(w: *World, path: []const u8) !u64 {
    const Event = struct {
        ph: []const u8,
        args: struct { modules_checked: ?u64 = null } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(path), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var result: ?u64 = null;
    for (parsed.value.traceEvents) |event| {
        if (std.mem.eql(u8, event.ph, "C")) if (event.args.modules_checked) |count| {
            result = count;
        };
    }
    return result orelse error.MissingCheckedCounter;
}

test "checked controls distinguish sync and poly sibling callback parameter paths" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/fixtures/checked-controls/callback-identity", "_excluded.");
    const source = try w.read("Main.beni");
    const poly = try run(&w, &.{});
    try clean(poly);
    try siblingParameterInventory(poly.stdout);
    try testing.expectEqual(@as(usize, 1), linesWith(poly.stdout, "  source-scope "));
    try testing.expectEqual(@as(usize, 2), linesWith(poly.stdout, "    source-callback "));
    try contains(poly.stdout, "BODY.param=0 class=1 sync=true");
    try contains(poly.stdout, "BODY.param=1 class=2 sync=false");
    try contains(poly.stdout, "state=uncertified reason=callback_contract");
    try contains(poly.stdout, "module Main\nscheme 0");
    try contains(poly.stdout, "supported=0 unsupported=");
    try testing.expect(std.mem.indexOf(u8, poly.stdout, "unsupported=0 ") == null);
    try contains(poly.stdout, "sourceRegionMapped=false generatedBodyTypechecked=false");
    try testing.expectEqual(@as(usize, 0), linesWith(poly.stdout, "  body "));
    try testing.expectEqual(@as(usize, 0), linesWith(poly.stdout, "  job-class "));
    // Keep BOTH callback declarations and their equal ordinary signatures.
    // Changing only the selected lexical parameter must expose a supported
    // region, proving this negative was not a blanket unsupported-shape result.
    const selected = try std.mem.replaceOwned(u8, w.arena.allocator(), source, "    poly value", "    synchronous value");
    try w.write("Main.beni", selected);
    const sync = try run(&w, &.{});
    try clean(sync);
    try siblingParameterInventory(sync.stdout);
    try testing.expectEqual(@as(usize, 1), linesWith(sync.stdout, "  source-scope "));
    try contains(sync.stdout, "BODY.param=0 class=1 sync=true");
    try contains(sync.stdout, "state=body-checked reason=supported");
    try contains(sync.stdout, "supported=1 unsupported=");
    try contains(sync.stdout, "sourceRegionMapped=true generatedBodyTypechecked=true");
    try testing.expectEqual(@as(usize, 1), linesWith(sync.stdout, "  body "));
    try testing.expectEqual(@as(usize, 2), linesWith(sync.stdout, "    capture "));
    try contains(sync.stdout, "parameter=0 ");
    try contains(sync.stdout, "parameter=2 ");
    try testing.expect(std.mem.indexOf(u8, sync.stdout, "parameter=1 ") == null);
    // Restore the poly selection into the already populated cache as well.
    try w.write("Main.beni", source);
    const restored = try run(&w, &.{"--jobs=8"});
    try clean(restored);
    try testing.expectEqualStrings(poly.stdout, restored.stdout);
}

test "checked controls source warning and generated error form one diagnostic document" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.copyTree("tests/fixtures/checked-controls/warning", "_excluded.");
    // Keep the warning in the reached source module, outside all admitted
    // remainders; an unimported fixture would not exercise source diagnostics.
    const source = try w.read("Main.beni");
    try w.write("Main.beni", try std.fmt.allocPrint(w.arena.allocator(), "{s}\n{s}", .{ source, try w.read("Warning.beni") }));
    const r = try run(&w, &.{"--checked-controls-tamper=wrong-slot"});
    try rejected(r);
    try testing.expect(hasCode(r, .unit_discarded));
    try testing.expect(hasCode(r, .type_mismatch));
    try testing.expect(hasCode(r, .internal));
    var warnings: usize = 0;
    for (r.diagnostics) |d| if (d.code == .unit_discarded) {
        try testing.expectEqual(diagnostic.Severity.warning, d.severity);
        warnings += 1;
    };
    try testing.expectEqual(@as(usize, 1), warnings);
    try testing.expectEqualStrings(try w.read("wrong-slot-expected.json"), r.stderr);
    const success = try run(&w, &.{});
    try testing.expectEqual(@as(u8, 0), success.exit_code);
    try testing.expectEqual(@as(usize, 1), success.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.unit_discarded, success.diagnostics[0].code);
    try testing.expectEqual(diagnostic.Severity.warning, success.diagnostics[0].severity);
    try contains(success.stdout, "supported=4 unsupported=2 sourceRegionMapped=true generatedBodyTypechecked=true");
    try testing.expectEqual(@as(usize, 4), linesWith(success.stdout, "  body "));
}

test "checked controls generated suspending job fails ordinary sync checking" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const r = try run(&w, &.{"--checked-controls-tamper=suspending-job"});
    try rejected(r);
    try testing.expect(hasCode(r, .sync_boundary));
    try testing.expect(hasCode(r, .internal));
    try contains(r.stderr, "Generated ordinary body");
    try testing.expectEqualStrings(try w.read("suspending-job-expected.json"), r.stderr);
}

fn siblingParameterInventory(output: []const u8) !void {
    try testing.expectEqual(@as(usize, 6), linesWith(output, "    source-parameter "));
    // OWNER/BODY both retain all declared parameters. A direct function term
    // is not a sync certificate: only separately published effect paths are.
    for ([_][]const u8{ "OWNER.param=0 ", "OWNER.param=1 ", "BODY.param=0 ", "BODY.param=1 " }) |selector| {
        var lines = std.mem.splitScalar(u8, output, '\n');
        var matched: usize = 0;
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "    source-parameter ") or std.mem.indexOf(u8, line, selector) == null) continue;
            try contains(line, "directFunction=true effectAuthority=published-paths");
            matched += 1;
        }
        try testing.expectEqual(@as(usize, 1), matched);
    }
}

test "checked controls publish no receipt when a late platform runtime contract fails" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/fixtures/checked-controls/late-platform", "_excluded.");
    const r = try w.run(&.{ "check", "--checked-controls", "--platform=platform", "Main.beni" });
    try rejected(r);
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .invalid_entry_kind,
        .severity = .@"error",
        .span = .{ .file = "platform/Rt.beni", .start = .{ .line = 2, .col = 1 }, .end = .{ .line = 2, .col = 4 } },
        .title = "INVALID ENTRY KIND",
        .message = "`Rt.run` must take exactly one `Start.Program` and return `⊤`, with no evidence\nparameters or specialized type arguments.",
    }, r.diagnostics[0]);
}

test "checked controls unsupported fault produces one structured failure without a receipt" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/fixtures/checked-controls/no-supported", "_excluded.");
    const r = try run(&w, &.{"--checked-controls-tamper=wrong-slot"});
    try rejected(r);
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Severity.@"error", r.diagnostics[0].severity);
    try contains(r.diagnostics[0].message, "UnsupportedTamper");
    try testing.expectEqualStrings(try w.read("expected.json"), r.stderr);
}

test "checked controls optional inner profile records actual ordinary generated batch" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const plain = try run(&w, &.{});
    try positive(plain);
    try testing.expect(!w.exists("trace.json"));
    try testing.expect(!w.exists("trace.json.checked-controls.json"));
    const profiled = try run(&w, &.{"--self-profile=trace.json"});
    try positive(profiled);
    try testing.expectEqualStrings(plain.stdout, profiled.stdout);
    const inner = try readInnerProfile(&w, "trace.json.checked-controls.json");
    try testing.expect(inner.embedded > 0);
    try testing.expectEqual(inner.modules, inner.embedded + inner.checked + inner.hits);
    try testing.expectEqual(inner.checked, inner.check_events);
    try testing.expectEqual(inner.checked, inner.body_events + inner.bridge_events);
    try testing.expectEqual(@as(u64, 1), inner.body_events);
    try testing.expectEqual(@as(u64, 1), inner.bridge_events);
    // The source trace must remain separate and contain no generated checks.
    const outer = try readInnerProfile(&w, "trace.json");
    try testing.expectEqual(@as(u64, 0), outer.body_events + outer.bridge_events);
}

test "checked controls unsupported only profile does not create or replace an inner sidecar" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/fixtures/checked-controls/callback-identity", "_excluded.");
    const plain = try run(&w, &.{});
    try clean(plain);
    try contains(plain.stdout, "supported=0 unsupported=2");
    const fresh = try run(&w, &.{"--self-profile=fresh.json"});
    try clean(fresh);
    try testing.expectEqualStrings(plain.stdout, fresh.stdout);
    try testing.expect(w.exists("fresh.json"));
    try testing.expect(!w.exists("fresh.json.checked-controls.json"));
    try w.write("reused.json.checked-controls.json", "older invocation marker\n");
    const reused = try run(&w, &.{"--self-profile=reused.json"});
    try clean(reused);
    try testing.expectEqualStrings(plain.stdout, reused.stdout);
    try testing.expectEqualStrings("older invocation marker\n", try w.read("reused.json.checked-controls.json"));
}

test "checked controls inner profile I O failure prevents a positive receipt" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    // Outer destination is valid, but the derived destination is a directory.
    try w.write("blocked.json.checked-controls.json/marker", "keep\n");
    const r = try run(&w, &.{"--self-profile=blocked.json"});
    try rejected(r);
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.internal, r.diagnostics[0].code);
    try contains(r.diagnostics[0].message, "InputPath");
    try testing.expect(w.exists("blocked.json"));
    try testing.expectEqualStrings("keep\n", try w.read("blocked.json.checked-controls.json/marker"));
}

const InnerProfile = struct {
    modules: u64,
    embedded: u64,
    checked: u64,
    hits: u64,
    check_events: u64 = 0,
    body_events: u64 = 0,
    bridge_events: u64 = 0,
};
fn readInnerProfile(w: *World, path: []const u8) !InnerProfile {
    const Event = struct {
        ph: []const u8,
        name: []const u8 = "",
        args: struct {
            file: ?[]const u8 = null,
            modules: ?u64 = null,
            embedded_modules: ?u64 = null,
            modules_checked: ?u64 = null,
            cache_hits: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(path), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var result: InnerProfile = .{ .modules = 0, .embedded = 0, .checked = 0, .hits = 0 };
    var fields: u8 = 0;
    for (parsed.value.traceEvents) |event| {
        if (std.mem.eql(u8, event.ph, "C")) {
            if (event.args.modules) |n| {
                result.modules = n;
                fields |= 1;
            }
            if (event.args.embedded_modules) |n| {
                result.embedded = n;
                fields |= 2;
            }
            if (event.args.modules_checked) |n| {
                result.checked = n;
                fields |= 4;
            }
            if (event.args.cache_hits) |n| {
                result.hits = n;
                fields |= 8;
            }
        }
        if (!std.mem.eql(u8, event.ph, "X") or !std.mem.eql(u8, event.name, "check")) continue;
        result.check_events += 1;
        const file = std.fs.path.basename(event.args.file orelse return error.MissingCheckedFile);
        if (std.mem.eql(u8, file, "GeneratedControls.beni")) result.body_events += 1;
        if (std.mem.eql(u8, file, "ControlBridge.beni")) result.bridge_events += 1;
    }
    try testing.expectEqual(@as(u8, 15), fields);
    return result;
}

fn runtimeOwnershipFault(mode: []const u8, expected: []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const r = try run(&w, &.{ mode, "--checked-controls-tamper=ownership-conflict" });
    try rejected(r);
    try testing.expect(hasCode(r, .list_still_used));
    // Captured from the actual ordinary generated checker, not a provenance
    // substitute; the canonical producer fault must reach checkRuntime first.
    try testing.expectEqualStrings(try w.read(expected), r.stderr);
}
test "checked controls validated runtime own1 rejects actual ownership conflict before receipt" {
    try runtimeOwnershipFault("--ownership=v1", "ownership-conflict-v1-expected.json");
}
test "checked controls validated runtime own2 rejects actual ownership conflict before receipt" {
    try runtimeOwnershipFault("--ownership=v2", "ownership-conflict-v2-expected.json");
}

fn prepareBoundResult(w: *World) !void {
    try w.copyTree("tests/fixtures/checked-controls/bound-result", "_excluded.");
}
fn boundResultPositive(r: world.Result) !void {
    try clean(r);
    try contains(r.stdout, "checked-controls schema=1 supported=1 unsupported=0 ");
    for ([_][]const u8{ "sourceRegionMapped=true", "generatedBodyTypechecked=true", "actualTaskProducerProved=false", "runtimeRepresentationProved=false", "owningStorageProved=false", "taskMigrated=false", "C=false", "launch=false", "batches=1" }) |field| try contains(r.stdout, field);
    try testing.expectEqual(@as(usize, 1), linesWith(r.stdout, "  body "));
    try testing.expectEqual(@as(usize, 2), linesWith(r.stdout, "    capture "));
    try contains(r.stdout, "resumed-input local=3 definition=13 scope=0 type=18 output=16 binding=bound_int");
    try contains(r.stdout, "capture 0 local=0 definition=10 scope=0 parameter=0 type=12");
    try contains(r.stdout, "capture 1 local=2 definition=12 scope=0 parameter=2 type=15");
    try contains(r.stdout, "BODY.param=0 sourceClass=1 -> factory.param=2");
}
test "checked controls map a real bound join Int result separately from captures" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepareBoundResult(&w);
    const cold = try run(&w, &.{ "--jobs=1", "--self-profile=bound-cold.json" });
    try boundResultPositive(cold);
    const warm = try run(&w, &.{ "--jobs=8", "--roundtrip-interfaces", "--roundtrip-dispatch", "--self-profile=bound-warm.json" });
    try boundResultPositive(warm);
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), try modulesChecked(&w, "bound-warm.json"));
    try testing.expect((try modulesChecked(&w, "bound-cold.json")) > 0);
}

fn boundCacheMutation(offset: usize, replacement: u32) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepareBoundResult(&w);
    try boundResultPositive(try run(&w, &.{}));
    const path = try mainCachePath(&w);
    const original = try w.read(path);
    const p = try planLocation(original);
    try testing.expectEqual(@as(u32, 1), word(original, p.plan + 16));
    const region = p.plan + 32 + @as(usize, word(original, p.plan + 12)) * 8;
    try testing.expectEqual(@as(u32, 1), word(original, region + 40));
    try testing.expectEqual(@as(u32, 3), word(original, region + 44));
    try testing.expectEqual(@as(u32, 13), word(original, region + 48));
    const mutation = .{ .offset = offset, .replacement = replacement };
    {
        const changed = try w.arena.allocator().dupe(u8, original);
        const at = region + mutation.offset;
        putWord(changed, at, mutation.replacement);
        try testing.expectEqualSlices(u8, original[0..at], changed[0..at]);
        try testing.expectEqualSlices(u8, original[at + 4 ..], changed[at + 4 ..]);
        try w.write(path, changed);
        try boundResultPositive(try run(&w, &.{"--self-profile=bound-repair.json"}));
        try testing.expectEqual(@as(u64, 1), try modulesChecked(&w, "bound-repair.json"));
        try testing.expectEqualSlices(u8, original, try w.read(path));
    }
    try boundResultPositive(try run(&w, &.{"--self-profile=bound-restored.json"}));
    try testing.expectEqual(@as(u64, 0), try modulesChecked(&w, "bound-restored.json"));
}

test "checked controls bound input and output slot faults fail ordinary typing and job sync" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepareBoundResult(&w);
    for ([_][]const u8{ "wrong-input-slot", "wrong-slot", "suspending-job" }) |kind| {
        const option = try std.fmt.allocPrint(w.arena.allocator(), "--checked-controls-tamper={s}", .{kind});
        const r = try run(&w, &.{option});
        try rejected(r);
        const expected = try std.fmt.allocPrint(w.arena.allocator(), "{s}-expected.json", .{kind});
        try testing.expectEqualStrings(try w.read(expected), r.stderr);
    }
}
test "checked controls distinguish resumed input from equal typed captures on every branch" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepareBoundResult(&w);
    for ([_][]const u8{ "same-type-operand", "direct-input", "parked-input" }) |kind| {
        const option = try std.fmt.allocPrint(w.arena.allocator(), "--checked-controls-tamper={s}", .{kind});
        const r = try run(&w, &.{option});
        try rejected(r);
        try testing.expect(!hasCode(r, .type_mismatch));
        try contains(r.stderr, "InvalidControlProvenance");
        const expected = try std.fmt.allocPrint(w.arena.allocator(), "{s}-expected.json", .{kind});
        try testing.expectEqualStrings(try w.read(expected), r.stderr);
    }
}

test "checked controls repair a bound input local substitution" {
    try boundCacheMutation(44, 2);
}
test "checked controls repair a bound input definition substitution" {
    try boundCacheMutation(48, 12);
}
test "checked controls repair a bound input type role substitution" {
    try boundCacheMutation(16, 15);
}

fn boundOwnershipConflict(mode: []const u8, expected: []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepareBoundResult(&w);
    const r = try run(&w, &.{ mode, "--checked-controls-tamper=ownership-conflict" });
    try rejected(r);
    try testing.expect(hasCode(r, .list_still_used));
    try testing.expectEqualStrings(try w.read(expected), r.stderr);
}
test "checked controls bound input model preserves ordinary v1 ownership refusal" {
    try boundOwnershipConflict("--ownership=v1", "ownership-conflict-v1-expected.json");
}
test "checked controls bound input model preserves ordinary v2 ownership refusal" {
    try boundOwnershipConflict("--ownership=v2", "ownership-conflict-v2-expected.json");
}
test "checked controls bound input model exposes actual unavailable v2 coverage" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepareBoundResult(&w);
    const r = try run(&w, &.{"--ownership=v2"});
    try boundResultPositive(r);
    try contains(r.stdout, "ownership-v2-report source owningStorageProved=false");
    try contains(r.stdout, "ownership-v2-report generated owningStorageProved=false");
    for ([_][]const u8{ "unchecked joined:", "unchecked rest0:", "unchecked job0:", "unchecked control0:" }) |name| try contains(r.stdout, name);
}
test "checked controls bound poly callback and generic input remain explicitly uncertified" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/fixtures/checked-controls/bound-unsupported", "_excluded.");
    const r = try run(&w, &.{});
    try clean(r);
    try contains(r.stdout, "supported=0 unsupported=3 sourceRegionMapped=false generatedBodyTypechecked=false");
    try testing.expectEqual(@as(usize, 0), linesWith(r.stdout, "  body "));
    try contains(r.stdout, "inst=16 type=18 own=yes body=no state=uncertified reason=callback_contract");
    try contains(r.stdout, "inst=35 type=21 own=yes body=no state=uncertified reason=source_shape");
}
test "checked controls batch bound and discarded inputs in the same actual generated session" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const original = try w.read("Main.beni");
    const bound = try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/fixtures/checked-controls/bound-result/Main.beni", w.arena.allocator(), .limited(65536));
    const start = std.mem.indexOf(u8, bound, "pub joined") orelse return error.MissingJoinedFixture;
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ original, "\n\n", bound[start..] }));
    const r = try run(&w, &.{});
    try clean(r);
    try contains(r.stdout, "supported=5 ");
    try contains(r.stdout, "batches=1");
    try testing.expectEqual(@as(usize, 5), linesWith(r.stdout, "  body "));
    try testing.expectEqual(@as(usize, 1), linesWith(r.stdout, "    resumed-input "));
    try testing.expectEqual(@as(usize, 12), linesWith(r.stdout, "    capture "));
}
