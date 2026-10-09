//! The `direct` program lowering (docs/design/browser-direct.md): a program
//! of The Elm Architecture is compiled, not run. Where a program constructor
//! is called, the compiler hands this lowering the program — its record's
//! shapes, its `view`'s markup, its message keys and what the write-set pass
//! found (`boundary.md` §9.4.6, versions 1.6 to 1.8) — and the lowering
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
//! Slice S2 adds `For` (§6, and its S2 amendment): a **row site** per `For`
//! — its row template, parsed once, `make(it, L)` that clones it, walks to
//! its nodes and builds an instance `{ e, it, l, u, …nodes, …slots, …lists }`,
//! and a function per row group taking the instance — and a **descriptor**
//! per list `{ p, n, r, m, o, k, u }` that the runtime's list functions
//! take (`Direct.mount`, `append`, `swap`, `row`, …: every loop is the
//! runtime's, since the builder has none). A handler runs, per list, the
//! script its key's edit tag names under the tag's guard, then visits the
//! rows its element writes name (`Direct.row`) and every row a read not
//! bound to its row needs (`Direct.each`), calling there exactly the row
//! groups the edits list. Events in a row go through one listener per list
//! and event name on the list's parent (`Direct.delegate`), or a listener
//! of the row's own for one that does not bubble (`Direct.listen`).
//!
//! Everything a later slice adds is refused at build time, naming that
//! slice — never a silent miscompile.

const std = @import("std");
const m = @import("beni_markup");
const dom = @import("platform_browser").dom;

pub const lowering: m.Lowering = .{
    .name = "direct",
    .targets = .{ .major = 1, .minor = 8 },
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
        // `--fuzz`: a mount's dispatcher, reachable as
        // `globalThis.__beniFuzz.send(program, msg)` (§8.3).
        .{ .name = "fuzzMount", .arity = 1 },
        // Lists (§6, as amended for S2): each takes the list's descriptor.
        // `(L, xs)`: every row made, in order, at the list's place.
        .{ .name = "mount", .arity = 2 },
        // `(L, first, xs)`: the rows the template holds, from its first,
        // adopted (K3).
        .{ .name = "adopt", .arity = 3 },
        // §6.2's scripts, each under its tag's guard.
        .{ .name = "append", .arity = 2 },
        .{ .name = "prepend", .arity = 2 },
        .{ .name = "clear", .arity = 1 },
        .{ .name = "insert", .arity = 3 },
        .{ .name = "removeAt", .arity = 3 },
        .{ .name = "swap", .arity = 4 },
        // `(L, xs, j)`: row `j` when its item changed — its item updated —
        // or null; `rekey` makes the row again where its key changed.
        .{ .name = "row", .arity = 3 },
        .{ .name = "rekey", .arity = 3 },
        // `(L, xs, f)`: every row, its item updated, handed to `f`.
        .{ .name = "each", .arity = 3 },
        // `(L, xs, f)`: the positional pass (§6.2): the rows whose item
        // changed handed to `f`, then rows made or removed at the end.
        .{ .name = "positional", .arity = 3 },
        // `(L, el, name, prop)`: the list's listener for a bubbling event
        // (§4.2); `(el, name, h, r)`: a row node's own, for one that is not.
        .{ .name = "delegate", .arity = 4 },
        .{ .name = "listen", .arity = 4 },
        // `(L, xs, check, what, structural)`: the verify mode's list check.
        .{ .name = "verifyList", .arity = 5 },
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
    var g: dom.Gen = .{ .cx = cx, .tree = tree, .direct = true, .bake = bakeOf, .bake_item = bakeItemOf, .bake_list = bakeListOf };
    // A page that holds rows written one after another relies on no
    // implied end tag (K3).
    g.close_all = anyBaked(cx, tree, r.node);
    var b = try g.plan(&.{r.node}, r.site.inst);
    // A root element in the SVG or MathML namespace that is not that
    // namespace's own root is parsed inside a wrapper the mount would take
    // off (`dom`'s flag 2); no vocabulary that ships reaches it.
    if (b.flags & 2 != 0) return cx.notImplemented(r.node,
        \\`browser-direct` does not compile a `view` whose root is an SVG or MathML element
        \\other than `<svg>` or `<math>` yet: it arrives with slice S4
        \\(`docs/design/browser-direct.md` §14).
    ++ " " ++ until_then);
    // Rows written into the template need their instances only for a
    // handler in them, or for the development verify mode (K3).
    var adopt = false;
    for (b.baked_lists.items) |x| {
        if (!cx.build.release or hasEvent(tree, tree.root(tree.row(tree.for_(x.what).row).body).node)) adopt = true;
    }
    if (b.ops.items.len == 0 and !cx.build.fuzz and b.baked_holes.items.len == 0 and b.baked_items.items.len == 0 and !adopt) return staticMount(cx, tree, r.node, b.html.items, b.flags);
    var page: Page = .{ .cx = cx, .tree = tree, .g = &g };
    return page.mount(&b, index, r.node);
}

/// The text a hole is baked as (§5.1, as amended: O8 widened): a text hole
/// of a `String` or an `Int` the program never writes, whose value `init`
/// gives as text the template holds exactly — or, for a row of a `For` K3
/// bakes, that row's text.
fn bakeOf(g: *const dom.Gen, n: m.Node.Index) ?[]const u8 {
    if (g.row) |row| return g.cx.programRowBake(.{ .node = n }, row);
    return g.cx.programHole(.{ .node = n }).bake;
}

/// The same for an attribute, by its index in `Tree.items`.
fn bakeItemOf(g: *const dom.Gen, item: u32) ?[]const u8 {
    if (g.row) |row| return g.cx.programRowBake(.{ .item = item }, row);
    return g.cx.programHole(.{ .item = item }).bake;
}

/// K3 (`browser-direct.md` §6, as amended for S2): the rows of a `For` the
/// pass bakes, each planned with its own texts and written one after
/// another — or null when a row writes something the template cannot hold
/// (an attribute that needs code, a value that is not baked), and the list
/// is made at mount.
fn bakeListOf(g: *dom.Gen, n: m.Node.Index) m.Error!?dom.Gen.BakedRows {
    const count = g.cx.programList(n).baked orelse return null;
    if (count == 0) return null;
    const row = g.tree.row(g.tree.for_(n).row);
    if (row.kind != .markup) return null;
    const body = g.tree.root(row.body);
    var html: std.ArrayList(u8) = .empty;
    for (0..count) |i| {
        var rg: dom.Gen = g.*;
        rg.row = @intCast(i);
        rg.bake_list = null;
        const rb = try rg.plan(&.{body.node}, body.site.inst);
        if (rb.top != 1 or rb.flags & 6 != 0) return null;
        for (rb.ops.items) |op| if (op.what != .event) return null;
        try html.appendSlice(g.cx.arena, rb.html.items);
    }
    return .{ .html = html.items, .count = count };
}

/// Whether the view holds a `For` the pass bakes.
fn anyBaked(cx: *m.Context, tree: *const m.Tree, n: m.Node.Index) bool {
    switch (tree.kind(n)) {
        .element => for (tree.childrenOf(tree.element(n).children)) |c| if (anyBaked(cx, tree, c)) return true,
        .fragment => for (tree.childrenOf(tree.fragment(n).children)) |c| if (anyBaked(cx, tree, c)) return true,
        .for_ => return cx.programList(n).baked != null,
        else => {},
    }
    return false;
}

/// Whether markup holds a handler.
fn hasEvent(tree: *const m.Tree, n: m.Node.Index) bool {
    switch (tree.kind(n)) {
        .element => {
            const e = tree.element(n);
            for (tree.itemsOf(e.items)) |it| if (it.kind == .event) return true;
            for (tree.childrenOf(e.children)) |c| if (hasEvent(tree, c)) return true;
        },
        .fragment => for (tree.childrenOf(tree.fragment(n).children)) |c| if (hasEvent(tree, c)) return true,
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
        .for_ => {
            const f = tree.for_(n);
            if (f.fallback != null) return refuse(cx, n, "a `For`'s `fallback`, markup shown in its place when the list is empty", "S4", "§5.5");
            const row = tree.row(f.row);
            if (row.kind != .markup) return refuse(cx, n, "a `For` row that is not markup written in place — an `if`, a `case`, a `let` or a helper's call around it", "S4", "§5.4, §5.5");
            if (row.arity == 2 and f.mode != .position) return refuse(cx, n, "a keyed `For` row that reads its position (`λrow i →`), which an insert or a remove changes for every row after it", "S3", "§6.2");
            try supported(cx, tree, tree.root(row.body).node);
        },
        .show => return refuse(cx, n, "a `Show`", "S4", "§5.5"),
        else => return refuse(cx, n, "this markup", "S4", "§5"),
    }
}

fn refuse(cx: *m.Context, n: m.Node.Index, what: []const u8, slice: []const u8, section: []const u8) m.Error!void {
    const message = try std.fmt.allocPrint(cx.arena, "`browser-direct` does not compile {s} yet: it arrives with slice {s} (`docs/design/browser-direct.md` {s}, §14). {s}", .{ what, slice, section, until_then });
    return cx.notImplemented(n, message);
}

/// One group of a site's writes (§5.3): the ops that share a read set,
/// merged so that an element's attributes are written in source order.
const Group = struct {
    /// Its ops, in source order.
    ops: std.ArrayList(u32) = .empty,
    /// No key ever calls it: written at mount, or at a row's `make`, never
    /// again (§5.1).
    static: bool,
    /// Evaluates a value that may have an effect (`Random.value`): every
    /// handler calls it (§5.3).
    every: bool,
    /// The read sets of its ops (`Program.HoleFacts.group`).
    sets: std.ArrayList(u32) = .empty,
    /// The function a handler calls: `()` for the view's root, `(r)` for a
    /// row's.
    name: ?m.Name = null,
};

/// Where a site keeps a node, a slot or a list: a name of the mount's scope
/// for the view's root, a field of the instance for a row.
const Ref = union(enum) {
    name: m.Name,
    field: []const u8,
};

/// A row's instance as code reaches it: a name, then fields (`r`, `L.u`).
const Path = struct {
    base: m.Name,
    fields: []const []const u8 = &.{},
};

/// A markup root the mount writes: the view's own, or a `For`'s row.
const Site = struct {
    b: *dom.Body,
    node: m.Node.Index,
    /// The view's root (`row == null`), or the row's root.
    index: m.Root.Index,
    row: ?m.Row.Index = null,
    /// A row site's list.
    list: ?*List = null,
    walks: []?Ref = &.{},
    texts: []?Ref = &.{},
    slots: []?Ref = &.{},
    facts: []m.Program.HoleFacts = &.{},
    groups: std.ArrayList(Group) = .empty,
    group_of: []u32 = &.{},
    /// Per op: the list a `For` op is.
    lists: []?*List = &.{},
    /// The `For`s whose rows the template holds (K3), which no op is.
    baked: std.ArrayList(*List) = .empty,
    /// Per event op: the listener body.
    bodies: []?m.Name = &.{},
    /// A row site's: the row template's root node, `make`, the check.
    template: ?m.Name = null,
    make: ?m.Name = null,
    check: ?m.Name = null,

    fn ops(s: *const Site) []const dom.Op {
        return s.b.ops.items;
    }
};

/// One `For`: where its rows go, its row site, what the pass says of it.
const List = struct {
    node: m.Node.Index,
    /// The site holding it, and its op there.
    site: *Site,
    op: u32,
    rows: *Site,
    facts: m.Program.ListFacts,
    mode: m.For.Mode,
    each: m.Value.Index,
    key: ?m.Value.Index,
    /// Its descriptor: a name of the mount for a list of the view's root, a
    /// field of the enclosing row's instance otherwise.
    desc: Ref,
    /// How many `For`s are around it.
    depth: u32,
    /// The template nodes of its parent and its end marker, as the plan
    /// placed it; null for a list at the view's top level, or rows that
    /// come last.
    parent_t: ?u32,
    marker_t: ?u32,
    /// Its rows are their parent's only children (`clear` empties it).
    owns: bool,
    /// Some key's edit patches its rows whole: `set`, a positional `swap`,
    /// the positional pass.
    whole: bool = false,
    /// The bubbling events its rows handle, as `dom_name`s.
    delegated: std.ArrayList([]const u8) = .empty,
    where: []const u8 = "",
    /// K3: the template holds its rows, the first at this template node;
    /// they are adopted at mount, never made.
    first_t: ?u32 = null,

    fn keyed(l: *const List) bool {
        return l.mode != .position;
    }
};

/// What one key does to one list under one choice of the enclosing rows,
/// decided before its code is written.
const Plan = struct {
    /// Shape scripts, in the edits' order.
    shapes: std.ArrayList(m.Program.Edit) = .empty,
    /// Index visits: the rows at these indices; the union of what each
    /// needs runs at every one, since §6.2's guards make a second visit of
    /// one row a no-op.
    at: std.ArrayList(m.Program.Index) = .empty,
    at_groups: std.ArrayList(u32) = .empty,
    /// The index visits make the row again where its key changed.
    rekey: bool = false,
    /// The index visits patch the row whole: every live group, its lists
    /// replaced (`set`, a positional `swap`).
    whole: bool = false,
    /// Every row, for these groups.
    every: bool = false,
    every_groups: std.ArrayList(u32) = .empty,
    /// The positional pass.
    positional: bool = false,
};

const Page = struct {
    cx: *m.Context,
    tree: *const m.Tree,
    g: *dom.Gen,

    root_site: *Site = undefined,
    index: m.Root.Index = undefined,
    node: m.Node.Index = undefined,
    body: m.Block = undefined,
    model: m.Name = undefined,
    frag: m.Name = undefined,
    at_root: m.Name = undefined,
    t: m.Name = undefined,
    dispatch: ?m.Name = null,
    /// Every list, outermost first.
    lists: std.ArrayList(*List) = .empty,
    keys: []const m.Program.Key = &.{},
    handlers: []m.Name = &.{},
    /// Each key's handler's name, made where it is first needed.
    handler_names: []?m.Name = &.{},
    /// The handler being written: its key's indices, evaluated before its
    /// arm (§6.2, as amended for S2).
    indices: std.AutoHashMapUnmanaged(m.Program.Index, m.Name) = .empty,

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

    fn print(pg: *Page, comptime fmt: []const u8, args: anytype) m.Error![]const u8 {
        return std.fmt.allocPrint(pg.a(), fmt, args);
    }

    fn num(pg: *Page, n: u32) m.Error!m.Expr {
        return pg.jsb().number(try pg.print("{d}", .{n}));
    }

    /// A site's node, slot or list: in a row's code, read through the
    /// instance `inst`. A fresh expression at every call: the builder's
    /// nodes form a tree.
    fn ref(pg: *Page, r: Ref, inst: ?Path) m.Error!m.Expr {
        return switch (r) {
            .name => |n| pg.ident(n),
            .field => |f| pg.jsb().member(try pg.path(inst.?), f),
        };
    }

    /// Key `k`'s handler's name: made where it is first needed — by its
    /// handler, or by a row's listener body written before it.
    fn handlerName(pg: *Page, k: u32) m.Error!m.Name {
        if (pg.handler_names[k]) |n| return n;
        const n = try pg.cx.fresh(try handlerHint(pg.a(), pg.keys[k].name));
        pg.handler_names[k] = n;
        return n;
    }

    /// An instance's expression, fresh.
    fn path(pg: *Page, p: Path) m.Error!m.Expr {
        var e = try pg.ident(p.base);
        for (p.fields) |f| e = try pg.jsb().member(e, f);
        return e;
    }

    /// `p.f`.
    fn dot(pg: *Page, p: Path, f: []const u8) m.Error!Path {
        const fields = try pg.a().alloc([]const u8, p.fields.len + 1);
        @memcpy(fields[0..p.fields.len], p.fields);
        fields[p.fields.len] = f;
        return .{ .base = p.base, .fields = fields };
    }

    fn mount(pg: *Page, b: *dom.Body, index: m.Root.Index, node: m.Node.Index) m.Error!m.Expr {
        const cx = pg.cx;
        const js = pg.jsb();
        pg.index = index;
        pg.node = node;
        pg.at_root = try cx.fresh("$root");
        pg.t = try cx.fresh("$t");
        pg.body = try js.block();

        // Every site planned and every list found, and what S2 does not
        // compile refused, before a line is written.
        const rs = try pg.a().create(Site);
        rs.* = .{ .b = b, .node = node, .index = index };
        pg.root_site = rs;
        pg.keys = cx.programKeys();
        pg.handler_names = try pg.a().alloc(?m.Name, pg.keys.len);
        @memset(pg.handler_names, null);
        try pg.planLists(rs, 0);
        for (pg.lists.items) |list| try pg.checkList(list);

        // `--fuzz` (§8.3, the contract's item 3): this program's
        // dispatcher registered first, so the programs are numbered in
        // mount order and a message value reaches this one.
        if (cx.build.fuzz) {
            pg.dispatch = try cx.fresh("$dispatch");
            const msg = try cx.fresh("$msg");
            const blk = try js.block();
            try js.expression(blk, try js.call(try pg.ident(pg.dispatch.?), &.{try pg.ident(msg)}));
            try js.expression(pg.body, try pg.rt("fuzzMount", &.{try js.arrow(&.{msg}, blk)}));
        }

        // The model, which every handler replaces (§4.1).
        const init = try cx.programInit(pg.body);
        pg.model = try cx.fresh("$model");
        try js.let(pg.body, pg.model, init);
        const update = try cx.programUpdate(pg.body);

        // Each row's template, parsed once, before the page's (§6.1).
        for (pg.lists.items) |list| {
            const s = list.rows;
            if (list.first_t != null) continue;
            cx.at(list.node);
            try js.assign(pg.body, try js.member(try pg.ident(pg.t), "innerHTML"), try js.string(s.b.html.items));
            s.template = try cx.fresh("$T");
            try js.constant(pg.body, s.template.?, try js.member(try js.member(try pg.ident(pg.t), "content"), "firstChild"));
        }

        // The page, parsed once, and its dynamic nodes reached once (§5.1).
        cx.at(pg.node);
        try js.assign(pg.body, try js.member(try pg.ident(pg.t), "innerHTML"), try js.string(b.html.items));
        pg.frag = try cx.fresh("$r");
        try js.constant(pg.body, pg.frag, try content(cx, pg.t, b.flags));
        const walked = try pg.writeWalks(rs, pg.body, null);
        rs.walks = try pg.a().alloc(?Ref, walked.walks.len);
        for (rs.walks, walked.walks) |*w, n| w.* = if (n) |x| .{ .name = x } else null;
        rs.texts = try pg.a().alloc(?Ref, walked.texts.len);
        for (rs.texts, walked.texts) |*w, n| w.* = if (n) |x| .{ .name = x } else null;
        try pg.makeGroups(rs);
        try pg.writeSlots(rs);
        for (rs.groups.items) |*gr| if (!gr.static) {
            gr.name = try cx.fresh("$g");
            try js.constant(pg.body, gr.name.?, try pg.groupFunction(rs, gr));
        };

        // Each row site: its fields, its groups and their functions.
        for (pg.lists.items) |list| {
            const s = list.rows;
            try pg.rowFields(s);
            try pg.makeGroups(s);
            try pg.writeSlots(s);
            for (s.groups.items) |*gr| if (!gr.static) {
                gr.name = try cx.fresh("$g");
                try js.constant(pg.body, gr.name.?, try pg.groupFunction(s, gr));
            };
        }
        // Each row site's listener bodies (§4.2), which `make` puts on its
        // nodes, and its `make`; inner lists first, so an outer `make`
        // names its inner lists' (`make` reads nothing else at its
        // definition).
        for (pg.lists.items) |list| try pg.rowBodies(list);
        var li = pg.lists.items.len;
        while (li > 0) {
            li -= 1;
            try pg.makeFunction(pg.lists.items[li]);
        }
        // The lists of the view's root: their descriptors.
        for (rs.lists) |maybe| if (maybe) |list| {
            const d = try cx.fresh("$L");
            const desc = try pg.descriptor(pg.body, list, null, null);
            list.desc = .{ .name = d };
            try js.constant(pg.body, d, desc);
        };
        for (rs.baked.items) |list| {
            const d = try cx.fresh("$L");
            const desc = try pg.descriptor(pg.body, list, null, null);
            list.desc = .{ .name = d };
            try js.constant(pg.body, d, desc);
        }

        // `patchAll`, for a key that may change everything (§4.1).
        const keys = pg.keys;
        var all: ?m.Name = null;
        for (keys) |key| if (key.star) {
            const blk = try js.block();
            for (rs.groups.items) |gr| if (gr.name) |n| try js.expression(blk, try js.call(try pg.ident(n), &.{}));
            all = try cx.fresh("$patchAll");
            try js.constant(pg.body, all.?, try js.arrow(&.{}, blk));
            break;
        };

        // One handler per key (§4.1): the indices its edits name, its arm,
        // its lists' scripts and visits (§4.1 step 3's (c)), then the groups
        // its write set conflicts with, each guarded by its own compare.
        pg.handlers = try pg.a().alloc(m.Name, keys.len);
        for (keys, pg.handlers, 0..) |key, *h, k| {
            const params = try pg.a().alloc(m.Name, key.params);
            for (params) |*x| x.* = try cx.fresh("$p");
            const blk = try js.block();
            try pg.evaluateIndices(blk, @intCast(k), params);
            const next = try cx.programArm(@intCast(k), blk, params, try pg.ident(pg.model), update);
            try js.assign(blk, try pg.ident(pg.model), next);
            for (rs.lists) |maybe| if (maybe) |list| try pg.visitList(blk, @intCast(k), list, &.{}, null);
            if (key.star) {
                try js.expression(blk, try js.call(try pg.ident(all.?), &.{}));
            } else for (rs.groups.items) |gr| {
                const name = gr.name orelse continue;
                if (gr.every or pg.calls(gr, @intCast(k))) try js.expression(blk, try js.call(try pg.ident(name), &.{}));
            }
            h.* = try pg.handlerName(@intCast(k));
            try js.constant(pg.body, h.*, try js.arrow(params, blk));
        }

        // The listeners, into a block of their own so the dispatcher, which
        // only some of them need, is declared before them.
        const listeners = try js.block();
        for (rs.ops(), 0..) |op, k| switch (op.what) {
            .event => |x| try pg.listener(listeners, rs, x, @intCast(k)),
            else => {},
        };
        if (pg.dispatch) |d| {
            const msg = try cx.fresh("$msg");
            const blk = try js.block();
            try cx.programDispatch(blk, try pg.ident(msg), pg.handlers);
            try js.constant(pg.body, d, try js.arrow(&.{msg}, blk));
        }
        try js.nested(pg.body, listeners);
        // Each list of the view's root listening for its rows' bubbling
        // events, on its parent — the mount node at the top level (§4.2).
        for (rs.lists) |maybe| if (maybe) |list| try pg.delegateList(pg.body, list, null, null);
        for (rs.baked.items) |list| try pg.delegateList(pg.body, list, null, null);

        // The mount: every group once and every list's rows, in source
        // order, a group no key calls written in place (§5.1); then the
        // rows the template holds, adopted (K3).
        try pg.mountSite(pg.body, rs, null);
        for (rs.baked.items) |list| {
            const inner = try js.block();
            const xs = try pg.eachValue(inner, list, null);
            try js.expression(inner, try pg.rt("adopt", &.{ try pg.ref(list.desc, null), try pg.ref(rs.walks[list.first_t.?].?, null), try pg.ident(xs) }));
            try js.nested(pg.body, inner);
        }
        try js.expression(pg.body, try js.call(try js.member(try pg.ident(pg.at_root), "append"), &.{try pg.ident(pg.frag)}));

        if (!cx.build.release) try pg.writeVerify();
        return js.arrow(&.{ pg.at_root, pg.t }, pg.body);
    }

    // ---- Planning -------------------------------------------------------

    /// Each `For` op of the site: its list and its row site planned, then
    /// the lists inside that row — every list, outermost first.
    fn planLists(pg: *Page, s: *Site, depth: u32) m.Error!void {
        s.lists = try pg.a().alloc(?*List, s.ops().len);
        @memset(s.lists, null);
        for (s.ops(), 0..) |op, k| switch (op.what) {
            .for_ => |x| {
                const f = pg.tree.for_(op.node);
                const row = pg.tree.row(f.row);
                const body = pg.tree.root(row.body);
                const rb = try pg.a().create(dom.Body);
                pg.cx.at(op.node);
                rb.* = try pg.g.plan(&.{body.node}, body.site.inst);
                // One element at the row's root: what a script moves and
                // removes (§6.2).
                const one = rb.top == 1 and rb.first != null and rb.first.? == .node and rb.tnodes.items[rb.first.?.node].kind == .element and rb.flags & 4 == 0;
                if (!one) try refuse(pg.cx, op.node, "a `For` row that is not one element — several nodes, text, or a hole at its root", "S4", "§6.1");
                if (rb.flags & 2 != 0) try refuse(pg.cx, op.node, "a `For` row whose root is an SVG or MathML element other than `<svg>` or `<math>`", "S4", "§14");
                const rs = try pg.a().create(Site);
                rs.* = .{ .b = rb, .node = body.node, .index = row.body, .row = f.row };
                const list = try pg.a().create(List);
                const parent_t = x.at.parent;
                const marker_t: ?u32 = switch (x.at.marker) {
                    .node => |t| t,
                    else => null,
                };
                // Its rows are the parent's only children: nothing else of
                // the template, and no other slot, is in it.
                var owns = parent_t != null and marker_t == null;
                if (owns) {
                    for (s.b.tnodes.items) |tn| if (tn.parent != null and tn.parent.? == parent_t.?) {
                        owns = false;
                    };
                    for (s.ops(), 0..) |other, j| if (j != k) if (placeOf(other)) |pl| if (pl.parent != null and pl.parent.? == parent_t.?) {
                        owns = false;
                    };
                }
                list.* = .{
                    .node = op.node,
                    .site = s,
                    .op = @intCast(k),
                    .rows = rs,
                    .facts = pg.cx.programList(op.node),
                    .mode = f.mode,
                    .each = f.each,
                    .key = f.key,
                    .desc = .{ .field = try pg.print("l{d}", .{k}) },
                    .depth = depth,
                    .parent_t = parent_t,
                    .marker_t = marker_t,
                    .owns = owns,
                    .where = pg.cx.programHole(.{ .node = op.node }).where,
                };
                rs.list = list;
                s.lists[k] = list;
                try pg.lists.append(pg.a(), list);
                for (rb.ops.items) |rop| switch (rop.what) {
                    .event => |ev| {
                        const facts = pg.tree.eventFacts(ev.item.event);
                        if (!facts.delegated) continue;
                        const name = pg.tree.string(facts.dom_name);
                        for (list.delegated.items) |seen| {
                            if (std.mem.eql(u8, seen, name)) break;
                        } else try list.delegated.append(pg.a(), name);
                    },
                    else => {},
                };
                try pg.planLists(rs, depth + 1);
            },
            else => {},
        };
        // K3: a list whose rows the template holds — its row planned for
        // its structure, which every row shares, and its first row and the
        // node after its last walked to.
        for (s.b.baked_lists.items) |x| {
            const f = pg.tree.for_(x.what);
            const row = pg.tree.row(f.row);
            const body = pg.tree.root(row.body);
            // A release build keeps no instance a page does not use: rows
            // with no handler are the template's, and nothing more.
            if (pg.cx.build.release and !hasEvent(pg.tree, body.node)) continue;
            const count = pg.cx.programList(x.what).baked.?;
            var rg: dom.Gen = pg.g.*;
            rg.row = 0;
            rg.bake_list = null;
            const rb = try pg.a().create(dom.Body);
            rb.* = try rg.plan(&.{body.node}, body.site.inst);
            const tnodes = s.b.tnodes.items;
            const last = x.t + count - 1;
            const parent_t = tnodes[x.t].parent;
            var marker_t: ?u32 = null;
            for (tnodes[last + 1 ..], last + 1..) |tn, i| if (tn.parent == parent_t and tn.index == tnodes[last].index + 1) {
                marker_t = @intCast(i);
                break;
            };
            s.b.mark(x.t);
            if (marker_t) |t| s.b.mark(t);
            const rs = try pg.a().create(Site);
            rs.* = .{ .b = rb, .node = body.node, .index = row.body, .row = f.row };
            const list = try pg.a().create(List);
            list.* = .{
                .node = x.what,
                .site = s,
                .op = std.math.maxInt(u32),
                .rows = rs,
                .facts = pg.cx.programList(x.what),
                .mode = f.mode,
                .each = f.each,
                .key = f.key,
                .desc = .{ .field = "" },
                .depth = depth,
                .parent_t = parent_t,
                .marker_t = marker_t,
                .owns = false,
                .where = pg.cx.programHole(.{ .node = x.what }).where,
                .first_t = x.t,
            };
            rs.list = list;
            try s.baked.append(pg.a(), list);
            try pg.lists.append(pg.a(), list);
            for (rb.ops.items) |rop| switch (rop.what) {
                .event => |ev| {
                    const facts = pg.tree.eventFacts(ev.item.event);
                    if (!facts.delegated) continue;
                    const name = pg.tree.string(facts.dom_name);
                    for (list.delegated.items) |seen| {
                        if (std.mem.eql(u8, seen, name)) break;
                    } else try list.delegated.append(pg.a(), name);
                },
                else => {},
            };
            rs.lists = &.{};
        }
    }

    /// Refuse what a key does to a list that S2 does not compile: on a
    /// keyed `For`, the reconciler's tags, the identity walk, the merge, an
    /// index the handler cannot evaluate, and a derived `each` some key
    /// replaces; and a keyed `For` in a row some key patches whole (§6, as
    /// amended for S2). Note which lists some key patches whole.
    fn checkList(pg: *Page, list: *List) m.Error!void {
        const js = pg.jsb();
        const keyed = list.keyed();
        const scratch = try js.block();
        for (pg.keys, 0..) |key, k| {
            const params = try pg.a().alloc(m.Name, key.params);
            for (params) |*x| x.* = try pg.cx.fresh("$p");
            for (pg.cx.programEdits(@intCast(k), list.node)) |e| switch (e.what) {
                .shape => |sh| {
                    const needs: []const m.Program.Index = switch (sh.tag) {
                        .set, .insert, .remove_at => &.{sh.a},
                        .swap => &.{ sh.a, sh.b },
                        else => &.{},
                    };
                    var evaluable = true;
                    for (needs) |ix| {
                        if (ix == .every or ix == .unknown or try pg.cx.programIndex(@intCast(k), scratch, params, try js.literal(.null), ix) == null) evaluable = false;
                    }
                    const reconciler = switch (sh.tag) {
                        .all, .remove_some, .permute, .replaced => true,
                        else => false,
                    };
                    if (keyed and (reconciler or !evaluable)) {
                        const why = switch (sh.tag) {
                            .all => "maps every row (`List.map`: §6.2's identity walk)",
                            .remove_some => "drops some rows (`List.filter`, `take`, `drop`: §6.2's merge)",
                            .permute => "reorders it (`List.sort`, `List.reverse`: §6.3's reconciler)",
                            .replaced => if (list.facts.exact) "replaces it — another list, or two edits composed (§6.3's reconciler)" else "changes what its derived `each` reads (§6.2: a derived list is matched by §6.3's reconciler)",
                            else => "edits it at an index the handler cannot compute before the arm (§6.2's index symbols)",
                        };
                        const who = if (std.mem.eql(u8, key.name, "(any)")) "the program's `update`" else try pg.print("the message `{s}`", .{key.name});
                        const message = try pg.print("`browser-direct` does not compile this keyed `For` yet: {s} {s}, which arrives with slice S3 (`docs/design/browser-direct.md` §6.2, §6.3, §14). {s}", .{ who, why, until_then });
                        return pg.cx.notImplemented(list.node, message);
                    }
                    if (reconciler or !evaluable) list.whole = true;
                    if (!keyed and (sh.tag == .prepend or sh.tag == .insert or sh.tag == .remove_at)) list.whole = true;
                    if (sh.tag == .set or (!keyed and sh.tag == .swap)) list.whole = true;
                },
                .rows => {},
            };
        }
        // A row patched whole shows another item, whose lists are other
        // lists; a keyed one needs the reconciler.
        if (list.whole) for (list.rows.lists) |maybe| if (maybe) |inner| if (inner.keyed()) {
            const message = try pg.print("`browser-direct` does not compile a keyed `For` in the row of a `For` some message patches whole (`List.set`, or the positional pass): the inner list is then another list, which §6.3's reconciler matches, and it arrives with slice S3 (`docs/design/browser-direct.md` §14). {s}", .{until_then});
            return pg.cx.notImplemented(inner.node, message);
        };
    }

    // ---- The view's root, and a row's fields ------------------------------

    const Walked = struct { walks: []?m.Name, texts: []?m.Name };

    /// Every needed node of a site's template, reached from the parsed
    /// content — or, for a row, from its root element `row_root` — into
    /// `blk` before anything is written (`dom`'s walks, `dom/template.rs`),
    /// and a text hole's node made where it goes; their local names.
    fn writeWalks(pg: *Page, s: *Site, blk: m.Block, row_root: ?m.Name) m.Error!Walked {
        const js = pg.jsb();
        const tnodes = s.b.tnodes.items;
        const names = try pg.a().alloc(?m.Name, tnodes.len);
        @memset(names, null);
        const last_in = try pg.a().alloc(?u32, tnodes.len + 1);
        @memset(last_in, null);
        for (tnodes, 0..) |tn, i| {
            if (!tn.needed) continue;
            if (row_root != null and tn.parent == null) {
                // The row's root element is the clone itself.
                names[i] = row_root.?;
                last_in[tnodes.len] = @intCast(i);
                continue;
            }
            const group = tn.parent orelse tnodes.len;
            var e: m.Expr = undefined;
            var steps: u32 = undefined;
            if (last_in[group]) |prev| {
                e = try pg.ident(names[prev].?);
                steps = tn.index - tnodes[prev].index;
            } else {
                const base = if (tn.parent) |p| names[p].? else pg.frag;
                e = try js.member(try pg.ident(base), "firstChild");
                steps = tn.index;
            }
            for (0..steps) |_| e = try js.member(e, "nextSibling");
            const w = try pg.cx.fresh("$w");
            try js.constant(blk, w, e);
            names[i] = w;
            last_in[group] = @intCast(i);
        }
        const texts = try pg.a().alloc(?m.Name, s.ops().len);
        @memset(texts, null);
        for (s.ops(), 0..) |op, k| switch (op.what) {
            .text => |x| {
                pg.cx.at(op.node);
                const parent = if (x.at.parent) |p| try pg.ident(names[p].?) else try pg.ident(pg.frag);
                const marker = switch (x.at.marker) {
                    .node => |mk| try pg.ident(names[mk].?),
                    else => try js.literal(.null),
                };
                const n = try pg.cx.fresh("$x");
                try js.constant(blk, n, try pg.rt("insertText", &.{ parent, marker, try js.string("") }));
                texts[k] = n;
            },
            else => {},
        };
        return .{ .walks = names, .texts = texts };
    }

    /// A row's nodes, as fields of its instance: `e` for its root element,
    /// `w<t>` for a node a write reads, `x<k>` for a text hole's node.
    fn rowFields(pg: *Page, s: *Site) m.Error!void {
        const tnodes = s.b.tnodes.items;
        s.walks = try pg.a().alloc(?Ref, tnodes.len);
        @memset(s.walks, null);
        s.texts = try pg.a().alloc(?Ref, s.ops().len);
        @memset(s.texts, null);
        for (s.ops(), 0..) |op, k| {
            const t: ?u32 = switch (op.what) {
                .placeholder => |x| x.t,
                .attribute => |x| x.t,
                .toggle => |x| x.t,
                .style => |x| x.t,
                .text => {
                    s.texts[k] = .{ .field = try pg.print("x{d}", .{k}) };
                    continue;
                },
                else => null,
            };
            if (t) |tt| s.walks[tt] = .{ .field = if (tnodes[tt].parent == null) "e" else try pg.print("w{d}", .{tt}) };
        }
        // A baked row's text and attributes, which the development verify
        // mode reads back (K3).
        if (!pg.cx.build.release) {
            for (s.b.baked_holes.items) |x| s.walks[x.t] = .{ .field = if (tnodes[x.t].parent == null) "e" else try pg.print("w{d}", .{x.t}) };
            for (s.b.baked_items.items) |x| s.walks[x.t] = .{ .field = if (tnodes[x.t].parent == null) "e" else try pg.print("w{d}", .{x.t}) };
        }
    }

    /// The value an op writes, if it has one.
    fn valueOf(s: *const Site, op: dom.Op) ?m.Value.Index {
        const k: u32 = switch (op.what) {
            .placeholder => |x| x.value,
            .text => |x| x.value,
            .attribute => |x| if (x.constant) return null else x.value,
            .toggle => |x| x.value,
            .style => |x| x.value,
            else => return null,
        };
        return switch (s.b.operands.items[k]) {
            .value => |v| v,
            else => null,
        };
    }

    /// Each op's read set, and the groups: ops of one read set are one,
    /// those no key writes one more, written at mount only, and two groups
    /// that would write one element's attributes out of source order are
    /// merged (`dom`'s rule). An event and a `For` are in no group. A row's
    /// group is static when no key's edits of its list call it and no key
    /// patches its rows whole.
    fn makeGroups(pg: *Page, s: *Site) m.Error!void {
        const all = s.ops();
        s.facts = try pg.a().alloc(m.Program.HoleFacts, all.len);
        const key_of = try pg.a().alloc(u64, all.len);
        const event_key: u64 = std.math.maxInt(u64);
        const static_bit: u64 = 1 << 62;
        const constant_bit: u64 = 1 << 61;
        for (all, s.facts, key_of, 0..) |op, *f, *key, k| {
            const ref_: ?m.Program.HoleRef = switch (op.what) {
                .placeholder, .text => .{ .node = op.node },
                .attribute => |x| if (x.constant) null else .{ .item = x.index },
                .toggle => |x| .{ .item = x.index },
                .style => |x| .{ .item = x.index },
                else => null,
            };
            f.* = if (ref_) |r| pg.cx.programHole(r) else .{ .group = std.math.maxInt(u32), .static = true, .bake = null };
            if (op.what == .event or op.what == .for_) {
                key.* = event_key;
                continue;
            }
            const every = if (valueOf(s, op)) |v| pg.tree.everyRender(v) else false;
            if (s.list) |list| if (ref_ != null) {
                f.static = !pg.rowCalled(list, f.group) and !(list.whole and !f.static);
            };
            if (every) f.static = false;
            key.* = if (ref_ == null)
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
        const on = try pg.a().alloc(std.ArrayList(u32), s.b.tnodes.items.len);
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
        s.group_of = try pg.a().alloc(u32, all.len);
        @memset(s.group_of, std.math.maxInt(u32));
        const at_root = try pg.a().alloc(u32, all.len);
        @memset(at_root, std.math.maxInt(u32));
        for (all, 0..) |_, k| {
            if (key_of[k] == event_key) continue;
            const r = find(parent, @intCast(k));
            if (at_root[r] == std.math.maxInt(u32)) {
                at_root[r] = @intCast(s.groups.items.len);
                try s.groups.append(pg.a(), .{ .static = true, .every = false });
            }
            const gr = &s.groups.items[at_root[r]];
            s.group_of[k] = at_root[r];
            try gr.ops.append(pg.a(), @intCast(k));
            const every = if (valueOf(s, all[k])) |v| pg.tree.everyRender(v) else false;
            gr.every = gr.every or every;
            const static = key_of[k] & (static_bit | constant_bit) != 0;
            gr.static = gr.static and static;
            if (!static and std.mem.indexOfScalar(u32, gr.sets.items, s.facts[k].group) == null) {
                try gr.sets.append(pg.a(), s.facts[k].group);
            }
        }
    }

    /// Whether some key's edits of `list` call row group `group`.
    fn rowCalled(pg: *Page, list: *const List, group: u32) bool {
        for (0..pg.keys.len) |k| for (pg.cx.programEdits(@intCast(k), list.node)) |e| switch (e.what) {
            .rows => |r| if (std.mem.indexOfScalar(u32, r.groups, group) != null) return true,
            else => {},
        };
        return false;
    }

    /// A slot per op a group compares (§5.3), each `= unset`; a constant
    /// attribute in a group that runs again keeps one too, so it is written
    /// once. A development build keeps the mount-only ops' values as well,
    /// for its check. A row's are fields of its instance (`s<k>`).
    fn writeSlots(pg: *Page, s: *Site) m.Error!void {
        const js = pg.jsb();
        s.slots = try pg.a().alloc(?Ref, s.ops().len);
        @memset(s.slots, null);
        for (s.ops(), 0..) |op, k| {
            if (op.what == .event or op.what == .for_) continue;
            const gr = s.groups.items[s.group_of[k]];
            if (gr.static and (pg.cx.build.release or valueOf(s, op) == null)) continue;
            if (s.row != null) {
                s.slots[k] = .{ .field = try pg.print("s{d}", .{k}) };
                continue;
            }
            const n = try pg.cx.fresh("$s");
            try js.let(pg.body, n, try js.name(try pg.cx.runtime("unset")));
            s.slots[k] = .{ .name = n };
        }
    }

    // ---- Values -------------------------------------------------------------

    /// Bind what a site's code reads into `blk`: `view`'s parameter to the
    /// model, and for a row each enclosing row's item, outermost first —
    /// `inst` the row's instance, or, in `make`, `item` its item and `up`
    /// the enclosing row's instance — then evaluate `values` of the site's
    /// root. The caller leaves the view (`programViewLeave`).
    fn enter(pg: *Page, blk: m.Block, s: *const Site, inst: ?Path, item: ?Path, up: ?Path, values: []const m.Value.Index) m.Error!void {
        try pg.cx.programViewEnter(blk, try pg.ident(pg.model));
        if (s.row == null) return pg.cx.rootValues(blk, pg.index, values);
        const it = item orelse try pg.dot(inst.?, "it");
        const parent: ?Path = up orelse if (s.list.?.depth > 0) try pg.dot(inst.?, "u") else null;
        const position: ?Path = if (pg.readsPosition(s)) (if (inst) |i| try pg.dot(i, "i") else null) else null;
        try pg.bindRow(blk, s, it, parent, position, values);
    }

    fn bindRow(pg: *Page, blk: m.Block, s: *const Site, item: Path, up: ?Path, position: ?Path, values: []const m.Value.Index) m.Error!void {
        const js = pg.jsb();
        const outer = s.list.?.site;
        if (outer.row != null) try pg.bindRow(
            blk,
            outer,
            try pg.dot(up.?, "it"),
            if (outer.list.?.depth > 0) try pg.dot(up.?, "u") else null,
            if (pg.readsPosition(outer)) try pg.dot(up.?, "i") else null,
            &.{},
        );
        const it = try pg.cx.fresh("$it");
        try js.constant(blk, it, try pg.path(item));
        var pos: ?m.Name = null;
        if (position) |p| {
            pos = try pg.cx.fresh("$i");
            try js.constant(blk, pos.?, try pg.path(p));
        }
        try pg.cx.rowValuesOf(blk, s.row.?, it, pos, values);
    }

    /// Whether a row reads its position (a positional `For`'s `λrow i →`):
    /// its instance keeps it, as `i`.
    fn readsPosition(pg: *Page, s: *const Site) bool {
        const row = s.row orelse return false;
        return pg.tree.row(row).arity == 2;
    }

    /// The values a group's ops write.
    fn groupValues(pg: *Page, s: *const Site, gr: *const Group) m.Error![]const m.Value.Index {
        var values: std.ArrayList(m.Value.Index) = .empty;
        for (gr.ops.items) |k| if (valueOf(s, s.ops()[k])) |v| try values.append(pg.a(), v);
        return values.items;
    }

    /// `() => { <view's parameter bound to the model>; <values>; <writes> }`
    /// for the view's root; `(r) => { … }` for a row, its item `r.it`.
    fn groupFunction(pg: *Page, s: *Site, gr: *const Group) m.Error!m.Expr {
        const js = pg.jsb();
        const blk = try js.block();
        if (s.row == null) {
            try pg.groupBody(blk, s, gr, false, null);
            return js.arrow(&.{}, blk);
        }
        const r = try pg.cx.fresh("$r");
        try pg.groupBody(blk, s, gr, false, .{ .base = r });
        return js.arrow(&.{r}, blk);
    }

    /// A group's values evaluated against the model, then each op's write:
    /// under one compare with its slot, or unguarded for a group written at
    /// mount only. `inst`: a row's instance.
    fn groupBody(pg: *Page, blk: m.Block, s: *Site, gr: *const Group, once: bool, inst: ?Path) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        try pg.enter(blk, s, inst, null, null, try pg.groupValues(s, gr));
        defer cx.programViewLeave();
        for (gr.ops.items) |k| {
            const op = s.ops()[k];
            if (op.node != .none) cx.at(op.node);
            const slot = s.slots[k];
            switch (op.what) {
                .attribute => |x| if (x.constant) {
                    const v = try pg.g.make(.{ .constant = s.b.operands.items[x.value].constant });
                    const el = try pg.ref(s.walks[x.t].?, inst);
                    if (once or slot == null) {
                        try pg.g.writeAttribute(blk, el, x.item, v, null);
                    } else {
                        // Written once, where its group puts it, and never
                        // again: the group may run on later messages.
                        const then = try js.block();
                        try js.assign(then, try pg.ref(slot.?, inst), try js.literal(.true));
                        try pg.g.writeAttribute(then, el, x.item, v, null);
                        try js.@"if"(blk, try js.binary(.strict_eq, try pg.ref(slot.?, inst), try js.name(try cx.runtime("unset"))), then, null);
                    }
                    continue;
                },
                else => {},
            }
            const v = valueOf(s, op) orelse continue;
            const leaf = try pg.leafOf(op, v);
            if (once) {
                try pg.write(blk, s, op, k, v, null, inst);
                if (slot) |sl| try js.assign(blk, try pg.ref(sl, inst), leaf);
                continue;
            }
            const then = try js.block();
            try pg.write(then, s, op, k, v, slot, inst);
            try js.assign(then, try pg.ref(slot.?, inst), try pg.leafOf(op, v));
            try js.@"if"(blk, try js.binary(.strict_ne, leaf, try pg.ref(slot.?, inst)), then, null);
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
    fn write(pg: *Page, blk: m.Block, s: *Site, op: dom.Op, k: u32, v: m.Value.Index, slot: ?Ref, inst: ?Path) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        switch (op.what) {
            .placeholder => |x| try js.assign(blk, try js.member(try pg.ref(s.walks[x.t].?, inst), "data"), try cx.value(v)),
            .text => try js.assign(blk, try js.member(try pg.ref(s.texts[k].?, inst), "data"), try cx.value(v)),
            .attribute => |x| try pg.g.writeAttribute(blk, try pg.ref(s.walks[x.t].?, inst), x.item, try cx.value(v), if (slot) |sl| try pg.ref(sl, inst) else null),
            .toggle => |x| {
                // A class that is off is not written before it was on: a
                // toggle off would leave an empty `class` in some DOMs.
                const el = try pg.ref(s.walks[x.t].?, inst);
                const toggle = try js.call(try js.member(try js.member(el, "classList"), "toggle"), &.{ try js.string(x.name), try cx.value(v) });
                const then = try js.block();
                try js.expression(then, toggle);
                const was = if (slot) |sl| try js.binary(.strict_ne, try pg.ref(sl, inst), try js.name(try cx.runtime("unset"))) else try js.literal(.false);
                try js.@"if"(blk, try js.binary(.logical_or, try cx.value(v), was), then, null);
            },
            .style => |x| try js.expression(blk, try js.call(
                try js.member(try js.member(try pg.ref(s.walks[x.t].?, inst), "style"), "setProperty"),
                &.{ try js.string(x.name), try cx.value(v) },
            )),
            else => {},
        }
    }

    /// Whether key `k` writes something one of the group's read sets reads.
    fn calls(pg: *Page, gr: Group, k: u32) bool {
        for (gr.sets.items) |set| if (pg.cx.programCalls(k, set)) return true;
        return false;
    }

    /// A list's items, evaluated into `blk` — against the model for a list
    /// of the view's root, with its enclosing row's item otherwise (`inst`,
    /// that row's instance; or, in `make`, `item` and `up`) — as a name.
    fn eachValue(pg: *Page, blk: m.Block, list: *const List, inst: ?Path) m.Error!m.Name {
        const js = pg.jsb();
        try pg.enter(blk, list.site, inst, null, null, &.{list.each});
        const xs = try pg.cx.fresh("$xs");
        try js.constant(blk, xs, try pg.cx.value(list.each));
        pg.cx.programViewLeave();
        return xs;
    }

    // ---- Mount and make -----------------------------------------------------

    /// A site's first writes, in source order: each group once — in place
    /// when no key calls it — and each list's rows (`Direct.mount`). In
    /// `make`, `inst` is the row's instance and `item`, `up` what it is
    /// made of.
    fn mountSite(pg: *Page, blk: m.Block, s: *Site, inst: ?Path) m.Error!void {
        const js = pg.jsb();
        const done = try pg.a().alloc(bool, s.groups.items.len);
        @memset(done, false);
        for (s.ops(), 0..) |op, k| {
            if (op.what == .for_) {
                const list = s.lists[k].?;
                const inner = try js.block();
                const xs = try pg.eachValue(inner, list, inst);
                try js.expression(inner, try pg.rt("mount", &.{ try pg.ref(list.desc, inst), try pg.ident(xs) }));
                try js.nested(blk, inner);
                continue;
            }
            if (op.what == .event) continue;
            const gi = s.group_of[k];
            if (done[gi]) continue;
            done[gi] = true;
            const gr = &s.groups.items[gi];
            if (gr.name) |n| {
                try js.expression(blk, try js.call(try pg.ident(n), if (inst) |i| &.{try pg.path(i)} else &.{}));
            } else {
                const inner = try js.block();
                try pg.groupBody(inner, s, gr, true, inst);
                try js.nested(blk, inner);
            }
        }
    }

    /// A list's descriptor (§6, as amended for S2): `{ p, n, r, m, o, k, u }`
    /// — its parent (null at the view's top level), its end marker (null:
    /// its rows come last), its instances, `make`, whether its rows are the
    /// parent's only children, its key function (null for a positional
    /// list), and the instance of the row it is in (null at the view's
    /// root). Values are evaluated into `blk`; `walk` names the enclosing
    /// site's nodes where they are local names (`make`'s), and `inst` is
    /// the enclosing row's instance.
    fn descriptor(pg: *Page, blk: m.Block, list: *List, walk: ?[]const ?m.Name, inst: ?Path) m.Error!m.Expr {
        const js = pg.jsb();
        const nodeOf = struct {
            fn get(p: *Page, l: *List, w: ?[]const ?m.Name, t: ?u32) m.Error!m.Expr {
                const tt = t orelse return p.jsb().literal(.null);
                if (w) |names| return p.ident(names[tt].?);
                return p.ref(l.site.walks[tt] orelse return p.jsb().literal(.null), null);
            }
        }.get;
        var props: std.ArrayList(m.Property) = .empty;
        // Rows the template holds at its top level are the mount node's
        // children once it is mounted (K3).
        const parent = if (list.first_t != null and list.parent_t == null) try pg.ident(pg.at_root) else try nodeOf(pg, list, walk, list.parent_t);
        try props.append(pg.a(), .{ .key = "p", .value = parent });
        try props.append(pg.a(), .{ .key = "n", .value = try nodeOf(pg, list, walk, list.marker_t) });
        try props.append(pg.a(), .{ .key = "r", .value = try js.array(&.{}) });
        try props.append(pg.a(), .{ .key = "m", .value = try pg.ident(list.rows.make.?) });
        try props.append(pg.a(), .{ .key = "o", .value = try js.literal(if (list.owns) .true else .false) });
        const key: m.Expr = switch (list.mode) {
            .position => try js.literal(.null),
            .key => blk_: {
                try pg.enter(blk, list.site, inst, null, null, &.{list.key.?});
                const kn = try pg.cx.fresh("$key");
                try js.constant(blk, kn, try pg.cx.value(list.key.?));
                pg.cx.programViewLeave();
                break :blk_ try pg.ident(kn);
            },
            else => try js.name(try pg.cx.runtime("identity")),
        };
        try props.append(pg.a(), .{ .key = "k", .value = key });
        try props.append(pg.a(), .{ .key = "u", .value = if (inst) |i| try pg.path(i) else try js.literal(.null) });
        return js.object(props.items);
    }

    /// `make(it, L, j)`: the row cloned, its nodes walked to, its instance
    /// `{ e, it, l, u, i, …nodes, …slots, …lists }` built, its handler nodes
    /// marked (§4.2), its lists' descriptors made, and its first writes and
    /// rows in source order.
    fn makeFunction(pg: *Page, list: *List) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        const s = list.rows;
        const blk = try js.block();
        const it = try cx.fresh("$it");
        const desc = try cx.fresh("$L");
        const position = try cx.fresh("$j");
        const e = try cx.fresh("$e");
        cx.at(list.node);
        // A row the template holds is adopted: its element is given (K3).
        if (list.first_t == null) {
            const template = try pg.ident(s.template.?);
            const clone = if (s.b.flags & 1 != 0)
                try js.call(try js.member(try js.member(try pg.ident(pg.t), "ownerDocument"), "importNode"), &.{ template, try js.literal(.true) })
            else
                try js.call(try js.member(template, "cloneNode"), &.{try js.literal(.true)});
            try js.constant(blk, e, clone);
        }
        const walked = try pg.writeWalks(s, blk, e);
        // The instance: its fields in one literal, so every row has one
        // shape.
        const r = try cx.fresh("$r");
        var props: std.ArrayList(m.Property) = .empty;
        try props.append(pg.a(), .{ .key = "e", .value = try pg.ident(e) });
        try props.append(pg.a(), .{ .key = "it", .value = try pg.ident(it) });
        const marked = list.delegated.items.len != 0;
        if (marked) try props.append(pg.a(), .{ .key = "l", .value = try pg.ident(desc) });
        if (list.depth > 0) try props.append(pg.a(), .{ .key = "u", .value = try js.member(try pg.ident(desc), "u") });
        if (pg.readsPosition(s)) try props.append(pg.a(), .{ .key = "i", .value = try pg.ident(position) });
        for (s.walks, 0..) |w, t| if (w) |field| if (!std.mem.eql(u8, field.field, "e")) {
            try props.append(pg.a(), .{ .key = field.field, .value = try pg.ident(walked.walks[t].?) });
        };
        for (s.texts, 0..) |x, k| if (x) |field| try props.append(pg.a(), .{ .key = field.field, .value = try pg.ident(walked.texts[k].?) });
        for (s.slots) |slot| if (slot) |field| try props.append(pg.a(), .{ .key = field.field, .value = try js.name(try cx.runtime("unset")) });
        for (s.lists) |maybe| if (maybe) |inner| try props.append(pg.a(), .{ .key = inner.desc.field, .value = try js.literal(.null) });
        try js.constant(blk, r, try js.object(props.items));
        const ri: Path = .{ .base = r };
        // The row's root is marked for its list's walk (§4.2).
        if (marked) try js.assign(blk, try js.member(try pg.ident(e), "$r"), try pg.ident(r));
        // Each handler node: its body for the list's walk, or a listener
        // of its own for an event that does not bubble.
        for (s.ops(), 0..) |op, k| switch (op.what) {
            .event => |x| {
                const facts = pg.tree.eventFacts(x.item.event);
                const node = try pg.ident(walked.walks[x.t].?);
                const body_ = try pg.ident(s.bodies[k].?);
                const name = pg.tree.string(facts.dom_name);
                if (facts.delegated) {
                    try js.assign(blk, try js.member(node, try pg.print("${s}", .{name})), body_);
                } else {
                    try js.expression(blk, try pg.rt("listen", &.{ node, try js.string(name), body_, try pg.ident(r) }));
                }
            },
            else => {},
        };
        // Its lists, made empty here and filled in source order below.
        for (s.lists) |maybe| if (maybe) |inner| {
            const inner_blk = try js.block();
            const d = try pg.descriptor(inner_blk, inner, walked.walks, ri);
            try js.assign(inner_blk, try js.member(try pg.ident(r), inner.desc.field), d);
            try js.nested(blk, inner_blk);
            try pg.delegateList(blk, inner, walked.walks, ri);
        };
        try pg.mountSite(blk, s, ri);
        try js.@"return"(blk, try pg.ident(r));
        s.make = try cx.fresh("$make");
        try js.constant(pg.body, s.make.?, try js.arrow(if (list.first_t == null) &.{ it, desc, position } else &.{ it, desc, position, e }, blk));
    }

    /// A list's listener for each bubbling event its rows handle, on its
    /// parent — the mount node for a list at the view's top level (§4.2).
    fn delegateList(pg: *Page, blk: m.Block, list: *List, walk: ?[]const ?m.Name, inst: ?Path) m.Error!void {
        const js = pg.jsb();
        if (list.delegated.items.len == 0) return;
        const el: m.Expr = if (list.parent_t) |t|
            (if (walk) |names| try pg.ident(names[t].?) else try pg.ref(list.site.walks[t].?, null))
        else
            try pg.ident(pg.at_root);
        for (list.delegated.items) |name| {
            try js.expression(blk, try pg.rt("delegate", &.{ try pg.ref(list.desc, inst), el, try js.string(name), try js.string(try pg.print("${s}", .{name})) }));
        }
    }

    // ---- Events -------------------------------------------------------------

    /// A view event's listener (§4.2): its body reads the payload and sends
    /// the message the handler value makes, read at the event (Q1), inside
    /// the guard; the declaration's `preventDefault` and `stopPropagation`
    /// run in the DOM listener itself, synchronously, before `send`.
    fn listener(pg: *Page, into: m.Block, s: *Site, x: @FieldType(dom.Op.What, "event"), k: u32) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        _ = k;
        const facts = pg.tree.eventFacts(x.item.event);
        const e = try cx.fresh("$e");
        const blk = try js.block();
        try pg.listenerBody(blk, s, x, e, null);
        const body = try cx.fresh("$l");
        try js.constant(into, body, try js.arrow(&.{e}, blk));
        const dom_listener = try js.block();
        const ev = try cx.fresh("$e");
        if (facts.prevent_default) try js.expression(dom_listener, try js.call(try js.member(try pg.ident(ev), "preventDefault"), &.{}));
        if (facts.stop_propagation) try js.expression(dom_listener, try js.call(try js.member(try pg.ident(ev), "stopPropagation"), &.{}));
        try js.expression(dom_listener, try pg.rt("send", &.{ try pg.ident(body), try pg.ident(ev) }));
        try js.expression(into, try js.call(try js.member(try pg.ref(s.walks[x.t].?, null), "addEventListener"), &.{
            try js.string(pg.tree.string(facts.dom_name)),
            try js.arrow(&.{ev}, dom_listener),
        }));
    }

    /// What a listener body does: the payload read, the message made — read
    /// at the event — and sent to its key's handler or the dispatcher.
    /// `inst`: a row's instance, whose item the handler value reads.
    fn listenerBody(pg: *Page, blk: m.Block, s: *Site, x: @FieldType(dom.Op.What, "event"), e: m.Name, inst: ?Path) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        var payload: ?m.Expr = null;
        if (x.item.form == .payload) {
            const extract = try cx.extractor(x.index) orelse try js.name(try cx.runtime("identity"));
            const p = try cx.fresh("$payload");
            try js.constant(blk, p, try js.call(extract, &.{try pg.ident(e)}));
            payload = try pg.ident(p);
        }
        switch (s.b.operands.items[x.handler]) {
            .value => |v| {
                try pg.enter(blk, s, inst, null, null, &.{});
                const message = try cx.programMessage(blk, v, payload);
                cx.programViewLeave();
                switch (message) {
                    .key => |kc| try js.expression(blk, try js.call(try pg.ident(try pg.handlerName(kc.key)), kc.args)),
                    .value => |msg| try pg.dispatchValue(blk, msg),
                }
            },
            // A message written as a literal (a `String` message).
            .constant => |c| try pg.dispatchValue(blk, try pg.g.make(.{ .constant = c })),
            else => {},
        }
    }

    /// Each event of a row: its body `(e, r) => …`, which `make` puts on
    /// the handler node for the list's walk or hands to the node's own
    /// listener, and its declaration's flags on it as `f` — 1
    /// `preventDefault`, 2 `stopPropagation` — which the runtime applies,
    /// synchronously, as the event passes the node.
    fn rowBodies(pg: *Page, list: *List) m.Error!void {
        const cx = pg.cx;
        const js = pg.jsb();
        const s = list.rows;
        s.bodies = try pg.a().alloc(?m.Name, s.ops().len);
        @memset(s.bodies, null);
        for (s.ops(), 0..) |op, k| switch (op.what) {
            .event => |x| {
                const facts = pg.tree.eventFacts(x.item.event);
                const e = try cx.fresh("$e");
                const r = try cx.fresh("$r");
                const blk = try js.block();
                try pg.listenerBody(blk, s, x, e, .{ .base = r });
                const body = try cx.fresh("$l");
                try js.constant(pg.body, body, try js.arrow(&.{ e, r }, blk));
                const flags: u32 = @as(u32, @intFromBool(facts.prevent_default)) | (@as(u32, @intFromBool(facts.stop_propagation)) << 1);
                if (flags != 0) try js.assign(pg.body, try js.member(try pg.ident(body), "f"), try pg.num(flags));
                s.bodies[k] = body;
            },
            else => {},
        };
    }

    fn dispatchValue(pg: *Page, blk: m.Block, msg: m.Expr) m.Error!void {
        if (pg.dispatch == null) pg.dispatch = try pg.cx.fresh("$dispatch");
        try pg.jsb().expression(blk, try pg.jsb().call(try pg.ident(pg.dispatch.?), &.{msg}));
    }

    // ---- Handlers: scripts and visits ---------------------------------------

    /// Every index key `k`'s edits name, evaluated before its arm into a
    /// constant (§6.2, as amended for S2): `pg.indices`. One the handler
    /// cannot evaluate is left out, and its visit is every row's.
    fn evaluateIndices(pg: *Page, blk: m.Block, k: u32, params: []const m.Name) m.Error!void {
        const js = pg.jsb();
        pg.indices = .empty;
        for (pg.lists.items) |list| for (pg.cx.programEdits(k, list.node)) |e| {
            var used: std.ArrayList(m.Program.Index) = .empty;
            try used.appendSlice(pg.a(), e.outer);
            switch (e.what) {
                .shape => |sh| try used.appendSlice(pg.a(), &.{ sh.a, sh.b }),
                .rows => |r| try used.append(pg.a(), r.at),
            }
            for (used.items) |ix| {
                if (ix == .every or ix == .unknown or pg.indices.contains(ix)) continue;
                const value = try pg.cx.programIndex(k, blk, params, try pg.ident(pg.model), ix) orelse continue;
                const n = try pg.cx.fresh("$k");
                try js.constant(blk, n, value);
                try pg.indices.put(pg.a(), ix, n);
            }
        };
    }

    /// An index visit's index, or null when it is every row's.
    fn indexOf(pg: *Page, ix: m.Program.Index) ?m.Name {
        if (ix == .every or ix == .unknown) return null;
        return pg.indices.get(ix);
    }

    /// Whether an edit's `outer` matches the visit being written: at each
    /// enclosing list, a visit of one row (`false`) or of every row
    /// (`true`).
    fn under(pg: *Page, outer: []const m.Program.Index, modes: []const bool) bool {
        if (outer.len < modes.len) return false;
        for (modes, outer[0..modes.len]) |every, ix| if (every != (pg.indexOf(ix) == null)) return false;
        return true;
    }

    /// What key `k` does to `list` in the rows of the enclosing lists
    /// `modes` names: its shapes and visits, and the visits its inner
    /// lists' edits need of its rows.
    fn plan(pg: *Page, k: u32, list: *const List, modes: []const bool) m.Error!Plan {
        var p: Plan = .{};
        const keyed = list.keyed();
        for (pg.cx.programEdits(k, list.node)) |e| {
            if (e.outer.len != modes.len or !pg.under(e.outer, modes)) continue;
            switch (e.what) {
                .shape => |sh| switch (sh.tag) {
                    .append, .clear => try p.shapes.append(pg.a(), e),
                    .prepend, .insert, .remove_at => if (keyed and pg.indexOf(sh.a) != null or keyed and sh.tag == .prepend) try p.shapes.append(pg.a(), e) else {
                        p.positional = true;
                    },
                    .swap => if (pg.indexOf(sh.a) == null or pg.indexOf(sh.b) == null) {
                        p.positional = true;
                    } else if (keyed) try p.shapes.append(pg.a(), e) else {
                        try addIndex(pg.a(), &p.at, sh.a);
                        try addIndex(pg.a(), &p.at, sh.b);
                        p.whole = true;
                    },
                    .set => if (pg.indexOf(sh.a) == null) {
                        p.positional = true;
                    } else {
                        try addIndex(pg.a(), &p.at, sh.a);
                        p.whole = true;
                        p.rekey = p.rekey or keyed;
                    },
                    else => p.positional = true,
                },
                .rows => |r| if (pg.indexOf(r.at) == null) {
                    p.every = true;
                    for (r.groups) |g| try addGroup(pg.a(), &p.every_groups, g);
                } else {
                    try addIndex(pg.a(), &p.at, r.at);
                    for (r.groups) |g| try addGroup(pg.a(), &p.at_groups, g);
                    p.rekey = p.rekey or r.rekey;
                },
            }
        }
        // The rows the inner lists' edits are in.
        for (pg.lists.items) |inner| {
            if (!pg.inside(inner, list)) continue;
            for (pg.cx.programEdits(k, inner.node)) |e| {
                if (e.outer.len <= modes.len or !pg.under(e.outer, modes)) continue;
                const ix = e.outer[modes.len];
                if (pg.indexOf(ix) == null) p.every = true else try addIndex(pg.a(), &p.at, ix);
            }
        }
        return p;
    }

    /// Whether `inner` is in `list`'s rows, at any depth.
    fn inside(pg: *Page, inner: *const List, list: *const List) bool {
        _ = pg;
        var s: *const Site = inner.site;
        while (s.list) |l| : (s = l.site) if (l == list) return true;
        return false;
    }

    /// Key `k`'s scripts and visits of `list` (§4.1 step 3's (c)), its
    /// enclosing lists' rows chosen by `modes`, `inst` the row it is in.
    fn visitList(pg: *Page, blk: m.Block, k: u32, list: *List, modes: []const bool, inst: ?Path) m.Error!void {
        const js = pg.jsb();
        const p = try pg.plan(k, list, modes);
        if (p.shapes.items.len == 0 and p.at.items.len == 0 and !p.every and !p.positional) return;
        const inner = try js.block();
        const xs = try pg.eachValue(inner, list, inst);
        for (p.shapes.items) |e| {
            const sh = e.what.shape;
            const desc = try pg.ref(list.desc, inst);
            const items = try pg.ident(xs);
            const call = switch (sh.tag) {
                .append => try pg.rt("append", &.{ desc, items }),
                .prepend => try pg.rt("prepend", &.{ desc, items }),
                .clear => try pg.rt("clear", &.{desc}),
                .insert => try pg.rt("insert", &.{ desc, items, try pg.ident(pg.indexOf(sh.a).?) }),
                .remove_at => try pg.rt("removeAt", &.{ desc, items, try pg.ident(pg.indexOf(sh.a).?) }),
                .swap => try pg.rt("swap", &.{ desc, items, try pg.ident(pg.indexOf(sh.a).?), try pg.ident(pg.indexOf(sh.b).?) }),
                else => unreachable,
            };
            try js.expression(inner, call);
        }
        if (p.positional) {
            try js.expression(inner, try pg.rt("positional", &.{ try pg.ref(list.desc, inst), try pg.ident(xs), try pg.wholeFunction(list) }));
        }
        // One row at each index, its item updated where it changed.
        if (p.at.items.len != 0) {
            const r = try pg.cx.fresh("$r");
            const body = try js.block();
            try pg.rowVisit(body, k, list, modes, .{ .base = r }, &p, false);
            const visit: ?m.Name = if (p.at.items.len > 1) try pg.cx.fresh("$v") else null;
            if (visit) |v| try js.constant(inner, v, try js.arrow(&.{r}, body));
            for (p.at.items) |ix| {
                const one = try js.block();
                const found = if (visit != null) try pg.cx.fresh("$r") else r;
                try js.constant(one, found, try pg.rt(if (p.rekey) "rekey" else "row", &.{ try pg.ref(list.desc, inst), try pg.ident(xs), try pg.ident(pg.indexOf(ix).?) }));
                const then = if (visit) |v| blk_: {
                    const b = try js.block();
                    try js.expression(b, try js.call(try pg.ident(v), &.{try pg.ident(found)}));
                    break :blk_ b;
                } else body;
                try js.@"if"(one, try js.binary(.strict_ne, try pg.ident(found), try js.literal(.null)), then, null);
                try js.nested(inner, one);
            }
        }
        // Every row, for what reads more than its own item.
        if (p.every) {
            const r = try pg.cx.fresh("$r");
            const body = try js.block();
            try pg.rowVisit(body, k, list, modes, .{ .base = r }, &p, true);
            try js.expression(inner, try pg.rt("each", &.{ try pg.ref(list.desc, inst), try pg.ident(xs), try js.arrow(&.{r}, body) }));
        }
        try js.nested(blk, inner);
    }

    /// One row's visit: its groups, then its lists' scripts and visits.
    fn rowVisit(pg: *Page, blk: m.Block, k: u32, list: *List, modes: []const bool, r: Path, p: *const Plan, every: bool) m.Error!void {
        const js = pg.jsb();
        const s = list.rows;
        const whole = !every and p.whole;
        const groups = if (every) p.every_groups.items else p.at_groups.items;
        for (s.groups.items) |gr| {
            const name = gr.name orelse continue;
            const called = whole or gr.every or for (gr.sets.items) |set| {
                if (std.mem.indexOfScalar(u32, groups, set) != null) break true;
            } else false;
            if (called) try js.expression(blk, try js.call(try pg.ident(name), &.{try pg.path(r)}));
        }
        const next = try pg.a().alloc(bool, modes.len + 1);
        @memcpy(next[0..modes.len], modes);
        next[modes.len] = every;
        for (s.lists) |maybe| if (maybe) |inner| {
            if (whole) {
                // Another item, so another list: the positional pass (a
                // keyed one here was refused, `checkList`).
                try pg.replaceList(blk, inner, r);
            } else try pg.visitList(blk, k, inner, next, r);
        };
    }

    /// A list in a row patched whole: its rows matched by the positional
    /// pass to the item's.
    fn replaceList(pg: *Page, blk: m.Block, inner: *List, r: Path) m.Error!void {
        const js = pg.jsb();
        const b = try js.block();
        const xs = try pg.eachValue(b, inner, r);
        try js.expression(b, try pg.rt("positional", &.{ try pg.ref(inner.desc, r), try pg.ident(xs), try pg.wholeFunction(inner) }));
        try js.nested(blk, b);
    }

    /// `(r) => …`: a row patched whole — every live group, and its lists
    /// by the positional pass — for the positional pass and `set`.
    fn wholeFunction(pg: *Page, list: *List) m.Error!m.Expr {
        const js = pg.jsb();
        const r = try pg.cx.fresh("$r");
        const blk = try js.block();
        for (list.rows.groups.items) |gr| if (gr.name) |n| try js.expression(blk, try js.call(try pg.ident(n), &.{try pg.ident(r)}));
        for (list.rows.lists) |maybe| if (maybe) |inner| try pg.replaceList(blk, inner, .{ .base = r });
        return js.arrow(&.{r}, blk);
    }

    // ---- The development verify mode (§8.3) --------------------------------

    /// After every dispatch, every hole the page shows computed again from
    /// the model and compared, by structure, with what it wrote — a baked
    /// hole with its text — and every list with its rows: their number,
    /// each row's item, their order in the page, and each row's holes and
    /// lists. A value that is made again on every message (`Random.value`)
    /// or that calls `Debug` is not evaluated twice: either would change
    /// what a page that is right does.
    fn writeVerify(pg: *Page) m.Error!void {
        const js = pg.jsb();
        // Each row site's check, inner ones first.
        var li = pg.lists.items.len;
        while (li > 0) {
            li -= 1;
            const list = pg.lists.items[li];
            const r = try pg.cx.fresh("$r");
            const blk = try js.block();
            _ = try pg.verifySite(blk, list.rows, .{ .base = r });
            list.rows.check = try pg.cx.fresh("$check");
            try js.constant(pg.body, list.rows.check.?, try js.arrow(&.{r}, blk));
        }
        const blk = try js.block();
        if (!try pg.verifySite(blk, pg.root_site, null)) return;
        try js.expression(pg.body, try pg.rt("verify", &.{try js.arrow(&.{}, blk)}));
    }

    /// A site's checks into `blk`; false when it has none.
    fn verifySite(pg: *Page, blk: m.Block, s: *Site, inst: ?Path) m.Error!bool {
        const cx = pg.cx;
        const js = pg.jsb();
        var values: std.ArrayList(m.Value.Index) = .empty;
        var checked: std.ArrayList(u32) = .empty;
        for (s.ops(), 0..) |op, k| {
            const v = valueOf(s, op) orelse continue;
            if (s.slots[k] == null or pg.tree.everyRender(v) or cx.reachesDebug(v)) continue;
            try values.append(pg.a(), v);
            try checked.append(pg.a(), @intCast(k));
        }
        // What the template holds verbatim: each baked text hole and
        // attribute, its value computed again, and the page's node read
        // and compared with what a write of that value would leave there.
        var baked: std.ArrayList(Baked) = .empty;
        {
            for (s.b.baked_holes.items) |x| {
                const facts = cx.programHole(.{ .node = x.what });
                try baked.append(pg.a(), .{ .value = pg.tree.hole(x.what).value, .t = x.t, .item = null, .what = try std.fmt.allocPrint(pg.a(), "the text {s} baked into the page", .{if (facts.where.len != 0) facts.where else "hole"}) });
            }
            for (s.b.baked_items.items) |x| {
                const facts = cx.programHole(.{ .item = x.what });
                const it = pg.tree.items[x.what];
                try baked.append(pg.a(), .{ .value = it.value.dynamic.?, .t = x.t, .item = it, .what = try std.fmt.allocPrint(pg.a(), "the attribute `{s}` at {s} baked into the page", .{ pg.tree.string(it.name), if (facts.where.len != 0) facts.where else "?" }) });
            }
        }
        var kept: std.ArrayList(Baked) = .empty;
        for (baked.items) |x| if (!cx.reachesDebug(x.value)) {
            try kept.append(pg.a(), x);
            try values.append(pg.a(), x.value);
        };
        var lists = false;
        if (s.baked.items.len != 0) lists = true;
        for (s.lists) |maybe| if (maybe != null) {
            lists = true;
        };
        if (checked.items.len == 0 and kept.items.len == 0 and !lists) return false;
        try pg.enter(blk, s, inst, null, null, values.items);
        for (checked.items) |k| {
            const op = s.ops()[k];
            const slot = try pg.ref(s.slots[k].?, inst);
            const leaf = try pg.leafOf(op, valueOf(s, op).?);
            const then = try js.block();
            const what = try pg.describe(s, op, k);
            try js.expression(then, try pg.rt("wrong", &.{ try js.string(what), slot, try pg.leafOf(op, valueOf(s, op).?) }));
            try js.@"if"(blk, try js.unary(.not, try pg.rt("same", &.{ leaf, try pg.ref(s.slots[k].?, inst) })), then, null);
            // The page itself, not only the slot: a write that stored the
            // right value and left the wrong text is a missed write too.
            const v = valueOf(s, op).?;
            const at = try std.fmt.allocPrint(pg.a(), "{s} in the document", .{what});
            switch (op.what) {
                .placeholder => |x| try pg.checkNode(blk, at, s.walks[x.t].?, inst, null, v),
                .text => try pg.checkNode(blk, at, s.texts[k].?, inst, null, v),
                .attribute => |x| try pg.checkNode(blk, at, s.walks[x.t].?, inst, x.item, v),
                else => {},
            }
        }
        for (kept.items) |x| try pg.checkNode(blk, x.what, s.walks[x.t].?, inst, x.item, x.value);
        cx.programViewLeave();
        // Each list: its rows against its items, and each row's checks.
        for (s.lists) |maybe| if (maybe) |list| try pg.verifyList(blk, list, inst);
        for (s.baked.items) |list| try pg.verifyList(blk, list, inst);
        return true;
    }

    fn verifyList(pg: *Page, blk: m.Block, list: *List, inst: ?Path) m.Error!void {
        const js = pg.jsb();
        const inner = try js.block();
        const xs = try pg.eachValue(inner, list, inst);
        const what = try pg.print("the `For` at {s}", .{if (list.where.len != 0) list.where else "?"});
        try js.expression(inner, try pg.rt("verifyList", &.{
            try pg.ref(list.desc, inst),
            try pg.ident(xs),
            try pg.ident(list.rows.check.?),
            try js.string(what),
            try js.literal(if (list.facts.exact) .false else .true),
        }));
        try js.nested(blk, inner);
    }

    const Baked = struct { value: m.Value.Index, t: u32, item: ?m.Item, what: []const u8 };

    /// The verify mode's read of the page (§8.3, as amended): a text node's
    /// `data`, or an element's attribute `item`, compared with the string
    /// a write of value `v` leaves there (`dom`'s `writeAttribute`). An
    /// attribute the page writes as a property, raw markup, a list or a
    /// state is not read.
    fn checkNode(pg: *Page, blk: m.Block, what: []const u8, node: Ref, inst: ?Path, item: ?m.Item, v: m.Value.Index) m.Error!void {
        const js = pg.jsb();
        const cond = try pg.readAndExpected(node, inst, item, v) orelse return;
        const msg = (try pg.readAndExpected(node, inst, item, v)).?;
        const then = try js.block();
        try js.expression(then, try pg.rt("wrong", &.{ try js.string(what), msg[0], msg[1] }));
        try js.@"if"(blk, try js.binary(.strict_ne, cond[0], cond[1]), then, null);
    }

    /// What the page shows at `node` and what a write of `v` leaves there,
    /// or null for a write the verify mode does not read back.
    fn readAndExpected(pg: *Page, node: Ref, inst: ?Path, item: ?m.Item, v: m.Value.Index) m.Error!?[2]m.Expr {
        const cx = pg.cx;
        const js = pg.jsb();
        const it = item orelse return .{
            try js.member(try pg.ref(node, inst), "data"),
            try js.template(&.{ .{ .text = "" }, .{ .expr = try cx.value(v) } }),
        };
        if (it.kind != .attribute and it.kind != .escape) return null;
        if (it.kind == .attribute and it.attribute != .none) {
            const f = pg.tree.attributeFacts(it.attribute);
            if (f.property != null or f.raw or f.stateful) return null;
        }
        const expected = switch (it.class) {
            .string, .int, .float => if (it.url)
                try pg.rt("safeUrl", &.{try cx.value(v)})
            else
                try js.template(&.{ .{ .text = "" }, .{ .expr = try cx.value(v) } }),
            .bool => try js.cond(try cx.value(v), try js.string(""), try js.literal(.null)),
            .maybe_string => try js.cond(
                try cx.isJust(try cx.value(v)),
                if (it.url)
                    try pg.rt("safeUrl", &.{try cx.maybe(try cx.value(v))})
                else
                    try js.template(&.{ .{ .text = "" }, .{ .expr = try cx.maybe(try cx.value(v)) } }),
                try js.literal(.null),
            ),
            else => return null,
        };
        return .{ try js.call(try js.member(try pg.ref(node, inst), "getAttribute"), &.{try js.string(pg.tree.string(it.name))}), expected };
    }

    /// The hole an op writes, for the verify mode's message.
    fn describe(pg: *Page, s: *const Site, op: dom.Op, k: u32) m.Error![]const u8 {
        const where = if (s.facts[k].where.len != 0) s.facts[k].where else "a hole";
        return switch (op.what) {
            .placeholder, .text => std.fmt.allocPrint(pg.a(), "the text hole at {s}", .{where}),
            .attribute => |x| std.fmt.allocPrint(pg.a(), "the attribute `{s}` at {s}", .{ pg.tree.string(x.item.name), where }),
            .toggle => |x| std.fmt.allocPrint(pg.a(), "the class `{s}` at {s}", .{ x.name, where }),
            .style => |x| std.fmt.allocPrint(pg.a(), "the style `{s}` at {s}", .{ x.name, where }),
            else => where,
        };
    }
};

/// The place of a slot op: where its content goes.
fn placeOf(op: dom.Op) ?dom.Place {
    return switch (op.what) {
        .text => |y| y.at,
        .for_ => |y| y.at,
        .html => |y| y.at,
        .helper => |y| y.at,
        .component => |y| y.at,
        .show => |y| y.at,
        else => null,
    };
}

fn addIndex(a: std.mem.Allocator, list: *std.ArrayList(m.Program.Index), ix: m.Program.Index) m.Error!void {
    if (std.mem.indexOfScalar(m.Program.Index, list.items, ix) != null) return;
    try list.append(a, ix);
}

fn addGroup(a: std.mem.Allocator, list: *std.ArrayList(u32), g: u32) m.Error!void {
    if (std.mem.indexOfScalar(u32, list.items, g) != null) return;
    try list.append(a, g);
}

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
