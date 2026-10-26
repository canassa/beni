//! The hints of a `type_mismatch` at a `let` binding that has ONE type
//! (checker-v2.md §8.4): one held back over a constraint (A.30), and one
//! held back because a call made its value (§8.4, amended 2026-10-26).
//! Kept apart from `Diagnostics.zig` to hold both under `checker-v2.md`
//! §19.1's 1 500 lines; `Reporter.mismatch` and `kindNotSatisfied` call them.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");
const EnvFile = @import("Env.zig");
const Resolve = @import("Resolve.zig");
const Diagnostics = @import("Diagnostics.zig");
const Walk = @import("Walk.zig");
const Category = @import("Category.zig").Category;

const Reporter = Diagnostics.Reporter;
const Error = Reporter.Error;
const Var = TypeStore.Var;
const article = Diagnostics.article;

/// The A.30 hint, when the callee of this argument is a `let` binding
/// whose type carries a method constraint. False when it is not, and
/// then the ordinary hints apply.
pub fn monomorphicLetHint(r: *Reporter, w: *std.Io.Writer, category: Category) Error!bool {
    if (category.tag != .call_arg) return false;
    const call = category.owner.unwrap() orelse return false;
    const bir = r.env.bir;
    if (call.int() >= bir.insts.len) return false;
    const callee: Bir.Inst.Index = switch (bir.instTag(call)) {
        .call => @fromBackingInt(@intCast(bir.instData(call).lhs)),
        else => return false,
    };
    if (callee.int() >= bir.insts.len or bir.instTag(callee) != .local) return false;
    const index = bir.instData(callee).lhs;
    const v = r.env.localVar(index) orelse return false;
    const found = (try monomorphicMethod(r, v)) orelse return false;
    const at = r.env.locals_base + index;
    const name = if (at < bir.locals.len)
        (if (bir.locals[at].name.unwrap()) |sym| r.env.interner.slice(bir.symbols[sym]) else "it")
    else
        "it";
    const method = r.env.interner.slice(found.method);
    // Why the binding has one type (checker-v2.md §8.4): every other
    // constrained `let` function is generalised.
    switch (found.why) {
        .dot_call => w.print(
            \\
            \\Hint: `{s}` is a binding of a block whose type needs {s} `{s}` method only
            \\through a dot-call, which could still turn out to call a record's field,
            \\so the binding has ONE type inside the definition that holds it
            \\(`docs/design/checker-v2.md` §8.4). The first use fixed the type; this is
            \\the second.
            \\
            \\Move `{s}` out to a top-level declaration and annotate it with
            \\`where … .{s} : …` to use it at two.
            \\
        , .{ name, article(method), method, name, method }) catch return error.OutOfMemory,
        .value => w.print(
            \\
            \\Hint: `{s}` is a value of a block, with no parameters, whose type needs {s}
            \\`{s}` method. A value is computed once, where it is written, so it has ONE
            \\type inside the definition that holds it (`docs/design/checker-v2.md`
            \\§8.4). The first use fixed the type; this is the second.
            \\
            \\Give `{s}` a parameter, or move it out to a top-level declaration
            \\annotated with `where … .{s} : …`, to use it at two.
            \\
        , .{ name, article(method), method, name, method }) catch return error.OutOfMemory,
        .cap => w.print(
            \\
            \\Hint: `{s}` is a binding of a block whose type needs more than {d} methods, one
            \\of them {s} `{s}` method, and past that many a binding of a block is not
            \\generalised: it has ONE type inside the definition that holds it
            \\(`docs/design/static-dispatch-spike.md` §10.11). The first use fixed the
            \\type; this is the second.
            \\
            \\Move `{s}` out to a top-level declaration annotated with its `where`
            \\clause to use it at two.
            \\
        , .{ name, Resolve.max_inferred_constraints, article(method), method, name }) catch return error.OutOfMemory,
        .unreached => w.print(
            \\
            \\Hint: `{s}` is a binding of a block whose type needs {s} `{s}` method, and such a
            \\binding is used at ONE type inside the definition that holds it
            \\(`docs/design/checker-v2.md` §8.4). The first use fixed the type; this is
            \\the second.
            \\
            \\Move `{s}` out to a top-level declaration and annotate it with
            \\`where … .{s} : …` to use it at two.
            \\
        , .{ name, article(method), method, name, method }) catch return error.OutOfMemory,
    }
    return true;
}

/// §8.4, amended 2026-10-26: one side of the mismatch reaches a variable
/// a `let` value made by a call kept at one type. Says so, as
/// `monomorphicLetHint` does for a constrained binding. Error path only.
pub fn madeByCallHint(r: *Reporter, w: *std.Io.Writer, expected: Var, actual: Var) Error!bool {
    if (r.env.made_by_call.items.len == 0) return false;
    const st = r.env.store;
    const scratch = r.env.scratch;
    const seen = st.nextMark();
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, expected);
    try stack.append(scratch, actual);
    const found: EnvFile.MadeByCall = search: while (stack.pop()) |next| {
        const root = st.find(next);
        if (st.mark(root) == seen) continue;
        st.setMark(root, seen);
        for (r.env.made_by_call.items) |m| {
            if (st.find(m.v) == root) break :search m;
        }
        var n: u32 = 0;
        while (Walk.child(st, root, n, .structural)) |c| : (n += 1) try stack.append(scratch, c);
    } else return false;
    const sym = found.binding.unwrap() orelse {
        w.writeAll(
            \\
            \\Hint: this pattern takes apart a value of a block that is computed, once,
            \\where it is written: its right-hand side calls something, or is an `if`, a
            \\`case` or a block. A computation can make something that holds values, such
            \\as a new `Ref`, and one such thing cannot hold two types, so what the pattern
            \\binds has ONE type inside the definition that holds it
            \\(`docs/design/checker-v2.md` §8.4). The first use fixed the type; this one
            \\disagrees.
            \\
            \\Make the value in a function, `make ⊤ = …`, and take apart one call of it for
            \\each type.
            \\
        ) catch return error.OutOfMemory;
        return true;
    };
    const name = r.env.interner.slice(sym);
    w.print(
        \\
        \\Hint: `{s}` is a value of a block that is computed, once, where it is
        \\written: its right-hand side calls something, or is an `if`, a `case` or a
        \\block. A computation can make something that holds values, such as a new
        \\`Ref`, and one such thing cannot hold two types, so `{s}` has ONE type inside
        \\the definition that holds it (`docs/design/checker-v2.md` §8.4). The first
        \\use fixed the type; this one disagrees.
        \\
        \\Give `{s}` a parameter, so that each call makes a new one, to use it at two.
        \\
    , .{ name, name, name }) catch return error.OutOfMemory;
    return true;
}

/// The held variable that made `v`'s binding monomorphic, if any: a
/// variable inside `v`'s type that a `let` held back. The walk follows
/// `structural` successors to the bottom, each root once, on a stack
/// that grows: `Walk`'s rule, no fixed stack and no answer for giving up.
fn monomorphicMethod(r: *Reporter, v: Var) Error!?EnvFile.Monomorphic {
    if (r.env.monomorphic.items.len == 0) return null;
    const st = r.env.store;
    const scratch = r.env.scratch;
    const seen = st.nextMark();
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, v);
    while (stack.pop()) |next| {
        const root = st.find(next);
        if (st.mark(root) == seen) continue;
        st.setMark(root, seen);
        for (r.env.monomorphic.items) |m| {
            if (st.find(m.v) == root) return m;
        }
        var n: u32 = 0;
        while (Walk.child(st, root, n, .structural)) |c| : (n += 1) try stack.append(scratch, c);
    }
    return null;
}
