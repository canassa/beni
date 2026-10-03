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
    const s = &e.solved;
    const classes = s.classesOf(decl);
    if (!e.publishes(decl)) return Interface.no_terms;
    const gpa = e.gpa;
    // Which classes are worth a site: a rung, a dependency, or a dependant.
    const worth = try gpa.alloc(bool, classes.len);
    defer gpa.free(worth);
    @memset(worth, false);
    for (classes, 0..) |c, i| {
        if (c.rung != .pure or c.deps_len != 0 or c.sync or c.sensitive) worth[i] = true;
        for (s.depsOf(c)) |d| worth[d] = true;
    }
    if (std.mem.indexOfScalar(bool, worth, true) == null) return Interface.no_terms;

    var sites: std.ArrayList(BlockSite) = .empty;
    defer sites.deinit(gpa);
    var steps: std.ArrayList(u32) = .empty;
    defer steps.deinit(gpa);
    const roots = try gpa.alloc(Var, where_types.len + 1);
    defer gpa.free(roots);
    roots[0] = v;
    @memcpy(roots[1..], where_types);
    try walkSites(e, roots, &sites, &steps, context, symbol_index);

    // Classes numbered by first site.
    const number = try gpa.alloc(u32, classes.len);
    defer gpa.free(number);
    @memset(number, none);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    var kept: std.ArrayList(BlockSite) = .empty;
    defer kept.deinit(gpa);
    for (sites.items) |site| {
        const c = s.classIndex(decl, site.node) orelse continue;
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
        for (s.depsOf(class)) |d| {
            if (number[d] != none) try deps.append(gpa, number[d]);
        }
        std.mem.sort(u32, deps.items, {}, std.sort.asc(u32));
        try extra.append(extra_gpa, @as(u32, @backingInt(class.rung)) | (if (class.sync) Interface.EffectBlock.sync_bit else 0) | (if (class.sensitive) Interface.EffectBlock.sensitive_bit else 0));
        try extra.append(extra_gpa, @intCast(deps.items.len));
        try extra.appendSlice(extra_gpa, deps.items);
    }
    try extra.append(extra_gpa, @intCast(kept.items.len));
    for (kept.items) |site| {
        const c = s.classIndex(decl, site.node).?;
        try extra.append(extra_gpa, number[c]);
        try extra.append(extra_gpa, site.root);
        try extra.append(extra_gpa, site.steps_len);
        try extra.appendSlice(extra_gpa, steps.items[site.steps_start..][0..site.steps_len]);
    }
    return at;
}

/// §14.6's walk: from each root in turn, depth first, parameters before
/// the result, arguments and elements in order, a record's fields by name
/// text then its extension, an alias's expansion; each variable once. Every
/// function type and function-holding application is a site, with the path
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
            if (e.carries(r)) {
                // A variable the graph never met is in no class a summary has.
                if (e.solved.nodeIfAny(r)) |id| {
                    const steps_start: u32 = @intCast(steps.items.len);
                    try steps.appendSlice(gpa, paths.items[f.path_start..][0..f.path_len]);
                    try sites.append(gpa, .{ .v = r, .node = e.solved.find(id), .root = @intCast(ri), .steps_start = steps_start, .steps_len = f.path_len });
                }
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
