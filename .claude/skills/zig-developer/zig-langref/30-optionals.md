# Optionals


One area that Zig provides safety without compromising efficiency or readability is with the optional type.

The question mark symbolizes the optional type. You can convert a type to an optional type by putting a question mark in front of it, like this:

    // normal integer
    const normal_int: i32 = 1234;

    // optional integer
    const optional_int: ?i32 = 5678;

optional_integer.zig

Now the variable `optional_int` could be an `i32`, or `null`.

Instead of integers, let's talk about pointers. Null references are the source of many runtime exceptions, and even stand accused of being [the worst mistake of computer science](https://www.lucidchart.com/techblog/2015/08/31/the-worst-mistake-of-computer-science/).

Zig does not have them.

Instead, you can use an optional pointer. This secretly compiles down to a normal pointer, since we know we can use 0 as the null value for the optional type. But the compiler can check your work and make sure you don't assign null to something that can't be null.

Typically the downside of not having null is that it makes the code more verbose to write. But, let's compare some equivalent C code and Zig code.

Task: call malloc, if the result is null, return null.

C code

    // malloc prototype included for reference
    void *malloc(size_t size);

    struct Foo *do_a_thing(void) {
        char *ptr = malloc(1234);
        if (!ptr) return NULL;
        // ...
    }

call_malloc_in_c.c

Zig code

    // malloc prototype included for reference
    extern fn malloc(size: usize) ?[*]u8;

    fn doAThing() ?*Foo {
        const ptr = malloc(1234) orelse return null;
        _ = ptr; // ...
    }

call_malloc_from_zig.zig

Here, Zig is at least as convenient, if not more, than C. And, the type of "ptr" is `[*]``u8` *not* `?[*]``u8`. The `orelse` keyword unwrapped the optional type and therefore `ptr` is guaranteed to be non-null everywhere it is used in the function.

The other form of checking against NULL you might see looks like this:

    void do_a_thing(struct Foo *foo) {
        // do some stuff

        if (foo) {
            do_something_with_foo(foo);
        }

        // do some stuff
    }

checking_null_in_c.c

In Zig you can accomplish the same thing:

    const Foo = struct {};
    fn doSomethingWithFoo(foo: *Foo) void {
        _ = foo;
    }

    fn doAThing(optional_foo: ?*Foo) void {
        // do some stuff

        if (optional_foo) |foo| {
            doSomethingWithFoo(foo);
        }

        // do some stuff
    }

checking_null_in_zig.zig

Once again, the notable thing here is that inside the if block, `foo` is no longer an optional pointer, it is a pointer, which cannot be null.

One benefit to this is that functions which take pointers as arguments can be annotated with the "nonnull" attribute - `__attribute__((nonnull))` in [GCC](https://gcc.gnu.org/onlinedocs/gcc-4.0.0/gcc/Function-Attributes.html). The optimizer can sometimes make better decisions knowing that pointer arguments cannot be null.

### [Optional Type](#toc-Optional-Type) [§](#Optional-Type)

An optional is created by putting `?` in front of a type. You can use compile-time reflection to access the child type of an optional:

    const expectEqual = @import("std").testing.expectEqual;

    test "optional type" {
        // Declare an optional and coerce from null:
        var foo: ?i32 = null;

        // Coerce from child type of an optional
        foo = 1234;

        // Use compile-time reflection to access the child type of the optional:
        try comptime expectEqual(i32, @typeInfo(@TypeOf(foo)).optional.child);
    }

test_optional_type.zig

    $ zig test test_optional_type.zig
    1/1 test_optional_type.test.optional type...OK
    All 1 tests passed.

Shell

### [null](#toc-null) [§](#null)

Just like [undefined](#undefined), `null` has its own type, and the only way to use it is to cast it to a different type:

    const optional_value: ?i32 = null;

null.zig

### [Optional Pointers](#toc-Optional-Pointers) [§](#Optional-Pointers)

An optional pointer is guaranteed to be the same size as a pointer. The `null` of the optional is guaranteed to be address 0.

    const expectEqual = @import("std").testing.expectEqual;

    test "optional pointers" {
        // Pointers cannot be null. If you want a null pointer, use the optional
        // prefix `?` to make the pointer type optional.
        var ptr: ?*i32 = null;

        var x: i32 = 1;
        ptr = &x;

        try expectEqual(1, ptr.?.*);

        // Optional pointers are the same size as normal pointers, because pointer
        // value 0 is used as the null value.
        try expectEqual(@sizeOf(?*i32), @sizeOf(*i32));
    }

test_optional_pointer.zig

    $ zig test test_optional_pointer.zig
    1/1 test_optional_pointer.test.optional pointers...OK
    All 1 tests passed.

Shell

See also:

- [while with Optionals](#while-with-Optionals)
- [if with Optionals](#if-with-Optionals)

