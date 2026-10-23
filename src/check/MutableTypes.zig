//! Whether a declared type can contain a cell whose identity survives a
//! write. Propagate from records and List along declared payload edges.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Types = @import("Types.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Artifacts = @import("../Artifacts.zig");

pub fn settle(gpa: std.mem.Allocator, types: *Types, graph: *const Graph, artifacts: *const Artifacts, interner: *const InternPool.Global) !void {
    const n = types.entries.len;
    var from: std.ArrayList(u32) = .empty;
    defer from.deinit(gpa);
    var to: std.ArrayList(u32) = .empty;
    defer to.deinit(gpa);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    var pending: std.ArrayList(Bir.Inst.Index) = .empty;
    defer pending.deinit(gpa);
    const wk = types.well_known;
    for (types.entries, 0..) |*entry, k| {
        const id: Types.TypeId = @fromBackingInt(@intCast(k));
        const primitive = id == wk.int or id == wk.float or id == wk.string or id == wk.char or id == wk.bool or (entry.package == .core and std.mem.eql(u8, interner.slice(entry.module_name), "Int32") and std.mem.eql(u8, interner.slice(entry.name), "Int32"));
        if (entry.schema_endpoint) {
            entry.holds_mutable = true;
            try queue.append(gpa, @intCast(k));
            continue;
        }
        entry.holds_mutable = entry.schema_endpoint or id == wk.list or (entry.kind == .foreign and !primitive);
        const bir = artifacts.bir(graph.moduleFile(entry.module));
        const decl = bir.decl(entry.decl);
        pending.clearRetainingCapacity();
        switch (entry.kind) {
            .alias => if (decl.annotation.unwrap()) |body| try pending.append(gpa, body),
            .adt => for (bir.declCtors(decl)) |ctor| {
                try pending.appendSlice(gpa, bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index));
            },
            .foreign => {},
        }
        while (pending.pop()) |inst| {
            const tag = bir.instTag(inst);
            const data = bir.instData(inst);
            switch (tag) {
                // A function's signature does not describe cells it holds.
                // Closure identity is safe; ownership checks its captures.
                .type_fn => {},
                .type_record, .type_record_ext => entry.holds_mutable = true,
                .type_top, .ext_type, .schema_type_top, .ext_schema_type => {
                    const dep = types.headId(entry.module, tag, data);
                    if (dep == .none) continue;
                    try from.append(gpa, dep.int());
                    try to.append(gpa, @intCast(k));
                },
                .type_app => {
                    try pending.append(gpa, @fromBackingInt(@intCast(data.lhs)));
                    try pending.appendSlice(gpa, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index));
                },
                .type_tuple => try pending.appendSlice(gpa, bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)),
                else => {},
            }
        }
        if (entry.holds_mutable) try queue.append(gpa, @intCast(k));
    }
    const starts = try gpa.alloc(u32, n + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (from.items) |dep| starts[dep + 1] += 1;
    for (1..n + 1) |k| starts[k] += starts[k - 1];
    const edges = try gpa.alloc(u32, to.items.len);
    defer gpa.free(edges);
    const cursor = try gpa.dupe(u32, starts[0..n]);
    defer gpa.free(cursor);
    for (from.items, to.items) |dep, target| {
        edges[cursor[dep]] = target;
        cursor[dep] += 1;
    }
    while (queue.pop()) |dep| {
        for (edges[starts[dep]..starts[dep + 1]]) |target| {
            if (types.entries[target].holds_mutable) continue;
            types.entries[target].holds_mutable = true;
            try queue.append(gpa, target);
        }
    }
}
