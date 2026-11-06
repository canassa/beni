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
        // A row step followed by a field's or a wider row's is that step (§2.1).
        if (st.isRow() and i + 1 < words.len and Step.fromWord(words[i + 1]).inRow()) {
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

/// The paths row step `st` names from `at` (§2.1, *The row of a record*): each field
/// its names do not hold and the place's own row. None at a place of no steps of a record.
fn rowPaths(gpa: Allocator, account: *Ids.Account, places: *Place.Table, at: PathId, st: Step, out: *std.ArrayList(u32)) Error!void {
    const p = places.pathPlace(at);
    if (places.kind(p) != .record) return;
    for (places.steps(p).steps) |s| {
        if (!places.rowHolds(st, s)) continue;
        if (try places.extend(gpa, .growth(account), at, s)) |nx| try out.append(gpa, nx.int());
    }
}

/// Whether a caller's slot `words` is read from the entry `rw`, a row: past the row's
/// parent `words` take a step of their own that a row may hold (§2.1).
pub fn inRowOf(rw: []const u32, words: []const u32) bool {
    if (!endsInRow(rw) or rw.len > words.len) return false;
    const up = rw.len - 1;
    return words[up] != rw[up] and Step.fromWord(words[up]).inRow() and std.mem.eql(u32, rw[0..up], words[0..up]);
}

/// Whether `words` read a field out of a row that excludes it: a true nothing, no fold.
pub fn excluded(places: *const Place.Table, words: []const u32) bool {
    for (words[0..words.len -| 1], 1..) |w, i| {
        const st = Step.fromWord(w);
        if (st.isRow() and !places.rowHolds(st, Step.fromWord(words[i]))) return true;
    }
    return false;
}

/// Whether `words` end at a row step: every object below it is read (§2.1).
pub fn endsInRow(words: []const u32) bool {
    return words.len != 0 and Step.fromWord(words[words.len - 1]).isRow();
}
