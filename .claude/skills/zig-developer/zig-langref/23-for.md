# for


    const expectEqual = @import("std").testing.expectEqual;

    test "for basics" {
        const items = [_]i32{ 4, 5, 3, 4, 0 };
        var sum: i32 = 0;

        // For loops iterate over slices and arrays.
        for (items) |value| {
            // Break and continue are supported.
            if (value == 0) {
                continue;
            }
            sum += value;
        }
        try expectEqual(16, sum);

        // To iterate over a portion of a slice, reslice.
        for (items[0..1]) |value| {
            sum += value;
        }
        try expectEqual(20, sum);

        // To access the index of iteration, specify a second condition as well
        // as a second capture value.
        var sum2: i32 = 0;
        for (items, 0..) |_, i| {
            try expectEqual(usize, @TypeOf(i));
            sum2 += @as(i32, @intCast(i));
        }
        try expectEqual(10, sum2);

        // To iterate over consecutive integers, use the range syntax.
        // Unbounded range is always a compile error.
        var sum3: usize = 0;
        for (0..5) |i| {
            sum3 += i;
        }
        try expectEqual(10, sum3);
    }

    test "multi object for" {
        const items = [_]usize{ 1, 2, 3 };
        const items2 = [_]usize{ 4, 5, 6 };
        var count: usize = 0;

        // Iterate over multiple objects.
        // All lengths must be equal at the start of the loop, otherwise detectable
        // illegal behavior occurs.
        for (items, items2) |i, j| {
            count += i + j;
        }

        try expectEqual(21, count);
    }

    test "for reference" {
        var items = [_]i32{ 3, 4, 2 };

        // Iterate over the slice by reference by
        // specifying that the capture value is a pointer.
        for (&items) |*value| {
            value.* += 1;
        }

        try expectEqual(4, items[0]);
        try expectEqual(5, items[1]);
        try expectEqual(3, items[2]);
    }

    test "for else" {
        // For allows an else attached to it, the same as a while loop.
        const items = [_]?i32{ 3, 4, null, 5 };

        // For loops can also be used as expressions.
        // Similar to while loops, when you break from a for loop, the else branch is not evaluated.
        var sum: i32 = 0;
        const result = for (items) |value| {
            if (value != null) {
                sum += value.?;
            }
        } else blk: {
            try expectEqual(12, sum);
            break :blk sum;
        };
        try expectEqual(12, result);
    }

test_for.zig

    $ zig test test_for.zig
    1/4 test_for.test.for basics...OK
    2/4 test_for.test.multi object for...OK
    3/4 test_for.test.for reference...OK
    4/4 test_for.test.for else...OK
    All 4 tests passed.

Shell

### [Labeled for](#toc-Labeled-for) [§](#Labeled-for)

When a `for` loop is labeled, it can be referenced from a `break` or `continue` from within a nested loop:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "nested break" {
        var count: usize = 0;
        outer: for (1..6) |_| {
            for (1..6) |_| {
                count += 1;
                break :outer;
            }
        }
        try expectEqual(1, count);
    }

    test "nested continue" {
        var count: usize = 0;
        outer: for (1..9) |_| {
            for (1..6) |_| {
                count += 1;
                continue :outer;
            }
        }

        try expectEqual(8, count);
    }

test_for_nested_break.zig

    $ zig test test_for_nested_break.zig
    1/2 test_for_nested_break.test.nested break...OK
    2/2 test_for_nested_break.test.nested continue...OK
    All 2 tests passed.

Shell

### [inline for](#toc-inline-for) [§](#inline-for)

For loops can be inlined. This causes the loop to be unrolled, which allows the code to do some things which only work at compile time, such as use types as first class values. The capture value and iterator value of inlined for loops are compile-time known.

    const expectEqual = @import("std").testing.expectEqual;

    test "inline for loop" {
        const nums = [_]i32{ 2, 4, 6 };
        var sum: usize = 0;
        inline for (nums) |i| {
            const T = switch (i) {
                2 => f32,
                4 => i8,
                6 => bool,
                else => unreachable,
            };
            sum += typeNameLength(T);
        }
        try expectEqual(9, sum);
    }

    fn typeNameLength(comptime T: type) usize {
        return @typeName(T).len;
    }

test_inline_for.zig

    $ zig test test_inline_for.zig
    1/1 test_inline_for.test.inline for loop...OK
    All 1 tests passed.

Shell

It is recommended to use `inline` loops only for one of these reasons:

- You need the loop to execute at [comptime](#comptime) for the semantics to work.
- You have a benchmark to prove that forcibly unrolling the loop in this way is measurably faster.

See also:

- [while](#while)
- [comptime](#comptime)
- [Arrays](#Arrays)
- [Slices](#Slices)

