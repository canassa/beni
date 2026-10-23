//! Identity facts for renderers. Only values whose type proves immutable
//! may suppress a render. Unknown polymorphic values carry no such proof.
const std = @import("std");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");
const Dispatch = @import("Dispatch.zig");
const InternPool = @import("../InternPool.zig");
const Bir = @import("../bir/Bir.zig");

pub fn build(gpa: std.mem.Allocator, scratch: std.mem.Allocator, store: *TypeStore, types: *const Types, insts: []const TypeStore.Var.Optional, locals: []const TypeStore.Var.Optional, interner: *const InternPool.Global, out: *Dispatch) !void {
    var b: Builder = .{ .gpa = gpa, .scratch = scratch, .store = store, .types = types, .interner = interner };
    errdefer b.facts.deinit(gpa);
    errdefer b.links.deinit(gpa);
    defer b.path.deinit(scratch);
    defer b.pending.deinit(scratch);
    defer b.frames.deinit(scratch);
    for (insts, 0..) |v, k| if (v.unwrap()) |t| {
        if (try b.stable(t)) try b.add(false, @intCast(k));
    };
    for (locals, 0..) |v, k| if (v.unwrap()) |t| try b.local(@intCast(k), t);
    try b.canonicalize();
    out.render_facts = try b.facts.toOwnedSlice(gpa);
    out.render_links = try b.links.toOwnedSlice(gpa);
}

const Builder = struct {
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    facts: std.ArrayList(Dispatch.RenderFact) = .empty,
    links: std.ArrayList(u32) = .empty,
    path: std.ArrayList(u32) = .empty,
    pending: std.ArrayList(TypeStore.Var) = .empty,
    frames: std.ArrayList(Frame) = .empty,

    const Frame = struct { value: TypeStore.Var, depth: usize, link: ?u32 = null };

    // Row extension layout is an inference detail. Publish paths in text
    // order, then rewrite their spans in that order, so session-assigned
    // symbol ids and equivalent extension partitions cannot move bytes.
    fn canonicalize(b: *Builder) std.mem.Allocator.Error!void {
        std.mem.sort(Dispatch.RenderFact, b.facts.items, b, struct {
            fn less(ctx: *const Builder, a: Dispatch.RenderFact, c: Dispatch.RenderFact) bool {
                if (a.local != c.local) return !a.local;
                if (a.index != c.index) return a.index < c.index;
                const xs = ctx.links.items[a.path.start..][0..a.path.len];
                const ys = ctx.links.items[c.path.start..][0..c.path.len];
                for (0..@min(xs.len, ys.len)) |k| {
                    const x = xs[k];
                    const y = ys[k];
                    if (x == y) continue;
                    const xt = x & Bir.tuple_link != 0;
                    const yt = y & Bir.tuple_link != 0;
                    if (xt != yt) return !xt;
                    if (xt) return x < y;
                    return std.mem.order(u8, ctx.interner.slice(@fromBackingInt(@intCast(x))), ctx.interner.slice(@fromBackingInt(@intCast(y)))) == .lt;
                }
                return xs.len < ys.len;
            }
        }.less);
        var links: std.ArrayList(u32) = .empty;
        errdefer links.deinit(b.gpa);
        for (b.facts.items) |*fact| {
            const start: u32 = @intCast(links.items.len);
            try links.appendSlice(b.gpa, b.links.items[fact.path.start..][0..fact.path.len]);
            fact.path.start = start;
        }
        b.links.deinit(b.gpa);
        b.links = links;
    }

    fn stable(b: *Builder, v: TypeStore.Var) std.mem.Allocator.Error!bool {
        b.pending.clearRetainingCapacity();
        try b.pending.append(b.scratch, v);
        const mark = b.store.nextMark();
        while (b.pending.pop()) |next| {
            const root = b.store.find(next);
            if (b.store.mark(root) == mark) continue;
            b.store.setMark(root, mark);
            switch (b.store.resolvedContent(root)) {
                .structure => |shape| switch (shape) {
                    .unit, .func => {},
                    .app => |app| {
                        if (app.type == .none) return false;
                        const entry = b.types.entry(app.type);
                        if (entry.schema_endpoint or entry.holds_mutable) return false;
                        try b.pending.appendSlice(b.scratch, Walk.positions(b.store, root));
                    },
                    .tuple => try b.pending.appendSlice(b.scratch, Walk.positions(b.store, root)),
                    else => return false,
                },
                .flex, .rigid => |flags| if (flags.kind != .number and flags.kind != .dict_key) return false,
                else => return false,
            }
        }
        return true;
    }

    fn add(b: *Builder, local_: bool, index: u32) !void {
        const start: u32 = @intCast(b.links.items.len);
        try b.links.appendSlice(b.gpa, b.path.items);
        try b.facts.append(b.gpa, .{ .local = local_, .index = index, .path = .{ .start = start, .len = @intCast(b.path.items.len) } });
    }

    fn local(b: *Builder, index: u32, v: TypeStore.Var) std.mem.Allocator.Error!void {
        b.path.clearRetainingCapacity();
        b.frames.clearRetainingCapacity();
        try b.frames.append(b.scratch, .{ .value = v, .depth = 0 });
        while (b.frames.pop()) |frame| {
            b.path.shrinkRetainingCapacity(frame.depth);
            if (frame.link) |link| try b.path.append(b.scratch, link);
            if (try b.stable(frame.value)) try b.add(true, index);
            switch (b.store.resolvedContent(frame.value)) {
                .structure => |shape| switch (shape) {
                    .record => |record| {
                        const fields = try b.scratch.dupe(TypeStore.Field, Walk.recordFields(b.store, record));
                        defer b.scratch.free(fields);
                        std.mem.sort(TypeStore.Field, fields, b.interner, struct {
                            fn less(pool: *const InternPool.Global, a: TypeStore.Field, c: TypeStore.Field) bool {
                                return std.mem.order(u8, pool.slice(a.name), pool.slice(c.name)) == .lt;
                            }
                        }.less);
                        const ext = Walk.recordExtension(record);
                        try b.frames.append(b.scratch, .{ .value = ext, .depth = b.path.items.len });
                        var k = fields.len;
                        while (k > 0) {
                            k -= 1;
                            try b.frames.append(b.scratch, .{ .value = fields[k].value, .depth = b.path.items.len, .link = @backingInt(fields[k].name) });
                        }
                    },
                    .tuple => {
                        const children = Walk.positions(b.store, frame.value);
                        var k = children.len;
                        while (k > 0) {
                            k -= 1;
                            try b.frames.append(b.scratch, .{ .value = children[k], .depth = b.path.items.len, .link = Bir.tuple_link | @as(u32, @intCast(k)) });
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
};
