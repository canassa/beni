//! The prelude (docs/design/language.md Appendix A): the names in scope in
//! every module without an import, as a constant table inside the compiler.
//!
//! Every prelude name is a `WellKnown` symbol, and `InternPool.Local.init`
//! gives every worker's interner the same well-known prefix `Global` has, so
//! a symbol IS a prelude name exactly when its index is below
//! `WellKnown.count` and one of the functions below says so — no lookup, no
//! table walk, no per-file state. The functions are comptime-evaluable
//! switches; a name absent from Appendix A (the operator functions, `main`)
//! answers `null` in every namespace.
//!
//! What a prelude name resolves to is the form an explicit import would
//! produce: `import_value(Basics, max)`, `import_ctor(Maybe, Just)`,
//! `type_import(Basics, Int)`, so nothing downstream knows the prelude
//! exists. The home module of each name is what these functions return.

const std = @import("std");
const InternPool = @import("../InternPool.zig");
const Symbol = InternPool.Symbol;
const WellKnown = InternPool.WellKnown;

/// The `WellKnown` behind a symbol, when the symbol is in the well-known
/// prefix. Symbols at or past `WellKnown.count` are ordinary identifiers.
pub fn wellKnown(symbol: Symbol) ?WellKnown {
    const i = @backingInt(symbol);
    return if (i < WellKnown.count) @fromBackingInt(@intCast(i)) else null;
}

/// True for the nine module aliases usable in qualified names. `Int` and
/// `Float` are modules here and types of `Basics` (`typeModule`): the
/// modules hold `Int.mod`, `Int.rem` and `Float.log` and declare no type
/// (language.md §12.4, amended 2026-10-01).
pub fn isModule(w: WellKnown) bool {
    return switch (w) {
        .Basics, .List, .Maybe, .Result, .String, .Char, .Debug, .Int, .Float => true,
        else => false,
    };
}

/// The module that exposes `w` as a type, or null when `w` is not a prelude
/// type. `Char`, `String`, `List`, `Maybe` and `Result` are both a module
/// and a type of that module; the namespaces are separate (§5.3).
pub fn typeModule(w: WellKnown) ?WellKnown {
    return switch (w) {
        .Int, .Float, .Bool, .Order, .Never => .Basics,
        // `String` and `Char` are declared by their own modules
        // (static-dispatch-spike.md §5.1): under the module rule a type's
        // methods are its declaring module's `pub` values, and leaving them
        // in `Basics` would make `Basics.compare : number, number -> Order`
        // the `compare` of both.
        .String => .String,
        .Char => .Char,
        .List => .List,
        .Maybe => .Maybe,
        .Result => .Result,
        else => null,
    };
}

/// The module that exposes `w` as a constructor, or null.
pub fn ctorModule(w: WellKnown) ?WellKnown {
    return switch (w) {
        .True, .False, .LT, .EQ, .GT => .Basics,
        .Just, .Nothing => .Maybe,
        .Ok, .Err => .Result,
        else => null,
    };
}

/// The module that exposes `w` as a value, or null. Every prelude value is
/// from `Basics`. The operator functions (`add`, `cons`, …) are NOT prelude
/// values: operators are syntax and their functions are reached only
/// through desugaring, so a user may name a function `add`.
pub fn valueModule(w: WellKnown) ?WellKnown {
    return switch (w) {
        .toFloat,
        .round,
        .floor,
        .ceiling,
        .truncate,
        .max,
        .min,
        .compare,
        .not,
        .xor,
        .negate,
        .abs,
        .clamp,
        .sqrt,
        .e,
        .pi,
        .cos,
        .sin,
        .tan,
        .acos,
        .asin,
        .atan,
        .atan2,
        .degrees,
        .radians,
        .turns,
        .toPolar,
        .fromPolar,
        .isNaN,
        .isInfinite,
        .identity,
        .always,
        .never,
        => .Basics,
        else => null,
    };
}

/// A `Basics` value that left the language because its Elm name reads
/// backwards in subject-first order (language.md §12.4), and what replaced
/// it: `module.name`, with the arguments in the order they already had.
pub const Removed = struct {
    old: []const u8,
    module: []const u8,
    name: []const u8,
    /// The two arguments of the message's example call, in beni's order.
    subject: []const u8,
    other: []const u8,
};

/// The removed-names table (language.md §12.4): `--migrate-names` rewrites
/// each `old` to its replacement, and a use of one is `name_removed` —
/// lowering's for an unqualified name, resolution's for a qualified one or
/// an `exposing` entry, the checker's for a method.
pub const removed = [_]Removed{
    .{ .old = "modBy", .module = "Int", .name = "mod", .subject = "n", .other = "2" },
    .{ .old = "remainderBy", .module = "Int", .name = "rem", .subject = "n", .other = "3" },
    .{ .old = "logBase", .module = "Float", .name = "log", .subject = "x", .other = "10" },
};

/// `name_removed`'s message, the same from every phase that reports it.
pub fn writeRemoved(w: *std.Io.Writer, r: Removed) std.Io.Writer.Error!void {
    try w.print(
        \\`{s}` was removed: beni's `{s} {s} {s}` read as Elm's `{s} {s} {s}`. Write
        \\`{s}.{s} {s} {s}`, the arguments in the order they had. `{s}` is a prelude
        \\module, so it needs no import.
        \\
        \\`beni fmt --migrate-names <file>` rewrites every use in a file.
    , .{
        r.old,    r.old,  r.subject, r.other, r.old,    r.other, r.subject,
        r.module, r.name, r.subject, r.other, r.module,
    });
}

/// The table's row for `old`, or null.
pub fn removedName(old: []const u8) ?Removed {
    for (removed) |r| {
        if (std.mem.eql(u8, r.old, old)) return r;
    }
    return null;
}

/// The prelude modules in Appendix A's order, for the import table's
/// prelude rows.
pub const modules = [_]WellKnown{ .Basics, .List, .Maybe, .Result, .String, .Char, .Debug, .Int, .Float };

test "every prelude name has exactly the namespaces Appendix A gives it" {
    // Counts from Appendix A: 9 modules, 10 types, 9 constructors, 33 values.
    var n_modules: u32 = 0;
    var n_types: u32 = 0;
    var n_ctors: u32 = 0;
    var n_values: u32 = 0;
    inline for (@typeInfo(WellKnown).@"enum".field_values) |field_value| {
        const w: WellKnown = @fromBackingInt(@intCast(field_value));
        if (isModule(w)) n_modules += 1;
        if (typeModule(w) != null) n_types += 1;
        if (ctorModule(w) != null) n_ctors += 1;
        if (valueModule(w) != null) n_values += 1;
        // A name is a constructor or a value, never both; the operator
        // functions and `main` are neither.
        try std.testing.expect(!(ctorModule(w) != null and valueModule(w) != null));
    }
    try std.testing.expectEqual(@as(u32, 9), n_modules);
    try std.testing.expectEqual(@as(u32, 10), n_types);
    try std.testing.expectEqual(@as(u32, 9), n_ctors);
    try std.testing.expectEqual(@as(u32, 33), n_values);
    try std.testing.expectEqual(@as(?WellKnown, null), valueModule(.add));
    try std.testing.expectEqual(@as(?WellKnown, null), ctorModule(.main));
    try std.testing.expectEqual(@as(?WellKnown, .Maybe), ctorModule(.Just));
    try std.testing.expectEqual(@as(?WellKnown, .List), typeModule(.List));
    // `String` and `Char` are declared by their own modules
    // (static-dispatch-spike.md §5.1) and still resolve unqualified from
    // every module, because they are prelude TYPES either way.
    try std.testing.expectEqual(@as(?WellKnown, .String), typeModule(.String));
    try std.testing.expectEqual(@as(?WellKnown, .Char), typeModule(.Char));
    try std.testing.expect(isModule(.List));
    try std.testing.expectEqual(@as(?WellKnown, .max), wellKnown(WellKnown.max.symbol()));
    try std.testing.expectEqual(@as(?WellKnown, null), wellKnown(@fromBackingInt(@intCast(WellKnown.count))));
}
