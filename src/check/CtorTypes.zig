//! One ordinary declaring-module constructor reader for public/private publication.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Context = @import("Context.zig");
const Types = @import("Types.zig");
const TypeStore = @import("TypeStore.zig");
const Var = TypeStore.Var;
pub const Read = struct {
    builder: Types.Builder,
    parameters: []const Var,
    arguments: []const Var,
    owns_parameters: bool,
    pub fn deinit(r: *Read) void {
        const a = r.builder.scratch;
        a.free(r.arguments);
        if (r.owns_parameters) a.free(r.parameters);
        r.builder.deinit();
    }
};
/// Supplied parameters are the FINAL ordinary Preparation's declaring slots.
/// A null slice preserves public ctorTerms' original fresh bindings exactly.
pub fn read(cx: *const Context, ctor: Bir.Ctor, parameters: ?[]const Var, work: ?*@import("TypeRead.zig").Work) std.mem.Allocator.Error!Read {
    var b = cx.builder(.flex, TypeStore.generalized);
    errdefer b.deinit();
    b.private_read = parameters != null;
    b.private_work = work;
    b.shallow = parameters != null;
    const names = cx.bir.declTypeParams(cx.bir.decl(ctor.decl));
    const params = parameters orelse try cx.scratch.alloc(Var, names.len);
    errdefer if (parameters == null) cx.scratch.free(params);
    std.debug.assert(params.len == names.len);
    for (names, 0..) |name, i| {
        if (parameters == null) @constCast(params)[i] = try cx.store.fresh(.{ .flex = .{ .name = name.toOptional() } }, TypeStore.generalized);
        try b.bind(name, params[i]);
    }
    const args = cx.bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index);
    const vars = try cx.scratch.alloc(Var, args.len);
    errdefer cx.scratch.free(vars);
    for (args, vars) |arg, *v| v.* = try b.read(arg);
    return .{ .builder = b, .parameters = params, .arguments = vars, .owns_parameters = parameters == null };
}
