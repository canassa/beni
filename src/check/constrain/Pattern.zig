//! Constraint generation for patterns (checker-v2.md §6; `checker.md` §6.1,
//! v1's rules verbatim).
//!
//! A pattern binds its variables by making the local's variable the one the
//! context expects — no fresh variable and no equality — and it registers
//! each one as a **binder** of the current frame (§6.3), with the pattern
//! instruction as the region an `infinite_type` points at. The enclosing
//! lambda, `case` branch or declaration closes the range with a
//! `binders_end`; a `let` pattern's binders are checked at its group's
//! boundary.

const std = @import("std");
const Bir = @import("../../bir/Bir.zig");
const TypeStore = @import("../TypeStore.zig");
const Tree = @import("Tree.zig");

const Generator = Tree.Generator;
const Constraint = Tree.Constraint;
const Var = Tree.Var;
const Error = Tree.Error;

/// Bind a parameter pattern to `v`.
pub fn pattern(g: *Generator, inst: Bir.Inst.Index, v: Var) Error!Constraint {
    return patternAgainst(g, inst, v);
}

pub fn patternAgainst(g: *Generator, inst: Bir.Inst.Index, expected: Var) Error!Constraint {
    g.depth += 1;
    defer g.depth -= 1;
    // Unreachable from a file the parser accepted; noted, never silent (I4).
    if (g.depth > Generator.max_depth) {
        try g.cx.noteTooDeep(inst, @intFromEnum(g.decl));
        return g.true_();
    }

    const bir = g.cx.bir;
    const wk = g.cx.types.well_known;
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .pat_wild => return g.true_(),
        .pat_var => {
            g.setLocal(data.lhs, expected);
            _ = try g.binder(expected, inst, g.nameOfLocal(data.lhs));
            return g.true_();
        },
        .pat_as => {
            g.setLocal(data.rhs, expected);
            _ = try g.binder(expected, inst, g.nameOfLocal(data.rhs));
            return patternAgainst(g, @enumFromInt(data.lhs), expected);
        },
        .pat_int => return g.equal(expected, try g.freshKind(.number), inst, .{ .tag = .case_pattern }),
        .pat_char => return g.equal(expected, try g.primitive(wk.char), inst, .{ .tag = .case_pattern }),
        .pat_string => return g.equal(expected, try g.primitive(wk.string), inst, .{ .tag = .case_pattern }),
        .pat_unit => return g.equal(expected, try g.fresh(.{ .structure = .unit }), inst, .{ .tag = .case_pattern }),
        .pat_tuple => {
            const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
            const vars = try g.cx.scratch.alloc(Var, elements.len);
            defer g.cx.scratch.free(vars);
            for (vars) |*v| v.* = try g.freshFlex();
            const range = try g.cx.store.addVars(vars);
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            try parts.append(g.cx.scratch, try g.equal(expected, try g.fresh(.{ .structure = .{ .tuple = range } }), inst, .{ .tag = .case_pattern }));
            for (elements, vars) |el, v| try parts.append(g.cx.scratch, try patternAgainst(g, el, v));
            return g.conj(parts.items);
        },
        .pat_list => {
            const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
            const element = try g.freshFlex();
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            try parts.append(g.cx.scratch, try g.equal(expected, try g.applied(wk.list, &.{element}), inst, .{ .tag = .case_pattern }));
            for (elements) |el| try parts.append(g.cx.scratch, try patternAgainst(g, el, element));
            return g.conj(parts.items);
        },
        .pat_cons => {
            const element = try g.freshFlex();
            const list = try g.applied(wk.list, &.{element});
            return g.conj(&.{
                try g.equal(expected, list, inst, .{ .tag = .case_pattern }),
                try patternAgainst(g, @enumFromInt(data.lhs), element),
                try patternAgainst(g, @enumFromInt(data.rhs), list),
            });
        },
        .pat_record => {
            const locals = bir.extraSlice(Bir.inlineRange(data), u32);
            const pairs = try g.cx.scratch.alloc(TypeStore.Field, locals.len);
            defer g.cx.scratch.free(pairs);
            for (locals, pairs) |li, *p| {
                const v = try g.freshFlex();
                g.setLocal(li, v);
                const name = g.nameOfLocal(li);
                _ = try g.binder(v, inst, name);
                p.* = .{ .name = name.unwrap() orelse @enumFromInt(0), .value = v };
            }
            const range = try g.cx.store.addFields(pairs);
            const ext = try g.freshFlex();
            const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
            return g.equal(required, expected, inst, .{ .tag = .case_pattern });
        },
        .pat_ctor => {
            const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
            const ctor = try g.freshFlex();
            const arg_vars = try g.cx.scratch.alloc(Var, args.len);
            defer g.cx.scratch.free(arg_vars);
            for (arg_vars) |*v| v.* = try g.freshFlex();
            const args_start: u32 = @intCast(g.tree.extra.items.len);
            try g.tree.extra.appendSlice(g.gpa, @ptrCast(arg_vars));
            const payload = try g.addExtra(Tree.Call{
                .callee = ctor,
                .args_start = args_start,
                .args_len = @intCast(args.len),
                .result = expected,
                .flavor = .ctor_pattern,
            });
            var parts: std.ArrayList(Constraint) = .empty;
            defer parts.deinit(g.cx.scratch);
            const reference: Bir.Inst.Index = @enumFromInt(data.lhs);
            if (bir.instTag(reference) == .@"error") {
                try parts.append(g.cx.scratch, try g.equal(ctor, try g.fresh(.err), inst, .{}));
            } else {
                try parts.append(g.cx.scratch, try g.add(.reference, reference, @intFromEnum(ctor), 0, .{}));
            }
            try parts.append(g.cx.scratch, try g.add(.call, inst, payload, 0, .{ .tag = .case_pattern }));
            for (args, arg_vars) |arg, v| try parts.append(g.cx.scratch, try patternAgainst(g, arg, v));
            return g.conj(parts.items);
        },
        // A parser placeholder: already reported.
        .@"error" => return g.equal(expected, try g.fresh(.err), inst, .{}),
        // No pattern at all: the compiler's failure (review S1).
        else => return g.add(.internal, inst, @intFromEnum(expected), 0, .{}),
    }
}
