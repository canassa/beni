//! What the dumps print of effect inference's classes
//! (transparent-effects-proposal.md §14.7, §15.5): split from `Effects.zig`
//! when the `sync` step grew it past checker-v2.md §19.1's 1 500 lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Effects = @import("Effects.zig");

const Var = TypeStore.Var;
const Rung = Effects.Rung;
const Error = Effects.Error;
const none = Effects.none;

/// The classes one printed type may show, and their names: a
/// declaration's summary with its locals read against it (`forDecl`), or an
/// interface scheme's block (`forBlock`). Every lookup is a column over the
/// store's variables, never a map keyed by one.
pub const View = struct {
    gpa: Allocator,
    /// `forBlock`: per store variable, its class + 1, or 0.
    by_var: []u32 = &.{},
    /// `forDecl`: the solved graph, and the declaration read against it.
    effects: ?*Effects = null,
    decl: u32 = 0,
    /// `forDecl`: per node, which of the declaration's classes reach it,
    /// `chunks` words of 64 bits each.
    reach: []u64 = &.{},
    chunks: u32 = 0,
    classes: std.ArrayList(ViewClass) = .empty,
    deps: std.ArrayList(u32) = .empty,
    /// Per class, its printed name once it has one, or `none`.
    names: std.ArrayList(u32) = .empty,
    named: u32 = 0,
    /// A local's dependencies, rebuilt per lookup.
    scratch_deps: std.ArrayList(u32) = .empty,

    pub const ViewClass = struct { rung: Rung, deps_start: u32, deps_len: u32, dependant: bool, sync: bool };

    pub fn deinit(view: *View) void {
        view.gpa.free(view.by_var);
        view.gpa.free(view.reach);
        view.classes.deinit(view.gpa);
        view.deps.deinit(view.gpa);
        view.names.deinit(view.gpa);
        view.scratch_deps.deinit(view.gpa);
    }

    fn addClass(view: *View, rung: Rung, deps: []const u32, sync: bool) Error!void {
        try view.classes.append(view.gpa, .{ .rung = rung, .deps_start = @intCast(view.deps.items.len), .deps_len = @intCast(deps.len), .dependant = false, .sync = sync });
        try view.deps.appendSlice(view.gpa, deps);
        try view.names.append(view.gpa, none);
    }

    fn markDependants(view: *View) void {
        for (view.deps.items) |d| {
            if (d < view.classes.items.len) view.classes.items[d].dependant = true;
        }
    }

    /// A declaration's summary, and its locals read against it.
    pub fn forDecl(gpa: Allocator, e: *Effects, decl: u32) Error!View {
        var view: View = .{ .gpa = gpa, .effects = e, .decl = decl };
        errdefer view.deinit();
        const s = &e.solved;
        const classes = s.classesOf(decl);
        for (classes) |c| try view.addClass(c.rung, s.depsOf(c), c.sync);
        view.markDependants();
        // What reaches each node the declaration's classes reach: one
        // forward walk per class, its bit set on every node it meets.
        view.chunks = @intCast((classes.len + 63) / 64);
        view.reach = try gpa.alloc(u64, @as(usize, s.nodes()) * view.chunks);
        @memset(view.reach, 0);
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(gpa);
        for (classes, 0..) |c, ci| {
            const word = ci / 64;
            const bit = @as(u64, 1) << @intCast(ci % 64);
            try work.append(gpa, c.node);
            view.reach[@as(usize, c.node) * view.chunks + word] |= bit;
            while (work.pop()) |x| {
                var at = s.head.items[x];
                while (at != none) : (at = s.next.items[at]) {
                    const y = s.find(s.to.items[at]);
                    const slot = &view.reach[@as(usize, y) * view.chunks + word];
                    if (slot.* & bit != 0) continue;
                    slot.* |= bit;
                    try work.append(gpa, y);
                }
            }
        }
        return view;
    }

    /// An interface scheme's block, over the variables `Schemes.instantiate`
    /// read it into.
    pub fn forBlock(gpa: Allocator, store: *TypeStore, iface: *const Interface, scheme: Interface.Scheme, body: Var, quantified: []const Var) Error!View {
        var view: View = .{ .gpa = gpa };
        errdefer view.deinit();
        const block = iface.effectBlock(scheme) orelse return view;
        for (0..block.classCount()) |c| {
            const class = block.class(@intCast(c));
            try view.addClass(@enumFromInt(@min(class.rung, 2)), class.deps, class.sync);
        }
        view.markDependants();
        view.by_var = try gpa.alloc(u32, store.count());
        @memset(view.by_var, 0);
        var reader: Effects = .{ .gpa = gpa, .store = store, .types = undefined, .interner = undefined };
        var sites = block.sites();
        while (sites.next()) |site| {
            const v = reader.follow(iface, site, body, quantified) orelse continue;
            const r, _ = store.resolved(v);
            if (r.int() < view.by_var.len) view.by_var[r.int()] = site.class + 1;
        }
        return view;
    }

    const Printed = union(enum) { class: u32, local: struct { rung: Rung, deps: []const u32 } };

    /// What `v` prints: one of the view's classes, or a local's rung and the
    /// declaration's classes that reach it.
    fn classOf(view: *View, store: *TypeStore, v: Var) Error!?Printed {
        const r, _ = store.resolved(v);
        if (r.int() < view.by_var.len and view.by_var[r.int()] != 0) return .{ .class = view.by_var[r.int()] - 1 };
        const e = view.effects orelse return null;
        if (!e.carries(r)) return null;
        const nd = e.nodeOf(r) orelse return null;
        if (e.solved.classIndex(view.decl, nd)) |c| return .{ .class = c };
        view.scratch_deps.clearRetainingCapacity();
        for (0..view.classes.items.len) |ci| {
            if (view.reach[@as(usize, nd) * view.chunks + ci / 64] & (@as(u64, 1) << @intCast(ci % 64)) != 0) {
                try view.scratch_deps.append(view.gpa, @intCast(ci));
            }
        }
        const rung = e.levelOf(nd);
        if (rung == .pure and view.scratch_deps.items.len == 0) return null;
        return .{ .local = .{ .rung = rung, .deps = view.scratch_deps.items } };
    }

    /// ` !x` for `v`'s class, or nothing when it prints nothing (§14.7).
    pub fn suffix(view: *View, store: *TypeStore, v: Var, out: *std.ArrayList(u8)) Error!void {
        out.clearRetainingCapacity();
        const what = (try view.classOf(store, v)) orelse return;
        var rung: Rung = .pure;
        var own: ?u32 = null;
        var deps: []const u32 = &.{};
        var sync = false;
        switch (what) {
            .class => |c| {
                const vc = view.classes.items[c];
                rung = vc.rung;
                sync = vc.sync;
                if (vc.dependant) own = c;
                deps = view.deps.items[vc.deps_start..][0..vc.deps_len];
            },
            .local => |l| {
                rung = l.rung;
                deps = l.deps;
            },
        }
        if (rung == .suspends) return out.appendSlice(view.gpa, " !suspends");
        var parts: u32 = 0;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(view.gpa);
        if (rung == .impure) {
            try text.appendSlice(view.gpa, "impure");
            parts += 1;
        }
        if (own) |c| {
            if (parts != 0) try text.appendSlice(view.gpa, " | ");
            try view.nameOf(c, &text);
            parts += 1;
        }
        for (deps) |d| {
            if (d >= view.names.items.len or own == d) continue;
            if (parts != 0) try text.appendSlice(view.gpa, " | ");
            try view.nameOf(d, &text);
            parts += 1;
        }
        // A demand prints last (transparent-effects-proposal.md §15.5).
        if (sync) {
            if (parts != 0) try text.appendSlice(view.gpa, " | ");
            try text.appendSlice(view.gpa, "sync");
            parts += 1;
        }
        if (parts == 0) return;
        try out.appendSlice(view.gpa, " !");
        if (parts > 1) try out.append(view.gpa, '(');
        try out.appendSlice(view.gpa, text.items);
        if (parts > 1) try out.append(view.gpa, ')');
    }

    fn nameOf(view: *View, c: u32, text: *std.ArrayList(u8)) Error!void {
        if (view.names.items[c] == none) {
            view.named += 1;
            view.names.items[c] = view.named;
        }
        var buf: [16]u8 = undefined;
        try text.appendSlice(view.gpa, std.fmt.bufPrint(&buf, "e{d}", .{view.names.items[c]}) catch unreachable);
    }
};
