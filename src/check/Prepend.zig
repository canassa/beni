//! `prepend_in_loop` (`checker-v2.md` §35; `language.md` §6.8, *`[ x, …xs ]`
//! copies*): a warning at a list built by putting elements in front of an
//! accumulator a loop carries from one step to the next. A list is an
//! array with no room in front, so each such step copies the accumulator
//! and the loop is quadratic; `[ …acc, x ]` pushes, amortised O(1).
//!
//! Decided on BIR, after the module checked clean and was elaborated, so
//! the pass cannot change a type. Two shapes:
//!
//! - **a self-recursion**: an argument of a call of a function — top-level
//!   or block-bound, its parameters written or a lambda — to itself, with
//!   in result position a construction onto one of that function's own
//!   parameters: `go rest [ x, …acc ]`. A parameter is a local of its
//!   function alone, so a construction onto one can only be inside it;
//! - **a fold's callback**: the lambda written as the last argument of
//!   core's `List.foldl` or `List.foldr` — by name, piped, or a method call
//!   the checker resolved to one — with in result position a construction
//!   onto the lambda's last parameter, the accumulator the fold hands back.
//!
//! A construction is a chain of `List.cons` — what `[ a, b, …acc ]` lowers
//! to — whose innermost tail is the parameter itself. A result position is
//! the expression, a branch of a `case` (and so of an `if`) in result
//! position, or a block's last expression in result position.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Diagnostics = @import("Diagnostics.zig");
const Dispatch = @import("Dispatch.zig");
const CallStyle = @import("CallStyle.zig");

const Reporter = Diagnostics.Reporter;
const Error = Reporter.Error;
const Inst = Bir.Inst;

/// A result position never nests deeper than the source does; this bounds
/// the walk on a malformed tree all the same.
const max_depth = 256;

/// The elements a message prints before `…`.
const max_elements = 8;

/// Which loop carries the accumulator, for the message.
const Loop = enum { recursion, foldl, foldr };

/// One walk of a module that checked clean.
pub fn check(r: *Reporter, set_decl: anytype, dispatch: *const Dispatch) Error!void {
    const bir = r.env.bir;
    const tags = bir.insts.items(.tag);
    for (bir.decls, 0..) |decl, d| {
        if (!decl.kind.isValue()) continue;
        const body = decl.body.unwrap() orelse continue;
        set_decl.at(@intCast(d));
        for (decl.inst_start.int()..decl.inst_end.int()) |i| {
            const at: Inst.Index = @fromBackingInt(@intCast(i));
            switch (tags[i]) {
                .call => {
                    const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(at).lhs));
                    const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(at).rhs))), Inst.Index);
                    if (selfParams(bir, decl, @intCast(d), body, callee)) |params| {
                        for (args) |arg| try resultPosition(r, arg, params, .recursion, 0);
                        continue;
                    }
                    if (bir.instTag(callee) != .ext_value) continue;
                    const data = bir.instData(callee);
                    const loop = foldOf(r, data.lhs, data.rhs) orelse continue;
                    if (args.len > 0) try callback(r, args[args.len - 1], loop);
                },
                .method_call => {
                    const site = dispatch.siteOf(at) orelse continue;
                    const callee = site.callee.unwrap() orelse continue;
                    const loop = switch (dispatch.term(callee)) {
                        .ext => |e| foldOf(r, e.module.int(), @backingInt(e.value)),
                        else => null,
                    } orelse continue;
                    const m = bir.extraData(@fromBackingInt(@intCast(bir.instData(at).rhs)), Bir.MethodCall);
                    const args = bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Inst.Index);
                    if (args.len > 0) try callback(r, args[args.len - 1], loop);
                },
                else => {},
            }
        }
    }
    set_decl.at(null);
}

/// A fold's callback, when it is a lambda written at the call: its last
/// parameter is the accumulator.
fn callback(r: *Reporter, lambda: Inst.Index, loop: Loop) Error!void {
    const bir = r.env.bir;
    if (bir.instTag(lambda) != .lambda) return;
    const params = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(lambda).lhs))), Inst.Index);
    if (params.len < 2) return;
    try resultPosition(r, @fromBackingInt(@intCast(bir.instData(lambda).rhs)), params[params.len - 1 ..], loop, 0);
}

/// The parameter patterns of the function `callee` names, when it names
/// the function whose instructions these are: declaration `d` (a `top`)
/// or a block-bound function of it (a `local` a `let_def` binds). Null
/// otherwise.
fn selfParams(bir: *const Bir, decl: Bir.Decl, d: u32, body: Inst.Index, callee: Inst.Index) ?[]const Inst.Index {
    const data = bir.instData(callee);
    switch (bir.instTag(callee)) {
        .top => {
            if (data.lhs != d) return null;
            const params = bir.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Inst.Index);
            if (params.len > 0) return params;
            return lambdaParams(bir, body);
        },
        .local => {
            const tags = bir.insts.items(.tag);
            for (decl.inst_start.int()..decl.inst_end.int()) |i| {
                if (tags[i] != .let_def) continue;
                const at: Inst.Index = @fromBackingInt(@intCast(i));
                const def = bir.extraData(@fromBackingInt(@intCast(bir.instData(at).lhs)), Bir.LetDef);
                if (def.local != data.lhs) continue;
                const params = bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Inst.Index);
                if (params.len > 0) return params;
                return lambdaParams(bir, @fromBackingInt(@intCast(bir.instData(at).rhs)));
            }
            return null;
        },
        else => return null,
    }
}

fn lambdaParams(bir: *const Bir, inst: Inst.Index) ?[]const Inst.Index {
    if (bir.instTag(inst) != .lambda) return null;
    return bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(inst).lhs))), Inst.Index);
}

/// Value `value` of module `module` as core's `List.foldl` or `List.foldr`.
fn foldOf(r: *const Reporter, module_int: u32, value: u32) ?Loop {
    const name = coreListValue(r, module_int, value) orelse return null;
    if (std.mem.eql(u8, name, "foldl")) return .foldl;
    if (std.mem.eql(u8, name, "foldr")) return .foldr;
    return null;
}

/// The name of value `value` of module `module_int` when that module is
/// core's `List`, or null.
fn coreListValue(r: *const Reporter, module_int: u32, value: u32) ?[]const u8 {
    if (module_int >= r.env.interfaces.len) return null;
    const module: Graph.Index = @fromBackingInt(@intCast(module_int));
    if (r.env.graph.modulePackage(module) != .core) return null;
    if (!std.mem.eql(u8, r.env.interner.slice(r.env.graph.moduleName(module)), "List")) return null;
    const iface = r.env.iface(module);
    if (value >= iface.values.len) return null;
    return r.env.interner.slice(iface.valueName(@fromBackingInt(@intCast(value))));
}

/// The two arguments of `inst` when it is a call of core's `List.cons`.
fn consArgs(r: *const Reporter, inst: Inst.Index) ?[]const Inst.Index {
    const bir = r.env.bir;
    if (bir.instTag(inst) != .call) return null;
    const callee: Inst.Index = @fromBackingInt(@intCast(bir.instData(inst).lhs));
    if (bir.instTag(callee) != .ext_value) return null;
    const data = bir.instData(callee);
    const name = coreListValue(r, data.lhs, data.rhs) orelse return null;
    if (!std.mem.eql(u8, name, "cons")) return null;
    const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(inst).rhs))), Inst.Index);
    if (args.len != 2) return null;
    return args;
}

/// Whether `inst` reads one of the locals the patterns `params` bind as
/// plain variables.
fn readsParam(bir: *const Bir, inst: Inst.Index, params: []const Inst.Index) bool {
    if (bir.instTag(inst) != .local) return false;
    const local = bir.instData(inst).lhs;
    for (params) |p| {
        if (bir.instTag(p) == .pat_var and bir.instData(p).lhs == local) return true;
    }
    return false;
}

/// Every construction onto a parameter in `inst`'s result positions.
fn resultPosition(r: *Reporter, inst: Inst.Index, params: []const Inst.Index, loop: Loop, depth: u32) Error!void {
    const bir = r.env.bir;
    if (depth > max_depth or inst.int() >= bir.insts.len) return;
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .call => {
            var at = inst;
            var n: u32 = 0;
            while (consArgs(r, at)) |args| : (n += 1) {
                if (n > max_depth) return;
                at = args[1];
            }
            if (n > 0 and readsParam(bir, at, params)) try warn(r, inst, at, loop);
        },
        .case => {
            const branches = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index);
            for (branches) |b| {
                if (bir.instTag(b) != .branch) continue;
                try resultPosition(r, @fromBackingInt(@intCast(bir.instData(b).rhs)), params, loop, depth + 1);
            }
        },
        .let => try resultPosition(r, @fromBackingInt(@intCast(data.rhs)), params, loop, depth + 1),
        else => {},
    }
}

fn warn(r: *Reporter, construction: Inst.Index, acc: Inst.Index, loop: Loop) Error!void {
    var out = r.writer();
    defer out.deinit();
    writeWarning(r, &out.writer, construction, acc, loop) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    errdefer r.gpa.free(message);
    try r.items.append(r.gpa, .{
        .code = .prepend_in_loop,
        .module = r.env.module,
        .region = construction,
        .severity = .warning,
        .message = message,
    });
}

/// The construction's elements, outermost first (`[ a, b, …acc ]` is `a`,
/// then `b`), or reversed; at most `max_elements`, then `…`.
fn writeElements(r: *const Reporter, w: *std.Io.Writer, construction: Inst.Index, reversed: bool) std.Io.Writer.Error!void {
    var elements: [max_elements]Inst.Index = undefined;
    var n: usize = 0;
    var more = false;
    var at = construction;
    while (consArgs(r, at)) |args| {
        if (n == elements.len) {
            more = true;
            break;
        }
        elements[n] = args[0];
        n += 1;
        at = args[1];
    }
    for (0..n) |k| {
        const e = if (reversed) elements[n - 1 - k] else elements[k];
        if (k > 0) try w.writeAll(", ");
        try CallStyle.writeArg(r, w, e);
    }
    if (more) try w.writeAll(", …");
}

fn writeWarning(r: *const Reporter, w: *std.Io.Writer, construction: Inst.Index, acc: Inst.Index, loop: Loop) std.Io.Writer.Error!void {
    try w.writeAll("This puts elements in front of `");
    try CallStyle.writeArg(r, w, acc);
    switch (loop) {
        .recursion => try w.writeAll("`, which this function hands back to\nitself, so it happens at every step of a loop:\n\n    [ "),
        .foldl, .foldr => try w.print("`, the accumulator this `List.{s}` hands\nback to its callback, so it happens at every step:\n\n    [ ", .{@tagName(loop)}),
    }
    try writeElements(r, w, construction, false);
    try w.writeAll(", …");
    try CallStyle.writeArg(r, w, acc);
    try w.writeAll(" ]\n\nA list is an array, so every step copies the whole accumulator, and the loop\ntakes time that grows with the square of the list's length. Add at the end\ninstead, which takes the same short time at every step:\n\n    [ …");
    try CallStyle.writeArg(r, w, acc);
    try w.writeAll(", ");
    try writeElements(r, w, construction, loop != .foldr);
    try w.writeAll(" ]\n\n");
    switch (loop) {
        .recursion, .foldl => try w.writeAll(
            \\That keeps the elements in the order they arrive, so the `List.reverse` that
            \\put a prepended result back in order is no longer needed.
            \\
        ),
        .foldr => try w.writeAll(
            \\`List.foldr` hands over the last element first, so to keep the order write
            \\the loop as `List.foldl`, which hands over the first element first.
            \\
        ),
    }
    try w.writeAll("\nIf the prepend is meant — the list stays short — give the new list a name\nfirst, and this warning goes.");
}
