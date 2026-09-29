//! The vocabulary a module's markup is typed against (checker-v2.md §25.1,
//! §25.2): the element, attribute and event rows of the build's vocabulary
//! module, and how a markup name resolves to one.
//!
//! **One view, two sources.** An importer reads the vocabulary module's
//! published interface. The vocabulary module itself writes markup against
//! its own declarations, which P2 and `Vocab.check` have read before any
//! value group, so it reads its own interface skeleton, the declarations
//! behind it, and their failure bits: a row whose declaration failed is
//! absent, exactly as publication will leave it out (§25.2), so the row
//! indices here are the published ones.
//!
//! **Every resolution is a function of the name's text and the rows**
//! (I13): exact before pattern, and of two patterns the longer literal part;
//! an attribute or event scoped to the element (`on`) before one of every
//! element. The rows are sorted by name text, so an exact name is a binary
//! search.
//!
//! Each row's type — an attribute's value type, an event's payload — is
//! read once, at rank `generalized`, the first time a use asks for it;
//! every use copies it (`instantiate`), so nothing one use unifies reaches
//! another.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const InterfaceTerms = @import("InterfaceTerms.zig");
const Context = @import("Context.zig");
const Vocab = @import("Vocab.zig");
const Dispatch = @import("Dispatch.zig");
const MarkupDecide = @import("MarkupDecide.zig");

const Markup = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

pub const Form = enum(u8) { element, attribute, event };

/// No row: a published row index's sentinel.
pub const no_row: u32 = std.math.maxInt(u32);

pub const Row = struct {
    form: Form,
    /// The row's index in the published table of its form.
    index: u32,
    name: Symbol,
    /// Where the name's `*` is, for a pattern.
    star: ?u32,
    /// `Interface.VocabRow.facts`.
    facts: u32,
    /// The `on` element names; empty for every element.
    on: []const Symbol,
    /// An event's `via` extractor.
    via: Symbol.Optional,
    /// Where the type comes from: this module's declaration, or the
    /// interface's scheme.
    decl: ?Bir.DeclIndex,
    scheme: Interface.SchemeIndex,
    /// The type, once read; at rank `generalized`.
    type: Var.Optional = .none,

    pub fn has(row: Row, word: Bir.FactWord) bool {
        return row.facts & (@as(u32, 1) << @intCast(@intFromEnum(word))) != 0;
    }

    fn literalLen(row: Row, cx: *const Context) usize {
        return cx.interner.slice(row.name).len - @intFromBool(row.star != null);
    }
};

cx: *const Context,
/// The markup type `H` of `H msg`, or `.none` when it did not resolve.
markup_type: Types.TypeId,
vocabulary: Graph.Index,
/// The vocabulary module's own `decl_scheme`, when this module is it.
own_schemes: []const Var.Optional = &.{},
elements: []Row,
attributes: []Row,
events: []Row,

/// The view for a module that writes markup, or null when the build has
/// no vocabulary (the module then has its `no_markup_vocabulary`).
/// `provenance` and `failed` are this module's, read only when it is the
/// vocabulary module itself.
pub fn build(
    cx: *const Context,
    provenance: *const Interface.Provenance,
    failed: *const std.DynamicBitSetUnmanaged,
    decl_scheme: []const Var.Optional,
) Error!?Markup {
    const graph = cx.graph;
    if (graph.markup.status != .ok) return null;
    const vocabulary = graph.markup.vocabulary orelse return null;
    const own = vocabulary == cx.module;
    const iface: *const Interface = if (own) &cx.interfaces[cx.module.int()] else cx.iface(vocabulary);
    var m: Markup = .{
        .cx = cx,
        .markup_type = markupTypeId(cx),
        .vocabulary = vocabulary,
        .own_schemes = if (own) decl_scheme else &.{},
        .elements = &.{},
        .attributes = &.{},
        .events = &.{},
    };
    var at: usize = 0;
    inline for (.{ .element, .attribute, .event }, .{ "elements", "attributes", "events" }) |form, field| {
        const table = @field(iface, field);
        var rows: std.ArrayList(Row) = .empty;
        for (table) |r| {
            const decl: ?Bir.DeclIndex = if (own) blk: {
                const d = if (at < provenance.vocab_decl.len) provenance.vocab_decl[at] else null;
                at += 1;
                break :blk d orelse continue;
            } else null;
            if (decl) |d| if (d.int() < failed.bit_length and failed.isSet(d.int())) continue;
            const name = iface.symbol(r.name);
            const text = cx.interner.slice(name);
            var on: std.ArrayList(Symbol) = .empty;
            if (r.on != Interface.no_terms and r.on < iface.extra.len) {
                const len = iface.extra[r.on];
                for (iface.extra[r.on + 1 ..][0..len]) |s| try on.append(cx.scratch, iface.symbol(@enumFromInt(s)));
            }
            try rows.append(cx.scratch, .{
                .form = form,
                .index = @intCast(rows.items.len),
                .name = name,
                .star = if (std.mem.indexOfScalar(u8, text, '*')) |s| @intCast(s) else null,
                .facts = r.facts,
                .on = on.items,
                .via = if (r.via.unwrap()) |v| iface.symbol(v).toOptional() else .none,
                .decl = decl,
                .scheme = r.scheme,
            });
        }
        @field(m, field) = rows.items;
    }
    return m;
}

/// The build's markup type, by the names the manifest gives.
fn markupTypeId(cx: *const Context) Types.TypeId {
    const module = cx.graph.markup.type_module.unwrap() orelse return .none;
    const name = cx.graph.markup.type_name.unwrap() orelse return .none;
    return cx.types.find(cx.graph, .platform, module, name);
}

/// The row's type, at rank `generalized`, or null when it has none that
/// can be read (a failed declaration's, or a dependency's `<error>`).
pub fn typeOf(m: *Markup, row: *Row) Error!?Var {
    if (row.type.unwrap()) |v| return v;
    const cx = m.cx;
    const v: Var = if (row.decl) |d| blk: {
        if (d.int() >= m.own_schemes.len) return null;
        break :blk m.own_schemes[d.int()].unwrap() orelse return null;
    } else blk: {
        if (row.scheme == .none) return null;
        const iface = cx.iface(m.vocabulary);
        if (@intFromEnum(row.scheme) >= iface.schemes.len) return null;
        break :blk try InterfaceTerms.instantiate(iface, cx.types.refIds(m.vocabulary), cx.store, @intFromEnum(row.scheme), TypeStore.generalized, cx.scratch);
    };
    row.type = v.toOptional();
    return v;
}

/// Which of the five value types an attribute row's type is.
pub fn classOf(m: *Markup, row: *Row) Error!?Vocab.ValueClass {
    const v = try m.typeOf(row) orelse return null;
    if (m.cx.store.resolvedContent(v) == .err) return null;
    return Vocab.valueClass(m.cx, v);
}

// ---------------------------------------------------------------------------
// Resolution (§25.2)
// ---------------------------------------------------------------------------

/// The element row a tag resolves to: an exact name, then the most specific
/// pattern.
pub fn element(m: *Markup, name: Symbol) ?*Row {
    return m.exact(m.elements, name, null, .any) orelse m.pattern(m.elements, name, null, .any);
}

/// The attribute or event row an item named `name` on the element `tag`
/// resolves to: one scoped to the element before one of every element, each
/// by exact name, then by pattern. Attributes and events share the name
/// space.
pub fn item(m: *Markup, tag: Symbol, name: Symbol) ?*Row {
    inline for (.{ Scope.scoped, Scope.unscoped }) |scope| {
        if (m.exact(m.attributes, name, tag, scope) orelse m.exact(m.events, name, tag, scope)) |r| return r;
        const a = m.pattern(m.attributes, name, tag, scope);
        const e = m.pattern(m.events, name, tag, scope);
        if (a != null and e != null) return if (e.?.literalLen(m.cx) > a.?.literalLen(m.cx)) e else a;
        if (a orelse e) |r| return r;
    }
    return null;
}

const Scope = enum { any, scoped, unscoped };

fn inScope(row: Row, tag: ?Symbol, scope: Scope) bool {
    return switch (scope) {
        .any => true,
        .unscoped => row.on.len == 0,
        .scoped => row.on.len != 0 and std.mem.indexOfScalar(Symbol, row.on, tag.?) != null,
    };
}

fn exact(m: *Markup, rows: []Row, name: Symbol, tag: ?Symbol, scope: Scope) ?*Row {
    const text = m.cx.interner.slice(name);
    const Cx = struct {
        interner: *const InternPool.Global,
        key: []const u8,
        fn order(c: @This(), row: Row) std.math.Order {
            return std.mem.order(u8, c.key, c.interner.slice(row.name));
        }
    };
    var i = std.sort.lowerBound(Row, rows, Cx{ .interner = m.cx.interner, .key = text }, Cx.order);
    while (i < rows.len and rows[i].name == name) : (i += 1) {
        if (rows[i].star == null and inScope(rows[i], tag, scope)) return &rows[i];
    }
    return null;
}

fn pattern(m: *Markup, rows: []Row, name: Symbol, tag: ?Symbol, scope: Scope) ?*Row {
    const text = m.cx.interner.slice(name);
    var best: ?*Row = null;
    for (rows) |*r| {
        const star = r.star orelse continue;
        if (!inScope(r.*, tag, scope)) continue;
        const p = m.cx.interner.slice(r.name);
        const prefix = p[0..star];
        const suffix = p[star + 1 ..];
        // `*` matches a non-empty run of name characters.
        if (text.len <= prefix.len + suffix.len) continue;
        if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, suffix)) continue;
        if (best == null or r.literalLen(m.cx) > best.?.literalLen(m.cx)) best = r;
    }
    return best;
}

// ---------------------------------------------------------------------------
// The markup section of the record (§25.7)
// ---------------------------------------------------------------------------

/// One row per node the checker decided something about: every markup root
/// in instruction order, each tree depth first, items before children. Read
/// off the tree, the rows and what the solver decided (`decisions`, sorted
/// here); called only for a module that checked clean, where every name
/// resolved and every obligation was decided.
pub fn section(m: *Markup, gpa: Allocator, decisions: []MarkupDecide.Decision) Error![]Dispatch.Markup {
    std.mem.sort(MarkupDecide.Decision, decisions, {}, decisionLessThan);
    var s: Section = .{ .m = m, .gpa = gpa, .decisions = decisions };
    errdefer s.out.deinit(gpa);
    const bir = m.cx.bir;
    const tags = bir.insts.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .markup) continue;
        s.root = @enumFromInt(i);
        try s.node(@enumFromInt(bir.instData(s.root).lhs));
    }
    return s.out.toOwnedSlice(gpa);
}

fn decisionLessThan(_: void, a: MarkupDecide.Decision, b: MarkupDecide.Decision) bool {
    return a.at < b.at;
}

const Section = struct {
    m: *Markup,
    gpa: Allocator,
    decisions: []const MarkupDecide.Decision,
    root: Bir.Inst.Index = @enumFromInt(0),
    out: std.ArrayList(Dispatch.Markup) = .empty,

    fn decided(s: *const Section, at: Bir.ExtraIndex) u8 {
        const key = @intFromEnum(at);
        const i = std.sort.lowerBound(MarkupDecide.Decision, s.decisions, key, struct {
            fn order(k: u32, d: MarkupDecide.Decision) std.math.Order {
                return std.math.order(k, d.at);
            }
        }.order);
        return if (i < s.decisions.len and s.decisions[i].at == key) s.decisions[i].value else 0;
    }

    fn add(s: *Section, row: Dispatch.Markup) Error!void {
        var r = row;
        r.root = s.root;
        try s.out.append(s.gpa, r);
    }

    fn node(s: *Section, at: Bir.ExtraIndex) Error!void {
        const bir = s.m.cx.bir;
        switch (bir.markupKind(at)) {
            .element => {
                const e = bir.extraData(at, Bir.MarkupElement);
                const tag = bir.symbol(e.name);
                const row = s.m.element(tag);
                try s.add(.{ .root = s.root, .node = @intFromEnum(at), .kind = .element, .row = if (row) |r| r.index else Dispatch.Markup.no_row });
                for (bir.extraSlice(.{ .start = e.items_start, .end = e.items_end }, Bir.ExtraIndex)) |i| try s.item(tag, i);
                try s.children(e.children_start, e.children_end);
            },
            .fragment => {
                const f = bir.extraData(at, Bir.MarkupFragment);
                try s.children(f.children_start, f.children_end);
            },
            .text => {},
            .hole => try s.add(.{ .root = s.root, .node = @intFromEnum(at), .kind = .hole, .detail = s.decided(at) }),
            // A component is an ordinary call: its site is an ordinary
            // site. Children written as markup are this root's nodes.
            .component => {
                const c = bir.extraData(at, Bir.MarkupComponent);
                if (c.children_form == .fragment) try s.children(c.children_start, c.children_end);
            },
            .@"for", .show => {
                const f = bir.extraData(at, Bir.MarkupForm);
                const is_for = bir.markupKind(at) == .@"for";
                const detail: u8 = if (is_for) @intFromEnum(switch (f.mode) {
                    .key_function => Dispatch.Markup.ForMode.key,
                    .literal_false => .position,
                    .literal_true, .absent => .reference,
                }) else @intFromEnum(if (f.mode == .key_function) Dispatch.Markup.ShowMode.key else .identity);
                var arity: u8 = 1;
                if (f.row != Bir.none_extra) {
                    const r = bir.extraData(@enumFromInt(f.row), Bir.MarkupRow);
                    arity = switch (r.shape) {
                        .markup, .lambda => if (is_for and bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(r.function).lhs)), Bir.Inst.Index).len == 2) 2 else 1,
                        .function => @max(s.decided(@enumFromInt(f.row)), 1),
                    };
                }
                try s.add(.{
                    .root = s.root,
                    .node = @intFromEnum(at),
                    .kind = if (is_for) .@"for" else .show,
                    .detail = detail,
                    .arity = arity,
                    .primitive = s.decided(at) != 0,
                });
            },
        }
    }

    fn children(s: *Section, start: Bir.ExtraIndex, end: Bir.ExtraIndex) Error!void {
        for (s.m.cx.bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |c| try s.node(c);
    }

    fn item(s: *Section, tag: Symbol, at: Bir.ExtraIndex) Error!void {
        const m = s.m;
        const bir = m.cx.bir;
        const it = bir.extraData(at, Bir.MarkupItem);
        switch (it.kind) {
            .spread => {},
            .escape => try s.add(.{ .root = s.root, .node = @intFromEnum(at), .kind = .escape, .detail = @intFromEnum(Dispatch.Markup.Class.string) }),
            .attr => {
                const row = m.item(tag, bir.symbol(it.name)) orelse return;
                if (row.form == .event) {
                    return s.add(.{
                        .root = s.root,
                        .node = @intFromEnum(at),
                        .kind = .event,
                        .detail = s.decided(at),
                        .row = row.index,
                        .extractor = m.extractor(row.*),
                    });
                }
                const class: Dispatch.Markup.Class = if (row.has(.classes) or row.has(.styles))
                    @enumFromInt(s.decided(at))
                else switch (try m.classOf(row) orelse .string) {
                    .string, .other => .string,
                    .int => .int,
                    .float => .float,
                    .bool => .bool,
                    .maybe_string => .maybe_string,
                };
                try s.add(.{ .root = s.root, .node = @intFromEnum(at), .kind = .attribute, .detail = @intFromEnum(class), .row = row.index });
            },
        }
    }
};

/// An event row's extractor as a value of the vocabulary module's
/// interface, or `no_row` when it has none or it is not `pub`.
fn extractor(m: *const Markup, row: Row) u32 {
    const via = row.via.unwrap() orelse return no_row;
    const cx = m.cx;
    const iface: *const Interface = if (m.vocabulary == cx.module) &cx.interfaces[cx.module.int()] else cx.iface(m.vocabulary);
    const index = iface.findValue(cx.interner, via) orelse return no_row;
    return @intFromEnum(index);
}

// ---------------------------------------------------------------------------
// "Did you mean"
// ---------------------------------------------------------------------------

/// At most `max_suggestions` names close to `name`, sorted by edit distance
/// then text (§15.3's rule): the declared elements, or — with `tag` — the
/// attributes and events that element accepts. Patterns are not names a
/// program can copy, so they are not suggested.
pub fn suggestions(m: *const Markup, scratch: Allocator, name: Symbol, tag: ?Symbol) Error![]const []const u8 {
    const text = m.cx.interner.slice(name);
    const Candidate = struct { text: []const u8, distance: usize };
    var found: std.ArrayList(Candidate) = .empty;
    const lists: []const []const Row = if (tag == null) &.{m.elements} else &.{ m.attributes, m.events };
    for (lists) |rows| for (rows) |r| {
        if (r.star != null) continue;
        if (tag) |t| if (r.on.len != 0 and std.mem.indexOfScalar(Symbol, r.on, t) == null) continue;
        const candidate = m.cx.interner.slice(r.name);
        const d = distance(text, candidate);
        if (d == 0 or d > @max(text.len / 2, 2)) continue;
        for (found.items) |f| {
            if (std.mem.eql(u8, f.text, candidate)) break;
        } else try found.append(scratch, .{ .text = candidate, .distance = d });
    };
    std.mem.sort(Candidate, found.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.distance != b.distance) return a.distance < b.distance;
            return std.mem.lessThan(u8, a.text, b.text);
        }
    }.lessThan);
    const out = try scratch.alloc([]const u8, @min(found.items.len, max_suggestions));
    for (out, found.items[0..out.len]) |*o, f| o.* = f.text;
    return out;
}

pub const max_suggestions = 3;

/// The events `tag` accepts whose name is `name` spelt in any case: what a
/// quoted `"onclick"` meant.
pub fn eventsLike(m: *const Markup, scratch: Allocator, name: []const u8, tag: Symbol) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (m.events) |r| {
        if (r.star != null) continue;
        if (r.on.len != 0 and std.mem.indexOfScalar(Symbol, r.on, tag) == null) continue;
        const candidate = m.cx.interner.slice(r.name);
        if (std.ascii.eqlIgnoreCase(candidate, name)) try out.append(scratch, candidate);
    }
    return out.items;
}

/// Levenshtein distance for short names; a name longer than 64 bytes is
/// never near.
pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize) / 4;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "edit distance counts single-byte edits" {
    try testing.expectEqual(@as(usize, 0), distance("class", "class"));
    try testing.expectEqual(@as(usize, 1), distance("clas", "class"));
    try testing.expectEqual(@as(usize, 1), distance("onclick", "onClick"));
    try testing.expectEqual(@as(usize, 3), distance("", "div"));
}
