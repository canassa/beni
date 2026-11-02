//! Effect classes retained by stored values and declaration schemes.
//! Traversals used while constructing the effect graph and its summaries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Effects = @import("Effects.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Var = TypeStore.Var;
const Error = Effects.Error;

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
            if (item.stored and e.carries(r)) shared[r.int()] = true;
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
