//! The `dom` markup lowering (docs/design/backend.md §15.3–§15.5): a port
//! of dom-expressions' client compiler to The Elm Architecture. Each markup
//! site becomes a **kind** `{ m(v, cx), p(inst, v) }`, hoisted once and
//! named by its site: `m` clones the site's template, walks to the nodes
//! its holes write, writes them and returns the instance; `p` writes a hole
//! again only when its value is not the one it wrote last. There is no
//! signal: `view` runs again, and a hole compares by reference.
//!
//! **A root evaluates to a block** `{ t: kind, v: [values] }`, which the
//! slot that receives it patches when its kind is the slot's and remounts
//! otherwise (§15.4). A `For` row whose body is markup is compiled in
//! place instead, as a pair of functions the runtime's list calls per row
//! (§15.5): nothing is allocated for a row that did not change.
//!
//! What is ported, with the file each rule comes from
//! (`references/dom-expressions/packages/compiler/src/…`):
//!
//! - the template string: static elements, constant attributes and text
//!   baked in, quotes dropped where HTML allows (`shared/utils.rs:
//!   271-290`), a quoted value followed by the next attribute with no space
//!   (`dom/attrs.rs:599-606`), end tags the parser implies omitted
//!   (`dom/attrs.rs:510-563`, `shared/constants.rs:39-91`), an SVG
//!   element wrapped for parsing (`dom/element.rs:476-495`);
//! - the walks: a node a write or a slot uses is reached by `firstChild`
//!   and `nextSibling` from the nearest walk before it under the same
//!   parent, or from its parent (`dom/template.rs:413-458`), and every walk
//!   is declared before the first write (`dom/element.rs:429-431`);
//! - the slot markers: the next node of the template, a `<!>` where the
//!   slot sits between two text runs or its parent has several slots, or
//!   none, to append, when it is its parent's only slot and nothing follows
//!   it (`dom/children.rs:557-634`);
//! - what each attribute, class entry, style entry and event writes
//!   (`dom/set_attr.rs:25-228`, `dom/events.rs:60-107`), as §15.3's table
//!   says, with the last value kept in an instance field instead of an
//!   effect's `_p$` (`dom/dynamics.rs:150-179`).
//!
//! What is not: hydration, the reactive wrappers (`effect`, `memo`,
//! `insert`'s thunks), spread, refs, and Babel's walk ids for nodes no
//! write uses. Text the compiler already decoded is escaped back for the
//! page's parser, so `dom` and `ssr` write the same characters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const m = @import("beni_markup");
const parser = @import("platform_html").parser_table;

pub const lowering: m.Lowering = .{
    .name = "dom",
    .targets = .{ .major = 1, .minor = 0 },
    .runtime = &.{
        .{ .name = "start", .arity = 1 },
        .{ .name = "delegate", .arity = 1 },
        .{ .name = "template", .arity = 2 },
        .{ .name = "slot", .arity = 3 },
        .{ .name = "childHtml", .arity = 2 },
        .{ .name = "childMaybe", .arity = 2 },
        .{ .name = "childList", .arity = 2 },
        .{ .name = "forKeyed", .arity = 5 },
        .{ .name = "forPosition", .arity = 4 },
        .{ .name = "show", .arity = 3 },
        .{ .name = "hide", .arity = 2 },
        .{ .name = "classes", .arity = 3 },
        .{ .name = "styles", .arity = 3 },
        .{ .name = "attrNS", .arity = 4 },
        .{ .name = "safeUrl", .arity = 1 },
        .{ .name = "rawHtml", .arity = 2 },
        .{ .name = "listen", .arity = 3 },
        // Emitted code never calls it: the render loop's synchronous flush,
        // which the program runtime owns and exports (§15.11).
        .{ .name = "flush", .arity = 0 },
        // `(el, name, value)`: an attribute written, or removed for null —
        // a `Bool` or a `Maybe String`.
        .{ .name = "attr", .arity = 3 },
        // `(parent, marker, value)`: a text hole's node, made at mount.
        .{ .name = "insertText", .arity = 3 },
        // The payload extractor of an event whose handler takes the event.
        .{ .name = "identity", .arity = 1 },
    },
    .module = module,
    .root = root,
};

/// Everything is hoisted by the roots that need it, where the enclosing
/// declaration is being lowered: a row's values can only be placed there.
fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}

fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const r = tree.root(index);
    var g: Gen = .{ .cx = cx, .tree = tree };
    return g.block(&.{r.node}, r.site.inst, null);
}

// ---- The plan of one template -------------------------------------------

/// One node of a template, in the order the template's HTML writes it.
const TNode = struct {
    /// The element it is a child of; null at the template's top level.
    parent: ?u32,
    /// Its position among its parent's nodes.
    index: u32,
    kind: enum { element, text, marker },
    /// Something is written to it or placed by it, or to a node under it.
    needed: bool = false,
    /// A patch writes it, so the instance keeps it.
    stored: bool = false,
};

/// Where a slot's content goes: under `parent` (the top level when null),
/// before `marker`.
const Place = struct {
    parent: ?u32,
    marker: Marker,
};

const Marker = union(enum) {
    /// Appended: the slot is its parent's last content.
    none,
    node: u32,
    /// The template node at this position of the parent, which is written
    /// after the slot.
    next: u32,
};

/// One write, in source order. Each operand is an index into
/// `Body.operands`.
const Op = struct {
    node: m.Node.Index,
    what: What,

    const What = union(enum) {
        /// A text hole that is its parent's only child: a text node of the
        /// template.
        placeholder: struct { t: u32, value: u32 },
        /// Any other text hole: a text node made at mount.
        text: struct { at: Place, value: u32 },
        attribute: struct { t: u32, item: m.Item, value: u32, constant: bool },
        toggle: struct { t: u32, name: []const u8, value: u32 },
        style: struct { t: u32, name: []const u8, value: u32 },
        event: struct { t: u32, item: m.Item, index: u32, handler: u32, context: bool },
        html: struct { at: Place, kind: m.HoleKind, value: u32 },
        component: struct { at: Place, props: []const u32, children: ?u32, thunk: u32 },
        for_: struct { at: Place, mode: m.For.Mode, each: u32, key: ?u32, row: u32, inputs: ?u32 },
        show: struct { at: Place, when: u32, key: ?u32, fallback: ?u32, body: u32, inputs: []const u32 },
    };

    fn place(op: Op) ?Place {
        return switch (op.what) {
            .text => |x| x.at,
            .html => |x| x.at,
            .component => |x| x.at,
            .for_ => |x| x.at,
            .show => |x| x.at,
            else => null,
        };
    }

    /// Whether the op owns a slot of the runtime's.
    fn slotted(op: Op) bool {
        return switch (op.what) {
            .html, .component, .for_, .show => true,
            else => false,
        };
    }
};

/// What a template's code reads: a value of the markup's root, or a
/// function made where the markup is evaluated.
const Operand = union(enum) {
    value: m.Value.Index,
    /// A constant attribute that still needs code: a URL, a property.
    constant: m.Constant,
    /// A `For`'s row: `{ m, p, i, f }` or `{ b, i, f }` (the runtime's
    /// header).
    row: m.Node.Index,
    /// A `Show`'s body, `(value) => block`.
    body: m.Node.Index,
    /// A component's call, `(children) => block`.
    thunk: struct { node: m.Node.Index, children: bool },
    /// A component's children written as markup: one block.
    children: struct { node: m.Node.Index, site: u32 },
    /// A row's inputs, as an array the runtime compares entry by entry.
    inputs: m.Value.Range,

    /// Whether building it makes a function or a block, so a use builds
    /// it once.
    fn made(o: Operand) bool {
        return switch (o) {
            .row, .body, .thunk, .children => true,
            else => false,
        };
    }
};

/// A template's first node: a node of the template, a text hole's node, or
/// a slot's content.
const First = union(enum) { node: u32, text: u32, slot: u32 };

const Body = struct {
    html: std.ArrayList(u8) = .empty,
    flags: u8 = 0,
    tnodes: std.ArrayList(TNode) = .empty,
    ops: std.ArrayList(Op) = .empty,
    operands: std.ArrayList(Operand) = .empty,
    /// The top level's first entry and last node.
    first: ?First = null,
    last: u32 = 0,
    /// Template nodes at the top level.
    top: u32 = 0,
    /// A single top-level element: its name and namespace, for the SVG
    /// wrapper.
    root_element: ?struct { name: []const u8, namespace: m.ElementFacts.Namespace } = null,
    /// A `--library` build's delegated event names, which `m` registers.
    delegated: std.ArrayList([]const u8) = .empty,
    /// The root site, for the names of the kinds it makes.
    site: u32,

    fn tnode(b: *Body, a: Allocator, parent: ?u32, index: u32, kind: @FieldType(TNode, "kind")) !u32 {
        const i: u32 = @intCast(b.tnodes.items.len);
        try b.tnodes.append(a, .{ .parent = parent, .index = index, .kind = kind });
        if (parent == null) {
            b.top += 1;
            b.last = i;
            if (b.first == null) b.first = .{ .node = i };
        }
        return i;
    }

    fn write(b: *Body, a: Allocator, bytes: []const u8) !void {
        try b.html.appendSlice(a, bytes);
    }

    fn operand(b: *Body, a: Allocator, o: Operand) !u32 {
        if (o == .value) for (b.operands.items, 0..) |x, i| {
            if (x == .value and x.value == o.value) return @intCast(i);
        };
        try b.operands.append(a, o);
        return @intCast(b.operands.items.len - 1);
    }

    fn mark(b: *Body, t: u32) void {
        var at: ?u32 = t;
        while (at) |i| {
            if (b.tnodes.items[i].needed) return;
            b.tnodes.items[i].needed = true;
            at = b.tnodes.items[i].parent;
        }
    }

    fn store(b: *Body, t: u32) void {
        b.mark(t);
        b.tnodes.items[t].stored = true;
    }
};

/// Which ancestors' end tags must be written for the parser to rebuild the
/// tree: dom-expressions' `CloseTagContext` (`dom/attrs.rs:510-563`).
const Close = struct {
    /// The element is the last content of its parent that the template
    /// writes.
    last: bool,
    /// Once an ancestor's end tag is written, the elements whose end tags
    /// must be too; null before.
    to_be_closed: ?[]const []const u8,
};

const always_close = [_][]const u8{
    "title",  "style",    "a",      "strong", "small",  "b",        "u",        "i",        "em", "s", "code", "object", "table",
    "button", "textarea", "select", "iframe", "script", "noscript", "template", "fieldset",
};

const block_elements = [_][]const u8{
    "address", "article",  "aside",      "blockquote", "dd",      "details", "dialog", "div",  "dl",
    "dt",      "fieldset", "figcaption", "figure",     "footer",  "form",    "h1",     "h2",   "h3",
    "h4",      "h5",       "h6",         "header",     "hgroup",  "hr",      "li",     "main", "menu",
    "nav",     "ol",       "p",          "pre",        "section", "table",   "ul",
};

const inline_elements = [_][]const u8{
    "a",      "abbr",    "acronym",  "b",        "bdi",   "bdo", "big",      "br",       "button",   "canvas",
    "cite",   "code",    "data",     "datalist", "del",   "dfn", "em",       "embed",    "i",        "iframe",
    "img",    "input",   "ins",      "kbd",      "label", "map", "mark",     "meter",    "noscript", "object",
    "output", "picture", "progress", "q",        "ruby",  "s",   "samp",     "script",   "select",   "slot",
    "small",  "span",    "strong",   "sub",      "sup",   "svg", "template", "textarea", "time",     "u",
    "tt",     "var",     "video",
};

fn among(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn shouldClose(name: []const u8, close: Close) bool {
    if (parser.isVoid(name)) return false;
    return !close.last or close.to_be_closed != null;
}

// ---- The generator --------------------------------------------------------

/// The names a site's hoisted declarations take: its kind `k`, its
/// template `t` and, for markup with no values, its one block `b`.
const Names = struct { kind: []const u8, template: []const u8, block: []const u8 };

/// One function being written: a kind's `m` or `p`, or a row's.
const Fn = struct {
    block: m.Block,
    /// A kind's function reads its values from `v`; a row's reads them
    /// where the row placed them.
    v: ?m.Name,
    /// `p`: the instance.
    i: ?m.Name = null,
    /// `m`: the mount context, and the clone.
    cx: ?m.Name = null,
    r: ?m.Name = null,
    /// `m`: each template node's walk.
    walks: []?m.Name = &.{},
    /// `m`: each op's slot, and a text hole's node.
    slots: []?m.Name = &.{},
    texts: []?m.Name = &.{},
    /// A row's function or block operand, made once per function.
    made: []?m.Name = &.{},
};

const Gen = struct {
    cx: *m.Context,
    tree: *const m.Tree,

    fn a(g: *Gen) Allocator {
        return g.cx.arena;
    }

    fn jsb(g: *Gen) m.Js {
        return g.cx.js;
    }

    fn print(g: *Gen, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(g.a(), fmt, args);
    }

    fn str(g: *Gen, s: []const u8) !m.Expr {
        return g.jsb().string(s);
    }

    fn num(g: *Gen, n: u32) !m.Expr {
        return g.jsb().number(try g.print("{d}", .{n}));
    }

    fn nul(g: *Gen) !m.Expr {
        return g.jsb().literal(.null);
    }

    fn ident(g: *Gen, n: m.Name) !m.Expr {
        return g.jsb().name(n);
    }

    fn member(g: *Gen, e: m.Expr, prop: []const u8) !m.Expr {
        return g.jsb().member(e, prop);
    }

    fn rt(g: *Gen, export_name: []const u8, args: []const m.Expr) !m.Expr {
        return g.jsb().call(try g.jsb().name(try g.cx.runtime(export_name)), args);
    }

    fn method(g: *Gen, target: m.Expr, method_name: []const u8, args: []const m.Expr) !m.Expr {
        return g.jsb().call(try g.member(target, method_name), args);
    }

    fn restructured(g: *Gen, n: m.Node.Index, where: []const u8, why: []const u8) m.Error {
        const message = if (where.len == 0)
            try g.print("The `dom` lowering cannot write this markup as a template the page's parser would read back: {s}.", .{why})
        else
            try g.print("The `dom` lowering cannot write this markup inside `<{s}>` as a template the page's parser would read back: {s}.", .{ where, why });
        return g.cx.report(n, message);
    }

    // ---- Blocks ---------------------------------------------------------

    fn names(g: *Gen, site: u32, sub: ?m.Node.Index) !Names {
        if (sub) |n| {
            const at = @intFromEnum(n);
            return .{
                .kind = try g.print("k{d}n{d}", .{ site, at }),
                .template = try g.print("t{d}n{d}", .{ site, at }),
                .block = try g.print("b{d}n{d}", .{ site, at }),
            };
        }
        return .{
            .kind = try g.print("k{d}", .{site}),
            .template = try g.print("t{d}", .{site}),
            .block = try g.print("b{d}", .{site}),
        };
    }

    /// The block markup evaluates to: its kind, hoisted once per site, and
    /// its values, made where the markup is. Markup with no values is one
    /// block, hoisted.
    fn block(g: *Gen, nodes: []const m.Node.Index, site: u32, sub: ?m.Node.Index) m.Error!m.Expr {
        const n = try g.names(site, sub);
        var b = try g.plan(nodes, site);
        const kind = g.cx.hoisted(n.kind) orelse try g.hoistKind(&b, n);
        if (b.operands.items.len == 0) {
            const hoisted = g.cx.hoisted(n.block) orelse try g.cx.hoist(n.block, try g.jsb().object(&.{
                .{ .key = "t", .value = try g.ident(kind) },
                .{ .key = "v", .value = try g.nul() },
            }));
            return g.ident(hoisted);
        }
        const values = try g.a().alloc(m.Expr, b.operands.items.len);
        for (b.operands.items, values) |o, *v| v.* = try g.make(o);
        return g.jsb().object(&.{
            .{ .key = "t", .value = try g.ident(kind) },
            .{ .key = "v", .value = try g.jsb().array(values) },
        });
    }

    /// The template's cloner, hoisted once.
    fn template(g: *Gen, b: *const Body, hint: []const u8) !m.Name {
        if (g.cx.hoisted(hint)) |t| return t;
        return g.cx.hoist(hint, try g.rt("template", &.{ try g.str(b.html.items), try g.num(b.flags) }));
    }

    fn hoistKind(g: *Gen, b: *Body, n: Names) m.Error!m.Name {
        const js = g.jsb();
        const t = try g.template(b, n.template);
        const v = try g.cx.fresh("v");
        const cx = try g.cx.fresh("cx");
        var mount: Fn = .{ .block = try js.block(), .v = v, .cx = cx };
        try js.@"return"(mount.block, try g.writeMount(b, &mount, t));
        const i = try g.cx.fresh("i");
        const pv = try g.cx.fresh("v");
        var patch: Fn = .{ .block = try js.block(), .v = pv, .i = i };
        try g.writePatch(b, &patch);
        return g.cx.hoist(n.kind, try js.object(&.{
            .{ .key = "m", .value = try js.arrow(&.{ v, cx }, mount.block) },
            .{ .key = "p", .value = try js.arrow(&.{ i, pv }, patch.block) },
        }));
    }

    /// An operand made where the markup is evaluated.
    fn make(g: *Gen, o: Operand) m.Error!m.Expr {
        const js = g.jsb();
        return switch (o) {
            .value => |v| g.cx.value(v),
            .constant => |c| switch (c.kind) {
                .string => g.str(g.tree.string(c.text)),
                .number => js.number(g.tree.string(c.text)),
                .bool => js.literal(if (c.bool) .true else .false),
                else => g.nul(),
            },
            .inputs => |range| blk: {
                const values = try g.a().alloc(m.Expr, range.len);
                for (values, 0..) |*v, k| v.* = try g.cx.value(range.at(@intCast(k)));
                break :blk js.array(values);
            },
            .row => |n| g.rowObject(n),
            .body => |n| g.showBody(n),
            .thunk => |t| blk: {
                const body = try js.block();
                if (t.children) {
                    const children = try g.cx.fresh("children");
                    try js.@"return"(body, try g.cx.componentCall(t.node, try g.ident(children)));
                    break :blk js.arrow(&.{children}, body);
                }
                try js.@"return"(body, try g.cx.componentCall(t.node, null));
                break :blk js.arrow(&.{}, body);
            },
            .children => |c| g.block(g.tree.childrenOf(g.tree.component(c.node).children_nodes), c.site, c.node),
        };
    }

    /// A `For`'s row: a pair compiled in place for a row whose body is
    /// markup, a block function for any other.
    fn rowObject(g: *Gen, n: m.Node.Index) m.Error!m.Expr {
        const js = g.jsb();
        const f = g.tree.for_(n);
        const row = g.tree.row(f.row);
        var props: std.ArrayList(m.Property) = .empty;
        const item = try g.cx.fresh("item");
        const position = try g.cx.fresh("position");
        const reads: ?m.Name = if (row.arity == 2) position else null;
        switch (row.kind) {
            .markup => {
                const body = g.tree.root(row.body);
                var b = try g.plan(&.{body.node}, body.site.inst);
                const t = try g.template(&b, try g.print("t{d}", .{body.site.inst}));

                const cx = try g.cx.fresh("cx");
                var mount: Fn = .{ .block = try js.block(), .v = null, .cx = cx };
                _ = try g.cx.rowValues(mount.block, f.row, item, reads, &.{});
                try js.@"return"(mount.block, try g.writeMount(&b, &mount, t));
                try props.append(g.a(), .{ .key = "m", .value = try js.arrow(&.{ item, position, cx }, mount.block) });

                const i = try g.cx.fresh("i");
                const item2 = try g.cx.fresh("item");
                const position2 = try g.cx.fresh("position");
                var patch: Fn = .{ .block = try js.block(), .v = null, .i = i };
                _ = try g.cx.rowValues(patch.block, f.row, item2, if (row.arity == 2) position2 else null, &.{});
                try g.writePatch(&b, &patch);
                try props.append(g.a(), .{ .key = "p", .value = try js.arrow(&.{ i, item2, position2 }, patch.block) });
            },
            .lambda, .function => {
                const body = try js.block();
                const result = if (row.kind == .lambda)
                    (try g.cx.rowValues(body, f.row, item, reads, &.{})).?
                else if (row.arity == 2)
                    try g.cx.call(try g.cx.value(row.function.?), &.{ try g.ident(item), try g.ident(position) })
                else
                    try g.cx.call(try g.cx.value(row.function.?), &.{try g.ident(item)});
                try js.@"return"(body, result);
                try props.append(g.a(), .{ .key = "b", .value = try js.arrow(&.{ item, position }, body) });
            },
            else => unreachable,
        }
        try props.append(g.a(), .{ .key = "i", .value = try js.literal(if (row.arity == 2) .true else .false) });
        try props.append(g.a(), .{ .key = "f", .value = if (f.fallback) |fb| try g.cx.value(fb) else try g.nul() });
        return js.object(props.items);
    }

    /// A `Show`'s body, `(value) => block`: always a block (§15.5).
    fn showBody(g: *Gen, n: m.Node.Index) m.Error!m.Expr {
        const js = g.jsb();
        const s = g.tree.show(n);
        const row = g.tree.row(s.body);
        const x = try g.cx.fresh("value");
        const body = try js.block();
        const result = switch (row.kind) {
            .markup => blk: {
                _ = try g.cx.rowValues(body, s.body, x, null, &.{});
                const r = g.tree.root(row.body);
                break :blk try g.block(&.{r.node}, r.site.inst, null);
            },
            .lambda => (try g.cx.rowValues(body, s.body, x, null, &.{})).?,
            .function => try g.cx.call(try g.cx.value(row.function.?), &.{try g.ident(x)}),
            else => unreachable,
        };
        try js.@"return"(body, result);
        return js.arrow(&.{x}, body);
    }

    // ---- Planning -------------------------------------------------------

    fn plan(g: *Gen, nodes: []const m.Node.Index, site: u32) m.Error!Body {
        var b: Body = .{ .site = site };
        try g.childNodes(&b, null, nodes, .{}, null, .normal);
        if (b.top == 0) {
            // Markup with no nodes still owns a place on the page.
            try b.write(g.a(), "<!>");
            _ = try b.tnode(g.a(), null, 0, .marker);
        }
        if (b.top > 1) b.flags |= 4;
        if (b.flags & 4 == 0) if (b.root_element) |e| {
            const owner: ?[]const u8 = switch (e.namespace) {
                .svg => "svg",
                .mathml => "math",
                else => null,
            };
            if (owner) |o| if (!std.mem.eql(u8, e.name, o)) {
                const wrapped = try g.print("<{s}>{s}</{s}>", .{ o, b.html.items, o });
                b.html = .fromOwnedSlice(@constCast(wrapped));
                b.flags |= 2;
            };
        };
        // What the functions read: every op's nodes, and the top level's
        // first and last when there are several.
        for (b.ops.items) |op| switch (op.what) {
            .placeholder => |x| b.store(x.t),
            .attribute => |x| if (!x.constant or g.stateful(x.item)) b.store(x.t) else b.mark(x.t),
            .toggle => |x| b.store(x.t),
            .style => |x| b.store(x.t),
            .event => |x| b.store(x.t),
            else => if (op.place()) |at| {
                if (at.parent) |p| b.mark(p);
                if (at.marker == .node) b.mark(at.marker.node);
            },
        };
        // The first and last top-level nodes are the instance's; one alone
        // is the clone itself, and needs no walk.
        if (b.first.? == .node) b.mark(b.first.?.node);
        b.mark(b.last);
        return b;
    }

    fn stateful(g: *Gen, it: m.Item) bool {
        if (it.kind != .attribute or it.attribute == .none) return false;
        return g.tree.attributeFacts(it.attribute).stateful;
    }

    fn flatten(g: *Gen, out: *std.ArrayList(m.Node.Index), nodes: []const m.Node.Index) !void {
        for (nodes) |n| {
            if (g.tree.kind(n) == .fragment) {
                try g.flatten(out, g.tree.childrenOf(g.tree.fragment(n).children));
            } else try out.append(g.a(), n);
        }
    }

    fn isDynamic(g: *Gen, n: m.Node.Index) bool {
        return switch (g.tree.kind(n)) {
            .hole, .component, .for_, .show => true,
            else => false,
        };
    }

    fn isTemplate(g: *Gen, n: m.Node.Index) bool {
        return switch (g.tree.kind(n)) {
            .text, .element => true,
            else => false,
        };
    }

    /// The nearest node on one side that the template writes is text:
    /// slots are passed over, an element stops the search.
    fn textBeside(g: *Gen, list: []const m.Node.Index, from: usize, step: enum { back, forth }) bool {
        var at = from;
        while (true) {
            switch (step) {
                .back => {
                    if (at == 0) return false;
                    at -= 1;
                },
                .forth => {
                    at += 1;
                    if (at >= list.len) return false;
                },
            }
            switch (g.tree.kind(list[at])) {
                .text => return true,
                .element => return false,
                else => {},
            }
        }
    }

    fn boxedByText(g: *Gen, list: []const m.Node.Index, at: usize) bool {
        return g.textBeside(list, at, .back) and g.textBeside(list, at, .forth);
    }

    /// dom-expressions' `find_last_element`: the last child the template
    /// writes, whose end tag the parser may imply; none when several slots
    /// put a marker after it.
    fn lastElement(g: *Gen, list: []const m.Node.Index, per_slot: bool) ?usize {
        var j = list.len;
        while (j > 0) {
            j -= 1;
            if (g.isTemplate(list[j])) return j;
            if (per_slot) return null;
        }
        return null;
    }

    /// The children of `parent` (the top level when null), written in
    /// `scope`, whose content the parser reads as `content`.
    fn childNodes(
        g: *Gen,
        b: *Body,
        parent: ?u32,
        written: []const m.Node.Index,
        scope: parser.Scope,
        to_be_closed: ?[]const []const u8,
        content: parser.Content,
    ) m.Error!void {
        var flat: std.ArrayList(m.Node.Index) = .empty;
        try g.flatten(&flat, written);
        const list = flat.items;
        var dynamic: u32 = 0;
        for (list) |n| {
            if (g.isDynamic(n)) dynamic += 1;
        }
        // At the top level every slot has a marker: the template's nodes
        // move into a page, and a slot finds its parent through it.
        const per_slot = parent == null or dynamic > 1;
        const last_element = g.lastElement(list, per_slot);
        const ops_start = b.ops.items.len;
        var index: u32 = 0;
        var in_text = false;
        for (list, 0..) |n, at| {
            g.cx.at(n);
            switch (g.tree.kind(n)) {
                .text => {
                    const text = g.tree.string(g.tree.text(n).text);
                    if (parser.movesText(scope.parent)) {
                        return g.restructured(n, scope.parent.?, "the parser moves text out of a table, so it would not be where it is written");
                    }
                    if (content == .raw_text) {
                        if (parser.endsRawText(scope.parent.?, text)) {
                            return g.restructured(n, scope.parent.?, "the text holds the element's own end tag, which would close it early");
                        }
                        try b.write(g.a(), text);
                    } else try escapeText(g.a(), &b.html, text);
                    if (!in_text) {
                        _ = try b.tnode(g.a(), parent, index, .text);
                        index += 1;
                        in_text = true;
                    }
                },
                .element => {
                    in_text = false;
                    if (content != .normal) {
                        return g.restructured(n, scope.parent.?, "the parser reads this element's content as text, so a child element would be text");
                    }
                    try g.element(b, n, parent, index, scope, .{ .last = last_element == at, .to_be_closed = to_be_closed });
                    index += 1;
                },
                .hole, .component, .for_, .show => {
                    in_text = false;
                    const text_hole = g.tree.kind(n) == .hole and switch (g.tree.hole(n).kind) {
                        .text_string, .text_number, .text_char, .text_bool => true,
                        else => false,
                    };
                    if (content != .normal and !text_hole) {
                        return g.restructured(n, scope.parent.?, "the parser reads this element's content as text, so only text can be written in it");
                    }
                    if (text_hole and list.len == 1) {
                        // A text node of the template, written in place.
                        try b.write(g.a(), " ");
                        const t = try b.tnode(g.a(), parent, index, .text);
                        index += 1;
                        const value = try b.operand(g.a(), .{ .value = g.tree.hole(n).value });
                        try b.ops.append(g.a(), .{ .node = n, .what = .{ .placeholder = .{ .t = t, .value = value } } });
                        continue;
                    }
                    const op_at: u32 = @intCast(b.ops.items.len);
                    if (parent == null) {
                        // What the slot holds is placed in the clone's
                        // fragment, and the instance begins with it when it
                        // comes first.
                        b.flags |= 4;
                        if (b.first == null) b.first = if (text_hole) .{ .text = op_at } else .{ .slot = op_at };
                    }
                    var marker: Marker = .none;
                    const dedicated = if (per_slot)
                        g.boxedByText(list, at) or at + 1 >= list.len or !g.isTemplate(list[at + 1])
                    else
                        g.boxedByText(list, at);
                    if (dedicated) {
                        if (content != .normal) {
                            return g.restructured(n, scope.parent.?, "a hole here needs a marker, and the parser would read one as text");
                        }
                        try b.write(g.a(), "<!>");
                        marker = .{ .node = try b.tnode(g.a(), parent, index, .marker) };
                        index += 1;
                    } else if (per_slot) {
                        marker = .{ .next = index };
                    } else {
                        for (list[at + 1 ..]) |later| {
                            if (g.isTemplate(later)) {
                                marker = .{ .next = index };
                                break;
                            }
                        }
                    }
                    try g.slot(b, n, .{ .parent = parent, .marker = marker });
                },
                else => unreachable,
            }
        }
        // A marker that is the next node of the template, now written.
        for (b.ops.items[ops_start..]) |*op| {
            const at = switch (op.what) {
                .text => |*x| &x.at,
                .html => |*x| &x.at,
                .component => |*x| &x.at,
                .for_ => |*x| &x.at,
                .show => |*x| &x.at,
                else => continue,
            };
            if (at.parent != parent or at.marker != .next) continue;
            const want = at.marker.next;
            for (b.tnodes.items, 0..) |t, i| {
                if (t.parent == parent and t.index == want) {
                    at.marker = .{ .node = @intCast(i) };
                    break;
                }
            }
        }
    }

    fn element(g: *Gen, b: *Body, n: m.Node.Index, parent: ?u32, index: u32, scope: parser.Scope, close: Close) m.Error!void {
        const e = g.tree.element(n);
        const facts = g.tree.elementFacts(e.row);
        const name = g.tree.string(facts.name);
        if (parser.misnested(scope, name)) |why| return g.restructured(n, scope.parent orelse "", why);
        const t = try b.tnode(g.a(), parent, index, .element);
        if (parent == null) b.root_element = if (b.top == 1) .{ .name = name, .namespace = facts.namespace } else null;
        // A custom element, a customised built-in and a lazy image or
        // frame are imported rather than cloned, so the page upgrades or
        // loads them (`dom/element.rs:501-521`).
        if (std.mem.indexOfScalar(u8, name, '-') != null) b.flags |= 1;
        for (g.tree.itemsOf(e.items)) |it| {
            const written = g.tree.string(it.name);
            if (it.kind == .event) continue;
            if (std.mem.eql(u8, written, "is")) b.flags |= 1;
            if (std.mem.eql(u8, written, "loading") and (std.mem.eql(u8, name, "img") or std.mem.eql(u8, name, "iframe"))) b.flags |= 1;
        }
        try b.write(g.a(), "<");
        try b.write(g.a(), name);
        const kids = g.tree.childrenOf(e.children);
        const raw = try g.attributes(b, t, e.items);
        try b.write(g.a(), ">");
        if (parser.isVoid(name)) {
            if (kids.len != 0) return g.restructured(n, name, "the parser treats this element as void, so its content would follow it");
            return;
        }
        if (raw and kids.len != 0) {
            return g.restructured(n, name, "its content is written by a raw attribute, which replaces the children written in it");
        }
        const child_close = try g.childClose(name, close);
        // With scripting on, the parser reads `<noscript>`'s content as
        // text, and the page never shows it: dom-expressions writes none.
        if (!std.mem.eql(u8, name, "noscript")) {
            try g.childNodes(b, t, kids, scope.enter(name), child_close, parser.content(name));
        }
        if (shouldClose(name, close)) {
            try b.write(g.a(), "</");
            try b.write(g.a(), name);
            try b.write(g.a(), ">");
        }
    }

    /// `child_close_context` (`dom/attrs.rs:537-560`).
    fn childClose(g: *Gen, name: []const u8, close: Close) !?[]const []const u8 {
        if (!shouldClose(name, close)) return close.to_be_closed;
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(g.a(), close.to_be_closed orelse &always_close);
        if (!among(name, list.items)) try list.append(g.a(), name);
        if (among(name, &inline_elements)) {
            for (block_elements) |x| {
                if (!among(x, list.items)) try list.append(g.a(), x);
            }
        }
        return list.items;
    }

    /// An element's attributes, escapes and events, in source order: a
    /// constant written into the template, anything else an op. Whether a
    /// raw attribute writes the element's content.
    fn attributes(g: *Gen, b: *Body, t: u32, range: m.Range) m.Error!bool {
        var raw = false;
        var had_event = false;
        for (g.tree.itemsOf(range), 0..) |it, j| {
            const index: u32 = range.start + @as(u32, @intCast(j));
            switch (it.kind) {
                .event => {
                    const facts = g.tree.eventFacts(it.event);
                    const dom_name = g.tree.string(facts.dom_name);
                    if (facts.delegated) {
                        if (g.cx.build.library) {
                            if (!among(dom_name, b.delegated.items)) try b.delegated.append(g.a(), dom_name);
                        } else try g.cx.start("delegate", dom_name);
                    }
                    // A message written as a literal is a constant.
                    const handler = if (it.value.kind == .constant)
                        try b.operand(g.a(), .{ .constant = it.value.constant })
                    else
                        try b.operand(g.a(), .{ .value = it.value.dynamic.? });
                    try b.ops.append(g.a(), .{ .node = .none, .what = .{ .event = .{
                        .t = t,
                        .item = it,
                        .index = index,
                        .handler = handler,
                        .context = !had_event,
                    } } });
                    had_event = true;
                },
                .attribute, .escape => raw = try g.attribute(b, t, it) or raw,
                else => unreachable,
            }
        }
        return raw;
    }

    fn attribute(g: *Gen, b: *Body, t: u32, it: m.Item) m.Error!bool {
        const name = g.tree.string(it.name);
        const facts: ?m.AttributeFacts = if (it.kind == .attribute and it.attribute != .none) g.tree.attributeFacts(it.attribute) else null;
        const raw = facts != null and facts.?.raw;
        switch (it.value.kind) {
            .constant => {
                const c = it.value.constant;
                const coded = raw or it.url or (facts != null and facts.?.property != null);
                if (coded) {
                    const value = try b.operand(g.a(), .{ .constant = c });
                    try b.ops.append(g.a(), .{ .node = .none, .what = .{ .attribute = .{ .t = t, .item = it, .value = value, .constant = true } } });
                    return raw;
                }
                switch (c.kind) {
                    .string, .number => try bakeAttribute(g.a(), &b.html, name, g.tree.string(c.text)),
                    .bool => if (c.bool) try bakeAttribute(g.a(), &b.html, name, ""),
                    else => {},
                }
            },
            .dynamic => {
                const value = try b.operand(g.a(), .{ .value = it.value.dynamic.? });
                try b.ops.append(g.a(), .{ .node = .none, .what = .{ .attribute = .{ .t = t, .item = it, .value = value, .constant = false } } });
            },
            .entries => {
                if (!try g.entriesInPlace(b, t, it)) {
                    const value = try b.operand(g.a(), .{ .value = it.value.dynamic.? });
                    try b.ops.append(g.a(), .{ .node = .none, .what = .{ .attribute = .{ .t = t, .item = it, .value = value, .constant = false } } });
                }
            },
            else => unreachable,
        }
        return raw;
    }

    /// A class or style list written in place, split at compile time as
    /// dom-expressions splits an object literal (`shared/attr_plan.rs:
    /// 587-895`): constant entries into the template, a dynamic one a
    /// toggle or a property of its own. False when its names do not allow
    /// it — two alike, or one that is empty or holds whitespace — and the
    /// runtime writes the list.
    fn entriesInPlace(g: *Gen, b: *Body, t: u32, it: m.Item) m.Error!bool {
        const entries = g.tree.entriesOf(it.value.entries);
        for (entries, 0..) |e, j| {
            const name = g.tree.string(e.name);
            if (name.len == 0) return false;
            if (it.class == .class_list and std.mem.indexOfAny(u8, name, "\t\n\x0c\r ") != null) return false;
            for (entries[0..j]) |before| {
                if (std.mem.eql(u8, g.tree.string(before.name), name)) return false;
            }
        }
        var baked: std.ArrayList(u8) = .empty;
        for (entries) |e| {
            const name = g.tree.string(e.name);
            switch (e.value.kind) {
                .constant => switch (it.class) {
                    .class_list => if (e.value.constant.kind == .bool and e.value.constant.bool) {
                        if (baked.items.len != 0) try baked.append(g.a(), ' ');
                        try baked.appendSlice(g.a(), name);
                    },
                    .style_list => if (e.value.constant.kind == .string) {
                        const value = g.tree.string(e.value.constant.text);
                        if (value.len != 0) {
                            if (baked.items.len != 0) try baked.append(g.a(), ';');
                            try baked.appendSlice(g.a(), name);
                            try baked.append(g.a(), ':');
                            try baked.appendSlice(g.a(), value);
                        }
                    },
                    else => return false,
                },
                else => {
                    const value = try b.operand(g.a(), .{ .value = e.value.dynamic.? });
                    const what: Op.What = if (it.class == .class_list)
                        .{ .toggle = .{ .t = t, .name = name, .value = value } }
                    else
                        .{ .style = .{ .t = t, .name = name, .value = value } };
                    try b.ops.append(g.a(), .{ .node = .none, .what = what });
                },
            }
        }
        if (baked.items.len != 0) try bakeAttribute(g.a(), &b.html, g.tree.string(it.name), baked.items);
        return true;
    }

    /// A slot's op: a text hole, a markup hole, a component, a `For` or a
    /// `Show`.
    fn slot(g: *Gen, b: *Body, n: m.Node.Index, at: Place) m.Error!void {
        const a_ = g.a();
        const what: Op.What = switch (g.tree.kind(n)) {
            .hole => blk: {
                const h = g.tree.hole(n);
                const value = try b.operand(a_, .{ .value = h.value });
                break :blk switch (h.kind) {
                    .text_string, .text_number, .text_char, .text_bool => .{ .text = .{ .at = at, .value = value } },
                    else => .{ .html = .{ .at = at, .kind = h.kind, .value = value } },
                };
            },
            .component => blk: {
                const c = g.tree.component(n);
                var props: std.ArrayList(u32) = .empty;
                if (c.spread) |s| try props.append(a_, try b.operand(a_, .{ .value = s }));
                for (g.tree.propsOf(c.props)) |p| try props.append(a_, try b.operand(a_, .{ .value = p.value }));
                if (c.children) |v| try props.append(a_, try b.operand(a_, .{ .value = v }));
                const written = c.children_nodes.len != 0;
                const children: ?u32 = if (written) try b.operand(a_, .{ .children = .{ .node = n, .site = b.site } }) else null;
                const thunk = try b.operand(a_, .{ .thunk = .{ .node = n, .children = written } });
                break :blk .{ .component = .{ .at = at, .props = props.items, .children = children, .thunk = thunk } };
            },
            .for_ => blk: {
                const f = g.tree.for_(n);
                const row = g.tree.row(f.row);
                const each = try b.operand(a_, .{ .value = f.each });
                const key: ?u32 = if (f.mode == .key) try b.operand(a_, .{ .value = f.key.? }) else null;
                const r = try b.operand(a_, .{ .row = n });
                const inputs: ?u32 = if (row.inputs.len != 0) try b.operand(a_, .{ .inputs = row.inputs }) else null;
                break :blk .{ .for_ = .{ .at = at, .mode = f.mode, .each = each, .key = key, .row = r, .inputs = inputs } };
            },
            .show => blk: {
                const s = g.tree.show(n);
                const row = g.tree.row(s.body);
                const when = try b.operand(a_, .{ .value = s.when });
                const key: ?u32 = if (s.mode == .key) try b.operand(a_, .{ .value = s.key.? }) else null;
                const fallback: ?u32 = if (s.fallback) |v| try b.operand(a_, .{ .value = v }) else null;
                const body = try b.operand(a_, .{ .body = n });
                const inputs = try a_.alloc(u32, row.inputs.len);
                for (inputs, 0..) |*x, k| x.* = try b.operand(a_, .{ .value = row.inputs.at(@intCast(k)) });
                break :blk .{ .show = .{ .at = at, .when = when, .key = key, .fallback = fallback, .body = body, .inputs = inputs } };
            },
            else => unreachable,
        };
        try b.ops.append(a_, .{ .node = n, .what = what });
    }

    // ---- Writing the functions ------------------------------------------

    /// An operand where the function reads it: `v[k]` in a kind, the value
    /// itself in a row, a function or block made once per function.
    fn read(g: *Gen, b: *const Body, f: *Fn, k: u32) m.Error!m.Expr {
        if (f.v) |v| return g.jsb().index(try g.ident(v), try g.num(k));
        const o = b.operands.items[k];
        if (!o.made()) return g.make(o);
        if (f.made.len == 0) {
            f.made = try g.a().alloc(?m.Name, b.operands.items.len);
            @memset(f.made, null);
        }
        if (f.made[k]) |n| return g.ident(n);
        const n = try g.cx.fresh("made");
        try g.jsb().constant(f.block, n, try g.make(o));
        f.made[k] = n;
        return g.ident(n);
    }

    /// A template node: its walk in `m`, the instance's field in `p`.
    fn node(g: *Gen, f: *const Fn, t: u32) !m.Expr {
        if (f.i) |i| return g.member(try g.ident(i), try g.print("w{d}", .{t}));
        return g.ident(f.walks[t].?);
    }

    /// An instance field of `p`.
    fn fieldOf(g: *Gen, f: *const Fn, comptime fmt: []const u8, args: anytype) !m.Expr {
        return g.member(try g.ident(f.i.?), try g.print(fmt, args));
    }

    /// The mount function's statements, into `f.block`; the instance.
    fn writeMount(g: *Gen, b: *const Body, f: *Fn, t: m.Name) m.Error!m.Expr {
        const js = g.jsb();
        const a_ = g.a();
        const r = try g.cx.fresh("r");
        f.r = r;
        try js.constant(f.block, r, try js.call(try g.ident(t), &.{}));

        // Every walk before the first write.
        f.walks = try a_.alloc(?m.Name, b.tnodes.items.len);
        @memset(f.walks, null);
        const last_in = try a_.alloc(?u32, b.tnodes.items.len + 1);
        @memset(last_in, null);
        for (b.tnodes.items, 0..) |tn, i| {
            if (!tn.needed) continue;
            if (b.flags & 4 == 0 and tn.parent == null) {
                f.walks[i] = r;
                continue;
            }
            const group = tn.parent orelse b.tnodes.items.len;
            var e: m.Expr = undefined;
            var steps: u32 = undefined;
            if (last_in[group]) |prev| {
                e = try g.ident(f.walks[prev].?);
                steps = tn.index - b.tnodes.items[prev].index;
            } else {
                const base = if (tn.parent) |p| f.walks[p].? else r;
                e = try g.member(try g.ident(base), "firstChild");
                steps = tn.index;
            }
            for (0..steps) |_| e = try g.member(e, "nextSibling");
            const w = try g.cx.fresh("w");
            try js.constant(f.block, w, e);
            f.walks[i] = w;
            last_in[group] = @intCast(i);
        }

        // A `--library` build has no program start: the kind registers the
        // events it delegates.
        if (b.delegated.items.len != 0) {
            const list = try a_.alloc(m.Expr, b.delegated.items.len);
            for (list, b.delegated.items) |*x, s| x.* = try g.str(s);
            try js.expression(f.block, try g.rt("delegate", &.{try js.array(list)}));
        }

        // The slots.
        f.slots = try a_.alloc(?m.Name, b.ops.items.len);
        @memset(f.slots, null);
        f.texts = try a_.alloc(?m.Name, b.ops.items.len);
        @memset(f.texts, null);
        for (b.ops.items, 0..) |op, k| {
            if (!op.slotted()) continue;
            const at = op.place().?;
            const c = try g.cx.fresh("c");
            try js.constant(f.block, c, try g.rt("slot", &.{ try g.parentOf(f, at, false), try g.markerOf(f, at), try g.ident(f.cx.?) }));
            f.slots[k] = c;
        }

        // The writes, in source order.
        var fields: std.ArrayList(m.Property) = .empty;
        for (b.ops.items, 0..) |op, k| try g.mountOp(b, f, op, @intCast(k), &fields);

        var props: std.ArrayList(m.Property) = .empty;
        const first: m.Expr, const q: m.Expr = switch (b.first.?) {
            .node => |x| .{ try g.ident(f.walks[x].?), try g.nul() },
            .text => |k| .{ try g.ident(f.texts[k].?), try g.nul() },
            .slot => |k| .{ try g.nul(), try g.ident(f.slots[k].?) },
        };
        try props.append(a_, .{ .key = "s", .value = first });
        try props.append(a_, .{ .key = "q", .value = q });
        try props.append(a_, .{ .key = "e", .value = try g.ident(f.walks[b.last].?) });
        for (b.tnodes.items, 0..) |tn, i| {
            if (tn.stored) try props.append(a_, .{ .key = try g.print("w{d}", .{i}), .value = try g.ident(f.walks[i].?) });
        }
        for (b.ops.items, 0..) |_, k| {
            if (f.slots[k]) |c| try props.append(a_, .{ .key = try g.print("c{d}", .{k}), .value = try g.ident(c) });
            if (f.texts[k]) |x| try props.append(a_, .{ .key = try g.print("x{d}", .{k}), .value = try g.ident(x) });
        }
        try props.appendSlice(a_, fields.items);
        return js.object(props.items);
    }

    /// A slot's parent: the element, or at the top level none — the marker
    /// knows it — except for a text hole's node, made into the clone.
    fn parentOf(g: *Gen, f: *const Fn, at: Place, text: bool) !m.Expr {
        if (at.parent) |p| return g.ident(f.walks[p].?);
        if (text) return g.ident(f.r.?);
        return g.nul();
    }

    fn markerOf(g: *Gen, f: *const Fn, at: Place) !m.Expr {
        return switch (at.marker) {
            .node => |t| g.ident(f.walks[t].?),
            else => g.nul(),
        };
    }

    fn mountOp(g: *Gen, b: *const Body, f: *Fn, op: Op, k: u32, fields: *std.ArrayList(m.Property)) m.Error!void {
        const js = g.jsb();
        const a_ = g.a();
        if (op.node != .none) g.cx.at(op.node);
        switch (op.what) {
            .placeholder => |x| {
                try js.assign(f.block, try g.member(try g.node(f, x.t), "data"), try g.read(b, f, x.value));
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.value) });
            },
            .text => |x| {
                const n = try g.cx.fresh("x");
                try js.constant(f.block, n, try g.rt("insertText", &.{ try g.parentOf(f, x.at, true), try g.markerOf(f, x.at), try g.read(b, f, x.value) }));
                f.texts[k] = n;
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.value) });
            },
            .attribute => |x| {
                try g.writeAttribute(f.block, try g.node(f, x.t), x.item, try g.read(b, f, x.value), null);
                if (!x.constant) try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.value) });
            },
            .toggle => |x| {
                // Only a class that is on is written at mount: a toggle off
                // would leave an empty `class` in some DOMs.
                const then = try js.block();
                try js.expression(then, try g.method(try g.member(try g.node(f, x.t), "classList"), "toggle", &.{ try g.str(x.name), try js.literal(.true) }));
                try js.@"if"(f.block, try g.read(b, f, x.value), then, null);
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.value) });
            },
            .style => |x| {
                try js.expression(f.block, try g.method(try g.member(try g.node(f, x.t), "style"), "setProperty", &.{ try g.str(x.name), try g.read(b, f, x.value) }));
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.value) });
            },
            .event => |x| {
                const facts = g.tree.eventFacts(x.item.event);
                const dom_name = g.tree.string(facts.dom_name);
                const key = try g.print("$${s}", .{dom_name});
                try js.assign(f.block, try g.member(try g.node(f, x.t), key), try g.read(b, f, x.handler));
                if (x.item.form == .payload) {
                    const extract = try g.cx.extractor(x.index) orelse try g.jsb().name(try g.cx.runtime("identity"));
                    try js.assign(f.block, try g.member(try g.node(f, x.t), try g.print("{s}X", .{key})), extract);
                }
                var flags: u32 = 0;
                if (facts.prevent_default) flags |= 1;
                if (facts.stop_propagation) flags |= 2;
                if (facts.delegated) {
                    if (flags != 0) try js.assign(f.block, try g.member(try g.node(f, x.t), try g.print("{s}F", .{key})), try g.num(flags));
                } else {
                    try js.expression(f.block, try g.rt("listen", &.{ try g.node(f, x.t), try g.str(dom_name), try g.num(flags) }));
                }
                if (x.context) {
                    const then = try js.block();
                    try js.assign(then, try g.member(try g.node(f, x.t), "$$cx"), try g.ident(f.cx.?));
                    try js.@"if"(f.block, try js.binary(.strict_ne, try g.ident(f.cx.?), try g.nul()), then, null);
                }
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.handler) });
            },
            .html => |x| try js.expression(f.block, try g.slotWrite(b, f, x.kind, try g.ident(f.slots[k].?), x.value)),
            .component => |x| {
                for (x.props, 0..) |p, j| try fields.append(a_, .{ .key = try g.print("a{d}_{d}", .{ k, j }), .value = try g.read(b, f, p) });
                if (x.children) |ch| try fields.append(a_, .{ .key = try g.print("a{d}c", .{k}), .value = try g.read(b, f, ch) });
                try js.expression(f.block, try g.rt("childHtml", &.{ try g.ident(f.slots[k].?), try g.componentCall(b, f, op.node, x.thunk, x.children) }));
            },
            .for_ => |x| try js.expression(f.block, try g.forCall(b, f, x.mode, try g.ident(f.slots[k].?), x.each, x.key, x.row, x.inputs)),
            .show => |x| {
                const c = f.slots[k].?;
                const key = try g.cx.fresh("key");
                const shown = try g.cx.fresh("shown");
                try js.let(f.block, key, try g.ident(c));
                try js.let(f.block, shown, try g.nul());
                const then = try js.block();
                const it = try g.cx.fresh("value");
                try js.constant(then, it, try g.cx.maybe(try g.read(b, f, x.when)));
                try js.assign(then, try g.ident(key), try g.showKey(b, f, x.key, it));
                try js.assign(then, try g.ident(shown), try g.ident(it));
                try js.expression(then, try g.rt("show", &.{ try g.ident(c), try g.ident(key), try js.call(try g.read(b, f, x.body), &.{try g.ident(it)}) }));
                const otherwise = try js.block();
                try js.expression(otherwise, try g.rt("hide", &.{ try g.ident(c), if (x.fallback) |fb| try g.read(b, f, fb) else try g.nul() }));
                try js.@"if"(f.block, try g.cx.isJust(try g.read(b, f, x.when)), then, otherwise);
                try fields.append(a_, .{ .key = try g.print("a{d}k", .{k}), .value = try g.ident(key) });
                try fields.append(a_, .{ .key = try g.print("a{d}v", .{k}), .value = try g.ident(shown) });
                for (x.inputs, 0..) |in, j| try fields.append(a_, .{ .key = try g.print("a{d}i{d}", .{ k, j }), .value = try g.read(b, f, in) });
            },
        }
    }

    /// The patch function's statements, into `f.block`: a write only where
    /// a value is not the one written last.
    fn writePatch(g: *Gen, b: *const Body, f: *Fn) m.Error!void {
        const js = g.jsb();
        for (b.ops.items, 0..) |op, i| {
            const k: u32 = @intCast(i);
            if (op.node != .none) g.cx.at(op.node);
            switch (op.what) {
                .placeholder => |x| try g.guarded(b, f, x.value, k, try g.node(f, x.t), .data),
                .text => |x| try g.guarded(b, f, x.value, k, try g.fieldOf(f, "x{d}", .{k}), .data),
                .attribute => |x| {
                    if (g.stateful(x.item)) {
                        // Compared with the page's own value, so an edit the
                        // model rejected is put back (§15.3).
                        const facts = g.tree.attributeFacts(x.item.attribute);
                        const prop = g.tree.string(facts.property.?);
                        const want = try g.propertyValue(x.item, try g.read(b, f, x.value));
                        const then = try js.block();
                        try js.assign(then, try g.member(try g.node(f, x.t), prop), try g.propertyValue(x.item, try g.read(b, f, x.value)));
                        try js.@"if"(f.block, try js.binary(.strict_ne, try g.member(try g.node(f, x.t), prop), want), then, null);
                        continue;
                    }
                    if (x.constant) continue;
                    const then = try js.block();
                    try g.writeAttribute(then, try g.node(f, x.t), x.item, try g.read(b, f, x.value), try g.fieldOf(f, "a{d}", .{k}));
                    try js.assign(then, try g.fieldOf(f, "a{d}", .{k}), try g.read(b, f, x.value));
                    try js.@"if"(f.block, try js.binary(.strict_ne, try g.read(b, f, x.value), try g.fieldOf(f, "a{d}", .{k})), then, null);
                },
                .toggle => |x| try g.guarded(b, f, x.value, k, try g.node(f, x.t), .{ .toggle = x.name }),
                .style => |x| try g.guarded(b, f, x.value, k, try g.node(f, x.t), .{ .style = x.name }),
                .event => |x| {
                    const facts = g.tree.eventFacts(x.item.event);
                    try g.guarded(b, f, x.handler, k, try g.node(f, x.t), .{ .property = try g.print("$${s}", .{g.tree.string(facts.dom_name)}) });
                },
                .html => |x| try js.expression(f.block, try g.slotWrite(b, f, x.kind, try g.fieldOf(f, "c{d}", .{k}), x.value)),
                .component => |x| {
                    if (x.props.len == 0 and x.children == null) continue;
                    var changed: ?m.Expr = null;
                    const then = try js.block();
                    for (x.props, 0..) |p, j| {
                        const test_ = try js.binary(.strict_ne, try g.read(b, f, p), try g.fieldOf(f, "a{d}_{d}", .{ k, j }));
                        changed = if (changed) |c| try js.binary(.logical_or, c, test_) else test_;
                        try js.assign(then, try g.fieldOf(f, "a{d}_{d}", .{ k, j }), try g.read(b, f, p));
                    }
                    if (x.children) |ch| {
                        const test_ = try js.binary(.strict_ne, try g.read(b, f, ch), try g.fieldOf(f, "a{d}c", .{k}));
                        changed = if (changed) |c| try js.binary(.logical_or, c, test_) else test_;
                        try js.assign(then, try g.fieldOf(f, "a{d}c", .{k}), try g.read(b, f, ch));
                    }
                    try js.expression(then, try g.rt("childHtml", &.{ try g.fieldOf(f, "c{d}", .{k}), try g.componentCall(b, f, op.node, x.thunk, x.children) }));
                    try js.@"if"(f.block, changed.?, then, null);
                },
                .for_ => |x| try js.expression(f.block, try g.forCall(b, f, x.mode, try g.fieldOf(f, "c{d}", .{k}), x.each, x.key, x.row, x.inputs)),
                .show => |x| {
                    const then = try js.block();
                    const it = try g.cx.fresh("value");
                    const key = try g.cx.fresh("key");
                    try js.constant(then, it, try g.cx.maybe(try g.read(b, f, x.when)));
                    try js.constant(then, key, try g.showKey(b, f, x.key, it));
                    var changed = try js.binary(.logical_or, try js.binary(.strict_ne, try g.ident(key), try g.fieldOf(f, "a{d}k", .{k})), try js.binary(.strict_ne, try g.ident(it), try g.fieldOf(f, "a{d}v", .{k})));
                    const again = try js.block();
                    try js.assign(again, try g.fieldOf(f, "a{d}k", .{k}), try g.ident(key));
                    try js.assign(again, try g.fieldOf(f, "a{d}v", .{k}), try g.ident(it));
                    for (x.inputs, 0..) |in, j| {
                        changed = try js.binary(.logical_or, changed, try js.binary(.strict_ne, try g.read(b, f, in), try g.fieldOf(f, "a{d}i{d}", .{ k, j })));
                        try js.assign(again, try g.fieldOf(f, "a{d}i{d}", .{ k, j }), try g.read(b, f, in));
                    }
                    try js.expression(again, try g.rt("show", &.{ try g.fieldOf(f, "c{d}", .{k}), try g.ident(key), try js.call(try g.read(b, f, x.body), &.{try g.ident(it)}) }));
                    try js.@"if"(then, changed, again, null);
                    const otherwise = try js.block();
                    // The slot stands for "nothing shown": no key is it.
                    try js.assign(otherwise, try g.fieldOf(f, "a{d}k", .{k}), try g.fieldOf(f, "c{d}", .{k}));
                    try js.expression(otherwise, try g.rt("hide", &.{ try g.fieldOf(f, "c{d}", .{k}), if (x.fallback) |fb| try g.read(b, f, fb) else try g.nul() }));
                    try js.@"if"(f.block, try g.cx.isJust(try g.read(b, f, x.when)), then, otherwise);
                },
            }
        }
    }

    const Write = union(enum) { data, toggle: []const u8, style: []const u8, property: []const u8 };

    /// `if (v !== i.aK) { i.aK = v; <write>; }`.
    fn guarded(g: *Gen, b: *const Body, f: *Fn, v: u32, k: u32, target: m.Expr, w: Write) m.Error!void {
        const js = g.jsb();
        const then = try js.block();
        try js.assign(then, try g.fieldOf(f, "a{d}", .{k}), try g.read(b, f, v));
        switch (w) {
            .data => try js.assign(then, try g.member(target, "data"), try g.read(b, f, v)),
            .property => |p| try js.assign(then, try g.member(target, p), try g.read(b, f, v)),
            .toggle => |n| try js.expression(then, try g.method(try g.member(target, "classList"), "toggle", &.{ try g.str(n), try g.read(b, f, v) })),
            .style => |n| try js.expression(then, try g.method(try g.member(target, "style"), "setProperty", &.{ try g.str(n), try g.read(b, f, v) })),
        }
        try js.@"if"(f.block, try js.binary(.strict_ne, try g.read(b, f, v), try g.fieldOf(f, "a{d}", .{k})), then, null);
    }

    /// What an attribute writes, by its facts and its value's class
    /// (§15.3's table). `previous` is the list a class or style list
    /// replaces, in `p`.
    fn writeAttribute(g: *Gen, into: m.Block, el: m.Expr, it: m.Item, v: m.Expr, previous: ?m.Expr) m.Error!void {
        const js = g.jsb();
        const name = g.tree.string(it.name);
        const facts: ?m.AttributeFacts = if (it.kind == .attribute and it.attribute != .none) g.tree.attributeFacts(it.attribute) else null;
        if (facts) |fa| {
            if (fa.raw) return js.expression(into, try g.rt("rawHtml", &.{ el, v }));
            if (fa.property) |p| return js.assign(into, try g.member(el, g.tree.string(p)), try g.propertyValue(it, v));
        }
        const written: m.Expr = switch (it.class) {
            .string, .int, .float => if (it.url) try g.rt("safeUrl", &.{v}) else v,
            .bool => try js.cond(v, try g.str(""), try g.nul()),
            .maybe_string => if (it.url)
                try js.cond(try g.cx.isJust(v), try g.rt("safeUrl", &.{try g.cx.maybe(try g.copy(v))}), try g.nul())
            else
                try g.cx.maybe(v),
            .class_list => return js.expression(into, try g.rt("classes", &.{ el, v, previous orelse try g.nul() })),
            .style_list => return js.expression(into, try g.rt("styles", &.{ el, v, previous orelse try g.nul() })),
            else => unreachable,
        };
        if (namespaceOf(name)) |ns| {
            return js.expression(into, try g.rt("attrNS", &.{ el, try g.str(ns), try g.str(name), written }));
        }
        switch (it.class) {
            .string, .int, .float => try js.expression(into, try g.method(el, "setAttribute", &.{ try g.str(name), written })),
            else => try js.expression(into, try g.rt("attr", &.{ el, try g.str(name), written })),
        }
    }

    /// An expression used twice in one write: a name or a read of `v`,
    /// which is spelled again rather than shared.
    fn copy(g: *Gen, e: m.Expr) !m.Expr {
        _ = g;
        return e;
    }

    fn propertyValue(g: *Gen, it: m.Item, v: m.Expr) !m.Expr {
        return switch (it.class) {
            .maybe_string => g.cx.maybe(v),
            .string => if (it.url) g.rt("safeUrl", &.{v}) else v,
            else => v,
        };
    }

    fn slotWrite(g: *Gen, b: *const Body, f: *Fn, kind: m.HoleKind, s: m.Expr, v: u32) m.Error!m.Expr {
        return switch (kind) {
            .html => g.rt("childHtml", &.{ s, try g.read(b, f, v) }),
            .maybe_html => g.rt("childMaybe", &.{ s, try g.cx.maybe(try g.read(b, f, v)) }),
            .list_html => g.rt("childList", &.{ s, try g.read(b, f, v) }),
            else => unreachable,
        };
    }

    /// The component's block: through its call made where the markup is
    /// evaluated, in a kind; called in place, in a row.
    fn componentCall(g: *Gen, b: *const Body, f: *Fn, n: m.Node.Index, thunk: u32, children: ?u32) m.Error!m.Expr {
        if (f.v != null) {
            const args: []const m.Expr = if (children) |ch| &.{try g.read(b, f, ch)} else &.{};
            return g.jsb().call(try g.read(b, f, thunk), args);
        }
        return g.cx.componentCall(n, if (children) |ch| try g.read(b, f, ch) else null);
    }

    fn forCall(g: *Gen, b: *const Body, f: *Fn, mode: m.For.Mode, s: m.Expr, each: u32, key: ?u32, row: u32, inputs: ?u32) m.Error!m.Expr {
        const in = if (inputs) |x| try g.read(b, f, x) else try g.nul();
        return switch (mode) {
            .position => g.rt("forPosition", &.{ s, try g.read(b, f, each), try g.read(b, f, row), in }),
            else => g.rt("forKeyed", &.{ s, try g.read(b, f, each), if (key) |x| try g.read(b, f, x) else try g.nul(), try g.read(b, f, row), in }),
        };
    }

    fn showKey(g: *Gen, b: *const Body, f: *Fn, key: ?u32, it: m.Name) m.Error!m.Expr {
        if (key) |x| return g.cx.call(try g.read(b, f, x), &.{try g.ident(it)});
        return g.ident(it);
    }
};

/// The namespace of a prefixed attribute name the page writes with
/// `setAttributeNS`.
fn namespaceOf(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "xlink:")) return "http://www.w3.org/1999/xlink";
    if (std.mem.startsWith(u8, name, "xml:")) return "http://www.w3.org/XML/1998/namespace";
    return null;
}

/// Text as the page's parser reads it back: `&` and `<` would begin a
/// reference or a tag, and a carriage return would become a line feed.
fn escapeText(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

/// A constant attribute in the template, as dom-expressions writes one:
/// bare when empty, unquoted when HTML allows it, and with no space after
/// a quoted value (`shared/utils.rs:271-290`, `dom/attrs.rs:599-631`).
fn bakeAttribute(a: Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (out.items.len == 0 or out.items[out.items.len - 1] != '"') try out.append(a, ' ');
    try out.appendSlice(a, name);
    if (value.len == 0) return;
    try out.append(a, '=');
    const quoted = for (value) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', '"', '\'', '`', '=', '<', '>' => break true,
            else => {},
        }
    } else false;
    if (quoted) try out.append(a, '"');
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
    if (quoted) try out.append(a, '"');
}

test "constant attributes are written as dom-expressions writes them" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try out.appendSlice(t.allocator, "<span");
    try bakeAttribute(t.allocator, &out, "class", "glyphicon glyphicon-remove");
    try bakeAttribute(t.allocator, &out, "aria-hidden", "true");
    try bakeAttribute(t.allocator, &out, "hidden", "");
    try bakeAttribute(t.allocator, &out, "title", "a&b<c");
    try t.expectEqualStrings("<span class=\"glyphicon glyphicon-remove\"aria-hidden=true hidden title=a&amp;b&lt;c", out.items);
}

test "text is escaped as the parser reads it back" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try escapeText(t.allocator, &out, "a < b & c\r");
    try t.expectEqualStrings("a &lt; b &amp; c&#13;", out.items);
}
