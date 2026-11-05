//! L8: a label's answers read (`docs/design/ownership-v2.md` §2.11.3, *a
//! traversal's supply*). Where the distinct check would say `no`, an answer
//! is read as what its run was handed, under the occurrence that says the
//! function answers only that and objects it makes (`AnsOcc.occ`); a
//! traversal's are one family, read apart. `AnswerCall` decides the occurrence
//! at a caller.
//!
//! Obligations kept here: O14's rule for a `within` over answers (§2.14).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Entries = @import("Entries.zig");
const Taken = @import("Taken.zig");
const AnsOcc = @import("AnsOcc.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Proj = Relation.Proj;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// What leaf `li`, an answer, reads as.
const Read = struct { occ: u64, apart: bool, fn_j: u32, fn_slot: Slots.Rel };

/// The one reading of a check's answers: an answer is read once, and all the
/// traversal answers it reads are of one function, whose occurrence asks the
/// family in one selection at the caller.
pub const Reader = struct {
    seen: Ids.FixedDict(1) = .{},
    each: ?[2]u32 = null,
    failed: bool = false,

    pub fn deinit(r: *Reader, g: std.mem.Allocator) void {
        r.seen.deinit(g);
    }

    /// Read leaf `x` into `st`, when it is an answer that can be read.
    pub fn take(r: *Reader, e: *Eval, st: *Entries.Rounds, occs: *Entries.Occs, x: u32, block: u32, par: [3]u32) Error!bool {
        const g = e.gpa();
        var parts: std.ArrayList(Proj) = .empty;
        defer parts.deinit(g);
        const got = (try of(e, x, &parts)) orelse return false;
        if ((try r.seen.getOrPut(g, .{x})).found_existing) r.failed = true;
        if (got.apart) {
            const fnk: [2]u32 = .{ got.fn_j, got.fn_slot };
            if (r.each) |w| {
                if (!std.mem.eql(u32, &w, &fnk)) r.failed = true;
            }
            r.each = fnk;
        }
        try occs.add(g, got.occ);
        for (parts.items) |q| {
            e.route_count += 1;
            try st.add(g, .{ .leaf = q.leaf, .route = 0x4000_0000 | e.route_count, .occ = if (got.apart) Contract.apart_bit else 0, .block = block, .read = true }, par);
        }
        return true;
    }
};

/// Whether a code's result is read: a code of a recursive group with no
/// label and no `taken` row has no answer of its own, and reading what it
/// calls round after round is the price of nothing it can hand on (§2.11.3).
pub fn reads(e: *Eval, labels: usize, recursive: bool) bool {
    if (labels != 0 or !recursive) return true;
    for (e.f.calls.items) |c| if (c.contract != none and e.contracts.head(c.contract).flags.taken) return true;
    return false;
}

/// Whether a code of group `ids` calls one of them by name.
pub fn groupRecurses(evals: anytype, ids: []const u32) bool {
    for (evals) |ev| for (ev.ev.f.calls.items) |c| {
        if (!c.virtual and c.code != none and std.mem.indexOfScalar(u32, ids, c.code) != null) return true;
    };
    return false;
}

/// Whether all call `call`'s result can hold is what its functions make, run
/// by run: its callee's reading asks only that. Such a result meets nothing
/// that existed, so the check stops there: expanded, a tuple of `n` answers
/// costs `n`, doubling with the depth of a wrapper (`w f = ( v f, v f )`).
pub fn allMade(e: *Eval, call: u32) Error!bool {
    const c = e.contractOf(call) orelse return false;
    const h = e.contracts.head(c);
    if (!h.res_cond.no or h.res_read.no) return false;
    const rc = try e.contracts.resCond(e.arena, c, true);
    if (rc.sel.len == 0) return false;
    for (rc.sel) |o| if (!AnsOcc.is(o) or AnsOcc.arg(o) != Contract.fresh_arg) return false;
    var arrs: std.ArrayList(Contract.Arrival) = .empty;
    defer arrs.deinit(e.gpa());
    try Forest.arrivalsOf(&e.contracts.trees, e.gpa(), e.places(), h.res_root, &arrs);
    for (arrs.items) |a| if (a.kind != .cb and a.kind != .fresh) return false;
    return true;
}

/// Leaf `li` as an answer that can be read: its occurrence, and what its run
/// was handed, deep, into `parts`.
fn of(e: *Eval, li: u32, parts: *std.ArrayList(Proj)) Error!?Read {
    const l = e.f.leafAt(li);
    if (l.kind == .answer) return pass(e, l.atom, l.tags, parts);
    if (l.kind != .ref or e.f.roots.items[l.root].kind != .cb) return null;
    const ci = e.f.roots.items[l.root].a;
    const cb = e.f.cbs.items[ci];
    if (cb.inst == none) return null;
    var arg: u32 = none;
    var k: u32 = Contract.fresh_arg;
    for (cb.args, 0..) |a, i| if (e.f.val(a).kind != .scalar) {
        if (arg != none) return null;
        arg = a;
        k = @intCast(i);
    };
    if (arg != none) try e.project(arg, &.{}, true, l.tags, 0, parts);
    return .{ .occ = AnsOcc.occ(cb.j, cb.slot, k), .apart = arg != none and Taken.containerOf(e.f, e.contracts, arg) != none, .fn_j = cb.j, .fn_slot = cb.slot };
}

/// The answer of label `fl` the frame passes on: at every call that passes
/// it, one object supply, a traversal's or run once, or none.
fn pass(e: *Eval, fl: u32, tags: u32, parts: *std.ArrayList(Proj)) Error!?Read {
    const cb = e.f.cbs.items[fl];
    var k: ?u32 = null;
    var apart = true;
    var any = false;
    var i: usize = 0;
    const keys = e.label_map.keys.items;
    while (i + 1 < keys.len) : (i += 2) {
        if (e.label_map.values.items[i / 2] != fl) continue;
        any = true;
        const call = keys[i];
        const cl = e.f.calls.items[call];
        const lab = e.contracts.labelsOf(e.contracts.head(cl.contract).labels)[keys[i + 1]];
        var hit: ?Contract.Supply = null;
        for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.res_root != 0) {
            if (hit != null) return null;
            hit = su;
        };
        const su = hit orelse {
            if (k != null and k.? != Contract.fresh_arg) return null;
            k = Contract.fresh_arg;
            apart = false;
            continue;
        };
        if (k != null and k.? != su.k) return null;
        k = su.k;
        if (!su.each and lab.calls != .once) return null;
        apart = apart and su.each;
        var es: Forest.Entries = .{};
        defer es.deinit(e.gpa());
        try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
        for (es.items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
            .fresh => {},
            .param => {
                if (a.j >= cl.args.len) return null;
                try e.project(cl.args[a.j], e.f.slots.relWords(a.slot), true, tags, 0, parts);
            },
            else => return null,
        };
    }
    if (!any) return null;
    return .{ .occ = AnsOcc.occ(cb.j, cb.slot, k.?), .apart = apart, .fn_j = cb.j, .fn_slot = cb.slot };
}
