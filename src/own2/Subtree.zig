//! L3: whole subtrees held as symbols (`docs/design/ownership-v2.md`
//! §2.3.1, *A subtree held whole*): a slot set's element `↓p` is every
//! object slot of `below(p)`, never written out. It is met by prefix tests
//! on `p`'s anchors (`p` and `Up(p)`, §2.7), as a deep read's walks are;
//! `belowAll` writes a subtree out for the one reader that must name each
//! slot (a contract's result, §2.10), charged on the asker's account.
//!
//! Obligations kept here: none of §2.14's directly (a symbol meets every
//! slot `below(p)` holds: never apart from one of them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const PastPayload = @import("PastPayload.zig");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");
const Slots = @import("Slots.zig");
const Trees = @import("Trees.zig");

const Table = Slots.Table;
const SetId = Slots.SetId;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const Error = Slots.Error;
const empty = Slots.empty;

/// Arrival `a` read for the objects at caller slot `slot` only (§2.10,
/// *Read-off*). An open arrival is the parameter's subtree by structure:
/// its object at `slot`, deep only where no step below `slot` can name
/// them (a type variable's or an opaque place). A plain one is as it is.
pub fn readAt(places: *const Place.Table, a: Trees.Arrival, slot: PathId, open: bool) Trees.Arrival {
    var x = a;
    if (@import("Mutate.zig").on(.read_at_shallow)) x.deep = false else if (open) x.deep = switch (places.kind(places.pathPlace(slot))) {
        .@"var" => true,
        .@"opaque" => a.deep,
        else => false,
    };
    return x;
}

/// Arrival `a` read at caller slot `slot` when that slot stands at a family's payload:
/// all of it, deep, at no suffix, since a word there says no depth (§2.1, *The exit
/// rule*). Null off a payload, where the words do say it.
pub fn wholeAt(places: *const Place.Table, a: Trees.Arrival, slot: PathId) ?Trees.Arrival {
    if (@import("Mutate.zig").on(.payload_arrival_exact) or !PastPayload.payload(places, places.pathPlace(slot))) return null;
    var x = a;
    x.deep = true;
    return x;
}

/// A caller's slot in a row is that slot of the argument, by structure (§2.1).
pub fn inRow(t: *const Table, a: Trees.Arrival, suffix: []const u32) Trees.Arrival {
    var x = a;
    if (suffix.len != 0 and a.kind != .fresh and a.kind != .top and a.kind != .host and a.kind != .shared and SlotWords.endsInRow(t.relWords(a.slot))) x.deep = false;
    return x;
}

/// Whether a set holds a symbol `↓p`.
pub fn symbolic(t: *const Table, s: SetId) bool {
    const xs = t.elems(s);
    return xs.len != 0 and Slots.isSub(xs[xs.len - 1]);
}

/// The explicit slots of a set (its symbols and exclusions left out).
pub fn explicit(t: *const Table, s: SetId) []const u32 {
    const xs = t.elems(s);
    var n = xs.len;
    while (n != 0 and xs[n - 1] >= Slots.not_bit) n -= 1;
    return xs[0..n];
}

/// The symbols of a set, as elements (`Slots.sub_bit` set).
pub fn subs(t: *const Table, s: SetId) []const u32 {
    const xs = t.elems(s);
    var n = xs.len;
    while (n != 0 and Slots.isSub(xs[n - 1])) n -= 1;
    return xs[n..];
}

/// `p` when the set is the one symbol `↓p`.
pub fn wholeOf(t: *const Table, s: SetId) ?PathId {
    const xs = t.elems(s);
    if (xs.len != 1 or !Slots.isSub(xs[0])) return null;
    return Slots.pathOf(xs[0]);
}

/// `below(p)`: the object slots at and below `p`, by their canonical
/// names (§2.3.1): a walk of `extend` over each place's steps, each path
/// once, filled once per path. It is the symbol `↓p` when the place graph
/// counts more than `Slots.below_min` object places below `p`'s place, or
/// a cycle below it that holds one (`Place.objectsBelow`), so no cycle is
/// walked; else written out, unless the walk finds more slots than that
/// (a `⟲` above `p` that stands for several paths).
pub fn below(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
    try account.reserve(.memo, 1);
    if (t.below_of.get(p)) |hit| {
        try account.readEntry(gpa, .below, p.int(), t.below_cost.get(p.int()));
        return hit;
    }
    const fill = account.beginFill();
    const s = belowFill(t, gpa, account, places, p) catch |err| {
        _ = account.endFill(fill);
        return err;
    };
    const cost = account.endFill(fill);
    try t.below_of.put(gpa, p, s);
    try t.below_cost.put(gpa, p.int(), cost);
    try account.readEntry(gpa, .below, p.int(), cost);
    return s;
}

fn belowFill(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
    std.debug.assert(p.int() < Slots.not_bit);
    var queue: std.ArrayList(PathId) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var found: Ids.FixedDict(1) = .{};
    defer found.deinit(gpa);
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    // Below an acyclic place, a path's slots are counted when it is found:
    // the walk stops at the first slot past `Slots.below_min`.
    var whole = places.objectsBelow(places.pathPlace(p)) > Slots.below_min;
    if (!whole) whole = try note(t, gpa, account, places, p, &found, &acc);
    try queue.append(gpa, p);
    _ = try seen.getOrPut(gpa, .{p.int()});
    var qi: usize = 0;
    walk: while (!whole and qi < queue.items.len) : (qi += 1) {
        const at = queue.items[qi];
        try account.reserve(.path, 1);
        const steps = places.steps(places.pathPlace(at)).steps;
        for (steps) |st| {
            const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
            if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
            try queue.append(gpa, nx);
            if (try note(t, gpa, account, places, nx, &found, &acc)) {
                whole = true;
                break :walk;
            }
        }
    }
    return if (whole) try t.internSorted(gpa, account, &.{p.int() | Slots.sub_bit}) else try t.sorted(gpa, account, acc.items);
}

/// Add path `at`'s object slots to `acc` (each once); whether there
/// are now more than `Slots.below_min`.
fn note(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, at: PathId, seen: *Ids.FixedDict(1), acc: *std.ArrayList(u32)) Error!bool {
    if (!Slots.isObject(places, at)) return false;
    for (t.items(try t.canon(gpa, account, places, at))) |c| {
        if ((try seen.getOrPut(gpa, .{c})).found_existing) continue;
        try acc.append(gpa, c);
    }
    return acc.items.len > Slots.below_min;
}

/// `below` of every slot of `s`, joined. A symbol is its own `below`;
/// an exclusion is dropped (what is below an excluded slot stays).
pub fn belowSet(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, s: SetId) Error!SetId {
    // One sort of every member's run, never a union per member: the
    // cost is linear in the parts, not in their product.
    const xs = t.elems(s);
    if (xs.len == 1 and xs[0] < Slots.not_bit) return below(t, gpa, account, places, .from(xs[0]));
    if (xs.len == 1 and Slots.isSub(xs[0])) return s;
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    for (xs) |x| {
        if (Slots.isSub(x)) {
            try acc.append(gpa, x);
        } else if (!Slots.isNot(x)) try acc.appendSlice(gpa, t.elems(try below(t, gpa, account, places, .from(x))));
    }
    return t.sorted(gpa, account, acc.items);
}

/// `s`'s slots written out: its symbols' through `belowAll`, for a
/// reader that names each slot; exclusions left out.
pub fn writeOut(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, s: SetId) Error!SetId {
    if (!symbolic(t, s)) return s;
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    try acc.appendSlice(gpa, explicit(t, s));
    for (subs(t, s)) |x| try acc.appendSlice(gpa, t.items(try belowAll(t, gpa, account, places, Slots.pathOf(x))));
    return t.sorted(gpa, account, acc.items);
}

/// `s` without the slots of the sets `minus`, null when nothing is
/// left: an explicit slot one of them holds is dropped; a symbol stays,
/// with their explicit slots excluded (a superset where they hold one).
pub fn without(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, s: SetId, minus: []const SetId) Error!?SetId {
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    outer: for (explicit(t, s)) |sl| {
        for (minus) |m| if (try contains(t, gpa, account, places, m, .from(sl))) continue :outer;
        try acc.append(gpa, sl);
    }
    if (symbolic(t, s)) {
        for (minus) |m| for (explicit(t, m)) |x| try acc.append(gpa, x | Slots.not_bit);
        try acc.appendSlice(gpa, subs(t, s));
    }
    if (acc.items.len == 0) return null;
    return try t.sorted(gpa, account, acc.items);
}

/// Whether two sets share a slot. Explicit runs by one merge; a symbol
/// `↓p` by prefix tests on its anchors (§2.3.1): an explicit slot of the
/// other set is in it when an anchor of `p` is a prefix of the slot, and
/// two symbols meet when an anchor of one is a prefix of an anchor of the
/// other at or below which something holds an object. Never by writing
/// out `below(p)`. An exclusion is read against explicit slots only.
pub fn meetIn(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, a: SetId, b: SetId) Error!bool {
    if (@import("Mutate.zig").on(.meet_in_never)) return false;
    if (!symbolic(t, a) and !symbolic(t, b)) return t.meet(account, a, b);
    if (a == empty or b == empty) return false;
    if (a == b) return true;
    for (explicit(t, a)) |x| if (try contains(t, gpa, account, places, b, .from(x))) return true;
    for (explicit(t, b)) |y| if (try contains(t, gpa, account, places, a, .from(y))) return true;
    for (subs(t, a)) |x| for (subs(t, b)) |y| {
        if (try subsMeet(t, gpa, account, places, Slots.pathOf(x), Slots.pathOf(y))) return true;
    };
    return false;
}

/// Whether explicit object slot `q` is in set `s`.
pub fn contains(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, s: SetId, q: PathId) Error!bool {
    const ex = explicit(t, s);
    try account.reserve(.inspection, 1);
    if (std.sort.binarySearch(u32, ex, q.int(), Table.order) != null) return true;
    const xs = t.elems(s);
    if (std.sort.binarySearch(u32, xs[ex.len..], q.int() | Slots.not_bit, Table.order) != null) return false;
    for (subs(t, s)) |x| if (try inBelow(t, gpa, account, places, Slots.pathOf(x), q)) return true;
    return false;
}

/// Whether path `q` is in `below(p)`: an anchor of `p` is a prefix of it.
pub fn inBelow(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId, q: PathId) Error!bool {
    for (t.elems(try anchors(t, gpa, account, places, p))) |a| {
        try account.reserve(.path, 1 + places.ancestorAt(q, places.pathDepth(.from(a)))[1]);
        if (places.isPrefix(.from(a), q)) return true;
    }
    return false;
}

/// Whether `below(p)` and `below(r)` share an object slot: an anchor of
/// one is a prefix of an anchor of the other, and something at or below
/// the deeper one holds an object.
fn subsMeet(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId, r: PathId) Error!bool {
    const ap = try anchors(t, gpa, account, places, p);
    const ar = try anchors(t, gpa, account, places, r);
    for (t.elems(ap)) |a0| for (t.elems(ar)) |b0| {
        const a: PathId = .from(a0);
        const b: PathId = .from(b0);
        try account.reserve(.path, 1 + places.ancestorAt(a, places.pathDepth(b))[1] + places.ancestorAt(b, places.pathDepth(a))[1]);
        if (places.isPrefix(a, b) and Slots.holdsAny(places, b)) return true;
        if (places.isPrefix(b, a) and Slots.holdsAny(places, a)) return true;
    };
    return false;
}

/// The anchors of `p`: paths every slot of `below(p)` lies at or under.
/// `p` itself and `Up(p)` (§2.7: the `⟲` paths above `p` that its levels
/// fold into, closed over theirs), each with its canonical names
/// (`Place.expandLevels`), so a slot named through a join lies under
/// one. Memoised per path, a run of `sets`.
pub fn anchors(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
    try account.reserve(.memo, 1);
    if (t.anchor_of.get(p)) |hit| {
        try account.readEntry(gpa, .anchors, p.int(), t.anchor_cost.get(p.int()));
        return hit;
    }
    const fill = account.beginFill();
    const s = anchorsFill(t, gpa, account, places, p) catch |err| {
        _ = account.endFill(fill);
        return err;
    };
    const cost = account.endFill(fill);
    try t.anchor_of.put(gpa, p, s);
    try t.anchor_cost.put(gpa, p.int(), cost);
    try account.readEntry(gpa, .anchors, p.int(), cost);
    return s;
}

fn anchorsFill(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
    var out: std.ArrayList(PathId) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, p);
    const r = try places.foldsUp(gpa, .growth(account), p);
    var k: u32 = 0;
    while (k < r.len) : (k += 1) try out.append(gpa, places.foldPath(r.start + k));
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    var ex: std.ArrayList(PathId) = .empty;
    defer ex.deinit(gpa);
    for (out.items) |x| {
        try acc.append(gpa, x.int());
        ex.clearRetainingCapacity();
        try places.expandLevels(gpa, .growth(account), x, &ex);
        for (ex.items) |y| try acc.append(gpa, y.int());
    }
    return t.sorted(gpa, account, acc.items);
}

/// `below(p)` written out, whatever its size: for a reader that must name
/// each slot (a contract says one arrival at every result slot below a
/// cast, which no wide entry can say, §2.3.1). The walk `below` stops;
/// filled once per path, charged on the asker's account like `below`.
pub fn belowAll(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
    const s = try below(t, gpa, account, places, p);
    if (!symbolic(t, s)) return s;
    if (t.all_of.get(p)) |hit| {
        try account.readEntry(gpa, .below_all, p.int(), t.all_cost.get(p.int()));
        return hit;
    }
    const fill = account.beginFill();
    const all = belowAllFill(t, gpa, account, places, p) catch |err| {
        _ = account.endFill(fill);
        return err;
    };
    const cost = account.endFill(fill);
    try t.all_of.put(gpa, p, all);
    try t.all_cost.put(gpa, p.int(), cost);
    try account.readEntry(gpa, .below_all, p.int(), cost);
    return all;
}

fn belowAllFill(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
    var queue: std.ArrayList(PathId) = .empty;
    defer queue.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    try queue.append(gpa, p);
    _ = try seen.getOrPut(gpa, .{p.int()});
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const at = queue.items[qi];
        try account.reserve(.path, 1);
        if (Slots.isObject(places, at)) try acc.appendSlice(gpa, t.items(try t.canon(gpa, account, places, at)));
        for (places.steps(places.pathPlace(at)).steps) |st| {
            const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
            if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
            try queue.append(gpa, nx);
        }
    }
    return t.sorted(gpa, account, acc.items);
}
