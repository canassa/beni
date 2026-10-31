//! Shared ordinary-view operations; owners supply immutable lexical environments.
const std = @import("std");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const PrivateTerms = @import("../check/PrivateTerms.zig");
pub fn projections(gpa: std.mem.Allocator, types: *const Interface) std.mem.Allocator.Error![]u32 {
    const heads = try gpa.alloc(u32, types.terms.len);
    errdefer gpa.free(heads);
    @memset(heads, PrivateTerms.no_projection);
    const colors = try gpa.alloc(u8, heads.len);
    defer gpa.free(colors);
    @memset(colors, 0);
    const Pending = struct { node: u32, next: u32 = 0 };
    var stack: std.ArrayList(Pending) = .empty;
    defer stack.deinit(gpa);
    for (0..heads.len) |start| {
        if (colors[start] != 0) continue;
        try stack.append(gpa, .{ .node = @intCast(start) });
        colors[start] = 1;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            if (PrivateTerms.child(types, top.node, top.next, true)) |next| {
                top.next += 1;
                if (colors[next] != 0) continue;
                colors[next] = 1;
                try stack.append(gpa, .{ .node = next });
                continue;
            }
            const node = top.node;
            const term = types.terms.get(node);
            switch (term.tag) {
                .@"var" => heads[node] = term.lhs,
                .alias => {
                    const projection = heads[types.type_refs[term.lhs].body.int()];
                    if (projection != PrivateTerms.no_projection) heads[node] = heads[types.range(term.rhs)[projection]];
                },
                else => {},
            }
            colors[node] = 2;
            _ = stack.pop();
        }
    }
    return heads;
}
/// Copy rows across calls that may grow owner tables. Never return stack frames.
pub fn normalize(comptime Owner: type, owner: *Owner, gpa: std.mem.Allocator, original: Owner.ViewIndex, comptime stop_at_boundary: bool) Owner.Error!Owner.ViewIndex {
    var view = owner.getView(original);
    while (true) {
        owner.noteStep();
        const types = owner.interface(view);
        const term = types.term(view.term);
        switch (term.tag) {
            .@"var" => {
                if (try owner.actual(view, term.lhs)) |actual| view = actual else break;
            },
            .alias => {
                if (stop_at_boundary and owner.boundary(view, term)) break;
                const args = types.range(term.rhs);
                const body = types.type_refs[term.lhs].body;
                if (owner.projection(view, body)) |parameter| {
                    view.term = @fromBackingInt(args[parameter]);
                    continue;
                }
                view = try owner.alias(gpa, view, term);
            },
            else => break,
        }
    }
    return owner.add(gpa, view);
}
pub const Field = union(enum) { child: Interface.TermIndex, extension: Interface.TermIndex, generic, mismatch };
pub fn field(types: *const Interface, term_index: Interface.TermIndex, symbol: InternPool.Symbol) Field {
    const term = types.term(term_index);
    if (term.tag == .@"var") return .generic;
    if (term.tag != .record) return .mismatch;
    const fields = types.range(term.lhs);
    var i: usize = 0;
    while (i < fields.len) : (i += 2) if (types.symbol(@fromBackingInt(fields[i])) == symbol) return .{ .child = @fromBackingInt(fields[i + 1]) };
    return .{ .extension = @fromBackingInt(term.rhs) };
}
