//! Diagnostics for closed kind constraints, including Dict and Set keys.
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");
const Render = @import("Render.zig");
const Reporter = @import("Diagnostics.zig").Reporter;
const Error = Reporter.Error;
const Var = TypeStore.Var;

pub fn invalidDictKey(r: *Reporter, region: Bir.Inst.Index, actual: Var) Error!void {
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    out.writer.writeAll("Dict keys and Set members must be Int or String.\n\nThis key has type:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(&out.writer, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
    out.writer.writeAll("\n\nAn alias of Int or String is accepted. Other types cannot be keys, even\nwhen they have eq or compare.\n") catch return error.OutOfMemory;
    try r.emit(.invalid_dict_key, region, &out);
}

pub fn keyScalarMismatch(r: *Reporter, region: Bir.Inst.Index, kind: TypeStore.Kind, actual: Var) Error!void {
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    out.writer.print("This use requires {s} key, but this key has type:\n\n    ", .{if (kind == .int_key) "an Int" else "a String"}) catch return error.OutOfMemory;
    Render.writeVar(&out.writer, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    try r.emit(.kind_mismatch, region, &out);
}
pub fn kindMismatch(r: *Reporter, region: Bir.Inst.Index, left: TypeStore.Kind, right: TypeStore.Kind) Error!void {
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    w.print(
        \\This value has to be `{s}` and `{s}` at the same time, and nothing is both.
        \\
        \\`number` is `Int` or `Float`; `appendable` is `String` or `List a`.
        \\
    , .{ left.text(), right.text() }) catch return error.OutOfMemory;
    try r.emit(.kind_mismatch, region, &out);
}
