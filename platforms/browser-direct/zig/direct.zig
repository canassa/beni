//! The `direct` program lowering (docs/design/browser-direct.md): a program
//! of The Elm Architecture is compiled, not run. Where a program constructor
//! is called, the compiler hands this lowering the program — its record's
//! shapes, its `view`'s markup, its message keys and what the write-set pass
//! found (`boundary.md` §9.4.6, versions 1.6 and 1.7) — and the lowering
//! returns the program's **mount**, a function of the mount node and a
//! `template` element that `Direct.run` calls inside the dispatch guard.
//!
//! Slice S1 (§14) compiles `Tea.sandbox` whose `view` is markup with text
//! and attribute holes and view events. The mount holds the program's whole
//! state in its own scope — the model, the page's nodes, a slot per hole —
//! so each mount of a program is its own (§8.2), and a slot read is a
//! context-slot load as a module-level variable's is (§5.2):
//!
//!     (root, t) => {
//!       const init = …; let model = init;
//!       t.innerHTML = "<p> </p><button>+</button>";
//!       const r = t.content, w0 = r.firstChild, …;
//!       let s0 = unset;                                   // one per hole (§5.3)
//!       const g0 = () => { const v = …model…; if (v !== s0) { s0 = v; w1.data = v; } };
//!       const h0 = () => { model = { ...model, n: model.n + 1 }; g0(); };   // one per key (§4.1)
//!       const l0 = (e) => { h0(); };                      // the listener body (§4.2)
//!       w2.addEventListener("click", (e) => { send(l0, e); });
//!       g0();                                             // the mount writes every hole
//!       root.append(r);
//!     }
//!
//! A hole no key's write set conflicts with is written at mount and never
//! again, and one whose text `init` gives is that text in the template
//! (§5.1, `write-sets.md` §9.1). Each handler runs its key's arm and calls
//! the groups its write set conflicts with, each guarded by one compare
//! (§4.1, §5.3); a `*` key calls them all (`patchAll`). Writes happen as the
//! handler runs: there is no render loop (§4.3, Q2). A development build
//! checks the whole page against the model after every dispatch (§8.3).
//!
//! Everything a later slice adds is refused at build time, naming that
//! slice — never a silent miscompile.

const std = @import("std");
const m = @import("beni_markup");
const dom = @import("platform_browser").dom;

pub const lowering: m.Lowering = .{
    .name = "direct",
    .targets = .{ .major = 1, .minor = 7 },
    .runtime = &.{
        // `(f, x)`: the dispatch guard (§4.3), which a listener body, the
        // dispatcher and the mount enter program code through.
        .{ .name = "send", .arity = 2 },
        // The sentinel every slot starts at (§5.3).
        .{ .name = "unset", .arity = 0 },
        // The writes `backend.md` §15.3's table names, as `browser`'s `Rt`
        // makes them.
        .{ .name = "insertText", .arity = 3 },
        .{ .name = "attr", .arity = 3 },
        .{ .name = "attrNS", .arity = 4 },
        .{ .name = "safeUrl", .arity = 1 },
        .{ .name = "rawHtml", .arity = 2 },
        .{ .name = "classes", .arity = 3 },
        .{ .name = "styles", .arity = 3 },
        // The payload of an event whose handler takes the event itself.
        .{ .name = "identity", .arity = 1 },
        // The development verify mode (§8.3): a program's check, the
        // structural comparison it makes, and the defect it throws.
        .{ .name = "verify", .arity = 1 },
        .{ .name = "same", .arity = 2 },
        .{ .name = "wrong", .arity = 3 },
    },
    .module = module,
    .root = root,
    // The view's values are evaluated by the code this lowering writes, in
    // its groups, its listeners and its check (version 1.5's grouped root).
    .groups = true,
    .programs = &.{
        .{ .module = "Tea", .name = "sandbox" },
        .{ .module = "Tea", .name = "element" },
        .{ .module = "Tea", .name = "document" },
        .{ .module = "Tea", .name = "application" },
        .{ .module = "Browser", .name = "program", .refused = refused_program },
        .{ .module = "Browser", .name = "hosted", .refused = refused_hosted },
    },
    .program = program,
    .placements = &.{
        .{ .module = "Browser", .name = "programs", .places = .list },
        .{ .module = "Browser", .name = "mountAt", .places = .first },
    },
    .no_markup_values = no_markup_values,
};

const until_then = "Build this program with `--platform=browser-tea` until then.";

const no_markup_values =
    \\`browser-direct` does not compile markup as a value yet — markup that is not the
    \\`view` a program constructor is called with (held, passed or returned by another
    \\function, or a `view` that is `pub` or used elsewhere), `Html.text` and `Html.map` —
    \\it arrives with slice S4 (`docs/design/browser-direct.md` §5.2, §14).
++ " " ++ until_then;

const refused_program =
    \\`Browser.program` is `browser`'s own program, which `browser-direct` does not run:
    \\this platform compiles The Elm Architecture itself (`docs/design/browser-direct.md`
    \\§15, Q6). Write `Tea.sandbox` with the same record.
;

const refused_hosted =
    \\`Browser.hosted` is the low-level form `browser-tea` is written over, which
    \\`browser-direct` does not run: this platform compiles The Elm Architecture itself
    \\(`docs/design/browser-direct.md` §15, Q6). Write `Tea.element`, which arrives with
    \\slice S5 (§14).
;

/// Nothing is hoisted: a program's mount is written where it is called.
fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}

/// Never called: the compiler refuses a markup root that is a value under
/// this lowering (`no_markup_values`) before it would be.
fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    _ = tree;
    _ = index;
    return cx.js.literal(.undefined);
}

/// The program hook: the mount of a `Tea.sandbox`.
fn program(cx: *m.Context, tree: *const m.Tree, p: *const m.Program) m.Error!m.Expr {
    switch (p.constructor) {
        0 => {},
        else => return cx.programReport(.call, .not_implemented,
            \\`browser-direct` does not compile `Tea.element`, `Tea.document` or
            \\`Tea.application` yet: programs with effects arrive with slice S5
            \\(`docs/design/browser-direct.md` §10, §14).
        ++ " " ++ until_then),
    }
    if (!p.record) return cx.programReport(.call, .view_not_compiled,
        \\This program's record is a value computed when the page runs, so its `view` is
        \\too, and `browser-direct` cannot compile it: the platform has no renderer to hand
        \\a `view` it did not compile (`docs/design/browser-direct.md` §11.1). Write the
        \\record where `Tea.sandbox` is called, or as a top-level value; or build for
        \\`--platform=browser-tea`, which renders any `view`.
    );
    switch (p.view) {
        .markup => {},
        .function => return cx.programReport(.view, .not_implemented,
            \\`browser-direct` compiles a `view` whose body is markup written in place, and this
            \\one's is not; a `view` whose body computes its markup — a `let`, an `if`, a
            \\`case`, a helper's call — arrives with slices S3 and S4
            \\(`docs/design/browser-direct.md` §5.4, §5.5, §9.2, §14).
        ++ " " ++ until_then),
        .other_module => return cx.programReport(.view, .not_implemented,
            \\`browser-direct` compiles a `view` declared in the module that calls `Tea.sandbox`,
            \\and this one is another module's; markup of another module arrives with slice S3
            \\(`docs/design/browser-direct.md` §9.2, §14).
        ++ " " ++ until_then),
        else => return cx.programReport(.view, .view_not_compiled,
            \\This program's `view` is a value computed when the page runs, not a function
            \\whose body the compiler can reach as markup, so `browser-direct` cannot compile
            \\it: the platform has no renderer to hand a `view` it did not compile
            \\(`docs/design/browser-direct.md` §11.1). Name a function, or write a lambda,
            \\whose body is the markup; or build for `--platform=browser-tea`, which renders
            \\any `view`.
        ),
    }
    const index = p.view_root.?;
    const r = tree.root(index);
    try supported(cx, tree, r.node);
    if (!cx.grouped(index)) return cx.notImplemented(r.node,
        \\`browser-direct` compiles a `view` whose values can be evaluated outside it, and
        \\this one's cannot (a `?`, or a function that takes evidence); that arrives with a
        \\later slice (`docs/design/browser-direct.md` §14).
    ++ " " ++ until_then);
    var g: dom.Gen = .{ .cx = cx, .tree = tree, .direct = true, .bake = bakeOf };
    var b = try g.plan(&.{r.node}, r.site.inst);
    // A root element in the SVG or MathML namespace that is not that
    // namespace's own root is parsed inside a wrapper the mount would take
    // off (`dom`'s flag 2); no vocabulary that ships reaches it.
    if (b.flags & 2 != 0) return cx.notImplemented(r.node,
        \\`browser-direct` does not compile a `view` whose root is an SVG or MathML element
        \\other than `<svg>` or `<math>` yet: it arrives with slice S4
        \\(`docs/design/browser-direct.md` §14).
    ++ " " ++ until_then);
    if (b.ops.items.len == 0 and !anyBaked(cx, tree, r.node)) return staticMount(cx, tree, r.node, b.html.items, b.flags);
    var page: Page = .{ .cx = cx, .tree = tree, .g = &g, .b = &b, .index = index, .node = r.node };
    return page.mount();
}

/// The text a hole is baked as (§5.1): a text hole the program never
/// writes whose value is a plain string `init` gives.
fn bakeOf(cx: *m.Context, n: m.Node.Index) ?[]const u8 {
    return cx.programHole(.{ .node = n }).bake;
}

fn anyBaked(cx: *m.Context, tree: *const m.Tree, n: m.Node.Index) bool {
    switch (tree.kind(n)) {
        .element => for (tree.childrenOf(tree.element(n).children)) |c| {
            if (anyBaked(cx, tree, c)) return true;
        },
        .fragment => for (tree.childrenOf(tree.fragment(n).children)) |c| {
            if (anyBaked(cx, tree, c)) return true;
        },
        .hole => return tree.hole(n).kind == .text_string and bakeOf(cx, n) != null,
        else => {},
    }
    return false;
}

/// A `view` that writes nothing after it is parsed — no hole, no event, no
/// attribute but a constant one the template holds — as slice S0 wrote it:
/// `init` evaluated inside the guard, then the page written once (§5.1).
/// Markup with no nodes writes nothing.
fn staticMount(cx: *m.Context, tree: *const m.Tree, node: m.Node.Index, html: []const u8, flags: u8) m.Error!m.Expr {
    const js = cx.js;
    const at = try cx.fresh("root");
    const t = try cx.fresh("t");
    const body = try js.block();
    _ = try cx.programInit(body);
    if (!(tree.kind(node) == .fragment and tree.fragment(node).children.len == 0)) {
        cx.at(node);
        try js.assign(body, try js.member(try js.name(t), "innerHTML"), try js.string(html));
        try js.expression(body, try js.call(try js.member(try js.name(at), "append"), &.{try content(cx, t, flags)}));
    }
    return js.arrow(&.{ at, t }, body);
}

/// What the template element's content is taken as: adopted, or — for a
/// custom element, an `is`, a lazy `<img>` or `<iframe>` (`dom`'s flag 1) —
/// imported into the page's document, as `browser`'s `Rt.template` imports
/// it, so the page upgrades or loads them.
fn content(cx: *m.Context, t: m.Name, flags: u8) m.Error!m.Expr {
    const js = cx.js;
    const c = try js.member(try js.name(t), "content");
    if (flags & 1 == 0) return c;
    return js.call(try js.member(try js.member(try js.name(t), "ownerDocument"), "importNode"), &.{ c, try js.literal(.true) });
}

/// Refuse the first thing in the markup that a later slice compiles,
/// naming that slice.
fn supported(cx: *m.Context, tree: *const m.Tree, n: m.Node.Index) m.Error!void {
    switch (tree.kind(n)) {
        .element => {
            const e = tree.element(n);
            for (tree.itemsOf(e.items)) |it| switch (it.kind) {
                .event => {},
                .attribute, .escape => if (it.kind == .attribute and it.attribute != .none and tree.attributeFacts(it.attribute).stateful) {
                    return refuse(cx, n, "a controlled attribute (`value`, `checked`, `selected`)", "S4", "§8.1");
                },
                else => return refuse(cx, n, "this attribute", "S4", "§5"),
            };
            for (tree.childrenOf(e.children)) |c| try supported(cx, tree, c);
        },
        .fragment => for (tree.childrenOf(tree.fragment(n).children)) |c| try supported(cx, tree, c),
        .text => {},
        .hole => switch (tree.hole(n).kind) {
            .text_string, .text_number, .text_char, .text_bool => {},
            else => return refuse(cx, n, "a hole that shows markup (a helper's, `Html.text`, a `Maybe Html` or a `List Html`)", "S4", "§5.2"),
        },
        .component => return refuse(cx, n, "a component", "S3", "§9.2"),
        .for_ => return refuse(cx, n, "a `For`", "S2", "§6"),
        .show => return refuse(cx, n, "a `Show`", "S4", "§5.5"),
        else => return refuse(cx, n, "this markup", "S4", "§5"),
    }
}

fn refuse(cx: *m.Context, n: m.Node.Index, what: []const u8, slice: []const u8, section: []const u8) m.Error!void {
    const message = try std.fmt.allocPrint(cx.arena, "`browser-direct` does not compile {s} yet: it arrives with slice {s} (`docs/design/browser-direct.md` {s}, §14). {s}", .{ what, slice, section, until_then });
    return cx.notImplemented(n, message);
}

/// One group of the page's writes (§5.3): the ops that share a read set,
/// merged so that an element's attributes are written in source order.
const Group = struct {
    /// Its ops, in source order.
    ops: std.ArrayList(u32) = .empty,
    /// No key ever calls it: written at mount, never again (§5.1).
    static: bool,
    /// Evaluates a value that may have an effect (`Random.value`): every
    /// handler calls it (§5.3).
    every: bool,
    /// The read sets of its ops (`Program.HoleFacts.group`).
    sets: std.ArrayList(u32) = .empty,
    /// The function a handler calls.
    name: ?m.Name = null,
};

/// The mount of one program whose `view` writes something.
const Page = struct {
    cx: *m.Context,
    tree: *const m.Tree,
    g: *dom.Gen,
    b: *dom.Body,
    index: m.Root.Index,
    node: m.Node.Index,

    body: m.Block = undefined,
    model: m.Name = undefined,
    frag: m.Name = undefined,
    walks: []?m.Name = &.{},
    texts: []?m.Name = &.{},
    slots: []?m.Name = &.{},
    facts: []m.Program.HoleFacts = &.{},
    groups: std.ArrayList(Group) = .empty,
    group_of: []u32 = &.{},
    dispatch: ?m.Name = null,

    fn a(pg: *Page) std.mem.Allocator {
        return pg.cx.arena;
    }

    fn jsb(pg: *Page) m.Js {
        return pg.cx.js;
    }

    fn ident(pg: *Page, n: m.Name) m.Error!m.Expr {
        return pg.jsb().name(n);
    }

    fn rt(pg: *Page, name: []const u8, args: []const m.Expr) m.Error!m.Expr {
        return pg.jsb().call(try pg.jsb().name(try pg.cx.runtime(name)), args);
    }

    fn ops(pg: *Page) []const dom.Op {
        return pg.b.ops.items;
    }

    fn mount(pg: *Page) m.Error!m.Expr {
        const cx = pg.cx;
        const js = pg.jsb();
        const at = try cx.fresh("$root");
        const t = try cx.fresh("$t");
        pg.body = try js.block();

        // The model, which every handler replaces (§4.1).
        const init = try cx.programInit(pg.body);
        pg.model = try cx.fresh("$model");
        try js.let(pg.body, pg.model, init);
        const update = try cx.programUpdate(pg.body);

        // The page, parsed once, and its dynamic nodes reached once (§5.1).
        cx.at(pg.node);
        try js.assign(pg.body, try js.member(try pg.ident(t), "innerHTML"), try js.string(pg.b.html.items));
        pg.frag = try cx.fresh("$r");
        try js.constant(pg.body, pg.frag, try content(cx, t, pg.b.flags));
        try pg.writeWalks();
        try pg.makeGroups();
        try pg.writeSlots();
        for (pg.groups.items) |*gr| if (!gr.static) {
            gr.name = try cx.fresh("$g");
            try js.constant(pg.body, gr.name.?, try pg.groupFunction(gr));
        };

        // `patchAll`, for a key that may change everything (§4.1).
        const keys = cx.programKeys();
        var all: ?m.Name = null;
        for (keys) |key| if (key.star) {
            const blk = try js.block();
            for (pg.groups.items) |gr| if (gr.name) |n| try js.expression(blk, try js.call(try pg.ident(n), &.{}));
            all = try cx.fresh("$patchAll");
            try js.constant(pg.body, all.?, try js.arrow(&.{}, blk));
            break;
        };

        // One handler per key (§4.1): its arm, then the groups its write set
        // conflicts with, each guarded by its own compare.
        const handlers = try pg.a().alloc(m.Name, keys.len);
        for (keys, handlers, 0..) |key, *h, k| {
            const params = try pg.a().alloc(m.Name, key.params);
            for (params) |*x| x.* = try cx.fresh("$p");
            const blk = try js.block();
            const next = try cx.programArm(@intCast(k), blk, params, try pg.ident(pg.model), update);
            try js.assign(blk, try pg.ident(pg.model), next);
            if (key.star) {
                try js.expression(blk, try js.call(try pg.ident(all.?), &.{}));
            } else for (pg.groups.items) |gr| {
                const name = gr.name orelse continue;
                if (gr.every or pg.calls(gr, @intCast(k))) try js.expression(blk, try js.call(try pg.ident(name), &.{}));
            }
            h.* = try cx.fresh(try handlerHint(pg.a(), key.name));
            try js.constant(pg.body, h.*, try js.arrow(params, blk));
        }

        // The listeners, into a block of their own so the dispatcher, which
        // only some of them need, is declared before them.
        const listeners = try js.block();
        for (pg.ops(), 0..) |op, k| switch (op.what) {
            .event => |x| try pg.listener(listeners, x, @intCast(k), handlers),
            else => {},
        };
        if (cx.build.fuzz and pg.dispatch == null) pg.dispatch = try cx.fresh("$dispatch");
        if (pg.dispatch) |d| {
            const msg = try cx.fresh("$msg");
            const blk = try js.block();
            try cx.programDispatch(blk, try pg.ident(msg), handlers);
            try js.constant(pg.body, d, try js.arrow(&.{msg}, blk));
        }
        try js.nested(pg.body, listeners);

        // The mount: every group once, in the order of its first write, a
        // group no key calls written in place (§5.1).
        for (pg.groups.items) |*gr| {
            if (gr.name) |n| {
                try js.expression(pg.body, try js.call(try pg.ident(n), &.{}));
            } else {
                const blk = try js.block();
                try pg.groupBody(blk, gr, true);
                try js.nested(pg.body, blk);
            }
        }
        try js.expression(pg.body, try js.call(try js.member(try pg.ident(at), "append"), &.{try pg.ident(pg.frag)}));

        if (!cx.build.release) try pg.writeVerify();
        // `--fuzz` (§8.3): the mount node applies a message value, as
        // `browser-tea`'s does.
        if (cx.build.fuzz) {
            const msg = try cx.fresh("$msg");
            const blk = try js.block();
            try js.expression(blk, try pg.rt("send", &.{ try pg.ident(pg.dispatch.?), try pg.ident(msg) }));
            try js.assign(pg.body, try js.member(try pg.ident(at), "$$root"), try js.arrow(&.{msg}, blk));
        }
        return js.arrow(&.{ at, t }, pg.body);
    }

    /// Whether key `k` writes something one of the group's read sets reads.
    fn calls(pg: *Page, gr: Group, k: u32) bool {
        for (gr.sets.items) |set| if (pg.cx.programCalls(k, set)) return true;
        return false;
    }

    /// Every needed node of the template, reached from the parsed content
    /// before anything is written (`dom`'s walks, `dom/template.rs`), and a
    /// text hole's node made where it goes.
    fn writeWalks(pg: *Page) m.Error!void {
        const js = pg.jsb();
        const tnodes = pg.b.tnodes.items;
        pg.walks = try pg.a().alloc(?m.Name, tnodes.len);
        @memset(pg.walks, null);
        const last_in = try pg.a().alloc(?u32, tnodes.len + 1);
        @memset(last_in, null);
        for (tnodes, 0..) |tn, i| {
            if (!tn.needed) continue;
            const group = tn.parent orelse tnodes.len;
            var e: m.Expr = undefined;
            var steps: u32 = undefined;
            if (last_in[group]) |prev| {
                e = try pg.ident(pg.walks[prev].?);
                steps = tn.index - tnodes[prev].index;
            } else {
                const base = if (tn.parent) |p| pg.walks[p].? else pg.frag;
                e = try js.member(try pg.ident(base), "firstChild");
                steps = tn.index;
            }
            for (0..steps) |_| e = try js.member(e, "nextSibling");
            const w = try pg.cx.fresh("$w");
            try js.constant(pg.body, w, e);
            pg.walks[i] = w;
            last_in[group] = @intCast(i);
        }
        pg.texts = try pg.a().alloc(?m.Name, pg.ops().len);
        @memset(pg.texts, null);
        for (pg.ops(), 0..) |op, k| switch (op.what) {
            .text => |x| {
                pg.cx.at(op.node);
                const parent = if (x.at.parent) |p| try pg.ident(pg.walks[p].?) else try pg.ident(pg.frag);
                const marker = switch (x.at.marker) {
                    .node => |mk| try pg.ident(pg.walks[mk].?),
                    else => try js.literal(.null),
                };
                const n = try pg.cx.fresh("$x");
                try js.constant(pg.body, n, try pg.rt("insertText", &.{ parent, marker, try js.string("") }));
                pg.texts[k] = n;
            },
            else => {},
        };
    }

    /// The value an op writes, if it has one.
    fn valueOf(pg: *Page, op: dom.Op) ?m.Value.Index {
        const k: u32 = switch (op.what) {
            .placeholder => |x| x.value,
            .text => |x| x.value,
            .attribute => |x| if (x.constant) return null else x.value,
            .toggle => |x| x.value,
            .style => |x| x.value,
            else => return null,
        };
        return switch (pg.b.operands.items[k]) {
            .value => |v| v,
            else => null,
        };
    }

    /// Each op's read set, and the groups: ops of one read set are one,
    /// those no key writes one more, written at mount only, and two groups
    /// that would write one element's attributes out of source order are
    /// merged (`dom`'s rule).
    fn makeGroups(pg: *Page) m.Error!void {
        const all = pg.ops();
        pg.facts = try pg.a().alloc(m.Program.HoleFacts, all.len);
        const key_of = try pg.a().alloc(u64, all.len);
        // A key: an event's, which is in no group; a read set's, with
        // whether it is evaluated on every message, `static` when no key
        // writes it; a constant attribute's own.
        const event_key: u64 = std.math.maxInt(u64);
        const static_bit: u64 = 1 << 62;
        const constant_bit: u64 = 1 << 61;
        for (all, pg.facts, key_of, 0..) |op, *f, *key, k| {
            const ref: ?m.Program.HoleRef = switch (op.what) {
                .placeholder, .text => .{ .node = op.node },
                .attribute => |x| if (x.constant) null else .{ .item = x.index },
                .toggle => |x| .{ .item = x.index },
                .style => |x| .{ .item = x.index },
                else => null,
            };
            f.* = if (ref) |r| pg.cx.programHole(r) else .{ .group = std.math.maxInt(u32), .static = true, .bake = null };
            if (op.what == .event) {
                key.* = event_key;
                continue;
            }
            const every = if (pg.valueOf(op)) |v| pg.tree.everyRender(v) else false;
            if (every) f.static = false;
            key.* = if (ref == null)
                constant_bit | k
            else if (f.static)
                static_bit | f.group
            else
                (@as(u64, f.group) << 1) | @intFromBool(every);
        }
        // Union by read set.
        const parent = try pg.a().alloc(u32, all.len);
        var by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        for (parent, 0..) |*x, k| {
            x.* = @intCast(k);
            if (key_of[k] == event_key) continue;
            const gop = try by_key.getOrPut(pg.a(), key_of[k]);
            if (gop.found_existing) x.* = gop.value_ptr.* else gop.value_ptr.* = @intCast(k);
        }
        // An element's attributes are written in source order on a mount:
        // the groups of two that would not be merge, until none would.
        const on = try pg.a().alloc(std.ArrayList(u32), pg.b.tnodes.items.len);
        for (on) |*x| x.* = .empty;
        for (all, 0..) |op, k| if (elementOf(op)) |t| try on[t].append(pg.a(), @intCast(k));
        const first = try pg.a().alloc(u32, all.len);
        var changed = true;
        while (changed) {
            changed = false;
            @memset(first, std.math.maxInt(u32));
            for (0..all.len) |k| {
                if (key_of[k] == event_key) continue;
                const r = find(parent, @intCast(k));
                first[r] = @min(first[r], @as(u32, @intCast(k)));
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
        pg.group_of = try pg.a().alloc(u32, all.len);
        @memset(pg.group_of, std.math.maxInt(u32));
        const at_root = try pg.a().alloc(u32, all.len);
        @memset(at_root, std.math.maxInt(u32));
        for (all, 0..) |_, k| {
            if (key_of[k] == event_key) continue;
            const r = find(parent, @intCast(k));
            if (at_root[r] == std.math.maxInt(u32)) {
                at_root[r] = @intCast(pg.groups.items.len);
                try pg.groups.append(pg.a(), .{ .static = true, .every = false });
            }
            const gr = &pg.groups.items[at_root[r]];
            pg.group_of[k] = at_root[r];
            try gr.ops.append(pg.a(), @intCast(k));
            const every = if (pg.valueOf(all[k])) |v| pg.tree.everyRender(v) else false;
            gr.every = gr.every or every;
            const static = key_of[k] & (static_bit | constant_bit) != 0;
            gr.static = gr.static and static;
            if (!static and std.mem.indexOfScalar(u32, gr.sets.items, pg.facts[k].group) == null) {
                try gr.sets.append(pg.a(), pg.facts[k].group);
            }
        }
    }

    /// A slot per op a group compares (§5.3), each `= unset`; a constant
    /// attribute in a group that runs again keeps one too, so it is written
    /// once. A development build keeps the mount-only ops' values as well,
    /// for its check.
    fn writeSlots(pg: *Page) m.Error!void {
        const js = pg.jsb();
        pg.slots = try pg.a().alloc(?m.Name, pg.ops().len);
        @memset(pg.slots, null);
        for (pg.ops(), 0..) |op, k| {
            if (op.what == .event) continue;
            const gr = pg.groups.items[pg.group_of[k]];
            if (gr.static and (pg.cx.build.release or pg.valueOf(op) == null)) continue;
            const s = try pg.cx.fresh("$s");
            try js.let(pg.body, s, try js.name(try pg.cx.runtime("unset")));
            pg.slots[k] = s;
        }
    }

    /// `() => { <the view's parameter bound to the model>; <values>; <writes> }`.
    fn groupFunction(pg: *Page, gr: *const Group) m.Error!m.Expr {
        const blk = try pg.jsb().block();
        try pg.groupBody(blk, gr, false);
        return pg.jsb().arrow(&.{}, blk);
    }

    /// A group's values evaluated against the model, then each op's write:
    /// under one compare with its slot, or unguarded for a group written at
    /// mount only.
    fn groupBody(pg: *Page, blk: m.Block, gr: *const Group, once: bool) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        try cx.programViewEnter(blk, try pg.ident(pg.model));
        defer cx.programViewLeave();
        var values: std.ArrayList(m.Value.Index) = .empty;
        for (gr.ops.items) |k| if (pg.valueOf(pg.ops()[k])) |v| try values.append(pg.a(), v);
        try cx.rootValues(blk, pg.index, values.items);
        for (gr.ops.items) |k| {
            const op = pg.ops()[k];
            if (op.node != .none) cx.at(op.node);
            const slot = pg.slots[k];
            switch (op.what) {
                .attribute => |x| if (x.constant) {
                    const v = try pg.g.make(.{ .constant = pg.b.operands.items[x.value].constant });
                    const el = try pg.ident(pg.walks[x.t].?);
                    if (once or slot == null) {
                        try pg.g.writeAttribute(blk, el, x.item, v, null);
                    } else {
                        // Written once, where its group puts it, and never
                        // again: the group may run on later messages.
                        const then = try js.block();
                        try js.assign(then, try pg.ident(slot.?), try js.literal(.true));
                        try pg.g.writeAttribute(then, el, x.item, v, null);
                        try js.@"if"(blk, try js.binary(.strict_eq, try pg.ident(slot.?), try js.name(try cx.runtime("unset"))), then, null);
                    }
                    continue;
                },
                else => {},
            }
            const v = pg.valueOf(op) orelse continue;
            const leaf = try pg.leafOf(op, v);
            if (once) {
                try pg.write(blk, op, k, v, null);
                if (slot) |s| try js.assign(blk, try pg.ident(s), leaf);
                continue;
            }
            const then = try js.block();
            try pg.write(then, op, k, v, slot);
            try js.assign(then, try pg.ident(slot.?), try pg.leafOf(op, v));
            try js.@"if"(blk, try js.binary(.strict_ne, leaf, try pg.ident(slot.?)), then, null);
        }
    }

    /// What a slot holds of an op's value: the value itself, or a `Maybe`'s
    /// payload — a leaf, never a structure that is made again (§5.3).
    fn leafOf(pg: *Page, op: dom.Op, v: m.Value.Index) m.Error!m.Expr {
        const value = try pg.cx.value(v);
        return switch (op.what) {
            .attribute => |x| if (x.item.class == .maybe_string) pg.cx.maybe(value) else value,
            else => value,
        };
    }

    /// One op's write of value `v`, `backend.md` §15.3's table, as `dom`
    /// writes it. `slot`, when the op is compared, holds what it wrote
    /// last: a class or style list's previous list, a toggle's first state.
    fn write(pg: *Page, blk: m.Block, op: dom.Op, k: u32, v: m.Value.Index, slot: ?m.Name) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        switch (op.what) {
            .placeholder => |x| try js.assign(blk, try js.member(try pg.ident(pg.walks[x.t].?), "data"), try cx.value(v)),
            .text => try js.assign(blk, try js.member(try pg.ident(pg.texts[k].?), "data"), try cx.value(v)),
            .attribute => |x| try pg.g.writeAttribute(blk, try pg.ident(pg.walks[x.t].?), x.item, try cx.value(v), if (slot) |s| try pg.ident(s) else null),
            .toggle => |x| {
                // A class that is off is not written before it was on: a
                // toggle off would leave an empty `class` in some DOMs.
                const el = try pg.ident(pg.walks[x.t].?);
                const toggle = try js.call(try js.member(try js.member(el, "classList"), "toggle"), &.{ try js.string(x.name), try cx.value(v) });
                const then = try js.block();
                try js.expression(then, toggle);
                const was = if (slot) |s| try js.binary(.strict_ne, try pg.ident(s), try js.name(try cx.runtime("unset"))) else try js.literal(.false);
                try js.@"if"(blk, try js.binary(.logical_or, try cx.value(v), was), then, null);
            },
            .style => |x| try js.expression(blk, try js.call(
                try js.member(try js.member(try pg.ident(pg.walks[x.t].?), "style"), "setProperty"),
                &.{ try js.string(x.name), try cx.value(v) },
            )),
            else => {},
        }
    }

    /// A view event's listener (§4.2): its body reads the payload and sends
    /// the message the handler value makes, read at the event (Q1), inside
    /// the guard; the declaration's `preventDefault` and `stopPropagation`
    /// run in the DOM listener itself, synchronously, before `send`.
    fn listener(pg: *Page, into: m.Block, x: @FieldType(dom.Op.What, "event"), k: u32, handlers: []const m.Name) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        _ = k;
        const facts = pg.tree.eventFacts(x.item.event);
        const e = try cx.fresh("$e");
        const blk = try js.block();
        var payload: ?m.Expr = null;
        if (x.item.form == .payload) {
            const extract = try cx.extractor(x.index) orelse try js.name(try cx.runtime("identity"));
            const p = try cx.fresh("$payload");
            try js.constant(blk, p, try js.call(extract, &.{try pg.ident(e)}));
            payload = try pg.ident(p);
        }
        switch (pg.b.operands.items[x.handler]) {
            .value => |v| {
                try cx.programViewEnter(blk, try pg.ident(pg.model));
                const message = try cx.programMessage(blk, v, payload);
                cx.programViewLeave();
                switch (message) {
                    .key => |kc| try js.expression(blk, try js.call(try pg.ident(handlers[kc.key]), kc.args)),
                    .value => |msg| try pg.dispatchValue(blk, msg),
                }
            },
            // A message written as a literal (a `String` message).
            .constant => |c| try pg.dispatchValue(blk, try pg.g.make(.{ .constant = c })),
            else => {},
        }
        const body = try cx.fresh("$l");
        try js.constant(into, body, try js.arrow(&.{e}, blk));
        const dom_listener = try js.block();
        const ev = try cx.fresh("$e");
        if (facts.prevent_default) try js.expression(dom_listener, try js.call(try js.member(try pg.ident(ev), "preventDefault"), &.{}));
        if (facts.stop_propagation) try js.expression(dom_listener, try js.call(try js.member(try pg.ident(ev), "stopPropagation"), &.{}));
        try js.expression(dom_listener, try pg.rt("send", &.{ try pg.ident(body), try pg.ident(ev) }));
        try js.expression(into, try js.call(try js.member(try pg.ident(pg.walks[x.t].?), "addEventListener"), &.{
            try js.string(pg.tree.string(facts.dom_name)),
            try js.arrow(&.{ev}, dom_listener),
        }));
    }

    fn dispatchValue(pg: *Page, blk: m.Block, msg: m.Expr) m.Error!void {
        if (pg.dispatch == null) pg.dispatch = try pg.cx.fresh("$dispatch");
        try pg.jsb().expression(blk, try pg.jsb().call(try pg.ident(pg.dispatch.?), &.{msg}));
    }

    /// The development verify mode (§8.3): after every dispatch, every hole
    /// the page shows computed again from the model and compared, by
    /// structure, with what it wrote — a baked hole with its text. A value
    /// that is made again on every message (`Random.value`) or that calls
    /// `Debug` is not evaluated twice: either would change what a page that
    /// is right does.
    fn writeVerify(pg: *Page) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        const blk = try js.block();
        try cx.programViewEnter(blk, try pg.ident(pg.model));
        var values: std.ArrayList(m.Value.Index) = .empty;
        var checked: std.ArrayList(u32) = .empty;
        for (pg.ops(), 0..) |op, k| {
            const v = pg.valueOf(op) orelse continue;
            if (pg.slots[k] == null or pg.tree.everyRender(v) or cx.reachesDebug(v)) continue;
            try values.append(pg.a(), v);
            try checked.append(pg.a(), @intCast(k));
        }
        var baked: std.ArrayList(m.Node.Index) = .empty;
        try pg.bakedHoles(pg.node, &baked);
        for (baked.items) |n| {
            const v = pg.tree.hole(n).value;
            if (!cx.reachesDebug(v)) try values.append(pg.a(), v);
        }
        if (checked.items.len == 0 and baked.items.len == 0) {
            cx.programViewLeave();
            return;
        }
        try cx.rootValues(blk, pg.index, values.items);
        for (checked.items) |k| {
            const op = pg.ops()[k];
            const leaf = try pg.leafOf(op, pg.valueOf(op).?);
            const then = try js.block();
            try js.expression(then, try pg.rt("wrong", &.{ try js.string(try pg.describe(op, k)), try pg.ident(pg.slots[k].?), try pg.leafOf(op, pg.valueOf(op).?) }));
            try js.@"if"(blk, try js.unary(.not, try pg.rt("same", &.{ leaf, try pg.ident(pg.slots[k].?) })), then, null);
        }
        for (baked.items) |n| {
            const v = pg.tree.hole(n).value;
            if (cx.reachesDebug(v)) continue;
            const facts = cx.programHole(.{ .node = n });
            const text = try js.string(facts.bake.?);
            const then = try js.block();
            const what = try std.fmt.allocPrint(pg.a(), "the text {s} baked into the page", .{if (facts.where.len != 0) facts.where else "hole"});
            try js.expression(then, try pg.rt("wrong", &.{ try js.string(what), text, try cx.value(v) }));
            try js.@"if"(blk, try js.unary(.not, try pg.rt("same", &.{ try cx.value(v), try js.string(facts.bake.?) })), then, null);
        }
        cx.programViewLeave();
        try js.expression(pg.body, try pg.rt("verify", &.{try js.arrow(&.{}, blk)}));
    }

    fn bakedHoles(pg: *Page, n: m.Node.Index, out: *std.ArrayList(m.Node.Index)) m.Error!void {
        const tree = pg.tree;
        switch (tree.kind(n)) {
            .element => for (tree.childrenOf(tree.element(n).children)) |c| try pg.bakedHoles(c, out),
            .fragment => for (tree.childrenOf(tree.fragment(n).children)) |c| try pg.bakedHoles(c, out),
            .hole => if (tree.hole(n).kind == .text_string and bakeOf(pg.cx, n) != null) try out.append(pg.a(), n),
            else => {},
        }
    }

    /// The hole an op writes, for the verify mode's message.
    fn describe(pg: *Page, op: dom.Op, k: u32) m.Error![]const u8 {
        const where = if (pg.facts[k].where.len != 0) pg.facts[k].where else "a hole";
        return switch (op.what) {
            .placeholder, .text => std.fmt.allocPrint(pg.a(), "the text hole at {s}", .{where}),
            .attribute => |x| std.fmt.allocPrint(pg.a(), "the attribute `{s}` at {s}", .{ pg.tree.string(x.item.name), where }),
            .toggle => |x| std.fmt.allocPrint(pg.a(), "the class `{s}` at {s}", .{ x.name, where }),
            .style => |x| std.fmt.allocPrint(pg.a(), "the style `{s}` at {s}", .{ x.name, where }),
            else => where,
        };
    }
};

/// The element an attribute, a class entry or a style entry is written on.
fn elementOf(op: dom.Op) ?u32 {
    return switch (op.what) {
        .attribute => |x| x.t,
        .toggle => |x| x.t,
        .style => |x| x.t,
        else => null,
    };
}

fn find(parent: []u32, k: u32) u32 {
    var at = k;
    while (parent[at] != at) at = parent[at];
    return at;
}

/// A handler's name from its key's (`GotPage · Typed` → `hGotPage$Typed`).
fn handlerHint(arena: std.mem.Allocator, key: []const u8) m.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "$h");
    var sep = false;
    for (key) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            if (sep and out.items.len > 2) try out.append(arena, '$');
            sep = false;
            try out.append(arena, c);
        } else if (c == '*') {
            try out.appendSlice(arena, "All");
        } else sep = true;
    }
    return out.items;
}

test "a handler's name is its key's" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("$hInc", try handlerHint(arena.allocator(), "Inc"));
    try t.expectEqualStrings("$hGotPage$Typed", try handlerHint(arena.allocator(), "GotPage · Typed"));
    try t.expectEqualStrings("$hany", try handlerHint(arena.allocator(), "(any)"));
    try t.expectEqualStrings("$hAll", try handlerHint(arena.allocator(), "*"));
}
