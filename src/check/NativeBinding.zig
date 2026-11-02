//! Validate the compiler's trusted callable row against ordinary solved types.
//! Provenance is nominal: an app module with these spellings is never native.
const std = @import("std");
const Context = @import("Context.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Operations = @import("../native/Operations.zig");
const Var = TypeStore.Var;
fn named(cx: *const Context, v: Var, module: []const u8, name: []const u8) bool {
    const content = cx.store.resolvedContent(v);
    const app = switch (content) {
        .structure => |s| switch (s) {
            .app => |a| a,
            else => return false,
        },
        else => return false,
    };
    const identity = cx.types.named(app.type) orelse return false;
    return identity.package == .core and std.mem.eql(u8, cx.interner.slice(identity.module), module) and std.mem.eql(u8, cx.interner.slice(identity.name), name);
}
fn native(cx: *const Context, v: Var, name: []const u8) bool {
    var buffer: [128]u8 = undefined;
    const module = std.fmt.bufPrint(&buffer, "Browser.Host.{s}", .{name}) catch return false;
    return named(cx, v, module, name);
}
fn unit(cx: *const Context, v: Var) bool {
    return switch (cx.store.resolvedContent(v)) {
        .structure => |s| s == .unit,
        else => false,
    };
}
fn argument(cx: *const Context, v: Var, module: []const u8, name: []const u8, index: usize) ?Var {
    if (!named(cx, v, module, name)) return null;
    const args = Walk.positions(cx.store, v);
    return if (index < args.len) args[index] else null;
}
pub fn valid(cx: *const Context, row: Operations.Row, v: Var) bool {
    const f = Walk.function(cx.store, v) orelse return false;
    const a = f.params;
    const r = f.result;
    return switch (row.recipe) {
        .document => a.len == 1 and unit(cx, a[0]) and native(cx, r, "Document"),
        .query_selector => blk: {
            if (a.len != 2 or !native(cx, a[0], "Document") or !named(cx, a[1], "String", "String")) break :blk false;
            const error_type = argument(cx, r, "Result", "Result", 0) orelse break :blk false;
            const result = argument(cx, r, "Result", "Result", 1) orelse break :blk false;
            const element = argument(cx, result, "Maybe", "Maybe", 0) orelse break :blk false;
            break :blk named(cx, error_type, "Browser.Host.Document", "QueryError") and native(cx, element, "Element");
        },
        .text_content => a.len == 1 and native(cx, a[0], "Node") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |text| named(cx, text, "String", "String") else false),
        .set_text_content => a.len == 2 and native(cx, a[0], "Node") and named(cx, a[1], "String", "String") and unit(cx, r),
        .identity => a.len == 1 and native(cx, a[0], "Element") and native(cx, r, "Node"),
        .text_encoder => a.len == 1 and unit(cx, a[0]) and native(cx, r, "TextEncoder"),
        .encode => a.len == 2 and native(cx, a[0], "TextEncoder") and named(cx, a[1], "String", "String") and native(cx, r, "Uint8Array"),
        .byte_length => a.len == 1 and native(cx, a[0], "Uint8Array") and named(cx, r, "Basics", "Int"),
        .timeout => a.len == 2 and named(cx, a[1], "Basics", "Int") and named(cx, r, "Basics", "Int") and (if (Walk.function(cx.store, a[0])) |callback| callback.params.len == 1 and unit(cx, callback.params[0]) and unit(cx, callback.result) else false),
        .worker_self => a.len == 1 and unit(cx, a[0]) and native(cx, r, "WorkerGlobalScope"),
    };
}
