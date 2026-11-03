//! Checked source operands used to close a lowering's heterogeneous packets.
//! These demands use the ordinary identity fixpoint and dispatch terms; they
//! are not method evidence for the source expression itself.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Context = @import("Context.zig");
const Instantiate = @import("Instantiate.zig");

pub fn uses(cx: *const Context, existing: []const Instantiate.IdentityUse) std.mem.Allocator.Error![]const Instantiate.IdentityUse {
    const kinds = cx.graph.markup.operand_evidence;
    if (!cx.bir.uses_markup or kinds == 0) return existing;
    var collect: Collect = .{
        .cx = cx,
        .selected = try cx.scratch.alloc(bool, cx.bir.insts.len),
    };
    @memset(collect.selected, false);
    for (cx.bir.decls, 0..) |decl, owner| {
        collect.decl = @intCast(owner);
        var i = decl.inst_start.int();
        while (i < decl.inst_end.int()) : (i += 1) {
            const inst: Bir.Inst.Index = @fromBackingInt(@intCast(i));
            if (cx.bir.instTag(inst) == .markup) try collect.node(@fromBackingInt(@intCast(cx.bir.instData(inst).lhs)));
        }
    }
    var out: std.ArrayList(Instantiate.IdentityUse) = .empty;
    try out.appendSlice(cx.scratch, existing);
    for (cx.bir.decls, 0..) |decl, owner| {
        var i = decl.inst_start.int();
        while (i < decl.inst_end.int()) : (i += 1) {
            if (!collect.selected[i] or i >= cx.inst_type.len) continue;
            const value = cx.inst_type[i].unwrap() orelse continue;
            for (0..2) |kind| {
                if (kinds & (@as(u8, 1) << @intCast(kind)) == 0) continue;
                try out.append(cx.scratch, .{
                    .inst = @fromBackingInt(@intCast(i)),
                    .decl = @intCast(owner),
                    .module = cx.module,
                    .value = 0,
                    .quantified = 0,
                    .v = value,
                    .checked = kind == 1,
                    .operand = true,
                });
            }
        }
    }
    return out.items;
}

const Collect = struct {
    cx: *const Context,
    selected: []bool,
    decl: u32 = 0,

    fn value(c: *Collect, inst: Bir.Inst.Index) void {
        c.selected[inst.int()] = true;
    }

    fn optional(c: *Collect, inst: Bir.Inst.OptionalIndex) void {
        if (inst.unwrap()) |i| c.value(i);
    }

    fn local(c: *Collect, index: u32) void {
        const d = c.cx.bir.decls[c.decl];
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) {
            const inst: Bir.Inst.Index = @fromBackingInt(@intCast(i));
            if (c.cx.bir.instTag(inst) == .local and c.cx.bir.instData(inst).lhs == index) c.value(inst);
        }
    }

    fn items(c: *Collect, start: Bir.ExtraIndex, end: Bir.ExtraIndex) !void {
        const bir = c.cx.bir;
        for (bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |at| {
            const item = bir.extraData(at, Bir.MarkupItem);
            c.optional(item.value);
            for (bir.extraSlice(.{ .start = item.entries_start, .end = item.entries_end }, Bir.ExtraIndex)) |entry| {
                const e = bir.extraData(entry, Bir.MarkupEntry);
                c.value(e.value);
            }
        }
    }

    fn children(c: *Collect, start: Bir.ExtraIndex, end: Bir.ExtraIndex) std.mem.Allocator.Error!void {
        for (c.cx.bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |at| try c.node(at);
    }

    fn node(c: *Collect, at: Bir.ExtraIndex) std.mem.Allocator.Error!void {
        const bir = c.cx.bir;
        switch (bir.markupKind(at)) {
            .text => {},
            .hole => c.value(bir.extraData(at, Bir.MarkupHole).value),
            .element => {
                const e = bir.extraData(at, Bir.MarkupElement);
                try c.items(e.items_start, e.items_end);
                try c.children(e.children_start, e.children_end);
            },
            .fragment => {
                const e = bir.extraData(at, Bir.MarkupFragment);
                try c.children(e.children_start, e.children_end);
            },
            .component => {
                const e = bir.extraData(at, Bir.MarkupComponent);
                try c.items(e.props_start, e.props_end);
                c.optional(e.spread);
                if (e.children_form != .absent) try c.children(e.children_start, e.children_end);
            },
            .@"for", .show => {
                const e = bir.extraData(at, Bir.MarkupForm);
                c.optional(e.list);
                c.optional(e.keyed);
                c.optional(e.fallback);
                if (e.row != Bir.none_extra) {
                    const row = bir.extraData(@fromBackingInt(@intCast(e.row)), Bir.MarkupRow);
                    c.value(row.function);
                    for (bir.extraSlice(.{ .start = row.captures_start, .end = row.captures_end }, u32)) |capture| c.local(capture);
                }
            },
        }
    }
};
