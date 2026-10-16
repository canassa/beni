//! `beni dump --stage=ownership` (`docs/design/ownership-checker.md` §9,
//! §16.11): every demand of every module the argument names, with its
//! verdict, then each declaration's summary.
//!
//! ```
//! module Main
//!   12:13 construction acc: accepted param
//!   19:12 List.push xs: rejected later-use: xs is read again at 20:5
//!   summary grow: π1 RAW; res π1
//!   demands 2: accepted 1 (fresh 0, call 0, param 1, callback-param 0; assumed 0), pending 0, rejected 1
//! total 2: accepted 1 (fresh 0, call 0, param 1, callback-param 0; assumed 0), pending 0, rejected 1
//! cause later-use 1
//! ```
//!
//! One line per demand, in source order; nothing printed is an id.
//! `--ownership-totals` prints the `total`, `cause` and `pending` lines alone.

const std = @import("std");
const Ownership = @import("../own/Ownership.zig");

pub const Error = std.Io.Writer.Error;

pub const Options = struct { totals_only: bool = false };

const Counts = struct {
    accepted: [@typeInfo(Ownership.Accept).@"enum".field_names.len]u32 = @splat(0),
    rejected: [@typeInfo(Ownership.Cause).@"enum".field_names.len]u32 = @splat(0),
    pending: u32 = 0,
    assumed: u32 = 0,

    fn add(c: *Counts, d: Ownership.Demand) void {
        switch (d.verdict) {
            .accepted => |a| {
                c.accepted[@backingInt(a)] += 1;
                if (d.assumed) c.assumed += 1;
            },
            .pending => c.pending += 1,
            .rejected => |r| c.rejected[@backingInt(r)] += 1,
        }
    }

    fn merge(c: *Counts, o: Counts) void {
        for (&c.accepted, o.accepted) |*x, y| x.* += y;
        for (&c.rejected, o.rejected) |*x, y| x.* += y;
        c.pending += o.pending;
        c.assumed += o.assumed;
    }

    fn write(c: Counts, w: *std.Io.Writer, label: []const u8) Error!void {
        var acc: u32 = 0;
        for (c.accepted) |x| acc += x;
        var rej: u32 = 0;
        for (c.rejected) |x| rej += x;
        try w.print("{s} {d}: accepted {d} (", .{ label, acc + rej + c.pending, acc });
        // Every kind, in `Accept`'s order, so a new kind cannot be dropped.
        for (c.accepted, 0..) |n, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s} {d}", .{ acceptText(@fromBackingInt(@intCast(i))), n });
        }
        try w.print("; assumed {d}), pending {d}, rejected {d}\n", .{ c.assumed, c.pending, rej });
    }
};

fn acceptText(a: Ownership.Accept) []const u8 {
    return switch (a) {
        .fresh => "fresh",
        .call => "call",
        .param => "param",
        .callback_param => "callback-param",
        .once => "once",
        .entry => "entry",
    };
}

pub fn write(w: *std.Io.Writer, reports: []const Ownership.ModuleReport, module_names: []const []const u8, options: Options) Error!void {
    var total: Counts = .{};
    var limits: usize = 0;
    for (reports) |r| {
        if (!options.totals_only) try w.print("module {s}", .{module_names[r.module]});
        if (!r.checked) {
            if (!options.totals_only) try w.writeAll(" (not checked)\n");
            continue;
        }
        if (!options.totals_only) try w.writeByte('\n');
        var counts: Counts = .{};
        for (r.demands) |d| {
            counts.add(d);
            if (options.totals_only) continue;
            try w.print("  {d}:{d} {s} {s}: ", .{ d.position.line, d.position.col, d.op, d.base });
            switch (d.verdict) {
                .accepted => |a| try w.print("accepted {s}", .{acceptText(a)}),
                .pending => try w.writeAll("pending"),
                .rejected => |c| try w.print("rejected {s}", .{c.text()}),
            }
            if (d.verdict != .accepted and d.detail.len != 0) try w.print(": {s}", .{d.detail});
            if (d.note.len != 0) try w.print(" ({s})", .{d.note});
            if (d.verdict == .rejected and d.approx) try w.writeAll(" (approx)");
            try w.writeByte('\n');
        }
        if (!options.totals_only) {
            for (r.summaries) |s| try w.print("  {s}\n", .{s.text});
            for (r.limits) |h| switch (h.limit) {
                .rounds => try w.print("  limit {s}: rounds, unsettled after {d}\n", .{ h.name, h.limit.cap() }),
                else => try w.print("  limit {s}: {s} {d}, over {d}\n", .{ h.name, h.limit.text(), h.at, h.limit.cap() }),
            };
            try counts.write(w, "  demands");
        }
        total.merge(counts);
        limits += r.limits.len;
    }
    try total.write(w, "total");
    if (limits != 0) try w.print("limits {d}\n", .{limits});
    for (total.rejected, 0..) |n, i| {
        if (n == 0) continue;
        const c: Ownership.Cause = @fromBackingInt(@intCast(i));
        try w.print("cause {s} {d}\n", .{ c.text(), n });
    }
}
