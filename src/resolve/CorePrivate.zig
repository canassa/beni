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
    .{ .module = "Js", .name = "Cell", .access = .runtime },
    .{ .module = "Js", .name = "cell", .access = .runtime },
    .{ .module = "Js", .name = "cellRead", .access = .runtime },
    .{ .module = "Js", .name = "cellWrite", .access = .runtime },
    .{ .module = "Js", .name = "Opt", .access = .runtime },
    .{ .module = "Js", .name = "none", .access = .runtime },
    .{ .module = "Js", .name = "some", .access = .runtime },
    .{ .module = "Js", .name = "optMatch", .access = .runtime },
    .{ .module = "Js", .name = "optWithDefault", .access = .runtime },
    .{ .module = "Node", .name = "output", .access = .platform },
    .{ .module = "Node", .name = "exitCode", .access = .platform },
    .{ .module = "Browser.Worker", .name = "run", .access = .worker },
    .{ .module = "Browser.Worker", .name = "installHostStop", .access = .worker },
    .{ .module = "Browser.WorkerRuntime", .name = "run", .access = .worker },
    .{ .module = "Browser.WorkerStream", .name = "Storage", .access = .platform },
    .{ .module = "Browser.WorkerStream", .name = "onTake", .access = .platform },
    .{ .module = "Js.Dispatch", .name = null, .access = .platform },
    .{ .module = "Cmd", .name = "Storage", .access = .platform },
    .{ .module = "Cmd", .name = "ItemStorage", .access = .platform },
    .{ .module = "Sub", .name = "Storage", .access = .platform },
    .{ .module = "Js.Host", .name = null, .access = .platform },
    .{ .module = "Js.Protocol", .name = null, .access = .platform },
    .{ .module = "Js.Data", .name = null },
    .{ .module = "Js.Inspect", .name = null, .access = .debug },
    .{ .module = "Js.Any", .name = null, .access = .platform },
    .{ .module = "Js.Key", .name = null, .access = .platform },
    .{ .module = "Js.Chain", .name = null, .access = .platform },
    .{ .module = "List", .name = "Builder" },
    .{ .module = "List", .name = "builder" },
    .{ .module = "List", .name = "done" },
    .{ .module = "List", .name = "base" },
    .{ .module = "List", .name = "offset" },
    .{ .module = "List", .name = "viewOf" },

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

/// Effective caller authority, including root core/platform authoring.
pub const Authority = enum { app, core, platform };

pub fn authority(package: anytype, core_app: bool, app_is_platform: bool) Authority {
    return switch (package) {
        .core => .core,
        .platform => .platform,
        .app => if (core_app) .core else if (app_is_platform) .platform else .app,
    };
}

/// The same name fence governs imported names and imported methods. An app
/// module with a reserved spelling never acquires a trusted module's policy.
pub fn denied(owner: Authority, module: []const u8, name: []const u8, is_value: bool, caller: Authority, caller_module: []const u8) bool {
    const required = access(module, name, is_value) orelse return false;
    return deniedAccess(required, owner, caller, caller_module);
}

/// Apply a declaration’s access class after its trusted owner is known.
pub fn deniedAccess(required: Access, owner: Authority, caller: Authority, caller_module: []const u8) bool {
    if (owner == .app) return false;
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

// The platform/debug classes have no bindings on workers yet. Test their
// policy on hypothetical declarations, without reserving production names.
test "access classes use effective caller authority and trusted owner identity" {
    const Case = struct { access: Access, owner: Authority, caller: Authority, module: []const u8 = "Local", denied: bool };
    for ([_]Case{
        .{ .access = .core, .owner = .core, .caller = .app, .denied = true },
        .{ .access = .core, .owner = .core, .caller = .core, .denied = false },
        .{ .access = .core, .owner = .platform, .caller = .app, .denied = false },
        .{ .access = .task, .owner = .core, .caller = .core, .module = "Task", .denied = false },
        .{ .access = .task, .owner = .core, .caller = .platform, .module = "Task", .denied = true },
        .{ .access = .task, .owner = .core, .caller = .app, .module = "Task", .denied = true },
        .{ .access = .task, .owner = .core, .caller = .core, .denied = true },
        .{ .access = .worker, .owner = .platform, .caller = .platform, .module = "Browser.WorkerRuntime", .denied = false },
        .{ .access = .worker, .owner = .platform, .caller = .app, .module = "Browser.WorkerRuntime", .denied = true },
        .{ .access = .worker, .owner = .platform, .caller = .core, .module = "Browser.WorkerRuntime", .denied = true },
        .{ .access = .runtime, .owner = .core, .caller = .platform, .denied = false },
        .{ .access = .runtime, .owner = .core, .caller = .app, .denied = true },
        .{ .access = .platform, .owner = .platform, .caller = .platform, .denied = false },
        .{ .access = .platform, .owner = .core, .caller = .core, .denied = false },
        .{ .access = .platform, .owner = .core, .caller = .app, .denied = true },
        .{ .access = .platform, .owner = .app, .caller = .app, .denied = false },
        .{ .access = .debug, .owner = .core, .caller = .core, .module = "Debug", .denied = false },
        .{ .access = .debug, .owner = .core, .caller = .app, .module = "Debug", .denied = true },
        .{ .access = .debug, .owner = .core, .caller = .platform, .module = "Debug", .denied = true },
        .{ .access = .debug, .owner = .core, .caller = .core, .denied = true },
    }) |c| try std.testing.expectEqual(c.denied, deniedAccess(c.access, c.owner, c.caller, c.module));
}
