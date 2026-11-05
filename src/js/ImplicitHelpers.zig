//! One identity/result-use registration for helpers emitted without a BIR call.
const std = @import("std");
const Intrinsic = @import("JsIntrinsic.zig");
const Operations = @import("../native/Operations.zig");

pub const Id = enum {
    append_plain,
    append_public,
    opt_none,
    opt_some,
    any_pack,
    task_waiting,
    task_chain,
    list_get,
    list_view,
    list_base,
    list_offset,
    list_close,
    list_is_view,
    list_append,
    list_slice,
    list_eq,
    list_compare,
    string_compare,
};
pub const Use = enum { constant, value, call_result };
pub const Helper = struct { module: []const u8, name: []const u8, use: Use, exported: bool = false };
const definitions = [_]Helper{
    .{ .module = "Basics", .name = "plain", .use = .call_result },
    .{ .module = "Basics", .name = "append", .use = .call_result },
    .{ .module = "Js", .name = "optNone", .use = .constant },
    .{ .module = "Js", .name = "some", .use = .call_result },
    .{ .module = "Js.Any", .name = "pack", .use = .value },
    .{ .module = "Task", .name = "isWaiting", .use = .call_result },
    .{ .module = "Task", .name = "chain", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "unsafeGet", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "view", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "base", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "offset", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "close", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "isView", .use = .call_result, .exported = true },
    .{ .module = "List", .name = "append", .use = .call_result },
    .{ .module = "List", .name = "slice", .use = .call_result },
    .{ .module = "List", .name = "eq", .use = .call_result },
    .{ .module = "List", .name = "compare", .use = .call_result },
    .{ .module = "String", .name = "compare", .use = .call_result },
};
comptime {
    std.debug.assert(definitions.len == @typeInfo(Id).@"enum".field_names.len);
}

pub fn get(id: Id) Helper {
    return definitions[@backingInt(id)];
}
pub fn observesResult(module: []const u8, name: []const u8) bool {
    for (definitions) |helper| if (helper.use != .constant and std.mem.eql(u8, module, helper.module) and std.mem.eql(u8, name, helper.name)) return true;
    return false;
}

pub fn needsExport(module: []const u8, name: []const u8) bool {
    for (definitions) |helper| if (helper.exported and std.mem.eql(u8, module, helper.module) and std.mem.eql(u8, name, helper.name)) return true;
    return false;
}

pub fn intrinsic(which: Intrinsic.Which, plain: bool) []const Id {
    return switch (which) {
        .appendTyped => &.{ .append_plain, .append_public },
        .any_unpack_opt => if (plain) &.{ .any_pack, .opt_none } else &.{ .any_pack, .opt_some, .opt_none },
        .some => if (plain) &.{.opt_none} else &.{ .opt_some, .opt_none },
        .none, .optMatch, .optWithDefault, .nodeUpgrade => &.{.opt_none},
        else => &.{},
    };
}

pub fn native(row: Operations.Row) []const Id {
    if (row.host_projection and (row.recipe == .query_selector or row.recipe == .element_query or row.recipe == .worker_create)) return &.{ .opt_none, .opt_some };
    return if (row.host_projection or Operations.rendererNeedsOpt(row.recipe)) &.{.opt_none} else &.{};
}
pub const suspension = [_]Id{ .task_waiting, .task_chain };
