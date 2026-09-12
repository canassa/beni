# Casting


A **type cast** converts a value of one type to another. Zig has [Type Coercion](#Type-Coercion) for conversions that are known to be completely safe and unambiguous, and [Explicit Casts](#Explicit-Casts) for conversions that one would not want to happen on accident. There is also a third kind of type conversion called [Peer Type Resolution](#Peer-Type-Resolution) for the case when a result type must be decided given multiple operand types.

### [Type Coercion](#toc-Type-Coercion) [§](#Type-Coercion)

Type coercion occurs when one type is expected, but different type is provided:

    test "type coercion - variable declaration" {
        const a: u8 = 1;
        const b: u16 = a;
        _ = b;
    }

    test "type coercion - function call" {
        const a: u8 = 1;
        foo(a);
    }

    fn foo(b: u16) void {
        _ = b;
    }

    test "type coercion - @as builtin" {
        const a: u8 = 1;
        const b = @as(u16, a);
        _ = b;
    }

test_type_coercion.zig

    $ zig test test_type_coercion.zig
    1/3 test_type_coercion.test.type coercion - variable declaration...OK
    2/3 test_type_coercion.test.type coercion - function call...OK
    3/3 test_type_coercion.test.type coercion - @as builtin...OK
    All 3 tests passed.

Shell

Type coercions are only allowed when it is completely unambiguous how to get from one type to another, and the transformation is guaranteed to be safe. There is one exception, which is [C Pointers](#C-Pointers).

#### [Type Coercion: Stricter Qualification](#toc-Type-Coercion-Stricter-Qualification) [§](#Type-Coercion-Stricter-Qualification)

Values which have the same representation at runtime can be cast to increase the strictness of the qualifiers, no matter how nested the qualifiers are:

- `const` - non-const to const is allowed
- `volatile` - non-volatile to volatile is allowed
- `align` - bigger to smaller alignment is allowed
- [error sets](#Error-Set-Type) to supersets is allowed

These casts are no-ops at runtime since the value representation does not change.

    test "type coercion - const qualification" {
        var a: i32 = 1;
        const b: *i32 = &a;
        foo(b);
    }

    fn foo(_: *const i32) void {}

test_no_op_casts.zig

    $ zig test test_no_op_casts.zig
    1/1 test_no_op_casts.test.type coercion - const qualification...OK
    All 1 tests passed.

Shell

In addition, pointers coerce to const optional pointers:

    const std = @import("std");
    const expectEqualStrings = std.testing.expectEqualStrings;
    const mem = std.mem;

    test "cast *[1][*:0]const u8 to []const ?[*:0]const u8" {
        const window_name = [1][*:0]const u8{"window name"};
        const x: []const ?[*:0]const u8 = &window_name;
        try expectEqualStrings("window name", mem.span(x[0].?));
    }

test_pointer_coerce_const_optional.zig

    $ zig test test_pointer_coerce_const_optional.zig
    1/1 test_pointer_coerce_const_optional.test.cast *[1][*:0]const u8 to []const ?[*:0]const u8...OK
    All 1 tests passed.

Shell

#### [Type Coercion: Integer and Float Widening](#toc-Type-Coercion-Integer-and-Float-Widening) [§](#Type-Coercion-Integer-and-Float-Widening)

[Integers](#Integers) coerce to integer types which can represent every value of the old type, and likewise [Floats](#Floats) coerce to float types which can represent every value of the old type.

    const std = @import("std");
    const builtin = @import("builtin");
    const expectEqual = std.testing.expectEqual;
    const mem = std.mem;

    test "integer widening" {
        const a: u8 = 250;
        const b: u16 = a;
        const c: u32 = b;
        const d: u64 = c;
        const e: u64 = d;
        const f: u128 = e;
        try expectEqual(f, a);
    }

    test "implicit unsigned integer to signed integer" {
        const a: u8 = 250;
        const b: i16 = a;
        try expectEqual(250, b);
    }

    test "float widening" {
        const a: f16 = 12.34;
        const b: f32 = a;
        const c: f64 = b;
        const d: f128 = c;
        try expectEqual(d, a);
    }

test_integer_widening.zig

    $ zig test test_integer_widening.zig
    1/3 test_integer_widening.test.integer widening...OK
    2/3 test_integer_widening.test.implicit unsigned integer to signed integer...OK
    3/3 test_integer_widening.test.float widening...OK
    All 3 tests passed.

Shell

#### [Type Coercion: Int to Float](#toc-Type-Coercion-Int-to-Float) [§](#Type-Coercion-Int-to-Float)

[Integers](#Integers) coerce to [Floats](#Floats) if every possible integer value can be stored in the float without rounding (i.e. the integer's precision does not exceed the float's significand precision). Larger integer types that cannot be safely coerced must be explicitly casted with [@floatFromInt](#floatFromInt).

| Float Type     | Largest Integer Types |
|----------------|-----------------------|
| `f16`          | `i12` and `u11`       |
| `f32`          | `i25` and `u24`       |
| `f64`          | `i54` and `u53`       |
| `f80`          | `i65` and `u64`       |
| `f128`         | `i114` and `u113`     |
| `c_longdouble` | Varies by target      |

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "implicit integer to float" {
        var int: u8 = 123;
        _ = &int;
        const float: f32 = int;
        const int_from_float: u8 = @intFromFloat(float);
        try expectEqual(int, int_from_float);
    }

test_int_to_float_coercion.zig

    $ zig test test_int_to_float_coercion.zig
    1/1 test_int_to_float_coercion.test.implicit integer to float...OK
    All 1 tests passed.

Shell

    test "integer type is too large for implicit cast to float" {
        var int: u25 = 123;
        _ = &int;
        const float: f32 = int;
        _ = float;
    }

test_failed_int_to_float_coercion.zig

    $ zig test test_failed_int_to_float_coercion.zig
    /home/andy/src/zig/doc/langref/test_failed_int_to_float_coercion.zig:4:24: error: expected type 'f32', found 'u25'
        const float: f32 = int;
                           ^~~

Shell

#### [Type Coercion: Float to Int](#toc-Type-Coercion-Float-to-Int) [§](#Type-Coercion-Float-to-Int)

A compiler error is appropriate because this ambiguous expression leaves the compiler two choices about the coercion.

- Cast `54.0` to `comptime_int` resulting in `@as``(``comptime_int``, ``10``)`, which is casted to `@as``(``f32``, ``10``)`
- Cast `5` to `comptime_float` resulting in `@as``(``comptime_float``, ``10.8``)`, which is casted to `@as``(``f32``, ``10.8``)`

    // Compile time coercion of float to int
    test "implicit cast to comptime_int" {
        const f: f32 = 54.0 / 5;
        _ = f;
    }

test_ambiguous_coercion.zig

    $ zig test test_ambiguous_coercion.zig
    /home/andy/src/zig/doc/langref/test_ambiguous_coercion.zig:3:25: error: ambiguous coercion of division operands 'comptime_float' and 'comptime_int'; non-zero remainder '4'
        const f: f32 = 54.0 / 5;
                       ~~~~~^~~

Shell

#### [Type Coercion: Slices, Arrays and Pointers](#toc-Type-Coercion-Slices-Arrays-and-Pointers) [§](#Type-Coercion-Slices-Arrays-and-Pointers)

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;
    const expectEqualSlices = std.testing.expectEqualSlices;

    // You can assign constant pointers to arrays to a slice with
    // const modifier on the element type. Useful in particular for
    // String literals.
    test "*const [N]T to []const T" {
        const x1: []const u8 = "hello";
        const x2: []const u8 = &[5]u8{ 'h', 'e', 'l', 'l', 111 };
        try expectEqualStrings(x1, x2);

        const y: []const f32 = &[2]f32{ 1.2, 3.4 };
        try expectEqual(1.2, y[0]);
    }

    // Likewise, it works when the destination type is an error union.
    test "*const [N]T to E![]const T" {
        const x1: anyerror![]const u8 = "hello";
        const x2: anyerror![]const u8 = &[5]u8{ 'h', 'e', 'l', 'l', 111 };
        try expectEqualStrings(try x1, try x2);

        const y: anyerror![]const f32 = &[2]f32{ 1.2, 3.4 };
        try expectEqual(1.2, (try y)[0]);
    }

    // Likewise, it works when the destination type is an optional.
    test "*const [N]T to ?[]const T" {
        const x1: ?[]const u8 = "hello";
        const x2: ?[]const u8 = &[5]u8{ 'h', 'e', 'l', 'l', 111 };
        try expectEqualStrings(x1.?, x2.?);

        const y: ?[]const f32 = &[2]f32{ 1.2, 3.4 };
        try expectEqual(1.2, y.?[0]);
    }

    // In this cast, the array length becomes the slice length.
    test "*[N]T to []T" {
        var buf: [5]u8 = "hello".*;
        const x: []u8 = &buf;
        try expectEqualStrings("hello", x);

        const buf2 = [2]f32{ 1.2, 3.4 };
        const x2: []const f32 = &buf2;
        try expectEqualSlices(f32, &[2]f32{ 1.2, 3.4 }, x2);
    }

    // Single-item pointers to arrays can be coerced to many-item pointers.
    test "*[N]T to [*]T" {
        var buf: [5]u8 = "hello".*;
        const x: [*]u8 = &buf;
        try expectEqual('o', x[4]);
        // x[5] would be an uncaught out of bounds pointer dereference!
    }

    // Likewise, it works when the destination type is an optional.
    test "*[N]T to ?[*]T" {
        var buf: [5]u8 = "hello".*;
        const x: ?[*]u8 = &buf;
        try expectEqual('o', x.?[4]);
    }

    // Single-item pointers can be cast to len-1 single-item arrays.
    test "*T to *[1]T" {
        var x: i32 = 1234;
        const y: *[1]i32 = &x;
        const z: [*]i32 = y;
        try expectEqual(1234, z[0]);
    }

    // Sentinel-terminated slices can be coerced into sentinel-terminated pointers
    test "[:x]T to [*:x]T" {
        const buf: [:0]const u8 = "hello";
        const buf2: [*:0]const u8 = buf;
        try expectEqual('o', buf2[4]);
    }

test_coerce_slices_arrays_and_pointers.zig

    $ zig test test_coerce_slices_arrays_and_pointers.zig
    1/8 test_coerce_slices_arrays_and_pointers.test.*const [N]T to []const T...OK
    2/8 test_coerce_slices_arrays_and_pointers.test.*const [N]T to E![]const T...OK
    3/8 test_coerce_slices_arrays_and_pointers.test.*const [N]T to ?[]const T...OK
    4/8 test_coerce_slices_arrays_and_pointers.test.*[N]T to []T...OK
    5/8 test_coerce_slices_arrays_and_pointers.test.*[N]T to [*]T...OK
    6/8 test_coerce_slices_arrays_and_pointers.test.*[N]T to ?[*]T...OK
    7/8 test_coerce_slices_arrays_and_pointers.test.*T to *[1]T...OK
    8/8 test_coerce_slices_arrays_and_pointers.test.[:x]T to [*:x]T...OK
    All 8 tests passed.

Shell

See also:

- [C Pointers](#C-Pointers)

#### [Type Coercion: Optionals](#toc-Type-Coercion-Optionals) [§](#Type-Coercion-Optionals)

The payload type of [Optionals](#Optionals), as well as [null](#null), coerce to the optional type.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "coerce to optionals" {
        const x: ?i32 = 1234;
        const y: ?i32 = null;

        try expectEqual(1234, x.?);
        try expectEqual(null, y);
    }

test_coerce_optionals.zig

    $ zig test test_coerce_optionals.zig
    1/1 test_coerce_optionals.test.coerce to optionals...OK
    All 1 tests passed.

Shell

Optionals work nested inside the [Error Union Type](#Error-Union-Type), too:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "coerce to optionals wrapped in error union" {
        const x: anyerror!?i32 = 1234;
        const y: anyerror!?i32 = null;

        try expectEqual(1234, (try x).?);
        try expectEqual(null, (try y));
    }

test_coerce_optional_wrapped_error_union.zig

    $ zig test test_coerce_optional_wrapped_error_union.zig
    1/1 test_coerce_optional_wrapped_error_union.test.coerce to optionals wrapped in error union...OK
    All 1 tests passed.

Shell

#### [Type Coercion: Error Unions](#toc-Type-Coercion-Error-Unions) [§](#Type-Coercion-Error-Unions)

The payload type of an [Error Union Type](#Error-Union-Type) as well as the [Error Set Type](#Error-Set-Type) coerce to the error union type:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "coercion to error unions" {
        const x: anyerror!i32 = 1234;
        const y: anyerror!i32 = error.Failure;

        try expectEqual(1234, (try x));
        try std.testing.expectError(error.Failure, y);
    }

test_coerce_to_error_union.zig

    $ zig test test_coerce_to_error_union.zig
    1/1 test_coerce_to_error_union.test.coercion to error unions...OK
    All 1 tests passed.

Shell

#### [Type Coercion: Compile-Time Known Numbers](#toc-Type-Coercion-Compile-Time-Known-Numbers) [§](#Type-Coercion-Compile-Time-Known-Numbers)

When a number is [comptime](#comptime)-known to be representable in the destination type, it may be coerced:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "coercing large integer type to smaller one when value is comptime-known to fit" {
        const x: u64 = 255;
        const y: u8 = x;
        try expectEqual(255, y);
    }

test_coerce_large_to_small.zig

    $ zig test test_coerce_large_to_small.zig
    1/1 test_coerce_large_to_small.test.coercing large integer type to smaller one when value is comptime-known to fit...OK
    All 1 tests passed.

Shell

#### [Type Coercion: Unions and Enums](#toc-Type-Coercion-Unions-and-Enums) [§](#Type-Coercion-Unions-and-Enums)

Tagged unions can be coerced to enums, and enums can be coerced to tagged unions when they are [comptime](#comptime)-known to be a field of the union that has only one possible value, such as [void](#void):

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const E = enum {
        one,
        two,
        three,
    };

    const U = union(E) {
        one: i32,
        two: f32,
        three,
    };

    const U2 = union(enum) {
        a: void,
        b: f32,

        fn tag(self: U2) usize {
            switch (self) {
                .a => return 1,
                .b => return 2,
            }
        }
    };

    test "coercion between unions and enums" {
        const u = U{ .two = 12.34 };
        const e: E = u; // coerce union to enum
        try expectEqual(E.two, e);

        const three = E.three;
        const u_2: U = three; // coerce enum to union
        try expectEqual(E.three, u_2);

        const u_3: U = .three; // coerce enum literal to union
        try expectEqual(E.three, u_3);

        const u_4: U2 = .a; // coerce enum literal to union with inferred enum tag type.
        try expectEqual(1, u_4.tag());

        // The following example is invalid.
        // error: coercion from enum '@EnumLiteral()' to union 'test_coerce_unions_enum.U2' must initialize 'f32' field 'b'
        //var u_5: U2 = .b;
        //try expectEqual(2, u_5.tag());
    }

test_coerce_unions_enums.zig

    $ zig test test_coerce_unions_enums.zig
    1/1 test_coerce_unions_enums.test.coercion between unions and enums...OK
    All 1 tests passed.

Shell

See also:

- [union](#union)
- [enum](#enum)

#### [Type Coercion: undefined](#toc-Type-Coercion-undefined) [§](#Type-Coercion-undefined)

[undefined](#undefined) can be coerced to any type.

#### [Type Coercion: Tuples to Arrays](#toc-Type-Coercion-Tuples-to-Arrays) [§](#Type-Coercion-Tuples-to-Arrays)

[Tuples](#Tuples) can be coerced to arrays, if all of the fields have the same type.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const Tuple = struct { u8, u8 };
    test "coercion from homogeneous tuple to array" {
        const tuple: Tuple = .{ 5, 6 };
        const array: [2]u8 = tuple;
        _ = array;
    }

test_coerce_tuples_arrays.zig

    $ zig test test_coerce_tuples_arrays.zig
    1/1 test_coerce_tuples_arrays.test.coercion from homogeneous tuple to array...OK
    All 1 tests passed.

Shell

### [Explicit Casts](#toc-Explicit-Casts) [§](#Explicit-Casts)

Explicit casts are performed via [Builtin Functions](#Builtin-Functions). Some explicit casts are safe; some are not. Some explicit casts perform language-level assertions; some do not. Some explicit casts are no-ops at runtime; some are not.

- [@bitCast](#bitCast) - change type but maintain bit representation
- [@alignCast](#alignCast) - make a pointer have more alignment
- [@enumFromInt](#enumFromInt) - obtain an enum value based on its integer tag value
- [@errorFromInt](#errorFromInt) - obtain an error code based on its integer value
- [@errorCast](#errorCast) - convert to a smaller error set
- [@floatCast](#floatCast) - convert a larger float to a smaller float
- [@floatFromInt](#floatFromInt) - convert an integer to a float value
- [@intCast](#intCast) - convert between integer types
- [@intFromBool](#intFromBool) - convert true to 1 and false to 0
- [@intFromEnum](#intFromEnum) - obtain the integer tag value of an enum or tagged union
- [@intFromError](#intFromError) - obtain the integer value of an error code
- [@intFromFloat](#intFromFloat) - obtain the integer part of a float value
- [@intFromPtr](#intFromPtr) - obtain the address of a pointer
- [@ptrFromInt](#ptrFromInt) - convert an address to a pointer
- [@ptrCast](#ptrCast) - convert between pointer types
- [@truncate](#truncate) - convert between integer types, chopping off bits

### [Peer Type Resolution](#toc-Peer-Type-Resolution) [§](#Peer-Type-Resolution)

Peer Type Resolution occurs in these places:

- [switch](#switch) expressions
- [if](#if) expressions
- [while](#while) expressions
- [for](#for) expressions
- Multiple break statements in a block
- Some [binary operations](#Table-of-Operators)

This kind of type resolution chooses a type that all peer types can coerce into. Here are some examples:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    test "peer resolve int widening" {
        const a: i8 = 12;
        const b: i16 = 34;
        const c = a + b;
        try expectEqual(46, c);
        try expectEqual(i16, @TypeOf(c));
    }

    test "peer resolve small int and float" {
        // This only works for integer types that can coerce to the float type.
        // Larger integer types will cause a compiler error; no float widening occurs.
        var i: u8 = 12;
        var f: f32 = 34;
        _ = .{ &i, &f };
        const x = i + f;
        try expectEqual(x, 46.0);
        try expectEqual(@TypeOf(x), f32);
    }

    test "peer resolve arrays of different size to const slice" {
        try expectEqualStrings("true", boolToStr(true));
        try expectEqualStrings("false", boolToStr(false));
        try comptime expectEqualStrings("true", boolToStr(true));
        try comptime expectEqualStrings("false", boolToStr(false));
    }
    fn boolToStr(b: bool) []const u8 {
        return if (b) "true" else "false";
    }

    test "peer resolve array and const slice" {
        try testPeerResolveArrayConstSlice(true);
        try comptime testPeerResolveArrayConstSlice(true);
    }
    fn testPeerResolveArrayConstSlice(b: bool) !void {
        const value1 = if (b) "aoeu" else @as([]const u8, "zz");
        const value2 = if (b) @as([]const u8, "zz") else "aoeu";
        try expectEqualStrings("aoeu", value1);
        try expectEqualStrings("zz", value2);
    }

    test "peer type resolution: ?T and T" {
        try expectEqual(0, peerTypeTAndOptionalT(true, false).?);
        try expectEqual(3, peerTypeTAndOptionalT(false, false).?);
        comptime {
            try expectEqual(0, peerTypeTAndOptionalT(true, false).?);
            try expectEqual(3, peerTypeTAndOptionalT(false, false).?);
        }
    }
    fn peerTypeTAndOptionalT(c: bool, b: bool) ?usize {
        if (c) {
            return if (b) null else @as(usize, 0);
        }

        return @as(usize, 3);
    }

    test "peer type resolution: *[0]u8 and []const u8" {
        try expectEqual(0, peerTypeEmptyArrayAndSlice(true, "hi").len);
        try expectEqual(1, peerTypeEmptyArrayAndSlice(false, "hi").len);
        comptime {
            try expectEqual(0, peerTypeEmptyArrayAndSlice(true, "hi").len);
            try expectEqual(1, peerTypeEmptyArrayAndSlice(false, "hi").len);
        }
    }
    fn peerTypeEmptyArrayAndSlice(a: bool, slice: []const u8) []const u8 {
        if (a) {
            return &[_]u8{};
        }

        return slice[0..1];
    }
    test "peer type resolution: *[0]u8, []const u8, and anyerror![]u8" {
        {
            var data = "hi".*;
            const slice = data[0..];
            try expectEqual(0, (try peerTypeEmptyArrayAndSliceAndError(true, slice)).len);
            try expectEqual(1, (try peerTypeEmptyArrayAndSliceAndError(false, slice)).len);
        }
        comptime {
            var data = "hi".*;
            const slice = data[0..];
            try expectEqual(0, (try peerTypeEmptyArrayAndSliceAndError(true, slice)).len);
            try expectEqual(1, (try peerTypeEmptyArrayAndSliceAndError(false, slice)).len);
        }
    }
    fn peerTypeEmptyArrayAndSliceAndError(a: bool, slice: []u8) anyerror![]u8 {
        if (a) {
            return &[_]u8{};
        }

        return slice[0..1];
    }

    test "peer type resolution: *const T and ?*T" {
        const a: *const usize = @ptrFromInt(0x123456780);
        const b: ?*usize = @ptrFromInt(0x123456780);
        try expectEqual(a, b);
        try expectEqual(b, a);
    }

    test "peer type resolution: error union switch" {
        // The non-error and error cases are only peers if the error case is just a switch expression;
        // the pattern `if (x) {...} else |err| blk: { switch (err) {...} }` does not consider the
        // non-error and error case to be peers.
        var a: error{ A, B, C }!u32 = 0;
        _ = &a;
        const b = if (a) |x|
            x + 3
        else |err| switch (err) {
            error.A => 0,
            error.B => 1,
            error.C => null,
        };
        try expectEqual(?u32, @TypeOf(b));

        // The non-error and error cases are only peers if the error case is just a switch expression;
        // the pattern `x catch |err| blk: { switch (err) {...} }` does not consider the unwrapped `x`
        // and error case to be peers.
        const c = a catch |err| switch (err) {
            error.A => 0,
            error.B => 1,
            error.C => null,
        };
        try expectEqual(?u32, @TypeOf(c));
    }

test_peer_type_resolution.zig

    $ zig test test_peer_type_resolution.zig
    1/9 test_peer_type_resolution.test.peer resolve int widening...OK
    2/9 test_peer_type_resolution.test.peer resolve small int and float...OK
    3/9 test_peer_type_resolution.test.peer resolve arrays of different size to const slice...OK
    4/9 test_peer_type_resolution.test.peer resolve array and const slice...OK
    5/9 test_peer_type_resolution.test.peer type resolution: ?T and T...OK
    6/9 test_peer_type_resolution.test.peer type resolution: *[0]u8 and []const u8...OK
    7/9 test_peer_type_resolution.test.peer type resolution: *[0]u8, []const u8, and anyerror![]u8...OK
    8/9 test_peer_type_resolution.test.peer type resolution: *const T and ?*T...OK
    9/9 test_peer_type_resolution.test.peer type resolution: error union switch...OK
    All 9 tests passed.

Shell

