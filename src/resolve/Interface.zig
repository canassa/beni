//! A module's public face (docs/design/checker.md §7): the flat,
//! index-based record every dependent is checked against, built once from
//! the module's Bir and immutable from then on.
//!
//! **Why it exists at all** is `fast-compiler.md` §8.1: recompiling a
//! module must not recompile its dependents unless this record changed.
//! That is why it is a value — three sorted tables and a symbol column, no
//! pointers, no slices into the Bir — rather than a view onto the module:
//! M2 compares it by value, M4 hashes it and maps it from disk unchanged.
//!
//! M2a built the SKELETON: which names are public, what kind each is, how
//! many arguments each constructor takes, which types are opaque, foreign
//! or equatable — everything cross-module NAME resolution needs, and a
//! lexical fact needing no inference. M2b adds the TYPES: `schemes` and
//! `terms` (checker.md §7), filled from the solved store once a module is
//! checked, and the `scheme` slot each value already carried. The tables
//! are a flat term language rather than store variables because a store is
//! per module and dies with it, while an interface outlives every store and
//! in M4 is mapped from disk.
//!
//! `check/Schemes.zig` is the only thing that writes or reads them: it
//! turns a solved `Var` into terms and instantiates terms back into another
//! module's store. Nothing in `resolve/` depends on the checker.
//!
//! **Order is by name text, not by symbol.** A `Symbol` is an index into a
//! pool whose numbering depends on which worker interned which file first
//! (`InternPool`'s header), so sorting by id would make the record — and
//! in M4 its hash — depend on `--jobs`. Sorting by the bytes makes the
//! table, the dump and the future hash a function of the source alone, and
//! a lookup is a binary search over short strings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Bir = @import("../bir/Bir.zig");

const Interface = @This();

pub const Symbol = InternPool.Symbol;

/// Owned. The `pub` values, sorted by name.
values: []const Value,
/// Owned. The `pub` types and aliases, sorted by name.
types: []const Type,
/// Owned. Every visible constructor, grouped by owning type
/// (`Type.ctors_start..ctors_end`) and in declaration order within a type.
ctors: []const Ctor,
/// Owned. Generalised types, one per value that has one (checker.md §7).
schemes: []const Scheme,
/// Owned. The flat type term language every scheme's body is written in.
terms: std.MultiArrayList(Term).Slice,
/// Owned. Ranges and record fields the terms point at.
extra: []const u32,
/// Owned. The one symbol column; every name above is an index into it,
/// exactly as `Bir` does it, so a remap is one loop and M4 can map the
/// whole record without a fixup pass.
symbols: []const Symbol,

/// Index into `values`.
pub const ValueIndex = enum(u32) { _ };
/// Index into `types`.
pub const TypeIndex = enum(u32) { _ };
/// Index into `ctors`.
pub const CtorIndex = enum(u32) { _ };

/// Index into `schemes`, which M2b adds. Every value carries one now so
/// the record's layout does not change when it arrives.
pub const SchemeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

/// Index into `symbols`.
pub const SymbolIndex = enum(u32) {
    _,

    pub fn toOptional(i: SymbolIndex) Optional {
        return @enumFromInt(@intFromEnum(i));
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?SymbolIndex {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };
};

/// Index into `terms`.
pub const TermIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn int(t: TermIndex) u32 {
        return @intFromEnum(t);
    }
};

/// A generalised type: how many variables it quantifies and its body. The
/// quantified list lives in `extra` as TWO words each — see `Quantified` —
/// rather than in a table of its own, so §7's table list stays exactly
/// `values, types, ctors, schemes, terms, extra, symbols`.
pub const Scheme = struct {
    /// `extra[quantified_start..][0 .. 2 * quantified_count]`.
    quantified_start: u32,
    quantified_count: u32,
    body: TermIndex,
};

/// One quantified variable: its ad-hoc constraint (the closed set of
/// `fast-compiler.md` §3.1 and nothing else) and the name the annotation
/// gave it, so `dump --stage=interface` prints `a -> a` and not `a -> b`.
pub const Quantified = struct {
    /// `@intFromEnum` of a `TypeStore.Kind`.
    kind: u8,
    equatable: bool,
    /// Index into this interface's own `symbols` column, NOT a `Symbol`.
    ///
    /// A `Symbol` is an index into the session's interner, whose numbering
    /// depends on which worker interned which file (`InternPool`'s header)
    /// — so a `Symbol` written straight into `extra` would put a
    /// scheduling-dependent word into the bytes `fast-compiler.md` §8.1 has
    /// M4 hashing, and the hash of an unchanged module would move with
    /// `--jobs`. Every other name in this record is a `SymbolIndex` for
    /// exactly that reason; this one was the exception.
    name: SymbolIndex.Optional,
    /// The method constraints this variable carries
    /// (static-dispatch-spike.md §6.5): `constraints_len` CONSTRAINTS —
    /// not words — at `extra[constraints_start..][0 .. 2 * constraints_len]`,
    /// each a `(SymbolIndex, TermIndex)` pair.
    ///
    /// **Sorted by name TEXT**, never by symbol id, for the reason the
    /// header gives for every other order in this record: a `Symbol` is an
    /// index into the session interner and its numbering depends on which
    /// worker interned which file, and these bytes are what
    /// `fast-compiler.md` §8.1 has M4 hashing.
    ///
    /// `var(i)` inside a constraint's term means quantifier `i` of the SAME
    /// scheme, exactly as it does in the body, so a dependent rebuilds the
    /// constraint from this record alone.
    constraints_start: u32 = 0,
    constraints_len: u32 = 0,

    pub const words = 4;

    pub fn flags(q: Quantified) u32 {
        return @as(u32, q.kind) | (@as(u32, @intFromBool(q.equatable)) << 8);
    }

    pub fn unpack(flag_word: u32, name_word: u32, start: u32, len: u32) Quantified {
        return .{
            .kind = @truncate(flag_word),
            .equatable = (flag_word >> 8) & 1 == 1,
            .name = @enumFromInt(name_word),
            .constraints_start = start,
            .constraints_len = len,
        };
    }
};

/// One `(method name, type)` pair of a quantifier's constraint block.
pub const QuantifiedConstraint = struct {
    name: SymbolIndex,
    type: TermIndex,
};

/// The flat type term language of checker.md §7. `lhs` and `rhs` mean what
/// each tag's comment says; ranges live in `extra` as a length followed by
/// that many words, so a term is three fixed-size columns and nothing else.
pub const Term = struct {
    tag: Tag,
    lhs: u32,
    rhs: u32,

    pub const Tag = enum(u8) {
        /// `lhs` is the index into the scheme's quantified list.
        @"var",
        /// `lhs` is an `extra` range of parameter terms, `rhs` the result
        /// term. A function type is n-ary (language.md §6.7), so the
        /// parameters need a range of their own the way `app`'s arguments
        /// do — both operand words were already spoken for.
        func,
        /// `lhs` is a `TypeStore.TypeId`; `rhs` an `extra` range of terms.
        app,
        /// `lhs` is an `extra` range of terms.
        tuple,
        /// `lhs` is an `extra` range of `(SymbolIndex, TermIndex)` pairs;
        /// `rhs` is the extension term.
        record,
        /// `()`.
        unit,
        /// The closed end of a record.
        empty_record,
        /// `lhs` is a `TypeStore.TypeId`; `rhs` an `extra` range whose last
        /// word is the expansion and whose earlier words are the arguments.
        alias,
        /// A declaration that failed to check (checker.md §7).
        err,
    };
};

pub const Value = struct {
    name: SymbolIndex,
    /// `foreign name : Type` (language.md §5.4). The backend keys its
    /// JavaScript binding on the module-qualified name, so the interface
    /// has to say which names are bound that way.
    is_foreign: bool,
    /// The inferred or annotated scheme. `none` for the whole of M2a.
    scheme: SchemeIndex,
};

pub const TypeKind = enum(u8) {
    /// `type T = A | B`.
    adt,
    /// `type alias T = …`.
    alias,
    /// `foreign type T` (language.md §5.4): no constructors, ever.
    foreign,
};

pub const Type = struct {
    name: SymbolIndex,
    /// Type parameters. Types are always fully applied (checker.md
    /// Appendix A), so this is exactly how many arguments a use must have.
    arity: u8,
    kind: TypeKind,
    /// `pub opaque type T`: the name is exported, the constructors are
    /// not, and `ctors_start == ctors_end` here as a result.
    is_opaque: bool,
    /// `equatable foreign type T` (checker.md Appendix B): values of this
    /// type may be compared with `==`. Only ever set on a `foreign` type;
    /// for an `adt` or `alias` the answer follows from its fields and is
    /// M2b's to compute.
    is_equatable: bool,
    ctors_start: u32,
    ctors_end: u32,

    pub fn ctorRange(t: Type) struct { u32, u32 } {
        return .{ t.ctors_start, t.ctors_end };
    }
};

pub const Ctor = struct {
    name: SymbolIndex,
    /// The type that declares it.
    type: TypeIndex,
    /// How many arguments it takes. Also the length of `arg_terms`.
    arity: u32,
    /// The argument types in declaration order: an `extra` range of
    /// `TermIndex` words, exactly the `arg_terms: range` of checker.md §7.
    /// A `var(i)` inside them is the OWNING TYPE's parameter `i`, so a
    /// constructor needs no body term of its own — its type is
    /// `arg1 -> … -> argN -> T p0 … pk` and the result half is determined
    /// by `type`.
    ///
    /// This is what lets a dependent instantiate an imported constructor
    /// from the interface ALONE. Without it the solver had to open the
    /// declaring module's `Bir` and find the constructor by NAME, which
    /// breaks checker.md §4.5 ("the checker never looks a name up again")
    /// and the firewall of `fast-compiler.md` §8.1 — in M4 a dependency's
    /// Bir may not be in memory at all, only this record.
    ///
    /// `no_terms` until the declaring module has been checked: M2a builds
    /// the skeleton before any inference has run, and a module that failed
    /// to lower never gets further.
    arg_terms: u32 = no_terms,
    /// The owning type's parameters as quantifiers, laid out in `extra`
    /// exactly as a `Scheme`'s are — `Quantified.words` words each, in
    /// declaration order, `types[type].arity` of them. Meaningless while
    /// `arg_terms` is `no_terms`.
    quantified_start: u32 = 0,
};

/// A `Ctor.arg_terms` that has not been written: the module was never
/// checked, or never lowered.
pub const no_terms: u32 = std.math.maxInt(u32);

/// Where each entry of an interface came from in its module's `Bir`.
///
/// **Not part of the interface**, and deliberately a separate value: it is
/// meaningless once the Bir is gone, so it must never be hashed, compared
/// or written to disk (`fast-compiler.md` §8.1). It exists because the two
/// places that have to go interface entry → declaration — `check/Types`'s
/// `by_interface` and `check/Check`'s `fillInterface` — were scanning the
/// declaration table for a matching NAME, which is the lookup §4.5 forbids
/// and is quadratic in the module's public surface: 32 000 `pub`
/// declarations took 12.8 s in that loop against 73 ms without `pub`.
///
/// Built in the one walk that already knows the answer, `Interface.build`.
pub const Provenance = struct {
    /// Owned. `values[i]` was declared by `value_decl[i]`.
    value_decl: []const Bir.DeclIndex,
    /// Owned. `types[i]` was declared by `type_decl[i]`.
    type_decl: []const Bir.DeclIndex,
    /// Owned. `ctors[i]` is `bir.ctors[ctor_index[i]]`.
    ctor_index: []const u32,

    pub const empty: Provenance = .{ .value_decl = &.{}, .type_decl = &.{}, .ctor_index = &.{} };

    pub fn deinit(p: *Provenance, gpa: Allocator) void {
        gpa.free(p.value_decl);
        gpa.free(p.type_decl);
        gpa.free(p.ctor_index);
        p.* = Provenance.empty;
    }

    /// The declaration behind value `i`, or null when this provenance does
    /// not describe that interface — a module that failed to lower has an
    /// empty one, and a caller must not index past it.
    pub fn valueDecl(p: *const Provenance, i: usize) ?Bir.DeclIndex {
        return if (i < p.value_decl.len) p.value_decl[i] else null;
    }

    pub fn typeDecl(p: *const Provenance, i: usize) ?Bir.DeclIndex {
        return if (i < p.type_decl.len) p.type_decl[i] else null;
    }

    pub fn ctorIndex(p: *const Provenance, i: usize) ?u32 {
        return if (i < p.ctor_index.len) p.ctor_index[i] else null;
    }
};

/// A module with nothing public, and what a module that failed to lower
/// contributes to its dependents.
pub const empty: Interface = .{
    .values = &.{},
    .types = &.{},
    .ctors = &.{},
    .schemes = &.{},
    .terms = .empty,
    .extra = &.{},
    .symbols = &.{},
};

pub fn deinit(iface: *Interface, gpa: Allocator) void {
    gpa.free(iface.values);
    gpa.free(iface.types);
    gpa.free(iface.ctors);
    gpa.free(iface.schemes);
    iface.terms.deinit(gpa);
    gpa.free(iface.extra);
    gpa.free(iface.symbols);
    iface.* = undefined;
}

/// `extra[start..][0..len]`, the shape every range in `terms` uses. A
/// malformed header yields an empty range instead of trapping: M4 maps this
/// record from disk, and a record that does not describe itself must not be
/// able to crash the compiler.
pub fn range(iface: *const Interface, start: u32) []const u32 {
    if (start >= iface.extra.len) return &.{};
    const len = iface.extra[start];
    const rest = iface.extra[start + 1 ..];
    if (len > rest.len) return &.{};
    return rest[0..len];
}

pub fn term(iface: *const Interface, index: TermIndex) Term {
    return iface.terms.get(index.int());
}

pub fn scheme(iface: *const Interface, index: SchemeIndex) Scheme {
    return iface.schemes[@intFromEnum(index)];
}

/// The interner symbol a quantifier's name index points at, or none.
pub fn quantifiedSymbol(iface: *const Interface, q: Quantified) Symbol.Optional {
    const index = q.name.unwrap() orelse return .none;
    if (@intFromEnum(index) >= iface.symbols.len) return .none;
    return iface.symbol(index).toOptional();
}

/// The `i`th quantified variable of `s`.
pub fn quantified(iface: *const Interface, s: Scheme, i: u32) Quantified {
    const at = s.quantified_start + i * Quantified.words;
    if (at + Quantified.words > iface.extra.len) return .{ .kind = 0, .equatable = false, .name = .none };
    return Quantified.unpack(iface.extra[at], iface.extra[at + 1], iface.extra[at + 2], iface.extra[at + 3]);
}

/// The `j`th constraint of quantifier `q`. Out of range yields a constraint
/// with no type, so a record mapped from disk that does not describe itself
/// cannot trap.
pub fn quantifiedConstraint(iface: *const Interface, q: Quantified, j: u32) QuantifiedConstraint {
    const at = q.constraints_start + j * 2;
    if (at + 1 >= iface.extra.len) return .{ .name = @enumFromInt(0), .type = .none };
    return .{ .name = @enumFromInt(iface.extra[at]), .type = @enumFromInt(iface.extra[at + 1]) };
}

/// The `i`th parameter of the type that declares `c`, as a quantifier.
/// Laid out exactly like a `Scheme`'s quantified list — see
/// `Ctor.quantified_start`. An out-of-range read yields a plain `a`, so a
/// record M4 mapped from disk that does not describe itself cannot trap.
pub fn ctorQuantified(iface: *const Interface, c: Ctor, i: u32) Quantified {
    const at = c.quantified_start + i * Quantified.words;
    if (at + Quantified.words > iface.extra.len) return .{ .kind = 0, .equatable = false, .name = .none };
    return Quantified.unpack(iface.extra[at], iface.extra[at + 1], iface.extra[at + 2], iface.extra[at + 3]);
}

/// The scheme of `value`, or null when it has none — a declaration that
/// failed to check, or a module that was never checked.
pub fn valueScheme(iface: *const Interface, value: ValueIndex) ?Scheme {
    const s = iface.values[@intFromEnum(value)].scheme;
    if (s == .none) return null;
    return iface.scheme(s);
}

pub fn symbol(iface: *const Interface, index: SymbolIndex) Symbol {
    return iface.symbols[@intFromEnum(index)];
}

pub fn valueName(iface: *const Interface, index: ValueIndex) Symbol {
    return iface.symbol(iface.values[@intFromEnum(index)].name);
}

pub fn typeName(iface: *const Interface, index: TypeIndex) Symbol {
    return iface.symbol(iface.types[@intFromEnum(index)].name);
}

pub fn ctorName(iface: *const Interface, index: CtorIndex) Symbol {
    return iface.symbol(iface.ctors[@intFromEnum(index)].name);
}

/// The `pub` value named `name`, or null. `interner` is the pool `name`
/// and the record's symbols both come from.
pub fn findValue(iface: *const Interface, interner: *const InternPool.Global, name: Symbol) ?ValueIndex {
    const i = find(iface, interner, Value, iface.values, name) orelse return null;
    return @enumFromInt(i);
}

pub fn findType(iface: *const Interface, interner: *const InternPool.Global, name: Symbol) ?TypeIndex {
    const i = find(iface, interner, Type, iface.types, name) orelse return null;
    return @enumFromInt(i);
}

/// The visible constructor named `name`, or null. Constructors are grouped
/// by their TYPE rather than sorted by name — a type's constructors have to
/// stay adjacent and in declaration order for the exhaustiveness check of
/// checker.md §6.6 — so this is a scan over a handful of entries rather
/// than a binary search. It takes the interner it does not need so the
/// three `find*` functions are interchangeable at a call site.
pub fn findCtor(iface: *const Interface, _: *const InternPool.Global, name: Symbol) ?CtorIndex {
    for (iface.ctors, 0..) |c, i| {
        if (iface.symbol(c.name) == name) return @enumFromInt(i);
    }
    return null;
}

fn find(iface: *const Interface, interner: *const InternPool.Global, comptime T: type, entries: []const T, name: Symbol) ?u32 {
    const target = interner.slice(name);
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, interner.slice(iface.symbol(entries[mid].name)), target)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @intCast(mid),
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

/// An interface and the `Bir` indices each of its entries came from. The
/// two are built in one walk because only this walk knows the answer; see
/// `Provenance` for why they are separate values afterwards.
pub const Built = struct {
    iface: Interface,
    provenance: Provenance,
};

/// Build the interface of a lowered module. Only `bir.interface` — the
/// `pub` declarations lowering already picked out — is read, so this is
/// linear in the module's public surface and not in its size.
pub fn build(gpa: Allocator, bir: *const Bir, interner: *const InternPool.Global) Allocator.Error!Built {
    var b: Builder = .{ .gpa = gpa, .bir = bir, .interner = interner };
    errdefer b.deinit();

    // Two passes over the `pub` declarations: values and types are sorted
    // independently, and a constructor's `type` field is an index into the
    // sorted type table, so the types must be placed first.
    var value_decls: std.ArrayList(Bir.DeclIndex) = .empty;
    errdefer value_decls.deinit(gpa);
    for (bir.interface) |di| {
        const d = bir.decl(di);
        if (!d.kind.isValue()) continue;
        try value_decls.append(gpa, di);
        try b.values.append(gpa, .{
            .name = try b.symbolIndex(bir.symbol(d.name)),
            .is_foreign = d.kind == .foreign_value,
            .scheme = .none,
        });
    }
    try b.sortByName(Value, b.values.items, value_decls.items);

    // Types in declaration order first, then sorted; a constructor's
    // owning index is patched afterwards, because sorting moves the types.
    var type_decls: std.ArrayList(Bir.DeclIndex) = .empty;
    errdefer type_decls.deinit(gpa);
    for (bir.interface) |di| {
        const d = bir.decl(di);
        if (d.kind.isValue()) continue;
        try type_decls.append(gpa, di);
        try b.types.append(gpa, .{
            .name = try b.symbolIndex(bir.symbol(d.name)),
            .arity = std.math.cast(u8, d.params) orelse std.math.maxInt(u8),
            .kind = switch (d.kind) {
                .type => .adt,
                .type_alias => .alias,
                .foreign_type => .foreign,
                else => unreachable, // isValue() covered the rest
            },
            .is_opaque = d.is_opaque,
            .is_equatable = d.is_equatable,
            .ctors_start = 0,
            .ctors_end = 0,
        });
    }
    try b.sortByName(Type, b.types.items, type_decls.items);

    var ctor_indices: std.ArrayList(u32) = .empty;
    errdefer ctor_indices.deinit(gpa);
    for (b.types.items, type_decls.items, 0..) |*t, di, i| {
        t.ctors_start = @intCast(b.ctors.items.len);
        // `pub opaque type` exports the name and hides the constructors
        // (language.md §5.1); a `foreign type` has none by construction.
        if (!t.is_opaque) {
            const owner = bir.decl(di);
            for (bir.declCtors(owner), owner.ctors_start..) |c, bir_index| {
                try b.ctors.append(gpa, .{
                    .name = try b.symbolIndex(bir.symbol(c.name)),
                    .type = @enumFromInt(i),
                    .arity = @intFromEnum(c.args_end) - @intFromEnum(c.args_start),
                });
                try ctor_indices.append(gpa, @intCast(bir_index));
            }
        }
        t.ctors_end = @intCast(b.ctors.items.len);
    }
    const iface = try b.finish();
    return .{ .iface = iface, .provenance = .{
        .value_decl = try value_decls.toOwnedSlice(gpa),
        .type_decl = try type_decls.toOwnedSlice(gpa),
        .ctor_index = try ctor_indices.toOwnedSlice(gpa),
    } };
}

const Builder = struct {
    gpa: Allocator,
    bir: *const Bir,
    interner: *const InternPool.Global,
    values: std.ArrayList(Value) = .empty,
    types: std.ArrayList(Type) = .empty,
    ctors: std.ArrayList(Ctor) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,

    fn deinit(b: *Builder) void {
        b.values.deinit(b.gpa);
        b.types.deinit(b.gpa);
        b.ctors.deinit(b.gpa);
        b.symbols.deinit(b.gpa);
    }

    /// Append `s` to the symbol column and return its index. Duplicates
    /// are not merged: the column has one entry per name slot, a handful
    /// per module, and a set would cost more than it saves.
    fn symbolIndex(b: *Builder, s: Symbol) Allocator.Error!SymbolIndex {
        const i: u32 = @intCast(b.symbols.items.len);
        try b.symbols.append(b.gpa, s);
        return @enumFromInt(i);
    }

    fn nameLessThan(b: *const Builder, a: SymbolIndex, c: SymbolIndex) bool {
        return std.mem.lessThan(
            u8,
            b.interner.slice(b.symbols.items[@intFromEnum(a)]),
            b.interner.slice(b.symbols.items[@intFromEnum(c)]),
        );
    }

    /// Sort `entries` by name text, applying the same permutation to
    /// `owners` so `owners[i]` stays the declaration of `entries[i]`.
    ///
    /// A permutation of indices rather than a sort of the pairs: a
    /// generated module can export tens of thousands of names, so the
    /// insertion sort this replaced was quadratic where it mattered. The
    /// sort is STABLE, which is what keeps two `pub` declarations of the
    /// same name — already reported as `duplicate_declaration`, but still
    /// present — in declaration order rather than in an order that depends
    /// on the sort's internals.
    fn sortByName(
        b: *Builder,
        comptime T: type,
        entries: []T,
        owners: []Bir.DeclIndex,
    ) Allocator.Error!void {
        std.debug.assert(entries.len == owners.len);
        if (entries.len < 2) return;
        const order = try b.gpa.alloc(u32, entries.len);
        defer b.gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const Cx = struct {
            b: *const Builder,
            entries: []const T,
            fn lessThan(cx: @This(), x: u32, y: u32) bool {
                return cx.b.nameLessThan(cx.entries[x].name, cx.entries[y].name);
            }
        };
        std.mem.sort(u32, order, Cx{ .b = b, .entries = entries }, Cx.lessThan);

        const sorted_entries = try b.gpa.alloc(T, entries.len);
        defer b.gpa.free(sorted_entries);
        const sorted_owners = try b.gpa.alloc(Bir.DeclIndex, owners.len);
        defer b.gpa.free(sorted_owners);
        for (order, sorted_entries, sorted_owners) |from, *e, *o| {
            e.* = entries[from];
            o.* = owners[from];
        }
        @memcpy(entries, sorted_entries);
        @memcpy(owners, sorted_owners);
    }

    fn finish(b: *Builder) Allocator.Error!Interface {
        var iface: Interface = .empty;
        errdefer iface.deinit(b.gpa);
        iface.values = try b.values.toOwnedSlice(b.gpa);
        iface.types = try b.types.toOwnedSlice(b.gpa);
        iface.ctors = try b.ctors.toOwnedSlice(b.gpa);
        iface.symbols = try b.symbols.toOwnedSlice(b.gpa);
        return iface;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The interface of the single module in `source`, rendered by
/// `dump/interface.zig` — the same text the corpus goldens hold, so a
/// hermetic test states what a black-box one would see.
fn expectInterface(expected: []const u8, source: [:0]const u8) !void {
    const TestProject = @import("TestProject.zig");
    const dump = @import("../dump/interface.zig");
    var p = try TestProject.init(testing.allocator, &.{.{ .path = "M.beni", .source = source, .package = .core }});
    defer p.deinit();
    const m = p.module("M").?;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump.write(&out.writer, testing.allocator, "M", &p.session.resolution.interfaces[m.int()], &p.session.checked.types, &p.session.interner);
    try testing.expectEqualStrings(expected, out.written());
}

test "the interface holds the pub names, sorted, and nothing else" {
    try expectInterface(
        \\module M
        \\  value alpha
        \\  value zebra
        \\
    ,
        \\pub zebra : Int
        \\zebra =
        \\    1
        \\
        \\
        \\pub alpha : Int
        \\alpha =
        \\    2
        \\
        \\
        \\private : Int
        \\private =
        \\    3
        \\
    );
}

test "types carry arity, kind, opacity and the equatable marker" {
    try expectInterface(
        \\module M
        \\  foreign type Handle (equatable)
        \\  alias Pair a
        \\  type Shape a b
        \\    Box/2
        \\    Empty
        \\  opaque type Token
        \\
    ,
        \\pub equatable foreign type Handle
        \\
        \\
        \\pub type alias Pair a =
        \\    ( a, a )
        \\
        \\
        \\pub type Shape a b
        \\    = Box a b
        \\    | Empty
        \\
        \\
        \\pub opaque type Token
        \\    = Token Int
        \\
    );
}

test "a foreign value is marked, and an unexported type contributes nothing" {
    try expectInterface(
        \\module M
        \\  foreign type Int (equatable)
        \\  foreign value add
        \\  value twice
        \\
    ,
        \\pub equatable foreign type Int
        \\
        \\
        \\type Hidden
        \\    = Hidden
        \\
        \\
        \\pub foreign add : Int -> Int -> Int
        \\
        \\
        \\pub twice : Int -> Int
        \\twice n =
        \\    add n n
        \\
    );
}

test "a module with no pub declarations has an empty interface" {
    try expectInterface("module M\n",
        \\hidden : Int
        \\hidden =
        \\    1
        \\
    );
}
