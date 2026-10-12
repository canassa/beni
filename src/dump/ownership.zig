//! `beni dump --stage=ownership` (`docs/design/ownership-checker.md` §9):
//! every demand of every module the argument names, with its verdict.
//!
//! ```
//! module Main
//!   12:13 construction acc: accepted param
//!   19:12 List.push xs: rejected later-use: xs, read at 20:5
//!   demands 2: accepted 1 (fresh 0, call 0, param 1, callback-param 0), rejected 1
//! total 2: accepted 1 (fresh 0, call 0, param 1, callback-param 0), rejected 1
//! cause later-use 1
//! ```
//!
//! One line per demand, in source order; nothing printed is an id.

const std = @import("std");
const Ownership = @import("../own/Ownership.zig");

pub const Error = std.Io.Writer.Error;

const Counts = struct {
    accepted: [4]u32 = @splat(0),
    rejected: [@typeInfo(Ownership.Cause).@"enum".field_names.len]u32 = @splat(0),

    fn add(c: *Counts, v: Ownership.Verdict) void {
        switch (v) {
            .accepted => |a| c.accepted[@backingInt(a)] += 1,
            .rejected => |r| c.rejected[@backingInt(r)] += 1,
        }
    }

    fn merge(c: *Counts, o: Counts) void {
        for (&c.accepted, o.accepted) |*x, y| x.* += y;
        for (&c.rejected, o.rejected) |*x, y| x.* += y;
    }

    fn write(c: Counts, w: *std.Io.Writer, label: []const u8) Error!void {
        var acc: u32 = 0;
        for (c.accepted) |x| acc += x;
        var rej: u32 = 0;
        for (c.rejected) |x| rej += x;
        try w.print("{s} {d}: accepted {d} (fresh {d}, call {d}, param {d}, callback-param {d}), rejected {d}\n", .{
            label, acc + rej, acc, c.accepted[0], c.accepted[1], c.accepted[2], c.accepted[3], rej,
        });
    }
};

fn acceptText(a: Ownership.Accept) []const u8 {
    return switch (a) {
        .fresh => "fresh",
        .call => "call",
        .param => "param",
        .callback_param => "callback-param",
    };
}

pub fn write(w: *std.Io.Writer, reports: []const Ownership.ModuleReport, module_names: []const []const u8) Error!void {
    var total: Counts = .{};
    for (reports) |r| {
        try w.print("module {s}", .{module_names[r.module]});
        if (!r.checked) {
            try w.writeAll(" (not checked)\n");
            continue;
        }
        try w.writeByte('\n');
        var counts: Counts = .{};
        for (r.demands) |d| {
            try w.print("  {d}:{d} {s} {s}: ", .{ d.position.line, d.position.col, d.op, d.base });
            switch (d.verdict) {
                .accepted => |a| try w.print("accepted {s}", .{acceptText(a)}),
                .rejected => |c| {
                    try w.print("rejected {s}", .{c.text()});
                    if (d.detail.len != 0) try w.print(": {s}", .{d.detail});
                    if (c.approximate()) try w.writeAll(" (approx)");
                },
            }
            try w.writeByte('\n');
            counts.add(d.verdict);
        }
        try counts.write(w, "  demands");
        total.merge(counts);
    }
    try total.write(w, "total");
    for (total.rejected, 0..) |n, i| {
        if (n == 0) continue;
        const c: Ownership.Cause = @fromBackingInt(@intCast(i));
        try w.print("cause {s} {d}\n", .{ c.text(), n });
    }
}
