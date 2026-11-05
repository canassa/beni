//! L5: a declaration's `summary` lines (`docs/design/ownership-v2.md` §2.10,
//! §2.11.3): its contract's, then each called contract's, as `f@.run`.
//!
//! Obligations kept here: none (text).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const ContractText = @import("ContractText.zig");

pub fn lines(t: *const Contract.Table, gpa: Allocator, arena: Allocator, c: Contract.Id, name: []const u8, slots: *const Slots.Table, places: *const Place.Table, names: ContractText.Names, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var buf: std.Io.Writer.Allocating = .init(arena);
    buf.writer.print("summary {s}: ", .{name}) catch return error.OutOfMemory;
    ContractText.print(t, gpa, c, slots, places, names, &buf.writer) catch return error.OutOfMemory;
    try out.append(arena, buf.written());
    for (t.calledRun(c)) |x| {
        var cb: std.Io.Writer.Allocating = .init(arena);
        cb.writer.print("summary {s}@", .{name}) catch return error.OutOfMemory;
        ContractText.relText(slots, places, names, &cb.writer, x[0]) catch return error.OutOfMemory;
        cb.writer.writeAll(": ") catch return error.OutOfMemory;
        ContractText.print(t, gpa, x[1], slots, places, names, &cb.writer) catch return error.OutOfMemory;
        try out.append(arena, cb.written());
    }
}
