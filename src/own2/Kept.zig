//! L11: judgements kept across a group's rounds (`docs/design/ownership-v2.md`
//! §2.12, *judgements kept across rounds*). A round's demand judgement is
//! kept with what it read: the demand by its key (its fields, targets and
//! operands), the later uses' footprints it read (each call's read and
//! write tree node of the parameter), and where it stood in the round's
//! holder events (a holder keyed, a hold or a holder's aggregated holds
//! done). The round's reads of the candidates and drafts that no key
//! names — results, result conditions, labels, flags — and the frame's
//! escapes are compared once a round, whole. In the next round a demand
//! whose key, footprints and holder events are the same takes the kept
//! verdict, its conditions and its events again; any other is judged.
//!
//! Obligations kept here: none of §2.14's directly; a kept verdict is the
//! one a judgement makes again, which `-Downership-full-cross-check`
//! checks against a full judgement of every demand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Walk = @import("Walk.zig");

pub const Error = Ids.ChargeError;
const Cond = Contract.Cond;
const PathId = Ids.PathId;
const Range = Ids.Range;
const none: u32 = Ids.none_int;

/// Every judgement is checked against a kept one (§2.12).
pub const cross = std.debug.runtime_safety and @import("ownership_options").full_cross_check;

/// What `Resolve` tells the read-off: the accepted demands' reliance and each direct label's kept slots and condition.
pub const Verdicts = struct {
    req: Cond = .{},
    /// Per frame label: the kept argument slots, as `(k, leaf)` pairs.
    kept: []const [3]u32 = &.{},
    /// Per frame label and argument (`label * width + k`): the condition
    /// that supply's check relied on (§2.11.3).
    supply_cond: []const Cond = &.{},
    width: u32 = 1,
    /// Per passed-on label (`passes`' index): the kept supply slots, as
    /// `(pass, k, leaf, at)` (`at`: the leaf's slot in the supply), and
    /// each supply's condition (`pass * width + k`).
    pass_kept: []const [4]u32 = &.{},
    pass_cond: []const Cond = &.{},
};

pub const HolderKind = enum(u8) { binding, pending };

/// The holder a refusal names: a local (`who`) or a pending operand (its
/// instruction's token).
pub const Holder = struct { kind: HolderKind, who: u32, token: u32 };

/// A demand's verdict (R-0.3) with what `Message` says of it.
pub const Outcome = struct {
    verdict: enum(u8) { accepted, refused } = .accepted,
    accepted: Facts.Verdict.Accepted = .fresh,
    cause: Facts.Cause = .unknown,
    exactness: Facts.Exactness = .exact,
    holder_path: PathId = .none,
    other_paths: bool = false,
    /// `top_level`: the value's `(module, declaration)`.
    shared: [2]u32 = .{ none, none },
    /// `loan`: the callee that lent it and the cell, as instructions.
    loan: [2]u32 = .{ none, none },
};

/// One verdict line: the demand, its outcome, the holder and the use.
pub const Line = struct {
    demand: Walk.Demand,
    outcome: Outcome,
    holder: ?Holder = null,
    /// What the judgement added to `demand.relies` (the callee's own,
    /// shared by its call's demands): gathered apart, so that a frame's
    /// `req` reads a call's `relies` once, not once per write of it.
    extra: Cond = .{},
    use_token: u32 = none,
};

/// A holder event (§2.8's sweep): `key` holder `hi` keyed, `hold` its
/// hold `k` done, `holder` its aggregated holds done.
pub const Event = [3]u32;
pub const key_event: u32 = 0;
pub const hold_event: u32 = 1;
pub const holder_event: u32 = 2;

/// A hold (`hold_event`) or a holder's aggregated holds
/// (`holder_event`) done on resolver `r`'s sweep, an event of the round.
pub fn done(r: anytype, kind: u32, hi: u32, k: u32) Error!void {
    if (kind == hold_event) r.live.holdsOf(hi)[k].done = true else r.live.aggDone(hi);
    if (r.kept) |t| try t.event(r.e.w.f.gpa, .{ kind, hi, k });
}

/// A kept judgement: its key's lists, its line, and what it read and did,
/// as runs of `Gen.words`.
const Rec = struct {
    next: u32 = none,
    targets: Range,
    operands: Range,
    line: Line,
    /// `(call, parameter, read node, write node)` a footprint read.
    feet: Range,
    /// The round's holder events before it, and its own.
    log_at: u32,
    events: Range,
    /// Its `(call, argument, target)` and pending `(clock, point, target)`
    /// writes, for the round's `req`.
    writes: Range,
    swrites: Range,
};

const Gen = struct {
    arena: std.heap.ArenaAllocator,
    keys: Ids.FixedDict(8) = .{},
    recs: std.ArrayList(Rec) = .empty,
    words: std.ArrayList(u32) = .empty,
    log: std.ArrayList(Event) = .empty,
    escapes: std.ArrayList(Walk.Escape) = .empty,

    fn deinit(x: *Gen, g: Allocator) void {
        x.arena.deinit();
        x.keys.deinit(g);
        inline for (.{ &x.recs, &x.words, &x.log, &x.escapes }) |l| l.deinit(g);
    }
    fn clear(x: *Gen) void {
        _ = x.arena.reset(.retain_capacity);
        x.keys.clearRetainingCapacity();
        inline for (.{ &x.recs, &x.words, &x.log, &x.escapes }) |l| l.clearRetainingCapacity();
    }
    fn run(x: *const Gen, r: Range) []const u32 {
        return x.words.items[r.start..][0..r.len];
    }
    fn add(x: *Gen, g: Allocator, ws: []const u32) Error!Range {
        const s: u32 = @intCast(x.words.items.len);
        try x.words.appendSlice(g, ws);
        return .{ .start = s, .len = @intCast(ws.len) };
    }
};

/// One code's kept judgements: the round before's and this round's.
pub const Table = struct {
    gens: [2]Gen,
    cur: u1 = 0,
    /// Whether this round may take a judgement of the round before.
    same: bool = false,
    /// Whether the group's print is the round before's (`Group.round`).
    group_same: bool = false,
    /// The round's holder events equal to the round before's so far.
    lcp: u32 = 0,
    /// The current judgement's footprints read (`Later.Uses.feet`).
    feet: std.ArrayList([2]u32) = .empty,
    scratch: std.ArrayList(u32) = .empty,

    pub fn init(g: Allocator) Table {
        return .{ .gens = .{ .{ .arena = .init(g) }, .{ .arena = .init(g) } } };
    }
    pub fn deinit(t: *Table, g: Allocator) void {
        for (&t.gens) |*x| x.deinit(g);
        t.feet.deinit(g);
        t.scratch.deinit(g);
    }
    fn now(t: *Table) *Gen {
        return &t.gens[t.cur];
    }
    fn before(t: *Table) *Gen {
        return &t.gens[t.cur ^ 1];
    }

    /// Begin a round of this code: the round before's judgements may be
    /// taken when the group's print (`Group.round`) and the frame's escapes
    /// are what they were.
    pub fn begin(t: *Table, g: Allocator, escapes: []const Walk.Escape) Error!void {
        t.cur ^= 1;
        t.now().clear();
        try t.now().escapes.appendSlice(g, escapes);
        const was = t.before().escapes.items;
        t.same = t.group_same and t.before().recs.items.len != 0 and was.len == escapes.len;
        if (t.same) for (was, escapes) |a, b| {
            if (a.leaf != b.leaf or a.point != b.point or a.call != b.call) t.same = false;
        };
        t.lcp = 0;
    }

    fn keyOf(d: Walk.Demand) [8]u32 {
        const flags: u32 = @as(u32, @intFromBool(d.relies.no)) | @as(u32, @intFromBool(d.kept)) << 1 | @as(u32, @intFromBool(d.many)) << 2 | @as(u32, @intFromBool(d.callback)) << 3;
        return .{ d.point, @backingInt(d.kind), d.base_inst, d.call, d.arg, d.pending, d.base_local, flags };
    }

    /// The round before's judgement of a demand with `d`'s key, when what
    /// it read is what this round reads.
    pub fn find(t: *Table, w: *Walk.Walk, d: Walk.Demand, contracts: *const Contract.Table) Error!?u32 {
        if (!t.same) return null;
        const x = t.before();
        var at = x.keys.get(keyOf(d)) orelse return null;
        const log = t.now().log.items.len;
        while (at != none) : (at = x.recs.items[at].next) {
            const r = x.recs.items[at];
            try w.f.charge(.inspection, 1);
            if (!std.mem.eql(u32, x.run(r.targets), w.leavesOfRun(d.targets)) or !std.mem.eql(u32, x.run(r.operands), w.valuesOfRun(d.operands))) continue;
            if (r.log_at != log or t.lcp != log) return null;
            const fs = x.run(r.feet);
            try w.f.charge(.inspection, @intCast(fs.len / 4));
            var i: usize = 0;
            while (i < fs.len) : (i += 4) if (!std.mem.eql(u32, fs[i..][0..4], &footOf(&w.f, contracts, fs[i..][0..2].*))) return null;
            return at;
        }
        return null;
    }

    /// A footprint's nodes now: the callee's read and write tree of the
    /// parameter (0 none).
    fn footOf(f: *const Value.Frame, contracts: *const Contract.Table, foot: [2]u32) [4]u32 {
        const c = f.calls.items[foot[0]].contract;
        var out: [4]u32 = .{ foot[0], foot[1], none, none };
        if (c == none) return out;
        const h = contracts.head(c);
        out[2] = 0;
        out[3] = 0;
        for (contracts.readsOf(h.reads)) |r| if (r[0] == foot[1]) {
            out[2] = r[1];
        };
        for (contracts.writesOf(h.writes)) |r| if (r[0] == foot[1]) {
            out[3] = r[1];
        };
        return out;
    }

    pub fn line(t: *Table, ri: u32) Line {
        return t.before().recs.items[ri].line;
    }
    pub fn events(t: *Table, ri: u32) []const u32 {
        return t.before().run(t.before().recs.items[ri].events);
    }
    pub fn writes(t: *Table, ri: u32) []const [3]u32 {
        return @ptrCast(t.before().run(t.before().recs.items[ri].writes));
    }
    pub fn swrites(t: *Table, ri: u32) []const [3]u32 {
        return @ptrCast(t.before().run(t.before().recs.items[ri].swrites));
    }

    /// A holder event of this round, in order.
    pub fn event(t: *Table, g: Allocator, e: Event) Error!void {
        const x = t.now();
        try x.log.append(g, e);
        const b = t.before().log.items;
        if (t.lcp + 1 == x.log.items.len and t.lcp < b.len and std.mem.eql(u32, &b[t.lcp], &e)) t.lcp += 1;
    }

    /// Where the next judgement starts: its footprints forgotten, the
    /// round's events and writes so far.
    pub fn mark(t: *Table, writes_len: usize, swrites_len: usize) [3]u32 {
        t.feet.clearRetainingCapacity();
        return .{ @intCast(t.now().log.items.len), @intCast(writes_len), @intCast(swrites_len) };
    }

    /// Keep judgement `l` of `d` for the next round: what it read (since
    /// `at`, `mark`'s) and the writes it made.
    pub fn put(t: *Table, g: Allocator, w: *Walk.Walk, contracts: *const Contract.Table, d: Walk.Demand, l: Line, at: [3]u32, ws: []const [3]u32, sws: []const [3]u32) Error!void {
        const x = t.now();
        std.mem.sort([2]u32, t.feet.items, {}, struct {
            fn lt(_: void, a: [2]u32, b: [2]u32) bool {
                return std.mem.order(u32, &a, &b) == .lt;
            }
        }.lt);
        t.scratch.clearRetainingCapacity();
        for (t.feet.items, 0..) |ft, i| if (i == 0 or !std.mem.eql(u32, &t.feet.items[i - 1], &ft)) try t.scratch.appendSlice(g, &footOf(&w.f, contracts, ft));
        var r: Rec = .{ .targets = try x.add(g, w.leavesOfRun(d.targets)), .operands = try x.add(g, w.valuesOfRun(d.operands)), .line = l, .feet = try x.add(g, t.scratch.items), .log_at = at[0], .events = try x.add(g, @ptrCast(x.log.items[at[0]..])), .writes = try x.add(g, @ptrCast(ws)), .swrites = try x.add(g, @ptrCast(sws)) };
        r.line.extra.sel = try x.arena.allocator().dupe(u64, l.extra.sel);
        const got = try x.keys.getOrPut(g, keyOf(d));
        r.next = if (got.found_existing) got.value_ptr.* else none;
        got.value_ptr.* = @intCast(x.recs.items.len);
        try x.recs.append(g, r);
    }

    /// Take the round before's judgement `ri` again for `d` on resolver `r`
    /// (`Resolve`): its line, its holder events made again (a keying by
    /// keying the live holders, as it did), its writes; kept again.
    pub fn replay(t: *Table, r: anytype, d: Walk.Demand, ri: u32, at: [3]u32) Error!Line {
        const w = r.e.w;
        const g = w.f.gpa;
        var l = t.line(ri);
        l.demand = d;
        const evs = t.events(ri);
        var i: usize = 0;
        while (i < evs.len) : (i += 3) switch (evs[i]) {
            key_event => if (i == 0) try r.keyLive(),
            else => try done(r, evs[i], evs[i + 1], evs[i + 2]),
        };
        if (std.debug.runtime_safety) std.debug.assert(std.mem.eql(u32, evs, @ptrCast(t.now().log.items[at[0]..])));
        try r.ops.writes.appendSlice(g, t.writes(ri));
        // A pending write is made on the built index, as the judgement built it.
        if (t.swrites(ri).len != 0) try r.stack.build(&r.e.ev, w, r.regions, &r.keys);
        try r.stack.writes.appendSlice(g, t.swrites(ri));
        try t.carry(g, w, r.e.contracts, d, ri, at);
        return l;
    }

    /// Judgement `l` of `d`, made from `at`, kept; under the cross-check
    /// compared with the kept one `found`.
    pub fn judged(t: *Table, r: anytype, d: Walk.Demand, l: Line, found: ?u32, at: [3]u32) Error!Line {
        const ws = r.ops.writes.items[at[1]..];
        const sws = r.stack.writes.items[at[2]..];
        if (found) |ri| t.check(ri, l, at, ws, sws);
        try t.put(r.e.w.f.gpa, r.e.w, r.e.contracts, d, l, at, ws, sws);
        return l;
    }

    /// Keep the round before's judgement `ri` again, for `d`.
    pub fn carry(t: *Table, g: Allocator, w: *Walk.Walk, contracts: *const Contract.Table, d: Walk.Demand, ri: u32, at: [3]u32) Error!void {
        const r = t.before().recs.items[ri];
        t.feet.clearRetainingCapacity();
        const fs = t.before().run(r.feet);
        var i: usize = 0;
        while (i < fs.len) : (i += 4) try t.feet.append(g, fs[i..][0..2].*);
        try t.put(g, w, contracts, d, r.line, at, t.writes(ri), t.swrites(ri));
    }

    /// Under the cross-check: the full judgement `l` (from `at`) is the
    /// kept one `ri`, its line, its events and its writes.
    pub fn check(t: *Table, ri: u32, l: Line, at: [3]u32, ws: []const [3]u32, sws: []const [3]u32) void {
        const k = t.line(ri);
        const evs: []const u32 = @ptrCast(t.now().log.items[at[0]..]);
        const same = std.meta.eql(k.outcome, l.outcome) and std.meta.eql(k.holder, l.holder) and k.use_token == l.use_token and k.extra.eql(l.extra) and
            std.mem.eql(u32, t.events(ri), evs) and std.mem.eql(u32, @ptrCast(t.writes(ri)), @ptrCast(ws)) and std.mem.eql(u32, @ptrCast(t.swrites(ri)), @ptrCast(sws));
        if (!same) std.debug.panic("ownership v2: a kept judgement at point {d} differs from the full one (§2.12)", .{l.demand.point});
    }
};

/// A group's kept judgements, a table a code, and the print of what the
/// round reads whole: each code's candidate (result, its condition, labels,
/// flags) and its draft's result and labels.
pub const Group = struct {
    tables: []Table,
    prints: [2]std.ArrayList(u32) = .{ .empty, .empty },
    cur: u1 = 0,
    same: bool = false,

    pub fn init(g: Allocator, n: usize) Error!Group {
        const ts = try g.alloc(Table, n);
        for (ts) |*t| t.* = .init(g);
        return .{ .tables = ts };
    }
    pub fn deinit(x: *Group, g: Allocator) void {
        for (x.tables) |*t| t.deinit(g);
        g.free(x.tables);
        for (&x.prints) |*p| p.deinit(g);
    }

    /// The round's print, at its resolution: `codes[ids[i]].contract` is
    /// code `i`'s candidate, `drafts[i]` its draft, `evals[i]` its
    /// evaluation. A round with no demand to keep prints nothing.
    pub fn round(x: *Group, g: Allocator, account: *Ids.Account, contracts: *const Contract.Table, codes: anytype, ids: []const u32, drafts: []const Contract.Draft, evals: anytype) Error!void {
        x.cur ^= 1;
        const p = &x.prints[x.cur];
        p.clearRetainingCapacity();
        x.same = false;
        for (x.tables) |*t| t.group_same = false;
        for (evals) |*e| {
            if (e.demands.items.len != 0) break;
        } else return;
        for (ids, drafts) |id, *d| {
            const h = contracts.head(codes[id].contract);
            try p.appendSlice(g, &.{ h.res_root, @as(u8, @bitCast(h.flags)) });
            try putCond(p, g, contracts.occsOf(h.res_cond), h.res_cond.no);
            const ls = contracts.labelsOf(h.labels);
            try p.append(g, @intCast(ls.len));
            for (ls) |l| {
                try p.appendSlice(g, &.{ l.j, l.slot, l.origin[0], l.origin[1], l.origin[2], @backingInt(l.calls) });
                const ss = contracts.suppliesOf(l.supplies);
                try p.append(g, @intCast(ss.len));
                for (ss) |s| {
                    try p.appendSlice(g, &.{ s.k, s.res_root, @intFromBool(s.each) });
                    try putEffects(p, g, contracts.effectsOf(s.kept));
                    try putCond(p, g, contracts.occsOf(s.cond), s.cond.no);
                    try putCond(p, g, contracts.occsOf(s.below), s.below.no);
                }
            }
            try p.append(g, @as(u8, @bitCast(d.flags)));
            try putRes(p, g, &d.res);
            try p.append(g, @intCast(d.labels.items.len));
            for (d.labels.items) |l| {
                try p.appendSlice(g, &.{ l.j, l.slot, l.origin[0], l.origin[1], l.origin[2], @backingInt(l.calls), @intCast(l.supplies.items.len) });
                for (l.supplies.items) |*s| {
                    try p.append(g, s.k);
                    try putRes(p, g, &s.res);
                    try putEffects(p, g, s.kept.items);
                }
            }
        }
        try account.reserve(.inspection, @intCast(1 + p.items.len / 16));
        x.same = std.mem.eql(u32, p.items, x.prints[x.cur ^ 1].items);
        for (x.tables) |*t| t.group_same = x.same;
    }

    fn putCond(p: *std.ArrayList(u32), g: Allocator, occs: []const u64, no: bool) Error!void {
        try p.appendSlice(g, &.{ @intFromBool(no), @intCast(occs.len) });
        for (occs) |o| try p.appendSlice(g, &.{ @truncate(o), @truncate(o >> 32) });
    }
    fn putEffects(p: *std.ArrayList(u32), g: Allocator, es: []const Contract.Effect) Error!void {
        try p.append(g, @intCast(es.len));
        for (es) |e| try p.appendSlice(g, &.{ e.j, e.slot, @intFromBool(e.deep), e.node });
    }
    fn putRes(p: *std.ArrayList(u32), g: Allocator, r: *const Contract.Draft.Res) Error!void {
        try p.appendSlice(g, &.{ r.base, @intCast(r.items.items.len) });
        for (r.items.items) |e| try p.appendSlice(g, &.{ e.slot, @as(u32, @intFromBool(e.wide)) | @as(u32, @intFromBool(r.isOpen(e))) << 1 | @as(u32, @intFromBool(e.a.deep)) << 2, @backingInt(e.a.kind), e.a.j, e.a.slot, e.node });
    }
};
