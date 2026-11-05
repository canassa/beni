//! L9: a function value the frame cannot follow (`docs/design/ownership-v2.md`
//! §2.11.3, *a function value goes where a value goes*). A value that is one
//! parameter function slot by every arrival is that slot (`oneParam`, and
//! `settled` for the walk), so a call of it is a label. Any other function
//! value run by code the frame cannot see — a call of it, a callee's label
//! applied to it, a known code's answer to a label — escapes there: the
//! parameters' function slots it comes from, and the frame's own closures it
//! is. A parameter's escape says to every caller that the code it hands has
//! callers nobody checks; a closure's escape makes its parameter writes
//! demands on `⊤` and a capture write `once` (`Closures`). The other objects
//! such a value reaches (a closure's captures) are not function objects and
//! do not escape here. A closure handed to a label escapes at the read-off,
//! which says it into the supply (`Put.handed`).
//!
//! Obligations kept here: O1 (an unknown caller's supplies are `⊤`: the
//! code it runs is said to escape, never dropped).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const LabelChain = @import("LabelChain.zig");
const RouteWalk = @import("RouteWalk.zig");
const Relation = @import("Relation.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const WalkContext = @import("WalkContext.zig");

const Error = Value.Error;

/// Why a value escapes, and so which function objects: `run`, called by
/// unknown code (its own storage: the parameters' function slots and the
/// frame's closures it is); `answer`, a known code's answer to its label,
/// handed back to the callee (every parameter function slot it holds; a
/// closure it holds is `Closures`' hand-back).
pub const Mode = enum { run, answer };

/// The function objects of value `v` at `words` that `mode` gives, into
/// `out`, under a subscription, so that what a growing draft adds later is
/// read the same way (`delivered`, §2.12 *Deliveries*).
pub fn escapes(ev: *Relation.Eval, cx: WalkContext.Context, closures: anytype, v: u32, words: []const u32, mode: Mode, point: u32, call: u32, out: *std.ArrayList(u32)) Error!void {
    // An answer whose place holds no closure holds no function object.
    const at = ev.f.val(v).place;
    if (mode == .answer and at != .none and !ev.places().holds(at).closure) return;
    const saved = ev.cur_sub;
    ev.cur_sub = .{ .kind = .escape_fn, .a = point, .b = @backingInt(mode), .c = call };
    defer ev.cur_sub = saved;
    try leaves(ev, v, words, try wantOf(ev, cx, closures, mode), out);
}

/// The function objects of a leaf delivered to subscription `sub` (`escapes`).
pub fn delivered(ev: *Relation.Eval, cx: WalkContext.Context, closures: anytype, sub: Relation.Sub, leaf: u32, out: *std.ArrayList(u32)) Error!void {
    const y = (try ev.f.withTags(leaf, sub.tags)) orelse return;
    const saved = ev.cur_sub;
    ev.cur_sub = sub;
    defer ev.cur_sub = saved;
    try ofLeaves(ev, &.{y}, try wantOf(ev, cx, closures, @fromBackingInt(@intCast(sub.b))), out);
}

fn wantOf(ev: *Relation.Eval, cx: WalkContext.Context, closures: anytype, mode: Mode) Error!Want {
    if (mode == .answer) return .{ .deep = true };
    var out: std.ArrayList(u32) = .empty;
    for (closures) |c| if (frameSite(ev.contracts, cx, closures, c.inst)) try out.append(ev.arena, c.inst);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return .{ .sites = out.items };
}

/// Which function objects to give: every parameter function slot, and the
/// frame's closures by their sites (sorted).
const Want = struct {
    sites: []const u32 = &.{},
    /// Every object the value reaches, not its own storage alone.
    deep: bool = false,
};

/// Whether `site` is one of the frame's closures `closures` (each with its
/// `code` and `inst`) whose escape matters: not a worded row's, whose
/// value writes nothing in place, only a call site the checker authorises
/// does (§2.11.5 *Evidence*).
pub fn frameSite(contracts: *const Contract.Table, cx: WalkContext.Context, closures: anytype, site: u32) bool {
    for (closures) |c| if (c.inst == site) {
        const k = cx.contractOf(cx.ctx, c.code) orelse return true;
        return !contracts.head(k).flags.words;
    };
    return false;
}

/// The function objects of value `v` at relative steps `words` (its own
/// storage, or deep, every call, supply and label it comes through
/// expanded), as leaves into `out`: each parameter leaf narrowed to its
/// slots at a function's place, each site leaf of one of `want.sites`.
fn leaves(ev: *Relation.Eval, v: u32, words: []const u32, want: Want, out: *std.ArrayList(u32)) Error!void {
    const gpa = ev.gpa();
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try ev.project(v, words, want.deep, 0, 0, &ps);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    for (ps.items) |p| try stack.append(gpa, p.leaf);
    try expanded(ev, &stack, want, out);
}

/// Leaves `ls` (any objects) expanded, the function objects of `want` kept.
fn ofLeaves(ev: *Relation.Eval, ls: []const u32, want: Want, out: *std.ArrayList(u32)) Error!void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(ev.gpa());
    try stack.appendSlice(ev.gpa(), ls);
    try expanded(ev, &stack, want, out);
}

fn expanded(ev: *Relation.Eval, stack: *std.ArrayList(u32), want: Want, out: *std.ArrayList(u32)) Error!void {
    const f = ev.f;
    const gpa = ev.gpa();
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    while (stack.pop()) |li| {
        if ((try seen.getOrPut(gpa, .{li})).found_existing) continue;
        try ev.charge(.inspection, 1);
        const l = f.leafAt(li);
        if (ev.expandable(l)) {
            try ev.expand(li, stack);
            continue;
        }
        switch (l.kind) {
            .site => if (std.sort.binarySearch(u32, want.sites, l.atom, order) != null) try out.append(gpa, li),
            .ref => if (f.roots.items[l.root].kind == .param) {
                var fs: std.ArrayList(u32) = .empty;
                defer fs.deinit(gpa);
                // A subtree held whole (`↓p`) that may hold a closure keeps
                // the leaf whole: more than its function objects escape.
                const whole = for (f.slots.elems(l.slots)) |s| {
                    if (Slots.isSub(s) and f.places.holds(f.places.pathPlace(Slots.pathOf(s))).closure) break true;
                    if (s & (Slots.sub_bit | Slots.not_bit) == 0 and f.places.kind(f.places.pathPlace(.from(s))) == .closure) try fs.append(gpa, s);
                } else false;
                if (whole) {
                    try out.append(gpa, li);
                    continue;
                }
                if (fs.items.len == 0) continue;
                var n = l;
                n.slots = try f.slots.setOf(gpa, f.account, f.places, fs.items);
                try out.append(gpa, try f.leaf(n));
            },
            else => {},
        }
    }
}

fn order(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// An arrival of call `q`'s supply, as leaves (`Relation.arrivalLeaves`' rule, read from outside).
pub fn supplyLeaves(ev: *Relation.Eval, q: u32, a: Contract.Arrival, out: *std.ArrayList(u32)) Error!void {
    const f = ev.f;
    const call = f.calls.items[q];
    switch (a.kind) {
        .param => {
            if (a.j >= call.args.len) return out.append(ev.gpa(), try f.leaf(.{ .kind = .top }));
            var ps: std.ArrayList(Relation.Proj) = .empty;
            defer ps.deinit(ev.gpa());
            try ev.project(call.args[a.j], f.slots.relWords(a.slot), true, 0, 0, &ps);
            for (ps.items) |p| try out.append(ev.gpa(), p.leaf);
        },
        else => try ev.arrivalLeaves(q, call.contract, a, &.{}, out),
    }
}

/// Every leaf call `q`'s callee hands its label `lab`, into `out`.
pub fn supplied(ev: *Relation.Eval, c: LabelChain.Chain, q: u32, lab: Contract.Label, out: *std.ArrayList(u32)) Error!void {
    for (c.contracts.suppliesOf(lab.supplies)) |s| for ((try LabelChain.entriesOf(c, s.res_root)).items.items) |rs| {
        for (rs.arrivals) |a| try supplyLeaves(ev, q, a, out);
    };
}

/// The one parameter function slot `(j, rel)` that value `v` at `words` is
/// by every object its storage comes from (a callee's supply of it, a
/// call's result arriving from it, under any tags), else null (§2.11.3).
pub fn oneParam(ev: *Relation.Eval, v: u32, words: []const u32) Error!?[2]u32 {
    const f = ev.f;
    const gpa = ev.gpa();
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try ev.project(v, words, false, 0, 0, &ps);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    for (ps.items) |p| try stack.append(gpa, p.leaf);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var got: ?[2]u32 = null;
    while (stack.pop()) |li| {
        if ((try seen.getOrPut(gpa, .{li})).found_existing) continue;
        try ev.charge(.inspection, 1);
        const l = f.leafAt(li);
        if (ev.expandable(l)) {
            try ev.expand(li, &stack);
            continue;
        }
        if (l.kind != .ref or f.roots.items[l.root].kind != .param) return null;
        const ss = f.slots.elems(l.slots);
        if (ss.len != 1 or ss[0] & (Slots.sub_bit | Slots.not_bit) != 0 or f.places.kind(f.places.pathPlace(.from(ss[0]))) != .closure) return null;
        const at: [2]u32 = .{ f.roots.items[l.root].a, try f.slots.relOf(gpa, f.account, f.places, .from(ss[0])) };
        if (got) |g| if (g[0] != at[0] or g[1] != at[1]) return null;
        got = at;
    }
    return got;
}

/// `oneParam` of value `v` of frame `f`, read at its walk through the
/// contracts settled then (an earlier group's, an import's, words; a call
/// of a member of the walk's own group has none, so it gives null), as the
/// identity control reads them (§2.11.2, §2.11.3).
pub fn settled(f: *Value.Frame, contracts: *Contract.Table, cx: WalkContext.Context, v: u32) Error!?[2]u32 {
    // The walk's calls read their contracts at the evaluation; here, for
    // this read only, each settled code's.
    var set: std.ArrayList(u32) = .empty;
    defer set.deinit(f.gpa);
    defer for (set.items) |q| {
        f.calls.items[q].contract = Value.none;
    };
    for (f.calls.items, 0..) |*c, q| if (c.contract == Value.none and c.code != Value.none) if (cx.contractOf(cx.ctx, c.code)) |k| {
        c.contract = k;
        try set.append(f.gpa, @intCast(q));
    };
    var ev: Relation.Eval = .{ .f = f, .contracts = contracts, .arena = f.arena, .routed = routedLeaves, .code_sig = .{ .ctx = cx.ctx, .of = cx.codeSig } };
    defer ev.deinit();
    return oneParam(&ev, v, &.{});
}

fn routedLeaves(e: *Relation.Eval, v: u32, words: []const u32, deep: bool, _: u32, out: *std.ArrayList(u32)) Error!void {
    return RouteWalk.paramLeaves(e, v, words, deep, out);
}
