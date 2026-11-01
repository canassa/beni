//! External corpus driver for the existing public resident Session API.
const std = @import("std");
const beni = @import("beni");
const diagnostic = @import("diagnostic");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return 2;
    const jobs = try std.fmt.parseInt(u32, args[2], 10);
    if (jobs == 0) return 2;
    var failure: ?beni.cache.Dir.Failure = null;
    var cache = try beni.cache.Dir.open(io, "cache", &failure);
    defer cache.close();
    var session = try beni.Session.init(a, io, .{
        .jobs = jobs,
        .diagnostics = .json,
        .informational = true,
        .cache = &cache,
        .self_profile = "profile.json",
    });
    defer session.deinit();
    try session.store.addPending(a, "Main.beni", 0, .app);
    var rendered: Io.Writer.Allocating = .init(a);
    defer rendered.deinit();
    var output: Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try output.writer.writeAll("[\n");
    const revisions = [_][]const u8{ "warning.beni", "warning.beni", "error.beni", "repaired.beni" };
    for (revisions, 0..) |revision, i| {
        const input_path = try std.fs.path.join(a, &.{ args[1], revision });
        const source = try Io.Dir.cwd().readFileAlloc(io, input_path, a, .unlimited);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "Main.beni", .data = source });
        if (i != 0) try session.store.read(a, io, session.store.find("Main.beni").?);
        rendered.clearRetainingCapacity();
        const before_frontend = session.profile.counter(.frontend_hits);
        const before_check = session.profile.counter(.cache_hits);
        const summary = try session.run(&.{}, beni.Session.check_phases, &rendered.writer);
        const cached = session.profile.counter(.frontend_hits) > before_frontend and session.profile.counter(.cache_hits) > before_check;
        const diagnostics = if (rendered.written().len == 0) "[]" else rendered.written();
        // Parse the production document without changing its messages/spans.
        const parsed = try std.json.parseFromSlice([]const diagnostic.Diagnostic, a, diagnostics, .{});
        defer parsed.deinit();
        if (i != 0) try output.writer.writeAll(",\n");
        try std.json.Stringify.value(.{ .run = i, .errors = summary.errors, .warnings = summary.warnings, .cached = cached, .diagnostics = parsed.value }, .{}, &output.writer);
    }
    try output.writer.writeAll("\n]\n");
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout.interface.writeAll(output.written());
    try stdout.interface.flush();
    return 0;
}
