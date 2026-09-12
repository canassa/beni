# Functions


    const std = @import("std");
    const builtin = @import("builtin");
    const native_arch = builtin.cpu.arch;
    const expectEqual = std.testing.expectEqual;

    // Functions are declared like this
    fn add(a: i8, b: i8) i8 {
        if (a == 0) {
            return b;
        }

        return a + b;
    }

    // The export specifier makes a function externally visible in the generated
    // object file, and makes it use the C ABI.
    export fn sub(a: i8, b: i8) i8 {
        return a - b;
    }

    // The extern specifier is used to declare a function that will be resolved
    // at link time, when linking statically, or at runtime, when linking
    // dynamically. The quoted identifier after the extern keyword specifies
    // the library that has the function. (e.g. "c" -> libc.so)
    // The callconv specifier changes the calling convention of the function.
    extern "kernel32" fn ExitProcess(exit_code: u32) callconv(.winapi) noreturn;
    extern "c" fn atan2(a: f64, b: f64) f64;

    // The @branchHint builtin can be used to tell the optimizer that a function is rarely called ("cold").
    fn abort() noreturn {
        @branchHint(.cold);
        while (true) {}
    }

    // The naked calling convention makes a function not have any function prologue or epilogue.
    // This can be useful when integrating with assembly.
    fn _start() callconv(.naked) noreturn {
        abort();
    }

    // The inline calling convention forces a function to be inlined at all call sites.
    // If the function cannot be inlined, it is a compile-time error.
    inline fn shiftLeftOne(a: u32) u32 {
        return a << 1;
    }

    // The pub specifier allows the function to be visible when importing.
    // Another file can use @import and call sub2
    pub fn sub2(a: i8, b: i8) i8 {
        return a - b;
    }

    // Function pointers are prefixed with `*const `.
    const Call2Op = *const fn (a: i8, b: i8) i8;
    fn doOp(fnCall: Call2Op, op1: i8, op2: i8) i8 {
        return fnCall(op1, op2);
    }

    test "function" {
        try expectEqual(11, doOp(add, 5, 6));
        try expectEqual(-1, doOp(sub2, 5, 6));
    }

test_functions.zig

    $ zig test test_functions.zig
    1/1 test_functions.test.function...OK
    All 1 tests passed.

Shell

There is a difference between a function *body* and a function *pointer*. Function bodies are [comptime](#comptime)-only types while function [Pointers](#Pointers) may be runtime-known.

### [Pass-by-value Parameters](#toc-Pass-by-value-Parameters) [§](#Pass-by-value-Parameters)

Primitive types such as [Integers](#Integers) and [Floats](#Floats) passed as parameters are copied, and then the copy is available in the function body. This is called "passing by value". Copying a primitive type is essentially free and typically involves nothing more than setting a register.

Structs, unions, and arrays can sometimes be more efficiently passed as a reference, since a copy could be arbitrarily expensive depending on the size. When these types are passed as parameters, Zig may choose to copy and pass by value, or pass by reference, whichever way Zig decides will be faster. This is made possible, in part, by the fact that parameters are immutable.

    const Point = struct {
        x: i32,
        y: i32,
    };

    fn foo(point: Point) i32 {
        // Here, `point` could be a reference, or a copy. The function body
        // can ignore the difference and treat it as a value. Be very careful
        // taking the address of the parameter - it should be treated as if
        // the address will become invalid when the function returns.
        return point.x + point.y;
    }

    const expectEqual = @import("std").testing.expectEqual;

    test "pass struct to function" {
        try expectEqual(3, foo(Point{ .x = 1, .y = 2 }));
    }

test_pass_by_reference_or_value.zig

    $ zig test test_pass_by_reference_or_value.zig
    1/1 test_pass_by_reference_or_value.test.pass struct to function...OK
    All 1 tests passed.

Shell

For extern functions, Zig follows the C ABI for passing structs and unions by value.

### [Function Parameter Type Inference](#toc-Function-Parameter-Type-Inference) [§](#Function-Parameter-Type-Inference)

Function parameters can be declared with `anytype` in place of the type. In this case the parameter types will be inferred when the function is called. Use [@TypeOf](#TypeOf) and [@typeInfo](#typeInfo) to get information about the inferred type.

    const expectEqual = @import("std").testing.expectEqual;

    fn addFortyTwo(x: anytype) @TypeOf(x) {
        return x + 42;
    }

    test "fn type inference" {
        try expectEqual(43, addFortyTwo(1));
        try expectEqual(comptime_int, @TypeOf(addFortyTwo(1)));
        const y: i64 = 2;
        try expectEqual(44, addFortyTwo(y));
        try expectEqual(i64, @TypeOf(addFortyTwo(y)));
    }

test_fn_type_inference.zig

    $ zig test test_fn_type_inference.zig
    1/1 test_fn_type_inference.test.fn type inference...OK
    All 1 tests passed.

Shell

### [inline fn](#toc-inline-fn) [§](#inline-fn)

Adding the `inline` keyword to a function definition makes that function become *semantically inlined* at the callsite. This is not a hint to be possibly observed by optimization passes, but has implications on the types and values involved in the function call.

Unlike normal function calls, arguments at an inline function callsite which are compile-time known are treated as [Compile Time Parameters](#Compile-Time-Parameters). This can potentially propagate all the way to the return value:

    const std = @import("std");

    pub fn main() void {
        if (foo(1200, 34) != 1234) {
            @compileError("bad");
        }
    }

    inline fn foo(a: i32, b: i32) i32 {
        std.debug.print("runtime a = {} b = {}", .{ a, b });
        return a + b;
    }

inline_call.zig

    $ zig build-exe inline_call.zig
    $ ./inline_call
    runtime a = 1200 b = 34

Shell

If `inline` is removed, the test fails with the compile error instead of passing.

It is generally better to let the compiler decide when to inline a function, except for these scenarios:

- To change how many stack frames are in the call stack, for debugging purposes.
- To force comptime-ness of the arguments to propagate to the return value of the function, as in the above example.
- Real world performance measurements demand it.

Note that `inline` actually *restricts* what the compiler is allowed to do. This can harm binary size, compilation speed, and even runtime performance.

### [Function Reflection](#toc-Function-Reflection) [§](#Function-Reflection)

    const std = @import("std");
    const math = std.math;
    const testing = std.testing;

    test "fn reflection" {
        try testing.expectEqual(bool, @typeInfo(@TypeOf(testing.expect)).@"fn".params[0].type.?);
        try testing.expectEqual(testing.TmpDir, @typeInfo(@TypeOf(testing.tmpDir)).@"fn".return_type.?);

        try testing.expect(@typeInfo(@TypeOf(math.Log2Int)).@"fn".is_generic);
    }

test_fn_reflection.zig

    $ zig test test_fn_reflection.zig
    1/1 test_fn_reflection.test.fn reflection...OK
    All 1 tests passed.

Shell

