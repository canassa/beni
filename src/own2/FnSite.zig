//! L8: a function value that is one closure of the frame by every arrival
//! (`docs/design/ownership-v2.md` §2.11.3, *a function value goes where a
//! value goes*; #2395). A callee that hands a closure back (`ident f = f`,
//! a field of a record it returns) answers that closure: the frame follows
//! the value it gets back to the closure's code, as it follows a parameter's
//! function slot (`FnRun.oneParam`), and a closure among the arrivals of a
//! callee's result that escapes or is returned has escaped there
//! (`throughCalls`, read by `Closures`).
//!
//! Obligations kept here: O1 (a value this cannot name stays unknown code).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Subtree = @import("Subtree.zig");

const Error = Relation.Error;

/// The one closure site that value `v` at `words` is by every object its
/// storage comes from through callees' results (their arrivals, under any
/// tags), else null. A supply is a label's runs and is not read through.
pub fn one(ev: *Relation.Eval, v: u32, words: []const u32) Error!?u32 {
    const gpa = ev.gpa();
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try ev.project(v, words, false, 0, 0, &ps);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    for (ps.items) |p| try expanded(ev, p.leaf, &ls);
    var got: ?u32 = null;
    for (ls.items) |li| {
        const l = ev.f.leafAt(li);
        if (l.kind != .site) return null;
        if (got) |g| if (g != l.atom) return null;
        got = l.atom;
    }
    return got;
}

/// The frame's closure sites leaf `leaf` reaches through the callees'
/// results it is (their arrivals, expanded), into `out`; nothing when it is
/// no callee's result.
pub fn throughCalls(ev: *Relation.Eval, leaf: u32, out: *std.ArrayList(u32)) Error!void {
    const l = ev.f.leafAt(leaf);
    if (!ev.expandable(l) or ev.f.roots.items[l.root].kind != .call) return;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(ev.gpa());
    try expanded(ev, leaf, &ls);
    for (ls.items) |li| if (ev.f.leafAt(li).kind == .site) try out.append(ev.gpa(), li);
}

/// Whether call `q`'s result holds the closure made at instruction `site`, through callees' results: hands it back.
pub fn handsBack(ev: *Relation.Eval, q: u32, site: u32) Error!bool {
    const r = ev.f.roots.items[ev.f.calls.items[q].root];
    const all = try ev.f.leaf(.{ .kind = .ref, .root = ev.f.calls.items[q].root, .pos = r.pos, .slots = try Subtree.below(ev.f.slots, ev.gpa(), ev.account(), ev.places(), r.path) });
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(ev.gpa());
    try throughCalls(ev, all, &ls);
    for (ls.items) |l| if (ev.f.leafAt(l).atom == site) return true;
    return false;
}

/// Leaf `leaf` with every callee's result it comes through expanded: the
/// leaves that are none, into `out`.
fn expanded(ev: *Relation.Eval, leaf: u32, out: *std.ArrayList(u32)) Error!void {
    const gpa = ev.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, leaf);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    while (stack.pop()) |li| {
        if ((try seen.getOrPut(gpa, .{li})).found_existing) continue;
        try ev.charge(.inspection, 1);
        const l = ev.f.leafAt(li);
        if (ev.expandable(l) and ev.f.roots.items[l.root].kind == .call) try ev.expand(li, &stack) else try out.append(gpa, li);
    }
}

/// The value of the frame's one closure made at instruction `site`, else
/// null: a worded row's, which writes nothing in place (§2.11.5), or a site
/// made more than once, is not followed. `cx` is the walk's context.
pub fn closureAt(contracts: *const Contract.Table, cx: anytype, closures: anytype, site: u32) ?u32 {
    var got: ?u32 = null;
    for (closures) |c| if (c.inst == site) {
        if (got != null) return null;
        if (cx.contractOf(cx.ctx, c.code)) |k| if (contracts.head(k).flags.words) return null;
        got = c.value;
    };
    return got;
}

/// The closure sites the frame's `escapes` and its result's leaves `result` reach through callees' results, as escapes
/// into `out`: an escape's at its point, a returned one's at the call that hands it back.
pub fn escapedSites(ev: *Relation.Eval, escapes: anytype, result: []const u32, out: anytype) Error!void {
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(ev.gpa());
    for (escapes) |es| {
        ls.clearRetainingCapacity();
        try throughCalls(ev, es.leaf, &ls);
        for (ls.items) |l| try out.append(ev.gpa(), .{ .leaf = l, .point = es.point, .call = es.call });
    }
    for (result) |l| {
        ls.clearRetainingCapacity();
        try throughCalls(ev, l, &ls);
        const q = if (ls.items.len != 0) ev.f.roots.items[ev.f.leafAt(l).root].a else continue;
        for (ls.items) |s| try out.append(ev.gpa(), .{ .leaf = s, .point = ev.f.calls.items[q].point, .call = q });
    }
}
