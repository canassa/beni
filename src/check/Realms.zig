//! Realm facts ride the existing typed call/copy/evidence graph. No native
//! feature means no seeds, no realm column and no separate analysis pass.
const std = @import("std");
const Effects = @import("Effects.zig");
const Context = @import("Context.zig");
const TypeStore = @import("TypeStore.zig");
const Operations = @import("../native/Operations.zig");
pub fn seed(e: *Effects, cx: *const Context, schemes: []const TypeStore.Var.Optional, report: *@import("Report.zig")) Effects.Error!void {
    if (cx.graph.modulePackage(cx.module) != .core) return;
    const name = cx.interner.slice(cx.graph.moduleName(cx.module));
    if (!Operations.nativeModule(name)) return;
    for (cx.bir.decls, 0..) |decl, i| {
        if (decl.kind != .foreign_value) continue;
        const op = Operations.lookup(name, cx.interner.slice(cx.bir.symbol(decl.name))) orelse {
            report.at(@intCast(i));
            try report.emitText(.invalid_native_binding, decl.inst_start, decl.name_token, "This native callable has no reviewed adapter in the pinned native table.");
            report.at(null);
            continue;
        };
        const v = schemes[i].unwrap() orelse continue;
        if (!@import("NativeBinding.zig").valid(cx, op, v) or !std.mem.eql(u8, @tagName(decl.rung), @tagName(op.effect))) {
            report.at(@intCast(i));
            try report.emitText(.invalid_native_binding, decl.inst_start, decl.name_token, "This native binding does not match the pinned callable signature and effect metadata.");
            report.at(null);
            continue;
        }
        if (op.recipe == .timeout) e.native_callback = v;
        try e.realm_seeds.append(cx.gpa, .{ .v = v, .forbidden = Operations.all & ~op.allowed });
    }
}
