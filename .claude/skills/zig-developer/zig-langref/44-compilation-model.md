# Compilation Model


A Zig compilation is separated into *modules*. Each module is a collection of Zig source files, one of which is the module's *root source file*. Each module can *depend* on any number of other modules, forming a directed graph (dependency loops between modules are allowed). If module A depends on module B, then any Zig source file in module A can import the *root source file* of module B using `@import` with the module's name. In essence, a module acts as an alias to import a Zig source file (which might exist in a completely separate part of the filesystem).

A simple Zig program compiled with `zig build-exe` has two key modules: the one containing your code, known as the "main" or "root" module, and the standard library. Your module *depends on* the standard library module under the name "std", which is what allows you to write `@import``(``"std"``)`! In fact, every single module in a Zig compilation — including the standard library itself — implicitly depends on the standard library module under the name "std".

The "root module" (the one provided by you in the `zig build-exe` example) has a special property. Like the standard library, it is implicitly made available to all modules (including itself), this time under the name "root". So, `@import``(``"root"``)` will always be equivalent to `@import` of your "main" source file (often, but not necessarily, named `main.zig`).

### [Source File Structs](#toc-Source-File-Structs) [§](#Source-File-Structs)

Every Zig source file is implicitly a `struct` declaration; you can imagine that the file's contents are literally surrounded by `struct`` { ... }`. This means that as well as declarations, the top level of a file is permitted to contain fields:

    //! Because this file contains fields, it is a type which is intended to be instantiated, and so
    //! is named in TitleCase instead of snake_case by convention.

    foo: u32,
    bar: u64,

    /// `@This()` can be used to refer to this struct type. In files with fields, it is quite common to
    /// name the type here, so it can be easily referenced by other declarations in this file.
    const TopLevelFields = @This();

    pub fn init(val: u32) TopLevelFields {
        return .{
            .foo = val,
            .bar = val * 10,
        };
    }

TopLevelFields.zig

Such files can be instantiated just like any other `struct` type. A file's "root struct type" can be referred to within that file using [@This](#This).

### [File and Declaration Discovery](#toc-File-and-Declaration-Discovery) [§](#File-and-Declaration-Discovery)

Zig places importance on the concept of whether any piece of code is *semantically analyzed*; in essence, whether the compiler "looks at" it. What code is analyzed is based on what files and declarations are "discovered" from a certain point. This process of "discovery" is based on a simple set of recursive rules:

- If a call to `@import` is analyzed, the file being imported is analyzed.
- If a type (including a file) is analyzed, all `comptime` and `export` declarations within it are analyzed.
- If a type (including a file) is analyzed, and the compilation is for a [test](#Zig-Test), and the module the type is within is the root module of the compilation, then all `test` declarations within it are also analyzed.
- If a reference to a named declaration (i.e. a usage of it) is analyzed, the declaration being referenced is analyzed. Declarations are order-independent, so this reference may be above or below the declaration being referenced, or even in another file entirely.

That's it! Those rules define how Zig files and declarations are discovered. All that remains is to understand where this process *starts*.

The answer to that is the root of the standard library: every Zig compilation begins by analyzing the file `lib/std/std.zig`. This file contains a `comptime` declaration which imports `lib/std/start.zig`, and that file in turn uses `@import``(``"root"``)` to reference the "root module"; so, the file you provide as your main module's root source file is effectively also a root, because the standard library will always reference it.

It is often desirable to make sure that certain declarations — particularly `test` or `export` declarations — are discovered. Based on the above rules, a common strategy for this is to use `@import` within a `comptime` or `test` block:

    comptime {
        // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
        // It is useful if 'api.zig' contains important exported declarations.
        _ = @import("api.zig");

        // We could also have a file which contains declarations we only want to export depending on a comptime
        // condition. In that case, we can use an `if` statement here:
        if (builtin.os.tag == .windows) {
            _ = @import("windows_api.zig");
        }
    }

    test {
        // This will ensure that the file 'tests.zig' is always discovered (as long as this file is discovered),
        // if this compilation is a test. It is useful if 'tests.zig' contains tests we want to ensure are run.
        _ = @import("tests.zig");

        // We could also have a file which contains tests we only want to run depending on a comptime condition.
        // In that case, we can use an `if` statement here:
        if (builtin.os.tag == .windows) {
            _ = @import("windows_tests.zig");
        }
    }

    const builtin = @import("builtin");

force_file_discovery.zig

### [Special Root Declarations](#toc-Special-Root-Declarations) [§](#Special-Root-Declarations)

Because the root module's root source file is always accessible using `@import``(``"root"``)`, is is sometimes used by libraries — including the Zig Standard Library — as a place for the program to expose some "global" information to that library. The Zig Standard Library will look for several declarations in this file.

#### [Entry Point](#toc-Entry-Point) [§](#Entry-Point)

When building an executable, the most important thing to be looked up in this file is the program's *entry point*. Most commonly, this is a function named `main`, which `std.start` will call just after performing important initialization work.

Alternatively, the presence of a declaration named `_start` (for instance, `pub`` ``const`` _start = {};`) will disable the default `std.start` logic, allowing your root source file to export a low-level entry point as needed.

    /// `std.start` imports this file using `@import("root")`, and uses this declaration as the program's
    /// user-provided entry point. It can return any of the following types:
    /// * `void`
    /// * `E!void`, for any error set `E`
    /// * `u8`
    /// * `E!u8`, for any error set `E`
    /// Returning a `void` value from this function will exit with code 0.
    /// Returning a `u8` value from this function will exit with the given status code.
    /// Returning an error value from this function will print an Error Return Trace and exit with code 1.
    pub fn main() void {
        std.debug.print("Hello, World!\n", .{});
    }

    // If uncommented, this declaration would suppress the usual std.start logic, causing
    // the `main` declaration above to be ignored.
    //pub const _start = {};

    const std = @import("std");

entry_point.zig

    $ zig build-exe entry_point.zig
    $ ./entry_point
    Hello, World!

Shell

If the Zig compilation links libc, the `main` function can optionally be an `export`` ``fn` which matches the signature of the C `main` function:

    pub export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
        const args = argv[0..@intCast(argc)];
        std.debug.print("Hello! argv[0] is '{s}'\n", .{args[0]});
        return 0;
    }

    const std = @import("std");

libc_export_entry_point.zig

    $ zig build-exe libc_export_entry_point.zig -lc
    $ ./libc_export_entry_point
    Hello! argv[0] is './libc_export_entry_point'

Shell

`std.start` may also use other entry point declarations in certain situations, such as `wWinMain` or `EfiMain`. Refer to the `lib/std/start.zig` logic for details of these declarations.

#### [Standard Library Options](#toc-Standard-Library-Options) [§](#Standard-Library-Options)

The standard library also looks for a declaration in the root module's root source file named `std_options`. If present, this declaration is expected to be a struct of type `std.Options`, and allows the program to customize some standard library functionality, such as the `std.log` implementation.

    /// The presence of this declaration allows the program to override certain behaviors of the standard library.
    /// For a full list of available options, see the documentation for `std.Options`.
    pub const std_options: std.Options = .{
        // By default, in safe build modes, the standard library will attach a segfault handler to the program to
        // print a helpful stack trace if a segmentation fault occurs. Here, we can disable this, or even enable
        // it in unsafe build modes.
        .enable_segfault_handler = true,
        // This is the logging function used by `std.log`.
        .logFn = myLogFn,
    };

    fn myLogFn(
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // We could do anything we want here!
        // ...but actually, let's just call the default implementation.
        std.log.defaultLog(level, scope, format, args);
    }

    const std = @import("std");

std_options.zig

#### [Panic Handler](#toc-Panic-Handler) [§](#Panic-Handler)

The Zig Standard Library looks for a declaration named `panic` in the root module's root source file. If present, it is expected to be a namespace (container type) with declarations providing different panic handlers.

See `std.debug.simple_panic` for a basic implementation of this namespace.

Overriding how the panic handler actually outputs messages, but keeping the formatted safety panics which are enabled by default, can be easily achieved with `std.debug.FullPanic`:

    pub fn main() void {
        @setRuntimeSafety(true);
        var x: u8 = 255;
        // Let's overflow this integer!
        x += 1;
    }

    pub const panic = std.debug.FullPanic(myPanic);

    fn myPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        std.debug.print("Panic! {s}\n", .{msg});
        std.process.exit(1);
    }

    const std = @import("std");

panic_handler.zig

    $ zig build-exe panic_handler.zig
    $ ./panic_handler
    Panic! integer overflow

Shell

