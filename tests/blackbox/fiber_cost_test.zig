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
    try w.write("out/check.mjs", try source(&w, "tests/blackbox/fiber_entries.mjs"));
    try w.expectProgram("out/check.mjs", .{ .stdout = "all 18 benchmark entries checked\n" });
}

fn costTool(w: *World, body: []const u8) !void {
    try w.write("out/cost.mjs", try source(w, "bench/fiber/cost.mjs"));
    const script = try std.mem.concat(w.arena.allocator(), u8, &.{
        "import * as cost from './cost.mjs';\nimport {fileURLToPath} from 'node:url';\nimport {measureCosts,checkCosts,measureBuiltSizes,checkSizes} from './cost.mjs';\nconst root=fileURLToPath(new URL('.',import.meta.url));\nconst budgets=",
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
    try costTool(&w,
        \\const rows=measureCosts(root);
        \\checkCosts(rows,budgets);
        \\const invalid=structuredClone(rows);
        \\invalid['fast-path'].large=NaN;
        \\const assert=await import('node:assert/strict');
        \\assert.throws(()=>checkCosts(invalid,budgets),{name:'Error',message:'Fiber budget failures:\nfast-path: invalid numeric sample\n'+cost.budgetAdvice});
        \\console.log('fiber cost ratchets checked');
        \\
    );
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

test "fiber budget reports include every failure slack and targets" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try costTool(&w,
        \\const assert=await import('node:assert/strict');
        \\const limits={node:process.version,retained:{parked:{counts:[1,3],deltaBytes:10},completed:{counts:[1,3],deltaBytes:20}},allocated:{'fast-path':{counts:[1,3],deltaBytes:0}},brotli:{S0Plain:100,S1Start:200},targets:{'fast-path':0}};
        \\const rows={parked:{metric:'retained',counts:[1,3],small:100,large:112},completed:{metric:'retained',counts:[1,3],small:100,large:125},'fast-path':{metric:'allocated',counts:[1,3],small:0,large:8}};
        \\const sizes=[{fiber:'S0Plain',raw:1000,brotli:105},{fiber:'S1Start',raw:2000,brotli:207}];
        \\const advice="Review bench/fiber/budgets.json; do not raise caps to hide a regression.\nMeasure: node bench/fiber/cost.mjs ./zig-out/bin/beni zig-out/fiber-cost\nRe-record verified hashes: zig build test-run-hashes -Dtest-filter='fiber '";
        \\const costErrors='parked: delta 12 bytes, budget 10 (2 over)\ncompleted: delta 25 bytes, budget 20 (5 over)\nfast-path: delta 8 bytes, budget 0 (8 over)';
        \\const sizeErrors='S0Plain: 105 brotli bytes, budget 100 (5 over); raw 1000\nS1Start: 207 brotli bytes, budget 200 (7 over); raw 2000';
        \\assert.throws(()=>checkCosts(rows,limits),{name:'Error',message:'Fiber budget failures:\n'+costErrors+'\n'+advice});
        \\assert.equal(cost.budgetAdvice,advice);
        \\assert.throws(()=>checkSizes(sizes,limits),{name:'Error',message:'Fiber budget failures:\n'+sizeErrors+'\n'+advice});
        \\assert.throws(()=>cost.checkBudgets(rows,sizes,limits),{name:'Error',message:'Fiber budget failures:\n'+costErrors+'\n'+sizeErrors+'\n'+advice});
        \\const under=structuredClone(rows);under.parked.large=108;under.completed.large=116;under['fast-path'].large=4;
        \\assert.deepEqual(cost.costSlack(under,limits),[{case:'parked',bytesPerUnit:4,slackDeltaBytes:2,slackBytesPerUnit:1},{case:'completed',bytesPerUnit:8,slackDeltaBytes:4,slackBytesPerUnit:2},{case:'fast-path',bytesPerUnit:2,slackDeltaBytes:-4,slackBytesPerUnit:-2,targetBytesPerUnit:0,distanceToTargetBytesPerUnit:2}]);
        \\limits.targets['fast-path']=1;
        \\assert.equal(cost.costSlack(under,limits)[2].distanceToTargetBytesPerUnit,1);
        \\const smaller=[{fiber:'S0Plain',raw:1000,brotli:90},{fiber:'S1Start',raw:2000,brotli:200}];
        \\assert.deepEqual(cost.sizeSlack(smaller,limits),[{case:'S0Plain',brotliBytes:90,slackBytes:10},{case:'S1Start',brotliBytes:200,slackBytes:0}]);
        \\assert.equal(cost.formatSlack(under,smaller,limits),'parked: slack 2 bytes (1.000 bytes/unit); review tightening budgets.json\ncompleted: slack 4 bytes (2.000 bytes/unit); review tightening budgets.json\nfast-path: slack -4 bytes (-2.000 bytes/unit); target 1 bytes/unit, distance 1.000 bytes/unit\nS0Plain: slack 10 brotli bytes; review tightening budgets.json\nS1Start: slack 0 brotli bytes\n');
        \\console.log('all budget reports checked');
        \\
    );
    try w.expectProgram("out/check.mjs", .{ .stdout = "all budget reports checked\n" });
}
