//! One name fence for resolution, diagnostics and generated API references.
const std = @import("std");

pub const Access = enum { core, task };
const Entry = struct {
    module: []const u8,
    name: ?[]const u8,
    access: Access = .core,
    value_only: bool = false,
};

const entries = [_]Entry{
    .{ .module = "Js", .name = "invoke", .value_only = true },
    .{ .module = "Js", .name = "completion", .access = .task, .value_only = true },
    .{ .module = "Js.Runtime", .name = "parked", .access = .task },
    .{ .module = "Js.Runtime", .name = null },
    .{ .module = "Task", .name = "VirtualClock" },
    .{ .module = "Task", .name = "currentClock" },
    .{ .module = "Task", .name = "withClock" },
    .{ .module = "Task", .name = "virtualClock" },
    .{ .module = "Task", .name = "adjustClock" },
    .{ .module = "Task", .name = "currentLogContext" },
    .{ .module = "Task", .name = "withLogContext" },
};

pub fn access(module: []const u8, name: []const u8, is_value: bool) ?Access {
    for (entries) |entry| {
        if (!std.mem.eql(u8, module, entry.module) or (entry.value_only and !is_value)) continue;
        if (entry.name) |wanted| if (!std.mem.eql(u8, name, wanted)) continue;
        return entry.access;
    }
    return null;
}
