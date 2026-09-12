# defer


Executes an expression unconditionally at scope exit.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;
    const print = std.debug.print;

    fn deferExample() !usize {
        var a: usize = 1;

        {
            defer a = 2;
            a = 1;
        }
        try expectEqual(2, a);

        a = 5;
        return a;
    }

    test "defer basics" {
        try expectEqual(5, (try deferExample()));
    }

test_defer.zig

    $ zig test test_defer.zig
    1/1 test_defer.test.defer basics...OK
    All 1 tests passed.

Shell

Defer expressions are evaluated in reverse order.

    const std = @import("std");
    const print = std.debug.print;

    pub fn main() void {
        print("\n", .{});

        defer {
            print("1 ", .{});
        }
        defer {
            print("2 ", .{});
        }
        if (false) {
            // defers are not run if they are never executed.
            defer {
                print("3 ", .{});
            }
        }
    }

defer_unwind.zig

    $ zig build-exe defer_unwind.zig
    $ ./defer_unwind

    2 1

Shell

Inside a defer expression the return statement is not allowed.

    fn deferInvalidExample() !void {
        defer {
            return error.DeferError;
        }

        return error.DeferError;
    }

test_invalid_defer.zig

    $ zig test test_invalid_defer.zig
    /home/andy/src/zig/doc/langref/test_invalid_defer.zig:3:9: error: cannot return from defer expression
            return error.DeferError;
            ^~~~~~~~~~~~~~~~~~~~~~~
    /home/andy/src/zig/doc/langref/test_invalid_defer.zig:2:5: note: defer expression here
        defer {
        ^~~~~

Shell

See also:

- [Errors](#Errors)

