# noreturn


`noreturn` is the type of:

- `break`
- `continue`
- `return`
- `unreachable`
- `while`` (``true``) {}`

When resolving types together, such as `if` clauses or `switch` prongs, the `noreturn` type is compatible with every other type. Consider:

    fn foo(condition: bool, b: u32) void {
        const a = if (condition) b else return;
        _ = a;
        @panic("do something with a");
    }
    test "noreturn" {
        foo(false, 1);
    }

test_noreturn.zig

    $ zig test test_noreturn.zig
    1/1 test_noreturn.test.noreturn...OK
    All 1 tests passed.

Shell

Another use case for `noreturn` is the `exit` function:

    const std = @import("std");
    const builtin = @import("builtin");
    const native_arch = builtin.cpu.arch;
    const expectEqual = std.testing.expectEqual;

    const WINAPI: std.builtin.CallingConvention = if (native_arch == .x86) .{ .x86_stdcall = .{} } else .c;
    extern "kernel32" fn ExitProcess(exit_code: c_uint) callconv(WINAPI) noreturn;

    test "foo" {
        const value = bar() catch ExitProcess(1);
        try expectEqual(1234, value);
    }

    fn bar() anyerror!u32 {
        return 1234;
    }

test_noreturn_from_exit.zig

    $ zig test test_noreturn_from_exit.zig -target x86_64-windows --test-no-exec

Shell

