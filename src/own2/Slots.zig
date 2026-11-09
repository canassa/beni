//! L2: slots (`docs/design/ownership-v2.md` §2.3.1, §3.2): the module's
//! slot sets and their tables (`below`'s is filled by `Subtree`), a
//! slot's canonical name (`canon`, its expansion through
//! `Place.expandLevels`), and relative steps (`Rel`, a contract's slots,
//! by their step words).
//!
//! A slot is a canonical path of `Place.Table`; an object slot is one whose
//! place holds an object. A slot set is a sorted, deduplicated run of
//! expanded object slots, then exclusions and symbols `↓p` (§2.3.1), interned
//! by content; two runs of explicit slots meet by one merge, a symbol by
//! `Subtree.meetIn`. Every fill is reserved on
//! the asking account before its work (§4.1); a hit is one record.
//!
//! Obligations kept here: none of §2.14's directly (tables only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const WordRun = @import("WordRun.zig");
const Runs = @import("Runs.zig").Runs;
const ByPath = @import("Runs.zig").ByPath;

pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const Error = Ids.ChargeError;
pub const Step = Place.Step;
const none: u32 = Ids.none_int;

/// A slot set: an index of `Table.sets`; `empty` is the empty set.
pub const SetId = u32;
pub const empty: SetId = 0;

/// A set's element `sub_bit | p` is the symbol `↓p`, every object slot of
/// `below(p)` (§2.3.1, *A subtree held whole*; `Subtree` reads it);
/// `not_bit | q` excludes the explicit slot `q` from the set's symbols.
/// Explicit slots sort first, then exclusions, then symbols.
pub const sub_bit: u32 = 1 << 31;
pub const not_bit: u32 = 1 << 30;
/// A subtree of more object slots than this is held whole, as `↓p`; a
/// smaller one is written out, which costs less to read slot by slot. A
/// reader that reads a whole subtree through one key or one effect at its
/// top does so exactly when the set is `↓p` (§2.10 *Read-off*).
pub const below_min: usize = Place.below_min;

pub fn isSub(x: u32) bool {
    return x & sub_bit != 0;
}

pub fn isNot(x: u32) bool {
    return x & (sub_bit | not_bit) == not_bit;
}

/// The path of an element, whatever its kind.
pub fn pathOf(x: u32) PathId {
    return .from(x & ~(sub_bit | not_bit));
}

/// Relative steps: an index of `Table.rels`; `root` is no step.
pub const Rel = u32;
pub const root: Rel = 0;

pub const Table = struct {
    sets: Runs = .{},
    rels: Runs = .{},
    below_of: ByPath = .{},
    canon_of: ByPath = .{},
    rel_of: ByPath = .{},
    /// Per path: its index in `walks`, a run of `steps` (`relsBelow`'s
    /// walk from it).
    steps_of: ByPath = .{},
    walks: std.ArrayList([2]u32) = .empty,
    steps: std.ArrayList([2]u32) = .empty,
    /// Per relative run: its canonical key, three words a step (the kind,
    /// a constructor step's `(ordinal, argument)` and not its pair index,
    /// which is module-local), so the order of §2.10 is the same in every
    /// module.
    keys: Runs = .{},
    key_of: std.ArrayList(u32) = .empty,
    /// Per relative run, a root-relative path at each root place it was
    /// replayed from is not kept: replay walks `extend`, which Place memoises.
    scratch: std.ArrayList(u32) = .empty,
    /// Per path: its anchors (`anchors`), a run of `sets`.
    anchor_of: ByPath = .{},
    /// Per path whose `below` is a symbol: `belowAll`, written out.
    all_of: ByPath = .{},
    /// Each table's fill costs, by path (§4.1, *A module table's entries*).
    canon_cost: Ids.Costs = .{},
    rel_cost: Ids.Costs = .{},
    walk_cost: Ids.Costs = .{},
    below_cost: Ids.Costs = .{},
    anchor_cost: Ids.Costs = .{},
    all_cost: Ids.Costs = .{},

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.anchor_of.deinit(gpa);
        t.all_of.deinit(gpa);
        inline for (.{ &t.canon_cost, &t.rel_cost, &t.walk_cost, &t.below_cost, &t.anchor_cost, &t.all_cost }) |c| c.deinit(gpa);
        t.sets.deinit(gpa);
        t.rels.deinit(gpa);
        t.below_of.deinit(gpa);
        t.canon_of.deinit(gpa);
        t.rel_of.deinit(gpa);
        t.steps_of.deinit(gpa);
        t.steps.deinit(gpa);
        t.walks.deinit(gpa);
        t.keys.deinit(gpa);
        t.key_of.deinit(gpa);
        t.scratch.deinit(gpa);
    }

    /// The slots of a set that holds no symbol. A reader that may meet a
    /// symbol reads `elems` and handles `↓p` itself.
    pub fn items(t: *const Table, s: SetId) []const u32 {
        if (s == empty) return &.{};
        const xs = t.sets.get(s);
        if (std.debug.runtime_safety) std.debug.assert(xs.len == 0 or xs[xs.len - 1] < not_bit);
        return xs;
    }

    /// Every element of a set: explicit slots, then exclusions, then symbols.
    pub fn elems(t: *const Table, s: SetId) []const u32 {
        if (s == empty) return &.{};
        return t.sets.get(s);
    }

    pub fn relWords(t: *const Table, r: Rel) []const u32 {
        if (r == root) return &.{};
        return t.rels.get(r);
    }

    /// `r`'s canonical key: a prefix of steps has a prefix of keys.
    pub fn relKey(t: *const Table, r: Rel) []const u32 {
        return t.keyOf(r);
    }

    fn keyOf(t: *const Table, r: Rel) []const u32 {
        if (r == root or r >= t.key_of.items.len) return &.{};
        return t.keys.get(t.key_of.items[r]);
    }

    /// Whether `a`'s steps sort before `b`'s (the canonical order of §2.10,
    /// by canonical keys, never by intern order).
    pub fn relLess(t: *const Table, a: Rel, b: Rel) bool {
        return t.relOrder(a, b) == .lt;
    }

    pub fn relOrder(t: *const Table, a: Rel, b: Rel) std.math.Order {
        return std.mem.order(u32, t.keyOf(a), t.keyOf(b));
    }

    /// Intern a run of step words and its canonical key.
    fn internRel(t: *Table, gpa: Allocator, places: *const Place.Table, words: []const u32) Error!Rel {
        const r = try t.rels.intern(gpa, words);
        if (r == root) return r;
        while (t.key_of.items.len <= r) try t.key_of.append(gpa, none);
        if (t.key_of.items[r] != none) return r;
        var key: std.ArrayList(u32) = .empty;
        defer key.deinit(gpa);
        for (words) |w| {
            const s = Step.fromWord(w);
            if (s.kind == .ctor_arg) {
                const ca = places.ctorArgOf(s);
                try key.appendSlice(gpa, &.{ @backingInt(s.kind), ca[0], ca[1] });
            } else if (s.isRow()) {
                // One row step leaves a place, so its names order nothing.
                try key.appendSlice(gpa, &.{ @backingInt(s.kind), 0, 0 });
            } else try key.appendSlice(gpa, &.{ @backingInt(s.kind), s.payload, 0 });
        }
        t.key_of.items[r] = try t.keys.intern(gpa, key.items);
        return r;
    }

    /// Intern a run of slots already sorted and deduplicated.
    pub fn internSorted(t: *Table, gpa: Allocator, account: *Ids.Account, run: []const u32) Error!SetId {
        try account.reserve(.set, @intCast(@max(1, run.len)));
        return t.sets.intern(gpa, run);
    }

    /// The set of the object slots among `paths`, each by its canonical
    /// names (§2.3.1): expanded, filtered, sorted, deduplicated.
    pub fn setOf(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, paths: []const u32) Error!SetId {
        var acc: std.ArrayList(u32) = .empty;
        defer acc.deinit(gpa);
        for (paths) |p| for (t.items(try t.canon(gpa, account, places, .from(p)))) |c| try acc.append(gpa, c);
        return t.sorted(gpa, account, acc.items);
    }

    /// Sort, deduplicate and intern `run` (owned by the caller, reordered).
    pub fn sorted(t: *Table, gpa: Allocator, account: *Ids.Account, run: []u32) Error!SetId {
        std.mem.sort(u32, run, {}, std.sort.asc(u32));
        var n: usize = 0;
        for (run) |x| {
            if (n != 0 and run[n - 1] == x) continue;
            run[n] = x;
            n += 1;
        }
        return t.internSorted(gpa, account, run[0..n]);
    }

    /// The union of two sets. An exclusion of either is dropped: a slot one
    /// side excludes, the other may hold (a superset, never a subset).
    pub fn unionOf(t: *Table, gpa: Allocator, account: *Ids.Account, a: SetId, b: SetId) Error!SetId {
        if (a == b or b == empty) return a;
        if (a == empty) return b;
        if (t.hasNot(a) or t.hasNot(b)) {
            var acc: std.ArrayList(u32) = .empty;
            defer acc.deinit(gpa);
            for ([_]SetId{ a, b }) |x| for (t.elems(x)) |y| if (!isNot(y)) try acc.append(gpa, y);
            return t.sorted(gpa, account, acc.items);
        }
        const xs = t.elems(a);
        const ys = t.elems(b);
        try account.reserve(.set, @intCast(xs.len + ys.len));
        var out = try std.ArrayList(u32).initCapacity(gpa, xs.len + ys.len);
        defer out.deinit(gpa);
        var i: usize = 0;
        var j: usize = 0;
        while (i < xs.len or j < ys.len) {
            if (j >= ys.len or (i < xs.len and xs[i] < ys[j])) {
                out.appendAssumeCapacity(xs[i]);
                i += 1;
            } else if (i >= xs.len or ys[j] < xs[i]) {
                out.appendAssumeCapacity(ys[j]);
                j += 1;
            } else {
                out.appendAssumeCapacity(xs[i]);
                i += 1;
                j += 1;
            }
        }
        return t.sets.intern(gpa, out.items);
    }

    fn hasNot(t: *const Table, s: SetId) bool {
        for (t.elems(s)) |x| if (isNot(x)) return true;
        return false;
    }

    /// Whether two sets of explicit slots share a slot: one merge, charged.
    pub fn meet(t: *const Table, account: *Ids.Account, a: SetId, b: SetId) Ids.AccountError!bool {
        if (a == empty or b == empty) return false;
        if (a == b) return true;
        const xs = t.items(a);
        const ys = t.items(b);
        try account.reserve(.inspection, @intCast(@max(1, (xs.len + ys.len) / 8)));
        var i: usize = 0;
        var j: usize = 0;
        while (i < xs.len and j < ys.len) {
            if (xs[i] == ys[j]) return true;
            if (xs[i] < ys[j]) i += 1 else j += 1;
        }
        return false;
    }

    pub fn order(k: u32, x: u32) std.math.Order {
        return std.math.order(k, x);
    }

    pub fn has(t: *const Table, s: SetId, p: u32) bool {
        return std.sort.binarySearch(u32, t.items(s), p, order) != null;
    }

    /// `p`'s canonical names, as a set of the object slots among them; a
    /// slot that is not an object slot is the empty set.
    pub fn canon(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
        try account.reserve(.memo, 1);
        // No `⟲` on the way: `p` is its own name, read off its node (§2.3.1).
        if (!places.paths.col.info[p.int()].levels) return t.sets.intern(gpa, if (isObject(places, p)) &.{p.int()} else &.{});
        if (t.canon_of.get(p)) |hit| {
            try account.readEntry(gpa, .canon, p.int(), t.canon_cost.get(p.int()));
            return hit;
        }
        const fill = account.beginFill();
        const s = t.canonFill(gpa, account, places, p) catch |err| {
            _ = account.endFill(fill);
            return err;
        };
        const cost = account.endFill(fill);
        try t.canon_of.put(gpa, p, s);
        try t.canon_cost.put(gpa, p.int(), cost);
        try account.readEntry(gpa, .canon, p.int(), cost);
        return s;
    }

    /// The other names of `p`: `Place.expandLevels`'s, when a `⟲` on it is a join.
    /// Empty otherwise, in one read of a column; an object's, read off `canon`.
    pub fn joinNames(t: *Table, gpa: Allocator, arena: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error![]const u32 {
        if (!places.paths.col.info[p.int()].joins or @import("Mutate.zig").on(.level_join_kept)) return &.{};
        if (isObject(places, p)) {
            const names = t.items(try t.canon(gpa, account, places, p));
            return if (names.len == 1 and names[0] == p.int()) &.{} else arena.dupe(u32, names);
        }
        var out: std.ArrayList(PathId) = .empty;
        defer out.deinit(gpa);
        try places.expandLevels(gpa, .growth(account), p, &out);
        return if (out.items.len == 1 and out.items[0] == p) &.{} else arena.dupe(u32, @ptrCast(out.items));
    }

    fn canonFill(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
        var out: std.ArrayList(PathId) = .empty;
        defer out.deinit(gpa);
        try places.expandLevels(gpa, .growth(account), p, &out);
        var run: std.ArrayList(u32) = .empty;
        defer run.deinit(gpa);
        for (out.items) |x| if (isObject(places, x)) try run.append(gpa, x.int());
        return t.sorted(gpa, account, run.items);
    }

    /// The relative steps of path `p` from its root.
    pub fn relOf(t: *Table, gpa: Allocator, account: *Ids.Account, places: *const Place.Table, p: PathId) Error!Rel {
        try account.reserve(.memo, 1);
        if (t.rel_of.get(p)) |hit| {
            try account.readEntry(gpa, .rel_of, p.int(), t.rel_cost.get(p.int()));
            return hit;
        }
        // The fill's cost is one record a step, counted by depth.
        t.scratch.clearRetainingCapacity();
        var at = p;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) try t.scratch.append(gpa, places.pathStep(at).word());
        std.mem.reverse(u32, t.scratch.items);
        const r = try t.internRel(gpa, places, t.scratch.items);
        const cost: u64 = t.scratch.items.len;
        try t.rel_of.put(gpa, p, r);
        try t.rel_cost.put(gpa, p.int(), cost);
        try account.readEntry(gpa, .rel_of, p.int(), cost);
        return r;
    }

    /// Intern a run of step words.
    pub fn relOfWords(t: *Table, gpa: Allocator, account: *Ids.Account, places: *const Place.Table, words: []const u32) Error!Rel {
        try account.reserve(.path, @intCast(@max(1, words.len)));
        return t.internRel(gpa, places, words);
    }

    /// The relative steps of `p` below a root's `ε` path `from`: `p`'s own
    /// words, its one route. Any other `from` takes `relsBelow`, which
    /// names every route (§2.1, *Every name*).
    pub fn relUnder(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId, p: PathId) Error!?Rel {
        if (std.debug.runtime_safety) std.debug.assert(places.pathParent(from) == .none);
        const a = t.relWords(try t.relOf(gpa, account, places, from));
        const b = t.relWords(try t.relOf(gpa, account, places, p));
        if (!WordRun.startsAt(b, a)) return null;
        const rest = try gpa.dupe(u32, b[a.len..]);
        defer gpa.free(rest);
        return try t.relOfWords(gpa, account, places, rest);
    }

    /// Every run of steps naming `p` below `from`, in `into` (§2.1, *Every
    /// name*). Below a `from` with no `⟲`, a textual extension has its own
    /// steps alone: a fold lands on a `⟲`, never below such a `from`. Any
    /// other `p` (one folded above `from`, §2.3.1, or one below a `from`
    /// inside a level) has each name `walkFrom` pairs it with; a `⟲` in one
    /// is every route around its cycle where it is replayed. None when unreached.
    pub fn relsBelow(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId, p: PathId, into: Allocator) Error![]Rel {
        const a = t.relWords(try t.relOf(gpa, account, places, from));
        const b = t.relWords(try t.relOf(gpa, account, places, p));
        if (!places.paths.col.info[from.int()].levels and WordRun.startsAt(b, a)) {
            const rest = try gpa.dupe(u32, b[a.len..]);
            defer gpa.free(rest);
            return into.dupe(Rel, &.{try t.relOfWords(gpa, account, places, rest)});
        }
        try account.reserve(.memo, 1);
        const wi = if (t.steps_of.get(from)) |hit| hit else blk: {
            const fill = account.beginFill();
            const got = t.walkFrom(gpa, account, places, from) catch |err| {
                _ = account.endFill(fill);
                return err;
            };
            try t.walk_cost.put(gpa, from.int(), account.endFill(fill));
            break :blk got;
        };
        try account.readEntry(gpa, .rel_walk, from.int(), t.walk_cost.get(from.int()));
        const run = t.walks.items[wi];
        var out: std.ArrayList(Rel) = .empty;
        for (t.steps.items[run[0]..][0..run[1]]) |x| if (x[0] == p.int()) {
            try out.append(into, x[1]);
            if (@import("Mutate.zig").on(.reroot_one_route)) break;
        };
        return out.toOwnedSlice(into);
    }

    /// `relsBelow`'s runs, each after run `at`: `p` below `from`
    /// re-rooted at `at`, interned (`at` itself where no route reaches `p`).
    pub fn relsAt(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, at: Rel, from: PathId, p: PathId, into: Allocator) Error![]Rel {
        const rels = try t.relsBelow(gpa, account, places, from, p, into);
        if (rels.len == 0) return into.dupe(Rel, &.{at});
        for (rels) |*r| {
            const ws = try std.mem.concat(gpa, u32, &.{ t.relWords(at), t.relWords(r.*) });
            defer gpa.free(ws);
            r.* = try t.relOfWords(gpa, account, places, ws);
        }
        return rels;
    }

    /// Every path the walk from `from` reaches, paired with each name the
    /// same routes reach from an `ε` of its place (`extend` on both, each
    /// pair once; both sides are finite): the index of its run in `walks`.
    fn walkFrom(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId) Error!u32 {
        const start: u32 = @intCast(t.steps.items.len);
        const top = try places.rootPath(gpa, places.pathPlace(from));
        var queue: std.ArrayList([2]PathId) = .empty;
        defer queue.deinit(gpa);
        var seen: Ids.FixedDict(2) = .{};
        defer seen.deinit(gpa);
        try queue.append(gpa, .{ from, top });
        _ = try seen.getOrPut(gpa, .{ from.int(), top.int() });
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const at, const y = queue.items[qi];
            try account.reserve(.path, 1);
            try t.steps.append(gpa, .{ at.int(), try t.relOf(gpa, account, places, y) });
            for (places.steps(places.pathPlace(at)).steps) |st| {
                // A `⟲` is no step of a route: the routes it stands for are.
                if (st.kind == .level) continue;
                const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
                // One place on both sides, so one step answers both.
                const ny = (try places.extend(gpa, .growth(account), y, st)) orelse unreachable;
                if ((try seen.getOrPut(gpa, .{ nx.int(), ny.int() })).found_existing) continue;
                try queue.append(gpa, .{ nx, ny });
            }
        }
        const wi: u32 = @intCast(t.walks.items.len);
        try t.walks.append(gpa, .{ start, @intCast(t.steps.items.len - start) });
        try t.steps_of.put(gpa, from, wi);
        return wi;
    }
};

/// Whether path `p` is an object slot.
pub fn isObject(places: *const Place.Table, p: PathId) bool {
    return !Place.Kind.own(places.kind(places.pathPlace(p))).isEmpty();
}

/// Whether anything at or below `p` holds an object.
pub fn holdsAny(places: *const Place.Table, p: PathId) bool {
    const at = places.pathPlace(p);
    return !places.holds(at).isEmpty() or !Place.Kind.own(places.kind(at)).isEmpty();
}

const testing = std.testing;

test "a set is interned by content and sets meet by one merge" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    var account: Ids.Account = .{};
    defer account.deinit(testing.allocator);
    var a = [_]u32{ 5, 3, 3, 9 };
    var b = [_]u32{ 9, 3, 5 };
    const x = try t.sorted(testing.allocator, &account, &a);
    const y = try t.sorted(testing.allocator, &account, &b);
    try testing.expectEqual(x, y);
    try testing.expectEqualSlices(u32, &.{ 3, 5, 9 }, t.items(x));
    var c = [_]u32{ 4, 7 };
    const z = try t.sorted(testing.allocator, &account, &c);
    try testing.expect(!try t.meet(&account, x, z));
    const u = try t.unionOf(testing.allocator, &account, x, z);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 5, 7, 9 }, t.items(u));
    try testing.expect(try t.meet(&account, u, z));
    try testing.expect(t.has(u, 7) and !t.has(u, 8));
}
