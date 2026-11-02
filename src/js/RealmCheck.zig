//! EntryHost proof over inferred typed summaries, followed by a breadth-first
//! explanation in the entry's existing execution projection. No second native
//! shape graph and no source sidecar is involved.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const Reach = @import("Reach.zig");
const Operations = @import("../native/Operations.zig");
const Dispatch = @import("../check/Dispatch.zig");
const none = std.math.maxInt(u32);

pub fn check(e: anytype, module: Graph.Index, decl: u32) std.mem.Allocator.Error!void {
    if (e.options.library or !e.graph().has_native_bindings) return;
    const realm = e.options.platform.entry_host;
    const forbidden = Operations.bit(realm);
    const root_mask = e.session.checked.dispatch[module.int()].effectDecl(decl);
    var roots: std.ArrayList(Reach.Node) = .empty;
    if ((root_mask.realms | root_mask.eval_realms) & forbidden != 0) try roots.append(e.scratch, .{ .module = module, .index = decl, .kind = .decl });
    if (e.worker_runtime orelse e.session.entry_plan.runtime()) |runtime| {
        const mask = e.session.checked.dispatch[runtime.module.int()].effectDecl(runtime.decl);
        if ((mask.realms | mask.eval_realms) & forbidden != 0) try roots.append(e.scratch, .{ .module = runtime.module, .index = runtime.decl, .kind = .decl });
    }
    // Initializers that this projection actually evaluates are roots as well.
    for (e.session.checked.dispatch, 0..) |table, mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(mi));
        for (table.effect_decls, 0..) |effect, di| {
            if (effect.eval_realms & forbidden == 0 or !e.live.decl(m, di)) continue;
            if (m == module and di == decl) continue;
            try roots.append(e.scratch, .{ .module = m, .index = @intCast(di), .kind = .decl });
        }
    }
    if (roots.items.len == 0) return;
    const native_reachable = for (0..e.graph().count()) |mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(mi));
        if (e.graph().modulePackage(m) != .core) continue;
        const b = e.bir(m);
        for (b.decls, 0..) |d, di| {
            if (!e.live.decl(m, di)) continue;
            const op = Operations.lookup(e.session.interner.slice(e.graph().moduleName(m)), e.session.interner.slice(b.symbol(d.name))) orelse continue;
            if (op.allowed & forbidden != forbidden) break;
        } else continue;
        break true;
    } else false;
    if (!native_reachable) return;
    const Frame = struct { node: Reach.Node, parent: u32 };
    var queue: std.ArrayList(Frame) = .empty;
    // Sparse here: diagnostic-only nodes include derived rows as well as values.
    var seen: std.AutoHashMapUnmanaged(Reach.Node, void) = .empty;
    for (roots.items) |root| {
        const mark = try seen.getOrPut(e.scratch, root);
        if (mark.found_existing) continue;
        try queue.append(e.scratch, .{ .node = root, .parent = none });
    }
    var cursor: u32 = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const node = queue.items[cursor].node;
        if (node.kind == .decl and e.graph().modulePackage(node.module) == .core) {
            const b = e.bir(node.module);
            const name = e.session.interner.slice(b.symbol(b.decls[node.index].name));
            if (Operations.lookup(e.session.interner.slice(e.graph().moduleName(node.module)), name)) |operation| {
                if (operation.allowed & forbidden != forbidden) {
                    var path: std.ArrayList(u32) = .empty;
                    var at = cursor;
                    while (at != none) : (at = queue.items[at].parent) try path.append(e.scratch, at);
                    var chain: std.ArrayList(u8) = .empty;
                    var i = path.items.len;
                    while (i > 0) {
                        i -= 1;
                        const step = queue.items[path.items[i]].node;
                        if (chain.items.len != 0) try chain.appendSlice(e.scratch, " → ");
                        const step_name = if (step.kind == .decl) e.session.interner.slice(e.bir(step.module).symbol(e.bir(step.module).decls[step.index].name)) else "<evidence>";
                        try chain.print(e.scratch, "{s}.{s}", .{ e.session.interner.slice(e.graph().moduleName(step.module)), step_name });
                    }
                    var allowed: std.ArrayList(u8) = .empty;
                    inline for (@typeInfo(@import("../entry/Plan.zig").Realm).@"enum".field_names, @typeInfo(@import("../entry/Plan.zig").Realm).@"enum".field_values) |field_name, field_value| {
                        if (operation.allowed & (@as(u8, 1) << @intCast(field_value)) != 0) {
                            if (allowed.items.len != 0) try allowed.appendSlice(e.scratch, ", ");
                            try allowed.appendSlice(e.scratch, field_name);
                        }
                    }
                    if (realm == .unknown) {
                        try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "Native operation `{s}.{s}` requires a known entry realm. This platform chain does not declare `entryHost`. Allowed realms: {s}.\n\nShortest inferred call or evidence chain: {s}.", .{ operation.owner, operation.member, allowed.items, chain.items });
                        return;
                    }
                    try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "Native operation `{s}.{s}` is unavailable in entry realm `{s}`. Allowed realms: {s}.\n\nShortest inferred call or evidence chain: {s}.", .{ operation.owner, operation.member, @tagName(realm), allowed.items, chain.items });
                    return;
                }
            }
        }
        if (node.module.int() >= e.edges.len) continue;
        for (e.edges[node.module.int()].targets(node)) |edge| {
            const target = edge.node;
            if (target.kind == .decl and !e.live.decl(target.module, target.index)) continue;
            const mark = try seen.getOrPut(e.scratch, target);
            if (mark.found_existing) continue;
            try queue.append(e.scratch, .{ .node = target, .parent = cursor });
        }
    }
    // A summary cannot lose its native terminal: keep this an explicit compiler
    // defect rather than silently treating an unexplainable obligation as proven.
    try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "This entry's inferred native availability excludes realm `{s}` (mask {d}). The native call chain could not be reconstructed.", .{ @tagName(realm), root_mask.realms | root_mask.eval_realms });
}
