//! L7: the one relation and the distinct check (`docs/design/ownership-v2.md`
//! §2.9): the selection of a parameter at a slot set, a call's separation
//! (its callee's `res_cond` on its arguments), the distinct check over the
//! objects a value reaches, and the relation of two leaves. It reads a
//! value's leaves and a call's instantiation through `Relation.Eval`, which
//! keeps the instantiations and separations of one evaluation.
//!
//! Obligations kept here: the relation's half of O3 (two positions of one
//! root are apart only under the root's separation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const PlaceBelow = @import("PlaceBelow.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
pub const Fed = @import("Fed.zig");
const Taken = @import("Taken.zig");
const AnswerKeep = @import("AnswerKeep.zig");
const HeldBy = @import("HeldBy.zig");
const FedCall = @import("FedCall.zig");
const Entries = @import("Entries.zig");
const OneSet = @import("OneSet.zig");
const RouteWalk = @import("RouteWalk.zig");
const CallGraft = @import("CallGraft.zig");
const ApartPlain = @import("ApartPlain.zig");
const Graft = @import("Graft.zig");
const PlainReach = @import("PlainReach.zig");
const EntryExpand = @import("EntryExpand.zig");
const Answers = @import("Answers.zig");
const AnswerCall = @import("AnswerCall.zig");
const AnsOcc = @import("AnsOcc.zig");
const Coexist = @import("Coexist.zig");
const Chains = @import("Chains.zig");
const Ends = @import("Ends.zig");
const AtomSets = @import("AtomSets.zig");
const SelfFed = @import("SelfFed.zig");

const Error = Relation.Error;
const Cond = Contract.Cond;
const Eval = Relation.Eval;
const Ov = Relation.Ov;
const Proj = Relation.Proj;
const Leaf = Value.Leaf;
const Step = Place.Step;
const none: u32 = Ids.none_int;

/// The selection of parameter `j` at the slots of `set` (paths under its root).
pub fn sel(e: *Eval, j: u32, set: Slots.SetId) Error!Cond {
    return selOf(e, j, set, false);
}

/// The selection of parameter `j` at `set`, its occurrences apart
/// only (§2.9.1) when `apart`.
pub fn selOf(e: *Eval, j: u32, set: Slots.SetId, only_apart: bool) Error!Cond {
    const items = e.f.slots.elems(set);
    try e.charge(.cond, @intCast(1 + items.len));
    var out: std.ArrayList(u64) = .empty;
    for (items) |s| if (try occOf(e, j, s, only_apart)) |o| try out.append(e.arena, o);
    return Cond.of(e.account(), out.items);
}

/// The occurrence of parameter `j` at set element `s`: a symbol `↓p`
/// (§2.3.1) is the deep occurrence at `p`, and so is an explicit slot no
/// step below can name (`deepAt`); an exclusion asks nothing less (null:
/// the symbol's occurrence asks it).
fn occOf(e: *Eval, j: u32, s: u32, only_apart: bool) Error!?u64 {
    if (Slots.isNot(s)) return null;
    const p = Slots.pathOf(s);
    const r = try e.f.slots.relOf(e.gpa(), e.account(), e.places(), p);
    const o = if (Slots.isSub(s)) Contract.occDeep(Contract.occ(j, r)) else try deepAt(e, p, Contract.occ(j, r));
    return if (only_apart) o | Contract.apart_bit else o;
}

/// Occurrence `o` at slot path `s`, deep where no step below `s` can be
/// named (a type variable's or an opaque place, §2.9.1; a function's, whose
/// code reads its captures, #1956).
fn deepAt(e: *Eval, s: Slots.PathId, o: u64) Error!u64 {
    if (@import("Mutate.zig").on(.deep_at_closure_off) and e.places().kind(e.places().pathPlace(s)) == .closure) return o;
    if (@import("Mutate.zig").on(.deep_at_off)) return o;
    return switch (e.places().kind(e.places().pathPlace(s))) {
        .@"var", .@"opaque", .closure => Contract.occDeep(o),
        else => o,
    };
}

/// Whether a leaf names a family: one of its slots is below a `[*]` or a
/// `⟲`, where many objects sit (§2.3.1); elsewhere a position's slot
/// holds one object.
fn isFamily(e: *Eval, l: Leaf) Error!bool {
    for (e.f.slots.elems(l.slots)) |s| {
        if (Slots.isNot(s)) continue;
        if (Slots.isSub(s)) {
            if (try PlaceBelow.familyBelow(e.gpa(), e.account(), e.places(), Slots.pathOf(s))) return true;
        } else if (e.f.places.isSummary(.from(s))) return true;
    }
    return false;
}

/// `Sep` of a leaf's own objects (a family's): a parameter's selection,
/// a call's instantiated condition, an expansion's distinct check.
fn sepLeaf(e: *Eval, li: u32) Error!Cond {
    const l = e.f.leafAt(li);
    const r = e.f.roots.items[l.root];
    return switch (r.kind) {
        .param => sel(e, r.a, l.slots),
        .call => instCond(e, r.a),
        .supply, .cb => blk: {
            if (!e.expandable(l)) break :blk Cond.unprovable;
            var ps: std.ArrayList(Proj) = .empty;
            defer ps.deinit(e.gpa());
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(e.gpa());
            try e.expand(li, &ls);
            for (ls.items, 0..) |x, k| try ps.append(e.gpa(), .{ .leaf = x, .route = @intCast(k + 1) });
            break :blk distinct(e, ps.items, false);
        },
    };
}

/// The callee's `res_cond` on call `call`'s arguments, once per call; a
/// cycle through it reads `no`. A virtual call handed its own answer reads
/// it through its twin (`SelfFed`, §2.11.3).
pub fn instCond(e: *Eval, call: u32) Error!Cond {
    if (@import("Mutate.zig").on(.inst_cond_yes)) return Cond.yes;
    try condStates(e);
    if (e.contractOf(call)) |c| if (!e.contracts.head(c).res_read.no) hoped(e);
    // Each call once a mode: an ask may fall back to reading, and a strict
    // run is exactly the check before it (§2.11.3).
    const at = 3 * call + modeOf(e);
    switch (e.cond_state.items[at] & 3) {
        2 => return e.cond_of.items[at],
        1 => return Cond.unprovable,
        else => {},
    }
    e.cond_state.items[at] |= 1;
    var got = Cond.unprovable;
    if (e.contractOf(call)) |c| {
        const rc = try e.contracts.resCond(e.arena, c, e.read_mode == .reading);
        got = try instSel(e, rc, call);
        if (got.no) if (try SelfFed.of(e, call, FedCall)) |tw| {
            got = try instSelOn(e, rc, call, tw.args, null);
        };
    }
    e.cond_state.items[at] ^= 3; // in progress → done, `mixed_on` kept
    e.cond_of.items[at] = got;
    return got;
}

/// A known code's `req` on its virtual call `call` (§2.11.2 item 4): where
/// it fails on the call's own arguments and the label is handed its own
/// answer, on the twin, with the answer's separation (`SelfFed`, §2.11.3).
pub fn reqOn(e: *Eval, c: Cond, call: u32) Error!Cond {
    const got = try instSel(e, c, call);
    if (!got.no) return got;
    const tw = (try SelfFed.of(e, call, FedCall)) orelse return got;
    const r = e.f.roots.items[e.f.calls.items[call].root];
    const answer = try e.f.leaf(.{ .kind = .ref, .root = e.f.calls.items[call].root, .pos = r.pos, .slots = try Subtree.below(e.f.slots, e.gpa(), e.account(), e.places(), r.path) });
    if (@import("Mutate.zig").on(.self_fed_answer_free)) return instSelOn(e, c, call, tw.args, null);
    return Cond.conj(e.arena, e.account(), try instSelOn(e, c, call, tw.args, null), try distinct(e, &.{.{ .leaf = answer, .route = 1 }}, false));
}

fn condStates(e: *Eval) Error!void {
    while (e.cond_state.items.len < 3 * e.f.calls.items.len) {
        try e.cond_state.append(e.gpa(), 0);
        try e.cond_of.append(e.gpa(), .{});
    }
}

/// A callee's condition (a selection over its parameters) on call
/// `call`'s arguments (§2.9.3's routed rule): every object at a selected
/// occurrence, projected, distinct from every other.
pub fn instSel(e: *Eval, c: Cond, call: u32) Error!Cond {
    return instSelFeed(e, c, call, null);
}

/// `instSel` at a call that may pass the frame's label on (`feed`, §2.11.3,
/// *a label's answer handed back to it*): `Fed` reads the label's own answer
/// handed back as what its call was handed, and decides `fed` occurrences.
pub fn instSelFeed(e: *Eval, c0: Cond, call: u32, feed: ?Fed.Feed) Error!Cond {
    return instSelOn(e, c0, call, null, feed);
}

/// `instSelFeed` on `args` in place of the call's own, when given.
fn instSelOn(e: *Eval, c0: Cond, call: u32, args: ?[]const u32, feed: ?Fed.Feed) Error!Cond {
    if (@import("Mutate.zig").on(.inst_sel_yes)) return Cond.yes;
    if (c0.no) return Cond.unprovable;
    if (c0.sel.len == 0) return Cond.yes;
    var fed: std.ArrayList(u64) = .empty;
    var rest: std.ArrayList(u64) = .empty;
    var own: Cond = .yes;
    var own_n: usize = 0;
    for (c0.sel) |o| own_n += @intFromBool(!Contract.isFed(o));
    for (c0.sel) |o| if (!Contract.isFed(o)) try rest.append(e.arena, o) else if (AnsOcc.is(o)) {
        if (!try AnswerCall.at(e, call, o, instCond, FedCall, &rest, &own, &fed)) return Cond.unprovable;
    } else switch (try FedCall.at(e, call, o, null)) {
        .yes => {},
        .no => return Cond.unprovable,
        .occ => |x| try fed.append(e.arena, x),
    };
    if (rest.items.len != own_n) return withFed(e, try Cond.conj(e.arena, e.account(), own, try instSelOn(e, try Cond.of(e.account(), rest.items), call, args, feed)), fed.items);
    const c: Cond = .{ .sel = rest.items };
    if (c.sel.len == 0) return withFed(e, Cond.yes, fed.items);
    // Arguments that are the caller's parameters whole: renamed (`CallGraft`).
    if (try CallGraft.sel(e, c, call)) |rc| return withFed(e, rc, fed.items);
    const g = e.gpa();
    var cl = e.f.calls.items[call];
    if (args) |a| cl.args = a;
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(g);
    // A parameter asked deep apart and plain below: its objects part by part.
    var aps: std.ArrayList(Proj) = .empty;
    defer aps.deinit(g);
    var plains: std.ArrayList(Proj) = .empty;
    defer plains.deinit(g);
    defer e.parts = false;
    for (c.sel) |o| if (Contract.occParam(o) >= cl.args.len) return Cond.unprovable;
    const got = try e.arena.alloc(std.ArrayList(Proj), c.sel.len);
    for (got) |*x| x.* = .empty;
    defer for (got) |*x| x.deinit(g);
    // A literal read part by part: its plain occurrences whole first (`Graft`).
    if (Graft.plainsOnLiteral(e, c, cl)) {
        try projectAll(e, c, cl, got, true);
        var fed0: std.ArrayList(u64) = .empty;
        for (c.sel, got) |o, *gp| {
            const k = if (feed) |fd| try FedCall.supplyOf(e, call, fd.label, Contract.occParam(o)) else null;
            for (gp.items) |p| if (feed == null or !try Fed.replace(e, p, o, k, feed.?, &ps, &fed0)) try ps.append(g, .{ .leaf = p.leaf, .route = p.route, .occ = o, .routes = p.routes });
            gp.clearRetainingCapacity();
        }
        if ((try distinct(e, ps.items, true)).no) return Cond.unprovable;
        ps.clearRetainingCapacity();
    }
    try projectAll(e, c, cl, got, false);
    for (c.sel, got) |o, *gp| {
        e.parts = ApartPlain.mixed(c.sel, Contract.occParam(o));
        const to = if (!e.parts) &ps else if (Contract.isApart(o)) &aps else &plains;
        const k = if (feed) |fd| try FedCall.supplyOf(e, call, fd.label, Contract.occParam(o)) else null;
        for (gp.items) |p| if (feed == null or !try Fed.replace(e, p, o, k, feed.?, to, &fed)) try to.append(g, .{ .leaf = p.leaf, .route = p.route, .occ = o, .routes = p.routes });
    }
    // An apart and a plain projection of one place by one route are taken
    // apart by their routes; two route sets there are written out.
    if (aps.items.len != 0 and try ApartPlain.routesDiffer(e, aps.items, plains.items)) {
        try ApartPlain.writeOut(e, &aps);
        try ApartPlain.writeOut(e, &plains);
    }
    try ps.appendSlice(g, plains.items);
    try ApartPlain.withoutPlain(e, aps.items, plains.items, &ps);
    return withFed(e, try distinct(e, ps.items, true), fed.items);
}

/// `res` with the `fed` occurrences a call asks of its caller.
fn withFed(e: *Eval, res: Cond, fed: []u64) Error!Cond {
    return if (fed.len == 0 or res.no) res else Cond.conj(e.arena, e.account(), res, try Cond.of(e.account(), fed));
}

/// Each parameter's occurrences of `c` (`plain`: its plain ones only) into
/// `got`, by one walk of its argument (§2.11.2 item 3): a step they share is
/// read once, and a value several arms reach once under their routes.
fn projectAll(e: *Eval, c: Cond, cl: Value.Call, got: []std.ArrayList(Proj), plain: bool) Error!void {
    const g = e.gpa();
    const reqs = try e.arena.alloc(RouteWalk.Req, c.sel.len);
    var js: std.ArrayList(u32) = .empty;
    defer js.deinit(g);
    for (c.sel, 0..) |o, i| {
        const j = Contract.occParam(o);
        if ((plain and Contract.isApart(o)) or std.mem.indexOfScalar(u32, js.items, j) != null) continue;
        try js.append(g, j);
        var n: usize = 0;
        for (c.sel[i..], i..) |x, k| if (Contract.occParam(x) == j and !(plain and Contract.isApart(x))) {
            reqs[n] = .{ .words = e.f.slots.relWords(Contract.occRel(x)), .deep = Contract.isDeep(x), .out = &got[k] };
            n += 1;
        };
        e.parts = !plain and ApartPlain.mixed(c.sel, j);
        // Routes are per parameter: two parameters handed one value are
        // that value twice (the experiment's third requirement).
        try RouteWalk.project(e, cl.args[j], reqs[0..n], try e.routeStep(0, 0x8000_0000 | j), 0);
    }
}

/// A result's separation: as a call reads it, and, where that is `no`, with
/// its labels' answers read (§2.11.3, *a traversal's supply*).
pub fn resConds(e: *Eval, v: u32, d: anytype, recursive: bool) Error!void {
    if (@import("Mutate.zig").on(.res_conds_off)) return;
    e.read_mode = .strict;
    defer e.read_mode = .ask;
    d.res_cond = try sepOf(e, v);
    e.read_mode = .reading;
    if (d.res_cond.no and Answers.reads(e, d.labels.items.len, recursive)) d.res_read = try sepOf(e, v);
}

/// `Sep(v)`: v's components each separated, all apart.
pub fn sepOf(e: *Eval, v: u32) Error!Cond {
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    try e.leavesOf(v, 0, &ls);
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(e.gpa());
    // Each component its own route: one value placed twice is two
    // entries (the experiment's fifth requirement).
    for (ls.items, 0..) |l, k| try ps.append(e.gpa(), .{ .leaf = l, .route = @intCast(k + 1) });
    return distinct(e, ps.items, false);
}

const Ent = Entries.Ent;
const Occs = Entries.Occs;

/// Whether a callee's occurrence `o`, projected to entry leaf `li`, names
/// one object of one invocation (§2.9.3, *candidates of one object*): not
/// deep nor apart, a path of fields, tuple indices and constructor
/// arguments only, at a slot some step below can name.
fn singular(f: *Value.Frame, o: u64, li: u32) bool {
    if (Contract.isDeep(o) or Contract.isApart(o) or Contract.isFed(o)) return false;
    for (f.slots.relWords(Contract.occRel(o))) |w| switch (Place.Step.fromWord(w).kind) {
        .field, .index, .ctor_arg => {},
        else => return false,
    };
    const l = f.leafAt(li);
    return !Subtree.symbolic(f.slots, l.slots) and !Entries.wildEntry(f, .{ .leaf = li, .route = 0, .occ = o, .block = none });
}

/// Whether a callback's answer among `ents` may be another entry's object
/// (§2.9.3, #1711), for the pairs with an entry from `fresh` on: the
/// earlier pairs were asked in an earlier round. Unknown code may answer
/// any object its caller reaches, so an answer is apart from no other
/// entry but an alternative to it or one its own block vouches for.
fn answerMeets(f: *Value.Frame, ents: []const Ent, alive: []const bool, fresh: usize) Error!bool {
    if (@import("Mutate.zig").on(.answer_meets_off)) return false;
    for (ents, 0..) |en, i| {
        if (!alive[i] or !isAnswer(f, f.leafAt(en.leaf))) continue;
        for (ents[if (i >= fresh) 0 else fresh..], if (i >= fresh) 0 else fresh..) |o, k| {
            if (k == i or !alive[k]) continue;
            if ((o.block != none and o.block == en.block) or Entries.oneObject(o, en)) continue;
            if (try Entries.routesMeet(f, en, o)) return true;
        }
    }
    return false;
}

/// A mode of a call's kept condition and of a pair's row: what a condition
/// met in one must not answer another.
fn modeOf(e: *const Eval) u32 {
    return switch (e.read_mode) {
        .ask => 0,
        .strict, .hope => 1,
        .reading => 2,
    };
}

/// A `no` from here on may be another answer read (`distinct`).
fn hoped(e: *Eval) void {
    if (e.read_mode == .strict) e.read_mode = .hope;
}

fn isAnswer(f: *const Value.Frame, l: Value.Leaf) bool {
    return l.kind == .answer or (l.kind == .ref and f.roots.items[l.root].kind == .cb);
}

/// §2.9.3: every object the entries name is distinct from every other's,
/// by the factored check (never a table of pairs). The groups are kept
/// across rounds (`Entries.Rounds`): a round checks only the groups its
/// expansion changed, each for its new entries.
pub fn distinct(e: *Eval, ps: []const Proj, routed: bool) Error!Cond {
    // Where it would say `no`, a label's answers are read (`Answers`).
    var rd: Answers.Reader = .{};
    defer rd.deinit(e.gpa());
    if (e.read_mode == .reading) return check(e, ps, routed, &rd);
    if (e.read_mode != .ask) return check(e, ps, routed, null);
    e.read_mode = .strict;
    const c = check(e, ps, routed, null);
    const hope = e.read_mode == .hope;
    e.read_mode = .ask;
    if ((c catch return c).no == false or !hope) return c;
    e.read_mode = .reading;
    defer e.read_mode = .ask;
    return check(e, ps, routed, &rd);
}

fn check(e: *Eval, ps: []const Proj, routed: bool, read: ?*Answers.Reader) Error!Cond {
    if (@import("Mutate.zig").on(.distinct_yes)) return Cond.yes;
    const g = e.gpa();
    const f = e.f;
    var st: Entries.Rounds = .{};
    defer st.deinit(g);
    // The conditions met, gathered and made one at the end: a merge per
    // entry or group would cost their product (§2.9.3's linear bound).
    var occs: Occs = .{};
    defer occs.deinit(g);
    // A callee's occurrence that names one object: its entries are candidates of it.
    for (ps, 0..) |p, k| {
        if (read) |rd| if (try rd.take(e, &st, &occs, p.leaf, none, .{ none, @intCast(k), 0 })) continue;
        try st.add(g, .{ .leaf = p.leaf, .route = p.route, .occ = p.occ, .block = none, .routes = p.routes, .one = if (routed and singular(f, p.occ, p.leaf)) @intCast(k) else none }, .{ none, @intCast(k), 0 });
    }
    if (read) |rd| if (rd.failed) return Cond.unprovable;
    // A family asks its own root's separation; ⊤ and shared objects are
    // never known to be once.
    for (st.ents.items) |en| {
        const l = f.leafAt(en.leaf);
        if (isAnswer(f, l)) hoped(e);
        if (@import("Mutate.zig").on(.sep_top_ok) and l.kind != .ref) continue;
        if (@import("Mutate.zig").on(.sep_family_off) and l.kind == .ref) continue;
        switch (l.kind) {
            .ref => if (!l.at_pos and try isFamily(e, l) and !Contract.isApart(en.occ)) {
                if (f.roots.items[l.root].kind == .cb and !e.expandable(l)) return Cond.unprovable;
                if (try Chains.gather(e, &occs, try sepLeaf(e, en.leaf))) return Cond.unprovable;
            },
            .top, .shared, .loan => return Cond.unprovable,
            else => {},
        }
        // A callback answer may be what the label was supplied (unknown code
        // may answer its argument): never apart from another entry that
        // reaches a supply (`pickSecond`: `( f b, b )`).
        if (@import("Mutate.zig").on(.sep_answer_supply_off)) continue;
        if (l.kind == .ref and f.roots.items[l.root].kind == .cb and !e.expandable(l)) {
            var sl: std.ArrayList(u32) = .empty;
            defer sl.deinit(g);
            for (f.cbs.items[f.roots.items[l.root].a].args) |sv| try e.leavesOf(sv, 0, &sl);
            for (st.ents.items) |o| if (o.leaf != en.leaf) for (sl.items) |x| {
                if (o.routes != 0 and !try Entries.routesMeet(f, o, .{ .leaf = x, .route = 0, .occ = 0, .block = none })) continue;
                if ((try overlap(e, o.leaf, x, false)).kind != .no) return Cond.unprovable;
            };
        }
    }
    var taken: std.ArrayList(u32) = .empty;
    defer taken.deinit(g);
    var dirty: std.ArrayList(u32) = .empty;
    defer dirty.deinit(g);
    // The candidates of one object and the apart entries made, by leaf, block,
    // occurrence and route set: one met again is compared as the first, and
    // adds nothing (a fold's accumulator, fed its own answer).
    var cands: Ids.FixedDict(6) = .{};
    defer cands.deinit(g);
    var fresh: usize = 0;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        const ents = st.ents.items;
        try e.charge(.cond, @intCast(1 + ents.len - fresh));
        if (try answerMeets(f, ents, st.alive.items, fresh) or Entries.madeMeetsOwn(e, ents)) return Cond.unprovable;
        // The new entries into their groups; a second parameter's group
        // makes every parameter group ask its occurrences.
        const params = st.params;
        for (fresh..ents.len) |i| try st.place(f, @intCast(i));
        fresh = ents.len;
        if (params < 2 and st.params >= 2) for (st.groups.items, 0..) |gr, gi| {
            if (gr.root != none and f.roots.items[gr.root].kind == .param) try st.mark(g, @intCast(gi));
        };
        std.mem.swap(std.ArrayList(u32), &dirty, &st.dirty);
        st.dirty.clearRetainingCapacity();
        for (dirty.items) |gi| st.groups.items[gi].dirty = false;
        for (dirty.items) |gi| {
            const gr = &st.groups.items[gi];
            const idx = gr.members.items;
            if (idx.len == 0) continue;
            if (gr.root == none) {
                if (try Entries.atomTwice(f, ents, idx)) return Cond.unprovable;
                continue;
            }
            if (try gr.within.add(f, ents, idx, routed)) return Cond.unprovable;
            const r = f.roots.items[gr.root];
            switch (r.kind) {
                // One entry that names several objects (a tuple a parameter
                // or a call answers whole) asks as two entries do (#1711).
                .param => if (idx.len >= 2 or st.params >= 2 or Entries.manyObjects(f, ents, idx)) {
                    // One sort of the group's slots, never a union per entry.
                    // Each entry's slots; an entry of an apart occurrence
                    // asks to be apart only. A member's are asked once.
                    for (idx[gr.occ_done..]) |i| {
                        const ap = Contract.isApart(ents[i].occ);
                        const lslots = f.slots.elems(f.leafAt(ents[i].leaf).slots);
                        try e.charge(.cond, @intCast(1 + lslots.len));
                        for (lslots) |x| if (try occOf(e, r.a, x, ap)) |o| try occs.add(g, o);
                    }
                    gr.occ_done = @intCast(idx.len);
                },
                .call => {
                    gr.must = 0;
                    if (read != null and try Answers.allMade(e, r.a)) {
                        if (try Chains.gather(e, &occs, try instCond(e, r.a))) return Cond.unprovable;
                        gr.settled = true;
                        continue;
                    }
                    if ((idx.len >= 2 or Entries.manyObjects(f, ents, idx)) and !Entries.allApart(ents, idx)) {
                        // A call that does not vouch for its parts is read
                        // through what they come from (§2.9.2 step 3),
                        // each part on its own.
                        const c = if (Entries.anyApart(ents, idx)) try PlainReach.instCondMixed(e, r.a, ents, idx, instSel, try condStates(e)) else try instCond(e, r.a);
                        if (c.no) {
                            // At a slot no step below can name, the arrivals
                            // are one set: `xs` twice inside a cast is one leaf
                            // there, so expansion cannot count it (#1710).
                            if (idx.len == 1 and OneSet.of(f, ents[idx[0]])) return Cond.unprovable;
                            gr.must = 1;
                        } else if (try Chains.gather(e, &occs, c)) return Cond.unprovable;
                    }
                },
                .supply, .cb => {
                    gr.must = 0;
                    if (idx.len >= 2 or Entries.manyObjects(f, ents, idx)) {
                        if (!e.expandable(f.leafAt(ents[idx[0]].leaf))) return Cond.unprovable;
                        gr.must = 2;
                    }
                },
            }
            if (gr.must != 0) try Entries.Rounds.push(g, &st.musts, gr.root);
        }
        // A supply or a label meeting itself is decided by expansion.
        const must = st.top(&st.musts, struct {
            fn ok(gr: *const Entries.Group) bool {
                return gr.must != 0 and gr.members.items.len != 0;
            }
        }.ok);
        const latest = must orelse st.top(&st.expandable, struct {
            fn ok(gr: *const Entries.Group) bool {
                return gr.members.items.len != 0 and !gr.settled;
            }
        }.ok) orelse break;
        if (must == null and st.nonempty < 2) break;
        if (rounds > 4096) return Cond.unprovable;
        const unvouched = must != null and st.groups.items[st.of_root.items[latest]].must == 1;
        if (must == null and try AtomSets.settled(e, &st)) break; // its atoms meet nothing
        // The latest expandable root meets another: its entries become
        // what they come from (one level), a block it vouched for, in the
        // order the entries are read (a leaf met twice keeps its first).
        taken.clearRetainingCapacity();
        try st.take(g, latest, &taken);
        const blk = if (f.roots.items[latest].kind == .call and !unvouched) latest else none;
        if (blk != none and taken.items.len >= 2) try Chains.sortInline(e, &st, taken.items);
        // An expansion of a call is one block of alternatives: one entry
        // per leaf (pairs inside a block are never compared).
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(g);
        const start = st.ents.items.len;
        for (taken.items) |ti| {
            const en = st.ents.items[ti];
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(g);
            var rs: std.ArrayList(u32) = .empty;
            defer rs.deinit(g);
            try EntryExpand.expand(e, en, &list, &rs);
            // One entry of its root expanding to one leaf: a chain of calls
            // that hand one object on is read to its end, each call's
            // group one entry of one object (it asks nothing of its own).
            if (taken.items.len == 1 and list.items.len == 1 and rs.items[0] == 0) list.items[0] = try Ends.endOf(e, list.items[0]);
            for (list.items, 0..) |x, nth| {
                const xl = f.leafAt(x);
                if (xl.kind == .top or xl.kind == .shared or xl.kind == .loan) return Cond.unprovable;
                if (isAnswer(f, xl) or (read == null and Taken.containerRoot(f, e.contracts, f.leafAt(en.leaf)) != none)) hoped(e);
                try e.charge(.edge, 1);
                e.route_count += 1;
                if (blk != none and (try seen.getOrPut(g, .{ x, rs.items[nth] })).found_existing) continue;
                // A leaf the entry was expanded from, met again around a
                // cycle of expansions (a fold's supply and its step's
                // answer): its objects are that ancestor's, which this
                // chain reads already (the least fixpoint, §2.9.3).
                if (try Chains.onChain(e, &st, ti, x)) continue;
                if ((en.one != none or Contract.isApart(en.occ)) and (try cands.getOrPut(g, .{ x, en.one, blk, @truncate(en.occ), @intCast(en.occ >> 32), rs.items[nth] })).found_existing) continue;
                if (read) |rd| if (try rd.take(e, &st, &occs, x, blk, .{ ti, @intCast(nth), st.par.items[ti][2] + 1 })) {
                    if (rd.failed) return Cond.unprovable;
                    continue;
                };
                try st.add(g, .{ .leaf = x, .route = 0x4000_0000 | e.route_count, .occ = if (Contract.isApart(en.occ)) en.occ else 0, .block = blk, .routes = rs.items[nth], .one = en.one, .taken = read != null and Taken.containerRoot(f, e.contracts, f.leafAt(en.leaf)) != none }, .{ ti, @intCast(nth), st.par.items[ti][2] + 1 });
            }
        }
        // Families of the expansion ask their own separation.
        for (st.ents.items[start..]) |en| {
            if (en.block == none and !en.read) continue;
            const l = f.leafAt(en.leaf);
            if (l.kind == .ref and !l.at_pos and try isFamily(e, l) and !e.expandable(l) and !Contract.isApart(en.occ)) {
                if (f.roots.items[l.root].kind == .cb) return Cond.unprovable;
                if (try Chains.gather(e, &occs, try sepLeaf(e, en.leaf))) return Cond.unprovable;
            }
        }
    }
    if (occs.run.items.len == 0) return Cond.yes;
    return Cond.of(e.account(), try e.arena.dupe(u64, occs.run.items));
}

// ---- the one relation (§2.9.2) -------------------------------------------

/// The relation of holder leaf `x` (deep) and target leaf `t`;
/// `target`: `t` is a shallow write target. Its answer is the least fixed
/// point over the pairs it reaches (`Pairs`), whatever else is being asked.
pub fn overlap(e: *Eval, x: u32, t: u32, target: bool) Error!Ov {
    try e.pairs.begin(e.gpa(), e.grown);
    defer e.pairs.end();
    return pair(e, x, t, target);
}

/// A pair the current query reaches: solved, or its equation (`overlapRaw`).
fn pair(e: *Eval, x: u32, t: u32, target: bool) Error!Ov {
    try e.charge(.cond, 1);
    const key: [3]u32 = .{ x, t, @as(u32, @intFromBool(target)) | @as(u32, @intFromBool(e.keeping)) << 1 | modeOf(e) << 2 };
    const fr = switch (try e.pairs.enter(e.gpa(), key)) {
        .value => |v| return v,
        .frame => |fr| fr,
    };
    while (true) {
        const got = try overlapRaw(e, x, t, target);
        if (try e.pairs.leave(e.gpa(), e.arena, e.account(), fr, got)) |v| return v;
    }
}

fn overlapRaw(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    // A loan holds what it lends (§2.13.7); written, it is unknown.
    if (@import("Mutate.zig").on(.loan_holds_nothing) and x.kind == .loan and t.kind != .loan) return .no;
    if (x.kind == .loan and t.kind != .loan) return pair(e, x.atom, ti, target);
    if (x.routes == 0 and t.routes == 0) {
        if (!try e.f.sets.tags.meet(e.f.account, x.tags, t.tags)) return .no;
    } else if (!try Coexist.setsMeet(&e.f.sets.tags, e.gpa(), e.account(), x.tags, x.routes, t.tags, t.routes)) return .no;
    // A cell's `◆` is behind its barrier (§2.13.7): a write replaces
    // what the cell holds and changes no object anyone holds.
    if (t.kind == .ref and t.at_pos) {
        const tp = e.f.pos.items[t.pos];
        if (tp.kind == .plain and Step.fromWord(tp.a).kind == .contents) return .no;
    }
    if (x.kind == .top or t.kind == .top or x.kind == .loan or t.kind == .loan) return .may;
    if (!@import("Mutate.zig").on(.made_meets_off)) if (e.made) |m| if (m(e, x) | m(e, t) == 3) return .may;
    // A host object is no target that is still writable: it may be another host object only (§2.10).
    if (@import("Mutate.zig").on(.overlap_host_no) and (x.kind == .host or t.kind == .host)) return .no;
    if (x.kind == .host or t.kind == .host) return if (x.kind == t.kind) .may else .no;
    const xr = x.kind == .ref;
    const tr = t.kind == .ref;
    if (Taken.side(e.f, e.contracts, x, t)) |w| return Taken.apartFromOthers(Ov, e, xi, ti, w, target, apartIn, pair);
    // An unknown label's answer, written: anything; holding the target,
    // what it was supplied or its label's function slot holds.
    if (t.kind == .answer or (tr and e.f.roots.items[t.root].kind == .cb)) {
        if (e.keeping) return AnswerKeep.kept(Ov, e, xi, ti, pair, answerHolds);
        // The rest of what it may be is the need's, judged at each caller (§2.11.3).
        if (x.kind == .answer or (xr and e.f.roots.items[x.root].kind == .cb)) return if (x.root == t.root and x.atom == t.atom) .may else answerHolds(e, x, ti, target);
        if (!xr or !e.expandable(x)) return .no;
    } else if (@import("Mutate.zig").on(.answer_holds_no) and (x.kind == .answer or (xr and e.f.roots.items[x.root].kind == .cb))) {
        return .no;
    } else if (x.kind == .answer or (xr and e.f.roots.items[x.root].kind == .cb)) return answerHolds(e, x, ti, target);
    if (xr and tr and x.root == t.root) return positional(e, xi, ti, target);
    if (xr or tr) {
        // An object made after a call is none of the call's result (§2.9.2
        // step 4): no expansion, so a chain of calls is never walked again
        // per atom met at its end.
        if (Chains.madeAfter(e, x, t) or Chains.madeAfter(e, t, x)) return .no;
        const ex = xr and e.expandable(x);
        const et = tr and e.expandable(t);
        if (@import("Mutate.zig").on(.overlap_no_expand)) return .no;
        if (ex or et) {
            const expand_x = if (ex and et) x.root > t.root else ex;
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(e.gpa());
            try e.expand(if (expand_x) xi else ti, &list);
            var acc: Ov = .no;
            for (list.items) |l| {
                const o = if (expand_x) try pair(e, l, ti, target) else try pair(e, xi, l, target);
                acc = try Ov.join(e.arena, e.account(), acc, o);
                if (acc.kind == .may) return acc;
            }
            return acc;
        }
        if (xr and tr) {
            // Two parameters: apart under both selections; the holder's
            // objects need only be apart from the target's (§2.9.1).
            if (@import("Mutate.zig").on(.two_params_no)) return .no;
            const c = try Cond.conj(e.arena, e.account(), try selOf(e, e.f.roots.items[x.root].a, x.slots, true), try sel(e, e.f.roots.items[t.root].a, t.slots));
            return .{ .kind = .under, .cond = c };
        }
        // A parameter's leaf and an atom.
        return .no;
    }
    // Two atoms.
    if (x.kind == t.kind and x.atom == t.atom and x.extra == t.extra) return .may;
    return .no;
}

/// What the answer `x` of a label's direct call may hold of `t` (§2.9.2
/// step 7): unknown code answers from what that call supplied it and
/// from what its function holds, the label's parameter slot. A label the
/// frame only passes on, or a target under that slot, answers anything.
fn answerHolds(e: *Eval, x: Leaf, ti: u32, target: bool) Error!Ov {
    const cb = e.f.cbs.items[if (x.kind == .answer) x.atom else e.f.roots.items[x.root].a];
    if (cb.inst == none) return .may;
    var sl: std.ArrayList(u32) = .empty;
    defer sl.deinit(e.gpa());
    for (cb.args) |sv| try e.leavesOf(sv, 0, &sl);
    var acc: Ov = .no;
    for (sl.items) |l| {
        acc = try Ov.join(e.arena, e.account(), acc, try pair(e, l, ti, target));
        if (acc.kind == .may) return acc;
    }
    return Ov.join(e.arena, e.account(), acc, try HeldBy.of(Ov, e, cb.j, cb.slot, ti, sel));
}

fn positional(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    if (@import("Mutate.zig").on(.positional_always_apart)) return apartOf(e, xi, ti, target);
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    if (x.slots == Slots.empty or t.slots == Slots.empty) return .no;
    const r = try e.f.related(x.pos, t.pos);
    if (r.rel == .related) {
        // A write of a position's own storage never meets what lies
        // inside it: no value holds itself.
        if (target and t.at_pos and r.second_prefix and x.pos != t.pos) {
            if (!(try Subtree.meetIn(e.f.slots, e.gpa(), e.account(), e.places(), x.slots, t.slots))) return apartIn(e, xi, ti, target);
            // The holder below the written position holds the slot only
            // where a level folds back onto it.
        }
        if (try Subtree.meetIn(e.f.slots, e.gpa(), e.account(), e.places(), x.slots, t.slots)) return .may;
    }
    return apartIn(e, xi, ti, target);
}

/// Two leaves of one root at distinct places: apart under the root's
/// separation. A query, as `overlap`.
pub fn apartOf(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    if (@import("Mutate.zig").on(.apart_of_no)) return .no;
    try e.pairs.begin(e.gpa(), e.grown);
    defer e.pairs.end();
    return apartIn(e, xi, ti, target);
}

fn apartIn(e: *Eval, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = e.f.leafAt(xi);
    const t = e.f.leafAt(ti);
    const r0 = e.f.roots.items[x.root];
    switch (r0.kind) {
        .param => return .{ .kind = .under, .cond = try Cond.conj(e.arena, e.account(), try selOf(e, r0.a, x.slots, true), try sel(e, r0.a, t.slots)) },
        .call => {
            const sep = try instCond(e, r0.a);
            if (!sep.no) return .{ .kind = .under, .cond = sep };
        },
        .supply, .cb => {},
    }
    if (!e.expandable(x)) return .may;
    var lx: std.ArrayList(u32) = .empty;
    defer lx.deinit(e.gpa());
    var lt: std.ArrayList(u32) = .empty;
    defer lt.deinit(e.gpa());
    try e.expand(xi, &lx);
    try e.expand(ti, &lt);
    var acc: Ov = .no;
    for (lx.items) |a| for (lt.items) |b| {
        acc = try Ov.join(e.arena, e.account(), acc, try pair(e, a, b, target));
        if (acc.kind == .may) return acc;
    };
    return acc;
}
