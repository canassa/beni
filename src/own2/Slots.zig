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
    /// Per path: its index in `walks`, a run of `steps` (`relBelow`'s
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

    /// The relative steps of `p` below `from`, a prefix of it (or `root`
    /// when it is not one).
    /// A path below `from` whose canonical name folds at a level (§2.3.1:
    /// `#Rose.1[*]⟲#Rose.0` below `#Rose.1[*]#Rose.1`) is no textual
    /// extension of it: its steps are then the shortest ones the place graph
    /// takes from `from` to it, found by one walk per `from`, a module
    /// table like `below`'s.
    pub fn relBelow(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId, p: PathId) Error!?Rel {
        const a = t.relWords(try t.relOf(gpa, account, places, from));
        const b = t.relWords(try t.relOf(gpa, account, places, p));
        if (b.len >= a.len and std.mem.eql(u32, a, b[0..a.len])) {
            const rest = try gpa.dupe(u32, b[a.len..]);
            defer gpa.free(rest);
            return try t.relOfWords(gpa, account, places, rest);
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
        for (t.steps.items[run[0]..][0..run[1]]) |x| if (x[0] == p.int()) return x[1];
        return null;
    }

    /// Every path the place graph reaches from `from`, each with the
    /// shortest steps to it: the index of its run in `walks`.
    fn walkFrom(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId) Error!u32 {
        const start: u32 = @intCast(t.steps.items.len);
        var queue: std.ArrayList(struct { PathId, Rel }) = .empty;
        defer queue.deinit(gpa);
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(gpa);
        try queue.append(gpa, .{ from, root });
        _ = try seen.getOrPut(gpa, .{from.int()});
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const at, const rel = queue.items[qi];
            try account.reserve(.path, 1);
            try t.steps.append(gpa, .{ at.int(), rel });
            for (places.steps(places.pathPlace(at)).steps) |st| {
                const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
                if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
                words.clearRetainingCapacity();
                try words.appendSlice(gpa, t.relWords(rel));
                try words.append(gpa, st.word());
                try queue.append(gpa, .{ nx, try t.relOfWords(gpa, account, places, words.items) });
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

/// Whether a `⟲` replayed at `at` folds onto it (a level or a return
/// node), so `extend` names the levels; elsewhere a `⟲` is every level
/// below at the same place (`Place.levelsOf`), never a path no type has
/// (the experiment's fourth requirement).
fn folds(places: *const Place.Table, at: PathId) bool {
    if (places.pathParent(at) == .none) return false;
    return places.pathStep(at).kind == .level or places.isReturn(at);
}

/// `from · words` as canonical paths, appended to `out` (each once): a
/// `⟲` where `from`'s path does not fold is every level below at its own
/// place, then the rest of the steps from each.
pub fn replay(gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId, words: []const u32, out: *std.ArrayList(u32)) Error!void {
    var cur: std.ArrayList(u32) = .empty;
    defer cur.deinit(gpa);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(gpa);
    try cur.append(gpa, from.int());
    for (words) |w| {
        const st = Step.fromWord(w);
        next.clearRetainingCapacity();
        for (cur.items) |a| {
            const at: PathId = .from(a);
            try account.reserve(.path, 1);
            if (st.kind == .level and !folds(places, at)) {
                const r = try places.levelsOf(gpa, .growth(account), at);
                var k: u32 = 0;
                while (k < r.len) : (k += 1) try next.append(gpa, places.foldPath(r.start + k).int());
                continue;
            }
            const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
            try next.append(gpa, nx.int());
        }
        std.mem.sort(u32, next.items, {}, std.sort.asc(u32));
        cur.clearRetainingCapacity();
        for (next.items) |x| if (cur.items.len == 0 or cur.items[cur.items.len - 1] != x) try cur.append(gpa, x);
        if (cur.items.len == 0) return;
    }
    try out.appendSlice(gpa, cur.items);
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
