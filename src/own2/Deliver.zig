//! L9: a recursive group's deliveries (`docs/design/ownership-v2.md`
//! §2.12 step 2). The members' evaluations are open at once; a member's
//! new fact (an arrival, a write, an escape) is delivered to the keys and
//! calls that read it, once per reader, and a key's new leaf to each of its
//! consumers: semi-naive, never a walk or an evaluation again. The
//! validation round (§2.12 step 3, `Groups`) checks what it inferred.
//!
//! Obligations kept here: none of §2.14's directly; what it infers is
//! validated by a plain evaluation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Replay = @import("Replay.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Eval = @import("Eval.zig");

pub const Error = Ids.ChargeError;
const Evaluation = Eval.Evaluation;

/// The codes of a group being solved: their evaluations and drafts, who
/// reads whose facts, and the queue of facts and keys still to deliver.
/// Facts only grow (arrivals, writes, escapes), so each is delivered once
/// per reader: semi-naive, never a walk or an evaluation again.
pub const Solver = struct {
    gpa: Allocator,
    /// Group code → its index here.
    member: Ids.FixedDict(1) = .{},
    evals: []Evaluation,
    drafts: []Contract.Draft,
    /// `(member, result rel)` → a run of `res_lists`: the keys `(eval, key)`
    /// reading that slot exactly; and per member every key reading it (an
    /// open slot's arrivals reach the keys below it).
    res_watch: Ids.FixedDict(2) = .{},
    res_lists: std.ArrayList(std.ArrayList([2]u32)) = .empty,
    all_watch: std.ArrayList(std.ArrayList([3]u32)) = .empty,
    /// Per member: the keys `(eval, key, prefix rel)` reading its result at
    /// and below a prefix (`Relation.Eval.instBelow`).
    below_watch: std.ArrayList(std.ArrayList([3]u32)) = .empty,
    /// Per member: the calls `(eval, call)` of it whose effects it delivers.
    eff_watch: std.ArrayList(std.ArrayList([2]u32)) = .empty,
    queue: std.ArrayList(Item) = .empty,
    draining: bool = false,
    /// Some code read a member's draft or effects this round.
    used: bool = false,
    live: Relation.Live = undefined,
    group: Eval.Group = undefined,

    const Item = struct {
        kind: enum(u8) { key, res, node, write, escape },
        x: u32,
        a: u32 = 0,
        open: bool = false,
        arrival: Contract.Arrival = .{ .kind = .top },
        effect: Contract.Effect = .{ .j = 0, .slot = 0 },
        node: Contract.Node = 0,
    };

    pub fn init(s: *Solver, gpa: Allocator, codes: []const u32, evals: []Evaluation, drafts: []Contract.Draft) Error!void {
        s.* = .{ .gpa = gpa, .evals = evals, .drafts = drafts };
        s.live = .{ .ctx = s, .draftRes = draftRes, .watch = watch, .watchBelow = watchBelow, .dirty = dirty, .deliver = deliverFn, .pump = pumpFn, .labelIn = labelIn };
        s.group = .{ .ctx = s, .live = &s.live, .member = memberFn, .watchEffects = watchEffectsFn, .resFact = resFactFn, .effFact = effFactFn };
        for (codes, 0..) |c, x| {
            try s.member.put(gpa, .{c}, @intCast(x));
            try s.all_watch.append(gpa, .empty);
            try s.below_watch.append(gpa, .empty);
            try s.eff_watch.append(gpa, .empty);
        }
    }

    pub fn deinit(s: *Solver) void {
        s.member.deinit(s.gpa);
        s.res_watch.deinit(s.gpa);
        for (s.res_lists.items) |*l| l.deinit(s.gpa);
        s.res_lists.deinit(s.gpa);
        for (s.all_watch.items) |*l| l.deinit(s.gpa);
        s.all_watch.deinit(s.gpa);
        for (s.below_watch.items) |*l| l.deinit(s.gpa);
        s.below_watch.deinit(s.gpa);
        for (s.eff_watch.items) |*l| l.deinit(s.gpa);
        s.eff_watch.deinit(s.gpa);
        s.queue.deinit(s.gpa);
    }

    pub fn memberOf(s: *const Solver, code: u32) ?u32 {
        return s.member.get(.{code});
    }

    fn self(ctx: *anyopaque) *Solver {
        return @ptrCast(@alignCast(ctx));
    }

    fn evalIndex(s: *Solver, ev: *Relation.Eval) u32 {
        const e: *Evaluation = @fieldParentPtr("ev", ev);
        return @intCast((@intFromPtr(e) - @intFromPtr(s.evals.ptr)) / @sizeOf(Evaluation));
    }

    fn draftRes(ctx: *anyopaque, code: u32) ?*Contract.Draft.Res {
        const s = self(ctx);
        const x = s.memberOf(code) orelse return null;
        return &s.drafts[x].res;
    }

    fn watch(ctx: *anyopaque, code: u32, rel: Slots.Rel, ev: *Relation.Eval, key: u32) Error!void {
        const s = self(ctx);
        const x = s.memberOf(code).?;
        const y = s.evalIndex(ev);
        s.used = true;
        const got = try s.res_watch.getOrPut(s.gpa, .{ x, rel });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(s.res_lists.items.len);
            try s.res_lists.append(s.gpa, .empty);
        }
        try s.res_lists.items[got.value_ptr.*].append(s.gpa, .{ y, key });
        try s.all_watch.items[x].append(s.gpa, .{ y, key, rel });
    }

    fn watchBelow(ctx: *anyopaque, code: u32, rel: Slots.Rel, ev: *Relation.Eval, key: u32) Error!void {
        const s = self(ctx);
        const x = s.memberOf(code).?;
        s.used = true;
        try s.below_watch.items[x].append(s.gpa, .{ s.evalIndex(ev), key, rel });
    }

    fn dirty(ctx: *anyopaque, ev: *Relation.Eval, key: u32) Error!void {
        const s = self(ctx);
        try s.queue.append(s.gpa, .{ .kind = .key, .x = s.evalIndex(ev), .a = key });
    }

    fn deliverFn(ctx: *anyopaque, ev: *Relation.Eval, sub: Relation.Sub, leaf: u32, at: u32) Error!void {
        _ = ctx;
        const e: *Evaluation = @fieldParentPtr("ev", ev);
        // An escape the evaluation subscribed before its read-off began
        // (a function value run by unknown code) is read off with the rest.
        if (sub.kind == .escape_fn) return Eval.deliverFns(e, sub, leaf);
        if (!e.facts_on and sub.kind == .escape) return Eval.addEscape(e, (try e.fr().withTags(leaf, sub.tags)) orelse return, sub.a);
        try e.hooks.deliver(e, sub, leaf, at);
    }

    fn labelIn(ctx: *anyopaque, code: u32, i: u32, c: Contract.Id) ?u32 {
        const s = self(ctx);
        const x = s.memberOf(code) orelse return null;
        const dl = s.drafts[x].labels.items[i];
        const t = s.evals[x].contracts;
        for (t.labelsOf(t.head(c).labels), 0..) |l, k| {
            if (l.j == dl.j and l.slot == dl.slot and std.mem.eql(u32, &l.origin, &dl.origin)) return @intCast(k);
        }
        return null;
    }

    fn memberFn(ctx: *anyopaque, code: u32) ?Eval.Group.Member {
        const s = self(ctx);
        const x = s.memberOf(code) orelse return null;
        return .{ .x = x, .draft = &s.drafts[x] };
    }

    fn watchEffectsFn(ctx: *anyopaque, x: u32, y: u32, call: u32) Error!void {
        try self(ctx).watchEffects(x, y, call);
    }

    fn resFactFn(ctx: *anyopaque, x: u32, rel: Slots.Rel, open: bool, a: Contract.Arrival, n: Contract.Node) Error!void {
        try self(ctx).queue.append(self(ctx).gpa, .{ .kind = if (n != 0) .node else .res, .x = x, .a = rel, .open = open, .arrival = a, .node = n });
    }

    fn effFactFn(ctx: *anyopaque, x: u32, write: bool, eff: Contract.Effect) Error!void {
        try self(ctx).effFact(x, write, eff);
    }

    fn pumpFn(ctx: *anyopaque) Error!void {
        try self(ctx).pump();
    }

    pub fn effFact(s: *Solver, x: u32, write: bool, eff: Contract.Effect) Error!void {
        try s.queue.append(s.gpa, .{ .kind = if (write) .write else .escape, .x = x, .effect = eff });
    }

    pub fn watchEffects(s: *Solver, x: u32, y: u32, call: u32) Error!void {
        s.used = true;
        try s.eff_watch.items[x].append(s.gpa, .{ y, call });
    }

    /// Deliver until nothing is queued (§2.12 step 2).
    pub fn pump(s: *Solver) Error!void {
        if (s.draining) return;
        s.draining = true;
        defer s.draining = false;
        var at: usize = 0;
        while (at < s.queue.items.len) : (at += 1) {
            const it = s.queue.items[at];
            switch (it.kind) {
                .key => try s.evals[it.x].ev.drainKey(it.a),
                .node => try s.nodeItem(it.x, it.a, it.node),
                .res => try s.resItem(it.x, it.a, it.open, it.arrival),
                .write, .escape => {
                    var i: usize = 0;
                    while (i < s.eff_watch.items[it.x].items.len) : (i += 1) {
                        const cw = s.eff_watch.items[it.x].items[i];
                        const e = &s.evals[cw[0]];
                        try e.ev.f.charge(.edge, 1);
                        if (it.kind == .write) try Eval.callWrite(e, cw[1], it.effect) else try Eval.callEscape(e, cw[1], it.effect);
                    }
                },
            }
        }
        s.queue.clearRetainingCapacity();
    }

    /// Member `x`'s subtree `n` below result slot `rel`, delivered to the
    /// keys that read it: a key at a slot reads what the subtree says
    /// there (its open nodes above it too), a key below a prefix every
    /// entry at and below the prefix and each open one above it.
    fn nodeItem(s: *Solver, x: u32, rel: Slots.Rel, n: Contract.Node) Error!void {
        const e0 = &s.evals[x];
        const t = &e0.contracts.trees;
        const sl = e0.ev.f.slots;
        const rw = sl.relWords(rel);
        var bi: usize = 0;
        while (bi < s.below_watch.items[x].items.len) : (bi += 1) {
            const kw = s.below_watch.items[x].items[bi];
            const e = &s.evals[kw[0]];
            try e.ev.f.charge(.edge, 1);
            const pw = sl.relWords(kw[2]);
            var sub = n;
            var d: usize = rw.len;
            if (pw.len > rw.len) {
                if (!std.mem.eql(u32, rw, pw[0..rw.len])) continue;
                // Down to the prefix: an open node on the way holds below it.
                while (d < pw.len and sub != 0) : (d += 1) {
                    const on = t.kidAt(sub, pw[d]);
                    for ([_]Forest.Node{ sub, if (on == null) t.rowKid(sub, pw[d]) orelse 0 else 0 }) |o| if (o != 0) {
                        const at = sl.rels.find(pw[0..d]) orelse try sl.relOfWords(s.gpa, e0.ev.f.account, e0.ev.f.places, pw[0..d]);
                        const opens = try s.gpa.dupe(Contract.Arrival, t.open(o));
                        defer s.gpa.free(opens);
                        for (opens) |a| try e.ev.feedBelowDraft(kw[1], at, true, a);
                    };
                    sub = on orelse 0;
                }
            } else if (!std.mem.eql(u32, pw, rw[0..pw.len])) continue;
            var es: Forest.Entries = .{};
            defer es.deinit(s.gpa);
            try es.of(t, s.gpa, e0.ev.f.places, sub, if (pw.len > rw.len) pw else rw);
            for (es.items.items) |y| {
                const at = sl.rels.find(es.wordsOf(y)) orelse try sl.relOfWords(s.gpa, e0.ev.f.account, e0.ev.f.places, es.wordsOf(y));
                for (y.arrivals) |a| try e.ev.feedBelowDraft(kw[1], at, y.open, a);
            }
        }
        var hits: std.ArrayList(Contract.Hit) = .empty;
        defer hits.deinit(s.gpa);
        var i: usize = 0;
        while (i < s.all_watch.items[x].items.len) : (i += 1) {
            const kw = s.all_watch.items[x].items[i];
            const e = &s.evals[kw[0]];
            try e.ev.f.charge(.edge, 1);
            const words = sl.relWords(kw[2]);
            if (words.len < rw.len or !std.mem.eql(u32, rw, words[0..rw.len])) continue;
            hits.clearRetainingCapacity();
            _ = try Forest.atSlot(t, s.gpa, n, words[rw.len..], &hits);
            var arrs: std.ArrayList(struct { a: Contract.Arrival, n: u32, open: bool }) = .empty;
            defer arrs.deinit(s.gpa);
            for (hits.items) |h| for (h.arrivals) |a| try arrs.append(s.gpa, .{ .a = a, .n = @intCast(rw.len + h.depth), .open = h.open });
            for (arrs.items) |y| try e.ev.feedDraft(kw[1], y.a, y.n, y.open);
        }
    }

    /// Member `x`.s arrival `a` at result slot `rel`, delivered to the keys
    /// that read it.
    fn resItem(s: *Solver, x: u32, rel: Slots.Rel, open: bool, arrival: Contract.Arrival) Error!void {
        const rw = s.evals[x].ev.f.slots.relWords(rel);
        // The keys below a prefix: each reads the fact itself.
        var bi: usize = 0;
        while (bi < s.below_watch.items[x].items.len) : (bi += 1) {
            const kw = s.below_watch.items[x].items[bi];
            const e = &s.evals[kw[0]];
            try e.ev.f.charge(.edge, 1);
            try e.ev.feedBelowDraft(kw[1], rel, open, arrival);
        }
        if (open) {
            // Every key at or below an open slot.
            var i: usize = 0;
            while (i < s.all_watch.items[x].items.len) : (i += 1) {
                const kw = s.all_watch.items[x].items[i];
                const e = &s.evals[kw[0]];
                try e.ev.f.charge(.edge, 1);
                const words = e.ev.f.slots.relWords(kw[2]);
                const row = Replay.inRowOf(rw, words);
                if (!row and (words.len < rw.len or !std.mem.eql(u32, rw, words[0..rw.len]))) continue;
                try e.ev.feedDraft(kw[1], arrival, @intCast(if (row) rw.len - 1 else rw.len), true);
            }
        } else if (s.res_watch.get(.{ x, rel })) |li| {
            var i: usize = 0;
            while (i < s.res_lists.items[li].items.len) : (i += 1) {
                const kw = s.res_lists.items[li].items[i];
                try s.evals[kw[0]].ev.feedDraft(kw[1], arrival, @intCast(rw.len), false);
            }
        }
    }
};
