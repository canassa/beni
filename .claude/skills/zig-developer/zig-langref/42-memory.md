# Memory


The Zig language performs no memory management on behalf of the programmer. This is why Zig has no runtime, and why Zig code works seamlessly in so many environments, including real-time software, operating system kernels, embedded devices, and low latency servers. As a consequence, Zig programmers must always be able to answer the question:

[Where are the bytes?](#Where-are-the-bytes)

Like Zig, the C programming language has manual memory management. However, unlike Zig, C has a default allocator - `malloc`, `realloc`, and `free`. When linking against libc, Zig exposes this allocator with `std.heap.c_allocator`. However, by convention, there is no default allocator in Zig. Instead, functions which need to allocate accept an `Allocator` parameter. Likewise, some data structures accept an `Allocator` parameter in their initialization functions:

    const std = @import("std");
    const Allocator = std.mem.Allocator;
    const expectEqualStrings = std.testing.expectEqualStrings;

    test "using an allocator" {
        var buffer: [100]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();
        const result = try concat(allocator, "foo", "bar");
        try expectEqualStrings("foobar", result);
    }

    fn concat(allocator: Allocator, a: []const u8, b: []const u8) ![]u8 {
        const result = try allocator.alloc(u8, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

test_allocator.zig

    $ zig test test_allocator.zig
    1/1 test_allocator.test.using an allocator...OK
    All 1 tests passed.

Shell

In the above example, 100 bytes of stack memory are used to initialize a `FixedBufferAllocator`, which is then passed to a function. As a convenience there is a global `FixedBufferAllocator` available for quick tests at `std.testing.allocator`, which will also perform basic leak detection.

Zig has a general purpose allocator available to be imported with `std.heap.DebugAllocator`. However, it is still recommended to follow the [Choosing an Allocator](#Choosing-an-Allocator) guide.

### [Choosing an Allocator](#toc-Choosing-an-Allocator) [§](#Choosing-an-Allocator)

What allocator to use depends on a number of factors. Here is a flow chart to help you decide:

1.  Are you making a library? In this case, best to accept an `Allocator` as a parameter and allow your library's users to decide what allocator to use.
2.  Are you linking libc? In this case, `std.heap.c_allocator` is likely the right choice, at least for your main allocator.
3.  Is the maximum number of bytes that you will need bounded by a number known at [comptime](#comptime)? In this case, use `std.heap.FixedBufferAllocator`.
4.  Is your program a command line application which runs from start to end without any fundamental cyclical pattern (such as a video game main loop, or a web server request handler), such that it would make sense to free everything at once at the end? In this case, it is recommended to follow this pattern:
        const std = @import("std");

        pub fn main() !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const allocator = arena.allocator();

            const ptr = try allocator.create(i32);
            std.debug.print("ptr={*}\n", .{ptr});
        }

    cli_allocation.zig

        $ zig build-exe cli_allocation.zig
        $ ./cli_allocation
        ptr=i32@7ff19946e018

    Shell

    When using this kind of allocator, there is no need to free anything manually. Everything gets freed at once with the call to `arena.deinit()`.
5.  Are the allocations part of a cyclical pattern such as a video game main loop, or a web server request handler? If the allocations can all be freed at once, at the end of the cycle, for example once the video game frame has been fully rendered, or the web server request has been served, then `std.heap.ArenaAllocator` is a great candidate. As demonstrated in the previous bullet point, this allows you to free entire arenas at once. Note also that if an upper bound of memory can be established, then `std.heap.FixedBufferAllocator` can be used as a further optimization.
6.  Are you writing a test, and you want to make sure `error``.OutOfMemory` is handled correctly? In this case, use `std.testing.FailingAllocator`.
7.  Are you writing a test? In this case, use `std.testing.allocator`.
8.  Finally, if none of the above apply, you need a general purpose allocator. If you are in Debug mode, `std.heap.DebugAllocator` is available as a function that takes a [comptime](#comptime) [struct](#struct) of configuration options and returns a type. Generally, you will set up exactly one in your main function, and then pass it or sub-allocators around to various parts of your application.
9.  If you are compiling in ReleaseFast mode, `std.heap.smp_allocator` is a solid choice for a general purpose allocator.
10. You can also consider implementing an allocator.

### [Where are the bytes?](#toc-Where-are-the-bytes) [§](#Where-are-the-bytes)

String literals such as `"hello"` are in the global constant data section. This is why it is an error to pass a string literal to a mutable slice, like this:

    fn foo(s: []u8) void {
        _ = s;
    }

    test "string literal to mutable slice" {
        foo("hello");
    }

test_string_literal_to_slice.zig

    $ zig test test_string_literal_to_slice.zig
    /home/andy/src/zig/doc/langref/test_string_literal_to_slice.zig:6:9: error: expected type '[]u8', found '*const [5:0]u8'
        foo("hello");
            ^~~~~~~
    /home/andy/src/zig/doc/langref/test_string_literal_to_slice.zig:6:9: note: cast discards const qualifier
    /home/andy/src/zig/doc/langref/test_string_literal_to_slice.zig:1:11: note: parameter type declared here
    fn foo(s: []u8) void {
              ^~~~

Shell

However if you make the slice constant, then it works:

    fn foo(s: []const u8) void {
        _ = s;
    }

    test "string literal to constant slice" {
        foo("hello");
    }

test_string_literal_to_const_slice.zig

    $ zig test test_string_literal_to_const_slice.zig
    1/1 test_string_literal_to_const_slice.test.string literal to constant slice...OK
    All 1 tests passed.

Shell

Just like string literals, `const` declarations, when the value is known at [comptime](#comptime), are stored in the global constant data section. Also [Compile Time Variables](#Compile-Time-Variables) are stored in the global constant data section.

`var` declarations inside functions are stored in the function's stack frame. Once a function returns, any [Pointers](#Pointers) to variables in the function's stack frame become invalid references, and dereferencing them becomes unchecked [Illegal Behavior](#Illegal-Behavior).

`var` declarations at the top level or in [struct](#struct) declarations are stored in the global data section.

The location of memory allocated with `allocator.alloc` or `allocator.create` is determined by the allocator's implementation.

TODO: thread local variables

### [Heap Allocation Failure](#toc-Heap-Allocation-Failure) [§](#Heap-Allocation-Failure)

Many programming languages choose to handle the possibility of heap allocation failure by unconditionally crashing. By convention, Zig programmers do not consider this to be a satisfactory solution. Instead, `error``.OutOfMemory` represents heap allocation failure, and Zig libraries return this error code whenever heap allocation failure prevented an operation from completing successfully.

Some have argued that because some operating systems such as Linux have memory overcommit enabled by default, it is pointless to handle heap allocation failure. There are many problems with this reasoning:

- Only some operating systems have an overcommit feature.
  - Linux has it enabled by default, but it is configurable.
  - Windows does not overcommit.
  - Embedded systems do not have overcommit.
  - Hobby operating systems may or may not have overcommit.
- For real-time systems, not only is there no overcommit, but typically the maximum amount of memory per application is determined ahead of time.
- When writing a library, one of the main goals is code reuse. By making code handle allocation failure correctly, a library becomes eligible to be reused in more contexts.
- Although some software has grown to depend on overcommit being enabled, its existence is the source of countless user experience disasters. When a system with overcommit enabled, such as Linux on default settings, comes close to memory exhaustion, the system locks up and becomes unusable. At this point, the OOM Killer selects an application to kill based on heuristics. This non-deterministic decision often results in an important process being killed, and often fails to return the system back to working order.

### [Recursion](#toc-Recursion) [§](#Recursion)

Recursion is a fundamental tool in modeling software. However it has an often-overlooked problem: unbounded memory allocation.

Recursion is an area of active experimentation in Zig and so the documentation here is not final. You can read a [summary of recursion status in the 0.3.0 release notes](https://ziglang.org/download/0.3.0/release-notes.html#recursion).

The short summary is that currently recursion works normally as you would expect. Although Zig code is not yet protected from stack overflow, it is planned that a future version of Zig will provide such protection, with some degree of cooperation from Zig code required.

### [Lifetime and Ownership](#toc-Lifetime-and-Ownership) [§](#Lifetime-and-Ownership)

It is the Zig programmer's responsibility to ensure that a [pointer](#Pointers) is not accessed when the memory pointed to is no longer available. Note that a [slice](#Slices) is a form of pointer, in that it references other memory.

In order to prevent bugs, there are some helpful conventions to follow when dealing with pointers. In general, when a function returns a pointer, the documentation for the function should explain who "owns" the pointer. This concept helps the programmer decide when it is appropriate, if ever, to free the pointer.

For example, the function's documentation may say "caller owns the returned memory", in which case the code that calls the function must have a plan for when to free that memory. Probably in this situation, the function will accept an `Allocator` parameter.

Sometimes the lifetime of a pointer may be more complicated. For example, the `std.ArrayList(T).items` slice has a lifetime that remains valid until the next time the list is resized, such as by appending new elements.

The API documentation for functions and data structures should take great care to explain the ownership and lifetime semantics of pointers. Ownership determines whose responsibility it is to free the memory referenced by the pointer, and lifetime determines the point at which the memory becomes inaccessible (lest [Illegal Behavior](#Illegal-Behavior) occur).

