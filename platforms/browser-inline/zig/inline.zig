//! The `inline` program lowering (docs/design/browser-inline.md): a program
//! of The Elm Architecture is compiled, not run, into the output tea-inline
//! writes (`../reactivity-research/frameworks/tea-inline/`). Where a program
//! constructor is called, the compiler hands this lowering the program, and
//! the lowering returns its **mount**, a function of the mount node that
//! `Inline.run` calls inside the dispatch guard:
//!
//!     (root) => {
//!       let model = init;
//!       root.insertAdjacentHTML("beforeend", "<div><output></output><button>+1");
//!       const n = root.lastChild;
//!       own(() => { n.remove(); });
//!       const E = n.querySelectorAll("*");
//!       const g0 = () => { text(E[0], model.count); };
//!       g0();
//!       const onInc = () => { model = { ...model, count: model.count + 1 }; g0(); };
//!       on(E[1], onInc);
//!     }
//!
//! The view's static markup is one HTML string, written once after the
//! mount node's children, with the end tags HTML makes optional left out
//! (§8.2); each element code refers to is `E[n]` by document order. A
//! binding is one write guarded by a compare (`text`, `prop`, `when`),
//! grouped into one function per set of read sets; a key's handler is its
//! arm of `update`, then a write pass of the functions its writes reach,
//! each once (§8.3). What the mount added is undone by the function it
//! registers with `own`, which `stop` runs (`boundary.md` §9.4.5, amended
//! 2026-10-17). Everything this lowering cannot compile exactly is a build
//! error that names its class and what to write instead
//! (`browser-inline.md` §5) — never a fallback.

const std = @import("std");
const m = @import("beni_markup");
const parser = @import("platform_html").parser_table;

pub const lowering: m.Lowering = .{
    .name = "inline",
    .targets = .{ .major = 1, .minor = 15 },
    .runtime = &.{
        // `(f, x)`: the dispatch guard, which every entry into program code
        // goes through.
        .{ .name = "send", .arity = 2 },
        // `(f)`: what undoes the mount, run once by `stop`.
        .{ .name = "own", .arity = 1 },
        // `(id)`: the element a program mounts at.
        .{ .name = "root", .arity = 1 },
        // `(⊤)`: the page's unmount (`boundary.md` §9.4.5).
        .{ .name = "stop", .arity = 1 },
        // `(cmd, dispatch)`: a command's bodies, queued on the guard to run
        // after the dispatch's write pass (`boundary.md` §9.8.4, as amended
        // 2026-10-17), each message one sends handed to `dispatch`.
        .{ .name = "commands", .arity = 2 },
        // The bindings and the listener (`browser-inline.md` §8.2).
        .{ .name = "text", .arity = 2 },
        .{ .name = "prop", .arity = 3 },
        .{ .name = "when", .arity = 2 },
        .{ .name = "on", .arity = 3 },
        // `(node)`: a piece root's table of elements (§8.4).
        .{ .name = "part", .arity = 1 },
    },
    .module = module,
    .root = root,
    .groups = true,
    .programs = &.{
        .{ .module = "Tea", .name = "sandbox" },
        .{ .module = "Tea", .name = "element" },
    },
    .program = program,
    .piece = piece,
    .placements = &.{
        .{ .module = "Browser", .name = "mountAt", .places = .first },
    },
    .places = true,
    .constructs = true,
    .arm_fields = true,
    .effects = .{ .sub = "Sub", .cmd = "Cmd" },
    .no_markup_values = no_markup_values,
};

const no_markup_values =
    \\A limit of the compiler: `browser-inline` has no markup value yet; it compiles markup only
    \\as a program's `view`, written in place (`docs/design/browser-inline.md` §5, class 1).
    \\Write markup held, passed or returned by a helper in place in the `view`, or build this
    \\program with `--platform=browser-tea`.
;

fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}

/// Unreachable: `no_markup_values` refuses every root that is not a
/// program's `view`.
fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    return cx.notImplemented(tree.root(index).node, no_markup_values);
}

/// The class-1 refusal (`browser-inline.md` §5): a limit of the compiler, a
/// construct this platform does not compile yet, and what to write instead.
fn later(cx: *m.Context, n: m.Node.Index, what: []const u8) m.Error {
    const message = std.fmt.allocPrint(cx.arena,
        \\A limit of the compiler: `browser-inline` does not compile {s} yet
        \\(`docs/design/browser-inline.md` §5, class 1). Write the `view` without it, or build this
        \\program with `--platform=browser-tea`, which compiles it.
    , .{what}) catch return error.OutOfMemory;
    return cx.notImplemented(n, message);
}

/// The class-4 refusal (`browser-inline.md` §5): a limit of the compiler
/// that no slice of the plan has yet in its area.
fn limit(cx: *m.Context, n: m.Node.Index, what: []const u8) m.Error {
    const message = std.fmt.allocPrint(cx.arena,
        \\A limit of the compiler: {s} (`docs/design/browser-inline.md` §8.7; §5, class 4). The
        \\program is valid: it builds with `--platform=browser-tea`.
    , .{what}) catch return error.OutOfMemory;
    return cx.notImplemented(n, message);
}

/// The program hook: the mount of a `Tea.sandbox` or a `Tea.element`.
fn program(cx: *m.Context, tree: *const m.Tree, p: *const m.Program) m.Error!m.Expr {
    if (!p.record) return cx.programReport(.call, .view_not_compiled,
        \\This program's record is a value computed when the page runs, so `browser-inline`
        \\cannot compile its `view`: the platform has no renderer to hand a `view` it did not
        \\compile. Write the record where `Tea.sandbox` or `Tea.element` is called
        \\(`docs/design/browser-inline.md` §5, class 3).
    );
    switch (p.view) {
        .markup => {},
        .function => return cx.programReport(.view, .not_implemented,
            \\A limit of the compiler: `browser-inline` compiles a `view` whose body is markup
            \\written in place, and this one's computes its markup, or has `let`s, which it does not compile yet
            \\(`docs/design/browser-inline.md` §5, class 1). Write the markup in place as the body of
            \\`view`, or build this program with `--platform=browser-tea`.
        ),
        .other_module => return cx.programReport(.view, .not_implemented,
            \\A limit of the compiler: `browser-inline` compiles a `view` declared in the module that
            \\calls the program's constructor, and this one is another module's, which it does not compile yet
            \\(`docs/design/browser-inline.md` §5, class 1). Declare `view` beside the program, or
            \\build this program with `--platform=browser-tea`.
        ),
        else => return cx.programReport(.view, .view_not_compiled,
            \\This program's `view` is a value computed when the page runs, not a function whose
            \\body the compiler can reach as markup, so `browser-inline` cannot compile it: the
            \\platform has no renderer to hand a `view` it did not compile. Name a function, or
            \\write a lambda, whose body is the markup (`docs/design/browser-inline.md` §5,
            \\class 3).
        ),
    }
    const index = p.view_root.?;
    const r = tree.root(index);
    var page: Page = .{ .cx = cx, .tree = tree, .p = p, .index = index };
    try page.ctxs.append(cx.arena, .{ .parent = null, .node = .none, .arm = 0, .root = index });
    page.top_nodes = try page.markup(r.node, .{}, 0, true);
    return page.mount(r.node);
}

// ---- Pieces (`browser-inline.md` §8.4) ------------------------------------

/// What a piece's owner records for the program site: the facts of
/// `m.PieceFacts.data`, in the request's arena.
const PieceData = struct {
    /// The name of the piece that is the root's static markup, its end tags
    /// all written, and its top element's name.
    html: []const u8,
    top: []const u8,
    /// The elements numbered below the top element.
    count: u32,
    binds: []const PieceBind,
    /// The event-wiring piece's name, when the root has events.
    wire: ?[]const u8,
    handlers: []const PieceHandler,
    /// The root's function's parameter count.
    arity: u32,
    /// The static markup as a tree, which the program site checks again in
    /// the scope it places the piece in: the parser rebuilds markup by
    /// what is open around it, across the boundary of the piece (#373).
    nodes: []const Html,
};

const PieceBind = struct { name: []const u8, groups: []const u32 };

/// A constructor the root's events send, and the binding functions writing
/// a control one of its events is on.
const PieceHandler = struct { ctor: m.Ctor, fields: u32, controls: []const u32 };

const no_program: m.Program = .{ .constructor = 0, .record = true, .view = .markup, .view_root = null, .update = .computed };

/// The piece hook: another module's program shows this root, the body of a
/// function its `view` calls. Each binding function is a piece
/// `(elements, argument)`, the events one piece `(elements, handler…)`
/// that wires each to the handler of the constructor it sends, and the
/// static markup and the read sets are the facts the program site writes
/// the rest from.
fn piece(cx: *m.Context, tree: *const m.Tree, req: *const m.PieceRequest) m.Error!void {
    const js = cx.js;
    var page: Page = .{ .cx = cx, .tree = tree, .p = &no_program, .index = req.root, .piece = true };
    const pg = &page;
    try pg.ctxs.append(cx.arena, .{ .parent = null, .node = .none, .arm = 0, .root = req.root });
    const r = tree.root(req.root);
    pg.top_nodes = try pg.markup(r.node, .{}, 0, true);
    if (pg.top_nodes.len != 1 or pg.top_nodes[0].kind != .element) return limit(cx, r.node, "`browser-inline` writes another module's markup as pieces when it is one element, and this is not");
    for (pg.writes.items) |w| if (w.target == null) return later(cx, r.node, "a binding of the top element of another module's markup");
    for (pg.events.items) |ev| if (ev.target == null) return later(cx, ev.node, "an event on the top element of another module's markup");
    // D-d: a `let` of the view read by one hole is that hole's value; one
    // several read is a memo node, S3's (§8.2).
    for (0..r.lets.len) |k| if (cx.rootLetReaders(req.root, @intCast(k)) > 1) return limit(cx, r.node, "a `let` of this `view` is read by several holes, and `browser-inline` computes a `let` in the binding of the one hole that reads it (D-d); one several holes read is a memo node, which slice S3 brings");
    pg.elements = try cx.fresh("elements");
    // The root's function's parameters, each a parameter of every binding
    // function after the elements.
    const params_all = try cx.arena.alloc(m.Name, cx.pieceArity() + 1);
    params_all[0] = pg.elements.?;
    for (params_all[1..]) |*x| x.* = try cx.fresh("model");
    pg.piece_args = params_all[1..];
    try pg.group();
    try pg.letsOnce();
    const a = req.arena;
    const binds = try a.alloc(PieceBind, pg.functions.items.len);
    for (pg.functions.items, binds, 0..) |*f, *b, j| {
        const blk = try js.block();
        try pg.writeFunction(blk, f);
        const base = try std.fmt.allocPrint(a, "{s}$$bind${d}${d}", .{ req.decl, req.ordinal, j });
        try cx.pieceExport(base, try js.arrow(params_all, blk));
        b.* = .{ .name = base, .groups = try a.dupe(u32, f.groups) };
    }
    // The events: one handler parameter per constructor, in the order of
    // its first event.
    var handlers: std.ArrayList(PieceHandler) = .empty;
    var params: std.ArrayList(m.Name) = .empty;
    var controls: std.ArrayList(std.ArrayList(u32)) = .empty;
    const wire = try js.block();
    for (pg.events.items) |ev| {
        const facts = tree.eventFacts(ev.item.event);
        const dom = tree.string(facts.dom_name);
        const kind: ?[]const u8 = if (std.mem.eql(u8, dom, "click")) null else dom;
        const v = switch (ev.item.value.kind) {
            .dynamic => ev.item.value.dynamic.?,
            else => return limit(cx, ev.node, "this event's handler is a message written as a literal, which `browser-inline` cannot route to a key"),
        };
        const payload_form = ev.item.form == .payload;
        const sent = cx.pieceEventCtor(v, payload_form) orelse return limit(cx, ev.node, "`browser-inline` wires an event of another module's markup by the constructor alone, which takes the event's payload or nothing, and this event's handler value is a constructor applied to values, or not a constructor");
        const hi = for (handlers.items, 0..) |h, i| {
            if (std.meta.eql(h.ctor, sent.ctor)) break i;
        } else blk: {
            try handlers.append(cx.arena, .{ .ctor = sent.ctor, .fields = sent.fields, .controls = &.{} });
            try params.append(cx.arena, try cx.fresh("on"));
            try controls.append(cx.arena, .empty);
            break :blk handlers.items.len - 1;
        };
        // The binding functions of a control this event is on (§8.3).
        for (pg.functions.items, 0..) |f, fi| for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (!w.stateful or w.target != ev.target) continue;
            if (std.mem.indexOfScalar(u32, controls.items[hi].items, @intCast(fi)) == null) try controls.items[hi].append(cx.arena, @intCast(fi));
        };
        const h = try js.name(params.items[hi]);
        var listener = h;
        if (payload_form) {
            const e = try cx.fresh("event");
            const blk = try js.block();
            const payload = if (try cx.extractor(ev.index)) |extract| try js.call(extract, &.{try js.name(e)}) else try js.name(e);
            try js.expression(blk, try js.call(h, &.{payload}));
            listener = try js.arrow(&.{e}, blk);
        }
        const node = try pg.ref(ev.target);
        if (!facts.prevent_default and !facts.stop_propagation) {
            if (kind) |k| {
                try js.expression(wire, try js.call(try js.name(try cx.runtime("on")), &.{ node, listener, try js.string(k) }));
            } else try js.expression(wire, try js.call(try js.name(try cx.runtime("on")), &.{ node, listener }));
            continue;
        }
        const evn = try cx.fresh("event");
        const dom_blk = try js.block();
        if (facts.prevent_default) try js.expression(dom_blk, try js.call(try js.member(try js.name(evn), "preventDefault"), &.{}));
        if (facts.stop_propagation) try js.expression(dom_blk, try js.call(try js.member(try js.name(evn), "stopPropagation"), &.{}));
        try js.expression(dom_blk, try js.call(try js.name(try cx.runtime("send")), &.{ listener, try js.name(evn) }));
        try js.expression(wire, try js.call(try js.member(node, "addEventListener"), &.{ try js.string(kind orelse "click"), try js.arrow(&.{evn}, dom_blk) }));
    }
    var wire_name: ?[]const u8 = null;
    if (handlers.items.len != 0) {
        const base = try std.fmt.allocPrint(a, "{s}$$on${d}", .{ req.decl, req.ordinal });
        const all = try cx.arena.alloc(m.Name, params.items.len + 1);
        all[0] = pg.elements.?;
        @memcpy(all[1..], params.items);
        try cx.pieceExport(base, try js.arrow(all, wire));
        wire_name = base;
    }
    const out_handlers = try a.alloc(PieceHandler, handlers.items.len);
    for (out_handlers, handlers.items, controls.items) |*o, h, c| o.* = .{ .ctor = h.ctor, .fields = h.fields, .controls = try a.dupe(u32, c.items) };
    const data = try a.create(PieceData);
    // The static markup, a piece of its own: every end tag of the top
    // element written, since the program site writes more after it.
    var html: std.ArrayList(u8) = .empty;
    try serialise(cx.arena, &html, pg.top_nodes, null, false);
    const html_base = try std.fmt.allocPrint(a, "{s}$$html${d}", .{ req.decl, req.ordinal });
    try cx.pieceExport(html_base, try js.string(html.items));
    data.* = .{ .html = html_base, .top = try a.dupe(u8, pg.top_nodes[0].name), .nodes = try copyHtml(a, pg.top_nodes), .count = pg.count, .arity = cx.pieceArity(), .binds = binds, .wire = wire_name, .handlers = out_handlers };
    req.facts.* = .{ .written = true, .data = data };
}

/// A deep copy of `nodes` into `a`, which outlives the lowering that made
/// them.
fn copyHtml(a: std.mem.Allocator, nodes: []const Html) std.mem.Allocator.Error![]const Html {
    const out = try a.alloc(Html, nodes.len);
    for (out, nodes) |*o, x| {
        o.* = x;
        o.name = try a.dupe(u8, x.name);
        o.attributes = try a.dupe(u8, x.attributes);
        o.children = try copyHtml(a, x.children);
    }
    return out;
}

/// Why the parser would rebuild `nodes` written in `scope`, or null: the
/// same rules the walk applies to a unit's own markup (`element`).
fn rebuilt(scope: parser.Scope, nodes: []const Html) ?[]const u8 {
    for (nodes) |x| switch (x.kind) {
        .text => if (parser.movesText(scope.parent)) return "the parser moves text written here out of the table",
        .element => {
            if (parser.misplaced(scope, x.name, false)) |why| return why;
            if (parser.misnested(scope, x.name)) |why| return why;
            if (!x.void) if (rebuilt(scope.enter(x.name), x.children)) |why| return why;
        },
        .piece => {},
    };
    return null;
}

/// One node of the static markup, as `serialise` writes it.
const Html = struct {
    /// `piece`: another module's root, its markup the piece `piece` of the
    /// page names, written in its place; `name` is its top element's.
    kind: enum { element, text, piece },
    piece: u32 = 0,
    /// The element's name, or the text, escaped.
    name: []const u8,
    /// ` name=value…`, written.
    attributes: []const u8 = "",
    void: bool = false,
    children: []const Html = &.{},
};

/// Where a binding's or an event's values are evaluated: the `view`'s root
/// (context 0), or an eager arm of a branch in an enclosing context.
const Ctx = struct {
    parent: ?u32,
    /// The branch's hole; `none` for the `view`.
    node: m.Node.Index,
    arm: u32,
    root: m.Root.Index,
};

/// One part of a text binding: text written as it is, or a hole's value.
const Part = union(enum) { text: []const u8, value: m.Value.Index };

/// One write of the page (§8.2), on an element: `null` is the unit's top
/// element, any other number its descendant of that place in document
/// order.
const Write = struct {
    target: ?u32,
    ctx: u32,
    /// The read sets it is in, sorted, each once.
    groups: []const u32,
    what: union(enum) {
        text: []const Part,
        /// `key` null: the control's `value`.
        prop: struct { value: m.Value.Index, key: ?[]const u8 },
        /// Hidden while the branch at `node` takes another arm than `shown`.
        when: struct { node: m.Node.Index, shown: u32 },
    },
    /// A `stateful` attribute: a control the user edits (§8.3).
    stateful: bool = false,
    /// A text write whose value is a `String`, not a lone number.
    string: bool = true,
};

/// One event of the page, on an element.
const Event = struct {
    node: m.Node.Index,
    target: ?u32,
    ctx: u32,
    item: m.Item,
    /// Its index in `Tree.items`.
    index: u32,
};

/// One binding function: the writes of one set of read sets, or a piece's
/// binding function called with its elements and argument.
const Function = struct {
    groups: []const u32,
    writes: std.ArrayList(u32) = .empty,
    name: m.Name = undefined,
    piece: ?struct { use: u32, bind: u32 } = null,
};

/// Another module's root the page shows as pieces: its hole, its top
/// element's place, its facts, the name of its elements, and the index of
/// the first of its binding functions among the page's.
const PieceUse = struct {
    node: m.Node.Index,
    target: u32,
    data: *const PieceData,
    elements: m.Name = undefined,
    first: u32 = 0,
};

/// One program's page, as the lowering builds it.
const Page = struct {
    cx: *m.Context,
    tree: *const m.Tree,
    p: *const m.Program,
    index: m.Root.Index,
    /// The view's static markup, as nodes.
    top_nodes: []const Html = &.{},
    /// How many descendants of the top element are numbered.
    count: u32 = 0,
    ctxs: std.ArrayList(Ctx) = .empty,
    writes: std.ArrayList(Write) = .empty,
    events: std.ArrayList(Event) = .empty,
    functions: std.ArrayList(Function) = .empty,
    /// The mount's body, the model's name, the top node and its
    /// descendants by place.
    body: m.Block = undefined,
    model: m.Name = undefined,
    node: ?m.Name = null,
    elements: ?m.Name = null,
    /// `elements` is the one element code refers to, not the list.
    single: bool = false,
    /// The handlers by key, named when something first calls one.
    handlers: []?m.Name = &.{},
    /// Per key, the functions of the stateful controls its events are on.
    controls: []std.ArrayList(u32) = &.{},
    /// Per group, the functions that hold one of its writes; per function,
    /// the last key `passOf` took it for.
    by_group: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    stamp: []u32 = &.{},
    dispatch: ?m.Name = null,
    /// The page is another module's root, written as pieces (`piece`).
    piece: bool = false,
    /// A piece's binding functions' parameters after the elements.
    piece_args: []const m.Name = &.{},
    pieces: std.ArrayList(PieceUse) = .empty,

    fn a(pg: *Page) std.mem.Allocator {
        return pg.cx.arena;
    }

    /// A hole's facts, refused when the write-set pass did not reach the
    /// hole: its group would be unknown, and no key's pass could name it.
    /// No pass calls every binding (`browser-inline.md` §8.3, amended
    /// 2026-10-19), so this is a limit of the compiler in every build.
    fn known(pg: *Page, n: m.Node.Index, facts: m.Program.HoleFacts) m.Error!m.Program.HoleFacts {
        if (facts.group != std.math.maxInt(u32)) return facts;
        return limit(pg.cx, n, "the write-set pass did not reach this hole on the `view`'s call path, so `browser-inline` cannot say which messages change it; write it in the program's own `view`, or a function the `view` calls directly");
    }

    // ---- The walk: markup, writes and events ---------------------------

    /// The markup of node `n` of context `ctx`, in `scope`, refusing what
    /// S1 does not compile; `top`: `n` is at the unit's top level.
    fn markup(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32, top: bool) m.Error![]const Html {
        const tree = pg.tree;
        pg.cx.at(n);
        switch (tree.kind(n)) {
            .fragment => {
                var out: std.ArrayList(Html) = .empty;
                for (tree.childrenOf(tree.fragment(n).children)) |child| try out.appendSlice(pg.a(), try pg.markup(child, scope, ctx, top));
                return out.items;
            },
            .element => return pg.a().dupe(Html, &.{try pg.element(n, scope, ctx, top)}),
            .text => {
                if (parser.movesText(scope.parent)) return pg.cx.report(n, "the parser moves text written here out of the table");
                var text: std.ArrayList(u8) = .empty;
                try escapeText(pg.a(), &text, tree.string(tree.text(n).text));
                return pg.a().dupe(Html, &.{.{ .kind = .text, .name = text.items }});
            },
            .hole => return later(pg.cx, n, "a hole outside an element"),
            .component => return later(pg.cx, n, "a component"),
            .for_ => return later(pg.cx, n, "a `For`"),
            .show => return later(pg.cx, n, "a `Show`"),
            else => return later(pg.cx, n, "this markup"),
        }
    }

    fn element(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32, top: bool) m.Error!Html {
        const tree = pg.tree;
        const e = tree.element(n);
        const facts = tree.elementFacts(e.row);
        const name = tree.string(facts.name);
        if (facts.namespace != .html) return later(pg.cx, n, "an element of the SVG or MathML namespace");
        if (parser.misnested(scope, name)) |why| return pg.cx.report(n, why);
        // The top element is the unit's node; every other has its place.
        const target: ?u32 = if (top and ctx == 0) null else blk: {
            pg.count += 1;
            break :blk pg.count - 1;
        };
        var attributes: std.ArrayList(u8) = .empty;
        for (tree.itemsOf(e.items), 0..) |it, i| try pg.item(n, target, ctx, it, e.items.start + @as(u32, @intCast(i)), &attributes);
        if (facts.void) return .{ .kind = .element, .name = name, .attributes = attributes.items, .void = true };
        const inner = scope.enter(name);
        const children = tree.childrenOf(e.children);
        if (parser.content(name) != .normal and children.len != 0) return later(pg.cx, n, "the content of an element whose content the parser reads as text");
        // Texts and text holes only, a hole among them: the element's text
        // is one binding, mixed or alone.
        var holes: u32 = 0;
        const texts = for (children) |child| {
            switch (tree.kind(child)) {
                .text => {},
                .hole => if (textHole(tree.hole(child).kind)) {
                    holes += 1;
                } else break false,
                else => break false,
            }
        } else true;
        if (texts and holes != 0) {
            if (parser.movesText(inner.parent)) return pg.cx.report(n, "the parser moves text written here out of the table");
            return .{ .kind = .element, .name = name, .attributes = attributes.items, .children = try pg.textOf(target, ctx, children) };
        }
        var out: std.ArrayList(Html) = .empty;
        for (children) |child| {
            if (tree.kind(child) == .hole) {
                const h = tree.hole(child);
                if (textHole(h.kind)) return limit(pg.cx, child, "`browser-inline` writes a text hole as its element's whole text, and this one stands beside an element; wrap the hole and the text around it in an element of their own");
                if (h.kind != .html) return later(pg.cx, child, "a hole that is not text of a `String`, a `Char` or a number");
                if (try pg.cx.programPiece(child)) |piece_facts| {
                    try out.append(pg.a(), try pg.pieceHole(child, piece_facts, ctx, inner));
                    continue;
                }
                try out.append(pg.a(), try pg.when(child, inner, ctx));
                continue;
            }
            try out.appendSlice(pg.a(), try pg.markup(child, inner, ctx, false));
        }
        return .{ .kind = .element, .name = name, .attributes = attributes.items, .children = out.items };
    }

    /// The text of element `n` (`target`), its children texts and holes:
    /// baked into the markup when every hole is, else one binding.
    fn textOf(pg: *Page, target: ?u32, ctx: u32, children: []const m.Node.Index) m.Error![]const Html {
        const tree = pg.tree;
        var parts: std.ArrayList(Part) = .empty;
        var groups: std.ArrayList(u32) = .empty;
        var baked: std.ArrayList(u8) = .empty;
        var all_baked = true;
        // Whether the text written is a `String` already: no lone number.
        var string = true;
        for (children) |child| switch (tree.kind(child)) {
            .text => {
                const s = tree.string(tree.text(child).text);
                try parts.append(pg.a(), .{ .text = s });
                try baked.appendSlice(pg.a(), s);
            },
            else => {
                const h = tree.hole(child);
                const facts = try pg.known(child, pg.cx.programHole(.{ .node = child }));
                if (facts.bake) |b| {
                    try parts.append(pg.a(), .{ .text = b });
                    try baked.appendSlice(pg.a(), b);
                } else {
                    all_baked = false;
                    try parts.append(pg.a(), .{ .value = h.value });
                    if (h.kind == .text_number) string = false;
                    try groups.append(pg.a(), facts.group);
                }
            },
        };
        if (all_baked) {
            if (baked.items.len == 0) return &.{};
            var escaped: std.ArrayList(u8) = .empty;
            try escapeText(pg.a(), &escaped, baked.items);
            return pg.a().dupe(Html, &.{.{ .kind = .text, .name = escaped.items }});
        }
        try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), groups.items), .what = .{ .text = parts.items }, .string = string or parts.items.len > 1 });
        return &.{};
    }

    /// The page's string, `html`, with each piece's mark replaced by that
    /// piece's name: one string, or a template of the two.
    fn htmlValue(pg: *Page, html: []const u8) m.Error!m.Expr {
        const js = pg.cx.js;
        if (std.mem.indexOfScalar(u8, html, 0) == null) return js.string(html);
        var parts: std.ArrayList(m.TemplatePart) = .empty;
        var rest = html;
        while (std.mem.indexOfScalar(u8, rest, 0)) |open| {
            if (open != 0) try parts.append(pg.a(), .{ .text = rest[0..open] });
            const close = open + 1 + std.mem.indexOfScalar(u8, rest[open + 1 ..], 0).?;
            const index = std.fmt.parseInt(u32, rest[open + 1 .. close], 10) catch unreachable;
            const u = pg.pieces.items[index];
            try parts.append(pg.a(), .{ .expr = try js.name(try pg.cx.programPieceName(u.node, u.data.html)) });
            rest = rest[close + 1 ..];
        }
        if (rest.len != 0) try parts.append(pg.a(), .{ .text = rest });
        return js.template(parts.items);
    }

    /// An `html` hole that is another module's root, written as pieces
    /// (§8.4): its static markup in place, its elements numbered after its
    /// top element's place.
    fn pieceHole(pg: *Page, n: m.Node.Index, facts: *const m.PieceFacts, ctx: u32, scope: parser.Scope) m.Error!Html {
        if (!facts.written) return error.Reported;
        const data: *const PieceData = @ptrCast(@alignCast(facts.data.?));
        // The piece's markup was checked where its own module wrote it, at a
        // root; the parser reads it where it stands in this page (#373).
        if (rebuilt(scope, data.nodes)) |why| return pg.cx.report(n, why);
        if (ctx != 0) return later(pg.cx, n, "another module's markup inside an `if` or a `case` of the `view`");
        try pg.pieces.append(pg.a(), .{ .node = n, .target = pg.count, .data = data });
        pg.count += 1 + data.count;
        return .{ .kind = .piece, .name = data.top, .piece = @intCast(pg.pieces.items.len - 1) };
    }

    /// An `html` hole among an element's children: an eager `when`
    /// (§8.2, D-b) — an `if` one arm of which is one element written in
    /// place and the other `<></>`. Its element is in the markup, in the
    /// arm's context; the `when` is a write of the hole's context.
    fn when(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32) m.Error!Html {
        const cx = pg.cx;
        const tree = pg.tree;
        const not_when = "markup that is not written in place, or a branch whose arms are not one element and `<></>`";
        const br = cx.programBranch(n) orelse return later(cx, n, not_when);
        if (br.arms.len != 2) return later(cx, n, not_when);
        var shown: ?u32 = null;
        for (br.arms, 0..) |arm, k| {
            const r = switch (arm.what) {
                .markup => |r| r,
                else => return later(cx, n, not_when),
            };
            const node = tree.root(r).node;
            const empty = tree.kind(node) == .fragment and tree.fragment(node).children.len == 0;
            if (empty) continue;
            if (shown != null or tree.kind(node) != .element) return later(cx, n, not_when);
            shown = @intCast(k);
        }
        const s = shown orelse return later(cx, n, not_when);
        const arm = br.arms[s];
        if (!arm.eager or arm.statements) return later(cx, n, "an `if` or a `case` in markup whose shown arm reads a variable the branch binds, or has `let`s,");
        const facts = try pg.known(n, cx.programHole(.{ .node = n }));
        const armRoot = arm.what.markup;
        try pg.ctxs.append(pg.a(), .{ .parent = ctx, .node = n, .arm = s, .root = armRoot });
        const inner: u32 = @intCast(pg.ctxs.items.len - 1);
        // The arm's facts, on its path.
        // The `when` before the arm's own writes: document order.
        try pg.writes.append(pg.a(), .{ .target = pg.count, .ctx = ctx, .groups = try sorted(pg.a(), &.{facts.group}), .what = .{ .when = .{ .node = n, .shown = s } } });
        _ = try cx.programBranchEnter(null, n, s, false, null);
        const html = try pg.element(tree.root(armRoot).node, scope, inner, false);
        cx.programInlineLeave();
        return html;
    }

    /// An attribute or an event of element `n` (`target`): a constant one
    /// written into the markup, one `init` bakes too, any other a write; an
    /// event recorded for the mount to wire.
    fn item(pg: *Page, n: m.Node.Index, target: ?u32, ctx: u32, it: m.Item, index: u32, out: *std.ArrayList(u8)) m.Error!void {
        const tree = pg.tree;
        const cx = pg.cx;
        switch (it.kind) {
            .attribute => {},
            .event => {
                try pg.events.append(pg.a(), .{ .node = n, .target = target, .ctx = ctx, .item = it, .index = index });
                return;
            },
            else => return later(cx, n, "an escape attribute"),
        }
        const name = tree.string(it.name);
        var stateful = false;
        var property: ?[]const u8 = null;
        if (it.attribute != .none) {
            const f = tree.attributeFacts(it.attribute);
            if (f.raw or f.classes or f.styles) return later(cx, n, "an attribute written as raw HTML, or a class or style list");
            if (f.property) |prop| property = tree.string(prop);
            stateful = f.stateful;
        }
        if (it.url) return later(cx, n, "an attribute that holds a URL");
        switch (it.value.kind) {
            .constant => {
                // A control's value in the markup would be its default, not
                // what it shows: a constant one is a write too.
                if (stateful) return later(cx, n, "a constant value of a control");
                return writeAttribute(pg.a(), out, name, it.value.constant, tree);
            },
            .dynamic => {},
            else => return later(cx, n, "this attribute's value"),
        }
        const v = it.value.dynamic.?;
        const facts = try pg.known(n, cx.programHole(.{ .item = index }));
        if (facts.bake) |b| if (!stateful and property == null) {
            return writeValue(pg.a(), out, name, b);
        };
        // A boolean attribute whose DOM property has its name, or a
        // property: written through it (§8.2).
        const key: ?[]const u8 = if (property) |prop|
            (if (std.mem.eql(u8, prop, "value")) null else prop)
        else if (it.class == .bool and isBoolProperty(name))
            name
        else
            return later(cx, n, "an attribute that is not a DOM property and whose value changes");
        try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), &.{facts.group}), .what = .{ .prop = .{ .value = v, .key = key } }, .stateful = stateful });
    }

    // ---- The mount ----------------------------------------------------

    /// The mount (`browser-inline.md` §3–§4, §8): the element found, `init`
    /// evaluated (a release build drops it when nothing reads it and it has
    /// no effect), the markup written once after the element's children,
    /// the elements found, each binding function written and called once,
    /// each key's handler, each event wired, each subscription started,
    /// `init`'s command queued, and what undoes the mount registered.
    fn mount(pg: *Page, view_node: m.Node.Index) m.Error!m.Expr {
        const cx = pg.cx;
        const js = cx.js;
        if (pg.top_nodes.len > 1) return later(cx, view_node, "a `view` of more than one top-level node");
        const element_ = pg.p.constructor == 1;
        const keys = cx.programKeys();
        pg.handlers = try pg.a().alloc(?m.Name, keys.len);
        @memset(pg.handlers, null);

        // What the program's subscriptions and commands are, refused first.
        var subs: []const m.Program.Subscription = &.{};
        if (element_) {
            switch (cx.programSubscriptions()) {
                .set => |s| subs = s,
                .model => return cx.programReport(.call, .not_implemented,
                    \\A limit of the compiler: this program's subscriptions depend on its model, and
                    \\`browser-inline` compiles a set of subscriptions that is the same for the page's life;
                    \\a set that changes it does not compile yet (`docs/design/browser-inline.md` §3; §5,
                    \\class 1). Write `subscriptions` so that it does not read the model, and let `update`
                    \\ignore what it does not need.
                ),
                .no_key => |where| return cx.programReport(.call, .program_shape, try std.fmt.allocPrint(cx.arena,
                    \\The subscription at {s} hands its values to a tagger that does not give one of the
                    \\program's message constructors, and `browser-inline` calls the handler of that
                    \\constructor's key with each value directly, with no message made
                    \\(`docs/design/browser-inline.md` §3; §5, class 3). Tag the value with a constructor of
                    \\the message that takes it — `Pushed Value`, tagged with `Pushed` — and decide in
                    \\`update` what it means.
                , .{where})),
                .limit => |where| return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: the subscription at {s} tags its values with a message whose
                    \\handler the write-set pass decides only from the value itself — the constructor wraps
                    \\the value, or `update` matches on what the value holds — and `browser-inline` calls a
                    \\handler chosen when the program is built (`docs/design/browser-inline.md` §3; §5,
                    \\class 4). The program is valid: it builds with `--platform=browser-tea`.
                , .{where})),
                else => return cx.programReport(.call, .not_implemented,
                    \\A limit of the compiler: the write-set pass could not read this program's
                    \\subscriptions as a list of `Sub.on` declarations with constant keys
                    \\(`docs/design/browser-inline.md` §3; §5, class 4). Write them with `Sub.on`,
                    \\`Sub.batch`, `Sub.map` and `Sub.none`, each key a constant.
                ),
            }
        }
        for (subs) |s| {
            if (s.handler >= keys.len) return cx.programReport(.call, .not_implemented, "A limit of the compiler: a subscription's key has no handler.");
            if (s.fields > 1 or keys[s.handler].fields != s.fields) return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\A limit of the compiler: `browser-inline` does not compile the subscription at {s} yet:
                \\its message's constructor takes the value in more than one field
                \\(`docs/design/browser-inline.md` §5, class 1). Give the constructor one field for the
                \\value.
            , .{s.where}));
            _ = try pg.handler(s.handler);
        }
        // A command that runs sends messages of any key: every key is then
        // reached, through the dispatcher.
        var runs = element_ and try pg.command(null);

        pg.body = try js.block();
        const body = pg.body;
        const id = try cx.fresh("id");
        const at = try cx.fresh("root");
        // The element: the one a placement written at the call names, the
        // page's body for `main` itself, or the one the program value is
        // handed. A constant argument is one a release build folds into
        // `root`.
        const which = switch (pg.p.placed) {
            .at => |text_| try js.string(text_),
            .body => try js.literal(.undefined),
            else => try js.name(id),
        };
        try js.constant(body, at, try js.call(try js.name(try cx.runtime("root")), &.{which}));
        const init = try cx.programInit(body);
        // The model, kept only when something reads it.
        pg.model = try cx.fresh("model");
        const reads_model = pg.writes.items.len != 0 or pg.events.items.len != 0 or pg.pieces.items.len != 0 or subs.len != 0 or runs;
        if (reads_model) try js.let(body, pg.model, if (element_) try js.member(init, "a") else init);
        if (pg.top_nodes.len == 1) {
            cx.at(view_node);
            var html: std.ArrayList(u8) = .empty;
            // The whole string the parser reads: nothing is appended after
            // it, so the end of the input may close the last node's path.
            try serialise(pg.a(), &html, pg.top_nodes, null, true);
            try js.expression(body, try js.call(try js.member(try js.name(at), "insertAdjacentHTML"), &.{ try js.string("beforeend"), try pg.htmlValue(html.items) }));
            pg.node = try cx.fresh("node");
            try js.constant(body, pg.node.?, try js.member(try js.name(at), "lastChild"));
            // Each piece registers what removes it as it is added, so a mount
            // that throws halfway leaves nothing `stop` cannot take back.
            const undo = try js.block();
            try js.expression(undo, try js.call(try js.member(try js.name(pg.node.?), "remove"), &.{}));
            try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{try js.arrow(&.{}, undo)}));
        }
        // The elements code refers to, by place.
        const placed = pg.pieces.items.len != 0 or for (pg.writes.items) |w| {
            if (w.target != null) break true;
        } else for (pg.events.items) |ev| {
            if (ev.target != null) break true;
        } else false;
        if (placed) {
            // One element referred to is reached by its path from the top
            // node, which costs less than the list of all of them; more are
            // read from the list (§8.2).
            const only = pg.onlyTarget();
            const path = if (only) |t| try pathOf(pg.a(), pg.top_nodes[0].children, t) else null;
            if (path) |steps| {
                pg.elements = try cx.fresh("element");
                pg.single = true;
                var e: m.Expr = try js.name(pg.node.?);
                for (steps) |i| e = if (i == 0) try js.member(e, "firstChild") else try js.index(try js.member(e, "childNodes"), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{i})));
                try js.constant(body, pg.elements.?, e);
            } else {
                pg.elements = try cx.fresh("elements");
                try js.constant(body, pg.elements.?, try js.call(try js.member(try js.name(pg.node.?), "querySelectorAll"), &.{try js.string("*")}));
            }
        }

        // Each piece's elements, below its top element.
        for (pg.pieces.items) |*u| {
            u.elements = try cx.fresh("elements");
            try js.constant(body, u.elements, try js.call(try js.name(try cx.runtime("part")), &.{try pg.ref(u.target)}));
        }
        // The binding functions, each written once and called once now.
        try pg.group();
        try pg.letsOnce();
        for (pg.pieces.items, 0..) |*u, ui| {
            u.first = @intCast(pg.functions.items.len);
            for (u.data.binds, 0..) |b, bi| try pg.functions.append(pg.a(), .{ .groups = b.groups, .piece = .{ .use = @intCast(ui), .bind = @intCast(bi) } });
        }
        for (pg.functions.items) |*f| {
            const blk = try js.block();
            f.name = try cx.fresh("bind");
            if (f.piece) |pat| {
                // A piece's binding: the table and the root's function's
                // arguments are its wrapper's parameters, which release names
                // alike in every piece's wrapper, as tea-inline's widget
                // functions' `(E, s)`; the piece is written into it.
                const u = pg.pieces.items[pat.use];
                const params = try pg.a().alloc(m.Name, u.data.arity + 1);
                for (params) |*x| x.* = try cx.fresh("p");
                const callee = try cx.programPieceName(u.node, u.data.binds[pat.bind].name);
                const args = try pg.a().alloc(m.Expr, params.len);
                for (args, params) |*x, n| x.* = try js.name(n);
                try js.expression(blk, try js.call(try js.name(callee), args));
                try js.constant(body, f.name, try js.arrow(params, blk));
                continue;
            }
            try pg.writeFunction(blk, f);
            try js.constant(body, f.name, try js.arrow(&.{}, blk));
        }
        for (0..pg.functions.items.len) |fi| try pg.callFunction(body, @intCast(fi));

        // Each event's listener, planned now and wired after the handlers
        // it calls: which key it reaches decides what a stateful control's
        // handler writes back, and a key only one event reaches has its
        // handler written in that event's listener.
        var plans: std.ArrayList(Plan) = .empty;
        for (pg.events.items) |ev| try plans.append(pg.a(), try pg.plan(ev));
        // Per key, the functions writing a stateful control one of its events
        // is on: its handler calls them whatever it writes (§8.3).
        pg.controls = try pg.a().alloc(std.ArrayList(u32), keys.len);
        @memset(pg.controls, .empty);
        var stateful_at: std.AutoHashMapUnmanaged(?u32, std.ArrayList(u32)) = .empty;
        for (pg.functions.items, 0..) |f, fi| for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (!w.stateful) continue;
            const slot = try stateful_at.getOrPut(pg.a(), w.target);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(pg.a(), @intCast(fi));
        };
        // Per key, how many places call its handler, and the one event that
        // does when it is one.
        const refs = try pg.a().alloc(u32, keys.len);
        @memset(refs, 0);
        const only = try pg.a().alloc(?u32, keys.len);
        @memset(only, null);
        for (subs) |s| refs[s.handler] += 1;
        for (plans.items, 0..) |pl, i| {
            refs[pl.key] += 1;
            only[pl.key] = @intCast(i);
            if (stateful_at.get(pg.events.items[i].target)) |fs| try pg.controls[pl.key].appendSlice(pg.a(), fs.items);
        }
        // Each piece's handlers, by the key the constructor reaches through
        // the hole's maps.
        const piece_keys = try pg.a().alloc([]m.Context.PieceKey, pg.pieces.items.len);
        for (pg.pieces.items, piece_keys) |u, *ks| {
            ks.* = try pg.a().alloc(m.Context.PieceKey, u.data.handlers.len);
            for (u.data.handlers, ks.*) |h, *pk| {
                pk.* = cx.programPieceKey(u.node, h.ctor) orelse {
                    // A key the pass cut or could not split names its own
                    // cause before the maps are blamed.
                    for (keys) |key| if (key.star or key.cap != .none) try pg.refuseKey(key);
                    return limit(cx, u.node, "an event of this other module's markup sends a message whose key `browser-inline` cannot name through the `Html.map`s around the call, each of which must be a constructor of one field");
                };
                const k = pk.key;
                if (keys[k].fields != (if (pk.whole) 1 else h.fields)) return limit(cx, u.node, "an event of this other module's markup sends a message whose key's handler takes another number of fields");
                refs[k] += 1;
                for (h.controls) |c| try pg.controls[k].append(pg.a(), u.first + c);
            }
        }
        for (refs, 0..) |r, k| if (r != 0 and element_) {
            if (try pg.command(@intCast(k))) runs = true;
        };
        if (runs) {
            // The dispatcher hands a handler the message's fields as `params`
            // reads them; a handler of a deeper key takes its leaf's.
            for (keys) |key| if (key.fields != key.params) return cx.programReport(.call, .not_implemented,
                \\A limit of the compiler: this program's commands send messages, which reach their handlers
                \\through a dispatcher, and `browser-inline`'s dispatcher does not yet hand a key of a
                \\message inside another its leaf's fields (`docs/design/browser-inline.md` §4, §8.4; §5,
                \\class 1). Build this program with `--platform=browser-tea`.
            );
            for (0..keys.len) |k| {
                refs[k] += 1;
                if (element_) _ = try pg.command(@intCast(k));
            }
            pg.dispatch = try cx.fresh("dispatch");
        }

        // One handler per key reached: its arm writes the model, then the
        // write pass calls each binding function the key's writes reach,
        // once, then its command is queued.
        const any = for (refs) |r| {
            if (r != 0) break true;
        } else false;
        const update = if (any) try cx.programUpdate(body) else null;
        const listeners = try pg.a().alloc(m.Expr, plans.items.len);
        const inlined = try pg.a().alloc(bool, plans.items.len);
        @memset(inlined, false);
        for (keys, 0..) |key, k| {
            if (refs[k] == 0) continue;
            try pg.refuseKey(key);
            const params = try pg.a().alloc(m.Name, key.fields);
            for (params) |*x| x.* = try cx.fresh("value");
            if (refs[k] == 1) if (only[k]) |i| {
                // Written in its one event's listener, its fields bound to
                // what the event's message holds.
                const pl = plans.items[i];
                if (pl.args.len != params.len) return limit(cx, pl.node, "this event's message has another number of fields than its key's handler takes");
                for (params, pl.args) |x, arg| try js.constant(pl.blk, x, arg);
                try pg.handlerBody(pl.blk, @intCast(k), params, update);
                listeners[i] = if (pl.event) |e| try js.arrow(&.{e}, pl.blk) else try js.arrow(&.{}, pl.blk);
                inlined[i] = true;
                continue;
            };
            const blk = try js.block();
            try pg.handlerBody(blk, @intCast(k), params, update);
            try js.constant(body, try pg.handler(@intCast(k)), try js.arrow(params, blk));
        }
        // Every other listener calls its key's handler, or is it.
        for (plans.items, listeners, inlined) |pl, *l, done| {
            if (done) continue;
            const h = try js.name(try pg.handler(pl.key));
            if (pl.args.len == 0 and pl.event == null) {
                l.* = h;
                continue;
            }
            try js.expression(pl.blk, try js.call(h, pl.args));
            l.* = if (pl.event) |e| try js.arrow(&.{e}, pl.blk) else try js.arrow(&.{}, pl.blk);
        }
        if (pg.dispatch) |d| {
            const msg = try cx.fresh("msg");
            const blk = try js.block();
            const all = try pg.a().alloc(m.Name, keys.len);
            for (all, 0..) |*x, k| x.* = try pg.handler(@intCast(k));
            try cx.programDispatch(blk, try js.name(msg), all);
            try js.constant(body, d, try js.arrow(&.{msg}, blk));
        }

        // Each event wired. A listener with neither flag is the runtime's
        // `on`, the event's name left out for a click.
        for (plans.items, listeners) |pl, f| {
            const node = try pg.ref(pl.target);
            if (!pl.flags.prevent_default and !pl.flags.stop_propagation) {
                if (pl.kind) |k| {
                    try js.expression(body, try js.call(try js.name(try cx.runtime("on")), &.{ node, f, try js.string(k) }));
                } else try js.expression(body, try js.call(try js.name(try cx.runtime("on")), &.{ node, f }));
                continue;
            }
            const ev = try cx.fresh("event");
            const dom = try js.block();
            if (pl.flags.prevent_default) try js.expression(dom, try js.call(try js.member(try js.name(ev), "preventDefault"), &.{}));
            if (pl.flags.stop_propagation) try js.expression(dom, try js.call(try js.member(try js.name(ev), "stopPropagation"), &.{}));
            try js.expression(dom, try js.call(try js.name(try cx.runtime("send")), &.{ f, try js.name(ev) }));
            try js.expression(body, try js.call(try js.member(node, "addEventListener"), &.{
                try js.string(pl.kind orelse "click"),
                try js.arrow(&.{ev}, dom),
            }));
        }

        // Each piece's events, wired to the handlers of their keys.
        for (pg.pieces.items, piece_keys) |u, ks| {
            const wire = u.data.wire orelse continue;
            const args = try pg.a().alloc(m.Expr, ks.len + 1);
            args[0] = try js.name(u.elements);
            for (args[1..], ks, u.data.handlers) |*x, pk, h| {
                const handler_ = try js.name(try pg.handler(pk.key));
                if (!pk.whole) {
                    x.* = handler_;
                    continue;
                }
                // The key's handler takes the message below its leaf: made
                // here, from the constructor's fields.
                const fields = try pg.a().alloc(m.Name, h.fields);
                const field_exprs = try pg.a().alloc(m.Expr, h.fields);
                for (fields, field_exprs) |*f, *fe| {
                    f.* = try cx.fresh("value");
                    fe.* = try js.name(f.*);
                }
                const blk = try js.block();
                try js.expression(blk, try js.call(handler_, &.{try cx.programPieceMessage(u.node, h.ctor, pk.key, field_exprs)}));
                x.* = try js.arrow(fields, blk);
            }
            try js.expression(body, try js.call(try js.name(try cx.programPieceName(u.node, wire)), args));
        }

        // Each subscription started: the first declaration of each key
        // starts it, and each value goes through every declaration of that
        // key in order, each a dispatch of its own.
        for (subs, 0..) |s, i| {
            if (s.first != i) continue;
            const v = try cx.fresh("v");
            const sends = try js.block();
            for (subs) |t| {
                if (t.first != i) continue;
                // A message with no payload passes none: `send`'s argument is
                // `undefined` either way.
                const handler_ = try js.name(try pg.handler(t.handler));
                try js.expression(sends, try js.call(try js.name(try cx.runtime("send")), if (t.fields == 0) &.{handler_} else &.{ handler_, try js.name(v) }));
            }
            const send = try js.arrow(if (s.fields == 0) &.{} else &.{v}, sends);
            const remove = try cx.fresh("remove");
            try js.constant(body, remove, try cx.programSubscriptionStart(body, @intCast(i), send));
            try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{try js.name(remove)}));
        }
        // `init`'s command, after the mount's writes.
        if (element_ and cx.programCommand(null) == .runs) {
            try js.expression(body, try js.call(try js.name(try cx.runtime("commands")), &.{ try js.member(init, "b"), try js.name(pg.dispatch.?) }));
        }
        return js.arrow(&.{id}, body);
    }

    /// What a key's handler is refused by (§8.7): an `update` computed when
    /// the page runs has no arm to write (class 3); a `*` key, by its kind
    /// (§5, the owner, 2026-10-17) — lost precision is a limit of the
    /// compiler (class 4), an inferred whole write of a record of several
    /// fields the language rule (class 3), and a model of one value is
    /// written exactly and accepted, every binding called.
    fn refuseKey(pg: *Page, key: m.Program.Key) m.Error!void {
        const cx = pg.cx;
        if (pg.p.update == .computed) return cx.programReport(.update, .program_shape,
            \\This program's `update` is a value computed when the page runs, so `browser-inline`
            \\cannot write each message's arm into the handler of its key: a handler is the arm itself,
            \\with no message made (`docs/design/browser-inline.md` §8.7; §5, class 3). Name a function
            \\of the program's modules as `update`, or write a lambda whose body chooses the arm.
        );
        // A key the depth limit or the rounds of a recursive function cut
        // (`Program.Key.cap`): what it writes below the cut is not known
        // (§8.7, class 4) until the pass folds paths precisely (#286).
        if (!key.star and (key.cap == .depth or key.cap == .rounds)) {
            const spelled_ = if (key.spelled.len != 0) key.spelled else key.name;
            const where = if (key.cap == .depth) "at its depth limit, 8 steps below the model" else "where a recursive function needs more than the pass's 4 rounds";
            const fix = if (key.cap == .depth) "a model nested less deeply builds here" else "a function that recurses over a smaller structure builds here";
            return cx.programReport(.update, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\A limit of the compiler: the write-set pass cut what key `{s}` writes {s}, so it cannot
                \\say which bindings those writes reach (`docs/design/browser-inline.md` §8.7; §5, class 4).
                \\The program is valid: it builds with `--platform=browser-tea`, and {s}.
            , .{ spelled_, where, fix }));
        }
        if (!key.star) return;
        // The key as the program spells it: `Run`. A key of no steps whose
        // message type the pass does not know (an `update` with no
        // annotation) is the program's one key, never `(any)`.
        const spelled = if (key.spelled.len != 0) key.spelled else key.name;
        const name = if (std.mem.eql(u8, spelled, "(any)"))
            "every message of the program"
        else
            try std.fmt.allocPrint(cx.arena, "key `{s}`", .{spelled});
        switch (key.star_kind) {
            // It opens the sentence: `Key …`, `Every message …`.
            .whole_record => return cx.programReport(.update, .program_shape, try std.fmt.allocPrint(cx.arena,
                \\{s} writes the whole model, a record of several fields, in one value, which hides
                \\which of its fields changed, so no binding of the page can be chosen for it:
                \\`browser-inline` writes only the bindings a key's writes reach, and never checks the
                \\whole page again (`docs/design/browser-inline.md` §8.7; §5, class 3). Write the fields
                \\the arm changes, as a record update of the model — `{{ model | field = … }}` — or, for
                \\a replacement of the whole model, a declared `replace` once the language has one.
            , .{try capital(cx.arena, name)})),
            .precision => {
                const lost = key.lost orelse return cx.programReport(.update, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: the write-set pass lost track of what {s} writes{s}, and
                    \\says it writes the whole model, so it cannot tell which of the model's fields change
                    \\(`docs/design/browser-inline.md` §8.7; §5, class 4). The program is valid: it builds
                    \\with `--platform=browser-tea`.
                , .{ name, capOf(key.cap) }));
                const what = if (lost.text.len != 0) try std.fmt.allocPrint(cx.arena, "`{s}`", .{lost.text}) else try std.fmt.allocPrint(cx.arena, "the expression at {s}", .{lost.where});
                // The function called, as the text spells it: its first word.
                const callee = lost.text[0 .. std.mem.indexOfAny(u8, lost.text, " (") orelse lost.text.len];
                const why = switch (lost.kind) {
                    .parameter => try std.fmt.allocPrint(cx.arena, "a call of `{s}`, a function-valued parameter, which the compiler cannot see through", .{callee}),
                    .local => try std.fmt.allocPrint(cx.arena, "a call of `{s}`, a function a pattern or a `let` binds, which the compiler knows only as a value", .{callee}),
                    .record => "a record of a type the compiler cannot read",
                    else => "a call whose result the compiler cannot see into",
                };
                if (key.cap != .none) return cx.programReportAt(lost.site, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: the write-set pass stopped following what {s} writes at
                    \\{s}{s}, so it cannot tell which of the model's fields change
                    \\(`docs/design/browser-inline.md` §8.7; §5, class 4). Write the arm with less nesting, or
                    \\build this program with `--platform=browser-tea`, where the program is valid.
                , .{ name, what, capOf(key.cap) }));
                const more = if (lost.more == 0) "" else try std.fmt.allocPrint(cx.arena, " (and {d} more place{s})", .{ lost.more, if (lost.more == 1) "" else "s" });
                return cx.programReportAt(lost.site, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: {s} writes the whole model with {s}{s}, {s}, so the
                    \\compiler cannot tell which of the model's fields change (`docs/design/browser-inline.md`
                    \\§8.7; §5, class 4). Write each change in `update` itself — a message per change, each
                    \\writing its fields — and the bindings it reaches follow. The program is valid: it
                    \\builds with `--platform=browser-tea`.
                , .{ name, what, more, why }));
            },
            // A model of one value: its one write is the model, exactly.
            .single_value => {},
            // A key the write-set pass never made: the program is one it did
            // not analyse. Never passed on, so no handler is written without
            // its pass (`browser-inline.md` §8.3, amended 2026-10-19).
            .none, _ => return cx.programReport(.update, .not_implemented,
                \\A limit of the compiler: the write-set pass did not analyse this program, so
                \\`browser-inline` cannot say which bindings a message reaches
                \\(`docs/design/browser-inline.md` §8.3; §5, class 4). The program is valid: it builds
                \\with `--platform=browser-tea`.
            ),
        }
    }

    /// The cap of the write-set pass that cut a key's writes, in words, for
    /// a diagnostic: empty when none did.
    fn capOf(cap: m.Program.Key.Cap) []const u8 {
        return switch (cap) {
            .depth => " past the write-set pass's depth limit of 8 steps below the model",
            .alternatives => " past the write-set pass's limit of 16 alternatives",
            .instantiation => " where calls of functions nest past the write-set pass's limit of 8",
            .rounds => " where a recursive function needs more rounds than the write-set pass's 4",
            .size => " past the write-set pass's term size limit",
            .work => " past the write-set pass's work limit",
            .leaves => " past the write-set pass's 256 message keys",
            else => "",
        };
    }

    /// Key `k`'s handler's name, made the first time it is asked for.
    fn handler(pg: *Page, k: u32) m.Error!m.Name {
        if (pg.handlers[k]) |h| return h;
        const keys = pg.cx.programKeys();
        const h = try pg.cx.fresh(try std.fmt.allocPrint(pg.a(), "on{s}", .{handlerHint(keys[k].name)}));
        pg.handlers[k] = h;
        return h;
    }

    /// Whether key `key`'s command — or `init`'s, for null — runs; one that
    /// may suspend, or that the pass could not read, is refused.
    fn command(pg: *Page, key: ?u32) m.Error!bool {
        const cx = pg.cx;
        switch (cx.programCommand(key)) {
            .none => return false,
            .runs => return true,
            .suspends => |where| return cx.programReport(if (key == null) .init else .update, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\A limit of the compiler: the command whose body is at {s} may suspend, and a body that
                \\suspends needs the task kernel, which `browser-inline` does not have yet
                \\(`docs/design/browser-inline.md` §4; §5, class 2).
                \\Write the body so that it does not wait, or build this program with
                \\`--platform=browser-tea`.
            , .{where})),
            else => return cx.programReport(if (key == null) .init else .update, .not_implemented,
                \\A limit of the compiler: the write-set pass could not read this command as
                \\`Cmd.none`, `Cmd.batch` or `Cmd.perform` (`docs/design/browser-inline.md` §4; §5,
                \\class 4). Write the command where `update` returns it, with those three.
            ),
        }
    }

    /// The one descendant the page's code refers to, when it is one.
    fn onlyTarget(pg: *Page) ?u32 {
        if (pg.pieces.items.len != 0) return null;
        var only: ?u32 = null;
        for (pg.writes.items) |w| if (w.target) |t| {
            if (only != null and only.? != t) return null;
            only = t;
        };
        for (pg.events.items) |ev| if (ev.target) |t| {
            if (only != null and only.? != t) return null;
            only = t;
        };
        return only;
    }

    /// The element at `target`: the top node, or its descendant by place.
    fn ref(pg: *Page, target: ?u32) m.Error!m.Expr {
        const js = pg.cx.js;
        const t = target orelse return js.name(pg.node.?);
        if (pg.single) return js.name(pg.elements.?);
        return js.index(try js.name(pg.elements.?), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{t})));
    }

    // ---- Binding functions --------------------------------------------

    /// The writes grouped by their sets of read sets, one function each, in
    /// the order of their first write: the page's document order.
    fn group(pg: *Page) m.Error!void {
        var by: std.StringHashMapUnmanaged(u32) = .empty;
        for (pg.writes.items, 0..) |w, i| {
            const key = std.mem.sliceAsBytes(w.groups);
            const slot = try by.getOrPut(pg.a(), key);
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(pg.functions.items.len);
                try pg.functions.append(pg.a(), .{ .groups = w.groups });
            }
            const f = &pg.functions.items[slot.value_ptr.*];
            try f.writes.append(pg.a(), @intCast(i));
        }
    }

    /// Enter context `ctx` for evaluation, outermost first: the `view` with
    /// the model, then each eager arm. Returns how many arms were entered.
    fn enter(pg: *Page, blk: m.Block, ctx: u32) m.Error!u32 {
        var chain: std.ArrayList(u32) = .empty;
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) try chain.insert(pg.a(), 0, c);
        if (pg.piece) {
            const args = try pg.a().alloc(m.Expr, pg.piece_args.len);
            for (args, pg.piece_args) |*x, n| x.* = try pg.cx.js.name(n);
            try pg.cx.pieceViewEnter(blk, args);
        } else try pg.cx.programViewEnter(blk, try pg.cx.js.name(pg.model));
        for (chain.items[1..]) |c| {
            const x = pg.ctxs.items[c];
            try pg.cx.programBranchEager(x.node, x.arm);
        }
        return @intCast(chain.items.len - 1);
    }

    fn leave(pg: *Page, arms: u32) void {
        for (0..arms) |_| pg.cx.programInlineLeave();
        pg.cx.programViewLeave();
    }

    /// A call of binding function `fi` into `blk`: of no arguments, or for a
    /// piece's, its table and the root's function's arguments, evaluated in
    /// the `view` as the model is now.
    fn callFunction(pg: *Page, blk: m.Block, fi: u32) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const f = pg.functions.items[fi];
        const at = f.piece orelse return js.expression(blk, try js.call(try js.name(f.name), &.{}));
        const u = pg.pieces.items[at.use];
        const inner = try js.block();
        const arms = try pg.enter(inner, 0);
        const args = try cx.programPieceArgs(inner, u.node);
        // The wrapper takes the table and the root's function's parameters.
        std.debug.assert(args.len == u.data.arity);
        const all = try pg.a().alloc(m.Expr, args.len + 1);
        all[0] = try js.name(u.elements);
        @memcpy(all[1..], args);
        try js.expression(inner, try js.call(try js.name(f.name), all));
        pg.leave(arms);
        try js.nested(blk, inner);
    }

    /// Root `r`'s `let`s that `values` read, directly or through a later
    /// `let`, evaluated into `blk` and read under their names (D-d).
    fn bindLets(pg: *Page, blk: m.Block, r: m.Root.Index, values: []const m.Value.Index) m.Error!void {
        const cx = pg.cx;
        const lets = pg.tree.root(r).lets;
        const needed = try pg.neededLets(r, values);
        for (0..lets.len) |kk| {
            if (!needed[kk]) continue;
            const lv = lets.at(@intCast(kk));
            try cx.rootValues(blk, r, &.{lv});
            const n = try cx.fresh("let");
            try cx.js.constant(blk, n, try cx.value(lv));
            try cx.bindLet(r, @intCast(kk), n);
        }
    }

    /// Which of root `r`'s `let`s `values` read, directly or through a
    /// later `let`.
    fn neededLets(pg: *Page, r: m.Root.Index, values: []const m.Value.Index) m.Error![]bool {
        const cx = pg.cx;
        const lets = pg.tree.root(r).lets;
        const needed = try pg.a().alloc(bool, lets.len);
        @memset(needed, false);
        var k = lets.len;
        while (k > 0) {
            k -= 1;
            for (values) |v| if (cx.valueReadsLet(r, @intCast(k), v)) {
                needed[k] = true;
                break;
            };
            if (needed[k]) continue;
            for (k + 1..lets.len) |j| if (needed[j] and cx.valueReadsLet(r, @intCast(k), lets.at(@intCast(j)))) {
                needed[k] = true;
                break;
            };
        }
        return needed;
    }

    /// What binding function `f` reads in context `ctx`: each `when`'s
    /// branch value, which picks its arm, then its writes' values, which
    /// are appended to `values` too.
    fn functionReads(pg: *Page, f: *const Function, ctx: u32, values: *std.ArrayList(m.Value.Index)) m.Error![]const m.Value.Index {
        var reads: std.ArrayList(m.Value.Index) = .empty;
        for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (w.ctx != ctx) continue;
            switch (w.what) {
                .text => |parts| for (parts) |part| switch (part) {
                    .value => |v| try values.append(pg.a(), v),
                    else => {},
                },
                .prop => |x| try values.append(pg.a(), x.value),
                .when => |x| try reads.append(pg.a(), pg.tree.hole(x.node).value),
            }
        }
        try reads.appendSlice(pg.a(), values.items);
        return reads.items;
    }

    /// D-d, as built: a `let` is evaluated in each binding function that
    /// reads it, directly or through another `let`, so one that two
    /// functions read would run twice in a pass that calls both — a
    /// `Debug.log` in it would log twice. That is a memo node, S3's (§8.2).
    fn letsOnce(pg: *Page) m.Error!void {
        var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        for (pg.functions.items, 0..) |*f, fi| {
            if (f.piece != null) continue;
            var done: std.ArrayList(u32) = .empty;
            for (f.writes.items) |first| {
                const ctx = pg.writes.items[first].ctx;
                if (std.mem.indexOfScalar(u32, done.items, ctx) != null) continue;
                try done.append(pg.a(), ctx);
                var values: std.ArrayList(m.Value.Index) = .empty;
                const reads = try pg.functionReads(f, ctx, &values);
                const roots = [_]m.Root.Index{ pg.ctxs.items[0].root, pg.ctxs.items[ctx].root };
                for (roots[0..if (ctx != 0) 2 else 1]) |r| {
                    const needed = try pg.neededLets(r, reads);
                    for (needed, 0..) |yes, k| {
                        if (!yes) continue;
                        const key = (@as(u64, @backingInt(r)) << 32) | k;
                        const gop = try seen.getOrPut(pg.a(), key);
                        if (gop.found_existing and gop.value_ptr.* != fi) return limit(pg.cx, pg.tree.root(r).node, "a `let` of this `view` is read by several binding functions, directly or through another `let`, and `browser-inline` computes a `let` in each function that reads it (D-d); one several read is a memo node, which slice S3 brings");
                        gop.value_ptr.* = @intCast(fi);
                    }
                }
            }
        }
    }

    /// A binding function's body: per context its writes are in, the
    /// context entered, its values evaluated and each write made.
    fn writeFunction(pg: *Page, blk: m.Block, f: *const Function) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        // A piece's binding is the program site's wrapper's call (`page`).
        std.debug.assert(f.piece == null);
        var done: std.ArrayList(u32) = .empty;
        for (f.writes.items) |first| {
            const ctx = pg.writes.items[first].ctx;
            if (std.mem.indexOfScalar(u32, done.items, ctx) != null) continue;
            try done.append(pg.a(), ctx);
            const arms = try pg.enter(blk, ctx);
            var values: std.ArrayList(m.Value.Index) = .empty;
            const reads = try pg.functionReads(f, ctx, &values);
            // The `let`s of the view's body its root takes (`Root.lets`, D-d):
            // each the function reads evaluated here, in source order, and
            // no other (`letsOnce`: no other function reads it).
            // An arm's root is never the view's own, so their `let`s, bound per
            // root and ordinal, never alias.
            if (ctx != 0) std.debug.assert(pg.ctxs.items[ctx].root != pg.ctxs.items[0].root);
            try pg.bindLets(blk, pg.ctxs.items[0].root, reads);
            if (ctx != 0) try pg.bindLets(blk, pg.ctxs.items[ctx].root, reads);
            try cx.rootValues(blk, pg.ctxs.items[ctx].root, values.items);
            for (f.writes.items) |wi| {
                const w = pg.writes.items[wi];
                if (w.ctx != ctx) continue;
                const node = try pg.ref(w.target);
                switch (w.what) {
                    .text => |parts| {
                        const value = if (parts.len == 1 and parts[0] == .value)
                            try cx.value(parts[0].value)
                        else value: {
                            const tp = try pg.a().alloc(m.TemplatePart, parts.len);
                            for (tp, parts) |*t, part| t.* = switch (part) {
                                .text => |s| .{ .text = s },
                                .value => |v| .{ .expr = try cx.value(v) },
                            };
                            break :value try js.template(tp);
                        };
                        // `text` takes a string: a lone number is written as
                        // one, by a template (`browser-inline.md` §8.2).
                        const shown = if (w.string) value else try js.template(&.{.{ .expr = value }});
                        try js.expression(blk, try js.call(try js.name(try cx.runtime("text")), &.{ node, shown }));
                    },
                    .prop => |x| {
                        const value = try cx.value(x.value);
                        if (x.key) |key| {
                            try js.expression(blk, try js.call(try js.name(try cx.runtime("prop")), &.{ node, value, try js.string(key) }));
                        } else try js.expression(blk, try js.call(try js.name(try cx.runtime("prop")), &.{ node, value }));
                    },
                    .when => |x| {
                        const taken = try cx.programBranchArm(blk, x.node);
                        // The arm taken is a number of two: hidden while it is not
                        // the shown one — itself when that is the first, else its
                        // negation.
                        const hidden = if (x.shown == 0) taken else try js.unary(.not, taken);
                        try js.expression(blk, try js.call(try js.name(try cx.runtime("when")), &.{ node, hidden }));
                    },
                }
            }
            pg.leave(arms);
        }
    }

    // ---- Listeners ----------------------------------------------------

    /// Event `ev`'s listener, planned: its block, which reads the payload
    /// through the event's extractor and evaluates the message the handler
    /// value makes, read at the event (Q1); the key it reaches and that
    /// key's fields. The mount then ends the block with the key's handler,
    /// or a call of it.
    fn plan(pg: *Page, ev: Event) m.Error!Plan {
        const cx = pg.cx;
        const js = cx.js;
        const tree = pg.tree;
        const facts = tree.eventFacts(ev.item.event);
        const dom = tree.string(facts.dom_name);
        const kind: ?[]const u8 = if (std.mem.eql(u8, dom, "click")) null else dom;
        const v = switch (ev.item.value.kind) {
            .dynamic => ev.item.value.dynamic.?,
            else => return limit(cx, ev.node, "this event's handler is a message written as a literal, which `browser-inline` cannot route to a key"),
        };
        const blk = try js.block();
        var event: ?m.Name = null;
        var payload: ?m.Expr = null;
        if (ev.item.form == .payload) {
            const e = try cx.fresh("event");
            event = e;
            if (try cx.extractor(ev.index)) |extract| {
                const p = try cx.fresh("payload");
                try js.constant(blk, p, try js.call(extract, &.{try js.name(e)}));
                payload = try js.name(p);
            } else payload = try js.name(e);
        }
        const arms = try pg.enter(blk, ev.ctx);
        const message = try cx.programMessageFields(blk, v, payload);
        pg.leave(arms);
        return switch (message) {
            .key => |kc| .{ .node = ev.node, .target = ev.target, .blk = blk, .event = event, .key = kc.key, .args = kc.args, .kind = kind, .flags = facts },
            .value => limit(cx, ev.node, "this event's handler value is not a constructor of the program's message whose key `browser-inline` can name, so its message would need a dispatcher"),
        };
    }

    /// Key `k`'s handler body into `blk`, its fields `params`: the arm
    /// writes the model, then the write pass calls each binding function the
    /// key's writes reach — and each a control of the key's events shows —
    /// once, in document order, then the key's command is queued.
    fn handlerBody(pg: *Page, blk: m.Block, k: u32, params: []const m.Name, update: ?m.Expr) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const key = cx.programKeys()[k];
        const element_ = pg.p.constructor == 1;
        const incoming = try cx.fresh("before");
        try js.constant(blk, incoming, try js.name(pg.model));
        const next = try cx.programArmFields(k, blk, params, try js.name(incoming), update);
        var result = next;
        if (element_) {
            const pair = try cx.fresh("result");
            try js.constant(blk, pair, next);
            result = try js.name(pair);
        }
        try js.assign(blk, try js.name(pg.model), if (element_) try js.member(result, "a") else result);
        for (try pg.passOf(k, key)) |fi| try pg.callFunction(blk, fi);
        if (element_) switch (cx.programCommand(k)) {
            .runs => try js.expression(blk, try js.call(try js.name(try cx.runtime("commands")), &.{ try js.member(result, "b"), try js.name(pg.dispatch.?) })),
            else => {},
        };
    }

    /// Key `k`'s write pass (§8.3): the binding functions the key's writes
    /// reach — from the groups the pass says they conflict with, each
    /// function found by its groups — and those of the controls its events
    /// are on, each once, in document order. There is no coarse pass: a `*`
    /// key reaches here only for a model of one value (`refuseKey`), whose
    /// whole write is that value, and the groups it reaches are the ones the
    /// pass found for it like any other key's (`programGroupsOf`).
    fn passOf(pg: *Page, k: u32, the: m.Program.Key) m.Error![]const u32 {
        // By construction: `refuseKey` ran for this key before its handler,
        // and refuses every `*` key but one of a model of one value.
        if (the.star) std.debug.assert(the.star_kind == .single_value);
        // Null only for a program the pass did not analyse, whose keys
        // `refuseKey` refused (`.none`); refused here too, so no build mode
        // writes a handler without its pass.
        const groups = pg.cx.programGroupsOf(k) orelse return pg.cx.programReport(.update, .not_implemented,
            \\A limit of the compiler: the write-set pass did not analyse this program, so
            \\`browser-inline` cannot say which bindings a message reaches
            \\(`docs/design/browser-inline.md` §8.3; §5, class 4). The program is valid: it builds
            \\with `--platform=browser-tea`.
        );
        if (pg.by_group.count() == 0 and pg.functions.items.len != 0) {
            pg.stamp = try pg.a().alloc(u32, pg.functions.items.len);
            @memset(pg.stamp, std.math.maxInt(u32));
            for (pg.functions.items, 0..) |f, fi| for (f.groups) |g| {
                const slot = try pg.by_group.getOrPut(pg.a(), g);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(pg.a(), @intCast(fi));
            };
        }
        var out: std.ArrayList(u32) = .empty;
        const add = struct {
            fn f(p: *Page, list: []const u32, key: u32, into: *std.ArrayList(u32)) !void {
                for (list) |fi| {
                    if (p.stamp[fi] == key) continue;
                    p.stamp[fi] = key;
                    try into.append(p.a(), fi);
                }
            }
        }.f;
        for (groups) |g| if (pg.by_group.get(g)) |fs| try add(pg, fs.items, k, &out);
        // By construction: every write's group passed `known`, and a
        // piece's binds were made by its owner's lowering, which refused the
        // same way, so no function is in the unknown bucket.
        std.debug.assert(pg.by_group.get(std.math.maxInt(u32)) == null);
        if (pg.controls.len != 0) try add(pg, pg.controls[k].items, k, &out);
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        return out.items;
    }
};

/// An event's listener, planned (`Page.plan`).
const Plan = struct {
    node: m.Node.Index,
    target: ?u32,
    blk: m.Block,
    /// The listener's parameter, when it reads the event.
    event: ?m.Name,
    key: u32,
    args: []const m.Expr,
    kind: ?[]const u8,
    flags: m.EventFacts,
};

fn textHole(kind: m.HoleKind) bool {
    return switch (kind) {
        .text_string, .text_number, .text_char => true,
        else => false,
    };
}

/// The boolean attributes whose DOM property has the attribute's name and
/// reflects it (`browser-inline.md` §8.2).
fn isBoolProperty(name: []const u8) bool {
    for ([_][]const u8{ "disabled", "hidden", "multiple", "open", "required" }) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

fn sorted(a: std.mem.Allocator, groups: []const u32) ![]const u32 {
    const out = try a.dupe(u32, groups);
    std.mem.sort(u32, out, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (out) |g| {
        if (n != 0 and out[n - 1] == g) continue;
        out[n] = g;
        n += 1;
    }
    return out[0..n];
}

/// A handler's name hint from its key's name: its letters and digits.
fn handlerHint(key: []const u8) []const u8 {
    var end: usize = 0;
    while (end < key.len and std.ascii.isAlphanumeric(key[end])) end += 1;
    return if (end == 0) "Key" else key[0..end];
}

// ---- The markup string (§8.2) -------------------------------------------

/// A constant attribute, written into `out`.
fn writeAttribute(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, c: m.Constant, tree: *const m.Tree) !void {
    switch (c.kind) {
        .string, .number => try writeValue(a, out, name, tree.string(c.text)),
        .bool => if (c.bool) {
            try out.append(a, ' ');
            try out.appendSlice(a, name);
        },
        .none => {
            try out.append(a, ' ');
            try out.appendSlice(a, name);
        },
        else => {},
    }
}

/// ` name=value`: unquoted where the parser reads it back so, bare when
/// empty, double-quoted otherwise.
fn writeValue(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.append(a, ' ');
    try out.appendSlice(a, name);
    if (value.len == 0) return;
    try out.append(a, '=');
    if (unquoted(value)) return escapeAmpersand(a, out, value);
    try out.append(a, '"');
    try escapeAttribute(a, out, value);
    try out.append(a, '"');
}

/// Whether an attribute value reads back the same unquoted: none of the
/// characters that end or change an unquoted value.
fn unquoted(value: []const u8) bool {
    for (value) |ch| switch (ch) {
        ' ', '\t', '\n', '\x0c', '\r', '"', '\'', '=', '<', '>', '`' => return false,
        else => {},
    };
    return true;
}

fn escapeAmpersand(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        else => try out.append(a, c),
    };
}

/// Text as the parser of an element's ordinary content reads it back.
fn escapeText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

/// A double-quoted attribute value as the parser reads it back.
fn escapeAttribute(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

/// `nodes`, the children of `parent` (null: the string's top level), into
/// `out`, each end tag left out where the parser closes the element there
/// as the end tag would: an optional one (`optionalEnd`), and any at the
/// very end of the string (`at_end`), which the parser closes at the end of
/// its input.
/// `at_end`: `nodes` end the whole string the parser reads — every end
/// tag of the last node's path is left out, which only the end of the input
/// closes as the end tags would, so the caller never appends to it.
fn serialise(a: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Html, parent: ?[]const u8, at_end: bool) !void {
    _ = try serialiseOpen(a, out, nodes, parent, at_end, false);
}

/// `serialise`, and whether the last node is an element other than a `<p>`
/// whose end tag it left out: that element is still open, and a start tag
/// that would close the parent stops at it — an `<li>` stops its search at a
/// `<dd>`, a special element — so the parent then keeps its own end tag
/// before a sibling (`<ul><li><dd>x</li><li>`; the review of S1's first
/// pull request).
/// `in_select`: `nodes` are inside a `<select>`, where every end tag is
/// written, the select's own included (`optionalEnd`).
fn serialiseOpen(a: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Html, parent: ?[]const u8, at_end: bool, in_select: bool) !bool {
    var open = false;
    for (nodes, 0..) |n, i| {
        open = false;
        const next: ?Html = if (i + 1 < nodes.len) nodes[i + 1] else null;
        switch (n.kind) {
            .text => try out.appendSlice(a, n.name),
            // A mark the mount replaces with the piece's string: the piece
            // writes every end tag of its own, so nothing of it is open.
            .piece => try out.print(a, "\x00{d}\x00", .{n.piece}),
            .element => {
                try out.append(a, '<');
                try out.appendSlice(a, n.name);
                try out.appendSlice(a, n.attributes);
                try out.append(a, '>');
                if (n.void) continue;
                const select = in_select or std.mem.eql(u8, n.name, "select");
                const last = next == null and at_end and !select;
                const child_open = try serialiseOpen(a, out, n.children, n.name, last, select);
                if (!select and (last or (optionalEnd(n.name, next, parent) and (next == null or !child_open)))) {
                    open = !std.mem.eql(u8, n.name, "p");
                    continue;
                }
                try out.appendSlice(a, "</");
                try out.appendSlice(a, n.name);
                try out.append(a, '>');
            },
        }
    }
    return open;
}

/// Whether element `name`'s end tag may be left out when `next` follows it
/// (null: its parent ends), in `parent` (null: unknown) — only where the
/// HTML standard's tree builder (§13.2.6) closes the element there exactly
/// as the end tag would:
///
/// - before a next sibling, the start tags that close it: an `<li>` an
///   open `<li>`, a `<dt>` or `<dd>` either, a cell a cell, a row a row, a
///   row group a row group, and the block elements whose start tag closes a `<p>` in
///   button scope (not `<table>`, which does only outside quirks mode, nor
///   `<form>`, which depends on the form pointer);
/// - at its parent's end, only a parent whose end tag generates implied end
///   tags (`impliesEnds`): any other end tag — `</span>`, `</label>`,
///   `</em>`, a custom element's — meets the open `<p>`, `<li>` or `<dd>`,
///   a special element, and is ignored, or runs the adoption agency for a
///   formatting element, which builds the tree anew.
///
/// The rules follow the HTML Living Standard's tree construction as parse5
/// 7.3.0 implements it (`tests/browser/parse5.mjs`), the parser the gates
/// check every page with: the standard before its rework of `select`
/// parsing for the customizable `<select>`, which replaced the "in select"
/// insertion mode. Nothing here depends on that mode: inside a `<select>`
/// every end tag is written (`serialiseOpen`'s `in_select`), so an
/// `<option>`, an `<optgroup>` and whatever they hold close where the tree
/// says under either revision (`browser/inline/SelectEndTags`).
fn optionalEnd(name: []const u8, next: ?Html, parent: ?[]const u8) bool {
    const eql = std.mem.eql;
    const nextIs = struct {
        fn f(n: ?Html, names: []const []const u8) bool {
            const x = n orelse return false;
            if (x.kind != .element) return false;
            for (names) |s| if (std.mem.eql(u8, s, x.name)) return true;
            return false;
        }
    }.f;
    const among = struct {
        fn f(s: []const u8, names: []const []const u8) bool {
            for (names) |x| if (std.mem.eql(u8, s, x)) return true;
            return false;
        }
    }.f;
    // At the parent's end: a parent known to close it.
    const ends = next == null and if (parent) |p| impliesEnds(p) or
        // A cell's end closes it, and a row's end closes a cell.
        (among(name, &.{ "td", "th" }) and eql(u8, p, "tr")) or
        (eql(u8, name, "tr") and among(p, &.{ "tbody", "thead", "tfoot" })) else false;
    if (eql(u8, name, "li")) return ends or nextIs(next, &.{"li"});
    if (eql(u8, name, "dt")) return nextIs(next, &.{ "dt", "dd" });
    if (eql(u8, name, "dd")) return ends or nextIs(next, &.{ "dt", "dd" });
    if (eql(u8, name, "td") or eql(u8, name, "th")) return ends or nextIs(next, &.{ "td", "th" });
    if (eql(u8, name, "tr")) return ends or nextIs(next, &.{"tr"});
    if (eql(u8, name, "thead")) return nextIs(next, &.{ "tbody", "tfoot" });
    if (eql(u8, name, "tbody")) return ends or nextIs(next, &.{ "tbody", "tfoot" });
    if (eql(u8, name, "p")) return ends or nextIs(next, &.{ "address", "article", "aside", "blockquote", "details", "dialog", "div", "dl", "fieldset", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "search", "section", "ul" });
    return false;
}

/// Whether the end tag of `name` generates implied end tags (§13.2.6.4.7):
/// it closes an open `<p>`, `<li>`, `<dd>`, `<dt>`, `<rp>` or `<rt>` inside it
/// (and an `<option>` or `<optgroup>`, whose end tags are always written).
fn impliesEnds(name: []const u8) bool {
    for ([_][]const u8{
        "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre", "search", "section", "summary", "ul",
        "li",      "dd",      "dt",    "h1",         "h2",     "h3",     "h4",      "h5",     "h6",  "td",  "th", "caption",  "body",       "html",
    }) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
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

test "an attribute value is unquoted only where the parser reads it back so" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeValue(a, &out, "data-role", "inc");
    try writeValue(a, &out, "title", "a b");
    try writeValue(a, &out, "data-x", "");
    try writeValue(a, &out, "data-y", "x&y");
    try t.expectEqualStrings(" data-role=inc title=\"a b\" data-x data-y=x&amp;y", out.items);
}

test "optional end tags and the closing run are left out" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const li = Html{ .kind = .element, .name = "li", .children = &.{.{ .kind = .text, .name = "x" }} };
    const p = Html{ .kind = .element, .name = "p" };
    const button = Html{ .kind = .element, .name = "button" };
    const div = Html{ .kind = .element, .name = "div" };
    const ul = Html{ .kind = .element, .name = "ul", .children = &.{ li, li } };
    const section = Html{ .kind = .element, .name = "section", .children = &.{ ul, p, button, p, div, p } };
    var out: std.ArrayList(u8) = .empty;
    try serialise(a, &out, &.{section}, null, false);
    try t.expectEqualStrings("<section><ul><li>x<li>x</ul><p></p><button></button><p><div></div><p></section>", out.items);
    out.clearRetainingCapacity();
    try serialise(a, &out, &.{section}, null, true);
    try t.expectEqualStrings("<section><ul><li>x<li>x</ul><p></p><button></button><p><div></div><p>", out.items);
    // A `<p>` at the end of an `<a>` keeps its end tag.
    out.clearRetainingCapacity();
    try serialise(a, &out, &.{.{ .kind = .element, .name = "a", .children = &.{p} }}, null, false);
    try t.expectEqualStrings("<a><p></p></a>", out.items);
}

/// The child indices from `nodes`, the top element's children, down to the
/// element of place `target` among its descendants in document order.
/// Null when two texts stand side by side on the way, which the parser
/// makes one node.
fn pathOf(a: std.mem.Allocator, nodes: []const Html, target: u32) !?[]const u32 {
    var path: std.ArrayList(u32) = .empty;
    var count: u32 = 0;
    if (!try find(a, nodes, target, &count, &path)) return null;
    var level = nodes;
    for (path.items) |i| {
        for (level[0..i], 0..) |n, j| if (n.kind == .text and j + 1 < level.len and level[j + 1].kind == .text) return null;
        level = level[i].children;
    }
    return path.items;
}

fn find(a: std.mem.Allocator, nodes: []const Html, target: u32, count: *u32, path: *std.ArrayList(u32)) !bool {
    for (nodes, 0..) |n, i| {
        if (n.kind != .element) continue;
        try path.append(a, @intCast(i));
        if (count.* == target) return true;
        count.* += 1;
        if (try find(a, n.children, target, count, path)) return true;
        _ = path.pop();
    }
    return false;
}

test "an end tag is left out only where the parser closes the element there" {
    // Each case's expectation is what the HTML standard's tree builder
    // (§13.2.6) makes of the string: the parent's end tag closes an open
    // `<p>`, `<li>`, `<dd>` only when it generates implied end tags, and a
    // formatting or phrasing parent's does not, so the end tag stays.
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const el = struct {
        fn f(name: []const u8, children: []const Html) Html {
            return .{ .kind = .element, .name = name, .children = children };
        }
    }.f;
    const x: Html = .{ .kind = .text, .name = "x" };
    const cases = [_]struct { tree: Html, html: []const u8 }{
        .{ .tree = el("div", &.{el("p", &.{x})}), .html = "<div><p>x</div>" },
        .{ .tree = el("button", &.{el("p", &.{x})}), .html = "<button><p>x</button>" },
        .{ .tree = el("label", &.{el("p", &.{x})}), .html = "<label><p>x</p></label>" },
        .{ .tree = el("em", &.{el("p", &.{x})}), .html = "<em><p>x</p></em>" },
        .{ .tree = el("span", &.{el("li", &.{x})}), .html = "<span><li>x</li></span>" },
        .{ .tree = el("output", &.{el("dd", &.{x})}), .html = "<output><dd>x</dd></output>" },
        .{ .tree = el("x-y", &.{el("p", &.{x})}), .html = "<x-y><p>x</p></x-y>" },
        .{ .tree = el("a", &.{el("p", &.{x})}), .html = "<a><p>x</p></a>" },
        .{ .tree = el("ul", &.{ el("li", &.{x}), el("li", &.{x}) }), .html = "<ul><li>x<li>x</ul>" },
        .{ .tree = el("dl", &.{ el("dt", &.{x}), el("dd", &.{x}) }), .html = "<dl><dt>x<dd>x</dl>" },
        .{ .tree = el("section", &.{ el("p", &.{x}), el("div", &.{}) }), .html = "<section><p>x<div></div></section>" },
        .{ .tree = el("div", &.{ el("p", &.{x}), el("span", &.{}) }), .html = "<div><p>x</p><span></span></div>" },
        .{ .tree = el("div", &.{ el("p", &.{x}), el("table", &.{}) }), .html = "<div><p>x</p><table></table></div>" },
        // Inside a `<select>` every end tag is written.
        .{ .tree = el("select", &.{ el("option", &.{x}), el("option", &.{x}) }), .html = "<select><option>x</option><option>x</option></select>" },
        .{ .tree = el("li", &.{el("p", &.{x})}), .html = "<li><p>x</li>" },
        .{ .tree = el("h2", &.{el("span", &.{el("p", &.{x})})}), .html = "<h2><span><p>x</p></span></h2>" },
        // An `<li>` or a `<dt>` stops its search for an open one at a `<dd>`
        // or an `<li>` still open: the parent keeps its end tag there.
        .{ .tree = el("ul", &.{ el("li", &.{el("dd", &.{x})}), el("li", &.{x}) }), .html = "<ul><li><dd>x</li><li>x</ul>" },
        .{ .tree = el("dl", &.{ el("dd", &.{el("li", &.{x})}), el("dt", &.{x}) }), .html = "<dl><dd><li>x</dd><dt>x</dt></dl>" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        try serialise(a, &out, &.{c.tree}, null, false);
        try t.expectEqualStrings(c.html, out.items);
    }
}

/// `s` with its first letter upper case, to open a sentence.
fn capital(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len != 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}
