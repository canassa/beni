//! What one module's v2 check reads, shared by the generator, the solver
//! and publication (checker-v2.md §5). One per module, built by
//! `Module.check` in P1 and never written after it except through the
//! pointers it holds (`store`, `too_deep`).
//!
//! It is deliberately NOT v1's `Constrain.Env`: it has no `local_var`, no
//! `inst_result` and no "current declaration", so the solver cannot read
//! generation-time context through it (I11, checker-v2.md §6.2). The one
//! place a v1 `Env` still exists is `Report.zig`, as the context v1's
//! message texts are written against (§15.1, *As built by R4b*).

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
/// points at (v1's `Env.too_deep`, same contract): sorted, deduplicated and
/// reported once at the end of P8 (`Module.reportTooDeep`).
too_deep: *std.ArrayList(TooDeep),

/// One written or inferred type too deep to finish: where the message points,
/// and the declaration whose failure bit it sets (§15.2, review S10).
pub const TooDeep = struct { region: Bir.Inst.Index, decl: ?u32 };

/// Another module's interface, noted for the covered-read self-check
/// (`reads.zig`): every cross-module read on the checking path goes through
/// here, as v1's `Env.iface` does.
pub fn iface(cx: *const Context, m: Graph.Index) *const Interface {
    reads.note(.iface, m);
    return &cx.interfaces[m.int()];
}

/// A reader for written types, with this module's schema lookup — the same
/// reader v1's `Env.builder` makes, so an annotation reads the same here.
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

/// The instruction a `nesting_too_deep` about declaration `decl` points at:
/// its annotation, its body, or its first instruction (v1's `noteDeepDecl`).
pub fn noteDeepDecl(cx: *const Context, decl: ?Bir.DeclIndex) Error!void {
    const index = decl orelse return;
    if (index.int() >= cx.bir.decls.len) return;
    const d = cx.bir.decl(index);
    try cx.noteTooDeep(d.annotation.unwrap() orelse d.body.unwrap() orelse d.inst_start, index.int());
}
