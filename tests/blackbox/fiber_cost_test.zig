//! Fiber benchmark correctness and deterministic runtime cost ratchets.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

fn source(w: *World, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, w.arena.allocator(), .limited(world.max_stream_bytes));
}

test "fiber benchmark forwards resumed results through beni entries" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Bench.beni", try source(&w, "bench/fiber/Bench.beni"));
    const built = try w.run(&.{ "build", "--platform=node", "--library", "--no-source-maps", "--out=out", "Bench.beni" });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    try w.write("out/workloads.mjs", try source(&w, "bench/fiber/workloads.mjs"));
    // Only the beni workloads are under test. Comparison functions return
    // their exact expected results without adding an npm dependency to gates.
    try w.write("out/check.mjs",
        \\import * as beni from './Bench.mjs';
        \\import { all } from './workloads.mjs';
        \\const comparison = {loopFlatMap:n=>n,loopGen:n=>n,loopYielding:async n=>n,fanOut:async n=>n*(n+1)/2};
        \\await all(beni,comparison,{calls:8,sequenced:2,yields:3,fibers:3,effectCalls:1,effectYields:1});
        \\console.log('benchmark results checked');
        \\
    );
    try w.expectProgram("out/check.mjs", .{ .stdout = "benchmark results checked\n" });
}

fn costTool(w: *World, body: []const u8) !void {
    try w.write("out/cost.mjs", try source(w, "bench/fiber/cost.mjs"));
    const script = try std.mem.concat(w.arena.allocator(), u8, &.{
        "// Cost cache target: " ++ @tagName(@import("builtin").target.cpu.arch) ++ "\n",
        "import {fileURLToPath} from 'node:url';\nimport {measureCosts,checkCosts,measureBuiltSizes,checkSizes} from './cost.mjs';\nconst root=fileURLToPath(new URL('.',import.meta.url));\nconst budgets=",
        try source(w, "bench/fiber/budgets.json"),
        ";\n",
        body,
    });
    try w.write("out/check.mjs", script);
}

test "fiber retained bytes and allocation deltas stay within ratchets" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    for ([_][]const u8{ "beni.json", "Probe.beni", "Probe.js" }) |name| {
        const input = try w.arena.allocator().print("bench/fiber/cost/platform/{s}", .{name});
        const output = try w.arena.allocator().print("platform/{s}", .{name});
        try w.write(output, try source(&w, input));
    }
    for ([_][]const u8{ "Parked", "ParkedDeferred", "Completed", "SpawnJoin", "FastPath", "Yield" }) |name| {
        const input = try w.arena.allocator().print("bench/fiber/cost/{s}.beni", .{name});
        const output = try w.arena.allocator().print("{s}.beni", .{name});
        const out_arg = try w.arena.allocator().print("--out=out/{s}", .{name});
        try w.write(output, try source(&w, input));
        const built = try w.run(&.{ "build", "--release", "--no-source-maps", "--platform=platform", out_arg, output });
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    }
    try costTool(&w, "const rows=measureCosts(root);checkCosts(rows,budgets);const invalid=structuredClone(rows);invalid['fast-path'].large=NaN;const assert=await import('node:assert/strict');assert.throws(()=>checkCosts(invalid,budgets),{name:'Error',message:'fast-path: invalid numeric sample'});console.log('fiber cost ratchets checked');\n");
    try w.expectProgram("out/check.mjs", .{ .stdout = "fiber cost ratchets checked\n" });
}

test "fiber release bundle brotli sizes stay within ratchets" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    for ([_][]const u8{ "S0Plain", "S1Start", "S2SpawnJoin", "S3ScopeFinalizer", "S4Cancel", "S5Queue" }) |name| {
        const input = try w.arena.allocator().print("tests/corpus/emit/release/app/Fiber{s}.beni", .{name});
        const output = try w.arena.allocator().print("Fiber{s}.beni", .{name});
        const out_arg = try w.arena.allocator().print("--out=out/{s}", .{name});
        try w.write(output, try source(&w, input));
        const built = try w.run(&.{ "build", "--release", "--no-source-maps", "--platform=node", out_arg, output });
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
        const script = try w.arena.allocator().print("out/{s}/_main.mjs", .{name});
        const expected = if (std.mem.eql(u8, name, "S0Plain") or std.mem.eql(u8, name, "S1Start")) "hi\n" else if (std.mem.eql(u8, name, "S3ScopeFinalizer")) "43\n" else if (std.mem.eql(u8, name, "S4Cancel")) "cancelled\n" else "42\n";
        try w.expectProgram(script, .{ .stdout = expected });
    }
    try costTool(&w, "checkSizes(measureBuiltSizes(root),budgets);console.log('fiber bundle ratchets checked');\n");
    try w.expectProgram("out/check.mjs", .{ .stdout = "fiber bundle ratchets checked\n" });
}
