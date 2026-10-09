//! The dispatch table's `debug` rows (checker-v2.md §32): the type each use
//! of core's `Debug.toString` or `Debug.log` prints, as the solver left it.
//!
//! The runtime representation cannot tell a tuple from a record whose
//! fields are `a` and `b`, a `Char` from a one-character `String`, a
//! constructor of an all-nullary type from a string, or a `()` argument
//! from a constructor's padding (`backend.md` §4). The type at the call
//! can, and only this checker has it: so the type crosses to the backend
//! as data, beside the `boundary` rows of §28 and walked the same way, and
//! the backend writes it into the call (`backend.md` §4, *`Debug.toString`
//! reads the argument's type*).
//!
//! A type variable is unknown here — the value of a polymorphic function
//! may be anything — and the printer reads such a value by its
//! representation. A named type is one node with its arguments: its
//! constructors are declarations, which the backend reads from `Bir`, as
//! it does a boundary row's. An alias is read through to its expansion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Solve = @import("Solve.zig");

const Var = TypeStore.Var;

/// Nodes one row may hold before every subtree still to be written is
/// `unknown`: a type is a DAG in the store and a tree here, and
/// `( x, x )` nested n deep is 2ⁿ nodes. A program's printed types are a
/// few dozen nodes; the cap only bounds the pathological ones.
pub const max_nodes: u32 = 4096;

pub const Rows = struct {
    sites: []const Dispatch.DebugSite,
    nodes: []const Dispatch.DebugNode,
};

/// The rows of `uses`, ascending by instruction, owned by `gpa`. A use
/// whose whole type is one `unknown` has no row: the printer reads that
/// value by its representation either way.
pub fn rows(
    gpa: Allocator,
    store: *TypeStore,
    interner: *const InternPool.Global,
    uses: []const Solve.DebugUse,
) Allocator.Error!Rows {
    if (uses.len == 0) return .{ .sites = &.{}, .nodes = &.{} };
    const sorted = try gpa.dupe(Solve.DebugUse, uses);
    defer gpa.free(sorted);
    std.mem.sort(Solve.DebugUse, sorted, {}, struct {
        fn lessThan(_: void, a: Solve.DebugUse, b: Solve.DebugUse) bool {
            return a.inst.int() < b.inst.int();
        }
    }.lessThan);

    var sites: std.ArrayList(Dispatch.DebugSite) = .empty;
    defer sites.deinit(gpa);
    var nodes: std.ArrayList(Dispatch.DebugNode) = .empty;
    defer nodes.deinit(gpa);
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    var fields: std.ArrayList(TypeStore.Field) = .empty;
    defer fields.deinit(gpa);

    for (sorted, 0..) |use, i| {
        // One reference, one row: a use is noted once per instruction.
        if (i != 0 and sorted[i - 1].inst == use.inst) continue;
        const func = Walk.function(store, use.copy) orelse continue;
        // `toString`'s parameter, `log`'s second: the value printed.
        const printed = switch (use.which) {
            .toString => if (func.params.len == 1) func.params[0] else continue,
            .log => if (func.params.len == 2) func.params[1] else continue,
        };
        const start: u32 = @intCast(nodes.items.len);
        try walk(gpa, store, interner, printed, &nodes, &stack, &fields);
        const len: u32 = @as(u32, @intCast(nodes.items.len)) - start;
        if (len == 1 and nodes.items[start].kind == .unknown) {
            nodes.shrinkRetainingCapacity(start);
            continue;
        }
        try sites.append(gpa, .{ .inst = use.inst, .which = use.which, .shape = .{ .start = start, .len = len } });
    }
    const out_sites = try sites.toOwnedSlice(gpa);
    errdefer gpa.free(out_sites);
    return .{ .sites = out_sites, .nodes = try nodes.toOwnedSlice(gpa) };
}

/// The pre-order nodes of `v`, owned by `gpa`: one type outside a debug row,
/// in the row's own form — the message type the page fuzzer generates
/// values of (`dump --stage=writes --msg-types`, browser-direct.md §8.3,
/// amended 2026-10-09), read as `Debug.toString` reads a printed value's.
pub fn shape(gpa: Allocator, store: *TypeStore, interner: *const InternPool.Global, v: Var) Allocator.Error![]Dispatch.DebugNode {
    var nodes: std.ArrayList(Dispatch.DebugNode) = .empty;
    defer nodes.deinit(gpa);
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    var fields: std.ArrayList(TypeStore.Field) = .empty;
    defer fields.deinit(gpa);
    try walk(gpa, store, interner, v, &nodes, &stack, &fields);
    return nodes.toOwnedSlice(gpa);
}

/// Append `root`'s nodes, pre-order, every subtree past `max_nodes`
/// `unknown`. Without recursion: a type is nested as deep as it is written.
fn walk(
    gpa: Allocator,
    store: *TypeStore,
    interner: *const InternPool.Global,
    root: Var,
    nodes: *std.ArrayList(Dispatch.DebugNode),
    stack: *std.ArrayList(Item),
    fields: *std.ArrayList(TypeStore.Field),
) Allocator.Error!void {
    stack.clearRetainingCapacity();
    try stack.append(gpa, .{ .type = root });
    var written: u32 = 0;
    while (stack.pop()) |item| {
        written += 1;
        switch (item) {
            .field => |f| {
                try nodes.append(gpa, .{ .kind = .field, .count = 1, .value = @backingInt(f.name) });
                try stack.append(gpa, .{ .type = f.value });
            },
            .type => |t| {
                if (written > max_nodes) {
                    try nodes.append(gpa, .{ .kind = .unknown });
                    continue;
                }
                try node(gpa, store, interner, t, nodes, stack, fields);
            },
        }
    }
}

/// What is still to be written: a type, or a record's field and then its
/// type.
const Item = union(enum) {
    type: Var,
    field: TypeStore.Field,
};

/// `v`'s own node, its children pushed so that they pop in order.
fn node(
    gpa: Allocator,
    store: *TypeStore,
    interner: *const InternPool.Global,
    v: Var,
    nodes: *std.ArrayList(Dispatch.DebugNode),
    stack: *std.ArrayList(Item),
    fields: *std.ArrayList(TypeStore.Field),
) Allocator.Error!void {
    switch (store.resolvedContent(v)) {
        // Which type a variable holds is not known here, and an `err` is a
        // hole a message already covers.
        .flex, .rigid, .err, .alias => try nodes.append(gpa, .{ .kind = .unknown }),
        .structure => |flat| switch (flat) {
            .unit => try nodes.append(gpa, .{ .kind = .unit }),
            .func => try nodes.append(gpa, .{ .kind = .function }),
            .empty_record => try nodes.append(gpa, .{ .kind = .record }),
            .tuple => {
                const elements = Walk.positions(store, v);
                try nodes.append(gpa, .{ .kind = .tuple, .count = @intCast(elements.len) });
                var k = elements.len;
                while (k > 0) {
                    k -= 1;
                    try stack.append(gpa, .{ .type = elements[k] });
                }
            },
            .app => |a| {
                const args = Walk.positions(store, v);
                try nodes.append(gpa, .{ .kind = .named, .count = @intCast(args.len), .value = a.type.int() });
                var k = args.len;
                while (k > 0) {
                    k -= 1;
                    try stack.append(gpa, .{ .type = args[k] });
                }
            },
            .record => |r| {
                // The whole row, an open end left out: what the printer
                // does not find here it reads by representation.
                fields.clearRetainingCapacity();
                var concatenated = false;
                _ = try Walk.recordRow(store, r, fields, gpa, &concatenated);
                // By TEXT: a `Symbol` id depends on `--jobs` (§17).
                std.mem.sort(TypeStore.Field, fields.items, interner, struct {
                    fn lessThan(pool: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
                        return std.mem.lessThan(u8, pool.slice(a.name), pool.slice(b.name));
                    }
                }.lessThan);
                try nodes.append(gpa, .{ .kind = .record, .count = @intCast(fields.items.len) });
                var k = fields.items.len;
                while (k > 0) {
                    k -= 1;
                    try stack.append(gpa, .{ .field = fields.items[k] });
                }
            },
        },
    }
}
