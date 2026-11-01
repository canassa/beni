//! L14: the report (`docs/design/ownership-v2.md` §3.7, R-7.15): per module
//! its verdict lines in source order, its own `summary` and `limit` lines,
//! its counts; then the totals and the causes in R-6.3's order. The grammar
//! is `dump --stage=ownership`'s, so a golden compares v1's verdict and
//! count lines with v2's (R-8.1).
//!
//! Obligations kept here: none (text).

const std = @import("std");
const Facts = @import("Facts.zig");
const Line = Facts.Line;

pub const Error = std.Io.Writer.Error;

pub const Options = struct { totals_only: bool = false };

/// One module's report.
pub const Module = struct {
    module: u32,
    checked: bool = true,
    lines: []const Line = &.{},
    /// v2's own lines (`summary …`, `limit …`), printed as they are.
    others: []const []const u8 = &.{},
    limits: u32 = 0,
    /// The published block (`Ownership.publish`), or null.
    block: ?[]const u8 = null,
    /// The v2 words on places without their kind: `(decl, slot, word)`.
    word_errors: []const [3]u32 = &.{},
};

/// A module's report kept past the run that made it, its strings its own:
/// the session check's report, which `dump --stage=ownership` prints
/// instead of checking the module again (#1193).
pub const Kept = struct {
    arena: std.heap.ArenaAllocator,
    report: Module,

    pub fn of(gpa: std.mem.Allocator, r: Module) std.mem.Allocator.Error!*Kept {
        const k = try gpa.create(Kept);
        k.* = .{ .arena = .init(gpa), .report = r };
        errdefer k.deinit(gpa);
        const a = k.arena.allocator();
        const lines = try a.alloc(Line, r.lines.len);
        for (lines, r.lines) |*to, from| {
            to.* = from;
            to.op = try a.dupe(u8, from.op);
            to.base = try a.dupe(u8, from.base);
            to.detail = try a.dupe(u8, from.detail);
        }
        const others = try a.alloc([]const u8, r.others.len);
        for (others, r.others) |*to, from| to.* = try a.dupe(u8, from);
        k.report.lines = lines;
        k.report.others = others;
        // What the dump prints, nothing it does not: the block and the word
        // errors stay the check's.
        k.report.block = null;
        k.report.word_errors = &.{};
        return k;
    }

    pub fn deinit(k: *Kept, gpa: std.mem.Allocator) void {
        k.arena.deinit();
        gpa.destroy(k);
    }
};

const Counts = struct {
    accepted: [@typeInfo(Facts.Verdict.Accepted).@"enum".field_names.len]u32 = @splat(0),
    rejected: [@typeInfo(Facts.Cause).@"enum".field_names.len]u32 = @splat(0),
    pending: u32 = 0,

    fn add(c: *Counts, l: Line) void {
        if (l.refused) {
            c.rejected[@backingInt(l.cause)] += 1;
        } else c.accepted[@backingInt(l.accepted)] += 1;
    }

    fn merge(c: *Counts, o: Counts) void {
        for (&c.accepted, o.accepted) |*x, y| x.* += y;
        for (&c.rejected, o.rejected) |*x, y| x.* += y;
        c.pending += o.pending;
    }

    fn write(c: Counts, w: *std.Io.Writer, label: []const u8) Error!void {
        var acc: u32 = 0;
        for (c.accepted) |x| acc += x;
        var rej: u32 = 0;
        for (c.rejected) |x| rej += x;
        const a = c.accepted;
        // The kinds R-7.15 names, in its order; `assumed` last.
        try w.print("{s} {d}: accepted {d} (fresh {d}, call {d}, param {d}, callback-param {d}, once {d}, entry {d}; assumed {d}), pending {d}, rejected {d}\n", .{
            label,                                                 acc + rej + c.pending,                       acc,
            a[@backingInt(Facts.Verdict.Accepted.fresh)],          a[@backingInt(Facts.Verdict.Accepted.call)], a[@backingInt(Facts.Verdict.Accepted.param)],
            a[@backingInt(Facts.Verdict.Accepted.callback_param)], a[@backingInt(Facts.Verdict.Accepted.once)], a[@backingInt(Facts.Verdict.Accepted.entry)],
            a[@backingInt(Facts.Verdict.Accepted.assumed)],        c.pending,                                   rej,
        });
    }
};

fn lineLess(_: void, a: Line, b: Line) bool {
    return a.position.line < b.position.line or (a.position.line == b.position.line and a.position.col < b.position.col);
}

pub fn writeLine(w: *std.Io.Writer, l: Line) Error!void {
    try w.print("  {d}:{d} {s} {s}: ", .{ l.position.line, l.position.col, l.op, l.base });
    if (l.refused) try w.print("rejected {s}", .{Facts.causeText(l.cause)}) else try w.print("accepted {s}", .{Facts.acceptText(l.accepted)});
    if (l.refused and l.detail.len != 0) try w.print(": {s}", .{l.detail});
    if (l.approx) try w.writeAll(" (approx)");
    try w.writeByte('\n');
}

/// The report of `reports` (R-7.15). `lines` of each are sorted here.
pub fn write(w: *std.Io.Writer, reports: []Module, module_names: []const []const u8, options: Options) Error!void {
    var total: Counts = .{};
    var limits: u32 = 0;
    for (reports) |*r| {
        if (!options.totals_only) try w.print("module {s}", .{module_names[r.module]});
        if (!r.checked) {
            if (!options.totals_only) try w.writeAll(" (not checked)\n");
            continue;
        }
        if (!options.totals_only) try w.writeByte('\n');
        const sorted = @constCast(r.lines);
        std.mem.sort(Line, sorted, {}, lineLess);
        var counts: Counts = .{};
        for (sorted) |l| {
            counts.add(l);
            if (!options.totals_only) try writeLine(w, l);
        }
        if (!options.totals_only) {
            for (r.others) |s| try w.print("  {s}\n", .{s});
            try counts.write(w, "  demands");
        }
        total.merge(counts);
        limits += r.limits;
    }
    try total.write(w, "total");
    if (limits != 0) try w.print("limits {d}\n", .{limits});
    for (total.rejected, 0..) |n, i| {
        if (n == 0) continue;
        try w.print("cause {s} {d}\n", .{ Facts.causeText(@fromBackingInt(@intCast(i))), n });
    }
}
