# Builtin Functions


Builtin functions are provided by the compiler and are prefixed with `@`. The `comptime` keyword on a parameter means that the parameter must be known at compile time.

### [@addrSpaceCast](#toc-addrSpaceCast) [§](#addrSpaceCast)

    @addrSpaceCast(ptr: anytype) anytype

Converts a pointer from one address space to another. The new address space is inferred based on the result type. Depending on the current target and address spaces, this cast may be a no-op, a complex operation, or illegal. If the cast is legal, then the resulting pointer points to the same memory location as the pointer operand. It is always valid to cast a pointer between the same address spaces.

### [@addWithOverflow](#toc-addWithOverflow) [§](#addWithOverflow)

    @addWithOverflow(a: anytype, b: anytype) struct { @TypeOf(a, b), u1 }

Performs `a + b` and returns a tuple with the result and a possible overflow bit.

### [@alignCast](#toc-alignCast) [§](#alignCast)

    @alignCast(ptr: anytype) anytype

`ptr` can be `*T`, `?*T`, or `[]T`. Changes the alignment of a pointer. The alignment to use is inferred based on the result type.

A [pointer alignment safety check](#Incorrect-Pointer-Alignment) is added to the generated code to make sure the pointer is aligned as promised.

### [@alignOf](#toc-alignOf) [§](#alignOf)

    @alignOf(comptime T: type) comptime_int

This function returns the number of bytes that this type should be aligned to for the current target to match the C ABI. When the child type of a pointer has this alignment, the alignment can be omitted from the type.

    const assert = @import("std").debug.assert;
    comptime {
        assert(*u32 == *align(@alignOf(u32)) u32);
    }

The result is a target-specific compile time constant. It is guaranteed to be less than or equal to [@sizeOf(T)](#sizeOf).

See also:

- [Alignment](#Alignment)

### [@as](#toc-as) [§](#as)

    @as(comptime T: type, expression) T

Performs [Type Coercion](#Type-Coercion). This cast is allowed when the conversion is unambiguous and safe, and is the preferred way to convert between types, whenever possible.

### [@atomicLoad](#toc-atomicLoad) [§](#atomicLoad)

    @atomicLoad(comptime T: type, ptr: *const T, comptime ordering: AtomicOrder) T

This builtin function atomically dereferences a pointer to a `T` and returns the value.

`T` must be a pointer, a `bool`, a float, an integer, an enum, or a packed struct.

`AtomicOrder` can be found with `@import``(``"std"``).builtin.AtomicOrder`.

See also:

- [@atomicStore](#atomicStore)
- [@atomicRmw](#atomicRmw)
- [@cmpxchgWeak](#cmpxchgWeak)
- [@cmpxchgStrong](#cmpxchgStrong)

### [@atomicRmw](#toc-atomicRmw) [§](#atomicRmw)

    @atomicRmw(comptime T: type, ptr: *T, comptime op: AtomicRmwOp, operand: T, comptime ordering: AtomicOrder) T

This builtin function dereferences a pointer to a `T` and atomically modifies the value and returns the previous value.

`T` must be a pointer, a `bool`, a float, an integer, an enum, or a packed struct.

`AtomicOrder` can be found with `@import``(``"std"``).builtin.AtomicOrder`.

`AtomicRmwOp` can be found with `@import``(``"std"``).builtin.AtomicRmwOp`.

See also:

- [@atomicStore](#atomicStore)
- [@atomicLoad](#atomicLoad)
- [@cmpxchgWeak](#cmpxchgWeak)
- [@cmpxchgStrong](#cmpxchgStrong)

### [@atomicStore](#toc-atomicStore) [§](#atomicStore)

    @atomicStore(comptime T: type, ptr: *T, value: T, comptime ordering: AtomicOrder) void

This builtin function dereferences a pointer to a `T` and atomically stores the given value.

`T` must be a pointer, a `bool`, a float, an integer, an enum, or a packed struct.

`AtomicOrder` can be found with `@import``(``"std"``).builtin.AtomicOrder`.

See also:

- [@atomicLoad](#atomicLoad)
- [@atomicRmw](#atomicRmw)
- [@cmpxchgWeak](#cmpxchgWeak)
- [@cmpxchgStrong](#cmpxchgStrong)

### [@bitCast](#toc-bitCast) [§](#bitCast)

    @bitCast(value: anytype) anytype

Converts a value of one type to another type. The return type is the inferred result type.

Asserts that `@sizeOf``(``@TypeOf``(value)) == ``@sizeOf``(DestType)`.

Asserts that `@typeInfo``(DestType) != .pointer`. Use `@ptrCast` or `@ptrFromInt` if you need this.

Can be used for these things for example:

- Convert `f32` to `u32` bits
- Convert `i32` to `u32` preserving twos complement

Works at compile-time if `value` is known at compile time. It's a compile error to bitcast a value of undefined layout; this means that, besides the restriction from types which possess dedicated casting builtins (enums, pointers, error sets), bare structs, error unions, slices, optionals, and any other type without a well-defined memory layout, also cannot be used in this operation.

### [@bitOffsetOf](#toc-bitOffsetOf) [§](#bitOffsetOf)

    @bitOffsetOf(comptime T: type, comptime field_name: []const u8) comptime_int

Returns the bit offset of a field relative to its containing struct.

For non [packed structs](#packed-struct), this will always be divisible by `8`. For packed structs, non-byte-aligned fields will share a byte offset, but they will have different bit offsets.

See also:

- [@offsetOf](#offsetOf)

### [@bitSizeOf](#toc-bitSizeOf) [§](#bitSizeOf)

    @bitSizeOf(comptime T: type) comptime_int

This function returns the number of bits it takes to store `T` in memory if the type were a field in a packed struct/union. The result is a target-specific compile time constant.

This function measures the size at runtime. For types that are disallowed at runtime, such as `comptime_int` and `type`, the result is `0`.

See also:

- [@sizeOf](#sizeOf)
- [@typeInfo](#typeInfo)

### [@branchHint](#toc-branchHint) [§](#branchHint)

    @branchHint(hint: BranchHint) void

Hints to the optimizer how likely a given branch of control flow is to be reached.

`BranchHint` can be found with `@import``(``"std"``).builtin.BranchHint`.

This function is only valid as the first statement in a control flow branch, or the first statement in a function.

### [@breakpoint](#toc-breakpoint) [§](#breakpoint)

    @breakpoint() void

This function inserts a platform-specific debug trap instruction which causes debuggers to break there. Unlike for `@trap``()`, execution may continue after this point if the program is resumed.

This function is only valid within function scope.

See also:

- [@trap](#trap)

### [@mulAdd](#toc-mulAdd) [§](#mulAdd)

    @mulAdd(comptime T: type, a: T, b: T, c: T) T

Fused multiply-add, similar to `(a * b) + c`, except only rounds once, and is thus more accurate.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@byteSwap](#toc-byteSwap) [§](#byteSwap)

    @byteSwap(operand: anytype) T

`@TypeOf``(operand)` must be an integer type or an integer vector type with bit count evenly divisible by 8.

`operand` may be an [integer](#Integers) or [vector](#Vectors).

Swaps the byte order of the integer. This converts a big endian integer to a little endian integer, and converts a little endian integer to a big endian integer.

Note that for the purposes of memory layout with respect to endianness, the integer type should be related to the number of bytes reported by [@sizeOf](#sizeOf) bytes. This is demonstrated with `u24`. `@sizeOf``(``u24``) == ``4`, which means that a `u24` stored in memory takes 4 bytes, and those 4 bytes are what are swapped on a little vs big endian system. On the other hand, if `T` is specified to be `u24`, then only 3 bytes are reversed.

### [@bitReverse](#toc-bitReverse) [§](#bitReverse)

    @bitReverse(integer: anytype) T

`@TypeOf``(``anytype``)` accepts any integer type or integer vector type.

Reverses the bitpattern of an integer value, including the sign bit if applicable.

For example 0b10110110 (`u8`` = ``182`, `i8`` = -``74`) becomes 0b01101101 (`u8`` = ``109`, `i8`` = ``109`).

### [@offsetOf](#toc-offsetOf) [§](#offsetOf)

    @offsetOf(comptime T: type, comptime field_name: []const u8) comptime_int

Returns the byte offset of a field relative to its containing struct.

See also:

- [@bitOffsetOf](#bitOffsetOf)

### [@call](#toc-call) [§](#call)

    @call(modifier: std.builtin.CallModifier, function: anytype, args: anytype) anytype

Calls a function, in the same way that invoking an expression with parentheses does:

    const expectEqual = @import("std").testing.expectEqual;

    test "noinline function call" {
        try expectEqual(12, @call(.auto, add, .{ 3, 9 }));
    }

    fn add(a: i32, b: i32) i32 {
        return a + b;
    }

test_call_builtin.zig

    $ zig test test_call_builtin.zig
    1/1 test_call_builtin.test.noinline function call...OK
    All 1 tests passed.

Shell

`@call` allows more flexibility than normal function call syntax does. The `CallModifier` enum is reproduced here:

    pub const CallModifier = enum {
        /// Equivalent to function call syntax.
        auto,

        /// Prevents tail call optimization. This guarantees that the return
        /// address will point to the callsite, as opposed to the callsite's
        /// callsite. If the call is otherwise required to be tail-called
        /// or inlined, a compile error is emitted instead.
        never_tail,

        /// Guarantees that the call will not be inlined. If the call is
        /// otherwise required to be inlined, a compile error is emitted instead.
        never_inline,

        /// Asserts that the function call will not suspend. This allows a
        /// non-async function to call an async function.
        no_suspend,

        /// Guarantees that the call will be generated with tail call optimization.
        /// If this is not possible, a compile error is emitted instead.
        always_tail,

        /// Guarantees that the call will be inlined at the callsite.
        /// If this is not possible, a compile error is emitted instead.
        always_inline,

        /// Evaluates the call at compile-time. If the call cannot be completed at
        /// compile-time, a compile error is emitted instead.
        compile_time,
    };

builtin.CallModifier struct.zig

### [@cDefine](#toc-cDefine) [§](#cDefine)

    @cDefine(comptime name: []const u8, value) void

This function can only occur inside `@cImport`.

This appends `#define $name $value` to the `@cImport` temporary buffer.

To define without a value, like this:

``` c
#define _GNU_SOURCE
```

Use the void value, like this:

    @cDefine("_GNU_SOURCE", {})

See also:

- [Import from C Header File](#Import-from-C-Header-File)
- [@cInclude](#cInclude)
- [@cImport](#cImport)
- [@cUndef](#cUndef)
- [void](#void)

### [@cImport](#toc-cImport) [§](#cImport)

    @cImport(expression) type

This function parses C code and imports the functions, types, variables, and compatible macro definitions into a new empty struct type, and then returns that type.

`expression` is interpreted at compile time. The builtin functions `@cInclude`, `@cDefine`, and `@cUndef` work within this expression, appending to a temporary buffer which is then parsed as C code.

Usually you should only have one `@cImport` in your entire application, because it saves the compiler from invoking clang multiple times, and prevents inline functions from being duplicated.

Reasons for having multiple `@cImport` expressions would be:

- To avoid a symbol collision, for example if foo.h and bar.h both `#define CONNECTION_COUNT`
- To analyze the C code with different preprocessor defines

See also:

- [Import from C Header File](#Import-from-C-Header-File)
- [@cInclude](#cInclude)
- [@cDefine](#cDefine)
- [@cUndef](#cUndef)

### [@cInclude](#toc-cInclude) [§](#cInclude)

    @cInclude(comptime path: []const u8) void

This function can only occur inside `@cImport`.

This appends `#include <$path>\n` to the `c_import` temporary buffer.

See also:

- [Import from C Header File](#Import-from-C-Header-File)
- [@cImport](#cImport)
- [@cDefine](#cDefine)
- [@cUndef](#cUndef)

### [@clz](#toc-clz) [§](#clz)

    @clz(operand: anytype) anytype

`@TypeOf``(operand)` must be an integer type or an integer vector type.

`operand` may be an [integer](#Integers) or [vector](#Vectors).

Counts the number of most-significant (leading in a big-endian sense) zeroes in an integer - "count leading zeroes".

The return type is an unsigned integer or vector of unsigned integers with the minimum number of bits that can represent the bit count of the integer type.

If `operand` is zero, `@clz` returns the bit width of integer type `T`.

See also:

- [@ctz](#ctz)
- [@popCount](#popCount)

### [@cmpxchgStrong](#toc-cmpxchgStrong) [§](#cmpxchgStrong)

    @cmpxchgStrong(comptime T: type, ptr: *T, expected_value: T, new_value: T, success_order: AtomicOrder, fail_order: AtomicOrder) ?T

This function performs a strong atomic compare-and-exchange operation, returning `null` if the current value is the given expected value. It's the equivalent of this code, except atomic:

    fn cmpxchgStrongButNotAtomic(comptime T: type, ptr: *T, expected_value: T, new_value: T) ?T {
        const old_value = ptr.*;
        if (old_value == expected_value) {
            ptr.* = new_value;
            return null;
        } else {
            return old_value;
        }
    }

not_atomic_cmpxchgStrong.zig

If you are using cmpxchg in a retry loop, [@cmpxchgWeak](#cmpxchgWeak) is the better choice, because it can be implemented more efficiently in machine instructions.

`T` must be a pointer, a `bool`, an integer, an enum, or a packed struct.

`@typeInfo``(``@TypeOf``(ptr)).pointer.alignment` must be `>= ``@sizeOf``(T).`

`AtomicOrder` can be found with `@import``(``"std"``).builtin.AtomicOrder`.

See also:

- [@atomicStore](#atomicStore)
- [@atomicLoad](#atomicLoad)
- [@atomicRmw](#atomicRmw)
- [@cmpxchgWeak](#cmpxchgWeak)

### [@cmpxchgWeak](#toc-cmpxchgWeak) [§](#cmpxchgWeak)

    @cmpxchgWeak(comptime T: type, ptr: *T, expected_value: T, new_value: T, success_order: AtomicOrder, fail_order: AtomicOrder) ?T

This function performs a weak atomic compare-and-exchange operation, returning `null` if the current value is the given expected value. It's the equivalent of this code, except atomic:

    fn cmpxchgWeakButNotAtomic(comptime T: type, ptr: *T, expected_value: T, new_value: T) ?T {
        const old_value = ptr.*;
        if (old_value == expected_value and usuallyTrueButSometimesFalse()) {
            ptr.* = new_value;
            return null;
        } else {
            return old_value;
        }
    }

cmpxchgWeakButNotAtomic

If you are using cmpxchg in a retry loop, the sporadic failure will be no problem, and `cmpxchgWeak` is the better choice, because it can be implemented more efficiently in machine instructions. However if you need a stronger guarantee, use [@cmpxchgStrong](#cmpxchgStrong).

`T` must be a pointer, a `bool`, an integer, an enum, or a packed struct.

`@typeInfo``(``@TypeOf``(ptr)).pointer.alignment` must be `>= ``@sizeOf``(T).`

`AtomicOrder` can be found with `@import``(``"std"``).builtin.AtomicOrder`.

See also:

- [@atomicStore](#atomicStore)
- [@atomicLoad](#atomicLoad)
- [@atomicRmw](#atomicRmw)
- [@cmpxchgStrong](#cmpxchgStrong)

### [@compileError](#toc-compileError) [§](#compileError)

    @compileError(comptime msg: []const u8) noreturn

This function, when semantically analyzed, causes a compile error with the message `msg`.

There are several ways that code avoids being semantically checked, such as using `if` or `switch` with compile time constants, and `comptime` functions.

### [@compileLog](#toc-compileLog) [§](#compileLog)

    @compileLog(...) void

This function prints the arguments passed to it at compile-time.

To prevent accidentally leaving compile log statements in a codebase, a compilation error is added to the build, pointing to the compile log statement. This error prevents code from being generated, but does not otherwise interfere with analysis.

This function can be used to do "printf debugging" on compile-time executing code.

    const print = @import("std").debug.print;

    const num1 = blk: {
        var val1: i32 = 99;
        @compileLog("comptime val1 = ", val1);
        val1 = val1 + 1;
        break :blk val1;
    };

    test "main" {
        @compileLog("comptime in main");

        print("Runtime in main, num1 = {}.\n", .{num1});
    }

test_compileLog_builtin.zig

    $ zig test test_compileLog_builtin.zig
    /home/andy/src/zig/doc/langref/test_compileLog_builtin.zig:5:5: error: found compile log statement
        @compileLog("comptime val1 = ", val1);
        ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    /home/andy/src/zig/doc/langref/test_compileLog_builtin.zig:11:5: note: also here
        @compileLog("comptime in main");
        ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    referenced by:
        test.main: /home/andy/src/zig/doc/langref/test_compileLog_builtin.zig:13:46

    Compile Log Output:
    @as(*const [16:0]u8, "comptime val1 = "), @as(i32, 99)
    @as(*const [16:0]u8, "comptime in main")

Shell

### [@constCast](#toc-constCast) [§](#constCast)

    @constCast(value: anytype) DestType

Remove `const` qualifier from a pointer.

### [@ctz](#toc-ctz) [§](#ctz)

    @ctz(operand: anytype) anytype

`@TypeOf``(operand)` must be an integer type or an integer vector type.

`operand` may be an [integer](#Integers) or [vector](#Vectors).

Counts the number of least-significant (trailing in a big-endian sense) zeroes in an integer - "count trailing zeroes".

The return type is an unsigned integer or vector of unsigned integers with the minimum number of bits that can represent the bit count of the integer type.

If `operand` is zero, `@ctz` returns the bit width of integer type `T`.

See also:

- [@clz](#clz)
- [@popCount](#popCount)

### [@cUndef](#toc-cUndef) [§](#cUndef)

    @cUndef(comptime name: []const u8) void

This function can only occur inside `@cImport`.

This appends `#undef $name` to the `@cImport` temporary buffer.

See also:

- [Import from C Header File](#Import-from-C-Header-File)
- [@cImport](#cImport)
- [@cDefine](#cDefine)
- [@cInclude](#cInclude)

### [@cVaArg](#toc-cVaArg) [§](#cVaArg)

    @cVaArg(operand: *std.builtin.VaList, comptime T: type) T

Implements the C macro `va_arg`.

See also:

- [@cVaCopy](#cVaCopy)
- [@cVaEnd](#cVaEnd)
- [@cVaStart](#cVaStart)

### [@cVaCopy](#toc-cVaCopy) [§](#cVaCopy)

    @cVaCopy(src: *std.builtin.VaList) std.builtin.VaList

Implements the C macro `va_copy`.

See also:

- [@cVaArg](#cVaArg)
- [@cVaEnd](#cVaEnd)
- [@cVaStart](#cVaStart)

### [@cVaEnd](#toc-cVaEnd) [§](#cVaEnd)

    @cVaEnd(src: *std.builtin.VaList) void

Implements the C macro `va_end`.

See also:

- [@cVaArg](#cVaArg)
- [@cVaCopy](#cVaCopy)
- [@cVaStart](#cVaStart)

### [@cVaStart](#toc-cVaStart) [§](#cVaStart)

    @cVaStart() std.builtin.VaList

Implements the C macro `va_start`. Only valid inside a variadic function.

See also:

- [@cVaArg](#cVaArg)
- [@cVaCopy](#cVaCopy)
- [@cVaEnd](#cVaEnd)

### [@divExact](#toc-divExact) [§](#divExact)

    @divExact(numerator: T, denominator: T) T

Exact division. Caller guarantees `denominator != ``0` and `@divTrunc``(numerator, denominator) * denominator == numerator`.

- `@divExact``(``6``, ``3``) == ``2`
- `@divExact``(a, b) * b == a`

For a function that returns a possible error code, use `@import``(``"std"``).math.divExact`.

See also:

- [@divTrunc](#divTrunc)
- [@divFloor](#divFloor)

### [@divFloor](#toc-divFloor) [§](#divFloor)

    @divFloor(numerator: T, denominator: T) T

Floored division. Rounds toward negative infinity. For unsigned integers it is the same as `numerator / denominator`. Caller guarantees `denominator != ``0` and `!(``@typeInfo``(T) == .int ``and`` T.is_signed ``and`` numerator == std.math.minInt(T) ``and`` denominator == -``1``)`.

- `@divFloor``(-``5``, ``3``) == -``2`
- `(``@divFloor``(a, b) * b) + ``@mod``(a, b) == a`

For a function that returns a possible error code, use `@import``(``"std"``).math.divFloor`.

See also:

- [@divTrunc](#divTrunc)
- [@divExact](#divExact)

### [@divTrunc](#toc-divTrunc) [§](#divTrunc)

    @divTrunc(numerator: T, denominator: T) T

Truncated division. Rounds toward zero. For unsigned integers it is the same as `numerator / denominator`. Caller guarantees `denominator != ``0` and `!(``@typeInfo``(T) == .int ``and`` T.is_signed ``and`` numerator == std.math.minInt(T) ``and`` denominator == -``1``)`.

- `@divTrunc``(-``5``, ``3``) == -``1`
- `(``@divTrunc``(a, b) * b) + ``@rem``(a, b) == a`

For a function that returns a possible error code, use `@import``(``"std"``).math.divTrunc`.

See also:

- [@divFloor](#divFloor)
- [@divExact](#divExact)

### [@embedFile](#toc-embedFile) [§](#embedFile)

    @embedFile(comptime path: []const u8) *const [N:0]u8

This function returns a compile time constant pointer to null-terminated, fixed-size array with length equal to the byte count of the file given by `path`. The contents of the array are the contents of the file. This is equivalent to a [string literal](#String-Literals-and-Unicode-Code-Point-Literals) with the file contents.

`path` is absolute or relative to the current file, just like `@import`.

See also:

- [@import](#import)

### [@enumFromInt](#toc-enumFromInt) [§](#enumFromInt)

    @enumFromInt(integer: anytype) anytype

Converts an integer into an [enum](#enum) value. The return type is the inferred result type.

Attempting to convert an integer with no corresponding value in the enum invokes safety-checked [Illegal Behavior](#Illegal-Behavior). Note that a [non-exhaustive enum](#Non-exhaustive-enum) has corresponding values for all integers in the enum's integer tag type: the `_` value represents all the remaining unnamed integers in the enum's tag type.

See also:

- [@intFromEnum](#intFromEnum)

### [@errorFromInt](#toc-errorFromInt) [§](#errorFromInt)

    @errorFromInt(value: @Int(.unsigned, @bitSizeOf(anyerror))) anyerror

Converts from the integer representation of an error into [The Global Error Set](#The-Global-Error-Set) type.

It is generally recommended to avoid this cast, as the integer representation of an error is not stable across source code changes.

Attempting to convert an integer that does not correspond to any error results in safety-checked [Illegal Behavior](#Illegal-Behavior).

See also:

- [@intFromError](#intFromError)

### [@errorName](#toc-errorName) [§](#errorName)

    @errorName(err: anyerror) [:0]const u8

This function returns the string representation of an error. The string representation of `error``.OutOfMem` is `"OutOfMem"`.

If there are no calls to `@errorName` in an entire application, or all calls have a compile-time known value for `err`, then no error name table will be generated.

### [@errorReturnTrace](#toc-errorReturnTrace) [§](#errorReturnTrace)

    @errorReturnTrace() ?*builtin.StackTrace

If the binary is built with error return tracing, and this function is invoked in a function that calls a function with an error or error union return type, returns a stack trace object. Otherwise returns [null](#null).

### [@errorCast](#toc-errorCast) [§](#errorCast)

    @errorCast(value: anytype) anytype

Converts an error set or error union value from one error set to another error set. The return type is the inferred result type. Attempting to convert an error which is not in the destination error set results in safety-checked [Illegal Behavior](#Illegal-Behavior).

### [@export](#toc-export) [§](#export)

    @export(comptime ptr: *const anyopaque, comptime options: std.builtin.ExportOptions) void

Creates a symbol in the output object file which refers to the target of `ptr`.

`ptr` must point to a global variable or a comptime-known constant.

This builtin can be called from a [comptime](#comptime) block to conditionally export symbols. When `ptr` points to a function with the C calling convention and `options.linkage` is `.strong`, this is equivalent to the `export` keyword used on a function:

    comptime {
        @export(&internalName, .{ .name = "foo", .linkage = .strong });
    }

    fn internalName() callconv(.c) void {}

export_builtin.zig

    $ zig build-obj export_builtin.zig

Shell

This is equivalent to:

    export fn foo() void {}

export_builtin_equivalent_code.zig

    $ zig build-obj export_builtin_equivalent_code.zig

Shell

Note that even when using `export`, the `@"foo"` syntax for [identifiers](#Identifiers) can be used to choose any string for the symbol name:

    export fn @"A function name that is a complete sentence."() void {}

export_any_symbol_name.zig

    $ zig build-obj export_any_symbol_name.zig

Shell

When looking at the resulting object, you can see the symbol is used verbatim:

    00000000000001f0 T A function name that is a complete sentence.

See also:

- [Exporting a C Library](#Exporting-a-C-Library)

### [@extern](#toc-extern) [§](#extern)

    @extern(T: type, comptime options: std.builtin.ExternOptions) T

Creates a reference to an external symbol in the output object file. T must be a pointer type.

See also:

- [@export](#export)

### [@field](#toc-field) [§](#field)

    @field(lhs: anytype, comptime field_name: []const u8) (field)

Performs field access by a compile-time string. Works on both fields and declarations.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    const Point = struct {
        x: u32,
        y: u32,

        pub var z: u32 = 1;
    };

    test "field access by string" {
        var p = Point{ .x = 0, .y = 0 };

        @field(p, "x") = 4;
        @field(p, "y") = @field(p, "x") + 1;

        try expectEqual(4, @field(p, "x"));
        try expectEqual(5, @field(p, "y"));
    }

    test "decl access by string" {
        try expectEqual(1, @field(Point, "z"));

        @field(Point, "z") = 2;
        try expectEqual(2, @field(Point, "z"));
    }

test_field_builtin.zig

    $ zig test test_field_builtin.zig
    1/2 test_field_builtin.test.field access by string...OK
    2/2 test_field_builtin.test.decl access by string...OK
    All 2 tests passed.

Shell

### [@fieldParentPtr](#toc-fieldParentPtr) [§](#fieldParentPtr)

    @fieldParentPtr(comptime field_name: []const u8, field_ptr: *T) anytype

Given a pointer to a struct or union field, returns a pointer to the struct or union containing that field. The return type (pointer to the parent struct or union in question) is the inferred result type.

If `field_ptr` does not point to the `field_name` field of an instance of the result type, and the result type has ill-defined layout, invokes unchecked [Illegal Behavior](#Illegal-Behavior).

### [@FieldType](#toc-FieldType) [§](#FieldType)

    @FieldType(comptime Type: type, comptime field_name: []const u8) type

Given a type and the name of one of its fields, returns the type of that field.

### [@floatCast](#toc-floatCast) [§](#floatCast)

    @floatCast(value: anytype) anytype

Convert from one float type to another. This cast is safe, but may cause the numeric value to lose precision. The return type is the inferred result type.

### [@floatFromInt](#toc-floatFromInt) [§](#floatFromInt)

    @floatFromInt(int: anytype) anytype

Converts an integer to the closest floating point representation. The return type is the inferred result type. To convert the other way, use [@intFromFloat](#intFromFloat). This operation is legal for all values of all integer types.

### [@frameAddress](#toc-frameAddress) [§](#frameAddress)

    @frameAddress() usize

This function returns the base pointer of the current stack frame.

The implications of this are target-specific and not consistent across all platforms. The frame address may not be available in release mode due to aggressive optimizations.

This function is only valid within function scope.

### [@hasDecl](#toc-hasDecl) [§](#hasDecl)

    @hasDecl(comptime Container: type, comptime name: []const u8) bool

Returns whether or not a [container](#Containers) has a declaration matching `name`.

    const std = @import("std");
    const expect = std.testing.expect;

    const Foo = struct {
        nope: i32,

        pub var blah = "xxx";
        const hi = 1;
    };

    test "@hasDecl" {
        try expect(@hasDecl(Foo, "blah"));

        // Even though `hi` is private, @hasDecl returns true because this test is
        // in the same file scope as Foo. It would return false if Foo was declared
        // in a different file.
        try expect(@hasDecl(Foo, "hi"));

        // @hasDecl is for declarations; not fields.
        try expect(!@hasDecl(Foo, "nope"));
        try expect(!@hasDecl(Foo, "nope1234"));
    }

test_hasDecl_builtin.zig

    $ zig test test_hasDecl_builtin.zig
    1/1 test_hasDecl_builtin.test.@hasDecl...OK
    All 1 tests passed.

Shell

See also:

- [@hasField](#hasField)

### [@hasField](#toc-hasField) [§](#hasField)

    @hasField(comptime Container: type, comptime name: []const u8) bool

Returns whether the field name of a struct, union, or enum exists.

The result is a compile time constant.

It does not include functions, variables, or constants.

See also:

- [@hasDecl](#hasDecl)

### [@import](#toc-import) [§](#import)

    @import(comptime target: []const u8) anytype

Imports the file at `target`, adding it to the compilation if it is not already added. `target` is either a relative path to another file from the file containing the `@import` call, or it is the name of a [module](#Compilation-Model), with the import referring to the root source file of that module. Either way, the file path must end in either `.zig` (for a Zig source file) or `.zon` (for a ZON data file).

If `target` refers to a Zig source file, then `@import` returns that file's [corresponding struct type](#Source-File-Structs), essentially as if the builtin call was replaced by `struct`` { FILE_CONTENTS }`. The return type is `type`.

If `target` refers to a ZON file, then `@import` returns the value of the literal in the file. If there is an inferred [result type](#Result-Types), then the return type is that type, and the ZON literal is interpreted as that type ([Result Types](#Result-Types) are propagated through the ZON expression). Otherwise, the return type is the type of the equivalent Zig expression, essentially as if the builtin call was replaced by the ZON file contents.

The following modules are always available for import:

- `@import``(``"std"``)` - Zig Standard Library
- `@import``(``"builtin"``)` - Target-specific information. The command `zig build-exe --show-builtin` outputs the source to stdout for reference.
- `@import``(``"root"``)` - Alias for the root module. In typical project structures, this means it refers back to `src/main.zig`.

See also:

- [Compile Variables](#Compile-Variables)
- [@embedFile](#embedFile)

### [@inComptime](#toc-inComptime) [§](#inComptime)

    @inComptime() bool

Returns whether the builtin was run in a `comptime` context. The result is a compile-time constant.

This can be used to provide alternative, comptime-friendly implementations of functions. It should not be used, for instance, to exclude certain functions from being evaluated at comptime.

See also:

- [comptime](#comptime)

### [@intCast](#toc-intCast) [§](#intCast)

    @intCast(int: anytype) anytype

Converts an integer to another integer while keeping the same numerical value. The return type is the inferred result type. Attempting to convert a number which is out of range of the destination type results in safety-checked [Illegal Behavior](#Illegal-Behavior).

    test "integer cast panic" {
        var a: u16 = 0xabcd; // runtime-known
        _ = &a;
        const b: u8 = @intCast(a);
        _ = b;
    }

test_intCast_builtin.zig

    $ zig test test_intCast_builtin.zig
    1/1 test_intCast_builtin.test.integer cast panic...thread 934579 panic: integer does not fit in destination type
    /home/andy/src/zig/doc/langref/test_intCast_builtin.zig:4:19: 0x1234e40 in test.integer cast panic (test_intCast_builtin.zig)
        const b: u8 = @intCast(a);
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
    /home/andy/src/zig/.zig-cache/o/22604da2684fadfdf98324181ed766ec/test --seed=0x9949decf

Shell

To truncate the significant bits of a number out of range of the destination type, use [@truncate](#truncate).

If `T` is `comptime_int`, then this is semantically equivalent to [Type Coercion](#Type-Coercion).

### [@intFromBool](#toc-intFromBool) [§](#intFromBool)

    @intFromBool(value: bool) u1

Converts `true` to `@as``(``u1``, ``1``)` and `false` to `@as``(``u1``, ``0``)`.

### [@intFromEnum](#toc-intFromEnum) [§](#intFromEnum)

    @intFromEnum(enum_or_tagged_union: anytype) anytype

Converts an enumeration value into its integer tag type. When a tagged union is passed, the tag value is used as the enumeration value.

If there is only one possible enum value, the result is a `comptime_int` known at [comptime](#comptime).

See also:

- [@enumFromInt](#enumFromInt)

### [@intFromError](#toc-intFromError) [§](#intFromError)

    @intFromError(err: anytype) @Int(.unsigned, @bitSizeOf(anyerror))

Supports the following types:

- [The Global Error Set](#The-Global-Error-Set)
- [Error Set Type](#Error-Set-Type)
- [Error Union Type](#Error-Union-Type)

Converts an error to the integer representation of an error.

It is generally recommended to avoid this cast, as the integer representation of an error is not stable across source code changes.

See also:

- [@errorFromInt](#errorFromInt)

### [@intFromFloat](#toc-intFromFloat) [§](#intFromFloat)

    @intFromFloat(float: anytype) anytype

Converts the integer part of a floating point number to the inferred result type.

If the integer part of the floating point number cannot fit in the destination type, it invokes safety-checked [Illegal Behavior](#Illegal-Behavior).

See also:

- [@floatFromInt](#floatFromInt)

### [@intFromPtr](#toc-intFromPtr) [§](#intFromPtr)

    @intFromPtr(value: anytype) usize

Converts `value` to a `usize` which is the address of the pointer. `value` can be `*T` or `?*T`.

To convert the other way, use [@ptrFromInt](#ptrFromInt)

### [@max](#toc-max) [§](#max)

    @max(...) T

Takes two or more arguments and returns the biggest value included (the maximum). This builtin accepts integers, floats, and vectors of either. In the latter case, the operation is performed element wise.

NaNs are handled as follows: return the biggest non-NaN value included. If all operands are NaN, return NaN.

See also:

- [@min](#min)
- [Vectors](#Vectors)

### [@memcpy](#toc-memcpy) [§](#memcpy)

    @memcpy(noalias dest, noalias source) void

This function copies bytes from one region of memory to another.

`dest` must be a mutable slice, a mutable pointer to an array, or a mutable many-item [pointer](#Pointers). It may have any alignment, and it may have any element type.

`source` must be a slice, a pointer to an array, or a many-item [pointer](#Pointers). It may have any alignment, and it may have any element type.

The `source` element type must have the same in-memory representation as the `dest` element type.

Similar to [for](#for) loops, at least one of `source` and `dest` must provide a length, and if two lengths are provided, they must be equal.

Finally, the two memory regions must not overlap.

### [@memset](#toc-memset) [§](#memset)

    @memset(dest, elem) void

This function sets all the elements of a memory region to `elem`.

`dest` must be a mutable slice or a mutable pointer to an array. It may have any alignment, and it may have any element type.

`elem` is coerced to the element type of `dest`.

For securely zeroing out sensitive contents from memory, you should use `std.crypto.secureZero`

### [@memmove](#toc-memmove) [§](#memmove)

    @memmove(dest, source) void

This function copies bytes from one region of memory to another, but unlike [@memcpy](#memcpy) the regions may overlap.

`dest` must be a mutable slice, a mutable pointer to an array, or a mutable many-item [pointer](#Pointers). It may have any alignment, and it may have any element type.

`source` must be a slice, a pointer to an array, or a many-item [pointer](#Pointers). It may have any alignment, and it may have any element type.

The `source` element type must have the same in-memory representation as the `dest` element type.

Similar to [for](#for) loops, at least one of `source` and `dest` must provide a length, and if two lengths are provided, they must be equal.

### [@min](#toc-min) [§](#min)

    @min(...) T

Takes two or more arguments and returns the smallest value included (the minimum). This builtin accepts integers, floats, and vectors of either. In the latter case, the operation is performed element wise.

NaNs are handled as follows: return the smallest non-NaN value included. If all operands are NaN, return NaN.

See also:

- [@max](#max)
- [Vectors](#Vectors)

### [@wasmMemorySize](#toc-wasmMemorySize) [§](#wasmMemorySize)

    @wasmMemorySize(index: u32) usize

This function returns the size of the Wasm memory identified by `index` as an unsigned value in units of Wasm pages. Note that each Wasm page is 64KB in size.

This function is a low level intrinsic with no safety mechanisms usually useful for allocator designers targeting Wasm. So unless you are writing a new allocator from scratch, you should use something like `@import``(``"std"``).heap.WasmPageAllocator`.

See also:

- [@wasmMemoryGrow](#wasmMemoryGrow)

### [@wasmMemoryGrow](#toc-wasmMemoryGrow) [§](#wasmMemoryGrow)

    @wasmMemoryGrow(index: u32, delta: usize) isize

This function increases the size of the Wasm memory identified by `index` by `delta` in units of unsigned number of Wasm pages. Note that each Wasm page is 64KB in size. On success, returns previous memory size; on failure, if the allocation fails, returns -1.

This function is a low level intrinsic with no safety mechanisms usually useful for allocator designers targeting Wasm. So unless you are writing a new allocator from scratch, you should use something like `@import``(``"std"``).heap.WasmPageAllocator`.

    const std = @import("std");
    const native_arch = @import("builtin").target.cpu.arch;
    const expectEqual = std.testing.expectEqual;

    test "@wasmMemoryGrow" {
        if (native_arch != .wasm32) return error.SkipZigTest;

        const prev = @wasmMemorySize(0);
        try expectEqual(@wasmMemoryGrow(0, 1), prev);
        try expectEqual(@wasmMemorySize(0), prev + 1);
    }

test_wasmMemoryGrow_builtin.zig

    $ zig test test_wasmMemoryGrow_builtin.zig
    1/1 test_wasmMemoryGrow_builtin.test.@wasmMemoryGrow...SKIP
    0 passed; 1 skipped; 0 failed.

Shell

See also:

- [@wasmMemorySize](#wasmMemorySize)

### [@mod](#toc-mod) [§](#mod)

    @mod(numerator: T, denominator: T) T

Modulus division. For unsigned integers this is the same as `numerator % denominator`. Caller guarantees `denominator != ``0`, otherwise the operation will result in a [Remainder Division by Zero](#Remainder-Division-by-Zero) when runtime safety checks are enabled.

- `@mod``(-``5``, ``3``) == ``1`
- `(``@divFloor``(a, b) * b) + ``@mod``(a, b) == a`

For a function that returns an error code, see `@import``(``"std"``).math.mod`.

See also:

- [@rem](#rem)

### [@mulWithOverflow](#toc-mulWithOverflow) [§](#mulWithOverflow)

    @mulWithOverflow(a: anytype, b: anytype) struct { @TypeOf(a, b), u1 }

Performs `a * b` and returns a tuple with the result and a possible overflow bit.

### [@panic](#toc-panic) [§](#panic)

    @panic(message: []const u8) noreturn

Invokes the panic handler function. By default the panic handler function calls the public `panic` function exposed in the root source file, or if there is not one specified, the `std.builtin.default_panic` function from `std/builtin.zig`.

Generally it is better to use `@import``(``"std"``).debug.panic`. However, `@panic` can be useful for 2 scenarios:

- From library code, calling the programmer's panic function if they exposed one in the root source file.
- When mixing C and Zig code, calling the canonical panic implementation across multiple .o files.

See also:

- [Panic Handler](#Panic-Handler)

### [@popCount](#toc-popCount) [§](#popCount)

    @popCount(operand: anytype) anytype

`@TypeOf``(operand)` must be an integer type.

`operand` may be an [integer](#Integers) or [vector](#Vectors).

Counts the number of bits set in an integer - "population count".

The return type is an unsigned integer or vector of unsigned integers with the minimum number of bits that can represent the bit count of the integer type.

See also:

- [@ctz](#ctz)
- [@clz](#clz)

### [@prefetch](#toc-prefetch) [§](#prefetch)

    @prefetch(ptr: anytype, comptime options: PrefetchOptions) void

This builtin tells the compiler to emit a prefetch instruction if supported by the target CPU. If the target CPU does not support the requested prefetch instruction, this builtin is a no-op. This function has no effect on the behavior of the program, only on the performance characteristics.

The `ptr` argument may be any pointer type and determines the memory address to prefetch. This function does not dereference the pointer, it is perfectly legal to pass a pointer to invalid memory to this function and no Illegal Behavior will result.

`PrefetchOptions` can be found with `@import``(``"std"``).builtin.PrefetchOptions`.

### [@ptrCast](#toc-ptrCast) [§](#ptrCast)

    @ptrCast(value: anytype) anytype

Converts a pointer of one type to a pointer of another type. The return type is the inferred result type.

[Optional Pointers](#Optional-Pointers) are allowed. Casting an optional pointer which is [null](#null) to a non-optional pointer invokes safety-checked [Illegal Behavior](#Illegal-Behavior).

`@ptrCast` cannot be used for:

- Removing `const` qualifier, use [@constCast](#constCast).
- Removing `volatile` qualifier, use [@volatileCast](#volatileCast).
- Changing pointer address space, use [@addrSpaceCast](#addrSpaceCast).
- Increasing pointer alignment, use [@alignCast](#alignCast).
- Casting a non-slice pointer to a slice, use slicing syntax `ptr[start..end]`.

### [@ptrFromInt](#toc-ptrFromInt) [§](#ptrFromInt)

    @ptrFromInt(address: usize) anytype

Converts an integer to a [pointer](#Pointers). The return type is the inferred result type. To convert the other way, use [@intFromPtr](#intFromPtr). Casting an address of 0 to a destination type which in not [optional](#Optional-Pointers) and does not have the `allowzero` attribute will result in a [Pointer Cast Invalid Null](#Pointer-Cast-Invalid-Null) panic when runtime safety checks are enabled.

If the destination pointer type does not allow address zero and `address` is zero, this invokes safety-checked [Illegal Behavior](#Illegal-Behavior).

### [@rem](#toc-rem) [§](#rem)

    @rem(numerator: T, denominator: T) T

Remainder division. For unsigned integers this is the same as `numerator % denominator`. Caller guarantees `denominator != ``0`, otherwise the operation will result in a [Remainder Division by Zero](#Remainder-Division-by-Zero) when runtime safety checks are enabled.

- `@rem``(-``5``, ``3``) == -``2`
- `(``@divTrunc``(a, b) * b) + ``@rem``(a, b) == a`

For a function that returns an error code, see `@import``(``"std"``).math.rem`.

See also:

- [@mod](#mod)

### [@returnAddress](#toc-returnAddress) [§](#returnAddress)

    @returnAddress() usize

This function returns the address of the next machine code instruction that will be executed when the current function returns.

The implications of this are target-specific and not consistent across all platforms.

This function is only valid within function scope. If the function gets inlined into a calling function, the returned address will apply to the calling function.

### [@select](#toc-select) [§](#select)

    @select(comptime T: type, pred: @Vector(len, bool), a: @Vector(len, T), b: @Vector(len, T)) @Vector(len, T)

Selects values element-wise from `a` or `b` based on `pred`. If `pred[i]` is `true`, the corresponding element in the result will be `a[i]` and otherwise `b[i]`.

See also:

- [Vectors](#Vectors)

### [@setEvalBranchQuota](#toc-setEvalBranchQuota) [§](#setEvalBranchQuota)

    @setEvalBranchQuota(comptime new_quota: u32) void

Increase the maximum number of backwards branches that compile-time code execution can use before giving up and making a compile error.

If the `new_quota` is smaller than the default quota (`1000`) or a previously explicitly set quota, it is ignored.

Example:

    test "foo" {
        comptime {
            var i = 0;
            while (i < 1001) : (i += 1) {}
        }
    }

test_without_setEvalBranchQuota_builtin.zig

    $ zig test test_without_setEvalBranchQuota_builtin.zig
    /home/andy/src/zig/doc/langref/test_without_setEvalBranchQuota_builtin.zig:4:9: error: evaluation exceeded 1000 backwards branches
            while (i < 1001) : (i += 1) {}
            ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    /home/andy/src/zig/doc/langref/test_without_setEvalBranchQuota_builtin.zig:4:9: note: use @setEvalBranchQuota() to raise the branch limit from 1000

Shell

Now we use `@setEvalBranchQuota`:

    test "foo" {
        comptime {
            @setEvalBranchQuota(1001);
            var i = 0;
            while (i < 1001) : (i += 1) {}
        }
    }

test_setEvalBranchQuota_builtin.zig

    $ zig test test_setEvalBranchQuota_builtin.zig
    1/1 test_setEvalBranchQuota_builtin.test.foo...OK
    All 1 tests passed.

Shell

See also:

- [comptime](#comptime)

### [@setFloatMode](#toc-setFloatMode) [§](#setFloatMode)

    @setFloatMode(comptime mode: FloatMode) void

Changes the current scope's rules about how floating point operations are defined.

- `.strict` (default) - Floating point operations follow strict IEEE compliance.
- `.optimized` - Floating point operations may do all of the following:
  - Assume the arguments and result are not NaN. Optimizations are required to retain legal behavior over NaNs, but the value of the result is undefined.
  - Assume the arguments and result are not +/-Inf. Optimizations are required to retain legal behavior over +/-Inf, but the value of the result is undefined.
  - Treat the sign of a zero argument or result as insignificant.
  - Use the reciprocal of an argument rather than perform division.
  - Perform floating-point contraction (e.g. fusing a multiply followed by an addition into a fused multiply-add).
  - Perform algebraically equivalent transformations that may change results in floating point (e.g. reassociate).

  This is equivalent to `-ffast-math` in GCC.

The floating point mode is inherited by child scopes, and can be overridden in any scope. You can set the floating point mode in a struct or module scope by using a comptime block.

`FloatMode` can be found with `@import``(``"std"``).builtin.FloatMode`.

See also:

- [Floating Point Operations](#Floating-Point-Operations)

### [@setRuntimeSafety](#toc-setRuntimeSafety) [§](#setRuntimeSafety)

    @setRuntimeSafety(comptime safety_on: bool) void

Sets whether runtime safety checks are enabled for the scope that contains the function call.

    test "@setRuntimeSafety" {
        // The builtin applies to the scope that it is called in. So here, integer overflow
        // will not be caught in ReleaseFast and ReleaseSmall modes:
        // var x: u8 = 255;
        // x += 1; // Unchecked Illegal Behavior in ReleaseFast/ReleaseSmall modes.
        {
            // However this block has safety enabled, so safety checks happen here,
            // even in ReleaseFast and ReleaseSmall modes.
            @setRuntimeSafety(true);
            var x: u8 = 255;
            x += 1;

            {
                // The value can be overridden at any scope. So here integer overflow
                // would not be caught in any build mode.
                @setRuntimeSafety(false);
                // var x: u8 = 255;
                // x += 1; // Unchecked Illegal Behavior in all build modes.
            }
        }
    }

test_setRuntimeSafety_builtin.zig

    $ zig test test_setRuntimeSafety_builtin.zig -OReleaseFast
    1/1 test_setRuntimeSafety_builtin.test.@setRuntimeSafety...thread 935744 panic: integer overflow
    /home/andy/src/zig/doc/langref/test_setRuntimeSafety_builtin.zig:11:11: 0x10855f8 in test.@setRuntimeSafety (test)
            x += 1;
              ^
    /home/andy/src/zig/lib/compiler/test_runner.zig:291:25: 0x1074feb in mainTerminal (test)
            if (test_fn.func()) |_| {
                            ^
    /home/andy/src/zig/lib/std/start.zig:686:88: 0x107314a in callMain (test)
        if (fn_info.params[0].type.? == std.process.Init.Minimal) return wrapMain(root.main(.{
                                                                                           ^
    /home/andy/src/zig/lib/std/start.zig:190:5: 0x1072c1d in _start (test)
        asm volatile (switch (native_arch) {
        ^
    error: the following test command terminated with signal ABRT:
    /home/andy/src/zig/.zig-cache/o/fedda1f87f11ec581f9d78378c471f74/test --seed=0x5af059f2

Shell

Note: it is [planned](https://github.com/ziglang/zig/issues/978) to replace `@setRuntimeSafety` with `@optimizeFor`

### [@shlExact](#toc-shlExact) [§](#shlExact)

    @shlExact(value: T, shift_amt: Log2T) T

Performs the left shift operation (`<<`). For unsigned integers, the result is [undefined](#undefined) if any 1 bits are shifted out. For signed integers, the result is [undefined](#undefined) if any bits that disagree with the resultant sign bit are shifted out.

The type of `shift_amt` is an unsigned integer with `log2(``@typeInfo``(T).int.bits)` bits. This is because `shift_amt >= ``@typeInfo``(T).int.bits` triggers safety-checked [Illegal Behavior](#Illegal-Behavior).

`comptime_int` is modeled as an integer with an infinite number of bits, meaning that in such case, `@shlExact` always produces a result and cannot produce a compile error.

See also:

- [@shrExact](#shrExact)
- [@shlWithOverflow](#shlWithOverflow)

### [@shlWithOverflow](#toc-shlWithOverflow) [§](#shlWithOverflow)

    @shlWithOverflow(a: anytype, shift_amt: Log2T) struct { @TypeOf(a), u1 }

Performs `a << b` and returns a tuple with the result and a possible overflow bit.

The type of `shift_amt` is an unsigned integer with `log2(``@typeInfo``(``@TypeOf``(a)).int.bits)` bits. This is because `shift_amt >= ``@typeInfo``(``@TypeOf``(a)).int.bits` triggers safety-checked [Illegal Behavior](#Illegal-Behavior).

See also:

- [@shlExact](#shlExact)
- [@shrExact](#shrExact)

### [@shrExact](#toc-shrExact) [§](#shrExact)

    @shrExact(value: T, shift_amt: Log2T) T

Performs the right shift operation (`>>`). Caller guarantees that the shift will not shift any 1 bits out.

The type of `shift_amt` is an unsigned integer with `log2(``@typeInfo``(T).int.bits)` bits. This is because `shift_amt >= ``@typeInfo``(T).int.bits` triggers safety-checked [Illegal Behavior](#Illegal-Behavior).

See also:

- [@shlExact](#shlExact)
- [@shlWithOverflow](#shlWithOverflow)

### [@shuffle](#toc-shuffle) [§](#shuffle)

    @shuffle(comptime E: type, a: @Vector(a_len, E), b: @Vector(b_len, E), comptime mask: @Vector(mask_len, i32)) @Vector(mask_len, E)

Constructs a new [vector](#Vectors) by selecting elements from `a` and `b` based on `mask`.

Each element in `mask` selects an element from either `a` or `b`. Positive numbers select from `a` starting at 0. Negative values select from `b`, starting at `-``1` and going down. It is recommended to use the `~` operator for indexes from `b` so that both indexes can start from `0` (i.e. `~``@as``(``i32``, ``0``)` is `-``1`).

For each element of `mask`, if it or the selected value from `a` or `b` is `undefined`, then the resulting element is `undefined`.

`a_len` and `b_len` may differ in length. Out-of-bounds element indexes in `mask` result in compile errors.

If `a` or `b` is `undefined`, it is equivalent to a vector of all `undefined` with the same length as the other vector. If both vectors are `undefined`, `@shuffle` returns a vector with all elements `undefined`.

`E` must be an [integer](#Integers), [float](#Floats), [pointer](#Pointers), or `bool`. The mask may be any vector length, and its length determines the result length.

    const std = @import("std");
    const expectEqualStrings = std.testing.expectEqualStrings;

    test "vector @shuffle" {
        const a = @Vector(7, u8){ 'o', 'l', 'h', 'e', 'r', 'z', 'w' };
        const b = @Vector(4, u8){ 'w', 'd', '!', 'x' };

        // To shuffle within a single vector, pass undefined as the second argument.
        // Notice that we can re-order, duplicate, or omit elements of the input vector
        const mask1 = @Vector(5, i32){ 2, 3, 1, 1, 0 };
        const res1: @Vector(5, u8) = @shuffle(u8, a, undefined, mask1);
        try expectEqualStrings("hello", &@as([5]u8, res1));

        // Combining two vectors
        const mask2 = @Vector(6, i32){ -1, 0, 4, 1, -2, -3 };
        const res2: @Vector(6, u8) = @shuffle(u8, a, b, mask2);
        try expectEqualStrings("world!", &@as([6]u8, res2));
    }

test_shuffle_builtin.zig

    $ zig test test_shuffle_builtin.zig
    1/1 test_shuffle_builtin.test.vector @shuffle...OK
    All 1 tests passed.

Shell

See also:

- [Vectors](#Vectors)

### [@sizeOf](#toc-sizeOf) [§](#sizeOf)

    @sizeOf(comptime T: type) comptime_int

This function returns the number of bytes it takes to store `T` in memory. The result is a target-specific compile time constant.

This size may contain padding bytes. If there were two consecutive T in memory, the padding would be the offset in bytes between element at index 0 and the element at index 1. For [integer](#Integers), consider whether you want to use `@sizeOf``(T)` or `@typeInfo``(T).int.bits`.

This function measures the size at runtime. For types that are disallowed at runtime, such as `comptime_int` and `type`, the result is `0`.

See also:

- [@bitSizeOf](#bitSizeOf)
- [@typeInfo](#typeInfo)

### [@splat](#toc-splat) [§](#splat)

    @splat(scalar: anytype) anytype

Produces an array or vector where each element is the value `scalar`. The return type and thus the length of the vector is inferred.

    const std = @import("std");
    const expectEqualSlices = std.testing.expectEqualSlices;

    test "vector @splat" {
        const scalar: u32 = 5;
        const result: @Vector(4, u32) = @splat(scalar);
        try expectEqualSlices(u32, &[_]u32{ 5, 5, 5, 5 }, &@as([4]u32, result));
    }

    test "array @splat" {
        const scalar: u32 = 5;
        const result: [4]u32 = @splat(scalar);
        try expectEqualSlices(u32, &[_]u32{ 5, 5, 5, 5 }, &@as([4]u32, result));
    }

test_splat_builtin.zig

    $ zig test test_splat_builtin.zig
    1/2 test_splat_builtin.test.vector @splat...OK
    2/2 test_splat_builtin.test.array @splat...OK
    All 2 tests passed.

Shell

`scalar` must be an [integer](#Integers), [bool](#Primitive-Types), [float](#Floats), or [pointer](#Pointers).

See also:

- [Vectors](#Vectors)
- [@shuffle](#shuffle)

### [@reduce](#toc-reduce) [§](#reduce)

    @reduce(comptime op: std.builtin.ReduceOp, value: anytype) E

Transforms a [vector](#Vectors) into a scalar value (of type `E`) by performing a sequential horizontal reduction of its elements using the specified operator `op`.

Not every operator is available for every vector element type:

- Every operator is available for [integer](#Integers) vectors.
- `.And`, `.Or`, `.Xor` are additionally available for `bool` vectors,
- `.Min`, `.Max`, `.Add`, `.Mul` are additionally available for [floating point](#Floats) vectors,

Note that `.Add` and `.Mul` reductions on integral types are wrapping; when applied on floating point types the operation associativity is preserved, unless the float mode is set to `.optimized`.

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "vector @reduce" {
        const V = @Vector(4, i32);
        const value = V{ 1, -1, 1, -1 };
        const result = value > @as(V, @splat(0));
        // result is { true, false, true, false };
        try comptime expectEqual(@Vector(4, bool), @TypeOf(result));
        const is_all_true = @reduce(.And, result);
        try comptime expectEqual(bool, @TypeOf(is_all_true));
        try expectEqual(false, is_all_true);
    }

test_reduce_builtin.zig

    $ zig test test_reduce_builtin.zig
    1/1 test_reduce_builtin.test.vector @reduce...OK
    All 1 tests passed.

Shell

See also:

- [Vectors](#Vectors)
- [@setFloatMode](#setFloatMode)

### [@src](#toc-src) [§](#src)

    @src() std.builtin.SourceLocation

Returns a `SourceLocation` struct representing the function's name and location in the source code. This must be called in a function.

    const std = @import("std");
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    test "@src" {
        try doTheTest();
    }

    fn doTheTest() !void {
        const src = @src();

        try expectEqual(10, src.line);
        try expectEqual(17, src.column);
        try expect(std.mem.endsWith(u8, src.fn_name, "doTheTest"));
        try expect(std.mem.endsWith(u8, src.file, "test_src_builtin.zig"));
    }

test_src_builtin.zig

    $ zig test test_src_builtin.zig
    1/1 test_src_builtin.test.@src...OK
    All 1 tests passed.

Shell

### [@sqrt](#toc-sqrt) [§](#sqrt)

    @sqrt(value: anytype) @TypeOf(value)

Performs the square root of a floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@sin](#toc-sin) [§](#sin)

    @sin(value: anytype) @TypeOf(value)

Sine trigonometric function on a floating point number in radians. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@cos](#toc-cos) [§](#cos)

    @cos(value: anytype) @TypeOf(value)

Cosine trigonometric function on a floating point number in radians. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@tan](#toc-tan) [§](#tan)

    @tan(value: anytype) @TypeOf(value)

Tangent trigonometric function on a floating point number in radians. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@exp](#toc-exp) [§](#exp)

    @exp(value: anytype) @TypeOf(value)

Base-e exponential function on a floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@exp2](#toc-exp2) [§](#exp2)

    @exp2(value: anytype) @TypeOf(value)

Base-2 exponential function on a floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@log](#toc-log) [§](#log)

    @log(value: anytype) @TypeOf(value)

Returns the natural logarithm of a floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@log2](#toc-log2) [§](#log2)

    @log2(value: anytype) @TypeOf(value)

Returns the logarithm to the base 2 of a floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@log10](#toc-log10) [§](#log10)

    @log10(value: anytype) @TypeOf(value)

Returns the logarithm to the base 10 of a floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@abs](#toc-abs) [§](#abs)

    @abs(value: anytype) anytype

Returns the absolute value of an integer or a floating point number. Uses a dedicated hardware instruction when available. The return type is always an unsigned integer of the same bit width as the operand if the operand is an integer. Unsigned integer operands are supported. The builtin cannot overflow for signed integer operands.

Supports [Floats](#Floats), [Integers](#Integers) and [Vectors](#Vectors) of floats or integers.

### [@floor](#toc-floor) [§](#floor)

    @floor(value: anytype) @TypeOf(value)

Returns the largest integral value not greater than the given floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@ceil](#toc-ceil) [§](#ceil)

    @ceil(value: anytype) @TypeOf(value)

Returns the smallest integral value not less than the given floating point number. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@trunc](#toc-trunc) [§](#trunc)

    @trunc(value: anytype) @TypeOf(value)

Rounds the given floating point number to an integer, towards zero. Uses a dedicated hardware instruction when available.

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@round](#toc-round) [§](#round)

    @round(value: anytype) @TypeOf(value)

Rounds the given floating point number to the nearest integer. If two integers are equally close, rounds away from zero. Uses a dedicated hardware instruction when available.

    const expectEqual = @import("std").testing.expectEqual;

    test "@round" {
        try expectEqual(1, @round(1.4));
        try expectEqual(2, @round(1.5));
        try expectEqual(-1, @round(-1.4));
        try expectEqual(-3, @round(-2.5));
    }

test_round_builtin.zig

    $ zig test test_round_builtin.zig
    1/1 test_round_builtin.test.@round...OK
    All 1 tests passed.

Shell

Supports [Floats](#Floats) and [Vectors](#Vectors) of floats.

### [@subWithOverflow](#toc-subWithOverflow) [§](#subWithOverflow)

    @subWithOverflow(a: anytype, b: anytype) struct { @TypeOf(a, b), u1 }

Performs `a - b` and returns a tuple with the result and a possible overflow bit.

### [@tagName](#toc-tagName) [§](#tagName)

    @tagName(value: anytype) [:0]const u8

Converts an enum value or union value to a string literal representing the name.

If the enum is non-exhaustive and the tag value does not map to a name, it invokes safety-checked [Illegal Behavior](#Illegal-Behavior).

### [@This](#toc-This) [§](#This)

    @This() type

Returns the innermost struct, enum, or union that this function call is inside. This can be useful for an anonymous struct that needs to refer to itself:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "@This()" {
        var items = [_]i32{ 1, 2, 3, 4 };
        const list = List(i32){ .items = items[0..] };
        try expectEqual(4, list.length());
    }

    fn List(comptime T: type) type {
        return struct {
            const Self = @This();

            items: []T,

            fn length(self: Self) usize {
                return self.items.len;
            }
        };
    }

test_this_builtin.zig

    $ zig test test_this_builtin.zig
    1/1 test_this_builtin.test.@This()...OK
    All 1 tests passed.

Shell

When `@This``()` is used at file scope, it returns a reference to the struct that corresponds to the current file.

### [@trap](#toc-trap) [§](#trap)

    @trap() noreturn

This function inserts a platform-specific trap/jam instruction which can be used to exit the program abnormally. This may be implemented by explicitly emitting an invalid instruction which may cause an illegal instruction exception of some sort. Unlike for `@breakpoint``()`, execution does not continue after this point.

Outside function scope, this builtin causes a compile error.

See also:

- [@breakpoint](#breakpoint)

### [@truncate](#toc-truncate) [§](#truncate)

    @truncate(integer: anytype) anytype

This function truncates bits from an integer type, resulting in a smaller or same-sized integer type. The return type is the inferred result type.

This function always truncates the significant bits of the integer, regardless of endianness on the target platform.

Calling `@truncate` on a number out of range of the destination type is well defined and working code:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "integer truncation" {
        const a: u16 = 0xabcd;
        const b: u8 = @truncate(a);
        try expectEqual(0xcd, b);
    }

test_truncate_builtin.zig

    $ zig test test_truncate_builtin.zig
    1/1 test_truncate_builtin.test.integer truncation...OK
    All 1 tests passed.

Shell

Use [@intCast](#intCast) to convert numbers guaranteed to fit the destination type.

### [@EnumLiteral](#toc-EnumLiteral) [§](#EnumLiteral)

    @EnumLiteral() type

Returns the comptime-only "enum literal" type. This is the type of uncoerced [Enum Literals](#Enum-Literals). Values of this type can coerce to any [enum](#enum) with a matching field.

### [@Int](#toc-Int) [§](#Int)

    @Int(comptime signedness: std.builtin.Signedness, comptime bits: u16) type

Returns an integer type with the given signedness and bit width.

For instance, `@Int``(.unsigned, ``18``)` returns the type `u18`.

### [@Tuple](#toc-Tuple) [§](#Tuple)

    @Tuple(comptime field_types: []const type) type

Returns a [tuple](#Tuples) type with the given field types.

### [@Pointer](#toc-Pointer) [§](#Pointer)

    @Pointer(
        comptime size: std.builtin.Type.Pointer.Size,
        comptime attrs: std.builtin.Type.Pointer.Attributes,
        comptime Element: type,
        comptime sentinel: ?Element,
    ) type

Returns a [pointer](#Pointers) type with the properties specified by the arguments.

### [@Fn](#toc-Fn) [§](#Fn)

    @Fn(
        comptime param_types: []const type,
        comptime param_attrs: *const [param_types.len]std.builtin.Type.Fn.Param.Attributes,
        comptime ReturnType: type,
        comptime attrs: std.builtin.Type.Fn.Attributes,
    ) type

Returns a [function](#Functions) type with the properties specified by the arguments.

### [@Struct](#toc-Struct) [§](#Struct)

    @Struct(
        comptime layout: std.builtin.Type.ContainerLayout,
        comptime BackingInt: ?type,
        comptime field_names: []const []const u8,
        comptime field_types: *const [field_names.len]type,
        comptime field_attrs: *const [field_names.len]std.builtin.Type.StructField.Attributes,
    ) type

Returns a [struct](#struct) type with the properties specified by the arguments.

### [@Union](#toc-Union) [§](#Union)

    @Union(
        comptime layout: std.builtin.Type.ContainerLayout,
        /// Either the integer tag type, or the integer backing type, depending on `layout`.
        comptime ArgType: ?type,
        comptime field_names: []const []const u8,
        comptime field_types: *const [field_names.len]type,
        comptime field_attrs: *const [field_names.len]std.builtin.Type.UnionField.Attributes,
    ) type

Returns a [union](#union) type with the properties specified by the arguments.

### [@Enum](#toc-Enum) [§](#Enum)

    @Enum(
        comptime TagInt: type,
        comptime mode: std.builtin.Type.Enum.Mode,
        comptime field_names: []const []const u8,
        comptime field_values: *const [field_names.len]TagInt,
    ) type

Returns an [enum](#enum) type with the properties specified by the arguments.

### [@typeInfo](#toc-typeInfo) [§](#typeInfo)

    @typeInfo(comptime T: type) std.builtin.Type

Provides type reflection.

Type information of [structs](#struct), [unions](#union), [enums](#enum), and [error sets](#Error-Set-Type) has fields which are guaranteed to be in the same order as appearance in the source file.

Type information of [structs](#struct), [unions](#union), [enums](#enum), and [opaques](#opaque) has declarations, which are also guaranteed to be in the same order as appearance in the source file.

### [@typeName](#toc-typeName) [§](#typeName)

    @typeName(T: type) *const [N:0]u8

This function returns the string representation of a type, as an array. It is equivalent to a string literal of the type name. The returned type name is fully qualified with the parent namespace included as part of the type name with a series of dots.

### [@TypeOf](#toc-TypeOf) [§](#TypeOf)

    @TypeOf(...) type

`@TypeOf` is a special builtin function that takes any (non-zero) number of expressions as parameters and returns the type of the result, using [Peer Type Resolution](#Peer-Type-Resolution).

The expressions are evaluated, however they are guaranteed to have no *runtime* side-effects:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "no runtime side effects" {
        var data: i32 = 0;
        const T = @TypeOf(foo(i32, &data));
        try comptime expectEqual(i32, T);
        try expectEqual(0, data);
    }

    fn foo(comptime T: type, ptr: *T) T {
        ptr.* += 1;
        return ptr.*;
    }

test_TypeOf_builtin.zig

    $ zig test test_TypeOf_builtin.zig
    1/1 test_TypeOf_builtin.test.no runtime side effects...OK
    All 1 tests passed.

Shell

### [@unionInit](#toc-unionInit) [§](#unionInit)

    @unionInit(comptime Union: type, comptime active_field_name: []const u8, init_expr) Union

This is the same thing as [union](#union) initialization syntax, except that the field name is a [comptime](#comptime)-known value rather than an identifier token.

`@unionInit` forwards its [result location](#Result-Location-Semantics) to `init_expr`.

### [@Vector](#toc-Vector) [§](#Vector)

    @Vector(len: comptime_int, Element: type) type

Creates [Vectors](#Vectors).

### [@volatileCast](#toc-volatileCast) [§](#volatileCast)

    @volatileCast(value: anytype) DestType

Remove `volatile` qualifier from a pointer.

### [@workGroupId](#toc-workGroupId) [§](#workGroupId)

    @workGroupId(comptime dimension: u32) u32

Returns the index of the work group in the current kernel invocation in dimension `dimension`.

### [@workGroupSize](#toc-workGroupSize) [§](#workGroupSize)

    @workGroupSize(comptime dimension: u32) u32

Returns the number of work items that a work group has in dimension `dimension`.

### [@workItemId](#toc-workItemId) [§](#workItemId)

    @workItemId(comptime dimension: u32) u32

Returns the index of the work item in the work group in dimension `dimension`. This function returns values between `0` (inclusive) and `@workGroupSize``(dimension)` (exclusive).

