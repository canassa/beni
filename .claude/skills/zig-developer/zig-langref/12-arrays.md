# Arrays


    const expectEqual = @import("std").testing.expectEqual;
    const assert = @import("std").debug.assert;
    const mem = @import("std").mem;

    // array literal
    const message = [_]u8{ 'h', 'e', 'l', 'l', 'o' };

    // alternative initialization using result location
    const alt_message: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };

    comptime {
        assert(mem.eql(u8, &message, &alt_message));
    }

    // get the size of an array
    comptime {
        assert(message.len == 5);
    }

    // A string literal is a single-item pointer to an array.
    const same_message = "hello";

    comptime {
        assert(mem.eql(u8, &message, same_message));
    }

    test "iterate over an array" {
        var sum: usize = 0;
        for (message) |byte| {
            sum += byte;
        }
        try expectEqual('h' + 'e' + 'l' * 2 + 'o', sum);
    }

    // modifiable array
    var some_integers: [100]i32 = undefined;

    test "modify an array" {
        for (&some_integers, 0..) |*item, i| {
            item.* = @intCast(i);
        }
        try expectEqual(10, some_integers[10]);
        try expectEqual(99, some_integers[99]);
    }

    // array concatenation works if the values are known
    // at compile time
    const part_one = [_]i32{ 1, 2, 3, 4 };
    const part_two = [_]i32{ 5, 6, 7, 8 };
    const all_of_it = part_one ++ part_two;
    comptime {
        assert(mem.eql(i32, &all_of_it, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    }

    // remember that string literals are arrays
    const hello = "hello";
    const world = "world";
    const hello_world = hello ++ " " ++ world;
    comptime {
        assert(mem.eql(u8, hello_world, "hello world"));
    }

    // ** does repeating patterns
    const pattern = "ab" ** 3;
    comptime {
        assert(mem.eql(u8, pattern, "ababab"));
    }

    // initialize an array to zero
    const all_zero = [_]u16{0} ** 10;

    comptime {
        assert(all_zero.len == 10);
        assert(all_zero[5] == 0);
    }

    // use compile-time code to initialize an array
    var fancy_array = init: {
        var initial_value: [10]Point = undefined;
        for (&initial_value, 0..) |*pt, i| {
            pt.* = Point{
                .x = @intCast(i),
                .y = @intCast(i * 2),
            };
        }
        break :init initial_value;
    };
    const Point = struct {
        x: i32,
        y: i32,
    };

    test "compile-time array initialization" {
        try expectEqual(4, fancy_array[4].x);
        try expectEqual(8, fancy_array[4].y);
    }

    // call a function to initialize an array
    var more_points = [_]Point{makePoint(3)} ** 10;
    fn makePoint(x: i32) Point {
        return Point{
            .x = x,
            .y = x * 2,
        };
    }
    test "array initialization with function calls" {
        try expectEqual(3, more_points[4].x);
        try expectEqual(6, more_points[4].y);
        try expectEqual(10, more_points.len);
    }

test_arrays.zig

    $ zig test test_arrays.zig
    1/4 test_arrays.test.iterate over an array...OK
    2/4 test_arrays.test.modify an array...OK
    3/4 test_arrays.test.compile-time array initialization...OK
    4/4 test_arrays.test.array initialization with function calls...OK
    All 4 tests passed.

Shell

See also:

- [for](#for)
- [Slices](#Slices)

### [Multidimensional Arrays](#toc-Multidimensional-Arrays) [§](#Multidimensional-Arrays)

Multidimensional arrays can be created by nesting arrays:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const mat4x5 = [4][5]f32{
        [_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0 },
        [_]f32{ 0.0, 1.0, 0.0, 1.0, 0.0 },
        [_]f32{ 0.0, 0.0, 1.0, 0.0, 0.0 },
        [_]f32{ 0.0, 0.0, 0.0, 1.0, 9.9 },
    };
    test "multidimensional arrays" {
        // mat4x5 itself is a one-dimensional array of arrays.
        try expectEqual(mat4x5[1], [_]f32{ 0.0, 1.0, 0.0, 1.0, 0.0 });

        // Access the 2D array by indexing the outer array, and then the inner array.
        try expectEqual(9.9, mat4x5[3][4]);

        // Here we iterate with for loops.
        for (mat4x5, 0..) |row, row_index| {
            for (row, 0..) |cell, column_index| {
                if (row_index == column_index) {
                    try expectEqual(1.0, cell);
                }
            }
        }

        // Initialize a multidimensional array to zeros.
        const all_zero: [4][5]f32 = .{.{0} ** 5} ** 4;
        try expectEqual(0, all_zero[0][0]);
    }

test_multidimensional_arrays.zig

    $ zig test test_multidimensional_arrays.zig
    1/1 test_multidimensional_arrays.test.multidimensional arrays...OK
    All 1 tests passed.

Shell

### [Sentinel-Terminated Arrays](#toc-Sentinel-Terminated-Arrays) [§](#Sentinel-Terminated-Arrays)

The syntax `[N:x]T` describes an array which has a sentinel element of value `x` at the index corresponding to the length `N`.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "0-terminated sentinel array" {
        const array = [_:0]u8{ 1, 2, 3, 4 };

        try expectEqual([4:0]u8, @TypeOf(array));
        try expectEqual(4, array.len);
        try expectEqual(0, array[4]);
    }

    test "extra 0s in 0-terminated sentinel array" {
        // The sentinel value may appear earlier, but does not influence the compile-time 'len'.
        const array = [_:0]u8{ 1, 0, 0, 4 };

        try expectEqual([4:0]u8, @TypeOf(array));
        try expectEqual(4, array.len);
        try expectEqual(0, array[4]);
    }

test_null_terminated_array.zig

    $ zig test test_null_terminated_array.zig
    1/2 test_null_terminated_array.test.0-terminated sentinel array...OK
    2/2 test_null_terminated_array.test.extra 0s in 0-terminated sentinel array...OK
    All 2 tests passed.

Shell

See also:

- [Sentinel-Terminated Pointers](#Sentinel-Terminated-Pointers)
- [Sentinel-Terminated Slices](#Sentinel-Terminated-Slices)

### [Destructuring Arrays](#toc-Destructuring-Arrays) [§](#Destructuring-Arrays)

Arrays can be destructured:

    const print = @import("std").debug.print;

    fn swizzleRgbaToBgra(rgba: [4]u8) [4]u8 {
        // readable swizzling by destructuring
        const r, const g, const b, const a = rgba;
        return .{ b, g, r, a };
    }

    pub fn main() void {
        const pos = [_]i32{ 1, 2 };
        const x, const y = pos;
        print("x = {}, y = {}\n", .{x, y});

        const orange: [4]u8 = .{ 255, 165, 0, 255 };
        print("{any}\n", .{swizzleRgbaToBgra(orange)});
    }

destructuring_arrays.zig

    $ zig build-exe destructuring_arrays.zig
    $ ./destructuring_arrays
    x = 1, y = 2
    { 0, 165, 255, 255 }

Shell

See also:

- [Destructuring](#Destructuring)
- [Destructuring Tuples](#Destructuring-Tuples)
- [Destructuring Vectors](#Destructuring-Vectors)

