//! The suspendable form (transparent-effects-proposal.md §16.3): one pass
//! over a function body that `Lower` has already written, turning each
//! suspension point it marked into the continuation that follows it.
//!
//! **Lowering marks, this pass splits.** `Lower` lowers a call that may
//! suspend exactly like any other hoist — `?`'s machinery pins what was
//! written before it — and leaves a marker statement in the list it was
//! lowering into: `$$suspend(<the call>, <its temporary>)`. Everything the
//! list holds after the marker is the rest of the function from that point,
//! because a suspension point is only ever written where every path through
//! the rest ends the function (tail position, or a join below). This pass
//! then rewrites, list by list:
//!
//!   - Call first and bind the result. Only the sentinel branch constructs
//!     a frame for the rest and hands it to the kernel; the synchronous
//!     branch continues in place. Tail calls return directly.
//!   - In a parked loop frame a `continue` re-enters the loop with captured
//!     state. Building loops append their completed re-entry's list.
//!
//! Joins write their rest into the leaves, so no join closure is allocated
//! on the fast path. The driver reverses each new frame segment once and
//! resumes it iteratively. Functions that cannot suspend are unchanged.
//!
//! **Nothing here guesses.** A marker in a statement list whose rest can
//! fall through — the one shape lowering must never produce — is
//! `error.FallsThrough`, which `Lower` reports rather than emit a program
//! that silently skips its own code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const JsIr = @import("JsIr.zig");

const Node = JsIr.Node;
const NameIndex = JsIr.NameIndex;

/// `InsideTry`: a marker inside a `try … finally` (`Js.finally`), whose
/// cleanup would run when the call parks rather than when the guarded code
/// ends, or inside a `try … catch` (`Js.catchIf`), which would not see what
/// the code after the park throws. Its arguments are `sync`, so the checker refuses a suspending one
/// before this pass could see it; lowering reports it as a compiler fault.
pub const Error = error{ OutOfMemory, FallsThrough, InsideTry };

/// The names the pass recognises and writes.
pub const Names = struct {
    /// `$$suspend(call, temp)`, `$$join($j)`, `$$joined($j, $t)`.
    marker: NameIndex,
    join: NameIndex,
    joined: NameIndex,
    /// Private `Task.chain` and public `Task.isWaiting`, imported by `Lower`.
    and_then: NameIndex,
    is_waiting: NameIndex,
};

/// A tail-call loop the body belongs to: its label, the function that
/// re-enters it, and that function's parameters in order.
pub const Loop = struct {
    label: NameIndex,
    callee: NameIndex,
    params: []const NameIndex,
    /// A building loop's destination (`backend.md` §8, *Tail calls modulo
    /// cons, onto an array*): `$root`, the `List$close` that hands it over
    /// with a list added after it, and the parameter of the continuation
    /// that adds a re-entry's list. `.none` for a loop that does not build.
    root: NameIndex = .none,
    close: NameIndex = .none,
    built: NameIndex = .none,
};

pub const Mode = enum { closure, loop };

pub const Pass = struct {
    b: *JsIr.Builder,
    scratch: Allocator,
    names: Names,
    loop: ?Loop,
    /// The bindings the release optimiser keeps (`Lower.effect_keep`): a
    /// copy of one is kept too.
    keep: ?*std.ArrayList(Node.Index) = null,
    helpers: *std.ArrayList(Node.Index),
    helper_base: NameIndex,
    compiler_locals: []const bool,
    bind: NameIndex,
    helper_next: u32 = 1,
    local_next: u32 = 1,
    mutable: std.DynamicBitSetUnmanaged = .{},
    accessors: []const Capture = &.{},
    tails: std.ArrayList(Tail) = .empty,

    const Capture = struct { name: NameIndex, param: NameIndex, mutable: bool };
    const Tail = struct { list: []const Node.Index, input: NameIndex, name: NameIndex, captures: []const Capture };

    pub fn prepare(p: *Pass, list: []const Node.Index) Allocator.Error!void {
        var bound = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        p.mutable = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        try p.bindingsIn(list, &bound, &p.mutable);
    }

    // ---- Reading the builder's nodes ------------------------------------

    inline fn tag(p: *const Pass, n: Node.Index) Node.Tag {
        return p.b.tagOf(n);
    }

    inline fn data(p: *const Pass, n: Node.Index) Node.Data {
        return p.b.dataOf(n);
    }

    fn posOf(p: *const Pass, n: Node.Index) u32 {
        return p.b.nodes.items(.pos)[n.int()];
    }

    /// `JsIr.Node.flags.host` of a `call`.
    fn hostOf(p: *const Pass, n: Node.Index) bool {
        return p.b.nodes.items(.flags)[n.int()].host;
    }

    fn word(p: *const Pass, at: u32) u32 {
        return p.b.extra.items[at];
    }

    /// The `SubRange` record at `at`.
    fn rangeAt(p: *const Pass, at: u32) JsIr.SubRange {
        return .{ .start = @fromBackingInt(@intCast(p.word(at))), .end = @fromBackingInt(@intCast(p.word(at + 1))) };
    }

    /// A range's nodes, copied: the builder's `extra` moves as it grows.
    fn nodesOf(p: *const Pass, r: JsIr.SubRange) Allocator.Error![]Node.Index {
        const words = p.b.extra.items[@backingInt(r.start)..@backingInt(r.end)];
        const out = try p.scratch.alloc(Node.Index, words.len);
        for (out, words) |*o, w| o.* = @fromBackingInt(@intCast(w));
        return out;
    }

    fn namesOf(p: *const Pass, r: JsIr.SubRange) Allocator.Error![]NameIndex {
        const words = p.b.extra.items[@backingInt(r.start)..@backingInt(r.end)];
        const out = try p.scratch.alloc(NameIndex, words.len);
        for (out, words) |*o, w| o.* = @fromBackingInt(@intCast(w));
        return out;
    }

    fn func(p: *const Pass, at: u32) JsIr.Func {
        return .{
            .params_start = @fromBackingInt(@intCast(p.word(at))),
            .params_end = @fromBackingInt(@intCast(p.word(at + 1))),
            .body_start = @fromBackingInt(@intCast(p.word(at + 2))),
            .body_end = @fromBackingInt(@intCast(p.word(at + 3))),
        };
    }

    fn ifOf(p: *const Pass, at: u32) JsIr.If {
        return .{
            .then_start = @fromBackingInt(@intCast(p.word(at))),
            .then_end = @fromBackingInt(@intCast(p.word(at + 1))),
            .else_start = @fromBackingInt(@intCast(p.word(at + 2))),
            .else_end = @fromBackingInt(@intCast(p.word(at + 3))),
        };
    }

    // ---- Building ---------------------------------------------------------

    fn add(p: *Pass, t: Node.Tag, at: u32, lhs: u32, rhs: u32) Error!Node.Index {
        return p.b.addParts(t, at, lhs, rhs);
    }

    fn ident(p: *Pass, n: NameIndex, at: u32) Error!Node.Index {
        return p.add(.ident, at, @backingInt(n), 0);
    }

    fn call(p: *Pass, callee: Node.Index, args: []const Node.Index, at: u32) Error!Node.Index {
        const range = try p.b.addRange(args);
        const record = try p.b.addRecord(range);
        return p.add(.call, at, callee.int(), @backingInt(record));
    }

    fn arrow(p: *Pass, params: []const NameIndex, body: []const Node.Index, at: u32) Error!Node.Index {
        const params_range = try p.b.addNames(params);
        const body_range = try p.b.addRange(body);
        const record = try p.b.addRecord(JsIr.Func{
            .params_start = params_range.start,
            .params_end = params_range.end,
            .body_start = body_range.start,
            .body_end = body_range.end,
        });
        return p.add(.arrow, at, @backingInt(record), Node.arrow_plain);
    }

    fn ret(p: *Pass, value: Node.Index, at: u32) Error!Node.Index {
        return p.add(.return_stmt, at, @backingInt(value.toOptional()), 0);
    }

    fn block(p: *Pass, t: Node.Tag, at: u32, lhs: u32, body: []const Node.Index) Error!Node.Index {
        const range = try p.b.addRange(body);
        const record = try p.b.addRecord(range);
        return p.add(t, at, lhs, @backingInt(record));
    }

    // ---- Markers ----------------------------------------------------------

    /// The marker call's arguments when `n` is `expr_stmt($$<which>(…))`.
    fn markerArgs(p: *const Pass, n: Node.Index, which: NameIndex) ?JsIr.SubRange {
        if (p.tag(n) != .expr_stmt) return null;
        const e: Node.Index = @fromBackingInt(@intCast(p.data(n).lhs));
        if (p.tag(e) != .call) return null;
        const callee: Node.Index = @fromBackingInt(@intCast(p.data(e).lhs));
        if (p.tag(callee) != .ident or p.data(callee).lhs != @backingInt(which)) return null;
        return p.rangeAt(p.data(e).rhs);
    }

    fn isMarker(p: *const Pass, n: Node.Index) bool {
        return p.markerArgs(n, p.names.marker) != null or p.markerArgs(n, p.names.join) != null or p.markerArgs(n, p.names.joined) != null;
    }

    fn argNode(p: *const Pass, r: JsIr.SubRange, i: u32) Node.Index {
        return @fromBackingInt(@intCast(p.word(@backingInt(r.start) + i)));
    }

    fn argName(p: *const Pass, r: JsIr.SubRange, i: u32) NameIndex {
        return @fromBackingInt(@intCast(p.data(p.argNode(r, i)).lhs));
    }

    /// Whether statement `n` holds a marker, or — `continues` — a `continue`
    /// of the loop, anywhere in its statement lists (never inside a
    /// function: a nested function was rewritten when it was built).
    fn holds(p: *const Pass, n: Node.Index, continues: bool) Error!bool {
        if (p.isMarker(n)) return true;
        const d = p.data(n);
        switch (p.tag(n)) {
            .continue_stmt => return continues and p.loop != null and d.lhs == @backingInt(p.loop.?.label),
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                return try p.listHolds(try p.nodesOf(i.thenBody()), continues) or try p.listHolds(try p.nodesOf(i.elseBody()), continues);
            },
            .switch_stmt, .switch_case, .block_stmt => return p.listHolds(try p.nodesOf(p.rangeAt(d.rhs)), continues),
            .try_stmt => return try p.listHolds(try p.nodesOf(p.rangeAt(d.rhs)), continues) or
                try p.listHolds(try p.nodesOf(p.rangeAt(d.rhs + 2)), continues) or
                try p.listHolds(try p.nodesOf(p.rangeAt(d.rhs + 4)), continues),
            else => return false,
        }
    }

    fn listHolds(p: *const Pass, list: []const Node.Index, continues: bool) Error!bool {
        for (list) |n| if (try p.holds(n, continues)) return true;
        return false;
    }

    /// Whether every path through `list` leaves it: the rest of a function
    /// after a suspension point must, or moving it into a continuation
    /// would skip what follows it.
    fn terminates(p: *const Pass, list: []const Node.Index) Error!bool {
        if (list.len == 0) return false;
        const last = list[list.len - 1];
        const d = p.data(last);
        switch (p.tag(last)) {
            .return_stmt, .continue_stmt, .throw_stmt => return true,
            // A `break` cannot leave a continuation: a list that ends in one
            // is not the rest of a function (plan §2.3).
            .break_stmt => return false,
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                return try p.terminates(try p.nodesOf(i.thenBody())) and try p.terminates(try p.nodesOf(i.elseBody()));
            },
            .block_stmt => return p.terminates(try p.nodesOf(p.rangeAt(d.rhs))),
            // The cleanup ends normally or leaves; either way, a body that
            // always leaves takes the `try` with it — when nothing catches
            // what it throws, or when the `catch` block always leaves too.
            .try_stmt => {
                const catches: JsIr.NameIndex = @fromBackingInt(@intCast(p.word(d.rhs + 6)));
                const body = try p.terminates(try p.nodesOf(p.rangeAt(d.rhs)));
                const caught = catches == .none or try p.terminates(try p.nodesOf(p.rangeAt(d.rhs + 4)));
                return (body and caught) or try p.terminates(try p.nodesOf(p.rangeAt(d.rhs + 2)));
            },
            .switch_stmt => {
                var has_default = false;
                for (try p.nodesOf(p.rangeAt(d.rhs))) |c| {
                    if (p.data(c).lhs == @backingInt(Node.OptionalIndex.none)) has_default = true;
                    if (!try p.terminates(try p.nodesOf(p.rangeAt(p.data(c).rhs)))) return false;
                }
                return has_default;
            },
            // A shared leaf written after the block the tree breaks out of
            // is the list's own last statements; `while (true)` never falls
            // out.
            .while_true => return true,
            else => return false,
        }
    }

    // ---- The rewrite ------------------------------------------------------

    /// `list` rewritten in `mode`, with every marker in it and below it gone.
    pub fn rewrite(p: *Pass, list: []const Node.Index, mode: Mode) Error![]Node.Index {
        var out: std.ArrayList(Node.Index) = .empty;
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            const n = list[i];
            if (p.markerArgs(n, p.names.marker)) |args| {
                const call_node = p.argNode(args, 0);
                const temp = p.argName(args, 1);
                const rest = list[i + 1 ..];
                if (!try p.terminates(rest)) return error.FallsThrough;
                const at = p.posOf(call_node);
                // Tail results, including the sentinel, pass straight through.
                if (rest.len == 1 and p.isReturnOf(rest[0], temp)) {
                    try out.append(p.scratch, try p.ret(call_node, at));
                    return out.items;
                }
                try p.liftFunctions(list[0..i], call_node, rest, &out);
                const remaining = try p.withoutLifted(rest, out.items);
                const shared: ?Tail = try p.tail(remaining, temp, at);
                const parked_suffix = shared.?;
                const frame_args = try p.scratch.alloc(Node.Index, parked_suffix.captures.len + 1);
                frame_args[0] = try p.add(.null_lit, at, 0, 0);
                for (parked_suffix.captures, frame_args[1..]) |capture, *arg| arg.* = try p.captureExpr(capture, at);
                const bound = try p.add(.member, at, (try p.ident(parked_suffix.name, at)).int(), @backingInt(p.bind));
                const k = try p.call(bound, frame_args, at);
                try out.append(p.scratch, try p.add(.const_decl, at, @backingInt(temp), call_node.int()));
                const result = try p.ident(temp, at);
                const parked = try p.call(try p.ident(p.names.is_waiting, at), &.{result}, at);
                const chained = try p.call(try p.ident(p.names.and_then, at), &.{ result, k }, at);
                const then_range = try p.b.addRange(&.{try p.ret(chained, at)});
                const else_range = try p.b.addRange(&.{});
                const record = try p.b.addRecord(JsIr.If{
                    .then_start = then_range.start,
                    .then_end = then_range.end,
                    .else_start = else_range.start,
                    .else_end = else_range.end,
                });
                try out.append(p.scratch, try p.add(.if_stmt, at, parked.int(), @backingInt(record)));
                if (mode == .closure) if (shared) |suffix| {
                    const direct = for (suffix.captures) |cap| {
                        if (cap.mutable and p.accessor(cap.name) == null) break false;
                    } else true;
                    if (direct) {
                        const fast_args = try p.scratch.alloc(Node.Index, suffix.captures.len + 1);
                        for (suffix.captures, fast_args[0..suffix.captures.len]) |cap, *arg| arg.* = try p.captureExpr(cap, at);
                        fast_args[suffix.captures.len] = try p.ident(temp, at);
                        const resumed = try p.call(try p.ident(suffix.name, at), fast_args, at);
                        try out.append(p.scratch, try p.ret(resumed, at));
                        return out.items;
                    }
                };
                try out.appendSlice(p.scratch, try p.rewrite(remaining, mode));
                return out.items;
            }
            if (p.markerArgs(n, p.names.join)) |args| {
                const j = p.argName(args, 0);
                const close = for (list[i + 1 ..], i + 1..) |m, at| {
                    if (p.markerArgs(m, p.names.joined)) |jargs| {
                        if (p.argName(jargs, 0) == j) break at;
                    }
                } else return error.FallsThrough;
                const jargs = p.markerArgs(list[close], p.names.joined).?;
                const param = p.argName(jargs, 1);
                const tree = list[i + 1 .. close];
                const rest = list[close + 1 ..];
                if (!try p.terminates(rest) or !try p.terminates(tree)) return error.FallsThrough;
                const inlined = try p.substituteJoin(tree, j, param, rest);
                try out.appendSlice(p.scratch, try p.rewrite(inlined, mode));
                return out.items;
            }
            try out.append(p.scratch, try p.rewriteNode(n, mode));
        }
        return out.items;
    }

    fn isReturnOf(p: *const Pass, n: Node.Index, temp: NameIndex) bool {
        if (p.tag(n) != .return_stmt) return false;
        const v: Node.OptionalIndex = @fromBackingInt(@intCast(p.data(n).lhs));
        const value = v.unwrap() orelse return false;
        return p.tag(value) == .ident and p.data(value).lhs == @backingInt(temp);
    }

    /// One statement, its lists rewritten when they hold a marker — or, in
    /// closure mode inside a loop, a `continue` of the loop, which becomes
    /// the loop's function called again.
    fn rewriteNode(p: *Pass, n: Node.Index, mode: Mode) Error!Node.Index {
        const continues = mode == .closure and p.loop != null;
        if (!try p.holds(n, continues)) return n;
        const d = p.data(n);
        const at = p.posOf(n);
        switch (p.tag(n)) {
            .continue_stmt => {
                const lp = p.loop.?;
                const args = try p.scratch.alloc(Node.Index, lp.params.len);
                for (args, lp.params) |*arg, param| arg.* = try p.ident(param, at);
                const reentry = try p.call(try p.ident(lp.callee, at), args, at);
                if (lp.root == .none) return p.ret(reentry, at);
                // Only a parked re-entry retains the building destination.
                const result = try p.ident(lp.built, at);
                const closed = try p.call(try p.ident(lp.close, at), &.{ try p.ident(lp.root, at), try p.ident(lp.built, at) }, at);
                const k = try p.arrow(&.{lp.built}, &.{try p.ret(closed, at)}, at);
                const parked = try p.call(try p.ident(p.names.is_waiting, at), &.{result}, at);
                const chained = try p.call(try p.ident(p.names.and_then, at), &.{ result, k }, at);
                const yes = try p.b.addRange(&.{try p.ret(chained, at)});
                const no = try p.b.addRange(&.{});
                const record = try p.b.addRecord(JsIr.If{
                    .then_start = yes.start,
                    .then_end = yes.end,
                    .else_start = no.start,
                    .else_end = no.end,
                });
                return p.block(.block_stmt, at, @backingInt(NameIndex.none), &.{
                    try p.add(.const_decl, at, @backingInt(lp.built), reentry.int()),
                    try p.add(.if_stmt, at, parked.int(), @backingInt(record)),
                    try p.ret(try p.clone(closed), at),
                });
            },
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                const then = try p.rewrite(try p.nodesOf(i.thenBody()), mode);
                const otherwise = try p.rewrite(try p.nodesOf(i.elseBody()), mode);
                const then_range = try p.b.addRange(then);
                const else_range = try p.b.addRange(otherwise);
                const record = try p.b.addRecord(JsIr.If{
                    .then_start = then_range.start,
                    .then_end = then_range.end,
                    .else_start = else_range.start,
                    .else_end = else_range.end,
                });
                return p.add(.if_stmt, at, d.lhs, @backingInt(record));
            },
            .switch_stmt, .switch_case, .block_stmt => {
                const body = try p.rewrite(try p.nodesOf(p.rangeAt(d.rhs)), mode);
                return p.block(p.tag(n), at, d.lhs, body);
            },
            // A continuation cannot stay inside the guard: the cleanup would
            // run when the call parks, before the rest it guards.
            .try_stmt => return error.InsideTry,
            else => return n,
        }
    }

    /// Loop mode's join: every `return $j(value)` of `tree` becomes `const
    /// $t = value;` and a copy of `rest`.
    fn substituteJoin(p: *Pass, tree: []const Node.Index, j: NameIndex, param: NameIndex, rest: []const Node.Index) Error![]Node.Index {
        var out: std.ArrayList(Node.Index) = .empty;
        for (tree) |n| {
            if (p.joinValue(n, j)) |value| {
                const at = p.posOf(n);
                try out.append(p.scratch, try p.add(.const_decl, at, @backingInt(param), value.int()));
                try out.appendSlice(p.scratch, try p.cloneList(rest));
                continue;
            }
            const d = p.data(n);
            const at = p.posOf(n);
            switch (p.tag(n)) {
                .if_stmt => {
                    const i = p.ifOf(d.rhs);
                    const then = try p.substituteJoin(try p.nodesOf(i.thenBody()), j, param, rest);
                    const otherwise = try p.substituteJoin(try p.nodesOf(i.elseBody()), j, param, rest);
                    const then_range = try p.b.addRange(then);
                    const else_range = try p.b.addRange(otherwise);
                    const record = try p.b.addRecord(JsIr.If{
                        .then_start = then_range.start,
                        .then_end = then_range.end,
                        .else_start = else_range.start,
                        .else_end = else_range.end,
                    });
                    try out.append(p.scratch, try p.add(.if_stmt, at, d.lhs, @backingInt(record)));
                },
                .switch_stmt, .switch_case, .block_stmt => {
                    const body = try p.substituteJoin(try p.nodesOf(p.rangeAt(d.rhs)), j, param, rest);
                    try out.append(p.scratch, try p.block(p.tag(n), at, d.lhs, body));
                },
                else => try out.append(p.scratch, n),
            }
        }
        return out.items;
    }

    /// `value` when `n` is `return $j(value)`.
    fn joinValue(p: *const Pass, n: Node.Index, j: NameIndex) ?Node.Index {
        if (p.tag(n) != .return_stmt) return null;
        const v: Node.OptionalIndex = @fromBackingInt(@intCast(p.data(n).lhs));
        const e = v.unwrap() orelse return null;
        if (p.tag(e) != .call) return null;
        const callee: Node.Index = @fromBackingInt(@intCast(p.data(e).lhs));
        if (p.tag(callee) != .ident or p.data(callee).lhs != @backingInt(j)) return null;
        const args = p.rangeAt(p.data(e).rhs);
        if (args.len() != 1) return null;
        return p.argNode(args, 0);
    }

    // ---- `let` functions a continuation would hide -------------------------

    /// A `function` declaration of `rest` that the statements before the
    /// suspension point, or the call itself, name is hoisted in front of the
    /// point (with the declarations it names in turn), so a `let` function
    /// is still readable anywhere in its `let` (`language.md` §7).
    fn liftFunctions(p: *Pass, before: []const Node.Index, call_node: Node.Index, rest: []const Node.Index, out: *std.ArrayList(Node.Index)) Error!void {
        var any = false;
        for (rest) |n| any = any or p.tag(n) == .func_decl;
        if (!any) return;
        var named = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        for (before) |n| try p.namesIn(n, &named, null);
        try p.namesIn(call_node, &named, null);
        var lifted = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        var grew = true;
        while (grew) {
            grew = false;
            for (rest) |n| {
                if (p.tag(n) != .func_decl) continue;
                const name = p.data(n).lhs;
                if (lifted.isSet(name) or !named.isSet(name)) continue;
                lifted.set(name);
                try p.namesIn(n, &named, null);
                grew = true;
            }
        }
        for (rest) |n| {
            if (p.tag(n) == .func_decl and lifted.isSet(p.data(n).lhs)) try out.append(p.scratch, n);
        }
    }

    /// `rest` without the declarations `liftFunctions` put in `hoisted`.
    fn withoutLifted(p: *Pass, rest: []const Node.Index, hoisted: []const Node.Index) Error![]const Node.Index {
        if (hoisted.len == 0) return rest;
        var kept: std.ArrayList(Node.Index) = .empty;
        outer: for (rest) |n| {
            for (hoisted) |h| if (h == n) continue :outer;
            try kept.append(p.scratch, n);
        }
        return kept.items;
    }

    /// Every name an `ident` under `n` reads, functions included.
    fn namesIn(p: *Pass, n: Node.Index, into: *std.DynamicBitSetUnmanaged, order: ?*std.ArrayList(NameIndex)) Allocator.Error!void {
        var stack: std.ArrayList(Node.Index) = .empty;
        try stack.append(p.scratch, n);
        while (stack.pop()) |x| {
            const children_start = stack.items.len;
            const d = p.data(x);
            switch (p.tag(x)) {
                .ident => if (d.lhs < into.bit_length and !into.isSet(d.lhs)) {
                    into.set(d.lhs);
                    if (order) |names| try names.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                },
                .const_decl, .assign_stmt, .index_get, .assign, .computed_property => {
                    if (p.tag(x) != .const_decl) try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                    try stack.append(p.scratch, @fromBackingInt(@intCast(d.rhs)));
                },
                .let_decl, .return_stmt => {
                    const v: Node.OptionalIndex = @fromBackingInt(@intCast(if (p.tag(x) == .let_decl) d.rhs else d.lhs));
                    if (v.unwrap()) |e| try stack.append(p.scratch, e);
                },
                .expr_stmt, .throw_stmt, .spread_property => try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs))),
                .member, .unary => try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs))),
                .property => try stack.append(p.scratch, @fromBackingInt(@intCast(d.rhs))),
                .func_decl => try stack.appendSlice(p.scratch, try p.nodesOf(p.func(d.rhs).body())),
                .arrow => try stack.appendSlice(p.scratch, try p.nodesOf(p.func(d.lhs).body())),
                .if_stmt => {
                    const i = p.ifOf(d.rhs);
                    try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                    try stack.appendSlice(p.scratch, try p.nodesOf(i.thenBody()));
                    try stack.appendSlice(p.scratch, try p.nodesOf(i.elseBody()));
                },
                .switch_stmt => {
                    try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                },
                .switch_case => {
                    const t: Node.OptionalIndex = @fromBackingInt(@intCast(d.lhs));
                    if (t.unwrap()) |e| try stack.append(p.scratch, e);
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                },
                .block_stmt, .while_true => try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs))),
                .try_stmt => {
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs + 2)));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs + 4)));
                },
                .for_of => {
                    try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.rhs))));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs + 1)));
                },
                .call, .new_call => {
                    try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                },
                .object, .array, .template, .sequence => try stack.appendSlice(p.scratch, try p.nodesOf(JsIr.inlineRange(d))),
                .cond => {
                    try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                    try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.rhs))));
                    try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.rhs + 1))));
                },
                .binary => {
                    try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.lhs))));
                    try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.lhs + 1))));
                },
                else => {},
            }
            // A LIFO walk visits pushed children backwards. Capture order
            // follows source structure, never name-interning history.
            if (order != null) std.mem.reverse(Node.Index, stack.items[children_start..]);
        }
    }

    // ---- Shared cold remainders ---------------------------------------------

    fn local(p: *Pass) Error!NameIndex {
        var name = p.b.names.items[p.helper_base.int()];
        name.module = .none;
        name.tag = p.local_next;
        p.local_next += 1;
        return p.b.intern(name);
    }

    fn accessor(p: *const Pass, name: NameIndex) ?NameIndex {
        for (p.accessors) |item| if (item.name == name and item.mutable) return item.param;
        return null;
    }

    fn captureExpr(p: *Pass, item: Capture, at: u32) Error!Node.Index {
        if (!item.mutable) return p.ident(item.name, at);
        if (p.accessor(item.name)) |ref| return p.ident(ref, at);
        const value = try p.local();
        const write = try p.local();
        const target = try p.ident(item.name, at);
        const assigned = try p.add(.assign, at, target.int(), (try p.ident(value, at)).int());
        const branches = try p.b.addRecord(JsIr.Cond{ .consequent = assigned, .alternate = try p.ident(item.name, at) });
        const answer = try p.add(.cond, at, (try p.ident(write, at)).int(), @backingInt(branches));
        return p.arrow(&.{ value, write }, &.{try p.ret(answer, at)}, at);
    }

    fn tail(p: *Pass, list: []const Node.Index, input: NameIndex, at: u32) Error!Tail {
        for (p.tails.items) |item| if (item.input == input and std.mem.eql(Node.Index, item.list, list)) return item;
        var named = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        var ordered: std.ArrayList(NameIndex) = .empty;
        for (list) |n| try p.namesIn(n, &named, &ordered);
        if (p.loop) |lp| {
            for (lp.params) |param| if (param.int() < named.bit_length and !named.isSet(param.int())) {
                named.set(param.int());
                try ordered.append(p.scratch, param);
            };
            if (lp.root != .none and lp.root.int() < named.bit_length and !named.isSet(lp.root.int())) {
                named.set(lp.root.int());
                try ordered.append(p.scratch, lp.root);
            }
        }
        var bound = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        var written = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        try p.bindingsIn(list, &bound, &written);
        var captures: std.ArrayList(Capture) = .empty;
        for (ordered.items) |variable| {
            const index = variable.int();
            if (bound.isSet(index) or index == input.int()) continue;
            const name = p.b.names.items[index];
            const loop_parameter = if (p.loop) |lp| blk: {
                for (lp.params) |param| if (param == variable) break :blk true;
                break :blk lp.root == variable;
            } else false;
            const written_variable = index < p.mutable.bit_length and p.mutable.isSet(index);
            if (name.module != .none or name.tag == JsIr.Name.field or
                (name.tag == JsIr.Name.no_tag and !loop_parameter and !written_variable and
                    !(index < p.compiler_locals.len and p.compiler_locals[index]))) continue;
            if (variable == p.names.marker or variable == p.names.join or variable == p.names.joined) continue;
            const mutable = written_variable and !loop_parameter;
            try captures.append(p.scratch, .{ .name = variable, .param = if (mutable) try p.local() else variable, .mutable = mutable });
        }
        var name = p.b.names.items[p.helper_base.int()];
        name.tag = p.helper_next;
        p.helper_next += 1;
        const helper = try p.b.intern(name);
        const item: Tail = .{ .list = list, .input = input, .name = helper, .captures = captures.items };
        try p.tails.append(p.scratch, item);
        const outer = p.accessors;
        p.accessors = item.captures;
        defer p.accessors = outer;
        const rewritten = try p.rewrite(list, .closure);
        const body = try p.cloneList(rewritten);
        const params = try p.scratch.alloc(NameIndex, item.captures.len + 1);
        for (item.captures, params[0..item.captures.len]) |cap, *param| param.* = cap.param;
        params[item.captures.len] = input;
        const param_range = try p.b.addNames(params);
        const body_range = try p.b.addRange(body);
        const function = try p.b.addRecord(JsIr.Func{
            .params_start = param_range.start,
            .params_end = param_range.end,
            .body_start = body_range.start,
            .body_end = body_range.end,
        });
        try p.helpers.append(p.scratch, try p.add(.func_decl, at, @backingInt(item.name), @backingInt(function)));
        return item;
    }

    /// Bound names and writes, including captured writes inside nested functions.
    fn bindingsIn(p: *Pass, list: []const Node.Index, bound: *std.DynamicBitSetUnmanaged, written: *std.DynamicBitSetUnmanaged) Allocator.Error!void {
        var stack: std.ArrayList(Node.Index) = .empty;
        try stack.appendSlice(p.scratch, list);
        while (stack.pop()) |n| {
            const d = p.data(n);
            if (p.markerArgs(n, p.names.marker)) |args| {
                const temp = p.argName(args, 1);
                if (temp.int() < bound.bit_length) bound.set(temp.int());
            }
            if (p.markerArgs(n, p.names.join)) |args| {
                const join_name = p.argName(args, 0);
                if (join_name.int() < bound.bit_length) bound.set(join_name.int());
            }
            if (p.markerArgs(n, p.names.joined)) |args| {
                const temp = p.argName(args, 1);
                if (temp.int() < bound.bit_length) bound.set(temp.int());
            }
            switch (p.tag(n)) {
                .const_decl, .let_decl, .func_decl, .for_of => if (d.lhs < bound.bit_length) bound.set(d.lhs),
                .assign, .assign_stmt => {
                    const target: Node.Index = @fromBackingInt(@intCast(d.lhs));
                    if (p.tag(target) == .ident and p.data(target).lhs < written.bit_length) written.set(p.data(target).lhs);
                },
                else => {},
            }
            if (p.tag(n) == .func_decl or p.tag(n) == .arrow) {
                const f = p.func(if (p.tag(n) == .func_decl) d.rhs else d.lhs);
                for (try p.namesOf(f.params())) |name| if (name.int() < bound.bit_length) {
                    bound.set(name.int());
                };
            }
            try p.children(n, &stack);
        }
    }

    fn children(p: *Pass, n: Node.Index, stack: *std.ArrayList(Node.Index)) Allocator.Error!void {
        const d = p.data(n);
        switch (p.tag(n)) {
            .const_decl, .property, .member, .unary => try stack.append(p.scratch, @fromBackingInt(@intCast(if (p.tag(n) == .const_decl or p.tag(n) == .property) d.rhs else d.lhs))),
            .assign_stmt, .index_get, .assign, .computed_property => {
                try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                try stack.append(p.scratch, @fromBackingInt(@intCast(d.rhs)));
            },
            .let_decl, .return_stmt => {
                const value: Node.OptionalIndex = @fromBackingInt(@intCast(if (p.tag(n) == .let_decl) d.rhs else d.lhs));
                if (value.unwrap()) |v| try stack.append(p.scratch, v);
            },
            .expr_stmt, .throw_stmt, .spread_property => try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs))),
            .func_decl => try stack.appendSlice(p.scratch, try p.nodesOf(p.func(d.rhs).body())),
            .arrow => try stack.appendSlice(p.scratch, try p.nodesOf(p.func(d.lhs).body())),
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                try stack.appendSlice(p.scratch, try p.nodesOf(i.thenBody()));
                try stack.appendSlice(p.scratch, try p.nodesOf(i.elseBody()));
            },
            .switch_stmt => {
                try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
            },
            .switch_case => {
                const value: Node.OptionalIndex = @fromBackingInt(@intCast(d.lhs));
                if (value.unwrap()) |v| try stack.append(p.scratch, v);
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
            },
            .block_stmt, .while_true => try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs))),
            .try_stmt => {
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs + 2)));
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs + 4)));
            },
            .for_of => {
                try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.rhs))));
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs + 1)));
            },
            .call, .new_call => {
                try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
            },
            .object, .array, .template, .sequence => try stack.appendSlice(p.scratch, try p.nodesOf(JsIr.inlineRange(d))),
            .cond => {
                try stack.append(p.scratch, @fromBackingInt(@intCast(d.lhs)));
                try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.rhs))));
                try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.rhs + 1))));
            },
            .binary => {
                try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.lhs))));
                try stack.append(p.scratch, @fromBackingInt(@intCast(p.word(d.lhs + 1))));
            },
            else => {},
        }
    }

    // ---- Copies -------------------------------------------------------------

    /// A copy of `list` with fresh nodes throughout, functions included, so
    /// that no node is reachable from two functions — the release passes key
    /// what they decide by node (`Opt.Plan`).
    fn cloneList(p: *Pass, list: []const Node.Index) Error![]Node.Index {
        const out = try p.scratch.alloc(Node.Index, list.len);
        for (out, list) |*o, n| o.* = try p.clone(n);
        return out;
    }

    fn cloneRange(p: *Pass, r: JsIr.SubRange) Error!JsIr.SubRange {
        const copied = try p.cloneList(try p.nodesOf(r));
        return p.b.addRange(copied);
    }

    fn cloneFunc(p: *Pass, at: u32) Error!JsIr.ExtraIndex {
        const f = p.func(at);
        const params = try p.b.addNames(try p.namesOf(f.params()));
        const body = try p.cloneRange(f.body());
        return p.b.addRecord(JsIr.Func{
            .params_start = params.start,
            .params_end = params.end,
            .body_start = body.start,
            .body_end = body.end,
        });
    }

    fn opt(p: *Pass, raw: u32) Error!u32 {
        const o: Node.OptionalIndex = @fromBackingInt(@intCast(raw));
        const n = o.unwrap() orelse return raw;
        return (try p.clone(n)).int();
    }

    fn clone(p: *Pass, n: Node.Index) Error!Node.Index {
        const d = p.data(n);
        const t = p.tag(n);
        const at = p.posOf(n);
        if (t == .ident) if (p.accessor(@fromBackingInt(@intCast(d.lhs)))) |ref| {
            return p.call(try p.ident(ref, at), &.{ try p.add(.undefined_lit, at, 0, 0), try p.add(.false_lit, at, 0, 0) }, at);
        };
        if (t == .assign or t == .assign_stmt) {
            const target: Node.Index = @fromBackingInt(@intCast(d.lhs));
            if (p.tag(target) == .ident) if (p.accessor(@fromBackingInt(@intCast(p.data(target).lhs)))) |ref| {
                const call_node = try p.call(try p.ident(ref, at), &.{ try p.clone(@fromBackingInt(@intCast(d.rhs))), try p.add(.true_lit, at, 0, 0) }, at);
                return if (t == .assign_stmt) p.add(.expr_stmt, at, call_node.int(), 0) else call_node;
            };
        }
        switch (t) {
            .ident, .field_name, .number, .template_chunk, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .import_meta_url, .worker_path, .this_lit, .break_stmt, .continue_stmt => return p.add(t, at, d.lhs, d.rhs),
            .string => {
                const copied = try p.add(t, at, d.lhs, d.rhs);
                if (p.b.nodes.items(.flags)[n.int()].identity) p.b.markIdentity(copied);
                return copied;
            },
            .const_decl => {
                const copy = try p.add(t, at, d.lhs, (try p.clone(@fromBackingInt(@intCast(d.rhs)))).int());
                if (p.keep) |keep| if (std.mem.indexOfScalar(Node.Index, keep.items, n) != null) try keep.append(p.scratch, copy);
                return copy;
            },
            .property => return p.add(t, at, d.lhs, (try p.clone(@fromBackingInt(@intCast(d.rhs)))).int()),
            .let_decl => return p.add(t, at, d.lhs, try p.opt(d.rhs)),
            .return_stmt => return p.add(t, at, try p.opt(d.lhs), d.rhs),
            .assign_stmt, .index_get, .assign, .computed_property => {
                const lhs = try p.clone(@fromBackingInt(@intCast(d.lhs)));
                const rhs = try p.clone(@fromBackingInt(@intCast(d.rhs)));
                return p.add(t, at, lhs.int(), rhs.int());
            },
            .expr_stmt, .throw_stmt, .spread_property => return p.add(t, at, (try p.clone(@fromBackingInt(@intCast(d.lhs)))).int(), d.rhs),
            .member, .unary => return p.add(t, at, (try p.clone(@fromBackingInt(@intCast(d.lhs)))).int(), d.rhs),
            .func_decl, .gen_decl => return p.add(t, at, d.lhs, @backingInt(try p.cloneFunc(d.rhs))),
            .arrow => return p.add(t, at, @backingInt(try p.cloneFunc(d.lhs)), d.rhs),
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                const cond = try p.clone(@fromBackingInt(@intCast(d.lhs)));
                const then = try p.cloneRange(i.thenBody());
                const otherwise = try p.cloneRange(i.elseBody());
                const record = try p.b.addRecord(JsIr.If{
                    .then_start = then.start,
                    .then_end = then.end,
                    .else_start = otherwise.start,
                    .else_end = otherwise.end,
                });
                return p.add(t, at, cond.int(), @backingInt(record));
            },
            .switch_stmt => {
                const disc = try p.clone(@fromBackingInt(@intCast(d.lhs)));
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, disc.int(), @backingInt(try p.b.addRecord(body)));
            },
            .switch_case => {
                const test_raw = try p.opt(d.lhs);
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, test_raw, @backingInt(try p.b.addRecord(body)));
            },
            .block_stmt, .while_true => {
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, d.lhs, @backingInt(try p.b.addRecord(body)));
            },
            .try_stmt => {
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                const final = try p.cloneRange(p.rangeAt(d.rhs + 2));
                const caught = try p.cloneRange(p.rangeAt(d.rhs + 4));
                const record = try p.b.addRecord(JsIr.Try{
                    .body_start = body.start,
                    .body_end = body.end,
                    .final_start = final.start,
                    .final_end = final.end,
                    .catch_start = caught.start,
                    .catch_end = caught.end,
                    .catch_name = @fromBackingInt(@intCast(p.word(d.rhs + 6))),
                });
                return p.add(t, at, d.lhs, @backingInt(record));
            },
            .for_of => {
                const iterable = try p.clone(@fromBackingInt(@intCast(p.word(d.rhs))));
                const body = try p.cloneRange(p.rangeAt(d.rhs + 1));
                const record = try p.b.addRecord(JsIr.ForOf{ .iterable = iterable, .body_start = body.start, .body_end = body.end });
                return p.add(t, at, d.lhs, @backingInt(record));
            },
            .call, .new_call => {
                const callee = try p.clone(@fromBackingInt(@intCast(d.lhs)));
                const args = try p.cloneRange(p.rangeAt(d.rhs));
                const copy = try p.add(t, at, callee.int(), @backingInt(try p.b.addRecord(args)));
                // A `Js.apply`'s call keeps its mark (`JsIr.Node.flags.host`): §9
                // item 6 reads it on the copy as on the original.
                if (t == .call and p.hostOf(n)) p.b.markHost(copy);
                return copy;
            },
            .object, .array, .template, .sequence => {
                const r = try p.cloneRange(JsIr.inlineRange(d));
                const copy = try p.add(t, at, @backingInt(r.start), @backingInt(r.end));
                if (p.b.nodes.items(.flags)[n.int()].cell) p.b.markCell(copy);
                return copy;
            },
            .cond => {
                const test_node = try p.clone(@fromBackingInt(@intCast(d.lhs)));
                const yes = try p.clone(@fromBackingInt(@intCast(p.word(d.rhs))));
                const no = try p.clone(@fromBackingInt(@intCast(p.word(d.rhs + 1))));
                const record = try p.b.addRecord(JsIr.Cond{ .consequent = yes, .alternate = no });
                return p.add(t, at, test_node.int(), @backingInt(record));
            },
            .binary => {
                const left = try p.clone(@fromBackingInt(@intCast(p.word(d.lhs))));
                const right = try p.clone(@fromBackingInt(@intCast(p.word(d.lhs + 1))));
                const record = try p.b.addRecord(JsIr.Binary{ .left = left, .right = right });
                return p.add(t, at, @backingInt(record), d.rhs);
            },
            .import_stmt, .export_stmt => return n,
        }
    }
};
