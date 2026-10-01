//! The dispatch table's `boundary` rows (checker-v2.md §28): what of a type
//! JavaScript sees through a use of core's `Js.from` or `Js.to`.
//!
//! `backend.md` §9's *Item 4, taken up* renames record fields and gives
//! constructors integer tags under `--release`, except where JavaScript can
//! see them. Where a `foreign` annotation says so the backend reads it from
//! the declaration; where a cast says so only the solved type knows, and
//! this file turns each cast's type into rows: every field NAME of every
//! record node and every named type the walk reaches. A type variable is
//! opaque (`boundary.md` §4, *What JavaScript may read of a beni value*), so
//! the walk stops at one; it does not open a named type's constructors,
//! whose bodies the backend reads from `Bir`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");
const Solve = @import("Solve.zig");

const Var = TypeStore.Var;

/// The rows of `casts`, sorted and without repeats, owned by `gpa`.
pub fn rows(
    gpa: Allocator,
    store: *TypeStore,
    stacks: *Walk.Stacks,
    types: *const Types,
    interner: *const InternPool.Global,
    casts: []const Solve.Cast,
) Allocator.Error![]const Dispatch.Boundary {
    if (casts.len == 0) return &.{};
    var out: std.ArrayList(Dispatch.Boundary) = .empty;
    defer out.deinit(gpa);
    const stack = &stacks.vars;
    for (casts) |cast| {
        // Every expression is some declaration's, so every use has one.
        if (cast.decl == std.math.maxInt(u32)) {
            if (std.debug.runtime_safety) std.debug.panic("checker invariant: a `Js` cast outside every declaration (checker-v2.md §28)", .{});
            continue;
        }
        // A fresh mark per cast: two casts in one declaration may share a
        // node and each must see all of it; repeats are dropped below.
        const seen = store.nextMark();
        stack.clearRetainingCapacity();
        // `from`'s parameter and `to`'s result: the `Value` on the other
        // side is JavaScript's own.
        const func = Walk.function(store, cast.copy) orelse continue;
        try stack.append(gpa, switch (cast.which) {
            .from => if (func.params.len == 1) func.params[0] else continue,
            .to => func.result,
        });
        while (stack.pop()) |v| {
            const root = store.find(v);
            if (store.mark(root) == seen) continue;
            store.setMark(root, seen);
            switch (store.content(root)) {
                // Opaque: which type a variable holds is not JavaScript's to
                // know, and an `err` is a hole a message already covers.
                .flex, .rigid, .err => continue,
                .structure => |flat| switch (flat) {
                    .app => |app| try out.append(gpa, .{ .decl = cast.decl, .kind = .type, .value = app.type.int() }),
                    .record => |r| for (Walk.recordFields(store, r)) |f| {
                        try out.append(gpa, .{ .decl = cast.decl, .kind = .field, .value = @intFromEnum(f.name) });
                    },
                    else => {},
                },
                .alias => {},
            }
            var n: u32 = 0;
            while (Walk.child(store, root, n, .payload)) |c| : (n += 1) try stack.append(gpa, c);
        }
    }
    const Order = struct {
        types: *const Types,
        interner: *const InternPool.Global,

        fn key(o: @This(), r: Dispatch.Boundary) [3][]const u8 {
            return switch (r.kind) {
                .field => .{ o.interner.slice(@enumFromInt(r.value)), "", "" },
                .type => blk: {
                    const named = o.types.named(@enumFromInt(r.value)) orelse break :blk .{ "", "", "" };
                    break :blk .{ @tagName(named.package), o.interner.slice(named.module), o.interner.slice(named.name) };
                },
            };
        }

        fn lessThan(o: @This(), a: Dispatch.Boundary, b: Dispatch.Boundary) bool {
            if (a.decl != b.decl) return a.decl < b.decl;
            if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
            const ka = o.key(a);
            const kb = o.key(b);
            for (ka, kb) |x, y| switch (std.mem.order(u8, x, y)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            };
            return false;
        }
    };
    const order: Order = .{ .types = types, .interner = interner };
    std.mem.sort(Dispatch.Boundary, out.items, order, Order.lessThan);
    // Repeats are adjacent now: one (decl, kind, value) is one key.
    var kept: usize = 0;
    for (out.items) |r| {
        if (kept != 0 and std.meta.eql(out.items[kept - 1], r)) continue;
        out.items[kept] = r;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
    return out.toOwnedSlice(gpa);
}
