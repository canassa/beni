//! An effect block on its way into the interface
//! (transparent-effects-proposal.md §14.6, §15.5, §16.2): `Effects.writeBlock`
//! is `write` here, split from `Effects.zig` to keep that file under §19.1's
//! 1 500 lines (checker-v2.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Effects = @import("Effects.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Effects.Error;
const none = Effects.none;

/// One site of a scheme on its way into a block.
const BlockSite = struct { v: Var, node: u32, root: u32, steps_start: u32, steps_len: u32 };

/// The block of `decl`'s scheme `v`, appended to `extra`, or `no_terms`
/// when no class of it carries anything. `where_types` are the scheme's
/// `where` types in the record's order; `symbol_index` turns a field's
/// `Symbol` into the record's `SymbolIndex`; `extra` grows with `extra_gpa`.
pub fn write(
    e: *Effects,
    decl: u32,
    v: Var,
    where_types: []const Var,
    extra_gpa: Allocator,
    extra: *std.ArrayList(u32),
    context: anytype,
    comptime symbol_index: fn (@TypeOf(context), Symbol) Error!u32,
) Error!u32 {
    if (decl == Effects.no_owner) return writeRoot(e, v, where_types, extra_gpa, extra, context, symbol_index);
    if (!e.publishes(decl)) return Interface.no_terms;
    return writeClasses(e, e.solved.classesOf(decl), e.solved.deps.items, v, where_types, extra_gpa, extra, context, symbol_index);
}

fn writeClasses(
    e: *Effects,
    classes: []const Effects.Class,
    dependencies: []const u32,
    v: Var,
    where_types: []const Var,
    extra_gpa: Allocator,
    extra: *std.ArrayList(u32),
    context: anytype,
    comptime symbol_index: fn (@TypeOf(context), Symbol) Error!u32,
) Error!u32 {
    const gpa = e.gpa;
    // Which classes are worth a site: a rung, a dependency, or a dependant.
    const worth = try gpa.alloc(bool, classes.len);
    defer gpa.free(worth);
    @memset(worth, false);
    for (classes, 0..) |c, i| {
        if (c.rung != .pure or c.realms != 0 or c.deps_len != 0 or c.sync or c.sensitive or c.holder) worth[i] = true;
        for (classDeps(dependencies, c)) |d| worth[d & ~Interface.EffectBlock.realm_only] = true;
    }

    var sites: std.ArrayList(BlockSite) = .empty;
    defer sites.deinit(gpa);
    var steps: std.ArrayList(u32) = .empty;
    defer steps.deinit(gpa);
    const roots = try gpa.alloc(Var, where_types.len + 1);
    defer gpa.free(roots);
    roots[0] = v;
    @memcpy(roots[1..], where_types);
    try walkSites(e, roots, &sites, &steps, context, symbol_index);

    // A constructor can join a callback arrow and a nominal result without
    // adding a rung or dependency. Keep that relationship at imported uses.
    const seen = try gpa.alloc(bool, classes.len);
    defer gpa.free(seen);
    @memset(seen, false);
    for (sites.items) |site| {
        const c = classIndex(classes, site.node) orelse continue;
        if (seen[c]) worth[c] = true;
        seen[c] = true;
    }
    if (std.mem.indexOfScalar(bool, worth, true) == null) return Interface.no_terms;

    // Classes numbered by first site.
    const number = try gpa.alloc(u32, classes.len);
    defer gpa.free(number);
    @memset(number, none);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    var kept: std.ArrayList(BlockSite) = .empty;
    defer kept.deinit(gpa);
    for (sites.items) |site| {
        const c = classIndex(classes, site.node) orelse continue;
        if (!worth[c]) continue;
        if (number[c] == none) {
            number[c] = @intCast(order.items.len);
            try order.append(gpa, @intCast(c));
        }
        try kept.append(gpa, site);
    }
    if (order.items.len == 0) return Interface.no_terms;
    const at: u32 = @intCast(extra.items.len);
    try extra.append(extra_gpa, @intCast(order.items.len));
    var deps: std.ArrayList(u32) = .empty;
    defer deps.deinit(gpa);
    for (order.items) |c| {
        const class = classes[c];
        deps.clearRetainingCapacity();
        for (classDeps(dependencies, class)) |d| {
            const index = d & ~Interface.EffectBlock.realm_only;
            if (number[index] != none) try deps.append(gpa, number[index] | (d & Interface.EffectBlock.realm_only));
        }
        std.mem.sort(u32, deps.items, {}, std.sort.asc(u32));
        try extra.append(extra_gpa, @as(u32, @backingInt(class.rung)) | (@as(u32, class.realms) << 16) | (if (class.sync) Interface.EffectBlock.sync_bit else 0) | (if (class.sensitive) Interface.EffectBlock.sensitive_bit else 0));
        try extra.append(extra_gpa, @intCast(deps.items.len));
        try extra.appendSlice(extra_gpa, deps.items);
    }
    try extra.append(extra_gpa, @intCast(kept.items.len));
    for (kept.items) |site| {
        const c = classIndex(classes, site.node).?;
        try extra.append(extra_gpa, number[c]);
        try extra.append(extra_gpa, site.root);
        try extra.append(extra_gpa, site.steps_len);
        try extra.appendSlice(extra_gpa, steps.items[site.steps_start..][0..site.steps_len]);
    }
    return at;
}

/// A virtual schema member has no ordinary declaration summary. Read the
/// same solved classes and dependencies from its exact checked member type.
fn writeRoot(
    e: *Effects,
    v: Var,
    where_types: []const Var,
    extra_gpa: Allocator,
    extra: *std.ArrayList(u32),
    context: anytype,
    comptime symbol_index: fn (@TypeOf(context), Symbol) Error!u32,
) Error!u32 {
    const gpa = e.gpa;
    var sites: std.ArrayList(BlockSite) = .empty;
    defer sites.deinit(gpa);
    var steps: std.ArrayList(u32) = .empty;
    defer steps.deinit(gpa);
    const roots = try gpa.alloc(Var, where_types.len + 1);
    defer gpa.free(roots);
    roots[0] = v;
    @memcpy(roots[1..], where_types);
    try walkSites(e, roots, &sites, &steps, context, symbol_index);
    var nodes: std.ArrayList(u32) = .empty;
    defer nodes.deinit(gpa);
    for (sites.items) |site| if (std.mem.indexOfScalar(u32, nodes.items, site.node) == null) try nodes.append(gpa, site.node);
    if (nodes.items.len == 0) return Interface.no_terms;
    const reach = try gpa.alloc(bool, nodes.items.len);
    defer gpa.free(reach);
    @memset(reach, false);
    const deps = try @import("Realms.zig").dependencies(e, nodes.items, gpa, reach);
    defer {
        for (deps) |list| gpa.free(list);
        gpa.free(deps);
    }
    var classes: std.ArrayList(Effects.Class) = .empty;
    defer classes.deinit(gpa);
    var dependencies: std.ArrayList(u32) = .empty;
    defer dependencies.deinit(gpa);
    const own = e.nodeOf(v);
    for (nodes.items, deps, reach) |node, list, demanded| {
        const start: u32 = @intCast(dependencies.items.len);
        try dependencies.appendSlice(gpa, list);
        const rung = e.solved.level.items[node];
        var holder = false;
        for (sites.items) |site| if (site.node == node and e.isHolder(e.store.find(site.v))) {
            holder = true;
            break;
        };
        try classes.append(gpa, .{
            .node = node,
            .rung = rung,
            .realms = e.realmOf(node),
            .deps_start = start,
            .deps_len = @intCast(list.len),
            .holder = holder,
            .sync = demanded and node != own and rung != .suspends,
        });
    }
    return writeClasses(e, classes.items, dependencies.items, v, where_types, extra_gpa, extra, context, symbol_index);
}

fn classIndex(classes: []const Effects.Class, node: u32) ?u32 {
    for (classes, 0..) |class, i| if (class.node == node) return @intCast(i);
    return null;
}

fn classDeps(dependencies: []const u32, class: Effects.Class) []const u32 {
    return dependencies[class.deps_start..][0..class.deps_len];
}

/// §14.6's walk: from each root in turn, depth first, parameters before
/// the result, arguments and elements in order, a record's fields by name
/// text then its extension, an alias's expansion; each variable once. Every
/// function type, function-holding application and unknown realm source is a site, with the path
/// that reached it first.
fn walkSites(
    e: *Effects,
    roots: []const Var,
    sites: *std.ArrayList(BlockSite),
    steps: *std.ArrayList(u32),
    context: anytype,
    comptime symbol_index: fn (@TypeOf(context), Symbol) Error!u32,
) Error!void {
    const gpa = e.gpa;
    const store = e.store;
    const Frame = struct { v: Var, path_start: u32, path_len: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    // Paths live in one list; a frame's path is a run of it.
    var paths: std.ArrayList(u32) = .empty;
    defer paths.deinit(gpa);
    var kids: std.ArrayList(Walk.Stepped) = .empty;
    defer kids.deinit(gpa);
    const mark = store.nextMark();
    for (roots, 0..) |root, ri| {
        try stack.append(gpa, .{ .v = root, .path_start = 0, .path_len = 0 });
        while (stack.pop()) |f| {
            const r = store.find(f.v);
            if (store.mark(r) == mark) continue;
            store.setMark(r, mark);
            if (e.realmCarrier(r)) {
                // A variable the graph never met is in no class a summary has.
                if (e.solved.nodeIfAny(r)) |id| {
                    const steps_start: u32 = @intCast(steps.items.len);
                    try steps.appendSlice(gpa, paths.items[f.path_start..][0..f.path_len]);
                    try sites.append(gpa, .{ .v = r, .node = e.solved.find(id), .root = @intCast(ri), .steps_start = steps_start, .steps_len = f.path_len });
                }
            }
            var stored_sites: std.ArrayList(@import("AnyValues.zig").Site) = .empty;
            defer stored_sites.deinit(gpa);
            try @import("AnyValues.zig").sites(e, r, &stored_sites, gpa);
            defer for (stored_sites.items) |stored| if (stored.key.len != 0) gpa.free(stored.key);
            for (stored_sites.items) |stored| {
                const node = try e.nodeFor(stored.variable);
                const start: u32 = @intCast(steps.items.len);
                try steps.appendSlice(gpa, paths.items[f.path_start..][0..f.path_len]);
                try steps.append(gpa, (@as(u32, 7) << 28) | @as(u32, @intCast(stored.key.len)));
                var offset: usize = 0;
                while (offset < stored.key.len) : (offset += 4) {
                    var word: u32 = 0;
                    for (stored.key[offset..@min(offset + 4, stored.key.len)], 0..) |byte, i| word |= @as(u32, byte) << @as(u5, @intCast(i * 8));
                    try steps.append(gpa, word);
                }
                try sites.append(gpa, .{ .v = stored.variable, .node = node, .root = @intCast(ri), .steps_start = start, .steps_len = @as(u32, @intCast(steps.items.len)) - start });
            }
            kids.clearRetainingCapacity();
            var k: u32 = 0;
            while (Walk.stepped(store, r, k)) |c| : (k += 1) try kids.append(gpa, c);
            // A record's fields by name text (the extension stays last).
            const Sorter = struct {
                interner: *const InternPool.Global,
                fn lessThan(ctx: @This(), a: Walk.Stepped, b: Walk.Stepped) bool {
                    if (a.kind != .field or b.kind != .field) return @backingInt(a.kind) < @backingInt(b.kind);
                    return std.mem.lessThan(u8, ctx.interner.slice(@fromBackingInt(@intCast(a.index))), ctx.interner.slice(@fromBackingInt(@intCast(b.index))));
                }
            };
            std.mem.sort(Walk.Stepped, kids.items, Sorter{ .interner = e.interner }, Sorter.lessThan);
            // Pushed in reverse, so the first child is walked first.
            var i = kids.items.len;
            while (i > 0) {
                i -= 1;
                const c = kids.items[i];
                const index: u32 = if (c.kind == .field) try symbol_index(context, @fromBackingInt(@intCast(c.index))) else c.index;
                const path_start: u32 = @intCast(paths.items.len);
                // Grown first: the parent's path is a run of this same list.
                try paths.ensureUnusedCapacity(gpa, f.path_len + 1);
                paths.appendSliceAssumeCapacity(paths.items[f.path_start..][0..f.path_len]);
                paths.appendAssumeCapacity((@as(u32, @backingInt(c.kind)) << 28) | index);
                try stack.append(gpa, .{ .v = c.v, .path_start = path_start, .path_len = f.path_len + 1 });
            }
        }
    }
}
