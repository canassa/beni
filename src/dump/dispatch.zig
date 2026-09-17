//! `beni dump --stage=dispatch` (docs/design/static-dispatch-spike.md §7.3):
//! what the checker decided about every method call of one module, as text.
//!
//! ```
//! module Tally
//!   decl tally evidence=0
//!   site 12 0 primitive string_compare
//! ```
//!
//! Line-oriented, one fact per line, with **no symbol ids, no positions and
//! no module indices** — every name is text — so reformatting the input
//! leaves a golden untouched and `--jobs` cannot move a byte. That is the
//! rule `dump/types.zig` already states, and the reason the table is sorted
//! before anything indexes it (§7.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Types = @import("../check/Types.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

pub fn write(
    w: *std.Io.Writer,
    module_name: []const u8,
    bir: *const Bir,
    dispatch: *const Dispatch,
    graph: *const Graph,
    interfaces: []const Interface,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
    const cx: Context = .{
        .dispatch = dispatch,
        .bir = bir,
        .graph = graph,
        .interfaces = interfaces,
        .types = types,
        .interner = interner,
    };
    try w.print("module {s}\n", .{module_name});
    // A module with no dispatch at all prints its `module` line and nothing
    // else (§7.3); one with any prints every value declaration in SOURCE
    // order, so the evidence lists read as the parameter lists they are.
    if (dispatch.sites.len == 0 and dispatch.derived.len == 0 and dispatch.evidence.len == 0) return;
    for (bir.decls, 0..) |d, i| {
        if (!d.kind.isValue()) continue;
        const evidence = dispatch.declEvidence(@intCast(i));
        try w.print("  decl {s} evidence={d}\n", .{ interner.slice(bir.symbol(d.name)), evidence.len });
        for (evidence, 0..) |e, k| {
            try w.print("    evidence {d} quantified={d} var={s} method={s}\n", .{
                k,
                e.quantified,
                if (e.var_name.unwrap()) |n| interner.slice(n) else "_",
                interner.slice(e.method),
            });
        }
    }
    // Derived functions in the emission order of §8.5 (by printed name
    // text). `part` lines under a `derived` row are the BODY's positions —
    // every constructor argument of a nominal type, in declaration order
    // (§9's parts contract). A record, a tuple and `()` have none: such a
    // body applies `$m$0 … $m$n-1` position by position by construction
    // (§9.2, §9.3), so `evidence=<n>` is the whole of it.
    for (dispatch.derived, 0..) |d, i| {
        try w.print("  derived {d} {s} ", .{ i, @tagName(d.kind) });
        try cx.writeShape(w, d.shape);
        try w.print(" evidence={d}\n", .{d.evidence_count});
        try cx.writeParts(w, d.parts, 2);
    }
    // Sites sorted by `(inst, evidence_index)`. A site whose target is a
    // derived function carries its OWN evidence arguments, one per
    // position, because the function is keyed on its shape alone and
    // parameterised by them (A.11, A.46) — these are what tell
    // `( Int, Int )` from `( String, String )`.
    for (dispatch.sites) |site| {
        try w.print("  site {d} {d} ", .{ site.inst.int(), site.evidence_index });
        try cx.writeTarget(w, site.target);
        try w.writeByte('\n');
        try cx.writeParts(w, site.target.partsOf(), 2);
    }
}

const Context = struct {
    dispatch: *const Dispatch,
    bir: *const Bir,
    graph: *const Graph,
    interfaces: []const Interface,
    types: *const Types,
    interner: *const InternPool.Global,

    /// `part` lines, nested: a position that is itself a derived function
    /// has its own evidence under it. Indented two spaces per level, so a
    /// record of a record reads as the tree it is.
    fn writeParts(cx: Context, w: *std.Io.Writer, r: Dispatch.Range, indent: usize) Error!void {
        if (r.len == 0) return;
        if (indent > 32) return; // a poisoned table cannot fill stderr
        for (cx.dispatch.partsAt(r), 0..) |target, j| {
            try w.splatByteAll(' ', indent * 2);
            try w.print("part {d} ", .{j});
            try cx.writeTarget(w, target);
            try w.writeByte('\n');
            try cx.writeParts(w, target.partsOf(), indent + 1);
        }
    }

    fn writeShape(cx: Context, w: *std.Io.Writer, shape: Dispatch.Shape) Error!void {
        switch (shape) {
            .nominal => |id| {
                const entry = cx.types.entry(id);
                try w.print("{s}.{s}", .{
                    cx.interner.slice(cx.graph.moduleName(entry.module)),
                    cx.interner.slice(entry.name),
                });
            },
            .record => |r| {
                try w.writeAll("r");
                for (cx.dispatch.symbols[r.start..][0..r.len]) |name| {
                    try w.print("${s}", .{cx.interner.slice(name)});
                }
            },
            .tuple => |n| try w.print("t{d}", .{n}),
            .unit => try w.writeAll("unit"),
        }
    }

    fn writeTarget(cx: Context, w: *std.Io.Writer, target: Dispatch.Target) Error!void {
        switch (target) {
            .top => |d| {
                const name = if (d.int() < cx.bir.decls.len)
                    cx.interner.slice(cx.bir.symbol(cx.bir.decls[d.int()].name))
                else
                    "?";
                try w.print("top {s}", .{name});
            },
            .ext => |e| {
                const module = cx.interner.slice(cx.graph.moduleName(e.module));
                const name = if (e.module.int() < cx.interfaces.len)
                    cx.interner.slice(cx.interfaces[e.module.int()].valueName(e.value))
                else
                    "?";
                try w.print("ext {s} {s}", .{ module, name });
            },
            .evidence => |k| try w.print("evidence {d}", .{k}),
            .primitive => |p| try w.print("primitive {s}", .{@tagName(p)}),
            .derived => |d| try w.print("derived {d}", .{d.index}),
            .ext_derived => |d| {
                const entry = cx.types.entry(d.type);
                try w.print("ext_derived {s}.{s} {s}", .{
                    cx.interner.slice(cx.graph.moduleName(entry.module)),
                    cx.interner.slice(entry.name),
                    @tagName(d.kind),
                });
            },
            .field => try w.writeAll("field"),
            .err => try w.writeAll("err"),
        }
    }
};
