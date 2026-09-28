//! Column zero of a pattern matrix, indexed by the alternative that heads
//! each row. `Exhaustive`'s two relations ask three questions of
//! that column — which alternatives appear (`collect`), which rows a
//! specialisation by EACH alternative keeps (`split`), and, as a `case` is
//! read branch by branch, which rows above a new branch share its head
//! (`Heads`). Each was a scan of the whole matrix per alternative or per
//! branch, so a `case` over a type of n constructors listing each once cost
//! n² steps and a flat 2 000-constructor `case` ran out of the budget that
//! exists for exponential matrices. Each is now one pass over the rows,
//! with the alternatives as dense indices into arrays (`fast-compiler.md` §5)
//! relative to their union's `alts_start`.
//!
//! Nothing here decides an answer: it only says which rows a question
//! reads, in matrix order, so the matrices `Exhaustive` builds from it are
//! the ones it built before.

const std = @import("std");
const Allocator = std.mem.Allocator;
const PatternStore = @import("PatternStore.zig");

const PatIndex = PatternStore.PatIndex;
const Patterns = PatternStore.Patterns;

/// A column no index can describe: a constructor of another union, or a
/// literal where constructors were — the matrix is not what the checker
/// thinks, and `Exhaustive` stays silent about it.
pub const Malformed = error{Malformed};

/// The alternatives appearing in column zero. Every one of them belongs to
/// the same union — the declaration type-checked — and a matrix that says
/// otherwise is abandoned rather than trusted.
///
/// A BITSET over the union's alternatives, not a list: a list made
/// collecting a column of n distinct constructors n², and `has` per
/// alternative n² again.
pub const Seen = struct {
    un: u32 = 0,
    count: u32 = 0,
    /// Bit `alt - alts_start` per alternative seen; empty when `count` is 0.
    bits: std.DynamicBitSetUnmanaged = .{},
    alts_start: u32 = 0,

    pub fn has(s: Seen, alt: u32) bool {
        return s.bits.isSet(alt - s.alts_start);
    }
};

pub fn collect(arena: Allocator, pats: *const Patterns, matrix: []const []const PatIndex) (Allocator.Error || Malformed)!Seen {
    var seen: Seen = .{};
    for (matrix) |row| {
        if (row.len == 0) return error.Malformed;
        if (pats.tag(row[0]) != .ctor) continue;
        const c = pats.ctor(row[0]);
        if (seen.count == 0) {
            const u = pats.unionAt(c.un);
            seen.un = c.un;
            seen.alts_start = u.alts_start;
            seen.bits = try .initEmpty(arena, u.count());
        } else if (c.un != seen.un) return error.Malformed;
        if (c.alt < seen.alts_start or c.alt - seen.alts_start >= seen.bits.bit_length) return error.Malformed;
        if (seen.bits.isSet(c.alt - seen.alts_start)) continue;
        seen.bits.set(c.alt - seen.alts_start);
        seen.count += 1;
    }
    return seen;
}

/// Column zero's rows by the alternative that heads them, for a caller
/// about to specialise by EVERY alternative of one union in turn. What a
/// specialisation by `alt` keeps is the rows headed by `alt` and the
/// wildcard rows, in matrix order: `headed(alt)` and `wild`.
pub const Split = struct {
    alts_start: u32,
    /// `rows[starts[a]..starts[a + 1]]` are the indices of the rows headed
    /// by alternative `alts_start + a`, ascending.
    starts: []u32,
    rows: []u32,
    /// The wildcard-headed rows, ascending.
    wild: []u32,

    pub fn headed(s: Split, alt: u32) []const u32 {
        const a = alt - s.alts_start;
        return s.rows[s.starts[a]..s.starts[a + 1]];
    }
};

/// One counting sort of `matrix`'s rows by head, for union `un`.
pub fn split(arena: Allocator, pats: *const Patterns, matrix: []const []const PatIndex, un: u32) (Allocator.Error || Malformed)!Split {
    const u = pats.unionAt(un);
    const starts = try arena.alloc(u32, u.count() + 1);
    @memset(starts, 0);
    var wild_count: usize = 0;
    for (matrix) |row| {
        if (row.len == 0) return error.Malformed;
        switch (pats.tag(row[0])) {
            .ctor => {
                const c = pats.ctor(row[0]);
                if (c.un != un or c.alt < u.alts_start or c.alt >= u.alts_end) return error.Malformed;
                starts[c.alt - u.alts_start + 1] += 1;
            },
            .anything => wild_count += 1,
            .literal => return error.Malformed,
        }
    }
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const rows = try arena.alloc(u32, starts[starts.len - 1]);
    const wild = try arena.alloc(u32, wild_count);
    const fill = try arena.dupe(u32, starts[0 .. starts.len - 1]);
    var w: usize = 0;
    for (matrix, 0..) |row, i| {
        if (pats.tag(row[0]) == .anything) {
            wild[w] = @intCast(i);
            w += 1;
            continue;
        }
        const a = pats.ctor(row[0]).alt - u.alts_start;
        rows[fill[a]] = @intCast(i);
        fill[a] += 1;
    }
    return .{ .alts_start = u.alts_start, .starts = starts, .rows = rows, .wild = wild };
}

/// The rows of a `case` so far by what heads them, kept as `Exhaustive.one`
/// adds each branch. A branch headed by constructor `C` is useful against
/// the rows above it exactly when it is useful against the ones headed by
/// `C` or by a wildcard — which is `isUseful`'s first step — so asking that
/// of the whole matrix made a `case` of n branches over n constructors n²,
/// the budget spent before any branch had nested patterns worth exploring.
/// `ok` goes false for good at a head this index does not describe (a
/// literal, a second union), and the caller then asks the general relation
/// of the whole matrix, as before.
pub const Heads = struct {
    ok: bool = true,
    un: ?u32 = null,
    alts_start: u32 = 0,
    by_alt: []std.ArrayList(u32) = &.{},
    wild: std.ArrayList(u32) = .empty,

    pub fn add(h: *Heads, arena: Allocator, pats: *const Patterns, row_index: usize, head: PatIndex) Allocator.Error!void {
        if (!h.ok) return;
        const index: u32 = @intCast(row_index);
        switch (pats.tag(head)) {
            .anything => try h.wild.append(arena, index),
            .literal => h.ok = false,
            .ctor => {
                const c = pats.ctor(head);
                if (h.un == null) {
                    const u = pats.unionAt(c.un);
                    h.un = c.un;
                    h.alts_start = u.alts_start;
                    h.by_alt = try arena.alloc(std.ArrayList(u32), u.count());
                    @memset(h.by_alt, .empty);
                }
                const at = h.slot(c) orelse {
                    h.ok = false;
                    return;
                };
                try h.by_alt[at].append(arena, index);
            },
        }
    }

    /// The rows above headed by constructor `c`'s alternative, or null when
    /// this index cannot say (it is off, or `c` is of another union).
    pub fn headedBy(h: *const Heads, c: Patterns.Ctor) ?[]const u32 {
        if (!h.ok) return null;
        if (h.un == null) return &.{};
        return h.by_alt[h.slot(c) orelse return null].items;
    }

    fn slot(h: *const Heads, c: Patterns.Ctor) ?usize {
        if (c.un != h.un.? or c.alt < h.alts_start or c.alt - h.alts_start >= h.by_alt.len) return null;
        return c.alt - h.alts_start;
    }
};
