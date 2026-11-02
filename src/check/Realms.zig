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
        try e.realm_seeds.append(cx.gpa, .{ .v = v, .forbidden = Operations.all & ~op.allowed });
    }
}

/// Keep callable types visible at an erasing conversion until HostFree can be
/// enabled. This changes realm availability, never purity or suspension.
pub fn connect(e: *Effects, scratch: std.mem.Allocator) Effects.Error!void {
    const Walk = @import("Walk.zig");
    const store = e.store;
    var stack: std.ArrayList(Effects.Var) = .empty;
    defer stack.deinit(scratch);
    for (e.erasures.items) |copy| {
        const func = Walk.function(store, copy) orelse continue;
        try stack.appendSlice(scratch, func.params);
        const mark = store.nextMark();
        while (stack.pop()) |value| {
            const root, _ = store.resolved(value);
            if (store.mark(root) == mark) continue;
            store.setMark(root, mark);
            if (e.carries(root)) try e.realm_edges.append(e.gpa, .{ .a = root, .b = copy });
            var k: u32 = 0;
            while (Walk.stepped(store, root, k)) |child| : (k += 1) try stack.append(scratch, child.v);
        }
    }
    for (e.realm_edges.items) |edge| {
        try e.edgeNodes(try e.nodeFor(edge.a), try e.nodeFor(edge.b), Effects.realm_origin);
    }
}

/// Reuse the typed graph's dependency walk. The high bit marks paths which
/// carry realm facts but cannot make the receiver impure or suspendable.
pub fn dependencies(e: *Effects, nodes: []const u32, scratch: std.mem.Allocator, reach: ?[]bool) Effects.Error![][]u32 {
    const effects = try e.dependencies(nodes, scratch, reach, false);
    if (!e.has_realm_edges) return effects;
    const realms = try e.dependencies(nodes, scratch, null, true);
    defer scratch.free(realms);
    const realm_only = @import("../resolve/Interface.zig").EffectBlock.realm_only;
    for (effects, realms) |*effect, realm| {
        defer scratch.free(realm);
        var merged: std.ArrayList(u32) = .empty;
        try merged.appendSlice(scratch, effect.*);
        for (realm) |index| {
            if (std.mem.indexOfScalar(u32, effect.*, index) == null) try merged.append(scratch, index | realm_only);
        }
        scratch.free(effect.*);
        effect.* = try merged.toOwnedSlice(scratch);
    }
    return effects;
}

/// Forbidden native realms. Allocate only after the first nonportable seed.
pub fn realmOf(e: *const Effects, node: u32) u8 {
    return if (node < e.solved.realms.items.len) e.solved.realms.items[node] else 0;
}
pub fn raiseRealm(e: *Effects, node: u32, bits: u8, work: *std.ArrayList(u32), scratch: std.mem.Allocator) Effects.Error!void {
    if (bits == 0 or e.realmOf(node) | bits == e.realmOf(node)) return;
    const old_len = e.solved.realms.items.len;
    try e.solved.realms.resize(e.gpa, e.solved.nodes());
    @memset(e.solved.realms.items[old_len..], 0);
    e.solved.realms.items[node] |= bits;
    try work.append(scratch, node);
}
pub fn evalRealms(e: *Effects, decl: u32) u8 {
    if (decl >= e.eval.len) return 0;
    const v = e.eval[decl].unwrap() orelse return 0;
    return if (e.nodeOf(v)) |node| e.realmOf(node) else 0;
}
