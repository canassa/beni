//! L4: rows as contracts (`docs/design/ownership-v2.md` §2.10, §2.13.6): a
//! worded declaration's words over its places, a constructor's contract, a
//! derived or primitive comparison's, a schema member's, and the
//! pessimistic contract of a callee with none. A worded code is never
//! walked: its words are taken as given (§2.13.6's pins check the bodies).
//!
//! | word | contract |
//! |---|---|
//! | `unused` | nothing |
//! | `borrowed` | a read at ε (at every depth on a bare type variable) |
//! | `aliased` | a deep read; every result slot may hold any of it |
//! | `returned` | a deep read; the result at each slot is it at that slot |
//! | `stored` | a deep read; the result's `[*]` holds it |
//! | `escaped` | a deep read and an escape |
//! | `consumed` | a deep write |
//! | `written` | a read and a storage write at ε |
//! | result `fresh` | every result slot fresh; `exclusive`: separated |
//! | result `elementof` | the result is `π1[*]` |
//! | result `copyof` | fresh storage, `[*]` from `π1[*]` |
//! | result `concatenated` | storage `π1` or fresh, `[*]` from both |
//! | result `prepended` | storage `π2` or fresh, `[*]` from `π1` and `π2[*]` |
//! | result `builderdone` | `π1` |
//! | result `cellnew` | a fresh cell whose `◆` holds `π1` |
//! | result `cellempty` | a fresh cell |
//! | `cellwrite`, `cellcomplete` | a storage write of the cell `π1` |
//! | `cellstored` | the value escapes behind the barrier |
//! | `cellupdate`, `cellmodify` | a label called once, supplied `π1◆` |
//! | anything else (`taken`, `lent`, callbacks' rows), `unknown` | the result `⊤`, not separated |
//!
//! Obligations kept here: O9 (rows state their bodies: a row is taken as
//! given, never inferred).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Ast = @import("../parse/Ast.zig");

pub const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;
const PathId = Ids.PathId;
const W = Ast.OwnWord;
const Draft = Contract.Draft;

pub const Param = struct { place: PlaceId, words: u32 = 0, type_variable: bool = false };
pub const Signature = struct {
    params: []const Param,
    result: PlaceId,
    result_words: u32 = 0,
    /// The worded declaration's `(module, declaration)`: the origin of a
    /// cell callback's label.
    origin: ?[2]u32 = null,
};

pub const Env = struct {
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    places: *Place.Table,
    slots: *Slots.Table,
    contracts: *Contract.Table,

    fn has(words: u32, w: W) bool {
        return words & w.bit() != 0;
    }

    fn root(env: Env, p: PlaceId) Error!PathId {
        return env.places.rootPath(env.gpa, p);
    }

    fn rel(env: Env, p: PathId) Error!Slots.Rel {
        return env.slots.relOf(env.gpa, env.account, env.places, p);
    }

    fn isVar(env: Env, p: PathId) bool {
        return env.places.kind(env.places.pathPlace(p)) == .@"var";
    }

    /// Every object slot at and below the result root, each with `a`.
    fn everySlot(env: Env, d: *Draft, result: PlaceId, a: Contract.Arrival) Error!void {
        const r = try env.root(result);
        // A whole subtree (`↓r`, §2.3.1): an atom is the same at every slot,
        // one wide entry at the root; anything else is named at each slot
        // (`belowAll`, charged).
        const set = try Subtree.below(env.slots, env.gpa, env.account, env.places, r);
        if (Subtree.symbolic(env.slots, set) and (a.kind == .fresh or a.kind == .top or a.kind == .shared)) {
            _ = try Draft.addWide(&d.res, env.arena, Slots.root, a);
            return;
        }
        for (env.slots.items(try Subtree.belowAll(env.slots, env.gpa, env.account, env.places, r))) |s| {
            const sr = try env.rel(.from(s));
            if (env.isVar(.from(s))) try Draft.markOpen(&d.res, env.arena, sr);
            _ = try Draft.addArrival(&d.res, env.arena, sr, a);
        }
        if (Slots.isObject(env.places, r) and env.isVar(r)) try Draft.markOpen(&d.res, env.arena, Slots.root);
    }

    /// The result's slots below `prefix` (a result path) are parameter `j`'s
    /// below `from` (a parameter path), slot for slot.
    fn identity(env: Env, d: *Draft, prefix: PathId, j: u32, from: PathId) Error!void {
        return env.identityInto(&d.res, prefix, j, from);
    }

    /// `identity` into the slots `list`: a result's or a supply's.
    fn identityInto(env: Env, list: *Draft.Res, prefix: PathId, j: u32, from: PathId) Error!void {
        // A contract names each result slot (§2.10): a whole subtree is
        // written out (`belowAll`, §2.3.1, charged).
        for (env.slots.items(try Subtree.belowAll(env.slots, env.gpa, env.account, env.places, from))) |s| {
            const below = (try env.slots.relBelow(env.gpa, env.account, env.places, from, .from(s))) orelse continue;
            var at: std.ArrayList(u32) = .empty;
            defer at.deinit(env.gpa);
            try Slots.replay(env.gpa, env.account, env.places, prefix, env.slots.relWords(below), &at);
            // An opaque or a type variable's slot holds anything (a cast's
            // inner, §2.13.9): every object of it, at every result slot
            // below where it lands.
            const wild = env.isVar(.from(s)) or env.places.kind(env.places.pathPlace(.from(s))) == .@"opaque";
            const arrival: Contract.Arrival = .{ .kind = .param, .j = j, .slot = try env.rel(.from(s)), .deep = wild };
            if (at.items.len == 0) {
                // A slot the result cannot name: it arrives at the prefix.
                const pr = try env.rel(prefix);
                if (env.isVar(prefix)) try Draft.markOpen(list, env.arena, pr);
                _ = try Draft.addArrival(list, env.arena, pr, .{ .kind = .param, .j = j, .slot = try env.rel(.from(s)), .deep = true });
                continue;
            }
            for (at.items) |q| {
                const qr = try env.rel(.from(q));
                if (env.isVar(.from(q))) try Draft.markOpen(list, env.arena, qr);
                _ = try Draft.addArrival(list, env.arena, qr, arrival);
                // Below where it lands, each result slot is that slot's
                // steps taken inside the parameter (a cast read back is the
                // part it was built from, §2.13.9): the slot is open, so a
                // caller's slot below it takes its own steps on from `s`.
                if (wild) try Draft.markOpen(list, env.arena, qr);
            }
        }
    }

    fn commit(env: Env, d: *Draft) Error!Contract.Id {
        return env.contracts.commit(env.gpa, env.account, env.slots, d);
    }
};

/// The pessimistic contract (§2.10): every argument read and escaped deep,
/// the result `⊤`, not separated.
pub fn pessimistic(env: Env, arity: u32) Error!Contract.Id {
    var d: Draft = .{ .arity = arity, .flags = .{ .returns = true, .pessimistic = true } };
    for (0..arity) |j| {
        _ = try Draft.addEffect(&d.reads, env.arena, .{ .j = @intCast(j), .slot = Slots.root, .deep = true });
        _ = try Draft.addEffect(&d.escapes, env.arena, .{ .j = @intCast(j), .slot = Slots.root, .deep = true });
    }
    try Draft.markOpen(&d.res, env.arena, Slots.root);
    _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .top });
    d.res_cond = .unprovable;
    return env.commit(&d);
}

/// A comparison's contract (§2.13.13): both arguments read deep, the
/// result crossing, nothing written.
pub fn comparison(env: Env, arity: u32) Error!Contract.Id {
    var d: Draft = .{ .arity = arity, .flags = .{ .returns = true, .cross = true } };
    for (0..arity) |j| _ = try Draft.addEffect(&d.reads, env.arena, .{ .j = @intCast(j), .slot = Slots.root, .deep = true });
    return env.commit(&d);
}

/// A constructor used as a function (§2.13.1): the result's `C#k` is
/// argument `k`, slot for slot; a constructor duplicates nothing.
pub fn ctor(env: Env, sig: Signature, ordinal: u32) Error!Contract.Id {
    var d: Draft = .{ .arity = @intCast(sig.params.len), .flags = .{ .returns = true } };
    const r = try env.root(sig.result);
    d.flags.cross = !Slots.holdsAny(env.places, r);
    var occs: std.ArrayList(u64) = .empty;
    for (sig.params, 0..) |p, k| {
        const from = try env.root(p.place);
        _ = try Draft.addEffect(&d.reads, env.arena, .{ .j = @intCast(k), .slot = Slots.root, .deep = true });
        const st: Place.Step = if (env.places.kind(sig.result) == .record) blk: {
            const steps = env.places.steps(sig.result).steps;
            break :blk if (k < steps.len) steps[k] else continue;
        } else try env.places.ctorStep(env.gpa, env.account, ordinal, @intCast(k));
        const at = (try env.places.extend(env.gpa, .growth(env.account), r, st)) orelse continue;
        try env.identity(&d, at, @intCast(k), from);
        for (env.slots.items(try Subtree.belowAll(env.slots, env.gpa, env.account, env.places, from))) |s| {
            const o = Contract.occ(@intCast(k), try env.rel(.from(s)));
            try occs.append(env.arena, if (env.isVar(.from(s)) or env.places.kind(env.places.pathPlace(.from(s))) == .@"opaque") Contract.occDeep(o) else o);
        }
    }
    if (env.places.kind(sig.result) == .record and !d.flags.cross) _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .fresh });
    d.res_cond = try Contract.Cond.of(env.account, occs.items);
    return env.commit(&d);
}

/// A worded declaration's contract (§2.13.6), over the places of its
/// signature at this use.
pub fn fromWords(env: Env, sig: Signature) Error!Contract.Id {
    var d: Draft = .{ .arity = @intCast(sig.params.len), .flags = .{ .returns = true, .words = true } };
    const r = try env.root(sig.result);
    d.flags.cross = !Slots.holdsAny(env.places, r);
    const rw = sig.result_words;
    var exclusive = true;
    var known_result = false;
    for (sig.params, 0..) |p, k| {
        const j: u32 = @intCast(k);
        const from = try env.root(p.place);
        const ws = p.words;
        if (env.places.kind(p.place) == .closure) {
            // A cell callback (`cellupdate`, `cellmodify`, §2.13.7): called
            // once, synchronously, on the contents taken out of `π1`'s `◆`.
            // A label whose one supply is `π1◆`, slot for slot, kept by
            // nothing. A write of it is deep at the caller (`Eval.callWrite`),
            // so it is never a cell operation (`Eval.cellWrite`).
            if ((Env.has(ws, .cellupdate) or Env.has(ws, .cellmodify)) and k > 0) if (sig.origin) |o| cell: {
                const cs = (try env.places.extend(env.gpa, .growth(env.account), try env.root(sig.params[0].place), Place.Step.contents)) orelse break :cell;
                // Offset 1 marks `cellmodify`: only `.1` is stored (`Cells.shared`).
                const li = try d.labelOf(env.arena, j, Slots.root, .{ o[0], o[1], @intFromBool(Env.has(ws, .cellmodify)) });
                d.labels.items[li].calls = .once;
                const su = try d.labels.items[li].supplyOf(env.arena, 0);
                try env.identityInto(&su.res, try env.root(env.places.pathPlace(cs)), 0, cs);
                exclusive = false;
                continue;
            };
            // A callback of a row: called by the row's own code, which the
            // checker does not see: unknown code.
            if (ws != 0 and !Env.has(ws, .unused)) {
                _ = try Draft.addEffect(&d.escapes, env.arena, .{ .j = j, .slot = Slots.root, .deep = true });
                exclusive = false;
            }
            continue;
        }
        if (ws == 0 or Env.has(ws, .escaped)) {
            // No word: escaped (§2.13.6).
            _ = try Draft.addEffect(&d.reads, env.arena, .{ .j = j, .slot = Slots.root, .deep = true });
            _ = try Draft.addEffect(&d.escapes, env.arena, .{ .j = j, .slot = Slots.root, .deep = true });
            continue;
        }
        if (Env.has(ws, .unused)) continue;
        const deep_read = p.type_variable or Env.has(ws, .aliased) or Env.has(ws, .returned) or Env.has(ws, .stored) or Env.has(ws, .consumed);
        _ = try Draft.addEffect(&d.reads, env.arena, .{ .j = j, .slot = Slots.root, .deep = deep_read });
        if (Env.has(ws, .consumed)) _ = try Draft.addEffect(&d.writes, env.arena, .{ .j = j, .slot = Slots.root, .deep = true });
        if (Env.has(ws, .written)) _ = try Draft.addEffect(&d.writes, env.arena, .{ .j = j, .slot = Slots.root, .deep = false });
        // A cell's write replaces what its slot holds: the cell object itself
        // is written, never the object behind the barrier.
        // It writes the cell's `◆` (§2.13.7): behind the barrier, so no
        // holder of the handle holds what it replaces.
        if (Env.has(ws, .cellwrite) or Env.has(ws, .cellcomplete)) {
            const cs = if (try env.places.extend(env.gpa, .growth(env.account), from, Place.Step.contents)) |c| try env.rel(c) else Slots.root;
            _ = try Draft.addEffect(&d.writes, env.arena, .{ .j = j, .slot = cs, .deep = false });
        }
        if (Env.has(ws, .cellstored)) _ = try Draft.addEffect(&d.escapes, env.arena, .{ .j = j, .slot = Slots.root, .deep = true });
        if (d.flags.cross) continue;
        if (Env.has(ws, .returned)) {
            try env.identity(&d, r, j, from);
            known_result = true;
        }
        if (Env.has(ws, .aliased)) {
            try env.everySlot(&d, sig.result, .{ .kind = .param, .j = j, .slot = Slots.root, .deep = true });
            exclusive = false;
            known_result = true;
        }
        if (Env.has(ws, .stored)) {
            if (try env.places.extend(env.gpa, .growth(env.account), r, Place.Step.elem)) |e| {
                try env.identity(&d, e, j, from);
                known_result = true;
            }
        }
    }
    if (!d.flags.cross) {
        const elem = try env.places.extend(env.gpa, .growth(env.account), r, Place.Step.elem);
        if (Env.has(rw, .fresh)) {
            try env.everySlot(&d, sig.result, .{ .kind = .fresh });
            if (!Env.has(rw, .exclusive)) exclusive = false;
            known_result = true;
        } else if ((Env.has(rw, .elementof) or Env.has(rw, .taken)) and sig.params.len >= 1) {
            // `taken`: one element of `π1`, the traversal's (§2.13.6).
            if (try env.places.extend(env.gpa, .growth(env.account), try env.root(sig.params[0].place), Place.Step.elem)) |pe| try env.identity(&d, r, 0, pe);
            known_result = true;
        } else if (Env.has(rw, .copyof) and sig.params.len >= 1) {
            _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .fresh });
            if (elem) |e| if (try env.places.extend(env.gpa, .growth(env.account), try env.root(sig.params[0].place), Place.Step.elem)) |pe| try env.identity(&d, e, 0, pe);
            known_result = true;
        } else if (Env.has(rw, .concatenated) and sig.params.len >= 2) {
            _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .fresh });
            _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .param, .j = 0, .slot = Slots.root });
            for (0..2) |k| if (elem) |e| if (try env.places.extend(env.gpa, .growth(env.account), try env.root(sig.params[k].place), Place.Step.elem)) |pe| try env.identity(&d, e, @intCast(k), pe);
            known_result = true;
        } else if (Env.has(rw, .prepended) and sig.params.len >= 2) {
            _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .fresh });
            _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .param, .j = 1, .slot = Slots.root });
            if (elem) |e| {
                try env.identity(&d, e, 0, try env.root(sig.params[0].place));
                if (try env.places.extend(env.gpa, .growth(env.account), try env.root(sig.params[1].place), Place.Step.elem)) |pe| try env.identity(&d, e, 1, pe);
            }
            known_result = true;
        } else if (Env.has(rw, .builderdone) and sig.params.len >= 1) {
            try env.identity(&d, r, 0, try env.root(sig.params[0].place));
            known_result = true;
        } else if ((Env.has(rw, .cellnew) or Env.has(rw, .cellempty))) {
            _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .fresh });
            if (Env.has(rw, .cellnew) and sig.params.len >= 1) if (try env.places.extend(env.gpa, .growth(env.account), r, Place.Step.contents)) |c| try env.identity(&d, c, 0, try env.root(sig.params[0].place));
            known_result = true;
        }
        if (!known_result or Env.has(rw, .unknown) or Env.has(rw, .escaped) or Env.has(rw, .lent) or Env.has(rw, .lentoptional)) {
            if (!known_result or rw != 0) {
                try env.everySlot(&d, sig.result, .{ .kind = .top });
                try Draft.markOpen(&d.res, env.arena, Slots.root);
                _ = try Draft.addArrival(&d.res, env.arena, Slots.root, .{ .kind = .top });
                exclusive = false;
            }
        }
    }
    d.res_cond = if (exclusive) .yes else .unprovable;
    if (!d.flags.cross and exclusive and !Env.has(rw, .fresh)) {
        // A result made of its parameters is separated when they are.
        var occs: std.ArrayList(u64) = .empty;
        for (d.res.items.items) |s| if (s.node == 0) if (s.a.kind == .param) try occs.append(env.arena, if (s.a.deep) Contract.occDeep(Contract.occ(s.a.j, s.a.slot)) else Contract.occ(s.a.j, s.a.slot));
        d.res_cond = try Contract.Cond.of(env.account, occs.items);
    }
    return env.commit(&d);
}
