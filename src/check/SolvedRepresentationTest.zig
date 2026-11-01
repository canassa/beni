//! Resident real-source publication/lifetime boundary; no mock type solutions.
const std = @import("std");
const Session = @import("../Session.zig");
const S = @import("SolvedRepresentations.zig");
test "solved representation resident error restore and demand reset discard all stale source provenance" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..len], "Main.beni" });
    defer a.free(path);
    var session = try Session.init(a, std.testing.io, .{ .jobs = 1, .diagnostics = .json, .solved_representations = true, .entry_root_requests = &.{.{ .program = "Start.Program" }} });
    defer session.deinit();
    try session.store.addPending(a, path, @intCast(len + 1), .app);
    try session.store.addEmbedded(a, "platform/Start.beni", 9, .platform, "pub type Program a = Program a\n\npub make value = Program value\n");
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const sources = [_][]const u8{
        "import Start\n\nmain = Start.make ⊤\n",
        "import Start\n\nmain : Missing\nmain = Start.make ⊤\n",
        "import Start\n\nmain = Start.make λvalue → value\n",
        "import Start\n\nmain = Start.make λvalue → value\n",
        "import Start\n\nmain = Start.make λvalue → value\n",
    };
    for (sources, 0..) |source, attempt| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Main.beni", .data = source });
        if (attempt != 0) try session.store.read(a, std.testing.io, session.store.find(path).?);
        session.options.solved_representations = attempt != 3;
        output.clearRetainingCapacity();
        const summary = try session.run(&.{}, Session.check_phases, &output.writer);
        if (summary.errors != (if (attempt == 1) @as(u32, 1) else 0)) std.debug.print("{s}\n", .{output.written()});
        try std.testing.expectEqual(@as(u32, if (attempt == 1) 1 else 0), summary.errors);
        const module = for (0..session.graph.count()) |i| {
            const m: @import("../resolve/Graph.zig").Index = @fromBackingInt(@intCast(i));
            if (std.mem.eql(u8, session.interner.slice(session.graph.moduleName(m)), "Main")) break m;
        } else return error.MissingMain;
        const inventory = &session.checked.dispatch[module.int()].solved_representations;
        try std.testing.expect(inventory.verify());
        if (attempt == 1 or attempt == 3) {
            try std.testing.expect(!inventory.present);
            try std.testing.expectEqual(@as(usize, 0), inventory.nodes.len);
            try std.testing.expectEqual(@as(usize, 0), inventory.roots.len);
            try std.testing.expectEqual(@as(usize, 0), inventory.descriptor_nodes.len);
            if (attempt == 1) try std.testing.expectEqual(@import("diagnostic").Code.unbound_type, session.diagnostics.items[0].code);
        } else {
            try std.testing.expect(inventory.present);
            const root = for (0..inventory.roots.len) |i| {
                const r = inventory.roots.get(i);
                if (r.kind == .entry) break r;
            } else return error.MissingEntryRoot;
            const node = inventory.nodes.get(@backingInt(root.node));
            try std.testing.expectEqual(S.Tag.app, node.tag);
            try std.testing.expectEqual(@as(u32, 1), node.len);
            const payload = inventory.nodes.get(@backingInt(inventory.edges.get(node.start).target));
            try std.testing.expectEqual(if (attempt == 0) S.Tag.unit else S.Tag.function, payload.tag);
        }
        // The producer is independent of the retained ownership store.
        if (session.checked.modules.len != 0) try std.testing.expectEqual(@as(u32, 0), session.checked.modules[module.int()].store.count());
        try std.testing.expect(!session.options.keep_type_stores);
    }
}
