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

/// The callers an access class admits, as a refusal names them: the one
/// wording map for `private_name` (Resolve) and `private_method` (dispatch).
pub fn owner(a: Access) []const u8 {
    return switch (a) {
        .worker => "the platform’s worker entry modules, `Browser.Worker` and `Browser.WorkerRuntime`",
    };
}

/// How a refused method was reached: the use as the program wrote it
/// (`x.run`, `==`), and the type whose method that use needs.
pub const Use = struct { written: []const u8, type_name: []const u8 };

/// The text of a fenced name's refusal: `private_name` without a `use`,
/// `private_method` with one. It names `module.name` and the callers the
/// class admits (`static-dispatch-spike.md` §10.2, `workers.md`).
pub fn writeRefusal(w: *std.Io.Writer, a: Access, module: []const u8, name: []const u8, use: ?Use) std.Io.Writer.Error!void {
    try w.print("`{s}.{s}` is private to {s}.\n\n", .{ module, name, owner(a) });
    if (use) |u| try w.print("{s} needs the `{s}` of `{s}`, declared in `{s}`. ", .{ u.written, name, u.type_name, module });
    try w.print("`{s}` declares it `pub`, but only those modules may use it.", .{module});
}

pub fn workerCaller(platform: bool, module: []const u8) bool {
    return platform and (std.mem.eql(u8, module, "Browser.Worker") or std.mem.eql(u8, module, "Browser.WorkerRuntime"));
}
