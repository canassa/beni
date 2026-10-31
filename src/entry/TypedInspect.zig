//! Checked-entry inspection of owned ordinary roots. No Wire certification.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Artifacts = @import("../Artifacts.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("../check/Types.zig");
const Dispatch = @import("../check/Dispatch.zig");
const EntryRoots = @import("../check/EntryRoots.zig");
const Plan = @import("Plan.zig");
const RoleRoots = @import("RoleRoots.zig");
const interface = @import("../dump/interface.zig");
pub const Input = struct {
    graph: *const Graph,
    artifacts: *const Artifacts,
    interner: *const InternPool.Global,
    types: *const Types,
    dispatch: []const Dispatch,
    plan: *const Plan,
};
pub const Error = Allocator.Error || std.Io.Writer.Error || error{ UnvalidatedPlan, MissingEntryRoots, MissingNominalLayouts };
/// Availability only: current checked Plan identity, never source reconstruction.
pub fn validate(in: Input) error{ UnvalidatedPlan, MissingEntryRoots, MissingNominalLayouts }!void {
    if (!in.plan.validated) return error.UnvalidatedPlan;
    for (in.dispatch) |*dispatch| {
        for (dispatch.decl_heads, 0..) |head, di| {
            if (in.plan.find(head) == null) continue;
            if (!dispatch.entry_roots.present or dispatch.entry_roots.find(@fromBackingInt(@intCast(di))) == null)
                return error.MissingEntryRoots;
        }
    }
    for (in.dispatch, 0..) |*dispatch, mi| {
        if (inspectNominals(in, @fromBackingInt(@intCast(mi))) and !dispatch.nominal_layouts.present) return error.MissingNominalLayouts;
    }
}
/// Call only after the existing complete entry contract validation.
/// All output references artifact-local indices; no expanded aliases/trees.
pub fn write(gpa: Allocator, out: *std.Io.Writer, in: Input) Error!void {
    try validate(in);
    try out.writeAll("typed-entry-roots proof=ordinary-types wire=false\n");
    for (in.dispatch, 0..) |*dispatch, mi| {
        const module: Graph.Index = @fromBackingInt(@intCast(mi));
        const artifact = &dispatch.entry_roots;
        const bir = in.artifacts.bir(in.graph.moduleFile(module));
        var needed = false;
        for (dispatch.decl_heads, 0..) |head, di| {
            if (in.plan.find(head) == null) continue;
            needed = true;
            if (!artifact.present or artifact.find(@fromBackingInt(@intCast(di))) == null) return error.MissingEntryRoots;
        }
        if (!needed) continue;
        const name = in.interner.slice(in.graph.moduleName(module));
        try out.print("typed-module {t}:{s} schema={d} present={}\n", .{ in.graph.modulePackage(module), name, EntryRoots.schema_version, artifact.present });
        var views = try RoleRoots.init(gpa, &artifact.types);
        defer views.deinit(gpa);
        for (0..artifact.roots.len) |i| {
            const row = artifact.roots.get(i);
            const kind_index = in.plan.find(dispatch.decl_heads[row.decl.int()]) orelse continue;
            const kind = in.plan.kinds.get(@backingInt(kind_index));
            try out.print("  typed-candidate {s} decl={d} scheme={d}\n", .{ in.interner.slice(bir.symbol(bir.decls[row.decl.int()].name)), row.decl.int(), @backingInt(row.scheme) });
            for (kind.roles.start..@as(usize, kind.roles.start) + kind.roles.len) |ri| {
                const role = in.plan.roles.get(ri);
                try out.print("    role {d} {t} parameter={d} path=", .{ ri, role.kind, role.index });
                const path = in.plan.paths.items[role.path.start..][0..role.path.len];
                for (path, 0..) |field, fi| {
                    if (fi != 0) try out.writeByte('.');
                    try quoted(out, in.interner.slice(field));
                }
                if (role.kind == .local) {
                    try out.writeAll(" excluded\n");
                    continue;
                }
                const result_index = try views.project(gpa, row.scheme, role.index, path);
                const result = views.results.get(@backingInt(result_index));
                try out.print(" {t} view={d} remaining={d}\n", .{ result.kind, @backingInt(result.view), result.remaining });
            }
        }
        for (0..views.views.len) |i| {
            const view = views.views.get(i);
            try out.print("  view {d} scheme={d} term={d} env={d}\n", .{ i, @backingInt(view.scheme), view.term.int(), @backingInt(view.env) });
        }
        for (0..views.frames.len) |i| {
            const frame = views.frames.get(i);
            try out.print("  frame {d} args=", .{i});
            for (views.extra.items[frame.start..][0..frame.len], 0..) |arg, ai| {
                if (ai != 0) try out.writeByte(',');
                try out.print("{d}", .{arg});
            }
            try out.writeByte('\n');
        }
        // Existing raw printer writes flat terms/refs/extra once; never reads
        // the recursive public InterfaceTerms reader or expanded Render.
        try interface.writeRaw(out, name, &artifact.types, in.interner);
        for (artifact.types.schemes, 0..) |scheme, si| {
            try out.print("scheme-proof {d} total={} identities=", .{ si, scheme.total });
            for (0..scheme.quantified_count) |q| {
                if (artifact.types.quantified(scheme, @intCast(q)).identity) try out.print("{d},", .{q});
            }
            try out.writeByte('\n');
        }
    }
    for (in.dispatch, 0..) |*dispatch, mi| {
        const module: Graph.Index = @fromBackingInt(@intCast(mi));
        if (inspectNominals(in, module)) try @import("NominalInspect.zig").write(out, in.graph, module, &dispatch.nominal_layouts, in.interner);
    }
}

fn inspectNominals(in: Input, module: Graph.Index) bool {
    if (in.graph.modulePackage(module) == .app) return true;
    for (in.plan.kinds.items(.module)) |owner| if (owner == module) return true;
    for (in.dispatch[module.int()].decl_heads) |head| if (in.plan.find(head) != null) return true;
    return false;
}

fn quoted(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => if (byte < 0x20 or byte == 0x7f) {
            const hex = "0123456789abcdef";
            try out.writeAll("\\x");
            try out.writeByte(hex[byte >> 4]);
            try out.writeByte(hex[byte & 15]);
        } else try out.writeByte(byte),
    };
    try out.writeByte('"');
}
