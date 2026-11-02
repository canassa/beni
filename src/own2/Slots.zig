//! L2: slots (`docs/design/ownership-v2.md` §2.3.1, §3.2): the module's
//! slot sets, the object slots at and below a path (`below`), a slot's
//! canonical name (`canon`, its expansion through `Place.expandLevels`),
//! and relative steps (`Rel`, a contract's slots, by their step words).
//!
//! A slot is a canonical path of `Place.Table`; an object slot is one whose
//! place holds an object. A slot set is a sorted, deduplicated run of
//! expanded object slots, interned by content, so two sets meet exactly
//! when their runs share an element (one merge). Every fill is reserved on
//! the asking account before its work (§4.1); a hit is one record.
//!
//! Obligations kept here: none of §2.14's directly (tables only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const Error = Ids.ChargeError;
pub const Step = Place.Step;
const none: u32 = Ids.none_int;

/// A slot set: an index of `Table.sets`; `empty` is the empty set.
pub const SetId = u32;
pub const empty: SetId = 0;

/// Relative steps: an index of `Table.rels`; `root` is no step.
pub const Rel = u32;
pub const root: Rel = 0;

/// Runs of words interned by content: a 64-bit hash names a chain, each
/// run once. Run 0 is the empty run. Each run is its own allocation in the
/// table's arena, so a run read stays valid while others are interned.
const Runs = struct {
    store: std.heap.ArenaAllocator.State = .{},
    runs: std.ArrayList([]const u32) = .empty,
    heads: Ids.FixedDict(2) = .{},
    next: std.ArrayList(u32) = .empty,

    fn deinit(r: *Runs, gpa: Allocator) void {
        r.store.promote(gpa).deinit();
        r.runs.deinit(gpa);
        r.heads.deinit(gpa);
        r.next.deinit(gpa);
    }

    fn ensureEmpty(r: *Runs, gpa: Allocator) Allocator.Error!void {
        if (r.runs.items.len != 0) return;
        try r.runs.append(gpa, &.{});
        try r.next.append(gpa, none);
    }

    fn get(r: *const Runs, id: u32) []const u32 {
        return r.runs.items[id];
    }

    fn intern(r: *Runs, gpa: Allocator, items: []const u32) Ids.IndexError!u32 {
        try r.ensureEmpty(gpa);
        if (items.len == 0) return 0;
        const h = std.hash.Wyhash.hash(0x51075, std.mem.sliceAsBytes(items));
        const key: [2]u32 = .{ @truncate(h), @truncate(h >> 32) };
        const got = try r.heads.getOrPut(gpa, key);
        if (got.found_existing) {
            var at = got.value_ptr.*;
            while (at != none) : (at = r.next.items[at]) if (std.mem.eql(u32, r.get(at), items)) return at;
        }
        const id: u32 = @intCast(r.runs.items.len);
        var arena = r.store.promote(gpa);
        const own = arena.allocator().dupe(u32, items);
        r.store = arena.state;
        try r.runs.append(gpa, try own);
        try r.next.append(gpa, if (got.found_existing) got.value_ptr.* else none);
        got.value_ptr.* = id;
        return id;
    }
};

/// A column of `u32` by a dense id, `none` where not filled.
const ByPath = struct {
    items: std.ArrayList(u32) = .empty,

    fn deinit(c: *ByPath, gpa: Allocator) void {
        c.items.deinit(gpa);
    }
    fn get(c: *const ByPath, p: PathId) ?u32 {
        const i = p.int();
        if (i >= c.items.items.len or c.items.items[i] == none) return null;
        return c.items.items[i];
    }
    fn put(c: *ByPath, gpa: Allocator, p: PathId, v: u32) Allocator.Error!void {
        const i = p.int();
        if (i >= c.items.items.len) try c.items.appendNTimes(gpa, none, i + 1 - c.items.items.len);
        c.items.items[i] = v;
    }
};

pub const Table = struct {
    sets: Runs = .{},
    rels: Runs = .{},
    below_of: ByPath = .{},
    canon_of: ByPath = .{},
    rel_of: ByPath = .{},
    /// Per relative run: its canonical key, three words a step (the kind,
    /// a constructor step's `(ordinal, argument)` and not its pair index,
    /// which is module-local), so the order of §2.10 is the same in every
    /// module.
    keys: Runs = .{},
    key_of: std.ArrayList(u32) = .empty,
    /// Per relative run, a root-relative path at each root place it was
    /// replayed from is not kept: replay walks `extend`, which Place memoises.
    scratch: std.ArrayList(u32) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.sets.deinit(gpa);
        t.rels.deinit(gpa);
        t.below_of.deinit(gpa);
        t.canon_of.deinit(gpa);
        t.rel_of.deinit(gpa);
        t.keys.deinit(gpa);
        t.key_of.deinit(gpa);
        t.scratch.deinit(gpa);
    }

    pub fn items(t: *const Table, s: SetId) []const u32 {
        if (s == empty) return &.{};
        return t.sets.get(s);
    }

    pub fn relWords(t: *const Table, r: Rel) []const u32 {
        if (r == root) return &.{};
        return t.rels.get(r);
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

    pub fn unionOf(t: *Table, gpa: Allocator, account: *Ids.Account, a: SetId, b: SetId) Error!SetId {
        if (a == b or b == empty) return a;
        if (a == empty) return b;
        const xs = t.items(a);
        const ys = t.items(b);
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

    /// Whether two sets share a slot: one merge, charged.
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

    pub fn has(t: *const Table, s: SetId, p: u32) bool {
        return std.sort.binarySearch(u32, t.items(s), p, struct {
            fn f(k: u32, x: u32) std.math.Order {
                return std.math.order(k, x);
            }
        }.f) != null;
    }

    /// `p`'s canonical names, as a set of the object slots among them; a
    /// slot that is not an object slot is the empty set.
    pub fn canon(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
        try account.reserve(.memo, 1);
        if (t.canon_of.get(p)) |hit| return hit;
        var out: std.ArrayList(PathId) = .empty;
        defer out.deinit(gpa);
        try places.expandLevels(gpa, .growth(account), p, &out);
        var run: std.ArrayList(u32) = .empty;
        defer run.deinit(gpa);
        for (out.items) |x| if (isObject(places, x)) try run.append(gpa, x.int());
        const s = try t.sorted(gpa, account, run.items);
        try t.canon_of.put(gpa, p, s);
        return s;
    }

    /// `below(p)`: the object slots at and below `p`, by their canonical
    /// names (§2.3.1): a walk of `extend` over each place's steps, each path
    /// once, filled once per path.
    pub fn below(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, p: PathId) Error!SetId {
        try account.reserve(.memo, 1);
        if (t.below_of.get(p)) |hit| return hit;
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
            if (isObject(places, at)) for (t.items(try t.canon(gpa, account, places, at))) |c| try acc.append(gpa, c);
            const steps = places.steps(places.pathPlace(at)).steps;
            for (steps) |st| {
                const nx = (try places.extend(gpa, .growth(account), at, st)) orelse continue;
                if ((try seen.getOrPut(gpa, .{nx.int()})).found_existing) continue;
                try queue.append(gpa, nx);
            }
        }
        const s = try t.sorted(gpa, account, acc.items);
        try t.below_of.put(gpa, p, s);
        return s;
    }

    /// `below` of every slot of `s`, joined.
    pub fn belowSet(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, s: SetId) Error!SetId {
        var acc: SetId = empty;
        for (t.items(s)) |x| acc = try t.unionOf(gpa, account, acc, try t.below(gpa, account, places, .from(x)));
        return acc;
    }

    /// The relative steps of path `p` from its root.
    pub fn relOf(t: *Table, gpa: Allocator, account: *Ids.Account, places: *const Place.Table, p: PathId) Error!Rel {
        try account.reserve(.memo, 1);
        if (t.rel_of.get(p)) |hit| return hit;
        t.scratch.clearRetainingCapacity();
        var at = p;
        while (places.pathParent(at) != .none) : (at = places.pathParent(at)) {
            try account.reserve(.path, 1);
            try t.scratch.append(gpa, places.pathStep(at).word());
        }
        std.mem.reverse(u32, t.scratch.items);
        const r = try t.internRel(gpa, places, t.scratch.items);
        try t.rel_of.put(gpa, p, r);
        return r;
    }

    /// Intern a run of step words.
    pub fn relOfWords(t: *Table, gpa: Allocator, account: *Ids.Account, places: *const Place.Table, words: []const u32) Error!Rel {
        try account.reserve(.path, @intCast(@max(1, words.len)));
        return t.internRel(gpa, places, words);
    }

    /// The relative steps of `p` below `from`, a prefix of it (or `root`
    /// when it is not one).
    pub fn relBelow(t: *Table, gpa: Allocator, account: *Ids.Account, places: *const Place.Table, from: PathId, p: PathId) Error!?Rel {
        const a = t.relWords(try t.relOf(gpa, account, places, from));
        const b = t.relWords(try t.relOf(gpa, account, places, p));
        if (b.len < a.len or !std.mem.eql(u32, a, b[0..a.len])) return null;
        const rest = try gpa.dupe(u32, b[a.len..]);
        defer gpa.free(rest);
        return try t.relOfWords(gpa, account, places, rest);
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
