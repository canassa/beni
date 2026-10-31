//! Private reachable-type postorder; public scheme depth policy is unchanged.
const std = @import("std");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Var = TypeStore.Var;
pub const Frame = struct { root: Var, start: u32, len: u32, next: u32 = 0 };

pub fn write(w: anytype, v: Var, comptime ops: anytype) std.mem.Allocator.Error!Interface.TermIndex {
    const root = w.store.find(v);
    if (ops.live(w, root) and w.memo[root.int()] != .none) return w.memo[root.int()];
    w.scoped_frames.clearRetainingCapacity();
    w.scoped_children.clearRetainingCapacity();
    w.scoped_active = true;
    defer w.scoped_active = false;
    try push(w, root, ops);
    while (w.scoped_frames.items.len != 0) {
        const at = w.scoped_frames.items.len - 1;
        const frame = w.scoped_frames.items[at];
        if (frame.next < frame.len) {
            const next = w.store.find(w.scoped_children.items[frame.start + frame.next]);
            w.scoped_frames.items[at].next += 1;
            if (ops.live(w, next)) {
                if (w.memo[next.int()] != .none) continue;
                switch (w.store.content(next)) {
                    .structure, .alias => {
                        // A gray structural node is a source cycle. The
                        // temporary result is discarded by addScopedRoots.
                        w.scoped_invalid = true;
                        return ops.term(w, .unit, 0, 0);
                    },
                    else => {},
                }
            }
            try push(w, next, ops);
            continue;
        }
        _ = try ops.writeVar(w, frame.root);
        _ = w.scoped_frames.pop();
    }
    return w.memo[root.int()];
}

fn push(w: anytype, root: Var, comptime ops: anytype) std.mem.Allocator.Error!void {
    _ = ops.claim(w, root);
    const start: u32 = @intCast(w.scoped_children.items.len);
    if (w.store.content(root) == .alias) {
        // Structural successor zero is the expansion. Canonical alias rows
        // export that separately; this occurrence exports only its arguments.
        var i: u32 = 1;
        while (Walk.child(w.store, root, i, .structural)) |argument| : (i += 1)
            try w.scoped_children.append(w.gpa, argument);
    } else {
        w.scoped_fields.clearRetainingCapacity();
        var extension: ?Var = null;
        var i: u32 = 0;
        while (Walk.stepped(w.store, root, i)) |child| : (i += 1) {
            switch (child.kind) {
                .field => try w.scoped_fields.append(w.gpa, .{ .name = @fromBackingInt(child.index), .value = child.v }),
                .extension => extension = child.v,
                else => try w.scoped_children.append(w.gpa, child.v),
            }
        }
        std.mem.sort(TypeStore.Field, w.scoped_fields.items, w.interner, struct {
            fn less(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
                return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
            }
        }.less);
        for (w.scoped_fields.items) |field| try w.scoped_children.append(w.gpa, field.value);
        if (extension) |ext| try w.scoped_children.append(w.gpa, ext);
    }
    try w.scoped_frames.append(w.gpa, .{ .root = root, .start = start, .len = @intCast(w.scoped_children.items.len - start) });
}

test "continuation plan owner constraint parameters precede unrelated site parameters" {
    const gpa = std.testing.allocator;
    const Schemes = @import("Schemes.zig");
    const Types = @import("Types.zig");
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    const a_name = try interner.getOrPut(gpa, "a");
    const b_name = try interner.getOrPut(gpa, "b");
    const c_name = try interner.getOrPut(gpa, "c");
    const method = try interner.getOrPut(gpa, "m");
    const a = try store.fresh(.{ .flex = .{ .name = a_name.toOptional() } }, TypeStore.generalized);
    const b = try store.fresh(.{ .flex = .{ .name = b_name.toOptional() } }, TypeStore.generalized);
    const c = try store.fresh(.{ .flex = .{ .name = c_name.toOptional() } }, TypeStore.generalized);
    const constraint = try store.fresh(.{ .structure = .{ .func = .{ .params = try store.addVars(&.{b}), .result = b } } }, TypeStore.generalized);
    const set = try store.addConstraints(&.{.{ .name = method, .fn_var = constraint, .region = @fromBackingInt(0), .origin = .where_clause }});
    store.setContent(a, .{ .flex = .{ .name = a_name.toOptional(), .constraints = set.toOptional() } });
    const owner = try store.fresh(.{ .structure = .{ .func = .{ .params = try store.addVars(&.{a}), .result = a } } }, TypeStore.generalized);
    const site = try store.fresh(.{ .structure = .{ .func = .{ .params = try store.addVars(&.{c}), .result = c } } }, TypeStore.generalized);
    const no_types: Types = .empty;
    var writer: Schemes.Writer = .init(gpa, &store, &interner, &no_types, 0);
    defer writer.deinit();
    writer.identities = &.{1};
    _ = try writer.addScopedRoots(&.{ owner, owner, site }, &.{});
    var types: Interface = .empty;
    defer types.deinit(gpa);
    try writer.attach(&types);
    const scheme = types.schemes[0];
    try std.testing.expectEqual(@as(u32, 3), scheme.quantified_count);
    const b_flags = types.quantified(scheme, 1);
    const c_flags = types.quantified(scheme, 2);
    try std.testing.expectEqualStrings("b", interner.slice(types.symbol(b_flags.name.unwrap().?)));
    try std.testing.expectEqualStrings("c", interner.slice(types.symbol(c_flags.name.unwrap().?)));
    try std.testing.expect(b_flags.identity);
    try std.testing.expect(!c_flags.identity);
    const owner_quantifier = types.quantified(scheme, 0);
    try std.testing.expectEqual(@as(u32, 1), owner_quantifier.constraints_len);
    const exported = types.term(types.quantifiedConstraint(owner_quantifier, 0).type);
    try std.testing.expectEqual(Interface.Term.Tag.func, exported.tag);
    try std.testing.expectEqual(@as(u32, 1), types.term(@fromBackingInt(@intCast(types.range(exported.lhs)[0]))).lhs);
    try std.testing.expectEqual(@as(u32, 1), types.term(@fromBackingInt(@intCast(exported.rhs))).lhs);
}
