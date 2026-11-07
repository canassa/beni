//! L2: relative steps replayed at a path (`docs/design/ownership-v2.md` §2.3.1,
//! §2.11.2), split from `Slots`: a `⟲` taken at every level, and a record's
//! row read at a caller's record (§2.1, *The row of a record*).
//!
//! Obligations kept here: none of §2.14's directly; the row's reading is what
//! §2.1's argument for a row rests on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const StepWord = @import("StepWord.zig");

const PathId = Ids.PathId;
const Error = Ids.ChargeError;
const Step = Place.Step;

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
    for (words, 0..) |w, i| {
        const st = Step.fromWord(w);
        if (StepWord.rowThen(words[i..])) {
            if (!places.rowHolds(st, Step.fromWord(words[i + 1]))) return;
            continue;
        }
        next.clearRetainingCapacity();
        for (cur.items) |a| {
            const at: PathId = .from(a);
            try account.reserve(.path, 1);
            if (st.isRow()) {
                try rowPaths(gpa, account, places, at, st, &next);
                continue;
            }
            // No step goes on from a row: what it stands for is all below its slot.
            if (places.pathParent(at) != .none and places.pathStep(at).isRow()) {
                try next.append(gpa, a);
                continue;
            }
            if (st.kind == .level and !folds(places, at) and !@import("Mutate.zig").on(.level_replay_same)) {
                const r = try places.levelsOf(gpa, .growth(account), at);
                var k: u32 = 0;
                while (k < r.len) : (k += 1) try next.append(gpa, places.foldPath(r.start + k).int());
                continue;
            }
            const nx = try places.extend(gpa, .growth(account), at, st) orelse try rowOf(gpa, account, places, at, st) orelse continue;
            try next.append(gpa, nx.int());
        }
        std.mem.sort(u32, next.items, {}, std.sort.asc(u32));
        cur.clearRetainingCapacity();
        for (next.items) |x| if (cur.items.len == 0 or cur.items[cur.items.len - 1] != x) try cur.append(gpa, x);
        if (cur.items.len == 0) return;
    }
    try out.appendSlice(gpa, cur.items);
}

/// The row `at` holds field step `st` in: a step of a wider record that `at`'s place does not name
/// (§2.1: every object of a record is at a named field or at its row).
fn rowOf(gpa: Allocator, account: *Ids.Account, places: *Place.Table, at: PathId, st: Step) Error!?PathId {
    const p = places.pathPlace(at);
    if (places.kind(p) != .record or st.kind != .field) return null;
    const ss = places.steps(p).steps;
    if (ss.len == 0 or !ss[ss.len - 1].isRow()) return null;
    return places.extend(gpa, .growth(account), at, ss[ss.len - 1]);
}

/// Whether `words` from `at` take a step no place answers, where the place holds objects: a
/// cast's other record, or a list read as a tuple. An empty read of them has no reason (§2.14.3,
/// Lemma E): what they name is inside that place, so each of its steps goes to `out`, for a reader
/// of a value to read deep. A list of `Int`s has nothing inside, which is true. A row excludes its
/// own, and a fold's `var` and an `opaque` have readers of their own.
pub fn inside(gpa: Allocator, account: *Ids.Account, places: *Place.Table, from: PathId, words: []const u32, out: *std.ArrayList(u32)) Error!bool {
    var at = from;
    for (words, 0..) |w, i| {
        const st = Step.fromWord(w);
        if (StepWord.rowThen(words[i..])) {
            if (!places.rowHolds(st, Step.fromWord(words[i + 1]))) return false;
            continue;
        }
        at = try places.extend(gpa, .growth(account), at, st) orelse {
            const p = places.pathPlace(at);
            switch (places.kind(p)) {
                .cross, .@"var", .@"opaque" => return false,
                else => {},
            }
            if (st.kind == .level) return false;
            for (places.steps(p).steps) |s| if (try places.extend(gpa, .growth(account), at, s)) |c| try out.append(gpa, c.int());
            return true;
        };
    }
    return false;
}

/// The paths row step `st` names from `at` (§2.1, *The row of a record*): each field
/// its names do not hold and the place's own row. At any other place, a `var`'s or an
/// `opaque`'s, the place's own object: what no step of it can name is all of it.
fn rowPaths(gpa: Allocator, account: *Ids.Account, places: *Place.Table, at: PathId, st: Step, out: *std.ArrayList(u32)) Error!void {
    const p = places.pathPlace(at);
    if (places.kind(p) != .record) return out.append(gpa, at.int());
    for (places.steps(p).steps) |s| {
        if (!places.rowHolds(st, s)) continue;
        if (try places.extend(gpa, .growth(account), at, s)) |nx| try out.append(gpa, nx.int());
    }
}
