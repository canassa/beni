//! Reuse one generated call: its inlined body is another call with the
//! arguments reversed. Rewriting a pending duplicate with the old body
//! would reverse them again (#1782).
const m = @import("beni_markup");
pub const lowering: m.Lowering = .{
    .name = "shared-toy",
    .targets = .{ .major = 1, .minor = 0 },
    .runtime = &.{.{ .name = "flip", .arity = 2 }},
    .module = module,
    .root = root,
};
fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}
fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    cx.at(tree.root(index).node);
    const call = try cx.js.call(try cx.js.name(try cx.runtime("flip")), &.{ try cx.js.string("left"), try cx.js.string("right") });
    const joined = try cx.js.binary(.add, try cx.js.binary(.add, call, try cx.js.string("/")), call);
    return cx.js.object(&.{.{ .key = "t", .value = joined }});
}
