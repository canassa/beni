//! The runs that compile to a validator (`docs/design/schema.md` §6, *A run
//! whose failure is never read is a validator*): a call of core's
//! `Schema.read` that is the scrutinee of a `case`, directly, every arm of
//! which that can match an `Err` matches it as `Err _`. Decided from the
//! program's text alone, so reachability and lowering, which both ask,
//! answer the same: the call is written as a call of the core-private
//! `Schema.readValid`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const SchemaGraph = @import("SchemaGraph.zig");

const Inst = Bir.Inst;

/// A module's validator runs: the callees, which are `Schema.readValid`,
/// ascending; and of those whose schema is `S.schema ⊤` of a nongeneric
/// declaration, the argument calls and the member instructions, ascending,
/// with the declarations: such a run calls `Schema.validRun` with `S`'s
/// validator worker, and reaches no root value of `S`.
pub const Sites = struct {
    callees: []const u32 = &.{},
    direct_callees: []const u32 = &.{},
    args: []const u32 = &.{},
    members: []const u32 = &.{},
    refs: []const SchemaGraph.Ref = &.{},

    pub fn refOfArg(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.args, s.refs) |a, r| if (a == inst) return r;
        return null;
    }

    pub fn refOfMember(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.members, s.refs) |x, r| if (x == inst) return r;
        return null;
    }
};

pub fn sites(scratch: Allocator, graph: *const Graph, interfaces: []const Interface, provenance: []const Interface.Provenance, interner: anytype, bir: *const Bir, module: Graph.Index, sg: ?*const SchemaGraph, library: bool) Allocator.Error!Sites {
    var callee_list: std.ArrayList(u32) = .empty;
    var direct: std.ArrayList(u32) = .empty;
    var args: std.ArrayList(u32) = .empty;
    var members: std.ArrayList(u32) = .empty;
    var refs: std.ArrayList(SchemaGraph.Ref) = .empty;
    for (0..bir.insts.len) |i| {
        const inst: Inst.Index = @fromBackingInt(@intCast(i));
        if (bir.instTag(inst) != .case) continue;
        const c = calleeOf(graph, interfaces, interner, bir, inst) orelse continue;
        try callee_list.append(scratch, c.int());
        // Under `--schema-library` no worker is written: `readValid` runs
        // the schema through the library.
        if (library) continue;
        const g = sg orelse continue;
        const call: Inst.Index = @fromBackingInt(@intCast(bir.instData(inst).lhs));
        const call_args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(call).rhs))), Inst.Index);
        if (call_args.len != 2 or bir.instTag(call_args[0]) != .call) continue;
        const arg = call_args[0];
        const member: Inst.Index = @fromBackingInt(@intCast(bir.instData(arg).lhs));
        const ref = schemaRoot(provenance, interfaces, bir, module, member) orelse continue;
        const def = g.definition(ref.module, ref.decl) orelse continue;
        if (def.params_end != def.params_start) continue;
        try direct.append(scratch, c.int());
        try args.append(scratch, arg.int());
        try members.append(scratch, member.int());
        try refs.append(scratch, ref);
    }
    std.mem.sort(u32, callee_list.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, direct.items, {}, std.sort.asc(u32));
    return .{ .callees = callee_list.items, .direct_callees = direct.items, .args = args.items, .members = members.items, .refs = refs.items };
}

/// The declaration a `schema` member instruction names, `S.schema`.
fn schemaRoot(provenance: []const Interface.Provenance, interfaces: []const Interface, bir: *const Bir, module: Graph.Index, inst: Inst.Index) ?SchemaGraph.Ref {
    const d = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .schema_member_top => {
            const kind = std.enums.fromInt(Interface.SchemaMember.Kind, d.rhs) orelse return null;
            if (kind != .schema) return null;
            return .{ .module = module, .decl = d.lhs };
        },
        .ext_schema_member => {
            const owner: Graph.Index = @fromBackingInt(@intCast(d.lhs));
            if (owner.int() >= interfaces.len or owner.int() >= provenance.len) return null;
            const iface = &interfaces[owner.int()];
            if (d.rhs >= iface.schema_members.len) return null;
            const m = iface.schema_members[d.rhs];
            if (m.kind != .schema) return null;
            const decl = provenance[owner.int()].schemaDecl(@backingInt(m.schema)) orelse return null;
            return .{ .module = owner, .decl = decl.int() };
        },
        else => return null,
    }
}

/// Whether instruction `inst` is the callee of one of `list`'s runs.
pub fn has(list: []const u32, inst: u32) bool {
    return std.sort.binarySearch(u32, list, inst, struct {
        fn order(key: u32, x: u32) std.math.Order {
            return std.math.order(key, x);
        }
    }.order) != null;
}

/// The callee of `case` instruction `inst`'s scrutinee when it is a
/// validator run, else null.
fn calleeOf(graph: *const Graph, interfaces: []const Interface, interner: anytype, bir: *const Bir, inst: Inst.Index) ?Inst.Index {
    const d = bir.instData(inst);
    const scrutinee: Inst.Index = @fromBackingInt(@intCast(d.lhs));
    if (bir.instTag(scrutinee) != .call) return null;
    const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(scrutinee).lhs));
    if (!isCoreValue(graph, interfaces, interner, bir, callee, "Schema", "read")) return null;
    for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index)) |branch| {
        if (bir.instTag(branch) != .branch) return null;
        const pattern: Inst.Index = @fromBackingInt(@intCast(bir.instData(branch).lhs));
        switch (bir.instTag(pattern)) {
            .pat_wild => {},
            .pat_ctor => {
                const pd = bir.instData(pattern);
                const name = ctorName(graph, interfaces, interner, bir, @fromBackingInt(@intCast(pd.lhs))) orelse return null;
                if (std.mem.eql(u8, name, "Ok")) continue;
                if (!std.mem.eql(u8, name, "Err")) return null;
                const subs = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(pd.rhs))), Inst.Index);
                for (subs) |sub| if (bir.instTag(sub) != .pat_wild) return null;
            },
            else => return null,
        }
    }
    return callee;
}

fn isCoreValue(graph: *const Graph, interfaces: []const Interface, interner: anytype, bir: *const Bir, inst: Inst.Index, module_name: []const u8, value_name: []const u8) bool {
    if (bir.instTag(inst) != .ext_value) return false;
    const d = bir.instData(inst);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= interfaces.len or module.int() >= graph.count()) return false;
    if (graph.modulePackage(module) != .core) return false;
    if (!std.mem.eql(u8, interner.slice(graph.moduleName(module)), module_name)) return false;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.values.len) return false;
    return std.mem.eql(u8, interner.slice(iface.symbols[@backingInt(iface.values[d.rhs].name)]), value_name);
}

/// The name of the constructor a `pat_ctor`'s constructor instruction names,
/// when it is core `Result`'s, else null.
fn ctorName(graph: *const Graph, interfaces: []const Interface, interner: anytype, bir: *const Bir, inst: Inst.Index) ?[]const u8 {
    if (bir.instTag(inst) != .ext_ctor) return null;
    const d = bir.instData(inst);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= interfaces.len or module.int() >= graph.count()) return null;
    if (graph.modulePackage(module) != .core) return null;
    if (!std.mem.eql(u8, interner.slice(graph.moduleName(module)), "Result")) return null;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.ctors.len) return null;
    return interner.slice(iface.symbols[@backingInt(iface.ctors[d.rhs].name)]);
}
