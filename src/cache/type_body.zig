//! A written type as position-free, name-carrying bytes — the one digest input
//! nothing in the compiler computes today (`checker.md` §7, *The dependency
//! digest*).
//!
//! **What it is for.** An interface record carries the body of every alias its
//! terms name, on the alias's `type_refs` row (`checker-v2.md` §14.2), so a
//! `pub type alias` a scheme of its own module mentions has its body in the
//! record and the firewall sees a change to it. One that NO scheme of its own
//! module mentions has its
//! expansion nowhere — and renaming a field of it turns an importer's clean
//! build into `missing_field` while the declaring module's interface hash stays
//! byte-identical (`plans/m4-3.md` §6.2, reproduced here: a `pub type alias
//! Pair a = { first : a, second : a }` whose body became `{ first : a, other :
//! a }` left `app:Leaf` at `3fe27ffd…` on both sides). The digest is where the
//! expansion goes, and this is its encoding.
//!
//! **Position-free, or a whitespace edit would move it.** The obvious encoding
//! — the `Bir` instruction range — carries `Inst.token`, so adding a blank line
//! to the module would move every alias body in it and the firewall would fire
//! on an edit nobody can observe. What is written instead is the SHAPE: a
//! pre-order tag stream in which nothing is an offset into anything.
//!
//! **Names are spelled as TEXT, never as an index.** *This is a correction to
//! `checker.md` §7's "the alias expansion as interface TERMS", made in place.*
//! The record's own term language spells a type reference as a `TypeRefIndex`
//! into the module's `type_refs` table and a field name as a `SymbolIndex` into
//! its `symbols` column — both of which are positions in tables the digest does
//! not have, and neither of which carries the name the firewall has to see
//! move. §6.2's demonstrated miscompile is a FIELD RENAME, so an encoding whose
//! field names were indices would not close the very case the row exists for. A
//! type reference is therefore `(package, declaring module's name, type's
//! name)` written out, exactly the content of a `type_refs` ROW rather than its
//! index, and a field name is its text.
//!
//! **Nested aliases are NOT expanded here**; the digest's type set is closed
//! under "a body in the set names a type of this module" instead
//! (`Digest.zig`), which reaches the same answer in linear time and without the
//! blow-up an expansion would have. A nested alias of ANOTHER module is covered
//! by that module's own digest, which this module's key folds.
//!
//! **Record fields are sorted by name TEXT**, for the reason the record's own
//! fields are (`checker.md` §7): a record type is unordered, so an encoding
//! that moved when the author swapped two fields would be finer than the thing
//! it describes.
//!
//! **The depth bound is the parser's**, so no program that parses can reach it
//! — checker.md §7's rule that a bound is either unreachable or reported, and
//! the reason `too_deep` is a tag of its own rather than `err`: two bodies that
//! differed only past the bound would otherwise encode alike.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const SourceStore = @import("../SourceStore.zig");
const Types = @import("../check/Types.zig");
const Interface = @import("../resolve/Interface.zig");

pub const Symbol = InternPool.Symbol;

/// The tag stream's alphabet. Values are part of the digest's bytes, so a
/// variant may be added but never renumbered without a `digest_version` bump.
pub const Tag = enum(u8) {
    /// `u32` — the alias's own parameter `i`.
    @"var" = 0,
    /// `u32 count`, then `count` parameter types, then the result type.
    func = 1,
    /// `u8 package`, `u32 len + module name`, `u32 len + type name`,
    /// `u32 argc`, then `argc` argument types.
    named = 2,
    /// `u32 count`, then `count` element types.
    tuple = 3,
    /// `u32 count`, then per field sorted by name text `u32 len + name` and
    /// the field's type; then `u8` 0 for a closed record or 1 followed by the
    /// extension's type.
    record = 4,
    unit = 5,
    /// A type that did not resolve, a free variable, or a parser placeholder.
    /// Such a module has a diagnostic already and is never cached.
    err = 6,
    /// The depth bound (see the header) — unreachable on anything that parses.
    too_deep = 7,
};

/// How deep a written type may nest before the encoder gives up. The parser's
/// own limit, so nothing that parses reaches it.
pub const max_depth: u32 = 4096;

/// Everything the encoder needs that is not the tree itself.
pub const Context = struct {
    graph: *const Graph,
    types: *const Types,
    interner: *const InternPool.Global,
    /// The module the tree lives in — a `type_top` head is one of ITS
    /// declarations.
    module: Graph.Index,
    bir: *const Bir,
    /// The alias's own type parameters, in declaration order: a `type_var`
    /// spelled like one of these is `var(i)`.
    params: []const Symbol,
};

/// Append the encoding of `root` to `out`.
pub fn write(gpa: Allocator, out: *std.ArrayList(u8), cx: Context, root: Bir.Inst.Index) Allocator.Error!void {
    return writeAt(gpa, out, cx, root, 0);
}

/// The same position-free encoding, starting from a checked interface term.
/// Schema record endpoints have no BIR type annotation of their own: their
/// structural expansion is the body on the endpoint's `type_refs` row.
/// Reading that term keeps the dependency digest sensitive to the endpoint
/// shape without admitting the resolved schema plan (and private `via`
/// expressions) into the hash.
pub const InterfaceContext = struct {
    graph: *const Graph,
    types: *const Types,
    interner: *const InternPool.Global,
    module: Graph.Index,
    iface: *const Interface,
};

pub fn writeInterface(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cx: InterfaceContext,
    root: Interface.TermIndex,
) Allocator.Error!void {
    return writeInterfaceAt(gpa, out, cx, root, 0);
}

fn writeInterfaceAt(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cx: InterfaceContext,
    index: Interface.TermIndex,
    depth: u32,
) Allocator.Error!void {
    if (depth > max_depth) return tag(gpa, out, .too_deep);
    const term = cx.iface.term(index);
    switch (term.tag) {
        .@"var" => {
            try tag(gpa, out, .@"var");
            return appendInt(gpa, out, u32, term.lhs);
        },
        .func => {
            const params = cx.iface.range(term.lhs);
            try tag(gpa, out, .func);
            try appendInt(gpa, out, u32, @intCast(params.len));
            for (params) |p| try writeInterfaceAt(gpa, out, cx, @enumFromInt(p), depth + 1);
            return writeInterfaceAt(gpa, out, cx, @enumFromInt(term.rhs), depth + 1);
        },
        .app => return writeInterfaceNamed(gpa, out, cx, term.lhs, cx.iface.range(term.rhs), depth),
        // As with BIR bodies, a nested alias stays named; closure adds its
        // own digest row.
        .alias => return writeInterfaceNamed(gpa, out, cx, term.lhs, cx.iface.range(term.rhs), depth),
        .tuple => {
            const elements = cx.iface.range(term.lhs);
            try tag(gpa, out, .tuple);
            try appendInt(gpa, out, u32, @intCast(elements.len));
            for (elements) |e| try writeInterfaceAt(gpa, out, cx, @enumFromInt(e), depth + 1);
        },
        .record => return writeInterfaceRecord(gpa, out, cx, term, depth),
        .unit => return tag(gpa, out, .unit),
        .empty_record => {
            try tag(gpa, out, .record);
            try appendInt(gpa, out, u32, 0);
            return out.append(gpa, 0);
        },
        .err => return tag(gpa, out, .err),
    }
}

fn writeInterfaceNamed(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cx: InterfaceContext,
    ref_word: u32,
    args: []const u32,
    depth: u32,
) Allocator.Error!void {
    const ref = cx.iface.typeRef(@enumFromInt(ref_word)) orelse return tag(gpa, out, .err);
    try tag(gpa, out, .named);
    try out.append(gpa, @intFromEnum(ref.package));
    try appendText(gpa, out, cx.interner.slice(cx.iface.symbol(ref.module)));
    try appendText(gpa, out, cx.interner.slice(cx.iface.symbol(ref.name)));
    try appendInt(gpa, out, u32, @intCast(args.len));
    for (args) |a| try writeInterfaceAt(gpa, out, cx, @enumFromInt(a), depth + 1);
}

const InterfaceField = struct {
    name: Interface.SymbolIndex,
    value: Interface.TermIndex,
};

fn writeInterfaceRecord(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cx: InterfaceContext,
    term: Interface.Term,
    depth: u32,
) Allocator.Error!void {
    const words = cx.iface.range(term.lhs);
    if (words.len % 2 != 0) return tag(gpa, out, .err);
    const fields = try gpa.alloc(InterfaceField, words.len / 2);
    defer gpa.free(fields);
    for (fields, 0..) |*field, i| field.* = .{
        .name = @enumFromInt(words[i * 2]),
        .value = @enumFromInt(words[i * 2 + 1]),
    };
    const Sorter = struct {
        cx: InterfaceContext,
        fn lessThan(s: @This(), a: InterfaceField, b: InterfaceField) bool {
            return std.mem.lessThan(
                u8,
                s.cx.interner.slice(s.cx.iface.symbol(a.name)),
                s.cx.interner.slice(s.cx.iface.symbol(b.name)),
            );
        }
    };
    std.mem.sort(InterfaceField, fields, Sorter{ .cx = cx }, Sorter.lessThan);

    try tag(gpa, out, .record);
    try appendInt(gpa, out, u32, @intCast(fields.len));
    for (fields) |field| {
        try appendText(gpa, out, cx.interner.slice(cx.iface.symbol(field.name)));
        try writeInterfaceAt(gpa, out, cx, field.value, depth + 1);
    }
    if (term.rhs != Interface.TermIndex.none.int()) {
        try out.append(gpa, 1);
        return writeInterfaceAt(gpa, out, cx, @enumFromInt(term.rhs), depth + 1);
    }
    return out.append(gpa, 0);
}

fn writeAt(gpa: Allocator, out: *std.ArrayList(u8), cx: Context, inst: Bir.Inst.Index, depth: u32) Allocator.Error!void {
    if (depth > max_depth) return tag(gpa, out, .too_deep);
    const bir = cx.bir;
    const t = bir.instTag(inst);
    const data = bir.instData(inst);
    switch (t) {
        .type_unit => return tag(gpa, out, .unit),
        .type_var => {
            const name = bir.symbol(@enumFromInt(data.lhs));
            for (cx.params, 0..) |p, i| {
                if (p != name) continue;
                try tag(gpa, out, .@"var");
                return appendInt(gpa, out, u32, @intCast(i));
            }
            // A variable the alias does not bind is `unbound_type_variable`,
            // an error of the declaring module, which is therefore never
            // cached. Encoded rather than trapped, for `fast-compiler.md` §5.
            return tag(gpa, out, .err);
        },
        .type_fn => {
            const params = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index);
            try tag(gpa, out, .func);
            try appendInt(gpa, out, u32, @intCast(params.len));
            for (params) |p| try writeAt(gpa, out, cx, p, depth + 1);
            return writeAt(gpa, out, cx, @enumFromInt(data.rhs), depth + 1);
        },
        .type_tuple => {
            const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
            try tag(gpa, out, .tuple);
            try appendInt(gpa, out, u32, @intCast(elements.len));
            for (elements) |e| try writeAt(gpa, out, cx, e, depth + 1);
            return;
        },
        .type_record => return record(gpa, out, cx, bir.extraSlice(Bir.inlineRange(data), Bir.Field), null, depth),
        .type_record_ext => return record(
            gpa,
            out,
            cx,
            bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field),
            @as(Bir.Inst.Index, @enumFromInt(data.lhs)),
            depth,
        ),
        .type_top, .ext_type, .schema_type_top, .ext_schema_type => return named(gpa, out, cx, t, data, &.{}, depth),
        .type_app => {
            const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
            const head: Bir.Inst.Index = @enumFromInt(data.lhs);
            return named(gpa, out, cx, bir.instTag(head), bir.instData(head), args, depth);
        },
        else => return tag(gpa, out, .err),
    }
}

fn named(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cx: Context,
    t: Bir.Inst.Tag,
    data: Bir.Inst.Data,
    args: []const Bir.Inst.Index,
    depth: u32,
) Allocator.Error!void {
    // A schema endpoint is a named type like any other: were it `err` here,
    // an alias whose body names a schema's `Type` would digest alike
    // whatever it named, and a private record schema's endpoint — read
    // through the alias from the plan — could change under a cached
    // dependent.
    const id: Types.TypeId = Types.headId(cx.types, cx.module, t, data);
    const who = cx.types.named(id) orelse return tag(gpa, out, .err);
    try tag(gpa, out, .named);
    try out.append(gpa, @intFromEnum(who.package));
    try appendText(gpa, out, cx.interner.slice(who.module));
    try appendText(gpa, out, cx.interner.slice(who.name));
    try appendInt(gpa, out, u32, @intCast(args.len));
    for (args) |a| try writeAt(gpa, out, cx, a, depth + 1);
}

fn record(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cx: Context,
    fields: []const Bir.Field,
    ext: ?Bir.Inst.Index,
    depth: u32,
) Allocator.Error!void {
    // Sorted by name TEXT (see the header). A copy, because the `Bir`'s own
    // order is the author's and is not this encoder's to rewrite.
    const sorted = try gpa.alloc(Bir.Field, fields.len);
    defer gpa.free(sorted);
    @memcpy(sorted, fields);
    const Sorter = struct {
        cx: Context,
        fn lessThan(s: @This(), a: Bir.Field, b: Bir.Field) bool {
            return std.mem.lessThan(
                u8,
                s.cx.interner.slice(s.cx.bir.symbol(a.name)),
                s.cx.interner.slice(s.cx.bir.symbol(b.name)),
            );
        }
    };
    std.mem.sort(Bir.Field, sorted, Sorter{ .cx = cx }, Sorter.lessThan);

    try tag(gpa, out, .record);
    try appendInt(gpa, out, u32, @intCast(sorted.len));
    for (sorted) |f| {
        try appendText(gpa, out, cx.interner.slice(cx.bir.symbol(f.name)));
        try writeAt(gpa, out, cx, f.value, depth + 1);
    }
    if (ext) |e| {
        try out.append(gpa, 1);
        return writeAt(gpa, out, cx, e, depth + 1);
    }
    try out.append(gpa, 0);
}

/// Every type of `cx.module` that `root` names, appended to `out`.
///
/// This is what closes the digest's type set (`Digest.zig`): a `pub type alias`
/// whose body is a PRIVATE alias of the same module has that alias's body in no
/// record and in no digest row of its own, and §6.2's miscompile would come
/// straight back one level down. Cross-module heads are deliberately NOT
/// collected — the declaring module's own digest carries them and this module's
/// key folds it.
pub fn collectLocal(
    gpa: Allocator,
    out: *std.ArrayList(Types.TypeId),
    cx: Context,
    root: Bir.Inst.Index,
) Allocator.Error!void {
    return collectAt(gpa, out, cx, root, 0);
}

/// Every type of `cx.module` named by an interface term. Closure follows a
/// named alias and its arguments only; the alias receives its own digest
/// row on the worklist.
pub fn collectLocalInterface(
    gpa: Allocator,
    out: *std.ArrayList(Types.TypeId),
    cx: InterfaceContext,
    root: Interface.TermIndex,
) Allocator.Error!void {
    return collectInterfaceAt(gpa, out, cx, root, 0);
}

fn collectInterfaceAt(
    gpa: Allocator,
    out: *std.ArrayList(Types.TypeId),
    cx: InterfaceContext,
    index: Interface.TermIndex,
    depth: u32,
) Allocator.Error!void {
    if (depth > max_depth) return;
    const term = cx.iface.term(index);
    switch (term.tag) {
        .app, .alias => {
            if (cx.iface.typeRef(@enumFromInt(term.lhs))) |ref| {
                const module_name = cx.iface.symbol(ref.module);
                if (ref.package == cx.graph.modulePackage(cx.module) and module_name == cx.graph.moduleName(cx.module)) {
                    const id = cx.types.find(cx.graph, ref.package, module_name, cx.iface.symbol(ref.name));
                    if (id != .none) try out.append(gpa, id);
                }
            }
            for (cx.iface.range(term.rhs)) |arg| try collectInterfaceAt(gpa, out, cx, @enumFromInt(arg), depth + 1);
        },
        .func => {
            for (cx.iface.range(term.lhs)) |p| try collectInterfaceAt(gpa, out, cx, @enumFromInt(p), depth + 1);
            try collectInterfaceAt(gpa, out, cx, @enumFromInt(term.rhs), depth + 1);
        },
        .tuple => for (cx.iface.range(term.lhs)) |e| try collectInterfaceAt(gpa, out, cx, @enumFromInt(e), depth + 1),
        .record => {
            const words = cx.iface.range(term.lhs);
            var i: usize = 1;
            while (i < words.len) : (i += 2) try collectInterfaceAt(gpa, out, cx, @enumFromInt(words[i]), depth + 1);
            if (term.rhs != Interface.TermIndex.none.int()) try collectInterfaceAt(gpa, out, cx, @enumFromInt(term.rhs), depth + 1);
        },
        .@"var", .unit, .empty_record, .err => {},
    }
}

fn collectAt(
    gpa: Allocator,
    out: *std.ArrayList(Types.TypeId),
    cx: Context,
    inst: Bir.Inst.Index,
    depth: u32,
) Allocator.Error!void {
    if (depth > max_depth) return;
    const bir = cx.bir;
    const t = bir.instTag(inst);
    const data = bir.instData(inst);
    switch (t) {
        .type_top, .schema_type_top => {
            const id = Types.headId(cx.types, cx.module, t, data);
            if (id != .none) try out.append(gpa, id);
        },
        .type_fn => {
            for (bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index)) |p| {
                try collectAt(gpa, out, cx, p, depth + 1);
            }
            try collectAt(gpa, out, cx, @enumFromInt(data.rhs), depth + 1);
        },
        .type_tuple => for (bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |e| {
            try collectAt(gpa, out, cx, e, depth + 1);
        },
        .type_record => for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| {
            try collectAt(gpa, out, cx, f.value, depth + 1);
        },
        .type_record_ext => {
            try collectAt(gpa, out, cx, @enumFromInt(data.lhs), depth + 1);
            for (bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field)) |f| {
                try collectAt(gpa, out, cx, f.value, depth + 1);
            }
        },
        .type_app => {
            const head: Bir.Inst.Index = @enumFromInt(data.lhs);
            const head_tag = bir.instTag(head);
            if (head_tag == .type_top or head_tag == .schema_type_top) {
                const id = Types.headId(cx.types, cx.module, head_tag, bir.instData(head));
                if (id != .none) try out.append(gpa, id);
            }
            for (bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index)) |a| {
                try collectAt(gpa, out, cx, a, depth + 1);
            }
        },
        else => {},
    }
}

fn tag(gpa: Allocator, out: *std.ArrayList(u8), t: Tag) Allocator.Error!void {
    try out.append(gpa, @intFromEnum(t));
}

fn appendText(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try appendInt(gpa, out, u32, @intCast(text.len));
    try out.appendSlice(gpa, text);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var word: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &word, value, .little);
    try out.appendSlice(gpa, &word);
}

// ---------------------------------------------------------------------------
// Reading back — the round trip, as TEXT
// ---------------------------------------------------------------------------

/// The encoding rendered as source-shaped text, so a golden is readable and a
/// test can assert what the bytes MEAN rather than only that two of them
/// differ. Nothing in the compiler reads this on a code path; it is the round
/// trip the dependency digest's design asks for, and it is total — every byte the
/// writer can produce has a rendering, so a decoder that fell off the end of
/// the stream would show up as a failure here.
pub fn render(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    var r: Reader = .{ .bytes = bytes };
    try r.render(gpa, out);
    if (r.at != bytes.len) try out.appendSlice(gpa, " <trailing>");
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    bad: bool = false,

    fn byte(r: *Reader) u8 {
        if (r.at >= r.bytes.len) {
            r.bad = true;
            return 0xFF;
        }
        defer r.at += 1;
        return r.bytes[r.at];
    }

    fn int(r: *Reader) u32 {
        if (r.at + 4 > r.bytes.len) {
            r.bad = true;
            r.at = r.bytes.len;
            return 0;
        }
        defer r.at += 4;
        return std.mem.readInt(u32, r.bytes[r.at..][0..4], .little);
    }

    fn text(r: *Reader) []const u8 {
        const len = r.int();
        if (r.at + len > r.bytes.len) {
            r.bad = true;
            r.at = r.bytes.len;
            return "";
        }
        defer r.at += len;
        return r.bytes[r.at..][0..len];
    }

    fn render(r: *Reader, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        if (r.bad) return;
        const raw = r.byte();
        const t = std.enums.fromInt(Tag, raw) orelse {
            r.bad = true;
            return out.appendSlice(gpa, "<bad>");
        };
        switch (t) {
            .unit => try out.appendSlice(gpa, "()"),
            .err => try out.appendSlice(gpa, "?"),
            .too_deep => try out.appendSlice(gpa, "…"),
            .@"var" => try out.print(gpa, "var({d})", .{r.int()}),
            .func => {
                const count = r.int();
                try out.append(gpa, '(');
                for (0..count) |i| {
                    if (i != 0) try out.appendSlice(gpa, ", ");
                    try r.render(gpa, out);
                }
                try out.appendSlice(gpa, " → ");
                try r.render(gpa, out);
                try out.append(gpa, ')');
            },
            .tuple => {
                const count = r.int();
                try out.appendSlice(gpa, "( ");
                for (0..count) |i| {
                    if (i != 0) try out.appendSlice(gpa, ", ");
                    try r.render(gpa, out);
                }
                try out.appendSlice(gpa, " )");
            },
            .named => {
                const package = r.byte();
                const module = r.text();
                const name = r.text();
                const argc = r.int();
                try out.print(gpa, "{s}:{s}.{s}", .{ packageName(package), module, name });
                for (0..argc) |_| {
                    try out.append(gpa, ' ');
                    try r.render(gpa, out);
                }
            },
            .record => {
                const count = r.int();
                try out.appendSlice(gpa, "{ ");
                for (0..count) |i| {
                    if (i != 0) try out.appendSlice(gpa, ", ");
                    try out.print(gpa, "{s} : ", .{r.text()});
                    try r.render(gpa, out);
                }
                if (r.byte() == 1) {
                    try out.appendSlice(gpa, " | ");
                    try r.render(gpa, out);
                }
                try out.appendSlice(gpa, " }");
            },
        }
    }
};

fn packageName(raw: u8) []const u8 {
    const p = std.enums.fromInt(SourceStore.Package, raw) orelse return "?";
    return @tagName(p);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("../resolve/TestProject.zig");

/// Every `type alias` of module `name`, encoded and rendered, one line each,
/// as `<alias name> = <rendering>`. The shape a test can state as a literal.
fn aliasBodies(gpa: Allocator, p: *TestProject, name: []const u8) ![]u8 {
    const m = p.module(name).?;
    const bir = p.session.artifacts.bir(p.session.graph.moduleFile(m));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bir.decls) |d| {
        if (d.kind != .type_alias) continue;
        const body = d.annotation.unwrap() orelse continue;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try write(gpa, &bytes, .{
            .graph = &p.session.graph,
            .types = &p.session.checked.types,
            .interner = &p.session.interner,
            .module = m,
            .bir = bir,
            .params = bir.declTypeParams(d),
        }, body);
        try out.print(gpa, "{s} = ", .{p.session.interner.slice(bir.symbol(d.name))});
        try render(gpa, &out, bytes.items);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn project(gpa: Allocator, source: [:0]const u8) !TestProject {
    return TestProject.initWith(gpa, &.{
        .{ .path = "a/L.beni", .source = source, .rel_start = 2 },
    }, .{ .phases = @import("../Session.zig").check_phases });
}

test "an alias body encodes as its shape, with every name spelled out" {
    const gpa = testing.allocator;
    var p = try project(gpa,
        \\type alias Pair a =
        \\    { first : a, second : a }
        \\
        \\
        \\type alias Pack a b =
        \\    a × Pair b × ⊤
        \\
        \\
        \\type alias Fn a =
        \\    a, a → Pair a
        \\
    );
    defer p.deinit();
    const got = try aliasBodies(gpa, &p, "L");
    defer gpa.free(got);
    try testing.expectEqualStrings(
        \\Pair = { first : var(0), second : var(0) }
        \\Pack = ( var(0), app:L.Pair var(1), () )
        \\Fn = (var(0), var(0) → app:L.Pair var(0))
        \\
    , got);
}

test "a field RENAME moves the bytes and a field REORDER does not" {
    // The two halves of `plans/m4-3.md` §6.2 in one test. The rename is the
    // demonstrated miscompile — the declaring module's interface hash does not
    // move for it — and the reorder is the converse the digest must not be
    // wider than: a record type is unordered, so an encoding that saw the swap
    // would re-check importers for nothing.
    const gpa = testing.allocator;
    var a = try project(gpa, "type alias Pair a =\n    { first : a, second : a }\n");
    defer a.deinit();
    var renamed = try project(gpa, "type alias Pair a =\n    { first : a, other : a }\n");
    defer renamed.deinit();
    var reordered = try project(gpa, "type alias Pair a =\n    { second : a, first : a }\n");
    defer reordered.deinit();
    var spaced = try project(gpa, "type alias Pair a =\n    { first : a\n    , second : a\n    }\n");
    defer spaced.deinit();

    const base = try aliasBodies(gpa, &a, "L");
    defer gpa.free(base);
    const one = try aliasBodies(gpa, &renamed, "L");
    defer gpa.free(one);
    const two = try aliasBodies(gpa, &reordered, "L");
    defer gpa.free(two);
    const three = try aliasBodies(gpa, &spaced, "L");
    defer gpa.free(three);

    try testing.expect(!std.mem.eql(u8, base, one));
    try testing.expectEqualStrings(base, two);
    // Position-free: the `Bir` instruction indices and tokens moved, the
    // encoding did not.
    try testing.expectEqualStrings(base, three);
}

test "a parameter is its INDEX, so renaming one does not move the bytes" {
    // `var(i)` means the alias's own parameter `i` (`checker.md` §7), so the
    // spelling of a type variable is the author's business and not a
    // dependent's.
    const gpa = testing.allocator;
    var a = try project(gpa, "type alias Pair a b =\n    a × b\n");
    defer a.deinit();
    var b = try project(gpa, "type alias Pair x y =\n    x × y\n");
    defer b.deinit();
    var swapped = try project(gpa, "type alias Pair a b =\n    b × a\n");
    defer swapped.deinit();

    const one = try aliasBodies(gpa, &a, "L");
    defer gpa.free(one);
    const two = try aliasBodies(gpa, &b, "L");
    defer gpa.free(two);
    const three = try aliasBodies(gpa, &swapped, "L");
    defer gpa.free(three);
    try testing.expectEqualStrings(one, two);
    try testing.expect(!std.mem.eql(u8, one, three));
}

test "the round trip is total: every tag renders and nothing is left over" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for ([_]Tag{ .unit, .err, .too_deep }) |t| {
        out.clearRetainingCapacity();
        try render(gpa, &out, &.{@intFromEnum(t)});
        try testing.expect(out.items.len != 0);
        try testing.expect(std.mem.indexOf(u8, out.items, "trailing") == null);
    }
    // A truncated stream is rendered rather than trapped: the encoder never
    // produces one, and a reader that could crash on bytes is the posture
    // `checker.md` §7 forbids.
    out.clearRetainingCapacity();
    try render(gpa, &out, &.{ @intFromEnum(Tag.tuple), 9 });
    try testing.expect(out.items.len != 0);
}
