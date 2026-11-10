//! L8: a write onto a caller's parameter stops at the parameter
//! (`docs/design/ownership-v2.md` §2.11.2, #1714). A callee's writes are a
//! tree a parameter (§2.10, *Effects as trees*); when the argument is one of
//! the caller's parameters at an exact slot `c`, the tree is not written out
//! path by path. Its targets are read off the tree: a subtree that writes
//! every object below its slot is one target, the deep projection there
//! (the objects of `↓s`, §2.3.1); elsewhere each written slot is its own.
//! The targets are grouped into demands by state: the first step from `c`,
//! to one place, into one subtree, of one kind. The caller's own writes are
//! the callee's tree grafted at `c`.
//!
//! Obligations kept here: none of §2.14's directly (a demand's targets are
//! every object the callee's writes there reach, as the written-out writes'
//! projections are, and the judgement reads them all).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const SlotWords = @import("SlotWords.zig");
const Subtree = @import("Subtree.zig");
const Trees = @import("Trees.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Proj = Relation.Proj;
const PlaceId = Ids.PlaceId;
const Node = Trees.Node;
const none: u32 = Ids.none_int;

/// The caller's parameter `j`'s write tree `node` at its slot `slot`.
pub const Graft = struct { j: u32 = none, slot: Slots.Rel = Slots.root, node: Node = 0 };

/// One demand: the effect its text names (the least route of its state,
/// relative to the argument) and its targets.
/// `also`: the other routes it covers, each named by its least route (the
/// line names every one, §2.11.2).
pub const Group = struct { x: Contract.Effect, targets: std.ArrayList(Proj) = .empty, also: std.ArrayList(Slots.Rel) = .empty };

/// Call `call`'s instruction a write of argument `j` names as its base.
pub fn argInst(call: Value.Call, j: u32) u32 {
    return if (j < call.arg_insts.len and call.arg_insts[j] != none) call.arg_insts[j] else call.inst;
}

const Walk = struct {
    ev: *Relation.Eval,
    arg: u32,
    j: u32,
    groups: *std.ArrayList(Group),
    /// A state's key → its group: at a slot the frame names, `(position,
    /// none, 0, kind)`; past one, `(position, place, subtree, kind)` of the
    /// first step that leaves the slots the frame names.
    by_key: Ids.FixedDict(4) = .{},
    /// `(node, place)` → whether the subtree writes every object below it.
    full: Ids.FixedDict(2) = .{},
    /// A place on a cycle met below a slot other than the parameter's root:
    /// its canonical names may fold (§2.1), so the tree is written out.
    root: bool,
    cyclic: bool = false,
    words: std.ArrayList(u32) = .empty,
    ks: std.ArrayList([2]u32) = .empty,

    fn t(w: *Walk) *const Trees.Table {
        return &w.ev.contracts.trees;
    }

    /// Whether `n` at place `p` writes every object slot at and below it,
    /// shallow: its own slot when it is an object, and every step of the
    /// place to a slot that is or holds one. A place on a cycle is never.
    fn fullAt(w: *Walk, n: Node, p: PlaceId) Error!bool {
        const pl = w.ev.places();
        if (n == 0 or w.t().open(n).len != 0 or pl.cyclic(p)) return false;
        if (w.full.get(.{ n, p.int() })) |x| return x == 1;
        try w.ev.charge(.inspection, 1);
        var ok = Place.Kind.own(pl.kind(p)).isEmpty() or w.t().here(n).len != 0;
        if (ok) {
            const st = pl.steps(p);
            for (st.steps, st.children) |s, c| {
                if (pl.holds(c).isEmpty() and Place.Kind.own(pl.kind(c)).isEmpty()) continue;
                const k = w.t().kidAt(n, s.word()) orelse {
                    ok = false;
                    break;
                };
                if (!try w.fullAt(k, c)) {
                    ok = false;
                    break;
                }
            }
        }
        try w.full.put(w.ev.gpa(), .{ n, p.int() }, @intFromBool(ok));
        return ok;
    }

    /// The group of `key`, made when missing, its text the least route
    /// below `words` that node `n` writes.
    fn groupOf(w: *Walk, key: [4]u32, n: Node) Error!*Group {
        const g = w.ev.gpa();
        const got = try w.by_key.getOrPut(g, key);
        const slot = try w.leastRel(n);
        if (got.found_existing) {
            const gr = &w.groups.items[got.value_ptr.*];
            try gr.also.append(g, slot);
            return gr;
        }
        got.value_ptr.* = @intCast(w.groups.items.len);
        try w.groups.append(g, .{ .x = .{ .j = w.j, .slot = slot, .deep = key[3] == 1 } });
        return &w.groups.items[w.groups.items.len - 1];
    }

    /// The least route below `words` that node `n` writes.
    fn leastRel(w: *Walk, n: Node) Error!Slots.Rel {
        const g = w.ev.gpa();
        const top = w.words.items.len;
        defer w.words.shrinkRetainingCapacity(top);
        var m = n;
        while (w.t().here(m).len == 0 and w.t().open(m).len == 0) {
            try Forest.sortedKids(w.t(), g, w.ev.places(), m, &w.ks);
            if (w.ks.items.len == 0) break;
            try w.words.append(g, w.ks.items[0][0]);
            m = w.ks.items[0][1];
        }
        return w.ev.f.slots.relOfWords(g, w.ev.account(), w.ev.places(), w.words.items);
    }

    fn target(w: *Walk, state: [3]u32, kind: u32, n: Node, deep: bool, path: Ids.PathId) Error!void {
        const gr = try w.groupOf(.{ state[0], state[1], state[2], kind }, n);
        const g = w.ev.gpa();
        const f = w.ev.f;
        // The parameter's objects at the walk's path (its projection, never replayed).
        if (deep or w.words.items.len != 0) {
            const set = if (deep) try Subtree.below(f.slots, g, f.account, f.places, path) else try f.slots.canon(g, f.account, f.places, path);
            if (set != Slots.empty) try gr.targets.append(g, .{ .leaf = try f.leaf(.{ .kind = .ref, .root = f.val(w.arg).root, .pos = f.val(w.arg).pos, .slots = set }) });
            return;
        }
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(g);
        try w.ev.storageOf(w.arg, 0, &ls);
        for (ls.items) |l| try gr.targets.append(g, .{ .leaf = l });
    }

    /// Node `n` at place `p`, `words` below the argument. `at`: the frame's
    /// position there while the frame names the slot (`none` past it);
    /// `state` the state's key.
    fn node(w: *Walk, n: Node, p: PlaceId, path: Ids.PathId, at: u32, state: [3]u32) Error!void {
        const pl = w.ev.places();
        const f = w.ev.f;
        if (pl.cyclic(p) and !w.root) w.cyclic = true;
        if (w.cyclic) return;
        if (w.t().open(n).len != 0) return w.target(state, 1, n, true, path);
        // A slot the frame names is read step by step, past one whole.
        // A record's own storage is a demand of its own kind (2), judged by field (§2.8): never one with a list's below it.
        if (at == none and !(w.ev.f.records and pl.kind(p) == .record) and try w.fullAt(n, p)) return w.target(state, 0, n, true, path);
        if (w.t().here(n).len != 0) try w.target(state, if (w.ev.f.records and pl.kind(p) == .record) 2 else 0, n, false, path);
        var ks: std.ArrayList([2]u32) = .empty;
        defer ks.deinit(w.ev.gpa());
        try Forest.sortedKids(w.t(), w.ev.gpa(), pl, n, &ks);
        for (ks.items) |k| {
            const c = pl.child(p, Place.Step.fromWord(k[0])) orelse {
                w.cyclic = true;
                return;
            };
            try w.words.append(w.ev.gpa(), k[0]);
            defer _ = w.words.pop();
            try w.ev.charge(.inspection, 1);
            // A step to a slot the frame names keeps the route apart.
            const next = if (at == none) none else f.pos_index.get(.{ at, @backingInt(Value.PKind.plain), k[0], 0 }) orelse none;
            const st: [3]u32 = if (next != none) .{ next, none, 0 } else if (at != none) .{ at, c.int(), k[1] } else state;
            try w.node(k[1], c, (try pl.extend(w.ev.gpa(), f.gc(), path, Place.Step.fromWord(k[0]))).?, next, st);
        }
    }
};

/// A literal's walk (§2.11.2, *A literal argument*): each `(node, value)`
/// once, a demand a written slot of it, named by the first route.
const Lit = struct {
    ev: *Relation.Eval,
    j: u32,
    groups: *std.ArrayList(Group),
    /// `(node, value)` → its first visit in `visits`: the groups it made
    /// and the length of its route.
    seen: Ids.FixedDict(2) = .{},
    visits: std.ArrayList([3]u32) = .empty,
    words: std.ArrayList(u32) = .empty,

    /// A second route to a visited `(node, value)`: each group its first
    /// visit made covers this route too, named by its own steps below.
    fn again(l: *Lit, visit: [3]u32) Error!void {
        const g = l.ev.gpa();
        const sl = l.ev.f.slots;
        const top = l.words.items.len;
        defer l.words.shrinkRetainingCapacity(top);
        for (l.groups.items[visit[0]..visit[1]]) |*gr| {
            try l.ev.charge(.inspection, 1);
            l.words.shrinkRetainingCapacity(top);
            try l.words.appendSlice(g, sl.relWords(gr.x.slot)[visit[2]..]);
            try gr.also.append(g, try sl.relOfWords(g, l.ev.account(), l.ev.places(), l.words.items));
        }
    }

    fn add(l: *Lit, deep: bool) Error!*Group {
        const slot = try l.ev.f.slots.relOfWords(l.ev.gpa(), l.ev.account(), l.ev.places(), l.words.items);
        try l.groups.append(l.ev.gpa(), .{ .x = .{ .j = l.j, .slot = slot, .deep = deep } });
        return &l.groups.items[l.groups.items.len - 1];
    }

    /// Node `n` at value `v`: a tuple, a constructor or a record by its
    /// kids; any other value by each written slot projected on it.
    fn at(l: *Lit, n: Node, v: u32) Error!void {
        const ev = l.ev;
        const g = ev.gpa();
        const f = ev.f;
        const got = try l.seen.getOrPut(g, .{ n, v });
        if (got.found_existing) return l.again(l.visits.items[got.value_ptr.*]);
        const vi: u32 = @intCast(l.visits.items.len);
        got.value_ptr.* = vi;
        try l.visits.append(g, .{ @intCast(l.groups.items.len), 0, @intCast(l.words.items.len) });
        defer l.visits.items[vi][1] = @intCast(l.groups.items.len);
        try ev.charge(.inspection, 1);
        const x = f.val(v);
        const t = &ev.contracts.trees;
        if (x.kind != .built or !(x.form == .tuple or x.form == .ctor or x.form == .record)) {
            var es: Forest.Entries = .{};
            defer es.deinit(g);
            try es.of(t, g, ev.places(), n, &.{});
            for (es.items.items) |y| {
                const top = l.words.items.len;
                defer l.words.shrinkRetainingCapacity(top);
                try l.words.appendSlice(g, es.wordsOf(y));
                const gr = try l.add(y.open);
                var ps: std.ArrayList(Proj) = .empty;
                defer ps.deinit(g);
                if (y.open or es.wordsOf(y).len != 0) try ev.project(v, es.wordsOf(y), y.open, 0, 0, &ps) else {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(g);
                    try ev.storageOf(v, 0, &ls);
                    for (ls.items) |li| try ps.append(g, .{ .leaf = li });
                }
                for (ps.items) |p| try gr.targets.append(g, .{ .leaf = p.leaf });
            }
            return;
        }
        if (t.open(n).len != 0 or t.here(n).len != 0) {
            const gr = try l.add(t.open(n).len != 0);
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(g);
            if (t.open(n).len != 0) try ev.leavesOf(v, 0, &ls) else try ev.storageOf(v, 0, &ls);
            for (ls.items) |li| try gr.targets.append(g, .{ .leaf = li });
        }
        var ks: std.ArrayList([2]u32) = .empty;
        defer ks.deinit(g);
        try Forest.sortedKids(t, g, ev.places(), n, &ks);
        const kids = f.kidsOf(x);
        for (ks.items) |k| {
            try l.words.append(g, k[0]);
            defer _ = l.words.pop();
            const st = Place.Step.fromWord(k[0]);
            switch (st.kind) {
                .index => if (x.form == .tuple and st.payload < kids.len) try l.at(k[1], kids[st.payload]),
                .ctor_arg => if (x.form == .ctor) {
                    const ca = ev.places().ctorArgOf(st);
                    if (ca[0] == x.head and ca[1] < kids.len) try l.at(k[1], kids[ca[1]]);
                },
                .field => if (x.form == .record) for (f.wordsOf(x.extra), 0..) |r, i| if (r == st.payload) try l.at(k[1], kids[i]),
                else => {},
            }
        }
    }
};

/// Call `call`'s write tree `x` on a literal argument (a tuple, a
/// constructor or a record; §2.11.2): each `(node, value)` read once, a
/// demand a written slot there, so a literal that reaches one value by many
/// routes names its objects once. False when the argument is no literal, or
/// the tree takes a step no literal follows exactly.
pub fn literal(ev: *Relation.Eval, call: Value.Call, x: Contract.Effect, groups: *std.ArrayList(Group)) Error!bool {
    if (x.node == 0 or call.virtual or x.j >= call.args.len or x.slot != Slots.root) return false;
    const v = ev.f.val(call.args[x.j]);
    if (v.kind != .built or !(v.form == .tuple or v.form == .ctor or v.form == .record)) return false;
    if (!try exactSteps(ev, x.node)) return false;
    const g = ev.gpa();
    var l: Lit = .{ .ev = ev, .j = x.j, .groups = groups };
    defer inline for (.{ &l.seen, &l.visits, &l.words }) |m| m.deinit(g);
    try l.at(x.node, call.args[x.j]);
    return true;
}

/// A stored selection folded exactly (§2.11.2, *Stored selections fold
/// exactly*): a slot every object slot of whose subtree is asked plain, its
/// own included, is one deep occurrence `s*`, its occurrences below
/// dropped. The test is made on the occurrence tree with the place: a node
/// is full when its own slot is asked plain or is no object, and every step
/// its place takes to a slot that is or holds an object leads to a full kid.
/// A place on a cycle is never full. A full slot with nothing asked below
/// it is kept as it is (it names the same objects).
pub fn fold(ev: *Relation.Eval, c: Contract.Cond) Error!Contract.Cond {
    if (c.no or c.sel.len < 2) return c;
    const g = ev.gpa();
    const f = ev.f;
    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(g);
    // A `fed` occurrence asks no object apart (§2.11.3): it is kept as it is.
    var kept: std.ArrayList(u64) = .empty;
    for (c.sel) |o| if (Contract.isFed(o)) try out.append(g, o) else try kept.append(ev.arena, o);
    const run = kept.items;
    Contract.sortOccs(f.slots, run);
    var i: usize = 0;
    while (i < run.len) {
        const j = Contract.occParam(run[i]);
        var end = i;
        while (end < run.len and Contract.occParam(run[end]) == j) end += 1;
        const place = for (f.roots.items) |r| {
            if (r.kind == .param and r.a == j) break r.place;
        } else null;
        if (place) |p| {
            var fd: Fold = .{ .ev = ev, .out = &out, .j = j };
            _ = try fd.go(run[i..end], 0, p);
        } else try out.appendSlice(g, run[i..end]);
        i = end;
    }
    return Contract.Cond.of(ev.account(), try ev.arena.dupe(u64, out.items));
}

const Fold = struct {
    ev: *Relation.Eval,
    out: *std.ArrayList(u64),
    j: u32,

    fn wordsOf(fd: *Fold, o: u64) []const u32 {
        return fd.ev.f.slots.relWords(Contract.occRel(o));
    }

    /// The occurrences `run` (canonical order, each `depth` steps or more,
    /// sharing their first `depth`) at place `p`: into `out`, folded; true
    /// when the node is full.
    fn go(fd: *Fold, run: []const u64, depth: usize, p: PlaceId) Error!bool {
        const pl = fd.ev.places();
        const g = fd.ev.gpa();
        const start = fd.out.items.len;
        try fd.ev.charge(.inspection, 1);
        var own = false;
        var deep = false;
        var k: usize = 0;
        while (k < run.len and fd.wordsOf(run[k]).len == depth) : (k += 1) {
            try fd.out.append(g, run[k]);
            if (!Contract.isApart(run[k])) {
                own = true;
                deep = deep or Contract.isDeep(run[k]);
            }
        }
        var full = !pl.cyclic(p) and (own or Place.Kind.own(pl.kind(p)).isEmpty());
        var met: usize = 0;
        while (k < run.len) {
            const s = fd.wordsOf(run[k])[depth];
            var e = k;
            while (e < run.len and fd.wordsOf(run[e])[depth] == s) e += 1;
            const c = pl.child(p, Place.Step.fromWord(s));
            // A step the frame's place has no such child at (a callee's row, read at a record
            // that names more) is kept as it is: its occurrences are read by the caller (§2.1).
            const kid = if (c) |cp| try fd.go(run[k..e], depth + 1, cp) else blk: {
                try fd.out.appendSlice(g, run[k..e]);
                break :blk false;
            };
            if (c != null and kid) met += 1 else full = false;
            k = e;
        }
        if (!deep) {
            if (!full) return false;
            const st = pl.steps(p);
            var need: usize = 0;
            for (st.children) |cp| {
                if (!pl.holds(cp).isEmpty() or !Place.Kind.own(pl.kind(cp)).isEmpty()) need += 1;
            }
            if (met < need) return false;
            // A slot asked alone stays as it is: it names the same objects.
            if (met == 0) return true;
        }
        fd.out.shrinkRetainingCapacity(start);
        const ws = fd.wordsOf(run[0])[0..depth];
        try fd.out.append(g, Contract.occDeep(Contract.occ(fd.j, try fd.ev.f.slots.relOfWords(g, fd.ev.account(), pl, ws))));
        return true;
    }
};

/// Whether selection `c`'s plain occurrences are read on call `call`'s
/// arguments as a whole first (`Distinct.instSel`): one of its parameters
/// is asked deep apart and plain on a literal, which the selection then
/// reads part by part, every route of the literal on its own (§2.11.2, *A
/// literal argument*): a literal that reaches one object by two routes
/// names it twice at the plain occurrences already, and then the selection
/// is `no` at once.
pub fn plainsOnLiteral(ev: *Relation.Eval, c: Contract.Cond, call: Value.Call) bool {
    for (c.sel) |o| {
        const j = Contract.occParam(o);
        if (j >= call.args.len or ev.f.val(call.args[j]).kind != .built) continue;
        var plain = false;
        var deep_apart = false;
        for (c.sel) |y| if (Contract.occParam(y) == j) {
            if (!Contract.isApart(y)) plain = true else if (Contract.isDeep(y)) deep_apart = true;
        };
        if (plain and deep_apart) return true;
    }
    return false;
}

/// Whether every step of tree `n` is a plain one a slot names exactly (a
/// field, an index, a constructor's argument).
fn exactSteps(ev: *Relation.Eval, n: Node) Error!bool {
    var ns: std.ArrayList(Node) = .empty;
    defer ns.deinit(ev.gpa());
    try Forest.nodes(&ev.contracts.trees, ev.gpa(), ev.places(), n, &ns);
    for (ns.items) |m| for (ev.contracts.trees.kids(m)) |k| switch (Place.Step.fromWord(k[0]).kind) {
        .field, .index, .ctor_arg => {},
        else => return false,
    };
    return true;
}

/// Where argument `j` of `call` is, when it is a parameter of the frame's at
/// an exact slot: the parameter, the slot's steps (in `ev.arena`) and its
/// place. A slot below a place on a cycle is not one: its canonical name
/// may fold (§2.1).
pub const Base = struct { j: u32, words: []const u32, place: PlaceId, path: Ids.PathId };
pub fn baseOf(ev: *Relation.Eval, call: Value.Call, j: u32) Error!?Base {
    const f = ev.f;
    if (call.virtual or j >= call.args.len) return null;
    const v = f.val(call.args[j]);
    if (v.kind != .ref or v.family != Slots.empty or f.roots.items[v.root].kind != .param) return null;
    const ws = f.slots.relWords(try f.slots.relOf(ev.gpa(), ev.account(), ev.places(), f.pos.items[v.pos].slot));
    var p = f.roots.items[v.root].place;
    for (ws) |s| {
        switch (Place.Step.fromWord(s).kind) {
            .field, .index, .ctor_arg => {},
            else => return null,
        }
        if (ev.places().cyclic(p)) return null;
        p = ev.places().child(p, Place.Step.fromWord(s)) orelse return null;
    }
    return .{ .j = f.roots.items[v.root].a, .words = try ev.arena.dupe(u32, ws), .place = p, .path = f.pos.items[v.pos].slot };
}

/// Call `call`'s write `x` (`x.node` the callee's tree below `x.slot`) as
/// grafted demands into `groups`, when argument `x.j` is a parameter of the
/// caller's at an exact slot; the graft, or `null` when the tree is to be
/// written out (§2.11.2).
pub fn stop(ev: *Relation.Eval, call: Value.Call, x: Contract.Effect, groups: *std.ArrayList(Group)) Error!?Graft {
    if (@import("Mutate.zig").on(.graft_stop_off)) return null;
    const f = ev.f;
    const g = ev.gpa();
    if (x.node == 0) return null;
    const b = (try baseOf(ev, call, x.j)) orelse return null;
    const v = f.val(call.args[x.j]);
    if (!try exactSteps(ev, x.node)) return null;
    var cw: std.ArrayList(u32) = .empty;
    defer cw.deinit(g);
    try cw.appendSlice(g, b.words);
    var p = b.place;
    var path = f.pos.items[v.pos].slot;
    for (f.slots.relWords(x.slot)) |s| {
        switch (Place.Step.fromWord(s).kind) {
            .field, .index, .ctor_arg => {},
            else => return null,
        }
        if (cw.items.len != 0 and ev.places().cyclic(p)) return null;
        p = ev.places().child(p, Place.Step.fromWord(s)) orelse return null;
        path = (try ev.places().extend(g, f.gc(), path, Place.Step.fromWord(s))).?;
        try cw.append(g, s);
    }
    var w: Walk = .{ .ev = ev, .arg = call.args[x.j], .j = x.j, .groups = groups, .root = cw.items.len == 0 };
    defer inline for (.{ &w.by_key, &w.full, &w.words, &w.ks }) |m| m.deinit(g);
    try w.words.appendSlice(g, f.slots.relWords(x.slot));
    const start = groups.items.len;
    var at = v.pos;
    for (f.slots.relWords(x.slot)) |s| at = if (at == none) none else f.pos_index.get(.{ at, @backingInt(Value.PKind.plain), s, 0 }) orelse none;
    try w.node(x.node, p, path, at, .{ at, none, 0 });
    if (w.cyclic) {
        for (groups.items[start..]) |*gr| gr.targets.deinit(g);
        groups.shrinkRetainingCapacity(start);
        return null;
    }
    return .{ .j = b.j, .slot = try f.slots.relOfWords(g, ev.account(), ev.places(), cw.items), .node = x.node };
}
