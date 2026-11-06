//! One name fence for resolution, diagnostics and generated API references.
const std = @import("std");

pub const Access = enum { worker };
const Entry = struct {
    module: []const u8,
    name: ?[]const u8,
    access: Access = .worker,
    value_only: bool = false,
};

const entries = [_]Entry{
    .{ .module = "Browser.Worker", .name = "run", .access = .worker },
    .{ .module = "Browser.WorkerRuntime", .name = "run", .access = .worker },
    .{ .module = "Task", .name = "chainDefect", .access = .worker },
};

pub fn access(module: []const u8, name: []const u8, is_value: bool) ?Access {
    for (entries) |entry| {
        if (!std.mem.eql(u8, module, entry.module) or (entry.value_only and !is_value)) continue;
        if (entry.name) |wanted| if (!std.mem.eql(u8, name, wanted)) continue;
        return entry.access;
    }
    return null;
}

pub fn workerCaller(platform: bool, module: []const u8) bool {
    return platform and (std.mem.eql(u8, module, "Browser.Worker") or std.mem.eql(u8, module, "Browser.WorkerRuntime"));
}
