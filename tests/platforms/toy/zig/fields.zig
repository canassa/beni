//! The Source record namespace crosses a generated/runtime boundary in
//! development and release without pinning native ABI properties.
const m = @import("beni_markup");

pub const lowering: m.Lowering = .{
    .name = "source-fields-toy",
    .targets = .{ .major = 1, .minor = 27 },
    .runtime = &.{
        .{ .name = "read", .arity = 1 },
        .{ .name = "make", .arity = 1 },
    },
    .module = module,
    .root = root,
};

fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}

fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    cx.at(tree.root(index).node);
    const record = try cx.js.object(&.{
        .{ .key = "producerValue", .value = try cx.js.string("left"), .source = true },
        .{ .key = "a", .value = try cx.js.string("native") },
    });
    const read = try cx.js.call(try cx.js.name(try cx.runtime("read")), &.{record});
    const made = try cx.js.call(try cx.js.name(try cx.runtime("make")), &.{try cx.js.string("right")});
    const prefix = try cx.js.binary(.add, try cx.js.binary(.add, read, try cx.js.string("/")), try cx.js.member(record, "a"));
    const result = try cx.js.binary(.add, try cx.js.binary(.add, prefix, try cx.js.string("/")), try cx.js.field(made, "consumerValue"));
    return cx.js.object(&.{.{ .key = "t", .value = result }});
}
