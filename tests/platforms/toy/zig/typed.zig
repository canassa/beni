//! A consumer of checked capture evidence, separate from the original toy
//! lowering so its emitted output remains an independent compatibility test.
const m = @import("beni_markup");
pub const lowering: m.Lowering = .{
    .name = "typed-toy",
    .targets = .{ .major = 1, .minor = 25 },
    .operand_evidence = .{ .identity = true, .checked_data = true },
    .runtime = &.{
        .{ .name = "inspect", .arity = 1 },
        .{ .name = "first", .arity = 1 },
        .{ .name = "sample", .arity = 1 },
        .{ .name = "keyValue", .arity = 1 },
        .{ .name = "capture", .arity = 2 },
        .{ .name = "restore", .arity = 2 },
        .{ .name = "data", .arity = 1 },
    },
    .module = module,
    .root = root,
};
fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}
fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const node = tree.root(index).node;
    cx.at(node);
    if (tree.kind(node) != .for_) return cx.report(node, "Expected a For capture.");
    const row = tree.for_(node);
    const each = try cx.value(row.each);
    const a = try cx.evidence(row.each, &.{ .list_item, .{ .tuple_field = 3 }, .{ .record_field = "sample" } }, .identity);
    const a_from_callback = try cx.evidence(row.each, &.{ .list_item, .{ .tuple_field = 3 }, .{ .record_field = "keyOf" }, .{ .function_param = 0 } }, .identity);
    const k = try cx.evidence(row.each, &.{ .list_item, .{ .tuple_field = 3 }, .{ .record_field = "keyOf" }, .function_result }, .identity);
    const checked = try cx.evidence(row.each, &.{ .list_item, .{ .tuple_field = 3 }, .{ .record_field = "sample" } }, .checked_data);
    const one = try cx.js.call(try cx.suppliedRuntime("inspect", &.{ a, k }), &.{each});
    const two = try cx.js.call(try cx.suppliedRuntime("inspect", &.{ a_from_callback, k }), &.{each});
    const first = try cx.js.call(try cx.js.name(try cx.runtime("first")), &.{each});
    const pair = try cx.maybe(first);
    const sample = try cx.js.call(try cx.js.name(try cx.runtime("sample")), &.{each});
    const id = try cx.js.call(try cx.js.name(try cx.runtime("keyValue")), &.{each});
    const packet = try cx.js.object(&.{ .{ .key = "a", .value = sample }, .{ .key = "b", .value = id } });
    const packet_type = try cx.tupleEvidence(&.{ a, k }, .identity);
    const capture = try cx.js.call(try cx.suppliedRuntime("capture", &.{packet_type}), &.{ try cx.js.member(pair, "c"), packet });
    const saved_packet = try cx.packet(packet, packet_type);
    const restored = try cx.js.call(try cx.suppliedRuntime("restore", &.{packet_type}), &.{ saved_packet, packet });
    const data = try cx.js.call(try cx.suppliedRuntime("data", &.{checked}), &.{sample});
    var result = try cx.js.binary(.add, try cx.js.binary(.add, one, try cx.js.string("/")), two);
    result = try cx.js.binary(.add, result, try cx.js.string("/"));
    result = try cx.js.binary(.add, result, capture);
    result = try cx.js.binary(.add, result, try cx.js.string("/"));
    result = try cx.js.binary(.add, result, data);
    result = try cx.js.binary(.add, result, try cx.js.string("/"));
    result = try cx.js.binary(.add, result, restored);
    result = try cx.js.cond(try cx.isJust(first), result, try cx.js.string("empty"));
    return cx.js.object(&.{.{ .key = "t", .value = result }});
}

pub const packet_nonfresh = badLowering("typed-packet-nonfresh", nonfresh);
pub const packet_call = badLowering("typed-packet-call", callResult);
pub const packet_data = badLowering("typed-packet-data", dataEvidence);
pub const packet_forged = badLowering("typed-packet-forged", forged);

fn badLowering(name: []const u8, emit: *const fn (*m.Context, *const m.Tree, m.Root.Index) m.Error!m.Expr) m.Lowering {
    var result = lowering;
    result.name = name;
    result.root = emit;
    return result;
}

fn nonfresh(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const node = tree.root(index).node;
    cx.at(node);
    const each = tree.for_(node).each;
    const identity = try cx.evidence(each, &.{}, .identity);
    return cx.packet(try cx.value(each), identity);
}

fn callResult(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const node = tree.root(index).node;
    cx.at(node);
    const each = tree.for_(node).each;
    const identity = try cx.evidence(each, &.{}, .identity);
    const value = try cx.js.call(try cx.js.name(try cx.runtime("first")), &.{try cx.value(each)});
    return cx.packet(value, identity);
}

fn dataEvidence(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const node = tree.root(index).node;
    cx.at(node);
    const evidence = try cx.evidence(tree.for_(node).each, &.{}, .checked_data);
    return cx.packet(try cx.js.object(&.{}), evidence);
}

fn forged(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    cx.at(tree.root(index).node);
    return cx.packet(try cx.js.object(&.{}), @fromBackingInt(0xffffffff));
}

pub const packet_only: m.Lowering = .{
    .name = "typed-packet-only",
    .targets = .{ .major = 1, .minor = 25 },
    .operand_evidence = .{ .identity = true },
    .runtime = &.{.{ .name = "restore", .arity = 1 }},
    .module = module,
    .root = packetOnly,
};

fn packetOnly(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    const node = tree.root(index).node;
    cx.at(node);
    const string = try cx.evidence(tree.for_(node).each, &.{.list_item}, .identity);
    const identity = try cx.tupleEvidence(&.{ string, string }, .identity);
    const fresh = try cx.js.object(&.{
        .{ .key = "a", .value = try cx.js.string("left") },
        .{ .key = "b", .value = try cx.js.string("right") },
    });
    const saved = try cx.packet(fresh, identity);
    const result = try cx.js.call(try cx.js.name(try cx.runtime("restore")), &.{saved});
    return cx.js.object(&.{.{ .key = "t", .value = result }});
}
