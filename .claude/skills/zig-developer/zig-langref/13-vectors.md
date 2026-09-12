# Vectors


A vector is a group of booleans, [Integers](#Integers), [Floats](#Floats), or [Pointers](#Pointers) which are operated on in parallel, using SIMD instructions if possible. Vector types are created with the builtin function [@Vector](#Vector).

Vectors generally support the same builtin operators as their underlying base types. The only exception to this is the keywords \`and\` and \`or\` on vectors of bools, since these operators affect control flow, which is not allowed for vectors. All other operations are performed element-wise, and return a vector of the same length as the input vectors. This includes:

- Arithmetic (`+`, `-`, `/`, `*`, `@divFloor`, `@sqrt`, `@ceil`, `@log`, etc.)
- Bitwise operators (`>>`, `<<`, `&`, `|`, `~`, etc.)
- Comparison operators (`<`, `>`, `==`, etc.)
- Boolean not (`!`)

It is prohibited to use a math operator on a mixture of scalars (individual numbers) and vectors. Zig provides the [@splat](#splat) builtin to easily convert from scalars to vectors, and it supports [@reduce](#reduce) and array indexing syntax to convert from vectors to scalars. Vectors also support assignment to and from fixed-length arrays with comptime-known length.

For rearranging elements within and between vectors, Zig provides the [@shuffle](#shuffle) and [@select](#select) functions.

Operations on vectors shorter than the target machine's native SIMD size will typically compile to single SIMD instructions, while vectors longer than the target machine's native SIMD size will compile to multiple SIMD instructions. If a given operation doesn't have SIMD support on the target architecture, the compiler will default to operating on each vector element one at a time. Zig supports any comptime-known vector length up to 2^32-1, although small powers of two (2-64) are most typical. Note that excessively long vector lengths (e.g. 2^20) may result in compiler crashes on current versions of Zig.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "Basic vector usage" {
        // Vectors have a compile-time known length and base type.
        const a = @Vector(4, i32){ 1, 2, 3, 4 };
        const b = @Vector(4, i32){ 5, 6, 7, 8 };

        // Math operations take place element-wise.
        const c = a + b;

        // Individual vector elements can be accessed using array indexing syntax.
        try expectEqual(6, c[0]);
        try expectEqual(8, c[1]);
        try expectEqual(10, c[2]);
        try expectEqual(12, c[3]);
    }

    test "Conversion between vectors, arrays, and slices" {
        // Vectors can be coerced to arrays, and vice versa.
        const arr1: [4]f32 = [_]f32{ 1.1, 3.2, 4.5, 5.6 };
        const vec: @Vector(4, f32) = arr1;
        const arr2: [4]f32 = vec;
        try expectEqual(arr1, arr2);

        // You can also assign from a slice with comptime-known length to a vector using .*
        const vec2: @Vector(2, f32) = arr1[1..3].*;

        const slice: []const f32 = &arr1;
        var offset: u32 = 1; // var to make it runtime-known
        _ = &offset; // suppress 'var is never mutated' error
        // To extract a comptime-known length from a runtime-known offset,
        // first extract a new slice from the starting offset, then an array of
        // comptime-known length
        const vec3: @Vector(2, f32) = slice[offset..][0..2].*;
        try expectEqual(slice[offset], vec2[0]);
        try expectEqual(slice[offset + 1], vec2[1]);
        try expectEqual(vec2, vec3);
    }

test_vector.zig

    $ zig test test_vector.zig
    1/2 test_vector.test.Basic vector usage...OK
    2/2 test_vector.test.Conversion between vectors, arrays, and slices...OK
    All 2 tests passed.

Shell

TODO talk about C ABI interop  
TODO consider suggesting std.MultiArrayList

See also:

- [@splat](#splat)
- [@shuffle](#shuffle)
- [@select](#select)
- [@reduce](#reduce)

### [Relationship with Arrays](#toc-Relationship-with-Arrays) [§](#Relationship-with-Arrays)

Vectors and [Arrays](#Arrays) each have a well-defined **bit layout** and therefore support [@bitCast](#bitCast) between each other. [Type Coercion](#Type-Coercion) implicitly peforms `@bitCast`.

Arrays have well-defined byte layout, but vectors do not, making [@ptrCast](#ptrCast) between them [Illegal Behavior](#Illegal-Behavior).

### [Destructuring Vectors](#toc-Destructuring-Vectors) [§](#Destructuring-Vectors)

Vectors can be destructured:

    const print = @import("std").debug.print;

    // emulate punpckldq
    pub fn unpack(x: @Vector(4, f32), y: @Vector(4, f32)) @Vector(4, f32) {
        const a, const c, _, _ = x;
        const b, const d, _, _ = y;
        return .{ a, b, c, d };
    }

    pub fn main() void {
        const x: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
        const y: @Vector(4, f32) = .{ 5.0, 6.0, 7.0, 8.0 };
        print("{}", .{unpack(x, y)});
    }

destructuring_vectors.zig

    $ zig build-exe destructuring_vectors.zig
    $ ./destructuring_vectors
    { 1, 5, 2, 6 }

Shell

See also:

- [Destructuring](#Destructuring)
- [Destructuring Tuples](#Destructuring-Tuples)
- [Destructuring Arrays](#Destructuring-Arrays)

