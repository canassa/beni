//! The `inline` program lowering (docs/design/browser-inline.md): a program
//! of The Elm Architecture is compiled, not run, into the output tea-inline
//! writes (`../reactivity-research/frameworks/tea-inline/`). Where a program
//! constructor is called, the compiler hands this lowering the program, and
//! the lowering returns its **mount**, a function of the mount node that
//! `Inline.run` calls inside the dispatch guard:
//!
//!     (root) => {
//!       root.insertAdjacentHTML("beforeend", "<div data-role=\"dashboard\"></div>");
//!       const n = root.lastChild;
//!       own(() => { n.remove(); });
//!     }
//!
//! The view's static markup is one HTML string, written once after the
//! mount node's children; what the mount added is undone by the one
//! function it registers with `own`, which `stop` runs (`boundary.md`
//! §9.4.5, amended 2026-10-17). Everything this lowering cannot compile
//! exactly is a build error that names its class and what to write instead
//! (`browser-inline.md` §5) — never a fallback.

const std = @import("std");
const m = @import("beni_markup");
const parser = @import("platform_html").parser_table;

pub const lowering: m.Lowering = .{
    .name = "inline",
    .targets = .{ .major = 1, .minor = 14 },
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
    \\`browser-inline` has no markup value: markup is compiled only as a program's `view`,
    \\written in place (`docs/design/browser-inline.md` §5, class 1). Markup held, passed or
    \\returned by a helper is not supported on browser-inline yet: write it in place in the
    \\`view`, or build this program with `--platform=browser-tea`.
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

/// The class-1 refusal (`browser-inline.md` §5): a construct this platform
/// does not compile yet, and what to write instead.
fn later(cx: *m.Context, n: m.Node.Index, what: []const u8) m.Error {
    const message = std.fmt.allocPrint(cx.arena,
        \\`browser-inline` does not compile {s}: not supported on browser-inline yet
        \\(`docs/design/browser-inline.md` §5, class 1). Write the `view` without it, or build this
        \\program with `--platform=browser-tea`, which compiles it.
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
            \\`browser-inline` compiles a `view` whose body is markup written in place, and this
            \\one's computes its markup, or has `let`s: not supported on browser-inline yet
            \\(`docs/design/browser-inline.md` §5, class 1). Write the markup in place as the body of
            \\`view`, or build this program with `--platform=browser-tea`.
        ),
        .other_module => return cx.programReport(.view, .not_implemented,
            \\`browser-inline` compiles a `view` declared in the module that calls the program's
            \\constructor, and this one is another module's: not supported on browser-inline yet
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
    try page.markup(r.node, .{}, &.{});
    return page.mount(r.node);
}

/// The view's one text binding: a text hole that
/// is its element's only child, the path to its element from the view's top
/// element, child by child.
const Binding = struct {
    node: m.Node.Index,
    value: m.Value.Index,
    path: []const u32,
    group: u32,
};

/// One program's page, as the lowering builds it.
const Page = struct {
    cx: *m.Context,
    tree: *const m.Tree,
    p: *const m.Program,
    index: m.Root.Index,
    /// The view's static markup.
    html: std.ArrayList(u8) = .empty,
    /// The top-level nodes the markup makes.
    top: u32 = 0,
    binding: ?Binding = null,
    /// The mount's body, the model's name, and the handlers by key.
    body: m.Block = undefined,
    model: m.Name = undefined,
    handlers: []?m.Name = &.{},
    dispatch: ?m.Name = null,
    slot: m.Name = undefined,
    text: m.Name = undefined,

    fn a(pg: *Page) std.mem.Allocator {
        return pg.cx.arena;
    }

    /// Serialise a node of the view into `html`, refusing what S0 does not
    /// compile. `path` is the child indices from the top element to `n`'s
    /// parent.
    fn markup(pg: *Page, n: m.Node.Index, scope: parser.Scope, path: []const u32) m.Error!void {
        const tree = pg.tree;
        pg.cx.at(n);
        switch (tree.kind(n)) {
            .fragment => {
                for (tree.childrenOf(tree.fragment(n).children)) |child| try pg.markup(child, scope, path);
            },
            .element => {
                const e = tree.element(n);
                const facts = tree.elementFacts(e.row);
                const name = tree.string(facts.name);
                if (facts.namespace != .html) return later(pg.cx, n, "an element of the SVG or MathML namespace");
                if (parser.misnested(scope, name)) |why| return pg.cx.report(n, why);
                if (scope.parent == null) pg.top += 1;
                try pg.html.append(pg.a(), '<');
                try pg.html.appendSlice(pg.a(), name);
                for (tree.itemsOf(e.items)) |it| try pg.attribute(n, it);
                try pg.html.append(pg.a(), '>');
                if (facts.void) return;
                const inner = scope.enter(name);
                const children = tree.childrenOf(e.children);
                if (parser.content(name) != .normal and children.len != 0) return later(pg.cx, n, "the content of an element whose content the parser reads as text");
                for (children, 0..) |child, i| {
                    if (tree.kind(child) == .hole) {
                        if (children.len != 1) return later(pg.cx, child, "a hole beside other children of its element");
                        try pg.hole(child, path);
                        continue;
                    }
                    const below = try std.mem.concat(pg.a(), u32, &.{ path, &.{@intCast(i)} });
                    try pg.markup(child, inner, below);
                }
                try pg.html.appendSlice(pg.a(), "</");
                try pg.html.appendSlice(pg.a(), name);
                try pg.html.append(pg.a(), '>');
            },
            .text => {
                if (parser.movesText(scope.parent)) return pg.cx.report(n, "the parser moves text written here out of the table");
                if (scope.parent == null) pg.top += 1;
                try escapeText(pg.a(), &pg.html, tree.string(tree.text(n).text));
            },
            .hole => return later(pg.cx, n, "a hole outside an element"),
            .component => return later(pg.cx, n, "a component"),
            .for_ => return later(pg.cx, n, "a `For`"),
            .show => return later(pg.cx, n, "a `Show`"),
            else => return later(pg.cx, n, "this markup"),
        }
    }

    /// A text hole, the only child of its element: baked into the markup
    /// when it never changes and `init` gives its text, or the view's one
    /// text binding. The binding's text node is a space in the markup.
    fn hole(pg: *Page, n: m.Node.Index, path: []const u32) m.Error!void {
        const h = pg.tree.hole(n);
        switch (h.kind) {
            .text_string, .text_number => {},
            else => return later(pg.cx, n, "a hole that is not text of a `String` or a number"),
        }
        const facts = pg.cx.programHole(.{ .node = n });
        if (facts.bake) |text| {
            try escapeText(pg.a(), &pg.html, text);
            return;
        }
        if (pg.binding != null) return later(pg.cx, n, "a second text binding");
        pg.binding = .{ .node = n, .value = h.value, .path = path, .group = facts.group };
        try pg.html.append(pg.a(), ' ');
    }

    /// A constant attribute, written into the markup; anything that needs
    /// code is refused.
    fn attribute(pg: *Page, n: m.Node.Index, it: m.Item) m.Error!void {
        const tree = pg.tree;
        switch (it.kind) {
            .attribute => {},
            .event => return later(pg.cx, n, "an event"),
            else => return later(pg.cx, n, "an escape attribute"),
        }
        if (it.attribute != .none) {
            const facts = tree.attributeFacts(it.attribute);
            if (facts.property != null or facts.raw or facts.classes or facts.styles or facts.stateful)
                return later(pg.cx, n, "an attribute written through a property, raw HTML, or a class or style list");
        }
        if (it.url) return later(pg.cx, n, "an attribute that holds a URL");
        if (it.value.kind != .constant) return later(pg.cx, n, "an attribute whose value is not a constant");
        const name = tree.string(it.name);
        const c = it.value.constant;
        switch (c.kind) {
            .string, .number => {
                try pg.html.append(pg.a(), ' ');
                try pg.html.appendSlice(pg.a(), name);
                try pg.html.appendSlice(pg.a(), "=\"");
                try escapeAttribute(pg.a(), &pg.html, tree.string(c.text));
                try pg.html.append(pg.a(), '"');
            },
            .bool => if (c.bool) {
                try pg.html.append(pg.a(), ' ');
                try pg.html.appendSlice(pg.a(), name);
            },
            .none => {
                try pg.html.append(pg.a(), ' ');
                try pg.html.appendSlice(pg.a(), name);
            },
            else => return later(pg.cx, n, "this attribute's value"),
        }
    }

    /// The mount (`browser-inline.md` §3–§4): the element found, `init`
    /// evaluated (a release build drops it when nothing reads it and it has
    /// no effect), the markup written once after the element's children and
    /// the binding's first text, each subscription started, `init`'s
    /// command queued, and what undoes the mount registered.
    fn mount(pg: *Page, view_node: m.Node.Index) m.Error!m.Expr {
        const cx = pg.cx;
        const js = cx.js;
        if (pg.top > 1) return later(cx, view_node, "a `view` of more than one top-level node");
        const element_ = pg.p.constructor == 1;
        const keys = cx.programKeys();

        // What the program's subscriptions and commands are, refused first.
        var subs: []const m.Program.Subscription = &.{};
        if (element_) {
            switch (cx.programSubscriptions()) {
                .set => |s| subs = s,
                .model => return cx.programReport(.call, .not_implemented,
                    \\This program's subscriptions depend on its model, and `browser-inline` compiles a
                    \\set of subscriptions that is the same for the page's life: a set that changes is not
                    \\supported on browser-inline yet (`docs/design/browser-inline.md` §3; §5, class 3). Write `subscriptions` so that
                    \\it does not read the model, and let `update` ignore what it does not need.
                ),
                .no_key => |where| return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
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
        var reached = try pg.a().alloc(bool, keys.len);
        @memset(reached, false);
        for (subs) |s| {
            if (s.handler >= keys.len) return cx.programReport(.call, .not_implemented, "A limit of the compiler: a subscription's key has no handler.");
            if (s.fields > 1 or keys[s.handler].params != s.fields) return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\`browser-inline` does not compile the subscription at {s} yet: its message's
                \\constructor takes the value in more than one field, which is not supported on
                \\browser-inline yet (`docs/design/browser-inline.md` §5, class 1). Give the constructor
                \\one field for the value.
            , .{s.where}));
            reached[s.handler] = true;
        }
        // A command that runs sends messages of any key: every key is then
        // reached, through the dispatcher.
        var runs = element_ and try pg.command(null);
        for (reached, 0..) |r, k| if (r and element_) {
            if (try pg.command(@intCast(k))) runs = true;
        };
        if (runs) for (reached, 0..) |*r, k| {
            if (!r.* and element_) _ = try pg.command(@intCast(k));
            r.* = true;
        };

        pg.body = try js.block();
        const body = pg.body;
        const id = try cx.fresh("id");
        const at = try cx.fresh("root");
        // The element: the one a placement written at the call names, the
        // page's body for `main` itself, or the one the program value is
        // handed. A constant argument is one a release build folds into
        // `root`.
        const which = switch (pg.p.placed) {
            .at => |text| try js.string(text),
            .body => try js.literal(.undefined),
            else => try js.name(id),
        };
        try js.constant(body, at, try js.call(try js.name(try cx.runtime("root")), &.{which}));
        const init = try cx.programInit(body);
        // The model, kept only when something reads it.
        pg.model = try cx.fresh("model");
        if (pg.binding != null or std.mem.indexOfScalar(bool, reached, true) != null) try js.let(body, pg.model, if (element_) try js.member(init, "a") else init);
        var node: ?m.Name = null;
        if (pg.top == 1) {
            cx.at(view_node);
            try js.expression(body, try js.call(try js.member(try js.name(at), "insertAdjacentHTML"), &.{ try js.string("beforeend"), try js.string(pg.html.items) }));
            node = try cx.fresh("node");
            try js.constant(body, node.?, try js.member(try js.name(at), "lastChild"));
            // Each piece registers what removes it as it is added, so a mount
            // that throws halfway leaves nothing `stop` cannot take back.
            const undo = try js.block();
            try js.expression(undo, try js.call(try js.member(try js.name(node.?), "remove"), &.{}));
            try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{try js.arrow(&.{}, undo)}));
        }
        // The binding's text node, and its first text.
        if (pg.binding) |b| {
            var e = try js.name(node.?);
            for (b.path) |i| e = if (i == 0) try js.member(e, "firstChild") else try js.index(try js.member(e, "childNodes"), try js.number(try std.fmt.allocPrint(cx.arena, "{d}", .{i})));
            pg.text = try cx.fresh("text");
            try js.constant(body, pg.text, try js.member(e, "firstChild"));
            pg.slot = try cx.fresh("shown");
            try js.let(body, pg.slot, null);
            try pg.write(body, false);
        }

        // One handler per key reached: its arm writes the model, then the
        // write pass runs the binding where the key's writes reach it, then
        // its command is queued.
        pg.handlers = try pg.a().alloc(?m.Name, keys.len);
        @memset(pg.handlers, null);
        if (runs) pg.dispatch = try cx.fresh("dispatch");
        const update = if (std.mem.indexOfScalar(bool, reached, true) != null) try cx.programUpdate(body) else null;
        for (keys, 0..) |key, k| {
            if (!reached[k]) continue;
            const params = try pg.a().alloc(m.Name, key.params);
            for (params) |*x| x.* = try cx.fresh("value");
            const blk = try js.block();
            const incoming = try cx.fresh("before");
            try js.constant(blk, incoming, try js.name(pg.model));
            const next = try cx.programArm(@intCast(k), blk, params, try js.name(incoming), update);
            var result = next;
            if (element_) {
                const pair = try cx.fresh("result");
                try js.constant(blk, pair, next);
                result = try js.name(pair);
            }
            try js.assign(blk, try js.name(pg.model), if (element_) try js.member(result, "a") else result);
            if (pg.binding) |b| if (key.star or cx.programCalls(@intCast(k), b.group)) try pg.write(blk, true);
            if (element_) switch (cx.programCommand(@intCast(k))) {
                .runs => try js.expression(blk, try js.call(try js.name(try cx.runtime("commands")), &.{ try js.member(result, "b"), try js.name(pg.dispatch.?) })),
                else => {},
            };
            const h = try cx.fresh(try std.fmt.allocPrint(cx.arena, "on{s}", .{handlerHint(key.name)}));
            try js.constant(body, h, try js.arrow(params, blk));
            pg.handlers[k] = h;
        }
        if (pg.dispatch) |d| {
            const msg = try cx.fresh("msg");
            const blk = try js.block();
            const all = try pg.a().alloc(m.Name, keys.len);
            for (all, pg.handlers) |*x, h| x.* = h.?;
            try cx.programDispatch(blk, try js.name(msg), all);
            try js.constant(body, d, try js.arrow(&.{msg}, blk));
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
                const arg = if (t.fields == 0) try js.literal(.undefined) else try js.name(v);
                try js.expression(sends, try js.call(try js.name(try cx.runtime("send")), &.{ try js.name(pg.handlers[t.handler].?), arg }));
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

    /// Whether key `key`'s command — or `init`'s, for null — runs; one that
    /// may suspend, or that the pass could not read, is refused.
    fn command(pg: *Page, key: ?u32) m.Error!bool {
        const cx = pg.cx;
        switch (cx.programCommand(key)) {
            .none => return false,
            .runs => return true,
            .suspends => |where| return cx.programReport(if (key == null) .init else .update, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\The command whose body is at {s} may suspend, and a body that suspends needs the task
                \\kernel, which is not supported on browser-inline yet (`docs/design/browser-inline.md` §4;
                \\§5, class 2).
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

    /// The binding's write: its value, from the model; then, when it
    /// differs from the text shown — at the mount, always — the text node
    /// written.
    fn write(pg: *Page, blk: m.Block, compare: bool) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const b = pg.binding.?;
        try cx.programViewEnter(blk, try js.name(pg.model));
        try cx.rootValues(blk, pg.index, &.{b.value});
        const shown = try cx.fresh("t");
        try js.constant(blk, shown, try cx.value(b.value));
        cx.programViewLeave();
        const then = try js.block();
        try js.assign(then, try js.name(pg.slot), try js.name(shown));
        try js.assign(then, try js.member(try js.name(pg.text), "data"), try js.name(shown));
        if (compare)
            try js.@"if"(blk, try js.binary(.strict_ne, try js.name(shown), try js.name(pg.slot)), then, null)
        else
            try js.nested(blk, then);
    }
};

/// A handler's name hint from its key's name: its letters and digits.
fn handlerHint(key: []const u8) []const u8 {
    var end: usize = 0;
    while (end < key.len and std.ascii.isAlphanumeric(key[end])) end += 1;
    return if (end == 0) "Key" else key[0..end];
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
