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
const Render = @import("Render.zig");
const Types = @import("Types.zig");

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
    /// The pool every `Symbol` written here comes from. Needed to order a
    /// record's fields by their TEXT — see `writeVar`'s `.record` arm.
    interner: *const InternPool.Global,
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
    /// Every root written into `memo` or `quantified` since the last reset,
    /// so a reset clears what this scheme touched instead of the whole
    /// store.
    ///
    /// This is Elm's `touched` trick and it is not an optimisation
    /// detail: the store has one variable per instruction of the module,
    /// and a module exporting `n` values calls `resetMemo` `n` times — so
    /// clearing the whole array made writing the interface quadratic in the
    /// module's size. Measured on one module of `n` mutually recursive
    /// `pub` declarations, the whole `check` phase: 31 ms at n = 4 000 and
    /// 135 ms at n = 8 000, none of it visible in a trace because it sits
    /// between the profiled events.
    touched: std.ArrayList(Var) = .empty,
    quantified_count: u32 = 0,
    /// Flags of the quantifiers discovered so far, moved into `extra` when
    /// the scheme is closed.
    pending_flags: std.ArrayList(u32) = .empty,
    depth: u32 = 0,
    /// Set when `max_depth` stopped the walk. The caller must REPORT and
    /// write `addError()` instead of the truncated body: an `err` term
    /// buried inside an otherwise concrete scheme is a hole that unifies
    /// with anything, so a dependent's mistake against this declaration
    /// would compile clean (`fast-compiler.md` §5 — a poisoned variable
    /// after a message, never instead of one). Cleared by `add`.
    too_deep: bool = false,

    const unbound: u32 = std.math.maxInt(u32);
    /// How deep a solved type may nest before the writer gives up. The same
    /// number as `Types.Builder.max_depth` and for the same reason: a type
    /// that came from an annotation cannot be deeper than the annotation
    /// was, so a scheme that trips this came from unification joining two
    /// annotations that each fit.
    pub const max_depth = 512;

    pub fn init(gpa: Allocator, store: *TypeStore, interner: *const InternPool.Global, symbol_base: u32) Writer {
        return .{ .gpa = gpa, .store = store, .interner = interner, .symbol_base = symbol_base };
    }

    pub fn deinit(w: *Writer) void {
        w.touched.deinit(w.gpa);
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
        w.too_deep = false;
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

    /// Where a constructor's argument types landed: the `extra` range of
    /// argument terms, and the quantifier block the `var(i)` inside them
    /// index into.
    pub const CtorTerms = struct {
        arg_terms: u32,
        quantified_start: u32,
    };

    /// Write one constructor's argument types (checker.md §7's `arg_terms`).
    ///
    /// `params` are the owning TYPE's parameters, as store variables; they
    /// are quantified FIRST and in order, so `var(i)` in an argument term is
    /// parameter `i` and a reader can rebuild `arg1 -> … -> argN -> T p0 … pk`
    /// knowing only the owning type. That is the whole reason a constructor
    /// needs no body term: the result half is determined by `Ctor.type`.
    ///
    /// Forcing the parameter order is the difference from `add`, which
    /// DISCOVERS quantifiers in first-appearance order. A constructor whose
    /// arguments do not mention every parameter — `type Phantom a = Phantom`
    /// — would otherwise number them by accident.
    pub fn addCtor(w: *Writer, params: []const Var, args: []const Var) Error!CtorTerms {
        try w.resetMemo();
        w.too_deep = false;
        for (params) |p| {
            const root = w.store.find(p);
            const flags: TypeStore.Flags = switch (w.store.content(root)) {
                .flex, .rigid => |f| f,
                else => .{},
            };
            _ = try w.quantifierOf(root, flags);
        }
        const words = try w.gpa.alloc(u32, args.len);
        defer w.gpa.free(words);
        for (args, words) |arg, *word| word.* = (try w.writeVar(arg)).int();
        const quantified_start: u32 = @intCast(w.extra.items.len);
        try w.extra.appendSlice(w.gpa, w.pending_flags.items);
        return .{ .arg_terms = try w.addRange(words), .quantified_start = quantified_start };
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
            // Growing initialises everything, which also clears whatever
            // the previous scheme touched.
            w.gpa.free(w.memo);
            w.memo = try w.gpa.alloc(Interface.TermIndex, n);
            w.gpa.free(w.quantified);
            w.quantified = try w.gpa.alloc(u32, n);
            @memset(w.memo, .none);
            @memset(w.quantified, unbound);
            w.touched.clearRetainingCapacity();
        } else {
            for (w.touched.items) |v| {
                w.memo[v.int()] = .none;
                w.quantified[v.int()] = unbound;
            }
            w.touched.clearRetainingCapacity();
        }
        w.quantified_count = 0;
        w.pending_flags.clearRetainingCapacity();
    }

    /// Remember that `root` has an entry in `memo` or `quantified`, so the
    /// next `resetMemo` clears it. A root may be recorded twice — once for
    /// each table — which costs a second clear and no correctness.
    fn touch(w: *Writer, root: Var) Error!void {
        try w.touched.append(w.gpa, root);
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
        if (w.depth > max_depth) {
            w.too_deep = true;
            return w.term(.err, 0, 0);
        }

        const root = w.store.find(v);
        if (root.int() < w.memo.len and w.memo[root.int()] != .none) return w.memo[root.int()];

        const content = w.store.content(root);
        // EVERY arm memoises, the leaves included. A leaf writes a term
        // with no operands, so sharing one looks like an economy and is
        // actually the contract: the reader memoises per TERM, so a source
        // variable that wrote two identical `unit` terms comes back as two
        // variables where it went in as one, and "sharing survives the
        // crossing" (design §7 #4) stops being true of the whole type.
        switch (content) {
            .err => return try w.memoise(root, try w.term(.err, 0, 0)),
            .flex, .rigid => |flags| {
                const index = try w.quantifierOf(root, flags);
                const t = try w.term(.@"var", index, 0);
                return try w.memoise(root, t);
            },
            .structure => |flat| switch (flat) {
                .unit => return try w.memoise(root, try w.term(.unit, 0, 0)),
                .empty_record => return try w.memoise(root, try w.term(.empty_record, 0, 0)),
                .func => |f| {
                    const param = try w.writeVar(f.param);
                    const result = try w.writeVar(f.result);
                    return try w.memoise(root, try w.term(.func, param.int(), result.int()));
                },
                .app => |a| {
                    const words = try w.writeRange(w.store.vars(a.args));
                    defer w.gpa.free(words);
                    const start = try w.addRange(words);
                    return try w.memoise(root, try w.term(.app, @intFromEnum(a.type), start));
                },
                .tuple => |t| {
                    const words = try w.writeRange(w.store.vars(t));
                    defer w.gpa.free(words);
                    const start = try w.addRange(words);
                    return try w.memoise(root, try w.term(.tuple, start, 0));
                },
                .record => |r| {
                    const fields = try w.gpa.dupe(TypeStore.Field, w.store.fields(r.fields));
                    defer w.gpa.free(fields);
                    // Sorted by TEXT, which is the interface's rule
                    // everywhere else (`Interface`'s header). The store
                    // orders a record's fields by SYMBOL ID so unification
                    // can merge-join them, and a symbol id depends on which
                    // worker interned which file (`InternPool`'s header) —
                    // so writing them in the store's order would make the
                    // bytes of `terms`, `extra` AND the `quantified`
                    // numbering a function of `--jobs`. §8.1 has M4 hashing
                    // this record; a hash of a scheduling-dependent byte
                    // layout is a cache that misses at random.
                    std.mem.sort(TypeStore.Field, fields, w.interner, fieldNameLessThan);
                    const words = try w.gpa.alloc(u32, fields.len * 2);
                    defer w.gpa.free(words);
                    for (fields, 0..) |f, i| {
                        words[i * 2] = try w.symbolIndex(f.name);
                        words[i * 2 + 1] = (try w.writeVar(f.value)).int();
                    }
                    const start = try w.addRange(words);
                    const ext = try w.writeVar(r.ext);
                    return try w.memoise(root, try w.term(.record, start, ext.int()));
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
                return try w.memoise(root, try w.term(.alias, @intFromEnum(a.type), start));
            },
        }
    }

    fn fieldNameLessThan(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
        return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
    }

    fn memoise(w: *Writer, root: Var, t: Interface.TermIndex) Error!Interface.TermIndex {
        if (root.int() < w.memo.len) {
            w.memo[root.int()] = t;
            try w.touch(root);
        }
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
        if (root.int() < w.quantified.len) {
            w.quantified[root.int()] = index;
            try w.touch(root);
        }
        const q: Interface.Quantified = .{
            .kind = @intFromEnum(flags.kind),
            .equatable = flags.equatable,
            // Into the interface's own column, never the interner's — see
            // `Interface.Quantified.name`.
            .name = if (flags.name.unwrap()) |n|
                @enumFromInt(try w.symbolIndex(n))
            else
                .none,
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
            .name = iface.quantifiedSymbol(q),
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

/// Copy an imported constructor's type into `store` at `rank`:
/// `arg1 -> … -> argN -> T p0 … pk`, with one fresh variable per parameter
/// of the owning type.
///
/// The mirror of `instantiate`, and the point of `Interface.Ctor.arg_terms`:
/// a dependent builds an imported constructor's type out of the interface
/// alone, never out of the declaring module's `Bir`. `type_id` is what
/// `Types.ofInterface` says the owning type is in THIS session — the
/// interface stores its own `TypeIndex`, which is meaningless anywhere
/// else.
///
/// Null when the constructor has no terms: the declaring module was never
/// checked, or its declaration was too deep to read. The caller poisons.
pub fn instantiateCtor(
    iface: *const Interface,
    store: *TypeStore,
    ctor_index: u32,
    type_id: TypeStore.TypeId,
    rank: u32,
    scratch: Allocator,
) Error!?Var {
    if (ctor_index >= iface.ctors.len) return null;
    const c = iface.ctors[ctor_index];
    if (c.arg_terms == Interface.no_terms) return null;
    if (@intFromEnum(c.type) >= iface.types.len) return null;
    const arity = iface.types[@intFromEnum(c.type)].arity;

    const fresh = try scratch.alloc(Var, arity);
    defer scratch.free(fresh);
    for (fresh, 0..) |*v, i| {
        const q = iface.ctorQuantified(c, @intCast(i));
        v.* = try store.fresh(.{ .flex = .{
            .name = iface.quantifiedSymbol(q),
            .kind = @enumFromInt(q.kind),
            .equatable = q.equatable,
        } }, rank);
    }
    const memo = try scratch.alloc(Var.Optional, iface.terms.len);
    defer scratch.free(memo);
    @memset(memo, .none);
    var reader: Reader = .{ .iface = iface, .store = store, .rank = rank, .scratch = scratch, .fresh = fresh, .memo = memo };

    const words = iface.range(c.arg_terms);
    const args = try scratch.alloc(Var, words.len);
    defer scratch.free(args);
    for (words, args) |word, *v| v.* = try reader.read(@enumFromInt(word));

    // The result: the owning type applied to its own parameters. An ADT is
    // an `app` and never an `alias` — only a `type` declares constructors.
    const params = try store.addVars(fresh);
    var result = try store.fresh(.{ .structure = .{ .app = .{ .type = type_id, .args = params } } }, rank);
    var i = args.len;
    while (i > 0) {
        i -= 1;
        result = try store.fresh(.{ .structure = .{ .func = .{ .param = args[i], .result = result } } }, rank);
    }
    return result;
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
        // Silence is right HERE and nowhere else in this file: the writer
        // refuses to emit a term deeper than `max_depth`, so a well-formed
        // interface cannot trip this. What can is a record M4 mapped from
        // disk that does not describe itself, and there is no source
        // position in THIS module to point a message at — the module that
        // wrote it reported when it wrote it.
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
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();

    // `a -> a`: one generalised variable, used twice.
    const a = try store.fresh(.{ .flex = .{ .kind = .number } }, TypeStore.generalized);
    const body = try store.fresh(.{ .structure = .{ .func = .{ .param = a, .result = a } } }, TypeStore.generalized);

    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &store, &interner, 0);
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

/// Build a random solved type at `TypeStore.generalized`, with deliberate
/// SHARING: a new node's children are sometimes an earlier node rather than
/// a fresh one, which is the property the whole round trip exists to
/// preserve (design §7 #4). Never cyclic — a child is always a node that
/// already existed, so nothing can contain itself.
const RandomType = struct {
    gpa: Allocator,
    store: *TypeStore,
    random: std.Random,
    made: std.ArrayList(Var) = .empty,
    names: []const Symbol,

    const max_depth = 4;

    fn deinit(g: *RandomType) void {
        g.made.deinit(g.gpa);
    }

    fn make(g: *RandomType, depth: u32) Error!Var {
        if (g.made.items.len != 0 and g.random.uintLessThan(u32, 10) < 3) {
            return g.made.items[g.random.uintLessThan(usize, g.made.items.len)];
        }
        const v = try g.build(depth);
        try g.made.append(g.gpa, v);
        return v;
    }

    fn build(g: *RandomType, depth: u32) Error!Var {
        const rank = TypeStore.generalized;
        const choice = if (depth >= max_depth) g.random.uintLessThan(u32, 3) else g.random.uintLessThan(u32, 7);
        switch (choice) {
            0 => return g.store.fresh(.{ .flex = .{
                .name = g.names[g.random.uintLessThan(usize, g.names.len)].toOptional(),
                .kind = @enumFromInt(g.random.uintLessThan(u32, 3)),
                .equatable = g.random.boolean(),
            } }, rank),
            1 => return g.store.fresh(.{ .structure = .unit }, rank),
            2 => return g.store.fresh(.{ .structure = .empty_record }, rank),
            3 => {
                const param = try g.make(depth + 1);
                const result = try g.make(depth + 1);
                return g.store.fresh(.{ .structure = .{ .func = .{ .param = param, .result = result } } }, rank);
            },
            4 => {
                const n = 1 + g.random.uintLessThan(usize, 3);
                const elements = try g.gpa.alloc(Var, n);
                defer g.gpa.free(elements);
                for (elements) |*e| e.* = try g.make(depth + 1);
                const range = try g.store.addVars(elements);
                return g.store.fresh(.{ .structure = .{ .tuple = range } }, rank);
            },
            5 => {
                // Distinct field names, drawn without replacement so the
                // record is well formed however they sort.
                const n = 1 + g.random.uintLessThan(usize, g.names.len - 1);
                const pairs = try g.gpa.alloc(TypeStore.Field, n);
                defer g.gpa.free(pairs);
                for (pairs, 0..) |*f, i| f.* = .{ .name = g.names[i], .value = try g.make(depth + 1) };
                const range = try g.store.addFields(pairs);
                const ext = if (g.random.boolean())
                    try g.store.fresh(.{ .structure = .empty_record }, rank)
                else
                    try g.store.fresh(.{ .flex = .{} }, rank);
                return g.store.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } }, rank);
            },
            else => {
                const n = g.random.uintLessThan(usize, 3);
                const args = try g.gpa.alloc(Var, n);
                defer g.gpa.free(args);
                for (args) |*a| a.* = try g.make(depth + 1);
                const range = try g.store.addVars(args);
                return g.store.fresh(.{ .structure = .{ .app = .{ .type = .none, .args = range } } }, rank);
            },
        }
    }
};

/// How many DISTINCT variables a type is built from, counting through
/// aliases and structures. Sharing is exactly this number being smaller
/// than the node count, so comparing it on both sides of the crossing is
/// how "the sharing survived" is stated without reaching into either store.
fn distinctVars(gpa: Allocator, store: *TypeStore, root: Var) Allocator.Error!usize {
    const mark = store.nextMark();
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root);
    var seen: usize = 0;
    while (stack.pop()) |v| {
        const r = store.find(v);
        if (store.mark(r) == mark) continue;
        store.setMark(r, mark);
        seen += 1;
        var i: u32 = 0;
        while (nthChildOf(store, r, i)) |child| : (i += 1) try stack.append(gpa, child);
    }
    return seen;
}

fn nthChildOf(store: *TypeStore, root: Var, n: u32) ?Var {
    switch (store.content(root)) {
        .err, .flex, .rigid => return null,
        .alias => |a| {
            if (n == 0) return a.actual;
            const args = store.vars(a.args);
            return if (n - 1 < args.len) args[n - 1] else null;
        },
        .structure => |flat| switch (flat) {
            .unit, .empty_record => return null,
            .func => |f| return switch (n) {
                0 => f.param,
                1 => f.result,
                else => null,
            },
            .app => |a| {
                const args = store.vars(a.args);
                return if (n < args.len) args[n] else null;
            },
            .tuple => |t| {
                const elements = store.vars(t);
                return if (n < elements.len) elements[n] else null;
            },
            .record => |r| {
                const fs = store.fields(r.fields);
                if (n < fs.len) return fs[n].value;
                return if (n == fs.len) r.ext else null;
            },
        },
    }
}

/// Write a random solved type through `Writer`, read it back with
/// `instantiate`, and assert the two render identically and share the same
/// number of variables.
///
/// This is the only part of the M4 firewall that can be tested today
/// (`fast-compiler.md` §8.1): the interface is the whole contract between a
/// module and its dependents, and until M4 maps one from disk, a round trip
/// through the term language is the closest thing to a dependent reading
/// it. It is a property test rather than a golden because the failures it
/// is looking for — a field order that depends on scheduling, an `err` term
/// smuggled into an otherwise concrete type, a quantifier numbered by
/// accident — do not show on any one hand-written example.
fn expectRoundTrip(seed: u64) !void {
    const gpa = testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var names: [5]Symbol = undefined;
    for (&names, [_][]const u8{ "zulu", "alpha", "middle", "bravo", "kilo" }) |*sym, text| {
        sym.* = try interner.getOrPut(gpa, text);
    }

    var prng: std.Random.DefaultPrng = .init(seed);
    var source: TypeStore = .init(gpa);
    defer source.deinit();
    var g: RandomType = .{ .gpa = gpa, .store = &source, .random = prng.random(), .names = &names };
    defer g.deinit();
    const root = try g.make(0);

    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &source, &interner, 0);
    defer w.deinit();
    const index = try w.add(root);
    try testing.expect(!w.too_deep);
    try w.attach(&iface);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var target: TypeStore = .init(gpa);
    defer target.deinit();
    const copy = try instantiate(&iface, &target, @intFromEnum(index), TypeStore.generalized, arena.allocator());

    // The record must not have smuggled an error term into a type that had
    // none: `err` unifies with anything, so one hiding inside a published
    // scheme is a hole in every dependent.
    for (iface.terms.items(.tag)) |tag| try testing.expect(tag != .err);

    const types: Types = .empty;
    const before = try renderOf(gpa, &source, &types, &interner, root);
    defer gpa.free(before);
    const after = try renderOf(gpa, &target, &types, &interner, copy);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);

    try testing.expectEqual(
        try distinctVars(gpa, &source, root),
        try distinctVars(gpa, &target, copy),
    );
}

fn renderOf(
    gpa: Allocator,
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    v: Var,
) Allocator.Error![]u8 {
    var namer: Render.Namer = .init(gpa);
    defer namer.deinit();
    return Render.allocType(gpa, .{ .store = store, .types = types, .interner = interner }, &namer, v);
}

test "a random solved type renders the same after a round trip through the interface" {
    // 256 shapes rather than one: the properties this is looking for —
    // field order, quantifier numbering, sharing — need a type that has
    // several of each before they can differ.
    for (0..256) |seed| try expectRoundTrip(seed);
}

test "fuzz the interface round trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0x5CE3E);
            var seed: u64 = 0;
            for (buf[0..len]) |b| seed = seed *% 31 +% b;
            try expectRoundTrip(seed);
        }
    }.testOne, .{});
}

test "an errored declaration still gets a scheme, whose body is the error term" {
    const gpa = testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &store, &interner, 0);
    defer w.deinit();
    _ = try w.addError();
    try w.attach(&iface);
    try testing.expectEqual(@as(usize, 1), iface.schemes.len);
    try testing.expectEqual(Interface.Term.Tag.err, iface.term(iface.schemes[0].body).tag);
}
