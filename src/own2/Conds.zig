//! L3: conditions (`docs/design/ownership-v2.md` §2.9.1): `no`, or a
//! selection — a run of occurrence words `(j << 32) | rel`, sorted and
//! deduplicated. A conjunction is one merge. In a contract a selection is
//! kept in its canonical order (by parameter, then by the slot's step
//! words), so a contract never depends on the order its slots were
//! interned in. Split from `Contract` (#1714).
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");

pub const Rel = Slots.Rel;
pub const Error = Ids.ChargeError;

/// A walk-time condition: `no`, or a selection in an arena, sorted by its
/// words (`occ`).
pub const Cond = struct {
    no: bool = false,
    sel: []const u64 = &.{},

    pub const yes: Cond = .{};
    pub const unprovable: Cond = .{ .no = true };

    pub fn isYes(c: Cond) bool {
        return !c.no and c.sel.len == 0;
    }

    pub fn eql(a: Cond, b: Cond) bool {
        return a.no == b.no and std.mem.eql(u64, a.sel, b.sel);
    }

    /// `a` asks no more than `b` (b ⇒ a). An apart occurrence is asked
    /// by itself or by the plain one.
    pub fn weaker(a: Cond, b: Cond) bool {
        if (b.no) return true;
        if (a.no) return false;
        for (a.sel) |x| {
            if (std.sort.binarySearch(u64, b.sel, x, order) != null) continue;
            if (isApart(x) and std.sort.binarySearch(u64, b.sel, x & ~apart_bit, order) != null) continue;
            return false;
        }
        return true;
    }

    /// `weaker`, where a deep occurrence also asks every occurrence of its
    /// parameter at a slot whose steps continue its own (§2.9.1, *A subtree
    /// held whole*).
    pub fn weakerIn(a: Cond, slots: *const Slots.Table, b: Cond) bool {
        if (b.no) return true;
        if (a.no) return false;
        outer: for (a.sel) |x| {
            if (std.sort.binarySearch(u64, b.sel, x, order) != null) continue;
            if (isApart(x) and std.sort.binarySearch(u64, b.sel, x & ~apart_bit, order) != null) continue;
            const xw = slots.relWords(occRel(x));
            for (b.sel) |y| {
                if (!isDeep(y) or occParam(y) != occParam(x) or (isApart(y) and !isApart(x))) continue;
                const yw = slots.relWords(occRel(y));
                if (xw.len >= yw.len and std.mem.eql(u32, yw, xw[0..yw.len])) continue :outer;
            }
            return false;
        }
        return true;
    }

    fn order(x: u64, y: u64) std.math.Order {
        return std.math.order(x, y);
    }

    /// The conjunction: the union of the selections, in `arena`.
    pub fn conj(arena: Allocator, account: *Ids.Account, a: Cond, b: Cond) Error!Cond {
        if (a.no or b.no) return unprovable;
        if (b.sel.len == 0) return a;
        if (a.sel.len == 0) return b;
        if (std.mem.eql(u64, a.sel, b.sel)) return a;
        try account.reserve(.cond, @intCast(a.sel.len + b.sel.len));
        const out = try arena.alloc(u64, a.sel.len + b.sel.len);
        var i: usize = 0;
        var j: usize = 0;
        var n: usize = 0;
        while (i < a.sel.len or j < b.sel.len) {
            if (j >= b.sel.len or (i < a.sel.len and a.sel[i] < b.sel[j])) {
                out[n] = a.sel[i];
                i += 1;
            } else if (i >= a.sel.len or b.sel[j] < a.sel[i]) {
                out[n] = b.sel[j];
                j += 1;
            } else {
                out[n] = a.sel[i];
                i += 1;
                j += 1;
            }
            n += 1;
        }
        return .{ .sel = dropAsked(out[0..n]) };
    }

    /// Drop each apart occurrence whose plain one is in the run too (the
    /// plain one asks more): a sorted run, in place.
    fn dropAsked(run: []u64) []u64 {
        var n: usize = 0;
        for (run) |x| {
            if (isApart(x) and std.sort.binarySearch(u64, run, x & ~apart_bit, order) != null) continue;
            run[n] = x;
            n += 1;
        }
        return run[0..n];
    }

    /// A selection of `run` (unsorted, owned by `arena`): sorted, deduplicated.
    pub fn of(account: *Ids.Account, run: []u64) Error!Cond {
        try account.reserve(.cond, @intCast(@max(1, run.len)));
        std.mem.sort(u64, run, {}, std.sort.asc(u64));
        var n: usize = 0;
        for (run) |x| {
            if (n != 0 and run[n - 1] == x) continue;
            run[n] = x;
            n += 1;
        }
        return .{ .sel = dropAsked(run[0..n]) };
    }
};

pub fn occ(j: u32, r: Rel) u64 {
    return (@as(u64, j) << 32) | r;
}
/// An occurrence that only has to be apart from the others (§2.9.1): its
/// objects may repeat among themselves. A holder beside a write needs no
/// more: the written object is none of the holder's.
pub const apart_bit: u64 = 1 << 63;
pub fn occApart(j: u32, r: Rel) u64 {
    return occ(j, r) | apart_bit;
}
pub fn isApart(o: u64) bool {
    return o & apart_bit != 0;
}
/// An occurrence at a slot no step below can name (a type variable's or an
/// opaque place): it selects every object below it in the value it is
/// instantiated on, which may be a tuple of one list twice (§2.9.1, #1711).
pub const deep_bit: u64 = 1 << 62;
pub fn occDeep(o: u64) u64 {
    return o | deep_bit;
}
pub fn isDeep(o: u64) bool {
    return o & deep_bit != 0;
}
pub fn occParam(o: u64) u32 {
    return @intCast((o >> 32) & 0x3fff_ffff);
}
pub fn occRel(o: u64) Rel {
    return @truncate(o);
}

/// The weaker of two conditions (`no` absorbs): their union's selection,
/// which asks the most, is the separation both sides together need.
pub fn weakest(arena: Allocator, account: *Ids.Account, a: Cond, b: Cond) Error!Cond {
    return Cond.conj(arena, account, a, b);
}

/// Sort occurrence words canonically: by parameter, then by step words.
pub fn sortOccs(slots: *const Slots.Table, run: []u64) void {
    std.mem.sort(u64, run, slots, struct {
        fn lt(s: *const Slots.Table, x: u64, y: u64) bool {
            if (occParam(x) != occParam(y)) return occParam(x) < occParam(y);
            if (occRel(x) != occRel(y)) return s.relLess(occRel(x), occRel(y));
            if (isApart(x) != isApart(y)) return !isApart(x);
            return !isDeep(x) and isDeep(y);
        }
    }.lt);
}

const testing = std.testing;

test "conditions conjoin by union and order by inclusion" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    const a: Cond = .{ .sel = &.{ occ(0, 1), occ(1, 2) } };
    const b: Cond = .{ .sel = &.{ occ(0, 1), occ(0, 3) } };
    const c = try Cond.conj(arena, &account, a, b);
    try testing.expectEqualSlices(u64, &.{ occ(0, 1), occ(0, 3), occ(1, 2) }, c.sel);
    try testing.expect(a.weaker(c) and b.weaker(c) and !c.weaker(a));
    try testing.expect(Cond.yes.weaker(a) and a.weaker(Cond.unprovable));
    try testing.expect((try Cond.conj(arena, &account, a, .unprovable)).no);
}
