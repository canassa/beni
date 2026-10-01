//! The checker's prose (docs/design/checker.md §8).
//!
//! Register and structure follow Elm's `Reporting/Error/Type.hs`: a title,
//! what the compiler was looking at, the two types one under the other, and
//! a hint where there is a known one. The hints are Elm's, minus the ones
//! for features beni does not have: `number` against `String`, the missing
//! `toFloat`, function equality (a compile error here rather than a runtime
//! crash, `fast-compiler.md` §3.1 point 5), and record field typos by edit
//! distance. Ordering text is no longer among them: `<` is the receiver's
//! `compare` (static-dispatch-spike.md §3.1), so `"a" < "b"` compiles.
//!
//! **A message is built when it is reported, not later.** The types are
//! rendered out of the store into a string here and now, because the store
//! is released as soon as the module's interface has been extracted and a
//! `Var` means nothing afterwards. That keeps the whole rendering
//! subsystem — including fresh-variable naming — off the happy path, which
//! is the property research/02 §6 says Elm's good messages cost nothing for.
//!
//! A diagnostic carries a Bir instruction as its region and nothing else; a
//! line and column are looked up by `Session` at report time from the token
//! that instruction came from (checker.md §6.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const EnvFile = @import("Env.zig");
const Resolve = @import("Resolve.zig");
const Env = EnvFile.Env;
const Render = @import("Render.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");
const DispatchTexts = @import("DispatchTexts.zig");
const CallStyle = @import("CallStyle.zig");
const PatternTexts = @import("PatternTexts.zig");
const StatementTexts = @import("StatementTexts.zig");

const Diagnostics = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
const Category = @import("Category.zig").Category;
const MarkupTexts = @import("MarkupTexts.zig");

/// A checker diagnostic, message already rendered.
pub const Item = struct {
    code: diagnostic.Code,
    module: Graph.Index,
    /// The instruction to point at; `Session` turns it into a span. This is
    /// the PRIMARY span, and for the three codes that carry two
    /// (static-dispatch-spike.md §10 preamble, A.37) it is the obligation's
    /// `origin` — the call the author wrote — never the annotation the
    /// requirement came from.
    region: Bir.Inst.Index,
    /// `warning` only for `ambiguous_method_receiver` (§10.9); a warning
    /// never changes the exit code.
    severity: diagnostic.Severity = .@"error",
    /// The token to underline, when it is not the one `region`'s
    /// instruction came from. A message ABOUT a declaration —
    /// `ambiguous_method_receiver`, `constrained_constant` — points at its
    /// NAME, and no instruction carries that token.
    token: ?u32 = null,
    /// Owned by the session allocator.
    message: []const u8,
};

/// What a call's callee is, for the sentence that names it.
pub const Callee = struct {
    kind: Kind,
    name: []const u8,

    pub const Kind = enum { function, value, ctor, operator, anonymous };

    pub const anonymous: Callee = .{ .kind = .anonymous, .name = "" };
};

/// The widest record `==` or `compare` may DERIVE a function for.
/// A derived record function takes one evidence parameter per field
/// (static-dispatch-spike.md §9), and a JavaScript call with tens of
/// thousands of arguments overflows the engine's stack: V8 threw at 60 000
/// under Node 24, and JavaScriptCore and SpiderMonkey set their own limits.
/// 4 096 is far below any of them. Lifting it needs a derived record function
/// that takes its evidence as ONE value (an array).
pub const max_derived_record_fields = 4096;

pub const Reporter = struct {
    gpa: Allocator,
    env: *Env,
    /// `Report`'s staging list. The reporter never drops a message itself:
    /// `Report.emit` is the one place a quiet module's are dropped
    /// (checker-v2.md §15.1).
    items: *std.ArrayList(Item),
    /// The `where` clause a `.where_clause` unification is checking: set by
    /// the resolver around that one unification, so the message can name
    /// the clause after its receiver is bound (static-dispatch-spike.md
    /// §10.13).
    clause: ?Clause = null,
    pub const Error = Allocator.Error;
    pub const Clause = struct { variable: Symbol.Optional, method: Symbol };

    pub fn cx(r: *const Reporter) Render.Context {
        return .{ .store = r.env.store, .types = r.env.types, .interner = r.env.interner };
    }

    pub fn emit(r: *Reporter, code: diagnostic.Code, region: Bir.Inst.Index, out: *std.Io.Writer.Allocating) Error!void {
        const message = try out.toOwnedSlice();
        errdefer r.gpa.free(message);
        try r.items.append(r.gpa, .{ .code = code, .module = r.env.module, .region = region, .message = message });
    }

    /// `emit`, underlining `token` rather than `region`'s own.
    pub fn emitAt(r: *Reporter, code: diagnostic.Code, region: Bir.Inst.Index, token: u32, out: *std.Io.Writer.Allocating) Error!void {
        const message = try out.toOwnedSlice();
        errdefer r.gpa.free(message);
        try r.items.append(r.gpa, .{
            .code = code,
            .module = r.env.module,
            .region = region,
            .token = token,
            .message = message,
        });
    }

    pub fn writer(r: *Reporter) std.Io.Writer.Allocating {
        return .init(r.gpa);
    }

    // ---- The two-types layout -------------------------------------------

    /// `type_mismatch` and its rigid twin: the sentence the category picks,
    /// then the two types, then a hint if there is a known one.
    pub fn mismatch(
        r: *Reporter,
        region: Bir.Inst.Index,
        category: Category,
        expected: Var,
        actual: Var,
        rigid: ?Rigid,
    ) Error!void {
        if (category.tag == .where_clause and rigid == null) {
            if (r.clause) |c| return DispatchTexts.whereClauseMismatch(r, region, c, expected, actual);
        }
        if (category.tag == .statement) return StatementTexts.statementNotUnit(r, region, category, actual);
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        // Two types of one name are told apart by their modules.
        try Render.qualifyClashes(&namer, r.cx(), &.{ expected, actual });

        // A field access whose record HAS the field: the field's type is
        // what failed, so the message shows it against the type the code
        // needs, rather than saying the record lacks the field.
        if (category.tag == .field_access and category.index != Category.no_field) {
            const name: InternPool.Symbol = @enumFromInt(category.index);
            if (recordField(r.env.store, actual, name)) |found| if (recordField(r.env.store, expected, name)) |wanted| {
                const text = r.fieldText(category.index);
                w.print("This record has {s} `{s}` field, but not of the type I need:\n\n", .{ article(text), text }) catch return error.OutOfMemory;
                w.print("The `{s}` field is:\n\n    ", .{text}) catch return error.OutOfMemory;
                Render.writeVar(w, r.cx(), &namer, found, .top) catch return error.OutOfMemory;
                w.writeAll("\n\nBut I need it to be:\n\n    ") catch return error.OutOfMemory;
                Render.writeVar(w, r.cx(), &namer, wanted, .top) catch return error.OutOfMemory;
                w.writeByte('\n') catch return error.OutOfMemory;
                if (rigid) |rg| {
                    try r.rigidHint(w, &namer, rg);
                    try r.emit(.rigid_mismatch, region, &out);
                    return;
                }
                try r.typeHint(w, &namer, .{ .tag = .general }, wanted, found);
                try r.emit(.type_mismatch, region, &out);
                return;
            };
        }

        const lines = r.categoryLines(category, region);
        w.print("{s}\n\n", .{lines.intro}) catch return error.OutOfMemory;
        w.print("{s}\n\n    ", .{lines.found}) catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
        w.print("\n\n{s}\n\n    ", .{lines.wanted}) catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, expected, .top) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;

        if (rigid) |rg| {
            try r.rigidHint(w, &namer, rg);
            try r.emit(.rigid_mismatch, region, &out);
            return;
        }
        if (category.tag == .schema_conversion) {
            try r.emit(.schema_conversion_mismatch, region, &out);
            return;
        }
        // **A.30's boundary, said out loud.** A `let` binding that is not
        // generalised over a constrained variable (a dot-call's own
        // requirement, or a value binding: checker-v2.md §8.4) meets a
        // second use at another type here, as an ordinary
        // mismatch — and the numeric hints below would tell the author to
        // check their arithmetic. This one names the binding and the
        // constraint instead, and says what to do.
        if (try r.monomorphicLetHint(w, category)) {
            try r.emit(.type_mismatch, region, &out);
            return;
        }
        // `xs.length` and `f(a, b)` (language.md §12.5).
        if (try CallStyle.mismatchHint(r, w, region, category, actual)) {
            try r.emit(.type_mismatch, region, &out);
            return;
        }
        try r.typeHint(w, &namer, category, expected, actual);
        try r.emit(.type_mismatch, region, &out);
    }

    /// The A.30 hint, when the callee of this argument is a `let` binding
    /// whose type carries a method constraint. False when it is not, and
    /// then the ordinary hints apply.
    fn monomorphicLetHint(r: *Reporter, w: *std.Io.Writer, category: Category) Error!bool {
        if (category.tag != .call_arg) return false;
        const call = category.owner.unwrap() orelse return false;
        const bir = r.env.bir;
        if (call.int() >= bir.insts.len) return false;
        const callee: Bir.Inst.Index = switch (bir.instTag(call)) {
            .call => @enumFromInt(bir.instData(call).lhs),
            else => return false,
        };
        if (callee.int() >= bir.insts.len or bir.instTag(callee) != .local) return false;
        const index = bir.instData(callee).lhs;
        const v = r.env.localVar(index) orelse return false;
        const found = (try r.monomorphicMethod(v)) orelse return false;
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
                \\Hint: `{s}` is a `let` binding whose type needs {s} `{s}` method only
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
                \\Hint: `{s}` is a `let` value, with no parameters, whose type needs {s}
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
                \\Hint: `{s}` is a `let` binding whose type needs more than {d} methods, one
                \\of them {s} `{s}` method, and past that many a `let` binding is not
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
                \\Hint: `{s}` is a `let` binding whose type needs {s} `{s}` method, and such a
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

    /// Which side of a failed unification was the annotation's promise.
    pub const Rigid = struct {
        /// The rigid variable, for its name.
        v: Var,
        /// What the code wanted it to be instead.
        against: Var,
    };

    fn rigidHint(r: *Reporter, w: *std.Io.Writer, namer: *Render.Namer, rg: Rigid) Error!void {
        const root = r.env.store.find(rg.v);
        const name: []const u8 = switch (r.env.store.content(root)) {
            .rigid => |flags| if (flags.name.unwrap()) |s| r.env.interner.slice(s) else "a",
            else => "a",
        };
        var buffer: std.Io.Writer.Allocating = .init(r.gpa);
        defer buffer.deinit();
        Render.writeVar(&buffer.writer, r.cx(), namer, rg.against, .top) catch return error.OutOfMemory;
        w.print(
            \\
            \\Hint: your annotation uses the type variable `{s}`, which means ANY type can
            \\flow through, but the code specifically wants `{s}`. Maybe the annotation
            \\should be more specific, or maybe the code should be more general?
            \\
        , .{ name, buffer.written() }) catch return error.OutOfMemory;
    }

    pub const Lines = struct { intro: []const u8, found: []const u8, wanted: []const u8 };

    /// What the compiler was looking at, in Elm's words. The strings are
    /// built into `scratch` because several of them name something.
    fn categoryLines(r: *Reporter, category: Category, region: Bir.Inst.Index) Lines {
        const scratch = r.env.scratch;
        switch (category.tag) {
            .annotation => return .{
                .intro = "Something is off with the body of this definition:",
                .found = "The body is:",
                .wanted = "But the type annotation says it should be:",
            },
            .let_annotation => return .{
                .intro = "Something is off with the body of this `let` definition:",
                .found = "The body is:",
                .wanted = "But its type annotation says it should be:",
            },
            .call_arg => {
                const callee = r.calleeOf(category.owner.unwrap() orelse region);
                // A list written with a spread IS these calls (language.md
                // §6.8), so the sentence says which spelling it was.
                const is = struct {
                    fn name(c: Callee, n: []const u8) bool {
                        return c.kind == .function and std.mem.eql(u8, c.name, n);
                    }
                };
                const spelled: []const u8 = if (is.name(callee, "List.cons"))
                    " — `[ x, ...xs ]` is `List.cons x xs`"
                else if (is.name(callee, "List.append")) " — `[ ...xs, y ]` is `List.append xs [ y ]`" else "";
                return .{
                    .intro = std.fmt.allocPrint(scratch, "The {s} argument to {s} is not what I expect{s}:", .{
                        ordinal(scratch, category.index),
                        calleeReference(scratch, callee),
                        spelled,
                    }) catch "This argument is not what I expect:",
                    .found = "This argument is:",
                    .wanted = std.fmt.allocPrint(scratch, "But {s} needs the {s} argument to be:", .{
                        calleeReference(scratch, callee),
                        ordinal(scratch, category.index),
                    }) catch "But it needs it to be:",
                };
            },
            // The 1st element can only have failed against the list's
            // CONTEXT: the elements are checked left to right against one
            // element type, and it has no previous ones (checker.md §8.7).
            .list_entry => if (category.index == 1) return .{
                .intro = "The 1st element of this list is not what the list needs:",
                .found = "The 1st element is:",
                .wanted = "But this list needs its elements to be:",
            } else return .{
                .intro = std.fmt.allocPrint(scratch, "The {s} element of this list does not match all the previous elements:", .{ordinal(scratch, category.index)}) catch "This list is not consistent:",
                .found = std.fmt.allocPrint(scratch, "The {s} element is:", .{ordinal(scratch, category.index)}) catch "This element is:",
                .wanted = "But all the previous elements in the list are:",
            },
            .case_branch => return .{
                .intro = std.fmt.allocPrint(scratch, "The {s} branch of this `case` does not match all the previous branches:", .{ordinal(scratch, category.index)}) catch "This `case` is not consistent:",
                .found = std.fmt.allocPrint(scratch, "The {s} branch is:", .{ordinal(scratch, category.index)}) catch "This branch is:",
                .wanted = "But all the previous branches result in:",
            },
            .case_pattern => return .{
                .intro = "This pattern cannot match the value this `case` is looking at:",
                .found = "The pattern matches values of type:",
                .wanted = "But the value being matched is:",
            },
            .record_field => return .{
                .intro = std.fmt.allocPrint(scratch, "The `{s}` field of this record is not what I expect:", .{r.fieldText(category.index)}) catch "This record field is not what I expect:",
                .found = "The value is:",
                .wanted = "But it needs to be:",
            },
            .record_update => return .{
                .intro = if (category.index == Category.no_field)
                    "This record does not have the fields this update is changing:"
                else
                    std.fmt.allocPrint(scratch, "The `{s}` field of this update is not what I expect:", .{r.fieldText(category.index)}) catch "This update is not what I expect:",
                .found = if (category.index == Category.no_field) "The record is:" else "The new value is:",
                .wanted = if (category.index == Category.no_field) "But the update needs it to have:" else "But the field holds:",
            },
            .field_access => return .{
                .intro = std.fmt.allocPrint(scratch, "This is not a record with {s} `{s}` field:", .{ article(r.fieldText(category.index)), r.fieldText(category.index) }) catch "This is not a record with that field:",
                .found = "It is:",
                .wanted = "But I need a record like:",
            },
            .interp_part => return .{
                .intro = "This interpolated value cannot be put into a string:",
                .found = "It is:",
                .wanted = "But I need:",
            },
            .tuple_element => return .{
                .intro = std.fmt.allocPrint(scratch, "The {s} element of this tuple is not what I expect:", .{ordinal(scratch, category.index)}) catch "This tuple element is not what I expect:",
                .found = "It is:",
                .wanted = "But I need:",
            },
            .schema_conversion => return .{
                .intro = std.fmt.allocPrint(scratch, "The conversion for the `{s}` schema field does not connect its program endpoint:", .{r.fieldText(category.index)}) catch "This schema conversion does not connect its program endpoint:",
                .found = "The conversion has type:",
                .wanted = "But this field needs:",
            },
            // Markup names the attribute, event or form it was looking at.
            .markup_attribute, .markup_list_attribute, .markup_handler, .markup_form, .markup_row, .markup_child, .markup_children => return MarkupTexts.categoryLines(scratch, r.env.interner, category),
            // `.where_clause` (a `where` clause's method type against the
            // method it resolved to) keeps the general lines.
            .try_value, .pattern, .ctor_arg, .destructure, .statement, .general, .where_clause => return .{
                .intro = "Something is off here:",
                .found = "This is:",
                .wanted = "But I need:",
            },
        }
    }

    /// The field name a `record_field`/`record_update`/`field_access`
    /// category carries, or "" when the category is about the record as a
    /// whole. The sentinel is `Category.no_field` and NOT zero: `Symbol` 0
    /// is `InternPool.WellKnown`'s first entry, which is `main` — so a
    /// record field actually named `main`, the likeliest field name there
    /// is in an Elm-like program, used to render as an empty name.
    fn symbolTextLessThan(interner: *const InternPool.Global, a: Symbol, b: Symbol) bool {
        return std.mem.lessThan(u8, interner.slice(a), interner.slice(b));
    }

    fn fieldText(r: *const Reporter, packed_symbol: u32) []const u8 {
        if (packed_symbol == Category.no_field) return "";
        return r.env.interner.slice(@enumFromInt(packed_symbol));
    }

    // ---- Hints -----------------------------------------------------------

    /// The known hints of checker.md §8, chosen from the pair of types and
    /// from what the compiler was looking at.
    fn typeHint(r: *Reporter, w: *std.Io.Writer, namer: *Render.Namer, category: Category, expected: Var, actual: Var) Error!void {
        // Two functions of different arity where one was wanted is the
        // missing-argument shape again, one level in: §8.3 catches it at a
        // CALL, and this is the same mistake passed as an argument.
        const wanted_arrows = r.paramCount(expected);
        const found_arrows = r.paramCount(actual);
        // An Elm curried annotation over a definition of that many
        // parameters (checker.md §8.7).
        if ((category.tag == .annotation or category.tag == .let_annotation) and
            r.env.store.isCurried(expected, found_arrows))
        {
            w.writeAll(
                \\
                \\Hint: this annotation is in Elm's curried form. A beni function takes all
                \\of its arguments at once, and its type lists them before one arrow:
                \\
                \\
            ) catch return error.OutOfMemory;
            w.writeAll("    ") catch return error.OutOfMemory;
            var i: u32 = 0;
            while (i < found_arrows) : (i += 1) {
                if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                Render.writeVar(w, r.cx(), namer, r.env.store.curriedParam(expected, i), .arg) catch return error.OutOfMemory;
            }
            w.writeAll(" -> ") catch return error.OutOfMemory;
            Render.writeVar(w, r.cx(), namer, r.env.store.curriedResult(expected, found_arrows), .top) catch return error.OutOfMemory;
            w.writeByte('\n') catch return error.OutOfMemory;
            return;
        }
        if (wanted_arrows > 0 and found_arrows > 0 and wanted_arrows != found_arrows) {
            w.print(
                \\
                \\Hint: I need a function of {s}, and this one takes {s}.
                \\
            , .{ plural(r.env.scratch, wanted_arrows, "argument"), plural(r.env.scratch, found_arrows, "argument") }) catch return error.OutOfMemory;
            try r.leftToRightHint(w, category);
            return;
        }
        const wk = r.env.types.well_known;
        const e = r.primitiveOf(expected);
        const a = r.primitiveOf(actual);
        const e_kind = r.kindOf(expected);
        const a_kind = r.kindOf(actual);

        // Int vs Float, in either direction: Elm's implicit-casts note.
        if ((e == wk.int and a == wk.float) or (e == wk.float and a == wk.int)) {
            w.writeAll(
                \\
                \\Hint: beni does not implicitly convert `Int` to `Float`. Use `toFloat` to go
                \\one way and `round`, `floor`, `ceiling` or `truncate` to go the other.
                \\
            ) catch return error.OutOfMemory;
            return;
        }
        // `Int` and `Int32` are different types on purpose
        // (`fast-compiler.md` §3.1), so the conversion is written out. The
        // same shape as the `Int`/`Float` note above, and for the same
        // reason: the reader's next question is "how do I get from one to
        // the other".
        if ((r.isCoreInt32(expected) and (a == wk.int or a_kind == .number)) or
            (r.isCoreInt32(actual) and (e == wk.int or e_kind == .number)))
        {
            w.writeAll(
                \\
                \\Hint: beni does not implicitly convert between `Int` and `Int32`. Use
                \\`Int32.fromInt` to go one way, and `Int32.toInt` or `Int32.toUnsignedInt`
                \\to go the other.
                \\
            ) catch return error.OutOfMemory;
            return;
        }
        // A number where a String was wanted, or the reverse.
        if (e == wk.string and (a == wk.int or a_kind == .number)) {
            w.writeAll(to_string_hint) catch return error.OutOfMemory;
            return;
        }
        // Arithmetic only: `<` and the other three orderings are the
        // receiver's `compare` since static dispatch (spike §3.1), so
        // `"a" < "b"` compiles and neither they nor `String.compare`
        // belong in a hint about numbers.
        if (a == wk.string and (e == wk.int or e_kind == .number)) {
            // The numbers-only sentence only for an arithmetic operator's
            // operand (checker.md §8.7).
            if (r.arithmeticOperand(category)) {
                w.writeAll(
                    \\
                    \\Hint: `+`, `-`, `*` and `/` work on numbers only. To read a number out of
                    \\text use `String.toInt` or `String.toFloat`.
                    \\
                ) catch return error.OutOfMemory;
            } else {
                w.writeAll(read_number_hint) catch return error.OutOfMemory;
            }
            return;
        }
        if (e == wk.bool or a == wk.bool) {
            if (e != a and (e != .none or a != .none)) {
                w.writeAll(
                    \\
                    \\Hint: beni has no "truthiness" — numbers, strings and lists are never
                    \\automatically a `Bool`. Do the conversion explicitly.
                    \\
                ) catch return error.OutOfMemory;
                return;
            }
        }
        // An Elm-ordered call (§12.5); a misplaced function keeps the hint below.
        if (!(r.isFunction(actual) and !r.isFunction(expected))) {
            if (try CallStyle.elmOrderHint(r, w, category, actual)) return;
        }
        // A function where a value was wanted is nearly always a missing
        // argument; §8.3 catches it at a call, and this is the rest.
        if (r.isFunction(actual) and !r.isFunction(expected) and !r.isFlex(expected)) {
            if (r.subjectFirstSlot(category, actual)) |slot| {
                w.print(
                    \\
                    \\Hint: this function looks like it belongs in the {s} argument, which takes
                    \\one. beni's functions take their subject first — `List.map list f`, where
                    \\Elm writes `List.map f list` — so the arguments may be the wrong way round.
                    \\
                , .{ordinal(r.env.scratch, slot)}) catch return error.OutOfMemory;
                return;
            }
            if (try DispatchTexts.negativeArgumentHint(r, w, category)) return;
            w.writeAll(
                \\
                \\Hint: this is a function, so it may be missing an argument.
                \\
            ) catch return error.OutOfMemory;
        }
        try r.leftToRightHint(w, category);
    }

    /// Elm's `badFlexSuper`/`problemToHint` for a number that has to become
    /// a `String`, and for a `String` that has to become a number
    /// (checker.md §8.7).
    const to_string_hint =
        \\
        \\Hint: want to turn a number into a `String`? Use `String.fromInt` or
        \\`String.fromFloat`.
        \\
    ;
    const read_number_hint =
        \\
        \\Hint: to read a number out of text, use `String.toInt` or `String.toFloat`.
        \\
    ;

    /// Whether the mismatch is an operand of an arithmetic operator — the
    /// one place the numbers-only hint is true (checker.md §8.7).
    fn arithmeticOperand(r: *const Reporter, category: Category) bool {
        if (category.tag != .call_arg) return false;
        const call = category.owner.unwrap() orelse return false;
        const callee = r.calleeOf(call);
        if (callee.kind != .operator) return false;
        for ([_][]const u8{ "+", "-", "*", "/", "//", "^" }) |op| {
            if (std.mem.eql(u8, callee.name, op)) return true;
        }
        return false;
    }

    /// The 1-based position of another parameter of this call that is a
    /// function of as many arguments as `actual`, when `actual` — a function
    /// — was passed where a non-function is wanted: Elm's argument
    /// order against beni's subject-first one (checker.md §8.7).
    ///
    /// The parameters are read off the callee's DECLARED type — its scheme
    /// in this module, or its interface's — because an argument is checked
    /// after its call, when nothing else still holds them. An error path
    /// only.
    fn subjectFirstSlot(r: *Reporter, category: Category, actual: Var) ?u32 {
        if (category.tag != .call_arg or category.index == 0) return null;
        const call = category.owner.unwrap() orelse return null;
        const at = category.index - 1;
        const st = r.env.store;
        const arity = st.paramCount(actual);
        const bir = r.env.bir;
        if (call.int() >= bir.insts.len or bir.instTag(call) != .call) return null;
        const callee: Bir.Inst.Index = @enumFromInt(bir.instData(call).lhs);
        if (callee.int() >= bir.insts.len) return null;
        const data = bir.instData(callee);
        switch (bir.instTag(callee)) {
            .top, .local => {
                const v = (if (bir.instTag(callee) == .top)
                    (if (data.lhs < r.env.decl_scheme.len) r.env.decl_scheme[data.lhs].unwrap() else null)
                else
                    r.env.localVar(data.lhs)) orelse return null;
                const f = switch (st.resolvedContent(v)) {
                    .structure => |s| switch (s) {
                        .func => |f| f,
                        else => return null,
                    },
                    else => return null,
                };
                for (st.vars(f.params), 0..) |p, j| {
                    if (j != at and r.isFunction(p) and st.paramCount(p) == arity) return @intCast(j + 1);
                }
            },
            .ext_value => {
                if (data.lhs >= r.env.interfaces.len) return null;
                const iface = r.env.iface(@enumFromInt(data.lhs));
                if (data.rhs >= iface.values.len) return null;
                const body = iface.term(iface.scheme(iface.values[data.rhs].scheme).body);
                if (body.tag != .func) return null;
                for (iface.range(body.lhs), 0..) |p, j| {
                    const t = iface.term(@enumFromInt(p));
                    if (j != at and t.tag == .func and iface.range(t.lhs).len == arity) return @intCast(j + 1);
                }
            },
            else => {},
        }
        return null;
    }

    /// Elm's hint for an argument after the first: the types of a call's
    /// arguments are decided left to right, so a mismatch on the third can
    /// be the consequence of a mistake in the first.
    fn leftToRightHint(_: *Reporter, w: *std.Io.Writer, category: Category) Error!void {
        if (category.tag != .call_arg) return;
        if (category.index <= 1) return;
        w.writeAll(
            \\
            \\Hint: I work out a call's argument types from left to right, and once an
            \\argument fits I move on. So the mistake may be in one of the earlier
            \\arguments rather than in this one.
            \\
        ) catch return error.OutOfMemory;
    }

    /// How many arguments `v` takes, following aliases. `TypeStore` owns
    /// the rule: the solver counts parameters to decide whether a call's
    /// arity is wrong and this writes the sentence about it, so the two
    /// must agree, and they did so by holding the same code twice.
    fn paramCount(r: *const Reporter, v: Var) u32 {
        return r.env.store.paramCount(v);
    }

    fn primitiveOf(r: *const Reporter, v: Var) Types.TypeId {
        const c = r.env.store.resolvedContent(v);
        return switch (c) {
            .structure => |s| switch (s) {
                .app => |a| if (a.args.len == 0) a.type else .none,
                else => .none,
            },
            else => .none,
        };
    }

    fn kindOf(r: *const Reporter, v: Var) TypeStore.Kind {
        const c = r.env.store.resolvedContent(v);
        return switch (c) {
            .flex, .rigid => |flags| flags.kind,
            else => .any,
        };
    }

    pub fn isFunction(r: *const Reporter, v: Var) bool {
        const c = r.env.store.resolvedContent(v);
        return switch (c) {
            .structure => |s| s == .func,
            else => false,
        };
    }

    fn isFlex(r: *const Reporter, v: Var) bool {
        const c = r.env.store.resolvedContent(v);
        return c == .flex;
    }

    // ---- Arity (checker.md §8.3) ----------------------------------------

    /// `too_few_args`: the callee takes more arguments than the call
    /// supplied. THE load-bearing diagnostic of §8.3.
    ///
    /// **Nothing is deferred.** Under currying this message had to argue
    /// that the call "produces a function" and that a function was not what
    /// the context wanted; with saturated calls there is no
    /// partial-application reading to keep open, so the message is the
    /// count and the types of the arguments that are missing.
    pub fn tooFewArgs(
        r: *Reporter,
        region: Bir.Inst.Index,
        callee: Callee,
        arity: u32,
        given: u32,
        missing: []const Var,
    ) Error!void {
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        const scratch = r.env.scratch;

        w.print("{s} expects {s}, but it got only {d}.\n\n", .{
            calleeSubject(scratch, asFunction(callee), true),
            plural(scratch, arity, "argument"),
            given,
        }) catch return error.OutOfMemory;
        w.print("The missing {s}:\n\n", .{
            if (missing.len == 1) "argument is" else "arguments are",
        }) catch return error.OutOfMemory;
        for (missing) |m| {
            w.writeAll("    ") catch return error.OutOfMemory;
            Render.writeVar(w, r.cx(), &namer, m, .top) catch return error.OutOfMemory;
            w.writeByte('\n') catch return error.OutOfMemory;
        }
        // `f(a, b)`: one tuple where the arguments go (language.md §12.5).
        if (!try CallStyle.tupleCallHint(r, w, region, arity)) w.writeAll(
            \\
            \\Hint: every call supplies every argument. To make a function out of this one,
            \\write the missing argument as `_`: `f a _` is `λx -> f a x`.
            \\
        ) catch return error.OutOfMemory;
        try r.emit(.too_few_args, region, &out);
    }

    /// `too_many_args`. Deliberately Elm's short form: the types of the
    /// EXTRA arguments say nothing useful — a call's arguments are
    /// constrained after the call itself, so at this point they are still
    /// variables — and the count plus the callee's name is the whole
    /// message.
    pub fn tooManyArgs(
        r: *Reporter,
        region: Bir.Inst.Index,
        callee: Callee,
        arity: u32,
        given: u32,
    ) Error!void {
        var out = r.writer();
        defer out.deinit();
        const w = &out.writer;
        const scratch = r.env.scratch;

        w.print("{s} expects {s}, but it got {d}.\n\n", .{
            calleeSubject(scratch, asFunction(callee), true),
            plural(scratch, arity, "argument"),
            given,
        }) catch return error.OutOfMemory;
        w.writeAll("Are there any missing commas? Or missing parentheses?\n") catch return error.OutOfMemory;
        try r.emit(.too_many_args, region, &out);
    }

    pub fn notAFunction(
        r: *Reporter,
        region: Bir.Inst.Index,
        callee: Callee,
        given: u32,
        actual: Var,
    ) Error!void {
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        const scratch = r.env.scratch;

        // Never "the `x` function is not a function": whatever the Bir
        // calls it, in THIS message it is a value.
        const as_value: Callee = .{
            .kind = if (callee.kind == .function) .value else callee.kind,
            .name = callee.name,
        };
        w.print("{s} is not a function, but it was given {s}:\n\n    ", .{
            calleeSubject(scratch, as_value, true),
            plural(scratch, given, "argument"),
        }) catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
        w.writeAll("\n\nAre there any missing commas? Or missing parentheses?\n") catch return error.OutOfMemory;
        try r.emit(.not_a_function, region, &out);
    }

    /// The pattern twin of the two arity messages. A pattern does not
    /// "produce a function", so it gets its own sentence rather than a
    /// confusing reuse of the call one.
    pub fn ctorPatternArity(r: *Reporter, region: Bir.Inst.Index, callee: Callee, arity: u32, given: u32) Error!void {
        var out = r.writer();
        defer out.deinit();
        const w = &out.writer;
        const scratch = r.env.scratch;
        w.print("{s} takes {s}, but this pattern gives it {d}.\n\n", .{
            calleeSubject(scratch, callee, true),
            plural(scratch, arity, "argument"),
            given,
        }) catch return error.OutOfMemory;
        w.writeAll("Hint: a constructor pattern has to name every argument the constructor takes.\n") catch return error.OutOfMemory;
        try r.emit(if (given < arity) .too_few_args else .too_many_args, region, &out);
    }

    // ---- Kinds, cycles, obligations --------------------------------------

    pub fn kindMismatch(r: *Reporter, region: Bir.Inst.Index, left: TypeStore.Kind, right: TypeStore.Kind) Error!void {
        var out = r.writer();
        defer out.deinit();
        const w = &out.writer;
        w.print(
            \\This value has to be `{s}` and `{s}` at the same time, and nothing is both.
            \\
            \\`number` is `Int` or `Float`; `appendable` is `String` or `List a`.
            \\
        , .{ left.text(), right.text() }) catch return error.OutOfMemory;
        try r.emit(.kind_mismatch, region, &out);
    }

    /// A kind that met a structure it is not a member of: `appendable`
    /// against `Int`, `number` against `String`.
    pub fn kindNotSatisfied(
        r: *Reporter,
        region: Bir.Inst.Index,
        category: Category,
        kind: TypeStore.Kind,
        expected: Var,
        actual: Var,
    ) Error!void {
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        // The same opening sentence and the same two-types layout an
        // ordinary mismatch gets — "the 2nd branch of this `case`" must not
        // be lost just because the reason turned out to be a kind, and the
        // reader still needs to see which side is which.
        const lines = r.categoryLines(category, region);
        w.print("{s}\n\n{s}\n\n    ", .{ lines.intro, lines.found }) catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
        w.print("\n\n{s}\n\n    ", .{lines.wanted}) catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, expected, .top) catch return error.OutOfMemory;
        switch (kind) {
            // `Int32` is the one type a reader is likely to have reached
            // for ON PURPOSE and then found the operators missing, so it
            // gets the hint that says what to write instead. The general
            // sentence would send them looking for a conversion that does
            // not exist (`core/Int32.beni`, `fast-compiler.md` §3.1).
            .number => if (r.isCoreInt32(expected) or r.isCoreInt32(actual)) w.writeAll(
                \\
                \\
                \\One of those has to be a number — an `Int` or a `Float` — and it is not.
                \\
                \\Hint: `Int32` has no arithmetic operators on purpose: its arithmetic wraps
                \\at 32 bits, and `+` reading like `Int`'s would hide that. Use `Int32.add`,
                \\`sub`, `mul`, `div`, `rem` or `mod` — as a method, `a.add b`, or qualified,
                \\`Int32.add a b`. `==`, `<` and the other comparisons do work.
                \\
            ) catch return error.OutOfMemory else {
                w.writeAll(
                    \\
                    \\
                    \\One of those has to be a number — an `Int` or a `Float` — and it is not.
                    \\
                ) catch return error.OutOfMemory;
                // The numbers-only sentence only for an arithmetic operator's
                // operand; elsewhere Elm's conversion, in the direction the
                // value has to go (checker.md §8.7).
                const wk = r.env.types.well_known;
                // A number literal where Elm's order puts it (§12.5).
                if (try CallStyle.elmOrderHint(r, w, category, actual)) {
                    // said
                } else if (r.arithmeticOperand(category)) {
                    w.writeAll(
                        \\
                        \\Hint: `+`, `-`, `*` and `/` work on numbers only. To join text use `++`.
                        \\
                    ) catch return error.OutOfMemory;
                } else if (r.primitiveOf(expected) == wk.string) {
                    w.writeAll(to_string_hint) catch return error.OutOfMemory;
                } else if (r.primitiveOf(actual) == wk.string) {
                    w.writeAll(read_number_hint) catch return error.OutOfMemory;
                }
            },
            .appendable => w.writeAll(
                \\
                \\
                \\One of those has to be appendable — a `String` or a `List a` — and it is
                \\not.
                \\
                \\Hint: `++` joins two strings or two lists. To add numbers use `+`.
                \\
            ) catch return error.OutOfMemory,
            .any => w.writeByte('\n') catch return error.OutOfMemory,
        }
        try r.emit(.kind_mismatch, region, &out);
    }

    pub fn infiniteType(r: *Reporter, region: Bir.Inst.Index, name: Symbol.Optional) Error!void {
        var out = r.writer();
        defer out.deinit();
        const w = &out.writer;
        if (name.unwrap()) |s| {
            w.print("I am inferring a weird self-referential type for `{s}`:\n\n", .{r.env.interner.slice(s)}) catch return error.OutOfMemory;
        } else {
            w.writeAll("I am inferring a weird self-referential type here:\n\n") catch return error.OutOfMemory;
        }
        w.writeAll(
            \\Here is my best effort at writing it down:
            \\
            \\    a  =  … a …
            \\
            \\Hint: the type would go on forever, so I gave up. This usually means a
            \\definition is missing an argument, or is being used with one argument too
            \\many, somewhere inside itself.
            \\
        ) catch return error.OutOfMemory;
        try r.emit(.infinite_type, region, &out);
    }

    /// A written or inferred type the checker could not read to the bottom
    /// (`Types.Builder.max_depth`, `Schemes.Writer.max_depth`).
    ///
    /// **This message is what keeps a silent wrong answer out of the
    /// compiler.** The reader poisons what it could not finish, and a
    /// poisoned variable unifies with anything — so without a message the
    /// declaration becomes a hole and a caller's mistake against it
    /// compiles clean. The parser accepts eight times this much nesting
    /// (`Parse.max_depth` is 4096), so the band between the two limits is
    /// reachable from a file the front end took happily, which is exactly
    /// how it was found. `fast-compiler.md` §5's "errors never stop the
    /// build" means a poisoned variable AFTER a message, never instead of
    /// one.
    ///
    /// It shares `nesting_too_deep` with the parser deliberately: it is the
    /// same problem — this file nests further than the compiler reads — and
    /// an author who splits the type up fixes both.
    pub fn nestingTooDeep(r: *Reporter, region: Bir.Inst.Index, limit: u32) Error!void {
        var out = r.writer();
        defer out.deinit();
        const w = &out.writer;
        w.print(
            \\This type is nested more than {d} levels deep, which is more than I can
            \\read.
            \\
            \\I gave up part way down, so I cannot check this declaration or anything
            \\that uses it. Give the inner part a `type alias` of its own and write
            \\that name here instead.
            \\
        , .{limit}) catch return error.OutOfMemory;
        try r.emit(.nesting_too_deep, region, &out);
    }
    // ---- Static dispatch (static-dispatch-spike.md §10) ------------------
    //
    // **The two-span rule** (§10 preamble, A.37). Three of these codes are
    // raised while discharging an obligation, and an obligation carries two
    // instructions: `origin`, the call in THIS module whose instantiation
    // created it, and `region`, where the requirement itself was written —
    // which for a constraint that arrived on an imported scheme is inside
    // the callee. The PRIMARY span is always `origin`, the call the author
    // wrote. That is the whole of report 18 §2.4's complaint about Roc,
    // which records the same instruction and reports the other one.
    //
    // The secondary is carried as PROSE and not as a second span, because
    // `diagnostic.Diagnostic` has exactly one (`src/diagnostic.zig`) and a
    // second `Item` would be sorted by file and position — putting the
    // callee's file FIRST whenever its path sorts lower, which is the very
    // ordering the rule exists to forbid. What the reader needs is which
    // declaration asked, and that is a name.

    /// A compiler invariant the checker could not rely on. It is a
    /// diagnostic and not a panic for the reason `fast-compiler.md` §5
    /// gives — the build says what it could not do — and it should be
    /// unreachable on every input a person writes. `Report.emit` keeps it
    /// even in a quiet module: a broken invariant is not a consequence of
    /// anything the author wrote.
    pub fn internal(r: *Reporter, region: Bir.Inst.Index, what: []const u8) Error!void {
        var out = r.writer();
        defer out.deinit();
        out.writer.print(
            \\Something went wrong inside the compiler here: {s}.
            \\
            \\This is a bug in beni, not in your code. Please report it.
            \\
        , .{what}) catch return error.OutOfMemory;
        try r.emit(.internal, region, &out);
    }

    /// Which shape a receiver turned out to be, for §10.3's sentence.
    /// `record` is a dot-call's (its hint is the field call); `record_required`
    /// a requirement that is not one, and `open_record` a well-known method
    /// on an open record (static-dispatch-spike.md §10.3).
    pub const ShapeKind = enum { record, record_required, open_record, tuple, unit, function, contains_function, not_orderable, too_wide, other };

    // The texts of static dispatch and of the obligations (§10, checker.md
    // §8.4), in `DispatchTexts.zig` (checker-v2.md §19.1).
    pub const EquatableReason = enum { function, opaque_type, rigid_variable, too_wide };
    pub const EqUse = DispatchTexts.EqUse;
    pub const eqName = DispatchTexts.eqName;
    pub const eqRequirer = DispatchTexts.eqRequirer;
    pub const unknownMethod = DispatchTexts.unknownMethod;
    pub const undeterminedMethodReceiver = DispatchTexts.undeterminedMethodReceiver;
    pub const methodSignatureMismatch = DispatchTexts.methodSignatureMismatch;
    pub const privateMethod = DispatchTexts.privateMethod;
    pub const noMethodsOnShape = DispatchTexts.noMethodsOnShape;
    pub const missingWhereConstraint = DispatchTexts.missingWhereConstraint;
    pub const methodConstraintMismatch = DispatchTexts.methodConstraintMismatch;
    pub const typeDispatchNeedsAnnotation = DispatchTexts.typeDispatchNeedsAnnotation;
    pub const tooManyInferredConstraints = DispatchTexts.tooManyInferredConstraints;
    pub const ambiguousMethodReceiver = DispatchTexts.ambiguousMethodReceiver;
    pub const constrainedConstant = DispatchTexts.constrainedConstant;
    pub const notEquatable = DispatchTexts.notEquatable;
    pub const notInterpolatable = DispatchTexts.notInterpolatable;
    pub const ambiguousInterpolation = DispatchTexts.ambiguousInterpolation;
    pub const ambiguousTuple = DispatchTexts.ambiguousTuple;
    pub const tupleIndexOutOfRange = DispatchTexts.tupleIndexOutOfRange;
    pub const notATuple = DispatchTexts.notATuple;
    pub const tryShape = DispatchTexts.tryShape;

    // ---- Patterns (checker.md §6.6) --------------------------------------

    /// §6.7's text, in `DispatchTexts.zig`.
    pub const cyclicValue = DispatchTexts.cyclicValue;

    // The pattern texts, in `PatternTexts.zig`.
    pub const missingPatterns = PatternTexts.missingPatterns;
    pub const patternBudgetExhausted = PatternTexts.patternBudgetExhausted;
    pub const refutablePattern = PatternTexts.refutablePattern;
    pub const redundantPattern = PatternTexts.redundantPattern;

    // ---- Records ---------------------------------------------------------

    /// `missing` is sorted by NAME TEXT here, not taken as given: the
    /// solver partitions a record's fields in symbol-id order, and a symbol
    /// id depends on which worker interned which file (`InternPool`'s
    /// header) — so listing them as the partition produced them made the
    /// message depend on `--jobs`, which `fast-compiler.md` §10 forbids of
    /// everything a build prints. The slice is the solver's scratch and is
    /// discarded straight after, so sorting it in place costs nothing.
    pub fn missingField(r: *Reporter, region: Bir.Inst.Index, missing: []Symbol, actual: Var, expected: Var) Error!void {
        std.mem.sort(Symbol, missing, r.env.interner, symbolTextLessThan);
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        if (missing.len == 1) {
            w.print("This record does not have {s} `{s}` field:\n\n    ", .{ article(r.env.interner.slice(missing[0])), r.env.interner.slice(missing[0]) }) catch return error.OutOfMemory;
        } else {
            w.writeAll("This record is missing some fields:\n\n    ") catch return error.OutOfMemory;
        }
        Render.writeVar(w, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
        w.writeAll("\n\nBut I need a record like:\n\n    ") catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, expected, .top) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
        if (missing.len == 1) {
            if (r.nearestField(missing[0], actual)) |near| {
                w.print(
                    \\
                    \\Hint: this looks like a typo. Maybe `{s}` should be `{s}`?
                    \\
                , .{ r.env.interner.slice(missing[0]), r.env.interner.slice(near) }) catch return error.OutOfMemory;
            }
        } else {
            w.writeAll("\nHint: the fields I could not find are:\n") catch return error.OutOfMemory;
            for (missing) |m| w.print("    {s}\n", .{r.env.interner.slice(m)}) catch return error.OutOfMemory;
        }
        try r.emit(.missing_field, region, &out);
    }

    /// Sorted by name text for the same reason as `missingField`.
    pub fn unknownField(r: *Reporter, region: Bir.Inst.Index, extra: []Symbol, actual: Var, expected: Var) Error!void {
        std.mem.sort(Symbol, extra, r.env.interner, symbolTextLessThan);
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        if (extra.len == 1) {
            w.print("This record has {s} `{s}` field I did not expect:\n\n    ", .{ article(r.env.interner.slice(extra[0])), r.env.interner.slice(extra[0]) }) catch return error.OutOfMemory;
        } else {
            w.writeAll("This record has fields I did not expect:\n\n    ") catch return error.OutOfMemory;
        }
        Render.writeVar(w, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
        w.writeAll("\n\nBut I need a record like:\n\n    ") catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, expected, .top) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
        if (extra.len == 1) {
            if (r.nearestField(extra[0], expected)) |near| {
                w.print(
                    \\
                    \\Hint: this looks like a typo. Maybe `{s}` should be `{s}`?
                    \\
                , .{ r.env.interner.slice(extra[0]), r.env.interner.slice(near) }) catch return error.OutOfMemory;
            }
        }
        try r.emit(.unknown_field, region, &out);
    }

    pub fn recordNotClosed(r: *Reporter, region: Bir.Inst.Index, actual: Var, expected: Var) Error!void {
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        w.writeAll("This has to work with ANY record that has these fields:\n\n    ") catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, expected, .top) catch return error.OutOfMemory;
        w.writeAll("\n\nBut the value here is one specific record:\n\n    ") catch return error.OutOfMemory;
        Render.writeVar(w, r.cx(), &namer, actual, .top) catch return error.OutOfMemory;
        w.writeAll(
            \\
            \\
            \\Hint: `{ r | … }` means "any record with at least these fields", so a
            \\caller may pass one with more. A record literal and a record alias are
            \\closed, so neither can stand in for one.
            \\
        ) catch return error.OutOfMemory;
        try r.emit(.record_not_closed, region, &out);
    }

    /// The field of `v`'s record type closest to `name` by edit distance,
    /// for the typo hint of §8.
    fn nearestField(r: *Reporter, name: Symbol, v: Var) ?Symbol {
        const target = r.env.interner.slice(name);
        var best: ?Symbol = null;
        var best_distance: usize = std.math.maxInt(usize);
        var tail = v;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const c = r.env.store.resolvedContent(tail);
            const record = switch (c) {
                .structure => |s| switch (s) {
                    .record => |rec| rec,
                    else => break,
                },
                else => break,
            };
            for (r.env.store.fields(record.fields)) |f| {
                const candidate = r.env.interner.slice(f.name);
                const d = editDistance(r.env.scratch, target, candidate) catch continue;
                if (d < best_distance) {
                    best_distance = d;
                    best = f.name;
                }
            }
            tail = record.ext;
        }
        // A suggestion is only useful when it is close AND when the name is
        // long enough for closeness to mean anything: every one-letter name
        // is one edit from every other, so `z` must not be "a typo for `x`".
        if (target.len < 3) return null;
        const limit = @max(target.len / 3, 1) + 1;
        if (best_distance > limit) return null;
        return best;
    }

    // ---- Callees ---------------------------------------------------------

    /// What the callee of the call at `region` is, for the sentence that
    /// names it. Read straight off the Bir: after resolution a reference is
    /// a pair of dense indices, so this is two array lookups.
    pub fn calleeOf(r: *const Reporter, region: Bir.Inst.Index) Callee {
        const bir = r.env.bir;
        if (region.int() >= bir.insts.len) return .anonymous;
        const tag = bir.instTag(region);
        const reference: Bir.Inst.Index = switch (tag) {
            .call, .pat_ctor => @enumFromInt(bir.instData(region).lhs),
            else => region,
        };
        // A method call names the METHOD, or — when it came from one of the
        // six comparison operators — the operator the author wrote
        // (static-dispatch-spike.md §1.3, "diagnostics name the operator").
        // Its `lhs` is the receiver, so it cannot go through `describe`.
        if (tag == .method_call) {
            const m = bir.extraData(@enumFromInt(bir.instData(region).rhs), Bir.MethodCall);
            if (m.origin.spelling()) |op| return .{ .kind = .operator, .name = op };
            return .{ .kind = .value, .name = r.env.interner.slice(bir.symbol(m.name)) };
        }
        return r.describe(reference);
    }

    pub fn describe(r: *const Reporter, reference: Bir.Inst.Index) Callee {
        const bir = r.env.bir;
        if (reference.int() >= bir.insts.len) return .anonymous;
        const data = bir.instData(reference);
        switch (bir.instTag(reference)) {
            .local => {
                // A local index is relative to the declaration being
                // checked; `locals_base` is where that declaration's run
                // starts in the module-wide table.
                const at = r.env.locals_base + data.lhs;
                if (data.lhs >= r.env.local_var.len or at >= bir.locals.len) return .anonymous;
                const name = bir.locals[at].name.unwrap() orelse return .anonymous;
                return .{ .kind = .value, .name = r.env.interner.slice(bir.symbols[name]) };
            },
            .top => {
                if (data.lhs >= bir.decls.len) return .anonymous;
                return .{ .kind = .function, .name = r.env.interner.slice(bir.symbol(bir.decls[data.lhs].name)) };
            },
            .ctor => {
                if (data.lhs >= bir.ctors.len) return .anonymous;
                return .{ .kind = .ctor, .name = r.env.interner.slice(bir.symbol(bir.ctors[data.lhs].name)) };
            },
            .ext_value => {
                if (data.lhs >= r.env.interfaces.len) return .anonymous;
                const iface = r.env.iface(@enumFromInt(data.lhs));
                if (data.rhs >= iface.values.len) return .anonymous;
                const symbol = iface.valueName(@enumFromInt(data.rhs));
                // Every operator of language.md §6.5 desugars to a call of
                // a core function nobody writes by hand, so naming the
                // function would name something the author never typed.
                if (r.operatorCallee(@enumFromInt(data.lhs), symbol)) |op| return .{ .kind = .operator, .name = op };
                if (r.listSyntaxCallee(@enumFromInt(data.lhs), symbol)) |name| return .{ .kind = .function, .name = name };
                return .{ .kind = .function, .name = r.env.interner.slice(symbol) };
            },
            .ext_ctor => {
                if (data.lhs >= r.env.interfaces.len) return .anonymous;
                const iface = r.env.iface(@enumFromInt(data.lhs));
                if (data.rhs >= iface.ctors.len) return .anonymous;
                return .{ .kind = .ctor, .name = r.env.interner.slice(iface.ctorName(@enumFromInt(data.rhs))) };
            },
            // `s.retries 2`: the field is what the author wrote, so it is
            // what the message names.
            .field_access => return .{ .kind = .value, .name = r.env.interner.slice(bir.symbols[data.rhs]) },
            // `(==)` is a LAMBDA over a method call
            // (static-dispatch-spike.md §3.1, Appendix A.22), so without
            // this every message about one said "This value". §1.3 promises
            // that a message about a well-known call names the operator.
            .lambda => return if (bir.operatorSection(reference, r.env.locals_base)) |origin|
                .{ .kind = .operator, .name = origin.spelling().? }
            else
                .anonymous,
            else => return .anonymous,
        }
    }

    /// `operatorSpelling`, but only for the core value the operator really
    /// desugars to. **The name alone is not enough**, and saying it was is
    /// how `Int32.add a b` came to be reported as "the (+) operator" — an
    /// operator the author never typed and one that, on an `Int32`, does
    /// not exist at all (`core/Int32.beni`). `List.eq`, `List.compare` and
    /// `String.append` share a name with a desugaring the same way. Every
    /// operator of language.md §6.5 lowers to a value of `core/Basics`
    /// (`::`, which lowered to `core/List`'s `cons`, left on 2026-10-01; a
    /// list's spread is `listSyntaxCallee`'s).
    fn operatorCallee(r: *const Reporter, module: Graph.Index, symbol: Symbol) ?[]const u8 {
        const spelling = operatorSpelling(symbol) orelse return null;
        // The six comparisons lower to method calls, never to a call of
        // their core function (static-dispatch-spike.md §3.1), so a call of
        // `Basics.eq` or `Basics.lt` is one the program wrote by name.
        const wk = InternPool.WellKnown;
        inline for (.{ wk.eq, wk.neq, wk.lt, wk.gt, wk.le, wk.ge }) |comparison| {
            if (symbol == comparison.symbol()) return null;
        }
        const declared = r.env.graph.find(.core, InternPool.WellKnown.Basics.symbol()) orelse return null;
        return if (declared == module) spelling else null;
    }

    /// `List.cons` or `List.append` when `symbol` of `module` is core's —
    /// the two functions a list written with a spread is (language.md
    /// §6.8, §8) — named in full, because the author wrote brackets and
    /// the message has to say which call they mean.
    fn listSyntaxCallee(r: *const Reporter, module: Graph.Index, symbol: Symbol) ?[]const u8 {
        const wk = InternPool.WellKnown;
        const name = if (symbol == wk.cons.symbol()) "List.cons" else if (symbol == wk.append.symbol()) "List.append" else return null;
        const declared = r.env.graph.find(.core, wk.List.symbol()) orelse return null;
        return if (declared == module) name else null;
    }

    /// Whether `v` is `core/Int32.beni`'s `Int32`, asked by NAME and only
    /// on the error path. `Int32` has no `Types.WellKnown` slot because it
    /// has no `InternPool.WellKnown` symbol, and it may not gain one: that
    /// enum's indices are exactly what lowering compares a symbol against
    /// to decide "is this a prelude name?" (`InternPool.WellKnown`), and
    /// `Int32` is deliberately not in the prelude (`language.md` Appendix
    /// A). One string compare per reported mismatch is the right price.
    fn isCoreInt32(r: *const Reporter, v: Var) bool {
        const id = r.primitiveOf(v);
        if (id == .none) return false;
        const e = r.env.types.entry(id);
        if (e.package != .core) return false;
        return std.mem.eql(u8, r.env.interner.slice(e.module_name), "Int32") and
            std.mem.eql(u8, r.env.interner.slice(e.name), "Int32");
    }
};

/// The operator a core function is the desugaring of (`DispatchTexts.zig`).
pub const operatorSpelling = DispatchTexts.operatorSpelling;

/// Whatever the Bir calls it, something that takes arguments is a function
/// in an arity message: "the `scale` value expects 2 arguments" reads wrong
/// for a `let`-bound helper.
fn asFunction(callee: Callee) Callee {
    return .{ .kind = if (callee.kind == .value) .function else callee.kind, .name = callee.name };
}

/// "The `f` function", "The (+) operator", "This value".
fn calleeSubject(scratch: Allocator, callee: Callee, comptime capital: bool) []const u8 {
    const the = if (capital) "The" else "the";
    return switch (callee.kind) {
        .anonymous => if (capital) "This value" else "this value",
        .function => std.fmt.allocPrint(scratch, "{s} `{s}` function", .{ the, callee.name }) catch "This function",
        .value => std.fmt.allocPrint(scratch, "{s} `{s}` value", .{ the, callee.name }) catch "This value",
        .ctor => std.fmt.allocPrint(scratch, "{s} `{s}` constructor", .{ the, callee.name }) catch "This constructor",
        .operator => std.fmt.allocPrint(scratch, "{s} ({s}) operator", .{ the, callee.name }) catch "This operator",
    };
}

/// "`f`", "(+)", "this function" — the short form, for mid-sentence use.
pub fn calleeReference(scratch: Allocator, callee: Callee) []const u8 {
    return switch (callee.kind) {
        .anonymous => "this function",
        .operator => std.fmt.allocPrint(scratch, "({s})", .{callee.name}) catch "this operator",
        else => std.fmt.allocPrint(scratch, "`{s}`", .{callee.name}) catch "this function",
    };
}

fn plural(scratch: Allocator, n: u32, comptime noun: []const u8) []const u8 {
    if (n == 1) return "1 " ++ noun;
    return std.fmt.allocPrint(scratch, "{d} " ++ noun ++ "s", .{n}) catch "several " ++ noun ++ "s";
}

/// The type record `v` gives field `name`, looking through aliases and
/// along its extension chain, or null when `v` is no record or has no such
/// field. The chain is bounded as the printer's is, and a cycle ends it.
fn recordField(store: *TypeStore, v: Var, name: InternPool.Symbol) ?Var {
    var at = v;
    var links: u32 = 0;
    while (links < 64) : (links += 1) {
        switch (store.resolvedContent(at)) {
            .structure => |s| switch (s) {
                .record => |rec| {
                    for (store.fields(rec.fields)) |f| if (f.name == name) return f.value;
                    at = rec.ext;
                },
                else => return null,
            },
            else => return null,
        }
    }
    return null;
}

/// "a" or "an" before a backticked name (checker.md §8.7): "an" when
/// it starts with a vowel LETTER. A name is not a word, so the letter the
/// reader sees decides, not how it might be spoken (`url` reads "an").
/// Elm writes "a" every time.
pub fn article(name: []const u8) []const u8 {
    if (name.len == 0) return "a";
    return switch (std.ascii.toLower(name[0])) {
        'a', 'e', 'i', 'o', 'u' => "an",
        else => "a",
    };
}

/// "1st", "2nd", "3rd", "4th", … — Elm's `D.ordinal`.
fn ordinal(scratch: Allocator, n: u32) []const u8 {
    const suffix: []const u8 = switch (n % 100) {
        11, 12, 13 => "th",
        else => switch (n % 10) {
            1 => "st",
            2 => "nd",
            3 => "rd",
            else => "th",
        },
    };
    return std.fmt.allocPrint(scratch, "{d}{s}", .{ n, suffix }) catch "next";
}

/// Levenshtein distance, for the field-typo hint. Two rows rather than a
/// matrix: field names are short and this runs only on the error path.
pub fn editDistance(scratch: Allocator, a: []const u8, b: []const u8) Allocator.Error!usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    const previous = try scratch.alloc(usize, b.len + 1);
    defer scratch.free(previous);
    const current = try scratch.alloc(usize, b.len + 1);
    defer scratch.free(current);
    for (previous, 0..) |*p, i| p.* = i;
    for (a, 0..) |ca, i| {
        current[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            current[j + 1] = @min(@min(current[j] + 1, previous[j + 1] + 1), previous[j] + cost);
        }
        @memcpy(previous, current);
    }
    return previous[b.len];
}

/// `1st`, `2nd`, `3rd`, `4th` … — English, including the teens, which are
/// all `th` however they end.
pub fn ordinalSuffix(n: u32) []const u8 {
    if (n % 100 >= 11 and n % 100 <= 13) return "th";
    return switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ordinals follow English, teens included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("1st", ordinal(a, 1));
    try testing.expectEqualStrings("2nd", ordinal(a, 2));
    try testing.expectEqualStrings("3rd", ordinal(a, 3));
    try testing.expectEqualStrings("4th", ordinal(a, 4));
    try testing.expectEqualStrings("11th", ordinal(a, 11));
    try testing.expectEqualStrings("12th", ordinal(a, 12));
    try testing.expectEqualStrings("13th", ordinal(a, 13));
    try testing.expectEqualStrings("21st", ordinal(a, 21));
    try testing.expectEqualStrings("22nd", ordinal(a, 22));
    try testing.expectEqualStrings("101st", ordinal(a, 101));
}

test "plural says 1 argument and 2 arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("1 argument", plural(a, 1, "argument"));
    try testing.expectEqualStrings("2 arguments", plural(a, 2, "argument"));
    try testing.expectEqualStrings("0 arguments", plural(a, 0, "argument"));
}

test "edit distance is what the field-typo hint needs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try editDistance(a, "name", "name"));
    try testing.expectEqual(@as(usize, 1), try editDistance(a, "nme", "name"));
    try testing.expectEqual(@as(usize, 1), try editDistance(a, "namee", "name"));
    try testing.expectEqual(@as(usize, 1), try editDistance(a, "nane", "name"));
    try testing.expectEqual(@as(usize, 4), try editDistance(a, "", "name"));
    try testing.expectEqual(@as(usize, 5), try editDistance(a, "count", ""));
}
