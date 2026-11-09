//! L5: the environment rows are read in (`docs/design/ownership-v2.md`
//! §2.10, §2.13.6), split from `Rows`: the tables a contract is made of,
//! a row's result slots at and below a place, a parameter's slots as the
//! result's, and what a `taken` callback's write asks at its caller.
//! Obligations kept here: none of §2.14's directly (`Rows` keeps O9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Dests = @import("Dests.zig");
const SlotWords = @import("SlotWords.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Ast = @import("../parse/Ast.zig");

pub const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;
const PathId = Ids.PathId;
const W = Ast.OwnWord;
const Draft = Contract.Draft;

/// A `taken` label's origin offset: a bit no instruction offset has, kept
/// as the label is passed on (§2.11.3).
pub const taken_origin: u32 = 1 << 30;

pub const Env = struct {
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    places: *Place.Table,
    slots: *Slots.Table,
    contracts: *Contract.Table,

    pub fn has(words: u32, w: W) bool {
        return words & w.bit() != 0 and @import("Mutate.zig").keeps(w);
    }

    pub fn root(env: Env, p: PlaceId) Error!PathId {
        return env.places.rootPath(env.gpa, p);
    }

    pub fn rel(env: Env, p: PathId) Error!Slots.Rel {
        return env.slots.relOf(env.gpa, env.account, env.places, p);
    }

    pub fn isVar(env: Env, p: PathId) bool {
        return env.places.kind(env.places.pathPlace(p)) == .@"var";
    }

    /// Every object slot at and below the result root, each with `a`.
    pub fn everySlot(env: Env, d: *Draft, result: PlaceId, a: Contract.Arrival) Error!void {
        const r = try env.root(result);
        // A whole subtree (`↓r`, §2.3.1): an atom is the same at every slot,
        // one wide entry at the root; anything else is named at each slot
        // (`belowAll`, charged).
        const set = try Subtree.below(env.slots, env.gpa, env.account, env.places, r);
        if (Subtree.symbolic(env.slots, set) and (a.kind == .fresh or a.kind == .top or a.kind == .shared or a.kind == .host)) {
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
    pub fn identity(env: Env, d: *Draft, prefix: PathId, j: u32, from: PathId) Error!void {
        return env.identityInto(&d.res, prefix, j, from);
    }

    /// `identity` into the slots `list`: a result's or a supply's.
    pub fn identityInto(env: Env, list: *Draft.Res, prefix: PathId, j: u32, from: PathId) Error!void {
        // A contract names each result slot (§2.10): a whole subtree is
        // written out (`belowAll`, §2.3.1, charged).
        for (env.slots.items(try Subtree.belowAll(env.slots, env.gpa, env.account, env.places, from))) |s| {
            // Every route to `s` from `from`, each from `prefix` (§2.1, *Every name*).
            var at: std.ArrayList(u32) = .empty;
            defer at.deinit(env.gpa);
            if (!try Dests.routes(.{ .gpa = env.gpa, .account = env.account, .places = env.places, .slots = env.slots }, from, .from(s), prefix, &at)) continue;
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
            for (at.items) |q0| for ([_][]const u32{ &.{q0}, try env.slots.joinNames(env.gpa, env.arena, env.account, env.places, .from(q0)) }) |ps| for (ps) |q| {
                const qr = try env.rel(.from(q));
                if (env.isVar(.from(q))) try Draft.markOpen(list, env.arena, qr);
                _ = try Draft.addArrival(list, env.arena, qr, arrival);
                // Below where it lands, each result slot is that slot's steps inside the parameter
                // (a cast read back, §2.13.9): open, so a caller's slot takes its own steps on.
                if (wild) try Draft.markOpen(list, env.arena, qr);
            };
        }
    }

    pub fn commit(env: Env, d: *Draft) Error!Contract.Id {
        return env.contracts.commit(env.gpa, env.account, env.slots, d);
    }
};

/// A write at `words` of a `taken` label's supply `su` (§2.13.6): its
/// container stays, so what is written occurs once in it, and apart from
/// everything else it holds. As the label's caller's occurrences: every
/// parameter slot of the supply (the element) deep and apart, the written slot plain
/// from the deepest entry at a prefix of `words`, or an open one; a supply passed on by
/// structure names a tuple's parts at its root. A slot no parameter's was judged at the pass.
pub fn takenOccs(contracts: *const Contract.Table, places: *const Place.Table, slots: *Slots.Table, account: *Ids.Account, gpa: Allocator, arena: Allocator, su: Contract.Supply, words: []const u32, deep: bool) Error!?[]u64 {
    var es: Forest.Entries = .{};
    defer es.deinit(gpa);
    try es.of(&contracts.trees, gpa, places, su.res_root, &.{});
    var best: ?u32 = null;
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind == .param) best = @max(best orelse 0, @as(u32, @intCast(SlotWords.under(places, es.wordsOf(rs), words) orelse continue)));
    };
    const at_best = best orelse return null;
    var out: std.ArrayList(u64) = .empty;
    for (es.items.items) |rs| for (rs.arrivals) |a| {
        if (a.kind != .param) continue;
        // An arrival below another's is in its deep occurrence already.
        const covered = blk: {
            for (es.items.items) |rt| for (rt.arrivals) |b| {
                if (b.kind == .param and b.j == a.j and b.slot != a.slot and SlotWords.under(places, slots.relWords(b.slot), slots.relWords(a.slot)) != null) break :blk true;
            };
            break :blk false;
        };
        if (!covered) try out.append(arena, Contract.occDeep(Contract.occApart(a.j, a.slot)));
        const n = SlotWords.under(places, es.wordsOf(rs), words) orelse continue;
        if (n != at_best and !rs.open) continue;
        const at = try std.mem.concat(arena, u32, &.{ slots.relWords(a.slot), words[n..] });
        const o = Contract.occ(a.j, try slots.relOfWords(gpa, account, places, at));
        try out.append(arena, if (deep or a.deep) Contract.occDeep(o) else o);
    };
    return out.items;
}
