//! The `ssr` markup lowering (docs/design/backend.md §15.6): the same tree
//! the `dom` lowering compiles into templates, emitted as strings, so a view
//! renders to HTML under Node — for a server, and for the `run/` corpus,
//! which has no DOM.
//!
//! **A root evaluates to `{ t: string }`**, the markup type's representation
//! under `ssr`: a string already rendered is never escaped twice. A root's
//! static text is its kind, a hoisted array of strings named by its site;
//! the root concatenates it with its dynamic parts. **Escaping is decided by
//! type, here**: a `String` hole is escaped, a number is not, an `Html` hole
//! splices its `.t`, an attribute value is escaped as an attribute, and a
//! URL goes through `safeUrl` first. Text arrives decoded and is escaped
//! into the static strings as the page's parser reads it back, so the page
//! says what `dom` would build. Events are dropped: a string carries no
//! handler.

const std = @import("std");
const Allocator = std.mem.Allocator;
const m = @import("beni_markup");
const parser = @import("platform_html").parser_table;

pub const lowering: m.Lowering = .{
    .name = "ssr",
    .targets = .{ .major = 1, .minor = 0 },
    .runtime = &.{
        .{ .name = "escape", .arity = 1 },
        .{ .name = "escapeAttr", .arity = 1 },
        .{ .name = "safeUrl", .arity = 1 },
        // `(items, row, fallback)`: the rows of a cons list concatenated,
        // or the fallback's text when the list is empty.
        .{ .name = "list", .arity = 3 },
        .{ .name = "classes", .arity = 1 },
        .{ .name = "styles", .arity = 1 },
        // `(text, tag)`: text written into a raw-text element as it is,
        // an end tag of the element made harmless.
        .{ .name = "rawText", .arity = 2 },
    },
    .module = module,
    .root = root,
};

/// Nothing is shared between a module's roots: each hoists its own kind.
fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}

fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    return renderRoot(cx, tree, index);
}

/// The block a root evaluates to, its static strings hoisted as the kind
/// `k<instruction>`.
fn renderRoot(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const r = tree.root(index);
    var render: Render = .{ .cx = cx, .tree = tree };
    try render.node(r.node, .{});
    const hint = try std.fmt.allocPrint(cx.arena, "k{d}", .{r.site.inst});
    return render.finishRoot(hint);
}

/// One piece of a rendered string: text known now, or an expression the
/// page's text is computed from.
const Piece = union(enum) {
    static: []const u8,
    /// `string`: the expression is certainly a JavaScript string, so a
    /// concatenation may begin with it.
    dynamic: struct { expr: m.Expr, string: bool },
};

const Render = struct {
    cx: *m.Context,
    tree: *const m.Tree,
    pieces: std.ArrayList(Piece) = .empty,
    current: std.ArrayList(u8) = .empty,

    fn arena(r: *Render) Allocator {
        return r.cx.arena;
    }

    fn js(r: *Render) m.Js {
        return r.cx.js;
    }

    fn write(r: *Render, bytes: []const u8) !void {
        try r.current.appendSlice(r.arena(), bytes);
    }

    fn dynamic(r: *Render, e: m.Expr, is_string: bool) !void {
        try r.flush();
        try r.pieces.append(r.arena(), .{ .dynamic = .{ .expr = e, .string = is_string } });
    }

    fn flush(r: *Render) !void {
        if (r.current.items.len == 0) return;
        try r.pieces.append(r.arena(), .{ .static = try r.current.toOwnedSlice(r.arena()) });
    }

    fn hasDynamic(r: *const Render) bool {
        for (r.pieces.items) |p| if (p == .dynamic) return true;
        return false;
    }

    /// The root's block. Static text only: the whole block is the kind,
    /// hoisted once. Otherwise the kind is the array of static strings,
    /// and the block concatenates them with the dynamic parts.
    fn finishRoot(r: *Render, hint: []const u8) m.Error!m.Expr {
        try r.flush();
        if (!r.hasDynamic()) {
            const all = try r.staticText();
            const block = try r.js().object(&.{.{ .key = "t", .value = try r.js().string(all) }});
            return r.js().name(try r.cx.hoist(hint, block));
        }
        var statics: std.ArrayList(m.Expr) = .empty;
        // The concatenation begins with a string, so a number that comes
        // first is appended to text rather than added to what follows.
        const leads_with_static = r.pieces.items[0] == .static;
        if (!leads_with_static) try statics.append(r.arena(), try r.js().string(""));
        for (r.pieces.items) |p| switch (p) {
            .static => |s| try statics.append(r.arena(), try r.js().string(s)),
            .dynamic => {},
        };
        const kind = try r.cx.hoist(hint, try r.js().array(statics.items));
        var slot: u32 = 0;
        var acc: ?m.Expr = null;
        if (!leads_with_static) {
            acc = try r.staticAt(kind, 0);
            slot = 1;
        }
        for (r.pieces.items) |p| {
            const next = switch (p) {
                .static => blk: {
                    defer slot += 1;
                    break :blk try r.staticAt(kind, slot);
                },
                .dynamic => |d| d.expr,
            };
            acc = if (acc) |a| try r.js().binary(.add, a, next) else next;
        }
        return r.js().object(&.{.{ .key = "t", .value = acc.? }});
    }

    fn staticAt(r: *Render, kind: m.Name, slot: u32) !m.Expr {
        const spelled = try std.fmt.allocPrint(r.arena(), "{d}", .{slot});
        return r.js().index(try r.js().name(kind), try r.js().number(spelled));
    }

    fn staticText(r: *Render) ![]const u8 {
        var all: std.ArrayList(u8) = .empty;
        for (r.pieces.items) |p| switch (p) {
            .static => |s| try all.appendSlice(r.arena(), s),
            .dynamic => unreachable,
        };
        return all.items;
    }

    /// The pieces as one string expression, written in place: for markup
    /// that is not a root of its own — a component's children.
    fn finishInline(r: *Render) m.Error!m.Expr {
        try r.flush();
        var acc: ?m.Expr = null;
        for (r.pieces.items, 0..) |p, i| {
            const next = switch (p) {
                .static => |s| try r.js().string(s),
                .dynamic => |d| blk: {
                    if (i == 0 and !d.string) acc = try r.js().string("");
                    break :blk d.expr;
                },
            };
            acc = if (acc) |a| try r.js().binary(.add, a, next) else next;
        }
        return acc orelse r.js().string("");
    }

    // ---- Nodes ----------------------------------------------------------

    fn node(r: *Render, n: m.Node.Index, scope: parser.Scope) m.Error!void {
        r.cx.at(n);
        switch (r.tree.kind(n)) {
            .element => try r.element(n, scope),
            .fragment => for (r.tree.childrenOf(r.tree.fragment(n).children)) |child| try r.node(child, scope),
            .text => {
                if (parser.movesText(scope.parent)) {
                    return r.restructured(n, scope.parent.?, "the parser moves text out of a table, so it would not be where it is written");
                }
                try escapeText(r.arena(), &r.current, r.tree.string(r.tree.text(n).text));
            },
            .hole => try r.hole(r.tree.hole(n)),
            .component => try r.component(n),
            .for_ => try r.forList(n),
            .show => try r.show(n),
            // Every node kind of the interface version this lowering
            // targets is handled above; a newer one is gated
            // (`boundary.md` §9.4.6) and never reaches it.
            _ => unreachable,
        }
    }

    fn element(r: *Render, n: m.Node.Index, scope: parser.Scope) m.Error!void {
        const e = r.tree.element(n);
        const name = r.tree.string(r.tree.elementFacts(e.row).name);
        if (parser.misnested(scope, name)) |why| return r.restructured(n, scope.parent orelse "", why);
        try r.write("<");
        try r.write(name);
        var content: ?m.Expr = null;
        for (r.tree.itemsOf(e.items)) |it| try r.attributeItem(it, &content);
        try r.write(">");
        const children = r.tree.childrenOf(e.children);
        if (parser.isVoid(name)) {
            if (children.len != 0 or content != null) {
                return r.restructured(n, name, "the parser treats this element as void, so its content would follow it");
            }
            return;
        }
        if (content) |c| try r.dynamic(c, true);
        const inner = scope.enter(name);
        switch (parser.content(name)) {
            .normal => for (children) |child| try r.node(child, inner),
            // Nothing is decoded in raw text, so it is written as it is: text
            // known now is refused if it would end the element early, and a
            // text hole's value is written by the runtime's `rawText`, which
            // cannot refuse and so writes an end tag's `</` as `<\/`.
            .raw_text => for (children) |child| switch (r.tree.kind(child)) {
                .text => {
                    const raw = r.tree.string(r.tree.text(child).text);
                    if (parser.endsRawText(name, raw)) {
                        return r.restructured(child, name, "the text holds the element's own end tag, which would close it early");
                    }
                    try r.write(raw);
                },
                .hole => {
                    const h = r.tree.hole(child);
                    const v = try r.cx.value(h.value);
                    switch (h.kind) {
                        .text_string, .text_char => try r.dynamic(try r.runtimeCall("rawText", &.{ v, try r.js().string(name) }), true),
                        .text_number, .text_bool => try r.dynamic(v, false),
                        else => return r.restructured(child, name, "the parser reads this element's content as raw text, so markup written in it would be text"),
                    }
                },
                else => return r.restructured(child, name, "the parser reads this element's content as raw text, so nothing but text can be written in it"),
            },
            .escapable_raw_text => for (children) |child| {
                const allowed = switch (r.tree.kind(child)) {
                    .text => true,
                    .hole => switch (r.tree.hole(child).kind) {
                        .text_string, .text_number, .text_char, .text_bool => true,
                        else => false,
                    },
                    else => false,
                };
                if (!allowed) {
                    return r.restructured(child, name, "the parser reads this element's content as text, so markup written in it would be text");
                }
                try r.node(child, inner);
            },
        }
        try r.write("</");
        try r.write(name);
        try r.write(">");
    }

    fn restructured(r: *Render, n: m.Node.Index, where: []const u8, why: []const u8) m.Error {
        const message = if (where.len == 0)
            try std.fmt.allocPrint(r.arena(), "The `ssr` lowering cannot write this markup as the page's parser would read it: {s}.", .{why})
        else
            try std.fmt.allocPrint(r.arena(), "The `ssr` lowering cannot write this markup inside `<{s}>` as the page's parser would read it: {s}.", .{ where, why });
        return r.cx.report(n, message);
    }

    fn hole(r: *Render, h: m.Hole) m.Error!void {
        const v = try r.cx.value(h.value);
        switch (h.kind) {
            .text_string, .text_char => try r.dynamic(try r.runtimeCall("escape", &.{v}), true),
            // `"${n}"` of a number or a `Bool` needs no escaping, and
            // appending it to text stringifies it as interpolation does.
            .text_number, .text_bool => try r.dynamic(v, false),
            .html => try r.dynamic(try r.js().member(v, "t"), true),
            .maybe_html => {
                const shown = try r.js().member(try r.cx.maybe(try r.cx.value(h.value)), "t");
                try r.dynamic(try r.js().cond(try r.cx.isJust(v), shown, try r.js().string("")), true);
            },
            .list_html => {
                // Each element is already a block: the row is the identity.
                const each = try r.cx.fresh("h");
                const body = try r.js().block();
                try r.js().@"return"(body, try r.js().name(each));
                const identity = try r.js().arrow(&.{each}, body);
                try r.dynamic(try r.runtimeCall("list", &.{ v, identity, try r.js().literal(.null) }), true);
            },
            _ => unreachable,
        }
    }

    fn component(r: *Render, n: m.Node.Index) m.Error!void {
        const c = r.tree.component(n);
        var children: ?m.Expr = null;
        if (c.children_nodes.len != 0) {
            // The children are one markup value the component decides
            // where to place, so they are rendered with no parent.
            var inner: Render = .{ .cx = r.cx, .tree = r.tree };
            for (r.tree.childrenOf(c.children_nodes)) |child| try inner.node(child, .{});
            children = try r.js().object(&.{.{ .key = "t", .value = try inner.finishInline() }});
        }
        const call = try r.cx.componentCall(n, children);
        try r.dynamic(try r.js().member(call, "t"), true);
    }

    fn forList(r: *Render, n: m.Node.Index) m.Error!void {
        const f = r.tree.for_(n);
        const row = try r.rowFunction(f.row);
        const fallback = if (f.fallback) |v| try r.cx.value(v) else try r.js().literal(.null);
        try r.dynamic(try r.runtimeCall("list", &.{ try r.cx.value(f.each), row, fallback }), true);
    }

    fn show(r: *Render, n: m.Node.Index) m.Error!void {
        const s = r.tree.show(n);
        const body = try r.rowFunction(s.body);
        const payload = try r.cx.maybe(try r.cx.value(s.when));
        const shown = try r.js().member(try r.js().call(body, &.{payload}), "t");
        const otherwise = if (s.fallback) |v| try r.js().member(try r.cx.value(v), "t") else try r.js().string("");
        try r.dynamic(try r.js().cond(try r.cx.isJust(try r.cx.value(s.when)), shown, otherwise), true);
    }

    /// The function a row is: `(item, position) => block`.
    fn rowFunction(r: *Render, index: m.Row.Index) m.Error!m.Expr {
        const row = r.tree.row(index);
        const argument = try r.cx.fresh("item");
        const position: ?m.Name = if (row.arity == 2) try r.cx.fresh("position") else null;
        const body = try r.js().block();
        switch (row.kind) {
            .markup => {
                _ = try r.cx.rowValues(body, index, argument, position, &.{});
                try r.js().@"return"(body, try renderRoot(r.cx, r.tree, row.body));
            },
            .lambda => {
                const result = try r.cx.rowValues(body, index, argument, position, &.{});
                try r.js().@"return"(body, result.?);
            },
            .function => {
                const f = try r.cx.value(row.function.?);
                const called = if (position) |p|
                    try r.cx.call(f, &.{ try r.js().name(argument), try r.js().name(p) })
                else
                    try r.cx.call(f, &.{try r.js().name(argument)});
                try r.js().@"return"(body, called);
            },
            _ => unreachable,
        }
        if (position) |p| return r.js().arrow(&.{ argument, p }, body);
        return r.js().arrow(&.{argument}, body);
    }

    // ---- Attributes -----------------------------------------------------

    /// One attribute or escape; events write nothing. A `raw` attribute is
    /// the element's content, written unescaped after its start tag.
    fn attributeItem(r: *Render, it: m.Item, content: *?m.Expr) m.Error!void {
        switch (it.kind) {
            .attribute, .escape => {},
            .event => return,
            _ => unreachable,
        }
        if (it.kind == .attribute and r.tree.attributeFacts(it.attribute).raw) {
            content.* = switch (it.value.kind) {
                .constant => try r.js().string(r.tree.string(it.value.constant.text)),
                else => try r.cx.value(it.value.dynamic.?),
            };
            return;
        }
        const name = r.tree.string(it.name);
        switch (it.value.kind) {
            .constant => try r.constantAttribute(name, it),
            .dynamic => try r.dynamicAttribute(name, it, try r.cx.value(it.value.dynamic.?)),
            .entries => {
                const written = try r.entriesText(it) orelse
                    return r.dynamicAttribute(name, it, try r.cx.value(it.value.dynamic.?));
                try r.writeAttribute(name, written);
            },
            _ => unreachable,
        }
    }

    fn constantAttribute(r: *Render, name: []const u8, it: m.Item) m.Error!void {
        const c = it.value.constant;
        switch (c.kind) {
            .string => {
                if (it.url) return r.dynamicAttribute(name, it, try r.js().string(r.tree.string(c.text)));
                try r.writeAttribute(name, r.tree.string(c.text));
            },
            .number => try r.writeAttribute(name, r.tree.string(c.text)),
            .bool => if (c.bool) {
                try r.write(" ");
                try r.write(name);
            },
            else => unreachable,
        }
    }

    fn writeAttribute(r: *Render, name: []const u8, value: []const u8) !void {
        try r.write(" ");
        try r.write(name);
        try r.write("=\"");
        try escapeAttribute(r.arena(), &r.current, value);
        try r.write("\"");
    }

    fn dynamicAttribute(r: *Render, name: []const u8, it: m.Item, v: m.Expr) m.Error!void {
        switch (it.class) {
            .string => try r.quoted(name, try r.escapedValue(it, v)),
            // A number is written as `"${n}"` writes it, and needs no
            // escaping.
            .int, .float => {
                try r.write(" ");
                try r.write(name);
                try r.write("=\"");
                try r.dynamic(v, false);
                try r.write("\"");
            },
            .bool => {
                const present = try std.fmt.allocPrint(r.arena(), " {s}", .{name});
                try r.dynamic(try r.js().cond(v, try r.js().string(present), try r.js().string("")), true);
            },
            .maybe_string => {
                const value = try r.escapedValue(it, try r.cx.maybe(v));
                const open = try std.fmt.allocPrint(r.arena(), " {s}=\"", .{name});
                const written = try r.js().binary(.add, try r.js().binary(.add, try r.js().string(open), value), try r.js().string("\""));
                try r.dynamic(try r.js().cond(try r.cx.isJust(v), written, try r.js().string("")), true);
            },
            .class_list => try r.quoted(name, try r.runtimeCall("escapeAttr", &.{try r.runtimeCall("classes", &.{v})})),
            .style_list => try r.quoted(name, try r.runtimeCall("escapeAttr", &.{try r.runtimeCall("styles", &.{v})})),
            _ => unreachable,
        }
    }

    fn quoted(r: *Render, name: []const u8, value: m.Expr) !void {
        try r.write(" ");
        try r.write(name);
        try r.write("=\"");
        try r.dynamic(value, true);
        try r.write("\"");
    }

    /// A string value escaped for an attribute, a URL made safe first.
    fn escapedValue(r: *Render, it: m.Item, v: m.Expr) !m.Expr {
        const safe = if (it.url) try r.runtimeCall("safeUrl", &.{v}) else v;
        return r.runtimeCall("escapeAttr", &.{safe});
    }

    /// A class or style list written in place whose entries are all
    /// constants, as the attribute's text; null when one is not, and the
    /// runtime writes the list.
    fn entriesText(r: *Render, it: m.Item) !?[]const u8 {
        const entries = r.tree.entriesOf(it.value.entries);
        for (entries) |e| if (e.value.kind != .constant) return null;
        var out: std.ArrayList(u8) = .empty;
        switch (it.class) {
            .class_list => {
                // The names whose flag is `True`, split at whitespace, each
                // once, in first-occurrence order.
                var seen: std.ArrayList([]const u8) = .empty;
                for (entries) |e| {
                    if (!(e.value.constant.kind == .bool and e.value.constant.bool)) continue;
                    var names = std.mem.tokenizeAny(u8, r.tree.string(e.name), "\t\n\x0c\r ");
                    while (names.next()) |one| {
                        var repeated = false;
                        for (seen.items) |s| repeated = repeated or std.mem.eql(u8, s, one);
                        if (repeated) continue;
                        try seen.append(r.arena(), one);
                        if (out.items.len != 0) try out.append(r.arena(), ' ');
                        try out.appendSlice(r.arena(), one);
                    }
                }
            },
            .style_list => {
                // Each property once, in first-occurrence order, with its
                // last value; an empty last value removes it.
                const Property = struct { name: []const u8, value: []const u8 };
                var properties: std.ArrayList(Property) = .empty;
                for (entries) |e| {
                    const name = r.tree.string(e.name);
                    const value = if (e.value.constant.kind == .string) r.tree.string(e.value.constant.text) else "";
                    for (properties.items) |*p| {
                        if (!std.mem.eql(u8, p.name, name)) continue;
                        p.value = value;
                        break;
                    } else try properties.append(r.arena(), .{ .name = name, .value = value });
                }
                for (properties.items) |p| {
                    if (p.value.len == 0) continue;
                    try out.appendSlice(r.arena(), p.name);
                    try out.append(r.arena(), ':');
                    try out.appendSlice(r.arena(), p.value);
                    try out.append(r.arena(), ';');
                }
            },
            else => return null,
        }
        return out.items;
    }

    fn runtimeCall(r: *Render, export_name: []const u8, args: []const m.Expr) !m.Expr {
        return r.js().call(try r.js().name(try r.cx.runtime(export_name)), args);
    }
};

/// Text as the parser of an element's ordinary content reads it back: `&`
/// and `<` would begin a reference or a tag, and a carriage return would
/// become a line feed.
fn escapeText(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

/// A double-quoted attribute value as the parser reads it back.
fn escapeAttribute(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

test "text and attribute values are escaped as the parser reads them back" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try escapeText(t.allocator, &out, "a < b & \"c\"\r");
    try t.expectEqualStrings("a &lt; b &amp; \"c\"&#13;", out.items);
    out.clearRetainingCapacity();
    try escapeAttribute(t.allocator, &out, "a < b & \"c\"");
    try t.expectEqualStrings("a &lt; b &amp; &quot;c&quot;", out.items);
}
