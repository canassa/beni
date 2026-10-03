//! The text of `statement_not_unit` (checker-v2.md §29.1): a block's
//! statement whose type is not `()`. Kept apart from `Diagnostics.zig` to
//! hold both under `checker-v2.md` §19.1's 1 500 lines; `Reporter.mismatch`
//! calls it for the `statement` category.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Render = @import("Render.zig");
const TypeStore = @import("TypeStore.zig");
const Diagnostics = @import("Diagnostics.zig");
const Walk = @import("Walk.zig");
const Category = @import("Category.zig").Category;

const Reporter = Diagnostics.Reporter;
const Error = Reporter.Error;
const Var = TypeStore.Var;

/// What `Session` replaces with the source text of a statement: the
/// checker has no source, and the message gives the two fixes in the
/// statement's own words (checker-v2.md §29.1).
pub const statement_text = "\x1a";

/// `statement_not_unit` (checker-v2.md §29.1), at the `let_stmt`
/// `region`: the type the statement has, then the two fixes — bind it,
/// or discard it with `_ =`. When the statement calls a function and
/// passes it a local of the very type it returns, the function made a
/// new value and changed nothing, and the sentence says so.
pub fn statementNotUnit(r: *Reporter, region: Bir.Inst.Index, category: Category, actual: Var) Error!void {
    // A statement that failed inside — `List.push xs "a"` — has said so
    // already, and its type holds the poison (checker-v2.md §15.2).
    if (try holdsError(r, actual)) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    var shown: std.Io.Writer.Allocating = .init(r.gpa);
    defer shown.deinit();
    Render.writeVar(&shown.writer, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
    const type_text = shown.written();
    w.print("This line is a statement, so its value is thrown away — but it is {s} `{s}`, not `⊤`.\n\n", .{ Diagnostics.article(type_text), type_text }) catch return error.OutOfMemory;

    // A "returns a new one" function (§29.1): a call, not an operator,
    // passed a local of the very type it returns. The binding the fix
    // suggests is then named after its first argument.
    const bir = r.env.bir;
    var name: []const u8 = "result";
    if (category.owner.unwrap()) |call| if (call.int() < bir.insts.len and bir.instTag(call) == .call) {
        const callee = r.calleeOf(call);
        const data = bir.instData(call);
        const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index);
        var new_one = false;
        for (args) |arg| {
            if (bir.instTag(arg) != .local) continue;
            const v = r.env.localVar(bir.instData(arg).lhs) orelse continue;
            var arg_text: std.Io.Writer.Allocating = .init(r.gpa);
            defer arg_text.deinit();
            Render.writeVar(&arg_text.writer, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
            if (std.mem.eql(u8, arg_text.written(), type_text)) new_one = true;
        }
        if (new_one and (callee.kind == .function or callee.kind == .value)) {
            w.print("{s} returns a new `{s}` and changes nothing. ", .{ Diagnostics.calleeReference(r.env.scratch, callee), type_text }) catch return error.OutOfMemory;
            if (args.len > 0 and bir.instTag(args[0]) == .local) {
                const at = r.env.locals_base + bir.instData(args[0]).lhs;
                if (at < bir.locals.len and bir.locals[at].name != .none) {
                    name = std.fmt.allocPrint(r.env.scratch, "{s}2", .{r.env.interner.slice(bir.symbol(bir.locals[at].name))}) catch name;
                }
            }
        }
    };
    w.print(
        \\Bind the result and use it:
        \\
        \\    {s} = {s}
        \\
        \\or, if throwing it away is what you mean, say so:
        \\
        \\    _ = {s}
    , .{ name, statement_text, statement_text }) catch return error.OutOfMemory;
    try r.emit(.statement_not_unit, region, &out);
}

/// A mismatch against `⊤` under `statement` or `if_without_else`, which
/// `Reporter.mismatch` hands here; `kindNotSatisfied` calls `ifWithoutElse`
/// itself, for a number.
pub fn unitMismatch(r: *Reporter, region: Bir.Inst.Index, category: Category, actual: Var) Error!void {
    if (category.tag == .if_without_else) return ifWithoutElse(r, region, actual);
    return statementNotUnit(r, region, category, actual);
}

/// `if_without_else_not_unit` (checker-v2.md §34), at the `then` branch
/// `region` of an `if` without `else`: an `if` with no `else` is `⊤` when
/// its condition is false, so its `then` branch must be `⊤` too.
pub fn ifWithoutElse(r: *Reporter, region: Bir.Inst.Index, actual: Var) Error!void {
    // A branch that failed inside has said so already (§15.2).
    if (try holdsError(r, actual)) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    var shown: std.Io.Writer.Allocating = .init(r.gpa);
    defer shown.deinit();
    Render.writeVar(&shown.writer, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
    const type_text = shown.written();
    w.print(
        \\This `if` has no `else`, so it is `⊤` when its condition is false — and then its
        \\`then` branch must be `⊤` too, but it is {s} `{s}`.
        \\
        \\Give the `if` the value it has when the condition is false:
        \\
        \\    if … then … else …
    , .{ Diagnostics.article(type_text), type_text }) catch return error.OutOfMemory;
    try r.emit(.if_without_else_not_unit, region, &out);
}

/// Whether an error variable is anywhere inside `v`'s type, on a stack
/// that grows (`Walk`'s rule).
fn holdsError(r: *Reporter, v: Var) Error!bool {
    const st = r.env.store;
    const seen = st.nextMark();
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(r.env.scratch);
    try stack.append(r.env.scratch, v);
    while (stack.pop()) |next| {
        const root = st.find(next);
        if (st.mark(root) == seen) continue;
        st.setMark(root, seen);
        if (st.content(root) == .err) return true;
        var n: u32 = 0;
        while (Walk.child(st, root, n, .structural)) |c| : (n += 1) try stack.append(r.env.scratch, c);
    }
    return false;
}
