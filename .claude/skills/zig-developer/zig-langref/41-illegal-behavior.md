# Illegal Behavior


Many operations in Zig trigger what is known as "Illegal Behavior" (IB). If Illegal Behavior is detected at compile-time, Zig emits a compile error and refuses to continue. Otherwise, when Illegal Behavior is not caught at compile-time, it falls into one of two categories.

Some Illegal Behavior is *safety-checked*: this means that the compiler will insert "safety checks" anywhere that the Illegal Behavior may occur at runtime, to determine whether it is about to happen. If it is, the safety check "fails", which triggers a panic.

All other Illegal Behavior is *unchecked*, meaning the compiler is unable to insert safety checks for it. If Unchecked Illegal Behavior is invoked at runtime, anything can happen: usually that will be some kind of crash, but the optimizer is free to make Unchecked Illegal Behavior do anything, such as calling arbitrary functions or clobbering arbitrary data. This is similar to the concept of "undefined behavior" in some other languages. Note that Unchecked Illegal Behavior still always results in a compile error if evaluated at [comptime](#comptime), because the Zig compiler is able to perform more sophisticated checks at compile-time than at runtime.

Most Illegal Behavior is safety-checked. However, to facilitate optimizations, safety checks are disabled by default in the [ReleaseFast](#ReleaseFast) and [ReleaseSmall](#ReleaseSmall) optimization modes. Safety checks can also be enabled or disabled on a per-block basis, overriding the default for the current optimization mode, using [@setRuntimeSafety](#setRuntimeSafety). When safety checks are disabled, Safety-Checked Illegal Behavior behaves like Unchecked Illegal Behavior; that is, any behavior may result from invoking it.

When a safety check fails, Zig's default panic handler crashes with a stack trace, like this:

    test "safety check" {
        unreachable;
    }

test_illegal_behavior.zig

    $ zig test test_illegal_behavior.zig
    1/1 test_illegal_behavior.test.safety check...thread 926313 panic: reached unreachable code
    /home/andy/src/zig/doc/langref/test_illegal_behavior.zig:2:5: 0x1234e2c in test.safety check (test_illegal_behavior.zig)
        unreachable;
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
    /home/andy/src/zig/.zig-cache/o/072ba49a7ed3af767b4ac6cae5d991d5/test --seed=0x56efd66b

Shell

### [Reaching Unreachable Code](#toc-Reaching-Unreachable-Code) [§](#Reaching-Unreachable-Code)

At compile-time:

    comptime {
        assert(false);
    }
    fn assert(ok: bool) void {
        if (!ok) unreachable; // assertion failure
    }

test_comptime_reaching_unreachable.zig

    $ zig test test_comptime_reaching_unreachable.zig
    /home/andy/src/zig/doc/langref/test_comptime_reaching_unreachable.zig:5:14: error: reached unreachable code
        if (!ok) unreachable; // assertion failure
                 ^~~~~~~~~~~
    /home/andy/src/zig/doc/langref/test_comptime_reaching_unreachable.zig:2:11: note: called at comptime here
        assert(false);
        ~~~~~~^~~~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        std.debug.assert(false);
    }

runtime_reaching_unreachable.zig

    $ zig build-exe runtime_reaching_unreachable.zig
    $ ./runtime_reaching_unreachable
    thread 930209 panic: reached unreachable code
    /home/andy/src/zig/lib/std/debug.zig:421:14: 0x1025eb9 in assert (std.zig)
        if (!ok) unreachable; // assertion failure
                 ^
    /home/andy/src/zig/doc/langref/runtime_reaching_unreachable.zig:4:21: 0x11d57fe in main (runtime_reaching_unreachable.zig)
        std.debug.assert(false);
                        ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Index out of Bounds](#toc-Index-out-of-Bounds) [§](#Index-out-of-Bounds)

At compile-time:

    comptime {
        const array: [5]u8 = "hello".*;
        const garbage = array[5];
        _ = garbage;
    }

test_comptime_index_out_of_bounds.zig

    $ zig test test_comptime_index_out_of_bounds.zig
    /home/andy/src/zig/doc/langref/test_comptime_index_out_of_bounds.zig:3:27: error: index 5 outside array of length 5
        const garbage = array[5];
                              ^

Shell

At runtime:

    pub fn main() void {
        const x = foo("hello");
        _ = x;
    }

    fn foo(x: []const u8) u8 {
        return x[5];
    }

runtime_index_out_of_bounds.zig

    $ zig build-exe runtime_index_out_of_bounds.zig
    $ ./runtime_index_out_of_bounds
    thread 931962 panic: index out of bounds: index 5, len 5
    /home/andy/src/zig/doc/langref/runtime_index_out_of_bounds.zig:7:13: 0x11d58de in foo (runtime_index_out_of_bounds.zig)
        return x[5];
                ^
    /home/andy/src/zig/doc/langref/runtime_index_out_of_bounds.zig:2:18: 0x11d580a in main (runtime_index_out_of_bounds.zig)
        const x = foo("hello");
                     ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Cast Negative Number to Unsigned Integer](#toc-Cast-Negative-Number-to-Unsigned-Integer) [§](#Cast-Negative-Number-to-Unsigned-Integer)

At compile-time:

    comptime {
        const value: i32 = -1;
        const unsigned: u32 = @intCast(value);
        _ = unsigned;
    }

test_comptime_invalid_cast.zig

    $ zig test test_comptime_invalid_cast.zig
    /home/andy/src/zig/doc/langref/test_comptime_invalid_cast.zig:3:36: error: type 'u32' cannot represent integer value '-1'
        const unsigned: u32 = @intCast(value);
                                       ^~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var value: i32 = -1; // runtime-known
        _ = &value;
        const unsigned: u32 = @intCast(value);
        std.debug.print("value: {}\n", .{unsigned});
    }

runtime_invalid_cast.zig

    $ zig build-exe runtime_invalid_cast.zig
    $ ./runtime_invalid_cast
    thread 933932 panic: integer does not fit in destination type
    /home/andy/src/zig/doc/langref/runtime_invalid_cast.zig:6:27: 0x11d580f in main (runtime_invalid_cast.zig)
        const unsigned: u32 = @intCast(value);
                              ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

To obtain the maximum value of an unsigned integer, use `std.math.maxInt`.

### [Cast Truncates Data](#toc-Cast-Truncates-Data) [§](#Cast-Truncates-Data)

At compile-time:

    comptime {
        const spartan_count: u16 = 300;
        const byte: u8 = @intCast(spartan_count);
        _ = byte;
    }

test_comptime_invalid_cast_truncate.zig

    $ zig test test_comptime_invalid_cast_truncate.zig
    /home/andy/src/zig/doc/langref/test_comptime_invalid_cast_truncate.zig:3:31: error: type 'u8' cannot represent integer value '300'
        const byte: u8 = @intCast(spartan_count);
                                  ^~~~~~~~~~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var spartan_count: u16 = 300; // runtime-known
        _ = &spartan_count;
        const byte: u8 = @intCast(spartan_count);
        std.debug.print("value: {}\n", .{byte});
    }

runtime_invalid_cast_truncate.zig

    $ zig build-exe runtime_invalid_cast_truncate.zig
    $ ./runtime_invalid_cast_truncate
    thread 930996 panic: integer does not fit in destination type
    /home/andy/src/zig/doc/langref/runtime_invalid_cast_truncate.zig:6:22: 0x11d5810 in main (runtime_invalid_cast_truncate.zig)
        const byte: u8 = @intCast(spartan_count);
                         ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

To truncate bits, use [@truncate](#truncate).

### [Integer Overflow](#toc-Integer-Overflow) [§](#Integer-Overflow)

#### [Default Operations](#toc-Default-Operations) [§](#Default-Operations)

The following operators can cause integer overflow:

- `+` (addition)
- `-` (subtraction)
- `-` (negation)
- `*` (multiplication)
- `/` (division)
- [@divTrunc](#divTrunc) (division)
- [@divFloor](#divFloor) (division)
- [@divExact](#divExact) (division)

Example with addition at compile-time:

    comptime {
        var byte: u8 = 255;
        byte += 1;
    }

test_comptime_overflow.zig

    $ zig test test_comptime_overflow.zig
    /home/andy/src/zig/doc/langref/test_comptime_overflow.zig:3:10: error: overflow of integer type 'u8' with value '256'
        byte += 1;
        ~~~~~^~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var byte: u8 = 255;
        byte += 1;
        std.debug.print("value: {}\n", .{byte});
    }

runtime_overflow.zig

    $ zig build-exe runtime_overflow.zig
    $ ./runtime_overflow
    thread 934575 panic: integer overflow
    /home/andy/src/zig/doc/langref/runtime_overflow.zig:5:10: 0x11d5825 in main (runtime_overflow.zig)
        byte += 1;
             ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

#### [Standard Library Math Functions](#toc-Standard-Library-Math-Functions) [§](#Standard-Library-Math-Functions)

These functions provided by the standard library return possible errors.

- `@import``(``"std"``).math.add`
- `@import``(``"std"``).math.sub`
- `@import``(``"std"``).math.mul`
- `@import``(``"std"``).math.divTrunc`
- `@import``(``"std"``).math.divFloor`
- `@import``(``"std"``).math.divExact`
- `@import``(``"std"``).math.shl`

Example of catching an overflow for addition:

    const math = @import("std").math;
    const print = @import("std").debug.print;
    pub fn main() !void {
        var byte: u8 = 255;

        byte = if (math.add(u8, byte, 1)) |result| result else |err| {
            print("unable to add one: {s}\n", .{@errorName(err)});
            return err;
        };

        print("result: {}\n", .{byte});
    }

math_add.zig

    $ zig build-exe math_add.zig
    $ ./math_add
    unable to add one: Overflow
    error: Overflow
    /home/andy/src/zig/lib/std/math.zig:565:21: 0x1139244 in add__anon_22508 (std.zig)
        if (ov[1] != 0) return error.Overflow;
                        ^
    /home/andy/src/zig/doc/langref/math_add.zig:8:9: 0x11d4c44 in main (math_add.zig)
            return err;
            ^

Shell

#### [Builtin Overflow Functions](#toc-Builtin-Overflow-Functions) [§](#Builtin-Overflow-Functions)

These builtins return a tuple containing whether there was an overflow (as a `u1`) and the possibly overflowed bits of the operation:

- [@addWithOverflow](#addWithOverflow)
- [@subWithOverflow](#subWithOverflow)
- [@mulWithOverflow](#mulWithOverflow)
- [@shlWithOverflow](#shlWithOverflow)

Example of [@addWithOverflow](#addWithOverflow):

    const print = @import("std").debug.print;
    pub fn main() void {
        const byte: u8 = 255;

        const ov = @addWithOverflow(byte, 10);
        if (ov[1] != 0) {
            print("overflowed result: {}\n", .{ov[0]});
        } else {
            print("result: {}\n", .{ov[0]});
        }
    }

addWithOverflow_builtin.zig

    $ zig build-exe addWithOverflow_builtin.zig
    $ ./addWithOverflow_builtin
    overflowed result: 9

Shell

#### [Wrapping Operations](#toc-Wrapping-Operations) [§](#Wrapping-Operations)

These operations have guaranteed wraparound semantics.

- `+%` (wraparound addition)
- `-%` (wraparound subtraction)
- `-%` (wraparound negation)
- `*%` (wraparound multiplication)

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;
    const minInt = std.math.minInt;
    const maxInt = std.math.maxInt;

    test "wraparound addition and subtraction" {
        const x: i32 = maxInt(i32);
        const min_val = x +% 1;
        try expectEqual(minInt(i32), min_val);
        const max_val = min_val -% 1;
        try expectEqual(maxInt(i32), max_val);
    }

test_wraparound_semantics.zig

    $ zig test test_wraparound_semantics.zig
    1/1 test_wraparound_semantics.test.wraparound addition and subtraction...OK
    All 1 tests passed.

Shell

### [Exact Left Shift Overflow](#toc-Exact-Left-Shift-Overflow) [§](#Exact-Left-Shift-Overflow)

At compile-time:

    comptime {
        const x = @shlExact(@as(u8, 0b01010101), 2);
        _ = x;
    }

test_comptime_shlExact_overflow.zig

    $ zig test test_comptime_shlExact_overflow.zig
    /home/andy/src/zig/doc/langref/test_comptime_shlExact_overflow.zig:2:15: error: overflow of integer type 'u8' with value '340'
        const x = @shlExact(@as(u8, 0b01010101), 2);
                  ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var x: u8 = 0b01010101; // runtime-known
        _ = &x;
        const y = @shlExact(x, 2);
        std.debug.print("value: {}\n", .{y});
    }

runtime_shlExact_overflow.zig

    $ zig build-exe runtime_shlExact_overflow.zig
    $ ./runtime_shlExact_overflow
    thread 934568 panic: left shift overflowed bits
    /home/andy/src/zig/doc/langref/runtime_shlExact_overflow.zig:6:5: 0x11d5831 in main (runtime_shlExact_overflow.zig)
        const y = @shlExact(x, 2);
        ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Exact Right Shift Overflow](#toc-Exact-Right-Shift-Overflow) [§](#Exact-Right-Shift-Overflow)

At compile-time:

    comptime {
        const x = @shrExact(@as(u8, 0b10101010), 2);
        _ = x;
    }

test_comptime_shrExact_overflow.zig

    $ zig test test_comptime_shrExact_overflow.zig
    /home/andy/src/zig/doc/langref/test_comptime_shrExact_overflow.zig:2:15: error: exact shift shifted out 1 bits
        const x = @shrExact(@as(u8, 0b10101010), 2);
                  ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Shell

At runtime:

    const builtin = @import("builtin");
    const std = @import("std");

    pub fn main() void {
        var x: u8 = 0b10101010; // runtime-known
        _ = &x;
        const y = @shrExact(x, 2);
        std.debug.print("value: {}\n", .{y});

        if ((builtin.cpu.arch.isPowerPC() or builtin.cpu.arch.isRISCV() or builtin.cpu.arch.isLoongArch() or builtin.cpu.arch == .s390x) and builtin.zig_backend == .stage2_llvm) @panic("https://github.com/ziglang/zig/issues/24304");
    }

runtime_shrExact_overflow.zig

    $ zig build-exe runtime_shrExact_overflow.zig
    $ ./runtime_shrExact_overflow
    thread 935584 panic: right shift overflowed bits
    /home/andy/src/zig/doc/langref/runtime_shrExact_overflow.zig:7:5: 0x11d581a in main (runtime_shrExact_overflow.zig)
        const y = @shrExact(x, 2);
        ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Division by Zero](#toc-Division-by-Zero) [§](#Division-by-Zero)

At compile-time:

    comptime {
        const a: i32 = 1;
        const b: i32 = 0;
        const c = a / b;
        _ = c;
    }

test_comptime_division_by_zero.zig

    $ zig test test_comptime_division_by_zero.zig
    /home/andy/src/zig/doc/langref/test_comptime_division_by_zero.zig:4:19: error: division by zero here causes illegal behavior
        const c = a / b;
                      ^

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var a: u32 = 1;
        var b: u32 = 0;
        _ = .{ &a, &b };
        const c = a / b;
        std.debug.print("value: {}\n", .{c});
    }

runtime_division_by_zero.zig

    $ zig build-exe runtime_division_by_zero.zig
    $ ./runtime_division_by_zero
    thread 928583 panic: division by zero
    /home/andy/src/zig/doc/langref/runtime_division_by_zero.zig:7:17: 0x11d5820 in main (runtime_division_by_zero.zig)
        const c = a / b;
                    ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Remainder Division by Zero](#toc-Remainder-Division-by-Zero) [§](#Remainder-Division-by-Zero)

At compile-time:

    comptime {
        const a: i32 = 10;
        const b: i32 = 0;
        const c = a % b;
        _ = c;
    }

test_comptime_remainder_division_by_zero.zig

    $ zig test test_comptime_remainder_division_by_zero.zig
    /home/andy/src/zig/doc/langref/test_comptime_remainder_division_by_zero.zig:4:19: error: division by zero here causes illegal behavior
        const c = a % b;
                      ^

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var a: u32 = 10;
        var b: u32 = 0;
        _ = .{ &a, &b };
        const c = a % b;
        std.debug.print("value: {}\n", .{c});
    }

runtime_remainder_division_by_zero.zig

    $ zig build-exe runtime_remainder_division_by_zero.zig
    $ ./runtime_remainder_division_by_zero
    thread 931002 panic: division by zero
    /home/andy/src/zig/doc/langref/runtime_remainder_division_by_zero.zig:7:17: 0x11d5820 in main (runtime_remainder_division_by_zero.zig)
        const c = a % b;
                    ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Exact Division Remainder](#toc-Exact-Division-Remainder) [§](#Exact-Division-Remainder)

At compile-time:

    comptime {
        const a: u32 = 10;
        const b: u32 = 3;
        const c = @divExact(a, b);
        _ = c;
    }

test_comptime_divExact_remainder.zig

    $ zig test test_comptime_divExact_remainder.zig
    /home/andy/src/zig/doc/langref/test_comptime_divExact_remainder.zig:4:15: error: exact division produced remainder
        const c = @divExact(a, b);
                  ^~~~~~~~~~~~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var a: u32 = 10;
        var b: u32 = 3;
        _ = .{ &a, &b };
        const c = @divExact(a, b);
        std.debug.print("value: {}\n", .{c});
    }

runtime_divExact_remainder.zig

    $ zig build-exe runtime_divExact_remainder.zig
    $ ./runtime_divExact_remainder
    thread 930219 panic: exact division produced remainder
    /home/andy/src/zig/doc/langref/runtime_divExact_remainder.zig:7:15: 0x11d5855 in main (runtime_divExact_remainder.zig)
        const c = @divExact(a, b);
                  ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Attempt to Unwrap Null](#toc-Attempt-to-Unwrap-Null) [§](#Attempt-to-Unwrap-Null)

At compile-time:

    comptime {
        const optional_number: ?i32 = null;
        const number = optional_number.?;
        _ = number;
    }

test_comptime_unwrap_null.zig

    $ zig test test_comptime_unwrap_null.zig
    /home/andy/src/zig/doc/langref/test_comptime_unwrap_null.zig:3:35: error: unable to unwrap null
        const number = optional_number.?;
                       ~~~~~~~~~~~~~~~^~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        var optional_number: ?i32 = null;
        _ = &optional_number;
        const number = optional_number.?;
        std.debug.print("value: {}\n", .{number});
    }

runtime_unwrap_null.zig

    $ zig build-exe runtime_unwrap_null.zig
    $ ./runtime_unwrap_null
    thread 930212 panic: attempt to use null value
    /home/andy/src/zig/doc/langref/runtime_unwrap_null.zig:6:35: 0x11d5824 in main (runtime_unwrap_null.zig)
        const number = optional_number.?;
                                      ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

One way to avoid this crash is to test for null instead of assuming non-null, with the `if` expression:

    const print = @import("std").debug.print;
    pub fn main() void {
        const optional_number: ?i32 = null;

        if (optional_number) |number| {
            print("got number: {}\n", .{number});
        } else {
            print("it's null\n", .{});
        }
    }

testing_null_with_if.zig

    $ zig build-exe testing_null_with_if.zig
    $ ./testing_null_with_if
    it's null

Shell

See also:

- [Optionals](#Optionals)

### [Attempt to Unwrap Error](#toc-Attempt-to-Unwrap-Error) [§](#Attempt-to-Unwrap-Error)

At compile-time:

    comptime {
        const number = getNumberOrFail() catch unreachable;
        _ = number;
    }

    fn getNumberOrFail() !i32 {
        return error.UnableToReturnNumber;
    }

test_comptime_unwrap_error.zig

    $ zig test test_comptime_unwrap_error.zig
    /home/andy/src/zig/doc/langref/test_comptime_unwrap_error.zig:2:44: error: caught unexpected error 'UnableToReturnNumber'
        const number = getNumberOrFail() catch unreachable;
                                               ^~~~~~~~~~~
    /home/andy/src/zig/doc/langref/test_comptime_unwrap_error.zig:7:18: note: error returned here
        return error.UnableToReturnNumber;
                     ^~~~~~~~~~~~~~~~~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        const number = getNumberOrFail() catch unreachable;
        std.debug.print("value: {}\n", .{number});
    }

    fn getNumberOrFail() !i32 {
        return error.UnableToReturnNumber;
    }

runtime_unwrap_error.zig

    $ zig build-exe runtime_unwrap_error.zig
    $ ./runtime_unwrap_error
    thread 935569 panic: attempt to unwrap error: UnableToReturnNumber
    error return context:
    /home/andy/src/zig/doc/langref/runtime_unwrap_error.zig:9:5: 0x11d57fc in getNumberOrFail (runtime_unwrap_error.zig)
        return error.UnableToReturnNumber;
        ^

    stack trace:
    /home/andy/src/zig/doc/langref/runtime_unwrap_error.zig:4:44: 0x11d5863 in main (runtime_unwrap_error.zig)
        const number = getNumberOrFail() catch unreachable;
                                               ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

One way to avoid this crash is to test for an error instead of assuming a successful result, with the `if` expression:

    const print = @import("std").debug.print;

    pub fn main() void {
        const result = getNumberOrFail();

        if (result) |number| {
            print("got number: {}\n", .{number});
        } else |err| {
            print("got error: {s}\n", .{@errorName(err)});
        }
    }

    fn getNumberOrFail() !i32 {
        return error.UnableToReturnNumber;
    }

testing_error_with_if.zig

    $ zig build-exe testing_error_with_if.zig
    $ ./testing_error_with_if
    got error: UnableToReturnNumber

Shell

See also:

- [Errors](#Errors)

### [Invalid Error Code](#toc-Invalid-Error-Code) [§](#Invalid-Error-Code)

At compile-time:

    comptime {
        _ = @errorFromInt(12345);
    }

test_comptime_invalid_error_code.zig

    $ zig test test_comptime_invalid_error_code.zig
    /home/andy/src/zig/doc/langref/test_comptime_invalid_error_code.zig:2:23: error: integer value '12345' represents no error
        _ = @errorFromInt(12345);
                          ^~~~~

Shell

At runtime:

    const std = @import("std");

    pub fn main() void {
        const err = error.AnError;
        var number = @intFromError(err) + 500;
        _ = &number;
        const invalid_err = @errorFromInt(number);
        std.debug.print("value: {}\n", .{invalid_err});
    }

runtime_invalid_error_code.zig

    $ zig build-exe runtime_invalid_error_code.zig
    $ ./runtime_invalid_error_code
    thread 926286 panic: invalid error code
    /home/andy/src/zig/doc/langref/runtime_invalid_error_code.zig:7:5: 0x11d5837 in main (runtime_invalid_error_code.zig)
        const invalid_err = @errorFromInt(number);
        ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Invalid Enum Cast](#toc-Invalid-Enum-Cast) [§](#Invalid-Enum-Cast)

At compile-time:

    const Foo = enum {
        a,
        b,
        c,
    };
    comptime {
        const a: u2 = 3;
        const b: Foo = @enumFromInt(a);
        _ = b;
    }

test_comptime_invalid_enum_cast.zig

    $ zig test test_comptime_invalid_enum_cast.zig
    /home/andy/src/zig/doc/langref/test_comptime_invalid_enum_cast.zig:8:20: error: enum 'test_comptime_invalid_enum_cast.Foo' has no tag with value '3'
        const b: Foo = @enumFromInt(a);
                       ^~~~~~~~~~~~~~~
    /home/andy/src/zig/doc/langref/test_comptime_invalid_enum_cast.zig:1:13: note: enum declared here
    const Foo = enum {
                ^~~~

Shell

At runtime:

    const std = @import("std");

    const Foo = enum {
        a,
        b,
        c,
    };

    pub fn main() void {
        var a: u2 = 3;
        _ = &a;
        const b: Foo = @enumFromInt(a);
        std.debug.print("value: {s}\n", .{@tagName(b)});
    }

runtime_invalid_enum_cast.zig

    $ zig build-exe runtime_invalid_enum_cast.zig
    $ ./runtime_invalid_enum_cast
    thread 926295 panic: invalid enum value
    /home/andy/src/zig/doc/langref/runtime_invalid_enum_cast.zig:12:20: 0x11d5880 in main (runtime_invalid_enum_cast.zig)
        const b: Foo = @enumFromInt(a);
                       ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Invalid Error Set Cast](#toc-Invalid-Error-Set-Cast) [§](#Invalid-Error-Set-Cast)

At compile-time:

    const Set1 = error{
        A,
        B,
    };
    const Set2 = error{
        A,
        C,
    };
    comptime {
        _ = @as(Set2, @errorCast(Set1.B));
    }

test_comptime_invalid_error_set_cast.zig

    $ zig test test_comptime_invalid_error_set_cast.zig
    /home/andy/src/zig/doc/langref/test_comptime_invalid_error_set_cast.zig:10:19: error: 'error.B' not a member of error set 'error{A,C}'
        _ = @as(Set2, @errorCast(Set1.B));
                      ^~~~~~~~~~~~~~~~~~

Shell

At runtime:

    const std = @import("std");

    const Set1 = error{
        A,
        B,
    };
    const Set2 = error{
        A,
        C,
    };
    pub fn main() void {
        foo(Set1.B);
    }
    fn foo(set1: Set1) void {
        const x: Set2 = @errorCast(set1);
        std.debug.print("value: {}\n", .{x});
    }

runtime_invalid_error_set_cast.zig

    $ zig build-exe runtime_invalid_error_set_cast.zig
    $ ./runtime_invalid_error_set_cast
    thread 927253 panic: invalid error code
    /home/andy/src/zig/doc/langref/runtime_invalid_error_set_cast.zig:15:21: 0x11d58fc in foo (runtime_invalid_error_set_cast.zig)
        const x: Set2 = @errorCast(set1);
                        ^
    /home/andy/src/zig/doc/langref/runtime_invalid_error_set_cast.zig:12:8: 0x11d5807 in main (runtime_invalid_error_set_cast.zig)
        foo(Set1.B);
           ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Incorrect Pointer Alignment](#toc-Incorrect-Pointer-Alignment) [§](#Incorrect-Pointer-Alignment)

At compile-time:

    comptime {
        const ptr: *align(1) i32 = @ptrFromInt(0x1);
        const aligned: *align(4) i32 = @alignCast(ptr);
        _ = aligned;
    }

test_comptime_incorrect_pointer_alignment.zig

    $ zig test test_comptime_incorrect_pointer_alignment.zig
    /home/andy/src/zig/doc/langref/test_comptime_incorrect_pointer_alignment.zig:3:47: error: pointer address 0x1 is not aligned to 4 bytes
        const aligned: *align(4) i32 = @alignCast(ptr);
                                                  ^~~

Shell

At runtime:

    const mem = @import("std").mem;
    pub fn main() !void {
        var array align(4) = [_]u32{ 0x11111111, 0x11111111 };
        const bytes = mem.sliceAsBytes(array[0..]);
        if (foo(bytes) != 0x11111111) return error.Wrong;
    }
    fn foo(bytes: []u8) u32 {
        const slice4 = bytes[1..5];
        const int_slice = mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(slice4)));
        return int_slice[0];
    }

runtime_incorrect_pointer_alignment.zig

    $ zig build-exe runtime_incorrect_pointer_alignment.zig
    $ ./runtime_incorrect_pointer_alignment
    thread 927819 panic: incorrect alignment
    /home/andy/src/zig/doc/langref/runtime_incorrect_pointer_alignment.zig:9:64: 0x11d6176 in foo (runtime_incorrect_pointer_alignment.zig)
        const int_slice = mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(slice4)));
                                                                   ^
    /home/andy/src/zig/doc/langref/runtime_incorrect_pointer_alignment.zig:5:12: 0x11d4bde in main (runtime_incorrect_pointer_alignment.zig)
        if (foo(bytes) != 0x11111111) return error.Wrong;
               ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d51cc in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Wrong Union Field Access](#toc-Wrong-Union-Field-Access) [§](#Wrong-Union-Field-Access)

At compile-time:

    comptime {
        var f = Foo{ .int = 42 };
        f.float = 12.34;
    }

    const Foo = union {
        float: f32,
        int: u32,
    };

test_comptime_wrong_union_field_access.zig

    $ zig test test_comptime_wrong_union_field_access.zig
    /home/andy/src/zig/doc/langref/test_comptime_wrong_union_field_access.zig:3:6: error: access of union field 'float' while field 'int' is active
        f.float = 12.34;
        ~^~~~~~
    /home/andy/src/zig/doc/langref/test_comptime_wrong_union_field_access.zig:6:13: note: union declared here
    const Foo = union {
                ^~~~~

Shell

At runtime:

    const std = @import("std");

    const Foo = union {
        float: f32,
        int: u32,
    };

    pub fn main() void {
        var f = Foo{ .int = 42 };
        bar(&f);
    }

    fn bar(f: *Foo) void {
        f.float = 12.34;
        std.debug.print("value: {}\n", .{f.float});
    }

runtime_wrong_union_field_access.zig

    $ zig build-exe runtime_wrong_union_field_access.zig
    $ ./runtime_wrong_union_field_access
    thread 932701 panic: access of union field 'float' while field 'int' is active
    /home/andy/src/zig/doc/langref/runtime_wrong_union_field_access.zig:14:6: 0x11d58ce in bar (runtime_wrong_union_field_access.zig)
        f.float = 12.34;
         ^
    /home/andy/src/zig/doc/langref/runtime_wrong_union_field_access.zig:10:8: 0x11d580e in main (runtime_wrong_union_field_access.zig)
        bar(&f);
           ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

This safety is not available for `extern` or `packed` unions.

To change the active field of a union, assign the entire union, like this:

    const std = @import("std");

    const Foo = union {
        float: f32,
        int: u32,
    };

    pub fn main() void {
        var f = Foo{ .int = 42 };
        bar(&f);
    }

    fn bar(f: *Foo) void {
        f.* = Foo{ .float = 12.34 };
        std.debug.print("value: {}\n", .{f.float});
    }

change_active_union_field.zig

    $ zig build-exe change_active_union_field.zig
    $ ./change_active_union_field
    value: 12.34

Shell

To change the active field of a union when a meaningful value for the field is not known, use [undefined](#undefined), like this:

    const std = @import("std");

    const Foo = union {
        float: f32,
        int: u32,
    };

    pub fn main() void {
        var f = Foo{ .int = 42 };
        f = Foo{ .float = undefined };
        bar(&f);
        std.debug.print("value: {}\n", .{f.float});
    }

    fn bar(f: *Foo) void {
        f.float = 12.34;
    }

undefined_active_union_field.zig

    $ zig build-exe undefined_active_union_field.zig
    $ ./undefined_active_union_field
    value: 12.34

Shell

See also:

- [union](#union)
- [extern union](#extern-union)

### [Out of Bounds Float to Integer Cast](#toc-Out-of-Bounds-Float-to-Integer-Cast) [§](#Out-of-Bounds-Float-to-Integer-Cast)

This happens when casting a float to an integer where the float has a value outside the integer type's range.

At compile-time:

    comptime {
        const float: f32 = 4294967296;
        const int: i32 = @intFromFloat(float);
        _ = int;
    }

test_comptime_out_of_bounds_float_to_integer_cast.zig

    $ zig test test_comptime_out_of_bounds_float_to_integer_cast.zig
    /home/andy/src/zig/doc/langref/test_comptime_out_of_bounds_float_to_integer_cast.zig:3:36: error: float value '4294967296' cannot be stored in integer type 'i32'
        const int: i32 = @intFromFloat(float);
                                       ^~~~~

Shell

At runtime:

    pub fn main() void {
        var float: f32 = 4294967296; // runtime-known
        _ = &float;
        const int: i32 = @intFromFloat(float);
        _ = int;
    }

runtime_out_of_bounds_float_to_integer_cast.zig

    $ zig build-exe runtime_out_of_bounds_float_to_integer_cast.zig
    $ ./runtime_out_of_bounds_float_to_integer_cast
    thread 935571 panic: integer part of floating point value out of bounds
    /home/andy/src/zig/doc/langref/runtime_out_of_bounds_float_to_integer_cast.zig:4:22: 0x11d583f in main (runtime_out_of_bounds_float_to_integer_cast.zig)
        const int: i32 = @intFromFloat(float);
                         ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

### [Pointer Cast Invalid Null](#toc-Pointer-Cast-Invalid-Null) [§](#Pointer-Cast-Invalid-Null)

This happens when casting a pointer with the address 0 to a pointer which may not have the address 0. For example, [C Pointers](#C-Pointers), [Optional Pointers](#Optional-Pointers), and [allowzero](#allowzero) pointers allow address zero, but normal [Pointers](#Pointers) do not.

At compile-time:

    comptime {
        const opt_ptr: ?*i32 = null;
        const ptr: *i32 = @ptrCast(opt_ptr);
        _ = ptr;
    }

test_comptime_invalid_null_pointer_cast.zig

    $ zig test test_comptime_invalid_null_pointer_cast.zig
    /home/andy/src/zig/doc/langref/test_comptime_invalid_null_pointer_cast.zig:3:32: error: null pointer casted to type '*i32'
        const ptr: *i32 = @ptrCast(opt_ptr);
                                   ^~~~~~~

Shell

At runtime:

    pub fn main() void {
        var opt_ptr: ?*i32 = null;
        _ = &opt_ptr;
        const ptr: *i32 = @ptrCast(opt_ptr);
        _ = ptr;
    }

runtime_invalid_null_pointer_cast.zig

    $ zig build-exe runtime_invalid_null_pointer_cast.zig
    $ ./runtime_invalid_null_pointer_cast
    thread 931960 panic: cast causes pointer to be null
    /home/andy/src/zig/doc/langref/runtime_invalid_null_pointer_cast.zig:4:23: 0x11d581a in main (runtime_invalid_null_pointer_cast.zig)
        const ptr: *i32 = @ptrCast(opt_ptr);
                          ^
    /home/andy/src/zig/lib/std/start.zig:685:59: 0x11d5121 in callMain (std.zig)
        if (fn_info.params.len == 0) return wrapMain(root.main());
                                                              ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x11d4b81 in _start (std.zig)
        asm volatile (switch (native_arch) {
        ^
    (process terminated by signal)

Shell

