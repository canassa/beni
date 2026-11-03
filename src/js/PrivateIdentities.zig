//! Private identity atom numbering. Runs once after lowering and before
//! release specialisation, including for libraries. Cached dispatch stores
//! checked identity grammar, never these build-specific ordinals.
const std = @import("std");
const JsIr = @import("JsIr.zig");
const Rename = @import("Rename.zig");
const Allocator = std.mem.Allocator;

fn separator(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', ',', '=', '|', '-', '>' => true,
        else => false,
    };
}

pub fn compact(gpa: Allocator, scratch: Allocator, modules: []const *JsIr) Allocator.Error!void {
    var atoms: std.StringHashMapUnmanaged(u32) = .empty;
    for (modules) |ir| {
        for (ir.nodes.items(.flags), ir.nodes.items(.data)) |flags, data| {
            if (!flags.identity) continue;
            const text = ir.string_bytes[data.lhs..][0..data.rhs];
            var cursor: usize = 0;
            while (cursor < text.len) {
                if (separator(text[cursor])) {
                    cursor += 1;
                    continue;
                }
                const start = cursor;
                while (cursor < text.len and !separator(text[cursor])) cursor += 1;
                const entry = try atoms.getOrPut(scratch, text[start..cursor]);
                if (!entry.found_existing) entry.key_ptr.* = try scratch.dupe(u8, entry.key_ptr.*);
            }
        }
    }
    if (atoms.count() == 0) return;
    const ordered = try scratch.alloc([]const u8, atoms.count());
    var keys = atoms.keyIterator();
    var count: usize = 0;
    while (keys.next()) |key| : (count += 1) ordered[count] = key.*;
    std.mem.sort([]const u8, ordered, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (ordered, 0..) |atom, ordinal| atoms.getPtr(atom).?.* = @intCast(ordinal);

    for (modules) |ir| {
        const marked = for (ir.nodes.items(.flags)) |flags| {
            if (flags.identity) break true;
        } else false;
        if (!marked) continue;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, ir.string_bytes);
        for (ir.nodes.items(.flags), ir.nodes.items(.data)) |*flags, *data| {
            if (!flags.identity) continue;
            // Read from the old immutable bytes: growing the replacement
            // buffer cannot invalidate either these slices or the atom keys.
            const text = ir.string_bytes[data.lhs..][0..data.rhs];
            const offset: u32 = @intCast(bytes.items.len);
            var cursor: usize = 0;
            while (cursor < text.len) {
                if (separator(text[cursor])) {
                    try bytes.append(gpa, text[cursor]);
                    cursor += 1;
                    continue;
                }
                const start = cursor;
                while (cursor < text.len and !separator(text[cursor])) cursor += 1;
                var buffer: [8]u8 = undefined;
                try bytes.appendSlice(gpa, Rename.spell(atoms.get(text[start..cursor]).?, &buffer));
            }
            data.* = .{ .lhs = offset, .rhs = @intCast(bytes.items.len - offset) };
            flags.identity = false;
        }
        const old = ir.string_bytes;
        ir.string_bytes = try bytes.toOwnedSlice(gpa);
        gpa.free(old);
    }
}
