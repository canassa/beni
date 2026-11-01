//! Test-only host observation, generated as verified JsIr; never a native recipe.
const std = @import("std");
const Ir = @import("../js/JsIr.zig");
const Print = @import("../js/Print.zig");
const Pool = @import("../InternPool.zig");
const A = std.mem.Allocator;
const Node = Ir.Node;
const Maker = struct {
    a: A,
    b: Ir.Builder,
    names: Pool.Local,
    fn name(m: *Maker, text: []const u8) !Ir.NameIndex {
        return m.b.intern(Ir.Name.local(try m.names.getOrPut(m.a, text)));
    }
    fn node(m: *Maker, tag: Node.Tag, lhs: u32, rhs: u32) !Node.Index {
        return m.b.addParts(tag, Node.no_pos, lhs, rhs);
    }
    fn ident(m: *Maker, text: []const u8) !Node.Index {
        return m.node(.ident, @backingInt(try m.name(text)), Node.Data.unused);
    }
    fn member(m: *Maker, target: Node.Index, text: []const u8) !Node.Index {
        return m.node(.member, target.int(), @backingInt(try m.name(text)));
    }
    fn string(m: *Maker, text: []const u8) !Node.Index {
        const pair = try m.b.addString(text);
        return m.node(.string, pair[0], pair[1]);
    }
    fn call(m: *Maker, tag: Node.Tag, callee: Node.Index, args: []const Node.Index) !Node.Index {
        return m.node(tag, callee.int(), @backingInt(try m.b.addRecord(try m.b.addRange(args))));
    }
    fn arrow(m: *Maker, params: []const Ir.NameIndex, body: []const Node.Index) !Node.Index {
        const p = try m.b.addNames(params);
        const b = try m.b.addRange(body);
        const record = try m.b.addRecord(Ir.Func{ .params_start = p.start, .params_end = p.end, .body_start = b.start, .body_end = b.end });
        return m.node(.arrow, @backingInt(record), Node.Data.unused);
    }
    fn property(m: *Maker, key: []const u8, value: Node.Index) !Node.Index {
        return m.node(.property, @backingInt(try m.name(key)), value.int());
    }
    fn object(m: *Maker, fields: []const Node.Index) !Node.Index {
        const r = try m.b.addRange(fields);
        return m.node(.object, @backingInt(r.start), @backingInt(r.end));
    }
    fn log(m: *Maker, global: Node.Index, text: []const u8) !Node.Index {
        const function = try m.member(try m.member(global, "console"), "log");
        return m.node(.expr_stmt, (try m.call(.call, function, &.{try m.string(text)})).int(), Node.Data.unused);
    }
};
pub fn generate(a: A, throwing: bool) ![]u8 {
    var m: Maker = .{ .a = a, .b = .init(a), .names = try .init(a) };
    defer m.b.deinit();
    defer m.names.deinit(a);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const global = try m.node(.global_this, Node.Data.unused, Node.Data.unused);
    const original = try m.node(.const_decl, @backingInt(try m.name("original")), (try m.member(global, "TextEncoder")).int());
    const params = [_]Ir.NameIndex{ try m.name("target"), try m.name("args"), try m.name("newTarget") };
    const done = if (throwing)
        try m.node(.throw_stmt, (try m.call(.new_call, try m.member(global, "Error"), &.{try m.string("native host defect")})).int(), Node.Data.unused)
    else
        try m.node(.return_stmt, @backingInt((try m.call(.call, try m.member(try m.member(global, "Reflect"), "construct"), &.{ try m.ident("target"), try m.ident("args"), try m.ident("newTarget") })).toOptional()), Node.Data.unused);
    const trap = try m.arrow(&params, &.{ try m.log(global, "construct"), done });
    const handler = try m.object(&.{try m.property("construct", trap)});
    const proxy = try m.node(.const_decl, @backingInt(try m.name("proxy")), (try m.call(.new_call, try m.member(global, "Proxy"), &.{ try m.ident("original"), handler })).int());
    const getter = try m.arrow(&.{}, &.{ try m.log(global, "get"), try m.node(.return_stmt, @backingInt((try m.ident("proxy")).toOptional()), Node.Data.unused) });
    const descriptor = try m.object(&.{ try m.property("configurable", try m.node(.true_lit, Node.Data.unused, Node.Data.unused)), try m.property("get", getter) });
    const install = try m.node(.expr_stmt, (try m.call(.call, try m.member(try m.member(global, "Object"), "defineProperty"), &.{ global, try m.string("TextEncoder"), descriptor })).int(), Node.Data.unused);
    var ir = try m.b.toOwned(try m.b.addRange(&.{ original, proxy, install }));
    defer ir.deinit(a);
    try ir.verify();
    return Print.print(a, scratch.allocator(), &ir, .fromLocal(&m.names), .{});
}
test "native host observation fixture is verified JsIr and cleans allocation failures" {
    for ([_]bool{ false, true }) |throwing| {
        const expected = try generate(std.testing.allocator, throwing);
        defer std.testing.allocator.free(expected);
        // Exercise every relocation allocation deterministically, irrespective
        // of the backing allocator's incidental in-place resize opportunities.
        var backing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(backing.allocator(), struct {
            fn run(a: A, fail: bool, expected_bytes: []const u8) !void {
                const bytes = try generate(a, fail);
                defer a.free(bytes);
                try std.testing.expectEqualStrings(expected_bytes, bytes);
            }
        }.run, .{ throwing, expected });
    }
}

/// An ordinary foreign sibling; no attestation or native authority is supplied.
pub fn sibling(a: A, export_name: []const u8) ![]u8 {
    var m: Maker = .{ .a = a, .b = .init(a), .names = try .init(a) };
    defer m.b.deinit();
    defer m.names.deinit(a);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const global = try m.node(.global_this, Node.Data.unused, Node.Data.unused);
    const constructed = try m.call(.new_call, try m.member(global, "TextEncoder"), &.{});
    const ret = try m.node(.return_stmt, @backingInt(constructed.toOptional()), Node.Data.unused);
    const function = try m.arrow(&.{try m.name("unit")}, &.{ try m.log(global, "sibling"), ret });
    const exported = try m.name(export_name);
    const decl = try m.node(.const_decl, @backingInt(exported), function.int());
    const range = try m.b.addNames(&.{exported});
    const exports = try m.node(.export_stmt, @backingInt(range.start), @backingInt(range.end));
    var ir = try m.b.toOwned(try m.b.addRange(&.{ decl, exports }));
    defer ir.deinit(a);
    try ir.verify();
    return Print.print(a, scratch.allocator(), &ir, .fromLocal(&m.names), .{});
}
test "native host ordinary sibling preserves reserved logical export names" {
    for ([_][]const u8{ "new", "class", "default", "ordinary" }) |logical| {
        const bytes = try sibling(std.testing.allocator, logical);
        defer std.testing.allocator.free(bytes);
        const expected = if (std.mem.eql(u8, logical, "ordinary"))
            try std.fmt.allocPrint(std.testing.allocator, "export {{ {s} }};", .{logical})
        else
            try std.fmt.allocPrint(std.testing.allocator, "export {{ ${s} as {s} }};", .{ logical, logical });
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    }
}

/// Observe the REAL native getter through its original accessor; this is not a
/// replacement brand validator and preserves native receiver checks/defects.
pub fn getterObservation(a: A) ![]u8 {
    var m: Maker = .{ .a = a, .b = .init(a), .names = try .init(a) };
    defer m.b.deinit();
    defer m.names.deinit(a);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const global = try m.node(.global_this, Node.Data.unused, Node.Data.unused);
    const object = try m.member(global, "Object");
    const prototype = try m.node(.const_decl, @backingInt(try m.name("encoderPrototype")), (try m.member(try m.member(global, "TextEncoder"), "prototype")).int());
    const descriptor = try m.call(.call, try m.member(object, "getOwnPropertyDescriptor"), &.{ try m.ident("encoderPrototype"), try m.string("encoding") });
    const original = try m.node(.const_decl, @backingInt(try m.name("encodingGetter")), (try m.member(descriptor, "get")).int());
    const actual = try m.call(.call, try m.member(try m.ident("encodingGetter"), "call"), &.{try m.node(.this_lit, Node.Data.unused, Node.Data.unused)});
    const value = try m.node(.const_decl, @backingInt(try m.name("encodingValue")), actual.int());
    const log = try m.node(.expr_stmt, (try m.call(.call, try m.member(try m.member(global, "console"), "log"), &.{try m.ident("encodingValue")})).int(), Node.Data.unused);
    const method = try m.arrow(&.{}, &.{ value, log, try m.node(.return_stmt, @backingInt((try m.ident("encodingValue")).toOptional()), Node.Data.unused) });
    m.b.nodes.items(.data)[method.int()].rhs = Node.arrow_method;
    const replacement = try m.object(&.{ try m.property("configurable", try m.node(.true_lit, Node.Data.unused, Node.Data.unused)), try m.property("get", method) });
    const install = try m.node(.expr_stmt, (try m.call(.call, try m.member(object, "defineProperty"), &.{ try m.ident("encoderPrototype"), try m.string("encoding"), replacement })).int(), Node.Data.unused);
    var ir = try m.b.toOwned(try m.b.addRange(&.{ prototype, original, install }));
    defer ir.deinit(a);
    try ir.verify();
    return Print.print(a, scratch.allocator(), &ir, .fromLocal(&m.names), .{});
}

pub fn completeSibling(a: A) ![]u8 {
    const constructor = try sibling(a, "new");
    defer a.free(constructor);
    var m: Maker = .{ .a = a, .b = .init(a), .names = try .init(a) };
    defer m.b.deinit();
    defer m.names.deinit(a);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const value = try m.member(try m.ident("receiver"), "encoding");
    const body = try m.arrow(&.{try m.name("receiver")}, &.{try m.node(.return_stmt, @backingInt(value.toOptional()), Node.Data.unused)});
    const name = try m.name("encoding");
    const declaration = try m.node(.const_decl, @backingInt(name), body.int());
    const range = try m.b.addNames(&.{name});
    const exports = try m.node(.export_stmt, @backingInt(range.start), @backingInt(range.end));
    var ir = try m.b.toOwned(try m.b.addRange(&.{ declaration, exports }));
    defer ir.deinit(a);
    try ir.verify();
    const getter = try Print.print(a, scratch.allocator(), &ir, .fromLocal(&m.names), .{});
    defer a.free(getter);
    return std.mem.concat(a, u8, &.{ constructor, getter });
}
