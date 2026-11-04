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
        .seen = try cx.scratch.alloc(bool, cx.bir.insts.len),
    };
    @memset(collect.selected, false);
    @memset(collect.seen, false);
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
    seen: []bool,
    stack: std.ArrayList(Bir.Inst.Index) = .empty,
    decl: u32 = 0,

    fn value(c: *Collect, inst: Bir.Inst.Index) std.mem.Allocator.Error!void {
        c.selected[inst.int()] = true;
        try c.stack.append(c.cx.scratch, inst);
        while (c.stack.pop()) |cursor| {
            if (c.seen[cursor.int()]) continue;
            c.seen[cursor.int()] = true;
            // Grouped roots capture the checked reads inside an expression,
            // including both model and delta in model.count + delta.
            switch (c.cx.bir.instTag(cursor)) {
                .local => {
                    c.selected[cursor.int()] = true;
                    const local_index = c.cx.bir.instData(cursor).lhs;
                    const locals = c.cx.bir.declLocals(c.cx.bir.decls[c.decl]);
                    if (local_index < locals.len and locals[local_index].kind == .let) {
                        const def = c.cx.bir.instData(locals[local_index].inst);
                        const info = c.cx.bir.extraData(@fromBackingInt(@intCast(def.lhs)), Bir.LetDef);
                        // Grouping may move a constant let's initializer
                        // into its patch. Its free reads then become inputs.
                        if (info.params_start == info.params_end)
                            try c.stack.append(c.cx.scratch, @fromBackingInt(@intCast(def.rhs)));
                    }
                },
                .field_access, .tuple_index => c.selected[cursor.int()] = true,
                else => {},
            }
            try @import("constrain/Decl.zig").pushChildren(c.cx.bir, c.cx.scratch, cursor, &c.stack);
        }
    }

    fn optional(c: *Collect, inst: Bir.Inst.OptionalIndex) std.mem.Allocator.Error!void {
        if (inst.unwrap()) |i| try c.value(i);
    }

    fn local(c: *Collect, index: u32) std.mem.Allocator.Error!void {
        const d = c.cx.bir.decls[c.decl];
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) {
            const inst: Bir.Inst.Index = @fromBackingInt(@intCast(i));
            if (c.cx.bir.instTag(inst) == .local and c.cx.bir.instData(inst).lhs == index) try c.value(inst);
        }
    }

    fn items(c: *Collect, start: Bir.ExtraIndex, end: Bir.ExtraIndex) !void {
        const bir = c.cx.bir;
        for (bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |at| {
            const item = bir.extraData(at, Bir.MarkupItem);
            try c.optional(item.value);
            for (bir.extraSlice(.{ .start = item.entries_start, .end = item.entries_end }, Bir.ExtraIndex)) |entry| {
                const e = bir.extraData(entry, Bir.MarkupEntry);
                try c.value(e.value);
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
            .hole => try c.value(bir.extraData(at, Bir.MarkupHole).value),
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
                try c.optional(e.spread);
                if (e.children_form != .absent) try c.children(e.children_start, e.children_end);
            },
            .@"for", .show => {
                const e = bir.extraData(at, Bir.MarkupForm);
                try c.optional(e.list);
                try c.optional(e.keyed);
                try c.optional(e.fallback);
                if (e.row != Bir.none_extra) {
                    const row = bir.extraData(@fromBackingInt(@intCast(e.row)), Bir.MarkupRow);
                    try c.value(row.function);
                    for (bir.extraSlice(.{ .start = row.captures_start, .end = row.captures_end }, u32)) |capture| try c.local(capture);
                }
            },
        }
    }
};
