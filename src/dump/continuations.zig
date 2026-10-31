//! Hidden symbolic-plan inspection, independent of retained checker stores.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Plan = @import("../check/ContinuationPlan.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Types = @import("../check/Types.zig");
const interface = @import("interface.zig");

pub fn write(w: *std.Io.Writer, module_name: []const u8, bir: *const Bir, table: *const Dispatch, types: *const Types, interner: *const InternPool.Global) interface.Error!void {
    const plan = &table.continuations;
    try w.print("continuations {s} schema={d} partial=true present={}\n", .{ module_name, Plan.schema_version, plan.present });
    try w.print("declaration-heads {s} rows={d}\n", .{ module_name, table.decl_heads.len });
    for (table.decl_heads, 0..) |head, i| {
        try w.print("  head {s} ", .{interner.slice(bir.symbol(bir.decls[i].name))});
        if (head == .none) {
            try w.writeAll("none\n");
        } else {
            const named = types.entries[head.int()];
            try w.print("{t}:{s}.{s}\n", .{ named.package, interner.slice(named.module_name), interner.slice(named.name) });
        }
    }
    if (!plan.present) return;
    for (0..plan.scopes.len) |i| {
        const scope = plan.scopes.get(i);
        try w.print("  owner {s} bundle={d}\n", .{ interner.slice(bir.symbol(bir.decls[scope.decl.int()].name)), @backingInt(scope.scheme) });
        for (0..scope.len) |j| {
            const site = plan.sites.get(scope.start + j);
            try w.print("    site {d} {t} type={d} own={t} body={t}\n", .{ site.inst.int(), site.tag, site.type.int(), site.own, site.body });
        }
    }
    try interface.writeRaw(w, module_name, &plan.types, interner);
}
