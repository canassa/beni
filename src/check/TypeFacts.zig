//! What a declared type's body holds, settled once per session for every
//! type by `Types.build` (the header of `Types.zig`): `Entry.equatable`,
//! `comparable`, `has_function` and `holds_markup`, one fixpoint over one
//! set of edges. Split out of `Types.zig` by §19.1's 1 500-line rule.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Types = @import("Types.zig");

const TypeId = Types.TypeId;
const Symbol = InternPool.Symbol;

/// Shrink the optimistic "everything is equatable" assumption to a fixpoint
/// (see the header). A `foreign type` is fixed by its declaration and never
/// moves; everything else is false as soon as a function is reachable in
/// its body.
///
/// **One pass, then a worklist.** The property only ever goes true → false,
/// so it needs no re-scanning: walk each body ONCE, recording whether it
/// mentions a function and which other types it names, then propagate
/// `false` backwards along those edges. The re-scanning version this
/// replaced was O(types² × body size) whenever the dependency chain ran
/// against declaration order — 250 aliases took 38 ms and 2 000 took
/// 1 353 ms, a clean 4× per doubling — and it is serial, before the DAG,
/// so it was on the critical path of every build.
pub fn settle(
    types: *Types,
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
) Allocator.Error!void {
    const n = types.entries.len;
    if (n == 0) return;

    // Edges `dependency → dependent`, flattened: `deps` is collected per
    // entry first, then counting-sorted into one array with per-dependency
    // offsets. No map, no per-node allocation.
    var edge_from: std.ArrayList(u32) = .empty;
    defer edge_from.deinit(gpa);
    var edge_to: std.ArrayList(u32) = .empty;
    defer edge_to.deinit(gpa);
    var deps: std.ArrayList(TypeId) = .empty;
    defer deps.deinit(gpa);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    // `comparable` is the SAME fixpoint over the SAME edges, so it rides
    // along: one body walk, two properties, two queues (A.54).
    var order_queue: std.ArrayList(u32) = .empty;
    defer order_queue.deinit(gpa);
    // And `has_function` is the same fixpoint run the other way up (A.58):
    // it starts FALSE and spreads TRUE along the same edges, because a type
    // holds a function exactly when one of the types it holds does. It is
    // what lets §10.3 tell "there is a function inside it" from "something
    // it holds has no ordering", which the two folded gates above cannot.
    var function_queue: std.ArrayList(u32) = .empty;
    defer function_queue.deinit(gpa);
    // And `holds_markup` the same way again, seeded at the build's markup
    // type rather than at a function.
    var markup_queue: std.ArrayList(u32) = .empty;
    defer markup_queue.deinit(gpa);
    if (graph.markup.type_module.unwrap()) |markup_module| if (graph.markup.type_name.unwrap()) |markup_name| {
        for (types.entries, 0..) |*e, i| {
            if (e.schema_endpoint or e.module_name != markup_module or e.name != markup_name) continue;
            e.holds_markup = true;
            try markup_queue.append(gpa, @intCast(i));
        }
    };

    var walk: BodyWalk = .{ .gpa = gpa, .graph = graph, .artifacts = artifacts };
    defer walk.deinit();

    for (types.entries, 0..) |*e, i| {
        if (e.schema_endpoint) continue;
        const bir = artifacts.bir(graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        if (e.kind == .foreign) {
            // Declared, never computed (checker.md Appendix B).
            e.equatable = d.is_equatable;
            if (!e.equatable) try queue.append(gpa, @intCast(i));
            // A `foreign type` has no body to derive `compare` over, so it
            // answers `<` only through §3.2's table or through a `pub
            // compare` of its own module (A.50). A `foreign type` with
            // neither makes `xs < ys` an honest `unknown_method`.
            e.comparable = inWellKnownTable(types, @enumFromInt(i)) or
                declaresPubCompare(types, e.module, bir, @enumFromInt(i));
            if (!e.comparable) try order_queue.append(gpa, @intCast(i));
            continue;
        }
        deps.clearRetainingCapacity();
        var has_function = false;
        switch (e.kind) {
            .alias => if (d.annotation.unwrap()) |body| {
                has_function = try walk.run(types, e.module, bir, body, &deps);
            },
            .adt => for (bir.declCtors(d)) |c| {
                for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| {
                    if (try walk.run(types, e.module, bir, arg, &deps)) has_function = true;
                }
            },
            .foreign => unreachable, // handled above
        }
        if (has_function) {
            e.equatable = false;
            e.comparable = false;
            e.has_function = true;
            try queue.append(gpa, @intCast(i));
            try order_queue.append(gpa, @intCast(i));
            try function_queue.append(gpa, @intCast(i));
            // A type already false needs no incoming edges for `equatable`
            // or `comparable`: nothing can make it false a second time. It
            // still needs its OUTGOING edges, because `has_function` runs
            // the other way — this type is how a function reaches the ones
            // that hold it.
        }
        for (deps.items) |dep| {
            if (dep == .none or dep.int() >= n) continue;
            try edge_from.append(gpa, dep.int());
            try edge_to.append(gpa, @intCast(i));
        }
    }

    // Counting sort the edges by their source, so propagation is one scan
    // of a contiguous range per popped type.
    const starts = try gpa.alloc(u32, n + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (edge_from.items) |from| starts[from + 1] += 1;
    for (1..n + 1) |i| starts[i] += starts[i - 1];
    const dependents = try gpa.alloc(u32, edge_to.items.len);
    defer gpa.free(dependents);
    const cursor = try gpa.alloc(u32, n);
    defer gpa.free(cursor);
    @memcpy(cursor, starts[0..n]);
    for (edge_from.items, edge_to.items) |from, to| {
        dependents[cursor[from]] = to;
        cursor[from] += 1;
    }

    // Propagate. Each type is pushed at most once — it is pushed only on
    // the transition true → false — so this is O(types + edges).
    while (queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (!types.entries[dependent].equatable) continue;
            types.entries[dependent].equatable = false;
            try queue.append(gpa, dependent);
        }
    }
    while (order_queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (!types.entries[dependent].comparable) continue;
            types.entries[dependent].comparable = false;
            try order_queue.append(gpa, dependent);
        }
    }
    while (function_queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (types.entries[dependent].has_function) continue;
            types.entries[dependent].has_function = true;
            try function_queue.append(gpa, dependent);
        }
    }
    while (markup_queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (types.entries[dependent].holds_markup) continue;
            types.entries[dependent].holds_markup = true;
            try markup_queue.append(gpa, dependent);
        }
    }
}

/// Whether §3.2's table answers `eq` and `compare` for `id`. The five types
/// that stay in `core/Basics.beni` plus `String` and `Char`: the table
/// exists precisely because the module rule cannot serve them, so the
/// fixpoint must not ask it to either.
fn inWellKnownTable(types: *const Types, id: TypeId) bool {
    const wk = types.well_known;
    return id != .none and (id == wk.int or id == wk.float or id == wk.char or
        id == wk.string or id == wk.bool or id == wk.order or id == wk.never);
}

/// Whether the module that declares the `foreign type` `id` supplies the
/// `pub compare` that A.50 says is the only way to order one — asked of the
/// module rule exactly as a USE would ask it (§1.2).
///
/// Two halves, and the property needs both. **`pub`**, because this answer
/// is one bit on a session-wide table read from every module, and a private
/// `compare` is invisible to all but one of them: a gate that said yes
/// would make `type Wraps = Wraps Handle` derive a `compare` whose one part
/// is `err` everywhere else. **The first parameter**, because a module's
/// `pub` values are one namespace (§11) — `pub compare : Tag, Tag -> Order`
/// beside an unrelated `pub foreign type Handle` is `Tag`'s method and not
/// `Handle`'s, and taking it for `Handle`'s emitted a call to it with a
/// `Handle` in hand.
fn declaresPubCompare(types: *const Types, module: Graph.Index, bir: *const Bir, id: TypeId) bool {
    return declaresPubMethod(types, module, bir, id, InternPool.WellKnown.compare.symbol());
}

fn declaresPubMethod(types: *const Types, module: Graph.Index, bir: *const Bir, id: TypeId, method_name: Symbol) bool {
    for (bir.decls) |d| {
        if (!d.kind.isValue() or !d.is_pub) continue;
        if (bir.symbol(d.name) != method_name) continue;
        const annotation = d.annotation.unwrap() orelse continue;
        if (bir.instTag(annotation) != .type_fn) continue;
        const params = bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(annotation).lhs)), Bir.Inst.Index);
        if (params.len == 0) continue;
        if (writtenHead(types, module, bir, params[0]) == id) return true;
    }
    return false;
}

/// The `TypeId` a written type's HEAD names: `Handle`, `List a` and a bare
/// `Handle` alike. `.none` for anything else — a variable, a tuple, a
/// record, a function.
fn writtenHead(types: *const Types, module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index) TypeId {
    const tag = bir.instTag(inst);
    if (tag == .type_app) {
        const head: Bir.Inst.Index = @enumFromInt(bir.instData(inst).lhs);
        return types.headId(module, bir.instTag(head), bir.instData(head));
    }
    return types.headId(module, tag, bir.instData(inst));
}

/// Walks a written type once: does it mention a function, and which other
/// declared types does it name? The two questions together are what
/// `settle` needs, and asking them in one walk is what turns its
/// fixpoint into a worklist.
///
/// Type PARAMETERS are not consulted — `List a` is equatable exactly when
/// `a` is, and the argument is checked at the use site by the obligation
/// walk of checker.md §6.4.
const BodyWalk = struct {
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
    /// Reused across every body of the session; an annotation is as deep as
    /// the parser's nesting limit allows (4096), which does not belong on
    /// the C stack.
    stack: std.ArrayList(Frame) = .empty,

    const Frame = struct { module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index };

    fn deinit(w: *BodyWalk) void {
        w.stack.deinit(w.gpa);
    }

    /// True when a function is reachable. Every named type met on the way
    /// is appended to `out`, whether or not it is equatable today: the
    /// caller turns them into edges and propagates along them.
    ///
    /// The walk grows its worklist instead of truncating at a fixed size.
    /// A fixed one would have to answer "equatable" for a type too wide to
    /// finish, which is a silent yes to `==` on a function — the failure
    /// mode this whole milestone is about.
    fn run(
        w: *BodyWalk,
        types: *const Types,
        module: Graph.Index,
        bir: *const Bir,
        root: Bir.Inst.Index,
        out: *std.ArrayList(TypeId),
    ) Allocator.Error!bool {
        w.stack.clearRetainingCapacity();
        try w.stack.append(w.gpa, .{ .module = module, .bir = bir, .inst = root });
        // A well-formed Bir type is a TREE, so this terminates in the size
        // of the body; the budget only exists so a poisoned one cannot spin
        // forever, and it is stated in terms of the input rather than as a
        // constant so it cannot become the real limit.
        var budget: usize = @as(usize, bir.insts.len) + 16;
        while (w.stack.pop()) |frame| {
            if (budget == 0) return true; // see above: not a limit, a backstop
            budget -= 1;
            const b = frame.bir;
            const tag = b.instTag(frame.inst);
            const data = b.instData(frame.inst);
            switch (tag) {
                .type_fn => return true,
                .type_var, .type_unit, .@"error" => {},
                .type_top, .ext_type, .schema_type_top, .ext_schema_type => try out.append(w.gpa, types.headId(frame.module, tag, data)),
                .type_app => {
                    const head_tag = b.instTag(@enumFromInt(data.lhs));
                    const head_data = b.instData(@enumFromInt(data.lhs));
                    try out.append(w.gpa, types.headId(frame.module, head_tag, head_data));
                    for (b.extraSlice(b.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index)) |arg| {
                        try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = arg });
                    }
                },
                .type_tuple => for (b.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |el| {
                    try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = el });
                },
                .type_record => for (b.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| {
                    try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = f.value });
                },
                .type_record_ext => for (b.extraSlice(b.subRange(@enumFromInt(data.rhs)), Bir.Field)) |f| {
                    try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = f.value });
                },
                else => {},
            }
        }
        return false;
    }
};
