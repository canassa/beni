//! The `direct` program lowering (docs/design/browser-direct.md): a program
//! of The Elm Architecture is compiled, not run. Where a program constructor
//! is called, the compiler hands this lowering the program — its record's
//! shapes, its `view`'s markup, its `init` to evaluate — through the
//! program hook (`boundary.md` §9.4.6, version 1.6), and the lowering
//! returns the program's **mount**, a function of the mount node and a
//! `template` element that `Direct.run` calls inside the dispatch guard:
//!
//!     (root, t) => { const init = <init>; t.innerHTML = "<html>"; root.append(t.content); }
//!
//! There is no `view` at run time and no markup value: a markup root
//! anywhere else, and a markup primitive, is refused at build time
//! (`Lowering.no_markup_values`) until slice S4's value path (§5.2).
//!
//! **Slice S0** (§14) compiles `Tea.sandbox` whose `view` is static markup:
//! its whole page is one string, written once at mount (§5.1), parsed from
//! the same text `browser`'s `dom` lowering writes for the same markup
//! (`dom.staticTemplate`). Everything else is `not_implemented`, naming the
//! slice that adds it, never a silent miscompile.

const std = @import("std");
const m = @import("beni_markup");
const dom = @import("platform_browser").dom;

pub const lowering: m.Lowering = .{
    .name = "direct",
    .targets = .{ .major = 1, .minor = 6 },
    .runtime = &.{
        // `(f, x)`: the dispatch guard (§4.3), which a listener body, the
        // dispatcher and the mount enter program code through.
        .{ .name = "send", .arity = 2 },
        // The sentinel every slot starts at (§5.3).
        .{ .name = "unset", .arity = 0 },
    },
    .module = module,
    .root = root,
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

/// The program hook: the mount of a `Tea.sandbox` whose `view` is static.
fn program(cx: *m.Context, tree: *const m.Tree, p: *const m.Program) m.Error!m.Expr {
    switch (p.constructor) {
        0 => {},
        else => return cx.programReport(.call, .not_implemented,
            \\`browser-direct` does not compile `Tea.element`, `Tea.document` or
            \\`Tea.application` yet: programs with effects arrive with slice S5
            \\(`docs/design/browser-direct.md` §10, §14).
        ++ " " ++ until_then),
    }
    if (!p.record) return cx.programReport(.call, .not_implemented,
        \\`browser-direct` compiles a program whose record is written where `Tea.sandbox` is
        \\called, with its `init`, `update` and `view`; a record held in a value or built by a
        \\function arrives with slice S1 (`docs/design/browser-direct.md` §11.1, §14).
    ++ " " ++ until_then);
    switch (p.update) {
        .markup, .function, .other_module => {},
        else => return cx.programReport(.update, .not_implemented,
            \\`browser-direct` does not compile an `update` that is computed — a call such as
            \\`withLogging update`, a local — yet: it is the single `*` message key, which
            \\arrives with slice S1 (`docs/design/browser-direct.md` §4.1, §14).
        ++ " " ++ until_then),
    }
    switch (p.view) {
        .markup => {},
        .function => return cx.programReport(.view, .not_implemented,
            \\`browser-direct` compiles a `view` whose body is markup written in place, and this
            \\one's is not; a `view` whose body computes its markup — a `let`, an `if`, a
            \\`case`, a helper's call — arrives with slices S1 to S4
            \\(`docs/design/browser-direct.md` §5, §14).
        ++ " " ++ until_then),
        .other_module => return cx.programReport(.view, .not_implemented,
            \\`browser-direct` compiles a `view` declared in the module that calls `Tea.sandbox`,
            \\and this one is another module's; that arrives with slice S1
            \\(`docs/design/browser-direct.md` §11.1, §14).
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
    const r = tree.root(p.view_root.?);
    try staticOnly(cx, tree, r.node);
    const page = try dom.staticTemplate(cx, tree, &.{r.node}, r.site.inst) orelse
        return cx.notImplemented(r.node, "`browser-direct` compiles a `view` of static markup only: this markup writes something after it is parsed. Holes and attributes that change arrive with slice S1 (`docs/design/browser-direct.md` §14). " ++ until_then);
    // A root element in the SVG or MathML namespace that is not that
    // namespace's own root is parsed inside a wrapper the mount would take
    // off (`dom`'s flag 2).
    if (page.flags & 2 != 0) return cx.notImplemented(r.node,
        \\`browser-direct` does not compile a `view` whose root is an SVG or MathML element
        \\other than `<svg>` or `<math>` yet: it arrives with slice S1
        \\(`docs/design/browser-direct.md` §14).
    ++ " " ++ until_then);
    return mount(cx, tree, r.node, page.html);
}

/// `(root, t) => { const init = <init>; t.innerHTML = html; root.append(t.content); }`:
/// `init` evaluated inside the guard, then the page written once (§5.1).
/// Markup with no nodes writes nothing.
fn mount(cx: *m.Context, tree: *const m.Tree, node: m.Node.Index, html: []const u8) m.Error!m.Expr {
    const js = cx.js;
    const at = try cx.fresh("root");
    const t = try cx.fresh("t");
    const body = try js.block();
    // S0 reads nothing of the model: `init` is evaluated for what it does,
    // and S1 keeps its value in the program's `model`.
    _ = try cx.programInit(body);
    if (!empty(tree, node)) {
        cx.at(node);
        try js.assign(body, try js.member(try js.name(t), "innerHTML"), try js.string(html));
        try js.expression(body, try js.call(try js.member(try js.name(at), "append"), &.{try js.member(try js.name(t), "content")}));
    }
    return js.arrow(&.{ at, t }, body);
}

/// A fragment with no children: a page that shows nothing.
fn empty(tree: *const m.Tree, node: m.Node.Index) bool {
    return tree.kind(node) == .fragment and tree.fragment(node).children.len == 0;
}

/// Refuse the first thing in the markup that is not static, naming the
/// slice that compiles it.
fn staticOnly(cx: *m.Context, tree: *const m.Tree, n: m.Node.Index) m.Error!void {
    switch (tree.kind(n)) {
        .element => {
            const e = tree.element(n);
            for (tree.itemsOf(e.items)) |it| switch (it.kind) {
                .event => return refuse(cx, n, "an event handler", "S1", "§4"),
                .attribute, .escape => {
                    if (it.value.kind != .constant) return refuse(cx, n, "an attribute whose value is computed", "S1", "§5.3");
                    if (it.kind == .attribute and it.attribute != .none and tree.attributeFacts(it.attribute).stateful) {
                        return refuse(cx, n, "a controlled attribute (`value`, `checked`, `selected`)", "S4", "§8.1");
                    }
                },
                else => return refuse(cx, n, "this attribute", "S1", "§5"),
            };
            for (tree.childrenOf(e.children)) |c| try staticOnly(cx, tree, c);
        },
        .fragment => for (tree.childrenOf(tree.fragment(n).children)) |c| try staticOnly(cx, tree, c),
        .text => {},
        .hole => return refuse(cx, n, "a hole", "S1", "§5.1, §5.3"),
        .component => return refuse(cx, n, "a component", "S3", "§9.2"),
        .for_ => return refuse(cx, n, "a `For`", "S2", "§6"),
        .show => return refuse(cx, n, "a `Show`", "S4", "§5.5"),
        else => return refuse(cx, n, "this markup", "S1", "§5"),
    }
}

fn refuse(cx: *m.Context, n: m.Node.Index, what: []const u8, slice: []const u8, section: []const u8) m.Error!void {
    const message = try std.fmt.allocPrint(cx.arena, "`browser-direct` compiles a `view` of static markup only, and this is {s}: it arrives with slice {s} (`docs/design/browser-direct.md` {s}, §14). {s}", .{ what, slice, section, until_then });
    return cx.notImplemented(n, message);
}
