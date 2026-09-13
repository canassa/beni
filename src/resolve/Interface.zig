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
//! M2a builds the SKELETON: which names are public, what kind each is, how
//! many arguments each constructor takes, which types are opaque, foreign
//! or equatable. That is everything cross-module NAME resolution needs and
//! it is a lexical fact — no inference has run yet. M2b adds `schemes` and
//! `terms` next to these tables and fills the `scheme` slot each value
//! already carries; nothing here moves when it does, which is the point of
//! reserving the slot now.
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
pub const SymbolIndex = enum(u32) { _ };

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
    /// How many arguments it takes.
    arity: u32,
};

/// A module with nothing public, and what a module that failed to lower
/// contributes to its dependents.
pub const empty: Interface = .{ .values = &.{}, .types = &.{}, .ctors = &.{}, .symbols = &.{} };

pub fn deinit(iface: *Interface, gpa: Allocator) void {
    gpa.free(iface.values);
    gpa.free(iface.types);
    gpa.free(iface.ctors);
    gpa.free(iface.symbols);
    iface.* = undefined;
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

/// Build the interface of a lowered module. Only `bir.interface` — the
/// `pub` declarations lowering already picked out — is read, so this is
/// linear in the module's public surface and not in its size.
pub fn build(gpa: Allocator, bir: *const Bir, interner: *const InternPool.Global) Allocator.Error!Interface {
    var b: Builder = .{ .gpa = gpa, .bir = bir, .interner = interner };
    errdefer b.deinit();

    // Two passes over the `pub` declarations: values and types are sorted
    // independently, and a constructor's `type` field is an index into the
    // sorted type table, so the types must be placed first.
    for (bir.interface) |di| {
        const d = bir.decl(di);
        if (!d.kind.isValue()) continue;
        try b.values.append(gpa, .{
            .name = try b.symbolIndex(bir.symbol(d.name)),
            .is_foreign = d.kind == .foreign_value,
            .scheme = .none,
        });
    }
    std.mem.sort(Value, b.values.items, &b, Builder.valueLessThan);

    // Types in declaration order first, then sorted; a constructor's
    // owning index is patched afterwards, because sorting moves the types.
    var owners: std.ArrayList(Bir.DeclIndex) = .empty;
    defer owners.deinit(gpa);
    for (bir.interface) |di| {
        const d = bir.decl(di);
        if (d.kind.isValue()) continue;
        try owners.append(gpa, di);
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
    sortTypesWithOwners(&b, owners.items);

    for (b.types.items, owners.items, 0..) |*t, di, i| {
        t.ctors_start = @intCast(b.ctors.items.len);
        // `pub opaque type` exports the name and hides the constructors
        // (language.md §5.1); a `foreign type` has none by construction.
        if (!t.is_opaque) {
            for (bir.declCtors(bir.decl(di))) |c| {
                try b.ctors.append(gpa, .{
                    .name = try b.symbolIndex(bir.symbol(c.name)),
                    .type = @enumFromInt(i),
                    .arity = @intFromEnum(c.args_end) - @intFromEnum(c.args_start),
                });
            }
        }
        t.ctors_end = @intCast(b.ctors.items.len);
    }
    return b.finish();
}

/// Sort the type table by name while keeping `owners[i]` the declaration
/// of `types[i]`. An insertion sort: a module's public type count is in
/// the single digits, and this keeps the permutation applied to both
/// arrays without allocating an index array to sort instead.
fn sortTypesWithOwners(b: *Builder, owners: []Bir.DeclIndex) void {
    var i: usize = 1;
    while (i < b.types.items.len) : (i += 1) {
        var j = i;
        while (j > 0 and b.nameLessThan(b.types.items[j].name, b.types.items[j - 1].name)) : (j -= 1) {
            std.mem.swap(Type, &b.types.items[j], &b.types.items[j - 1]);
            std.mem.swap(Bir.DeclIndex, &owners[j], &owners[j - 1]);
        }
    }
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

    fn valueLessThan(b: *const Builder, a: Value, c: Value) bool {
        return b.nameLessThan(a.name, c.name);
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
    try dump.write(&out.writer, "M", &p.session.resolution.interfaces[m.int()], &p.session.interner);
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
