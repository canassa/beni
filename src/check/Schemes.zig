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
    /// The session type table, read ONLY to turn a store `TypeId` into the
    /// `(package, module name, type name)` an `Interface.TypeRef` holds.
    /// Writing the id itself is what `Interface`'s purity rule forbids.
    types: *const Types,
    /// Where this writer's symbols land in the finished column: the
    /// interface already has one, and these are appended to it.
    symbol_base: u32,
    schemes: std.ArrayList(Interface.Scheme) = .empty,
    terms: std.MultiArrayList(Interface.Term) = .empty,
    extra: std.ArrayList(u32) = .empty,
    type_refs: std.ArrayList(Interface.TypeRef) = .empty,
    /// The `TypeId` behind each row of `type_refs`, so the same type named
    /// twice writes one row and both terms point at it.
    ///
    /// A linear scan rather than a dense `TypeId → row` side array: a
    /// module's interface names a handful of types — 36 rows across the
    /// nine modules of `core/` — while the session type table has one entry
    /// per type in the PROJECT, so a dense array would cost an allocation
    /// and a memset proportional to the whole program once per module, to
    /// index four entries.
    ref_ids: std.ArrayList(TypeStore.TypeId) = .empty,
    /// `ref_ids` inverted: a type's row, so `typeRefOf` is O(1) and not a
    /// scan per mention (CK-124: quadratic in a module's named types).
    ref_index: std.AutoHashMapUnmanaged(TypeStore.TypeId, u32) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    /// `Var → TermIndex` for the scheme being written; dense over the
    /// store. Never a map: a `Var` is a dense id and the house rules forbid
    /// hashing one. A slot means something only while its `stamp` is the
    /// current `epoch`.
    memo: []Interface.TermIndex = &.{},
    /// `Var → quantified index` for the scheme being written, under the
    /// same stamp.
    quantified: []u32 = &.{},
    /// **Epoch marks** (`checker-v2.md` §14.2, CK-41): slot `v` of `memo`
    /// and `quantified` is live only when `stamp[v] == epoch`, and a reset
    /// is one increment. Nothing is cleared per scheme, and the three
    /// arrays grow to at least TWICE their length when the store outgrows
    /// them, so growing is amortised.
    ///
    /// Both halves are load-bearing. Clearing the whole array per scheme
    /// made writing an interface quadratic in the module's size (the
    /// store has one variable per instruction, and a module exporting `n`
    /// values resets `n` times); Elm's `touched` list fixed that, but the
    /// arrays were still reallocated and memset to the store's EXACT size
    /// whenever it had grown — and `fillCtorTerms` grows the store before
    /// every constructor, so one type of `n` constructors cost O(n × store):
    /// 390 ms at 4 000 constructors and 1 416 ms at 8 000 on 050cd2d
    /// (ReleaseFast), a ratio of 3.6.
    stamp: []u32 = &.{},
    epoch: u32 = 0,
    quantified_count: u32 = 0,
    /// Flags of the quantifiers discovered so far, moved into `extra` when
    /// the scheme is closed. `Quantified.words` words each; the last two —
    /// the constraint block's start and length — are patched by
    /// `writeConstraints` once the body is written
    /// (static-dispatch-spike.md §6.5).
    pending_flags: std.ArrayList(u32) = .empty,
    /// The store root behind each quantifier, parallel to `pending_flags`.
    /// A quantifier's constraints live on its variable, and they can only
    /// be written after the body — writing one's type may discover a
    /// further quantifier, and a quantifier's four words have to stay
    /// contiguous.
    pending_roots: std.ArrayList(Var) = .empty,
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

    pub fn init(
        gpa: Allocator,
        store: *TypeStore,
        interner: *const InternPool.Global,
        types: *const Types,
        symbol_base: u32,
    ) Writer {
        return .{ .gpa = gpa, .store = store, .interner = interner, .types = types, .symbol_base = symbol_base };
    }

    pub fn deinit(w: *Writer) void {
        w.schemes.deinit(w.gpa);
        w.terms.deinit(w.gpa);
        w.extra.deinit(w.gpa);
        w.type_refs.deinit(w.gpa);
        w.ref_ids.deinit(w.gpa);
        w.ref_index.deinit(w.gpa);
        w.symbols.deinit(w.gpa);
        w.pending_flags.deinit(w.gpa);
        w.pending_roots.deinit(w.gpa);
        w.gpa.free(w.memo);
        w.gpa.free(w.quantified);
        w.gpa.free(w.stamp);
        w.* = undefined;
    }

    /// Seed the shared `extra` column with the interface skeleton's rows.
    /// Schema parameter-name ranges are known at resolution time, before
    /// solved schemes exist; every term range written afterwards therefore
    /// starts beyond this prefix and both sets of offsets remain valid.
    pub fn seedExtra(w: *Writer, words: []const u32) Error!void {
        std.debug.assert(w.extra.items.len == 0);
        try w.extra.appendSlice(w.gpa, words);
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
        try w.writeConstraints();
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

    /// Write one solved root for an unhashed schema plan. Unlike `add`, this
    /// emits no Scheme row or constraint block: the plan retains the canonical
    /// endpoint/conversion term itself and owns the moved flat tables.
    pub fn addPlanRoot(w: *Writer, v: Var) Error!Interface.TermIndex {
        try w.resetMemo();
        w.too_deep = false;
        return w.writeVar(v);
    }

    pub const PlanTerms = struct {
        terms: std.MultiArrayList(Interface.Term).Slice,
        extra: []const u32,
        type_refs: []const Interface.TypeRef,
        symbols: []const Symbol,
    };

    /// Move the position-free term tables into a resolved schema plan.
    pub fn takePlanTerms(w: *Writer) Error!PlanTerms {
        const extra = try w.extra.toOwnedSlice(w.gpa);
        errdefer w.gpa.free(extra);
        const type_refs = try w.type_refs.toOwnedSlice(w.gpa);
        errdefer w.gpa.free(type_refs);
        const symbols = try w.symbols.toOwnedSlice(w.gpa);
        errdefer w.gpa.free(symbols);
        return .{
            .terms = w.terms.toOwnedSlice(),
            .extra = extra,
            .type_refs = type_refs,
            .symbols = symbols,
        };
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
        try w.writeConstraints();
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

    /// Start a new scheme: a new epoch, so every slot written for the last
    /// one reads as empty, and — when the store has outgrown the arrays —
    /// arrays at least twice as long, every stamp zero (see `stamp`).
    fn resetMemo(w: *Writer) Error!void {
        const n = w.store.count();
        if (w.stamp.len < n) {
            const len = @max(n, w.stamp.len * 2);
            w.gpa.free(w.memo);
            w.memo = &.{};
            w.gpa.free(w.quantified);
            w.quantified = &.{};
            w.gpa.free(w.stamp);
            w.stamp = &.{};
            w.memo = try w.gpa.alloc(Interface.TermIndex, len);
            w.quantified = try w.gpa.alloc(u32, len);
            w.stamp = try w.gpa.alloc(u32, len);
            @memset(w.stamp, 0);
            w.epoch = 0;
        }
        w.epoch +%= 1;
        if (w.epoch == 0) {
            // Four billion schemes in one writer: start the stamps again.
            @memset(w.stamp, 0);
            w.epoch = 1;
        }
        w.quantified_count = 0;
        w.pending_flags.clearRetainingCapacity();
        w.pending_roots.clearRetainingCapacity();
    }

    /// Write every quantifier's constraint block and patch its two words
    /// (static-dispatch-spike.md §6.5).
    ///
    /// By INDEX and re-reading the length each round, because writing a
    /// constraint's type can discover a further quantifier — which then
    /// needs its own block — and because `pending_roots` grows from under a
    /// held slice while that happens.
    fn writeConstraints(w: *Writer) Error!void {
        var i: usize = 0;
        while (i < w.pending_roots.items.len) : (i += 1) {
            const root = w.pending_roots.items[i];
            const set = w.store.flagsOf(root).constraints;
            const n = w.store.constraintCount(set);
            if (n == 0) continue;
            // Sorted by name TEXT, never by symbol id (§6.5 rule 1).
            const sorted = try w.gpa.alloc(TypeStore.MethodConstraint, n);
            defer w.gpa.free(sorted);
            for (sorted, 0..) |*c, j| c.* = w.store.constraintAt(set, @intCast(j));
            std.mem.sort(TypeStore.MethodConstraint, sorted, w.interner, constraintNameLessThan);
            const words = try w.gpa.alloc(u32, n * 2);
            defer w.gpa.free(words);
            for (sorted, 0..) |c, j| {
                words[j * 2] = try w.symbolIndex(c.name);
                words[j * 2 + 1] = (try w.writeVar(c.fn_var)).int();
            }
            const start: u32 = @intCast(w.extra.items.len);
            try w.extra.appendSlice(w.gpa, words);
            const at = i * Interface.Quantified.words;
            w.pending_flags.items[at + 2] = start;
            w.pending_flags.items[at + 3] = @intCast(n);
        }
    }

    fn constraintNameLessThan(
        interner: *const InternPool.Global,
        a: TypeStore.MethodConstraint,
        b: TypeStore.MethodConstraint,
    ) bool {
        return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
    }

    /// Whether `root`'s slots belong to the scheme being written.
    fn live(w: *const Writer, root: Var) bool {
        return root.int() < w.stamp.len and w.stamp[root.int()] == w.epoch;
    }

    /// Claim `root`'s slots for this scheme, emptying both the first time.
    /// False when the store grew past the arrays after the last reset — a
    /// root that is then simply not memoised, as before.
    fn claim(w: *Writer, root: Var) bool {
        if (root.int() >= w.stamp.len) return false;
        if (w.stamp[root.int()] != w.epoch) {
            w.stamp[root.int()] = w.epoch;
            w.memo[root.int()] = .none;
            w.quantified[root.int()] = unbound;
        }
        return true;
    }

    fn term(w: *Writer, tag: Interface.Term.Tag, lhs: u32, rhs: u32) Error!Interface.TermIndex {
        const index: u32 = @intCast(w.terms.len);
        try w.terms.append(w.gpa, .{ .tag = tag, .lhs = lhs, .rhs = rhs });
        return @enumFromInt(index);
    }

    pub fn addRange(w: *Writer, words: []const u32) Error!u32 {
        const start: u32 = @intCast(w.extra.items.len);
        try w.extra.append(w.gpa, @intCast(words.len));
        try w.extra.appendSlice(w.gpa, words);
        return start;
    }

    pub fn symbolIndex(w: *Writer, s: Symbol) Error!u32 {
        const index: u32 = w.symbol_base + @as(u32, @intCast(w.symbols.items.len));
        try w.symbols.append(w.gpa, s);
        return index;
    }

    /// The row of `type_refs` that names `id`, appending one if this is the
    /// first mention. A poisoned id gets `none`, which reads back as the
    /// same poisoned id.
    ///
    /// **The row's CONTENT is what makes the record pure**: the declaring
    /// module's package and name and the type's own name, none of which
    /// moves when an unrelated module gains a declaration. The row's
    /// POSITION is first mention in this walk, which is a function of the
    /// module's own source — the `pub` declarations in name order, each
    /// term walked in the order `writeVar` descends.
    /// Public for a publisher that names a type outside any term: a
    /// `private_method` row's culprit (checker-v2.md §14.2 *as amended by
    /// R8b*).
    pub fn typeRefOf(w: *Writer, id: TypeStore.TypeId) Error!Interface.TypeRefIndex {
        const t = w.types.named(id) orelse return .none;
        if (w.ref_index.get(id)) |i| return @enumFromInt(i);
        const index: Interface.TypeRefIndex = @enumFromInt(@as(u32, @intCast(w.type_refs.items.len)));
        try w.type_refs.append(w.gpa, .{
            .package = t.package,
            .module = @enumFromInt(try w.symbolIndex(t.module)),
            .name = @enumFromInt(try w.symbolIndex(t.name)),
        });
        try w.ref_ids.append(w.gpa, id);
        try w.ref_index.put(w.gpa, id, @intFromEnum(index));
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
        if (w.live(root) and w.memo[root.int()] != .none) return w.memo[root.int()];

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
                    const words = try w.writeRange(w.store.vars(f.params));
                    defer w.gpa.free(words);
                    const start = try w.addRange(words);
                    const result = try w.writeVar(f.result);
                    return try w.memoise(root, try w.term(.func, start, result.int()));
                },
                .app => |a| {
                    const words = try w.writeRange(w.store.vars(a.args));
                    defer w.gpa.free(words);
                    const start = try w.addRange(words);
                    const ref = try w.typeRefOf(a.type);
                    return try w.memoise(root, try w.term(.app, ref.int(), start));
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
                const ref = try w.typeRefOf(a.type);
                return try w.memoise(root, try w.term(.alias, ref.int(), start));
            },
        }
    }

    fn memoise(w: *Writer, root: Var, t: Interface.TermIndex) Error!Interface.TermIndex {
        if (w.claim(root)) w.memo[root.int()] = t;
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
        if (w.live(root) and w.quantified[root.int()] != unbound) {
            return w.quantified[root.int()];
        }
        const index = w.quantified_count;
        w.quantified_count += 1;
        if (w.claim(root)) w.quantified[root.int()] = index;
        const q: Interface.Quantified = .{
            .kind = @intFromEnum(flags.kind),
            .equatable = flags.equatable,
            // Into the interface's own column, never the interner's — see
            // `Interface.Quantified.name`.
            // A name that disagrees with the kind is not published: it was
            // inherited through a merge, which member order decides
            // (checker.md §8.7, CK-94 and its F8).
            .name = if (flags.name.unwrap()) |n|
                (if (Render.nameAgreesWithKind(w.interner.slice(n), flags.kind)) @enumFromInt(try w.symbolIndex(n)) else .none)
            else
                .none,
        };
        try w.pending_flags.append(w.gpa, q.flags());
        try w.pending_flags.append(w.gpa, @intFromEnum(q.name));
        // Patched by `writeConstraints`; a quantifier with none keeps
        // `0, 0` and consumes no `extra` (§6.5 rule 4).
        try w.pending_flags.append(w.gpa, 0);
        try w.pending_flags.append(w.gpa, 0);
        try w.pending_roots.append(w.gpa, root);
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
        w.gpa.free(@constCast(iface.extra));
        iface.extra = try w.extra.toOwnedSlice(w.gpa);
        iface.type_refs = try w.type_refs.toOwnedSlice(w.gpa);
    }
};

/// The quantifiers of a solved type, in the order `Writer` records them
/// (static-dispatch-spike.md §7.2's canonical order).
///
/// **This must agree with `Writer.writeVar` exactly**, because caller and
/// callee compute the evidence order independently — the callee from its own
/// store, the caller from the interface record — and a disagreement is a
/// silent miscompile rather than a diagnostic. It lives here, next to the
/// writer, and `quantifier order matches the writer` below pins the one case
/// where the two could plausibly drift: a record, whose fields the writer
/// sorts by name TEXT before descending (`Schemes.zig`'s `.record` arm).
///
/// Appends the roots to `out`; a root already in `out` is not appended
/// again. Roots discovered inside a constraint's own type come after the
/// whole body, exactly as `writeConstraints` discovers them.
pub fn quantifierOrder(
    store: *TypeStore,
    interner: *const InternPool.Global,
    v: Var,
    out: *std.ArrayList(Var),
    gpa: Allocator,
) Error!void {
    const mark = store.nextMark();
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(gpa);
    try orderWalk(store, interner, v, out, gpa, mark, &stack);
    // A quantifier's constraints can mention a variable the body never
    // reaches only when §2.4's closure rule was not in force — an inferred
    // scheme. By index and re-reading the length, because the walk appends.
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const root = out.items[i];
        const set = store.flagsOf(root).constraints;
        const n = store.constraintCount(set);
        if (n == 0) continue;
        const sorted = try gpa.alloc(TypeStore.MethodConstraint, n);
        defer gpa.free(sorted);
        for (sorted, 0..) |*c, j| c.* = store.constraintAt(set, @intCast(j));
        std.mem.sort(TypeStore.MethodConstraint, sorted, interner, constraintLessThan);
        for (sorted) |c| try orderWalk(store, interner, c.fn_var, out, gpa, mark, &stack);
    }
}

fn fieldNameLessThan(interner: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
    return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
}

fn constraintLessThan(
    interner: *const InternPool.Global,
    a: TypeStore.MethodConstraint,
    b: TypeStore.MethodConstraint,
) bool {
    return std.mem.lessThan(u8, interner.slice(a.name), interner.slice(b.name));
}

/// The walk of `quantifierOrder`: a preorder over the solved type from `v`,
/// appending each variable root the first time it is reached — function
/// parameters then result, arguments in order, record fields by name TEXT
/// then the extension, an alias's arguments then its expansion.
///
/// **An explicit stack, with no depth cap** (CK-135). It recursed, and
/// stopped in silence at `Writer.max_depth`: a variable 2^10 tuple levels
/// down (`w x = ( x, x )` applied ten times) was left out of a scheme's
/// canonical order while `Instantiate` counted it, so an instantiation's
/// requirement was paired with no wanted (I5, I4). A node is marked when it
/// is POPPED and its successors are pushed in reverse, which visits them in
/// exactly the recursive order. The writer's own bound is not this walk's:
/// a type too deep to WRITE is reported by the writer (`too_deep`), and the
/// declaration then fails, so the two orders can only differ for a scheme
/// that is never published.
fn orderWalk(
    store: *TypeStore,
    interner: *const InternPool.Global,
    v: Var,
    out: *std.ArrayList(Var),
    gpa: Allocator,
    mark: u32,
    stack: *std.ArrayList(Var),
) Error!void {
    stack.clearRetainingCapacity();
    try stack.append(gpa, v);
    while (stack.pop()) |next| {
        const root = store.find(next);
        if (store.mark(root) == mark) continue;
        store.setMark(root, mark);
        switch (store.content(root)) {
            .err => {},
            .flex, .rigid => try out.append(gpa, root),
            .structure => |flat| switch (flat) {
                .unit, .empty_record => {},
                .func => |f| {
                    try stack.append(gpa, f.result);
                    try pushReversed(stack, gpa, store.vars(f.params));
                },
                .app => |a| try pushReversed(stack, gpa, store.vars(a.args)),
                .tuple => |t| try pushReversed(stack, gpa, store.vars(t)),
                .record => |r| {
                    try stack.append(gpa, r.ext);
                    const fields = try gpa.dupe(TypeStore.Field, store.fields(r.fields));
                    defer gpa.free(fields);
                    // By name TEXT, which is what the writer descends in.
                    std.mem.sort(TypeStore.Field, fields, interner, fieldNameLessThan);
                    var i = fields.len;
                    while (i > 0) {
                        i -= 1;
                        try stack.append(gpa, fields[i].value);
                    }
                },
            },
            .alias => |a| {
                try stack.append(gpa, a.actual);
                try pushReversed(stack, gpa, store.vars(a.args));
            },
        }
    }
}

/// Push `vars` so that they pop in order. `vars` is the store's, which the
/// walk never grows, so it is read in place.
fn pushReversed(stack: *std.ArrayList(Var), gpa: Allocator, vars: []const Var) Error!void {
    var i = vars.len;
    while (i > 0) {
        i -= 1;
        try stack.append(gpa, vars[i]);
    }
}

/// A reader's memo of an interface's terms, by term index: one variable per
/// term, so a term referenced twice becomes one variable (`instantiate`).
/// Kept by a module's check and reused by every instantiation it makes
/// (R14b): a slot holds a variable only while its stamp is the current
/// read's, so starting a read is one increment, not a clear of a table as
/// long as the whole interface, which an instantiation of a small scheme
/// from `core` paid on every use.
pub const TermMemo = struct {
    slots: std.ArrayList(Slot) = .empty,
    stamp: u32 = 0,

    const Slot = struct { stamp: u32 = 0, v: Var = undefined };

    pub fn deinit(m: *TermMemo, gpa: Allocator) void {
        m.slots.deinit(gpa);
    }

    /// A new read over `len` terms: every slot empty.
    fn begin(m: *TermMemo, gpa: Allocator, len: usize) Error!void {
        if (m.slots.items.len < len) try m.slots.appendNTimes(gpa, .{}, len - m.slots.items.len);
        m.stamp +%= 1;
        if (m.stamp == 0) {
            @memset(m.slots.items, .{});
            m.stamp = 1;
        }
    }

    fn get(m: *const TermMemo, index: u32) ?Var {
        const slot = m.slots.items[index];
        return if (slot.stamp == m.stamp) slot.v else null;
    }

    fn put(m: *TermMemo, index: u32, v: Var) void {
        m.slots.items[index] = .{ .stamp = m.stamp, .v = v };
    }
};

/// Copy an interface scheme into `store` at `rank`: one fresh variable per
/// quantifier, then the body rebuilt on top of them.
///
/// `type_ids` is this session's translation of `iface.type_refs`, which is
/// `Types.refIds` of the module the record belongs to. It is passed in
/// rather than resolved here because it is built ONCE per module, when that
/// module is checked, and read on every import use: resolving a reference
/// has to stay one array index however many times a scheme is instantiated
/// (`Interface.TypeRef`, `Types.ref_ids`).
pub fn instantiate(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    scheme_index: u32,
    rank: u32,
    scratch: Allocator,
) Error!Var {
    var memo: TermMemo = .{};
    defer memo.deinit(scratch);
    return instantiateWith(iface, type_ids, store, scheme_index, rank, scratch, &memo, scratch);
}

/// `instantiate` with the caller's memo, allocated with `gpa` (R14b).
pub fn instantiateWith(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    scheme_index: u32,
    rank: u32,
    scratch: Allocator,
    memo: *TermMemo,
    gpa: Allocator,
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
    try memo.begin(gpa, iface.terms.len);
    var reader: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .fresh = fresh, .memo = memo };
    const body = try reader.read(s.body);
    // The constraint blocks LAST, so every quantifier already has its
    // variable and a `var(i)` inside a constraint's type lands on the same
    // one the body uses (static-dispatch-spike.md §6.5 rule 3). Each
    // quantifier gets a FRESH set; the evidence index runs across
    // quantifiers in canonical order (§7.2).
    for (fresh, 0..) |v, i| {
        const q = iface.quantified(s, @intCast(i));
        if (q.constraints_len == 0) continue;
        const built = try scratch.alloc(TypeStore.MethodConstraint, q.constraints_len);
        defer scratch.free(built);
        for (built, 0..) |*c, j| {
            const qc = iface.quantifiedConstraint(q, @intCast(j));
            c.* = .{
                .name = iface.symbol(qc.name),
                .fn_var = try reader.read(qc.type),
                .region = @enumFromInt(0),
                .origin = .where_clause,
            };
        }
        const set = try store.addConstraints(built);
        const flags = store.flagsOf(store.find(v));
        store.setContent(store.find(v), .{ .flex = .{
            .name = flags.name,
            .kind = flags.kind,
            .equatable = flags.equatable,
            .constraints = set.toOptional(),
        } });
    }
    return body;
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
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    ctor_index: u32,
    type_id: TypeStore.TypeId,
    rank: u32,
    scratch: Allocator,
) Error!?Var {
    var memo: TermMemo = .{};
    defer memo.deinit(scratch);
    return instantiateCtorWith(iface, type_ids, store, ctor_index, type_id, rank, scratch, &memo, scratch);
}

/// `instantiateCtor` with the caller's memo, allocated with `gpa` (R14b).
pub fn instantiateCtorWith(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    ctor_index: u32,
    type_id: TypeStore.TypeId,
    rank: u32,
    scratch: Allocator,
    memo: *TermMemo,
    gpa: Allocator,
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
    try memo.begin(gpa, iface.terms.len);
    var reader: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .fresh = fresh, .memo = memo };

    const words = iface.range(c.arg_terms);
    const args = try scratch.alloc(Var, words.len);
    defer scratch.free(args);
    for (words, args) |word, *v| v.* = try reader.read(@enumFromInt(word));

    // The result: the owning type applied to its own parameters — or, for
    // a record alias's constructor (interface v3, CK-39), the alias of the
    // RECORD its fields make, argument `i` being field `i` of the row's
    // declaration-order names. That is exactly what the declaring module's
    // own check builds for it (`Types.Builder.apply` on the alias), so a
    // field access or an update on `P 1 "a"` types the same on both sides
    // of the import.
    const params = try store.addVars(fresh);
    const result = switch (c.result) {
        .nominal => try store.fresh(.{ .structure = .{ .app = .{ .type = type_id, .args = params } } }, rank),
        .record_alias => blk: {
            const names = iface.range(c.fields);
            // A row whose names do not match its arguments is a record the
            // writer never produces; poison rather than guess.
            if (names.len != args.len) return null;
            const fields = try scratch.alloc(TypeStore.Field, args.len);
            defer scratch.free(fields);
            for (fields, names, args) |*f, name, arg| {
                if (name >= iface.symbols.len) return null;
                f.* = .{ .name = iface.symbol(@enumFromInt(name)), .value = arg };
            }
            const field_range = try store.addFields(fields);
            const closed = try store.fresh(.{ .structure = .empty_record }, rank);
            const record = try store.fresh(.{ .structure = .{ .record = .{ .fields = field_range, .ext = closed } } }, rank);
            break :blk try store.fresh(.{ .alias = .{ .type = type_id, .args = params, .actual = record } }, rank);
        },
    };
    // A constructor of n fields is an n-ARY function, not a chain of n
    // one-argument ones (language.md §6.7), and a nullary one is the type
    // itself.
    if (args.len == 0) return result;
    const arg_range = try store.addVars(args);
    return try store.fresh(.{ .structure = .{ .func = .{ .params = arg_range, .result = result } } }, rank);
}

const Reader = struct {
    iface: *const Interface,
    /// `iface.type_refs` translated into this session — see `instantiate`.
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    rank: u32,
    scratch: Allocator,
    fresh: []const Var,
    memo: *TermMemo,
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
        if (r.memo.get(index.int())) |v| return v;

        const t = r.iface.term(index);
        const v = switch (t.tag) {
            .err => try r.store.freshErr(r.rank),
            .@"var" => if (t.lhs < r.fresh.len) r.fresh[t.lhs] else try r.store.freshErr(r.rank),
            .unit => try r.store.fresh(.{ .structure = .unit }, r.rank),
            .empty_record => try r.store.fresh(.{ .structure = .empty_record }, r.rank),
            .func => blk: {
                const params = try r.readRange(t.lhs);
                defer r.scratch.free(params);
                const range = try r.store.addVars(params);
                const result = try r.read(@enumFromInt(t.rhs));
                break :blk try r.store.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } }, r.rank);
            },
            .app => blk: {
                const args = try r.readRange(t.rhs);
                defer r.scratch.free(args);
                const range = try r.store.addVars(args);
                break :blk try r.store.fresh(.{ .structure = .{ .app = .{ .type = r.typeId(t.lhs), .args = range } } }, r.rank);
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
                break :blk try r.store.fresh(.{ .alias = .{ .type = r.typeId(t.lhs), .args = range, .actual = actual } }, r.rank);
            },
        };
        r.memo.put(index.int(), v);
        return v;
    }

    /// The session `TypeId` an `app` or `alias` operand names. One array
    /// index — the whole point of `Types.ref_ids`. A reference the session
    /// could not resolve, and an operand a record mapped from disk does not
    /// describe, both give `.none`, which is the poisoned id this operand
    /// carried directly before the reference existed.
    fn typeId(r: *const Reader, operand: u32) TypeStore.TypeId {
        return if (operand < r.type_ids.len) r.type_ids[operand] else .none;
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

/// A session type table for the tests that fabricate a solved type by hand:
/// one module `M` of package `core` declaring `names` in order, so `TypeId`
/// `i` is `names[i]`.
///
/// It exists because the interface no longer stores a session `TypeId`. A
/// term names a type by `(package, declaring module, type name)`
/// (`Interface.TypeRef`), so the writer has to be told what an id MEANS —
/// which is the whole point of the change, and a test that could not say it
/// would be testing a record no build produces.
fn testTypes(entries: []Types.Entry, module: Symbol, names: []const Symbol) Types {
    for (entries, names) |*e, n| e.* = .{
        .module = @enumFromInt(0),
        .decl = @enumFromInt(0),
        .name = n,
        .package = .core,
        .module_name = module,
        .arity = 0,
        .kind = .adt,
        .equatable = true,
        .comparable = true,
        .has_function = false,
    };
    var types: Types = .empty;
    types.entries = entries;
    return types;
}

/// `iface.type_refs` translated back into ids, the way `Types.resolveRefs`
/// does it against a real graph: by name, against the declaring module's
/// declarations. The reader indexes this.
fn testTypeIds(gpa: Allocator, iface: *const Interface, types: *const Types) Allocator.Error![]TypeStore.TypeId {
    const out = try gpa.alloc(TypeStore.TypeId, iface.type_refs.len);
    errdefer gpa.free(out);
    for (iface.type_refs, out) |ref, *slot| {
        slot.* = .none;
        for (types.entries, 0..) |e, i| {
            if (e.name == iface.symbol(ref.name) and e.module_name == iface.symbol(ref.module)) {
                slot.* = @enumFromInt(i);
                break;
            }
        }
    }
    return out;
}

test "a scheme round trips through terms with its sharing intact" {
    const gpa = testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();

    // `a -> a`: one generalised variable, used twice.
    const a = try store.fresh(.{ .flex = .{ .kind = .number } }, TypeStore.generalized);
    const one = try store.addVars(&.{a});
    const body = try store.fresh(.{ .structure = .{ .func = .{ .params = one, .result = a } } }, TypeStore.generalized);

    const no_types: Types = .empty;
    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &store, &interner, &no_types, 0);
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
    const first = try instantiate(&iface, &.{}, &target, 0, 1, arena.allocator());
    const second = try instantiate(&iface, &.{}, &target, 0, 1, arena.allocator());
    const f1 = target.content(target.find(first)).structure.func;
    const f2 = target.content(target.find(second)).structure.func;
    const p1 = target.vars(f1.params)[0];
    const p2 = target.vars(f2.params)[0];
    try testing.expectEqual(target.find(p1), target.find(f1.result));
    try testing.expect(target.find(p1) != target.find(p2));
    // The kind crossed with it: a `number` stays a `number`.
    try testing.expectEqual(TypeStore.Kind.number, target.content(target.find(p1)).flex.kind);
}

test "a method constraint round trips through the interface onto a fresh variable" {
    // static-dispatch-spike.md §6.5: a quantifier's `where` block is two
    // words per constraint in `extra`, sorted by name TEXT, and `var(i)`
    // inside a constraint's term means quantifier `i` of the SAME scheme —
    // so a dependent rebuilds the constraint from this record alone.
    const gpa = testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();

    // `a, Int -> a where a.eq : a, a -> Bool, a.compare : a, a -> Order`,
    // the two constraints DECLARED in the wrong order on purpose: the
    // record must come back sorted by name text, `compare` before `eq`.
    const module_name = try interner.getOrPut(gpa, "M");
    var entries: [3]Types.Entry = undefined;
    const types = testTypes(&entries, module_name, &.{
        try interner.getOrPut(gpa, "Int"),
        try interner.getOrPut(gpa, "Bool"),
        try interner.getOrPut(gpa, "Order"),
    });
    const int: TypeStore.TypeId = @enumFromInt(0);
    const bool_id: TypeStore.TypeId = @enumFromInt(1);
    const order_id: TypeStore.TypeId = @enumFromInt(2);
    const a = try store.fresh(.{ .flex = .{} }, TypeStore.generalized);
    const int_var = try store.fresh(.{ .structure = .{ .app = .{ .type = int, .args = .empty } } }, TypeStore.generalized);
    const bool_var = try store.fresh(.{ .structure = .{ .app = .{ .type = bool_id, .args = .empty } } }, TypeStore.generalized);
    const order_var = try store.fresh(.{ .structure = .{ .app = .{ .type = order_id, .args = .empty } } }, TypeStore.generalized);
    const pair = try store.addVars(&.{ a, a });
    const eq_fn = try store.fresh(.{ .structure = .{ .func = .{ .params = pair, .result = bool_var } } }, TypeStore.generalized);
    const compare_fn = try store.fresh(.{ .structure = .{ .func = .{ .params = pair, .result = order_var } } }, TypeStore.generalized);
    const eq_name = try interner.getOrPut(gpa, "eq");
    const compare_name = try interner.getOrPut(gpa, "compare");
    const set = try store.addConstraints(&.{
        .{ .name = eq_name, .fn_var = eq_fn, .region = @enumFromInt(0), .origin = .where_clause },
        .{ .name = compare_name, .fn_var = compare_fn, .region = @enumFromInt(0), .origin = .where_clause },
    });
    store.setContent(a, .{ .flex = .{ .constraints = set.toOptional() } });
    const params = try store.addVars(&.{ a, int_var });
    const body = try store.fresh(.{ .structure = .{ .func = .{ .params = params, .result = a } } }, TypeStore.generalized);

    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &store, &interner, &types, 0);
    defer w.deinit();
    _ = try w.add(body);
    try w.attach(&iface);
    const type_ids = try testTypeIds(gpa, &iface, &types);
    defer gpa.free(type_ids);

    const scheme = iface.schemes[0];
    try testing.expectEqual(@as(u32, 1), scheme.quantified_count);
    const q = iface.quantified(scheme, 0);
    try testing.expectEqual(@as(u32, 2), q.constraints_len);
    // Sorted by name text, whatever order they were declared in.
    try testing.expectEqualStrings("compare", interner.slice(iface.symbol(iface.quantifiedConstraint(q, 0).name)));
    try testing.expectEqualStrings("eq", interner.slice(iface.symbol(iface.quantifiedConstraint(q, 1).name)));

    // Reading it back gives ONE fresh variable carrying a FRESH set whose
    // method types are about that same variable — the sharing `var(i)`
    // encodes.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var target: TypeStore = .init(gpa);
    defer target.deinit();
    const copy = try instantiate(&iface, type_ids, &target, 0, 1, arena.allocator());
    const func = target.content(target.find(copy)).structure.func;
    const fresh_a = target.find(target.vars(func.params)[0]);
    try testing.expectEqual(fresh_a, target.find(func.result));
    const read = target.flagsOf(fresh_a).constraints;
    try testing.expectEqual(@as(u32, 2), target.constraintCount(read));
    const read_compare = target.findConstraint(read, compare_name).?;
    const read_eq = target.findConstraint(read, eq_name).?;
    // `a, a -> Order` and `a, a -> Bool`, both about the instantiated `a`.
    const compare_shape = target.content(target.find(read_compare.fn_var)).structure.func;
    try testing.expectEqual(fresh_a, target.find(target.vars(compare_shape.params)[0]));
    try testing.expectEqual(order_id, target.resolvedContent(compare_shape.result).structure.app.type);
    const eq_shape = target.content(target.find(read_eq.fn_var)).structure.func;
    try testing.expectEqual(fresh_a, target.find(target.vars(eq_shape.params)[1]));
    try testing.expectEqual(bool_id, target.resolvedContent(eq_shape.result).structure.app.type);

    // A second instantiation is independent: two call sites of a
    // constrained value do not share a method type.
    const again = try instantiate(&iface, type_ids, &target, 0, 1, arena.allocator());
    const second = target.content(target.find(again)).structure.func;
    const other_a = target.find(target.vars(second.params)[0]);
    try testing.expect(other_a != fresh_a);
    try testing.expect(target.findConstraint(target.flagsOf(other_a).constraints, eq_name).?.fn_var != read_eq.fn_var);
}

test "quantifier order matches the writer, records and constraints included" {
    // static-dispatch-spike.md §7.2, A.24: caller and callee compute the
    // canonical evidence order independently — the callee from its own
    // store with `quantifierOrder`, the caller from the interface record's
    // quantifier list — so the two walks must agree exactly. The case that
    // could plausibly drift is a RECORD, whose fields the writer sorts by
    // name TEXT before descending, so `{ b : x, a : y } -> x` discovers `y`
    // before `x`.
    const gpa = testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();

    const x = try store.fresh(.{ .flex = .{} }, TypeStore.generalized);
    const y = try store.fresh(.{ .flex = .{} }, TypeStore.generalized);
    const b_name = try interner.getOrPut(gpa, "b");
    const a_name = try interner.getOrPut(gpa, "a");
    var fields = [_]TypeStore.Field{
        .{ .name = b_name, .value = x },
        .{ .name = a_name, .value = y },
    };
    const range = try store.addFields(&fields);
    const closed = try store.fresh(.{ .structure = .empty_record }, TypeStore.generalized);
    const record = try store.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = closed } } }, TypeStore.generalized);
    const params = try store.addVars(&.{record});
    const body = try store.fresh(.{ .structure = .{ .func = .{ .params = params, .result = x } } }, TypeStore.generalized);

    var order: std.ArrayList(Var) = .empty;
    defer order.deinit(gpa);
    try quantifierOrder(&store, &interner, body, &order, gpa);
    try testing.expectEqualSlices(Var, &.{ y, x }, order.items);

    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    const no_types: Types = .empty;
    var w: Writer = .init(gpa, &store, &interner, &no_types, 0);
    defer w.deinit();
    _ = try w.add(body);
    try w.attach(&iface);
    // The writer numbered them the same way: field `a`'s variable is
    // quantifier 0 and field `b`'s is quantifier 1, so a caller reading the
    // record lays the evidence out in the order the callee expects.
    const scheme = iface.schemes[0];
    try testing.expectEqual(@as(u32, 2), scheme.quantified_count);
    const record_term = iface.term(@enumFromInt(iface.term(scheme.body).rhs));
    _ = record_term;
    const func_term = iface.term(scheme.body);
    const param_words = iface.range(func_term.lhs);
    const rec = iface.term(@enumFromInt(param_words[0]));
    const pairs = iface.range(rec.lhs);
    try testing.expectEqualStrings("a", interner.slice(iface.symbol(@enumFromInt(pairs[0]))));
    try testing.expectEqual(@as(u32, 0), iface.term(@enumFromInt(pairs[1])).lhs);
    try testing.expectEqualStrings("b", interner.slice(iface.symbol(@enumFromInt(pairs[2]))));
    try testing.expectEqual(@as(u32, 1), iface.term(@enumFromInt(pairs[3])).lhs);
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
    /// What an `app` may name, `.none` included. Real ids rather than
    /// always-`none`, so the round trip exercises the `type_refs` table
    /// that `app` and `alias` now index (`Interface.TypeRef`).
    type_ids: []const TypeStore.TypeId,

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
                const n = 1 + g.random.uintLessThan(usize, 3);
                const ps = try g.gpa.alloc(Var, n);
                defer g.gpa.free(ps);
                for (ps) |*x| x.* = try g.make(depth + 1);
                const range = try g.store.addVars(ps);
                const result = try g.make(depth + 1);
                return g.store.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } }, rank);
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
                const id = g.type_ids[g.random.uintLessThan(usize, g.type_ids.len)];
                return g.store.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } }, rank);
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
            .func => |f| {
                const ps = store.vars(f.params);
                if (n < ps.len) return ps[n];
                return if (n == ps.len) f.result else null;
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

    // Three named types and the poisoned id, so the walk writes `type_refs`
    // rows and the reader has to translate them back. `renderOf` prints an
    // `app`'s type by NAME, so a reference that came back as a different
    // type — or as `.none` — shows up in the rendered text.
    var entries: [3]Types.Entry = undefined;
    const types = testTypes(&entries, try interner.getOrPut(gpa, "M"), &.{ names[0], names[1], names[2] });
    const ids = [_]TypeStore.TypeId{ @enumFromInt(0), @enumFromInt(1), @enumFromInt(2), .none };

    var prng: std.Random.DefaultPrng = .init(seed);
    var source: TypeStore = .init(gpa);
    defer source.deinit();
    var g: RandomType = .{ .gpa = gpa, .store = &source, .random = prng.random(), .names = &names, .type_ids = &ids };
    defer g.deinit();
    const root = try g.make(0);

    var iface: Interface = .empty;
    defer iface.deinit(gpa);
    var w: Writer = .init(gpa, &source, &interner, &types, 0);
    defer w.deinit();
    const index = try w.add(root);
    try testing.expect(!w.too_deep);
    try w.attach(&iface);
    const type_ids = try testTypeIds(gpa, &iface, &types);
    defer gpa.free(type_ids);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var target: TypeStore = .init(gpa);
    defer target.deinit();
    const copy = try instantiate(&iface, type_ids, &target, @intFromEnum(index), TypeStore.generalized, arena.allocator());

    // The record must not have smuggled an error term into a type that had
    // none: `err` unifies with anything, so one hiding inside a published
    // scheme is a hole in every dependent.
    for (iface.terms.items(.tag)) |tag| try testing.expect(tag != .err);

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
    const no_types: Types = .empty;
    var w: Writer = .init(gpa, &store, &interner, &no_types, 0);
    defer w.deinit();
    _ = try w.addError();
    try w.attach(&iface);
    try testing.expectEqual(@as(usize, 1), iface.schemes.len);
    try testing.expectEqual(Interface.Term.Tag.err, iface.term(iface.schemes[0].body).tag);
}
