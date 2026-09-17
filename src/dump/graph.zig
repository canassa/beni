//! `beni dump --stage=graph` (docs/design/checker.md §4.1–§4.4,
//! `static-dispatch-spike.md` §6.8): the module graph's EDGES as text, one
//! per line, so the schedule the parallel checker runs on is an output the
//! black-box suite can assert instead of an internal nobody can see.
//!
//! ```
//! app:C -> app:B
//! app:D -> core:List
//! core:List -> core:Basics
//! ```
//!
//! Every edge, `from -> to`, sorted by the printed line. A module's
//! identity is `(package, name)` and not the name alone — the user's
//! package and core may each have a `List` (see `Graph`'s header) — so both
//! halves carry their package and a golden cannot confuse the two.
//!
//! **Why the edges and not the order.** `order` is a topological sort of
//! exactly these edges, so a golden over the edge set pins the schedule and
//! says WHY, while a golden over the order alone would move for either of
//! two unrelated reasons. What §6.8 needs asserted is that the module
//! declaring a type is an ancestor of every module that can see the type,
//! and that is a statement about edges.
//!
//! There are no positions, no symbol ids and no file indices here, so the
//! output is a function of the sources alone and is byte-identical at every
//! `--jobs` (`fast-compiler.md` §10).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

pub fn write(
    w: *std.Io.Writer,
    gpa: Allocator,
    graph: *const Graph,
    interner: *const InternPool.Global,
) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    for (0..graph.count()) |i| {
        const from: Graph.Index = @enumFromInt(i);
        for (graph.dependencies(from)) |to| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "{s} -> {s}", .{
                try name(arena, graph, interner, from),
                try name(arena, graph, interner, to),
            }));
        }
    }
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    for (lines.items) |line| try w.print("{s}\n", .{line});
}

/// `package:Module`. The package is the file's, not the importer's: an
/// `app` module that shadows a core one keeps its own prefix.
fn name(
    arena: Allocator,
    graph: *const Graph,
    interner: *const InternPool.Global,
    i: Graph.Index,
) Allocator.Error![]const u8 {
    const m = graph.module(i);
    return std.fmt.allocPrint(arena, "{t}:{s}", .{ m.package, interner.slice(m.name) });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
