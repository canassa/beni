//! L10: the read-off (`docs/design/ownership-v2.md` §2.10 *Read-off*,
//! §2.11, §2.12): an evaluation's contract read off its frame, its result's
//! arrivals described along the result's place, its parameters' reads,
//! writes and escapes, its labels' supplies, and its conditions once the
//! demands are resolved. While a group is solved the read-off stays open:
//! what a key gains later is delivered to it (`deliver`).
//!
//! Obligations kept here: O1 (an unknown arrival is `⊤`, never nothing).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;
const Evaluation = Eval.Evaluation;
const Sink = Eval.Sink;
const Verdicts = Eval.Verdicts;

const hooks: Eval.Hooks = .{ .demand = demandFacts, .escape = escapeFacts, .deliver = deliver };

/// Where the read-off puts arrivals: the result's, or label `label`'s
/// supply `k` (an index into the draft's labels, never a pointer: the
/// lists grow while the facts are delivered).
const ResList = struct { label: u32 = none, k: u32 = 0 };
/// Where a parameter effect goes.
const EffList = enum(u8) { reads, writes, escapes };

fn labelIndex(s: *Sink, cb: u32) Error!u32 {
    const gpa = s.e.gpa();
    while (s.label_at.items.len <= cb) try s.label_at.append(gpa, none);
    if (s.label_at.items[cb] != none) return s.label_at.items[cb];
    const c = s.e.fr().cbs.items[cb];
    const at = try s.d.labelOf(s.arena, c.j, c.slot, c.origin);
    s.label_at.items[cb] = at;
    return at;
}

fn resList(s: *Sink, l: ResList) Error!*Contract.Draft.Res {
    if (l.label == none) return &s.d.res;
    return &(try s.d.labels.items[l.label].supplyOf(s.arena, l.k)).res;
}

fn effList(s: *Sink, l: EffList) *std.ArrayList(Contract.Effect) {
    return switch (l) {
        .reads => &s.d.reads,
        .writes => &s.d.writes,
        .escapes => &s.d.escapes,
    };
}

/// Run `expand` for consumer `sub`: it gets what the keys hold now (in
/// `out`) and, while a group is solved, every leaf they gain later.
fn expandFor(e: *Evaluation, li: u32, sub: Relation.Sub, out: *std.ArrayList(u32)) Error!void {
    const saved = e.ev.cur_sub;
    e.ev.cur_sub = if (e.solver != null) sub else null;
    defer e.ev.cur_sub = saved;
    try e.ev.expand(li, out);
}

/// Describe value `v` at result slot `q` of the result's root into `out`
/// (§2.10 *Read-off*): what arrives at each object slot. A slot whose
/// subtree is described once per place (`canNode`) gets the value's subtree.
fn describe(s: *Sink, v: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f, const gpa = .{ e.fr(), e.gpa() };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(2) = .{}; // each (value, slot) once (§2.3.5)
    defer seen.deinit(gpa);
    try stack.append(gpa, .{ .v = v, .q = q });
    while (stack.pop()) |it| {
        if (s.building.items.len != 0 or try canNode(s, it.q, out)) {
            try emitPart(s, it.q, try nodeOfValue(s, it.v, it.q, out), out);
            continue;
        }
        if ((try seen.getOrPut(gpa, .{ it.v, it.q.int() })).found_existing) continue;
        try f.charge(.inspection, 1);
        try valueBody(s, it.v, it.q, out, &stack);
    }
}

const Item = struct { v: u32, q: PathId };

/// What value `v` gives at result slot `q`: its own arrivals, its parts
/// onto `stack` (or, with none, described at once).
fn valueBody(s: *Sink, v: u32, q: PathId, out: ResList, stack: ?*std.ArrayList(Item)) Error!void {
    const e = s.e;
    const f, const gpa = .{ e.fr(), e.gpa() };
    const x = f.val(v);
    switch (x.kind) {
        .scalar, .bot => {},
        .alt => {
            const ks = f.kidsOf(x);
            var i: usize = 0;
            while (i < ks.len) : (i += 2) if (stack) |st| try st.append(gpa, .{ .v = ks[i + 1], .q = q }) else try describe(s, ks[i + 1], q, out);
        },
        .built => {
            if (x.site != none and Slots.isObject(f.places, q)) try arrive(s, q, .{ .kind = .fresh }, out);
            if (x.form == .list and x.head != 0) {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try e.ev.storageOf(x.head - 1, 0, &ls);
                for (ls.items) |l| try describeLeaf(s, l, q, false, out);
            }
            const ks = f.kidsOf(x);
            for (ks, 0..) |kv, n| {
                const st: ?Step = switch (x.form) {
                    .tuple => try Step.index(f.account, @intCast(n)),
                    .ctor => try f.places.ctorStep(gpa, f.account, x.head, @intCast(n)),
                    .list => Step.elem,
                    .record => try Step.field(f.account, f.wordsOf(x.extra)[n]),
                    .closure => Step.env,
                    .opaque_ => null,
                };
                if (st) |stp| {
                    if (try f.places.extend(gpa, f.gc(), q, stp)) |nq| {
                        if (stack) |sk| try sk.append(gpa, .{ .v = kv, .q = nq }) else try describe(s, kv, nq, out);
                        continue;
                    }
                }
                // A part the result's place does not name (an opaque
                // value's): every object of it arrives at this slot.
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try e.ev.leavesOf(kv, 0, &ls);
                for (ls.items) |l| try describeLeaf(s, l, q, true, out);
            }
        },
        .ref, .top, .shared => {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try e.ev.leavesOf(v, 0, &ls);
            for (ls.items) |l| try describeLeaf(s, l, q, false, out);
        },
    }
}

/// An arrival at `q` and, by structure, at every slot below it.
fn arriveWide(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    if (s.building.items.len != 0) {
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addWide(&s.building.items[s.building.items.len - 1].res, s.arena, try relIn(s, q), a);
        return;
    }
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const list = try resList(s, out);
    try f.charge(.edge, 1);
    if (try Contract.Draft.addWide(list, s.arena, r, a)) {
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, true, a, 0);
    }
}

fn arrive(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    const open = f.places.kind(f.places.pathPlace(q)) == .@"var";
    if (s.building.items.len != 0) {
        const res = &s.building.items[s.building.items.len - 1].res;
        const r = try relIn(s, q);
        if (open) try Contract.Draft.markOpen(res, s.arena, r);
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addArrival(res, s.arena, r, a);
        return;
    }
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const list = try resList(s, out);
    if (open) try Contract.Draft.markOpen(list, s.arena, r);
    try f.charge(.edge, 1);
    if (try Contract.Draft.addArrival(list, s.arena, r, a)) {
        // A new fact of a member: delivered to what reads it (§2.12).
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, open, a, 0);
    }
}

/// A leaf at result slot `q`: its arrivals at `q` and below it. `whole`:
/// every object of it arrives at `q` itself.
fn describeLeaf(s: *Sink, li: u32, q: PathId, whole: bool, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    switch (l.kind) {
        .site, .fresh => try arrive(s, q, .{ .kind = .fresh }, out),
        .shared => try arrive(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        .top => try arrive(s, q, .{ .kind = .top }, out),
        .answer => try arrive(s, q, .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra }, out),
        .recons => unreachable,
        .ref => {
            const r = f.roots.items[l.root];
            const pslot = f.pos.items[l.pos].slot;
            // A value read back at its own place is read by its own
            // structure: an unstepped cast at a place structurally identical
            // to its inner's restores the inner exactly (§2.13.9), so the
            // result's storage is the position's, not every object below it.
            const by_structure = !whole or f.places.pathPlace(pslot) == f.places.pathPlace(q);
            // A call's or a supply's whole subtree read by structure is read
            // through one key below its position, never one per slot below it
            // (§2.10 *Read-off*).
            if (by_structure and (r.kind == .call or r.kind == .supply) and Subtree.wholeOf(f.slots, l.slots) == pslot) return describeCallWide(s, l, pslot, q, out);
            // A whole subtree (`↓p`, §2.3.1): a call's or a supply's through
            // one key below `p`, a parameter's read at `q` itself one deep
            // arrival; else named slot by slot, as a contract names each
            // result slot (§2.10).
            const held = r.kind == .call or r.kind == .supply or (r.kind == .param and !by_structure);
            if (held) for (Subtree.subs(f.slots, l.slots)) |el| {
                const x = Slots.pathOf(el);
                if (r.kind == .param) {
                    try arrive(s, q, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, x), .deep = true }, out);
                } else try describeSub(s, l, pslot, x, q, by_structure, out);
            };
            for (if (held) Subtree.explicit(f.slots, l.slots) else f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots))) |sl| {
                // The result slot of this object: q, below by the steps from
                // the position to the slot.
                var at = q;
                if (by_structure) {
                    const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, .from(sl))) orelse Slots.root;
                    var ps: std.ArrayList(u32) = .empty;
                    defer ps.deinit(gpa);
                    try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &ps);
                    if (ps.items.len == 0) {
                        at = q;
                    } else {
                        for (ps.items[1..]) |p2| try describeOne(s, l, r, sl, .from(p2), out);
                        at = .from(ps.items[0]);
                    }
                }
                try describeOne(s, l, r, sl, at, out);
            }
        },
    }
}

/// A call's or a supply's whole subtree `↓x` (§2.3.1) at result slot
/// `q`: by structure through one key below `x`, else all of it at `q`.
fn describeSub(s: *Sink, l: Value.Leaf, pslot: PathId, x: PathId, q: PathId, by_structure: bool, out: ResList) Error!void {
    const f = s.e.fr();
    const gpa = s.e.gpa();
    var dests: std.ArrayList(u32) = .empty;
    defer dests.deinit(gpa);
    if (by_structure) {
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, x)) orelse Slots.root;
        try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &dests);
    }
    for (dests.items) |d| try describeCallWide(s, l, x, .from(d), out);
    if (dests.items.len != 0) return;
    const sub = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{x.int() | Slots.sub_bit}), .tags = l.tags });
    var xs: std.ArrayList(u32) = .empty;
    defer xs.deinit(gpa);
    try expandFor(s.e, sub, .{ .kind = .describe, .a = out.label, .b = q.int(), .c = out.k, .tags = l.tags }, &xs);
    for (xs.items) |y| try describeLeaf(s, y, q, true, out);
}

/// The subtree at `prefix` of a call's or a supply's root `root`, described
/// at result slot `q` through one key below the prefix (§2.10 *Read-off*).
fn describeBelow(s: *Sink, root: u32, prefix: PathId, tags: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const r = f.roots.items[root];
    const call: u32, const which: u32 = switch (r.kind) {
        .call => .{ r.a, none },
        .supply => blk: {
            const su = f.supplies.items[r.a];
            break :blk .{ su.call, (su.label << 16) | su.k };
        },
        .param, .cb => unreachable,
    };
    if (try canNode(s, q, out) and try callNode(s, call, which, prefix, tags, q, out)) return;
    const saved = e.ev.cur_sub;
    e.ev.cur_sub = if (e.solver != null) .{ .kind = .describe_below, .a = out.label, .b = q.int(), .c = out.k, .d = prefix.int(), .tags = tags } else null;
    const ki = e.ev.instBelow(call, prefix, which) catch |err| {
        e.ev.cur_sub = saved;
        return err;
    };
    e.ev.cur_sub = saved;
    if ((try s.described.getOrPut(e.gpa(), try describedKey(s, ki | Relation.open_bit, q, out))).found_existing) return;
    var i: usize = 0;
    while (i < e.ev.keyItems(ki)[0].len) : (i += 1) {
        const items = e.ev.keyItems(ki);
        const y = (try f.withTags(items[0][i], tags)) orelse continue;
        try describeItem(s, y, items[1][i], prefix, q, out);
    }
}

// ---- a value described once per place (§2.10, *a contract is a tree of shared subtrees*)

/// Whether what arrives below result slot `q` is described once per place,
/// as a subtree relative to `q`: nothing the frame reads grows (no group
/// member's draft), and no place below `q`'s is on a cycle, so every slot
/// below `q` is `q` and its steps.
fn canNode(s: *Sink, q: PathId, out: ResList) Error!bool {
    const e = s.e;
    // A supply.s slots are also read off one arrival at a time, plain at a
    // type variable.s slot until the slot is opened: written out there.
    if (out.label != none) return false;
    if (s.frozen == 0) {
        s.frozen = 1;
        if (e.ev.live) |lv| for (e.fr().calls.items) |cl| if (cl.code != none and lv.draftRes(lv.ctx, cl.code) != null) {
            s.frozen = 2;
        };
    }
    return s.frozen == 1 and try acyclicBelow(s, e.fr().places.pathPlace(q));
}

fn acyclicBelow(s: *Sink, p: PlaceId) Error!bool {
    if (s.acyclic.get(.{p.int()})) |x| return x == 1;
    const places = s.e.fr().places;
    var ok = !places.cyclic(p);
    if (ok) for (places.steps(p).children) |c| if (!try acyclicBelow(s, c)) {
        ok = false;
        break;
    };
    try s.acyclic.put(s.e.gpa(), .{p.int()}, if (ok) 1 else 2);
    return ok;
}

/// `q`'s steps below the innermost subtree's path.
fn relIn(s: *Sink, q: PathId) Error!Slots.Rel {
    const f = s.e.fr();
    const b = &s.building.items[s.building.items.len - 1];
    // The steps up from `q` to the subtree's path (one record a step),
    // never from the root: a slot below another is that slot's steps.
    var w: std.ArrayList(u32) = .empty;
    defer w.deinit(s.e.gpa());
    var at = q;
    while (at != b.q) : (at = f.places.pathParent(at)) {
        if (std.debug.runtime_safety) std.debug.assert(at != .none);
        try f.charge(.path, 1);
        try w.append(s.e.gpa(), f.places.pathStep(at).word());
    }
    std.mem.reverse(u32, w.items);
    return f.slots.rels.find(w.items) orelse f.slots.relOfWords(s.e.gpa(), f.account, f.places, w.items);
}

fn begin(s: *Sink, q: PathId) Error!void {
    s.serial += 1;
    try s.building.append(s.e.gpa(), .{ .q = q, .depth = s.serial });
}

/// What `described` keys a leaf at slot `q` of list `out` by: inside a
/// subtree being described, that subtree.s own (a subtree kept for its
/// place must hold everything said in it, whatever was said before).
fn describedKey(s: *Sink, x: u32, q: PathId, out: ResList) Error![4]u32 {
    if (s.building.items.len == 0) return .{ x, q.int(), out.label, out.k };
    return .{ x, q.int(), s.building.items[s.building.items.len - 1].depth, Relation.open_bit };
}

/// The innermost subtree, made: its arrivals and subtrees in one node,
/// its labels the draft's.
fn end(s: *Sink) Error!Contract.Node {
    var b = s.building.pop().?;
    const same = try s.arena.alloc(u32, s.d.labels.items.len);
    for (same, 0..) |*x, i| x.* = @intCast(i);
    return s.e.contracts.putRes(s.e.gpa(), s.e.fr().slots, &b.res, same);
}

/// Subtree `n` below result slot `q`: into the innermost subtree being
/// described, else into the draft, a fact delivered to what reads it.
fn emitPart(s: *Sink, q: PathId, n: Contract.Node, out: ResList) Error!void {
    if (n == 0) return;
    const f = s.e.fr();
    try f.charge(.edge, 1);
    if (s.building.items.len != 0) {
        _ = try Contract.Draft.addNode(&s.building.items[s.building.items.len - 1].res, s.arena, try relIn(s, q), n);
        return;
    }
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    if (try Contract.Draft.addNode(try resList(s, out), s.arena, r, n)) {
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, false, .{ .kind = .top }, n);
    }
}

/// A subtree described before at the same place (`key`, with `q`'s place):
/// its node, `none` while it is described, or null when it is not yet.
fn memoGet(s: *Sink, key: [6]u32) ?u32 {
    const v = s.nodes.get(key) orelse return null;
    if (v == none - 2) return null;
    // Met again while it is described (a fold's answer feeding itself):
    // it adds nothing here, and nothing made meanwhile is kept.
    if (v == none) s.cut = 0;
    return v;
}

fn memoPut(s: *Sink, key: [6]u32, n: Contract.Node) Error!void {
    const depth = s.building.items.len;
    if (s.cut > depth) {
        try s.nodes.put(s.e.gpa(), key, n);
    } else try s.nodes.put(s.e.gpa(), key, none - 2);
    if (s.cut >= depth) s.cut = std.math.maxInt(usize);
}

/// Value `v` at result slot `q`, as a subtree relative to `q`, once per
/// `(value, place)`.
fn nodeOfValue(s: *Sink, v: u32, q: PathId, out: ResList) Error!Contract.Node {
    const f = s.e.fr();
    const key: [6]u32 = .{ 1, v, 0, 0, f.places.pathPlace(q).int(), 0 };
    if (memoGet(s, key)) |n| return if (n == none) 0 else n;
    try s.nodes.put(s.e.gpa(), key, none);
    try f.charge(.inspection, 1);
    try begin(s, q);
    try valueBody(s, v, q, out, null);
    const n = try end(s);
    try memoPut(s, key, n);
    return n;
}

/// The subtree at `prefix` of call `call`'s root (or of its supply
/// `which`), at result slot `q`, node by node of the callee's tree: one
/// subtree per callee node and result place (§2.10, *a call's
/// instantiation is a tree*). False where it is read through a key instead:
/// the callee's tree is not fixed or has an open node above the prefix.
fn callNode(s: *Sink, call: u32, which: u32, prefix: PathId, tags: u32, q: PathId, out: ResList) Error!bool {
    const e = s.e;
    const f = e.fr();
    const c = e.ev.contractOf(call) orelse return false;
    if (e.contracts.head(c).flags.pessimistic) return false;
    const pw = f.slots.relWords(try f.slots.relOf(e.gpa(), f.account, f.places, prefix));
    var n = e.ev.resRoot(c, which);
    try f.charge(.inspection, @intCast(1 + pw.len));
    for (pw) |w| {
        if (e.contracts.trees.open(n).len != 0) return false;
        n = e.contracts.trees.kidAt(n, w) orelse return true;
    }
    const got = (try callNodeAt(s, call, which, c, n, prefix, tags, q, false, out)) orelse return false;
    try emitPart(s, q, got, out);
    return true;
}

/// Callee node `n` at call slot `cs` and result slot `q` (§2.11.2): each
/// arrival as the key of `cs` reads it (`Relation.Eval.feedAt`), each kid
/// one step below both. Null where a step does not reach a slot.
fn callNodeAt(s: *Sink, call: u32, which: u32, c: Contract.Id, n: Contract.Node, cs: PathId, tags: u32, q: PathId, above: bool, out: ResList) Error!?Contract.Node {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const t = &e.contracts.trees;
    const key: [6]u32 = .{ 2, call, which, n, f.places.pathPlace(q).int(), tags };
    // Below an open node a slot's key reads it too: no subtree is shared.
    if (!above) if (memoGet(s, key)) |m| return if (m == none) 0 else if (m == none - 1) null else m;
    // Every kid's step reaches a slot of both.
    const kids = try gpa.dupe([2]u32, t.kids(n));
    defer gpa.free(kids);
    const at = try gpa.alloc([2]PathId, kids.len);
    defer gpa.free(at);
    for (kids, at) |k, *a| {
        const st = Step.fromWord(k[0]);
        if (st.kind == .level) return fail(s, key, above);
        a.* = .{ (try f.places.extend(gpa, f.gc(), cs, st)) orelse return fail(s, key, above), (try f.places.extend(gpa, f.gc(), q, st)) orelse return fail(s, key, above) };
    }
    if (!above) try s.nodes.put(gpa, key, none);
    try f.charge(.inspection, 1);
    try begin(s, q);
    const here = try gpa.dupe(Contract.Arrival, t.here(n));
    defer gpa.free(here);
    const opens = try gpa.dupe(Contract.Arrival, t.open(n));
    defer gpa.free(opens);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    // Plain: an atom is itself at the slot; anything else is the slot's key.
    var keyed = false;
    for (here) |a| {
        ls.clearRetainingCapacity();
        if (a.kind == .fresh or a.kind == .top or a.kind == .shared) try e.ev.arrivalLeaves(call, c, a, &.{}, &ls) else if (!keyed) {
            keyed = true;
            try ls.appendSlice(gpa, try e.ev.instAt(call, cs, which));
        }
        for (ls.items) |x| if (try f.withTags(x, tags)) |y| try describeLeaf(s, y, q, true, out);
    }
    // Open: atoms and calls' results hold below it; anything else is its
    // projection at the slot, and each slot below through that slot's key.
    for (opens) |a| {
        ls.clearRetainingCapacity();
        try e.ev.arrivalLeaves(call, c, a, &.{}, &ls);
        var atoms: std.ArrayList(u32) = .empty;
        defer atoms.deinit(gpa);
        var uniform = true;
        for (ls.items) |x| if (!try e.ev.uniformAtoms(x, &atoms)) {
            uniform = false;
            break;
        };
        var calls = true;
        for (ls.items) |x| if (!e.ev.expandable(f.leafAt(x))) {
            calls = false;
        };
        if (uniform or calls or a.kind == .fresh or a.kind == .top or a.kind == .shared) {
            for (if (uniform) atoms.items else ls.items) |x| if (try f.withTags(x, tags)) |y| {
                if (f.places.kind(f.places.pathPlace(q)) == .@"var") try describeLeaf(s, y, q, true, out) else try describeWide(s, y, q, out);
            };
            continue;
        }
        for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, cs))) |sl| {
            if (sl == cs.int()) continue;
            const rel = (try f.slots.relBelow(gpa, f.account, f.places, cs, .from(sl))) orelse Slots.root;
            var ps: std.ArrayList(u32) = .empty;
            defer ps.deinit(gpa);
            try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &ps);
            if (ps.items.len == 0) try ps.append(gpa, q.int());
            const run = try gpa.dupe(u32, try e.ev.instAt(call, .from(sl), which));
            defer gpa.free(run);
            for (run) |x| if (try f.withTags(x, tags)) |y| for (ps.items) |d| try describeLeaf(s, y, .from(d), true, out);
        }
        for (ls.items) |x| if (try f.withTags(x, tags)) |y| try describeLeaf(s, y, q, true, out);
    }
    for (kids, at) |k, a| {
        const m = (try callNodeAt(s, call, which, c, k[1], a[0], tags, a[1], above or opens.len != 0, out)) orelse {
            _ = s.building.pop();
            return fail(s, key, above);
        };
        try emitPart(s, a[1], m, out);
    }
    const m = try end(s);
    if (!above) try memoPut(s, key, m);
    return m;
}

fn fail(s: *Sink, key: [6]u32, above: bool) Error!?Contract.Node {
    if (!above) try s.nodes.put(s.e.gpa(), key, none - 1);
    return null;
}

/// An item of a key below `prefix` (leaf `li` at slot `at`), described at
/// the result slot the steps from the prefix take `q` to.
fn describeItem(s: *Sink, li: u32, at: u32, prefix: PathId, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const slot: PathId = .from(at & ~Relation.open_bit);
    const open = at & Relation.open_bit != 0;
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(gpa);
    if (slot == prefix) try ps.append(gpa, q.int()) else {
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, prefix, slot)) orelse Slots.root;
        try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &ps);
        if (ps.items.len == 0) try ps.append(gpa, q.int());
    }
    for (ps.items) |dest| {
        // A type variable's slot has no structure below it: what is open
        // there is all of it at the slot, which `arrive` keeps open.
        const wide = open and f.places.kind(f.places.pathPlace(.from(dest))) != .@"var";
        if (wide) try describeWide(s, li, .from(dest), out) else try describeLeaf(s, li, .from(dest), true, out);
    }
}

/// The subtree of a call or a supply at its slot `sl`, at result slot
/// `dest` and below by structure. A slot that an opaque or a type
/// variable's place holds is read on through the call's arrivals (§2.13.9,
/// *On slots*), one result slot at a time, where the result's place is not
/// its own.
fn describeCallWide(s: *Sink, l: Value.Leaf, sl: PathId, dest: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    try describeBelow(s, l.root, sl, l.tags, dest, out);
    const k = f.places.kind(f.places.pathPlace(sl));
    if ((k != .@"opaque" and k != .@"var") or f.places.pathPlace(sl) == f.places.pathPlace(dest)) return;
    for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, dest))) |qs| {
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, dest, .from(qs))) orelse continue;
        const words = f.slots.relWords(rel);
        if (words.len == 0) continue;
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        if (!try e.ev.throughCall(l.root, sl, words, false, l.tags, 0, &ps)) {
            const all = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try Subtree.below(f.slots, gpa, f.account, f.places, sl), .tags = l.tags });
            try describeLeaf(s, all, .from(qs), true, out);
            continue;
        }
        for (ps.items) |p| try describeLeaf(s, p.leaf, .from(qs), true, out);
    }
}

/// Leaf `li` at result slot `q` and, by structure, at every slot below it.
fn describeWide(s: *Sink, li: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    switch (l.kind) {
        .site, .fresh => try arriveWide(s, q, .{ .kind = .fresh }, out),
        .shared => try arriveWide(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        .top => try arriveWide(s, q, .{ .kind = .top }, out),
        .answer => try arriveWide(s, q, .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra }, out),
        .recons => unreachable,
        .ref => {
            const r = f.roots.items[l.root];
            // The leaf is a subtree of its root read at `q` by structure: its
            // base is the longest common prefix of its slots whose place is
            // `q`'s (a family's element, a position's own slot), and each
            // slot is at the result slot its steps from the base reach. A
            // leaf that is its base's whole subtree says each top slot once,
            // open; any other says each slot. Without such a base it is all
            // at `q` (a cast, §2.13.9).
            // A symbol `↓p` (§2.3.1) is the slot `p` read as a whole subtree.
            const items = f.slots.elems(l.slots);
            var rels = try gpa.alloc(Slots.Rel, items.len);
            defer gpa.free(rels);
            var cp: usize = std.math.maxInt(usize);
            var first: []const u32 = &.{};
            for (items, 0..) |sl, i| {
                rels[i] = try f.slots.relOf(gpa, f.account, f.places, Slots.pathOf(sl));
                const w = f.slots.relWords(rels[i]);
                if (i == 0) {
                    first = w;
                    cp = w.len;
                } else {
                    var n: usize = 0;
                    while (n < cp and n < w.len and w[n] == first[n]) n += 1;
                    cp = n;
                }
            }
            if (items.len == 0) return;
            var base: ?usize = null;
            var base_path: PathId = .none;
            // Never above the leaf's own position: what is above it is not this leaf.
            const floor = f.slots.relWords(try f.slots.relOf(gpa, f.account, f.places, f.pos.items[l.pos].slot)).len;
            var k: usize = cp + 1;
            while (k > floor) {
                k -= 1;
                var ps: std.ArrayList(u32) = .empty;
                defer ps.deinit(gpa);
                try Slots.replay(gpa, f.account, f.places, r.path, first[0..k], &ps);
                if (ps.items.len == 0) continue;
                if (f.places.pathPlace(.from(ps.items[0])) == f.places.pathPlace(q)) {
                    base = k;
                    base_path = .from(ps.items[0]);
                    break;
                }
            }
            const b = base orelse {
                // Read across a cast: a call's part through its arrivals,
                // anything else all of it at every result slot below `q`.
                const qs_all = f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, q));
                for (items, 0..) |sl, i| switch (r.kind) {
                    .call, .supply => {
                        const k2 = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        if (k2 == .@"opaque" or k2 == .@"var") {
                            try describeCallWide(s, l, Slots.pathOf(sl), q, out);
                            continue;
                        }
                        const sub = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = if (Slots.isSub(sl)) try f.slots.internSorted(gpa, f.account, &.{sl}) else try Subtree.below(f.slots, gpa, f.account, f.places, Slots.pathOf(sl)), .tags = l.tags });
                        var xs: std.ArrayList(u32) = .empty;
                        defer xs.deinit(gpa);
                        try e.ev.expand(sub, &xs);
                        for (xs.items) |x| {
                            try describeLeaf(s, x, q, true, out);
                            for (qs_all) |qs| try describeLeaf(s, x, .from(qs), true, out);
                        }
                    },
                    .param => {
                        const pk = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        const a: Contract.Arrival = .{ .kind = .param, .j = r.a, .slot = rels[i], .deep = Slots.isSub(sl) or pk == .@"var" or pk == .@"opaque" };
                        try arrive(s, q, a, out);
                        for (qs_all) |qs| try arrive(s, .from(qs), a, out);
                    },
                    .cb => {
                        const crel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, Slots.pathOf(sl))) orelse Slots.root;
                        const a: Contract.Arrival = .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = crel };
                        try arrive(s, q, a, out);
                        for (qs_all) |qs| try arrive(s, .from(qs), a, out);
                    },
                };
                return;
            };
            const whole = l.slots == try Subtree.below(f.slots, gpa, f.account, f.places, base_path);
            var have: Ids.FixedDict(1) = .{};
            defer have.deinit(gpa);
            if (whole) for (rels) |rl| try have.put(gpa, .{rl}, 0);
            for (items, 0..) |sl, i| {
                const w = f.slots.relWords(rels[i]);
                // A slot below another of a whole subtree is said by it.
                if (whole) {
                    var below_other = false;
                    var m = w.len;
                    while (m > b) {
                        m -= 1;
                        if (have.get(.{try f.slots.relOfWords(gpa, f.account, f.places, w[0..m])}) != null) {
                            below_other = true;
                            break;
                        }
                    }
                    if (below_other) continue;
                }
                var ps: std.ArrayList(u32) = .empty;
                defer ps.deinit(gpa);
                try Slots.replay(gpa, f.account, f.places, q, w[b..], &ps);
                if (ps.items.len == 0) try ps.append(gpa, q.int());
                for (ps.items) |dest| switch (r.kind) {
                    .param => {
                        // An opaque or a type variable's slot holds anything
                        // below it: where the result's place is not its own,
                        // all of it arrives at each result slot (§2.13.9),
                        // never by steps the slot cannot take.
                        const pk = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        const wild = pk == .@"var" or pk == .@"opaque";
                        const a: Contract.Arrival = .{ .kind = .param, .j = r.a, .slot = rels[i], .deep = wild };
                        if (wild and f.places.pathPlace(Slots.pathOf(sl)) != f.places.pathPlace(.from(dest))) {
                            for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, .from(dest)))) |qs| try arrive(s, .from(qs), a, out);
                        } else if (whole or Slots.isSub(sl)) try arriveWide(s, .from(dest), a, out) else try arrive(s, .from(dest), a, out);
                    },
                    .cb => {
                        const crel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, Slots.pathOf(sl))) orelse Slots.root;
                        const a: Contract.Arrival = .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = crel };
                        if (whole or Slots.isSub(sl)) try arriveWide(s, .from(dest), a, out) else try arrive(s, .from(dest), a, out);
                    },
                    .call, .supply => if (whole or Slots.isSub(sl)) try describeCallWide(s, l, Slots.pathOf(sl), .from(dest), out) else {
                        const one = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{sl}), .tags = l.tags });
                        try describeLeaf(s, one, .from(dest), true, out);
                    },
                };
            }
        },
    }
}

fn describeOne(s: *Sink, l: Value.Leaf, r: Value.Root, sl: u32, at: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    switch (r.kind) {
        .param => {
            const deep = f.places.kind(f.places.pathPlace(.from(sl))) == .@"var";
            try arrive(s, at, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = deep }, out);
        },
        .cb => {
            const rel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
            try arrive(s, at, .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = rel }, out);
        },
        .call, .supply => {
            const one = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{sl}), .tags = l.tags });
            // Once a slot; a subtree described once per place has its memo.
            if ((try s.described.getOrPut(gpa, try describedKey(s, one, at, out))).found_existing) return;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try expandFor(e, one, .{ .kind = .describe, .a = out.label, .b = at.int(), .c = out.k, .tags = l.tags }, &ls);
            for (ls.items) |x| try describeLeaf(s, x, at, true, out);
        },
    }
}

/// The effects of leaf `li` on the frame's parameters: each parameter slot
/// it names (expanded through calls), as `(j, slot)`.
fn paramEffects(s: *Sink, li: u32, deep: bool, out: EffList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try stack.append(gpa, li);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, .{x})).found_existing) continue;
        if ((try s.effected.getOrPut(gpa, .{ x, @intFromBool(deep), @backingInt(out) })).found_existing) continue;
        const l = f.leafAt(x);
        if (l.kind != .ref) continue;
        const r = f.roots.items[l.root];
        switch (r.kind) {
            .param => {
                // A whole subtree (`↓p`, §2.3.1): one deep effect at `p`.
                for (f.slots.elems(l.slots)) |sl| {
                    if (Slots.isNot(sl)) continue;
                    const eff: Contract.Effect = .{ .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, Slots.pathOf(sl)), .deep = deep or Slots.isSub(sl) };
                    if (try Contract.Draft.addEffect(effList(s, out), s.arena, eff)) {
                        if (out != .reads) if (e.solver) |sv| try sv.effFact(sv.ctx, e.x, out == .writes, eff);
                    }
                }
            },
            .call, .supply => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try expandFor(e, x, .{ .kind = .effect, .a = @backingInt(out), .b = @intFromBool(deep), .tags = l.tags }, &ls);
                try stack.appendSlice(gpa, ls.items);
            },
            .cb => {},
        }
    }
}

/// An escape made while the read-off is under way.
fn escapeFacts(e: *Evaluation, leaf: u32) Error!void {
    try paramEffects(&e.sink, leaf, true, .escapes);
}

/// A demand's written parameter slots (whatever its verdict).
fn demandFacts(e: *Evaluation, di: usize) Error!void {
    const dm = e.demands.items[di];
    for (e.w.leavesOfRun(dm.targets)) |t| try paramEffects(&e.sink, t, dm.deep, .writes);
}

/// The facts of the code's contract (§2.10 *Read-off*): its result's
/// arrivals, reads, writes, escapes and labels. While a group is solved
/// the read-off stays open: what the calls' keys gain later, and the
/// demands and escapes made later, arrive in the draft as they come.
pub fn factsOff(e: *Evaluation, arena: Allocator, d: *Contract.Draft) Error!void {
    const w = e.w;
    const f = e.fr();
    const gpa = e.gpa();
    const code = w.code;
    d.* = .{ .arity = @intCast(code.params.len + code.captures.len) };
    e.sink = .{ .e = e, .d = d, .arena = arena };
    e.hooks = hooks;
    e.facts_on = true;
    const s = &e.sink;
    const rpath = try f.places.rootPath(gpa, code.result_place);
    const rv = f.val(w.result);
    d.flags.returns = rv.kind != .bot;
    d.flags.cross = !Slots.holdsAny(f.places, rpath);
    if (d.flags.returns and !d.flags.cross) try describe(s, w.result, rpath, .{});
    // Reads: every use of a local whose value is a parameter's, at its path.
    // One pass (§2.3.4 *Reading*): a leaf set node read deep before adds no
    // read, so a tower of uses costs its distinct nodes.
    const pass = f.sets.newPass();
    for (w.uses.items) |u| {
        const b = w.bindings[u.local];
        if (b.value == none) continue;
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        const lroot = try f.places.rootPath(gpa, try e.ctx.placeOfLocal(e.ctx.ctx, u.local));
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, lroot, u.path)) orelse Slots.root;
        // A call use reads what its callee's footprint reads of the
        // argument (§2.10 *Read-off*, §2.11.2 item 1), not all of it.
        if (u.kind == .call and u.use_node != .none) foot: {
            const ft = w.foots.items[u.use_node.int()];
            const call = f.calls.items[ft[0]];
            if (call.contract == none) break :foot;
            const h = e.contracts.head(call.contract);
            if (h.flags.pessimistic) break :foot;
            for (e.contracts.readsOf(h.reads)) |x| if (x[0] == ft[1]) try readsThrough(s, b.value, f.slots.relWords(rel), x[1], pass);
            continue;
        }
        e.ev.pass = pass;
        defer e.ev.pass = 0;
        try e.ev.project(b.value, f.slots.relWords(rel), true, 0, 0, &ps);
        for (ps.items) |p| try paramEffects(s, p.leaf, true, .reads);
    }
    // Writes: every demand's parameter targets, whatever its verdict.
    for (0..e.demands.items.len) |di| try demandFacts(e, di);
    // Escapes, deep.
    // By index: an escape made meanwhile is read off when it is made.
    const n_esc = e.escapes.items.len;
    for (0..n_esc) |i| try paramEffects(s, e.escapes.items[i].leaf, true, .escapes);
    // Labels: the direct ones with their arguments, the passed-on ones with
    // their callees' supplies.
    for (f.cbs.items, 0..) |cb, ci| {
        const at = try labelIndex(s, @intCast(ci));
        if (cb.inst != none) {
            const dl = &d.labels.items[at];
            dl.calls = if (cb.calls > 1 or dl.calls == .many) .many else if (dl.calls == .none) .once else .many;
            for (cb.args, 0..) |a, k| {
                _ = try d.labels.items[at].supplyOf(arena, @intCast(k));
                const ap = f.val(a).place;
                const root = if (ap != .none) try f.places.rootPath(gpa, ap) else rpath;
                try describe(s, a, root, .{ .label = at, .k = @intCast(k) });
            }
        }
    }
    for (e.passes.items) |p| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        const dl = &d.labels.items[at];
        dl.calls = @fromBackingInt(@intCast(@max(@backingInt(dl.calls), @backingInt(lab.calls))));
        // The supplies at this call's function type: a callee's supply slot
        // of a type variable's place (`apply : (a → b), a → b`) takes the
        // whole argument, whose structure this frame's type names. Each
        // part arrives at its own slot below, as a direct label's argument
        // does: one arrival at the variable's slot would leave a write at
        // `.f0` of an `R` supply with nothing to read (§2.11.3).
        var site: std.ArrayList(PlaceId) = .empty;
        defer site.deinit(gpa);
        const at_site = f.slots.relWords(lab.slot).len == 0 and lab.j < call.arg_insts.len and call.arg_insts[lab.j] != none and
            (try e.ctx.siteSig(e.ctx.ctx, call.arg_insts[lab.j], &site)) != null;
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const es = try Eval.entriesOf(e, su.res_root);
            if (at_site and su.k < site.items.len) for (es.items.items) |rs| {
                for (rs.arrivals) |a| {
                    if (a.kind != .param or a.j >= call.args.len) continue;
                    const v = try e.ev.valueAt(call.args[a.j], f.slots.relWords(a.slot));
                    var ps: std.ArrayList(u32) = .empty;
                    defer ps.deinit(gpa);
                    try Slots.replay(gpa, f.account, f.places, try f.places.rootPath(gpa, site.items[su.k]), es.wordsOf(rs), &ps);
                    for (ps.items) |p2| try describe(s, v, .from(p2), .{ .label = at, .k = su.k });
                }
            };
            _ = try d.labels.items[at].supplyOf(arena, su.k);
            for (es.items.items) |x| {
                const rel = f.slots.rels.find(es.wordsOf(x)) orelse try f.slots.relOfWords(gpa, f.account, f.places, es.wordsOf(x));
                for (x.arrivals) |a| {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    {
                        const saved = e.ev.cur_sub;
                        e.ev.cur_sub = if (e.solver != null) .{ .kind = .supply, .a = at, .b = su.k, .c = rel } else null;
                        defer e.ev.cur_sub = saved;
                        try Eval.supplyLeaves(e, p[1], a, &ls);
                    }
                    for (ls.items) |l| try supplyArrive(s, l, rel, .{ .label = at, .k = su.k });
                }
            }
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            for (e.contracts.effectsOf(su.kept)) |kp| _ = try Contract.Draft.addEffect(&sup.kept, arena, kp);
        }
    }
}

/// A callee's reads of an argument (tree `n`), read where value `v` is used
/// at `at` (§2.10 *Read-off*): a parameter's subtree read by its own
/// structure, of more than `Slots.below_min` objects, takes the tree whole,
/// below the slot it is used at (§2.10,
/// *a call's instantiation is a tree*); anything else is each read slot
/// projected.
fn readsThrough(s: *Sink, v: u32, at: []const u32, n: Contract.Node, pass: u32) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    whole: {
        const x = f.val(try e.ev.valueAt(v, at));
        if (x.kind != .ref or x.family != Slots.empty or f.roots.items[x.root].kind != .param) break :whole;
        const sl = f.pos.items[x.pos].slot;
        const k = f.places.kind(f.places.pathPlace(sl));
        if (k == .@"var" or k == .@"opaque" or !try acyclicBelow(s, f.places.pathPlace(sl))) break :whole;
        // A subtree written out (at most `Slots.below_min` objects) is read
        // slot by slot: what a slot holds no object of reads nothing.
        if (!Subtree.symbolic(f.slots, try Subtree.below(f.slots, gpa, f.account, f.places, sl))) break :whole;
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addEffect(&s.d.reads, s.arena, .{ .j = f.roots.items[x.root].a, .slot = try f.slots.relOf(gpa, f.account, f.places, sl), .node = n });
        return;
    }
    var es: Forest.Entries = .{};
    defer es.deinit(gpa);
    try es.of(&e.contracts.trees, gpa, f.places, n, at);
    for (es.items.items) |x| {
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        e.ev.pass = if (x.open) pass else 0;
        defer e.ev.pass = 0;
        try e.ev.project(v, es.wordsOf(x), x.open, 0, 0, &ps);
        for (ps.items) |p| try paramEffects(s, p.leaf, x.open, .reads);
    }
}

/// A leaf delivered to a consumer of the read-off (§2.12 *Deliveries*).
pub fn deliver(e: *Evaluation, sub: Relation.Sub, x: u32, at: u32) Error!void {
    const f = e.fr();
    const y = (try f.withTags(x, sub.tags)) orelse return;
    switch (sub.kind) {
        .describe => try describeLeaf(&e.sink, y, .from(sub.b), true, .{ .label = sub.a, .k = sub.c }),
        .describe_below => try describeItem(&e.sink, y, at, .from(sub.d), .from(sub.b), .{ .label = sub.a, .k = sub.c }),
        .forward_below => unreachable,
        .effect => try paramEffects(&e.sink, y, sub.b != 0, @fromBackingInt(@intCast(sub.a))),
        .supply => try supplyArrive(&e.sink, y, sub.c, .{ .label = sub.a, .k = sub.b }),
        .escape => try Eval.addEscape(e, y, sub.a),
        .forward => unreachable,
    }
}

/// The conditions of the code's contract, once its facts are in: its
/// result's separation, what its writes rely on, its labels' supplies'
/// conditions and kept slots, and `once` (§2.10 *Read-off*).
pub fn condsOff(e: *Evaluation, arena: Allocator, v: Verdicts) Error!void {
    const w = e.w;
    const f = e.fr();
    const s = &e.sink;
    const d = s.d;
    const code = w.code;
    if (d.flags.returns and !d.flags.cross) d.res_cond = try Distinct.sepOf(&e.ev, w.result);
    // An arrival is read where the result is consumed.
    var arrs: std.ArrayList(Contract.Arrival) = .empty;
    for (d.res.items.items) |rs| {
        arrs.clearRetainingCapacity();
        if (rs.node == 0) try arrs.append(arena, rs.a) else try Forest.arrivalsOf(&e.contracts.trees, arena, f.places, rs.node, &arrs);
        for (arrs.items) |a| if (a.kind == .param) {
            _ = try Contract.Draft.addEffect(&d.reads, arena, .{ .j = a.j, .slot = a.slot, .deep = true });
        };
    }
    d.req = v.req;
    for (f.cbs.items, 0..) |cb, ci| {
        if (cb.inst == none) continue;
        const at = try labelIndex(s, @intCast(ci));
        for (cb.args, 0..) |_, k| {
            const sup = try d.labels.items[at].supplyOf(arena, @intCast(k));
            if (ci < v.supply_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.supply_cond[ci]);
        }
        for (v.kept) |kp| if (kp[0] == ci) {
            const sup = try d.labels.items[at].supplyOf(arena, kp[1]);
            try keptAt(s, kp[2], Slots.root, &sup.kept);
        };
    }
    for (e.passes.items, 0..) |p, pi| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            sup.cond = try Cond.conj(arena, f.account, sup.cond, try Distinct.instSel(&e.ev, try e.contracts.cond(arena, su.cond), p[1]));
            if (pi < v.pass_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.pass_cond[pi]);
            for (v.pass_kept) |kp| if (kp[0] == pi and kp[1] == su.k) try keptAt(s, kp[2], kp[3], &sup.kept);
        }
    }
    // A code that writes one of its captures is `once` (R-2.8).
    for (d.writes.items) |x| if (x.j >= code.params.len) {
        d.flags.once = true;
    };
}

/// A leaf's arrivals, all at supply slot `rel`: a parameter's slots, an
/// answer's label, what a call or a supply comes from.
fn supplyArrive(s: *Sink, li: u32, rel: Slots.Rel, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try stack.append(gpa, li);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, .{x})).found_existing) continue;
        const l = f.leafAt(x);
        const a: Contract.Arrival = switch (l.kind) {
            .site, .fresh => .{ .kind = .fresh },
            .shared => .{ .kind = .shared, .j = l.atom, .slot = l.extra },
            .top => .{ .kind = .top },
            .answer => .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra },
            .recons => unreachable,
            .ref => {
                const r = f.roots.items[l.root];
                switch (r.kind) {
                    .param => for (f.slots.elems(l.slots)) |el| {
                        if (Slots.isNot(el)) continue;
                        const sl = Slots.pathOf(el);
                        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, sl), .deep = Slots.isSub(el) or f.places.kind(f.places.pathPlace(sl)) == .@"var" });
                    },
                    .cb => for (f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots))) |sl| {
                        const below = (try f.slots.relBelow(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
                        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = below });
                    },
                    .call, .supply => {
                        var ls: std.ArrayList(u32) = .empty;
                        defer ls.deinit(gpa);
                        try expandFor(e, x, .{ .kind = .supply, .a = out.label, .b = out.k, .c = rel, .tags = l.tags }, &ls);
                        try stack.appendSlice(gpa, ls.items);
                    },
                }
                continue;
            },
        };
        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, a);
    }
}

/// A kept leaf at supply slot `at`: its slots below `at`.
fn keptAt(s: *Sink, li: u32, at: Slots.Rel, out: *std.ArrayList(Contract.Effect)) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    if (l.kind != .ref) {
        _ = try Contract.Draft.addEffect(out, s.arena, .{ .j = 0, .slot = at, .deep = true });
        return;
    }
    const pslot = f.pos.items[l.pos].slot;
    for (f.slots.elems(l.slots)) |el| {
        if (Slots.isNot(el)) continue;
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, Slots.pathOf(el))) orelse Slots.root;
        const ws = try std.mem.concat(s.arena, u32, &.{ f.slots.relWords(at), f.slots.relWords(rel) });
        _ = try Contract.Draft.addEffect(out, s.arena, .{ .j = 0, .slot = try f.slots.relOfWords(gpa, f.account, f.places, ws), .deep = Slots.isSub(el) });
    }
}
