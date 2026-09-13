//! The bridge between a module's store and its interface (docs/design/
//! checker.md §7): turning a solved `Var` into the flat term language, and
//! instantiating those terms back into another module's store.
//!
//! **Why terms at all.** A `TypeStore` is per module and is released as soon
//! as the interface has been extracted (§5), so a `Var` means nothing to a
//! dependent. An interface has to outlive every store, be comparable by
//! value for the firewall of `fast-compiler.md` §8.1, and in M4 be mapped
//! from disk with no fixup pass — which is exactly a `MultiArrayList` of
//! `{tag, lhs, rhs}` plus one `extra` sidecar and one symbol column.
//!
//! **Sharing survives the round trip.** Writing memoises `Var → TermIndex`
//! in a dense array over the store, so a scheme whose body mentions the same
//! variable twice writes one term and points at it twice; reading allocates
//! exactly one store variable per quantifier, so `a -> a` comes back with
//! both arrows on the SAME variable. That is the interface-crossing half of
//! the sharing-preserving instantiation of design §7 #4 — without it, every
//! use of a core function would unroll its type.
//!
//! **A declaration that failed to check still has a scheme**, whose body is
//! the `err` term: checker.md §7 requires the interface of a module with
//! type errors to exist so dependents can be checked against the rest, and
//! `<error>` is what the dump prints for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");

const Schemes = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// Accumulates the `schemes`, `terms` and `extra` tables of one interface,
/// plus the symbols its record types name. Attached to the interface in one
/// call at the end, so the interface is immutable from then on.
pub const Writer = struct {
    gpa: Allocator,
    store: *TypeStore,
    /// Where this writer's symbols land in the finished column: the
    /// interface already has one, and these are appended to it.
    symbol_base: u32,
    schemes: std.ArrayList(Interface.Scheme) = .empty,
    terms: std.MultiArrayList(Interface.Term) = .empty,
    extra: std.ArrayList(u32) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    /// `Var → TermIndex` for the scheme being written; dense over the
    /// store, cleared per scheme. Never a map: a `Var` is a dense id and
    /// the house rules forbid hashing one.
    memo: []Interface.TermIndex = &.{},
    /// `Var → quantified index` for the scheme being written.
    quantified: []u32 = &.{},
    quantified_count: u32 = 0,
    /// Flags of the quantifiers discovered so far, moved into `extra` when
    /// the scheme is closed.
    pending_flags: std.ArrayList(u32) = .empty,
    depth: u32 = 0,

    const unbound: u32 = std.math.maxInt(u32);
    const max_depth = 512;

    pub fn init(gpa: Allocator, store: *TypeStore, symbol_base: u32) Writer {
        return .{ .gpa = gpa, .store = store, .symbol_base = symbol_base };
    }

    pub fn deinit(w: *Writer) void {
        w.schemes.deinit(w.gpa);
        w.terms.deinit(w.gpa);
        w.extra.deinit(w.gpa);
        w.symbols.deinit(w.gpa);
        w.pending_flags.deinit(w.gpa);
        w.gpa.free(w.memo);
        w.gpa.free(w.quantified);
        w.* = undefined;
    }

    /// Write `v` as a scheme and return its index. Every variable still at
    /// `TypeStore.generalized` becomes a quantifier; anything else is
    /// concrete by the time a module is done.
    pub fn add(w: *Writer, v: Var) Error!Interface.SchemeIndex {
        try w.resetMemo();
        // The body is written first and the quantifier list placed after
        // it: the walk DISCOVERS the quantifiers, and their order is first
        // appearance in the body, which is also the order `Render` names
        // them in.
        const body = try w.writeVar(v);
        const count = w.quantified_count;
        const flags_start: u32 = @intCast(w.extra.items.len);
        try w.extra.appendSlice(w.gpa, w.pending_flags.items);
        const index: u32 = @intCast(w.schemes.items.len);
        try w.schemes.append(w.gpa, .{
            .quantified_start = flags_start,
            .quantified_count = count,
            .body = body,
        });
        return @enumFromInt(index);
    }

    /// A scheme for a declaration that did not check (checker.md §7).
    pub fn addError(w: *Writer) Error!Interface.SchemeIndex {
        const body = try w.term(.err, 0, 0);
        const index: u32 = @intCast(w.schemes.items.len);
        try w.schemes.append(w.gpa, .{
            .quantified_start = @intCast(w.extra.items.len),
            .quantified_count = 0,
            .body = body,
        });
        return @enumFromInt(index);
    }

    fn resetMemo(w: *Writer) Error!void {
        const n = w.store.count();
        if (w.memo.len < n) {
            w.gpa.free(w.memo);
            w.memo = try w.gpa.alloc(Interface.TermIndex, n);
            w.gpa.free(w.quantified);
            w.quantified = try w.gpa.alloc(u32, n);
        }
        @memset(w.memo[0..n], .none);
        @memset(w.quantified[0..n], unbound);
        w.quantified_count = 0;
        w.pending_flags.clearRetainingCapacity();
    }

    fn term(w: *Writer, tag: Interface.Term.Tag, lhs: u32, rhs: u32) Error!Interface.TermIndex {
        const index: u32 = @intCast(w.terms.len);
        try w.terms.append(w.gpa, .{ .tag = tag, .lhs = lhs, .rhs = rhs });
        return @enumFromInt(index);
    }

    fn addRange(w: *Writer, words: []const u32) Error!u32 {
        const start: u32 = @intCast(w.extra.items.len);
        try w.extra.append(w.gpa, @intCast(words.len));
        try w.extra.appendSlice(w.gpa, words);
        return start;
    }

    fn symbolIndex(w: *Writer, s: Symbol) Error!u32 {
        const index: u32 = w.symbol_base + @as(u32, @intCast(w.symbols.items.len));
        try w.symbols.append(w.gpa, s);
        return index;
    }

    fn writeVar(w: *Writer, v: Var) Error!Interface.TermIndex {
        w.depth += 1;
        defer w.depth -= 1;
        if (w.depth > max_depth) return w.term(.err, 0, 0);

        const root = w.store.find(v);
        if (root.int() < w.memo.len and w.memo[root.int()] != .none) return w.memo[root.int()];

        const content = w.store.content(root);
        switch (content) {
            .err => return w.term(.err, 0, 0),
            .flex, .rigid => |flags| {
                const index = try w.quantifierOf(root, flags);
                const t = try w.term(.@"var", index, 0);
                if (root.int() < w.memo.len) w.memo[root.int()] = t;
                return t;
            },
            .structure => |flat| switch (flat) {
                .unit => return w.term(.unit, 0, 0),
                .empty_record => return w.term(.empty_record, 0, 0),
                .func => |f| {
                    const param = try w.writeVar(f.param);
                    const result = try w.writeVar(f.result);
                    return w.memoise(root, try w.term(.func, param.int(), result.int()));
                },
                .app => |a| {
                    const words = try w.writeRange(w.store.vars(a.args));
                    defer w.gpa.free(words);
                    const start = try w.addRange(words);
                    return w.memoise(root, try w.term(.app, @intFromEnum(a.type), start));
                },
                .tuple => |t| {
                    const words = try w.writeRange(w.store.vars(t));
                    defer w.gpa.free(words);
                    const start = try w.addRange(words);
                    return w.memoise(root, try w.term(.tuple, start, 0));
                },
                .record => |r| {
                    const fields = try w.gpa.dupe(TypeStore.Field, w.store.fields(r.fields));
                    defer w.gpa.free(fields);
                    // Sorted by TEXT is the interface's rule everywhere
                    // else; here the order is the store's (by symbol id),
                    // which is not stable across `--jobs`. The dump sorts,
                    // so nothing observable depends on it — but a future
                    // HASH of this record must sort first.
                    const words = try w.gpa.alloc(u32, fields.len * 2);
                    defer w.gpa.free(words);
                    for (fields, 0..) |f, i| {
                        words[i * 2] = try w.symbolIndex(f.name);
                        words[i * 2 + 1] = (try w.writeVar(f.value)).int();
                    }
                    const start = try w.addRange(words);
                    const ext = try w.writeVar(r.ext);
                    return w.memoise(root, try w.term(.record, start, ext.int()));
                },
            },
            .alias => |a| {
                const args = w.store.vars(a.args);
                const words = try w.gpa.alloc(u32, args.len + 1);
                defer w.gpa.free(words);
                const copied = try w.gpa.dupe(Var, args);
                defer w.gpa.free(copied);
                for (copied, 0..) |arg, i| words[i] = (try w.writeVar(arg)).int();
                words[args.len] = (try w.writeVar(a.actual)).int();
                const start = try w.addRange(words);
                return w.memoise(root, try w.term(.alias, @intFromEnum(a.type), start));
            },
        }
    }

    fn memoise(w: *Writer, root: Var, t: Interface.TermIndex) Interface.TermIndex {
        if (root.int() < w.memo.len) w.memo[root.int()] = t;
        return t;
    }

    fn writeRange(w: *Writer, vars: []const Var) Error![]u32 {
        const copied = try w.gpa.dupe(Var, vars);
        defer w.gpa.free(copied);
        const out = try w.gpa.alloc(u32, copied.len);
        errdefer w.gpa.free(out);
        for (copied, out) |v, *o| o.* = (try w.writeVar(v)).int();
        return out;
    }

    fn quantifierOf(w: *Writer, root: Var, flags: TypeStore.Flags) Error!u32 {
        if (root.int() < w.quantified.len and w.quantified[root.int()] != unbound) {
            return w.quantified[root.int()];
        }
        const index = w.quantified_count;
        w.quantified_count += 1;
        if (root.int() < w.quantified.len) w.quantified[root.int()] = index;
        const q: Interface.Quantified = .{
            .kind = @intFromEnum(flags.kind),
            .equatable = flags.equatable,
            .name = flags.name,
        };
        try w.pending_flags.append(w.gpa, q.flags());
        try w.pending_flags.append(w.gpa, @intFromEnum(q.name));
        return index;
    }

    /// Move the tables onto `iface`, extending its symbol column. The
    /// interface is immutable after this.
    pub fn attach(w: *Writer, iface: *Interface) Error!void {
        const combined = try w.gpa.alloc(Symbol, iface.symbols.len + w.symbols.items.len);
        @memcpy(combined[0..iface.symbols.len], iface.symbols);
        @memcpy(combined[iface.symbols.len..], w.symbols.items);
        w.gpa.free(@constCast(iface.symbols));
        iface.symbols = combined;
        iface.schemes = try w.schemes.toOwnedSlice(w.gpa);
        iface.terms = w.terms.toOwnedSlice();
        iface.extra = try w.extra.toOwnedSlice(w.gpa);
    }
};

/// Copy an interface scheme into `store` at `rank`: one fresh variable per
/// quantifier, then the body rebuilt on top of them.
pub fn instantiate(
    iface: *const Interface,
    store: *TypeStore,
    scheme_index: u32,
    rank: u32,
    scratch: Allocator,
) Error!Var {
    const s = iface.schemes[scheme_index];
    const fresh = try scratch.alloc(Var, s.quantified_count);
    defer scratch.free(fresh);
    for (fresh, 0..) |*v, i| {
        const q = iface.quantified(s, @intCast(i));
        v.* = try store.fresh(.{ .flex = .{
            .name = q.name,
            .kind = @enumFromInt(q.kind),
            .equatable = q.equatable,
        } }, rank);
    }
    // One store variable per TERM, so a term referenced twice becomes one
    // variable and the sharing the writer preserved survives the crossing.
    const memo = try scratch.alloc(Var.Optional, iface.terms.len);
    defer scratch.free(memo);
    @memset(memo, .none);
    var reader: Reader = .{ .iface = iface, .store = store, .rank = rank, .scratch = scratch, .fresh = fresh, .memo = memo };
    return reader.read(s.body);
}

const Reader = struct {
    iface: *const Interface,
    store: *TypeStore,
    rank: u32,
    scratch: Allocator,
    fresh: []const Var,
    memo: []Var.Optional,
    depth: u32 = 0,

    fn read(r: *Reader, index: Interface.TermIndex) Error!Var {
        if (index == .none) return r.store.freshErr(r.rank);
        r.depth += 1;
        defer r.depth -= 1;
        if (r.depth > Writer.max_depth) return r.store.freshErr(r.rank);
        if (r.memo[index.int()].unwrap()) |v| return v;

        const t = r.iface.term(index);
        const v = switch (t.tag) {
            .err => try r.store.freshErr(r.rank),
            .@"var" => if (t.lhs < r.fresh.len) r.fresh[t.lhs] else try r.store.freshErr(r.rank),
            .unit => try r.store.fresh(.{ .structure = .unit }, r.rank),
            .empty_record => try r.store.fresh(.{ .structure = .empty_record }, r.rank),
            .func => blk: {
                const param = try r.read(@enumFromInt(t.lhs));
                const result = try r.read(@enumFromInt(t.rhs));
                break :blk try r.store.fresh(.{ .structure = .{ .func = .{ .param = param, .result = result } } }, r.rank);
            },
            .app => blk: {
                const args = try r.readRange(t.rhs);
                defer r.scratch.free(args);
                const range = try r.store.addVars(args);
                break :blk try r.store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(t.lhs), .args = range } } }, r.rank);
            },
            .tuple => blk: {
                const elements = try r.readRange(t.lhs);
                defer r.scratch.free(elements);
                const range = try r.store.addVars(elements);
                break :blk try r.store.fresh(.{ .structure = .{ .tuple = range } }, r.rank);
            },
            .record => blk: {
                const words = r.iface.range(t.lhs);
                const count = words.len / 2;
                const fields = try r.scratch.alloc(TypeStore.Field, count);
                defer r.scratch.free(fields);
                for (0..count) |i| {
                    fields[i] = .{
                        .name = r.iface.symbol(@enumFromInt(words[i * 2])),
                        .value = try r.read(@enumFromInt(words[i * 2 + 1])),
                    };
                }
                const range = try r.store.addFields(fields);
                const ext = try r.read(@enumFromInt(t.rhs));
                break :blk try r.store.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } }, r.rank);
            },
            .alias => blk: {
                const words = r.iface.range(t.rhs);
                // An alias range is its arguments followed by the
                // expansion, so it is never empty; a malformed one — M4
                // will map these from disk — must poison rather than
                // underflow the length.
                if (words.len == 0) break :blk try r.store.freshErr(r.rank);
                const args = try r.scratch.alloc(Var, words.len - 1);
                defer r.scratch.free(args);
                for (args, 0..) |*a, i| a.* = try r.read(@enumFromInt(words[i]));
                const actual = try r.read(@enumFromInt(words[words.len - 1]));
                const range = try r.store.addVars(args);
                break :blk try r.store.fresh(.{ .alias = .{ .type = @enumFromInt(t.lhs), .args = range, .actual = actual } }, r.rank);
            },
        };
        r.memo[index.int()] = v.toOptional();
        return v;
    }

    fn readRange(r: *Reader, start: u32) Error![]Var {
        const words = r.iface.range(start);
        const out = try r.scratch.alloc(Var, words.len);
        errdefer r.scratch.free(out);
        for (words, out) |word, *v| v.* = try r.read(@enumFromInt(word));
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a scheme round trips through terms with its sharing intact" {
    const gpa = testing.allocator;
    var store: TypeStore = .init(gpa);
    defer store.deinit();

    // `a -> a`: one generalised variable, used twice.
    const a = try store.fresh(.{ .flex = .{ .kind = .number } }, TypeStore.generalized);
    const body = try store.fresh(.{ .structure = .{ .func = .{ .param = a, .result = a } } }, TypeStore.generalized);

    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &store, 0);
    defer w.deinit();
    const index = try w.add(body);
    try w.attach(&iface);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(index));
    try testing.expectEqual(@as(u32, 1), iface.schemes[0].quantified_count);

    // Instantiating twice gives two independent copies, and within one copy
    // the two occurrences are the SAME variable (design §7 #4).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var target: TypeStore = .init(gpa);
    defer target.deinit();
    const first = try instantiate(&iface, &target, 0, 1, arena.allocator());
    const second = try instantiate(&iface, &target, 0, 1, arena.allocator());
    const f1 = target.content(target.find(first)).structure.func;
    const f2 = target.content(target.find(second)).structure.func;
    try testing.expectEqual(target.find(f1.param), target.find(f1.result));
    try testing.expect(target.find(f1.param) != target.find(f2.param));
    // The kind crossed with it: a `number` stays a `number`.
    try testing.expectEqual(TypeStore.Kind.number, target.content(target.find(f1.param)).flex.kind);
}

test "an errored declaration still gets a scheme, whose body is the error term" {
    const gpa = testing.allocator;
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &store, 0);
    defer w.deinit();
    _ = try w.addError();
    try w.attach(&iface);
    try testing.expectEqual(@as(usize, 1), iface.schemes.len);
    try testing.expectEqual(Interface.Term.Tag.err, iface.term(iface.schemes[0].body).tag);
}
