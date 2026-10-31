//! Generate the actual sibling for core Js.Buffer using the ordinary JsIr
//! printer. Foreign export and arity checks remain the same for these typed
//! compiler intrinsics and their first-class fallback implementations.
const std = @import("std");
const JsIr = @import("js/JsIr.zig");
const Print = @import("js/Print.zig");
const InternPool = @import("InternPool.zig");

const Node = JsIr.Node;
const Index = Node.Index;
const NameIndex = JsIr.NameIndex;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedOutputPath;
    var g: Generator = .{ .a = a, .b = .init(a), .names = try .init(a) };
    const bytes = try g.generate();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
}

const Generator = struct {
    a: std.mem.Allocator,
    b: JsIr.Builder,
    names: InternPool.Local,

    fn add(g: *Generator, tag: Node.Tag, lhs: u32, rhs: u32) !Index {
        return g.b.addParts(tag, Node.no_pos, lhs, rhs);
    }

    fn name(g: *Generator, text: []const u8) !NameIndex {
        return g.b.intern(.local(try g.names.getOrPut(g.a, text)));
    }

    fn ident(g: *Generator, text: []const u8) !Index {
        return g.add(.ident, @backingInt(try g.name(text)), 0);
    }

    fn member(g: *Generator, object: Index, text: []const u8) !Index {
        return g.add(.member, object.int(), @backingInt(try g.name(text)));
    }

    fn call(g: *Generator, callee: Index, args: []const Index) !Index {
        const range = try g.b.addRange(args);
        const extra = try g.b.addRecord(range);
        return g.add(.call, callee.int(), @backingInt(extra));
    }

    fn arrow(g: *Generator, params: []const []const u8, body: []const Index) !Index {
        var ns: std.ArrayList(NameIndex) = .empty;
        for (params) |text| try ns.append(g.a, try g.name(text));
        const ps = try g.b.addNames(ns.items);
        const bs = try g.b.addRange(body);
        const record = try g.b.addRecord(JsIr.Func{
            .params_start = ps.start,
            .params_end = ps.end,
            .body_start = bs.start,
            .body_end = bs.end,
        });
        return g.add(.arrow, @backingInt(record), Node.arrow_plain);
    }

    fn decl(g: *Generator, text: []const u8, function: Index) !Index {
        return g.add(.const_decl, @backingInt(try g.name(text)), function.int());
    }

    fn generate(g: *Generator) ![]const u8 {
        const empty = try g.b.addRange(&.{});
        const array = try g.add(.array, @backingInt(empty.start), @backingInt(empty.end));
        const make = try g.decl("make", try g.arrow(&.{"unit"}, &.{try g.add(.return_stmt, array.int(), 0)}));
        const buffer = try g.ident("buffer");
        const value = try g.ident("value");
        const push_call = try g.call(try g.member(buffer, "push"), &.{value});
        const push = try g.decl("push", try g.arrow(&.{ "buffer", "value" }, &.{try g.add(.expr_stmt, push_call.int(), 0)}));
        const size = try g.member(buffer, "length");
        const length = try g.decl("length", try g.arrow(&.{"buffer"}, &.{try g.add(.return_stmt, size.int(), 0)}));
        const body_call = try g.call(try g.ident("body"), &.{value});
        const for_body = try g.b.addRange(&.{try g.add(.expr_stmt, body_call.int(), 0)});
        const for_record = try g.b.addRecord(JsIr.ForOf{ .iterable = buffer, .body_start = for_body.start, .body_end = for_body.end });
        const loop = try g.add(.for_of, @backingInt(try g.name("value")), @backingInt(for_record));
        const each = try g.decl("forEach", try g.arrow(&.{ "buffer", "body" }, &.{loop}));
        const stop = try g.add(.unary, body_call.int(), @backingInt(JsIr.UnaryOp.not));
        const breaking = try g.b.addRange(&.{try g.add(.break_stmt, @backingInt(NameIndex.none), 0)});
        const no_else = try g.b.addRange(&.{});
        const stop_if = try g.b.addRecord(JsIr.If{ .then_start = breaking.start, .then_end = breaking.end, .else_start = no_else.start, .else_end = no_else.end });
        const while_body = try g.b.addRange(&.{try g.add(.if_stmt, stop.int(), @backingInt(stop_if))});
        const while_record = try g.b.addRecord(JsIr.ForOf{ .iterable = buffer, .body_start = while_body.start, .body_end = while_body.end });
        const while_loop = try g.add(.for_of, @backingInt(try g.name("value")), @backingInt(while_record));
        const each_while = try g.decl("forEachWhile", try g.arrow(&.{ "buffer", "body" }, &.{while_loop}));
        const exports = try g.b.addNames(&.{ try g.name("make"), try g.name("push"), try g.name("length"), try g.name("forEach"), try g.name("forEachWhile") });
        const export_stmt = try g.add(.export_stmt, @backingInt(exports.start), @backingInt(exports.end));
        const top = try g.b.addRange(&.{ make, push, length, each, each_while, export_stmt });
        var ir = try g.b.toOwned(top);
        try ir.verify();
        return Print.print(g.a, g.a, &ir, .fromLocal(&g.names), .{});
    }
};
