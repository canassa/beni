//! `beni dump --stage=writes` (docs/design/write-sets.md §8.1): every
//! program's message keys with their write sets and classes, and every view
//! hole with its class and anchored reads.
//!
//! ```
//! program Main.main : Tea.application
//!   model Main.Model
//!   init
//!     literal <none>
//!   key GotHomeMsg · ClickedTag                     exact      node ρ; node ρ.Home#0; …
//!   keys 101: bounded 100 (99%), exact 83, indexed 9, structural 8, * 1; capped 0
//!   hole Main.beni:52:17                            dynamic    reads ρ
//!   holes 507: static 9, literal 264, static-key 2, dynamic 232
//! ```
//!
//! Each line is one fact, so a golden diff names the fact that moved.
//! Nothing printed is an id: paths are sorted structurally (parents first,
//! fields by name, constructors by declaration), holes by module and
//! position, keys in the order `update`'s arms are written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writes = @import("../writes/Writes.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

/// Where a hole is: its module's file name and position.
pub const Position = struct { line: u32, col: u32 };

pub const Positions = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, module: u32, token: u32) Position,
};

const column: usize = 50;

fn pad(w: *std.Io.Writer, used: usize) std.Io.Writer.Error!void {
    if (used + 2 > column) {
        try w.writeByte('\n');
        try w.splatByteAll(' ', column);
        return;
    }
    try w.splatByteAll(' ', column - used);
}

/// The width of `s` in code points, as a column counts (language.md §12.7).
fn width(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

pub fn write(w: *std.Io.Writer, gpa: Allocator, a: *Writes, run: Writes.Run, positions: Positions) Error!void {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    for (run.programs) |*prog| {
        if (!prog.recognised) {
            try w.print("program <unrecognised> ({s}.{s})\n", .{ a.moduleName(prog.module), a.declNameOf(prog.module, prog.decl) });
            try w.writeAll("  key *");
            try pad(w, 7);
            try w.writeAll("*          value ρ\n");
        } else {
            try w.print("program {s}.{s}", .{ a.moduleName(prog.module), a.declNameOf(prog.module, prog.decl) });
            if (prog.index) |i| try w.print("[{d}]", .{i});
            try w.print(" : {s}\n  model ", .{Writes.programKindName(prog.kind)});
            try a.writeModelType(w, prog);
            try w.writeAll("\n  init\n    literal ");
            if (prog.init_literals.len == 0) try w.writeAll("<none>");
            const lits = try gpa.dupe(u32, prog.init_literals);
            defer gpa.free(lits);
            std.mem.sort(u32, lits, a, pathLess);
            for (lits, 0..) |p, i| {
                if (i > 0) try w.writeAll("; ");
                try a.writePath(w, p);
            }
            try w.writeByte('\n');
            var counts = [_]u32{ 0, 0, 0, 0 };
            var capped: u32 = 0;
            for (prog.keys) |k| {
                line.clearRetainingCapacity();
                try writeKeyName(&line.writer, a, k);
                const name = line.written();
                try w.print("  key {s}", .{name});
                try pad(w, 6 + width(name));
                const class = a.keyClass(k.writes);
                counts[@backingInt(class)] += 1;
                const class_name = switch (class) {
                    .exact => "exact",
                    .indexed => "indexed",
                    .structural => "structural",
                    .star => "*",
                };
                try w.writeAll(class_name);
                if (k.caps.any()) {
                    capped += 1;
                    try writeCaps(w, k.caps);
                    try w.writeByte(' ');
                } else try w.splatByteAll(' ', 11 - class_name.len);
                try writeSet(w, gpa, a, k.writes);
                try w.writeByte('\n');
            }
            const n: u32 = @intCast(prog.keys.len);
            const bounded = n - counts[3];
            try w.print("  keys {d}: bounded {d} ({d}%), exact {d}, indexed {d}, structural {d}, * {d}; capped {d}\n", .{
                n, bounded, if (n == 0) 0 else bounded * 100 / n, counts[0], counts[1], counts[2], counts[3], capped,
            });
            for (prog.summaries) |s| {
                try w.print("  summary {s}.{s}", .{ a.moduleName(s.module), a.declNameOf(s.module, s.decl) });
                try writeCaps(w, s.caps);
                try w.writeByte('\n');
            }
        }
        // Holes, by module name and position.
        const order = try gpa.alloc(usize, prog.holes.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        const Sort = struct {
            a: *Writes,
            holes: []const Writes.Hole,
            positions: Positions,
            fn less(s: @This(), x: usize, y: usize) bool {
                const hx = s.holes[x];
                const hy = s.holes[y];
                const o = std.mem.order(u8, s.a.moduleName(hx.module), s.a.moduleName(hy.module));
                if (o != .eq) return o == .lt;
                const px = s.positions.get(s.positions.ctx, hx.module, hx.token);
                const py = s.positions.get(s.positions.ctx, hy.module, hy.token);
                if (px.line != py.line) return px.line < py.line;
                return px.col < py.col;
            }
        };
        std.mem.sort(usize, order, Sort{ .a = a, .holes = prog.holes, .positions = positions }, Sort.less);
        var hcounts = [_]u32{ 0, 0, 0, 0 };
        for (order) |i| {
            const h = &prog.holes[i];
            const pos = positions.get(positions.ctx, h.module, h.token);
            line.clearRetainingCapacity();
            try modulePath(&line.writer, a.moduleName(h.module));
            try line.writer.print(":{d}:{d}", .{ pos.line, pos.col });
            const name = line.written();
            try w.print("  hole {s}", .{name});
            try pad(w, 7 + width(name));
            const class = a.holeClass(prog, h);
            hcounts[@backingInt(class)] += 1;
            const class_name = switch (class) {
                .static => "static",
                .literal => "literal",
                .static_key => "static-key",
                .dynamic => "dynamic",
            };
            try w.writeAll(class_name);
            try w.splatByteAll(' ', 11 - class_name.len);
            try w.writeAll("reads ");
            if (h.reads.len == 0) try w.writeAll("∅");
            const reads = try gpa.dupe(u32, h.reads);
            defer gpa.free(reads);
            std.mem.sort(u32, reads, a, pathLess);
            for (reads, 0..) |r, j| {
                if (j > 0) try w.writeAll("; ");
                try a.writePath(w, r);
            }
            try w.writeByte('\n');
        }
        try w.print("  holes {d}: static {d}, literal {d}, static-key {d}, dynamic {d}\n", .{
            prog.holes.len, hcounts[0], hcounts[1], hcounts[2], hcounts[3],
        });
    }
}

fn pathLess(a: *Writes, x: u32, y: u32) bool {
    return a.pathLess(x, y);
}

/// `Browser.Navigation` is `Browser/Navigation.beni`.
fn modulePath(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name) |c| try w.writeByte(if (c == '.') '/' else c);
    try w.writeAll(".beni");
}

fn writeCaps(w: *std.Io.Writer, caps: Writes.Caps) std.Io.Writer.Error!void {
    if (caps.k) try w.writeAll(" (cap k)");
    if (caps.a) try w.writeAll(" (cap A)");
    if (caps.d) try w.writeAll(" (cap D)");
    if (caps.i) try w.writeAll(" (cap I)");
    if (caps.s) try w.writeAll(" (cap S)");
    if (caps.w) try w.writeAll(" (cap W)");
    if (caps.l) try w.writeAll(" (cap L)");
}

fn writeSet(w: *std.Io.Writer, gpa: Allocator, a: *Writes, ws: []const Writes.Write) Error!void {
    if (ws.len == 0) return w.writeAll("∅");
    const sorted = try gpa.dupe(Writes.Write, ws);
    defer gpa.free(sorted);
    std.mem.sort(Writes.Write, sorted, a, struct {
        fn less(ctx: *Writes, x: Writes.Write, y: Writes.Write) bool {
            return ctx.pathLess(x.path, y.path);
        }
    }.less);
    for (sorted, 0..) |wr, i| {
        if (i > 0) try w.writeAll("; ");
        try w.writeAll(if (wr.kind == .node) "node " else "value ");
        try a.writePath(w, wr.path);
        try a.writeEdit(w, wr);
    }
}

/// The key as constructor names joined by ` · ` (§8.1): a constructor whose
/// argument the next split is under is written `C#i` when it has more than
/// one argument; the default child is `_`.
fn writeKeyName(w: *std.Io.Writer, a: *Writes, k: Writes.Key) std.Io.Writer.Error!void {
    if (k.steps.len == 0) return w.writeAll("(any)");
    // The constructors along each split's path, then the split's own: a
    // single-constructor wrapper no `case` split is still named.
    const Entry = struct { ctor: u32, arg: ?u32 };
    var entries: [64]Entry = undefined;
    var n: usize = 0;
    var prev: [Writes.k_limit + 2]Entry = undefined;
    var prev_len: usize = 0;
    for (k.steps) |s| {
        var chain: [Writes.k_limit + 2]Entry = undefined;
        var len: usize = 0;
        var buf: [Writes.k_limit + 1]u32 = undefined;
        var q = s.path;
        while (a.pathParent(q) != Writes.none) : (q = a.pathParent(q)) {
            buf[len] = q;
            len += 1;
        }
        std.mem.reverse(u32, buf[0..len]);
        var c_len: usize = 0;
        for (buf[0..len]) |st| if (a.pathKind(st) == .ctor) {
            chain[c_len] = .{ .ctor = a.pathA(st), .arg = a.pathB(st) };
            c_len += 1;
        };
        var common: usize = 0;
        while (common < c_len and common + 1 < prev_len and chain[common].ctor == prev[common].ctor) common += 1;
        for (chain[common..c_len]) |e| if (n < entries.len) {
            entries[n] = e;
            n += 1;
        };
        if (n < entries.len) {
            entries[n] = .{ .ctor = s.ctor, .arg = null };
            n += 1;
        }
        @memcpy(prev[0..c_len], chain[0..c_len]);
        prev[c_len] = .{ .ctor = s.ctor, .arg = null };
        prev_len = c_len + 1;
    }
    var i: usize = 0;
    var first = true;
    while (i < n) : (i += 1) {
        const e = entries[i];
        if (!first) try w.writeAll(" · ");
        first = false;
        if (e.ctor == Writes.none) {
            try w.writeByte('_');
            continue;
        }
        try w.writeAll(a.ctorName(e.ctor));
        var arg = e.arg;
        if (arg == null and i + 1 < n and entries[i + 1].arg != null and entries[i + 1].ctor == e.ctor) {
            arg = entries[i + 1].arg;
            i += 1;
        }
        if (arg) |x| if (a.ctorArity(e.ctor) > 1) try w.print("#{d}", .{x});
    }
}
