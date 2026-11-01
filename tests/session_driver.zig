//! External corpus driver for the existing public resident Session API.
const std = @import("std");
const beni = @import("beni");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return 2;
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer if (heap.deinit() == .leak) std.process.exit(1);
    try revisions(heap.allocator(), init.io, args[1]);
    return 0;
}

fn revisions(a: std.mem.Allocator, io: Io, fixture_dir: []const u8) !void {
    var failure: ?beni.cache.Dir.Failure = null;
    var cache = try beni.cache.Dir.open(io, "cache", &failure);
    defer cache.close();
    // The warning revision is not emitted by this API without this option.
    var session = try beni.Session.init(a, io, .{ .jobs = 1, .core_package = true, .diagnostics = .json, .informational = true, .cache = &cache });
    defer session.deinit();
    try session.store.addPending(a, "Main.beni", 0, .app);
    var rendered: Io.Writer.Allocating = .init(a);
    defer rendered.deinit();
    var output: Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const sources = [_][]const u8{ "warning.beni", "warning.beni", "error.beni", "repaired.beni" };
    for (sources, 0..) |revision, i| {
        const input_path = try std.fs.path.join(a, &.{ fixture_dir, revision });
        defer a.free(input_path);
        const source = try Io.Dir.cwd().readFileAlloc(io, input_path, a, .unlimited);
        defer a.free(source);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "Main.beni", .data = source });
        if (i != 0) try session.store.read(a, io, session.store.find("Main.beni").?);
        rendered.clearRetainingCapacity();
        _ = try session.run(&.{}, beni.Session.check_phases, &rendered.writer);
        // Embedded sources are numbered now; subsequent runs reuse those rows.
        session.options.core_package = false;
        const diagnostics = if (rendered.written().len == 0) "[]" else rendered.written();
        try output.writer.writeAll(diagnostics);
        if (!std.mem.endsWith(u8, diagnostics, "\n")) try output.writer.writeByte('\n');
    }
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout.interface.writeAll(output.written());
    try stdout.interface.flush();
}
