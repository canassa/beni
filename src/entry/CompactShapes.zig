//! Checked record updates preserve field sets. Canonical literal sets and
//! memoized source-port equations avoid walking ancestry for every update.
const std = @import("std");
const Ir = @import("Compact.zig");
const Allocator = std.mem.Allocator;
const ShapeId = enum(u32) { none = std.math.maxInt(u32), _ };
const Shape = struct { selectors: Ir.Range, next: ShapeId };
const Cache = struct { state: enum(u8) { unseen, busy, ready } = .unseen, shape: ShapeId = .none };
const Frame = struct { port: Ir.PortId, exit: bool = false };

pub fn build(ir: *Ir, a: Allocator) Allocator.Error!void {
    var p: Pass = .{ .ir = ir, .a = a };
    defer p.deinit();
    try p.cache.ensureTotalCapacity(a, ir.ports.len);
    for (0..ir.ports.len) |_| p.cache.appendAssumeCapacity(.{});
    for (0..ir.ports.len) |i| {
        ir.counts.shape_port_work += 1;
        const port = ir.ports.get(i);
        if (port.tag != .allocation) continue;
        const row = ir.allocations.get(port.lhs);
        if (row.tag != .record or row.base == .none) continue;
        const shape = try p.resolve(@fromBackingInt(@intCast(i)));
        ir.allocations.items(.shape_complete)[port.lhs] = shape != .none;
        ir.allocations.items(.shape)[port.lhs] = if (shape == .none) .{} else p.shapes.get(@backingInt(shape)).selectors;
    }
}
const Pass = struct {
    ir: *Ir,
    a: Allocator,
    shapes: std.MultiArrayList(Shape) = .empty,
    cache: std.MultiArrayList(Cache) = .empty,
    frames: std.MultiArrayList(Frame) = .empty,
    index: std.AutoHashMapUnmanaged(u64, ShapeId) = .empty,
    names: std.ArrayList(Ir.SelectorId) = .empty,
    fn deinit(p: *Pass) void {
        inline for (.{ "shapes", "cache", "frames", "index", "names" }) |name| @field(p, name).deinit(p.a);
    }
    fn literal(p: *Pass, row: Ir.Allocation) !ShapeId {
        p.names.clearRetainingCapacity();
        for (row.fields.start..row.fields.start + row.fields.len) |i| {
            p.ir.counts.shape_selector_work += 1;
            try p.names.append(p.a, p.ir.fields.get(i).selector);
        }
        std.mem.sort(Ir.SelectorId, p.names.items, p.ir, struct {
            fn less(ir: *Ir, left: Ir.SelectorId, right: Ir.SelectorId) bool {
                ir.counts.shape_selector_work += 1;
                return @backingInt(left) < @backingInt(right);
            }
        }.less);
        var length: usize = 0;
        for (p.names.items) |name| {
            if (length == 0 or p.names.items[length - 1] != name) {
                p.names.items[length] = name;
                length += 1;
            }
        }
        p.names.items.len = length;
        p.ir.counts.shape_selector_work += length; // selector words hashed
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(p.names.items));
        const bucket = try p.index.getOrPut(p.a, hash);
        const old = if (bucket.found_existing) bucket.value_ptr.* else ShapeId.none;
        var at = old;
        while (at != .none) : (at = p.shapes.get(@backingInt(at)).next) {
            const other = p.shapes.get(@backingInt(at)).selectors;
            if (other.len != p.names.items.len) continue;
            var same = true;
            for (p.ir.ids(Ir.SelectorId, other), p.names.items) |left, right| {
                p.ir.counts.shape_selector_work += 1;
                if (left != right) {
                    same = false;
                    break;
                }
            }
            if (same) return at;
        }
        const selectors = try p.ir.appendIds(p.a, p.names.items);
        const id: ShapeId = @fromBackingInt(@intCast(p.shapes.len));
        try p.shapes.append(p.a, .{ .selectors = selectors, .next = old });
        bucket.value_ptr.* = id;
        return id;
    }
    fn push(p: *Pass, child_id: Ir.PortId) !void {
        p.ir.counts.shape_edge_work += 1;
        try p.frames.append(p.a, .{ .port = child_id });
    }
    fn child(p: *Pass, id: Ir.PortId) ShapeId {
        p.ir.counts.shape_edge_work += 1;
        return p.cache.get(@backingInt(id)).shape;
    }
    fn resolve(p: *Pass, root: Ir.PortId) !ShapeId {
        p.frames.clearRetainingCapacity();
        try p.frames.append(p.a, .{ .port = root });
        while (p.frames.len != 0) {
            const frame = p.frames.get(p.frames.len - 1);
            p.frames.len -= 1;
            p.ir.counts.shape_port_work += 1;
            const cached = p.cache.get(@backingInt(frame.port));
            if (cached.state == .ready) continue;
            const port = p.ir.ports.get(@backingInt(frame.port));
            if (frame.exit) {
                var shape: ShapeId = .none;
                switch (port.tag) {
                    .alias => if (port.lhs != std.math.maxInt(u32)) {
                        shape = p.child(@fromBackingInt(port.lhs));
                    },
                    .alternatives => {
                        const children = p.ir.ids(Ir.PortId, port.values);
                        if (children.len != 0) {
                            shape = p.child(children[0]);
                            for (children[1..]) |value| if (p.child(value) != shape) {
                                shape = .none;
                                break;
                            };
                        }
                    },
                    .allocation => {
                        const allocation = p.ir.allocations.get(port.lhs);
                        if (allocation.tag == .record) {
                            shape = if (allocation.base != .none) p.child(allocation.base) else try p.literal(allocation);
                            if (shape != .none) p.ir.allocations.items(.shape)[port.lhs] = p.shapes.get(@backingInt(shape)).selectors;
                        }
                    },
                    else => {},
                }
                p.cache.set(@backingInt(frame.port), .{ .state = .ready, .shape = shape });
                continue;
            }
            if (cached.state == .busy) {
                // Cyclic source shape equations are not evidence of a
                // well-founded materialized record. No recursive walker.
                p.cache.set(@backingInt(frame.port), .{ .state = .ready });
                continue;
            }
            p.cache.items(.state)[@backingInt(frame.port)] = .busy;
            try p.frames.append(p.a, .{ .port = frame.port, .exit = true });
            switch (port.tag) {
                .alias => if (port.lhs != std.math.maxInt(u32)) {
                    try p.push(@fromBackingInt(port.lhs));
                },
                .alternatives => for (p.ir.ids(Ir.PortId, port.values)) |value| try p.push(value),
                .allocation => {
                    const allocation = p.ir.allocations.get(port.lhs);
                    if (allocation.tag == .record and allocation.base != .none) try p.push(allocation.base);
                },
                else => {},
            }
        }
        return p.cache.get(@backingInt(root)).shape;
    }
};
