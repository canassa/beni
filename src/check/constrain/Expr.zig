//! Constraint generation for expressions (checker-v2.md §6; `checker.md`
//! §6.1's per-form rules).
//!
//! **Expected types are pushed down**, as in Elm: a sub-expression is handed
//! the variable its context already knows about, which is what lets §8.3's
//! arity messages see what a call's result was wanted for.
//!
//! What differs from Elm's generator:
//!
//!   - a `.local` or `.top` reference is resolved to its variable here
//!     (§6.2: the solver reads no generation-time context), and every
//!     other reference is left to the solver as a
//!     `reference` node read from the Bir or an interface;
//!   - a lambda's parameters and a `case` branch's pattern variables are
//!     binders, occurs-checked by a `binders_end` node when the lambda or
//!     branch ends (§6.3);
//!   - the obligation forms (`e.i`, `${…}`, `e?`) emit a node the solver
//!     decides at once or turns into an obligation riding on its variables
//!     (§4.5, §8.6); a record literal's fields and its meeting with the
//!     expectation are one node, whose order the solver chooses (§6.5);
//!   - a method call, an operator comparison and a `type_dispatch` emit a
//!     `method` node between the receiver's constraints and the arguments'
//!     (Rule U0), whose wanted the resolver answers (§9); an operator
//!     section's lambda is typed `a, a -> Bool` before its body (for the
//!     message), but a saturated section is an ordinary call of the lambda,
//!     with no call shim (§6.4);
//!   - a form with no rule here is `internal`, never a silent poison.

const std = @import("std");
const Bir = @import("../../bir/Bir.zig");
const TypeStore = @import("../TypeStore.zig");
const Tree = @import("Tree.zig");
const Pattern = @import("Pattern.zig");
const Decl = @import("Decl.zig");
const Markup = @import("Markup.zig");
const Walk = @import("../Walk.zig");
const Evidence = @import("../Evidence.zig");
const InternPool = @import("../../InternPool.zig");

const Generator = Tree.Generator;
const Constraint = Tree.Constraint;
const Category = Tree.Category;
const Var = Tree.Var;
const Error = Tree.Error;

/// Constrain `inst` to have type `expected`.
pub fn expr(g: *Generator, inst: Bir.Inst.Index, expected: Var, category: Category) Error!Constraint {
    g.depth += 1;
    defer g.depth -= 1;
    // Reachable from a file the parser accepted only through markup's holes
    // (`Generator.depth`); noted, never silent. What was not read is
    // poisoned, so nothing that meets it says a second thing about it.
    if (g.depth > Generator.max_depth) {
        try g.cx.noteTooDeepAs(inst, @intFromEnum(g.decl), if (g.markup_roots != 0) .markup else .type);
        return g.equal(expected, try g.fresh(.err), inst, category);
    }

    const bir = g.cx.bir;
    const wk = g.cx.types.well_known;
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        // A literal integer is `number` (`fast-compiler.md` §3.1).
        .int => return g.equal(expected, try g.freshKind(.number), inst, category),
        .float => return g.equal(expected, try g.primitive(wk.float), inst, category),
        .char => return g.equal(expected, try g.primitive(wk.char), inst, category),
        .string, .chunk => return g.equal(expected, try g.primitive(wk.string), inst, category),
        .unit => return g.equal(expected, try g.fresh(.{ .structure = .unit }), inst, category),

        // Resolved here, never by the solver: the binder's variable
        // was made before this reference was generated (§6.2).
        .local => {
            const v = g.localVar(data.lhs) orelse return g.equal(expected, try g.fresh(.err), inst, category);
            return g.instantiate(expected, v, inst, category);
        },
        .top => {
            // A group checked out of SCC order (nested, §10.2) may name one
            // that is not `done`: the solver demands it at this node.
            if (g.demands(data.lhs)) return g.add(.demand, inst, @intFromEnum(expected), data.lhs, category);
            const scheme = if (data.lhs < g.decl_scheme.len) g.decl_scheme[data.lhs].unwrap() else null;
            const v = scheme orelse return g.equal(expected, try g.fresh(.err), inst, category);
            return g.instantiate(expected, v, inst, category);
        },
        .schema_member_top, .schema_ctor_top => {
            if (g.demands(data.lhs)) return g.add(.demand, inst, @intFromEnum(expected), data.lhs, category);
            return g.add(.reference, inst, @intFromEnum(expected), 0, category);
        },
        .ctor, .ext_value, .ext_ctor, .ext_schema_member, .ext_schema_ctor => {
            return g.add(.reference, inst, @intFromEnum(expected), 0, category);
        },

        .tuple => {
            const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
            const vars = try g.cx.scratch.alloc(Var, elements.len);
            defer g.cx.scratch.free(vars);
            for (vars) |*v| v.* = try g.freshFlex();
            const range = try g.cx.store.addVars(vars);
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            try parts.append(g.cx.scratch, try g.equal(expected, try g.fresh(.{ .structure = .{ .tuple = range } }), inst, category));
            for (elements, vars, 0..) |el, v, i| {
                try parts.append(g.cx.scratch, try expr(g, el, v, .{ .tag = .tuple_element, .index = @intCast(i + 1) }));
            }
            return g.conj(parts.items);
        },

        .list => {
            const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
            const element = try g.freshFlex();
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            try parts.append(g.cx.scratch, try g.equal(expected, try g.applied(wk.list, &.{element}), inst, category));
            for (elements, 0..) |el, i| {
                try parts.append(g.cx.scratch, try expr(g, el, element, .{ .tag = .list_entry, .index = @intCast(i + 1) }));
            }
            return g.conj(parts.items);
        },

        // The fields, and the literal meeting the expectation, in the order
        // the solver chooses (§6.5): the fields first
        // when the expectation cannot take this literal's field names, so a
        // missing or unexpected field shows the literal's own field types;
        // the expectation first otherwise, so each field is checked against
        // the type the context wants for it.
        .record => {
            const written = bir.extraSlice(Bir.inlineRange(data), Bir.Field);
            const pairs = try g.cx.scratch.alloc(TypeStore.Field, written.len);
            defer g.cx.scratch.free(pairs);
            for (written, pairs) |f, *p| p.* = .{ .name = bir.symbol(f.name), .value = try g.freshFlex() };
            const range = try g.cx.store.addFields(pairs);
            const closed = try g.fresh(.{ .structure = .empty_record });
            const record_var = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = closed } } });
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            for (written) |f| {
                const name = bir.symbol(f.name);
                const v = Walk.fieldIn(g.cx.store, range, name) orelse try g.freshFlex();
                try parts.append(g.cx.scratch, try expr(g, f.value, v, .{ .tag = .record_field, .index = @intFromEnum(name) }));
            }
            const fields = try g.conj(parts.items);
            const payload = try g.addExtra(Tree.RecordLiteral{ .expected = expected, .record = record_var, .fields = fields });
            return g.add(.record, inst, payload, 0, category);
        },

        .record_update => {
            const written = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field);
            const base = try g.freshFlex();
            const pairs = try g.cx.scratch.alloc(TypeStore.Field, written.len);
            defer g.cx.scratch.free(pairs);
            for (written, pairs) |f, *p| p.* = .{ .name = bir.symbol(f.name), .value = try g.freshFlex() };
            const range = try g.cx.store.addFields(pairs);
            const ext = try g.freshFlex();
            const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            try parts.append(g.cx.scratch, try expr(g, @enumFromInt(data.lhs), base, .{ .tag = .general }));
            // The base must HAVE every updated field; the result is the
            // base's own type, so an update never widens a record.
            try parts.append(g.cx.scratch, try g.equal(required, base, inst, .{ .tag = .record_update, .index = Category.no_field }));
            try parts.append(g.cx.scratch, try g.equal(expected, base, inst, category));
            for (written) |f| {
                const name = bir.symbol(f.name);
                const v = Walk.fieldIn(g.cx.store, range, name) orelse try g.freshFlex();
                try parts.append(g.cx.scratch, try expr(g, f.value, v, .{ .tag = .record_update, .index = @intFromEnum(name) }));
            }
            return g.conj(parts.items);
        },

        .field_access => {
            const name = bir.symbol(@enumFromInt(data.rhs));
            var pairs = [_]TypeStore.Field{.{ .name = name, .value = expected }};
            const range = try g.cx.store.addFields(&pairs);
            const ext = try g.freshFlex();
            const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
            const target = try g.freshFlex();
            return g.conj(&.{
                try expr(g, @enumFromInt(data.lhs), target, .{ .tag = .general }),
                try g.equal(required, target, inst, .{ .tag = .field_access, .index = @intFromEnum(name) }),
            });
        },

        // A `${…}` string: `String`, and each part an `interpolatable`
        // obligation on its own variable (§4.5).
        .interp => {
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            try parts.append(g.cx.scratch, try g.equal(expected, try g.primitive(wk.string), inst, category));
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |part| {
                if (bir.instTag(part) == .chunk) continue;
                const t = try g.freshFlex();
                try parts.append(g.cx.scratch, try expr(g, part, t, .{ .tag = .interp_part }));
                try parts.append(g.cx.scratch, try g.add(.interpolatable, part, @intFromEnum(t), 0, .{ .tag = .interp_part }));
            }
            return g.conj(parts.items);
        },

        // `e.i`: the tuple first, then the obligation on it (§4.5).
        .tuple_index => {
            const target = try g.freshFlex();
            const payload = try g.addExtra(Tree.TupleIndex{ .index = data.rhs, .result = expected });
            return g.conj(&.{
                try expr(g, @enumFromInt(data.lhs), target, .{ .tag = .general }),
                try g.add(.tuple_index, inst, @intFromEnum(target), payload, category),
            });
        },

        // `e?`: the subject first, then the obligation on it and on the
        // result of the definition it returns from (§8.6).
        .@"try" => {
            const subject = try g.freshFlex();
            const target = g.targetResult(@enumFromInt(data.rhs)) orelse try g.fresh(.err);
            const payload = try g.addExtra(Tree.Try{ .subject = subject, .target = target, .value = expected });
            return g.conj(&.{
                try expr(g, @enumFromInt(data.lhs), subject, .{ .tag = .general }),
                try g.add(.try_, inst, payload, 0, category),
            });
        },

        .method_call => return methodCall(g, inst, data, expected, category),
        .type_dispatch => return typeDispatch(g, inst, data, expected, category),
        .call => return call(g, inst, data, expected, category),
        .lambda => return lambda(g, inst, data, expected, category),
        .let => return Decl.letExpr(g, data, expected, category),
        .case => return caseExpr(g, data, expected, category),

        // A name that did not resolve, or a parser placeholder: it has a
        // diagnostic already, so poison and stay quiet.
        .@"error", .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref => {
            return g.equal(expected, try g.fresh(.err), inst, category);
        },
        // Markup, typed against the build's vocabulary (checker-v2.md §25).
        .markup => return Markup.root(g, inst, expected, category),
        // A form the generator has no rule for, or no expression at all:
        // the compiler says so, never a silent poison: no failure to decide
        // is answered as success.
        else => return g.add(.internal, inst, @intFromEnum(expected), 0, category),
    }
}

// ---------------------------------------------------------------------------
// Method calls (static-dispatch-spike.md §1, §3.1, §4; checker-v2.md §6.4)
// ---------------------------------------------------------------------------

/// `x.m a b` and the six comparison operators: the receiver's constraints,
/// then the `method` node, then the arguments' — the order IS Rule U0 (a
/// receiver already known is resolved before the arguments are checked).
fn methodCall(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
    const bir = g.cx.bir;
    const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
    const args = bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index);
    const receiver: Bir.Inst.Index = @enumFromInt(data.lhs);
    if (m.origin != .none) return wellKnownCall(g, inst, receiver, args, m.origin, expected, category);

    const recv = try g.freshFlex();
    const arg_vars = try g.cx.scratch.alloc(Var, args.len);
    defer g.cx.scratch.free(arg_vars);
    for (arg_vars) |*v| v.* = try g.freshFlex();
    // The receiver FIRST: `x.m a b` means `M.m x a b` (§1.2).
    const params = try g.cx.scratch.alloc(Var, args.len + 1);
    defer g.cx.scratch.free(params);
    params[0] = recv;
    @memcpy(params[1..], arg_vars);
    const method_type = try g.func(params, expected);
    try g.called(method_type, inst);
    const payload = try g.addExtra(Tree.Method{
        .name = bir.symbol(m.name),
        .receiver = recv,
        .method_type = method_type,
        .kind = @intFromEnum(Evidence.Kind.dot_call),
        .var_name = @intFromEnum(Tree.Symbol.Optional.none),
    });
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    try parts.append(g.cx.scratch, try expr(g, receiver, recv, .{ .tag = .general }));
    try parts.append(g.cx.scratch, try g.add(.method, inst, payload, 0, category));
    for (args, arg_vars, 0..) |arg, v, i| {
        try parts.append(g.cx.scratch, try expr(g, arg, v, .{
            .tag = .call_arg,
            .index = @intCast(i + 1),
            .owner = inst.toOptional(),
        }));
    }
    return g.conj(parts.items);
}

/// `a == b` and the four orderings (§3.1): ONE operand variable for the
/// receiver, the argument and the method type, so `same a b = a == b` is
/// `a, a -> Bool where a.eq : a, a -> Bool`; the instruction is `Bool`.
fn wellKnownCall(
    g: *Generator,
    inst: Bir.Inst.Index,
    receiver: Bir.Inst.Index,
    args: []const Bir.Inst.Index,
    origin: Bir.WellKnown,
    expected: Var,
    category: Category,
) Error!Constraint {
    const wk = g.cx.types.well_known;
    const operand = try g.freshFlex();
    const method_result = switch (origin) {
        .none, .eq, .neq => try g.primitive(wk.bool),
        else => try g.primitive(wk.order),
    };
    const method_type = try g.func(&.{ operand, operand }, method_result);
    try g.called(method_type, inst);
    const name = (origin.method() orelse InternPool.WellKnown.eq).symbol();
    const payload = try g.addExtra(Tree.Method{
        .name = name,
        .receiver = operand,
        .method_type = method_type,
        .kind = @intFromEnum(Evidence.Kind.well_known),
        .var_name = @intFromEnum(Tree.Symbol.Optional.none),
    });
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    try parts.append(g.cx.scratch, try g.equal(expected, try g.primitive(wk.bool), inst, category));
    try parts.append(g.cx.scratch, try expr(g, receiver, operand, .{
        .tag = .call_arg,
        .index = 1,
        .owner = inst.toOptional(),
    }));
    try parts.append(g.cx.scratch, try g.add(.method, inst, payload, 0, category));
    for (args, 0..) |arg, i| {
        try parts.append(g.cx.scratch, try expr(g, arg, operand, .{
            .tag = .call_arg,
            .index = @intCast(i + 2),
            .owner = inst.toOptional(),
        }));
    }
    return g.conj(parts.items);
}

/// `a.decode s` (§4): a dispatch on a TYPE. The variable is the rigid the
/// declaration's annotation introduced for it; lowering refused every other
/// case, and a poisoned annotation poisons the expression here.
fn typeDispatch(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
    const bir = g.cx.bir;
    const t = bir.extraData(@enumFromInt(data.rhs), Bir.TypeDispatch);
    const args = bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Bir.Inst.Index);
    const var_symbol = bir.symbols[data.lhs];
    const rigid = blk: {
        for (g.decl_rigids) |scoped| {
            if (scoped.name == var_symbol) break :blk scoped.v;
        }
        break :blk try g.fresh(.err);
    };
    const arg_vars = try g.cx.scratch.alloc(Var, args.len);
    defer g.cx.scratch.free(arg_vars);
    for (arg_vars) |*v| v.* = try g.freshFlex();
    // No receiver: the method's type is `arg₁, …, argₙ -> result` (§4.2).
    const method_type = try g.func(arg_vars, expected);
    try g.called(method_type, inst);
    const payload = try g.addExtra(Tree.Method{
        .name = bir.symbol(t.name),
        .receiver = rigid,
        .method_type = method_type,
        .kind = @intFromEnum(Evidence.Kind.type_dispatch),
        .var_name = @intFromEnum(var_symbol.toOptional()),
    });
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    try parts.append(g.cx.scratch, try g.add(.method, inst, payload, 0, category));
    for (args, arg_vars, 0..) |arg, v, i| {
        try parts.append(g.cx.scratch, try expr(g, arg, v, .{
            .tag = .call_arg,
            .index = @intCast(i + 1),
            .owner = inst.toOptional(),
        }));
    }
    return g.conj(parts.items);
}

fn call(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
    const bir = g.cx.bir;
    const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
    const callee = try g.freshFlex();
    try g.called(callee, inst);
    const arg_vars = try g.cx.scratch.alloc(Var, args.len);
    defer g.cx.scratch.free(arg_vars);
    for (arg_vars) |*v| v.* = try g.freshFlex();

    const args_start: u32 = @intCast(g.tree.extra.items.len);
    try g.tree.extra.appendSlice(g.gpa, @ptrCast(arg_vars));
    const payload = try g.addExtra(Tree.Call{
        .callee = callee,
        .args_start = args_start,
        .args_len = @intCast(args.len),
        .result = expected,
        .flavor = .call,
    });

    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    // The callee first, so the solver knows its arrows; then the call, so
    // §8.3 sees both the arrows and what the result was wanted for; then
    // the arguments, against a callee that is already concrete.
    try parts.append(g.cx.scratch, try expr(g, @enumFromInt(data.lhs), callee, .{ .tag = .general }));
    try parts.append(g.cx.scratch, try g.add(.call, inst, payload, 0, category));
    for (args, arg_vars, 0..) |arg, v, i| {
        try parts.append(g.cx.scratch, try expr(g, arg, v, .{
            .tag = .call_arg,
            .index = @intCast(i + 1),
            .owner = inst.toOptional(),
        }));
    }
    return g.conj(parts.items);
}

fn lambda(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
    const bir = g.cx.bir;
    const params = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index);
    const param_vars = try g.cx.scratch.alloc(Var, params.len);
    defer g.cx.scratch.free(param_vars);
    for (param_vars) |*v| v.* = try g.freshFlex();
    var result = try g.freshFlex();
    // An operator section (`(==)`, `(<)`, …) is a lambda over one marked
    // `method_call` (static-dispatch-spike.md §3.1, A.22), and its type is
    // known exactly: `a, a -> Bool`. Pinned before the body, so
    // `List.foldl [ 1 ] 0 (<)` says "this argument is `Int, Int -> Bool`" at
    // the section and not "`Bool` is not `b`" inside it (a message rule,
    // not a call shim: §6.4 has none).
    if (bir.operatorSection(inst, g.locals_base) != null) {
        const operand = try g.freshFlex();
        for (param_vars) |*v| v.* = operand;
        result = try g.primitive(g.cx.types.well_known.bool);
    }

    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    const arrow = try g.func(param_vars, result);
    try parts.append(g.cx.scratch, try g.equal(expected, arrow, inst, category));
    const binders: u32 = @intCast(g.tree.binders.items.len);
    for (params, param_vars) |p, v| try parts.append(g.cx.scratch, try Pattern.pattern(g, p, v));
    // The body's calls join the lambda's own arrow, never the enclosing
    // function's (§14.3 rule 1): passing a lambda along calls nothing.
    const outer = g.ambient;
    const outer_site = g.ambient_site;
    g.ambient = arrow;
    g.ambient_site = @intFromEnum(inst);
    defer {
        g.ambient = outer;
        g.ambient_site = outer_site;
    }
    try parts.append(g.cx.scratch, try expr(g, @enumFromInt(data.rhs), result, .{ .tag = .general }));
    // Elm's placement: the lambda's own header, checked before anything
    // outside it meets the lambda's type (§6.3).
    if (try g.bindersEnd(binders)) |end| try parts.append(g.cx.scratch, end);
    return g.conj(parts.items);
}

fn caseExpr(g: *Generator, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
    const bir = g.cx.bir;
    const branches = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
    const scrutinee = try g.freshFlex();
    var parts: std.ArrayList(Constraint) = .empty;
    defer parts.deinit(g.cx.scratch);
    try parts.append(g.cx.scratch, try expr(g, @enumFromInt(data.lhs), scrutinee, .{ .tag = .general }));
    for (branches, 0..) |b, i| {
        const bd = bir.instData(b);
        const binders: u32 = @intCast(g.tree.binders.items.len);
        try parts.append(g.cx.scratch, try Pattern.patternAgainst(g, @enumFromInt(bd.lhs), scrutinee));
        // The FIRST branch is measured against the context, every later one
        // against the branches before it (Elm's split).
        try parts.append(g.cx.scratch, try expr(g, @enumFromInt(bd.rhs), expected, if (i == 0) category else .{
            .tag = .case_branch,
            .index = @intCast(i + 1),
        }));
        if (try g.bindersEnd(binders)) |end| try parts.append(g.cx.scratch, end);
    }
    return g.conj(parts.items);
}
