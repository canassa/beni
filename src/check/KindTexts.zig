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

pub fn runtimeKind(r: *Reporter, region: Bir.Inst.Index, kind: TypeStore.Kind, actual: Var) Error!void {
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    out.writer.writeAll(if (kind == .record)
        "A Js.Cell needs a record row. This payload has type:\n\n    "
    else
        "A Js.Opt payload cannot itself be another Opt. This payload has type:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(&out.writer, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
    out.writer.writeAll(if (kind == .record)
        "\n\nUse a record of typed fields. A Cell has identity; record copy, update and\nstructural comparison do not apply to it.\n"
    else
        "\n\nJs.Opt cannot be an optional payload, including through aliases\nor generic instantiation. Use a tagged type to distinguish those cases.\n") catch return error.OutOfMemory;
    try r.emit(.kind_mismatch, region, &out);
}
