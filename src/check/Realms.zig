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

/// Discharge a realm-only obligation at its instantiated type. An unknown
/// variable remains a source in the scheme; an aggregate exposes all of its
/// callable descendants. These edges never carry purity or suspension.
pub fn connectValue(e: *Effects, value: Effects.Var, target: u32, scratch: std.mem.Allocator) Effects.Error!u8 {
    const Walk = @import("Walk.zig");
    const store = e.store;
    var stack: std.ArrayList(Effects.Var) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, value);
    const mark = store.nextMark();
    var bits: u8 = 0;
    while (stack.pop()) |next| {
        const root, _ = store.resolved(next);
        if (store.mark(root) == mark) continue;
        store.setMark(root, mark);
        if (e.realmCarrier(root)) {
            const source = try e.nodeFor(root);
            try e.edgeNodes(source, target, Effects.realm_origin);
            bits |= e.realmOf(source);
        }
        var k: u32 = 0;
        while (Walk.stepped(store, root, k)) |child| : (k += 1) try stack.append(scratch, child.v);
    }
    return bits;
}

pub fn connect(e: *Effects, scratch: std.mem.Allocator) Effects.Error!void {
    for (e.realm_edges.items) |edge|
        _ = try connectValue(e, edge.a, try e.nodeFor(edge.b), scratch);
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

pub const ForeignCall = struct { caller: u32, callback: u32 };

/// Foreign input obligations belong to their nearest positive arrow. A
/// returned callback receiver owns its inputs rather than the factory.
pub fn foreignDependencies(e: *Effects, nodes: []const u32, calls: []const ForeignCall, caller: u32) Effects.Error!void {
    for (calls) |relation| {
        if (relation.caller != caller) continue;
        const index = std.mem.indexOfScalar(u32, nodes, relation.callback) orelse continue;
        try e.solved.deps.append(e.gpa, @as(u32, @intCast(index)) | @import("../resolve/Interface.zig").EffectBlock.realm_only);
    }
}

/// Unknown types have realm obligations, but never effect rungs of their own.
pub fn carrier(e: *const Effects, r: Effects.Var) bool {
    return e.carries(r) or unknown(e.store, r);
}

/// Discharge each image of the source class independently. A generic parameter
/// can instantiate to a record or nominal aggregate, not just a function arrow.
pub fn applyCopy(e: *Effects, record: Effects.Record, source_node: u32, target: u32, work: *std.ArrayList(u32), scratch: std.mem.Allocator) Effects.Error!void {
    for (e.pairs.items[record.start..][0..record.len]) |p| {
        if ((e.nodeOf(p.a) orelse continue) != source_node) continue;
        const bits = try connectValue(e, p.b, target, scratch);
        try raiseRealm(e, target, bits, work, scratch);
    }
}

pub fn unknown(store: *TypeStore, root: Effects.Var) bool {
    return switch (store.content(root)) {
        .flex, .rigid => true,
        else => false,
    };
}

/// A local unknown's concrete copies must not join their effect classes.
/// The generic source observes their callable realms, including aggregates.
pub fn localCopy(e: *Effects, pair: Effects.Pair) Effects.Error!bool {
    if (!unknown(e.store, e.store.find(pair.a))) return false;
    try e.realm_edges.append(e.gpa, .{ .a = pair.b, .b = pair.a });
    return true;
}
