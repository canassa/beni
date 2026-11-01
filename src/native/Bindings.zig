//! Ordinary checked attestation for the one pinned native candidate. No row is
//! lowerable until independent realm production/consumption is implemented.
const std = @import("std");
const Source = @import("Source.zig");
const SourceStore = @import("../SourceStore.zig");
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");

pub const Checked = struct {
    declaration: u32,
    getter_declaration: u32,
    getter_scheme: Interface.SchemeIndex,
    type_index: Interface.TypeIndex,
    scheme: Interface.SchemeIndex,
    status: Source.Status = .awaiting_realm,
};

/// Input Interface is structurally verified by the common reader or freshly
/// published by ordinary checking. A supplier tag alone never grants authority.
pub fn validate(origin: Source.Origin, bytes: []const u8, module_name: []const u8, package: SourceStore.Package, bir: *const Bir, iface: *const Interface, interner: *const InternPool.Global) ?Checked {
    if (!std.meta.eql(Source.candidate, Source.row(Source.candidate.file, Source.candidate.member_start, Source.candidate.member_end))) return null;
    if (origin != .text_encoder_v1 or package != .core or
        !std.mem.eql(u8, module_name, Source.module_name) or
        !std.mem.eql(u8, bytes, Source.source)) return null;
    if (bir.decls.len != 3 or iface.types.len != 1 or iface.values.len != 2 or iface.ctors.len != 0 or iface.schemas.len != 0) return null;
    var declaration: ?u32 = null;
    var native_type = false;
    var getter: ?u32 = null;
    for (bir.decls, 0..) |decl, i| {
        const name = interner.slice(bir.symbol(decl.name));
        if (!decl.is_pub) return null;
        switch (decl.kind) {
            .foreign_type => {
                if (!std.mem.eql(u8, name, "TextEncoder") or decl.params != 0 or decl.is_equatable) return null;
                native_type = true;
            },
            .foreign_value => {
                if (decl.params != 1 or decl.rung != .impure) return null;
                if (std.mem.eql(u8, name, "new")) declaration = @intCast(i) else if (std.mem.eql(u8, name, "encoding")) getter = @intCast(i) else return null;
            },
            else => return null,
        }
    }
    if (!native_type or declaration == null or getter == null) return null;
    const typ = iface.types[0];
    if (!std.mem.eql(u8, interner.slice(iface.symbol(typ.name)), "TextEncoder") or
        typ.kind != .foreign or typ.arity != 0 or typ.is_equatable or typ.ctors_start != typ.ctors_end) return null;
    var constructor_scheme: Interface.SchemeIndex = .none;
    var getter_scheme: Interface.SchemeIndex = .none;
    for (iface.values) |value| {
        const name = interner.slice(iface.symbol(value.name));
        const is_new = std.mem.eql(u8, name, "new");
        if (!is_new and !std.mem.eql(u8, name, "encoding")) return null;
        if (!value.is_foreign or value.is_markup_primitive or value.scheme == .none or @backingInt(value.scheme) >= iface.schemes.len) return null;
        const scheme = iface.schemes[@backingInt(value.scheme)];
        if (scheme.quantified_count != 0 or scheme.total) return null;
        const function = iface.term(scheme.body);
        if (function.tag != .func) return null;
        const args = iface.range(function.lhs);
        if (args.len != 1) return null;
        const argument = iface.term(@fromBackingInt(@intCast(args[0])));
        const result = iface.term(@fromBackingInt(function.rhs));
        if (is_new) {
            if (argument.tag != .unit or !isNominal(iface, interner, result, Source.module_name, "TextEncoder")) return null;
            if (constructor_scheme != .none) return null;
            constructor_scheme = value.scheme;
        } else {
            if (!isNominal(iface, interner, argument, Source.module_name, "TextEncoder") or !isNominal(iface, interner, result, "String", "String")) return null;
            if (getter_scheme != .none) return null;
            getter_scheme = value.scheme;
        }
        const block = iface.effectBlock(scheme) orelse return null;
        if (block.classCount() != 1) return null;
        const class = block.class(0);
        if (class.rung != 1 or class.deps.len != 0 or class.sync or class.sensitive) return null;
        var sites = block.sites();
        const root = sites.next() orelse return null;
        if (root.class != 0 or root.root != 0 or root.steps.len != 0 or sites.next() != null) return null;
    }
    if (constructor_scheme == .none or getter_scheme == .none) return null;
    return .{ .declaration = declaration.?, .getter_declaration = getter.?, .type_index = @fromBackingInt(0), .scheme = constructor_scheme, .getter_scheme = getter_scheme };
}
fn isNominal(iface: *const Interface, interner: *const InternPool.Global, term: Interface.Term, module: []const u8, name: []const u8) bool {
    if (term.tag != .app or term.lhs >= iface.type_refs.len or iface.range(term.rhs).len != 0) return false;
    const ref = iface.type_refs[term.lhs];
    return ref.package == .core and ref.body == .none and
        std.mem.eql(u8, interner.slice(iface.symbol(ref.module)), module) and
        std.mem.eql(u8, interner.slice(iface.symbol(ref.name)), name);
}

const Graph = @import("../resolve/Graph.zig");
const Types = @import("../check/Types.zig");

pub const Installed = struct {
    module: Graph.Index,
    nominal: Types.TypeId,
    checked: Checked,
    candidate: Source.Row = Source.candidate,
};

/// One supported identity, indexed by its closed Origin enum; not a source cap.
/// Future recipes must extend the indexed registry rather than scan declarations.
pub const Registry = struct {
    text_encoder: ?Installed = null,

    pub fn install(registry: *Registry, store: *const SourceStore, graph: *const Graph, types: *const Types, artifacts: *const @import("../Artifacts.zig"), interfaces: []const Interface, interner: *const InternPool.Global) error{InvalidNativeBinding}!void {
        var next: Registry = .{};
        for (0..graph.count()) |i| {
            const module: Graph.Index = @fromBackingInt(@intCast(i));
            const file = graph.moduleFile(module);
            if (store.nativeOrigin(file) == .none) continue;
            const checked = validate(store.nativeOrigin(file), store.bytes(file), interner.slice(graph.moduleName(module)), graph.modulePackage(module), artifacts.bir(file), &interfaces[i], interner) orelse return error.InvalidNativeBinding;
            const name = interfaces[i].symbol(interfaces[i].types[@backingInt(checked.type_index)].name);
            const nominal = types.find(graph, graph.modulePackage(module), graph.moduleName(module), name);
            if (nominal == .none or next.text_encoder != null) return error.InvalidNativeBinding;
            next.text_encoder = .{ .module = module, .nominal = nominal, .checked = checked };
        }
        registry.* = next;
    }
};

/// Common cache predicate, before replacing ordinary interface/derived tables.
/// An ordinary supplier receives no native authority from a cached record.
pub fn acceptsCached(store: ?*const SourceStore, graph: *const Graph, module: Graph.Index, bir: *const Bir, iface: *const Interface, interner: *const InternPool.Global) bool {
    const sources = store orelse return true;
    const file = graph.moduleFile(module);
    const origin = sources.nativeOrigin(file);
    if (origin == .none) return true;
    return validate(origin, sources.bytes(file), interner.slice(graph.moduleName(module)), graph.modulePackage(module), bir, iface, interner) != null;
}
