//! Wire evidence for concrete entry roles (workers.md §5). Created while the
//! solved store is alive; only flat representation nodes survive in the cache.
const std = @import("std");
const Types = @import("Types.zig");
const Store = @import("TypeStore.zig");
const Context = @import("Context.zig");
const Walk = @import("Walk.zig");
const Manifest = @import("../js/Manifest.zig");
const Bir = @import("../bir/Bir.zig");
const Symbol = @import("../InternPool.zig").Symbol;
const Diagnostics = @import("Diagnostics.zig");
const Allocator = std.mem.Allocator;
const Var = Store.Var;

pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const Node = struct { kind: Kind, edges: Range = .{} };
pub const Kind = enum(u32) { stable, list, record, tuple, tagged };
pub const Edge = struct { label: Symbol.Optional = .none, child: u32 };
pub const Root = struct { decl: u32, roles: Range };
pub const Role = struct { index: u32, node: u32 };
pub const Artifact = struct {
    nodes: []const Node = &.{},
    edges: []const Edge = &.{},
    roots: []const Root = &.{},
    roles: []const Role = &.{},
    types: []const Types.TypeId = &.{},

    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        gpa.free(a.nodes);
        gpa.free(a.edges);
        gpa.free(a.roots);
        gpa.free(a.roles);
        gpa.free(a.types);
        a.* = .{};
    }
};

pub const Use = struct { v: Var, decl: ?u32, inst: Bir.Inst.Index, path: []const Symbol = &.{} };
pub const Requirement = struct { variable: Var, path: []const Symbol };
pub const Output = struct { artifact: Artifact, quantifiers: []const bool, paths: []const Requirement };

pub fn build(in: @import("TypeKeys.zig").Input, imported: []const Use, kinds: []const Manifest.EntryKind, items: *std.ArrayList(Diagnostics.Item)) Allocator.Error!Output {
    const cx = in.cx;
    const schemes = in.decl_scheme;

    var w: Builder = .{ .cx = cx, .defer_all = true };
    var roots: std.ArrayList(Root) = .empty;
    var roles: std.ArrayList(Role) = .empty;
    const a = cx.scratch;
    for (cx.bir.decls, schemes, 0..) |decl, maybe, di| {
        if (decl.kind != .value or decl.params_start != decl.params_end) continue;
        var root = maybe.unwrap() orelse continue;
        while (cx.store.resolved(root)[1] == .alias) root = Walk.follow(cx.store, cx.store.find(root), .expansion, 0).?;
        const content = cx.store.resolved(root)[1];
        if (content != .structure or content.structure != .app) continue;
        const app = content.structure.app;
        const entry = cx.types.entry(app.type);
        for (kinds) |kind| {
            if (kind.launches.len == 0 or entry.package != .platform) continue;
            const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ cx.interner.slice(entry.module_name), cx.interner.slice(entry.name) });
            if (!std.mem.eql(u8, kind.programType, qualified)) continue;
            const args = try a.dupe(Var, Walk.positions(cx.store, root));
            const start: u32 = @intCast(roles.items.len);
            for (kind.parameters, 0..) |role, ri| {
                if (!std.mem.eql(u8, role.role, "wire") or role.index >= args.len) continue;
                var value = args[role.index];
                var path = try std.fmt.allocPrint(a, "parameter[{d}]", .{role.index});
                var valid = true;
                for (role.path) |field| {
                    path = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, field });
                    value = w.field(value, field) orelse {
                        valid = false;
                        break;
                    };
                }
                w.failure = null;
                if (!valid and w.defer_all) continue;
                const node = if (valid) try w.node(value, path, 0) else blk: {
                    w.failure = .{ .path = path, .reason = "an unresolved protocol field" };
                    break :blk @as(u32, 0);
                };
                if (w.failure != null) break;
                try roles.append(a, .{ .index = @intCast(ri), .node = node });
            }
            try roots.append(a, .{ .decl = @intCast(di), .roles = .{ .start = start, .len = @intCast(roles.items.len - start) } });
        }
    }
    var seeds: std.ArrayList(Use) = .empty;
    try seeds.appendSlice(a, imported);
    const seen = try a.alloc(bool, cx.store.count());
    @memset(seen, false);
    // A constructor may hold a non-Wire protocol until it is launched. The
    // launch's signature acquires the implicit obligations; instantiation
    // propagates them through helpers and discharges them at concrete uses.
    for (kinds) |kind| for (kind.launches) |launch| {
        for (cx.bir.decls, schemes, 0..) |decl, maybe, di| {
            const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ cx.interner.slice(cx.graph.moduleName(cx.module)), cx.interner.slice(cx.bir.symbol(decl.name)) });
            if (!std.mem.eql(u8, qualified, launch.name)) continue;
            var value = maybe.unwrap() orelse continue;
            while (cx.store.resolved(value)[1] == .alias) value = Walk.follow(cx.store, cx.store.find(value), .expansion, 0).?;
            const content = cx.store.resolved(value)[1];
            if (content != .structure or content.structure != .func) continue;
            const params = Walk.function(cx.store, value).?.params;
            if (launch.parameter >= params.len) continue;
            try w.seed(params[launch.parameter], &.{kind}, @intCast(di), decl.body.unwrap() orelse decl.inst_start, seen, &seeds);
        }
    };
    const all_owners = try @import("TypeKeys.zig").schemeVariables(in);
    const marked = try a.alloc(bool, cx.store.count());
    @memset(marked, false);
    w.marked = marked;
    w.defer_all = false;
    var at: usize = 0;
    var event: usize = 0;
    while (at < seeds.items.len) : (at += 1) {
        const check = seeds.items[at];
        const decl = check.decl orelse continue;
        w.owners = all_owners[decl] orelse &.{};
        w.failure = null;
        w.memo.clearRetainingCapacity();
        var value = check.v;
        var path: []const u8 = "message";
        var pending = false;
        for (check.path, 0..) |part, pi| {
            path = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, cx.interner.slice(part) });
            switch (w.member(value, cx.interner.slice(part))) {
                .value => |next| value = next,
                .pending => |variable| {
                    if (!try w.require(variable, check.path[pi..])) _ = w.bad(path, "an unresolved protocol field");
                    pending = true;
                    break;
                },
                .missing => {
                    _ = w.bad(path, "an unresolved protocol field");
                    pending = true;
                    break;
                },
            }
        }
        if (!pending) _ = try w.node(value, path, 0);
        if (w.failure) |failure| {
            try items.append(cx.gpa, .{ .code = .worker_message_not_serializable, .module = cx.module, .region = check.inst, .severity = .@"error", .message = try std.fmt.allocPrint(cx.gpa, "Message field `{s}` cannot cross a worker boundary:\n\nIt contains {s}.\n\nConvert it to a concrete Wire value before sending it.", .{ failure.path, failure.reason }) });
            break;
        }
        // Each newly inferred path is replayed at the local scheme's copies.
        // Imported schemes enter above with those same paths already retained.
        while (event < w.requirements.items.len) : (event += 1) {
            const requirement = w.requirements.items[event];
            for (in.copies) |copy| {
                if (cx.store.find(copy.quantifier) != requirement.variable) continue;
                const d = cx.bir.decls[copy.decl];
                try seeds.append(a, .{ .v = copy.copy, .decl = copy.decl, .inst = d.body.unwrap() orelse d.inst_start, .path = requirement.path });
            }
        }
    }
    var artifact: Artifact = .{};
    errdefer artifact.deinit(cx.gpa);
    artifact.nodes = try cx.gpa.dupe(Node, w.nodes.items);
    artifact.edges = try cx.gpa.dupe(Edge, w.edges.items);
    artifact.roots = try cx.gpa.dupe(Root, roots.items);
    artifact.roles = try cx.gpa.dupe(Role, roles.items);
    artifact.types = try cx.gpa.dupe(Types.TypeId, w.types.items);
    return .{ .quantifiers = marked, .paths = w.requirements.items, .artifact = artifact };
}

const Builder = struct {
    cx: *const Context,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    types: std.ArrayList(Types.TypeId) = .empty,
    memo: std.ArrayList(struct { type: Types.TypeId, args: []const Var, node: u32 }) = .empty,
    defer_all: bool = false,
    owners: []const Var = &.{},
    marked: []bool = &.{},
    requirements: std.ArrayList(Requirement) = .empty,
    failure: ?struct { path: []const u8, reason: []const u8 } = null,

    fn seed(w: *Builder, original: Var, kinds: []const Manifest.EntryKind, decl: u32, inst: Bir.Inst.Index, seen: []bool, seeds: *std.ArrayList(Use)) Allocator.Error!void {
        const cx = w.cx;
        const value = cx.store.find(original);
        if (value.int() >= seen.len or seen[value.int()]) return;
        seen[value.int()] = true;
        switch (cx.store.content(value)) {
            .alias => try w.seed(Walk.follow(cx.store, value, .expansion, 0).?, kinds, decl, inst, seen, seeds),
            .structure => |s| switch (s) {
                .app => |app| {
                    const entry = cx.types.entry(app.type);
                    if (entry.package != .platform) return;
                    const qualified = try std.fmt.allocPrint(cx.scratch, "{s}.{s}", .{ cx.interner.slice(entry.module_name), cx.interner.slice(entry.name) });
                    for (kinds) |kind| {
                        if (!std.mem.eql(u8, kind.programType, qualified)) continue;
                        const args = Walk.positions(cx.store, value);
                        for (kind.parameters) |role| {
                            if (!std.mem.eql(u8, role.role, "wire") or role.index >= args.len) continue;
                            const path = try cx.scratch.alloc(Symbol, role.path.len);
                            for (path, role.path) |*symbol, part| symbol.* = cx.interner.find(part) orelse return;
                            try seeds.append(cx.scratch, .{ .v = args[role.index], .decl = decl, .inst = inst, .path = path });
                        }
                    }
                },
                .func => {
                    for (Walk.function(cx.store, value).?.params) |param| try w.seed(param, kinds, decl, inst, seen, seeds);
                    try w.seed(Walk.function(cx.store, value).?.result, kinds, decl, inst, seen, seeds);
                },
                .record => |record| {
                    for (Walk.recordFields(cx.store, record)) |record_field| try w.seed(record_field.value, kinds, decl, inst, seen, seeds);
                    try w.seed(Walk.recordExtension(record), kinds, decl, inst, seen, seeds);
                },
                .tuple => for (Walk.positions(cx.store, value)) |element| try w.seed(element, kinds, decl, inst, seen, seeds),
                else => {},
            },
            else => {},
        }
    }

    const Member = union(enum) { value: Var, pending: Var, missing };
    fn member(w: *Builder, original: Var, name: []const u8) Member {
        var value = original;
        while (true) switch (w.cx.store.resolved(value)[1]) {
            .alias => value = Walk.follow(w.cx.store, w.cx.store.find(value), .expansion, 0).?,
            .flex, .rigid => return .{ .pending = value },
            .structure => |s| switch (s) {
                .record => |r| {
                    for (Walk.recordFields(w.cx.store, r)) |f| if (std.mem.eql(u8, w.cx.interner.slice(f.name), name)) return .{ .value = f.value };
                    value = Walk.recordExtension(r);
                },
                else => return .missing,
            },
            else => return .missing,
        };
    }

    fn field(w: *Builder, value: Var, name: []const u8) ?Var {
        return switch (w.member(value, name)) {
            .value => |v| v,
            else => null,
        };
    }

    fn require(w: *Builder, original: Var, path: []const Symbol) Allocator.Error!bool {
        const cx = w.cx;
        const variable = cx.store.find(original);
        const flags = cx.store.flagsOf(variable);
        var found = false;
        for (w.owners) |owner| {
            const root = cx.store.find(owner);
            if (root != variable and (flags.name == .none or flags.name != cx.store.flagsOf(root).name)) continue;
            found = true;
            const exists = for (w.requirements.items) |requirement| {
                if (requirement.variable == root and std.mem.eql(Symbol, requirement.path, path)) break true;
            } else false;
            if (exists) continue;
            try w.requirements.append(cx.scratch, .{ .variable = root, .path = path });
            if (path.len == 0 and root.int() < w.marked.len) w.marked[root.int()] = true;
        }
        return found;
    }

    fn bad(w: *Builder, path: []const u8, reason: []const u8) u32 {
        if (w.failure == null) w.failure = .{ .path = path, .reason = reason };
        return 0;
    }

    fn add(w: *Builder, kind: Kind, edges: []const Edge) Allocator.Error!u32 {
        const index: u32 = @intCast(w.nodes.items.len);
        const start: u32 = @intCast(w.edges.items.len);
        try w.edges.appendSlice(w.cx.scratch, edges);
        try w.nodes.append(w.cx.scratch, .{ .kind = kind, .edges = .{ .start = start, .len = @intCast(edges.len) } });
        return index;
    }

    fn node(w: *Builder, original: Var, path: []const u8, depth: u32) Allocator.Error!u32 {
        if (depth > 512) return w.bad(path, "a type whose Wire graph cannot be resolved");
        const cx = w.cx;
        const a = cx.scratch;
        switch (cx.store.resolved(original)[1]) {
            .flex, .rigid => |flags| {
                if (w.defer_all) return w.add(.stable, &.{});
                if (flags.kind == .number or flags.kind == .int_key or flags.kind == .string_key or flags.kind == .dict_key) return w.add(.stable, &.{});
                if (try w.require(original, &.{})) return w.add(.stable, &.{});
                return w.bad(path, "an unresolved type variable");
            },

            .err => return w.bad(path, "an unresolved type"),
            .alias => return w.node(Walk.follow(cx.store, cx.store.find(original), .expansion, 0).?, path, depth + 1),
            .structure => |s| switch (s) {
                .unit, .empty_record => return w.add(.stable, &.{}),
                .func => return w.bad(path, "a function"),
                .tuple => {
                    var edges: std.ArrayList(Edge) = .empty;
                    for (try a.dupe(Var, Walk.positions(cx.store, original)), 0..) |v, i| try edges.append(a, .{ .child = try w.node(v, try std.fmt.allocPrint(a, "{s}[{d}]", .{ path, i }), depth + 1) });
                    return w.add(.tuple, edges.items);
                },
                .record => |r| {
                    var edges: std.ArrayList(Edge) = .empty;
                    var row = r;
                    while (true) {
                        const fields = try a.dupe(Store.Field, Walk.recordFields(cx.store, row));
                        std.mem.sort(Store.Field, fields, cx.interner, struct {
                            fn less(pool: *const @import("../InternPool.zig").Global, x: Store.Field, y: Store.Field) bool {
                                return std.mem.lessThan(u8, pool.slice(x.name), pool.slice(y.name));
                            }
                        }.less);
                        for (fields) |f| try edges.append(a, .{ .label = f.name.toOptional(), .child = try w.node(f.value, try std.fmt.allocPrint(a, "{s}.{s}", .{ path, cx.interner.slice(f.name) }), depth + 1) });
                        var ext = Walk.recordExtension(row);
                        while (cx.store.resolved(ext)[1] == .alias) ext = Walk.follow(cx.store, cx.store.find(ext), .expansion, 0).?;
                        const tail = cx.store.resolved(ext)[1];
                        if (tail == .structure and tail.structure == .empty_record) break;
                        if (tail != .structure or tail.structure != .record) {
                            if (w.defer_all or try w.require(ext, &.{})) break;
                            return w.bad(path, "an open record row");
                        }
                        row = tail.structure.record;
                    }
                    return w.add(.record, edges.items);
                },
                .app => |app| {
                    const entry = cx.types.entry(app.type);
                    const wk = cx.types.well_known;
                    if (app.type == wk.int or app.type == wk.float or app.type == wk.string or app.type == wk.bool or app.type == wk.char) return w.add(.stable, &.{});
                    if (entry.package == .core and std.mem.eql(u8, cx.interner.slice(entry.module_name), "Int32") and std.mem.eql(u8, cx.interner.slice(entry.name), "Int32")) return w.add(.stable, &.{});
                    const args = try a.dupe(Var, Walk.positions(cx.store, original));
                    for (args) |*v| v.* = cx.store.find(v.*);
                    for (w.memo.items) |m| if (m.type == app.type and std.mem.eql(Var, m.args, args)) return m.node;
                    if (app.type == wk.list) {
                        const child = try w.node(args[0], try std.fmt.allocPrint(a, "{s}[]", .{path}), depth + 1);
                        return w.add(.list, &.{.{ .child = child }});
                    }
                    if (entry.kind == .foreign or entry.schema_endpoint) return w.bad(path, try std.fmt.allocPrint(a, "the native type `{s}.{s}`", .{ cx.interner.slice(entry.module_name), cx.interner.slice(entry.name) }));
                    const index = try w.add(.tagged, &.{});
                    try w.memo.append(a, .{ .type = app.type, .args = args, .node = index });
                    if (std.mem.indexOfScalar(Types.TypeId, w.types.items, app.type) == null) try w.types.append(a, app.type);
                    const bir = cx.artifacts.bir(cx.graph.moduleFile(entry.module));
                    const decl = bir.decl(entry.decl);
                    var b: Types.Builder = .init(cx.store, cx.types, cx.graph, cx.artifacts, entry.module, bir, .flex, 0, a, cx.interner);
                    defer b.deinit();
                    for (bir.declTypeParams(decl), args) |p, v| try b.bind(p, v);
                    var variants: std.ArrayList(Edge) = .empty;
                    for (bir.declCtors(decl)) |ctor| {
                        var payloads: std.ArrayList(Edge) = .empty;
                        for (bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, Bir.Inst.Index), 0..) |at, i| {
                            const payload = try b.read(at);
                            try payloads.append(a, .{ .child = try w.node(payload, try std.fmt.allocPrint(a, "{s}.{s}[{d}]", .{ path, cx.interner.slice(bir.symbol(ctor.name)), i }), depth + 1) });
                        }
                        try variants.append(a, .{ .label = bir.symbol(ctor.name).toOptional(), .child = try w.add(.tuple, payloads.items) });
                    }
                    const start: u32 = @intCast(w.edges.items.len);
                    try w.edges.appendSlice(a, variants.items);
                    w.nodes.items[index].edges = .{ .start = start, .len = @intCast(variants.items.len) };
                    return index;
                },
            },
        }
    }
};

/// Propagate the need to normalize from list views to their parents. Stable
/// recursive subgraphs have no runtime traversal at all.
pub fn normalization(a: Allocator, plan: *const Artifact) Allocator.Error![]bool {
    const needs = try a.alloc(bool, plan.nodes.len);
    @memset(needs, false);
    const starts = try a.alloc(u32, plan.nodes.len + 1);
    defer a.free(starts);
    @memset(starts, 0);
    for (plan.edges) |edge| starts[edge.child + 1] += 1;
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const cursors = try a.dupe(u32, starts);
    defer a.free(cursors);
    const parents = try a.alloc(u32, plan.edges.len);
    defer a.free(parents);
    for (plan.nodes, 0..) |n, i| for (plan.edges[n.edges.start..][0..n.edges.len]) |edge| {
        parents[cursors[edge.child]] = @intCast(i);
        cursors[edge.child] += 1;
    };
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(a);
    for (plan.nodes, 0..) |n, i| if (n.kind == .list) {
        needs[i] = true;
        try queue.append(a, @intCast(i));
    };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const child = queue.items[head];
        for (parents[starts[child]..starts[child + 1]]) |parent| if (!needs[parent]) {
            needs[parent] = true;
            try queue.append(a, parent);
        };
    }
    return needs;
}
