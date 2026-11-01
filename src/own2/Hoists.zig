//! L14: the lowering channel (`docs/design/ownership-v2.md` §3.7, R-1.12),
//! its list half: per module a *clean* bit and, per accepted list write, its
//! instruction and kind. Rows hold only BIR identities (instruction indices
//! of the module), never a session id, so the table means the same to any
//! lowering of the same BIR.
//!
//! Two readers, two questions. The list sanitiser (§7.3, `--sanitize-lists`)
//! wraps every write the table lists: it judges verdicts, so it follows each
//! accepted write, in a module whose other declarations v2 has not built as
//! well. S8b's in-place lowering stores only in a `clean` module (R-1.12:
//! checked whole, no limit, every write accepted). A refused or exhausted
//! module publishes no write (§2.8, *Record lowering boundary*).
//!
//! The record half (written fields, hoisted reads) is S5's; the wire format
//! (`write`/`read`, its version beside the cache entry's) lands with v2's
//! cache, which `--ownership=v2` turns off today (`Session.zig`).
//!
//! Obligations kept here: none (data).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Facts = @import("Facts.zig");

/// The channel's format version (§3.7: versioned, outside the interface
/// hash). 2: v1's `Hoists` was 1.
pub const format_version: u32 = 2;

/// One accepted list write: the demand's instruction and its kind (a
/// writer call, a construction's spread, a `++`).
pub const Write = struct {
    inst: u32,
    kind: Facts.DemandKind,
};

pub const Table = struct {
    /// R-1.12's clean bit: every declaration checked, no limit, every write
    /// accepted. What S8b's stores need; the sanitiser does not read it.
    clean: bool = false,
    /// The accepted list writes, by instruction, ascending, each once.
    writes: []const Write = &.{},

    pub const empty: Table = .{};

    pub fn deinit(t: *Table, gpa: Allocator) void {
        gpa.free(t.writes);
        t.* = .empty;
    }

    pub fn clone(t: Table, gpa: Allocator) Allocator.Error!Table {
        return .{ .clean = t.clean, .writes = try gpa.dupe(Write, t.writes) };
    }

    /// Whether the write at instruction `inst` is one the checker accepted.
    pub fn accepted(t: Table, inst: u32) bool {
        var lo: usize = 0;
        var hi = t.writes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (t.writes[mid].inst < inst) lo = mid + 1 else hi = mid;
        }
        return lo < t.writes.len and t.writes[lo].inst == inst;
    }
};

/// Whether a demand of kind `k` is a list write the lowering wraps or
/// stores: a writer call, a spread chain's construction, a `++`. A record
/// update is S5's, a deep demand (a send, a consumed argument, a focus)
/// writes nothing at its own instruction.
pub fn isListWrite(k: Facts.DemandKind) bool {
    return k == .writer or k == .construction or k == .append;
}

/// A module's table, built from its verdicts in any order.
pub const Builder = struct {
    writes: std.ArrayList(Write) = .empty,
    refused: bool = false,
    unchecked: bool = false,

    /// A demand's verdict at instruction `inst`.
    pub fn add(b: *Builder, scratch: Allocator, inst: u32, kind: Facts.DemandKind, refused: bool) Allocator.Error!void {
        if (refused) {
            b.refused = true;
            return;
        }
        if (isListWrite(kind)) try b.writes.append(scratch, .{ .inst = inst, .kind = kind });
    }

    /// The table, in `gpa` (the rows were in `scratch`); `limited` when the
    /// module reached a limit.
    /// A refused or limited module publishes no write.
    pub fn finish(b: *Builder, scratch: Allocator, gpa: Allocator, limited: bool) Allocator.Error!Table {
        defer b.writes.deinit(scratch);
        if (b.refused or limited) return .empty;
        const items = b.writes.items;
        std.mem.sort(Write, items, {}, struct {
            fn lessThan(_: void, x: Write, y: Write) bool {
                return x.inst < y.inst or (x.inst == y.inst and @backingInt(x.kind) < @backingInt(y.kind));
            }
        }.lessThan);
        var n: usize = 0;
        for (items) |w| {
            if (n != 0 and items[n - 1].inst == w.inst) continue;
            items[n] = w;
            n += 1;
        }
        return .{ .clean = !b.unchecked, .writes = try gpa.dupe(Write, items[0..n]) };
    }
};

const testing = std.testing;

test "a refused or limited module publishes no write; an accepted one its writes, each once, by instruction" {
    const gpa = testing.allocator;
    var b: Builder = .{};
    try b.add(gpa, 9, .writer, false);
    try b.add(gpa, 3, .append, false);
    try b.add(gpa, 9, .writer, false);
    try b.add(gpa, 5, .update, false);
    var t = try b.finish(gpa, gpa, false);
    defer t.deinit(gpa);
    try testing.expect(t.clean);
    try testing.expectEqual(@as(usize, 2), t.writes.len);
    try testing.expect(t.accepted(3) and t.accepted(9));
    try testing.expect(!t.accepted(5) and !t.accepted(4));

    var r: Builder = .{};
    try r.add(gpa, 1, .writer, false);
    try r.add(gpa, 2, .writer, true);
    var none = try r.finish(gpa, gpa, false);
    try testing.expect(!none.clean and none.writes.len == 0);
    none.deinit(gpa);

    var u: Builder = .{ .unchecked = true };
    try u.add(gpa, 1, .construction, false);
    var partial = try u.finish(gpa, gpa, false);
    defer partial.deinit(gpa);
    try testing.expect(!partial.clean and partial.accepted(1));

    var l: Builder = .{};
    try l.add(gpa, 1, .writer, false);
    var limited = try l.finish(gpa, gpa, true);
    try testing.expect(limited.writes.len == 0);
    limited.deinit(gpa);
}
