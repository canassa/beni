//! Cross-module name resolution (docs/design/checker.md §4.5): every module
//! in topological order, every reference in it looked up once against the
//! interfaces of the modules it imports, and REWRITTEN IN PLACE to the pair
//! of dense indices it resolved to.
//!
//! Rewriting is the point. Lowering leaves a reference as two symbols —
//! `import_value(Basics, add)` — because one file's text is all it may
//! know. After this pass that instruction is `ext_value(module 3, value 7)`
//! and no later phase ever looks a name up again: the checker indexes an
//! array, the backend indexes an array, and M4's cache key is a pair of
//! integers rather than a string comparison. A reference to the module's
//! OWN declarations becomes `top`/`ctor`/`type_top`, and one that does not
//! resolve becomes `error`, so the unresolved forms simply do not exist
//! downstream (`Bir.Inst.Tag.isUnresolved`).
//!
//! Four rules decide what a miss means, and they need the target module's
//! Bir as well as its interface — the interface holds what is public, and
//! "is it private or is it absent?" is exactly the difference between
//! `private_name` and `unknown_import_name`:
//!
//!   - in the interface            → resolved
//!   - declared but not `pub`      → `private_name`
//!   - a constructor of a `pub opaque type` → `opaque_constructor`
//!   - not declared at all         → `unknown_import_name`
//!
//! Two checks ride along because they need exactly the same tables:
//!
//!   - **`wrong_type_arity`.** Types are always fully applied (checker.md
//!     Appendix A), so a type reference's argument count must equal the
//!     declared parameter count — 0 for a bare name.
//!   - **`recursive_alias`.** An alias may not mention itself, directly or
//!     through other aliases. The search stays inside one module, and that
//!     is not a shortcut: a chain of aliases that leaves a module and comes
//!     back needs those modules to import each other, which is an
//!     `import_cycle` and is reported there.
//!
//! Poisoned modules — the members of an import cycle — are rewritten but
//! not reported on (checker.md §4.3): one bad edge yields one diagnostic,
//! not one per name in the loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Artifacts = @import("../Artifacts.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Graph = @import("Graph.zig");
const Profile = @import("../Profile.zig");
const Interface = @import("Interface.zig");

const Resolve = @This();

pub const Symbol = InternPool.Symbol;

/// Owned. One per module, indexed by `Graph.Index`; `Interface.empty` for
/// a module that could not be built.
interfaces: []Interface,
/// Owned. In the order the modules were resolved, which is topological and
/// therefore stable; the session sorts them with everything else.
diagnostics: []const Item,

/// A resolution diagnostic before it is rendered: which module, which
/// token, and the names the prose needs (`Diagnostics.Context`).
pub const Item = struct {
    code: diagnostic.Code,
    module: Graph.Index,
    /// Token index into the module's file.
    token: u32,
    name: Symbol.Optional = .none,
    module_name: Symbol.Optional = .none,
    owner: Symbol.Optional = .none,
    expected: u32 = 0,
    found: u32 = 0,
};

pub const empty: Resolve = .{ .interfaces = &.{}, .diagnostics = &.{} };

pub fn deinit(r: *Resolve, gpa: Allocator) void {
    for (r.interfaces) |*iface| iface.deinit(gpa);
    gpa.free(r.interfaces);
    gpa.free(r.diagnostics);
    r.* = undefined;
}

/// Resolve every module of `graph`, in its topological order. `scratch` is
/// one worker's arena and holds nothing after the call; the interfaces and
/// the diagnostics are `gpa`-owned and belong to the session.
/// Resolve every module in the graph's order. `profile` gets one `resolve`
/// event per MODULE (checker.md §9) — the per-module granularity is what
/// M4's incrementality tests read, since "this module was not re-resolved"
/// is only visible if the trace has a row per module.
pub fn run(
    gpa: Allocator,
    scratch: Allocator,
    graph: *const Graph,
    artifacts: *Artifacts,
    interner: *const InternPool.Global,
    profile: ?*Profile,
) Allocator.Error!Resolve {
    var r: Resolve = .empty;
    errdefer r.deinit(gpa);
    r.interfaces = try gpa.alloc(Interface, graph.count());
    @memset(r.interfaces, Interface.empty);

    var diagnostics: std.ArrayList(Item) = .empty;
    errdefer diagnostics.deinit(gpa);

    var pass: Pass = .{
        .gpa = gpa,
        .scratch = scratch,
        .graph = graph,
        .artifacts = artifacts,
        .interner = interner,
        .interfaces = r.interfaces,
        .diagnostics = &diagnostics,
    };
    for (graph.order) |m| {
        const token = if (profile) |p| p.begin() else null;
        try pass.module(m);
        if (profile) |p| p.end(0, token.?, .resolve, graph.moduleFile(m).int(), 0);
    }
    r.diagnostics = try diagnostics.toOwnedSlice(gpa);
    return r;
}

const Pass = struct {
    gpa: Allocator,
    scratch: Allocator,
    graph: *const Graph,
    artifacts: *Artifacts,
    interner: *const InternPool.Global,
    interfaces: []Interface,
    diagnostics: *std.ArrayList(Item),

    /// The module being resolved, and the things every helper needs.
    current: Graph.Index = @enumFromInt(0),
    quiet: bool = false,

    fn report(p: *Pass, item: Item) Allocator.Error!void {
        if (p.quiet) return;
        try p.diagnostics.append(p.gpa, item);
    }

    fn module(p: *Pass, m: Graph.Index) Allocator.Error!void {
        p.current = m;
        p.quiet = p.graph.isPoisoned(m);
        const file = p.graph.moduleFile(m);
        const bir = p.artifacts.birMut(file);
        try p.checkExposing(m, bir);
        try p.rewriteReferences(m, bir);
        try p.checkTypeArity(bir);
        try p.checkRecursiveAliases(bir);
        p.interfaces[m.int()] = try Interface.build(p.gpa, bir, p.interner);
    }

    // ---- `exposing` lists ------------------------------------------------

    /// Every name in an `exposing` list must be something the named module
    /// exposes (language.md §5.2), whether or not this file goes on to use
    /// it. A reference would catch the used ones; an unused entry that
    /// names nothing is still a lie about the import, and the list is where
    /// a reader looks to see what a module offers.
    ///
    /// An upper name is a type OR a constructor and the file cannot tell
    /// which (§5.2), so either is enough.
    fn checkExposing(p: *Pass, m: Graph.Index, bir: *const Bir) Allocator.Error!void {
        if (p.quiet) return;
        const pkg = p.graph.module(m).package;
        for (bir.imports) |imp| {
            if (imp.prelude) continue;
            const module_symbol = bir.symbol(imp.module);
            const target = p.graph.lookup(pkg, module_symbol) orelse continue; // `unknown_module`, already reported
            if (target == m) continue; // `self_import`, already reported
            const iface = &p.interfaces[target.int()];
            for (bir.importExposed(imp)) |e| {
                const name = bir.symbol(e.name);
                if (iface.findValue(p.interner, name) != null) continue;
                if (iface.findType(p.interner, name) != null) continue;
                if (iface.findCtor(p.interner, name) != null) continue;
                // Which namespace the name belongs to is not knowable from
                // the list, so the "why" is asked of each in turn and the
                // most specific answer wins.
                const code = p.whyExposedMissing(target, name);
                var item: Item = .{
                    .code = code,
                    .module = m,
                    .token = e.token,
                    .name = name.toOptional(),
                    .module_name = module_symbol.toOptional(),
                };
                if (code == .opaque_constructor) item.owner = p.owningTypeName(target, name).toOptional();
                try p.report(item);
            }
        }
    }

    fn whyExposedMissing(p: *Pass, target: Graph.Index, name: Symbol) diagnostic.Code {
        for ([_]Namespace{ .value, .type, .ctor }) |namespace| {
            const code = p.whyMissing(target, name, namespace);
            if (code != .unknown_import_name) return code;
        }
        return .unknown_import_name;
    }

    // ---- References ------------------------------------------------------

    fn rewriteReferences(p: *Pass, m: Graph.Index, bir: *Bir) Allocator.Error!void {
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        const tokens = bir.insts.items(.main_token);
        for (tags, data, tokens) |*tag, *d, token| {
            if (!tag.isUnresolved()) continue;
            const module_symbol = bir.symbol(@enumFromInt(d.lhs));
            const name = bir.symbol(@enumFromInt(d.rhs));
            const namespace: Namespace = switch (tag.*) {
                .import_value, .qualified => .value,
                .import_ctor, .qualified_ctor => .ctor,
                .type_import, .type_qualified => .type,
                else => unreachable, // isUnresolved covered the rest
            };
            const resolved = try p.resolveOne(m, module_symbol, name, namespace, token);
            tag.* = resolved.tag;
            d.* = .{ .lhs = resolved.lhs, .rhs = resolved.rhs };
        }
    }

    const Namespace = enum { value, ctor, type };

    const Resolved = struct {
        tag: Bir.Inst.Tag,
        lhs: u32,
        rhs: u32,

        fn poison(code: diagnostic.Code) Resolved {
            return .{ .tag = .@"error", .lhs = @intFromEnum(code), .rhs = 0 };
        }
    };

    fn resolveOne(p: *Pass, m: Graph.Index, module_symbol: Symbol, name: Symbol, namespace: Namespace, token: u32) Allocator.Error!Resolved {
        const target = p.graph.lookup(p.graph.module(m).package, module_symbol) orelse {
            // Lowering checked that the ALIAS is imported (language.md
            // §6.2); this is the other half — whether the module it names
            // exists at all, which only the graph knows. A prelude module
            // reaching here means the core package is missing.
            try p.report(.{
                .code = .unknown_module_alias,
                .module = m,
                .token = token,
                .name = name.toOptional(),
                .module_name = module_symbol.toOptional(),
            });
            return .poison(.unknown_module_alias);
        };
        // A module's references to itself resolve to its own declarations
        // (checker.md §4.3), public or not: it is not importing anything.
        if (target == m) return p.resolveSelf(m, name, namespace, token, module_symbol);
        return p.resolveImported(m, target, name, namespace, token, module_symbol);
    }

    fn resolveSelf(p: *Pass, m: Graph.Index, name: Symbol, namespace: Namespace, token: u32, module_symbol: Symbol) Allocator.Error!Resolved {
        const bir = p.artifacts.bir(p.graph.moduleFile(m));
        switch (namespace) {
            .value => for (bir.decls, 0..) |d, i| {
                if (d.kind.isValue() and bir.symbol(d.name) == name) {
                    return .{ .tag = .top, .lhs = @intCast(i), .rhs = 0 };
                }
            },
            .type => for (bir.decls, 0..) |d, i| {
                if (!d.kind.isValue() and bir.symbol(d.name) == name) {
                    return .{ .tag = .type_top, .lhs = @intCast(i), .rhs = 0 };
                }
            },
            .ctor => for (bir.ctors, 0..) |c, i| {
                if (bir.symbol(c.name) == name) {
                    return .{ .tag = .ctor, .lhs = @intCast(i), .rhs = 0 };
                }
            },
        }
        try p.report(.{
            .code = .unknown_import_name,
            .module = m,
            .token = token,
            .name = name.toOptional(),
            .module_name = module_symbol.toOptional(),
        });
        return .poison(.unknown_import_name);
    }

    fn resolveImported(p: *Pass, m: Graph.Index, target: Graph.Index, name: Symbol, namespace: Namespace, token: u32, module_symbol: Symbol) Allocator.Error!Resolved {
        const iface = &p.interfaces[target.int()];
        switch (namespace) {
            .value => if (iface.findValue(p.interner, name)) |v| {
                return .{ .tag = .ext_value, .lhs = target.int(), .rhs = @intFromEnum(v) };
            },
            .type => if (iface.findType(p.interner, name)) |t| {
                return .{ .tag = .ext_type, .lhs = target.int(), .rhs = @intFromEnum(t) };
            },
            .ctor => if (iface.findCtor(p.interner, name)) |c| {
                return .{ .tag = .ext_ctor, .lhs = target.int(), .rhs = @intFromEnum(c) };
            },
        }
        const code = p.whyMissing(target, name, namespace);
        var item: Item = .{
            .code = code,
            .module = m,
            .token = token,
            .name = name.toOptional(),
            .module_name = module_symbol.toOptional(),
        };
        if (code == .opaque_constructor) item.owner = p.owningTypeName(target, name).toOptional();
        try p.report(item);
        return .poison(code);
    }

    /// Why `name` is not in `target`'s interface. Answered from the target
    /// module's Bir, which the interface deliberately does not carry: the
    /// interface is what is PUBLIC, and telling "private" from "absent"
    /// needs what is not.
    fn whyMissing(p: *Pass, target: Graph.Index, name: Symbol, namespace: Namespace) diagnostic.Code {
        const bir = p.artifacts.bir(p.graph.moduleFile(target));
        switch (namespace) {
            .value => for (bir.decls) |d| {
                if (d.kind.isValue() and bir.symbol(d.name) == name) return .private_name;
            },
            .type => for (bir.decls) |d| {
                if (!d.kind.isValue() and bir.symbol(d.name) == name) return .private_name;
            },
            .ctor => for (bir.ctors) |c| {
                if (bir.symbol(c.name) != name) continue;
                const owner = bir.decl(c.decl);
                if (!owner.is_pub) return .private_name;
                // `pub opaque type T = A | B` exports `T` and hides `A`
                // and `B` (language.md §5.1).
                return if (owner.is_opaque) .opaque_constructor else .private_name;
            },
        }
        return .unknown_import_name;
    }

    fn owningTypeName(p: *Pass, target: Graph.Index, ctor: Symbol) Symbol {
        const bir = p.artifacts.bir(p.graph.moduleFile(target));
        for (bir.ctors) |c| {
            if (bir.symbol(c.name) == ctor) return bir.symbol(bir.decl(c.decl).name);
        }
        return ctor;
    }

    // ---- Type arity ------------------------------------------------------

    /// Every type reference must supply exactly the parameters its
    /// declaration takes (checker.md Appendix A). Applications are found
    /// first, so a bare reference — one that is nobody's `type_app` head —
    /// is an application of zero arguments.
    fn checkTypeArity(p: *Pass, bir: *const Bir) Allocator.Error!void {
        if (p.quiet or bir.insts.len == 0) return;
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        const tokens = bir.insts.items(.main_token);
        const applied = try p.scratch.alloc(u32, bir.insts.len);
        defer p.scratch.free(applied);
        @memset(applied, 0);
        for (tags, data) |tag, d| {
            if (tag != .type_app) continue;
            applied[d.lhs] = bir.subRange(@enumFromInt(d.rhs)).len();
        }
        for (tags, data, tokens, applied) |tag, d, token, found| {
            const expected: u32, const name: Symbol = switch (tag) {
                .type_top => .{ bir.decl(@enumFromInt(d.lhs)).params, bir.symbol(bir.decl(@enumFromInt(d.lhs)).name) },
                .ext_type => blk: {
                    const iface = &p.interfaces[d.lhs];
                    const t = iface.types[d.rhs];
                    break :blk .{ t.arity, iface.symbol(t.name) };
                },
                else => continue,
            };
            if (expected == found) continue;
            try p.report(.{
                .code = .wrong_type_arity,
                .module = p.current,
                .token = token,
                .name = name.toOptional(),
                .expected = expected,
                .found = found,
            });
        }
    }

    // ---- Recursive aliases ----------------------------------------------

    /// An alias that can reach itself through alias references inside its
    /// body. One report per cycle, on the alias that starts it in
    /// declaration order; the rest of the cycle is marked done so a loop of
    /// three aliases is one message and not three.
    fn checkRecursiveAliases(p: *Pass, bir: *const Bir) Allocator.Error!void {
        if (p.quiet or bir.decls.len == 0) return;
        var any = false;
        for (bir.decls) |d| {
            if (d.kind == .type_alias) any = true;
        }
        if (!any) return;

        const state = try p.scratch.alloc(u8, bir.decls.len);
        defer p.scratch.free(state);
        @memset(state, 0); // 0 unvisited, 1 on the current path, 2 finished
        for (bir.decls, 0..) |d, i| {
            if (d.kind != .type_alias or state[i] != 0) continue;
            if (try p.aliasReaches(bir, state, @intCast(i))) {
                try p.report(.{
                    .code = .recursive_alias,
                    .module = p.current,
                    .token = d.name_token,
                    .name = bir.symbol(d.name).toOptional(),
                });
            }
        }
    }

    /// Depth-first over `type_top` references inside alias bodies. Returns
    /// true when the walk came back to a declaration already on the path.
    /// Recursion depth is the number of aliases in one module, which the
    /// parser's nesting limit does not bound — so this is iterative.
    fn aliasReaches(p: *Pass, bir: *const Bir, state: []u8, start: u32) Allocator.Error!bool {
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(p.scratch);
        try stack.append(p.scratch, start);
        state[start] = 1;
        var found = false;
        while (stack.items.len > 0) {
            const current = stack.items[stack.items.len - 1];
            const d = bir.decls[current];
            var progressed = false;
            var i = d.inst_start.int();
            while (i < d.inst_end.int()) : (i += 1) {
                if (tags[i] != .type_top) continue;
                const target = data[i].lhs;
                if (bir.decls[target].kind != .type_alias) continue;
                if (state[target] == 1) {
                    found = true;
                    continue;
                }
                if (state[target] != 0) continue;
                state[target] = 1;
                try stack.append(p.scratch, target);
                progressed = true;
                break;
            }
            if (progressed) continue;
            state[current] = 2;
            _ = stack.pop();
        }
        return found;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("TestProject.zig");

/// The codes a two-module project produces, `Util` first. `Main` is the
/// importer in every scenario below.
///
/// The sources name nothing from the prelude: `TestProject` runs with the
/// core package switched off, so an `Int` here would be three
/// `unknown_module_alias` items drowning the one code the scenario is
/// about. What core does for real names is the black-box suite's job.
fn expectCodes(expected: []const diagnostic.Code, util: [:0]const u8, main: [:0]const u8) !void {
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Main.beni", .source = main },
        .{ .path = "Util.beni", .source = util },
    });
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, expected, codes);
}

test "a value, a type and a constructor of another module all resolve" {
    try expectCodes(&.{},
        \\pub type Colour
        \\    = Red
        \\    | Green
        \\
        \\
        \\pub name : Colour -> Colour
        \\name c =
        \\    c
        \\
    ,
        \\import Util exposing (Colour, Red, name)
        \\
        \\
        \\pub mine : Colour
        \\mine =
        \\    name (Util.Green)
        \\
    );
}

test "a name the module does not declare is unknown_import_name, exposed or used" {
    try expectCodes(&.{ .unknown_import_name, .unknown_import_name },
        \\pub present =
        \\    1
        \\
    ,
        \\import Util exposing (absent)
        \\
        \\
        \\pub mine =
        \\    Util.alsoAbsent
        \\
    );
}

test "a name declared without pub is private_name, which is not the same message" {
    try expectCodes(&.{ .private_name, .private_name },
        \\secret =
        \\    1
        \\
    ,
        \\import Util exposing (secret)
        \\
        \\
        \\pub mine =
        \\    Util.secret
        \\
    );
}

test "an opaque type exposes its name and refuses its constructors" {
    try expectCodes(&.{.opaque_constructor},
        \\pub opaque type Token
        \\    = Token
        \\
    ,
        \\import Util exposing (Token)
        \\
        \\
        \\pub mine : Token
        \\mine =
        \\    Util.Token
        \\
    );
}

test "a type constructor must be fully applied, in both directions" {
    try expectCodes(&.{ .wrong_type_arity, .wrong_type_arity },
        \\pub type Box a
        \\    = Box a
        \\
        \\
        \\pub type Plain
        \\    = Plain
        \\
    ,
        \\import Util exposing (Box, Plain)
        \\
        \\
        \\pub tooFew : Box
        \\tooFew =
        \\    tooFew
        \\
        \\
        \\pub tooMany : Plain Plain
        \\tooMany =
        \\    tooMany
        \\
    );
}

test "an alias that reaches itself is one recursive_alias per cycle" {
    // Three aliases in one ring plus one that names itself: two cycles,
    // two diagnostics — not four, and not one per edge.
    var p = try TestProject.init(testing.allocator, &.{.{
        .path = "M.beni",
        .source =
        \\pub type alias Self =
        \\    Self
        \\
        \\
        \\pub type alias A =
        \\    B
        \\
        \\
        \\pub type alias B =
        \\    C
        \\
        \\
        \\pub type alias C =
        \\    A
        \\
        \\
        \\pub type alias Fine =
        \\    Self
        \\
        ,
    }});
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{ .recursive_alias, .recursive_alias }, codes);
    try testing.expectEqual(@as(u32, 1), p.session.diagnostics.items[0].span.start.line);
    try testing.expectEqual(@as(u32, 5), p.session.diagnostics.items[1].span.start.line);
}

test "a qualified name whose module does not exist is unknown_module_alias" {
    // Lowering accepts `Char.toUpper` because `Char` is a prelude module
    // alias (language.md Appendix A) — whether that module EXISTS is the
    // graph's to know, and here the core package is switched off.
    var p = try TestProject.init(testing.allocator, &.{.{
        .path = "M.beni",
        .source = "pub shout : String -> String\nshout s =\n    Char.toUpper s\n",
    }});
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    // `String` is a prelude type from `Basics`, which is equally missing.
    try testing.expectEqualSlices(diagnostic.Code, &.{
        .unknown_module_alias,
        .unknown_module_alias,
        .unknown_module_alias,
    }, codes);
}

test "a poisoned module reports its cycle and nothing else" {
    // `Main` is in a cycle AND names something `Util` does not have. The
    // cycle is the cause; the rest is noise, and §4.3 says a cycle member
    // produces no further diagnostics.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Main.beni", .source = "import Util exposing (absent)\n\n\npub mine =\n    1\n" },
        .{ .path = "Util.beni", .source = "import Main exposing (mine)\n\n\npub present =\n    mine\n" },
    });
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{.import_cycle}, codes);
}

test "every reference is rewritten: no unresolved form survives the pass" {
    // The whole point of §4.5. After resolution the four `(module symbol,
    // name symbol)` tags must not appear anywhere, in ANY module — a name
    // is looked up once and never again.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Main.beni", .source = "import Util exposing (Colour, Red)\n\n\npub mine : Colour\nmine =\n    Util.Red\n" },
        .{ .path = "Util.beni", .source = "pub type Colour\n    = Red\n" },
    });
    defer p.deinit();
    for (0..p.session.store.count()) |i| {
        const bir = p.session.artifacts.bir(@enumFromInt(i));
        for (bir.insts.items(.tag)) |tag| try testing.expect(!tag.isUnresolved());
    }
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{}, codes);
}

test "a module's own names resolve to its own declarations, not through an interface" {
    // `Basics` refers to `Basics.add` through the `+` desugaring and to
    // `Basics.Int` through the prelude. Both are itself, so both become
    // `top`/`type_top` — and a PRIVATE one resolves too, because the
    // module is not importing anything from itself.
    var p = try TestProject.init(testing.allocator, &.{.{
        .path = "Basics.beni",
        .package = .core,
        .source =
        \\pub foreign type Int
        \\
        \\
        \\foreign add : Int -> Int -> Int
        \\
        \\
        \\pub twice : Int -> Int
        \\twice n =
        \\    n + n
        \\
        ,
    }});
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{}, codes);

    const bir = p.session.artifacts.bir(@enumFromInt(0));
    var tops: u32 = 0;
    for (bir.insts.items(.tag)) |tag| {
        if (tag == .top or tag == .type_top) tops += 1;
        try testing.expect(tag != .ext_value and tag != .ext_type and tag != .ext_ctor);
    }
    try testing.expect(tops > 0);
}

// ---- Stress and fuzz --------------------------------------------------------

/// Run the graph and the resolver over an arbitrary pair of modules, and
/// assert the ONE invariant that must hold whatever the input: no
/// unresolved reference survives, and every rewritten pair is in bounds of
/// the tables it names. A panic or an out-of-bounds index here is a bug
/// reachable from user source, which the house rules forbid.
fn checkArbitrary(a: [:0]const u8, b: [:0]const u8) !void {
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "A.beni", .source = a },
        .{ .path = "B.beni", .source = b },
    });
    defer p.deinit();
    for (0..p.session.store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        const bir = p.session.artifacts.bir(file);
        for (bir.insts.items(.tag), bir.insts.items(.data)) |tag, d| {
            try testing.expect(!tag.isUnresolved());
            switch (tag) {
                .ext_value => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].values.len);
                },
                .ext_type => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].types.len);
                },
                .ext_ctor => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].ctors.len);
                },
                .top, .type_top => try testing.expect(d.lhs < bir.decls.len),
                .ctor => try testing.expect(d.lhs < bir.ctors.len),
                else => {},
            }
        }
    }
}

test "every corpus fixture resolves, against itself and against another, without a panic" {
    const corpus = @import("corpus_bir");
    for (corpus.fixtures, 0..) |fixture, i| {
        const other = corpus.fixtures[(i + 1) % corpus.fixtures.len];
        checkArbitrary(fixture.source, other.source) catch |err| {
            std.debug.print("fixtures {s} + {s}: {t}\n", .{ fixture.name, other.name, err });
            return err;
        };
    }
}

test "fuzz: arbitrary bytes as two modules never panic and always resolve in bounds" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(buf[0 .. buf.len - 1], 0x2E501);
            buf[len] = 0;
            const source = buf[0..len :0];
            try checkArbitrary(source, source);
        }
    }.testOne, .{ .corpus = &.{
        "import B exposing (b)\nx = b\n",
        "import A\ny = A.x\n",
        "pub type alias T = T\n",
        "pub opaque type O = O\nx = O\n",
        "pub type P a = P a\nq : P\n",
    } });
}

// PRNG-driven stand-in for the fuzzer (the toolchain's fuzz mode does not
// build on 0.16.0), mirroring `Lower`'s: corpus fixtures with lines
// dropped, duplicated and swapped, PAIRED so cross-module resolution —
// imports, cycles, interfaces — is what gets the mutated input.
// `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: mutated corpus fixtures resolve in pairs without a panic" {
    var iterations: usize = 200;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}

    const corpus = @import("corpus_bir");
    var prng: std.Random.DefaultPrng = .init(0x2E501);
    const random = prng.random();
    var sources: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&sources) |*s| s.deinit(testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(testing.allocator);

    for (0..iterations) |_| {
        for (&sources) |*out| {
            const fixture = corpus.fixtures[random.uintLessThan(usize, corpus.fixtures.len)];
            lines.clearRetainingCapacity();
            // Half the time, prepend an import of the other module, so the
            // pair really is a graph and not two islands.
            if (random.boolean()) try lines.append(testing.allocator, "import A exposing (x)");
            if (random.boolean()) try lines.append(testing.allocator, "import B");
            var it = std.mem.splitScalar(u8, fixture.source, '\n');
            while (it.next()) |line| try lines.append(testing.allocator, line);
            for (0..1 + random.uintLessThan(usize, 4)) |_| {
                if (lines.items.len < 2) break;
                const i = random.uintLessThan(usize, lines.items.len);
                switch (random.uintLessThan(u8, 3)) {
                    0 => _ = lines.orderedRemove(i),
                    1 => try lines.insert(testing.allocator, i, lines.items[random.uintLessThan(usize, lines.items.len)]),
                    else => {
                        const j = random.uintLessThan(usize, lines.items.len);
                        std.mem.swap([]const u8, &lines.items[i], &lines.items[j]);
                    },
                }
            }
            out.clearRetainingCapacity();
            for (lines.items) |line| {
                try out.appendSlice(testing.allocator, line);
                try out.append(testing.allocator, '\n');
            }
            try out.append(testing.allocator, 0);
        }
        const a = sources[0].items[0 .. sources[0].items.len - 1 :0];
        const b = sources[1].items[0 .. sources[1].items.len - 1 :0];
        checkArbitrary(a, b) catch |err| {
            std.debug.print("mutated pair failed ({t}):\n--- A ---\n{s}\n--- B ---\n{s}\n", .{ err, a, b });
            return err;
        };
    }
}
