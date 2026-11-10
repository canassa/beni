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
const Replay = @import("Replay.zig");
const SlotWords = @import("SlotWords.zig");
const Subtree = @import("Subtree.zig");
const BelowSize = @import("BelowSize.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Graft = @import("Graft.zig");
const Origin = @import("Origin.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Eval = @import("Eval.zig");
const FnRun = @import("FnRun.zig");
const Outward = @import("Outward.zig");
const SupplyCond = @import("SupplyCond.zig");
const SupplyAnswers = @import("SupplyAnswers.zig");
const SplitRow = @import("SplitRow.zig");
const SupplyKey = @import("SupplyKey.zig");
const Held = @import("Held.zig");
const Routed = @import("Routed.zig");
const CallGraft = @import("CallGraft.zig");
const Canon = @import("Canon.zig");
const AtomGraft = @import("AtomGraft.zig");
const Put = @import("Put.zig");
const Needs = @import("Needs.zig");
const PastPayload = @import("PastPayload.zig");
const PutMemo = @import("PutMemo.zig");
const LevelTargets = @import("LevelTargets.zig");
const Building = @import("Building.zig");
const Made = @import("Made.zig");
const Host = @import("Host.zig");
const Cells = @import("Cells.zig");
const ReadCols = @import("ReadCols.zig");
const BelowAnchors = @import("BelowAnchors.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;
const Evaluation = Eval.Evaluation;
const Sink = Eval.Sink;
const Verdicts = @import("Kept.zig").Verdicts;

const hooks: Eval.Hooks = .{ .demand = demandFacts, .escape = escapeFacts, .deliver = deliver };

/// Run `expand` for consumer `sub`: it gets what the keys hold now (in
/// `out`) and, while a group is solved, every leaf they gain later.
fn expandFor(e: *Evaluation, li: u32, sub: Relation.Sub, out: *std.ArrayList(u32)) Error!void {
    const saved = e.ev.cur_sub;
    e.ev.cur_sub = if (e.solver != null) sub else null;
    defer e.ev.cur_sub = saved;
    try e.ev.expandRouted(li, out);
}

/// Describe value `v` at result slot `q` of the result's root into `out`
/// (§2.10 *Read-off*): what arrives at each object slot. A slot whose
/// subtree is described once per place (`canNode`) gets the value's subtree.
fn describe(s: *Sink, v: u32, q: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    const f, const gpa = .{ e.fr(), e.gpa() };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(2) = .{}; // each (value, slot) once (§2.3.5)
    defer seen.deinit(gpa);
    try stack.append(gpa, .{ .v = v, .q = q });
    while (stack.pop()) |it| {
        if (s.building.items.len != 0 or try canNode(s, it.q, out)) {
            try Put.emitPart(s, it.q, try nodeOfValue(s, it.v, it.q, out), out);
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
fn valueBody(s: *Sink, v: u32, q: PathId, out: Put.ResList, stack: ?*std.ArrayList(Item)) Error!void {
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
            if (x.site != none and Slots.isObject(f.places, q)) {
                try Put.arrive(s, q, try Made.made(s, .{ .kind = .site, .atom = x.site }), out);
                if (try hosted(s, try f.leaf(.{ .kind = .site, .atom = x.site }), q.int(), false, out)) try Put.arrive(s, q, .{ .kind = .host }, out);
            }
            if ((x.form == .list or x.form == .record) and x.head != 0) {
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
                    .record => try Step.ofRank(f.account, f.wordsOf(x.extra)[n]),
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
        .ref, .top, .shared, .host => {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try e.ev.leavesOf(v, 0, &ls);
            for (ls.items) |l| try describeLeaf(s, l, q, false, out);
        },
    }
}

/// Whether no step below slot `sl` names what it holds.
fn unnamed(f: *Value.Frame, sl: PathId) bool {
    if (@import("Mutate.zig").on(.family_exit_off)) return false;
    const k = f.places.kind(f.places.pathPlace(sl));
    return k == .@"var";
}

/// A leaf at result slot `q`: its arrivals at `q` and below it. `whole`:
/// every object of it arrives at `q` itself.
fn describeLeaf(s: *Sink, li: u32, q: PathId, whole: bool, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    if (try hosted(s, li, q.int(), l.kind == .ref, out)) if (l.kind == .ref) try Put.arriveWide(s, q, .{ .kind = .host }, out) else try Put.arrive(s, q, .{ .kind = .host }, out);
    switch (l.kind) {
        .site, .fresh => {
            try Put.arrive(s, q, try Made.made(s, l), out);
            // A closure's captures leave with it, reached by no structure here.
            if (l.kind == .site and !(try s.described.getOrPut(e.gpa(), try Building.describedKey(s, li, q, out))).found_existing) for (e.w.closures.items) |cl| if (cl.inst == l.atom) for (f.kidsOf(f.val(cl.value))) |k| try describe(s, k, q, out);
        },
        .shared => try Put.arriveWide(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        // Unknown here, unknown below: no step of it is fresh (§2.1, *A family*).
        .top, .loan => {
            for ([_]bool{ false, true }) |wide| if (wide) try Put.arriveWide(s, q, .{ .kind = .top }, out) else try Put.arrive(s, q, .{ .kind = .top }, out);
            try describeOrigin(s, l, q, out);
        },
        .host => try Put.arrive(s, q, .{ .kind = .host }, out),
        .answer => try Put.arrive(s, q, try Made.answer(s, l.atom, l.extra, l.whole), out),
        .recons => unreachable,
        .ref => {
            const r = f.roots.items[l.root];
            const pslot = f.pos.items[l.pos].slot;
            // A value read back at its own place is read by its own structure: an unstepped
            // cast restores the inner exactly (§2.13.9), its storage the position's.
            const by_structure = !whole or f.places.pathPlace(pslot) == f.places.pathPlace(q);
            // A parameter's whole subtree of more than `Slots.below_min` objects read
            // by structure at its own place, with no cycle below, is one open arrival,
            // never one a slot below it (§2.10, *Arrivals by structure*). So is one in
            // the result at its own path, whatever its size (§2.11.2).
            if (r.kind == .param and !l.at_pos and f.places.pathPlace(pslot) == f.places.pathPlace(q) and Subtree.symbolic(f.slots, l.slots) and l.slots == try Subtree.below(f.slots, gpa, f.account, f.places, pslot) and (try Eval.acyclicBelow(s, f.places.pathPlace(q)) or (pslot == q and out.label == none))) return Put.arriveWide(s, q, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, pslot), .deep = f.places.kind(f.places.pathPlace(pslot)) == .@"var", .path = pslot.int() }, out);
            if (r.kind == .cb and out.label == none and !l.at_pos and f.places.pathPlace(pslot) == f.places.pathPlace(q) and l.slots == try Subtree.below(f.slots, gpa, f.account, f.places, pslot) and try Eval.acyclicBelow(s, f.places.pathPlace(q))) {
                const crel = (try f.slots.relUnder(gpa, f.account, f.places, r.path, pslot)) orelse Slots.root;
                return Put.arriveWide(s, q, try Made.answer(s, r.a, crel, true), out);
            }
            // A call's or a supply's whole subtree by structure: one key below it (§2.10).
            if (by_structure and (r.kind == .call or r.kind == .supply) and Subtree.wholeOf(f.slots, l.slots) == pslot) return describeCallWide(s, l, pslot, q, out);
            // A whole subtree (`↓p`, §2.3.1): a call's or a supply's through one key
            // below `p`, a parameter's at `q` one deep arrival; else slot by slot.
            const held = r.kind == .call or r.kind == .supply or (r.kind == .param and !by_structure);
            var named: std.ArrayList(u32) = .empty;
            defer named.deinit(gpa);
            try named.appendSlice(gpa, if (held) Subtree.explicit(f.slots, l.slots) else f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots)));
            // The result slots of the slots this leaf names: the read's column.
            const col = if (by_structure) try ReadCols.read(s, pslot, q) else none;
            if (by_structure) {
                var domain: std.ArrayList(u32) = .empty;
                defer domain.deinit(gpa);
                try domain.appendSlice(gpa, named.items);
                if (held and r.kind != .param) for (Subtree.subs(f.slots, l.slots)) |el| try domain.append(gpa, Slots.pathOf(el).int());
                try ReadCols.fill(s, pslot, q, domain.items, col);
            }
            if (held) for (Subtree.subs(f.slots, l.slots)) |el| {
                const x = Slots.pathOf(el);
                if (r.kind == .param) {
                    try Put.arrive(s, q, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, x), .deep = true, .path = x.int() }, out);
                } else try describeSub(s, l, col, x, q, by_structure, out);
            };
            for (named.items) |sl| {
                // The result slot of this object: q, below by the steps from
                // the position to the slot.
                var at = q;
                var mapped = false;
                if (by_structure) {
                    var ps: std.ArrayList(u32) = .empty;
                    defer ps.deinit(gpa);
                    try ReadCols.dests(s, col, pslot, .from(sl), q, &ps);
                    if (ps.items.len == 0) {
                        at = q;
                    } else {
                        for (ps.items[1..]) |p2| try describeOne(s, l, r, sl, .from(p2), out);
                        at = .from(ps.items[0]);
                        mapped = true;
                    }
                }
                try describeOne(s, l, r, sl, at, out);
                // Out of a family (§2.1, *The exit rule*): no slot below a concrete `at` names it.
                if (mapped and unnamed(f, .from(sl)) and f.places.kind(f.places.pathPlace(at)) != .@"var") {
                    // A parameter's by its slot; any other root's contract names no such slot.
                    if (r.kind == .param) try Put.arriveWide(s, at, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = true, .path = sl }, out) else try Put.arriveWide(s, at, .{ .kind = .top }, out);
                }
            }
        },
    }
}

/// A call's or a supply's whole subtree `↓x` (§2.3.1) at result slot
/// `q`: by structure through one key below `x`, else all of it at `q`.
fn describeSub(s: *Sink, l: Value.Leaf, col: u32, x: PathId, q: PathId, by_structure: bool, out: Put.ResList) Error!void {
    const f = s.e.fr();
    const gpa = s.e.gpa();
    var dests: std.ArrayList(u32) = .empty;
    defer dests.deinit(gpa);
    if (by_structure) if (s.reads.cols.items[col].at(x.int())) |ds| try dests.appendSlice(gpa, ds);
    for (dests.items) |d| try describeCallWide(s, l, x, .from(d), out);
    if (dests.items.len != 0) return;
    const sub = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{x.int() | Slots.sub_bit}), .tags = l.tags });
    var xs: std.ArrayList(u32) = .empty;
    defer xs.deinit(gpa);
    try expandFor(s.e, sub, .{ .kind = .describe, .a = out.label, .b = q.int(), .c = out.k, .tags = l.tags, .key = out.key }, &xs);
    for (xs.items) |y| try describeLeaf(s, y, q, true, out);
}

/// The subtree at `prefix` of a call's or a supply's root `root`, described
/// at result slot `q` through one key below the prefix (§2.10 *Read-off*).
fn describeBelow(s: *Sink, root: u32, prefix: PathId, tags: u32, q: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const r = f.roots.items[root];
    const call: u32, const which: u32 = switch (r.kind) {
        .call => .{ r.a, none },
        .supply => .{ f.supplies.items[r.a].call, r.a },
        .param, .cb => unreachable,
    };
    if (try canNode(s, q, out) and try callNode(s, call, which, prefix, tags, q, out)) return;
    const saved = e.ev.cur_sub;
    const live = e.solver != null;
    e.ev.cur_sub = if (live) .{ .kind = .describe_below, .a = out.label, .b = q.int(), .c = out.k, .d = prefix.int(), .tags = tags, .key = out.key } else null;
    // Every anchor (§2.1, *One below*): the prefix's key by its steps, a fold's all of it at `q` and below.
    var anchors: std.ArrayList(BelowAnchors.Anchor) = .empty;
    defer anchors.deinit(e.gpa());
    e.ev.instBelow(call, prefix, which, if (live) .{ .kind = .describe_whole, .a = out.label, .b = q.int(), .c = out.k, .tags = tags, .key = out.key } else null, &anchors) catch |err| {
        e.ev.cur_sub = saved;
        return err;
    };
    e.ev.cur_sub = saved;
    for (anchors.items) |an| if (an.at == prefix and !BelowAnchors.isFold(f, prefix)) try describeKey(s, an.key, prefix, tags, q, out) else try describeFold(s, an.key, tags, q, out);
}

/// The items of a fold's key `ki`, each all of it at result slot `q` and below it (`describeEach`).
fn describeFold(s: *Sink, ki: u32, tags: u32, q: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    if ((try s.described.getOrPut(e.gpa(), try Building.describedKey(s, ki | Relation.open_bit, .from(q.int() | Relation.open_bit), out))).found_existing) return;
    var i: usize = 0;
    while (i < e.ev.keys.items[ki].leaves.items.len) : (i += 1) {
        const k = e.ev.keys.items[ki];
        if (try e.fr().withTags(try e.ev.widen(k.leaves.items[i], k.at.items[i]), tags)) |y| try describeEach(s, y, q, out);
    }
}

/// Leaf `li` of a fold's key at result slot `q` and at every slot below it: no steps from the
/// read's prefix name a slot below the fold, and the result's own folds are other places.
fn describeEach(s: *Sink, li: u32, q: PathId, out: Put.ResList) Error!void {
    const f = s.e.fr();
    if (Held.has(try Held.atoms(f, try Put.resList(s, out), try SupplyKey.relAt(s, q, out.key)), f.leafAt(li))) return;
    try describeLeaf(s, li, q, true, out);
    for (f.slots.items(try Subtree.belowAll(f.slots, s.e.gpa(), f.account, f.places, q))) |qs| try describeLeaf(s, li, .from(qs), true, out);
}

/// The prefix's key `ki` of a read below it, each item at the result slot its steps take `q` to.
fn describeKey(s: *Sink, ki: u32, prefix: PathId, tags: u32, q: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    if ((try s.described.getOrPut(e.gpa(), try Building.describedKey(s, ki | Relation.open_bit, q, out))).found_existing) return;
    const held = try Held.atoms(f, try Put.resList(s, out), try SupplyKey.relAt(s, q, out.key));
    // The result slots of the key's items: the read's column.
    const col = try ReadCols.read(s, prefix, q);
    {
        var domain: std.ArrayList(u32) = .empty;
        defer domain.deinit(e.gpa());
        const k = e.ev.keys.items[ki];
        for (k.leaves.items, k.at.items) |x, at| {
            if (at & ~Relation.open_bit == prefix.int()) continue;
            const y = (try f.withTags(x, tags)) orelse continue;
            if (!Held.has(held, f.leafAt(y))) try domain.append(e.gpa(), at & ~Relation.open_bit);
        }
        try ReadCols.fill(s, prefix, q, domain.items, col);
    }
    var i: usize = 0;
    while (i < e.ev.keys.items[ki].leaves.items.len) : (i += 1) {
        const k = e.ev.keys.items[ki];
        const y = (try f.withTags(k.leaves.items[i], tags)) orelse continue;
        try describeItem(s, col, y, k.at.items[i], prefix, q, held, out);
    }
}

// ---- a value described once per place (§2.10, *a contract is a tree of shared subtrees*)

/// Whether what arrives below result slot `q` is described once per place,
/// as a subtree relative to `q`: nothing the frame reads grows (no group
/// member's draft), and no place below `q`'s is on a cycle, so every slot
/// below `q` is `q` and its steps.
fn canNode(s: *Sink, q: PathId, out: Put.ResList) Error!bool {
    const e = s.e;
    // A supply.s slots are also read off one arrival at a time, plain at a
    // type variable.s slot until the slot is opened: written out there.
    if (out.label != none or e.w.code.called != null) return false;
    if (s.frozen == 0) {
        s.frozen = 1;
        if (e.ev.live) |lv| for (e.fr().calls.items) |cl| if (cl.code != none and lv.draftRes(lv.ctx, cl.code) != null) {
            s.frozen = 2;
        };
    }
    return s.frozen == 1 and try Eval.acyclicBelow(s, e.fr().places.pathPlace(q));
}

/// Value `v` at result slot `q`, as a subtree relative to `q`, once per
/// `(value, place)`.
fn nodeOfValue(s: *Sink, v: u32, q: PathId, out: Put.ResList) Error!Contract.Node {
    const f = s.e.fr();
    const key: [6]u32 = .{ 1, v, 0, 0, f.places.pathPlace(q).int(), 0 };
    if (PutMemo.get(s, key)) |n| return if (n == none) 0 else n;
    try s.nodes.put(s.e.gpa(), key, none);
    try f.charge(.inspection, 1);
    try Building.begin(s, q);
    try valueBody(s, v, q, out, null);
    const n = try Building.end(s);
    try PutMemo.put(s, key, n);
    return n;
}

/// The subtree at `prefix` of call `call`'s root (or of its supply
/// `which`), at result slot `q`, node by node of the callee's tree: one
/// subtree per callee node and result place (§2.10, *a call's
/// instantiation is a tree*). False where it is read through a key instead:
/// the callee's tree is not fixed or has an open node above the prefix.
fn callNode(s: *Sink, call: u32, which: u32, prefix: PathId, tags: u32, q: PathId, out: Put.ResList) Error!bool {
    const e = s.e;
    const f = e.fr();
    const c = e.ev.contractOf(call) orelse return false;
    if (e.contracts.head(c).flags.pessimistic) return false;
    if (try BelowAnchors.foldsAbove(f, e.gpa(), e.ev.arena, prefix)) return false; // §2.1, *One below*
    const pw = f.slots.relWords(try f.slots.relOf(e.gpa(), f.account, f.places, prefix));
    var n = e.ev.resRoot(c, which);
    try f.charge(.inspection, @intCast(1 + pw.len));
    for (pw) |w| {
        if (e.contracts.trees.open(n).len != 0) return false;
        n = e.contracts.trees.kidAt(n, w) orelse return e.contracts.trees.rowKid(f.places, n, w) == null;
    }
    const got = (try callNodeAt(s, call, which, c, n, prefix, tags, q, false, out)) orelse return false;
    try Put.emitPart(s, q, got, out);
    return true;
}

/// Callee node `n` at call slot `cs` and result slot `q` (§2.11.2): each
/// arrival as the key of `cs` reads it (`Relation.Eval.feedAt`), each kid
/// one step below both. Null where a step does not reach a slot.
fn callNodeAt(s: *Sink, call: u32, which: u32, c: Contract.Id, n: Contract.Node, cs: PathId, tags: u32, q: PathId, above: bool, out: Put.ResList) Error!?Contract.Node {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const t = &e.contracts.trees;
    const key: [6]u32 = .{ 2, call, which, n, f.places.pathPlace(q).int(), tags };
    // Below an open node a slot's key reads it too: no subtree is shared.
    if (!above) if (PutMemo.get(s, key)) |m| return if (m == none) 0 else if (m == none - 1) null else m;
    // Every kid's step reaches a slot of both.
    const kids = try gpa.dupe([2]u32, t.kids(n));
    defer gpa.free(kids);
    const at = try gpa.alloc([2]PathId, kids.len);
    defer gpa.free(at);
    for (kids, at) |k, *a| {
        const st = Step.fromWord(k[0]);
        if (st.kind == .level) return PutMemo.fail(s, key, above);
        a.* = .{ (try f.places.extend(gpa, f.gc(), cs, st)) orelse return PutMemo.fail(s, key, above), (try f.places.extend(gpa, f.gc(), q, st)) orelse return PutMemo.fail(s, key, above) };
    }
    if (!above) try s.nodes.put(gpa, key, none);
    try f.charge(.inspection, 1);
    try Building.begin(s, q);
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
        if (a.kind == .fresh or a.kind == .top or a.kind == .shared or a.kind == .host) try e.ev.arrivalLeaves(call, c, a, &.{}, &ls) else if (!keyed) {
            keyed = true;
            try ls.appendSlice(gpa, try e.ev.instAt(call, cs, which));
        }
        for (ls.items) |x| if (try f.withTags(x, tags)) |y| try describeLeaf(s, y, q, true, out);
    }
    // Open: atoms and calls' results hold below it; anything else is its
    // projection at the slot, and each slot below through that slot's key.
    for (opens) |a0| {
        // At a family's payload, all of it at every depth (§2.1, *The exit rule*).
        const a = Subtree.wholeAt(f.places, a0, cs) orelse a0;
        ls.clearRetainingCapacity();
        try e.ev.arrivalLeaves(call, c, a, &.{}, &ls);
        // What holds below the slot: an arrival by structure is the
        // argument's whole subtree there (`Relation.Eval.feedAt`).
        var below: std.ArrayList(u32) = .empty;
        defer below.deinit(gpa);
        var da = a;
        da.deep = true;
        if (a.kind == .param and !a.deep) try e.ev.arrivalLeaves(call, c, da, &.{}, &below) else try below.appendSlice(gpa, ls.items);
        var atoms: std.ArrayList(u32) = .empty;
        defer atoms.deinit(gpa);
        var uniform = true;
        for (below.items) |x| if (!try e.ev.uniformAtoms(x, &atoms)) {
            uniform = false;
            break;
        };
        var calls = true;
        for (below.items) |x| if (!e.ev.expandable(f.leafAt(x))) {
            calls = false;
        };
        // A projection with nothing at the slot itself (a record's, a
        // constructor's) still has its parts below it.
        if ((below.items.len != 0 and (uniform or calls)) or a.kind == .fresh or a.kind == .top or a.kind == .shared or a.kind == .host) {
            for (if (uniform) atoms.items else below.items) |x| if (try f.withTags(x, tags)) |y| {
                if (f.places.kind(f.places.pathPlace(q)) == .@"var") try describeLeaf(s, y, q, true, out) else try describeWide(s, y, q, out);
            };
            continue;
        }
        // An argument's part read by structure: its value described at the
        // slot, lazily, by its own structure (§2.10, *Arrivals by structure*).
        const cl = f.calls.items[call];
        if (a.kind == .param and !a.deep and tags == 0 and a.j < cl.args.len) {
            try describe(s, try e.ev.valueAt(cl.args[a.j], f.slots.relWords(a.slot)), q, out);
            continue;
        }
        var all: std.ArrayList(u32) = .empty;
        defer all.deinit(gpa);
        for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, cs))) |sl| if (sl != cs.int()) try all.append(gpa, sl);
        // The result slots of every slot below `cs`: the read's column.
        const col = try ReadCols.read(s, cs, q);
        try ReadCols.fill(s, cs, q, all.items, col);
        for (all.items) |sl| {
            var ps: std.ArrayList(u32) = .empty;
            defer ps.deinit(gpa);
            try ReadCols.dests(s, col, cs, .from(sl), q, &ps);
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
            return PutMemo.fail(s, key, above);
        };
        try Put.emitPart(s, a[1], m, out);
    }
    const m = try Building.end(s);
    if (!above) try PutMemo.put(s, key, m);
    return m;
}

/// An item of a key below `prefix` (leaf `li` at slot `at`), described at
/// the result slot the steps from the prefix take `q` to.
fn describeItem(s: *Sink, col: u32, li: u32, at: u32, prefix: PathId, q: PathId, held: Held.Atoms, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const slot: PathId = .from(at & ~Relation.open_bit);
    const open = at & Relation.open_bit != 0;
    if (Held.has(held, f.leafAt(li))) return;
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(gpa);
    if (slot == prefix) try ps.append(gpa, q.int()) else {
        try ReadCols.add(s, prefix, q, col, slot.int());
        try ReadCols.dests(s, col, prefix, slot, q, &ps);
        if (ps.items.len == 0) try ps.append(gpa, q.int());
    }
    for (ps.items) |dest| {
        // A type variable's slot has no structure below it: what is open
        // there is all of it at the slot, which `arrive` keeps open.
        const wide = open and f.places.kind(f.places.pathPlace(.from(dest))) != .@"var";
        // A parameter's whole subtree is said as the read-off says one
        // (open only where its paths fold as the slot's, §2.10).
        const whole_param = wide and f.leafAt(li).kind == .ref and f.roots.items[f.leafAt(li).root].kind == .param;
        if (wide and !whole_param) try describeWide(s, try e.ev.widen(li, at), .from(dest), out) else try describeLeaf(s, if (whole_param) try e.ev.widen(li, at) else li, .from(dest), true, out);
    }
}

/// The subtree of a call or a supply at its slot `sl`, at result slot
/// `dest` and below by structure. A slot that an opaque or a type
/// variable's place holds is read on through the call's arrivals (§2.13.9,
/// *On slots*), one result slot at a time, where the result's place is not
/// its own.
fn describeCallWide(s: *Sink, l: Value.Leaf, sl: PathId, dest: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    if (try wholeAtoms(s, l, sl, dest, out)) return;
    try describeBelow(s, l.root, sl, l.tags, dest, out);
    const k = f.places.kind(f.places.pathPlace(sl));
    if ((k != .@"opaque" and k != .@"var") or f.places.pathPlace(sl) == f.places.pathPlace(dest)) return;
    for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, dest))) |qs| {
        // What arrives at `qs` by every route from `dest` (§2.1, *Every name*).
        const rels = try f.slots.relsBelow(gpa, f.account, f.places, dest, .from(qs), f.arena);
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        const known = for (rels) |rel| {
            if (f.slots.relWords(rel).len != 0 and !try e.ev.throughCall(l.root, sl, f.slots.relWords(rel), false, l.tags, 0, &ps)) break false;
        } else true;
        if (!known) {
            const all = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try Subtree.below(f.slots, gpa, f.account, f.places, sl), .tags = l.tags });
            try describeLeaf(s, all, .from(qs), true, out);
            continue;
        }
        for (ps.items) |p| try describeLeaf(s, p.leaf, .from(qs), true, out);
    }
}

/// A call's subtree at `sl` whose settled callee says only atoms at and
/// below the slot and open above it (`AtomGraft`): the open atoms above
/// said wide at `dest` and the callee's node there grafted at `dest`.
fn wholeAtoms(s: *Sink, l: Value.Leaf, sl: PathId, dest: PathId, out: Put.ResList) Error!bool {
    const e = s.e;
    const f = e.fr();
    const r = f.roots.items[l.root];
    if (r.kind != .call or l.tags != 0 or out.label != none or e.w.code.called != null) return false;
    const cl = f.calls.items[r.a];
    if (cl.contract == none or (try @import("CallFolds.zig").of(&e.ev, r.a, none)).len != 0) return false;
    if (e.ev.live) |lv| if (cl.code != none and lv.draftRes(lv.ctx, cl.code) != null) return false;
    const pk = f.places.kind(f.places.pathPlace(sl));
    if (pk == .@"var" or pk == .@"opaque" or f.places.pathPlace(sl) != f.places.pathPlace(dest)) return false;
    if (try BelowAnchors.foldsAbove(f, e.gpa(), e.ev.arena, sl)) return false; // §2.1, *One below*
    const xw = if (sl == r.path) &.{} else f.slots.relWords(try f.slots.relOf(e.gpa(), f.account, f.places, sl));
    var hits: std.ArrayList(Contract.Hit) = .empty;
    defer hits.deinit(e.gpa());
    const n = (try AtomGraft.atomsAt(f, &e.contracts.trees, e.contracts.head(cl.contract).res_root, xw, &hits)) orelse return false;
    if (!try AtomGraft.offCycles(f, dest)) return false;
    for (hits.items) |h| if (h.depth < xw.len) for (h.arrivals) |a| try Put.arriveWide(s, dest, a, out);
    try Put.emitPart(s, dest, n, out);
    // The grafted node's atoms are the call's fresh objects: `host` where an escape reaches them.
    if (try hosted(s, try f.leaf(.{ .kind = .fresh, .atom = r.a }), dest.int(), true, out)) try Put.arriveWide(s, dest, .{ .kind = .host }, out);
    return true;
}

/// What a `⊤` lies inside leaves with it: open at `q`, since no slot says where (§2.1).
fn describeOrigin(s: *Sink, l: Value.Leaf, q: PathId, out: Put.ResList) Error!void {
    if (l.kind != .top or l.root == Value.none) return;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(s.e.gpa());
    try Origin.leaves(&s.e.ev, l, &ls);
    for (ls.items) |x| try describeWide(s, x, q, out);
}

/// Leaf `li` at result slot `q` and, by structure, at every slot below it.
fn describeWide(s: *Sink, li: u32, q: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    if (try hosted(s, li, q.int(), true, out)) try Put.arriveWide(s, q, .{ .kind = .host }, out);
    switch (l.kind) {
        .site, .fresh => try Put.arriveWide(s, q, try Made.made(s, l), out),
        .shared => try Put.arriveWide(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        .top, .loan => {
            try Put.arriveWide(s, q, .{ .kind = .top }, out);
            try describeOrigin(s, l, q, out);
        },
        .host => try Put.arriveWide(s, q, .{ .kind = .host }, out),
        .answer => try Put.arriveWide(s, q, try Made.answer(s, l.atom, l.extra, l.whole), out),
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
                try Replay.replay(gpa, f.account, f.places, r.path, first[0..k], &ps);
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
                        try e.ev.expandRouted(sub, &xs);
                        for (xs.items) |x| {
                            try describeLeaf(s, x, q, true, out);
                            for (qs_all) |qs| try describeLeaf(s, x, .from(qs), true, out);
                        }
                    },
                    .param => {
                        const pk = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        const a: Contract.Arrival = .{ .kind = .param, .j = r.a, .slot = rels[i], .deep = Slots.isSub(sl) or pk == .@"var" or pk == .@"opaque", .path = Slots.pathOf(sl).int() };
                        try Put.arrive(s, q, a, out);
                        for (qs_all) |qs| try Put.arrive(s, .from(qs), a, out);
                    },
                    .cb => {
                        const crel = (try f.slots.relUnder(gpa, f.account, f.places, r.path, Slots.pathOf(sl))) orelse Slots.root;
                        const a = try Made.answer(s, r.a, crel, PastPayload.answerWhole(f.places, sl));
                        try Put.arrive(s, q, a, out);
                        for (qs_all) |qs| try Put.arrive(s, .from(qs), a, out);
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
                try Replay.replay(gpa, f.account, f.places, q, w[b..], &ps);
                if (ps.items.len == 0) try ps.append(gpa, q.int());
                for (ps.items) |dest| switch (r.kind) {
                    .param => {
                        // An opaque or a type variable's slot holds anything
                        // below it: where the result's place is not its own,
                        // all of it arrives at each result slot (§2.13.9),
                        // never by steps the slot cannot take.
                        const pk = f.places.kind(f.places.pathPlace(Slots.pathOf(sl)));
                        const wild = pk == .@"var" or pk == .@"opaque";
                        // Open away from its own slot, a cycle with a middle would fold it
                        // out of its words (`LevelWide`): all of it at each slot, too.
                        const away = Slots.pathOf(sl).int() != dest and LevelTargets.hasMiddle(f.places, f.places.pathPlace(.from(dest)));
                        const a: Contract.Arrival = .{ .kind = .param, .j = r.a, .slot = rels[i], .deep = wild or away, .path = Slots.pathOf(sl).int() };
                        if ((wild and f.places.pathPlace(Slots.pathOf(sl)) != f.places.pathPlace(.from(dest))) or away) {
                            for (f.slots.items(try Subtree.belowAll(f.slots, gpa, f.account, f.places, .from(dest)))) |qs| try Put.arrive(s, .from(qs), a, out);
                        } else if (whole or Slots.isSub(sl)) try Put.arriveWide(s, .from(dest), a, out) else try Put.arrive(s, .from(dest), a, out);
                    },
                    .cb => {
                        const crel = (try f.slots.relUnder(gpa, f.account, f.places, r.path, Slots.pathOf(sl))) orelse Slots.root;
                        const a = try Made.answer(s, r.a, crel, PastPayload.answerWhole(f.places, sl));
                        if (whole or Slots.isSub(sl)) try Put.arriveWide(s, .from(dest), a, out) else try Put.arrive(s, .from(dest), a, out);
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

fn describeOne(s: *Sink, l: Value.Leaf, r: Value.Root, sl: u32, at: PathId, out: Put.ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    switch (r.kind) {
        .param => {
            const deep = f.places.kind(f.places.pathPlace(.from(sl))) == .@"var";
            try Put.arrive(s, at, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = deep, .path = sl }, out);
        },
        .cb => {
            const rel = (try f.slots.relUnder(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
            try Put.arrive(s, at, try Made.answer(s, r.a, rel, PastPayload.answerWhole(f.places, sl)), out);
        },
        .call, .supply => {
            const one = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{sl}), .tags = l.tags });
            // Once a slot; a subtree described once per place has its memo.
            if ((try s.described.getOrPut(gpa, try Building.describedKey(s, one, at, out))).found_existing) return;
            // The callee's arrivals there, its parameters renamed, never
            // replayed onto the arguments (`CallGraft`, §2.10).
            if (r.kind == .call and l.tags == 0 and e.w.code.called == null) {
                var arrs: std.ArrayList(Contract.Arrival) = .empty;
                defer arrs.deinit(gpa);
                if (try CallGraft.slotArrivals(&e.ev, r.a, .from(sl), &arrs)) {
                    for (arrs.items) |x| try Put.arrive(s, at, x, out);
                    // Its fresh arrivals are the call's objects: `host` where an escape reaches them.
                    for (arrs.items) |x| if (x.kind == .fresh) {
                        if (try hosted(s, try f.leaf(.{ .kind = .fresh, .atom = r.a }), at.int(), false, out)) try Put.arrive(s, at, .{ .kind = .host }, out);
                        break;
                    };
                    return;
                }
            }
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try expandFor(e, one, .{ .kind = .describe, .a = out.label, .b = at.int(), .c = out.k, .tags = l.tags, .key = out.key }, &ls);
            for (ls.items) |x| try describeLeaf(s, x, at, true, out);
        },
    }
}

/// The effects of leaf `li` on the frame's parameters: each parameter slot it names
/// (expanded through calls), as `(j, slot)`; a label's escaped answer escapes its function.
fn paramEffects(s: *Sink, li: u32, deep: bool, out: Put.EffList) Error!void {
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
        if (l.kind == .answer and out == .writes) _ = try Needs.publish(s, l.atom, 0, l.extra, deep or l.whole);
        if (l.kind == .answer and out == .escapes) _ = try Contract.Draft.addEffect(Put.effList(s, out), s.arena, .{ .j = f.cbs.items[l.atom].j, .slot = f.cbs.items[l.atom].slot, .deep = true });
        if (out == .escapes and try Made.selfEscape(s, l)) continue;
        if (out == .escapes and l.kind == .top and l.root != Value.none) try Origin.leaves(&e.ev, l, &stack);
        // An escaping loan lets what it lends escape: its cell's contents, `π_j◆` (§2.13.7, #2403).
        if (out == .escapes and l.kind == .loan) try stack.append(gpa, l.atom);
        if (l.kind != .ref) continue;
        const r = f.roots.items[l.root];
        switch (r.kind) {
            .param => {
                // A whole subtree (`↓p`, §2.3.1): one deep effect at `p`.
                for (f.slots.elems(l.slots)) |sl| {
                    if (Slots.isNot(sl)) continue;
                    var eff: Contract.Effect = .{ .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, Slots.pathOf(sl)), .deep = deep or Slots.isSub(sl) };
                    // An edit in place of what a cell holds is deep at its `◆`: never a cell operation (§2.13.7).
                    // So is a write at a family's payload: a `var` whose base no step can name.
                    eff.deep = eff.deep or (out == .writes and ((!l.at_pos and Cells.endsInContents(f.slots, eff.slot)) or f.places.kind(f.places.pathPlace(Slots.pathOf(sl))) == .@"var"));
                    if (try Contract.Draft.addEffect(Put.effList(s, out), s.arena, eff)) if (out != .reads) if (e.solver) |sv| if (!(out == .writes and f.records and @import("FieldReads.zig").told(s.d.writes.items, eff, false))) try sv.effFact(sv.ctx, e.x, out == .writes, eff);
                }
            },
            .call, .supply => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try expandFor(e, x, .{ .kind = .effect, .a = @backingInt(out), .b = @intFromBool(deep), .tags = l.tags }, &ls);
                try stack.appendSlice(gpa, ls.items);
            },
            // What the label answers leaves, and the code it runs is not told (#2059).
            .cb => if (out == .escapes) {
                s.d.labels.items[try s.labelIndex(r.a)].answer_left = true;
            } else if (out == .writes) for (f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots))) |sl| {
                // Deep where a step names no level (a payload's `var`), and whole where no slot names it.
                const rel = try f.slots.relUnder(gpa, f.account, f.places, r.path, .from(sl));
                _ = try Needs.publish(s, r.a, 0, rel orelse Slots.root, deep or rel == null or f.places.kind(f.places.pathPlace(.from(sl))) == .@"var");
            },
        }
    }
}

/// An escape made while the read-off is under way. An own leaf said that
/// it reaches is `host` where it was said, or, said inside a subtree
/// described once per place, at every slot of its list (§2.10).
fn escapeFacts(e: *Evaluation, leaf: u32) Error!void {
    if (@import("Mutate.zig").on(.contract_no_escapes)) return;
    try paramEffects(&e.sink, leaf, true, .escapes);

    const s = &e.sink;
    const from = try s.host.sync(&e.ev, e.escapes.items);
    var i: usize = 0;
    if (from != s.host.escs.items.len) while (i < s.host.told.items.len) : (i += 1) {
        const t = s.host.told.items[i];
        if (!try s.host.reaches(&e.ev, e.escapes.items, from, t.leaf, Distinct.overlap)) continue;
        if (t.wide and !t.built) {
            try Put.wideLevels(s, .from(t.q), .{ .kind = .host }, .{ .label = t.label, .k = t.k, .key = t.key });
            continue;
        }
        try Put.host(s, .from(t.q), t.built, .{ .label = t.label, .k = t.k, .key = t.key });
    };
}

/// Whether an escape of the frame reaches own leaf `li` (a call's is said by
/// its key's), said at `q` (`none`: not kept), noted for a later escape (§2.10).
fn hosted(s: *Sink, li: u32, q: u32, wide: bool, out: Put.ResList) Error!bool {
    const e = s.e;
    try Put.handed(s, li, out);
    if (!Host.own(e.fr(), li) or e.ev.expandable(e.fr().leafAt(li))) return false;
    try s.host.tell(e.gpa(), .{ .leaf = li, .q = q, .label = out.label, .k = out.k, .key = out.key, .wide = wide, .built = s.building.items.len != 0 or q == none });
    _ = try s.host.sync(&e.ev, e.escapes.items);
    return s.host.reaches(&e.ev, e.escapes.items, 0, li, Distinct.overlap);
}

/// A demand's written parameter slots (whatever its verdict). A record's write that a label's hold refuses is none: it is refused where it is made (§2.11.5).
fn demandFacts(e: *Evaluation, di: usize) Error!void {
    const dm = e.demands.items[di];
    if (@import("Mutate.zig").on(.contract_no_writes) or (dm.record and dm.kept)) return;
    if (dm.graft[0] != Ids.none_int) {
        const eff: Contract.Effect = .{ .j = dm.graft[0], .slot = dm.graft[1], .node = dm.graft[2] };
        if (try Contract.Draft.addEffect(&e.sink.d.writes, e.sink.arena, eff)) if (e.solver) |sv| try sv.effFact(sv.ctx, e.x, true, eff);
        return;
    }
    for (e.w.leavesOfRun(dm.targets)) |t| if (!dm.record or !try @import("FieldReads.zig").writes(&e.sink, t, dm.fields)) try paramEffects(&e.sink, t, dm.deep, .writes);
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
    d.* = .{ .arity = code.arity() };
    e.sink = .{ .e = e, .d = d, .arena = arena };
    e.hooks = hooks;
    e.facts_on = true;
    const s = &e.sink;
    const rpath = try f.places.rootPath(gpa, code.result_place);
    const rv = f.val(w.result);
    d.flags.returns = rv.kind != .bot;
    d.flags.cross = !Slots.holdsAny(f.places, rpath);
    if (d.flags.returns and !d.flags.cross and !@import("Mutate.zig").on(.contract_no_res)) try describe(s, w.result, rpath, .{});
    // Reads: every local whose value is a parameter's, in one pass (§2.3.4).
    const pass = f.sets.newPass();
    if (code.called) |cd| for (0..cd.own_places.len) |j| {
        _ = try Contract.Draft.addEffect(&d.reads, arena, .{ .j = @intCast(j), .slot = Slots.root, .deep = true });
    };
    for (w.uses.items[w.last.uses..]) |u| {
        if (@import("Mutate.zig").on(.contract_no_reads)) break;
        const b = w.bindings[u.local];
        if (b.value == none) continue;
        const lroot = try f.places.rootPath(gpa, try e.ctx.placeOfLocal(e.ctx.ctx, u.local));
        const rel = (try f.slots.relUnder(gpa, f.account, f.places, lroot, u.path)) orelse Slots.root;
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
        try readsDeep(s, b.value, f.slots.relWords(rel), pass);
    }
    try @import("FieldReads.zig").events(w, s, paramEffects); // a record's object, read by a field read or an update (§2.7)
    // Writes: every demand's parameter targets, whatever its verdict.
    for (0..e.demands.items.len) |di| try demandFacts(e, di);
    // Escapes, deep. By index: an escape made meanwhile is read off when it is made.
    const n_esc = e.escapes.items.len;
    for (0..n_esc) |i| try paramEffects(s, e.escapes.items[i].leaf, true, .escapes);
    // Labels: the direct ones with their arguments, the passed-on ones with
    // their callees' supplies.
    const cb_pass = f.sets.newPass();
    for (f.cbs.items[w.last.cbs..], w.last.cbs..) |cb, ci| {
        if (cb.inst != none) {
            const at = try s.labelIndex(@intCast(ci));
            const dl = &d.labels.items[at];
            dl.calls = if (cb.calls > 1 or dl.calls == .many) .many else if (dl.calls == .none) .once else .many;
            for (cb.args, 0..) |a, k| {
                _ = try d.labels.items[at].supplyOf(arena, @intCast(k));
                const ap = f.val(a).place;
                const root = if (ap != .none) try f.places.rootPath(gpa, ap) else rpath;
                try describe(s, a, root, .{ .label = at, .k = @intCast(k) });
                // A supply is read, all of it, temporary or not (§2.11.3 *a supply is read*, #2297).
                if (!@import("Mutate.zig").on(.supply_no_reads)) try readsDeep(s, a, &.{}, cb_pass);
            }
        }
    }
    for (e.passes.items) |p| {
        const at = try s.labelIndex(p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        const dl = &d.labels.items[at];
        // Calls add up: a label the frame calls and also hands on, or hands to
        // two calls, may run more than once per activation, whatever each
        // source says alone. Inside a known code an outer label runs, it runs as often (#1721).
        const lc: Contract.Calls = if (lab.calls != .none and Outward.outwardMany(e, p[1])) .many else lab.calls;
        dl.calls = if (lc == .none) dl.calls else if (dl.calls == .none) lc else .many;
        dl.answer_left = dl.answer_left or lab.answer_left;
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
                    try Replay.replay(gpa, f.account, f.places, try f.places.rootPath(gpa, site.items[su.k]), es.wordsOf(rs), &ps);
                    // A row read at a wider site is each of its steps there, the argument's own (§2.1).
                    const aw = f.slots.relWords(a.slot);
                    const paired = SlotWords.endsInRow(es.wordsOf(rs)) and SlotWords.endsInRow(aw);
                    for (ps.items) |p2| {
                        const st = f.places.pathStep(.from(p2)).word();
                        const at_step = if (paired) try e.ev.valueAt(call.args[a.j], try std.mem.concat(e.ev.arena, u32, &.{ aw[0 .. aw.len - 1], &.{st} })) else v;
                        try describe(s, at_step, .from(p2), .{ .label = at, .k = su.k });
                    }
                }
            };
            _ = try d.labels.items[at].supplyOf(arena, su.k);
            for (es.items.items) |x| {
                const rel = f.slots.rels.find(es.wordsOf(x)) orelse try f.slots.relOfWords(gpa, f.account, f.places, es.wordsOf(x));
                // Each arrival's parts, planned first: an open entry whose every part is written by
                // its value's structure, each at its own key, leaves nothing open at its own (§2.1,
                // *An arrival's level*). Marked open, it would also open every plain arrival there.
                var parts: std.ArrayList(SplitRow.Part) = .empty;
                for (x.arrivals) |a| {
                    // A passed-on supply is read at the argument, as a direct one is.
                    if (a.kind == .param and a.j < call.args.len and !@import("Mutate.zig").on(.supply_no_reads)) try readsDeep(s, try e.ev.valueAt(call.args[a.j], f.slots.relWords(a.slot)), &.{}, cb_pass);
                    try SplitRow.plan(&e.ev, p[1], es.wordsOf(x), x.open and !at_site, a, e.ev.arena, &parts);
                }
                const placed = for (parts.items) |pt| {
                    if (pt.place == .none) break false;
                } else parts.items.len != 0;
                if (at_site and !SupplyAnswers.staysOpen(x)) try SupplyAnswers.closesAtSite(e, su, x, call.args.len) else if (x.open and !placed) try Contract.Draft.markOpen(&(try d.labels.items[at].supplyOf(arena, su.k)).res, arena, rel);
                for (parts.items) |pt| try supplyPart(s, p[1], pt, .{ .label = at, .k = su.k }, rel);
            }
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            for (e.contracts.effectsOf(su.kept)) |kp| _ = try Contract.Draft.addEffect(&sup.kept, arena, kp);
        }
    }
}

/// One part of a supply's arrival at its key (`SplitRow`, §2.1, *An arrival's level*).
fn supplyPart(s: *Sink, q: u32, pt: SplitRow.Part, out: Put.ResList, entry: Slots.Rel) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const key = f.slots.rels.find(pt.key) orelse try f.slots.relOfWords(gpa, f.account, f.places, pt.key);
    const res = try Put.resList(s, out);
    if (key != entry) try Contract.Draft.markOpen(res, s.arena, key);
    if (pt.by_slot) {
        try f.charge(.edge, 1);
        _ = try Contract.Draft.addArrival(res, s.arena, key, pt.a);
        return;
    }
    if (pt.place != .none) return describe(s, pt.v, try f.places.rootPath(gpa, pt.place), .{ .label = out.label, .k = out.k, .key = key });
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    {
        const saved = e.ev.cur_sub;
        e.ev.cur_sub = if (e.solver != null) .{ .kind = .supply, .a = out.label, .b = out.k, .c = key, .key = out.key } else null;
        defer e.ev.cur_sub = saved;
        try FnRun.supplyLeaves(&e.ev, q, pt.a, &ls);
    }
    for (ls.items) |l| try supplyArrive(s, l, key, out);
}

/// Every parameter slot value `v` holds at `words` and below, read (a local's use, or a supply).
fn readsDeep(s: *Sink, v: u32, words: []const u32, pass: u32) Error!void {
    const e = s.e;
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(e.gpa());
    // A choice is read by route sets, a value two arms reach once.
    if (e.fr().val(v).kind == .alt) {
        const req = [1]Routed.Req{.{ .words = words, .deep = true, .out = &ps }};
        try Routed.project(&e.ev, v, &req, 0, pass);
    } else {
        e.ev.pass = pass;
        defer e.ev.pass = 0;
        try e.ev.project(v, words, true, 0, 0, &ps);
    }
    for (ps.items) |p| try paramEffects(s, p.leaf, true, .reads);
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
        if (k == .@"var" or k == .@"opaque" or !try Eval.acyclicBelow(s, f.places.pathPlace(sl))) break :whole;
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
        // A read is one whatever route reaches it: the walk by route sets.
        const req = [1]Routed.Req{.{ .words = es.wordsOf(x), .deep = x.open, .out = &ps }};
        try Routed.project(&e.ev, v, &req, 0, if (x.open) pass else 0);
        for (ps.items) |p| if (x.open or !try @import("FieldReads.zig").through(s, p.leaf, x.arrivals)) try paramEffects(s, p.leaf, x.open, .reads);
    }
}

/// A leaf delivered to a consumer of the read-off (§2.12 *Deliveries*).
pub fn deliver(e: *Evaluation, sub: Relation.Sub, x: u32, at: u32) Error!void {
    const f = e.fr();
    const y = (try f.withTags(x, sub.tags)) orelse return;
    switch (sub.kind) {
        .describe => try describeLeaf(&e.sink, y, .from(sub.b), true, .{ .label = sub.a, .k = sub.c, .key = sub.key }),
        .describe_below => try describeItem(&e.sink, try ReadCols.read(&e.sink, .from(sub.d), .from(sub.b)), y, at, .from(sub.d), .from(sub.b), try Held.atoms(e.fr(), try Put.resList(&e.sink, .{ .label = sub.a, .k = sub.c, .key = sub.key }), try SupplyKey.relAt(&e.sink, .from(sub.b), sub.key)), .{ .label = sub.a, .k = sub.c, .key = sub.key }),
        .describe_whole => try describeEach(&e.sink, y, .from(sub.b), .{ .label = sub.a, .k = sub.c, .key = sub.key }),
        .forward_below => unreachable,
        .effect => try paramEffects(&e.sink, y, sub.b != 0, @fromBackingInt(@intCast(sub.a))),
        .supply => try supplyArrive(&e.sink, y, sub.c, .{ .label = sub.a, .k = sub.b, .key = sub.key }),
        .escape => try Eval.addEscape(e, y, sub.a),
        .escape_fn => unreachable,
        .forward => unreachable,
    }
}

/// A leaf's arrivals, all at supply slot `rel`: a parameter's slots, an
/// answer's label, what a call or a supply comes from.
fn supplyArrive(s: *Sink, li: u32, rel: Slots.Rel, out: Put.ResList) Error!void {
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
        if (try hosted(s, x, none, l.kind == .ref, out)) _ = if (l.kind == .ref) try Contract.Draft.addWide(try Put.resList(s, out), s.arena, rel, .{ .kind = .host }) else try Contract.Draft.addArrival(try Put.resList(s, out), s.arena, rel, .{ .kind = .host });
        const a: Contract.Arrival = switch (l.kind) {
            .site, .fresh => try Made.made(s, l),
            .shared => .{ .kind = .shared, .j = l.atom, .slot = l.extra },
            .top, .loan => blk: {
                if (l.kind == .top and l.root != Value.none) try Origin.leaves(&s.e.ev, l, &stack);
                break :blk .{ .kind = .top };
            },
            .host => .{ .kind = .host },
            .answer => try Made.answer(s, l.atom, l.extra, l.whole),
            .recons => unreachable,
            .ref => {
                const r = f.roots.items[l.root];
                switch (r.kind) {
                    .param => for (f.slots.elems(l.slots)) |el| {
                        if (Slots.isNot(el)) continue;
                        const sl = Slots.pathOf(el);
                        _ = try Contract.Draft.addArrival(try Put.resList(s, out), s.arena, rel, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, sl), .deep = Slots.isSub(el) or f.places.kind(f.places.pathPlace(sl)) == .@"var" or (SlotWords.endsInRow(f.slots.relWords(rel)) and !SlotWords.endsInRow(f.slots.relWords(try f.slots.relOf(gpa, f.account, f.places, sl)))), .path = sl.int() });
                    },
                    .cb => for (f.slots.items(try Subtree.writeOut(f.slots, gpa, f.account, f.places, l.slots))) |sl| {
                        const below = (try f.slots.relUnder(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
                        _ = try Contract.Draft.addArrival(try Put.resList(s, out), s.arena, rel, try Made.answer(s, r.a, below, PastPayload.answerWhole(f.places, sl)));
                    },
                    .call, .supply => {
                        var ls: std.ArrayList(u32) = .empty;
                        defer ls.deinit(gpa);
                        try expandFor(e, x, .{ .kind = .supply, .a = out.label, .b = out.k, .c = rel, .tags = l.tags, .key = out.key }, &ls);
                        try stack.appendSlice(gpa, ls.items);
                    },
                }
                continue;
            },
        };
        _ = try Contract.Draft.addArrival(try Put.resList(s, out), s.arena, rel, a);
    }
}
