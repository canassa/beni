//! `beni dump --stage=interface` (docs/design/checker.md §2, §7): a module's
//! interface as text, so the record the whole firewall rests on has an
//! OUTPUT the black-box suite and the corpus goldens can assert without
//! importing it.
//!
//! ```
//! module Tree
//!   type Node a (2 ctors)
//!     Leaf
//!     Branch/2
//!   opaque type Handle
//!   foreign type Int (equatable)
//!   alias Pair a
//!   value map
//!   foreign value length
//! ```
//!
//! Types first, then values, each already in name order in the record
//! itself — the dump prints the tables as they are, which is what makes a
//! golden here a statement about the record and not about the printer. A
//! constructor's arity follows its name as `/n` and is omitted for a
//! nullary one.
//!
//! M2b fills in ` : scheme` after each value, rendered by `check/Render.zig`
//! — the same renderer every diagnostic uses, so these goldens test the
//! type text of every message too (checker.md §8.2). A scheme is printed by
//! instantiating it into a throwaway store: the interface stores terms
//! precisely so it can outlive the store it came from, and the renderer
//! reads store variables, so one of the two has to give. A run that
//! resolved names but did not check (the hermetic tests of `Interface`)
//! has no schemes and prints the names alone, which is M2a's output
//! unchanged. A declaration that failed to check prints `<error>`.
//!
//! Everything is a name or a small integer: there are no positions and no
//! symbol ids, so the output depends on the source alone and not on
//! `--jobs`.
//!
//! **`writeRaw` prints the RECORD, not this view of it** (`--stage=raw`).
//! The dump above goes through `Schemes.instantiate` and `Render`, and
//! `Render` re-sorts a record's fields by text — so it cannot see whether
//! the bytes `terms` and `extra` actually hold depend on which worker
//! interned which file. `fast-compiler.md` §8.1 has M4 hashing exactly
//! those bytes, so "the same at every `--jobs`" has to be assertable about
//! them and not about a printer that would hide a difference. That is the
//! whole reason the raw form exists; it is not meant to be read for
//! pleasure.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const Render = @import("../check/Render.zig");
const Schemes = @import("../check/Schemes.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

pub fn write(
    w: *std.Io.Writer,
    gpa: Allocator,
    module_name: []const u8,
    iface: *const Interface,
    /// This session's translation of `iface.type_refs` — `Types.refIds` of
    /// the module this record belongs to. The rendering does not print it;
    /// instantiating a scheme needs it (`Schemes.instantiate`).
    type_ids: []const TypeStore.TypeId,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
    try w.print("module {s}\n", .{module_name});
    for (iface.types) |t| {
        try w.writeAll("  ");
        if (t.is_opaque) try w.writeAll("opaque ");
        switch (t.kind) {
            .adt => try w.writeAll("type"),
            .alias => try w.writeAll("alias"),
            .foreign => try w.writeAll("foreign type"),
        }
        try w.print(" {s}", .{interner.slice(iface.symbol(t.name))});
        // The interface records an ARITY, not the parameter names the
        // source wrote: a type's identity does not depend on what its
        // parameters were called, and M4 hashes this record. The names come
        // from the type renderer's own generator, so a parameter here is
        // spelled exactly as an unnamed variable is spelled in a
        // diagnostic and in `dump --stage=types`.
        for (0..t.arity) |i| {
            const param = try Render.generatedName(gpa, @intCast(i));
            defer gpa.free(param);
            try w.print(" {s}", .{param});
        }
        if (t.is_equatable) try w.writeAll(" (equatable)");
        try w.writeByte('\n');
        for (iface.ctors[t.ctors_start..t.ctors_end]) |c| {
            try w.print("    {s}", .{interner.slice(iface.symbol(c.name))});
            if (c.arity != 0) try w.print("/{d}", .{c.arity});
            try w.writeByte('\n');
        }
    }
    for (iface.values, 0..) |v, i| {
        try w.writeAll("  ");
        if (v.is_foreign) try w.writeAll("foreign ");
        try w.print("value {s}", .{interner.slice(iface.symbol(v.name))});
        if (v.scheme != .none) {
            try w.writeAll(" : ");
            try writeScheme(w, gpa, iface, type_ids, @enumFromInt(i), types, interner);
        }
        try w.writeByte('\n');
    }
}

/// The interface's tables verbatim: every term's tag and operands, every
/// `extra` word, every scheme's quantifier block and every constructor's
/// argument range — with symbol INDICES resolved to text, because a symbol
/// id is the one thing in the record that legitimately varies (the column
/// is remapped per run) and printing it would make this dump differ for a
/// reason that is not a bug.
///
/// Written for diffing, one field per line, so a difference names itself.
pub fn writeRaw(
    w: *std.Io.Writer,
    module_name: []const u8,
    iface: *const Interface,
    interner: *const InternPool.Global,
) Error!void {
    try w.print("module {s}\n", .{module_name});
    for (iface.values, 0..) |v, i| {
        try w.print("value {d} {s} foreign={} scheme={d}\n", .{
            i,
            interner.slice(iface.symbol(v.name)),
            v.is_foreign,
            @intFromEnum(v.scheme),
        });
    }
    for (iface.types, 0..) |t, i| {
        try w.print("type {d} {s} arity={d} kind={t} opaque={} equatable={} ctors={d}..{d}\n", .{
            i,
            interner.slice(iface.symbol(t.name)),
            t.arity,
            t.kind,
            t.is_opaque,
            t.is_equatable,
            t.ctors_start,
            t.ctors_end,
        });
    }
    for (iface.ctors, 0..) |c, i| {
        try w.print("ctor {d} {s} type={d} arity={d} arg_terms={d} quantified={d}\n", .{
            i,
            interner.slice(iface.symbol(c.name)),
            @intFromEnum(c.type),
            c.arity,
            c.arg_terms,
            c.quantified_start,
        });
        if (c.arg_terms == Interface.no_terms) continue;
        for (iface.range(c.arg_terms), 0..) |word, a| try w.print("  arg {d} term={d}\n", .{ a, word });
        for (0..t: {
            const owner = @intFromEnum(c.type);
            break :t if (owner < iface.types.len) iface.types[owner].arity else 0;
        }) |q| {
            const info = iface.ctorQuantified(c, @intCast(q));
            try w.print("  param {d} kind={d} equatable={} name={s}\n", .{ q, info.kind, info.equatable, quantifiedName(iface, interner, info) });
        }
    }
    for (iface.schemes, 0..) |sch, i| {
        try w.print("scheme {d} body={d} quantified={d}\n", .{ i, @intFromEnum(sch.body), sch.quantified_count });
        for (0..sch.quantified_count) |q| {
            const info = iface.quantified(sch, @intCast(q));
            try w.print("  q {d} kind={d} equatable={} name={s} constraints={d}\n", .{
                q,
                info.kind,
                info.equatable,
                quantifiedName(iface, interner, info),
                info.constraints_len,
            });
            // The `where` block of static-dispatch-spike.md §6.5, so the
            // `--jobs=1` vs `--jobs=8` byte comparison covers it.
            for (0..info.constraints_len) |c| {
                const qc = iface.quantifiedConstraint(info, @intCast(c));
                try w.print("    where {s} term={d}\n", .{ interner.slice(iface.symbol(qc.name)), @intFromEnum(qc.type) });
            }
        }
    }
    // The types the terms name, printed as the record says them: a package,
    // a declaring module and a type name, never a session index. An `app`
    // or `alias` operand below is a row of THIS table, so an unrelated
    // module gaining a type cannot move it (`Interface.TypeRef`).
    for (iface.type_refs, 0..) |ref, i| {
        try w.print("typeref {d} {t} {s}.{s}\n", .{
            i,
            ref.package,
            interner.slice(iface.symbol(ref.module)),
            interner.slice(iface.symbol(ref.name)),
        });
    }
    const tags = iface.terms.items(.tag);
    const lhs = iface.terms.items(.lhs);
    const rhs = iface.terms.items(.rhs);
    for (tags, lhs, rhs, 0..) |tag, l, r, i| {
        try w.print("term {d} {t} {d} {d}\n", .{ i, tag, l, r });
        // A record's field pairs are `(symbol index, term)`; printing the
        // NAME is what makes a field-order difference visible as a
        // different line rather than as a different integer.
        if (tag != .record) continue;
        const words = iface.range(l);
        var f: usize = 0;
        while (f + 1 < words.len) : (f += 2) {
            try w.print("  field {s} term={d}\n", .{ interner.slice(iface.symbol(@enumFromInt(words[f]))), words[f + 1] });
        }
    }
    for (iface.extra, 0..) |word, i| try w.print("extra {d} {d}\n", .{ i, word });
}

fn quantifiedName(iface: *const Interface, interner: *const InternPool.Global, q: Interface.Quantified) []const u8 {
    const name = iface.quantifiedSymbol(q).unwrap() orelse return "-";
    return interner.slice(name);
}

/// One value's scheme. The throwaway store and arena are per value: a
/// scheme is a handful of nodes, this runs once per `pub` name, and a
/// store per call is what keeps the two instantiations of `a -> a` in two
/// different values from sharing a variable and printing as one.
fn writeScheme(
    w: *std.Io.Writer,
    gpa: Allocator,
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    value: Interface.ValueIndex,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
    const scheme = iface.valueScheme(value) orelse return w.writeAll("<error>");
    if (iface.term(scheme.body).tag == .err) return w.writeAll("<error>");
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try Schemes.instantiate(
        iface,
        type_ids,
        &store,
        @intFromEnum(iface.values[@intFromEnum(value)].scheme),
        TypeStore.generalized,
        arena.allocator(),
        null,
    );
    var namer: Render.Namer = .init(gpa);
    defer namer.deinit();
    try Render.writeScheme(w, .{ .store = &store, .types = types, .interner = interner }, &namer, v);
}
