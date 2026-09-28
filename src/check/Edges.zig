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
//!   3. every dispatch site of `d`: its callee term and its evidence roots,
//!      and recursively every term's `args` (checker-v2.md §13.3). **These are the edges `Bir` deliberately
//!      does not have** (`frontend.md` §3.6, `static-dispatch-spike.md` §1.4):
//!      a method call's callee is not known until the checker has run, and an
//!      evidence argument is a reference no source line spells.
//!
//! Out of a `Derived` row: every term of its `body`, recursively, by the
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
//! instruction order, leg 3 in site order, callee before roots, with a term's own edge before its
//! `args` (pre-order). The order is a function of the input, which is what lets `Cycles`
//! print a path and `Reach` build one edge list per module in parallel
//! (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");

pub const Error = Allocator.Error;

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
    primitive: Dispatch.Primitive,
    /// The `undetermined` leaf, which lowers to a call of core `Basics.eq`
    /// in an `eq` position (`Lower.partEq`).
    undetermined,

    /// `Graph.Index` plus the raw `Interface.ValueIndex`, which only a
    /// consumer holding that module's provenance table can turn into a
    /// declaration.
    pub const Ext = struct { module: Graph.Index, value: u32 };

    /// `Dispatch.Term.ExtDerivedUse` **without its `args`**, which the walk
    /// has already followed and yielded as edges of their own. Dropping them
    /// keeps the union at three words, and this stream is hot: it is written
    /// once and read once per declaration of the build.
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

    // Leg 3: the dispatch sites — the callee, then the roots — and every
    // term nested in one, each term once.
    var roots: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer roots.deinit(scratch);
    for (dispatch.sitesIn(d.inst_start.int(), d.inst_end.int())) |site| {
        if (site.callee.unwrap()) |callee| try roots.append(scratch, callee);
        try roots.appendSlice(scratch, dispatch.argsAt(site.evidence));
    }
    // Through the rows this module derives: a derived function RUNS the
    // values its body names when it is called, so a constant that calls one
    // depends on them — for its place in emission order and for the cycle
    // check (else `main` calling `Main$W$$eq`, whose body reads a
    // `Main$key` emitted after `main`, would throw at load).
    try termsEdges(out, scratch, dispatch, roots.items, true);
}

/// Every edge out of `Dispatch.Derived` row `index`: the terms of its
/// `body`, recursively. That is how a derived `eq` for
/// `type T = T (Maybe U)` reaches `Maybe`'s row and `U`'s.
pub fn derivedEdges(
    out: *std.ArrayList(Edge),
    scratch: Allocator,
    dispatch: *const Dispatch,
    index: u32,
) Error!void {
    try termsEdges(out, scratch, dispatch, dispatch.argsAt(dispatch.derived[index].body), false);
}

/// One term's edge, then its arguments' (`termsEdges`).
pub fn termEdges(
    out: *std.ArrayList(Edge),
    scratch: Allocator,
    dispatch: *const Dispatch,
    i: Dispatch.TermIndex,
) Error!void {
    try termsEdges(out, scratch, dispatch, &.{i}, false);
}

/// The edges of `roots` and of every term below them, in pre-order, EACH
/// TERM ONCE. A `param` is a parameter and a `field` is a property read, so
/// neither names anything that is emitted.
///
/// A table may share a term between owners (checker-v2.md §13.1: the
/// checker writes one term per distinct answer of a site, so `==` on a
/// type that is a doubling DAG is linear in its distinct nodes), and
/// a walk that expanded the sharing would be exponential in its depth. A
/// table without sharing yields exactly the edges the recursive walk did.
/// An explicit stack, and no depth guard: every argument's index is greater
/// than its owner's (verified on every load from bytes), so the walk ends.
pub fn termsEdges(
    out: *std.ArrayList(Edge),
    scratch: Allocator,
    dispatch: *const Dispatch,
    roots: []const Dispatch.TermIndex,
    /// Also walk the body of every `derived` row a term names (this
    /// module's rows; another module's run in that module).
    through_rows: bool,
) Error!void {
    if (roots.len == 0) return;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(scratch);
    var stack: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer stack.deinit(scratch);
    var r = roots.len;
    while (r > 0) {
        r -= 1;
        try stack.append(scratch, roots[r]);
    }
    while (stack.pop()) |i| {
        if (i.int() >= dispatch.terms.len) continue;
        if ((try seen.getOrPut(scratch, i.int())).found_existing) continue;
        const t = dispatch.term(i);
        switch (t) {
            .top => |use| try out.append(scratch, .{ .top = use.decl.int() }),
            .ext => |e| try out.append(scratch, .{ .ext = .{
                .module = e.module,
                .value = @intFromEnum(e.value),
            } }),
            .derived => |use| {
                try out.append(scratch, .{ .derived = use.index });
                if (through_rows and use.index < dispatch.derived.len) {
                    const body = dispatch.argsAt(dispatch.derived[use.index].body);
                    var b = body.len;
                    while (b > 0) {
                        b -= 1;
                        try stack.append(scratch, body[b]);
                    }
                }
            },
            .ext_derived => |use| try out.append(scratch, .{ .ext_derived = .{
                .module = use.module,
                .type = use.type,
                .kind = use.kind,
            } }),
            .primitive => |prim| try out.append(scratch, .{ .primitive = prim }),
            .undetermined => try out.append(scratch, .undetermined),
            .param, .field => {},
        }
        const args = dispatch.argsAt(t.argsOf());
        var a = args.len;
        while (a > 0) {
            a -= 1;
            if (args[a].int() <= i.int()) continue;
            try stack.append(scratch, args[a]);
        }
    }
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
    //   leg 3  a site   → callee `derived 0`, whose one argument is `ext`
    //                     module 5 value 6, and a second site whose one root
    //                     is `primitive string_compare`
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
    // one argument hanging off the first callee.
    const terms = [_]Dispatch.Term{
        .{ .derived = .{ .index = 0, .args = .{ .start = 0, .len = 1 } } },
        .{ .ext = .{ .module = @enumFromInt(5), .value = @enumFromInt(6) } },
        .{ .primitive = .string_compare },
        .{ .top = .{ .decl = @enumFromInt(0) } },
    };
    const args = [_]Dispatch.TermIndex{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3) };
    const sites = [_]Dispatch.Site{
        .{ .inst = @enumFromInt(1), .callee = @enumFromInt(0) },
        .{ .inst = @enumFromInt(2), .evidence = .{ .start = 1, .len = 1 } },
        // Declaration 1's site: past `inst_end`, so `sitesIn` must stop.
        .{ .inst = @enumFromInt(3), .evidence = .{ .start = 2, .len = 1 } },
    };
    var dispatch: Dispatch = .empty;
    dispatch.terms = &terms;
    dispatch.args = &args;
    dispatch.sites = &sites;

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
    // Leg 3: the callee, then what it passes, then the next site's root.
    try testing.expectEqual(@as(u32, 0), out.items[3].derived);
    try testing.expectEqual(@as(u32, 5), out.items[4].ext.module.int());
    try testing.expectEqual(@as(u32, 6), out.items[4].ext.value);
    try testing.expectEqual(Dispatch.Primitive.string_compare, out.items[5].primitive);

    // The neighbouring declaration's instruction and site are its own.
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

test "an argument that points back at its owner is not followed" {
    const gpa = testing.allocator;
    // A hand-corrupted table: the term's argument is itself. `Dispatch`
    // builds in pre-order and `dispatch_bytes` refuses such a table on load,
    // so only a hand-built one gets here — and the walk still ends.
    const terms = [_]Dispatch.Term{
        .{ .derived = .{ .index = 0, .args = .{ .start = 0, .len = 1 } } },
    };
    const args = [_]Dispatch.TermIndex{@enumFromInt(0)};
    var dispatch: Dispatch = .empty;
    dispatch.terms = &terms;
    dispatch.args = &args;

    var out: std.ArrayList(Edge) = .empty;
    defer out.deinit(gpa);
    try termEdges(&out, gpa, &dispatch, @enumFromInt(0));
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "a term shared by two owners is walked once" {
    // checker-v2.md §13.1: the checker writes one term per distinct
    // answer of a site, so `( x, [ x ] ) == …` shares `x`'s derived term
    // between the tuple and the list. Term 0 is the tuple's
    // `derived 0`, whose two arguments are term 1 (`derived 1`, `x`'s) and
    // term 2 (`ext`, the list's `eq`), and term 2's one argument is term 1
    // again. The walk yields each term's edge once, in pre-order.
    const gpa = testing.allocator;
    const terms = [_]Dispatch.Term{
        .{ .derived = .{ .index = 0, .args = .{ .start = 0, .len = 2 } } },
        .{ .derived = .{ .index = 1 } },
        .{ .ext = .{ .module = @enumFromInt(2), .value = @enumFromInt(3), .args = .{ .start = 2, .len = 1 } } },
    };
    const args = [_]Dispatch.TermIndex{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(1) };
    var dispatch: Dispatch = .empty;
    dispatch.terms = &terms;
    dispatch.args = &args;

    var out: std.ArrayList(Edge) = .empty;
    defer out.deinit(gpa);
    try termEdges(&out, gpa, &dispatch, @enumFromInt(0));
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].derived);
    try testing.expectEqual(@as(u32, 1), out.items[1].derived);
    try testing.expectEqual(@as(u32, 2), out.items[2].ext.module.int());
}
