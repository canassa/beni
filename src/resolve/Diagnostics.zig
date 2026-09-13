//! The prose for the M2a resolution diagnostics (checker.md §8, language.md
//! §10), kept apart from the pass that finds them for the reason the lexer's
//! and the parser's are: an item is `(code, where, a name or two)` while the
//! pass runs, and the sentences are written only for the items that survive
//! to be printed (`fast-compiler.md` §7, "good messages off the happy path").
//!
//! Register is Elm's: say what was looked for, where it was looked, and what
//! would fix it.

const std = @import("std");
const diagnostic = @import("diagnostic");

/// What a message needs beyond its code: the name that failed to resolve
/// and the module it was looked up in, as TEXT — the renderer runs after
/// the interner is final and never needs a symbol.
pub const Context = struct {
    /// The offending name (`Decoder`, `map2`, `Just`).
    name: []const u8 = "",
    /// The module it was sought in, or the module that owns it.
    module: []const u8 = "",
    /// `opaque_constructor`: the type whose constructors are hidden.
    /// `wrong_type_arity`: unused.
    owner: []const u8 = "",
    /// `wrong_type_arity`: what the declaration says and what the use gave.
    expected: u32 = 0,
    found: u32 = 0,
    /// `import_cycle`: the modules of the cycle in order.
    cycle: []const []const u8 = &.{},
    /// `duplicate_module`: the path of the file that claimed the name.
    other_path: []const u8 = "",
};

pub fn message(code: diagnostic.Code, cx: Context, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (code) {
        .unknown_module => try w.print(
            \\I cannot find a module named `{s}`.
            \\
            \\I looked in this project and in the core package. Check the spelling, or check
            \\that a file named `{s}.beni` exists under the source root.
        , .{ cx.name, cx.name }),
        .duplicate_module => try w.print(
            \\Two files claim the module name `{s}`.
            \\
            \\The other one is `{s}`. A module's name comes from its path, so two paths that
            \\differ only outside the source root collide. Move or rename one of them.
        , .{ cx.name, cx.other_path }),
        .import_cycle => {
            try w.print("These modules import each other in a circle:\n\n    ", .{});
            for (cx.cycle, 0..) |m, i| {
                if (i > 0) try w.writeAll(" → ");
                try w.writeAll(m);
            }
            if (cx.cycle.len > 0) try w.print(" → {s}", .{cx.cycle[0]});
            try w.print(
                \\
                \\
                \\Beni compiles modules in dependency order, so a circle has no place to start.
                \\Move what they share into a module of its own and have both import that.
            , .{});
        },
        .unknown_import_name => try w.print(
            \\`{s}` does not expose `{s}`.
            \\
            \\Check the spelling, or check that the declaration in `{s}` is marked `pub`.
        , .{ cx.module, cx.name, cx.module }),
        .private_name => try w.print(
            \\`{s}` is not public in `{s}`.
            \\
            \\It is declared there, but without `pub`, so only that module can use it. Add
            \\`pub` to its declaration if it is meant to be part of the interface.
        , .{ cx.name, cx.module }),
        .opaque_constructor => try w.print(
            \\`{s}` is a constructor of `{s}.{s}`, which is opaque.
            \\
            \\`pub opaque type` exposes the type's NAME and hides how it is built, so only
            \\`{s}` may write its constructors. Use the functions it exposes instead.
        , .{ cx.name, cx.module, cx.owner, cx.module }),
        .wrong_type_arity => try w.print(
            \\`{s}` takes {d} type {s}, but here it has {d}.
            \\
            \\Every type constructor is fully applied — beni has no higher-kinded types — so
            \\the number has to match the declaration exactly.
        , .{ cx.name, cx.expected, plural(cx.expected), cx.found }),
        .recursive_alias => try w.print(
            \\The type alias `{s}` refers to itself.
            \\
            \\An alias is a spelling for the type it names, so one that mentions itself —
            \\directly, or through other aliases — has no expansion. Make it a `type` with a
            \\constructor instead; that is what gives recursion somewhere to stop.
        , .{cx.name}),
        .unknown_module_alias => try w.print(
            \\I cannot find a module named `{s}`.
            \\
            \\The qualified name `{s}.{s}` needs it. Check the spelling, or add an import.
        , .{ cx.module, cx.module, cx.name }),
        // A code this pass does not produce; the title is still true.
        else => try w.writeAll(diagnostic.title(code)),
    }
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "argument" else "arguments";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectMessage(expected: []const u8, code: diagnostic.Code, cx: Context) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try message(code, cx, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "every M2a resolution code renders prose naming what failed" {
    try expectMessage(
        "I cannot find a module named `Json.Decode`.\n\nI looked in this project and in the core package. Check the spelling, or check\nthat a file named `Json.Decode.beni` exists under the source root.",
        .unknown_module,
        .{ .name = "Json.Decode" },
    );
    try expectMessage(
        "These modules import each other in a circle:\n\n    A → B → C → A\n\nBeni compiles modules in dependency order, so a circle has no place to start.\nMove what they share into a module of its own and have both import that.",
        .import_cycle,
        .{ .cycle = &.{ "A", "B", "C" } },
    );
    try expectMessage(
        "`Util` does not expose `helper`.\n\nCheck the spelling, or check that the declaration in `Util` is marked `pub`.",
        .unknown_import_name,
        .{ .name = "helper", .module = "Util" },
    );
    try expectMessage(
        "`helper` is not public in `Util`.\n\nIt is declared there, but without `pub`, so only that module can use it. Add\n`pub` to its declaration if it is meant to be part of the interface.",
        .private_name,
        .{ .name = "helper", .module = "Util" },
    );
    try expectMessage(
        "`Leaf` is a constructor of `Tree.Tree`, which is opaque.\n\n`pub opaque type` exposes the type's NAME and hides how it is built, so only\n`Tree` may write its constructors. Use the functions it exposes instead.",
        .opaque_constructor,
        .{ .name = "Leaf", .module = "Tree", .owner = "Tree" },
    );
    try expectMessage(
        "`Dict` takes 2 type arguments, but here it has 1.\n\nEvery type constructor is fully applied — beni has no higher-kinded types — so\nthe number has to match the declaration exactly.",
        .wrong_type_arity,
        .{ .name = "Dict", .expected = 2, .found = 1 },
    );
    try expectMessage(
        "`Maybe` takes 1 type argument, but here it has 0.\n\nEvery type constructor is fully applied — beni has no higher-kinded types — so\nthe number has to match the declaration exactly.",
        .wrong_type_arity,
        .{ .name = "Maybe", .expected = 1, .found = 0 },
    );
    try expectMessage(
        "The type alias `Loop` refers to itself.\n\nAn alias is a spelling for the type it names, so one that mentions itself —\ndirectly, or through other aliases — has no expansion. Make it a `type` with a\nconstructor instead; that is what gives recursion somewhere to stop.",
        .recursive_alias,
        .{ .name = "Loop" },
    );
    try expectMessage(
        "Two files claim the module name `Main`.\n\nThe other one is `a/Main.beni`. A module's name comes from its path, so two paths that\ndiffer only outside the source root collide. Move or rename one of them.",
        .duplicate_module,
        .{ .name = "Main", .other_path = "a/Main.beni" },
    );
    try expectMessage(
        "I cannot find a module named `Char`.\n\nThe qualified name `Char.toUpper` needs it. Check the spelling, or add an import.",
        .unknown_module_alias,
        .{ .name = "toUpper", .module = "Char" },
    );
}
