//! Closed scalar key constraints and the parameter facts published for them
//! (checker-v2.md §37). Alias chasing is the only walk in membership: lists,
//! records, functions and other nominal heads are rejected as heads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Kind = TypeStore.Kind;
const TypeId = TypeStore.TypeId;

pub const Issue = struct {
    region: Bir.Inst.Index,
    actual: Var,
    required: Kind,
    /// Two constraints on a variable have no common member.
    incompatible: ?Kind = null,
};

pub const Observer = struct {
    context: *anyopaque,
    note: *const fn (*anyopaque, TypeId, []const Var, Bir.Inst.Index) Allocator.Error!void,
};

pub fn root(store: *TypeStore, raw: Var) Var {
    return store.resolved(raw)[0];
}

pub fn allows(store: *TypeStore, types: *const Types, kind: Kind, raw: Var) bool {
    const v = root(store, raw);
    const content = store.content(v);
    if (content == .err) return true;
    if (content != .structure or content.structure != .app) return false;
    const app = content.structure.app;
    if (app.args.len != 0) return false;
    return switch (kind) {
        .dict_key => app.type == types.well_known.int or app.type == types.well_known.string,
        .int_key => app.type == types.well_known.int,
        .string_key => app.type == types.well_known.string,
        else => unreachable,
    };
}

/// Add a key constraint to a written type's variable, or report its fixed
/// unsupported head. The annotation reader has no live solver wanteds.
pub fn constrain(store: *TypeStore, types: *const Types, actual: Var, required: Kind, region: Bir.Inst.Index) ?Issue {
    std.debug.assert(required.isKey());
    const v = root(store, actual);
    switch (store.content(v)) {
        .err => return null,
        .flex, .rigid => |flags| {
            const kind = Kind.meet(flags.kind, required) orelse return .{ .region = region, .actual = actual, .required = required, .incompatible = flags.kind };
            var next = flags;
            next.kind = kind;
            store.setContent(v, if (store.content(v) == .rigid) .{ .rigid = next } else .{ .flex = next });
            return null;
        },
        .alias => unreachable,
        .structure => if (!allows(store, types, required, v)) return .{ .region = region, .actual = actual, .required = required },
    }
    return null;
}

const Graph = @import("../resolve/Graph.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const Schema = @import("Schema.zig");
const reads = @import("reads.zig");

/// One module owns these facts. Imported facts are already published by
/// its dependencies. Bodies are read shallowly once; an alias's scalar
/// head/projection is memoized independently of its applications.
pub const Preparation = struct {
    a: Allocator,
    store: *TypeStore,
    types: *Types,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    module: Graph.Index,
    bir: *const Bir,
    schemas: *Schema.State,
    issues: *std.ArrayList(Issue),
    start: u32,
    vars: []Var,
    published: []Kind,
    changed: bool = false,
    params: []?[]const Var,
    alias_roots: []Var.Optional,
    projections: []Projection,
    bindings: std.ArrayList(std.ArrayList(u32)) = .empty,
    uses: std.ArrayList(Use) = .empty,
    queue: std.ArrayList(u32) = .empty,

    const none = std.math.maxInt(u32);
    const Use = struct { source: u32, required: Kind, actual: Var, region: Bir.Inst.Index, reported: bool = false };
    const Projection = union(enum) { pending, active, parameter: u32, int, string, other, err };
    const Head = union(enum) { variable: Var, int, string, other, err };
    const AliasFrame = struct { id: TypeId, at: Var };

    pub fn init(a: Allocator, store: *TypeStore, types: *Types, graph: *const Graph, artifacts: *const Artifacts, interfaces: []const Interface, interner: *const InternPool.Global, module: Graph.Index, bir: *const Bir, schemas: *Schema.State, issues: *std.ArrayList(Issue)) Allocator.Error!Preparation {
        const first = types.entry_offsets[module.int()];
        const last = types.entry_offsets[module.int() + 1];
        const start = if (first < types.entries.len) types.entries[first].key_start else @as(u32, @intCast(types.key_kinds.len));
        var len: u32 = 0;
        for (types.entries[first..last]) |e| len += e.arity;
        var p: Preparation = .{
            .a = a,
            .store = store,
            .types = types,
            .graph = graph,
            .artifacts = artifacts,
            .interfaces = interfaces,
            .interner = interner,
            .module = module,
            .bir = bir,
            .schemas = schemas,
            .issues = issues,
            .start = start,
            .vars = try a.alloc(Var, len),
            .published = try a.alloc(Kind, len),
            .params = try a.alloc(?[]const Var, types.entries.len),
            .alias_roots = try a.alloc(Var.Optional, types.entries.len),
            .projections = try a.alloc(Projection, types.entries.len),
        };
        @memset(p.published, .any);
        @memset(p.params, null);
        @memset(p.alias_roots, .none);
        @memset(p.projections, .pending);
        for (first..last) |i| {
            const id: TypeId = @fromBackingInt(@intCast(i));
            const e = types.entries[i];
            const row = p.vars[e.key_start - start ..][0..e.arity];
            const names = bir.declTypeParams(bir.decl(e.decl));
            for (row, 0..) |*v, j| {
                if (e.schema_endpoint) {
                    const ep: Interface.SchemaCtor.Endpoint = if (types.ofSchemaDecl(module, e.decl, .type) == id) .type else .encoded;
                    v.* = schemas.param(e.decl.int(), @intCast(j), ep);
                } else {
                    const name = names[j];
                    v.* = try store.fresh(.{ .flex = .{ .name = name.toOptional(), .kind = Types.kindOfName(interner.slice(name)) } }, TypeStore.generalized);
                }
                try p.bind(v.*, e.key_start + @as(u32, @intCast(j)));
                const required = types.key_kinds[e.key_start + j];
                if (required.isKey()) if (constrain(store, types, v.*, required, @fromBackingInt(0))) |issue| try issues.append(a, issue);
            }
            p.params[i] = row;
        }
        return p;
    }

    fn bind(p: *Preparation, v: Var, offset: u32) Allocator.Error!void {
        const index = root(p.store, v).int();
        if (index >= p.bindings.items.len) try p.bindings.appendNTimes(p.a, .empty, index + 1 - p.bindings.items.len);
        try p.bindings.items[index].append(p.a, offset);
    }

    pub fn observer(p: *Preparation) Observer {
        return .{ .context = p, .note = observe };
    }

    fn observe(ctx: *anyopaque, id: TypeId, args: []const Var, region: Bir.Inst.Index) Allocator.Error!void {
        const p: *Preparation = @ptrCast(@alignCast(ctx));
        const e = p.types.entry(id);
        for (args, 0..) |actual, j| {
            const required = p.types.keyKinds(id)[j];
            if (e.module != p.module and !required.isKey()) continue;
            try p.uses.append(p.a, .{
                .source = if (e.module == p.module) e.key_start + @as(u32, @intCast(j)) - p.start else none,
                .required = required,
                .actual = actual,
                .region = region,
            });
        }
    }

    fn ignore(_: *anyopaque, _: TypeId, _: []const Var, _: Bir.Inst.Index) Allocator.Error!void {}

    fn builder(p: *Preparation, module: Graph.Index, bir: *const Bir, collect: bool) Types.Builder {
        var b: Types.Builder = .init(p.store, p.types, p.graph, p.artifacts, module, bir, .flex, TypeStore.generalized, p.a, p.interner);
        b.interfaces = p.interfaces;
        b.shallow = true;
        b.key_observer = if (collect) p.observer() else .{ .context = p, .note = ignore };
        if (module == p.module) {
            b.schema_context = p.schemas;
            b.schema_lookup = Schema.State.lookupOpaque;
        }
        return b;
    }

    /// Parameter constraints use a worklist over finite domain intersections,
    /// not repeated body expansion or a declaration-order-dependent scan.
    pub fn run(p: *Preparation) Allocator.Error!void {
        const first = p.types.entry_offsets[p.module.int()];
        const last = p.types.entry_offsets[p.module.int() + 1];
        for (first..last) |i| {
            const e = p.types.entries[i];
            if (e.schema_endpoint or e.kind == .foreign) continue;
            const d = p.bir.decl(e.decl);
            var b = p.builder(p.module, p.bir, true);
            defer b.deinit();
            for (p.bir.declTypeParams(d), p.params[i].?) |name, v| try b.bind(name, v);
            switch (e.kind) {
                .alias => if (d.annotation.unwrap()) |at| {
                    p.alias_roots[i] = (try b.read(at)).toOptional();
                },
                .adt => for (p.bir.declCtors(d)) |ctor| {
                    for (p.bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index)) |at| _ = try b.read(at);
                },
                .foreign => unreachable,
            }
        }
        const starts = try p.a.alloc(u32, p.vars.len + 1);
        @memset(starts, 0);
        for (p.uses.items) |use| if (use.source != none) {
            starts[use.source + 1] += 1;
        };
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const cursor = try p.a.dupe(u32, starts[0..p.vars.len]);
        const edges = try p.a.alloc(u32, starts[p.vars.len]);
        for (p.uses.items, 0..) |use, i| {
            if (use.source == none) continue;
            edges[cursor[use.source]] = @intCast(i);
            cursor[use.source] += 1;
        }
        for (p.vars) |v| try p.publish(v);
        for (0..p.uses.items.len) |i| if (p.uses.items[i].source == none) try p.propagate(@intCast(i), p.uses.items[i].required);
        var q: usize = 0;
        while (q < p.queue.items.len) : (q += 1) {
            const node = p.queue.items[q];
            const required = p.types.key_kinds[p.start + node];
            for (edges[starts[node]..starts[node + 1]]) |use| try p.propagate(use, required);
        }
    }

    fn publish(p: *Preparation, raw: Var) Allocator.Error!void {
        const v = root(p.store, raw);
        const kind = switch (p.store.content(v)) {
            .flex, .rigid => |f| f.kind,
            else => return,
        };
        if (!kind.isKey()) return;
        if (v.int() >= p.bindings.items.len) return;
        const offsets = p.bindings.items[v.int()].items;
        for (offsets) |offset| {
            if (offset < p.start or offset - p.start >= p.vars.len) continue;
            const local = offset - p.start;
            if (p.published[local] == kind) continue;
            p.published[local] = kind;
            if (p.types.key_kinds[offset] != kind) p.changed = true;
            p.types.key_kinds[offset] = kind;
            try p.queue.append(p.a, local);
        }
    }

    fn propagate(p: *Preparation, index: u32, required: Kind) Allocator.Error!void {
        if (!required.isKey()) return;
        const use = p.uses.items[index];
        const head_value = try p.head(use.actual);
        const issue: ?Issue = switch (head_value) {
            .variable => |v| constrain(p.store, p.types, v, required, use.region),
            .int => if (required == .string_key) .{ .region = use.region, .actual = use.actual, .required = required } else null,
            .string => if (required == .int_key) .{ .region = use.region, .actual = use.actual, .required = required } else null,
            .other => .{ .region = use.region, .actual = use.actual, .required = required },
            .err => null,
        };
        if (issue) |problem| {
            if (!use.reported) {
                try p.issues.append(p.a, problem);
                p.uses.items[index].reported = true;
            }
        } else if (head_value == .variable) try p.publish(head_value.variable);
    }

    fn aliasRoot(p: *Preparation, id: TypeId) Allocator.Error!Var {
        if (p.alias_roots[id.int()].unwrap()) |v| return v;
        const e = p.types.entry(id);
        const bir = p.artifacts.bir(p.graph.moduleFile(e.module));
        var b = p.builder(if (e.schema_endpoint) p.module else e.module, if (e.schema_endpoint) p.bir else bir, false);
        defer b.deinit();
        if (e.schema_endpoint) {
            const value = if (e.module == p.module) blk: {
                const ep = p.types.ofSchemaDecl(e.module, e.decl, .type) == id;
                break :blk try Schema.State.lookupOpaque(p.schemas, e.decl.int(), !ep, p.params[id.int()].?);
            } else try b.canonical(id);
            var v = value orelse try p.store.freshErr(TypeStore.generalized);
            const c = p.store.content(p.store.find(v));
            if (c == .alias and c.alias.type == id) {
                const args = Walk.nominal(p.store, v).?.args;
                for (args, 0..) |arg, j| try p.bind(arg, e.key_start + @as(u32, @intCast(j)));
                v = c.alias.actual;
            }
            p.alias_roots[id.int()] = v.toOptional();
            return v;
        }
        reads.note(.types_alias_body, e.module);
        const d = bir.decl(e.decl);
        const names = bir.declTypeParams(d);
        if (p.params[id.int()] == null) {
            const vs = try p.a.alloc(Var, e.arity);
            for (vs, names, 0..) |*v, name, j| {
                v.* = try p.store.fresh(.{ .flex = .{ .name = name.toOptional(), .kind = Types.kindOfName(p.interner.slice(name)) } }, TypeStore.generalized);
                try p.bind(v.*, e.key_start + @as(u32, @intCast(j)));
            }
            p.params[id.int()] = vs;
        }
        for (names, p.params[id.int()].?) |name, v| try b.bind(name, v);
        const v = if (d.annotation.unwrap()) |body| try b.read(body) else try p.store.freshErr(TypeStore.generalized);
        p.alias_roots[id.int()] = v.toOptional();
        return v;
    }

    /// Resolve alias projections with an explicit stack: an arbitrarily long
    /// chain of alias names does not consume the native stack or expand a DAG.
    fn settleAlias(p: *Preparation, id: TypeId) Allocator.Error!void {
        if (p.projections[id.int()] != .pending) return;
        var stack: std.ArrayList(AliasFrame) = .empty;
        try stack.append(p.a, .{ .id = id, .at = try p.aliasRoot(id) });
        p.projections[id.int()] = .active;
        while (stack.items.len != 0) {
            const f = &stack.items[stack.items.len - 1];
            const v = p.store.find(f.at);
            const c = p.store.content(v);
            var answer: ?Projection = null;
            switch (c) {
                .err => answer = .err,
                .flex, .rigid => {
                    const e = p.types.entry(f.id);
                    const offsets = if (v.int() < p.bindings.items.len) p.bindings.items[v.int()].items else &.{};
                    for (offsets) |offset| {
                        if (offset >= e.key_start and offset - e.key_start < e.arity) {
                            answer = .{ .parameter = offset - e.key_start };
                            break;
                        }
                    }
                    if (answer == null) answer = .err;
                },
                .structure => |s| {
                    answer = if (s == .app and s.app.type == p.types.well_known.int) .int else if (s == .app and s.app.type == p.types.well_known.string) .string else .other;
                },
                .alias => |alias| switch (p.projections[alias.type.int()]) {
                    .pending => {
                        p.projections[alias.type.int()] = .active;
                        try stack.append(p.a, .{ .id = alias.type, .at = try p.aliasRoot(alias.type) });
                        continue;
                    },
                    .active, .err => answer = .err, // a refused recursive alias or poisoned body
                    .parameter => |j| {
                        f.at = Walk.nominal(p.store, v).?.args[j];
                        continue;
                    },
                    else => |projection| answer = projection,
                },
            }
            p.projections[f.id.int()] = answer.?;
            _ = stack.pop();
        }
    }

    fn head(p: *Preparation, raw: Var) Allocator.Error!Head {
        var at = p.store.find(raw);
        while (true) switch (p.store.content(at)) {
            .flex, .rigid => return .{ .variable = at },
            .err => return .err,
            .structure => |s| return if (s == .app and s.app.type == p.types.well_known.int) .int else if (s == .app and s.app.type == p.types.well_known.string) .string else .other,
            .alias => |alias| {
                try p.settleAlias(alias.type);
                switch (p.projections[alias.type.int()]) {
                    .parameter => |j| at = p.store.find(Walk.nominal(p.store, at).?.args[j]),
                    .int => return .int,
                    .string => return .string,
                    .other => return .other,
                    .err => return .err,
                    .pending, .active => unreachable,
                }
            },
        };
    }
};

/// A schema conversion can reveal a parameter's key domain only after its
/// value group is inferred. Revisit live formations once when that happens,
/// before publication. Membership still tests only a scalar head; this walk
/// visits each live type node once and carries the source of its first use.
pub fn validateFormations(a: Allocator, store: *TypeStore, types: *Types, bir: *const Bir, inst_types: []const Var.Optional, schemes: []const Var.Optional, issues: *std.ArrayList(Issue)) Allocator.Error!void {
    const At = struct { v: Var, region: Bir.Inst.Index };
    var stack: std.ArrayList(At) = .empty;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(a, store.count());
    defer seen.deinit(a);
    for (inst_types, 0..) |maybe, i| if (maybe.unwrap()) |v| {
        try stack.append(a, .{ .v = v, .region = @fromBackingInt(@intCast(i)) });
    };
    for (schemes, bir.decls) |maybe, d| if (maybe.unwrap()) |v| {
        try stack.append(a, .{ .v = v, .region = d.annotation.unwrap() orelse d.body.unwrap() orelse @fromBackingInt(0) });
    };
    while (stack.pop()) |at| {
        const v = store.find(at.v);
        if (seen.isSet(v.int())) continue;
        seen.set(v.int());
        if (Walk.nominal(store, v)) |app| {
            for (types.keyKinds(app.type), app.args) |required, actual| {
                if (!required.isKey()) continue;
                if (constrain(store, types, actual, required, at.region)) |issue| try issues.append(a, issue);
            }
        }
        var child: u32 = 0;
        while (Walk.owned(store, null, v, child)) |next| : (child += 1)
            try stack.append(a, .{ .v = next, .region = at.region });
    }
}
