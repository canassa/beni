//! The runs that compile to a validator (`docs/design/schema.md` §6, *A run
//! whose failure is never read is a validator*). A run's error is never read
//! when the run is the scrutinee of a `case`, directly, every arm of which
//! that can match an `Err` matches it as `Err _`, or the first argument of
//! core's `Result.withDefault` or `Result.toMaybe`. Decided from the
//! program's text alone, so reachability and lowering, which both ask,
//! answer the same. Such a run calls a core-private runner in place of its
//! own:
//! - `Schema.read s v` calls `Schema.readValid`, or `Schema.validRun` with
//!   `S`'s validator worker when `s` is `S.schema ⊤` of a nongeneric
//!   declaration;
//! - `Schema.parse (S.schema ⊤) text` of a nongeneric `S` calls
//!   `Schema.validParse` with `S`'s validator worker; any other `parse`
//!   keeps its issues;
//! - `Json.decodeValue v` and `Json.decode text` whose evidence is a
//!   nongeneric derived codec are one call of `Schema.validRun` or
//!   `Schema.validParse` with the codec's validator worker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const SchemaGraph = @import("SchemaGraph.zig");

const Inst = Bir.Inst;

/// A module's validator runs. Every list of instructions is ascending.
pub const Sites = struct {
    /// The callees of the `Schema.read` and direct `Schema.parse` runs.
    callees: []const u32 = &.{},
    /// Of those, the ones whose schema is `S.schema ⊤` of a nongeneric
    /// declaration, which call `validRun` (a `read`) or `validParse` (a
    /// `parse`) with `S`'s validator worker and reach no root value of
    /// `S`; their argument calls and member instructions, with the
    /// declarations, in `args`, `members` and `refs`.
    direct_callees: []const u32 = &.{},
    /// Of the direct ones, the `parse` runs.
    parse_callees: []const u32 = &.{},
    args: []const u32 = &.{},
    members: []const u32 = &.{},
    refs: []const SchemaGraph.Ref = &.{},
    /// A `Json` validator run's call, written as one call of `validRun` or
    /// `validParse`, its codec's index in this module's plan, and of those
    /// calls the `decode` ones, which parse.
    json_calls: []const u32 = &.{},
    json_codecs: []const u32 = &.{},
    json_parses: []const u32 = &.{},
    /// Their callees, `Json.decodeValue` and `Json.decode`, which are not
    /// called.
    json_callees: []const u32 = &.{},

    pub fn refOfArg(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.args, s.refs) |a, r| if (a == inst) return r;
        return null;
    }

    pub fn refOfMember(s: Sites, inst: u32) ?SchemaGraph.Ref {
        for (s.members, s.refs) |x, r| if (x == inst) return r;
        return null;
    }

    /// The codec a `Json` validator run's call reads with.
    pub fn codecOfCall(s: Sites, inst: u32) ?u32 {
        for (s.json_calls, s.json_codecs) |x, k| if (x == inst) return k;
        return null;
    }

    /// The core-private value the callee of validator run `inst` calls.
    pub fn runner(s: Sites, callee: u32) []const u8 {
        if (has(s.parse_callees, callee)) return "validParse";
        return if (has(s.direct_callees, callee)) "validRun" else "readValid";
    }

    /// The core-private value a `Json` validator run's call is.
    pub fn jsonRunner(s: Sites, call: u32) []const u8 {
        return if (has(s.json_parses, call)) "validParse" else "validRun";
    }
};

/// What a run's callee is.
const Run = enum { schema_read, schema_parse, json_read, json_parse };

pub fn sites(
    scratch: Allocator,
    graph: *const Graph,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
    bir: *const Bir,
    dispatch: ?*const Dispatch,
    module: Graph.Index,
    sg: ?*const SchemaGraph,
    library: bool,
) Allocator.Error!Sites {
    var callee_list: std.ArrayList(u32) = .empty;
    var direct: std.ArrayList(u32) = .empty;
    var parses: std.ArrayList(u32) = .empty;
    var args: std.ArrayList(u32) = .empty;
    var members: std.ArrayList(u32) = .empty;
    var refs: std.ArrayList(SchemaGraph.Ref) = .empty;
    var json_calls: std.ArrayList(u32) = .empty;
    var json_codecs: std.ArrayList(u32) = .empty;
    var json_parses: std.ArrayList(u32) = .empty;
    var json_callees: std.ArrayList(u32) = .empty;
    for (0..bir.insts.len) |i| {
        const inst: Inst.Index = @fromBackingInt(@intCast(i));
        const call = unreadRun(graph, interfaces, interner, bir, inst) orelse continue;
        const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
        const run = runOf(graph, interfaces, interner, bir, callee) orelse continue;
        const call_args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(call).rhs))), Inst.Index);
        switch (run) {
            .json_read, .json_parse => {
                // Under `--schema-library` every run is the library's.
                if (library) continue;
                const g = sg orelse continue;
                const d = dispatch orelse continue;
                if (call_args.len != 1) continue;
                const site = d.siteOf(call) orelse continue;
                const roots = d.argsAt(site.evidence);
                if (roots.len != 1) continue;
                const k = switch (d.term(roots[0])) {
                    .codec => |use| use.index,
                    else => continue,
                };
                if (d.argsOfTerm(roots[0]).len != 0) continue;
                const def = g.definition(module, g.codecTarget(module, k).decl) orelse continue;
                if (def.params_end != def.params_start) continue;
                try json_calls.append(scratch, call.int());
                try json_codecs.append(scratch, k);
                try json_callees.append(scratch, callee.int());
                if (run == .json_parse) try json_parses.append(scratch, call.int());
            },
            .schema_read, .schema_parse => {
                // The schema `S.schema ⊤` of a nongeneric declaration, read
                // by its validator worker. Under `--schema-library` no worker
                // is written: a `read` calls `readValid`, which runs the
                // schema through the library, and a `parse` keeps its own.
                const direct_ref: ?struct { u32, u32, SchemaGraph.Ref } = blk: {
                    if (library) break :blk null;
                    const g = sg orelse break :blk null;
                    if (call_args.len != 2 or bir.instTag(call_args[0]) != .call) break :blk null;
                    const arg = call_args[0];
                    const member: Inst.Index = @fromBackingInt(@intCast(bir.instData(arg).lhs));
                    const ref = schemaRoot(provenance, interfaces, bir, module, member) orelse break :blk null;
                    const def = g.definition(ref.module, ref.decl) orelse break :blk null;
                    if (def.params_end != def.params_start) break :blk null;
                    break :blk .{ arg.int(), member.int(), ref };
                };
                // A `parse` of any other schema keeps its issues.
                if (run == .schema_parse and direct_ref == null) continue;
                try callee_list.append(scratch, callee.int());
                if (direct_ref) |r| {
                    try direct.append(scratch, callee.int());
                    if (run == .schema_parse) try parses.append(scratch, callee.int());
                    try args.append(scratch, r[0]);
                    try members.append(scratch, r[1]);
                    try refs.append(scratch, r[2]);
                }
            },
        }
    }
    std.mem.sort(u32, callee_list.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, direct.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, parses.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, json_parses.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, json_callees.items, {}, std.sort.asc(u32));
    return .{
        .callees = callee_list.items,
        .direct_callees = direct.items,
        .parse_callees = parses.items,
        .args = args.items,
        .members = members.items,
        .refs = refs.items,
        .json_calls = json_calls.items,
        .json_codecs = json_codecs.items,
        .json_parses = json_parses.items,
        .json_callees = json_callees.items,
    };
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

/// Whether instruction `inst` is in `list`, which is ascending.
pub fn has(list: []const u32, inst: u32) bool {
    return std.sort.binarySearch(u32, list, inst, struct {
        fn order(key: u32, x: u32) std.math.Order {
            return std.math.order(key, x);
        }
    }.order) != null;
}

/// The call whose error instruction `inst` never reads: a `case`'s
/// scrutinee whose `Err` arms are all `Err _`, or the first argument of a
/// call of `Result.withDefault` or `Result.toMaybe`. Null otherwise.
fn unreadRun(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index) ?Inst.Index {
    const d = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .case => {
            const scrutinee: Inst.Index = @fromBackingInt(@intCast(d.lhs));
            if (bir.instTag(scrutinee) != .call) return null;
            if (!errUnread(graph, interfaces, interner, bir, inst)) return null;
            return scrutinee;
        },
        .call => {
            const callee: Inst.Index = @fromBackingInt(@intCast(d.lhs));
            if (!isCoreValue(graph, interfaces, interner, bir, callee, "Result", "withDefault") and
                !isCoreValue(graph, interfaces, interner, bir, callee, "Result", "toMaybe")) return null;
            const call_args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index);
            if (call_args.len == 0 or bir.instTag(call_args[0]) != .call) return null;
            return call_args[0];
        },
        else => return null,
    }
}

/// Which run a call's callee is, if it is one.
fn runOf(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, callee: Inst.Index) ?Run {
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Schema", "read")) return .schema_read;
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Schema", "parse")) return .schema_parse;
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Json", "decodeValue")) return .json_read;
    if (isCoreValue(graph, interfaces, interner, bir, callee, "Json", "decode")) return .json_parse;
    return null;
}

/// Whether every arm of `case` instruction `inst` that can match an `Err`
/// matches it as `Err _`.
fn errUnread(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index) bool {
    const d = bir.instData(inst);
    for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index)) |branch| {
        if (bir.instTag(branch) != .branch) return false;
        const pattern: Inst.Index = @fromBackingInt(@intCast(bir.instData(branch).lhs));
        switch (bir.instTag(pattern)) {
            .pat_wild => {},
            .pat_ctor => {
                const pd = bir.instData(pattern);
                const name = ctorName(graph, interfaces, interner, bir, @fromBackingInt(@intCast(pd.lhs))) orelse return false;
                if (std.mem.eql(u8, name, "Ok")) continue;
                if (!std.mem.eql(u8, name, "Err")) return false;
                const subs = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(pd.rhs))), Inst.Index);
                for (subs) |sub| if (bir.instTag(sub) != .pat_wild) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn isCoreValue(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index, module_name: []const u8, value_name: []const u8) bool {
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
fn ctorName(graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global, bir: *const Bir, inst: Inst.Index) ?[]const u8 {
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
