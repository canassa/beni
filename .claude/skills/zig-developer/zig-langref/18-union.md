# union


A bare `union` defines a set of possible types that a value can be as a list of fields. Only one field can be active at a time. The in-memory representation of bare unions is not guaranteed. Bare unions cannot be used to reinterpret memory. For that, use [@ptrCast](#ptrCast), or use an [extern union](#extern-union) or a [packed union](#packed-union) which have guaranteed in-memory layout. [Accessing the non-active field](#Wrong-Union-Field-Access) is safety-checked [Illegal Behavior](#Illegal-Behavior):

    const Payload = union {
        int: i64,
        float: f64,
        boolean: bool,
    };
    test "simple union" {
        var payload = Payload{ .int = 1234 };
        payload.float = 12.34;
    }

test_wrong_union_access.zig

    $ zig test test_wrong_union_access.zig
    1/1 test_wrong_union_access.test.simple union...thread 933934 panic: access of union field 'float' while field 'int' is active
    /home/andy/src/zig/doc/langref/test_wrong_union_access.zig:8:12: 0x1234e62 in test.simple union (test_wrong_union_access.zig)
        payload.float = 12.34;
               ^
    /home/andy/src/zig/lib/compiler/test_runner.zig:291:25: 0x11ef546 in mainTerminal (test_runner.zig)
            if (test_fn.func()) |_| {
                            ^
    /home/andy/src/zig/lib/compiler/test_runner.zig:73:28: 0x11eed62 in main (test_runner.zig)
            return mainTerminal(init);
                               ^
    /home/andy/src/zig/lib/std/start.zig:686:88: 0x11eb6c6 in callMain (std.zig)
        if (fn_info.params[0].type.? == std.process.Init.Minimal) return wrapMain(root.main(.{
                                                                                           ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11eb0d1 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    error: the following test command terminated with signal ABRT:
    /home/andy/src/zig/.zig-cache/o/a910feedacc78c90cf0c411c52cd47d5/test --seed=0x39660e11

Shell

You can activate another field by assigning the entire union:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const Payload = union {
        int: i64,
        float: f64,
        boolean: bool,
    };
    test "simple union" {
        var payload = Payload{ .int = 1234 };
        try expectEqual(1234, payload.int);
        payload = Payload{ .float = 12.34 };
        try expectEqual(12.34, payload.float);
    }

test_simple_union.zig

    $ zig test test_simple_union.zig
    1/1 test_simple_union.test.simple union...OK
    All 1 tests passed.

Shell

In order to use [switch](#switch) with a union, it must be a [Tagged union](#Tagged-union).

To initialize a union when the tag is a [comptime](#comptime)-known name, see [@unionInit](#unionInit).

### [Tagged union](#toc-Tagged-union) [§](#Tagged-union)

Unions can be declared with an enum tag type. This turns the union into a *tagged* union, which makes it eligible to use with [switch](#switch) expressions. When switching on tagged unions, the tag value can be obtained using an additional capture. Tagged unions coerce to their tag type: [Type Coercion: Unions and Enums](#Type-Coercion-Unions-and-Enums).

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const ComplexTypeTag = enum {
        ok,
        not_ok,
    };
    const ComplexType = union(ComplexTypeTag) {
        ok: u8,
        not_ok: void,
    };

    test "switch on tagged union" {
        const c = ComplexType{ .ok = 42 };
        try expectEqual(ComplexTypeTag.ok, @as(ComplexTypeTag, c));

        switch (c) {
            .ok => |value| try expectEqual(42, value),
            .not_ok => unreachable,
        }

        switch (c) {
            .ok => |_, tag| {
                // Because we're in the '.ok' prong, 'tag' is compile-time known to be '.ok':
                comptime std.debug.assert(tag == .ok);
            },
            .not_ok => unreachable,
        }
    }

    test "get tag type" {
        try expectEqual(ComplexTypeTag, std.meta.Tag(ComplexType));
    }

test_tagged_union.zig

    $ zig test test_tagged_union.zig
    1/2 test_tagged_union.test.switch on tagged union...OK
    2/2 test_tagged_union.test.get tag type...OK
    All 2 tests passed.

Shell

In order to modify the payload of a tagged union in a switch expression, place a `*` before the variable name to make it a pointer:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const ComplexTypeTag = enum {
        ok,
        not_ok,
    };
    const ComplexType = union(ComplexTypeTag) {
        ok: u8,
        not_ok: void,
    };

    test "modify tagged union in switch" {
        var c = ComplexType{ .ok = 42 };

        switch (c) {
            ComplexTypeTag.ok => |*value| value.* += 1,
            ComplexTypeTag.not_ok => unreachable,
        }

        try expectEqual(43, c.ok);
    }

test_switch_modify_tagged_union.zig

    $ zig test test_switch_modify_tagged_union.zig
    1/1 test_switch_modify_tagged_union.test.modify tagged union in switch...OK
    All 1 tests passed.

Shell

Unions can be made to infer the enum tag type. Further, unions can have methods just like structs and enums.

    const std = @import("std");
    const expect = std.testing.expect;

    const Variant = union(enum) {
        int: i32,
        boolean: bool,

        // void can be omitted when inferring enum tag type.
        none,

        fn truthy(self: Variant) bool {
            return switch (self) {
                Variant.int => |x_int| x_int != 0,
                Variant.boolean => |x_bool| x_bool,
                Variant.none => false,
            };
        }
    };

    test "union method" {
        var v1: Variant = .{ .int = 1 };
        var v2: Variant = .{ .boolean = false };
        var v3: Variant = .none;

        try expect(v1.truthy());
        try expect(!v2.truthy());
        try expect(!v3.truthy());
    }

test_union_method.zig

    $ zig test test_union_method.zig
    1/1 test_union_method.test.union method...OK
    All 1 tests passed.

Shell

Unions with inferred enum tag types can also assign ordinal values to their inferred tag. This requires the tag to specify an explicit integer type. [@intFromEnum](#intFromEnum) can be used to access the ordinal value corresponding to the active field.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const Tagged = union(enum(u32)) {
        int: i64 = 123,
        boolean: bool = 67,
    };

    test "tag values" {
        const int: Tagged = .{ .int = -40 };
        try expectEqual(123, @intFromEnum(int));

        const boolean: Tagged = .{ .boolean = false };
        try expectEqual(67, @intFromEnum(boolean));
    }

test_tagged_union_with_tag_values.zig

    $ zig test test_tagged_union_with_tag_values.zig
    1/1 test_tagged_union_with_tag_values.test.tag values...OK
    All 1 tests passed.

Shell

[@tagName](#tagName) can be used to return a [comptime](#comptime) `[:``0``]``const`` ``u8` value representing the field name:

    const std = @import("std");
    const expectEqualSlices = std.testing.expectEqualSlices;

    const Small2 = union(enum) {
        a: i32,
        b: bool,
        c: u8,
    };
    test "@tagName" {
        try expectEqualSlices(u8, "a", @tagName(Small2.a));
    }

test_tagName.zig

    $ zig test test_tagName.zig
    1/1 test_tagName.test.@tagName...OK
    All 1 tests passed.

Shell

### [extern union](#toc-extern-union) [§](#extern-union)

An `extern`` ``union` has memory layout guaranteed to be compatible with the target C ABI.

See also:

- [extern struct](#extern-struct)

### [packed union](#toc-packed-union) [§](#packed-union)

A `packed`` ``union` has well-defined in-memory layout and is eligible to be in a [packed struct](#packed-struct).

All fields in a packed union must have the same [@bitSizeOf](#bitSizeOf).

Equating packed unions results in a comparison of the backing integer, and only works for the `==` and `!=` [Operators](#Operators).

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "packed union equality" {
        const U = packed union {
            a: u4,
            b: i4,
        };
        const x: U = .{ .a = 3 };
        const y: U = .{ .b = 3 };
        try expectEqual(x, y);
    }

test_packed_union_equality.zig

    $ zig test test_packed_union_equality.zig
    1/1 test_packed_union_equality.test.packed union equality...OK
    All 1 tests passed.

Shell

### [Anonymous Union Literals](#toc-Anonymous-Union-Literals) [§](#Anonymous-Union-Literals)

[Anonymous Struct Literals](#Anonymous-Struct-Literals) syntax can be used to initialize unions without specifying the type:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const Number = union {
        int: i32,
        float: f64,
    };

    test "anonymous union literal syntax" {
        const i: Number = .{ .int = 42 };
        const f = makeNumber();
        try expectEqual(42, i.int);
        try expectEqual(12.34, f.float);
    }

    fn makeNumber() Number {
        return .{ .float = 12.34 };
    }

test_anonymous_union.zig

    $ zig test test_anonymous_union.zig
    1/1 test_anonymous_union.test.anonymous union literal syntax...OK
    All 1 tests passed.

Shell

