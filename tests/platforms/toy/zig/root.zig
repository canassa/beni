//! The toy platform's Zig: one markup lowering, `toy`, written against the
//! interface as any lowering outside beni's tree is — `beni_markup`, `std`
//! and the `html` platform's module, nothing else (docs/design/boundary.md
//! §9.5). It renders `<p>Hi {name}</p>` as `p["Hi " "you"]`: an element as
//! its tag and its content in brackets through a helper it hoists, a text
//! hole quoted by its runtime, and every element's tag contributed as
//! program start data.

const std = @import("std");
const m = @import("beni_markup");
const parser = @import("platform_html").parser_table;

pub const lowerings = [_]m.Lowering{.{
    .name = "toy",
    .targets = .{ .major = 1, .minor = 0 },
    .runtime = &.{
        .{ .name = "start", .arity = 1 },
        .{ .name = "quote", .arity = 1 },
    },
    .module = module,
    .root = root,
}};

/// `wrap`, hoisted once per module: `(tag, inner) => tag + "[" + inner + "]"`.
fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = tree;
    const tag = try cx.fresh("tag");
    const inner = try cx.fresh("inner");
    const body = try cx.js.block();
    const open = try cx.js.binary(.add, try cx.js.name(tag), try cx.js.string("["));
    const close = try cx.js.binary(.add, try cx.js.binary(.add, open, try cx.js.name(inner)), try cx.js.string("]"));
    try cx.js.@"return"(body, close);
    _ = try cx.hoistFunction("wrap", &.{ tag, inner }, body);
}

fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const text = try render(cx, tree, tree.root(index).node);
    return cx.js.object(&.{.{ .key = "t", .value = text }});
}

fn render(cx: *m.Context, tree: *const m.Tree, n: m.Node.Index) m.Error!m.Expr {
    cx.at(n);
    switch (tree.kind(n)) {
        .element => {
            const e = tree.element(n);
            const tag = tree.string(tree.elementFacts(e.row).name);
            try cx.start("tag", tag);
            const wrap = try hoisted(cx);
            const shown = if (parser.isVoid(tag)) try std.fmt.allocPrint(cx.arena, "{s}/", .{tag}) else tag;
            return cx.js.call(wrap, &.{ try cx.js.string(shown), try children(cx, tree, tree.childrenOf(e.children)) });
        },
        .fragment => return children(cx, tree, tree.childrenOf(tree.fragment(n).children)),
        .text => return cx.js.string(try std.fmt.allocPrint(cx.arena, "\"{s}\"", .{tree.string(tree.text(n).text)})),
        .hole => {
            const h = tree.hole(n);
            const value = try cx.value(h.value);
            return switch (h.kind) {
                .html => cx.js.member(value, "t"),
                .text_string, .text_number, .text_char, .text_bool => cx.js.call(try cx.js.name(try cx.runtime("quote")), &.{value}),
                else => cx.report(n, "The toy lowering renders a hole of text or of one markup value only."),
            };
        },
        else => return cx.report(n, "The toy lowering renders elements, fragments, text and holes only."),
    }
}

/// The helper `module` hoisted, read back by its hint: a lowering keeps no
/// state of its own between calls.
fn hoisted(cx: *m.Context) m.Error!m.Expr {
    return cx.js.name(cx.hoisted("wrap").?);
}

fn children(cx: *m.Context, tree: *const m.Tree, nodes: []const m.Node.Index) m.Error!m.Expr {
    var joined = try cx.js.string("");
    for (nodes, 0..) |child, i| {
        const next = try render(cx, tree, child);
        joined = if (i == 0) next else try cx.js.binary(.add, try cx.js.binary(.add, joined, try cx.js.string(" ")), next);
    }
    return joined;
}
