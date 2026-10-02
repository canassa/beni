//! What one module's check reads, shared by the generator, the solver
//! and publication (checker-v2.md §5). One per module, built by
//! `Module.check` in P1 and never written after it except through the
//! pointers it holds (`store`, `too_deep`, `effects`).
//!
//! It deliberately has no `local_var`, no `inst_result` and no "current
//! declaration", so the solver cannot read generation-time context through
//! it (checker-v2.md §6.2). The one place an `Env` exists is `Report.zig`,
//! as the context the shared message texts are written against (§15.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Artifacts = @import("../Artifacts.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Schema = @import("Schema.zig");
const reads = @import("reads.zig");

const Context = @This();

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

gpa: Allocator,
/// The worker's module arena, reset after the module.
scratch: Allocator,
store: *TypeStore,
types: *const Types,
graph: *const Graph,
artifacts: *const Artifacts,
interner: *const InternPool.Global,
interfaces: []const Interface,
module: Graph.Index,
bir: *const Bir,
schemas: *Schema.State,
/// Written types the reader could not finish, by the instruction a message
/// points at: sorted, deduplicated and
/// reported once at the end of P8 (`Module.reportTooDeep`).
too_deep: *std.ArrayList(TooDeep),
/// The run keeps the module's tables for `dump --stage=types`: each
/// annotated declaration gets a reading of its annotation that nothing
/// unifies, which the dump prints (`constrain/Decl.zig`'s `Member.display`).
keep_display: bool = false,
/// The vocabulary this module's markup is typed against (checker-v2.md
/// §25.2), when it writes markup and the build has one. Set after the
/// vocabulary declarations are checked and before any value group.
markup: ?*Markup = null,
/// Where the generator, the solver and instantiation record what effect
/// inference solves after P5 (transparent-effects-proposal.md §14,
/// checker-v2.md §26); null in a unit test that builds no module.
effects: ?*Effects = null,
/// Where the generator records each `_ = e` — a `let_pattern` whose
/// pattern is `_` — and the variable of its value, for `unit_discarded`
/// (checker-v2.md §34); null when that warning is off.
discards: ?*std.ArrayList(Discard) = null,

/// One `_ = e`: the `let_pattern` and the variable its value was checked
/// against.
pub const Discard = struct { inst: Bir.Inst.Index, v: Var };

const Markup = @import("Markup.zig");
const Effects = @import("Effects.zig");

/// One written or inferred type too deep to finish: where the message points,
/// and the declaration whose failure bit it sets (§15.2).
pub const TooDeep = struct {
    region: Bir.Inst.Index,
    decl: ?u32,
    /// What was too deep, which the message names: a written or inferred
    /// type, or markup the generator could not follow.
    what: What = .type,

    pub const What = enum { type, markup };
};

/// Another module's interface, noted for the covered-read self-check
/// (`reads.zig`): every cross-module read on the checking path goes through
/// here.
pub fn iface(cx: *const Context, m: Graph.Index) *const Interface {
    reads.note(.iface, m);
    return &cx.interfaces[m.int()];
}

/// A reader for written types, with this module's schema lookup — the same
/// reader `Env.builder` makes, so an annotation reads the same here.
pub fn builder(cx: *const Context, mode: Types.VarMode, rank: u32) Types.Builder {
    var b: Types.Builder = .init(cx.store, cx.types, cx.graph, cx.artifacts, cx.module, cx.bir, mode, rank, cx.scratch, cx.interner);
    b.schema_context = cx.schemas;
    b.schema_lookup = Schema.State.lookupOpaque;
    b.interfaces = cx.interfaces;
    return b;
}

/// Read `annotation` with `b`, noting it when the reader ran out of depth,
/// so no guard poisons a type without a message (`fast-compiler.md` §5).
pub fn readAnnotation(cx: *const Context, b: *Types.Builder, annotation: Bir.Inst.Index, decl: ?u32) Error!Var {
    const v = try b.read(annotation);
    if (b.too_deep) try cx.noteTooDeep(annotation, decl);
    return v;
}

pub fn noteTooDeep(cx: *const Context, region: Bir.Inst.Index, decl: ?u32) Error!void {
    try cx.too_deep.append(cx.scratch, .{ .region = region, .decl = decl });
}

pub fn noteTooDeepAs(cx: *const Context, region: Bir.Inst.Index, decl: ?u32, what: TooDeep.What) Error!void {
    try cx.too_deep.append(cx.scratch, .{ .region = region, .decl = decl, .what = what });
}

/// The instruction a `nesting_too_deep` about declaration `decl` points at:
/// its annotation, its body, or its first instruction.
pub fn noteDeepDecl(cx: *const Context, decl: ?Bir.DeclIndex) Error!void {
    const index = decl orelse return;
    if (index.int() >= cx.bir.decls.len) return;
    const d = cx.bir.decl(index);
    try cx.noteTooDeep(d.annotation.unwrap() orelse d.body.unwrap() orelse d.inst_start, index.int());
}
