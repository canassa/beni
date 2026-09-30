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
//!   - **closure mode**: `return Task$andThen(<call>, (<temp>) => { rest })`.
//!     A rest that is `return <temp>` alone is the call returned as it is.
//!   - **loop mode**, the top of a tail-call loop's body (`backend.md` §8):
//!     `const <temp> = <call>; if (Task$isWaiting(<temp>)) return
//!     Task$andThen(<temp>, (<temp>) => { rest' }); rest`, where `rest'` is a
//!     copy of the rest in closure mode in which every `continue <label>` has
//!     become `return <function>(<parameters>)` — the loop's state is its
//!     parameter list (plan §2.2), and the copy reads only the iteration's
//!     `const`s and the slots the jump just assigned. A loop that BUILDS
//!     (`backend.md` §8, *Tail calls modulo cons, onto an array*) has a
//!     destination too, so its `continue` becomes `return
//!     Task$andThen(<function>(<parameters>), ($built) => List$close($root,
//!     $built))`: the re-entry builds the rest in a list of its own, and the
//!     continuation pushes it after what this call pushed.
//!
//! A **join** (`$$join($j)` … `$$joined($j, $t)`) closes a non-tail `case`
//! whose branches may suspend: in closure mode the rest after it becomes
//! `const $j = ($t) => { rest }`, declared in front of the case, whose
//! leaves `return $j(value)`; in loop mode the rest is written into each
//! leaf instead, so the fast path never calls back into the function.
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

pub const Error = error{ OutOfMemory, FallsThrough };

/// The names the pass recognises and writes.
pub const Names = struct {
    /// `$$suspend(call, temp)`, `$$join($j)`, `$$joined($j, $t)`.
    marker: NameIndex,
    join: NameIndex,
    joined: NameIndex,
    /// `Task$andThen` and `Task$isWaiting`, imported by `Lower`.
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

    // ---- Reading the builder's nodes ------------------------------------

    fn tag(p: *const Pass, n: Node.Index) Node.Tag {
        return p.b.nodes.items(.tag)[n.int()];
    }

    fn data(p: *const Pass, n: Node.Index) Node.Data {
        return p.b.nodes.items(.data)[n.int()];
    }

    fn posOf(p: *const Pass, n: Node.Index) u32 {
        return p.b.nodes.items(.pos)[n.int()];
    }

    fn word(p: *const Pass, at: u32) u32 {
        return p.b.extra.items[at];
    }

    /// The `SubRange` record at `at`.
    fn rangeAt(p: *const Pass, at: u32) JsIr.SubRange {
        return .{ .start = @enumFromInt(p.word(at)), .end = @enumFromInt(p.word(at + 1)) };
    }

    /// A range's nodes, copied: the builder's `extra` moves as it grows.
    fn nodesOf(p: *const Pass, r: JsIr.SubRange) Error![]Node.Index {
        const words = p.b.extra.items[@intFromEnum(r.start)..@intFromEnum(r.end)];
        const out = try p.scratch.alloc(Node.Index, words.len);
        for (out, words) |*o, w| o.* = @enumFromInt(w);
        return out;
    }

    fn namesOf(p: *const Pass, r: JsIr.SubRange) Error![]NameIndex {
        const words = p.b.extra.items[@intFromEnum(r.start)..@intFromEnum(r.end)];
        const out = try p.scratch.alloc(NameIndex, words.len);
        for (out, words) |*o, w| o.* = @enumFromInt(w);
        return out;
    }

    fn func(p: *const Pass, at: u32) JsIr.Func {
        return .{
            .params_start = @enumFromInt(p.word(at)),
            .params_end = @enumFromInt(p.word(at + 1)),
            .body_start = @enumFromInt(p.word(at + 2)),
            .body_end = @enumFromInt(p.word(at + 3)),
        };
    }

    fn ifOf(p: *const Pass, at: u32) JsIr.If {
        return .{
            .then_start = @enumFromInt(p.word(at)),
            .then_end = @enumFromInt(p.word(at + 1)),
            .else_start = @enumFromInt(p.word(at + 2)),
            .else_end = @enumFromInt(p.word(at + 3)),
        };
    }

    // ---- Building ---------------------------------------------------------

    fn add(p: *Pass, t: Node.Tag, at: u32, lhs: u32, rhs: u32) Error!Node.Index {
        return p.b.addParts(t, at, lhs, rhs);
    }

    fn ident(p: *Pass, n: NameIndex, at: u32) Error!Node.Index {
        return p.add(.ident, at, @intFromEnum(n), 0);
    }

    fn call(p: *Pass, callee: Node.Index, args: []const Node.Index, at: u32) Error!Node.Index {
        const range = try p.b.addRange(args);
        const record = try p.b.addRecord(range);
        return p.add(.call, at, callee.int(), @intFromEnum(record));
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
        return p.add(.arrow, at, @intFromEnum(record), Node.arrow_plain);
    }

    fn ret(p: *Pass, value: Node.Index, at: u32) Error!Node.Index {
        return p.add(.return_stmt, at, @intFromEnum(value.toOptional()), 0);
    }

    fn block(p: *Pass, t: Node.Tag, at: u32, lhs: u32, body: []const Node.Index) Error!Node.Index {
        const range = try p.b.addRange(body);
        const record = try p.b.addRecord(range);
        return p.add(t, at, lhs, @intFromEnum(record));
    }

    // ---- Markers ----------------------------------------------------------

    /// The marker call's arguments when `n` is `expr_stmt($$<which>(…))`.
    fn markerArgs(p: *const Pass, n: Node.Index, which: NameIndex) ?JsIr.SubRange {
        if (p.tag(n) != .expr_stmt) return null;
        const e: Node.Index = @enumFromInt(p.data(n).lhs);
        if (p.tag(e) != .call) return null;
        const callee: Node.Index = @enumFromInt(p.data(e).lhs);
        if (p.tag(callee) != .ident or p.data(callee).lhs != @intFromEnum(which)) return null;
        return p.rangeAt(p.data(e).rhs);
    }

    fn isMarker(p: *const Pass, n: Node.Index) bool {
        return p.markerArgs(n, p.names.marker) != null or p.markerArgs(n, p.names.join) != null or p.markerArgs(n, p.names.joined) != null;
    }

    fn argNode(p: *const Pass, r: JsIr.SubRange, i: u32) Node.Index {
        return @enumFromInt(p.word(@intFromEnum(r.start) + i));
    }

    fn argName(p: *const Pass, r: JsIr.SubRange, i: u32) NameIndex {
        return @enumFromInt(p.data(p.argNode(r, i)).lhs);
    }

    /// Whether statement `n` holds a marker, or — `continues` — a `continue`
    /// of the loop, anywhere in its statement lists (never inside a
    /// function: a nested function was rewritten when it was built).
    fn holds(p: *const Pass, n: Node.Index, continues: bool) Error!bool {
        if (p.isMarker(n)) return true;
        const d = p.data(n);
        switch (p.tag(n)) {
            .continue_stmt => return continues and p.loop != null and d.lhs == @intFromEnum(p.loop.?.label),
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                return try p.listHolds(try p.nodesOf(i.thenBody()), continues) or try p.listHolds(try p.nodesOf(i.elseBody()), continues);
            },
            .switch_stmt, .switch_case, .block_stmt => return p.listHolds(try p.nodesOf(p.rangeAt(d.rhs)), continues),
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
            .switch_stmt => {
                var has_default = false;
                for (try p.nodesOf(p.rangeAt(d.rhs))) |c| {
                    if (p.data(c).lhs == @intFromEnum(Node.OptionalIndex.none)) has_default = true;
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
                switch (mode) {
                    .closure => {
                        // The call in tail position: `$Y` passes through.
                        if (rest.len == 1 and p.isReturnOf(rest[0], temp)) {
                            try out.append(p.scratch, try p.ret(call_node, at));
                            return out.items;
                        }
                        try p.liftFunctions(list[0..i], call_node, rest, &out);
                        const body = try p.rewrite(try p.withoutLifted(rest, out.items), .closure);
                        const k = try p.arrow(&.{temp}, body, at);
                        const then = try p.call(try p.ident(p.names.and_then, at), &.{ call_node, k }, at);
                        try out.append(p.scratch, try p.ret(then, at));
                        return out.items;
                    },
                    .loop => {
                        // The fast path goes on in place; the slow path's
                        // continuation is a copy that re-enters the loop.
                        try out.append(p.scratch, try p.add(.const_decl, at, @intFromEnum(temp), call_node.int()));
                        const slow_rest = try p.cloneList(rest);
                        const slow = try p.rewrite(slow_rest, .closure);
                        const k = try p.arrow(&.{temp}, slow, at);
                        const parked = try p.call(try p.ident(p.names.is_waiting, at), &.{try p.ident(temp, at)}, at);
                        const then = try p.call(try p.ident(p.names.and_then, at), &.{ try p.ident(temp, at), k }, at);
                        const leave = try p.ret(then, at);
                        const then_range = try p.b.addRange(&.{leave});
                        const else_range = try p.b.addRange(&.{});
                        const if_record = try p.b.addRecord(JsIr.If{
                            .then_start = then_range.start,
                            .then_end = then_range.end,
                            .else_start = else_range.start,
                            .else_end = else_range.end,
                        });
                        try out.append(p.scratch, try p.add(.if_stmt, at, parked.int(), @intFromEnum(if_record)));
                        try out.appendSlice(p.scratch, try p.rewrite(rest, .loop));
                        return out.items;
                    },
                }
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
                const at = p.posOf(n);
                switch (mode) {
                    .closure => {
                        const body = try p.rewrite(rest, .closure);
                        const k = try p.arrow(&.{param}, body, at);
                        try out.append(p.scratch, try p.add(.const_decl, at, @intFromEnum(j), k.int()));
                        try out.appendSlice(p.scratch, try p.rewrite(tree, .closure));
                        return out.items;
                    },
                    .loop => {
                        const inlined = try p.substituteJoin(tree, j, param, rest);
                        try out.appendSlice(p.scratch, try p.rewrite(inlined, .loop));
                        return out.items;
                    },
                }
            }
            try out.append(p.scratch, try p.rewriteNode(n, mode));
        }
        return out.items;
    }

    fn isReturnOf(p: *const Pass, n: Node.Index, temp: NameIndex) bool {
        if (p.tag(n) != .return_stmt) return false;
        const v: Node.OptionalIndex = @enumFromInt(p.data(n).lhs);
        const value = v.unwrap() orelse return false;
        return p.tag(value) == .ident and p.data(value).lhs == @intFromEnum(temp);
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
                for (args, lp.params) |*a, param| a.* = try p.ident(param, at);
                const reentry = try p.call(try p.ident(lp.callee, at), args, at);
                if (lp.root == .none) return p.ret(reentry, at);
                // A building loop: the re-entry builds the rest of the list
                // in a destination of its own, and this call's list is
                // whole once that rest is pushed after what it holds —
                // `Task$andThen(F(…), ($built) => List$close($root,
                // $built))`, a copy of the rest once per park. The array
                // written so far is still reachable only from this
                // continuation, which runs once.
                const closed = try p.call(try p.ident(lp.close, at), &.{ try p.ident(lp.root, at), try p.ident(lp.built, at) }, at);
                const k = try p.arrow(&.{lp.built}, &.{try p.ret(closed, at)}, at);
                return p.ret(try p.call(try p.ident(p.names.and_then, at), &.{ reentry, k }, at), at);
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
                return p.add(.if_stmt, at, d.lhs, @intFromEnum(record));
            },
            .switch_stmt, .switch_case, .block_stmt => {
                const body = try p.rewrite(try p.nodesOf(p.rangeAt(d.rhs)), mode);
                return p.block(p.tag(n), at, d.lhs, body);
            },
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
                try out.append(p.scratch, try p.add(.const_decl, at, @intFromEnum(param), value.int()));
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
                    try out.append(p.scratch, try p.add(.if_stmt, at, d.lhs, @intFromEnum(record)));
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
        const v: Node.OptionalIndex = @enumFromInt(p.data(n).lhs);
        const e = v.unwrap() orelse return null;
        if (p.tag(e) != .call) return null;
        const callee: Node.Index = @enumFromInt(p.data(e).lhs);
        if (p.tag(callee) != .ident or p.data(callee).lhs != @intFromEnum(j)) return null;
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
        for (before) |n| try p.namesIn(n, &named);
        try p.namesIn(call_node, &named);
        var lifted = try std.DynamicBitSetUnmanaged.initEmpty(p.scratch, p.b.names.items.len);
        var grew = true;
        while (grew) {
            grew = false;
            for (rest) |n| {
                if (p.tag(n) != .func_decl) continue;
                const name = p.data(n).lhs;
                if (lifted.isSet(name) or !named.isSet(name)) continue;
                lifted.set(name);
                try p.namesIn(n, &named);
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
    fn namesIn(p: *Pass, n: Node.Index, into: *std.DynamicBitSetUnmanaged) Error!void {
        var stack: std.ArrayList(Node.Index) = .empty;
        try stack.append(p.scratch, n);
        while (stack.pop()) |x| {
            const d = p.data(x);
            switch (p.tag(x)) {
                .ident => if (d.lhs < into.bit_length) into.set(d.lhs),
                .const_decl, .assign_stmt, .index_get => {
                    if (p.tag(x) != .const_decl) try stack.append(p.scratch, @enumFromInt(d.lhs));
                    try stack.append(p.scratch, @enumFromInt(d.rhs));
                },
                .let_decl, .return_stmt => {
                    const v: Node.OptionalIndex = @enumFromInt(if (p.tag(x) == .let_decl) d.rhs else d.lhs);
                    if (v.unwrap()) |e| try stack.append(p.scratch, e);
                },
                .expr_stmt, .throw_stmt, .spread_property => try stack.append(p.scratch, @enumFromInt(d.lhs)),
                .member, .unary => try stack.append(p.scratch, @enumFromInt(d.lhs)),
                .property => try stack.append(p.scratch, @enumFromInt(d.rhs)),
                .func_decl => try stack.appendSlice(p.scratch, try p.nodesOf(p.func(d.rhs).body())),
                .arrow => try stack.appendSlice(p.scratch, try p.nodesOf(p.func(d.lhs).body())),
                .if_stmt => {
                    const i = p.ifOf(d.rhs);
                    try stack.append(p.scratch, @enumFromInt(d.lhs));
                    try stack.appendSlice(p.scratch, try p.nodesOf(i.thenBody()));
                    try stack.appendSlice(p.scratch, try p.nodesOf(i.elseBody()));
                },
                .switch_stmt => {
                    try stack.append(p.scratch, @enumFromInt(d.lhs));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                },
                .switch_case => {
                    const t: Node.OptionalIndex = @enumFromInt(d.lhs);
                    if (t.unwrap()) |e| try stack.append(p.scratch, e);
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                },
                .block_stmt, .while_true => try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs))),
                .call, .new_call => {
                    try stack.append(p.scratch, @enumFromInt(d.lhs));
                    try stack.appendSlice(p.scratch, try p.nodesOf(p.rangeAt(d.rhs)));
                },
                .object, .array, .template => try stack.appendSlice(p.scratch, try p.nodesOf(JsIr.inlineRange(d))),
                .cond => {
                    try stack.append(p.scratch, @enumFromInt(d.lhs));
                    try stack.append(p.scratch, @enumFromInt(p.word(d.rhs)));
                    try stack.append(p.scratch, @enumFromInt(p.word(d.rhs + 1)));
                },
                .binary => {
                    try stack.append(p.scratch, @enumFromInt(p.word(d.lhs)));
                    try stack.append(p.scratch, @enumFromInt(p.word(d.lhs + 1)));
                },
                else => {},
            }
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
        const o: Node.OptionalIndex = @enumFromInt(raw);
        const n = o.unwrap() orelse return raw;
        return (try p.clone(n)).int();
    }

    fn clone(p: *Pass, n: Node.Index) Error!Node.Index {
        const d = p.data(n);
        const t = p.tag(n);
        const at = p.posOf(n);
        switch (t) {
            .ident, .number, .string, .template_chunk, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .break_stmt, .continue_stmt => return p.add(t, at, d.lhs, d.rhs),
            .const_decl => {
                const copy = try p.add(t, at, d.lhs, (try p.clone(@enumFromInt(d.rhs))).int());
                if (p.keep) |keep| if (std.mem.indexOfScalar(Node.Index, keep.items, n) != null) try keep.append(p.scratch, copy);
                return copy;
            },
            .property => return p.add(t, at, d.lhs, (try p.clone(@enumFromInt(d.rhs))).int()),
            .let_decl => return p.add(t, at, d.lhs, try p.opt(d.rhs)),
            .return_stmt => return p.add(t, at, try p.opt(d.lhs), d.rhs),
            .assign_stmt, .index_get => {
                const lhs = try p.clone(@enumFromInt(d.lhs));
                const rhs = try p.clone(@enumFromInt(d.rhs));
                return p.add(t, at, lhs.int(), rhs.int());
            },
            .expr_stmt, .throw_stmt, .spread_property => return p.add(t, at, (try p.clone(@enumFromInt(d.lhs))).int(), d.rhs),
            .member, .unary => return p.add(t, at, (try p.clone(@enumFromInt(d.lhs))).int(), d.rhs),
            .func_decl, .gen_decl => return p.add(t, at, d.lhs, @intFromEnum(try p.cloneFunc(d.rhs))),
            .arrow => return p.add(t, at, @intFromEnum(try p.cloneFunc(d.lhs)), d.rhs),
            .if_stmt => {
                const i = p.ifOf(d.rhs);
                const cond = try p.clone(@enumFromInt(d.lhs));
                const then = try p.cloneRange(i.thenBody());
                const otherwise = try p.cloneRange(i.elseBody());
                const record = try p.b.addRecord(JsIr.If{
                    .then_start = then.start,
                    .then_end = then.end,
                    .else_start = otherwise.start,
                    .else_end = otherwise.end,
                });
                return p.add(t, at, cond.int(), @intFromEnum(record));
            },
            .switch_stmt => {
                const disc = try p.clone(@enumFromInt(d.lhs));
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, disc.int(), @intFromEnum(try p.b.addRecord(body)));
            },
            .switch_case => {
                const test_raw = try p.opt(d.lhs);
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, test_raw, @intFromEnum(try p.b.addRecord(body)));
            },
            .block_stmt, .while_true => {
                const body = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, d.lhs, @intFromEnum(try p.b.addRecord(body)));
            },
            .call, .new_call => {
                const callee = try p.clone(@enumFromInt(d.lhs));
                const args = try p.cloneRange(p.rangeAt(d.rhs));
                return p.add(t, at, callee.int(), @intFromEnum(try p.b.addRecord(args)));
            },
            .object, .array, .template => {
                const r = try p.cloneRange(JsIr.inlineRange(d));
                return p.add(t, at, @intFromEnum(r.start), @intFromEnum(r.end));
            },
            .cond => {
                const test_node = try p.clone(@enumFromInt(d.lhs));
                const yes = try p.clone(@enumFromInt(p.word(d.rhs)));
                const no = try p.clone(@enumFromInt(p.word(d.rhs + 1)));
                const record = try p.b.addRecord(JsIr.Cond{ .consequent = yes, .alternate = no });
                return p.add(t, at, test_node.int(), @intFromEnum(record));
            },
            .binary => {
                const left = try p.clone(@enumFromInt(p.word(d.lhs)));
                const right = try p.clone(@enumFromInt(p.word(d.lhs + 1)));
                const record = try p.b.addRecord(JsIr.Binary{ .left = left, .right = right });
                return p.add(t, at, @intFromEnum(record), d.rhs);
            },
            .import_stmt, .export_stmt => return n,
        }
    }
};
