//! One name fence for resolution, diagnostics and generated API references.
const std = @import("std");

pub const Access = enum { core, task, worker, runtime, platform, debug };
const Entry = struct {
    module: []const u8,
    name: ?[]const u8,
    access: Access = .core,
    value_only: bool = false,
};

const entries = [_]Entry{
    .{ .module = "Browser.Host.Cloudflare", .name = null, .access = .platform },
    .{ .module = "WebSocket", .name = "toNative", .access = .platform },
    .{ .module = "Js.Protocol", .name = null, .access = .platform },
    .{ .module = "Js.Inspect", .name = null, .access = .debug },
    .{ .module = "Js", .name = "Cell", .access = .runtime },
    .{ .module = "Js", .name = "cell", .access = .runtime },
    .{ .module = "Js", .name = "cellRead", .access = .runtime },
    .{ .module = "Js", .name = "cellWrite", .access = .runtime },
    .{ .module = "Js", .name = "Opt", .access = .runtime },
    .{ .module = "Js", .name = "none", .access = .runtime },
    .{ .module = "Js", .name = "some", .access = .runtime },
    .{ .module = "Js", .name = "optMatch", .access = .runtime },
    .{ .module = "Js", .name = "optWithDefault", .access = .runtime },
    .{ .module = "Browser.Worker", .name = "run", .access = .worker },
    .{ .module = "Browser.Worker", .name = "installHostStop", .access = .worker },
    .{ .module = "Browser.WorkerRuntime", .name = "run", .access = .worker },
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

pub fn workerCaller(platform: bool, module: []const u8) bool {
    return platform and (std.mem.eql(u8, module, "Browser.Worker") or std.mem.eql(u8, module, "Browser.WorkerRuntime"));
}

/// Effective caller authority; --core authorizes the root app package too.
pub const Authority = enum { app, core, platform };

pub fn authority(package: anytype, core_app: bool) Authority {
    return switch (package) {
        .core => .core,
        .platform => .platform,
        .app => if (core_app) .core else .app,
    };
}

/// The same name fence governs imported names and imported methods. An app
/// module with a reserved spelling never acquires a trusted module's policy.
pub fn denied(owner: Authority, module: []const u8, name: []const u8, is_value: bool, caller: Authority, caller_module: []const u8) bool {
    if (owner == .app) return false;
    const required = access(module, name, is_value) orelse return false;
    return switch (required) {
        .core => owner == .core and caller != .core,
        .task => owner == .core and !(caller == .core and std.mem.eql(u8, caller_module, "Task")),
        .worker => owner == .platform and !workerCaller(caller == .platform, caller_module),
        .runtime => owner == .core and caller == .app,
        .platform => caller == .app,
        .debug => caller != .core or !std.mem.eql(u8, caller_module, "Debug"),
    };
}

pub fn explanation(module: []const u8, name: []const u8) ?[]const u8 {
    const required = access(module, name, true) orelse return null;
    return switch (required) {
        .worker => "This name is private to the platform’s worker entry machinery.",
        .runtime, .platform => "This name is private to core and platform runtimes.",
        .debug => "This name is private to core's Debug module.",
        .core, .task => if (std.mem.eql(u8, module, "Js"))
            "This primitive is private to core's typed fiber protocol. Platforms use `Task.callback` and `Task.resume`."
        else
            "This name is private to core runtime modules.",
    };
}
