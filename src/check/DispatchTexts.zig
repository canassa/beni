//! The texts of static dispatch and of the obligations
//! (docs/design/static-dispatch-spike.md §10, checker.md §8.4): an unknown or
//! private method, a shape with no methods, the `where` clause messages;
//! `==`, interpolation, tuple indexes and `?` refused; and a cyclic
//! top-level value (checker.md §6.7, whose graph is half the dispatch table).
//! Split out of `Diagnostics.zig` by R12, which had grown past
//! `checker-v2.md` §19.1's 1 500 lines. They are still `Diagnostics.Reporter`'s
//! methods, re-exported there by name, so every caller reads
//! `r.unknownMethod(…)` as before.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Render = @import("Render.zig");
const TypeStore = @import("TypeStore.zig");
const Diagnostics = @import("Diagnostics.zig");

const Reporter = Diagnostics.Reporter;
const Error = Reporter.Error;
const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const ShapeKind = Reporter.ShapeKind;
const EquatableReason = Reporter.EquatableReason;
const max_derived_record_fields = Diagnostics.max_derived_record_fields;
const editDistance = Diagnostics.editDistance;

/// §10.1. `<Type>` has no method called `<m>`.
pub fn unknownMethod(
    r: *Reporter,
    origin: Bir.Inst.Index,
    from_annotation: bool,
    module: Graph.Index,
    type_name: Symbol,
    method: Symbol,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    const module_text = r.env.interner.slice(r.env.graph.moduleName(module));
    const method_text = r.env.interner.slice(method);
    w.print(
        \\`{s}` has no method called `{s}`.
        \\
        \\I resolve `x.{s}` in the module that declares `x`'s type. That module is
        \\`{s}`, and it has no `pub` value called `{s}`.
        \\
    , .{
        r.env.interner.slice(type_name),
        method_text,
        method_text,
        module_text,
        method_text,
    }) catch return error.OutOfMemory;
    if (nearestValue(r, module, method)) |near| {
        w.print("\nHint: did you mean `{s}`?\n", .{r.env.interner.slice(near)}) catch return error.OutOfMemory;
    } else if (module.int() < r.env.interfaces.len) {
        // No near name: say what IS there, which is the other half of
        // §10.1's hint. Capped, because a module's public surface can
        // be a hundred names and a message that scrolls is no message.
        const iface = r.env.iface(module);
        if (iface.values.len != 0) {
            w.print("\nHint: `{s}` exposes:\n\n   ", .{module_text}) catch return error.OutOfMemory;
            const shown = @min(iface.values.len, 8);
            var column: usize = 3;
            for (iface.values[0..shown], 0..) |value, i| {
                const text = r.env.interner.slice(iface.symbol(value.name));
                if (column + text.len + 4 > 64) {
                    w.writeAll("\n   ") catch return error.OutOfMemory;
                    column = 3;
                }
                w.print(" `{s}`{s}", .{ text, if (i + 1 == shown) "" else "," }) catch return error.OutOfMemory;
                column += text.len + 4;
            }
            if (shown < iface.values.len) {
                w.print(" and {d} more", .{iface.values.len - shown}) catch return error.OutOfMemory;
            }
            w.writeAll(".\n") catch return error.OutOfMemory;
        }
    }
    // The SECONDARY half of the two-span rule, as prose: which
    // declaration asked. A `Bir.Inst.Index` from another module means
    // nothing here, so the flag says where the requirement came from and
    // the callee's name says which one it was.
    if (from_annotation) {
        const callee = r.calleeOf(origin);
        if (callee.kind != .anonymous) {
            w.print("\n`{s}` was required by `{s}`'s annotation.\n", .{ method_text, callee.name }) catch return error.OutOfMemory;
        } else {
            w.print("\n`{s}` was required by the annotation this call instantiates.\n", .{method_text}) catch return error.OutOfMemory;
        }
    }
    try r.emit(.unknown_method, origin, &out);
}

/// §10.1, the arm for a receiver whose type nothing ever determines
/// (§7.2, A.66).
///
/// `[] == []` is answerable without knowing the element type, because
/// `eq` and `compare` mean the same thing at every type and no value of
/// an undetermined one ever reaches the function handed over. A name
/// that is NOT well known is not: `Solve.undeterminedTarget` has
/// nothing to hand the slot, and inventing a function for it would be
/// inventing a meaning. It used to return null in silence, which left
/// the site empty, the emitted call one argument short, and the only
/// wall between that and a shipped build was `Lower.evidenceShapeOk`'s
/// `internal` — a compiler bug reported about a program the author
/// merely failed to annotate.
///
/// It is `unknown_method` and not a code of its own: §10's catalogue is
/// closed, and the problem really is that there is no such method to
/// call. What the prose adds is that the RECEIVER, not the name, is
/// what could not be pinned down.
pub fn undeterminedMethodReceiver(
    r: *Reporter,
    region: Bir.Inst.Index,
    method: Symbol,
    kind: TypeStore.Kind,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    const method_text = r.env.interner.slice(method);
    w.print(
        \\I cannot tell which type `{s}` is being asked of here.
        \\
        \\A method is resolved in the module that declares its receiver's type, and
        \\nothing in this program ever says what that type is:
        \\
        \\    {s}
        \\
        \\`eq` and `compare` I could still answer, because they mean the same thing
        \\at every type. `{s}` I cannot — it is declared for some type, and there
        \\is no type here to look it up in.
        \\
        \\Hint: annotate the value at the type you mean.
        \\
    , .{
        method_text,
        switch (kind) {
            .number => "`number` — a literal I never had to choose between `Int` and `Float` for",
            .appendable => "`appendable` — either a `String` or a `List`",
            .any => "a type variable no use of this value determines",
        },
        method_text,
    }) catch return error.OutOfMemory;
    try r.emit(.unknown_method, region, &out);
}

/// The module rule found a method of the right NAME whose type does not
/// fit — which, when the receiver's module declares more than one type,
/// is §11's namespace clash and not a mistake in the call.
///
/// It is `type_mismatch` and not a code of its own: §10's catalogue is
/// closed and the problem really is that two types do not agree. What
/// the prose adds is WHY the compiler looked there.
pub fn methodSignatureMismatch(
    r: *Reporter,
    region: Bir.Inst.Index,
    module: Graph.Index,
    type_name: Symbol,
    method: Symbol,
    found: Var,
    wanted: Var,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const module_text = r.env.interner.slice(r.env.graph.moduleName(module));
    const method_text = r.env.interner.slice(method);
    w.print("`{s}.{s}` is not the method this call needs:\n\n    ", .{ module_text, method_text }) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, found, .top) catch return error.OutOfMemory;
    w.writeAll("\n\nbut the call wants:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, wanted, .top) catch return error.OutOfMemory;
    w.print(
        \\
        \\
        \\A method of `{s}` is a `pub` value of the module that declares it, which is
        \\`{s}`, and a module's `pub` values are ONE namespace — so `{s}` is the
        \\method of every type `{s}` declares.
        \\
        \\Hint: this is the module-rule clash of
        \\`docs/design/static-dispatch-spike.md` §11. Move one of the types into a
        \\module of its own, or give the two methods different names.
        \\
    , .{ r.env.interner.slice(type_name), module_text, method_text, module_text }) catch return error.OutOfMemory;
    try r.emit(.type_mismatch, region, &out);
}

/// §10.2. The value exists, but not as `pub`.
pub fn privateMethod(r: *Reporter, region: Bir.Inst.Index, module: Graph.Index, method: Symbol) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    const module_text = r.env.interner.slice(r.env.graph.moduleName(module));
    const method_text = r.env.interner.slice(method);
    w.print(
        \\`{s}.{s}` is not `pub`.
        \\
        \\`{s}` declares `{s}`, but without `pub` it is private to that module, so
        \\`x.{s}` cannot reach it from here.
        \\
        \\Hint: add `pub` to `{s}` in `{s}`.
        \\
    , .{ module_text, method_text, module_text, method_text, method_text, method_text, module_text }) catch return error.OutOfMemory;
    try r.emit(.private_method, region, &out);
}

/// §10.3. A tuple, a function, `()` or a record that reached discharge
/// rather than the call.
pub fn noMethodsOnShape(r: *Reporter, region: Bir.Inst.Index, method: Symbol, v: Var, shape: ShapeKind) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const method_text = r.env.interner.slice(method);
    if (shape == .too_wide) {
        w.print(
            \\I cannot derive `{s}` for this record: it has more than {d} fields.
            \\
            \\A derived `{s}` on a record is one generated function with a parameter per
            \\field, and past {d} of them a JavaScript engine can run out of stack calling
            \\it, so I stop here rather than build a program that may throw (CK-79).
            \\
            \\Hint: compare by the fields that decide the order, or split the record into
            \\nested records.
            \\
        , .{ method_text, max_derived_record_fields, method_text, max_derived_record_fields }) catch return error.OutOfMemory;
        try r.emit(.no_methods_on_shape, region, &out);
        return;
    }
    const what = switch (shape) {
        .record => "record",
        .tuple => "tuple",
        .unit => "`()`",
        .function => "function",
        .contains_function, .not_orderable, .too_wide, .other => "type",
    };
    if (shape == .contains_function or shape == .not_orderable) {
        w.print("This type has no `{s}`:\n\n    ", .{method_text}) catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
        if (shape == .contains_function) {
            w.writeAll(
                \\
                \\
                \\There is a function inside it, and functions have no ordering — so the
                \\compiler cannot write one for the type that holds them either.
                \\
                \\Hint: order by something you can compare — a name, an id — that sits
                \\next to the function.
                \\
            ) catch return error.OutOfMemory;
        } else {
            // §3.3 and A.54: derivation is structural and recursive, so
            // a type can only be ordered when everything it holds can
            // be. A `foreign type` holds a representation the compiler
            // cannot see, so it can be ordered only by a `pub compare`
            // in its own module (A.50) — and a type wrapping one
            // inherits that.
            w.writeAll(
                \\
                \\
                \\Something it holds has no ordering of its own — a function, or a
                \\`foreign type` whose module declares no `compare` — and I derive an
                \\ordering only over parts that already have one.
                \\
                \\Hint: a `foreign type` is ordered by a `pub compare` in the module that
                \\declares it. Add one there, or pass an ordering function instead.
                \\
            ) catch return error.OutOfMemory;
        }
        try r.emit(.no_methods_on_shape, region, &out);
        return;
    }
    w.print("A {s} has no methods, so I cannot resolve `.{s}` here:\n\n    ", .{ what, method_text }) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\Methods are resolved in the module that declares a type, and this shape is
        \\declared nowhere.
        \\
    ) catch return error.OutOfMemory;
    switch (shape) {
        .record => w.print(
            "\nHint: write `(x.{s}) a` to call the field `{s}`.\n",
            .{ method_text, method_text },
        ) catch return error.OutOfMemory,
        .function => w.writeAll(
            \\
            \\Hint: functions have no ordering. Pass an ordering function instead.
            \\
        ) catch return error.OutOfMemory,
        else => {},
    }
    try r.emit(.no_methods_on_shape, region, &out);
}

/// §10.4. The primary span is the call that needs the method — in the
/// body, or in the CALLER — and never the annotation it came from.
pub fn missingWhereConstraint(
    r: *Reporter,
    origin: Bir.Inst.Index,
    from_annotation: bool,
    var_name: Symbol.Optional,
    method: Symbol,
    fn_var: Var,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const v_text = if (var_name.unwrap()) |n| r.env.interner.slice(n) else "a";
    const method_text = r.env.interner.slice(method);
    w.print("I need `{s}.{s}` here, and the annotation does not allow it.\n\nThis call needs `{s}` to have a method `{s}`:\n\n    {s} : ", .{
        v_text,
        method_text,
        v_text,
        method_text,
        method_text,
    }) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, fn_var, .top) catch return error.OutOfMemory;
    const callee = r.calleeOf(origin);
    if (from_annotation and callee.kind != .anonymous) {
        w.print("\n\nbut `{s}` is any type at all. `{s}` is required by `{s}`.\n", .{
            v_text,
            method_text,
            callee.name,
        }) catch return error.OutOfMemory;
    } else {
        w.print("\n\nbut the annotation says `{s}` is any type at all.\n", .{v_text}) catch return error.OutOfMemory;
    }
    w.print("\nHint: add it to the annotation:\n\n    where {s}.{s} : ", .{ v_text, method_text }) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, fn_var, .top) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    try r.emit(.missing_where_constraint, origin, &out);
}

/// §10.5. One variable carries one constraint per method name (§6.1
/// invariant 3), so two uses at different types have to agree. The
/// primary span is the YOUNGER use — the later occurrence in the file.
pub fn methodConstraintMismatch(
    r: *Reporter,
    region: Bir.Inst.Index,
    other: Bir.Inst.Index,
    method: Symbol,
    younger: Var,
    older: Var,
) Error!void {
    if (r.quiet) return;
    _ = other;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.print("`{s}` is used at two different types here.\n\nHere it is used at:\n\n    ", .{r.env.interner.slice(method)}) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, younger, .top) catch return error.OutOfMemory;
    w.writeAll("\n\nand earlier it was used at:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, older, .top) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\One variable carries one constraint per method name, so these have to agree.
        \\
        \\Hint: give the two uses different type variables, or annotate.
        \\
    ) catch return error.OutOfMemory;
    try r.emit(.method_constraint_mismatch, region, &out);
}

/// §10.8. `a.decode s` where `a` is a type, not a value.
pub fn typeDispatchNeedsAnnotation(
    r: *Reporter,
    region: Bir.Inst.Index,
    var_name: Symbol.Optional,
    method: Symbol,
    fn_var: Var,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const v_text = if (var_name.unwrap()) |n| r.env.interner.slice(n) else "a";
    const method_text = r.env.interner.slice(method);
    w.print(
        \\`{s}` is a type, not a value, and I need to be told what `{s}.{s}` is.
        \\
        \\`{s}` is a type variable of this declaration's annotation, so `{s}.{s}` is a
        \\dispatch on the type. That needs a `where` clause naming it:
        \\
        \\    where {s}.{s} : 
    , .{ v_text, v_text, method_text, v_text, v_text, method_text, v_text, method_text }) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, fn_var, .top) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    try r.emit(.type_dispatch_needs_annotation, region, &out);
}

/// §10.11. The cap of §6.4: an unannotated declaration whose inferred
/// scheme would carry more than `Solver.max_inferred_constraints` of
/// them. `names` is the first few, in the canonical order of §7.2, and
/// only the first few — a message that printed all `count` of them
/// would be the 6.4 kB report 19 §3.1 reached, with a title on it.
pub fn tooManyInferredConstraints(
    r: *Reporter,
    region: Bir.Inst.Index,
    token: u32,
    decl: Symbol,
    count: u32,
    limit: u32,
    names: []const Symbol,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    const name = r.env.interner.slice(decl);
    w.print(
        "`{s}` has no annotation, and the type I inferred for it needs {d} methods.\nI stop at {d}.\n\nThe first {d} are ",
        .{ name, count, limit, names.len },
    ) catch return error.OutOfMemory;
    for (names, 0..) |m, i| {
        if (i != 0) w.writeAll(if (i + 1 == names.len) " and " else ", ") catch return error.OutOfMemory;
        w.print("`{s}`", .{r.env.interner.slice(m)}) catch return error.OutOfMemory;
    }
    w.print(
        \\.
        \\
        \\Each one is an argument I have to pass at every call to `{s}`, and a line in
        \\this module's interface that every importer is checked against. A list this
        \\long is almost always a chain of unannotated helpers, each one inheriting
        \\what the one before it needed.
        \\
        \\Hint: annotate `{s}`. An annotation pins the type, and a `where` clause you
        \\write yourself may name as many methods as you like.
        \\
    , .{ name, name }) catch return error.OutOfMemory;
    try r.emitAt(.too_many_inferred_constraints, region, token, &out);
}

/// §10.9. Informational, `warning`, and — since A.83 — emitted by
/// default, for a module of the ROOT package only: what plan §7's M3
/// churn measurement counts, and what tells the author of an
/// unannotated `pub` declaration that its interface now has a suffix.
pub fn ambiguousMethodReceiver(
    r: *Reporter,
    region: Bir.Inst.Index,
    token: u32,
    decl: Symbol,
    count: u32,
    scheme: Var,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.print(
        "`{s}` is `pub`, has no annotation, and its inferred type carries {d} method constraint(s):\n\n    ",
        .{ r.env.interner.slice(decl), count },
    ) catch return error.OutOfMemory;
    Render.writeScheme(w, r.cx(), &namer, scheme) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\Editing the body can change this, and changing it re-checks every importer.
        \\
        \\Hint: an annotation pins it.
        \\
    ) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    errdefer r.gpa.free(message);
    try r.items.append(r.gpa, .{
        .code = .ambiguous_method_receiver,
        .module = r.env.module,
        .region = region,
        .severity = .warning,
        .token = token,
        .message = message,
    });
}

/// §10.10. A `pub` value of no parameters and a non-function type whose
/// inferred scheme kept a constraint: it would need an evidence
/// parameter, and a value with one is a thunk (§8.1, checker-v2.md §12.5).
pub fn constrainedConstant(
    r: *Reporter,
    region: Bir.Inst.Index,
    token: u32,
    decl: Symbol,
    var_name: Symbol.Optional,
    method: Symbol,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    const v_text = if (var_name.unwrap()) |n| r.env.interner.slice(n) else "a";
    w.print(
        \\`{s}` takes no arguments but needs `{s}.{s}`.
        \\
        \\A value that needs a method has to receive it, which would make `{s}` a
        \\function of one hidden argument, and that is not what its type says.
        \\
        \\Hint: give it a parameter, annotate it at a concrete type, or write the `where`
        \\clause in its annotation.
        \\
    , .{ r.env.interner.slice(decl), v_text, r.env.interner.slice(method), r.env.interner.slice(decl) }) catch return error.OutOfMemory;
    try r.emitAt(.constrained_constant, region, token, &out);
}

/// The `pub` value of `module` closest to `name` by edit distance, for
/// §10.1's did-you-mean.
fn nearestValue(r: *Reporter, module: Graph.Index, name: Symbol) ?Symbol {
    if (module.int() >= r.env.interfaces.len) return null;
    const iface = r.env.iface(module);
    const target = r.env.interner.slice(name);
    if (target.len < 3) return null;
    var best: ?Symbol = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (iface.values) |value| {
        const symbol = iface.symbol(value.name);
        const candidate = r.env.interner.slice(symbol);
        const d = editDistance(r.env.scratch, target, candidate) catch continue;
        if (d < best_distance) {
            best_distance = d;
            best = symbol;
        }
    }
    if (best_distance > 2) return null;
    return best;
}

pub fn notEquatable(r: *Reporter, region: Bir.Inst.Index, v: Var, reason: EquatableReason) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.writeAll("I cannot compare these values with `==`:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
    switch (reason) {
        .function => w.writeAll(
            \\
            \\
            \\There is a function in there, and comparing functions is not decidable:
            \\deciding whether two functions agree on every input is the halting problem.
            \\
            \\Hint: compare the values the functions produce, or store something you can
            \\compare — a name, an id — next to the function.
            \\
        ) catch return error.OutOfMemory,
        .opaque_type => w.writeAll(
            \\
            \\
            \\That type does not support `==`.
            \\
            \\Hint: a `type` is comparable exactly when everything it can hold is, so a
            \\function anywhere inside it rules the whole type out. A `foreign type` is
            \\comparable only when it is declared `equatable`.
            \\
        ) catch return error.OutOfMemory,
        .rigid_variable => w.writeAll(
            \\
            \\
            \\The annotation says ANY type can flow through here, and not every type can
            \\be compared — a function cannot.
            \\
            \\Hint: make the annotation concrete, or take an equality function as an
            \\argument instead of using `==`.
            \\
        ) catch return error.OutOfMemory,
        .too_wide => w.print(
            \\
            \\
            \\It has more than {d} fields. `==` on a record calls one generated function
            \\with a parameter per field, and past {d} of them a JavaScript engine can run
            \\out of stack calling it, so I stop here rather than build a program that may
            \\throw (CK-79).
            \\
            \\Hint: `Basics.eq a b` compares records structurally, field by field, with no
            \\limit on width — it does not call a custom `eq` of a type inside them.
            \\
        , .{ max_derived_record_fields, max_derived_record_fields }) catch return error.OutOfMemory,
    }
    try r.emit(.not_equatable, region, &out);
}

pub fn notInterpolatable(r: *Reporter, region: Bir.Inst.Index, v: Var) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.writeAll("I cannot put this value into a string:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
    w.writeAll("\n\n`${…}` takes a `String`, `Int`, `Float`, `Bool` or `Char`.\n") catch return error.OutOfMemory;
    if (r.isFunction(v)) {
        // A function in an interpolation is a missing argument nine
        // times out of ten, and telling someone who wrote
        // `${String.fromInt}` to "use String.fromInt" is no help at all.
        w.writeAll(
            \\
            \\Hint: this is a FUNCTION, so it is probably missing an argument — did you
            \\mean to apply it to something?
            \\
        ) catch return error.OutOfMemory;
    } else {
        w.writeAll(
            \\
            \\Hint: convert it first — `String.fromInt`, `String.fromFloat`, or a function
            \\of your own that produces a `String`.
            \\
        ) catch return error.OutOfMemory;
    }
    try r.emit(.not_interpolatable, region, &out);
}

pub fn ambiguousInterpolation(r: *Reporter, region: Bir.Inst.Index) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    out.writer.writeAll(
        \\I cannot tell what type this interpolated value has.
        \\
        \\`${…}` only accepts `String`, `Int`, `Float`, `Bool` and `Char`, and I have to
        \\know which one it is here — the choice cannot be left to the caller.
        \\
        \\Hint: add a type annotation that pins it down.
        \\
    ) catch return error.OutOfMemory;
    try r.emit(.ambiguous_interpolation, region, &out);
}

pub fn ambiguousTuple(r: *Reporter, region: Bir.Inst.Index, index: u32) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    out.writer.print(
        \\I cannot tell what this `.{d}` is indexing into.
        \\
        \\A tuple index needs a tuple whose size I already know, and a type variable
        \\could still turn out to be anything.
        \\
        \\Hint: add a type annotation that says which tuple this is.
        \\
    , .{index}) catch return error.OutOfMemory;
    try r.emit(.ambiguous_tuple, region, &out);
}

pub fn tupleIndexOutOfRange(r: *Reporter, region: Bir.Inst.Index, index: u32, arity: u32, v: Var) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.print("This tuple has {d} elements, so there is no `.{d}`:\n\n    ", .{ arity, index }) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
    if (arity == 0) {
        w.writeAll("\n\nIt has no elements to index at all.\n") catch return error.OutOfMemory;
    } else {
        w.print("\n\nThe elements are `.0` through `.{d}`.\n", .{arity - 1}) catch return error.OutOfMemory;
    }
    try r.emit(.tuple_index_out_of_range, region, &out);
}

pub fn notATuple(r: *Reporter, region: Bir.Inst.Index, index: u32, v: Var) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.print("I cannot take `.{d}` of this, because it is not a tuple:\n\n    ", .{index}) catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, v, .top) catch return error.OutOfMemory;
    w.writeAll("\n\nHint: `.0`, `.1`, … work on tuples. Records are indexed by field name.\n") catch return error.OutOfMemory;
    try r.emit(.not_a_tuple, region, &out);
}

pub fn tryShape(r: *Reporter, region: Bir.Inst.Index, scrutinee: Var, enclosing: Var) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    w.writeAll("`?` needs a `Result` or a `Maybe`, and this is neither:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, scrutinee, .top) catch return error.OutOfMemory;
    w.writeAll("\n\nThe enclosing definition returns:\n\n    ") catch return error.OutOfMemory;
    Render.writeVar(w, r.cx(), &namer, enclosing, .top) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\Hint: `e?` unwraps an `Ok`/`Just` and returns the `Err`/`Nothing` from the
        \\enclosing definition, so both have to be the same shape. There is no
        \\conversion between `Result` and `Maybe`.
        \\
    ) catch return error.OutOfMemory;
    try r.emit(.try_shape, region, &out);
}

/// A top-level value the module cannot initialise, because computing it
/// needs its own result (`language.md` §7, `checker.md` §6.7).
///
/// `path` is the rest of the circle after `name`, in the order it is
/// walked, so the printed line always starts and ends at `name`;
/// `through` is the first step on it that DEFERS — a function, or a
/// value whose right-hand side is a lambda — when there is one, because
/// "these three values need each other" and "this value names a function
/// that reads it back" are the same defect and do not read the same way.
/// The sentence it earns says what naming one costs, which is the half
/// of the rule an author cannot guess.
///
/// The region is the declaration's BODY and the underline is its NAME:
/// the mistake is the definition as a whole, and no single reference in
/// it is more to blame than another.
pub fn cyclicValue(
    r: *Reporter,
    region: Bir.Inst.Index,
    token: u32,
    name: []const u8,
    path: []const []const u8,
    through: ?[]const u8,
    /// A value on the circle that takes evidence and is therefore
    /// computed when first used with its evidence (CK-85), not once at load
    /// (`Convention`'s `thunk` and `applied`, checker-v2.md §12.5).
    per_use: ?[]const u8,
) Error!void {
    if (r.quiet) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    w.print(
        \\`{s}` is defined in terms of itself:
        \\
        \\    {s}
    , .{ name, name }) catch return error.OutOfMemory;
    for (path) |step| w.print(" → {s}", .{step}) catch return error.OutOfMemory;
    w.print(
        \\ → {s}
        \\
    , .{name}) catch return error.OutOfMemory;
    if (per_use) |v| {
        w.print(
            \\
            \\A top-level value is computed from its own initialiser: once, when the module
            \\is loaded, or — for one with a `where` clause, like `{s}` — when it is first
            \\used with its evidence. Either way there is no order in which I can compute
            \\these: each of them is already needed before it has a value.
            \\
        , .{v}) catch return error.OutOfMemory;
    } else {
        w.writeAll(
            \\
            \\A top-level value is computed once, when the module is loaded, so there is no
            \\order in which I can compute these: each of them is already needed before it
            \\has a value.
            \\
        ) catch return error.OutOfMemory;
    }
    if (through) |f| {
        w.print(
            \\
            \\Naming `{s}` counts as calling it, so whatever its body reads is read
            \\while `{s}` is being computed.
            \\
        , .{ f, name }) catch return error.OutOfMemory;
    }
    w.writeAll(
        \\
        \\Hint: a FUNCTION may be recursive, because its body runs when it is called and
        \\not when the module loads. Give one of these a parameter, or compute it from
        \\something outside the circle.
        \\
    ) catch return error.OutOfMemory;
    try r.emitAt(.cyclic_value, region, token, &out);
}
