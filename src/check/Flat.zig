//! The lookup table of `Exhaustive.zig` (Maranget §4): a `case` whose every
//! branch is a key, decided by set membership instead of the general
//! relation. Kept apart from `Exhaustive.zig` to hold both under
//! `checker-v2.md` §19.1's 1 500 lines; `Exhaustive` imports it and nothing
//! else does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Exhaustive = @import("Exhaustive.zig");

const Analysis = Exhaustive.Analysis;
const PatIndex = Exhaustive.PatIndex;
const Error = Exhaustive.Error;
const max_depth = Exhaustive.max_depth;

/// A `case` whose every branch is a **key** — a lookup table, which is the
/// shape a program written by a person actually reaches the budget with.
///
/// The general relation answers "is row k useful?" by specialising the whole
/// matrix above k and recursing, which is O(k) per row and therefore
/// **quadratic in the branch count with no nesting at all**: ~1.05·n² for a
/// single-column table, and 2·n² once the key is a pair, because each row's
/// specialisation then runs twice over the rows above it. A key has no
/// alternatives to explore, so the same question collapses to set membership,
/// and `isExhaustive`'s answer collapses with it. That is Maranget §4's
/// observation for the one shape it is worth taking, and it is what OCaml and
/// Elm rely on in practice.
///
/// **What a key is.** `unwrap` walks a row, descending through every
/// constructor of a union with exactly ONE alternative — a tuple, a record's
/// product, a `Box a` wrapper — because such a constructor carries no choice:
/// `Box a` matches exactly the values whose contents `a` matches, so the
/// wrapper can be erased. (`as` is already transparent, `simplify` having
/// dropped it.) What the walk leaves is a fixed-width row of **cells**, each
/// of which must be `_`/a variable/a record, a literal, or a constructor of a
/// real choice that is **nullary or has only wildcard arguments** (`C x`
/// matches every value `C` builds, so it is one point of its column exactly
/// as `C` would be). Anything else — a constructor with a narrower
/// argument that is one alternative of several, a column that mixes literals with
/// constructors (which is `error.Malformed`, and whose silence is the general
/// path's to keep), a row that unwraps to a different spine than the rows
/// before it — is `.general`, for that row and every one after it.
///
/// **THE CUT.** A row of all-concrete cells matches exactly ONE value, so the
/// rows above it match exactly the keys in the set and "is it useful?" is "is
/// its key absent?". A row of all-wildcard cells matches EVERY value, so it is
/// useful exactly when nothing above it covers everything. A row that is
/// concrete in one cell and open in another — `( 1, _ )` — matches a SLICE of
/// the key space, and membership of a point cannot decide a slice: `( 1, _ )`
/// above shadows `( 1, 3 )` below, and no set of points says so. **Such a row
/// is `.general`**, and so is every row after it. So the shape this path
/// decides is: all-concrete rows, plus full-wildcard rows anywhere among them
/// (in practice the trailing `_ ->`). What it leaves on the slow path is a
/// table with a partial default — `( state, _ ) ->` — from that row down.
///
/// The two answers it gives are both proofs, never guesses:
///
///   - *useful / redundant* for a row, by the argument above.
///   - *exhaustive*, and only when `covered` can show it: every cell column
///     must be a constructor column, whose value space is its union's
///     alternatives, and then the whole key space has `∏ alternatives` points.
///     The keys are DISTINCT points of that space, so `count == product` is
///     "every point is taken". A literal column has infinitely many points and
///     ends the question; so does a product too big for `u64`.
///
/// Everything else — "not exhaustive", and the witnesses that go with it — is
/// **delegated** to `isExhaustive` over the same matrix, so there is exactly
/// one place in this file that builds a counterexample.
///
/// It decides **nothing the general relation would decide differently**. The
/// equivalence is asserted where it is visible — the `check/bad` fixtures for
/// `missing_patterns` and `redundant_pattern` are unchanged to the byte, and
/// `blackbox_test.zig`'s flat- and pair-table scenarios pin the redundant
/// row's position and the missing combinations by name inside tables the
/// general relation could not have decided at all — and the two pieces with
/// no visible output, that `literalKey` agrees with `Literal.eql` in both
/// directions and that `rowKey`'s concatenation is a prefix code, are pinned
/// at the bottom of `Exhaustive.zig`.
///
/// The budget is charged **1 per node the walk visits**, which is what
/// building and probing the key costs: 1 for a bare literal or nullary
/// constructor, 3 for `( 1, 2 )`. That leaves a single-column table at 2
/// steps a branch. It is not free: `--pattern-budget=1` still refuses the
/// first branch of any `case`, which is what the pattern-budget black-box
/// scenarios assert.
pub const Flat = struct {
    arena: Allocator,
    /// The spine the first all-concrete row fixed (`unwrap`'s tokens). A row
    /// that walks differently builds its key out of a different structure, so
    /// the two keys are not comparable and the table stops here.
    shape: ?[]const u32 = null,
    /// One per cell of the key, in order; fixed by that same first row.
    cols: []Column = &.{},
    /// Canonical keys of the all-concrete rows seen, by `rowKey`.
    keys: std.StringHashMapUnmanaged(void) = .empty,
    /// A row above matches every value, so nothing below it can be useful.
    wildcard: bool = false,
    /// One row's walk, reused across rows. A `case` is checked branch by
    /// branch and a branch's cells are dead as soon as its key is built, so
    /// three buffers for the whole `case` do what three per branch would —
    /// and a `case` that is not a table at all never grows them, because
    /// `unwrap` gives up before it appends. What OUTLIVES a row is copied
    /// out: `shape` on the first concrete row, a key when it is new.
    scratch_shape: std.ArrayList(u32) = .empty,
    scratch_cells: std.ArrayList(PatIndex) = .empty,
    scratch_key: std.ArrayList(u8) = .empty,

    const Answer = enum { useful, redundant, general };

    /// What one cell position holds. The kind is what makes a column of
    /// literals and a column of constructors two different questions, and
    /// `un` is what lets `covered` count a constructor column's points.
    const Column = struct {
        kind: enum { literal, ctor },
        un: u32 = 0,
    };

    /// Flatten `p` into `cells`, recording the structure it walked in
    /// `shape`. False means "not a key" — the caller answers `.general`.
    ///
    /// `shape`'s tokens are a prefix code, so two equal token sequences are
    /// two equal structures: `0` is a cell, and `1, un, arity` is a wrapper
    /// whose `arity` children follow. The cells themselves are NOT in it —
    /// `( _, _ )` and `( 1, 2 )` have to compare equal, because a full
    /// wildcard is the same row whatever the key's shape is.
    fn unwrap(
        f: *Flat,
        an: *Analysis,
        p: PatIndex,
        depth: u32,
        shape: *std.ArrayList(u32),
        cells: *std.ArrayList(PatIndex),
    ) (Allocator.Error || error{OverBudget})!bool {
        // The same nesting guard the general path has, answered the way this
        // path answers everything it cannot read: hand it back.
        if (depth > max_depth) return false;
        // Charged per node, so a row that unwraps into a combinatorial
        // explosion runs out of budget rather than out of memory.
        try an.spend(1);
        switch (an.pats.tag(p)) {
            .anything, .literal => {
                try shape.append(f.arena, 0);
                try cells.append(f.arena, p);
                return true;
            },
            .ctor => {
                const c = an.pats.ctor(p);
                if (an.pats.unionAt(c.un).count() == 1) {
                    try shape.appendSlice(f.arena, &.{ 1, c.un, c.args_len });
                    var i: u32 = 0;
                    // `args` re-slices at every index on purpose: nothing
                    // here appends to `extra`, but the rule that a slice of
                    // it is valid only at the moment of use is the rule.
                    while (i < c.args_len) : (i += 1) {
                        if (!try f.unwrap(an, an.pats.args(c)[i], depth + 1, shape, cells)) return false;
                    }
                    return true;
                }
                // One alternative of a real choice. Nullary, or with only
                // wildcard arguments — `C x`, `C _ _` — it is a key: it
                // matches exactly the values built by `C`, whatever they
                // carry, which is the point `rowKey` (the alternative) and
                // `covered` (a point per alternative) take it for, so
                // `C0 x -> … C1999 x ->` stays linear instead of going
                // through the quadratic general relation. A narrower argument is
                // exactly the recursion this path exists to avoid.
                for (an.pats.args(c)) |arg| {
                    try an.spend(1);
                    if (an.pats.tag(arg) != .anything) return false;
                }
                try shape.append(f.arena, 0);
                try cells.append(f.arena, p);
                return true;
            },
            // A list's alternatives depend on its column, which a key
            // cannot know: the general path decides it.
            .list => return false,
        }
    }

    /// Decide one row against the rows already admitted, and record it.
    /// `OverBudget` is the only abort it can raise: the nesting guard and
    /// every shape it cannot read are `.general` rather than `TooDeep` or
    /// `Malformed` — deciding those is the general path's job.
    pub fn admit(f: *Flat, an: *Analysis, p: PatIndex) (Allocator.Error || error{OverBudget})!Answer {
        f.scratch_shape.clearRetainingCapacity();
        f.scratch_cells.clearRetainingCapacity();
        const shape = &f.scratch_shape;
        const cells = &f.scratch_cells;
        if (!try f.unwrap(an, p, 0, shape, cells)) return .general;

        var concrete: usize = 0;
        for (cells.items) |c| {
            if (an.pats.tag(c) != .anything) concrete += 1;
        }

        // Nothing but wildcards: the row matches every value, so `_` and
        // `( _, _ )` are one row — and so is `One` of a one-constructor
        // type, which unwraps to no cells at all.
        if (concrete == 0) {
            if (f.wildcard) return .redundant;
            // A key space already covered leaves a wildcard nothing to
            // match, which is what `isUseful`'s `complete` arm answers.
            if (f.covered(an)) return .redundant;
            f.wildcard = true;
            return .useful;
        }
        // THE CUT — see this struct's comment.
        if (concrete != cells.items.len) return .general;

        if (f.shape) |s| {
            if (!std.mem.eql(u32, s, shape.items)) return .general;
        } else {
            const cols = try f.arena.alloc(Column, cells.items.len);
            for (cells.items, cols) |c, *col| col.* = (columnOf(an, c) orelse return .general);
            // Copied out of the scratch buffer, which the next row reuses.
            f.shape = try f.arena.dupe(u32, shape.items);
            f.cols = cols;
        }
        // Equal spines have equal cell counts, `0` being a cell's token — but
        // the loop below PANICS on a length mismatch rather than answering,
        // and handing back what it cannot decide is this path's whole job.
        if (cells.items.len != f.cols.len) return .general;
        // One spine can still carry two different columns: a cell that is a
        // literal where an earlier row had a constructor is the matrix the
        // general path calls malformed, and two constructors of different
        // unions is the same thing one level down.
        for (cells.items, f.cols) |c, col| {
            const here = columnOf(an, c) orelse return .general;
            if (here.kind != col.kind or here.un != col.un) return .general;
        }

        if (f.wildcard) return .redundant;
        const key = try f.rowKey(an, cells.items);
        // A key that is already there is answered without copying it, so the
        // only row that costs an allocation is a row that is kept.
        if (f.keys.contains(key)) return .redundant;
        try f.keys.put(f.arena, try f.arena.dupe(u8, key), {});
        return .useful;
    }

    /// The column a concrete cell describes, or null when it is not one.
    fn columnOf(an: *const Analysis, cell: PatIndex) ?Column {
        return switch (an.pats.tag(cell)) {
            .literal => .{ .kind = .literal },
            .ctor => .{ .kind = .ctor, .un = an.pats.ctor(cell).un },
            .anything, .list => null,
        };
    }

    /// A byte key two rows share exactly when they match the same value: each
    /// cell's canonical key, length-prefixed so the concatenation parses back
    /// into the same cells and equal bytes mean equal cells. A literal's key
    /// is `literalKey`'s, pinned against `Literal.eql` at the bottom of
    /// `Exhaustive.zig`; a nullary constructor's is its absolute alternative
    /// index, which is what the general relation compares too.
    ///
    /// Valid until the next row: the caller copies it if it keeps it.
    pub fn rowKey(f: *Flat, an: *Analysis, cells: []const PatIndex) Error![]const u8 {
        f.scratch_key.clearRetainingCapacity();
        const out = &f.scratch_key;
        for (cells) |c| {
            var alt: [4]u8 = undefined;
            const body: []const u8 = switch (an.pats.tag(c)) {
                .literal => try an.literalKey(an.pats.literal(c)),
                .ctor => blk: {
                    std.mem.writeInt(u32, &alt, an.pats.ctor(c).alt, .little);
                    break :blk &alt;
                },
                // `admit` counted the wildcards before it got here, and
                // `unwrap` handed a list back.
                .anything, .list => "",
            };
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(body.len), .little);
            try out.appendSlice(f.arena, &len);
            try out.appendSlice(f.arena, body);
        }
        return out.items;
    }

    /// Do the rows admitted so far take every point of the key space? Only a
    /// constructor column has a finite one, so every column must be one, and
    /// then the space has `∏ alternatives` points and the keys are distinct
    /// points of it.
    fn covered(f: *const Flat, an: *const Analysis) bool {
        if (f.shape == null) return false;
        var points: u64 = 1;
        for (f.cols) |col| {
            if (col.kind != .ctor) return false;
            points = std.math.mul(u64, points, an.pats.unionAt(col.un).count()) catch return false;
        }
        return @as(u64, f.keys.count()) == points;
    }

    /// Whether the rows admitted so far cover every value of the scrutinee.
    pub fn exhaustive(f: *const Flat, an: *const Analysis) bool {
        return f.wildcard or f.covered(an);
    }
};
