//! L5: a label whose function value is an `alt` of known codes
//! (`docs/design/ownership-v2.md` §2.11.3, *At a caller where the label's
//! function value is known*, #2322): the closures of the alternatives, and the
//! virtual calls an evaluation makes of them, one per alternative, which the
//! readers of a label's known code take together: its answer is the join of
//! theirs, and a condition asked of the code is asked of each.
//!
//! Obligations kept here: none of §2.14's directly (each alternative is a
//! virtual call, judged as one known code is).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const StepWord = @import("StepWord.zig");

const Error = Ids.ChargeError;

/// How many alternatives a label is applied to; past that it is unknown code.
pub const max_alternatives = 64;

/// Per `(call, callee label)` applied to the alternatives of an `alt`: its virtual calls, `[first, n]`, made
/// one after another. A label applied to one known code is in `Relation.Eval.known` instead.
pub const Table = struct {
    map: Ids.FixedDict(2) = .{},
    runs: std.ArrayList([2]u32) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.map.deinit(gpa);
        t.runs.deinit(gpa);
    }

    /// Label `li` of call `call` is applied by virtual calls `[first, first + n)`; each is marked in `applied`
    /// (`Relation.Eval.applied`) as one of its, as `Relation.Eval.apply` marks a known code's.
    pub fn put(t: *Table, gpa: Allocator, applied: *std.ArrayList([2]u32), call: u32, li: u32, first: u32, n: u32) Error!void {
        try t.map.put(gpa, .{ call, li }, @intCast(t.runs.items.len));
        try t.runs.append(gpa, .{ first, n });
        while (applied.items.len < first + n) try applied.append(gpa, .{ Ids.none_int, Ids.none_int });
        for (applied.items[first..][0..n]) |*a| a.* = .{ call, li };
    }

    /// The virtual calls of `(call, li)`'s alternatives, if it has any, and else the one in `known`.
    pub fn codes(t: *const Table, known: *const Ids.FixedDict(2), call: u32, li: u32) ?[2]u32 {
        if (known.get(.{ call, li })) |vi| return .{ vi, 1 };
        return t.runs.items[t.map.get(.{ call, li }) orelse return null];
    }

    /// The answers of the virtual calls of every alternative of call `call`'s labels but `self`, of frame `f` (a
    /// `Value.Frame`), appended to `out`: what the callee may hold across a run of `self` (`Across`), another
    /// alternative of `self`'s label too.
    pub fn beside(t: *const Table, f: anytype, call: u32, self: u32, out: *std.ArrayList(u32)) Error!void {
        const ks = t.map.keys.items;
        var i: usize = 0;
        while (i + 1 < ks.len) : (i += 2) if (ks[i] == call) {
            const r = t.runs.items[t.map.values.items[i / 2]];
            for (r[0]..r[0] + r[1]) |v| if (v != self) try out.append(f.gpa, try f.refRoot(f.calls.items[v].root));
        };
    }
};

/// The closures of value `fv` of frame `f` (a `Value.Frame`) when it is an `alt` whose every alternative is a
/// known code's closure or `⊥`, nested alts flattened, each once, into `out`; false (and `out` as it may stand)
/// when one is anything else, or when they pass `max_alternatives`.
pub fn closures(f: anytype, fv: u32, out: *std.ArrayList(u32)) Error!bool {
    const x = f.val(fv);
    switch (x.kind) {
        .bot => return true,
        .built => {
            if (x.form != .closure or x.head & Contract.fixed_bit != 0) return false;
            for (out.items) |o| if (o == fv) return true;
            if (out.items.len == max_alternatives) return false;
            try out.append(f.gpa, fv);
            return true;
        },
        .alt => {
            const ks = f.kidsOf(x);
            var i: usize = 0;
            while (i + 1 < ks.len) : (i += 2) if (!try closures(f, ks[i + 1], out)) return false;
            return true;
        },
        else => return false,
    }
}

/// The closures at `words` below argument `arg` whose value there is `fv` (`closures`): where that value is unknown
/// (`⊤`, as `Value.Frame.valueAt` answers below an `alt` or at a list of several elements), each alternative of an
/// `alt` and each element of a built list on the way, every one a known code's closure.
pub fn of(f: anytype, fv: u32, arg: u32, words: []const u32, out: *std.ArrayList(u32)) Error!bool {
    return if (f.val(fv).kind == .top) at(f, arg, words, out) else closures(f, fv, out);
}

fn at(f: anytype, v: u32, words: []const u32, out: *std.ArrayList(u32)) Error!bool {
    if (words.len == 0) return closures(f, v, out);
    const x = f.val(v);
    const ks = f.kidsOf(x);
    if (x.kind == .alt) {
        var i: usize = 0;
        while (i + 1 < ks.len) : (i += 2) if (!try at(f, ks[i + 1], words, out)) return false;
        return true;
    }
    // A built list's kids are its elements: a literal's, a prepend's fronts and its base's family (`Walk`).
    if (x.kind == .built and x.form == .list and StepWord.Step.fromWord(words[0]).kind == .elem) {
        for (ks) |k| if (!try at(f, k, words[1..], out)) return false;
        return true;
    }
    const y = try f.valueAt(v, words[0..1]);
    return f.val(y).kind != .top and try at(f, y, words[1..], out);
}
