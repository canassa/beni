//! Per-build native recipe disposition. No serialized or inspector authority.
//! workers-native-emission-authority.md §§8–9: initial closed Program slice.
const std = @import("std");
const Bindings = @import("Bindings.zig");
const Source = @import("Source.zig");
const Exposure = @import("Exposure.zig");
const Build = @import("../check/RealmBuild.zig");
const Consume = @import("../entry/RealmConsume.zig");
const Plan = @import("../entry/Plan.zig");
const Bir = @import("../bir/Bir.zig");
const Reach = @import("../js/Reach.zig");
const Interface = @import("../resolve/Interface.zig");
const Allocator = std.mem.Allocator;
/// Immutable lowering ABI codes, recorded in EmitPack.Fact.where (§17).
pub const Abi = enum(u8) { text_encoder_unit_constructor_v1 = @import("../js/EmitPack.zig").native_recipe_abi };
pub const Disposition = enum { @"unreachable", ready, refused };
pub const Reason = enum { none, selection, open_library, callback_contract, missing_root, unresolved_root, realm, escape, deferred_use };
pub const Recipe = struct {
    target: Build.QualifiedDecl,
    native_type: Interface.TypeIndex,
    scheme: Interface.SchemeIndex,
    digest: [32]u8,
    abi: Abi,
    disposition: Disposition = .refused,
    reason: Reason = .selection,
};
pub const Witness = struct {
    source: Build.Realms.Source,
    port: Build.PortId,
    call: Build.CallId,
    kind: @FieldType(Build.ValueUse, "kind"),
    exposure: u8,
};
pub const Table = struct {
    recipe: ?Recipe = null,
    selected: ?Build.QualifiedDecl = null,
    kind: Plan.KindIndex = .none,
    realm: ?Plan.Realm = null,
    witnesses: std.MultiArrayList(Witness) = .empty,
    work: Exposure.Work = .{},
    pub fn deinit(t: *Table, a: Allocator) void {
        t.witnesses.deinit(a);
        t.* = .{};
    }
    pub fn recipeMatches(t: *const Table, target: Build.QualifiedDecl, abi: u8) bool {
        const recipe = t.recipe orelse return false;
        return @backingInt(recipe.abi) == abi and std.meta.eql(recipe.target, target);
    }
    pub fn ready(t: *const Table, target: Build.QualifiedDecl) bool {
        const recipe = t.recipe orelse return false;
        return recipe.disposition == .ready and std.meta.eql(recipe.target, target);
    }
};
/// Positive-only query; unavailable false must never match a recorded false.
pub fn matchesRecipeFact(table: ?*const Table, target: Build.QualifiedDecl, fact: @import("../js/EmitPack.zig").Fact) bool {
    if (fact.question != .native_recipe or !fact.validNativeRecipe()) return false;
    const current = table orelse return false;
    return current.recipeMatches(target, fact.where);
}
pub const Input = struct {
    registry: *const Bindings.Registry,
    source: Build.Input,
    selection: Consume.Input,
    /// Actual final current emission reachability, separate from CompactGraph.
    live: *const Reach.Result,
    /// Actual unconsumed generic constant lowering, not retention.
    evaluated: []const Build.QualifiedDecl = &.{},
    profile: ?*@import("../Profile.zig") = null,
};
pub const Error = Consume.Error || Exposure.Error || error{InvalidNativeAuthority};
pub fn prepare(a: Allocator, in: Input) Error!Table {
    var out: Table = .{ .selected = in.selection.selected, .kind = in.selection.plan.selected };
    errdefer out.deinit(a);
    const installed = in.registry.text_encoder orelse return out;
    if (installed.candidate.schema != 1 or installed.candidate.identity != .text_encoder_v1 or
        installed.candidate.adapter_revision != 1) return error.InvalidNativeAuthority;
    const target: Build.QualifiedDecl = .{ .module = installed.module, .declaration = installed.checked.declaration };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(Source.provenance, &digest, .{});
    out.recipe = .{ .target = target, .native_type = installed.checked.type_index, .scheme = installed.checked.scheme, .digest = digest, .abi = .text_encoder_unit_constructor_v1 };
    if (in.live.modules.len != in.source.graph.count() or in.live.dispatch.len != in.source.dispatch.len or
        in.live.provenance.ptr != in.source.provenance.ptr or in.live.provenance.len != in.source.provenance.len) return error.InvalidNativeAuthority;
    for (in.live.dispatch, 0..) |table, i| if (table != &in.source.dispatch[i]) return error.InvalidNativeAuthority;
    if (!in.live.decl(target.module, target.declaration)) {
        out.recipe.?.disposition = .@"unreachable";
        out.recipe.?.reason = .none;
        return out;
    }
    if (in.source.graph != in.selection.graph or in.source.native_seeds.len != 0) return error.InvalidNativeAuthority;
    if (in.selection.library) {
        out.recipe.?.reason = .open_library;
        return out;
    }
    const plan = in.selection.plan;
    if (in.selection.selected == null or !plan.validated or plan.selected == .none) return out;
    if (@backingInt(plan.selected) >= plan.kinds.len) return error.InvalidNativeAuthority;
    const kind = plan.kinds.get(@backingInt(plan.selected));
    out.realm = kind.realm;
    if (kind.constructors.len != 0 or kind.launches.len != 0 or kind.roles.len != 0 or kind.arity != 0) {
        out.recipe.?.reason = .callback_contract;
        return out;
    }
    const seed: Build.Realms.NativeSeed = .{ .target = target, .allowed = installed.candidate.realm_mask, .binding_digest = digest, .contract = .unit_to_native };
    var source = in.source;
    source.native_seeds = &.{seed};
    var built = try Build.build(a, source);
    defer built.deinit(a);
    if (in.profile) |profile| {
        profile.addCounter(.realm_builder_runs, 1);
        profile.addCounter(.realm_value_field_steps, built.work.value.field_steps);
    }
    const birs = try a.alloc(*const Bir, in.source.graph.count());
    defer a.free(birs);
    var retained: std.ArrayList(Build.QualifiedDecl) = .empty;
    defer retained.deinit(a);
    for (birs, 0..) |*bir, mi| {
        const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@intCast(mi));
        bir.* = in.source.artifacts.bir(in.source.graph.moduleFile(module));
        for (bir.*.decls, 0..) |decl, di| {
            if (!in.live.decl(module, di) or (decl.kind != .value and decl.kind != .foreign_value)) continue;
            try retained.append(a, .{ .module = module, .declaration = @intCast(di) });
        }
    }
    for (in.evaluated) |q| {
        if (q.module.int() >= birs.len or q.declaration >= birs[q.module.int()].decls.len or !in.live.decl(q.module, q.declaration)) return error.InvalidNativeAuthority;
        const bir = birs[q.module.int()];
        if (bir.decls[q.declaration].kind != .value or @import("../check/Convention.zig").definitionOf(&in.source.dispatch[q.module.int()], bir, q.declaration) != .constant) return error.InvalidNativeAuthority;
    }
    var selection = in.selection;
    if (selection.emission_retained.len != 0 or selection.emission_evaluated.len != 0) return error.InvalidNativeAuthority;
    selection.emission_retained = retained.items;
    selection.emission_evaluated = in.evaluated;
    var consumed = try Consume.consume(a, selection, &built);
    defer consumed.deinit(a);
    var exposure = try Exposure.solve(a, &built, birs, in.source.interfaces);
    defer exposure.deinit(a);
    out.work = exposure.work;
    if (in.profile) |profile| {
        profile.addCounter(.native_exposure_nodes, exposure.work.nodes);
        profile.addCounter(.native_exposure_edges, exposure.work.edges);
        profile.addCounter(.native_exposure_transitions, exposure.work.transitions);
        profile.addCounter(.native_exposure_deliveries, exposure.work.deliveries);
    }
    if (consumed.work.root_misses != 0 or consumed.roots.len < 2) {
        out.recipe.?.reason = .missing_root;
        return out;
    }
    for (0..consumed.roots.len) |i| {
        const root = consumed.roots.get(i);
        if (root.exec == .none) {
            out.recipe.?.reason = .unresolved_root;
            return out;
        }
        const root_bits = try exposure.exec(root.exec);
        if (root.mode != .definite and root_bits != 0) {
            out.recipe.?.reason = .deferred_use;
            return out;
        }
        if (root_bits & Exposure.unresolved != 0) {
            out.recipe.?.reason = .unresolved_root;
            return out;
        }
        const fact = consumed.facts.facts.get(@backingInt(root.exec));
        if (fact.incomplete or fact.allowed & Consume.realmBit(kind.realm) == 0) {
            out.recipe.?.reason = .realm;
            return out;
        }
    }
    var reason: Reason = .none;
    for (birs, 0..) |bir, mi| {
        const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@intCast(mi));
        const live = in.live.of(module);
        if (live.lifts.count() != 0 or live.derived.count() != 0 or live.twins.count() != 0 or live.schemas.count() != 0) reason = .deferred_use;
        for (bir.decls, 0..) |decl, di| {
            if (!live.decl(di) or (decl.kind != .value and decl.kind != .foreign_value)) continue;
            const row = try built.declaration(.{ .module = module, .declaration = @intCast(di) });
            const bits = try exposure.port(row.port);
            if (bits & Exposure.unresolved != 0) reason = .escape;
            if (bits & Exposure.native != 0) {
                const port = built.ports.get(@backingInt(row.port));
                if (port.origin.kind != .callable or port.origin.value >= consumed.definite.len or !consumed.definite[port.origin.value]) reason = .deferred_use;
            }
        }
    }
    for (0..consumed.uses.len) |i| {
        const use = consumed.uses.get(i);
        const bits = try exposure.port(use.port);
        try out.witnesses.append(a, .{ .source = use.source, .port = use.port, .call = use.call, .kind = use.kind, .exposure = bits });
        if (use.kind == .escape and bits != 0) reason = .escape;
        if (use.kind == .invocation and use.native != Build.Realms.none and use.state != .checked) reason = .deferred_use;
        if (use.kind == .invocation and use.state == .unresolved and bits != 0) reason = .deferred_use;
    }
    out.recipe.?.reason = reason;
    out.recipe.?.disposition = if (reason == .none) .ready else .refused;
    return out;
}
