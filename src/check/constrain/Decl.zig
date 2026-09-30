//! Constraint generation for declarations and `let` groups (checker-v2.md
//! §6, §6.6; `checker.md` §6.1).
//!
//! **Every annotation has a scheme before anything uses it** (§6.6). A
//! top-level annotation's scheme is P2's; a `let` annotation's is read, at
//! rank `generalized`, when its group is declared, before any body of the
//! group is generated. Every use instantiates that scheme. Only the body is
//! checked against a RIGID reading, made at the frame's own rank with every
//! variable it makes in the frame's pool, so the boundary's
//! generality check (§8.3) can see whether a rigid escaped.
//!
//! **Generation runs in solving order** (§6.2): a `let`'s
//! groups first to last, each group's bindings declared before any is
//! defined, then the body. A `let` pattern's pattern is generated with its
//! binding's declaration, so its variables exist before a sibling is
//! defined, and the group order has an edge to a pattern binding from every
//! binding that names one of its variables.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../../bir/Bir.zig");
const InternPool = @import("../../InternPool.zig");
const TypeStore = @import("../TypeStore.zig");
const Scc = @import("../Scc.zig");
const Types = @import("../Types.zig");
const Context = @import("../Context.zig");
const Tree = @import("Tree.zig");
const Expr = @import("Expr.zig");
const Pattern = @import("Pattern.zig");
const Effects = @import("../Effects.zig");

const Generator = Tree.Generator;
const Constraint = Tree.Constraint;
const Category = Tree.Category;
const Var = Tree.Var;
const Error = Tree.Error;

// ---------------------------------------------------------------------------
// A top-level group
// ---------------------------------------------------------------------------

/// What `group` hands the solver about one member.
pub const Member = struct {
    decl: u32,
    /// The variable the body is checked against — the rigid reading of an
    /// annotation, or the group's own variable — or none for a member with
    /// no body.
    check: Var.Optional,
    /// The rigid reading's variables, for a `type_dispatch` in the body
    /// (static-dispatch-spike.md §4.2).
    rigids: []const Types.Builder.Scoped = &.{},
    /// What `dump --stage=types` prints for an annotated member: a second
    /// reading of the annotation over the rigid reading's variables, which
    /// nothing unifies, so it prints as written even where the rigid
    /// reading's alias names met others and show their expansions
    /// (checker-v2.md §7.1). Made only when the run keeps its tables.
    display: Var.Optional = .none,
};

/// Read `d`'s `where` clause with `b` — the builder its annotation was read
/// with, so a variable a constraint names is the one the annotation
/// introduced (static-dispatch-spike.md §2.4) — and attach each
/// variable's constraints to it: requirements on P2's scheme, givens on a
/// body's rigid reading (checker-v2.md §4.2).
pub fn attachWhere(cx: *const Context, d: Bir.Decl, b: *Types.Builder, decl: u32) Error!void {
    const bir = cx.bir;
    const clause = bir.declWhere(d);
    if (clause.len == 0) return;
    const scratch = cx.scratch;
    const store = cx.store;
    // Every type first: reading one can grow `b.scope`, and the lookup below
    // wants the finished scope.
    const fn_vars = try scratch.alloc(Var, clause.len);
    defer scratch.free(fn_vars);
    for (clause, fn_vars) |wc, *v| v.* = try cx.readAnnotation(b, wc.type_inst, decl);
    const taken = try scratch.alloc(bool, clause.len);
    defer scratch.free(taken);
    @memset(taken, false);
    var built: std.ArrayList(TypeStore.MethodConstraint) = .empty;
    defer built.deinit(scratch);
    for (clause, 0..) |wc, i| {
        if (taken[i]) continue;
        const variable = bir.symbol(wc.variable);
        built.clearRetainingCapacity();
        for (clause[i..], fn_vars[i..], i..) |other, fn_var, j| {
            if (bir.symbol(other.variable) != variable) continue;
            taken[j] = true;
            try built.append(scratch, .{
                .name = bir.symbol(other.method),
                .fn_var = fn_var,
                .region = other.type_inst,
                .origin = .where_clause,
            });
        }
        const target = blk: {
            for (b.scope.items) |scoped| {
                if (scoped.name == variable) break :blk scoped.v;
            }
            // `where_variable_unbound` refused it in lowering.
            continue;
        };
        const set = try store.addConstraints(built.items);
        const root = store.find(target);
        switch (store.content(root)) {
            // Copied and changed in one field.
            inline .flex, .rigid => |flags, tag| {
                var with = flags;
                with.constraints = set.toOptional();
                store.setContent(root, @unionInit(TypeStore.Content, @tagName(tag), with));
            },
            else => {},
        }
    }
}

/// Generate one top-level binding group at `g.rank` (a fresh frame: the
/// generator's pool, binders and annotated lists are the group's). Fills
/// `members[i].check` and returns the group's constraint.
pub fn group(g: *Generator, members: []Member) Error!Constraint {
    const bir = g.cx.bir;
    // Declare first, define second: a mutually recursive group sees itself.
    for (members) |*m| {
        const d = bir.decls[m.decl];
        g.decl = @enumFromInt(m.decl);
        g.locals_base = d.locals_start;
        m.check = .none;
        if (d.kind == .schema) {
            const factory = g.cx.schemas.member(m.decl, .schema) orelse continue;
            m.check = factory.toOptional();
            g.decl_scheme[m.decl] = factory.toOptional();
            continue;
        }
        if (!d.kind.isValue() or d.body == .none) continue;
        if (d.annotation.unwrap()) |annotation| {
            const scheme = g.decl_scheme[m.decl].unwrap() orelse continue;
            const reading = try rigidReading(g, annotation, scheme, bir.symbol(d.name).toOptional(), d);
            m.check = reading.check.toOptional();
            m.rigids = reading.rigids;
            if (g.cx.keep_display) m.display = (try displayReading(g, annotation, reading.rigids)).toOptional();
            // The dump's reading is one class with the scheme too
            // (§14.3 rule 5; `rigidReading` pairs the body's).
            if (g.cx.effects) |e| {
                if (m.display.unwrap()) |display| try e.zip(scheme, display);
            }
        } else {
            const v = try g.freshFlex();
            m.check = v.toOptional();
            g.decl_scheme[m.decl] = v.toOptional();
        }
        // The top-level header is a binder (§6.3), reported at the body.
        _ = try g.header(m.check.unwrap().?, d.body.unwrap().?, bir.symbol(d.name).toOptional());
    }
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    for (members) |m| {
        const check = m.check.unwrap() orelse continue;
        const d = bir.decls[m.decl];
        g.decl = @enumFromInt(m.decl);
        g.locals_base = d.locals_start;
        g.decl_rigids = m.rigids;
        defer g.decl_rigids = &.{};
        try parts.append(g.cx.scratch, try g.add(.member, @enumFromInt(0), m.decl, 0, .{}));
        try parts.append(g.cx.scratch, if (d.kind == .schema)
            try schemaDecl(g, m.decl)
        else
            try declBody(g, d, check));
    }
    return g.conj(parts.items);
}

/// Read `annotation` as rigid variables at the frame's rank, pool them, and
/// record the binding for the generality check (§8.3). For a top-level
/// declaration (`top`), its `where` clause is read into the rigids too — the
/// givens its body is checked with (§4.2) — and the rigids are returned for
/// a `type_dispatch` to name.
const Reading = struct { check: Var, rigids: []const Types.Builder.Scoped };

fn rigidReading(g: *Generator, annotation: Bir.Inst.Index, scheme: Var, name: Tree.Symbol.Optional, top: ?Bir.Decl) Error!Reading {
    const mark = g.storeMark();
    var b = g.cx.builder(.rigid, g.rank);
    defer b.deinit();
    const check = try g.cx.readAnnotation(&b, annotation, @intFromEnum(g.decl));
    if (top) |d| try attachWhere(g.cx, d, &b, @intFromEnum(g.decl));
    // The annotation promises no bits: this reading and the scheme are one
    // class position by position (transparent-effects-proposal.md §14.3
    // rule 5); a `let`'s, whose scheme was read just before, is zipped.
    if (g.cx.effects) |e| {
        if (top != null) try e.checkReading(@intFromEnum(g.decl), mark, g.storeMark(), scheme, check) else try e.zip(scheme, check);
    }
    try g.adoptSince(mark);
    const rigids_start: u32 = @intCast(g.tree.extra.items.len);
    for (b.scope.items) |scoped| try g.tree.extra.append(g.gpa, @intFromEnum(scoped.v));
    try g.frame_annotated.append(g.gpa, @intCast(g.tree.annotated.items.len));
    try g.tree.annotated.append(g.gpa, .{
        .scheme = scheme,
        .rigids_start = rigids_start,
        .rigids_len = @intCast(b.scope.items.len),
        .annotation = annotation,
        .name = name,
        .decl = @intFromEnum(g.decl),
        .let = top == null,
    });
    if (top) |d| {
        if (d.where_start != d.where_end) try g.evidence.registerGivens(g.gpa, g.cx.store, g.cx.interner, g.cx.scratch, check, @intFromEnum(g.decl));
    }
    return .{ .check = check, .rigids = if (top != null) try g.cx.scratch.dupe(Types.Builder.Scoped, b.scope.items) else &.{} };
}

/// `annotation` read again over `rigids`, the rigid reading's variables, for
/// `dump --stage=types` (`Member.display`): the same tree over the same
/// variables, so the locals the dump prints beside it name them alike, and
/// no unification ever reaches it. Pooled like the rigid reading.
fn displayReading(g: *Generator, annotation: Bir.Inst.Index, rigids: []const Types.Builder.Scoped) Error!Var {
    const mark = g.storeMark();
    var b = g.cx.builder(.rigid, g.rank);
    defer b.deinit();
    for (rigids) |scoped| try b.bind(scoped.name, scoped.v);
    const v = try b.read(annotation);
    try g.adoptSince(mark);
    return v;
}

/// The body of a value declaration, checked against `target`. Its parameters
/// are binders of the group's frame, occurs-checked at its boundary — which
/// follows the body directly, so a `binders_end` of their own would only
/// walk the same types twice (checker-v2.md §18).
fn declBody(g: *Generator, d: Bir.Decl, target: Var) Error!Constraint {
    const bir = g.cx.bir;
    const body = d.body.unwrap() orelse return g.true_();
    const params = bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index);
    const annotated = d.annotation != .none;
    const category: Category = .{ .tag = if (annotated) .annotation else .general };
    // What a call in the body joins (transparent-effects-proposal.md §14.3
    // rule 1): the declaration's own arrow, or, for a value with no
    // parameters, its evaluation class.
    const outer = g.ambient;
    const outer_site = g.ambient_site;
    g.ambient_site = Effects.none;
    defer {
        g.ambient = outer;
        g.ambient_site = outer_site;
    }
    if (params.len == 0) {
        g.ambient = if (g.cx.effects) |e| try e.evalNode(@intFromEnum(g.decl)) else null;
        // `main` is evaluated once, when the program starts, outside any
        // fiber: its evaluation is a `sync` boundary
        // (transparent-effects-proposal.md §15.2 item 5), for the `main` of
        // a module of the root package, where a build looks for it.
        if (g.cx.effects) |e| if (bir.symbol(d.name) == InternPool.WellKnown.main.symbol() and g.cx.graph.modulePackage(g.cx.module) == .app) {
            try e.demand(.{ .v = g.ambient.?, .kind = .main, .site = @intFromEnum(d.inst_start), .decl = @intFromEnum(g.decl) });
        };
        return Expr.expr(g, body, target, category);
    }
    const param_vars = try g.cx.scratch.alloc(Var, params.len);
    defer g.cx.scratch.free(param_vars);
    for (param_vars) |*v| v.* = try g.freshFlex();
    const result = try g.freshFlex();
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    const arrow = try g.func(param_vars, result);
    g.ambient = arrow;
    try parts.append(g.cx.scratch, try g.equal(target, arrow, body, category));
    for (params, param_vars) |p, v| try parts.append(g.cx.scratch, try Pattern.pattern(g, p, v));
    // A `?` in the body that names no `let` definition returns from here.
    g.decl_result = result;
    defer g.decl_result = null;
    try parts.append(g.cx.scratch, try Expr.expr(g, body, result, category));
    return g.conj(parts.items);
}

/// A schema declaration's `via` conversions, each checked against the
/// endpoint type `Schema.State` expects.
fn schemaDecl(g: *Generator, index: u32) Error!Constraint {
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    for (g.cx.schemas.vias.items) |via| {
        if (via.owner.int() != index) continue;
        try parts.append(g.cx.scratch, try Expr.expr(g, via.expr, via.expected, .{ .tag = .schema_conversion, .index = @intFromEnum(via.field) }));
    }
    return g.conj(parts.items);
}

// ---------------------------------------------------------------------------
// `let`
// ---------------------------------------------------------------------------

/// One `let` group generated but not yet nested.
const Pending = struct {
    first: Bir.Inst.Index,
    payload: Tree.Let,
};

pub fn letExpr(g: *Generator, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
    const bir = g.cx.bir;
    const defs = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index);
    const groups = try sccOfLet(g, defs);
    defer g.cx.scratch.free(groups.order);
    defer g.cx.scratch.free(groups.starts);

    const count = groups.starts.len - 1;
    const pending = try g.cx.scratch.alloc(Pending, count);
    defer g.cx.scratch.free(pending);
    for (pending, 0..) |*p, i| {
        const members = groups.order[groups.starts[i]..groups.starts[i + 1]];
        p.* = .{ .first = members[0], .payload = try bindingGroup(g, members) };
    }
    const body = try Expr.expr(g, @enumFromInt(data.rhs), expected, category);
    // Nest from the last group out, in a loop: the first group is the
    // outermost `let`, generalised first.
    var inner = body;
    var i = count;
    while (i > 0) {
        i -= 1;
        var payload = pending[i].payload;
        payload.body_con = inner;
        const at = try g.addExtra(payload);
        inner = try g.add(.let_, pending[i].first, at, 0, .{});
    }
    return inner;
}

/// One `let` group's header, in a frame of its own one rank in. Its pool,
/// binders and annotated bindings are pushed above the enclosing frame's on
/// the generator's lists, copied into the tree, and popped.
fn bindingGroup(g: *Generator, members: []const Bir.Inst.Index) Error!Tree.Let {
    const outer_rank = g.rank;
    const pool_base = g.pool.items.len;
    const binders_base = g.frame_binders.items.len;
    const annotated_base = g.frame_annotated.items.len;
    g.rank = outer_rank + 1;
    defer {
        g.pool.shrinkRetainingCapacity(pool_base);
        g.frame_binders.shrinkRetainingCapacity(binders_base);
        g.frame_annotated.shrinkRetainingCapacity(annotated_base);
        g.rank = outer_rank;
    }

    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    const checks = try g.cx.scratch.alloc(Var, members.len);
    defer g.cx.scratch.free(checks);
    for (members, checks) |m, *cv| cv.* = try declareBinding(g, m, &parts);
    for (members, checks) |m, cv| try parts.append(g.cx.scratch, try defineBinding(g, m, cv));
    const header_con = try g.conj(parts.items);

    const pool = g.pool.items[pool_base..];
    const binders = g.frame_binders.items[binders_base..];
    const annotated = g.frame_annotated.items[annotated_base..];
    const vars_start: u32 = @intCast(g.tree.extra.items.len);
    try g.tree.extra.appendSlice(g.gpa, @ptrCast(pool));
    const binders_start: u32 = @intCast(g.tree.extra.items.len);
    try g.tree.extra.appendSlice(g.gpa, binders);
    const annotated_start: u32 = @intCast(g.tree.extra.items.len);
    try g.tree.extra.appendSlice(g.gpa, annotated);
    return .{
        .rank = outer_rank + 1,
        .vars_start = vars_start,
        .vars_len = @intCast(pool.len),
        .binders_start = binders_start,
        .binders_len = @intCast(binders.len),
        .annotated_start = annotated_start,
        .annotated_len = @intCast(annotated.len),
        .header_con = header_con,
        .body_con = .none,
    };
}

/// Give a binding its variable before any body of the group is generated,
/// and return the variable its BODY is checked against. A `let` pattern's
/// pattern is generated here, into `parts` (§6.2).
fn declareBinding(g: *Generator, m: Bir.Inst.Index, parts: *std.ArrayList(Constraint)) Error!Var {
    const bir = g.cx.bir;
    const data = bir.instData(m);
    switch (bir.instTag(m)) {
        .let_def => {
            const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
            const name = g.nameOfLocal(def.local);
            if (def.annotation.unwrap()) |a| {
                var scheme_builder = g.cx.builder(.flex, TypeStore.generalized);
                defer scheme_builder.deinit();
                const scheme = try g.cx.readAnnotation(&scheme_builder, a, @intFromEnum(g.decl));
                const check = (try rigidReading(g, a, scheme, name, null)).check;
                // An Elm curried annotation: its uses are not held to it
                // (checker.md §8.7), as at the top level.
                if (g.cx.store.isCurried(scheme, @intCast(bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index).len))) {
                    g.setLocal(def.local, try g.cx.store.freshErr(TypeStore.generalized));
                } else {
                    g.setLocal(def.local, scheme);
                }
                _ = try g.header(check, m, name);
                return check;
            }
            const v = try g.freshFlex();
            g.setLocal(def.local, v);
            _ = try g.header(v, m, name);
            return v;
        },
        .let_pattern => {
            const v = try g.freshFlex();
            _ = try g.header(v, m, .none);
            try parts.append(g.cx.scratch, try Pattern.patternAgainst(g, @enumFromInt(data.lhs), v));
            return v;
        },
        else => return g.freshFlex(),
    }
}

fn defineBinding(g: *Generator, m: Bir.Inst.Index, check: Var) Error!Constraint {
    const bir = g.cx.bir;
    const data = bir.instData(m);
    switch (bir.instTag(m)) {
        .let_def => {
            const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
            const category: Category = .{ .tag = if (def.annotation == .none) .general else .let_annotation };
            const params = bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index);
            if (params.len == 0) return Expr.expr(g, @enumFromInt(data.rhs), check, category);
            const param_vars = try g.cx.scratch.alloc(Var, params.len);
            defer g.cx.scratch.free(param_vars);
            for (param_vars) |*v| v.* = try g.freshFlex();
            const result = try g.freshFlex();
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            const arrow = try g.func(param_vars, result);
            try parts.append(g.cx.scratch, try g.equal(check, arrow, m, category));
            for (params, param_vars) |p, v| try parts.append(g.cx.scratch, try Pattern.pattern(g, p, v));
            // The body's calls join this definition's own arrow (§14.3 rule 1).
            const outer = g.ambient;
            const outer_site = g.ambient_site;
            g.ambient = arrow;
            g.ambient_site = @intFromEnum(m);
            defer {
                g.ambient = outer;
                g.ambient_site = outer_site;
            }
            // A `?` in the body returns from this definition (§8.6).
            try g.targets.append(g.gpa, .{ .inst = m, .result = result });
            defer _ = g.targets.pop();
            try parts.append(g.cx.scratch, try Expr.expr(g, @enumFromInt(data.rhs), result, category));
            return g.conj(parts.items);
        },
        .let_pattern => return Expr.expr(g, @enumFromInt(data.rhs), check, .{ .tag = .destructure }),
        else => return g.true_(),
    }
}

// ---------------------------------------------------------------------------
// The `let` SCC (§4.4, §6.2)
// ---------------------------------------------------------------------------

const Groups = struct { order: []Bir.Inst.Index, starts: []u32 };

/// A `let`'s bindings in minimal mutually recursive groups, dependencies
/// first. An edge runs from a binding to the one that binds a local it
/// names: a `let_def` binds its own local, a pattern binds every variable
/// in it. An annotated `let_def` is never a target — its scheme is its
/// annotation. The Tarjan pass is `Scc.zig`'s.
fn sccOfLet(g: *Generator, defs: []const Bir.Inst.Index) Error!Groups {
    const scratch = g.cx.scratch;
    const bir = g.cx.bir;
    const n = defs.len;
    const none = std.math.maxInt(u32);
    // Local (relative) → the binding that binds it, over this declaration's
    // locals. Filled once per `let`; a local belongs to one binding.
    const d = bir.decls[@intFromEnum(g.decl)];
    const local_count = d.locals_end - d.locals_start;
    const bound_by = try scratch.alloc(u32, local_count);
    defer scratch.free(bound_by);
    @memset(bound_by, none);
    var locals: std.ArrayList(u32) = .empty;
    defer locals.deinit(scratch);
    for (defs, 0..) |def_inst, i| {
        const data = bir.instData(def_inst);
        switch (bir.instTag(def_inst)) {
            .let_def => {
                const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
                if (def.annotation != .none) continue;
                if (def.local < local_count) bound_by[def.local] = @intCast(i);
            },
            .let_pattern => {
                locals.clearRetainingCapacity();
                try patternLocals(g, @enumFromInt(data.lhs), &locals);
                for (locals.items) |l| {
                    if (l < local_count) bound_by[l] = @intCast(i);
                }
            },
            else => {},
        }
    }

    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(scratch);
    const edge_start = try scratch.alloc(u32, n + 1);
    defer scratch.free(edge_start);
    // Per binding, the last source that added an edge to it: deduplication
    // without a scan.
    const edge_mark = try scratch.alloc(u32, n);
    defer scratch.free(edge_mark);
    @memset(edge_mark, none);
    var referenced: std.ArrayList(u32) = .empty;
    defer referenced.deinit(scratch);
    for (defs, 0..) |def_inst, i| {
        edge_start[i] = @intCast(edges.items.len);
        referenced.clearRetainingCapacity();
        try collectLocalRefs(g, @enumFromInt(bir.instData(def_inst).rhs), &referenced);
        for (referenced.items) |local| {
            if (local >= local_count) continue;
            const j = bound_by[local];
            if (j == none or j == i or edge_mark[j] == i) continue;
            edge_mark[j] = @intCast(i);
            try edges.append(scratch, j);
        }
    }
    edge_start[n] = @intCast(edges.items.len);

    const groups = try Scc.sccGroups(scratch, n, edges.items, edge_start);
    const order = try scratch.alloc(Bir.Inst.Index, n);
    for (groups.order, order) |i, *o| o.* = defs[i];
    scratch.free(groups.order);
    return .{ .order = order, .starts = groups.starts };
}

/// Every local a pattern binds (relative indices).
fn patternLocals(g: *Generator, root: Bir.Inst.Index, out: *std.ArrayList(u32)) Error!void {
    const bir = g.cx.bir;
    const scratch = g.cx.scratch;
    var stack: std.ArrayList(Bir.Inst.Index) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, root);
    while (stack.pop()) |inst| {
        const data = bir.instData(inst);
        switch (bir.instTag(inst)) {
            .pat_var => try out.append(scratch, data.lhs),
            .pat_as => {
                try out.append(scratch, data.rhs);
                try stack.append(scratch, @enumFromInt(data.lhs));
            },
            .pat_record => try out.appendSlice(scratch, bir.extraSlice(Bir.inlineRange(data), u32)),
            .pat_tuple, .pat_list => try stack.appendSlice(scratch, bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)),
            .pat_cons => {
                try stack.append(scratch, @enumFromInt(data.lhs));
                try stack.append(scratch, @enumFromInt(data.rhs));
            },
            .pat_ctor => try stack.appendSlice(scratch, bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index)),
            else => {},
        }
    }
}

/// Every local a subtree references, with repeats: the caller deduplicates
/// the EDGES (`edge_mark`), so a scan here would only make it quadratic.
/// Iterative: an expression may be 4096 levels deep.
fn collectLocalRefs(g: *Generator, root: Bir.Inst.Index, out: *std.ArrayList(u32)) Error!void {
    const bir = g.cx.bir;
    const scratch = g.cx.scratch;
    var stack: std.ArrayList(Bir.Inst.Index) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, root);
    while (stack.pop()) |inst| {
        if (bir.instTag(inst) == .local) {
            const index = bir.instData(inst).lhs;
            try out.append(scratch, index);
            continue;
        }
        try pushChildren(bir, scratch, inst, &stack);
    }
}

/// Push every operand instruction of `inst`: one exhaustive switch, so a new
/// Bir form is a compile error here and not a silent missed edge.
pub fn pushChildren(bir: *const Bir, scratch: Allocator, inst: Bir.Inst.Index, stack: *std.ArrayList(Bir.Inst.Index)) Error!void {
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .interp, .tuple, .list, .pat_tuple, .pat_list, .type_tuple => {
            try stack.appendSlice(scratch, bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index));
        },
        .record, .type_record => {
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| try stack.append(scratch, f.value);
        },
        .record_update, .type_record_ext => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            for (bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field)) |f| try stack.append(scratch, f.value);
        },
        .field_access, .tuple_index, .@"try" => try stack.append(scratch, @enumFromInt(data.lhs)),
        .method_call => {
            const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index));
        },
        .type_dispatch => {
            const t = bir.extraData(@enumFromInt(data.rhs), Bir.TypeDispatch);
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Bir.Inst.Index));
        },
        .call, .pat_ctor, .case, .type_app => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.appendSlice(scratch, bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index));
        },
        .lambda, .let => {
            try stack.appendSlice(scratch, bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index));
            try stack.append(scratch, @enumFromInt(data.rhs));
        },
        .let_def => {
            const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index));
            try stack.append(scratch, @enumFromInt(data.rhs));
        },
        .let_pattern, .branch, .pat_cons, .type_fn => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.append(scratch, @enumFromInt(data.rhs));
        },
        .pat_as => try stack.append(scratch, @enumFromInt(data.lhs)),
        .markup => try bir.markupValues(scratch, @enumFromInt(data.lhs), stack),
        .schema_app, .schema_value, .schema_tagged => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.appendSlice(scratch, bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index));
        },
        .schema_paren, .schema_as, .schema_via => try stack.append(scratch, @enumFromInt(data.lhs)),
        .schema_record => try stack.appendSlice(scratch, bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)),
        .schema_field => {
            const field = bir.extraData(@enumFromInt(data.rhs), Bir.SchemaField);
            try stack.append(scratch, field.operand);
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = field.modifiers_start, .end = field.modifiers_end }, Bir.Inst.Index));
        },
        .schema_variant => {
            const variant = bir.extraData(@enumFromInt(data.rhs), Bir.SchemaVariant);
            if (variant.payload.unwrap()) |p| try stack.append(scratch, p);
            if (variant.rename.unwrap()) |r| try stack.append(scratch, r);
        },
        .local,
        .top,
        .ctor,
        .import_value,
        .import_ctor,
        .qualified,
        .qualified_ctor,
        .ext_value,
        .ext_ctor,
        .type_var,
        .type_top,
        .type_import,
        .type_qualified,
        .ext_type,
        .type_unit,
        .int,
        .float,
        .char,
        .string,
        .chunk,
        .unit,
        .pat_wild,
        .pat_var,
        .pat_int,
        .pat_char,
        .pat_string,
        .pat_unit,
        .pat_record,
        .schema_ref,
        .schema_optional,
        .schema_nullable,
        .schema_expr_ref,
        .schema_type_ref,
        .schema_value_ref,
        .schema_ctor_ref,
        .schema_member_top,
        .ext_schema_member,
        .schema_ctor_top,
        .ext_schema_ctor,
        .schema_type_top,
        .ext_schema_type,
        .schema_parameter,
        .schema_primitive,
        .schema_target_top,
        .ext_schema_target,
        .@"error",
        => {},
    }
}
