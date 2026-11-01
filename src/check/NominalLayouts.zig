//! Complete declaring-module private nominal evidence; never Wire certification.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("Types.zig");
const TypeStore = @import("TypeStore.zig");
const Context = @import("Context.zig");
const Schemes = @import("Schemes.zig");
const PrivateTerms = @import("PrivateTerms.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
pub const schema_version: u32 = 1;
pub const Work = struct {
    reader: @import("TypeRead.zig").Work = .{},
    owners: u64 = 0,
    ctors: u64 = 0,
    args: u64 = 0,
    cover_headers: u64 = 0,
    cover_ctors: u64 = 0,
    cover_refs: u64 = 0,
    cover_terms: u64 = 0,
};
pub const Kind = enum(u8) { adt, native_opaque, schema_type, schema_encoded };
pub const Owner = struct {
    type_ref: Interface.TypeRefIndex,
    decl: Bir.DeclIndex,
    scheme: Interface.SchemeIndex = .none,
    ctor_start: u32,
    ctor_len: u32,
    arity: u16,
    kind: Kind,
};
pub const Constructor = struct { name: Interface.SymbolIndex, owner: u32, ordinal: u32, arg_start: u32, arg_len: u32 };
pub const Artifact = struct {
    present: bool = false,
    owners: std.MultiArrayList(Owner).Slice = .empty,
    constructors: std.MultiArrayList(Constructor).Slice = .empty,
    arguments: []const Interface.TermIndex = &.{},
    types: Interface = .empty,
    pub const empty: Artifact = .{};
    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        a.owners.deinit(gpa);
        a.constructors.deinit(gpa);
        gpa.free(a.arguments);
        a.types.deinit(gpa);
        a.* = .empty;
    }
    pub fn verify(a: *const Artifact, gpa: Allocator, interner: *const InternPool.Global) Allocator.Error!bool {
        if (!a.present) return a.owners.len == 0 and a.constructors.len == 0 and a.arguments.len == 0 and a.types.terms.len == 0 and a.types.schemes.len == 0 and a.types.type_refs.len == 0;
        inline for (.{ "values", "types", "ctors", "schemas", "schema_members", "schema_ctors", "hidden_types", "elements", "attributes", "events", "ownership" }) |field| if (@field(a.types, field).len != 0) return false;
        if (!iface_bytes.verify(&a.types, interner) or !try PrivateTerms.verifyTypes(gpa, &a.types)) return false;
        for (a.types.terms.items(.tag), 0..) |tag, i| {
            if (tag == .err) return false;
            if (tag != .record) continue;
            const fields = a.types.range(a.types.terms.items(.lhs)[i]);
            var previous: ?InternPool.Symbol = null;
            var f: usize = 0;
            while (f < fields.len) : (f += 2) {
                const symbol = a.types.symbol(@fromBackingInt(fields[f]));
                if (previous) |p| if (!std.mem.lessThan(u8, interner.slice(p), interner.slice(symbol))) return false;
                previous = symbol;
            }
        }
        const seen = try gpa.alloc(bool, a.types.type_refs.len);
        defer gpa.free(seen);
        @memset(seen, false);
        var ctors: usize = 0;
        var args: usize = 0;
        var schemes: usize = 0;
        for (0..a.owners.len) |oi| {
            const owner = a.owners.get(oi);
            if (owner.type_ref.int() >= seen.len or seen[owner.type_ref.int()]) return false;
            seen[owner.type_ref.int()] = true;
            if (owner.ctor_start != ctors or owner.ctor_len > a.constructors.len - ctors) return false;
            if (owner.kind != .adt) {
                if (owner.scheme != .none or owner.ctor_len != 0) return false;
                continue;
            }
            if (owner.scheme == .none or @backingInt(owner.scheme) != schemes or schemes >= a.types.schemes.len) return false;
            const scheme = a.types.scheme(owner.scheme);
            schemes += 1;
            if (scheme.quantified_count != owner.arity) return false;
            const body = a.types.term(scheme.body);
            if (body.tag != .tuple) return false;
            const bundle = a.types.range(body.lhs);
            if (bundle.len == 0) return false;
            const anchor = a.types.terms.get(bundle[0]);
            if (anchor.tag != .app or anchor.lhs != owner.type_ref.int()) return false;
            const parameters = a.types.range(anchor.rhs);
            if (parameters.len != owner.arity) return false;
            for (parameters, 0..) |parameter, pi| {
                const term = a.types.terms.get(parameter);
                if (term.tag != .@"var" or term.lhs != pi) return false;
            }
            var part: usize = 1;
            for (0..owner.ctor_len) |ci| {
                const ctor = a.constructors.get(ctors);
                if (ctor.owner != oi or ctor.ordinal != ci or @backingInt(ctor.name) >= a.types.symbols.len) return false;
                if (ctor.arg_start != args or ctor.arg_len > a.arguments.len - args or ctor.arg_len > bundle.len - part) return false;
                for (a.arguments[args..][0..ctor.arg_len], bundle[part..][0..ctor.arg_len]) |arg, expected| if (arg.int() != expected) return false;
                args += ctor.arg_len;
                part += ctor.arg_len;
                ctors += 1;
            }
            if (part != bundle.len) return false;
        }
        return ctors == a.constructors.len and args == a.arguments.len and schemes == a.types.schemes.len;
    }
    /// Resolve every referenced identity once; compare complete current owners.
    pub fn covers(a: *const Artifact, gpa: Allocator, bir: *const Bir, graph: *const Graph, types: *const Types, module: Graph.Index, interner: *const InternPool.Global, own_interface: *const Interface, work: ?*Work) Allocator.Error!bool {
        if (!a.present) return false;
        const ids = try gpa.alloc(Types.TypeId, a.types.type_refs.len);
        defer gpa.free(ids);
        for (a.types.type_refs, ids) |ref, *id| {
            if (work) |w| w.cover_refs += 1;
            id.* = types.find(graph, ref.package, a.types.symbol(ref.module), a.types.symbol(ref.name));
            if (id.* == .none) return false;
        }
        for (a.types.terms.items(.tag), 0..) |tag, i| {
            if (work) |w| w.cover_terms += 1;
            if (tag != .app and tag != .alias) continue;
            const term = a.types.terms.get(i);
            const entry = types.entry(ids[term.lhs]);
            if ((tag == .alias) != (entry.kind == .alias) or a.types.range(term.rhs).len != entry.arity) return false;
        }
        var count: usize = 0;
        for (types.entry_offsets[module.int()]..types.entry_offsets[module.int() + 1]) |i| {
            if (work) |w| w.cover_headers += 1;
            const id: Types.TypeId = @fromBackingInt(@intCast(i));
            const entry = types.entry(id);
            if (entry.kind == .alias and !entry.schema_endpoint) continue;
            if (count >= a.owners.len) return false;
            const owner = a.owners.get(count);
            count += 1;
            if (ids[owner.type_ref.int()] != id or owner.decl != entry.decl or owner.arity != entry.arity or owner.kind != layoutKind(types, id)) return false;
            if (owner.kind != .adt) continue;
            const cs = bir.declCtors(bir.decl(entry.decl));
            if (owner.ctor_len != cs.len) return false;
            const scheme = a.types.scheme(owner.scheme);
            const names = bir.declTypeParams(bir.decl(entry.decl));
            if (names.len != owner.arity) return false;
            for (types.keyKinds(id), names, 0..) |required, name, pi| {
                const base_kind = Types.kindOfName(interner.slice(name));
                const q = a.types.quantified(scheme, @intCast(pi));
                if (q.kind > @backingInt(TypeStore.Kind.string_key)) return false;
                const actual: TypeStore.Kind = @fromBackingInt(@intCast(q.kind));
                if (required.isKey() and actual != (TypeStore.Kind.meet(base_kind, required) orelse return false)) return false;
                if (own_interface.typeFacts(interner, entry.name)) |facts| {
                    if (facts.arity != owner.arity or facts.kind != .adt) return false;
                    var declared: TypeStore.Kind = .any;
                    if (facts.key_kinds != Interface.no_terms) {
                        const domains = own_interface.range(facts.key_kinds);
                        if (domains.len != owner.arity or domains[pi] > @backingInt(TypeStore.Kind.string_key)) return false;
                        declared = @fromBackingInt(@intCast(domains[pi]));
                    }
                    if (actual != (TypeStore.Kind.meet(base_kind, declared) orelse return false)) return false;
                } else if (TypeStore.Kind.meet(base_kind, actual) != actual) return false;
            }
            for (cs, 0..) |source, ci| {
                if (work) |w| w.cover_ctors += 1;
                const ctor = a.constructors.get(owner.ctor_start + ci);
                if (a.types.symbol(ctor.name) != bir.symbol(source.name) or ctor.arg_len != bir.extraSlice(.{ .start = source.args_start, .end = source.args_end }, Bir.Inst.Index).len) return false;
            }
        }
        return count == a.owners.len;
    }
};
pub const Input = struct { cx: *const Context, parameters: []const ?[]const TypeStore.Var, crossing: []const bool = &.{}, work: ?*Work = null, solved_capture: ?*@import("SolvedRepresentations.zig").Capture = null };
pub const Error = Allocator.Error || error{ MissingParameters, BadOwnerArity, ParameterKindMismatch, UnexpectedBinder, InvalidLayout, IncompleteLayout, BadScope };
fn layoutKind(types: *const Types, id: Types.TypeId) Kind {
    const e = types.entry(id);
    if (e.schema_endpoint) return if (types.ofSchemaDecl(e.module, e.decl, .type) == id) .schema_type else .schema_encoded;
    return if (e.kind == .foreign) .native_opaque else .adt;
}
pub fn build(in: Input) Error!Artifact {
    const cx = in.cx;
    const gpa = cx.gpa;
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(gpa);
    var owners: std.MultiArrayList(Owner) = .empty;
    defer owners.deinit(gpa);
    var ctors: std.MultiArrayList(Constructor) = .empty;
    defer ctors.deinit(gpa);
    var arguments: std.ArrayList(Interface.TermIndex) = .empty;
    defer arguments.deinit(gpa);
    var writer: Schemes.Writer = .init(gpa, cx.store, cx.interner, cx.types, 0);
    defer writer.deinit();
    var bodies = cx.builder(.flex, TypeStore.generalized);
    defer bodies.deinit();
    bodies.shallow = true;
    bodies.private_read = true;
    bodies.private_work = if (in.work) |w| &w.reader else null;
    writer.bodies = &bodies;
    writer.crossing = in.crossing;
    writer.solved_capture = in.solved_capture;
    writer.solved_origin = .nominal;
    const first = cx.types.entry_offsets[cx.module.int()];
    const last = cx.types.entry_offsets[cx.module.int() + 1];
    for (first..last) |i| {
        const id: Types.TypeId = @fromBackingInt(@intCast(i));
        const e = cx.types.entry(id);
        if (e.kind == .alias and !e.schema_endpoint) continue;
        if (in.work) |w| w.owners += 1;
        var row: Owner = .{ .type_ref = try writer.typeRefOf(id), .decl = e.decl, .ctor_start = @intCast(ctors.len), .ctor_len = 0, .arity = e.arity, .kind = layoutKind(cx.types, id) };
        if (row.kind == .adt) {
            if (i >= in.parameters.len) return error.MissingParameters;
            const params = in.parameters[i] orelse return error.MissingParameters;
            if (params.len != e.arity or params.len != cx.bir.declTypeParams(cx.bir.decl(e.decl)).len) return error.BadOwnerArity;
            for (params, cx.types.keyKinds(id), cx.bir.declTypeParams(cx.bir.decl(e.decl))) |v, required, name| {
                const expected = TypeStore.Kind.meet(Types.kindOfName(cx.interner.slice(name)), required) orelse return error.ParameterKindMismatch;
                switch (cx.store.resolvedContent(v)) {
                    .flex, .rigid => |flags| if (flags.kind != expected) return error.ParameterKindMismatch,
                    else => return error.UnexpectedBinder,
                }
            }
            var roots: std.ArrayList(TypeStore.Var) = .empty;
            defer roots.deinit(gpa);
            try roots.append(gpa, try bodies.apply(id, params));
            const cs = cx.bir.declCtors(cx.bir.decl(e.decl));
            row.ctor_len = @intCast(cs.len);
            for (cs, 0..) |ctor, ci| {
                var input = try @import("CtorTypes.zig").read(cx, ctor, params, if (in.work) |w| &w.reader else null);
                defer input.deinit();
                if (in.work) |w| {
                    w.ctors += 1;
                    w.args += input.arguments.len;
                }
                try ctors.append(gpa, .{ .name = @fromBackingInt(try writer.symbolIndex(cx.bir.symbol(ctor.name))), .owner = @intCast(owners.len), .ordinal = @intCast(ci), .arg_start = @intCast(arguments.items.len + roots.items.len - 1), .arg_len = @intCast(input.arguments.len) });
                try roots.appendSlice(gpa, input.arguments);
            }
            const bundle = try cx.store.fresh(.{ .structure = .{ .tuple = try cx.store.addVars(roots.items) } }, TypeStore.generalized);
            row.scheme = try writer.addPrivate(bundle);
            if (in.solved_capture) |capture| try capture.add(gpa, .nominal_template, .nominal, e.decl.int(), id, @backingInt(row.scheme), bundle, params);
            const body = writer.terms.get(writer.schemes.items[@backingInt(row.scheme)].body.int());
            const range = writer.extra.items[body.lhs];
            const children = writer.extra.items[body.lhs + 1 ..][0..range];
            for (children[1..]) |term| try arguments.append(gpa, @fromBackingInt(term));
        }
        try owners.append(gpa, row);
    }
    out.owners = owners.toOwnedSlice();
    out.constructors = ctors.toOwnedSlice();
    out.arguments = try arguments.toOwnedSlice(gpa);
    try writer.attach(&out.types);
    if (!try out.verify(gpa, cx.interner)) return error.InvalidLayout;
    if (!try out.covers(gpa, cx.bir, cx.graph, cx.types, cx.module, cx.interner, &cx.interfaces[cx.module.int()], in.work)) return error.IncompleteLayout;
    return out;
}
