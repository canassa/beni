//! Call-style diagnostics (`language.md` §12.5, `checker-v2.md` §29.4): the
//! places where a habit from JavaScript or Elm meets a beni call.
//!
//! Four hints on codes that already exist — `xs.length` and `xs.length ()`
//! naming the function the author reached for, `f(a, b)` naming the
//! space-separated call, and a core or platform call written in Elm's
//! argument order printed in beni's — and one warning,
//! `suspicious_argument_order`, for the functions whose Elm-ordered call
//! still checks. Every hint is decided on the error path only, so no
//! program that checks pays for one; the warning is one walk of a clean
//! module's `call` instructions, made after it checked, so it cannot
//! change a type.
//!
//! **The Elm-order hint does not speculate in the store** (§7.5's
//! snapshot is not built). It asks, read-only, whether each argument's
//! type — the failing argument's, a literal's, a local's — could be the
//! declared parameter it would meet in another order, and prints the one
//! order under which every argument could; an argument whose type is not
//! at hand fits anywhere. An ambiguous answer prints nothing.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Diagnostics = @import("Diagnostics.zig");
const Category = @import("Category.zig").Category;
const Walk = @import("Walk.zig");

const Reporter = Diagnostics.Reporter;
const Error = Reporter.Error;
const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;

// ---- Argument text ------------------------------------------------------

/// Whether `inst` is a literal: a number, a character or a string,
/// interpolated or not.
fn isLiteral(bir: *const Bir, inst: Bir.Inst.Index) bool {
    return switch (bir.instTag(inst)) {
        .int, .float, .char, .string, .interp => true,
        else => false,
    };
}

/// `inst` as the author could have written it, when it is an atom this
/// can spell — a literal, `()`, or a name — and `(…)` otherwise. The
/// checker has no source text; the hints print calls, and a call whose
/// argument is an expression still shows where it goes.
pub fn writeArg(r: *const Reporter, w: *std.Io.Writer, inst: Bir.Inst.Index) std.Io.Writer.Error!void {
    const bir = r.env.bir;
    if (inst.int() >= bir.insts.len) return w.writeAll("(…)");
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .int, .float => return w.writeAll(bir.bytes(inst)),
        .string => {
            try w.writeByte('"');
            for (bir.bytes(inst)) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '$' => try w.writeAll("\\$"),
                else => try w.writeByte(c),
            };
            return w.writeByte('"');
        },
        .char => {
            var buffer: [4]u8 = undefined;
            const scalar: u21 = std.math.cast(u21, data.lhs) orelse return w.writeAll("(…)");
            const len = std.unicode.utf8Encode(scalar, &buffer) catch return w.writeAll("(…)");
            if (scalar == '\'' or scalar == '\\') return w.print("'\\{s}'", .{buffer[0..len]});
            return w.print("'{s}'", .{buffer[0..len]});
        },
        .unit => return w.writeAll("⊤"),
        .local => {
            const at = r.env.locals_base + data.lhs;
            if (at >= bir.locals.len) return w.writeAll("(…)");
            const name = bir.locals[at].name.unwrap() orelse return w.writeAll("(…)");
            return w.writeAll(r.env.interner.slice(bir.symbols[name]));
        },
        .top => {
            if (data.lhs >= bir.decls.len) return w.writeAll("(…)");
            return w.writeAll(r.env.interner.slice(bir.symbol(bir.decls[data.lhs].name)));
        },
        else => return w.writeAll("(…)"),
    }
}

/// Whether `writeArg` spells `inst` rather than writing `(…)`.
fn spellable(bir: *const Bir, inst: Bir.Inst.Index) bool {
    return switch (bir.instTag(inst)) {
        .int, .float, .string, .char, .unit, .local, .top => true,
        else => false,
    };
}

/// The name a call of `callee` is written with: `String.join`, or `clamp`
/// for a prelude value of `Basics`.
fn writeCallee(r: *const Reporter, w: *std.Io.Writer, module: Graph.Index, value: Symbol) std.Io.Writer.Error!void {
    const module_text = r.env.interner.slice(r.env.graph.moduleName(module));
    if (!std.mem.eql(u8, module_text, "Basics")) try w.print("{s}.", .{module_text});
    try w.writeAll(r.env.interner.slice(value));
}

// ---- `xs.length` and `xs.length ()` ----------------------------------------

/// The value a dot on a value of type `actual` reached for: a `pub` value
/// named `field` of the module declaring `actual`'s type, whose first
/// parameter is that type — what `x.field` would call were it applied
/// (static-dispatch-spike.md §1.2). Its parameter count, with the module.
const Reached = struct { module: Graph.Index, module_name: Symbol, params: usize };

fn reachedFunction(r: *Reporter, actual: Var, field: Symbol) ?Reached {
    const app = switch (r.env.store.resolvedContent(actual)) {
        .structure => |s| switch (s) {
            .app => |a| a,
            else => return null,
        },
        else => return null,
    };
    if (app.type == .none) return null;
    const entry = r.env.types.entry(app.type);
    if (entry.module == r.env.module or entry.module.int() >= r.env.interfaces.len) return null;
    const iface = r.env.iface(entry.module);
    const value = iface.findValue(r.env.interner, field) orelse return null;
    const body = iface.term(iface.scheme(iface.values[@backingInt(value)].scheme).body);
    if (body.tag != .func) return null;
    const params = iface.range(body.lhs);
    if (params.len == 0) return null;
    const first = iface.term(@fromBackingInt(@intCast(params[0])));
    if (first.tag != .app) return null;
    const ref = iface.typeRef(@fromBackingInt(@intCast(first.lhs))) orelse return null;
    if (iface.symbol(ref.name) != entry.name) return null;
    return .{ .module = entry.module, .module_name = entry.module_name, .params = params.len };
}

/// §12.5's first row: `xs.length` on a value whose type is not a record,
/// where `length` is a function of the type's module.
fn fieldHint(r: *Reporter, w: *std.Io.Writer, region: Bir.Inst.Index, category: Category, actual: Var) Error!bool {
    if (category.tag != .field_access or category.index == Category.no_field) return false;
    const bir = r.env.bir;
    if (region.int() >= bir.insts.len or bir.instTag(region) != .field_access) return false;
    const field: Symbol = @fromBackingInt(@intCast(category.index));
    const reached = reachedFunction(r, actual, field) orelse return false;
    try writeReachedHint(r, w, reached, field, @fromBackingInt(@intCast(bir.instData(region).lhs)));
    return true;
}

/// The hint's text, shared by `xs.length` and `xs.length ()`.
fn writeReachedHint(r: *Reporter, w: *std.Io.Writer, reached: Reached, field: Symbol, receiver: Bir.Inst.Index) Error!void {
    const module_text = r.env.interner.slice(reached.module_name);
    const field_text = r.env.interner.slice(field);
    if (reached.params == 1) {
        w.print("\nHint: `{s}` is a function of `{s}`, not a field. Write `{s}.{s} ", .{ field_text, module_text, module_text, field_text }) catch return error.OutOfMemory;
        writeArg(r, w, receiver) catch return error.OutOfMemory;
        w.writeAll(
            \\` — a method
            \\call needs its other arguments, `x.m a`, so one that takes none is written as a
            \\call.
            \\
        ) catch return error.OutOfMemory;
        return;
    }
    w.print("\nHint: `{s}` is a function of `{s}`, not a field, and it takes {d} more argument{s}: write them after it, `", .{
        field_text, module_text, reached.params - 1, if (reached.params == 2) "" else "s",
    }) catch return error.OutOfMemory;
    writeArg(r, w, receiver) catch return error.OutOfMemory;
    w.print(".{s} …`.\n", .{field_text}) catch return error.OutOfMemory;
}

/// §12.5's second row: `xs.length ()`, a method call whose one argument is
/// `()`, of a method that takes none. Appended to the method's signature
/// mismatch, which is what such a call meets.
pub fn unitMethodHint(r: *Reporter, w: *std.Io.Writer, region: Bir.Inst.Index, module: Graph.Index, method: Symbol, found: Var) Error!void {
    const bir = r.env.bir;
    if (region.int() >= bir.insts.len or bir.instTag(region) != .method_call) return;
    const m = bir.extraData(@fromBackingInt(@intCast(bir.instData(region).rhs)), Bir.MethodCall);
    if (m.origin.spelling() != null) return;
    const args = bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index);
    if (args.len != 1 or bir.instTag(args[0]) != .unit) return;
    if (r.env.store.paramCount(found) != 1) return;
    const reached: Reached = .{ .module = module, .module_name = r.env.graph.moduleName(module), .params = 1 };
    try writeReachedHint(r, w, reached, method, @fromBackingInt(@intCast(bir.instData(region).lhs)));
}

// ---- `f(a, b)` --------------------------------------------------------------

/// §12.5's third row: a call whose one argument is a tuple literal written
/// against the callee, with as many elements as the callee takes
/// parameters. "Against" is the tuple's `(` being the token after the
/// callee's — the checker has no bytes, so `f (a, b)` qualifies too, which
/// is the same mistake.
pub fn tupleCallHint(r: *Reporter, w: *std.Io.Writer, call: Bir.Inst.Index, arity: u32) Error!bool {
    const bir = r.env.bir;
    if (call.int() >= bir.insts.len or bir.instTag(call) != .call) return false;
    const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(call).rhs))), Bir.Inst.Index);
    if (args.len != 1 or bir.instTag(args[0]) != .tuple) return false;
    const elements = bir.extraSlice(Bir.inlineRange(bir.instData(args[0])), Bir.Inst.Index);
    if (elements.len != arity) return false;
    const callee: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
    const tokens = bir.insts.items(.main_token);
    if (tokens[args[0].int()] != tokens[callee.int()] + 1) return false;
    const name = r.calleeOf(call).name;
    w.writeAll("\nHint: beni separates arguments with spaces: `") catch return error.OutOfMemory;
    w.writeAll(name) catch return error.OutOfMemory;
    for (elements) |e| {
        w.writeByte(' ') catch return error.OutOfMemory;
        writeArg(r, w, e) catch return error.OutOfMemory;
    }
    w.writeAll("`.\n") catch return error.OutOfMemory;
    return true;
}

// ---- A call in Elm's order -----------------------------------------------

/// What is known of one argument's type without asking the store to unify.
const ArgType = union(enum) {
    unknown,
    v: Var,
    /// A number literal: `Int` or `Float`.
    number,
    float,
    string,
    char,
};

fn argType(r: *Reporter, inst: Bir.Inst.Index) ArgType {
    const bir = r.env.bir;
    return switch (bir.instTag(inst)) {
        .int => .number,
        .float => .float,
        .string, .interp => .string,
        .char => .char,
        .local => if (r.env.localVar(bir.instData(inst).lhs)) |v| .{ .v = v } else .unknown,
        else => .unknown,
    };
}

/// Whether a value of `arg` could be passed where `iface`'s term `index`
/// is declared — read-only, and generous: anything not known fits.
fn fits(r: *Reporter, iface: *const Interface, arg: ArgType, index: u32, depth: u32) bool {
    const t = iface.term(@fromBackingInt(@intCast(index)));
    switch (t.tag) {
        .@"var", .err, .alias => return true,
        else => {},
    }
    switch (arg) {
        .unknown => return true,
        .number, .float, .string, .char => {
            if (t.tag != .app) return false;
            const ref = iface.typeRef(@fromBackingInt(@intCast(t.lhs))) orelse return true;
            const name = r.env.interner.slice(iface.symbol(ref.name));
            return switch (arg) {
                .number => std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Float"),
                .float => std.mem.eql(u8, name, "Float"),
                .string => std.mem.eql(u8, name, "String"),
                .char => std.mem.eql(u8, name, "Char"),
                else => unreachable,
            };
        },
        .v => |v| {
            const st = r.env.store;
            const s = switch (st.resolvedContent(v)) {
                .structure => |s| s,
                else => return true,
            };
            switch (s) {
                .app => |a| {
                    if (t.tag != .app) return false;
                    if (a.type == .none) return true;
                    const ref = iface.typeRef(@fromBackingInt(@intCast(t.lhs))) orelse return true;
                    if (iface.symbol(ref.name) != r.env.types.name(a.type)) return false;
                    if (depth == 0) return true;
                    const args = Walk.positions(st, v);
                    const terms = iface.range(t.rhs);
                    if (args.len != terms.len) return true;
                    for (0..args.len) |i| {
                        // A view the recursion cannot outgrow: nothing here
                        // makes a variable.
                        if (!fits(r, iface, .{ .v = Walk.positions(st, v)[i] }, terms[i], depth - 1)) return false;
                    }
                    return true;
                },
                .func => return t.tag == .func and Walk.function(st, v).?.params.len == iface.range(t.lhs).len,
                .tuple => return t.tag == .tuple and Walk.positions(st, v).len == iface.range(t.lhs).len,
                .record, .empty_record => return t.tag == .record or t.tag == .empty_record,
                .unit => return t.tag == .unit,
            }
        },
    }
}

/// §12.5's fourth row: a call of a core or platform function that failed
/// to check, whose arguments would fit its parameters in exactly one other
/// order — the order beni takes them in, when the call was written in
/// Elm's. Prints the call that way.
pub fn elmOrderHint(r: *Reporter, w: *std.Io.Writer, category: Category, actual: Var) Error!bool {
    if (category.tag != .call_arg or category.index == 0) return false;
    const call = category.owner.unwrap() orelse return false;
    const bir = r.env.bir;
    if (call.int() >= bir.insts.len or bir.instTag(call) != .call) return false;
    const callee: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
    if (bir.instTag(callee) != .ext_value) return false;
    // An operator's core function is never a call the author wrote.
    if (r.calleeOf(call).kind == .operator) return false;
    const data = bir.instData(callee);
    if (data.lhs >= r.env.interfaces.len) return false;
    const module: Graph.Index = @fromBackingInt(@intCast(data.lhs));
    switch (r.env.graph.modulePackage(module)) {
        .core, .platform => {},
        else => return false,
    }
    const iface = r.env.iface(module);
    if (data.rhs >= iface.values.len) return false;
    const body = iface.term(iface.scheme(iface.values[data.rhs].scheme).body);
    if (body.tag != .func) return false;
    const params = iface.range(body.lhs);
    const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(call).rhs))), Bir.Inst.Index);
    const max = 5;
    if (args.len != params.len or args.len < 2 or args.len > max) return false;
    if (category.index > args.len) return false;
    // A call this cannot write out is a hint that says nothing.
    for (args) |a| if (!spellable(bir, a)) return false;

    var types: [max]ArgType = undefined;
    // The failing argument's type is the one in hand — unless it is a
    // literal, whose own type is surer than a number-kinded variable.
    for (args, 0..) |a, i| types[i] = if (i == category.index - 1 and !isLiteral(bir, a)) .{ .v = actual } else argType(r, a);

    // Every order but the written one; the answer when exactly one fits.
    var order: [max]u8 = undefined;
    for (0..args.len) |i| order[i] = @intCast(i);
    // Of the orders that fit, the one that moves the fewest pairs: Elm puts
    // the subject last and beni first, and the arguments between keep
    // their order (`String.slice 1 3 s` is `String.slice s 1 3`). A tie
    // at the fewest is no answer.
    var found: ?[max]u8 = null;
    var fewest: u32 = std.math.maxInt(u32);
    var tied = false;
    while (nextPermutation(order[0..args.len])) {
        var all = true;
        for (0..args.len) |j| {
            if (!fits(r, iface, types[order[j]], params[j], 2)) {
                all = false;
                break;
            }
        }
        if (!all) continue;
        // An order that only trades arguments between parameters of one
        // type says nothing: `eq 1 "a"` is not `eq "a" 1` in Elm.
        var moves_type = false;
        for (0..args.len) |j| {
            if (!sameTerm(iface, params[order[j]], params[j])) moves_type = true;
        }
        if (!moves_type) continue;
        const moved = inversions(order[0..args.len]);
        if (moved < fewest) {
            fewest = moved;
            found = order;
            tied = false;
        } else if (moved == fewest) {
            tied = true;
        }
    }
    if (tied) return false;
    const chosen = found orelse return false;
    const value = iface.valueName(@fromBackingInt(@intCast(data.rhs)));
    w.writeAll("\nHint: `") catch return error.OutOfMemory;
    writeCallee(r, w, module, value) catch return error.OutOfMemory;
    w.writeAll("` takes its arguments in another order than Elm's — the subject first, a\nfunction last:\n\n    ") catch return error.OutOfMemory;
    writeCallee(r, w, module, value) catch return error.OutOfMemory;
    for (chosen[0..args.len]) |i| {
        w.writeByte(' ') catch return error.OutOfMemory;
        writeArg(r, w, args[i]) catch return error.OutOfMemory;
    }
    w.writeByte('\n') catch return error.OutOfMemory;
    return true;
}

/// Whether two declared parameters are written alike at the top: one
/// variable, or one type constructor.
fn sameTerm(iface: *const Interface, a: u32, b: u32) bool {
    const x = iface.term(@fromBackingInt(@intCast(a)));
    const y = iface.term(@fromBackingInt(@intCast(b)));
    if (x.tag != y.tag) return false;
    return switch (x.tag) {
        .@"var", .app, .alias => x.lhs == y.lhs,
        else => true,
    };
}

/// How many pairs `xs` has out of order.
fn inversions(xs: []const u8) u32 {
    var n: u32 = 0;
    for (xs, 0..) |a, i| {
        for (xs[i + 1 ..]) |b| {
            if (a > b) n += 1;
        }
    }
    return n;
}

/// The next permutation of `xs` in lexicographic order, or false after the
/// last. Starting from the sorted order skips the identity, which is the
/// written call.
fn nextPermutation(xs: []u8) bool {
    if (xs.len < 2) return false;
    var i = xs.len - 1;
    while (i > 0 and xs[i - 1] >= xs[i]) i -= 1;
    if (i == 0) return false;
    var j = xs.len - 1;
    while (xs[j] <= xs[i - 1]) j -= 1;
    std.mem.swap(u8, &xs[i - 1], &xs[j]);
    std.mem.reverse(u8, xs[i..]);
    return true;
}

/// The hints a `type_mismatch` may carry, before the general ones. True
/// when one was written.
pub fn mismatchHint(r: *Reporter, w: *std.Io.Writer, region: Bir.Inst.Index, category: Category, actual: Var) Error!bool {
    if (try fieldHint(r, w, region, category, actual)) return true;
    if (category.tag == .call_arg) {
        if (category.owner.unwrap()) |call| {
            if (call.int() < r.env.bir.insts.len and r.env.bir.instTag(call) == .call) {
                const arity = calleeArity(r, call);
                if (arity) |n| if (try tupleCallHint(r, w, call, n)) return true;
            }
        }
    }
    return false;
}

/// The declared parameter count of a call's callee, when it is a value of
/// another module's interface or of this one.
fn calleeArity(r: *Reporter, call: Bir.Inst.Index) ?u32 {
    const bir = r.env.bir;
    const callee: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
    const data = bir.instData(callee);
    switch (bir.instTag(callee)) {
        .ext_value => {
            if (data.lhs >= r.env.interfaces.len) return null;
            const iface = r.env.iface(@fromBackingInt(@intCast(data.lhs)));
            if (data.rhs >= iface.values.len) return null;
            const body = iface.term(iface.scheme(iface.values[data.rhs].scheme).body);
            if (body.tag != .func) return null;
            return @intCast(iface.range(body.lhs).len);
        },
        .top => {
            if (data.lhs >= r.env.decl_scheme.len) return null;
            const v = r.env.decl_scheme[data.lhs].unwrap() orelse return null;
            return r.env.store.paramCount(v);
        },
        .local => {
            const v = r.env.localVar(data.lhs) orelse return null;
            return r.env.store.paramCount(v);
        },
        else => return null,
    }
}

// ---- `suspicious_argument_order` -------------------------------------------

/// The kept functions whose call in Elm's order still type-checks
/// (`language.md` §12.4): `Basics.clamp` and seven of `String`'s.
fn suspicious(module: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, module, "Basics")) return std.mem.eql(u8, value, "clamp");
    if (!std.mem.eql(u8, module, "String")) return false;
    for ([_][]const u8{ "split", "contains", "startsWith", "endsWith", "indexes", "indices", "replace" }) |name| {
        if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

/// One walk of a module that checked clean: every call of a `suspicious`
/// function whose first argument — the subject — is a literal while its
/// last, where Elm's order puts the subject, is not (§12.5). The method
/// form is a `method_call`, never a `call`, so it is never here.
pub fn suspiciousOrder(r: *Reporter, set_decl: anytype) Error!void {
    const bir = r.env.bir;
    const tags = bir.insts.items(.tag);
    for (bir.decls, 0..) |decl, d| {
        set_decl.at(@intCast(d));
        for (decl.inst_start.int()..decl.inst_end.int()) |i| {
            if (tags[i] != .call) continue;
            const call: Bir.Inst.Index = @fromBackingInt(@intCast(i));
            const callee: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
            if (bir.instTag(callee) != .ext_value) continue;
            const data = bir.instData(callee);
            if (data.lhs >= r.env.interfaces.len) continue;
            const module: Graph.Index = @fromBackingInt(@intCast(data.lhs));
            if (r.env.graph.modulePackage(module) != .core) continue;
            const iface = r.env.iface(module);
            if (data.rhs >= iface.values.len) continue;
            const value = iface.valueName(@fromBackingInt(@intCast(data.rhs)));
            if (!suspicious(r.env.interner.slice(r.env.graph.moduleName(module)), r.env.interner.slice(value))) continue;
            const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(call).rhs))), Bir.Inst.Index);
            if (args.len < 2) continue;
            if (!isLiteral(bir, args[0]) or isLiteral(bir, args[args.len - 1])) continue;
            try warn(r, call, module, value, args);
        }
    }
    set_decl.at(null);
}

fn warn(r: *Reporter, call: Bir.Inst.Index, module: Graph.Index, value: Symbol, args: []const Bir.Inst.Index) Error!void {
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    try writeWarning(r, w, module, value, args);
    const message = try out.toOwnedSlice();
    errdefer r.gpa.free(message);
    try r.items.append(r.gpa, .{
        .code = .suspicious_argument_order,
        .module = r.env.module,
        .region = call,
        .severity = .warning,
        .message = message,
    });
}

fn writeWarning(r: *Reporter, w: *std.Io.Writer, module: Graph.Index, value: Symbol, args: []const Bir.Inst.Index) Error!void {
    const written = struct {
        fn call(rr: *Reporter, ww: *std.Io.Writer, m: Graph.Index, v: Symbol, order: []const Bir.Inst.Index, rotate: bool) std.Io.Writer.Error!void {
            try writeCallee(rr, ww, m, v);
            if (rotate) {
                try ww.writeByte(' ');
                try writeArg(rr, ww, order[order.len - 1]);
                for (order[0 .. order.len - 1]) |a| {
                    try ww.writeByte(' ');
                    try writeArg(rr, ww, a);
                }
            } else for (order) |a| {
                try ww.writeByte(' ');
                try writeArg(rr, ww, a);
            }
        }
    }.call;
    const value_text = r.env.interner.slice(value);
    w.writeAll("This call's first argument is a literal and its last is not:\n\n    ") catch return error.OutOfMemory;
    written(r, w, module, value, args, false) catch return error.OutOfMemory;
    w.writeAll("\n\nThat is the shape of a call in Elm's order, which puts the subject last. beni's\n`") catch return error.OutOfMemory;
    writeCallee(r, w, module, value) catch return error.OutOfMemory;
    w.writeAll("` takes the subject first, so if you meant Elm's call, write:\n\n    ") catch return error.OutOfMemory;
    written(r, w, module, value, args, true) catch return error.OutOfMemory;
    w.writeAll("\n\nIf the literal really is the subject, give it a name") catch return error.OutOfMemory;
    if (r.env.bir.instTag(args[0]) == .string) {
        w.writeAll(" or write the call as a method, `") catch return error.OutOfMemory;
        writeArg(r, w, args[0]) catch return error.OutOfMemory;
        w.print(".{s}", .{value_text}) catch return error.OutOfMemory;
        for (args[1..]) |a| {
            w.writeByte(' ') catch return error.OutOfMemory;
            writeArg(r, w, a) catch return error.OutOfMemory;
        }
        w.writeAll("`") catch return error.OutOfMemory;
    }
    w.writeAll(", and this warning goes.\n") catch return error.OutOfMemory;
}
