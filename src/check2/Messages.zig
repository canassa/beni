//! Checker v2's own message texts (checker-v2.md §15.3; `checker.md` §8.5,
//! §8.6): the annotation escape of §8.3 (CK-01), the infinite type written
//! as its structure (§8.2, CK-57), and the three legs of a failed `?` (§8.6,
//! CK-51). Split out of `Report.zig` by R5's review (S5, §19.1), which keeps
//! the emit path, `quiet` and the failure bits; every text here ends in
//! `Report.emit`, the one path to the module's list (§15.1). v1 keeps its own
//! texts until the cut-over.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Render = @import("../check/Render.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Report = @import("Report.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Report.Error;

fn renderContext(r: *const Report) Render.Context {
    return .{ .store = r.env.store, .types = r.env.types, .interner = r.env.interner };
}

/// `infinite_type` at `region`, for binder `name` (or "here"), with the
/// cycle through `cycle` — a union-find root on the cycle — written down
/// once, every inner occurrence named (§8.2, CK-57).
///
/// The node's own content is printed through a detached copy while the node
/// itself reads as a plain variable, so the printer names it where it
/// recurs; the content is put back before returning. The caller poisons the
/// node after.
pub fn infiniteType(r: *Report, region: Bir.Inst.Index, name: Symbol.Optional, cycle: Var) Error!void {
    const store = r.env.store;
    const interner = r.env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;

    const content = store.content(cycle);
    const shown = try store.fresh(content, store.rank(cycle));
    store.setContent(cycle, .{ .flex = .{} });
    defer store.setContent(cycle, content);
    const repeat = try namer.name(cycle, null);

    if (name.unwrap()) |s| {
        w.print("I am inferring a weird self-referential type for `{s}`:\n\n", .{interner.slice(s)}) catch return error.OutOfMemory;
    } else {
        w.writeAll("I am inferring a weird self-referential type here:\n\n") catch return error.OutOfMemory;
    }
    w.print(
        \\Here is my best effort at writing it down, with `{s}` standing for the whole
        \\type wherever it repeats inside itself:
        \\
        \\
    , .{repeat}) catch return error.OutOfMemory;
    w.print("    {s} = ", .{repeat}) catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, shown, .top) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\Hint: the type would go on forever, so I gave up. This usually means a
        \\definition is missing an argument, or is being used with one argument too
        \\many, somewhere inside itself.
        \\
    ) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .infinite_type, .module = r.module, .region = region, .message = message });
}

/// `rigid_mismatch` for an annotation escape (§8.3, D7, CK-01): binding
/// `binding` declares `scheme`, and its variable `rigid` was tied to a type
/// of `enclosing`, the declaration it is written in.
pub fn escape(
    r: *Report,
    region: Bir.Inst.Index,
    binding: Symbol.Optional,
    enclosing: Symbol,
    scheme: Var,
    rigid: Var,
) Error!void {
    const store = r.env.store;
    const interner = r.env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const name = if (binding.unwrap()) |s| interner.slice(s) else "this binding";
    const outer = interner.slice(enclosing);
    const variable = switch (store.content(store.find(rigid))) {
        .rigid, .flex => |flags| if (flags.name.unwrap()) |s| interner.slice(s) else "a",
        else => "a",
    };
    w.print("The type annotation of `{s}` promises more than its body keeps:\n\n    {s} : ", .{ name, name }) catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, scheme, .top) catch return error.OutOfMemory;
    w.print(
        \\
        \\
        \\The annotation says `{s}` can be ANY type, but the body ties `{s}` to a type that
        \\comes from `{s}`, the definition `{s}` is written inside. That type is fixed for
        \\each call of `{s}`, so `{s}` does not work for every `{s}`.
        \\
        \\Hint: write the enclosing definition's type in the annotation instead of `{s}`,
        \\or remove the annotation and let the type be inferred.
        \\
    , .{ variable, variable, outer, name, outer, name, variable, variable }) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .rigid_mismatch, .module = r.module, .region = region, .message = message });
}

/// Which leg of a `?` failed (§8.6, §15.3; `checker.md` §8.6, CK-51).
pub const TryLeg = enum {
    /// The subject is not a `Result` or a `Maybe`.
    neither,
    /// The enclosing result is not the subject's shape.
    enclosing,
    /// Both are `Result`s whose error types differ.
    errors,
};

/// `try_shape` for a `?` at `region` whose subject is `subject` and whose
/// target's result is `enclosing`, naming the leg that failed (`checker.md`
/// §8.6). Rendered before either side is poisoned.
pub fn tryShape(r: *Report, region: Bir.Inst.Index, leg: TryLeg, subject: Var, enclosing: Var) Error!void {
    const store = r.env.store;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const cx = renderContext(r);
    const hint =
        \\
        \\
        \\Hint: `e?` unwraps an `Ok`/`Just` and returns the `Err`/`Nothing` from the
        \\enclosing definition, so both have to be the same shape. There is no
        \\conversion between `Result` and `Maybe`.
        \\
    ;
    switch (leg) {
        .neither => {
            w.writeAll("`?` needs a `Result` or a `Maybe`, and this is neither:\n\n    ") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, subject, .top) catch return error.OutOfMemory;
            w.writeAll("\n\nThe enclosing definition returns:\n\n    ") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, enclosing, .top) catch return error.OutOfMemory;
            w.writeAll(hint) catch return error.OutOfMemory;
        },
        .enclosing => {
            const shape = if (isApp(r, subject, r.env.types.well_known.result)) "Result" else "Maybe";
            w.writeAll("This `?` returns early from the enclosing definition, which returns:\n\n    ") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, enclosing, .top) catch return error.OutOfMemory;
            w.writeAll("\n\nbut this is a `") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, subject, .top) catch return error.OutOfMemory;
            w.print("`, and `?` on a `{s}` can only return from a\ndefinition whose result is a `{s}` too.", .{ shape, shape }) catch return error.OutOfMemory;
            w.writeAll(hint) catch return error.OutOfMemory;
        },
        .errors => {
            const here = firstArg(store, subject) orelse subject;
            const there = firstArg(store, enclosing) orelse enclosing;
            w.writeAll("This `?` returns the error of a `Result` from the enclosing definition, but\nthe error types differ: `") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, here, .top) catch return error.OutOfMemory;
            w.writeAll("` here, `") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, there, .top) catch return error.OutOfMemory;
            w.writeAll("` in the enclosing result:\n\n    ") catch return error.OutOfMemory;
            Render.writeVar(w, cx, &namer, subject, .top) catch return error.OutOfMemory;
            w.writeAll(
                \\
                \\
                \\Hint: convert the error first, with `Result.mapError`, so that it has the type
                \\the enclosing definition returns.
                \\
            ) catch return error.OutOfMemory;
        },
    }
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .try_shape, .module = r.module, .region = region, .message = message });
}

fn isApp(r: *const Report, v: Var, id: TypeStore.TypeId) bool {
    return switch (r.env.store.resolvedContent(v)) {
        .structure => |flat| switch (flat) {
            .app => |a| id != .none and a.type == id,
            else => false,
        },
        else => false,
    };
}

/// A `Result`'s error type: the first argument of the application `v`
/// resolves to.
fn firstArg(store: *TypeStore, v: Var) ?Var {
    const root, const content = store.resolved(v);
    if (content != .structure or content.structure != .app) return null;
    return Walk.child(store, root, 0, .structural);
}

/// `nesting_too_deep` when one top-level group's method resolution takes
/// more than `budget` steps (§9.5; review F1): the receiver types it builds
/// nest further than the checker follows. It shares the code with the
/// parser's and the type printer's limit for the same reason they share it:
/// the program is deeper than the compiler reads, and naming an inner part
/// fixes it.
pub fn resolutionBudget(r: *Report, region: Bir.Inst.Index, budget: u32) Error!void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\Working out which methods these declarations call took more than {d}
        \\steps, which is more than I will take for one group of declarations.
        \\
        \\The types their method calls are made on nest deeper and deeper as I follow
        \\them. I gave up here, so I cannot check this group or anything that uses
        \\it. An annotation with a `where` clause on the declaration usually stops
        \\the growth.
        \\
    , .{budget}) catch unreachable;
    try r.emitText(.nesting_too_deep, region, null, text);
}
