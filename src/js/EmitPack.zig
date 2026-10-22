//! The emit rows (`backend.md` §9, *The embedded modules' printed text, in
//! the pack*; `fast-compiler.md` §8, *The checked core, embedded*): the
//! development text of every module the binary carries, split in the units
//! `Lower` already draws, each with the marks, the names, the import asks,
//! the facts it consumed and the outgoing edges a join replays.
//!
//! **A row is a function of its module's check and of one build option.**
//! Lowering reads a short list of facts about the build (`Lower.Funnel`),
//! and of them only `--schema-library` is not a term of the module key (the
//! same split `EdgePack` made for `--release` and `--schema-library`; a
//! release build reads no row, `backend.md` §9, *Walk-1*). So the row is
//! keyed by the module key and that option, and the maker writes one row
//! per option.
//!
//! **A refused module has no row.** A module the maker cannot cache — one
//! that writes markup, names a program constructor or a placement, declares
//! a schema, or owns a derived codec plan (`core_pack_main.zig`) — is not
//! stored at all, and the completeness check has no row to require for it
//! (`backend.md` §9, *The maker*; `fast-compiler.md` §8).
//!
//! **The text is the units' text and nothing else.** The head, the tail and
//! the footer are rebuilt by the join and are not stored; `text` holds the
//! units back to back, and a unit's `start`/`len` are into it. The units
//! cover it in order with no gaps, each one nonempty — the invariant the
//! maker's split and the join's splice both rest on.
//!
//! **A mark's name is an identity, not a number.** The printer numbers a
//! module's map names in first-use order, and that order is a property of
//! the touched units; so a row records, per mark, the identity the
//! interning already deduplicated on — the module part, the base and the
//! tag — and, per unit, the identities it introduced, in the order the
//! printer numbered them. A join rebuilds the module's names list from the
//! units it takes, in that order, one entry per identity however many
//! marks carry it.
//!
//! **A fact is one question and the answer it got** (`backend.md` §9, *The
//! funnel, and why reuse is honest*). A build reuses a unit only when it
//! answers every one of the unit's recorded questions the same way; a
//! question the row does not hold was never asked, so it is no dependence.
//! The facts are stored sorted and deduplicated, so two records that asked
//! the same questions in a different order are the same record — the
//! questions do not steer the lowering except through their answers.
//!
//! ```
//! version: u32
//! flags: u8                     deep, list_eq, list_compare, eq_prim,
//!                               compare_prim, compare_char
//! strings: u32, then per string  len: u32, bytes
//! modules: u32, then per module  package: u8, name: u32 (a string)
//! idents: u32, then per ident    module: u32 (a string or `no_string`),
//!                                base: u32 (a string), tag: u32
//! text: u32 len, bytes
//! units: u32, then per unit
//!   selector: kind: u8, flags: u8, a: u32, b: u32
//!   start: u32, len: u32
//!   marks: u32, then per mark    generated: u32, source: u32,
//!                                name: u32 (an ident or `no_name`)
//!   introduced: u32, then per    ident: u32
//!   needed: u32, then per need   module: u32, value: u32 (or `no_value`),
//!                                base: u32 (a string or `no_string`)
//!   facts: u32, then per fact    question: u8, where: u8, module: u32,
//!                                index: u32, answer: u8
//!   runtime: u8
//!   edges: u32, then per edge    position: u32
//! ```
//!
//! `generated` is relative to the unit's first byte; `source` is the
//! `.beni` byte offset. A fact's `module` is 0 for this module and a
//! module-table slot + 1 otherwise; a needed entry's is the same. An edge
//! is a canonical position of the module's own check — a declaration index,
//! or `bir.decls.len + k` for a derived codec — never a graph index.
//!
//! Little-endian by definition, like every byte format of the cache.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SourceStore = @import("../SourceStore.zig");
const Key = @import("../cache/Key.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");

pub const magic = "BENIEMIT";
/// 1: the first.
pub const version: u32 = 1;

/// The build options a row depends on beyond its module key.
pub const Options = struct {
    schema_library: bool,
};

/// Every combination of `Options`: the rows the maker writes per module.
pub const every_options = [_]Options{
    .{ .schema_library = false },
    .{ .schema_library = true },
};

/// The key of the row that holds the units of the module whose key is
/// `module`, made with `options`.
pub fn key(module: Key.Key, options: Options) Key.Key {
    var bytes: [magic.len + 4 + 16 + 1]u8 = undefined;
    @memcpy(bytes[0..magic.len], magic);
    std.mem.writeInt(u32, bytes[magic.len..][0..4], version, .little);
    @memcpy(bytes[magic.len + 4 ..][0..16], &module);
    bytes[magic.len + 20] = @intFromBool(options.schema_library);
    return iface_bytes.hash(&bytes);
}

pub const no_string = std.math.maxInt(u32);
pub const no_value = std.math.maxInt(u32);
pub const no_name = std.math.maxInt(u32);
/// A module slot's "this module".
pub const self_slot = 0;

/// The module-level flags. The first three are the or of the units'
/// `runtime` (`uses_runtime` is their or); the next three are the module's
/// comparator flags, which select the comparator constants of the unit list
/// (`Lowerer.needs`, `backend.md` §9, *The funnel*).
pub const Flags = struct {
    deep: bool = false,
    list_eq: bool = false,
    list_compare: bool = false,
    eq_prim: bool = false,
    compare_prim: bool = false,
    compare_char: bool = false,

    pub const all: u8 = 0x3F;

    pub fn byte(f: Flags) u8 {
        return @as(u8, @intFromBool(f.deep)) |
            (@as(u8, @intFromBool(f.list_eq)) << 1) |
            (@as(u8, @intFromBool(f.list_compare)) << 2) |
            (@as(u8, @intFromBool(f.eq_prim)) << 3) |
            (@as(u8, @intFromBool(f.compare_prim)) << 4) |
            (@as(u8, @intFromBool(f.compare_char)) << 5);
    }

    pub fn of(b: u8) Flags {
        return .{
            .deep = b & 1 != 0,
            .list_eq = b & 2 != 0,
            .list_compare = b & 4 != 0,
            .eq_prim = b & 8 != 0,
            .compare_prim = b & 16 != 0,
            .compare_char = b & 32 != 0,
        };
    }
};

/// What selects a unit: the build fact whose answer decides whether the join
/// takes it. `backend.md` §9, *The unit list*'s bullets are the kinds.
pub const Selector = struct {
    kind: Kind,
    /// Kind-dependent: another package's constructor, or a schema's.
    flags: u8 = 0,
    /// A declaration index, a module slot, a which — by kind.
    a: u32 = 0,
    /// A part, a row, a constructor — by kind.
    b: u32 = 0,

    pub const Kind = enum(u8) {
        /// A nullary constructor's constant, selected when the build lowers
        /// a use of it (`Lower.nullaryDecls`). `a` is the module (0 this
        /// one), `b` the constructor, flags bit 0 another package's and
        /// bit 1 a schema's codec.
        nullary = 0,
        /// A synthesised value (`Lower.synthesisedValues`). `a` is the
        /// which, `b` the derived row.
        synthesised = 1,
        /// A declaration's statements, direct or twin, or one lifted piece.
        decl = 2,
        /// A schema declaration's parts (`Lower.declaration`; issue #349
        /// owns the boundaries). `a` is the declaration, `b` the part.
        schema = 3,
    };

    /// `synthesised.a`: which of `synthesisedValues`' runs a unit is.
    pub const Synth = enum(u8) {
        /// The `$$order` table of `b`.
        order = 0,
        /// The arrow of derived row `b`.
        arrow = 1,
        /// The `$$steps` helper of derived row `b`.
        steps = 2,
        /// Comparator constant `b` (0 `eq$prim`, 1 `compare$prim`,
        /// 2 `compare$char`).
        primitive = 3,
    };

    /// `decl.b`: the part of declaration `a`.
    pub const direct = 0;
    pub const twin = 1;
    /// A lifted piece: `part_lift + g`, `g` the piece's index in
    /// `Input.direct.lifts`.
    pub const part_lift = 2;

    /// `nullary.flags`.
    pub const nullary_ext = 1;
    pub const nullary_schema = 2;

    pub fn synthesisedValue(which: Synth, row: u32) Selector {
        return .{ .kind = .synthesised, .a = @backingInt(which), .b = row };
    }

    pub fn declarationPart(decl: u32, part: u32) Selector {
        return .{ .kind = .decl, .a = decl, .b = part };
    }

    /// A schema declaration's own record, or a derived codec's (`schema.md`
    /// §6, §12.10): `decl` above the module's declaration count is the
    /// codec's virtual index. `part`'s boundaries are #349's.
    pub fn schemaPart(decl: u32, part: u32) Selector {
        return .{ .kind = .schema, .a = decl, .b = part };
    }
};

/// One question the funnel answered, and the answer (`backend.md` §9, *The
/// funnel*). `where` and the meaning of `module`/`index` are the question's:
///
/// - `decl`, `derived`, `twin`, `ctor` — `module` the set's module, `index`
///   the member.
/// - `schema` — `module` the schema's, `index` `decl * Member.count + member`.
/// - `lift` — `index` the lift's own index.
/// - `arm_dead` — `index` the arm body's instruction.
/// - `probe` — `index` the dropped arm's body instruction, `where` the
///   `Variant`.
/// - `development`, `schema_library`, `schema_shapes`, `markup`, `debug` — a
///   module-level yes-or-no; `module` and `index` are 0.
/// - `consumed`, `wanted` — `index` the declaration.
/// - `nullary` — `a` in `module`, `b` in `index`, `where` the key's
///   ext/schema flags; answer true at every ask, because asking is what
///   builds the constant.
/// - `primitive` — `where` the comparator (0 `eq$prim`, 1 `compare$prim`,
///   2 `compare$char`).
/// - `entry` — a module-fixed read; `index` is not used.
/// - `core_private` — `where` the `core_private_values` slot.
/// - `direct` — a module-level yes-or-no: whether the build's direct handle
///   carries anything of THIS module (a lifted piece), which is what
///   decides whether its declarations have pieces of their own (`Lower`)
///   and whether a whole-declaration unit can be carried over.
/// - `steps` — whether derived row `index`'s synthesis appended its helper.
pub const Fact = struct {
    question: Question,
    where: u8 = 0,
    module: u32 = 0,
    index: u32 = 0,
    answer: bool,

    pub const Question = enum(u8) {
        decl = 0,
        derived = 1,
        twin = 2,
        ctor = 3,
        schema = 4,
        lift = 5,
        arm_dead = 6,
        probe = 7,
        development = 8,
        consumed = 9,
        wanted = 10,
        nullary = 11,
        primitive = 12,
        entry = 13,
        schema_library = 14,
        core_private = 15,
        debug = 16,
        markup = 17,
        direct = 18,
        steps = 19,
        /// The program's shape choice, per module (`Lower.Input.schema_shapes`,
        /// reachability's per-module fork — issue #432). False for a module
        /// whose edges came from the pack.
        schema_shapes = 20,
        /// What `Js.testHooks` is (`Lower.Input.test_hooks`).
        test_hooks = 21,
    };

    fn lessThan(a: Fact, b: Fact) bool {
        if (a.question != b.question) return @backingInt(a.question) < @backingInt(b.question);
        if (a.where != b.where) return a.where < b.where;
        if (a.module != b.module) return a.module < b.module;
        if (a.index != b.index) return a.index < b.index;
        return @intFromBool(a.answer) < @intFromBool(b.answer);
    }

    fn same(a: Fact, b: Fact) bool {
        return a.question == b.question and a.where == b.where and
            a.module == b.module and a.index == b.index;
    }
};

/// One mark: the generated BYTE offset `generated` (relative to the unit's
/// first byte), the source byte offset `source`, and the name's identity
/// `name` (an ident table index, or `no_name`).
pub const Mark = struct {
    generated: u32,
    source: u32,
    name: u32 = no_name,
};

/// One cross-module value a unit's body named (`Lower.Needed`): the module
/// by its table slot, and either the interface value or a synthesised
/// base's text — `needName`'s two forms. What the join resolves in its own
/// graph and replays in ask order.
pub const Needed = struct {
    /// A module-table slot: 0 is this module, k + 1 is `modules[k]`.
    module: u32 = 0,
    /// An index into the module's interface, or `no_value`.
    value: u32 = no_value,
    /// A string index for a synthesised name, or `no_string`.
    base: u32 = no_string,
};

/// One unit: its selector, its bytes' range in the row's `text`, and what a
/// join needs to splice it (`backend.md` §9, *What a unit carries*).
pub const Unit = struct {
    selector: Selector,
    /// Set by `Builder.addUnit` from the text it was given.
    start: u32 = 0,
    len: u32 = 0,
    marks: []const Mark = &.{},
    /// The identities the printer numbered while printing this unit, in
    /// that order.
    introduced: []const u32 = &.{},
    /// In ask order.
    needed: []const Needed = &.{},
    /// Sorted and deduplicated.
    facts: []const Fact = &.{},
    /// Which runtime exports the unit reaches: bit 0 `deep`, bit 1
    /// `listEq`, bit 2 `listCompare`.
    runtime: u8 = 0,
    /// The module's outgoing edges this unit's declaration walks, in walk
    /// order (`emissionOrder`'s `refs` then its site `tops`), as canonical
    /// positions. Empty for a unit that is not a declaration's.
    edges: []const u32 = &.{},
};

pub const runtime_deep = 1;
pub const runtime_list_eq = 2;
pub const runtime_list_compare = 4;
pub const runtime_all = 7;

/// One entry of the row's module table: a module by package and dotted name.
pub const ModuleRef = struct {
    package: SourceStore.Package,
    /// A string index.
    name: u32,
};

/// One name identity: the module part (a string index or `no_string` when
/// the name has none), the base (a string index) and the tag.
pub const Ident = struct {
    module: u32 = no_string,
    base: u32 = no_string,
    tag: u32 = 0,
};

/// A row, in memory. The maker fills one through `Builder`; `decode`
/// produces one whose slices borrow the decoded bytes.
pub const Row = struct {
    flags: Flags = .{},
    strings: []const []const u8 = &.{},
    modules: []const ModuleRef = &.{},
    idents: []const Ident = &.{},
    /// The units' text back to back: unit 0's bytes, then unit 1's, and so
    /// on, with no gaps.
    text: []const u8 = &.{},
    units: []const Unit = &.{},
};

/// Accumulates a row's tables and units, then encodes them.
pub const Builder = struct {
    gpa: Allocator,
    flags: Flags = .{},
    strings: std.ArrayList([]const u8) = .empty,
    /// A string's slot, by its bytes.
    string_slots: std.StringHashMapUnmanaged(u32) = .empty,
    modules: std.ArrayList(ModuleRef) = .empty,
    module_slots: std.AutoHashMapUnmanaged(ModuleKey, u32) = .empty,
    idents: std.ArrayList(Ident) = .empty,
    ident_slots: std.AutoHashMapUnmanaged(IdentKey, u32) = .empty,
    text: std.ArrayList(u8) = .empty,
    units: std.ArrayList(Unit) = .empty,

    const ModuleKey = struct { package: SourceStore.Package, name: u32 };
    const IdentKey = struct { module: u32, base: u32, tag: u32 };

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        for (b.units.items) |unit| b.gpa.free(unit.facts);
        b.strings.deinit(b.gpa);
        b.string_slots.deinit(b.gpa);
        b.modules.deinit(b.gpa);
        b.module_slots.deinit(b.gpa);
        b.idents.deinit(b.gpa);
        b.ident_slots.deinit(b.gpa);
        b.text.deinit(b.gpa);
        b.units.deinit(b.gpa);
        b.* = undefined;
    }

    /// The slot of `text`, adding it. A borrow of `text`, and an interned
    /// text must be stable until `encode`.
    pub fn internString(b: *Builder, text: []const u8) Allocator.Error!u32 {
        const gop = try b.string_slots.getOrPut(b.gpa, text);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.key_ptr.* = text;
        gop.value_ptr.* = @intCast(b.strings.items.len);
        try b.strings.append(b.gpa, text);
        return gop.value_ptr.*;
    }

    /// The slot of the module `package`/`name` (a string slot), adding it.
    pub fn internModule(b: *Builder, package: SourceStore.Package, name: u32) Allocator.Error!u32 {
        const gop = try b.module_slots.getOrPut(b.gpa, .{ .package = package, .name = name });
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = @intCast(b.modules.items.len);
        try b.modules.append(b.gpa, .{ .package = package, .name = name });
        return gop.value_ptr.*;
    }

    /// The slot of the identity, adding it.
    pub fn internIdent(b: *Builder, ident: Ident) Allocator.Error!u32 {
        const gop = try b.ident_slots.getOrPut(b.gpa, .{ .module = ident.module, .base = ident.base, .tag = ident.tag });
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = @intCast(b.idents.items.len);
        try b.idents.append(b.gpa, ident);
        return gop.value_ptr.*;
    }

    /// Append `unit` with `bytes` as its text: the builder appends the bytes
    /// to the row's text and records the range. The facts are copied (and
    /// normalized: sorted and deduplicated); the other slices are borrowed
    /// and must outlive `encode`.
    pub fn addUnit(b: *Builder, unit: Unit, bytes: []const u8) Allocator.Error!void {
        var copy = unit;
        copy.start = @intCast(b.text.items.len);
        copy.len = @intCast(bytes.len);
        std.debug.assert(copy.len != 0);
        try b.text.appendSlice(b.gpa, bytes);
        const sorted = try b.gpa.dupe(Fact, unit.facts);
        defer b.gpa.free(sorted);
        std.mem.sort(Fact, sorted, {}, struct {
            fn lessThan(_: void, x: Fact, y: Fact) bool {
                return Fact.lessThan(x, y);
            }
        }.lessThan);
        var kept: usize = 0;
        for (sorted) |f| {
            if (kept != 0 and Fact.same(sorted[kept - 1], f)) continue;
            sorted[kept] = f;
            kept += 1;
        }
        // One allocation of exactly the kept facts: `deinit` frees it, and
        // a shortened slice is not a freeable one.
        copy.facts = try b.gpa.dupe(Fact, sorted[0..kept]);
        errdefer b.gpa.free(copy.facts);
        try b.units.append(b.gpa, copy);
    }

    /// The row's bytes, gpa-owned.
    pub fn encode(b: *Builder, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendU32(gpa, &out, version);
        try out.append(gpa, b.flags.byte());
        try appendU32(gpa, &out, @intCast(b.strings.items.len));
        for (b.strings.items) |s| {
            try appendU32(gpa, &out, @intCast(s.len));
            try out.appendSlice(gpa, s);
        }
        try appendU32(gpa, &out, @intCast(b.modules.items.len));
        for (b.modules.items) |m| {
            try out.append(gpa, @backingInt(m.package));
            try appendU32(gpa, &out, m.name);
        }
        try appendU32(gpa, &out, @intCast(b.idents.items.len));
        for (b.idents.items) |ident| {
            try appendU32(gpa, &out, ident.module);
            try appendU32(gpa, &out, ident.base);
            try appendU32(gpa, &out, ident.tag);
        }
        try appendU32(gpa, &out, @intCast(b.text.items.len));
        try out.appendSlice(gpa, b.text.items);
        try appendU32(gpa, &out, @intCast(b.units.items.len));
        for (b.units.items, 0..) |unit, i| {
            const start: u32 = if (i == 0) 0 else b.units.items[i - 1].start + b.units.items[i - 1].len;
            std.debug.assert(unit.start == start);
            std.debug.assert(unit.len != 0 and @as(u64, unit.start) + unit.len <= b.text.items.len);
            std.debug.assert(unit.runtime & ~@as(u8, runtime_all) == 0);
            try out.append(gpa, @backingInt(unit.selector.kind));
            try out.append(gpa, unit.selector.flags);
            try appendU32(gpa, &out, unit.selector.a);
            try appendU32(gpa, &out, unit.selector.b);
            try appendU32(gpa, &out, unit.start);
            try appendU32(gpa, &out, unit.len);
            try appendU32(gpa, &out, @intCast(unit.marks.len));
            for (unit.marks) |mark| {
                std.debug.assert(mark.generated < unit.len);
                try appendU32(gpa, &out, mark.generated);
                try appendU32(gpa, &out, mark.source);
                try appendU32(gpa, &out, mark.name);
            }
            try appendU32(gpa, &out, @intCast(unit.introduced.len));
            for (unit.introduced) |ident| try appendU32(gpa, &out, ident);
            try appendU32(gpa, &out, @intCast(unit.needed.len));
            for (unit.needed) |need| {
                std.debug.assert((need.value == no_value) != (need.base == no_string));
                try appendU32(gpa, &out, need.module);
                try appendU32(gpa, &out, need.value);
                try appendU32(gpa, &out, need.base);
            }
            try appendU32(gpa, &out, @intCast(unit.facts.len));
            for (unit.facts) |fact| {
                try out.append(gpa, @backingInt(fact.question));
                try out.append(gpa, fact.where);
                try appendU32(gpa, &out, fact.module);
                try appendU32(gpa, &out, fact.index);
                try out.append(gpa, @intFromBool(fact.answer));
            }
            try out.append(gpa, unit.runtime);
            try appendU32(gpa, &out, @intCast(unit.edges.len));
            for (unit.edges) |edge| try appendU32(gpa, &out, edge);
        }
        return out.toOwnedSlice(gpa);
    }
};

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), value: u32) Allocator.Error!void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, value, .little);
    try out.appendSlice(gpa, &word);
}

/// A row's bytes as a row, in `arena`, or null when they cannot be used:
/// malformed, of another `version`, an entry out of its table's range, or
/// ranges that do not cover the text. The caller then makes the module as
/// before (`backend.md` §9: a row that cannot be used is not used).
///
/// Range checks a module's own check owns — a declaration out of its
/// module's range, an edge that is not a declaration — are the join's, not
/// this decoder's: it has no session.
pub fn decode(arena: Allocator, bytes: []const u8) Allocator.Error!?Row {
    var r: Reader = .{ .bytes = bytes };
    if ((r.word() orelse return null) != version) return null;
    const flags = r.byte() orelse return null;
    if (flags & ~Flags.all != 0) return null;

    const string_count = r.word() orelse return null;
    if (@as(u64, string_count) * 4 > r.rest()) return null;
    const strings = try arena.alloc([]const u8, string_count);
    for (strings) |*s| s.* = r.take(r.word() orelse return null) orelse return null;

    const module_count = r.word() orelse return null;
    if (@as(u64, module_count) * 5 > r.rest()) return null;
    const modules = try arena.alloc(ModuleRef, module_count);
    for (modules) |*m| {
        const package = r.byte() orelse return null;
        if (package > @backingInt(SourceStore.Package.platform)) return null;
        const name = r.word() orelse return null;
        if (name >= string_count) return null;
        m.* = .{ .package = @fromBackingInt(package), .name = name };
    }

    const ident_count = r.word() orelse return null;
    if (@as(u64, ident_count) * 12 > r.rest()) return null;
    const idents = try arena.alloc(Ident, ident_count);
    for (idents) |*ident| {
        ident.* = .{
            .module = r.word() orelse return null,
            .base = r.word() orelse return null,
            .tag = r.word() orelse return null,
        };
        if (ident.module != no_string and ident.module >= string_count) return null;
        if (ident.base == no_string or ident.base >= string_count) return null;
    }

    const text_len = r.word() orelse return null;
    const text = r.take(text_len) orelse return null;

    const unit_count = r.word() orelse return null;
    if (@as(u64, unit_count) * 29 > r.rest()) return null;
    const units = try arena.alloc(Unit, unit_count);
    var at: u32 = 0;
    for (units) |*unit| {
        unit.* = .{ .selector = .{
            .kind = std.enums.fromInt(Selector.Kind, r.byte() orelse return null) orelse return null,
            .flags = r.byte() orelse return null,
            .a = r.word() orelse return null,
            .b = r.word() orelse return null,
        } };
        unit.start = r.word() orelse return null;
        unit.len = r.word() orelse return null;
        if (unit.start != at or unit.len == 0) return null;
        if (@as(u64, unit.start) + unit.len > text.len) return null;
        at = unit.start + unit.len;

        const mark_count = r.word() orelse return null;
        if (@as(u64, mark_count) * 12 > r.rest()) return null;
        const marks = try arena.alloc(Mark, mark_count);
        for (marks) |*mark| {
            mark.* = .{
                .generated = r.word() orelse return null,
                .source = r.word() orelse return null,
                .name = r.word() orelse return null,
            };
            if (mark.generated >= unit.len) return null;
            if (mark.name != no_name and mark.name >= ident_count) return null;
        }
        unit.marks = marks;

        const introduced_count = r.word() orelse return null;
        if (@as(u64, introduced_count) * 4 > r.rest()) return null;
        const introduced = try arena.alloc(u32, introduced_count);
        for (introduced) |*ident| {
            ident.* = r.word() orelse return null;
            if (ident.* >= ident_count) return null;
        }
        unit.introduced = introduced;

        const need_count = r.word() orelse return null;
        if (@as(u64, need_count) * 12 > r.rest()) return null;
        const needed = try arena.alloc(Needed, need_count);
        for (needed) |*need| {
            need.* = .{
                .module = r.word() orelse return null,
                .value = r.word() orelse return null,
                .base = r.word() orelse return null,
            };
            if (need.module >= module_count + 1) return null;
            if ((need.value == no_value) == (need.base == no_string)) return null;
            if (need.base != no_string and need.base >= string_count) return null;
        }
        unit.needed = needed;

        const fact_count = r.word() orelse return null;
        if (@as(u64, fact_count) * 11 > r.rest()) return null;
        const facts = try arena.alloc(Fact, fact_count);
        for (facts, 0..) |*fact, i| {
            fact.* = .{
                .question = std.enums.fromInt(Fact.Question, r.byte() orelse return null) orelse return null,
                .where = r.byte() orelse return null,
                .module = r.word() orelse return null,
                .index = r.word() orelse return null,
                .answer = (r.byte() orelse return null) != 0,
            };
            if (fact.module >= module_count + 1) return null;
            if (i != 0 and !Fact.lessThan(facts[i - 1], fact.*)) return null;
        }
        unit.facts = facts;

        unit.runtime = r.byte() orelse return null;
        if (unit.runtime & ~@as(u8, runtime_all) != 0) return null;

        const edge_count = r.word() orelse return null;
        if (@as(u64, edge_count) * 4 > r.rest()) return null;
        const edges = try arena.alloc(u32, edge_count);
        for (edges) |*edge| edge.* = r.word() orelse return null;
        unit.edges = edges;
    }
    if (at != text.len) return null;
    if (r.rest() != 0) return null;

    return .{
        .flags = Flags.of(flags),
        .strings = strings,
        .modules = modules,
        .idents = idents,
        .text = text,
        .units = units,
    };
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn rest(r: *const Reader) usize {
        return r.bytes.len - r.at;
    }

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (n > r.rest()) return null;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn byte(r: *Reader) ?u8 {
        const b = r.take(1) orelse return null;
        return b[0];
    }

    fn word(r: *Reader) ?u32 {
        const b = r.take(4) orelse return null;
        return std.mem.readInt(u32, b[0..4], .little);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testRow(b: *Builder) !void {
    b.flags = .{ .deep = true, .eq_prim = true };
    const module_text = try b.internString("List");
    const base_text = try b.internString("foldl");
    const other = try b.internModule(.core, module_text);
    const ident = try b.internIdent(.{ .module = module_text, .base = base_text, .tag = 1 });
    try b.addUnit(.{
        .selector = Selector.declarationPart(3, Selector.direct),
        .marks = &.{
            .{ .generated = 0, .source = 40, .name = ident },
            .{ .generated = 12, .source = 48 },
        },
        .introduced = &.{ident},
        .needed = &.{.{ .module = other + 1, .value = 2 }},
        .facts = &.{
            .{ .question = .arm_dead, .index = 9, .answer = true },
            .{ .question = .decl, .index = 1, .answer = true },
            .{ .question = .decl, .index = 1, .answer = true },
            .{ .question = .decl, .module = other + 1, .index = 0, .answer = false },
        },
        .runtime = runtime_deep,
        .edges = &.{ 1, 2, 5 },
    }, "const a = 1;\n");
    try b.addUnit(.{
        .selector = Selector.synthesisedValue(.primitive, 0),
        .runtime = runtime_deep | runtime_list_eq,
        .facts = &.{.{ .question = .primitive, .answer = true }},
    }, "const eq$prim = 1;\n");
}

test "a row round-trips through its bytes" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try testRow(&b);
    const bytes = try b.encode(testing.allocator);
    defer testing.allocator.free(bytes);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const row = (try decode(arena_state.allocator(), bytes)) orelse return error.DecodeFailed;

    try testing.expect(row.flags.deep and row.flags.eq_prim and !row.flags.list_eq);
    try testing.expectEqual(@as(usize, 1), row.modules.len);
    try testing.expectEqualStrings("List", row.strings[row.modules[0].name]);
    try testing.expectEqual(@as(usize, 1), row.idents.len);
    try testing.expectEqualStrings("foldl", row.strings[row.idents[0].base]);
    try testing.expectEqualStrings("const a = 1;\nconst eq$prim = 1;\n", row.text);
    try testing.expectEqual(@as(usize, 2), row.units.len);

    const first = row.units[0];
    try testing.expectEqual(Selector.Kind.decl, first.selector.kind);
    try testing.expectEqual(@as(u32, 3), first.selector.a);
    try testing.expectEqual(Selector.direct, first.selector.b);
    try testing.expectEqual(@as(u32, 0), first.start);
    try testing.expectEqual(@as(u32, "const a = 1;\n".len), first.len);
    try testing.expectEqual(@as(usize, 2), first.marks.len);
    try testing.expectEqual(@as(u32, 0), first.marks[0].name);
    try testing.expectEqual(no_name, first.marks[1].name);
    try testing.expectEqualSlices(u32, &.{0}, first.introduced);
    try testing.expectEqual(@as(u32, 1), first.needed[0].module);
    try testing.expectEqual(@as(u32, 2), first.needed[0].value);
    // Sorted and deduplicated: one `decl(1)` is one fact, the group order
    // is the question's, the two modules in slot order inside it.
    try testing.expectEqual(@as(usize, 3), first.facts.len);
    try testing.expectEqual(Fact.Question.decl, first.facts[0].question);
    try testing.expectEqual(@as(u32, 0), first.facts[0].module);
    try testing.expectEqual(@as(u32, 1), first.facts[0].index);
    try testing.expect(first.facts[0].answer);
    try testing.expectEqual(Fact.Question.decl, first.facts[1].question);
    try testing.expectEqual(@as(u32, 1), first.facts[1].module);
    try testing.expectEqual(@as(u32, 0), first.facts[1].index);
    try testing.expect(!first.facts[1].answer);
    try testing.expectEqual(Fact.Question.arm_dead, first.facts[2].question);
    try testing.expectEqual(runtime_deep, first.runtime);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 5 }, first.edges);

    const second = row.units[1];
    try testing.expectEqual(@as(u32, first.len), second.start);
    try testing.expectEqual(Selector.Kind.synthesised, second.selector.kind);
    try testing.expectEqual(@as(u32, @backingInt(Selector.Synth.primitive)), second.selector.a);
    try testing.expectEqual(runtime_deep | runtime_list_eq, second.runtime);
    try testing.expectEqual(@as(usize, 0), second.edges.len);

    // A re-encode of the decoded row is the same bytes.
    var again: Builder = .init(testing.allocator);
    defer again.deinit();
    again.flags = row.flags;
    for (0..row.units.len) |i| {
        const u = row.units[i];
        const bytes_of = row.text[u.start..][0..u.len];
        try again.addUnit(.{
            .selector = u.selector,
            .marks = u.marks,
            .introduced = u.introduced,
            .needed = u.needed,
            .facts = u.facts,
            .runtime = u.runtime,
            .edges = u.edges,
        }, bytes_of);
    }
    for (row.strings) |s| _ = try again.internString(s);
    for (row.modules) |m| _ = try again.internModule(m.package, m.name);
    for (row.idents) |ident| _ = try again.internIdent(ident);
    const bytes2 = try again.encode(testing.allocator);
    defer testing.allocator.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);
}

test "a key depends on the module key and on each option" {
    const a: Key.Key = @splat(0x11);
    const b: Key.Key = @splat(0x22);
    var seen: [4]Key.Key = undefined;
    var n: usize = 0;
    for ([_]Key.Key{ a, b }) |module| {
        for (every_options) |options| {
            const k = key(module, options);
            for (seen[0..n]) |s| try testing.expect(!std.mem.eql(u8, &s, &k));
            seen[n] = k;
            n += 1;
        }
    }
    try testing.expectEqualSlices(u8, &key(a, every_options[1]), &key(a, every_options[1]));
}

test "malformed rows are refused" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try testRow(&b);
    const bytes = try b.encode(testing.allocator);
    defer testing.allocator.free(bytes);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try decode(arena, bytes)) != null);
    // A version that is not this one.
    var other = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(other);
    other[0] = 9;
    try testing.expect((try decode(arena, other)) == null);
    // A flag this version does not know.
    other[0] = 1;
    other[4] = 0x80;
    try testing.expect((try decode(arena, other)) == null);
    other[4] = b.flags.byte();
    // Truncated anywhere: never a row.
    for (0..bytes.len) |n| try testing.expect((try decode(arena, bytes[0..n])) == null);
    // A trailing byte.
    const extra = try testing.allocator.alloc(u8, bytes.len + 1);
    defer testing.allocator.free(extra);
    @memcpy(extra[0..bytes.len], bytes);
    extra[bytes.len] = 0;
    try testing.expect((try decode(arena, extra)) == null);
}

test "a unit that does not cover the text is refused" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.addUnit(.{ .selector = .{ .kind = .decl } }, "ab");
    const bytes = try b.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect((try decode(arena_state.allocator(), bytes)) != null);

    // The unit's `len` is one word, 18 bytes past the text (units count 4,
    // selector 1 + 1 + 4 + 4, start 4). The text "ab" must be covered
    // exactly; `len` 1 leaves the last byte out.
    var cut = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(cut);
    const text_end = std.mem.indexOf(u8, cut, "ab").? + 2;
    std.mem.writeInt(u32, cut[text_end + 18 ..][0..4], 1, .little);
    try testing.expect((try decode(arena_state.allocator(), cut)) == null);
}
