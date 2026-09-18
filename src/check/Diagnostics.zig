//! The checker's prose (docs/design/checker.md §8).
//!
//! Register and structure follow Elm's `Reporting/Error/Type.hs`: a title,
//! what the compiler was looking at, the two types one under the other, and
//! a hint where there is a known one. The hints are Elm's, minus the ones
//! for features beni does not have: `number` against `String`, the missing
//! `toFloat`, function equality (a compile error here rather than a runtime
//! crash, `fast-compiler.md` §3.1 point 5), ordering text with
//! `String.compare`, and record field typos by edit distance.
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
const Constrain = @import("Constrain.zig");
const Render = @import("Render.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

const Diagnostics = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
const Category = Constrain.Category;

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
    /// `warning` only for `ambiguous_method_receiver` under `--explain`
    /// (§10.9); a warning never changes the exit code.
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

pub const Reporter = struct {
    gpa: Allocator,
    env: *Constrain.Env,
    items: *std.ArrayList(Item),
    /// A module in an import cycle reports nothing (checker.md §4.3), and
    /// so does a declaration that has already failed: one mistake, one
    /// message.
    quiet: bool = false,
    /// Whether anything has been reported since `reported` was last
    /// cleared. The solver asks "did that sub-unification produce a
    /// message?" and used to answer it by comparing `items.len` before and
    /// after, which coupled it to a list's internals and would have gone
    /// quietly wrong the day a reporter stopped appending one item per
    /// message. A flag says what is meant.
    reported: bool = false,

    pub const Error = Allocator.Error;

    fn cx(r: *const Reporter) Render.Context {
        return .{ .store = r.env.store, .types = r.env.types, .interner = r.env.interner };
    }

    fn emit(r: *Reporter, code: diagnostic.Code, region: Bir.Inst.Index, out: *std.Io.Writer.Allocating) Error!void {
        const message = try out.toOwnedSlice();
        errdefer r.gpa.free(message);
        try r.items.append(r.gpa, .{ .code = code, .module = r.env.module, .region = region, .message = message });
        r.reported = true;
    }

    /// `emit`, underlining `token` rather than `region`'s own.
    fn emitAt(r: *Reporter, code: diagnostic.Code, region: Bir.Inst.Index, token: u32, out: *std.Io.Writer.Allocating) Error!void {
        const message = try out.toOwnedSlice();
        errdefer r.gpa.free(message);
        try r.items.append(r.gpa, .{
            .code = code,
            .module = r.env.module,
            .region = region,
            .token = token,
            .message = message,
        });
        r.reported = true;
    }

    /// Where the item list stood, so a SPECULATION can drop what it said.
    ///
    /// `checker.md` §6.5's `?` probe is not the only speculator any more:
    /// static-dispatch-spike.md §6.2 registers obligations from inside
    /// `unify`, so `dischargeMethod` — and `checkAgainstRigid`, and every
    /// message they raise — can run under a probe that is then retracted
    /// (§6.1 invariant 2, A.35). A diagnostic about a shape the compiler
    /// decided against is worse than no diagnostic at all.
    pub const Mark = struct { items: usize, reported: bool };

    pub fn mark(r: *const Reporter) Mark {
        return .{ .items = r.items.items.len, .reported = r.reported };
    }

    /// Drop everything reported since `m`.
    pub fn rollbackTo(r: *Reporter, m: Mark) void {
        for (r.items.items[m.items..]) |item| r.gpa.free(item.message);
        r.items.shrinkRetainingCapacity(m.items);
        r.reported = m.reported;
    }

    /// Arm the flag `didReport` reads. Every path that emits goes through
    /// `emit`, so nothing else has to remember to set it.
    pub fn clearReported(r: *Reporter) void {
        r.reported = false;
    }

    pub fn didReport(r: *const Reporter) bool {
        return r.reported;
    }

    pub fn markReported(r: *Reporter) void {
        r.reported = true;
    }

    fn writer(r: *Reporter) std.Io.Writer.Allocating {
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
        if (r.quiet) return;
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;

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
        // **A.30's boundary, said out loud.** A `let` binding whose type
        // carries a method constraint is not generalised over it (§6.4 rule
        // (a)), so a second use at another type arrives here as an ordinary
        // mismatch — and the numeric hints below would tell the author to
        // check their arithmetic. This one names the binding and the
        // constraint instead, and says what to do.
        if (try r.monomorphicLetHint(w, category)) {
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
        const found = r.monomorphicMethod(v) orelse return false;
        const at = r.env.locals_base + index;
        const name = if (at < bir.locals.len)
            (if (bir.locals[at].name.unwrap()) |sym| r.env.interner.slice(bir.symbols[sym]) else "it")
        else
            "it";
        w.print(
            \\
            \\Hint: `{s}` is a `let` binding whose type needs a `{s}` method, and such a
            \\binding is used at ONE type inside the definition that holds it
            \\(`docs/design/static-dispatch-spike.md` §6.4). The first use fixed the type;
            \\this is the second.
            \\
            \\Move `{s}` out to a top-level declaration and annotate it with
            \\`where … .{s} : …` to use it at two.
            \\
        , .{ name, r.env.interner.slice(found), name, r.env.interner.slice(found) }) catch return error.OutOfMemory;
        return true;
    }

    /// The method that made `v`'s binding monomorphic, if any: a variable
    /// inside `v`'s type is one §6.4 rule (a) held back.
    fn monomorphicMethod(r: *Reporter, v: Var) ?Symbol {
        if (r.env.monomorphic.items.len == 0) return null;
        const st = r.env.store;
        const seen = st.nextMark();
        var stack: [64]Var = undefined;
        var len: usize = 1;
        stack[0] = v;
        var budget: u32 = 4096;
        while (len > 0 and budget > 0) {
            budget -= 1;
            len -= 1;
            const root, const c = st.resolved(stack[len]);
            if (st.mark(root) == seen) continue;
            st.setMark(root, seen);
            for (r.env.monomorphic.items) |m| {
                if (st.find(m.v) == root) return m.method;
            }
            const push = struct {
                fn f(buf: *[64]Var, l: *usize, x: Var) void {
                    if (l.* >= buf.len) return;
                    buf[l.*] = x;
                    l.* += 1;
                }
            }.f;
            switch (c) {
                .structure => |flat| switch (flat) {
                    .func => |fn_| {
                        for (st.vars(fn_.params)) |param| push(&stack, &len, param);
                        push(&stack, &len, fn_.result);
                    },
                    .app => |a| for (st.vars(a.args)) |arg| push(&stack, &len, arg),
                    .tuple => |t| for (st.vars(t)) |el| push(&stack, &len, el),
                    .record => |rec| for (st.fields(rec.fields)) |f| push(&stack, &len, f.value),
                    else => {},
                },
                else => {},
            }
        }
        return null;
    }

    /// The name of the first method constraint anywhere in `v`'s type, in a
    /// bounded walk.
    fn firstConstraint(r: *Reporter, v: Var) ?Symbol {
        const st = r.env.store;
        const seen = st.nextMark();
        var stack: [64]Var = undefined;
        var len: usize = 1;
        stack[0] = v;
        var budget: u32 = 4096;
        while (len > 0 and budget > 0) {
            budget -= 1;
            len -= 1;
            const root, const c = st.resolved(stack[len]);
            if (st.mark(root) == seen) continue;
            st.setMark(root, seen);
            const flags = st.flagsOf(root);
            if (st.constraintCount(flags.constraints) != 0) return st.constraintAt(flags.constraints, 0).name;
            const push = struct {
                fn f(buf: *[64]Var, l: *usize, x: Var) void {
                    if (l.* >= buf.len) return;
                    buf[l.*] = x;
                    l.* += 1;
                }
            }.f;
            switch (c) {
                .structure => |flat| switch (flat) {
                    .func => |fn_| {
                        for (st.vars(fn_.params)) |param| push(&stack, &len, param);
                        push(&stack, &len, fn_.result);
                    },
                    .app => |a| for (st.vars(a.args)) |arg| push(&stack, &len, arg),
                    .tuple => |t| for (st.vars(t)) |el| push(&stack, &len, el),
                    .record => |rec| for (st.fields(rec.fields)) |f| push(&stack, &len, f.value),
                    else => {},
                },
                else => {},
            }
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

    const Lines = struct { intro: []const u8, found: []const u8, wanted: []const u8 };

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
                return .{
                    .intro = std.fmt.allocPrint(scratch, "The {s} argument to {s} is not what I expect:", .{
                        ordinal(scratch, category.index),
                        calleeReference(scratch, callee),
                    }) catch "This argument is not what I expect:",
                    .found = "This argument is:",
                    .wanted = std.fmt.allocPrint(scratch, "But {s} needs the {s} argument to be:", .{
                        calleeReference(scratch, callee),
                        ordinal(scratch, category.index),
                    }) catch "But it needs it to be:",
                };
            },
            .list_entry => return .{
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
                .intro = std.fmt.allocPrint(scratch, "This is not a record with a `{s}` field:", .{r.fieldText(category.index)}) catch "This is not a record with that field:",
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
            .try_value, .pattern, .ctor_arg, .destructure, .general => return .{
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
        _ = namer;
        // Two functions of different arity where one was wanted is the
        // missing-argument shape again, one level in: §8.3 catches it at a
        // CALL, and this is the same mistake passed as an argument.
        const wanted_arrows = r.paramCount(expected);
        const found_arrows = r.paramCount(actual);
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
        // A number where a String was wanted, or the reverse.
        if (e == wk.string and (a == wk.int or a_kind == .number)) {
            w.writeAll(
                \\
                \\Hint: want to turn a number into a `String`? Use `String.fromInt` or
                \\`String.fromFloat`.
                \\
            ) catch return error.OutOfMemory;
            return;
        }
        if (a == wk.string and (e == wk.int or e_kind == .number)) {
            w.writeAll(
                \\
                \\Hint: `<`, `>`, `<=`, `>=` and the arithmetic operators work on numbers only.
                \\To order text use `String.compare`; to read a number out of text use
                \\`String.toInt` or `String.toFloat`.
                \\
            ) catch return error.OutOfMemory;
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
        // A function where a value was wanted is nearly always a missing
        // argument; §8.3 catches it at a call, and this is the rest.
        if (r.isFunction(actual) and !r.isFunction(expected) and !r.isFlex(expected)) {
            w.writeAll(
                \\
                \\Hint: this is a function, so it may be missing an argument.
                \\
            ) catch return error.OutOfMemory;
        }
        try r.leftToRightHint(w, category);
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

    fn isFunction(r: *const Reporter, v: Var) bool {
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
        if (r.quiet) return;
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
        w.writeAll(
            \\
            \\Hint: every call supplies every argument. To make a function out of this one,
            \\write the missing argument as `_`: `f a _` is `\x -> f a x`.
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
        if (r.quiet) return;
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
        if (r.quiet) return;
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
        if (r.quiet) return;
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
        if (r.quiet) return;
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
        if (r.quiet) return;
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
            .number => w.writeAll(
                \\
                \\
                \\One of those has to be a number — an `Int` or a `Float` — and it is not.
                \\
                \\Hint: `+`, `-`, `*`, `<`, `>`, `<=` and `>=` work on numbers only. To join
                \\text use `++`, and to order it use `String.compare`.
                \\
            ) catch return error.OutOfMemory,
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
        if (r.quiet) return;
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
        if (r.quiet) return;
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
    /// unreachable on every input a person writes.
    pub fn internal(r: *Reporter, region: Bir.Inst.Index, what: []const u8) Error!void {
        if (r.quiet) return;
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
    pub const ShapeKind = enum { record, tuple, unit, function, contains_function, not_orderable, other };

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
        if (r.nearestValue(module, method)) |near| {
            w.print("\nHint: did you mean `{s}`?\n", .{r.env.interner.slice(near)}) catch return error.OutOfMemory;
        } else if (module.int() < r.env.interfaces.len) {
            // No near name: say what IS there, which is the other half of
            // §10.1's hint. Capped, because a module's public surface can
            // be a hundred names and a message that scrolls is no message.
            const iface = &r.env.interfaces[module.int()];
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
        const what = switch (shape) {
            .record => "record",
            .tuple => "tuple",
            .unit => "`()`",
            .function => "function",
            .contains_function, .not_orderable, .other => "type",
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

    /// §10.9. Informational, `warning`, and only under `--explain`: what
    /// plan §7's M3 churn measurement counts.
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
        r.reported = true;
    }

    /// §10.10. A `pub` value of no parameters whose inferred scheme kept a
    /// constraint: it would need an evidence parameter, and a value with
    /// one is a function (§8.1).
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
            \\Hint: give it a parameter, or annotate it at a concrete type.
            \\
        , .{ r.env.interner.slice(decl), v_text, r.env.interner.slice(method), r.env.interner.slice(decl) }) catch return error.OutOfMemory;
        try r.emitAt(.constrained_constant, region, token, &out);
    }

    /// The `pub` value of `module` closest to `name` by edit distance, for
    /// §10.1's did-you-mean.
    fn nearestValue(r: *Reporter, module: Graph.Index, name: Symbol) ?Symbol {
        if (module.int() >= r.env.interfaces.len) return null;
        const iface = &r.env.interfaces[module.int()];
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
        }
        try r.emit(.not_equatable, region, &out);
    }

    pub const EquatableReason = enum { function, opaque_type, rigid_variable };

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

    // ---- Patterns (checker.md §6.6) --------------------------------------

    /// A `case` with no branch for some possibility. `examples` are
    /// counterexample patterns already rendered as source syntax by
    /// `Render.allocPattern` — at most three of them, because a list of
    /// twenty is a wall and the first three say the same thing.
    ///
    /// The patterns arrive rendered rather than as a structure because the
    /// store they name constructors from is the module's, and this message
    /// is the last thing that will ever read it.
    pub fn missingPatterns(r: *Reporter, region: Bir.Inst.Index, examples: []const []const u8) Error!void {
        if (r.quiet) return;
        if (examples.len == 0) return;
        var out = r.writer();
        defer out.deinit();
        const w = &out.writer;
        w.writeAll(
            \\This `case` does not have branches for all possibilities:
            \\
            \\Missing possibilities include:
            \\
            \\
        ) catch return error.OutOfMemory;
        for (examples) |e| w.print("    {s}\n", .{e}) catch return error.OutOfMemory;
        w.writeAll(
            \\
            \\I would have to crash if I saw one of those. Add branches for them!
            \\
            \\Hint: if you want to write a branch's code later, `Debug.todo "…"` holds the
            \\place and has whatever type the branch needs.
            \\
        ) catch return error.OutOfMemory;
        try r.emit(.missing_patterns, region, &out);
    }

    /// A branch no value can reach: every shape it matches is taken by a
    /// branch above it. `index` is 1-based, as the reader counts them.
    pub fn redundantPattern(r: *Reporter, region: Bir.Inst.Index, index: u32) Error!void {
        if (r.quiet) return;
        var out = r.writer();
        defer out.deinit();
        out.writer.print(
            \\The {d}{s} pattern is redundant:
            \\
            \\Any value with this shape is matched by a branch above it, so this branch
            \\never runs. Remove it, or make it more specific than the one that shadows it.
            \\
        , .{ index, ordinalSuffix(index) }) catch return error.OutOfMemory;
        try r.emit(.redundant_pattern, region, &out);
    }

    // ---- Records ---------------------------------------------------------

    /// `missing` is sorted by NAME TEXT here, not taken as given: the
    /// solver partitions a record's fields in symbol-id order, and a symbol
    /// id depends on which worker interned which file (`InternPool`'s
    /// header) — so listing them as the partition produced them made the
    /// message depend on `--jobs`, which `fast-compiler.md` §10 forbids of
    /// everything a build prints. The slice is the solver's scratch and is
    /// discarded straight after, so sorting it in place costs nothing.
    pub fn missingField(r: *Reporter, region: Bir.Inst.Index, missing: []Symbol, actual: Var, expected: Var) Error!void {
        if (r.quiet) return;
        std.mem.sort(Symbol, missing, r.env.interner, symbolTextLessThan);
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        if (missing.len == 1) {
            w.print("This record does not have a `{s}` field:\n\n    ", .{r.env.interner.slice(missing[0])}) catch return error.OutOfMemory;
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
        if (r.quiet) return;
        std.mem.sort(Symbol, extra, r.env.interner, symbolTextLessThan);
        var out = r.writer();
        defer out.deinit();
        var namer: Render.Namer = .init(r.gpa);
        defer namer.deinit();
        const w = &out.writer;
        if (extra.len == 1) {
            w.print("This record has a `{s}` field I did not expect:\n\n    ", .{r.env.interner.slice(extra[0])}) catch return error.OutOfMemory;
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
        if (r.quiet) return;
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

    fn describe(r: *const Reporter, reference: Bir.Inst.Index) Callee {
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
                const iface = &r.env.interfaces[data.lhs];
                if (data.rhs >= iface.values.len) return .anonymous;
                const symbol = iface.valueName(@enumFromInt(data.rhs));
                // Every operator of language.md §6.5 desugars to a call of
                // a core function nobody writes by hand, so naming the
                // function would name something the author never typed.
                if (operatorSpelling(symbol)) |op| return .{ .kind = .operator, .name = op };
                return .{ .kind = .function, .name = r.env.interner.slice(symbol) };
            },
            .ext_ctor => {
                if (data.lhs >= r.env.interfaces.len) return .anonymous;
                const iface = &r.env.interfaces[data.lhs];
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
};

/// The operator a core function is the desugaring of (language.md §6.5), or
/// null for an ordinary name. The symbols are the well-known prefix of the
/// intern pool, so this is a switch on an integer.
pub fn operatorSpelling(symbol: Symbol) ?[]const u8 {
    const wk = InternPool.WellKnown;
    const pairs = .{
        .{ wk.add, "+" },     .{ wk.sub, "-" },   .{ wk.mul, "*" },
        .{ wk.fdiv, "/" },    .{ wk.idiv, "//" }, .{ wk.pow, "^" },
        .{ wk.append, "++" }, .{ wk.cons, "::" }, .{ wk.eq, "==" },
        .{ wk.neq, "/=" },    .{ wk.lt, "<" },    .{ wk.gt, ">" },
        .{ wk.le, "<=" },     .{ wk.ge, ">=" },   .{ wk.@"and", "&&" },
        .{ wk.@"or", "||" },
    };
    inline for (pairs) |pair| {
        if (symbol == pair[0].symbol()) return pair[1];
    }
    return null;
}

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
fn calleeReference(scratch: Allocator, callee: Callee) []const u8 {
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
fn editDistance(scratch: Allocator, a: []const u8, b: []const u8) Allocator.Error!usize {
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
fn ordinalSuffix(n: u32) []const u8 {
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

test "operator spellings cover the desugarings of language.md §6.5" {
    try testing.expectEqualStrings("+", operatorSpelling(InternPool.WellKnown.add.symbol()).?);
    try testing.expectEqualStrings("==", operatorSpelling(InternPool.WellKnown.eq.symbol()).?);
    try testing.expectEqualStrings("::", operatorSpelling(InternPool.WellKnown.cons.symbol()).?);
    // A prelude value the author DOES write by hand keeps its own name.
    try testing.expectEqual(@as(?[]const u8, null), operatorSpelling(InternPool.WellKnown.negate.symbol()));
    try testing.expectEqual(@as(?[]const u8, null), operatorSpelling(InternPool.WellKnown.max.symbol()));
}
