//! Partial symbolic suspension evidence (workers-continuation-plan.md).
//! This artifact does not certify generated continuations or change Task's ABI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Dispatch = @import("Dispatch.zig");
const Context = @import("Context.zig");
const Effects = @import("Effects.zig");
const Schemes = @import("Schemes.zig");
const Types = @import("Types.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");

pub const schema_version: u32 = 1;
pub const Scope = struct { decl: Bir.DeclIndex, scheme: Interface.SchemeIndex, start: u32, len: u32 };
pub const Site = struct { inst: Bir.Inst.Index, type: Interface.TermIndex, own: Dispatch.Suspend, body: Dispatch.Suspend, tag: Bir.Inst.Tag };
pub const Artifact = struct {
    /// False is absent evidence, never a complete empty plan.
    present: bool = false,
    scopes: std.MultiArrayList(Scope).Slice = .empty,
    sites: std.MultiArrayList(Site).Slice = .empty,
    types: Interface = .empty,

    pub const empty: Artifact = .{};
    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        a.scopes.deinit(gpa);
        a.sites.deinit(gpa);
        a.types.deinit(gpa);
        a.* = .empty;
    }

    fn verifyShape(a: *const Artifact, interner: *const InternPool.Global) bool {
        if (!a.present or a.scopes.len == 0) return a.scopes.len == 0 and a.sites.len == 0 and emptyTypes(&a.types);
        inline for (.{ "values", "types", "ctors", "schemas", "schema_members", "schema_ctors", "hidden_types", "elements", "attributes", "events", "ownership" }) |field| {
            if (@field(a.types, field).len != 0) return false;
        }
        if (!iface_bytes.verify(&a.types, interner) or a.types.schemes.len != a.scopes.len) return false;
        const tags = a.types.terms.items(.tag);
        const lhs = a.types.terms.items(.lhs);
        var end: u64 = 0;
        var previous_decl: ?u32 = null;
        for (0..a.scopes.len) |i| {
            const scope = a.scopes.get(i);
            if (@backingInt(scope.scheme) != i or scope.start != end or scope.len == 0) return false;
            if (previous_decl) |previous| if (scope.decl.int() <= previous) return false;
            previous_decl = scope.decl.int();
            if (scope.len > a.sites.len - end) return false;
            end += scope.len;
            const scheme = a.types.schemes[i];
            if (scheme.body.int() >= tags.len or tags[scheme.body.int()] != .tuple) return false;
            const at = lhs[scheme.body.int()];
            if (at >= a.types.extra.len or a.types.extra[at] != @as(u64, scope.len) + 2) return false;
            if (@as(u64, at) + 1 + a.types.extra[at] > a.types.extra.len) return false;
            var previous_inst: ?u32 = null;
            for (0..scope.len) |j| {
                const site = a.sites.get(scope.start + j);
                if (previous_inst) |previous| if (site.inst.int() <= previous) return false;
                previous_inst = site.inst.int();
                if (site.own == .no and site.body == .no) return false;
                if (site.type.int() != a.types.extra[at + 3 + j]) return false;
            }
        }
        for (tags, 0..) |tag, i| {
            if (tag == .err) return false;
            if (tag == .record) {
                const fields = a.types.range(lhs[i]);
                var previous: ?InternPool.Symbol = null;
                var f: usize = 0;
                while (f < fields.len) : (f += 2) {
                    const name = a.types.symbol(@fromBackingInt(fields[f]));
                    if (previous) |prior| if (!std.mem.lessThan(u8, interner.slice(prior), interner.slice(name))) return false;
                    previous = name;
                }
            }
        }
        return end == a.sites.len;
    }

    /// Validate compact types independently of the expired source TypeStore.
    pub fn verify(a: *const Artifact, gpa: Allocator, interner: *const InternPool.Global) Allocator.Error!bool {
        if (!a.verifyShape(interner)) return false;
        return verifyTypes(gpa, &a.types);
    }

    /// Called before installing a cache hit, while the graph/type table exists.
    pub fn verifyAgainstBir(a: *const Artifact, gpa: Allocator, bir: *const Bir, dispatch: *const Dispatch, graph: *const Graph, types: *const Types) Allocator.Error!bool {
        if (!a.present) return false;
        const effects = dispatch.effect_sites;
        var next: usize = 0;
        for (0..a.scopes.len) |scope_index| {
            const scope = a.scopes.get(scope_index);
            if (scope.decl.int() >= bir.decls.len) return false;
            const owner = bir.decls[scope.decl.int()];
            for (0..scope.len) |j| {
                const site = a.sites.get(scope.start + j);
                if (site.inst.int() < owner.inst_start.int() or site.inst.int() >= owner.inst_end.int() or site.inst.int() >= bir.insts.len) return false;
                var tag = bir.insts.items(.tag)[site.inst.int()];
                // Replay the checked nullary-dot kind without mutating BIR.
                if (tag == .field_access) if (dispatch.siteOf(site.inst)) |callee| {
                    if (callee.callee != .none) tag = .method_call;
                };
                if (tag != site.tag) return false;
                while (next < effects.len and effects[next].own == .no and effects[next].body == .no) next += 1;
                if (next == effects.len) return false;
                const effect = effects[next];
                if (effect.inst != site.inst or effect.own != site.own or effect.body != site.body) return false;
                next += 1;
            }
        }
        while (next < effects.len and effects[next].own == .no and effects[next].body == .no) next += 1;
        if (next != effects.len) return false;
        const resolved = try gpa.alloc(TypeStore.TypeId, a.types.type_refs.len);
        defer gpa.free(resolved);
        for (a.types.type_refs, resolved) |ref, *id| {
            id.* = types.find(graph, ref.package, a.types.symbol(ref.module), a.types.symbol(ref.name));
            if (id.* == .none) return false;
        }
        for (a.types.terms.items(.tag), 0..) |tag, i| {
            if (tag != .app and tag != .alias) continue;
            const term = a.types.terms.get(i);
            const declaration = types.entry(resolved[term.lhs]);
            if ((tag == .alias) != (declaration.kind == .alias) or a.types.range(term.rhs).len != declaration.arity) return false;
        }
        return true;
    }
};

const PrivateTerms = @import("PrivateTerms.zig");
const verifyTypes = PrivateTerms.verifyTypes;
const verifyTypesWork = PrivateTerms.verifyTypesWork;
const PathWork = PrivateTerms.PathWork;
const no_projection = PrivateTerms.no_projection;
const pathValid = PrivateTerms.pathValid;
fn emptyTypes(types: *const Interface) bool {
    inline for (.{ "values", "types", "ctors", "schemas", "schema_members", "schema_ctors", "hidden_types", "elements", "attributes", "events", "ownership", "schemes", "terms", "extra", "type_refs", "symbols" }) |field| {
        if (@field(types.*, field).len != 0) return false;
    }
    return true;
}

pub const Input = struct {
    solved_capture: ?*@import("SolvedRepresentations.zig").Capture = null,
    cx: *const Context,
    gpa: Allocator,
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    bir: *const Bir,
    effects: *Effects,
    dispatch: *const Dispatch,
    crossing: []const bool = &.{},
    decl_scheme: []const TypeStore.Var.Optional,
    decl_body: []const TypeStore.Var.Optional,
    inst_type: []const TypeStore.Var.Optional,
};
pub const Error = Allocator.Error || error{ MissingEvidence, BadScope, TooDeep };

pub fn build(in: Input) Error!Artifact {
    var has_sites = false;
    for (in.dispatch.effect_sites) |site| {
        if (site.own != .no or site.body != .no) {
            has_sites = true;
            break;
        }
    }
    if (!has_sites) return .{ .present = true };
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(in.gpa);
    var scopes: std.MultiArrayList(Scope) = .empty;
    defer scopes.deinit(in.gpa);
    var sites: std.MultiArrayList(Site) = .empty;
    defer sites.deinit(in.gpa);
    var writer: Schemes.Writer = .init(in.gpa, in.store, in.interner, in.types, 0);
    defer writer.deinit();
    var bodies = in.cx.builder(.flex, TypeStore.generalized);
    defer bodies.deinit();
    bodies.shallow = true;
    writer.bodies = &bodies;
    writer.crossing = in.crossing;
    var roots: std.ArrayList(TypeStore.Var) = .empty;
    defer roots.deinit(in.scratch);
    var bindings: std.ArrayList(Schemes.Writer.RootBinding) = .empty;
    defer bindings.deinit(in.scratch);
    var stacks: Walk.Stacks = .{};
    defer stacks.deinit(in.scratch);
    const function_types = try in.scratch.alloc(TypeStore.Var.Optional, in.bir.insts.len);
    defer in.scratch.free(function_types);
    @memset(function_types, .none);
    for (in.effects.fns.items) |function| {
        if (function.inst >= function_types.len) return error.MissingEvidence;
        function_types[function.inst] = function.v.toOptional();
    }
    var at: usize = 0;
    for (in.bir.decls, 0..) |owner, di| {
        roots.clearRetainingCapacity();
        bindings.clearRetainingCapacity();
        const start: u32 = @intCast(sites.len);
        while (at < in.dispatch.effect_sites.len and in.dispatch.effect_sites[at].inst.int() < owner.inst_end.int()) : (at += 1) {
            const effect = in.dispatch.effect_sites[at];
            if (effect.own == .no and effect.body == .no) continue;
            if (effect.inst.int() < owner.inst_start.int() or effect.inst.int() >= in.inst_type.len) return error.MissingEvidence;
            if (roots.items.len == 0) {
                try roots.append(in.scratch, in.decl_scheme[di].unwrap() orelse return error.MissingEvidence);
                try roots.append(in.scratch, in.decl_body[di].unwrap() orelse return error.MissingEvidence);
                if (owner.annotation != .none) {
                    const parameters = in.effects.annotation_readings.of(di, owner.annotation.unwrap().?) orelse return error.BadScope;
                    for (parameters.start..@as(usize, parameters.start) + parameters.len) |i| {
                        const binding = in.effects.annotation_readings.bindings.get(i);
                        try bindings.append(in.scratch, .{ .scheme = binding.scheme, .body = binding.body.unwrap() orelse return error.BadScope });
                    }
                }
            }
            const root = function_types[effect.inst.int()].unwrap() orelse in.inst_type[effect.inst.int()].unwrap() orelse return error.MissingEvidence;
            if (try Walk.hasError(in.store, &stacks, in.scratch, root) != .clean) return error.MissingEvidence;
            try roots.append(in.scratch, root);
            try sites.append(in.gpa, .{ .inst = effect.inst, .type = .none, .own = effect.own, .body = effect.body, .tag = in.bir.insts.items(.tag)[effect.inst.int()] });
        }
        if (sites.len == start) continue;
        const requirements = in.dispatch.declRequirements(@intCast(di));
        const identities = in.dispatch.declIdentities(@intCast(di));
        const quantifiers = try in.scratch.alloc(u16, identities.len);
        defer in.scratch.free(quantifiers);
        for (identities, quantifiers) |identity, *quantifier| {
            if (identity >= requirements.len) return error.MissingEvidence;
            quantifier.* = requirements[identity].quantified;
        }
        writer.identities = quantifiers;
        writer.effects = .{ .effects = in.effects, .decl = @intCast(di) };
        const scheme = try writer.addScopedRoots(roots.items, bindings.items);
        if (writer.too_deep) return error.TooDeep;
        const root = writer.schemes.items[@backingInt(scheme)].body;
        const tuple = writer.terms.items(.lhs)[root.int()];
        for (sites.items(.type)[start..], 0..) |*site_type, i| site_type.* = @fromBackingInt(@intCast(writer.extra.items[tuple + 3 + i]));
        try scopes.append(in.gpa, .{ .decl = @fromBackingInt(@intCast(di)), .scheme = scheme, .start = start, .len = @intCast(sites.len - start) });
    }
    if (at != in.dispatch.effect_sites.len) return error.MissingEvidence;
    out.scopes = scopes.toOwnedSlice();
    out.sites = sites.toOwnedSlice();
    try writer.attach(&out.types);
    if (!try out.verify(in.gpa, in.interner)) return error.BadScope;
    return out;
}

pub const magic = "BENICNT\x00";
const header_bytes = 24;
pub fn write(gpa: Allocator, a: *const Artifact, interner: *const InternPool.Global) Allocator.Error![]u8 {
    if (!a.present) return gpa.alloc(u8, 0);
    if (a.scopes.len == 0 and a.sites.len == 0 and emptyTypes(&a.types)) {
        const empty = try gpa.alloc(u8, header_bytes);
        @memset(empty, 0);
        @memcpy(empty[0..8], magic);
        put(empty, 8, schema_version);
        return empty;
    }
    const encoded = try iface_bytes.write(gpa, &a.types, interner);
    defer gpa.free(encoded);
    const out = try gpa.alloc(u8, header_bytes + a.scopes.len * 16 + a.sites.len * 16 + encoded.len);
    @memset(out, 0);
    @memcpy(out[0..8], magic);
    put(out, 8, schema_version);
    put(out, 12, @intCast(a.scopes.len));
    put(out, 16, @intCast(a.sites.len));
    put(out, 20, @intCast(encoded.len));
    var at: usize = header_bytes;
    for (0..a.scopes.len) |scope_index| {
        const scope = a.scopes.get(scope_index);
        put(out, at, scope.decl.int());
        put(out, at + 4, @backingInt(scope.scheme));
        put(out, at + 8, scope.start);
        put(out, at + 12, scope.len);
        at += 16;
    }
    for (0..a.sites.len) |i| {
        const site = a.sites.get(i);
        put(out, at, site.inst.int());
        put(out, at + 4, site.type.int());
        out[at + 8] = @intCast(@backingInt(site.own));
        out[at + 9] = @intCast(@backingInt(site.body));
        out[at + 10] = @intCast(@backingInt(site.tag));
        at += 16;
    }
    @memcpy(out[at..], encoded);
    return out;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

pub const ReadError = iface_bytes.ReadError || error{BadPlan};
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Artifact {
    return decode(gpa, bytes, interner, false);
}
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Artifact {
    return decode(gpa, bytes, interner, true);
}
fn decode(gpa: Allocator, bytes: []const u8, interner: anytype, comptime growing: bool) ReadError!Artifact {
    if (bytes.len == 0) return .empty;
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..8], magic) or get(bytes, 8) != schema_version) return error.BadPlan;
    const scopes = get(bytes, 12);
    const sites = get(bytes, 16);
    const record = get(bytes, 20);
    const start = @as(u64, header_bytes) + @as(u64, scopes) * 16 + @as(u64, sites) * 16;
    if (start + record != bytes.len) return error.BadPlan;
    if (record == 0) {
        if (scopes != 0 or sites != 0) return error.BadPlan;
        return .{ .present = true };
    }
    if (scopes == 0) return error.BadPlan;
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(gpa);
    var scope_rows: std.MultiArrayList(Scope) = .empty;
    defer scope_rows.deinit(gpa);
    try scope_rows.ensureTotalCapacity(gpa, scopes);
    var site_rows: std.MultiArrayList(Site) = .empty;
    defer site_rows.deinit(gpa);
    try site_rows.ensureTotalCapacity(gpa, sites);
    var at: usize = header_bytes;
    for (0..scopes) |_| {
        scope_rows.appendAssumeCapacity(.{ .decl = @fromBackingInt(@intCast(get(bytes, at))), .scheme = @fromBackingInt(@intCast(get(bytes, at + 4))), .start = get(bytes, at + 8), .len = get(bytes, at + 12) });
        at += 16;
    }
    for (0..sites) |_| {
        if (bytes[at + 8] > 2 or bytes[at + 9] > 2 or !std.mem.allEqual(u8, bytes[at + 11 ..][0..5], 0)) return error.BadPlan;
        site_rows.appendAssumeCapacity(.{ .inst = @fromBackingInt(@intCast(get(bytes, at))), .type = @fromBackingInt(@intCast(get(bytes, at + 4))), .own = @fromBackingInt(bytes[at + 8]), .body = @fromBackingInt(bytes[at + 9]), .tag = std.enums.fromInt(Bir.Inst.Tag, bytes[at + 10]) orelse return error.BadPlan });
        at += 16;
    }
    out.scopes = scope_rows.toOwnedSlice();
    out.sites = site_rows.toOwnedSlice();
    out.types = if (growing) try iface_bytes.readGrowing(gpa, bytes[at..], interner) else try iface_bytes.read(gpa, bytes[at..], interner);
    if (!try out.verify(gpa, interner)) return error.BadPlan;
    return out;
}

fn specimen(gpa: Allocator) !Artifact {
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(gpa);
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    try terms.append(gpa, .{ .tag = .unit, .lhs = 0, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .tuple, .lhs = 0, .rhs = 0 });
    out.types.terms = terms.toOwnedSlice();
    out.types.extra = try gpa.dupe(u32, &.{ 3, 0, 0, 0 });
    out.types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .quantified_start = 4, .quantified_count = 0, .body = @fromBackingInt(1) }});
    var scopes: std.MultiArrayList(Scope) = .empty;
    defer scopes.deinit(gpa);
    try scopes.append(gpa, .{ .decl = @fromBackingInt(0), .scheme = @fromBackingInt(0), .start = 0, .len = 1 });
    out.scopes = scopes.toOwnedSlice();
    var sites: std.MultiArrayList(Site) = .empty;
    defer sites.deinit(gpa);
    try sites.append(gpa, .{ .inst = @fromBackingInt(0), .type = @fromBackingInt(0), .own = .yes, .body = .no, .tag = .call });
    out.sites = sites.toOwnedSlice();
    return out;
}

test "continuation plan codec retains a nonempty scope and rejects malformed evidence" {
    const gpa = std.testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    const empty_bytes = try write(gpa, &.{ .present = true }, &global);
    defer gpa.free(empty_bytes);
    try std.testing.expectEqual(@as(usize, header_bytes), empty_bytes.len);
    var empty = try read(gpa, empty_bytes, &global);
    defer empty.deinit(gpa);
    try std.testing.expectEqualDeep(Artifact{ .present = true }, empty);
    var absent = try read(gpa, &.{}, &global);
    defer absent.deinit(gpa);
    try std.testing.expectEqualDeep(Artifact.empty, absent);
    var original = try specimen(gpa);
    defer original.deinit(gpa);
    try std.testing.expect(try original.verify(gpa, &global));
    const bytes = try write(gpa, &original, &global);
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes, &global);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(original.scopes.len, loaded.scopes.len);
    for (0..original.scopes.len) |i| try std.testing.expectEqualDeep(original.scopes.get(i), loaded.scopes.get(i));
    try std.testing.expectEqual(original.sites.len, loaded.sites.len);
    for (0..original.sites.len) |i| try std.testing.expectEqualDeep(original.sites.get(i), loaded.sites.get(i));
    const again = try write(gpa, &loaded, &global);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    put(bad, 8, 0);
    try std.testing.expectError(error.BadPlan, read(gpa, bad, &global));
    @memcpy(bad, bytes);
    put(bad, header_bytes + 16 + 4, std.math.maxInt(u32));
    try std.testing.expectError(error.BadPlan, read(gpa, bad, &global));
    @memcpy(bad, bytes);
    bad[header_bytes + 16 + 11] = 1;
    try std.testing.expectError(error.BadPlan, read(gpa, bad, &global));
    try std.testing.expectError(error.BadPlan, read(gpa, bytes[0 .. bytes.len - 1], &global));
}

test "continuation plan rejects structural alias cycles free parameters and invalid effect paths" {
    const gpa = std.testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    for (0..5) |mutation| {
        var original = try specimen(gpa);
        defer original.deinit(gpa);
        switch (mutation) {
            0 => original.types.terms.items(.tag)[0] = .tuple,
            1 => original.types.terms.items(.tag)[0] = .@"var",
            2 => {
                const module_name = try global.getOrPut(gpa, "AliasOwner");
                const type_name = try global.getOrPut(gpa, "Alias");
                original.types.symbols = try gpa.dupe(InternPool.Symbol, &.{ module_name, type_name });
                original.types.type_refs = try gpa.dupe(Interface.TypeRef, &.{.{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(1), .body = @fromBackingInt(2) }});
                var terms = original.types.terms.toMultiArrayList();
                defer terms.deinit(gpa);
                original.types.terms = .empty;
                try terms.append(gpa, .{ .tag = .alias, .lhs = 0, .rhs = 4 });
                original.types.terms = terms.toOwnedSlice();
                gpa.free(original.types.extra);
                original.types.extra = try gpa.dupe(u32, &.{ 3, 0, 0, 0, 0 });
            },
            3, 4 => {
                gpa.free(original.types.extra);
                original.types.extra = try gpa.dupe(u32, &.{ 3, 0, 0, 0, 1, 0, 0, 1, 0, if (mutation == 4) 1 else 0, 1, (@as(u32, 3) << 28) | 3 });
                @constCast(original.types.schemes)[0].effects = 4;
            },
            else => unreachable,
        }
        const bytes = try write(gpa, &original, &global);
        defer gpa.free(bytes);
        try std.testing.expectError(error.BadPlan, read(gpa, bytes, &global));
    }
}

test "fuzz: continuation plan truncation and byte mutations never produce unverified evidence" {
    try @import("../fuzzing.zig").skipUnlessFuzzing();
    const gpa = std.testing.allocator;
    var global = try InternPool.Global.init(gpa);
    defer global.deinit(gpa);
    var original = try specimen(gpa);
    defer original.deinit(gpa);
    const bytes = try write(gpa, &original, &global);
    defer gpa.free(bytes);
    for (0..bytes.len) |length| {
        var loaded = read(gpa, bytes[0..length], &global) catch continue;
        defer loaded.deinit(gpa);
        try std.testing.expect(try loaded.verify(gpa, &global));
    }
    const mutated = try gpa.dupe(u8, bytes);
    defer gpa.free(mutated);
    for (0..bytes.len) |at| {
        @memcpy(mutated, bytes);
        mutated[at] ^= 0xff;
        var loaded = read(gpa, mutated, &global) catch continue;
        defer loaded.deinit(gpa);
        try std.testing.expect(try loaded.verify(gpa, &global));
    }
}

test "continuation plan paths preserve alias compression while rejecting wrong structural steps" {
    const gpa = std.testing.allocator;
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    for ([_]Interface.Term{
        .{ .tag = .unit, .lhs = 0, .rhs = 0 },
        .{ .tag = .func, .lhs = 2, .rhs = 2 },
        .{ .tag = .unit, .lhs = 0, .rhs = 0 },
        .{ .tag = .alias, .lhs = 0, .rhs = 2 },
        .{ .tag = .alias, .lhs = 1, .rhs = 2 },
        .{ .tag = .func, .lhs = 0, .rhs = 2 },
    }) |term| try terms.append(gpa, term);
    var types: Interface = .empty;
    types.terms = terms.slice();
    types.extra = &.{ 1, 1, 0 };
    types.type_refs = &.{
        .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(4) },
        .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(5) },
    };
    try std.testing.expect(try verifyTypes(gpa, &types));
    const heads: [6]u32 = @splat(no_projection);
    // The checked source compressed A -> B -> function into A -> function.
    // Its explicit A expansion reaches the same terminal and nested callback.
    try std.testing.expect(try pathValid(gpa, &types, &heads, 3, &.{6 << 28}, null));
    try std.testing.expect(try pathValid(gpa, &types, &heads, 3, &.{ 6 << 28, 0 }, null));
    // A tuple step or missing parameter cannot be justified by transparency.
    try std.testing.expect(!try pathValid(gpa, &types, &heads, 3, &.{ 6 << 28, 3 << 28 }, null));
    try std.testing.expect(!try pathValid(gpa, &types, &heads, 3, &.{ 6 << 28, 1 }, null));
}

test "continuation plan compact alias heads have linear work and retained frames" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 8, 32, 64, 128, 512, 2048 }) |levels| {
        var terms: std.MultiArrayList(Interface.Term) = .empty;
        defer terms.deinit(gpa);
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(gpa);
        var refs: std.ArrayList(Interface.TypeRef) = .empty;
        defer refs.deinit(gpa);
        try extra.append(gpa, 0);
        try terms.append(gpa, .{ .tag = .@"var", .lhs = 0, .rhs = 0 });
        try terms.append(gpa, .{ .tag = .func, .lhs = 0, .rhs = 2 });
        try terms.append(gpa, .{ .tag = .unit, .lhs = 0, .rhs = 0 });
        try refs.append(gpa, .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(0) });
        for (0..levels) |level| {
            const inner: u32 = @intCast(terms.len);
            const args: u32 = @intCast(extra.items.len);
            try extra.appendSlice(gpa, &.{ 1, 0, 1, inner });
            try terms.append(gpa, .{ .tag = .alias, .lhs = @intCast(level), .rhs = args });
            try terms.append(gpa, .{ .tag = .alias, .lhs = @intCast(level), .rhs = args + 2 });
            try refs.append(gpa, .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(@intCast(terms.len - 1)) });
        }
        const args: u32 = @intCast(extra.items.len);
        try extra.appendSlice(gpa, &.{ 1, 1 });
        const root: Interface.TermIndex = @fromBackingInt(@intCast(terms.len));
        try terms.append(gpa, .{ .tag = .alias, .lhs = @intCast(levels), .rhs = args });
        const effects: u32 = @intCast(extra.items.len);
        try extra.appendSlice(gpa, &.{ 1, 0, 0, 1, 0, 0, 0 });
        const schemes = [_]Interface.Scheme{.{ .body = root, .quantified_count = 0, .quantified_start = 0, .effects = effects }};
        var types: Interface = .empty;
        types.terms = terms.slice();
        types.extra = extra.items;
        types.type_refs = refs.items;
        types.schemes = &schemes;
        var work: PathWork = .{};
        try std.testing.expect(try verifyTypesWork(gpa, &types, &work));
        try std.testing.expectEqual(types.terms.len, work.heads);
        if (work.steps > 2 * types.terms.len) std.debug.print("compact alias levels={d} nodes={d} steps={d} frames={d}\n", .{ levels, types.terms.len, work.steps, work.frames });
        try std.testing.expect(work.steps <= 2 * types.terms.len);
        try std.testing.expect(work.frames <= levels + 1);
        try std.testing.expectEqual(@as(usize, 2), work.steps);
        try std.testing.expectEqual(@as(usize, 0), work.frames);
    }
}

test "continuation plan record names reject duplicates and require canonical text order" {
    const gpa = std.testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    const a = try interner.getOrPut(gpa, "a");
    const b = try interner.getOrPut(gpa, "b");
    for (0..4) |mutation| {
        var original = try specimen(gpa);
        defer original.deinit(gpa);
        // In memory local slots0/1 deliberately name b/a, not text order.
        original.types.symbols = try gpa.dupe(InternPool.Symbol, if (mutation == 3) &.{ a, a } else &.{ b, a });
        var terms = original.types.terms.toMultiArrayList();
        original.types.terms = .empty;
        defer terms.deinit(gpa);
        try terms.append(gpa, .{ .tag = .empty_record, .lhs = 0, .rhs = 0 });
        try terms.append(gpa, .{ .tag = .unit, .lhs = 0, .rhs = 0 });
        terms.items(.tag)[0] = .record;
        terms.items(.lhs)[0] = 4;
        terms.items(.rhs)[0] = 2;
        original.types.terms = terms.toOwnedSlice();
        gpa.free(original.types.extra);
        original.types.extra = try gpa.dupe(u32, &.{ 3, 0, 0, 0, 4, if (mutation == 1) 0 else 1, 3, if (mutation == 1 or mutation == 2) 1 else 0, 3 });
        const bytes = try write(gpa, &original, &interner);
        defer gpa.free(bytes);
        if (mutation == 0) {
            var loaded = try read(gpa, bytes, &interner);
            defer loaded.deinit(gpa);
            try std.testing.expect(try loaded.verify(gpa, &interner));
        } else {
            try std.testing.expectError(error.BadPlan, read(gpa, bytes, &interner));
        }
    }
}

test "continuation plan mixed alias heads preserve explicit expansion and parameter shadowing" {
    const gpa = std.testing.allocator;
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    for ([_]Interface.Term{
        .{ .tag = .@"var", .lhs = 0, .rhs = 0 },
        .{ .tag = .unit, .lhs = 0, .rhs = 0 },
        .{ .tag = .func, .lhs = 0, .rhs = 1 },
        .{ .tag = .alias, .lhs = 0, .rhs = 1 },
        .{ .tag = .func, .lhs = 1, .rhs = 0 },
        .{ .tag = .alias, .lhs = 1, .rhs = 1 },
        .{ .tag = .alias, .lhs = 0, .rhs = 3 },
        .{ .tag = .alias, .lhs = 0, .rhs = 5 },
        .{ .tag = .alias, .lhs = 2, .rhs = 7 },
    }) |term| try terms.append(gpa, term);
    // Id a=a; Hold a=a→a; Inner a=Id(Hold a); root=Inner(Id(⊤→⊤)).
    const refs = [_]Interface.TypeRef{
        .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(0) },
        .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(4) },
        .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(6) },
    };
    const expand: u32 = 6 << 28;
    const words = [_]u32{ 0, 1, 0, 1, 5, 1, 2, 1, 7, 1, 0, 0, 2, 0, 0, 4, expand, expand, 0, expand, 0, 0, 2, 0, expand };
    const schemes = [_]Interface.Scheme{.{ .body = @fromBackingInt(8), .quantified_count = 0, .quantified_start = 0, .effects = 9 }};
    var types: Interface = .empty;
    types.terms = terms.slice();
    types.extra = &words;
    types.type_refs = &refs;
    types.schemes = &schemes;
    var work: PathWork = .{};
    try std.testing.expect(try verifyTypesWork(gpa, &types, &work));
    try std.testing.expectEqual(types.terms.len, work.heads);
    try std.testing.expect(work.frames <= 2);
    const n = no_projection;
    const heads = [_]u32{ 0, n, n, 0, n, n, n, n, n };
    // A second expansion after the actual argument has become a function is
    // invalid; projection must not skip or invent an explicit alias boundary.
    try std.testing.expect(!try pathValid(gpa, &types, &heads, 8, &.{ expand, expand, 0, expand, expand }, null));
    try std.testing.expect(!try pathValid(gpa, &types, &heads, 8, &.{expand | 1}, null));
}
