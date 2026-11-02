//! L3: contracts (`docs/design/ownership-v2.md` §2.10, §3.5): what one
//! code (a declaration, a lambda, a local function, a constructor, a worded
//! row) does with its parameters, over slots. The module's contracts live
//! in one table of flat runs; a contract is a record of ranges, immutable
//! once committed. A join makes a new contract.
//!
//! **Conditions** (§2.9.1): `no`, or a selection — a run of occurrence words
//! `(j << 32) | rel`, sorted and deduplicated. A conjunction is one merge.
//! In the table a selection is kept in its canonical order (by parameter,
//! then by the slot's step words), so a contract never depends on the order
//! its slots were interned in.
//!
//! Obligations kept here: none of §2.14's directly; `within` is §2.12's
//! validation test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");

pub const Rel = Slots.Rel;
pub const Range = Ids.Range;
pub const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

pub const Id = u32;

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
pub fn occParam(o: u64) u32 {
    return @intCast((o >> 32) & 0x7fff_ffff);
}
pub fn occRel(o: u64) Rel {
    return @truncate(o);
}

pub const ArrivalKind = enum(u8) { param, fresh, shared, cb, top };

/// One arrival (§2.10 `res`): `π_j·slot`, `fresh`, `shared (module, decl)`
/// (`j`, `slot`), `cb label` (`j`: the label's index in its contract), `⊤`.
pub const Arrival = struct {
    kind: ArrivalKind,
    /// `param`: the parameter's slot is a type variable's, so the arrival is
    /// every object at and below it at the caller.
    deep: bool = false,
    j: u32 = 0,
    slot: u32 = 0,

    pub fn eql(a: Arrival, b: Arrival) bool {
        return a.kind == b.kind and a.deep == b.deep and a.j == b.j and a.slot == b.slot;
    }
};

/// A result (or supply) slot and its arrivals. `open`: the slot is a type
/// variable's, so at a caller it stands for every slot at and below it.
pub const ResSlot = struct { slot: Rel, open: bool = false, arrivals: Range };

/// A read, write or escape (§2.10): parameter `j`'s slot, `deep` when it
/// reaches every slot below.
pub const Effect = struct {
    j: u32,
    slot: Rel,
    deep: bool = false,
};

/// A stored condition: `no`, or a run of `occs`.
pub const StoredCond = struct {
    no: bool = false,
    run: Range = .{},
};

/// A callback label (§2.11.3): the function slot it calls, its origin
/// `(module, declaration, offset)`, how often, and its supplies.
pub const Label = struct {
    j: u32,
    slot: Rel,
    origin: [3]u32,
    calls: Calls = .none,
    supplies: Range = .{},
};

pub const Calls = enum(u8) { none, once, many };

pub const Supply = struct {
    k: u32,
    res: Range,
    kept: Range,
    cond: StoredCond,
};

pub const Flags = packed struct(u8) {
    returns: bool = false,
    cross: bool = false,
    once: bool = false,
    words: bool = false,
    pessimistic: bool = false,
    _pad: u3 = 0,
};

pub const Head = struct {
    arity: u32,
    flags: Flags,
    res: Range = .{},
    res_cond: StoredCond = .{},
    reads: Range = .{},
    writes: Range = .{},
    req: StoredCond = .{},
    escapes: Range = .{},
    labels: Range = .{},
};

/// A contract being built: plain lists, committed into the table at once.
pub const Draft = struct {
    arity: u32,
    flags: Flags = .{},
    res: std.ArrayList(DraftSlot) = .empty,
    res_cond: Cond = .{},
    reads: std.ArrayList(Effect) = .empty,
    writes: std.ArrayList(Effect) = .empty,
    req: Cond = .{},
    escapes: std.ArrayList(Effect) = .empty,
    labels: std.ArrayList(DraftLabel) = .empty,

    /// `wide`: an entry of arrivals that hold at the slot and, by structure,
    /// at every slot below it (an open entry of its own, §2.10 *Read-off*),
    /// beside the slot's plain entry.
    pub const DraftSlot = struct { slot: Rel, open: bool = false, wide: bool = false, arrivals: std.ArrayList(Arrival) = .empty };
    pub const DraftLabel = struct {
        j: u32,
        slot: Rel,
        origin: [3]u32,
        calls: Calls = .none,
        supplies: std.ArrayList(DraftSupply) = .empty,

        pub fn supplyOf(l: *DraftLabel, arena: Allocator, k: u32) Allocator.Error!*DraftSupply {
            for (l.supplies.items) |*s| if (s.k == k) return s;
            try l.supplies.append(arena, .{ .k = k });
            return &l.supplies.items[l.supplies.items.len - 1];
        }
    };
    pub const DraftSupply = struct {
        k: u32,
        res: std.ArrayList(DraftSlot) = .empty,
        kept: std.ArrayList(Effect) = .empty,
        cond: Cond = .{},
    };

    /// The arrivals list of result slot `slot`, made when missing.
    pub fn slotOf(list: *std.ArrayList(DraftSlot), arena: Allocator, slot: Rel) Allocator.Error!*std.ArrayList(Arrival) {
        for (list.items) |*s| if (s.slot == slot and !s.wide) return &s.arrivals;
        try list.append(arena, .{ .slot = slot });
        return &list.items[list.items.len - 1].arrivals;
    }

    pub fn markOpen(list: *std.ArrayList(DraftSlot), arena: Allocator, slot: Rel) Allocator.Error!void {
        _ = try slotOf(list, arena, slot);
        for (list.items) |*s| if (s.slot == slot) {
            s.open = true;
        };
    }

    /// The wide entry of `slot`, made when missing.
    pub fn wideOf(list: *std.ArrayList(DraftSlot), arena: Allocator, slot: Rel) Allocator.Error!*std.ArrayList(Arrival) {
        for (list.items) |*s| if (s.slot == slot and s.wide) return &s.arrivals;
        try list.append(arena, .{ .slot = slot, .open = true, .wide = true });
        return &list.items[list.items.len - 1].arrivals;
    }

    /// An arrival at `slot` and, by structure, at every slot below it.
    pub fn addWide(list: *std.ArrayList(DraftSlot), arena: Allocator, slot: Rel, a: Arrival) Allocator.Error!bool {
        const arrs = try wideOf(list, arena, slot);
        for (arrs.items) |x| if (x.eql(a)) return false;
        try arrs.append(arena, a);
        return true;
    }

    /// An arrival of a committed entry, into the entry of the same kind.
    pub fn addAt(list: *std.ArrayList(DraftSlot), arena: Allocator, slot: Rel, open: bool, a: Arrival) Allocator.Error!bool {
        if (open) return addWide(list, arena, slot, a);
        return addArrival(list, arena, slot, a);
    }

    pub fn addArrival(list: *std.ArrayList(DraftSlot), arena: Allocator, slot: Rel, a: Arrival) Allocator.Error!bool {
        const arrs = try slotOf(list, arena, slot);
        for (arrs.items) |x| if (x.eql(a)) return false;
        try arrs.append(arena, a);
        return true;
    }

    pub fn addEffect(list: *std.ArrayList(Effect), arena: Allocator, e: Effect) Allocator.Error!bool {
        for (list.items) |*x| if (x.j == e.j and x.slot == e.slot) {
            if (e.deep and !x.deep) {
                x.deep = true;
                return true;
            }
            return false;
        };
        try list.append(arena, e);
        return true;
    }

    /// The label `(j, slot, origin)`, made when missing.
    pub fn labelOf(d: *Draft, arena: Allocator, j: u32, slot: Rel, origin: [3]u32) Allocator.Error!u32 {
        for (d.labels.items, 0..) |l, i| if (l.j == j and l.slot == slot and std.mem.eql(u32, &l.origin, &origin)) return @intCast(i);
        try d.labels.append(arena, .{ .j = j, .slot = slot, .origin = origin });
        return @intCast(d.labels.items.len - 1);
    }
};

pub const Table = struct {
    heads: std.ArrayList(Head) = .empty,
    res: std.ArrayList(ResSlot) = .empty,
    arrivals: std.ArrayList(Arrival) = .empty,
    effects: std.ArrayList(Effect) = .empty,
    occs: std.ArrayList(u64) = .empty,
    labels: std.ArrayList(Label) = .empty,
    supplies: std.ArrayList(Supply) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.heads.deinit(gpa);
        t.res.deinit(gpa);
        t.arrivals.deinit(gpa);
        t.effects.deinit(gpa);
        t.occs.deinit(gpa);
        t.labels.deinit(gpa);
        t.supplies.deinit(gpa);
    }

    pub fn head(t: *const Table, c: Id) Head {
        return t.heads.items[c];
    }
    pub fn resOf(t: *const Table, r: Range) []const ResSlot {
        return t.res.items[r.start..][0..r.len];
    }
    pub fn arrivalsOf(t: *const Table, r: Range) []const Arrival {
        return t.arrivals.items[r.start..][0..r.len];
    }
    pub fn effectsOf(t: *const Table, r: Range) []const Effect {
        return t.effects.items[r.start..][0..r.len];
    }
    pub fn labelsOf(t: *const Table, r: Range) []const Label {
        return t.labels.items[r.start..][0..r.len];
    }
    pub fn suppliesOf(t: *const Table, r: Range) []const Supply {
        return t.supplies.items[r.start..][0..r.len];
    }

    /// A stored condition as a walk-time one, its words in walk order
    /// (sorted by the raw occurrence word) in `arena`.
    pub fn cond(t: *const Table, arena: Allocator, c: StoredCond) Allocator.Error!Cond {
        if (c.no) return .unprovable;
        if (c.run.len == 0) return .yes;
        const out = try arena.dupe(u64, t.occs.items[c.run.start..][0..c.run.len]);
        std.mem.sort(u64, out, {}, std.sort.asc(u64));
        return .{ .sel = out };
    }

    /// The occurrences of a stored condition, in canonical order.
    pub fn occsOf(t: *const Table, c: StoredCond) []const u64 {
        return t.occs.items[c.run.start..][0..c.run.len];
    }

    /// The arrival `a` lists `cb` by label index; `labelAt` reads it.
    pub fn labelAt(t: *const Table, c: Id, i: u32) Label {
        return t.labels.items[t.heads.items[c].labels.start + i];
    }

    // ---- committing ----------------------------------------------------------

    fn putCond(t: *Table, gpa: Allocator, slots: *const Slots.Table, c: Cond) Allocator.Error!StoredCond {
        if (c.no) return .{ .no = true };
        const start: u32 = @intCast(t.occs.items.len);
        try t.occs.appendSlice(gpa, c.sel);
        const run = t.occs.items[start..];
        sortOccs(slots, run);
        return .{ .run = .{ .start = start, .len = @intCast(run.len) } };
    }

    fn putSlots(t: *Table, gpa: Allocator, slots: *const Slots.Table, list: []Draft.DraftSlot) Allocator.Error!Range {
        std.mem.sort(Draft.DraftSlot, list, slots, struct {
            fn lt(s: *const Slots.Table, a: Draft.DraftSlot, b: Draft.DraftSlot) bool {
                const o = s.relOrder(a.slot, b.slot);
                if (o != .eq) return o == .lt;
                return !a.open and b.open;
            }
        }.lt);
        const start: u32 = @intCast(t.res.items.len);
        var i: usize = 0;
        while (i < list.len) {
            // One entry per (slot, open): a wide entry and a type variable's
            // open one are one entry.
            var n = i + 1;
            while (n < list.len and list[n].slot == list[i].slot and list[n].open == list[i].open) n += 1;
            const astart: u32 = @intCast(t.arrivals.items.len);
            for (list[i..n]) |s| try t.arrivals.appendSlice(gpa, s.arrivals.items);
            const run = t.arrivals.items[astart..];
            std.mem.sort(Arrival, run, slots, arrivalLess);
            var m: usize = 0;
            for (run) |a| {
                if (m != 0 and run[m - 1].eql(a)) continue;
                run[m] = a;
                m += 1;
            }
            t.arrivals.shrinkRetainingCapacity(astart + m);
            if (m != 0) try t.res.append(gpa, .{ .slot = list[i].slot, .open = list[i].open, .arrivals = .{ .start = astart, .len = @intCast(m) } });
            i = n;
        }
        return .{ .start = start, .len = @intCast(t.res.items.len - start) };
    }

    fn putEffects(t: *Table, gpa: Allocator, slots: *const Slots.Table, list: []Effect) Allocator.Error!Range {
        std.mem.sort(Effect, list, slots, effectLess);
        const start: u32 = @intCast(t.effects.items.len);
        // An effect below a deep one of the same parameter says nothing more.
        outer: for (list) |x| {
            for (t.effects.items[start..]) |y| {
                if (y.j == x.j and y.deep and y.slot != x.slot and continues(slots, y.slot, &.{}, x.slot, true)) continue :outer;
            }
            try t.effects.append(gpa, x);
        }
        return .{ .start = start, .len = @intCast(t.effects.items.len - start) };
    }

    /// Commit a draft: every list in its canonical order (§2.10).
    pub fn commit(t: *Table, gpa: Allocator, account: *Ids.Account, slots: *const Slots.Table, d: *Draft) Error!Id {
        try account.reserve(.class, 1);
        var h: Head = .{ .arity = d.arity, .flags = d.flags };
        h.res = try t.putSlots(gpa, slots, d.res.items);
        h.res_cond = try t.putCond(gpa, slots, d.res_cond);
        h.reads = try t.putEffects(gpa, slots, d.reads.items);
        h.writes = try t.putEffects(gpa, slots, d.writes.items);
        h.req = try t.putCond(gpa, slots, d.req);
        h.escapes = try t.putEffects(gpa, slots, d.escapes.items);
        // Labels: sorted by (j, slot, origin); `cb` arrivals renumbered.
        const order = try gpa.alloc(u32, d.labels.items.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, .{ slots, d.labels.items }, struct {
            fn lt(c: struct { *const Slots.Table, []Draft.DraftLabel }, x: u32, y: u32) bool {
                const a = c[1][x];
                const b = c[1][y];
                if (a.j != b.j) return a.j < b.j;
                const o = c[0].relOrder(a.slot, b.slot);
                if (o != .eq) return o == .lt;
                return std.mem.order(u32, &a.origin, &b.origin) == .lt;
            }
        }.lt);
        const rank = try gpa.alloc(u32, d.labels.items.len);
        defer gpa.free(rank);
        for (order, 0..) |o, r| rank[o] = @intCast(r);
        renumberCb(d.res.items, rank);
        for (d.labels.items) |*l| for (l.supplies.items) |*s| renumberCb(s.res.items, rank);
        const lstart: u32 = @intCast(t.labels.items.len);
        for (order) |o| {
            const l = &d.labels.items[o];
            std.mem.sort(Draft.DraftSupply, l.supplies.items, {}, struct {
                fn lt(_: void, a: Draft.DraftSupply, b: Draft.DraftSupply) bool {
                    return a.k < b.k;
                }
            }.lt);
            const sstart: u32 = @intCast(t.supplies.items.len);
            // The supplies' runs are made first; their records after.
            var made: std.ArrayList(Supply) = .empty;
            defer made.deinit(gpa);
            for (l.supplies.items) |*s| try made.append(gpa, .{ .k = s.k, .res = try t.putSlots(gpa, slots, s.res.items), .kept = try t.putEffects(gpa, slots, s.kept.items), .cond = try t.putCond(gpa, slots, s.cond) });
            try t.supplies.appendSlice(gpa, made.items);
            try t.labels.append(gpa, .{ .j = l.j, .slot = l.slot, .origin = l.origin, .calls = l.calls, .supplies = .{ .start = sstart, .len = @intCast(made.items.len) } });
        }
        h.labels = .{ .start = lstart, .len = @intCast(d.labels.items.len) };
        try t.heads.append(gpa, h);
        return @intCast(t.heads.items.len - 1);
    }

    /// A draft holding `c`'s facts, in `arena`: what a join starts from.
    pub fn draftOf(t: *const Table, arena: Allocator, c: Id) Allocator.Error!Draft {
        const h = t.heads.items[c];
        var d: Draft = .{ .arity = h.arity, .flags = h.flags };
        try t.copySlots(arena, &d.res, h.res);
        d.res_cond = try t.cond(arena, h.res_cond);
        try d.reads.appendSlice(arena, t.effectsOf(h.reads));
        try d.writes.appendSlice(arena, t.effectsOf(h.writes));
        d.req = try t.cond(arena, h.req);
        try d.escapes.appendSlice(arena, t.effectsOf(h.escapes));
        for (t.labelsOf(h.labels)) |l| {
            var dl: Draft.DraftLabel = .{ .j = l.j, .slot = l.slot, .origin = l.origin, .calls = l.calls };
            for (t.suppliesOf(l.supplies)) |s| {
                var ds: Draft.DraftSupply = .{ .k = s.k, .cond = try t.cond(arena, s.cond) };
                try t.copySlots(arena, &ds.res, s.res);
                try ds.kept.appendSlice(arena, t.effectsOf(s.kept));
                try dl.supplies.append(arena, ds);
            }
            try d.labels.append(arena, dl);
        }
        return d;
    }

    fn copySlots(t: *const Table, arena: Allocator, out: *std.ArrayList(Draft.DraftSlot), r: Range) Allocator.Error!void {
        for (t.resOf(r)) |s| {
            var arrs: std.ArrayList(Arrival) = .empty;
            try arrs.appendSlice(arena, t.arrivalsOf(s.arrivals));
            try out.append(arena, .{ .slot = s.slot, .open = s.open, .arrivals = arrs });
        }
    }

    /// `a ⊔ b` (§2.10 *Lattice*): never drops a result slot.
    pub fn join(t: *Table, gpa: Allocator, arena: Allocator, account: *Ids.Account, slots: *const Slots.Table, a: Id, b: Id) Error!Id {
        if (a == b) return a;
        var d = try t.draftOf(arena, a);
        try t.mergeInto(arena, account, &d, b);
        return t.commit(gpa, account, slots, &d);
    }

    /// Add `b`'s facts to draft `d`.
    pub fn mergeInto(t: *const Table, arena: Allocator, account: *Ids.Account, d: *Draft, b: Id) Error!void {
        const hb = t.heads.items[b];
        try account.reserve(.class, 1);
        const b_returns = hb.flags.returns;
        const a_returns = d.flags.returns;
        d.flags.returns = a_returns or b_returns;
        if (!a_returns) d.flags.cross = hb.flags.cross else if (b_returns) d.flags.cross = d.flags.cross and hb.flags.cross;
        d.flags.once = d.flags.once or hb.flags.once;
        // A side that does not return says nothing of the result's condition.
        const bc = try t.cond(arena, hb.res_cond);
        if (!a_returns) d.res_cond = bc else if (b_returns) d.res_cond = try weakest(arena, account, d.res_cond, bc);
        d.req = try Cond.conj(arena, account, d.req, try t.cond(arena, hb.req));
        // Labels of `b`, matched to `d`'s by (j, slot, origin): `b`'s index → `d`'s.
        const map = try arena.alloc(u32, hb.labels.len);
        for (t.labelsOf(hb.labels), 0..) |l, i| map[i] = try d.labelOf(arena, l.j, l.slot, l.origin);
        for (t.labelsOf(hb.labels), 0..) |l, i| {
            const at = map[i];
            const dl = &d.labels.items[at];
            dl.calls = @fromBackingInt(@intCast(@max(@backingInt(dl.calls), @backingInt(l.calls))));
            for (t.suppliesOf(l.supplies)) |s| {
                const ds = try dl.supplyOf(arena, s.k);
                try t.mergeSlots(arena, &ds.res, s.res, map);
                for (t.effectsOf(s.kept)) |e| _ = try Draft.addEffect(&ds.kept, arena, e);
                ds.cond = try weakest(arena, account, ds.cond, try t.cond(arena, s.cond));
            }
        }
        try t.mergeSlots(arena, &d.res, hb.res, map);
        for (t.effectsOf(hb.reads)) |e| _ = try Draft.addEffect(&d.reads, arena, e);
        for (t.effectsOf(hb.writes)) |e| _ = try Draft.addEffect(&d.writes, arena, e);
        for (t.effectsOf(hb.escapes)) |e| _ = try Draft.addEffect(&d.escapes, arena, e);
    }

    fn mergeSlots(t: *const Table, arena: Allocator, out: *std.ArrayList(Draft.DraftSlot), r: Range, map: []const u32) Allocator.Error!void {
        for (t.resOf(r)) |s| for (t.arrivalsOf(s.arrivals)) |a0| {
            var a = a0;
            if (a.kind == .cb) a.j = map[a.j];
            if (s.open) try Draft.markOpen(out, arena, s.slot);
            _ = try Draft.addArrival(out, arena, s.slot, a);
        };
    }

    /// Equality of two committed contracts: their words (both canonical).
    pub fn eql(t: *const Table, a: Id, b: Id) bool {
        if (a == b) return true;
        const x = t.heads.items[a];
        const y = t.heads.items[b];
        if (x.arity != y.arity or @as(u8, @bitCast(x.flags)) != @as(u8, @bitCast(y.flags))) return false;
        if (!t.condEql(x.res_cond, y.res_cond) or !t.condEql(x.req, y.req)) return false;
        if (!t.slotsEql(x.res, y.res)) return false;
        if (!t.effectsEql(x.reads, y.reads) or !t.effectsEql(x.writes, y.writes) or !t.effectsEql(x.escapes, y.escapes)) return false;
        if (x.labels.len != y.labels.len) return false;
        for (t.labelsOf(x.labels), t.labelsOf(y.labels)) |p, q| {
            if (p.j != q.j or p.slot != q.slot or !std.mem.eql(u32, &p.origin, &q.origin) or p.calls != q.calls) return false;
            if (p.supplies.len != q.supplies.len) return false;
            for (t.suppliesOf(p.supplies), t.suppliesOf(q.supplies)) |s, u| {
                if (s.k != u.k or !t.slotsEql(s.res, u.res) or !t.effectsEql(s.kept, u.kept) or !t.condEql(s.cond, u.cond)) return false;
            }
        }
        return true;
    }

    fn condEql(t: *const Table, a: StoredCond, b: StoredCond) bool {
        return a.no == b.no and std.mem.eql(u64, t.occsOf(a), t.occsOf(b));
    }

    fn slotsEql(t: *const Table, a: Range, b: Range) bool {
        if (a.len != b.len) return false;
        for (t.resOf(a), t.resOf(b)) |x, y| {
            if (x.slot != y.slot or x.open != y.open or x.arrivals.len != y.arrivals.len) return false;
            for (t.arrivalsOf(x.arrivals), t.arrivalsOf(y.arrivals)) |p, q| if (!p.eql(q)) return false;
        }
        return true;
    }

    fn effectsEql(t: *const Table, a: Range, b: Range) bool {
        if (a.len != b.len) return false;
        for (t.effectsOf(a), t.effectsOf(b)) |x, y| if (x.j != y.j or x.slot != y.slot or x.deep != y.deep) return false;
        return true;
    }

    /// `within(got, claim)` (§2.10): `got` says no more than `claim`.
    pub fn within(t: *const Table, arena: Allocator, slots: *const Slots.Table, got: Id, claim: Id) Allocator.Error!bool {
        const g = t.heads.items[got];
        const c = t.heads.items[claim];
        if (g.flags.returns and !c.flags.returns) return false;
        if (g.flags.once and !c.flags.once) return false;
        if (g.flags.returns and !c.res_cond.no) {
            if (!(try t.cond(arena, g.res_cond)).weaker(try t.cond(arena, c.res_cond))) return false;
        }
        if (!(try t.cond(arena, g.req)).weaker(try t.cond(arena, c.req))) return false;
        if (!t.effectsWithin(slots, g.reads, c.reads) or !t.effectsWithin(slots, g.writes, c.writes) or !t.effectsWithin(slots, g.escapes, c.escapes)) return false;
        // Labels by identity; `cb` arrivals compared through them.
        for (t.labelsOf(g.labels)) |l| {
            const m = t.findLabel(c, l) orelse return false;
            if (@backingInt(l.calls) > @backingInt(m.calls)) return false;
            for (t.suppliesOf(l.supplies)) |s| {
                const u = for (t.suppliesOf(m.supplies)) |u| {
                    if (u.k == s.k) break u;
                } else return false;
                if (!t.slotsWithin(slots, got, claim, s.res, u.res)) return false;
                if (!t.effectsWithin(slots, s.kept, u.kept)) return false;
                if (!u.cond.no and !(try t.cond(arena, s.cond)).weaker(try t.cond(arena, u.cond))) return false;
            }
        }
        return t.slotsWithin(slots, got, claim, g.res, c.res);
    }

    fn findLabel(t: *const Table, h: Head, l: Label) ?Label {
        for (t.labelsOf(h.labels)) |m| if (m.j == l.j and m.slot == l.slot and std.mem.eql(u32, &m.origin, &l.origin)) return m;
        return null;
    }

    /// Every effect of `a` is one of `b`'s, or below a deep one of `b`'s.
    fn effectsWithin(t: *const Table, slots: *const Slots.Table, a: Range, b: Range) bool {
        for (t.effectsOf(a)) |x| {
            const found = for (t.effectsOf(b)) |y| {
                if (x.j != y.j) continue;
                if (x.slot == y.slot and (!x.deep or y.deep)) break true;
                if (y.deep and continues(slots, y.slot, &.{}, x.slot, true)) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }

    /// Every arrival of `a` is one of `b`'s at its slot: at the same slot, of an
    /// entry of the same kind, or of an open entry of `b` above it, continued
    /// by the steps between (an atom is the same at every slot below).
    fn slotsWithin(t: *const Table, slots: *const Slots.Table, got: Id, claim: Id, a: Range, b: Range) bool {
        for (t.resOf(a)) |x| {
            const xw = slots.relWords(x.slot);
            for (t.arrivalsOf(x.arrivals)) |p| {
                const found = for (t.resOf(b)) |y| {
                    const yw = slots.relWords(y.slot);
                    if (yw.len > xw.len or !std.mem.eql(u32, yw, xw[0..yw.len])) continue;
                    const suffix = xw[yw.len..];
                    if (suffix.len == 0 and x.open and !y.open) continue;
                    if (suffix.len != 0 and !y.open) continue;
                    if (t.arrivalsHas(slots, got, claim, y.arrivals, p, suffix)) break true;
                } else false;
                if (!found) return false;
            }
        }
        return true;
    }

    /// Whether `run` holds `p` once continued by `suffix`.
    fn arrivalsHas(t: *const Table, slots: *const Slots.Table, got: Id, claim: Id, run: Range, p: Arrival, suffix: []const u32) bool {
        for (t.arrivalsOf(run)) |q| {
            if (p.kind != q.kind) continue;
            switch (p.kind) {
                .fresh, .top => return true,
                .shared => if (p.j == q.j and p.slot == q.slot) return true,
                .cb => {
                    const lp = t.labelAt(got, p.j);
                    const lq = t.labelAt(claim, q.j);
                    if (lp.j == lq.j and lp.slot == lq.slot and std.mem.eql(u32, &lp.origin, &lq.origin) and continues(slots, q.slot, suffix, p.slot, false)) return true;
                },
                .param => if (p.j == q.j and (!p.deep or q.deep) and continues(slots, q.slot, suffix, p.slot, q.deep)) return true,
            }
        }
        return false;
    }

    /// Whether slot `p` is `q` continued by `suffix` (or below it, `deep`).
    fn continues(slots: *const Slots.Table, q: Rel, suffix: []const u32, p: Rel, deep: bool) bool {
        const qw = slots.relWords(q);
        const pw = slots.relWords(p);
        if (pw.len < qw.len or !std.mem.eql(u32, qw, pw[0..qw.len])) return false;
        if (deep) return true;
        return std.mem.eql(u32, pw[qw.len..], suffix);
    }
};

/// The weaker of two conditions (`no` absorbs): their union's selection,
/// which asks the most, is the separation both sides together need.
pub fn weakest(arena: Allocator, account: *Ids.Account, a: Cond, b: Cond) Error!Cond {
    return Cond.conj(arena, account, a, b);
}

fn renumberCb(list: []Draft.DraftSlot, rank: []const u32) void {
    for (list) |*s| for (s.arrivals.items) |*a| {
        if (a.kind == .cb) a.j = rank[a.j];
    };
}

fn arrivalLess(slots: *const Slots.Table, a: Arrival, b: Arrival) bool {
    if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
    if (a.j != b.j) return a.j < b.j;
    if (a.deep != b.deep) return !a.deep;
    if (a.kind == .param) return slots.relLess(a.slot, b.slot);
    return a.slot < b.slot;
}

fn effectLess(slots: *const Slots.Table, a: Effect, b: Effect) bool {
    if (a.j != b.j) return a.j < b.j;
    return slots.relLess(a.slot, b.slot);
}

/// Sort occurrence words canonically: by parameter, then by step words.
pub fn sortOccs(slots: *const Slots.Table, run: []u64) void {
    std.mem.sort(u64, run, slots, struct {
        fn lt(s: *const Slots.Table, x: u64, y: u64) bool {
            if (occParam(x) != occParam(y)) return occParam(x) < occParam(y);
            if (occRel(x) != occRel(y)) return s.relLess(occRel(x), occRel(y));
            return !isApart(x) and isApart(y);
        }
    }.lt);
}

/// How a contract's text names a step, a declaration and a field.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
};

/// `rel`'s text: `.f`, `.0`, `#c.i`, `[*]`, `⟲`, `◆`, `◇`, `⟨n⟩`; `ε` for none.
pub fn relText(slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, r: Rel) std.Io.Writer.Error!void {
    const words = slots.relWords(r);
    if (words.len == 0) return w.writeAll("ε");
    for (words) |word| {
        const s = Place.Step.fromWord(word);
        switch (s.kind) {
            .field => try w.print(".{s}", .{names.field(names.ctx, s.payload)}),
            .index => try w.print(".{d}", .{s.payload}),
            .ctor_arg => {
                const ca = places.ctorArgOf(s);
                try w.print("#{d}.{d}", .{ ca[0], ca[1] });
            },
            .elem => try w.writeAll("[*]"),
            .contents => try w.writeAll("◆"),
            .env => try w.writeAll("◇"),
            .slot => try w.print("⟨{d}⟩", .{s.payload}),
            .level => try w.writeAll("⟲"),
        }
    }
}

fn condText(t: *const Table, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, c: StoredCond) std.Io.Writer.Error!void {
    if (c.no) return w.writeAll("no");
    const run = t.occsOf(c);
    if (run.len == 0) return w.writeAll("yes");
    try w.writeAll("⇐ sel");
    var last: u32 = none;
    for (run) |o| {
        if (occParam(o) != last) {
            if (last != none) try w.writeAll("}");
            try w.print(" π{d}{{", .{occParam(o) + 1});
            last = occParam(o);
        } else try w.writeAll(",");
        try relText(slots, places, names, w, occRel(o));
        if (isApart(o)) try w.writeAll("~");
    }
    try w.writeAll("}");
}

fn effectsText(t: *const Table, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, r: Range) std.Io.Writer.Error!void {
    for (t.effectsOf(r)) |e| {
        try w.print(" π{d}", .{e.j + 1});
        try relText(slots, places, names, w, e.slot);
        if (e.deep) try w.writeAll("*");
    }
}

fn arrivalsText(t: *const Table, c: Id, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, r: Range) std.Io.Writer.Error!void {
    var first = true;
    for (t.resOf(r)) |s| {
        try w.writeAll(if (first) " " else ", ");
        first = false;
        try relText(slots, places, names, w, s.slot);
        if (s.open) try w.writeAll("…");
        for (t.arrivalsOf(s.arrivals)) |a| switch (a.kind) {
            .param => {
                try w.print(" π{d}", .{a.j + 1});
                try relText(slots, places, names, w, a.slot);
                if (a.deep) try w.writeAll("*");
            },
            .fresh => try w.writeAll(" fresh"),
            .shared => try w.writeAll(" shared"),
            .cb => {
                const l = t.labelAt(c, a.j);
                try w.print(" cb(π{d}", .{l.j + 1});
                try relText(slots, places, names, w, l.slot);
                try w.print("@{d})", .{l.origin[2]});
            },
            .top => try w.writeAll(" ⊤"),
        };
    }
}

/// The contract's text, the dump's `summary` line after its name.
pub fn print(t: *const Table, c: Id, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const h = t.heads.items[c];
    if (h.flags.pessimistic) try w.writeAll("pessimistic; ");
    if (h.flags.cross) try w.writeAll("res crossing") else if (!h.flags.returns) try w.writeAll("res ⊥") else {
        try w.writeAll("res");
        try arrivalsText(t, c, slots, places, names, w, h.res);
    }
    try w.writeAll("; nondup ");
    try condText(t, slots, places, names, w, h.res_cond);
    if (h.reads.len != 0) {
        try w.writeAll("; reads");
        try effectsText(t, slots, places, names, w, h.reads);
    }
    if (h.writes.len != 0) {
        try w.writeAll("; writes");
        try effectsText(t, slots, places, names, w, h.writes);
        try w.writeAll("; req ");
        try condText(t, slots, places, names, w, h.req);
    }
    if (h.escapes.len != 0) {
        try w.writeAll("; escapes");
        try effectsText(t, slots, places, names, w, h.escapes);
    }
    for (t.labelsOf(h.labels)) |l| {
        try w.print("; label π{d}", .{l.j + 1});
        try relText(slots, places, names, w, l.slot);
        try w.print("@{d} {t}", .{ l.origin[2], l.calls });
        for (t.suppliesOf(l.supplies)) |s| {
            try w.print(" [{d}:", .{s.k + 1});
            try arrivalsText(t, c, slots, places, names, w, s.res);
            if (s.kept.len != 0) {
                try w.writeAll(" kept");
                try effectsText(t, slots, places, names, w, s.kept);
            }
            try w.writeAll(" sep ");
            try condText(t, slots, places, names, w, s.cond);
            try w.writeAll("]");
        }
    }
    if (h.flags.once) try w.writeAll("; once");
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

test "a join keeps every result slot of both sides" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var slots: Slots.Table = .{};
    defer slots.deinit(gpa);
    var places: Place.Table = .{};
    defer places.deinit(gpa);
    var t: Table = .{};
    defer t.deinit(gpa);
    const r1 = try slots.relOfWords(gpa, &account, &places, &.{1});
    const r2 = try slots.relOfWords(gpa, &account, &places, &.{2});
    var da: Draft = .{ .arity = 1, .flags = .{ .returns = true } };
    _ = try Draft.addArrival(&da.res, arena, r1, .{ .kind = .param, .j = 0, .slot = r1 });
    var db: Draft = .{ .arity = 1, .flags = .{ .returns = true } };
    _ = try Draft.addArrival(&db.res, arena, r2, .{ .kind = .fresh });
    const a = try t.commit(gpa, &account, &slots, &da);
    const b = try t.commit(gpa, &account, &slots, &db);
    const j = try t.join(gpa, arena, &account, &slots, a, b);
    try testing.expectEqual(@as(u32, 2), t.head(j).res.len);
    try testing.expect(try t.within(arena, &slots, a, j) and try t.within(arena, &slots, b, j) and !try t.within(arena, &slots, j, a));
}
