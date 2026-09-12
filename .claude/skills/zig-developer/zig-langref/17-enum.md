# enum


    const expect = @import("std").testing.expect;
    const expectEqual = @import("std").testing.expectEqual;
    const expectEqualStrings = @import("std").testing.expectEqualStrings;
    const mem = @import("std").mem;

    // Declare an enum.
    const Type = enum {
        ok,
        not_ok,
    };

    // Declare a specific enum field.
    const c = Type.ok;

    // If you want access to the ordinal value of an enum, you
    // can specify the tag type.
    const Value = enum(u2) {
        zero,
        one,
        two,
    };
    // Now you can cast between u2 and Value.
    // The ordinal value starts from 0, counting up by 1 from the previous member.
    test "enum ordinal value" {
        try expectEqual(0, @intFromEnum(Value.zero));
        try expectEqual(1, @intFromEnum(Value.one));
        try expectEqual(2, @intFromEnum(Value.two));
    }

    // You can override the ordinal value for an enum.
    const Value2 = enum(u32) {
        hundred = 100,
        thousand = 1000,
        million = 1000000,
    };
    test "set enum ordinal value" {
        try expectEqual(100, @intFromEnum(Value2.hundred));
        try expectEqual(1000, @intFromEnum(Value2.thousand));
        try expectEqual(1000000, @intFromEnum(Value2.million));
    }

    // You can also override only some values.
    const Value3 = enum(u4) {
        a,
        b = 8,
        c,
        d = 4,
        e,
    };
    test "enum implicit ordinal values and overridden values" {
        try expectEqual(0, @intFromEnum(Value3.a));
        try expectEqual(8, @intFromEnum(Value3.b));
        try expectEqual(9, @intFromEnum(Value3.c));
        try expectEqual(4, @intFromEnum(Value3.d));
        try expectEqual(5, @intFromEnum(Value3.e));
    }

    // Enums can have methods, the same as structs and unions.
    // Enum methods are not special, they are only namespaced
    // functions that you can call with dot syntax.
    const Suit = enum {
        clubs,
        spades,
        diamonds,
        hearts,

        pub fn isClubs(self: Suit) bool {
            return self == Suit.clubs;
        }
    };
    test "enum method" {
        const p = Suit.spades;
        try expect(!p.isClubs());
    }

    // An enum can be switched upon.
    const Foo = enum {
        string,
        number,
        none,
    };
    test "enum switch" {
        const p = Foo.number;
        const what_is_it = switch (p) {
            Foo.string => "this is a string",
            Foo.number => "this is a number",
            Foo.none => "this is a none",
        };
        try expectEqualStrings(what_is_it, "this is a number");
    }

    // @typeInfo can be used to access the integer tag type of an enum.
    const Small = enum {
        one,
        two,
        three,
        four,
    };
    test "std.meta.Tag" {
        try expectEqual(u2, @typeInfo(Small).@"enum".tag_type);
    }

    // @typeInfo tells us the field count and the fields names:
    test "@typeInfo" {
        try expectEqual(4, @typeInfo(Small).@"enum".fields.len);
        try expectEqualStrings(@typeInfo(Small).@"enum".fields[1].name, "two");
    }

    // @tagName gives a [:0]const u8 representation of an enum value:
    test "@tagName" {
        try expectEqualStrings(@tagName(Small.three), "three");
    }

test_enums.zig

    $ zig test test_enums.zig
    1/8 test_enums.test.enum ordinal value...OK
    2/8 test_enums.test.set enum ordinal value...OK
    3/8 test_enums.test.enum implicit ordinal values and overridden values...OK
    4/8 test_enums.test.enum method...OK
    5/8 test_enums.test.enum switch...OK
    6/8 test_enums.test.std.meta.Tag...OK
    7/8 test_enums.test.@typeInfo...OK
    8/8 test_enums.test.@tagName...OK
    All 8 tests passed.

Shell

See also:

- [@typeInfo](#typeInfo)
- [@tagName](#tagName)
- [@sizeOf](#sizeOf)

### [extern enum](#toc-extern-enum) [§](#extern-enum)

By default, enums are not guaranteed to be compatible with the C ABI:

    const Foo = enum { a, b, c };
    export fn entry(foo: Foo) void {
        _ = foo;
    }

enum_export_error.zig

    $ zig build-obj enum_export_error.zig -target x86_64-linux
    /home/andy/src/zig/doc/langref/enum_export_error.zig:2:17: error: parameter of type 'enum_export_error.Foo' not allowed in function with calling convention 'x86_64_sysv'
    export fn entry(foo: Foo) void {
                    ^~~~~~~~
    /home/andy/src/zig/doc/langref/enum_export_error.zig:1:13: note: integer tag type of enum is inferred
    const Foo = enum { a, b, c };
                ^~~~~~~~~~~~~~~~
    /home/andy/src/zig/doc/langref/enum_export_error.zig:1:13: note: consider explicitly specifying the integer tag type
    /home/andy/src/zig/doc/langref/enum_export_error.zig:1:13: note: enum declared here
    referenced by:
        root: /home/andy/src/zig/lib/std/start.zig:13:22
        comptime: /home/andy/src/zig/lib/std/start.zig:20:9
        2 reference(s) hidden; use '-freference-trace=4' to see all references

Shell

For a C-ABI-compatible enum, provide an explicit tag type to the enum:

    const Foo = enum(c_int) { a, b, c };
    export fn entry(foo: Foo) void {
        _ = foo;
    }

enum_export.zig

    $ zig build-obj enum_export.zig

Shell

### [Enum Literals](#toc-Enum-Literals) [§](#Enum-Literals)

Enum literals allow specifying the name of an enum field without specifying the enum type:

    const std = @import("std");
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    const Color = enum {
        auto,
        off,
        on,
    };

    test "enum literals" {
        const color1: Color = .auto;
        const color2 = Color.auto;
        try expectEqual(color1, color2);
    }

    test "switch using enum literals" {
        const color = Color.on;
        const result = switch (color) {
            .auto => false,
            .on => true,
            .off => false,
        };
        try expect(result);
    }

test_enum_literals.zig

    $ zig test test_enum_literals.zig
    1/2 test_enum_literals.test.enum literals...OK
    2/2 test_enum_literals.test.switch using enum literals...OK
    All 2 tests passed.

Shell

### [Non-exhaustive enum](#toc-Non-exhaustive-enum) [§](#Non-exhaustive-enum)

A non-exhaustive enum can be created by adding a trailing `_` field. The enum must specify a tag type and cannot consume every enumeration value.

[@enumFromInt](#enumFromInt) on a non-exhaustive enum involves the safety semantics of [@intCast](#intCast) to the integer tag type, but beyond that always results in a well-defined enum value.

A switch on a non-exhaustive enum can include a `_` prong as an alternative to an `else` prong. With a `_` prong the compiler errors if all the known tag names are not handled by the switch.

    const std = @import("std");
    const expect = std.testing.expect;

    const Number = enum(u8) {
        one,
        two,
        three,
        _,
    };

    test "switch on non-exhaustive enum" {
        const number = Number.one;
        const result = switch (number) {
            .one => true,
            .two, .three => false,
            _ => false,
        };
        try expect(result);
        const is_one = switch (number) {
            .one => true,
            else => false,
        };
        try expect(is_one);
    }

test_switch_non-exhaustive.zig

    $ zig test test_switch_non-exhaustive.zig
    1/1 test_switch_non-exhaustive.test.switch on non-exhaustive enum...OK
    All 1 tests passed.

Shell

