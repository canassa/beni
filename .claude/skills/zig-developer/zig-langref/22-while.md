# while


A while loop is used to repeatedly execute an expression until some condition is no longer true.

    const expectEqual = @import("std").testing.expectEqual;

    test "while basic" {
        var i: usize = 0;
        while (i < 10) {
            i += 1;
        }
        try expectEqual(10, i);
    }

test_while.zig

    $ zig test test_while.zig
    1/1 test_while.test.while basic...OK
    All 1 tests passed.

Shell

Use `break` to exit a while loop early.

    const expectEqual = @import("std").testing.expectEqual;

    test "while break" {
        var i: usize = 0;
        while (true) {
            if (i == 10)
                break;
            i += 1;
        }
        try expectEqual(10, i);
    }

test_while_break.zig

    $ zig test test_while_break.zig
    1/1 test_while_break.test.while break...OK
    All 1 tests passed.

Shell

Use `continue` to jump back to the beginning of the loop.

    const expectEqual = @import("std").testing.expectEqual;

    test "while continue" {
        var i: usize = 0;
        while (true) {
            i += 1;
            if (i < 10)
                continue;
            break;
        }
        try expectEqual(10, i);
    }

test_while_continue.zig

    $ zig test test_while_continue.zig
    1/1 test_while_continue.test.while continue...OK
    All 1 tests passed.

Shell

While loops support a continue expression which is executed when the loop is continued. The `continue` keyword respects this expression.

    const expectEqual = @import("std").testing.expectEqual;
    const expect = @import("std").testing.expect;

    test "while loop continue expression" {
        var i: usize = 0;
        while (i < 10) : (i += 1) {}
        try expectEqual(10, i);
    }

    test "while loop continue expression, more complicated" {
        var i: usize = 1;
        var j: usize = 1;
        while (i * j < 2000) : ({
            i *= 2;
            j *= 3;
        }) {
            const my_ij = i * j;
            try expect(my_ij < 2000);
        }
    }

test_while_continue_expression.zig

    $ zig test test_while_continue_expression.zig
    1/2 test_while_continue_expression.test.while loop continue expression...OK
    2/2 test_while_continue_expression.test.while loop continue expression, more complicated...OK
    All 2 tests passed.

Shell

While loops are expressions. The result of the expression is the result of the `else` clause of a while loop, which is executed when the condition of the while loop is tested as false.

`break`, like `return`, accepts a value parameter. This is the result of the `while` expression. When you `break` from a while loop, the `else` branch is not evaluated.

    const expect = @import("std").testing.expect;

    test "while else" {
        try expect(rangeHasNumber(0, 10, 5));
        try expect(!rangeHasNumber(0, 10, 15));
    }

    fn rangeHasNumber(begin: usize, end: usize, number: usize) bool {
        var i = begin;
        return while (i < end) : (i += 1) {
            if (i == number) {
                break true;
            }
        } else false;
    }

test_while_else.zig

    $ zig test test_while_else.zig
    1/1 test_while_else.test.while else...OK
    All 1 tests passed.

Shell

### [Labeled while](#toc-Labeled-while) [§](#Labeled-while)

When a `while` loop is labeled, it can be referenced from a `break` or `continue` from within a nested loop:

    test "nested break" {
        outer: while (true) {
            while (true) {
                break :outer;
            }
        }
    }

    test "nested continue" {
        var i: usize = 0;
        outer: while (i < 10) : (i += 1) {
            while (true) {
                continue :outer;
            }
        }
    }

test_while_nested_break.zig

    $ zig test test_while_nested_break.zig
    1/2 test_while_nested_break.test.nested break...OK
    2/2 test_while_nested_break.test.nested continue...OK
    All 2 tests passed.

Shell

### [while with Optionals](#toc-while-with-Optionals) [§](#while-with-Optionals)

Just like [if](#if) expressions, while loops can take an optional as the condition and capture the payload. When [null](#null) is encountered the loop exits.

When the `|x|` syntax is present on a `while` expression, the while condition must have an [Optional Type](#Optional-Type).

The `else` branch is allowed on optional iteration. In this case, it will be executed on the first null value encountered.

    const expectEqual = @import("std").testing.expectEqual;

    test "while null capture" {
        var sum1: u32 = 0;
        numbers_left = 3;
        while (eventuallyNullSequence()) |value| {
            sum1 += value;
        }
        try expectEqual(3, sum1);

        // null capture with an else block
        var sum2: u32 = 0;
        numbers_left = 3;
        while (eventuallyNullSequence()) |value| {
            sum2 += value;
        } else {
            try expectEqual(3, sum2);
        }

        // null capture with a continue expression
        var i: u32 = 0;
        var sum3: u32 = 0;
        numbers_left = 3;
        while (eventuallyNullSequence()) |value| : (i += 1) {
            sum3 += value;
        }
        try expectEqual(3, i);
    }

    var numbers_left: u32 = undefined;
    fn eventuallyNullSequence() ?u32 {
        return if (numbers_left == 0) null else blk: {
            numbers_left -= 1;
            break :blk numbers_left;
        };
    }

test_while_null_capture.zig

    $ zig test test_while_null_capture.zig
    1/1 test_while_null_capture.test.while null capture...OK
    All 1 tests passed.

Shell

### [while with Error Unions](#toc-while-with-Error-Unions) [§](#while-with-Error-Unions)

Just like [if](#if) expressions, while loops can take an error union as the condition and capture the payload or the error code. When the condition results in an error code the else branch is evaluated and the loop is finished.

When the `else`` |x|` syntax is present on a `while` expression, the while condition must have an [Error Union Type](#Error-Union-Type).

    const expectEqual = @import("std").testing.expectEqual;

    test "while error union capture" {
        var sum1: u32 = 0;
        numbers_left = 3;
        while (eventuallyErrorSequence()) |value| {
            sum1 += value;
        } else |err| {
            try expectEqual(error.ReachedZero, err);
        }
    }

    var numbers_left: u32 = undefined;

    fn eventuallyErrorSequence() anyerror!u32 {
        return if (numbers_left == 0) error.ReachedZero else blk: {
            numbers_left -= 1;
            break :blk numbers_left;
        };
    }

test_while_error_capture.zig

    $ zig test test_while_error_capture.zig
    1/1 test_while_error_capture.test.while error union capture...OK
    All 1 tests passed.

Shell

### [inline while](#toc-inline-while) [§](#inline-while)

While loops can be inlined. This causes the loop to be unrolled, which allows the code to do some things which only work at compile time, such as use types as first class values.

    const expectEqual = @import("std").testing.expectEqual;

    test "inline while loop" {
        comptime var i = 0;
        var sum: usize = 0;
        inline while (i < 3) : (i += 1) {
            const T = switch (i) {
                0 => f32,
                1 => i8,
                2 => bool,
                else => unreachable,
            };
            sum += typeNameLength(T);
        }
        try expectEqual(9, sum);
    }

    fn typeNameLength(comptime T: type) usize {
        return @typeName(T).len;
    }

test_inline_while.zig

    $ zig test test_inline_while.zig
    1/1 test_inline_while.test.inline while loop...OK
    All 1 tests passed.

Shell

It is recommended to use `inline` loops only for one of these reasons:

- You need the loop to execute at [comptime](#comptime) for the semantics to work.
- You have a benchmark to prove that forcibly unrolling the loop in this way is measurably faster.

See also:

- [if](#if)
- [Optionals](#Optionals)
- [Errors](#Errors)
- [comptime](#comptime)
- [unreachable](#unreachable)

