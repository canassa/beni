//! Effect classes retained by module-level mutable cells. This is part of
//! Effects.run's existing class construction, before solving the graph.
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
                            std.mem.eql(u8, e.interner.slice(entry.name), "Ref")) stored = true;
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
