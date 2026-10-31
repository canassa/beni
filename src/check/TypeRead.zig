//! Shared written-type child order; private publication uses an explicit stack.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");
const Inst = Bir.Inst.Index;
pub const Work = struct { nodes: u64 = 0, aliases: u64 = 0 };
pub fn count(bir: *const Bir, inst: Inst) usize {
    const d = bir.instData(inst);
    return switch (bir.instTag(inst)) {
        .type_fn => bir.extraSlice(bir.subRange(@fromBackingInt(d.lhs)), Inst).len + 1,
        .type_tuple => bir.extraSlice(Bir.inlineRange(d), Inst).len,
        .type_record => bir.extraSlice(Bir.inlineRange(d), Bir.Field).len,
        .type_record_ext => bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Field).len + 1,
        .type_app => bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Inst).len,
        else => 0,
    };
}
pub fn child(bir: *const Bir, inst: Inst, index: usize) Inst {
    const d = bir.instData(inst);
    return switch (bir.instTag(inst)) {
        .type_fn => blk: {
            const args = bir.extraSlice(bir.subRange(@fromBackingInt(d.lhs)), Inst);
            break :blk if (index < args.len) args[index] else @fromBackingInt(d.rhs);
        },
        .type_tuple => bir.extraSlice(Bir.inlineRange(d), Inst)[index],
        .type_record => bir.extraSlice(Bir.inlineRange(d), Bir.Field)[index].value,
        .type_record_ext => blk: {
            const fields = bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Field);
            break :blk if (index < fields.len) fields[index].value else @fromBackingInt(d.lhs);
        },
        .type_app => bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Inst)[index],
        else => unreachable,
    };
}
pub fn read(b: anytype, inst: Inst, comptime finish: anytype) std.mem.Allocator.Error!TypeStore.Var {
    const Frame = struct { inst: Inst, start: usize, next: usize = 0 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(b.scratch);
    var values: std.ArrayList(TypeStore.Var) = .empty;
    defer values.deinit(b.scratch);
    try frames.append(b.scratch, .{ .inst = inst, .start = 0 });
    while (frames.items.len != 0) {
        const i = frames.items.len - 1;
        const f = frames.items[i];
        if (f.next < count(b.bir, f.inst)) {
            frames.items[i].next += 1;
            try frames.append(b.scratch, .{ .inst = child(b.bir, f.inst, f.next), .start = values.items.len });
            continue;
        }
        if (b.private_work) |work| work.nodes += 1;
        const result = try finish(b, f.inst, values.items[f.start..]);
        values.shrinkRetainingCapacity(f.start);
        _ = frames.pop();
        if (frames.items.len == 0) return result;
        try values.append(b.scratch, result);
    }
    unreachable;
}
