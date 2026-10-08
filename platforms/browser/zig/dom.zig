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
    .targets = .{ .major = 1, .minor = 5 },
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
        // `(slot)`: what the slot shows patched again when it must be on
        // every render — a skipped helper's or component's markup.
        .{ .name = "restate", .arity = 1 },
        // `(el, prop, value)`: a `stateful` attribute's write, its value
        // kept on the element for the page's side of the promise.
        .{ .name = "control", .arity = 3 },
        // `(el)`: a controlled element a write of this render may have
        // changed, put back when the render ends (§15.3, *Controlled
        // inputs*).
        .{ .name = "edited", .arity = 1 },
    },
    .module = module,
    .root = root,
    // A root computes its own values, by what they read (backend.md §15.4,
    // *A root computes its own values*).
    .groups = true,
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
    if (cx.grouped(index)) return g.groupedBlock(r, index);
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
        /// A helper call in an `html` hole (`Hole.call`): made only when an
        /// argument is not the one kept (language.md §11.6).
        helper: struct { at: Place, callee: m.Value.Index, args: []const u32, impure: bool },
        component: struct { at: Place, props: []const u32, children: ?u32, thunk: u32, impure: bool },
        for_: struct { at: Place, mode: m.For.Mode, each: u32, key: ?u32, row: u32, inputs: ?u32 },
        show: struct { at: Place, when: u32, key: ?u32, fallback: ?u32, body: u32, inputs: []const u32 },
    };

    fn place(op: Op) ?Place {
        return switch (op.what) {
            .text => |x| x.at,
            .html => |x| x.at,
            .helper => |x| x.at,
            .component => |x| x.at,
            .for_ => |x| x.at,
            .show => |x| x.at,
            else => null,
        };
    }

    /// Whether the op owns a slot of the runtime's.
    fn slotted(op: Op) bool {
        return switch (op.what) {
            .html, .helper, .component, .for_, .show => true,
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
    /// `m` of a row that mounts through its patch (§15.5): it writes only
    /// what `p` never does, and leaves every kept value `undefined`.
    through: bool = false,
    /// A grouped root's `m` or `p` (backend.md §15.4, *A root computes its
    /// own values*): every write is `p`'s, made in its op's group.
    grouped: bool = false,
    /// `m` of a grouped root: its groups' fields, each `undefined`.
    group_fields: []const m.Property = &.{},
    /// A grouped root, per op: the name its group read its one path into
    /// when the op writes exactly that path, which needs no test of its own
    /// and keeps no value (null otherwise).
    direct: []const ?m.Name = &.{},
    /// A grouped root's `p`, writing the group that runs at mount only.
    once: bool = false,
    /// A grouped root's `m`: per op, whether it is a constant attribute
    /// written under a test of its own field (in a group that may run
    /// again).
    guarded: []const bool = &.{},
    /// A row's `m` or `p`: a `stateful` attribute keeps its value
    /// (`a<k>`), which the row's `r` writes again.
    row: bool = false,
    /// The markup is live for its own sake (`selfLive`).
    self_live: bool = false,
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
            const at = @backingInt(n);
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

    // ---- Grouped roots (backend.md §15.4, *A root computes its own values*)

    /// The block a grouped root evaluates to: its kind, hoisted once per
    /// site, and its inputs.
    fn groupedBlock(g: *Gen, r: m.Root, index: m.Root.Index) m.Error!m.Expr {
        const js = g.jsb();
        const n = try g.names(r.site.inst, null);
        var b = try g.plan(&.{r.node}, r.site.inst);
        // Markup that writes nothing is one hoisted block, as before.
        if (b.ops.items.len == 0) return g.block(&.{r.node}, r.site.inst, null);
        const kind = g.cx.hoisted(n.kind) orelse try g.hoistGroupedKind(&b, n, r, index);
        // A root with no input is one hoisted block; a slot handed it again
        // patches it again only when its kind is live (`Rt.patch`).
        if (r.inputs.len == 0) {
            if (g.cx.hoisted(n.block)) |h| return g.ident(h);
            return g.ident(try g.cx.hoist(n.block, try js.object(&.{
                .{ .key = "t", .value = try g.ident(kind) },
                .{ .key = "v", .value = try g.nul() },
            })));
        }
        const values = try g.a().alloc(m.Expr, r.inputs.len);
        for (values, 0..) |*v, k| v.* = try g.cx.value(r.inputs.at(@intCast(k)));
        return js.object(&.{
            .{ .key = "t", .value = try g.ident(kind) },
            .{ .key = "v", .value = try js.array(values) },
        });
    }

    /// Whether a render that skips this markup must patch it again for its
    /// own sake (backend.md §15.4, as amended after the third review and
    /// on 2026-10-08): when `every`, for a grouped root or a row, whose
    /// patch evaluates its values, one of its values is evaluated on every
    /// render (`tree.everyRender`). A `stateful` attribute no longer is a
    /// reason: the controls a render may leave changed are marked and put
    /// back (§15.3, *Controlled inputs*). Whether an instance is live (`l`)
    /// is this, or any of its slots being live.
    fn selfLive(g: *Gen, b: *const Body, every: bool) m.Error!bool {
        if (!every) return false;
        for (b.ops.items) |op| if (try g.everyValue(b, op)) return true;
        return false;
    }

    fn everyValue(g: *Gen, b: *const Body, op: Op) m.Error!bool {
        var values: std.ArrayList(m.Value.Index) = .empty;
        try g.opValues(b, op, &values);
        for (values.items) |v| if (g.tree.everyRender(v)) return true;
        return false;
    }

    /// An instance's `l`: `true` when the markup is live for its own sake,
    /// else whether one of its slots is (`c<k>.l`, and a list's `c<k>.w`),
    /// each slot read by `slot`; null when it has no slot and is not.
    fn liveOf(g: *Gen, b: *const Body, self: bool, f: *const Fn, from_locals: bool) m.Error!?m.Expr {
        const js = g.jsb();
        if (self) return try js.literal(.true);
        var e: ?m.Expr = null;
        for (b.ops.items, 0..) |op, k| {
            if (!op.slotted()) continue;
            const slot_ = if (from_locals) try g.ident(f.slots[k].?) else try g.fieldOf(f, "c{d}", .{k});
            const parts: []const []const u8 = switch (op.what) {
                .for_ => &.{ "w", "l" },
                .html => |x| if (x.kind == .list_html) &.{"w"} else &.{"l"},
                else => &.{"l"},
            };
            for (parts) |part| {
                const x = try g.member(slot_, part);
                e = if (e) |c| try js.binary(.logical_or, c, x) else x;
            }
        }
        return e;
    }

    /// `i.l = …` at the end of a patch whose slots may have changed.
    fn writeLive(g: *Gen, b: *const Body, f: *const Fn, self: bool) m.Error!void {
        if (self) return;
        const e = try g.liveOf(b, false, f, false) orelse return;
        try g.jsb().assign(f.block, try g.member(try g.ident(f.i.?), "l"), e);
    }

    /// One group of a grouped root's ops: the paths it reads (positions in
    /// `Root.reads`), whether it runs on every render, and its ops.
    const Group = struct {
        reads: std.ArrayList(u32) = .empty,
        every: bool = false,
        first: u32,
        ops: std.ArrayList(u32) = .empty,
    };

    /// The values an op is written from, and so evaluated in its group: its
    /// operands' values, a list written in place's entries, and what a row,
    /// a `Show`'s body, a component's call and its children are made of.
    fn opValues(g: *Gen, b: *const Body, op: Op, out: *std.ArrayList(m.Value.Index)) m.Error!void {
        const a_ = g.a();
        switch (op.what) {
            .attribute => |x| if (x.item.value.kind == .entries) for (g.tree.entriesOf(x.item.value.entries)) |e| {
                if (e.value.dynamic) |dv| try out.append(a_, dv);
            },
            .component, .for_, .show => try g.nodeValues(op.node, false, out),
            else => {},
        }
        var ks: std.ArrayList(u32) = .empty;
        try opOperandList(a_, op, &ks);
        for (ks.items) |k| switch (b.operands.items[k]) {
            .value => |v| try out.append(a_, v),
            else => {},
        };
    }

    /// Every value a node reads, its children's included, but not a row's
    /// or a `Show`'s body (placed where the row is) nor a row's captures,
    /// whose reads are its inputs (language.md §11.9).
    fn nodeValues(g: *Gen, n: m.Node.Index, within: bool, out: *std.ArrayList(m.Value.Index)) m.Error!void {
        const a_ = g.a();
        const t = g.tree;
        switch (t.kind(n)) {
            .element => {
                const e = t.element(n);
                for (t.itemsOf(e.items)) |it| {
                    if (it.value.dynamic) |v| try out.append(a_, v);
                    if (it.value.kind == .entries) for (t.entriesOf(it.value.entries)) |entry| {
                        if (entry.value.dynamic) |dv| try out.append(a_, dv);
                    };
                }
                for (t.childrenOf(e.children)) |c| try g.nodeValues(c, true, out);
            },
            .fragment => for (t.childrenOf(t.fragment(n).children)) |c| try g.nodeValues(c, true, out),
            .text => {},
            .hole => {
                const h = t.hole(n);
                try out.append(a_, h.value);
                if (h.call) |c| for (0..c.args.len) |k| try out.append(a_, c.args.at(@intCast(k)));
            },
            .component => {
                const c = t.component(n);
                if (c.spread) |v| try out.append(a_, v);
                for (t.propsOf(c.props)) |prop| try out.append(a_, prop.value);
                if (c.children) |v| try out.append(a_, v);
                for (t.childrenOf(c.children_nodes)) |child| try g.nodeValues(child, true, out);
            },
            .for_ => {
                const f = t.for_(n);
                try out.append(a_, f.each);
                if (f.key) |v| try out.append(a_, v);
                if (f.fallback) |v| try out.append(a_, v);
                try g.rowValuesOf(f.row, out);
            },
            .show => {
                const s = t.show(n);
                try out.append(a_, s.when);
                if (s.key) |v| try out.append(a_, v);
                if (s.fallback) |v| try out.append(a_, v);
                try g.rowValuesOf(s.body, out);
            },
            else => {},
        }
        _ = within;
    }

    /// What a row reads of its enclosing root: its function, its inputs and
    /// its selector's probe.
    fn rowValuesOf(g: *Gen, ri: m.Row.Index, out: *std.ArrayList(m.Value.Index)) m.Error!void {
        const a_ = g.a();
        const row = g.tree.row(ri);
        if (row.function) |v| try out.append(a_, v);
        for (0..row.inputs.len) |k| try out.append(a_, row.inputs.at(@intCast(k)));
        if (row.selector) |sel| try out.append(a_, sel.probe);
    }

    fn hoistGroupedKind(g: *Gen, b: *Body, n: Names, r: m.Root, index: m.Root.Index) m.Error!m.Name {
        const js = g.jsb();
        const a_ = g.a();
        const ops = b.ops.items;
        // A constant attribute that needs code is written by `p` too, so
        // the instance keeps its element.
        for (ops) |op| switch (op.what) {
            .attribute => |x| b.store(x.t),
            else => {},
        };

        // Each op's values and paths, and whether it runs on every render.
        const op_values = try a_.alloc([]const m.Value.Index, ops.len);
        const op_reads = try a_.alloc([]const u32, ops.len);
        const op_every = try a_.alloc(bool, ops.len);
        for (ops, 0..) |op, k| {
            var values: std.ArrayList(m.Value.Index) = .empty;
            try g.opValues(b, op, &values);
            var reads: std.ArrayList(u32) = .empty;
            // A call that may have an effect is made on every render; any
            // other slot is restated when its group is skipped. A
            // `stateful` attribute is tested like any op (§15.3,
            // *Controlled inputs*).
            var every = switch (op.what) {
                .helper => |x| x.impure,
                .component => |x| x.impure,
                else => false,
            };
            for (values.items) |v| {
                if (g.tree.everyRender(v)) every = true;
                for (g.tree.readsOf(v)) |rd| {
                    if (std.mem.indexOfScalar(u32, reads.items, rd) == null) try reads.append(a_, rd);
                }
            }
            std.mem.sort(u32, reads.items, {}, std.sort.asc(u32));
            op_values[k] = values.items;
            op_reads[k] = reads.items;
            op_every[k] = every;
        }

        // Ops that read the same paths are one group; `parent` merges them.
        const parent = try a_.alloc(u32, ops.len);
        var by_key: std.StringHashMapUnmanaged(u32) = .empty;
        for (parent, 0..) |*x, k| {
            const key = try std.fmt.allocPrint(a_, "{}:{any}", .{ op_every[k], op_reads[k] });
            const gop = try by_key.getOrPut(a_, key);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(k);
            x.* = gop.value_ptr.*;
        }
        // A value two ops read is evaluated in one group: theirs merge.
        var top: u32 = 0;
        for (op_values) |values| for (values) |v| {
            top = @max(top, @backingInt(v) + 1);
        };
        const reader = try a_.alloc(u32, top);
        @memset(reader, std.math.maxInt(u32));
        for (op_values, 0..) |values, k| for (values) |v| {
            const at = @backingInt(v);
            if (reader[at] == std.math.maxInt(u32)) {
                reader[at] = @intCast(k);
                continue;
            }
            const gx = find(parent, reader[at]);
            const gy = find(parent, @intCast(k));
            if (gx != gy) parent[@max(gx, gy)] = @min(gx, gy);
        };
        // An element's attributes are written in source order on a mount:
        // the groups of two that would not be merge, until none would.
        const on = try a_.alloc(std.ArrayList(u32), b.tnodes.items.len);
        for (on) |*x| x.* = .empty;
        for (ops, 0..) |op, k| if (elementOf(op)) |t| try on[t].append(a_, @intCast(k));
        const first = try a_.alloc(u32, ops.len);
        var changed = true;
        while (changed) {
            changed = false;
            @memset(first, std.math.maxInt(u32));
            for (0..ops.len) |k| {
                const root_ = find(parent, @intCast(k));
                first[root_] = @min(first[root_], @as(u32, @intCast(k)));
            }
            for (on) |list| for (list.items, 0..) |x, xi| for (list.items[xi + 1 ..]) |y| {
                const gx = find(parent, x);
                const gy = find(parent, y);
                if (gx != gy and first[gx] > first[gy]) {
                    parent[@max(gx, gy)] = @min(gx, gy);
                    changed = true;
                }
            };
        }

        // The groups, by their first op.
        var groups: std.ArrayList(Group) = .empty;
        const group_at = try a_.alloc(u32, ops.len);
        @memset(group_at, std.math.maxInt(u32));
        for (ops, 0..) |_, k| {
            const root_ = find(parent, @intCast(k));
            if (group_at[root_] == std.math.maxInt(u32)) {
                group_at[root_] = @intCast(groups.items.len);
                try groups.append(a_, .{ .first = @intCast(k) });
            }
            const gr = &groups.items[group_at[root_]];
            try gr.ops.append(a_, @intCast(k));
            gr.every = gr.every or op_every[k];
            for (op_reads[k]) |rd| {
                if (std.mem.indexOfScalar(u32, gr.reads.items, rd) == null) try gr.reads.append(a_, rd);
            }
        }

        // `p`: the inputs, then each group under its test.
        const i = try g.cx.fresh("i");
        const pv = try g.cx.fresh("v");
        const pblock = try js.block();
        const inputs = try a_.alloc(m.Name, r.inputs.len);
        for (inputs, 0..) |*x, k| {
            x.* = try g.cx.fresh("in");
            try js.constant(pblock, x.*, try js.index(try g.ident(pv), try g.num(@intCast(k))));
        }
        try g.cx.bindInputs(index, inputs);
        var patch: Fn = .{ .block = pblock, .v = null, .i = i, .grouped = true };
        var fields: std.ArrayList(m.Property) = .empty;
        const undef = try js.literal(.undefined);
        // What a read-path field holds before the first render: `NaN`, which
        // differs from every value — `undefined` would not, since under
        // `--release` a `⊤` may be `undefined` (§4, *A `()` result is not
        // written*) and a group reading only one would never run at mount.
        const unseen = try js.number("NaN");
        // The `let`s only this root reads, first, each under the test of
        // what it reads, and kept: `d<k>` (backend.md §15.4, *The `let`
        // rule*).
        for (0..r.lets.len) |k| {
            const lv = r.lets.at(@intCast(k));
            const then = try js.block();
            const kept = try g.print("d{d}", .{k});
            var condition: ?m.Expr = null;
            const reads = g.tree.readsOf(lv);
            if (reads.len == 0) {
                condition = try js.binary(.strict_eq, try g.member(try g.ident(i), kept), undef);
            } else for (reads, 0..) |rd, j| {
                const field = try g.print("l{d}_{d}", .{ k, j });
                const path = r.reads.at(rd);
                const test_ = try js.binary(.strict_ne, try g.cx.value(path), try g.member(try g.ident(i), field));
                condition = if (condition) |c| try js.binary(.logical_or, c, test_) else test_;
                try js.assign(then, try g.member(try g.ident(i), field), try g.cx.value(path));
                try fields.append(a_, .{ .key = field, .value = unseen });
            }
            try g.cx.rootValues(then, index, &.{lv});
            try js.assign(then, try g.member(try g.ident(i), kept), try g.cx.value(lv));
            try js.@"if"(pblock, condition.?, then, null);
            try fields.append(a_, .{ .key = kept, .value = undef });
            const name = try g.cx.fresh("let");
            try js.constant(pblock, name, try g.member(try g.ident(i), kept));
            try g.cx.bindLet(index, @intCast(k), name);
        }
        const direct = try a_.alloc(?m.Name, ops.len);
        @memset(direct, null);
        patch.direct = direct;
        for (groups.items, 0..) |gr, gi| {
            const then = try js.block();
            var condition: ?m.Expr = null;
            // A group that reads one path reads it once, into a name; an
            // op that writes exactly that path writes the name, untested.
            const one: ?m.Name = if (!gr.every and gr.reads.items.len == 1) blk: {
                const x = try g.cx.fresh("x");
                try js.constant(pblock, x, try g.cx.value(r.reads.at(gr.reads.items[0])));
                break :blk x;
            } else null;
            var skip: std.ArrayList(m.Value.Index) = .empty;
            if (one) |x| for (gr.ops.items) |k| {
                const v = directValue(g, b, ops[k]) orelse continue;
                if (g.tree.pathOf(v) != gr.reads.items[0]) continue;
                direct[k] = x;
                try skip.append(a_, v);
            };
            if (one) |x| {
                const field = try g.print("g{d}_0", .{gi});
                condition = try js.binary(.strict_ne, try g.ident(x), try g.member(try g.ident(i), field));
                try js.assign(then, try g.member(try g.ident(i), field), try g.ident(x));
                try fields.append(a_, .{ .key = field, .value = unseen });
            } else if (!gr.every) {
                if (gr.reads.items.len == 0) {
                    const field = try g.print("g{d}", .{gi});
                    condition = try js.binary(.strict_eq, try g.member(try g.ident(i), field), undef);
                    try js.assign(then, try g.member(try g.ident(i), field), try js.literal(.true));
                    try fields.append(a_, .{ .key = field, .value = undef });
                } else for (gr.reads.items, 0..) |rd, j| {
                    const field = try g.print("g{d}_{d}", .{ gi, j });
                    const path = r.reads.at(rd);
                    const test_ = try js.binary(.strict_ne, try g.cx.value(path), try g.member(try g.ident(i), field));
                    condition = if (condition) |c| try js.binary(.logical_or, c, test_) else test_;
                    try js.assign(then, try g.member(try g.ident(i), field), try g.cx.value(path));
                    try fields.append(a_, .{ .key = field, .value = unseen });
                }
            }
            var values: std.ArrayList(m.Value.Index) = .empty;
            const mask = try a_.alloc(bool, ops.len);
            @memset(mask, false);
            for (gr.ops.items) |k| {
                mask[k] = true;
                for (op_values[k]) |v| {
                    if (direct[k] != null and std.mem.indexOfScalar(m.Value.Index, skip.items, v) != null) continue;
                    try values.append(a_, v);
                }
            }
            try g.cx.rootValues(then, index, values.items);
            patch.block = then;
            patch.made = &.{};
            patch.once = !gr.every and gr.reads.items.len == 0;
            try g.writePatch(b, &patch, mask, true);
            // A control a write of the group's may have changed is marked
            // (§15.3, *Controlled inputs*, the runtime's marks).
            try g.writeMarks(b, &patch, then, gr.ops.items);
            // A skipped group's slots are restated: what they show may hold
            // an every-render value at any depth (backend.md §15.4, as
            // amended after the second review).
            const otherwise = try js.block();
            var restates = false;
            for (gr.ops.items) |k| if (ops[k].slotted()) {
                try g.writeRestateSlot(b, &patch, otherwise, ops[k], try g.fieldOf(&patch, "c{d}", .{k}));
                restates = true;
            };
            if (condition) |c| try js.@"if"(pblock, c, then, if (restates) otherwise else null) else try js.nested(pblock, then);
        }
        const self = try g.selfLive(b, true);
        patch.block = pblock;
        try g.writeLive(b, &patch, self);
        g.cx.unbindInputs(index);
        const p_name = try g.cx.hoist(try g.print("p{d}", .{r.site.inst}), try js.arrow(&.{ i, pv }, pblock));

        // `m`: the clone and what only it writes, the instance, then `p`.
        const t = try g.template(b, n.template);
        const v = try g.cx.fresh("v");
        const cx = try g.cx.fresh("cx");
        const guards = try a_.alloc(bool, ops.len);
        @memset(guards, false);
        for (groups.items) |gr| {
            if (!gr.every and gr.reads.items.len == 0) continue;
            for (gr.ops.items) |k| switch (ops[k].what) {
                .attribute => |x| guards[k] = x.constant and !g.stateful(x.item),
                else => {},
            };
        }
        var mount: Fn = .{ .block = try js.block(), .v = v, .cx = cx, .through = true, .grouped = true, .group_fields = fields.items, .direct = direct, .guarded = guards, .self_live = self };
        const object = try g.writeMount(b, &mount, t);
        const inst = try g.cx.fresh("i");
        try js.constant(mount.block, inst, object);
        try js.expression(mount.block, try js.call(try g.ident(p_name), &.{ try g.ident(inst), try g.ident(v) }));
        try js.@"return"(mount.block, try g.ident(inst));
        var props: std.ArrayList(m.Property) = .empty;
        try props.append(a_, .{ .key = "m", .value = try js.arrow(&.{ v, cx }, mount.block) });
        try props.append(a_, .{ .key = "p", .value = try g.ident(p_name) });
        if (try g.liveOf(b, self, &patch, false) != null) try props.append(a_, .{ .key = "l", .value = try js.literal(.true) });
        return g.cx.hoist(n.kind, try js.object(props.items));
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
        // Its values are evaluated where the markup is, never by `p`, so
        // it is never live for its own sake.
        const self = try g.selfLive(b, false);
        var mount: Fn = .{ .block = try js.block(), .v = v, .cx = cx, .self_live = self };
        const instance = try g.writeMount(b, &mount, t);
        try g.writeMarks(b, &mount, mount.block, null);
        try js.@"return"(mount.block, instance);
        const i = try g.cx.fresh("i");
        const pv = try g.cx.fresh("v");
        var patch: Fn = .{ .block = try js.block(), .v = pv, .i = i };
        try g.writePatch(b, &patch, null, false);
        try g.writeMarks(b, &patch, patch.block, null);
        try g.writeLive(b, &patch, self);
        var props: std.ArrayList(m.Property) = .empty;
        try props.append(g.a(), .{ .key = "m", .value = try js.arrow(&.{ v, cx }, mount.block) });
        try props.append(g.a(), .{ .key = "p", .value = try js.arrow(&.{ i, pv }, patch.block) });
        // `l`: an instance of the kind can be live, so a slot showing one
        // keeps whether it is (`Rt.held`).
        if (try g.liveOf(b, self, &patch, false) != null) try props.append(g.a(), .{ .key = "l", .value = try js.literal(.true) });
        return g.cx.hoist(n.kind, try js.object(props.items));
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

                // What reads only the item is computed and written under
                // one test of the item, so a row patched because an input
                // changed leaves it alone (language.md §11.11).
                // A row with no inputs that does not read its position is
                // patched only when its item changed: nothing to guard.
                const apart = try g.itemOnlyOps(&b);
                if (row.inputs.len == 0 and row.arity == 1) @memset(apart, false);
                // A row whose `p` writes what `m` would, in the same order,
                // mounts through it: the runtime calls `p` on the instance
                // `m` returns (§15.5, *a row mounts through its patch*).
                const through = try g.mountsThroughPatch(&b, body, apart);

                const self = try g.selfLive(&b, true);
                const cx = try g.cx.fresh("cx");
                var mount: Fn = .{ .block = try js.block(), .v = null, .cx = cx, .through = through, .row = true, .self_live = self };
                if (!through) _ = try g.cx.rowValues(mount.block, f.row, item, reads, &.{});
                const instance = try g.writeMount(&b, &mount, t);
                if (!through) try g.writeMarks(&b, &mount, mount.block, null);
                try js.@"return"(mount.block, instance);
                try props.append(g.a(), .{ .key = "m", .value = try js.arrow(&.{ item, position, cx }, mount.block) });

                const i = try g.cx.fresh("i");
                const item2 = try g.cx.fresh("item");
                const position2 = try g.cx.fresh("position");
                var patch: Fn = .{ .block = try js.block(), .v = null, .i = i, .row = true };
                const apart_block = try js.block();
                _ = try g.cx.rowValuesApart(patch.block, apart_block, f.row, item2, if (row.arity == 2) position2 else null, &.{}, try g.apartValues(&b, apart));
                try g.writePatch(&b, &patch, apart, false);
                if (std.mem.indexOfScalar(bool, apart, true) != null) {
                    const main = patch.block;
                    patch.block = apart_block;
                    try g.writePatch(&b, &patch, apart, true);
                    patch.block = main;
                    try js.@"if"(patch.block, try js.binary(.strict_ne, try g.ident(item2), try g.member(try g.ident(i), "x")), apart_block, null);
                }
                try g.writeMarks(&b, &patch, patch.block, null);
                try g.writeLive(&b, &patch, self);
                try props.append(g.a(), .{ .key = "p", .value = try js.arrow(&.{ i, item2, position2 }, patch.block) });
                if (through) try props.append(g.a(), .{ .key = "w", .value = try js.literal(.true) });
                // How a live row a render skips is patched again (backend.md
                // §15.4, as amended after the third review): by `p` with
                // the item it shows when it has a value evaluated on every
                // render (`e`), else by `r`, which evaluates nothing.
                var every = false;
                for (b.ops.items) |op| if (try g.everyValue(&b, op)) {
                    every = true;
                };
                // `l`: a row of it can be live, so a list keeps whether one
                // is (`Rt.passed`).
                if (every or try g.liveOf(&b, self, &patch, false) != null) try props.append(g.a(), .{ .key = "l", .value = try js.literal(.true) });
                if (every) {
                    try props.append(g.a(), .{ .key = "e", .value = try js.literal(.true) });
                } else if (try g.liveOf(&b, self, &patch, false) != null) {
                    const ri = try g.cx.fresh("i");
                    var restate: Fn = .{ .block = try js.block(), .v = null, .i = ri, .row = true };
                    try g.writeRestate(&b, &restate);
                    try props.append(g.a(), .{ .key = "r", .value = try js.arrow(&.{ri}, restate.block) });
                }
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
        // A selector (backend.md §15.5): which input it is, and this
        // render's probe, which `forKeyed` looks up in its key map when
        // the selection is all that changed.
        if (row.kind == .markup and f.mode != .position) if (row.selector) |sel| {
            try props.append(g.a(), .{ .key = "g", .value = try g.num(sel.input) });
            try props.append(g.a(), .{ .key = "z", .value = try g.cx.value(sel.probe) });
        };
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
                .helper => |*x| &x.at,
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
                // A constant URL is checked here, as the runtime's `safeUrl`
                // would check it at the mount, and written into the template
                // — what `safeUrl` writes, `""` for a script URL — unless
                // the check cannot be decided without Unicode's whitespace.
                const script: ?bool = if (!it.url) false else switch (c.kind) {
                    .string => scriptUrl(g.tree.string(c.text)),
                    .number => false,
                    else => null,
                };
                const coded = raw or script == null or (facts != null and facts.?.property != null);
                if (coded) {
                    const value = try b.operand(g.a(), .{ .constant = c });
                    try b.ops.append(g.a(), .{ .node = .none, .what = .{ .attribute = .{ .t = t, .item = it, .value = value, .constant = true } } });
                    return raw;
                }
                switch (c.kind) {
                    .string, .number => try bakeAttribute(g.a(), &b.html, name, if (script.?) "" else g.tree.string(c.text)),
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
                if (h.kind == .html) if (h.call) |call| {
                    const args = try a_.alloc(u32, call.args.len);
                    for (args, 0..) |*x, k| x.* = try b.operand(a_, .{ .value = call.args.at(@intCast(k)) });
                    break :blk .{ .helper = .{ .at = at, .callee = call.callee, .args = args, .impure = g.tree.everyRender(h.value) } };
                };
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
                break :blk .{ .component = .{ .at = at, .props = props.items, .children = children, .thunk = thunk, .impure = c.impure } };
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
        for (b.ops.items, 0..) |op, k| {
            if (f.grouped)
                try g.mountGroupedOp(b, f, op, @intCast(k), &fields)
            else if (f.through)
                try g.mountOnlyOp(f, op, @intCast(k), &fields)
            else
                try g.mountOp(b, f, op, @intCast(k), &fields);
        }
        // Not yet shown with any item: `p`'s test of the item holds.
        if (f.through and !f.grouped) try fields.append(a_, .{ .key = "x", .value = try js.literal(.undefined) });
        try fields.appendSlice(a_, f.group_fields);

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
        // Whether the instance is live (`l`): for an `m` that leaves its
        // writes to `p`, only when it is for its own sake, as `p` says the
        // rest; else from the slots `m` has just filled.
        if (f.grouped or f.through) {
            if (f.self_live) try props.append(a_, .{ .key = "l", .value = try js.literal(.true) });
        } else if (try g.liveOf(b, f.self_live, f, true)) |e| try props.append(a_, .{ .key = "l", .value = e });
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
                if (g.stateful(x.item)) {
                    try g.writeControl(f.block, try g.node(f, x.t), x.item, try g.read(b, f, x.value));
                    return;
                }
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
                try g.mountEvent(f, x, try g.read(b, f, x.handler));
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try g.read(b, f, x.handler) });
            },
            .html => |x| try js.expression(f.block, try g.slotWrite(b, f, x.kind, try g.ident(f.slots[k].?), x.value)),
            .helper => |x| {
                for (x.args, 0..) |p, j| {
                    if (g.constantOperand(b, p)) continue;
                    try fields.append(a_, .{ .key = try g.print("a{d}_{d}", .{ k, j }), .value = try g.read(b, f, p) });
                }
                try js.expression(f.block, try g.rt("childHtml", &.{ try g.ident(f.slots[k].?), try g.helperCall(b, f, x.callee, x.args) }));
            },
            .component => |x| {
                for (x.props, 0..) |p, j| {
                    if (g.constantOperand(b, p)) continue;
                    try fields.append(a_, .{ .key = try g.print("a{d}_{d}", .{ k, j }), .value = try g.read(b, f, p) });
                }
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

    /// Whether a row's `m` can leave its writes to `p` (§15.5, *a row mounts
    /// through its patch*): every op one whose guarded write in `p` is the
    /// write `m` makes, in a template that is cloned, not imported — a
    /// custom element's upgrade could see the order of its attributes —
    /// and `p` evaluating the values and writing in the order `m` does,
    /// which holds when the item-only ops, and the values placed apart for
    /// them, come after all the others (language.md §6, §11.11).
    fn mountsThroughPatch(g: *Gen, b: *const Body, body: m.Root, apart: []const bool) m.Error!bool {
        if (b.flags & 1 != 0 or b.ops.items.len == 0) return false;
        var seen = false;
        for (b.ops.items, apart) |op, x| {
            switch (op.what) {
                .placeholder, .style, .event => {},
                .attribute => |at| {
                    if (at.constant or g.stateful(at.item)) return false;
                    if (at.item.class == .class_list or at.item.class == .style_list) return false;
                    if (at.item.kind == .attribute and at.item.attribute != .none and g.tree.attributeFacts(at.item.attribute).raw) return false;
                },
                else => return false,
            }
            if (x) seen = true else if (seen) return false;
        }
        // The values the ops write, in evaluation order: those placed apart
        // must come after the others. A value no op writes — a class or
        // style list split in place — is not evaluated as a whole.
        const placed = try g.apartValues(b, apart);
        var written: std.ArrayList(m.Value.Index) = .empty;
        for (b.ops.items) |op| for ((try g.opOperands(op)).?) |k| switch (b.operands.items[k]) {
            .value => |v| try written.append(g.a(), v),
            else => {},
        };
        seen = false;
        for (0..body.values.len) |k| {
            const v = body.values.at(@intCast(k));
            if (std.mem.indexOfScalar(m.Value.Index, placed, v) != null) {
                seen = true;
            } else if (seen and std.mem.indexOfScalar(m.Value.Index, written.items, v) != null) return false;
        }
        return true;
    }

    /// What a grouped root's `m` writes of an op: what `p` never does — a
    /// text hole's node, empty, and an event's extractor, flags, listener
    /// and mount context — and each kept value's first state: `undefined`,
    /// which no value the checker lets an op hold is (a `⊤` may be
    /// `undefined` under `--release`, but no hole or attribute takes one;
    /// an event's `⊤` message is a known gap), a toggle's `false` and a class or style
    /// list's `null`, so that `p`'s first write is the one `m` made.
    fn mountGroupedOp(g: *Gen, b: *const Body, f: *Fn, op: Op, k: u32, fields: *std.ArrayList(m.Property)) m.Error!void {
        const js = g.jsb();
        const a_ = g.a();
        if (op.node != .none) g.cx.at(op.node);
        const undef = try js.literal(.undefined);
        if (k < f.direct.len and f.direct[k] != null) {
            // What `m` still writes of an event; no kept value.
            switch (op.what) {
                .event => |x| try g.mountEvent(f, x, null),
                .text => |x| {
                    const n = try g.cx.fresh("x");
                    try js.constant(f.block, n, try g.rt("insertText", &.{ try g.parentOf(f, x.at, true), try g.markerOf(f, x.at), try g.str("") }));
                    f.texts[k] = n;
                },
                else => {},
            }
            return;
        }
        switch (op.what) {
            .placeholder, .style => try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = undef }),
            .text => |x| {
                const n = try g.cx.fresh("x");
                try js.constant(f.block, n, try g.rt("insertText", &.{ try g.parentOf(f, x.at, true), try g.markerOf(f, x.at), try g.str("") }));
                f.texts[k] = n;
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = undef });
            },
            .attribute => |x| {
                if (g.stateful(x.item)) return;
                if (x.constant) {
                    // Its field exists only where its write is guarded.
                    if (k < f.guarded.len and f.guarded[k]) try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = undef });
                    return;
                }
                const first = if (x.item.class == .class_list or x.item.class == .style_list) try g.nul() else undef;
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = first });
            },
            .toggle => try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try js.literal(.false) }),
            .event => |x| {
                try g.mountEvent(f, x, null);
                try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = undef });
            },
            .html, .for_ => {},
            .helper => |x| {
                for (x.args, 0..) |arg, j| {
                    if (g.constantOperand(b, arg)) continue;
                    try fields.append(a_, .{ .key = try g.print("a{d}_{d}", .{ k, j }), .value = undef });
                }
                if (!x.impure and g.allConstant(b, x.args)) try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = undef });
            },
            .component => |x| {
                for (x.props, 0..) |prop, j| {
                    if (g.constantOperand(b, prop)) continue;
                    try fields.append(a_, .{ .key = try g.print("a{d}_{d}", .{ k, j }), .value = undef });
                }
                if (x.children != null) try fields.append(a_, .{ .key = try g.print("a{d}c", .{k}), .value = undef });
                if (!x.impure and x.children == null and g.allConstant(b, x.props)) try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = undef });
            },
            .show => |x| {
                try fields.append(a_, .{ .key = try g.print("a{d}k", .{k}), .value = undef });
                try fields.append(a_, .{ .key = try g.print("a{d}v", .{k}), .value = undef });
                for (x.inputs, 0..) |_, j| try fields.append(a_, .{ .key = try g.print("a{d}i{d}", .{ k, j }), .value = undef });
            },
        }
    }

    /// What `m` writes of an op when `p` writes its value: an event's
    /// extractor, flags, listener and mount context. Every kept value is
    /// `undefined`, which no value the checker lets an op hold is (as
    /// `mountGroupedOp` says), so `p` writes it.
    fn mountOnlyOp(g: *Gen, f: *Fn, op: Op, k: u32, fields: *std.ArrayList(m.Property)) m.Error!void {
        const js = g.jsb();
        const a_ = g.a();
        if (op.node != .none) g.cx.at(op.node);
        switch (op.what) {
            .placeholder, .style, .attribute => {},
            .event => |x| try g.mountEvent(f, x, null),
            else => unreachable,
        }
        try fields.append(a_, .{ .key = try g.print("a{d}", .{k}), .value = try js.literal(.undefined) });
    }

    /// An event's writes at mount: its handler, unless `p` writes it, and
    /// its extractor, flags or listener, and mount context.
    fn mountEvent(g: *Gen, f: *Fn, x: @FieldType(Op.What, "event"), handler: ?m.Expr) m.Error!void {
        const js = g.jsb();
        const facts = g.tree.eventFacts(x.item.event);
        const dom_name = g.tree.string(facts.dom_name);
        const key = try g.print("$${s}", .{dom_name});
        if (handler) |h| try js.assign(f.block, try g.member(try g.node(f, x.t), key), h);
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
    }

    /// A row's `r`: what a render that skips it patches again — each slot
    /// restated. It evaluates nothing, and keeps no `stateful` value: the
    /// controls a render may leave changed are marked and put back
    /// (§15.3, *Controlled inputs*).
    fn writeRestate(g: *Gen, b: *const Body, f: *Fn) m.Error!void {
        for (b.ops.items, 0..) |op, i| {
            if (op.slotted()) try g.writeRestateSlot(b, f, f.block, op, try g.fieldOf(f, "c{d}", .{@as(u32, @intCast(i))}));
        }
    }

    /// `Rt.restate(slot)` for a skipped op's slot; when the slot is inside
    /// a controlled element of the template and what it shows is still
    /// live after the restate — so the restate may have written under it —
    /// the element is marked (§15.3, *Controlled inputs*, the runtime's
    /// marks).
    fn writeRestateSlot(g: *Gen, b: *const Body, f: *const Fn, into: m.Block, op: Op, s: m.Expr) m.Error!void {
        const js = g.jsb();
        try js.expression(into, try g.rt("restate", &.{s}));
        const under = try g.controlsOver(b, op);
        if (under.len == 0) return;
        const then = try js.block();
        for (under) |t| try js.expression(then, try g.rt("edited", &.{try g.node(f, t)}));
        try js.@"if"(into, try js.binary(.logical_or, try g.member(s, "l"), try g.member(s, "w")), then, null);
    }

    /// `Rt.edited(el)` for each controlled element of the template that a
    /// write of the given ops (every op, for null) may have changed: the
    /// element itself, by any write but its own `stateful` one, and every
    /// controlled element above the op's node.
    fn writeMarks(g: *Gen, b: *const Body, f: *const Fn, into: m.Block, only: ?[]const u32) m.Error!void {
        const js = g.jsb();
        var seen: std.ArrayList(u32) = .empty;
        const all = try g.a().alloc(u32, b.ops.items.len);
        for (all, 0..) |*x, k| x.* = @intCast(k);
        for (only orelse all) |k| for (try g.controlsOver(b, b.ops.items[k])) |t| {
            if (std.mem.indexOfScalar(u32, seen.items, t) == null) try seen.append(g.a(), t);
        };
        for (seen.items) |t| try js.expression(into, try g.rt("edited", &.{try g.node(f, t)}));
    }

    /// The controlled elements of the template a write of `op` may change:
    /// every one above the node it writes, and the element it writes
    /// itself when the write is an attribute the HTML standard lets change
    /// a control's value or checkedness (`resetting`). An event's handler,
    /// a class or a style changes nothing a control shows.
    fn controlsOver(g: *Gen, b: *const Body, op: Op) m.Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        var at: ?u32 = switch (op.what) {
            .attribute => |x| blk: {
                if (!g.stateful(x.item) and resetting(g.tree.string(x.item.name)) and g.controlled(b, x.t)) try out.append(g.a(), x.t);
                break :blk b.tnodes.items[x.t].parent;
            },
            .toggle => |x| b.tnodes.items[x.t].parent,
            .style => |x| b.tnodes.items[x.t].parent,
            .placeholder => |x| x.t,
            .event => null,
            else => if (op.place()) |p| p.parent else null,
        };
        while (at) |t| : (at = b.tnodes.items[t].parent) {
            if (g.controlled(b, t)) try out.append(g.a(), t);
        }
        return out.items;
    }

    /// Whether a `stateful` attribute is written on template node `t`.
    fn controlled(g: *Gen, b: *const Body, t: u32) bool {
        for (b.ops.items) |op| switch (op.what) {
            .attribute => |x| if (x.t == t and g.stateful(x.item)) return true,
            else => {},
        };
        return false;
    }

    /// The patch function's statements, into `f.block`: a write only where
    /// a value is not the one written last.
    fn writePatch(g: *Gen, b: *const Body, f: *Fn, only: ?[]const bool, which: bool) m.Error!void {
        const js = g.jsb();
        for (b.ops.items, 0..) |op, i| {
            if (only) |o| if (o[i] != which) continue;
            const k: u32 = @intCast(i);
            if (op.node != .none) g.cx.at(op.node);
            switch (op.what) {
                .placeholder => |x| try g.guarded(b, f, x.value, k, try g.node(f, x.t), .data),
                .text => |x| try g.guarded(b, f, x.value, k, try g.fieldOf(f, "x{d}", .{k}), .data),
                .attribute => |x| {
                    if (g.stateful(x.item)) {
                        // Kept on the element and compared with the page's
                        // own value, so an edit the model took is not
                        // written back (§15.3, *Controlled inputs*).
                        try g.writeControl(f.block, try g.node(f, x.t), x.item, try g.read(b, f, x.value));
                        continue;
                    }
                    if (x.constant) {
                        // A grouped root writes it once, at mount, where its
                        // group puts it in source order, and never again:
                        // its group may run on later renders.
                        if (f.grouped and f.once) {
                            try g.writeAttribute(f.block, try g.node(f, x.t), x.item, try g.read(b, f, x.value), null);
                        } else if (f.grouped) {
                            const once = try js.block();
                            try g.writeAttribute(once, try g.node(f, x.t), x.item, try g.read(b, f, x.value), null);
                            try js.assign(once, try g.fieldOf(f, "a{d}", .{k}), try js.literal(.true));
                            try js.@"if"(f.block, try js.binary(.strict_eq, try g.fieldOf(f, "a{d}", .{k}), try js.literal(.undefined)), once, null);
                        }
                        continue;
                    }
                    if (k < f.direct.len) if (f.direct[k]) |d| {
                        try g.writeAttribute(f.block, try g.node(f, x.t), x.item, try g.ident(d), null);
                        continue;
                    };
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
                .helper => |x| {
                    // A component's skip, for a plain function: the call is
                    // made only when an argument changed (§11.6). A
                    // constant argument never does (`Tree.constant`), so
                    // a call of constants is made at mount only.
                    var changed: ?m.Expr = null;
                    const then = try js.block();
                    for (x.args, 0..) |p, j| {
                        if (g.constantOperand(b, p)) continue;
                        const test_ = try js.binary(.strict_ne, try g.read(b, f, p), try g.fieldOf(f, "a{d}_{d}", .{ k, j }));
                        changed = if (changed) |c| try js.binary(.logical_or, c, test_) else test_;
                        try js.assign(then, try g.fieldOf(f, "a{d}_{d}", .{ k, j }), try g.read(b, f, p));
                    }
                    try js.expression(then, try g.rt("childHtml", &.{ try g.fieldOf(f, "c{d}", .{k}), try g.helperCall(b, f, x.callee, x.args) }));
                    try g.callOrRestate(f, k, changed, then, x.impure);
                },
                .component => |x| {
                    var changed: ?m.Expr = null;
                    const then = try js.block();
                    for (x.props, 0..) |p, j| {
                        if (g.constantOperand(b, p)) continue;
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
                    try g.callOrRestate(f, k, changed, then, x.impure);
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
                    // The body unchanged and skipped: what it shows kept
                    // current all the same (`Rt.restate`).
                    const same = try js.block();
                    try js.expression(same, try g.rt("restate", &.{try g.fieldOf(f, "c{d}", .{k})}));
                    try js.@"if"(then, changed, again, same);
                    const otherwise = try js.block();
                    // The slot stands for "nothing shown": no key is it.
                    try js.assign(otherwise, try g.fieldOf(f, "a{d}k", .{k}), try g.fieldOf(f, "c{d}", .{k}));
                    try js.expression(otherwise, try g.rt("hide", &.{ try g.fieldOf(f, "c{d}", .{k}), if (x.fallback) |fb| try g.read(b, f, fb) else try g.nul() }));
                    try js.@"if"(f.block, try g.cx.isJust(try g.read(b, f, x.when)), then, otherwise);
                },
            }
        }
    }

    /// A helper's or a component's call in `p` (`then`, which places it),
    /// or, when it is skipped, the slot's markup patched again if it must
    /// be patched on every render (`Rt.restate`; language.md §11.11): a
    /// skipped call keeps a controlled input or an effect inside it as
    /// current as a call would. An impure call is never skipped. A call
    /// whose arguments are all constant is made once, at mount: by `m`
    /// for a root that is not grouped, by `p` under a field of its own
    /// otherwise.
    fn callOrRestate(g: *Gen, f: *Fn, k: u32, changed: ?m.Expr, then: m.Block, impure: bool) m.Error!void {
        const js = g.jsb();
        if (impure) return js.nested(f.block, then);
        const otherwise = try js.block();
        try js.expression(otherwise, try g.rt("restate", &.{try g.fieldOf(f, "c{d}", .{k})}));
        if (changed) |c| return js.@"if"(f.block, c, then, otherwise);
        if (!f.grouped) return js.nested(f.block, otherwise);
        try js.assign(then, try g.fieldOf(f, "a{d}", .{k}), try js.literal(.true));
        try js.@"if"(f.block, try js.binary(.strict_eq, try g.fieldOf(f, "a{d}", .{k}), try js.literal(.undefined)), then, otherwise);
    }

    /// The operands an op writes from, for the ops a row may leave alone
    /// when its item did not change; null for any other op.
    fn opOperands(g: *Gen, op: Op) m.Error!?[]const u32 {
        const one = struct {
            fn of(gen: *Gen, k: u32) m.Error![]const u32 {
                return gen.a().dupe(u32, &.{k});
            }
        }.of;
        return switch (op.what) {
            .placeholder => |x| try one(g, x.value),
            .text => |x| try one(g, x.value),
            .attribute => |x| try one(g, x.value),
            .toggle => |x| try one(g, x.value),
            .style => |x| try one(g, x.value),
            .event => |x| try one(g, x.handler),
            .html => |x| try one(g, x.value),
            .helper => |x| x.args,
            else => null,
        };
    }

    /// Per op of a row's body, whether everything it writes reads only the
    /// item (`Tree.itemOnly`). A `stateful` property may be one, as any
    /// write may (§15.3, *Controlled inputs*, amended 2026-10-08).
    fn itemOnlyOps(g: *Gen, b: *const Body) m.Error![]bool {
        const out = try g.a().alloc(bool, b.ops.items.len);
        for (b.ops.items, out) |op, *o| {
            const operands = (try g.opOperands(op)) orelse {
                o.* = false;
                continue;
            };
            o.* = for (operands) |k| {
                switch (b.operands.items[k]) {
                    .value => |v| if (!g.tree.itemOnly(v)) break false,
                    .constant => {},
                    else => break false,
                }
            } else true;
        }
        return out;
    }

    /// The values only item-only ops read: those the compiler places apart.
    fn apartValues(g: *Gen, b: *const Body, apart: []const bool) m.Error![]const m.Value.Index {
        const shared = try g.a().alloc(bool, b.operands.items.len);
        @memset(shared, false);
        for (b.ops.items, apart) |op, x| {
            if (x) continue;
            // An op that is not apart may read any operand.
            for (b.operands.items, 0..) |_, k| if (opReads(op, @intCast(k))) {
                shared[k] = true;
            };
        }
        var out: std.ArrayList(m.Value.Index) = .empty;
        for (b.ops.items, apart) |op, x| {
            if (!x) continue;
            for ((try g.opOperands(op)).?) |k| {
                if (shared[k]) continue;
                const v = b.operands.items[k];
                if (v == .value and std.mem.indexOfScalar(m.Value.Index, out.items, v.value) == null) try out.append(g.a(), v.value);
            }
        }
        return out.items;
    }

    const Write = union(enum) { data, toggle: []const u8, style: []const u8, property: []const u8 };

    /// `if (v !== i.aK) { i.aK = v; <write>; }`.
    fn guarded(g: *Gen, b: *const Body, f: *Fn, v: u32, k: u32, target: m.Expr, w: Write) m.Error!void {
        const js = g.jsb();
        if (k < f.direct.len) if (f.direct[k]) |x| {
            // Its group ran because the path it writes changed.
            switch (w) {
                .data => try js.assign(f.block, try g.member(target, "data"), try g.ident(x)),
                .property => |p| try js.assign(f.block, try g.member(target, p), try g.ident(x)),
                .toggle => |n| try js.expression(f.block, try g.method(try g.member(target, "classList"), "toggle", &.{ try g.str(n), try g.ident(x) })),
                .style => |n| try js.expression(f.block, try g.method(try g.member(target, "style"), "setProperty", &.{ try g.str(n), try g.ident(x) })),
            }
            return;
        };
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

    /// A `stateful` attribute's write: `control(el, "prop", v)`, which
    /// keeps `v` on the element and writes it when the page's differs.
    fn writeControl(g: *Gen, into: m.Block, el: m.Expr, it: m.Item, v: m.Expr) m.Error!void {
        const prop = g.tree.string(g.tree.attributeFacts(it.attribute).property.?);
        try g.jsb().expression(into, try g.rt("control", &.{ el, try g.str(prop), try g.propertyValue(it, v) }));
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

    /// Whether operand `k` is a value that is the same on every render
    /// (`Tree.constant`), which needs no field and no comparison.
    fn constantOperand(g: *Gen, b: *const Body, k: u32) bool {
        return switch (b.operands.items[k]) {
            .value => |v| g.tree.isConstant(v),
            else => false,
        };
    }

    fn allConstant(g: *Gen, b: *const Body, ks: []const u32) bool {
        for (ks) |k| if (!g.constantOperand(b, k)) return false;
        return true;
    }

    /// A helper's call: its callee named where it is, its arguments read.
    fn helperCall(g: *Gen, b: *const Body, f: *Fn, callee: m.Value.Index, args: []const u32) m.Error!m.Expr {
        const values = try g.a().alloc(m.Expr, args.len);
        for (values, args) |*v, p| v.* = try g.read(b, f, p);
        return g.cx.call(try g.cx.value(callee), values);
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

/// The one value an op writes when the group's name may stand for it: a
/// text hole, a plain attribute, a style entry or an event, none of which
/// keeps more than its last value. A toggle writes `false` at mount only
/// when it must, and a class or style list, a `stateful` property and a
/// constant need what only their own test keeps.
fn directValue(g: *Gen, b: *const Body, op: Op) ?m.Value.Index {
    const k = switch (op.what) {
        .placeholder => |x| x.value,
        .text => |x| x.value,
        .style => |x| x.value,
        .event => |x| x.handler,
        .attribute => |x| blk: {
            if (x.constant or g.stateful(x.item)) return null;
            if (x.item.class == .class_list or x.item.class == .style_list) return null;
            if (x.item.value.kind != .dynamic) return null;
            break :blk x.value;
        },
        else => return null,
    };
    return switch (b.operands.items[k]) {
        .value => |v| v,
        else => null,
    };
}

/// The attributes of a form control whose write may change its value or
/// checkedness by the HTML standard's own steps — a new `type` sanitises
/// the value, `min`, `max` and `step` clamp a range's, `multiple` and
/// `size` make a select choose again (backend.md §15.3, *Controlled
/// inputs*, the runtime's marks).
fn resetting(name: []const u8) bool {
    return among(name, &.{ "type", "min", "max", "step", "multiple", "size" });
}

/// The representative of op `k`'s group.
fn find(parent: []u32, k: u32) u32 {
    var at = k;
    while (parent[at] != at) at = parent[at];
    return at;
}

/// The element an attribute, a class entry or a style entry is written on.
fn elementOf(op: Op) ?u32 {
    return switch (op.what) {
        .attribute => |x| x.t,
        .toggle => |x| x.t,
        .style => |x| x.t,
        else => null,
    };
}

/// Every operand `op` reads, in any of its forms: `opReads`'s, listed.
fn opOperandList(a: Allocator, op: Op, out: *std.ArrayList(u32)) Allocator.Error!void {
    switch (op.what) {
        .placeholder => |x| try out.append(a, x.value),
        .text => |x| try out.append(a, x.value),
        .attribute => |x| try out.append(a, x.value),
        .toggle => |x| try out.append(a, x.value),
        .style => |x| try out.append(a, x.value),
        .event => |x| try out.append(a, x.handler),
        .html => |x| try out.append(a, x.value),
        .helper => |x| try out.appendSlice(a, x.args),
        .component => |x| {
            try out.append(a, x.thunk);
            if (x.children) |c| try out.append(a, c);
            try out.appendSlice(a, x.props);
        },
        .for_ => |x| {
            try out.append(a, x.each);
            try out.append(a, x.row);
            if (x.key) |k| try out.append(a, k);
            if (x.inputs) |k| try out.append(a, k);
        },
        .show => |x| {
            try out.append(a, x.when);
            try out.append(a, x.body);
            if (x.key) |k| try out.append(a, k);
            if (x.fallback) |k| try out.append(a, k);
            try out.appendSlice(a, x.inputs);
        },
    }
}

/// Whether `op` reads operand `k`, in any of its forms.
fn opReads(op: Op, k: u32) bool {
    return switch (op.what) {
        .placeholder => |x| x.value == k,
        .text => |x| x.value == k,
        .attribute => |x| x.value == k,
        .toggle => |x| x.value == k,
        .style => |x| x.value == k,
        .event => |x| x.handler == k,
        .html => |x| x.value == k,
        .helper => |x| std.mem.indexOfScalar(u32, x.args, k) != null,
        .component => |x| x.thunk == k or (x.children != null and x.children.? == k) or std.mem.indexOfScalar(u32, x.props, k) != null,
        .for_ => |x| x.each == k or x.row == k or (x.key != null and x.key.? == k) or (x.inputs != null and x.inputs.? == k),
        .show => |x| x.when == k or x.body == k or (x.key != null and x.key.? == k) or (x.fallback != null and x.fallback.? == k) or std.mem.indexOfScalar(u32, x.inputs, k) != null,
    };
}

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
    // A value that ends in `/` is quoted too: `href=#/>` is `#/` to the
    // HTML standard's parser, and `#` to happy-dom's, which reads the `/>`
    // as a self-closing tag.
    const quoted = value[value.len - 1] == '/' or for (value) |c| {
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

/// Whether the runtime's `safeUrl` (`Rt.beni`) refuses `url` — its pattern,
/// `^[\s\x00-\x20]*(j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|d\s*a\s*t\s*a
/// \s*:\s*t\s*e\s*x\s*t\s*/\s*h\s*t\s*m\s*l\s*[,;])` with `i` — or null when
/// the answer turns on a character outside ASCII, which `\s` may match
/// (a no-break space, U+2028, …): such a URL is left to the runtime.
fn scriptUrl(url: []const u8) ?bool {
    var i: usize = 0;
    while (i < url.len and url[i] <= 0x20) i += 1;
    if (i < url.len and url[i] >= 0x80) return null;
    const javascript = scriptPrefix(url, i, "javascript:");
    if (javascript == null) return null;
    if (javascript.?) return true;
    return scriptPrefix(url, i, "data:text/html");
}

/// Whether `url` from `start` is `word`, letters in any case, with ASCII
/// whitespace between any two characters — and, for `data:text/html`, one
/// of `,` `;` after it; null at a character outside ASCII before that is
/// known.
fn scriptPrefix(url: []const u8, start: usize, word: []const u8) ?bool {
    var i = start;
    const html = word[word.len - 1] == 'l';
    for (word, 0..) |w, n| {
        if (n != 0) {
            while (i < url.len and isSpace(url[i])) i += 1;
        }
        if (i == url.len) return false;
        if (url[i] >= 0x80) return null;
        if (std.ascii.toLower(url[i]) != w) return false;
        i += 1;
    }
    if (!html) return true;
    while (i < url.len and isSpace(url[i])) i += 1;
    if (i == url.len) return false;
    if (url[i] >= 0x80) return null;
    return url[i] == ',' or url[i] == ';';
}

/// `\s` in ASCII: tab, line feed, vertical tab, form feed, carriage return
/// and space.
fn isSpace(c: u8) bool {
    return (c >= 0x09 and c <= 0x0D) or c == ' ';
}

test "a constant URL is checked as the runtime's safeUrl checks it" {
    const t = std.testing;
    try t.expectEqual(@as(?bool, false), scriptUrl("#/active"));
    try t.expectEqual(@as(?bool, true), scriptUrl("javascript:alert(1)"));
    try t.expectEqual(@as(?bool, true), scriptUrl(" \x01\tJaVa\nscript :x"));
    try t.expectEqual(@as(?bool, true), scriptUrl("DATA: text / html ;base64,eA=="));
    try t.expectEqual(@as(?bool, false), scriptUrl("data:image/png,x"));
    try t.expectEqual(@as(?bool, false), scriptUrl("javascript.html"));
    try t.expectEqual(@as(?bool, false), scriptUrl("data:text/htm"));
    try t.expectEqual(@as(?bool, false), scriptUrl(""));
    // A no-break space may be `\s`: the runtime decides.
    try t.expectEqual(@as(?bool, null), scriptUrl("\xc2\xa0javascript:x"));
    try t.expectEqual(@as(?bool, null), scriptUrl("java\xc2\xa0script:x"));
    try t.expectEqual(@as(?bool, false), scriptUrl("/caf\xc3\xa9"));
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
    try bakeAttribute(t.allocator, &out, "href", "#/");
    try t.expectEqualStrings("<span class=\"glyphicon glyphicon-remove\"aria-hidden=true hidden title=\"a&amp;b&lt;c\"href=\"#/\"", out.items);
}

test "text is escaped as the parser reads it back" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try escapeText(t.allocator, &out, "a < b & c\r");
    try t.expectEqualStrings("a &lt; b &amp; c&#13;", out.items);
}
