//! `beni dump --stage=dispatch`, format v2 (docs/design/checker-v2.md §13.2):
//! what the checker decided about every method call of one module, as text.
//!
//! ```
//! module Tally
//!   decl tally evidence=0 arity=1
//!   site 12 callee primitive string_compare
//! ```
//!
//! Line-oriented, one fact per line, with **no symbol ids, no positions and
//! no module indices** — every name is text — so reformatting the input
//! leaves a golden untouched and `--jobs` cannot move a byte. That is the
//! rule `dump/types.zig` already states, and the reason the table is sorted
//! before anything indexes it (§7.1).
//!
//! **A tree is printed as a tree.** A term's arguments are printed one per
//! line, two spaces deeper than the line that holds the term, so a golden
//! reads as the hidden arguments the emitter passes and there is no
//! pre-order to reconstruct (§13.2, which retired A.68's discussion). A
//! callee's own arguments sit under its `site` line as `arg` lines, before the
//! first `evidence` line, so neither can be mistaken for the other; below
//! those two keywords, arguments are bare terms (checker-v2.md §13.2).

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
    // else; one with any prints every value declaration in SOURCE order, so
    // the requirement lists read as the parameter lists they are.
    if (dispatch.isEmpty()) return;
    for (bir.decls, 0..) |d, i| {
        if (!d.kind.isValue()) continue;
        const requirements = dispatch.declRequirements(@intCast(i));
        const arity: u16 = if (i < dispatch.decls.len) dispatch.decls[i].value_arity else 0;
        try w.print("  decl {s} evidence={d} arity={d}\n", .{ interner.slice(bir.symbol(d.name)), requirements.len, arity });
        for (requirements, 0..) |e, k| try cx.writeRequirement(w, k, e);
    }
    // D5's constrained `let`s (§13.1). Empty until R14; printed so the day
    // the column fills, the dump already says so.
    for (dispatch.lets) |let| {
        const r = let.requirements;
        try w.print("  let {d} evidence={d}\n", .{ let.inst.int(), r.len });
        for (dispatch.requirements[r.start..][0..r.len], 0..) |e, k| try cx.writeRequirement(w, k, e);
    }
    // Which shape each `?` solved as (`checker.md` §6.5), ascending by
    // instruction.
    for (dispatch.tries) |t| {
        try w.print("  try {d} {s}\n", .{ t.inst.int(), @tagName(t.shape) });
    }
    // Derived functions in the emission order of §8.5 (by printed name
    // text): the context — its evidence parameters — then, for a nominal
    // type, one `body` term per constructor argument position.
    for (dispatch.derived, 0..) |d, i| {
        try w.print("  derived {d} {s} ", .{ i, @tagName(d.kind) });
        try cx.writeShape(w, d.shape);
        try w.print(" context={d}\n", .{d.context.len});
        for (dispatch.contextOf(@intCast(i)), 0..) |entry, k| {
            try w.print("    context {d} param={d} method={s}\n", .{ k, entry.param, interner.slice(entry.method) });
        }
        for (dispatch.argsAt(d.body), 0..) |t, j| {
            try w.print("    body {d} ", .{j});
            try cx.writeTermLine(w, t, 2);
        }
    }
    // One `site` per instruction, ascending: the callee on the line itself
    // and its own arguments under it, then one `evidence` line per root.
    for (dispatch.sites) |site| {
        try w.print("  site {d}", .{site.inst.int()});
        if (site.callee.unwrap()) |callee| {
            // The callee on the line itself; its OWN arguments (a derived
            // callee's evidence) one per `arg` line under it, so they read
            // apart from the site's `evidence` roots at the same depth.
            try w.writeAll(" callee ");
            try cx.writeTerm(w, callee);
            try w.writeByte('\n');
            if (callee.int() < dispatch.terms.len) for (dispatch.argsOfTerm(callee)) |arg| {
                if (arg.int() <= callee.int()) continue;
                try w.writeAll("    arg ");
                try cx.writeTermLine(w, arg, 2);
            };
        } else {
            try w.writeByte('\n');
        }
        for (dispatch.argsAt(site.evidence)) |root| {
            try w.writeAll("    evidence ");
            try cx.writeTermLine(w, root, 2);
        }
    }
}

const Context = struct {
    dispatch: *const Dispatch,
    bir: *const Bir,
    graph: *const Graph,
    interfaces: []const Interface,
    types: *const Types,
    interner: *const InternPool.Global,

    fn writeRequirement(cx: Context, w: *std.Io.Writer, k: usize, e: Dispatch.Requirement) Error!void {
        try w.print("    requirement {d} quantified={d} var={s} method={s}\n", .{
            k,
            e.quantified,
            if (e.var_name.unwrap()) |n| cx.interner.slice(n) else "_",
            cx.interner.slice(e.method),
        });
    }

    /// The term at `i`, the rest of its line, and its arguments under it —
    /// each at `level + 1`, two spaces a level. The table is acyclic by
    /// construction (every argument follows its owner), so the recursion
    /// ends; the depth guard only keeps a hand-built table from filling
    /// stderr.
    fn writeTermLine(cx: Context, w: *std.Io.Writer, i: Dispatch.TermIndex, level: usize) Error!void {
        try cx.writeTerm(w, i);
        try w.writeByte('\n');
        if (level > 256) return;
        if (i.int() >= cx.dispatch.terms.len) return;
        for (cx.dispatch.argsOfTerm(i)) |arg| {
            if (arg.int() <= i.int()) continue;
            try w.splatByteAll(' ', (level + 1) * 2);
            try cx.writeTermLine(w, arg, level + 1);
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

    fn writeTerm(cx: Context, w: *std.Io.Writer, i: Dispatch.TermIndex) Error!void {
        if (i.int() >= cx.dispatch.terms.len) return w.writeAll("?");
        switch (cx.dispatch.term(i)) {
            .param => |p| switch (p.binder) {
                .decl => try w.print("param {d}", .{p.k}),
                .let => |inst| try w.print("param let {d} {d}", .{ inst.int(), p.k }),
                .derived => |index| try w.print("param derived {d} {d}", .{ index, p.k }),
            },
            .top => |use| {
                const d = use.decl;
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
            .undetermined => try w.writeAll("undetermined"),
            .field => try w.writeAll("field"),
        }
    }
};
