//! Flat inspection of the declaring artifact; no cross-artifact cursor/Wire proof.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Layouts = @import("../check/NominalLayouts.zig");
const interface = @import("../dump/interface.zig");
pub fn write(out: *std.Io.Writer, graph: *const Graph, module: Graph.Index, a: *const Layouts.Artifact, interner: *const InternPool.Global) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const name = interner.slice(graph.moduleName(module));
    try out.print("nominal-module {t}:{s} schema={d} owners={d} ctors={d} proof=ordinary-types wire=false\n", .{ graph.modulePackage(module), name, Layouts.schema_version, a.owners.len, a.constructors.len });
    for (0..a.owners.len) |oi| {
        const owner = a.owners.get(oi);
        const ref = a.types.type_refs[owner.type_ref.int()];
        try out.print("  nominal-owner {d} {s} kind={t} arity={d} scheme={d} ctors={d}+{d}", .{ oi, interner.slice(a.types.symbol(ref.name)), owner.kind, owner.arity, @backingInt(owner.scheme), owner.ctor_start, owner.ctor_len });
        switch (owner.kind) {
            .adt => try out.writeAll(" layout=ordinary-payloads\n"),
            .native_opaque => try out.writeAll(" layout=native-contract-unavailable\n"),
            .schema_type, .schema_encoded => try out.writeAll(" layout=schema-contract-unavailable\n"),
        }
        for (owner.ctor_start..@as(usize, owner.ctor_start) + owner.ctor_len) |ci| {
            const ctor = a.constructors.get(ci);
            try out.print("    nominal-ctor {d} {s} ordinal={d} args=[", .{ ci, interner.slice(a.types.symbol(ctor.name)), ctor.ordinal });
            for (a.arguments[ctor.arg_start..][0..ctor.arg_len], 0..) |arg, ai| {
                if (ai != 0) try out.writeByte(',');
                try out.print("{d}", .{arg.int()});
            }
            try out.writeAll("]\n");
        }
    }
    try interface.writeRaw(out, name, &a.types, interner);
}
