//! Effect classes retained by stored values and declaration schemes.
//! Traversals used while constructing the effect graph and its summaries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Effects = @import("Effects.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Var = TypeStore.Var;
const Error = Effects.Error;
const Record = Effects.Record;
const Interface = @import("../resolve/Interface.zig");
const none = Effects.none;

/// Callback classes stored in module-level Js.Ref values have one identity.
/// Stop at functions: their signatures describe a factory, not a cell already
/// allocated by module evaluation. Records/tuples may contain cells as well.
pub fn run(e: *Effects, schemes: []const Var.Optional, scratch: Allocator) Error![]bool {
    const store = e.store;
    const shared = try scratch.alloc(bool, store.count());
    @memset(shared, false);
    const seen = try scratch.alloc(u8, store.count());
    @memset(seen, 0);
    const Item = struct { v: Var, stored: bool = false };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(scratch);
    for (schemes) |maybe| {
        const scheme = maybe.unwrap() orelse continue;
        try stack.append(scratch, .{ .v = scheme });
        while (stack.pop()) |item| {
            const r, _ = store.resolved(item.v);
            const bit: u8 = if (item.stored) 2 else 1;
            if (seen[r.int()] & bit != 0) continue;
            seen[r.int()] |= bit;
            if (item.stored and (e.carries(r) or @import("Realms.zig").stored(e, r))) shared[r.int()] = true;
            var stored = item.stored;
            switch (store.content(r)) {
                .structure => |st| switch (st) {
                    .func => if (!stored) continue,
                    .app => |a| if (a.type != .none) {
                        const entry = e.types.entry(a.type);
                        if (entry.package == .core and
                            std.mem.eql(u8, e.interner.slice(entry.module_name), "Js") and
                            (std.mem.eql(u8, e.interner.slice(entry.name), "Ref") or std.mem.eql(u8, e.interner.slice(entry.name), "Cell"))) stored = true;
                    },
                    else => {},
                },
                else => {},
            }
            var k: u32 = 0;
            while (Walk.stepped(store, r, k)) |c| : (k += 1)
                try stack.append(scratch, .{ .v = c.v, .stored = stored });
        }
    }
    return shared;
}

/// The distinct nodes of `scheme`'s function types and function-holding
/// applications and realm variables, including `where` types.
pub fn schemeNodes(e: *Effects, scheme: Var, out: *std.ArrayList(u32), holders: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const store = e.store;
    const stack = &e.solved.walk;
    stack.clearRetainingCapacity();
    const mark = store.nextMark();
    try stack.append(e.gpa, scheme);
    while (stack.pop()) |next| {
        const r = store.find(next);
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        switch (store.content(r)) {
            .flex, .rigid => |flags| {
                const set = Walk.constraints(flags);
                for (0..set.count(store)) |i| try stack.append(e.gpa, set.at(store, @intCast(i)).fn_var);
            },
            else => {},
        }
        if (e.realmCarrier(r)) {
            const nd = try e.nodeFor(r);
            if (std.mem.indexOfScalar(u32, out.items, nd) == null) try out.append(e.gpa, nd);
            if (e.isHolder(r)) try holders.append(scratch, nd);
        }
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1) try stack.append(e.gpa, c.v);
    }
}

/// Whether `v`'s class is a nominal application's: a value that holds a
/// function, rather than a function (§15.4's wording).
pub fn isHolder(e: *const Effects, v: Var) bool {
    const r, _ = e.store.resolved(v);
    return switch (e.store.content(r)) {
        .structure => |s| s == .app,
        else => false,
    };
}

/// Whether record `r`'s copy of `target`'s class `ci` is a nominal
/// application's (`isHolder`).
pub fn nodeIsHolder(e: *Effects, r: Record, ci: usize, target: u32) Error!bool {
    for (e.pairs.items[r.start..][0..r.len]) |p| {
        if (e.solved.classIndex(target, try e.nodeFor(p.a)) == @as(u32, @intCast(ci))) return e.isHolder(p.b);
    }
    return false;
}

/// A copy of `target`'s scheme gets `target`'s summary (§14.3 rule 3): its
/// copies of one class are one class, each gets the class's rung, and the
/// copy of each class it depends on flows into it.
pub fn applyRecord(e: *Effects, r: Record, target: u32, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const s = &e.solved;
    const classes = s.classesOf(target);
    if (classes.len == 0) return;
    const reps = try scratch.alloc(u32, classes.len);
    defer scratch.free(reps);
    @memset(reps, none);
    var copied: std.ArrayList(Var) = .empty;
    defer copied.deinit(scratch);
    for (classes, 0..) |class, class_index| {
        copied.clearRetainingCapacity();
        try @import("AnyValues.zig").images(e, r, class.node, &copied, scratch);
        for (copied.items) |actual| {
        const c = class_index;
        const i = try e.nodeFor(actual);

        if (reps[c] == none) {
            reps[c] = i;
        } else if (reps[c] != i) {
            try e.edgeNodes(reps[c], i, none);
            try e.edgeNodes(i, reps[c], none);
            const lr = s.level.items[reps[c]];
            const li = s.level.items[i];
            if (@backingInt(lr) > @backingInt(li)) try e.raise(i, lr, work, scratch);
            if (@backingInt(li) > @backingInt(lr)) try e.raise(reps[c], li, work, scratch);
            try e.raiseRealm(i, e.realmOf(reps[c]), work, scratch);
            try e.raiseRealm(reps[c], e.realmOf(i), work, scratch);
        }
        }
    }
    for (classes, 0..) |c, ci| {
        const rep = reps[ci];
        if (rep == none) continue;
        try e.raise(rep, c.rung, work, scratch);
        try e.raiseRealm(rep, c.realms, work, scratch);
        for (s.depsOf(c)) |d| {
            const from = reps[d & ~Interface.EffectBlock.realm_only];
            if (from == none) continue;
            const realm_only = d & Interface.EffectBlock.realm_only != 0;
            if (realm_only) try @import("Realms.zig").applyCopy(e, r, classes[d & ~Interface.EffectBlock.realm_only].node, rep, work, scratch);
            try e.edgeNodes(from, rep, if (realm_only) Effects.realm_origin else none);
            if (!realm_only) try e.raise(rep, s.level.items[from], work, scratch);
            try e.raiseRealm(rep, e.realmOf(from), work, scratch);
        }
        // §15.3: the use's copy of a `sync` class must not suspend. Where
        // the class sits is read off `target`'s scheme when it is reported.
        if (c.sync) try e.addSource(.{
            .node = rep,
            .demand = .{ .v = @fromBackingInt(@intCast(none)), .kind = .argument, .site = r.site, .decl = r.owner, .holder = try nodeIsHolder(e, r, ci, target) },
            .target = target,
            .class = @intCast(ci),
        });
    }
}
