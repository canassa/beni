# Blocks


Blocks are used to limit the scope of variable declarations:

    test "access variable after block scope" {
        {
            var x: i32 = 1;
            _ = &x;
        }
        x += 1;
    }

test_blocks.zig

    $ zig test test_blocks.zig
    /home/andy/src/zig/doc/langref/test_blocks.zig:6:5: error: use of undeclared identifier 'x'
        x += 1;
        ^

Shell

Blocks are expressions. When labeled, `break` can be used to return a value from the block:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test "labeled break from labeled block expression" {
        var y: i32 = 123;

        const x = blk: {
            y += 1;
            break :blk y;
        };
        try expectEqual(124, x);
        try expectEqual(124, y);
    }

test_labeled_break.zig

    $ zig test test_labeled_break.zig
    1/1 test_labeled_break.test.labeled break from labeled block expression...OK
    All 1 tests passed.

Shell

Here, `blk` can be any name.

See also:

- [Labeled while](#Labeled-while)
- [Labeled for](#Labeled-for)

### [Shadowing](#toc-Shadowing) [§](#Shadowing)

[Identifiers](#Identifiers) are never allowed to "hide" other identifiers by using the same name:

    const pi = 3.14;

    test "inside test block" {
        // Let's even go inside another block
        {
            var pi: i32 = 1234;
        }
    }

test_shadowing.zig

    $ zig test test_shadowing.zig
    /home/andy/src/zig/doc/langref/test_shadowing.zig:6:13: error: local variable shadows declaration of 'pi'
            var pi: i32 = 1234;
                ^~
    /home/andy/src/zig/doc/langref/test_shadowing.zig:1:1: note: declared here
    const pi = 3.14;
    ^~~~~~~~~~~~~~~

Shell

Because of this, when you read Zig code you can always rely on an identifier to consistently mean the same thing within the scope it is defined. Note that you can, however, use the same name if the scopes are separate:

    test "separate scopes" {
        {
            const pi = 3.14;
            _ = pi;
        }
        {
            var pi: bool = true;
            _ = &pi;
        }
    }

test_scopes.zig

    $ zig test test_scopes.zig
    1/1 test_scopes.test.separate scopes...OK
    All 1 tests passed.

Shell

### [Empty Blocks](#toc-Empty-Blocks) [§](#Empty-Blocks)

An empty block is equivalent to `void``{}`:

    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    test {
        const a = {};
        const b = void{};
        try expectEqual(void, @TypeOf(a));
        try expectEqual(void, @TypeOf(b));
        try expectEqual(a, b);
    }

test_empty_block.zig

    $ zig test test_empty_block.zig
    1/1 test_empty_block.test_0...OK
    All 1 tests passed.

Shell

