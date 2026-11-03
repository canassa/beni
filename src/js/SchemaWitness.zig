//! Checked-data evidence for generated Schema endpoints, from their checked
//! interface terms. It uses Lower.checkedShape, exactly as ordinary demands do.
const std = @import("std");
const Lowerer = @import("Lower.zig").Lowerer;
const Plan = @import("../check/SchemaPlan.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("../check/Dispatch.zig");
const JsIr = @import("JsIr.zig");
const Error = std.mem.Allocator.Error;

pub fn expression(l: *Lowerer, plan: *const Plan, root: Interface.TermIndex, parameters: []const JsIr.Node.Index, pos: u32) Error!?JsIr.Node.Index {
    var writer: Writer = .{ .l = l, .plan = plan };
    if (!try writer.typeOf(root, null, 0)) return null;
    return try l.checkedShape(writer.nodes.items, parameters, pos);
}

const Bound = struct { term: Interface.TermIndex, environment: ?[]const Bound };
const Writer = struct {
    l: *Lowerer,
    plan: *const Plan,
    nodes: std.ArrayList(Dispatch.DebugNode) = .empty,
    visited: u32 = 0,

    fn range(w: *Writer, index: u32) ?[]const u32 {
        if (index >= w.plan.type_extra.len) return null;
        const count = w.plan.type_extra[index];
        if (count > w.plan.type_extra.len - index - 1) return null;
        return w.plan.type_extra[index + 1 ..][0..count];
    }

    fn add(w: *Writer, kind: Dispatch.DebugNode.Kind, count: u32, value: u32) Error!void {
        try w.nodes.append(w.l.scratch, .{ .kind = kind, .count = count, .value = value });
    }

    fn typeOf(w: *Writer, root: Interface.TermIndex, environment: ?[]const Bound, depth: u32) Error!bool {
        if (root == .none or root.int() >= w.plan.terms.len or depth > 400) return false;
        w.visited += 1;
        if (w.visited > @import("../check/Identity.zig").max_parts) return false;
        const row = w.plan.terms.get(root.int());
        switch (row.tag) {
            .err => return false,
            .@"var" => {
                if (environment) |bindings| {
                    if (row.lhs >= bindings.len) return false;
                    const bound = bindings[row.lhs];
                    return w.typeOf(bound.term, bound.environment, depth + 1);
                }
                try w.add(.parameter, 0, row.lhs);
            },
            .unit => try w.add(.unit, 0, 0),
            .empty_record => try w.add(.record, 0, 0),
            .func => try w.add(.function, 0, 0),
            .tuple => {
                const words = w.range(row.lhs) orelse return false;
                try w.add(.tuple, @intCast(words.len), 0);
                for (words) |word| if (!try w.typeOf(@fromBackingInt(word), environment, depth + 1)) return false;
            },
            .record => {
                const words = w.range(row.lhs) orelse return false;
                if (words.len % 2 != 0) return false;
                const tail: Interface.TermIndex = @fromBackingInt(row.rhs);
                if (tail == .none or tail.int() >= w.plan.terms.len) return false;
                const open = w.plan.terms.get(tail.int()).tag != .empty_record;
                try w.add(.record, @intCast(words.len / 2 + @intFromBool(open)), 0);
                var i: usize = 0;
                while (i < words.len) : (i += 2) {
                    if (words[i] >= w.plan.symbols.len) return false;
                    try w.add(.field, 1, @backingInt(w.plan.symbols[words[i]]));
                    if (!try w.typeOf(@fromBackingInt(words[i + 1]), environment, depth + 1)) return false;
                }
                if (open) {
                    try w.add(.row, 1, 0);
                    if (!try w.typeOf(tail, environment, depth + 1)) return false;
                }
            },
            .app, .alias => {
                if (row.lhs >= w.plan.type_refs.len) return false;
                const ref = w.plan.type_refs[row.lhs];
                const words = w.range(row.rhs) orelse return false;
                if (row.tag == .alias) {
                    const bindings = try w.l.scratch.alloc(Bound, words.len);
                    for (bindings, words) |*binding, word| binding.* = .{ .term = @fromBackingInt(word), .environment = environment };
                    return w.typeOf(ref.body, bindings, depth + 1);
                }
                if (@backingInt(ref.module) >= w.plan.symbols.len or @backingInt(ref.name) >= w.plan.symbols.len) return false;
                const id = w.l.in.types.find(w.l.in.graph, ref.package, w.plan.symbols[@backingInt(ref.module)], w.plan.symbols[@backingInt(ref.name)]);
                if (id == .none) return false;
                try w.add(.named, @intCast(words.len), id.int());
                for (words) |word| if (!try w.typeOf(@fromBackingInt(word), environment, depth + 1)) return false;
            },
        }
        return true;
    }
};
