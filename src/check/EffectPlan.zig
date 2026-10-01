//! What the lowering needs of the effect bits
//! (transparent-effects-proposal.md §16.2), read off the graph `Effects.run`
//! solved: per instruction `no`, `yes` or `poly`, per declaration its own
//! arrow's answer and whether it has a second, suspendable body.
//!
//! **A class answers `yes`** when its rung is `suspends`; **`poly`** when a
//! *sensitive* scheme class of the enclosing declaration reaches it — so it
//! suspends exactly when the declaration is used with something that does;
//! and `no` otherwise. A scheme class other than the declaration's own arrow
//! is sensitive when it reaches a class the lowering reads (a call's callee,
//! a function's own arrow, the classes a reference's choice of body is read
//! off) whose rung is below `suspends`. A declaration with a sensitive class
//! has two bodies: a direct one, where `poly` is `no`, and a suspendable one,
//! `<name>$s`, where `poly` is `yes`.
//!
//! **Which body a use takes** is read off the type the use instantiated: the
//! `$s` body when one of its classes suspends, the enclosing body's choice
//! when one is `poly`, the direct body otherwise. That is a superset of the
//! use's copies of the target's sensitive classes, so it is never the direct
//! body where the suspendable one is needed; and a program in which nothing
//! suspends has no class that suspends, so none of its uses takes a `$s`
//! body and none is written (`backend.md` §9).
//!
//! Nothing here reports. Deterministic: everything is indexed by store
//! variable, node, declaration and instruction, all input derived.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const Effects = @import("Effects.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Suspend = Dispatch.Suspend;
const none = Effects.none;

pub const Error = Allocator.Error;

/// What `build` leaves for the dispatch table, gpa-owned.
pub const Result = struct {
    sites: []Dispatch.EffectSite = &.{},
    decls: []Dispatch.EffectDecl = &.{},
};

pub const Input = struct {
    gpa: Allocator,
    scratch: Allocator,
    bir: *const Bir,
    decl_scheme: []const Var.Optional,
    /// Per declaration, its binding group's root (`Groups.root`), or
    /// `Effects.none`: a reference to a member of one's own group has no
    /// copy, and takes the enclosing body's choice.
    unit: []const u32,
};

/// One reference whose choice of body is read off the classes it
/// instantiated: `choice_nodes[start..][0..len]`. `target` is the own
/// declaration it names, or `none` for an imported one, which has two
/// bodies or would not have been recorded.
const Choice = struct { site: u32, target: u32, start: u32, len: u32 };

const Plan = struct {
    e: *Effects,
    in: Input,
    /// Per node: the walk that last reached it.
    seen: []u32,
    walk: u32 = 0,
    /// Per node: the declaration whose sensitive classes reach it, + 1.
    poly: []u32,
    /// Per node: the declaration it is relevant to, + 1.
    relevant: []u32,
    stack: std.ArrayList(u32) = .empty,
    /// Per declaration: its instructions' callee nodes, function nodes and
    /// choices, bucketed once.
    calls: []std.ArrayList([2]u32),
    fns: []std.ArrayList([2]u32),
    /// Per declaration: its `Js.maySuspend` calls and their argument's
    /// node, a class the lowering reads (`backend.md` §4).
    probes: []std.ArrayList([2]u32),
    choices: []std.ArrayList(Choice),
    choice_nodes: std.ArrayList(u32) = .empty,
    /// Per declaration: it has a sensitive class.
    twin: []bool,
    /// Per node: the declaration one of whose `sync` scheme classes reaches
    /// it, + 1 (`taint`).
    tainted: []u32,
};

pub fn build(e: *Effects, in: Input) Error!Result {
    const s = &e.solved;
    const decls = in.bir.decls.len;
    const n = s.nodes();
    const scratch = in.scratch;
    var p: Plan = .{
        .e = e,
        .in = in,
        .seen = try scratch.alloc(u32, n),
        .poly = try scratch.alloc(u32, n),
        .relevant = try scratch.alloc(u32, n),
        .calls = try scratch.alloc(std.ArrayList([2]u32), decls),
        .fns = try scratch.alloc(std.ArrayList([2]u32), decls),
        .probes = try scratch.alloc(std.ArrayList([2]u32), decls),
        .choices = try scratch.alloc(std.ArrayList(Choice), decls),
        .twin = try scratch.alloc(bool, decls),
        .tainted = try scratch.alloc(u32, n),
    };
    @memset(p.tainted, 0);
    @memset(p.seen, 0);
    @memset(p.poly, 0);
    @memset(p.relevant, 0);
    for (p.calls, p.fns, p.probes, p.choices) |*a, *b, *q, *c| {
        a.* = .empty;
        b.* = .empty;
        q.* = .empty;
        c.* = .empty;
    }
    @memset(p.twin, false);
    if (n == 0 or decls == 0) return .{};

    try bucket(&p);
    // Dependencies first, so a reference's target has its sensitive classes
    // before its user asks; a component iterates until nothing changes
    // (sensitivity only grows).
    var at: usize = 0;
    while (at + 1 < s.order_starts.len) : (at += 1) {
        const members = s.order[s.order_starts[at]..s.order_starts[at + 1]];
        var rounds: u32 = 0;
        while (true) : (rounds += 1) {
            var changed = false;
            for (members) |d| {
                if (try sensitivity(&p, d)) changed = true;
            }
            if (!changed or members.len == 1 or rounds > 64) break;
        }
    }
    return answers(&p);
}

/// Declaration `inst` is in, by range: `none` for none.
fn declOf(bir: *const Bir, inst: u32) u32 {
    var lo: usize = 0;
    var hi: usize = bir.decls.len;
    // Declarations' ranges ascend with their index.
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const d = bir.decls[mid];
        if (inst < d.inst_start.int()) {
            hi = mid;
        } else if (inst >= d.inst_end.int()) {
            lo = mid + 1;
        } else return @intCast(mid);
    }
    // Not sorted after all: a linear look.
    for (bir.decls, 0..) |d, i| {
        if (inst >= d.inst_start.int() and inst < d.inst_end.int()) return @intCast(i);
    }
    return none;
}

fn nodeOf(p: *Plan, v: Var) ?u32 {
    return p.e.nodeOf(v);
}

fn level(p: *const Plan, node: u32) Effects.Rung {
    return p.e.solved.level.items[node];
}

/// Every call's callee, every function's arrow and every reference whose
/// target has two bodies, by declaration.
fn bucket(p: *Plan) Error!void {
    const e = p.e;
    const scratch = p.in.scratch;
    const bir = p.in.bir;
    for (e.edges.items, e.sites.items) |edge, site| {
        if (site.call == none) continue;
        const d = declOf(bir, site.call);
        if (d == none) continue;
        const node = nodeOf(p, edge.a) orelse continue;
        try p.calls[d].append(scratch, .{ site.call, node });
    }
    for (e.fns.items) |f| {
        const d = declOf(bir, f.inst);
        if (d == none) continue;
        const node = nodeOf(p, f.v) orelse continue;
        try p.fns[d].append(scratch, .{ f.inst, node });
    }
    for (e.probes.items) |f| {
        const d = declOf(bir, f.inst);
        if (d == none) continue;
        const node = nodeOf(p, f.v) orelse continue;
        try p.probes[d].append(scratch, .{ f.inst, node });
    }
    // Imported uses of a declaration with two bodies: every class of the
    // type the use read.
    for (e.uses.items) |u| {
        const d = declOf(bir, u.site);
        if (d == none) continue;
        const start: u32 = @intCast(p.choice_nodes.items.len);
        try typeNodes(p, u.v);
        try p.choices[d].append(scratch, .{ .site = u.site, .target = none, .start = start, .len = @as(u32, @intCast(p.choice_nodes.items.len)) - start });
    }
    // Own references: the copies a record made. Whether the target has two
    // bodies is known only once it is solved, so the choice keeps the
    // record's target and asks then.
    for (e.records.items) |r| {
        if (r.owner == Effects.no_owner or r.owner >= bir.decls.len or r.site == none) continue;
        const target = schemeDecl(e, r.scheme) orelse continue;
        const start: u32 = @intCast(p.choice_nodes.items.len);
        for (e.pairs.items[r.start..][0..r.len]) |pair| {
            const node = nodeOf(p, pair.b) orelse continue;
            try p.choice_nodes.append(scratch, node);
        }
        try p.choices[r.owner].append(scratch, .{ .site = r.site, .target = target, .start = start, .len = @as(u32, @intCast(p.choice_nodes.items.len)) - start });
    }
}

fn schemeDecl(e: *const Effects, scheme: Var) ?u32 {
    const pairs = e.scheme_decl;
    const key = e.store.find(scheme).int();
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = pairs[mid][0];
        if (at < key) lo = mid + 1 else if (at > key) hi = mid else return pairs[mid][1];
    }
    return null;
}

/// Every class of type `v`, appended to `choice_nodes`.
fn typeNodes(p: *Plan, v: Var) Error!void {
    const e = p.e;
    const store = e.store;
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(p.in.scratch);
    const mark = store.nextMark();
    try stack.append(p.in.scratch, v);
    while (stack.pop()) |next| {
        const r = store.find(next);
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        switch (store.content(r)) {
            .flex, .rigid => |flags| {
                const set = Walk.constraints(flags);
                for (0..set.count(store)) |i| try stack.append(p.in.scratch, set.at(store, @intCast(i)).fn_var);
                continue;
            },
            else => {},
        }
        if (e.carries(r)) if (nodeOf(p, r)) |node| try p.choice_nodes.append(p.in.scratch, node);
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1) try stack.append(p.in.scratch, c.v);
    }
}

/// The root class of `d`, when its scheme's root carries one.
fn rootOf(p: *Plan, d: u32) ?u32 {
    const scheme = p.in.decl_scheme[d].unwrap() orelse return null;
    const r, _ = p.e.store.resolved(scheme);
    if (!p.e.carries(r)) return null;
    return nodeOf(p, r);
}

fn isTwinTarget(p: *const Plan, c: Choice) bool {
    if (c.target == none) return true;
    return p.twin[c.target];
}

/// The nodes the lowering reads in `d`'s body, tagged `d + 1`.
fn markRelevant(p: *Plan, d: u32, root: ?u32) void {
    const tag = d + 1;
    for (p.calls[d].items) |c| p.relevant[c[1]] = tag;
    for (p.fns[d].items) |f| p.relevant[f[1]] = tag;
    for (p.probes[d].items) |f| p.relevant[f[1]] = tag;
    if (root) |r| p.relevant[r] = tag;
    for (p.choices[d].items) |c| {
        if (!isTwinTarget(p, c)) continue;
        for (p.choice_nodes.items[c.start..][0..c.len]) |node| p.relevant[node] = tag;
    }
}

/// Mark `d`'s relevant nodes, walk from each non-root scheme class below
/// `suspends`, and record which are sensitive. True when that changed.
fn sensitivity(p: *Plan, d: u32) Error!bool {
    const e = p.e;
    const s = &e.solved;
    const bir = p.in.bir;
    const decl = bir.decls[d];
    if (decl.kind != .value or decl.body == .none) return false;
    const classes = s.classesOf(d);
    if (classes.len == 0) return false;
    const root = rootOf(p, d);
    const tag = d + 1;
    markRelevant(p, d, root);
    var changed = false;
    var any = false;
    const summary = s.summaries[d];
    for (0..classes.len) |i| {
        const c = &s.classes.items[summary.start + i];
        const node = s.find(c.node);
        if (root != null and node == root.?) continue;
        if (level(p, node) == .suspends) continue;
        // A `sync` class never suspends at any use — the check refuses the
        // use that would — so reading it needs no second body.
        if (c.sync) continue;
        const reaches = try reach(p, node, tag);
        if (reaches and !c.sensitive) {
            c.sensitive = true;
            changed = true;
        }
        any = any or c.sensitive;
    }
    if (any != p.twin[d]) {
        p.twin[d] = any;
        changed = true;
    }
    return changed;
}

/// Walk forward from `start`; true when the walk meets a node relevant to
/// the declaration tagged `tag` that does not suspend. Every node met is
/// marked `poly` for it when the walk succeeds.
fn reach(p: *Plan, start: u32, tag: u32) Error!bool {
    const s = &p.e.solved;
    p.walk += 1;
    const w = p.walk;
    p.stack.clearRetainingCapacity();
    try p.stack.append(p.in.scratch, start);
    p.seen[start] = w;
    var met = false;
    var reached: std.ArrayList(u32) = .empty;
    defer reached.deinit(p.in.scratch);
    while (p.stack.pop()) |x| {
        try reached.append(p.in.scratch, x);
        if (p.relevant[x] == tag and level(p, x) != .suspends) met = true;
        var at = s.head.items[x];
        while (at != none) : (at = s.next.items[at]) {
            const y = s.find(s.to.items[at]);
            if (p.seen[y] == w) continue;
            p.seen[y] = w;
            try p.stack.append(p.in.scratch, y);
        }
    }
    if (met) for (reached.items) |x| {
        p.poly[x] = tag;
    };
    return met;
}

fn answer(p: *const Plan, node: u32, tag: u32) Suspend {
    if (level(p, node) == .suspends) return .yes;
    if (p.poly[node] == tag) return .poly;
    return .no;
}

fn answers(p: *Plan) Error!Result {
    const gpa = p.in.gpa;
    const bir = p.in.bir;
    var sites: std.ArrayList(Dispatch.EffectSite) = .empty;
    errdefer sites.deinit(gpa);
    const decls = try gpa.alloc(Dispatch.EffectDecl, bir.decls.len);
    errdefer gpa.free(decls);
    @memset(decls, .{});
    var any_decl = false;
    // `poly` is per walk's declaration: recompute each declaration's set now
    // that every sensitivity is final.
    for (0..bir.decls.len) |di| {
        const d: u32 = @intCast(di);
        const decl = bir.decls[d];
        if (decl.kind != .value or decl.body == .none) continue;
        const tag = d + 1;
        try sensitivityFinal(p, d);
        try taint(p, d);
        for (p.calls[d].items) |c| {
            const a = answer(p, c[1], tag);
            // "May be impure": already, or once the declaration is used with
            // something that is — a `poly` callee, or one a `sync` class
            // reaches, which is never `poly` because it cannot suspend.
            const impure = level(p, c[1]) != .pure or a != .no or p.tainted[c[1]] == tag;
            if (a != .no or impure) try sites.append(gpa, .{ .inst = @enumFromInt(c[0]), .own = a, .impure = impure });
        }
        for (p.fns[d].items) |f| {
            const a = answer(p, f[1], tag);
            if (a != .no) try sites.append(gpa, .{ .inst = @enumFromInt(f[0]), .own = a });
        }
        // A `Js.maySuspend` call's value is its argument's answer, carried
        // as the call's choice of body (no reference reads `body` on a
        // `call`): `true` in a body that takes the answer as yes.
        for (p.probes[d].items) |f| {
            const a = answer(p, f[1], tag);
            if (a != .no) try sites.append(gpa, .{ .inst = @enumFromInt(f[0]), .body = a });
        }
        for (p.choices[d].items) |c| {
            if (!isTwinTarget(p, c)) continue;
            var a: Suspend = .no;
            for (p.choice_nodes.items[c.start..][0..c.len]) |node| {
                switch (answer(p, node, tag)) {
                    .yes => {
                        a = .yes;
                        break;
                    },
                    .poly => a = .poly,
                    .no => {},
                }
            }
            if (a != .no) try sites.append(gpa, .{ .inst = @enumFromInt(c.site), .body = a });
        }
        // A reference to a member of one's own binding group has no copy:
        // it follows the enclosing body when the target has two.
        const unit = if (d < p.in.unit.len) p.in.unit[d] else none;
        if (unit != none) {
            const tags = bir.insts.items(.tag);
            const datas = bir.insts.items(.data);
            for (decl.inst_start.int()..decl.inst_end.int()) |i| {
                if (tags[i] != .top) continue;
                const target = datas[i].lhs;
                if (target >= bir.decls.len or !p.twin[target]) continue;
                const tu = if (target < p.in.unit.len) p.in.unit[target] else none;
                if (tu != unit) continue;
                try sites.append(gpa, .{ .inst = @enumFromInt(i), .body = .poly });
            }
        }
        var own: Suspend = .no;
        if (rootOf(p, d)) |r| own = answer(p, r, tag);
        decls[d] = .{ .own = own, .twin = p.twin[d] };
        if (own != .no or p.twin[d]) any_decl = true;
    }
    // One row per instruction: a call's own answer and a method call's
    // choice of body land on the same instruction.
    std.mem.sort(Dispatch.EffectSite, sites.items, {}, struct {
        fn lessThan(_: void, a: Dispatch.EffectSite, b: Dispatch.EffectSite) bool {
            if (a.inst != b.inst) return a.inst.int() < b.inst.int();
            return @intFromEnum(a.own) < @intFromEnum(b.own) or (a.own == b.own and @intFromEnum(a.body) < @intFromEnum(b.body));
        }
    }.lessThan);
    var out: std.ArrayList(Dispatch.EffectSite) = .empty;
    errdefer out.deinit(gpa);
    for (sites.items) |site| {
        if (out.items.len != 0 and out.items[out.items.len - 1].inst == site.inst) {
            const last = &out.items[out.items.len - 1];
            last.own = join(last.own, site.own);
            last.body = join(last.body, site.body);
            last.impure = last.impure or site.impure;
            continue;
        }
        try out.append(gpa, site);
    }
    sites.deinit(gpa);
    if (!any_decl) {
        gpa.free(decls);
        return .{ .sites = try out.toOwnedSlice(gpa) };
    }
    return .{ .sites = try out.toOwnedSlice(gpa), .decls = decls };
}

fn join(a: Suspend, b: Suspend) Suspend {
    if (a == .yes or b == .yes) return .yes;
    if (a == .poly or b == .poly) return .poly;
    return .no;
}

/// The `poly` marks of `d`'s sensitive classes, walked again with every
/// sensitivity final (a walk marks only when it succeeds, and a
/// component's later round may have made more classes relevant).
fn sensitivityFinal(p: *Plan, d: u32) Error!void {
    const s = &p.e.solved;
    const classes = s.classesOf(d);
    const tag = d + 1;
    // Relevance re-marked: another declaration's walk may have overwritten a
    // shared node's tag.
    markRelevant(p, d, rootOf(p, d));
    if (classes.len == 0) return;
    const summary = s.summaries[d];
    for (0..classes.len) |i| {
        const c = s.classes.items[summary.start + i];
        if (!c.sensitive) continue;
        _ = try reach(p, s.find(c.node), tag);
    }
}

/// Mark, `d + 1`, every node a pure `sync` scheme class of `d` reaches. Such
/// a class cannot suspend, so it is never sensitive and a call it reaches is
/// never `poly`; but it may still be impure at a use, and so may that call
/// — which the release optimiser must know (`backend.md` §9 item 1). Only
/// `sync` classes are walked: any other pure class that reaches a call has
/// made it `poly` already. They are few, so this is cheap.
fn taint(p: *Plan, d: u32) Error!void {
    const s = &p.e.solved;
    const classes = s.classesOf(d);
    if (classes.len == 0) return;
    const tag = d + 1;
    const root = rootOf(p, d);
    const summary = s.summaries[d];
    for (0..classes.len) |i| {
        const c = s.classes.items[summary.start + i];
        if (!c.sync) continue;
        const start = s.find(c.node);
        if (root != null and start == root.?) continue;
        if (level(p, start) != .pure or p.tainted[start] == tag) continue;
        p.stack.clearRetainingCapacity();
        try p.stack.append(p.in.scratch, start);
        p.tainted[start] = tag;
        while (p.stack.pop()) |x| {
            var at = s.head.items[x];
            while (at != none) : (at = s.next.items[at]) {
                const y = s.find(s.to.items[at]);
                if (p.tainted[y] == tag) continue;
                p.tainted[y] = tag;
                try p.stack.append(p.in.scratch, y);
            }
        }
    }
}
