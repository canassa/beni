//! Maranget's usefulness relation `U(P, q)` for a `case` read branch by
//! branch (`Exhaustive.one`, checker.md §6.6), over a TREE of the matrices
//! the relation specialises instead of over a fresh matrix per branch.
//! Kept apart from `Exhaustive.zig` to hold both under `checker-v2.md`
//! §19.1's 1 500 lines; `Exhaustive` imports it and nothing else does.
//!
//! **Why a tree.** Branch k is useful when it matches a value the k − 1
//! rows above it do not, and the relation answers that by specialising
//! those rows by branch k's head, then the result by its next head, and so
//! on down. Done afresh for every branch, each step reads every row above,
//! so a `case` of n branches costs O(n²) even when every specialisation
//! keeps almost nothing: n branches `[ Just ( k, y ), ...rest ] →` read
//! all the rows above three times over before the literal `k` throws them
//! away (issue #812: 500 → 1 000 branches cost 128M → 448M instructions).
//!
//! But specialisation keeps rows in matrix order and treats each row on its
//! own, so specialising rows 0 … k is specialising rows 0 … k − 1 and then
//! row k. A `Node` is one specialised matrix, kept for the rest of the
//! `case`: the root is the branches admitted so far, and a node's child by
//! a key is that node's matrix specialised by the key. A child is made the
//! first time a branch asks for it and **caught up** whenever one visits
//! it, with only the rows its parent gained since. A node's FIRST child by
//! a head reads the node's rows in order from where it stopped; from the
//! second, the node indexes its rows by what heads them (a chain per head,
//! and lists of its wildcard rows and its lists with a spread), so a later
//! child catches up on the rows the specialisation keeps — those headed by
//! its key and those headed by a wildcard — and never on the rows it drops.
//! A node asked for one head, which is most of them, never pays for an
//! index. Each row therefore enters each node at most once and is read at
//! most three times there, and a branch costs the rows that are new along
//! its path plus a step per level, not the rows above it.
//!
//! **Nothing is decided differently.** A node's rows are, row for row and
//! in order, the matrix the relation built before for the same question,
//! because they are made by the same specialisation of the same rows; so
//! the recursion visits the same questions in the same order, gives the
//! same answers, stops at the same first useful alternative, and goes as
//! deep before `max_depth` stops it. What a column tells the relation —
//! which kinds of head it holds, which alternatives of which union it has
//! seen, a list column's length split — is kept per node as its rows
//! arrive, and read exactly where the relation read the matrix. A head the
//! specialisation would have refused as `error.Malformed` is a flag, raised
//! at the step that would have scanned it.
//!
//! **The budget** is charged 1 per step of the relation, 1 per child
//! looked up, 1 per row a node reads or catches up on, and 1 per row an
//! index is built over: the work done, as before, and no longer the size of
//! the matrix above.
//!
//! **What still costs a square** is a wildcard row under many distinct
//! heads: each child that a head names takes every wildcard row above it,
//! because its matrix holds them. `( k, x )` rows interleaved with `( _, k )`
//! rows are that shape; `( k, _ )`, a table with a per-row default, is not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Exhaustive = @import("Exhaustive.zig");

const Analysis = Exhaustive.Analysis;
const PatIndex = Exhaustive.PatIndex;
const Fail = Exhaustive.Fail;
const LenSplit = Analysis.LenSplit;
const max_depth = Exhaustive.max_depth;

/// What a child is its parent specialised by, and what heads a row: `a`
/// and `b` are an alternative and its arity for `ctor` (a head carries no
/// arity, so its `b` is 0), a literal id (`Patterns.literalId`) for
/// `literal`, a length for `exact`, and the leading and trailing counts of
/// the `at least` alternative for `at_least`, which is `P + S` long
/// (`Analysis.lenSplit`).
const Key = struct {
    kind: enum(u8) { ctor, literal, anything, exact, at_least },
    a: u32 = 0,
    b: u32 = 0,
};

/// Keys are small integers, so they are mixed rather than run through a
/// byte hash.
const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: u64 = (@as(u64, k.b) << 32 | k.a) ^ (@as(u64, @backingInt(k.kind)) *% 0x9E3779B97F4A7C15);
        h = (h ^ (h >> 30)) *% 0xBF58476D1CE4E5B9;
        h = (h ^ (h >> 27)) *% 0x94D049BB133111EB;
        return h ^ (h >> 31);
    }

    pub fn eql(_: KeyContext, x: Key, y: Key) bool {
        return x.kind == y.kind and x.a == y.a and x.b == y.b;
    }
};

fn KeyMap(comptime V: type) type {
    return std.HashMapUnmanaged(Key, V, KeyContext, std.hash_map.default_max_load_percentage);
}

const none = std.math.maxInt(u32);

/// The rows of one head, as a chain through `Node.next`.
const Chain = struct { first: u32, last: u32 };

/// One specialised matrix, its column zero indexed by head.
pub const Node = struct {
    rows: std.ArrayList([]const PatIndex) = .empty,

    /// The node this is a specialisation of, by `key`; null at the root,
    /// whose rows are added directly.
    parent: ?*Node = null,
    key: Key = .{ .kind = .anything },
    /// How this node catches up with its parent. The first child of a
    /// node that needs rows headed by its key READS the parent's rows in
    /// order (`scan`, from `at_row`), so a node asked for one such child
    /// never pays for an index; any later one walks the parent's chain for
    /// its key (from `last_headed`, `none` before the first) merged with
    /// the parent's `spread` and `wild` lists (from `at_spread`, `at_wild`).
    scan: bool = false,
    at_row: u32 = 0,
    last_headed: u32 = none,
    at_spread: usize = 0,
    at_wild: usize = 0,

    // Column zero, by head.
    /// Whether `next` and `heads` are kept: from the second child that
    /// needs them, built then over the rows so far (`index`).
    indexed: bool = false,
    /// Whether a child already reads this node's rows in order.
    scanned: bool = false,
    /// Per row, the next row with the same head, or `none`.
    next: std.ArrayList(u32) = .empty,
    /// The rows headed by a constructor, a literal or a list with no
    /// spread, by head (`headOf`).
    heads: KeyMap(Chain) = .empty,
    /// The rows headed by a list with a spread, ascending.
    spread: std.ArrayList(u32) = .empty,
    /// The rows headed by a wildcard, ascending.
    wild: std.ArrayList(u32) = .empty,

    // What the relation asks of column zero.
    has_ctor: bool = false,
    has_literal: bool = false,
    has_list: bool = false,
    /// A row of width zero, which every specialisation refuses.
    has_empty: bool = false,
    /// `ColumnIndex.collect`, kept as rows arrive: the union of the first
    /// constructor, its alternatives seen, and whether a later one broke
    /// the union (`collect`'s `error.Malformed`).
    un: ?u32 = null,
    alts_start: u32 = 0,
    seen: std.DynamicBitSetUnmanaged = .{},
    seen_count: u32 = 0,
    union_bad: bool = false,
    /// `Analysis.lenSplit`'s three maxima over the rows.
    fixed: ?u32 = null,
    prefix: u32 = 0,
    suffix: u32 = 0,

    kids: KeyMap(*Node) = .empty,

    /// Append `row` and index its head.
    pub fn add(n: *Node, an: *Analysis, row: []const PatIndex) Exhaustive.Error!void {
        const arena = an.arena;
        const i: u32 = @intCast(n.rows.items.len);
        try n.rows.append(arena, row);
        if (n.indexed) try n.chain(an, row, i);
        if (row.len == 0) {
            n.has_empty = true;
            return;
        }
        const pats = an.pats;
        switch (pats.tag(row[0])) {
            .anything => try n.wild.append(arena, i),
            .literal => {
                n.has_literal = true;
            },
            .ctor => {
                n.has_ctor = true;
                const c = pats.ctor(row[0]);
                if (n.un == null) {
                    const u = pats.unionAt(c.un);
                    n.un = c.un;
                    n.alts_start = u.alts_start;
                    n.seen = try .initEmpty(arena, u.count());
                } else if (c.un != n.un.?) {
                    n.union_bad = true;
                    return;
                }
                if (c.alt < n.alts_start or c.alt - n.alts_start >= n.seen.bit_length) {
                    n.union_bad = true;
                    return;
                }
                if (n.seen.isSet(c.alt - n.alts_start)) return;
                n.seen.set(c.alt - n.alts_start);
                n.seen_count += 1;
            },
            .list => {
                n.has_list = true;
                const l = pats.list(row[0]);
                if (l.spread) {
                    n.prefix = @max(n.prefix, l.prefix);
                    n.suffix = @max(n.suffix, l.suffix);
                    try n.spread.append(arena, i);
                } else {
                    n.fixed = @max(n.fixed orelse 0, l.prefix);
                }
            },
        }
    }

    /// Give row `i` its `next` slot and put it at the end of the chain of
    /// its head, if it has one.
    fn chain(n: *Node, an: *Analysis, row: []const PatIndex, i: u32) Exhaustive.Error!void {
        try n.next.append(an.arena, none);
        const head = headOf(an, row) orelse return;
        const gop = try n.heads.getOrPut(an.arena, head);
        if (gop.found_existing) {
            n.next.items[gop.value_ptr.last] = i;
            gop.value_ptr.last = i;
        } else gop.value_ptr.* = .{ .first = i, .last = i };
    }

    /// Start keeping `next` and `heads`, over the rows so far, a step of
    /// the budget each.
    fn index(n: *Node, an: *Analysis) Fail!void {
        if (n.indexed) return;
        try an.spend(n.rows.items.len);
        for (n.rows.items, 0..) |row, i| try n.chain(an, row, @intCast(i));
        n.indexed = true;
    }

    /// `Analysis.lenSplit` of this node's rows with `extra` counted as one
    /// more, from the maxima kept as they arrived.
    fn lenSplit(n: *const Node, an: *const Analysis, extra: ?PatIndex) LenSplit {
        var fixed = n.fixed;
        var prefix = n.prefix;
        var suffix = n.suffix;
        if (extra) |p| if (an.pats.tag(p) == .list) {
            const l = an.pats.list(p);
            if (l.spread) {
                prefix = @max(prefix, l.prefix);
                suffix = @max(suffix, l.suffix);
            } else fixed = @max(fixed orelse 0, l.prefix);
        };
        var len = prefix + suffix;
        if (fixed) |f| if (f + 1 > len) {
            prefix = f + 1 - suffix;
            len = f + 1;
        };
        return .{ .prefix = prefix, .suffix = suffix, .len = len };
    }

    /// Elm's `isComplete` (`Analysis.complete`): the union of column zero
    /// when every one of its alternatives appears, else null.
    fn complete(n: *const Node, an: *const Analysis) Fail!?u32 {
        if (n.has_empty or n.union_bad) return error.Malformed;
        const un = n.un orelse return null;
        if (n.seen_count != an.pats.unionAt(un).count()) return null;
        return un;
    }
};

/// Maranget's `U(P, q)` with `P` the matrix `node` holds: can `vector`
/// match a value no row of it matches? `Analysis.isUseful`'s recursion,
/// step for step, with every specialisation a child of `node`.
pub fn isUseful(an: *Analysis, node: *Node, vector: []const PatIndex, depth: u32) Fail!bool {
    // Nesting guard, before anything else, as it always was.
    if (depth > max_depth) return error.TooDeep;
    try an.spend(1);
    // Nothing above it matches the same values, so it is useful.
    if (node.rows.items.len == 0) return true;
    // Nothing left to distinguish it by, and rows remain: not useful.
    if (vector.len == 0) return false;

    const pats = an.pats;
    const first = vector[0];
    const rest = vector[1..];
    switch (pats.tag(first)) {
        .ctor => {
            // `specializeByCtor` refuses a literal or a list in the column.
            if (node.has_empty or node.has_literal or node.has_list) return error.Malformed;
            const c = pats.ctor(first);
            const sub = try child(an, node, .{ .kind = .ctor, .a = c.alt, .b = c.args_len });
            return isUseful(an, sub, try an.concat(pats.args(c), rest), depth + 1);
        },
        .literal => {
            if (node.has_empty or node.has_ctor or node.has_list) return error.Malformed;
            const sub = try child(an, node, .{ .kind = .literal, .a = pats.literalId(first) });
            return isUseful(an, sub, rest, depth + 1);
        },
        // A list pattern stands for every alternative it covers.
        .list => {
            const lens = node.lenSplit(an, first);
            var alt: u32 = 0;
            while (alt < lens.count()) : (alt += 1) {
                const cells = (try an.listCells(first, lens, alt)) orelse continue;
                if (node.has_empty or node.has_ctor or node.has_literal) return error.Malformed;
                const sub = try child(an, node, listKey(lens, alt));
                if (try isUseful(an, sub, try an.concat(cells, rest), depth + 1)) return true;
            }
            return false;
        },
        .anything => {
            // A wildcard over lists: every alternative of the column,
            // which together are every list.
            if (node.has_list) {
                const lens = node.lenSplit(an, null);
                var alt: u32 = 0;
                while (alt < lens.count()) : (alt += 1) {
                    if (node.has_empty or node.has_ctor or node.has_literal) return error.Malformed;
                    const sub = try child(an, node, listKey(lens, alt));
                    const v = try an.concat(try an.anythings(lens.arity(alt)), rest);
                    if (try isUseful(an, sub, v, depth + 1)) return true;
                }
                return false;
            }
            if (try node.complete(an)) |un| {
                // Every alternative is covered above, so this wildcard adds
                // nothing for the HEADS — but an alternative's arguments
                // may still be narrower above than here. (`split` refuses a
                // literal in the column.)
                if (node.has_literal) return error.Malformed;
                const u = pats.unionAt(un);
                var alt = u.alts_start;
                while (alt < u.alts_end) : (alt += 1) {
                    const arity = pats.alt(alt).arity;
                    const sub = try child(an, node, .{ .kind = .ctor, .a = alt, .b = arity });
                    const v = try an.concat(try an.anythings(arity), rest);
                    if (try isUseful(an, sub, v, depth + 1)) return true;
                }
                return false;
            }
            if (node.has_empty) return error.Malformed;
            return isUseful(an, try child(an, node, .{ .kind = .anything }), rest, depth + 1);
        },
    }
}

/// The child of list alternative `alt`: `exact ℓ` is the same matrix
/// whatever the split around it, and `at least` is keyed by the leading
/// and trailing counts its cells are padded to.
fn listKey(lens: LenSplit, alt: u32) Key {
    if (alt < lens.len) return .{ .kind = .exact, .a = alt };
    return .{ .kind = .at_least, .a = lens.prefix, .b = lens.suffix };
}

/// `node` specialised by `key`, made on first use and caught up.
fn child(an: *Analysis, node: *Node, key: Key) Fail!*Node {
    try an.spend(1);
    const gop = try node.kids.getOrPut(an.arena, key);
    if (!gop.found_existing) {
        const made = try an.arena.create(Node);
        made.* = .{ .parent = node, .key = key };
        gop.value_ptr.* = made;
        switch (key.kind) {
            // These read only the parent's `spread` and `wild` lists.
            .anything, .at_least => {},
            .ctor, .literal, .exact => if (!node.indexed and !node.scanned) {
                node.scanned = true;
                made.scan = true;
            } else try node.index(an),
        }
    }
    const sub = gop.value_ptr.*;
    try catchUp(an, sub);
    return sub;
}

/// The head of `row` that a child's key names (`Key`), or null for a
/// wildcard, a list with a spread and an empty row.
fn headOf(an: *const Analysis, row: []const PatIndex) ?Key {
    if (row.len == 0) return null;
    const pats = an.pats;
    return switch (pats.tag(row[0])) {
        .anything => null,
        .literal => .{ .kind = .literal, .a = pats.literalId(row[0]) },
        .ctor => .{ .kind = .ctor, .a = pats.ctor(row[0]).alt },
        .list => {
            const l = pats.list(row[0]);
            return if (l.spread) null else .{ .kind = .exact, .a = l.prefix };
        },
    };
}

/// Add to `n` the rows its parent gained since `n` last caught up, each
/// specialised by `n`'s key, in the parent's order: a merge of the
/// parent's chain of rows headed by the key, its rows with a spread (for a
/// list alternative) and its wildcard rows, which are the only rows the
/// specialisation keeps. Each row taken is a step of the budget.
fn catchUp(an: *Analysis, n: *Node) Fail!void {
    const parent = n.parent.?;
    const head: ?Key = switch (n.key.kind) {
        .ctor => .{ .kind = .ctor, .a = n.key.a },
        .literal, .exact => n.key,
        .anything, .at_least => null,
    };
    const spread: []const u32 = switch (n.key.kind) {
        .exact, .at_least => parent.spread.items,
        .ctor, .literal, .anything => &.{},
    };
    if (n.scan) {
        while (n.at_row < parent.rows.items.len) : (n.at_row += 1) {
            try an.spend(1);
            const row = parent.rows.items[n.at_row];
            if (row.len == 0) continue;
            switch (an.pats.tag(row[0])) {
                .anything => try n.add(an, try wildRow(an, n, row)),
                .list => if (an.pats.list(row[0]).spread) {
                    if (n.key.kind == .exact) if (try spreadRow(an, n, row)) |r| try n.add(an, r);
                    continue;
                },
                .literal, .ctor => {},
            }
            const at = headOf(an, row) orelse continue;
            if (head != null and KeyContext.eql(.{}, at, head.?)) try n.add(an, try headedRow(an, n, row));
        }
        return;
    }
    const wild = parent.wild.items;
    while (true) {
        const h: u32 = if (n.last_headed != none)
            parent.next.items[n.last_headed]
        else if (head) |k|
            (if (parent.heads.get(k)) |c| c.first else none)
        else
            none;
        const s: u32 = if (n.at_spread < spread.len) spread[n.at_spread] else none;
        const w: u32 = if (n.at_wild < wild.len) wild[n.at_wild] else none;
        const at = @min(h, s, w);
        if (at == none) return;
        try an.spend(1);
        const row = parent.rows.items[at];
        if (at == h) {
            n.last_headed = h;
            try n.add(an, try headedRow(an, n, row));
        } else if (at == s) {
            n.at_spread += 1;
            if (try spreadRow(an, n, row)) |r| try n.add(an, r);
        } else {
            n.at_wild += 1;
            try n.add(an, try wildRow(an, n, row));
        }
    }
}

/// A parent row headed by a wildcard: as many wildcards as `n`'s key has
/// columns, then the tail — which is the tail itself when it has none.
fn wildRow(an: *Analysis, n: *const Node, row: []const PatIndex) Fail![]const PatIndex {
    const width = widthOf(n);
    if (width == 0) return row[1..];
    return an.concat(try an.anythings(width), row[1..]);
}

/// How many columns `n`'s key puts in front of a parent row's tail.
fn widthOf(n: *const Node) u32 {
    return switch (n.key.kind) {
        .ctor => n.key.b,
        .literal, .anything => 0,
        .exact => n.key.a,
        .at_least => n.key.a + n.key.b,
    };
}

/// A parent row headed by `n`'s own key: a constructor's arguments, a
/// literal's nothing, an exact list's items, then the tail.
fn headedRow(an: *Analysis, n: *const Node, row: []const PatIndex) Fail![]const PatIndex {
    const pats = an.pats;
    return switch (n.key.kind) {
        .literal => row[1..],
        .ctor => an.concat(pats.args(pats.ctor(row[0])), row[1..]),
        .exact => an.concat(try an.arena.dupe(PatIndex, pats.items(pats.list(row[0]))), row[1..]),
        .anything, .at_least => unreachable,
    };
}

/// A parent row headed by a list with a spread, under `n`'s list
/// alternative, or null when it does not cover it (`Analysis.listCells`).
fn spreadRow(an: *Analysis, n: *const Node, row: []const PatIndex) Fail!?[]const PatIndex {
    const pats = an.pats;
    const l = pats.list(row[0]);
    const width = widthOf(n);
    // `exact ℓ` is covered when ℓ ≥ p + s; `at least` always, its width
    // being P + S with P ≥ p and S ≥ s.
    if (l.prefix + l.suffix > width) return null;
    // A key `( P, S )` is asked for only while every row above has `p ≤ P`
    // and `s ≤ S`, and it is caught up only from those rows.
    if (std.debug.runtime_safety and n.key.kind == .at_least) std.debug.assert(l.prefix <= n.key.a and l.suffix <= n.key.b);
    // The same cells under both: `p` leading items, wildcards, `s`
    // trailing items — under `at least`, the leading ones padded to `P` and
    // the trailing ones padded in front to `S`, which is the same row.
    const items = try an.arena.dupe(PatIndex, pats.items(l));
    const out = try an.arena.alloc(PatIndex, width);
    @memcpy(out[0..l.prefix], items[0..l.prefix]);
    for (out[l.prefix .. width - l.suffix]) |*c| c.* = try an.anything();
    @memcpy(out[width - l.suffix ..], items[l.prefix..]);
    return try an.concat(out, row[1..]);
}
