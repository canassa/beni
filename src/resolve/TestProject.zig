//! A whole project in memory, for the hermetic tests of `Graph`,
//! `Interface` and `Resolve` (`.claude/skills/write-tests`, boundary 3).
//!
//! These three are pure functions of "every module's Bir plus the store",
//! and the cheapest honest way to hand them one is to run the real per-file
//! phases over sources that never touch the filesystem: `SourceStore`
//! already carries in-memory files for the embedded core package, so a test
//! module is one of those with its package chosen. The session runs at
//! `--jobs=1` with the core package switched off, so what the graph
//! contains is exactly what the test wrote and nothing else.
//!
//! Test-only: imported from `test` blocks, never from a code path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const Graph = @import("Graph.zig");

const TestProject = @This();

/// One module: a path relative to the (implicit) source root, and its text.
pub const Module = struct {
    path: [:0]const u8,
    source: [:0]const u8,
    package: SourceStore.Package = .app,
    /// Where the module-relative part of `path` starts (the source root's
    /// length plus one). Zero means the whole path is the module name, so
    /// `a/M.beni` is `a.M`; set it to 2 to make it `M`.
    rel_start: u32 = 0,
};

/// What the project runs. `resolve_phases` stops at names (M2a); the
/// checker's tests pass `check_phases` and ask for the stores to be kept so
/// they can look at the types afterwards.
pub const Options = struct {
    phases: Session.Phases = Session.resolve_phases,
    keep_type_stores: bool = false,
};

session: Session,
/// Everything the run wrote to stderr — empty unless a scenario wants the
/// rendered prose.
stderr: Io.Writer.Allocating,

pub fn init(gpa: Allocator, modules: []const Module) !TestProject {
    return initWith(gpa, modules, .{});
}

pub fn initWith(gpa: Allocator, modules: []const Module, options: Options) !TestProject {
    var p: TestProject = .{
        .session = try Session.init(gpa, std.testing.io, .{
            .jobs = 1,
            .diagnostics = .json,
            .keep_type_stores = options.keep_type_stores,
        }),
        .stderr = .init(gpa),
    };
    errdefer p.deinit();
    for (modules) |m| try p.session.store.addEmbedded(gpa, m.path, m.rel_start, m.package, m.source);
    // No argument paths: every file is one of the seeded ones.
    _ = try p.session.run(&.{}, options.phases, &p.stderr.writer);
    return p;
}

pub fn deinit(p: *TestProject) void {
    p.session.deinit();
    p.stderr.deinit();
}

pub fn graph(p: *const TestProject) *const Graph {
    return &p.session.graph;
}

/// The module named `name`, whatever package it is in.
pub fn module(p: *const TestProject, name: []const u8) ?Graph.Index {
    for (0..p.session.graph.count()) |i| {
        const m: Graph.Index = @enumFromInt(i);
        if (std.mem.eql(u8, p.session.interner.slice(p.session.graph.moduleName(m)), name)) return m;
    }
    return null;
}

/// The module names of `graph.order`, in order — the whole schedule as
/// something a test can state as a literal.
pub fn order(p: *const TestProject, gpa: Allocator) Allocator.Error![][]const u8 {
    const out = try gpa.alloc([]const u8, p.session.graph.order.len);
    for (p.session.graph.order, out) |m, *slot| {
        slot.* = p.session.interner.slice(p.session.graph.moduleName(m));
    }
    return out;
}

/// Every diagnostic code of the run, in emission order.
pub fn codes(p: *const TestProject, gpa: Allocator) Allocator.Error![]@import("diagnostic").Code {
    const out = try gpa.alloc(@import("diagnostic").Code, p.session.diagnostics.items.len);
    for (p.session.diagnostics.items, out) |d, *slot| slot.* = d.code;
    return out;
}
