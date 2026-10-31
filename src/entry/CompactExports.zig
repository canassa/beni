//! Source-finite launch summaries. Each row is (template, source launch), not
//! a caller environment. Only known direct source calls propagate exports.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ir = @import("Compact.zig");
const sentinel = std.math.maxInt(u32);
const ExportKey = struct { owner: Ir.TemplateId, launch: u32 };
const ContributionKey = struct { exported: u32, port: Ir.PortId };
const Contribution = struct { exported: u32, port: Ir.PortId, next: u32 };
const Caller = struct { call: Ir.CallId, next: u32 };

pub fn build(ir: *Ir, a: Allocator) Allocator.Error!void {
    std.debug.assert(ir.exports.len == 0);
    var pass: Pass = .{ .ir = ir, .a = a };
    defer pass.deinit();
    try pass.callers.resize(a, ir.templates.len);
    @memset(pass.callers.items, sentinel);
    for (0..ir.calls.len) |ci| {
        const call = ir.calls.get(ci);
        if (call.target == .none) continue;
        const index: u32 = @intCast(pass.links.len);
        try pass.links.append(a, .{ .call = @fromBackingInt(@intCast(ci)), .next = pass.callers.items[@backingInt(call.target)] });
        pass.callers.items[@backingInt(call.target)] = index;
    }
    for (0..ir.execution.len) |ei| {
        const execution = ir.execution.get(ei);
        if (execution.tag != .launch) continue;
        const exported = try pass.internExport(.{ .owner = execution.owner, .launch = @intCast(ei) });
        try pass.contribute(exported, execution.argument);
    }
    var cursor: usize = 0;
    while (cursor < ir.exports.len) : (cursor += 1) {
        const row = ir.exports.get(cursor);
        var link = pass.callers.items[@backingInt(row.owner)];
        while (link != sentinel) : (link = pass.links.items(.next)[link]) {
            const caller = pass.links.get(link);
            const call = ir.calls.get(@backingInt(caller.call));
            const target = try pass.internExport(.{ .owner = call.owner, .launch = row.launch });
            const port = try ir.addPort(a, .{
                .owner = call.owner,
                .site = call.site,
                .tag = .call,
                .lhs = @backingInt(caller.call),
                .rhs = @backingInt(row.port),
            });
            try pass.contribute(target, port);
        }
    }
    // Freeze each export's source contributions into the shared scalar sidecar.
    // Reverse insertion order is stable source order, never completion order.
    var values: std.ArrayList(Ir.PortId) = .empty;
    defer values.deinit(a);
    for (0..ir.exports.len) |ei| {
        values.clearRetainingCapacity();
        var at = pass.heads.items[ei];
        while (at != sentinel) : (at = pass.contributions.items(.next)[at])
            try values.append(a, pass.contributions.get(at).port);
        std.mem.reverse(Ir.PortId, values.items);
        const port = ir.exports.get(ei).port;
        ir.ports.items(.values)[@backingInt(port)] = try ir.appendIds(a, values.items);
    }
}

const Pass = struct {
    ir: *Ir,
    a: Allocator,
    index: std.AutoHashMapUnmanaged(ExportKey, u32) = .empty,
    contribution_index: std.AutoHashMapUnmanaged(ContributionKey, void) = .empty,
    heads: std.ArrayList(u32) = .empty,
    callers: std.ArrayList(u32) = .empty,
    links: std.MultiArrayList(Caller) = .empty,
    contributions: std.MultiArrayList(Contribution) = .empty,

    fn deinit(p: *Pass) void {
        p.index.deinit(p.a);
        p.contribution_index.deinit(p.a);
        p.heads.deinit(p.a);
        p.callers.deinit(p.a);
        p.links.deinit(p.a);
        p.contributions.deinit(p.a);
    }
    fn internExport(p: *Pass, key: ExportKey) Allocator.Error!u32 {
        const found = try p.index.getOrPut(p.a, key);
        if (found.found_existing) return found.value_ptr.*;
        const index: u32 = @intCast(p.ir.exports.len);
        const port = try p.ir.addPort(p.a, .{ .owner = key.owner, .site = p.ir.templates.get(@backingInt(key.owner)).site, .tag = .alternatives });
        try p.ir.exports.append(p.a, .{ .owner = key.owner, .launch = key.launch, .port = port });
        try p.heads.append(p.a, sentinel);
        found.value_ptr.* = index;
        return index;
    }
    fn contribute(p: *Pass, exported: u32, port: Ir.PortId) Allocator.Error!void {
        const found = try p.contribution_index.getOrPut(p.a, .{ .exported = exported, .port = port });
        if (found.found_existing) return;
        const index: u32 = @intCast(p.contributions.len);
        try p.contributions.append(p.a, .{ .exported = exported, .port = port, .next = p.heads.items[exported] });
        p.heads.items[exported] = index;
    }
};
