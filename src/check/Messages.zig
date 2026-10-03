//! The checker's own message texts (checker-v2.md §15.3; `checker.md` §8.5,
//! §8.6): the annotation escape of §8.3, the infinite type written as its
//! structure (§8.2), and the three legs of a failed `?` (§8.6). Kept apart
//! from `Report.zig` (§19.1), which keeps the emit path, `quiet` and the
//! failure bits; every text here ends in `Report.emit`, the one path to the
//! module's list (§15.1).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Render = @import("Render.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Report = @import("Report.zig");
const Walk = @import("Walk.zig");
const Diagnostics = @import("Diagnostics.zig");
const DispatchTexts = @import("DispatchTexts.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Report.Error;

fn renderContext(r: *const Report) Render.Context {
    return .{ .store = r.env.store, .types = r.env.types, .interner = r.env.interner };
}

/// `infinite_type` at `region`, for binder `name` (or "here"), with the
/// cycle through `cycle` — a union-find root on the cycle — written down
/// once, every inner occurrence named (§8.2).
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

/// `nesting_too_deep` for an INFERRED type deeper than `limit` (checker-v2.md
/// §7.3): the binding `name`, whose type the program
/// built one level at a time — a chain of bindings, each wrapping the one
/// before. No annotation can be written for it (an annotation is read to
/// 512 levels), so the hint is about the program, not the type.
pub fn inferredTooDeep(r: *Report, region: Bir.Inst.Index, name: Symbol.Optional, limit: u32) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    if (name.unwrap()) |s| {
        w.print("The type I inferred for `{s}` is nested more than {d} levels deep", .{ r.env.interner.slice(s), limit }) catch return error.OutOfMemory;
    } else {
        w.print("The type I inferred here is nested more than {d} levels deep", .{limit}) catch return error.OutOfMemory;
    }
    w.writeAll(
        \\, which is more than
        \\I can check.
        \\
        \\I gave up on it, so I cannot check this definition or anything that uses
        \\it.
        \\
        \\Hint: a type this deep is usually built one level at a time, by a chain
        \\of definitions each wrapping the one before. Build the value with a
        \\function that takes the depth as an argument instead, or use a
        \\recursive `type`, whose values can be as deep as they like.
        \\
    ) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .nesting_too_deep, .module = r.module, .region = region, .message = message });
}

/// `rigid_mismatch` for an annotation escape (§8.3; the owner's decision
/// that an escape needs no new code): binding
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

/// Which leg of a `?` failed (§8.6, §15.3; `checker.md` §8.6).
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
/// more than `budget` steps (§9.5): the receiver types it builds
/// nest further than the checker follows, or are finite and simply too
/// many, and the text claims neither. It shares the code with the
/// parser's and the type printer's limit for the same reason they share it:
/// the program is larger than the compiler reads, and naming an inner part
/// fixes it.
pub fn resolutionBudget(r: *Report, region: Bir.Inst.Index, budget: u32) Error!void {
    var buf: [640]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\Working out which methods these declarations call took more than {d}
        \\steps, which is more than I will take for one group of declarations.
        \\
        \\The types their method calls are made on are too many, or too large, for me
        \\to follow: they may keep growing as I follow them, or simply be very big. I
        \\gave up here, so I cannot check this group or anything that uses it. When a
        \\type keeps growing, an annotation with a `where` clause on the declaration
        \\usually stops it.
        \\
    , .{budget}) catch unreachable;
    try r.emitText(.nesting_too_deep, region, null, text);
}

/// `nesting_too_deep` at a use of a derived `eq` or `compare` whose
/// derived-context pass gave up (§11.2's `absent_budget`): its resolution
/// ran out of steps, or a declaration it needed could not be checked
/// nested where the pass stood. It is no answer about the type, so it never
/// reads as "does not support".
pub fn derivedBudget(r: *Report, region: Bir.Inst.Index, shown: Var, method: Symbol) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const m = r.env.interner.slice(method);
    w.print("I could not work out the derived `{s}` of this type:\n\n    ", .{m}) catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, shown, .top) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\Deriving it means checking what its parts need, and here that went deeper
        \\than I will follow: a declaration it reaches would have to be checked nested
        \\inside too many others, or the types its method calls are made on are too
        \\many or keep growing. This is a limit of mine, not a fact about the type.
        \\
        \\Hint: annotate the methods this comparison reaches, so I can use their
        \\annotations instead of checking their bodies here.
        \\
    ) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .nesting_too_deep, .module = r.module, .region = region, .message = message });
}

/// `nesting_too_deep` at a use whose own method's group would be checked
/// here, nested (§10.2), past the budget of the whole frame stack: the use is
/// refused, and the method's own group is checked where it stands.
pub fn nestingAtDemand(r: *Report, region: Bir.Inst.Index, name: Symbol) Error!void {
    const text = r.env.interner.slice(name);
    const message = try std.fmt.allocPrint(r.gpa,
        \\This use of `{s}` needs its type before `{s}` has been checked, and checking
        \\it here would nest one declaration inside another too many times: this is
        \\as deep as I can check.
        \\
        \\Hint: annotate `{s}`, so this use instantiates its annotation instead of
        \\checking its body here.
        \\
    , .{ text, text, text });
    try r.emit(.{ .code = .nesting_too_deep, .module = r.module, .region = region, .message = message });
}

/// `type_mismatch` for a member of a group that is recursive through method
/// calls (§10.4, §10.6), used at a type another use in the group
/// already fixed: inside the group the member has one type (§10.3). `cycle`
/// is the group's cycle, starting and ending at the member whose name is
/// smallest by text, so the text is the same in every declaration order.
pub fn recursiveMethod(r: *Report, region: Bir.Inst.Index, method: Symbol, found: Var, wanted: Var, cycle: []const Symbol) Error!void {
    const interner = r.env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const name = interner.slice(method);
    w.print("`{s}` is used at two types inside a group that is recursive through method calls (", .{name}) catch return error.OutOfMemory;
    for (cycle, 0..) |c, i| {
        if (i != 0) w.writeAll(" → ") catch return error.OutOfMemory;
        w.print("`{s}`", .{interner.slice(c)}) catch return error.OutOfMemory;
    }
    w.writeAll("). Inside the group it has one type:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, found, .top) catch return error.OutOfMemory;
    w.writeAll("\n\nbut this use wants:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, wanted, .top) catch return error.OutOfMemory;
    w.print(
        \\
        \\
        \\Hint: an annotation on `{s}` lets each use instantiate it.
        \\
    , .{name}) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .type_mismatch, .module = r.module, .region = region, .message = message });
}

/// `method_needs_annotation` for §11.2's one surviving case (§21.1):
/// comparing `shown` needs a derived `eq` or `compare` whose context is
/// indexed by a type parameter and depends on `culprit`, an own method
/// without an annotation that is being checked right now. An annotation on
/// `culprit` always lifts it, in either declaration order.
///
/// `schema`: the culprit is a schema whose group is in flight, so its `via`
/// targets — the payloads of the endpoint being compared — are not inferred
/// yet (§11.5), and the type has a parameter (a closed one
/// is deferred): an annotation on the conversion (`conversion`, when it is
/// a top-level value) takes it out of the schema's group.
pub fn derivedNeedsAnnotation(r: *Report, region: Bir.Inst.Index, shown: Var, method: Symbol, schema: bool, culprit: Symbol, conversion: ?Symbol) Error!void {
    const interner = r.env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const m = interner.slice(method);
    const c = interner.slice(culprit);
    w.print("This needs the derived `{s}` of:\n\n    ", .{m}) catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, shown, .top) catch return error.OutOfMemory;
    if (schema) {
        w.print(
            \\
            \\
            \\and that depends on the types the `via` conversions of schema `{s}` produce.
            \\They are still being checked here, together with this comparison, and the
            \\type has a parameter, so I cannot tell yet.
            \\
            \\
        , .{c}) catch return error.OutOfMemory;
        if (conversion) |conv| {
            w.print("Hint: annotate `{s}`, or compare outside the schema's group.\n", .{interner.slice(conv)}) catch return error.OutOfMemory;
        } else {
            w.writeAll("Hint: annotate the conversion, or compare outside the schema's group.\n") catch return error.OutOfMemory;
        }
        const message = try out.toOwnedSlice();
        return r.emit(.{ .code = .method_needs_annotation, .module = r.module, .region = region, .message = message });
    }
    w.print(
        \\
        \\
        \\and that depends on what `{s}` needs of the type's parameter. `{s}` has no
        \\type annotation and is still being checked here, so I cannot tell yet.
        \\
        \\Hint: annotate `{s}`.
        \\
    , .{ c, c, c }) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .method_needs_annotation, .module = r.module, .region = region, .message = message });
}

/// `private_method` at a use that reaches another module's private method
/// (checker-v2.md §11.3: private methods answer dispatch only inside their
/// module). A receiver that IS the private method's type gets the plain
/// text (`x.eq`, `M.T 1 == M.T 11`); one
/// that reaches it through something derived — a wrapper, a tuple, a record,
/// a list, or a type of a third module whose published row says so (§14.2)
/// — says which type inside it holds the private method, and that no
/// comparison outside the declaring module may use it.
pub fn privateMethod(r: *Report, region: Bir.Inst.Index, shown: Var, culprit: Types.TypeId, method: Symbol) Error!void {
    const env = r.env;
    const entry = env.types.entry(culprit);
    switch (env.store.resolvedContent(shown)) {
        .structure => |flat| switch (flat) {
            .app => |a| if (a.type == culprit) return r.privateMethod(region, entry.module, method),
            else => {},
        },
        else => {},
    }
    const interner = env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const module_text = interner.slice(env.graph.moduleName(entry.module));
    const m = interner.slice(method);
    const type_text = interner.slice(entry.name);
    // The shown value renders its types unqualified, so the type is named
    // as it will appear there, with its module beside it.
    w.print("`{s}.{s}` is not `pub`.\n\nThis needs the `{s}` of `{s}`, declared in `{s}`, which is inside:\n\n    ", .{ module_text, m, m, type_text, module_text }) catch return error.OutOfMemory;
    Render.writeVar(w, renderContext(r), &namer, shown, .top) catch return error.OutOfMemory;
    w.print(
        \\
        \\
        \\`{s}` declares `{s}` without `pub`, and it is the `{s}` of every type `{s}`
        \\declares, so it is private to that module: it cannot be used from here,
        \\directly or inside another value.
        \\
        \\Hint: add `pub` to `{s}` in `{s}`.
        \\
    , .{ module_text, m, m, module_text, m, module_text }) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .private_method, .module = r.module, .region = region, .message = message });
}

/// The two types of a failed requirement, when the use decided it: what the
/// requirement asked for and what the method is.
pub const RequirementTypes = struct { wanted: Var, found: Var };

/// `==` (or `compare`) refused because a method a derived answer needs — a
/// payload's own `eq`, or a requirement a payload's method carries in its
/// `where` clause — exists and has the wrong type (static-dispatch-spike.md
/// §10.13). `shown` is the value the author compared, `culprit` the
/// type whose method `need` failed. `types` when the use decided it; a
/// reason read from a context's answer or a published row has none.
/// A payload a derived context's answer names (`Contexts.Answer.payload`,
/// for its message): the type whose payload it is, and its index.
pub const PayloadSite = struct { owner: Types.TypeId, payload: u32 };

/// That payload, read for the message: its type's name, its constructor, and
/// its type over the type's own parameters.
pub const Payload = struct { owner: Symbol, ctor: Symbol, v: Var };

/// `use`: what the program wrote, which the text names
/// (`DispatchTexts.eqName`).
pub fn requirementFailed(r: *Report, region: Bir.Inst.Index, shown: Var, method: Symbol, culprit: Types.TypeId, need: Symbol, types: ?RequirementTypes, payload: ?Payload, use: Diagnostics.Reporter.EqUse) Error!void {
    const env = r.env;
    const interner = env.interner;
    const entry = env.types.entry(culprit);
    const is_eq = method == InternPool.WellKnown.eq.symbol();
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const module_text = interner.slice(env.graph.moduleName(entry.module));
    const type_text = interner.slice(entry.name);
    const need_text = interner.slice(need);
    const eq_op = try r.texts.eqName(r.gpa, use);
    defer r.gpa.free(eq_op);
    if (is_eq) {
        w.print("I cannot compare these values with {s}", .{eq_op}) catch return error.OutOfMemory;
        if (r.texts.eqRequirer(use)) |f| w.print(", which `{s}` requires", .{f}) catch return error.OutOfMemory;
        w.writeAll(":\n\n    ") catch return error.OutOfMemory;
    } else {
        w.print("This type has no `{s}`:\n\n    ", .{interner.slice(method)}) catch return error.OutOfMemory;
    }
    Render.writeVar(w, renderContext(r), &namer, shown, .top) catch return error.OutOfMemory;
    const doing = if (is_eq) "comparing" else "ordering";
    const article = Diagnostics.article(type_text);
    if (types) |t| {
        w.print("\n\nIt holds {s} `{s}`, and {s} that needs the `{s}` of `{s}` at this type:\n\n    ", .{ article, type_text, doing, need_text, type_text }) catch return error.OutOfMemory;
        Render.writeVar(w, renderContext(r), &namer, t.wanted, .top) catch return error.OutOfMemory;
        w.print("\n\nbut `{s}.{s}` is:\n\n    ", .{ module_text, need_text }) catch return error.OutOfMemory;
        Render.writeVar(w, renderContext(r), &namer, t.found, .top) catch return error.OutOfMemory;
        if (DispatchTexts.clashes(&r.texts, entry.module, entry.name, t.found)) {
            w.writeAll("\n\n" ++ clash_hint) catch return error.OutOfMemory;
        } else {
            w.print("\n\nHint: give `{s}.{s}` that type, or compare the values another way.\n", .{ module_text, need_text }) catch return error.OutOfMemory;
        }
    } else {
        if (payload) |p| {
            // Which payload, and what it asks: the constructor and
            // the type it holds, over the type's own parameters.
            w.print(
                \\
                \\
                \\`{s}` gets its {s} from what it holds, and its `{s}` holds:
                \\
                \\
            , .{ interner.slice(p.owner), if (is_eq) eq_op else "ordering", interner.slice(p.ctor) }) catch return error.OutOfMemory;
            w.writeAll("    ") catch return error.OutOfMemory;
            Render.writeVar(w, renderContext(r), &namer, p.v, .top) catch return error.OutOfMemory;
            w.print(
                \\
                \\
                \\{s} that needs the `{s}` of `{s}` at a type that `{s}.{s}` does not
                \\have.
                \\
                \\
            , .{ if (is_eq) "Comparing" else "Ordering", need_text, type_text, module_text, need_text }) catch return error.OutOfMemory;
        } else w.print(
            \\
            \\
            \\It holds {s} `{s}`, and {s} that needs the `{s}` of `{s}` at a type that
            \\`{s}.{s}` does not have.
            \\
            \\
        , .{ article, type_text, doing, need_text, type_text, module_text, need_text }) catch return error.OutOfMemory;
        if (clashesByName(r, culprit, need)) {
            w.writeAll(clash_hint) catch return error.OutOfMemory;
        } else {
            w.print(
                \\Hint: give `{s}.{s}` the type it is asked for, or compare the values another
                \\way.
                \\
            , .{ module_text, need_text }) catch return error.OutOfMemory;
        }
    }
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = if (is_eq) .not_equatable else .no_methods_on_shape, .module = r.module, .region = region, .message = message });
}

/// The specialised method that pins a derived type's argument.
pub const PinCulprit = struct { type_id: Types.TypeId, method: Symbol };

/// `==` (or `compare`) refused because the derived answer's type PINS an
/// argument (checker-v2.md §11.2): a
/// payload's method is specialised (`H.eq : Holder Int, …`), so the type
/// derives only at that argument. `shown` is the value the author compared,
/// `pinned` the type as it derives, `culprit` the method when known;
/// `use` what the program wrote, which the text names.
pub fn pinnedDerived(r: *Report, region: Bir.Inst.Index, shown: Var, method: Symbol, pinned: Var, culprit: ?PinCulprit, use: Diagnostics.Reporter.EqUse) Error!void {
    const env = r.env;
    const interner = env.interner;
    const is_eq = method == InternPool.WellKnown.eq.symbol();
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const eq_op = try r.texts.eqName(r.gpa, use);
    defer r.gpa.free(eq_op);
    const op = if (!is_eq) "`compare`" else eq_op;
    if (is_eq) {
        w.print("I cannot compare these values with {s}", .{op}) catch return error.OutOfMemory;
        if (r.texts.eqRequirer(use)) |f| w.print(", which `{s}` requires", .{f}) catch return error.OutOfMemory;
        w.writeAll(":\n\n    ") catch return error.OutOfMemory;
    } else {
        w.print("This type has no `{s}`:\n\n    ", .{interner.slice(method)}) catch return error.OutOfMemory;
    }
    Render.writeVar(w, renderContext(r), &namer, shown, .top) catch return error.OutOfMemory;
    const owner: []const u8 = switch (env.store.resolvedContent(pinned)) {
        .structure => |flat| switch (flat) {
            .app => |a| interner.slice(env.types.entry(a.type).name),
            else => "it",
        },
        else => "it",
    };
    if (culprit) |c| {
        const entry = env.types.entry(c.type_id);
        const type_text = interner.slice(entry.name);
        const module_text = interner.slice(env.graph.moduleName(entry.module));
        const need_text = interner.slice(c.method);
        w.print(
            \\
            \\
            \\`{s}` gets its {s} from what it holds, and it holds {s} `{s}`, whose
            \\`{s}` is `{s}.{s}`, for one type of `{s}` only. So `{s}` has {s} only as:
            \\
            \\
        , .{ owner, op, Diagnostics.article(type_text), type_text, need_text, module_text, need_text, type_text, owner, op }) catch return error.OutOfMemory;
        w.writeAll("    ") catch return error.OutOfMemory;
        Render.writeVar(w, renderContext(r), &namer, pinned, .top) catch return error.OutOfMemory;
        w.print(
            \\
            \\
            \\Hint: use it at that type, or give `{s}.{s}` a type that works for every
            \\`{s}`.
            \\
        , .{ module_text, need_text, type_text }) catch return error.OutOfMemory;
    } else {
        w.print(
            \\
            \\
            \\`{s}` gets its {s} from what it holds, and one of those has {s} only at
            \\one type. So `{s}` has {s} only as:
            \\
            \\
        , .{ owner, op, op, owner, op }) catch return error.OutOfMemory;
        w.writeAll("    ") catch return error.OutOfMemory;
        Render.writeVar(w, renderContext(r), &namer, pinned, .top) catch return error.OutOfMemory;
        w.writeAll("\n\nHint: use it at that type, or compare the values another way.\n") catch return error.OutOfMemory;
    }
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = if (is_eq) .not_equatable else .no_methods_on_shape, .module = r.module, .region = region, .message = message });
}

const clash_hint =
    \\Hint: this is the module-rule clash of
    \\`docs/design/static-dispatch-spike.md` §11. Move one of the types into a
    \\module of its own, or give the two methods different names.
    \\
;

/// `DispatchTexts.clashes` for a reason read off an answer or a row, which
/// carries no method type: the method `need` of `culprit`'s module is read
/// off that module's own scheme — this module's, or its interface's — and
/// the clash is its first parameter naming ANOTHER type of the module.
fn clashesByName(r: *Report, culprit: Types.TypeId, need: Symbol) bool {
    const env = r.env;
    const entry = env.types.entry(culprit);
    const first: Types.TypeId = if (entry.module == env.module) blk: {
        const bir = env.bir;
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue() or bir.symbol(d.name) != need) continue;
            const v = (if (i < env.decl_scheme.len) env.decl_scheme[i].unwrap() else null) orelse return false;
            const f = Walk.function(env.store, v) orelse return false;
            if (f.params.len == 0) return false;
            break :blk switch (env.store.resolvedContent(f.params[0])) {
                .structure => |flat| switch (flat) {
                    .app => |a| a.type,
                    else => return false,
                },
                else => return false,
            };
        }
        return false;
    } else blk: {
        if (entry.module.int() >= env.interfaces.len) return false;
        const iface = env.iface(entry.module);
        const value = iface.findValue(env.interner, need) orelse return false;
        const body = iface.term(iface.scheme(iface.values[@backingInt(value)].scheme).body);
        if (body.tag != .func) return false;
        const params = iface.range(body.lhs);
        if (params.len == 0) return false;
        const t = iface.term(@fromBackingInt(@intCast(params[0])));
        if (t.tag != .app) return false;
        const refs = env.types.refIds(entry.module);
        if (t.lhs >= refs.len) return false;
        break :blk refs[t.lhs];
    };
    if (first == .none or first == culprit) return false;
    return env.types.entry(first).module == entry.module;
}
