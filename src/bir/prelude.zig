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
    const i = @intFromEnum(symbol);
    return if (i < WellKnown.count) @enumFromInt(i) else null;
}

/// True for the seven module aliases usable in qualified names.
pub fn isModule(w: WellKnown) bool {
    return switch (w) {
        .Basics, .List, .Maybe, .Result, .String, .Char, .Debug => true,
        else => false,
    };
}

/// The module that exposes `w` as a type, or null when `w` is not a prelude
/// type. `Char`, `String`, `List`, `Maybe` and `Result` are both a module
/// and a type of that module; the namespaces are separate (§5.3).
pub fn typeModule(w: WellKnown) ?WellKnown {
    return switch (w) {
        .Int, .Float, .Bool, .Char, .String, .Order, .Never => .Basics,
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
        .modBy,
        .remainderBy,
        .negate,
        .abs,
        .clamp,
        .sqrt,
        .logBase,
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

/// The prelude modules in Appendix A's order, for the import table's
/// prelude rows.
pub const modules = [_]WellKnown{ .Basics, .List, .Maybe, .Result, .String, .Char, .Debug };

test "every prelude name has exactly the namespaces Appendix A gives it" {
    // Counts from Appendix A: 7 modules, 10 types, 9 constructors, 36 values.
    var n_modules: u32 = 0;
    var n_types: u32 = 0;
    var n_ctors: u32 = 0;
    var n_values: u32 = 0;
    inline for (@typeInfo(WellKnown).@"enum".fields) |field| {
        const w: WellKnown = @enumFromInt(field.value);
        if (isModule(w)) n_modules += 1;
        if (typeModule(w) != null) n_types += 1;
        if (ctorModule(w) != null) n_ctors += 1;
        if (valueModule(w) != null) n_values += 1;
        // A name is a constructor or a value, never both; the operator
        // functions and `main` are neither.
        try std.testing.expect(!(ctorModule(w) != null and valueModule(w) != null));
    }
    try std.testing.expectEqual(@as(u32, 7), n_modules);
    try std.testing.expectEqual(@as(u32, 10), n_types);
    try std.testing.expectEqual(@as(u32, 9), n_ctors);
    try std.testing.expectEqual(@as(u32, 36), n_values);
    try std.testing.expectEqual(@as(?WellKnown, null), valueModule(.add));
    try std.testing.expectEqual(@as(?WellKnown, null), ctorModule(.main));
    try std.testing.expectEqual(@as(?WellKnown, .Maybe), ctorModule(.Just));
    try std.testing.expectEqual(@as(?WellKnown, .List), typeModule(.List));
    try std.testing.expect(isModule(.List));
    try std.testing.expectEqual(@as(?WellKnown, .max), wellKnown(WellKnown.max.symbol()));
    try std.testing.expectEqual(@as(?WellKnown, null), wellKnown(@enumFromInt(WellKnown.count)));
}
