//! The declaration-edge walk, once (`checker.md` §6.7, `backend.md` §9).
//!
//! Two passes need to know what a top-level declaration REFERS TO:
//! `check/Cycles.zig`, which refuses a top-level value reachable from its own
//! initialiser, and `js/Reach.zig`, which ships only what `main` reaches.
//! They ask the same question of the same two tables — the module's `Bir` and
//! the module's dispatch table — and they asked it twice, in two files, with
//! nothing but a "these must agree" comment in each to keep them in step.
//! That is the shape of defect this compiler has already paid for twice: the
//! DCE slice's spec was missing three of these edges and only a compile-time
//! wall caught them, and a `foreign`'s arity was computed independently in two
//! places and drifted. So the walk lives here and each consumer takes what it
//! needs from it.
//!
//! **Where it lives, and why here.** The walk is a pure function of `Bir` and
//! `Dispatch`. `Dispatch` is the checker's (`checker.md` §3), and `Cycles`
//! runs per module inside §4.4's DAG-parallel check, where depending on the
//! backend is not allowed; `js/Reach.zig` already imports `check/Dispatch.zig`
//! and `check/Types.zig`, so the dependency `src/js/` → `src/check/` is the
//! one that exists and the one that stays. `src/check/` is therefore the only
//! home both can reach, and this file adds no import `Dispatch.zig` did not
//! already have.
//!
//! **The three legs**, out of a value declaration `d`:
//!
//!   1. every `Bir.refs` row of `d` whose kind is `top_value`;
//!   2. every `.top` and `.ext_value` instruction in `d`'s contiguous
//!      instruction range. `refs` records a reference by the NAME the source
//!      wrote and an operator writes none, so `0 - n` lowers to a call of
//!      `Basics.sub` whose `refs` row stays a symbolic `import_value` while
//!      the instruction is rewritten — to a plain `top` inside `core/Basics`
//!      itself, to an `ext_value` carrying `(Graph.Index, ValueIndex)`
//!      anywhere else (`backend.md` §9 legs 1 and 2);
//!   3. every dispatch site of `d`, and recursively every target nested in one
//!      through `Dispatch.partsAt`. **These are the edges `Bir` deliberately
//!      does not have** (`frontend.md` §3.6, `static-dispatch-spike.md` §1.4):
//!      a method call's callee is not known until the checker has run, and an
//!      evidence argument is a reference no source line spells.
//!
//! Out of a `Derived` row: every target of its `parts`, recursively, by the
//! same mapping (`derivedEdges`). Out of a foreign binding: nothing.
//!
//! **A tagged stream, not a callback.** `Edge` is the union of everything the
//! three legs can name, and the caller appends it to a buffer it owns and
//! reuses — flat output, no per-edge indirection and no allocation the caller
//! did not ask for. Each consumer then reads the tags it cares about:
//! `Reach` maps all six onto its whole-program `Node`s, and `Cycles` keeps
//! `.top` alone, because a cycle cannot cross a module (the module graph is a
//! DAG and an import circle is already `import_cycle`) and every other tag
//! is cross-module or synthesised. Adding a fourth leg — effects and chunking
//! will each want one — is adding a tag here, and both consumers are then
//! made to answer for it by the compiler.
//!
//! **Determinism.** Nothing here reads anything but the two tables it is
//! handed, and it appends in table order: leg 1 in `refs` order, leg 2 in
//! instruction order, leg 3 in site order with a target's own edge before its
//! `parts`. The order is a function of the input, which is what lets `Cycles`
//! print a path and `Reach` build one edge list per module in parallel
//! (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");

pub const Error = Allocator.Error;

/// A poisoned `parts` range could point back at itself; the walk that reads
/// one is recursive, so it is capped exactly as `Lower.derivedValue` and
/// `dump/dispatch.zig` cap theirs.
pub const max_depth: u8 = 32;

/// One thing a declaration refers to, in the numbering of the module it was
/// read out of. Nothing here is resolved against another module's tables:
/// that is the consumer's job, and `Cycles` does not have those tables.
pub const Edge = union(enum) {
    /// A declaration of THIS module, by `Bir.Decl` index.
    top: u32,
    /// A value of another module, by interface index.
    ext: Ext,
    /// A `Dispatch.Derived` row of THIS module, by index.
    derived: u32,
    /// Another module's derived function, by `(module, type, kind)`.
    ext_derived: ExtDerived,
    /// A dispatch primitive. Only `string_compare` names a declaration —
    /// core `String.compare` (`backend.md` §9's correction) — but the tag is
    /// yielded whole so the consumer, not the walk, decides that.
    primitive: Dispatch.Target.Primitive,
    /// A poisoned comparison, which lowers to a call of core `Basics.eq`
    /// (`Lower.partEq`'s `err` arm).
    err,

    /// `Graph.Index` plus the raw `Interface.ValueIndex`, which only a
    /// consumer holding that module's provenance table can turn into a
    /// declaration.
    pub const Ext = struct { module: Graph.Index, value: u32 };

    /// `Dispatch.Target.ExtDerivedUse` **without its `parts`**, which the
    /// walk has already followed and yielded as edges of their own. Dropping
    /// them keeps the union at three words, and this stream is hot: it is
    /// written once and read once per declaration of the build.
    pub const ExtDerived = struct {
        module: Graph.Index,
        type: Dispatch.TypeId,
        kind: Dispatch.Derived.Kind,
    };

    comptime {
        // The stream is the pass's memory traffic, so its width is an
        // invariant and not an accident.
        std.debug.assert(@sizeOf(Edge) <= 16);
    }
};

/// Every within-module edge out of declaration `index`, appended to `out` in
/// the three-leg order.
///
/// **Which declarations are walked at all is the caller's**, and deliberately
/// so: `Reach` walks every `.value` because a body-less one contributes an
/// empty range anyway, while `Cycles` walks only a `.value` with a body,
/// because a declaration that emits no initialiser is not a node of its graph.
/// Putting that filter here would make one of the two answer the other's
/// question.
pub fn declEdges(
    out: *std.ArrayList(Edge),
    scratch: Allocator,
    bir: *const Bir,
    dispatch: *const Dispatch,
    index: u32,
) Error!void {
    const d = bir.decls[index];

    // Leg 1: the reference table, already deduplicated per declaration and in
    // source order.
    for (bir.refs[d.refs_start..d.refs_end]) |ref| {
        if (ref.kind != .top_value) continue;
        try out.append(scratch, .{ .top = ref.a });
    }

    // Leg 2: the references `Resolve` rewrote into the instructions. A
    // declaration's instructions are contiguous, so this is a slice walk and
    // not a tree traversal.
    const tags = bir.insts.items(.tag);
    const data = bir.insts.items(.data);
    const start = @min(d.inst_start.int(), bir.insts.len);
    const end = @min(d.inst_end.int(), bir.insts.len);
    for (tags[start..end], data[start..end]) |tag, payload| {
        switch (tag) {
            .top => try out.append(scratch, .{ .top = payload.lhs }),
            .ext_value => try out.append(scratch, .{ .ext = .{
                .module = @enumFromInt(payload.lhs),
                .value = payload.rhs,
            } }),
            else => {},
        }
    }

    // Leg 3: the dispatch sites, and everything nested in one.
    const range = siteRange(dispatch.sites, d.inst_start.int(), d.inst_end.int());
    for (dispatch.sites[range.start..][0..range.len]) |site| {
        try targetEdges(out, scratch, dispatch, site.target, 0);
    }
}

/// Every edge out of `Dispatch.Derived` row `index`: the targets of its
/// `parts`, recursively. That is how a derived `eq` for
/// `type T = T (Maybe U)` reaches `Maybe`'s row and `U`'s.
pub fn derivedEdges(
    out: *std.ArrayList(Edge),
    scratch: Allocator,
    dispatch: *const Dispatch,
    index: u32,
) Error!void {
    for (dispatch.partsAt(dispatch.derived[index].parts)) |part| {
        try targetEdges(out, scratch, dispatch, part, 0);
    }
}

/// One dispatch target's edge, then recursively its evidence arguments. An
/// `evidence` target is a parameter and a `field` target is a property read,
/// so neither names anything that is emitted.
pub fn targetEdges(
    out: *std.ArrayList(Edge),
    scratch: Allocator,
    dispatch: *const Dispatch,
    t: Dispatch.Target,
    depth: u8,
) Error!void {
    if (depth > max_depth) return;
    switch (t) {
        .top => |use| try out.append(scratch, .{ .top = use.decl.int() }),
        .ext => |e| try out.append(scratch, .{ .ext = .{
            .module = e.module,
            .value = @intFromEnum(e.value),
        } }),
        .derived => |use| try out.append(scratch, .{ .derived = use.index }),
        .ext_derived => |use| try out.append(scratch, .{ .ext_derived = .{
            .module = use.module,
            .type = use.type,
            .kind = use.kind,
        } }),
        .primitive => |prim| try out.append(scratch, .{ .primitive = prim }),
        .err => try out.append(scratch, .err),
        .evidence, .field => {},
    }
    for (dispatch.partsAt(t.partsOf())) |part| {
        try targetEdges(out, scratch, dispatch, part, depth + 1);
    }
}

/// The dispatch sites of one instruction range. `Dispatch.sites` is grouped
/// by `inst` and a declaration's instructions are contiguous, so this is a
/// lower bound plus a scan — `Lower.siteRangeOf` reads the same table the
/// same way.
pub fn siteRange(sites: []const Dispatch.Site, start: u32, end: u32) Dispatch.Range {
    const lo = std.sort.lowerBound(Dispatch.Site, sites, start, siteBefore);
    var hi = lo;
    while (hi < sites.len and sites[hi].inst.int() < end) hi += 1;
    return .{ .start = @intCast(lo), .len = @intCast(hi - lo) };
}

fn siteBefore(inst: u32, s: Dispatch.Site) std.math.Order {
    return std.math.order(inst, s.inst.int());
}

// ---------------------------------------------------------------------------
// Tests
//
// A SUPPLEMENT and never the coverage (CLAUDE.md rule 3): what the two
// consumers decide is visible as diagnostics (`check/bad/Cyclic*`) and as
// emitted JavaScript that runs (`emit/app/`, `run/Dce*`). What is here is the
// one thing neither can point at — that the walk yields ALL THREE legs, in
// order, out of one declaration. It exists so that the day effects or
// chunking adds a fourth, the leg is added in one place and this test is what
// notices it went missing from the other.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "one declaration, three legs, in table order" {
    const gpa = testing.allocator;

    // A module of two declarations. Declaration 0 is the one under test; it
    // is written to exercise every leg at once:
    //
    //   leg 1  `refs`   → `top 1` (and a `top_type` row that is not an edge)
    //   leg 2  insts    → `top 1`, and an `ext_value` of module 3 value 4
    //   leg 3  a site   → `derived 0`, whose one part is `ext` module 5
    //                     value 6, and a second site on `primitive
    //                     string_compare`
    //
    // Declaration 1 has an instruction and a site of its own, which is what
    // makes the range arithmetic visible: reading one instruction or one
    // site past `inst_end` would pull its `top 0` into declaration 0's list.
    var insts: Bir.InstList = .empty;
    defer insts.deinit(gpa);
    // decl 0's range, insts 0..3
    try insts.append(gpa, .{ .tag = .int, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });
    try insts.append(gpa, .{ .tag = .top, .main_token = 0, .data = .{ .lhs = 1, .rhs = 0 } });
    try insts.append(gpa, .{ .tag = .ext_value, .main_token = 0, .data = .{ .lhs = 3, .rhs = 4 } });
    // decl 1's range, insts 3..4 — a `top` this walk must NOT see.
    try insts.append(gpa, .{ .tag = .top, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });

    const refs = [_]Bir.Ref{
        .{ .kind = .top_value, .a = 1, .b = 0 },
        // A type reference is not a value edge.
        .{ .kind = .top_type, .a = 1, .b = 0 },
    };

    var bir: Bir = .empty;
    bir.insts = insts.slice();
    bir.refs = &refs;
    const decls = [_]Bir.Decl{
        blankDecl(0, 3, 0, 2),
        blankDecl(3, 4, 2, 2),
    };
    bir.decls = &decls;

    // The dispatch table: two sites on instructions inside declaration 0, and
    // one `parts` row hanging off the first target.
    const parts = [_]Dispatch.Target{
        .{ .ext = .{ .module = @enumFromInt(5), .value = @enumFromInt(6) } },
    };
    const sites = [_]Dispatch.Site{
        .{
            .inst = @enumFromInt(1),
            .evidence_index = 0,
            .target = .{ .derived = .{ .index = 0, .parts = .{ .start = 0, .len = 1 } } },
        },
        .{ .inst = @enumFromInt(2), .evidence_index = 1, .target = .{ .primitive = .string_compare } },
        // Declaration 1's site: past `inst_end`, so `siteRange` must stop.
        .{ .inst = @enumFromInt(3), .evidence_index = 2, .target = .{ .top = .{ .decl = @enumFromInt(0) } } },
    };
    var dispatch: Dispatch = .empty;
    dispatch.sites = &sites;
    dispatch.parts = &parts;

    var out: std.ArrayList(Edge) = .empty;
    defer out.deinit(gpa);
    try declEdges(&out, gpa, &bir, &dispatch, 0);

    try testing.expectEqual(@as(usize, 6), out.items.len);
    // Leg 1.
    try testing.expectEqual(@as(u32, 1), out.items[0].top);
    // Leg 2, in instruction order.
    try testing.expectEqual(@as(u32, 1), out.items[1].top);
    try testing.expectEqual(@as(u32, 3), out.items[2].ext.module.int());
    try testing.expectEqual(@as(u32, 4), out.items[2].ext.value);
    // Leg 3: the target, then what it passes, then the next site.
    try testing.expectEqual(@as(u32, 0), out.items[3].derived);
    try testing.expectEqual(@as(u32, 5), out.items[4].ext.module.int());
    try testing.expectEqual(@as(u32, 6), out.items[4].ext.value);
    try testing.expectEqual(Dispatch.Target.Primitive.string_compare, out.items[5].primitive);

    // The neighbouring declaration's instruction and site are its own, and
    // both of them show up here and nowhere above: the ranges are what
    // separates two declarations, and reading one instruction or one site too
    // far is the way this walk goes wrong.
    out.clearRetainingCapacity();
    try declEdges(&out, gpa, &bir, &dispatch, 1);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].top);
    try testing.expectEqual(@as(u32, 0), out.items[1].top);
}

/// A `Decl` with nothing in it but the four ranges the walk reads.
fn blankDecl(inst_start: u32, inst_end: u32, refs_start: u32, refs_end: u32) Bir.Decl {
    return .{
        .kind = .value,
        .name = @enumFromInt(0),
        .name_token = 0,
        .is_pub = false,
        .is_opaque = false,
        .is_equatable = false,
        .doc_start = 0,
        .doc_end = 0,
        .params = 0,
        .params_start = @enumFromInt(0),
        .params_end = @enumFromInt(0),
        .type_params_start = 0,
        .type_params_end = 0,
        .annotation = .none,
        .where_start = @enumFromInt(0),
        .where_end = @enumFromInt(0),
        .body = @enumFromInt(inst_start),
        .schema_body = .none,
        .inst_start = @enumFromInt(inst_start),
        .inst_end = @enumFromInt(inst_end),
        .ctors_start = 0,
        .ctors_end = 0,
        .locals_start = 0,
        .locals_end = 0,
        .refs_start = refs_start,
        .refs_end = refs_end,
    };
}

test "a `parts` range that points back at itself is capped, not followed forever" {
    const gpa = testing.allocator;
    // A poisoned table: the target's evidence argument is itself. The walk
    // stops at `max_depth`, which is what keeps a corrupt dispatch table from
    // being a hang rather than a diagnostic.
    const parts = [_]Dispatch.Target{
        .{ .derived = .{ .index = 0, .parts = .{ .start = 0, .len = 1 } } },
    };
    var dispatch: Dispatch = .empty;
    dispatch.parts = &parts;

    var out: std.ArrayList(Edge) = .empty;
    defer out.deinit(gpa);
    try targetEdges(&out, gpa, &dispatch, parts[0], 0);
    try testing.expectEqual(@as(usize, max_depth + 1), out.items.len);
}
