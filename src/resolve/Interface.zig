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
//! **The purity rule** (checker.md §7, decided 2026-09-18): every byte of
//! this record is a function of ITS MODULE'S SOURCE and ITS IMPORTS'
//! INTERFACES, and of nothing else in the program. Nothing here may be an
//! index assigned by walking the whole project. `Term.app` and `Term.alias`
//! used to spend `lhs` on a session `TypeStore.TypeId` — a whole-program
//! dense index — so adding one type declaration to an alphabetically
//! earlier module, `pub` or private, shifted the bytes of an untouched
//! module that did not import it, and the firewall of `fast-compiler.md`
//! §8.1 would have fired on approximately every type-introducing edit.
//! `type_refs` is the fix: a term names a type by WHERE IT IS DECLARED.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
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
/// Owned. Public schema namespaces, sorted by name text.
schemas: []const Schema,
/// Owned. Fixed members grouped by schema in `SchemaMember.Kind` order.
schema_members: []const SchemaMember,
/// Owned. Tagged endpoint constructors, program then encoded per schema.
schema_ctors: []const SchemaCtor,
/// Owned. Generalised types, one per value that has one (checker.md §7).
schemes: []const Scheme,
/// Owned. The flat type term language every scheme's body is written in.
terms: std.MultiArrayList(Term).Slice,
/// Owned. Ranges and record fields the terms point at.
extra: []const u32,
/// Owned. Every declared type the terms above name, each said in a way
/// that means the same thing in every compilation of the same sources —
/// see `TypeRef` and the header's purity rule. `Term.app` and `Term.alias`
/// index this.
type_refs: []const TypeRef,
/// Owned. Every OTHER nominal type of this module that a `type_refs` row
/// names — a private `type` or `foreign type` an importer can reach through
/// a published term — with its derived rows, sorted by name text
/// (`checker-v2.md` §14.2 *Amended by R8a*, CK-89). Never a declaration:
/// resolution does not read it. Empty in a record the old checker wrote.
hidden_types: []const HiddenType = &.{},
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
pub const SchemaIndex = enum(u32) { _ };
pub const SchemaMemberIndex = enum(u32) { _ };
pub const SchemaCtorIndex = enum(u32) { _ };

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

/// A declared type, named by WHERE IT IS DECLARED rather than by any index
/// the session assigned: the declaring module's package and name, and the
/// type's own name. The header's purity rule is why.
///
/// **Both names are `SymbolIndex`, never `Symbol`**, for the reason every
/// other name in this record is: a `Symbol` is an index into the session's
/// interner, whose numbering depends on which worker interned which file.
///
/// **The declaring module, not the module this record was imported FROM.**
/// A module's inferred scheme can name a type it never imported — `C` uses
/// `B.mk : A.T` without mentioning `A` — so the reference has to be
/// absolute. It is then copied through `B`'s record unchanged, and `C`'s
/// bytes move only when `B`'s do, which is exactly what the firewall wants.
///
/// **Private types are included.** `pub make : Hidden` over a private
/// `type Hidden` is legal and publishes a scheme naming a type that is in
/// no interface's `types` table, so a reference cannot be an interface
/// `TypeIndex`: it is a NAME, resolved against the declaring module's whole
/// declaration list (`check/Types.zig`'s `resolveRefs`).
pub const TypeRef = struct {
    /// The package the declaring module belongs to. A module's identity is
    /// `(package, name)` and not the name alone (`Graph`'s header).
    package: SourceStore.Package,
    /// The declaring module's name, e.g. `Json.Decode`.
    module: SymbolIndex,
    /// The type's own name, as its declaration spells it.
    name: SymbolIndex,
};

/// Index into `type_refs`. `none` is a poisoned type — the term said
/// nothing about which type it was, exactly as `TypeStore.TypeId.none`
/// does inside a store.
pub const TypeRefIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn int(i: TypeRefIndex) u32 {
        return @intFromEnum(i);
    }
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
        /// `lhs` is a `TypeRefIndex`; `rhs` an `extra` range of terms.
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
        /// `lhs` is a `TypeRefIndex`; `rhs` an `extra` range whose last
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
    ///
    /// A `u16` since interface v3 (`checker-v2.md` §14.2, CK-38): as a `u8`
    /// it saturated at 255, so a 256-parameter type was imported as a
    /// 255-parameter one. Lowering refuses a declaration of more than
    /// `max_type_params` (`too_many_type_parameters`), so no cast into this
    /// field saturates.
    arity: u16,
    kind: TypeKind,
    /// `pub opaque type T`: the name is exported, the constructors are
    /// not, and `ctors_start == ctors_end` here as a result.
    is_opaque: bool,
    /// `equatable foreign type T` (checker.md Appendix B): values of this
    /// type may be compared with `==`. Only ever set on a `foreign` type;
    /// for an `adt` or `alias` the answer follows from its fields and is
    /// M2b's to compute.
    is_equatable: bool,
    /// `checker-v2.md` §11.4's gate for an `adt` (R8b's review round, CK-120):
    /// no function is reachable from its payloads, through its own module's
    /// types, schema endpoints and `via` targets and the published gates of
    /// everything else. Written by the new checker; the old one writes
    /// `false`, and an importer reads its table bit instead.
    no_function: bool = false,
    ctors_start: u32,
    ctors_end: u32,
    /// The parameters that occur in a constructor payload, as a bitset: an
    /// `extra` range of `⌈arity / 32⌉` words, parameter `i` at bit `i % 32`
    /// of word `i / 32` (`checker-v2.md` §14.2, D10). Every bit is set for
    /// a `foreign type`, whose payloads nobody can see; an alias has none.
    /// Filled when the module is checked, from EVERY constructor — an
    /// opaque type's hidden ones included, which is the point: the marker
    /// walk must not read them from another module. `no_terms` until then.
    payload_params: u32 = no_terms,
    /// What an importer resolves `==` and `compare` on this type against
    /// when the type declares no method of its own (§14.2, D4): the
    /// derived function's context, or why there is none. Filled when the
    /// module is checked; `unchecked` until then.
    eq: Derived = .{},
    compare: Derived = .{},

    pub fn ctorRange(t: Type) struct { u32, u32 } {
        return .{ t.ctors_start, t.ctors_end };
    }

    pub fn derived(t: Type, kind: DerivedKind) Derived {
        return switch (kind) {
            .eq => t.eq,
            .compare => t.compare,
        };
    }
};

/// The most type parameters a declaration may have (`checker-v2.md` §14.2):
/// `Type.arity` is a `u16`.
pub const max_type_params: u32 = Bir.max_type_params;

pub const DerivedKind = enum { eq, compare };

/// A private nominal type of this module an importer can reach (§14.2 *as
/// amended by R8a*): the facts of a `Type` row an importer reads, and no
/// constructors — it cannot name them. A tagged schema endpoint named by a
/// published term has one too (R8b), its name `Schema.Type` or
/// `Schema.Encoded`, `no_function` its §11.4 gate.
pub const HiddenType = struct {
    name: SymbolIndex,
    arity: u16,
    kind: TypeKind,
    is_equatable: bool,
    /// As `Type.no_function`.
    no_function: bool = false,
    payload_params: u32 = no_terms,
    eq: Derived = .{},
    compare: Derived = .{},
};

/// What an importer reads about one nominal type of a module: its exported
/// row, else its hidden one.
pub const TypeFacts = struct {
    arity: u16,
    kind: TypeKind,
    /// The row's `is_equatable`: a `foreign type` declared `equatable`.
    is_equatable: bool,
    /// The row's §11.4 gate for an `adt` (`Type.no_function`).
    no_function: bool,
    payload_params: u32,
    eq: Derived,
    compare: Derived,

    pub fn derived(t: TypeFacts, kind: DerivedKind) Derived {
        return switch (kind) {
            .eq => t.eq,
            .compare => t.compare,
        };
    }
};

/// The facts of this module's nominal type `name`: its `types` row, else its
/// `hidden_types` row, else null — a record the old checker wrote has no
/// hidden rows, and the caller reads v1's ABI for it (§14.2 *as amended by
/// R8a*).
pub fn typeFacts(iface: *const Interface, interner: *const InternPool.Global, name: Symbol) ?TypeFacts {
    if (find(iface, interner, Type, iface.types, name)) |i| {
        const t = iface.types[i];
        return .{ .arity = t.arity, .kind = t.kind, .is_equatable = t.is_equatable, .no_function = t.no_function, .payload_params = t.payload_params, .eq = t.eq, .compare = t.compare };
    }
    if (find(iface, interner, HiddenType, iface.hidden_types, name)) |i| {
        const t = iface.hidden_types[i];
        return .{ .arity = t.arity, .kind = t.kind, .is_equatable = t.is_equatable, .no_function = t.no_function, .payload_params = t.payload_params, .eq = t.eq, .compare = t.compare };
    }
    return null;
}

/// One entry of a `present` context (§14.2 *as amended by R8a*).
pub const ContextEntry = struct {
    param: u16,
    method: SymbolIndex,
    /// `none` for `eq` and `compare`; else the element of the row's method
    /// types (`contextScheme`) that is this entry's method type.
    slot: u32,
};

/// Words per context entry: `(param, method, slot)`. The range starts with
/// one more word, the row's scheme (`contextScheme`).
pub const context_words = 3;

/// The scheme of a present row's method types, or `none` when every entry
/// is `eq` or `compare`: its body is `( p₀, …, pₙ₋₁, ( τ₀, …, τₖ ) )`, the
/// type's parameters and then one method type per `slot` (§14.2 *as amended
/// by R8a*, after its review: one scheme per row, not per entry).
pub fn contextScheme(iface: *const Interface, context: u32) SchemeIndex {
    const words = iface.range(context);
    if (words.len == 0) return .none;
    return @enumFromInt(words[0]);
}

/// A `private_method` row's culprit (`Derived.Status.private_method`): the
/// type whose module declares the private method, and its name. Null for a
/// range not of that shape (`iface_bytes.verify` refuses one).
pub fn privateCulprit(iface: *const Interface, context: u32) ?struct { type_ref: TypeRefIndex, method: SymbolIndex } {
    if (context == no_terms) return null;
    const words = iface.range(context);
    if (words.len != 2) return null;
    return .{ .type_ref = @enumFromInt(words[0]), .method = @enumFromInt(words[1]) };
}

/// Entry `i` of a context range (`Derived.context`), or null past its end.
pub fn contextEntry(iface: *const Interface, context: u32, i: usize) ?ContextEntry {
    const words = iface.range(context);
    if (words.len == 0 or 1 + (i + 1) * context_words > words.len) return null;
    const at = 1 + i * context_words;
    return .{
        .param = @intCast(@min(words[at], std.math.maxInt(u16))),
        .method = @enumFromInt(words[at + 1]),
        .slot = words[at + 2],
    };
}

/// How many entries a context range holds.
pub fn contextLen(iface: *const Interface, context: u32) u32 {
    if (context == no_terms) return 0;
    const words = iface.range(context);
    if (words.len == 0) return 0;
    return @intCast((words.len - 1) / context_words);
}

/// One exported type's derived `eq` or `compare` (`checker-v2.md` §14.2, D4,
/// I10): `present` with a context — an `extra` range of the row's scheme word
/// (`contextScheme`) and then `(param, method, slot)` triples
/// (`ContextEntry`), sorted by `(param, method text)`, `method` a
/// `SymbolIndex` — or absent, with the reason.
///
/// The old checker writes exactly its own ABI: one entry per type parameter,
/// each naming the method being derived, `slot` and the scheme `none`. The new checker
/// writes its inferred contexts (D4) in the same format.
pub const Derived = struct {
    status: Status = .unchecked,
    /// An `extra` range of `1 + 3 × entries` words when `status == .present`,
    /// else `no_terms`.
    context: u32 = no_terms,

    pub const Status = enum(u8) {
        /// Not filled: the module was never checked.
        unchecked,
        /// The declaring module emits the derived function.
        present,
        /// §3.2's table answers the method with a JavaScript operator:
        /// `Int`, `Float`, `Char`, `String` and `Bool` both methods, `Order`'s
        /// `eq` (A.18). No function exists. (`Order`'s `compare` and `Never`'s
        /// two are derived: `present`.)
        primitive,
        /// The type's module declares a `pub` value of the method's name —
        /// the type's own method, or under the module rule
        /// (static-dispatch-spike.md §3.3 step 1) one for another type of the
        /// module — so nothing is derived.
        own_method,
        /// A `foreign type`, of any arity, that neither the table nor its
        /// module answers: there is no body to derive over (A.55). An
        /// `equatable` one is still compared by the structural walk.
        foreign,
        /// A function is reachable in a payload (`not_equatable`).
        function,
        /// A payload cannot answer the method for any other reason — a type
        /// that cannot order inside it, say.
        unanswerable,
        /// A type alias, which is not nominal: its expansion answers.
        alias,
        /// D1 (`checker-v2.md` §11.3, §14.2 *as amended by R8b*): the method
        /// is a PRIVATE method of some module, which no other module may
        /// use — the type's own module's, under the module rule, or one a
        /// payload's context reaches. `context` is a range of two words,
        /// `(type_ref, method)`: a `TypeRefIndex` whose declaring module
        /// declares the private method, and the method's `SymbolIndex`
        /// (`privateCulprit`), so the importer's message names it.
        private_method,
    };
};

/// What a constructor builds (`checker-v2.md` §14.2, CK-39).
pub const CtorResult = enum(u8) {
    /// `T p0 … pk`: a constructor of a `type`.
    nominal,
    /// The record a `type alias` of a record body names: its implicit
    /// constructor, whose value IS the record (D12, `backend.md` §4).
    record_alias,
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
    /// What the constructor's application IS (interface v3, CK-39): the
    /// owning type applied to its parameters, or a record alias's record.
    result: CtorResult = .nominal,
    /// For a `record_alias` constructor, its field names in DECLARATION
    /// order — argument `i` is field `i` — as an `extra` range of
    /// `SymbolIndex` words; `no_terms` for a nominal one. The alias body's
    /// record term cannot give them: its fields are canonicalised by name
    /// text, and the constructor's argument order is the declaration's
    /// (`checker-v2.md` §14.2, the R1-review amendment). The backend emits an
    /// imported alias's constructor as the record, and reads its pattern's
    /// arguments, by these names.
    fields: u32 = no_terms,
};

pub const Schema = struct {
    name: SymbolIndex,
    params_len: u32,
    members_start: u32,
    members_end: u32,
    program_ctors_start: u32,
    program_ctors_end: u32,
    encoded_ctors_start: u32,
    encoded_ctors_end: u32,
};

pub const SchemaMember = struct {
    name: SymbolIndex,
    schema: SchemaIndex,
    scheme: SchemeIndex = .none,
    kind: Kind,
    arity: u8,
    visible: bool = true,

    pub const Kind = enum(u8) { type, encoded, schema, parse, print, parse_with, print_with };
};

pub const SchemaCtor = struct {
    name: SymbolIndex,
    schema: SchemaIndex,
    scheme: SchemeIndex = .none,
    endpoint: Endpoint,
    arity: u8,
    visible: bool = true,

    pub const Endpoint = enum(u8) { type, encoded };
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
    /// `schemas[i]` was declared by `schema_decl[i]`.
    schema_decl: []const Bir.DeclIndex,

    pub const empty: Provenance = .{ .value_decl = &.{}, .type_decl = &.{}, .ctor_index = &.{}, .schema_decl = &.{} };

    pub fn deinit(p: *Provenance, gpa: Allocator) void {
        gpa.free(p.value_decl);
        gpa.free(p.type_decl);
        gpa.free(p.ctor_index);
        gpa.free(p.schema_decl);
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

    pub fn schemaDecl(p: *const Provenance, i: usize) ?Bir.DeclIndex {
        return if (i < p.schema_decl.len) p.schema_decl[i] else null;
    }
};

/// A module with nothing public, and what a module that failed to lower
/// contributes to its dependents.
pub const empty: Interface = .{
    .values = &.{},
    .types = &.{},
    .ctors = &.{},
    .schemas = &.{},
    .schema_members = &.{},
    .schema_ctors = &.{},
    .schemes = &.{},
    .terms = .empty,
    .extra = &.{},
    .type_refs = &.{},
    .symbols = &.{},
};

pub fn deinit(iface: *Interface, gpa: Allocator) void {
    gpa.free(iface.values);
    gpa.free(iface.types);
    gpa.free(iface.ctors);
    gpa.free(iface.schemas);
    gpa.free(iface.schema_members);
    gpa.free(iface.schema_ctors);
    gpa.free(iface.schemes);
    iface.terms.deinit(gpa);
    gpa.free(iface.extra);
    gpa.free(iface.type_refs);
    gpa.free(iface.hidden_types);
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

/// The term at `index`, or `err` for `none` and for an index this record
/// does not describe. Bounds-checked for the reason `range` is: M4 maps
/// these from disk, and a record that does not describe itself must not be
/// able to crash the compiler — nor to mislead it, which is why the
/// degraded answer is `err` (the tag every reader already poisons on) and
/// not some other term's bytes (checker.md §7's *The serialized form*).
pub fn term(iface: *const Interface, index: TermIndex) Term {
    if (index == .none or index.int() >= iface.terms.len) return .{ .tag = .err, .lhs = 0, .rhs = 0 };
    return iface.terms.get(index.int());
}

/// The type an `app` or `alias` term names, or null for `none` and for an
/// index this record does not describe — M4 maps these from disk, and a
/// record that does not describe itself must not be able to crash the
/// compiler (`range`'s comment).
pub fn typeRef(iface: *const Interface, index: TypeRefIndex) ?TypeRef {
    if (index == .none or index.int() >= iface.type_refs.len) return null;
    return iface.type_refs[index.int()];
}

/// The scheme at `index`. `none`, and an index this record does not
/// describe, both yield the empty scheme — no quantifiers and an `err`
/// body, which is what a value with no scheme already means to every
/// reader. Bounds-checked for `range`'s reason.
pub fn scheme(iface: *const Interface, index: SchemeIndex) Scheme {
    if (index == .none or @intFromEnum(index) >= iface.schemes.len) {
        return .{ .quantified_start = 0, .quantified_count = 0, .body = .none };
    }
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
/// failed to check, a module that was never checked, or a value index this
/// record does not describe (`range`'s reason).
pub fn valueScheme(iface: *const Interface, value: ValueIndex) ?Scheme {
    if (@intFromEnum(value) >= iface.values.len) return null;
    const s = iface.values[@intFromEnum(value)].scheme;
    if (s == .none) return null;
    return iface.scheme(s);
}

/// The interner symbol at `index`. An index this record does not describe
/// yields symbol 0 — `InternPool.WellKnown.main`, which every session has
/// interned — so a malformed record renders as a wrong NAME rather than
/// reading past the column. Bounds-checked for `range`'s reason; every
/// caller of this is on the path a record mapped from disk reaches.
pub fn symbol(iface: *const Interface, index: SymbolIndex) Symbol {
    if (@intFromEnum(index) >= iface.symbols.len) return @enumFromInt(0);
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

pub fn findSchema(iface: *const Interface, interner: *const InternPool.Global, name: Symbol) ?SchemaIndex {
    const i = find(iface, interner, Schema, iface.schemas, name) orelse return null;
    return @enumFromInt(i);
}

pub fn findSchemaMember(
    iface: *const Interface,
    schema_index: SchemaIndex,
    interner: *const InternPool.Global,
    name: Symbol,
    kind: ?SchemaMember.Kind,
) ?SchemaMemberIndex {
    if (@intFromEnum(schema_index) >= iface.schemas.len) return null;
    const schema = iface.schemas[@intFromEnum(schema_index)];
    if (schema.members_start > schema.members_end or schema.members_end > iface.schema_members.len) return null;
    for (iface.schema_members[schema.members_start..schema.members_end], schema.members_start..) |member, i| {
        if (kind != null and member.kind != kind.?) continue;
        if (iface.symbol(member.name) == name) return @enumFromInt(i);
    }
    _ = interner;
    return null;
}

pub fn findSchemaCtor(
    iface: *const Interface,
    schema_index: SchemaIndex,
    endpoint: SchemaCtor.Endpoint,
    interner: *const InternPool.Global,
    name: Symbol,
) ?SchemaCtorIndex {
    if (@intFromEnum(schema_index) >= iface.schemas.len) return null;
    const schema = iface.schemas[@intFromEnum(schema_index)];
    const start, const end = switch (endpoint) {
        .type => .{ schema.program_ctors_start, schema.program_ctors_end },
        .encoded => .{ schema.encoded_ctors_start, schema.encoded_ctors_end },
    };
    if (start > end or end > iface.schema_ctors.len) return null;
    for (iface.schema_ctors[start..end], start..) |ctor, i| {
        if (iface.symbol(ctor.name) == name) return @enumFromInt(i);
    }
    _ = interner;
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
        if (d.kind == .schema) continue; // S1 refusal runs before this; S2 adds its own table.
        try type_decls.append(gpa, di);
        try b.types.append(gpa, .{
            .name = try b.symbolIndex(bir.symbol(d.name)),
            // Lowering refused more (`max_type_params`), so this saturates
            // only on a declaration that already has its error.
            .arity = std.math.cast(u16, d.params) orelse std.math.maxInt(u16),
            .kind = switch (d.kind) {
                .type => .adt,
                .type_alias => .alias,
                .foreign_type => .foreign,
                .schema => unreachable,
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
                const name = try b.symbolIndex(bir.symbol(c.name));
                // A record alias's implicit constructor carries its field
                // names, argument `i` being field `i` (§14.2, CK-39) — a
                // lexical fact, so the skeleton has it before any check.
                const result: CtorResult, const fields = if (owner.kind == .type_alias)
                    .{ .record_alias, try b.aliasFieldNames(owner) }
                else
                    .{ .nominal, no_terms };
                try b.ctors.append(gpa, .{
                    .name = name,
                    .type = @enumFromInt(i),
                    .arity = @intFromEnum(c.args_end) - @intFromEnum(c.args_start),
                    .result = result,
                    .fields = fields,
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
        .schema_decl = try b.schema_decls.toOwnedSlice(gpa),
    } };
}

const Builder = struct {
    gpa: Allocator,
    bir: *const Bir,
    interner: *const InternPool.Global,
    values: std.ArrayList(Value) = .empty,
    types: std.ArrayList(Type) = .empty,
    ctors: std.ArrayList(Ctor) = .empty,
    schemas: std.ArrayList(Schema) = .empty,
    schema_members: std.ArrayList(SchemaMember) = .empty,
    schema_ctors: std.ArrayList(SchemaCtor) = .empty,
    schema_decls: std.ArrayList(Bir.DeclIndex) = .empty,
    extra: std.ArrayList(u32) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,

    fn deinit(b: *Builder) void {
        b.values.deinit(b.gpa);
        b.types.deinit(b.gpa);
        b.ctors.deinit(b.gpa);
        b.schemas.deinit(b.gpa);
        b.schema_members.deinit(b.gpa);
        b.schema_ctors.deinit(b.gpa);
        b.schema_decls.deinit(b.gpa);
        b.extra.deinit(b.gpa);
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

    /// The `extra` range of a record alias's field names in declaration
    /// order, each a new symbol slot: the body's `type_record`, which is the
    /// only body that declares a constructor (`bir/Lower.zig`). A body
    /// that is not one — a parenthesised record — gives an empty range, and
    /// its constructor then has no arguments either.
    fn aliasFieldNames(b: *Builder, owner: Bir.Decl) Allocator.Error!u32 {
        const start: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, 0);
        const body = owner.annotation.unwrap() orelse return start;
        if (b.bir.instTag(body) != .type_record) return start;
        const fields = b.bir.extraSlice(Bir.inlineRange(b.bir.instData(body)), Bir.Field);
        for (fields) |f| try b.extra.append(b.gpa, @intFromEnum(try b.symbolIndex(b.bir.symbol(f.name))));
        b.extra.items[start] = @intCast(fields.len);
        return start;
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
        try b.buildSchemas();
        var iface: Interface = .empty;
        errdefer iface.deinit(b.gpa);
        iface.values = try b.values.toOwnedSlice(b.gpa);
        iface.types = try b.types.toOwnedSlice(b.gpa);
        iface.ctors = try b.ctors.toOwnedSlice(b.gpa);
        iface.schemas = try b.schemas.toOwnedSlice(b.gpa);
        iface.schema_members = try b.schema_members.toOwnedSlice(b.gpa);
        iface.schema_ctors = try b.schema_ctors.toOwnedSlice(b.gpa);
        iface.extra = try b.extra.toOwnedSlice(b.gpa);
        iface.symbols = try b.symbols.toOwnedSlice(b.gpa);
        return iface;
    }

    fn buildSchemas(b: *Builder) Allocator.Error!void {
        for (b.bir.interface) |di| {
            const d = b.bir.decl(di);
            if (d.kind != .schema) continue;
            try b.schema_decls.append(b.gpa, di);
            try b.schemas.append(b.gpa, .{
                .name = try b.symbolIndex(b.bir.symbol(d.name)),
                .params_len = d.params,
                .members_start = 0,
                .members_end = 0,
                .program_ctors_start = 0,
                .program_ctors_end = 0,
                .encoded_ctors_start = 0,
                .encoded_ctors_end = 0,
            });
        }
        try b.sortByName(Schema, b.schemas.items, b.schema_decls.items);

        const member_names = [_][]const u8{ "Type", "Encoded", "schema", "parse", "print", "parseWith", "printWith" };
        for (b.schemas.items, b.schema_decls.items, 0..) |*schema, di, schema_i| {
            const d = b.bir.decl(di);
            schema.members_start = @intCast(b.schema_members.items.len);
            for (member_names, 0..) |text, kind_i| {
                const member_symbol = b.interner.find(text) orelse unreachable; // Lower pre-interns every fixed member.
                const kind: SchemaMember.Kind = @enumFromInt(kind_i);
                const n = d.params;
                const arity: u8 = std.math.cast(u8, switch (kind) {
                    .type, .encoded => n,
                    .schema => if (n == 0) 1 else n,
                    .parse, .print => n + 1,
                    .parse_with, .print_with => n + 2,
                }) orelse std.math.maxInt(u8);
                try b.schema_members.append(b.gpa, .{
                    .name = try b.symbolIndex(member_symbol),
                    .schema = @enumFromInt(schema_i),
                    .kind = kind,
                    .arity = arity,
                });
            }
            schema.members_end = @intCast(b.schema_members.items.len);

            // Empty constructor families still own their position in the
            // grouped column. Leaving the skeleton's zeroes here makes a
            // record schema following a tagged schema overlap the first
            // schema's ranges after a byte round-trip.
            schema.program_ctors_start = @intCast(b.schema_ctors.items.len);
            schema.program_ctors_end = @intCast(b.schema_ctors.items.len);
            schema.encoded_ctors_start = @intCast(b.schema_ctors.items.len);
            schema.encoded_ctors_end = @intCast(b.schema_ctors.items.len);
            const root = d.schema_body.unwrap() orelse continue;
            const tagged = schemaTagged(b.bir, root) orelse continue;
            const variants = b.bir.extraSlice(b.bir.subRange(@enumFromInt(b.bir.instData(tagged).rhs)), Bir.Inst.Index);
            schema.program_ctors_start = @intCast(b.schema_ctors.items.len);
            try b.appendSchemaCtors(@enumFromInt(schema_i), .type, variants);
            schema.program_ctors_end = @intCast(b.schema_ctors.items.len);
            schema.encoded_ctors_start = @intCast(b.schema_ctors.items.len);
            try b.appendSchemaCtors(@enumFromInt(schema_i), .encoded, variants);
            schema.encoded_ctors_end = @intCast(b.schema_ctors.items.len);
        }
    }

    fn appendSchemaCtors(b: *Builder, schema: SchemaIndex, endpoint: SchemaCtor.Endpoint, variants: []const Bir.Inst.Index) Allocator.Error!void {
        for (variants) |variant_inst| {
            if (b.bir.instTag(variant_inst) != .schema_variant) continue;
            const data = b.bir.instData(variant_inst);
            const variant = b.bir.extraData(@enumFromInt(data.rhs), Bir.SchemaVariant);
            try b.schema_ctors.append(b.gpa, .{
                .name = try b.symbolIndex(b.bir.symbol(@enumFromInt(data.lhs))),
                .schema = schema,
                .endpoint = endpoint,
                .arity = if (variant.payload == .none) 0 else 1,
            });
        }
    }
};

fn schemaTagged(bir: *const Bir, root: Bir.Inst.Index) ?Bir.Inst.Index {
    var at = root;
    var budget: usize = bir.insts.len + 1;
    while (budget > 0 and at.int() < bir.insts.len) : (budget -= 1) {
        switch (bir.instTag(at)) {
            .schema_tagged => return at,
            .schema_value, .schema_paren => at = @enumFromInt(bir.instData(at).lhs),
            else => return null,
        }
    }
    return null;
}

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
    try dump.write(
        &out.writer,
        testing.allocator,
        "M",
        &p.session.resolution.interfaces[m.int()],
        p.session.checked.types.refIds(m),
        &p.session.checked.types,
        &p.session.interner,
    );
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

// ---------------------------------------------------------------------------
// The bounds-checked posture (checker.md §7, *The serialized form*).
//
// Every accessor above answers a DEGRADED value rather than trapping, because
// M4 loads these records from bytes and a record that does not describe itself
// must be able to crash neither the compiler nor the answer. The records below
// are ones no writer produces: every index in them is out of range on purpose.
// ---------------------------------------------------------------------------

test "an empty record's accessors answer instead of trapping" {
    const iface: Interface = .empty;
    try testing.expectEqual(Term.Tag.err, iface.term(@enumFromInt(0)).tag);
    try testing.expectEqual(Term.Tag.err, iface.term(.none).tag);
    try testing.expectEqual(Term.Tag.err, iface.term(@enumFromInt(std.math.maxInt(u32) - 1)).tag);

    try testing.expectEqual(TermIndex.none, iface.scheme(@enumFromInt(0)).body);
    try testing.expectEqual(@as(u32, 0), iface.scheme(@enumFromInt(7)).quantified_count);
    try testing.expectEqual(TermIndex.none, iface.scheme(.none).body);

    try testing.expectEqual(@as(?Scheme, null), iface.valueScheme(@enumFromInt(0)));
    try testing.expectEqual(@as(Symbol, @enumFromInt(0)), iface.symbol(@enumFromInt(9)));
}

test "a record whose indices leave their columns still answers" {
    var terms: std.MultiArrayList(Term) = .empty;
    defer terms.deinit(testing.allocator);
    try terms.append(testing.allocator, .{ .tag = .unit, .lhs = 0, .rhs = 0 });

    // One value naming a scheme that is not there, one scheme whose body is
    // not there, and a symbol column of length one.
    const iface: Interface = .{
        .values = &.{.{ .name = @enumFromInt(4), .is_foreign = false, .scheme = @enumFromInt(3) }},
        .types = &.{},
        .ctors = &.{},
        .schemas = &.{},
        .schema_members = &.{},
        .schema_ctors = &.{},
        .schemes = &.{.{ .quantified_start = 100, .quantified_count = 2, .body = @enumFromInt(50) }},
        .terms = terms.slice(),
        .extra = &.{},
        .type_refs = &.{},
        .symbols = &.{@enumFromInt(0)},
    };

    // The one real term is readable; one past it is `err`.
    try testing.expectEqual(Term.Tag.unit, iface.term(@enumFromInt(0)).tag);
    try testing.expectEqual(Term.Tag.err, iface.term(@enumFromInt(1)).tag);

    // `values[0].scheme` is 3 and there is one scheme: the degraded scheme,
    // not a read past `schemes`.
    const s = iface.valueScheme(@enumFromInt(0)).?;
    try testing.expectEqual(TermIndex.none, s.body);
    try testing.expectEqual(@as(u32, 0), s.quantified_count);
    // And a value index past the column is "no scheme" rather than a trap.
    try testing.expectEqual(@as(?Scheme, null), iface.valueScheme(@enumFromInt(1)));

    // The scheme that IS there has a body index that is not, and quantifiers
    // past the end of `extra`; both are already the six accessors' business.
    const real = iface.scheme(@enumFromInt(0));
    try testing.expectEqual(Term.Tag.err, iface.term(real.body).tag);
    try testing.expectEqual(SymbolIndex.Optional.none, iface.quantified(real, 0).name);

    // `values[0].name` is 4 over a one-entry symbol column.
    try testing.expectEqual(@as(Symbol, @enumFromInt(0)), iface.symbol(@enumFromInt(4)));
    try testing.expectEqual(@as(Symbol, @enumFromInt(0)), iface.symbol(@enumFromInt(1)));
}
