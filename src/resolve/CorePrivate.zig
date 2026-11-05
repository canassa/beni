//! One name fence for resolution, diagnostics and generated API references.
const std = @import("std");

pub const Access = enum { core, task, worker, runtime, cloudflare, same_platform, platform, debug };
const Entry = struct {
    module: []const u8,
    name: ?[]const u8,
    access: Access = .core,
    value_only: bool = false,
};

const entries = [_]Entry{
    .{ .module = "Browser", .name = "Boot", .access = .same_platform },
    .{ .module = "Browser", .name = "runMounts", .access = .same_platform },
    .{ .module = "Browser.Bridge", .name = null, .access = .same_platform },
    .{ .module = "Inline", .name = "guarded", .access = .platform },
    .{ .module = "Inline", .name = "unchanged", .access = .platform },
    .{ .module = "Rt.Slots", .name = null, .access = .platform },
    .{ .module = "Rt.Rows", .name = null, .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "EarlyListeners", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyListeners", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyAppend", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlySize", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyKindAt", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyHandlerAt", .access = .platform },
    .{ .module = "Browser.Host.Array", .name = "rendererHas", .access = .platform },
    .{ .module = "Browser.Host.Array", .name = "rendererTruncate", .access = .platform },
    .{ .module = "Browser.Host.Array", .name = "rendererAt", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererTarget", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererDisabled", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererTag", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererKind", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererName", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererFocused", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererValue", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSetValue", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererChecked", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSetChecked", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSelected", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSetSelected", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSelectedIndex", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSetSelectedIndex", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSelectionStart", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSelectionEnd", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSelectionDirection", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSetSelectionRange", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererOptions", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererElements", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererNamed", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererControls", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererEdits", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererSetEdits", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererCurrentTarget", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererClearCurrentTarget", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererTakeEarly", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyEvent", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyTarget", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyRemember", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyValue", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlyChecked", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "rendererEarlySelectedIndex", .access = .platform },
    .{ .module = "Browser.Host.Event", .name = "EarlyCapture", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererFirstChild", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererNextSibling", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererParent", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererInsertBefore", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererAppend", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererRemove", .access = .platform },
    .{ .module = "Browser.Host.Node", .name = "rendererClone", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererFragment", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererImport", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererTemplate", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererBody", .access = .platform },
    .{ .module = "Browser.Host.Document", .name = "rendererText", .access = .platform },
    .{ .module = "Browser.Host.EventTarget", .name = "rendererFromNode", .access = .platform },
    .{ .module = "Browser.Host.EventTarget", .name = "rendererDocument", .access = .platform },
    .{ .module = "Html.Runtime", .name = null, .access = .platform },
    .{ .module = "Browser.Worker", .name = "eventsPossible", .access = .platform },
    .{ .module = "Browser.Host.Worker", .name = "closeSelf", .access = .platform },
    .{ .module = "Js", .name = "Builder" },
    .{ .module = "Js.Array", .name = null },
    .{ .module = "Js.Kernel", .name = null, .access = .task },
    .{ .module = "Browser.Host.Map", .name = null, .access = .platform },
    .{ .module = "Worker.Object", .name = "replyIds", .access = .cloudflare, .value_only = true },
    .{ .module = "Js", .name = "Cell", .access = .runtime },
    .{ .module = "Js", .name = "cell", .access = .runtime },
    .{ .module = "Js", .name = "cellRead", .access = .runtime },
    .{ .module = "Js", .name = "cellWrite", .access = .runtime },
    .{ .module = "Js", .name = "Opt", .access = .runtime },
    .{ .module = "Js", .name = "none", .access = .runtime },
    .{ .module = "Js", .name = "some", .access = .runtime },
    .{ .module = "Js", .name = "optMatch", .access = .runtime },
    .{ .module = "Js", .name = "optWithDefault", .access = .runtime },
    .{ .module = "List", .name = "isView", .access = .platform },
    .{ .module = "Worker.Object", .name = "replyIds", .access = .cloudflare, .value_only = true },
    .{ .module = "Browser.Host.Cloudflare", .name = null, .access = .platform },
    .{ .module = "Worker", .name = "fromHost", .access = .platform },
    .{ .module = "Worker", .name = "hostResponse", .access = .platform },
    .{ .module = "Worker", .name = "makeRequest", .access = .platform },
    .{ .module = "Worker", .name = "hostRequest", .access = .platform },
    .{ .module = "Worker", .name = "requestWithBody", .access = .platform },
    .{ .module = "Worker", .name = "requestBody", .access = .platform },
    .{ .module = "Worker", .name = "wrapEnv", .access = .platform },
    .{ .module = "Worker", .name = "nativeEnv", .access = .platform },
    .{ .module = "Worker", .name = "setDraining", .access = .platform },
    .{ .module = "Worker", .name = "chainNow", .access = .platform },
    .{ .module = "Worker", .name = "selfRef", .access = .platform },
    .{ .module = "Worker", .name = "refStub", .access = .platform },
    .{ .module = "Worker", .name = "refPost", .access = .platform },
    .{ .module = "Worker", .name = "printRef", .access = .platform },
    .{ .module = "Worker", .name = "settleHost", .access = .platform },
    .{ .module = "Worker.Object", .name = "hostState", .access = .platform },
    .{ .module = "WebSocket", .name = "fromNative", .access = .platform },
    .{ .module = "WebSocket", .name = "toNative", .access = .platform },
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
    .{ .module = "Js.TaskHooks", .name = null, .access = .platform },
    .{ .module = "Js.Fifo", .name = null, .access = .platform },
    .{ .module = "List", .name = "isView", .access = .platform },
    .{ .module = "List", .name = "wrapTree" },
    .{ .module = "List", .name = "treeOf" },
    .{ .module = "List", .name = "isTree" },
    .{ .module = "List", .name = "peekArray" },
    .{ .module = "List", .name = "writeArray" },
    .{ .module = "List", .name = "viewToken" },
    .{ .module = "List", .name = "Builder" },
    .{ .module = "List", .name = "builder" },
    .{ .module = "List", .name = "done" },
    .{ .module = "List", .name = "base" },
    .{ .module = "List", .name = "offset" },
    .{ .module = "List", .name = "viewOf" },

    .{ .module = "Js", .name = "invoke", .value_only = true },
    .{ .module = "Js.Runtime", .name = "parked", .access = .task },
    .{ .module = "Js.Runtime", .name = null },
    .{ .module = "Task", .name = "WaitList" },
    .{ .module = "Task", .name = "waitList" },
    .{ .module = "Task", .name = "parkIn" },
    .{ .module = "Task", .name = "wakeFirst" },
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

/// Platform identities established by the loaded chain, never a source name.
pub const PlatformIdentity = struct {
    same_layer: bool = false,
    owner_cloudflare: bool = false,
    caller_cloudflare: bool = false,
};

/// The same name fence governs imported names and imported methods. An app
/// module with a reserved spelling never acquires a trusted module's policy.
pub fn denied(owner: Authority, module: []const u8, name: []const u8, is_value: bool, caller: Authority, caller_module: []const u8, platform: PlatformIdentity) bool {
    const required = access(module, name, is_value) orelse return false;
    return deniedAccess(required, owner, caller, caller_module, platform);
}

/// Apply a declaration’s access class after its trusted owner is known.
pub fn deniedAccess(required: Access, owner: Authority, caller: Authority, caller_module: []const u8, platform: PlatformIdentity) bool {
    if (owner == .app) return false;
    return switch (required) {
        .core => owner == .core and caller != .core,
        .task => owner == .core and !(caller == .core and std.mem.eql(u8, caller_module, "Task")),
        .worker => owner == .platform and !workerCaller(caller == .platform, caller_module),
        .cloudflare => !platform.owner_cloudflare or !platform.caller_cloudflare,
        .same_platform => caller != .core and (owner != .platform or caller != .platform or !platform.same_layer),
        .runtime => owner == .core and caller == .app,
        .platform => caller == .app,
        .debug => caller != .core or !std.mem.eql(u8, caller_module, "Debug"),
    };
}

pub fn explanation(module: []const u8, name: []const u8) ?[]const u8 {
    const required = access(module, name, true) orelse return null;
    return switch (required) {
        .worker => "This name is private to the platform’s worker entry machinery.",
        .cloudflare => "This primitive is private to the Cloudflare Object runtime.",
        .same_platform => "This primitive is private to its owning platform layer.",
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
    }) |c| try std.testing.expectEqual(c.denied, deniedAccess(c.access, c.owner, c.caller, c.module, .{}));
}

test "Cloudflare privacy requires both loaded platform identities" {
    for ([_]bool{ false, true }) |owner| {
        for ([_]bool{ false, true }) |caller| {
            try std.testing.expectEqual(!(owner and caller), denied(.platform, "Worker.Object", "replyIds", true, .platform, "Worker.ObjectRuntime", .{
                .owner_cloudflare = owner,
                .caller_cloudflare = caller,
            }));
        }
    }
    // An application module with the same spelling does not acquire this fence.
    try std.testing.expect(!denied(.app, "Worker.Object", "replyIds", true, .app, "Main", .{}));
}

test "browser bridge access requires core or the same loaded platform layer" {
    const testing = std.testing;
    for ([_][]const u8{ "block", "installRoot", "installFuzz" }) |name| {
        try testing.expect(denied(.platform, "Browser.Bridge", name, true, .app, "Main", .{ .same_layer = true }));
        try testing.expect(denied(.platform, "Browser.Bridge", name, true, .platform, "Browser", .{}));
        try testing.expect(!denied(.platform, "Browser.Bridge", name, true, .platform, "Rt", .{ .same_layer = true }));
        try testing.expect(!denied(.platform, "Browser.Bridge", name, true, .core, "Probe", .{}));
    }
}
