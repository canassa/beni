//! Generate the native opaque-callback/control fixtures through the ordinary JsIr
//! verifier/printer. Black-box tests consume its bytes, not compiler internals.
const std = @import("std");
const Ir = @import("js/JsIr.zig");
const Print = @import("js/Print.zig");
const Pool = @import("InternPool.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedOutputPath;
    var b: Ir.Builder = .init(a);
    var names: Pool.Local = try .init(a);
    const exported = try b.intern(.local(try names.getOrPut(a, "opaqueCallback")));
    const unit = try b.intern(.local(try names.getOrPut(a, "unit")));
    const context = try b.intern(.local(try names.getOrPut(a, "context")));
    const value = try b.intern(.local(try names.getOrPut(a, "value")));
    const ident = try b.addParts(.ident, Ir.Node.no_pos, @backingInt(value), 0);
    const returned_value = try b.addParts(.return_stmt, Ir.Node.no_pos, ident.int(), 0);
    const params = try b.addNames(&.{ context, value });
    const body = try b.addRange(&.{returned_value});
    const function = try b.addRecord(Ir.Func{ .params_start = params.start, .params_end = params.end, .body_start = body.start, .body_end = body.end });
    const arrow = try b.addParts(.arrow, Ir.Node.no_pos, @backingInt(function), Ir.Node.arrow_plain);
    const returned_callback = try b.addParts(.return_stmt, Ir.Node.no_pos, arrow.int(), 0);
    const factory_params = try b.addNames(&.{unit});
    const factory_body = try b.addRange(&.{returned_callback});
    const factory = try b.addRecord(Ir.Func{ .params_start = factory_params.start, .params_end = factory_params.end, .body_start = factory_body.start, .body_end = factory_body.end });
    const factory_arrow = try b.addParts(.arrow, Ir.Node.no_pos, @backingInt(factory), Ir.Node.arrow_plain);
    const declaration = try b.addParts(.const_decl, Ir.Node.no_pos, @backingInt(exported), factory_arrow.int());
    const input = try b.intern(.local(try names.getOrPut(a, "input")));
    const date = try b.intern(.local(try names.getOrPut(a, "Date")));
    const now = try b.intern(.local(try names.getOrPut(a, "now")));
    const date_ident = try b.addParts(.ident, Ir.Node.no_pos, @backingInt(date), 0);
    const method = try b.addParts(.member, Ir.Node.no_pos, date_ident.int(), @backingInt(now));
    const empty = try b.addRange(&.{});
    const call_args = try b.addRecord(empty);
    const clock = try b.addParts(.call, Ir.Node.no_pos, method.int(), @backingInt(call_args));
    const input_return = try b.addParts(.return_stmt, Ir.Node.no_pos, clock.int(), 0);
    const input_body = try b.addRange(&.{input_return});
    const input_func = try b.addRecord(Ir.Func{ .params_start = factory_params.start, .params_end = factory_params.end, .body_start = input_body.start, .body_end = input_body.end });
    const input_arrow = try b.addParts(.arrow, Ir.Node.no_pos, @backingInt(input_func), Ir.Node.arrow_plain);
    const input_decl = try b.addParts(.const_decl, Ir.Node.no_pos, @backingInt(input), input_arrow.int());
    const export_names = try b.addNames(&.{ exported, input });
    const exports = try b.addParts(.export_stmt, Ir.Node.no_pos, @backingInt(export_names.start), @backingInt(export_names.end));
    var ir = try b.toOwned(try b.addRange(&.{ declaration, input_decl, exports }));
    try ir.verify();
    const bytes = try Print.print(a, a, &ir, .fromLocal(&names), .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
}
