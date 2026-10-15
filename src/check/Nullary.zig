//! Turn resolved nullary dots into calls (static-dispatch-spike.md §1.1,
//! amendment 2026-10-15). This is the one rewrite all path walkers rely on.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Evidence = @import("Evidence.zig");
const Dispatch = @import("Dispatch.zig");

pub fn checked(gpa: std.mem.Allocator, bir: *Bir, evidence: *const Evidence) std.mem.Allocator.Error!void {
    var calls: std.ArrayList(Bir.Inst.Index) = .empty;
    defer calls.deinit(gpa);
    for (evidence.callees.items) |c| {
        if (bir.instTag(c.inst) != .field_access) continue;
        if (evidence.get(c.wanted).state != .answered) continue;
        if (evidence.answer(c.wanted) == .field) continue;
        try calls.append(gpa, c.inst);
    }
    try rewrite(gpa, bir, calls.items);
}

/// Cache entries store dispatch against the original frontend BIR. Replay the
/// rewrite from their callee sites before releasing the checked module.
/// `Elaborate.siteRows` omits field-read callees, so these sites are calls.
pub fn cached(gpa: std.mem.Allocator, bir: *Bir, dispatch: *const Dispatch) std.mem.Allocator.Error!void {
    var calls: std.ArrayList(Bir.Inst.Index) = .empty;
    defer calls.deinit(gpa);
    for (dispatch.sites) |site| {
        if (bir.instTag(site.inst) != .field_access or site.callee == .none) continue;
        try calls.append(gpa, site.inst);
    }
    try rewrite(gpa, bir, calls.items);
}

// The caller has finished solving (or loading) the module: no borrowed
// `extraSlice` survives this boundary. Bir.extra is gpa-owned on both the
// lowered and artifact-loader paths, as Bir.deinit's ownership requires.
fn rewrite(gpa: std.mem.Allocator, bir: *Bir, calls: []const Bir.Inst.Index) std.mem.Allocator.Error!void {
    if (calls.len == 0) return;
    const old_len = bir.extra.len;
    const extra = try gpa.alloc(u32, old_len + calls.len * Bir.extraLen(Bir.MethodCall));
    @memcpy(extra[0..old_len], bir.extra);
    for (calls, 0..) |inst, i| {
        const at = old_len + i * Bir.extraLen(Bir.MethodCall);
        const data = bir.instData(inst);
        const payload: Bir.MethodCall = .{
            .name = @fromBackingInt(@intCast(data.rhs)),
            .origin = .none,
            .args_start = @fromBackingInt(0),
            .args_end = @fromBackingInt(0),
        };
        inline for (@typeInfo(Bir.MethodCall).@"struct".field_names, 0..) |name, j|
            extra[at + j] = @backingInt(@field(payload, name));
        bir.insts.items(.tag)[inst.int()] = .method_call;
        bir.insts.items(.data)[inst.int()].rhs = @intCast(at);
    }
    gpa.free(bir.extra);
    bir.extra = extra;
}
