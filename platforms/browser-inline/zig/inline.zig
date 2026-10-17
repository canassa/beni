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
    },
    .module = module,
    .root = root,
    .groups = true,
    .programs = &.{
        .{ .module = "Tea", .name = "sandbox" },
        .{ .module = "Tea", .name = "element" },
    },
    .program = program,
    .placements = &.{
        .{ .module = "Browser", .name = "mountAt", .places = .first },
    },
    .places = true,
    .constructs = true,
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

/// One node of the static markup, as `serialise` writes it.
const Html = struct {
    kind: enum { element, text },
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

/// One binding function: the writes of one set of read sets.
const Function = struct {
    groups: []const u32,
    writes: std.ArrayList(u32) = .empty,
    name: m.Name = undefined,
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
    /// The handlers by key, named when something first calls one.
    handlers: []?m.Name = &.{},
    /// Per key, the functions of the stateful controls its events are on.
    controls: []std.ArrayList(u32) = &.{},
    /// Per group, the functions that hold one of its writes; per function,
    /// the last key `passOf` took it for.
    by_group: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    stamp: []u32 = &.{},
    dispatch: ?m.Name = null,

    fn a(pg: *Page) std.mem.Allocator {
        return pg.cx.arena;
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
        for (children) |child| switch (tree.kind(child)) {
            .text => {
                const s = tree.string(tree.text(child).text);
                try parts.append(pg.a(), .{ .text = s });
                try baked.appendSlice(pg.a(), s);
            },
            else => {
                const h = tree.hole(child);
                const facts = pg.cx.programHole(.{ .node = child });
                if (facts.bake) |b| {
                    try parts.append(pg.a(), .{ .text = b });
                    try baked.appendSlice(pg.a(), b);
                } else {
                    all_baked = false;
                    try parts.append(pg.a(), .{ .value = h.value });
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
        try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), groups.items), .what = .{ .text = parts.items } });
        return &.{};
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
        const facts = cx.programHole(.{ .node = n });
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
        const facts = cx.programHole(.{ .item = index });
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
            if (s.fields > 1 or keys[s.handler].params != s.fields) return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
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
        const reads_model = pg.writes.items.len != 0 or pg.events.items.len != 0 or subs.len != 0 or runs;
        if (reads_model) try js.let(body, pg.model, if (element_) try js.member(init, "a") else init);
        if (pg.top_nodes.len == 1) {
            cx.at(view_node);
            var html: std.ArrayList(u8) = .empty;
            try serialise(pg.a(), &html, pg.top_nodes, null, true);
            try js.expression(body, try js.call(try js.member(try js.name(at), "insertAdjacentHTML"), &.{ try js.string("beforeend"), try js.string(html.items) }));
            pg.node = try cx.fresh("node");
            try js.constant(body, pg.node.?, try js.member(try js.name(at), "lastChild"));
            // Each piece registers what removes it as it is added, so a mount
            // that throws halfway leaves nothing `stop` cannot take back.
            const undo = try js.block();
            try js.expression(undo, try js.call(try js.member(try js.name(pg.node.?), "remove"), &.{}));
            try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{try js.arrow(&.{}, undo)}));
        }
        // The elements code refers to, by place.
        const placed = for (pg.writes.items) |w| {
            if (w.target != null) break true;
        } else for (pg.events.items) |ev| {
            if (ev.target != null) break true;
        } else false;
        if (placed) {
            pg.elements = try cx.fresh("elements");
            try js.constant(body, pg.elements.?, try js.call(try js.member(try js.name(pg.node.?), "querySelectorAll"), &.{try js.string("*")}));
        }

        // The binding functions, each written once and called once now.
        try pg.group();
        for (pg.functions.items) |*f| {
            const blk = try js.block();
            try pg.writeFunction(blk, f);
            f.name = try cx.fresh("bind");
            try js.constant(body, f.name, try js.arrow(&.{}, blk));
        }
        for (pg.functions.items) |f| try js.expression(body, try js.call(try js.name(f.name), &.{}));

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
        for (refs, 0..) |r, k| if (r != 0 and element_) {
            if (try pg.command(@intCast(k))) runs = true;
        };
        if (runs) {
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
            try pg.refuseKey();
            const params = try pg.a().alloc(m.Name, key.params);
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

    /// The language rule a key's handler is refused by (§8.7, class 3): an
    /// `update` computed when the page runs has no arm to write. A `*` key is
    /// compiled as S0 compiles it, every binding called, until the owner
    /// decides which the rule refuses (§8.7).
    fn refuseKey(pg: *Page) m.Error!void {
        const cx = pg.cx;
        if (pg.p.update == .computed) return cx.programReport(.update, .program_shape,
            \\This program's `update` is a value computed when the page runs, so `browser-inline`
            \\cannot write each message's arm into the handler of its key: a handler is the arm itself,
            \\with no message made (`docs/design/browser-inline.md` §8.7; §5, class 3). Name a function
            \\of the program's modules as `update`, or write a lambda whose body chooses the arm.
        );
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

    /// The element at `target`: the top node, or its descendant by place.
    fn ref(pg: *Page, target: ?u32) m.Error!m.Expr {
        const js = pg.cx.js;
        const t = target orelse return js.name(pg.node.?);
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
        try pg.cx.programViewEnter(blk, try pg.cx.js.name(pg.model));
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

    /// A binding function's body: per context its writes are in, the
    /// context entered, its values evaluated and each write made.
    fn writeFunction(pg: *Page, blk: m.Block, f: *const Function) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        var done: std.ArrayList(u32) = .empty;
        for (f.writes.items) |first| {
            const ctx = pg.writes.items[first].ctx;
            if (std.mem.indexOfScalar(u32, done.items, ctx) != null) continue;
            try done.append(pg.a(), ctx);
            const arms = try pg.enter(blk, ctx);
            var values: std.ArrayList(m.Value.Index) = .empty;
            for (f.writes.items) |wi| {
                const w = pg.writes.items[wi];
                if (w.ctx != ctx) continue;
                switch (w.what) {
                    .text => |parts| for (parts) |part| switch (part) {
                        .value => |v| try values.append(pg.a(), v),
                        else => {},
                    },
                    .prop => |x| try values.append(pg.a(), x.value),
                    .when => {},
                }
            }
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
                        try js.expression(blk, try js.call(try js.name(try cx.runtime("text")), &.{ node, value }));
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
        const message = try cx.programMessage(blk, v, payload);
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
        const next = try cx.programArm(k, blk, params, try js.name(incoming), update);
        var result = next;
        if (element_) {
            const pair = try cx.fresh("result");
            try js.constant(blk, pair, next);
            result = try js.name(pair);
        }
        try js.assign(blk, try js.name(pg.model), if (element_) try js.member(result, "a") else result);
        for (try pg.passOf(k, key.star)) |fi| try js.expression(blk, try js.call(try js.name(pg.functions.items[fi].name), &.{}));
        if (element_) switch (cx.programCommand(k)) {
            .runs => try js.expression(blk, try js.call(try js.name(try cx.runtime("commands")), &.{ try js.member(result, "b"), try js.name(pg.dispatch.?) })),
            else => {},
        };
    }

    /// Key `k`'s write pass (§8.3): the binding functions the key's writes
    /// reach — from the groups the pass says they conflict with, each
    /// function found by its groups — and those of the controls its events
    /// are on, each once, in document order. Every function for a `*` key,
    /// or for a program the pass does not know.
    fn passOf(pg: *Page, k: u32, star: bool) m.Error![]const u32 {
        const groups = pg.cx.programGroupsOf(k);
        if (star or groups == null) {
            const all = try pg.a().alloc(u32, pg.functions.items.len);
            for (all, 0..) |*x, i| x.* = @intCast(i);
            return all;
        }
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
        for (groups.?) |g| if (pg.by_group.get(g)) |fs| try add(pg, fs.items, k, &out);
        // A group the pass does not know is called by every key.
        if (pg.by_group.get(std.math.maxInt(u32))) |fs| try add(pg, fs.items, k, &out);
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
fn serialise(a: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Html, parent: ?[]const u8, at_end: bool) !void {
    for (nodes, 0..) |n, i| {
        const next: ?Html = if (i + 1 < nodes.len) nodes[i + 1] else null;
        switch (n.kind) {
            .text => try out.appendSlice(a, n.name),
            .element => {
                try out.append(a, '<');
                try out.appendSlice(a, n.name);
                try out.appendSlice(a, n.attributes);
                try out.append(a, '>');
                if (n.void) continue;
                const last = next == null and at_end;
                try serialise(a, out, n.children, n.name, last);
                if (last or optionalEnd(n.name, next, parent)) continue;
                try out.appendSlice(a, "</");
                try out.appendSlice(a, n.name);
                try out.append(a, '>');
            },
        }
    }
}

/// Whether element `name`'s end tag may be left out when `next` follows it
/// (null: its parent ends), in `parent` (null: unknown): the HTML
/// standard's optional end tags (§13.1.2.4), those whose rule needs no
/// look at whitespace or comments.
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
    const ends = next == null;
    if (eql(u8, name, "li")) return ends or nextIs(next, &.{"li"});
    if (eql(u8, name, "dt")) return nextIs(next, &.{ "dt", "dd" });
    if (eql(u8, name, "dd")) return ends or nextIs(next, &.{ "dt", "dd" });
    if (eql(u8, name, "rt") or eql(u8, name, "rp")) return ends or nextIs(next, &.{ "rt", "rp" });
    if (eql(u8, name, "option")) return ends or nextIs(next, &.{ "option", "optgroup", "hr" });
    if (eql(u8, name, "optgroup")) return ends or nextIs(next, &.{ "optgroup", "hr" });
    if (eql(u8, name, "td") or eql(u8, name, "th")) return ends or nextIs(next, &.{ "td", "th" });
    if (eql(u8, name, "tr")) return ends or nextIs(next, &.{"tr"});
    if (eql(u8, name, "thead")) return nextIs(next, &.{ "tbody", "tfoot" });
    if (eql(u8, name, "tbody")) return ends or nextIs(next, &.{ "tbody", "tfoot" });
    if (eql(u8, name, "tfoot")) return ends;
    if (eql(u8, name, "p")) {
        if (nextIs(next, &.{ "address", "article", "aside", "blockquote", "details", "dialog", "div", "dl", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "search", "section", "table", "ul" })) return true;
        if (!ends) return false;
        const p = parent orelse return false;
        for ([_][]const u8{ "a", "audio", "del", "ins", "map", "noscript", "video" }) |x| if (eql(u8, x, p)) return false;
        // A custom element's end does not close a `<p>`.
        return std.mem.indexOfScalar(u8, p, '-') == null;
    }
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
